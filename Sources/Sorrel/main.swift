import AppKit

// Test hooks (every SORREL_* variable) belong to build/SorrelTest.app, which has its own container, preferences
// and site data. The real app drops them all before anything reads them, so nothing that can set a Mac app's
// environment (launchctl setenv, say) can steer it: swap in another "built-in" blocker, move downloads, or run the
// debug hooks against the owner's profile. SORREL_HOME still gets an explanation, since it means a test run
// started the wrong app (it would write into the owner's preferences, and couldn't reach its scratch folder).
if !isTestBuild {
    let hooks = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("SORREL_") }
    if hooks.contains("SORREL_HOME") {
        FileHandle.standardError.write("Sorrel: test runs (SORREL_HOME) use build/SorrelTest.app/Contents/MacOS/Sorrel, not Sorrel.app. See CLAUDE.md, Testing.\n".data(using: .utf8)!)
        exit(2)
    }
    hooks.forEach { unsetenv($0) }
}

// Memory: Sorrel runs with macOS's space-efficient allocator mode.
// Loading an extension's blocking rules allocates heavily for a moment and then frees it; in the default
// mode the freed pages stay charged to the app (about 235 MB with uBlock Origin Lite), in this mode they
// are returned (about 40 MB). The setting has to be in place before the process starts, so Info.plist
// carries it for normal launches, and a launch without it (from a terminal, say) restarts itself once with it.
if getenv("MallocSpaceEfficient") == nil, getenv("SORREL_DEFAULT_ALLOCATOR") == nil {
    setenv("MallocSpaceEfficient", "1", 1)
    let args = CommandLine.arguments
    var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
    argv.append(nil)
    if let path = Bundle.main.executablePath {
        execv(path, &argv)
    }
    // If the restart failed, carry on as we are.
}

// First sandboxed launch: copy the profile, cookies and site data into the container before anything opens them.
Migration.runIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.setActivationPolicy(isQuietTest ? .accessory : .regular)
app.run()
