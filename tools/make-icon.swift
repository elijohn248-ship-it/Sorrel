// Draws the app icon and writes an .iconset folder, plus an SVG master of the same mark.
// Usage: swift tools/make-icon.swift <out.iconset> [logo.svg]
//        then: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
//
// The mark (2026-11-14): one solid sorrel leaf in deep green, leaning forward, with a single
// midrib cut through it so the tile shows, on a quiet pastel tile that runs lavender -> sky -> mint.
// Nothing else: no veins, no outline, no shine. It should feel like Arc's icon did: light, calm, intentional.
import AppKit

// ---- Design constants (unit space: the leaf runs from the stem end y = -1.12 to the tip y = 1.10) ----
let tileStops: [UInt32] = [0xEBDDF5, 0xCFE3F6, 0xB8EAD2]   // lavender, sky, mint
let tileAngle: CGFloat = 300                                // top-left -> bottom-right
let cornerRatio: CGFloat = 0.225                            // macOS squircle-ish radius
let ink: UInt32 = 0x1C4F3D                                  // leaf green
let tilt: CGFloat = -26                                     // degrees, clockwise = leaning right
let unit: CGFloat = 0.285                                   // leaf scale relative to tile width
let lift: CGFloat = 0.08                                    // nudges leaf+stem so the pair sits centred
let roundness: CGFloat = 0.09                               // outline stroke that softens every corner
let stemWidth: CGFloat = 0.15
let ribWidth: CGFloat = 0.075
let notchY: CGFloat = -0.54, ribTop: CGFloat = 0.40, stemEnd: CGFloat = -1.12

// Leaf outline as cubic segments, right side first then mirrored. Each: (to, cp1, cp2).
typealias Seg = (to: (CGFloat, CGFloat), c1: (CGFloat, CGFloat), c2: (CGFloat, CGFloat))
let tip: (CGFloat, CGFloat) = (0, 1.10)
let rightSide: [Seg] = [
    (to: (0.43, -0.22), c1: (0.40, 0.66), c2: (0.50, 0.14)),    // tip down the shoulder to a gentle waist
    (to: (0.44, -0.84), c1: (0.39, -0.44), c2: (0.44, -0.68)),  // waist out to the lobe
    (to: (0, notchY),   c1: (0.32, -0.78), c2: (0.14, -0.60)),  // lobe back in to the notch above the stem
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * cornerRatio, yRadius: rect.width * cornerRatio)
    NSGradient(colors: tileStops.map(color))!.draw(in: tile, angle: tileAngle)
    tile.addClip()

    let u = rect.width * unit
    let t = NSAffineTransform()
    t.translateX(by: rect.midX, yBy: rect.midY)
    t.rotate(byDegrees: tilt)
    t.scale(by: u)
    func p(_ pt: (CGFloat, CGFloat)) -> NSPoint { t.transform(NSPoint(x: pt.0, y: pt.1 + lift)) }

    let leaf = NSBezierPath()
    for side in [1.0, -1.0] as [CGFloat] {
        leaf.move(to: p(tip))
        for seg in rightSide {
            leaf.curve(to: p((side * seg.to.0, seg.to.1)), controlPoint1: p((side * seg.c1.0, seg.c1.1)),
                       controlPoint2: p((side * seg.c2.0, seg.c2.1)))
        }
    }
    leaf.close()

    // Leaf, stem and the cut-out midrib are composed on one layer so the cut goes through to the tile.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    color(ink).setFill(); color(ink).setStroke()
    leaf.fill()
    leaf.lineWidth = u * roundness; leaf.lineJoinStyle = .round; leaf.stroke()
    let stem = NSBezierPath()
    stem.move(to: p((0, notchY + 0.04))); stem.line(to: p((0, stemEnd)))
    stem.lineWidth = u * stemWidth; stem.lineCapStyle = .round; stem.stroke()
    ctx.setBlendMode(.destinationOut)
    let rib = NSBezierPath()
    rib.move(to: p((0, notchY))); rib.line(to: p((0, ribTop)))
    rib.lineWidth = u * ribWidth; rib.lineCapStyle = .round
    NSColor.black.setStroke(); rib.stroke()
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The same mark as an SVG (1024 canvas, same 10% inset), for the welcome page, a README or anything else.
func svg() -> String {
    func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
    func f(_ v: CGFloat) -> String { String(format: "%.3f", v) }
    let size: CGFloat = 1024, inset = size * 0.1, w = size - inset * 2
    let r = w * cornerRatio, u = w * unit
    // NSGradient angle 300 = direction (cos 300, sin 300) in a y-up space = down-right on screen.
    // The gradient is defined in user space over the tile so the rib can be stroked with it: a cut-out
    // without a mask, which not every SVG renderer handles the same way.
    let a = tileAngle * .pi / 180
    let dx = cos(a) / 2, dy = -sin(a) / 2
    let x1 = inset + w * (0.5 - dx), y1 = inset + w * (0.5 - dy), x2 = inset + w * (0.5 + dx), y2 = inset + w * (0.5 + dy)
    var d = ""
    for side in [1.0, -1.0] as [CGFloat] {
        d += "M \(f(tip.0)) \(f(tip.1 + lift)) "
        for seg in rightSide {
            d += "C \(f(side * seg.c1.0)) \(f(seg.c1.1 + lift)) \(f(side * seg.c2.0)) \(f(seg.c2.1 + lift)) \(f(side * seg.to.0)) \(f(seg.to.1 + lift)) "
        }
    }
    d += "Z"
    let stops = tileStops.enumerated().map { i, c in
        "    <stop offset=\"\(f(CGFloat(i) / CGFloat(tileStops.count - 1)))\" stop-color=\"\(hex(c))\"/>"
    }.joined(separator: "\n")
    // y is flipped by scale(u, -u) so the unit coordinates above (y up) can be reused as they are.
    // The rib is painted with the tile gradient, whose user-space coordinates are page coordinates, so it
    // sits outside the rotated group with its end points worked out by hand (same transform as `g`).
    let th = -tilt * .pi / 180
    func page(_ y: CGFloat) -> NSPoint { NSPoint(x: size / 2 + u * (y + lift) * sin(th), y: size / 2 - u * (y + lift) * cos(th)) }
    let rib0 = page(notchY), rib1 = page(ribTop)
    let g = "translate(\(f(size / 2)) \(f(size / 2))) rotate(\(f(-tilt))) scale(\(f(u)) \(f(-u)))"
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(size)) \(Int(size))" width="\(Int(size))" height="\(Int(size))">
      <!-- Sorrel: generated by tools/make-icon.swift; edit the constants there, not this file. -->
      <defs>
        <linearGradient id="tile" gradientUnits="userSpaceOnUse" x1="\(f(x1))" y1="\(f(y1))" x2="\(f(x2))" y2="\(f(y2))">
    \(stops)
        </linearGradient>
      </defs>
      <rect x="\(f(inset))" y="\(f(inset))" width="\(f(w))" height="\(f(w))" rx="\(f(r))" fill="url(#tile)"/>
      <g transform="\(g)" fill="\(hex(ink))" stroke="\(hex(ink))">
        <path d="\(d)" stroke-width="\(f(roundness))" stroke-linejoin="round"/>
        <line x1="0" y1="\(f(notchY + 0.04 + lift))" x2="0" y2="\(f(stemEnd + lift))" stroke-width="\(f(stemWidth))" stroke-linecap="round"/>
      </g>
      <line x1="\(f(rib0.x))" y1="\(f(rib0.y))" x2="\(f(rib1.x))" y2="\(f(rib1.y))" stroke="url(#tile)" stroke-width="\(f(ribWidth * u))" stroke-linecap="round"/>
    </svg>

    """
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try svg().write(to: URL(fileURLWithPath: CommandLine.arguments[2]), atomically: true, encoding: .utf8)
}
