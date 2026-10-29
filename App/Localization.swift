import Foundation
import ScanEngine

/// Language-dependent formatting that isn't a plain UI string: size units, the decimal separator, percentages and
/// volume descriptions. UI text itself lives in Localizable.xcstrings.
enum L10n {
    /// Installs the engine's presentation hooks for the user's language. Call once at launch, before any UI.
    static func configure() {
        ByteSize.decimalSeparator = Locale.current.decimalSeparator ?? "."
        ByteSize.unitName = { unit in
            switch unit {
            case "byte": String(localized: "byte", comment: "Size unit: exactly one byte")
            case "bytes": String(localized: "bytes", comment: "Size unit: several bytes (e.g. 512 bytes)")
            case "KB": String(localized: "KB", comment: "Size unit: kilobytes")
            case "MB": String(localized: "MB", comment: "Size unit: megabytes")
            case "GB": String(localized: "GB", comment: "Size unit: gigabytes")
            case "TB": String(localized: "TB", comment: "Size unit: terabytes")
            case "PB": String(localized: "PB", comment: "Size unit: petabytes")
            default: unit
            }
        }
    }

    /// Short unit shown in aligned size columns instead of "bytes" (e.g. "512 B").
    static var shortByteUnit: String { String(localized: "B", comment: "Size unit: bytes, abbreviated, in size columns") }

    /// Every unit name as displayed, to size the unit column.
    static var allUnitNames: [String] {
        ["KB", "MB", "GB", "TB", "PB"].map(ByteSize.unitName) + [shortByteUnit]
    }

    /// "74%", "8%", "3.6%", "1%", "0.4%", "<0.1%", formatted for the user's locale ("74 %", "%74", "٧٤٪").
    /// One decimal below 5%, none above.
    static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        if p <= 0 { return percentFormatter(digits: 0).string(from: 0) ?? "0%" }
        if p < 0.05 {
            let tiny = percentFormatter(digits: 1).string(from: 0.001) ?? "0.1%"
            return String(localized: "<\(tiny)", comment: "Percentage smaller than the given value, e.g. <0.1%")
        }
        return percentFormatter(digits: p < 5 ? 1 : 0).string(from: NSNumber(value: fraction)) ?? "\(Int(p.rounded()))%"
    }

    private static let formatters: [NumberFormatter] = (0...1).map { digits in
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0 // "1%" rather than "1.0%"
        formatter.maximumFractionDigits = digits
        return formatter
    }

    private static func percentFormatter(digits: Int) -> NumberFormatter { formatters[digits] }
}

extension VolumeInfo {
    /// "encrypted startup disk", "disk image", … in the user's language.
    var localizedDescriptor: String {
        var text = kind.localizedLabel
        // Disk images and optical media are inherently read-only; not worth calling out.
        if isReadOnly && !isRoot && ![.diskImage, .dvd, .cd, .bluRay].contains(kind) {
            text = String(localized: "read-only \(text)", comment: "Volume description, e.g. read-only USB disk")
        }
        if isEncrypted {
            text = String(localized: "\(text) · encrypted", comment: "Volume description, e.g. startup disk · encrypted")
        }
        return text
    }
}

extension VolumeKind {
    var localizedLabel: String {
        switch self {
        case .startupDisk: String(localized: "startup disk", comment: "Volume kind")
        case .localDisk: String(localized: "local disk", comment: "Volume kind")
        case .usbDisk: String(localized: "USB disk", comment: "Volume kind")
        case .thunderboltDisk: String(localized: "Thunderbolt disk", comment: "Volume kind")
        case .fireWireDisk: String(localized: "FireWire disk", comment: "Volume kind")
        case .sdCard: String(localized: "SD card", comment: "Volume kind")
        case .diskImage: String(localized: "disk image", comment: "Volume kind")
        case .dvd: String(localized: "DVD", comment: "Volume kind")
        case .cd: String(localized: "data CD", comment: "Volume kind")
        case .bluRay: String(localized: "Blu-ray disk", comment: "Volume kind")
        case .ntfsDisk: String(localized: "NTFS disk", comment: "Volume kind")
        case .fatDisk: String(localized: "FAT disk", comment: "Volume kind")
        case .timeMachine: String(localized: "Time Machine volume", comment: "Volume kind")
        case .appleShare: String(localized: "Apple network share", comment: "Volume kind")
        case .smbShare: String(localized: "Windows network share", comment: "Volume kind")
        case .nfsShare: String(localized: "NFS network disk", comment: "Volume kind")
        case .webDAVShare: String(localized: "WebDAV network share", comment: "Volume kind")
        case .networkDisk: String(localized: "network disk", comment: "Volume kind")
        case .other(let fs): String(localized: "\(fs) volume", comment: "Volume kind for an unknown file system, e.g. ZFS volume")
        }
    }
}
