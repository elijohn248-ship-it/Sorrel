import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private(set) var main: MainWindowController!
    private var pendingURLs: [URL] = []
    private var launched = false
    private var keyMonitor: Any?
    private var archiveTimer: Timer?
    private let archivedMenu = NSMenu(title: "Archived Tabs")
    private let historyMenu = NSMenu(title: "History")

    private var store: Store { Store.shared }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Bangs.shared
        registerCommands()
        wireEngine()
        main = MainWindowController()
        buildMenu()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let w = event.window,
                  w.windowController is MainWindowController || w.windowController is MiniWindowController,
                  w.attachedSheet == nil else { return event }
            // Esc closes an open preview.
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               w === self.main.window, self.main.peek != nil, self.main.commandBar.isHidden {
                self.main.dismissPeek()
                return nil
            }
            return Keybindings.shared.handle(event) ? nil : event
        }

        if isQuietTest { main.window?.orderBack(nil) } else { main.showWindow(nil) }
        bringAppForward()
        launched = true
        Blocker.shared.start()
        Extensions.shared.start()
        Extensions.shared.windowReady()
        // Put away long-unused tabs shortly after launch, then keep checking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.archiveStaleTabs() }
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.archiveStaleTabs()
            Store.shared.sleepIdleTabs(olderThanMinutes: Settings.current.sleepTabsAfterMinutes)
        }
        if !pendingURLs.isEmpty {
            open(pendingURLs)
            pendingURLs = []
        }
        runDebugHooks()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { open(urls) } else { pendingURLs.append(contentsOf: urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
        History.shared.saveNow()
    }

    private func archiveStaleTabs() {
        let n = store.archiveStaleTabs(olderThanHours: Settings.current.archiveAfterHours)
        if n > 0 { main.showToast("Archived \(n) unused tab\(n == 1 ? "" : "s") · Tabs ▸ Archived Tabs") }
    }

    /// Called by the Settings window after a change.
    func settingsChanged(blocking: Bool) {
        main.root.trackWhenInactive = Settings.current.sidebarHoverWhenInactive
        if blocking { Blocker.shared.settingsChanged() }
    }

    func showMainWindow() {
        if isQuietTest {
            if main.window?.isVisible != true { main.window?.orderBack(nil) }
            return
        }
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        bringAppForward()
    }

    /// Links from other apps.
    private func open(_ urls: [URL]) {
        for url in urls {
            if Settings.current.externalLinksOpenInMiniWindow {
                MiniWindowController.present(url: url)
            } else {
                store.newTab(url: url.absoluteString)
                showMainWindow()
            }
        }
    }

    // MARK: Engine callbacks

    private func wireEngine() {
        let engine = Engine.shared
        engine.onNewPage = { [weak self] newPage, source in
            guard let self else { return }
            if let item = source?.item {
                let space = self.store.space(containing: item)
                self.store.newTab(url: "", in: space, after: item, page: newPage)
            } else if let source, source === self.main.peek?.page {
                self.store.newTab(url: "", page: newPage)
            } else if source != nil {
                MiniWindowController.present(url: nil, page: newPage, isPrivate: newPage.isPrivate)
            } else {
                self.store.newTab(url: "", page: newPage)
            }
        }
        engine.onOpenInBackground = { [weak self] url, source in
            guard let self else { return }
            // From a private window, the link stays private: it must not become a normal tab with history and cookies.
            if source?.isPrivate == true {
                MiniWindowController.present(url: url, isPrivate: true)
                return
            }
            let item = source?.item
            self.store.newTab(url: url.absoluteString, in: item.flatMap { self.store.space(containing: $0) },
                              after: item, select: false)
            // Background tabs start loading right away, as they do in other browsers.
            if let created = self.store.currentSpace.today.first(where: { $0.url == url.absoluteString && $0.page == nil }) {
                _ = Engine.shared.ensurePage(for: created)
            }
        }
        engine.onPageClosed = { [weak self] page in
            if let item = page.item {
                self?.store.close(item)
            } else {
                MiniWindowController.all.first { $0.page === page }?.close()
            }
        }
        engine.onPeek = { [weak self] url, source in
            self?.main.showPeek(url, profileID: source.profileID)
        }
        engine.onToast = { [weak self] text in self?.main.showToast(text) }
    }

    // MARK: Context

    private var keyMini: MiniWindowController? { NSApp.keyWindow?.windowController as? MiniWindowController }

    /// The preview over the page, when the main window is the one in front.
    private var frontPeek: PeekOverlay? { keyMini == nil ? main.peek : nil }

    /// The page the user is looking at: the mini window's if one is in front, otherwise the selected tab's.
    private var activeWebView: WKWebView? {
        if let mini = keyMini { return mini.page.webView }
        return main.peek?.page.webView ?? main.currentWebView
    }

    private func revealSidebarForEditing() {
        showMainWindow()
        if main.mode != .pinned { main.toggleSidebar() }
    }

    // MARK: Commands

    private func registerCommands() {
        let c = Commands.shared

        c.register("tab.new", "New Tab") { [unowned self] in
            self.showMainWindow()
            self.main.commandBar.present(.newTab)
        }
        c.register("tab.editURL", "Edit Address") { [unowned self] in
            if let mini = self.keyMini { mini.focusAddress(); return }
            self.main.editAddress()
        }
        c.register("tab.close", "Close Tab") { [unowned self] in
            if let mini = self.keyMini { mini.close(); return }
            // Settings and other plain windows: the shortcut just closes them.
            if let w = NSApp.keyWindow, w !== self.main.window { w.performClose(nil); return }
            if !self.main.commandBar.isHidden { self.main.commandBar.dismiss(); return }
            if self.frontPeek != nil { self.main.dismissPeek(); return }
            if let sel = self.store.selected { self.store.close(sel) } else { self.main.window?.performClose(nil) }
        }
        c.register("tab.reopen", "Reopen Closed Tab") { [unowned self] in self.store.reopenClosed() }
        c.register("tab.reload", "Reload Page") { [unowned self] in self.activeWebView?.reload() }
        c.register("tab.hardReload", "Reload Page Ignoring Cache") { [unowned self] in self.activeWebView?.reloadFromOrigin() }
        c.register("tab.togglePin", "Pin or Unpin Tab") { [unowned self] in
            if let sel = self.store.selected { self.store.togglePin(sel) }
        }
        c.register("tab.toggleFavorite", "Add to or Remove from Favorites") { [unowned self] in
            if let sel = self.store.selected { self.store.toggleFavorite(sel) }
        }
        c.register("tab.copyURL", "Copy Link") { [unowned self] in
            guard let u = self.activeWebView?.url?.absoluteString else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(u, forType: .string)
            self.main.showToast("Link copied")
        }
        c.register("tab.duplicate", "Duplicate Tab") { [unowned self] in
            if let sel = self.store.selected, let u = sel.url { self.store.newTab(url: u, title: sel.title, after: sel) }
        }
        c.register("tab.openInFallback", "Open Page in \(Settings.current.fallbackBrowser)") { [unowned self] in
            self.openInFallbackBrowser()
        }
        c.register("tab.next", "Next Tab") { [unowned self] in self.store.selectRelative(1) }
        c.register("tab.previous", "Previous Tab") { [unowned self] in self.store.selectRelative(-1) }
        for n in 1...9 {
            c.register("tab.select.\(n)", "Go to Favorite or Pinned Tab \(n)") { [unowned self] in
                let order = self.store.favorites + self.store.tabs(in: self.store.currentSpace.pinned)
                if n <= order.count { self.store.select(order[n - 1]) }
            }
        }

        // Split view
        func currentSplit() -> Item? { self.store.selected.flatMap { self.store.split(containing: $0) } }
        c.register("split.add", "New Split View…") { [unowned self] in
            self.showMainWindow()
            // With nothing open there is nothing to split beside; it's an ordinary new tab.
            self.main.commandBar.present(self.store.selected == nil ? .newTab : .newSplit)
        }
        c.register("split.separate", "Separate Split View") { [unowned self] in
            if let sv = currentSplit() { self.store.unsplit(sv) }
        }
        c.register("split.removeTab", "Remove Tab from Split View") { [unowned self] in
            if let sel = self.store.selected, currentSplit() != nil { self.store.removeFromSplit(sel) }
        }
        c.register("split.focusNext", "Focus Next Split Pane") { [unowned self] in self.store.focusPane(offset: 1) }
        c.register("split.focusPrevious", "Focus Previous Split Pane") { [unowned self] in self.store.focusPane(offset: -1) }
        c.register("split.rotate", "Switch Split View Between Side by Side and Stacked") { [unowned self] in
            if let sv = currentSplit() { self.store.setSplitStacked(sv, !(sv.split?.stacked ?? false)) }
        }
        c.register("split.swap", "Swap Split View Panes") { [unowned self] in
            if let sv = currentSplit() { self.store.rotatePanes(sv) }
        }
        c.register("split.peek", "Open Preview in Split View") { [unowned self] in
            if self.frontPeek != nil { self.main.splitPeek() }
        }

        c.register("nav.back", "Back") { [unowned self] in self.activeWebView?.goBack() }
        c.register("nav.forward", "Forward") { [unowned self] in self.activeWebView?.goForward() }

        c.register("sidebar.toggle", "Hide or Show Sidebar") { [unowned self] in self.main.toggleSidebar() }
        c.register("find.show", "Find on Page") { [unowned self] in
            if let wv = self.main.currentWebView { self.main.card.findBar.open(for: wv) }
        }
        func zoom(_ change: @escaping (CGFloat) -> CGFloat) -> () -> Void {
            { [unowned self] in
                guard let wv = self.activeWebView else { return }
                wv.pageZoom = max(0.3, min(3, change(wv.pageZoom)))
                // Remembered per site, except in private windows.
                if (wv as? SorrelWebView)?.page?.isPrivate != true {
                    ZoomStore.shared.set(Double(wv.pageZoom), forHost: wv.url?.host)
                }
            }
        }
        c.register("view.zoomIn", "Zoom In", zoom { $0 * 1.1 })
        c.register("view.zoomOut", "Zoom Out", zoom { $0 / 1.1 })
        c.register("view.zoomReset", "Actual Size", zoom { _ in 1 })
        c.register("tab.print", "Print Page…") { [unowned self] in self.printPage() }

        c.register("space.next", "Next Space") { [unowned self] in self.store.switchSpace(offset: 1) }
        c.register("space.previous", "Previous Space") { [unowned self] in self.store.switchSpace(offset: -1) }
        for n in 1...9 {
            c.register("space.\(n)", "Go to Space \(n)") { [unowned self] in
                if n <= self.store.spaces.count { self.store.switchSpace(to: self.store.spaces[n - 1]) }
            }
        }
        c.register("space.new", "New Space") { [unowned self] in
            self.revealSidebarForEditing()
            self.store.addSpace()
            self.main.sidebar.renameCurrentSpace()
        }
        c.register("folder.new", "New Folder") { [unowned self] in
            self.revealSidebarForEditing()
            self.main.sidebar.createFolderAndRename()
        }
        c.register("theme.edit", "Edit Space Theme") { [unowned self] in
            self.revealSidebarForEditing()
            self.main.sidebar.showThemeEditor()
        }

        c.register("mini.new", "New Mini Window") { MiniWindowController.present(url: nil) }
        c.register("private.new", "New Private Window") { MiniWindowController.present(url: nil, isPrivate: true) }
        c.register("mini.expand", "Open Preview or Mini Window as a Full Tab") { [unowned self] in
            if self.frontPeek != nil { self.main.expandPeek() } else { self.keyMini?.expand() }
        }
        c.register("window.show", "Show Main Window") { [unowned self] in self.showMainWindow() }

        c.register("settings.open", "Settings…") { SettingsWindowController.shared.show() }
        c.register("config.open", "Open Settings Folder") { NSWorkspace.shared.open(Paths.support) }
        c.register("downloads.show", "Show Downloads Folder") {
            NSWorkspace.shared.open(Sandbox.downloads)
        }
        c.register("blocking.toggleSite", "Turn Ad Blocking Off or On for This Site") { [unowned self] in
            // With uBlock Origin Lite running, its own pop-up is where a site is switched off.
            if let ubol = Extensions.shared.blocker, ubol.isLoaded {
                self.showMainWindow()
                Extensions.shared.performAction(ubol)
            } else {
                self.toggleBlockingForSite()
            }
        }
        c.register("extensions.manage", "Manage Extensions…") { SettingsWindowController.shared.show(tab: 2) }
        c.register("extensions.menu", "Show Extensions") { [unowned self] in
            self.showMainWindow()
            if self.main.mode == .hidden { self.main.toggleSidebar() }
            self.main.sidebar.showExtensionsMenu()
        }
        c.register("blocking.update", "Update Ad Blocking Lists") { [unowned self] in
            self.main.showToast("Updating filter lists…")
            Blocker.shared.update { ok in self.main.showToast(ok ? "Filter lists updated" : "Couldn’t update the filter lists") }
        }
        c.register("tabs.sleepNow", "Put Background Tabs to Sleep Now") { [unowned self] in
            let n = self.store.sleepIdleTabs(olderThanMinutes: 0.01)
            self.main.showToast(n == 0 ? "No background tabs to put to sleep" : "\(n) tab\(n == 1 ? "" : "s") asleep · memory freed")
        }
        c.register("blocking.updateExtension", "Check for uBlock Origin Lite Update") { [unowned self] in
            self.main.showToast("Checking for a uBlock Origin Lite update…")
            Extensions.shared.updateBlockerIfNeeded(force: true) { message in self.main.showToast(message) }
        }
        c.register("archive.now", "Archive Unused Tabs Now") { [unowned self] in
            let hours = Settings.current.archiveAfterHours > 0 ? Settings.current.archiveAfterHours : 24
            let n = self.store.archiveStaleTabs(olderThanHours: hours)
            self.main.showToast(n == 0 ? "No unused tabs to archive" : "Archived \(n) tab\(n == 1 ? "" : "s")")
        }
        c.register("data.clear", "Clear Cookies and Website Data…") { [unowned self] in self.clearWebsiteData() }
        c.register("config.reload", "Reload Settings, Shortcuts and Bangs") { [unowned self] in
            Settings.current = Settings.load()
            Keybindings.shared.reload()
            Bangs.shared.reload()
            self.buildMenu()
            self.main.root.trackWhenInactive = Settings.current.sidebarHoverWhenInactive
            self.main.showToast("Settings reloaded")
        }
        c.register("history.clear", "Clear Browsing History…") { [unowned self] in
            self.confirm("Clear your browsing history?",
                         "Sorrel forgets every page you have visited. Open tabs, cookies and logins are not affected.",
                         button: "Clear History") {
                History.shared.clear()
                self.store.clearArchive()
                self.main.showToast("History cleared")
            }
        }
    }

    private func confirm(_ title: String, _ detail: String, button: String, then run: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let w = NSApp.keyWindow ?? main.window {
            alert.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { run() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            run()
        }
    }

    private func printPage() {
        guard let wv = activeWebView, let window = wv.window else { return }
        let op = wv.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func toggleBlockingForSite() {
        guard let wv = activeWebView, let host = wv.url?.host, let site = Site.key(host) else { return }
        var sites = Settings.current.blockingDisabledSites
        let wasOff = Site.host(host, isIn: sites)
        if wasOff {
            sites.removeAll { Site.host(host, isIn: [$0]) }
        } else {
            sites.append(site)
        }
        Settings.current.blockingDisabledSites = sites
        Settings.current.save()
        Blocker.shared.willNavigate(toHost: host, controller: wv.configuration.userContentController)
        wv.reload()
        main.showToast(wasOff ? "Ad blocking is on for \(site)" : "Ad blocking is off for \(site)")
    }

    private func clearWebsiteData() {
        confirm("Clear all cookies and website data?",
                "You will be signed out of every website in every space, and saved site data is erased. History is not affected.",
                button: "Clear Data") { [unowned self] in
            var stores: [WKWebsiteDataStore] = [Engine.store(for: nil)]
            for space in self.store.spaces {
                if let id = space.profileID { stores.append(Engine.store(for: id)) }
            }
            let group = DispatchGroup()
            for s in stores {
                group.enter()
                s.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { group.leave() }
            }
            group.notify(queue: .main) { self.main.showToast("Cookies and website data cleared") }
        }
    }

    // MARK: Archived tabs menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu {
            menu.removeAllItems()
            menu.addItem(item("nav.back"))
            menu.addItem(item("nav.forward"))
            menu.addItem(item("tab.reopen"))
            menu.addItem(.separator())
            let recent = History.shared.recent(limit: 18)
            if recent.isEmpty {
                let none = NSMenuItem(title: "No History Yet", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for e in recent {
                let title = e.title.isEmpty ? e.url : e.title
                let entry = ActionMenuItem(String(title.prefix(64))) { [unowned self] in
                    self.showMainWindow()
                    self.store.newTab(url: e.url, title: e.title)
                }
                if let icon = FaviconStore.shared.image(forHost: URL(string: e.url)?.host)?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(item("history.clear"))
            return
        }
        guard menu === archivedMenu else { return }
        menu.removeAllItems()
        let entries = store.archive.prefix(25)
        if entries.isEmpty {
            let none = NSMenuItem(title: "No Archived Tabs", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for (i, e) in entries.enumerated() {
            let space = store.space(id: e.spaceID)
            let title = (space.map { $0.icon + "  " } ?? "") + (e.title.isEmpty ? e.url : e.title)
            menu.addItem(ActionMenuItem(String(title.prefix(70))) { [unowned self] in
                self.showMainWindow()
                self.store.restoreArchived(at: i)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Clear Archive") { [unowned self] in self.store.clearArchive() })
    }

    private func openInFallbackBrowser() {
        guard let url = activeWebView?.url, url.scheme?.hasPrefix("http") == true else { return }
        let name = Settings.current.fallbackBrowser
        let candidates = ["/Applications/\(name).app", Sandbox.realHome.path + "/Applications/\(name).app"]
        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            main.showToast("\(name) isn’t installed")
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Menu bar

    @objc private func runCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Commands.shared.run(id) }
    }

    private func item(_ id: String, title: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title ?? Commands.shared.title(id) ?? id, action: #selector(runCommand(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = id
        if let eq = Keybindings.shared.menuEquivalent(for: id) {
            mi.keyEquivalent = eq.key
            mi.keyEquivalentModifierMask = eq.mask
        }
        return mi
    }

    private func std(_ title: String, _ selector: String, _ key: String, _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
        mi.keyEquivalentModifierMask = mask
        return mi
    }

    func buildMenu() {
        let bar = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            bar.addItem(top)
            return m
        }

        _ = add("Sorrel", [
            std("About Sorrel", "orderFrontStandardAboutPanel:", ""),
            .separator(),
            item("settings.open"),
            item("config.open", title: "Settings Folder…"),
            item("config.reload"),
            .separator(),
            item("history.clear"),
            item("data.clear"),
            .separator(),
            std("Hide Sorrel", "hide:", "h"),
            std("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
            std("Show All", "unhideAllApplications:", ""),
            .separator(),
            std("Quit Sorrel", "terminate:", "q"),
        ])
        _ = add("File", [
            item("tab.new"), item("mini.new"), item("private.new"), item("folder.new"), item("space.new"),
            .separator(),
            item("tab.close"), item("tab.reopen"),
            .separator(),
            item("mini.expand"), item("tab.openInFallback"),
            .separator(),
            item("downloads.show"), item("tab.print"),
        ])
        _ = add("Edit", [
            std("Undo", "undo:", "z"),
            std("Redo", "redo:", "z", [.command, .shift]),
            .separator(),
            std("Cut", "cut:", "x"),
            std("Copy", "copy:", "c"),
            std("Paste", "paste:", "v"),
            std("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]),
            std("Select All", "selectAll:", "a"),
            .separator(),
            item("find.show"), item("tab.copyURL"), item("tab.editURL"),
        ])
        _ = add("View", [
            item("sidebar.toggle"), item("theme.edit"),
            .separator(),
            item("tab.reload"), item("tab.hardReload"), item("nav.back"), item("nav.forward"),
            .separator(),
            item("view.zoomIn"), item("view.zoomOut"), item("view.zoomReset"),
            .separator(),
            item("blocking.toggleSite"), item("blocking.updateExtension"), item("extensions.manage"),
            .separator(),
            std("Enter Full Screen", "toggleFullScreen:", "f", [.command, .control]),
        ])
        _ = add("Tabs", [
            item("tab.next"), item("tab.previous"),
            .separator(),
            item("tab.togglePin"), item("tab.toggleFavorite"), item("tab.duplicate"),
            .separator(),
            item("split.add"), item("split.separate"), item("split.removeTab"),
            item("split.focusNext"), item("split.focusPrevious"),
            item("split.rotate", title: "Side by Side / Stacked"), item("split.swap"),
            .separator(),
            {
                let archived = NSMenuItem(title: "Archived Tabs", action: nil, keyEquivalent: "")
                archivedMenu.delegate = self
                archivedMenu.supermenu?.items.first { $0.submenu === archivedMenu }?.submenu = nil
                archived.submenu = archivedMenu
                return archived
            }(),
            item("archive.now"), item("tabs.sleepNow"),
        ])
        _ = add("Spaces", [item("space.next"), item("space.previous"), .separator(), item("space.new")])
        // History fills itself in each time it is opened.
        historyMenu.removeAllItems()
        historyMenu.delegate = self
        historyMenu.supermenu?.items.first { $0.submenu === historyMenu }?.submenu = nil
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        bar.addItem(historyItem)
        let window = add("Window", [
            std("Minimize", "performMiniaturize:", "m"),
            std("Zoom", "performZoom:", ""),
            .separator(),
            item("window.show"),
            std("Bring All to Front", "arrangeInFront:", ""),
        ])
        NSApp.mainMenu = bar
        NSApp.windowsMenu = window
    }

    // MARK: Debug

    /// Test hooks, all driven by environment variables so a run never needs a person at the keyboard.
    /// SORREL_SNAPSHOT=/path.png writes a picture of the window contents and quits.
    private func runDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["SORREL_SNAPSHOT"] else { return }
        let delay = Double(env["SORREL_DELAY"] ?? "") ?? 2.5
        func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for id in (env["SORREL_RUN"] ?? "").split(separator: ",") { Commands.shared.run(String(id)) }
            if let u = env["SORREL_OPEN"] { self.store.newTab(url: u) }
            if let u = env["SORREL_MINI"], let url = URL(string: u) { MiniWindowController.present(url: url) }
            if let s = env["SORREL_SIDEBAR"] { self.main.debugSetSidebar(s) }
            if let text = env["SORREL_COMMAND"] { self.main.commandBar.debugType(text) }
            if env["SORREL_THEME"] != nil { self.main.sidebar.showThemeEditor() }
            if let mode = env["SORREL_EMOJITEST"] {
                self.main.sidebar.showThemeEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.main.sidebar.debugEmojiTest(mode, log: log) }
            }
            if env["SORREL_EDITADDR"] != nil {
                self.main.editAddress()
                if let text = env["SORREL_EDITADDR"], text != "1" { self.main.commandBar.debugSetText(text) }
                log("address: placement=\(self.main.commandBar.placement) focus=\(self.main.commandBar.hasKeyboardFocus) sidebar=\(self.main.mode)")
            }
            if env["SORREL_HOVERTEST"] != nil {
                // Drive the hover logic with stand-in cursor positions (root view coordinates).
                let m = self.main!
                func step(_ label: String, _ p: NSPoint, exited: Bool = false, then next: @escaping () -> Void) {
                    m.debugCursor = p
                    if exited { m.root.onMouseExited?() } else { m.root.onMouseMoved?(p) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        log("hover: \(label) -> \(m.mode)")
                        next()
                    }
                }
                m.debugSetSidebar("hidden")
                step("mid-page", NSPoint(x: 300, y: 300)) {
                step("12pt from the edge", NSPoint(x: 12, y: 300)) {
                step("over the sidebar", NSPoint(x: 120, y: 300)) {
                step("back on the page", NSPoint(x: 700, y: 300)) {
                step("flicked 40pt past the edge", NSPoint(x: -40, y: 300), exited: true) {
                step("resting 40pt outside", NSPoint(x: -40, y: 300), exited: true) {
                step("far outside the window", NSPoint(x: -400, y: 300), exited: true) {
                step("left through the top", NSPoint(x: 300, y: 2000), exited: true) {
                    log("hover: command bar focus=\(m.commandBar.hasKeyboardFocus) (before opening)")
                    Commands.shared.run("tab.new")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        log("hover: command bar focus=\(m.commandBar.hasKeyboardFocus) (after opening)")
                        if let wv = m.currentWebView {
                            let stolen = m.window?.makeFirstResponder(wv) ?? false
                            log("hover: page tried to take focus back -> allowed=\(stolen) barFocus=\(m.commandBar.hasKeyboardFocus)")
                        }
                    }
                }}}}}}}}
            }
        }
        if env["SORREL_BLOCKTEST"] != nil {
            // Wait for the filter lists, then load a page that pulls from well-known ad and tracker hosts.
            let started = Date()
            func page(_ selector: String) -> String {
                """
                <!doctype html><meta charset="utf-8"><title>pending</title>
                <div id="cos" class="\(selector)">sample ad box</div>
                <script>
                var r = {};
                function get(name, src) { return new Promise(function (res) {
                    var s = document.createElement('script'); s.src = src;
                    s.onload = function () { r[name] = 'loaded'; res(); };
                    s.onerror = function () { r[name] = 'BLOCKED'; res(); };
                    document.head.appendChild(s); }); }
                Promise.all([
                    get('adsense', 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'),
                    get('doubleclick', 'https://securepubads.g.doubleclick.net/tag/js/gpt.js'),
                    get('google-analytics', 'https://www.google-analytics.com/analytics.js'),
                    get('facebook-pixel', 'https://connect.facebook.net/en_US/fbevents.js'),
                    get('control (cdnjs lodash)', 'https://cdnjs.cloudflare.com/ajax/libs/lodash.js/4.17.21/lodash.min.js')
                ]).then(function () {
                    r['sample ad box'] = getComputedStyle(document.getElementById('cos')).display === 'none' ? 'HIDDEN' : 'visible';
                    document.title = JSON.stringify(r);
                });
                </script>
                """
            }
            func run(_ label: String, then next: @escaping () -> Void) {
                let item = self.store.newTab(url: "")
                let p = Engine.shared.ensurePage(for: item)
                p.webView.loadHTMLString(page(String((Blocker.shared.meta.sampleSelector ?? ".x").dropFirst())),
                                         baseURL: URL(string: "https://example.org/")!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    log("block[\(label)]: \(p.webView.title ?? "nil")")
                    next()
                }
            }
            func waitForLists() {
                if Blocker.shared.lists.isEmpty, Date().timeIntervalSince(started) < 240 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForLists() }
                    return
                }
                log("block: lists=\(Blocker.shared.lists.count) status=\(Blocker.shared.statusText) after \(Int(Date().timeIntervalSince(started)))s sample=\(Blocker.shared.meta.sampleSelector ?? "nil")")
                run("blocking on") {
                    Settings.current.blockingDisabledSites = ["example.org"]
                    run("site exempted") {
                        Settings.current.blockingDisabledSites = []
                        // A blocked ad domain must still open when it is the page itself.
                        let item = self.store.newTab(url: "https://doubleclick.net/")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            log("block[top-level page on an ad domain]: title=\(item.page?.webView.title ?? "nil") url=\(item.page?.webView.url?.absoluteString ?? "nil")")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { waitForLists() }
        }
        if let mode = env["SORREL_EXTTEST"] {
            let started = Date()
            func describe() {
                for e in Extensions.shared.entries {
                    let ctxErrors = (e.context?.errors ?? []).map { $0.localizedDescription }
                    log("ext: \(e.id) | \(e.name) \(e.version) | \(e.sourceText) | enabled=\(Extensions.shared.isEnabled(e)) loaded=\(e.isLoaded) error=\(e.error ?? "none") contextErrors=\(ctxErrors)")
                }
            }
            func adPage() -> String {
                let cls = String((Blocker.shared.meta.sampleSelector ?? ".x").dropFirst())
                return """
                <!doctype html><meta charset="utf-8"><title>pending</title>
                <div id="cos" class="\(cls)">sample ad box</div>
                <script>
                var r = {};
                function get(name, src) { return new Promise(function (res) {
                    var s = document.createElement('script'); s.src = src;
                    s.onload = function () { r[name] = 'loaded'; res(); };
                    s.onerror = function () { r[name] = 'BLOCKED'; res(); };
                    document.head.appendChild(s); }); }
                // A plain network request cannot be swapped for a stand-in script, so it shows real blocking.
                function net(name, url) { return fetch(url, { mode: 'no-cors', cache: 'no-store' })
                    .then(function () { r[name] = 'allowed'; }, function () { r[name] = 'BLOCKED'; }); }
                Promise.all([
                    net('adsense', 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'),
                    net('doubleclick', 'https://securepubads.g.doubleclick.net/tag/js/gpt.js'),
                    net('google-analytics', 'https://www.google-analytics.com/analytics.js'),
                    net('facebook-pixel', 'https://connect.facebook.net/en_US/fbevents.js'),
                    net('taboola', 'https://cdn.taboola.com/libtrc/loader.js'),
                    net('criteo', 'https://static.criteo.net/js/ld/publishertag.js'),
                    net('amazon-ads', 'https://c.amazon-adsystem.com/aax2/apstag.js'),
                    net('scorecard', 'https://sb.scorecardresearch.com/beacon.js'),
                    net('hotjar', 'https://static.hotjar.com/c/hotjar-1.js'),
                    net('CONTROL cdnjs', 'https://cdnjs.cloudflare.com/ajax/libs/lodash.js/4.17.21/lodash.min.js'),
                    net('CONTROL wikipedia', 'https://en.wikipedia.org/static/favicon/wikipedia.ico'),
                    get('adsense as a script tag', 'https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js'),
                    get('analytics as a script tag', 'https://www.google-analytics.com/analytics.js'),
                    get('gpt as a script tag', 'https://securepubads.g.doubleclick.net/tag/js/gpt.js')
                ]).then(function () {
                    setTimeout(function () {
                        // The real scripts leave these marks; uBlock Origin's stand-ins do not.
                        var real = [];
                        if (typeof window.gaData !== 'undefined' || typeof window.gaGlobal !== 'undefined') real.push('analytics');
                        try { if (window.googletag && googletag.getVersion && String(googletag.getVersion()).length > 0) real.push('gpt v' + googletag.getVersion()); } catch (e) {}
                        if (typeof window.google_tag_data !== 'undefined' || document.querySelector('iframe[src*="google"]')) real.push('adsense');
                        var note = 'REAL Google scripts that ran: ' + (real.length ? real.join(', ') : 'none');
                        var blocked = Object.keys(r).filter(function (k) { return r[k] === 'BLOCKED'; });
                        var allowed = Object.keys(r).filter(function (k) { return r[k] !== 'BLOCKED'; });
                        r = { BLOCKED: blocked.join(', '), 'not blocked': allowed.map(function (k) { return k + '=' + r[k]; }).join(', ') };
                        r.note = note;
                        document.title = JSON.stringify(r);
                    }, 1500);
                });
                </script>
                """
            }
            func adTest(_ label: String, wait: Double = 9, then next: @escaping () -> Void) {
                let item = self.store.newTab(url: "")
                let p = Engine.shared.ensurePage(for: item)
                let builtIn = p.webView.configuration.userContentController
                p.webView.loadHTMLString(adPage(), baseURL: URL(string: "https://example.org/")!)
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    log("ext[\(label)]: uBOL active=\(Extensions.shared.hasActiveBlocker) pageHasExtensionController=\(p.webView.configuration.webExtensionController != nil) | \(p.webView.title ?? "nil")")
                    _ = builtIn
                    next()
                }
            }
            func waitForBlocker() {
                let ubol = Extensions.shared.blocker
                if (ubol == nil || ubol!.isLoading || (!ubol!.isLoaded && ubol!.error == nil)), Date().timeIntervalSince(started) < 90 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitForBlocker() }
                    return
                }
                log("ext: ready after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                describe()
                // Give the extension a moment to register its rules, then test with ONLY the extension doing the blocking.
                func state(_ when: String) {
                    let c = Extensions.shared.blocker?.context
                    log("ext: [\(when)] hasContentModificationRules=\(c?.hasContentModificationRules ?? false) dnrPermission=\(c?.hasPermission(.declarativeNetRequest) ?? false) allHosts=\(c?.hasAccessToAllHosts ?? false) errors=\((c?.errors ?? []).map { $0.localizedDescription })")
                }
                state("just loaded")
                if mode == "loop" {
                    // Re-test every 20 seconds to see when the extension's rules take effect.
                    var round = 0
                    func again() {
                        round += 1
                        let t = Int(Date().timeIntervalSince(started))
                        adTest("t+\(t)s", wait: 5) {
                            if round >= 8 { NSApp.terminate(nil) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { again() } }
                        }
                    }
                    again()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    state("+4s")
                    adTest("uBlock Origin Lite only, +4s") {
                      state("+13s")
                      DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "slow" ? 30 : 0)) {
                       if mode == "slow" { state("+43s") }
                       adTest(mode == "slow" ? "uBlock Origin Lite only, +43s" : "second page") {
                        if mode == "ui", let ubol = Extensions.shared.entries.first(where: { $0.id.contains(env["SORREL_UI_EXT"] ?? Extensions.blockerID) }) {
                          // Open the toolbar pop-up and the dashboard page, and photograph both.
                          let run = {
                            if env["SORREL_UI_NODASH"] == nil { Extensions.shared.openOptions(ubol) }
                            let tabAtClick = self.store.selected?.extensionTab
                            bringAppForward()
                            Extensions.shared.performAction(ubol)
                            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["SORREL_UI_WAIT"] ?? "") ?? 8)) {
                                let action = ubol.context?.action(for: tabAtClick)
                                let pop = action?.popupPopover
                                log("ui: popover shown=\(pop?.isShown ?? false) contentSize=\(pop?.contentSize ?? .zero) contentView=\(pop?.contentViewController?.view.frame.size ?? .zero) appActive=\(NSApp.isActive) loading=\(action?.popupWebView?.isLoading ?? false) title=\(action?.popupWebView?.title ?? "nil")")
                                if let out = env["SORREL_SNAPSHOT_POPOVER"], let v = pop?.contentViewController?.view, v.bounds.width > 0,
                                   let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                                    v.cacheDisplay(in: v.bounds, to: rep)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                                }
                                log("ui: popup open=\(Extensions.shared.isPopupOpen) popupWebView=\(action?.popupWebView != nil) popupURL=\(action?.popupWebView?.url?.absoluteString ?? "nil") popupSize=\(action?.popupWebView?.frame.size ?? .zero)")
                                log("ui: dashboard tab title=\(self.store.selected?.title ?? "nil") url=\(self.store.selected?.url ?? "nil") loaded=\(self.store.selected?.page?.webView.url?.absoluteString ?? "nil")")
                                let group = DispatchGroup()
                                func shoot(_ wv: WKWebView?, _ path: String?) {
                                    guard let wv, let path else { return }
                                    group.enter()
                                    wv.takeSnapshot(with: nil) { image, _ in
                                        if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                                        }
                                        group.leave()
                                    }
                                }
                                action?.popupWebView?.evaluateJavaScript("(function(){var box=function(el){if(!el)return null;var r=el.getBoundingClientRect(),c=getComputedStyle(el);return [Math.round(r.left),Math.round(r.top),Math.round(r.width),Math.round(r.height),c.display,c.visibility,c.opacity,c.overflow].join(' ');};var root=document.querySelector('.app-root');return JSON.stringify({ready: document.readyState, text: (document.body ? document.body.innerText : '').slice(0, 120), nodes: document.querySelectorAll('*').length, win: innerWidth+'x'+innerHeight, html: box(document.documentElement), body: box(document.body), appRoot: box(root), first: box(root&&root.firstElementChild), second: box(root&&root.firstElementChild&&root.firstElementChild.firstElementChild), vars: [getComputedStyle(document.documentElement).getPropertyValue('--popup-width'), getComputedStyle(document.documentElement).getPropertyValue('--popup-height')], inline: document.documentElement.getAttribute('style'), bodyInline: document.body.getAttribute('style')});})()") { r, e in
                                    log("ui: popup page \(r ?? "nil") \(e.map { $0.localizedDescription } ?? "")")
                                }
                                log("ui: context errors=\((ubol.context?.errors ?? []).map { $0.localizedDescription })")
                                shoot(action?.popupWebView, env["SORREL_SNAPSHOT_POPUP"])
                                shoot(self.store.selected?.page?.webView, env["SORREL_SNAPSHOT_DASH"])
                                group.notify(queue: .main) { NSApp.terminate(nil) }
                            }
                          }
                          if ubol.isLoaded { run() } else {
                              Extensions.shared.setEnabled(ubol, true) { ok in
                                  log("ui: enabled \(ubol.name) ok=\(ok) error=\(ubol.error ?? "none")")
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 6) { run() }
                              }
                          }
                          return
                        }
                        guard mode == "protonpass", let pp = Extensions.shared.entries.first(where: { $0.id.contains("proton") }) else {
                            NSApp.terminate(nil)
                            return
                        }
                        Extensions.shared.setEnabled(pp, true) { ok in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                log("ext: proton pass load ok=\(ok)")
                                describe()
                                let action = pp.context?.action(for: nil)
                                log("ext: proton pass action label=\(action?.label ?? "nil") presentsPopup=\(action?.presentsPopup ?? false) options=\(pp.context?.optionsPageURL?.absoluteString ?? "nil") permissions=\(pp.context?.currentPermissions.count ?? 0) allHosts=\(pp.context?.hasAccessToAllHosts ?? false)")
                                NSApp.terminate(nil)
                            }
                        }
                       }
                      }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { waitForBlocker() }
        }
        if let which = env["SORREL_EXTERNALTEST"] {
            // Can an ordinary web page, one the extension names in its manifest, message the extension?
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                guard let entry = Extensions.shared.entries.first(where: { $0.id.contains(which) }), let ctx = entry.context else {
                    log("external: extension not loaded"); NSApp.terminate(nil); return
                }
                let tab = self.store.newTab(url: env["SORREL_EXTERNAL_PAGE"] ?? "https://example.com/")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let js = """
                    const out = { ua: navigator.userAgent.replace(/.*(Chrome\\/[0-9]+|Version\\/[0-9.]+ Safari).*/, '$1'), chrome: typeof chrome, browser: typeof browser,
                                  chromeRuntime: typeof (window.chrome && chrome.runtime), browserRuntime: typeof (window.browser && browser.runtime) };
                    const api = (window.chrome && chrome.runtime && chrome.runtime.sendMessage) ? chrome : null;
                    if (!api) { out.result = 'page has no Chrome-style way to reach an extension'; return JSON.stringify(out); }
                    out.callbackStyle = await new Promise((res) => { try { api.runtime.sendMessage(ids[0], { hello: 'callback' }, (r) => res(r === undefined ? 'NO ANSWER' : 'answered')); } catch (e) { res('threw: ' + e.message); } setTimeout(() => res('timed out'), 3000); });
                    for (const id of ids) {
                      try { const r = await api.runtime.sendMessage(id, { hello: 'from the page' }); out['to ' + id.slice(0, 18)] = r === undefined ? 'NO ANSWER' : 'answered ' + JSON.stringify(r).slice(0, 80); }
                      catch (e) { out['to ' + id.slice(0, 18)] = 'failed: ' + e.message; }
                    }
                    return JSON.stringify(out);
                    """
                    tab.page?.webView.callAsyncJavaScript(js, arguments: ["ids": [ctx.uniqueIdentifier]], in: nil, in: .page) { result in
                        log("external: id=\(ctx.uniqueIdentifier) page=\(tab.page?.webView.url?.host ?? "nil") -> \(result)")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        if let which = env["SORREL_AUTOFILLTEST"] {
            // Open a real sign-in page and report what the extension put into it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                guard let entry = Extensions.shared.entries.first(where: { $0.id.contains(which) }), let ctx = entry.context else {
                    log("autofill: extension not loaded"); NSApp.terminate(nil); return
                }
                let tab = self.store.newTab(url: env["SORREL_AUTOFILL_PAGE"] ?? "https://github.com/login")
                func look(_ label: String, then next: @escaping () -> Void) {
                    let js = """
                    (function () {
                      var custom = {}, frames = [];
                      document.querySelectorAll('*').forEach(function (el) { var t = el.tagName.toLowerCase(); if (t.indexOf('-') > 0) custom[t] = (custom[t] || 0) + 1; });
                      document.querySelectorAll('iframe').forEach(function (f) { frames.push(String(f.src).slice(0, 70)); });
                      var log = []; try { log = JSON.parse(document.documentElement.getAttribute('data-sorrel-extlog') || '[]'); } catch (e) {}
                      var fields = Array.from(document.querySelectorAll('input')).filter(function (i) { return ['text','email','password'].indexOf(i.type) >= 0; });
                      return JSON.stringify({ loginFields: fields.length, customElements: custom, iframes: frames,
                        fieldsMarked: fields.filter(function (i) { return Array.from(i.attributes).some(function (a) { return /proton|pass/i.test(a.name); }); }).length,
                        contentScriptLog: log });
                    })()
                    """
                    tab.page?.webView.evaluateJavaScript(js) { r, e in
                        log("autofill[\(label)]: \(r ?? "no answer") \(e.map { $0.localizedDescription } ?? "")")
                        next()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    look("8s after opening \(tab.page?.webView.url?.host ?? "?")") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            look("18s") {
                                log("autofill: extension problems=\(ctx.errors.map { $0.localizedDescription })")
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
        if let which = env["SORREL_EXTDIAG"] {
            // Report everything WebKit and the extension say about an extension that is not behaving.
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                guard let entry = Extensions.shared.entries.first(where: { $0.id.contains(which) }), let ctx = entry.context else {
                    log("diag: extension not loaded. entries=\(Extensions.shared.entries.map { "\($0.id) loaded=\($0.isLoaded) error=\($0.error ?? "none")" })")
                    NSApp.terminate(nil)
                    return
                }
                let ext = ctx.webExtension
                log("diag: \(entry.name) \(entry.version) manifest v\(ext.manifestVersion) background=\(ext.hasBackgroundContent) persistentBackground=\(ext.hasPersistentBackgroundContent) injects=\(ext.hasInjectedContent)")
                log("diag: manifest problems=\(ext.errors.map { $0.localizedDescription })")
                log("diag: runtime problems=\(ctx.errors.map { $0.localizedDescription })")
                log("diag: sorrel-reported error=\(entry.error ?? "none")")
                log("diag: unsupported APIs=\(ctx.unsupportedAPIs.sorted())")
                let asked = (ext.manifest["permissions"] as? [String] ?? [])
                log("diag: permissions asked=\(asked) granted=\(ctx.currentPermissions.map { $0.rawValue }.sorted())")
                log("diag: tabs opened so far=\(self.store.allTabs.compactMap { $0.item.url }.filter { !$0.hasPrefix("sorrel") })")
                let base = ctx.baseURL.absoluteString
                let popup = ((ext.manifest["action"] as? [String: Any])?["default_popup"] as? String) ?? "popup.html"
                let tab = self.store.newTab(url: base + popup)
                var finished = false
                func report(_ label: String) {
                    let wv = tab.page?.webView
                    log("diag[\(label)]: page loading=\(wv?.isLoading ?? false) progress=\(String(format: "%.2f", wv?.estimatedProgress ?? 0)) url=\(wv?.url?.absoluteString ?? "nil") title=\(wv?.title ?? "nil") tabs=\(self.store.allTabs.compactMap { $0.item.url }.filter { !$0.hasPrefix("sorrel") && !$0.contains("pubmed") })")
                    tab.page?.webView.evaluateJavaScript("JSON.stringify({ready: document.readyState, hash: location.hash, text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 260), nodes: document.querySelectorAll('*').length, errors: (window.__sorrelErrors || ['recorder missing']).slice(0, 14)})") { r, e in
                        log("diag[\(label)]: \(r ?? "no answer") \(e.map { $0.localizedDescription } ?? "")")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { report("popup page after 6s") }
                for at in [9.0, 20.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                        // Ask the background directly, in the extension's own message format.
                        let js = """
                        (async () => { const rt = __sorrelHeld.runtime; const out = {};
                          for (const m of [{type:'PING',sender:'popup'}, {type:'ENDPOINT_INIT',sender:'popup',payload:{popup:true}}, {type:'NOT_A_REAL_TYPE',sender:'popup'}]) {
                            try { const r = await rt.sendMessage(m); out[m.type] = r === undefined ? 'NO ANSWER' : JSON.stringify(r).slice(0, 140); } catch (e) { out[m.type] = 'failed: ' + e.message; } }
                          return JSON.stringify(out); })()
                        """
                        tab.page?.webView.callAsyncJavaScript("return await " + js, arguments: [:], in: nil, in: .page) { result in
                            log("diag: direct questions at +\(Int(at))s: \(result)")
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
                    report("popup page after 16s")
                    log("diag: runtime problems now=\(ctx.errors.map { $0.localizedDescription })")
                    log("diag: sorrel-reported error now=\(entry.error ?? "none")")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { report("popup page after 30s") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 36) { if !finished { finished = true; NSApp.terminate(nil) } }
            }
        }
        if env["SORREL_SECTEST"] != nil {
            // Security checks: HTTPS-first (upgrade and warning), private links staying private,
            // pages opening other apps, data: navigations, download quarantine.
            func js(_ wv: WKWebView?, _ code: String, _ done: @escaping (String) -> Void) {
                wv?.evaluateJavaScript(code) { r, e in done("\(r ?? e?.localizedDescription ?? "nil")") }
            }
            let up = self.store.newTab(url: "http://example.com/")
            let plain = self.store.newTab(url: env["SORREL_SECTEST_HTTP"] ?? "http://expired.badssl.com/")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                log("sec: upgrade url=\(up.page?.webView.url?.absoluteString ?? "nil")")
                js(plain.page?.webView, "document.title + ' | ' + location.href") { r in
                    log("sec: no-https site shows=\(r)")
                    plain.page?.webView.evaluateJavaScript("location.href='sorrel-insecure:continue'")
                }
                // A page sending the tab to data: and to another app without a click.
                self.store.select(up)
                js(up.page?.webView, "location.href='data:text/html,<h1>fake</h1>'; 'sent'") { _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    js(up.page?.webView, "location.href='mailto:someone@example.com'; 'sent'") { _ in }
                }
                // ⌘-click inside a private window.
                let priv = MiniWindowController.present(url: URL(string: "https://example.com/private-src"), isPrivate: true)
                let before = MiniWindowController.all.count
                Engine.shared.onOpenInBackground?(URL(string: "https://example.org/from-private")!, priv.page)
                let leakedTab = self.store.allTabs.contains { $0.item.url == "https://example.org/from-private" }
                let newPrivate = MiniWindowController.all.count == before + 1 && MiniWindowController.all.last?.isPrivate == true
                log("sec: private cmd-click -> normal tab leaked=\(leakedTab) opened in new private window=\(newPrivate)")
                // Download quarantine.
                if let wv = up.page?.webView, let f = URL(string: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf") {
                    Engine.shared.startDownload(f, in: wv)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    log("sec: after data: nav url=\(up.page?.webView.url?.absoluteString ?? "nil")")
                    log("sec: external app prompt=\(Engine.shared.lastExternalPrompt ?? "none (opened or ignored)")")
                    js(plain.page?.webView, "document.title + ' | ' + location.href") { r in log("sec: after Continue=\(r)") }
                    for d in Engine.shared.downloads {
                        let q = (try? d.file.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
                        log("sec: download \(d.file.lastPathComponent) state=\(d.state) quarantine=\(q.map { "\($0[kLSQuarantineAgentNameKey as String] ?? "?") type=\($0[kLSQuarantineTypeKey as String] ?? "?")" } ?? "MISSING")")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                }
            }
        }
        if env["SORREL_DAILYTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // 1. Sleeping tabs keep their history.
                let tab = self.store.newTab(url: "https://example.com/")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    tab.page?.webView.load(URLRequest(url: URL(string: "https://www.iana.org/help/example-domains")!))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        let other = self.store.newTab(url: "sorrel://welcome")
                        tab.lastActive = Date().addingTimeInterval(-3 * 3600)
                        other.lastActive = Date().addingTimeInterval(-3 * 3600)
                        let n = self.store.sleepIdleTabs(olderThanMinutes: 120)
                        log("sleep: put to sleep=\(n) tabUnloaded=\(tab.page == nil) stateSaved=\(tab.savedState != nil) visibleTabStillLoaded=\(other.page != nil) rememberedURL=\(tab.url ?? "nil")")
                        self.store.select(tab)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            let wv = tab.page?.webView
                            log("sleep: after waking url=\(wv?.url?.absoluteString ?? "nil") canGoBack=\(wv?.canGoBack ?? false) backTo=\(wv?.backForwardList.backItem?.url.absoluteString ?? "nil")")

                            // 2. Downloads are tracked.
                            if let wv, let file = URL(string: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf") {
                                Engine.shared.startDownload(file, in: wv)
                            }
                            // 3. Suggestions, when switched on.
                            Settings.current.searchSuggestions = true
                            self.main.commandBar.debugType("nephr")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                log("suggest: \(self.main.commandBar.debugResultTitles.prefix(6))")
                                self.main.commandBar.dismiss()
                                Settings.current.searchSuggestions = false
                                for d in Engine.shared.downloads {
                                    log("download: \(d.file.lastPathComponent) state=\(d.state) fraction=\(d.fraction) onDisk=\(FileManager.default.fileExists(atPath: d.file.path)) folder=\(d.file.deletingLastPathComponent().lastPathComponent)")
                                }
                                if Engine.shared.downloads.isEmpty { log("download: none recorded") }
                                // 4. History menu.
                                self.menuNeedsUpdate(self.historyMenu)
                                log("history menu: \(self.historyMenu.items.filter { !$0.isSeparatorItem }.map { $0.title }.prefix(7))")
                                // 5. Blocker update check.
                                Extensions.shared.updateBlockerIfNeeded(force: true) { message in
                                    log("update: \(message)")
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
        if let late = env["SORREL_OPEN_LATE"] {
            // Open a page a few seconds in, once extensions have loaded.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.store.newTab(url: late) }
        }
        if let js = env["SORREL_EVAL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.8) {
                self.main.currentWebView?.evaluateJavaScript(js) { r, e in
                    log("eval: \(r ?? "nil") \(e.map { "\($0.localizedDescription)" } ?? "")")
                }
            }
        }
        if env["SORREL_FEATURETEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // Shortcut editing
                let k = Keybindings.shared
                log("keys: pin before = \(k.displayAll(for: "tab.togglePin"))")
                k.setShortcut("ctrl+alt+p", for: "tab.togglePin")
                log("keys: pin after set = \(k.displayAll(for: "tab.togglePin")); ctrl+alt+p runs \(k.command(onStroke: "ctrl+alt+p") ?? "nil"); old cmd+d runs \(k.command(onStroke: "cmd+d") ?? "nothing")")
                k.setShortcut("cmd+t", for: "tab.togglePin")
                log("keys: after taking cmd+t: cmd+t runs \(k.command(onStroke: "cmd+t") ?? "nil"); new tab now = '\(k.displayAll(for: "tab.new"))'")
                k.setShortcut(nil, for: "tab.togglePin")
                log("keys: after remove = '\(k.displayAll(for: "tab.togglePin"))'")
                k.resetAll()
                log("keys: after reset: pin = \(k.displayAll(for: "tab.togglePin")), new tab = \(k.displayAll(for: "tab.new")), private = \(k.displayAll(for: "private.new")), settings = \(k.displayAll(for: "settings.open"))")

                // Archiving
                let a = self.store.newTab(url: "https://example.com/a", title: "Old A", select: false)
                let b = self.store.newTab(url: "https://example.com/b", title: "Old B", select: false)
                let c = self.store.newTab(url: "https://example.com/c", title: "Fresh C", select: false)
                let pinned = self.store.newTab(url: "https://example.com/p", title: "Old pinned", select: false)
                self.store.togglePin(pinned)
                for old in [a, b, pinned] { old.lastActive = Date().addingTimeInterval(-3 * 86400) }
                self.store.selected?.lastActive = Date().addingTimeInterval(-9 * 86400)
                _ = c
                let n = self.store.archiveStaleTabs(olderThanHours: 24)
                log("archive: archived=\(n) unpinned left=\(self.store.currentSpace.today.map { $0.displayTitle }) pinned left=\(self.store.tabs(in: self.store.currentSpace.pinned).map { $0.displayTitle }) archive=\(self.store.archive.map { $0.title })")
                self.store.restoreArchived(at: 0)
                log("archive: after restore unpinned=\(self.store.currentSpace.today.map { $0.displayTitle }) archive=\(self.store.archive.map { $0.title })")
                log("archive: never (0h) archives \(self.store.archiveStaleTabs(olderThanHours: 0))")

                // Private window
                let mini = MiniWindowController.present(url: URL(string: "https://example.com/private-test"), isPrivate: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    let inHistory = History.shared.search("private-test", limit: 5).count
                    mini.expand()
                    log("private: isPrivate=\(mini.isPrivate) persistent=\(mini.page.webView.configuration.websiteDataStore.isPersistent) loaded=\(mini.page.webView.url?.absoluteString ?? "nil") historyEntries=\(inHistory) stillAWindowAfterExpandAttempt=\(MiniWindowController.all.contains { $0 === mini })")
                    if let out = env["SORREL_SNAPSHOT_PRIVATE"], let v = mini.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                }
            }
        }
        if let tab = env["SORREL_SETTINGS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                // Light appearance for the capture, so text shows against the capture's blank background.
                SettingsWindowController.shared.window?.appearance = NSAppearance(named: .aqua)
                SettingsWindowController.shared.show(tab: Int(tab))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.3) {
                if let out = env["SORREL_SNAPSHOT_SETTINGS"], let view = SettingsWindowController.shared.window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    // The window's own background is not part of its content view; paint one behind the capture.
                    let image = NSImage(size: view.bounds.size)
                    image.lockFocus()
                    view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: view.bounds.size).fill()
                    }
                    rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
                    image.unlockFocus()
                    if let tiff = image.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff) {
                        try? flat.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                }
            }
        }
        if env["SORREL_PEEKTEST"] != nil {
            // Pin a tab on example.com, click its link to another site, and watch for the preview.
            let m = self.main!
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let item = self.store.newTab(url: env["SORREL_PEEKURL"] ?? "https://example.com/")
                if env["SORREL_PEEKTEST"] != "unpinned" { self.store.togglePin(item) }
                log("peek: pinned=\(self.store.isPinned(item))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let js = env["SORREL_PEEKTEST"] == "othersite"
                        ? "(function(){var a=document.createElement('a');a.href='https://www.iana.org/help/example-domains';document.body.appendChild(a);a.click();return location.host+' -> '+a.href})()"
                        : env["SORREL_PEEKTEST"] == "samesite"
                        ? "(function(){var a=document.querySelector('a');a.href='https://example.com/next';a.click();return a.href+' | clicked'})()"
                        : "document.querySelector('a').href + ' | ' + (document.querySelector('a').click(), 'clicked')"
                    item.page?.webView.evaluateJavaScript(js) { r, e in
                        log("peek: link \(r ?? "nil") \(e.map { "\($0)" } ?? "")")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        log("peek: open=\(m.peek != nil) previewURL=\(m.peek?.page.webView.url?.absoluteString ?? "nil") pinnedTabStillAt=\(item.page?.webView.url?.absoluteString ?? "nil")")
                        if let out = env["SORREL_SNAPSHOT_PEEK"],
                           let view = m.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                        }
                        if env["SORREL_PEEKTEST"] == "close" {
                            m.dismissPeek()
                            log("peek: after close open=\(m.peek != nil) tabs=\(self.store.currentSpace.today.count)")
                        } else {
                            Commands.shared.run("mini.expand")
                            log("peek: after expand open=\(m.peek != nil) tabs=\(self.store.currentSpace.today.map { $0.url ?? "" }) selected=\(self.store.selected?.url ?? "nil") pinned=\(self.store.tabs(in: self.store.currentSpace.pinned).map { $0.url ?? "" })")
                        }
                    }
                }
            }
        }
        if let mode = env["SORREL_SPLITTEST"] {
            // Split view: build one, move focus, resize, stack, add/remove panes, pin, and check what is saved.
            let m = self.main!
            let st = self.store
            func host(_ i: Item?) -> String { i.flatMap { URL(string: $0.url ?? "")?.host } ?? (i?.url ?? "nil") }
            func describe(_ label: String) {
                let sp = st.currentSpace
                func names(_ list: [Item]) -> String {
                    list.map { $0.isSplit ? "[" + $0.children.map(host).joined(separator: "|") + ($0.split?.stacked == true ? " stacked" : "") + "]" : host($0) }
                        .joined(separator: ", ")
                }
                let frames = m.card.panes.map { p in "\(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(p.frame.width))x\(Int(p.frame.height))\(p.isFocused ? "*" : "")" }
                log("split: \(label) | pinned=\(names(sp.pinned)) today=\(names(sp.today)) selected=\(host(st.selected)) panes=\(frames) focusedIsSelected=\(m.card.webView === st.selected?.page?.webView)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                describe("at launch")
                if mode == "reopen" { return }
                let a = st.newTab(url: "https://example.com/")
                let b = st.newTab(url: "https://example.org/", select: false)
                let c = st.newTab(url: "https://example.net/", select: false)
                st.select(a)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    m.splitSelected(with: b)
                    describe("a+b side by side")
                    st.focusPane(offset: -1)
                    describe("focus previous")
                    m.debugClickPane(1)
                    describe("clicked right pane")
                    m.card.debugDragFirstDivider(toFraction: 0.3)
                    log("split: dragged divider -> saved fractions=\((st.split(containing: a)?.split?.fractions ?? []).map { String(format: "%.2f", $0) })")
                    describe("after drag")
                    Commands.shared.run("split.rotate")
                    describe("stacked")
                    Commands.shared.run("split.rotate")
                    _ = st.makeSplit(b, with: c)
                    describe("added c")
                    let item = st.split(containing: a).map { m.sidebar.menu(for: $0).items.map(\.title) } ?? []
                    log("split: row menu=\(item)")
                    log("split: tab menu has split entry=\(m.sidebar.menu(for: st.newTab(url: "https://www.iana.org/", select: false)).items.contains { $0.title == "Open in Split View" })")
                    st.close(c)
                    describe("closed c")
                    Commands.shared.run("tab.reopen")
                    describe("reopened closed tab")
                    if let sv = st.split(containing: a) { st.togglePin(sv) }
                    describe("pinned the split")
                    if let sv = st.split(containing: a) { st.close(sv) }
                    describe("put pinned split to sleep")
                    st.select(a)
                    describe("woke it")
                    Commands.shared.run("split.separate")
                    describe("separated")
                    st.select(a)
                    _ = st.makeSplit(a, with: b)
                    st.focusPane(offset: -1)
                    st.saveNow()
                    if let data = try? Data(contentsOf: Paths.state), let text = String(data: data, encoding: .utf8) {
                        log("split: state.json has split=\(text.contains("\"split\"")) stacked-key=\(text.contains("\"stacked\""))")
                    }
                    describe("final")
                }
            }
        }
        if env["SORREL_EXPAND"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1.0) {
                log("expand: mini windows before=\(MiniWindowController.all.count) tabs=\(self.store.currentSpace.today.count)")
                MiniWindowController.all.first?.expand()
                log("expand: mini windows after=\(MiniWindowController.all.count) tabs=\(self.store.currentSpace.today.count) selected=\(self.store.selected?.url ?? "nil")")
            }
        }
        if let mode = env["SORREL_COOKIETEST"] {
            // Cookies across launches (and across the move into the sandbox): `set` stores a lasting cookie for
            // example.com in the shared store, `check` lists what a later launch finds. Only meaningful without
            // SORREL_HOME (which keeps cookies in memory), so only in the test build's own profile.
            let jar = Engine.store(for: nil).httpCookieStore
            if mode == "set" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let cookie = HTTPCookie(properties: [.domain: ".example.com", .path: "/", .name: "sorreltest",
                                                         .value: "\(Int(Date().timeIntervalSince1970))",
                                                         .expires: Date().addingTimeInterval(86400), .secure: "TRUE"])!
                    jar.setCookie(cookie) { log("cookie: set \(cookie.value) persistent=\(Engine.store(for: nil).isPersistent)") }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 2) {
                jar.getAllCookies { all in
                    log("cookie: found=" + all.filter { $0.domain.contains("example.com") }.map { "\($0.name)=\($0.value)" }.joined(separator: ","))
                }
            }
        }
        if let out = env["SORREL_WEBSNAPSHOT"] {
            // WebKit's own picture of the selected page. Under the App Sandbox the window snapshot
            // (cacheDisplay) can't copy the page out of WebKit's process and shows it blank; this can.
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1.5) {
                guard let web = self.store.selected?.page?.webView else { log("websnapshot: no page"); return }
                web.takeSnapshot(with: nil) { image, error in
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        log("websnapshot: failed \(error?.localizedDescription ?? "")"); return
                    }
                    try? png.write(to: URL(fileURLWithPath: out))
                    log("websnapshot: \(Int(image.size.width))x\(Int(image.size.height))")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            func capture(_ view: NSView?, to path: String) {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            capture(self.main.window?.contentView, to: out)
            if let pop = env["SORREL_SNAPSHOT_CUSTOMIZE"] { capture(self.main.sidebar.debugCustomizeView, to: pop) }
            if let mini = env["SORREL_SNAPSHOT_MINI"] { capture(MiniWindowController.all.first?.window?.contentView, to: mini) }
            if let sel = self.store.selected {
                log("selected: title=\(sel.title) url=\(sel.url ?? "nil") loading=\(sel.page?.webView.isLoading ?? false)")
            }
            if let full = env["SORREL_SCREENCAPTURE"], let num = self.main.window?.windowNumber {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(num), full]
                try? p.run()
                p.waitUntilExit()
            }
            NSApp.terminate(nil)
        }
    }
}
