import SwiftUI

extension Color {
    /// Display P3 color from a hex triplet — the wide-gamut counterpart of `init(hex:)` below. The sunburst's folder
    /// colors are not hex literals: they are generated in OkLCh (see `SunburstPalette`), which is where the chart
    /// needs P3. Nothing calls this initializer at the moment; it is kept as the pair to `init(hex:)` for P3 literals.
    init(p3 hex: UInt32, opacity: Double = 1) {
        self.init(.displayP3,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// sRGB color from a hex triplet. UI tokens are sRGB samples of the design mocks.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

extension Color {
    /// A color that follows the app's appearance (Settings → Appearance; dark by default).
    init(dark: Color, light: Color) {
        let dark = NSColor(dark), light = NSColor(light)
        nonisolated(unsafe) let pair = (dark, light) // NSColor is immutable
        self.init(nsColor: NSColor(name: nil) { $0.isDark ? pair.0 : pair.1 })
    }

    init(dark: UInt32, light: UInt32) {
        self.init(dark: Color(hex: dark), light: Color(hex: light))
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Settings → Appearance.
enum AppAppearance: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match System"
        }
    }

    /// App-wide, so the full-screen toolbar strip (which follows the app, not the window) matches too.
    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }
}

/// DiskGarden's look: green-tinted near-black (or, in light mode, a green-tinted off-white), glass
/// cards with hairline borders, bold type, a green accent. Dark colors are sampled from the design mocks.
enum Theme {
    // Surfaces
    static let windowBackground = Color(dark: 0x0F1513, light: 0xF1F4F2)
    static let cardTop = Color(dark: 0x1D2523, light: 0xFFFFFF)
    static let cardBottom = Color(dark: 0x141C19, light: 0xFAFCFB)
    static let cardBorderTop = Color(dark: .white.opacity(0.15), light: .black.opacity(0.07))
    static let cardBorderBottom = Color(dark: .white.opacity(0.06), light: .black.opacity(0.09))
    static let controlFill = Color(dark: 0x353D3A, light: 0xFFFFFF)
    static let controlFillHover = Color(dark: 0x3E4744, light: 0xF4F6F5)
    static let controlFillPressed = Color(dark: 0x2C3431, light: 0xE9EDEB)
    static let controlBorder = Color(dark: .white.opacity(0.10), light: .black.opacity(0.06))
    static let controlDivider = Color(dark: 0x252C2A, light: 0xC9D2CD)
    static let rowHighlight = Color(dark: 0x313A37, light: 0xE6ECE9)
    static let divider = Color(dark: .white.opacity(0.08), light: .black.opacity(0.08))
    static let track = Color(dark: 0x2B3432, light: 0xDFE5E2)
    /// Floating chips: the toolbar's history buttons, the layout switch, hover labels, the drag chip.
    static let chipFill = Color(dark: 0x1C2422, light: 0xFFFFFF)
    static let popupFill = Color(dark: Color(hex: 0x131A17).opacity(0.94), light: Color.white.opacity(0.96))
    /// Square tiles behind volume icons.
    static let iconTile = Color(dark: 0x2B3231, light: 0xFFFFFF)
    /// Segmented switches (grid / list): the track and the selected segment.
    static let segmentTrack = Color(dark: 0x1C2422, light: 0xE5E9E6)
    static let segmentSelected = Color(dark: 0x3E4744, light: 0xFFFFFF)
    /// A faint wash for hovered rows and plain text boxes.
    static let subtleFill = Color(dark: .white.opacity(0.05), light: .black.opacity(0.04))
    /// The sunburst's center disc and the outline of the hovered wedge.
    static let centerDisc = Color(dark: 0x181E1C, light: 0xEBEDEB)
    static let chartOutline = Color(dark: .white.opacity(0.85), light: Color(hex: 0x141B18).opacity(0.75))
    /// Share-panel tiles for Copy / More….
    static let neutralTile = Color(dark: 0x3E4744, light: 0x7C8682)
    static let shadow = Color(dark: .black.opacity(0.35), light: .black.opacity(0.13))
    static let scrim = Color(dark: .black.opacity(0.45), light: .black.opacity(0.22))

    // Text
    static let primaryText = Color(dark: 0xF2F4F3, light: 0x141B18)
    static let secondaryText = Color(dark: 0x9BA39F, light: 0x5B6561)
    static let tertiaryText = Color(dark: 0x6C7572, light: 0x8E9893)
    static let hiddenSpaceText = Color(dark: 0xD58CEB, light: 0x9A3DB8)

    // Accents
    static let accent = Color(dark: 0x1ED660, light: 0x1FD260)
    static let accentText = Color(dark: 0x3BE07A, light: 0x0E8F3E)
    /// Text and icons on an accent-filled button.
    static let onAccent = Color(hex: 0x08170D)
    static let warning = Color(dark: 0xFF893D, light: 0xF5822F)
    static let critical = Color(dark: 0xFF5B4F, light: 0xE23B2E)
    static let scanning = Color(dark: 0x4FA3FF, light: 0x2B84E6)

    // Metrics (points)
    static let titleBarHeight: CGFloat = 52
    static let cardRadius: CGFloat = 20
    static let panelRadius: CGFloat = 22
}

// MARK: - Glass card

/// The mock's card: a dark vertical gradient, a hairline border that is brighter at the top, and a soft shadow.
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.cardRadius
    var highlighted = false

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(LinearGradient(colors: highlighted ? [Theme.cardTop.lighter(0.03), Theme.cardBottom.lighter(0.025)]
                                                         : [Theme.cardTop, Theme.cardBottom],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(LinearGradient(
                    colors: [Theme.cardBorderTop.opacity(highlighted ? 1.3 : 1), Theme.cardBorderBottom],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: Theme.shadow, radius: 14, y: 6)
        }
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.cardRadius, highlighted: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlighted: highlighted))
    }
}

extension Color {
    /// Hover/emphasis shift: adds `amount` of white (0…1) in dark mode, takes it away in light mode.
    func lighter(_ amount: Double) -> Color {
        nonisolated(unsafe) let base = NSColor(self)
        return Color(nsColor: NSColor(name: nil) { appearance in
            var ns = NSColor.black
            appearance.performAsCurrentDrawingAppearance { ns = base.usingColorSpace(.sRGB) ?? .black }
            let d = appearance.isDark ? amount : -amount
            return NSColor(srgbRed: ns.redComponent + d, green: ns.greenComponent + d, blue: ns.blueComponent + d,
                           alpha: ns.alphaComponent)
        })
    }
}

// MARK: - Brand

/// The seedling from the app icon: a stem with two leaves, drawn in a unit square (y down).
struct SproutShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        // Stem (a thin filled sliver so the whole mark is one fill).
        path.move(to: p(0.47, 0.98))
        path.addQuadCurve(to: p(0.47, 0.50), control: p(0.42, 0.74))
        path.addLine(to: p(0.55, 0.50))
        path.addQuadCurve(to: p(0.55, 0.98), control: p(0.50, 0.74))
        path.closeSubpath()
        // Left leaf.
        path.move(to: p(0.50, 0.54))
        path.addQuadCurve(to: p(0.04, 0.10), control: p(0.02, 0.52))
        path.addQuadCurve(to: p(0.50, 0.54), control: p(0.46, 0.08))
        path.closeSubpath()
        // Right leaf.
        path.move(to: p(0.52, 0.46))
        path.addQuadCurve(to: p(0.96, 0.02), control: p(0.56, 0.02))
        path.addQuadCurve(to: p(0.52, 0.46), control: p(0.98, 0.44))
        path.closeSubpath()
        return path
    }
}

/// "🌱 DiskGarden" — the brand shown in the title bar.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 7) {
            SproutShape()
                .fill(Theme.accent)
                .frame(width: 14, height: 16)
            Text(verbatim: "DiskGarden")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
        }
    }
}

/// Pushes the following toolbar items to the trailing edge (macOS 26; earlier systems already put `.primaryAction`
/// items there).
struct TrailingToolbarSpacer: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
    }
}

/// A toolbar item drawn as-is: on macOS 26 toolbar items otherwise get a shared "glass" capsule behind them.
struct PlainToolbarItem<Content: View>: ToolbarContent {
    let placement: ToolbarItemPlacement
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: placement) { content() }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: placement) { content() }
        }
    }
}
