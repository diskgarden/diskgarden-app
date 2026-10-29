import Foundation

/// Locations the Waste bin refuses: OS-owned paths, the home directory and the standard folders directly
/// inside it. `ReportModel.collectionBlocker` turns a hit here into the notice the user sees.
enum ProtectedPaths {
    private static let home = NSHomeDirectory()

    private static let exact: Set<String> = Set<String>([
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores", "/dev", "/etc",
        "/home", "/opt", "/private", "/private/etc", "/private/tmp", "/private/var", "/sbin", "/tmp", "/usr", "/var",
        home,
    ]).union(["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public"]
        .map { (home as NSString).appendingPathComponent($0) })

    /// Whole subtrees that belong to the OS.
    private static let prefixes = ["/System/", "/bin/", "/sbin/", "/usr/", "/private/var/db/", "/Library/Apple/"]
    private static let allowedPrefixes = ["/usr/local/"]

    static func isProtected(_ path: String) -> Bool {
        let normalized = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if exact.contains(normalized) { return true }
        if allowedPrefixes.contains(where: { normalized.hasPrefix($0) }) { return false }
        return prefixes.contains { normalized.hasPrefix($0) }
    }
}
