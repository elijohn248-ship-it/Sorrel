import AppKit
import WebKit

// MARK: - Converting filter lists to WebKit rules

/// Turns Adblock-style filter lists (EasyList and friends) into WebKit content-blocker rules.
/// WebKit applies these natively, off the main thread, so blocking costs almost nothing while browsing.
/// What it cannot express (script injection, regex rules, a few rare options) is skipped.
enum FilterConverter {
    struct Output {
        /// Ordinary block rules.
        var block: [[String: Any]] = []
        /// Block rules that target whole pages or pop-ups; these go after the page-protecting exception.
        var pageBlock: [[String: Any]] = []
        /// "@@" exceptions.
        var exceptions: [[String: Any]] = []
        /// Element-hiding rules.
        var cosmetic: [[String: Any]] = []
        var skipped = 0
        /// One plain generic selector, used to check that hiding works.
        var sampleSelector: String?

        /// Network rules in the order WebKit needs: blocks, then the exception that keeps every
        /// top-level page and pop-up loadable, then deliberate page blocks, then the list's own exceptions.
        var network: [[String: Any]] {
            guard !block.isEmpty || !pageBlock.isEmpty else { return [] }
            let protectPages: [String: Any] = [
                "trigger": ["url-filter": ".*", "resource-type": ["top-document", "popup"]],
                "action": ["type": "ignore-previous-rules"],
            ]
            return block + [protectPages] + pageBlock + exceptions
        }
    }

    private static let typeNames: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "font": "font", "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch",
        "websocket": "websocket", "ping": "ping", "beacon": "ping", "other": "other",
        "subdocument": "child-document", "frame": "child-document",
        "object": "other", "object-subrequest": "other",
    ]
    private static let ordinaryTypes = ["script", "image", "style-sheet", "font", "media", "fetch",
                                        "websocket", "ping", "other", "child-document", "svg-document"]

    private static let unsupportedSelectorParts = [
        ":-abp-", ":has-text", ":contains", ":xpath", ":matches-", ":upward", ":remove", ":style",
        ":min-text-length", ":watch-attr", ":nth-ancestor", ":others", ":spath", ":if", "{", "+js(",
    ]

    static func convert(_ text: String) -> Output {
        var out = Output()
        var generic: [String] = []
        var genericSeen: Set<String> = []
        var genericExceptions: [String: [String]] = [:]   // selector -> domains where it must not hide
        var removedEverywhere: Set<String> = []
        var specific: [String: [String]] = [:]            // "a.com,b.com" -> selectors

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return }

            if let r = line.range(of: "#@#") {
                let selector = String(line[r.upperBound...])
                let domains = includedDomains(String(line[..<r.lowerBound])).include
                if domains.isEmpty { removedEverywhere.insert(selector) } else { genericExceptions[selector, default: []] += domains }
                return
            }
            if line.contains("#?#") || line.contains("#$#") || line.contains("#%#") || line.contains("#@?#")
                || line.contains("#@$#") || line.contains("##+js") || line.contains("##^") {
                out.skipped += 1
                return
            }
            if let r = line.range(of: "##") {
                let selector = String(line[r.upperBound...])
                guard isUsableSelector(selector) else { out.skipped += 1; return }
                let domainText = String(line[..<r.lowerBound])
                if domainText.isEmpty {
                    if genericSeen.insert(selector).inserted { generic.append(selector) }
                    return
                }
                let (include, exclude, dropped) = includedDomains(domainText)
                if !include.isEmpty {
                    specific[include.sorted().joined(separator: ","), default: []].append(selector)
                } else if !exclude.isEmpty, !dropped {
                    genericExceptions[selector, default: []] += exclude
                    if genericSeen.insert(selector).inserted { generic.append(selector) }
                } else {
                    out.skipped += 1
                }
                return
            }
            network(line, into: &out)
        }

        // Generic hiding rules. Plain ones are grouped; ones with per-site exceptions stand alone.
        var plain: [String] = []
        for selector in generic where !removedEverywhere.contains(selector) {
            if let except = genericExceptions[selector] {
                let domains = Array(Set(except)).sorted().map { "*" + $0 }
                out.cosmetic.append(hide(selector, trigger: ["url-filter": ".*", "unless-domain": domains]))
            } else {
                plain.append(selector)
            }
        }
        out.sampleSelector = plain.first { s in
            s.hasPrefix(".") && s.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        // Small groups: WebKit drops a whole rule if any one selector in it is invalid.
        for start in stride(from: 0, to: plain.count, by: 12) {
            let group = plain[start..<min(start + 12, plain.count)].joined(separator: ", ")
            out.cosmetic.append(hide(group, trigger: ["url-filter": ".*"]))
        }
        for (key, selectors) in specific {
            let domains = key.split(separator: ",").map { "*" + $0 }
            for start in stride(from: 0, to: selectors.count, by: 12) {
                let group = selectors[start..<min(start + 12, selectors.count)].joined(separator: ", ")
                out.cosmetic.append(hide(group, trigger: ["url-filter": ".*", "if-domain": domains]))
            }
        }
        return out
    }

    private static func hide(_ selector: String, trigger: [String: Any]) -> [String: Any] {
        ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    private static func isUsableSelector(_ s: String) -> Bool {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII }) else { return false }
        return !unsupportedSelectorParts.contains { s.contains($0) }
    }

    private static func isUsableDomain(_ d: String) -> Bool {
        !d.isEmpty && !d.contains("*") && d.contains(".")
            && d.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Splits "a.com,~b.com". `dropped` is true when an entry could not be expressed (like "google.*").
    private static func includedDomains(_ text: String, separator: Character = ",") -> (include: [String], exclude: [String], dropped: Bool) {
        var include: [String] = [], exclude: [String] = [], dropped = false
        for part in text.lowercased().split(separator: separator) {
            let negated = part.hasPrefix("~")
            let d = negated ? String(part.dropFirst()) : String(part)
            guard isUsableDomain(d) else { dropped = true; continue }
            if negated { exclude.append(d) } else { include.append(d) }
        }
        return (include, exclude, dropped)
    }

    private static func looksLikeOptions(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || ",=~|.-_*".contains($0) }
    }

    private static func network(_ raw: String, into out: inout Output) {
        var line = raw
        let isException = line.hasPrefix("@@")
        if isException { line.removeFirst(2) }

        var options: [Substring] = []
        if let idx = line.lastIndex(of: "$"), idx != line.startIndex {
            let tail = line[line.index(after: idx)...]
            if looksLikeOptions(tail) {
                options = tail.split(separator: ",")
                line = String(line[..<idx])
            }
        }
        // Regex rules, and anything WebKit's pattern language cannot hold.
        if line.count > 1, line.hasPrefix("/"), line.hasSuffix("/") { out.skipped += 1; return }
        guard !line.isEmpty, line.allSatisfy({ $0.isASCII && !$0.isWhitespace }), !line.contains("\\") else {
            out.skipped += 1
            return
        }

        var thirdParty: Bool?
        var include: [String] = [], exclude: [String] = []
        var types: Set<String> = [], negated: Set<String> = []
        var wholePage = false, popup = false

        for opt in options {
            let o = opt.lowercased()
            switch o {
            case "third-party", "3p", "~first-party", "~1p": thirdParty = true
            case "~third-party", "~3p", "first-party", "1p": thirdParty = false
            case "match-case", "important", "all": continue
            case "document", "doc": wholePage = true
            case "popup": popup = true
            default:
                if o.hasPrefix("domain=") || o.hasPrefix("from=") {
                    let value = String(o[o.index(after: o.firstIndex(of: "=")!)...])
                    let (inc, exc, dropped) = includedDomains(value, separator: "|")
                    // A rule limited to sites we cannot name must not become a rule for every site.
                    if inc.isEmpty && dropped { out.skipped += 1; return }
                    include = inc
                    exclude = exc
                } else if let t = typeNames[o] {
                    types.insert(t)
                } else if o.hasPrefix("~"), let t = typeNames[String(o.dropFirst())] {
                    negated.insert(t)
                } else {
                    out.skipped += 1   // csp=, redirect=, removeparam=, badfilter, generichide, ...
                    return
                }
            }
        }

        guard let filter = regex(from: line) else { out.skipped += 1; return }
        var trigger: [String: Any] = ["url-filter": filter]
        if let thirdParty { trigger["load-type"] = [thirdParty ? "third-party" : "first-party"] }
        if !include.isEmpty {
            trigger["if-domain"] = include.map { "*" + $0 }
        } else if !exclude.isEmpty {
            trigger["unless-domain"] = exclude.map { "*" + $0 }
        }

        if isException {
            if wholePage {
                // "@@||site.com^$document": leave that whole site alone.
                guard line.hasPrefix("||"), let host = hostOnly(line) else { out.skipped += 1; return }
                out.exceptions.append(["trigger": ["url-filter": ".*", "if-domain": ["*" + host]],
                                       "action": ["type": "ignore-previous-rules"]])
                return
            }
            if !types.isEmpty { trigger["resource-type"] = types.sorted() }
            else if !negated.isEmpty { trigger["resource-type"] = ordinaryTypes.filter { !negated.contains($0) } }
            if popup { trigger["resource-type"] = ((trigger["resource-type"] as? [String]) ?? []) + ["popup"] }
            out.exceptions.append(["trigger": trigger, "action": ["type": "ignore-previous-rules"]])
            return
        }

        let action: [String: Any] = ["type": "block"]
        if wholePage || popup {
            var pageTypes: [String] = []
            if wholePage { pageTypes.append("top-document") }
            if popup { pageTypes.append("popup") }
            var pageTrigger = trigger
            pageTrigger["resource-type"] = pageTypes
            out.pageBlock.append(["trigger": pageTrigger, "action": action])
            if types.isEmpty && negated.isEmpty { return }
        }
        if !types.isEmpty {
            trigger["resource-type"] = types.sorted()
        } else if !negated.isEmpty {
            trigger["resource-type"] = ordinaryTypes.filter { !negated.contains($0) }
        }
        out.block.append(["trigger": trigger, "action": action])
    }

    private static func hostOnly(_ pattern: String) -> String? {
        var p = pattern.dropFirst(2)
        if p.hasSuffix("^") { p = p.dropLast() }
        let host = String(p).lowercased()
        return isUsableDomain(host) ? host : nil
    }

    /// Adblock pattern -> the limited regular expressions WebKit accepts (no alternation, no {n}).
    private static func regex(from pattern: String) -> String? {
        var p = Substring(pattern)
        var out = ""
        if p.hasPrefix("||") {
            out = "^[^:]+://+([^:/]+\\.)?"
            p = p.dropFirst(2)
        } else if p.hasPrefix("|") {
            out = "^"
            p = p.dropFirst()
        }
        var endAnchor = false
        if p.hasSuffix("|") {
            endAnchor = true
            p = p.dropLast()
        }
        while p.hasSuffix("*") { p = p.dropLast() }
        if out.isEmpty { while p.hasPrefix("*") { p = p.dropFirst() } }

        for ch in p {
            switch ch {
            case "*": out += ".*"
            case "^": out += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "$", "(", ")", "[", "]": out += "\\" + String(ch)
            case "{", "}", "|": return nil
            default: out.append(ch)
            }
        }
        if endAnchor { out += "$" }
        return out.isEmpty ? ".*" : out
    }
}

// MARK: - Blocker

extension Notification.Name {
    static let driftBlockerStatus = Notification.Name("driftBlockerStatus")
}

/// Downloads the filter lists, compiles them once, and attaches them to every page.
final class Blocker {
    static let shared = Blocker()

    struct Source {
        let id: String
        let name: String
        let url: String
    }

    static let adSources = [
        Source(id: "easylist", name: "EasyList", url: "https://easylist.to/easylist/easylist.txt"),
        Source(id: "easyprivacy", name: "EasyPrivacy", url: "https://easylist.to/easylist/easyprivacy.txt"),
    ]
    static let cookieSource = Source(id: "cookies", name: "EasyList Cookie List",
                                     url: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")

    struct Meta: Codable {
        var updated: Date?
        var identifiers: [String] = []
        var ruleCount = 0
        var sources: [String] = []
        var sampleSelector: String?
    }

    private let store: WKContentRuleListStore
    private var metaURL: URL { Paths.support.appendingPathComponent("blocker.json") }
    private(set) var meta = Meta()
    private(set) var lists: [WKContentRuleList] = []
    /// The lists in use before the last update, so they can be detached from pages that still carry them.
    private var previousLists: [WKContentRuleList] = []
    private(set) var isUpdating = false
    private(set) var lastError: String?
    /// Every live page's content controller, and whether blocking is currently off for it.
    private let controllers = NSMapTable<WKUserContentController, NSNumber>.weakToStrongObjects()
    /// Controllers that belong to private windows, which extensions cannot reach.
    private let privateControllers = NSHashTable<WKUserContentController>.weakObjects()
    private let session = URLSession(configuration: .ephemeral)

    private init() {
        let dir = Paths.support.appendingPathComponent("rulelists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: dir) ?? .default()
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: metaURL), let m = try? dec.decode(Meta.self, from: data) { meta = m }
    }

    private var wantedSources: [Source] {
        Self.adSources + (Settings.current.blockCookieNotices ? [Self.cookieSource] : [])
    }

    var statusText: String {
        if !Settings.current.blockAds { return "Off" }
        if Extensions.shared.hasActiveBlocker, !lists.isEmpty {
            return "uBlock Origin Lite does the blocking. These lists cover private windows and the first moments after launch."
        }
        if isUpdating { return lists.isEmpty ? "Downloading filter lists…" : "Updating filter lists…" }
        if lists.isEmpty { return lastError ?? "Not loaded yet" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        let when = meta.updated.map { f.string(from: $0) } ?? "unknown"
        let n = NumberFormatter.localizedString(from: NSNumber(value: meta.ruleCount), number: .decimal)
        return "\(n) rules · updated \(when)" + (lastError.map { " · \($0)" } ?? "")
    }

    private func changed() {
        NotificationCenter.default.post(name: .driftBlockerStatus, object: nil)
    }

    // MARK: Pages

    func register(_ controller: WKUserContentController, isPrivate: Bool = false) {
        controllers.setObject(NSNumber(value: false), forKey: controller)
        if isPrivate { privateControllers.add(controller) }
        apply(to: controller, disabled: false)
    }

    /// uBlock Origin Lite started or stopped: hand blocking over to it, or take it back.
    func extensionBlockerChanged() {
        applyToAll()
        changed()
    }

    private func apply(to controller: WKUserContentController, disabled: Bool) {
        // Remove only Drift's own lists. Extensions (uBlock Origin Lite) attach their rules to the
        // same controller, and clearing everything would silently switch them off.
        for list in lists + previousLists { controller.remove(list) }
        // When uBlock Origin Lite is running it does the blocking on ordinary pages; doing it twice is wasted work.
        if Extensions.shared.blockerInCharge, !privateControllers.contains(controller) { return }
        if Settings.current.blockAds, !disabled {
            // DRIFT_BLOCKONLY (testing): attach only the lists whose name contains this text.
            let only = ProcessInfo.processInfo.environment["DRIFT_BLOCKONLY"]
            for list in lists where only == nil || list.identifier.contains(only!) { controller.add(list) }
        }
    }

    private func applyToAll() {
        for controller in controllers.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            apply(to: controller, disabled: controllers.object(forKey: controller)?.boolValue ?? false)
        }
    }

    func isDisabled(forHost host: String?) -> Bool {
        Site.host(host, isIn: Settings.current.blockingDisabledSites)
    }

    /// Called as a tab starts loading a page, so blocking can be off for sites the user exempted.
    func willNavigate(toHost host: String?, controller: WKUserContentController) {
        let want = isDisabled(forHost: host)
        let have = controllers.object(forKey: controller)?.boolValue
        if have == nil || have != want {
            controllers.setObject(NSNumber(value: want), forKey: controller)
            apply(to: controller, disabled: want)
        }
    }

    /// The blocking switch or the exempt-site list changed.
    func settingsChanged() {
        if Settings.current.blockAds, lists.isEmpty || Set(meta.sources) != Set(wantedSources.map { $0.id }) {
            start()
        }
        applyToAll()
        changed()
    }

    // MARK: Loading and updating

    func start() {
        guard Settings.current.blockAds else { return }
        let wanted = Set(wantedSources.map { $0.id })
        if lists.isEmpty, !meta.identifiers.isEmpty, Set(meta.sources) == wanted {
            lookUp(meta.identifiers[...], found: []) { [weak self] found in
                guard let self else { return }
                if found.count == self.meta.identifiers.count {
                    self.lists = found
                    self.applyToAll()
                    self.changed()
                    let age = self.meta.updated.map { Date().timeIntervalSince($0) } ?? .infinity
                    if age > 4 * 86400 { self.update() }
                } else {
                    self.update()
                }
            }
        } else if lists.isEmpty || Set(meta.sources) != wanted {
            update()
        }
    }

    private func lookUp(_ ids: ArraySlice<String>, found: [WKContentRuleList], completion: @escaping ([WKContentRuleList]) -> Void) {
        guard let id = ids.first else { completion(found); return }
        store.lookUpContentRuleList(forIdentifier: id) { [weak self] list, _ in
            self?.lookUp(ids.dropFirst(), found: found + (list.map { [$0] } ?? []), completion: completion)
        }
    }

    /// Downloads fresh lists and swaps them in. The old rules keep working until the new ones are ready.
    func update(completion: ((Bool) -> Void)? = nil) {
        guard !isUpdating else { completion?(false); return }
        isUpdating = true
        lastError = nil
        changed()
        let sources = wantedSources
        download(sources[...], texts: []) { [weak self] texts in
            guard let self else { return }
            guard texts.count == sources.count else {
                self.finish(error: "Couldn’t download the filter lists", completion: completion)
                return
            }
            DispatchQueue.global(qos: .utility).async {
                let converted = zip(sources, texts).map { ($0.0, FilterConverter.convert($0.1)) }
                DispatchQueue.main.async { self.compileAll(converted, completion: completion) }
            }
        }
    }

    private func download(_ sources: ArraySlice<Source>, texts: [String], completion: @escaping ([String]) -> Void) {
        guard let source = sources.first, let url = URL(string: source.url) else { completion(texts); return }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpShouldHandleCookies = false
        session.dataTask(with: req) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let text = (ok ? data : nil).flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async {
                // A real list is tens of thousands of lines; anything tiny is an error page.
                guard let self, let text, text.count > 20_000 else { completion(texts); return }
                self.download(sources.dropFirst(), texts: texts + [text], completion: completion)
            }
        }.resume()
    }

    private func compileAll(_ converted: [(Source, FilterConverter.Output)], completion: ((Bool) -> Void)?) {
        let generation = String(Int(Date().timeIntervalSince1970))
        var jobs: [(id: String, rules: [[String: Any]])] = []
        for (source, out) in converted {
            if !out.network.isEmpty { jobs.append(("drift-\(generation)-\(source.id)-net", out.network)) }
            if !out.cosmetic.isEmpty { jobs.append(("drift-\(generation)-\(source.id)-css", out.cosmetic)) }
        }
        let sample = converted.first?.1.sampleSelector
        var compiled: [WKContentRuleList] = []
        var total = 0

        func next(_ index: Int) {
            guard index < jobs.count else {
                guard !compiled.isEmpty else {
                    self.finish(error: "Couldn’t prepare the filter lists", completion: completion)
                    return
                }
                let old = self.meta.identifiers
                self.previousLists = self.lists
                self.lists = compiled
                self.meta = Meta(updated: Date(), identifiers: compiled.map { $0.identifier }, ruleCount: total,
                                 sources: converted.map { $0.0.id }, sampleSelector: sample)
                self.saveMeta()
                for id in old where !self.meta.identifiers.contains(id) {
                    self.store.removeContentRuleList(forIdentifier: id) { _ in }
                }
                self.applyToAll()
                self.previousLists = []
                self.finish(error: nil, completion: completion)
                return
            }
            let job = jobs[index]
            self.compileValid(id: job.id, rules: job.rules) { list, count in
                if let list {
                    compiled.append(list)
                    total += count
                }
                next(index + 1)
            }
        }
        next(0)
    }

    private func encode(_ rules: [[String: Any]]) -> String? {
        (try? JSONSerialization.data(withJSONObject: rules)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Compiles a list. If WebKit rejects it, the offending rules are found by halving and left out.
    private func compileValid(id: String, rules: [[String: Any]], completion: @escaping (WKContentRuleList?, Int) -> Void) {
        guard let json = encode(rules) else { completion(nil, 0); return }
        store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { [weak self] list, _ in
            guard let self else { return }
            if let list { completion(list, rules.count); return }
            self.prune(rules, scratchID: id + "-t") { good in
                guard !good.isEmpty, good.count < rules.count, let json = self.encode(good) else { completion(nil, 0); return }
                self.store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in
                    completion(list, list == nil ? 0 : good.count)
                }
            }
        }
    }

    private func prune(_ rules: [[String: Any]], scratchID: String, completion: @escaping ([[String: Any]]) -> Void) {
        guard let json = encode(rules) else { completion([]); return }
        store.compileContentRuleList(forIdentifier: scratchID, encodedContentRuleList: json) { [weak self] list, _ in
            guard let self else { return }
            if list != nil {
                self.store.removeContentRuleList(forIdentifier: scratchID) { _ in }
                completion(rules)
                return
            }
            if rules.count <= 1 { completion([]); return }
            let mid = rules.count / 2
            self.prune(Array(rules[..<mid]), scratchID: scratchID + "a") { left in
                self.prune(Array(rules[mid...]), scratchID: scratchID + "b") { right in
                    completion(left + right)
                }
            }
        }
    }

    private func finish(error: String?, completion: ((Bool) -> Void)?) {
        isUpdating = false
        lastError = error
        changed()
        completion?(error == nil)
    }

    private func saveMeta() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(meta) { try? data.write(to: metaURL, options: .atomic) }
    }
}
