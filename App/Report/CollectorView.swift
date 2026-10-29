import ScanEngine
import SwiftUI
import UniformTypeIdentifiers

/// The Waste bin (model name: collector): a card at the bottom of the right column. Empty, it's a drop target with a
/// hint. With items it shows their total and an Empty button, and hovering unfolds the list above. Empty runs a
/// 3-second countdown (Stop cancels) before deleting.
struct CollectorView: View {
    let report: ReportModel
    let mode: DeletionMode
    /// `DG_COLLECTOR_EXPANDED=1` pins the list open for scripted screenshots.
    @State private var isHovered = ProcessInfo.processInfo.environment["DG_COLLECTOR_EXPANDED"] != nil
    @State private var isDropTargeted = false

    private var isEmpty: Bool { report.collected.isEmpty }
    private var isExpanded: Bool {
        isHovered && !isEmpty && { if case .countdown = report.deletionPhase { false } else { true } }()
    }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                CollectedList(report: report)
                    .frame(height: listHeight)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                Theme.divider.frame(height: 1).padding(.horizontal, 16)
            }
            HStack(spacing: 14) {
                WasteBinBadge(report: report, isDropTargeted: isDropTargeted)
                VStack(alignment: .leading, spacing: 3) {
                    title
                    caption
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                button
            }
            .padding(.horizontal, 16)
            .frame(height: 76)
        }
        .glassCard(radius: Theme.panelRadius, highlighted: isDropTargeted)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .onHover { hovering in
            guard ProcessInfo.processInfo.environment["DG_COLLECTOR_EXPANDED"] == nil else { return }
            withAnimation(.easeOut(duration: 0.18)) { isHovered = hovering }
        }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $isDropTargeted) { providers in
            CollectorDrag.receive(providers, collectInto: report)
        }
        .animation(.easeOut(duration: 0.2), value: report.collected)
        .animation(.easeOut(duration: 0.2), value: report.deletionPhase)
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    private var listHeight: CGFloat { min(220, CGFloat(report.collected.count) * 26 + 16) }

    // MARK: Text

    @ViewBuilder private var title: some View {
        Group {
            switch report.deletionPhase {
            case .countdown:
                Text("Emptying the Waste bin…")
            case .deleting:
                if mode == .permanent { Text("Deleting…") } else { Text("Moving to the Trash…") }
            case .finished(_, let failures) where isEmpty:
                if failures == 0 { Text("Done!") } else { Text("Partly done") }
            default:
                if isEmpty {
                    Text("Waste bin", comment: "Name of the drop area for files to delete")
                } else {
                    Text("Waste bin", comment: "Name of the drop area for files to delete")
                        + Text(verbatim: " · ").foregroundStyle(Theme.secondaryText)
                        + Text("\(report.collected.count) items", comment: "Number of items in the Waste bin; plural")
                            .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(Theme.primaryText)
        .lineLimit(1)
    }

    @ViewBuilder private var caption: some View {
        let size = Text(ByteSize.string(report.collectedBytes)).foregroundStyle(Theme.primaryText).fontWeight(.semibold)
        Group {
            if let notice = report.notice {
                Text(notice).foregroundStyle(Theme.warning)
            } else {
                switch report.deletionPhase {
                case .countdown:
                    Text("Starting in a moment.") + Text(verbatim: " ")
                        + (mode == .permanent
                            ? Text("The files will be deleted forever.").foregroundStyle(Theme.critical).fontWeight(.semibold)
                            : Text("The files will be moved to the Trash.").foregroundStyle(Theme.primaryText))
                case .deleting:
                    Text("\(ByteSize.string(report.collectedBytes)) to go", comment: "Waste bin while deleting: size left")
                case .finished(let freed, let failures) where isEmpty:
                    let freedText = Text(ByteSize.string(freed)).foregroundStyle(Theme.accentText).fontWeight(.semibold)
                    if failures == 0 {
                        Text("You've freed up \(freedText).", comment: "Waste bin after emptying; placeholder is a size")
                    } else {
                        Text("Freed \(freedText).", comment: "Waste bin after emptying with errors; placeholder is a size")
                            + Text(verbatim: " ")
                            + Text("\(failures) items couldn't be removed.", comment: "Waste bin after emptying; plural")
                    }
                default:
                    if isEmpty {
                        if isDropTargeted {
                            Text("Release to put it in the Waste bin.")
                        } else {
                            Text("Drop files here. Nothing is removed until you empty it.")
                        }
                    } else if isExpanded {
                        Text("\(size) ready to remove.", comment: "Waste bin caption; placeholder is the total size")
                    } else {
                        Text("\(size) ready to remove.", comment: "Waste bin caption; placeholder is the total size")
                            + Text(verbatim: " ") + Text("Hover to review.")
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Button

    @ViewBuilder private var button: some View {
        switch report.deletionPhase {
        case .countdown:
            Button { report.stopDeletion() } label: { Text("Stop").frame(minWidth: 44) }
                .buttonStyle(PillButtonStyle())
        case .deleting:
            EmptyView()
        default:
            if !isEmpty {
                Button { report.startDeletion(mode: mode) } label: { Text("Empty").frame(minWidth: 44) }
                    .buttonStyle(PillButtonStyle(tint: Theme.critical))
            }
        }
    }
}

// MARK: - Badge (the round well on the left)

private struct WasteBinBadge: View {
    let report: ReportModel
    let isDropTargeted: Bool

    var body: some View {
        ZStack {
            switch report.deletionPhase {
            case .countdown(let startedAt):
                TimelineView(.animation) { timeline in
                    let total = Double(ReportModel.countdownSeconds)
                    let elapsed = min(total, timeline.date.timeIntervalSince(startedAt))
                    ZStack {
                        Circle().stroke(Theme.track, lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: 1 - elapsed / total)
                            .stroke(Theme.critical, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(verbatim: "\(max(1, Int((total - elapsed).rounded(.up))))")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText(countsDown: true))
                    }
                }
            case .deleting:
                Circle().stroke(Theme.track, lineWidth: 3)
                ProgressView().controlSize(.small)
            default:
                if report.collected.isEmpty {
                    Circle()
                        .strokeBorder(isDropTargeted ? Theme.accent : Theme.tertiaryText,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [3.5, 3]))
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else {
                    Circle().fill(Theme.accent.opacity(0.14))
                    Circle().strokeBorder(Theme.accent, lineWidth: 1.5)
                    Image(systemName: "trash.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 44, height: 44)
    }
}

// MARK: - Expanded list

private struct CollectedList: View {
    let report: ReportModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(report.collected) { item in
                    CollectedRow(report: report, item: item)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
    }
}

private struct CollectedRow: View {
    let report: ReportModel
    let item: ReportModel.CollectedItem
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Circle().fill(item.color).frame(width: 8, height: 8)
                .frame(width: 22)
            Text(item.name).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(item.error == nil ? Theme.primaryText : Theme.warning)
                .help(item.error ?? item.path)
            Spacer(minLength: 12)
            SizeText(parts: ByteSize.parts(item.size), fontSize: 13)
                .foregroundStyle(Theme.primaryText)
            Button { report.uncollect(item.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .opacity(isHovered ? 1 : 0)
            .padding(.leading, 8)
            .help("Take out of the Waste bin")
        }
        .font(.system(size: 13))
        .frame(height: 26)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHovered ? Theme.rowHighlight : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDrag { CollectorDrag.provider(uncollecting: item.id) }
        .contextMenu {
            Button("Take “\(item.name)” out of the Waste bin") { report.uncollect(item.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
        }
    }
}

// MARK: - Drag preview

/// What follows the pointer while an item is dragged toward the Waste bin: a small capsule with the item's color,
/// name and size (instead of a snapshot of the whole chart or row).
struct DragChip: View {
    let report: ReportModel
    let node: NodeRef

    var body: some View {
        let color = report.color(of: node)
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(report.displayName(node))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
            Text(ByteSize.string(report.size(of: node)))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background {
            Capsule().fill(Theme.popupFill)
                .overlay(Capsule().fill(color.opacity(NSApp.effectiveAppearance.isDark ? 0.22 : 0.08)))
                .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
        }
        .fixedSize()
        // The preview's left edge sits at the pointer, where macOS draws its "+" badge: start the chip past it.
        .padding(.leading, 22)
        // The drag preview is rendered outside the window: give it the app's appearance explicitly.
        .environment(\.colorScheme, NSApp.effectiveAppearance.isDark ? .dark : .light)
    }
}

// MARK: - Drag payloads

/// In-app drag payloads: "dg-collect:<node>" (chart/legend → Waste bin) and "dg-uncollect:<node>" (Waste bin → out).
enum CollectorDrag {
    static func provider(collecting node: NodeRef) -> NSItemProvider {
        NSItemProvider(object: "dg-collect:\(node.raw)" as NSString)
    }

    static func provider(uncollecting node: NodeRef) -> NSItemProvider {
        NSItemProvider(object: "dg-uncollect:\(node.raw)" as NSString)
    }

    @MainActor static func receive(_ providers: [NSItemProvider], collectInto report: ReportModel) -> Bool {
        // Files dragged in from Finder: collect them if they belong to this scan.
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !fileProviders.isEmpty {
            for provider in fileProviders {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let path = url?.standardizedFileURL.path else { return }
                    Task { @MainActor in report.collect(path: path) }
                }
            }
            return true
        }
        return load(providers, prefix: "dg-collect:") { report.collect($0) }
    }

    @MainActor static func receive(_ providers: [NSItemProvider], uncollectInto report: ReportModel) -> Bool {
        load(providers, prefix: "dg-uncollect:") { report.uncollect($0) }
    }

    @MainActor private static func load(_ providers: [NSItemProvider], prefix: String, apply: @escaping @MainActor (NodeRef) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, text.hasPrefix(prefix), let raw = UInt32(text.dropFirst(prefix.count)) else { return }
            Task { @MainActor in apply(NodeRef(raw: raw)) }
        }
        return true
    }
}
