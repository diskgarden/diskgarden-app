import Darwin
import Foundation
import ScanEngine

// dgscan — command-line harness for the scan engine.
//
//   dgscan <path> [--workers N] [--buffer KB] [--top N] [--depth N] [--du] [--cross-mounts]

struct Arguments {
    var path = FileManager.default.currentDirectoryPath
    var workers = ScanOptions.defaultWorkerCount
    var bufferKB = 64
    var top = 10
    var depth = 1
    var compareWithDu = false
    var crossMounts = false
    var storeBenchmark = false

    init(_ argv: [String]) {
        var it = argv.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--workers": workers = Int(it.next() ?? "") ?? workers
            case "--buffer": bufferKB = Int(it.next() ?? "") ?? bufferKB
            case "--top": top = Int(it.next() ?? "") ?? top
            case "--depth": depth = Int(it.next() ?? "") ?? depth
            case "--du": compareWithDu = true
            case "--cross-mounts": crossMounts = true
            case "--store": storeBenchmark = true
            case "-h", "--help":
                print("usage: dgscan <path> [--workers N] [--buffer KB] [--top N] [--depth N] [--du] [--cross-mounts]")
                exit(0)
            default: path = arg
            }
        }
    }
}

func residentFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

func printTree(_ tree: FileTree, _ ref: NodeRef, depth: Int, maxDepth: Int, top: Int) {
    let children = tree.children(ref)
    for child in children.prefix(top) {
        let indent = String(repeating: "  ", count: depth)
        let marker = tree.isDirectory(child) ? "▸" : "·"
        let size = ByteSize.parts(tree.size(child))
        let flags = tree.flags(child)
        var note = ""
        if flags.contains(.restricted) { note += " [restricted]" }
        if flags.contains(.mountPoint) { note += " [mount]" }
        print("\(indent)\(marker) \(size.number.leftPadded(7)) \(size.unit.rightPadded(5)) \(tree.name(child))\(note)")
        if depth + 1 < maxDepth, tree.isDirectory(child) {
            printTree(tree, child, depth: depth + 1, maxDepth: maxDepth, top: top)
        }
    }
    if children.count > top {
        let rest = children.dropFirst(top).reduce(UInt64(0)) { $0 + tree.size($1) }
        print("\(String(repeating: "  ", count: depth))  \(ByteSize.string(rest)) in \(children.count - top) smaller objects")
    }
}

extension String {
    func leftPadded(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
    func rightPadded(_ n: Int) -> String { count >= n ? self : self + String(repeating: " ", count: n - count) }
}

let args = Arguments(CommandLine.arguments)
if let root = ProcessInfo.processInfo.environment["DG_LOAD_ONLY"] {
    // Time loading the app's saved scan for `root` (diagnostics).
    let t = ContinuousClock.now
    do {
        let tree = try ScanStore.standard.loadTree(for: root)
        print("loaded \(tree.nodeCount) nodes, \(ByteSize.string(tree.size(tree.root))) in \(ContinuousClock.now - t)")
    } catch { print("load failed after \(ContinuousClock.now - t): \(error)") }
    exit(0)
}
// Size sibling APFS volumes mounted below the root (e.g. /System/Volumes/VM) like the app does.
let accounting = ContainerAccounting(root: args.path, volumes: APFSContainer.volumes(sharingContainerWith: args.path))
let options = ScanOptions(workerCount: args.workers, bufferSize: args.bufferKB * 1024, crossMountPoints: args.crossMounts,
                          fixedSizeMountPoints: accounting.fixedSizeMountPoints, startupDisk: args.path == "/")
let scanner = DiskScanner(path: args.path, options: options)

/// Background progress + Ctrl-C handling. Kept out of top-level code so the closures are not main-actor isolated.
nonisolated func startMonitoring(_ scanner: DiskScanner) -> (DispatchSourceSignal, DispatchSourceTimer) {
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { scanner.cancel() }
    sigint.resume()

    let ticker = DispatchSource.makeTimerSource(queue: .global())
    ticker.schedule(deadline: .now() + 0.25, repeating: 0.25)
    ticker.setEventHandler {
        let p = scanner.progress
        FileHandle.standardError.write("\r\u{1B}[K  \(p.fileCount) files, \(p.directoryCount) folders, \(ByteSize.string(p.byteCount))".data(using: .utf8)!)
    }
    ticker.resume()
    return (sigint, ticker)
}

let (sigint, ticker) = startMonitoring(scanner)

let memoryBefore = residentFootprint()
let start = ContinuousClock.now
let tree: FileTree
do {
    tree = try scanner.run()
} catch {
    ticker.cancel()
    FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)
    print("scan failed: \(error)")
    exit(1)
}
let elapsed = ContinuousClock.now - start
ticker.cancel()
FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!)
let memoryAfter = residentFootprint()

let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
let nodes = tree.nodeCount
print("path      \(tree.rootPath)")
print("total     \(ByteSize.string(tree.size(tree.root)))  (\(tree.size(tree.root)) bytes)")
print("items     \(nodes) nodes — \(scanner.progress.fileCount) files, \(scanner.progress.directoryCount) folders")
print("time      \(String(format: "%.2f", seconds)) s  (\(Int(Double(nodes) / max(seconds, 0.001))) items/s, \(options.workerCount) workers, \(args.bufferKB) KB buffer)")
print("restricted \(scanner.progress.restrictedCount) folders; other volumes \(ByteSize.string(accounting.otherVolumesBytes))")
print("memory    arenas \(ByteSize.string(UInt64(tree.memoryFootprint))) (\(tree.memoryFootprint / max(nodes, 1)) B/node), process +\(ByteSize.string(memoryAfter &- memoryBefore))")
print("")
print("\(ByteSize.string(tree.size(tree.root)))  \(tree.name(tree.root))")
printTree(tree, tree.root, depth: 0, maxDepth: args.depth, top: args.top)

// Sunburst layout cost at the root and at the largest child (what the UI computes on every zoom).
for focus in [tree.root] + Array(tree.children(tree.root).prefix(1)) {
    let t = ContinuousClock.now
    let layout = SunburstLayout(tree: tree, focus: focus)
    let segments = layout.rings.reduce(0) { $0 + $1.count }
    print("layout    \(tree.name(focus)): \(segments) segments in \(layout.rings.count) rings, \(ContinuousClock.now - t)")
}

if ProcessInfo.processInfo.environment["DG_NAME_STATS"] != nil {
    var counts: [String: Int] = [:]
    var totalBytes = 0
    var stack = [tree.root]
    while let n = stack.popLast() {
        for c in tree.children(n) {
            let name = tree.name(c)
            counts[name, default: 0] += 1
            totalBytes += name.utf8.count
            if tree.isDirectory(c) { stack.append(c) }
        }
    }
    let uniqueBytes = counts.keys.reduce(0) { $0 + $1.utf8.count }
    print("names     \(nodes) total, \(counts.count) unique; name bytes \(ByteSize.string(UInt64(totalBytes))) → \(ByteSize.string(UInt64(uniqueBytes))) if deduplicated")
    print("top       " + counts.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: ", "))
}

if args.storeBenchmark {
    let store = ScanStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("dgscan-store"))
    let info = SavedScanInfo(rootPath: tree.rootPath, totalBytes: tree.size(tree.root),
                             nodeCount: UInt64(tree.descendantCount(tree.root) + 1), volumeUUID: ScanStore.volumeUUID(for: tree.rootPath))
    var t = ContinuousClock.now
    try store.save(tree, info: info)
    let saveTime = ContinuousClock.now - t
    let bytes = (try? FileManager.default.attributesOfItem(atPath: store.directory.path + "/" + ScanStore.key(tree.rootPath) + ".dgscan")[.size] as? UInt64) ?? 0
    t = ContinuousClock.now
    let reloaded = try store.loadTree(for: tree.rootPath)
    let loadTime = ContinuousClock.now - t
    print("store     saved \(ByteSize.string(bytes)) in \(saveTime); reloaded \(reloaded.nodeCount) nodes in \(loadTime); sizes match: \(reloaded.size(reloaded.root) == tree.size(tree.root))")
    store.delete(tree.rootPath)
}

if args.compareWithDu {
    let du = Process()
    du.executableURL = URL(fileURLWithPath: "/usr/bin/du")
    du.arguments = ["-skx", args.path]
    let pipe = Pipe()
    du.standardOutput = pipe
    du.standardError = FileHandle.nullDevice
    let duStart = ContinuousClock.now
    try du.run()
    du.waitUntilExit()
    let duElapsed = ContinuousClock.now - duStart
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if let kb = UInt64(output.split(separator: "\t").first ?? "") {
        let duBytes = kb * 1024
        let ours = tree.size(tree.root)
        let diff = (Double(ours) - Double(duBytes)) / Double(max(duBytes, 1)) * 100
        print("")
        print("du -skx   \(ByteSize.string(duBytes))  (\(duBytes) bytes) in \(duElapsed)")
        print("delta     \(String(format: "%+.3f", diff))%")
    }
}
