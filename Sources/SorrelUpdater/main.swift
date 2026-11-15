// SorrelUpdater: the unsandboxed XPC service that installs an update, bundled at
// Sorrel.app/Contents/XPCServices/SorrelUpdater.xpc. Two roles share this executable:
//
//   no arguments          the XPC service launchd starts for Sorrel. It checks the request (bundle ids match,
//                         signature valid) and spawns the installer below in its own session, so it survives
//                         Sorrel quitting (launchd ends the service itself along with the app).
//   --install …           the detached installer: waits for Sorrel to exit, unpacks the archive next to the
//                         app, checks it again, strips quarantine, swaps the bundles, relaunches if asked.
//
// Everything it does is logged to the path Sorrel passes (Updates/update.log in the profile folder).
import Foundation
import SorrelUpdateCore

func now() -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.string(from: Date())
}

struct Log {
    let handle: FileHandle?
    let echo: Bool   // also to stderr (the installer's stderr already is the log file)
    init(path: String, echo: Bool = true) {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        self.echo = echo
    }
    func line(_ s: String) {
        let text = "\(now()) \(s)\n"
        handle?.write(text.data(using: .utf8)!)
        if echo { FileHandle.standardError.write(text.data(using: .utf8)!) }
    }
}

/// The app bundle id this service may touch: its own id minus ".updater".
let serviceID = Bundle.main.bundleIdentifier ?? ""
let appID: String? = serviceID.hasSuffix(UpdaterService.suffix) ? String(serviceID.dropLast(UpdaterService.suffix.count)) : nil

struct Refused: Error { let why: String }

/// The checks both roles make before touching anything.
func precheck(zip: String, signature: String, app: String) throws -> BundleInfo {
    guard let appID else { throw Refused(why: "The updater service has an unexpected bundle id (\(serviceID))") }
    guard FileManager.default.isReadableFile(atPath: zip) else { throw Refused(why: "The downloaded update is missing") }
    guard let info = BundleInfo(appURL: URL(fileURLWithPath: app)) else { throw Refused(why: "\(app) is not an app bundle") }
    guard info.identifier == appID else { throw Refused(why: "\(app) is \(info.identifier), not \(appID)") }
    do { try UpdateSigning.verify(file: URL(fileURLWithPath: zip), signature: signature) }
    catch { throw Refused(why: "\(error)") }
    return info
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

func install(zip: String, signature: String, app: String, pid: Int32, relaunch: Bool, log: Log) -> Int32 {
    let fm = FileManager.default
    log.line("installer: start zip=\(zip) app=\(app) pid=\(pid) relaunch=\(relaunch)")
    let current: BundleInfo
    do { current = try precheck(zip: zip, signature: signature, app: app) }
    catch let r as Refused { log.line("installer: refused: \(r.why)"); return 2 }
    catch { log.line("installer: refused: \(error)"); return 2 }

    // 1. Wait for Sorrel to be gone. kill(pid, 0) fails with ESRCH once it has exited.
    var waited = 0.0
    while kill(pid, 0) == 0 && waited < 90 { usleep(250_000); waited += 0.25 }
    if kill(pid, 0) == 0 { log.line("installer: Sorrel (pid \(pid)) is still running after 90 s; giving up"); return 3 }
    log.line("installer: Sorrel quit after \(waited) s")

    // 2. Unpack beside the app (same volume, so the swap is two renames). If the app's folder isn't writable
    //    (e.g. /Applications for a non-admin account), work inside the bundle and swap Contents instead.
    let appURL = URL(fileURLWithPath: app)
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
    try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: appURL.path)   // so Launch Services notices
    try? fm.removeItem(atPath: zip)
    log.line("installer: installed \(next.version) (build \(next.build)) over \(current.version) (build \(current.build)) at \(app)")

    if relaunch {
        let (ocode, oout) = run("/usr/bin/open", [app])
        log.line("installer: relaunch \(ocode == 0 ? "ok" : "failed: \(oout)")")
    }
    return 0
}

// MARK: - XPC service

final class Service: NSObject, SorrelUpdaterXPC {
    func install(zip: String, signature: String, app: String, pid: Int32, relaunch: Bool, log logPath: String,
                 reply: @escaping (String?) -> Void) {
        let log = Log(path: logPath)
        do { _ = try precheck(zip: zip, signature: signature, app: app) }
        catch let r as Refused { log.line("service: refused: \(r.why)"); reply(r.why); return }
        catch { log.line("service: refused: \(error)"); reply("\(error)"); return }

        // Start the installer in its own session with its output on the log, so it outlives this service.
        guard let exe = Bundle.main.executablePath else { reply("The updater's executable path is unknown"); return }
        let args = [exe, "--install", zip, signature, app, String(pid), relaunch ? "1" : "0", logPath]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_addopen(&actions, 2, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        var child: pid_t = 0
        let rc = posix_spawn(&child, exe, &actions, &attr, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        if rc != 0 {
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
if argv.count == 8, argv[1] == "--install" {
    let log = Log(path: argv[7], echo: false)
    exit(install(zip: argv[2], signature: argv[3], app: argv[4], pid: Int32(argv[5]) ?? 0, relaunch: argv[6] == "1", log: log))
}
let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()   // never returns
