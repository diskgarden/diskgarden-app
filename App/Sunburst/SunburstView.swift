import ScanEngine
import SwiftUI

/// The interactive sunburst: Canvas rendering, polar hit-testing, hover, click to zoom in,
/// click the center to zoom out, and animated transitions between layouts.
struct SunburstView: View {
    let tree: FileTree
    let layout: SunburstLayout
    /// Changes whenever `layout` should be animated to (focus change or data change).
    let layoutVersion: Int
    let centerSize: ByteSize.Parts
    /// Second line of the center disc ("of 994.6 GB used", "74% of Macintosh HD").
    let centerCaption: String?
    @Binding var hovered: SegmentKey?
    /// What to draw highlighted (the chart hover, or a hovered legend row). Changes cross-fade.
    var highlighted: SegmentKey?
    /// Updated only while the mouse moves over the chart (not when hover ends), so a context menu
    /// opened on a wedge still knows its target.
    @Binding var menuTarget: SegmentKey?
    var onOpen: (NodeRef) -> Void
    var onZoomOut: () -> Void
    /// Clicks on non-folder wedges (e.g. hidden space).
    var onSelect: (SunburstSegment) -> Void = { _ in }
    /// Title and detail line of the hover label for a segment.
    var describe: (SunburstSegment) -> (title: String, detail: String) = { _ in ("", "") }
    /// Direction of the labels' text (the chart itself is always laid out left to right).
    var textDirection: LayoutDirection = .leftToRight

    @State private var transition = SunburstTransition()
    @State private var fader = HoverFader()
    @Environment(\.colorScheme) private var colorScheme
    private var isLight: Bool { colorScheme == .light }

    var body: some View {
        GeometryReader { proxy in
            let geometry = RingGeometry.fitting(proxy.size)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            TimelineView(.animation(paused: !transition.isAnimating && !fader.isAnimating)) { timeline in
                Canvas { context, _ in
                    let t = transition.progress(at: timeline.date)
                    draw(in: &context, center: center, geometry: geometry, t: t, now: timeline.date)
                }
            }
            .overlay {
                CenterLabel(size: centerSize, caption: centerCaption, radius: geometry.holeRadius, scale: geometry.scale)
                    .environment(\.layoutDirection, textDirection)
                    .position(center)
                    .allowsHitTesting(false)
            }
            .overlay { tooltip(in: proxy.size, center: center, geometry: geometry) }
            .animation(.easeOut(duration: 0.12), value: highlighted)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if ProcessInfo.processInfo.environment["DG_TRACE"] != nil {
                        NSLog("DG hover %.0f,%.0f animating=%d", location.x, location.y, transition.isAnimating ? 1 : 0)
                    }
                    // While the chart zooms, wedges fly under the pointer: keep the current hover until it settles.
                    // (In-place refresh animations don't block hover.)
                    guard !transition.isZooming else { return }
                    let key = hitTest(location, center: center, geometry: geometry)?.key
                    if key != hovered { hovered = key }
                    if key != menuTarget { menuTarget = key }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                handleTap(at: value.location, center: center, geometry: geometry)
            })
        }
        .onAppear {
            transition.tree = tree
            transition.blossom(to: layout, delay: 0.3) // let the window finish resizing first
        }
        .onChange(of: layoutVersion) { transition.begin(to: layout) }
        .onChange(of: highlighted) { old, new in fader.change(from: old, to: new) }
    }

    // MARK: Interaction

    private func polar(_ point: CGPoint, center: CGPoint) -> (radius: CGFloat, angle: Double) {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        var angle = atan2(dy, dx) - Self.startAngle // 0 at the chart's start, increasing clockwise (y points down)
        while angle < 0 { angle += 2 * .pi }
        return (CGFloat(hypot(dx, dy)), angle)
    }

    private func hitTest(_ point: CGPoint, center: CGPoint, geometry: RingGeometry) -> SunburstSegment? {
        let (radius, angle) = polar(point, center: center)
        guard let depth = geometry.depth(atRadius: radius), depth > 0 else { return nil }
        return layout.hitTest(depth: depth, angle: angle)
    }

    private func handleTap(at point: CGPoint, center: CGPoint, geometry: RingGeometry) {
        guard !transition.isZooming else { return }
        let (radius, _) = polar(point, center: center)
        if radius < geometry.holeRadius {
            onZoomOut()
            return
        }
        guard let segment = hitTest(point, center: center, geometry: geometry) else { return }
        if segment.kind == .directory, let node = segment.node {
            hovered = nil
            onOpen(node)
        } else {
            onSelect(segment)
        }
    }

    // MARK: Hover label

    @State private var tooltipSize = CGSize(width: 180, height: 46)

    /// A capsule next to the highlighted wedge with its name, size and share, tinted with the wedge's color.
    @ViewBuilder
    private func tooltip(in size: CGSize, center: CGPoint, geometry: RingGeometry) -> some View {
        if let key = highlighted, !transition.isZooming, let segment = layout.segment(for: key) {
            let mid = Self.startAngle + (segment.start + segment.end) / 2
            let radii = geometry.radii(depth: segment.depth)
            let r = (radii.inner + radii.outer) / 2
            let anchor = CGPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
            let w = tooltipSize.width, h = tooltipSize.height
            // Extend away from the chart's center: to the right of wedges on the right half, left otherwise.
            let x = cos(mid) >= 0 ? anchor.x + w / 2 + 6 : anchor.x - w / 2 - 6
            let info = describe(segment)
            HoverLabel(title: info.title, detail: info.detail, color: SunburstPalette.rgb(for: segment, light: isLight).color)
                .environment(\.layoutDirection, textDirection)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                .position(x: min(max(x, w / 2 + 8), size.width - w / 2 - 8),
                          y: min(max(anchor.y, h / 2 + 8), size.height - h / 2 - 8))
                .id(key)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: Drawing

    private struct Wedge {
        var start: Double
        var end: Double
        var inner: CGFloat
        var outer: CGFloat
        var alpha: Double
        /// Clear space kept around the wedge (points).
        var gap: CGFloat
        /// Corner rounding (points).
        var radius: CGFloat

        func lerp(to other: Wedge, _ t: Double) -> Wedge {
            let ct = CGFloat(t)
            return Wedge(start: start + (other.start - start) * t, end: end + (other.end - end) * t,
                         inner: inner + (other.inner - inner) * ct, outer: outer + (other.outer - outer) * ct,
                         alpha: alpha + (other.alpha - alpha) * t, gap: gap + (other.gap - gap) * ct,
                         radius: radius + (other.radius - radius) * ct)
        }
    }

    private func wedge(_ s: SunburstSegment, geometry: RingGeometry, angleMap: (Double) -> Double = { $0 },
                       depthShift: Int = 0, sweep: Double = .infinity, alpha: Double = 1) -> Wedge {
        let radii = geometry.radii(depth: s.depth + depthShift)
        let start = min(max(angleMap(s.start), 0), sweep)
        let end = min(max(angleMap(s.end), 0), sweep)
        let depth = max(1, s.depth + depthShift)
        return Wedge(start: start, end: end, inner: radii.inner, outer: radii.outer, alpha: alpha,
                     gap: geometry.gap(depth: depth), radius: geometry.cornerRadius(depth: depth))
    }

    private func draw(in context: inout GraphicsContext, center: CGPoint, geometry: RingGeometry, t: Double, now: Date) {
        // Rounded tiles: fill the tile shrunk by the corner radius, then stroke it that wide with round joins, which
        // grows it back with round corners. Tiles too small to round are drawn sharp.
        func fill(_ w: Wedge, _ rgb: SunburstPalette.RGB, outlined: Bool = false) {
            guard w.alpha > 0.01, w.end - w.start > 0.0005, w.outer - w.inner > 0.2 else { return }
            var radius = w.radius
            var path = radius > 0.3 ? Self.annularSector(center: center, inner: w.inner, outer: w.outer,
                                                         start: w.start, end: w.end, gap: w.gap + 2 * radius) : nil
            if path == nil {
                radius = 0
                path = Self.annularSector(center: center, inner: w.inner, outer: w.outer, start: w.start, end: w.end, gap: w.gap)
            }
            guard let path else { return }
            context.opacity = w.alpha
            if outlined {
                context.stroke(path, with: .color(Theme.chartOutline),
                               style: StrokeStyle(lineWidth: 2 * radius + 3, lineJoin: .round))
            }
            let shading = GraphicsContext.Shading.radialGradient(
                Gradient(colors: [rgb.scaled(0.9).color, rgb.color]), center: center, startRadius: w.inner, endRadius: w.outer)
            context.fill(path, with: shading)
            if radius > 0 {
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2 * radius, lineJoin: .round))
            }
            context.opacity = 1
        }

        let e = Self.ease(t)
        if case .blossom = transition.kind {
            for ring in layout.rings {
                for s in ring {
                    var w = wedge(s, geometry: geometry)
                    let local = Self.easeOut(min(1, max(0, (t - 0.06 * Double(s.depth - 1)) / 0.55)))
                    w.start *= e
                    w.end *= e
                    w.outer = w.inner + (w.outer - w.inner) * CGFloat(local)
                    w.alpha = min(1, local * 1.5)
                    fill(w, SunburstPalette.rgb(for: s, light: isLight))
                }
            }
        } else if case .zoom(let map) = transition.kind, let from = transition.from, t < 1 {
            // Segments leaving: slide/squeeze toward their place in the new coordinate system.
            for ring in from.rings {
                for s in ring where layout.segment(for: s.key) == nil {
                    let start = wedge(s, geometry: geometry)
                    let end = wedge(s, geometry: geometry, angleMap: map.forward, depthShift: map.depthShift,
                                    sweep: layout.sweep, alpha: 0)
                    fill(start.lerp(to: end, e), SunburstPalette.rgb(for: s, light: isLight))
                }
            }
            // Segments staying or arriving.
            for ring in layout.rings {
                for s in ring {
                    let target = wedge(s, geometry: geometry)
                    let origin: Wedge
                    var color = SunburstPalette.rgb(for: s, light: isLight)
                    if let old = from.segment(for: s.key) {
                        origin = wedge(old, geometry: geometry)
                        // Colors are relative to the focus: a wedge that stays on screen blends to its new color.
                        color = SunburstPalette.rgb(for: old, light: isLight).mixed(with: color, e)
                    } else {
                        origin = wedge(s, geometry: geometry, angleMap: map.inverse, depthShift: -map.depthShift,
                                       sweep: from.sweep, alpha: 0)
                    }
                    fill(origin.lerp(to: target, e), color)
                }
            }
        } else {
            for ring in layout.rings {
                for s in ring {
                    let rgb = SunburstPalette.rgb(for: s, light: isLight)
                    let level = fader.level(for: s.key, at: now)
                    fill(wedge(s, geometry: geometry), level > 0 ? rgb.scaled(1 - (1 - SunburstPalette.hoverFactor) * level) : rgb,
                         outlined: s.key == highlighted)
                }
            }
        }

        // Center disc outline.
        let hole = geometry.holeRadius
        let disc = Path(ellipseIn: CGRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
        context.fill(disc, with: .color(Theme.centerDisc))
        context.stroke(disc, with: .color(Theme.controlBorder), lineWidth: 1)
    }

    /// A ring segment shrunk by `gap` on every side. The side edges stay parallel (the angular inset is larger at the
    /// inner radius), so neighbours are separated by an even channel, like DaisyDisk's tiles. nil if nothing is left.
    /// Screen angle where the sweep begins: 9 o'clock tilted 4° down, so the chart's left baseline isn't flat.
    static let startAngle = Double.pi - 4 * .pi / 180

    static func annularSector(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double,
                              gap: CGFloat) -> Path? {
        let half = gap / 2
        let r0 = inner + half, r1 = outer - half
        guard r1 > r0 else { return nil }
        let full = end - start >= 2 * .pi - 1e-6
        // Angular inset for a constant linear half-gap at each radius (a full ring needs no seam).
        let d1 = full ? 0 : Double(asin(min(1, half / r1)))
        let d0 = full ? 0 : Double(asin(min(1, half / max(r0, half))))
        let o0 = start + d1, o1 = end - d1
        guard o1 > o0 else { return nil } // narrower than the gap: the channel swallows it
        var i0 = start + d0, i1 = end - d0
        if i1 <= i0 { i0 = (start + end) / 2; i1 = i0 } // the wedge tapers to a point before the inner edge
        // Screen angle: chart start + sweep angle, clockwise on screen (y down).
        let a = startAngle
        var path = Path()
        path.addArc(center: center, radius: r1, startAngle: .radians(a + o0), endAngle: .radians(a + o1), clockwise: false)
        path.addArc(center: center, radius: r0, startAngle: .radians(a + i1), endAngle: .radians(a + i0), clockwise: true)
        path.closeSubpath()
        return path
    }

    static func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}

// MARK: - Transition state

/// Linear map between the angular coordinates of two layouts whose foci are ancestor/descendant.
struct ZoomMap {
    var scale: Double
    var offset: Double
    var depthShift: Int

    func forward(_ angle: Double) -> Double { angle * scale + offset }
    func inverse(_ angle: Double) -> Double { (angle - offset) / scale }

    static let identity = ZoomMap(scale: 1, offset: 0, depthShift: 0)
}

@MainActor @Observable
final class SunburstTransition {
    enum Kind {
        case none
        case blossom
        case zoom(ZoomMap)
    }

    private(set) var isAnimating = false
    @ObservationIgnored private(set) var kind: Kind = .none
    @ObservationIgnored private(set) var from: SunburstLayout?
    @ObservationIgnored private var current: SunburstLayout?
    @ObservationIgnored private var startDate = Date.distantPast
    @ObservationIgnored private var duration: TimeInterval = 0.5
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored var tree: FileTree?

    /// A focus change or blossom is running (as opposed to an in-place refresh of the same focus).
    var isZooming: Bool {
        guard isAnimating else { return false }
        switch kind {
        case .blossom: return true
        case .zoom(let map): return map.scale != 1 || map.offset != 0 || map.depthShift != 0
        case .none: return false
        }
    }

    func progress(at date: Date) -> Double {
        guard isAnimating else { return 1 }
        return min(1, max(0, date.timeIntervalSince(startDate) / duration))
    }

    func blossom(to layout: SunburstLayout, delay: TimeInterval = 0) {
        current = layout
        start(.blossom, from: nil, duration: 0.9, delay: delay)
    }

    func begin(to layout: SunburstLayout) {
        let previous = current
        current = layout
        guard let previous, let tree else {
            start(.blossom, from: nil, duration: 0.6)
            return
        }
        start(.zoom(Self.map(from: previous, to: layout, tree: tree)), from: previous, duration: 0.5)
    }

    private func start(_ kind: Kind, from: SunburstLayout?, duration: TimeInterval, delay: TimeInterval = 0) {
        self.kind = kind
        self.from = from
        self.duration = duration
        startDate = Date().addingTimeInterval(delay)
        isAnimating = true
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + delay))
            guard !Task.isCancelled, let self else { return }
            self.isAnimating = false
            self.kind = .none
            self.from = nil
        }
    }

    /// How to carry `old` coordinates into `new` ones: zooming into a descendant stretches its wedge to the
    /// full sweep; zooming out squeezes the old chart into the old focus' wedge.
    static func map(from old: SunburstLayout, to new: SunburstLayout, tree: FileTree) -> ZoomMap {
        if let k = old.relativeDepth(of: new.focus, in: tree), k > 0, let range = old.angleRange(of: new.focus, in: tree) {
            let width = max(1e-9, range.upperBound - range.lowerBound)
            let scale = new.sweep / width
            return ZoomMap(scale: scale, offset: -range.lowerBound * scale, depthShift: -k)
        }
        if let k = new.relativeDepth(of: old.focus, in: tree), k > 0, let range = new.angleRange(of: old.focus, in: tree) {
            let width = range.upperBound - range.lowerBound
            return ZoomMap(scale: width / max(1e-9, old.sweep), offset: range.lowerBound, depthShift: k)
        }
        return .identity
    }
}

// MARK: - Hover pulse

/// The hovered wedge "breathes": it cycles between its normal color and `SunburstPalette.hoverFactor` and back,
/// starting from normal the moment it's hovered. When the pointer leaves, the wedge eases back to normal.
///
/// The pulse is a raised cosine rather than a linear ramp, so it settles at both ends instead of snapping through
/// them — the wedge reads as breathing, not blinking. One full breath takes `period`: 1.2 s is slow enough that
/// the eye follows the swell rather than seeing a flash, and quick enough that a complete cycle lands inside a
/// normal hover. Both were picked by watching the chart, not measured from anything.
@MainActor @Observable
final class HoverFader {
    static let period: TimeInterval = 1.2
    static let fadeOut: TimeInterval = 0.15

    /// True while anything is pulsing or settling (keeps the Canvas redrawing).
    private(set) var isAnimating = false
    @ObservationIgnored private var active: (key: SegmentKey, start: Date)?
    @ObservationIgnored private var leaving: [SegmentKey: (from: Double, start: Date)] = [:]
    @ObservationIgnored private var settleTask: Task<Void, Never>?

    /// 0 = normal color … 1 = darkest.
    func level(for key: SegmentKey, at date: Date) -> Double {
        if let active, active.key == key {
            let phase = max(0, date.timeIntervalSince(active.start)) / Self.period
            return (1 - cos(2 * .pi * phase.truncatingRemainder(dividingBy: 1))) / 2
        }
        if let fade = leaving[key] {
            let t = min(1, max(0, date.timeIntervalSince(fade.start) / Self.fadeOut))
            return fade.from * (1 - t)
        }
        return 0
    }

    func change(from old: SegmentKey?, to new: SegmentKey?) {
        let now = Date()
        if let old { leaving[old] = (level(for: old, at: now), now) }
        active = new.map { ($0, now) }
        if let new { leaving[new] = nil }
        isAnimating = true
        settleTask?.cancel()
        guard active == nil else { return } // keeps pulsing while something is hovered
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.fadeOut + 0.02))
            guard !Task.isCancelled, let self else { return }
            self.leaving.removeAll()
            self.isAnimating = false
        }
    }
}

// MARK: - Center label

/// "508.7 GB" in bold with a small caption under it ("of 994.6 GB used").
private struct CenterLabel: View {
    let size: ByteSize.Parts
    let caption: String?
    let radius: CGFloat
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 3 * scale) {
            Text(verbatim: "\(size.number) \(size.unit)")
                .font(.system(size: 24 * scale, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: size.number)
            if let caption {
                Text(caption)
                    .font(.system(size: 11 * max(0.85, scale)))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: radius * 1.62)
    }
}

// MARK: - Hover label

private struct HoverLabel: View {
    let title: String
    let detail: String
    let color: Color
    /// The light design keeps the label white; dark mode tints it with the wedge's color.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = colorScheme == .light ? 0.0 : 1.0
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.primaryText.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(height: 46)
        .background {
            Capsule().fill(Theme.popupFill)
                .overlay(Capsule().fill(LinearGradient(colors: [color.opacity(0.42 * tint), color.opacity(0.18 * tint)],
                                                       startPoint: .leading, endPoint: .trailing)))
                .overlay(Capsule().strokeBorder(Theme.controlBorder, lineWidth: 1))
                .shadow(color: Theme.shadow, radius: 12, y: 4)
        }
    }
}
