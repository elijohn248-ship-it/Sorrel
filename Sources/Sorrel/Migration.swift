import AppKit

/// The one-time move into the App Sandbox.
///
/// Sandboxed, Sorrel sees only its own container (~/Library/Containers/<bundle id>/Data), which macOS hands it
/// as its home folder. Everything from before lives outside it: the profile in "Application Support/Sorrel", and
/// the cookies, site data and extension storage that WebKit files under the bundle id. On the first sandboxed
/// launch Sorrel COPIES those into the container. Read-only access to exactly these paths comes from the
/// temporary-exception entitlement in Resources/Sorrel.entitlements; nothing outside can be written.
/// The originals are never changed or deleted: they are the owner's backup, and an unsandboxed build still
/// opens them.
///
/// Runs first thing (main.swift), only when sandboxed, only while the container has no profile yet, never in
/// test runs (SORREL_HOME), and never while an unsandboxed Sorrel is still running (a live cookie jar or
/// database copied mid-write could be corrupt). On any failure it quits without keeping a partial copy, so the
/// next launch retries. SORREL_MIGRATE_TEST=<from Library>:<to Library> runs the copy between two stand-in
/// folders, prints what it did, and exits.
///
/// (Before this, the same file held the 2026-11-14 copy from Drift's old names. That copy has run for the
/// owner; the Drift originals are still in place as a backup.)
enum Migration {
    static var id: String { Bundle.main.bundleIdentifier ?? "app.sorrel.browser" }

    /// What goes where: outside path (relative to the real ~/Library) -> container path (relative to the
    /// container's Library). The layouts differ: inside the sandbox WebKit drops the bundle-id folder, and the
    /// cookie jar is Cookies/Cookies.binarycookies (both found by experiment, 2026-11-14). WebKit's folder is
    /// copied item by item so per-space login stores (WebsiteDataStore/<uuid>) come along too. The profile
    /// folder goes last: its presence marks the move as done.
    static func moves(from: URL) -> [(String, String)] {
        let webkit = "WebKit/\(id)"
        let inside = (try? FileManager.default.contentsOfDirectory(atPath: from.appendingPathComponent(webkit).path)) ?? []
        return inside.sorted().filter { !$0.hasPrefix(".") }.map { ("\(webkit)/\($0)", "WebKit/\($0)") } + [
            ("HTTPStorages/\(id)", "HTTPStorages/\(id)"),
            ("HTTPStorages/\(id).binarycookies", "Cookies/Cookies.binarycookies"),
            ("Application Support/\(Paths.profileName)", "Application Support/\(Paths.profileName)"),
        ]
    }

    static func runIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if let pair = env["SORREL_MIGRATE_TEST"] {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { print("migrate: SORREL_MIGRATE_TEST needs <from>:<to>"); exit(2) }
            let report = copy(from: URL(fileURLWithPath: parts[0], isDirectory: true),
                              to: URL(fileURLWithPath: parts[1], isDirectory: true))
            FileHandle.standardError.write(("migrate: " + report.joined(separator: "\nmigrate: ") + "\n").data(using: .utf8)!)
            exit(0)
        }
        guard Sandbox.isOn, !isTestProfile else { return }
        let fm = FileManager.default
        let container = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let outside = Sandbox.realHome.appendingPathComponent("Library", isDirectory: true)
        let profile = "Application Support/\(Paths.profileName)"
        guard container.standardizedFileURL != outside.standardizedFileURL,
              !fm.fileExists(atPath: container.appendingPathComponent(profile).path),
              fm.fileExists(atPath: outside.appendingPathComponent(profile).path) else { return }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        guard unsandboxedCopyIsClosed() else { exit(0) }
        let report = copy(from: outside, to: container)
        if let failure = report.first(where: { $0.hasPrefix("FAILED") }) {
            alert("Birch couldn’t bring over your data",
                  "\(failure)\n\nNothing was changed: your tabs and logins are untouched. Quit, then try opening Birch again.",
                  buttons: ["Quit"])
            exit(1)
        }
        copyPreferences(from: outside.appendingPathComponent("Preferences/\(id).plist"))
    }

    /// Copies each item from one Library folder to the other, through a temporary name so a half-finished copy
    /// is never mistaken for a finished one. Returns one line per item.
    static func copy(from: URL, to: URL) -> [String] {
        let fm = FileManager.default
        var report: [String] = []
        var staged: [(tmp: URL, dest: URL)] = []
        let stamp = Int(Date().timeIntervalSince1970)
        for (item, target) in moves(from: from) {
            let src = from.appendingPathComponent(item), dest = to.appendingPathComponent(target)
            guard fm.fileExists(atPath: src.path) else { report.append("skip (none) \(item)"); continue }
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + ".migrating")
            do {
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: tmp)
                staged.append((tmp, dest))
            } catch {
                for s in staged { try? fm.removeItem(at: s.tmp) }
                try? fm.removeItem(at: tmp)
                return report + ["FAILED copying \(item): \(error.localizedDescription)"]
            }
        }
        for (tmp, dest) in staged {
            // WebKit may already have made an empty folder in the container; set anything there aside, never delete it.
            if fm.fileExists(atPath: dest.path) {
                let aside = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + ".before-migration-\(stamp)")
                try? fm.moveItem(at: dest, to: aside)
                report.append("set aside existing \(dest.lastPathComponent)")
            }
            do {
                try fm.moveItem(at: tmp, to: dest)
                report.append("copied \(dest.lastPathComponent)")
            } catch {
                return report + ["FAILED finishing \(dest.lastPathComponent): \(error.localizedDescription)"]
            }
        }
        let profile = to.appendingPathComponent("Application Support/\(Paths.profileName)")
        if fm.fileExists(atPath: profile.path) {
            try? "Copied into the App Sandbox container on \(Date()).\nThe originals are still in ~/Library (see CLAUDE.md, Sandbox).\n"
                .write(to: profile.appendingPathComponent("moved-into-sandbox.txt"), atomically: true, encoding: .utf8)
        }
        return report
    }

    /// Window size and position and the like. Inside the sandbox UserDefaults reads the container's copy.
    private static func copyPreferences(from file: URL) {
        guard let old = NSDictionary(contentsOf: file) as? [String: Any] else { return }
        let defaults = UserDefaults.standard
        var new = defaults.persistentDomain(forName: id) ?? [:]
        for (key, value) in old where new[key] == nil { new[key] = value }
        defaults.setPersistentDomain(new, forName: id)
    }

    /// An older, unsandboxed Sorrel (same bundle id) must be closed so its cookie jar and databases aren't
    /// copied mid-write. Offers to quit it.
    private static func unsandboxedCopyIsClosed() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        if running.isEmpty { return true }
        let choice = alert("An older copy is still open",
                           "This version of Birch keeps its data in a protected place. To bring over your tabs, logins and extensions, the older copy (Sorrel) needs to be closed first.",
                           buttons: ["Quit It and Continue", "Cancel"])
        guard choice == .alertFirstButtonReturn else { return false }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            running = running.filter { !$0.isTerminated }
            if running.isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        alert("The older copy didn’t quit", "Quit it yourself (⌘Q), then open Birch again.", buttons: ["OK"])
        return false
    }

    @discardableResult
    private static func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        buttons.forEach { a.addButton(withTitle: $0) }
        return a.runModal()
    }
}
