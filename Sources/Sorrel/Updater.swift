import AppKit
import SorrelUpdateCore

extension Notification.Name {
    /// Posted on the main thread whenever Updater.state changes.
    static let sorrelUpdateState = Notification.Name("sorrelUpdateState")
}

/// Keeps Sorrel current from the owner's GitHub releases (see CLAUDE.md, Updates).
///
/// Sorrel itself only fetches updates.json and the zip, checks the zip against the built-in Ed25519 key and
/// hands the file to SorrelUpdater.xpc, the unsandboxed service in the bundle that does the swap after Sorrel
/// has quit. A ready update installs when Sorrel quits, or straight away from Sorrel ▸ Relaunch to Update.
/// No request carries anything about the person or the Mac.
final class Updater: NSObject, URLSessionDownloadDelegate {
    static let shared = Updater()

    enum State {
        case idle, checking
        case upToDate
        case downloading(UpdateManifest, Double)
        case ready(UpdateManifest, URL)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { DispatchQueue.main.async { NotificationCenter.default.post(name: .sorrelUpdateState, object: nil) } }
    }

    /// Where downloads, the last-check stamp and update.log live.
    let folder: URL = {
        let dir = Paths.support.appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var stamp: URL { folder.appendingPathComponent("last-check") }
    private var marker: URL { folder.appendingPathComponent("installing") }
    private var logFile: URL { folder.appendingPathComponent("update.log") }

    private let env = ProcessInfo.processInfo.environment
    /// Test runs of the test build may point at a local manifest (file:// or https://).
    private lazy var feed: URL = {
        if isTestBuild, let s = env["SORREL_UPDATE_FEED"], let u = URL(string: s) { return u }
        return UpdateConfig.feedURL
    }()
    let current = BundleInfo.current
    /// macOS runs a quarantined app straight from Downloads at a hidden read-only path; it can't be replaced there.
    let isTranslocated = Bundle.main.bundleURL.path.contains("/AppTranslocation/")

    private var timer: Timer?
    private var manual = false
    private var session: URLSession?
    private var downloadingManifest: UpdateManifest?
    private var installing = false
    private var allowInstallOnQuit = true
    private let checkEvery: TimeInterval = 6 * 3600

    private func tlog(_ s: String) {
        if env["SORREL_SNAPSHOT"] != nil { FileHandle.standardError.write("updater: \(s)\n".data(using: .utf8)!) }
    }

    // MARK: Lifecycle

    func start() {
        noteJustUpdated()
        // Tests never reach the network (or the updater) unless they are update tests.
        guard !isQuietTest || env["SORREL_UPDATETEST"] != nil else { return }
        guard env["SORREL_UPDATETEST"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    /// After an update: say so once, and drop archives that are no longer newer than what is running.
    private func noteJustUpdated() {
        let fm = FileManager.default
        if let text = try? String(contentsOf: marker, encoding: .utf8), let build = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try? fm.removeItem(at: marker)
            if let current, build == current.build {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    AppDelegate.shared.main.showToast("Sorrel updated to \(current.version)")
                }
            }
        }
        for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "zip" {
            if let build = Self.build(ofZip: file), build <= (current?.build ?? 0) { try? fm.removeItem(at: file) }
        }
    }

    private static func build(ofZip url: URL) -> Int? {
        Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "")
    }

    private func zipURL(for m: UpdateManifest) -> URL { folder.appendingPathComponent("Sorrel-\(m.build).zip") }

    private func checkIfDue() {
        guard Settings.current.checkForUpdates, !isTranslocated else { return }
        if let date = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < checkEvery { return }
        check(manual: false)
    }

    // MARK: Checking

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: return true
        default: return false
        }
    }

    var readyManifest: UpdateManifest? {
        if case .ready(let m, _) = state { return m }
        return nil
    }

    func check(manual: Bool) {
        guard !isBusy else { return }
        if case .ready(let m, _) = state {
            if manual { offerRelaunch(m) }
            return
        }
        self.manual = manual
        state = .checking
        try? Data().write(to: stamp)
        tlog("checking \(feed.absoluteString)")
        fetch(feed) { [weak self] result in
            DispatchQueue.main.async { self?.handleFeed(result) }
        }
    }

    private func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        if url.isFileURL {
            completion(Result { try Data(contentsOf: url) })
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession(configuration: .ephemeral).dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completion(.failure(UpdateSigning.Failure("The update server answered \(http.statusCode)")))
                return
            }
            completion(.success(data ?? Data()))
        }.resume()
    }

    private func handleFeed(_ result: Result<Data, Error>) {
        let manifest: UpdateManifest
        switch result {
        case .failure(let error):
            fail("Couldn't check for updates: \(error.localizedDescription)")
            return
        case .success(let data):
            guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
                fail("Couldn't read the update list")
                return
            }
            manifest = m
        }
        guard let current else { fail("This copy of Sorrel has no version number"); return }
        tlog("feed version=\(manifest.version) build=\(manifest.build) running=\(current.build)")
        guard manifest.build > current.build else {
            state = .upToDate
            if manual { toast("Sorrel \(current.version) is up to date") }
            return
        }
        guard manifest.runsOnThisMac() else {
            fail("Sorrel \(manifest.version) needs macOS \(manifest.minimumSystemVersion ?? "")")
            return
        }
        let zip = zipURL(for: manifest)
        if FileManager.default.fileExists(atPath: zip.path),
           (try? UpdateSigning.verify(file: zip, signature: manifest.signature, sha256: manifest.sha256, size: manifest.size)) != nil {
            becameReady(manifest, zip)
            return
        }
        download(manifest)
    }

    private func fail(_ message: String) {
        tlog("failed: \(message)")
        state = .failed(message)
        if manual { toast(message) }
    }

    private func toast(_ text: String) {
        guard !isQuietTest else { return }
        AppDelegate.shared.main.showToast(text)
    }

    // MARK: Downloading

    private func download(_ m: UpdateManifest) {
        state = .downloading(m, 0)
        let zip = zipURL(for: m)
        try? FileManager.default.removeItem(at: zip)
        tlog("downloading \(m.url.absoluteString)")
        if m.url.isFileURL {
            do { try FileManager.default.copyItem(at: m.url, to: zip) } catch { fail("Couldn't copy the update: \(error.localizedDescription)"); return }
            finishDownload(m, zip)
            return
        }
        downloadingManifest = m
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: URLRequest(url: m.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let m = downloadingManifest else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(m.size ?? 0)
        let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
        DispatchQueue.main.async { self.state = .downloading(m, fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let m = downloadingManifest else { return }
        let zip = zipURL(for: m)
        // The temporary file is gone once this returns, so move it now, then verify on the main thread.
        let moved = (try? FileManager.default.moveItem(at: location, to: zip)) != nil
        let http = downloadTask.response as? HTTPURLResponse
        DispatchQueue.main.async {
            if let http, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: zip)
                self.fail("The download failed (\(http.statusCode))")
            } else if !moved {
                self.fail("Couldn't save the download")
            } else {
                self.finishDownload(m, zip)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        guard let error else { return }
        DispatchQueue.main.async { self.fail("The download failed: \(error.localizedDescription)") }
    }

    private func finishDownload(_ m: UpdateManifest, _ zip: URL) {
        downloadingManifest = nil
        do {
            try UpdateSigning.verify(file: zip, signature: m.signature, sha256: m.sha256, size: m.size)
        } catch {
            try? FileManager.default.removeItem(at: zip)
            fail("\(error). The update was not installed.")
            return
        }
        becameReady(m, zip)
    }

    private func becameReady(_ m: UpdateManifest, _ zip: URL) {
        tlog("ready version=\(m.version) build=\(m.build) zip=\(zip.path)")
        state = .ready(m, zip)
        if manual { offerRelaunch(m) } else { toast("Sorrel \(m.version) is ready · Sorrel ▸ Relaunch to Update") }
    }

    private func offerRelaunch(_ m: UpdateManifest) {
        guard !isQuietTest else { return }
        if isTranslocated { explainTranslocation(); return }
        let a = NSAlert()
        a.messageText = "Sorrel \(m.version) is ready"
        a.informativeText = (m.notes.map { $0 + "\n\n" } ?? "") + "Relaunch now to update, or let it install the next time you quit Sorrel."
        a.addButton(withTitle: "Relaunch Now")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { relaunchToUpdate() }
    }

    private func explainTranslocation() {
        let a = NSAlert()
        a.messageText = "Move Sorrel to your Applications folder first"
        a.informativeText = "macOS runs an app straight from Downloads at a temporary address, where it can't be updated. Quit Sorrel, drag it into Applications, open it from there and the update will install."
        a.runModal()
    }

    // MARK: Installing

    /// Text for Settings ▸ General.
    var statusText: String {
        switch state {
        case .idle:
            if let date = (try? FileManager.default.attributesOfItem(atPath: stamp.path))?[.modificationDate] as? Date {
                let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
                return "Last checked \(f.localizedString(for: date, relativeTo: Date()))."
            }
            return "Not checked yet."
        case .checking: return "Checking…"
        case .upToDate: return "Sorrel is up to date."
        case .downloading(let m, let fraction): return "Downloading Sorrel \(m.version)… \(Int(fraction * 100))%"
        case .ready(let m, _): return "Sorrel \(m.version) is ready. It installs when you quit Sorrel."
        case .failed(let message): return message
        }
    }

    /// Title for the Sorrel menu item.
    var menuTitle: String {
        if let m = readyManifest { return "Relaunch to Update to \(m.version)…" }
        return "Check for Updates…"
    }

    /// Sorrel ▸ Check for Updates… / Relaunch to Update…
    func checkOrRelaunch() {
        if readyManifest != nil { relaunchToUpdate() } else { check(manual: true) }
    }

    func relaunchToUpdate() {
        if isTranslocated { explainTranslocation(); return }
        install(relaunch: true) { error in
            if let error {
                self.fail(error)
                if !isQuietTest {
                    let a = NSAlert(); a.messageText = "Sorrel couldn't update"; a.informativeText = error; a.runModal()
                }
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    /// From applicationShouldTerminate: true when an update is being handed to the installer, in which case
    /// `then` runs (on the main thread) once that is done and the app may finish quitting.
    func installOnQuit(then: @escaping () -> Void) -> Bool {
        guard allowInstallOnQuit, !installing, !isTranslocated, readyManifest != nil else { return false }
        install(relaunch: false) { error in
            if let error { self.tlog("install on quit refused: \(error)") }
            then()
        }
        return true
    }

    /// Hands the verified archive to SorrelUpdater.xpc. The completion runs on the main thread.
    private func install(relaunch: Bool, logOverride: String? = nil, completion: @escaping (String?) -> Void) {
        guard case .ready(let m, let zip) = state else { completion("No update is ready"); return }
        guard let id = Bundle.main.bundleIdentifier else { completion("Sorrel has no bundle id"); return }
        installing = true
        let connection = NSXPCConnection(serviceName: id + UpdaterService.suffix)
        connection.remoteObjectInterface = NSXPCInterface(with: SorrelUpdaterXPC.self)
        connection.resume()
        var done = false
        // Through the run loop, not the main dispatch queue: while the app is in "terminate later" (install on
        // quit) AppKit runs a nested run loop, and a main-queue block scheduled from inside one can't run there.
        let finish: (String?) -> Void = { error in
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                guard !done else { return }
                done = true
                connection.invalidate()
                if error != nil { self.installing = false }
                self.tlog("install handoff \(error ?? "ok")")
                completion(error)
            }
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish("Couldn't reach the updater: \(error.localizedDescription)")
        }) as? SorrelUpdaterXPC else { finish("The updater is unavailable"); return }
        try? "\(m.build)\n".write(to: marker, atomically: true, encoding: .utf8)
        proxy.install(zip: zip.path, signature: m.signature, pid: getpid(), relaunch: relaunch, log: logOverride ?? logFile.path) { error in
            if error != nil { try? FileManager.default.removeItem(at: self.marker) }
            finish(error)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish("The updater didn't answer") }
    }

    // MARK: Tests (SORREL_UPDATETEST=version|check|install|quit, with SORREL_UPDATE_FEED; tools/update-test.sh)

    func runTest(_ mode: String) {
        func log(_ s: String) { FileHandle.standardError.write("updater: \(s)\n".data(using: .utf8)!) }
        log("running version=\(current?.version ?? "?") build=\(current?.build ?? 0) app=\(Bundle.main.bundleURL.path) translocated=\(isTranslocated)")
        if mode == "version" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }; return }
        // The update.log inside this app's own container: where the real app's log lives (tests otherwise log under
        // /private/tmp), so swapzip uses it to show the service accepts that location.
        let containerLog = Sandbox.realHome.appendingPathComponent(
            "Library/Containers/\(Bundle.main.bundleIdentifier ?? "")/Data/Library/Application Support/\(Paths.profileName)/Updates/update.log")
        if mode == "containerlog" {
            let text = (try? String(contentsOf: containerLog, encoding: .utf8)) ?? "(no log at \(containerLog.path))"
            for line in text.split(separator: "\n") { log("containerlog: \(line)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return
        }
        allowInstallOnQuit = mode == "quit"
        var finished = false
        NotificationCenter.default.addObserver(forName: .sorrelUpdateState, object: nil, queue: .main) { [weak self] _ in
            guard let self, !finished else { return }
            switch self.state {
            case .upToDate, .failed:
                finished = true
                log("state: \(self.statusText)")
                NSApp.terminate(nil)
            case .ready(let m, _):
                finished = true
                log("state: ready \(m.version) build=\(m.build)")
                switch mode {
                case "install":
                    self.install(relaunch: false) { error in
                        log("install: \(error ?? "handed to the updater")")
                        NSApp.terminate(nil)
                    }
                case "swapzip":
                    // The service must install the bytes it checked, not whatever the zip holds by the time it unpacks.
                    try? FileManager.default.createDirectory(at: containerLog.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: containerLog)
                    self.install(relaunch: false, logOverride: containerLog.path) { error in
                        log("install: \(error ?? "handed to the updater")")
                        if case .ready(_, let zip) = self.state {
                            let junk = (try? Data(contentsOf: zip)).map { Data($0.reversed()) } ?? Data("junk".utf8)
                            log("swapzip: replaced the zip after handoff: \((try? junk.write(to: zip)) != nil)")
                            // The service's own copy must be out of the sandbox's reach.
                            let fm = FileManager.default
                            let priv = Sandbox.realHome.appendingPathComponent("Library/Caches/\(Bundle.main.bundleIdentifier ?? "")\(UpdaterService.suffix)")
                            let copies = ((try? fm.contentsOfDirectory(at: priv, includingPropertiesForKeys: nil)) ?? [])
                                .map { $0.appendingPathComponent("Sorrel.zip") }
                            let tampered = copies.contains { (try? junk.write(to: $0)) != nil }
                            log("swapzip: private copies visible=\(copies.count) tampered=\(tampered)")
                        }
                        NSApp.terminate(nil)
                    }
                case "badlog":
                    // The service writes only to the app's own update.log: every one of these must be refused.
                    let scratch = "/private/tmp/sorrel-badlog-\(getpid())"
                    try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
                    try? "victim\n".write(toFile: scratch + "/victim.txt", atomically: true, encoding: .utf8)
                    try? FileManager.default.createDirectory(atPath: scratch + "/sym", withIntermediateDirectories: true)
                    try? FileManager.default.createSymbolicLink(atPath: scratch + "/sym/update.log", withDestinationPath: scratch + "/victim.txt")
                    try? FileManager.default.createSymbolicLink(atPath: scratch + "/outside", withDestinationPath: Sandbox.realHome.appendingPathComponent("Library/Caches").path)
                    let cases = [("wrong name", scratch + "/victim.txt"),
                                 ("symlinked file", scratch + "/sym/update.log"),
                                 ("symlinked folder", scratch + "/outside/update.log"),
                                 ("outside the allowed folders", Sandbox.realHome.appendingPathComponent("update.log").path)]
                    func next(_ i: Int) {
                        guard i < cases.count else {
                            let victim = (try? String(contentsOfFile: scratch + "/victim.txt", encoding: .utf8)) ?? "?"
                            log("badlog: victim file untouched=\(victim == "victim\n") createdOutside=\(["Library/Caches/update.log", "update.log"].contains { FileManager.default.fileExists(atPath: Sandbox.realHome.appendingPathComponent($0).path) })")
                            NSApp.terminate(nil)
                            return
                        }
                        self.install(relaunch: false, logOverride: cases[i].1) { error in
                            log("badlog: \(cases[i].0): \(error.map { "refused (\($0))" } ?? "ACCEPTED")")
                            next(i + 1)
                        }
                    }
                    next(0)
                default:
                    NSApp.terminate(nil)   // "check" quits without installing; "quit" installs on the way out
                }
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.check(manual: false) }
    }
}
