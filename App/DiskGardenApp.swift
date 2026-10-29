import SwiftUI

@main
struct DiskGardenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        L10n.configure() // before anything formats a size
        _model = State(initialValue: AppModel.shared)
    }

    var body: some Scene {
        // The main window is an AppKit window (see MainWindow) so SwiftUI never resizes it — the Window scene's
        // automatic window sizing fought WindowController's page resizes and crashed in AppKit's layout loop.
        Window("About DiskGarden", id: "about") {
            AboutView().environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed) // SwiftUI would otherwise open its first window scene at launch
        .restorationBehavior(.disabled) // don't reopen About at launch just because it was open at quit

        Settings {
            SettingsView().environment(model)
        }
        .commands { AppCommands(model: model) }
    }
}

/// The main DiskGarden window: an NSWindow hosting RootView. `sizingOptions = []` keeps SwiftUI from ever setting the
/// window's size (WindowController owns it); `sceneBridgingOptions` still carries RootView's `.toolbar` items into
/// the window's toolbar.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    static var current: NSWindow? { window }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let frame = NSRect(x: 0, y: 0, width: VolumesMetrics.defaultWidth(items: AppModel.shared.sources.count,
                                                                          grid: AppModel.shared.showsVolumesGrid), height: WindowController.sourcesHeight(rows: AppModel.shared.sources.count,
                                                                                            grid: AppModel.shared.showsVolumesGrid))
        // The SwiftUI view is *embedded* in a plain container instead of being the window's content view: a hosting
        // view that is the content view resizes the window itself from inside AppKit's layout pass
        // (NSHostingView.windowDidLayout → updateAnimatedWindowSize), which fought WindowController's resizes and
        // crashed with "too many Update Constraints passes". Embedded, with sizing off, it only fills its container.
        // Right-to-left languages (Arabic): an NSHostingView outside a SwiftUI scene doesn't pick up the direction by
        // itself, and NSApp's direction can lag the app's language (e.g. -AppleLanguages), so derive it from the
        // localization the app actually runs in.
        let language = Locale.Language(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let direction: LayoutDirection = language.characterDirection == .rightToLeft
            || NSApp.userInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        let hostingView = NSHostingView(rootView: RootView()
            .environment(AppModel.shared)
            .environment(\.layoutDirection, direction))
        hostingView.sizingOptions = []
        hostingView.sceneBridgingOptions = [.toolbars]
        hostingView.frame = frame
        hostingView.autoresizingMask = [.width, .height]
        let container = NSView(frame: frame)
        container.addSubview(hostingView)

        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = container
        window.setFrame(frame, display: false) // full frame (fullSizeContentView: the titlebar overlaps content)
        window.title = "DiskGarden"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DiskGarden") { openWindow(id: "about") }
            Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { model.chooseFolder() }
                .keyboardShortcut("o")
            Divider()
            Button("Export Scan to CSV…") {
                if let report = model.currentReport { CSVExporter.export(report) }
            }
            .keyboardShortcut("e")
            .disabled(model.currentReport == nil)
            Divider()
            Toggle("Empty Waste Bin to Trash", isOn: Binding(
                get: { model.deletionMode == .moveToTrash },
                set: { model.deletionMode = $0 ? .moveToTrash : .permanent }))
        }
    }
}

/// Quit guards: warn before quitting if a deletion or scan is mid-flight, or the Waste bin is loaded.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // App-wide appearance (dark by default): in full screen the toolbar lives in a separate system strip that
            // follows the app's appearance, not the window's.
            AppModel.shared.applyAppearance()
            InstallHistory.recordLaunch() // first / last open, so early users can be recognised if there is ever a paid plan
            // Firebase once AppKit is fully up (configuring it in App.init, before NSApplication finished launching,
            // tripped AppKit's main-event-queue assertion).
            AppServices.start()
            AppUpdater.start()
            MainWindow.show()
            ShareNudge.shared.appDidLaunch()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindow.show() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let warning: (title: String, text: String)? =
                if model.isDeletingAnything {
                    (String(localized: "File deletion in progress", comment: "Quit warning title"), String(localized: "DiskGarden is still deleting. Quitting now leaves the rest of the files in place.", comment: "Quit warning text"))
                } else if model.isScanningAnything {
                    (String(localized: "Scanning in progress", comment: "Quit warning title"), String(localized: "DiskGarden is currently scanning a disk. If you quit now, the scan will not be completed.", comment: "Quit warning text"))
                } else if model.hasCollectedItems {
                    (String(localized: "The Waste bin isn't empty", comment: "Quit warning title"), String(localized: "If you quit now, DiskGarden will forget the files in the Waste bin. Nothing has been deleted.", comment: "Quit warning text"))
                } else {
                    nil
                }
            guard let warning else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = warning.title
            alert.informativeText = warning.text
            alert.addButton(withTitle: String(localized: "Quit Anyway", comment: "Quit warning button"))
            alert.addButton(withTitle: String(localized: "Cancel", comment: "Button"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}
