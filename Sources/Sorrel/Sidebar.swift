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

private final class Marker: NSObject {
    enum Kind { case separator, newTab }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

// MARK: - Outline pieces

private final class SidebarOutline: NSOutlineView {
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
    /// +1 = next space, -1 = previous space.
    var onSwipe: ((Int) -> Void)?
    private var accumulated: CGFloat = 0
    private var fired = false
    private var horizontal: Bool?

    override func scrollWheel(with e: NSEvent) {
        if e.phase == .began {
            accumulated = 0
            fired = false
            horizontal = nil
        }
        if !e.phase.isEmpty, horizontal == nil, e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 {
            horizontal = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) * 1.5
        }
        if horizontal == true {
            accumulated += e.scrollingDeltaX
            if !fired, abs(accumulated) > 50 {
                fired = true
                onSwipe?(accumulated < 0 ? 1 : -1)
            }
            if e.phase == .ended || e.phase == .cancelled { horizontal = nil }
            return
        }
        super.scrollWheel(with: e)
    }
}

private final class SidebarRowView: NSTableRowView {
    var isActive = false { didSet { if oldValue != isActive { needsDisplay = true } } }
    var highlightable = true
    private(set) var isHovered = false
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ h: Bool) {
        guard h != isHovered else { return }
        isHovered = h
        needsDisplay = true
        onHover?(h)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        isActive = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard highlightable, isActive || isHovered else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        if isActive {
            color = dark ? NSColor.white.withAlphaComponent(0.2) : NSColor.white.withAlphaComponent(0.85)
        } else {
            color = dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

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

private final class ItemCell: NSTableCellView, NSTextFieldDelegate {
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
        closeButton.isHidden = !hovered || (item?.isFolder ?? true)
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

private final class SeparatorCell: NSTableCellView {
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

private final class NewTabCell: NSTableCellView {
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
    var menuProvider: (() -> NSMenu)?
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
        let live = Extensions.shared.action(for: entry)
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
    private var canCopy = false
    private var hovered = false
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        copyButton = IconButton(symbol: "link", size: 12) { [weak self] in self?.onCopy?() }
        copyButton.isHidden = true
        addSubview(copyButton)
        extensionStack.orientation = .horizontal
        extensionStack.spacing = 0
        extensionStack.translatesAutoresizingMaskIntoConstraints = false
        extensionStack.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(extensionStack)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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

    func set(_ text: String?, canCopy: Bool) {
        label.stringValue = text ?? "Search or enter address"
        label.textColor = text == nil ? .tertiaryLabelColor : .labelColor
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
        copyButton.isHidden = !canCopy
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        copyButton.isHidden = true
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
    var isActive = false { didSet { needsDisplay = true } }
    var onClick: ((Item) -> Void)?
    var menuProvider: ((Item) -> NSMenu)?

    init(item: Item) {
        self.item = item
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        toolTip = item.displayTitle
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

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

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color: NSColor
        if isActive {
            color = dark ? NSColor.white.withAlphaComponent(0.26) : NSColor.white.withAlphaComponent(0.9)
        } else {
            color = dark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.06)
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?(item) }
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

private final class SpaceButton: NSButton {
    var space: Space?
    var menuProvider: ((Space) -> NSMenu)?
    override func menu(for event: NSEvent) -> NSMenu? { space.flatMap { menuProvider?($0) } }
    override var mouseDownCanMoveWindow: Bool { false }
}

private final class SpaceBar: NSView {
    private let stack = NSStackView()
    var onSelect: ((Space) -> Void)?
    var menuProvider: ((Space) -> NSMenu)?
    var onAdd: ((NSView) -> Void)?
    var onExtensions: ((NSView) -> Void)?
    var onDownloads: ((NSView) -> Void)?
    private var addButton: IconButton!
    private(set) var extensionsButton: IconButton!
    private(set) var downloadsButton: IconButton!

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addButton = IconButton(symbol: "plus", size: 12, tooltip: "New space or folder") { [weak self] in
            if let self { self.onAdd?(self.addButton) }
        }
        addSubview(addButton)
        extensionsButton = IconButton(symbol: "puzzlepiece.extension", size: 12, tooltip: "Extensions") { [weak self] in
            if let self { self.onExtensions?(self.extensionsButton) }
        }
        addSubview(extensionsButton)
        downloadsButton = IconButton(symbol: "arrow.down.circle", size: 12, tooltip: "Downloads") { [weak self] in
            if let self { self.onDownloads?(self.downloadsButton) }
        }
        downloadsButton.isHidden = true   // appears once something has been downloaded
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
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 56),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),
            addButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ spaces: [Space], current: Space) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for sp in spaces {
            let b = SpaceButton(title: sp.icon, target: self, action: #selector(pick(_:)))
            b.space = sp
            b.menuProvider = menuProvider
            b.isBordered = false
            b.font = .systemFont(ofSize: 14)
            b.toolTip = sp.name
            b.alphaValue = sp === current ? 1 : 0.45
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.layer?.backgroundColor = sp === current ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : nil
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(b)
        }
    }

    @objc private func pick(_ sender: SpaceButton) {
        if let sp = sender.space { onSelect?(sp) }
    }
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
    private let spaceContainer = NSView()
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

    private var store: Store { Store.shared }

    /// The extensions button, which extension pop-ups attach to.
    var extensionsAnchor: NSView { spaceBar.extensionsButton }

    /// The address box, for editing the address in place.
    var addressAnchor: NSView { pill }

    /// True while something in the sidebar needs it to stay on screen.
    var wantsToStayOpen: Bool {
        editingCount > 0 || (themePopover?.isShown ?? false)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(structureChanged), name: .sorrelStructure, object: nil)
        nc.addObserver(self, selector: #selector(selectionChanged), name: .sorrelSelection, object: nil)
        nc.addObserver(self, selector: #selector(itemChanged(_:)), name: .sorrelItem, object: nil)
        nc.addObserver(self, selector: #selector(spaceChanged), name: .sorrelSpace, object: nil)
        nc.addObserver(self, selector: #selector(downloadsChanged), name: .sorrelDownloads, object: nil)
        nc.addObserver(self, selector: #selector(extensionsChanged), name: .sorrelExtensions, object: nil)
        nc.addObserver(self, selector: #selector(extensionActionChanged(_:)), name: .sorrelExtensionAction, object: nil)
        nc.addObserver(self, selector: #selector(extensionTabChanged), name: .sorrelSelection, object: nil)
        reloadAll(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: Building

    private func build() {
        wantsLayer = true
        floatingBackground.cornerRadius = 8
        floatingBackground.alphaValue = 0
        floatingBackground.layer?.borderWidth = 0.5
        floatingBackground.layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor

        for v in [floatingBackground, topRow, pill, favorites, spaceContainer, spaceBar, handle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

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
        scroll.onSwipe = { [weak self] dir in self?.store.switchSpace(offset: dir) }

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
        spaceBar.menuProvider = { [weak self] in self?.menu(for: $0) ?? NSMenu() }
        spaceBar.onAdd = { [weak self] anchor in self?.showAddMenu(from: anchor) }
        spaceBar.onExtensions = { [weak self] anchor in self?.showExtensionsMenu(from: anchor) }
        spaceBar.onDownloads = { [weak self] anchor in self?.showDownloadsMenu(from: anchor) }
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

            spaceContainer.topAnchor.constraint(equalTo: favorites.bottomAnchor, constant: 8),
            spaceContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            spaceContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            spaceContainer.bottomAnchor.constraint(equalTo: spaceBar.topAnchor, constant: -4),

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

    @objc private func selectionChanged() {
        refreshSelection()
        refreshNavigation()
    }

    @objc private func spaceChanged() { reloadAll(animated: true) }

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
        if animated, shownSpaceID != nil, shownSpaceID != sp.id, let layer = spaceContainer.layer {
            let t = CATransition()
            t.type = .push
            t.subtype = store.lastSwitchDirection > 0 ? .fromRight : .fromLeft
            t.duration = 0.22
            t.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(t, forKey: "space")
        }
        shownSpaceID = sp.id
        spaceIcon.title = sp.icon
        spaceName.stringValue = sp.name + (sp.profileID != nil ? "  ·  separate logins" : "")
        spaceBar.reload(store.spaces, current: sp)
        reloadOutline()
        refreshNavigation()
    }

    private func reloadOutline() {
        isReloading = true
        outline.reloadData()
        func expand(_ items: [Item]) {
            for i in items where i.isFolder {
                if i.expanded {
                    outline.expandItem(i)
                    expand(i.children)
                }
            }
        }
        expand(store.currentSpace.pinned)
        isReloading = false
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
            pill.set(item?.host?.replacingOccurrences(of: "www.", with: "") ?? item?.url,
                     canCopy: item?.url?.hasPrefix("http") ?? false)
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
        let list = Engine.shared.downloads
        let button = spaceBar.downloadsButton!
        button.isHidden = list.isEmpty
        let running = list.filter { $0.state == .running }
        button.contentTintColor = running.isEmpty ? .secondaryLabelColor : .controlAccentColor
        if let first = running.first {
            button.toolTip = "Downloading \(first.file.lastPathComponent) (\(Int(first.fraction * 100))%)"
        } else {
            button.toolTip = "Downloads"
        }
    }

    func showDownloadsMenu(from anchor: NSView? = nil) {
        let anchor = anchor ?? spaceBar.downloadsButton!
        let m = NSMenu()
        let list = Engine.shared.downloads
        if list.isEmpty {
            let none = NSMenuItem(title: "Nothing Downloaded Yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            m.addItem(none)
        }
        for record in list.prefix(15) {
            let name = String(record.file.lastPathComponent.prefix(48))
            switch record.state {
            case .running:
                m.addItem(ActionMenuItem("\(name) — \(Int(record.fraction * 100))% · Cancel") {
                    record.download?.cancel { _ in }
                })
            case .done:
                let item = ActionMenuItem(name) { NSWorkspace.shared.activateFileViewerSelecting([record.file]) }
                item.image = NSWorkspace.shared.icon(forFile: record.file.path)
                item.image?.size = NSSize(width: 16, height: 16)
                item.toolTip = "Show in Finder"
                m.addItem(item)
            case .failed:
                let item = NSMenuItem(title: "\(name) — didn’t finish", action: nil, keyEquivalent: "")
                item.isEnabled = false
                m.addItem(item)
            }
        }
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Open Downloads Folder") { Commands.shared.run("downloads.show") })
        if list.contains(where: { $0.state != .running }) {
            m.addItem(ActionMenuItem("Clear This List") { Engine.shared.clearFinishedDownloads() })
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

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
            let live = Extensions.shared.action(for: entry)
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
