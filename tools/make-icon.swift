// Draws the app icon (Sorrel: a sorrel leaf on the soft gradient tile) and writes an .iconset folder.
// Usage: swift tools/make-icon.swift <out.iconset>
//        then: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.47, blue: 1, alpha: 1),
                        NSColor(srgbRed: 0.72, green: 0.52, blue: 1, alpha: 1),
                        NSColor(srgbRed: 0.42, green: 0.82, blue: 0.95, alpha: 1)])!.draw(in: shape, angle: 300)
    shape.addClip()

    // A sorrel leaf, leaning forward, drawn in the same soft white strokes the tile always had:
    // bright outline, a dimmer midrib and stem, faint veins.
    let w = rect.width
    let t = NSAffineTransform()
    t.translateX(by: rect.midX - w * 0.045, yBy: rect.midY - w * 0.035)
    t.rotate(byDegrees: -38)
    t.scale(by: w * 0.29)
    // Leaf coordinates run from the stem end (y = -1.5) to the tip (y = 1.05); shift so the whole thing is centred.
    func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { t.transform(NSPoint(x: x, y: y + 0.22)) }
    let stroke = w * 0.07

    // Outline: an arrow-shaped sorrel leaf, pointed tip, two lobes at the base angled back toward the stem.
    let leaf = NSBezierPath()
    leaf.move(to: p(0, 1.05))
    for side in [1.0, -1.0] as [CGFloat] {
        if side < 0 { leaf.move(to: p(0, 1.05)) }
        leaf.curve(to: p(side * 0.44, -0.98), controlPoint1: p(side * 0.42, 0.72), controlPoint2: p(side * 0.68, -0.3))
        leaf.curve(to: p(0, -0.7), controlPoint1: p(side * 0.3, -0.86), controlPoint2: p(side * 0.12, -0.72))
    }
    leaf.lineWidth = stroke
    leaf.lineJoinStyle = .round
    leaf.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.1).setFill()
    leaf.fill()
    NSColor.white.withAlphaComponent(0.95).setStroke()
    leaf.stroke()

    // Midrib running on through the notch into a short stem.
    let rib = NSBezierPath()
    rib.move(to: p(0, -1.5))
    rib.curve(to: p(0, 0.6), controlPoint1: p(-0.03, -0.7), controlPoint2: p(0.02, 0.1))
    rib.lineWidth = stroke * 0.85
    rib.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.6).setStroke()
    rib.stroke()

    // Two pairs of faint veins (left out at small sizes, where they would only blur).
    if px >= 64 {
        for (y, reach) in [(-0.3, 0.34), (0.18, 0.24)] as [(CGFloat, CGFloat)] {
            for side in [-1.0, 1.0] as [CGFloat] {
                let vein = NSBezierPath()
                vein.move(to: p(0, y))
                vein.curve(to: p(side * reach, y + 0.3), controlPoint1: p(side * reach * 0.4, y + 0.05),
                           controlPoint2: p(side * reach * 0.8, y + 0.17))
                vein.lineWidth = stroke * 0.6
                vein.lineCapStyle = .round
                NSColor.white.withAlphaComponent(0.32).setStroke()
                vein.stroke()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
