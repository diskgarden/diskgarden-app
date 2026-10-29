import ScanEngine
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var windowController = WindowController()

    var body: some View {
        ZStack {
            Theme.windowBackground
            // A blocked old version shows only the update screen (a running deletion finishes first).
            if UpdateGate.isUpdateRequired && !model.isDeletingAnything {
                UpdateRequiredView()
            } else {
                switch model.page {
                case .sources:
                    SourcesView()
                case .report:
                    if let source = model.currentSource, let report = model.report(for: source) {
                        ReportView(report: report)
                            .id(source.id)
                    }
                }
            }
        }
        .id(model.sizeUnitsVersion) // re-render every size when the unit base changes
        .ignoresSafeArea()
        // The window itself is transparent: paint the whole of it, including macOS 26's bottom-corner safe area
        // (otherwise the bottom strip stays see-through and the rounded corners look clipped).
        .background(Theme.windowBackground.ignoresSafeArea())
        // Report a small minimum so SwiftUI doesn't add the hidden title bar's inset on top of our content height
        // (NSHostingView would otherwise grow the window from windowDidLayout); WindowController owns the real size.
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        .focusEffectDisabled()
        // An empty, background-less toolbar: macOS 26 gives toolbar windows DaisyDisk's rounder corners and inset
        // traffic lights. Our own title / path bar is drawn by the pages underneath it.
        .toolbar(removing: .title) // our pages draw their own title; the bridged toolbar would add the window title
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // No SwiftUI animation on page switches: inside an animated transaction SwiftUI also animates the window
        // size, fighting WindowController's resize. The page appears as the window morphs; the chart blossoms in.
        .background(WindowAccessor { window in
            windowController.attach(window)
            // Next turn: the window may still be mid-setup (being attached to its hosting controller).
            DispatchQueue.main.async {
                windowController.show(page: model.page, sourceRows: model.sources.count, sourcesGrid: model.showsVolumesGrid, animated: false)
                runDebugLaunchActions()
            }
        })
        .onChange(of: model.page) { _, page in
            windowController.show(page: page, sourceRows: model.sources.count, sourcesGrid: model.showsVolumesGrid, animated: true)
        }
        // Switching grid ↔ list (by the user, or because drives were attached / ejected) changes the page height.
        .onChange(of: model.showsVolumesGrid) { _, grid in
            if model.page == .sources {
                windowController.show(page: .sources, sourceRows: model.sources.count, sourcesGrid: grid, animated: true)
            }
        }
        .onChange(of: model.sources.count) { _, count in
            if model.page == .sources {
                windowController.show(page: .sources, sourceRows: count, sourcesGrid: model.showsVolumesGrid, animated: true)
            }
        }
    }

    /// `DG_AUTOSCAN=<path>` starts a scan at launch — used for scripted UI checks.
    private func runDebugLaunchActions() {
        // `DG_CHECK_UPDATES=1` runs a background update check right away (the scheduled check, without waiting).
        if ProcessInfo.processInfo.environment["DG_CHECK_UPDATES"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let updater = AppUpdater.shared.updater
                NSLog("DG update: check now (canCheck %d, feed %@, autoCheck %d, autoInstall %d)", updater.canCheckForUpdates ? 1 : 0,
                      updater.feedURL?.absoluteString ?? "nil", updater.automaticallyChecksForUpdates ? 1 : 0,
                      updater.automaticallyDownloadsUpdates ? 1 : 0)
                updater.checkForUpdatesInBackground()
            }
        }
        // `DG_TEST_CRASH=1` crashes 3 s after launch, to check that Crashlytics reports (on the next launch) arrive.
        if ProcessInfo.processInfo.environment["DG_TEST_CRASH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                CrashReporter.log("Test crash requested with DG_TEST_CRASH")
                fatalError("DiskGarden Crashlytics test crash")
            }
        }
        // `DG_FULLSCREEN=1` enters full screen shortly after launch — for scripted screenshots.
        if ProcessInfo.processInfo.environment["DG_FULLSCREEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.activate()
                MainWindow.current?.toggleFullScreen(nil)
            }
        }
        // `DG_OPEN=about,settings` opens those windows at launch — for scripted screenshots.
        let windows = ProcessInfo.processInfo.environment["DG_OPEN"]?.split(separator: ",") ?? []
        // Through the app menu: this view lives in an AppKit-hosted window, outside any SwiftUI scene,
        // where `openWindow` / `openSettings` do nothing.
        func clickMenuItem(_ title: String) {
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = appMenu.items.firstIndex(where: { $0.title.hasPrefix(title) }) else { return }
            appMenu.performActionForItem(at: index)
            if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    NSLog("DG open %@ → windows: %@", title, NSApp.windows.filter(\.isVisible).map(\.title).joined(separator: ", "))
                }
            }
        }
        if windows.contains("about") { clickMenuItem("About") }
        if windows.contains("settings") { clickMenuItem("Settings") }
        // `DG_PINGPONG=n` flips between the report and the Sources page n times (crash reproduction).
        if let count = Int(ProcessInfo.processInfo.environment["DG_PINGPONG"] ?? ""), let path = ProcessInfo.processInfo.environment["DG_AUTOVIEW"] {
            let id = URL(fileURLWithPath: path).standardizedFileURL.path
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                for i in 0..<count {
                    if i % 2 == 0 { model.showSources() } else { model.view(id) }
                    let fast = ProcessInfo.processInfo.environment["DG_PINGPONG_FAST"] != nil
                    try? await Task.sleep(for: .milliseconds(fast ? Int.random(in: 40...350) : Int.random(in: 150...900)))
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["DG_AUTOVIEW"] { // open a saved scan
            model.view(URL(fileURLWithPath: path).standardizedFileURL.path)
        }
        guard let path = ProcessInfo.processInfo.environment["DG_AUTOSCAN"] else { return }
        if model.source(path) != nil { model.scan(path) } else { model.addFolder(URL(fileURLWithPath: path)) }
    }
}
