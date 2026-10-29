import ScanEngine
import SwiftUI

/// Report page: path bar in the title band, sunburst on the left, legend on the right, collector at the bottom.
struct ReportView: View {
    @Environment(AppModel.self) private var app
    let report: ReportModel
    @FocusState private var isFocused: Bool
    @Environment(\.layoutDirection) private var layoutDirection
    /// Live chart scale while pinching (springs back to 1).
    @State private var pinchScale: CGFloat = 1
    /// Window width, for the toolbar's fixed-width navigation area.
    @State private var windowWidth: CGFloat = 900
    /// Where the traffic lights end (window x), read from the window: the toolbar's items start after them.
    @State private var toolbarLeadingInset: CGFloat = 80
    /// One navigation per pinch.
    @State private var pinchHandled = false

    var body: some View {
        @Bindable var report = report
        VStack(spacing: 0) {
            // The history buttons and breadcrumb live in the window toolbar (see `.toolbar` below).
            Color.clear.frame(height: Theme.titleBarHeight)

            GeometryReader { proxy in
                let panelWidth = min(380, max(300, proxy.size.width * 0.3))
                // Legend and Waste bin on the left, chart on the right.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if report.showsHiddenInfo {
                            HiddenSpaceLegend(report: report)
                        } else {
                            LegendView(report: report)
                        }
                        Spacer(minLength: 14)
                        CollectorView(report: report, mode: app.deletionMode)
                    }
                    .frame(width: panelWidth)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                    .padding(.leading, 24)
                    if report.showsHiddenInfo {
                        HiddenSpaceDonut(report: report)
                            .padding(.bottom, 12)
                            .frame(width: proxy.size.width - panelWidth - 24)
                            .contentShape(Rectangle())
                            .onTapGesture { report.showsHiddenInfo = false }
                    } else {
                    SunburstView(
                        tree: report.tree,
                        layout: report.layout,
                        layoutVersion: report.layoutVersion,
                        centerSize: ByteSize.parts(report.focusSize),
                        centerCaption: report.centerCaption,
                        hovered: $report.chartHover,
                        highlighted: report.highlighted,
                        menuTarget: $report.chartMenuTarget,
                        onOpen: { report.zoom(to: $0) },
                        onZoomOut: { report.zoomOut() },
                        onSelect: { segment in
                            if segment.kind == .hiddenSpace { report.showsHiddenInfo = true }
                            if segment.kind == .smallerObjects { report.expandSmaller(segment) }
                        },
                        describe: { (report.title(of: $0), report.tooltipDetail(of: $0)) },
                        textDirection: layoutDirection)
                    // The chart is a picture: its geometry (start angle, hit-testing, label placement) never mirrors.
                    .environment(\.layoutDirection, .leftToRight)
                    .contextMenu {
                        if case .node(let node)? = report.chartMenuTarget {
                            ItemContextMenu(report: report, node: node)
                        }
                    }
                    .onDrag {
                        guard case .node(let node)? = report.chartMenuTarget else { return NSItemProvider() }
                        return CollectorDrag.provider(collecting: node)
                    } preview: {
                        // A compact chip follows the pointer, not a snapshot of the whole chart.
                        if case .node(let node)? = report.chartMenuTarget {
                            DragChip(report: report, node: node)
                        }
                    }
                    .onDrop(of: [.plainText], isTargeted: nil) { providers in
                        CollectorDrag.receive(providers, uncollectInto: report)
                    }
                    .scaleEffect(pinchScale)
                    .padding(.bottom, 12)
                    .frame(width: proxy.size.width - panelWidth - 24)
                    }

                }
                .overlay(alignment: .bottom) {
                    if !report.showsHiddenInfo {
                        OutdatedNote(source: report.source)
                            .padding(.leading, panelWidth + 24) // centred under the chart
                            .padding(.bottom, 10)
                    }
                }
            }
        }
        .background(Theme.windowBackground.ignoresSafeArea()) // also under the rounded bottom corners' safe area
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            windowWidth = width
            if let zoom = MainWindow.current?.standardWindowButton(.zoomButton) {
                toolbarLeadingInset = zoom.convert(zoom.bounds, to: nil).maxX
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Trackpad pinch: in → parent folder, out → open the hovered folder (or "small items…").
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                guard !pinchHandled else { return }
                let m = value.magnification
                // Follow the fingers a little for tactile feedback.
                pinchScale = min(1.08, max(0.92, 1 + (m - 1) * 0.35))
                if m < 0.8 {
                    pinchHandled = true
                    springBack()
                    report.zoomOut()
                } else if m > 1.25, report.canExpandHovered {
                    pinchHandled = true
                    springBack()
                    report.expandHovered()
                }
            }
            .onEnded { _ in
                pinchHandled = false
                springBack()
            })
        .toolbar {
            PlainToolbarItem(placement: .navigation) {
                // One item spanning the bar: AppKit resizes toolbar items instantly (so a group that changed size —
                // the Volumes button widening, crumbs coming and going — jumped) and pushes items that don't fit into
                // an overflow menu. Inside one full-width item SwiftUI animates widths and lays out everything itself.
                HStack(spacing: 10) {
                    HistoryButtons(report: report) { app.showSources() }
                    VolumesButton { app.showSources() }
                    PathBar(report: report)
                        .layoutPriority(1) // offered the space before the drag area
                    // The empty middle still drags the window.
                    Color.clear.frame(minWidth: 8).contentShape(Rectangle()).gesture(WindowDragGesture())
                    ShareToolbarCluster(showsBrand: true, trailingPadding: 8)
                        .layoutPriority(2)
                }
                .padding(.leading, 12)
                .frame(width: max(400, windowWidth - toolbarLeadingInset - Self.toolbarItemInsets), alignment: .leading)
            }
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.space) {
            report.preview(report.previewTarget)
            return .handled
        }
        .background {
            // Invisible buttons carry the navigation shortcuts.
            Group {
                Button("") { report.zoomOut() }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("") { report.expandHovered() }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("") { report.collectHovered() }.keyboardShortcut(.delete, modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .overlay {
            if let bytes = app.congratulations {
                CongratulationsCard(bytes: bytes) { app.congratulations = nil }
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: app.congratulations)
        .onAppear { isFocused = true }
        .task { await runDebugZoomSequence() }
    }

    private func springBack() {
        withAnimation(.spring(duration: 0.3, bounce: 0.25)) { pinchScale = 1 }
    }

    /// `DG_ZOOM_SEQUENCE="Photos_etc;..;+junk.bin;-junk.bin;!delete"` replays steps every `DG_ZOOM_INTERVAL` seconds:
    /// a path (relative to the focus) zooms in, `..` zooms out, `+path` / `-path` collect / uncollect,
    /// `!delete` presses Delete. Used for scripted UI checks.
    private func runDebugZoomSequence() async {
        let env = ProcessInfo.processInfo.environment
        guard let sequence = env["DG_ZOOM_SEQUENCE"] else { return }
        let interval = Double(env["DG_ZOOM_INTERVAL"] ?? "") ?? 2
        for step in sequence.split(separator: ";") {
            try? await Task.sleep(for: .seconds(interval))
            func resolve(_ path: Substring) -> NodeRef {
                var node = report.focus
                for component in path.split(separator: "/") {
                    guard let next = report.tree.children(node).first(where: { report.tree.name($0) == component }) else { break }
                    node = next
                }
                return node
            }
            if step == ".." {
                report.zoomOut()
            } else if step == "!quickadmin" {
                app.quickRescanAsAdministrator(report.source.id)
            } else if step.hasPrefix("?") {
                report.chartHover = .node(resolve(step.dropFirst()))
            } else if step == "!attention" {
                ShareNudge.shared.bumpAttention(after: 0, shakes: 5) // as after a deletion
            } else if step == "!congrats" {
                app.congratulations = 10_700_000_000 // shows the card as after deleting 10.7 GB
            } else if step == "!home" {
                app.showSources()
            } else if step == "!rescan" {
                app.rescan(report.source.id)
            } else if step == "!smaller" {
                if let segment = report.layout.segment(for: .smaller(report.focus)) { report.expandSmaller(segment) }
            } else if step == "!hidden" {
                report.showsHiddenInfo = true
            } else if step == "!delete" {
                report.startDeletion(mode: app.deletionMode)
            } else if step.hasPrefix("+") {
                report.collect(resolve(step.dropFirst()))
            } else if step.hasPrefix("-") {
                report.uncollect(resolve(step.dropFirst()))
            } else {
                report.zoom(to: resolve(step))
            }
        }
    }
}

// MARK: - History

/// Back / forward in one glass pill.
extension ReportView {
    /// The toolbar's own spacing after the traffic lights and at the right edge. With the traffic lights ending at
    /// x = 79 (macOS 26), a total of 100 already spills the bar into the overflow menu and 104 fits; this keeps 4 pt
    /// of slack, taken from the share cluster's trailing padding so the right edge looks as before.
    static let toolbarItemInsets: CGFloat = 29
}

private struct HistoryButtons: View {
    let report: ReportModel
    let onSources: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Always available: history first; at the top of the disk it leaves for the Volumes page, and with no
            // history (e.g. a reopened result) it goes up a folder.
            Button {
                if report.isAtRoot { onSources() } else if report.canGoBack { report.goBack() } else { report.zoomOut() }
            } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
            Button { report.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!report.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(HistoryButtonStyle())
        .padding(.horizontal, 4)
        .toolbarPill()
    }
}

private struct HistoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HistoryButtonBody(configuration: configuration)
    }

    private struct HistoryButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.primaryText.opacity(configuration.isPressed ? 0.6 : 1) : Theme.tertiaryText)
                .frame(width: 34, height: 30)
                .background(Capsule().fill(isHovered && isEnabled ? Theme.subtleFill : .clear))
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
        }
    }
}

extension View {
    /// The mock's toolbar capsule: dark glass with a hairline border.
    func toolbarPill() -> some View {
        frame(height: 34)
            .background(Capsule().fill(Theme.chipFill))
            .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
            .shadow(color: Theme.shadow, radius: 6, y: 2)
    }
}

// MARK: - Breadcrumb

/// "Volumes › Macintosh HD › Users": earlier crumbs gray and clickable, the current one bold. Deep paths collapse the
/// middle into "…", which opens a menu of the hidden levels.
/// Leaves the report for the Volumes page: an icon that widens to show "Volumes" on hover.
private struct VolumesButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @State private var labelWidth: CGFloat = 60

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 13, weight: .semibold))
                    .frame(width: 16)
                // The label slides out to the right: its clip widens from 0 to the text's width.
                Text("Volumes", comment: "Breadcrumb / page title: the list of disks")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                    .padding(.leading, 6)
                    .frame(width: isHovered ? labelWidth + 6 : 0, alignment: .leading)
                    .clipped()
                    .opacity(isHovered ? 1 : 0)
            }
            .foregroundStyle(isHovered ? Theme.primaryText : Theme.secondaryText)
            .padding(.horizontal, isHovered ? 13 : 9)
            .toolbarPill()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.22)) { isHovered = hovering } }
        .accessibilityLabel(Text("Volumes", comment: "Breadcrumb / page title: the list of disks"))
    }
}

struct PathBar: View {
    let report: ReportModel

    var body: some View {
        let crumbs = report.breadcrumb
        // Collapse by width, not count: the full path when it fits, else hide more and more middle folders behind
        // "…" (the root and the current folder always stay).
        let hideCounts = crumbs.count > 2 ? Array(0 ... crumbs.count - 2) : [0]
        ViewThatFits(in: .horizontal) {
            ForEach(hideCounts, id: \.self) { hiddenCount in
                row(crumbs, hiding: hiddenCount)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: crumbs)
        .animation(.easeInOut(duration: 0.2), value: report.subsetStart)
    }

    /// The path with `count` crumbs after the root folded into a "…" menu.
    private func row(_ crumbs: [NodeRef], hiding count: Int) -> some View {
        let isSubset = report.subsetStart != nil
        let hidden = count > 0 ? Array(crumbs[1 ... count]) : []
        let visible = count > 0 ? [crumbs[0]] + crumbs[(count + 1)...] : crumbs

        return HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.element) { index, node in
                if index > 0 { Separator() }
                if index == 0 { // the scanned disk or folder itself: its icon marks the top
                    Image(systemName: rootIcon).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                }
                if !hidden.isEmpty && index == 1 {
                    Menu {
                        ForEach(hidden, id: \.self) { node in
                            Button(report.displayName(node)) { report.zoom(to: node) }
                        }
                    } label: {
                        Text("…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Separator()
                }
                Crumb(title: report.displayName(node), isCurrent: index == visible.count - 1 && !isSubset && !report.showsHiddenInfo) {
                    report.zoom(to: node)
                }
            }
            if isSubset {
                Separator()
                Crumb(title: String(localized: "small items", comment: "Breadcrumb: inside the smaller-objects group"), isCurrent: true) {}
            }
            if report.showsHiddenInfo {
                Separator()
                Crumb(title: String(localized: "hidden space…"), isCurrent: true) {}
            }
        }
        .padding(.horizontal, 16)
        .toolbarPill()
        .fixedSize()
    }

    private var rootIcon: String {
        guard let volume = report.source.volume else { return "folder.fill" }
        switch volume.kind {
        case .startupDisk, .localDisk: return "internaldrive"
        case .appleShare, .smbShare, .nfsShare, .webDAVShare, .networkDisk: return "server.rack"
        default: return volume.isInternal ? "internaldrive" : "externaldrive"
        }
    }

    private struct Separator: View {
        var body: some View {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    private struct Crumb: View {
        let title: String
        let isCurrent: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 13, weight: isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent || isHovered ? Theme.primaryText : Theme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }
            .buttonStyle(.plain)
            .disabled(isCurrent)
            .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Congratulations

private struct CongratulationsCard: View {
    let bytes: UInt64
    let dismiss: () -> Void
    @State private var isSharing = false

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(spacing: 12) {
                SproutShape()
                    .fill(Theme.accent)
                    .frame(width: 34, height: 38)
                    .padding(.bottom, 4)
                Text("Nice pruning!")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text("You've just freed up \(Text(ByteSize.string(bytes)).foregroundStyle(Theme.accentText).fontWeight(.bold)) on your disk.",
                     comment: "Congratulations card; the placeholder is a size like 12.4 GB")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                // Sharing is the main action here; the card can still be turned off in Settings → General.
                Button { isSharing = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up").frame(minWidth: 120)
                }
                .buttonStyle(PillButtonStyle(tint: Theme.accent))
                .keyboardShortcut(.defaultAction)
                .popover(isPresented: $isSharing, arrowEdge: .bottom) { SharePanel(content: .freed(bytes)) }
                .padding(.top, 8)
                Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, 2)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .glassCard(radius: 24)
        }
    }
}

// MARK: - Outdated result

/// A quiet line under the chart when the result may have missed changes (old, and not kept current by live
/// updates): "Scanned 5 hours ago · Rescan". Nothing happens on its own.
private struct OutdatedNote: View {
    @Environment(AppModel.self) private var app
    let source: Source
    @State private var isHovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if !source.isScanning, source.isOutdated(now: context.date, updatesLive: app.updatesLive), let date = source.scanDate {
                let when = date.formatted(.relative(presentation: .named))
                Button { app.rescan(source.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 10))
                        Text("Scanned \(when)", comment: "Report: the result is a few hours old, e.g. Scanned 5 hours ago")
                        Text(verbatim: "·")
                        Text("Rescan").foregroundStyle(isHovered ? Theme.accent : Theme.secondaryText)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help(String(localized: "Files may have changed since this scan."))
                .transition(.opacity)
            }
        }
    }
}
