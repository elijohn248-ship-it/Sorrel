import AppKit
import WebKit
import Darwin
import CoreFoundation

// Clearing what browsing leaves behind, measuring it, and freeing memory: the engine behind Clear Browsing Data
// (ClearDataPanel.swift), Settings ▸ Memory & Storage, Library ▸ History and Free Up Memory. WebKit already
// compresses, purges and suspends background pages on its own; this is the "do it now" button on top.

enum Cleanup {
    /// The time ranges Clear Browsing Data offers, as in Firefox and Zen.
    enum Range: Int, CaseIterable {
        case hour, day, week, month, all

        var title: String {
            ["Last hour", "Last 24 hours", "Last 7 days", "Last 4 weeks", "All time"][rawValue]
        }

        var since: Date {
            let now = Date()
            switch self {
            case .hour: return now.addingTimeInterval(-3600)
            case .day: return now.addingTimeInterval(-86400)
            case .week: return now.addingTimeInterval(-7 * 86400)
            case .month: return now.addingTimeInterval(-28 * 86400)
            case .all: return .distantPast
            }
        }
    }

    /// What to clear.
    struct Kinds: OptionSet {
        let rawValue: Int
        /// Visited pages, the downloads list and archived tabs.
        static let history = Kinds(rawValue: 1)
        /// Cookies, local storage, databases, service workers: everything that keeps you signed in.
        static let siteData = Kinds(rawValue: 2)
        /// Cached images and files, and saved site icons. Pages just load them again.
        static let cache = Kinds(rawValue: 4)
    }

    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                          WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
    static var siteDataTypes: Set<String> { WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes) }

    /// Every store a normal tab can use: the shared logins, plus each space that keeps its own.
    /// Private windows are left out: their store lives only as long as the window.
    static var stores: [WKWebsiteDataStore] {
        var out = [Engine.store(for: nil)]
        for space in Store.shared.spaces {
            guard let id = space.profileID else { continue }
            let s = Engine.store(for: id)
            if !out.contains(where: { $0 === s }) { out.append(s) }
        }
        return out
    }

    // MARK: Clearing

    /// Clears the chosen kinds of data from `since` until now, in every space's store.
    static func clear(_ kinds: Kinds, since: Date, completion: @escaping () -> Void) {
        if kinds.contains(.history) {
            if since == .distantPast {
                History.shared.clear()
                Engine.shared.clearFinishedDownloads()
                Store.shared.clearArchive()
            } else {
                History.shared.remove(since: since)
                for r in Engine.shared.downloads where r.state != .running && (r.finished ?? r.started) >= since {
                    Engine.shared.removeDownload(r)
                }
                Store.shared.clearArchive(since: since)
            }
        }
        var types = Set<String>()
        if kinds.contains(.siteData) { types.formUnion(siteDataTypes) }
        if kinds.contains(.cache) {
            types.formUnion(cacheTypes)
            FaviconStore.shared.forget(since: since)
            URLCache.shared.removeAllCachedResponses()
        }
        guard !types.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for s in stores {
            group.enter()
            s.removeData(ofTypes: types, modifiedSince: since) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    /// Firefox's "Forget About This Site": its history, archived tabs, cookies and site data, cached files,
    /// icon and zoom, in every space. Open tabs stay open.
    static func forget(site: String, completion: @escaping () -> Void) {
        History.shared.remove(site: site)
        Store.shared.clearArchive(site: site)
        FaviconStore.shared.forget(site: site)
        ZoomStore.shared.forget(site: site)
        fetchSites { all in
            remove(all.filter { Site.key($0.name) == site }, completion: completion)
        }
    }

    /// Automatic rules from Settings ▸ Memory & Storage, run at launch and every few minutes.
    static func applyAutomaticRules() {
        let days = Settings.current.removeHistoryAfterDays
        guard days > 0 else { return }
        History.shared.remove(olderThan: Date().addingTimeInterval(-days * 86400))
    }

    /// Settings ▸ Memory & Storage ▸ "Empty the cache when Birch quits". Calls back on the main thread, at the
    /// latest after a few seconds so a stuck WebKit can never hold up quitting. Answers through the run loop, not
    /// the main dispatch queue: while the app waits in "terminate later", AppKit runs a nested run loop where
    /// main-queue blocks don't run (same as Updater.installOnQuit).
    static func emptyCacheBeforeQuitting(then done: @escaping () -> Void) {
        var finished = false
        let finish = {
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                guard !finished else { return }
                finished = true
                if isQuietTest { FileHandle.standardError.write("clean: cache emptied before quitting\n".data(using: .utf8)!) }
                done()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        FaviconStore.shared.forget(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        let group = DispatchGroup()
        for s in stores {
            group.enter()
            s.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast) { group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated), execute: finish)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3, execute: finish)
    }

    // MARK: Websites with stored data

    /// One website's stored data, gathered from every store.
    struct SiteData {
        let name: String
        var types: Set<String>
        var records: [(store: WKWebsiteDataStore, record: WKWebsiteDataRecord)]

        var hasCookies: Bool { types.contains(WKWebsiteDataTypeCookies) }

        /// "Cookies, Local storage, Cache" for the site list.
        var summary: String {
            var parts: [String] = []
            if types.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
            if !types.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage]) { parts.append("Local storage") }
            if !types.isDisjoint(with: [WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem]) { parts.append("Databases") }
            if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Offline data") }
            if !types.isDisjoint(with: Cleanup.cacheTypes) { parts.append("Cache") }
            if parts.isEmpty { parts.append("Other data") }
            return parts.joined(separator: ", ")
        }
    }

    /// Every website that has stored something, merged across spaces, sorted by name.
    static func fetchSites(completion: @escaping ([SiteData]) -> Void) {
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let group = DispatchGroup()
        var found: [String: SiteData] = [:]
        for s in stores {
            group.enter()
            s.fetchDataRecords(ofTypes: all) { records in
                for r in records {
                    var entry = found[r.displayName] ?? SiteData(name: r.displayName, types: [], records: [])
                    entry.types.formUnion(r.dataTypes)
                    entry.records.append((s, r))
                    found[r.displayName] = entry
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    /// Removes everything the given websites stored, in every store they used.
    static func remove(_ sites: [SiteData], completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for site in sites {
            for (store, record) in site.records {
                group.enter()
                store.removeData(ofTypes: record.dataTypes, for: [record]) { group.leave() }
            }
        }
        group.notify(queue: .main, execute: completion)
    }

    // MARK: Measuring storage

    struct Usage {
        var historyPages = 0
        var historyBytes: Int64 = 0
        var cacheBytes: Int64 = 0
        var siteDataBytes: Int64 = 0
        var iconBytes: Int64 = 0
        var sites = 0
        var sitesWithCookies = 0
    }

    /// What Sorrel's stored data takes on disk. Folder sizes are summed off the main thread.
    static func measure(completion: @escaping (Usage) -> Void) {
        var usage = Usage()
        usage.historyPages = History.shared.count
        usage.historyBytes = History.shared.fileSize
        let (cacheFolders, dataFolders) = webKitFolders
        let icons = Paths.favicons
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let cache = cacheFolders.reduce(Int64(0)) { $0 + size(of: $1) }
            let data = dataFolders.reduce(Int64(0)) { $0 + size(of: $1) }
            let iconBytes = size(of: icons)
            DispatchQueue.main.async {
                usage.cacheBytes = cache
                usage.siteDataBytes = data
                usage.iconBytes = iconBytes
                group.leave()
            }
        }
        group.enter()
        fetchSites { sites in
            usage.sites = sites.count
            usage.sitesWithCookies = sites.filter(\.hasCookies).count
            group.leave()
        }
        group.notify(queue: .main) { completion(usage) }
    }

    /// Where WebKit keeps the cache and the site data. Inside the sandbox the bundle-id folder is left out
    /// (CLAUDE.md ▸ Sandbox). Extensions' storage and the blocker's rule lists are not counted.
    private static var webKitFolders: (cache: [URL], data: [URL]) {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        if Sandbox.isOn {
            return ([lib.appendingPathComponent("Caches/WebKit")],
                    [lib.appendingPathComponent("WebKit/WebsiteData"), lib.appendingPathComponent("WebKit/WebsiteDataStore"),
                     lib.appendingPathComponent("Cookies")])
        }
        let id = Bundle.main.bundleIdentifier ?? "app.sorrel.browser"
        return ([lib.appendingPathComponent("Caches/\(id)/WebKit")],
                [lib.appendingPathComponent("WebKit/\(id)/WebsiteData"), lib.appendingPathComponent("WebKit/\(id)/WebsiteDataStore"),
                 lib.appendingPathComponent("HTTPStorages/\(id)"), lib.appendingPathComponent("HTTPStorages/\(id).binarycookies")])
    }

    private static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
            return Int64(v.totalFileAllocatedSize ?? 0)
        }
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in walk {
            total += Int64((try? f.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func bytes(_ n: Int64) -> String {
        n <= 0 ? "Zero KB" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Memory sizes count in memory units, so a 16 GB Mac reads "16 GB".
    static func memory(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory) }

    // MARK: Memory

    /// Memory in use on the whole Mac, as Activity Monitor's "Memory Used" counts it (app memory + wired +
    /// compressed). The sandbox won't let Sorrel read its web processes one by one, so freeing is measured here.
    static func memoryInUse() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))
        let used = (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    /// Reclaim idle background pages when macOS needs memory, rather than waiting for the normal timer.
    /// Keep recently used pages warm: five minutes at warning, one minute at critical. The user's shorter
    /// sleep interval still wins, and "Never" still disables automatic sleeping. Store applies the same
    /// visible-pane, playback, capture, loading and extension protections as ordinary idle sleeping.
    @discardableResult
    static func relieveMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) -> Int {
        guard event.contains(.warning) || event.contains(.critical) else { return 0 }
        FaviconStore.shared.trimMemory()
        URLCache.shared.removeAllCachedResponses()
        let configured = Settings.current.sleepTabsAfterMinutes
        guard configured > 0 else { return 0 }
        let minutes = min(configured, event.contains(.critical) ? 1 : 5)
        return Store.profile.sleepIdleTabs(olderThanMinutes: minutes)
    }

    /// Zen's "unload all tabs", plus emptying the caches WebKit keeps in memory: every tab not on screen goes
    /// to sleep (tabs playing sound, in a call or loading are left alone; they all wake where they were).
    /// Calls back with how many tabs slept and how far the Mac's memory use fell once their processes exited
    /// (nil when it didn't measurably fall: other apps move the number too).
    static func freeMemory(completion: @escaping (_ slept: Int, _ freed: UInt64?) -> Void) {
        let before = memoryInUse()?.used
        let slept = Store.shared.sleepTabs()
        FaviconStore.shared.trimMemory()
        URLCache.shared.removeAllCachedResponses()
        let group = DispatchGroup()
        for s in stores {
            group.enter()
            s.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) { group.leave() }
        }
        group.notify(queue: .main) {
            // Give the slept tabs' processes a moment to exit before measuring again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard slept > 0, let before, let after = memoryInUse()?.used, before > after + 20_000_000 else {
                    completion(slept, nil)
                    return
                }
                completion(slept, before - after)
            }
        }
    }

    /// "4 tabs asleep · about 820 MB freed" for the toast.
    static func freedMessage(slept: Int, freed: UInt64?) -> String {
        guard slept > 0 else { return "Nothing to unload: the other tabs are already asleep" }
        let tabs = "\(slept) tab\(slept == 1 ? "" : "s") asleep"
        guard let freed, freed > 0 else { return tabs }
        return tabs + " · about " + memory(freed) + " of memory freed"
    }
}
