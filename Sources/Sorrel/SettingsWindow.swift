import AppKit
import WebKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Runs a closure from a control's target/action.
private final class Trampoline: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
                                      NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var trampolines: [Trampoline] = []
    private var fieldCommits: [ObjectIdentifier: (String) -> Void] = [:]
    private let tabs = NSTabView()

    // Extensions
    private let extensionList = NSStackView()

    // Privacy
    private let blockerStatus = NSTextField(labelWithString: "")
    private let defaultBrowserStatus = NSTextField(labelWithString: "")
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private var updateButton: NSButton?

    // Shortcuts
    private let table = NSTableView()
    private let search = NSSearchField()
    private let shortcutHint = NSTextField(labelWithString: "")
    private var commands: [Command] = []
    private var recordingFor: String?
    private var recordMonitor: Any?
    private var recordButton: NSButton!

    private static let searchEngines: [(String, String)] = [
        ("DuckDuckGo", "https://duckduckgo.com/?q=%s"),
        ("Google", "https://www.google.com/search?q=%s"),
        ("Kagi", "https://kagi.com/search?q=%s"),
        ("Brave Search", "https://search.brave.com/search?q=%s"),
        ("Startpage", "https://www.startpage.com/do/search?q=%s"),
        ("Bing", "https://www.bing.com/search?q=%s"),
        ("Ecosia", "https://www.ecosia.org/search?q=%s"),
    ]

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Sorrel Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.center()
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus),
                                               name: .sorrelBlockerStatus, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadExtensions),
                                               name: .sorrelExtensions, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshUpdateStatus),
                                               name: .sorrelUpdateState, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(reloadExtensions),
                                               name: WKWebExtensionContext.errorsDidUpdateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: Int? = nil) {
        if let tab, tab < tabs.numberOfTabViewItems { tabs.selectTabViewItem(at: tab) }
        Extensions.shared.discover()
        refreshStatus()
        reloadShortcuts()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        bringAppForward()
    }

    func windowWillClose(_ notification: Notification) { stopRecording(message: "") }

    // MARK: Small builders

    private func mutate(blocking: Bool = false, _ change: (inout Settings) -> Void) {
        change(&Settings.current)
        Settings.current.save()
        AppDelegate.shared.settingsChanged(blocking: blocking)
    }

    private func hold(_ run: @escaping () -> Void) -> Trampoline {
        let t = Trampoline(run)
        trampolines.append(t)
        return t
    }

    private func checkbox(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = value ? .on : .off
        let t = hold { [weak b] in set(b?.state == .on) }
        b.target = t
        b.action = #selector(Trampoline.fire)
        return b
    }

    private func button(_ title: String, _ run: @escaping () -> Void) -> NSButton {
        let t = hold(run)
        return NSButton(title: title, target: t, action: #selector(Trampoline.fire))
    }

    private func popup(_ titles: [String], selected: Int, _ set: @escaping (Int) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.addItems(withTitles: titles)
        p.selectItem(at: max(0, min(selected, titles.count - 1)))
        let t = hold { [weak p] in set(p?.indexOfSelectedItem ?? 0) }
        p.target = t
        p.action = #selector(Trampoline.fire)
        return p
    }

    /// A text field that saves when editing ends.
    private func field(_ value: String, placeholder: String = "", width: CGFloat = 320, _ commit: @escaping (String) -> Void) -> NSTextField {
        let f = NSTextField(string: value)
        f.placeholderString = placeholder
        f.delegate = self
        f.lineBreakMode = .byTruncatingTail
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        fieldCommits[ObjectIdentifier(f)] = commit
        return f
    }

    private func slider(_ value: Double, _ min: Double, _ max: Double, unit: String, digits: Int = 0,
                        _ set: @escaping (Double) -> Void) -> NSView {
        let s = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        s.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let label = NSTextField(labelWithString: "")
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        let show = { (v: Double) in label.stringValue = String(format: "%.\(digits)f", v) + unit }
        show(value)
        let t = hold { [weak s] in
            let v = s?.doubleValue ?? value
            show(v)
            set(v)
        }
        s.target = t
        s.action = #selector(Trampoline.fire)
        let row = NSStackView(views: [s, label])
        row.spacing = 8
        return row
    }

    private func note(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 380
        return l
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    /// A two-column form: labels on the left, controls on the right.
    private func form(_ rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView(views: rows.map { [label($0.0), $0.1] })
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        for (i, row) in rows.enumerated() where row.1 is NSStackView || !(row.1 is NSControl) {
            grid.row(at: i).rowAlignment = .none
            grid.row(at: i).yPlacement = .top
        }
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16),
        ])
        return container
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        return s
    }

    private func addTab(_ title: String, _ view: NSView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        tabs.addTabViewItem(item)
    }

    // MARK: Building

    private func build() {
        guard let content = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])
        addTab("General", generalTab())
        addTab("Privacy", privacyTab())
        addTab("Extensions", extensionsTab())
        addTab("Tabs", tabsTab())
        addTab("Sidebar", sidebarTab())
        addTab("Shortcuts", shortcutsTab())
    }

    private func generalTab() -> NSView {
        let s = Settings.current
        let engines = Self.searchEngines
        let current = engines.firstIndex { $0.1 == s.searchEngineURL } ?? engines.count
        let custom = field(current == engines.count ? s.searchEngineURL : "", placeholder: "https://example.com/search?q=%s") { [weak self] text in
            guard text.contains("%s"), URL(string: text.replacingOccurrences(of: "%s", with: "x")) != nil else { return }
            self?.mutate { $0.searchEngineURL = text; $0.searchEngineName = URL(string: text)?.host ?? "the web" }
        }
        custom.isEnabled = current == engines.count
        let enginePopup = popup(engines.map { $0.0 } + ["Custom…"], selected: current) { [weak self, weak custom] i in
            custom?.isEnabled = i == engines.count
            if i < engines.count {
                self?.mutate { $0.searchEngineName = engines[i].0; $0.searchEngineURL = engines[i].1 }
            } else {
                custom?.window?.makeFirstResponder(custom)
            }
        }
        defaultBrowserStatus.textColor = .secondaryLabelColor
        defaultBrowserStatus.font = .systemFont(ofSize: 11)
        let makeDefault = button("Make Sorrel the Default Browser") { [weak self] in self?.makeDefaultBrowser() }
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.preferredMaxLayoutWidth = 380
        let check = button("Check Now") { Updater.shared.checkOrRelaunch() }
        check.controlSize = .small
        updateButton = check
        let info = Updater.shared.current
        let versionLine = note("Sorrel \(info?.version ?? "?") (build \(info?.build ?? 0))")
        versionLine.textColor = .labelColor
        refreshUpdateStatus()

        return form([
            ("Search engine:", enginePopup),
            ("Custom search address:", column([custom, note("Use %s where the search words go. Bangs like !w work with any engine.")])),
            ("Suggestions:", column([
                checkbox("Suggest searches as I type", s.searchSuggestions) { [weak self] on in
                    self?.mutate { $0.searchSuggestions = on }
                },
                note("Off by default, because it sends what you type to the search engine before you press Return."),
            ])),
            ("Backup browser:", column([
                field(s.fallbackBrowser, placeholder: "Helium", width: 180) { [weak self] text in
                    self?.mutate { $0.fallbackBrowser = text.trimmingCharacters(in: .whitespaces) }
                },
                note("The app that “Open Page in …” sends the current page to, for the rare site that needs Chromium."),
            ])),
            ("Links from other apps:", checkbox("Open in a mini window", s.externalLinksOpenInMiniWindow) { [weak self] on in
                self?.mutate { $0.externalLinksOpenInMiniWindow = on }
            }),
            ("Default browser:", column([makeDefault, defaultBrowserStatus])),
            ("Updates:", column([
                versionLine,
                checkbox("Check for updates automatically", s.checkForUpdates) { [weak self] on in
                    self?.mutate { $0.checkForUpdates = on }
                },
                check,
                updateStatus,
                note("Updates come from Sorrel’s GitHub releases and are signed; one that fails the check is never installed. A downloaded update installs when you quit Sorrel."),
            ])),
        ])
    }

    private func privacyTab() -> NSView {
        let s = Settings.current
        blockerStatus.textColor = .secondaryLabelColor
        blockerStatus.font = .systemFont(ofSize: 11)
        blockerStatus.lineBreakMode = .byTruncatingTail
        let update = button("Update Lists Now") { Blocker.shared.update() }
        update.controlSize = .small

        return form([
            ("Ads and trackers:", column([
                checkbox("Block ads and trackers with Sorrel’s built-in lists", s.blockAds) { [weak self] on in
                    self?.mutate(blocking: true) { $0.blockAds = on }
                },
                blockerStatus,
                update,
            ])),
            ("Cookie notices:", column([
                checkbox("Hide cookie-consent notices", s.blockCookieNotices) { [weak self] on in
                    self?.mutate(blocking: true) { $0.blockCookieNotices = on }
                },
                note("Uses an extra filter list. It can occasionally break a site; turn blocking off for that site if so."),
            ])),
            ("Blocking is off on:", column([
                field(s.blockingDisabledSites.joined(separator: ", "), placeholder: "example.com, another.org") { [weak self] text in
                    self?.mutate(blocking: true) { $0.blockingDisabledSites = Self.splitList(text) }
                },
                note("Separate sites with commas."),
            ])),
            ("Links:", checkbox("Remove tracking codes from links (utm_…, fbclid, gclid)", s.stripTrackingParameters) { [weak self] on in
                self?.mutate { $0.stripTrackingParameters = on }
            }),
            ("Connections:", column([
                checkbox("Always try a secure connection first (HTTPS-first)", s.httpsFirst) { [weak self] on in
                    self?.mutate { $0.httpsFirst = on }
                },
                note("Plain http:// sites are opened with encryption when they support it. If one doesn’t, Sorrel warns you before showing it."),
            ])),
            ("Stored data:", column([
                button("Clear History…") { Commands.shared.run("history.clear") },
                button("Clear Cookies and Website Data…") { Commands.shared.run("data.clear") },
            ])),
        ])
    }

    private func tabsTab() -> NSView {
        let s = Settings.current
        let hours: [Double] = [0, 12, 24, 168, 720]
        let names = ["Never", "After 12 hours", "After 24 hours", "After 7 days", "After 30 days"]
        let archive = popup(names, selected: hours.firstIndex(of: s.archiveAfterHours) ?? 2) { [weak self] i in
            self?.mutate { $0.archiveAfterHours = hours[i] }
        }
        let previewMode = s.peekLinksFromAllTabs ? 0 : (s.peekLinksFromPinnedTabs ? 1 : 2)
        let previews = popup(["From every tab", "From pinned tabs and favorites only", "Never"], selected: previewMode) { [weak self] i in
            self?.mutate { $0.peekLinksFromAllTabs = i == 0; $0.peekLinksFromPinnedTabs = i <= 1 }
        }
        return form([
            ("Archive unpinned tabs:", column([
                archive,
                note("Unpinned tabs you haven’t touched are put away. Find them under Tabs ▸ Archived Tabs. Pinned tabs and favorites are never archived."),
            ])),
            ("Sleep unused tabs:", column([
                {
                    let minutes: [Double] = [0, 30, 60, 120, 360]
                    return popup(["Never", "After 30 minutes", "After 1 hour", "After 2 hours", "After 6 hours"],
                                 selected: minutes.firstIndex(of: s.sleepTabsAfterMinutes) ?? 3) { [weak self] i in
                        self?.mutate { $0.sleepTabsAfterMinutes = minutes[i] }
                    }
                }(),
                note("A sleeping tab stays in the sidebar and uses no memory. It reloads where you left it when you open it. Tabs playing sound or in a call are left alone."),
            ])),
            ("Preview links to other sites:", column([
                previews,
                note("A link that leaves the current site opens as a preview over the page. Shift-click always previews."),
            ])),
            ("No previews from:", column([
                field(s.peekExcludedSites.joined(separator: ", ")) { [weak self] text in
                    self?.mutate { $0.peekExcludedSites = Self.splitList(text) }
                },
                note("Links on these sites open normally. A bare name like “google” covers every country version. Your search engine is always included."),
            ])),
        ])
    }

    private func sidebarTab() -> NSView {
        let s = Settings.current
        return form([
            ("Reveal strip:", column([
                slider(s.sidebarHoverEdgeWidth, 2, 40, unit: " pt") { [weak self] v in self?.mutate { $0.sidebarHoverEdgeWidth = v.rounded() } },
                note("How close to the window’s left edge the cursor must come to reveal a hidden sidebar."),
            ])),
            ("Overshoot reach:", column([
                slider(s.sidebarOvershootReach, 0, 200, unit: " pt") { [weak self] v in self?.mutate { $0.sidebarOvershootReach = v.rounded() } },
                note("Flicking past the edge still reveals the sidebar within this distance outside the window. 0 turns it off."),
            ])),
            ("Hide delay:", slider(s.sidebarHideDelay, 0, 1, unit: " s", digits: 2) { [weak self] v in
                self?.mutate { $0.sidebarHideDelay = (v * 100).rounded() / 100 }
            }),
            ("Slide speed:", slider(s.sidebarAnimationDuration, 0.05, 0.5, unit: " s", digits: 2) { [weak self] v in
                self?.mutate { $0.sidebarAnimationDuration = (v * 100).rounded() / 100 }
            }),
            ("In the background:", checkbox("Reveal on hover even when Sorrel isn’t the front app", s.sidebarHoverWhenInactive) { [weak self] on in
                self?.mutate { $0.sidebarHoverWhenInactive = on }
            }),
        ])
    }

    private func shortcutsTab() -> NSView {
        let container = NSView()
        search.placeholderString = "Filter commands"
        search.delegate = self
        search.sendsSearchStringImmediately = true

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Command"
        nameColumn.width = 320
        let keyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        keyColumn.title = "Shortcut"
        keyColumn.width = 200
        table.addTableColumn(nameColumn)
        table.addTableColumn(keyColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(recordSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        recordButton = button("Record Shortcut") { [weak self] in self?.recordSelected() }
        let clear = button("Remove") { [weak self] in self?.clearSelected() }
        let reset = button("Reset All…") { [weak self] in self?.resetAll() }
        let buttons = NSStackView(views: [recordButton, clear, NSView(), reset])
        buttons.spacing = 8
        shortcutHint.font = .systemFont(ofSize: 11)
        shortcutHint.textColor = .secondaryLabelColor
        shortcutHint.lineBreakMode = .byTruncatingTail
        setIdleHint()

        for v in [search, scroll, buttons, shortcutHint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            shortcutHint.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            shortcutHint.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            shortcutHint.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            shortcutHint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    // MARK: Extensions

    private func extensionsTab() -> NSView {
        let container = NSView()
        extensionList.orientation = .vertical
        extensionList.alignment = .leading
        extensionList.spacing = 14
        extensionList.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

        // A flipped document view keeps the list at the top of the scroll area.
        let document = FlippedView()
        extensionList.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(extensionList)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false

        let add = button("Add Extension…") { [weak self] in self?.addExtension() }
        let store = button("Add from Chrome Web Store…") { [weak self] in self?.addFromChromeStore() }
        let reveal = button("Show Folder") { NSWorkspace.shared.open(Extensions.shared.folder) }
        let update = button("Check for Updates") { Commands.shared.run("extensions.update") }
        let buttons = NSStackView(views: [store, add, update, reveal])
        buttons.spacing = 8
        let hint = note("Safari extensions already on this Mac are listed here, switched off until you turn them on. Chrome extensions can be added by pasting their Web Store link; many work, but ones that lean on Chrome-only features may not. Extensions from the Web Store and uBlock Origin Lite are kept up to date automatically; an update is used the next time Sorrel opens. Extensions do not run in private windows.")
        hint.preferredMaxLayoutWidth = 560

        for v in [scroll, buttons, hint] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            extensionList.topAnchor.constraint(equalTo: document.topAnchor),
            extensionList.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            extensionList.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            extensionList.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        reloadExtensions()
        return container
    }

    @objc private func reloadExtensions() {
        extensionList.arrangedSubviews.forEach { extensionList.removeArrangedSubview($0); $0.removeFromSuperview() }
        let ext = Extensions.shared
        for entry in ext.entries {
            let title = entry.name + (entry.version.isEmpty ? "" : "  \(entry.version)")
            let toggle = checkbox(title, ext.isEnabled(entry)) { [weak self] on in self?.toggleExtension(entry, on) }
            toggle.font = .systemFont(ofSize: 13, weight: .medium)

            var detail = entry.sourceText
            if entry.isLoading { detail += " · starting…" }
            else if entry.isLoaded { detail += " · on" }
            if !entry.summary.isEmpty, entry.isLoaded { detail += "\n" + entry.summary }
            if ext.hasPendingUpdate(entry) { detail += "\nAn update is ready and will be used the next time Sorrel opens." }
            // Its keyboard shortcuts, so they can be discovered (and clashes with Sorrel's own noticed).
            let shortcuts = ext.commands(for: entry).compactMap { c in Extensions.shortcutText(for: c).map { "\(c.title) \($0)" } }
            if !shortcuts.isEmpty { detail += "\nShortcuts: " + shortcuts.joined(separator: " · ") }
            let info = note(detail)
            info.preferredMaxLayoutWidth = 470

            var rowViews: [NSView] = [toggle, info]
            if let error = entry.error {
                let problem = note(error)
                problem.textColor = .systemRed
                problem.preferredMaxLayoutWidth = 470
                rowViews.append(problem)
            }
            // Anything the extension itself has tripped over, so a misbehaving one can be diagnosed.
            let problems = (entry.context?.errors ?? []).map { $0.localizedDescription }
            if !problems.isEmpty {
                let shown = note("Problems it reported:\n" + problems.suffix(3).joined(separator: "\n"))
                shown.textColor = .systemOrange
                shown.preferredMaxLayoutWidth = 470
                shown.maximumNumberOfLines = 6
                rowViews.append(shown)
            }
            var actions: [NSView] = []
            if !problems.isEmpty {
                let b = button("Copy Problems") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(entry.name) \(entry.version)\n" + problems.joined(separator: "\n"), forType: .string)
                }
                b.controlSize = .small
                actions.append(b)
            }
            if entry.context?.optionsPageURL != nil {
                let b = button("Settings") { Extensions.shared.openOptions(entry) }
                b.controlSize = .small
                actions.append(b)
            }
            if case .folder = entry.source {
                let b = button("Remove") { Extensions.shared.remove(entry) }
                b.controlSize = .small
                actions.append(b)
            }
            if !actions.isEmpty {
                let row = NSStackView(views: actions)
                row.spacing = 6
                rowViews.append(row)
            }
            let block = column(rowViews)
            block.spacing = 3
            extensionList.addArrangedSubview(block)
        }
        if ext.entries.isEmpty {
            extensionList.addArrangedSubview(note("No extensions found."))
        }
    }

    private func toggleExtension(_ entry: ExtensionEntry, _ on: Bool) {
        guard on, !entry.isBundled, let window else {
            Extensions.shared.setEnabled(entry, on)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Turn on \(entry.name)?"
        alert.informativeText = "It will be able to read and change the pages you visit, as its maker designed it to. Only turn on extensions you trust."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                Extensions.shared.setEnabled(entry, true)
            } else {
                self?.reloadExtensions()
            }
        }
    }

    private func addFromChromeStore() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add an extension from the Chrome Web Store"
        alert.informativeText = "Paste the address of the extension’s Web Store page."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "https://chromewebstore.google.com/detail/…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Extensions.shared.addFromChromeStore(field.stringValue) { result in
                switch result {
                case .success(let entry):
                    self?.toggleExtension(entry, true)
                case .failure(let error):
                    let problem = NSAlert()
                    problem.messageText = "Couldn’t add that extension"
                    problem.informativeText = error.localizedDescription
                    problem.beginSheetModal(for: window)
                }
            }
        }
    }

    private func addExtension() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an unpacked extension folder (the one containing manifest.json) or a .zip of one."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if let entry = try Extensions.shared.add(from: url) { self?.toggleExtension(entry, true) }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t add that extension"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window)
            }
        }
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    // MARK: Status

    @objc private func refreshUpdateStatus() {
        updateStatus.stringValue = Updater.shared.statusText
        updateButton?.title = Updater.shared.readyManifest != nil ? "Relaunch to Update" : "Check Now"
        updateButton?.isEnabled = !Updater.shared.isBusy
    }

    @objc private func refreshStatus() {
        blockerStatus.stringValue = Blocker.shared.statusText
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let isDefault = handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        let name = handler?.deletingPathExtension().lastPathComponent ?? "another app"
        defaultBrowserStatus.stringValue = isDefault ? "Sorrel is your default browser." : "Links currently open in \(name)."
    }

    private func makeDefaultBrowser() {
        let app = Bundle.main.bundleURL
        // macOS asks the person to confirm the change itself.
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { [weak self] _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                DispatchQueue.main.async { self?.refreshStatus() }
            }
        }
    }

    // MARK: Text fields

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let commit = fieldCommits[ObjectIdentifier(f)] else { return }
        commit(f.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSSearchField) === search { reloadShortcuts() }
    }

    // MARK: Shortcuts

    private func setIdleHint() {
        shortcutHint.stringValue = "Double-click a command to give it a new shortcut. Two-step shortcuts (like ⌘K ⌘T) can be set in keybindings.json."
    }

    private func reloadShortcuts() {
        let q = search.stringValue.lowercased()
        commands = Commands.shared.all.filter { c in
            q.isEmpty || c.title.lowercased().contains(q) || Keybindings.shared.displayAll(for: c.id).lowercased().contains(q)
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let c = NSTableCellView()
            c.identifier = id
            let t = NSTextField(labelWithString: "")
            t.lineBreakMode = .byTruncatingTail
            t.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let command = commands[row]
        if id.rawValue == "name" {
            cell.textField?.stringValue = command.title
            cell.textField?.textColor = .labelColor
        } else if recordingFor == command.id {
            cell.textField?.stringValue = "Press keys…"
            cell.textField?.textColor = .controlAccentColor
        } else {
            let keys = Keybindings.shared.displayAll(for: command.id)
            cell.textField?.stringValue = keys.isEmpty ? "—" : keys
            cell.textField?.textColor = keys.isEmpty ? .tertiaryLabelColor : .labelColor
        }
        return cell
    }

    @objc private func recordSelected() {
        if recordingFor != nil { stopRecording(message: nil); setIdleHint(); return }
        let row = table.selectedRow >= 0 ? table.selectedRow : table.clickedRow
        guard row >= 0, row < commands.count else {
            shortcutHint.stringValue = "Select a command first."
            return
        }
        stopRecording(message: nil)
        let command = commands[row]
        recordingFor = command.id
        recordButton.title = "Cancel"
        shortcutHint.stringValue = "Press the new shortcut for “\(command.title)”. Esc cancels."
        table.reloadData()
        table.selectRowIndexes([row], byExtendingSelection: false)
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.captured(event)
            return nil
        }
    }

    private func captured(_ event: NSEvent) {
        guard let id = recordingFor, let stroke = Keybindings.stroke(for: event) else { return }
        if stroke == "escape" { stopRecording(message: nil); setIdleHint(); return }
        let hasModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        guard hasModifier else {
            NSSound.beep()
            shortcutHint.stringValue = "Shortcuts need ⌘, ⌃ or ⌥ so they don’t get in the way of typing. Try again, or Esc to cancel."
            return
        }
        let previous = Keybindings.shared.command(onStroke: stroke)
        Keybindings.shared.setShortcut(stroke, for: id)
        AppDelegate.shared.buildMenu()
        var message = "Set \(Keybindings.pretty(stroke)) for “\(Commands.shared.title(id) ?? id)”."
        if let previous, previous != id, let title = Commands.shared.title(previous) {
            message += " It was taken from “\(title)”."
        }
        stopRecording(message: message)
    }

    private func stopRecording(message: String?) {
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        let was = recordingFor
        recordingFor = nil
        recordButton?.title = "Record Shortcut"
        if let message, !message.isEmpty { shortcutHint.stringValue = message }
        if was != nil { reloadShortcuts() }
    }

    private func clearSelected() {
        if recordingFor != nil { stopRecording(message: nil); setIdleHint(); return }
        let row = table.selectedRow
        guard row >= 0, row < commands.count else { return }
        let command = commands[row]
        Keybindings.shared.setShortcut(nil, for: command.id)
        AppDelegate.shared.buildMenu()
        shortcutHint.stringValue = "Removed the shortcut for “\(command.title)”."
        reloadShortcuts()
    }

    private func resetAll() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset every shortcut to its default?"
        alert.informativeText = "This removes all of your custom shortcuts, including any in keybindings.json."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Keybindings.shared.resetAll()
            AppDelegate.shared.buildMenu()
            self?.shortcutHint.stringValue = "All shortcuts are back to their defaults."
            self?.reloadShortcuts()
        }
    }
}
