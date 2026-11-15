import AppKit

private final class Swatch: NSButton {
    var theme = Theme.presets[0]
    var onPick: ((Theme) -> Void)?

    convenience init(theme: Theme, onPick: @escaping (Theme) -> Void) {
        self.init(frame: .zero)
        self.theme = theme
        self.onPick = onPick
        title = ""
        isBordered = false
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    @objc private func fire() { onPick?(theme) }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        var colors = theme.resolvedColors(systemIsDark: systemIsDark())
        if colors.count == 1 { colors.append(colors[0]) }
        NSGradient(colors: colors)?.draw(in: path, angle: CGFloat(theme.angle))
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// One emoji in the icon list.
private final class EmojiButton: NSButton {
    var onPick: ((String) -> Void)?

    convenience init(_ emoji: String, onPick: @escaping (String) -> Void) {
        self.init(frame: .zero)
        self.onPick = onPick
        title = emoji
        font = .systemFont(ofSize: 17)
        isBordered = false
        target = self
        action = #selector(fire)
        toolTip = nil
    }

    @objc private func fire() { onPick?(title) }
}

/// The space's current icon; clicking it slides up the full emoji sheet.
private final class IconWell: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var onClick: (() -> Void)?
    var emoji = "" { didSet { needsDisplay = true } }

    convenience init(onClick: @escaping () -> Void) {
        self.init(frame: .zero)
        self.onClick = onClick
        isBordered = false
        title = ""
        target = self
        action = #selector(fire)
        toolTip = "Choose an icon"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 38).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    @objc private func fire() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isHighlighted ? 0.2 : hovering ? 0.14 : 0.08
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18)]
        let str = emoji as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
}

/// "Customize Space": name, icon, colors and gradient.
final class ThemeEditor: NSViewController, NSTextFieldDelegate {
    private let space: Space
    private let focusName: Bool
    private let nameField = NSTextField()
    private var iconWell: IconWell!
    private let content = NSStackView()
    private lazy var emojiSheet: EmojiSheet = {
        let sheet = EmojiSheet(frame: .zero)
        sheet.onPick = { [weak self] emoji in self?.setIcon(emoji) }
        sheet.onProgress = { [weak self] progress, animated in
            // The editor recedes as the sheet comes up over it.
            let alpha = 1 - 0.7 * max(0, min(1, progress))
            if animated { self?.content.animator().alphaValue = alpha } else { self?.content.alphaValue = alpha }
        }
        sheet.onClosed = { [weak self] in self?.view.window?.makeFirstResponder(nil) }
        return sheet
    }()
    private var theme: Theme
    private let wellStack = NSStackView()
    private var wells: [NSColorWell] = []
    private let angle = NSSlider(value: 0, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let intensity = NSSlider(value: 0.5, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private var addButton: IconButton!
    private var removeButton: IconButton!

    init(space: Space, focusName: Bool = false) {
        self.space = space
        self.focusName = focusName
        self.theme = space.theme
        super.init(nibName: nil, bundle: nil)
        EmojiCatalog.preload()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    override func loadView() {
        let stack = content
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        stack.addArrangedSubview(caption("ICON AND NAME"))
        iconWell = IconWell { [weak self] in self?.showEmojiSheet() }
        iconWell.emoji = space.icon
        nameField.stringValue = space.name
        nameField.placeholderString = "Space name"
        nameField.font = .systemFont(ofSize: 13)
        nameField.delegate = self
        nameField.widthAnchor.constraint(equalToConstant: 144).isActive = true
        let identity = NSStackView(views: [iconWell, nameField])
        identity.orientation = .horizontal
        identity.spacing = 8
        stack.addArrangedSubview(identity)
        stack.addArrangedSubview(emojiList())

        stack.addArrangedSubview(caption("PRESETS"))
        let perRow = 5
        for start in stride(from: 0, to: Theme.presets.count, by: perRow) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            for preset in Theme.presets[start..<min(start + perRow, Theme.presets.count)] {
                row.addArrangedSubview(Swatch(theme: preset) { [weak self] t in self?.load(t) })
            }
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(caption("COLORS"))
        wellStack.orientation = .horizontal
        wellStack.spacing = 8
        addButton = IconButton(symbol: "plus.circle", size: 15, tooltip: "Add a color") { [weak self] in self?.addColor() }
        removeButton = IconButton(symbol: "minus.circle", size: 15, tooltip: "Remove the last color") { [weak self] in self?.removeColor() }
        let colorRow = NSStackView(views: [wellStack, addButton, removeButton])
        colorRow.orientation = .horizontal
        colorRow.spacing = 8
        stack.addArrangedSubview(colorRow)

        stack.addArrangedSubview(caption("DIRECTION"))
        angle.target = self
        angle.action = #selector(sliderChanged)
        angle.widthAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(angle)

        stack.addArrangedSubview(caption("STRENGTH"))
        intensity.target = self
        intensity.action = #selector(sliderChanged)
        intensity.widthAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(intensity)

        // A plain container with explicit padding, so the popover sizes itself to the real content.
        let container = NSView()
        container.clipsToBounds = true  // the emoji sheet waits just below the bottom edge
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        view = container
        load(theme, commit: false)
    }

    private static let emojis: [String] = [
        "🏠", "💼", "🎓", "📚", "🩺", "🧬", "🧪", "💊", "🏥", "🧠", "❤️", "🦷", "🔬", "📖", "✏️", "📝",
        "🗂", "📁", "📌", "📅", "⏰", "💡", "🔍", "⚙️", "🛠", "💻", "🖥", "⌨️", "📱", "🎧", "🎵", "🎬",
        "🎮", "📷", "🎨", "✈️", "🚗", "🗺", "🌍", "🏝", "⛰", "🏃", "🏋️", "⚽️", "🏀", "🎾", "🍎", "☕️",
        "🍕", "🛒", "💰", "💳", "📈", "🏦", "🧾", "✉️", "💬", "📣", "🔒", "🔑", "⭐️", "✨", "🔥", "🌙",
        "☀️", "🌈", "⚡️", "🌊", "🌱", "🌸", "🍀", "🐶", "🐱", "🦊", "🐼", "🦉", "🐙", "😀", "😎", "🤓",
        "🥳", "🤔", "😴", "👋", "👍", "🙌", "💪", "🧘", "🎉", "🎁", "🏆", "🚀", "🧭", "🧳", "🔔", "🧩",
        "♻️", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "⚫️", "⚪️",
    ]

    /// A scrolling grid of emojis to pick the space's icon from, plus a way into the full system picker.
    private func emojiList() -> NSView {
        let columns = 6
        let cell: CGFloat = 28
        let rows = (Self.emojis.count + columns - 1) / columns
        let grid = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * cell, height: CGFloat(rows) * cell))
        for (i, emoji) in Self.emojis.enumerated() {
            let b = EmojiButton(emoji) { [weak self] picked in self?.setIcon(picked) }
            // Top row first: AppKit's y axis points up.
            b.frame = NSRect(x: CGFloat(i % columns) * cell, y: grid.frame.height - CGFloat(i / columns + 1) * cell,
                             width: cell, height: cell)
            grid.addSubview(b)
        }
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.scrollerStyle = .legacy
        // Room for the scroll bar beside the last column, so no emoji is cut off.
        scroll.widthAnchor.constraint(equalToConstant: CGFloat(columns) * cell + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 2).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: cell * 4).isActive = true
        // Start at the top of the list.
        DispatchQueue.main.async { grid.scroll(NSPoint(x: 0, y: grid.frame.height)) }

        let more = NSButton(title: "All Emoji", target: self, action: #selector(showEmojiSheet))
        more.controlSize = .small
        more.bezelStyle = .accessoryBarAction
        more.toolTip = "Browse and search every emoji"
        let box = NSStackView(views: [scroll, more])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        return box
    }

    private func setIcon(_ emoji: String) {
        iconWell.emoji = emoji
        Store.shared.updateSpace(space, icon: emoji)
    }

    /// Slides the full emoji list up over the editor; picking one slides it back down.
    @objc private func showEmojiSheet() {
        emojiSheet.open(in: view, current: iconWell.emoji)
    }

    /// Test hook: opens the sheet, optionally searches and picks, and reports each step.
    func debugEmojiTest(_ mode: String, log: @escaping (String) -> Void) {
        showEmojiSheet()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            log("emoji: opened \(emojiSheet.debugState()) editorAlpha=\(String(format: "%.2f", content.alphaValue))")
            for step in mode.split(separator: ",") where step.hasPrefix("search:") {
                let q = String(step.dropFirst(7))
                log("emoji: search \(q) \(emojiSheet.debugSearch(q))")
            }
            guard mode.contains("pick") else { return }
            let picked = emojiSheet.debugPickFirst() ?? "-"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                log("emoji: picked=\(picked) spaceIcon=\(Store.shared.currentSpace.icon) well=\(iconWell.emoji) "
                    + "\(emojiSheet.debugState()) editorAlpha=\(String(format: "%.2f", content.alphaValue))")
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if focusName {
            view.window?.makeFirstResponder(nameField)
            nameField.currentEditor()?.selectAll(nil)
        } else {
            view.window?.makeFirstResponder(nil)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField {
            Store.shared.updateSpace(space, name: nameField.stringValue)
        }
    }

    private func load(_ t: Theme, commit: Bool = true) {
        theme = t
        wells.forEach { wellStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        wells = t.colors.prefix(3).map { hex in
            let w = NSColorWell(style: .minimal)
            w.color = NSColor(hex: hex) ?? .systemBlue
            w.target = self
            w.action = #selector(wellChanged)
            w.translatesAutoresizingMaskIntoConstraints = false
            w.widthAnchor.constraint(equalToConstant: 40).isActive = true
            w.heightAnchor.constraint(equalToConstant: 26).isActive = true
            wellStack.addArrangedSubview(w)
            return w
        }
        angle.doubleValue = t.angle
        intensity.doubleValue = t.intensity
        addButton.isEnabled = wells.count < 3
        removeButton.isEnabled = wells.count > 1
        if commit { Store.shared.setTheme(theme, for: space) }
    }

    private func commitFromControls() {
        theme.colors = wells.map { $0.color.hexString }
        theme.angle = angle.doubleValue
        theme.intensity = intensity.doubleValue
        Store.shared.setTheme(theme, for: space)
    }

    @objc private func wellChanged() { commitFromControls() }
    @objc private func sliderChanged() { commitFromControls() }

    private func addColor() {
        guard theme.colors.count < 3 else { return }
        var t = theme
        t.colors.append(t.colors.last ?? "#7C9CFF")
        load(t)
    }

    private func removeColor() {
        guard theme.colors.count > 1 else { return }
        var t = theme
        t.colors.removeLast()
        load(t)
    }
}
