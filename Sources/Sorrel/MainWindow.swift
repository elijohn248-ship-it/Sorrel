import AppKit
import WebKit

/// The window's root view. Reports cursor movement so the hidden sidebar can reveal itself.
final class RootView: NSView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    var onAppearanceChanged: (() -> Void)?
    private var area: NSTrackingArea?
    var trackWhenInactive = true { didSet { updateTrackingAreas() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
                      trackWhenInactive ? .activeAlways : .activeInActiveApp],
            owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The rounded card that holds the current page, or the panes of a split view.
final class ContentCard: NSView {
    /// The focused page.
    private(set) weak var webView: WKWebView?
    private let empty = NSTextField(labelWithString: "")
    let findBar = FindBar()

    // Split view (Split.swift has the pane and divider views).
    private(set) var panes: [PaneView] = []
    private var dividers: [PaneDivider] = []
    private var stacked = false
    private var fractions: [CGFloat] = []
    private let dropHighlight = NSView()
    private var dropSide: DropSide?
    private let paneGap: CGFloat = 8
    /// A pane's button was clicked: (pane index, action).
    var onPaneAction: ((Int, PaneAction) -> Void)?
    /// The panes were resized by dragging a divider.
    var onFractionsChanged: (([Double]) -> Void)?
    /// A tab from the sidebar was dropped on the page. Return false to refuse it.
    var canDrop: ((UUID) -> Bool)?
    var onDrop: ((UUID, DropSide) -> Void)?
    var isSplit: Bool { panes.count > 1 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        dropHighlight.wantsLayer = true
        dropHighlight.layer?.cornerRadius = 8
        dropHighlight.layer?.borderWidth = 2
        dropHighlight.isHidden = true
        addSubview(dropHighlight)
        registerForDraggedTypes([splitItemDragType])

        empty.font = .systemFont(ofSize: 15, weight: .medium)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        addSubview(findBar)

        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            findBar.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            findBar.widthAnchor.constraint(equalToConstant: 300),
            findBar.heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// With no tab open the card is see-through, so the space's own color and gradient fill the area.
    private var isEmpty = true
    private var themeIsDark = false
    /// A single page can fill fullscreen; split panes retain their individual frames.
    var paneCornerRadius: CGFloat = 8
    var edgeToEdge = false {
        didSet {
            guard oldValue != edgeToEdge else { return }
            for pane in panes { pane.layer?.cornerRadius = edgeToEdge && !isSplit ? 0 : paneCornerRadius }
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if isEmpty || isSplit {
            // Split panes draw their own frames; the space's color shows in the gaps.
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = isSplit ? 0 : 0.5
            layer?.borderColor = (themeIsDark ? NSColor.white : NSColor.black).withAlphaComponent(0.14).cgColor
        } else {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        }
        if edgeToEdge && !isSplit { layer?.borderWidth = 0 }
        let accent = NSColor.controlAccentColor
        dropHighlight.layer?.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        dropHighlight.layer?.borderColor = accent.withAlphaComponent(0.8).cgColor
    }

    /// Keeps the "no tab open" text readable on the space's color.
    func setTheme(isDark: Bool) {
        themeIsDark = isDark
        empty.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for p in panes { p.themeIsDark = isDark }
        needsDisplay = true
    }

    func show(_ newWebView: WKWebView?) {
        show(newWebView.map { [$0] } ?? [], focused: 0, stacked: false, fractions: [])
    }

    /// Shows one page, or several side by side. Panes whose page is already on screen are kept as they are,
    /// so changing focus between panes never reloads or flickers.
    func show(_ views: [WKWebView], focused: Int, stacked: Bool, fractions: [Double]) {
        let focusedView = views.indices.contains(focused) ? views[focused] : views.first
        if focusedView !== webView { findBar.close() }
        webView = focusedView
        isEmpty = views.isEmpty

        let same = views.count == panes.count && zip(views, panes).allSatisfy { $0 === $1.webView }
        if !same {
            var old = panes
            var next: [PaneView] = []
            for wv in views {
                if let i = old.firstIndex(where: { $0.webView === wv }) {
                    next.append(old.remove(at: i))
                } else {
                    let pane = PaneView(webView: wv, cornerRadius: layer?.cornerRadius ?? 8)
                    pane.themeIsDark = themeIsDark
                    next.append(pane)
                }
            }
            for p in old {
                // Leave the web view alone if something else (a peek, another pane) has taken it.
                if p.webView.superview === p { p.webView.removeFromSuperview() }
                p.removeFromSuperview()
            }
            panes = next
            for p in panes where p.superview !== self { addSubview(p, positioned: .below, relativeTo: dropHighlight) }
            for (i, p) in panes.enumerated() {
                let index = i
                p.onAction = { [weak self] action in self?.onPaneAction?(index, action) }
            }
        }
        for p in panes {
            p.reclaimWebView()
            p.inSplit = panes.count > 1
            p.layer?.cornerRadius = edgeToEdge && panes.count == 1 ? 0 : paneCornerRadius
            p.isFocused = p.webView === focusedView
        }
        self.stacked = stacked
        let n = panes.count
        let given = SplitLayout(stacked: stacked, fractions: fractions).normalized(count: n)
        self.fractions = given.map { CGFloat($0) }
        syncDividers()
        if views.isEmpty {
            let key = Keybindings.shared.display(for: "tab.new") ?? "⌘T"
            empty.stringValue = "No tab open  ·  \(key) to start"
            empty.isHidden = false
        } else {
            empty.isHidden = true
        }
        needsDisplay = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func syncDividers() {
        let want = max(0, panes.count - 1)
        while dividers.count > want { dividers.removeLast().removeFromSuperview() }
        while dividers.count < want {
            let d = PaneDivider()
            addSubview(d, positioned: .below, relativeTo: dropHighlight)
            dividers.append(d)
        }
        for (i, d) in dividers.enumerated() {
            d.stacked = stacked
            let index = i
            d.onDrag = { [weak self] p in self?.dragDivider(index, to: p) }
            d.onDragEnd = { [weak self] in
                guard let self else { return }
                self.onFractionsChanged?(self.fractions.map { Double($0) })
            }
            d.onReset = { [weak self] in
                guard let self, !self.panes.isEmpty else { return }
                self.fractions = Array(repeating: 1 / CGFloat(self.panes.count), count: self.panes.count)
                self.needsLayout = true
                self.onFractionsChanged?(self.fractions.map { Double($0) })
            }
        }
    }

    /// Length available to panes along the split direction.
    private var paneSpan: CGFloat {
        (stacked ? bounds.height : bounds.width) - paneGap * CGFloat(max(0, panes.count - 1))
    }

    private func dragDivider(_ index: Int, to p: NSPoint) {
        guard index + 1 < fractions.count, paneSpan > 0 else { return }
        // Where the divider sits now, measured from the start (left, or top) of the card.
        let along = stacked ? bounds.height - p.y : p.x
        let before = fractions[..<index].reduce(0, +) * paneSpan + CGFloat(index) * paneGap
        let pair = fractions[index] + fractions[index + 1]
        let minShare = min(pair / 2, 180 / paneSpan)
        var first = (along - before - paneGap / 2) / paneSpan
        first = max(minShare, min(pair - minShare, first))
        fractions[index] = first
        fractions[index + 1] = pair - first
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = panes.count
        guard n > 0 else { return }
        if n == 1 {
            panes[0].frame = bounds
            return
        }
        let span = paneSpan
        var pos: CGFloat = 0
        for i in 0..<n {
            let len = i == n - 1 ? span + CGFloat(n - 1) * paneGap - pos : (span * fractions[i]).rounded()
            if stacked {
                panes[i].frame = NSRect(x: 0, y: bounds.height - pos - len, width: bounds.width, height: len)
            } else {
                panes[i].frame = NSRect(x: pos, y: 0, width: len, height: bounds.height)
            }
            pos += len
            if i < n - 1 {
                dividers[i].frame = stacked
                    ? NSRect(x: 0, y: bounds.height - pos - paneGap, width: bounds.width, height: paneGap)
                    : NSRect(x: pos, y: 0, width: paneGap, height: bounds.height)
                pos += paneGap
            }
        }
    }

    /// Test hook: drag the first divider so the first pane gets `f` of the space, then let go.
    func debugDragFirstDivider(toFraction f: CGFloat) {
        guard let d = dividers.first else { return }
        let along = paneSpan * f + paneGap / 2
        d.onDrag?(stacked ? NSPoint(x: 10, y: bounds.height - along) : NSPoint(x: along, y: 10))
        layoutSubtreeIfNeeded()
        d.onDragEnd?()
    }

    /// The pane that holds a view.
    func paneIndex(containing view: NSView) -> Int? {
        panes.firstIndex { view === $0 || view.isDescendant(of: $0) }
    }

    // MARK: Dropping a tab from the sidebar onto the page

    private func draggedID(_ info: NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: splitItemDragType).flatMap(UUID.init(uuidString:))
    }

    private func side(for info: NSDraggingInfo) -> DropSide? {
        let p = convert(info.draggingLocation, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let fx = p.x / bounds.width, fy = p.y / bounds.height
        if fx < 0.33 { return .left }
        if fx > 0.67 { return .right }
        if fy > 0.72 { return .top }
        if fy < 0.28 { return .bottom }
        return nil
    }

    private func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedID(info), canDrop?(id) ?? false, let s = side(for: info) else {
            setDropSide(nil)
            return []
        }
        setDropSide(s)
        return .move
    }

    private func setDropSide(_ s: DropSide?) {
        guard s != dropSide else { return }
        dropSide = s
        guard let s else { dropHighlight.isHidden = true; return }
        let inset = bounds.insetBy(dx: 6, dy: 6)
        var r = inset
        switch s {
        case .left: r.size.width = inset.width / 2
        case .right: r.origin.x = inset.midX; r.size.width = inset.width / 2
        case .top: r.origin.y = inset.midY; r.size.height = inset.height / 2
        case .bottom: r.size.height = inset.height / 2
        }
        dropHighlight.frame = r
        dropHighlight.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropSide(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropSide(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropSide(nil) }
        guard let id = draggedID(sender), let s = side(for: sender), canDrop?(id) ?? false else { return false }
        onDrop?(id, s)
        return true
    }
}

/// Find in page.
final class FindBar: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    weak var webView: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 10
            s.shadowColor = NSColor.black.withAlphaComponent(0.2)
            return s
        }()
        field.placeholderString = "Find on page"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let prev = IconButton(symbol: "chevron.up", size: 11, tooltip: "Previous") { [weak self] in self?.search(backwards: true) }
        let next = IconButton(symbol: "chevron.down", size: 11, tooltip: "Next") { [weak self] in self?.search(backwards: false) }
        let done = IconButton(symbol: "xmark", size: 10, tooltip: "Close") { [weak self] in self?.close() }
        for v in [field, status, prev, next, done] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -6),
            status.trailingAnchor.constraint(equalTo: prev.leadingAnchor, constant: -4),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            prev.trailingAnchor.constraint(equalTo: next.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -2),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            prev.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            prev.widthAnchor.constraint(equalToConstant: 22),
            next.widthAnchor.constraint(equalToConstant: 22),
            done.widthAnchor.constraint(equalToConstant: 22),
        ])
        status.setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    func open(for webView: WKWebView) {
        self.webView = webView
        isHidden = false
        status.stringValue = ""
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func close() {
        guard !isHidden else { return }
        isHidden = true
        if let wv = webView { window?.makeFirstResponder(wv) }
    }

    private func search(backwards: Bool) {
        let text = field.stringValue
        guard !text.isEmpty, let wv = webView else { return }
        let cfg = WKFindConfiguration()
        cfg.backwards = backwards
        cfg.wraps = true
        cfg.caseSensitive = false
        wv.find(text, configuration: cfg) { [weak self] result in
            self?.status.stringValue = result.matchFound ? "" : "Not found"
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            search(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }
}

final class SorrelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// While set, web pages cannot pull keyboard focus away from this view.
    /// (A page that is still loading can otherwise grab focus back from the command bar.)
    weak var focusHolder: NSView?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let holder = focusHolder, holder.window === self, !holder.isHiddenOrHasHiddenAncestor,
           let view = responder as? NSView, !view.isDescendant(of: holder) {
            var v: NSView? = view
            while let cur = v {
                if cur is WKWebView { return false }
                v = cur.superview
            }
        }
        return super.makeFirstResponder(responder)
    }
}

// MARK: - Main window

final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum SidebarMode { case pinned, hidden, peeking }

    let root = RootView()
    private let background = ThemeBackgroundView()
    let card = ContentCard()
    let sidebar: SidebarView
    let commandBar = CommandBar()
    /// Downloads in progress over the page's bottom left, while the sidebar is hidden (DownloadFlight.swift).
    let downloadsCapsule = DownloadsCapsule()
    private(set) var peek: PeekOverlay?
    /// The Import from Another Browser card while it is open (showImporter).
    fileprivate(set) var importer: ImportOverlay?
    private let toast = NSTextField(labelWithString: "")
    private let toastBox = NSView()

    private var sidebarLeading: NSLayoutConstraint!
    private var sidebarTop: NSLayoutConstraint!
    private var sidebarBottom: NSLayoutConstraint!
    private var sidebarWidth: NSLayoutConstraint!
    private var cardLeading: NSLayoutConstraint!
    private var cardTop: NSLayoutConstraint!
    private var cardBottom: NSLayoutConstraint!
    private var cardTrailing: NSLayoutConstraint!
    private var fullscreenLayout = false
    private var windowedCornerRadius: CGFloat = 8
    private(set) var mode: SidebarMode = .pinned
    private var peekTimer: Timer?
    private var outsideSince: Date?
    private var toastTimer: Timer?
    private var clickMonitor: Any?
    private let margin: CGFloat = 8

    let store: Store
    lazy var extensionWindow = ExtensionWindow(controller: self)
    private var width: CGFloat { CGFloat(store.sidebarWidth) }

    init(store: Store) {
        self.store = store
        sidebar = SidebarView(store: store)
        let w = SorrelWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        super.init(window: w)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Sorrel"
        // An empty toolbar gives the window buttons a taller, roomier strip.
        let toolbar = NSToolbar(identifier: "main")
        toolbar.showsBaselineSeparator = false
        w.toolbar = toolbar
        w.toolbarStyle = .unifiedCompact
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 520, height: 400)
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("SorrelWindow-" + store.windowID.uuidString)
        build()
        sidebar.reloadForWindow()
        observe()
        wireSplitView()
        mode = store.sidebarCollapsed ? .hidden : .pinned
        applyMode(animated: false)
        applyTheme(animated: false)
        showSelected()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        window.contentView = root
        root.wantsLayer = true
        sidebar.controller = self
        // Inner corners share a center with the window's own corners, so the gap stays even.
        let inner = max(6, window.outerCornerRadius - margin)
        windowedCornerRadius = inner
        card.paneCornerRadius = inner
        card.layer?.cornerRadius = inner
        sidebar.floatingBackground.cornerRadius = inner

        toastBox.wantsLayer = true
        toastBox.layer?.cornerRadius = 9
        toastBox.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        toastBox.alphaValue = 0
        toast.textColor = .white
        toast.font = .systemFont(ofSize: 12, weight: .medium)
        toast.lineBreakMode = .byTruncatingMiddle
        toast.translatesAutoresizingMaskIntoConstraints = false
        toastBox.addSubview(toast)

        // Order matters: the sidebar floats above the page, the command bar above everything.
        for v in [background, card, sidebar, toastBox, commandBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        downloadsCapsule.attach(to: root, over: card)
        commandBar.isHidden = true
        commandBar.controller = self

        sidebarLeading = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        sidebarTop = sidebar.topAnchor.constraint(equalTo: root.topAnchor)
        sidebarBottom = root.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: width)
        cardLeading = card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: width)

        cardTop = card.topAnchor.constraint(equalTo: root.topAnchor, constant: margin)
        cardTrailing = card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin)
        cardBottom = card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            sidebarLeading, sidebarTop, sidebarBottom, sidebarWidth,

            cardLeading,
            cardTop, cardTrailing, cardBottom,

            commandBar.topAnchor.constraint(equalTo: root.topAnchor),
            commandBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            commandBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            toastBox.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            toastBox.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            toastBox.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            toast.leadingAnchor.constraint(equalTo: toastBox.leadingAnchor, constant: 14),
            toast.trailingAnchor.constraint(equalTo: toastBox.trailingAnchor, constant: -14),
            toast.topAnchor.constraint(equalTo: toastBox.topAnchor, constant: 8),
            toast.bottomAnchor.constraint(equalTo: toastBox.bottomAnchor, constant: -8),
        ])

        root.trackWhenInactive = Settings.current.sidebarHoverWhenInactive
        root.onMouseMoved = { [weak self] p in self?.mouseMoved(to: p) }
        root.onMouseExited = { [weak self] in self?.mouseLeftWindow() }
        root.onAppearanceChanged = { [weak self] in self?.applyTheme(animated: false) }
    }

    private func observe() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(selectionChanged(_:)), name: .sorrelSelection, object: nil)
        nc.addObserver(self, selector: #selector(structureChanged), name: .sorrelStructure, object: nil)
        nc.addObserver(self, selector: #selector(themeChanged(_:)), name: .sorrelSpace, object: nil)
        nc.addObserver(self, selector: #selector(themeChanged(_:)), name: .sorrelTheme, object: nil)
    }

    @objc private func selectionChanged(_ note: Notification) {
        if let source = note.object as? Store, source !== store { return }
        dismissPeek(refocus: false)   // a preview belongs to the tab it was opened from
        showSelected()
    }
    @objc private func themeChanged(_ note: Notification) {
        if let source = note.object as? Store, source !== store { return }
        store.reconcileSelection()
        applyTheme(animated: true)
        showSelected()
    }
    @objc private func structureChanged() {
        store.reconcileSelection()
        showSelected()
    }

    // MARK: Content

    func showSelected() {
        guard let item = store.selected else {
            card.show(nil)
            window?.title = "Sorrel"
            return
        }
        let page = Engine.shared.ensurePage(for: item)
        if let sv = store.split(containing: item) {
            let views = sv.children.map { Engine.shared.ensurePage(for: $0).webView }
            let focus = sv.children.firstIndex { $0 === item } ?? 0
            card.show(views, focused: focus, stacked: sv.split?.stacked ?? false, fractions: sv.split?.fractions ?? [])
        } else {
            card.show(page.webView)
        }
        window?.title = item.displayTitle
        if commandBar.isHidden, window?.firstResponder !== page.webView { window?.makeFirstResponder(page.webView) }
    }

    // MARK: Split view

    private func wireSplitView() {
        card.onPaneAction = { [weak self] index, action in
            guard let self, let sel = self.store.selected, let sv = self.store.split(containing: sel),
                  sv.children.indices.contains(index) else { return }
            let tab = sv.children[index]
            switch action {
            case .separate: self.store.removeFromSplit(tab)
            case .close: self.store.close(tab)
            case .swap: self.store.rotatePanes(sv)
            }
        }
        card.onFractionsChanged = { [weak self] f in
            guard let self, let sel = self.store.selected, let sv = self.store.split(containing: sel) else { return }
            self.store.setSplitFractions(sv, f)
        }
        card.canDrop = { [weak self] id in
            guard let self, let dragged = self.store.item(id: id), let sel = self.store.selected else { return false }
            if dragged === sel || !self.store.canSplit(dragged) || !self.store.canSplit(sel) { return false }
            if let sv = self.store.split(containing: sel) {
                return sv.children.contains { $0 === dragged } || sv.children.count < SplitLayout.maxPanes
            }
            return true
        }
        card.onDrop = { [weak self] id, side in
            guard let self, let dragged = self.store.item(id: id) else { return }
            self.splitSelected(with: dragged, side: side)
        }
        // Clicking into a pane focuses it, so the address box and shortcuts follow what you're using.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            self?.focusPane(for: e)
            return e
        }
    }

    private func focusPane(for event: NSEvent) {
        guard event.window === window, card.isSplit, peek == nil, commandBar.isHidden,
              let sel = store.selected, let sv = store.split(containing: sel),
              let hit = root.hitTest(root.convert(event.locationInWindow, from: nil)),
              let index = card.paneIndex(containing: hit), sv.children.indices.contains(index) else { return }
        let tab = sv.children[index]
        if tab !== sel { store.select(tab) }
    }

    /// Opens `other` beside the tab on screen. `side` is where `other` goes.
    func splitSelected(with other: Item, side: DropSide = .right) {
        guard let sel = store.selected else { store.select(other); return }
        if store.makeSplit(sel, with: other, otherFirst: side.first, stacked: side.stacked) == nil {
            showToast(splitRefusal(sel, other))
        }
    }

    func splitRefusal(_ a: Item, _ b: Item) -> String {
        if store.isFavorite(a) || store.isFavorite(b) { return "Favorites can’t go in a split view" }
        if let sv = store.split(containing: a), sv.children.count >= SplitLayout.maxPanes {
            return "A split view holds up to \(SplitLayout.maxPanes) tabs"
        }
        return "Those tabs can’t be split"
    }

    /// Opens the link preview beside the current tab instead of over it.
    func splitPeek() {
        guard let overlay = peek, let base = store.selected else { expandPeek(); return }
        peek = nil
        let page = overlay.page
        overlay.removeFromSuperview()
        let tab = store.newTab(url: page.displayURL ?? "", title: page.webView.title ?? "", after: base,
                               select: false, page: page)
        if store.makeSplit(base, with: tab) == nil {
            store.select(tab)
            showToast(splitRefusal(base, tab))
        }
    }

    var currentWebView: WKWebView? { store.selected?.page?.webView }

    /// Edits the current tab's address. With the sidebar on screen this happens in its address box;
    /// with the sidebar hidden there is no box to edit in, so the centered bar is used.
    func editAddress() {
        let editMode: CommandBar.Mode = store.selected == nil ? .newTab : .editCurrent
        if mode == .hidden {
            commandBar.present(editMode)
        } else {
            root.layoutSubtreeIfNeeded()
            commandBar.present(editMode, anchor: sidebar.addressAnchor)
        }
    }

    /// Where an extension's pop-up attaches: the sidebar's extensions button, or the page corner if the sidebar is hidden.
    func extensionPopupAnchor(for entry: ExtensionEntry? = nil) -> (NSView, NSRect, NSRectEdge) {
        if mode == .hidden {
            return (card, NSRect(x: 12, y: card.bounds.height - 14, width: 2, height: 2), .minY)
        }
        let anchor = sidebar.extensionAnchor(for: entry)
        // From an icon in the address box the pop-up drops down; from the bottom button it opens sideways.
        return (anchor, anchor.bounds, anchor === sidebar.extensionsAnchor ? .maxX : .minY)
    }

    // MARK: Peek

    func showPeek(_ url: URL, profileID: UUID?) {
        dismissPeek(refocus: false, animated: false)
        let page = Engine.shared.makePage(profileID: profileID)
        Engine.shared.load(url.absoluteString, in: page)
        let overlay = PeekOverlay(page: page, cornerRadius: card.layer?.cornerRadius ?? 8)
        overlay.onClose = { [weak self] in self?.dismissPeek() }
        overlay.onExpand = { [weak self] in self?.expandPeek() }
        overlay.onSplit = { [weak self] in self?.splitPeek() }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Above the page, below the sidebar and the command bar.
        root.addSubview(overlay, positioned: .above, relativeTo: card)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: card.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        peek = overlay
        root.layoutSubtreeIfNeeded()
        overlay.animateIn()
        window?.makeFirstResponder(page.webView)
    }

    func dismissPeek(refocus: Bool = true, animated: Bool = true) {
        guard let overlay = peek else { return }
        peek = nil
        let finish = {
            overlay.page.teardown()
            overlay.removeFromSuperview()
        }
        if animated { overlay.animateOut(done: finish) } else { finish() }
        if refocus, commandBar.isHidden, let wv = currentWebView { window?.makeFirstResponder(wv) }
    }

    /// Turns the preview into a full tab in this space, keeping the page exactly as it is.
    func expandPeek() {
        guard let overlay = peek else { return }
        peek = nil   // cleared first: selecting the new tab must not tear the page down
        let page = overlay.page
        store.newTab(url: page.displayURL ?? "", title: page.webView.title ?? "", page: page)
        overlay.removeFromSuperview()
    }

    func applyTheme(animated: Bool) {
        let theme = store.currentSpace.theme
        background.apply(theme, animated: animated)
        sidebar.applyTheme(theme)
        card.setTheme(isDark: theme.isDark(systemIsDark: systemIsDark()))
        downloadsThemeChanged()
    }

    /// During a space swipe: the window (and floating sidebar) show `f` of the way from `a`'s colours to `b`'s.
    func blendTheme(_ a: Theme, _ b: Theme, _ f: CGFloat) {
        background.blend(a, b, f)
        sidebar.floatingBackground.blend(a, b, f)
    }

    func showToast(_ text: String) {
        toast.stringValue = text
        toastTimer?.invalidate()
        root.layoutSubtreeIfNeeded()
        if toastBox.alphaValue < 1 {
            toastBox.alphaValue = 1
            toastBox.layer?.popIn(scale: 0.94, rise: 10, duration: 0.3)
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: false) { [weak self] _ in
            Motion.run(0.3, Motion.leave) { self?.toastBox.animator().alphaValue = 0 }
        }
    }

    // MARK: Sidebar: pinned, hidden, or peeking on hover

    func toggleSidebar() {
        // From a hover peek, the shortcut keeps the sidebar open for good.
        setMode(mode == .pinned ? .hidden : .pinned)
        store.sidebarCollapsed = mode != .pinned
    }

    private func setMode(_ new: SidebarMode, animated: Bool = true) {
        guard new != mode else { return }
        mode = new
        peekTimer?.invalidate()
        peekTimer = nil
        outsideSince = nil
        if new == .peeking { startPeekWatch() }
        applyMode(animated: animated)
    }

    private func applyMode(animated: Bool) {
        downloadsCapsule.sidebarHidden = mode == .hidden
        func set(_ constraint: NSLayoutConstraint, _ value: CGFloat) {
            if animated { constraint.animator().constant = value } else { constraint.constant = value }
        }
        let apply = {
            let pageMargin: CGFloat = self.fullscreenLayout && self.mode != .pinned ? 0 : self.margin
            let radius = self.fullscreenLayout ? self.margin : self.windowedCornerRadius
            set(self.cardTop, pageMargin)
            set(self.cardBottom, -pageMargin)
            set(self.cardTrailing, -pageMargin)
            self.card.layer?.cornerRadius = self.fullscreenLayout && self.mode != .pinned ? 0 : radius
            self.card.paneCornerRadius = radius
            self.card.edgeToEdge = self.fullscreenLayout && self.mode != .pinned
            // Reapply radii even when only the window's shape changed.
            for pane in self.card.panes {
                pane.layer?.cornerRadius = self.card.edgeToEdge && !self.card.isSplit ? 0 : radius
            }
            switch self.mode {
            case .pinned:
                set(self.sidebarLeading, 0)
                set(self.sidebarTop, 0)
                set(self.sidebarBottom, 0)
                set(self.cardLeading, self.width)
            case .hidden:
                set(self.sidebarLeading, -(self.width + 40))
                set(self.sidebarTop, self.margin)
                set(self.sidebarBottom, self.margin)
                set(self.cardLeading, pageMargin)
            case .peeking:
                set(self.sidebarLeading, self.margin)
                set(self.sidebarTop, self.margin)
                set(self.sidebarBottom, self.margin)
                set(self.cardLeading, pageMargin)
            }
            self.sidebar.setFloating(self.mode != .pinned, fullscreen: self.fullscreenLayout, animated: animated)
            self.setWindowButtons(visible: self.mode != .hidden)
            self.root.layoutSubtreeIfNeeded()
        }
        if animated {
            // Arriving settles softly; leaving is a plain ease so the page is back in reach sooner.
            let duration = Settings.current.sidebarAnimationDuration
            Motion.run(mode == .hidden ? duration : duration * 1.3, mode == .hidden ? Motion.glide : Motion.settle, apply)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                apply()
            }
        }
    }

    private func setWindowButtons(visible: Bool) {
        guard let window else { return }
        let inFullScreen = fullscreenLayout || window.styleMask.contains(.fullScreen)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(kind) else { continue }
            // AppKit owns the auto-hiding fullscreen titlebar, including its exit control.
            b.animator().alphaValue = (visible || inFullScreen) ? 1 : 0
            b.isEnabled = visible || inFullScreen
        }
    }

    func resizeSidebar(to x: CGFloat) {
        guard mode == .pinned else { return }
        let w = max(190, min(420, x))
        store.sidebarWidth = Double(w)
        sidebarWidth.constant = w
        cardLeading.constant = w
    }

    /// Test hook: stands in for the real cursor position.
    var debugCursor: NSPoint?

    private var cursor: NSPoint {
        if let debugCursor { return debugCursor }
        guard let window else { return NSPoint(x: -10_000, y: -10_000) }
        return root.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private var overshootReach: CGFloat { CGFloat(max(0, Settings.current.sidebarOvershootReach)) }

    /// Level with the window, vertically.
    private func isBesideWindow(_ p: NSPoint) -> Bool { p.y >= 0 && p.y <= root.bounds.height }

    /// Just past the window's left edge: the cursor overshot while reaching for the sidebar.
    private func isOvershoot(_ p: NSPoint) -> Bool {
        overshootReach > 0 && p.x < 0 && p.x >= -overshootReach && isBesideWindow(p)
    }

    /// Where the cursor counts as "on the sidebar" while it is peeking.
    private func isInSidebarZone(_ p: NSPoint) -> Bool {
        let limit = margin + width + CGFloat(Settings.current.sidebarExitTolerance)
        return p.x <= limit && p.x >= -max(1, overshootReach) && p.y >= -1 && p.y <= root.bounds.height + 1
    }

    private func mouseMoved(to p: NSPoint) {
        guard mode == .hidden, commandBar.isHidden else { return }
        // The cursor reached the left edge: slide the sidebar out over the page.
        if p.x <= CGFloat(Settings.current.sidebarHoverEdgeWidth), p.x >= -1, isBesideWindow(p) {
            setMode(.peeking)
        }
    }

    private func mouseLeftWindow() {
        // Flicking the cursor past the edge counts too, so the target is not a thin strip.
        if mode == .hidden, commandBar.isHidden, isOvershoot(cursor) { setMode(.peeking) }
    }

    /// While peeking, watch the cursor directly. Events stop arriving once it leaves the window,
    /// and a plain timer pauses during menus and drags, which is exactly when the sidebar should stay.
    private func startPeekWatch() {
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self, self.mode == .peeking else { return }
            if self.isInSidebarZone(self.cursor) || self.sidebar.wantsToStayOpen || self.commandBar.isAnchoredOpen
                || Extensions.shared.isPopupOpen {
                self.outsideSince = nil
                return
            }
            let since = self.outsideSince ?? Date()
            self.outsideSince = since
            if Date().timeIntervalSince(since) >= Settings.current.sidebarHideDelay {
                self.setMode(.hidden)
            }
        }
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) { AppDelegate.shared.windowFocused(self) }

    func windowWillClose(_ notification: Notification) {
        dismissPeek(refocus: false)
        commandBar.dismiss()
        sidebar.prepareForClose()
        peekTimer?.invalidate()
        toastTimer?.invalidate()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        NotificationCenter.default.removeObserver(self)
        card.show(nil)
        AppDelegate.shared.windowClosed(self)
    }

    private func setFullscreenLayout(_ fullscreen: Bool) {
        fullscreenLayout = fullscreen
        // A transient hover should not survive the window changing Spaces.
        if mode == .peeking { setMode(.hidden, animated: false) }
        applyMode(animated: false)
    }

    func windowWillEnterFullScreen(_ notification: Notification) { setFullscreenLayout(true) }
    func windowDidEnterFullScreen(_ notification: Notification) { setFullscreenLayout(true) }
    func windowDidExitFullScreen(_ notification: Notification) { setFullscreenLayout(false) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { setFullscreenLayout(false) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { setFullscreenLayout(true) }

    func windowDidResignKey(_ notification: Notification) {
        if !commandBar.isHidden { commandBar.dismiss() }
    }
}

extension MainWindowController {
    /// Layout regression checks only: native fullscreen transitions require an owner check.
    func debugFullscreenTest(log: (String) -> Void) {
        guard let window else { return }
        func check(_ name: String, _ passed: Bool) { log("fullscreen: \(name) expected=true got=\(passed)") }
        func settle() {
            root.layoutSubtreeIfNeeded()
            card.layoutSubtreeIfNeeded()
            sidebar.layoutSubtreeIfNeeded()
        }
        let note = Notification(name: NSWindow.didEnterFullScreenNotification, object: window)
        commandBar.dismiss()
        debugSetSidebar("hidden")
        settle()
        let savedChoice = store.sidebarCollapsed
        let normalFrame = card.frame
        let normalRadius = card.layer?.cornerRadius
        windowDidEnterFullScreen(note)
        settle()
        check("hidden page fills window", card.frame == root.bounds)
        check("hidden page has square corners", card.layer?.cornerRadius == 0 && card.panes.allSatisfy { $0.layer?.cornerRadius == 0 })
        check("sidebar choice preserved", mode == .hidden && store.sidebarCollapsed == savedChoice)
        check("native exit control available", window.standardWindowButton(.zoomButton).map { $0.alphaValue == 1 && $0.isEnabled } ?? false)
        let hiddenFrame = card.frame
        debugSetSidebar("peek")
        settle()
        check("hover overlays without resizing page", card.frame == hiddenFrame && sidebar.frame.minX == 8)
        debugSetSidebar("pinned")
        settle()
        check("pinned sidebar leaves page inset", card.frame.minX == CGFloat(store.sidebarWidth) && root.bounds.maxY - card.frame.maxY == 8)
        check("compact fullscreen header", sidebar.bounds.height - sidebar.addressAnchor.frame.maxY == 36)
        editAddress()
        check("address editor stays anchored", commandBar.isAnchoredOpen)
        commandBar.dismiss()
        debugSetSidebar("hidden")
        let a = store.newTab(url: "sorrel://welcome")
        let b = store.newTab(url: "sorrel://welcome")
        _ = store.makeSplit(a, with: b)
        settle()
        check("fullscreen split keeps pane frames", card.isSplit && card.frame == root.bounds && card.panes.allSatisfy { $0.layer?.cornerRadius == 8 && $0.bounds.width > 0 })
        store.unsplit(store.unit(a))
        settle()
        check("single page after split has square corners", !card.isSplit && card.panes.allSatisfy { $0.layer?.cornerRadius == 0 })
        windowDidFailToExitFullScreen(window)
        settle()
        check("failed exit retains fullscreen layout", card.frame == root.bounds)
        windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        settle()
        check("windowed layout restored", card.frame == normalFrame && card.layer?.cornerRadius == normalRadius)
        check("windowed hidden buttons restored", window.standardWindowButton(.zoomButton).map { $0.alphaValue == 0 && !$0.isEnabled } ?? false)
        debugSetSidebar("pinned")
        settle()
        check("windowed pinned buttons restored", window.standardWindowButton(.zoomButton).map { $0.alphaValue == 1 && $0.isEnabled } ?? false)
        windowWillEnterFullScreen(note)
        settle()
        check("enter preserves pinned sidebar", mode == .pinned && sidebar.bounds.height - sidebar.addressAnchor.frame.maxY == 36)
        windowDidFailToEnterFullScreen(window)
        settle()
        check("failed entry restores header", sidebar.bounds.height - sidebar.addressAnchor.frame.maxY == 44)
        debugCursor = nil
    }

    /// Test hook: a mouse-down in the middle of a split pane, through the same path as a real click.
    func debugClickPane(_ index: Int) {
        guard let window, card.panes.indices.contains(index) else { return }
        let pane = card.panes[index]
        let p = pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
        if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            focusPane(for: e)
        }
    }

    /// Import from Another Browser (ImportView.swift): a card over everything but the command bar.
    func showImporter() {
        if !commandBar.isHidden { commandBar.dismiss() }
        if let importer { window?.makeFirstResponder(importer); return }
        let o = ImportOverlay()
        o.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(o, positioned: .below, relativeTo: commandBar)
        NSLayoutConstraint.activate([
            o.topAnchor.constraint(equalTo: root.topAnchor), o.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            o.leadingAnchor.constraint(equalTo: root.leadingAnchor), o.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        o.onClosed = { [weak self] in
            self?.importer = nil
            if let wv = self?.currentWebView { self?.window?.makeFirstResponder(wv) }
        }
        importer = o
        root.layoutSubtreeIfNeeded()
        o.present()
    }

    /// A hidden sidebar slides out (as on hover) so something in it can be shown, like the Library.
    func peekSidebar() {
        if mode == .hidden { setMode(.peeking) }
    }

    /// Test hook: force a sidebar state without moving the mouse.
    func debugSetSidebar(_ name: String) {
        switch name {
        case "hidden": setMode(.hidden, animated: false)
        case "peek": setMode(.hidden, animated: false); setMode(.peeking, animated: false)
        default: setMode(.pinned, animated: false)
        }
    }
}
