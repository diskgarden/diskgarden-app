import Darwin
import Foundation
import CRemovefile // removefile(3) with the macOS 26 SDK too (CI runs Xcode 26)

public enum DeletionMode: String, Sendable, CaseIterable {
    /// Recoverable: items go to the user's Trash.
    case moveToTrash
    /// DaisyDisk's behavior: items are removed immediately and cannot be recovered.
    case permanent
}

public struct DeletionOutcome: Sendable, Equatable {
    public let path: String
    /// nil on success (a path that was already gone counts as success).
    public let error: String?

    public var succeeded: Bool { error == nil }
}

public enum Deleter {
    /// Deletes each path, reporting per-item outcomes. Runs synchronously — call off the main thread.
    public static func delete(_ paths: [String], mode: DeletionMode, onItemFinished: @Sendable (Int) -> Void = { _ in }) -> [DeletionOutcome] {
        paths.enumerated().map { index, path in
            let outcome = switch mode {
            case .moveToTrash: moveToTrash(path)
            case .permanent: removePermanently(path)
            }
            onItemFinished(index + 1)
            return outcome
        }
    }

    static func moveToTrash(_ path: String) -> DeletionOutcome {
        guard exists(path) else { return DeletionOutcome(path: path, error: nil) }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return DeletionOutcome(path: path, error: nil)
        } catch {
            return DeletionOutcome(path: path, error: error.localizedDescription)
        }
    }

    static func removePermanently(_ path: String) -> DeletionOutcome {
        guard exists(path) else { return DeletionOutcome(path: path, error: nil) }
        if removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 {
            return DeletionOutcome(path: path, error: nil)
        }
        var code = errno
        if code == ENOENT { return DeletionOutcome(path: path, error: nil) }
        // Locked (uchg/uappnd) items refuse unlink; clear user flags throughout and retry once.
        if code == EPERM || code == EACCES {
            clearUserFlags(path)
            if removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE)) == 0 {
                return DeletionOutcome(path: path, error: nil)
            }
            code = errno
        }
        return DeletionOutcome(path: path, error: String(cString: strerror(code)))
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func clearUserFlags(_ path: String) {
        let userFlags = UInt32(UF_IMMUTABLE | UF_APPEND)
        func clear(_ p: String) {
            var st = stat()
            if lstat(p, &st) == 0, st.st_flags & userFlags != 0 {
                lchflags(p, st.st_flags & ~userFlags)
            }
        }
        clear(path)
        clear((path as NSString).deletingLastPathComponent)
        guard let walker = FileManager.default.enumerator(atPath: path) else { return }
        while let relative = walker.nextObject() as? String {
            clear((path as NSString).appendingPathComponent(relative))
        }
    }
}
