import Foundation

/// Makes extensions written for Chrome more likely to run on WebKit.
///
/// Chrome has features WebKit lacks. An extension that touches one at start-up (for example
/// `chrome.runtime.onUpdateAvailable.addListener(...)`) throws, and its background script dies before
/// doing anything. This adds a small script that runs first, everywhere the extension runs, and fills
/// those gaps with harmless stand-ins: events that never fire and calls that report "not available".
/// It changes nothing that WebKit already provides.
enum ChromeCompat {
    static let shimName = "sorrel-chrome-compat.js"
    static let backgroundName = "sorrel-background.js"
    static let bridgeName = "sorrel-page-bridge.js"

    /// Runs inside the few websites an extension says it talks to (its own sign-in pages, typically).
    /// Chrome gives those pages `chrome.runtime` for messaging the extension; WebKit gives them the same
    /// thing under the name `browser.runtime`. This makes the Chrome name point at it.
    static let bridge = #"""
    (() => {
      if ("chrome" in window && window.chrome && window.chrome.runtime) return;
      try {
        Object.defineProperty(window, "chrome", {
          configurable: true,
          get() { return window.browser && window.browser.runtime ? { runtime: window.browser.runtime } : undefined; }
        });
      } catch (e) {}
    })();
    """#
    /// The `externally_connectable` patterns that name exact hosts ("https://account.proton.me/*"). Patterns with a
    /// wildcard host ("*://*.google.com/*") would hand a whole family of sites Chrome's identity and the page
    /// bridge, so they are left out (CLAUDE.md, Security invariants: ask before widening this).
    static func exactHostPatterns(_ matches: [String]) -> [String] {
        matches.filter { pattern in
            guard let range = pattern.range(of: "://") else { return false }
            let host = pattern[range.upperBound...].prefix { $0 != "/" }
            return !host.isEmpty && !host.contains("*")
        }
    }

    private static let marker = "sorrel_compat"
    private static let version = 14
    /// The names this layer used before the app was renamed. A copy patched back then chains through them;
    /// `apply` collapses the chain so the extension runs the current layer straight from its own files.
    private static let oldPrefix = "drift"

    static let shim = #"""
    // Added by Sorrel. Fills in Chrome features that WebKit does not have, so the extension can start.
    // It only ever adds things that are missing. Nothing WebKit provides is wrapped or replaced:
    // wrapping the API, even transparently, stops messages reaching the background script.
    (() => {
      const g = globalThis;
      if (g.__sorrelCompat) return;
      g.__sorrelCompat = true;

      // Chrome schedules low-priority work with requestIdleCallback. WebKit has no such function, and a
      // script that calls it (Proton Pass's in-page autofill does) stops dead. A short timer stands in.
      if (typeof g.requestIdleCallback !== "function") {
        g.requestIdleCallback = (callback, options) => setTimeout(() => {
          const started = Date.now();
          callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - started)) });
        }, 1);
        g.cancelIdleCallback = (id) => clearTimeout(id);
      }

      const quietEvent = () => ({
        addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; },
        addRules() {}, removeRules() {}, getRules() {}
      });
      const unavailable = (what) => () => Promise.reject(new Error(what + " is not available in Sorrel"));
      const add = (obj, key, make) => {
        try {
          if (obj && obj[key] === undefined) Object.defineProperty(obj, key, { value: make(), configurable: true, writable: true });
        } catch (e) {}
      };

      // Events Chrome has and WebKit lacks. Listeners can be added; they are simply never called.
      const missingEvents = {
        runtime: ["onUpdateAvailable", "onRestartRequired", "onSuspend", "onSuspendCanceled", "onBrowserUpdateAvailable",
                  "onUserScriptConnect", "onUserScriptMessage", "onConnectNative"],
        webRequest: ["onAuthRequired", "onActionIgnored"],
        tabs: ["onZoomChange", "onHighlighted", "onAttached", "onDetached"],
        windows: ["onBoundsChanged"],
        storage: ["onChanged"],
        action: ["onUserSettingsChanged"],
        permissions: ["onAdded", "onRemoved"],
        webNavigation: ["onTabReplaced", "onCreatedNavigationTarget"],
        alarms: ["onAlarm"],
        commands: ["onCommand"],
        notifications: ["onClicked", "onClosed", "onButtonClicked", "onShown"]
      };
      // Calls Chrome has and WebKit lacks.
      const missingCalls = {
        runtime: {
          requestUpdateCheck: () => () => Promise.resolve({ status: "no_update" }),
          getContexts: () => () => Promise.resolve([]),
          setUninstallURL: () => () => Promise.resolve(),
          restart: () => () => {},
          getPackageDirectoryEntry: () => unavailable("chrome.runtime.getPackageDirectoryEntry")
        }
      };
      // Whole areas Chrome has and WebKit lacks. Present, so the extension can ask; every real request says no.
      const missingAreas = {
        offscreen: () => ({
          Reason: new Proxy({}, { get: (_, p) => String(p) }),
          createDocument: unavailable("chrome.offscreen"),
          closeDocument: () => Promise.resolve(),
          hasDocument: () => Promise.resolve(false)
        }),
        idle: () => ({
          IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" },
          queryState: () => Promise.resolve("active"),
          setDetectionInterval() {},
          onStateChanged: quietEvent()
        }),
        management: () => ({ getSelf: unavailable("chrome.management"), onEnabled: quietEvent(), onDisabled: quietEvent() }),
        notifications: () => ({
          create: () => Promise.resolve(""), clear: () => Promise.resolve(false), getAll: () => Promise.resolve({}),
          onClicked: quietEvent(), onClosed: quietEvent(), onButtonClicked: quietEvent(), onShown: quietEvent()
        })
      };

      // Some extensions (Proton Pass among them) replace the global API object with a locked stand-in
      // shortly after starting, to keep page scripts away from it. On WebKit that silently stops every
      // message reaching the extension, because WebKit looks its listeners up through that global.
      // So the globals are pinned: reads keep returning the real object and later replacements are ignored.
      const pin = (name) => {
        const real = g[name];
        if (!real || typeof real !== "object") return;
        try {
          Object.defineProperty(g, name, { get: () => real, set: () => {}, configurable: false, enumerable: true });
        } catch (e) {}
      };
      if (!g.__sorrelNoPin) { pin("chrome"); pin("browser"); }

      const seen = new Set();
      for (const name of ["chrome", "browser"]) {
        const api = g[name];
        if (!api || typeof api !== "object" || seen.has(api)) continue;
        seen.add(api);
        for (const [area, make] of Object.entries(missingAreas)) add(api, area, make);
        for (const [area, names] of Object.entries(missingEvents)) {
          let target;
          try { target = api[area]; } catch (e) {}
          if (target && typeof target === "object") for (const n of names) add(target, n, quietEvent);
        }
        for (const [area, calls] of Object.entries(missingCalls)) {
          let target;
          try { target = api[area]; } catch (e) {}
          if (target && typeof target === "object") for (const [n, make] of Object.entries(calls)) add(target, n, make);
        }
      }
    })();
    """#

    /// Testing only (SORREL_EXTDIAG): makes every part of the extension report its errors, warnings and
    /// key actions back to Sorrel, so a silent failure can be traced.
    static let reporter = #"""
    (() => {
      const g = globalThis;
      if (g.__sorrelReporter) return;
      g.__sorrelReporter = true;
      const where = (typeof ServiceWorkerGlobalScope !== "undefined" && g instanceof ServiceWorkerGlobalScope) ? "background"
                  : (g.location && g.location.protocol && g.location.protocol.indexOf("extension") >= 0 ? "page " + g.location.pathname : "content script");
      // Keep our own handle on the API: some extensions lock the global one after start-up.
      const held = g.chrome || g.browser;
      g.__sorrelHeld = held;   // lets a test send its own messages even after the extension locks the API
      // Pages and the background can report to Sorrel directly. Content scripts cannot, so they leave
      // their log on the page itself, where a test can read it.
      const nativeSend = held.runtime.sendNativeMessage ? held.runtime.sendNativeMessage.bind(held.runtime) : null;
      const kept = [];
      const send = (msg) => {
        const text = String(msg).slice(0, 500);
        if (nativeSend) { try { nativeSend("sorrel-diag", { where, msg: text }).catch(() => {}); } catch (e) {} return; }
        kept.push(text);
        try { document.documentElement.setAttribute("data-sorrel-extlog", JSON.stringify(kept.slice(-25))); } catch (e) {}
      };
      g.addEventListener("error", (e) => send("error: " + (e.message || e.type) + " @" + String(e.filename || "").split("/").pop() + ":" + e.lineno));
      g.addEventListener("unhandledrejection", (e) => send("rejection: " + String(e.reason && (e.reason.stack || e.reason.message || e.reason)).slice(0, 400)));
      for (const k of ["error", "warn", "info", "log", "debug"]) {
        const o = console[k];
        console[k] = function () { send(k + ": " + Array.prototype.map.call(arguments, (a) => (a && (a.message || a.stack)) || (typeof a === "object" ? JSON.stringify(a) : String(a))).join(" ")); return o.apply(console, arguments); };
      }
      if (g.close && where.indexOf("page") === 0) { const c = g.close.bind(g); g.close = () => { send("window.close() called"); }; }
      if (where === "background") {
        // A second, passive listener: it only reports what arrives and never answers.
        try { held.runtime.onMessage.addListener((m) => { send("saw message " + JSON.stringify(m).slice(0, 120)); }); } catch (e) { send("could not listen: " + e.message); }
        try { held.runtime.onConnect.addListener((p) => { send("saw connection " + p.name); }); } catch (e) {}
        let beats = 0;
        setInterval(() => { beats += 1; if (beats <= 6) send("still running (" + beats * 4 + "s)"); }, 4000);
      }
      send("started");
    })();
    """#

    /// Adds the compatibility script to an unpacked extension, in place. Safe to call repeatedly.
    @discardableResult
    static func apply(to dir: URL) -> Bool {
        let fm = FileManager.default
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let env = ProcessInfo.processInfo.environment
        let diagnosing = env["SORREL_EXTDIAG"] != nil
        var shim = (diagnosing && env["SORREL_COMPAT_NOREPORTER"] == nil) ? self.shim + "\n" + reporter : self.shim
        if env["SORREL_COMPAT_OFF"] != nil { shim = "// compatibility layer switched off for a test\n" }
        if env["SORREL_COMPAT_NOPIN"] != nil { shim = "globalThis.__sorrelNoPin = true;\n" + shim }
        if (manifest[marker] as? Int) == version {
            // Already done; keep the script itself current.
            try? shim.write(to: dir.appendingPathComponent(shimName), atomically: true, encoding: .utf8)
            return true
        }
        guard (try? shim.write(to: dir.appendingPathComponent(shimName), atomically: true, encoding: .utf8)) != nil else { return false }
        let oldShim = "\(oldPrefix)-chrome-compat.js", oldLoader = "\(oldPrefix)-background.js", oldBridge = "\(oldPrefix)-page-bridge.js"

        // Background: run the compatibility script before the extension's own background script.
        if var background = manifest["background"] as? [String: Any] {
            if let worker = background["service_worker"] as? String, worker != backgroundName || manifest["\(oldPrefix)_original_worker"] != nil {
                // The extension's own worker: recorded by this layer, or by its older name, else the manifest's.
                var original = (manifest["sorrel_original_worker"] as? String) ?? worker
                if original == oldLoader || original == backgroundName, let older = manifest["\(oldPrefix)_original_worker"] as? String { original = older }
                manifest["\(oldPrefix)_original_worker"] = nil
                manifest["\(oldPrefix)_compat"] = nil
                let isModule = (background["type"] as? String) == "module"
                let path = original.hasPrefix("/") ? original : "/" + original
                let loader = isModule
                    ? "import \"/\(shimName)\";\nimport \"\(path)\";\n"
                    : "importScripts(\"/\(shimName)\", \"\(path)\");\n"
                try? loader.write(to: dir.appendingPathComponent(backgroundName), atomically: true, encoding: .utf8)
                background["service_worker"] = backgroundName
                manifest["sorrel_original_worker"] = original
            } else if var scripts = background["scripts"] as? [String] {
                scripts.removeAll { $0 == oldShim || $0 == "/" + oldShim }
                if !scripts.contains(shimName), !scripts.contains("/" + shimName) { scripts.insert(shimName, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts: the compatibility script goes first in each group. Groups that run inside the
        // page itself ("MAIN" world) are left alone: the extension API is not there, and pages must not see ours.
        do {
            // (An extension with no content scripts of its own still gets the page bridge below.)
            var groups = (manifest["content_scripts"] as? [[String: Any]]) ?? []
            for i in groups.indices {
                var js = (groups[i]["js"] as? [String]) ?? []
                js.removeAll { $0 == oldShim }
                groups[i]["js"] = js
                let inPage = (groups[i]["world"] as? String) == "MAIN"
                if inPage {
                    js.removeAll { $0 == shimName }
                    groups[i]["js"] = js
                } else if !js.isEmpty, !js.contains(shimName) {
                    js.insert(shimName, at: 0)
                    groups[i]["js"] = js
                }
            }
            // Sites the extension declares it exchanges messages with get the Chrome-style entry point.
            groups.removeAll { ($0["js"] as? [String]) == [bridgeName] || ($0["js"] as? [String]) == [oldBridge] }
            if let external = manifest["externally_connectable"] as? [String: Any],
               case let matches = exactHostPatterns((external["matches"] as? [String]) ?? []), !matches.isEmpty {
                try? bridge.write(to: dir.appendingPathComponent(bridgeName), atomically: true, encoding: .utf8)
                groups.insert(["matches": matches, "js": [bridgeName], "world": "MAIN", "run_at": "document_start",
                               "all_frames": false], at: 0)
            }
            if !groups.isEmpty { manifest["content_scripts"] = groups }
        }

        // The extension's own pages (pop-up, settings): load the compatibility script before anything else.
        let tag = "<script src=\"/\(shimName)\"></script>"
        if let files = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension.lowercased() == "html" {
                guard var html = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if html.contains(oldShim) {
                    html = html.replacingOccurrences(of: "<script src=\"/\(oldShim)\"></script>", with: "")
                    try? html.write(to: file, atomically: true, encoding: .utf8)
                }
                guard !html.contains(shimName) else { continue }
                if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                    html.insert(contentsOf: tag, at: head.upperBound)
                } else if let body = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                    html.insert(contentsOf: tag, at: body.upperBound)
                } else {
                    html = tag + html
                }
                try? html.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        // Scripts the extension runs inside web pages themselves cannot use the compatibility script
        // (pages must not see it). Where one of them needs requestIdleCallback, it gets a private copy:
        // the file is wrapped so the stand-in exists only inside that file.
        var pageScripts: Set<String> = []
        for group in (manifest["content_scripts"] as? [[String: Any]]) ?? [] where (group["world"] as? String) == "MAIN" {
            for file in (group["js"] as? [String]) ?? [] where file != bridgeName { pageScripts.insert(file) }
        }
        for group in (manifest["web_accessible_resources"] as? [[String: Any]]) ?? [] {
            for file in (group["resources"] as? [String]) ?? [] where file.hasSuffix(".js") && !file.contains("*") { pageScripts.insert(file) }
        }
        let idleMarker = "/*sorrel-idle*/"
        for file in pageScripts {
            let url = dir.appendingPathComponent(file.hasPrefix("/") ? String(file.dropFirst()) : file)
            guard var code = try? String(contentsOf: url, encoding: .utf8), !code.hasPrefix(idleMarker),
                  code.contains("requestIdleCallback") || code.contains("cancelIdleCallback"),
                  code.range(of: "(^|\\n)(import|export)\\s", options: .regularExpression) == nil else { continue }
            code = idleMarker + "(()=>{const requestIdleCallback=globalThis.requestIdleCallback||((cb)=>setTimeout(()=>{const s=Date.now();cb({didTimeout:false,timeRemaining:()=>Math.max(0,50-(Date.now()-s))})},1));"
                + "const cancelIdleCallback=globalThis.cancelIdleCallback||((id)=>clearTimeout(id));\n" + code + "\n})();\n"
            try? code.write(to: url, atomically: true, encoding: .utf8)
        }

        guardChromeOnlyEvents(in: dir, skipping: [shimName, bridgeName, backgroundName])

        for old in [oldShim, oldLoader, oldBridge] { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
        manifest[marker] = version
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        return (try? out.write(to: manifestURL, options: .atomic)) != nil
    }

    /// Chrome-only events (no WebKit equivalent). The shim gives each an inert stand-in, but on some
    /// background restarts WebKit hands the worker fresh `runtime`/`webRequest`/… objects without them
    /// (seen with Proton Pass: `runtime.onUpdateAvailable` undefined at start-up, background dead).
    private static let chromeOnlyEvents = [
        "onUpdateAvailable", "onRestartRequired", "onSuspend", "onSuspendCanceled", "onBrowserUpdateAvailable",
        "onUserScriptConnect", "onUserScriptMessage", "onConnectNative", "onAuthRequired", "onActionIgnored",
        "onZoomChange", "onHighlighted", "onBoundsChanged", "onUserSettingsChanged", "onTabReplaced", "onCreatedNavigationTarget"
    ]

    /// So the extension's own code reaches those events with optional chaining: `x.onUpdateAvailable.addListener(f)`
    /// becomes `x.onUpdateAvailable?.addListener(f)`. Where the stand-in is present nothing changes; where it is
    /// missing the line does nothing instead of throwing. Only these exact member chains are touched.
    private static func guardChromeOnlyEvents(in dir: URL, skipping ours: Set<String>) {
        let names = chromeOnlyEvents.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "\\.(\(names))\\.(addListener|removeListener|hasListener)\\(") else { return }
        guard let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension.lowercased() == "js" && !ours.contains(file.lastPathComponent) {
            guard let code = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(code.startIndex..., in: code)
            guard regex.firstMatch(in: code, range: range) != nil else { continue }
            let guarded = regex.stringByReplacingMatches(in: code, range: range, withTemplate: ".$1?.$2(")
            try? guarded.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
