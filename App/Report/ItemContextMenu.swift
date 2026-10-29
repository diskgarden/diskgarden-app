import ScanEngine
import SwiftUI

/// DaisyDisk's item menu, shared by chart wedges and legend rows.
struct ItemContextMenu: View {
    let report: ReportModel
    let node: NodeRef

    var body: some View {
        let name = report.displayName(node)
        if report.tree.isDirectory(node) && node != report.focus {
            Button("Expand “\(name)”") { report.zoom(to: node) }
        }
        Button("Preview") { report.preview(node) }
            .keyboardShortcut(.space, modifiers: [])
        Button("Show in Finder") { report.showInFinder(node) }
        Button("Open in Terminal") { report.openInTerminal(node) }
        Button("Put “\(name)” in the Waste bin") { report.collect(node) }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(report.isDeleting)
    }
}
