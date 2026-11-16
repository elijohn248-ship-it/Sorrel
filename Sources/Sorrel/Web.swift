import AppKit
import WebKit

final class SorrelWebView: WKWebView {
    weak var page: Page?

    /// Sorrel has tabs, not extra windows, so the page menu should say so.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let renames = [
            "WKMenuItemIdentifierOpenLinkInNewWindow": "Open Link in New Tab",
            "WKMenuItemIdentifierOpenImageInNewWindow": "Open Image in New Tab",
            "WKMenuItemIdentifierOpenFrameInNewWindow": "Open Frame in New Tab",
            "WKMenuItemIdentifierOpenMediaInNewWindow": "Open Video in New Tab",
        ]
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = renames[id] { item.title = title }
        }
        super.willOpenMenu(menu, with: event)
    }
}

/// One file being downloaded, or downloaded recently (finished ones from normal windows are remembered
/// across launches in `downloads.json`; private ones never are).
final class DownloadRecord {
    enum State { case running, done, failed }
    let file: URL
    var state: State = .running
    weak var download: WKDownload?
    var observation: NSKeyValueObservation?
    var fraction: Double = 0
    /// Bytes so far, and the expected size (0 = the server didn't say).
    var received: Int64 = 0
    var total: Int64 = 0
    let started: Date
    var finished: Date?
    var isPrivate = false
    /// Stopped on purpose (so it reads "Cancelled", not "Didn't finish").
    var cancelled = false
    init(file: URL, started: Date = Date()) { self.file = file; self.started = started }

    /// What `downloads.json` keeps: just enough to list the file again.
    struct Saved: Codable { var path: String; var bytes: Int64; var finished: Date }
}

extension Notification.Name {
    static let sorrelDownloads = Notification.Name("sorrelDownloads")
}

// MARK: - Page (one live web view)

final class Page: NSObject {
    let webView: SorrelWebView
    let profileID: UUID?
    /// Private pages keep nothing: no history, no saved cookies, no icon cache.
    var isPrivate = false
    weak var item: Item?
    /// Used by mini windows, which show a page that is not a tab yet.
    var onChange: ((Page) -> Void)?
    var favicon: NSImage?
    private var observations: [NSKeyValueObservation] = []

    init(webView: SorrelWebView, profileID: UUID?) {
        self.webView = webView
        self.profileID = profileID
        super.init()
        webView.page = self
        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.changed() },
            webView.observe(\.url) { [weak self] _, _ in self?.changed() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.changed() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.changed() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.changed() },
        ]
    }

    /// The address to show and save. Bundled pages keep their sorrel:// name.
    var displayURL: String? {
        guard let u = webView.url else { return nil }
        if u.isFileURL, let res = Bundle.main.resourceURL, u.path.hasPrefix(res.path) {
            return "sorrel://" + u.deletingPathExtension().lastPathComponent
        }
        if u.absoluteString == "about:blank" { return nil }
        return u.absoluteString
    }

    func changed() {
        if let item {
            if let u = displayURL { item.url = u }
            if let t = webView.title, !t.isEmpty { item.title = t }
            Store.shared.itemChanged(item)
            Extensions.shared.tabChanged(item)
        }
        onChange?(self)
    }

    func teardown() {
        observations.forEach { $0.invalidate() }
        observations = []
        onChange = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }
}

// MARK: - Engine

final class Engine: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let shared = Engine()

    /// Called when a page asks for a new window (target=_blank, window.open).
    var onNewPage: ((_ newPage: Page, _ source: Page?) -> Void)?
    /// Called for cmd-click and middle-click.
    var onOpenInBackground: ((_ url: URL, _ source: Page?) -> Void)?
    var onPageClosed: ((Page) -> Void)?
    /// Called to show a link as a preview over the current page.
    var onPeek: ((_ url: URL, _ source: Page) -> Void)?
    var onToast: ((String) -> Void)?

    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    /// Recent downloads, newest first: this session's, plus finished ones remembered from earlier launches.
    private(set) lazy var downloads: [DownloadRecord] = loadSavedDownloads()
    private var downloadsFile: URL { Paths.support.appendingPathComponent("downloads.json") }
    private static let savedDownloadLimit = 30

    /// Starts a download directly (used by tests). Sorrel started it, so it doesn't ask.
    func startDownload(_ url: URL, in webView: WKWebView) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.sorrelStartedDownloads.insert(ObjectIdentifier(download))
            download.delegate = self
        }
    }
    /// Downloads Sorrel itself started, which need no permission.
    private var sorrelStartedDownloads: Set<ObjectIdentifier> = []
    /// Sites allowed to start downloads without a click, until Sorrel quits.
    private var downloadGrants: Set<String> = []
    private var downloadPromptOpen = false

    func clearFinishedDownloads() {
        downloads.removeAll { $0.state != .running }
        downloadsChanged(save: true)
    }

    /// Takes one entry off the list (the file stays where it is). A running download is cancelled first.
    func removeDownload(_ record: DownloadRecord) {
        if record.state == .running { record.download?.cancel { _ in } }
        downloads.removeAll { $0 === record }
        downloadsChanged(save: true)
    }

    /// Moves a finished download to the Trash and takes it off the list.
    func trashDownload(_ record: DownloadRecord) {
        guard record.state != .running else { return }
        try? FileManager.default.trashItem(at: record.file, resultingItemURL: nil)
        removeDownload(record)
    }

    private func downloadsChanged(save: Bool = false) {
        if save { saveDownloads() }
        NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
    }

    private func loadSavedDownloads() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: downloadsFile) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let saved = try? decoder.decode([DownloadRecord.Saved].self, from: data) else { return [] }
        return saved.prefix(Self.savedDownloadLimit).map { s in
            let r = DownloadRecord(file: URL(fileURLWithPath: s.path), started: s.finished)
            r.state = .done
            r.fraction = 1
            r.received = s.bytes
            r.total = s.bytes
            r.finished = s.finished
            return r
        }
    }

    /// Only finished downloads from normal windows are written down; private ones leave no record.
    private func saveDownloads() {
        let saved = downloads.filter { $0.state == .done && !$0.isPrivate }.prefix(Self.savedDownloadLimit).map {
            DownloadRecord.Saved(path: $0.file.path, bytes: $0.received, finished: $0.finished ?? $0.started)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: downloadsFile)
        } else if let data = try? encoder.encode(Array(saved)) {
            try? data.write(to: downloadsFile, options: .atomic)
        }
    }

    /// Test hook: puts a stand-in entry on the list without downloading anything.
    func debugAddDownload(_ record: DownloadRecord) {
        downloads.insert(record, at: 0)
        downloadsChanged()
    }

    private func record(for download: WKDownload) -> DownloadRecord? { downloads.first { $0.download === download } }
    private var mediaGrants: [String: Bool] = [:]
    /// Downloads started from private pages: their files are still quarantined, but without the addresses.
    private var privateDownloads: Set<ObjectIdentifier> = []

    // HTTPS-first: plain http:// pages are tried over https:// first.
    /// Web view -> the http:// address currently being tried over https://.
    private var upgrades: [ObjectIdentifier: URL] = [:]
    /// Web view -> the http:// address offered by the "not secure" warning showing in it.
    private var insecureOffers: [ObjectIdentifier: URL] = [:]
    /// Sites the person chose to open without encryption, until Sorrel quits.
    private var insecureAllowed: Set<String> = []
    /// Site + scheme pairs the person let open another app, until Sorrel quits.
    private var externalGrants: Set<String> = []
    private var externalPromptOpen = false
    /// Opened from a page without asking, but only when the person clicked the link.
    private static let quietExternalSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "facetime-audio"]

    static let chromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private lazy var safariVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }()

    // MARK: Creating pages

    /// Test runs keep cookies and site data in memory. WebKit files persistent data by app, not by
    /// profile folder, so a persistent store in a test would be the owner's real one.
    private static let testStore = WKWebsiteDataStore.nonPersistent()

    /// Where a space's cookies and site data live: its own store if it keeps separate logins, else the shared one.
    static func store(for profileID: UUID?) -> WKWebsiteDataStore {
        if isTestProfile { return testStore }
        return profileID.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
    }

    func makeConfiguration(profileID: UUID?, isPrivate: Bool = false) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        if isPrivate {
            c.websiteDataStore = .nonPersistent()
        } else {
            c.websiteDataStore = Self.store(for: profileID)
            // Extensions run on ordinary pages. Private windows stay out of their reach.
            c.webExtensionController = Extensions.shared.controller
        }
        Blocker.shared.register(c.userContentController, isPrivate: isPrivate)
        // Present as Safari so sites serve the same pages they serve Safari.
        c.applicationNameForUserAgent = "Version/\(safariVersion) Safari/605.1.15"
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.setValue(true, forKey: "developerExtrasEnabled")
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.upgradeKnownHostsToHTTPS = true
        c.allowsAirPlayForMediaPlayback = true
        return c
    }

    func makePage(profileID: UUID?, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) -> Page {
        let cfg = configuration ?? makeConfiguration(profileID: profileID, isPrivate: isPrivate)
        let wv = SorrelWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = true
        let page = Page(webView: wv, profileID: profileID)
        page.isPrivate = isPrivate
        return page
    }

    func ensurePage(for item: Item) -> Page {
        if let p = item.page { return p }
        let space = Store.shared.space(containing: item)
        // An extension's own pages (its settings, for instance) need the extension's configuration.
        let extensionConfig = item.url.flatMap { URL(string: $0) }.flatMap { Extensions.shared.configuration(forExtensionURL: $0) }
        if let extensionConfig, ProcessInfo.processInfo.environment["SORREL_EXTDIAG"] != nil {
            // Testing: record what goes wrong inside an extension's own page.
            let recorder = """
            window.__sorrelErrors = [];
            window.addEventListener('error', function (e) { __sorrelErrors.push('error: ' + (e.message || e.type) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno); }, true);
            window.addEventListener('unhandledrejection', function (e) { __sorrelErrors.push('rejection: ' + String(e.reason && (e.reason.message || e.reason))); });
            ['error', 'warn'].forEach(function (k) { var o = console[k]; console[k] = function () { try { __sorrelErrors.push(k + ': ' + Array.prototype.map.call(arguments, function (a) { return (a && a.message) || String(a); }).join(' ').slice(0, 300)); } catch (x) {} return o.apply(console, arguments); }; });
            """
            extensionConfig.userContentController.addUserScript(
                WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let p = makePage(profileID: space?.profileID, configuration: extensionConfig)
        p.item = item
        item.page = p
        if let saved = item.savedState {
            // Waking a sleeping tab: bring back its history and scroll position, which also reloads it.
            item.savedState = nil
            p.webView.interactionState = saved
            if p.webView.url == nil, let u = item.url, !u.isEmpty { load(u, in: p) }
        } else if let u = item.url, !u.isEmpty {
            load(u, in: p)
        }
        return p
    }

    func load(_ urlString: String, in page: Page) {
        // Tabs saved before the rename still say drift://.
        let urlString = urlString.hasPrefix("drift://") ? "sorrel://" + urlString.dropFirst("drift://".count) : urlString
        if urlString.hasPrefix("sorrel://") {
            let name = String(urlString.dropFirst("sorrel://".count))
            // A plain name only: Bundle.url(forResource:) follows "../", which would reach files outside the app.
            if name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil,
               let file = Bundle.main.url(forResource: name, withExtension: "html") {
                page.webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
            }
            return
        }
        guard let url = URL(string: urlString) else { return }
        page.webView.load(URLRequest(url: url))
    }

    private func page(_ webView: WKWebView) -> Page? { (webView as? SorrelWebView)?.page }

    /// A clicked link gets a preview when it leads to a different site than the tab it is in,
    /// or when it is shift-clicked. Only real link clicks count: typed addresses, redirects,
    /// form submissions and script-opened windows (sign-in pop-ups) behave as usual.
    private func shouldPeek(_ url: URL, from page: Page?, action: WKNavigationAction) -> Bool {
        guard onPeek != nil, let page, let item = page.item, action.navigationType == .linkActivated,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if action.modifierFlags.contains(.shift) { return true }
        let s = Settings.current
        // Search results open in the tab: every result leads to another site, so previews there only get in the way.
        var excluded = s.peekExcludedSites
        if let engine = URL(string: s.searchEngineURL.replacingOccurrences(of: "%s", with: "x"))?.host { excluded.append(engine) }
        if Site.host(page.webView.url?.host, isIn: excluded) { return false }
        let pinned = Store.shared.isPinned(item) || Store.shared.isFavorite(item)
        guard s.peekLinksFromAllTabs || (s.peekLinksFromPinnedTabs && pinned) else { return false }
        let here = page.webView.url?.host ?? item.pinnedURL.flatMap { URL(string: $0)?.host }
        guard here != nil, url.host != nil else { return false }
        return !Site.same(here, url.host)
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = (url.scheme ?? "").lowercased()
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let id = ObjectIdentifier(webView)

        if isMain, let ownPage = internalLoads[id], ownPage == url {
            // Sorrel's own error or warning page, shown under the failed site's address.
            internalLoads[id] = nil
            decisionHandler(.allow)
            return
        }
        if scheme == Self.insecureContinueScheme {
            // "Continue to site" on Sorrel's own not-secure warning. Honoured only from that warning, while it is
            // the page showing (its address is the offered one); a page loaded after it can't use a leftover offer.
            decisionHandler(.cancel)
            if isMain, navigationAction.sourceFrame.isMainFrame, let offer = insecureOffers[id],
               webView.url?.absoluteString == offer.absoluteString,
               let target = insecureOffers.removeValue(forKey: id), let host = target.host?.lowercased() {
                insecureAllowed.insert(host)
                upgrades[id] = nil
                webView.load(URLRequest(url: target))
            }
            return
        }
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme),
           !Extensions.shared.isExtensionURL(url) {
            // mailto:, zoommtg:, facetime: and friends belong to other apps. Pages must ask first.
            if isMain { openInOtherApp(url, from: webView, clicked: navigationAction.navigationType == .linkActivated) }
            decisionHandler(.cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if isMain, Extensions.shared.isExtensionURL(url) {
            // An extension's own page in a tab: start its background first (Extensions.wakeBackground).
            Extensions.shared.wakeBackground(beforeLoading: url) { decisionHandler(.allow) }
            return
        }
        if isMain, scheme == "data" {
            // Pages may not send the whole tab to a data: address (a common way to fake a sign-in page).
            decisionHandler(.cancel)
            return
        }
        if isMain, scheme.hasPrefix("http") {
            Blocker.shared.willNavigate(toHost: url.host, controller: webView.configuration.userContentController)
            // A Chrome extension's own website expects Chrome. Everywhere else Sorrel stays Safari.
            let wantsChrome = Extensions.shared.isChromeCompanionSite(url)
            let isChrome = webView.customUserAgent == Self.chromeUserAgent
            if wantsChrome != isChrome {
                webView.customUserAgent = wantsChrome ? Self.chromeUserAgent : nil
                // Restart this load so the very first request already carries the right identity.
                if (navigationAction.request.httpMethod ?? "GET") == "GET" {
                    decisionHandler(.cancel)
                    webView.load(navigationAction.request)
                    return
                }
            }
        }
        if navigationAction.navigationType == .linkActivated, scheme.hasPrefix("http") {
            let middle = navigationAction.buttonNumber == 2 || navigationAction.buttonNumber == 4
            if navigationAction.modifierFlags.contains(.command) || middle {
                onOpenInBackground?(url, page(webView))
                decisionHandler(.cancel)
                return
            }
            if isMain, let source = page(webView), shouldPeek(url, from: source, action: navigationAction) {
                onPeek?(url, source)
                decisionHandler(.cancel)
                return
            }
        }
        if isMain, scheme == "http", Settings.current.httpsFirst,
           (navigationAction.request.httpMethod ?? "GET") == "GET",
           let host = url.host?.lowercased(), Self.canUpgrade(url), !insecureAllowed.contains(host) {
            decisionHandler(.cancel)
            if upgrades[id]?.host?.lowercased() == host {
                // The https:// version sent us straight back to http://: the site has no working secure version.
                showInsecureWarning(for: url, in: webView)
            } else {
                upgrades[id] = url
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = "https"
                if comps?.port == 80 { comps?.port = nil }
                var req = navigationAction.request
                req.url = comps?.url ?? url
                webView.load(req)
            }
            return
        }
        if isMain, Settings.current.stripTrackingParameters,
           (navigationAction.request.httpMethod ?? "GET") == "GET",
           navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .other,
           let cleaned = URLCleaner.clean(url) {
            decisionHandler(.cancel)
            var req = navigationAction.request
            req.url = cleaned
            webView.load(req)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // An https:// upgrade that got this far worked.
        let id = ObjectIdentifier(webView)
        internalLoads[id] = nil
        // Anything other than the not-secure warning itself ends its offer to continue.
        if let offer = insecureOffers[id], webView.url?.absoluteString != offer.absoluteString { insecureOffers[id] = nil }
        // A new page starts with a clean slate for dialogs.
        dialogCounts[id] = nil
        silencedPages.remove(id)
        if let tried = upgrades[id], webView.url?.scheme == "https", webView.url?.host == tried.host { upgrades[id] = nil }
        // Each site remembers its own zoom level.
        let zoom = ZoomStore.shared.level(forHost: webView.url?.host)
        if abs(webView.pageZoom - zoom) > 0.001 { webView.pageZoom = zoom }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = page(webView) else { return }
        if !page.isPrivate {
            if let url = webView.url { History.shared.record(url: url, title: webView.title) }
            FaviconStore.shared.fetch(for: webView) { [weak page] image in
                guard let page, let image else { return }
                page.favicon = image
                page.changed()
            }
        }
        page.item?.lastActive = Date()
        page.changed()
    }

    /// Sites that ask for a name and password with the browser's own prompt (some school and library proxies).
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method),
              challenge.previousFailureCount < 3 else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(challenge.protectionSpace.host)"
        alert.informativeText = challenge.protectionSpace.realm ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        user.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(user)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        user.nextKeyView = pass
        sheet(alert, for: webView) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue,
                                                                persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        // A plain http:// address Sorrel tried over https:// first, and the secure version failed.
        let id = ObjectIdentifier(webView)
        if let tried = upgrades[id], failing?.scheme == "https", failing?.host?.lowercased() == tried.host?.lowercased() {
            upgrades[id] = nil
            showInsecureWarning(for: tried, in: webView)
            return
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Can’t open page</title>
        <style>
        :root{color-scheme:light dark}
        body{font:15px -apple-system,system-ui;margin:0;min-height:100vh;display:grid;place-items:center;
             background:Canvas;color:CanvasText}
        main{max-width:460px;padding:32px}
        h1{font-size:22px;margin:0 0 8px}
        p{opacity:.7;line-height:1.5;margin:0 0 6px;overflow-wrap:anywhere}
        button{margin-top:16px;font:inherit;padding:7px 16px;border-radius:8px;border:1px solid GrayText;
               background:transparent;color:inherit}
        </style>
        <main><h1>Sorrel can’t open this page</h1>
        <p>\(esc(e.localizedDescription))</p>
        <p>\(esc(failing?.absoluteString ?? ""))</p>
        <button data-u="\(esc(failing?.absoluteString ?? "").replacingOccurrences(of: "\"", with: "&quot;"))"
                onclick="if(this.dataset.u)location.replace(this.dataset.u)">Try again</button></main>
        """
        loadInternalPage(html, baseURL: failing, in: webView)
    }

    // MARK: HTTPS-first

    static let insecureContinueScheme = "sorrel-insecure"

    /// Ordinary websites only. Local names, IP addresses and unusual ports (routers, printers,
    /// development servers) are left on http://, as other browsers do.
    static func canUpgrade(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.contains(".") else { return false }
        if let port = url.port, port != 80 { return false }
        let local = [".local", ".localhost", ".test", ".internal", ".lan", ".home", ".arpa", ".example", ".invalid"]
        if local.contains(where: { host.hasSuffix($0) }) { return false }
        if host.contains(":") || host.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Sorrel's own pages shown in place of a site (errors, warnings). Their load is let through untouched.
    private var internalLoads: [ObjectIdentifier: URL] = [:]

    private func loadInternalPage(_ html: String, baseURL: URL?, in webView: WKWebView) {
        if let baseURL { internalLoads[ObjectIdentifier(webView)] = baseURL }
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let pageStyle = """
    <style>
    :root{color-scheme:light dark}
    body{font:15px -apple-system,system-ui;margin:0;min-height:100vh;display:grid;place-items:center;
         background:Canvas;color:CanvasText}
    main{max-width:480px;padding:32px}
    h1{font-size:22px;margin:0 0 8px}
    p{opacity:.75;line-height:1.5;margin:0 0 8px;overflow-wrap:anywhere}
    button{margin:16px 8px 0 0;font:inherit;padding:7px 16px;border-radius:8px;border:1px solid GrayText;
           background:transparent;color:inherit}
    button.main{background:AccentColor;color:AccentColorText;border-color:AccentColor}
    </style>
    """

    /// The site has no working https:// version. Say so, and let the person choose.
    private func showInsecureWarning(for httpURL: URL, in webView: WKWebView) {
        insecureOffers[ObjectIdentifier(webView)] = httpURL
        let host = Self.escapeHTML(httpURL.host ?? "This site")
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>Not secure</title>\(Self.pageStyle)
        <main><h1>\(host) doesn’t offer a secure connection</h1>
        <p>Sorrel tried to open it with encryption (https) and couldn’t. If you continue, anyone on this
        network (café or campus Wi-Fi, for example) could see or change what you send and receive.</p>
        <p>Don’t type passwords or personal details on it.</p>
        <button class="main" onclick="history.length > 1 ? history.back() : window.close()">Go Back</button>
        <button onclick="location.href='\(Self.insecureContinueScheme):continue'">Continue to \(host)</button></main>
        """
        loadInternalPage(html, baseURL: httpURL, in: webView)
    }

    // MARK: Other apps

    /// What a quiet test saw instead of a prompt.
    private(set) var lastExternalPrompt: String?

    /// A page wants to open another app (zoommtg:, vscode:, …). Clicked mail and phone links just go;
    /// everything else asks, once per site and app until Sorrel quits.
    private func openInOtherApp(_ url: URL, from webView: WKWebView, clicked: Bool) {
        let scheme = (url.scheme ?? "").lowercased()
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if clicked { onToast?("No app on this Mac opens \(scheme): links") }
            return
        }
        let site = webView.url?.host?.lowercased() ?? ""
        let key = site + "|" + scheme
        if externalGrants.contains(key) || (clicked && Self.quietExternalSchemes.contains(scheme)) {
            NSWorkspace.shared.open(url)
            return
        }
        // Background tabs and repeated requests don't get to put up a prompt.
        guard webView.window != nil, !externalPromptOpen else { return }
        let appName = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let title = "Open \(appName)?"
        if isQuietTest { lastExternalPrompt = "\(title) [\(site)]"; return }   // testing: record, never open
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(site.isEmpty ? "This page" : site) wants to open \(appName) on your Mac."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        externalPromptOpen = true
        sheet(alert, for: webView) { [weak self] response in
            self?.externalPromptOpen = false
            guard response == .alertFirstButtonReturn else { return }
            self?.externalGrants.insert(key)
            NSWorkspace.shared.open(url)
        }
    }

    /// Web view -> when its page last crashed, to stop a page that keeps crashing from reloading forever.
    private var crashTimes: [ObjectIdentifier: [Date]] = [:]

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let id = ObjectIdentifier(webView)
        let recent = (crashTimes[id] ?? []).filter { Date().timeIntervalSince($0) < 60 } + [Date()]
        crashTimes[id] = recent
        if recent.count <= 2 {
            webView.reload()
        } else {
            crashTimes[id] = nil
            showError(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [
                NSLocalizedDescriptionKey: "This page stopped working several times in a row, so Sorrel stopped reloading it."]),
                in: webView)
        }
    }

    // MARK: New windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let source = page(webView)
        // A clicked "open in new window" link to another site becomes a preview instead.
        if let url = navigationAction.request.url, let source, shouldPeek(url, from: source, action: navigationAction) {
            onPeek?(url, source)
            return nil
        }
        let newPage = makePage(profileID: source?.profileID, configuration: configuration,
                               isPrivate: source?.isPrivate ?? false)
        onNewPage?(newPage, source)
        return newPage.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let p = page(webView) { onPageClosed?(p) }
    }

    // MARK: Dialogs

    /// Shows a page's dialog as a sheet on its own window. A tab that isn't on screen gets an immediate "Cancel":
    /// an app-wide modal dialog would freeze all of Sorrel and appear over whatever site is in front.
    private func sheet(_ alert: NSAlert, for webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else { completion(.cancel); return }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    /// Dialogs each page has shown since it loaded, and pages the person silenced (until they navigate).
    private var dialogCounts: [ObjectIdentifier: Int] = [:]
    private var silencedPages: Set<ObjectIdentifier> = []

    /// alert/confirm/prompt: from the second dialog on, offer to stop this page showing more.
    private func pageDialog(_ alert: NSAlert, for webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let id = ObjectIdentifier(webView)
        if silencedPages.contains(id) { completion(.cancel); return }
        let shown = dialogCounts[id, default: 0]
        dialogCounts[id] = shown + 1
        if shown >= 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don’t let this page show more dialogs"
        }
        sheet(alert, for: webView) { [weak self] response in
            if alert.showsSuppressionButton, alert.suppressionButton?.state == .on { self?.silencedPages.insert(id) }
            completion(response)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        pageDialog(alert, for: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        pageDialog(alert, for: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        pageDialog(alert, for: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what: String
        switch type {
        case .camera: what = "camera"
        case .microphone: what = "microphone"
        case .cameraAndMicrophone: what = "camera and microphone"
        @unknown default: what = "camera or microphone"
        }
        // Keyed by who asks and which site they are embedded in, so a grant to a video-call site
        // doesn't carry over to another site that embeds it. Private windows always ask.
        let isPrivate = page(webView)?.isPrivate ?? true
        let key = "\(origin.protocol)://\(origin.host):\(origin.port)|\(webView.url?.host ?? "")|\(what)"
        if !isPrivate, let granted = mediaGrants[key] {
            decisionHandler(granted ? .grant : .deny)
            return
        }
        guard webView.window != nil else { decisionHandler(.deny); return }   // hidden tabs can't ask
        let alert = NSAlert()
        let top = webView.url?.host ?? origin.host
        alert.messageText = "Allow \(origin.host) to use your \(what)?"
        alert.informativeText = (top == origin.host ? "" : "It is part of \(top). ")
            + (isPrivate ? "In a private window Sorrel asks every time." : "Sorrel remembers this choice until you quit.")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        sheet(alert, for: webView) { [weak self] response in
            let granted = response == .alertFirstButtonReturn
            if !isPrivate { self?.mediaGrants[key] = granted }
            decisionHandler(granted ? .grant : .deny)
        }
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        // A download the person didn't click for needs their OK, once per site until Sorrel quits.
        let started = sorrelStartedDownloads.remove(ObjectIdentifier(download)) != nil
        let site = download.webView?.url?.host?.lowercased() ?? download.originatingFrame.securityOrigin.host.lowercased()
        if started || download.isUserInitiated || downloadGrants.contains(site) {
            chooseDestination(for: download, response: response, suggestedFilename: suggestedFilename, completionHandler: completionHandler)
            return
        }
        let name = suggestedFilename.isEmpty ? "a file" : "“\(suggestedFilename)”"
        guard let webView = download.webView, webView.window != nil, !downloadPromptOpen, !isQuietTest else {
            // Hidden tabs and repeated requests don't get to ask (tests record it instead of asking).
            if isQuietTest { lastDownloadPrompt = "\(site): \(suggestedFilename)" }
            onToast?("Blocked a download from \(site.isEmpty ? "a page" : site)")
            completionHandler(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(site.isEmpty ? "this page" : site) to download files?"
        alert.informativeText = "It wants to save \(name) to your Downloads folder. You didn’t click a download link."
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        downloadPromptOpen = true
        sheet(alert, for: webView) { [weak self] answer in
            guard let self else { completionHandler(nil); return }
            self.downloadPromptOpen = false
            guard answer == .alertFirstButtonReturn else { completionHandler(nil); return }
            self.downloadGrants.insert(site)
            self.chooseDestination(for: download, response: response, suggestedFilename: suggestedFilename, completionHandler: completionHandler)
        }
    }

    /// What a quiet test saw instead of the download prompt.
    private(set) var lastDownloadPrompt: String?

    private func chooseDestination(for download: WKDownload, response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        var dir = Sandbox.downloads
        if let override = ProcessInfo.processInfo.environment["SORREL_DOWNLOADS"] {   // testing: never write to the real folder
            dir = URL(fileURLWithPath: override, isDirectory: true)
        }
        let clean = suggestedFilename.replacingOccurrences(of: "/", with: "_")
        let name = clean.isEmpty ? "download" : clean
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = dest
        let isPrivate = download.webView.flatMap({ page($0) })?.isPrivate == true
        if isPrivate { privateDownloads.insert(ObjectIdentifier(download)) }
        let record = DownloadRecord(file: dest)
        record.download = download
        record.isPrivate = isPrivate
        record.total = max(0, response.expectedContentLength)
        record.observation = download.progress.observe(\.fractionCompleted) { [weak record] progress, _ in
            let value = progress.fractionCompleted
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let record else { return }
                record.received = done
                if total > 0 { record.total = total }
                guard abs(value - record.fraction) >= 0.01 || value >= 1 else { return }
                record.fraction = value
                NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
            }
        }
        downloads.insert(record, at: 0)
        if downloads.count > 40 { downloads.removeLast() }
        NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
        onToast?("Downloading \(dest.lastPathComponent)…")
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        quarantine(dest, from: download, isPrivate: privateDownloads.remove(ObjectIdentifier(download)) != nil)
        if let r = record(for: download) {
            r.state = .done
            r.observation = nil
            r.fraction = 1
            r.finished = Date()
            if let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { r.received = Int64(size) }
            r.total = r.received
            downloadsChanged(save: true)
        }
        onToast?("Downloaded \(dest.lastPathComponent)")
        DistributedNotificationCenter.default().post(
            name: Notification.Name("com.apple.DownloadFileFinished"), object: dest.path)
    }

    /// Marks a downloaded file as coming from the internet, as Safari does. macOS then checks apps and
    /// installers with Gatekeeper and warns before opening them. Private downloads leave out the addresses,
    /// since macOS keeps a log of where quarantined files came from.
    private func quarantine(_ file: URL, from download: WKDownload, isPrivate: Bool) {
        var file = file
        let existing = (try? file.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        if isQuietTest {
            FileHandle.standardError.write("download: quarantine already set before Sorrel=\(existing != nil)\n".data(using: .utf8)!)
        }
        var props = existing ?? [:]
        props[kLSQuarantineAgentNameKey as String] = "Sorrel"
        props[kLSQuarantineTypeKey as String] = kLSQuarantineTypeWebDownload as String
        if isPrivate {
            props[kLSQuarantineDataURLKey as String] = nil
            props[kLSQuarantineOriginURLKey as String] = nil
        } else {
            if let u = download.originalRequest?.url { props[kLSQuarantineDataURLKey as String] = u }
            if let u = download.webView?.url, u.scheme?.hasPrefix("http") == true { props[kLSQuarantineOriginURLKey as String] = u }
        }
        var values = URLResourceValues()
        values.quarantineProperties = props
        try? file.setResourceValues(values)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        privateDownloads.remove(ObjectIdentifier(download))
        let dest = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        if let r = record(for: download) {
            r.state = .failed
            r.cancelled = r.cancelled || cancelled
            r.observation = nil
            r.finished = Date()
            NotificationCenter.default.post(name: .sorrelDownloads, object: nil)
        }
        if cancelled {
            onToast?("Download cancelled")
        } else {
            onToast?("Download failed: \(dest?.lastPathComponent ?? error.localizedDescription)")
        }
    }
}
