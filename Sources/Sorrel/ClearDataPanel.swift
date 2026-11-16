import AppKit
import WebKit

// Clear Browsing Data (⇧⌘⌫), as in Firefox and Zen: pick a time range, tick what goes, see how much each takes.
// And Manage Website Data: every site that stored something, searchable, removable one by one.

private func showToast(_ text: String) { AppDelegate.shared.main.showToast(text) }

/// The window a sheet should hang from: the Settings window when it is in front, otherwise the main window.
private func sheetParent() -> NSWindow? {
    if let key = NSApp.keyWindow, key.attachedSheet == nil, !(key is NSPanel) { return key }
    return AppDelegate.shared.main.window
}

final class ClearDataPanel: NSWindowController {
    /// The one open now, so a second ⇧⌘⌫ doesn't stack another sheet.
    private static var current: ClearDataPanel?

    private let rangePopup = NSPopUpButton()
    private let historyBox = NSButton(checkboxWithTitle: "Browsing history", target: nil, action: nil)
    private let siteDataBox = NSButton(checkboxWithTitle: "Cookies and site data", target: nil, action: nil)
    private let cacheBox = NSButton(checkboxWithTitle: "Cached images and files", target: nil, action: nil)
    private let historyDetail = ClearDataPanel.detail()
    private let siteDataDetail = ClearDataPanel.detail()
    private let cacheDetail = ClearDataPanel.detail()
    private let clearButton = NSButton(title: "Clear Now", target: nil, action: nil)
    private var usage: Cleanup.Usage?

    /// Remembered between openings (not between launches), like Firefox.
    private static var lastRange = Cleanup.Range.hour
    private static var lastKinds: Cleanup.Kinds = [.history, .cache]

    /// Opens the panel. `kinds` preselects what to clear (otherwise the last choice); `range` likewise.
    static func present(kinds: Cleanup.Kinds? = nil, range: Cleanup.Range? = nil) {
        if let open = current, let w = open.window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ClearDataPanel(kinds: kinds ?? lastKinds, range: range ?? lastRange)
        current = panel
        guard let w = panel.window else { return }
        if let parent = sheetParent() {
            if parent === AppDelegate.shared.main.window { AppDelegate.shared.showMainWindow() }
            parent.beginSheet(w)
        } else {
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
    }

    private init(kinds: Cleanup.Kinds, range: Cleanup.Range) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Clear Browsing Data"
        super.init(window: w)
        build(in: w)
        rangePopup.addItems(withTitles: Cleanup.Range.allCases.map(\.title))
        rangePopup.selectItem(at: range.rawValue)
        historyBox.state = kinds.contains(.history) ? .on : .off
        siteDataBox.state = kinds.contains(.siteData) ? .on : .off
        cacheBox.state = kinds.contains(.cache) ? .on : .off
        refresh()
        Cleanup.measure { [weak self] u in
            self?.usage = u
            self?.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func detail() -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 340
        return l
    }

    private func build(in w: NSWindow) {
        let title = NSTextField(labelWithString: "Clear Browsing Data")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let rangeLabel = NSTextField(labelWithString: "Time range:")
        rangePopup.target = self
        rangePopup.action = #selector(changed)
        let rangeRow = NSStackView(views: [rangeLabel, rangePopup])
        rangeRow.spacing = 8

        for box in [historyBox, siteDataBox, cacheBox] {
            box.target = self
            box.action = #selector(changed)
            box.font = .systemFont(ofSize: 13, weight: .medium)
        }
        func option(_ box: NSButton, _ detail: NSTextField) -> NSStackView {
            // The detail lines up under the checkbox's title, not its box.
            let indent = NSView()
            indent.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let line = NSStackView(views: [indent, detail])
            line.spacing = 0
            let s = NSStackView(views: [box, line])
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 1
            return s
        }
        let options = NSStackView(views: [option(historyBox, historyDetail), option(siteDataBox, siteDataDetail),
                                          option(cacheBox, cacheDetail)])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 12

        let manage = NSButton(title: "Manage Website Data…", target: self, action: #selector(manage))
        manage.bezelStyle = .push
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        clearButton.target = self
        clearButton.action = #selector(clearNow)
        clearButton.keyEquivalent = "\r"
        clearButton.hasDestructiveAction = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [manage, spacer, cancel, clearButton])
        buttons.spacing = 8

        let note = ClearDataPanel.detail()
        note.stringValue = "Open tabs, pinned tabs, passwords in extensions and downloaded files are never touched."

        let stack = NSStackView(views: [title, rangeRow, options, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44),
        ])
        w.contentView = content
        w.setContentSize(content.fittingSize)
    }

    private var range: Cleanup.Range { Cleanup.Range(rawValue: rangePopup.indexOfSelectedItem) ?? .hour }

    private var kinds: Cleanup.Kinds {
        var k: Cleanup.Kinds = []
        if historyBox.state == .on { k.insert(.history) }
        if siteDataBox.state == .on { k.insert(.siteData) }
        if cacheBox.state == .on { k.insert(.cache) }
        return k
    }

    @objc private func changed() { refresh() }

    /// Fills in the detail lines for the chosen time range.
    private func refresh() {
        let r = range
        let pages = r == .all ? History.shared.count : History.shared.count(since: r.since)
        let when = r == .all ? "" : " from the \(r.title.lowercased())"
        historyDetail.stringValue = pages == 0
            ? "No pages\(when) · also the downloads list and archived tabs"
            : "\(pages.formatted()) page\(pages == 1 ? "" : "s")\(when), plus the downloads list and archived tabs"
        if let u = usage {
            let sites = "\(u.sites) site\(u.sites == 1 ? "" : "s")"
            let cookies = u.sitesWithCookies > 0 ? ", \(u.sitesWithCookies) with cookies" : ""
            siteDataDetail.stringValue = r == .all
                ? "\(sites) store data here\(cookies) · you’ll be signed out of them"
                : "What sites saved\(when) (of \(sites) in all) · you may be signed out"
            let size = Cleanup.bytes(u.cacheBytes + u.iconBytes)
            cacheDetail.stringValue = r == .all
                ? "\(size) · pages simply load them again"
                : "Files saved\(when) (of \(size) in all) · pages simply load them again"
        } else {
            siteDataDetail.stringValue = "Counting… · you’ll be signed out of the sites cleared"
            cacheDetail.stringValue = "Measuring… · pages simply load them again"
        }
        clearButton.isEnabled = !kinds.isEmpty
    }

    private func dismiss(then next: (() -> Void)? = nil) {
        guard let w = window else { return }
        if let parent = w.sheetParent { parent.endSheet(w) } else { w.orderOut(nil) }
        Self.current = nil
        next?()
    }

    @objc private func cancel() { dismiss() }

    @objc private func manage() { dismiss { WebsiteDataPanel.present() } }

    @objc private func clearNow() {
        let k = kinds, r = range
        guard !k.isEmpty else { return }
        Self.lastKinds = k
        Self.lastRange = r
        dismiss()
        Cleanup.clear(k, since: r.since) {
            var what: [String] = []
            if k.contains(.history) { what.append("history") }
            if k.contains(.siteData) { what.append("cookies and site data") }
            if k.contains(.cache) { what.append("cache") }
            let list = ListFormatter.localizedString(byJoining: what)
            showToast("Cleared " + list + (r == .all ? "" : " from the \(r.title.lowercased())"))
        }
    }

    /// Test hook: ticks, range and the detail lines as text.
    static var debugState: String? {
        guard let p = current else { return nil }
        return "range=\(p.range.title) history=\(p.historyBox.state == .on) site=\(p.siteDataBox.state == .on) cache=\(p.cacheBox.state == .on) | \(p.historyDetail.stringValue) | \(p.siteDataDetail.stringValue) | \(p.cacheDetail.stringValue)"
    }

    /// Test hook: choose a range and kinds, then press Clear Now.
    static func debugClear(range: Cleanup.Range, kinds: Cleanup.Kinds) {
        guard let p = current else { return }
        p.rangePopup.selectItem(at: range.rawValue)
        p.historyBox.state = kinds.contains(.history) ? .on : .off
        p.siteDataBox.state = kinds.contains(.siteData) ? .on : .off
        p.cacheBox.state = kinds.contains(.cache) ? .on : .off
        p.clearNow()
    }
}

// MARK: - Manage Website Data

/// Every website that has stored cookies or data, as in Safari's Manage Website Data: search, remove some, or all.
final class WebsiteDataPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static var current: WebsiteDataPanel?

    private var all: [Cleanup.SiteData] = []
    private var shown: [Cleanup.SiteData] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "Loading…")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let removeAllButton = NSButton(title: "Remove All", target: nil, action: nil)

    static func present() {
        if let open = current, let w = open.window, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let panel = WebsiteDataPanel()
        current = panel
        guard let w = panel.window else { return }
        if let parent = sheetParent() { parent.beginSheet(w) } else { w.center(); w.makeKeyAndOrderFront(nil) }
        panel.reload()
    }

    private init() {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.title = "Manage Website Data"
        w.minSize = NSSize(width: 420, height: 300)
        super.init(window: w)
        build(in: w)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(in w: NSWindow) {
        let title = NSTextField(labelWithString: "Websites that stored data on this Mac")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        search.placeholderString = "Search websites"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let site = NSTableColumn(identifier: .init("site"))
        site.title = "Website"
        site.width = 220
        let kinds = NSTableColumn(identifier: .init("kinds"))
        kinds.title = "Stored"
        kinds.width = 220
        table.addTableColumn(site)
        table.addTableColumn(kinds)
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.isEnabled = false
        removeAllButton.target = self
        removeAllButton.action = #selector(removeAll)
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [removeButton, removeAllButton, status, spacer, done])
        buttons.spacing = 8

        let content = NSView()
        for v in [title, search, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            search.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            search.widthAnchor.constraint(equalToConstant: 170),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        w.contentView = content
    }

    private func reload() {
        Cleanup.fetchSites { [weak self] sites in
            guard let self else { return }
            self.all = sites
            self.filter()
        }
    }

    private func filter() {
        let q = search.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        shown = q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
        table.reloadData()
        let n = all.count
        status.stringValue = n == 0 ? "No website data" : "\(n) website\(n == 1 ? "" : "s")"
        removeAllButton.isEnabled = !shown.isEmpty
        removeAllButton.title = q.isEmpty ? "Remove All" : "Remove All Shown"
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let site = shown[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "site" ? site.name : site.summary)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        if tableColumn?.identifier.rawValue != "site" { text.textColor = .secondaryLabelColor }
        cell.addSubview(text)
        cell.textField = text
        var leading = text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2)
        if tableColumn?.identifier.rawValue == "site" {
            let icon = NSImageView(image: FaviconStore.shared.image(forHost: site.name) ?? symbol("globe", size: 12) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
            ])
            leading = text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6)
        }
        NSLayoutConstraint.activate([
            leading,
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    @objc private func removeSelected() {
        let picked = table.selectedRowIndexes.compactMap { shown.indices.contains($0) ? shown[$0] : nil }
        remove(picked)
    }

    @objc private func removeAll() {
        let targets = shown
        guard !targets.isEmpty, let w = window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = targets.count == all.count
            ? "Remove data stored by all websites?" : "Remove data stored by \(targets.count) website\(targets.count == 1 ? "" : "s")?"
        alert.informativeText = "You will be signed out of them, and their saved data and cached files are erased. History is not affected."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: w) { [weak self] in if $0 == .alertFirstButtonReturn { self?.remove(targets) } }
    }

    private func remove(_ sites: [Cleanup.SiteData]) {
        guard !sites.isEmpty else { return }
        status.stringValue = "Removing…"
        Cleanup.remove(sites) { [weak self] in
            showToast(sites.count == 1 ? "Removed data from \(sites[0].name)" : "Removed data from \(sites.count) websites")
            self?.reload()
        }
    }

    @objc private func done() {
        guard let w = window else { return }
        if let parent = w.sheetParent { parent.endSheet(w) } else { w.orderOut(nil) }
        Self.current = nil
    }

    /// Test hook: the listed sites.
    static var debugSites: [String]? { current?.all.map { "\($0.name) [\($0.summary)]" } }
}
