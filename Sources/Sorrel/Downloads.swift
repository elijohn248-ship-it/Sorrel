import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Arc-style downloads. The Library button at the bottom left of the sidebar fills a ring while files download,
// shows recent downloads when hovered, and opens the Library (Library.swift) when clicked. Downloads in progress
// also sit in a strip at the bottom of the sidebar with their size, time left and a cancel button.

// MARK: - Space bar button

/// The Library button: books when idle; while downloading, an arrow that drops in, inside a ring that fills.
/// Hovering it asks for the recent-downloads preview.
final class DownloadsButton: NSView {
    private(set) var button: IconButton!
    /// Called with true after the cursor has rested on the button, and false when it leaves.
    var onHover: ((Bool) -> Void)?
    private var hoverWork: DispatchWorkItem?
    private static let idleSymbol = "books.vertical"
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var runningIDs: Set<ObjectIdentifier> = []
    private var spinning = false

    init(handler: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        button = IconButton(symbol: Self.idleSymbol, size: 12, tooltip: "Library", handler: handler)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for l in [track, ring] {
            l.fillColor = nil
            l.lineWidth = 1.6
            l.lineCap = .round
            l.opacity = 0
            layer?.addSublayer(l)
        }
        ring.strokeEnd = 0
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Motion.layer(0) {
            for l in [track, ring] {
                l.frame = bounds
                // Starts at twelve o'clock and runs clockwise (this view is not flipped, so y points up).
                let path = CGMutablePath()
                path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: 8,
                            startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
                l.path = path
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = NSColor.controlAccentColor.cgColor
            track.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onHover?(true) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        hoverWork = nil
        onHover?(false)
    }

    /// A click opens the Library, so a pending preview shouldn't pop up after it.
    func cancelHover() { hoverWork?.cancel(); hoverWork = nil }

    func update(_ list: [DownloadRecord]) {
        // A download whose icon is still flying in counts once it lands, so the ring starts as it arrives.
        let running = list.filter { $0.state == .running && !DownloadFlight.inFlight.contains(ObjectIdentifier($0)) }
        let ids = Set(running.map(ObjectIdentifier.init))
        let started = !ids.subtracting(runningIDs).isEmpty
        let finished = !runningIDs.subtracting(ids).isEmpty && list.contains { runningIDs.contains(ObjectIdentifier($0)) && $0.state == .done }
        runningIDs = ids

        // A known size for every running file gives a real fraction; otherwise the ring just turns.
        let sized = running.filter { $0.total > 0 }
        let fraction: Double? = running.isEmpty || sized.count < running.count ? nil
            : Double(sized.reduce(0) { $0 + $1.received }) / Double(max(1, sized.reduce(0) { $0 + $1.total }))

        button.image = symbol(running.isEmpty ? Self.idleSymbol : "arrow.down", size: running.isEmpty ? 12 : 9,
                              weight: running.isEmpty ? .medium : .bold)
        button.contentTintColor = running.isEmpty ? .secondaryLabelColor : .controlAccentColor
        Motion.layer(0.25) {
            track.opacity = running.isEmpty ? 0 : 1
            ring.opacity = running.isEmpty ? 0 : 1
            ring.strokeEnd = running.isEmpty ? 1 : CGFloat(fraction ?? 0.25)
        }
        setSpinning(!running.isEmpty && fraction == nil)

        if started { button.layer?.popIn(scale: 1, rise: -7, duration: 0.4) }        // the arrow drops in
        else if finished && running.isEmpty { layer?.popIn(scale: 1.3, fade: false, duration: 0.35) }

        if running.count == 1, let r = running.first {
            button.toolTip = "Downloading \(r.file.lastPathComponent)" + (fraction.map { " (\(Int($0 * 100))%)" } ?? "")
        } else if running.count > 1 {
            button.toolTip = "Downloading \(running.count) files" + (fraction.map { " (\(Int($0 * 100))%)" } ?? "")
        } else {
            button.toolTip = "Library"
        }
    }

    /// A flying download icon just dropped in: the button gives under it and a ring of the space's colour
    /// spreads out from it.
    func catchLanding(tint: [NSColor]) {
        guard let host = layer, !Motion.reduced else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [1, 1.3, 0.9, 1.04, 1].map { s -> CATransform3D in
            var t = CATransform3DMakeTranslation(c.x, c.y, 0)
            t = CATransform3DScale(t, s, s, 1)
            return CATransform3DTranslate(t, -c.x, -c.y, 0)
        }
        squash.keyTimes = [0, 0.25, 0.55, 0.8, 1]
        squash.duration = 0.5
        squash.timingFunction = Motion.glide
        host.add(squash, forKey: "catch")

        for (i, color) in [tint.first, tint.last].compactMap({ $0 }).enumerated() {
            let ripple = CAShapeLayer()
            ripple.frame = bounds
            ripple.path = CGPath(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18), transform: nil)
            ripple.fillColor = nil
            ripple.strokeColor = color.cgColor
            ripple.lineWidth = i == 0 ? 2 : 1.2
            ripple.opacity = 0
            host.addSublayer(ripple)
            var big = CATransform3DMakeTranslation(c.x, c.y, 0)
            big = CATransform3DScale(big, 2.3, 2.3, 1)
            big = CATransform3DTranslate(big, -c.x, -c.y, 0)
            var small = CATransform3DMakeTranslation(c.x, c.y, 0)
            small = CATransform3DScale(small, 0.7, 0.7, 1)
            small = CATransform3DTranslate(small, -c.x, -c.y, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = small
            grow.toValue = big
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.85
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [grow, fade]
            g.duration = 0.6
            g.beginTime = CACurrentMediaTime() + Double(i) * 0.09
            g.timingFunction = Motion.settle
            g.fillMode = .backwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
            ripple.add(g, forKey: "ripple")
            CATransaction.commit()
        }
    }

    private func setSpinning(_ on: Bool) {
        guard on != spinning else { return }
        spinning = on
        if on, !Motion.reduced {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1.1
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        } else {
            ring.removeAnimation(forKey: "spin")
        }
    }

    /// Test hook: what the ring is showing.
    var debugRing: String {
        "visible=\(!isHidden) ring=\(ring.opacity > 0) fill=\(String(format: "%.2f", ring.strokeEnd)) spinning=\(spinning) tooltip=\(button.toolTip ?? "")"
    }
}

// MARK: - Hover preview

/// What hovering the Library button shows: the most recent downloads, newest first.
final class DownloadsPreview: NSViewController {
    static let width: CGFloat = 280
    static let limit = 5
    var onClose: (() -> Void)?
    private let stack = NSStackView()
    private(set) var rows: [DownloadRow] = []

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 100))
        let title = NSTextField(labelWithString: "Recent Downloads")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        for c in [title, stack] as [NSView] {
            c.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(c)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            stack.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
        ])
        view = v
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .sorrelDownloads, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func reload() {
        let list = Array(Engine.shared.downloads.prefix(Self.limit))
        if list.count == rows.count, zip(list, rows).allSatisfy({ $0 === $1.record }) {
            rows.forEach { $0.refresh() }
            return
        }
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = list.map { DownloadRow(record: $0, onOpened: { [weak self] in self?.onClose?() }) }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.refresh()
        }
        preferredContentSize = NSSize(width: Self.width, height: 32 + CGFloat(rows.count) * DownloadRow.height + 6)
    }
}

// MARK: - In-progress strip

/// Downloads in progress, at the bottom of the sidebar above the space bar: name, size, time left, cancel.
/// A row arrives as its file's icon lands (DownloadFlight), and stays a moment after the download ends, with a
/// full bar and a tick (or "Cancelled"), before it fades. It is empty (zero height) when nothing is downloading.
final class DownloadsStrip: NSView {
    private let stack = NSStackView()
    private var height: NSLayoutConstraint!
    private(set) var rows: [DownloadRow] = []
    static let maxRows = 3
    /// How long an ended download stays in the strip.
    static let lingerDone: TimeInterval = 2.6
    static let lingerFailed: TimeInterval = 1.6
    /// Called with the number of rows about to show (0 as the last row starts to fade).
    var onRowsChanged: ((Int) -> Void)?
    private var expiry: Timer?
    private var leaving = false
    /// While the Library is open its own list shows the progress, so the strip steps aside.
    var isSuppressed = false {
        didSet { if isSuppressed != oldValue { resize() } }
    }
    var debugHeight: CGFloat { height.constant }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .sorrelDownloads, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// What the strip shows: running downloads whose icon has landed, and ones that ended a moment ago.
    private func wanted() -> [DownloadRecord] {
        let now = Date()
        return Array(Engine.shared.downloads.filter { r in
            if DownloadFlight.inFlight.contains(ObjectIdentifier(r)) { return false }
            return r.state == .running || (Self.lingersUntil(r).map { $0 > now } ?? false)
        }.prefix(Self.maxRows))
    }

    /// When an ended download leaves the strip: a while after it ended, or after its icon landed if that was later.
    static func lingersUntil(_ r: DownloadRecord) -> Date? {
        guard r.state != .running, let finished = r.finished else { return nil }
        let base = max(finished, DownloadFlight.landedAt[ObjectIdentifier(r)] ?? .distantPast)
        return base.addingTimeInterval(r.state == .done ? lingerDone : lingerFailed)
    }

    @objc func reload() {
        let list = wanted()
        let ids = list.map(ObjectIdentifier.init)
        scheduleExpiry(list)
        if ids == rows.map({ ObjectIdentifier($0.record) }) {
            rows.forEach { $0.refresh() }
            return
        }
        guard !leaving else { return }   // the rebuild after the fade picks this change up
        // Rows that are going fade and shrink away first; the rest of the change follows once they've gone.
        let going = rows.filter { !ids.contains(ObjectIdentifier($0.record)) }
        if !going.isEmpty, !isSuppressed, window != nil {
            leaving = true
            if ids.isEmpty { onRowsChanged?(0) }
            for row in going {
                row.layer?.popOut(scale: 0.96, duration: 0.2)
                row.fade(in: false, duration: 0.2)
            }
            rows.filter { r in !going.contains { $0 === r } }.forEach { $0.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                self?.leaving = false
                self?.rebuild()
            }
            return
        }
        rebuild()
    }

    private func rebuild() {
        let list = wanted()
        let old = Dictionary(uniqueKeysWithValues: rows.map { (ObjectIdentifier($0.record), $0) })
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        rows = list.map { old[ObjectIdentifier($0)] ?? DownloadRow(record: $0) }
        for row in rows {
            row.showsCompletion = true
            row.layer?.clearPopOut()
            row.isHidden = false
            row.alphaValue = 1
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.refresh()
        }
        resize()
        onRowsChanged?(rows.count)
        // A new row rises into place as the icon drops onto it.
        for row in rows where old[ObjectIdentifier(row.record)] == nil { row.layer?.popIn(scale: 0.94, rise: -6, duration: 0.36) }
    }

    private func scheduleExpiry(_ list: [DownloadRecord]) {
        expiry?.invalidate()
        expiry = nil
        guard let next = list.compactMap(Self.lingersUntil).min() else { return }
        expiry = Timer.scheduledTimer(withTimeInterval: max(0.05, next.timeIntervalSinceNow + 0.02), repeats: false) { [weak self] _ in
            self?.reload()
        }
    }

    /// The strip grows and shrinks with the sidebar's contents sliding to make room.
    private func resize() {
        let target = isSuppressed ? 0 : CGFloat(rows.count) * DownloadRow.height
        guard height.constant != target else { return }
        // Set at once rather than animating the sidebar's layout: animating it shifted the tab list's scroll
        // position. New rows pop in instead (reload), and an emptied strip just closes.
        height.constant = target
    }
}

final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

/// One download: thumbnail, name, size or progress. Click opens it, drag carries the file out,
/// right-click has the rest.
final class DownloadRow: NSView, NSDraggingSource {
    let record: DownloadRecord
    static let height: CGFloat = 46
    /// Called after the row opened its file or showed it in Finder (the hover preview closes then).
    private let onOpened: (() -> Void)?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// The progress bar: a gradient in the space's colours with a soft glow, a light that sweeps along the filled
    /// part while it downloads, and a short segment that glides back and forth while the size is unknown.
    private let bar = CAGradientLayer()
    private let barTrack = CALayer()
    private let barHolder = NSView()
    private let shineClip = CALayer()
    private let shine = CAGradientLayer()
    private var barRevealed = false
    private var shimmerWidth: CGFloat = -1
    private var indeterminateWidth: CGFloat = -1
    /// The tick that draws itself when a download in the strip finishes.
    private let checkDisc = CAShapeLayer()
    private let checkMark = CAShapeLayer()
    private var checkShown = false
    private var checkDrawn = false
    /// In the strip (and the capsule), an ended download keeps its full bar and shows a tick before it goes.
    var showsCompletion = false
    private static let barHeight: CGFloat = 4
    private var action: IconButton!
    private let highlight = CALayer()
    private var hovering = false
    private var pressedAt: NSPoint?
    private var dragging = false
    private var thumbFor: String?
    /// The first refresh sets the hover button without a fade, so a new row appears in its final state.
    private var settled = false

    /// Quick Look pictures by path (only real previews; plain icons aren't cached here).
    private static let thumbs = NSCache<NSString, NSImage>()
    private static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
    private static let left: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = [.hour, .minute, .second]
        return f
    }()

    init(record: DownloadRecord, onOpened: (() -> Void)? = nil) {
        self.record = record
        self.onOpened = onOpened
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        highlight.cornerRadius = 8
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        name.font = .systemFont(ofSize: 12.5)
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        barHolder.wantsLayer = true
        let r = Self.barHeight / 2
        barTrack.cornerRadius = r
        bar.cornerRadius = r
        bar.startPoint = CGPoint(x: 0, y: 0.5)
        bar.endPoint = CGPoint(x: 1, y: 0.5)
        bar.shadowOpacity = 0.55
        bar.shadowRadius = 3
        bar.shadowOffset = .zero
        shineClip.cornerRadius = r
        shineClip.masksToBounds = true
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.colors = [0, 0.6, 0].map { NSColor.white.withAlphaComponent($0).cgColor }
        shine.opacity = 0
        shineClip.addSublayer(shine)
        bar.addSublayer(shineClip)
        barHolder.layer?.addSublayer(barTrack)
        barHolder.layer?.addSublayer(bar)
        action = IconButton(symbol: "magnifyingglass", size: 11) { [weak self] in self?.primaryAction() }
        action.isHidden = true   // shown on hover, or always while downloading
        checkDisc.opacity = 0
        checkMark.fillColor = nil
        checkMark.strokeColor = NSColor.white.cgColor
        checkMark.lineWidth = 1.8
        checkMark.lineCap = .round
        checkMark.lineJoin = .round
        checkMark.strokeEnd = 0
        checkDisc.addSublayer(checkMark)
        layer?.addSublayer(checkDisc)
        NotificationCenter.default.addObserver(self, selector: #selector(tintChanged), name: .sorrelDownloadTint, object: nil)

        for v in [icon, name, detail, barHolder, action!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            barHolder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            barHolder.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -6),
            barHolder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            barHolder.heightAnchor.constraint(equalToConstant: Self.barHeight),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 22),
            action.heightAnchor.constraint(equalToConstant: 22),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var exists: Bool { FileManager.default.fileExists(atPath: record.file.path) }
    private var canOpen: Bool { record.state == .done && exists }

    override func layout() {
        super.layout()
        Motion.layer(0) {
            highlight.frame = bounds
            barTrack.frame = barHolder.bounds
            bar.frame.size.height = barHolder.bounds.height
            // The tick sits where the action button is.
            let a = action.frame
            checkDisc.frame = CGRect(x: a.midX - 8, y: a.midY - 8, width: 16, height: 16)
            checkDisc.path = CGPath(ellipseIn: checkDisc.bounds, transform: nil)
            checkMark.frame = checkDisc.bounds
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: 4.6, y: 8.2))
            tick.addLine(to: CGPoint(x: 7, y: 5.6))
            tick.addLine(to: CGPoint(x: 11.6, y: 10.6))
            checkMark.path = tick
        }
        updateBar(animated: false)
    }

    @objc private func tintChanged() { applyColors() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            barTrack.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            let tint = Store.shared.currentSpace.theme.progressColors(dark: isDarkAppearance)
            bar.colors = tint.map(\.cgColor)
            bar.shadowColor = (tint.last ?? tint[0]).cgColor
            checkDisc.fillColor = tint[0].cgColor
        }
    }

    /// Brings the text, thumbnail, bar and button up to date with the record.
    func refresh() {
        let file = record.file
        let present = exists
        name.stringValue = file.lastPathComponent
        name.textColor = record.state == .failed || (record.state == .done && !present) ? .secondaryLabelColor : .labelColor
        detail.stringValue = detailText(present: present)
        toolTip = record.state == .done && present ? file.path : nil

        switch record.state {
        case .running:
            setThumb(fallback: true)
            action.image = symbol("xmark.circle.fill", size: 12)
            action.toolTip = "Cancel"
        case .done:
            setThumb(fallback: !present)
            action.image = symbol("magnifyingglass", size: 11)
            action.toolTip = "Show in Finder"
        case .failed:
            setThumb(fallback: true)
            action.image = symbol("xmark", size: 10)
            action.toolTip = "Remove from List"
        }
        icon.alphaValue = record.state == .done && present ? 1 : 0.55
        // A download that just finished in the strip shows a tick in the button's place until hovered.
        let completed = showsCompletion && record.state == .done && present
        let tick = completed && !hovering
        let showAction = !tick && (record.state == .running || (hovering && (record.state != .done || present)))
        if !settled {
            action.isHidden = !showAction
            settled = true
        } else if action.isHidden == showAction {
            action.fade(in: showAction)
        }
        setCheck(tick)
        barHolder.isHidden = record.state != .running && !completed
        updateBar(animated: true)
    }

    private func setCheck(_ on: Bool) {
        guard on != checkShown else { return }
        checkShown = on
        Motion.layer(on ? 0.16 : 0.12) { checkDisc.opacity = on ? 1 : 0 }
        guard on, !checkDrawn else { return }
        // The first time: the disc pops in and the tick draws itself across it.
        checkDrawn = true
        checkDisc.popIn(scale: 0.3, fade: false, duration: 0.4)
        Motion.layer(0) { checkMark.strokeEnd = 1 }
        guard !Motion.reduced else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = CACurrentMediaTime() + 0.14
        draw.duration = 0.3
        draw.fillMode = .backwards
        draw.timingFunction = Motion.settle
        checkMark.add(draw, forKey: "draw")
    }

    private func detailText(present: Bool) -> String {
        let fmt = Self.bytes
        switch record.state {
        case .running:
            if record.received <= 0 { return "Starting…" }
            guard record.total > 0 else { return fmt.string(fromByteCount: record.received) }
            var text = "\(fmt.string(fromByteCount: record.received)) of \(fmt.string(fromByteCount: record.total))"
            let elapsed = Date().timeIntervalSince(record.started)
            if elapsed > 1.5, record.received > 0 {
                let rate = Double(record.received) / elapsed
                let remaining = Double(record.total - record.received) / rate
                if remaining.isFinite, remaining >= 1, let s = Self.left.string(from: remaining) { text += " · \(s) left" }
            }
            return text
        case .done:
            guard present else { return "Moved or deleted" }
            let when = record.finished ?? record.started
            let ago = Date().timeIntervalSince(when) < 60 ? "Just now" : Self.ago.localizedString(for: when, relativeTo: Date())
            return record.received > 0 ? "\(fmt.string(fromByteCount: record.received)) · \(ago)" : ago
        case .failed:
            return record.cancelled ? "Cancelled" : "Didn’t finish"
        }
    }

    private func updateBar(animated: Bool) {
        let width = barHolder.bounds.width, h = barHolder.bounds.height
        guard width > 0, !barHolder.isHidden else { return }
        let running = record.state == .running
        let unknown = running && record.total <= 0
        let f: CGFloat = record.state == .done ? 1
            : unknown ? 0.3
            : record.total > 0 ? CGFloat(max(0, min(1, Double(record.received) / Double(record.total)))) : 0
        let target = CGRect(x: 0, y: 0, width: max(h, width * f), height: h)
        var duration: TimeInterval = animated ? 0.3 : 0
        if !barRevealed {
            // The bar's first appearance: it grows out from the left as the row arrives.
            barRevealed = true
            Motion.layer(0) { bar.frame = CGRect(x: 0, y: 0, width: h, height: h) }
            duration = Motion.reduced ? 0 : 0.55
        }
        Motion.layer(duration, duration > 0.3 ? Motion.settle : Motion.glide) {
            bar.frame = target
            shineClip.frame = CGRect(origin: .zero, size: target.size)
        }
        setIndeterminate(unknown && !Motion.reduced ? width : nil)
        setShimmer(running && !unknown && !Motion.reduced ? width : nil)
    }

    /// While the size is unknown, the segment glides from end to end and back.
    private func setIndeterminate(_ width: CGFloat?) {
        guard width != indeterminateWidth else { return }
        indeterminateWidth = width ?? -1
        bar.removeAnimation(forKey: "unknown")
        guard let width else { return }
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = width * 0.15
        a.toValue = width * 0.85
        a.duration = 1.0
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = Motion.glide
        bar.add(a, forKey: "unknown")
    }

    /// A light passes along the filled part of the bar every couple of seconds while it downloads.
    private func setShimmer(_ width: CGFloat?) {
        guard width != shimmerWidth else { return }
        shimmerWidth = width ?? -1
        shine.removeAnimation(forKey: "sweep")
        guard let width else { Motion.layer(0) { shine.opacity = 0 }; return }
        let w: CGFloat = 44
        Motion.layer(0) {
            shine.opacity = 1
            shine.frame = CGRect(x: -w, y: 0, width: w, height: Self.barHeight)
        }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -w / 2
        sweep.toValue = width + w / 2
        sweep.duration = 1.3
        sweep.timingFunction = Motion.glide
        let loop = CAAnimationGroup()
        loop.animations = [sweep]
        loop.duration = 2.2
        loop.repeatCount = .infinity
        shine.add(loop, forKey: "sweep")
    }

    /// The file's own icon, swapped for a Quick Look picture (PDF page, image, video frame) once it exists.
    private func setThumb(fallback: Bool) {
        let path = record.file.path
        if fallback {
            guard thumbFor != "icon" else { return }
            thumbFor = "icon"
            let type = UTType(filenameExtension: record.file.pathExtension) ?? .data
            icon.image = NSWorkspace.shared.icon(for: type)
            framePreview(false)
            return
        }
        guard thumbFor != path else { return }
        thumbFor = path
        if let cached = Self.thumbs.object(forKey: path as NSString) { icon.image = cached; framePreview(true); return }
        icon.image = NSWorkspace.shared.icon(forFile: path)
        framePreview(false)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: record.file, size: CGSize(width: 30, height: 30),
                                                   scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            // Only a real preview (a page, a photo) replaces the icon; an icon-type result is no better.
            guard let rep, rep.type == .thumbnail else { return }
            let image = rep.nsImage
            DispatchQueue.main.async {
                Self.thumbs.setObject(image, forKey: path as NSString)
                guard let self, self.thumbFor == path else { return }
                self.icon.image = image
                self.framePreview(true)
            }
        }
    }

    /// A preview gets a hairline edge and a soft shadow, as in Finder, so a white page still reads on a light panel.
    private func framePreview(_ on: Bool) {
        guard let layer = icon.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
        }
        layer.borderWidth = on ? 0.5 : 0
        layer.cornerRadius = on ? 3 : 0
        layer.masksToBounds = on
        icon.imageScaling = on ? .scaleProportionallyDown : .scaleProportionallyUpOrDown
    }

    // MARK: Actions

    private func primaryAction() {
        switch record.state {
        case .running: cancel()
        case .done: showInFinder()
        case .failed: Engine.shared.removeDownload(record)
        }
    }

    private func cancel() {
        record.cancelled = true
        record.download?.cancel { _ in }
    }

    private func open() {
        guard canOpen else { return }
        // Downloads are quarantined, so macOS still checks apps and installers before they run.
        NSWorkspace.shared.open(record.file)
        onOpened?()
    }

    private func showInFinder() {
        guard exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([record.file])
        onOpened?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let record = record
        switch record.state {
        case .running:
            m.addItem(ActionMenuItem("Cancel Download") { [weak self] in self?.cancel() })
        case .done:
            let open = ActionMenuItem("Open") { [weak self] in self?.open() }
            let show = ActionMenuItem("Show in Finder") { [weak self] in self?.showInFinder() }
            let copy = ActionMenuItem("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([record.file as NSURL])
            }
            for item in [open, show, copy] {
                item.isEnabled = exists
                m.addItem(item)
            }
            m.autoenablesItems = false
            m.addItem(.separator())
            m.addItem(ActionMenuItem("Remove from List") { Engine.shared.removeDownload(record) })
            if exists { m.addItem(ActionMenuItem("Move to Trash") { Engine.shared.trashDownload(record) }) }
        case .failed:
            m.addItem(ActionMenuItem("Remove from List") { Engine.shared.removeDownload(record) })
        }
        return m
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        Motion.layer(on ? 0.12 : 0.2) { highlight.opacity = on ? 1 : 0 }
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        pressedAt = convert(event.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, canOpen, let start = pressedAt else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        dragging = true
        // Drag the file out to Finder, Mail, a page's upload box… as a copy, so the download stays put.
        let item = NSDraggingItem(pasteboardWriter: record.file as NSURL)
        item.setDraggingFrame(icon.frame, contents: icon.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil }
        guard !dragging, pressedAt != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Test hook: the row as text.
    var debugDescription_: String {
        "\(name.stringValue) | \(detail.stringValue) | bar=\(!barHolder.isHidden) action=\(action.isHidden ? "-" : action.toolTip ?? "?")"
    }
}
