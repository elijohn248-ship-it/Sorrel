import AppKit
import WebKit

// MARK: - Favicons

final class FaviconStore {
    static let shared = FaviconStore()
    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private let session = URLSession(configuration: .ephemeral)

    private func file(for host: String) -> URL {
        let safe = host.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return Paths.favicons.appendingPathComponent(safe + ".img")
    }

    func image(forHost host: String?) -> NSImage? {
        guard let host, !host.isEmpty else { return nil }
        if let m = memory[host] { return m }
        if missing.contains(host) { return nil }
        if let data = try? Data(contentsOf: file(for: host)), let img = NSImage(data: data) {
            memory[host] = img
            return img
        }
        missing.insert(host)
        return nil
    }

    func image(for item: Item) -> NSImage? {
        if let u = item.url, u.hasPrefix("drift://") { return symbol("sparkles", size: 14) }
        return item.page?.favicon ?? image(forHost: item.host)
    }

    private static let script = """
    (function(){var l=document.querySelectorAll('link[rel~="icon"],link[rel="apple-touch-icon"],link[rel="shortcut icon"]');\
    var best=null,bs=-1;for(var i=0;i<l.length;i++){var e=l[i];if(!e.href)continue;\
    var s=(e.sizes&&e.sizes.length&&parseInt(e.sizes[0]))||(e.rel.indexOf('apple')>=0?180:16);\
    if(/\\.svg(\\?|$)/.test(e.href))s=24;if(s>256)s=20;if(s>bs){best=e.href;bs=s}}\
    return {icons: [best, location.origin+'/favicon.ico'], ua: navigator.userAgent};})()
    """

    func fetch(for webView: WKWebView, completion: @escaping (NSImage?) -> Void) {
        guard let host = webView.url?.host else { completion(nil); return }
        webView.evaluateJavaScript(Self.script) { [weak self] result, _ in
            guard let self else { return }
            let info = result as? [String: Any]
            // Encrypted addresses only, fetched under the same browser identity as the page,
            // so the icon request doesn't announce "Drift" or travel in the clear.
            let candidates = ((info?["icons"] as? [Any]) ?? []).compactMap { $0 as? String }.compactMap { URL(string: $0) }
                .filter { $0.scheme == "https" }
            self.download(candidates[...], host: host, userAgent: info?["ua"] as? String, completion: completion)
        }
    }

    private func download(_ urls: ArraySlice<URL>, host: String, userAgent: String?, completion: @escaping (NSImage?) -> Void) {
        guard let url = urls.first else { completion(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpShouldHandleCookies = false
        if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        session.dataTask(with: req) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? false
            let img = (ok ? data : nil).flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if let img, img.size.width > 0, let data {
                    self.memory[host] = img
                    self.missing.remove(host)
                    try? data.write(to: self.file(for: host), options: .atomic)
                    completion(img)
                } else {
                    self.download(urls.dropFirst(), host: host, userAgent: userAgent, completion: completion)
                }
            }
        }.resume()
    }
}

// MARK: - History

final class History {
    static let shared = History()

    struct Entry: Codable {
        var url: String
        var title: String
        var visits: Int
        var last: Date
    }

    private var entries: [String: Entry] = [:]
    private let saver = Debouncer(delay: 3)

    private init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Paths.history),
           let list = try? dec.decode([Entry].self, from: data) {
            for e in list { entries[e.url] = e }
        }
    }

    func record(url: URL, title: String?) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        let key = url.absoluteString
        var e = entries[key] ?? Entry(url: key, title: "", visits: 0, last: Date())
        e.visits += 1
        e.last = Date()
        if let title, !title.isEmpty { e.title = title }
        entries[key] = e
        saver.schedule { [weak self] in self?.saveNow() }
    }

    func saveNow() {
        var list = Array(entries.values)
        if list.count > 20000 {
            list.sort { $0.last > $1.last }
            list = Array(list.prefix(15000))
            entries = Dictionary(uniqueKeysWithValues: list.map { ($0.url, $0) })
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(list) { try? data.write(to: Paths.history, options: .atomic) }
    }

    func clear() {
        entries = [:]
        saveNow()
    }

    /// The pages visited most recently, newest first.
    func recent(limit: Int) -> [Entry] {
        Array(entries.values.sorted { $0.last > $1.last }.prefix(limit))
    }

    /// Matches every word of the query against the URL and title.
    func search(_ query: String, limit: Int) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let now = Date()
        var scored: [(Double, Entry)] = []
        for e in entries.values {
            let u = e.url.lowercased(), t = e.title.lowercased()
            guard words.allSatisfy({ u.contains($0) || t.contains($0) }) else { continue }
            let days = now.timeIntervalSince(e.last) / 86400
            var score = log(Double(e.visits) + 1) * 2 + max(0, 5 - days / 7)
            if let host = URL(string: e.url)?.host?.replacingOccurrences(of: "www.", with: ""),
               host.hasPrefix(words[0]) {
                score += 6
                if (URL(string: e.url)?.path ?? "/").count <= 1 { score += 4 }
            }
            scored.append((score, e))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
    }

    /// The most-visited page whose host starts with the typed text.
    func topHostMatch(_ text: String) -> Entry? {
        let q = text.lowercased()
        guard q.count >= 2, !q.contains(" ") else { return nil }
        return search(q, limit: 5).first { e in
            guard let host = URL(string: e.url)?.host?.replacingOccurrences(of: "www.", with: "") else { return false }
            return host.hasPrefix(q)
        }
    }
}

// MARK: - Per-site zoom

final class ZoomStore {
    static let shared = ZoomStore()
    private var levels: [String: Double] = [:]

    private init() {
        if let data = try? Data(contentsOf: Paths.zoom),
           let d = try? JSONDecoder().decode([String: Double].self, from: data) { levels = d }
    }

    func level(forHost host: String?) -> Double { host.flatMap { levels[$0] } ?? 1 }

    func set(_ level: Double, forHost host: String?) {
        guard let host else { return }
        if abs(level - 1) < 0.01 { levels[host] = nil } else { levels[host] = level }
        if let data = try? JSONEncoder().encode(levels) { try? data.write(to: Paths.zoom, options: .atomic) }
    }
}

// MARK: - Bangs

final class Bangs {
    static let shared = Bangs()

    struct Bang {
        let trigger: String
        let name: String
        let domain: String
        let template: String
        let spaceToPlus: Bool?
    }

    private var table: [String: Bang] = [:]

    private static let starterCustom = """
    [
      {"t": "amb", "s": "AMBOSS", "u": "https://next.amboss.com/us/search?q={{{s}}}"},
      {"t": "up", "s": "UpToDate", "u": "https://www.uptodate.com/contents/search?search={{{s}}}"},
      {"t": "mdc", "s": "MDCalc", "u": "https://www.mdcalc.com/search?q={{{s}}}"},
      {"t": "rad", "s": "Radiopaedia", "u": "https://radiopaedia.org/search?q={{{s}}}&scope=all"},
      {"t": "pm", "s": "PubMed", "u": "https://pubmed.ncbi.nlm.nih.gov/?term={{{s}}}"}
    ]
    """

    private init() { reload() }

    func reload() {
        table = [:]
        if let url = Bundle.main.url(forResource: "bangs", withExtension: "json") {
            ingest(url)
        }
        if !FileManager.default.fileExists(atPath: Paths.bangs.path) {
            try? Self.starterCustom.write(to: Paths.bangs, atomically: true, encoding: .utf8)
        }
        ingest(Paths.bangs)   // custom bangs win over the bundled list
    }

    private func ingest(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for e in list {
            guard let t = e["t"] as? String, var u = e["u"] as? String else { continue }
            u = u.replacingOccurrences(of: "%s", with: "{{{s}}}")
            let fmt = e["fmt"] as? [String]
            let domain = (e["d"] as? String) ?? URL(string: u.replacingOccurrences(of: "{{{s}}}", with: ""))?.host ?? ""
            let name = (e["s"] as? String) ?? t
            let plus: Bool? = fmt.map { $0.contains("url_encode_space_to_plus") }
            for trig in [t] + ((e["ts"] as? [String]) ?? []) {
                table[trig.lowercased()] = Bang(trigger: trig.lowercased(), name: name, domain: domain,
                                                template: u, spaceToPlus: plus)
            }
        }
    }

    var count: Int { table.count }

    struct Match {
        let bang: Bang
        let query: String
        let url: URL
    }

    /// Finds a `!bang` anywhere in the text and builds the destination, entirely on this device.
    func resolve(_ text: String) -> Match? {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let idx = words.firstIndex(where: { w in
            w.hasPrefix("!") && w.count > 1 && table[String(w.dropFirst()).lowercased()] != nil
        }) else { return nil }
        let bang = table[String(words[idx].dropFirst()).lowercased()]!
        words.remove(at: idx)
        let query = words.joined(separator: " ")

        if query.isEmpty {
            let base = URL(string: bang.template.replacingOccurrences(of: "{{{s}}}", with: ""))
            var comps = URLComponents()
            comps.scheme = base?.scheme ?? "https"
            comps.host = base?.host ?? bang.domain
            guard let url = comps.url else { return nil }
            return Match(bang: bang, query: "", url: url)
        }

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        // In a query string a space is usually "+"; in a path it has to stay "%20".
        let inQueryString: Bool = {
            guard let r = bang.template.range(of: "{{{s}}}") else { return true }
            return bang.template[..<r.lowerBound].contains("?")
        }()
        if bang.spaceToPlus ?? inQueryString {
            encoded = encoded.replacingOccurrences(of: "%20", with: "+")
        }
        guard let url = URL(string: bang.template.replacingOccurrences(of: "{{{s}}}", with: encoded)) else { return nil }
        return Match(bang: bang, query: query, url: url)
    }
}

// MARK: - Turning typed text into a destination

enum Resolver {
    static func url(fromTyped raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "file://", "drift://", "about:"] where lower.hasPrefix(scheme) {
            return URL(string: text)
        }
        if lower.hasPrefix("localhost") || lower.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + text)
        }
        // host.tld with an optional port and path
        if lower.range(of: #"^([a-z0-9-]+\.)+[a-z]{2,}(:\d+)?([/?#].*)?$"#, options: .regularExpression) != nil {
            return URL(string: "https://" + text)
        }
        return nil
    }

    static func searchURL(_ query: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let q = (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query)
            .replacingOccurrences(of: "%20", with: "+")
        return URL(string: Settings.current.searchEngineURL.replacingOccurrences(of: "%s", with: q))
            ?? URL(string: "https://duckduckgo.com/?q=" + q)!
    }

    /// Bang, then URL, then search.
    static func destination(for text: String) -> URL {
        if let m = Bangs.shared.resolve(text) { return m.url }
        if let u = url(fromTyped: text) { return u }
        return searchURL(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Tracking parameter removal

enum URLCleaner {
    private static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "mc_eid", "mc_cid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "oly_enc_id", "oly_anon_id", "vero_id", "vero_conv", "s_cid", "_openstat",
        "li_fat_id", "rb_clickid", "srsltid", "ml_subscriber", "ml_subscriber_hash",
    ]
    private static let prefixes = ["utm_", "pk_", "piwik_", "mtm_"]

    /// Returns a cleaned URL, or nil when there was nothing to remove.
    static func clean(_ url: URL) -> URL? {
        guard url.scheme == "https" || url.scheme == "http",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.percentEncodedQueryItems, !items.isEmpty else { return nil }
        let host = (url.host ?? "").lowercased()
        let kept = items.filter { item in
            let name = item.name.lowercased()
            if exact.contains(name) { return false }
            if prefixes.contains(where: { name.hasPrefix($0) }) { return false }
            if name == "si", host.hasSuffix("youtube.com") || host.hasSuffix("youtu.be") || host.hasSuffix("spotify.com") {
                return false
            }
            return true
        }
        guard kept.count != items.count else { return nil }
        comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return comps.url
    }
}
