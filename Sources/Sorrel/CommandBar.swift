import AppKit

private final class ResultRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

private final class ResultCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        for v in [icon, title, subtitle, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        hint.setContentHuggingPriority(.required, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            subtitle.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: hint.leadingAnchor, constant: -10),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The search, address and command box (new tab, edit address).
final class CommandBar: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// `newSplit`: whatever is chosen opens beside the current tab, in a split view.
    enum Mode { case newTab, editCurrent, newSplit }

    struct Result {
        /// What the row *is* (the search row, a URL, a tab, a command), so a row that only changes its
        /// text while typing is updated in place instead of being swapped for a new one.
        var key: String
        let icon: NSImage?
        let title: String
        let subtitle: String
        let hint: String
        let run: () -> Void
    }

    weak var controller: MainWindowController?
    private let shadowHost = NSView()
    private let panel = NSVisualEffectView()
    private let glyph = NSImageView()
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var tableHeight: NSLayoutConstraint!
    private var results: [Result] = []
    private var mode: Mode = .newTab
    private var rowHeight: CGFloat = 40
    private let maxRows = 8

    // The list's height follows its rows on a spring, one frame at a time, so every part of the bar
    // (blur, tint, border, shadow) moves together and a new keystroke mid-way just retargets it.
    private var listTarget: CGFloat = 0
    private var listVelocity: CGFloat = 0
    private var listLink: CADisplayLink?
    private var listLastTick: CFTimeInterval = 0

    /// Centered = the floating bar in the middle of the window (new tab).
    /// Anchored = editing in place, on top of the sidebar's address box.
    enum Placement { case centered, anchored }
    private(set) var placement: Placement = .centered
    private var centeredConstraints: [NSLayoutConstraint] = []
    private var anchoredConstraints: [NSLayoutConstraint] = []
    private var centeredTop: NSLayoutConstraint!
    private var anchoredLeading: NSLayoutConstraint!
    private var anchoredTop: NSLayoutConstraint!
    private var anchoredWidth: NSLayoutConstraint!
    private var fieldTop: NSLayoutConstraint!
    private var fieldLeading: NSLayoutConstraint!
    private var fieldTrailing: NSLayoutConstraint!
    private var scrollTop: NSLayoutConstraint!
    private var radius: CGFloat = 14

    // Search suggestions (only when switched on in Settings).
    private var suggestions: [String] = []
    private var suggestionsFor = ""
    private var suggestTask: URLSessionDataTask?
    private let suggestDelay = Debouncer(delay: 0.18)
    private let suggestSession = URLSession(configuration: .ephemeral)
    private let tint = NSBox()
    private weak var anchorView: NSView?

    /// True while the address is being edited in the sidebar, which must then stay on screen.
    var isAnchoredOpen: Bool { !isHidden && !isDismissing && placement == .anchored }

    /// Fading out after `dismiss()`: still drawn for a moment, but no longer open or clickable.
    private var isDismissing = false
    override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    private func build() {
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.35
        shadowHost.layer?.shadowRadius = 30
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -10)

        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 0.5
        panel.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor

        tint.boxType = .custom
        tint.borderWidth = 0
        tint.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(0.8)
        tint.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: panel.topAnchor),
            tint.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
        ])

        glyph.image = symbol("magnifyingglass", size: 16)
        glyph.contentTintColor = .secondaryLabelColor

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Search, enter an address, or type !bang"
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.refusesFirstResponder = true
        table.target = self
        table.action = #selector(rowClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false

        for v in [shadowHost, panel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [glyph, field, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(v)
        }
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 660)
        preferredWidth.priority = .defaultHigh

        // The bar's top edge is fixed (see positionCentered) so the text field never moves while
        // suggestions fill in below it; the list grows downward only.
        centeredTop = panel.topAnchor.constraint(equalTo: topAnchor, constant: 24)

        centeredConstraints = [
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            centeredTop,
            preferredWidth,
            panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -60),
        ]
        anchoredLeading = panel.leadingAnchor.constraint(equalTo: leadingAnchor)
        anchoredTop = panel.topAnchor.constraint(equalTo: topAnchor)
        anchoredWidth = panel.widthAnchor.constraint(equalToConstant: 440)
        anchoredWidth.priority = .defaultHigh
        anchoredConstraints = [
            anchoredLeading, anchoredTop, anchoredWidth,
            panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ]
        fieldTop = field.topAnchor.constraint(equalTo: panel.topAnchor, constant: 15)
        fieldLeading = field.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 48)
        fieldTrailing = field.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18)
        scrollTop = scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 13)

        NSLayoutConstraint.activate(centeredConstraints + [
            shadowHost.topAnchor.constraint(equalTo: panel.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            glyph.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            glyph.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 20),

            fieldTop, fieldLeading, fieldTrailing,

            scrollTop,
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            tableHeight,
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
        ])
    }

    override func layout() {
        super.layout()
        shadowHost.layer?.shadowPath = CGPath(roundedRect: shadowHost.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        positionCentered()
        positionOnAnchor()
    }

    /// Places the centered bar so its empty field row sits in the middle of the window, moved up only
    /// as far as needed for a full list to fit. It depends on the window's height alone, never on how
    /// many results are showing, so the line being typed on stays still.
    private func positionCentered() {
        guard placement == .centered else { return }
        let empty = fieldTop.constant + field.intrinsicContentSize.height + scrollTop.constant + 6
        let full = empty + CGFloat(maxRows) * rowHeight
        let top = max(24, min((bounds.height - empty) / 2, bounds.height - 24 - full))
        if abs(centeredTop.constant - top) > 0.5 { centeredTop.constant = top }
    }

    /// Keeps the in-place editor exactly on the address box, even if the sidebar is still sliding in.
    private func positionOnAnchor() {
        guard placement == .anchored, !isHidden, let anchor = anchorView, anchor.window != nil else { return }
        let r = anchor.convert(anchor.bounds, to: self)
        let top = bounds.height - r.maxY
        let width = max(r.width, 440)
        if abs(anchoredLeading.constant - r.minX) > 0.5 { anchoredLeading.constant = r.minX }
        if abs(anchoredTop.constant - top) > 0.5 { anchoredTop.constant = top }
        if abs(anchoredWidth.constant - width) > 0.5 { anchoredWidth.constant = width }
        let fieldTopWanted = max(4, (r.height - field.intrinsicContentSize.height) / 2)
        if abs(fieldTop.constant - fieldTopWanted) > 0.5 { fieldTop.constant = fieldTopWanted }
    }

    // MARK: Showing and hiding

    /// Switches between the centered bar and the compact one that sits on the sidebar's address box.
    private func apply(_ new: Placement, anchor: NSView?) {
        placement = new
        anchorView = new == .anchored ? anchor : nil
        // Over the address box the editor must fully cover what is underneath it.
        tint.fillColor = NSColor.windowBackgroundColor.withAlphaComponent(new == .anchored ? 0.97 : 0.8)
        NSLayoutConstraint.deactivate(centeredConstraints + anchoredConstraints)
        switch new {
        case .centered:
            radius = 14
            rowHeight = 40
            field.font = .systemFont(ofSize: 18)
            field.placeholderString = "Search, enter an address, or type !bang"
            glyph.isHidden = false
            fieldTop.constant = 15
            fieldLeading.constant = 48
            fieldTrailing.constant = -18
            scrollTop.constant = 13
            shadowHost.layer?.shadowRadius = 30
            positionCentered()
            NSLayoutConstraint.activate(centeredConstraints)
        case .anchored:
            radius = 9
            rowHeight = 34
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = "Search or enter address"
            glyph.isHidden = true
            fieldLeading.constant = 12
            fieldTrailing.constant = -12
            scrollTop.constant = 7
            shadowHost.layer?.shadowRadius = 16
            // Sit exactly on the address box: same corner, same row height, growing right and down.
            positionOnAnchor()
            NSLayoutConstraint.activate(anchoredConstraints)
        }
        panel.layer?.cornerRadius = radius
        table.rowHeight = rowHeight
        needsLayout = true
    }

    /// `anchor` is the sidebar's address box when editing in place; nil shows the centered bar.
    func present(_ mode: Mode, anchor: NSView? = nil) {
        self.mode = mode
        let arriving = isHidden || isDismissing
        if isDismissing {
            isDismissing = false
            layer?.removeAllAnimations()
            for v in [panel, shadowHost] as [NSView] { v.layer?.clearPopOut() }
        }
        alphaValue = 1
        isHidden = false
        layoutSubtreeIfNeeded()
        apply(anchor == nil ? .centered : .anchored, anchor: anchor)
        // Suggestions from the last time the bar was open don't carry over.
        suggestions = []
        suggestionsFor = ""
        if mode == .editCurrent, let u = controller?.store.selected?.url, !BundledPage.isBundled(u) {
            field.stringValue = u
        } else {
            field.stringValue = ""
        }
        (window as? SorrelWindow)?.focusHolder = field
        takeFocus()
        if mode == .newSplit { field.placeholderString = "Open beside this tab: search, address, or a tab" }
        refresh(animated: false)
        if arriving {
            layoutSubtreeIfNeeded()
            if placement == .centered {
                // The floating bar grows into place; the in-place editor just appears on its box.
                alphaValue = 0
                Motion.run(0.18) { animator().alphaValue = 1 }
                for v in [panel, shadowHost] as [NSView] { v.layer?.popIn(scale: 0.95, rise: -6, fade: false, duration: 0.3) }
            } else {
                alphaValue = 0
                Motion.run(0.1, Motion.glide) { animator().alphaValue = 1 }
            }
        }
        // Focus can be taken back in the same moment (a click finishing, a page loading), so check again.
        // The sidebar may also still be sliding into place, so re-align with the address box as it settles.
        for delay in [0.0, 0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isHidden else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.positionOnAnchor()
                if self.field.currentEditor() == nil { self.takeFocus(selectAll: false) }
            }
        }
    }

    private func takeFocus(selectAll: Bool = true) {
        guard let window else { return }
        if !window.isKeyWindow && !isQuietTest { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(field)
        if selectAll {
            field.currentEditor()?.selectAll(nil)
        } else {
            // Regaining focus mid-typing: keep what was typed and continue at the end.
            field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
        }
    }

    var hasKeyboardFocus: Bool { field.currentEditor() != nil }

    func dismiss() {
        guard !isHidden, !isDismissing else { return }
        isDismissing = true
        (window as? SorrelWindow)?.focusHolder = nil
        if let wv = controller?.currentWebView {
            window?.makeFirstResponder(wv)
        } else {
            window?.makeFirstResponder(nil)
        }
        if placement == .centered { for v in [panel, shadowHost] as [NSView] { v.layer?.popOut(scale: 0.97, duration: 0.13) } }
        Motion.run(placement == .centered ? 0.13 : 0.08, Motion.leave, { animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.isDismissing else { return }
            self.isDismissing = false
            self.stopListAnimation()
            self.isHidden = true
            self.alphaValue = 1
            for v in [self.panel, self.shadowHost] as [NSView] { v.layer?.clearPopOut() }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { dismiss() }
    }

    /// Test hook: what the bar is currently offering.
    var debugResultTitles: [String] { results.map { $0.subtitle.isEmpty ? $0.title : "\($0.title) [\($0.subtitle)]" } }

    /// Test hook: stands in for the search engine (no network); answers 0.15 s after the usual pause.
    var debugSuggest: ((String) -> [String])?
    /// Test hook: how many times the whole list was thrown away and rebuilt.
    private(set) var debugFullReloads = 0
    var debugPanelHeight: CGFloat { panel.frame.height }
    var debugFieldFrame: NSRect { field.convert(field.bounds, to: nil) }
    var debugShadowHeight: CGFloat { shadowHost.layer?.shadowPath?.boundingBox.height ?? 0 }

    /// Test hook: replace the text in a bar that is already open.
    func debugSetText(_ text: String) {
        field.stringValue = text
        refresh()
    }

    /// Test hook: open the bar with text already typed.
    func debugType(_ text: String) {
        present(.newTab)
        field.stringValue = text
        refresh(animated: false)
    }

    // MARK: Results

    private func go(_ url: URL) {
        let store = controller?.store ?? Store.shared
        if mode == .editCurrent, let item = store.selected {
            let page = Engine.shared.ensurePage(for: item)
            Engine.shared.load(url.absoluteString, in: page)
        } else if mode == .newSplit, let base = store.selected {
            let tab = store.newTab(url: url.absoluteString, after: base, select: false)
            if store.makeSplit(base, with: tab) == nil {
                store.select(tab)
                if let c = controller { c.showToast(c.splitRefusal(base, tab)) }
            }
        } else {
            store.newTab(url: url.absoluteString)
        }
    }

    /// Picking an open tab: switch to it, or in split mode, put it beside the current tab.
    private func pick(_ item: Item) {
        let store = controller?.store ?? Store.shared
        guard mode == .newSplit, let base = store.selected, base !== item else { store.select(item); return }
        controller?.splitSelected(with: item)
    }

    private func compute(_ raw: String) -> [Result] {
        let store = controller?.store ?? Store.shared
        let q = raw.trimmingCharacters(in: .whitespaces)
        var out: [Result] = []

        if q.isEmpty {
            let recent = store.cycleOrder.filter { $0 !== store.selected }
                .sorted { $0.lastActive > $1.lastActive }.prefix(6)
            for t in recent {
                out.append(Result(key: "tab:\(t.id)", icon: FaviconStore.shared.image(for: t) ?? symbol("globe"),
                                  title: t.displayTitle, subtitle: t.host ?? "",
                                  hint: self.mode == .newSplit ? "Open Beside" : "Switch to Tab") { [weak self] in
                    self?.pick(t)
                })
            }
            return out
        }

        let engine = Settings.current.searchEngineName
        let search = Result(key: "search", icon: symbol("magnifyingglass"), title: q, subtitle: "Search \(engine)", hint: "") { [weak self] in
            self?.go(Resolver.searchURL(q))
        }
        var seen: Set<String> = []

        if let m = Bangs.shared.resolve(q) {
            let title = m.query.isEmpty ? "Open \(m.bang.name)" : "Search \(m.bang.name) for “\(m.query)”"
            out.append(Result(key: "bang", icon: symbol("bolt.fill"), title: title, subtitle: m.url.host ?? "",
                              hint: "!\(m.bang.trigger)") { [weak self] in self?.go(m.url) })
        } else if let u = Resolver.url(fromTyped: q) {
            out.append(Result(key: "address", icon: symbol("globe"), title: q, subtitle: "Open address", hint: "") { [weak self] in self?.go(u) })
            seen.insert(u.absoluteString)
            out.append(search)
        } else {
            if let top = History.shared.topHostMatch(q), let u = URL(string: top.url) {
                out.append(Result(key: "url:\(top.url)", icon: FaviconStore.shared.image(forHost: u.host) ?? symbol("globe"),
                                  title: top.title.nonEmpty ?? top.url, subtitle: u.host ?? "", hint: "") { [weak self] in
                    self?.go(u)
                })
                seen.insert(top.url)
            }
            out.append(search)
            for s in shownSuggestions(for: q).prefix(4) where s.lowercased() != q.lowercased() {
                    out.append(Result(key: "suggest:\(s.lowercased())", icon: symbol("magnifyingglass"), title: s, subtitle: "Suggestion", hint: "") { [weak self] in
                        self?.go(Resolver.searchURL(s))
                    })
            }
        }

        let words = q.lowercased().split(separator: " ").map(String.init)
        func matches(_ strings: [String]) -> Bool {
            let hay = strings.joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }

        // Tabs that are already open, in any space.
        for (item, space) in store.allTabs.filter({ matches([$0.item.displayTitle, $0.item.url ?? ""]) }).prefix(4) {
            if item === store.selected { continue }
            let place = space.map { "\($0.icon) \($0.name)" } ?? "Favorites"
            out.append(Result(key: "tab:\(item.id)", icon: FaviconStore.shared.image(for: item) ?? symbol("globe"),
                              title: item.displayTitle, subtitle: place,
                              hint: mode == .newSplit ? "Open Beside" : "Switch to Tab") { [weak self] in
                self?.pick(item)
            })
            if let u = item.url { seen.insert(u) }
        }

        for e in History.shared.search(q, limit: 6) where !seen.contains(e.url) {
            guard let u = URL(string: e.url) else { continue }
            out.append(Result(key: "url:\(e.url)", icon: FaviconStore.shared.image(forHost: u.host) ?? symbol("clock"),
                              title: e.title.nonEmpty ?? e.url, subtitle: u.host ?? "", hint: "") { [weak self] in
                self?.go(u)
            })
            if out.count >= 9 { break }
        }

        for c in Commands.shared.all.filter({ matches([$0.title]) }).prefix(4) {
            out.append(Result(key: "cmd:\(c.id)", icon: symbol("command"), title: c.title, subtitle: "Command",
                              hint: Keybindings.shared.display(for: c.id) ?? "") {
                Commands.shared.run(c.id)
            })
        }
        // Keys must be unique for rows to be matched up between keystrokes.
        var used: Set<String> = []
        for i in out.indices {
            var k = out[i].key, n = 1
            while used.contains(k) { n += 1; k = "\(out[i].key)#\(n)" }
            used.insert(k)
            out[i].key = k
        }
        return Array(out.prefix(11))
    }

    /// The engine's suggestions for `q`. While the answer for the newest letter is on its way, the
    /// previous ones that still fit what is typed stay up, so the rows don't blink out and back in.
    private func shownSuggestions(for q: String) -> [String] {
        if suggestionsFor == q { return suggestions }
        guard q.count >= 2, !suggestionsFor.isEmpty else { return [] }
        let lower = q.lowercased()
        return suggestions.filter { $0.lowercased().hasPrefix(lower) }
    }

    /// Asks the search engine for suggestions, a moment after typing pauses.
    private func requestSuggestions(for raw: String) {
        suggestTask?.cancel()
        let q = raw.trimmingCharacters(in: .whitespaces)
        guard Settings.current.searchSuggestions || debugSuggest != nil, q.count >= 2, !isHidden,
              Bangs.shared.resolve(q) == nil, Resolver.url(fromTyped: q) == nil else { return }
        suggestDelay.schedule { [weak self] in
            guard let self, !self.isHidden else { return }
            if let fake = self.debugSuggest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.deliverSuggestions(fake(q), for: q) }
                return
            }
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
            let host = URL(string: Settings.current.searchEngineURL.replacingOccurrences(of: "%s", with: "x"))?.host ?? ""
            let address: String
            if host.contains("google") {
                address = "https://suggestqueries.google.com/complete/search?client=firefox&q=\(encoded)"
            } else if host.contains("brave") {
                address = "https://search.brave.com/api/suggest?q=\(encoded)"
            } else {
                address = "https://duckduckgo.com/ac/?type=list&q=\(encoded)"
            }
            guard let url = URL(string: address) else { return }
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.httpShouldHandleCookies = false
            let task = self.suggestSession.dataTask(with: request) { [weak self] data, _, _ in
                // Every supported engine answers with ["query", ["suggestion", ...]].
                guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                      json.count > 1, let list = json[1] as? [String] else { return }
                DispatchQueue.main.async { self?.deliverSuggestions(list, for: q) }
            }
            self.suggestTask = task
            task.resume()
        }
    }

    private func deliverSuggestions(_ list: [String], for q: String) {
        guard !isHidden, field.stringValue.trimmingCharacters(in: .whitespaces) == q else { return }
        suggestions = list
        suggestionsFor = q
        // If the person had arrowed down to a row, stay on that row as suggestions settle in around it.
        let sel = table.selectedRow
        let keep = sel > 0 && sel < results.count ? results[sel].key : nil
        refresh(fetch: false)
        if let keep, let i = results.firstIndex(where: { $0.key == keep }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
    }

    /// `animated` off (opening the bar) shows the list at once; while typing, rows that stay are
    /// updated in place, new ones fade in, gone ones fade out, and the list's height glides.
    private func refresh(animated: Bool = true, fetch: Bool = true) {
        if fetch { requestSuggestions(for: field.stringValue) }
        let new = compute(field.stringValue)
        let moving = animated && !Motion.reduced && window != nil && !isDismissing
        if moving {
            let diff = new.map(\.key).difference(from: results.map(\.key))
            results = new
            var removed: [Int] = [], inserted: [Int] = []
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removed.append(offset)
                case .insert(let offset, _, _): inserted.append(offset)
                }
            }
            // Removals go bottom-up against the old list, then insertions top-down against the new one.
            removed.sort(by: >)
            inserted.sort()
            if !removed.isEmpty || !inserted.isEmpty {
                table.beginUpdates()
                for i in removed { table.removeRows(at: [i], withAnimation: .effectFade) }
                for i in inserted { table.insertRows(at: [i], withAnimation: .effectFade) }
                table.endUpdates()
            }
            // Rows that stayed keep their views; just bring their text and icon up to date.
            let fresh = Set(inserted)
            for row in results.indices where !fresh.contains(row) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell {
                    configure(cell, with: results[row])
                }
            }
        } else {
            results = new
            debugFullReloads += 1
            table.reloadData()
        }
        setListHeight(CGFloat(min(results.count, maxRows)) * rowHeight, animated: moving)
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    /// Moves the list toward `height`: at once, or on a critically damped spring driven by the display,
    /// re-laying out the bar each frame. Only the list below the field changes; the bar's top is fixed.
    private func setListHeight(_ height: CGFloat, animated: Bool) {
        listTarget = height
        guard animated else {
            stopListAnimation()
            if tableHeight.constant != height {
                tableHeight.constant = height
                layoutSubtreeIfNeeded()
            }
            return
        }
        if abs(tableHeight.constant - height) < 0.5, abs(listVelocity) < 1 { return }
        if listLink == nil {
            let link = displayLink(target: self, selector: #selector(stepListHeight(_:)))
            link.add(to: .main, forMode: .common)
            listLink = link
            listLastTick = 0
        }
    }

    @objc private func stepListHeight(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = listLastTick == 0 ? 1.0 / 60 : min(1.0 / 30, max(0, now - listLastTick))
        listLastTick = now
        // Critically damped: no bounce, and about a quarter of a second to settle.
        let omega: CGFloat = 2 * .pi / 0.28
        var x = tableHeight.constant, v = listVelocity
        let steps = 4, h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            let a = -omega * omega * (x - listTarget) - 2 * omega * v
            v += a * h
            x += v * h
        }
        if abs(x - listTarget) < 0.3, abs(v) < 6 {
            x = listTarget
            stopListAnimation()
        } else {
            listVelocity = v
        }
        tableHeight.constant = x
        layoutSubtreeIfNeeded()
    }

    private func stopListAnimation() {
        listLink?.invalidate()
        listLink = nil
        listVelocity = 0
    }

    private func runSelected() {
        let row = table.selectedRow
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if row >= 0, row < results.count {
            let r = results[row]
            dismiss()
            r.run()
        } else if !text.isEmpty {
            dismiss()
            go(Resolver.destination(for: text))
        } else {
            dismiss()
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let next = max(0, min(results.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowClicked() {
        if table.clickedRow >= 0 {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
            runSelected()
        }
    }

    // MARK: Text field

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ResultRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ResultCell) ?? {
            let c = ResultCell()
            c.identifier = id
            return c
        }()
        configure(cell, with: results[row])
        return cell
    }

    private func configure(_ cell: ResultCell, with r: Result) {
        if cell.icon.image !== r.icon { cell.icon.image = r.icon }
        if cell.title.stringValue != r.title { cell.title.stringValue = r.title }
        if cell.subtitle.stringValue != r.subtitle { cell.subtitle.stringValue = r.subtitle }
        if cell.hint.stringValue != r.hint { cell.hint.stringValue = r.hint }
    }
}
