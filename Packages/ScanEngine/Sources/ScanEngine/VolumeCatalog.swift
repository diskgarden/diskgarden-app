import DiskArbitration
import Foundation
import IOKit

/// A mounted volume as shown in the Sources list.
public struct VolumeInfo: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let url: URL
    public let path: String
    public let name: String
    public let totalCapacity: Int64
    /// Free space right now (`volumeAvailableCapacity`).
    public let availableCapacity: Int64
    /// Free + purgeable (`volumeAvailableCapacityForImportantUsage`).
    public let importantAvailableCapacity: Int64
    public let isRoot: Bool
    public let isEncrypted: Bool
    public let isReadOnly: Bool
    public let isLocal: Bool
    public let isInternal: Bool
    public let isEjectable: Bool
    public let kind: VolumeKind
    /// Solid state vs rotational, from IOKit's device characteristics (nil if unknown, e.g. network).
    public var isSolidState: Bool? = nil

    /// Parallel directory reads help SSDs but make spinning disks, network shares and optical media seek-thrash.
    public var recommendedWorkerCount: Int {
        if kind.isNetwork || isSolidState == false { return 4 }
        if [.dvd, .cd, .bluRay].contains(kind) { return 2 }
        return ScanOptions.defaultWorkerCount
    }

    public var usedBytes: Int64 { max(0, totalCapacity - availableCapacity) }
    public var freeBytes: Int64 { max(availableCapacity, importantAvailableCapacity) }
    public var usedFraction: Double { totalCapacity > 0 ? Double(totalCapacity - freeBytes) / Double(totalCapacity) : 0 }

    /// "encrypted startup disk", "read-only disk image", "USB disk", …
    public var descriptor: String {
        var words: [String] = []
        if isEncrypted { words.append("encrypted") }
        // Disk images and optical media are inherently read-only; DaisyDisk doesn't call that out.
        if isReadOnly && !isRoot && ![.diskImage, .dvd, .cd, .bluRay].contains(kind) { words.append("read-only") }
        words.append(kind.label)
        return words.joined(separator: " ")
    }
}

public enum VolumeKind: Hashable, Sendable {
    case startupDisk, localDisk, usbDisk, thunderboltDisk, fireWireDisk, sdCard, diskImage
    case dvd, cd, bluRay, ntfsDisk, fatDisk, timeMachine
    case appleShare, smbShare, nfsShare, webDAVShare, networkDisk
    case other(String)

    public var label: String {
        switch self {
        case .startupDisk: "startup disk"
        case .localDisk: "local disk"
        case .usbDisk: "USB disk"
        case .thunderboltDisk: "Thunderbolt disk"
        case .fireWireDisk: "FireWire disk"
        case .sdCard: "SD card"
        case .diskImage: "disk image"
        case .dvd: "DVD"
        case .cd: "data CD"
        case .bluRay: "Blu-ray disk"
        case .ntfsDisk: "NTFS disk"
        case .fatDisk: "FAT disk"
        case .timeMachine: "Time Machine volume"
        case .appleShare: "Apple network share"
        case .smbShare: "Windows network share"
        case .nfsShare: "NFS network disk"
        case .webDAVShare: "WebDAV network share"
        case .networkDisk: "network disk"
        case .other(let fs): "\(fs) volume"
        }
    }

    public var isNetwork: Bool {
        switch self {
        case .appleShare, .smbShare, .nfsShare, .webDAVShare, .networkDisk: true
        default: false
        }
    }
}

public enum VolumeCatalog {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRootFileSystemKey, .volumeIsEncryptedKey,
        .volumeIsReadOnlyKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsEjectableKey,
        .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey,
    ]

    /// Browsable mounted volumes, startup disk first.
    public static func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        return urls.compactMap { info(for: $0, session: session) }
            .sorted { ($0.isRoot ? 0 : 1, $0.name.localizedLowercase) < ($1.isRoot ? 0 : 1, $1.name.localizedLowercase) }
    }

    public static func volume(containing url: URL) -> VolumeInfo? {
        guard let volumeURL = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return info(for: volumeURL, session: DASessionCreate(kCFAllocatorDefault))
    }

    static func info(for url: URL, session: DASession?) -> VolumeInfo? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable ?? true else { return nil }
        let isRoot = v.volumeIsRootFileSystem ?? (url.path == "/")
        let description = session.flatMap { diskDescription(for: url, session: $0) } ?? [:]
        var info = VolumeInfo(
            url: url,
            path: url.path,
            name: v.volumeLocalizedName ?? v.volumeName ?? url.lastPathComponent,
            totalCapacity: Int64(v.volumeTotalCapacity ?? 0),
            availableCapacity: Int64(v.volumeAvailableCapacity ?? 0),
            importantAvailableCapacity: v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0),
            isRoot: isRoot,
            isEncrypted: isEncrypted(url: isRoot ? URL(fileURLWithPath: "/System/Volumes/Data") : url, session: session)
                || (v.volumeIsEncrypted ?? false),
            isReadOnly: v.volumeIsReadOnly ?? false,
            isLocal: v.volumeIsLocal ?? true,
            isInternal: v.volumeIsInternal ?? false,
            isEjectable: v.volumeIsEjectable ?? false,
            kind: classify(url: url, isRoot: isRoot, isLocal: v.volumeIsLocal ?? true, description: description))
        info.isSolidState = (description[kDADiskDescriptionMediaBSDNameKey as String] as? String).flatMap(isSolidState(bsdName:))
        return info
    }

    /// Walks from the volume's IOMedia up the registry to the block storage device's "Medium Type".
    static func isSolidState(bsdName: String) -> Bool? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let characteristics = IORegistryEntrySearchCFProperty(
            media, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault, options) as? [String: Any],
              let medium = characteristics["Medium Type"] as? String else { return nil }
        return medium == "Solid State"
    }

    /// Encrypted at rest (FileVault or Apple Silicon hardware encryption), read from the IOMedia "Encrypted" property.
    /// For the startup disk pass the Data volume: the root is a sealed system snapshot.
    static func isEncrypted(url: URL, session: DASession?) -> Bool {
        guard let session, let description = diskDescription(for: url, session: session),
              let bsdName = description[kDADiskDescriptionMediaBSDNameKey as String] as? String,
              let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return false }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { return false }
        defer { IOObjectRelease(media) }
        let value = IORegistryEntryCreateCFProperty(media, "Encrypted" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static func diskDescription(for url: URL, session: DASession) -> [String: Any]? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return nil }
        return description
    }

    static func classify(url: URL, isRoot: Bool, isLocal: Bool, description: [String: Any]) -> VolumeKind {
        if isRoot { return .startupDisk }
        let fsKind = (description[kDADiskDescriptionVolumeKindKey as String] as? String)?.lowercased() ?? fileSystemName(url)
        switch fsKind {
        case "smbfs", "cifs": return .smbShare
        case "afpfs": return .appleShare
        case "nfs": return .nfsShare
        case "webdav": return .webDAVShare
        default: break
        }
        if !isLocal { return .networkDisk }

        let model = (description[kDADiskDescriptionDeviceModelKey as String] as? String) ?? ""
        let proto = (description[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        let mediaKind = (description[kDADiskDescriptionMediaKindKey as String] as? String) ?? ""

        if model.localizedCaseInsensitiveContains("Disk Image") || proto == "Virtual Interface" { return .diskImage }
        if mediaKind.contains("BD") { return .bluRay }
        if mediaKind.contains("DVD") { return .dvd }
        if mediaKind.contains("CD") { return .cd }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Backups.backupdb").path) { return .timeMachine }
        if fsKind == "ntfs" { return .ntfsDisk }
        switch proto {
        case "USB": return fsKind == "msdos" || fsKind == "exfat" ? .fatDisk : .usbDisk
        case "Thunderbolt": return .thunderboltDisk
        case "FireWire": return .fireWireDisk
        case "Secure Digital": return .sdCard
        default: break
        }
        if fsKind == "msdos" || fsKind == "exfat" { return .fatDisk }
        return .localDisk
    }

    static func fileSystemName(_ url: URL) -> String {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return "" }
        return withUnsafeBytes(of: st.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

// MARK: - APFS containers

/// A volume in an APFS container, with its space in use (from `diskutil apfs list -plist`).
public struct APFSVolume: Hashable, Sendable, Codable {
    public let bsdName: String
    public let name: String
    public let roles: [String]
    public let bytesInUse: UInt64
    /// Where it's mounted, if it is.
    public let mountPoint: String?
}

public enum APFSContainer {
    /// All volumes that share an APFS container with the volume mounted at `path` (including that volume).
    /// Returns [] for non-APFS volumes or if `diskutil` isn't available.
    public static func volumes(sharingContainerWith path: String) -> [APFSVolume] {
        var st = statfs()
        guard statfs(path, &st) == 0 else { return [] }
        let device = withUnsafeBytes(of: st.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let fsType = withUnsafeBytes(of: st.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard fsType == "apfs", let bsd = device.split(separator: "/").last,
              let container = bsd.firstMatch(of: /^(disk\d+)s/)?.1 else { return [] }

        guard let plist = runDiskutil(["apfs", "list", "-plist"]),
              let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let containers = root["Containers"] as? [[String: Any]],
              let match = containers.first(where: { ($0["ContainerReference"] as? String) == String(container) }),
              let volumes = match["Volumes"] as? [[String: Any]] else { return [] }

        let mounts = mountPoints()
        return volumes.compactMap { v in
            guard let id = v["DeviceIdentifier"] as? String else { return nil }
            return APFSVolume(
                bsdName: id,
                name: v["Name"] as? String ?? id,
                roles: v["Roles"] as? [String] ?? [],
                bytesInUse: (v["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0,
                mountPoint: mounts[id])
        }
    }

    /// BSD name (e.g. "disk3s6") → mount point, from the kernel's mount table.
    static func mountPoints() -> [String: String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [:] }
        var result: [String: String] = [:]
        for i in 0..<Int(count) {
            var entry = buffer[i]
            let from = withUnsafeBytes(of: &entry.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let on = withUnsafeBytes(of: &entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if let bsd = from.split(separator: "/").last, from.hasPrefix("/dev/") { result[String(bsd)] = on }
        }
        return result
    }

    private static func runDiskutil(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}

/// How the volumes of the scanned container relate to a scan of `root`.
public struct ContainerAccounting: Sendable {
    /// Sibling volumes mounted below the scan root (mount path → bytes): shown as fixed-size folders.
    public let fixedSizeMountPoints: [String: UInt64]
    /// Sibling volumes not reachable from the scan root (unmounted, or mounted elsewhere).
    public let otherVolumes: [APFSVolume]

    public var otherVolumesBytes: UInt64 { otherVolumes.reduce(0) { $0 + $1.bytesInUse } }

    /// For a scan of the volume mounted at `root`. The scanned volume itself and, on the startup disk, its
    /// firmlinked Data partner are excluded — their content is scanned directly.
    public init(root: String, volumes: [APFSVolume]) {
        let rootIsSystem = root == "/"
        var fixed: [String: UInt64] = [:]
        var others: [APFSVolume] = []
        for volume in volumes {
            if volume.mountPoint == root { continue }
            if rootIsSystem && (volume.roles.contains("Data") || volume.roles.contains("System")) { continue }
            if let mount = volume.mountPoint, root == "/" || mount.hasPrefix(root + "/") {
                fixed[mount] = volume.bytesInUse
            } else {
                others.append(volume)
            }
        }
        fixedSizeMountPoints = fixed
        otherVolumes = others
    }

    public static let empty = ContainerAccounting(root: "", volumes: [])

    /// Rebuilds the accounting stored with a saved scan.
    public init(restoring info: SavedScanInfo) {
        fixedSizeMountPoints = info.fixedSizeMountPoints
        otherVolumes = info.otherVolumes
    }
}
