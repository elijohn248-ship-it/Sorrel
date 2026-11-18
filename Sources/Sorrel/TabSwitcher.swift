import AppKit

/// A window-local HUD driven by the same frozen order as Control+Tab.
/// Uses cached icons only, and never takes keyboard focus from the browser.
final class TabSwitcher: NSVisualEffectView {
    private let scroll = NSScrollView()
    private let strip = NSView()
    private let caption = NSTextField(labelWithString: "")
    private var width: NSLayoutConstraint!
    private var tiles: [TabSwitcherTile] = []
    private(set) var itemIDs: [UUID] = []
    private(set) var selectedID: UUID?
    private(set) var isPresented = false
    var onChoose: ((Item) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
        isHidden = true
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = strip
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        for view in [scroll, caption] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            scroll.heightAnchor.constraint(equalToConstant: 112),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            caption.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        setAccessibilityLabel("Tabs in this space")
    }
    required init?(coder: NSCoder) { fatalError() }

    func attach(to root: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(self)
        width = widthAnchor.constraint(equalToConstant: 400)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: root.centerXAnchor),
            centerYAnchor.constraint(equalTo: root.centerYAnchor),
            widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -48),
            width,
        ])
    }

    func show(_ items: [Item], selected: Item?) {
        guard items.count > 1, let selected, items.contains(where: { $0 === selected }) else {
            isPresented = false
            itemIDs = []
            selectedID = nil
            fade(in: false)
            return
        }
        let arriving = !isPresented
        isPresented = true
        selectedID = selected.id
        let ids = items.map { $0.id }
        if ids != itemIDs {
            itemIDs = ids
            for tile in tiles { tile.removeFromSuperview() }
            tiles = items.map { item in
                let tile = TabSwitcherTile(item: item)
                tile.onChoose = { [weak self, weak item] in
                    if let item { self?.onChoose?(item) }
                }
                strip.addSubview(tile)
                return tile
            }
        }
        width.constant = min(872, CGFloat(items.count) * 112 + 32)
        strip.frame = NSRect(x: 0, y: 0, width: CGFloat(items.count) * 112, height: 112)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(index) * 112, y: 4, width: 108, height: 104)
            tile.update(items[index], selected: items[index] === selected)
        }
        let index = items.firstIndex { $0 === selected } ?? 0
        caption.stringValue = "\(selected.displayTitle)  ·  \(index + 1) of \(items.count)"
        superview?.layoutSubtreeIfNeeded()
        tiles[index].scrollToVisible(tiles[index].bounds)
        fade(in: true)
        if arriving { layer?.popIn() }
    }

    var selectedTileIsVisible: Bool {
        guard let index = itemIDs.firstIndex(where: { $0 == selectedID }), tiles.indices.contains(index) else { return false }
        let visible = scroll.contentView.documentVisibleRect
        let frame = tiles[index].frame
        return visible.contains(frame)
    }
}

private final class TabSwitcherTile: NSButton {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var onChoose: (() -> Void)?

    init(item: Item) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = 14
        target = self
        action = #selector(choose)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
        ])
        update(item, selected: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ item: Item, selected: Bool) {
        icon.image = FaviconStore.shared.image(for: item) ?? symbol("globe", size: 48)
        label.stringValue = item.displayTitle
        toolTip = item.displayTitle
        setAccessibilityLabel(item.displayTitle)
        setAccessibilityValue(selected ? "Selected" : "")
        layer?.backgroundColor = (selected ? NSColor.labelColor.withAlphaComponent(0.14) : .clear).cgColor
        layer?.borderWidth = selected ? 2 : 0
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    @objc private func choose() { onChoose?() }
}
