import Foundation
import ScanEngine

/// Runs the bundled `DiskGardenHelper` as root for one operation, via the standard administrator prompt.
///
/// This is the interim route until DiskGarden has a real signing identity for a persistent `SMAppService`
/// daemon; each admin action asks for the password once.
enum AdminRunner {
    enum Failure: LocalizedError {
        case helperMissing
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing: String(localized: "The DiskGarden helper is missing from the app bundle.", comment: "Admin scan error")
            case .cancelled: String(localized: "Administrator access was not granted.", comment: "Admin scan error: the password prompt was cancelled")
            case .failed(let message): message
            }
        }
    }

    /// Scans `paths` as root and returns the archived results.
    static func scan(paths: [String], fixedMountPoints: [String: UInt64] = [:], reason: String) async throws -> [TreeArchive.Entry] {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "DiskGardenHelper") else { throw Failure.helperMissing }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskGardenAdmin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workDir) }

        let pathsFile = workDir.appendingPathComponent("paths.txt")
        try paths.joined(separator: "\n").write(to: pathsFile, atomically: true, encoding: .utf8)
        // The helper streams its results through a named pipe: nothing is written to disk, which matters most when
        // the disk is full and this scan is how the user finds what to delete.
        let pipePath = workDir.appendingPathComponent("result.pipe").path
        guard mkfifo(pipePath, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Hold both ends open: reads then wait for the helper instead of seeing end-of-file before it connects, and
        // closing our write end after the helper is gone ends the read even if it never ran.
        let readEnd = open(pipePath, O_RDONLY | O_NONBLOCK)
        guard readEnd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(readEnd, F_SETFL, fcntl(readEnd, F_GETFL) & ~O_NONBLOCK)
        let ownWriteEnd = open(pipePath, O_WRONLY)
        guard ownWriteEnd >= 0 else { close(readEnd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let reading = Task.detached {
            (try? FileHandle(fileDescriptor: readEnd, closeOnDealloc: true).readToEnd()) ?? Data()
        }

        var command = [helper.path, "scan", pipePath, String(getuid()), pathsFile.path].map(shellQuote)
        for (mount, bytes) in fixedMountPoints.sorted(by: { $0.key < $1.key }) {
            command += ["--fixed", shellQuote("\(mount)=\(bytes)")]
        }
        // DG_ADMIN_DRYRUN runs the identical command path without elevation, for scripted tests.
        let elevate = ProcessInfo.processInfo.environment["DG_ADMIN_DRYRUN"] == nil
        let script = "do shell script \(appleScriptString(command.joined(separator: " ")))"
            + (elevate ? " with prompt \(appleScriptString(reason)) with administrator privileges" : "")

        var failure: Error?
        do { try await runOSAScript(script) } catch { failure = error }
        close(ownWriteEnd) // the helper has exited: the read ends once what it wrote is drained
        let data = await reading.value
        if let failure { throw failure }
        return try TreeArchive.read(data)
    }

    private static func runOSAScript(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") {
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
