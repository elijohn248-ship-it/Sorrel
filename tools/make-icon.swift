// Draws the app icon and writes an .iconset folder, plus an SVG master of the same mark.
// Usage: swift tools/make-icon.swift <out.iconset> [logo.svg]
//        then: iconutil -c icns <out.iconset> -o Resources/AppIcon.icns
//
// The mark (2026-11-17, Birch): one solid birch leaf in deep green, leaning forward: the triangular-oval
// blade with a long tip and a broad wedge base, a toothed edge whose teeth point toward the tip, and the
// midrib and birch's straight, parallel side veins cut through so the tile shows. It sits on the same quiet
// pastel tile as before (lavender -> sky -> mint). No outline, no shine. It should feel like Arc's icon did:
// light, calm, intentional. (Until 2026-11-17 the app was Sorrel, and the mark a smooth sorrel leaf.)
import AppKit

// ---- Design constants (unit space: the leaf runs from the stem end y = -1.12 to the tip y = 1.10) ----
let tileStops: [UInt32] = [0xEBDDF5, 0xCFE3F6, 0xB8EAD2]   // lavender, sky, mint
let tileAngle: CGFloat = 300                                // top-left -> bottom-right
let cornerRatio: CGFloat = 0.225                            // macOS squircle-ish radius
let ink: UInt32 = 0x1C4F3D                                  // leaf green
let tilt: CGFloat = -26                                     // degrees, clockwise = leaning right
let unit: CGFloat = 0.285                                   // leaf scale relative to tile width
let lift: CGFloat = 0.10                                    // nudges leaf+stem so the pair sits centred
let roundness: CGFloat = 0.07                               // outline stroke that softens every corner
let stemWidth: CGFloat = 0.15
let ribWidth: CGFloat = 0.075
let veinWidth: CGFloat = 0.05
let baseY: CGFloat = -0.66, ribTop: CGFloat = 0.62, stemEnd: CGFloat = -1.12

// The smooth right edge, tip to base, as cubic segments (to, cp1, cp2); teeth are cut into it below.
typealias Seg = (to: (CGFloat, CGFloat), c1: (CGFloat, CGFloat), c2: (CGFloat, CGFloat))
let tip: (CGFloat, CGFloat) = (0, 1.10)
let rightSide: [Seg] = [
    (to: (0.66, -0.30), c1: (0.07, 0.78), c2: (0.60, 0.20)),     // long tip, widening to the broad lower third
    (to: (0, baseY),    c1: (0.70, -0.54), c2: (0.30, -0.66)),   // round shoulder into the wide wedge base
]
let teeth = 8                                    // per side
let toothDepth: CGFloat = 0.068                  // how far a tooth stands out from the smooth edge
let toothFrom: CGFloat = 0.20, toothTo: CGFloat = 0.86   // along the edge (0 = tip, 1 = base): plain tip and base
let toothLean: CGFloat = 0.28                    // where in its step the point sits: small = points toward the tip
// Side veins: (where they leave the midrib, y; where they end, as a fraction of the way to the edge).
let veins: [(y: CGFloat, reach: CGFloat)] = [(-0.36, 0.74), (-0.04, 0.72), (0.28, 0.66)]
let veinRise: CGFloat = 0.62                     // a vein climbs this much per unit it runs outward

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// ---- Geometry, shared by the bitmap and the SVG ----

func bezier(_ a: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    let m = 1 - t
    return CGPoint(x: m * m * m * a.x + 3 * m * m * t * c1.x + 3 * m * t * t * c2.x + t * t * t * b.x,
                   y: m * m * m * a.y + 3 * m * m * t * c1.y + 3 * m * t * t * c2.y + t * t * t * b.y)
}

/// The smooth right edge, densely sampled from tip to base, with the length run so far at each sample.
let edge: [(p: CGPoint, run: CGFloat)] = {
    var pts: [CGPoint] = [CGPoint(x: tip.0, y: tip.1)]
    var from = pts[0]
    for seg in rightSide {
        let c1 = CGPoint(x: seg.c1.0, y: seg.c1.1), c2 = CGPoint(x: seg.c2.0, y: seg.c2.1), to = CGPoint(x: seg.to.0, y: seg.to.1)
        for i in 1...400 { pts.append(bezier(from, c1, c2, to, CGFloat(i) / 400)) }
        from = to
    }
    var out: [(p: CGPoint, run: CGFloat)] = [(pts[0], 0)]
    for i in 1..<pts.count { out.append((pts[i], out[i - 1].run + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))) }
    return out
}()

/// A point on the smooth edge `f` of the way from tip (0) to base (1), and the outward normal there.
func along(_ f: CGFloat) -> (p: CGPoint, out: CGPoint) {
    let target = f * edge.last!.run
    let i = max(1, min(edge.count - 1, edge.firstIndex { $0.run >= target } ?? edge.count - 1))
    let a = edge[i - 1].p, b = edge[i].p
    let len = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
    let tx = (b.x - a.x) / len, ty = (b.y - a.y) / len   // heading down the right side
    return (edge[i].p, CGPoint(x: -ty, y: tx))             // turned toward the outside
}

/// The right edge with its teeth, tip to base: notch, then a short steep rise to a point leaning toward the
/// tip, then a long gentle run down to the next notch.
let rightOutline: [CGPoint] = {
    var pts: [CGPoint] = []
    let n = 60
    for i in 1...n { pts.append(along(toothFrom * CGFloat(i) / CGFloat(n)).p) }   // plain tip
    let step = (toothTo - toothFrom) / CGFloat(teeth)
    for k in 0..<teeth {
        let start = toothFrom + CGFloat(k) * step
        let top = along(start + step * toothLean)
        pts.append(CGPoint(x: top.p.x + top.out.x * toothDepth, y: top.p.y + top.out.y * toothDepth))
        // The back of the tooth curves gently into the next notch.
        for j in 1...6 {
            let f = CGFloat(j) / 6
            let q = along(start + step * (toothLean + (1 - toothLean) * f))
            let d = toothDepth * (1 - f) * (1 - f)
            pts.append(CGPoint(x: q.p.x + q.out.x * d, y: q.p.y + q.out.y * d))
        }
    }
    for i in 1...n { pts.append(along(toothTo + (1 - toothTo) * CGFloat(i) / CGFloat(n)).p) }   // plain base
    return pts
}()

/// The whole leaf outline: tip, down the right edge, back up the mirrored left edge.
let outline: [CGPoint] = [CGPoint(x: tip.0, y: tip.1)] + rightOutline
    + rightOutline.dropLast().reversed().map { CGPoint(x: -$0.x, y: $0.y) }

/// Half the leaf's width at height y (the smooth edge), for sizing the veins.
func halfWidth(at y: CGFloat) -> CGFloat {
    edge.filter { abs($0.p.y - y) < 0.01 }.map(\.p.x).max() ?? 0
}

/// Each side vein as a line in unit space, both sides.
let veinLines: [(CGPoint, CGPoint)] = veins.flatMap { v -> [(CGPoint, CGPoint)] in
    // The vein ends `reach` of the way out, at the height it has climbed to by then.
    var x = halfWidth(at: v.y) * v.reach
    for _ in 0..<4 { x = halfWidth(at: v.y + x * veinRise) * v.reach }
    let a = CGPoint(x: 0, y: v.y), b = CGPoint(x: x, y: v.y + x * veinRise)
    return [(a, b), (a, CGPoint(x: -b.x, y: b.y))]
}

// ---- Bitmap ----

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
    func p(_ pt: CGPoint) -> NSPoint { t.transform(NSPoint(x: pt.x, y: pt.y + lift)) }

    let leaf = NSBezierPath()
    leaf.move(to: p(outline[0]))
    for pt in outline.dropFirst() { leaf.line(to: p(pt)) }
    leaf.close()

    // Leaf, stem and the cut-out midrib and veins are composed on one layer so the cuts go through to the tile.
    // The smallest sizes leave the veins out: at 16-32 px they would only muddy the leaf.
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    color(ink).setFill(); color(ink).setStroke()
    leaf.fill()
    leaf.lineWidth = u * roundness; leaf.lineJoinStyle = .round; leaf.stroke()
    let stem = NSBezierPath()
    stem.move(to: p(CGPoint(x: 0, y: baseY + 0.04))); stem.line(to: p(CGPoint(x: 0, y: stemEnd)))
    stem.lineWidth = u * stemWidth; stem.lineCapStyle = .round; stem.stroke()
    ctx.setBlendMode(.destinationOut)
    NSColor.black.setStroke()
    let rib = NSBezierPath()
    rib.move(to: p(CGPoint(x: 0, y: baseY + 0.02))); rib.line(to: p(CGPoint(x: 0, y: ribTop)))
    rib.lineWidth = u * ribWidth; rib.lineCapStyle = .round; rib.stroke()
    if px >= 64 {
        for (a, b) in veinLines {
            let v = NSBezierPath(); v.move(to: p(a)); v.line(to: p(b))
            v.lineWidth = u * veinWidth; v.lineCapStyle = .round; v.stroke()
        }
    }
    ctx.setBlendMode(.normal)
    ctx.endTransparencyLayer()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ---- SVG: the same mark (1024 canvas, same 10% inset), for the welcome page, a README or anything else ----

func svg() -> String {
    func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
    func f(_ v: CGFloat) -> String { String(format: "%.3f", v) }
    let size: CGFloat = 1024, inset = size * 0.1, w = size - inset * 2
    let r = w * cornerRatio, u = w * unit
    // NSGradient angle 300 = direction (cos 300, sin 300) in a y-up space = down-right on screen.
    // The gradient is defined in user space over the tile so the cuts can be stroked with it: a cut-out
    // without a mask, which not every SVG renderer handles the same way.
    let a = tileAngle * .pi / 180
    let dx = cos(a) / 2, dy = -sin(a) / 2
    let x1 = inset + w * (0.5 - dx), y1 = inset + w * (0.5 - dy), x2 = inset + w * (0.5 + dx), y2 = inset + w * (0.5 + dy)
    let d = "M " + outline.map { "\(f($0.x)) \(f($0.y + lift))" }.joined(separator: " L ") + " Z"
    let stops = tileStops.enumerated().map { i, c in
        "    <stop offset=\"\(f(CGFloat(i) / CGFloat(tileStops.count - 1)))\" stop-color=\"\(hex(c))\"/>"
    }.joined(separator: "\n")
    // y is flipped by scale(u, -u) so the unit coordinates above (y up) can be reused as they are.
    // The cuts are painted with the tile gradient, whose user-space coordinates are page coordinates, so they
    // sit outside the rotated group with their end points worked out by hand (same transform as `g`).
    let th = -tilt * .pi / 180
    func page(_ pt: CGPoint) -> NSPoint {
        let X = u * pt.x, Y = -u * (pt.y + lift)
        return NSPoint(x: size / 2 + X * cos(th) - Y * sin(th), y: size / 2 + X * sin(th) + Y * cos(th))
    }
    func cut(_ a: CGPoint, _ b: CGPoint, _ width: CGFloat) -> String {
        let p0 = page(a), p1 = page(b)
        return "  <line x1=\"\(f(p0.x))\" y1=\"\(f(p0.y))\" x2=\"\(f(p1.x))\" y2=\"\(f(p1.y))\" stroke=\"url(#tile)\" stroke-width=\"\(f(width * u))\" stroke-linecap=\"round\"/>"
    }
    let cuts = ([cut(CGPoint(x: 0, y: baseY + 0.02), CGPoint(x: 0, y: ribTop), ribWidth)]
        + veinLines.map { cut($0.0, $0.1, veinWidth) }).joined(separator: "\n")
    let g = "translate(\(f(size / 2)) \(f(size / 2))) rotate(\(f(-tilt))) scale(\(f(u)) \(f(-u)))"
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(size)) \(Int(size))" width="\(Int(size))" height="\(Int(size))">
      <!-- Birch: generated by tools/make-icon.swift; edit the constants there, not this file. -->
      <defs>
        <linearGradient id="tile" gradientUnits="userSpaceOnUse" x1="\(f(x1))" y1="\(f(y1))" x2="\(f(x2))" y2="\(f(y2))">
    \(stops)
        </linearGradient>
      </defs>
      <rect x="\(f(inset))" y="\(f(inset))" width="\(f(w))" height="\(f(w))" rx="\(f(r))" fill="url(#tile)"/>
      <g transform="\(g)" fill="\(hex(ink))" stroke="\(hex(ink))">
        <path d="\(d)" stroke-width="\(f(roundness))" stroke-linejoin="round"/>
        <line x1="0" y1="\(f(baseY + 0.04 + lift))" x2="0" y2="\(f(stemEnd + lift))" stroke-width="\(f(stemWidth))" stroke-linecap="round"/>
      </g>
    \(cuts)
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
