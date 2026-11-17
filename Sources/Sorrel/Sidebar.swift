import AppKit

private let itemDragType = NSPasteboard.PasteboardType("app.sorrel.item")

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.handler = handler
        target = self
        state = checked ? .on : .off
    }

    @objc private func fire() { handler?() }
}

final class Marker: NSObject {
    enum Kind { case separator, newTab }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

// MARK: - Outline pieces

final class SidebarOutline: NSOutlineView {
    // Rows span the full width; indentation is drawn by the cells themselves.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var r = super.frameOfCell(atColumn: column, row: row)
        r.origin.x = 0
        r.size.width = bounds.width
        return r
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class SidebarScroll: NSScrollView {
    /// Offered every scroll first; true = it was a sideways space swipe and has been handled.
    var onScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with e: NSEvent) {
        if onScroll?(e) == true { return }
        super.scrollWheel(with: e)
    }
}

final class SidebarRowView: NSTableRowView {
    var isActive = false { didSet { if oldValue != isActive { updateHighlight(animated: true) } } }
    var highlightable = true { didSet { if oldValue != highlightable { updateHighlight(animated: false) } } }
    private(set) var isHovered = false
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    /// The rounded tint behind the row. A layer of its own, so hover and selection crossfade instead of snapping.
    private let highlight = CALayer()
    private var shownColor: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        highlight.cornerRadius = 8
        highlight.zPosition = -1
        layer?.addSublayer(highlight)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Motion.layer(0) { highlight.frame = bounds.insetBy(dx: 8, dy: 1) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight(animated: false)
    }

    private func updateHighlight(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var color: NSColor?
        if highlightable && isActive {
            color = dark ? NSColor.white.withAlphaComponent(0.2) : NSColor.white.withAlphaComponent(0.85)
        } else if highlightable && isHovered {
            color = dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
        }
        let target = (color ?? (shownColor ?? .white).withAlphaComponent(0)).usingColorSpace(.sRGB) ?? .clear
        // Arrivals are quick, departures linger a little; a change of state while lit crossfades.
        let duration: TimeInterval = !animated ? 0 : (color == nil ? 0.22 : (shownColor == nil ? 0.1 : 0.18))
        if shownColor == nil, color != nil {
            // Start from the same tint at zero so the fade-in never passes through a grey.
            Motion.layer(0) { highlight.removeAllAnimations(); highlight.backgroundColor = target.withAlphaComponent(0).cgColor }
        }
        Motion.layer(duration) {
            if duration == 0 { highlight.removeAllAnimations() }
            highlight.backgroundColor = target.cgColor
        }
        shownColor = color
    }

    /// Off for the still pictures of other spaces that slide in during a space swipe.
    var tracksHover = true

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = nil
        guard tracksHover else { return }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ h: Bool) {
        guard h != isHovered else { return }
        isHovered = h
        updateHighlight(animated: true)
        onHover?(h)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isActive = false
        updateHighlight(animated: false)
    }

    override func drawBackground(in dirtyRect: NSRect) {}

    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

/// The button at the right end of a tab row. "−" unloads a pinned tab; "×" closes. It is drawn as two
/// strokes, so going from one to the other turns the minus into the cross instead of swapping icons.
final class TabActionButton: NSButton {
    enum Mode { case unload, close }
    private(set) var mode: Mode = .close
    var onClick: (() -> Void)?
    private let strokeA = CALayer()
    private let strokeB = CALayer()
    /// Holds both strokes so their transparency is applied once, not doubled where they overlap.
    private let strokes = CALayer()
    /// Clicks right after a change are ignored, so a double-click on "−" doesn't also hit the "×".
    private var changedAt = Date.distantPast

    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        image = nil
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        strokes.allowsGroupOpacity = true
        layer?.addSublayer(strokes)
        for s in [strokeA, strokeB] {
            s.cornerRadius = 0.8
            s.bounds = CGRect(x: 0, y: 0, width: Self.length(.close), height: 1.6)
            strokes.addSublayer(s)
        }
        place(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func length(_ m: Mode) -> CGFloat { m == .close ? 11 : 9 }
    private static func angle(_ m: Mode) -> CGFloat { m == .close ? .pi / 4 : 0 }

    func setMode(_ m: Mode, animated: Bool) {
        guard m != mode else { return }
        mode = m
        if animated { changedAt = Date() }
        place(animated: animated)
    }

    private func place(animated: Bool) {
        let angle = Self.angle(mode), length = Self.length(mode)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (s, sign) in [(strokeA, CGFloat(1)), (strokeB, CGFloat(-1))] {
            let from = (s.presentation() ?? s)
            if animated {
                let spin = CASpringAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = from.value(forKeyPath: "transform.rotation.z")
                spin.toValue = angle * sign
                spin.mass = 1
                spin.stiffness = 320
                spin.damping = 18
                spin.duration = spin.settlingDuration
                s.add(spin, forKey: "spin")
                let grow = CABasicAnimation(keyPath: "bounds.size.width")
                grow.fromValue = from.bounds.width
                grow.toValue = length
                grow.duration = 0.2
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                s.add(grow, forKey: "grow")
            }
            s.setValue(angle * sign, forKeyPath: "transform.rotation.z")
            s.bounds.size.width = length
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokes.frame = bounds
        for s in [strokeA, strokeB] { s.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        CATransaction.commit()
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        var color = NSColor.secondaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strokes.opacity = Float(color.alphaComponent)
        strokeA.backgroundColor = color.withAlphaComponent(1).cgColor
        strokeB.backgroundColor = color.withAlphaComponent(1).cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.5
        super.mouseDown(with: event)   // tracks until mouse up, firing the action if released inside
        layer?.opacity = 1
    }

    @objc private func fire() {
        guard Date().timeIntervalSince(changedAt) > 0.35 else { return }
        onClick?()
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

final class ItemCell: NSTableCellView, NSTextFieldDelegate {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    private(set) var closeButton: TabActionButton!
    private var leading: NSLayoutConstraint!
    private(set) weak var item: Item?
    /// The row's button was clicked: unload a loaded pinned tab, otherwise close.
    var onClose: ((Item) -> Void)?
    var onRename: ((Item, String) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        closeButton = TabActionButton()
        closeButton.onClick = { [weak self] in
            if let self, let item = self.item { self.onClose?(item) }
        }
        for v in [icon, label, spinner, closeButton!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.delegate = self
        label.focusRingType = .none
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        closeButton.isHidden = true

        leading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18)
        NSLayoutConstraint.activate([
            leading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: Item, level: Int) {
        let sameItem = self.item === item
        self.item = item
        if !item.isContainer {
            // Pinned tabs: "−" while loaded, then "×" (close and unpin) once asleep. Other tabs: "×".
            let pinned = Store.shared.isPinned(item)
            let mode: TabActionButton.Mode = pinned && item.page != nil ? .unload : .close
            closeButton.setMode(mode, animated: sameItem && window != nil)
            closeButton.toolTip = mode == .unload ? "Unload Tab" : (pinned ? "Close and Unpin" : "Close")
        }
        leading.constant = 18 + CGFloat(level) * 16
        label.stringValue = item.displayTitle
        if item.isFolder {
            icon.image = symbol(item.expanded ? "folder" : "folder.fill", size: 13)
            icon.contentTintColor = .secondaryLabelColor
            icon.alphaValue = 1
            icon.isHidden = false
            spinner.stopAnimation(nil)
            label.textColor = .labelColor
            label.font = .systemFont(ofSize: 13, weight: .medium)
        } else {
            let loading = item.page?.webView.isLoading ?? false
            let fav = FaviconStore.shared.image(for: item)
            icon.image = fav ?? symbol("globe", size: 13)
            icon.contentTintColor = .secondaryLabelColor
            icon.alphaValue = item.page == nil ? 0.55 : 1
            icon.isHidden = loading
            if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            label.textColor = .labelColor
            label.font = .systemFont(ofSize: 13)
        }
    }

    func setHovered(_ hovered: Bool) {
        closeButton.fade(in: hovered && !(item?.isFolder ?? true))
    }

    func beginRename() {
        guard let item else { return }
        label.isEditable = true
        label.stringValue = item.displayTitle
        onEditingChanged?(true)
        window?.makeFirstResponder(label)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        label.isEditable = false
        onEditingChanged?(false)
        if let item { onRename?(item, label.stringValue) }
    }
}

final class SeparatorCell: NSTableCellView {
    let clear = NSButton(title: "Clear", target: nil, action: nil)
    var onClear: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = NSColor.labelColor.withAlphaComponent(0.12)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        clear.isBordered = false
        clear.font = .systemFont(ofSize: 11, weight: .medium)
        clear.contentTintColor = .tertiaryLabelColor
        clear.target = self
        clear.action = #selector(fire)
        clear.toolTip = "Close all unpinned tabs"
        clear.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clear)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            clear.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onClear?() }
}

final class NewTabCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: symbol("plus", size: 12) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "New Tab")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        for v in [icon, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Address pill

/// An extension's icon in the address box. Click runs the extension; right-click offers its settings.
/// It shows the extension's button as it stands for the selected tab: extensions swap the icon per site
/// (uBlock Origin Lite's filtering level), add a badge (Proton Pass's count of logins for the site) or
/// switch it off where they can't work.
private final class ExtensionIconButton: NSButton {
    let entry: ExtensionEntry
    var entryID: String { entry.id }
    var onClick: (() -> Void)?
    /// The pointer reached the icon: a click is likely, so the extension's background is woken now.
    var onHover: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var hoverArea: NSTrackingArea?
    private var badge = ""
    private var dimmed = false

    init(entry: ExtensionEntry) {
        self.entry = entry
        super.init(frame: .zero)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Reads the button's current state from the extension.
    func refresh() {
        let live = Extensions.shared.action(for: entry, in: (window?.windowController as? MainWindowController)?.store.selected)
        let icon = (live?.icon(for: NSSize(width: 16, height: 16)) ?? entry.icon?.copy() as? NSImage)
            ?? symbol("puzzlepiece.extension", size: 12) ?? NSImage()
        icon.size = NSSize(width: 16, height: 16)
        image = icon
        badge = live?.badgeText ?? ""
        dimmed = !(live?.isEnabled ?? true)
        alphaValue = dimmed ? 0.4 : 1
        let label = live?.label ?? ""
        toolTip = (label.isEmpty ? entry.name : label) + (badge.isEmpty ? "" : " · \(badge)")
        live?.hasUnreadBadgeText = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !badge.isEmpty else { return }
        // A small count in the bottom-right corner, like Safari's.
        let text = NSAttributedString(string: badge.count > 4 ? String(badge.prefix(3)) + "…" : badge, attributes: [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        let w = max(11, size.width + 5), h: CGFloat = 11
        let box = NSRect(x: bounds.maxX - w - 1, y: 1, width: w, height: h)
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: box, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
    }

    @objc private func fire() { onClick?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        hoverArea = a
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class URLPill: NSView {
    let label = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var onCopy: (() -> Void)?
    /// Switched-on extensions, shown at the right end of the address box.
    private let extensionStack = NSStackView()
    private var extensionButtons: [ExtensionIconButton] = []
    static let maxExtensionIcons = 4
    private var copyButton: IconButton!
    /// An open lock in front of the host when the page came over plain http://. Kept apart from the text so
    /// cutting a long host short never cuts the lock.
    private let lockView = NSImageView()
    private var labelLeading: NSLayoutConstraint!
    private var canCopy = false
    private var hovered = false
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 13)
        // A long host is cut at the front, so the part that says whose site it is (evil.com in
        // "paypal.com.secure-login.evil.com") is the part that always shows.
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        lockView.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Not Secure")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [.systemOrange])))
        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.isHidden = true
        addSubview(lockView)
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        copyButton = IconButton(symbol: "link", size: 12) { [weak self] in self?.onCopy?() }
        copyButton.isHidden = true
        addSubview(copyButton)
        extensionStack.orientation = .horizontal
        extensionStack.spacing = 0
        extensionStack.translatesAutoresizingMaskIntoConstraints = false
        extensionStack.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(extensionStack)
        NSLayoutConstraint.activate([
            labelLeading,
            lockView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            lockView.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            extensionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            extensionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: extensionStack.leadingAnchor, constant: -1),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows an icon for each switched-on extension (the first few; the rest stay in the extensions menu).
    func setExtensions(_ entries: [ExtensionEntry], menuFor: @escaping (ExtensionEntry) -> NSMenu) {
        extensionButtons.forEach { extensionStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        extensionButtons = entries.prefix(Self.maxExtensionIcons).map { entry in
            let b = ExtensionIconButton(entry: entry)
            b.onClick = { Extensions.shared.performAction(entry) }
            b.onHover = { Extensions.shared.prewarm(entry) }
            b.menuProvider = { menuFor(entry) }
            extensionStack.addArrangedSubview(b)
            return b
        }
    }

    /// The icon for one extension, so its pop-up can open from it.
    func extensionButton(id: String) -> NSView? { extensionButtons.first { $0.entryID == id } }

    /// Re-reads each icon's state (badge, icon, enabled) for the selected tab.
    func refreshExtensionStates(only id: String? = nil) {
        for b in extensionButtons where id == nil || b.entryID == id { b.refresh() }
    }

    /// `insecure`: the page came over plain http://. An open lock goes in front of the host so that is never hidden.
    func set(_ text: String?, canCopy: Bool, insecure: Bool = false) {
        label.stringValue = text ?? "Search or enter address"
        label.textColor = text == nil ? .tertiaryLabelColor : .labelColor
        let notSecure = insecure && text != nil
        label.toolTip = notSecure ? "Not Secure: this page isn’t encrypted. Others on the network can see and change it." : nil
        lockView.toolTip = label.toolTip
        lockView.isHidden = !notSecure
        labelLeading.constant = notSecure ? 27 : 12
        self.canCopy = canCopy
        let key = Keybindings.shared.display(for: "tab.copyURL")
        copyButton.toolTip = "Copy link" + (key.map { " (\($0))" } ?? "")
        copyButton.isHidden = !(hovered && canCopy)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        copyButton.fade(in: canCopy)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        copyButton.fade(in: false)
    }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.1)
                                       : NSColor.black.withAlphaComponent(0.07)).cgColor
    }
    override var wantsUpdateLayer: Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Favorites (pinned across every space)

private final class FavoriteTile: NSView {
    let item: Item
    let icon = NSImageView()
    var isActive = false { didSet { if oldValue != isActive { updateLook(animated: true) } } }
    var onClick: ((Item) -> Void)?
    var menuProvider: ((Item) -> NSMenu)?
    private var hovered = false
    private var area: NSTrackingArea?

    init(item: Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        toolTip = item.displayTitle
        refresh()
        updateLook(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateLook(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateLook(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLook(animated: false)
    }

    private func updateLook(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        if isActive {
            color = dark ? NSColor.white.withAlphaComponent(0.26) : NSColor.white.withAlphaComponent(0.9)
        } else if hovered {
            color = dark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.1)
        } else {
            color = dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.06)
        }
        Motion.layer(animated ? 0.16 : 0) {
            layer?.backgroundColor = (color.usingColorSpace(.sRGB) ?? color).cgColor
        }
    }

    func refresh() {
        icon.image = FaviconStore.shared.image(for: item) ?? symbol("globe", size: 16)
        icon.contentTintColor = .secondaryLabelColor
        icon.alphaValue = item.page == nil ? 0.7 : 1
        toolTip = item.displayTitle
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
    }

    override func mouseDown(with event: NSEvent) {
        layer?.press()
        onClick?(item)
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?(item) }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class FavoritesGrid: NSView {
    private var tiles: [FavoriteTile] = []
    var heightConstraint: NSLayoutConstraint!
    var onClick: ((Item) -> Void)?
    var menuProvider: ((Item) -> NSMenu)?
    var onDropItem: ((UUID) -> Void)?
    private let tileHeight: CGFloat = 44
    private let gap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([itemDragType])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var columns: Int { max(1, min(tiles.count, 4)) }

    func reload(_ items: [Item], selected: Item?) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = items.map { item in
            let t = FavoriteTile(item: item)
            t.onClick = { [weak self] in self?.onClick?($0) }
            t.menuProvider = { [weak self] in self?.menuProvider?($0) ?? NSMenu() }
            t.isActive = item === selected
            addSubview(t)
            return t
        }
        let rows = tiles.isEmpty ? 0 : (tiles.count + columns - 1) / columns
        heightConstraint.constant = rows == 0 ? 0 : CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gap
        needsLayout = true
    }

    func refresh(selected: Item?) {
        for t in tiles {
            t.isActive = t.item === selected
            t.refresh()
        }
    }

    override func layout() {
        super.layout()
        guard !tiles.isEmpty else { return }
        let cols = CGFloat(columns)
        let w = (bounds.width - gap * (cols - 1)) / cols
        for (i, t) in tiles.enumerated() {
            let row = CGFloat(i / columns), col = CGFloat(i % columns)
            t.frame = NSRect(x: col * (w + gap), y: bounds.height - (row + 1) * tileHeight - row * gap,
                             width: w, height: tileHeight)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let s = sender.draggingPasteboard.string(forType: itemDragType), let id = UUID(uuidString: s) else { return false }
        onDropItem?(id)
        return true
    }
}

// MARK: - Space switcher

/// The row of space icons. Pressing anywhere on it and dragging sideways scrubs through the spaces, the
/// sidebar sliding along under the cursor; a plain click still picks the space under it. The buttons hand
/// their mouse events to the strip (so their tooltips and right-click menus keep working).
private final class SpaceStrip: NSStackView {
    var onPress: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var onRelease: ((NSEvent) -> Void)?
    override func mouseDown(with e: NSEvent) { onPress?(e) }
    override func mouseDragged(with e: NSEvent) { onDrag?(e) }
    override func mouseUp(with e: NSEvent) { onRelease?(e) }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class SpaceButton: NSButton {
    var space: Space?
    var menuProvider: ((Space) -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { space.flatMap { menuProvider?($0) } }
    override var mouseDownCanMoveWindow: Bool { false }
    private var strip: SpaceStrip? { superview as? SpaceStrip }
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control), let m = menu(for: e) {
            NSMenu.popUpContextMenu(m, with: e, for: self)
            return
        }
        strip?.mouseDown(with: e)
    }
    override func mouseDragged(with e: NSEvent) { strip?.mouseDragged(with: e) }
    override func mouseUp(with e: NSEvent) { strip?.mouseUp(with: e) }
}

/// The scrolling window onto the space icons when there are more than fit. Every scroll over the icons is the
/// row's own (the owner asked that it never switch spaces, even when they all fit): two fingers either way, or a
/// wheel mouse, slide the row; up/down counts as sideways, and the momentum glide carries on. Switching by
/// swiping is for the rest of the sidebar.
private final class SpaceRowScroll: NSScrollView {
    var overflows: Bool { (documentView?.frame.width ?? 0) > contentView.bounds.width + 0.5 }

    override func scrollWheel(with e: NSEvent) {
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        var d = abs(dy) > abs(dx) ? dy : dx
        if !e.hasPreciseScrollingDeltas { d *= 8 }   // a wheel's deltas are in lines
        if d != 0, overflows { scrollRow(by: -d) }
    }

    /// Moves the row by `dx` points (positive = towards later spaces), staying within its ends.
    func scrollRow(by dx: CGFloat) {
        scrollRow(toX: contentView.bounds.origin.x + dx)
    }

    func scrollRow(toX x: CGFloat, animated: Bool = false) {
        let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        let target = NSPoint(x: max(0, min(maxX, x)), y: contentView.bounds.origin.y)
        if animated, !Motion.reduced {
            Motion.run(0.3, Motion.glide) { contentView.animator().setBoundsOrigin(target) }
        } else {
            contentView.setBoundsOrigin(target)
        }
        reflectScrolledClipView(contentView)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

private final class SpaceBar: NSView {
    private let stack = SpaceStrip()
    private let row = SpaceRowScroll()
    private let rowContent = NSView()
    private let rowFade = CAGradientLayer()
    /// While scrubbing: the cursor's last window x, and the timer that keeps the row scrolling while it rests
    /// near either end of the row.
    private var scrubX: CGFloat = 0
    private var edgeTimer: Timer?
    var onSelect: ((Space) -> Void)?
    /// Click-and-hold scrubbing: began, moved to a position (in spaces, may run past either end), let go.
    var onScrubBegin: (() -> Void)?
    var onScrub: ((CGFloat) -> Void)?
    var onScrubEnd: ((CGFloat) -> Void)?
    private var pressX: CGFloat = 0
    private var pressed: SpaceButton?
    private(set) var isScrubbing = false
    var menuProvider: ((Space) -> NSMenu)?
    var onAdd: ((NSView) -> Void)?
    var onExtensions: ((NSView) -> Void)?
    var onDownloads: ((NSView) -> Void)?
    private var addButton: IconButton!
    private(set) var extensionsButton: IconButton!
    private(set) var downloadsButton: DownloadsButton!

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.onPress = { [weak self] in self?.press($0) }
        stack.onDrag = { [weak self] in self?.drag($0) }
        stack.onRelease = { [weak self] in self?.release($0) }
        // The icons sit in a row that scrolls sideways once there are more than fit between the buttons.
        row.drawsBackground = false
        row.hasHorizontalScroller = false
        row.hasVerticalScroller = false
        row.horizontalScrollElasticity = .allowed
        row.verticalScrollElasticity = .none
        row.automaticallyAdjustsContentInsets = false
        row.translatesAutoresizingMaskIntoConstraints = false
        rowContent.translatesAutoresizingMaskIntoConstraints = false
        row.documentView = rowContent
        rowContent.addSubview(stack)
        addSubview(row)
        row.wantsLayer = true
        row.layer?.mask = rowFade
        rowFade.startPoint = CGPoint(x: 0, y: 0.5)
        rowFade.endPoint = CGPoint(x: 1, y: 0.5)
        row.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(rowScrolled), name: NSView.boundsDidChangeNotification,
                                               object: row.contentView)
        addButton = IconButton(symbol: "plus", size: 12, tooltip: "New space or folder") { [weak self] in
            if let self { self.onAdd?(self.addButton) }
        }
        addSubview(addButton)
        extensionsButton = IconButton(symbol: "puzzlepiece.extension", size: 12, tooltip: "Extensions") { [weak self] in
            if let self { self.onExtensions?(self.extensionsButton) }
        }
        addSubview(extensionsButton)
        downloadsButton = DownloadsButton { [weak self] in
            if let self { self.onDownloads?(self.downloadsButton) }
        }
        addSubview(downloadsButton)
        NSLayoutConstraint.activate([
            downloadsButton.leadingAnchor.constraint(equalTo: extensionsButton.trailingAnchor, constant: 0),
            downloadsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            downloadsButton.widthAnchor.constraint(equalToConstant: 24),
            downloadsButton.heightAnchor.constraint(equalToConstant: 24),
            extensionsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            extensionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            extensionsButton.widthAnchor.constraint(equalToConstant: 24),
            extensionsButton.heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            row.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowContent.topAnchor.constraint(equalTo: row.contentView.topAnchor),
            rowContent.leadingAnchor.constraint(equalTo: row.contentView.leadingAnchor),
            rowContent.heightAnchor.constraint(equalTo: row.contentView.heightAnchor),
            // At least as wide as the row, and as wide as the icons need.
            rowContent.widthAnchor.constraint(greaterThanOrEqualTo: row.contentView.widthAnchor),
            { let c = rowContent.widthAnchor.constraint(equalTo: row.contentView.widthAnchor); c.priority = .defaultLow; return c }(),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: rowContent.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: rowContent.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: rowContent.centerYAnchor),
            // When they fit, the icons stay centred under the whole bar, as before (the row itself sits 11 pt
            // right of the bar's centre, because the buttons on the left take more room than + on the right).
            { let c = stack.centerXAnchor.constraint(equalTo: rowContent.centerXAnchor, constant: -11); c.priority = .defaultHigh; return c }(),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var buttons: [SpaceButton] = []

    func reload(_ spaces: [Space], current: Space) {
        // Same spaces in the same order: keep the buttons, so the move of the "current" tint can animate.
        let same = buttons.count == spaces.count && zip(buttons, spaces).allSatisfy { $0.space === $1 }
        if !same {
            stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
            buttons = spaces.map { sp in
                let b = SpaceButton(title: sp.icon, target: self, action: #selector(pick(_:)))
                b.space = sp
                b.menuProvider = menuProvider
                b.isBordered = false
                b.font = .systemFont(ofSize: 14)
                b.wantsLayer = true
                b.layer?.cornerRadius = 7
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 28).isActive = true
                b.heightAnchor.constraint(equalToConstant: 26).isActive = true
                stack.addArrangedSubview(b)
                return b
            }
        }
        for (b, sp) in zip(buttons, spaces) {
            b.title = sp.icon
            b.toolTip = sp.name
            let lit = sp === current
            let tint = NSColor.labelColor.withAlphaComponent(lit ? 0.1 : 0)
            if same {
                Motion.run(0.22, Motion.glide) { b.animator().alphaValue = lit ? 1 : 0.45 }
                Motion.layer(0.22) { b.layer?.backgroundColor = tint.cgColor }
            } else {
                b.alphaValue = lit ? 1 : 0.45
                b.layer?.backgroundColor = tint.cgColor
            }
        }
        layoutSubtreeIfNeeded()
        updateFade()
        if let i = spaces.firstIndex(where: { $0 === current }), !isScrubbing {
            reveal(CGFloat(i), animated: same && window != nil)
        }
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    @objc private func rowScrolled() { updateFade() }

    /// Fades whichever end of the row has more icons beyond it, so it's clear the row scrolls.
    private func updateFade() {
        let w = row.bounds.width
        guard w > 0 else { return }
        let x = row.contentView.bounds.origin.x
        let more = rowContent.frame.width - w - x
        let edge = min(0.5, 14 / w)
        let left: CGFloat = x > 1 ? 0 : 1, right: CGFloat = more > 1 ? 0 : 1
        Motion.layer(0) {
            rowFade.frame = row.bounds
            rowFade.colors = [NSColor.black.withAlphaComponent(left).cgColor, NSColor.black.cgColor,
                              NSColor.black.cgColor, NSColor.black.withAlphaComponent(right).cgColor]
            rowFade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        }
    }

    /// Scrolls the row just enough that the icon at `position` (fractions fall between two icons) is in view,
    /// with a little of its neighbours showing.
    private func reveal(_ position: CGFloat, animated: Bool) {
        guard row.overflows, !buttons.isEmpty else { return }
        let i = max(0, min(buttons.count - 1, Int(position.rounded(.down))))
        let j = min(buttons.count - 1, i + 1)
        let f = max(0, min(1, position - CGFloat(i)))
        let a = buttons[i].convert(buttons[i].bounds, to: rowContent), b = buttons[j].convert(buttons[j].bounds, to: rowContent)
        let midX = a.midX + (b.midX - a.midX) * f
        let margin: CGFloat = 22, w = row.contentView.bounds.width, x = row.contentView.bounds.origin.x
        if midX - margin < x {
            row.scrollRow(toX: midX - margin, animated: animated)
        } else if midX + margin > x + w {
            row.scrollRow(toX: midX + margin - w, animated: animated)
        }
    }

    @objc private func pick(_ sender: SpaceButton) {
        if let sp = sender.space { onSelect?(sp) }
    }

    /// Lights the icons for a position between spaces (during a swipe or scrub): each icon is as lit as it is
    /// close to `position`, so the tint slides from one to the next instead of jumping.
    func show(position p: CGFloat) {
        Motion.layer(0) {
            for (i, b) in buttons.enumerated() {
                let lit = max(0, 1 - abs(CGFloat(i) - p))
                b.layer?.removeAllAnimations()
                b.alphaValue = 0.45 + 0.55 * lit
                b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1 * lit).cgColor
            }
        }
        // A trackpad swipe can head for a space whose icon is scrolled away: bring it along. (While scrubbing
        // the cursor does the steering, and the row scrolls only at its ends.)
        if !isScrubbing { reveal(p, animated: false) }
    }

    /// Where `x` (window coordinates) falls along the icons, in spaces: 0 at the first icon's centre, 1 at the
    /// second's, and running on past either end at the same spacing.
    func position(atWindowX x: CGFloat) -> CGFloat {
        let local = stack.convert(NSPoint(x: x, y: 0), from: nil).x
        let centres = buttons.map { $0.frame.midX }
        guard let first = centres.first else { return 0 }
        guard centres.count > 1 else { return (local - first) / 32 }
        if local <= first { return (local - first) / (centres[1] - first) }
        for i in 1..<centres.count where local <= centres[i] {
            return CGFloat(i - 1) + (local - centres[i - 1]) / (centres[i] - centres[i - 1])
        }
        let n = centres.count
        return CGFloat(n - 1) + (local - centres[n - 1]) / (centres[n - 1] - centres[n - 2])
    }

    private func button(at e: NSEvent) -> SpaceButton? {
        buttons.first { $0.bounds.contains($0.convert(e.locationInWindow, from: nil)) }
    }

    private func press(_ e: NSEvent) {
        pressX = e.locationInWindow.x
        pressed = button(at: e)
        isScrubbing = false
        pressed?.layer?.press()
    }

    private func drag(_ e: NSEvent) {
        if !isScrubbing {
            // A few points of sideways travel turn the press into a scrub; less is still a click.
            guard abs(e.locationInWindow.x - pressX) > 4, buttons.count > 0 else { return }
            isScrubbing = true
            onScrubBegin?()
            startEdgeScroll()
        }
        scrubX = e.locationInWindow.x
        onScrub?(position(atWindowX: scrubX))
    }

    /// While scrubbing with the cursor resting near (or past) either end of an overflowing row, the row keeps
    /// scrolling that way, faster the further out the cursor is, and the scrub follows the icons now under it.
    private func startEdgeScroll() {
        edgeTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.edgeStep() }
        RunLoop.main.add(t, forMode: .common)   // keeps firing during the mouse-tracking loop
        edgeTimer = t
    }

    private func edgeStep() {
        guard isScrubbing, row.overflows else { return }
        let x = row.convert(NSPoint(x: scrubX, y: 0), from: nil).x
        let zone: CGFloat = 24, w = row.bounds.width
        var depth: CGFloat = 0
        if x < zone { depth = -(zone - x) } else if x > w - zone { depth = x - (w - zone) }
        guard depth != 0 else { return }
        let before = row.contentView.bounds.origin.x
        row.scrollRow(by: max(-14, min(14, depth * 0.35)))
        if row.contentView.bounds.origin.x != before { onScrub?(position(atWindowX: scrubX)) }
    }

    private func release(_ e: NSEvent) {
        edgeTimer?.invalidate()
        edgeTimer = nil
        if isScrubbing {
            isScrubbing = false
            onScrubEnd?(position(atWindowX: e.locationInWindow.x))
        } else if let b = pressed, b === button(at: e), let sp = b.space {
            onSelect?(sp)
        }
        pressed = nil
    }

    /// For the swipe test: the window point at the centre of icon `i`, nudged by `dx`.
    func debugPoint(icon i: Int, dx: CGFloat = 0) -> NSPoint {
        guard buttons.indices.contains(i) else { return .zero }
        let b = buttons[i]
        return b.convert(NSPoint(x: b.bounds.midX + dx, y: b.bounds.midY), to: nil)
    }
    var debugStrip: NSView { stack }
    /// For the row test: whether it overflows, how far it's scrolled, and which icons are fully in view.
    var debugRow: String {
        let x = row.contentView.bounds.origin.x, w = row.contentView.bounds.width
        let shown = buttons.indices.filter {
            let f = buttons[$0].convert(buttons[$0].bounds, to: rowContent)
            return f.minX >= x - 0.5 && f.maxX <= x + w + 0.5
        }
        return "overflows=\(row.overflows) scrollX=\(Int(x)) width=\(Int(w)) content=\(Int(rowContent.frame.width)) inView=\(shown.first ?? -1)...\(shown.last ?? -1)"
    }
    var debugRowScroll: NSScrollView { row }
}

private final class ResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow.x) }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Sidebar

final class SidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    weak var controller: MainWindowController?

    /// Shown only while the sidebar floats over the page.
    let floatingBackground = ThemeBackgroundView()
    private let topRow = NSView()
    private var topRowHeight: NSLayoutConstraint!
    private let pill = URLPill()
    private let favorites = FavoritesGrid()
    /// Clips the space page while it slides sideways during a swipe or scrub.
    private let spaceClip = NSView()
    private let spaceContainer = NSView()
    private var spaceOffset: NSLayoutConstraint!
    private var pager: SpacePager!
    private var swipe: SpaceSwipeTracker!
    private let spaceIcon = NSButton(title: "", target: nil, action: nil)
    private let spaceName = NSTextField(labelWithString: "")
    private let outline = SidebarOutline()
    private let scroll = SidebarScroll()
    private let spaceBar = SpaceBar()
    private let handle = ResizeHandle()
    private var backButton: IconButton!
    private var forwardButton: IconButton!
    private var reloadButton: IconButton!

    private let separatorMarker = Marker(.separator)
    private let newTabMarker = Marker(.newTab)
    private var isReloading = false
    private var editingCount = 0
    private var themePopover: NSPopover?

    private let store: Store
    /// Arc's Library, over the sidebar's contents (Library.swift), and the in-progress downloads strip.
    private(set) lazy var library = LibraryView(store: store)
    private let downloadsStrip = DownloadsStrip()
    /// Arc's "update ready" card, just above the space icons (UpdateCard.swift).
    let updateCard = UpdateCard()
    let mediaPlayer = SidebarMediaPlayer()
    private lazy var updateCardBottom = updateCard.bottomAnchor.constraint(equalTo: mediaPlayer.topAnchor, constant: -2)

    /// The Library button, where a starting download's icon flies to (DownloadFlight).
    var downloadsAnchor: DownloadsButton { spaceBar.downloadsButton }

    /// The extensions button, which extension pop-ups attach to.
    var extensionsAnchor: NSView { spaceBar.extensionsButton }

    /// The address box, for editing the address in place.
    var addressAnchor: NSView { pill }

    /// True while something in the sidebar needs it to stay on screen.
    var wantsToStayOpen: Bool {
        editingCount > 0 || (themePopover?.isShown ?? false) || (previewPopover?.isShown ?? false)
            || pager.isActive || spaceBar.isScrubbing
    }

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        build()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(structureChanged), name: .sorrelStructure, object: nil)
        nc.addObserver(self, selector: #selector(selectionChanged(_:)), name: .sorrelSelection, object: nil)
        nc.addObserver(self, selector: #selector(itemChanged(_:)), name: .sorrelItem, object: nil)
        nc.addObserver(self, selector: #selector(spaceChanged(_:)), name: .sorrelSpace, object: nil)
        nc.addObserver(self, selector: #selector(downloadsChanged), name: .sorrelDownloads, object: nil)
        DispatchQueue.main.async { [weak self] in self?.downloadsChanged() }   // remembered downloads show the button at launch
        nc.addObserver(self, selector: #selector(extensionsChanged), name: .sorrelExtensions, object: nil)
        nc.addObserver(self, selector: #selector(extensionActionChanged(_:)), name: .sorrelExtensionAction, object: nil)
        nc.addObserver(self, selector: #selector(extensionTabChanged), name: .sorrelSelection, object: nil)
        reloadAll(animated: false)
        updateCard.isOnScreen = { [weak self] in self?.controller.map { $0.mode != .hidden } ?? true }
        // Hidden, the card takes no room: the strip sits 2 pt above the space bar as before.
        updateCard.onShownChange = { [weak self] on in self?.updateCardBottom.constant = on ? -6 : -2 }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    /// Sideways two-finger swipes anywhere over the sidebar slide between spaces; the tab list's scroll view
    /// offers them here first too (`SidebarScroll.onScroll`).
    override func scrollWheel(with e: NSEvent) {
        if swipe.handle(e) { return }
        super.scrollWheel(with: e)
    }

    // MARK: Building

    private func build() {
        wantsLayer = true
        floatingBackground.cornerRadius = 8
        floatingBackground.alphaValue = 0
        floatingBackground.layer?.borderWidth = 0.5
        floatingBackground.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor

        for v in [floatingBackground, topRow, pill, favorites, spaceClip, library, downloadsStrip, updateCard, mediaPlayer, spaceBar, handle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        spaceClip.wantsLayer = true
        spaceClip.clipsToBounds = true
        spaceContainer.translatesAutoresizingMaskIntoConstraints = false
        spaceClip.addSubview(spaceContainer)
        spaceOffset = spaceContainer.leadingAnchor.constraint(equalTo: spaceClip.leadingAnchor)
        library.isHidden = true
        library.onClose = { [weak self] in self?.closeLibrary() }

        // Top row: sidebar toggle after the window buttons, navigation on the right.
        let toggle = IconButton(symbol: "sidebar.left", size: 14, tooltip: "Hide or show the sidebar") {
            Commands.shared.run("sidebar.toggle")
        }
        backButton = IconButton(symbol: "arrow.left", tooltip: "Back") { Commands.shared.run("nav.back") }
        forwardButton = IconButton(symbol: "arrow.right", tooltip: "Forward") { Commands.shared.run("nav.forward") }
        reloadButton = IconButton(symbol: "arrow.clockwise", tooltip: "Reload") { Commands.shared.run("tab.reload") }
        for b in [toggle, backButton!, forwardButton!, reloadButton!] {
            topRow.addSubview(b)
            b.centerYAnchor.constraint(equalTo: topRow.centerYAnchor).isActive = true
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        topRowHeight = topRow.heightAnchor.constraint(equalToConstant: 40)

        // Space header
        spaceIcon.isBordered = false
        spaceIcon.font = .systemFont(ofSize: 14)
        spaceIcon.target = self
        spaceIcon.action = #selector(showSpaceMenuFromHeader)
        spaceIcon.toolTip = "Space options"
        spaceName.font = .systemFont(ofSize: 12, weight: .semibold)
        spaceName.textColor = .secondaryLabelColor
        spaceName.lineBreakMode = .byTruncatingTail
        spaceName.delegate = self
        spaceName.focusRingType = .none
        spaceContainer.wantsLayer = true
        for v in [spaceIcon, spaceName, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            spaceContainer.addSubview(v)
        }

        // Outline
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
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.registerForDraggedTypes([itemDragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        pager = SpacePager(clip: spaceClip, page: spaceContainer, offset: spaceOffset)
        pager.onPosition = { [weak self] p in self?.spaceBar.show(position: p) }
        pager.onTheme = { [weak self] a, b, f in self?.controller?.blendTheme(a, b, f) }
        pager.onDone = { [weak self] in self?.controller?.applyTheme(animated: false) }
        swipe = SpaceSwipeTracker(pager: pager)
        swipe.canStart = { [weak self] in self?.library.isHidden ?? false }
        scroll.onScroll = { [weak self] e in self?.swipe.handle(e) ?? false }

        pill.onClick = { Commands.shared.run("tab.editURL") }
        pill.onCopy = { Commands.shared.run("tab.copyURL") }
        extensionsChanged()
        favorites.heightConstraint = favorites.heightAnchor.constraint(equalToConstant: 0)
        favorites.onClick = { [weak self] in self?.store.select($0) }
        favorites.menuProvider = { [weak self] in self?.menu(for: $0) ?? NSMenu() }
        favorites.onDropItem = { [weak self] id in
            guard let self, let item = self.store.item(id: id), !self.store.isFavorite(item) else { return }
            self.store.move(item, to: .favorites)
        }
        spaceBar.onSelect = { [weak self] in self?.store.switchSpace(to: $0) }
        spaceBar.onScrubBegin = { [weak self] in self?.pager.grab() }
        spaceBar.onScrub = { [weak self] p in self?.pager.follow(p) }
        spaceBar.onScrubEnd = { [weak self] p in
            guard let self else { return }
            self.pager.release(to: Int(max(0, p).rounded()), velocity: nil)
        }
        spaceBar.menuProvider = { [weak self] in self?.menu(for: $0) ?? NSMenu() }
        spaceBar.onAdd = { [weak self] anchor in self?.showAddMenu(from: anchor) }
        spaceBar.onExtensions = { [weak self] anchor in self?.showExtensionsMenu(from: anchor) }
        spaceBar.onDownloads = { [weak self] _ in self?.toggleLibrary() }
        spaceBar.downloadsButton.onHover = { [weak self] on in self?.hoverPreview(on) }
        handle.onDrag = { [weak self] x in self?.controller?.resizeSidebar(to: x) }

        NSLayoutConstraint.activate([
            floatingBackground.topAnchor.constraint(equalTo: topAnchor),
            floatingBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            floatingBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            floatingBackground.trailingAnchor.constraint(equalTo: trailingAnchor),

            topRow.topAnchor.constraint(equalTo: topAnchor),
            topRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            topRowHeight,
            toggle.leadingAnchor.constraint(equalTo: topRow.leadingAnchor, constant: 78),
            reloadButton.trailingAnchor.constraint(equalTo: topRow.trailingAnchor, constant: -10),
            forwardButton.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -2),
            backButton.trailingAnchor.constraint(equalTo: forwardButton.leadingAnchor, constant: -2),

            pill.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 4),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            pill.heightAnchor.constraint(equalToConstant: 34),

            favorites.topAnchor.constraint(equalTo: pill.bottomAnchor, constant: 8),
            favorites.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            favorites.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            favorites.heightConstraint,

            spaceClip.topAnchor.constraint(equalTo: favorites.bottomAnchor, constant: 8),
            spaceClip.leadingAnchor.constraint(equalTo: leadingAnchor),
            spaceClip.trailingAnchor.constraint(equalTo: trailingAnchor),
            spaceClip.bottomAnchor.constraint(equalTo: downloadsStrip.topAnchor, constant: -4),
            spaceContainer.topAnchor.constraint(equalTo: spaceClip.topAnchor),
            spaceContainer.bottomAnchor.constraint(equalTo: spaceClip.bottomAnchor),
            spaceContainer.widthAnchor.constraint(equalTo: spaceClip.widthAnchor),
            spaceOffset,

            library.topAnchor.constraint(equalTo: topRow.bottomAnchor, constant: 2),
            library.leadingAnchor.constraint(equalTo: leadingAnchor),
            library.trailingAnchor.constraint(equalTo: trailingAnchor),
            // To the space bar, not the strip: the strip steps aside while the Library is open, and the Library
            // must not resize when it does.
            library.bottomAnchor.constraint(equalTo: spaceBar.topAnchor, constant: -4),

            downloadsStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            downloadsStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            downloadsStrip.bottomAnchor.constraint(equalTo: updateCard.topAnchor),

            updateCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            updateCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            updateCardBottom,
            mediaPlayer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mediaPlayer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mediaPlayer.bottomAnchor.constraint(equalTo: spaceBar.topAnchor, constant: -4),

            spaceIcon.topAnchor.constraint(equalTo: spaceContainer.topAnchor, constant: 2),
            spaceIcon.leadingAnchor.constraint(equalTo: spaceContainer.leadingAnchor, constant: 14),
            spaceIcon.widthAnchor.constraint(equalToConstant: 24),
            spaceIcon.heightAnchor.constraint(equalToConstant: 22),
            spaceName.leadingAnchor.constraint(equalTo: spaceIcon.trailingAnchor, constant: 4),
            spaceName.centerYAnchor.constraint(equalTo: spaceIcon.centerYAnchor),
            spaceName.trailingAnchor.constraint(lessThanOrEqualTo: spaceContainer.trailingAnchor, constant: -14),

            scroll.topAnchor.constraint(equalTo: spaceIcon.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: spaceContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: spaceContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: spaceContainer.bottomAnchor),

            spaceBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            spaceBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            spaceBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            spaceBar.heightAnchor.constraint(equalToConstant: 30),

            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 3),
            handle.widthAnchor.constraint(equalToConstant: 7),
        ])
    }

    /// Floating = hovering over the page with its own background, instead of sitting beside it.
    func setFloating(_ floating: Bool) {
        floatingBackground.animator().alphaValue = floating ? 1 : 0
        topRowHeight.animator().constant = floating ? 24 : 40
        handle.isHidden = floating
        if floating {
            let s = NSShadow()
            s.shadowBlurRadius = 24
            s.shadowOffset = NSSize(width: 0, height: -6)
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow = s
        } else {
            shadow = nil
        }
    }

    func applyTheme(_ theme: Theme) {
        floatingBackground.apply(theme)
        appearance = NSAppearance(named: theme.isDark(systemIsDark: systemIsDark()) ? .darkAqua : .aqua)
        spaceBar.reload(store.spaces, current: store.currentSpace)
    }

    // MARK: Reloading

    @objc private func structureChanged() { reloadOutline() }

    func reloadForWindow() { reloadAll(animated: false) }

    func prepareForClose() {
        pager.cancel()
        previewWatch?.invalidate()
        previewPopover?.close()
        themePopover?.close()
        library.didDisappear()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func selectionChanged(_ note: Notification) {
        if let source = note.object as? Store, source !== store { return }
        refreshSelection()
        refreshNavigation()
    }

    @objc private func spaceChanged(_ note: Notification) {
        if let source = note.object as? Store, source !== store { return }
        reloadAll(animated: true)
    }

    @objc private func itemChanged(_ note: Notification) {
        guard let item = note.object as? Item else { return }
        let row = outline.row(forItem: item)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCell {
            cell.configure(item, level: outline.level(forRow: row))
        }
        if let sv = store.split(containing: item) { refreshSplitRow(sv) }
        if store.isFavorite(item) { favorites.refresh(selected: store.selected) }
        if item === store.selected { refreshNavigation() }
    }

    private var shownSpaceID: UUID?

    func reloadAll(animated: Bool) {
        let sp = store.currentSpace
        // A swipe or scrub already slid the new space in by hand: no second slide on top.
        if animated, !pager.isActive, shownSpaceID != nil, shownSpaceID != sp.id, let layer = spaceContainer.layer {
            let t = CATransition()
            t.type = .push
            t.subtype = store.lastSwitchDirection > 0 ? .fromRight : .fromLeft
            t.duration = Motion.reduced ? 0.15 : 0.3
            t.timingFunction = Motion.settle
            if Motion.reduced { t.type = .fade }
            layer.add(t, forKey: "space")
        }
        shownSpaceID = sp.id
        spaceIcon.title = sp.icon
        spaceName.stringValue = sp.name + (sp.profileID != nil ? "  ·  separate logins" : "")
        spaceBar.reload(store.spaces, current: sp)
        reloadOutline()
        refreshNavigation()
    }

    /// What the outline showed last time, so a new or closed tab can slide in or out instead of the whole
    /// list being redrawn. Top level = pinned tabs, the two markers, today's tabs.
    private var shownTop: [NSObject] = []
    private var shownFolderChildren: [ObjectIdentifier: [Item]] = [:]
    private var shownOutlineSpace: UUID?

    private func topLevel(of sp: Space) -> [NSObject] { sp.pinned + [separatorMarker, newTabMarker] + sp.today }

    private func folderChildren(of sp: Space) -> [ObjectIdentifier: [Item]] {
        var out: [ObjectIdentifier: [Item]] = [:]
        func walk(_ items: [Item]) {
            for i in items where i.isFolder {
                out[ObjectIdentifier(i)] = i.children
                walk(i.children)
            }
        }
        walk(sp.pinned)
        walk(sp.today)
        return out
    }

    /// Rows removed from `old` and rows added in `new`, when that is all that happened (nothing moved).
    private func simpleDiff(old: [NSObject], new: [NSObject]) -> (removed: IndexSet, inserted: IndexSet)? {
        let newSet = Set(new.map(ObjectIdentifier.init)), oldSet = Set(old.map(ObjectIdentifier.init))
        var removed = IndexSet(), inserted = IndexSet()
        for (i, o) in old.enumerated() where !newSet.contains(ObjectIdentifier(o)) { removed.insert(i) }
        for (i, o) in new.enumerated() where !oldSet.contains(ObjectIdentifier(o)) { inserted.insert(i) }
        let keptOld = old.enumerated().filter { !removed.contains($0.offset) }.map { $0.element }
        let keptNew = new.enumerated().filter { !inserted.contains($0.offset) }.map { $0.element }
        guard keptOld.count == keptNew.count, zip(keptOld, keptNew).allSatisfy({ $0 === $1 }) else { return nil }
        return (removed, inserted)
    }

    private func reloadOutline() {
        let sp = store.currentSpace
        let newTop = topLevel(of: sp)
        let newFolders = folderChildren(of: sp)
        let foldersSame = newFolders.count == shownFolderChildren.count && newFolders.allSatisfy { key, kids in
            guard let old = shownFolderChildren[key], old.count == kids.count else { return false }
            return zip(old, kids).allSatisfy { $0 === $1 }
        }
        isReloading = true
        if window != nil, shownOutlineSpace == sp.id, foldersSame,
           let diff = simpleDiff(old: shownTop, new: newTop), !(diff.removed.isEmpty && diff.inserted.isEmpty) {
            // Only rows came or went: slide them, and leave every other row (and its hover) as it is.
            let effect: NSTableView.AnimationOptions = Motion.reduced ? .effectFade : [.slideDown, .effectFade]
            outline.beginUpdates()
            if !diff.removed.isEmpty {
                outline.removeItems(at: diff.removed, inParent: nil, withAnimation: Motion.reduced ? .effectFade : [.slideUp, .effectFade])
            }
            if !diff.inserted.isEmpty { outline.insertItems(at: diff.inserted, inParent: nil, withAnimation: effect) }
            outline.endUpdates()
        } else {
            outline.reloadData()
            func expand(_ items: [Item]) {
                for i in items where i.isFolder {
                    if i.expanded {
                        outline.expandItem(i)
                        expand(i.children)
                    }
                }
            }
            expand(sp.pinned)
        }
        isReloading = false
        shownTop = newTop
        shownFolderChildren = newFolders
        shownOutlineSpace = sp.id
        favorites.reload(store.favorites, selected: store.selected)
        refreshSelection()
    }

    private func refreshSelection() {
        let sel = store.selected
        // A split view's row is lit while any of its tabs is the one in focus.
        let lit = sel.map { store.unit($0) }
        outline.enumerateAvailableRowViews { rowView, row in
            let obj = self.outline.item(atRow: row) as? Item
            (rowView as? SidebarRowView)?.isActive = obj === lit && lit != nil
            if let obj, obj.isSplit {
                (self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SplitCell)?
                    .configure(obj, level: self.outline.level(forRow: row), focused: obj === lit ? sel : nil)
            }
        }
        favorites.refresh(selected: sel)
    }

    private func refreshSplitRow(_ sv: Item) {
        let row = outline.row(forItem: sv)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SplitCell else { return }
        let sel = store.selected
        cell.configure(sv, level: outline.level(forRow: row), focused: sel.map { store.unit($0) } === sv ? sel : nil)
    }

    private func refreshNavigation() {
        let item = store.selected
        let wv = item?.page?.webView
        backButton.isEnabled = wv?.canGoBack ?? false
        forwardButton.isEnabled = wv?.canGoForward ?? false
        reloadButton.isEnabled = item != nil
        if let u = item?.url, u.hasPrefix("sorrel://") {
            pill.set("Sorrel", canCopy: false)
        } else {
            pill.set(Site.display(item?.host) ?? item?.url,
                     canCopy: item?.url?.hasPrefix("http") ?? false,
                     insecure: item?.host != nil && item?.url?.lowercased().hasPrefix("http://") == true)
        }
    }

    // MARK: Outline data

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let folder = item as? Item { return folder.children.count }
        let sp = store.currentSpace
        return sp.pinned.count + 2 + sp.today.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let folder = item as? Item { return folder.children[index] }
        let sp = store.currentSpace
        let p = sp.pinned.count
        if index < p { return sp.pinned[index] }
        if index == p { return separatorMarker }
        if index == p + 1 { return newTabMarker }
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
        let id = NSUserInterfaceItemIdentifier("row")
        let row = (outlineView.makeView(withIdentifier: id, owner: self) as? SidebarRowView) ?? {
            let r = SidebarRowView()
            r.identifier = id
            return r
        }()
        if let m = item as? Marker {
            row.highlightable = m.kind == .newTab
            row.isActive = false
        } else {
            row.highlightable = true
            let lit = store.selected.map { store.unit($0) }
            row.isActive = (item as? Item) === lit && lit != nil
        }
        row.onHover = { [weak row] hovered in
            guard let row, row.numberOfColumns > 0 else { return }
            (row.view(atColumn: 0) as? ItemCell)?.setHovered(hovered)
            (row.view(atColumn: 0) as? SplitCell)?.setHovered(hovered)
        }
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let m = item as? Marker {
            switch m.kind {
            case .separator:
                let id = NSUserInterfaceItemIdentifier("separator")
                let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? SeparatorCell) ?? {
                    let c = SeparatorCell()
                    c.identifier = id
                    return c
                }()
                cell.clear.isHidden = store.currentSpace.today.isEmpty
                cell.onClear = { [weak self] in
                    guard let self else { return }
                    self.store.clearToday(in: self.store.currentSpace)
                }
                return cell
            case .newTab:
                let id = NSUserInterfaceItemIdentifier("newtab")
                return (outlineView.makeView(withIdentifier: id, owner: self) as? NewTabCell) ?? {
                    let c = NewTabCell()
                    c.identifier = id
                    return c
                }()
            }
        }
        guard let it = item as? Item else { return nil }
        if it.isSplit {
            let sid = NSUserInterfaceItemIdentifier("split")
            let cell = (outlineView.makeView(withIdentifier: sid, owner: self) as? SplitCell) ?? {
                let c = SplitCell()
                c.identifier = sid
                return c
            }()
            let sel = store.selected
            cell.configure(it, level: outlineView.level(forItem: it), focused: sel.map { store.unit($0) } === it ? sel : nil)
            cell.setHovered(false)
            cell.onClose = { [weak self] sv in
                guard let self else { return }
                // A pinned split view that is fully asleep shows "×": take it out of the sidebar.
                if self.store.isPinned(sv), !sv.children.contains(where: { $0.page != nil }) {
                    self.store.closeAndUnpin(sv)
                } else {
                    self.store.close(sv)   // pinned: puts every pane to sleep; unpinned: closes it
                }
            }
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("item")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? ItemCell) ?? {
            let c = ItemCell()
            c.identifier = id
            return c
        }()
        cell.configure(it, level: outlineView.level(forItem: it))
        cell.setHovered(false)
        cell.onClose = { [weak self] item in
            guard let self else { return }
            // A pinned tab that is already asleep shows "×": take it out of the sidebar.
            if !item.isContainer, self.store.isPinned(item), item.page == nil {
                self.store.closeAndUnpin(item)
            } else {
                self.store.close(item)   // pinned and loaded: unload; unpinned: close
            }
        }
        cell.onRename = { [weak self] item, name in self?.store.rename(item, to: name) }
        cell.onEditingChanged = { [weak self] editing in self?.editingCount += editing ? 1 : -1 }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) { folderToggled(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { folderToggled(notification, expanded: false) }

    private func folderToggled(_ note: Notification, expanded: Bool) {
        guard !isReloading, let folder = note.userInfo?["NSObject"] as? Item else { return }
        store.setExpanded(folder, expanded)
        let row = outline.row(forItem: folder)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCell {
            cell.configure(folder, level: outline.level(forRow: row))
        }
        refreshSelection()
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let obj = outline.item(atRow: row)
        if let m = obj as? Marker {
            if m.kind == .newTab { Commands.shared.run("tab.new") }
            return
        }
        guard let item = obj as? Item else { return }
        if item.isSplit {
            // Each tab has its own part of the row: clicking one focuses that pane.
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SplitCell,
               let event = NSApp.currentEvent {
                store.select(cell.member(at: cell.convert(event.locationInWindow, from: nil)) ?? item)
            } else {
                store.select(item)
            }
            return
        }
        if item.isFolder {
            if outline.isItemExpanded(item) {
                outline.animator().collapseItem(item)
            } else {
                outline.animator().expandItem(item)
            }
        } else {
            store.select(item)
        }
    }

    @objc private func rowDoubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let item = outline.item(atRow: row) as? Item, item.isFolder else { return }
        beginRename(item)
    }

    func beginRename(_ item: Item) {
        let row = outline.row(forItem: item)
        guard row >= 0 else { return }
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ItemCell)?.beginRename()
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        let built: NSMenu
        if row >= 0, let item = outline.item(atRow: row) as? Item {
            built = self.menu(for: item)
        } else {
            built = spaceAreaMenu()
        }
        for i in built.items {
            built.removeItem(i)
            menu.addItem(i)
        }
    }

    /// Right-click on the space itself (anywhere that is not a tab or folder).
    func spaceAreaMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionMenuItem("Customize Space…") { [weak self] in self?.showThemeEditor() })
        m.addItem(.separator())
        m.addItem(ActionMenuItem("New Tab") { Commands.shared.run("tab.new") })
        m.addItem(ActionMenuItem("New Folder") { Commands.shared.run("folder.new") })
        m.addItem(ActionMenuItem("New Space") { Commands.shared.run("space.new") })
        return m
    }

    override func menu(for event: NSEvent) -> NSMenu? { spaceAreaMenu() }

    func menu(for item: Item) -> NSMenu {
        let m = NSMenu()
        if item.isFolder {
            m.addItem(ActionMenuItem("New Folder Inside") { [weak self] in
                guard let self else { return }
                let f = self.store.addFolder(parent: item)
                DispatchQueue.main.async { self.beginRename(f) }
            })
            m.addItem(ActionMenuItem("Rename…") { [weak self] in self?.beginRename(item) })
            m.addItem(.separator())
            m.addItem(ActionMenuItem("Remove Folder (Keep Tabs)") { [weak self] in self?.store.ungroup(item) })
            return m
        }
        if item.isSplit { return splitMenu(for: item) }

        let fav = store.isFavorite(item)
        let pinned = store.isPinned(item)
        if let entry = splitMenuItem(for: item) {
            m.addItem(entry)
            m.addItem(.separator())
        }
        m.addItem(ActionMenuItem("Copy Link") {
            guard let u = item.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(u, forType: .string)
        })
        m.addItem(ActionMenuItem("Duplicate") { [weak self] in
            guard let self, let u = item.url else { return }
            self.store.newTab(url: u, title: item.title, in: self.store.space(containing: item))
        })
        m.addItem(.separator())
        if !fav {
            m.addItem(ActionMenuItem(pinned ? "Unpin Tab" : "Pin Tab") { [weak self] in self?.store.togglePin(item) })
        }
        m.addItem(ActionMenuItem(fav ? "Remove from Favorites" : "Add to Favorites") { [weak self] in
            self?.store.toggleFavorite(item)
        })
        if !fav, store.spaces.count > 1 {
            let sub = NSMenu()
            let home = store.space(containing: item)
            for sp in store.spaces where sp !== home {
                sub.addItem(ActionMenuItem("\(sp.icon)  \(sp.name)") { [weak self] in self?.store.moveToSpace(item, sp) })
            }
            let parent = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            parent.submenu = sub
            m.addItem(parent)
        }
        if !fav {
            m.addItem(ActionMenuItem("Rename…") { [weak self] in self?.beginRename(item) })
        }
        if fav || pinned {
            if let home = item.pinnedURL, home != item.url {
                m.addItem(ActionMenuItem("Go Back to Pinned Page") { [weak self] in
                    item.url = home
                    if let page = item.page { Engine.shared.load(home, in: page) }
                    self?.store.itemChanged(item)
                })
                m.addItem(ActionMenuItem("Pin This Page Instead") { [weak self] in
                    item.pinnedURL = item.url
                    self?.store.itemChanged(item)
                })
            }
        }
        m.addItem(.separator())
        // Zen's unload: an unpinned tab can sleep too (it stays in the sidebar), as long as it isn't on screen.
        if !(fav || pinned), item.page != nil, !store.visibleTabs.contains(where: { $0 === item }) {
            let sleep = ActionMenuItem("Put Tab to Sleep") { [weak self] in self?.store.sleepTabs([item]) }
            sleep.isEnabled = store.canSleep(item)
            m.addItem(sleep)
        }
        let others = store.tabs(inSpace: store.space(containing: item) ?? store.currentSpace).filter { $0 !== item }
        let otherSleep = ActionMenuItem("Put Other Tabs to Sleep") { [weak self] in
            guard let self else { return }
            let n = self.store.sleepTabs(others)
            self.controller?.showToast(n == 0 ? "The other tabs are already asleep" : "\(n) tab\(n == 1 ? "" : "s") asleep")
        }
        otherSleep.isEnabled = others.contains { $0.page != nil }
        m.addItem(otherSleep)
        m.addItem(ActionMenuItem((fav || pinned) ? "Put Tab to Sleep" : "Close Tab") { [weak self] in
            self?.store.close(item)
        })
        if pinned {
            m.addItem(ActionMenuItem("Close and Unpin") { [weak self] in self?.store.closeAndUnpin(item) })
        }
        return m
    }

    /// "Open in Split View": beside the tab on screen, or beside any other tab in this space.
    private func splitMenuItem(for item: Item) -> NSMenuItem? {
        guard store.canSplit(item) else { return nil }
        let sel = store.selected
        let others = store.cycleOrder.filter {
            $0 !== item && store.canSplit($0) && (store.split(containing: $0).map { $0 !== store.split(containing: item) } ?? true)
        }
        let sub = NSMenu()
        if let sel, sel !== item, store.canSplit(sel), store.split(containing: sel) !== store.split(containing: item) || store.split(containing: sel) == nil {
            sub.addItem(ActionMenuItem("Beside Current Tab") { [weak self] in self?.controller?.splitSelected(with: item) })
            sub.addItem(ActionMenuItem("Beside Current Tab, Stacked") { [weak self] in
                self?.controller?.splitSelected(with: item, side: .bottom)
            })
            if !others.isEmpty { sub.addItem(.separator()) }
        }
        for other in others.prefix(15) where other !== sel {
            let entry = ActionMenuItem("With \(String(other.displayTitle.prefix(40)))") { [weak self] in
                guard let self else { return }
                if self.store.makeSplit(other, with: item) == nil, let c = self.controller {
                    c.showToast(c.splitRefusal(other, item))
                }
            }
            if let icon = FaviconStore.shared.image(for: other)?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
            }
            sub.addItem(entry)
        }
        guard !sub.items.isEmpty else { return nil }
        let parent = NSMenuItem(title: store.split(containing: item) == nil ? "Open in Split View" : "Move to Another Split View",
                                action: nil, keyEquivalent: "")
        parent.submenu = sub
        return parent
    }

    private func splitMenu(for sv: Item) -> NSMenu {
        let m = NSMenu()
        let stacked = sv.split?.stacked ?? false
        m.addItem(ActionMenuItem("Separate Split View") { [weak self] in self?.store.unsplit(sv) })
        m.addItem(ActionMenuItem(stacked ? "Show Side by Side" : "Show Stacked") { [weak self] in
            self?.store.setSplitStacked(sv, !stacked)
        })
        m.addItem(ActionMenuItem(sv.children.count == 2 ? "Swap Panes" : "Rotate Panes") { [weak self] in
            self?.store.rotatePanes(sv)
        })
        let remove = NSMenu()
        for t in sv.children {
            remove.addItem(ActionMenuItem(String(t.displayTitle.prefix(40))) { [weak self] in self?.store.removeFromSplit(t) })
        }
        let removeParent = NSMenuItem(title: "Remove from Split View", action: nil, keyEquivalent: "")
        removeParent.submenu = remove
        m.addItem(removeParent)
        m.addItem(.separator())
        let pinned = store.isPinned(sv)
        m.addItem(ActionMenuItem(pinned ? "Unpin Split View" : "Pin Split View") { [weak self] in self?.store.togglePin(sv) })
        if store.spaces.count > 1 {
            let sub = NSMenu()
            let home = store.space(containing: sv)
            for sp in store.spaces where sp !== home {
                sub.addItem(ActionMenuItem("\(sp.icon)  \(sp.name)") { [weak self] in self?.store.moveToSpace(sv, sp) })
            }
            let parent = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
            parent.submenu = sub
            m.addItem(parent)
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem(pinned ? "Put Split View to Sleep" : "Close Split View") { [weak self] in
            self?.store.close(sv)
        })
        return m
    }

    func menu(for space: Space) -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionMenuItem("Customize Space…") { [weak self] in
            self?.store.switchSpace(to: space)
            self?.showThemeEditor()
        })
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Keep Separate Logins", checked: space.profileID != nil) { [weak self] in
            self?.store.setSeparateLogins(space.profileID == nil, for: space)
        })
        let sleep = ActionMenuItem("Put Tabs in This Space to Sleep") { [weak self] in
            guard let self else { return }
            let n = self.store.sleepTabs(self.store.tabs(inSpace: space))
            self.controller?.showToast(n == 0 ? "No tabs here to put to sleep" : "\(n) tab\(n == 1 ? "" : "s") asleep")
        }
        sleep.isEnabled = store.tabs(inSpace: space).contains { $0.page != nil }
        m.addItem(sleep)
        m.addItem(.separator())
        let del = ActionMenuItem("Delete Space…") { [weak self] in self?.confirmDelete(space) }
        del.isEnabled = store.spaces.count > 1
        m.addItem(del)
        return m
    }

    @objc private func showSpaceMenuFromHeader() {
        let m = menu(for: store.currentSpace)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: spaceIcon.bounds.height + 4), in: spaceIcon)
    }

    @objc private func extensionsChanged() {
        pill.setExtensions(Extensions.shared.loaded) { [weak self] entry in self?.menu(forExtension: entry) ?? NSMenu() }
    }

    @objc private func extensionActionChanged(_ note: Notification) {
        pill.refreshExtensionStates(only: (note.object as? ExtensionEntry)?.id)
    }

    /// Extension buttons are per tab, so a different tab can mean different icons and badges.
    @objc private func extensionTabChanged() { pill.refreshExtensionStates() }

    private func menu(forExtension entry: ExtensionEntry) -> NSMenu {
        let m = NSMenu()
        m.addItem(ActionMenuItem("Open \(entry.name)") { Extensions.shared.performAction(entry) })
        Self.addExtensionItems(to: m, for: entry)
        if entry.context?.optionsPageURL != nil {
            m.addItem(ActionMenuItem("\(entry.name) Settings") { Extensions.shared.openOptions(entry) })
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Manage Extensions…") { Commands.shared.run("extensions.manage") })
        return m
    }

    /// The extension's own menu items for the selected tab, and its keyboard shortcuts (shown with their keys),
    /// as WebKit hands them out ready to perform.
    static func addExtensionItems(to m: NSMenu, for entry: ExtensionEntry) {
        let own = Extensions.shared.action(for: entry)?.menuItems ?? []
        if !own.isEmpty {
            m.addItem(.separator())
            for item in own { m.addItem(item) }
        }
        let commands = Extensions.shared.commands(for: entry)
        if !commands.isEmpty {
            m.addItem(.separator())
            for command in commands { m.addItem(command.menuItem) }
        }
    }

    /// Where an extension's pop-up should open from: its icon in the address box, or the extensions button.
    func extensionAnchor(for entry: ExtensionEntry?) -> NSView {
        entry.flatMap { pill.extensionButton(id: $0.id) } ?? extensionsAnchor
    }

    @objc private func downloadsChanged() {
        spaceBar.downloadsButton.update(Engine.shared.downloads)
    }

    // MARK: Library and downloads

    var isLibraryOpen: Bool { !library.isHidden }

    /// The Library button: opens the Library over the sidebar, or closes it. A section name switches to it.
    func toggleLibrary(_ section: LibraryView.Section? = nil) {
        spaceBar.downloadsButton.cancelHover()
        previewPopover?.close()
        if isLibraryOpen, section == nil || section == library.section {
            closeLibrary()
        } else {
            openLibrary(section ?? library.section)
        }
    }

    /// Slides the Library in over the address box, favorites and tabs, which fade away beneath it.
    func openLibrary(_ section: LibraryView.Section) {
        library.show(section)
        guard !isLibraryOpen else { return }
        downloadsStrip.isSuppressed = true
        mediaPlayer.isSuppressed = true
        updateCard.isSuppressed = true
        for v in [pill, favorites, spaceContainer] as [NSView] { v.fade(in: false, duration: 0.16) }
        library.fade(in: true, duration: 0.2)
        library.layer?.popIn(scale: 0.98, rise: 6, fade: false, duration: 0.28)
        library.didAppear()
    }

    func closeLibrary() {
        guard isLibraryOpen else { return }
        library.didDisappear()
        downloadsStrip.isSuppressed = false
        mediaPlayer.isSuppressed = false
        updateCard.isSuppressed = false
        library.fade(in: false, duration: 0.14)
        for v in [pill, favorites, spaceContainer] as [NSView] { v.fade(in: true, duration: 0.2) }
    }

    private var previewPopover: NSPopover?
    private var previewWatch: Timer?

    /// Hovering the Library button shows the latest downloads above it, as Arc does. It stays while the cursor
    /// is on the button or the preview, and goes once it is on neither.
    private func hoverPreview(_ on: Bool) {
        guard on else { return }   // leaving is handled by the watch below, so the cursor can move into the preview
        guard previewPopover?.isShown != true, !isLibraryOpen, !Engine.shared.downloads.isEmpty, window != nil else { return }
        let anchor = spaceBar.downloadsButton!
        let pop = NSPopover()
        pop.behavior = .semitransient
        pop.animates = true
        let preview = DownloadsPreview()
        preview.onClose = { [weak pop] in pop?.close() }
        pop.contentViewController = preview
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        previewPopover = pop
        previewWatch?.invalidate()
        var outsideSince: Date?
        previewWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak pop] timer in
            guard let self, let pop, pop.isShown else { timer.invalidate(); return }
            let mouse = NSEvent.mouseLocation
            let onButton = anchor.window.map { w in
                w.convertToScreen(anchor.convert(anchor.bounds, to: nil)).insetBy(dx: -4, dy: -4).contains(mouse)
            } ?? false
            let onPreview = pop.contentViewController?.view.window?.frame.insetBy(dx: -6, dy: -6).contains(mouse) ?? false
            if onButton || onPreview { outsideSince = nil; return }
            let since = outsideSince ?? Date()
            outsideSince = since
            if Date().timeIntervalSince(since) > 0.3 { pop.close(); timer.invalidate(); self.previewWatch = nil }
        }
    }

    /// Test hooks: the Library, the hover preview and the button, as seen by tests.
    var debugDownloadsRing: String { spaceBar.downloadsButton.debugRing }
    var debugPreview: DownloadsPreview? { previewPopover?.contentViewController as? DownloadsPreview }
    var debugStripRows: [String] { ["height=\(Int(downloadsStrip.debugHeight))"] + downloadsStrip.rows.map { $0.debugDescription_ } }
    func debugShowPreview() { hoverPreview(true) }

    func showExtensionsMenu(from anchor: NSView? = nil) {
        let anchor = anchor ?? extensionsAnchor
        let m = NSMenu()
        let loaded = Extensions.shared.loaded
        if loaded.isEmpty {
            let none = NSMenuItem(title: "No Extensions Turned On", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for entry in loaded {
            let live = Extensions.shared.action(for: entry, in: (window?.windowController as? MainWindowController)?.store.selected)
            let badge = live?.badgeText ?? ""
            let item = ActionMenuItem(entry.name + (badge.isEmpty ? "" : "  (\(badge))")) { Extensions.shared.performAction(entry) }
            if let icon = live?.icon(for: NSSize(width: 16, height: 16)) ?? entry.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            item.isEnabled = live?.isEnabled ?? true
            live?.hasUnreadBadgeText = false
            if let first = Extensions.shared.commands(for: entry).first(where: { $0.id == "_execute_action" }),
               let key = first.activationKey, !key.isEmpty {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = first.modifierFlags
            }
            m.addItem(item)
        }
        let withOptions = loaded.filter { $0.context?.optionsPageURL != nil }
        if !withOptions.isEmpty {
            m.addItem(.separator())
            for entry in withOptions {
                m.addItem(ActionMenuItem("\(entry.name) Settings") { Extensions.shared.openOptions(entry) })
            }
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Manage Extensions…") { Commands.shared.run("extensions.manage") })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func showAddMenu(from anchor: NSView) {
        let m = NSMenu()
        m.addItem(ActionMenuItem("New Space") { Commands.shared.run("space.new") })
        m.addItem(ActionMenuItem("New Folder") { Commands.shared.run("folder.new") })
        m.addItem(ActionMenuItem("New Tab") { Commands.shared.run("tab.new") })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func confirmDelete(_ space: Space) {
        guard let window else { return }
        let count = store.tabs(in: space.pinned).count + space.today.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(space.name)”?"
        alert.informativeText = count == 0 ? "This space has no tabs."
            : "Its \(count) tab\(count == 1 ? "" : "s") and folders will be removed. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.store.removeSpace(space) }
        }
    }

    func showThemeEditor(focusName: Bool = false) {
        themePopover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = ThemeEditor(space: store.currentSpace, focusName: focusName)
        pop.show(relativeTo: spaceIcon.bounds, of: spaceIcon, preferredEdge: .maxX)
        themePopover = pop
    }

    /// Test hook: the Customize panel's contents.
    var debugCustomizeView: NSView? { themePopover?.contentViewController?.view }
    var debugThemeEditor: ThemeEditor? { themePopover?.contentViewController as? ThemeEditor }

    /// Test hook: drives the emoji sheet inside the Customize panel.
    func debugEmojiTest(_ mode: String, log: @escaping (String) -> Void) {
        (themePopover?.contentViewController as? ThemeEditor)?.debugEmojiTest(mode, log: log)
    }

    /// A new space opens straight into its name, icon and colors.
    func renameCurrentSpace() { showThemeEditor(focusName: true) }

    func createFolderAndRename() {
        let f = store.addFolder()
        DispatchQueue.main.async { self.beginRename(f) }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let it = item as? Item else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(it.id.uuidString, forType: itemDragType)
        return pb
    }

    private func dragged(_ info: NSDraggingInfo) -> Item? {
        guard let s = info.draggingPasteboard.string(forType: itemDragType), let id = UUID(uuidString: s) else { return nil }
        return store.item(id: id)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let dragged = dragged(info) else { return [] }
        let sp = store.currentSpace
        let p = sp.pinned.count

        if item == nil {
            if index < 0 { return dragged.isFolder ? [] : .move }
            if index > p, dragged.isFolder { return [] }       // folders live with the pinned tabs
            if index == p + 1 { outlineView.setDropItem(nil, dropChildIndex: p + 2) }
            return .move
        }
        if let m = item as? Marker {
            if m.kind == .separator {
                outlineView.setDropItem(nil, dropChildIndex: p)
                return .move
            }
            if dragged.isFolder { return [] }
            outlineView.setDropItem(nil, dropChildIndex: p + 2)
            return .move
        }
        guard let target = item as? Item else { return [] }
        if target.isFolder {
            if dragged === target || target.isDescendant(of: dragged) { return [] }
            return .move
        }
        // Dropping a tab onto a split view's row adds it to the split view.
        if target.isSplit, index < 0, store.canSplit(dragged), store.split(containing: dragged) !== target,
           target.children.count < SplitLayout.maxPanes {
            return .move
        }
        // Hovering a tab row means "put it right after this tab".
        if let parent = target.parent {
            if dragged === parent || parent.isDescendant(of: dragged) { return [] }
            let i = parent.children.firstIndex { $0 === target } ?? 0
            outlineView.setDropItem(parent, dropChildIndex: i + 1)
        } else if let i = sp.pinned.firstIndex(where: { $0 === target }) {
            outlineView.setDropItem(nil, dropChildIndex: i + 1)
        } else if let i = sp.today.firstIndex(where: { $0 === target }) {
            if dragged.isFolder { return [] }
            outlineView.setDropItem(nil, dropChildIndex: p + 2 + i + 1)
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let dragged = dragged(info) else { return false }
        let sp = store.currentSpace
        let p = sp.pinned.count
        if let sv = item as? Item, sv.isSplit, index < 0, let last = sv.children.last {
            return store.makeSplit(last, with: dragged) != nil
        }
        if let folder = item as? Item, folder.isFolder {
            store.move(dragged, to: .pinned(sp, folder), index: index < 0 ? nil : index)
        } else if index < 0 {
            store.move(dragged, to: .today(sp))
        } else if index <= p {
            store.move(dragged, to: .pinned(sp, nil), index: index)
        } else {
            store.move(dragged, to: .today(sp), index: max(0, index - p - 2))
        }
        return true
    }
}

// MARK: - Space swipe test (SORREL_SWIPETEST)

extension SidebarView {
    /// Drives two-finger swipes (synthetic trackpad events) and click-and-hold scrubs on the space icons through
    /// the real handlers, logging `swipe:` lines. With `shots` set, writes swipe-mid.png and scrub-mid.png there.
    func debugSwipeTest(shots: String?, log: @escaping (String) -> Void) {
        let store = self.store
        let icons = ["🌿", "🌊", "🔥"]
        while store.spaces.count < 3 { store.addSpace(name: "Space \(store.spaces.count + 1)", icon: icons[store.spaces.count % 3]) }
        store.switchSpace(to: store.spaces[0])
        swipe.debugInverted = true   // synthetic events: deltaX > 0 means the fingers moved right
        func idx() -> Int { store.spaces.firstIndex { $0 === store.currentSpace } ?? -1 }
        func state(_ label: String) {
            log("swipe: \(label): space=\(idx()) active=\(pager.isActive) pos=\(String(format: "%.2f", pager.position)) [\(pager.debugLayout)]")
        }
        func scroll(dx: Double, dy: Double = 0, phase: Int64, momentum: Int64 = 0) -> Bool {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return false }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            guard let e = NSEvent(cgEvent: cg) else { return false }
            return swipe.handle(e)
        }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
            guard let w = window, let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            let strip = spaceBar.debugStrip
            switch type {
            case .leftMouseDown: strip.mouseDown(with: e)
            case .leftMouseDragged: strip.mouseDragged(with: e)
            default: strip.mouseUp(with: e)
            }
        }
        func shot(_ name: String) {
            guard let shots, let view = window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shots).appendingPathComponent(name))
        }
        // Steps run one after another, each `gap` seconds after the previous.
        var steps: [(gap: TimeInterval, run: () -> Void)] = []
        func then(_ gap: TimeInterval, _ run: @escaping () -> Void) { steps.append((gap, run)) }
        func next() {
            guard !steps.isEmpty else { return }
            let s = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + s.gap) { s.run(); next() }
        }
        let w = pager.pageWidth

        then(0.3) { log("swipe: \(store.spaces.count) spaces, page width \(Int(w))"); state("start") }
        // A: a quick swipe to the left (fingers move left): the next space slides in from the right, lands.
        then(0) { log("swipe: A handled=\(scroll(dx: -20, phase: 1))") }
        for _ in 0..<4 { then(0.016) { _ = scroll(dx: -20, phase: 2) } }
        then(0.016) { state("A mid (expect pos ~\(String(format: "%.2f", 100 / w)), live page left, Space 2 to its right)"); shot("swipe-mid.png") }
        for _ in 0..<3 { then(0.016) { _ = scroll(dx: -20, phase: 2) } }
        then(0.016) { _ = scroll(dx: 0, phase: 4) }
        then(0.01) { log("swipe: A momentum after a swipe swallowed=\(scroll(dx: -8, phase: 0, momentum: 2))"); _ = scroll(dx: 0, phase: 0, momentum: 3) }
        then(0.9) { state("A after flick (expect space=1, inactive)") }
        // B: a slow, short drag that pauses before letting go: springs back.
        then(0) { _ = scroll(dx: -10, phase: 1) }
        then(0.12) { _ = scroll(dx: -10, phase: 2) }
        then(0.12) { _ = scroll(dx: -10, phase: 2); state("B dragged") }
        then(0.25) { _ = scroll(dx: 0, phase: 4) }
        then(0.9) { state("B after slow let-go (expect space=1)") }
        // C: an ordinary vertical scroll is not a swipe.
        then(0) { log("swipe: C vertical handled=\(scroll(dx: 0, dy: -20, phase: 1)) \(scroll(dx: 2, dy: -20, phase: 2)) \(scroll(dx: 0, dy: 0, phase: 4)) (expect false false false)") }
        // D: a long fast swipe to the right from space 1: past space 0 and stretching beyond it, lands on 0.
        then(0.2) { _ = scroll(dx: 40, phase: 1) }
        let dSteps = Int((2.5 * w) / 40)
        for _ in 0..<dSteps { then(0.016) { _ = scroll(dx: 40, phase: 2) } }
        then(0.016) { state("D stretched past the first space (expect pos between -0.5 and 0)") }
        then(0.016) { _ = scroll(dx: 0, phase: 4) }
        then(0.9) { state("D after let-go (expect space=0)") }
        // E: click and hold the first icon, drag across to the third.
        then(0) { mouse(.leftMouseDown, self.spaceBar.debugPoint(icon: 0)) }
        for k in 1...8 { then(0.03) { mouse(.leftMouseDragged, self.spaceBar.debugPoint(icon: 0, dx: CGFloat(k) * 4)) } }
        then(0.3) { state("E holding over icon 1 (expect pos ~1)") }
        then(0) { mouse(.leftMouseDragged, self.spaceBar.debugPoint(icon: 1, dx: 16)) }
        then(0.4) { state("E halfway to icon 2 (expect pos ~1.5, two pages showing)"); shot("scrub-mid.png") }
        then(0) { mouse(.leftMouseDragged, self.spaceBar.debugPoint(icon: 2)) }
        then(0.05) { mouse(.leftMouseUp, self.spaceBar.debugPoint(icon: 2)) }
        then(0.9) { state("E after release (expect space=2, inactive)") }
        // F: a plain click on the first icon still just switches.
        then(0) { mouse(.leftMouseDown, self.spaceBar.debugPoint(icon: 0)) }
        then(0.05) { mouse(.leftMouseUp, self.spaceBar.debugPoint(icon: 0)); state("F after click (expect space=0, never active)") }
        // G: scrubbing past the first icon stretches, then returns.
        then(0.5) { mouse(.leftMouseDown, self.spaceBar.debugPoint(icon: 0)) }
        for k in 1...5 { then(0.03) { mouse(.leftMouseDragged, self.spaceBar.debugPoint(icon: 0, dx: CGFloat(k) * -20)) } }
        then(0.4) { state("G pulled past the first icon (expect pos between -0.5 and 0)") }
        then(0) { mouse(.leftMouseUp, self.spaceBar.debugPoint(icon: 0, dx: -100)) }
        then(0.9) { state("G after release (expect space=0, inactive)") }
        next()
    }
}

// MARK: - Space icon row test (SORREL_SPACEROWTEST)

extension SidebarView {
    /// With many spaces the icon row must scroll: logs `row:` lines for a swipe over a row that fits (switches
    /// spaces), the row revealing the current space, a sideways scroll of an overflowing row (scrolls, doesn't
    /// switch), clicking an icon that was scrolled into view, and scrubbing into the row's end (keeps scrolling).
    func debugSpaceRowTest(shots: String?, log: @escaping (String) -> Void) {
        let store = self.store
        let row = spaceBar.debugRowScroll
        swipe.debugInverted = true
        func idx() -> Int { store.spaces.firstIndex { $0 === store.currentSpace } ?? -1 }
        func state(_ label: String) { log("row: \(label): space=\(idx()) of \(store.spaces.count) active=\(pager.isActive) \(spaceBar.debugRow)") }
        func scroll(dx: Double, phase: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(dx), wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            if let e = NSEvent(cgEvent: cg) { row.scrollWheel(with: e) }
        }
        func scrollV(dy: Double, phase: Int64) {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            if let e = NSEvent(cgEvent: cg) { row.scrollWheel(with: e) }
        }
        func mouse(_ type: NSEvent.EventType, _ p: NSPoint) {
            guard let w = window, let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            let strip = spaceBar.debugStrip
            switch type {
            case .leftMouseDown: strip.mouseDown(with: e)
            case .leftMouseDragged: strip.mouseDragged(with: e)
            default: strip.mouseUp(with: e)
            }
        }
        func shot(_ name: String) {
            guard let shots, let rep = spaceBar.bitmapImageRepForCachingDisplay(in: spaceBar.bounds) else { return }
            spaceBar.cacheDisplay(in: spaceBar.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shots).appendingPathComponent(name))
        }
        var steps: [(gap: TimeInterval, run: () -> Void)] = []
        func then(_ gap: TimeInterval, _ run: @escaping () -> Void) { steps.append((gap, run)) }
        func next() {
            guard !steps.isEmpty else { return }
            let s = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + s.gap) { s.run(); next() }
        }
        then(0.3) {
            while store.spaces.count > 2 { store.removeSpace(store.spaces.last!) }
            store.switchSpace(to: store.spaces[0])
        }
        then(0.5) { state("two spaces (expect overflows=false)"); shot("row-fits.png") }
        // A sideways swipe over icons that fit still switches spaces.
        then(0) { scroll(dx: -20, phase: 1) }
        for _ in 0..<7 { then(0.016) { scroll(dx: -20, phase: 2) } }
        then(0.016) { scroll(dx: 0, phase: 4) }
        then(0.9) { state("after a swipe over a row that fits (expect space=0: the row never switches spaces)") }
        then(0) {
            let icons = ["🌿", "🌊", "🔥", "📚", "🎵", "🧪", "🏃", "🍳", "✈️", "🎨", "💼", "🧠"]
            for (k, ic) in icons.enumerated() { store.addSpace(name: "Space \(k + 3)", icon: ic) }
        }
        then(0.6) { state("added 12, now on the last (expect overflows=true, inView ends at 13)"); shot("row-last.png") }
        then(0) { store.switchSpace(to: store.spaces[0]) }
        then(0.6) { state("switched to the first (expect inView starts at 0, scrollX=0)"); shot("row-first.png") }
        // Sideways scroll over an overflowing row moves the row, not the spaces.
        then(0) { scroll(dx: -30, phase: 1) }
        for _ in 0..<5 { then(0.016) { scroll(dx: -30, phase: 2) } }
        then(0.016) { scroll(dx: 0, phase: 4) }
        then(0.8) { state("scrolled the row (expect scrollX>0, space=0, active=false)"); shot("row-scrolled.png") }
        // Two fingers up/down over the row slide it too (fingers up = towards later spaces), still no switch.
        then(0) { scrollV(dy: -30, phase: 1) }
        for _ in 0..<2 { then(0.016) { scrollV(dy: -30, phase: 2) } }
        then(0.016) { scrollV(dy: 0, phase: 4) }
        then(0.5) { state("scrolled up/down over the row (expect scrollX grown by ~90, space=0, active=false)") }
        // An icon that was off to the right can now be clicked.
        var target = -1
        then(0) {
            let r = self.spaceBar.debugRow
            target = Int(r.components(separatedBy: "...").last ?? "") ?? -1
            mouse(.leftMouseDown, self.spaceBar.debugPoint(icon: target))
        }
        then(0.05) { mouse(.leftMouseUp, self.spaceBar.debugPoint(icon: target)) }
        then(0.6) { state("clicked icon \(target) (expect space=\(target))") }
        // Scrub from the first icon to past the row's right end and hold: the row keeps scrolling.
        then(0) { store.switchSpace(to: store.spaces[0]) }
        then(0.6) { mouse(.leftMouseDown, self.spaceBar.debugPoint(icon: 0)) }
        let edge = { row.convert(NSPoint(x: row.bounds.maxX + 6, y: row.bounds.midY), to: nil) }
        for k in 1...6 { then(0.03) { mouse(.leftMouseDragged, self.spaceBar.debugPoint(icon: 0, dx: CGFloat(k) * 6)) } }
        then(0.03) { mouse(.leftMouseDragged, edge()) }
        then(0.25) { state("scrub resting at the right end, early") }
        then(0.9) { state("scrub resting at the right end, later (expect scrollX grown, pos far along)"); shot("row-scrub.png") }
        then(0) { mouse(.leftMouseUp, edge()) }
        then(0.9) { state("released at the right end (expect a late space, active=false)") }
        next()
    }
}
