import Foundation

/// The startup disk's Data volume is mounted at /System/Volumes/Data, and most of its top level is also reachable
/// from / through firmlinks (/Users, /Applications, /Library, …, listed in /usr/share/firmlinks). A few items exist
/// only on the Data volume (`macOS Install Data`, `.PreviousSystemInformation`, `MobileSoftwareUpdate`, …), so a scan
/// of / descends into /System/Volumes/Data too, skipping exactly the firmlinked entries — counted once, at /.
public enum Firmlinks {
    public static let dataRoot = "/System/Volumes/Data"

    /// Absolute paths under the Data volume that are firmlinked to / (e.g. "/System/Volumes/Data/Users").
    public static let dataTargets: Set<String> = {
        var targets = Set<String>()
        if let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                if parts.count == 2 { targets.insert(dataRoot + "/" + parts[1].trimmingCharacters(in: .whitespaces)) }
            }
        }
        if targets.isEmpty { // fallback: the long-standing set
            for t in ["Applications", "Library", "Users", "Volumes", "cores", "opt", "private", "usr/local", "System/Library/Caches",
                      "System/Library/Assets", "System/Library/PreinstalledAssets", "System/Library/AssetsV2",
                      "System/Library/PreinstalledAssetsV2", "System/Library/Speech"] {
                targets.insert(dataRoot + "/" + t)
            }
        }
        return targets
    }()

    /// Directories whose listing contains a firmlinked entry (the Data root and the targets' ancestors).
    public static let parentsOfTargets: Set<String> = {
        var parents = Set<String>()
        for target in dataTargets {
            var p = (target as NSString).deletingLastPathComponent
            while p.count >= dataRoot.count {
                parents.insert(p)
                if p == dataRoot { break }
                p = (p as NSString).deletingLastPathComponent
            }
        }
        return parents
    }()

    /// Whether `name` inside `directory` is a firmlinked Data-volume entry (and so already counted at /).
    public static func isFirmlinked(_ name: String, in directory: String) -> Bool {
        parentsOfTargets.contains(directory) && dataTargets.contains(directory + "/" + name)
    }

    /// FSEvents reports changes in firmlinked folders under /System/Volumes/Data; map those back to their / path.
    /// Paths of Data-only items stay where they are (they're scanned under /System/Volumes/Data).
    public static func pathInScanOfRoot(_ path: String) -> String {
        guard path.hasPrefix(dataRoot + "/") else { return path }
        for target in dataTargets where path == target || path.hasPrefix(target + "/") {
            return String(path.dropFirst(dataRoot.count))
        }
        return path
    }
}
