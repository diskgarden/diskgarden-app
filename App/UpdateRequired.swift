import AppKit
import SwiftUI

/// Remote kill switch for old versions: when the Remote Config parameter `minimum_app_version` (e.g. "1.2.0") is
/// above this app's version, the window shows `UpdateRequiredView` instead of the app. Empty (the default) = off.
/// Firebase keeps the last activated config on disk, so the block applies right at launch, and a value published in
/// the console takes effect live (never in the middle of a deletion).
@MainActor
enum UpdateGate {
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var isUpdateRequired: Bool {
        if ProcessInfo.processInfo.environment["DG_FORCE_UPDATE"] != nil { return true } // preview the screen
        let minimum = RemoteSettings.shared.string(.minimumAppVersion).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !minimum.isEmpty else { return false }
        return isVersion(currentVersion, olderThan: minimum)
    }

    /// Compares dotted versions numerically, missing parts counting as 0 ("1.2" == "1.2.0", "1.9" < "1.10").
    nonisolated static func isVersion(_ version: String, olderThan minimum: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(version), b = parts(minimum)
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static let downloadURL = URL(string: "https://diskgarden.app/download/")!
}

/// Replaces the window's content while this version is blocked: update in place with Sparkle, or download manually.
struct UpdateRequiredView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: AppIconImage.current)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Update DiskGarden")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("This version (\(UpdateGate.currentVersion)) is no longer supported. Install the latest version to keep using DiskGarden.",
                 comment: "Update required screen; placeholder is the installed version, e.g. 1.0.2")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            // An update Sparkle already downloaded is waiting for "Restart to Update" (its session stays open, so a new
            // check would do nothing): install that one; otherwise check, download and install.
            if let downloading = AppUpdater.shared.state.downloading, AppUpdater.shared.state.ready == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading DiskGarden \(downloading)…", comment: "Update required screen while the update downloads")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(height: 34)
                .padding(.top, 6)
            } else if let ready = AppUpdater.shared.state.ready {
                Button("Restart to Update") { ready.installNow() }
                    .buttonStyle(PillButtonStyle(tint: Theme.accent, height: 34, horizontalPadding: 22))
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            } else {
                Button("Update Now") { AppUpdater.shared.checkForUpdates() }
                    .buttonStyle(PillButtonStyle(tint: Theme.accent, height: 34, horizontalPadding: 22))
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 6)
            }
            VStack(spacing: 3) {
                Text("Update not starting?")
                    .foregroundStyle(Theme.tertiaryText)
                Link(destination: UpdateGate.downloadURL) {
                    Text(verbatim: "diskgarden.app/download").underline()
                }
                .foregroundStyle(Theme.accent)
                .help(String(localized: "Download the latest version from the website"))
            }
            .font(.system(size: 12))
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
