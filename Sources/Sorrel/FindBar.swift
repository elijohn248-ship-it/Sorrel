import AppKit
import WebKit

/// Find on page: a floating bar along the bottom of the focused page or pane (⌘F). It slides up from the page's
/// bottom edge, searches case-insensitively with WebKit's own find, and shows "3 of 12" from a fixed, read-only
/// script in an isolated content world (the query is passed as an argument, never pasted into the source).
/// It keeps nothing on disk: the last query lives only in this bar until the window closes.
final class FindBar: NSView, NSTextFieldDelegate {
    /// The page being searched.
    private(set) weak var webView: WKWebView?
    /// True from `open` until `close`, independent of the slide animation.
    private(set) var isOpen = false
    /// The space's colour, washed very faintly over the bar's material.
    var tint: NSColor? { didSet { refreshColors() } }

    private let material = NSVisualEffectView()
    private let wash = NSView()
    private let well = NSView()
    private let glass = NSImageView()
    let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private var prev: IconButton!
    private var next: IconButton!
    private let done = NSButton(title: "Done", target: nil, action: nil)
    private var urlObservation: NSKeyValueObservation?
    private var pageKey: String?
    private var generation = 0
    private let typing = Debouncer(delay: 0.12)
    /// The query the bar last searched for, so Return after typing shows the first match instead of skipping it.
    private var searched: String?

    static let height: CGFloat = 36
    static let bottomInset: CGFloat = 12
    static let maxWidth: CGFloat = 460

    /// Last result, for tests and the buttons.
    private(set) var total = 0
    private(set) var index = 0
    private(set) var found = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 12
            s.shadowOffset = NSSize(width: 0, height: -2)
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return s
        }()

        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 11
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5
        wash.wantsLayer = true
        well.wantsLayer = true
        well.layer?.cornerRadius = 7

        glass.image = symbol("magnifyingglass", size: 11)
        glass.contentTintColor = .secondaryLabelColor
        field.placeholderString = "Find on page"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Find on page")
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byClipping
        prev = IconButton(symbol: "chevron.up", size: 11, tooltip: "Previous match (⇧⌘G)") { [weak self] in
            self?.findAgain(backwards: true)
        }
        next = IconButton(symbol: "chevron.down", size: 11, tooltip: "Next match (⌘G)") { [weak self] in
            self?.findAgain(backwards: false)
        }
        done.isBordered = false
        done.font = .systemFont(ofSize: 12, weight: .medium)
        done.target = self
        done.action = #selector(doneClicked)
        done.toolTip = "Close (Esc)"

        for v in [material, wash, well, glass, field, status, prev!, next!, done] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(material)
        material.addSubview(wash)
        for v in [well, glass, field, status, prev!, next!, done] as [NSView] { material.addSubview(v) }
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            wash.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            wash.topAnchor.constraint(equalTo: material.topAnchor),
            wash.bottomAnchor.constraint(equalTo: material.bottomAnchor),

            well.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 6),
            well.topAnchor.constraint(equalTo: material.topAnchor, constant: 5),
            well.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -5),
            well.trailingAnchor.constraint(equalTo: prev.leadingAnchor, constant: -4),
            glass.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8),
            glass.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 5),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -6),
            status.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            status.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),

            prev.trailingAnchor.constraint(equalTo: next.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -4),
            done.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -10),
            prev.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            next.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            done.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            prev.widthAnchor.constraint(equalToConstant: 26),
            next.widthAnchor.constraint(equalToConstant: 26),
            prev.heightAnchor.constraint(equalToConstant: 24),
            next.heightAnchor.constraint(equalToConstant: 24),
        ])
        status.setContentHuggingPriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        done.setContentHuggingPriority(.required, for: .horizontal)
        setButtonsEnabled(false)
        refreshColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Pins the bar to the bottom centre of `container` (the focused pane's area, or a mini window's page).
    func install(in container: NSView) {
        container.addSubview(self)
        let fill = widthAnchor.constraint(equalTo: container.widthAnchor, constant: -24)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.bottomInset),
            heightAnchor.constraint(equalToConstant: Self.height),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -16),
            fill,
        ])
    }

    // MARK: Look

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = isDarkAppearance
            material.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.16 : 0.12).cgColor
            let t = tint ?? .controlAccentColor
            wash.layer?.backgroundColor = t.withAlphaComponent(dark ? 0.13 : 0.08).cgColor
            well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(dark ? 0.09 : 0.06).cgColor
            done.contentTintColor = (t.usingColorSpace(.sRGB).map { c -> NSColor in
                // Keep the space's colour readable on the bar.
                if dark { return c.luminance < 0.45 ? (c.blended(withFraction: 0.45, of: .white) ?? c) : c }
                return c.luminance > 0.6 ? (c.blended(withFraction: 0.4, of: .black) ?? c) : c
            }) ?? .controlAccentColor
        }
    }

    private func setButtonsEnabled(_ on: Bool) {
        prev.isEnabled = on
        next.isEnabled = on
        prev.alphaValue = on ? 1 : 0.4
        next.alphaValue = on ? 1 : 0.4
    }

    // MARK: Open, follow, close

    /// True while the search field (or its field editor) has keyboard focus.
    var hasFocus: Bool {
        guard let r = window?.firstResponder else { return false }
        if r === field { return true }
        return (r as? NSTextView)?.delegate === field
    }

    /// Shows the bar for `webView` and puts the cursor in the field with its text selected. Opening an already
    /// open bar (⌘F again) just selects the text again.
    func open(for webView: WKWebView) {
        if isOpen, self.webView === webView {
            focusField()
            return
        }
        attach(to: webView)
        let wasOpen = isOpen
        isOpen = true
        if !wasOpen { slideIn() }
        focusField()
        if !field.stringValue.isEmpty { search(fresh: true) } else { show(nil) }
    }

    /// The focused split pane changed: the open bar moves to it and searches it, without taking focus.
    func follow(_ webView: WKWebView) {
        guard isOpen, self.webView !== webView else { return }
        attach(to: webView)
        layer?.popIn(scale: 0.98, rise: 6, duration: 0.22)
        if !field.stringValue.isEmpty { search(fresh: true) } else { show(nil) }
    }

    /// Hides the bar. `refocus` gives the keyboard back to the page if the bar had it; otherwise focus is
    /// simply let go so the caller can place it (a tab change focuses the new page).
    func close(refocus: Bool = true) {
        guard isOpen else { return }
        let hadFocus = hasFocus
        isOpen = false
        generation += 1
        typing.flush()
        urlObservation = nil
        if hadFocus {
            if refocus, let wv = webView, wv.window === window { window?.makeFirstResponder(wv) }
            else { window?.makeFirstResponder(nil) }
        }
        slideOut()
    }

    private func attach(to webView: WKWebView) {
        self.webView = webView
        pageKey = Self.key(webView.url)
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            // Any navigation to another address closes the bar; a jump within the page (#section) does not.
            DispatchQueue.main.async {
                guard let self, self.isOpen, self.webView === wv, Self.key(wv.url) != self.pageKey else { return }
                self.close()
            }
        }
    }

    private static func key(_ url: URL?) -> String? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        return c.string
    }

    private func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func slideIn() {
        layer?.removeAnimation(forKey: "findSlideOut")
        superview?.layoutSubtreeIfNeeded()
        fade(in: true, duration: 0.22)
        layer?.popIn(scale: 1, rise: Self.height + Self.bottomInset, fade: false, duration: 0.22)
    }

    private func slideOut() {
        fade(in: false, duration: 0.14)
        guard !Motion.reduced, let layer else { return }
        layer.removeAnimation(forKey: "popIn")
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = CATransform3DIdentity
        a.toValue = CATransform3DMakeTranslation(0, -(Self.height + Self.bottomInset), 0)
        a.duration = 0.14
        a.timingFunction = Motion.leave
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        layer.add(a, forKey: "findSlideOut")
    }

    @objc private func doneClicked() { close() }

    // MARK: Searching

    /// ⌘G / ⇧⌘G and the arrow buttons.
    func findAgain(backwards: Bool) {
        guard isOpen, !field.stringValue.isEmpty else { return }
        typing.flush()
        search(fresh: false, backwards: backwards)
    }

    func controlTextDidChange(_ obj: Notification) {
        typing.schedule { [weak self] in self?.search(fresh: true) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if field.stringValue != searched { typing.flush(); search(fresh: true) }   // just typed: first match
            else { findAgain(backwards: shift) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    /// The isolated world the bar's two fixed scripts run in: the page can't see or change them.
    private static let world = WKContentWorld.world(name: "birch-find")

    /// `fresh`: the query changed, so search from the start of the current match (or the page's selection)
    /// rather than past it, keeping "app" -> "apple" on the same spot while typing.
    private func search(fresh: Bool, backwards: Bool = false) {
        generation += 1
        let gen = generation
        let query = field.stringValue
        guard let wv = webView, isOpen else { return }
        searched = query
        guard !query.isEmpty else { show(nil); return }
        let go = { [weak self, weak wv] in
            guard let self, let wv, gen == self.generation else { return }
            let cfg = WKFindConfiguration()
            cfg.backwards = backwards
            cfg.wraps = true
            cfg.caseSensitive = false
            wv.find(query, configuration: cfg) { [weak self, weak wv] result in
                guard let self, let wv, gen == self.generation else { return }
                guard result.matchFound else { self.show((0, 0, false)); return }
                self.count(query, in: wv, gen: gen)
            }
        }
        if fresh {
            wv.callAsyncJavaScript(Self.collapseScript, arguments: [:], in: nil, in: Self.world) { _ in go() }
        } else {
            go()
        }
    }

    private func count(_ query: String, in wv: WKWebView, gen: Int) {
        wv.callAsyncJavaScript(Self.countScript, arguments: ["query": query, "limit": 1000],
                               in: nil, in: Self.world) { [weak self] result in
            guard let self, gen == self.generation else { return }
            let values = (try? result.get()) as? [Any] ?? []
            let n = (values.first as? NSNumber)?.intValue ?? 0
            let i = (values.count > 1 ? values[1] as? NSNumber : nil)?.intValue ?? 0
            self.show((n, i, true))
        }
    }

    /// nil = no query. Otherwise (total, current index, whether WebKit found a match).
    private func show(_ r: (total: Int, index: Int, found: Bool)?) {
        total = r?.total ?? 0
        index = r?.index ?? 0
        found = r?.found ?? false
        status.stringValue = statusText
        status.textColor = r != nil && !found ? NSColor.systemRed.withAlphaComponent(0.85) : .secondaryLabelColor
        setButtonsEnabled(found)
    }

    var statusText: String {
        if field.stringValue.isEmpty { return "" }
        if !found { return "No matches" }
        let cap = total >= 1000 ? "1000+" : "\(total)"
        if total > 0, index > 0 { return "\(min(index, total)) of \(cap)" }
        if total > 0 { return total == 1 ? "1 match" : "\(cap) matches" }
        return "Found"   // a match WebKit sees that the count can't (inside a frame, say)
    }

    /// Starts the next search at the beginning of the current selection. Fixed source, no arguments.
    private static let collapseScript = """
        const s = window.getSelection();
        if (s && s.rangeCount > 0 && !s.isCollapsed) s.collapseToStart();
        return true;
        """

    /// Counts the case-insensitive matches of `query` in the page's visible text and works out which one is
    /// selected (WebKit's find selects the match it lands on). Read-only; `query` and `limit` are arguments.
    /// Returns [total, index] where index is 1-based, 0 if the selection isn't on a match.
    private static let countScript = """
        const norm = (t) => String(t).replace(/\\s+/g, " ").toLowerCase();
        const needle = norm(query);
        if (!needle || needle === " ") return [0, 0];
        const root = document.body || document.documentElement;
        if (!root) return [0, 0];
        const skipTags = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "TITLE", "TEXTAREA", "OPTION"]);
        const shown = new Map();
        const visible = (el) => {
            if (shown.has(el)) return shown.get(el);
            let v = !skipTags.has(el.tagName);
            if (v) v = el.checkVisibility ? el.checkVisibility({ visibilityProperty: true }) : el.getClientRects().length > 0;
            shown.set(el, v);
            return v;
        };
        const blocks = new Map();
        const blockOf = (el) => {
            const start = el;
            while (el && el !== root) {
                if (blocks.has(el)) { const b = blocks.get(el); blocks.set(start, b); return b; }
                const d = getComputedStyle(el).display;
                if (!d.startsWith("inline") && d !== "contents") break;
                el = el.parentElement;
            }
            blocks.set(start, el);
            return el;
        };
        const sel = window.getSelection();
        const range = sel && sel.rangeCount > 0 ? sel.getRangeAt(0) : null;
        let text = "";
        let selPos = -1;
        let lastBlock = null;
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
            const parent = node.parentElement;
            if (!parent || !node.data || !visible(parent)) continue;
            const block = blockOf(parent);
            if (block !== lastBlock && text.length > 0 && !text.endsWith("\\n")) text += "\\n";
            lastBlock = block;
            let piece = norm(node.data);
            if (piece.startsWith(" ") && (text.length === 0 || text.endsWith(" ") || text.endsWith("\\n"))) piece = piece.slice(1);
            if (range && selPos < 0) {
                if (node === range.startContainer) {
                    let before = norm(node.data.slice(0, range.startOffset));
                    if (before.startsWith(" ") && piece.length < norm(node.data).length) before = before.slice(1);
                    selPos = text.length + before.length;
                } else {
                    try { if (range.comparePoint(node, 0) >= 0) selPos = text.length; } catch (e) {}
                }
            }
            text += piece;
            if (text.length > 8000000) break;
        }
        let total = 0, index = 0, at = text.indexOf(needle);
        while (at >= 0 && total < limit) {
            total += 1;
            if (selPos >= 0 && at <= selPos) index = (at === selPos || at + needle.length > selPos) ? total : index;
            at = text.indexOf(needle, at + needle.length);
        }
        return [total, index];
        """

    // MARK: Tests

    /// Puts `text` in the field as if typed and searches at once (no typing delay).
    func debugType(_ text: String) {
        field.stringValue = text
        typing.flush()
        search(fresh: true)
    }
}

/// Holds the find bar over the focused pane and clips it to that pane's rounded frame. Clicks anywhere but
/// on the bar fall through to the page.
final class FindClipView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - SORREL_FINDTEST

extension MainWindowController {
    /// Drives the find bar through its real commands, key events and layout on local pages with known words.
    /// Logs `find:` expected/got booleans and writes `find.png` (window picture with WebKit's own picture of
    /// the page drawn into the pane, since the sandbox leaves window snapshots of pages blank).
    /// Can't show: the slide's feel, vibrancy on real sites, or a real keyboard.
    func debugFindTest(shot: URL, log: @escaping (String) -> Void) {
        let bar = card.findBar
        func check(_ name: String, _ passed: Bool) {
            log("find: \(name) expected=true got=\(passed)" + (passed ? "" : " [status=\(bar.statusText) open=\(bar.isOpen) panes=\(card.panes.count) barOnA=\(bar.webView === card.panes.first?.webView)]"))
        }
        let st = store
        func fixture(_ words: [String]) -> String {
            "<html><body style='font: 16px -apple-system; margin: 24px'>" + words.map { "<p>\($0)</p>" }.joined()
                + "<div style='display:none'>apple hidden</div><script>var hidden = 'apple';</script></body></html>"
        }
        let pageA = fixture(["apple one", "Apple two", "APPLE three", "an ap<b>ple</b> split across tags", "pineapple"])
        let pageB = fixture(["apple pie", "banana", "apple crumble"])
        let a = st.newTab(url: "https://find-a.test/", title: "Find A")
        let b = st.newTab(url: "https://find-b.test/", title: "Find B", select: false)
        let c = st.newTab(url: "https://find-c.test/", title: "Find C", select: false)
        let webA = Engine.shared.ensurePage(for: a).webView
        let webB = Engine.shared.ensurePage(for: b).webView
        let webC = Engine.shared.ensurePage(for: c).webView
        webA.loadHTMLString(pageA, baseURL: URL(string: "https://find-a.test/"))
        webB.loadHTMLString(pageB, baseURL: URL(string: "https://find-b.test/"))
        webC.loadHTMLString(fixture(["nothing here"]), baseURL: URL(string: "https://find-c.test/"))
        st.select(a)

        func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], posted: Bool = false) {
            guard let w = window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                        windowNumber: w.windowNumber, context: nil, characters: chars,
                                                        charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { return }
            // Through the app's key monitor, as a real key press goes. `posted` goes through the run loop, so the
            // event becomes NSApp.currentEvent (Shift-Return reads its modifiers from there).
            if posted { NSApp.postEvent(e, atStart: false) } else { NSApp.sendEvent(e) }
        }
        func atBottom(of pane: NSView) -> Bool {
            card.layoutSubtreeIfNeeded()
            let f = bar.convert(bar.bounds, to: card), p = pane.frame
            return abs(f.minY - p.minY - FindBar.bottomInset) < 1 && abs(f.midX - p.midX) < 1
                && f.width <= FindBar.maxWidth && f.height == FindBar.height && f.maxY < p.midY
        }
        func paneOf(_ wv: WKWebView) -> NSView? { card.panes.first { $0.webView === wv } }

        var steps: [(TimeInterval, () -> Void)] = []
        func step(_ wait: TimeInterval, _ body: @escaping () -> Void) { steps.append((wait, body)) }
        func run(_ i: Int) {
            guard i < steps.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + steps[i].0) { steps[i].1(); run(i + 1) }
        }

        step(2.5) {
            check("closed at start", !bar.isOpen && bar.isHidden)
            key(3, "f", .command)   // ⌘F
            check("cmd-f opens", bar.isOpen && !bar.isHidden && bar.webView === webA)
            check("field focused", bar.hasFocus)
            check("bottom of page", paneOf(webA).map(atBottom) ?? false)
            bar.debugType("apple")
        }
        step(0.8) { check("count first", bar.statusText == "1 of 5") ; key(5, "g", .command) }
        step(0.5) { check("cmd-g next", bar.statusText == "2 of 5"); key(36, "\r") }
        step(0.5) { check("return next", bar.statusText == "3 of 5"); key(5, "g", .command) }
        step(0.5) { key(5, "g", .command) }
        step(0.5) { check("last", bar.statusText == "5 of 5"); key(5, "g", .command) }
        step(0.5) { check("next wraps", bar.statusText == "1 of 5"); key(5, "g", [.command, .shift]) }
        step(0.5) { check("previous wraps", bar.statusText == "5 of 5"); key(36, "\r", .shift, posted: true) }
        step(0.5) { check("shift-return previous", bar.statusText == "4 of 5"); bar.debugType("zebra") }
        step(0.6) { check("no matches", bar.statusText == "No matches" && !bar.found); bar.debugType("a\"b\\`${x}');</script>") }
        step(0.6) { check("quoted query is data", bar.statusText == "No matches"); bar.debugType("APPLE") }
        step(0.6) { check("case-insensitive", bar.statusText == "1 of 5"); key(53, "\u{1b}") }
        step(0.4) {
            check("esc closes", !bar.isOpen)
            check("esc returns focus to page", self.window?.firstResponder === webA)
            key(3, "f", .command)
            check("reopens with query", bar.isOpen && bar.field.stringValue == "APPLE")
            if let ed = bar.field.currentEditor() as? NSTextView { ed.setSelectedRange(NSRange(location: 5, length: 0)) }
            key(3, "f", .command)
            let sel = (bar.field.currentEditor() as? NSTextView)?.selectedRange()
            check("cmd-f reselects text", bar.hasFocus && sel == NSRange(location: 0, length: 5))
        }
        step(0.8) {
            check("reopened count", bar.statusText.hasSuffix("of 5"))
            check("slid into place", bar.alphaValue == 1 && bar.layer?.animation(forKey: "findSlideOut") == nil)
            // Picture: the window, with WebKit's own picture of the page under the bar.
            webA.takeSnapshot(with: nil) { image, _ in
                guard let root = self.window?.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
                root.cacheDisplay(in: root.bounds, to: rep)
                let out = NSImage(size: root.bounds.size)
                out.lockFocus()
                rep.draw(in: root.bounds)
                if let image, let pane = paneOf(webA) { image.draw(in: pane.convert(pane.bounds, to: root)) }
                let barRect = bar.convert(bar.bounds, to: root)
                if let barRep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                    bar.cacheDisplay(in: bar.bounds, to: barRep)
                    barRep.draw(in: barRect)
                }
                out.unlockFocus()
                if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: shot)
                    log("find: wrote find.png")
                }
            }
        }
        step(0.6) {
            self.debugSetSidebar("hidden")
            self.root.layoutSubtreeIfNeeded()
            check("bottom with sidebar hidden", paneOf(webA).map(atBottom) ?? false)
            self.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: self.window))
            self.root.layoutSubtreeIfNeeded()
            check("bottom in fullscreen", bar.isOpen && (paneOf(webA).map(atBottom) ?? false))
            self.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: self.window))
            self.debugSetSidebar("pinned")
            self.root.layoutSubtreeIfNeeded()
            check("bottom after fullscreen", paneOf(webA).map(atBottom) ?? false)
            // Making a split focuses the tab that joined it; the open bar goes with the focus.
            self.splitSelected(with: b)
            check("follows into new split pane", bar.isOpen && bar.webView === webB && self.card.panes.count == 2)
            check("bottom of right pane", paneOf(webB).map(atBottom) ?? false)
        }
        step(0.8) {
            check("searches followed pane", bar.statusText == "1 of 2")
            st.focusPane(offset: -1)
            check("follows focused pane", bar.isOpen && bar.webView === webA && self.card.webView === webA)
            check("bottom of left pane", paneOf(webA).map(atBottom) ?? false)
            check("typing focus kept", bar.hasFocus)
        }
        step(0.8) {
            check("searches left pane", bar.statusText.hasSuffix("of 5"))
            webA.loadHTMLString(pageA + "<!-- reloaded -->", baseURL: URL(string: "https://find-a.test/next"))
        }
        step(1.0) {
            check("navigation closes", !bar.isOpen)
            Commands.shared.run("find.show")
            check("reopens on split pane", bar.isOpen && bar.webView === webA)
            st.select(c)
            check("tab switch closes", !bar.isOpen && self.card.webView === webC)
            check("new tab has focus", self.window?.firstResponder === webC)
            Commands.shared.run("find.next")
            check("cmd-g reopens last query", bar.isOpen && bar.webView === webC && bar.field.stringValue == "APPLE")
        }
        step(0.6) {
            check("other page no matches", bar.statusText == "No matches")
            bar.close()
            let mini = MiniWindowController.present(url: nil, isPrivate: true)
            mini.page.webView.loadHTMLString(pageA, baseURL: URL(string: "https://find-private.test/"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let mb = mini.findBar
                mb.open(for: mini.page.webView)
                mb.debugType("apple")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    check("private window count", mb.statusText == "1 of 5")
                    check("private store kept", !mini.page.webView.configuration.websiteDataStore.isPersistent)
                    if let host = mb.superview {
                        host.layoutSubtreeIfNeeded()
                        check("private bottom", abs(mb.frame.minY - FindBar.bottomInset) < 1 && abs(mb.frame.midX - host.bounds.midX) < 1)
                    }
                    mini.close()
                    check("private closed", !mb.isOpen)
                }
            }
        }
        run(0)
    }
}
