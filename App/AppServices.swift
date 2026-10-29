import AppKit
import FirebaseCore
import FirebaseCrashlytics
import FirebaseRemoteConfig
import FirebaseInstallations

/// Firebase: Crashlytics (crashes + handled errors) and Remote Config.
///
/// Firebase only starts when `GoogleService-Info.plist` is bundled. That plist and its `-Debug` twin are tracked in
/// this repo (see `.gitignore`), so a fresh clone builds with Firebase on. The guard in `start()` is what keeps a
/// build without the resource safe: Firebase stays off and every call here is a no-op.
@MainActor
enum AppServices {
    private(set) static var isEnabled = false

    /// Call once at launch, before the UI.
    static func start() {
        guard !isEnabled, Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else { return }
        // macOS: let uncaught Objective-C exceptions crash the app (and be reported) instead of being swallowed by
        // AppKit, as Crashlytics recommends.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        FirebaseApp.configure()
        isEnabled = true
        RemoteSettings.shared.start()
    }
}

/// Handled failures worth knowing about (they don't crash the app), reported to Crashlytics as non-fatal errors.
enum CrashReporter {
    /// `context` names the place it happened ("load-saved-scan", "admin-scan", …).
    static func record(_ error: Error, context: String, details: [String: Any] = [:]) {
        guard FirebaseApp.app() != nil else { return }
        var info = details
        info["context"] = context
        Crashlytics.crashlytics().record(error: error, userInfo: info)
    }

    /// Breadcrumb that shows up in the log of the next crash / non-fatal report.
    static func log(_ message: String) {
        guard FirebaseApp.app() != nil else { return }
        Crashlytics.crashlytics().log(message)
    }
}

/// Remote Config values with in-app defaults: the app always has an answer, fetched values replace the defaults once
/// activated, and live updates are applied while the app runs. Views read `RemoteSettings.shared` and update when a
/// new config activates.
@MainActor @Observable
final class RemoteSettings {
    static let shared = RemoteSettings()

    /// Parameters the app reads, with their in-app defaults (used before the first fetch and when offline).
    /// Add a case per parameter defined in the Firebase console.
    enum Key: CaseIterable {
        /// Kill switch for the occasional "Enjoying DiskGarden? Share it" nudge (ShareNudge).
        case shareSuggestionsEnabled
        /// Minimum days between two share nudges.
        case shareSuggestionMinDays
        /// Days without a share nudge after which a new round starts (the 6-per-round count resets).
        case shareSuggestionResetDays
        /// Versions below this (e.g. "1.2.0") must update before they can be used (UpdateGate). Empty = off.
        case minimumAppVersion

        /// Parameter name in the Firebase console.
        var name: String {
            switch self {
            case .shareSuggestionsEnabled: "share_suggestions_enabled"
            case .shareSuggestionMinDays: "share_suggestion_min_days"
            case .shareSuggestionResetDays: "share_suggestion_reset_days"
            case .minimumAppVersion: "minimum_app_version"
            }
        }

        var defaultValue: NSObject {
            switch self {
            case .shareSuggestionsEnabled: true as NSNumber
            case .shareSuggestionMinDays: 2 as NSNumber
            case .shareSuggestionResetDays: 10 as NSNumber
            case .minimumAppVersion: "" as NSString
            }
        }
    }

    /// Bumped whenever a new config is activated (views that read a value re-render).
    private(set) var version = 0

    private var config: RemoteConfig? { FirebaseApp.app() == nil ? nil : RemoteConfig.remoteConfig() }

    func start() {
        guard let config else { return }
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0 // see console changes immediately while developing
        #else
        settings.minimumFetchInterval = 3600
        #endif
        config.configSettings = settings
        config.setDefaults(Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.name, $0.defaultValue) }))

        if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
            NSLog("DG firebase: asking Installations for an ID…")
            Installations.installations().installationID { @Sendable id, error in
                NSLog("DG firebase: installation id %@, error %@", id ?? "nil", error.map { "\($0)" } ?? "none")
            }
        }
        // Firebase calls these back on its own queues: `@Sendable` keeps them nonisolated (a closure formed in this
        // @MainActor method would otherwise be main-actor isolated and trap when Firebase calls it off the main thread,
        // e.g. the realtime listener reporting a network error after the Mac wakes from sleep).
        config.fetchAndActivate { @Sendable [weak self] status, error in
            if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
                NSLog("DG remote config: status %d, error %@", status.rawValue, error.map { "\($0)" } ?? "none")
            }
            if let error { CrashReporter.log("Remote Config fetch failed: \(error.localizedDescription)") }
            guard status != .error else { return }
            Task { @MainActor in self?.version += 1 }
        }
        // Live updates: activate as soon as the console publishes a change.
        config.addOnConfigUpdateListener { @Sendable [weak self] update, error in
            guard error == nil, update != nil else { return }
            RemoteConfig.remoteConfig().activate { @Sendable changed, _ in
                guard changed else { return }
                Task { @MainActor in self?.version += 1 }
            }
        }
    }

    func bool(_ key: Key) -> Bool {
        _ = version
        return config?[key.name].boolValue ?? (key.defaultValue as? Bool ?? false)
    }

    func string(_ key: Key) -> String {
        _ = version
        return config?[key.name].stringValue ?? (key.defaultValue as? String ?? "")
    }

    func number(_ key: Key) -> Double {
        _ = version
        return config?[key.name].numberValue.doubleValue ?? (key.defaultValue as? NSNumber)?.doubleValue ?? 0
    }
}
