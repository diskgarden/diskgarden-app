import Darwin
import Foundation
import ScanEngine

// DiskGardenHelper — runs as root (launched through an administrator-authorization prompt) to scan folders the
// app can't read, and hands the results back as a TreeArchive.
//
//   DiskGardenHelper scan <out-fifo> <owner-uid> <paths-file> [--fixed <mount-path>=<bytes>]...
//
// <paths-file> lists absolute paths, one per line. <out-fifo> is a named pipe the app created (owned by <owner-uid>)
// and reads from while the archive is written: results never touch the disk, so this works on a full disk too.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("DiskGardenHelper: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 5, args[1] == "scan", let uid = uid_t(args[3]) else {
    fail("usage: DiskGardenHelper scan <out-fifo> <owner-uid> <paths-file> [--fixed <path>=<bytes>]...", code: 64)
}
let outPath = args[2]
guard outPath.hasPrefix("/") else { fail("out-fifo must be absolute") }
// Root only ever writes into the caller's own named pipe: never a file, device or symlink.
var outInfo = stat()
guard lstat(outPath, &outInfo) == 0, outInfo.st_mode & S_IFMT == S_IFIFO, outInfo.st_uid == uid else {
    fail("out-fifo must be a named pipe owned by the caller")
}

var fixed: [String: UInt64] = [:]
var index = 5
while index < args.count {
    guard args[index] == "--fixed", index + 1 < args.count else { fail("unexpected argument \(args[index])", code: 64) }
    let pair = args[index + 1].split(separator: "=", maxSplits: 1)
    guard pair.count == 2, let bytes = UInt64(pair[1]) else { fail("bad --fixed value", code: 64) }
    fixed[String(pair[0])] = bytes
    index += 2
}

guard let list = try? String(contentsOfFile: args[4], encoding: .utf8) else { fail("can't read paths file") }
let paths = list.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }

var entries: [(path: String, tree: FileTree)] = []
for path in paths {
    // Part of a scan of / when it's / itself or inside the Data volume (whose firmlinked entries are counted at /).
    let startupDisk = path == "/" || path == Firmlinks.dataRoot || path.hasPrefix(Firmlinks.dataRoot + "/")
    let scanner = DiskScanner(path: path, options: ScanOptions(fixedSizeMountPoints: fixed, startupDisk: startupDisk))
    if let tree = try? scanner.run() { entries.append((path, tree)) }
}

// Opening blocks until the app is reading. Checked again on the open descriptor, in case the path was swapped.
let fd = open(outPath, O_WRONLY | O_NOFOLLOW)
guard fd >= 0 else { fail("can't open out-fifo: \(String(cString: strerror(errno)))") }
guard fstat(fd, &outInfo) == 0, outInfo.st_mode & S_IFMT == S_IFIFO, outInfo.st_uid == uid else {
    fail("out-fifo must be a named pipe owned by the caller")
}
let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
do {
    try TreeArchive.write(entries) { try out.write(contentsOf: $0) }
    try out.close()
} catch {
    fail("can't write archive: \(error)")
}
print("scanned \(entries.count) of \(paths.count) paths")
