import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!

    private(set) var windows: [MainWindowController] = []
    private weak var focusedMain: MainWindowController?
    var main: MainWindowController! { focusedMain ?? windows.first }

    @discardableResult
    func newWindow(restoring saved: BrowserWindowState? = nil, present: Bool = true) -> MainWindowController {
        let snapshot = saved ?? BrowserWindowState(id: UUID(), currentSpaceID: main?.store.currentSpace.id ?? Store.profile.currentSpace.id, selections: [:])
        let controller = MainWindowController(store: Store(windowState: snapshot))
        if saved == nil, let previous = main?.window, let window = controller.window {
            window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        windows.append(controller)
        focusedMain = controller
        if launched { Extensions.shared.windowReady(controller) }
        if present { focus(controller) }
        controller.store.scheduleSave()
        return controller
    }

    func focus(_ controller: MainWindowController) {
        focusedMain = controller
        if isQuietTest {
            controller.window?.orderBack(nil)
        } else {
            controller.showWindow(nil)
            controller.window?.deminiaturize(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            bringAppForward()
        }
    }

    func windowFocused(_ controller: MainWindowController) {
        focusedMain = controller
        Extensions.shared.controller.didFocusWindow(controller.extensionWindow)
    }

    private var isTerminating = false

    func windowClosed(_ controller: MainWindowController) {
        // AppKit closes windows one by one during quit. Preserve the complete session snapshot.
        guard !isTerminating else { return }
        // Keep the last normal window's selection for reopening; never include private mini windows.
        Store.profile.saveNow()
        let tabs = controller.extensionWindow.items
        windows.removeAll { $0 === controller }
        if focusedMain === controller { focusedMain = windows.last }
        if let target = windows.first {
            for (index, item) in tabs.enumerated() {
                item.browserWindowID = target.store.windowID
                Extensions.shared.controller.didMoveTab(item.extensionTab, from: index, in: controller.extensionWindow)
            }
        }
        Extensions.shared.controller.didCloseWindow(controller.extensionWindow)
        if !windows.isEmpty { Store.profile.saveNow() }
    }

    func window(for page: Page?) -> MainWindowController? {
        guard let page else { return nil }
        if let owner = page.webView.window?.windowController as? MainWindowController { return owner }
        return windows.first { controller in controller.peek?.page === page || page.item.map { controller.store.displays($0) } == true }
            ?? windows.first { $0.store.windowID == page.item?.browserWindowID }
    }
    private var pendingURLs: [URL] = []
    private var launched = false
    private var keyMonitor: Any?
    private var archiveTimer: Timer?
    private let archivedMenu = NSMenu(title: "Archived Tabs")
    private let historyMenu = NSMenu(title: "History")
    private var updateMenuItem: NSMenuItem?

    private var store: Store { Store.shared }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Bangs.shared
        registerCommands()
        wireEngine()
        if let saved = Store.profile.state.windows, !saved.isEmpty {
            for snapshot in saved { newWindow(restoring: snapshot, present: false) }
        } else {
            let profile = Store.profile
            newWindow(restoring: profile.windowState, present: false)
        }
        buildMenu()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let w = event.window,
                  w.windowController is MainWindowController || w.windowController is MiniWindowController,
                  w.attachedSheet == nil else { return event }
            if let controller = w.windowController as? MainWindowController, controller !== self.main {
                self.windowFocused(controller)
            }
            // Esc closes an open preview.
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               w === self.main.window, self.main.peek != nil, self.main.commandBar.isHidden {
                self.main.dismissPeek()
                return nil
            }
            // Sorrel's own shortcuts first, then the ones extensions declare (their manifest `commands`).
            return (Keybindings.shared.handle(event) || Extensions.shared.handleKey(event)) ? nil : event
        }

        for controller in windows {
            if isQuietTest { controller.window?.orderBack(nil) } else { controller.showWindow(nil) }
        }
        bringAppForward()
        launched = true
        Blocker.shared.start()
        Extensions.shared.start()
        for controller in windows { Extensions.shared.windowReady(controller) }
        Updater.shared.start()
        NotificationCenter.default.addObserver(forName: .sorrelUpdateState, object: nil, queue: .main) { [weak self] _ in
            self?.updateMenuItem?.title = Updater.shared.menuTitle
        }
        // Put away long-unused tabs shortly after launch, then keep checking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.archiveStaleTabs() }
        Cleanup.applyAutomaticRules()
        archiveTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.archiveStaleTabs()
            Store.shared.sleepIdleTabs(olderThanMinutes: Settings.current.sleepTabsAfterMinutes)
            Cleanup.applyAutomaticRules()
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        // Settings ▸ Memory & Storage ▸ "Empty the cache when Sorrel quits" (Cleanup.swift), then the update.
        if Settings.current.emptyCacheOnQuit, !cacheEmptiedForQuit {
            cacheEmptiedForQuit = true
            Cleanup.emptyCacheBeforeQuitting { [weak self] in
                // Carry on with the rest of quitting; a pending update answers for itself once handed over.
                guard let self, self.applicationShouldTerminate(NSApp) == .terminateNow else { return }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // A downloaded, verified update is handed to the updater service on the way out (Updater.swift).
        if Updater.shared.installOnQuit(then: { NSApp.reply(toApplicationShouldTerminate: true) }) { return .terminateLater }
        return .terminateNow
    }
    private var cacheEmptiedForQuit = false

    func applicationWillTerminate(_ notification: Notification) {
        Store.profile.saveNow()
        History.shared.saveNow()
    }

    private func archiveStaleTabs() {
        let n = store.archiveStaleTabs(olderThanHours: Settings.current.archiveAfterHours)
        if n > 0 { main?.showToast("Archived \(n) unused tab\(n == 1 ? "" : "s") · Tabs ▸ Archived Tabs") }
    }

    /// Called by the Settings window after a change.
    func settingsChanged(blocking: Bool) {
        for controller in windows { controller.root.trackWhenInactive = Settings.current.sidebarHoverWhenInactive }
        if blocking { Blocker.shared.settingsChanged() }
    }

    func showMainWindow() {
        if let main { focus(main) } else {
            let saved = Store.profile.state.windows?.first
            newWindow(restoring: saved)
        }
    }

    /// Links from other apps.
    private func open(_ urls: [URL]) {
        for url in urls {
            if Settings.current.externalLinksOpenInMiniWindow {
                MiniWindowController.present(url: url)
            } else {
                showMainWindow()
                store.newTab(url: url.absoluteString)
            }
        }
    }

    // MARK: Engine callbacks

    private func wireEngine() {
        let engine = Engine.shared
        engine.onNewPage = { [weak self] newPage, source in
            guard let self else { return }
            let store = self.window(for: source)?.store ?? self.store
            if let item = source?.item {
                let space = store.space(containing: item)
                store.newTab(url: "", in: space, after: item, page: newPage)
            } else if let source, self.window(for: source)?.peek?.page === source {
                store.newTab(url: "", page: newPage)
            } else if source != nil {
                MiniWindowController.present(url: nil, page: newPage, isPrivate: newPage.isPrivate)
            } else {
                store.newTab(url: "", page: newPage)
            }
        }
        engine.onOpenInBackground = { [weak self] url, source in
            guard let self else { return }
            // From a private window, the link stays private: it must not become a normal tab with history and cookies.
            if source?.isPrivate == true {
                MiniWindowController.present(url: url, isPrivate: true)
                return
            }
            let store = self.window(for: source)?.store ?? self.store
            let item = source?.item
            let created = store.newTab(url: url.absoluteString, in: item.flatMap { store.space(containing: $0) },
                              after: item, select: false)
            // Background tabs start loading right away, as they do in other browsers.
            _ = Engine.shared.ensurePage(for: created)
        }
        engine.onPageClosed = { [weak self] page in
            if let item = page.item {
                self?.store.close(item)
            } else {
                MiniWindowController.all.first { $0.page === page }?.close()
            }
        }
        engine.onPeek = { [weak self] url, source in
            self?.window(for: source)?.showPeek(url, profileID: source.profileID)
        }
        engine.onToast = { [weak self] text in self?.main?.showToast(text) }
        engine.onDownloadStarted = { record, webView in
            (webView?.window?.windowController as? MainWindowController)?.downloadStarted(record, in: webView) ?? false
        }
        DownloadFlight.install()
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

        c.register("window.new", "New Window") { [unowned self] in
            self.newWindow().commandBar.present(.newTab)
        }
        c.register("window.close", "Close Window") { NSApp.keyWindow?.performClose(nil) }

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
        c.register("video.pictureInPicture", "Picture in Picture") { [unowned self] in
            if let view = self.activeWebView { PictureInPicture.shared.toggle(view) }
        }
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
        // Arc's Library, over the sidebar (Library.swift). A hidden sidebar slides out to show it.
        c.register("library.open", "Open Library") { [unowned self] in
            self.main.peekSidebar()
            self.main.sidebar.toggleLibrary()
        }
        c.register("library.downloads", "Show Downloads") { [unowned self] in
            self.main.peekSidebar()
            self.main.sidebar.openLibrary(.downloads)
        }
        c.register("import.browser", "Import from Another Browser…") { [unowned self] in
            self.showMainWindow()
            self.main.showImporter()
        }
        c.register("history.show", "Show History") { [unowned self] in
            self.showMainWindow()
            self.main.peekSidebar()
            self.main.sidebar.openLibrary(.history)
            self.main.sidebar.library.focusSearch()
        }
        // Clearing and freeing up (Cleanup.swift, ClearDataPanel.swift, Settings ▸ Memory & Storage).
        c.register("data.clearRecent", "Clear Browsing Data…") { ClearDataPanel.present() }
        c.register("data.manage", "Manage Website Data…") { WebsiteDataPanel.present() }
        c.register("site.forget", "Forget This Site…") { [unowned self] in
            guard let site = Site.key(self.activeWebView?.url?.host) else { self.main.showToast("Open a website first"); return }
            LibraryView.confirmForget(site: site)
        }
        c.register("cache.empty", "Empty Cache") { [unowned self] in
            Cleanup.measure { before in
                Cleanup.clear(.cache, since: .distantPast) {
                    Cleanup.measure { after in
                        let freed = (before.cacheBytes + before.iconBytes) - (after.cacheBytes + after.iconBytes)
                        self.main.showToast(freed > 0 ? "Cache emptied · \(Cleanup.bytes(freed)) freed" : "Cache emptied")
                    }
                }
            }
        }
        c.register("tabs.sleepSpace", "Put Tabs in This Space to Sleep") { [unowned self] in
            let n = self.store.sleepTabs(self.store.tabs(inSpace: self.store.currentSpace))
            self.main.showToast(n == 0 ? "No other tabs in this space to put to sleep" : "\(n) tab\(n == 1 ? "" : "s") asleep")
        }
        c.register("settings.storage", "Memory and Storage Settings…") { SettingsWindowController.shared.show(tabNamed: "Memory & Storage") }
        c.register("library.archive", "Show Archived Tabs") { [unowned self] in
            self.main.peekSidebar()
            self.main.sidebar.openLibrary(.archive)
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
        c.register("extensions.manage", "Manage Extensions…") { SettingsWindowController.shared.show(tabNamed: "Extensions") }
        c.register("extensions.menu", "Show Extensions") { [unowned self] in
            self.showMainWindow()
            if self.main.mode == .hidden { self.main.toggleSidebar() }
            self.main.sidebar.showExtensionsMenu()
        }
        c.register("blocking.update", "Update Ad Blocking Lists") { [unowned self] in
            self.main.showToast("Updating filter lists…")
            Blocker.shared.update { ok in self.main.showToast(ok ? "Filter lists updated" : "Couldn’t update the filter lists") }
        }
        // Zen's "unload all tabs": every tab you can't see sleeps now, and WebKit's in-memory caches are emptied.
        c.register("tabs.sleepNow", "Free Up Memory (Put Background Tabs to Sleep)") { [unowned self] in
            Cleanup.freeMemory { slept, freed in self.main.showToast(Cleanup.freedMessage(slept: slept, freed: freed)) }
        }
        c.register("blocking.updateExtension", "Check for uBlock Origin Lite Update") { [unowned self] in
            self.main.showToast("Checking for a uBlock Origin Lite update…")
            Extensions.shared.updateBlockerIfNeeded(force: true) { message in self.main.showToast(message) }
        }
        c.register("updates.check", "Check for Updates…") { Updater.shared.checkOrRelaunch() }
        c.register("extensions.update", "Check for Extension Updates") { [unowned self] in
            self.main.showToast("Checking for extension updates…")
            Extensions.shared.updateBlockerIfNeeded(force: true) { message in self.main.showToast(message) }
            Extensions.shared.updateChromeExtensionsIfNeeded(force: true) { message in self.main.showToast(message) }
        }
        c.register("archive.now", "Archive Unused Tabs Now") { [unowned self] in
            let hours = Settings.current.archiveAfterHours > 0 ? Settings.current.archiveAfterHours : 24
            let n = self.store.archiveStaleTabs(olderThanHours: hours)
            self.main.showToast(n == 0 ? "No unused tabs to archive" : "Archived \(n) tab\(n == 1 ? "" : "s")")
        }
        c.register("data.clear", "Clear Cookies and Website Data…") { ClearDataPanel.present(kinds: [.siteData, .cache], range: .all) }
        c.register("config.reload", "Reload Settings, Shortcuts and Bangs") { [unowned self] in
            Settings.current = Settings.load()
            Keybindings.shared.reload()
            Bangs.shared.reload()
            self.buildMenu()
            self.main.root.trackWhenInactive = Settings.current.sidebarHoverWhenInactive
            self.main.showToast("Settings reloaded")
        }
        c.register("history.clear", "Clear Browsing History…") { ClearDataPanel.present(kinds: [.history], range: .all) }
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

    // MARK: Archived tabs menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu {
            menu.removeAllItems()
            menu.addItem(item("nav.back"))
            menu.addItem(item("nav.forward"))
            menu.addItem(item("tab.reopen"))
            menu.addItem(item("history.show"))
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
            menu.addItem(item("data.clearRecent"))
            menu.addItem(item("site.forget"))
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
            {
                let mi = item("updates.check", title: Updater.shared.menuTitle)
                updateMenuItem = mi
                return mi
            }(),
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
            item("window.new"), item("tab.new"), item("mini.new"), item("private.new"), item("folder.new"), item("space.new"),
            .separator(),
            item("tab.close"), item("window.close"), item("tab.reopen"),
            .separator(),
            item("mini.expand"), item("tab.openInFallback"),
            .separator(),
            item("library.downloads"), item("downloads.show"), item("tab.print"),
            .separator(),
            item("import.browser"),
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
            item("video.pictureInPicture"),
            item("view.zoomIn"), item("view.zoomOut"), item("view.zoomReset"),
            .separator(),
            item("blocking.toggleSite"), item("blocking.updateExtension"), item("extensions.update"), item("extensions.manage"),
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
            item("library.archive"), item("archive.now"),
            .separator(),
            item("tabs.sleepNow"), item("tabs.sleepSpace"),
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

        if env["SORREL_FULLSCREEN_TEST"] != nil {
            // Exercise fullscreen layout callbacks without switching the owner's macOS Space.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.main.debugFullscreenTest(log: log)
            }
        }

        if let mode = env["SORREL_WINDOWTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                func check(_ label: String, _ value: Bool) { log("windows: \(label) expected=true got=\(value)") }
                guard let first = self.windows.first else { check("first window", false); return }
                if mode == "restore" {
                    check("restored two windows", self.windows.count == 2)
                    check("restored independent selections", self.windows.count == 2 && self.windows[0].store.selected !== self.windows[1].store.selected)
                    check("restored page ownership", self.windows.allSatisfy { $0.currentWebView?.window === $0.window })
                    check("normal stores share session", self.windows.count == 2 && self.windows[0].currentWebView?.configuration.websiteDataStore === self.windows[1].currentWebView?.configuration.websiteDataStore)
                    return
                }
                let a = first.store.newTab(url: "sorrel://welcome")
                Commands.shared.run("window.new")
                guard let second = self.main, second !== first else { check("new window command", false); return }
                second.commandBar.dismiss()
                check("new window command", self.windows.count == 2 && second.store.selected == nil)
                let b = second.store.newTab(url: "sorrel://welcome")
                check("independent selections", first.store.selected === a && second.store.selected === b)
                check("page ownership", a.page?.webView.window === first.window && b.page?.webView.window === second.window)
                let third = self.newWindow()
                let thirdTab = third.store.newTab(url: "sorrel://welcome")
                check("three independent windows", self.windows.count == 3 && first.store.selected === a && second.store.selected === b && third.store.selected === thirdTab)
                third.close()
                self.focus(second)
                check("shared normal logins", a.page?.webView.configuration.websiteDataStore === b.page?.webView.configuration.websiteDataStore)
                let privatePage = Engine.shared.makePage(profileID: nil, isPrivate: true)
                check("private session isolated", !privatePage.webView.configuration.websiteDataStore.isPersistent && privatePage.webView.configuration.websiteDataStore !== a.page?.webView.configuration.websiteDataStore)
                privatePage.teardown()
                second.store.select(a)
                check("select existing focuses owner", self.main === first && first.store.selected === a && second.store.selected === b && a.page?.webView.window === first.window)
                self.focus(second)
                let toClose = second.store.newTab(url: "sorrel://welcome")
                second.store.close(toClose)
                check("close tab keeps focus in its window", self.main === second && first.store.selected === a && second.store.selected !== a)
                second.store.select(b)
                let beforeBackground = Set(first.store.allTabs.map { $0.item.id })
                Engine.shared.onOpenInBackground?(URL(string: "sorrel://welcome")!, a.page)
                let background = first.store.allTabs.first { !beforeBackground.contains($0.item.id) }?.item
                check("background link uses source window", background?.browserWindowID == first.store.windowID && first.store.selected === a && second.store.selected === b)
                let sp = second.store.addSpace(name: "Window test")
                let c = second.store.newTab(url: "sorrel://welcome")
                check("space selection independent", first.store.currentSpace !== sp && second.store.currentSpace === sp && first.store.selected === a)
                let d = second.store.newTab(url: "sorrel://welcome", select: false)
                let split = second.store.makeSplit(c, with: d)
                check("split stays in its window", split != nil && second.card.panes.count == 2 && first.card.panes.count == 1)
                first.store.select(c)
                check("select split pane focuses owner", self.main === second && second.store.selected === c && first.store.selected === a && c.page?.webView.window === second.window)
                check("cannot split across windows", first.store.makeSplit(a, with: c) == nil)
                check("sleep protects both windows", first.store.sleepTabs([a, c, d]) == 0)
                a.lastActive = .distantPast; c.lastActive = .distantPast; d.lastActive = .distantPast
                _ = first.store.archiveStaleTabs(olderThanHours: 1)
                check("archive protects both windows", first.store.item(id: a.id) === a && first.store.item(id: c.id) === c)
                check("extension windows distinct", a.extensionTab.owner === first && c.extensionTab.owner === second)
                check("extension tab lists independent", first.extensionWindow.items.contains(a) && !first.extensionWindow.items.contains(c) && second.extensionWindow.items.contains(c))
                first.store.close(d)
                check("close pane preserves other window", first.store.selected === a && second.store.selected === c && second.card.panes.count == 1)
                second.close()
                check("close one keeps other", self.windows.count == 1 && first.store.selected === a && a.page?.webView.window === first.window)
                first.close()
                check("close all releases controllers", self.windows.isEmpty)
                Commands.shared.run("window.show")
                check("reopen last window", self.windows.count == 1 && self.main.store.selected === a)
                let restored = self.main!
                let last = self.newWindow()
                last.store.newTab(url: "sorrel://welcome")
                restored.store.saveNow()
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                let saved = try? decoder.decode(AppState.self, from: Data(contentsOf: Paths.state))
                check("save both window selections", saved?.windows?.count == 2 && saved?.windows?.allSatisfy { !$0.selections.isEmpty } == true)
            }
        }

        if let fixture = env["SORREL_PIPTEST"] {
            PictureInPicture.shared.runTest(store: self.store, fixture: fixture)
        }
        if env["SORREL_MEDIATEST"] != nil {
            main.sidebar.mediaPlayer.runMediaTest()
        }

        if env["SORREL_MEDIASEEKTEST"] != nil {
            main.sidebar.mediaPlayer.runMediaSeekTest()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            for id in (env["SORREL_RUN"] ?? "").split(separator: ",") { Commands.shared.run(String(id)) }
            if let u = env["SORREL_OPEN"] { self.store.newTab(url: u) }
            if let u = env["SORREL_MINI"], let url = URL(string: u) { MiniWindowController.present(url: url) }
            if let s = env["SORREL_SIDEBAR"] { self.main.debugSetSidebar(s) }
            if let text = env["SORREL_COMMAND"] { self.main.commandBar.debugType(text) }
            if let text = env["SORREL_TYPETEST"] {
                // Types into the ⌘T bar one letter at a time with stand-in suggestions (no network) and
                // watches for flicker: the field moving, rows vanishing then returning, the height
                // reversing, the shadow out of step with the panel, whole-list rebuilds.
                let bar = self.main.commandBar
                let gap = Double(env["SORREL_TYPEGAP"] ?? "") ?? 0.45
                // Like a real engine: completions of what is typed, from a fixed list.
                let words = ["nephrology", "nephron", "nephritis", "nephrotic syndrome", "nephrolithiasis",
                             "nephrectomy", "nephrogenic diabetes insipidus", "nephrologist", "neph meaning", "network"]
                bar.debugSuggest = { q in words.filter { $0.hasPrefix(q.lowercased()) } }
                bar.debugType("")
                let field0 = bar.debugFieldFrame
                var samples: [CGFloat] = [], fieldMoves = 0, shadowOff = 0, reversals = 0, lastDir: CGFloat = 0
                var lastRows: [String] = [], gone: Set<String> = [], blinks: Set<String> = []
                let sampler = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
                    let h = bar.debugPanelHeight
                    if let prev = samples.last, abs(h - prev) > 0.25 {
                        let dir: CGFloat = h > prev ? 1 : -1
                        if lastDir != 0, dir != lastDir { reversals += 1 }
                        lastDir = dir
                    }
                    samples.append(h)
                    if abs(bar.debugFieldFrame.minY - field0.minY) > 0.5 {
                        if fieldMoves == 0 { log("typing: field moved \(field0) -> \(bar.debugFieldFrame) with \(bar.debugResultTitles.count) rows") }
                        fieldMoves += 1
                    }
                    if abs(bar.debugShadowHeight - h) > 1 { shadowOff += 1 }
                    let rows = bar.debugResultTitles
                    for r in lastRows where !rows.contains(r) { gone.insert(r) }
                    for r in rows where gone.contains(r) { blinks.insert(r); gone.remove(r) }
                    lastRows = rows
                }
                RunLoop.main.add(sampler, forMode: .common)
                let letters = Array(text)
                for (i, _) in letters.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + gap * Double(i)) {
                        bar.debugSetText(String(letters[0...i]))
                        log("typing: \"\(String(letters[0...i]))\" now=\(bar.debugResultTitles.count) rows")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + gap * Double(letters.count) + 0.6) {
                    sampler.invalidate()
                    log("typing: final rows=\(bar.debugResultTitles)")
                    log("typing: fieldMoves=\(fieldMoves) heightReversals=\(reversals) shadowOutOfStep=\(shadowOff)/\(samples.count) blinkedRows=\(blinks.count) fullReloads=\(bar.debugFullReloads)")
                    if !blinks.isEmpty { log("typing: blinked \(blinks.sorted().prefix(6))") }
                    var runs: [String] = []
                    for h in samples where runs.last != String(format: "%.0f", h) { runs.append(String(format: "%.0f", h)) }
                    log("typing: heights \(runs.joined(separator: " "))")
                }
            }
            if env["SORREL_THEME"] != nil { self.main.sidebar.showThemeEditor() }
            if let dir = env["SORREL_BRIGHTNESSTEST"] {
                // Opt-in space brightness: legacy defaults, colour endpoints, real slider/preset actions and saving.
                func check(_ name: String, _ ok: Bool) { log("bright: \(name) expected=true got=\(ok)") }
                let old = try? JSONDecoder().decode(Theme.self, from: Data(##"{"colors":["#FE6F3E"],"angle":315,"intensity":1}"##.utf8))
                check("legacy soft default", old?.brightnessAmount == 0)
                var soft = Theme(colors: ["#FE6F3E"], angle: 315, intensity: 1)
                var bright = soft; bright.brightness = 1
                var middle = soft; middle.brightness = 0.5
                for dark in [false, true] {
                    let a = soft.softLabs(dark: dark)[0], b = bright.softLabs(dark: dark)[0]
                    check("vividness dark=\(dark)", b.chroma > a.chroma)
                    check("chosen color at full brightness dark=\(dark)", bright.resolvedColors(systemIsDark: dark)[0].hexString == "#FE6F3E")
                    let mid = middle.softLabs(dark: dark)[0]
                    check("smooth midpoint dark=\(dark)", abs(mid.a - (a.a + b.a) / 2) < 0.000001)
                }
                check("dark mode brighter", bright.resolvedColors(systemIsDark: true)[0].luminance > soft.resolvedColors(systemIsDark: true)[0].luminance)
                soft.brightness = 0
                check("legacy colors unchanged", old?.gradientStops(dark: true).map(\.hexString) == soft.gradientStops(dark: true).map(\.hexString))
                var bounds = soft; bounds.brightness = -1
                check("lower bound", bounds.brightnessAmount == 0)
                bounds.brightness = 2
                check("upper bound", bounds.brightnessAmount == 1)
                var valid = true
                for preset in Theme.presets {
                    for amount in [0.0, 0.5, 1.0] {
                        var t = preset; t.brightness = amount
                        for dark in [false, true] {
                            let stops = t.gradientStops(dark: dark)
                            valid = valid && stops.count == Theme.gradientStopCount && stops.allSatisfy {
                                [$0.redComponent, $0.greenComponent, $0.blueComponent].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
                            }
                        }
                    }
                }
                check("all presets valid light and dark", valid)
                check("swipe soft endpoint", Theme.blendedStops(soft, bright, 0, dark: true).map(\.hexString) == soft.gradientStops(dark: true).map(\.hexString))
                check("swipe bright endpoint", Theme.blendedStops(soft, bright, 1, dark: true).map(\.hexString) == bright.gradientStops(dark: true).map(\.hexString))
                let m = self.main!, space = self.store.currentSpace
                _ = self.store.addSpace(name: "Brightness isolation", theme: Theme.presets[2])
                self.store.switchSpace(to: space)
                let others = self.store.spaces.filter { $0 !== space }.map(\.theme)
                self.store.setTheme(Theme.presets[0], for: space)
                m.sidebar.showThemeEditor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let editor = m.sidebar.debugThemeEditor else { check("editor opened", false); return }
                    let before = space.theme
                    editor.debugSetBrightness(0.75)
                    check("slider saves", space.theme.brightnessAmount == 0.75)
                    check("other controls unchanged", space.theme.colors == before.colors && space.theme.intensity == before.intensity && space.theme.grainAmount == before.grainAmount && space.theme.angle == before.angle)
                    editor.debugPickPreset(1)
                    check("preset keeps brightness", space.theme.brightnessAmount == 0.75 && space.theme.colors == Theme.presets[1].colors)
                    editor.debugSetGrain(0.9)
                    _ = editor.debugWheelDrag(dot: 0, turn: 0.1)
                    check("wheel and grain keep brightness", space.theme.brightnessAmount == 0.75 && space.theme.grainAmount == 0.9)
                    check("other spaces unchanged", others == self.store.spaces.filter { $0 !== space }.map(\.theme))
                    self.store.saveNow()
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    let saved = (try? Data(contentsOf: Paths.state)).flatMap { try? decoder.decode(AppState.self, from: $0) }
                    check("saved state roundtrip", saved?.spaces.first(where: { $0.id == space.id })?.theme == space.theme)
                    m.sidebar.showThemeEditor()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        m.sidebar.debugThemeEditor?.debugSetGrain(0.4)
                        check("reopened editor keeps brightness", space.theme.brightnessAmount == 0.75)
                        if let v = m.sidebar.debugCustomizeView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                            v.cacheDisplay(in: v.bounds, to: rep)
                            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/brightness.png"))
                        }
                        m.sidebar.debugThemeEditor?.debugSetBrightness(0)
                        check("return to soft", space.theme.brightnessAmount == 0)
                        check("done", true)
                    }
                }
            }
            if let dir = env["SORREL_THEMETEST"] {
                // Arc-style colours (ThemeLook.swift): old saves still load, every preset in light and dark, the
                // colour wheel and grain slider. Writes preset-<i>-<light|dark>.png and customize.png into `dir`.
                let m = self.main!
                let space = self.store.currentSpace
                let old = try? JSONDecoder().decode(Theme.self, from: Data(##"{"colors":["#7C9CFF"],"angle":315,"intensity":0.55}"##.utf8))
                log("theme: legacy decodes=\(old != nil) grain=\(old?.grainAmount ?? -1)")
                var t = Theme.presets[3]; t.grain = 0.8
                let back = (try? JSONEncoder().encode(t)).flatMap { try? JSONDecoder().decode(Theme.self, from: $0) }
                log("theme: roundtrip grain=\(back?.grain ?? -1) equal=\(back == t)")
                let err = ["#FE6F3E", "#2B3A67", "#FFFFFF", "#000000", "#34E895"].map { h -> CGFloat in
                    let c = NSColor(hex: h)!, r = OKLab(c).color
                    return max(abs(c.redComponent - r.redComponent), abs(c.greenComponent - r.greenComponent), abs(c.blueComponent - r.blueComponent))
                }.max()!
                log("theme: oklab roundtrip maxError=\(String(format: "%.4f", err)) stops=\(Theme.presets[0].gradientStops(dark: false).count)")
                func shoot(_ name: String) {
                    guard let v = m.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
                }
                var steps: [() -> Void] = []
                for dark in [false, true] {
                    for (i, p) in Theme.presets.enumerated() {
                        steps.append {
                            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                            self.store.setTheme(p, for: space)
                            m.applyTheme(animated: false)
                        }
                        steps.append {
                            let hex = p.gradientStops(dark: dark).map(\.hexString)
                            log("theme: preset \(i) \(dark ? "dark" : "light") first=\(hex.first!) last=\(hex.last!) grain=\(p.grainAmount) textDark=\(p.isDark(systemIsDark: dark))")
                            shoot("preset-\(i)-\(dark ? "dark" : "light").png")
                        }
                    }
                }
                steps.append {
                    NSApp.appearance = NSAppearance(named: .aqua)
                    self.store.setTheme(Theme(colors: ["#FF0000", "#00FFFF"], angle: 315, intensity: 0.8), for: space)
                    m.applyTheme(animated: false)
                    m.sidebar.showThemeEditor()
                }
                steps.append {
                    guard let ed = m.sidebar.debugThemeEditor else { log("theme: no editor"); return }
                    log("theme: wheel turn first dot 0.25 -> \(ed.debugWheelDrag(dot: 0, turn: 0.25)) (expect both hues +90°: ~#80FF00/~#7F00FF)")
                    log("theme: wheel turn second dot 0.25 -> \(ed.debugWheelDrag(dot: 1, turn: 0.25)) (expect only the second to move)")
                    ed.debugSetGrain(0.9)
                    log("theme: grain slider -> \(self.store.currentSpace.theme.grain ?? -1) (expect 0.9)")
                }
                steps.append {
                    if let v = m.sidebar.debugCustomizeView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/customize.png"))
                    }
                    shoot("after-wheel.png")
                    log("theme: done")
                }
                for (k, step) in steps.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 * Double(k), execute: step) }
            }
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
        if env["SORREL_EXTACTIONTEST"] != nil {
            // Toolbar button state (icon, badge, enabled) and keyboard shortcuts of every loaded extension,
            // then the first shortcut is pressed to see that WebKit routes it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                for e in Extensions.shared.loaded {
                    let a = Extensions.shared.action(for: e)
                    let icon = a?.icon(for: NSSize(width: 16, height: 16))
                    log("action[\(e.id)]: label=\(a?.label ?? "nil") badge=\(a?.badgeText ?? "nil") enabled=\(a?.isEnabled ?? false) popup=\(a?.presentsPopup ?? false) icon=\(icon.map { "\(Int($0.size.width))x\(Int($0.size.height)) reps=\($0.representations.count)" } ?? "nil") menuItems=\(a?.menuItems.map { $0.title } ?? [])")
                    for c in Extensions.shared.commands(for: e) {
                        log("command[\(e.id)]: \(c.id) | \(c.title) | key=\(c.activationKey ?? "nil") mods=\(c.modifierFlags.rawValue) shown=\(Extensions.shortcutText(for: c) ?? "nil") menu=\(c.menuItem.title) [\(c.menuItem.keyEquivalent) \(c.menuItem.keyEquivalentModifierMask.rawValue)]")
                    }
                }
                let which = env["SORREL_EXTACTIONTEST"] ?? ""
                guard let e = Extensions.shared.loaded.first(where: { $0.id.contains(which) }),
                      let c = Extensions.shared.commands(for: e).first(where: { $0.activationKey != nil }),
                      let key = c.activationKey, let window = self.main.window,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: c.modifierFlags, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: key,
                                                   charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else {
                    log("action: no extension shortcut to press")
                    return
                }
                let handled = Extensions.shared.handleKey(event)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    log("action: pressed \(Extensions.shortcutText(for: c) ?? "?") for \(c.id) handled=\(handled) popupOpen=\(Extensions.shared.isPopupOpen)")
                }
            }
        }
        if env["SORREL_EXTUPDATETEST"] != nil {
            // Chrome Web Store update check against SORREL_CRX_DIR (a folder of <id>.crx files), then what is on disk.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Extensions.shared.updateChromeExtensionsIfNeeded(force: true) { message in
                    log("extupdate result: \(message.replacingOccurrences(of: "\n", with: " | "))")
                    for e in Extensions.shared.entries where e.chromeID != nil {
                        log("extupdate state: \(e.id) version=\(e.version) loaded=\(e.isLoaded) pending=\(Extensions.shared.hasPendingUpdate(e))")
                    }
                }
            }
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
                            // SORREL_UI_PREOPEN=<url>: open a web page first (its content scripts reach the idle background).
                            if let pre = env["SORREL_UI_PREOPEN"] { self.store.newTab(url: pre) }
                            // SORREL_UI_CLICKDELAY=<s>: wait before clicking the icon (lets PREOPEN's page wake the background alone).
                            // SORREL_UI_HOVER=<ms>: the pointer reaches the icon that long before the click (pre-wake).
                            let hoverLead = (Double(env["SORREL_UI_HOVER"] ?? "") ?? 0) / 1000
                            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["SORREL_UI_CLICKDELAY"] ?? "") ?? 0)) {
                                if hoverLead > 0 { Extensions.shared.prewarm(ubol) }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["SORREL_UI_CLICKDELAY"] ?? "") ?? 0) + hoverLead) {
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
                                    // Does the pop-up page think it is on screen? Hidden pages run no animation frames and no CSS animations.
                                    if let wv = action?.popupWebView {
                                        group.enter()
                                        wv.callAsyncJavaScript("return await new Promise(function (done) { var t = setTimeout(function () { done('stalled') }, 1000); requestAnimationFrame(function () { clearTimeout(t); done('ok') }) }).then(function (raf) { return 'visibility=' + document.visibilityState + ' focus=' + document.hasFocus() + ' rAF=' + raf + ' animations=' + document.getAnimations().map(function (a) { return a.playState }).join(',') })",
                                                               arguments: [:], in: nil, in: .page) { result in
                                            if case .success(let v) = result { log("ui: popup frames \(v)") } else { log("ui: popup frames \(result)") }
                                            log("ui: popover window visible=\(wv.window?.isVisible ?? false) occlusion=\(wv.window?.occlusionState.contains(.visible) ?? false) key=\(wv.window?.isKeyWindow ?? false)")
                                            group.leave()
                                        }
                                    }
                                    log("ui: context errors=\((ubol.context?.errors ?? []).map { $0.localizedDescription })")
                                    shoot(action?.popupWebView, env["SORREL_SNAPSHOT_POPUP"])
                                    shoot(self.store.selected?.page?.webView, env["SORREL_SNAPSHOT_DASH"])
                                    group.notify(queue: .main) { NSApp.terminate(nil) }
                                }
                            }
                          }
                          if ubol.isLoaded {
                              DispatchQueue.main.asyncAfter(deadline: .now() + (Double(env["SORREL_UI_PREWAIT"] ?? "") ?? 0)) { run() }
                          } else {
                              Extensions.shared.setEnabled(ubol, true) { ok in
                                  log("ui: enabled \(ubol.name) ok=\(ok) error=\(ubol.error ?? "none")")
                                  // SORREL_UI_PREWAIT: leave the extension idle first (WebKit stops idle background scripts).
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 6 + (Double(env["SORREL_UI_PREWAIT"] ?? "") ?? 0)) { run() }
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
        if env["SORREL_CLEANTEST"] != nil {
            // Clearing and freeing up (Cleanup.swift, ClearDataPanel.swift, Library ▸ History, Settings ▸ Memory &
            // Storage). Seeds stand-in history at known ages, opens three real pages, then walks every path and logs
            // `clean:` lines. Site data is the test build's in-memory store. SORREL_CLEANSHOTS=<dir> writes pictures.
            let shots = env["SORREL_CLEANSHOTS"].map { URL(fileURLWithPath: $0) }
            func shoot(_ view: NSView?, _ name: String) {
                guard let shots, let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                // Onto the window's own background colour, so light-on-dark text shows in the picture.
                let out = NSImage(size: view.bounds.size)
                out.lockFocus()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: view.bounds.size).fill()
                }
                rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: false, hints: nil)
                out.unlockFocus()
                if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: shots.appendingPathComponent(name))
                }
            }
            func js(_ wv: WKWebView?, _ code: String, _ done: @escaping (String) -> Void) {
                wv?.evaluateJavaScript(code) { r, e in done("\(r ?? e?.localizedDescription ?? "nil")") }
            }
            func step(_ at: Double, _ run: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: run) }
            let now = Date()
            History.shared.merge([
                .init(url: "https://example.com/recent", title: "Example recent", visits: 3, last: now.addingTimeInterval(-600)),
                .init(url: "https://www.example.com/older", title: "Example two days", visits: 1, last: now.addingTimeInterval(-2 * 86400)),
                .init(url: "https://b.test/old", title: "B forty days", visits: 1, last: now.addingTimeInterval(-40 * 86400)),
                .init(url: "https://c.test/today", title: "C today", visits: 1, last: now.addingTimeInterval(-1800)),
            ])
            log("clean: seeded history=\(History.shared.count)")
            let a = self.store.newTab(url: "https://example.com/")
            let b = self.store.newTab(url: "https://example.org/", select: false)
            let c = self.store.newTab(url: "https://www.iana.org/help/example-domains", select: false)
            for t in [b, c] { _ = Engine.shared.ensurePage(for: t) }
            step(7) {
                log("clean: mac memory=\(Cleanup.memoryInUse().map { "\(Cleanup.memory($0.used)) of \(Cleanup.memory($0.total))" } ?? "nil") awake=\(self.store.tabCounts.awake)")
                js(a.page?.webView, "document.cookie = 'cleantest=1; max-age=3600'; localStorage.setItem('k','v'); document.cookie") { log("clean: cookie set: \($0)") }
            }
            step(9) {
                Cleanup.fetchSites { sites in log("clean: sites=\(sites.map { "\($0.name) [\($0.summary)]" })") }
                Cleanup.freeMemory { slept, freed in
                    log("clean: freeMemory slept=\(slept) freed=\(freed.map { Cleanup.bytes(Int64($0)) } ?? "nil") toast='\(Cleanup.freedMessage(slept: slept, freed: freed))' awake=\(self.store.tabCounts.awake) asleep=\(self.store.tabCounts.asleep) selectedStillLoaded=\(a.page != nil) bAsleep=\(b.page == nil)")
                }
            }
            step(12) {
                ClearDataPanel.present(kinds: [.history], range: .day)
            }
            step(13.5) {
                log("clean: panel \(ClearDataPanel.debugState ?? "not open")")
                shoot(NSApp.windows.first { $0.title == "Clear Browsing Data" }?.contentView, "clear-panel.png")
                ClearDataPanel.debugClear(range: .day, kinds: [.history])
            }
            step(14.5) {
                log("clean: after clearing last 24 hours: history=\(History.shared.list(limit: 10).map(\.title)) panelOpen=\(ClearDataPanel.debugState != nil)")
                self.main.sidebar.openLibrary(.history)
                log("clean: library history=\(self.main.sidebar.library.debugLines)")
                self.main.sidebar.library.debugSearch("forty")
                log("clean: library search 'forty'=\(self.main.sidebar.library.debugLines)")
                self.main.sidebar.library.debugSearch("")
                shoot(self.main.sidebar.library, "library-history.png")
                self.main.sidebar.library.debugRemoveFirstPage()
                log("clean: after × on first page: history=\(History.shared.list(limit: 10).map(\.title))")
                History.shared.merge([.init(url: "https://example.com/again", title: "Example again", visits: 1, last: Date())])
                Settings.current.removeHistoryAfterDays = 30
                Cleanup.applyAutomaticRules()
                Settings.current.removeHistoryAfterDays = 0
                log("clean: after remove-older-than-30-days: history=\(History.shared.list(limit: 10).map(\.title))")
                Cleanup.forget(site: "example.com") {
                    Cleanup.fetchSites { sites in
                        log("clean: after forgetting example.com: history=\(History.shared.list(limit: 10).map(\.title)) sites=\(sites.map(\.name))")
                    }
                }
            }
            step(17) {
                let settings = SettingsWindowController.shared
                settings.refreshStorage()
                step(1.5) {
                    log("clean: storage tab: \(settings.debugStorage)")
                    if let w = settings.window {
                        let i = (w.contentView?.subviews.first as? NSTabView).map { $0.indexOfTabViewItem(withIdentifier: "Memory & Storage") } ?? NSNotFound
                        if i != NSNotFound, let tv = w.contentView?.subviews.first as? NSTabView { tv.selectTabViewItem(at: i) }
                        w.contentView?.layoutSubtreeIfNeeded()
                        shoot(w.contentView, "settings-storage.png")
                    }
                }
            }
            step(19) {
                js(a.page?.webView, "document.cookie = 'again=1; max-age=3600'; document.cookie") { log("clean: cookie set again: \($0)") }
            }
            step(20) {
                WebsiteDataPanel.present()
                step(1.5) {
                    log("clean: website data panel=\(WebsiteDataPanel.debugSites ?? ["not open"])")
                    shoot(NSApp.windows.first { $0.title == "Manage Website Data" }?.contentView, "website-data.png")
                    NSApp.windows.first { $0.title == "Manage Website Data" }.map { $0.sheetParent?.endSheet($0) }
                    Cleanup.clear([.siteData, .cache], since: .distantPast) {
                        Cleanup.fetchSites { sites in
                            log("clean: after clearing all site data: sites=\(sites.count)")
                            Settings.current.emptyCacheOnQuit = true
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        if env["SORREL_SPACEROWTEST"] != nil {
            // Many spaces: the icon row scrolls, reveals the current space, and scrubs into its ends.
            let sidebar = self.main.sidebar
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sidebar.debugSpaceRowTest(shots: env["SORREL_SWIPESHOTS"], log: log) }
        }
        if env["SORREL_SWIPETEST"] != nil {
            // Space swipe: two-finger swipes and click-and-hold scrubs on the space icons (SpaceSwipe.swift).
            let sidebar = self.main.sidebar
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sidebar.debugSwipeTest(shots: env["SORREL_SWIPESHOTS"], log: log) }
        }
        if env["SORREL_GEOTEST"] != nil {
            // Website location. Checks what a background test can: Sorrel answers WebKit's location questions,
            // and a page that asks while hidden gets nothing (WebKit holds the question until the page shows; test
            // windows always count as hidden, so the prompt itself has to be tried by hand). Never answers yes:
            // that would make macOS show its own location prompt on the owner's screen.
            for name in ["_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:",
                         "_webView:requestGeolocationPermissionForFrame:decisionHandler:"] {
                log("geo: answers \(name)=\(Engine.shared.responds(to: NSSelectorFromString(name)))")
            }
            let tab = self.store.newTab(url: "about:blank")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Engine.shared.ensurePage(for: tab).webView.loadHTMLString("""
                    <script>
                    document.title = 'waiting';
                    navigator.geolocation.getCurrentPosition(
                      p => document.title = 'GOT POSITION',
                      e => document.title = 'error ' + e.code);
                    </script>
                    """, baseURL: URL(string: "https://example.org/")!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                tab.page?.webView.evaluateJavaScript("document.visibilityState + ' page, result: ' + document.title") { r, e in
                    log("geo: \(r ?? e?.localizedDescription ?? "nil"); prompt=\(Engine.shared.lastLocationPrompt ?? "none")")
                    NSApp.terminate(nil)
                }
            }
        }
        if env["SORREL_SECTEST2"] != nil {
            // Security audit fixes (2026-11-15): a leftover "Continue" offer, dialogs from hidden tabs, sorrel:// names
            // that climb out of the app, and downloads a page starts without a click. Set SORREL_DOWNLOADS to a scratch
            // folder: if the download check failed, the file would otherwise land in the real Downloads folder.
            func js(_ wv: WKWebView?, _ code: String, _ done: @escaping (String) -> Void) {
                wv?.evaluateJavaScript(code) { r, e in done("\(r ?? e?.localizedDescription ?? "nil")") }
            }
            let stale = self.store.newTab(url: env["SORREL_SECTEST_HTTP"] ?? "http://expired.badssl.com/")
            let hidden = self.store.newTab(url: "https://example.com/", select: false)
            _ = Engine.shared.ensurePage(for: hidden)
            let home = Paths.support.deletingLastPathComponent()
            try? "<h1>outside</h1>".write(to: home.appendingPathComponent("sectest2-outside.html"), atomically: true, encoding: .utf8)
            let depth = Bundle.main.resourceURL?.pathComponents.count ?? 12
            let climb = String(repeating: "../", count: depth) + String(home.appendingPathComponent("sectest2-outside").path.dropFirst())
            let lone = Engine.shared.makePage(profileID: nil)
            Engine.shared.load("sorrel://" + climb, in: lone)
            let welcome = Engine.shared.makePage(profileID: nil)
            Engine.shared.load("sorrel://welcome", in: welcome)
            let dlTab = self.store.newTab(url: "about:blank")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // Two ways a page saves a file without a click: a scripted click on a download link, and a frame
                // pointed at something the browser can't show.
                Engine.shared.ensurePage(for: dlTab).webView.loadHTMLString("""
                    <script>
                    const a = document.createElement('a');
                    a.href = URL.createObjectURL(new Blob(['unasked'], {type: 'application/octet-stream'}));
                    a.download = 'unasked.bin'; document.documentElement.appendChild(a); a.click();
                    const f = document.createElement('iframe');
                    f.src = URL.createObjectURL(new Blob(['unasked2'], {type: 'application/x-unknown-thing'}));
                    document.documentElement.appendChild(f);
                    </script>
                    """, baseURL: URL(string: "https://example.org/")!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                log("sec2: sorrel:// climbing out loaded=\(lone.webView.url?.absoluteString ?? "nothing")")
                log("sec2: sorrel://welcome loaded=\(welcome.webView.url?.lastPathComponent ?? "nothing")")
                log("sec2: page-started download prompt=\(Engine.shared.lastDownloadPrompt ?? "none") recorded=\(Engine.shared.downloads.map(\.file.lastPathComponent))")
                log("sec2: hidden tab inWindow=\(hidden.page?.webView.window != nil)")
                let started = Date()
                js(hidden.page?.webView, "alert('hi'); String(confirm('sure?')) + '|' + String(prompt('password?'))") { r in
                    log("sec2: hidden tab dialogs answered=\(r) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                }
                js(stale.page?.webView, "document.title") { title in
                    log("sec2: warning showing=\(title)")
                    // Leave the warning, then try its Continue link from the next page.
                    if let p = stale.page { Engine.shared.load("https://example.com/", in: p) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        js(stale.page?.webView, "location.href='sorrel-insecure:continue'; 'sent'") { _ in }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            log("sec2: after leftover Continue url=\(stale.page?.webView.url?.absoluteString ?? "nil") (must stay https://example.com/)")
                            NSApp.terminate(nil)
                        }
                    }
                }
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
        if let spec = env["SORREL_IMPORTDRY"] {
            // Browser import, readers only: "<source id>:<folder or file>[;…]". Logs counts, never titles or addresses.
            for part in spec.split(separator: ";") {
                let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
                guard bits.count == 2, let s = (BrowserSource.all + [.bookmarksFile]).first(where: { $0.id == bits[0] }) else { continue }
                do {
                    let f = try ImportReader.read(s, at: URL(fileURLWithPath: bits[1]))
                    let folders = (f.spaces.flatMap(\.pinned) + f.bookmarks).reduce(0) { $0 + $1.folderCount }
                    let splits = f.spaces.flatMap(\.pinned).filter { if case .split = $0 { return true }; return false }.count
                    log("import-dry: \(s.id) spaces=\(f.spaces.count) pinned=\(f.spaces.reduce(0) { $0 + $1.pinnedTabs }) today=\(f.spaces.reduce(0) { $0 + $1.todayTabs }) folders=\(folders) splits=\(splits) favorites=\(f.favorites.count) bookmarks=\(f.bookmarkCount) history=\(f.history.count) themed=\(f.spaces.filter { $0.theme != nil }.count) newest=\(f.history.first.map { ISO8601DateFormatter().string(from: $0.last) } ?? "-") problems=\(f.problems)")
                } catch {
                    log("import-dry: \(s.id) error: \(error.localizedDescription)")
                }
            }
            log("import-dry: offered=\(BrowserSource.offered().map(\.id)) arcDataVisible=\(BrowserSource.all[0].dataURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
        }
        if let spec = env["SORREL_IMPORTTEST"], let dir = env["SORREL_IMPORTSHOTS"] {
            // Browser import end to end: "<source id>:<folder or file>". Opens the card, hands the folder over as if
            // from the Open panel, imports everything found, then (SORREL_IMPORTTEST_TWICE) imports it again to
            // show nothing doubles. Writes pick.png, access.png, choose.png, done.png into SORREL_IMPORTSHOTS.
            let bits = spec.split(separator: ":", maxSplits: 1).map(String.init)
            guard bits.count == 2, let s = (BrowserSource.all + [.bookmarksFile]).first(where: { $0.id == bits[0] }) else { log("import: bad spec"); return }
            func shot(_ name: String) {
                guard let view = self.main.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let image = NSImage(size: view.bounds.size)
                image.lockFocus()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: view.bounds.size).fill()
                }
                rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
            }
            func state(_ label: String) {
                for line in self.main.importer?.debugLines ?? ["(closed)"] { log("import: [\(label)] \(line)") }
            }
            let before = (self.store.spaces.count, self.store.favorites.count)
            Commands.shared.run("import.browser")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                state("pick"); shot("pick.png")
                self.main.importer?.debugRead(s, url: URL(fileURLWithPath: bits[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    shot("access.png")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        state("choose"); shot("choose.png")
                        self.main.importer?.runImport()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            state("done"); shot("done.png")
                            log("import: spaces \(before.0)->\(self.store.spaces.count) favorites \(before.1)->\(self.store.favorites.count)")
                            for sp in self.store.spaces {
                                let tabs = self.store.tabs(in: sp.pinned)
                                let folders = sp.pinned.filter(\.isFolder).count
                                let splits = sp.pinned.filter(\.isSplit).count
                                log("import:   space \(sp.icon) pinned=\(tabs.count) folders=\(folders) splits=\(splits) today=\(sp.today.count) separateLogins=\(sp.profileID != nil) colors=\(sp.theme.colors)")
                            }
                            if env["SORREL_IMPORTTEST_TWICE"] != nil, let importer = self.main.importer {
                                importer.runImport()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { state("again") }
                            }
                        }
                    }
                }
            }
        }
        if let mode = env["SORREL_DOWNLOADTEST"], let dir = env["SORREL_DOWNLOADS"] {
            // Arc-style Library and downloads: a real download plus stand-ins for every state and day group,
            // an archived tab, then the hover preview, the Library's two sections and the in-progress strip,
            // as text and pictures. "reopen" checks what a relaunch remembered.
            let out = URL(fileURLWithPath: dir)
            let sidebar = self.main.sidebar
            func png(_ view: NSView?, _ name: String) {
                guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { log("dl: nothing to snapshot for \(name)"); return }
                view.cacheDisplay(in: view.bounds, to: rep)
                // A popover's material isn't part of the capture: paint a backdrop in the view's own appearance.
                let image = NSImage(size: view.bounds.size)
                image.lockFocus()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: view.bounds.size).fill()
                }
                rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
                image.unlockFocus()
                if let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? data.write(to: out.appendingPathComponent(name))
                }
            }
            func library(_ label: String) {
                log("dl: [\(label)] library open=\(sidebar.isLibraryOpen) section=\(sidebar.library.section)")
                for line in sidebar.library.debugLines { log("dl: [\(label)]   \(line)") }
            }
            func button(_ label: String) {
                log("dl: [\(label)] button \(sidebar.debugDownloadsRing)")
                log("dl: [\(label)] strip \(sidebar.debugStripRows)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if mode == "reopen" {
                    sidebar.openLibrary(.downloads)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        log("dl: [reopen] list=\(Engine.shared.downloads.map { "\($0.file.lastPathComponent):\($0.state)" })")
                        library("reopen")
                        Engine.shared.clearFinishedDownloads()
                        log("dl: after clear list=\(Engine.shared.downloads.count) savedFileExists=\(FileManager.default.fileExists(atPath: Paths.support.appendingPathComponent("downloads.json").path))")
                        NSApp.terminate(nil)
                    }
                    return
                }
                // An archived tab to find in Library ▸ Archive.
                let old = self.store.newTab(url: "https://example.org/")
                let tab = self.store.newTab(url: "https://example.com/")
                old.lastActive = Date().addingTimeInterval(-5 * 3600)
                log("dl: archived \(self.store.archiveStaleTabs(olderThanHours: 1)) tab(s)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let cal = Calendar.current
                    let yesterday = cal.date(byAdding: .hour, value: -4, to: cal.startOfDay(for: Date()))!
                    // Yesterday: a picture (Quick Look preview). Earlier: one whose file has gone.
                    let gone = DownloadRecord(file: out.appendingPathComponent("Old Syllabus.pdf"), started: Date().addingTimeInterval(-12 * 86400))
                    gone.state = .done
                    gone.received = 220_000
                    gone.finished = gone.started
                    Engine.shared.debugAddDownload(gone)
                    let picture = out.appendingPathComponent("leaf.png")
                    if let tiff = NSApp.applicationIconImage?.tiffRepresentation,
                       let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? data.write(to: picture)
                        let done = DownloadRecord(file: picture, started: yesterday)
                        done.state = .done
                        done.received = Int64(data.count)
                        done.finished = yesterday
                        Engine.shared.debugAddDownload(done)
                    }
                    // Today: one cancelled, one mid-way with a known size, and a real one.
                    let cancelled = DownloadRecord(file: out.appendingPathComponent("anki-deck.apkg"))
                    cancelled.state = .failed
                    cancelled.cancelled = true
                    Engine.shared.debugAddDownload(cancelled)
                    let running = DownloadRecord(file: out.appendingPathComponent("Lecture 12 — Renal Physiology.mp4"), started: Date().addingTimeInterval(-6))
                    running.total = 84_000_000
                    running.received = 31_500_000
                    running.fraction = 0.375
                    Engine.shared.debugAddDownload(running)
                    if let wv = tab.page?.webView, let f = URL(string: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf") {
                        Engine.shared.startDownload(f, in: wv)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        button("live")
                        png(self.main.window?.contentView, "strip.png")
                        sidebar.debugShowPreview()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            log("dl: [preview] rows=\(sidebar.debugPreview?.rows.map { $0.debugDescription_ } ?? [])")
                            sidebar.debugPreview?.view.appearance = NSAppearance(named: .aqua)   // capture only
                            png(sidebar.debugPreview?.view, "preview.png")
                            sidebar.toggleLibrary()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                log("dl: [library] preview closed=\(sidebar.debugPreview == nil || !(sidebar.debugPreview?.view.window?.isVisible ?? false))")
                                library("downloads")
                                button("library")
                                png(self.main.window?.contentView, "library.png")
                                sidebar.openLibrary(.archive)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    library("archive")
                                    png(self.main.window?.contentView, "archive.png")
                                    // Reopening the archived tab from the Library closes it and brings the tab back.
                                    let before = self.store.archive.count
                                    sidebar.library.debugOpenFirstArchived()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                        log("dl: [restore] archive \(before)->\(self.store.archive.count) libraryOpen=\(sidebar.isLibraryOpen) selected=\(self.store.selected?.url ?? "nil")")
                                        // The mid-way stand-in finishes: the strip empties and the ring goes.
                                        running.state = .done
                                        running.finished = Date()
                                        try? Data(count: 1024).write(to: running.file)
                                        running.received = 1024
                                        NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                                            button("finished")
                                            png(self.main.window?.contentView, "finished.png")
                                            NSApp.terminate(nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if env["SORREL_FLIGHTTEST"] != nil, let dir = env["SORREL_DOWNLOADS"] {
            // Download flight (DownloadFlight.swift): the icon flies to the Library button and the strip waits for
            // it; the themed bar shows progress; a finished row lingers with a tick, then leaves; with the sidebar
            // hidden the icon lands in the capsule over the page; a real download goes the same way without toasts.
            let out = URL(fileURLWithPath: dir)
            let sidebar = self.main.sidebar
            let root = self.main.root
            func png(_ name: String) {
                guard let view = self.main.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: out.appendingPathComponent(name)) }
            }
            func flier(_ label: String) {
                guard let p = DownloadFlight.debugFlier?.presentation() else { log("flight: [\(label)] no icon in the air"); return }
                let sc = (p.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue ?? 1
                log("flight: [\(label)] icon at (\(Int(p.position.x)),\(Int(p.position.y))) scale=\(String(format: "%.2f", sc)) opacity=\(String(format: "%.2f", p.opacity))")
            }
            func state(_ label: String) {
                log("flight: [\(label)] inFlight=\(DownloadFlight.inFlight.count) strip=\(sidebar.debugStripRows) ring=\(sidebar.debugDownloadsRing)")
                log("flight: [\(label)] capsule \(self.main.downloadsCapsule.debugLine)")
            }
            func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
            after(2) {
                let tab = self.store.newTab(url: "sorrel://welcome")
                after(2) {
                    guard let wv = tab.page?.webView else { log("flight: no page"); NSApp.terminate(nil); return }
                    let a = sidebar.downloadsAnchor
                    let target = a.convert(NSPoint(x: a.bounds.midX, y: a.bounds.midY), to: root)
                    let page = wv.convert(wv.bounds, to: root)
                    log("flight: page centre (\(Int(page.midX)),\(Int(page.midY))) button (\(Int(target.x)),\(Int(target.y)))")
                    // 1. Sidebar showing, a known size.
                    let r = DownloadRecord(file: out.appendingPathComponent("Pharmacology Notes.pdf"))
                    r.total = 12_000_000
                    let shown = self.main.downloadStarted(r, in: wv)
                    Engine.shared.debugAddDownload(r)
                    log("flight: [start] flew=\(shown) (expect true)")
                    state("start (expect inFlight=1, strip height=0, ring off)")
                    after(0.05) { flier("t=0.05 lifting at the page") }
                    after(0.35) { flier("t=0.35 mid-arc") }
                    after(0.7) { flier("t=0.70 arriving, small") }
                    after(1.1) {
                        state("landed (expect inFlight=0, one row with bar, ring on)")
                        r.received = 5_000_000
                        NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
                        after(0.6) {
                            png("bar-progress.png")
                            try? Data(count: 2048).write(to: r.file)
                            r.received = 2048
                            r.state = .done
                            r.finished = Date()
                            NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
                            after(0.8) {
                                state("done (expect row still there, action=-, ring off)")
                                png("bar-done.png")
                                after(2.4) {
                                    state("after linger (expect strip height=0)")
                                    // 2. Sidebar hidden, size unknown: lands in the capsule.
                                    self.main.toggleSidebar()
                                    after(0.8) {
                                        let r2 = DownloadRecord(file: out.appendingPathComponent("Anatomy Atlas.zip"))
                                        let flew = self.main.downloadStarted(r2, in: wv)
                                        Engine.shared.debugAddDownload(r2)
                                        log("flight: [capsule] flew=\(flew) landing at \(self.main.downloadsCapsule.landingPoint(in: root))")
                                        state("capsule start (expect not shown)")
                                        after(1.1) {
                                            state("capsule landed (expect shown, one row)")
                                            png("capsule.png")
                                            r2.state = .failed
                                            r2.cancelled = true
                                            r2.finished = Date()
                                            NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
                                            after(0.5) {
                                                state("capsule cancelled (expect row reads Cancelled)")
                                                after(1.8) {
                                                    state("capsule after linger (expect not shown)")
                                                    // 3. A real download through the engine, sidebar back.
                                                    self.main.toggleSidebar()
                                                    after(0.8) {
                                                        if let f = URL(string: "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf") {
                                                            Engine.shared.startDownload(f, in: wv)
                                                        }
                                                        after(5) {
                                                            let first = Engine.shared.downloads.first
                                                            log("flight: [real] \(first?.file.lastPathComponent ?? "-") state=\(String(describing: first?.state)) shownInWindow=\(first?.shownInWindow ?? false) (expect true)")
                                                            state("real")
                                                            NSApp.terminate(nil)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
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
        if let mode = env["SORREL_UPDATETEST"] {
            // Sorrel's own updater: version | check | install | quit, against SORREL_UPDATE_FEED (tools/update-test.sh).
            Updater.shared.runTest(mode)
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
        if let body = env["SORREL_EVALASYNC"] {
            // Like SORREL_EVAL, but the text is an async function body (may `await`; `return` the answer),
            // started SORREL_EVALAT seconds in (default 4). The app stays open until it answers or SORREL_DELAY ends.
            let at = Double(env["SORREL_EVALAT"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                self.main.currentWebView?.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                    switch result {
                    case .success(let r): log("evalasync: \(r)")
                    case .failure(let e): log("evalasync: error \(e.localizedDescription)")
                    }
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
