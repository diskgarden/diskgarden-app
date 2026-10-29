import Darwin
import Foundation
import Synchronization

public enum ScanError: Error, Sendable, Equatable {
    case cannotOpen(path: String, errno: Int32)
    case cancelled
}

public struct ScanOptions: Sendable {
    /// Number of worker threads. SSDs benefit from deep queues; rotational/network media should use ~4.
    public var workerCount: Int
    /// Per-worker getattrlistbulk buffer.
    public var bufferSize: Int
    /// Descend into other volumes mounted below the scan root.
    public var crossMountPoints: Bool
    /// Mount points (absolute path → bytes) that should appear with a known size instead of 0, e.g. the sibling
    /// APFS volumes under /System/Volumes when scanning the startup disk.
    public var fixedSizeMountPoints: [String: UInt64]
    /// The scan is (part of) a scan of the startup disk's /: descend into the Data volume at /System/Volumes/Data
    /// and skip its firmlinked entries, which are counted at / (see Firmlinks).
    public var startupDisk: Bool

    public init(workerCount: Int = ScanOptions.defaultWorkerCount, bufferSize: Int = 64 * 1024, crossMountPoints: Bool = false,
                fixedSizeMountPoints: [String: UInt64] = [:], startupDisk: Bool = false) {
        self.workerCount = max(1, min(workerCount, NodeRef.maxArenas - 1))
        self.bufferSize = max(4096, bufferSize)
        self.crossMountPoints = crossMountPoints
        self.fixedSizeMountPoints = fixedSizeMountPoints
        self.startupDisk = startupDisk
    }

    public static var defaultWorkerCount: Int {
        // Measured on APFS/NVMe: throughput plateaus around 8–12 workers; more threads only add kernel lock contention.
        min(12, max(4, ProcessInfo.processInfo.activeProcessorCount * 2 / 3))
    }
}

/// Live counters, safe to poll from the UI while a scan runs.
public final class ScanProgress: Sendable {
    let files = Atomic<Int>(0)
    let directories = Atomic<Int>(0)
    let bytes = Atomic<UInt64>(0)
    let restricted = Atomic<Int>(0)
    let restrictedSample = Mutex<[String]>([])

    public var fileCount: Int { files.load(ordering: .relaxed) }
    public var directoryCount: Int { directories.load(ordering: .relaxed) }
    public var byteCount: UInt64 { bytes.load(ordering: .relaxed) }
    /// Folders that couldn't be opened (permissions / privacy protection).
    public var restrictedCount: Int { restricted.load(ordering: .relaxed) }
    /// Up to 50 of those folders' paths.
    public var restrictedPaths: [String] { restrictedSample.withLock { $0 } }

    func noteRestricted(_ path: String) {
        restricted.add(1, ordering: .relaxed)
        restrictedSample.withLock { if $0.count < 50 { $0.append(path) } }
    }
}

/// Parallel filesystem scanner modelled on DaisyDisk's approach:
/// `getattrlistbulk` per directory, a fixed pool of worker threads pulling from a shared LIFO stack,
/// depth-first continuation (a worker keeps one child directory for itself), allocated sizes,
/// hard links counted once, and mount points not crossed.
public final class DiskScanner: @unchecked Sendable {
    public let rootPath: String
    public let options: ScanOptions
    public let progress = ScanProgress()

    private let cancelled = Atomic<Bool>(false)
    private let seenHardLinks = Mutex<Set<UInt64>>([])
    private let stack = WorkStack()

    public init(path: String, options: ScanOptions = ScanOptions()) {
        var p = (path as NSString).standardizingPath
        if p.isEmpty { p = "/" }
        rootPath = p
        self.options = options
    }

    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        stack.cancel()
    }

    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    /// Runs the scan on dedicated threads without blocking the caller's executor.
    public func scan() async throws -> FileTree {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let thread = Thread { [self] in
                    continuation.resume(with: Result { try run() })
                }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            cancel()
        }
    }

    /// Blocking scan. Returns a finalized tree (sizes rolled up, children sorted).
    public func run() throws -> FileTree {
        let probe = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard probe >= 0 else { throw ScanError.cannotOpen(path: rootPath, errno: errno) }
        close(probe)

        let rootArena = Arena(id: 0)
        let displayName = rootPath == "/" ? "/" : (rootPath as NSString).lastPathComponent
        let nameBytes = Array(displayName.utf8)
        let nameOffset = nameBytes.withUnsafeBytes { rootArena.appendName($0.baseAddress!, count: $0.count) }
        let root = rootArena.append(Node(
            size: 0, parent: .none, firstChild: .none, childCount: 0, descendantCount: 0,
            nameOffset: nameOffset, nameLength: UInt16(nameBytes.count), flags: .directory))

        let workerArenas = (1...options.workerCount).map { Arena(id: $0) }
        let arenas = [rootArena] + workerArenas
        let tree = FileTree(rootPath: rootPath, root: root, arenas: arenas)

        var rootPathBytes = ContiguousArray(rootPath.utf8CString)
        if rootPath == "/" { rootPathBytes = [0] } // children are built as "<parent>/<name>"
        stack.push(DirTask(ref: root, path: rootPathBytes))

        let group = DispatchGroup()
        for arena in workerArenas {
            group.enter()
            let thread = Thread { [self] in
                Worker(scanner: self, tree: tree, arena: arena).run()
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.stackSize = 1 << 20
            thread.start()
        }
        group.wait()

        for arena in workerArenas { arena.dropInternTable() }
        if isCancelled { throw ScanError.cancelled }
        let finalizeStart = ContinuousClock.now
        tree.finalize()
        if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
            FileHandle.standardError.write("\nfinalize: \(ContinuousClock.now - finalizeStart)\n".data(using: .utf8)!)
        }
        return tree
    }

    // MARK: - Worker

    private struct Worker {
        let scanner: DiskScanner
        let tree: FileTree
        let arena: Arena

        func run() {
            // Never download dataless (iCloud / File Provider) files, and don't touch atime.
            setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_THREAD, IOPOL_ATIME_UPDATES_OFF)

            let bufferSize = scanner.options.bufferSize
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
            defer { buffer.deallocate() }
            var childDirs: [DirTask] = []

            while let task = scanner.stack.pop() {
                var current: DirTask? = task
                while let t = current, !scanner.isCancelled {
                    childDirs.removeAll(keepingCapacity: true)
                    enumerate(t, buffer: buffer, bufferSize: bufferSize, into: &childDirs)
                    // Depth-first continuation: keep one child, share the rest.
                    current = childDirs.popLast()
                    if !childDirs.isEmpty { scanner.stack.push(contentsOf: childDirs) }
                }
                scanner.stack.finish()
            }
        }

        /// `/.nofollow`, `/.resolve` and `/.vol` are kernel path-resolution namespaces, not real folders.
        /// "/System/Volumes/Data" as C chars (DirTask paths are NUL-terminated CChar arrays).
        static let dataRootBytes = ContiguousArray(Firmlinks.dataRoot.utf8CString.dropLast())

        private static func isMagicRootEntry(_ name: UnsafeRawPointer, _ length: Int) -> Bool {
            let bytes = UnsafeRawBufferPointer(start: name, count: length)
            return bytes.elementsEqual(".nofollow".utf8) || bytes.elementsEqual(".resolve".utf8) || bytes.elementsEqual(".vol".utf8)
        }

        private func enumerate(_ task: DirTask, buffer: UnsafeMutableRawPointer, bufferSize: Int, into childDirs: inout [DirTask]) {
            let dirNode = tree.pointer(task.ref)
            let fd: Int32 = task.path.withUnsafeBufferPointer { p in
                // Root "/" is stored as an empty string so children join cleanly.
                p.count == 1 ? open("/", O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
                    : open(p.baseAddress!, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_CLOEXEC)
            }
            guard fd >= 0 else {
                dirNode.pointee.flags.insert(.restricted)
                scanner.progress.noteRestricted(task.path.count == 1 ? "/" : task.path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
                return
            }
            defer { close(fd) }

            var attrs = attrlist()
            attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
            attrs.commonattr = Attr.common
            attrs.dirattr = Attr.dir
            attrs.fileattr = Attr.file

            var firstChild = NodeRef.none
            var childCount: UInt32 = 0
            var files = 0
            var dirs = 0
            var bytes: UInt64 = 0
            let crossMounts = scanner.options.crossMountPoints
            let fixedMounts = scanner.options.fixedSizeMountPoints
            let isFilesystemRoot = task.path.count == 1
            // Data-volume folders that contain firmlinked entries (cheap byte-prefix test before building a String).
            var firmlinkParent: String?
            if scanner.options.startupDisk, task.path.starts(with: Self.dataRootBytes) {
                let path = task.path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if Firmlinks.parentsOfTargets.contains(path) { firmlinkParent = path }
            }

            while true {
                let count = getattrlistbulk(fd, &attrs, buffer, bufferSize, UInt64(FSOPT_NOFOLLOW))
                if count == 0 { break }
                if count < 0 {
                    dirNode.pointee.flags.insert(.partial)
                    break
                }
                var entry = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    let length = Int(entry.loadUnaligned(as: UInt32.self))
                    defer { entry += length }
                    var field = entry + 4
                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field += MemoryLayout<attribute_set_t>.size

                    if returned.commonattr & Attr.error != 0 {
                        let err = field.loadUnaligned(as: UInt32.self)
                        field += 4
                        if err != 0 { continue }
                    }
                    guard returned.commonattr & Attr.name != 0 else { continue }
                    let nameRef = field.loadUnaligned(as: attrreference_t.self)
                    let namePtr = field + Int(nameRef.attr_dataoffset)
                    let nameLength = max(0, Int(nameRef.attr_length) - 1) // drop trailing NUL
                    field += MemoryLayout<attrreference_t>.size
                    if isFilesystemRoot && Self.isMagicRootEntry(namePtr, nameLength) { continue }
                    if let parent = firmlinkParent {
                        let name = String(decoding: UnsafeRawBufferPointer(start: namePtr, count: nameLength), as: UTF8.self)
                        if Firmlinks.isFirmlinked(name, in: parent) { continue } // counted at /
                    }

                    var objType: UInt32 = 0
                    if returned.commonattr & Attr.objType != 0 {
                        objType = field.loadUnaligned(as: UInt32.self)
                        field += 4
                    }
                    var fileID: UInt64 = 0
                    if returned.commonattr & Attr.fileID != 0 {
                        fileID = field.loadUnaligned(as: UInt64.self)
                        field += 8
                    }

                    var flags: NodeFlags = []
                    var size: UInt64 = 0
                    let isDir = objType == Attr.vdir
                    if isDir {
                        flags.insert(.directory)
                        if returned.dirattr & Attr.mountStatus != 0 {
                            let status = field.loadUnaligned(as: UInt32.self)
                            field += 4
                            if status & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0 { flags.insert(.mountPoint) }
                        }
                        dirs += 1
                    } else {
                        if objType == Attr.vlnk { flags.insert(.symlink) }
                        var linkCount: UInt32 = 1
                        if returned.fileattr & Attr.linkCount != 0 {
                            linkCount = field.loadUnaligned(as: UInt32.self)
                            field += 4
                        }
                        if returned.fileattr & Attr.allocSize != 0 {
                            size = UInt64(max(0, field.loadUnaligned(as: Int64.self)))
                            field += 8
                        }
                        if linkCount > 1 {
                            let isFirst = scanner.seenHardLinks.withLock { $0.insert(fileID).inserted }
                            if !isFirst {
                                flags.insert(.hardLinkDuplicate)
                                size = 0
                            }
                        }
                        files += 1
                        bytes &+= size
                    }

                    if flags.contains(.mountPoint) && !fixedMounts.isEmpty {
                        let child = DirTask(ref: .none, parentPath: task.path, name: namePtr, nameLength: nameLength)
                        let childPath = child.path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                        if let known = fixedMounts[childPath] {
                            size = known
                            flags.insert(.otherVolume)
                            bytes &+= known
                        }
                    }

                    let nameOffset = arena.internName(namePtr, count: nameLength)
                    let ref = arena.append(Node(
                        size: size, parent: task.ref, firstChild: .none, childCount: 0, descendantCount: 0,
                        nameOffset: nameOffset, nameLength: UInt16(nameLength), flags: flags))
                    if firstChild.isNone { firstChild = ref }
                    childCount += 1

                    var descend = crossMounts || !flags.contains(.mountPoint)
                    if !descend && scanner.options.startupDisk {
                        // The startup disk's Data volume: scanned too, minus its firmlinked entries.
                        let child = DirTask(ref: .none, parentPath: task.path, name: namePtr, nameLength: nameLength)
                        descend = child.path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } == Firmlinks.dataRoot
                    }
                    if isDir && descend {
                        childDirs.append(DirTask(ref: ref, parentPath: task.path, name: namePtr, nameLength: nameLength))
                    }
                }
            }

            dirNode.pointee.firstChild = firstChild
            dirNode.pointee.childCount = childCount
            scanner.progress.files.add(files, ordering: .relaxed)
            scanner.progress.directories.add(dirs, ordering: .relaxed)
            scanner.progress.bytes.add(bytes, ordering: .relaxed)
        }
    }
}

// MARK: - Attribute constants (spelled out to avoid signedness quirks of the imported macros)

private enum Attr {
    static let name: attrgroup_t = 0x0000_0001        // ATTR_CMN_NAME
    static let objType: attrgroup_t = 0x0000_0008     // ATTR_CMN_OBJTYPE
    static let fileID: attrgroup_t = 0x0200_0000      // ATTR_CMN_FILEID
    static let error: attrgroup_t = 0x2000_0000       // ATTR_CMN_ERROR
    static let returnedAttrs: attrgroup_t = 0x8000_0000 // ATTR_CMN_RETURNED_ATTRS
    static let common: attrgroup_t = returnedAttrs | name | error | objType | fileID

    static let mountStatus: attrgroup_t = 0x0000_0004 // ATTR_DIR_MOUNTSTATUS
    static let dir: attrgroup_t = mountStatus

    static let linkCount: attrgroup_t = 0x0000_0001   // ATTR_FILE_LINKCOUNT
    static let allocSize: attrgroup_t = 0x0000_0004   // ATTR_FILE_ALLOCSIZE
    static let file: attrgroup_t = linkCount | allocSize

    static let vdir: UInt32 = 2 // VDIR
    static let vlnk: UInt32 = 5 // VLNK
}

// MARK: - Work stack

struct DirTask: @unchecked Sendable {
    let ref: NodeRef
    /// NUL-terminated absolute path ("" for the filesystem root).
    let path: ContiguousArray<CChar>

    init(ref: NodeRef, path: ContiguousArray<CChar>) {
        self.ref = ref
        self.path = path
    }

    init(ref: NodeRef, parentPath: ContiguousArray<CChar>, name: UnsafeRawPointer, nameLength: Int) {
        self.ref = ref
        let parentLength = parentPath.count - 1
        var p = ContiguousArray<CChar>()
        p.reserveCapacity(parentLength + nameLength + 2)
        p.append(contentsOf: parentPath[0..<parentLength])
        p.append(0x2F) // "/"
        p.append(contentsOf: UnsafeBufferPointer(start: name.assumingMemoryBound(to: CChar.self), count: nameLength))
        p.append(0)
        path = p
    }
}

/// LIFO stack shared by all workers. `pop` blocks until work is available or the scan is complete
/// (stack empty and no worker still enumerating).
final class WorkStack: @unchecked Sendable {
    private let condition = NSCondition()
    private var tasks: [DirTask] = []
    private var active = 0
    private var finished = false

    func push(_ task: DirTask) {
        condition.lock()
        tasks.append(task)
        condition.signal()
        condition.unlock()
    }

    func push(contentsOf newTasks: [DirTask]) {
        condition.lock()
        tasks.append(contentsOf: newTasks)
        if newTasks.count == 1 { condition.signal() } else { condition.broadcast() }
        condition.unlock()
    }

    func pop() -> DirTask? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if finished { return nil }
            if let task = tasks.popLast() {
                active += 1
                return task
            }
            if active == 0 {
                finished = true
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    func finish() {
        condition.lock()
        active -= 1
        if active == 0 && tasks.isEmpty {
            finished = true
            condition.broadcast()
        }
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        tasks.removeAll()
        finished = true
        condition.broadcast()
        condition.unlock()
    }
}
