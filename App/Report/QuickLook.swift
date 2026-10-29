import AppKit
import Quartz

/// Quick Look for the report window. Lives in the window's responder chain (after the window itself), which is
/// how QLPreviewPanel discovers its controller; the report just calls `toggle(_:)`.
@MainActor
final class QuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()

    private var items: [URL] = []

    /// Opens a preview of `url`, or closes the panel if it's already previewing it.
    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible, items == [url] {
            panel.orderOut(nil)
            return
        }
        items = [url]
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func install(in window: NSWindow) {
        guard window.nextResponder !== self else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
    }

    // MARK: QLPreviewPanelController (informal protocol)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // QLPreviewPanel calls these on the main thread; the overrides are nonisolated by inheritance.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    // MARK: Data source

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { items[index] as NSURL }
    }
}
