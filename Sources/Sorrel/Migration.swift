import AppKit

/// The one-time move from Drift (Sorrel's old name, bundle id app.drift.browser) to Sorrel.
///
/// WebKit and macOS file cookies, site data, extension storage and preferences by bundle id, and Sorrel's own
/// profile lived in "Application Support/Drift". On the first real launch Sorrel COPIES all of that to its own
/// places. The Drift originals are never changed or deleted: they stay as a backup until the owner removes them.
///
/// It runs before anything else touches those folders (main.swift), only when Sorrel has no profile of its own
/// yet, never in test runs (SORREL_HOME), and never while Drift is still running (a live cookie jar or
/// database copied mid-write could be corrupt). SORREL_MIGRATE_TEST=<folder> runs the copy against a
/// stand-in Library folder instead, prints what it did, and exits.
enum Migration {
    static let oldID = "app.drift.browser"
    static let newID = "app.sorrel.browser"

    /// Old -> new, relative to ~/Library. The profile folder goes last: its presence marks the move as done.
    static let moves: [(String, String)] = [
        ("WebKit/\(oldID)", "WebKit/\(newID)"),
        ("HTTPStorages/\(oldID)", "HTTPStorages/\(newID)"),
        ("HTTPStorages/\(oldID).binarycookies", "HTTPStorages/\(newID).binarycookies"),
        ("Application Support/Drift", "Application Support/Sorrel"),
    ]

    static func runIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        if let fake = env["SORREL_MIGRATE_TEST"] {
            let report = copy(library: URL(fileURLWithPath: fake, isDirectory: true))
            FileHandle.standardError.write(("migrate: " + report.joined(separator: "\nmigrate: ") + "\n").data(using: .utf8)!)
            exit(0)
        }
        if isTestProfile { return }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let fm = FileManager.default
        guard fm.fileExists(atPath: library.appendingPathComponent("Application Support/Drift").path),
              !fm.fileExists(atPath: library.appendingPathComponent("Application Support/Sorrel").path) else { return }

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        guard driftIsClosed() else { exit(0) }
        let report = copy(library: library)
        if let failure = report.first(where: { $0.hasPrefix("FAILED") }) {
            alert("Sorrel couldn’t bring over your Drift data",
                  "\(failure)\n\nNothing was changed: your Drift data is untouched. Quit, then try opening Sorrel again.",
                  buttons: ["Quit"])
            exit(1)
        }
        copyPreferences()
    }

    /// Copies each old folder or file to its new place, through a temporary name so a half-finished copy is
    /// never mistaken for a finished one. Returns one line per item.
    static func copy(library: URL) -> [String] {
        let fm = FileManager.default
        var report: [String] = []
        var staged: [(tmp: URL, dest: URL)] = []
        let stamp = Int(Date().timeIntervalSince1970)
        for (old, new) in moves {
            let src = library.appendingPathComponent(old), dest = library.appendingPathComponent(new)
            guard fm.fileExists(atPath: src.path) else { report.append("skip (none) \(old)"); continue }
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + ".migrating")
            do {
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: src, to: tmp)
                staged.append((tmp, dest))
            } catch {
                for s in staged { try? fm.removeItem(at: s.tmp) }
                try? fm.removeItem(at: tmp)
                return report + ["FAILED copying \(old): \(error.localizedDescription)"]
            }
        }
        for (tmp, dest) in staged {
            // Anything already at the new place can only be from a test launch: set it aside, never delete it.
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
        // Saved tabs pointed at Sorrel's own pages by their old address.
        let profile = library.appendingPathComponent("Application Support/Sorrel")
        for name in ["state.json", "archive.json"] {
            let file = profile.appendingPathComponent(name)
            if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("drift://") {
                try? text.replacingOccurrences(of: "drift://", with: "sorrel://").write(to: file, atomically: true, encoding: .utf8)
                report.append("updated drift:// addresses in \(name)")
            }
        }
        if fm.fileExists(atPath: profile.path) {
            try? "Copied from Drift on \(Date()).\nThe originals are still in place; see CLAUDE.md (Name) for where.\n"
                .write(to: profile.appendingPathComponent("migrated-from-drift.txt"), atomically: true, encoding: .utf8)
        }
        return report
    }

    /// Window size and position and the like. The main window's saved frame was named after Drift.
    private static func copyPreferences() {
        let defaults = UserDefaults.standard
        guard let old = defaults.persistentDomain(forName: oldID) else { return }
        // Drift's values win: anything already under the new name can only be from a test launch.
        var new = defaults.persistentDomain(forName: newID) ?? [:]
        for (key, value) in old { new[key.replacingOccurrences(of: "DriftMainWindow", with: "SorrelMainWindow")] = value }
        defaults.setPersistentDomain(new, forName: newID)
    }

    /// Drift must be closed so its cookie jar and databases aren't copied mid-write. Offers to quit it.
    private static func driftIsClosed() -> Bool {
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: oldID)
        if running.isEmpty { return true }
        let choice = alert("Drift is still open",
                           "Sorrel is Drift with its new name. To bring over your tabs, logins and extensions, Drift needs to be closed first.",
                           buttons: ["Quit Drift and Continue", "Cancel"])
        guard choice == .alertFirstButtonReturn else { return false }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            running = running.filter { !$0.isTerminated }
            if running.isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        alert("Drift didn’t quit", "Quit Drift yourself (⌘Q in Drift), then open Sorrel again.", buttons: ["OK"])
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
