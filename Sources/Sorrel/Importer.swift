import AppKit
import SQLite3

// Importing from another browser (the screens are in ImportView.swift).
//
// Sorrel is sandboxed and may not look at other apps' files on its own, so every import starts with the person
// handing over the browser's folder in an Open panel (already pointed at it). Nothing is copied wholesale: the
// readers below pick out spaces, pinned tabs, favorites, bookmarks and history, and `Importer.apply` merges them
// into the sidebar without duplicating what is already there. Cookies and passwords are never read.

/// One thing to put in the sidebar.
indirect enum ImportedNode {
    case tab(title: String, customTitle: String?, url: String)
    case folder(title: String, children: [ImportedNode])
    case split([ImportedNode])

    var tabCount: Int {
        switch self {
        case .tab: return 1
        case .folder(_, let kids), .split(let kids): return kids.reduce(0) { $0 + $1.tabCount }
        }
    }

    var folderCount: Int {
        switch self {
        case .tab: return 0
        case .folder(_, let kids): return 1 + kids.reduce(0) { $0 + $1.folderCount }
        case .split(let kids): return kids.reduce(0) { $0 + $1.folderCount }
        }
    }

    /// Every tab inside, in order, with folders and splits dissolved.
    var flatTabs: [ImportedNode] {
        switch self {
        case .tab: return [self]
        case .folder(_, let kids), .split(let kids): return kids.flatMap(\.flatTabs)
        }
    }
}

struct ImportedSpace {
    var name: String
    var icon: String
    var theme: Theme?
    var pinned: [ImportedNode] = []
    var today: [ImportedNode] = []
    /// Spaces that kept separate logins in the other browser share a key; nil = the default logins.
    var profileKey: String?

    var pinnedTabs: Int { pinned.reduce(0) { $0 + $1.tabCount } }
    var todayTabs: Int { today.reduce(0) { $0 + $1.tabCount } }
}

/// Everything a reader found, before the person chooses what to bring.
struct ImportFound {
    var spaces: [ImportedSpace] = []
    var favorites: [ImportedNode] = []
    var bookmarks: [ImportedNode] = []
    var history: [History.Entry] = []
    /// Parts that couldn't be read (a locked database, say), in plain words.
    var problems: [String] = []

    var bookmarkCount: Int { bookmarks.reduce(0) { $0 + $1.tabCount } }
    var isEmpty: Bool { spaces.isEmpty && favorites.isEmpty && bookmarks.isEmpty && history.isEmpty }
}

/// What the person chose to bring over.
struct ImportChoice {
    var spaces = true
    var openTabs = true
    var favorites = true
    var bookmarks = true
    var history = true
}

struct ImportSummary {
    var spacesAdded = 0
    var spacesMerged = 0
    var tabsAdded = 0
    var favoritesAdded = 0
    var historyAdded = 0
    /// The first space that received something, to show afterwards.
    var firstSpace: Space?

    var lines: [String] {
        var out: [String] = []
        if spacesAdded > 0 { out.append(plural(spacesAdded, "new space")) }
        if spacesMerged > 0 { out.append("\(plural(spacesMerged, "space")) filled in") }
        if tabsAdded > 0 { out.append(plural(tabsAdded, "tab")) }
        if favoritesAdded > 0 { out.append(plural(favoritesAdded, "favorite")) }
        if historyAdded > 0 { out.append("\(plural(historyAdded, "page")) of history") }
        return out
    }
}

func plural(_ n: Int, _ word: String) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    let num = f.string(from: NSNumber(value: n)) ?? "\(n)"
    return "\(num) \(word)\(n == 1 ? "" : "s")"
}

// MARK: - Browsers Sorrel knows how to read

struct BrowserSource: Equatable {
    enum Kind { case arc, chromium, firefox, safari, bookmarksFile }

    let id: String
    let name: String
    let kind: Kind
    let bundleID: String?
    /// Where the browser keeps its data, relative to the real home folder.
    let dataPath: String?

    static func == (a: BrowserSource, b: BrowserSource) -> Bool { a.id == b.id }

    static let all: [BrowserSource] = [
        .init(id: "arc", name: "Arc", kind: .arc, bundleID: "company.thebrowser.Browser", dataPath: "Library/Application Support/Arc"),
        .init(id: "chrome", name: "Chrome", kind: .chromium, bundleID: "com.google.Chrome", dataPath: "Library/Application Support/Google/Chrome"),
        .init(id: "helium", name: "Helium", kind: .chromium, bundleID: "net.imput.helium", dataPath: "Library/Application Support/net.imput.helium"),
        .init(id: "brave", name: "Brave", kind: .chromium, bundleID: "com.brave.Browser", dataPath: "Library/Application Support/BraveSoftware/Brave-Browser"),
        .init(id: "edge", name: "Edge", kind: .chromium, bundleID: "com.microsoft.edgemac", dataPath: "Library/Application Support/Microsoft Edge"),
        .init(id: "vivaldi", name: "Vivaldi", kind: .chromium, bundleID: "com.vivaldi.Vivaldi", dataPath: "Library/Application Support/Vivaldi"),
        .init(id: "dia", name: "Dia", kind: .chromium, bundleID: "company.thebrowser.dia", dataPath: "Library/Application Support/Dia"),
        .init(id: "zen", name: "Zen", kind: .firefox, bundleID: "app.zen-browser.zen", dataPath: "Library/Application Support/zen"),
        .init(id: "firefox", name: "Firefox", kind: .firefox, bundleID: "org.mozilla.firefox", dataPath: "Library/Application Support/Firefox"),
        .init(id: "safari", name: "Safari", kind: .safari, bundleID: "com.apple.Safari", dataPath: "Library/Safari"),
    ]

    static let bookmarksFile = BrowserSource(id: "file", name: "Bookmarks File", kind: .bookmarksFile, bundleID: nil, dataPath: nil)

    var appURL: URL? { bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } }
    var dataURL: URL? { dataPath.map { Sandbox.realHome.appendingPathComponent($0, isDirectory: true) } }
    var isInstalled: Bool { appURL != nil }

    /// The browsers worth offering: the ones on this Mac, plus Arc always, since people keep its data after the
    /// app goes (Arc closes on 2026-12-22).
    static func offered() -> [BrowserSource] {
        all.filter { $0.isInstalled || $0.kind == .arc }
    }

    /// The app's own icon, or a lettered tile when the app isn't on this Mac.
    var icon: NSImage {
        if let app = appURL {
            let img = NSWorkspace.shared.icon(forFile: app.path)
            img.size = NSSize(width: 128, height: 128)
            return img
        }
        if kind == .bookmarksFile, let doc = symbol("doc.text", size: 40, weight: .regular) { return doc }
        return BrowserSource.monogram(String(name.prefix(1)), theme: kind == .arc ? Theme(colors: ["#FF5F6D", "#7B61FF"], angle: 315, intensity: 1) : Theme.presets[0])
    }

    static func monogram(_ letter: String, theme: Theme) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: 26, yRadius: 26)
            let colors = theme.resolvedColors(systemIsDark: false)
            NSGradient(colors: colors.count > 1 ? colors : colors + colors)?.draw(in: tile, angle: -45)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.white]
            let s = NSAttributedString(string: letter, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
    }

    /// What the person is asked to hand over, in one sentence.
    var accessHint: String {
        switch kind {
        case .bookmarksFile:
            return "Choose a bookmarks file you exported from any browser (an .html file)."
        case .safari:
            return "Safari’s folder will already be selected in the next window: just click Allow. If Safari won’t share it, export your bookmarks from Safari (File ▸ Export ▸ Bookmarks…) and choose that file instead."
        default:
            return "\(name)’s folder will already be selected in the next window: just click Allow. Birch reads it once and copies nothing else."
        }
    }
}

enum ImportError: LocalizedError {
    case wrongFolder(String)
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case .wrongFolder(let s), .unreadable(let s): return s
        }
    }
}

// MARK: - Reading

enum ImportReader {
    /// Reads `root` (the folder or file the person picked). Runs off the main thread.
    static func read(_ source: BrowserSource, at root: URL) throws -> ImportFound {
        switch source.kind {
        case .arc: return try readArc(root)
        case .chromium: return try readChromium(root, name: source.name)
        case .firefox: return try readFirefox(root, name: source.name)
        case .safari: return try readSafari(root)
        case .bookmarksFile: return try readBookmarksFile(root)
        }
    }

    static let historyLimit = 10_000

    static func isImportable(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Arc

    static func readArc(_ root: URL) throws -> ImportFound {
        let file = root.appendingPathComponent("StorableSidebar.json")
        guard let data = try? Data(contentsOf: file) else {
            throw ImportError.wrongFolder("That folder doesn’t look like Arc’s (it has no StorableSidebar.json). Arc keeps it in Library ▸ Application Support ▸ Arc.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (json["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let c = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else {
            throw ImportError.unreadable("Arc’s sidebar file is in a format Birch doesn’t recognise.")
        }
        var items: [String: [String: Any]] = [:]
        for case let i as [String: Any] in c["items"] as? [Any] ?? [] {
            if let id = i["id"] as? String { items[id] = i }
        }

        func node(_ id: String, depth: Int) -> ImportedNode? {
            guard depth < 24, let i = items[id], let d = i["data"] as? [String: Any] else { return nil }
            let title = (i["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            if let tab = d["tab"] as? [String: Any] {
                guard let url = tab["savedURL"] as? String, isImportable(url) else { return nil }
                let saved = (tab["savedTitle"] as? String) ?? ""
                return .tab(title: saved, customTitle: title == saved ? nil : title, url: url)
            }
            let kids = (i["childrenIds"] as? [String] ?? []).compactMap { node($0, depth: depth + 1) }
            if d["splitView"] != nil { return kids.isEmpty ? nil : .split(kids) }
            if d["list"] != nil { return .folder(title: title ?? "Folder", children: kids) }
            // Anything newer Arc may have added that still holds tabs comes over as a folder.
            return kids.isEmpty ? nil : .folder(title: title ?? "Folder", children: kids)
        }
        func contents(of container: String?) -> [ImportedNode] {
            guard let container else { return [] }
            return (items[container]?["childrenIds"] as? [String] ?? []).compactMap { node($0, depth: 0) }
        }
        /// Arc lists containers as [key, id, key, id…], where a key is a string or a one-entry dictionary.
        func pairs(_ list: [Any]) -> [(key: String, id: String)] {
            var out: [(String, String)] = []
            var i = 0
            while i + 1 < list.count {
                let key = (list[i] as? String) ?? (list[i] as? [String: Any])?.keys.first ?? ""
                if let id = list[i + 1] as? String { out.append((key, id)) }
                i += 2
            }
            return out
        }

        var found = ImportFound()
        for case let s as [String: Any] in c["spaces"] as? [Any] ?? [] {
            let containerPairs = pairs(s["containerIDs"] as? [Any] ?? [])
            var space = ImportedSpace(name: (s["title"] as? String)?.nonEmpty ?? "Space", icon: "●", theme: nil)
            space.pinned = contents(of: containerPairs.first { $0.key == "pinned" }?.id)
            space.today = contents(of: containerPairs.first { $0.key == "unpinned" }?.id)
            let info = s["customInfo"] as? [String: Any] ?? [:]
            if let icon = info["iconType"] as? [String: Any] {
                if let e = (icon["emoji_v2"] as? String)?.nonEmpty { space.icon = e }
                else if let n = icon["emoji"] as? Int, let scalar = Unicode.Scalar(n) { space.icon = String(Character(scalar)) }
            }
            space.theme = arcTheme(info["windowTheme"] as? [String: Any])
            if let profile = s["profile"] as? [String: Any], profile["default"] == nil,
               let key = try? JSONSerialization.data(withJSONObject: profile, options: .sortedKeys) {
                space.profileKey = String(decoding: key, as: UTF8.self)
            }
            found.spaces.append(space)
        }

        var seen = Set<String>()
        for (_, id) in pairs(c["topAppsContainerIDs"] as? [Any] ?? []) {
            for t in contents(of: id).flatMap(\.flatTabs) {
                if case .tab(_, _, let url) = t, seen.insert(url).inserted { found.favorites.append(t) }
            }
        }

        // Arc's history lives in an ordinary Chromium profile folder beside the sidebar file.
        let userData = root.appendingPathComponent("User Data", isDirectory: true)
        if exists(userData) {
            let (history, problems) = chromiumHistory(profiles: chromiumProfiles(userData).map(\.url))
            found.history = history
            found.problems += problems
        }
        return found
    }

    /// Arc's space colour -> a Sorrel theme. Arc stores either one colour or a gradient's base colours; a colour
    /// that is almost white (Arc's pale "light" themes) gives way to the palette's mid tone, which keeps the hue.
    static func arcTheme(_ theme: [String: Any]?) -> Theme? {
        guard let theme else { return nil }
        func hex(_ any: Any?) -> String? {
            guard let c = any as? [String: Any], let r = c["red"] as? Double, let g = c["green"] as? Double, let b = c["blue"] as? Double else { return nil }
            func clamp(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, v))) }
            return NSColor(srgbRed: clamp(r), green: clamp(g), blue: clamp(b), alpha: 1).hexString
        }
        let palette = theme["primaryColorPalette"] as? [String: Any]
        let midTone = hex(palette?["midTone"])
        let style = ((((theme["background"] as? [String: Any])?["single"] as? [String: Any])?["_0"] as? [String: Any])?["style"] as? [String: Any])
        let color = ((style?["color"] as? [String: Any])?["_0"] as? [String: Any]) ?? [:]
        let dark = (color.values.first as? [String: Any]).flatMap { ($0["_0"] as? [String: Any])?["translucencyStyle"] as? String } == "dark"
        // Arc's grain slider (`modifiers.noiseFactor`, 0…1) carries over as the space's grain.
        let grain = (color.values.first as? [String: Any]).flatMap { (($0["_0"] as? [String: Any])?["modifiers"] as? [String: Any])?["noiseFactor"] as? Double }
        if let single = (color["blendedSingleColor"] as? [String: Any])?["_0"] as? [String: Any],
           var c = hex(single["color"]) {
            if let lum = NSColor(hex: c)?.luminance, lum > 0.9, let m = midTone { c = m }
            return Theme(colors: [c], angle: 315, intensity: dark ? 0.95 : 0.6, grain: grain)
        }
        if let grad = (color["blendedGradient"] as? [String: Any])?["_0"] as? [String: Any],
           let bases = grad["baseColors"] as? [Any] {
            let cs = bases.compactMap(hex).prefix(3)
            if !cs.isEmpty { return Theme(colors: Array(cs), angle: 315, intensity: dark ? 0.95 : 0.85, grain: grain) }
        }
        return midTone.map { Theme(colors: [$0], angle: 315, intensity: 0.6, grain: grain) }
    }

    // MARK: Chrome, Helium, Brave, Edge, Vivaldi, Dia

    /// The profile folders under a Chromium "User Data" folder, with the names the browser shows for them.
    static func chromiumProfiles(_ root: URL) -> [(url: URL, name: String)] {
        // The picked folder may be one profile on its own.
        if exists(root.appendingPathComponent("Bookmarks")) || exists(root.appendingPathComponent("History")) {
            return [(root, root.lastPathComponent)]
        }
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, info) in cache { names[dir] = (info as? [String: Any])?["name"] as? String ?? dir }
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let candidates = dirs.filter { $0 == "Default" || $0.hasPrefix("Profile ") || names[$0] != nil }
        return candidates
            .filter { exists(root.appendingPathComponent($0).appendingPathComponent("History")) || exists(root.appendingPathComponent($0).appendingPathComponent("Bookmarks")) }
            .sorted { a, b in a == "Default" ? true : b == "Default" ? false : a.localizedStandardCompare(b) == .orderedAscending }
            .map { (root.appendingPathComponent($0, isDirectory: true), names[$0] ?? $0) }
    }

    static func readChromium(_ picked: URL, name: String) throws -> ImportFound {
        var root = picked
        if !exists(root.appendingPathComponent("Local State")), exists(root.appendingPathComponent("User Data/Local State")) {
            root = root.appendingPathComponent("User Data", isDirectory: true)
        }
        let profiles = chromiumProfiles(root)
        guard !profiles.isEmpty else {
            throw ImportError.wrongFolder("That folder doesn’t look like \(name)’s: there are no bookmarks or history in it.")
        }
        var found = ImportFound()
        var perProfile: [(String, [ImportedNode])] = []
        for p in profiles {
            let marks = chromiumBookmarks(p.url.appendingPathComponent("Bookmarks"))
            if !marks.isEmpty { perProfile.append((p.name, marks)) }
        }
        // One profile's bookmarks go straight in; several each get a folder named after the profile.
        if perProfile.count == 1 { found.bookmarks = perProfile[0].1 }
        else { found.bookmarks = perProfile.map { .folder(title: $0.0, children: $0.1) } }
        let (history, problems) = chromiumHistory(profiles: profiles.map(\.url))
        found.history = history
        found.problems = problems
        return found
    }

    static func chromiumBookmarks(_ file: URL) -> [ImportedNode] {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        func node(_ any: Any, depth: Int) -> ImportedNode? {
            guard depth < 30, let n = any as? [String: Any] else { return nil }
            let title = (n["name"] as? String) ?? ""
            if n["type"] as? String == "url" {
                guard let url = n["url"] as? String, isImportable(url) else { return nil }
                return .tab(title: title, customTitle: nil, url: url)
            }
            let kids = (n["children"] as? [Any] ?? []).compactMap { node($0, depth: depth + 1) }
            return kids.isEmpty ? nil : .folder(title: title.nonEmpty ?? "Folder", children: kids)
        }
        func children(_ key: String) -> [ImportedNode] {
            ((roots[key] as? [String: Any])?["children"] as? [Any] ?? []).compactMap { node($0, depth: 0) }
        }
        var out = children("bookmark_bar")
        let other = children("other")
        if !other.isEmpty { out.append(.folder(title: "Other Bookmarks", children: other)) }
        let mobile = children("synced")
        if !mobile.isEmpty { out.append(.folder(title: "Mobile Bookmarks", children: mobile)) }
        return out
    }

    static func chromiumHistory(profiles: [URL]) -> ([History.Entry], [String]) {
        var entries: [History.Entry] = []
        var problems: [String] = []
        for p in profiles {
            let db = p.appendingPathComponent("History")
            guard exists(db) else { continue }
            do {
                try SQLiteCopy.query(db, """
                    SELECT url, title, visit_count, last_visit_time FROM urls
                    WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(historyLimit)
                    """) { row in
                    guard let url = row.text(0), isImportable(url) else { return }
                    // Microseconds since 1601-01-01.
                    let date = Date(timeIntervalSince1970: Double(row.int(3)) / 1_000_000 - 11_644_473_600)
                    entries.append(.init(url: url, title: row.text(1) ?? "", visits: max(1, Int(row.int(2))), last: date))
                }
            } catch {
                problems.append("History from \(p.lastPathComponent) couldn’t be read.")
            }
        }
        return (newest(entries), problems)
    }

    /// Duplicates folded together (larger count, later date), newest first, at most `historyLimit`.
    static func newest(_ entries: [History.Entry]) -> [History.Entry] {
        var byURL: [String: History.Entry] = [:]
        for e in entries {
            if var old = byURL[e.url] {
                old.visits += e.visits
                if e.last > old.last { old.last = e.last; if !e.title.isEmpty { old.title = e.title } }
                byURL[e.url] = old
            } else {
                byURL[e.url] = e
            }
        }
        return Array(byURL.values.sorted { $0.last > $1.last }.prefix(historyLimit))
    }

    // MARK: Firefox, Zen

    /// The profile the browser opens by default: profiles.ini's [Install…] Default=, else the one marked Default=1,
    /// else the profile with the largest places.sqlite.
    static func firefoxProfile(_ root: URL) -> URL? {
        if exists(root.appendingPathComponent("places.sqlite")) { return root }
        guard let ini = try? String(contentsOf: root.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return nil }
        var sections: [(name: String, values: [String: String])] = []
        for raw in ini.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { sections.append((String(line.dropFirst().dropLast()), [:])); continue }
            guard let eq = line.firstIndex(of: "="), !sections.isEmpty else { continue }
            sections[sections.count - 1].values[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        func resolve(_ path: String?, relative: Bool = true) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            let url = relative ? root.appendingPathComponent(path, isDirectory: true) : URL(fileURLWithPath: path, isDirectory: true)
            return exists(url.appendingPathComponent("places.sqlite")) ? url : nil
        }
        if let install = sections.first(where: { $0.name.hasPrefix("Install") }), let hit = resolve(install.values["Default"]) { return hit }
        let profiles = sections.filter { $0.name.hasPrefix("Profile") }
        if let def = profiles.first(where: { $0.values["Default"] == "1" }),
           let hit = resolve(def.values["Path"], relative: def.values["IsRelative"] != "0") { return hit }
        let all = profiles.compactMap { resolve($0.values["Path"], relative: $0.values["IsRelative"] != "0") }
        func size(_ u: URL) -> Int { (try? u.appendingPathComponent("places.sqlite").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return all.max { size($0) < size($1) }
    }

    static func readFirefox(_ root: URL, name: String) throws -> ImportFound {
        guard let profile = firefoxProfile(root) else {
            throw ImportError.wrongFolder("That folder doesn’t look like \(name)’s: no profile with bookmarks was found in it.")
        }
        let db = profile.appendingPathComponent("places.sqlite")
        var found = ImportFound()
        struct Row { let id: Int64; let type: Int64; let parent: Int64; let title: String; let url: String?; let guid: String }
        var rows: [Row] = []
        do {
            try SQLiteCopy.query(db, """
                SELECT b.id, b.type, b.parent, IFNULL(b.title, ''), p.url, IFNULL(b.guid, '') FROM moz_bookmarks b
                LEFT JOIN moz_places p ON b.fk = p.id ORDER BY b.parent, b.position
                """) { r in
                rows.append(Row(id: r.int(0), type: r.int(1), parent: r.int(2), title: r.text(3) ?? "", url: r.text(4), guid: r.text(5) ?? ""))
            }
            try SQLiteCopy.query(db, """
                SELECT url, IFNULL(title, ''), visit_count, last_visit_date FROM moz_places
                WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
                ORDER BY last_visit_date DESC LIMIT \(historyLimit)
                """) { r in
                guard let url = r.text(0), isImportable(url) else { return }
                // Microseconds since 1970.
                found.history.append(.init(url: url, title: r.text(1) ?? "", visits: Int(r.int(2)),
                                           last: Date(timeIntervalSince1970: Double(r.int(3)) / 1_000_000)))
            }
        } catch {
            throw ImportError.unreadable("\(name)’s bookmarks database couldn’t be read. Quit \(name) and try again.")
        }
        var kids: [Int64: [Row]] = [:]
        for r in rows { kids[r.parent, default: []].append(r) }
        func build(_ parent: Int64, depth: Int) -> [ImportedNode] {
            guard depth < 30 else { return [] }
            return (kids[parent] ?? []).compactMap { r in
                switch r.type {
                case 1:
                    guard let url = r.url, isImportable(url) else { return nil }
                    return .tab(title: r.title, customTitle: nil, url: url)
                case 2:
                    let inner = build(r.id, depth: depth + 1)
                    return inner.isEmpty ? nil : .folder(title: r.title.nonEmpty ?? "Folder", children: inner)
                default: return nil
                }
            }
        }
        func rootID(_ guid: String) -> Int64? { rows.first { $0.guid == guid }?.id }
        if let bar = rootID("toolbar_____") { found.bookmarks += build(bar, depth: 0) }
        for (guid, title) in [("menu________", "Bookmarks Menu"), ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks")] {
            if let id = rootID(guid) {
                let inner = build(id, depth: 0)
                if !inner.isEmpty { found.bookmarks.append(.folder(title: title, children: inner)) }
            }
        }
        return found
    }

    // MARK: Safari

    static func readSafari(_ root: URL) throws -> ImportFound {
        // A picked exported file works here too.
        if root.pathExtension.lowercased().hasPrefix("htm") { return try readBookmarksFile(root) }
        var found = ImportFound()
        let plist = root.appendingPathComponent("Bookmarks.plist")
        let history = root.appendingPathComponent("History.db")
        guard let data = try? Data(contentsOf: plist) else {
            if exists(plist) || root.lastPathComponent == "Safari" {
                throw ImportError.unreadable("macOS kept Safari’s folder private. In Safari, choose File ▸ Export ▸ Bookmarks…, then pick that file with “Bookmarks File” here.")
            }
            throw ImportError.wrongFolder("That folder doesn’t look like Safari’s. Safari keeps its data in Library ▸ Safari.")
        }
        if let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            func node(_ d: [String: Any], depth: Int) -> ImportedNode? {
                guard depth < 30 else { return nil }
                switch d["WebBookmarkType"] as? String {
                case "WebBookmarkTypeLeaf":
                    guard let url = d["URLString"] as? String, isImportable(url) else { return nil }
                    let title = (d["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                    return .tab(title: title, customTitle: nil, url: url)
                case "WebBookmarkTypeList":
                    let kids = (d["Children"] as? [[String: Any]] ?? []).compactMap { node($0, depth: depth + 1) }
                    return kids.isEmpty ? nil : .folder(title: (d["Title"] as? String)?.nonEmpty ?? "Folder", children: kids)
                default: return nil
                }
            }
            for child in obj["Children"] as? [[String: Any]] ?? [] {
                let title = child["Title"] as? String
                guard let n = node(child, depth: 0) else { continue }
                switch (title, n) {
                case ("BookmarksBar", .folder(_, let kids)): found.bookmarks.insert(contentsOf: kids, at: 0)
                case ("BookmarksMenu", .folder(_, let kids)): found.bookmarks.append(.folder(title: "Bookmarks Menu", children: kids))
                case ("com.apple.ReadingList", .folder(_, let kids)): found.bookmarks.append(.folder(title: "Reading List", children: kids))
                default: found.bookmarks.append(n)
                }
            }
        }
        if exists(history) {
            do {
                try SQLiteCopy.query(history, """
                    SELECT i.url, IFNULL(v.title, ''), i.visit_count, MAX(v.visit_time) FROM history_items i
                    JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY 4 DESC LIMIT \(historyLimit)
                    """) { r in
                    guard let url = r.text(0), isImportable(url) else { return }
                    found.history.append(.init(url: url, title: r.text(1) ?? "", visits: max(1, Int(r.int(2))),
                                               last: Date(timeIntervalSinceReferenceDate: r.double(3))))
                }
            } catch {
                found.problems.append("Safari’s history couldn’t be read.")
            }
        }
        return found
    }

    // MARK: Exported bookmarks (Netscape HTML, which every browser writes)

    static func readBookmarksFile(_ file: URL) throws -> ImportFound {
        guard let data = try? Data(contentsOf: file) else { throw ImportError.unreadable("That file couldn’t be opened.") }
        let html = String(decoding: data, as: UTF8.self)
        let nodes = parseNetscape(html)
        guard !nodes.isEmpty else {
            throw ImportError.wrongFolder("No bookmarks were found in that file. It should be an .html file exported from a browser’s bookmarks.")
        }
        var found = ImportFound()
        found.bookmarks = nodes
        return found
    }

    static func parseNetscape(_ html: String) -> [ImportedNode] {
        guard let re = try? NSRegularExpression(
            pattern: #"<h3([^>]*)>(.*?)</h3>|<a\s([^>]*)>(.*?)</a>|<dl[^>]*>|</dl>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        struct Frame { var title: String?; var flatten: Bool; var items: [ImportedNode] = [] }
        var stack: [Frame] = []
        var pending: (title: String, flatten: Bool)?
        var top: [ImportedNode] = []
        func group(_ r: NSRange, in m: NSTextCheckingResult) -> String? {
            r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range).lowercased()
            if let title = group(m.range(at: 2), in: m) {
                let attrs = (group(m.range(at: 1), in: m) ?? "").uppercased()
                pending = (decodeEntities(stripTags(title)), attrs.contains("PERSONAL_TOOLBAR_FOLDER"))
            } else if let attrs = group(m.range(at: 3), in: m) {
                guard let href = attribute("href", in: attrs), isImportable(href) else { continue }
                let tab = ImportedNode.tab(title: decodeEntities(stripTags(group(m.range(at: 4), in: m) ?? "")), customTitle: nil, url: href)
                if stack.isEmpty { top.append(tab) } else { stack[stack.count - 1].items.append(tab) }
            } else if token.hasPrefix("<dl") {
                stack.append(Frame(title: pending?.title, flatten: pending?.flatten ?? false))
                pending = nil
            } else if let frame = stack.popLast() {
                // The outermost list, or the browser's toolbar folder, dissolves into its parent.
                let parentItems: [ImportedNode]
                if frame.title == nil || frame.flatten { parentItems = frame.items }
                else if frame.items.isEmpty { parentItems = [] }
                else { parentItems = [.folder(title: frame.title!.nonEmpty ?? "Folder", children: frame.items)] }
                if stack.isEmpty { top.append(contentsOf: parentItems) } else { stack[stack.count - 1].items.append(contentsOf: parentItems) }
            }
        }
        // An unclosed list still counts.
        while let frame = stack.popLast() {
            let items = (frame.title == nil || frame.flatten) ? frame.items : (frame.items.isEmpty ? [] : [.folder(title: frame.title!, children: frame.items)])
            if stack.isEmpty { top.append(contentsOf: items) } else { stack[stack.count - 1].items.append(contentsOf: items) }
        }
        return top
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: .caseInsensitive),
              let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)) else { return nil }
        for i in [2, 3] where m.range(at: i).location != NSNotFound {
            return decodeEntities((attrs as NSString).substring(with: m.range(at: i)))
        }
        return nil
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let digits = ns.substring(with: m.range(at: 2))
                if let n = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(n) { result.append(Character(scalar)) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Browsers keep their databases open (and locked) while running, so each one is copied to a private temporary
/// folder first and read from there; the copy is deleted straight after.
enum SQLiteCopy {
    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    }

    static func query(_ db: URL, _ sql: String, row: (Row) -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sorrel-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(db.lastPathComponent)
        try fm.copyItem(at: db, to: copy)
        // The write-ahead log or journal holds the newest changes.
        for suffix in ["-wal", "-journal"] {
            let side = URL(fileURLWithPath: db.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw ImportError.unreadable("database")
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(Row(stmt: stmt)); continue }
            if rc == SQLITE_DONE { break }
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
    }
}

// MARK: - Bringing it into Sorrel

enum Importer {
    /// Merges what was found into the sidebar. A space with the same name as an existing one is filled in rather
    /// than duplicated, folders with the same name merge, and a page already in that space (or already a
    /// favorite) is skipped, so importing twice adds nothing new.
    static func apply(_ found: ImportFound, from source: BrowserSource, choice: ImportChoice, store: Store) -> ImportSummary {
        var summary = ImportSummary()
        var newSpaces: [Space] = []
        var profiles: [String: UUID] = [:]
        var presetIndex = store.spaces.count

        func space(named name: String, icon: String, theme: Theme?) -> (Space, isNew: Bool) {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let s = (store.spaces + newSpaces).first(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key }) {
                return (s, false)
            }
            let t = theme ?? Theme.presets[presetIndex % Theme.presets.count]
            presetIndex += 1
            let s = Space(name: name, icon: icon, theme: t)
            newSpaces.append(s)
            return (s, true)
        }

        func note(_ s: Space, isNew: Bool, added: Int) {
            guard added > 0 || isNew else { return }
            if summary.firstSpace == nil { summary.firstSpace = s }
        }

        if source.kind == .arc, choice.spaces || choice.openTabs {
            for imported in found.spaces {
                let wantsPinned = choice.spaces && !imported.pinned.isEmpty
                let wantsToday = choice.openTabs && !imported.today.isEmpty
                guard wantsPinned || wantsToday || (choice.spaces && imported.pinned.isEmpty && imported.today.isEmpty) else { continue }
                let (s, isNew) = space(named: imported.name, icon: imported.icon, theme: imported.theme)
                if isNew, let key = imported.profileKey {
                    s.profileID = profiles[key] ?? UUID()
                    profiles[key] = s.profileID
                }
                var seen = Set(store.tabs(in: s.pinned + s.today).compactMap { $0.pinnedURL ?? $0.url })
                var added = 0
                if wantsPinned { added += build(imported.pinned, pinned: true, into: &s.pinned, seen: &seen) }
                if wantsToday { added += build(imported.today.flatMap(\.flatTabs), pinned: false, into: &s.today, seen: &seen) }
                summary.tabsAdded += added
                if isNew { summary.spacesAdded += 1 } else if added > 0 { summary.spacesMerged += 1 }
                note(s, isNew: isNew, added: added)
            }
        }

        var favorites: [Item] = []
        if choice.favorites, !found.favorites.isEmpty {
            var seen = Set(store.favorites.compactMap { $0.pinnedURL ?? $0.url })
            summary.favoritesAdded = build(found.favorites.flatMap(\.flatTabs), pinned: true, into: &favorites, seen: &seen)
        }

        if choice.bookmarks, !found.bookmarks.isEmpty {
            let (s, isNew) = space(named: source.kind == .bookmarksFile ? "Bookmarks" : source.name, icon: "🔖", theme: nil)
            var seen = Set(store.tabs(in: s.pinned + s.today).compactMap { $0.pinnedURL ?? $0.url })
            let added = build(found.bookmarks, pinned: true, into: &s.pinned, seen: &seen)
            summary.tabsAdded += added
            if isNew { summary.spacesAdded += 1 } else if added > 0 { summary.spacesMerged += 1 }
            note(s, isNew: isNew, added: added)
        }

        // Spaces that would arrive empty (say, every page was already there) aren't worth adding.
        newSpaces.removeAll { s in
            let empty = s.pinned.isEmpty && s.today.isEmpty
            if empty { summary.spacesAdded -= 1; if summary.firstSpace === s { summary.firstSpace = nil } }
            return empty
        }
        store.absorbImport(spaces: newSpaces, favorites: favorites)

        if choice.history, !found.history.isEmpty {
            summary.historyAdded = History.shared.merge(found.history)
        }
        return summary
    }

    /// Turns nodes into sidebar items appended to `list`; returns how many tabs were added.
    @discardableResult
    static func build(_ nodes: [ImportedNode], pinned: Bool, into list: inout [Item], seen: inout Set<String>) -> Int {
        var added = 0
        func tab(_ title: String, _ custom: String?, _ url: String) -> Item? {
            guard seen.insert(url).inserted else { return nil }
            let item = Item(url: url, title: title)
            item.customTitle = custom
            if pinned { item.pinnedURL = url }
            added += 1
            return item
        }
        for n in nodes {
            switch n {
            case .tab(let title, let custom, let url):
                if let item = tab(title, custom, url) { list.append(item) }
            case .folder(let title, let kids):
                guard pinned else {
                    added += build(kids.flatMap(\.flatTabs), pinned: false, into: &list, seen: &seen)
                    continue
                }
                if let existing = list.first(where: { $0.isFolder && $0.title == title }) {
                    added += build(kids, pinned: true, into: &existing.children, seen: &seen)
                } else {
                    let folder = Item.folder(named: title)
                    folder.expanded = false
                    added += build(kids, pinned: true, into: &folder.children, seen: &seen)
                    if !folder.children.isEmpty { list.append(folder) }
                }
            case .split(let kids):
                let tabs = kids.flatMap(\.flatTabs).compactMap { t -> Item? in
                    if case .tab(let title, let custom, let url) = t { return tab(title, custom, url) }
                    return nil
                }
                if (2...SplitLayout.maxPanes).contains(tabs.count) {
                    let sv = Item()
                    sv.split = SplitLayout()
                    sv.children = tabs
                    list.append(sv)
                } else {
                    list.append(contentsOf: tabs)
                }
            }
        }
        return added
    }
}
