import AppKit
import SwiftUI

/// Owns the AppKit side of the main window: DaisyDisk-style chrome (dark, transparent 52pt title bar with
/// vertically centered traffic lights, no title text) and animated resizing between the Sources and Report pages.
@MainActor
final class WindowController {
    private(set) weak var window: NSWindow?
    private var toolbarObservation: NSKeyValueObservation?
    private var lastRows = 1
    private var lastGrid = false
    /// Layout the Sources page was last sized for ("list", or "grid-<items>") and the width it had: the width resets
    /// to the layout's default when the layout changes (grid ↔ list, or items added / removed in the grid) and is
    /// otherwise kept, including across visits to a report.
    private var sourcesLayoutKey: String?
    private var sourcesWidth: CGFloat?
    private var liveResizeObserver: NSObjectProtocol?
    private var fullScreenObservers: [NSObjectProtocol] = []
    private var reportFrame: NSRect?
    private var currentPage: AppModel.Page?

    static let reportMinSize = NSSize(width: 900, height: 640)
    static let reportDefaultSize = NSSize(width: 1166, height: 803)

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        // Not movable by background: drags on the chart and lists must reach SwiftUI (Waste bin drag and drop).
        // The title bar still moves the window.
        window.isMovableByWindowBackground = false
        // Clear window background: with a toolbar, the titlebar area paints the window background color over our
        // content (hiding the title and path bar). The SwiftUI root view paints #2A2C32 for the whole window instead.
        window.backgroundColor = .clear
        window.isOpaque = false
        // The toolbar itself comes from SwiftUI (RootView) so its background can be hidden; it gives the macOS 26
        // toolbar-window chrome DaisyDisk has: larger corner radius, traffic lights inset ~26pt in a 52pt band.
        window.tabbingMode = .disallowed
        // SwiftUI installs the bridged toolbar after the window is set up, and AppKit grows the frame by the title
        // band to preserve the content area. Re-apply the page's size once that happens.
        if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { note in
                if let w = note.object as? NSWindow { NSLog("DG window resized → %@", NSStringFromRect(w.frame)) }
            }
        }
        // Full screen: lift the page's size limits (a fixed-height page would otherwise stay small in the middle of a
        // black screen) and don't resize while in it; restore the page's size on the way out.
        fullScreenObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window,
                                                   queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    window?.minSize = NSSize(width: 480, height: 300)
                    window?.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let page = self.currentPage else { return }
                    self.show(page: page, sourceRows: self.lastRows, sourcesGrid: self.lastGrid, animated: true)
                }
            },
        ]
        // A width the user drags to on the Sources page is kept until the layout changes.
        liveResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                                                    object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window, case .sources? = self.currentPage else { return }
                self.sourcesWidth = window.frame.width
            }
        }
        toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let page = self.currentPage else { return }
                    self.show(page: page, sourceRows: self.lastRows, sourcesGrid: self.lastGrid, animated: false)
                }
            }
        }
        if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
            NSLog("DG window attach: mask=%lu toolbar=%@ close=%@ hidden=%d frame=%@", window.styleMask.rawValue,
                  window.toolbar.map { "\($0.items.count) items" } ?? "none",
                  window.standardWindowButton(.closeButton).map { NSStringFromRect($0.frame) } ?? "nil",
                  window.standardWindowButton(.closeButton)?.isHidden == true ? 1 : 0, NSStringFromRect(window.frame))
        }
        QuickLook.shared.install(in: window)
        window.setFrameAutosaveName("")
    }

    /// Height of the Sources page for a given number of rows.
    static func sourcesHeight(rows: Int, grid: Bool, screen: NSScreen? = NSScreen.main) -> CGFloat {
        VolumesMetrics.pageHeight(rows: rows, grid: grid, maxHeight: (screen?.visibleFrame.height ?? .greatestFiniteMagnitude) - 40)
    }

    /// Generation counter: a newer `show` supersedes an in-flight resize.
    private var resizeGeneration = 0

    func show(page: AppModel.Page, sourceRows: Int, sourcesGrid: Bool, animated: Bool) {
        guard let window else { return }
        lastRows = sourceRows
        lastGrid = sourcesGrid
        // In full screen the window fills the screen whatever the page; sizes apply again on exit.
        if window.styleMask.contains(.fullScreen) {
            currentPage = page
            return
        }
        let leavingReport: Bool = if case .report = currentPage { true } else { false }
        if leavingReport, case .sources = page { reportFrame = window.frame }
        currentPage = page

        var frame = window.frame
        let minSize: NSSize
        let maxSize: NSSize
        switch page {
        case .sources:
            let height = Self.sourcesHeight(rows: sourceRows, grid: sourcesGrid, screen: window.screen ?? NSScreen.main)
            let minWidth = VolumesMetrics.minWidth(items: sourceRows, grid: sourcesGrid)
            minSize = NSSize(width: minWidth, height: height)
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
            let key = sourcesGrid ? "grid-\(sourceRows)" : "list"
            var width = key == sourcesLayoutKey ? (sourcesWidth ?? frame.width)
                : VolumesMetrics.defaultWidth(items: sourceRows, grid: sourcesGrid)
            sourcesLayoutKey = key
            if let screen = window.screen?.visibleFrame { width = min(width, screen.width - 20) }
            width = max(width, minWidth)
            sourcesWidth = width // the target, never a mid-animation frame
            frame.origin.x = frame.midX - width / 2 // resize around the window's center
            frame.size.width = width
            frame.origin.y = frame.maxY - height
            frame.size.height = height
        case .report:
            minSize = Self.reportMinSize
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            if let saved = reportFrame {
                frame = saved
            } else {
                let size = Self.reportDefaultSize
                frame = NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
            }
        }
        if let screen = window.screen?.visibleFrame {
            frame.origin.y = max(frame.origin.y, screen.minY)
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
            frame.origin.x = max(frame.origin.x, screen.minX)
        }

        resizeGeneration += 1
        let generation = resizeGeneration
        let target = frame
        let applyLimits: @MainActor () -> Void = { [weak window] in
            window?.minSize = minSize
            window?.maxSize = maxSize
        }
        guard target != window.frame else {
            applyLimits()
            return
        }
        guard animated else {
            applyLimits()
            window.setFrame(target, display: true)
            if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
                NSLog("DG window show %@: wanted %@ got %@ contentMin %@ min %@", "\(page)", NSStringFromRect(target),
                      NSStringFromRect(window.frame), NSStringFromSize(window.contentMinSize), NSStringFromSize(window.minSize))
            }
            return
        }
        // Never animate the frame while the old page's limits (or the new page's) forbid the in-between sizes:
        // AppKit and SwiftUI would keep correcting each other inside the same layout pass, which ends in AppKit's
        // "too many Update Constraints passes" abort. Relax the limits, animate on the next run-loop turn (outside
        // SwiftUI's own update), and apply the page's limits once the animation lands.
        window.minSize = NSSize(width: min(minSize.width, window.frame.width), height: min(minSize.height, window.frame.height))
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, generation == self.resizeGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(target, display: true)
            } completionHandler: {
                MainActor.assumeIsolated {
                    guard generation == self.resizeGeneration else { return }
                    applyLimits()
                }
            }
        }
    }
}

/// Hands the hosting NSWindow to a callback once the view is installed.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowObservingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
