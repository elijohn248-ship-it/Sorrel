import AppKit

// Arc's look for a space's colours: soft by default, optionally brighter, with smooth gradients and film grain.
//
// - Colours are worked on in OKLab (a perceptual colour space), so mixing a colour toward white or toward the dark
//   base keeps its hue and lightness even, and the middle of a gradient never turns grey or muddy.
// - Each chosen colour's chroma (how vivid it is) is eased through a soft knee: vivid picks become pastel, gentle
//   picks stay as they are. Optional brightness restores the original colours after this softening.
// - Gradients are drawn with many stops interpolated in OKLab on a gentle S-curve; one colour gets a faint tonal
//   lift so it still has depth.
// - Grain is a fixed noise tile (light and dark specks, so it reads on both) laid over the gradient. Each space has
//   its own amount (Theme.grain), like Arc's noise slider.

/// A colour in OKLab. L is lightness 0…1; a and b are the green–red and blue–yellow axes.
struct OKLab: Equatable {
    var L: Double, a: Double, b: Double

    init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        func lin(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.redComponent), g = lin(c.greenComponent), bl = lin(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var chroma: Double { (a * a + b * b).squareRoot() }

    func mix(_ o: OKLab, _ t: Double) -> OKLab {
        OKLab(L: L + (o.L - L) * t, a: a + (o.a - a) * t, b: b + (o.b - b) * t)
    }

    private func linearRGB() -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Back to sRGB. Out-of-gamut colours lose chroma (not hue) until they fit.
    var color: NSColor {
        var lab = self
        lab.L = max(0, min(1, lab.L))
        var rgb = lab.linearRGB()
        var tries = 0
        while tries < 24, [rgb.0, rgb.1, rgb.2].contains(where: { $0 < -0.0005 || $0 > 1.0005 }) {
            lab.a *= 0.92; lab.b *= 0.92
            rgb = lab.linearRGB()
            tries += 1
        }
        func enc(_ x: Double) -> CGFloat {
            let v = max(0, min(1, x))
            return CGFloat(v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        return NSColor(srgbRed: enc(rgb.0), green: enc(rgb.1), blue: enc(rgb.2), alpha: 1)
    }
}

extension Theme {
    /// Grain for spaces saved before grain existed, and for new spaces.
    static let defaultGrain = 0.35
    /// How many stops a drawn gradient has. Every theme uses the same count, so two can be blended stop by stop.
    static let gradientStopCount = 16

    /// 0 = smooth, 1 = Arc's heaviest grain.
    var grainAmount: Double { max(0, min(1, grain ?? Theme.defaultGrain)) }

    /// Existing spaces stay soft; moving toward 1 restores the chosen colours' vividness and lightness.
    var brightnessAmount: Double { max(0, min(1, brightness ?? 0)) }

    /// The neutral a theme fades into at low strength.
    static func softBase(dark: Bool) -> OKLab {
        dark ? OKLab(NSColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)) : OKLab(L: 1, a: 0, b: 0)
    }

    /// One chosen colour as a space draws it: soften by default, restore the original by optional brightness,
    /// then mix toward the light or dark base by the strength.
    static func soften(_ color: NSColor, intensity: Double, dark: Bool, brightness: Double = 0) -> OKLab {
        var lab = OKLab(color)
        let original = lab
        let c = lab.chroma
        if c > 0.0001 {
            let cap = 0.15
            let soft = cap * tanh(c / cap) * 0.9
            lab.a *= soft / c
            lab.b *= soft / c
        }
        // In dark mode a colour sinks to a deep, rich tone (Arc turns its coral into a dark rust), instead of a
        // bright midtone that reads as muddy next to dark pages. Already-deep colours are left as they are.
        if dark { lab.L = min(lab.L, 0.3 + 0.2 * lab.L) }
        lab = lab.mix(original, max(0, min(1, brightness)))
        return softBase(dark: dark).mix(lab, max(0, min(1, intensity)))
    }

    func softLabs(dark: Bool) -> [OKLab] {
        let labs = colors.compactMap { NSColor(hex: $0) }.map {
            Theme.soften($0, intensity: intensity, dark: dark, brightness: brightnessAmount)
        }
        return labs.isEmpty ? [Theme.softBase(dark: dark)] : labs
    }

    /// The gradient as drawn: `gradientStopCount` colours, start to end.
    func gradientStops(dark: Bool) -> [NSColor] {
        var labs = softLabs(dark: dark)
        if labs.count == 1 {
            // One colour still gets a faint tonal lift from start to end, like light falling across it.
            var hi = labs[0], lo = labs[0]
            hi.L = min(1, hi.L + 0.025)
            lo.L = max(0, lo.L - 0.025)
            labs = [hi, lo]
        }
        let n = Theme.gradientStopCount
        let segments = Double(labs.count - 1)
        return (0..<n).map { k in
            let u = Double(k) / Double(n - 1) * segments
            let i = min(Int(u), labs.count - 2)
            let f = u - Double(i)
            // Half linear, half smoothstep: soft ends without plateaus.
            let eased = 0.5 * f + 0.5 * (f * f * (3 - 2 * f))
            return labs[i].mix(labs[i + 1], eased).color
        }
    }

    /// Two themes' gradients `f` of the way from `a` to `b`, mixed stop by stop in OKLab.
    static func blendedStops(_ a: Theme, _ b: Theme, _ f: CGFloat, dark: Bool) -> [NSColor] {
        let sa = a.gradientStops(dark: dark).map(OKLab.init), sb = b.gradientStops(dark: dark).map(OKLab.init)
        return zip(sa, sb).map { $0.mix($1, Double(f)).color }
    }
}

/// The grain laid over a space's colours: one 128 pt tile of light and dark specks, tiled as a pattern colour.
enum Grain {
    /// Layer opacity at grain 1.0.
    static let strength: Float = 0.32

    static func opacity(_ amount: Double) -> Float { Float(max(0, min(1, amount))) * strength }

    static let pattern: CGColor = NSColor(patternImage: image).cgColor

    /// The 128 pt noise tile itself.
    static let image: NSImage = {
        let px = 256  // drawn into 128 pt, so one speck per pixel on a Retina screen
        var data = [UInt8](repeating: 0, count: px * px * 4)
        var seed: UInt64 = 0x5EED_50FF_E1
        func rand() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for i in 0..<(px * px) {
            // Roughly Gaussian (sum of four uniforms), so most specks are faint and a few stand out.
            let n = (rand() + rand() + rand() + rand()) / 4 - 0.5
            let v = max(-1, min(1, n * 3.2))
            let alpha = UInt8(abs(v) * 255)
            let shade: UInt8 = v > 0 ? alpha : 0  // premultiplied: white specks or black specks
            data[i * 4] = shade; data[i * 4 + 1] = shade; data[i * 4 + 2] = shade; data[i * 4 + 3] = alpha
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(data) as CFData)!
        let image = CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
                            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSImage(cgImage: image, size: NSSize(width: 128, height: 128))
    }()
}

/// Arc-style colour wheel: hue around the circle, vividness out from the centre, drawn in the soft palette spaces
/// use. Each of the space's colours is a dot. Dragging the first dot turns the others with it (they keep their
/// spacing around the wheel, like Arc's harmony); the others move on their own. A dot keeps its colour's brightness,
/// so deep colours stay deep.
final class ColorWheel: NSView {
    var colors: [NSColor] = [] { didSet { needsDisplay = true } }
    var brightness: Double = 0 {
        didSet { if brightness != oldValue { wheelImage = nil; needsDisplay = true } }
    }
    /// While dragging (live) and on let-go (final = true).
    var onChange: (([NSColor], _ final: Bool) -> Void)?
    private var dragging: Int?
    private var lastHue: CGFloat = 0
    private var grabOffset = CGPoint.zero
    private var wheelImage: NSImage?
    private var imageScale: CGFloat = 0

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 - 6 }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func hsb(_ c: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let c = c.usingColorSpace(.sRGB) ?? c
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    private func point(for c: NSColor) -> CGPoint {
        let (h, s, _) = hsb(c)
        let ang = h * 2 * .pi
        return CGPoint(x: center.x + cos(ang) * s * radius, y: center.y + sin(ang) * s * radius)
    }

    private func hueSat(at p: CGPoint) -> (CGFloat, CGFloat) {
        let dx = p.x - center.x, dy = p.y - center.y
        var h = atan2(dy, dx) / (2 * .pi)
        if h < 0 { h += 1 }
        return (h, min(1, (dx * dx + dy * dy).squareRoot() / radius))
    }

    private func makeWheel(scale: CGFloat) -> NSImage {
        let px = Int((radius * 2 * scale).rounded())
        var data = [UInt8](repeating: 0, count: px * px * 4)
        let r = Double(px) / 2
        for j in 0..<px {
            for i in 0..<px {
                let dx = Double(i) + 0.5 - r, dy = r - (Double(j) + 0.5)  // row 0 is the top
                let d = (dx * dx + dy * dy).squareRoot()
                guard d <= r + 1 else { continue }
                var h = atan2(dy, dx) / (2 * .pi)
                if h < 0 { h += 1 }
                let raw = NSColor(hue: CGFloat(h), saturation: CGFloat(min(1, d / r)), brightness: 1, alpha: 1)
                let c = Theme.soften(raw, intensity: 1, dark: false, brightness: brightness).color
                let edge = max(0, min(1, r + 0.5 - d))  // antialiased rim
                let k = (i + j * px) * 4
                data[k] = UInt8(c.redComponent * 255 * edge)
                data[k + 1] = UInt8(c.greenComponent * 255 * edge)
                data[k + 2] = UInt8(c.blueComponent * 255 * edge)
                data[k + 3] = UInt8(255 * edge)
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        let cg = CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return NSImage(cgImage: cg, size: NSSize(width: radius * 2, height: radius * 2))
    }

    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        if wheelImage == nil || imageScale != scale { wheelImage = makeWheel(scale: scale); imageScale = scale }
        let disc = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        wheelImage?.draw(in: disc)
        // The same grain spaces get, so the wheel previews the finish.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: disc).addClip()
        NSGraphicsContext.current?.cgContext.setAlpha(CGFloat(Grain.opacity(Theme.defaultGrain)))
        NSColor(patternImage: Grain.image).setFill()
        disc.fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        let rim = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5)); rim.lineWidth = 1; rim.stroke()

        // Lines from the first dot to the others, as Arc draws its harmony.
        if colors.count > 1 {
            let path = NSBezierPath()
            let p0 = point(for: colors[0])
            for c in colors.dropFirst() { path.move(to: p0); path.line(to: point(for: c)) }
            NSColor.white.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        for (i, c) in colors.enumerated().reversed() {
            let p = point(for: c)
            let size: CGFloat = i == 0 ? 20 : 15
            let r = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.soften(c, intensity: 1, dark: false, brightness: brightness).color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 2.5, dy: 2.5)).fill()
        }
    }

    func debugPoint(_ i: Int) -> CGPoint { point(for: colors[i]) }

    private func moved(to p: CGPoint, final: Bool) {
        guard let i = dragging, i < colors.count else { return }
        let (h, s) = hueSat(at: CGPoint(x: p.x + grabOffset.x, y: p.y + grabOffset.y))
        var out = colors
        let keep = hsb(colors[i]).b
        out[i] = NSColor(hue: h, saturation: s, brightness: max(keep, 0.05), alpha: 1)
        if i == 0 {
            let delta = h - lastHue
            for k in 1..<out.count {
                let (oh, os, ob) = hsb(colors[k])
                var nh = oh + delta
                nh -= floor(nh)
                out[k] = NSColor(hue: nh, saturation: os, brightness: ob, alpha: 1)
            }
        }
        lastHue = h
        colors = out
        onChange?(out, final)
    }

    override func mouseDown(with event: NSEvent) {
        guard !colors.isEmpty else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Grab the nearest dot under the cursor; a click elsewhere moves the first one there.
        let hits = colors.indices.map { ($0, hypot(point(for: colors[$0]).x - p.x, point(for: colors[$0]).y - p.y)) }
        let near = hits.filter { $0.1 <= 12 }.min { $0.1 < $1.1 }
        dragging = near?.0 ?? 0
        lastHue = hsb(colors[dragging!]).h
        let dot = point(for: colors[dragging!])
        grabOffset = near == nil ? .zero : CGPoint(x: dot.x - p.x, y: dot.y - p.y)
        if near == nil { moved(to: p, final: false) }
    }

    override func mouseDragged(with event: NSEvent) {
        moved(to: convert(event.locationInWindow, from: nil), final: false)
    }

    override func mouseUp(with event: NSEvent) {
        moved(to: convert(event.locationInWindow, from: nil), final: true)
        dragging = nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        wheelImage = nil
        needsDisplay = true
    }
}
