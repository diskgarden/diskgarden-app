import Foundation

/// DaisyDisk-style size formatting: decimal units, at most one fractional digit, ".0" dropped,
/// and number and unit returned separately so lists can align them in their own columns.
public enum ByteSize {
    public struct Parts: Equatable, Sendable {
        public let number: String
        public let unit: String
        public var joined: String { "\(number) \(unit)" }
    }

    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]

    /// 1000 (Finder-style, default) or 1024. Set from the app's settings on the main thread.
    nonisolated(unsafe) public static var defaultBase: Double = 1000

    /// Presentation hooks the app sets once at launch for the user's language (defaults: English).
    /// `decimalSeparator` replaces "." in numbers; `unitName` maps "bytes", "byte", "KB" … "PB" to localized names.
    nonisolated(unsafe) public static var decimalSeparator = "."
    nonisolated(unsafe) public static var unitName: @Sendable (String) -> String = { $0 }

    public static func parts(_ bytes: UInt64, base: Double = defaultBase) -> Parts {
        if Double(bytes) < base { return Parts(number: String(bytes), unit: unitName(bytes == 1 ? "byte" : "bytes")) }
        var value = Double(bytes)
        var unit = 0
        while value >= base && unit < units.count - 1 {
            value /= base
            unit += 1
        }
        var rounded = (value * 10).rounded() / 10
        if rounded >= base && unit < units.count - 1 { // 999.96 KB → 1 MB
            rounded = (rounded / base * 10).rounded() / 10
            unit += 1
        }
        let number = rounded == rounded.rounded() ? String(Int(rounded))
            : String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: decimalSeparator)
        return Parts(number: number, unit: unitName(units[unit]))
    }

    public static func string(_ bytes: UInt64) -> String { parts(bytes).joined }
}
