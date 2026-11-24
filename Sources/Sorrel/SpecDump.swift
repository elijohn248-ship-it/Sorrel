import AppKit
import CryptoKit

/// SORREL_SPECDUMP=<scratch dir>: the fixtures in spec/fixtures/ (spec/README.md). Runs Birch's real Swift functions
/// on synthetic inputs (example.* hosts, made-up spaces) inside the test build's scratch profile and writes one JSON
/// file per area. A few decisions live inside WebKit delegate callbacks that can't be called on their own; those
/// cases say "transcribed" in their `source` and still use the real helper functions for every comparison. Never
/// reads a real profile; logs file names and case counts only.
enum SpecDump {
    static let specVersion = "1.0.0"

    private typealias Case = [String: Any]
    private typealias Log = (String) -> Void

    static func run(dir path: String, app: AppDelegate, log: @escaping (String) -> Void) {
        guard isTestBuild, isTestProfile else { log("specdump: refused (test build with SORREL_HOME only)"); return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = app.main.store
        let seed = seedShape(store)   // first, before any scenario touches the fresh profile
        savedState(dir, seed: seed, log)
        settings(dir, log)
        archiveAndHistory(dir, log)
        keybindings(dir, log)
        bangs(dir, log)
        resolver(dir, log)
        urlCleaner(dir, log)
        site(dir, log)
        httpsFirst(dir, log)
        theme(dir, log)
        tabLifecycle(dir, store, log)
        splitView(dir, store, log)
        recency(dir, store, log)
        peek(dir, log)
        log("specdump: done version=\(specVersion)")
    }

    // MARK: - Output helpers

    private static func value(_ v: Any?) -> Any { v ?? NSNull() }

    private static func parse(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? NSNull()
    }

    private static func object<T: Encodable>(_ v: T) -> Any {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(v)).map(parse) ?? NSNull()
    }

    private static func bytes(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data("null".utf8)
    }

    private static func write(_ file: String, area: String, sources: [String], notes: [String] = [],
                              cases: [Case], extra: [String: Any] = [:], to dir: URL, _ log: Log) {
        var doc: [String: Any] = ["spec_version": specVersion, "fixture": file, "area": area,
                                  "generated_by": "SORREL_SPECDUMP (Sources/Sorrel/SpecDump.swift)",
                                  "sources": sources, "notes": notes, "cases": cases]
        for (k, v) in extra { doc[k] = v }
        guard let out = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            log("specdump: \(file).json FAILED to serialize"); return
        }
        try? (out + Data("\n".utf8)).write(to: dir.appendingPathComponent(file + ".json"), options: .atomic)
        log("specdump: \(file).json cases=\(cases.count)")
    }

    /// A decoding error as "keyNotFound expanded at spaces[0].today[0]" (informative; editions match only the kind).
    private static func describe(_ error: Error) -> String {
        func path(_ keys: [CodingKey]) -> String {
            keys.map { k in k.intValue.map { "[\($0)]" } ?? "." + k.stringValue }.joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        guard let d = error as? DecodingError else { return "error" }
        switch d {
        case .keyNotFound(let key, let ctx): return "keyNotFound \(key.stringValue) at \(path(ctx.codingPath))"
        case .typeMismatch(let type, let ctx): return "typeMismatch \(type) at \(path(ctx.codingPath))"
        case .valueNotFound(let type, let ctx): return "valueNotFound \(type) at \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx): return "dataCorrupted at \(path(ctx.codingPath))"
        @unknown default: return "decodingError"
        }
    }

    private static func decoded<T: Codable>(_ type: T.Type, _ data: Data) -> [String: Any] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let v = try dec.decode(type, from: data)
            return ["decodes": true, "error": NSNull(), "reencoded": object(v)]
        } catch {
            return ["decodes": false, "error": describe(error), "reencoded": NSNull()]
        }
    }

    private static func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: - Saved data: state.json

    private static func seedShape(_ store: Store) -> [String: Any] {
        let s = store.spaces
        guard let home = s.first else { return [:] }
        return ["space_count": s.count, "name": home.name, "icon": home.icon, "theme": object(home.theme),
                "profileID": value(home.profileID?.uuidString), "pinned_count": home.pinned.count,
                "today": home.today.map { ["url": value($0.url), "title": $0.title] },
                "selected_is_first_today_tab": home.selectedID == home.today.first?.id && store.selected === home.today.first,
                "favorites_count": store.favorites.count, "current_space_is_home": store.currentSpace === home]
    }

    private static func tab(_ n: Int, _ title: String, _ url: String, pinned: Bool = false) -> Item {
        let t = Item(url: url, title: title)
        t.id = uuid(n)
        t.lastActive = date("2026-11-20T09:30:00Z")
        if pinned { t.pinnedURL = url }
        return t
    }

    private static func savedState(_ dir: URL, seed: [String: Any], _ log: Log) {
        // A file as Birch writes it (Store.saveNow): every kind of item, theme and window record.
        let a1 = tab(11, "Docs", "https://docs.example/start", pinned: true)
        let f = Item.folder(named: "Reading"); f.id = uuid(12); f.lastActive = date("2026-11-20T09:30:00Z"); f.expanded = false
        let a2 = tab(13, "Paper", "https://journal.example/paper/1", pinned: true)
        a2.customTitle = "Must read"
        let a3 = tab(14, "Notes", "https://notes.example/", pinned: true)
        f.children = [a2, a3]
        let ps = Item(); ps.id = uuid(15); ps.lastActive = date("2026-11-20T09:30:00Z")
        ps.split = SplitLayout(stacked: true, fractions: [0.6, 0.4])
        ps.children = [tab(16, "Mail", "https://mail.example/", pinned: true), tab(17, "Calendar", "https://cal.example/", pinned: true)]
        let t1 = tab(18, "Search", "https://search.example/?q=birch")
        let us = Item(); us.id = uuid(19); us.lastActive = date("2026-11-20T09:30:00Z")
        us.split = SplitLayout()
        us.children = [tab(20, "Left", "https://left.example/"), tab(21, "Right", "https://right.example/"), tab(22, "", "birch://welcome")]
        let spA = Space(name: "Study", icon: "📚", theme: Theme(colors: ["#8978F9", "#6CBAD9"], angle: 315, intensity: 0.8, grain: 0.5, brightness: 0.25))
        spA.id = uuid(1)
        spA.pinned = [a1, f, ps]
        spA.today = [t1, us]
        spA.profileID = uuid(90)
        spA.selectedID = t1.id
        let spB = Space(name: "Home", icon: "🏠", theme: Theme(colors: ["#34E895"], angle: 300, intensity: 0.8))
        spB.id = uuid(2)
        spB.today = [tab(23, "Welcome to Birch", "birch://welcome")]
        let fav = tab(30, "Favorite", "https://fav.example/", pinned: true)
        let w1 = BrowserWindowState(id: uuid(80), currentSpaceID: spA.id, selections: [spA.id: t1.id])
        let w2 = BrowserWindowState(id: uuid(81), currentSpaceID: spB.id, selections: [spB.id: uuid(23)])
        let state = AppState(spaces: [spA, spB], favorites: [fav], currentSpaceID: spA.id, windows: [w1, w2],
                             sidebarCollapsed: false, sidebarWidth: 262)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]   // Store.saveNow's settings
        guard let written = try? enc.encode(state), let base = parse(written) as? [String: Any] else {
            log("specdump: state encode failed"); return
        }

        func variant(_ change: (inout [String: Any]) -> Void) -> [String: Any] { var o = base; change(&o); return o }
        func space0(_ o: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            var spaces = o["spaces"] as? [[String: Any]] ?? []
            change(&spaces[0])
            o["spaces"] = spaces
        }
        func firstToday(_ o: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            space0(&o) { sp in
                var today = sp["today"] as? [[String: Any]] ?? []
                change(&today[0])
                sp["today"] = today
            }
        }
        func todaySplit(_ o: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            space0(&o) { sp in
                var today = sp["today"] as? [[String: Any]] ?? []
                var split = today[1]["split"] as? [String: Any] ?? [:]
                change(&split)
                today[1]["split"] = split
                sp["today"] = today
            }
        }
        func theme0(_ o: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
            space0(&o) { sp in var th = sp["theme"] as? [String: Any] ?? [:]; change(&th); sp["theme"] = th }
        }

        var inputs: [(String, Any)] = [
            ("as written by Store.saveNow", base),
            ("no windows key (file from before multiple windows)", variant { $0["windows"] = nil }),
            ("windows null", variant { $0["windows"] = NSNull() }),
            ("windows empty array", variant { $0["windows"] = [] }),
            ("no sidebarWidth", variant { $0["sidebarWidth"] = nil }),
            ("no sidebarCollapsed", variant { $0["sidebarCollapsed"] = nil }),
            ("no version", variant { $0["version"] = nil }),
            ("tab without expanded", variant { firstToday(&$0) { $0["expanded"] = nil } }),
            ("tab without children", variant { firstToday(&$0) { $0["children"] = nil } }),
            ("tab without isFolder", variant { firstToday(&$0) { $0["isFolder"] = nil } }),
            ("tab without title", variant { firstToday(&$0) { $0["title"] = nil } }),
            ("tab without lastActive", variant { firstToday(&$0) { $0["lastActive"] = nil } }),
            ("tab without url and pinnedURL", variant { firstToday(&$0) { $0["url"] = nil; $0["pinnedURL"] = nil } }),
            ("tab customTitle null", variant { firstToday(&$0) { $0["customTitle"] = NSNull() } }),
            ("lastActive with fractional seconds", variant { firstToday(&$0) { $0["lastActive"] = "2026-11-20T09:30:00.250Z" } }),
            ("lastActive with +01:00 offset", variant { firstToday(&$0) { $0["lastActive"] = "2026-11-20T10:30:00+01:00" } }),
            ("lastActive as a number", variant { firstToday(&$0) { $0["lastActive"] = 785_323_800 } }),
            ("id not a UUID", variant { firstToday(&$0) { $0["id"] = "tab-1" } }),
            ("id lowercase UUID", variant { firstToday(&$0) { $0["id"] = "00000000-0000-4000-8000-0000000000aa" } }),
            ("theme without grain and brightness", variant { theme0(&$0) { $0["grain"] = nil; $0["brightness"] = nil } }),
            ("theme grain null", variant { theme0(&$0) { $0["grain"] = NSNull() } }),
            ("theme without intensity", variant { theme0(&$0) { $0["intensity"] = nil } }),
            ("theme with no colors", variant { theme0(&$0) { $0["colors"] = [] } }),
            ("split without fractions", variant { todaySplit(&$0) { $0["fractions"] = nil } }),
            ("split without stacked", variant { todaySplit(&$0) { $0["stacked"] = nil } }),
            ("split as empty object", variant { todaySplit(&$0) { $0 = [:] } }),
            ("space without profileID and selectedID", variant { space0(&$0) { $0["profileID"] = nil; $0["selectedID"] = nil } }),
            ("space without icon", variant { space0(&$0) { $0["icon"] = nil } }),
            ("space without pinned", variant { space0(&$0) { $0["pinned"] = nil } }),
            ("unknown keys everywhere", variant { o in
                o["futureField"] = ["x": 1]
                space0(&o) { $0["futureSpaceField"] = true }
                firstToday(&o) { $0["interactionState"] = "opaque" }
            }),
            ("no spaces", variant { $0["spaces"] = [] }),
            ("currentSpaceID names no space", variant { $0["currentSpaceID"] = uuid(999).uuidString }),
            ("window selections as a JSON object", variant { o in
                o["windows"] = [["id": uuid(80).uuidString, "currentSpaceID": uuid(1).uuidString,
                                 "selections": [uuid(1).uuidString: uuid(18).uuidString]]]
            }),
        ]
        var cases: [Case] = []
        for (name, json) in inputs {
            let data = bytes(json)
            var expected = decoded(AppState.self, data)
            let usable = (expected["decodes"] as? Bool == true) && ((json as? [String: Any])?["spaces"] as? [Any])?.isEmpty == false
            expected["store_on_launch"] = usable ? "use" : "seed fresh profile; copy file to state.unreadable-<unix time>.json"
            cases.append(["name": name, "input": ["state_json": json], "expected": expected])
        }
        inputs = []
        for (name, text) in [("not JSON", "{\"spaces\": ["), ("empty file", "")] {
            var expected = decoded(AppState.self, Data(text.utf8))
            expected["store_on_launch"] = "seed fresh profile; copy file to state.unreadable-<unix time>.json"
            cases.append(["name": name, "input": ["state_json_text": text], "expected": expected])
        }
        let sources = ["Models.swift AppState/Space/Item/SplitLayout/BrowserWindowState Codable (JSONDecoder, iso8601 dates)",
                       "store_on_launch: transcribed from Store.init (Models.swift): decode failure or no spaces -> seed + backup"]
        write("state-decode", area: "saved-data", sources: sources,
              notes: ["reencoded uses sorted keys; Birch writes the same keys unsorted and pretty-printed (Store.saveNow)."],
              cases: cases, extra: ["written_by_birch": base], to: dir, log)

        // Derived values from the real types.
        var derived: [Case] = []
        var nextID = 500
        func pin(_ item: Item) {
            item.id = uuid(nextID); nextID += 1
            item.lastActive = date("2026-11-20T09:30:00Z")
            item.children.forEach(pin)
        }
        func titleCase(_ name: String, _ item: Item) {
            pin(item)
            derived.append(["name": "displayTitle: " + name, "input": ["item": object(item)], "expected": ["displayTitle": item.displayTitle]])
        }
        let ct = Item(url: "https://a.example/", title: "Page"); ct.customTitle = "Mine"; titleCase("customTitle wins", ct)
        let ect = Item(url: "https://a.example/", title: "Page"); ect.customTitle = ""; titleCase("empty customTitle ignored", ect)
        titleCase("title", Item(url: "https://a.example/", title: "Page"))
        titleCase("no title: host", Item(url: "https://www.a.example/x", title: ""))
        titleCase("no title, no host", Item(url: "about:blank", title: ""))
        titleCase("no url", Item())
        let ef = Item.folder(named: ""); titleCase("folder without name", ef)
        titleCase("folder", Item.folder(named: "Reading"))
        let sv = Item(); sv.split = SplitLayout(); sv.children = [Item(url: "https://a.example/", title: "A"), Item(url: "https://b.example/x", title: "")]
        titleCase("split joins panes", sv)
        for (fr, n) in [([Double](), 2), ([1.0, 3.0], 2), ([0.5, 0.5], 3), ([0.2, 0, 0.8], 3), ([2.0, 1.0, 1.0], 3), ([-1.0, 2.0], 2), ([1.0], 0)] {
            let l = SplitLayout(stacked: false, fractions: fr)
            derived.append(["name": "SplitLayout.normalized \(fr) count \(n)", "input": ["fractions": fr, "count": n],
                            "expected": ["normalized": l.normalized(count: n)]])
        }
        for u in ["birch://welcome", "sorrel://welcome", "drift://welcome", "birch://", "Birch://welcome", "https://birch.example/", "sorrel-insecure:continue"] {
            derived.append(["name": "BundledPage \(u)", "input": ["address": u],
                            "expected": ["isBundled": BundledPage.isBundled(u), "current": BundledPage.current(u)]])
        }
        // Engine.load: a bundled name loads only if it is a plain name (transcribed regex, Web.swift).
        for name in ["welcome", "spec-1", "../etc/passwd", "Welcome", "a/b", "", "welcome.html", "a b"] {
            derived.append(["name": "bundled name \"\(name)\"", "input": ["name": name],
                            "expected": ["plain_name_allowed": name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil],
                            "source": "transcribed: Engine.load name check (Web.swift)"])
        }
        derived.append(["name": "fresh profile seed", "input": ["profile": "empty"], "expected": seed,
                        "source": "real: Store.profile on a fresh SORREL_HOME (Store.seed)"])
        write("state-derived", area: "saved-data",
              sources: ["Item.displayTitle, SplitLayout.normalized, BundledPage (real)", "Store.seed via a fresh profile (real)"],
              cases: derived, to: dir, log)
    }

    // MARK: - Saved data: settings.json

    private static func settings(_ dir: URL, _ log: Log) {
        let defaults = object(Settings()) as? [String: Any] ?? [:]
        let fromEmpty = (try? JSONDecoder().decode(Settings.self, from: Data("{}".utf8))).map { object($0) } as? [String: Any] ?? [:]
        var fields: [Case] = []
        for child in Mirror(reflecting: Settings()).children {
            guard let name = child.label else { continue }
            fields.append(["name": name, "input": ["field": name],
                           "expected": ["swift_type": "\(type(of: child.value))", "default": value(defaults[name]),
                                        "decoded_when_missing": value(fromEmpty[name])]])
        }
        write("settings-fields", area: "saved-data", sources: ["Support.swift Settings() and Settings.init(from:) (real)"],
              notes: ["default = a new profile's value; decoded_when_missing = what a settings.json without the key decodes to (before Settings.load's migration)."],
              cases: fields, to: dir, log)

        let original = try? Data(contentsOf: Paths.settings)
        let inputs: [(String, String?)] = [
            ("empty object", "{}"),
            ("version 1 with the old 8 pt reveal strip", #"{"settingsVersion":1,"sidebarHoverEdgeWidth":8}"#),
            ("version 1 with a customised reveal strip", #"{"settingsVersion":1,"sidebarHoverEdgeWidth":10}"#),
            ("no version, 8 pt reveal strip", #"{"sidebarHoverEdgeWidth":8}"#),
            ("version 2, 8 pt reveal strip kept", #"{"settingsVersion":2,"sidebarHoverEdgeWidth":8}"#),
            ("custom search engine", #"{"settingsVersion":2,"searchEngineName":"Kagi","searchEngineURL":"https://kagi.com/search?q=%s"}"#),
            ("integer for a Double field", #"{"settingsVersion":2,"sleepTabsAfterMinutes":30,"archiveAfterHours":0}"#),
            ("null value", #"{"settingsVersion":2,"blockAds":null}"#),
            ("empty list kept empty", #"{"settingsVersion":2,"peekExcludedSites":[]}"#),
            ("unknown key ignored", #"{"settingsVersion":2,"someFutureSetting":true}"#),
            ("wrong type for one field", #"{"settingsVersion":2,"httpsFirst":"yes","blockAds":false}"#),
            ("extension maps", #"{"settingsVersion":2,"extensionStates":{"ubol":false},"extensionGrants":{"x":["perm:tabs"]},"extensionApproved":{"x":["match:<all_urls>"]}}"#),
            ("not JSON", "{\"blockAds\": "),
            ("file missing", nil),
        ]
        var cases: [Case] = []
        for (name, text) in inputs {
            var expected: [String: Any] = [:]
            if let text {
                let raw = Data(text.utf8)
                do { expected["decoded"] = object(try JSONDecoder().decode(Settings.self, from: raw)); expected["decode_error"] = NSNull() }
                catch { expected["decoded"] = NSNull(); expected["decode_error"] = describe(error) }
                try? raw.write(to: Paths.settings, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: Paths.settings)
            }
            expected["loaded"] = object(Settings.load())
            let after = try? Data(contentsOf: Paths.settings)
            expected["file_rewritten"] = text.map { after != Data($0.utf8) } ?? (after != nil)
            expected["file_after_load"] = after.map(parse) ?? NSNull()
            cases.append(["name": name, "input": ["settings_json_text": value(text)], "expected": expected])
        }
        if let original { try? original.write(to: Paths.settings, options: .atomic) }
        write("settings-decode", area: "saved-data", sources: ["Support.swift Settings.init(from:) and Settings.load() against the scratch profile's settings.json (real)"],
              notes: ["loaded is what Birch runs with; file_after_load is settings.json afterwards (Settings.load rewrites it when it migrates or cannot read it)."],
              cases: cases, to: dir, log)
    }

    // MARK: - Saved data: archive.json and history.json

    private static func archiveAndHistory(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        let archived = [ArchivedTab(url: "https://a.example/old", title: "Old page", spaceID: uuid(1), date: date("2026-11-19T08:00:00Z")),
                        ArchivedTab(url: "https://b.example/", title: "", spaceID: uuid(2), date: date("2026-11-18T23:59:59Z"))]
        let aenc = JSONEncoder(); aenc.dateEncodingStrategy = .iso8601   // Store.saveArchive
        let awritten = (try? aenc.encode(archived)).map(parse) ?? NSNull()
        let archiveInputs: [(String, Any)] = [
            ("as written by Store.saveArchive", awritten),
            ("entry without title", [["url": "https://a.example/", "spaceID": uuid(1).uuidString, "date": "2026-11-19T08:00:00Z"]]),
            ("entry with fractional-second date", [["url": "https://a.example/", "title": "", "spaceID": uuid(1).uuidString, "date": "2026-11-19T08:00:00.5Z"]]),
            ("empty list", [Any]()),
        ]
        for (name, json) in archiveInputs {
            cases.append(["name": "archive.json: " + name, "input": ["archive_json": json], "expected": decoded([ArchivedTab].self, bytes(json))])
        }
        let entries = [History.Entry(url: "https://a.example/page?x=1", title: "A page", visits: 3, last: date("2026-11-20T12:00:00Z"))]
        let hwritten = (try? aenc.encode(entries)).map(parse) ?? NSNull()
        let historyInputs: [(String, Any)] = [
            ("as written by History.saveNow", hwritten),
            ("entry without visits", [["url": "https://a.example/", "title": "", "last": "2026-11-20T12:00:00Z"]]),
            ("visits as a Double", [["url": "https://a.example/", "title": "", "visits": 2.5, "last": "2026-11-20T12:00:00Z"]]),
        ]
        for (name, json) in historyInputs {
            cases.append(["name": "history.json: " + name, "input": ["history_json": json], "expected": decoded([History.Entry].self, bytes(json))])
        }
        write("archive-history-decode", area: "saved-data",
              sources: ["Models.swift ArchivedTab, Data.swift History.Entry Codable (real, iso8601)"],
              notes: ["A history.json or archive.json that fails to decode is treated as empty and overwritten on the next save."],
              cases: cases, to: dir, log)

        // History behaviour on the real History.shared (cleared before and after).
        let h = History.shared
        h.clear()
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        let seeded: [(String, String, Int, Double)] = [
            ("https://swift.example/", "Swift home", 40, 1),
            ("https://swift.example/docs/strings", "Strings in Swift", 2, 3),
            ("https://www.swiftly.example/", "Swiftly", 1, 30),
            ("https://news.example/today", "Morning news", 9, 0.5),
            ("https://docs.example/swift/guide", "A Swift guide", 5, 10),
            ("https://bbc.co.uk/news", "BBC", 3, 2),
            ("https://www.bbc.co.uk/sport", "BBC Sport", 1, 4),
            ("https://old.example/", "Old", 1, 400),
        ]
        h.merge(seeded.map { History.Entry(url: $0.0, title: $0.1, visits: $0.2, last: ago($0.3)) })
        var hc: [Case] = []
        let seededInput = seeded.map { ["url": $0.0, "title": $0.1, "visits": $0.2, "days_ago": $0.3] }
        func urls(_ list: [History.Entry]) -> [String] { list.map(\.url) }
        hc.append(["name": "list all, newest first", "input": ["history": seededInput, "query": "", "limit": 5],
                   "expected": ["urls": urls(h.list(limit: 5))]])
        hc.append(["name": "list matching every word in url or title", "input": ["history": seededInput, "query": "swift GUIDE", "limit": 10],
                   "expected": ["urls": urls(h.list(matching: "swift GUIDE", limit: 10))]])
        for q in ["swift", "sw", "bbc", "news", "Swift Strings", "nothing-here"] {
            hc.append(["name": "search ranking \"\(q)\"", "input": ["history": seededInput, "query": q, "limit": 10],
                       "expected": ["urls": urls(h.search(q, limit: 10))]])
        }
        for q in ["sw", "s", "swi", "bbc", "news ", "nothing"] {
            hc.append(["name": "topHostMatch \"\(q)\"", "input": ["history": seededInput, "text": q],
                       "expected": ["url": value(h.topHostMatch(q)?.url)]])
        }
        // Merging (browser import): larger visit count, later date, existing title kept unless empty.
        h.merge([History.Entry(url: "https://swift.example/", title: "Imported title", visits: 7, last: ago(0.1)),
                 History.Entry(url: "https://new.example/", title: "New", visits: 1, last: ago(5))])
        let merged = h.list(matching: "swift.example/", limit: 1).first
        hc.append(["name": "merge keeps the larger visits, the later date and the existing title",
                   "input": ["existing": ["url": "https://swift.example/", "title": "Swift home", "visits": 40, "days_ago": 1],
                             "imported": ["url": "https://swift.example/", "title": "Imported title", "visits": 7, "days_ago": 0.1]],
                   "expected": ["title": value(merged?.title), "visits": value(merged?.visits),
                                "last_is_imported_date": merged.map { abs($0.last.timeIntervalSince(ago(0.1))) < 1 } ?? false,
                                "count_after": h.count]])
        h.record(url: URL(string: "file:///tmp/x.html")!, title: "File")
        h.record(url: URL(string: "birch://welcome")!, title: "Welcome")
        h.record(url: URL(string: "https://news.example/today")!, title: "")
        let news = h.list(matching: "news.example/today", limit: 1).first
        hc.append(["name": "record: only http(s), visits +1, empty title keeps the old one",
                   "input": ["record": ["file:///tmp/x.html", "birch://welcome", "https://news.example/today (title \"\")"]],
                   "expected": ["count": h.count, "news_visits": value(news?.visits), "news_title": value(news?.title)]])
        hc.append(["name": "remove site (registrable part)", "input": ["site": "bbc.co.uk"],
                   "expected": ["removed": h.remove(site: "bbc.co.uk"), "count_after": h.count]])
        hc.append(["name": "remove older than 300 days", "input": ["days": 300],
                   "expected": ["removed": h.remove(olderThan: ago(300)), "count_after": h.count]])
        hc.append(["name": "remove since 2 days ago", "input": ["days": 2],
                   "expected": ["removed": h.remove(since: ago(2)), "remaining": urls(h.list(limit: 50))]])
        h.clear()
        // Cap: more than 20,000 pages keep the newest 15,000 when saved.
        h.merge((0..<20001).map { History.Entry(url: "https://cap.example/\($0)", title: "", visits: 1, last: ago(Double($0) / 1000)) })
        h.saveNow()
        hc.append(["name": "cap on save", "input": ["pages": 20001, "newest_first_index": "0"],
                   "expected": ["count_after_save": h.count, "newest_kept": value(h.list(limit: 1).first?.url),
                                "oldest_kept": value(h.list(limit: 20001).last?.url)]])
        h.clear()
        write("history-behaviour", area: "saved-data",
              sources: ["Data.swift History list/search/topHostMatch/merge/record/remove/saveNow on History.shared (real)"],
              notes: ["days_ago is relative to the moment the edition seeds the entries.",
                      "search score = ln(visits+1)*2 + max(0, 5 - days/7), +6 if the host without \"www.\" starts with the first word, +4 more if the path is \"/\" or empty."],
              cases: hc, to: dir, log)
    }

    // MARK: - Keybindings

    private static func keybindings(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        let kb = Keybindings.shared
        let defaultsFile = (try? Data(contentsOf: Paths.keybindingDefaults)).map(parse) ?? NSNull()
        cases.append(["name": "keybindings.default.json", "input": ["launch": "fresh profile"],
                      "expected": ["file": defaultsFile, "user_file_created": (try? String(contentsOf: Paths.keybindings, encoding: .utf8)) ?? NSNull()]])
        for s in ["cmd+t", "Cmd+Shift+T", "shift+cmd+t", "command+option+x", "meta+x", "super+x", "control+alt+del", "opt+a",
                  "cmd++", "cmd+plus", "cmd+=", "cmd+return", "esc", "ctrl+backspace", "hyper+x", "cmd+", "+", "", "CTRL+TAB", "alt+cmd+left"] {
            cases.append(["name": "normalize stroke \"\(s)\"", "input": ["stroke": s],
                          "expected": ["normalized": value(Keybindings.normalize(stroke: s.lowercased())), "pretty": Keybindings.pretty(Keybindings.normalize(stroke: s.lowercased()) ?? "")]])
        }
        for s in ["cmd+k cmd+t", "  Cmd+K   cmd+T ", "cmd+k hyper+x", "cmd+k"] {
            cases.append(["name": "normalize sequence \"\(s)\"", "input": ["sequence": s], "expected": ["normalized": Keybindings.normalize(sequence: s)]])
        }
        let original = try? Data(contentsOf: Paths.keybindings)
        let queries = ["cmd+t", "shift+cmd+t", "shift+cmd+k", "shift+cmd+c", "ctrl+tab", "cmd+s", "ctrl+alt+j"]   // normalized strokes
        let commands = ["tab.new", "tab.reopen", "tab.copyURL", "sidebar.toggle", "tab.cycleNext", "theme.edit"]
        func effective() -> [String: Any] {
            var single: [String: Any] = [:]
            for q in queries { single[q] = value(kb.command(onStroke: q)) }
            var all: [String: Any] = [:]
            for c in commands { all[c] = kb.displayAll(for: c) }
            return ["command_on_stroke": single, "display_all": all]
        }
        let userFiles: [(String, String)] = [
            ("empty user file", "{\n}\n"),
            ("same as a default", #"{"cmd+shift+c": "tab.copyURL"}"#),
            ("add a binding (any case)", #"{"Cmd+Shift+K": "tab.copyURL"}"#),
            ("null removes a default", #"{"cmd+t": null}"#),
            ("empty string removes a default", #"{"cmd+t": ""}"#),
            ("same keys in another order replace the default", #"{"shift+cmd+t": "tab.new"}"#),
            ("new chord", #"{"cmd+k cmd+s": "sidebar.toggle"}"#),
            ("invalid modifier ignored", #"{"hyper+s": "tab.new"}"#),
            ("not JSON: defaults only", "{\"cmd+t\": "),
        ]
        for (name, text) in userFiles {
            try? Data(text.utf8).write(to: Paths.keybindings, options: .atomic)
            kb.reload()
            cases.append(["name": "keybindings.json: " + name, "input": ["keybindings_json_text": text], "expected": effective()])
        }
        try? Data("{\n}\n".utf8).write(to: Paths.keybindings, options: .atomic)
        kb.reload()
        for (stroke, command, label) in [("ctrl+alt+j" as String?, "tab.cycleNext", "remap to a new stroke"),
                                         (nil, "tab.reopen", "no shortcut"),
                                         ("cmd+t", "tab.new", "set the default stroke again")] {
            kb.setShortcut(stroke, for: command)
            let file = (try? Data(contentsOf: Paths.keybindings)).map(parse) ?? NSNull()
            var exp = effective()
            exp["user_file_after"] = file
            cases.append(["name": "Settings ▸ Shortcuts: " + label, "input": ["stroke": value(stroke), "command": command, "applied_after_previous_case": true],
                          "expected": exp])
        }
        kb.resetAll()
        cases.append(["name": "Settings ▸ Shortcuts: reset all", "input": ["reset": true],
                      "expected": ["user_file_after": (try? Data(contentsOf: Paths.keybindings)).map(parse) ?? NSNull()]])
        if let original { try? original.write(to: Paths.keybindings, options: .atomic) }
        kb.reload()
        let registry = Commands.shared.all.map { ["id": $0.id, "title": $0.title] }
        write("keybindings", area: "saved-data",
              sources: ["Commands.swift Keybindings.defaults/normalize/pretty/reload/setShortcut/displayAll/command(onStroke:) (real)",
                        "Commands.shared.all after launch (real)"],
              notes: ["Mac modifiers: cmd = Command. Editions on other platforms document their own mapping; the grammar and file format are shared."],
              cases: cases, extra: ["commands": registry], to: dir, log)
    }

    // MARK: - Bangs

    private static func bangMatch(_ text: String) -> Any {
        guard let m = Bangs.shared.resolve(text) else { return ["matched": false] }
        return ["matched": true, "trigger": m.bang.trigger, "name": m.bang.name, "query": m.query, "url": m.url.absoluteString]
    }

    private static func bangs(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        for text in ["!w cats", "cats !w", "!W Cats", "!yt  two   spaces", "!g", "!gh swift-format", "hello !nosuchbang",
                     "!", "!! x", "a@b.example !g", "!a c++ & stuff", "!wp hello world", "!bunpro x y", "!archived https://a.example/a b",
                     "!ют test", "!g café ünïcode", "!g 50% off #1 a+b=c?", "!g !yt x", "!G", "  !reddit   swift  ", "!imdb",
                     "!gmaps 1 Main St, Springfield", "!caniuse :has()", "!ddg privacy", "!w"] {
            cases.append(["name": "bundled \"\(text)\"", "input": ["text": text], "expected": bangMatch(text)])
        }
        let original = try? Data(contentsOf: Paths.bangs)
        let custom = """
        [
          {"t": "spec", "s": "Spec Search", "u": "https://search.example/?q=%s"},
          {"t": "g", "s": "Override", "u": "https://override.example/find?q={{{s}}}"},
          {"t": "specpath", "u": "https://docs.example/{{{s}}}/index"},
          {"t": "specplus", "s": "Plus", "u": "https://plus.example/{{{s}}}", "fmt": ["url_encode_space_to_plus"]},
          {"t": "specnoplus", "s": "No plus", "u": "https://np.example/?q={{{s}}}", "fmt": ["open_base_path"]},
          {"t": "SpecCase", "ts": ["sc1", "SC2"], "s": "Case", "u": "https://case.example/?q={{{s}}}"},
          {"t": "specd", "s": "With d", "d": "other.example", "u": "https://d.example/?q={{{s}}}"},
          {"s": "missing t", "u": "https://x.example/?q={{{s}}}"},
          {"t": "specnou", "s": "missing u"}
        ]
        """
        try? Data(custom.utf8).write(to: Paths.bangs, options: .atomic)
        Bangs.shared.reload()
        for text in ["!spec a b", "!spec", "!g cats", "!google cats", "!specpath a b", "!specpath", "!specplus a b", "!specnoplus a b",
                     "!speccase x", "!SC1 x", "!sc2 x", "!specd x", "!specd", "!specnou x"] {
            cases.append(["name": "custom \"\(text)\"", "input": ["custom_bangs_json": parse(Data(custom.utf8)), "text": text], "expected": bangMatch(text)])
        }
        try? Data("[\n]".utf8).write(to: Paths.bangs, options: .atomic)
        Bangs.shared.reload()
        try? Data("[ {\"t\": ".utf8).write(to: Paths.bangs, options: .atomic)
        Bangs.shared.reload()
        cases.append(["name": "custom file that is not JSON is ignored", "input": ["custom_bangs_json_text": "[ {\"t\": ", "text": "!g cats"],
                      "expected": bangMatch("!g cats")])
        if let original { try? original.write(to: Paths.bangs, options: .atomic) } else { try? Data("[\n]".utf8).write(to: Paths.bangs, options: .atomic) }
        Bangs.shared.reload()

        // Every bundled trigger, resolved by the real code; the digest lets an edition check its whole table at once.
        var triggers: Set<String> = []
        if let url = Bundle.main.url(forResource: "bangs", withExtension: "json"), let data = try? Data(contentsOf: url),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for e in list {
                guard let t = e["t"] as? String, e["u"] is String else { continue }
                for trig in [t] + ((e["ts"] as? [String]) ?? []) { triggers.insert(trig.lowercased()) }
            }
        }
        var lines = ""
        for t in triggers.sorted() {
            let q = Bangs.shared.resolve("!\(t) a b&c/é")?.url.absoluteString ?? "-"
            let e = Bangs.shared.resolve("!\(t)")?.url.absoluteString ?? "-"
            lines += "\(t)\t\(q)\t\(e)\n"
        }
        try? Data(lines.utf8).write(to: dir.appendingPathComponent("bangs-all.tsv"), options: .atomic)
        let digest = SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
        let table: [String: Any] = ["bundled_file": "Resources/bangs.json", "table_size": Bangs.shared.count, "trigger_count": triggers.count,
                                    "query": "a b&c/é",
                                    "line_format": "<trigger>\\t<url for \"!<trigger> a b&c/é\">\\t<url for \"!<trigger>\">\\n, triggers sorted by Swift String order (Unicode scalar order), \"-\" when no URL",
                                    "sha256": digest]
        write("bangs", area: "address-and-search",
              sources: ["Data.swift Bangs.reload/ingest/resolve on Bangs.shared (real; custom file in the scratch profile)"],
              notes: ["bangs-all.tsv (not committed) is regenerated by the hook; its sha256 is table.sha256."],
              cases: cases, extra: ["table": table], to: dir, log)
    }

    // MARK: - Resolver, URL cleaning, Site, HTTPS-first

    private static let typed = [
        "example.com", "Example.COM/Path?q=1#x", "  example.com  ", "example", "localhost", "localhost:3000/x", "LOCALHOST",
        "localhost.example", "192.168.1.1", "192.168.1.1:8080/admin", "999.1.1.1", "10.0.0.1/", "1.2.3", "http://foo",
        "HTTPS://Example.com", "https://example.com/a b", "file:///etc/hosts", "birch://welcome", "sorrel://welcome",
        "drift://welcome", "about:blank", "about:config", "javascript:alert(1)", "data:text/html,hi", "mailto:a@b.example",
        "user@example.com", "sub.domain.co.uk", "xn--bcher-kva.de", "bücher.de", "example.c", "example.com:8080",
        "foo.bar:99999", "what is swift", "swift.org docs", "1.5", "3.14", "a.b", "node.js", "readme.md", "my-site.dev/",
        "my_site.dev", "-x.com", "ex ample.com", "", "   ", "?q", "#tag", "c++", "100%", "a&b", "😀", "日本語", "Ünïcode test",
        "example.com/path with space", "www.example.com", "example.com.", "EXAMPLE.museum", "a.b.c.d.e.f.example",
        "example.com/?q=a b", "example.com\t", "chrome://settings", "ftp://files.example/",
    ]

    private static func resolver(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        for t in typed {
            cases.append(["name": "typed \"\(t)\"", "input": ["text": t, "search_engine_url": Settings.current.searchEngineURL],
                          "expected": ["url_from_typed": value(Resolver.url(fromTyped: t)?.absoluteString),
                                       "destination": Resolver.destination(for: t).absoluteString]])
        }
        let saved = Settings.current.searchEngineURL
        for engine in ["https://kagi.com/search?q=%s", "https://search.example/find/%s/results", "not a url %s", "https://noplaceholder.example/"] {
            Settings.current.searchEngineURL = engine
            for q in ["swift strings", "a+b & c", "café"] {
                var c: Case = ["name": "search with \(engine) for \"\(q)\"", "input": ["query": q, "search_engine_url": engine],
                               "expected": ["search_url": Resolver.searchURL(q).absoluteString]]
                if engine.hasPrefix("not a url") { c["informative"] = "Foundation's URL(string:) percent-encodes an invalid template; editions need not copy this" }
                cases.append(c)
            }
        }
        Settings.current.searchEngineURL = saved
        write("resolver", area: "address-and-search",
              sources: ["Data.swift Resolver.url(fromTyped:), searchURL, destination(for:) (real; bundled bangs, empty custom file)"],
              notes: ["destination = bang, else address, else search with the default engine (DuckDuckGo)."],
              cases: cases, to: dir, log)
    }

    private static func urlCleaner(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        let urls = [
            "https://a.example/?utm_source=x&utm_medium=y&id=5", "https://a.example/?id=5", "https://a.example/",
            "https://a.example/?fbclid=abc", "https://a.example/?UTM_Source=x&Keep=1", "https://a.example/?gclid",
            "https://a.example/?fbclid=", "https://a.example/?a=1&&b=2&gclid=3", "https://a.example/p?utm_x=1#frag",
            "https://a.example/?utm%5Fsource=x", "https://a.example/?pk_campaign=1&mtm_x=2&piwik_y=3&_hsenc=4&mc_eid=5",
            "https://www.youtube.com/watch?v=abc&si=xyz", "https://youtu.be/abc?si=xyz", "https://open.spotify.com/track/1?si=xyz",
            "https://music.youtube.com/watch?v=1&si=2", "https://notyoutube.com/?si=1", "https://a.example/?si=1",
            "http://a.example/?utm_source=x", "ftp://a.example/?utm_source=x", "https://a.example/?q=a%20b&utm_source=x",
            "https://a.example/?q=a+b&fbclid=1", "https://a.example/?srsltid=1&li_fat_id=2&igshid=3", "https://a.example/?utm_source=1&utm_source=2&x=1",
            "https://A.EXAMPLE/?SI=1&Si=2", "https://a.example/?ref=hn",
        ]
        for u in urls {
            cases.append(["name": u, "input": ["url": u],
                          "expected": ["cleaned": value(URL(string: u).flatMap(URLCleaner.clean)?.absoluteString)]])
        }
        write("url-cleaner", area: "address-and-search", sources: ["Data.swift URLCleaner.clean (real)"],
              notes: ["cleaned null = nothing to remove (Birch then loads the address unchanged)."],
              cases: cases, to: dir, log)
    }

    private static func site(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        let hosts = ["example.com", "www.example.com", "a.b.example.com", "bbc.co.uk", "www.bbc.co.uk", "news.bbc.co.uk",
                     "example.co", "a.example.co", "foo.com.au", "x.gov.uk", "x.edu.au", "x.ac.jp", "localhost", "192.168.1.1",
                     "EXAMPLE.COM", "", "xn--bcher-kva.de", "a.b.c.d.net.nz", "uk", "co.uk"]
        for h in hosts {
            cases.append(["name": "key \"\(h)\"", "input": ["host": h], "expected": ["key": value(Site.key(h))]])
        }
        cases.append(["name": "key nil", "input": ["host": NSNull()], "expected": ["key": value(Site.key(nil))]])
        for h in ["www.example.com", "WWW.Example.com", "www2.example.com", "pwww.aypal.com", "example.www.com", "www.", "www", "example.com",
                  "www.www.example.com", "paypal.com.secure-login.evil.example"] {
            cases.append(["name": "display \"\(h)\"", "input": ["host": h], "expected": ["display": value(Site.display(h))]])
        }
        let list = Settings().peekExcludedSites + ["duckduckgo.com"]
        for h in ["www.google.com", "google.co.uk", "scholar.google.com", "notgoogle.com", "googleblog.com", "kagi.com", "app.kagi.com",
                  "evilkagi.com", "duckduckgo.com", "html.duckduckgo.com", "search.brave.com", "brave.com", "en.wikipedia.org",
                  "bing.com", "www.bing.com", "yahoo.co.jp", "perplexity.ai", "www.perplexity.ai", "baidu.com", "BING.COM"] {
            cases.append(["name": "on excluded list \"\(h)\"", "input": ["host": h, "list": list], "expected": ["is_in": Site.host(h, isIn: list)]])
        }
        for (h, l) in [("a.example", [" A.EXAMPLE "]), ("a.example", [""]), ("", ["a.example"]), ("google.com", ["Google"]), ("x.google.com", ["google.com"])] {
            cases.append(["name": "on list \(l) \"\(h)\"", "input": ["host": h, "list": l], "expected": ["is_in": Site.host(h, isIn: l)]])
        }
        for (a, b) in [("example.com", "www.example.com"), ("a.example.com", "b.example.com"), ("bbc.co.uk", "news.bbc.co.uk"),
                       ("example.com", "example.org"), ("a.co.uk", "b.co.uk"), ("example.com", ""), ("localhost", "localhost")] {
            cases.append(["name": "same \"\(a)\" \"\(b)\"", "input": ["a": a, "b": b], "expected": ["same": Site.same(a, b)]])
        }
        // What the address box shows (Sidebar refreshNavigation, transcribed) from the tab's saved address,
        // using the real Item.host (Foundation URL), Site.display and BundledPage.
        for u in ["https://www.example.com/a?b=c", "http://example.com/", "https://аpple.example/", "https://bücher.example/x",
                  "https://xn--bcher-kva.example/", "https://paypal.com.secure-login.evil.example/", "birch://welcome",
                  "sorrel://welcome", "about:blank", "file:///tmp/a.html", "https://WWW.EXAMPLE.COM/", "http://192.168.1.1:8080/",
                  "https://user:pass@example.com/", "https://例え.jp/", "https://www.xn--80ak6aa92e.com/"] {
            let item = Item(url: u, title: "")
            let text: String?
            var copy = false, insecure = false
            if BundledPage.isBundled(u) { text = "Birch" } else {
                text = Site.display(item.host) ?? item.url
                copy = u.hasPrefix("http")
                insecure = item.host != nil && u.lowercased().hasPrefix("http://")
            }
            cases.append(["name": "address box for \(u)", "input": ["url": u],
                          "expected": ["host": value(item.host), "text": value(text), "can_copy": copy, "not_secure_lock": insecure],
                          "source": "transcribed: Sidebar.refreshNavigation; real Item.host, Site.display, BundledPage.isBundled"])
        }
        write("site", area: "address-and-search",
              sources: ["Peek.swift Site.key/host(_:isIn:)/display/same (real)", "Models.swift Item.host (real Foundation URL parsing)"],
              notes: ["Long hosts are cut at the front in the address box (head truncation), so the registrable end always shows; that is layout, not a fixture."],
              cases: cases, to: dir, log)
    }

    private static func httpsFirst(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        let urls = ["http://example.com", "http://example.com:80/x?y=1", "http://example.com:8080/", "http://localhost/",
                    "http://router.local/", "http://printer.lan/", "http://dev.test/", "http://x.internal/", "http://nas.home/",
                    "http://1.0.168.192.in-addr.arpa/", "http://site.example/", "http://x.invalid/", "http://my.localhost/",
                    "http://192.168.1.1/", "http://[::1]/", "http://[2001:db8::1]:80/", "http://intranet/", "http://EXAMPLE.COM/",
                    "http://xn--bcher-kva.de/", "http://a.b.c.d.co.uk/", "http://example.com./", "http://1.2.3.4.nip.io/",
                    "http://localtest.me/", "http://example.com:443/", "http://user@example.com/", "https://example.com/"]
        for u in urls {
            guard let url = URL(string: u) else { continue }
            let can = Engine.canUpgrade(url)
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            if comps?.port == 80 { comps?.port = nil }
            cases.append(["name": u, "input": ["url": u],
                          "expected": ["can_upgrade": can, "upgraded_url": can && url.scheme == "http" ? value((comps?.url ?? url).absoluteString) : NSNull()],
                          "source": "real: Engine.canUpgrade; upgraded_url transcribed from Engine decidePolicyFor (Web.swift)"])
        }
        write("https-first", area: "address-and-search",
              sources: ["Web.swift Engine.canUpgrade (real)", "upgrade rewrite transcribed: scheme -> https, explicit port 80 dropped"],
              notes: ["Applies only to main-frame GET navigations to http:// with Settings.httpsFirst on and the host not allowed this session (see address-and-search.md)."],
              cases: cases, to: dir, log)
    }

    // MARK: - Space colours

    private static func rgb(_ c: NSColor) -> [Double] {
        let s = c.usingColorSpace(.sRGB) ?? c
        return [Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent)]
    }

    private static func lab(_ l: OKLab) -> [Double] { [l.L, l.a, l.b] }

    private static func themeCase(_ name: String, _ json: [String: Any], dark: Bool) -> Case? {
        guard let theme = try? JSONDecoder().decode(Theme.self, from: bytes(json)) else {
            return ["name": name, "input": ["theme": json, "dark": dark], "expected": ["decodes": false]]
        }
        let resolved = theme.resolvedColors(systemIsDark: dark)
        let stops = theme.gradientStops(dark: dark)
        return ["name": name, "input": ["theme": json, "dark": dark],
                "expected": ["decodes": true,
                             "soft_oklab": theme.softLabs(dark: dark).map(lab),
                             "resolved_srgb": resolved.map(rgb), "resolved_hex": resolved.map(\.hexString),
                             "resolved_luminance": resolved.map { Double($0.luminance) },
                             "is_dark": theme.isDark(systemIsDark: dark),
                             "stops_srgb": stops.map(rgb), "stops_hex": stops.map(\.hexString),
                             "grain_amount": theme.grainAmount, "grain_opacity": Double(Grain.opacity(theme.grainAmount)),
                             "grain_layer_hidden": theme.grainAmount <= 0.001,
                             "brightness_amount": theme.brightnessAmount]]
    }

    private static func theme(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        for (i, preset) in Theme.presets.enumerated() {
            for b in [nil, 0.5, 1.0] as [Double?] {
                var t = preset; t.brightness = b
                guard let json = object(t) as? [String: Any] else { continue }
                for dark in [false, true] {
                    if let c = themeCase("preset \(i) brightness \(b.map { "\($0)" } ?? "nil") \(dark ? "dark" : "light")", json, dark: dark) { cases.append(c) }
                }
            }
        }
        let custom: [(String, [String: Any])] = [
            ("grey (no chroma)", ["colors": ["#808080"], "angle": 0, "intensity": 1]),
            ("black", ["colors": ["#000000"], "angle": 0, "intensity": 1]),
            ("white", ["colors": ["#FFFFFF"], "angle": 0, "intensity": 1]),
            ("three colours", ["colors": ["#FF0000", "#00FF00", "#0000FF"], "angle": 90, "intensity": 0.6]),
            ("invalid hex dropped", ["colors": ["#GGGGGG", "12345", "#FE6F3E"], "angle": 315, "intensity": 0.8]),
            ("no valid colours", ["colors": ["nope"], "angle": 315, "intensity": 0.8]),
            ("no colours", ["colors": [String](), "angle": 315, "intensity": 0.8]),
            ("hex forms", ["colors": ["fe6f3e", " #FE6F3E "], "angle": 315, "intensity": 0.8]),
            ("intensity above 1", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 1.5]),
            ("intensity below 0", ["colors": ["#FE6F3E"], "angle": 315, "intensity": -0.2]),
            ("intensity 0", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 0]),
            ("grain 0", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 0.8, "grain": 0]),
            ("grain 1", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 0.8, "grain": 1]),
            ("grain 2 clamps", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 0.8, "grain": 2]),
            ("grain -1 clamps", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 0.8, "grain": -1]),
            ("grain null", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 0.8, "grain": NSNull()]),
            ("brightness 2 clamps", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 1, "brightness": 2]),
            ("brightness -1 clamps", ["colors": ["#FE6F3E"], "angle": 315, "intensity": 1, "brightness": -1]),
            ("vivid out of gamut at full brightness", ["colors": ["#00FFFF", "#FF00FF"], "angle": 45, "intensity": 1, "brightness": 1]),
            ("missing angle", ["colors": ["#FE6F3E"], "intensity": 0.8]),
        ]
        for (name, json) in custom {
            for dark in [false, true] { if let c = themeCase(name + (dark ? " dark" : " light"), json, dark: dark) { cases.append(c) } }
        }
        write("theme", area: "space-colours",
              sources: ["ThemeLook.swift Theme.soften/softLabs/gradientStops, Support.swift Theme.resolvedColors/isDark, Grain.opacity (real)"],
              notes: ["Compare floats with an absolute tolerance of 1e-6; hex may differ by 1 in a channel only where the float sits within 1e-6 of a rounding edge."],
              cases: cases, to: dir, log)

        // The pieces: hex parsing, OKLab both ways, the soft bases, blending and the grain tile.
        var math: [Case] = []
        for h in ["#FE6F3E", "fe6f3e", " #8978F9 ", "#FFF", "#GGGGGG", "", "#12345678", "##FE6F3E"] {
            math.append(["name": "hex \"\(h)\"", "input": ["hex": h], "expected": ["srgb": value(NSColor(hex: h).map(rgb)), "hex": value(NSColor(hex: h)?.hexString)]])
        }
        for h in ["#FFFFFF", "#000000", "#FF0000", "#00FF00", "#0000FF", "#808080", "#FE6F3E", "#8978F9", "#6CBAD9", "#34E895"] {
            math.append(["name": "srgb -> oklab \(h)", "input": ["hex": h], "expected": ["oklab": lab(OKLab(NSColor(hex: h)!))]])
        }
        for l in [[0.7, 0.1, 0.1], [0.7, 0.3, 0.3], [0.5, -0.4, 0.1], [1.2, 0, 0], [-0.1, 0, 0], [0.9, 0.2, -0.3], [0.62, 0.22, 0.12]] {
            let c = OKLab(L: l[0], a: l[1], b: l[2]).color
            math.append(["name": "oklab -> srgb \(l)", "input": ["oklab": l], "expected": ["srgb": rgb(c), "hex": c.hexString]])
        }
        math.append(["name": "soft bases", "input": ["dark": [false, true]],
                     "expected": ["light": lab(Theme.softBase(dark: false)), "dark": lab(Theme.softBase(dark: true))]])
        for (h, inten, dark, br) in [("#FE6F3E", 1.0, false, 0.0), ("#FE6F3E", 1.0, true, 0.0), ("#FE6F3E", 0.5, true, 0.5), ("#2B3A67", 0.95, true, 0.0)] {
            math.append(["name": "soften \(h) intensity \(inten) dark \(dark) brightness \(br)", "input": ["hex": h, "intensity": inten, "dark": dark, "brightness": br],
                         "expected": ["oklab": lab(Theme.soften(NSColor(hex: h)!, intensity: inten, dark: dark, brightness: br))]])
        }
        let pairs: [(Int, Int)] = [(0, 2), (1, 8), (3, 9)]
        for (i, j) in pairs {
            for f in [0.0, 0.25, 0.5, 1.0] {
                for dark in [false, true] {
                    let stops = Theme.blendedStops(Theme.presets[i], Theme.presets[j], CGFloat(f), dark: dark)
                    math.append(["name": "blend preset \(i) -> \(j) at \(f) \(dark ? "dark" : "light")",
                                 "input": ["from": object(Theme.presets[i]), "to": object(Theme.presets[j]), "fraction": f, "dark": dark],
                                 "expected": ["stops_srgb": stops.map(rgb), "stops_hex": stops.map(\.hexString)]])
                }
            }
        }
        var grainExpected: [String: Any] = ["generated": false]
        if let cg = Grain.image.cgImage(forProposedRect: nil, context: nil, hints: nil), let raw = cg.dataProvider?.data as Data? {
            var first: [[Int]] = []
            for i in 0..<8 {
                let px: [UInt8] = [raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]]
                first.append(px.map { Int($0) })
            }
            grainExpected = ["generated": true, "width_px": cg.width, "height_px": cg.height, "size_pt": [Double(Grain.image.size.width), Double(Grain.image.size.height)],
                             "bytes_per_row": cg.bytesPerRow, "first_8_pixels_rgba_premultiplied": first,
                             "sha256_rgba": SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
                             "strength_at_grain_1": Double(Grain.strength), "default_grain": Theme.defaultGrain]
        }
        math.append(["name": "grain tile", "input": ["seed": "0x5EED50FFE1", "px": 256], "expected": grainExpected])
        write("theme-math", area: "space-colours",
              sources: ["Support.swift NSColor(hex:)/hexString; ThemeLook.swift OKLab, Theme.softBase/soften/blendedStops, Grain (real)"],
              notes: ["Same tolerance as theme.json (1e-6 absolute)."],
              cases: math, to: dir, log)
    }

    // MARK: - Live store scenarios

    /// A throwaway space in the scratch profile; tabs are labelled by title and use birch://spec-<label>, which
    /// names no bundled page, so nothing loads and nothing touches the network.
    private final class Lab {
        let store: Store
        let space: Space
        var items: [String: Item] = [:]
        init(_ store: Store, _ name: String) {
            self.store = store
            space = store.addSpace(name: name, icon: "🧪", theme: Theme.presets[0])
        }
        /// Unpinned tabs in sidebar order (newTab puts each at the top, so they are made last to first).
        @discardableResult
        func tabs(_ labels: [String], url: ((String) -> String)? = nil) -> [Item] {
            for l in labels.reversed() {
                items[l] = store.newTab(url: url?(l) ?? "birch://spec-\(l)", title: l, in: space, select: false)
            }
            return labels.compactMap { items[$0] }
        }
        subscript(_ l: String) -> Item { items[l]! }
        func shape(_ list: [Item]) -> [Any] {
            list.map { i -> Any in
                if i.isSplit { return ["split": i.children.map(\.title), "stacked": i.split?.stacked ?? false, "fractions": i.split?.fractions ?? []] }
                if i.isFolder { return ["folder": i.title, "children": shape(i.children)] }
                return i.title
            }
        }
        var snapshot: [String: Any] {
            ["pinned": shape(space.pinned), "today": shape(space.today), "favorites": store.favorites.map(\.title),
             "selected": SpecDump.value(store.selected?.title)]
        }
        func done() {
            store.switchSpace(to: space)
            for f in store.favorites where items[f.title] === f { store.toggleFavorite(f) }
            store.removeSpace(space)
        }
    }

    private static func tabLifecycle(_ dir: URL, _ store: Store, _ log: Log) {
        var cases: [Case] = []
        let now = Date()
        // Archive: unpinned tabs idle longer than the setting, except what is on screen.
        do {
            let lab = Lab(store, "Spec archive")
            let ages: [String: Double] = ["old": 25, "old-birch": 25, "recent": 1, "old-selected": 25, "s1": 25, "s2": 25, "s3": 25, "s4": 1,
                                          "old-pinned": 25, "old-favorite": 25, "old-in-folder": 25]
            lab.tabs(["old", "old-birch", "recent", "old-selected", "s1", "s2", "s3", "s4", "old-pinned", "old-favorite", "old-in-folder"]) { l in
                l == "old-birch" ? "birch://spec-\(l)" : "https://\(l).example/"
            }
            store.makeSplit(lab["s1"], with: lab["s2"], focus: lab["s1"])
            store.makeSplit(lab["s3"], with: lab["s4"], focus: lab["s3"])
            store.togglePin(lab["old-pinned"])
            store.toggleFavorite(lab["old-favorite"])
            let folder = store.addFolder(named: "Folder", in: lab.space)
            store.move(lab["old-in-folder"], to: .pinned(lab.space, folder))
            store.select(lab["old-selected"])
            for (l, h) in ages { lab[l].lastActive = now.addingTimeInterval(-h * 3600) }
            let before = lab.snapshot
            let archivedBefore = store.archive.count
            let never = store.archiveStaleTabs(olderThanHours: 0)
            let n = store.archiveStaleTabs(olderThanHours: 24)
            let added = store.archive.prefix(store.archive.count - archivedBefore).map { ["url": $0.url, "title": $0.title, "space_is_lab": $0.spaceID == lab.space.id] }
            cases.append(["name": "archive after 24 hours", "input": ["hours_idle": ages, "setting_archiveAfterHours": 24, "before": before,
                                                                     "selected": "old-selected"],
                          "expected": ["never_setting_0_archives": never, "archived_count": n, "after": lab.snapshot, "archive_entries_added_newest_first": added]])
            lab.done()
        }
        // Sleep: the 5-minute timer and memory pressure.
        let labels = ["a", "b", "c", "d", "e", "f"]
        let minutesIdle: [String: Double] = ["a": 0.1, "b": 0.5, "c": 2, "d": 4, "e": 6, "f": 200]
        func sleepRun(_ name: String, configured: Double, event: DispatchSource.MemoryPressureEvent?, eventName: String?,
                      timerMinutes: Double? = nil, select: String? = nil, playing: String? = nil, splitWith: String? = nil) {
            let lab = Lab(store, "Spec sleep")
            lab.tabs(labels)
            if let s = select, let other = splitWith { store.makeSplit(lab[s], with: lab[other], focus: lab[s]) }
            for l in labels { _ = Engine.shared.ensurePage(for: lab[l]) }
            if let s = select { store.select(lab[s]) }
            if let p = playing { lab[p].page?.mediaIsPlaying = true }
            let t0 = Date()
            for l in labels { lab[l].lastActive = t0.addingTimeInterval(-minutesIdle[l]! * 60) }
            let saved = Settings.current.sleepTabsAfterMinutes
            Settings.current.sleepTabsAfterMinutes = configured
            let n: Int
            if let event { n = Cleanup.relieveMemoryPressure(event) } else { n = store.sleepIdleTabs(olderThanMinutes: timerMinutes ?? configured) }
            Settings.current.sleepTabsAfterMinutes = saved
            var input: [String: Any] = ["minutes_idle": minutesIdle, "setting_sleepTabsAfterMinutes": configured, "trigger": eventName ?? "maintenance timer"]
            if let s = select { input["on_screen"] = splitWith.map { [s, $0] } ?? [s] }
            if let p = playing { input["playing_media"] = p }
            cases.append(["name": name, "input": input,
                          "expected": ["slept_count": n, "asleep": labels.filter { lab[$0].page == nil }, "awake": labels.filter { lab[$0].page != nil }]])
            lab.done()
        }
        for configured in [0.0, 0.25, 1, 3, 5, 10, 120] {
            for (event, ename) in [(DispatchSource.MemoryPressureEvent.normal, "normal"), (.warning, "warning"), (.critical, "critical")] {
                sleepRun("memory pressure \(ename), sleep setting \(configured) min", configured: configured, event: event, eventName: "memory pressure " + ename)
            }
        }
        sleepRun("memory pressure warning+critical together", configured: 120, event: [.warning, .critical], eventName: "memory pressure warning+critical")
        for configured in [0.0, 1, 5, 120] {
            sleepRun("maintenance timer, sleep setting \(configured) min", configured: configured, event: nil, eventName: nil)
        }
        sleepRun("tab on screen never sleeps", configured: 120, event: .critical, eventName: "memory pressure critical", select: "f")
        sleepRun("every pane of the split on screen stays awake", configured: 120, event: .critical, eventName: "memory pressure critical", select: "f", splitWith: "e")
        sleepRun("playing media never sleeps", configured: 120, event: .critical, eventName: "memory pressure critical", playing: "f")
        write("tab-lifecycle", area: "behaviour",
              sources: ["Models.swift Store.archiveStaleTabs/sleepIdleTabs/canSleep, Cleanup.swift relieveMemoryPressure (real, live scratch store)"],
              notes: ["Sleep cases use tabs with a page created but nothing loaded; canSleep also refuses pages that are loading, capturing camera/mic, in Picture in Picture or showing a non-http(s) address (see tab-lifecycle.md)."],
              cases: cases, to: dir, log)
    }

    private static func splitView(_ dir: URL, _ store: Store, _ log: Log) {
        var cases: [Case] = []
        let lab = Lab(store, "Spec split")
        lab.tabs(["a", "b", "c", "d", "e", "f", "g", "h"])
        func step(_ name: String, _ op: String, _ result: Any? = nil, extra: [String: Any] = [:]) {
            var exp: [String: Any] = ["after": lab.snapshot]
            if let result { exp["result"] = result }
            for (k, v) in extra { exp[k] = v }
            cases.append(["name": name, "input": ["operation": op, "applied_after_previous_case": true], "expected": exp])
        }
        cases.append(["name": "start", "input": ["operation": "eight unpinned tabs a…h", "applied_after_previous_case": false], "expected": ["after": lab.snapshot]])
        func made(_ v: Item?) -> Any { v.map { $0.isSplit } ?? false }
        step("split two tabs", "makeSplit(a, with: b)", made(store.makeSplit(lab["a"], with: lab["b"])))
        step("third pane joins after the base", "makeSplit(a, with: c)", made(store.makeSplit(lab["a"], with: lab["c"])))
        step("fourth pane", "makeSplit(b, with: d)", made(store.makeSplit(lab["b"], with: lab["d"])))
        step("a fifth pane is refused", "makeSplit(a, with: e)", made(store.makeSplit(lab["a"], with: lab["e"])))
        step("a tab can't split with itself", "makeSplit(e, with: e)", made(store.makeSplit(lab["e"], with: lab["e"])))
        store.toggleFavorite(lab["f"])
        step("favorite made", "toggleFavorite(f)")
        step("favorites never go in a split (as base)", "makeSplit(f, with: e)", made(store.makeSplit(lab["f"], with: lab["e"])))
        step("favorites never go in a split (as other)", "makeSplit(e, with: f)", made(store.makeSplit(lab["e"], with: lab["f"])))
        let folder = store.addFolder(named: "Box", in: lab.space)
        step("folders can't split", "canSplit(folder)", store.canSplit(folder))
        store.ungroup(folder)
        store.select(lab["c"])
        store.close(lab["c"])
        step("closing a pane of an unpinned split closes that tab", "select(c); close(c)")
        store.removeFromSplit(lab["d"])
        step("remove from split puts the tab right after the split", "removeFromSplit(d)")
        store.close(lab["b"])
        step("one tab left dissolves the split", "close(b)")
        step("stacked split, other first", "makeSplit(a, with: d, otherFirst: true, stacked: true)",
             made(store.makeSplit(lab["a"], with: lab["d"], otherFirst: true, stacked: true)))
        store.togglePin(lab["a"])
        step("pinning a pane pins the whole split", "togglePin(a)", nil,
             extra: ["pinnedURL": ["a": value(lab["a"].pinnedURL), "d": value(lab["d"].pinnedURL)]])
        _ = Engine.shared.ensurePage(for: lab["d"])
        store.select(lab["a"])
        lab["a"].url = "https://moved.example/"
        store.close(lab["a"])
        step("closing an on-screen pane of a pinned split returns it to its pinned address", "select(a); a navigated to https://moved.example/; close(a)", nil,
             extra: ["a_has_page": lab["a"].page != nil, "a_url": value(lab["a"].url)])
        store.select(lab["e"])
        lab["a"].url = "https://moved.example/"
        store.close(lab["a"])
        step("closing a pane of a pinned split that is off screen puts it to sleep", "select(e); a navigated to https://moved.example/; close(a)", nil,
             extra: ["a_has_page": lab["a"].page != nil, "a_url": value(lab["a"].url)])
        store.toggleFavorite(lab["d"])
        step("a pane made a favorite leaves the split first", "toggleFavorite(d)")
        store.toggleFavorite(lab["d"])
        step("favorite back to pinned", "toggleFavorite(d)")
        let eg = store.makeSplit(lab["e"], with: lab["g"])
        store.move(eg!, to: .favorites)
        step("a split can't become a favorite", "makeSplit(e, with: g); move(split, to: favorites)")
        store.unsplit(eg!)
        step("separate", "unsplit(split e|g)")
        let three = store.makeSplit(lab["e"], with: lab["g"])
        store.makeSplit(lab["g"], with: lab["h"])
        store.setSplitFractions(three!, [0.5, 0.3, 0.2])
        step("pane sizes", "makeSplit(e, g); makeSplit(g, h); setSplitFractions([0.5, 0.3, 0.2])")
        store.setSplitFractions(three!, [0.5, 0.5])
        step("sizes with the wrong count are ignored", "setSplitFractions([0.5, 0.5])")
        store.rotatePanes(three!)
        step("rotate panes", "rotatePanes")
        store.select(lab["g"])
        store.focusPane(offset: 1)
        step("focus next pane", "select(g); focusPane(+1)")
        store.focusPane(offset: 1)
        step("focus next pane wraps", "focusPane(+1)")
        store.makeSplit(lab["e"], with: lab["g"], stacked: true)
        step("splitting two panes already together only changes the layout", "makeSplit(e, with: g, stacked: true)")
        store.togglePin(lab["e"])
        store.closeAndUnpin(three!)
        step("× on a pinned split removes it from the sidebar", "togglePin(e); closeAndUnpin(split)")
        lab.done()
        write("split-view", area: "behaviour",
              sources: ["Models.swift Store makeSplit/close/removeFromSplit/unsplit/togglePin/toggleFavorite/move/setSplitFractions/rotatePanes/focusPane/closeAndUnpin (real, live scratch store)"],
              notes: ["Cases are one sequence: each starts from the previous case's `after`. Labels are tab titles."],
              cases: cases, to: dir, log)
    }

    private static func recency(_ dir: URL, _ store: Store, _ log: Log) {
        var cases: [Case] = []
        let previous = store.onTabCycleChanged
        var shown: [String] = []
        store.onTabCycleChanged = { shown = $0.map(\.title) }
        let savedSetting = Settings.current.controlTabUsesRecency
        let now = Date()
        // One physical Control+Tab press is cycleTab(±1, holdingControl: true); letting go of Control ends the cycle.
        func run(_ name: String, recency: Bool = true, tabs labels: [String], idleMinutes: [String: Double] = [:],
                 setup: ((Lab) -> Void)? = nil, visits: [String], steps: [String], selectAfter: [Int: String] = [:]) {
            Settings.current.controlTabUsesRecency = recency
            let lab = Lab(store, "Spec recency")
            lab.tabs(labels)
            setup?(lab)
            for l in labels { lab[l].lastActive = now.addingTimeInterval(-(idleMinutes[l] ?? 60) * 60) }
            let before = lab.snapshot
            for v in visits { store.select(lab[v]) }
            var out: [[String: Any]] = []
            for s in steps {
                shown = []
                switch s {
                case "press": store.cycleTab(1, holdingControl: true)
                case "shift-press": store.cycleTab(-1, holdingControl: true)
                case "release": store.endTabCycle()
                case "menu-next": store.cycleTab(1)
                default:
                    if s.hasPrefix("close ") { store.close(lab[String(s.dropFirst(6))]) }
                    else if s.hasPrefix("click ") { store.select(lab[String(s.dropFirst(6))]) }
                }
                out.append(["step": s, "selected": value(store.selected?.title), "switcher": shown])
            }
            store.endTabCycle()
            cases.append(["name": name, "input": ["controlTabUsesRecency": recency, "sidebar_before": before, "idle_minutes_default": 60,
                                                  "idle_minutes": idleMinutes, "visits_in_order": visits, "steps": steps],
                          "expected": ["after_each_step": out]])
            lab.done()
        }
        run("quick press and release toggles between the last two tabs", tabs: ["a", "b", "c", "d"], visits: ["a", "d", "b"],
            steps: ["press", "release", "press", "release", "press", "release"])
        run("holding Control walks a stable order and wraps", tabs: ["a", "b", "c", "d"], visits: ["a", "d", "b"],
            steps: ["press", "press", "press", "press", "release"])
        run("Shift walks back", tabs: ["a", "b", "c", "d"], visits: ["a", "d", "b"],
            steps: ["press", "press", "shift-press", "shift-press", "shift-press", "release"])
        run("tabs never visited follow by last use, ties in sidebar order", tabs: ["a", "b", "c", "d", "e"],
            idleMinutes: ["a": 30, "b": 10, "c": 30, "d": 5, "e": 30], visits: ["e"],
            steps: ["press", "press", "press", "press", "press", "release"])
        run("a click ends the held cycle", tabs: ["a", "b", "c"], visits: ["a", "c", "b"], steps: ["press", "click a", "press", "release"])
        run("a tab closed mid-cycle is skipped", tabs: ["a", "b", "c", "d"], visits: ["a", "c", "d", "b"],
            steps: ["press", "close d", "press", "release"])
        run("favorites, pinned tabs, folders and split panes all take part", tabs: ["a", "b", "c", "d", "e"], setup: { lab in
            store.toggleFavorite(lab["a"])
            store.togglePin(lab["b"])
            let folder = store.addFolder(named: "F", in: lab.space)
            store.move(lab["c"], to: .pinned(lab.space, folder))
            store.makeSplit(lab["d"], with: lab["e"], focus: lab["d"])
        }, visits: ["c", "a", "e", "b"], steps: ["press", "press", "press", "press", "press", "release"])
        run("a single tab: nothing happens", tabs: ["a"], visits: ["a"], steps: ["press", "release"])
        run("menu Next Tab uses recency without holding", tabs: ["a", "b", "c"], visits: ["a", "c", "b"], steps: ["menu-next", "menu-next"])
        run("recency off: sidebar order, wrapping", recency: false, tabs: ["a", "b", "c", "d"], visits: ["d", "a", "c"],
            steps: ["press", "press", "shift-press", "release", "click d", "press", "release"])
        Settings.current.controlTabUsesRecency = savedSetting
        store.onTabCycleChanged = previous
        write("tab-recency", area: "behaviour",
              sources: ["Models.swift Store.cycleTab/endTabCycle/select/cycleOrder (real, live scratch store)"],
              notes: ["press = Control+Tab key down (holdingControl true), shift-press = Control+Shift+Tab, release = Control let go,",
                      "menu-next = tab.cycleNext from a menu or the command bar (holdingControl false).",
                      "switcher = the order the Control+Tab switcher shows after the step ([] = hidden).",
                      "Each case is its own space; favorites are shared, so the favorites row may hold other cases' favorites only while that case runs."],
              cases: cases, to: dir, log)
    }

    // MARK: - Peek

    /// Transcribed from Engine.shouldPeek and the link branch of Engine's navigation policy (Web.swift); every
    /// site comparison is the real Site.host(_:isIn:) / Site.same with the real Settings values passed in.
    private static func peekOutcome(link: String, page: String?, pinnedURL: String?, location: String, inTab: Bool,
                                    kind: String, modifier: String?, settings s: Settings) -> String {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return "navigate" }
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) { return "ask to open another app" }
        guard kind == "link click", scheme.hasPrefix("http") else { return "navigate" }
        if modifier == "cmd" || modifier == "middle" { return "background tab" }
        guard inTab else { return "navigate" }
        if modifier == "shift" { return "peek" }
        var excluded = s.peekExcludedSites
        if let engine = URL(string: s.searchEngineURL.replacingOccurrences(of: "%s", with: "x"))?.host { excluded.append(engine) }
        let pageHost = page.flatMap { URL(string: $0)?.host }
        if Site.host(pageHost, isIn: excluded) { return "navigate" }
        let pinned = location == "pinned" || location == "favorite"
        guard s.peekLinksFromAllTabs || (s.peekLinksFromPinnedTabs && pinned) else { return "navigate" }
        let here = pageHost ?? pinnedURL.flatMap { URL(string: $0)?.host }
        guard here != nil, url.host != nil else { return "navigate" }
        return Site.same(here, url.host) ? "navigate" : "peek"
    }

    private static func peek(_ dir: URL, _ log: Log) {
        var cases: [Case] = []
        let d = Settings()
        var pinnedOnly = Settings(); pinnedOnly.peekLinksFromAllTabs = false
        var never = Settings(); never.peekLinksFromAllTabs = false; never.peekLinksFromPinnedTabs = false
        var kagi = Settings(); kagi.searchEngineURL = "https://kagi.com/search?q=%s"; kagi.peekExcludedSites = []
        let rows: [(String, String, String?, String?, String, Bool, String, String?, Settings, String)] = [
            ("other site from an unpinned tab", "https://b.example/x", "https://a.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("same site, other subdomain", "https://news.a.example/x", "https://www.a.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("same site, co.uk", "https://news.bbc.co.uk/", "https://www.bbc.co.uk/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("http link to another site", "http://b.example/", "https://a.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("shift-click on the same site", "https://a.example/2", "https://a.example/", nil, "unpinned", true, "link click", "shift", d, "all tabs (default)"),
            ("cmd-click opens a background tab", "https://b.example/", "https://a.example/", nil, "unpinned", true, "link click", "cmd", d, "all tabs (default)"),
            ("middle-click opens a background tab", "https://b.example/", "https://a.example/", nil, "unpinned", true, "link click", "middle", d, "all tabs (default)"),
            ("typed address", "https://b.example/", "https://a.example/", nil, "unpinned", true, "typed or redirect", nil, d, "all tabs (default)"),
            ("form submit", "https://b.example/", "https://a.example/", nil, "unpinned", true, "form submit", nil, d, "all tabs (default)"),
            ("script window.open", "https://b.example/", "https://a.example/", nil, "unpinned", true, "script", nil, d, "all tabs (default)"),
            ("from Google results", "https://b.example/", "https://www.google.com/search?q=x", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("from google.co.uk", "https://b.example/", "https://www.google.co.uk/search?q=x", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("from DuckDuckGo html", "https://b.example/", "https://html.duckduckgo.com/html?q=x", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("from the custom search engine", "https://b.example/", "https://kagi.com/search?q=x", nil, "unpinned", true, "link click", nil, kagi, "engine kagi.com, empty list"),
            ("from a site merely named like Google", "https://b.example/", "https://googleblog.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("pinned-only setting, unpinned tab", "https://b.example/", "https://a.example/", nil, "unpinned", true, "link click", nil, pinnedOnly, "pinned tabs and favorites only"),
            ("pinned-only setting, pinned tab", "https://b.example/", "https://a.example/", nil, "pinned", true, "link click", nil, pinnedOnly, "pinned tabs and favorites only"),
            ("pinned-only setting, favorite", "https://b.example/", "https://a.example/", nil, "favorite", true, "link click", nil, pinnedOnly, "pinned tabs and favorites only"),
            ("never setting", "https://b.example/", "https://a.example/", nil, "pinned", true, "link click", nil, never, "never"),
            ("never setting, shift-click still previews", "https://b.example/", "https://a.example/", nil, "pinned", true, "link click", "shift", never, "never"),
            ("page without an address falls back to pinnedURL", "https://b.example/", nil, "https://a.example/home", "pinned", true, "link click", nil, d, "all tabs (default)"),
            ("no page address, no pinnedURL", "https://b.example/", nil, nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("mini or private window page (not a tab)", "https://b.example/", "https://a.example/", nil, "none", false, "link click", nil, d, "all tabs (default)"),
            ("mailto link", "mailto:a@b.example", "https://a.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("javascript: link", "javascript:void(0)", "https://a.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("link with no host", "https:///nohost", "https://a.example/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("from a bundled page", "https://b.example/", "birch://welcome", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
            ("IP address to a name", "https://b.example/", "http://192.168.1.1/", nil, "unpinned", true, "link click", nil, d, "all tabs (default)"),
        ]
        for r in rows {
            let outcome = peekOutcome(link: r.1, page: r.2, pinnedURL: r.3, location: r.4, inTab: r.5, kind: r.6, modifier: r.7, settings: r.8)
            cases.append(["name": r.0, "input": ["link": r.1, "page_url": value(r.2), "pinnedURL": value(r.3), "tab_location": r.4,
                                                 "page_is_a_tab": r.5, "navigation": r.6, "modifier": value(r.7), "settings": r.9,
                                                 "peekLinksFromAllTabs": r.8.peekLinksFromAllTabs, "peekLinksFromPinnedTabs": r.8.peekLinksFromPinnedTabs,
                                                 "peekExcludedSites": r.8.peekExcludedSites, "searchEngineURL": r.8.searchEngineURL],
                          "expected": ["outcome": outcome],
                          "source": "transcribed: Engine.shouldPeek + link branch of decidePolicyFor (Web.swift); real Site.host(_:isIn:), Site.same"])
        }
        write("peek", area: "behaviour",
              sources: ["transcribed Engine.shouldPeek (WKNavigationAction can't be built outside WebKit); real Site helpers and Settings defaults"],
              notes: ["outcome: peek | navigate (in the tab) | background tab | ask to open another app."],
              cases: cases, to: dir, log)
    }
}
