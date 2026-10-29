import Compression
import Foundation

/// What's remembered about a saved scan (stored as JSON next to the compressed tree).
public struct SavedScanInfo: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public var format = SavedScanInfo.currentFormat
    public var rootPath: String
    public var date: Date
    public var totalBytes: UInt64
    public var nodeCount: UInt64
    /// Identity of the volume that was scanned, so a different disk mounted at the same path isn't mistaken for it.
    public var volumeUUID: String?
    public var restrictedCount: Int
    public var restrictedPaths: [String]
    public var fixedSizeMountPoints: [String: UInt64]
    public var otherVolumes: [APFSVolume]
    /// Paths that were in the Collector when the scan was saved (re-collected after loading).
    public var collectedPaths: [String]

    public init(rootPath: String, date: Date = Date(), totalBytes: UInt64, nodeCount: UInt64, volumeUUID: String?,
                restrictedCount: Int = 0, restrictedPaths: [String] = [], fixedSizeMountPoints: [String: UInt64] = [:],
                otherVolumes: [APFSVolume] = [], collectedPaths: [String] = []) {
        self.rootPath = rootPath
        self.date = date
        self.totalBytes = totalBytes
        self.nodeCount = nodeCount
        self.volumeUUID = volumeUUID
        self.restrictedCount = restrictedCount
        self.restrictedPaths = restrictedPaths
        self.fixedSizeMountPoints = fixedSizeMountPoints
        self.otherVolumes = otherVolumes
        self.collectedPaths = collectedPaths
    }
}

/// Saved scan results: an LZFSE-compressed `TreeArchive` plus JSON metadata per scanned root.
public struct ScanStore: Sendable {
    public let directory: URL
    /// Free space a save leaves untouched: a nearly full disk keeps it for macOS and the user's own files.
    public var reservedFreeSpace: Int64

    public init(directory: URL, reservedFreeSpace: Int64 = 2 << 30) {
        self.directory = directory
        self.reservedFreeSpace = reservedFreeSpace
    }

    /// ~/Library/Application Support/DiskGarden/Scans
    public static var standard: ScanStore { standard(appFolder: "DiskGarden") }

    /// ~/Library/Application Support/<appFolder>/Scans (the debug app keeps its own: "DiskGarden Debug").
    public static func standard(appFolder: String) -> ScanStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ScanStore(directory: base.appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("Scans", isDirectory: true))
    }

    public static func volumeUUID(for path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    }

    // MARK: Files

    /// Stable file name for a root path (FNV-1a hash; Swift's `hashValue` is randomized per launch).
    public static func key(_ rootPath: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rootPath.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(format: "%016llx", hash)
    }

    func treeURL(_ rootPath: String) -> URL { directory.appendingPathComponent(Self.key(rootPath) + ".dgscan") }
    func infoURL(_ rootPath: String) -> URL { directory.appendingPathComponent(Self.key(rootPath) + ".json") }

    // MARK: API

    /// Whether `nodeCount` nodes can be saved without eating into `reservedFreeSpace`. Saved scans are only a
    /// convenience, so this counts free space the system wouldn't have to purge to make room.
    public func hasRoom(forNodes nodeCount: UInt64) -> Bool {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey]))?
            .volumeAvailableCapacityForOpportunisticUsage else { return true }
        // ~48 bytes per node uncompressed (name + record), an upper bound for the LZFSE file.
        return free >= reservedFreeSpace + Int64(clamping: nodeCount) * 48
    }

    public func save(_ tree: FileTree, info: SavedScanInfo) throws {
        guard hasRoom(forNodes: info.nodeCount) else {
            // Keep the result in memory only, and drop the older saved copy: it would come back later as if it were
            // the latest, and it takes space the disk doesn't have.
            delete(info.rootPath)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Unique temporary name, so two saves (or two app instances) never write the same partial file.
        let temporary = treeURL(info.rootPath).appendingPathExtension("\(getpid()).\(UUID().uuidString.prefix(8)).partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            let filter = try OutputFilter(.compress, using: .lzfse) { chunk in
                if let chunk { try handle.write(contentsOf: chunk) }
            }
            try TreeArchive.write([(info.rootPath, tree)]) { try filter.write($0) }
            try filter.finalize()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        // rename(2) replaces the old file atomically: a reader (or a crash) never sees a missing or half-written scan.
        guard rename(temporary.path, treeURL(info.rootPath).path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        let encoder = JSONEncoder()
        try encoder.encode(info).write(to: infoURL(info.rootPath), options: .atomic)
    }

    /// Metadata of the saved scan for `rootPath`, if one exists and still matches the mounted volume.
    public func info(for rootPath: String) -> SavedScanInfo? {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: infoURL(rootPath)),
              let info = try? decoder.decode(SavedScanInfo.self, from: data),
              info.format == SavedScanInfo.currentFormat, info.rootPath == rootPath,
              FileManager.default.fileExists(atPath: treeURL(rootPath).path) else { return nil }
        if let saved = info.volumeUUID, let mounted = Self.volumeUUID(for: rootPath), saved != mounted { return nil }
        return info
    }

    public func loadTree(for rootPath: String) throws -> FileTree {
        let handle = try FileHandle(forReadingFrom: treeURL(rootPath))
        defer { try? handle.close() }
        let filter = try InputFilter(.decompress, using: .lzfse) { length in
            try handle.read(upToCount: length)
        }
        var data = Data()
        while let page = try filter.readData(ofLength: 1 << 20), !page.isEmpty { data.append(page) }
        guard let entry = try TreeArchive.read(data).first else { throw TreeArchive.ArchiveError.truncated }
        return try FileTree.fromArchive(entry)
    }

    /// Rewrites only the metadata (e.g. when the Collector changes) — cheap, the tree file is untouched.
    public func updateInfo(_ info: SavedScanInfo) {
        guard FileManager.default.fileExists(atPath: treeURL(info.rootPath).path),
              let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: infoURL(info.rootPath), options: .atomic)
    }

    /// Removes saved scans made before `date` (and any whose metadata can't be read), plus abandoned partial saves.
    public func deleteScans(olderThan date: Date) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // Leftovers of saves that were interrupted (an hour old, so a save in progress elsewhere is left alone).
        for file in files where file.pathExtension == "partial" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < Date().addingTimeInterval(-3600) { try? FileManager.default.removeItem(at: file) }
        }
        for file in files where file.pathExtension == "json" {
            let info = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(SavedScanInfo.self, from: $0) }
            guard info.map({ $0.date < date }) ?? true else { continue }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("dgscan"))
        }
    }

    /// Removes every saved scan.
    public func deleteAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["dgscan", "json"].contains(file.pathExtension) { try? FileManager.default.removeItem(at: file) }
    }

    public func delete(_ rootPath: String) {
        try? FileManager.default.removeItem(at: treeURL(rootPath))
        try? FileManager.default.removeItem(at: infoURL(rootPath))
    }
}
