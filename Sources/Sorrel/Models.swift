import AppKit

// MARK: - Item (a tab or a folder)

final class Item: NSObject, Codable {
    var id = UUID()
    var isFolder = false
    var title = ""
    var customTitle: String?
    var url: String?
    /// The URL a pinned tab or favorite returns to when it is closed.
    var pinnedURL: String?
    var children: [Item] = []
    var expanded = true
    var lastActive = Date()
    /// Set when this item is a split view: two to four tabs shown side by side, kept in `children`.
    var split: SplitLayout?

    // Runtime only.
    var browserWindowID: UUID?
    var page: Page?
    weak var parent: Item?
    /// A sleeping tab's back/forward history and scroll position, restored when it wakes.
    var savedState: Any?
    /// How extensions refer to this tab.
    lazy var extensionTab = ExtensionTab(item: self)

    enum CodingKeys: String, CodingKey {
        case id, isFolder, title, customTitle, url, pinnedURL, children, expanded, lastActive, split
    }

    override init() { super.init() }

    convenience init(url: String, title: String = "") {
        self.init()
        self.url = url
        self.title = title
    }

    static func folder(named name: String) -> Item {
        let f = Item()
        f.isFolder = true
        f.title = name
        return f
    }

    var isSplit: Bool { split != nil }
    /// Folders and split views hold other items.
    var isContainer: Bool { isFolder || isSplit }

    var displayTitle: String {
        if isSplit { return children.map(\.displayTitle).joined(separator: " | ") }
        if let c = customTitle, !c.isEmpty { return c }
        if !title.isEmpty { return title }
        if isFolder { return "Folder" }
        if let u = url, let host = URL(string: u)?.host { return host }
        return "New Tab"
    }

    var host: String? { url.flatMap { URL(string: $0)?.host } }

    func isDescendant(of other: Item) -> Bool {
        var p = parent
        while let cur = p {
            if cur === other { return true }
            p = cur.parent
        }
        return false
    }
}

/// How a split view arranges its tabs.
struct SplitLayout: Codable {
    /// false = side by side, true = stacked top to bottom.
    var stacked = false
    /// Each pane's share of the space, in order. Empty or mismatched = equal shares.
    var fractions: [Double] = []

    static let maxPanes = 4

    func normalized(count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard fractions.count == count, fractions.allSatisfy({ $0 > 0 }) else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        let total = fractions.reduce(0, +)
        return fractions.map { $0 / total }
    }
}

// MARK: - Space

final class Space: NSObject, Codable {
    var id = UUID()
    var name = "Space"
    var icon = "●"
    var theme = Theme.presets[0]
    var pinned: [Item] = []
    var today: [Item] = []
    /// nil = shared default logins. A UUID = this space keeps its own cookies and logins.
    var profileID: UUID?
    var selectedID: UUID?

    enum CodingKeys: String, CodingKey {
        case id, name, icon, theme, pinned, today, profileID, selectedID
    }

    override init() { super.init() }

    convenience init(name: String, icon: String, theme: Theme) {
        self.init()
        self.name = name
        self.icon = icon
        self.theme = theme
    }
}

/// An unpinned tab that was put away after going unused.
struct ArchivedTab: Codable {
    var url: String
    var title: String
    var spaceID: UUID
    var date: Date
}

/// Window selections only; pages, cookies and tab data belong to the shared profile.
struct BrowserWindowState: Codable {
    var id: UUID
    var currentSpaceID: UUID
    var selections: [UUID: UUID]
}

struct AppState: Codable {
    var version = 1
    var spaces: [Space]
    var favorites: [Item]
    var currentSpaceID: UUID
    var windows: [BrowserWindowState]?
    var sidebarCollapsed = false
    var sidebarWidth: Double = 250
}

extension Notification.Name {
    /// Tabs, folders or favorites were added, removed or moved.
    static let sorrelStructure = Notification.Name("sorrelStructure")
    /// The selected tab changed.
    static let sorrelSelection = Notification.Name("sorrelSelection")
    /// One item's title, icon or loading state changed. `object` is the Item.
    static let sorrelItem = Notification.Name("sorrelItem")
    /// The current space changed, or spaces were added, removed or renamed.
    static let sorrelSpace = Notification.Name("sorrelSpace")
    /// A space's theme changed.
    static let sorrelTheme = Notification.Name("sorrelTheme")
}

// MARK: - Store

final class Store {
    static let profile = Store()
    /// Commands without a view use the most recently focused normal window.
    static var shared: Store { AppDelegate.shared?.main?.store ?? profile }

    private let owner: Store?
    let windowID: UUID
    private var currentSpaceID: UUID
    private var selections: [UUID: UUID]
    var windowState: BrowserWindowState {
        BrowserWindowState(id: windowID, currentSpaceID: currentSpace.id, selections: selections)
    }
    private var sessions: [Store] { AppDelegate.shared?.windows.map { $0.store } ?? [self] }

    init(windowState: BrowserWindowState) {
        owner = Store.profile
        windowID = windowState.id
        currentSpaceID = windowState.currentSpaceID
        selections = windowState.selections
        reconcileSelection()
        if let selected, sessions.contains(where: { $0.displays(selected) }) {
            selections[currentSpace.id] = nil
        }
    }

    func selectedID(in space: Space) -> UUID? { selections[space.id] }

    func displays(_ item: Item) -> Bool {
        visibleTabs.contains { $0 === item }
    }

    /// A live page has one view. Selecting it elsewhere focuses its existing window.
    private func focusExistingWindow(for item: Item) -> Bool {
        guard let other = AppDelegate.shared?.windows.first(where: { $0.store !== self && $0.store.displays(item) }) else { return false }
        AppDelegate.shared.focus(other)
        if other.store.selected !== item { other.store.select(item) }
        return true
    }

    enum Location {
        case favorites
        case pinned(Space, Item?)   // parent folder, or nil for the top level
        case today(Space)
    }

    private var storedState: AppState!
    private(set) var state: AppState {
        get { owner?.state ?? storedState }
        set { if let owner { owner.state = newValue } else { storedState = newValue } }
    }
    private let saver = Debouncer(delay: 0.8)
    private var storedClosedStack: [(url: String, title: String, spaceID: UUID)] = []
    private var closedStack: [(url: String, title: String, spaceID: UUID)] {
        get { owner?.closedStack ?? storedClosedStack }
        set { if let owner { owner.closedStack = newValue } else { storedClosedStack = newValue } }
    }
    /// Direction of the last space switch, for the slide animation. +1 = forward.
    private(set) var lastSwitchDirection = 1

    private var storedArchive: [ArchivedTab] = []
    private(set) var archive: [ArchivedTab] {
        get { owner?.archive ?? storedArchive }
        set { if let owner { owner.archive = newValue } else { storedArchive = newValue } }
    }

    private init() {
        owner = nil
        windowID = UUID()
        currentSpaceID = UUID()
        selections = [:]
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Paths.archive),
           let list = try? dec.decode([ArchivedTab].self, from: data) { archive = list }
        if let data = try? Data(contentsOf: Paths.state),
           let s = try? dec.decode(AppState.self, from: data), !s.spaces.isEmpty {
            state = s
        } else {
            if FileManager.default.fileExists(atPath: Paths.state.path) {
                // Never silently discard a state file we could not read.
                let backup = Paths.support.appendingPathComponent("state.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: Paths.state, to: backup)
            }
            state = Store.seed()
        }
        currentSpaceID = state.currentSpaceID
        selections = Dictionary(uniqueKeysWithValues: state.spaces.compactMap { sp in sp.selectedID.map { (sp.id, $0) } })
        rebuildParents()
    }

    /// A fresh profile: one plain space with the welcome page open. Nothing tailored to any one person;
    /// people add their own spaces (the + by the space icons) or bring them over with Import.
    private static func seed() -> AppState {
        let home = Space(name: "Home", icon: "🏠", theme: Theme.presets[0])
        let welcome = Item(url: "sorrel://welcome", title: "Welcome to Sorrel")
        home.today = [welcome]
        home.selectedID = welcome.id
        return AppState(spaces: [home], favorites: [], currentSpaceID: home.id)
    }

    // MARK: Reading

    var spaces: [Space] { state.spaces }
    var favorites: [Item] { state.favorites }

    var currentSpace: Space {
        state.spaces.first { $0.id == currentSpaceID } ?? state.spaces[0]
    }

    var selected: Item? {
        guard let id = selections[currentSpace.id] else { return nil }
        return item(id: id)
    }

    var sidebarCollapsed: Bool {
        get { state.sidebarCollapsed }
        set { state.sidebarCollapsed = newValue; scheduleSave() }
    }

    var sidebarWidth: Double {
        get { state.sidebarWidth }
        set { state.sidebarWidth = newValue; scheduleSave() }
    }

    /// All tabs (no folders) in a list, depth first.
    func tabs(in items: [Item]) -> [Item] {
        var out: [Item] = []
        for i in items {
            if i.isContainer { out.append(contentsOf: tabs(in: i.children)) } else { out.append(i) }
        }
        return out
    }

    private func find(_ id: UUID, in items: [Item]) -> Item? {
        for i in items {
            if i.id == id { return i }
            if i.isContainer, let hit = find(id, in: i.children) { return hit }
        }
        return nil
    }

    func item(id: UUID) -> Item? {
        if let hit = find(id, in: state.favorites) { return hit }
        for s in state.spaces {
            if let hit = find(id, in: s.pinned) { return hit }
            if let hit = find(id, in: s.today) { return hit }
        }
        return nil
    }

    func space(id: UUID) -> Space? { state.spaces.first { $0.id == id } }

    func space(containing item: Item) -> Space? {
        for s in state.spaces {
            if find(item.id, in: s.pinned) != nil || find(item.id, in: s.today) != nil { return s }
        }
        return nil
    }

    func isFavorite(_ item: Item) -> Bool { state.favorites.contains { $0 === item } }

    func isPinned(_ item: Item) -> Bool {
        state.spaces.contains { find(item.id, in: $0.pinned) != nil }
    }

    /// Every tab the user can cycle through in the current space, in sidebar order.
    var cycleOrder: [Item] {
        state.favorites + tabs(in: currentSpace.pinned) + tabs(in: currentSpace.today)
    }

    /// Every tab anywhere, for searching.
    var allTabs: [(item: Item, space: Space?)] {
        var out: [(Item, Space?)] = state.favorites.map { ($0, nil) }
        for s in state.spaces {
            out.append(contentsOf: tabs(in: s.pinned).map { ($0, s) })
            out.append(contentsOf: tabs(in: s.today).map { ($0, s) })
        }
        return out
    }

    func locate(_ item: Item) -> (Location, Int)? {
        if let i = state.favorites.firstIndex(where: { $0 === item }) { return (.favorites, i) }
        for s in state.spaces {
            if let i = s.today.firstIndex(where: { $0 === item }) { return (.today(s), i) }
            if let i = s.pinned.firstIndex(where: { $0 === item }) { return (.pinned(s, nil), i) }
            // Tabs inside a split view move with it; they have no place of their own.
            if let p = item.parent, p.isFolder, find(p.id, in: s.pinned) != nil,
               let i = p.children.firstIndex(where: { $0 === item }) {
                return (.pinned(s, p), i)
            }
        }
        return nil
    }

    /// Removes stale selections after another window closes/moves a shared tab or space.
    func reconcileSelection() {
        if space(id: currentSpaceID) == nil { currentSpaceID = spaces[0].id }
        for (spaceID, tabID) in selections {
            guard let tab = item(id: tabID), let sp = space(id: spaceID),
                  isFavorite(tab) || space(containing: tab) === sp else {
                selections[spaceID] = nil
                continue
            }
        }
    }

    // MARK: Notifications and saving

    private func post(_ name: Notification.Name, _ object: Any? = nil) {
        let scoped = name == .sorrelSelection
        NotificationCenter.default.post(name: name, object: scoped ? self : object)
    }

    func itemChanged(_ item: Item) {
        post(.sorrelItem, item)
        scheduleSave()
    }

    func scheduleSave() {
        if let owner { owner.scheduleSave(); return }
        saver.schedule { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        if let owner { owner.saveNow(); return }
        if let app = AppDelegate.shared, !app.windows.isEmpty {
            state.windows = app.windows.map { $0.store.windowState }
            state.currentSpaceID = app.main.store.currentSpace.id
            for sp in spaces { sp.selectedID = app.main.store.selectedID(in: sp) }
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: Paths.state, options: .atomic)
    }

    private func rebuildParents() {
        func walk(_ items: [Item], parent: Item?) {
            for i in items {
                i.parent = parent
                if i.isContainer { walk(i.children, parent: i) }
            }
        }
        walk(state.favorites, parent: nil)
        for s in state.spaces {
            walk(s.pinned, parent: nil)
            walk(s.today, parent: nil)
        }
    }

    // MARK: Selection

    func select(_ item: Item?) {
        // Selecting a split view focuses the pane used most recently.
        if let sv = item, sv.isSplit {
            select(sv.children.max { $0.lastActive < $1.lastActive })
            return
        }
        if let item, focusExistingWindow(for: item) { return }
        if let item, let sp = space(containing: item), sp.id != currentSpaceID {
            setCurrentSpace(sp)
        }
        let previous = selected
        let oldWindow = item?.extensionTab.owner
        let oldIndex = oldWindow.flatMap { window in item.flatMap { tab in window.extensionWindow.items.firstIndex { $0 === tab } } }
        item?.browserWindowID = windowID
        selections[currentSpace.id] = item?.id
        if let item, let oldWindow, oldWindow.store !== self, let oldIndex {
            Extensions.shared.controller.didMoveTab(item.extensionTab, from: oldIndex, in: oldWindow.extensionWindow)
        }
        // Every pane of a split view is on screen, so none of them counts as idle.
        if let item, let sv = split(containing: item) {
            let now = Date()
            for t in sv.children where t !== item { t.lastActive = now.addingTimeInterval(-0.001) }
        }
        item?.lastActive = Date()
        Extensions.shared.tabActivated(item, previous: previous)
        // Make sure the folders around the selected tab are open.
        var p = item?.parent
        var opened = false
        while let folder = p {
            if !folder.expanded { folder.expanded = true; opened = true }
            p = folder.parent
        }
        if opened { post(.sorrelStructure) }
        post(.sorrelSelection)
        scheduleSave()
    }

    func selectRelative(_ offset: Int) {
        let order = cycleOrder
        guard !order.isEmpty else { return }
        guard let cur = selected, let idx = order.firstIndex(where: { $0 === cur }) else {
            select(order[0]); return
        }
        select(order[(idx + offset + order.count) % order.count])
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: String, title: String = "", in space: Space? = nil, after: Item? = nil,
                select shouldSelect: Bool = true, page: Page? = nil) -> Item {
        let sp = space ?? currentSpace
        let item = Item(url: url, title: title)
        item.browserWindowID = windowID
        if let page {
            item.page = page
            page.item = item
        }
        if let after = after.map(unit), let idx = sp.today.firstIndex(where: { $0 === after }) {
            sp.today.insert(item, at: idx + 1)
        } else {
            sp.today.insert(item, at: 0)
        }
        post(.sorrelStructure)
        Extensions.shared.tabOpened(item)
        if shouldSelect { select(item) }
        scheduleSave()
        return item
    }

    func close(_ item: Item) {
        if let other = sessions.first(where: { $0 !== self && $0.displays(item) }) { other.close(item); return }
        if item.isSplit {
            for t in item.children { close(t) }
            return
        }
        guard !item.isFolder else { return }
        if let sv = split(containing: item), !isPinned(sv) {
            closePane(item, of: sv)
            return
        }
        let wasSelected = selected === item
        for s in state.spaces where selections[s.id] == item.id && s.id != currentSpaceID {
            selections[s.id] = nil
        }

        if isFavorite(item) || isPinned(item) {
            // Pinned tabs and favorites stay in the sidebar; closing puts them to sleep.
            item.page?.teardown()
            item.page = nil
            if let p = item.pinnedURL { item.url = p }
            post(.sorrelItem, item)
            if wasSelected {
                // In a pinned split view, focus moves to a pane that is still open.
                let sibling = split(containing: item)?.children.first { $0 !== item && $0.page != nil }
                select(sibling ?? mostRecentLoaded(excluding: item))
            }
        } else if let sp = space(containing: item), let idx = sp.today.firstIndex(where: { $0 === item }) {
            if let u = item.url, !u.isEmpty {
                closedStack.append((u, item.title, sp.id))
                if closedStack.count > 50 { closedStack.removeFirst() }
            }
            sp.today.remove(at: idx)
            Extensions.shared.tabClosed(item)
            item.page?.teardown()
            item.page = nil
            post(.sorrelStructure)
            if wasSelected {
                let neighbors = Array(sp.today.dropFirst(idx)) + Array(sp.today.prefix(idx).reversed())
                let neighbor = neighbors.first { candidate in
                    !sessions.contains { session in
                        session !== self && (candidate.isSplit ? candidate.children : [candidate]).contains(where: session.displays)
                    }
                }
                select(neighbor ?? mostRecentLoaded(excluding: item))
            }
        }
        scheduleSave()
    }

    /// Takes a pinned tab out of the sidebar altogether. Reopen Closed Tab brings it back, unpinned.
    func closeAndUnpin(_ item: Item) {
        if item.isSplit { closeSplitAndUnpin(item); return }
        guard !item.isContainer, isPinned(item), let sp = space(containing: item) else { return }
        let wasSelected = selected === item
        let sv = split(containing: item)
        let sibling = sv?.children.filter { $0 !== item && $0.page != nil }.max { $0.lastActive < $1.lastActive }
        if sv != nil {
            guard detachFromSplit(item) != nil else { return }
        } else {
            guard let (loc, idx) = locate(item) else { return }
            remove(at: loc, index: idx)
        }
        for s in state.spaces where selections[s.id] == item.id && s.id != currentSpaceID {
            selections[s.id] = nil
        }
        if let u = item.url, !u.isEmpty {
            closedStack.append((u, item.displayTitle, sp.id))
            if closedStack.count > 50 { closedStack.removeFirst() }
        }
        item.pinnedURL = nil
        Extensions.shared.tabClosed(item)
        item.page?.teardown()
        item.page = nil
        rebuildParents()
        post(.sorrelStructure)
        if wasSelected { select(sibling ?? mostRecentLoaded(excluding: item)) } else { post(.sorrelSelection) }
        scheduleSave()
    }

    /// A whole pinned split view leaves the sidebar. Reopen Closed Tab brings its tabs back one at a time.
    private func closeSplitAndUnpin(_ sv: Item) {
        guard isPinned(sv), let sp = space(containing: sv), let (loc, idx) = locate(sv) else { return }
        let kids = sv.children
        let wasSelected = kids.contains { $0 === selected }
        remove(at: loc, index: idx)
        for t in kids {
            for s in state.spaces where selections[s.id] == t.id && s.id != currentSpaceID { selections[s.id] = nil }
            if let u = t.url, !u.isEmpty {
                closedStack.append((u, t.displayTitle, sp.id))
                if closedStack.count > 50 { closedStack.removeFirst() }
            }
            t.pinnedURL = nil
            Extensions.shared.tabClosed(t)
            t.page?.teardown()
            t.page = nil
        }
        rebuildParents()
        post(.sorrelStructure)
        if wasSelected { select(mostRecentLoaded(excluding: sv)) } else { post(.sorrelSelection) }
        scheduleSave()
    }

    private func mostRecentLoaded(excluding: Item) -> Item? {
        cycleOrder.filter { candidate in
            candidate !== excluding && candidate.page != nil && !sessions.contains { $0 !== self && $0.displays(candidate) }
        }
            .max { $0.lastActive < $1.lastActive }
    }

    func reopenClosed() {
        guard let last = closedStack.popLast() else { return }
        newTab(url: last.url, title: last.title, in: space(id: last.spaceID))
    }

    /// Closes every unpinned tab in a space.
    func clearToday(in space: Space) {
        for item in tabs(in: space.today) { close(item) }
    }

    func rename(_ item: Item, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if item.isFolder {
            if !trimmed.isEmpty { item.title = trimmed }
        } else {
            item.customTitle = (trimmed.isEmpty || trimmed == item.title) ? nil : trimmed
        }
        itemChanged(item)
    }

    // MARK: Sleeping tabs

    /// Unloads tabs nobody has looked at for a while. They stay in the sidebar and reload, with their
    /// history and scroll position, when opened again. Returns how many were put to sleep.
    @discardableResult
    func sleepIdleTabs(olderThanMinutes minutes: Double) -> Int {
        guard minutes > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        return sleepTabs(allTabs.map { $0.item }.filter { $0.lastActive < cutoff })
    }

    /// Puts tabs to sleep now, whatever their age (Free Up Memory, "Put Other Tabs to Sleep"). The tabs on
    /// screen and those `canSleep` protects are skipped. nil = every tab. Returns how many went to sleep.
    @discardableResult
    func sleepTabs(_ candidates: [Item]? = nil) -> Int {
        let visible = sessions.flatMap { $0.visibleTabs }
        var count = 0
        let pool = candidates ?? allTabs.map { $0.item }
        for item in pool where !visible.contains(where: { $0 === item }) && canSleep(item) {
            sleep(item)
            count += 1
        }
        return count
    }

    /// The tab on screen, or every pane of the split view on screen.
    var visibleTabs: [Item] { selected.map { sel in split(containing: sel)?.children ?? [sel] } ?? [] }

    /// Whether a loaded tab can be unloaded without interrupting something: never a call, something playing,
    /// a page mid-load, or an extension's own page.
    func canSleep(_ item: Item) -> Bool {
        guard let wv = item.page?.webView else { return false }
        if item.page?.mediaIsPlaying == true || PictureInPicture.shared.contains(wv) { return false }
        if wv.isLoading || wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none { return false }
        if wv.responds(to: Selector(("_isPlayingAudio"))), (wv.value(forKey: "_isPlayingAudio") as? Bool) == true { return false }
        if let u = wv.url, !(u.scheme ?? "").hasPrefix("http") { return false }
        return true
    }

    /// Unloads one tab, keeping its back/forward history and scroll position for when it wakes.
    private func sleep(_ item: Item) {
        guard let page = item.page else { return }
        item.savedState = page.webView.interactionState
        page.teardown()
        item.page = nil
        post(.sorrelItem, item)
    }

    /// Every tab in a space, in the sidebar's order (pinned, then unpinned), splits opened up.
    func tabs(inSpace space: Space) -> [Item] { tabs(in: space.pinned) + tabs(in: space.today) }

    /// How many tabs are loaded and how many are asleep, across every space and the favorites.
    var tabCounts: (awake: Int, asleep: Int) {
        let all = allTabs.map { $0.item }
        let awake = all.filter { $0.page != nil }.count
        return (awake, all.count - awake)
    }

    // MARK: Archive

    private func saveArchive() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(archive) { try? data.write(to: Paths.archive, options: .atomic) }
        NotificationCenter.default.post(name: .sorrelArchive, object: nil)
    }

    /// Puts away unpinned tabs that have not been used for `hours`. Returns how many were archived.
    /// The tab on screen in each space is never touched, and neither are pinned tabs or favorites.
    @discardableResult
    func archiveStaleTabs(olderThanHours hours: Double) -> Int {
        guard hours > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        var count = 0
        for space in state.spaces {
            // A split view goes only when none of its panes has been used, and none is on screen.
            let stale = space.today.filter { entry in
                (entry.isSplit ? entry.children : [entry]).allSatisfy { tab in tab.lastActive < cutoff && tab.id != selectedID(in: space) && !sessions.contains { $0.displays(tab) } }
            }
            for entry in stale {
                space.today.removeAll { $0 === entry }
                for item in entry.isSplit ? entry.children : [entry] {
                    if let u = item.url, u.hasPrefix("http") {
                        archive.insert(ArchivedTab(url: u, title: item.displayTitle, spaceID: space.id, date: Date()), at: 0)
                    }
                    Extensions.shared.tabClosed(item)
                    item.page?.teardown()
                    item.page = nil
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        if archive.count > 500 { archive = Array(archive.prefix(500)) }
        saveArchive()
        post(.sorrelStructure)
        scheduleSave()
        return count
    }

    func restoreArchived(at index: Int) {
        guard archive.indices.contains(index) else { return }
        let entry = archive.remove(at: index)
        saveArchive()
        newTab(url: entry.url, title: entry.title, in: space(id: entry.spaceID))
    }

    /// Forgets one archived tab without reopening it (Library ▸ Archive).
    func removeArchived(at index: Int) {
        guard archive.indices.contains(index) else { return }
        archive.remove(at: index)
        saveArchive()
    }

    func clearArchive() {
        archive = []
        saveArchive()
    }

    /// Forgets archived tabs put away at or after `date` (Clear Browsing Data with a time range).
    func clearArchive(since date: Date) {
        let before = archive.count
        archive.removeAll { $0.date >= date }
        if archive.count != before { saveArchive() }
    }

    /// Forgets archived tabs from one website (Forget This Site).
    func clearArchive(site: String) {
        let before = archive.count
        archive.removeAll { Site.key(URL(string: $0.url)?.host) == site }
        if archive.count != before { saveArchive() }
    }

    // MARK: Moving

    private func count(at loc: Location) -> Int {
        switch loc {
        case .favorites: return state.favorites.count
        case .pinned(let s, let parent): return parent?.children.count ?? s.pinned.count
        case .today(let s): return s.today.count
        }
    }

    private func remove(at loc: Location, index: Int) {
        switch loc {
        case .favorites: state.favorites.remove(at: index)
        case .pinned(let s, let parent):
            if let parent { parent.children.remove(at: index) } else { s.pinned.remove(at: index) }
        case .today(let s): s.today.remove(at: index)
        }
    }

    private func insert(_ item: Item, at loc: Location, index: Int) {
        switch loc {
        case .favorites: state.favorites.insert(item, at: index)
        case .pinned(let s, let parent):
            if let parent { parent.children.insert(item, at: index) } else { s.pinned.insert(item, at: index) }
        case .today(let s): s.today.insert(item, at: index)
        }
    }

    private func same(_ a: Location, _ b: Location) -> Bool {
        switch (a, b) {
        case (.favorites, .favorites): return true
        case (.today(let x), .today(let y)): return x === y
        case (.pinned(let x, let px), .pinned(let y, let py)): return x === y && px === py
        default: return false
        }
    }

    /// Moves an item. `index` nil means "at the end".
    func move(_ item: Item, to loc: Location, index: Int? = nil) {
        guard let (oldLoc, oldIdx) = locate(item) else { return }
        // Only folders take items inside them.
        if case .pinned(_, let parent) = loc, let parent, !parent.isFolder { return }
        if item.isSplit, case .favorites = loc { return }
        if item.isFolder {
            switch loc {
            case .favorites, .today: return
            case .pinned(_, let parent):
                if let parent, parent === item || parent.isDescendant(of: item) { return }
            }
        }
        remove(at: oldLoc, index: oldIdx)
        var idx = index ?? count(at: loc)
        if same(oldLoc, loc), oldIdx < idx { idx -= 1 }
        idx = max(0, min(idx, count(at: loc)))
        insert(item, at: loc, index: idx)

        if !item.isFolder {
            for t in item.isSplit ? item.children : [item] {
                switch loc {
                case .today: t.pinnedURL = nil
                case .favorites, .pinned: if t.pinnedURL == nil { t.pinnedURL = t.url }
                }
            }
        }
        rebuildParents()
        post(.sorrelStructure)
        scheduleSave()
    }

    func togglePin(_ item: Item) {
        let item = unit(item)   // a tab in a split view pins the whole split
        guard !item.isFolder, !isFavorite(item), let sp = space(containing: item) else { return }
        if isPinned(item) {
            move(item, to: .today(sp), index: 0)
        } else {
            move(item, to: .pinned(sp, nil))
        }
    }

    func toggleFavorite(_ item: Item) {
        guard !item.isContainer else { return }
        // Favorites are single tabs, so a tab leaves its split view first.
        if split(containing: item) != nil { removeFromSplit(item) }
        if isFavorite(item) {
            move(item, to: .pinned(currentSpace, nil))
        } else {
            move(item, to: .favorites)
        }
    }

    func moveToSpace(_ item: Item, _ target: Space) {
        let item = unit(item)
        guard let source = space(containing: item), source !== target else { return }
        let wasPinned = isPinned(item)
        if selections[source.id] == item.id || item.children.contains(where: { $0.id == selections[source.id] }) {
            selections[source.id] = nil
            if source === currentSpace { post(.sorrelSelection) }
        }
        if wasPinned { move(item, to: .pinned(target, nil)) } else { move(item, to: .today(target), index: 0) }
    }

    // MARK: Split view

    /// The split view a tab is shown in, if any.
    func split(containing item: Item) -> Item? {
        guard let p = item.parent, p.isSplit else { return nil }
        return p
    }

    /// What moves, pins and archives as one: the split view a tab belongs to, or the tab itself.
    func unit(_ item: Item) -> Item { split(containing: item) ?? item }

    /// Can `item` be shown in a split view?
    func canSplit(_ item: Item) -> Bool { !item.isContainer && !isFavorite(item) && space(containing: item) != nil }

    /// Puts two tabs side by side, where `base` is now. If `base` is already in a split view, `other` joins it.
    /// `otherFirst` puts `other` before `base` (on the left, or on top). Returns the split view, or nil if
    /// either tab can't be split (favorites stay single tabs) or the split view is full.
    @discardableResult
    func makeSplit(_ base: Item, with other: Item, otherFirst: Bool = false, stacked: Bool? = nil,
                   focus: Item? = nil) -> Item? {
        guard base !== other, canSplit(base), canSplit(other),
              !sessions.contains(where: { $0 !== self && ($0.displays(base) || $0.displays(other)) }) else { return nil }
        if let existing = split(containing: base) {
            if existing === split(containing: other) {
                if let s = stacked { existing.split?.stacked = s }
                select(focus ?? other)
                return existing
            }
            guard existing.children.count < SplitLayout.maxPanes else { return nil }
            if split(containing: other) != nil { detachFromSplit(other) } else if !detachSingle(other) { return nil }
            let at = existing.children.firstIndex { $0 === base } ?? existing.children.count - 1
            existing.children.insert(other, at: otherFirst ? at : at + 1)
            existing.split?.fractions = []
            if let s = stacked { existing.split?.stacked = s }
            finishSplitChange(existing, focus: focus ?? other)
            return existing
        }
        // `other` leaves wherever it was first, so `base`'s place is read after that.
        if split(containing: other) != nil { detachFromSplit(other) } else if !detachSingle(other) { return nil }
        guard let (loc, idx) = locate(base) else { return nil }
        let sv = Item()
        sv.split = SplitLayout(stacked: stacked ?? false)
        sv.lastActive = Date()
        remove(at: loc, index: idx)
        sv.children = otherFirst ? [other, base] : [base, other]
        insert(sv, at: loc, index: idx)
        finishSplitChange(sv, focus: focus ?? other)
        return sv
    }

    /// Takes a tab that is not in a split view out of its list. Returns false if it couldn't be found.
    private func detachSingle(_ item: Item) -> Bool {
        guard let (loc, idx) = locate(item) else { return false }
        if selected !== item {
            for s in state.spaces where selections[s.id] == item.id { selections[s.id] = nil }
        }
        remove(at: loc, index: idx)
        return true
    }

    private func finishSplitChange(_ sv: Item, focus: Item?) {
        let pinned = isPinned(sv)
        for t in sv.children {
            if pinned { if t.pinnedURL == nil { t.pinnedURL = t.url } } else { t.pinnedURL = nil }
        }
        rebuildParents()
        post(.sorrelStructure)
        if let focus { select(focus) } else { post(.sorrelSelection) }
        scheduleSave()
    }

    /// Takes a tab out of its split view. If only one tab is left, the split view becomes that tab.
    /// Returns where the split view (or the tab left behind) now sits.
    @discardableResult
    private func detachFromSplit(_ item: Item) -> (Location, Int)? {
        guard let sv = split(containing: item), let (loc, idx) = locate(sv) else { return nil }
        sv.children.removeAll { $0 === item }
        sv.split?.fractions = []
        item.parent = nil
        if sv.children.count == 1 {
            let last = sv.children[0]
            sv.children = []
            remove(at: loc, index: idx)
            insert(last, at: loc, index: idx)
        }
        rebuildParents()
        return (loc, idx)
    }

    /// "Remove from Split View": the tab becomes a tab of its own, right after the split view.
    func removeFromSplit(_ item: Item) {
        guard let sv = split(containing: item) else { return }
        let wasSelected = selected === item
        let sibling = sv.children.filter { $0 !== item }.max { $0.lastActive < $1.lastActive }
        guard let (loc, idx) = detachFromSplit(item) else { return }
        insert(item, at: loc, index: min(idx + 1, count(at: loc)))
        switch loc {
        case .today: item.pinnedURL = nil
        case .favorites, .pinned: if item.pinnedURL == nil { item.pinnedURL = item.url }
        }
        rebuildParents()
        post(.sorrelStructure)
        // Focus stays with the tabs that are still side by side.
        if wasSelected { select(sibling) } else { post(.sorrelSelection) }
        scheduleSave()
    }

    /// Closes one pane of an unpinned split view.
    private func closePane(_ item: Item, of sv: Item) {
        let wasSelected = selected === item
        let sibling = sv.children.filter { $0 !== item }.max { $0.lastActive < $1.lastActive }
        let home = space(containing: sv)
        detachFromSplit(item)
        if let u = item.url, !u.isEmpty, let home {
            closedStack.append((u, item.title, home.id))
            if closedStack.count > 50 { closedStack.removeFirst() }
        }
        Extensions.shared.tabClosed(item)
        item.page?.teardown()
        item.page = nil
        post(.sorrelStructure)
        if wasSelected { select(sibling) } else { post(.sorrelSelection) }
        scheduleSave()
    }

    /// "Separate": every tab of the split view goes back to being a tab of its own, in the same place.
    func unsplit(_ sv: Item) {
        guard sv.isSplit, let (loc, idx) = locate(sv) else { return }
        let kids = sv.children
        sv.children = []
        remove(at: loc, index: idx)
        for (offset, kid) in kids.enumerated() { insert(kid, at: loc, index: idx + offset) }
        rebuildParents()
        post(.sorrelStructure)
        post(.sorrelSelection)
        scheduleSave()
    }

    func setSplitStacked(_ sv: Item, _ stacked: Bool) {
        guard sv.isSplit else { return }
        sv.split?.stacked = stacked
        post(.sorrelSelection)
        scheduleSave()
    }

    func setSplitFractions(_ sv: Item, _ fractions: [Double]) {
        guard sv.isSplit, fractions.count == sv.children.count else { return }
        sv.split?.fractions = fractions
        scheduleSave()
    }

    /// Moves the first pane to the end (with two panes, they swap places).
    func rotatePanes(_ sv: Item) {
        guard sv.isSplit, sv.children.count > 1 else { return }
        sv.children.append(sv.children.removeFirst())
        if let f = sv.split?.fractions, f.count == sv.children.count {
            sv.split?.fractions = Array(f.dropFirst()) + [f[0]]
        }
        post(.sorrelStructure)
        post(.sorrelSelection)
        scheduleSave()
    }

    /// Moves focus to the next (+1) or previous (-1) pane of the split view on screen.
    func focusPane(offset: Int) {
        guard let sel = selected, let sv = split(containing: sel),
              let idx = sv.children.firstIndex(where: { $0 === sel }) else { return }
        let n = sv.children.count
        select(sv.children[(idx + offset + n) % n])
    }

    // MARK: Folders

    @discardableResult
    func addFolder(named name: String = "New Folder", in space: Space? = nil, parent: Item? = nil) -> Item {
        let sp = space ?? currentSpace
        let folder = Item.folder(named: name)
        if let parent { parent.children.append(folder); parent.expanded = true } else { sp.pinned.append(folder) }
        rebuildParents()
        post(.sorrelStructure)
        scheduleSave()
        return folder
    }

    /// Removes a folder but keeps what was inside it, in the folder's place.
    func ungroup(_ folder: Item) {
        guard folder.isFolder, let (loc, idx) = locate(folder) else { return }
        let kids = folder.children
        folder.children = []
        remove(at: loc, index: idx)
        for (offset, kid) in kids.enumerated() { insert(kid, at: loc, index: idx + offset) }
        rebuildParents()
        post(.sorrelStructure)
        scheduleSave()
    }

    func setExpanded(_ folder: Item, _ expanded: Bool) {
        folder.expanded = expanded
        scheduleSave()
    }

    // MARK: Spaces

    private func setCurrentSpace(_ space: Space) {
        let oldIdx = state.spaces.firstIndex { $0.id == currentSpaceID } ?? 0
        let newIdx = state.spaces.firstIndex { $0 === space } ?? 0
        lastSwitchDirection = newIdx >= oldIdx ? 1 : -1
        currentSpaceID = space.id
        if let selected, sessions.contains(where: { $0 !== self && $0.displays(selected) }) {
            selections[space.id] = nil
        }
        NotificationCenter.default.post(name: .sorrelSpace, object: self)
    }

    func switchSpace(to space: Space) {
        guard space.id != currentSpaceID else { return }
        setCurrentSpace(space)
        post(.sorrelSelection)
        scheduleSave()
    }

    func switchSpace(offset: Int) {
        guard let idx = state.spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        let next = idx + offset
        guard next >= 0, next < state.spaces.count else { return }
        switchSpace(to: state.spaces[next])
    }

    @discardableResult
    func addSpace(name: String = "New Space", icon: String = "✨", theme: Theme? = nil) -> Space {
        let t = theme ?? Theme.presets[state.spaces.count % Theme.presets.count]
        let sp = Space(name: name, icon: icon, theme: t)
        state.spaces.append(sp)
        switchSpace(to: sp)
        post(.sorrelSpace)
        return sp
    }

    func removeSpace(_ space: Space) {
        guard state.spaces.count > 1, let idx = state.spaces.firstIndex(where: { $0 === space }) else { return }
        for t in tabs(in: space.pinned) + tabs(in: space.today) {
            t.page?.teardown()
            t.page = nil
        }
        let wasCurrent = space.id == currentSpaceID
        state.spaces.remove(at: idx)
        if wasCurrent {
            currentSpaceID = state.spaces[max(0, idx - 1)].id
            post(.sorrelSpace)
            post(.sorrelSelection)
        } else {
            post(.sorrelSpace)
        }
        scheduleSave()
    }

    func updateSpace(_ space: Space, name: String? = nil, icon: String? = nil) {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { space.name = name }
        if let icon, !icon.isEmpty { space.icon = icon }
        post(.sorrelSpace)
        scheduleSave()
    }

    func setTheme(_ theme: Theme, for space: Space) {
        space.theme = theme
        post(.sorrelTheme)
        scheduleSave()
    }

    /// Browser import (Importer.swift): adds the new spaces and favorites in one step. Existing spaces have
    /// already had their imported tabs appended; this re-links parents and tells the sidebar once.
    func absorbImport(spaces: [Space], favorites: [Item]) {
        state.spaces.append(contentsOf: spaces)
        state.favorites.append(contentsOf: favorites)
        rebuildParents()
        post(.sorrelSpace)
        post(.sorrelStructure)
        saveNow()
    }

    /// Gives a space its own cookies and logins, or returns it to the shared set.
    func setSeparateLogins(_ separate: Bool, for space: Space) {
        space.profileID = separate ? (space.profileID ?? UUID()) : nil
        // Pages keep the storage they were created with, so reload them from scratch.
        for t in tabs(in: space.pinned) + tabs(in: space.today) {
            t.page?.teardown()
            t.page = nil
        }
        post(.sorrelSpace)
        post(.sorrelSelection)
        scheduleSave()
    }
}
