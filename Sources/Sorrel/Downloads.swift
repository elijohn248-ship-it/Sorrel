import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// Arc-style downloads: the space bar's button fills a ring while files download, and opens a panel of
// recent downloads with thumbnails, live progress, drag-out, and quick actions.

// MARK: - Space bar button

/// The downloads button: an arrow that drops in when a download starts, inside a ring that fills as it goes.
final class DownloadsButton: NSView {
    private(set) var button: IconButton!
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var runningIDs: Set<ObjectIdentifier> = []
    private var spinning = false

    init(handler: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        button = IconButton(symbol: "arrow.down.circle", size: 12, tooltip: "Downloads", handler: handler)
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

    func update(_ list: [DownloadRecord]) {
        if isHidden != list.isEmpty {
            isHidden = list.isEmpty
            if !isHidden { layer?.popIn(scale: 0.6, duration: 0.3) }
        }
        let running = list.filter { $0.state == .running }
        let ids = Set(running.map(ObjectIdentifier.init))
        let started = !ids.subtracting(runningIDs).isEmpty
        let finished = !runningIDs.subtracting(ids).isEmpty && list.contains { runningIDs.contains(ObjectIdentifier($0)) && $0.state == .done }
        runningIDs = ids

        // A known size for every running file gives a real fraction; otherwise the ring just turns.
        let sized = running.filter { $0.total > 0 }
        let fraction: Double? = running.isEmpty || sized.count < running.count ? nil
            : Double(sized.reduce(0) { $0 + $1.received }) / Double(max(1, sized.reduce(0) { $0 + $1.total }))

        button.image = symbol(running.isEmpty ? "arrow.down.circle" : "arrow.down", size: running.isEmpty ? 12 : 9,
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
            button.toolTip = "Downloads"
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

// MARK: - Panel

/// The popover's contents: header, then one row per recent download, newest first.
final class DownloadsPanel: NSViewController {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 52
    static let maxVisibleRows = 6
    private static let headerHeight: CGFloat = 40

    /// Closes the popover (after opening a file, say).
    var onClose: (() -> Void)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "No downloads yet")
    private var clearButton: NSButton!
    private var scrollHeight: NSLayoutConstraint!
    private(set) var rows: [DownloadRow] = []
    private var clock: Timer?

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))

        let title = NSTextField(labelWithString: "Downloads")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        clearButton = NSButton(title: "Clear", target: self, action: #selector(clear))
        clearButton.isBordered = false
        clearButton.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor])
        clearButton.toolTip = "Clear finished downloads from this list (the files stay)"
        let folder = IconButton(symbol: "folder", size: 12, tooltip: "Open Downloads Folder") { [weak self] in
            self?.onClose?()
            Commands.shared.run("downloads.show")
        }
        for c in [title, clearButton!, folder] as [NSView] {
            c.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(c)
        }

        let document = FlippedContainer()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scroll)

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(empty)

        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: v.topAnchor, constant: Self.headerHeight / 2),
            folder.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            folder.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            folder.widthAnchor.constraint(equalToConstant: 24),
            folder.heightAnchor.constraint(equalToConstant: 24),
            clearButton.trailingAnchor.constraint(equalTo: folder.leadingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: v.topAnchor, constant: Self.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scrollHeight,

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -4),
        ])
        view = v
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: .sorrelDownloads, object: nil)
        reload(animated: false)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidAppear() {
        super.viewDidAppear()
        // "Just now" becomes "2 min ago" while the panel stays open.
        clock = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.rows.forEach { $0.refresh() } }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        clock?.invalidate()
        clock = nil
    }

    @objc private func changed() { reload(animated: true) }

    @objc private func clear() { Engine.shared.clearFinishedDownloads() }

    func reload(animated: Bool) {
        let list = Engine.shared.downloads
        if list.count == rows.count, zip(list, rows).allSatisfy({ $0 === $1.record }) {
            rows.forEach { $0.refresh() }
        } else {
            let old = Dictionary(uniqueKeysWithValues: rows.map { (ObjectIdentifier($0.record), $0) })
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            rows = list.map { old[ObjectIdentifier($0)] ?? DownloadRow(record: $0, panel: self) }
            for row in rows {
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
                row.refresh()
            }
            if animated {
                stack.layoutSubtreeIfNeeded()
                for row in rows where old[ObjectIdentifier(row.record)] == nil { row.layer?.popIn(scale: 0.96, rise: 4) }
            }
        }
        empty.isHidden = !list.isEmpty
        clearButton.isHidden = !list.contains { $0.state != .running }
        let visible = CGFloat(min(list.count, Self.maxVisibleRows))
        let height = list.isEmpty ? 56 : visible * Self.rowHeight + max(0, visible - 1) * stack.spacing + 6
        scrollHeight.constant = height
        preferredContentSize = NSSize(width: Self.width, height: Self.headerHeight + height)
    }
}

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

/// One download: thumbnail, name, size or progress. Click opens it, drag carries the file out,
/// right-click has the rest.
final class DownloadRow: NSView, NSDraggingSource {
    let record: DownloadRecord
    private weak var panel: DownloadsPanel?
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = CALayer()
    private let barTrack = CALayer()
    private let barHolder = NSView()
    private var action: IconButton!
    private let highlight = CALayer()
    private var hovering = false
    private var pressedAt: NSPoint?
    private var dragging = false
    private var thumbFor: String?

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

    init(record: DownloadRecord, panel: DownloadsPanel) {
        self.record = record
        self.panel = panel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        highlight.cornerRadius = 8
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        barHolder.wantsLayer = true
        barTrack.cornerRadius = 1.5
        bar.cornerRadius = 1.5
        barHolder.layer?.addSublayer(barTrack)
        barHolder.layer?.addSublayer(bar)
        action = IconButton(symbol: "magnifyingglass", size: 11) { [weak self] in self?.primaryAction() }

        for v in [icon, name, detail, barHolder, action!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DownloadsPanel.rowHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            barHolder.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            barHolder.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -6),
            barHolder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            barHolder.heightAnchor.constraint(equalToConstant: 3),
            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 22),
            action.heightAnchor.constraint(equalToConstant: 22),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var exists: Bool { FileManager.default.fileExists(atPath: record.file.path) }
    private var canOpen: Bool { record.state == .done && exists }

    override func layout() {
        super.layout()
        Motion.layer(0) {
            highlight.frame = bounds
            barTrack.frame = barHolder.bounds
            bar.frame.size.height = barHolder.bounds.height
        }
        updateBar(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            barTrack.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
            bar.backgroundColor = NSColor.controlAccentColor.cgColor
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
        let showAction = record.state == .running || (hovering && (record.state != .done || present))
        if action.isHidden == showAction { action.fade(in: showAction) }
        barHolder.isHidden = record.state != .running
        updateBar(animated: true)
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
        let width = barHolder.bounds.width
        let f = record.total > 0 ? CGFloat(max(0, min(1, Double(record.received) / Double(record.total)))) : 0.15
        Motion.layer(animated ? 0.25 : 0) { bar.frame = CGRect(x: 0, y: 0, width: max(3, width * f), height: barHolder.bounds.height) }
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
        let request = QLThumbnailGenerator.Request(fileAt: record.file, size: CGSize(width: 34, height: 34),
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
        panel?.onClose?()
    }

    private func showInFinder() {
        guard exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([record.file])
        panel?.onClose?()
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
