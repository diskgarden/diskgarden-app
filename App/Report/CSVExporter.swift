import AppKit
import ScanEngine
import UniformTypeIdentifiers

/// "Export Scan to CSV…": every item under the focused folder, depth-first, streamed to disk.
/// Columns: Path, Size (bytes), Size, Items, Kind.
@MainActor
enum CSVExporter {
    static func export(_ report: ReportModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(report.displayName(report.focus)).csv"
        panel.message = String(localized: "Exports every item inside “\(report.displayName(report.focus))”.", comment: "CSV export panel message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let tree = report.tree
        let focus = report.focus
        Task.detached(priority: .userInitiated) {
            do {
                try CSVWriter.write(tree: tree, from: focus, to: url)
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                CrashReporter.record(error, context: "csv-export")
                let message = error.localizedDescription
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Couldn't export the scan result", comment: "CSV export error title")
                    alert.informativeText = message
                    alert.runModal()
                }
            }
        }
    }
}
