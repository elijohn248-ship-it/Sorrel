import AppKit

// The Library, as in Arc: it takes over the sidebar (below the window controls) when the Library button at the
// bottom left is clicked. Two sections, Downloads and Archive, each a list grouped by Today / Yesterday /
// Previous 7 Days / Earlier.

extension Notification.Name {
    /// The archived-tabs list changed (Store.saveArchive).
    static let sorrelArchive = Notification.Name("sorrelArchive")
}

final class LibraryView: NSView {
    enum Section: Int { case downloads, archive }

    var onClose: (() -> Void)?
    private(set) var section: Section = .downloads
    private let store: Store
    private var tabs: [LibraryTab] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let empty = NSTextField(labelWithString: "")
    private var clearButton: NSButton!
    private var folderButton: IconButton!
    /// Rows already built, so progress updates and reloads keep their thumbnails and hover state.
    private var downloadRows: [ObjectIdentifier: DownloadRow] = [:]
    /// What the list currently shows (section + ids + group titles); a reload with the same shape only refreshes.
    private var shape = ""
    private var clock: Timer?

    init(store: Store) {
        self.store = store
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed), name: .sorrelDownloads, object: nil)
        nc.addObserver(self, selector: #selector(changed), name: .sorrelArchive, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        let title = NSTextField(labelWithString: "Library")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let close = IconButton(symbol: "xmark", size: 11, tooltip: "Close Library") { [weak self] in self?.onClose?() }

        let tabBar = NSView()
        tabBar.wantsLayer = true
        tabBar.layer?.cornerRadius = 8
        tabs = [LibraryTab(title: "Downloads", symbol: "arrow.down.circle"), LibraryTab(title: "Archive", symbol: "archivebox")]
        for (i, tab) in tabs.enumerated() {
            tab.onClick = { [weak self] in self?.show(Section(rawValue: i)!) }
            tab.translatesAutoresizingMaskIntoConstraints = false
            tabBar.addSubview(tab)
        }
        tabBar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        self.tabBar = tabBar

        clearButton = NSButton(title: "Clear", target: self, action: #selector(clear))
        clearButton.isBordered = false
        folderButton = IconButton(symbol: "folder", size: 12, tooltip: "Open Downloads Folder") { Commands.shared.run("downloads.show") }

        let document = FlippedContainer()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 10, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        // Clear and the folder button sit at the right edge; a hidden one takes no room.
        let actions = NSStackView(views: [clearButton, folderButton])
        actions.spacing = 2
        for v in [title, close, tabBar, actions, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),

            tabBar.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            tabBar.heightAnchor.constraint(equalToConstant: 28),
            tabs[0].leadingAnchor.constraint(equalTo: tabBar.leadingAnchor, constant: 2),
            tabs[1].trailingAnchor.constraint(equalTo: tabBar.trailingAnchor, constant: -2),
            tabs[0].trailingAnchor.constraint(equalTo: tabs[1].leadingAnchor, constant: -2),
            tabs[0].widthAnchor.constraint(equalTo: tabs[1].widthAnchor),

            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actions.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 6),
            actions.heightAnchor.constraint(equalToConstant: 22),
            folderButton.widthAnchor.constraint(equalToConstant: 22),
            folderButton.heightAnchor.constraint(equalToConstant: 22),

            scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 60),
        ])
        for tab in tabs {
            tab.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 2).isActive = true
            tab.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -2).isActive = true
        }
        applyColors()
    }

    private var tabBar: NSView?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tabBar?.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
        clearButton.attributedTitle = NSAttributedString(string: "Clear", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor])
    }

    // MARK: Showing

    /// Switches section (the list crossfades) and reloads.
    func show(_ new: Section) {
        let changed = new != section
        section = new
        for (i, tab) in tabs.enumerated() { tab.isSelected = i == new.rawValue }
        reload()
        if changed { stack.layer?.popIn(scale: 1, rise: 0, duration: 0.18) }
        if changed { scroll.contentView.scroll(to: .zero) }
    }

    /// The Library came on screen: keep "2 min ago" fresh while it stays.
    func didAppear() {
        reload()
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.reload() }
    }

    func didDisappear() {
        clock?.invalidate()
        clock = nil
    }

    @objc private func changed() {
        guard !isHidden else { return }
        reload()
    }

    @objc private func clear() {
        switch section {
        case .downloads: Engine.shared.clearFinishedDownloads()
        case .archive: store.clearArchive()
        }
    }

    // MARK: Building the list

    static func group(for date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if date > now.addingTimeInterval(-7 * 86400) { return "Previous 7 Days" }
        return "Earlier"
    }

    func reload() {
        switch section {
        case .downloads: reloadDownloads()
        case .archive: reloadArchive()
        }
    }

    private func reloadDownloads() {
        let list = Engine.shared.downloads
        folderButton.isHidden = false
        clearButton.isHidden = !list.contains { $0.state != .running }
        clearButton.toolTip = "Clear finished downloads from this list (the files stay)"
        empty.stringValue = "No downloads yet"
        empty.isHidden = !list.isEmpty

        let groups = grouped(list) { $0.finished ?? $0.started }
        let newShape = "d|" + groups.map { g in g.title + ":" + g.items.map { "\(ObjectIdentifier($0).hashValue)" }.joined(separator: ",") }.joined(separator: ";")
        if newShape == shape {
            for r in list { downloadRows[ObjectIdentifier(r)]?.refresh() }
            return
        }
        shape = newShape
        clearStack()
        var keep: [ObjectIdentifier: DownloadRow] = [:]
        for g in groups {
            add(LibraryHeader(g.title))
            for r in g.items {
                let row = downloadRows[ObjectIdentifier(r)] ?? DownloadRow(record: r)
                keep[ObjectIdentifier(r)] = row
                add(row)
                row.refresh()
            }
        }
        downloadRows = keep
    }

    private func reloadArchive() {
        let entries = Array(store.archive.prefix(300))
        folderButton.isHidden = true
        clearButton.isHidden = entries.isEmpty
        clearButton.toolTip = "Forget every archived tab"
        empty.stringValue = "No archived tabs"
        empty.isHidden = !entries.isEmpty

        let indexed = entries.enumerated().map { (index: $0.offset, entry: $0.element) }
        let groups = grouped(indexed) { $0.entry.date }
        let stamp = Int(Date().timeIntervalSince1970 / 60)   // refreshes the "… ago" text once a minute at most
        let newShape = "a|\(stamp)|" + groups.map { g in g.title + ":" + g.items.map { "\($0.entry.url)@\($0.entry.date.timeIntervalSince1970)" }.joined(separator: ",") }.joined(separator: ";")
        guard newShape != shape else { return }
        shape = newShape
        clearStack()
        for g in groups {
            add(LibraryHeader(g.title))
            for item in g.items {
                let index = item.index
                let row = ArchiveRow(entry: item.entry, space: store.space(id: item.entry.spaceID))
                row.onOpen = { [weak self] in
                    self?.store.restoreArchived(at: index)
                    self?.onClose?()
                }
                row.onRemove = { [weak self] in self?.store.removeArchived(at: index) }
                add(row)
            }
        }
    }

    private func grouped<T>(_ items: [T], date: (T) -> Date) -> [(title: String, items: [T])] {
        var out: [(title: String, items: [T])] = []
        let now = Date()
        for item in items {
            let title = Self.group(for: date(item), now: now)
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    private func clearStack() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
    }

    /// Test hook: clicks the first archived tab in the list.
    func debugOpenFirstArchived() {
        (stack.arrangedSubviews.first { $0 is ArchiveRow } as? ArchiveRow)?.onOpen?()
    }

    /// Test hook: the list as text.
    var debugLines: [String] {
        stack.arrangedSubviews.map { v in
            if let h = v as? LibraryHeader { return "## " + h.stringValue }
            if let r = v as? DownloadRow { return "dl " + r.debugDescription_ }
            if let r = v as? ArchiveRow { return "tab " + r.debugText }
            return "?"
        }
    }
}

// MARK: - Pieces

/// One of the two section buttons (Downloads / Archive) in the Library's capsule switch.
private final class LibraryTab: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let fill = CALayer()
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            Motion.layer(0.18) { fill.opacity = isSelected ? 1 : 0 }
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            icon.contentTintColor = label.textColor
        }
    }

    init(title: String, symbol name: String) {
        super.init(frame: .zero)
        wantsLayer = true
        fill.cornerRadius = 6
        fill.opacity = 0
        fill.shadowOpacity = 0.12
        fill.shadowRadius = 1.5
        fill.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(fill)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        icon.image = symbol(name, size: 11)
        icon.contentTintColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, label])
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Motion.layer(0) { fill.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            fill.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.85)).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { layer?.press() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// "Today", "Yesterday"… above a group of rows, sitting low in its band so it reads with the rows below.
private final class LibraryHeader: NSView {
    let stringValue: String

    init(_ title: String) {
        stringValue = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// An archived tab: favicon, title, site and when it was put away. Click reopens it; × forgets it.
final class ArchiveRow: NSView {
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var remove: IconButton!
    private let highlight = CALayer()
    private static let ago: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    init(entry: ArchivedTab, space: Space?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        highlight.cornerRadius = 8
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        let host = URL(string: entry.url)?.host
        icon.image = FaviconStore.shared.image(forHost: host) ?? symbol("globe", size: 13)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.stringValue = entry.title.isEmpty ? entry.url : entry.title
        title.font = .systemFont(ofSize: 12.5)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let when = Date().timeIntervalSince(entry.date) < 60 ? "Just now" : Self.ago.localizedString(for: entry.date, relativeTo: Date())
        detail.stringValue = [space.map { $0.icon }, host?.replacingOccurrences(of: "www.", with: ""), when]
            .compactMap { $0 }.joined(separator: " · ")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = entry.url
        remove = IconButton(symbol: "xmark", size: 10, tooltip: "Remove from Archive") { [weak self] in self?.onRemove?() }
        remove.isHidden = true

        for v in [icon, title, detail, remove!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 20),
            remove.heightAnchor.constraint(equalToConstant: 20),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        Motion.layer(0) { highlight.frame = bounds }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        Motion.layer(on ? 0.12 : 0.2) { highlight.opacity = on ? 1 : 0 }
        remove.fade(in: on)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(ActionMenuItem("Reopen Tab") { [weak self] in self?.onOpen?() })
        m.addItem(ActionMenuItem("Copy Link") { [weak self] in
            guard let link = self?.toolTip else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        })
        m.addItem(.separator())
        m.addItem(ActionMenuItem("Remove from Archive") { [weak self] in self?.onRemove?() })
        return m
    }

    override var mouseDownCanMoveWindow: Bool { false }

    var debugText: String { "\(title.stringValue) | \(detail.stringValue)" }
}
