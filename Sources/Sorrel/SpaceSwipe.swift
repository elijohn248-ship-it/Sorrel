import AppKit

// Arc-style sliding between spaces: a sideways two-finger swipe anywhere over the sidebar, or click-and-hold
// on the space icons and drag. The space page follows the fingers (or the cursor), the next space slides in
// beside it, the window's colours blend between the two, and letting go settles on a space with a spring.

/// Slides the sidebar's space page between spaces. Its position is measured in spaces (0 = the first space,
/// 1.5 = halfway from the second to the third). The real page (the live outline) sits where the current space
/// belongs; any other space on screen is a `SpacePreviewView`, a still, read-only copy built from the same cells.
/// The store only switches when the slide is let go, so a swipe that is taken back changes nothing.
final class SpacePager {
    var onPosition: ((CGFloat) -> Void)?
    var onTheme: ((Theme, Theme, CGFloat) -> Void)?
    var onDone: (() -> Void)?

    private(set) var isActive = false
    private(set) var position: CGFloat = 0
    private(set) var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private enum Mode { case drive, follow, settle }
    private var mode = Mode.drive
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var previews: [SpacePreviewView] = []

    private unowned let clip: NSView
    private unowned let page: NSView
    private let offset: NSLayoutConstraint
    private var store: Store { (clip.window?.windowController as? MainWindowController)?.store ?? .shared }

    init(clip: NSView, page: NSView, offset: NSLayoutConstraint) {
        self.clip = clip
        self.page = page
        self.offset = offset
    }

    var pageWidth: CGFloat { max(1, clip.bounds.width) }
    private var count: Int { store.spaces.count }
    private var currentIndex: Int { store.spaces.firstIndex { $0 === store.currentSpace } ?? 0 }

    /// Starts a slide, or catches one that is still settling. Returns where the page is, in spaces.
    @discardableResult
    func grab() -> CGFloat {
        if !isActive {
            isActive = true
            position = CGFloat(currentIndex)
            velocity = 0
        }
        stopLink()
        mode = .drive
        return position
    }

    /// Fingers on the trackpad: the page sits exactly at `p`, stretching (rubber-band) past the first and last space.
    func drive(to p: CGFloat) {
        guard isActive else { return }
        mode = .drive
        position = band(p)
        render()
    }

    /// Scrubbing the space icons: the page glides after `p` on a quick spring, so jumps between icons stay smooth.
    func follow(_ p: CGFloat) {
        guard isActive else { return }
        mode = .follow
        target = band(p)
        startLink()
    }

    /// Lets go: switches to space `index` at once (so the page and colours change while it lands), then settles
    /// there. `velocity` (spaces per second) carries a flick into the landing; nil keeps the current motion.
    func release(to index: Int, velocity v: CGFloat?) {
        guard isActive else { return }
        let i = max(0, min(count - 1, index))
        if let v { velocity = max(-8, min(8, v)) }
        target = CGFloat(i)
        mode = .settle
        if store.spaces.indices.contains(i), store.spaces[i] !== store.currentSpace {
            store.switchSpace(to: store.spaces[i])
        }
        if Motion.reduced {
            position = target
            finish()
            return
        }
        startLink()
    }

    /// Stop display callbacks before the owning window and its views are released.
    func cancel() { finish() }

    /// Past either end the page still moves, but less and less: at most half a page.
    private func band(_ p: CGFloat) -> CGFloat {
        let hi = CGFloat(max(0, count - 1))
        func rubber(_ x: CGFloat) -> CGFloat { 0.5 * (1 - 1 / (x * 1.1 + 1)) }
        if p < 0 { return -rubber(-p) }
        if p > hi { return hi + rubber(p - hi) }
        return p
    }

    // MARK: Motion

    private func startLink() {
        guard link == nil else { return }
        let l = clip.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTick = 0
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(1.0 / 30, max(0, now - lastTick))
        lastTick = now
        // Critically damped springs: no bounce. Following the cursor is quick; landing is a little softer.
        let omega: CGFloat = 2 * .pi / (mode == .follow ? 0.2 : 0.42)
        var x = position, v = velocity
        let steps = 4, h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            let a = -omega * omega * (x - target) - 2 * omega * v
            v += a * h
            x += v * h
        }
        position = x
        velocity = v
        if abs(x - target) < 0.001, abs(v) < 0.01 {
            position = target
            velocity = 0
            if mode == .settle {
                finish()
                return
            }
            stopLink()
        }
        render()
    }

    private func finish() {
        stopLink()
        isActive = false
        velocity = 0
        offset.constant = 0
        for p in previews {
            p.isHidden = true
            p.forget()
        }
        clip.layoutSubtreeIfNeeded()
        onPosition?(CGFloat(currentIndex))
        onDone?()
    }

    // MARK: Drawing

    private func render() {
        let spaces = store.spaces
        guard !spaces.isEmpty else { return }
        let w = pageWidth
        let scale = clip.window?.backingScaleFactor ?? 2
        func px(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let cur = currentIndex
        let low = Int(position.rounded(.down))
        let f = position - CGFloat(low)
        var visible = [low]
        if f > 0.0005 { visible.append(low + 1) }
        visible = visible.filter { spaces.indices.contains($0) }

        // The live page: wherever the current space belongs, kept just off screen when it isn't showing.
        let liveX = (CGFloat(cur) - position) * w
        offset.constant = px(max(-w - 1, min(w + 1, liveX)))
        clip.layoutSubtreeIfNeeded()

        // Still copies for the other spaces in view. Reuse one already showing that space, else a free one.
        let wanted = visible.filter { $0 != cur }
        var used: Set<ObjectIdentifier> = []
        for i in wanted {
            let sp = spaces[i]
            let view = previews.first { $0.space === sp && !used.contains(ObjectIdentifier($0)) }
                ?? previews.first { p in !used.contains(ObjectIdentifier(p)) && !wanted.contains { spaces[$0] === p.space } }
                ?? makePreview()
            used.insert(ObjectIdentifier(view))
            view.frame = NSRect(x: px((CGFloat(i) - position) * w), y: 0, width: w, height: clip.bounds.height)
            if view.space !== sp { view.show(sp) }
            view.isHidden = false
        }
        for p in previews where !used.contains(ObjectIdentifier(p)) { p.isHidden = true }

        // Colours: between the two spaces in view; past either end, that end's own.
        let a = max(0, min(spaces.count - 1, low)), b = max(0, min(spaces.count - 1, low + 1))
        let inRange = position >= 0 && position <= CGFloat(spaces.count - 1)
        onTheme?(spaces[a].theme, spaces[b].theme, inRange ? f : 0)
        onPosition?(position)
    }

    private func makePreview() -> SpacePreviewView {
        let v = SpacePreviewView(frame: clip.bounds)
        v.isHidden = true
        clip.addSubview(v)
        previews.append(v)
        return v
    }

    // MARK: Test support

    /// Where the live page and each visible copy sit, for the swipe test's log.
    var debugLayout: String {
        var parts = ["live@\(Int(offset.constant))"]
        for p in previews where !p.isHidden {
            parts.append("\(p.space?.name ?? "?")@\(Int(p.frame.minX))")
        }
        return parts.joined(separator: " ")
    }
}

/// Turns sideways two-finger trackpad swipes into a space slide. Vertical scrolls, wheel mice (no gesture
/// phases) and swipes that start mostly vertical are left alone; once a swipe is ours, its momentum glide is too.
final class SpaceSwipeTracker {
    private let pager: SpacePager
    var canStart: () -> Bool = { true }
    /// For the swipe test: synthetic events don't carry the trackpad's natural-scrolling flag.
    var debugInverted: Bool?

    private var sideways: Bool?
    private var base: CGFloat = 0
    private var travel: CGFloat = 0
    private var samples: [(time: TimeInterval, d: CGFloat)] = []
    private var ownsMomentum = false

    init(pager: SpacePager) { self.pager = pager }

    /// True when the event was part of a space swipe and has been handled.
    func handle(_ e: NSEvent) -> Bool {
        if !e.momentumPhase.isEmpty {
            let mine = ownsMomentum
            if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) { ownsMomentum = false }
            return mine
        }
        guard !e.phase.isEmpty, e.hasPreciseScrollingDeltas else { return false }
        if e.phase.contains(.began) {
            sideways = nil
            ownsMomentum = false
        }
        if sideways == nil {
            let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return false }
            if abs(dx) > abs(dy) * 1.3, canStart() {
                sideways = true
                base = pager.grab()
                travel = 0
                samples = []
            } else {
                sideways = false
            }
        }
        guard sideways == true else {
            if e.phase.contains(.ended) || e.phase.contains(.cancelled) { sideways = nil }
            return false
        }
        if e.phase.contains(.began) || e.phase.contains(.changed) {
            // How far the fingers moved (to the right = positive), whichever way scrolling is set to go:
            // the page follows the fingers, like swiping between pages in Safari.
            let inverted = debugInverted ?? e.isDirectionInvertedFromDevice
            let d = inverted ? e.scrollingDeltaX : -e.scrollingDeltaX
            travel += d
            samples.append((e.timestamp, d))
            samples.removeAll { e.timestamp - $0.time > 0.1 }
            pager.drive(to: base - travel / pager.pageWidth)
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            sideways = nil
            ownsMomentum = true
            samples.removeAll { e.timestamp - $0.time > 0.1 }
            var fingerSpeed: CGFloat = 0   // points per second
            if let first = samples.first, let last = samples.last, last.time - first.time > 0.008 {
                fingerSpeed = samples.reduce(0) { $0 + $1.d } / CGFloat(last.time - first.time)
            }
            let v = -fingerSpeed / pager.pageWidth   // spaces per second
            let p = pager.position
            let target: CGFloat
            if e.phase.contains(.cancelled) {
                target = base.rounded()
            } else if abs(v) > 0.6 {
                // A flick goes on to the next space in its direction, however short it was.
                target = v > 0 ? p.rounded(.up) : p.rounded(.down)
            } else {
                target = p.rounded()
            }
            pager.release(to: Int(target), velocity: v)
        }
        return true
    }
}

/// A still, read-only copy of a space's page (header and tab list) for a space that slides into view during a
/// swipe. Built from the sidebar's own cells so it looks the same; it takes no clicks and shows no hover.
final class SpacePreviewView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private(set) weak var space: Space?
    private let icon = NSButton(title: "", target: nil, action: nil)
    private let name = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let outline = SidebarOutline()
    private let separator = Marker(.separator)
    private let newTab = Marker(.newTab)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        icon.isBordered = false
        icon.font = .systemFont(ofSize: 14)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        for v in [icon, name, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 0
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        // Same placement as the real header and list (SidebarView.build).
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ sp: Space) {
        space = sp
        // Each page wears its own space's light or dark look, as the sidebar will once it arrives.
        appearance = NSAppearance(named: sp.theme.isDark(systemIsDark: systemIsDark()) ? .darkAqua : .aqua)
        icon.title = sp.icon
        name.stringValue = sp.name + (sp.profileID != nil ? "  ·  separate logins" : "")
        layoutSubtreeIfNeeded()
        outline.reloadData()
        func expand(_ items: [Item]) {
            for i in items where i.isFolder && i.expanded {
                outline.expandItem(i)
                expand(i.children)
            }
        }
        expand(sp.pinned)
        outline.sizeLastColumnToFit()
        outline.scroll(.zero)
        layoutSubtreeIfNeeded()
    }

    /// Drops the copy, so the next swipe rebuilds it from the space as it is then.
    func forget() {
        space = nil
        outline.reloadData()
    }

    private var store: Store { (window?.windowController as? MainWindowController)?.store ?? .shared }

    private var lit: Item? {
        guard let sp = space, let id = store.selectedID(in: sp), let item = store.item(id: id) else { return nil }
        return store.unit(item)
    }

    // MARK: Outline data (a read-only mirror of SidebarView's)

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let folder = item as? Item { return folder.children.count }
        guard let sp = space else { return 0 }
        return sp.pinned.count + 2 + sp.today.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let folder = item as? Item { return folder.children[index] }
        guard let sp = space else { return newTab }
        let p = sp.pinned.count
        if index < p { return sp.pinned[index] }
        if index == p { return separator }
        if index == p + 1 { return newTab }
        return sp.today[index - p - 2]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let m = item as? Marker, m.kind == .separator { return 22 }
        return 34
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        row.tracksHover = false
        if let m = item as? Marker {
            row.highlightable = m.kind == .newTab
            row.isActive = false
        } else {
            row.highlightable = true
            let lit = self.lit
            row.isActive = lit != nil && (item as? Item) === lit
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let m = item as? Marker {
            switch m.kind {
            case .separator:
                let c = SeparatorCell()
                c.clear.isHidden = space?.today.isEmpty ?? true
                return c
            case .newTab:
                return NewTabCell()
            }
        }
        guard let it = item as? Item else { return nil }
        if it.isSplit {
            let c = SplitCell()
            let focused: Item? = lit === it ? space.flatMap { store.selectedID(in: $0) }.flatMap { store.item(id: $0) } : nil
            c.configure(it, level: outlineView.level(forItem: it), focused: focused)
            c.setHovered(false)
            return c
        }
        let c = ItemCell()
        c.configure(it, level: outlineView.level(forItem: it))
        c.setHovered(false)
        return c
    }
}
