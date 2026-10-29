import AppKit
import SwiftUI

/// Settings window: General and Full Disk Access, in the app's colors with the green accent.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "switch.2") }
            FullDiskAccessSettings()
                .tabItem { Label("Full Disk Access", systemImage: "lock.shield") }
        }
        .frame(width: 520)
        .background(Theme.windowBackground)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    // Sparkle keeps these preferences; mirrored here so the checkboxes update when toggled.
    @State private var checksForUpdates = AppUpdater.shared.updater.automaticallyChecksForUpdates
    @State private var installsUpdates = AppUpdater.shared.updater.automaticallyDownloadsUpdates

    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Appearance:", selection: $model.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Divider().padding(.vertical, 4)
            Toggle("Celebrate after emptying more than 5 GB from the Waste bin", isOn: $model.showsCongratulations)
            Toggle("Emptying the Waste bin moves files to the Trash (instead of deleting them forever)", isOn: Binding(
                get: { model.deletionMode == .moveToTrash },
                set: { model.deletionMode = $0 ? .moveToTrash : .permanent }))
            Toggle("Use binary units (1 KB = 1024 bytes)", isOn: $model.usesBinarySizes)
            Toggle("Remember scan results between launches", isOn: $model.remembersScans)
            Toggle("Update results when files change", isOn: $model.updatesLive)
            Toggle("Suggest sharing DiskGarden now and then", isOn: Binding(
                get: { ShareNudge.shared.isEnabled },
                set: { ShareNudge.shared.isEnabled = $0 }))
            Divider().padding(.vertical, 4)
            Toggle("Check for updates automatically", isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { _, on in AppUpdater.shared.updater.automaticallyChecksForUpdates = on }
            Toggle("Download and install updates automatically", isOn: $installsUpdates)
                .onChange(of: installsUpdates) { _, on in AppUpdater.shared.updater.automaticallyDownloadsUpdates = on }
                .disabled(!checksForUpdates)
                .padding(.leading, 20)
        }
        .toggleStyle(.checkbox)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Probes whether DiskGarden has Full Disk Access by opening a TCC-protected file, like DaisyDisk does.
enum FullDiskAccess {
    static var isGranted: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

private struct FullDiskAccessSettings: View {
    @State private var granted = FullDiskAccess.isGranted

    var body: some View {
        VStack(spacing: 14) {
            if granted {
                Image(systemName: "checkmark.shield.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                Text("Full Disk Access is on.\nDiskGarden can see every folder on this Mac.")
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "exclamationmark.shield.fill").font(.system(size: 34)).foregroundStyle(Theme.warning)
                Text("Without Full Disk Access, macOS hides some folders from DiskGarden and their space shows up as “hidden space”.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open Privacy & Security › Full Disk Access.")
                    Text("2. Drag DiskGarden into the list (or click + and choose it).")
                    Text("3. Turn it on, then rescan.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") { FullDiskAccess.openSystemSettings() }
                        .buttonStyle(.borderedProminent)
                    Button("Show DiskGarden in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = FullDiskAccess.isGranted
        }
    }
}
