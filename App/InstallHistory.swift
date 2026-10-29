import Foundation
import Security

/// When this Mac first and last used DiskGarden: kept for a possible future paid plan, so early users can be
/// recognised. Recorded once per launch, locally only — nothing is sent anywhere.
///
/// Stored twice: in UserDefaults (easy to read) and in the app's data-protection keychain, which survives deleting and
/// reinstalling the app or `defaults delete`, so the first-open date isn't lost or reset by accident. The earliest
/// date found anywhere wins. Installs from before this was added (1.0.5 and earlier) get their real first use from the
/// preferences file's creation date, which macOS writes on the first launch.
///
///   defaults read app.diskgarden.DiskGarden installHistory     (debug app: app.diskgarden.DiskGarden.debug)
@MainActor
enum InstallHistory {
    struct Record: Codable, Equatable {
        var firstOpen: Date
        /// The version that first ran on this Mac (best effort for installs older than this record).
        var firstVersion: String
        var lastOpen: Date
        var launchCount: Int
    }

    private static let defaultsKey = "installHistory"
    private static let keychainService = "app.diskgarden.install-history"

    /// The record as of this launch (nil until `recordLaunch()` ran).
    private(set) static var current: Record?

    /// Call once per launch.
    static func recordLaunch(now: Date = Date()) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let stored = [readDefaults(), readKeychain()].compactMap { $0 }
        var record: Record
        if let earliest = stored.min(by: { $0.firstOpen < $1.firstOpen }) {
            record = earliest
            record.launchCount = (stored.map(\.launchCount).max() ?? 0) + 1
            record.lastOpen = now
        } else {
            // First launch with this record: an existing install's real first use, from its preferences file.
            let existing = preferencesCreationDate().map { $0 < now.addingTimeInterval(-60) } ?? false
            record = Record(firstOpen: existing ? preferencesCreationDate()! : now,
                            firstVersion: existing ? "≤ 1.0.5" : version, lastOpen: now, launchCount: 1)
        }
        current = record
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        writeKeychain(data)
    }

    // MARK: Storage

    private static func readDefaults() -> Record? {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "record",
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func readKeychain() -> Record? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func writeKeychain(_ data: Data) {
        let update = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = keychainQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func preferencesCreationDate() -> Date? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences/\(id).plist")
        return (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
