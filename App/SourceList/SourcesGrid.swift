import ScanEngine
import SwiftUI

/// Grid layout of the Volumes page: one column per volume / folder (usage ring, name, details, free space, button)
/// and a last "Scan a folder…" tile, separated by hairlines. Only used for a few items (see `AppModel.maxGridItems`).
struct SourcesGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(model.sources) { source in
                SourceTile(source: source)
                    .frame(maxWidth: .infinity)
                Theme.divider
                    .frame(width: 1, height: VolumesMetrics.gridHeight * 0.78)
                    .padding(.top, 16)
            }
            ScanFolderTile()
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, VolumesMetrics.gridSidePadding)
        .frame(height: VolumesMetrics.gridHeight, alignment: .top)
    }
}

enum GridMetrics {
    static let ringSize: CGFloat = 132
    static let ringWidth: CGFloat = 9
}

/// One volume or folder in the grid.
struct SourceTile: View {
    @Environment(AppModel.self) private var model
    let source: Source
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            UsageRing(source: source)
                .padding(.top, 14)

            HStack(spacing: 10) {
                Text(source.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if source.volume == nil {
                    FavoriteStar(isOn: source.isFavorite) { model.toggleFavorite(source.id) }
                }
            }
            .padding(.top, 18)

            SourceSubtitle(source: source, includesScanAge: false)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            status
                .padding(.top, 6)

            // Buttons line up across columns at the bottom, whatever the text above wraps to.
            Spacer(minLength: 14)
            SourceActionButton(source: source, minTitleWidth: 104)
                .fixedSize()
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(isHovered ? Theme.subtleFill : .clear)
                .padding(.horizontal, 6)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        // The whole tile is the primary action (View / Scan), like its button; a scan in progress isn't cancelled by
        // a stray click. The buttons inside keep their own actions.
        .onTapGesture {
            guard !source.isScanning else { return }
            if source.hasResult { model.view(source.id) } else { model.scan(source.id) }
        }
        .contextMenu { SourceContextMenu(source: source) }
    }

    /// Free space (orange / red when low), or the scan state.
    @ViewBuilder private var status: some View {
        Group {
            switch source.state {
            case .scanning:
                if source.isLoadingSaved { Text("Opening saved scan…") }
                else if source.adminActivity == nil { Text("Scanning…") }
                else { Text("Scanning as administrator…") }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            default:
                if let v = source.volume {
                    let severity = UsageSeverity(freeFraction: 1 - v.usedFraction)
                    Text("\(ByteSize.string(UInt64(v.freeBytes))) free")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(severity.labelColor)
                } else {
                    EmptyView()
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.secondaryText)
        .multilineTextAlignment(.center)
    }
}

/// Used space as a ring around the volume's icon; progress (or a turning arc) while scanning.
struct UsageRing: View {
    let source: Source

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: GridMetrics.ringWidth)
            if source.isScanning {
                ScanningRing(progress: source.progress)
            } else if let v = source.volume {
                arc(to: v.usedFraction, color: UsageSeverity(freeFraction: 1 - v.usedFraction).fill)
                    .animation(.easeOut(duration: 0.5), value: v.usedFraction)
            }
            Image(nsImage: source.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.iconTile))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.controlBorder, lineWidth: 1))
                .shadow(color: Theme.shadow, radius: 6, y: 3)
        }
        .frame(width: GridMetrics.ringSize, height: GridMetrics.ringSize)
    }

    /// Clockwise from 12 o'clock.
    private func arc(to fraction: Double, color: Color) -> some View {
        Circle()
            .trim(from: 0, to: max(0.005, min(1, fraction)))
            .stroke(color, style: StrokeStyle(lineWidth: GridMetrics.ringWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}

/// The ring while scanning, in the list's striped-bar style: diagonal stripes run along the scanned arc (so they
/// turn with the ring as they travel around it). Unknown progress stripes the whole ring, like the list's bar.
struct ScanningRing: View {
    let progress: Double?

    /// Stripe period along the ring and travel speed, as in the list's ScanningBar.
    private static let period: CGFloat = 10
    private static let speed: CGFloat = 16 // points per second

    /// Eases the drawn progress toward the latest value (the Canvas redraws every frame, but isn't animatable).
    @State private var smoother = ProgressSmoother()

    var body: some View {
        let target = progress.map { max(0.02, min(1, $0)) } ?? 1
        TimelineView(.animation) { timeline in
            let fraction = smoother.value(toward: target, at: timeline.date)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let width = GridMetrics.ringWidth
                // Same circle as the track: SwiftUI strokes it centered on the ring frame's edge.
                let radius = GridMetrics.ringSize / 2
                let start = -Double.pi / 2
                let sweep = 2 * Double.pi * fraction

                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .radians(start),
                           endAngle: .radians(start + sweep), clockwise: false)
                let band = arc.strokedPath(StrokeStyle(lineWidth: width, lineCap: fraction < 1 ? .round : .butt))
                context.clip(to: band)
                context.fill(band, with: .color(Theme.accent.opacity(0.55)))

                // Point at arc length `s` (measured on the middle radius) and radius offset `dr` from the middle.
                func point(_ s: CGFloat, _ dr: CGFloat) -> CGPoint {
                    let angle = start + Double(s / radius)
                    let r = radius + dr
                    return CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y + CGFloat(sin(angle)) * r)
                }
                let period = Self.period
                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate) * Self.speed
                let length = radius * CGFloat(sweep)
                var s = phase.truncatingRemainder(dividingBy: period) - period - width
                while s < length + period {
                    // A parallelogram slanted 45° to the ring: inner edge at s, outer edge shifted by the ring width.
                    var stripe = Path()
                    stripe.move(to: point(s, -width / 2 - 1))
                    stripe.addLine(to: point(s + width + 2, width / 2 + 1))
                    stripe.addLine(to: point(s + width + 2 + period / 2, width / 2 + 1))
                    stripe.addLine(to: point(s + period / 2, -width / 2 - 1))
                    stripe.closeSubpath()
                    context.fill(stripe, with: .color(Theme.accent))
                    s += period
                }
            }
        }
        // The track's stroke reaches half a ring width outside the ring frame: draw over that area too, but lay out at
        // the ring's size (a bigger frame would also grow the ZStack, and the track circle with it).
        .frame(width: GridMetrics.ringSize + GridMetrics.ringWidth, height: GridMetrics.ringSize + GridMetrics.ringWidth)
        .padding(-GridMetrics.ringWidth / 2)
    }
}

/// Frame-rate-independent easing of a displayed value toward a moving target: ~95% of the way in 0.25 s, like the
/// list bar's progress animation.
final class ProgressSmoother {
    private var current: Double?
    private var last: Date?
    private static let timeConstant = 0.08 // seconds

    func value(toward target: Double, at date: Date) -> Double {
        defer { last = date }
        guard let current, let last else {
            current = target
            return target
        }
        let dt = max(0, min(0.1, date.timeIntervalSince(last)))
        let next = current + (target - current) * (1 - exp(-dt / Self.timeConstant))
        self.current = abs(target - next) < 0.0005 ? target : next
        return self.current ?? target
    }
}

/// The grid's last tile: a dashed circle that opens the folder picker.
struct ScanFolderTile: View {
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        Button { model.chooseFolder() } label: {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .strokeBorder(isHovered ? Theme.accent.opacity(0.8) : Theme.tertiaryText,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(isHovered ? Theme.primaryText : Theme.secondaryText)
                }
                .frame(width: GridMetrics.ringSize, height: GridMetrics.ringSize)
                .padding(.top, 14)
                Text("Scan a folder…")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isHovered ? Theme.primaryText : Theme.secondaryText)
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

/// Grid / list switch in the Volumes header.
struct VolumesLayoutSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            segment(.grid, systemImage: "square.grid.2x2", help: Text("Show as grid", comment: "Volumes page layout switch"))
            segment(.list, systemImage: "list.bullet", help: Text("Show as list", comment: "Volumes page layout switch"))
        }
        .padding(3)
        .background(Capsule().fill(Theme.segmentTrack))
        .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
    }

    private func segment(_ layout: AppModel.VolumesLayout, systemImage: String, help: Text) -> some View {
        let isOn = model.volumesLayout == layout
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.volumesLayout = layout }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Theme.primaryText : Theme.secondaryText)
                .frame(width: 34, height: 24)
                .background(Capsule().fill(isOn ? Theme.segmentSelected : .clear).shadow(color: isOn ? Theme.shadow.opacity(0.6) : .clear, radius: 2, y: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
