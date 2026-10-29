import Foundation

/// The result of a scan: an immutable-shape tree stored in compact arenas.
///
/// After `finalize()` every directory's size is the sum of its children and children are
/// sorted by size, largest first. Reads are safe from any thread; mutations (collector removal)
/// must be serialized by the caller.
public final class FileTree: @unchecked Sendable {
    public let rootPath: String
    public let root: NodeRef
    var arenas: [Arena]
    var liveArenaStorage: Arena?
    /// Index in `arenas` of the first arena created for live edits.
    var firstLiveArena: Int?
    /// Nodes no longer reachable after live refreshes replaced their listings. They stay allocated until a rescan.
    public internal(set) var garbageNodeCount = 0

    init(rootPath: String, root: NodeRef, arenas: [Arena]) {
        self.rootPath = rootPath
        self.root = root
        self.arenas = arenas
    }

    @inline(__always) func pointer(_ ref: NodeRef) -> UnsafeMutablePointer<Node> {
        arenas[ref.arena].pointer(ref.index)
    }

    // MARK: - Reading

    public var nodeCount: Int { arenas.reduce(0) { $0 + $1.nodeCount } }
    public var memoryFootprint: Int { arenas.reduce(0) { $0 + $1.memoryFootprint } }

    public func size(_ ref: NodeRef) -> UInt64 { pointer(ref).pointee.size }
    public func flags(_ ref: NodeRef) -> NodeFlags { pointer(ref).pointee.flags }
    public func isDirectory(_ ref: NodeRef) -> Bool { flags(ref).contains(.directory) }
    public func descendantCount(_ ref: NodeRef) -> Int { Int(pointer(ref).pointee.descendantCount) }

    public func parent(_ ref: NodeRef) -> NodeRef? {
        let p = pointer(ref).pointee.parent
        return p.isNone ? nil : p
    }

    public func children(_ ref: NodeRef) -> Children {
        let node = pointer(ref).pointee
        return Children(first: node.firstChild, count: Int(node.childCount))
    }

    public func name(_ ref: NodeRef) -> String {
        withNameBytes(ref) { String(decoding: $0, as: UTF8.self) }
    }

    public func withNameBytes<R>(_ ref: NodeRef, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let node = pointer(ref).pointee
        return body(arenas[ref.arena].nameBytes(offset: node.nameOffset, length: node.nameLength))
    }

    /// Chain from the root down to `ref`, inclusive.
    public func ancestry(_ ref: NodeRef) -> [NodeRef] {
        var chain: [NodeRef] = []
        var current: NodeRef? = ref
        while let c = current {
            chain.append(c)
            current = parent(c)
        }
        return chain.reversed()
    }

    public func path(_ ref: NodeRef) -> String {
        var path = rootPath
        for node in ancestry(ref).dropFirst() {
            if !path.hasSuffix("/") { path += "/" }
            path += name(node)
        }
        return path
    }

    /// Finds a node by its path components relative to the root (used to restore selection after a rescan).
    public func lookup(components: [String]) -> NodeRef? {
        var current = root
        for component in components {
            guard let next = children(current).first(where: { name($0) == component }) else { return nil }
            current = next
        }
        return current
    }

    /// Children largest first. Scans store them sorted; later edits (collecting, live refresh) change sizes without
    /// moving nodes, so this re-sorts a copy only when the stored order has gone stale.
    public func sortedChildren(_ ref: NodeRef) -> [NodeRef] {
        let kids = Array(children(ref))
        var isSorted = true
        var previous = UInt64.max
        for kid in kids {
            let size = self.size(kid)
            if size > previous { isSorted = false; break }
            previous = size
        }
        if isSorted { return kids }
        return kids.sorted { size($0) > size($1) }
    }

    public struct Children: RandomAccessCollection, Sendable {
        let first: NodeRef
        public let count: Int
        public var startIndex: Int { 0 }
        public var endIndex: Int { count }
        public subscript(position: Int) -> NodeRef { first.advanced(by: position) }
    }

    // MARK: - Finalization

    /// Rolls sizes up bottom-up and sorts every directory's children by size (descending).
    /// Iterative post-order walk, so arbitrarily deep trees are fine.
    func finalize() {
        var stack: [(NodeRef, Bool)] = [(root, false)]
        var scratch: [Node] = []
        while let (ref, expanded) = stack.popLast() {
            let node = pointer(ref)
            let count = Int(node.pointee.childCount)
            guard node.pointee.flags.contains(.directory), count > 0 else { continue }
            let first = node.pointee.firstChild

            if !expanded {
                stack.append((ref, true))
                for i in 0..<count where pointer(first.advanced(by: i)).pointee.flags.contains(.directory) {
                    stack.append((first.advanced(by: i), false))
                }
                continue
            }

            var total: UInt64 = 0
            var descendants: UInt32 = 0
            scratch.removeAll(keepingCapacity: true)
            for i in 0..<count {
                let child = pointer(first.advanced(by: i)).pointee
                total &+= child.size
                descendants &+= child.descendantCount &+ 1
                scratch.append(child)
            }
            node.pointee.size = total
            node.pointee.descendantCount = descendants

            // Sort children in place; stable on name offset so equal sizes keep scan order.
            let alreadySorted = zip(scratch, scratch.dropFirst()).allSatisfy { $0.size >= $1.size }
            guard !alreadySorted else { continue }
            scratch.sort { $0.size != $1.size ? $0.size > $1.size : $0.nameOffset < $1.nameOffset }
            for i in 0..<count {
                let childRef = first.advanced(by: i)
                pointer(childRef).pointee = scratch[i]
                // The child moved: re-point its own children at its new slot.
                let moved = scratch[i]
                for j in 0..<Int(moved.childCount) {
                    pointer(moved.firstChild.advanced(by: j)).pointee.parent = childRef
                }
            }
        }
    }

    // MARK: - Mutation

    /// Marks `ref` as removed and subtracts its size from all ancestors. Returns the bytes removed.
    @discardableResult
    public func remove(_ ref: NodeRef) -> UInt64 {
        let node = pointer(ref)
        guard !node.pointee.flags.contains(.removed) else { return 0 }
        let size = node.pointee.size
        let items = node.pointee.descendantCount &+ 1
        node.pointee.flags.insert(.removed)
        var current = node.pointee.parent
        while !current.isNone {
            let p = pointer(current)
            p.pointee.size &-= size
            p.pointee.descendantCount &-= items
            current = p.pointee.parent
        }
        return size
    }

    /// Reverses `remove(_:)`.
    public func restore(_ ref: NodeRef) {
        let node = pointer(ref)
        guard node.pointee.flags.contains(.removed) else { return }
        let size = node.pointee.size
        let items = node.pointee.descendantCount &+ 1
        node.pointee.flags.remove(.removed)
        var current = node.pointee.parent
        while !current.isNone {
            let p = pointer(current)
            p.pointee.size &+= size
            p.pointee.descendantCount &+= items
            current = p.pointee.parent
        }
    }
}
