import AppKit

// Memory: Drift runs with macOS's space-efficient allocator mode.
// Loading an extension's blocking rules allocates heavily for a moment and then frees it; in the default
// mode the freed pages stay charged to the app (about 235 MB with uBlock Origin Lite), in this mode they
// are returned (about 40 MB). The setting has to be in place before the process starts, so Info.plist
// carries it for normal launches, and a launch without it (from a terminal, say) restarts itself once with it.
if getenv("MallocSpaceEfficient") == nil, getenv("DRIFT_DEFAULT_ALLOCATOR") == nil {
    setenv("MallocSpaceEfficient", "1", 1)
    let args = CommandLine.arguments
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    argv.append(nil)
    if let path = Bundle.main.executablePath {
        execv(path, &argv)
    }
    // If the restart failed, carry on as we are.
}

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(isQuietTest ? .accessory : .regular)
app.run()
