// Renders DiskGarden's app icon (original artwork) into App/Assets.xcassets/AppIcon.appiconset.
// Run: swift Tools/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")

func hsl(_ h: CGFloat, _ s: CGFloat, _ l: CGFloat, _ a: CGFloat = 1) -> CGColor {
    let c = (1 - abs(2 * l - 1)) * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (CGFloat, CGFloat, CGFloat) = hp < 1 ? (c, x, 0) : hp < 2 ? (x, c, 0) : hp < 3 ? (0, c, x) : hp < 4 ? (0, x, c) : hp < 5 ? (x, 0, c) : (c, 0, x)
    let m = l - c / 2
    return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [r + m, g + m, b + m, a])!
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    ctx.setShouldAntialias(true)

    // Body: macOS icon grid (824pt squircle-ish rounded rect inside 1024) with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 0.12, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [hsl(222, 0.12, 0.25), hsl(222, 0.14, 0.12)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft bloom behind the flower.
    let glow = CGGradient(colorsSpace: cs, colors: [hsl(150, 0.9, 0.6, 0.30), hsl(150, 0.9, 0.6, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])

    let center = CGPoint(x: 512, y: 512)
    let background = hsl(222, 0.12, 0.17)
    // One ring of sharp-cornered tiles; side edges stay parallel, so neighbours are separated by an even channel.
    // corner > 0 rounds them like the app's chart (shrink by the radius, then stroke that wide with round joins).
    let hole: CGFloat = 196, outer: CGFloat = 352, gap: CGFloat = 16, corner: CGFloat = 0
    func tile(_ a0: CGFloat, _ a1: CGFloat, _ color: CGColor) {
        let inset = gap / 2 + corner
        let r0 = hole + inset, r1 = outer - inset
        let p = CGMutablePath()
        p.addArc(center: center, radius: r1, startAngle: a0 + asin(inset / r1), endAngle: a1 - asin(inset / r1), clockwise: false)
        p.addArc(center: center, radius: r0, startAngle: a1 - asin(inset / r0), endAngle: a0 + asin(inset / r0), clockwise: true)
        p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(color); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(color); ctx.setLineWidth(2 * corner); ctx.setLineJoin(.round); ctx.strokePath()
    }
    // Five petals, big enough to read at 16 px.
    let petals: [(w: CGFloat, hue: CGFloat)] = [(1.5, 128), (1.1, 192), (1.0, 272), (0.8, 328), (1.2, 40)]
    let total = petals.map(\.w).reduce(0, +)
    var a = CGFloat.pi + 4 * .pi / 180 // like the chart: 9 o'clock, tilted a little (CG is y-up)
    for petal in petals {
        let span = 2 * .pi * petal.w / total
        tile(a, a + span, hsl(petal.hue, 1.0, 0.6))
        a += span
    }

    // Center disc, bigger, with a hairline like the app's.
    let disc: CGFloat = 176
    ctx.addEllipse(in: CGRect(x: center.x - disc, y: center.y - disc, width: disc * 2, height: disc * 2))
    ctx.setFillColor(background); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: center.x - disc + 3, y: center.y - disc + 3, width: disc * 2 - 6, height: disc * 2 - 6))
    ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 0.6)); ctx.setLineWidth(5); ctx.strokePath()

    // The seedling: exactly the app's SproutShape (App/Theme.swift, unit square, y down) in Theme.accent #1ED660.
    let green = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0x1E / 255.0, 0xD6 / 255.0, 0x60 / 255.0, 1])!
    let w: CGFloat = 196, h: CGFloat = 224 // the brand mark's 14 × 16 proportions
    let r = CGRect(x: center.x - w / 2, y: center.y - h / 2 + 4, width: w, height: h)
    func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w, y: r.maxY - y * h) } // flip y
    let sprout = CGMutablePath()
    sprout.move(to: q(0.47, 0.98))
    sprout.addQuadCurve(to: q(0.47, 0.50), control: q(0.42, 0.74))
    sprout.addLine(to: q(0.55, 0.50))
    sprout.addQuadCurve(to: q(0.55, 0.98), control: q(0.50, 0.74))
    sprout.closeSubpath()
    sprout.move(to: q(0.50, 0.54))
    sprout.addQuadCurve(to: q(0.04, 0.10), control: q(0.02, 0.52))
    sprout.addQuadCurve(to: q(0.50, 0.54), control: q(0.46, 0.08))
    sprout.closeSubpath()
    sprout.move(to: q(0.52, 0.46))
    sprout.addQuadCurve(to: q(0.96, 0.02), control: q(0.56, 0.02))
    sprout.addQuadCurve(to: q(0.52, 0.46), control: q(0.98, 0.44))
    sprout.closeSubpath()
    ctx.addPath(sprout); ctx.setFillColor(green); ctx.fillPath()
    ctx.restoreGState()

    // Hairline edge highlight.
    ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10)); ctx.setLineWidth(3); ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! render(size: px).write(to: out.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
try! #"{ "info" : { "version" : 1, "author" : "xcode" } }"#.data(using: .utf8)!
    .write(to: URL(fileURLWithPath: "App/Assets.xcassets/Contents.json"))
print("wrote \(images.count) icon images")
