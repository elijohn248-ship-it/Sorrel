// SorrelUpdater: the unsandboxed XPC service that installs an update, bundled at
// Sorrel.app/Contents/XPCServices/SorrelUpdater.xpc. Two roles share this executable:
//
//   no arguments          the XPC service launchd starts for Sorrel. It checks the request (bundle ids match,
//                         signature valid), keeps a private copy of the archive, and spawns the installer below in
//                         its own session, so it survives Sorrel quitting (launchd ends the service with the app).
//   --install …           the detached installer: waits for Sorrel to exit, unpacks the private copy next to the
//                         app, checks it again, strips quarantine, swaps the bundles, relaunches if asked.
//
// This process is outside the sandbox, so it treats everything the app sends as hostile (CLAUDE.md, Sandbox: a
// compromised main process must stay contained). In particular:
//   - it never installs over a path the app names: the app is the bundle that contains this service;
//   - it never re-reads a file the app can write after checking it: it checks bytes in memory and unpacks a copy
//     kept where the sandbox can't reach (~/Library/Caches/<service id>);
//   - it takes no paths at all from the app: the archive and the log arrive as files the app opened itself (so
//     the service can only write where the sandboxed app could), the log must be a plain file with one link,
//     and control characters are removed from what is written to it.
import Foundation
import SorrelUpdateCore

func now() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
}

/// Replaces control characters (newlines included), so nothing the app passes can start a log line of its own.
func clean(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars { out.append(CharacterSet.controlCharacters.contains(u) ? "?" : u) }
    return String(out)
}

struct Log {
    let handle: FileHandle?
    let echo: Bool   // also to stderr (the installer's stderr already is the log file)
    func line(_ s: String) {
        let text = "\(now()) \(clean(s))\n"
        handle?.write(text.data(using: .utf8)!)
        if echo { FileHandle.standardError.write(text.data(using: .utf8)!) }
    }
}

/// The app bundle id this service may touch: its own id minus ".updater".
let serviceID = Bundle.main.bundleIdentifier ?? ""
let appID: String? = serviceID.hasSuffix(UpdaterService.suffix) ? String(serviceID.dropLast(UpdaterService.suffix.count)) : nil
let isTestService = appID?.hasSuffix(".test") == true
/// The app this service belongs to: <app>/Contents/XPCServices/SorrelUpdater.xpc, three levels up.
let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
/// The person's real home. Not `homeDirectoryForCurrentUser`: launchd starts this service with the app's
/// environment, so Foundation's home is the app's container (found by tools/update-test.sh), where the sandboxed
/// app can write. No fallback: without the real home every request is refused.
let realHome: URL = {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return URL(fileURLWithPath: "/nonexistent") }
    return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
}()
/// Where archives wait for the installer. Outside the app's container, so the sandboxed app can't change them.
let privateFolder = realHome.appendingPathComponent("Library/Caches/\(serviceID)", isDirectory: true)

struct Refused: Error { let why: String }

func resolved(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

/// The log the app opened (its Updates/update.log): only a plain file of this user's with a single link, so
/// the service never writes into a pipe, device or a second name for some other file. Returns its descriptor.
func checkedLog(_ handle: FileHandle) -> Int32? {
    let fd = handle.fileDescriptor
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_uid == getuid() else { return nil }
    return fd
}

/// Where an open file is, or "" (used only to tell a test run's log under /private/tmp).
func path(of fd: Int32) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return fcntl(fd, F_GETPATH, &buf) != -1 ? String(cString: buf) : ""
}

/// The app this service may replace, as it is now.
func installedApp() throws -> BundleInfo {
    guard let appID else { throw Refused(why: "The updater service has an unexpected bundle id (\(serviceID))") }
    guard let info = BundleInfo(appURL: appURL) else { throw Refused(why: "\(appURL.path) is not an app bundle") }
    guard info.identifier == appID else { throw Refused(why: "\(appURL.path) is \(info.identifier), not \(appID)") }
    return info
}

/// Reads the archive once, checks those bytes, and writes them to a fresh private folder. Returns the copy.
func stagePrivateCopy(of zip: FileHandle, signature: String) throws -> URL {
    var st = stat()
    guard fstat(zip.fileDescriptor, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
          (try? zip.seek(toOffset: 0)) != nil, let data = try? zip.readToEnd(), !data.isEmpty
    else { throw Refused(why: "The downloaded update couldn’t be read") }
    do { try UpdateSigning.verify(data: data, signature: signature) } catch { throw Refused(why: "\(error)") }
    let fm = FileManager.default
    try? fm.createDirectory(at: privateFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var template = Array(privateFolder.appendingPathComponent("update-XXXXXX").path.utf8CString)
    guard let made = mkdtemp(&template) else { throw Refused(why: "Couldn't make a private folder for the update") }
    let copy = URL(fileURLWithPath: String(cString: made)).appendingPathComponent("Sorrel.zip")
    guard fm.createFile(atPath: copy.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        try? fm.removeItem(at: copy.deletingLastPathComponent())
        throw Refused(why: "Couldn't keep a private copy of the update")
    }
    return copy
}

/// True for a private copy made by `stagePrivateCopy` (the installer accepts nothing else).
func isPrivateCopy(_ path: String) -> Bool {
    guard let folder = resolved(privateFolder.path), let file = resolved(path) else { return false }
    let parent = (file as NSString).deletingLastPathComponent
    return (parent as NSString).deletingLastPathComponent == folder && (file as NSString).lastPathComponent == "Sorrel.zip"
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Removes com.apple.quarantine from everything under `root`. Files unpacked from a quarantined archive
/// inherit the flag, and Gatekeeper would refuse an ad-hoc signed app that carries it.
func stripQuarantine(_ root: URL) {
    let fm = FileManager.default
    removexattr(root.path, "com.apple.quarantine", XATTR_NOFOLLOW)
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return }
    for case let u as URL in e { removexattr(u.path, "com.apple.quarantine", XATTR_NOFOLLOW) }
}

// MARK: - Installer (detached)

/// Test runs log the reopen instead of opening a window that would take focus with no scratch profile. The
/// service decides (a test build logging under /private/tmp, i.e. a SORREL_HOME run) and tells the installer
/// with relaunch "2"; only the test build's service honours it. The environment can't be used: launchd doesn't
/// pass the app's variables to the service (found 2026-11-16).
var dryReopen = false

func reopenApp(_ log: Log, _ why: String) {
    if dryReopen { log.line("installer: reopen skipped in a test (\(why))"); return }
    let (ocode, oout) = run("/usr/bin/open", [appURL.path])
    log.line("installer: reopen after \(why) \(ocode == 0 ? "ok" : "failed: \(oout)")")
}

/// Installs, and when Sorrel asked to be relaunched, reopens it whatever happened: a failed install must never
/// leave the person without their browser (it reopens on the old version, which reads update.log and says why).
func install(zip: String, signature: String, pid: Int32, relaunch: Bool, log: Log) -> Int32 {
    let code = installSteps(zip: zip, signature: signature, pid: pid, log: log)
    guard relaunch else { return code }
    if code == 0 { reopenApp(log, "update"); return 0 }
    // Code 3 means Sorrel never quit: nothing to reopen. Otherwise wait for it to be gone (a refusal can come
    // before it has quit), then open the old copy.
    var waited = 0.0
    while kill(pid, 0) == 0 && waited < 90 { usleep(250_000); waited += 0.25 }
    if kill(pid, 0) != 0 { reopenApp(log, "failed update") }
    return code
}

func installSteps(zip: String, signature: String, pid: Int32, log: Log) -> Int32 {
    let fm = FileManager.default
    let app = appURL.path
    log.line("installer: start zip=\(zip) app=\(app) pid=\(pid)")
    defer { if isPrivateCopy(zip) { try? fm.removeItem(at: URL(fileURLWithPath: zip).deletingLastPathComponent()) } }
    let current: BundleInfo
    do {
        current = try installedApp()
        guard isPrivateCopy(zip) else { throw Refused(why: "\(zip) is not the service's private copy") }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: zip)) else { throw Refused(why: "The private copy is missing") }
        do { try UpdateSigning.verify(data: data, signature: signature) } catch { throw Refused(why: "\(error)") }
    }
    catch let r as Refused { log.line("installer: refused: \(r.why)"); return 2 }
    catch { log.line("installer: refused: \(error)"); return 2 }

    // 1. Wait for Sorrel to be gone. kill(pid, 0) fails with ESRCH once it has exited.
    var waited = 0.0
    while kill(pid, 0) == 0 && waited < 90 { usleep(250_000); waited += 0.25 }
    if kill(pid, 0) == 0 { log.line("installer: Sorrel (pid \(pid)) is still running after 90 s; giving up"); return 3 }
    log.line("installer: Sorrel quit after \(waited) s")

    // 2. Unpack beside the app (same volume, so the swap is two renames). If the app's folder isn't writable
    //    (e.g. /Applications for a non-admin account), work inside the bundle and swap Contents instead.
    let parent = appURL.deletingLastPathComponent()
    let parentWritable = access(parent.path, W_OK) == 0
    let token = String(UUID().uuidString.prefix(8))
    let stage = (parentWritable ? parent : appURL).appendingPathComponent(".sorrel-update-\(token)", isDirectory: true)
    defer { try? fm.removeItem(at: stage) }
    do { try fm.createDirectory(at: stage, withIntermediateDirectories: true) }
    catch { log.line("installer: can't create \(stage.path): \(error)"); return 4 }
    let (code, out) = run("/usr/bin/ditto", ["-x", "-k", zip, stage.path])
    guard code == 0 else { log.line("installer: ditto failed (\(code)): \(out)"); return 4 }
    guard let newApp = (try? fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
          let next = BundleInfo(appURL: newApp) else { log.line("installer: no app bundle in the archive"); return 4 }

    // 3. The unpacked app must be the same app, newer, and intact.
    guard next.identifier == current.identifier else { log.line("installer: archive is \(next.identifier), not \(current.identifier)"); return 5 }
    guard next.build > current.build else { log.line("installer: archive build \(next.build) is not newer than \(current.build)"); return 5 }
    let (vcode, vout) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
    guard vcode == 0 else { log.line("installer: codesign --verify failed (\(vcode)): \(vout)"); return 5 }
    stripQuarantine(newApp)

    // 4. Swap.
    do {
        if parentWritable {
            let old = parent.appendingPathComponent(".sorrel-old-\(token)", isDirectory: true)
            try fm.moveItem(at: appURL, to: old)
            do { try fm.moveItem(at: newApp, to: appURL) }
            catch { try? fm.moveItem(at: old, to: appURL); throw error }
            try? fm.removeItem(at: old)
        } else {
            let contents = appURL.appendingPathComponent("Contents")
            let old = appURL.appendingPathComponent("Contents.old-\(token)")
            try fm.moveItem(at: contents, to: old)
            do { try fm.moveItem(at: newApp.appendingPathComponent("Contents"), to: contents) }
            catch { try? fm.moveItem(at: old, to: contents); throw error }
            try? fm.removeItem(at: old)
        }
    } catch {
        log.line("installer: swap failed: \(error)")
        return 6
    }
    stripQuarantine(appURL)
    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: app)   // so Launch Services notices
    log.line("installer: installed \(next.version) (build \(next.build)) over \(current.version) (build \(current.build)) at \(app)")
    return 0
}

// MARK: - Moving a downloaded copy into Applications

/// macOS runs a quarantined app opened from Downloads at a random read-only mount under AppTranslocation.
/// Only Launch Services can make such a mount (SecTranslocateCreateSecureDirectoryForURL is refused to other
/// processes), so the test build's service also accepts a copy under /private/tmp as a stand-in.
let isTranslocated = appURL.path.contains("/AppTranslocation/")
    || (isTestService && appURL.path.hasPrefix("/private/tmp/"))

/// Where a translocated bundle really is (e.g. ~/Downloads/Sorrel.app), from Security.framework's
/// SecTranslocateCreateOriginalPathForURL (exported, not in the public headers, hence dlsym).
func originalLocation(of url: URL) -> URL? {
    guard let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
          let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return nil }
    typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
    let original = unsafeBitCast(sym, to: Original.self)
    guard let made = original(url as CFURL, nil)?.takeRetainedValue() as URL? else { return nil }
    return made.standardizedFileURL.path == url.standardizedFileURL.path ? nil : made
}

/// /Applications when this account may write there (admins), otherwise ~/Applications.
func applicationsFolder() -> URL {
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
    if access(system.path, W_OK) == 0 { return system }
    let mine = realHome.appendingPathComponent("Applications", isDirectory: true)
    try? FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    return mine
}

/// The detached half of a move: waits for Sorrel to quit, puts the staged copy at `dest`, trashes `original`,
/// and opens `dest`. If the copy can't be put in place it opens `original` again, so the person still has Sorrel.
func finishMove(staged: String, dest: String, original: String, pid: Int32, log: Log) -> Int32 {
    let fm = FileManager.default
    let stagedURL = URL(fileURLWithPath: staged), destURL = URL(fileURLWithPath: dest)
    let stage = stagedURL.deletingLastPathComponent()
    defer { try? fm.removeItem(at: stage) }
    log.line("mover: start staged=\(staged) dest=\(dest) original=\(original) pid=\(pid)")
    // The service made these; check they still look that way (the staging folder sits beside the destination).
    guard stage.lastPathComponent.hasPrefix(".sorrel-move-"),
          stage.deletingLastPathComponent().path == destURL.deletingLastPathComponent().path,
          let appID, BundleInfo(appURL: stagedURL)?.identifier == appID else {
        log.line("mover: refused: unexpected staged copy"); return 2
    }
    func reopen(_ path: String, _ why: String) {
        if dryReopen { log.line("mover: open skipped in a test (\(why))"); return }
        let (code, out) = run("/usr/bin/open", [path])
        log.line("mover: open after \(why) \(code == 0 ? "ok" : "failed: \(out)")")
    }
    var waited = 0.0
    while kill(pid, 0) == 0 && waited < 90 { usleep(250_000); waited += 0.25 }
    if kill(pid, 0) == 0 { log.line("mover: Sorrel (pid \(pid)) is still running after 90 s; giving up"); return 3 }
    log.line("mover: Sorrel quit after \(waited) s")

    let token = String(UUID().uuidString.prefix(8))
    let old = destURL.deletingLastPathComponent().appendingPathComponent(".sorrel-old-\(token)", isDirectory: true)
    do {
        if fm.fileExists(atPath: dest) {
            try fm.moveItem(at: destURL, to: old)
            do { try fm.moveItem(at: stagedURL, to: destURL) }
            catch { try? fm.moveItem(at: old, to: destURL); throw error }
            try? fm.removeItem(at: old)
        } else {
            try fm.moveItem(at: stagedURL, to: destURL)
        }
    } catch {
        log.line("mover: couldn't put Sorrel in place: \(error)")
        if !original.isEmpty { reopen(original, "failed move") }
        return 6
    }
    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest)   // so Launch Services notices
    log.line("mover: Sorrel is now at \(dest)")
    // The copy that was opened (usually in Downloads) goes to the Trash, so only the one in Applications is left.
    if !original.isEmpty, original != dest, let info = BundleInfo(appURL: URL(fileURLWithPath: original)), info.identifier == appID {
        do {
            var trashed: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: &trashed)
            log.line("mover: moved \(original) to the Trash\(trashed?.path.map { " (\($0))" } ?? "")")
        } catch { log.line("mover: left \(original) where it is: \(error)") }
    }
    reopen(dest, "move")
    return 0
}

// MARK: - XPC service

final class Service: NSObject, SorrelUpdaterXPC {
    func install(zip: FileHandle, signature: String, pid: Int32, relaunch: Bool, log logHandle: FileHandle,
                 reply: @escaping (String?) -> Void) {
        guard let logFD = checkedLog(logHandle) else {
            reply("The updater only writes to a plain log file")
            return
        }
        let log = Log(handle: logHandle, echo: true)
        let copy: URL
        do {
            _ = try installedApp()
            copy = try stagePrivateCopy(of: zip, signature: signature)
        }
        catch let r as Refused { log.line("service: refused: \(r.why)"); reply(clean(r.why)); return }
        catch { log.line("service: refused: \(error)"); reply(clean("\(error)")); return }

        // Start the installer in its own session with its output on the log, so it outlives this service.
        guard let exe = Bundle.main.executablePath else { reply("The updater's executable path is unknown"); return }
        let testRun = isTestService && path(of: logFD).hasPrefix("/private/tmp/")
        let args = [exe, "--install", copy.path, signature, String(pid), relaunch ? (testRun ? "2" : "1") : "0"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe, &actions, &attr, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        if rc != 0 {
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            log.line("service: couldn't start the installer (\(rc))")
            reply("Couldn't start the installer (error \(rc))")
            return
        }
        log.line("service: installer started as pid \(child)")
        reply(nil)
    }

    func moveToApplications(pid: Int32, log logHandle: FileHandle, reply: @escaping (String?) -> Void) {
        guard let logFD = checkedLog(logHandle) else { reply("The updater only writes to a plain log file"); return }
        let log = Log(handle: logHandle, echo: true)
        func refuse(_ why: String) { log.line("service: move refused: \(why)"); reply(clean(why)) }
        let fm = FileManager.default
        let current: BundleInfo
        do { current = try installedApp() } catch let r as Refused { refuse(r.why); return } catch { refuse("\(error)"); return }
        // Only a translocated copy: macOS keeps it read-only, so what is copied is what Gatekeeper checked and the
        // person approved, never something the sandboxed app could have written (it may write to ~/Downloads).
        guard isTranslocated else { refuse("Birch isn't running from a download, so there is nothing to move"); return }
        let original = originalLocation(of: appURL) ?? (isTestService && !appURL.path.contains("/AppTranslocation/") ? appURL : nil)
        let folder = applicationsFolder()
        // The app was Sorrel until 0.3.1; a copy is now called Birch.app (code names, the bundle id and the test app kept Sorrel).
        let dest = folder.appendingPathComponent(isTestService ? "SorrelTest.app" : "Birch.app", isDirectory: true)
        if let there = BundleInfo(appURL: dest) {
            guard there.identifier == current.identifier else { refuse("\(dest.path) is a different app"); return }
            guard there.build <= current.build else {
                refuse("Applications already has a newer Birch (\(there.version)). Open that one instead."); return
            }
        }

        // Copy now, while the translocated mount surely exists; the helper only renames it into place.
        var template = Array(folder.appendingPathComponent(".sorrel-move-XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { refuse("Couldn't write to \(folder.path)"); return }
        let stage = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        let staged = stage.appendingPathComponent(dest.lastPathComponent, isDirectory: true)
        let (code, out) = run("/usr/bin/ditto", [appURL.path, staged.path])
        guard code == 0 else { try? fm.removeItem(at: stage); refuse("Copying Birch failed: \(out)"); return }
        let (vcode, vout) = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        guard vcode == 0, BundleInfo(appURL: staged)?.identifier == current.identifier else {
            try? fm.removeItem(at: stage); refuse("The copy of Birch didn't check out: \(vout)"); return
        }
        // Without this the copy would be translocated again on every launch (and still couldn't update).
        stripQuarantine(staged)

        guard let exe = Bundle.main.executablePath else { try? fm.removeItem(at: stage); refuse("The updater's executable path is unknown"); return }
        let testRun = isTestService && path(of: logFD).hasPrefix("/private/tmp/")
        let args = [exe, "--move", staged.path, dest.path, original?.path ?? "", String(pid), testRun ? "2" : "1"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, logFD, 1)
        posix_spawn_file_actions_adddup2(&actions, logFD, 2)
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe, &actions, &attr, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        if rc != 0 { try? fm.removeItem(at: stage); refuse("Couldn't start the mover (error \(rc))"); return }
        log.line("service: copied \(appURL.path) to \(staged.path); mover started as pid \(child) for \(dest.path) (original \(original?.path ?? "unknown"))")
        reply(nil)
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: SorrelUpdaterXPC.self)
        c.exportedObject = Service()
        c.resume()
        return true
    }
}

let argv = CommandLine.arguments
if argv.count == 6, argv[1] == "--install" {
    let log = Log(handle: FileHandle.standardError, echo: false)
    dryReopen = isTestService && argv[5] == "2"
    exit(install(zip: argv[2], signature: argv[3], pid: Int32(argv[4]) ?? 0, relaunch: argv[5] != "0", log: log))
}
if argv.count == 7, argv[1] == "--move" {
    let log = Log(handle: FileHandle.standardError, echo: false)
    dryReopen = isTestService && argv[6] == "2"
    exit(finishMove(staged: argv[2], dest: argv[3], original: argv[4], pid: Int32(argv[5]) ?? 0, log: log))
}
let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()   // never returns
