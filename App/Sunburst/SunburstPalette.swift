import ScanEngine
import SwiftUI

/// The sunburst's folder colors are generated rather than sampled: a hue from the wedge's place in the ring, then
/// the same lightness and the same colorfulness for every hue in that ring. Both are set in OkLCh, where "the same
/// lightness" and "the same colorfulness" mean the same thing to the eye whatever the hue, so no folder reads as more
/// important than another just because of where it landed on the wheel. Display P3 throughout, and not for show:
/// roughly two thirds of the dark-theme wheel is more colorful than sRGB can represent.
enum SunburstPalette {
    static let file = RGB(0x6E, 0x77, 0x74)
    /// "Smaller objects…" wedges are a dark neutral tile (the mock's `#262D2B`); the legend dot is lighter to stay visible.
    static let smallerObjects = RGB(0x29, 0x31, 0x2F)
    static let smallerObjectsDot = RGB(0x6E, 0x76, 0x73)
    static let hiddenSpace = RGB(0x7A, 0x3C, 0x89)
    /// Light-mode neutrals (the colored tiles stay the same on both backgrounds).
    static let fileLight = RGB(0xA6, 0xAF, 0xAB)
    static let smallerObjectsLight = RGB(0xDC, 0xDF, 0xDD)
    static let smallerObjectsDotLight = RGB(0xA6, 0xAF, 0xAB)
    /// Darkest point of the hover pulse, as a multiplier on the tile's P3 components. Chosen so the pulse bottoms out
    /// about 17% below the tile's OkLab lightness, near enough the same drop in both appearances: far more than the
    /// step between rings (`ringStep`), so the hovered tile is unmistakable next to its untouched neighbours, and
    /// little enough that it stays recognisably the same folder rather than turning into a different color.
    /// `HoverFader` holds the shape and the period.
    static let hoverFactor = 0.78

    struct RGB: Equatable {
        var r: Double, g: Double, b: Double

        init(_ r: Int, _ g: Int, _ b: Int) {
            self.r = Double(r) / 255
            self.g = Double(g) / 255
            self.b = Double(b) / 255
        }

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        var color: Color { Color(.displayP3, red: r, green: g, blue: b) }

        func scaled(_ factor: Double) -> RGB { RGB(r: r * factor, g: g * factor, b: b * factor) }

        /// Linear blend toward `other` (t = 0 … 1), for color changes during zoom animations.
        func mixed(with other: RGB, _ t: Double) -> RGB {
            RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }
    }

    static func rgb(for segment: SunburstSegment, light: Bool = false) -> RGB {
        switch segment.kind {
        case .file: light ? fileLight : file
        case .smallerObjects: light ? smallerObjectsLight : smallerObjects
        case .hiddenSpace: hiddenSpace
        case .directory: directory(hue: segment.hue, depth: segment.depth, light: light)
        }
    }

    /// A folder color that follows the appearance (legend dots, path bar).
    static func directoryColor(hue: Double, depth: Int) -> Color {
        Color(dark: directory(hue: hue, depth: depth).color, light: directory(hue: hue, depth: depth, light: true).color)
    }

    // MARK: - The wheel

    /// How fast hue runs ahead of position. A ring is ordered big-to-small, so its long tail of small folders shares
    /// very little angle and, at an exponent of 1, would share just as little of the wheel, leaving the slivers in the
    /// outer rings very close in color. Above 1 the tail gets more hue per byte than the head: at 1.5 a wedge nine
    /// tenths of the way round the ring advances hue three times as fast as one a tenth of the way round (9^0.5 = 3).
    /// Pushed further it starts costing more than it buys, because the few large folders at the head of the ring are
    /// squeezed into an ever smaller corner of the wheel. 1.5 is where those two meet: on real scans the color gap
    /// between angularly adjacent tiles climbs up to about this exponent and flattens or falls after it. Chosen for
    /// that; not fitted to any particular chart.
    static let hueExponent = 1.5

    /// Folder hue in degrees, from the wedge's position in the ring (0…1 by cumulative size).
    static func degrees(forPosition position: Double) -> Double {
        let p = min(1, max(0, (position.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)))
        return pow(p, hueExponent) * 360
    }

    /// OkLCh lightness of a tile on the reference ring, per appearance. One lightness for the whole chart, not one per
    /// hue — that is the whole point of using OkLCh here. 0.80 is where a tile on the near-black backdrop reads as a
    /// color rather than a glowing pastel. 0.66 is the light-theme counterpart: the gaps between tiles are the
    /// backdrop showing through, so contrast with it is already taken care of, and going darker than this only turns
    /// the yellow quadrant of the wheel brown without making anything easier to tell apart.
    private static let baseLightness = (dark: 0.80, light: 0.66)
    /// OkLCh chroma of every tile. 0.155 is about the most Display P3 can hold right round the wheel without dragging
    /// some hues far off `baseLightness`; above it the blues and cyans would have to sit much deeper than the rest.
    private static let chroma = 0.155
    /// Each ring outward steps this much further from the backdrop — lighter on the dark theme, darker on the light
    /// one — so the thin outer slivers keep their contrast instead of fading into it. Ring 2 is the reference ring.
    private static let ringStep = 0.012

    static func directory(hue: Double, depth: Int, light: Bool = false) -> RGB {
        let ring = Double(min(max(depth, 1), 6)) - 2
        let lightness = light ? baseLightness.light - ringStep * ring : baseLightness.dark + ringStep * ring
        return oklch(lightness: lightness, chroma: chroma, degrees: degrees(forPosition: hue))
    }

    /// OkLCh → Display P3, preferring to keep the chroma. Where P3 can't hold it at this lightness the tile is
    /// darkened just enough to fit, which is why the blues and violets sit a little deeper than the rest of the wheel.
    /// Where no lightness can (the cyans on the light theme, whose extra chroma only exists at lightnesses too close
    /// to the backdrop to be usable), the chroma is pulled in instead.
    static func oklch(lightness: Double, chroma: Double, degrees: Double) -> RGB {
        let radians = degrees * .pi / 180
        let (a, b) = (cos(radians), sin(radians))
        if let fit = p3(lightness, chroma * a, chroma * b) { return fit }
        var low = 0.2, high = lightness
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if p3(mid, chroma * a, chroma * b) != nil { low = mid } else { high = mid }
        }
        if let fit = p3(low, chroma * a, chroma * b) { return fit }
        var thin = 0.0, wide = chroma
        for _ in 0..<24 {
            let mid = (thin + wide) / 2
            if p3(lightness, mid * a, mid * b) != nil { thin = mid } else { wide = mid }
        }
        return p3(lightness, thin * a, thin * b) ?? RGB(r: lightness, g: lightness, b: lightness)
    }

    /// Oklab → Display P3, or nil when the color falls outside the display's gamut. Ottosson's Oklab↔LMS matrices
    /// composed with XYZ (D65) → linear Display P3, then the sRGB transfer function, which Display P3 shares.
    private static func p3(_ l: Double, _ a: Double, _ b: Double) -> RGB? {
        let lms = (pow(l + 0.3963377774 * a + 0.2158037573 * b, 3),
                   pow(l - 0.1055613458 * a - 0.0638541728 * b, 3),
                   pow(l - 0.0894841775 * a - 1.2914855480 * b, 3))
        let x = 1.2270138511 * lms.0 - 0.5577999807 * lms.1 + 0.2812561490 * lms.2
        let y = -0.0405801784 * lms.0 + 1.1122568696 * lms.1 - 0.0716766787 * lms.2
        let z = -0.0763812845 * lms.0 - 0.4214819784 * lms.1 + 1.5861632204 * lms.2
        func encode(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        let rgb = (encode(2.4934969119 * x - 0.9313836179 * y - 0.4027107845 * z),
                   encode(-0.8294889696 * x + 1.7626640603 * y + 0.0236246858 * z),
                   encode(0.0358458302 * x - 0.0761723893 * y + 0.9568845240 * z))
        let slack = 0.0005
        guard rgb.0 >= -slack, rgb.0 <= 1 + slack, rgb.1 >= -slack, rgb.1 <= 1 + slack,
              rgb.2 >= -slack, rgb.2 <= 1 + slack else { return nil }
        return RGB(r: min(1, max(0, rgb.0)), g: min(1, max(0, rgb.1)), b: min(1, max(0, rgb.2)))
    }

    /// Color used for list dots and the center label tint.
    static func color(for segment: SunburstSegment, highlighted: Bool = false) -> Color {
        let base = rgb(for: segment)
        return (highlighted ? base.scaled(hoverFactor) : base).color
    }
}

/// Radii of the rings: a big center disc, a thick first ring, then progressively thinner rings of tiles.
struct RingGeometry {
    static let hole: CGFloat = 64
    /// Ring thickness by depth (1-based).
    static let thicknesses: [CGFloat] = [58, 44, 36, 30, 25, 20, 16, 13, 10]
    static let maxDepth = 9

    let scale: CGFloat

    static func thickness(_ depth: Int) -> CGFloat { thicknesses[min(max(depth, 1), maxDepth) - 1] }

    /// Clear space between neighbouring tiles (and rings), in points.
    func gap(depth: Int) -> CGFloat {
        (depth <= 6 ? 3.0 : 2.5) * max(0.75, scale)
    }

    /// Corner radius of the tiles: 4 pt, less on thin rings so they don't turn into pills.
    func cornerRadius(depth: Int) -> CGFloat {
        min(4, Self.thickness(depth) * scale / 5)
    }

    static let unscaledInner: [CGFloat] = {
        var radii: [CGFloat] = [hole]
        for depth in 1...maxDepth { radii.append(radii[depth - 1] + thickness(depth)) }
        return radii
    }()

    static var unscaledOuterRadius: CGFloat { unscaledInner[maxDepth] }

    /// Scale so the full chart fits a square of `side` points with a margin.
    static func fitting(_ size: CGSize) -> RingGeometry {
        let available = min(size.width, size.height) / 2 - 16
        // Grows with big windows / full screen too (up to 1.6×), not just shrinks.
        return RingGeometry(scale: max(0.5, min(1.6, available / unscaledOuterRadius)))
    }

    var holeRadius: CGFloat { Self.hole * scale }
    var outerRadius: CGFloat { Self.unscaledOuterRadius * scale }

    /// Inner/outer radius of ring `depth`. Depths ≤ 0 collapse into the hole, depths past the last ring onto the rim.
    func radii(depth: Int) -> (inner: CGFloat, outer: CGFloat) {
        if depth < 1 { return (holeRadius, holeRadius) }
        if depth > Self.maxDepth { return (outerRadius, outerRadius) }
        return (Self.unscaledInner[depth - 1] * scale, Self.unscaledInner[depth] * scale)
    }

    /// Ring index under a radius, or 0 for the center disc, nil outside the chart.
    func depth(atRadius r: CGFloat) -> Int? {
        if r < holeRadius { return 0 }
        for depth in 1...Self.maxDepth where r < Self.unscaledInner[depth] * scale { return depth }
        return nil
    }
}
