import ScanEngine
import SwiftUI

// Pieces shared by the Volumes list rows and grid tiles.

/// "994.6 GB · encrypted startup disk · scanned 5 hours ago", or the admin status / error when there is one.
struct SourceSubtitle: View {
    let source: Source
    /// The grid's narrow columns leave the scan age out.
    var includesScanAge = true

    var body: some View {
        if let error = source.adminError {
            Text(error).foregroundStyle(Theme.warning)
        } else if let activity = source.adminActivity, !source.isScanning {
            Text(activity)
        } else {
            description
        }
    }

    @ViewBuilder private var description: some View {
        switch source.kind {
        case .volume(let v):
            Text(verbatim: "\(ByteSize.string(UInt64(v.totalCapacity))) · \(v.localizedDescriptor)") + scanAge
        case .folder:
            if let tree = source.tree {
                Text(verbatim: "\(ByteSize.string(tree.size(tree.root))) · \(Self.folderWord)") + scanAge
            } else if let saved = source.savedInfo {
                Text(verbatim: "\(ByteSize.string(saved.totalBytes)) · \(Self.folderWord)") + scanAge
            } else {
                Text(abbreviatedParentPath)
            }
        }
    }

    /// " · scanned 2 hours ago" for results that aren't fresh from this session.
    private var scanAge: Text {
        guard includesScanAge, let date = source.scanDate ?? source.savedInfo?.date, Date().timeIntervalSince(date) > 60 else { return Text("") }
        let when = date.formatted(.relative(presentation: .named))
        return (Text(verbatim: " · ") + Text("scanned \(when)", comment: "Volume card: when the saved scan was made, e.g. scanned 5 hours ago"))
            .foregroundStyle(Theme.tertiaryText)
    }

    private static var folderWord: String { String(localized: "folder", comment: "Volume card: kind of a scanned folder") }

    private var abbreviatedParentPath: String {
        (source.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
}

/// Scan / View split button with its menu, or Cancel while scanning.
struct SourceActionButton: View {
    @Environment(AppModel.self) private var model
    let source: Source
    /// Width of the main segment (the grid uses a wider button).
    var minTitleWidth: CGFloat = 58

    var body: some View {
        if source.isScanning {
            Button { model.cancelScan(source.id) } label: {
                Text("Cancel").lineLimit(1).fixedSize().frame(minWidth: minTitleWidth + 2)
            }
            .buttonStyle(PillButtonStyle())
        } else if source.hasResult {
            SplitButton(title: "View", minTitleWidth: minTitleWidth, action: { model.view(source.id) }, menu: { menuEntries })
        } else {
            SplitButton(title: "Scan", minTitleWidth: minTitleWidth, action: { model.scan(source.id) }, menu: { menuEntries })
        }
    }

    private var menuEntries: [MenuEntry] {
        var entries: [MenuEntry] = []
        if source.hasResult {
            entries.append(.item(String(localized: "Rescan"), action: { model.rescan(source.id) }))
            entries.append(.item(String(localized: "Deep Scan (Admin)"), enabled: source.restrictedCount > 0 && source.adminActivity == nil) {
                model.quickRescanAsAdministrator(source.id)
            })
            entries.append(.item(String(localized: "Full Deep Scan (Admin)"), enabled: source.adminActivity == nil) {
                model.scanAsAdministrator(source.id)
            })
            entries.append(.separator)
            entries.append(.item(source.volume == nil ? String(localized: "Clear Scan Results for “\(source.name)”")
                                                      : String(localized: "Clear Scan Results")) {
                model.forget(source.id)
            })
        } else {
            entries.append(.item(String(localized: "Deep Scan (Admin)"), action: { model.scanAsAdministrator(source.id) }))
            if source.volume == nil {
                entries.append(.separator)
                entries.append(.item(String(localized: "Close “\(source.name)”"), action: { model.forget(source.id) }))
            }
        }
        entries.append(.separator)
        entries.append(.item(String(localized: "Show in Finder"), action: { model.showInFinder(source.id) }))
        entries.append(.item(String(localized: "Open Item Info"), action: { model.getInfo(source.id) }))
        return entries
    }
}

/// Right-click menu of a volume or folder.
struct SourceContextMenu: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        if source.tree != nil {
            Button("View “\(source.name)”") { model.view(source.id) }
            Button("Rescan “\(source.name)”") { model.rescan(source.id) }
            Button("Clear Scan Results") { model.forget(source.id) }
        } else if source.isScanning {
            Button("Cancel Scanning") { model.cancelScan(source.id) }
        } else {
            Button("Scan “\(source.name)”") { model.scan(source.id) }
        }
        Divider()
        if source.volume == nil {
            if source.isFavorite {
                Button("Unstar “\(source.name)”") { model.toggleFavorite(source.id) }
            } else {
                Button("Star “\(source.name)”") { model.toggleFavorite(source.id) }
            }
        }
        Button("Show “\(source.name)” in Finder") { model.showInFinder(source.id) }
        Button("Open Item Info") { model.getInfo(source.id) }
    }
}
