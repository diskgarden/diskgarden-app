import CoreServices
import Darwin
import Foundation

// MARK: - Reading one directory

/// One entry of a single-directory listing (used by live refresh).
public struct DirectoryEntry: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isMountPoint: Bool
    public let size: UInt64
}

public enum DirectoryReader {
    /// Lists `path` with getattrlistbulk (same attributes as the scanner). nil if it can't be opened.
    /// `startupDisk`: skip the Data volume's firmlinked entries (counted at /), like a scan of /.
    public static func list(_ path: String, startupDisk: Bool = false) -> [DirectoryEntry]? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = 0x8000_0000 | 0x0000_0001 | 0x2000_0000 | 0x0000_0008 // RETURNED | NAME | ERROR | OBJTYPE
        attrs.dirattr = 0x0000_0004 // MOUNTSTATUS
        attrs.fileattr = 0x0000_0004 // ALLOCSIZE
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [DirectoryEntry] = []
        let isRoot = path == "/"
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_NOFOLLOW))
            if count <= 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & 0x2000_0000 != 0 {
                    let err = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if err != 0 { continue }
                }
                guard returned.commonattr & 1 != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePtr = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                let name = String(cString: namePtr)
                field += MemoryLayout<attrreference_t>.size
                if isRoot && [".nofollow", ".resolve", ".vol"].contains(name) { continue }
                if startupDisk && Firmlinks.isFirmlinked(name, in: path) { continue }
                var objType: UInt32 = 0
                if returned.commonattr & 8 != 0 {
                    objType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                let isDir = objType == 2
                var mount = false
                var size: UInt64 = 0
                if isDir {
                    if returned.dirattr & 4 != 0 {
                        mount = field.loadUnaligned(as: UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
                    }
                } else if returned.fileattr & 4 != 0 {
                    size = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                }
                entries.append(DirectoryEntry(name: name, isDirectory: isDir, isSymlink: objType == 5,
                                              isMountPoint: mount, size: size))
            }
        }
        return entries
    }
}

// MARK: - Applying a refresh to the tree

public struct RefreshResult: Sendable {
    /// Children of the refreshed folder moved to new slots: old ref → new ref (their subtrees are unchanged).
    public var remap: [NodeRef: NodeRef] = [:]
    /// Children that no longer exist on disk.
    public var dropped: [NodeRef] = []
    /// New child folders that need their contents scanned (name → new node).
    public var newDirectories: [(name: String, node: NodeRef)] = []
    public var sizeDelta: Int64 = 0
}

extension FileTree {
    /// The append-only arena used for all post-scan edits (grafts, refreshes). Created on first use, so repeated
    /// edits never exhaust arena ids. Main thread only.
    var liveArena: Arena {
        // Roll over to a fresh arena well before this one is full (an arena holds 2^26 nodes): one edit appends at
        // most a folder's listing or one grafted subtree, far less than the headroom left.
        if let live = liveArenaStorage, live.nodeCount < Self.liveArenaRollover { return live }
        precondition(arenas.count < NodeRef.maxArenas, "no arena ids left for live edits")
        let arena = Arena(id: arenas.count)
        arenas.append(arena)
        if firstLiveArena == nil { firstLiveArena = arenas.count - 1 }
        liveArenaStorage = arena
        return arena
    }

    static let liveArenaRollover = 1 << 25

    /// Nodes appended by live edits and grafts since the scan (including real content, e.g. administrator results).
    public var liveNodeCount: Int {
        guard let first = firstLiveArena else { return 0 }
        return arenas[first...].reduce(0) { $0 + $1.nodeCount }
    }

    /// Replaces `directory`'s children with a fresh listing, keeping the subtrees of folders that still exist.
    /// `newSubtrees` holds scans of folders that appeared since (by name); new folders without one are returned in
    /// `newDirectories` with an empty node. Children are appended already in size order, so every returned ref is final.
    /// Must run on the tree's owning (main) thread.
    public func applyListing(_ entries: [DirectoryEntry], to directory: NodeRef,
                             newSubtrees: [String: FileTree] = [:], replaceDirectories: Bool = false) -> RefreshResult {
        var result = RefreshResult()
        let arena = liveArena
        var old: [String: NodeRef] = [:]
        for child in children(directory) { old[name(child)] = child }

        struct Pending {
            var record: Node
            var previous: NodeRef?
            var name: String
            var subtree: FileTree?
            var sortSize: UInt64
        }
        var pending: [Pending] = []
        var kept = Set<NodeRef>()
        for entry in entries {
            var flags: NodeFlags = []
            if entry.isDirectory { flags.insert(.directory) }
            if entry.isSymlink { flags.insert(.symlink) }
            if entry.isMountPoint { flags.insert(.mountPoint) }
            let nameBytes = Array(entry.name.utf8)
            let nameOffset = nameBytes.withUnsafeBytes { arena.internName($0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, count: $0.count) }
            var record = Node(size: entry.size, parent: directory, firstChild: .none, childCount: 0, descendantCount: 0,
                              nameOffset: nameOffset, nameLength: UInt16(nameBytes.count), flags: flags)
            // With `replaceDirectories` (FSEvents said the whole subtree changed), folders are rebuilt from fresh scans.
            let previous = old[entry.name].flatMap {
                isDirectory($0) == entry.isDirectory && !(replaceDirectories && entry.isDirectory && newSubtrees[entry.name] != nil) ? $0 : nil
            }
            var subtree: FileTree?
            if let previous {
                let before = pointer(previous).pointee
                if entry.isDirectory {
                    // Unchanged subtree: carry size, children and flags (restricted, removed, other volume…) over.
                    record = before
                    record.parent = directory
                    record.nameOffset = nameOffset
                } else {
                    record.flags.formUnion(before.flags.intersection([.removed, .hardLinkDuplicate]))
                    if before.flags.contains(.hardLinkDuplicate) { record.size = 0 }
                }
                kept.insert(previous)
            } else if entry.isDirectory {
                subtree = newSubtrees[entry.name]
            }
            pending.append(Pending(record: record, previous: previous, name: entry.name, subtree: subtree,
                                   sortSize: subtree.map { $0.size($0.root) } ?? record.size))
        }
        // Final order up front (sizes of new folders known from their scans), so slots never move afterwards.
        pending.sort { $0.sortSize != $1.sortSize ? $0.sortSize > $1.sortSize : $0.name < $1.name }

        // Same entries as before (only sizes changed — the common case: files being written): rewrite the existing
        // slots in their new order instead of appending a fresh copy, so frequently changing folders don't grow
        // the tree. Nothing is dropped, so every old ref stays valid or is remapped within the same block.
        let oldChildren = Array(children(directory))
        if !oldChildren.isEmpty, pending.count == oldChildren.count, kept.count == oldChildren.count,
           pending.allSatisfy({ $0.previous != nil }) {
            let first = oldChildren[0]
            let befores = pending.map { pointer($0.previous!).pointee } // read everything before writing
            for (i, item) in pending.enumerated() {
                let slot = first.advanced(by: i)
                var record = item.record
                // Names live in the block's own arena: keep the original offsets.
                record.nameOffset = befores[i].nameOffset
                record.nameLength = befores[i].nameLength
                pointer(slot).pointee = record
                if item.previous! != slot { result.remap[item.previous!] = slot }
            }
            for i in 0..<pending.count {
                let slot = first.advanced(by: i)
                for grandchild in children(slot) { pointer(grandchild).pointee.parent = slot }
            }
            pointer(directory).pointee.flags.subtract([.restricted, .partial])
            result.sizeDelta = rollUp(directory, sort: false)
            return result
        }

        var first = NodeRef.none
        var grafts: [(FileTree, NodeRef)] = []
        for item in pending {
            let ref = arena.append(item.record)
            if first.isNone { first = ref }
            if let previous = item.previous {
                result.remap[previous] = ref
                for grandchild in children(ref) { pointer(grandchild).pointee.parent = ref }
            } else if let subtree = item.subtree {
                grafts.append((subtree, ref))
            } else if item.record.flags.contains(.directory) && !item.record.flags.contains(.mountPoint) {
                result.newDirectories.append((item.name, ref))
            }
        }
        result.dropped = old.values.filter { !kept.contains($0) }
        // The old block is garbage now (slots are never reused: refs to vanished nodes must stay detached), and so
        // are the subtrees of folders that disappeared.
        garbageNodeCount += oldChildren.count + result.dropped.reduce(0) { $0 + descendantCount($1) }

        let dir = pointer(directory)
        dir.pointee.firstChild = first
        dir.pointee.childCount = UInt32(pending.count)
        dir.pointee.flags.subtract([.restricted, .partial])
        result.sizeDelta = rollUp(directory, sort: false)
        for (subtree, node) in grafts { graft(subtree, at: node) }
        return result
    }

    /// Grafts a separately scanned tree's contents under `node` (e.g. a folder that appeared after the scan).
    public func graft(_ source: FileTree, at node: NodeRef) {
        let arena = liveArena
        var queue: [(from: NodeRef, to: NodeRef)] = [(source.root, node)]
        var head = 0
        while head < queue.count {
            let (from, to) = queue[head]
            head += 1
            var first = NodeRef.none
            let kids = source.children(from)
            for child in kids {
                var record = source.pointer(child).pointee
                let offset = source.withNameBytes(child) { arena.internName(UnsafeRawPointer($0.baseAddress ?? UnsafePointer(bitPattern: 1)!), count: $0.count) }
                record.nameOffset = offset
                record.parent = to
                record.firstChild = .none
                let ref = arena.append(record)
                if first.isNone { first = ref }
                if record.childCount > 0 { queue.append((child, ref)) }
                pointer(ref).pointee.childCount = 0
            }
            pointer(to).pointee.firstChild = first
            pointer(to).pointee.childCount = UInt32(kids.count)
        }
        let target = pointer(node)
        target.pointee.flags.subtract([.restricted, .partial])
        _ = rollUp(node, knownSize: source.size(source.root), knownDescendants: source.descendantCount(source.root))
    }

    /// Re-sorts `node`'s children, recomputes its size and item count from them (or takes the given values), and
    /// propagates the change to all ancestors. Returns the size change.
    @discardableResult
    func rollUp(_ node: NodeRef, knownSize: UInt64? = nil, knownDescendants: Int? = nil, sort: Bool = true) -> Int64 {
        let p = pointer(node)
        if sort { sortChildren(of: node) }
        var size: UInt64 = 0
        var descendants: UInt32 = 0
        if let knownSize, let knownDescendants {
            size = knownSize
            descendants = UInt32(knownDescendants)
        } else {
            for child in children(node) where !flags(child).contains(.removed) {
                size &+= self.size(child)
                descendants &+= UInt32(descendantCount(child)) &+ 1
            }
        }
        let sizeDelta = Int64(bitPattern: size) - Int64(bitPattern: p.pointee.size)
        let countDelta = Int64(descendants) - Int64(p.pointee.descendantCount)
        p.pointee.size = size
        p.pointee.descendantCount = descendants
        guard !p.pointee.flags.contains(.removed) else { return sizeDelta }
        var current = p.pointee.parent
        while !current.isNone {
            let a = pointer(current)
            a.pointee.size = UInt64(Int64(bitPattern: a.pointee.size) + sizeDelta)
            a.pointee.descendantCount = UInt32(Int64(a.pointee.descendantCount) + countDelta)
            if a.pointee.flags.contains(.removed) { break }
            current = a.pointee.parent
        }
        return sizeDelta
    }

    /// Sorts children by size (descending) in place and re-points grandchildren at their parents' new slots.
    func sortChildren(of node: NodeRef) {
        let kids = children(node)
        guard kids.count > 1 else { return }
        var records = kids.map { pointer($0).pointee }
        guard !zip(records, records.dropFirst()).allSatisfy({ $0.size >= $1.size }) else { return }
        records.sort { $0.size != $1.size ? $0.size > $1.size : $0.nameOffset < $1.nameOffset }
        for (i, ref) in kids.enumerated() {
            pointer(ref).pointee = records[i]
            for grandchild in children(ref) { pointer(grandchild).pointee.parent = ref }
        }
    }

    /// Whether `node` is still reachable from the root (refreshes can orphan nodes).
    public func isAttached(_ node: NodeRef) -> Bool {
        var current = node
        while let parent = parent(current) {
            guard children(parent).contains(current) else { return false }
            current = parent
        }
        return current == root
    }

    /// Nearest ancestor-or-self of `node` that's still attached.
    public func nearestAttached(_ node: NodeRef) -> NodeRef {
        var current = node
        while !isAttached(current), let parent = parent(current) { current = parent }
        return isAttached(current) ? current : root
    }
}

// MARK: - Watching for changes

/// FSEvents watcher for a scanned root. Delivers batches of changed directory paths on a background queue.
public final class FileWatcher: @unchecked Sendable {
    public struct Change: Sendable, Hashable {
        public let path: String
        /// FSEvents coalesced events and the whole subtree below `path` should be rechecked.
        public let recursive: Bool
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "DiskGarden.FileWatcher")
    private let handler: @Sendable ([Change]) -> Void

    public init(path: String, latency: TimeInterval = 1.5, handler: @escaping @Sendable ([Change]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changes: [Change] = []
            for i in 0..<count {
                let flags = Int(eventFlags[i])
                let recursive = flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                var path = list[i]
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                // The Data volume's firmlinked content is reported under /System/Volumes/Data; map it back to /.
                path = Firmlinks.pathInScanOfRoot(path)
                changes.append(Change(path: path, recursive: recursive))
            }
            watcher.handler(changes)
        }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        if let stream { FSEventStreamSetDispatchQueue(stream, queue) }
    }

    public func start() {
        if let stream { FSEventStreamStart(stream) }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
