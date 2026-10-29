// Builds AppIconDebug.appiconset from AppIcon.appiconset: the same icon with an orange "DEBUG" band across the
// bottom of the tile, so the debug app is easy to tell apart in the Dock and Finder.
// Run from the repo root: swift Tools/make-debug-icon.swift
import AppKit

let source = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
let target = URL(fileURLWithPath: "App/Assets.xcassets/AppIconDebug.appiconset")
try? FileManager.default.removeItem(at: target)
try! FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
try! FileManager.default.copyItem(at: source.appendingPathComponent("Contents.json"),
                                  to: target.appendingPathComponent("Contents.json"))

for name in try! FileManager.default.contentsOfDirectory(atPath: source.path) where name.hasSuffix(".png") {
    let input = NSBitmapImageRep(data: try! Data(contentsOf: source.appendingPathComponent(name)))!
    let side = input.pixelsWide
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(side) / 1024
    input.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
    // The macOS icon tile: 824 × 824 centred, corner radius ≈ 185 (on a 1024 canvas).
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).addClip()
    let band = NSRect(x: tile.minX, y: tile.minY, width: tile.width, height: 190 * s)
    NSColor(srgbRed: 1.0, green: 0.55, blue: 0.1, alpha: 1).setFill()
    band.fill()
    if side >= 64 { // too small to read below that: the band alone marks it
        let font = NSFont.systemFont(ofSize: 120 * s, weight: .heavy)
        let text = NSAttributedString(string: "DEBUG", attributes: [.font: font, .foregroundColor: NSColor.white,
                                                                    .kern: 6 * s])
        let size = text.size()
        text.draw(at: NSPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2 + 4 * s))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent(name))
}
print("wrote \(target.path)")
