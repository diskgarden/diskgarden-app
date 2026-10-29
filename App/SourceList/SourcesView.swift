import ScanEngine
import SwiftUI
import UniformTypeIdentifiers

/// Layout of the Volumes page (the design mock scaled to our window, ~0.72×).
enum VolumesMetrics {
    static let sideMargin: CGFloat = 32
    static let headerHeight: CGFloat = 50
    static let cardHeight: CGFloat = 78
    static let cardSpacing: CGFloat = 12
    static let footerHeight: CGFloat = 74
    /// The window grows with the list up to this many cards; beyond that the list scrolls.
    static let maxVisibleCards = 6

    /// Default window widths. The grid looks right at ~316 pt per column (3 columns ≈ 1000 pt), so its width follows
    /// the number of columns (items + the "Scan a folder…" tile); the list has one default.
    static let gridColumnWidth: CGFloat = 316
    static let gridMinColumnWidth: CGFloat = 230
    static let gridSidePadding: CGFloat = sideMargin - 8
    static let listDefaultWidth: CGFloat = 1000
    static let listMinWidth: CGFloat = 720

    static func gridColumns(items: Int) -> Int { max(1, items) + 1 }

    static func defaultWidth(items: Int, grid: Bool) -> CGFloat {
        grid ? 2 * gridSidePadding + CGFloat(gridColumns(items: items)) * gridColumnWidth : listDefaultWidth
    }

    static func minWidth(items: Int, grid: Bool) -> CGFloat {
        grid ? 2 * gridSidePadding + CGFloat(gridColumns(items: items)) * gridMinColumnWidth : listMinWidth
    }

    /// Height of the grid area (one row of tiles: ring, name, details, free space, button).
    static let gridHeight: CGFloat = 290
    static let gridBottomMargin: CGFloat = 28

    /// Window height: the grid's fixed height, or for the list `rows` cards fitted exactly, up to `maxVisibleCards`
    /// and `maxHeight` (the screen).
    static func pageHeight(rows: Int, grid: Bool, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        if grid { return min(Theme.titleBarHeight + headerHeight + gridHeight + gridBottomMargin, max(maxHeight, 300)) }
        let n = CGFloat(min(max(rows, 1), maxVisibleCards))
        let fitted = Theme.titleBarHeight + headerHeight + n * cardHeight + (n - 1) * cardSpacing + footerHeight
        // Never shorter than one card, even on a tiny screen.
        return max(Theme.titleBarHeight + headerHeight + cardHeight + footerHeight, min(fitted, maxHeight))
    }
}

/// The Volumes page: a header with the grid / list switch, then the grid (few items) or the list of cards.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window title lives in the toolbar (see `.toolbar` below); keep its 52pt band.
            Color.clear.frame(height: Theme.titleBarHeight)

            HStack(alignment: .firstTextBaseline) {
                Text("Volumes")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text(countSummary)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                if model.canShowVolumesGrid {
                    VolumesLayoutSwitch()
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        .padding(.leading, 10)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, VolumesMetrics.sideMargin + 2)
            .frame(height: VolumesMetrics.headerHeight, alignment: .top)

            Group {
                if model.showsVolumesGrid {
                    // Centered in any extra height (full screen); the window normally fits it exactly.
                    SourcesGrid()
                        .frame(maxHeight: .infinity)
                        .padding(.bottom, VolumesMetrics.gridBottomMargin)
                } else {
                    list
                }
            }
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.25), value: model.showsVolumesGrid)
        .animation(.easeInOut(duration: 0.2), value: model.canShowVolumesGrid)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.windowBackground.ignoresSafeArea()) // also under the rounded bottom corners' safe area
        .toolbar {
            PlainToolbarItem(placement: .principal) { BrandShareButton() }
            TrailingToolbarSpacer()
            PlainToolbarItem(placement: .primaryAction) { ShareToolbarCluster() }
        }
        .overlay { if isDropTargeted { DropHint() } }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    /// The list layout: cards that scroll past `maxVisibleCards`, and "Scan a folder…" below.
    private var list: some View {
        VStack(spacing: 0) {
            // Takes whatever height the window gives it (sized for up to `maxVisibleCards`); scrolls past that.
            GeometryReader { proxy in
                let statusWidth = min(400, max(220, (proxy.size.width - 2 * VolumesMetrics.sideMargin) * 0.36))
                ScrollView(.vertical) {
                    VStack(spacing: VolumesMetrics.cardSpacing) {
                        ForEach(model.sources) { source in
                            SourceRow(source: source, statusWidth: statusWidth)
                        }
                    }
                    .padding(.horizontal, VolumesMetrics.sideMargin)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button { model.chooseFolder() } label: {
                    Label("Scan a folder…", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(horizontalPadding: 16))
                Spacer()
            }
            .padding(.horizontal, VolumesMetrics.sideMargin)
            .frame(height: VolumesMetrics.footerHeight)
            .overlay(alignment: .top) {
                // A hairline under the list when it scrolls, so cards visibly slide beneath the footer.
                if model.sources.count > VolumesMetrics.maxVisibleCards { Theme.divider.frame(height: 1) }
            }
        }
    }

    /// "2 mounted", or "2 mounted · 1 folder" when folders were added.
    private var countSummary: String {
        let volumes = model.sources.filter { $0.volume != nil }.count
        let folders = model.sources.count - volumes
        var text = String(localized: "\(volumes) mounted", comment: "Volumes page header: number of mounted volumes; plural")
        if folders > 0 { text += " · " + String(localized: "\(folders) folders", comment: "Volumes page header: number of added folders; plural") }
        return text
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            Task { @MainActor in model.addFolder(url) }
        }
        return true
    }
}

/// Shown while a folder is dragged over the window.
private struct DropHint: View {
    var body: some View {
        ZStack {
            Theme.windowBackground.opacity(0.92)
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(.horizontal, VolumesMetrics.sideMargin)
                .padding(.top, Theme.titleBarHeight)
                .padding(.bottom, 16)
            Label("Let go to scan this folder", systemImage: "folder.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .padding(.top, Theme.titleBarHeight / 2)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let statusWidth: CGFloat
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(nsImage: source.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.iconTile))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1))
                .padding(.leading, 18)
                .padding(.trailing, 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(source.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if source.volume == nil {
                        FavoriteStar(isOn: source.isFavorite) { model.toggleFavorite(source.id) }
                    }
                }
                SourceSubtitle(source: source)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            status
                .frame(width: statusWidth)
                .padding(.trailing, 22)

            SourceActionButton(source: source)
                .fixedSize()
                .frame(minWidth: 92, alignment: .trailing)
                .padding(.trailing, 18)
        }
        .frame(height: VolumesMetrics.cardHeight)
        .glassCard(highlighted: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .onTapGesture(count: 2) {
            if source.hasResult { model.view(source.id) } else { model.scan(source.id) }
        }
        .contextMenu { SourceContextMenu(source: source) }
    }

    // MARK: Status column (bar + caption)

    @ViewBuilder private var status: some View {
        switch source.state {
        case .scanning:
            VStack(alignment: .leading, spacing: 8) {
                ScanningBar(progress: source.progress)
                Group {
                    if source.isLoadingSaved { Text("Opening saved scan…") }
                    else if source.adminActivity == nil { Text("Scanning…") }
                    else { Text("Scanning as administrator…") }
                }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        case .failed(let message):
            HStack {
                Spacer()
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        default:
            if let v = source.volume {
                let severity = UsageSeverity(freeFraction: 1 - v.usedFraction)
                VStack(spacing: 8) {
                    UsageBar(fraction: v.usedFraction, severity: severity)
                    HStack {
                        Text("\(ByteSize.string(UInt64(max(0, v.totalCapacity - v.freeBytes)))) used")
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                        Text("\(ByteSize.string(UInt64(v.freeBytes))) free")
                            .fontWeight(severity == .normal ? .regular : .semibold)
                            .foregroundStyle(severity.labelColor)
                    }
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .lineLimit(1)
                }
            } else {
                Color.clear
            }
        }
    }

}

struct FavoriteStar: View {
    let isOn: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            ZStack {
                let star = RoundedStar()
                if isOn {
                    star.fill(Color(hex: 0xF5C542))
                    star.stroke(Color(hex: 0xF5C542), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                } else {
                    star.stroke(isHovered ? Theme.primaryText : Theme.secondaryText,
                                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .frame(width: 14, height: 14)
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isOn ? Text("Unstar") : Text("Star to keep this folder in the list"))
    }
}

/// A five-point star; drawn with round line joins it gets soft, rounded tips.
struct RoundedStar: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let outer = min(rect.width, rect.height) / 2 * 0.92
        let inner = outer * 0.48
        var path = Path()
        for i in 0..<10 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let angle = -Double.pi / 2 + Double(i) * .pi / 5
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
