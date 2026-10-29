import AppKit
import Sparkle
import SwiftUI

/// Sparkle updates. Everything about *what* to install and *how* lives in the appcast:
/// normal releases install automatically in the background, `sparkle:criticalUpdate` releases can't be skipped, and
/// `sparkle:minimumAutoupdateVersion` keeps a major (paid) release from installing silently. This class only starts
/// Sparkle's standard updater and exposes it to the menu and Settings.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    /// An update downloaded in the background and waiting to install on quit: the toolbar offers to restart now.
    struct ReadyUpdate {
        let version: String
        let installNow: () -> Void
    }
    /// Observed by the toolbar (see `RestartToUpdateButton`).
    @MainActor @Observable final class State {
        var ready: ReadyUpdate?
        /// Version being downloaded in the background (a new check can't start meanwhile).
        var downloading: String?
    }
    let state = State()

    private var controller: SPUStandardUpdaterController!

    var updater: SPUUpdater { controller.updater }

    override private init() {
        super.init()
        if let version = ProcessInfo.processInfo.environment["DG_UPDATE_READY"] { // preview the Restart to Update pill
            state.ready = ReadyUpdate(version: version, installNow: {})
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            // Sparkle's own schedule (every SUScheduledCheckInterval, and never on the very first launch) can leave a
            // new version unnoticed for hours: also check once per launch, quietly. With automatic updates on, it
            // downloads in the background and installs on quit; otherwise Sparkle shows its update window.
            // Respects "Check for updates automatically" (off in the Debug app).
            if controller.updater.automaticallyChecksForUpdates {
                controller.updater.checkForUpdatesInBackground()
            }
        } catch {
            // A misconfiguration (feed, keys, bundle): report it instead of Sparkle's blocking alert at launch.
            NSLog("DG update: updater failed to start: %@", "\(error)")
            CrashReporter.record(error, context: "sparkle-start")
        }
    }

    /// Call once at launch (starts scheduled checks and checks right away).
    static func start() { _ = shared }

    /// The "Check for Updates…" menu item.
    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Testing: `defaults write app.diskgarden.DiskGarden(.debug) DGUpdateFeedURL http://localhost:8765/appcast.xml` points the
    /// app at a local appcast. Safe to leave in release builds: updates must still be signed with our EdDSA key (and
    /// the feed too, see SURequireSignedFeed). Delete the default to go back to the Info.plist feed.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "DGUpdateFeedURL")
    }

    // MARK: Tracing (DG_TRACE=1)

    private nonisolated static func trace(_ message: String) {
        if ProcessInfo.processInfo.environment["DG_TRACE"] != nil { NSLog("DG update: %@", message) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Self.trace("appcast loaded, \(appcast.items.count) item(s)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.trace("found \(item.displayVersionString) (\(item.versionString)), critical \(item.isCriticalUpdate), major \(item.isMajorUpgrade)")
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Self.trace("no update: \(error.localizedDescription)")
    }

    nonisolated func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let version = item.displayVersionString
        Task { @MainActor in AppUpdater.shared.state.downloading = version }
    }

    nonisolated func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Self.trace("download failed: \(error)")
        Task { @MainActor in AppUpdater.shared.state.downloading = nil }
    }

    nonisolated func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { @MainActor in AppUpdater.shared.state.downloading = nil }
        Self.trace("downloaded \(item.displayVersionString)")
    }

    /// Sparkle downloaded an update that installs on quit: show "Restart to Update" instead of waiting silently.
    /// Returning true tells Sparkle we present it (it then shows nothing itself).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Self.trace("\(version) ready to install on quit")
        nonisolated(unsafe) let install = immediateInstallHandler
        Task { @MainActor in AppUpdater.shared.state.ready = ReadyUpdate(version: version, installNow: install) }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.trace("installing \(item.displayVersionString)")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { @MainActor in AppUpdater.shared.state.downloading = nil }
        Self.trace("aborted: \(error)")
    }
}

/// Green "Restart to Update" pill, shown once Sparkle has downloaded an update that would otherwise wait for quit.
struct RestartToUpdateButton: View {
    private let state = AppUpdater.shared.state

    var body: some View {
        if let ready = state.ready {
            Button { ready.installNow() } label: {
                Label("Restart to Update", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(PillButtonStyle(tint: Theme.accent, height: 28, horizontalPadding: 12))
            .help(String(localized: "DiskGarden \(ready.version) is ready. Restart to install it now, or it installs when you quit.",
                         comment: "Tooltip on Restart to Update; placeholder is the new version, e.g. 1.0.2"))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
