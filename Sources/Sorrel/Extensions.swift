import AppKit
import WebKit

extension Notification.Name {
    /// The list of extensions, or one's state, changed.
    static let sorrelExtensions = Notification.Name("sorrelExtensions")
    /// An extension changed its toolbar button (icon, badge, label or enabled state). `object` is the ExtensionEntry, or nil.
    static let sorrelExtensionAction = Notification.Name("sorrelExtensionAction")
}

/// One extension Sorrel knows about, loaded or not.
final class ExtensionEntry {
    enum Source {
        case bundled(URL)                         // ships inside Sorrel
        case safariApp(appex: URL, app: String)   // a Safari extension already installed on this Mac
        case folder(URL)                          // added by the user
    }

    let id: String
    let source: Source
    var name: String
    var version = ""
    var summary = ""
    var icon: NSImage?
    var context: WKWebExtensionContext?
    var error: String?
    var isLoading = false

    init(id: String, source: Source, name: String) {
        self.id = id
        self.source = source
        self.name = name
    }

    var isBundled: Bool { if case .bundled = source { return true } else { return false } }

    /// For an extension from the Chrome Web Store, its 32-letter store id.
    var chromeID: String? {
        guard case .folder(let url) = source, url.lastPathComponent.hasPrefix("chrome-") else { return nil }
        let id = String(url.lastPathComponent.dropFirst("chrome-".count))
        return id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil ? id : nil
    }

    /// Websites this extension says it exchanges messages with (from a Chrome extension's manifest).
    var companionSites: [WKWebExtension.MatchPattern] = []
    var isLoaded: Bool { context != nil }

    var sourceText: String {
        switch source {
        case .bundled: return "Included with Sorrel"
        case .safariApp(_, let app): return "From \(app)"
        case .folder(let url):
            return url.lastPathComponent.hasPrefix("chrome-") ? "From the Chrome Web Store" : "Added by you"
        }
    }
}

// MARK: - How extensions see Sorrel's tabs and window

/// A tab, as extensions see it. One per Item, kept for the Item's lifetime so WebKit can track it.
final class ExtensionTab: NSObject {
    weak var item: Item?
    init(item: Item) { self.item = item }
}

extension ExtensionTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        Store.shared.allTabs.firstIndex { $0.item === item } ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { item?.page?.webView }
    func title(for context: WKWebExtensionContext) -> String? { item?.displayTitle }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        guard let item else { return false }
        return Store.shared.isPinned(item) || Store.shared.isFavorite(item)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        item?.page?.webView.url ?? item?.url.flatMap { URL(string: $0) }
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(item?.page?.webView.isLoading ?? false)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool { item != nil && Store.shared.selected === item }
    func size(for context: WKWebExtensionContext) -> CGSize { item?.page?.webView.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(item?.page?.webView.pageZoom ?? 1) }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let item {
            item.url = url.absoluteString
            Engine.shared.load(url.absoluteString, in: Engine.shared.ensurePage(for: item))
        }
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if fromOrigin { item?.page?.webView.reloadFromOrigin() } else { item?.page?.webView.reload() }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        item?.page?.webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        item?.page?.webView.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let item { Store.shared.select(item) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let item { Store.shared.close(item) }
        completionHandler(nil)
    }
}

/// Sorrel's main window, as extensions see it. Tabs from every space belong to it.
final class ExtensionWindow: NSObject {}

extension ExtensionWindow: WKWebExtensionWindow {
    private var window: NSWindow? { AppDelegate.shared.main?.window }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        Store.shared.allTabs.map { $0.item.extensionTab }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        Store.shared.selected?.extensionTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return window.isMiniaturized ? .minimized : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .zero }
    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        AppDelegate.shared.showMainWindow()
        completionHandler(nil)
    }
}

// MARK: - Extensions

/// Hosts web extensions (the same kind Safari runs) and ships uBlock Origin Lite turned on.
final class Extensions: NSObject {
    static let shared = Extensions()
    static let blockerID = "ublock-origin-lite"

    let controller: WKWebExtensionController
    let window = ExtensionWindow()
    private(set) var entries: [ExtensionEntry] = []
    private weak var openPopover: NSPopover?


    var folder: URL {
        let dir = Paths.support.appendingPathComponent("Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private override init() {
        // Test runs (SORREL_HOME) keep extension data in memory so the real profile is never touched.
        let testing = !(ProcessInfo.processInfo.environment["SORREL_HOME"] ?? "").isEmpty
        var config: WKWebExtensionController.Configuration = testing ? .nonPersistent() : .default()
        // SORREL_EXT_STORE (testing): a named persistent store, to measure second-launch behaviour.
        if testing, let id = ProcessInfo.processInfo.environment["SORREL_EXT_STORE"].flatMap({ UUID(uuidString: $0) }) {
            config = WKWebExtensionController.Configuration(identifier: id)
        }
        controller = WKWebExtensionController(configuration: config)
        super.init()
        controller.delegate = self
    }

    private func changed() {
        NotificationCenter.default.post(name: .sorrelExtensions, object: nil)
    }

    /// True while uBlock Origin Lite is loaded.
    var hasActiveBlocker: Bool { entries.contains { $0.id == Self.blockerID && $0.isLoaded } }

    /// uBlock Origin Lite needs a moment after loading before its rules are in force (about 15 to 20 seconds
    /// the very first time, while WebKit compiles them; almost none afterwards). Sorrel's built-in lists
    /// keep blocking until this moment, then step aside so the two never fight over a page.
    private var blockerTakeoverAt: Date?
    static let blockerHandoverDelay: TimeInterval = 25

    /// True once uBlock Origin Lite has taken over blocking on ordinary pages.
    var blockerInCharge: Bool {
        guard hasActiveBlocker, let at = blockerTakeoverAt else { return false }
        return Date() >= at
    }
    var blocker: ExtensionEntry? { entries.first { $0.id == Self.blockerID } }
    var loaded: [ExtensionEntry] { entries.filter { $0.isLoaded } }
    var isPopupOpen: Bool { openPopover?.isShown ?? false }

    func isEnabled(_ entry: ExtensionEntry) -> Bool {
        Settings.current.extensionStates[entry.id] ?? entry.isBundled
    }

    // MARK: Finding extensions

    private static func slug(_ text: String) -> String {
        let s = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }

    private var blockerHome: URL { Paths.support.appendingPathComponent("BundledExtensions", isDirectory: true) }

    private static func manifestVersion(at dir: URL) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version"] as? String
    }

    /// Compares dotted versions like 2026.1110.1816 number by number.
    static func version(_ a: String, isNewerThan b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// WebKit refuses (by crashing) to load an extension that sits inside the app's own bundle, so the
    /// copy of uBlock Origin Lite that ships with Sorrel is unpacked into the support folder and run from there.
    /// Whichever is newest wins: the copy shipped in this build, or one fetched by the updater.
    private func installedBundledBlocker() -> URL? {
        let fm = FileManager.default
        var bundled = Bundle.main.resourceURL?.appendingPathComponent("extensions/ubol", isDirectory: true)
        if let override = ProcessInfo.processInfo.environment["SORREL_UBOL_SRC"] {   // testing: try a different copy
            bundled = URL(fileURLWithPath: override, isDirectory: true)
        }
        try? fm.createDirectory(at: blockerHome, withIntermediateDirectories: true)

        var installed: [(version: String, url: URL)] = []
        for dir in (try? fm.contentsOfDirectory(at: blockerHome, includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix("ubol-") && !dir.lastPathComponent.hasSuffix(".partial") {
            if let v = Self.manifestVersion(at: dir) { installed.append((v, dir)) }
        }
        installed.sort { Self.version($0.version, isNewerThan: $1.version) }

        if let source = bundled, let shipped = Self.manifestVersion(at: source),
           installed.first.map({ Self.version(shipped, isNewerThan: $0.version) }) ?? true {
            let dest = blockerHome.appendingPathComponent("ubol-\(shipped)", isDirectory: true)
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: source, to: dest)) != nil { installed.insert((shipped, dest), at: 0) }
        }
        // Keep only the newest copy.
        for old in installed.dropFirst() { try? fm.removeItem(at: old.url) }
        return installed.first?.url
    }

    /// Looks for a newer official uBlock Origin Lite release and fetches it. It is used from the next launch.
    func updateBlockerIfNeeded(force: Bool = false, completion: ((String) -> Void)? = nil) {
        guard force || Settings.current.autoUpdateBlocker, let current = blocker,
              case .bundled(let dir) = current.source, let have = Self.manifestVersion(at: dir) else {
            completion?("uBlock Origin Lite isn’t installed")
            return
        }
        let stamp = blockerHome.appendingPathComponent("last-update-check")
        if !force, let date = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 3 * 86400 {
            return
        }
        try? Data().write(to: stamp)

        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest")!, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, _, _ in
            func finish(_ message: String) { DispatchQueue.main.async { completion?(message) } }
            guard let data, let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = release["tag_name"] as? String, let assets = release["assets"] as? [[String: Any]] else {
                finish("Couldn’t check for a uBlock Origin Lite update")
                return
            }
            guard Self.version(tag, isNewerThan: have) else {
                finish("uBlock Origin Lite is up to date (\(have))")
                return
            }
            // Only the official release location is accepted.
            let prefix = "https://github.com/uBlockOrigin/uBOL-home/releases/download/"
            guard let link = assets.compactMap({ $0["browser_download_url"] as? String })
                    .first(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".safari.zip") }), let url = URL(string: link) else {
                finish("The new uBlock Origin Lite release has no build Sorrel can use yet")
                return
            }
            session.downloadTask(with: url) { file, response, _ in
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    finish("Couldn’t download the uBlock Origin Lite update")
                    return
                }
                let fm = FileManager.default
                let partial = self.blockerHome.appendingPathComponent("ubol-\(tag).partial", isDirectory: true)
                let final = self.blockerHome.appendingPathComponent("ubol-\(tag)", isDirectory: true)
                try? fm.removeItem(at: partial)
                try? fm.createDirectory(at: partial, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", file.path, partial.path]
                try? unzip.run()
                unzip.waitUntilExit()
                // It has to be what it claims: the right extension, at the announced version.
                guard unzip.terminationStatus == 0, Self.manifestVersion(at: partial) == tag,
                      fm.fileExists(atPath: partial.appendingPathComponent("rulesets").path) else {
                    try? fm.removeItem(at: partial)
                    finish("The uBlock Origin Lite update didn’t check out and was discarded")
                    return
                }
                try? fm.removeItem(at: final)
                do {
                    try fm.moveItem(at: partial, to: final)
                    finish("uBlock Origin Lite \(tag) is ready and will be used the next time Sorrel opens")
                } catch {
                    try? fm.removeItem(at: partial)
                    finish("Couldn’t save the uBlock Origin Lite update")
                }
            }.resume()
        }.resume()
    }

    /// Where a Chrome Web Store extension is fetched from. Tests point SORREL_CRX_DIR at a folder of <id>.crx files
    /// (the store itself is off limits to tests).
    private static func chromeStoreSource(for id: String) -> URL {
        if let dir = ProcessInfo.processInfo.environment["SORREL_CRX_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("\(id).crx")
        }
        return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0.0.0&acceptformat=crx2,crx3&x=id%3D\(id)%26installsource%3Dondemand%26uc")!
    }

    /// Fetches a Chrome Web Store extension and unpacks it into `dest` (replacing whatever is there).
    /// Reports the unpacked copy's version. Runs its completion on the main queue.
    private func fetchChromeExtension(id: String, into dest: URL, completion: @escaping (Result<String, Error>) -> Void) {
        func fail(_ message: String) {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "Sorrel", code: 3, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
        let source = Self.chromeStoreSource(for: id)
        URLSession(configuration: .ephemeral).dataTask(with: source) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? (source.isFileURL ? 200 : 0)
            guard let data, status == 200, data.count > 16, data.prefix(4) == Data("Cr24".utf8) else {
                fail("The Chrome Web Store didn’t return that extension. It may have been removed, or need a paid account.")
                return
            }
            // A .crx file is a zip with a signed header in front. Skip the header to reach the zip.
            func u32(_ offset: Int) -> Int { Int(data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian) }
            let version = u32(4)
            let zipStart = version == 2 ? 16 + u32(8) + u32(12) : 12 + u32(8)
            guard zipStart < data.count else { fail("That extension file couldn’t be read."); return }
            let fm = FileManager.default
            let zip = fm.temporaryDirectory.appendingPathComponent("sorrel-\(id)-\(UUID().uuidString).zip")
            do {
                try data.subdata(in: zipStart..<data.count).write(to: zip)
                defer { try? fm.removeItem(at: zip) }
                try? fm.removeItem(at: dest)
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, dest.path]
                try unzip.run()
                unzip.waitUntilExit()
                // Chrome's signature folder is not part of the extension.
                try? fm.removeItem(at: dest.appendingPathComponent("_metadata"))
                guard unzip.terminationStatus == 0, let got = Self.manifestVersion(at: dest) else {
                    try? fm.removeItem(at: dest)
                    fail("That download wasn’t a usable extension.")
                    return
                }
                DispatchQueue.main.async { completion(.success(got)) }
            } catch {
                try? fm.removeItem(at: dest)
                fail(error.localizedDescription)
            }
        }.resume()
    }

    /// Installs an extension from its Chrome Web Store page address (or its 32-letter id).
    func addFromChromeStore(_ text: String, completion: @escaping (Result<ExtensionEntry, Error>) -> Void) {
        guard let range = text.range(of: "[a-p]{32}", options: .regularExpression) else {
            completion(.failure(NSError(domain: "Sorrel", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "That doesn’t look like a Chrome Web Store link. It should contain a 32-letter extension id."])))
            return
        }
        let id = String(text[range])
        fetchChromeExtension(id: id, into: folder.appendingPathComponent("chrome-\(id)", isDirectory: true)) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self.discover()
                if let entry = self.entries.first(where: { $0.id == "added-" + Self.slug("chrome-\(id)") }) {
                    completion(.success(entry))
                } else {
                    completion(.failure(NSError(domain: "Sorrel", code: 4, userInfo: [NSLocalizedDescriptionKey: "The extension was downloaded but couldn’t be listed."])))
                }
            }
        }
    }

    // MARK: Keeping Chrome Web Store extensions current

    /// A newer copy of a Chrome Web Store extension waits here until it can be swapped in.
    private func pendingUpdateFolder(for id: String) -> URL {
        folder.appendingPathComponent("chrome-\(id).update", isDirectory: true)
    }

    /// Fetched updates are swapped in while the extension is not running: at launch (before anything loads),
    /// or right away for one that is switched off. Its settings and sign-ins live in WebKit's store under
    /// the extension's id, not in this folder, so they carry over.
    private func applyPendingChromeUpdates() {
        let fm = FileManager.default
        for pending in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where pending.pathExtension == "update" {
            let live = pending.deletingPathExtension()
            let name = live.lastPathComponent
            if let running = entries.first(where: { if case .folder(let u) = $0.source { return u.lastPathComponent == name } else { return false } }),
               running.isLoaded {
                continue   // next launch
            }
            guard let newVersion = Self.manifestVersion(at: pending) else { try? fm.removeItem(at: pending); continue }
            if let old = Self.manifestVersion(at: live), !Self.version(newVersion, isNewerThan: old) {
                try? fm.removeItem(at: pending)   // already current (reinstalled by hand, say)
                continue
            }
            let aside = folder.appendingPathComponent(name + ".old", isDirectory: true)
            try? fm.removeItem(at: aside)
            if fm.fileExists(atPath: live.path) { try? fm.moveItem(at: live, to: aside) }
            if (try? fm.moveItem(at: pending, to: live)) != nil {
                try? fm.removeItem(at: aside)
            } else if fm.fileExists(atPath: aside.path) {
                try? fm.moveItem(at: aside, to: live)   // put the old one back; try again next time
            }
        }
    }

    /// True when a newer copy of this extension is waiting for the next launch.
    func hasPendingUpdate(_ entry: ExtensionEntry) -> Bool {
        guard let id = entry.chromeID else { return false }
        return FileManager.default.fileExists(atPath: pendingUpdateFolder(for: id).appendingPathComponent("manifest.json").path)
    }

    /// Looks for newer versions of the extensions added from the Chrome Web Store (every few days, or on request).
    /// A newer copy is fetched now and used from the next launch, so a running extension is never disturbed.
    /// The message says what happened, in a sentence.
    func updateChromeExtensionsIfNeeded(force: Bool = false, completion: ((String) -> Void)? = nil) {
        guard force || Settings.current.autoUpdateBlocker else { return }
        let candidates = entries.filter { $0.chromeID != nil }
        guard !candidates.isEmpty else { completion?("No Chrome Web Store extensions to update"); return }
        let stamp = folder.appendingPathComponent("last-update-check")
        if !force, let date = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 3 * 86400 {
            return
        }
        try? Data().write(to: stamp)

        var results: [String] = []
        let group = DispatchGroup()
        for entry in candidates {
            guard let id = entry.chromeID, case .folder(let live) = entry.source,
                  let have = Self.manifestVersion(at: live) else { continue }
            let pending = pendingUpdateFolder(for: id)
            // Compare against the newest copy on hand, so a fetched update isn't fetched again.
            let newest = Self.manifestVersion(at: pending).map { Self.version($0, isNewerThan: have) ? $0 : have } ?? have
            group.enter()
            fetchChromeExtension(id: id, into: pending) { result in
                defer { group.leave() }
                switch result {
                case .failure(let error):
                    results.append("\(entry.name): \(error.localizedDescription)")
                case .success(let got):
                    if Self.version(got, isNewerThan: newest) {
                        results.append("\(entry.name) \(got) is ready and will be used the next time Sorrel opens")
                        self.changed()
                    } else {
                        if got == have { try? FileManager.default.removeItem(at: pending) }
                        results.append(got == have ? "\(entry.name) is up to date (\(have))"
                                                   : "\(entry.name) \(got) is already waiting for the next launch")
                    }
                }
            }
        }
        group.notify(queue: .main) {
            if ProcessInfo.processInfo.environment["SORREL_SNAPSHOT"] != nil {
                for line in results { FileHandle.standardError.write("extupdate: \(line)\n".data(using: .utf8)!) }
            }
            completion?(results.joined(separator: "\n"))
        }
    }

    func discover() {
        var found: [ExtensionEntry] = []
        let fm = FileManager.default

        if let ubol = installedBundledBlocker() {
            found.append(ExtensionEntry(id: Self.blockerID, source: .bundled(ubol), name: "uBlock Origin Lite"))
        }

        applyPendingChromeUpdates()
        for dir in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            // Folders ending in .update, .old or .partial belong to the updater, not to the list.
            guard !["update", "old", "partial"].contains(dir.pathExtension),
                  fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else { continue }
            // Extensions from the Chrome Web Store get the compatibility layer (including ones added before it existed).
            if dir.lastPathComponent.hasPrefix("chrome-") { ChromeCompat.apply(to: dir) }
            found.append(ExtensionEntry(id: "added-" + Self.slug(dir.lastPathComponent), source: .folder(dir),
                                        name: dir.lastPathComponent))
        }

        // Safari extensions already installed on this Mac can run here too.
        let appDirs = [URL(fileURLWithPath: "/Applications"), Sandbox.realHome.appendingPathComponent("Applications")]
        for appDir in appDirs {
            for app in (try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                let plugins = app.appendingPathComponent("Contents/PlugIns")
                for appex in (try? fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [] where appex.pathExtension == "appex" {
                    guard let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist")),
                          let ext = info["NSExtension"] as? [String: Any],
                          (ext["NSExtensionPointIdentifier"] as? String) == "com.apple.Safari.web-extension" else { continue }
                    let appName = app.deletingPathExtension().lastPathComponent
                    let bundleID = (info["CFBundleIdentifier"] as? String) ?? appName
                    // Sorrel already includes uBlock Origin Lite; a second copy from Safari would only double up.
                    if bundleID.lowercased().contains("ublock-origin-lite"), found.contains(where: { $0.id == Self.blockerID }) { continue }
                    found.append(ExtensionEntry(id: "safari-" + Self.slug(bundleID),
                                                source: .safariApp(appex: appex, app: appName),
                                                name: appName.replacingOccurrences(of: " for Safari", with: "")))
                }
            }
        }

        // Keep the live state of anything already loaded.
        for (i, entry) in found.enumerated() {
            if let existing = entries.first(where: { $0.id == entry.id }) { found[i] = existing }
        }
        entries = found
        changed()
    }

    func start() {
        discover()
        for entry in entries where isEnabled(entry) { load(entry) }
        // Quietly keep the built-in blocker current, a little after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.updateBlockerIfNeeded() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.updateChromeExtensionsIfNeeded() }
    }

    // MARK: Loading

    private func load(_ entry: ExtensionEntry, completion: ((Bool) -> Void)? = nil) {
        guard entry.context == nil, !entry.isLoading else { completion?(entry.isLoaded); return }
        entry.isLoading = true
        entry.error = nil
        changed()
        Task { @MainActor in
            do {
                let ext: WKWebExtension
                switch entry.source {
                case .bundled(let url), .folder(let url):
                    ext = try await WKWebExtension(resourceBaseURL: url)
                case .safariApp(let appex, _):
                    guard let bundle = Bundle(url: appex) else { throw CocoaError(.fileReadUnknown) }
                    ext = try await WKWebExtension(appExtensionBundle: bundle)
                }
                let context = WKWebExtensionContext(for: ext)
                // Stable identity and address, so the extension keeps its settings and its pages
                // (its dashboard, say) reopen correctly after a restart.
                // A Chrome Web Store extension keeps its real store id: its own website addresses it by that id.
                let identity = entry.chromeID ?? entry.id
                context.uniqueIdentifier = identity
                if let base = URL(string: "webkit-extension://\(identity)/") { context.baseURL = base }
                if entry.chromeID != nil,
                   let external = ext.manifest["externally_connectable"] as? [String: Any],
                   let matches = external["matches"] as? [String] {
                    entry.companionSites = ChromeCompat.exactHostPatterns(matches).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
                }
                context.isInspectable = true

                // Switching an extension on grants what its manifest requires; the person agreed to that then, and
                // it is recorded. Extensions update themselves, so a later version that requires more (every
                // website, cookies, …) is held back, with the extension off, until the person agrees.
                // Optional extras (clipboard, more sites, …) are asked for when the extension wants them,
                // and remembered once approved.
                let required = ext.requestedPermissions.map { "perm:" + $0.rawValue }
                    + ext.allRequestedMatchPatterns.map { "match:" + $0.string }
                let approved = Settings.current.extensionApproved[entry.id]
                let added = approved.map { have in required.filter { !have.contains($0) } } ?? []
                if !added.isEmpty {
                    let name = ext.displayName ?? entry.name
                    guard await self.approveNewAccess(name: name, added: added) else {
                        entry.isLoading = false
                        entry.error = "Switched off: its new version wants more access (\(Self.describe(added))). Switch it on to review."
                        Settings.current.extensionStates[entry.id] = false
                        Settings.current.save()
                        self.afterStateChange(entry)
                        completion?(false)
                        return
                    }
                }
                if approved.map({ Set($0) }) != Set(required).union(approved ?? []) {
                    Settings.current.extensionApproved[entry.id] = Array(Set(required).union(approved ?? [])).sorted()
                    Settings.current.save()
                }
                for permission in ext.requestedPermissions {
                    context.setPermissionStatus(.grantedExplicitly, for: permission)
                }
                for pattern in ext.allRequestedMatchPatterns {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
                for grant in Settings.current.extensionGrants[entry.id] ?? [] {
                    if grant.hasPrefix("perm:") {
                        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: String(grant.dropFirst(5))))
                    } else if grant.hasPrefix("match:"), let pattern = try? WKWebExtension.MatchPattern(string: String(grant.dropFirst(6))) {
                        context.setPermissionStatus(.grantedExplicitly, for: pattern)
                    } else if grant.hasPrefix("url:"), let url = URL(string: String(grant.dropFirst(4))) {
                        context.setPermissionStatus(.grantedExplicitly, for: url)
                    }
                }

                try self.controller.load(context)
                entry.context = context
                entry.name = ext.displayName ?? entry.name
                entry.version = ext.displayVersion ?? ""
                entry.summary = ext.displayDescription ?? ""
                entry.icon = ext.icon(for: CGSize(width: 32, height: 32))
                entry.isLoading = false
                // The extension counts as on from here. Its background page starts separately; some take
                // a while or never report back, and that must not leave the extension looking stuck.
                self.afterStateChange(entry)
                completion?(true)
                if ProcessInfo.processInfo.environment["SORREL_NO_BG"] != nil { return }   // testing: start it on demand
                self.startBackground(of: entry, context: context, attempt: 1)
            } catch {
                entry.isLoading = false
                entry.error = error.localizedDescription
                self.afterStateChange(entry)
                completion?(false)
            }
        }
    }

    /// Starts the extension's background script. WebKit now and then fails the very first start right after
    /// launch (seen with Proton Pass: its script ran before the compatibility layer had taken), and the same
    /// start succeeds a moment later, so one failure gets a second go before it is reported.
    private func startBackground(of entry: ExtensionEntry, context: WKWebExtensionContext, attempt: Int) {
        context.loadBackgroundContent { (error: (any Error)?) in
            let testing = ProcessInfo.processInfo.environment["SORREL_SNAPSHOT"] != nil
            guard let error else {
                if attempt > 1 {
                    entry.error = nil
                    if testing { FileHandle.standardError.write("ext: background of \(entry.id) started on attempt \(attempt)\n".data(using: .utf8)!) }
                    self.changed()
                }
                return
            }
            let e = error as NSError
            // Extensions without a background page report that here; it is not a failure.
            if e.domain == WKWebExtensionContext.errorDomain && e.code == WKWebExtensionContext.Error.noBackgroundContent.rawValue { return }
            if testing { FileHandle.standardError.write("ext: background of \(entry.id) failed on attempt \(attempt): \(error.localizedDescription)\n".data(using: .utf8)!) }
            if attempt == 1, entry.context === context {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard entry.context === context else { return }
                    self?.startBackground(of: entry, context: context, attempt: 2)
                }
                return
            }
            entry.error = "Its background page didn’t start: \(error.localizedDescription)"
            self.changed()
        }
    }

    private func unload(_ entry: ExtensionEntry) {
        if let context = entry.context { try? controller.unload(context) }
        entry.context = nil
        entry.companionSites = []
        afterStateChange(entry)
    }

    private func afterStateChange(_ entry: ExtensionEntry) {
        if entry.id == Self.blockerID {
            if entry.isLoaded {
                if blockerTakeoverAt == nil {
                    blockerTakeoverAt = Date().addingTimeInterval(Self.blockerHandoverDelay)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.blockerHandoverDelay + 0.1) {
                        Blocker.shared.extensionBlockerChanged()
                        // By now the extension's rules are loaded; give back what that work used.
                        releaseFreedMemory()
                    }
                }
            } else {
                blockerTakeoverAt = nil
            }
            Blocker.shared.extensionBlockerChanged()
        }
        changed()
    }

    func setEnabled(_ entry: ExtensionEntry, _ on: Bool, completion: ((Bool) -> Void)? = nil) {
        Settings.current.extensionStates[entry.id] = on
        Settings.current.save()
        if on { load(entry, completion: completion) } else { unload(entry); completion?(true) }
    }

    /// Copies an unpacked extension folder, or unzips an archive, into Sorrel's Extensions folder.
    func add(from url: URL) throws -> ExtensionEntry? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let name = url.deletingPathExtension().lastPathComponent
        let dest = folder.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }

        if isDir.boolValue {
            guard fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
                throw NSError(domain: "Sorrel", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "That folder isn’t an extension: it has no manifest.json at its top level."])
            }
            try fm.copyItem(at: url, to: dest)
        } else {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            // Sandbox: access to a file the person picked is granted to Sorrel itself, not to the ditto it
            // starts, so ditto unpacks a private copy.
            let copy = fm.temporaryDirectory.appendingPathComponent("sorrel-add-\(UUID().uuidString).zip")
            try fm.copyItem(at: url, to: copy)
            defer { try? fm.removeItem(at: copy) }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", copy.path, dest.path]
            try unzip.run()
            unzip.waitUntilExit()
            // Some archives wrap everything in a single folder.
            if !fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path),
               let inner = (try? fm.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil))?
                .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
                let tmp = folder.appendingPathComponent(name + "-unwrapped", isDirectory: true)
                try? fm.removeItem(at: tmp)
                try fm.moveItem(at: inner, to: tmp)
                try fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            }
            guard fm.fileExists(atPath: dest.appendingPathComponent("manifest.json").path) else {
                try? fm.removeItem(at: dest)
                throw NSError(domain: "Sorrel", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "That archive isn’t an extension: no manifest.json was found inside it."])
            }
        }
        discover()
        return entries.first { if case .folder(let u) = $0.source { return u.lastPathComponent == name } else { return false } }
    }

    func remove(_ entry: ExtensionEntry) {
        guard case .folder(let url) = entry.source else { return }
        unload(entry)
        try? FileManager.default.removeItem(at: url)
        if let id = entry.chromeID { try? FileManager.default.removeItem(at: pendingUpdateFolder(for: id)) }
        Settings.current.extensionStates[entry.id] = nil
        Settings.current.extensionGrants[entry.id] = nil
        Settings.current.extensionApproved[entry.id] = nil
        Settings.current.save()
        discover()
    }

    /// "perm:cookies", "match:<all_urls>" -> words for a prompt.
    static func describe(_ access: [String]) -> String {
        access.map { item -> String in
            if item.hasPrefix("perm:") { return String(item.dropFirst(5)) }
            let pattern = String(item.dropFirst(6))
            if pattern == "<all_urls>" || pattern.hasPrefix("*://*/") || pattern.contains("://*/") { return "every website" }
            return pattern
        }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(8).joined(separator: ", ")
    }

    /// An updated extension requires access it didn't have when switched on. Asks once; tests never ask (no).
    private func approveNewAccess(name: String, added: [String]) async -> Bool {
        if isQuietTest {
            FileHandle.standardError.write("ext: \(name) now requires more access, held back: \(Self.describe(added))\n".data(using: .utf8)!)
            return false
        }
        return await withCheckedContinuation { done in
            ask("\(name) was updated and now wants more access",
                "The new version asks for: \(Self.describe(added)).\n\nIf you don’t allow it, Sorrel switches the extension off. You can switch it back on in Settings ▸ Extensions to see this again.",
                completion: { done.resume(returning: $0) })
        }
    }

    // MARK: Pages

    func isExtensionURL(_ url: URL) -> Bool { controller.extensionContext(for: url) != nil }

    /// True for a website that a switched-on Chrome extension declares as its own (its sign-in page, say).
    /// Such a site hands things to "the Chrome extension", so it has to be told this browser is Chrome.
    func isChromeCompanionSite(_ url: URL) -> Bool {
        for entry in entries where entry.isLoaded && !entry.companionSites.isEmpty {
            if entry.companionSites.contains(where: { $0.matches(url) }) { return true }
        }
        return false
    }

    /// Extension pages (settings, dashboards) must be shown in a page made from the extension's own configuration.
    func configuration(forExtensionURL url: URL) -> WKWebViewConfiguration? {
        controller.extensionContext(for: url)?.webViewConfiguration
    }

    func entry(for context: WKWebExtensionContext) -> ExtensionEntry? { entries.first { $0.context === context } }

    // MARK: Telling extensions about tabs

    func tabOpened(_ item: Item) { controller.didOpenTab(item.extensionTab) }
    func tabClosed(_ item: Item) { controller.didCloseTab(item.extensionTab, windowIsClosing: false) }

    func tabActivated(_ item: Item?, previous: Item?) {
        guard let item, item !== previous else { return }
        controller.didActivateTab(item.extensionTab, previousActiveTab: previous?.extensionTab)
    }

    func tabChanged(_ item: Item) {
        controller.didChangeTabProperties([.URL, .title, .loading], for: item.extensionTab)
    }

    func windowReady() {
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
    }

    // MARK: Toolbar actions

    /// Runs an extension's toolbar button: opens its pop-up, or sends it a click.
    func performAction(_ entry: ExtensionEntry) {
        guard let context = entry.context else { return }
        context.performAction(for: Store.shared.selected?.extensionTab)
    }

    /// The extension's toolbar button as it stands for a tab (the selected one unless told otherwise):
    /// its current icon, badge, label and enabled state. Extensions change these per site.
    func action(for entry: ExtensionEntry, in item: Item? = Store.shared.selected) -> WKWebExtension.Action? {
        entry.context?.action(for: item?.extensionTab)
    }

    /// Keyboard shortcuts the extension declares (its manifest `commands`), for menus and Settings.
    func commands(for entry: ExtensionEntry) -> [WKWebExtension.Command] { entry.context?.commands ?? [] }

    /// Runs an extension's keyboard shortcut if the key press matches one. Sorrel's own shortcuts are
    /// checked first by the caller, so they win over an extension's.
    func handleKey(_ event: NSEvent) -> Bool {
        for entry in loaded {
            guard let context = entry.context, context.command(for: event) != nil else { continue }
            if context.performCommand(for: event) { return true }
        }
        return false
    }

    /// A readable shortcut, like ⌘⇧X, or nil when the command has no key.
    static func shortcutText(for command: WKWebExtension.Command) -> String? {
        guard let key = command.activationKey, !key.isEmpty else { return nil }
        var text = ""
        let f = command.modifierFlags
        if f.contains(.control) { text += "⌃" }
        if f.contains(.option) { text += "⌥" }
        if f.contains(.shift) { text += "⇧" }
        if f.contains(.command) { text += "⌘" }
        let names: [String: String] = ["up": "↑", "down": "↓", "left": "←", "right": "→", " ": "Space",
                                       "\u{7F}": "⌫", "\t": "⇥", "\r": "↩", "\u{1B}": "⎋"]
        return text + (names[key] ?? key.uppercased())
    }

    func openOptions(_ entry: ExtensionEntry) {
        guard let url = entry.context?.optionsPageURL else { return }
        AppDelegate.shared.showMainWindow()
        Store.shared.newTab(url: url.absoluteString, title: entry.name)
    }

    /// If a pop-up's own stylesheet gives it a fixed size larger than the window it currently has, tell
    /// the page to be at least that big. WebKit's popover then grows to fit, and the page settles there.
    private func applyDeclaredSize(to action: WKWebExtension.Action) {
        guard let webView = action.popupWebView else { return }
        // Read the size from the stylesheet, not from the live page: the live page has already shrunk.
        let script = """
        (function () {
          var root = document.documentElement, body = document.body || root;
          var vars = {}, declared = { width: 0, height: 0 }, rules = [];
          for (var i = 0; i < document.styleSheets.length; i++) {
            try { var list = document.styleSheets[i].cssRules; for (var j = 0; j < list.length; j++) if (list[j].style && list[j].selectorText) rules.push(list[j]); } catch (e) {}
          }
          rules.forEach(function (r) {
            var hit = false; try { hit = root.matches(r.selectorText); } catch (e) {}
            if (!hit) return;
            for (var k = 0; k < r.style.length; k++) { var name = r.style[k]; if (name.indexOf('--') === 0) vars[name] = r.style.getPropertyValue(name).trim(); }
          });
          var px = function (value) {
            value = String(value || '').trim();
            var m = value.match(/^var\\((--[\\w-]+)(?:,\\s*([^)]+))?\\)$/);
            if (m) value = vars[m[1]] || m[2] || '';
            return /^[\\d.]+px$/.test(value) ? parseFloat(value) : 0;
          };
          [root, body].forEach(function (el) {
            rules.forEach(function (r) {
              var hit = false; try { hit = el.matches(r.selectorText); } catch (e) {}
              if (!hit) return;
              ['width', 'height'].forEach(function (prop) { var v = px(r.style.getPropertyValue(prop)); if (v > declared[prop]) declared[prop] = v; });
            });
          });
          var w = Math.min(800, declared.width), h = Math.min(600, declared.height), changed = 0;
          if (w > window.innerWidth + 20 || h > window.innerHeight + 20) {
            [root, body].forEach(function (el) {
              if (w) el.style.setProperty('min-width', w + 'px', 'important');
              if (h) el.style.setProperty('min-height', h + 'px', 'important');
            });
            changed = 1;
          }
          return [w, h, window.innerWidth, window.innerHeight, changed];
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            if ProcessInfo.processInfo.environment["SORREL_SNAPSHOT"] != nil, let r = result as? [Double], r.count == 5 {
                FileHandle.standardError.write("popup size: declared \(Int(r[0]))x\(Int(r[1])), window \(Int(r[2]))x\(Int(r[3])), corrected=\(r[4] == 1)\n".data(using: .utf8)!)
                // Testing: where the page's main boxes actually are.
                let probe = "(function(){var box=function(el){if(!el)return 'none';var r=el.getBoundingClientRect(),c=getComputedStyle(el);return [Math.round(r.left),Math.round(r.top),Math.round(r.width)+'x'+Math.round(r.height),c.display,c.position,'op'+c.opacity,c.overflow].join(' ');};var root=document.querySelector('.app-root');var kids=root?Array.prototype.slice.call(root.children,0,3).map(box):[];var st=getComputedStyle(document.documentElement);return ['text:'+(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,60),'html:'+box(document.documentElement),'body:'+box(document.body),'appRoot:'+box(root),'children:'+kids.join(' | '),'vars:'+st.getPropertyValue('--popup-width')+'/'+st.getPropertyValue('--popup-height'),'htmlStyle:'+document.documentElement.getAttribute('style'),'scroll:'+window.scrollX+','+window.scrollY+' of '+document.documentElement.scrollWidth+'x'+document.documentElement.scrollHeight,'page visibility:'+document.visibilityState,'main box class:'+(root&&root.children[2]?root.children[2].className:'-')+' animation:'+(root&&root.children[2]?getComputedStyle(root.children[2]).animationName+' '+getComputedStyle(root.children[2]).animationPlayState+' transition:'+getComputedStyle(root.children[2]).transitionProperty:'-'),'animations:'+document.getAnimations().slice(0,6).map(function(a){return (a.animationName||a.transitionProperty||'?')+'='+a.playState+'@'+Math.round(a.currentTime||0)}).join(', ')].join('\\n   ');})()"
                webView.evaluateJavaScript(probe) { text, error in
                    FileHandle.standardError.write("popup layout:\n   \(text ?? error?.localizedDescription ?? "nil")\n".data(using: .utf8)!)
                }
            }
        }
    }

    /// Remembers access the person approved for an extension, so it survives a restart.
    private func remember(_ grants: [String], for context: WKWebExtensionContext) {
        guard let id = entry(for: context)?.id, !grants.isEmpty else { return }
        var list = Settings.current.extensionGrants[id] ?? []
        for g in grants where !list.contains(g) { list.append(g) }
        Settings.current.extensionGrants[id] = list
        Settings.current.save()
    }

    private func ask(_ title: String, _ detail: String, allow: String = "Allow", completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: allow)
        alert.addButton(withTitle: "Don’t Allow")
        if let window = AppDelegate.shared.main?.window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

// MARK: - What extensions ask the browser to do

extension Extensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [window]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        window
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        if ProcessInfo.processInfo.environment["SORREL_EXTDIAG"] != nil {
            FileHandle.standardError.write("extlog[sorrel]: extension asked for a new tab: \(configuration.url?.absoluteString ?? "blank")\n".data(using: .utf8)!)
        }
        AppDelegate.shared.showMainWindow()
        let item = Store.shared.newTab(url: configuration.url?.absoluteString ?? "", select: configuration.shouldBeActive)
        if !configuration.shouldBeActive { _ = Engine.shared.ensurePage(for: item) }
        completionHandler(item.extensionTab, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
        // Sorrel has one main window, so a requested window opens as tabs in it.
        AppDelegate.shared.showMainWindow()
        for url in configuration.tabURLs { Store.shared.newTab(url: url.absoluteString) }
        completionHandler(window, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping ((any Error)?) -> Void) {
        if let entry = entry(for: extensionContext) { openOptions(entry) }
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let name = entry(for: extensionContext)?.name ?? "An extension"
        let list = permissions.map { $0.rawValue }.sorted().joined(separator: ", ")
        ask("\(name) is asking for more access", "It wants: \(list).") { [weak self] allowed in
            if allowed { self?.remember(permissions.map { "perm:" + $0.rawValue }, for: extensionContext) }
            completionHandler(allowed ? permissions : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let name = entry(for: extensionContext)?.name ?? "An extension"
        let hosts = Set(urls.compactMap { $0.host }).sorted().prefix(6).joined(separator: ", ")
        ask("Let \(name) read and change this site?", hosts) { [weak self] allowed in
            if allowed { self?.remember(urls.map { "url:" + $0.absoluteString }, for: extensionContext) }
            completionHandler(allowed ? urls : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let name = entry(for: extensionContext)?.name ?? "An extension"
        let all = matchPatterns.contains { $0.matchesAllHosts || $0.matchesAllURLs }
        let detail = all ? "It is asking for every website."
                         : matchPatterns.map { $0.string }.sorted().prefix(6).joined(separator: ", ")
        ask("Let \(name) read and change websites?", detail) { [weak self] allowed in
            if allowed { self?.remember(matchPatterns.map { "match:" + $0.string }, for: extensionContext) }
            completionHandler(allowed ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) {
        // Only the selected tab's button is on screen; a change for another tab shows when that tab is selected.
        if let tab = action.associatedTab as? ExtensionTab, let item = tab.item, Store.shared.selected !== item { return }
        NotificationCenter.default.post(name: .sorrelExtensionAction, object: entry(for: context))
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let popover = action.popupPopover, let main = AppDelegate.shared.main else {
            completionHandler(nil)
            return
        }
        AppDelegate.shared.showMainWindow()
        let (view, rect, edge) = main.extensionPopupAnchor(for: entry(for: context))
        completionHandler(nil)
        openPopover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: edge)
        // WebKit sizes the pop-up to fit its content. A pop-up built for Chrome may declare a fixed size
        // instead (Proton Pass: 600 by 430) and then adapt to whatever window it is given, so WebKit and
        // the page talk each other down to a thin strip. Checked a few times as the page loads.
        for delay in [0.1, 0.4, 1.0, 2.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, popover.isShown, self.openPopover === popover else { return }
                self.applyDeclaredSize(to: action)
            }
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
                                toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext,
                                replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        if applicationIdentifier == "sorrel-diag" {   // testing: the extension reporting on itself
            if let m = message as? [String: Any] {
                FileHandle.standardError.write("extlog[\(m["where"] ?? "?")]: \(m["msg"] ?? "")\n".data(using: .utf8)!)
            }
            replyHandler(["ok": true], nil)
            return
        }
        // Messages to a companion Mac app are not available outside Safari.
        replyHandler(nil, NSError(domain: "Sorrel", code: 10, userInfo: [NSLocalizedDescriptionKey:
            "Sorrel can’t pass messages to the extension’s companion app."]))
    }
}
