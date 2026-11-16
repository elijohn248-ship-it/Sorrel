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
//   - it writes its log only to the app's own Updates/update.log (inside the app's container, or under
//     /private/tmp for the test build), never through a symlink or hard link, with control characters removed.
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

/// Opens the log the app asked for, only if it is the app's own update.log: inside the app's container (or, for
/// the test build, under /private/tmp), a plain file with one link, reached without symlinks. Returns an fd.
func openLog(_ path: String) -> Int32? {
    guard let appID else { return nil }
    var roots = [realHome.appendingPathComponent("Library/Containers/\(appID)/Data").path]
    if isTestService { roots.append("/private/tmp") }
    let allowed = roots.compactMap(resolved)
    func inside(_ p: String) -> Bool { allowed.contains { p.hasPrefix($0 + "/") } }

    let url = URL(fileURLWithPath: path)
    guard url.lastPathComponent == "update.log", let dir = resolved(url.deletingLastPathComponent().path), inside(dir + "/")
    else { return nil }
    let fd = open(dir + "/update.log", O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
    guard fd >= 0 else { return nil }
    // Check what was actually opened, in case a folder on the way was swapped for a symlink after the check above.
    var st = stat()
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_uid == getuid(),
          fcntl(fd, F_GETPATH, &buf) != -1 else { close(fd); return nil }
    let opened = String(cString: buf)
    guard inside(opened), opened.hasSuffix("/update.log") else { close(fd); return nil }
    return fd
}

/// The app this service may replace, as it is now.
func installedApp() throws -> BundleInfo {
    guard let appID else { throw Refused(why: "The updater service has an unexpected bundle id (\(serviceID))") }
    guard let info = BundleInfo(appURL: appURL) else { throw Refused(why: "\(appURL.path) is not an app bundle") }
    guard info.identifier == appID else { throw Refused(why: "\(appURL.path) is \(info.identifier), not \(appID)") }
    return info
}

/// Reads the archive once, checks those bytes, and writes them to a fresh private folder. Returns the copy.
func stagePrivateCopy(of zip: String, signature: String) throws -> URL {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: zip)) else { throw Refused(why: "The downloaded update is missing") }
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

func install(zip: String, signature: String, pid: Int32, relaunch: Bool, log: Log) -> Int32 {
    let fm = FileManager.default
    let app = appURL.path
    log.line("installer: start zip=\(zip) app=\(app) pid=\(pid) relaunch=\(relaunch)")
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

    if relaunch {
        let (ocode, oout) = run("/usr/bin/open", [app])
        log.line("installer: relaunch \(ocode == 0 ? "ok" : "failed: \(oout)")")
    }
    return 0
}

// MARK: - XPC service

final class Service: NSObject, SorrelUpdaterXPC {
    func install(zip: String, signature: String, pid: Int32, relaunch: Bool, log logPath: String,
                 reply: @escaping (String?) -> Void) {
        guard let logFD = openLog(logPath) else {
            reply("The updater only writes to Sorrel's own update.log, not \(clean(logPath))")
            return
        }
        defer { close(logFD) }
        let log = Log(handle: FileHandle(fileDescriptor: logFD, closeOnDealloc: false), echo: true)
        let copy: URL
        do {
            _ = try installedApp()
            copy = try stagePrivateCopy(of: zip, signature: signature)
        }
        catch let r as Refused { log.line("service: refused: \(r.why)"); reply(clean(r.why)); return }
        catch { log.line("service: refused: \(error)"); reply(clean("\(error)")); return }

        // Start the installer in its own session with its output on the log, so it outlives this service.
        guard let exe = Bundle.main.executablePath else { reply("The updater's executable path is unknown"); return }
        let args = [exe, "--install", copy.path, signature, String(pid), relaunch ? "1" : "0"]
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
    exit(install(zip: argv[2], signature: argv[3], pid: Int32(argv[4]) ?? 0, relaunch: argv[5] == "1", log: log))
}
let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()   // never returns
