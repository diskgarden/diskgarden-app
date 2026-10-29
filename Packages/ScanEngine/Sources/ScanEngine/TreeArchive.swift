import Foundation

/// Compact binary form of scanned subtrees, used to move scan results from the privileged helper to the app.
///
/// Layout (little-endian):
/// `"DGT1"`, `u32 entryCount`, then per entry: `u32 pathLength`, path bytes, `u64 nodeCount`, and `nodeCount`
/// records in breadth-first order — `u16 nameLength`, name bytes, `u64 size`, `u16 flags`, `u32 childCount`,
/// `u32 descendantCount`. Breadth-first order means every directory's children are contiguous, which is exactly
/// how `FileTree` stores them.
public enum TreeArchive {
    static let magic: [UInt8] = Array("DGT1".utf8)

    public enum ArchiveError: Error, Equatable {
        case badMagic
        case truncated
    }

    // MARK: Writing

    /// Streams the subtrees rooted at each tree's root to `url`, labeled with `path`.
    public static func write(_ entries: [(path: String, tree: FileTree)], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try write(entries) { try handle.write(contentsOf: $0) }
    }

    /// Streams the archive to `sink` in ~1 MB chunks. Items removed from the tree (collected) are left out.
    public static func write(_ entries: [(path: String, tree: FileTree)], sink: (Data) throws -> Void) throws {
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        func flushIfNeeded(force: Bool = false) throws {
            if force || buffer.count >= 1 << 20 {
                try sink(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        buffer.append(contentsOf: magic)
        buffer.append(le: UInt32(entries.count))
        for (path, tree) in entries {
            let pathBytes = Array(path.utf8)
            buffer.append(le: UInt32(pathBytes.count))
            buffer.append(contentsOf: pathBytes)
            // Walk the structure once and write exactly what was seen: the tree may still change meanwhile (items
            // collected or restored on the main thread), and the header count, child counts and descendant counts
            // must agree with the records or the archive can't be read back.
            var queue: [NodeRef] = [tree.root]
            var childCounts: [UInt32] = []
            var head = 0
            while head < queue.count {
                let children = tree.children(queue[head]).filter { !tree.flags($0).contains(.removed) }
                childCounts.append(UInt32(children.count))
                queue.append(contentsOf: children)
                head += 1
            }
            // Descendant counts from the captured structure, bottom-up (children follow their parent in BFS order).
            var firstChild = [Int](repeating: 0, count: queue.count)
            var next = 1
            for i in queue.indices {
                firstChild[i] = next
                next += Int(childCounts[i])
            }
            var descendants = [UInt32](repeating: 0, count: queue.count)
            for i in queue.indices.reversed() {
                var total: UInt32 = 0
                for c in firstChild[i] ..< firstChild[i] + Int(childCounts[i]) { total &+= descendants[c] &+ 1 }
                descendants[i] = total
            }
            firstChild = []
            buffer.append(le: UInt64(queue.count))
            for (i, ref) in queue.enumerated() {
                let node = tree.pointer(ref).pointee
                tree.withNameBytes(ref) { name in
                    buffer.append(le: UInt16(name.count))
                    buffer.append(contentsOf: name)
                }
                buffer.append(le: node.size)
                buffer.append(le: node.flags.subtracting(.removed).rawValue)
                buffer.append(le: childCounts[i])
                buffer.append(le: descendants[i])
                try flushIfNeeded()
            }
            // Release the queue between entries.
            queue = []
        }
        try flushIfNeeded(force: true)
    }

    // MARK: Reading

    /// One archived subtree, parsed lazily from the archive bytes.
    public struct Entry: Sendable {
        public let path: String
        public let nodeCount: UInt64
        let data: Data
        let recordsOffset: Int
    }

    public static func read(_ data: Data) throws -> [Entry] {
        var reader = Reader(data: data)
        guard try reader.bytes(4) == magic else { throw ArchiveError.badMagic }
        let count = try reader.u32()
        var entries: [Entry] = []
        for _ in 0..<count {
            let path = String(decoding: try reader.bytes(Int(try reader.u32())), as: UTF8.self)
            let nodeCount = try reader.u64()
            let start = reader.offset
            try reader.skipRecords(nodeCount)
            entries.append(Entry(path: path, nodeCount: nodeCount, data: data, recordsOffset: start))
        }
        return entries
    }

    struct Record {
        var name: UnsafeRawBufferPointer
        var size: UInt64
        var flags: NodeFlags
        var childCount: UInt32
        var descendantCount: UInt32
    }

    struct Reader {
        let data: Data
        var offset = 0

        init(data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw ArchiveError.truncated }
            defer { offset += n }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + n])
        }

        mutating func load<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw ArchiveError.truncated }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return T(littleEndian: value)
        }

        mutating func u16() throws -> UInt16 { try load(UInt16.self) }
        mutating func u32() throws -> UInt32 { try load(UInt32.self) }
        mutating func u64() throws -> UInt64 { try load(UInt64.self) }

        mutating func skipRecords(_ count: UInt64) throws {
            for _ in 0..<count {
                let nameLength = Int(try u16())
                guard offset + nameLength + 18 <= data.count else { throw ArchiveError.truncated }
                offset += nameLength + 18
            }
        }

        /// Calls `body` with each record; the name buffer is only valid during the call.
        mutating func forEachRecord(_ count: UInt64, _ body: (Record) throws -> Void) throws {
            try data.withUnsafeBytes { raw in
                for _ in 0..<count {
                    guard offset + 2 <= raw.count else { throw ArchiveError.truncated }
                    let nameLength = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                    let base = offset + 2
                    guard base + nameLength + 18 <= raw.count else { throw ArchiveError.truncated }
                    let name = UnsafeRawBufferPointer(rebasing: raw[base ..< base + nameLength])
                    var p = base + nameLength
                    let size = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt64.self)); p += 8
                    let flags = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt16.self)); p += 2
                    let children = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self)); p += 4
                    let descendants = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt32.self)); p += 4
                    offset = p
                    try body(Record(name: name, size: size, flags: NodeFlags(rawValue: flags),
                                    childCount: children, descendantCount: descendants))
                }
            }
        }
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - Grafting archives into trees

extension FileTree {
    /// Replaces the (empty, typically restricted) contents of `node` with an archived subtree scanned elsewhere,
    /// updating sizes and item counts of all ancestors. Must be called from the thread that owns the tree (main).
    public func graft(_ entry: TreeArchive.Entry, at node: NodeRef) throws {
        let arena = liveArena
        var reader = TreeArchive.Reader(data: entry.data, offset: entry.recordsOffset)
        var rootRecord: TreeArchive.Record?
        try reader.forEachRecord(1) { rootRecord = $0 }
        guard let rootRecord else { throw TreeArchive.ArchiveError.truncated }

        // Build the children breadth-first; each queued directory's children follow contiguously.
        var queue: [(ref: NodeRef, count: UInt32)] = [(node, rootRecord.childCount)]
        var head = 0
        var built: [NodeRef: (first: NodeRef, count: UInt32)] = [:]
        while head < queue.count {
            let (parent, count) = queue[head]
            head += 1
            var first = NodeRef.none
            try reader.forEachRecord(UInt64(count)) { record in
                let offset = arena.internName(record.name.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, count: record.name.count)
                let ref = arena.append(Node(
                    size: record.size, parent: parent, firstChild: .none, childCount: 0,
                    descendantCount: record.descendantCount, nameOffset: offset,
                    nameLength: UInt16(record.name.count), flags: record.flags.subtracting(.removed)))
                if first.isNone { first = ref }
                if record.childCount > 0 { queue.append((ref, record.childCount)) }
            }
            built[parent] = (first, count)
        }
        for (parent, children) in built where parent != node {
            pointer(parent).pointee.firstChild = children.first
            pointer(parent).pointee.childCount = children.count
        }

        // Attach to the target and roll the size change up the ancestors.
        let target = pointer(node)
        let sizeDelta = Int64(bitPattern: rootRecord.size) - Int64(bitPattern: target.pointee.size)
        let countDelta = Int64(rootRecord.descendantCount) - Int64(target.pointee.descendantCount)
        target.pointee.firstChild = built[node]?.first ?? .none
        target.pointee.childCount = built[node]?.count ?? 0
        target.pointee.size = rootRecord.size
        target.pointee.descendantCount = rootRecord.descendantCount
        target.pointee.flags.subtract([.restricted, .partial])
        guard !target.pointee.flags.contains(.removed) else { return }
        var current = target.pointee.parent
        while !current.isNone {
            let p = pointer(current)
            p.pointee.size = UInt64(Int64(bitPattern: p.pointee.size) + sizeDelta)
            p.pointee.descendantCount = UInt32(Int64(p.pointee.descendantCount) + countDelta)
            current = p.pointee.parent
        }
    }

    /// Builds a fresh tree from an archived full scan (e.g. a whole-volume scan made as administrator).
    public static func fromArchive(_ entry: TreeArchive.Entry) throws -> FileTree {
        let rootArena = Arena(id: 0)
        let name = entry.path == "/" ? "/" : (entry.path as NSString).lastPathComponent
        let nameBytes = Array(name.utf8)
        let offset = nameBytes.withUnsafeBytes { rootArena.appendName($0.baseAddress!, count: $0.count) }
        let root = rootArena.append(Node(size: 0, parent: .none, firstChild: .none, childCount: 0, descendantCount: 0,
                                         nameOffset: offset, nameLength: UInt16(nameBytes.count), flags: .directory))
        let tree = FileTree(rootPath: entry.path, root: root, arenas: [rootArena])
        try tree.graft(entry, at: root)
        return tree
    }

    /// Every directory that couldn't be opened (skipping collected ones), for "Quick Rescan as Administrator".
    public func restrictedNodes() -> [NodeRef] {
        var result: [NodeRef] = []
        var stack = [root]
        while let ref = stack.popLast() {
            let flags = self.flags(ref)
            if flags.contains(.removed) { continue }
            if flags.contains(.restricted) { result.append(ref) }
            for child in children(ref) where isDirectory(child) { stack.append(child) }
        }
        return result
    }
}
