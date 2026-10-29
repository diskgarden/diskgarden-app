import ScanEngine
import AppKit
import Synchronization
import SwiftUI

/// Right-hand panel: a glass card describing the hovered item (or the focus) — name, share summary, a stacked
/// composition bar, then its children with percentages and decimal-aligned sizes. The card hugs its content and
/// scrolls inside when the listing is taller than the space available.
struct LegendView: View {
    let report: ReportModel
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // The tree itself isn't observable; reading the layout version re-renders the list after any relayout
        // (collecting, deletion, live refresh).
        let _ = report.layoutVersion
        let node = report.legendNode
        let listing = report.listing(for: node)
        let total = max(1, node == report.focus ? report.focusSize : report.size(of: node))
        let isSubset = node == report.focus && report.subsetStart != nil
        let isRoot = node == report.tree.root && !isSubset
        let capacity = isRoot ? report.source.volume.map { UInt64(max(0, $0.totalCapacity)) } : nil
        let showsFree = isRoot && (node == report.focus || report.chartHover == nil)

        VStack(alignment: .leading, spacing: 0) {
            LegendHeader(
                name: isSubset ? String(localized: "small items…") : report.displayName(node),
                summary: isSubset ? report.centerCaption : report.shareSummary(of: node))
                .padding(.horizontal, 20)
                .padding(.top, 18)

            if report.tree.isDirectory(node) {
                CompositionBar(segments: listing.topLevel, total: Double(max(total, capacity ?? 0)),
                               highlighted: report.highlighted)
                    .frame(height: 8)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if report.tree.isDirectory(node) {
                        ForEach(listing.topLevel, id: \.key) { segment in
                            LegendRow(
                                report: report,
                                segment: segment,
                                title: title(for: segment),
                                fraction: Double(segment.size) / Double(total))
                        }
                    }

                    if showsFree, let free = report.freeBytes, let purgeable = report.freePlusPurgeableBytes {
                        Theme.divider.frame(height: 1).padding(.vertical, 10).padding(.horizontal, 10)
                        LegendInfoRow(glyph: .ring, title: "Available", size: free)
                        LegendInfoRow(glyph: .dashedRing, title: "Available (incl. purgeable)", size: purgeable)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: max(1, contentHeight))
        }
        .glassCard(radius: Theme.panelRadius)
        .animation(.easeOut(duration: 0.12), value: node)
    }

    private func title(for segment: SunburstSegment) -> String { report.title(of: segment) }
}

private struct LegendHeader: View {
    let name: String
    let summary: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.system(size: LegendMetrics.headerSize, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let summary {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Thin stacked bar: one segment per listed item, in chart colors, over the track. At a volume root it's scaled to
/// the disk's capacity, so the empty track on the right is the free space.
private struct CompositionBar: View {
    let segments: [SunburstSegment]
    let total: Double
    let highlighted: SegmentKey?
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let rightToLeft = layoutDirection == .rightToLeft
        let highlightedIsListed = highlighted.map { key in segments.contains { $0.key == key } } ?? false
        Canvas { context, size in
            context.clip(to: Capsule().path(in: CGRect(origin: .zero, size: size)))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.track))
            let gap: CGFloat = 2
            var x: CGFloat = 0
            for segment in segments {
                let width = size.width * CGFloat(Double(segment.size) / max(1, total))
                defer { x += width }
                guard width >= 1 else { continue }
                let dimmed = highlightedIsListed && highlighted != segment.key
                let w = max(1, width - gap)
                // Right-to-left languages fill the bar from the right, like the rest of the mirrored layout.
                context.fill(Path(CGRect(x: rightToLeft ? size.width - x - w : x, y: 0, width: w, height: size.height)),
                             with: .color(LegendRow.dotColor(for: segment).opacity(dimmed ? 0.45 : 1)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: highlighted)
    }
}

struct LegendRow: View {
    @Environment(AppModel.self) private var app
    let report: ReportModel
    let segment: SunburstSegment
    let title: String
    /// Share of the described item.
    let fraction: Double

    private var isHighlighted: Bool { report.highlighted == segment.key }
    private var isRestricted: Bool { segment.node.map { report.tree.flags($0).contains(.restricted) } ?? false }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Circle().fill(Self.dotColor(for: segment))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + LegendMetrics.capCenter(LegendMetrics.rowSize) }
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 8)
            Text(title)
                .font(.system(size: LegendMetrics.rowSize, weight: isHighlighted ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameColor)
            if isRestricted {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.leading, 5)
                    .help("Restricted folder: DiskGarden couldn't read it. Grant Full Disk Access or run a Deep Scan (Admin).")
            }
            Spacer(minLength: 10)
            Text(ReportModel.percent(fraction))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 14)
            SizeText(parts: ByteSize.parts(segment.size), fontSize: LegendMetrics.rowSize)
                .foregroundStyle(LegendMetrics.text)
                // A fixed-width size column keeps the percentage column straight whatever the sizes.
                .frame(width: SizeText.columnWidth(size: LegendMetrics.rowSize), alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.rowHighlight)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.controlBorder))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { report.listHover = segment.key } else if report.listHover == segment.key { report.listHover = nil }
        }
        .onTapGesture {
            if segment.kind == .directory, let node = segment.node { report.zoom(to: node) }
            if segment.kind == .hiddenSpace { report.showsHiddenInfo = true }
            if segment.kind == .smallerObjects { report.expandSmaller(segment) }
        }
        .contextMenu {
            if let node = segment.node { ItemContextMenu(report: report, node: node) }
        }
        .onDrag {
            guard let node = segment.node else { return NSItemProvider() }
            return CollectorDrag.provider(collecting: node)
        } preview: {
            if let node = segment.node { DragChip(report: report, node: node) }
        }
    }

    static func dotColor(for segment: SunburstSegment) -> Color {
        switch segment.kind {
        case .smallerObjects: Color(dark: SunburstPalette.smallerObjectsDot.color, light: SunburstPalette.smallerObjectsDotLight.color)
        case .directory: SunburstPalette.directoryColor(hue: segment.hue, depth: 1)
        default: Color(dark: SunburstPalette.rgb(for: segment).color, light: SunburstPalette.rgb(for: segment, light: true).color)
        }
    }

    /// Names are white, except the gray "small items…" and purple "hidden space…". Sizes are all white.
    private var nameColor: Color {
        switch segment.kind {
        case .smallerObjects: Theme.secondaryText
        case .hiddenSpace: Theme.hiddenSpaceText
        default: LegendMetrics.text
        }
    }
}

private struct LegendInfoRow: View {
    enum Glyph { case ring, dashedRing }
    let glyph: Glyph
    let title: LocalizedStringKey
    let size: UInt64

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Circle()
                .strokeBorder(Theme.secondaryText,
                              style: glyph == .ring ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .frame(width: 9, height: 9)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + LegendMetrics.capCenter(LegendMetrics.rowSize) }
                .frame(width: 16, alignment: .center)
                .padding(.trailing, 8)
            Text(title)
                .foregroundStyle(Theme.primaryText.opacity(0.82))
            Spacer()
            SizeText(parts: ByteSize.parts(size), fontSize: LegendMetrics.rowSize)
                .foregroundStyle(LegendMetrics.text)
        }
        .font(.system(size: LegendMetrics.rowSize))
        .padding(.horizontal, 10)
        .frame(height: 28)
    }
}

/// Legend typography: uniform 14 pt rows, a bold 20 pt header.
enum LegendMetrics {
    static let rowSize: CGFloat = 14
    static let headerSize: CGFloat = 20
    static let text = Theme.primaryText

    /// Distance from the baseline up to the middle of the capitals: dots sit there.
    static func capCenter(_ size: CGFloat) -> CGFloat { NSFont.systemFont(ofSize: size).capHeight / 2 }
}

/// "7.3 GB" / "5   GB": numbers aligned on the decimal point (a slot the width of ".0" is always reserved),
/// units right-aligned in a fixed column so every size in the list ends at the same edge — header included.
struct SizeText: View {
    let parts: ByteSize.Parts
    let fontSize: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        let (whole, fraction) = Self.split(parts.number)
        let unit = parts.unit == ByteSize.unitName("bytes") || parts.unit == ByteSize.unitName("byte") ? L10n.shortByteUnit : parts.unit
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(whole)
            Text(fraction)
                .frame(width: Self.width(of: ByteSize.decimalSeparator + "0", size: fontSize, weight: weight), alignment: .leading)
            Text(unit)
                .frame(width: Self.unitColumnWidth(size: fontSize, weight: weight) + fontSize * 0.28, alignment: .trailing)
        }
        .font(.system(size: fontSize, weight: weight))
        // Number and unit read as one token ("385.5 GB"), also in right-to-left languages.
        .environment(\.layoutDirection, .leftToRight)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    static func split(_ number: String) -> (String, String) {
        guard let dot = number.range(of: ByteSize.decimalSeparator) else { return (number, "") }
        return (String(number[..<dot.lowerBound]), String(number[dot.lowerBound...]))
    }

    /// Width of the widest size a column shows ("999.9" + the widest unit).
    static func columnWidth(size: CGFloat, weight: Font.Weight = .regular) -> CGFloat {
        width(of: "999", size: size, weight: weight) + width(of: ByteSize.decimalSeparator + "0", size: size, weight: weight)
            + unitColumnWidth(size: size, weight: weight) + size * 0.28
    }

    /// Width of the widest unit name in the user's language ("MB", "Mo", "МБ", …).
    static func unitColumnWidth(size: CGFloat, weight: Font.Weight) -> CGFloat {
        L10n.allUnitNames.map { width(of: $0, size: size, weight: weight) }.max() ?? 0
    }

    private static let widthCache = Mutex<[String: CGFloat]>([:])

    /// Rendered width of `text` in the system font with monospaced digits (cached).
    static func width(of text: String, size: CGFloat, weight: Font.Weight) -> CGFloat {
        let key = "\(text)|\(size)|\(weight)"
        if let cached = widthCache.withLock({ $0[key] }) { return cached }
        let nsWeight: NSFont.Weight = switch weight {
        case .light: .light
        case .thin: .thin
        case .medium: .medium
        case .semibold: .semibold
        default: .regular
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: nsWeight)
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widthCache.withLock { $0[key] = width }
        return width
    }
}
