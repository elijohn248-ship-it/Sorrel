import AppKit

// "Import from Another Browser": a card in the middle of the window, washed in the current space's colours.
// Four steps, each sliding in from the side it logically comes from:
//   pick     a tile per browser on this Mac (Arc always), plus an exported bookmarks file
//   access   why the Open panel is coming, then the panel (sandbox: Sorrel may only read what it is handed)
//   choose   what was found (Arc's spaces as coloured chips) and switches for what to bring
//   done     a ring draws itself, the results rise in one by one, the wash takes the new space's colours
// The chosen browser's icon flies from its tile into the header and stays there for the rest of the flow.

final class ImportOverlay: NSView {
    var onClosed: (() -> Void)?

    private let scrim = NSView()
    private let shadowHost = NSView()
    private let panel = NSVisualEffectView()
    private let wash = ThemeBackgroundView()
    private let tint = NSView()
    private let stage = FlippedContainer()
    private var stageHeight: NSLayoutConstraint!
    private var current: NSView?
    private let width: CGFloat = 480

    private var source: BrowserSource?
    private var found = ImportFound()
    private var choice = ImportChoice()
    private var summary: ImportSummary?
    private var pickedURL: URL?
    private(set) var step = "pick"
    private var busy = false
    private var isDismissing = false

    // Kept so the header icon is the one the flight lands on.
    private weak var headerIcon: NSImageView?
    private weak var accessMessage: NSTextField?
    private weak var accessButton: NSButton?
    private weak var accessSpinner: NSProgressIndicator?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { isDismissing ? nil : super.hitTest(point) }

    private func build() {
        scrim.wantsLayer = true
        shadowHost.wantsLayer = true
        shadowHost.layer?.shadowColor = NSColor.black.cgColor
        shadowHost.layer?.shadowOpacity = 0.3
        shadowHost.layer?.shadowRadius = 34
        shadowHost.layer?.shadowOffset = CGSize(width: 0, height: -12)
        shadowHost.layer?.cornerRadius = 18
        shadowHost.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.01).cgColor

        panel.material = .popover
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 0.5

        // The space's gradient glows from the top and fades out before the content gets busy.
        let fade = CAGradientLayer()
        fade.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 0.45, 1]
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        wash.layer?.mask = fade
        wash.alphaValue = 0.75

        for v in [scrim, shadowHost, panel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        tint.wantsLayer = true
        for v in [tint, wash, stage] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(v)
        }
        stageHeight = stage.heightAnchor.constraint(equalToConstant: 300)
        // The card hangs from a fixed line above the middle and grows downward, so its header never jumps
        // while the steps change height.
        let top = panel.topAnchor.constraint(equalTo: centerYAnchor, constant: -250)
        top.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),

            top,
            panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 28),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(equalToConstant: width),
            shadowHost.topAnchor.constraint(equalTo: panel.topAnchor), shadowHost.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor), shadowHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),

            tint.topAnchor.constraint(equalTo: panel.topAnchor), tint.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: panel.leadingAnchor), tint.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            wash.topAnchor.constraint(equalTo: panel.topAnchor), wash.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: panel.trailingAnchor), wash.heightAnchor.constraint(equalToConstant: 170),

            stage.topAnchor.constraint(equalTo: panel.topAnchor), stage.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: panel.leadingAnchor), stage.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stageHeight,
        ])

        let close = IconButton(symbol: "xmark", size: 11, tooltip: "Close") { [weak self] in self?.dismiss() }
        panel.addSubview(close)
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            close.widthAnchor.constraint(equalToConstant: 22), close.heightAnchor.constraint(equalToConstant: 22),
        ])
        applyColors()
    }

    override func layout() {
        super.layout()
        wash.layer?.mask?.frame = wash.bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        wash.apply(wash.theme)
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.38 : 0.2).cgColor
            panel.layer?.borderColor = NSColor.labelColor.withAlphaComponent(dark ? 0.16 : 0.1).cgColor
            tint.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        }
    }

    // MARK: Showing and leaving

    func present() {
        wash.apply(Store.shared.currentSpace.theme)
        isHidden = false
        alphaValue = 1
        show(pickView(), direction: 0)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        (window as? SorrelWindow)?.focusHolder = self
        scrim.alphaValue = 0
        Motion.run(0.22, Motion.glide) { scrim.animator().alphaValue = 1 }
        for v in [panel, shadowHost] as [NSView] { v.layer?.popIn(scale: 0.94, rise: -10, duration: 0.38) }
        cascade(in: current)
    }

    func dismiss(then: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        (window as? SorrelWindow)?.focusHolder = nil
        window?.makeFirstResponder(nil)
        for v in [panel, shadowHost] as [NSView] { v.layer?.popOut(scale: 0.96, duration: 0.16) }
        Motion.run(0.18, Motion.leave, { animator().alphaValue = 0 }) { [weak self] in
            guard let self else { return }
            self.removeFromSuperview()
            then?()
            self.onClosed?()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if step == "choose" || step == "access", !busy { back() } else if !busy { dismiss() }
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the dimmed window outside the card closes it, unless something is being read.
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)), !busy { dismiss() }
    }

    // MARK: Steps

    /// Swaps the step: the old one slides out toward where it logically sits, the new one slides in from the
    /// other side, and the card's height glides to fit. direction: +1 forward, -1 back, 0 first appearance.
    private func show(_ view: NSView, direction: CGFloat) {
        let old = current
        current = view
        view.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: stage.topAnchor),
            view.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        let height = ceil(view.fittingSize.height)
        stage.layoutSubtreeIfNeeded()
        guard direction != 0 else {
            stageHeight.constant = height
            old?.removeFromSuperview()
            return
        }
        let travel: CGFloat = Motion.reduced ? 0 : 28
        if let old {
            old.wantsLayer = true
            slide(old.layer, from: 0, to: -travel * direction, fadeTo: 0, duration: 0.16, timing: Motion.leave, removing: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { old.removeFromSuperview() }
        }
        view.wantsLayer = true
        slide(view.layer, from: travel * direction, to: 0, fadeTo: 1, duration: 0.38, timing: Motion.settle, delay: 0.06)
        Motion.run(0.36, Motion.settle) { stageHeight.animator().constant = height }
    }

    private func slide(_ layer: CALayer?, from: CGFloat, to: CGFloat, fadeTo: Float, duration: TimeInterval,
                       timing: CAMediaTimingFunction, delay: TimeInterval = 0, removing: Bool = false) {
        guard let layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = from
        move.toValue = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fadeTo == 1 ? 0 : 1
        fade.toValue = fadeTo
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.timingFunction = timing
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .both
        group.isRemovedOnCompletion = removing ? false : true
        layer.add(group, forKey: "stepSlide")
    }

    /// Children marked for it rise in one after another, a beat apart.
    private func cascade(in view: NSView?, start: TimeInterval = 0.08, gap: TimeInterval = 0.035) {
        guard let view else { return }
        var i = 0
        func walk(_ v: NSView) {
            if v.identifier?.rawValue == "cascade" {
                v.wantsLayer = true
                let layer = v.layer
                let delay = start + Double(i) * gap
                i += 1
                layer?.opacity = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    layer?.opacity = 1
                    layer?.popIn(scale: 0.9, rise: Motion.reduced ? 0 : -8, duration: 0.34)
                }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(view)
    }

    // MARK: Pick

    private func pickView() -> NSView {
        step = "pick"
        let v = NSView()
        let header = headerView(icon: NSApp.applicationIconImage, title: "Bring your browser with you",
                                subtitle: "Spaces, pinned tabs, favorites, bookmarks and history. Everything is read right here on your Mac; nothing is sent anywhere.")
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        let sources = BrowserSource.offered()
        var row: NSStackView?
        for (i, s) in sources.enumerated() {
            if i % 4 == 0 {
                row = NSStackView()
                row!.spacing = 8
                grid.addArrangedSubview(row!)
            }
            let tile = BrowserTile(source: s)
            tile.identifier = NSUserInterfaceItemIdentifier("cascade")
            tile.onClick = { [weak self, weak tile] in
                guard let self, let tile else { return }
                self.choose(s, from: tile)
            }
            row!.addArrangedSubview(tile)
        }

        let fileNote = NSTextField(labelWithString: "Have an exported bookmarks file?")
        fileNote.font = .systemFont(ofSize: 12)
        fileNote.textColor = .secondaryLabelColor
        let fileButton = LinkButton(title: "Choose File…") { [weak self] in
            self?.choose(.bookmarksFile, from: nil)
        }
        let footer = NSStackView(views: [fileNote, fileButton])
        footer.spacing = 4
        footer.identifier = NSUserInterfaceItemIdentifier("cascade")

        for x in [header, grid, footer] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            grid.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            footer.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            footer.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -22),
        ])
        return v
    }

    private func choose(_ s: BrowserSource, from tile: BrowserTile?) {
        guard !busy else { return }
        source = s
        found = ImportFound()
        choice = ImportChoice()
        let next = accessView(for: s)
        show(next, direction: 1)
        cascade(in: next, start: 0.16)
        if let tile { fly(tile.iconView) }
    }

    /// The tile's icon lifts off and lands in the next step's header; the header's own copy appears under it.
    private func fly(_ from: NSImageView) {
        guard let target = headerIcon, let image = from.image, let layer = self.layer else { return }
        layoutSubtreeIfNeeded()
        let start = from.convert(from.bounds, to: self)
        let end = target.convert(target.bounds, to: self)
        guard !Motion.reduced else { return }
        target.alphaValue = 0
        let flyer = CALayer()
        flyer.contents = image
        flyer.contentsGravity = .resizeAspect
        flyer.contentsScale = window?.backingScaleFactor ?? 2
        flyer.frame = end
        flyer.zPosition = 10
        flyer.shadowColor = NSColor.black.cgColor
        flyer.shadowOpacity = 0.25
        flyer.shadowRadius = 10
        flyer.shadowOffset = CGSize(width: 0, height: -4)
        layer.addSublayer(flyer)

        let pos = CABasicAnimation(keyPath: "position")
        pos.fromValue = CGPoint(x: start.midX, y: start.midY)
        pos.toValue = CGPoint(x: end.midX, y: end.midY)
        let size = CABasicAnimation(keyPath: "bounds.size")
        size.fromValue = start.size
        size.toValue = end.size
        // A slight arc: it rises a touch above the straight line, as if lifted rather than dragged.
        let lift = CAKeyframeAnimation(keyPath: "transform.translation.y")
        lift.values = [0, 10, 0]
        lift.keyTimes = [0, 0.45, 1]
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0, 0.3, 0]
        let group = CAAnimationGroup()
        group.animations = [pos, size, lift, glow]
        group.duration = 0.5
        group.timingFunction = Motion.settle
        flyer.shadowOpacity = 0
        flyer.add(group, forKey: "fly")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak target] in
            target?.alphaValue = 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flyer.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    // MARK: Access

    private func accessView(for s: BrowserSource) -> NSView {
        step = "access"
        let v = NSView()
        let header = headerView(icon: s.icon, title: s.kind == .bookmarksFile ? "Import a bookmarks file" : "Import from \(s.name)",
                                subtitle: whatComes(s))
        let hint = NSTextField(wrappingLabelWithString: s.accessHint)
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = .secondaryLabelColor
        hint.identifier = NSUserInterfaceItemIdentifier("cascade")

        var views: [NSView] = [header, hint]
        var pathChip: NSView?
        if let data = s.dataPath {
            let chip = PathChip(text: "~/" + data)
            chip.identifier = NSUserInterfaceItemIdentifier("cascade")
            views.append(chip)
            pathChip = chip
        }
        let message = NSTextField(wrappingLabelWithString: "")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .systemRed
        message.isHidden = true
        accessMessage = message
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        accessSpinner = spinner
        let back = NSButton(title: "Back", target: self, action: #selector(backClicked))
        back.bezelStyle = .rounded
        back.controlSize = .large
        let go = NSButton(title: s.kind == .bookmarksFile ? "Choose File…" : "Continue…", target: self, action: #selector(requestAccess))
        go.bezelStyle = .rounded
        go.controlSize = .large
        go.keyEquivalent = "\r"
        accessButton = go
        views += [message, spinner, back, go]
        for x in views {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        var cs: [NSLayoutConstraint] = [
            header.topAnchor.constraint(equalTo: v.topAnchor),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            hint.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 32),
            hint.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -32),
            message.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            back.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            go.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            back.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 18),
            go.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            spinner.centerYAnchor.constraint(equalTo: go.centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: go.leadingAnchor, constant: -10),
            back.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),
        ]
        if let chip = pathChip {
            cs += [chip.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
                   chip.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
                   chip.trailingAnchor.constraint(lessThanOrEqualTo: hint.trailingAnchor),
                   message.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 8)]
        } else {
            cs.append(message.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(cs)
        return v
    }

    private func whatComes(_ s: BrowserSource) -> String {
        switch s.kind {
        case .arc: return "Your spaces with their colours and icons, pinned tabs and folders, favorites, and history."
        case .bookmarksFile: return "Bookmarks arrive as pinned tabs in a new space, folders and all."
        default: return "Bookmarks arrive as pinned tabs in a new “\(s.name)” space, folders and all. History comes too."
        }
    }

    @objc private func backClicked() { back() }

    private func back() {
        guard !busy else { return }
        if step == "choose", let s = source {
            let v = accessView(for: s)
            show(v, direction: -1)
        } else {
            let v = pickView()
            show(v, direction: -1)
            cascade(in: v, start: 0.1, gap: 0.02)
        }
    }

    @objc private func requestAccess() {
        guard let s = source, let window, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = s.kind == .bookmarksFile || s.kind == .safari
        panel.canChooseDirectories = s.kind != .bookmarksFile
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        panel.treatsFilePackagesAsDirectories = true
        if s.kind == .bookmarksFile || s.kind == .safari { panel.allowedContentTypes = [.html, .folder] }
        panel.prompt = s.kind == .bookmarksFile ? "Import" : "Allow"
        panel.message = s.kind == .bookmarksFile
            ? "Choose the bookmarks file you exported."
            : "Sorrel needs your OK to read \(s.name)’s folder. It’s already open here: click Allow."
        if let dir = s.dataURL {
            panel.directoryURL = dir
        } else {
            panel.directoryURL = Sandbox.downloads
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.read(url)
        }
    }

    /// Reads off the main thread; the "choose" step slides in once there is something to show. Errors stay on
    /// this step with a small shake, so it's clear the button was heard.
    func read(_ url: URL) {
        guard let s = source else { return }
        busy = true
        pickedURL = url
        accessMessage?.isHidden = true
        accessButton?.isEnabled = false
        accessSpinner?.startAnimation(nil)
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            let result = Result { try ImportReader.read(s, at: url) }
            if scoped { url.stopAccessingSecurityScopedResource() }
            // Never flash: a quick read still lets the spinner be seen for a moment.
            let wait = max(0, 0.45 - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                guard let self else { return }
                self.busy = false
                self.accessSpinner?.stopAnimation(nil)
                self.accessButton?.isEnabled = true
                switch result {
                case .success(let f) where !f.isEmpty:
                    self.found = f
                    let v = self.chooseView()
                    self.show(v, direction: 1)
                    self.cascade(in: v, start: 0.14)
                case .success:
                    self.fail("Nothing to bring over was found there.")
                case .failure(let e):
                    self.fail(e.localizedDescription)
                }
            }
        }
    }

    private func fail(_ text: String) {
        guard let m = accessMessage else { return }
        m.stringValue = text
        let wasHidden = m.isHidden
        m.isHidden = false
        // Refit the card around the message.
        if let current { Motion.run(0.3, Motion.settle) { stageHeight.animator().constant = ceil(current.fittingSize.height) } }
        if wasHidden { m.layer?.popIn(scale: 1, rise: -4, duration: 0.25) }
        guard !Motion.reduced, let layer = panel.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -7, 6, -4, 2, 0]
        shake.duration = 0.36
        shake.timingFunction = Motion.glide
        layer.add(shake, forKey: "shake")
        shadowHost.layer?.add(shake, forKey: "shake")
    }

    // MARK: Choose

    private func chooseView() -> NSView {
        step = "choose"
        guard let s = source else { return NSView() }
        let v = NSView()
        let header = headerView(icon: s.icon, title: "Here’s what Sorrel found", subtitle: foundLine())

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 8
        rows.alignment = .width

        if s.kind == .arc, !found.spaces.isEmpty {
            let pinned = found.spaces.reduce(0) { $0 + $1.pinnedTabs }
            let folders = found.spaces.reduce(0) { $0 + $1.pinned.reduce(0) { $0 + $1.folderCount } }
            var detail = "\(plural(found.spaces.count, "space")) · \(plural(pinned, "pinned tab"))"
            if folders > 0 { detail += " in \(plural(folders, "folder"))" }
            let row = OptionRow(symbol: "square.stack.3d.up", title: "Spaces and pinned tabs", detail: detail, on: choice.spaces) { [weak self] on in self?.choice.spaces = on }
            row.accessory = chips()
            rows.addArrangedSubview(row)
            let today = found.spaces.reduce(0) { $0 + $1.todayTabs }
            if today > 0 {
                rows.addArrangedSubview(OptionRow(symbol: "rectangle.stack", title: "Open tabs", detail: "\(plural(today, "unpinned tab")), into the same spaces", on: choice.openTabs) { [weak self] on in self?.choice.openTabs = on })
            }
        }
        if !found.favorites.isEmpty {
            rows.addArrangedSubview(OptionRow(symbol: "star", title: "Favorites", detail: "\(plural(found.favorites.count, "site")), shared across every space", on: choice.favorites) { [weak self] on in self?.choice.favorites = on })
        }
        if !found.bookmarks.isEmpty {
            let folders = found.bookmarks.reduce(0) { $0 + $1.folderCount }
            var detail = "\(plural(found.bookmarkCount, "bookmark"))"
            if folders > 0 { detail += " in \(plural(folders, "folder"))" }
            detail += ", as pinned tabs in a “\(s.kind == .bookmarksFile ? "Bookmarks" : s.name)” space"
            rows.addArrangedSubview(OptionRow(symbol: "bookmark", title: "Bookmarks", detail: detail, on: choice.bookmarks) { [weak self] on in self?.choice.bookmarks = on })
        }
        if !found.history.isEmpty {
            rows.addArrangedSubview(OptionRow(symbol: "clock.arrow.circlepath", title: "History", detail: "\(plural(found.history.count, "page")), for suggestions as you type", on: choice.history) { [weak self] on in self?.choice.history = on })
        }
        for r in rows.arrangedSubviews {
            r.identifier = NSUserInterfaceItemIdentifier("cascade")
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        let problems = NSTextField(wrappingLabelWithString: found.problems.joined(separator: " "))
        problems.font = .systemFont(ofSize: 11.5)
        problems.textColor = .secondaryLabelColor
        problems.isHidden = found.problems.isEmpty

        let back = NSButton(title: "Back", target: self, action: #selector(backClicked))
        back.bezelStyle = .rounded
        back.controlSize = .large
        let go = NSButton(title: "Import", target: self, action: #selector(runImport))
        go.bezelStyle = .rounded
        go.controlSize = .large
        go.keyEquivalent = "\r"
        for x in [header, rows, problems, back, go] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            rows.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            rows.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 22),
            rows.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -22),
            problems.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 10),
            problems.leadingAnchor.constraint(equalTo: rows.leadingAnchor, constant: 4),
            problems.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
            back.topAnchor.constraint(equalTo: problems.bottomAnchor, constant: 16),
            back.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            go.centerYAnchor.constraint(equalTo: back.centerYAnchor),
            go.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            back.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),
        ])
        return v
    }

    private func foundLine() -> String {
        guard let s = source else { return "" }
        if let url = pickedURL, s.kind == .bookmarksFile { return "From \(url.lastPathComponent). Pick what to bring; pages already in Sorrel are skipped." }
        return "Pick what to bring. Pages already in Sorrel are skipped, so importing again adds only what’s new."
    }

    /// Arc's spaces as small coloured coins with their emoji: a glimpse of the sidebar that's about to arrive.
    private func chips() -> NSView {
        let row = NSStackView()
        row.spacing = 5
        let maxShown = 11
        for space in found.spaces.prefix(maxShown) {
            let chip = SpaceCoin(icon: space.icon, theme: space.theme ?? Theme.presets[0])
            chip.toolTip = space.name
            chip.identifier = NSUserInterfaceItemIdentifier("cascade")
            row.addArrangedSubview(chip)
        }
        if found.spaces.count > maxShown {
            let more = NSTextField(labelWithString: "+\(found.spaces.count - maxShown)")
            more.font = .systemFont(ofSize: 11, weight: .medium)
            more.textColor = .secondaryLabelColor
            row.addArrangedSubview(more)
        }
        return row
    }

    @objc func runImport() {
        guard let s = source, !busy, step == "choose" || step == "done" else { return }
        busy = true
        let result = Importer.apply(found, from: s, choice: choice, store: Store.shared)
        summary = result
        busy = false
        let v = doneView(result)
        show(v, direction: 1)
        cascade(in: v, start: 0.42, gap: 0.07)
        // The wash takes on the colours of where things landed.
        if let sp = result.firstSpace { wash.apply(sp.theme, animated: true) }
    }

    // MARK: Done

    private func doneView(_ r: ImportSummary) -> NSView {
        step = "done"
        let v = NSView()
        let ring = DrawnCheck(color: ringColor())
        let title = NSTextField(labelWithString: r.lines.isEmpty ? "Already up to date" : "You’re all moved in")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.alignment = .center
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 4
        let lines = r.lines.isEmpty ? ["Everything you picked was already here."] : r.lines
        for line in lines {
            let l = NSTextField(labelWithString: line)
            l.font = .systemFont(ofSize: 13)
            l.textColor = .secondaryLabelColor
            l.identifier = NSUserInterfaceItemIdentifier("cascade")
            list.addArrangedSubview(l)
        }
        let done = NSButton(title: r.firstSpace.map { "Go to \($0.icon) \($0.name)" } ?? "Done", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.controlSize = .large
        done.keyEquivalent = "\r"
        done.identifier = NSUserInterfaceItemIdentifier("cascade")
        for x in [ring, title, list, done] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: v.topAnchor, constant: 34),
            ring.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 58), ring.heightAnchor.constraint(equalToConstant: 58),
            title.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            list.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            list.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            done.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 22),
            done.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            done.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -24),
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { ring.draw() }
        return v
    }

    private func ringColor() -> NSColor {
        let theme = summary?.firstSpace?.theme ?? Store.shared.currentSpace.theme
        let c = theme.colors.compactMap { NSColor(hex: $0) }.first ?? .controlAccentColor
        // Pale theme colours would vanish on the card; deepen them until they read.
        return c.luminance > 0.7 ? (c.blended(withFraction: 0.45, of: .black) ?? c) : c
    }

    @objc private func finish() {
        let target = summary?.firstSpace
        dismiss {
            if let target { Store.shared.switchSpace(to: target) }
        }
    }

    // MARK: Pieces

    private func headerView(icon: NSImage, title: String, subtitle: String) -> NSView {
        let v = NSView()
        let iv = NSImageView(image: icon)
        iv.imageScaling = .scaleProportionallyUpOrDown
        headerIcon = iv
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 19, weight: .semibold)
        t.alignment = .center
        let s = NSTextField(wrappingLabelWithString: subtitle)
        s.font = .systemFont(ofSize: 12.5)
        s.textColor = .secondaryLabelColor
        s.alignment = .center
        for x in [iv, t, s] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: v.topAnchor, constant: 30),
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iv.widthAnchor.constraint(equalToConstant: 60), iv.heightAnchor.constraint(equalToConstant: 60),
            t.topAnchor.constraint(equalTo: iv.bottomAnchor, constant: 12),
            t.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            t.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 32),
            s.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 6),
            s.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 44),
            s.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -44),
            s.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    // MARK: Test hooks

    /// Picks a browser and hands over `url` as if the Open panel had returned it.
    func debugRead(_ s: BrowserSource, url: URL) {
        choose(s, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.read(url) }
    }

    var debugLines: [String] {
        var out = ["step=\(step) source=\(source?.id ?? "-") offered=\(BrowserSource.offered().map(\.id).joined(separator: ","))"]
        if let msg = accessMessage, !msg.isHidden { out.append("message=\(msg.stringValue)") }
        out.append("found spaces=\(found.spaces.count) pinned=\(found.spaces.reduce(0) { $0 + $1.pinnedTabs }) today=\(found.spaces.reduce(0) { $0 + $1.todayTabs }) favorites=\(found.favorites.count) bookmarks=\(found.bookmarkCount) history=\(found.history.count) problems=\(found.problems.count)")
        if let r = summary { out.append("summary " + r.lines.joined(separator: " | ") + " first=\(r.firstSpace?.name ?? "-")") }
        out.append("card height=\(Int(stageHeight.constant))")
        return out
    }
}

// MARK: - Browser tile

final class BrowserTile: NSView {
    let iconView = NSImageView()
    var onClick: (() -> Void)?
    private let highlight = CALayer()
    private var hovering = false { didSet { if hovering != oldValue { hoverChanged() } } }

    init(source: BrowserSource) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        highlight.cornerRadius = 12
        highlight.opacity = 0
        layer?.addSublayer(highlight)
        iconView.image = source.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        let label = NSTextField(labelWithString: source.name)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        let note = NSTextField(labelWithString: source.isInstalled ? "" : "Data only")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.isHidden = source.isInstalled
        toolTip = source.isInstalled ? "Import from \(source.name)" : "Import from \(source.name)’s saved data (the app isn’t installed)"
        for x in [iconView, label, note] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            addSubview(x)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 100), heightAnchor.constraint(equalToConstant: 96),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 46), iconView.heightAnchor.constraint(equalToConstant: 46),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            note.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 0),
            note.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        Motion.layer(0) { highlight.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// The highlight crossfades in and the icon lifts a little, as if offering itself.
    private func hoverChanged() {
        Motion.layer(hovering ? 0.16 : 0.22) { highlight.opacity = hovering ? 1 : 0 }
        guard !Motion.reduced, let layer = iconView.layer else { return }
        let b = layer.bounds
        var lifted = CATransform3DMakeTranslation(b.midX, b.midY + 3, 0)
        lifted = CATransform3DScale(lifted, 1.06, 1.06, 1)
        lifted = CATransform3DTranslate(lifted, -b.midX, -b.midY, 0)
        let to = hovering ? lifted : CATransform3DIdentity
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = layer.presentation()?.transform ?? layer.transform
        a.toValue = to
        a.duration = hovering ? 0.26 : 0.2
        a.timingFunction = hovering ? Motion.settle : Motion.glide
        layer.transform = to
        layer.add(a, forKey: "lift")
    }

    override func mouseDown(with event: NSEvent) { layer?.press(scale: 0.95) }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Small pieces

/// A text button that looks like a link and underlines on hover.
final class LinkButton: NSButton {
    private var handler: (() -> Void)?
    private let text: String

    init(title: String, handler: @escaping () -> Void) {
        self.text = title
        super.init(frame: .zero)
        self.handler = handler
        isBordered = false
        target = self
        action = #selector(fire)
        setTitle(underlined: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setTitle(underlined: Bool) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: underlined ? NSUnderlineStyle.single.rawValue : 0])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setTitle(underlined: true) }
    override func mouseExited(with event: NSEvent) { setTitle(underlined: false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    @objc private func fire() { handler?() }
}

/// A folder path in a quiet rounded chip, so it's clear what is about to be shared.
final class PathChip: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        let icon = NSImageView(image: symbol("folder", size: 11) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        for x in [icon, label] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            addSubview(x)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

/// A space as a small coin: its gradient, its emoji.
final class SpaceCoin: NSView {
    private let gradient = CAGradientLayer()
    private let theme: Theme

    init(icon: String, theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        gradient.cornerRadius = 13
        gradient.borderWidth = 0.5
        layer?.addSublayer(gradient)
        let label = NSTextField(labelWithString: icon)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 26),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        paint()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Motion.layer(0) { gradient.frame = bounds }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
    private func paint() {
        var cs = theme.resolvedColors(systemIsDark: systemIsDark()).map(\.cgColor)
        if cs.count == 1 { cs.append(cs[0]) }
        gradient.colors = cs
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
    }
}

/// One thing to bring: icon, title, a line of detail, an optional accessory under it, and a switch.
final class OptionRow: NSView {
    private let onChange: (Bool) -> Void
    private let toggle = NSSwitch()
    private let stack = NSStackView()
    private let content = NSStackView()
    var accessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessory { stack.addArrangedSubview(accessory); stack.setCustomSpacing(8, after: stack.arrangedSubviews[1]) }
        }
    }

    init(symbol name: String, title: String, detail: String, on: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        let icon = NSImageView(image: symbol(name, size: 15) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11.5)
        d.textColor = .secondaryLabelColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(t)
        stack.addArrangedSubview(d)
        toggle.state = on ? .on : .off
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(flipped)
        for x in [icon, stack, toggle] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            addSubview(x)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toggle.centerYAnchor.constraint(equalTo: t.centerYAnchor, constant: 6),
        ])
        updateLook(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { updateLook(animated: false) }

    @objc private func flipped() {
        onChange(toggle.state == .on)
        updateLook(animated: true)
    }

    /// A row switched off recedes rather than disappearing, so it can be switched back.
    private func updateLook(animated: Bool) {
        let on = toggle.state == .on
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Motion.layer(animated ? 0.2 : 0) {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(on ? 0.06 : 0.025).cgColor
            }
        }
        if animated { Motion.run(0.2, Motion.glide) { stack.animator().alphaValue = on ? 1 : 0.5 } } else { stack.alphaValue = on ? 1 : 0.5 }
    }

    override func mouseUp(with event: NSEvent) {
        // The whole row is the switch's label.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle.state = toggle.state == .on ? .off : .on
        flipped()
    }
    override func mouseDown(with event: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A ring that draws itself round, then a check that draws itself in.
final class DrawnCheck: NSView {
    private let ring = CAShapeLayer()
    private let check = CAShapeLayer()
    private let fill = CAShapeLayer()
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        for l in [fill, ring, check] { layer?.addSublayer(l) }
        fill.fillColor = color.withAlphaComponent(0.14).cgColor
        fill.opacity = 0
        for l in [ring, check] {
            l.fillColor = nil
            l.strokeColor = color.cgColor
            l.lineCap = .round
            l.lineJoin = .round
            l.strokeEnd = 0
        }
        ring.lineWidth = 3
        check.lineWidth = 3.5
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds.insetBy(dx: 2, dy: 2)
        Motion.layer(0) {
            for l in [fill, ring, check] { l.frame = bounds }
            // Starts at the top and goes clockwise, as a hand would draw it.
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: b.midX, y: b.midY), radius: b.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            ring.path = path
            fill.path = CGPath(ellipseIn: b, transform: nil)
            let c = CGMutablePath()
            c.move(to: CGPoint(x: b.minX + b.width * 0.29, y: b.minY + b.height * 0.5))
            c.addLine(to: CGPoint(x: b.minX + b.width * 0.44, y: b.minY + b.height * 0.35))
            c.addLine(to: CGPoint(x: b.minX + b.width * 0.72, y: b.minY + b.height * 0.64))
            check.path = c
        }
    }

    func draw() {
        layoutSubtreeIfNeeded()
        func stroke(_ l: CAShapeLayer, delay: TimeInterval, duration: TimeInterval) {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = 0
            a.toValue = 1
            a.duration = Motion.reduced ? 0.01 : duration
            a.beginTime = CACurrentMediaTime() + (Motion.reduced ? 0 : delay)
            a.timingFunction = Motion.settle
            a.fillMode = .backwards
            l.strokeEnd = 1
            l.add(a, forKey: "draw")
        }
        stroke(ring, delay: 0, duration: 0.55)
        stroke(check, delay: 0.38, duration: 0.32)
        Motion.layer(0) { fill.opacity = 1 }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0
        f.toValue = 1
        f.duration = 0.4
        f.beginTime = CACurrentMediaTime() + 0.3
        f.fillMode = .backwards
        fill.add(f, forKey: "fill")
        if !Motion.reduced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { [weak self] in self?.layer?.press(scale: 1.06) }
        }
    }
}
