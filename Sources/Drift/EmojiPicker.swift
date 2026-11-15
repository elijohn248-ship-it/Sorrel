import AppKit
import CoreText

// MARK: - Catalog

struct EmojiEntry {
    let emoji: String
    let name: String
    /// Lower-cased words of the name and group, for search.
    let words: [Substring]
}

struct EmojiGroup {
    let title: String
    let symbol: String
    let entries: [EmojiEntry]
}

/// Every emoji in Resources/emoji.tsv (built from Unicode's emoji-test.txt by tools/make-emoji-list.py),
/// minus any this Mac's emoji font can't draw yet, grouped like Apple's picker.
enum EmojiCatalog {
    private static let groupInfo: [String: (title: String, symbol: String)] = [
        "Smileys & Emotion": ("Smileys & Emotion", "face.smiling"),
        "People & Body": ("People & Body", "hand.wave"),
        "Animals & Nature": ("Animals & Nature", "leaf"),
        "Food & Drink": ("Food & Drink", "fork.knife"),
        "Travel & Places": ("Travel & Places", "car"),
        "Activities": ("Activities", "soccerball"),
        "Objects": ("Objects", "lightbulb"),
        "Symbols": ("Symbols", "number"),
        "Flags": ("Flags", "flag"),
    ]

    private static let lock = NSLock()
    private static var cached: [EmojiGroup]?

    static var groups: [EmojiGroup] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    /// Loads the list off the main thread so the sheet opens instantly.
    static func preload() {
        DispatchQueue.global(qos: .utility).async { _ = groups }
    }

    private static func load() -> [EmojiGroup] {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let oneWidth = width(of: "😀", font: font)
        var order: [String] = []
        var byGroup: [String: [EmojiEntry]] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let group = String(parts[0]), emoji = String(parts[1]), name = String(parts[2])
            guard canDraw(emoji, font: font, oneWidth: oneWidth) else { continue }
            if byGroup[group] == nil { order.append(group) }
            let words = (name + " " + group).lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            byGroup[group, default: []].append(EmojiEntry(emoji: emoji, name: name, words: words))
        }
        return order.map { g in
            let info = groupInfo[g] ?? (g, "circle")
            return EmojiGroup(title: info.title, symbol: info.symbol, entries: byGroup[g] ?? [])
        }
    }

    private static func width(of s: String, font: CTFont) -> Double {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// True when the emoji font draws it as one picture (newer emoji show as boxes or as pieces side by side).
    private static func canDraw(_ emoji: String, font: CTFont, oneWidth: Double) -> Bool {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: emoji, attributes: [.font: font]))
        guard CTLineGetTypographicBounds(line, nil, nil, nil) < oneWidth * 1.5 else { return false }
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName] else { return false }
            // swiftlint:disable:next force_cast
            if (CTFontCopyPostScriptName(runFont as! CTFont) as String) != "AppleColorEmoji" { return false }
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            if glyphs.contains(0) { return false }
        }
        return true
    }

    /// Entries whose name (or group) has a word starting with every word typed.
    static func search(_ query: String) -> [EmojiEntry] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !terms.isEmpty else { return [] }
        return groups.flatMap(\.entries).filter { entry in
            terms.allSatisfy { term in entry.words.contains { $0.hasPrefix(term) } }
        }
    }
}

// MARK: - Grid

/// Draws a whole emoji list as one view (fast with ~1,900 emoji) and handles hover and clicks itself.
private final class EmojiGridView: NSView {
    struct Section { let title: String; let entries: [EmojiEntry] }

    var sections: [Section] = [] { didSet { hovered = nil; pressed = nil; relayout() } }
    var selectedEmoji: String? { didSet { needsDisplay = true } }
    var onPick: ((EmojiEntry) -> Void)?
    var onHover: ((EmojiEntry?) -> Void)?

    private let headerHeight: CGFloat = 26
    private let minCell: CGFloat = 28
    private var columns = 7
    private var cell: CGFloat = 28
    private var sectionTops: [CGFloat] = []
    private var hovered: IndexPath? { didSet { if oldValue != hovered { redraw(oldValue); redraw(hovered); onHover?(hovered.map(entry)) } } }
    private var pressed: IndexPath? { didSet { if oldValue != pressed { redraw(oldValue); redraw(pressed) } } }

    private let emojiAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 21)]
    private let headerAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Lays the sections out for the current width and sets the height to fit.
    func relayout() {
        let width = max(frame.width, minCell)
        columns = max(1, Int(width / minCell))
        cell = floor(width / CGFloat(columns))
        var y: CGFloat = 0
        sectionTops = sections.map { s in
            defer { y += headerHeight + CGFloat((s.entries.count + columns - 1) / columns) * cell }
            return y
        }
        let height = max(y + 6, enclosingScrollView?.contentSize.height ?? 0)
        if abs(frame.height - height) > 0.5 { setFrameSize(NSSize(width: frame.width, height: height)) }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { relayout() }
    }

    func top(ofSection i: Int) -> CGFloat { i < sectionTops.count ? sectionTops[i] : 0 }

    func section(atY y: CGFloat) -> Int {
        var found = 0
        for (i, top) in sectionTops.enumerated() where top <= y + 1 { found = i }
        return found
    }

    private func entry(_ p: IndexPath) -> EmojiEntry { sections[p.section].entries[p.item] }

    private func rect(_ p: IndexPath) -> NSRect {
        let x = CGFloat(p.item % columns) * cell
        let y = sectionTops[p.section] + headerHeight + CGFloat(p.item / columns) * cell
        return NSRect(x: x, y: y, width: cell, height: cell)
    }

    private func redraw(_ p: IndexPath?) {
        if let p, p.section < sections.count, p.section < sectionTops.count { setNeedsDisplay(rect(p)) }
    }

    private func index(at point: NSPoint) -> IndexPath? {
        for (s, top) in sectionTops.enumerated().reversed() where point.y >= top {
            let gridY = point.y - top - headerHeight
            guard gridY >= 0, point.x >= 0, point.x < CGFloat(columns) * cell else { return nil }
            let item = Int(gridY / cell) * columns + Int(point.x / cell)
            return item < sections[s].entries.count ? IndexPath(item: item, section: s) : nil
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (s, section) in sections.enumerated() {
            let top = sectionTops[s]
            let rows = (section.entries.count + columns - 1) / columns
            let bottom = top + headerHeight + CGFloat(rows) * cell
            guard bottom >= dirtyRect.minY, top <= dirtyRect.maxY else { continue }
            if !section.title.isEmpty, top + headerHeight >= dirtyRect.minY {
                (section.title as NSString).draw(at: NSPoint(x: 5, y: top + 8), withAttributes: headerAttrs)
            }
            let firstRow = max(0, Int((dirtyRect.minY - top - headerHeight) / cell))
            let lastRow = min(rows - 1, Int((dirtyRect.maxY - top - headerHeight) / cell))
            guard firstRow <= lastRow else { continue }
            for item in (firstRow * columns)..<min(section.entries.count, (lastRow + 1) * columns) {
                let p = IndexPath(item: item, section: s)
                let r = rect(p)
                let e = section.entries[item]
                let fill: NSColor? = p == pressed ? NSColor.labelColor.withAlphaComponent(0.18)
                    : e.emoji == selectedEmoji ? NSColor.controlAccentColor.withAlphaComponent(0.28)
                    : p == hovered ? NSColor.labelColor.withAlphaComponent(0.09) : nil
                if let fill {
                    fill.setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
                }
                let str = e.emoji as NSString
                let size = str.size(withAttributes: emojiAttrs)
                str.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: emojiAttrs)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = index(at: convert(event.locationInWindow, from: nil))
        hovered = p
        if pressed != nil, p != pressed { pressed = nil }
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = pressed, p == index(at: convert(event.locationInWindow, from: nil)) else { pressed = nil; return }
        let e = entry(p)
        selectedEmoji = e.emoji
        onPick?(e)
        // Let the press highlight linger for a beat while the sheet starts to close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.pressed = nil }
    }

    func firstEntry() -> EmojiEntry? { sections.first?.entries.first }

    /// Where an emoji sits in the grid, if it's shown.
    func rect(of emoji: String) -> NSRect? {
        for (s, section) in sections.enumerated() {
            if let i = section.entries.firstIndex(where: { $0.emoji == emoji }) { return rect(IndexPath(item: i, section: s)) }
        }
        return nil
    }
}

/// A scroll view that reports when the list is pulled down past its top, like dismissing an iPhone sheet.
private final class PullScrollView: NSScrollView {
    var onPullDown: (() -> Void)?
    private var fired = false

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if event.phase == .began || contentView.bounds.minY >= 0 { fired = false }
        // Only while fingers are on the trackpad, not a momentum fling that bounces at the top.
        guard event.momentumPhase == [], !fired, contentView.bounds.minY < -56 else { return }
        fired = true
        onPullDown?()
    }
}

// MARK: - Sheet

/// The full emoji list that slides up over "Customize Space". Pick an emoji, press Esc, click the
/// chevron, drag the sheet down, or pull the list down past its top to slide it away again.
final class EmojiSheet: NSView, NSSearchFieldDelegate {
    var onPick: ((String) -> Void)?
    /// 0 = hidden below, 1 = fully up, so the editor behind can dim with it. `animated` is true when the
    /// call comes from inside the sheet's animation group (use `animator()`), false while being dragged.
    var onProgress: ((_ progress: CGFloat, _ animated: Bool) -> Void)?
    var onClosed: (() -> Void)?

    private(set) var isOpen = false
    private let search = NSSearchField()
    private let grid = EmojiGridView()
    private let scroll = PullScrollView()
    private let footer = NSTextField(labelWithString: "")
    private var tabs: [IconButton] = []
    private let tabRow = NSStackView()
    private let empty = NSTextField(labelWithString: "No emoji found")
    private var groups: [EmojiGroup] = []
    private var searching = false
    private var dragStart: (mouseY: CGFloat, originY: CGFloat)?
    private var dragSamples: [(time: TimeInterval, y: CGFloat)] = []
    private var animationToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let grabber = NSView()
        grabber.wantsLayer = true
        grabber.layer?.cornerRadius = 2.5
        grabber.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        grabber.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grabber)

        search.placeholderString = "Search emoji"
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.focusRingType = .none
        search.controlSize = .regular
        let done = IconButton(symbol: "chevron.down", size: 13, tooltip: "Close (Esc)") { [weak self] in self?.close() }
        let header = NSStackView(views: [search, done])
        header.orientation = .horizontal
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        tabRow.orientation = .horizontal
        tabRow.distribution = .equalSpacing
        tabRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabRow)

        grid.onPick = { [weak self] e in self?.pick(e.emoji) }
        grid.onHover = { [weak self] e in self?.showName(e) }
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.onPullDown = { [weak self] in self?.close() }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        empty.textColor = .tertiaryLabelColor
        empty.isHidden = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            grabber.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            grabber.centerXAnchor.constraint(equalTo: centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 34),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            header.topAnchor.constraint(equalTo: grabber.bottomAnchor, constant: 9),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            tabRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            tabRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: tabRow.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -4),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 40),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        let width = scroll.contentSize.width
        if abs(grid.frame.width - width) > 0.5 { grid.frame.size.width = width }
        grid.relayout()
    }

    // MARK: Open and close

    /// Slides the sheet up from below `host`'s bottom edge and puts the cursor in the search box.
    func open(in host: NSView, current: String) {
        if groups.isEmpty { loadGroups() }
        if superview !== host {
            removeFromSuperview()
            host.addSubview(self, positioned: .above, relativeTo: nil)
        }
        frame = NSRect(x: 0, y: isOpen ? frame.minY : -host.bounds.height, width: host.bounds.width, height: host.bounds.height)
        isHidden = false
        isOpen = true
        grid.selectedEmoji = current
        showName(nil)
        layoutSubtreeIfNeeded()
        if !searching { scrollToSelected(current) }
        window?.makeFirstResponder(search)
        // A quick start that glides to rest, like a sheet thrown up from the bottom.
        animate(to: 0, duration: 0.42, timing: CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))
    }

    /// Slides the sheet back down out of sight.
    func close(velocity: CGFloat = 0) {
        guard isOpen else { return }
        isOpen = false
        let distance = frame.height + frame.minY
        // A flick keeps its speed; otherwise ease away a little quicker than it came in.
        let duration = velocity > 300 ? min(0.28, max(0.12, Double(distance / velocity) * 1.6)) : 0.3
        let timing = velocity > 300 ? CAMediaTimingFunction(controlPoints: 0.25, 0.6, 0.4, 1)
                                    : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.4)
        if window?.firstResponder === search.currentEditor() { window?.makeFirstResponder(nil) }
        animate(to: -frame.height, duration: duration, timing: timing) { [weak self] in
            guard let self, !self.isOpen else { return }
            self.isHidden = true
            if self.searching { self.search.stringValue = ""; self.applySearch() }
            self.onClosed?()
        }
    }

    private func animate(to y: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunction, done: (() -> Void)? = nil) {
        animationToken += 1
        let token = animationToken
        guard let host = superview else { return }
        let target = 1 + y / max(host.bounds.height, 1)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            animator().setFrameOrigin(NSPoint(x: 0, y: y))
            onProgress?(target, true)
        }, completionHandler: { [weak self] in
            guard let self, token == self.animationToken else { return }
            done?()
        })
    }

    private func pick(_ emoji: String) {
        onPick?(emoji)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.close() }
    }

    // MARK: Dragging the sheet down

    override func mouseDown(with event: NSEvent) {
        guard isOpen, let host = superview else { return }
        animationToken += 1
        dragStart = (host.convert(event.locationInWindow, from: nil).y, frame.minY)
        dragSamples = []
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let host = superview else { return }
        let y = host.convert(event.locationInWindow, from: nil).y
        var offset = start.originY + (y - start.mouseY)
        // Pulling up past the top gives a little, then resists.
        if offset > 0 { offset = 10 * (1 - 1 / (offset / 30 + 1)) }
        setFrameOrigin(NSPoint(x: 0, y: offset))
        onProgress?(1 + min(0, offset) / max(host.bounds.height, 1), false)
        dragSamples.append((event.timestamp, y))
        if dragSamples.count > 6 { dragSamples.removeFirst() }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let host = superview else { return }
        dragStart = nil
        // Downward speed in points per second from the last few samples.
        var velocity: CGFloat = 0
        if let first = dragSamples.first, let last = dragSamples.last, last.time - first.time > 0.005 {
            velocity = (first.y - last.y) / CGFloat(last.time - first.time)
        }
        let dragged = -frame.minY
        if velocity > 450 || (dragged > host.bounds.height * 0.3 && velocity > -200) {
            close(velocity: max(velocity, 0))
        } else {
            // Spring back up.
            animate(to: 0, duration: 0.32, timing: CAMediaTimingFunction(controlPoints: 0.2, 1.2, 0.4, 1))
        }
    }

    // MARK: Contents

    private func loadGroups() {
        groups = EmojiCatalog.groups
        tabs.forEach { $0.removeFromSuperview() }
        tabs = groups.enumerated().map { i, g in
            let b = IconButton(symbol: g.symbol, size: 12, tooltip: g.title) { [weak self] in self?.jump(to: i) }
            tabRow.addArrangedSubview(b)
            return b
        }
        applySearch()
    }

    private func applySearch() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        searching = !q.isEmpty
        if searching {
            let found = EmojiCatalog.search(q)
            grid.sections = [.init(title: found.isEmpty ? "" : "Results", entries: found)]
            empty.isHidden = !found.isEmpty
        } else {
            grid.sections = groups.map { .init(title: $0.title, entries: $0.entries) }
            empty.isHidden = true
        }
        grid.scroll(.zero)
        updateTabs()
    }

    private func jump(to i: Int) {
        if searching { search.stringValue = ""; applySearch() }
        let y = min(grid.top(ofSection: i), max(0, grid.frame.height - scroll.contentSize.height))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Opens with the current icon in the middle of the list, so it's easy to see what's chosen.
    private func scrollToSelected(_ emoji: String) {
        let visible = scroll.contentSize.height
        let maxY = max(0, grid.frame.height - visible)
        let y = grid.rect(of: emoji).map { min(maxY, max(0, $0.midY - visible / 2)) } ?? 0
        grid.scroll(NSPoint(x: 0, y: y))
        updateTabs()
    }

    @objc private func scrolled() { updateTabs() }

    private func updateTabs() {
        // The section filling the upper part of the list, not one whose last row peeks in at the top.
        let clip = scroll.contentView.bounds
        let active = searching ? -1 : grid.section(atY: clip.minY + clip.height * 0.35)
        for (i, b) in tabs.enumerated() {
            b.contentTintColor = i == active ? .controlAccentColor : .secondaryLabelColor
        }
    }

    private func showName(_ e: EmojiEntry?) {
        if let e {
            footer.stringValue = e.name.prefix(1).uppercased() + e.name.dropFirst()
            footer.textColor = .secondaryLabelColor
        } else {
            footer.stringValue = searching ? "Return picks the first result" : "Esc or drag down to close"
            footer.textColor = .tertiaryLabelColor
        }
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        // An emoji typed straight in (e.g. from ⌃⌘Space) is picked as is.
        if let typed = search.stringValue.last, typed.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
            || (typed.unicodeScalars.count > 1 && typed.unicodeScalars.first?.properties.isEmoji == true) {
            pick(String(typed))
            return
        }
        applySearch()
        showName(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation(_:)):
            if searching { search.stringValue = ""; applySearch(); showName(nil) } else { close() }
            return true
        case #selector(insertNewline(_:)):
            if searching, let first = grid.firstEntry() { grid.selectedEmoji = first.emoji; pick(first.emoji) }
            return true
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    // MARK: Test hooks

    func debugState() -> String {
        let total = groups.reduce(0) { $0 + $1.entries.count }
        let focused = window?.firstResponder === search.currentEditor()
        return "open=\(isOpen) y=\(Int(frame.minY)) h=\(Int(frame.height)) groups=\(groups.count) emoji=\(total) "
            + "shown=\(grid.sections.reduce(0) { $0 + $1.entries.count }) searchFocused=\(focused) hidden=\(isHidden)"
    }

    func debugSearch(_ q: String) -> String {
        search.stringValue = q
        applySearch()
        return "results=\(grid.sections.first?.entries.count ?? 0) first=\(grid.firstEntry()?.emoji ?? "-")"
    }

    func debugPickFirst() -> String? {
        guard let e = grid.firstEntry() else { return nil }
        grid.selectedEmoji = e.emoji
        pick(e.emoji)
        return e.emoji
    }
}
