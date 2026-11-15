import AppKit
import WebKit

/// A small window for a link opened from another app (or with the shortcut).
/// "Open in <Space>" in the top right, or the expand shortcut, turns it into a full tab.
final class MiniWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private(set) static var all: [MiniWindowController] = []

    let page: Page
    private var targetSpace: Space
    private let background = ThemeBackgroundView()
    private let card = NSView()
    private let address = NSTextField()
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private var spaceChooser: IconButton!
    private var expanded = false

    /// Private windows keep no history or cookies and cannot be turned into tabs.
    var isPrivate: Bool { page.isPrivate }
    private static let privateTheme = Theme(colors: ["#26262B", "#3A3550"], angle: 315, intensity: 1)

    @discardableResult
    static func present(url: URL?, page existing: Page? = nil, isPrivate: Bool = false) -> MiniWindowController {
        let space = Store.shared.currentSpace
        let page = existing ?? Engine.shared.makePage(profileID: isPrivate ? nil : space.profileID, isPrivate: isPrivate)
        let c = MiniWindowController(page: page, space: space)
        all.append(c)
        if let url { Engine.shared.load(url.absoluteString, in: page) }
        c.showWindow(nil)
        bringAppForward()
        if url == nil && existing == nil { c.focusAddress() } else { c.window?.makeFirstResponder(page.webView) }
        return c
    }

    private init(page: Page, space: Space) {
        self.page = page
        self.targetSpace = space
        let w = SorrelWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        super.init(window: w)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "mini")
        w.toolbar = toolbar
        w.toolbarStyle = .unifiedCompact
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 420, height: 320)
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        // Stagger so several mini windows do not stack exactly.
        let offset = CGFloat(Self.all.count % 6) * 24
        w.setFrameOrigin(NSPoint(x: w.frame.origin.x + offset, y: w.frame.origin.y - offset))
        build()
        page.onChange = { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root

        card.wantsLayer = true
        card.layer?.cornerRadius = max(6, window.outerCornerRadius - 8)
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        address.isBordered = false
        address.drawsBackground = false
        address.focusRingType = .none
        address.font = .systemFont(ofSize: 13)
        address.alignment = .center
        address.placeholderString = "Search or enter address"
        address.delegate = self
        address.usesSingleLineMode = true
        address.cell?.isScrollable = true
        address.cell?.sendsActionOnEndEditing = false
        address.target = self
        address.action = #selector(addressEntered)

        expandButton.bezelStyle = .accessoryBarAction
        expandButton.controlSize = .regular
        expandButton.font = .systemFont(ofSize: 12, weight: .medium)
        expandButton.target = self
        expandButton.action = #selector(expandAction)

        spaceChooser = IconButton(symbol: "chevron.down", size: 10, tooltip: "Choose which space to open in") { [weak self] in
            self?.showSpaceMenu()
        }

        for v in [background, card, address, expandButton, spaceChooser!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        let wv = page.webView
        wv.frame = card.bounds
        wv.autoresizingMask = [.width, .height]
        card.addSubview(wv)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 40),
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),

            spaceChooser.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            spaceChooser.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            spaceChooser.widthAnchor.constraint(equalToConstant: 20),
            spaceChooser.heightAnchor.constraint(equalToConstant: 22),
            expandButton.trailingAnchor.constraint(equalTo: spaceChooser.leadingAnchor, constant: -2),
            expandButton.centerYAnchor.constraint(equalTo: spaceChooser.centerYAnchor),

            address.centerYAnchor.constraint(equalTo: spaceChooser.centerYAnchor),
            address.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 84),
            address.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor, constant: -12),
        ])
    }

    private func refresh() {
        guard let window else { return }
        let theme = isPrivate ? Self.privateTheme : targetSpace.theme
        background.apply(theme)
        let dark = theme.isDark(systemIsDark: systemIsDark())
        window.contentView?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        page.webView.appearance = NSApp.effectiveAppearance   // pages follow the system, not the theme

        if isPrivate {
            expandButton.title = "Private"
            expandButton.image = symbol("eye.slash", size: 11)
            expandButton.imagePosition = .imageLeading
            expandButton.isEnabled = false
            expandButton.toolTip = "Nothing from this window is saved: no history, cookies or logins."
            spaceChooser.isHidden = true
        } else {
            let key = Keybindings.shared.display(for: "mini.expand") ?? ""
            expandButton.title = "Open in \(targetSpace.icon) \(targetSpace.name)" + (key.isEmpty ? "" : "   \(key)")
            expandButton.toolTip = "Turn this into a full tab in \(targetSpace.name)"
            spaceChooser.isHidden = Store.shared.spaces.count < 2
        }

        window.title = isPrivate ? "Private Window" : (page.webView.title?.nonEmpty ?? "Sorrel")
        if address.currentEditor() == nil {
            address.stringValue = page.webView.url?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
    }

    private func showSpaceMenu() {
        let m = NSMenu()
        for sp in Store.shared.spaces {
            m.addItem(ActionMenuItem("\(sp.icon)  \(sp.name)", checked: sp === targetSpace) { [weak self] in
                self?.targetSpace = sp
                self?.refresh()
            })
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: spaceChooser.bounds.height + 4), in: spaceChooser)
    }

    func focusAddress() {
        address.stringValue = page.webView.url?.absoluteString ?? ""
        window?.makeFirstResponder(address)
        address.currentEditor()?.selectAll(nil)
    }

    @objc private func addressEntered() {
        let text = address.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Engine.shared.load(Resolver.destination(for: text).absoluteString, in: page)
        window?.makeFirstResponder(page.webView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(page.webView)
            refresh()
            return true
        }
        return false
    }

    @objc private func expandAction() { expand() }

    /// Moves the live page into the main window as a full tab, keeping its state.
    func expand() {
        guard !expanded, !isPrivate else { return }
        if page.webView.url == nil { return }
        expanded = true
        page.onChange = nil
        page.webView.appearance = nil
        let space = Store.shared.space(id: targetSpace.id) ?? Store.shared.currentSpace
        AppDelegate.shared.showMainWindow()
        Store.shared.newTab(url: page.displayURL ?? "", title: page.webView.title ?? "", in: space, page: page)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if !expanded { page.teardown() }
        Self.all.removeAll { $0 === self }
    }
}
