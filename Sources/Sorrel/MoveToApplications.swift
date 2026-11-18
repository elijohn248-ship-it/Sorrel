// Moving a downloaded copy into Applications (CLAUDE.md, Updates ▸ Known limits).
//
// A release zip opened from Downloads runs translocated: macOS starts it from a hidden read-only copy, where
// the updater can never replace it. At launch Sorrel offers to move itself; the sandboxed app can't write to
// Applications, so SorrelUpdater.xpc does the copy and a detached helper swaps it in once Sorrel quits, trashes
// the copy in Downloads and opens the one in Applications (SorrelUpdater/main.swift, `moveToApplications`).
import AppKit
import SorrelUpdateCore

enum MoveToApplications {
    static var isTranslocated: Bool {
        let path = Bundle.main.bundleURL.path
        // The test build treats a copy under /private/tmp as translocated (only Launch Services can translocate;
        // the service makes the same exception for the test build only).
        return path.contains("/AppTranslocation/") || (isTestBuild && path.hasPrefix("/private/tmp/"))
    }

    /// At launch: ask once per launch while Sorrel runs translocated.
    static func offerAtLaunch() {
        guard !isQuietTest, isTranslocated else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { offer(because: nil) }
    }

    /// The question, also used when an update can't install because of where Sorrel is.
    static func offer(because reason: String?) {
        let a = NSAlert()
        a.messageText = "Move Birch to Applications?"
        a.informativeText = (reason.map { $0 + "\n\n" } ?? "")
            + "Birch is running from your Downloads folder, where macOS won't let it update itself. Birch can move itself into Applications and reopen from there. Your tabs and settings stay as they are."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        move { error in
            guard let error else { NSApp.terminate(nil); return }
            let e = NSAlert()
            e.messageText = "Birch couldn't move itself"
            e.informativeText = error + "\n\nYou can quit Birch, drag it from Downloads into Applications, and open it from there."
            e.runModal()
        }
    }

    /// Asks the updater service to do the move. The completion runs on the main thread: nil means the helper is
    /// waiting for Sorrel to quit.
    static func move(completion: @escaping (String?) -> Void) {
        guard isTranslocated else { completion("Birch isn't running from a download."); return }
        guard let id = Bundle.main.bundleIdentifier else { completion("Birch has no bundle id."); return }
        // Another Sorrel running (say, an older copy already in Applications) would be swapped out from under it.
        let me = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me }) {
            completion("Another copy of Birch is open. Quit it first, then try again."); return
        }
        guard let logHandle = Updater.openForAppending(Updater.shared.folder.appendingPathComponent("update.log")) else {
            completion("Couldn’t open update.log."); return
        }
        let connection = NSXPCConnection(serviceName: id + UpdaterService.suffix)
        connection.remoteObjectInterface = NSXPCInterface(with: SorrelUpdaterXPC.self)
        connection.resume()
        var done = false
        let finish: (String?) -> Void = { error in
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                guard !done else { return }
                done = true
                connection.invalidate()
                completion(error)
            }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish("Couldn't reach the updater: \(error.localizedDescription)")
        }) as? SorrelUpdaterXPC else { finish("The updater is unavailable."); return }
        proxy.moveToApplications(pid: me, log: logHandle) { error in finish(error) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { finish("The updater didn't answer.") }
    }

    /// SORREL_MOVETEST=1: the move without the question; logs `move:` lines and quits.
    static func runTest() {
        func log(_ s: String) { FileHandle.standardError.write("move: \(s)\n".data(using: .utf8)!) }
        log("running app=\(Bundle.main.bundleURL.path) translocated=\(isTranslocated)")
        move { error in
            log("handoff \(error ?? "ok")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }
}
