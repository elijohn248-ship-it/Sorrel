import AppKit
import UniformTypeIdentifiers
import WebKit

// The moment a download starts: the file's icon lifts off where you clicked, arcs across the window with a soft
// glow in the space's colours, and drops into the Library button (or, with the sidebar hidden, into the downloads
// capsule at the bottom left of the page). The progress row waits for it to land, then grows in under it.

extension Theme {
    /// The colours download progress is drawn in: the space's own colours, lifted on a dark sidebar and deepened
    /// on a light one so the bar always reads. A grey space falls back to the system accent.
    func progressColors(dark: Bool) -> [NSColor] {
        var cs = colors.compactMap { NSColor(hex: $0)?.usingColorSpace(.sRGB) }
        guard cs.contains(where: { $0.saturationComponent > 0.18 }) else {
            let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            return [accent, accent.blended(withFraction: 0.3, of: .white) ?? accent]
        }
        cs = cs.map { c in
            if c.luminance < 0.35 { return c.blended(withFraction: dark ? 0.5 : 0.12, of: .white) ?? c }
            if !dark, c.luminance > 0.78 { return c.blended(withFraction: 0.25, of: .black) ?? c }
            return c
        }
        if cs.count == 1 { cs.append(cs[0].blended(withFraction: 0.3, of: .white) ?? cs[0]) }
        return cs
    }
}

extension NSView {
    var isDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Notification.Name {
    /// The current space's colours changed: download bars repaint in them.
    static let sorrelDownloadTint = Notification.Name("sorrelDownloadTint")
}

enum DownloadFlight {
    /// Downloads whose icon is still in the air. The strip, the capsule and the Library button leave them out
    /// until they land, so the progress bar appears under the icon as it arrives.
    private(set) static var inFlight: Set<ObjectIdentifier> = []
    /// When each icon landed: a file that finished mid-flight still shows its full bar for a moment after.
    private(set) static var landedAt: [ObjectIdentifier: Date] = [:]
    private static var lastClick: (window: Int, point: NSPoint, time: Date)?
    private static var monitor: Any?
    /// Lift-off plus the flight.
    static let duration: TimeInterval = 0.86
    private static let lift: TimeInterval = 0.17
    /// Test hook: the layer of the latest flight while it is in the air.
    private(set) static weak var debugFlier: CALayer?

    /// Remembers where the last click was, so the icon can start from the link that was clicked.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            if let w = e.window { lastClick = (w.windowNumber, e.locationInWindow, Date()) }
            return e
        }
    }

    /// Where the person clicked in `window` in the last few seconds, in window coordinates.
    static func recentClick(in window: NSWindow) -> NSPoint? {
        guard let c = lastClick, c.window == window.windowNumber, Date().timeIntervalSince(c.time) < 4 else { return nil }
        return c.point
    }

    /// Flies `image` from `start` to `end` (both in `host`'s coordinates) and calls `landed` as it arrives.
    /// With Reduce Motion nothing moves: it lands at once and the row fades in.
    static func fly(_ record: DownloadRecord, image: NSImage, in host: NSView, from start: NSPoint, to end: NSPoint,
                    tint: [NSColor], landed: @escaping () -> Void) {
        let id = ObjectIdentifier(record)
        var done = false
        let land = {
            guard !done else { return }
            done = true
            inFlight.remove(id)
            landedAt[id] = Date()
            landed()
            NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
            // Forget landing times once no row could still be lingering on them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { landedAt[id] = nil }
        }
        guard !Motion.reduced, let root = host.layer else { land(); return }
        inFlight.insert(id)

        let size: CGFloat = 40
        let scale = host.window?.backingScaleFactor ?? 2
        let contents = image.layerContents(forContentsScale: scale)
        func picture(_ opacity: Float) -> CALayer {
            let l = CALayer()
            l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            l.position = start
            l.contents = contents
            l.contentsScale = scale
            l.contentsGravity = .resizeAspect
            l.zPosition = 1000
            l.opacity = 0
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = opacity * 0.25
            l.shadowRadius = 6
            l.shadowOffset = CGSize(width: 0, height: -3)
            return l
        }
        let flier = picture(1)
        // A soft halo in the space's colours travels with the icon.
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.colors = [tint[0].withAlphaComponent(0.55).cgColor, (tint.last ?? tint[0]).withAlphaComponent(0).cgColor]
        halo.startPoint = CGPoint(x: 0.5, y: 0.5)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.frame = flier.bounds.insetBy(dx: -18, dy: -18)
        halo.zPosition = -1
        flier.addSublayer(halo)
        // A short comet trail: fainter, smaller copies a beat behind.
        let ghosts = (1...3).map { _ in picture(0) }
        for g in ghosts.reversed() { root.addSublayer(g) }
        root.addSublayer(flier)
        debugFlier = flier

        // Up and over: the arc rises a little above the higher end, then swoops down into the target.
        let path = CGMutablePath()
        path.move(to: start)
        let dist = hypot(end.x - start.x, end.y - start.y)
        let control = CGPoint(x: start.x + (end.x - start.x) * 0.3, y: max(start.y, end.y) + min(170, dist * 0.32))
        path.addQuadCurve(to: end, control: control)

        func flight(trailing i: Int) -> CAAnimationGroup {
            let delay = Double(i) * 0.04
            let peak: Float = i == 0 ? 1 : [0.42, 0.24, 0.12][i - 1]
            let shrink: CGFloat = i == 0 ? 1 : 1 - CGFloat(i) * 0.1

            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [0.35, 1.14, 1.0, 1.05, 0.28].map { $0 * shrink }
            grow.keyTimes = [0, 0.12, 0.21, 0.45, 1]
            grow.timingFunctions = [Motion.settle, Motion.glide, Motion.glide, CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.7)]
            grow.duration = duration

            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.beginTime = lift + delay
            move.duration = duration - lift
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
            move.fillMode = .backwards

            let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            tilt.values = [0, 0.1, -0.3]
            tilt.keyTimes = [0, 0.35, 1]
            tilt.beginTime = lift + delay
            tilt.duration = duration - lift
            tilt.timingFunction = Motion.glide

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            if i == 0 {
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.06, 0.9, 1]
            } else {
                // Ghosts only show once the icon is moving.
                fade.values = [0, 0, peak, peak * 0.6, 0]
                fade.keyTimes = [0, 0.22, 0.32, 0.85, 1]
            }
            fade.duration = duration + delay

            let g = CAAnimationGroup()
            g.animations = [grow, move, tilt, fade]
            g.duration = duration + delay
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            return g
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            ([flier] + ghosts).forEach { $0.removeFromSuperlayer() }
        }
        flier.add(flight(trailing: 0), forKey: "flight")
        for (i, g) in ghosts.enumerated() { g.add(flight(trailing: i + 1), forKey: "flight") }
        CATransaction.commit()
        // The landing is timed separately so the catch plays as the icon arrives, not after its trail.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration - 0.06) { land() }
    }
}

// MARK: - Starting a flight

extension MainWindowController {
    /// A download began. If it came from a page in this window, its icon flies to the Library button (or to the
    /// capsule over the page when the sidebar is hidden) and true comes back; otherwise the caller toasts instead.
    func downloadStarted(_ record: DownloadRecord, in webView: WKWebView?) -> Bool {
        guard let window, let webView, webView.window === window, !webView.isHiddenOrHasHiddenAncestor else { return false }
        root.layoutSubtreeIfNeeded()
        let page = webView.convert(webView.bounds, to: root)
        var start = NSPoint(x: page.midX, y: page.midY)
        if let click = DownloadFlight.recentClick(in: window) {
            let p = root.convert(click, from: nil)
            if page.contains(p) { start = p }
        }
        let toSidebar = mode != .hidden
        let end: NSPoint
        if toSidebar {
            let anchor = sidebar.downloadsAnchor
            end = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: root)
        } else {
            end = downloadsCapsule.landingPoint(in: root)
        }
        let type = UTType(filenameExtension: record.file.pathExtension) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        let tint = store.currentSpace.theme.progressColors(dark: sidebar.isDarkAppearance)
        DownloadFlight.fly(record, image: image, in: root, from: start, to: end, tint: tint) { [weak self] in
            guard let self else { return }
            if toSidebar { self.sidebar.downloadsAnchor.catchLanding(tint: tint) }
        }
        return true
    }

    /// The space's colours changed: the capsule and every download bar follow.
    func downloadsThemeChanged() {
        downloadsCapsule.apply(store.currentSpace.theme)
        NotificationCenter.default.post(name: .sorrelDownloadTint, object: nil)
    }
}

// MARK: - Capsule (sidebar hidden)

/// With the sidebar hidden, downloads in progress show in a small card at the bottom left of the page, in the
/// space's colours. It is the same strip the sidebar uses, so rows behave identically.
final class DownloadsCapsule: NSView {
    private let background = ThemeBackgroundView()
    let strip = DownloadsStrip()
    private var shown = false
    private weak var card: NSView?
    static let width: CGFloat = 272
    private static let inset: CGFloat = 12

    /// Set by the window as the sidebar hides and shows; the capsule only appears while it is hidden.
    var sidebarHidden = false { didSet { if sidebarHidden != oldValue { updateVisibility() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        background.cornerRadius = 12
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        for v in [background, strip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            strip.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isHidden = true
        alphaValue = 0
        strip.onRowsChanged = { [weak self] _ in self?.updateVisibility() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the capsule over `card` (the page), at its bottom left, under the sidebar and toasts.
    func attach(to root: NSView, over card: NSView) {
        self.card = card
        root.addSubview(self, positioned: .above, relativeTo: card)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.inset),
            bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.inset),
        ])
    }

    func apply(_ theme: Theme) {
        background.apply(theme, animated: shown)
        appearance = NSAppearance(named: theme.isDark(systemIsDark: systemIsDark()) ? .darkAqua : .aqua)
    }

    /// Where an incoming icon should land: on the first row's thumbnail, where the capsule is about to open.
    func landingPoint(in root: NSView) -> NSPoint {
        guard let card else { return NSPoint(x: 40, y: 40) }
        let f = card.convert(card.bounds, to: root)
        return NSPoint(x: f.minX + Self.inset + 4 + 8 + 15, y: f.minY + Self.inset + 4 + DownloadRow.height / 2)
    }

    private func updateVisibility() {
        let want = sidebarHidden && !strip.rows.isEmpty
        guard want != shown else { return }
        shown = want
        if want {
            superview?.layoutSubtreeIfNeeded()
            fade(in: true, duration: 0.18)
            layer?.popIn(scale: 0.86, rise: -10, fade: false, duration: 0.4)
        } else {
            layer?.popOut(scale: 0.94, duration: 0.2)
            fade(in: false, duration: 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, !self.shown else { return }
                self.layer?.clearPopOut()
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Test hook.
    var debugLine: String { "shown=\(shown) visible=\(!isHidden) rows=\(strip.rows.map { $0.debugDescription_ })" }
}
