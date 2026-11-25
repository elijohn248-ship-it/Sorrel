# Bugs

## Security audit, 2026-11-15 (branch `security-audit`)

All fixed on the branch and verified with SorrelTest.app (`tools/update-test.sh`, `SORREL_SECTEST2`, `SORREL_SECTEST`, an extension fixture, window snapshots).

- [x] Updater service could install a different archive than it verified. Cause: it re-read the zip from the app's container after checking it. Now: verified bytes kept in a private copy outside the sandbox's reach.
- [x] Updater service wrote its log to any path the app named. Cause: log and app paths came from the app. Now: app = the bundle containing the service; log only the app's own update.log.
- [x] Address box could show a lookalike host as another site. Cause: `www.` removed anywhere in the host. Now: only a leading `www.`; long hosts cut at the front.
- [x] Extension updates gained new required permissions silently. Cause: every load granted the current manifest. Now: recorded at switch-on; more is held back until approved.
- [x] Not-secure Continue usable after leaving the warning. Cause: offer never expired. Now: only while the warning is showing.
- [x] Hidden tabs could raise app-modal dialogs. Cause: `runModal` fallback. Now: answered Cancel; repeated dialogs can be silenced.
- [x] `SORREL_*` test hooks honoured by Sorrel.app. Now: dropped at launch unless SorrelTest.app.
- [x] `sorrel://` names could climb out of the app bundle. Now: plain names only.
- [x] Pages could save downloads without a click. Now: asks once per site.
- [x] Wildcard `externally_connectable` hosts got the Chrome bridge. Now: exact hosts only.
- [x] No sign of an unencrypted page in the address box. Now: orange open lock.
- [x] release.sh put the GitHub token on curl's command line. Now: passed as a header file.
- [x] A page that kept crashing reloaded forever. Now: error page after the third crash in a minute.

Not changed: Web Inspector stays available on every page (owner's tool; only reachable by someone at this Mac).
Still to check by hand (owner): a clicked download starts without a prompt; the extension update prompt's wording.

## Open

_None._

## Fixed

### Sidebar mini player shows tabs that have no audio playing (fixed 2026-11-24, branch `media-silent-tabs`)
- **Repro:** open a page holding an unplayed `<audio>`, a muted autoplay video or a video without sound (canvas stream). `SORREL_MEDIATEST=1` now opens such fixtures beside the real silent-WAV source.
- **Expected:** the card appears only for a tab that played audible media (then stays while it is paused or muted).
- **Actual:** every such tab became a source (`sources=4` instead of 1); the card followed them and pause/resume/background checks failed.
- **Cause / fix:** WebKit's `requestMediaPlaybackState` answers `.playing` for any page holding a media element that isn't paused, even one that never loaded (unplayed `<audio>`, background-tab video) or plays muted/without an audio track; the player took every `.playing` tab as a source. A tab now becomes a source only while WebKit's `_isPlayingAudio` (audible playback) is also true; pauses and mutes keep a real source as before. The same gate stops silent pages counting as "playing" for tab sleep.
- **Verified:** `SORREL_MEDIATEST=1 SORREL_MEDIASEEKTEST=1` (`SORREL_DELAY=32`): the three silent fixtures are still `.playing` to WebKit but never sources or sleep-protected (18 checks, in background and on screen), unmuting the muted video makes it the source, and all earlier media/seek checks pass; `SORREL_MEMORYTEST` 17/17. Real sites (YouTube previews, muted video ads) are the owner's to check.


### D2L Brightspace says "Safari version 18 is no longer supported" on a Mac with Safari 26+ (fixed 2026-11-23, branch `safari-ua`)
- **Repro:** Birch on another Mac (macOS 15, Safari 26 or newer per About Safari) opens a D2L Brightspace home page. Simulated here with `SORREL_FAKE_OS=15.7` (Safari unreadable): the user agent said `Version/18.7`.
- **Expected:** the same Safari version as that Mac's Safari (26+), no outdated-browser warning.
- **Actual:** "Your browser is looking a little retro… Apple Safari version 18 is no longer supported".
- **Cause / fix:** when Birch can't read Safari's version, it guessed from macOS (15.x = 18.x), but Safari and the system WebKit update separately from macOS 14/15. Birch now tries Safari's Info.plist at `/Applications/Safari.app`, the two cryptex paths and Launch Services' location, and never reports a version older than the loaded WebKit implies: the in-memory WebKit version (`NSVersionOfRunTimeLibrary`, no file read) is branch 622+ for every Safari 26+ engine, so the floor is 26.0. Why the read failed on that Mac isn't known (it works under the sandbox here, macOS 27).
- **Verified:** `SORREL_UATEST=1`: real Mac `Version/27.2` read from `/Applications/Safari.app`; `SORREL_FAKE_OS=15.7` now `Version/26.0` (was 18.7); with `SORREL_FAKE_WEBKIT=621.3.11` (a real Safari 18 engine) still `18.7`; floor-rule checks all pass. Release build has the same two source warnings. Not verified on the other Mac or on D2L itself (needs a sign-in).

### Screen Time attributes Birch to VS Code (reported 2026-11-19; resolved 2026-11-23, not an app bug)
- **Repro:** owner opens Birch through Finder, Dock or Spotlight and reports it is grouped with VS Code in macOS Screen Time. Compared a direct executable launch with Launch Services using SorrelTest.app and scratch profiles; normal-launch symptom not reproduced.
- **Expected:** macOS identifies Birch independently, with existing Screen Time restrictions respected.
- **Actual:** reported attribution to VS Code. After merging/rebuilding the launch guard, owner clarifies that Birch opens normally but webpages remain blocked outside the intended 12–1 restriction window. The running main app is responsible for its own PID, confirmed externally without accessing profile data. The startup guard therefore does not explain the current webpage-blocking symptom. Exact blocking message requested; cause not established. Owner cannot verify locked Screen Time settings interactively.
- **Investigation:** owner confirms Finder/Dock/Spotlight launches. With identical fresh scratch profiles and local welcome pages, direct SorrelTest executable launch inherits VS Code as its responsible process; `open -n -g` through Launch Services gives SorrelTest its own responsible PID. Both runs produce snapshots and exit normally. The responsibility query is an external, read-only diagnostic (`responsibility_get_pid_responsible_for_pid` from libSystem), not an app dependency. App metadata uses `app.sorrel.browser` / `app.sorrel.browser.test`, not VS Code's identifier.
- **Page-controller mitigation (merged from `screen-time-pages`):** explicitly bind each native Screen Time webpage controller to `Bundle.main.bundleIdentifier` through Apple's `setBundleIdentifier` API. Runtime-check WebKit's private controller getter; preserve the original controller if unavailable or the API refuses. Binding follows native shield insertion on the next main-queue turn because configuration can arrive after navigation finishes. Isolated native-controller tests confirm automatic binding and preservation of the data store, profile and recording policy. The native shield and blocking decision are not disabled or overwritten. Scheduled enforcement remains unverified.
- **Status:** owner authorized best-effort fixes without interactive confirmation. Added and verified a startup guard for the reproduced direct-launch attribution path (see Fixed below). The original Finder/Dock/Spotlight symptom remains unverified: these checks measure process attribution, not Screen Time's displayed history or scheduled enforcement. Existing direct launches are a possible source of VS Code-attributed activity, but this does not establish the cause of the owner's report. No real profile, Screen Time database or restriction settings accessed. Owner could not verify interactively at the time.
- **Cause / resolution (2026-11-23):** owner reports it is fixed: the blocking came from Screen Time's website restrictions (limits set on sites), not from how macOS identified the Birch app. No Birch code change was the fix. The launch guard and webpage-controller binding above stay merged as hardening; whether to keep the binding (it reaches WebKit's controller through a private getter) is the owner's call.


### Direct executable launches inherit the editor's app identity (fixed 2026-11-19, branch `screen-time-identity`)
- **Repro:** launch a browser executable directly from a VS Code terminal. The isolated SorrelTest reproduction has VS Code as its responsible process; a Launch Services launch is responsible for itself.
- **Expected:** the daily browser starts with its own macOS app identity.
- **Actual:** direct startup opens the browser while retaining the editor's responsibility, which can affect macOS attribution. This is not proof of the separate reported normal-launch Screen Time symptom.
- **Cause / fix:** startup accepted shell/editor launches without checking Launch Services registration. Before allocator restart, migration or profile access, the normal app now checks the public `NSRunningApplication.current.launchDate` metadata and refuses direct startup with instructions to open Birch.app in Finder/Dock/Spotlight or with `open`. Bundle IDs, signatures, entitlements and Screen Time settings are unchanged. Direct SorrelTest hooks remain available; `SORREL_LAUNCHTEST=guard` exercises the same refusal with an isolated test profile.
- **Verified:** `python3 tools/launch-identity-test.py` checks direct test metadata, production-style refusal with exit 2 and no profile writes/window, successful Launch Services startup with its own responsible PID, retained sandbox/scratch profile, snapshots, all 22 window regressions and process exit. Debug/release builds pass with the same two source warnings. No actual Screen Time history or scheduled restriction test; no real app/profile launched or read.

### Idle tabs stay loaded during memory pressure (fixed 2026-11-18, branch `memory-efficiency`)
- **Repro:** load background tabs, leave them idle for ten minutes with the default two-hour sleep setting, then receive a macOS memory warning.
- **Expected:** reclaim eligible idle tabs early when the Mac needs memory, preserving active pages and playback.
- **Actual:** only the five-minute timer checks the two-hour limit; there is no memory-pressure handler.
- **Cause / fix:** maintenance only checked the configured age every five minutes; no macOS pressure source was registered. A retained Dispatch source now trims disposable app caches and sleeps eligible tabs after five idle minutes at warning or one at critical, respecting Never and shorter user intervals. Existing visible/split-pane, playback, capture, loading, extension and PiP guards are reused.
- **Verified:** baseline fixture retained four background tabs; direct warning/critical handler calls now retain two, with Page/WKWebView deallocation confirmed. All 17 memory checks, 22 multi-window checks and silent-media/seek checks pass after merging main. Debug/release builds retain the same two source warnings. Actual OS notification delivery and signed-in browsing under pressure are not exercised; no MB saving is claimed.


### A downloaded release stays in Downloads and can't update (fixed 2026-11-17, branch `move-to-apps`)
- **Repro:** download the release zip from GitHub, open Sorrel from Downloads (Open Anyway once).
- **Expected:** Sorrel ends up in Applications, where the updater can replace it.
- **Actual:** it runs translocated (a hidden read-only copy) and only said "drag it into Applications yourself"; updates never installed.
- **Cause / fix:** the sandboxed app can't write to Applications. At launch a translocated Sorrel now asks "Move Sorrel to Applications?"; SorrelUpdater.xpc copies its own (read-only, Gatekeeper-approved) bundle into /Applications (or ~/Applications), strips quarantine, and a detached helper swaps it in once Sorrel quits, trashes the Downloads copy and reopens Sorrel from Applications. `SORREL_MOVETEST=1` covers it with a /private/tmp stand-in (only Launch Services can translocate); the real download path needs the owner.

### White bar across the top in fullscreen (fixed 2026-11-17, branch `fullscreen-toolbar`)
- **Repro:** enter fullscreen (⌃⌘F) in a main or mini window.
- **Expected:** the top of the screen is page/sidebar; the titlebar strip (window buttons) appears only when the cursor reaches the top edge, like the menu bar.
- **Actual:** an opaque white strip stays across the top the whole time.
- **Cause / fix:** the windows carry an empty `NSToolbar` (for roomier window buttons); AppKit keeps a toolbar permanently visible, on an opaque material, in fullscreen unless the window asks otherwise (`titlebarAppearsTransparent` doesn't apply there). Both window delegates now return `.autoHideToolbar` from `window(_:willUseFullScreenPresentationOptions:)`. `SORREL_FULLSCREEN_TEST` checks the option is requested; the real fullscreen look needs the owner.

### Fullscreen retains windowed chrome (fixed 2026-11-17, branch `fullscreen-polish`)
- **Repro:** enter fullscreen with the sidebar hidden, reveal it on hover, then pin it.
- **Expected:** edge-to-edge page when hidden, compact pinned header, working native exit control, and restored windowed layout on exit.
- **Actual:** fullscreen uses the same page insets, corner radius and header spacing as a normal window; window buttons are forced transparent.
- **Cause / fix:** fullscreen callbacks only changed button visibility and reused all windowed geometry. Added fullscreen layout state, edge-to-edge single pages, compact pinned controls, native button availability, transition failure recovery and direct constraint updates when animation is disabled. Verified before/after layout regression checks, hover and split hooks, and debug/release builds with the same two source warnings. Native macOS transitions/top-edge reveal and hover feel await the owner.

### Paused video resumed when reopening Picture in Picture (fixed 2026-11-17, branch `picture-in-picture`)
- **Repro:** pause a video in PiP, return it to the tab, then open PiP again.
- **Expected:** the video stays paused, including after seeking.
- **Actual:** the local video fixture resumed after WebKit moved into the floating window.
- **Cause / fix:** WebKit could resume suspended playback as its view became visible again. Capture pause state before changing styles, explicitly pause before moving a paused video, and reapply the pause after attaching the floating window. Verified with local video pause/resume, reopen, seek bounds, return, embedded frames, navigation/close and private-store teardown; nearby sidebar playback/seek and split hooks pass. Debug/release builds retain the two existing source warnings.

### Sidebar mini player lacks transport controls (fixed 2026-11-17, branch `miniplayer-controls`)
- **Repro:** play media, switch tabs, inspect the sidebar player.
- **Expected:** compact Arc-style player with rewind, play/pause and fast-forward; automatic source selection.
- **Actual:** only play/pause and mute, plus a dropdown for previously playing tabs; no seek controls.
- **Cause / fix:** the original card implemented play/pause, mute and manual source selection only. Added 15-second rewind/forward buttons below track details, removed the dropdown, and automatically follow newly playing tabs. Fixed-script seeking preserves paused playback and clamps to seekable ranges. Verified before/after with silent local media, real seek button actions, bounds checks, source handoff, mute/sleep, Library suppression, closing/navigation and private-store isolation. Signed-in sites and feel need the owner; seeking cannot reach cross-origin frames.

### ⌘N could only show the existing main window (fixed 2026-11-17, branch `multiple-windows`)
- **Repro:** choose File ▸ Show Main Window / press ⌘N while a browser window is open.
- **Expected:** open another normal window and use different tabs in the same browsing session.
- **Actual:** the existing window came forward; one global selection could not support independent windows.
- **Cause / fix:** one window controller and global selection owned every page. Normal windows now have independent selections over shared profile data; selecting an already visible tab focuses its owning window. Quit preserves all normal window snapshots rather than saving each window's close in turn. Verified with the multi-window and restore hooks, split-view, private/security and silent-media checks.

### Updates refused for the real app: the updater service can't reach Sorrel's container (fixed 2026-11-16, branch `update-card`)
- **Found as:** `tools/update-test.sh` swapzip step didn't install (`The updater only writes to Sorrel's own update.log, not ~/Library/Containers/…`), same with ad-hoc and self-signed builds, and also when launched through LaunchServices (`open -g`).
- **Cause:** macOS app-data protection. `sandboxd` logs `TCC denied kTCCServiceSystemPolicyAppDataDetailed` when the (unsandboxed) updater service touches a path in the app's container, where the real app keeps both the downloaded zip and `update.log`. Other tests passed only because `SORREL_HOME` moves both to /private/tmp. So real installs were most likely always refused at the hand-off.
- **Fix:** the app opens the zip and the log itself and passes them as `FileHandle`s over XPC; the service takes no paths at all (log: plain file, one link, this user's). Verified: swapzip now installs with the log in the container, and the test build on its own container profile (launched with `open -g`) installed an update whose zip and log were both in its container. Copies already on 0.2.0–0.2.2 keep the old service, so they will most likely need one manual download.

### "Allow Sorrel to access files in your Downloads folder" on every download after a rebuild or update (fixed 2026-11-16, branch `downloads-tcc`)
- **Repro:** rebuild or update Sorrel, download a file.
- **Expected:** macOS asks once, ever.
- **Actual:** macOS asked again after every new build.
- **Cause:** on macOS 27 the sandbox checks with TCC before a sandboxed app touches `~/Downloads`, even with `files.downloads.read-write` (seen in the log: `sandboxd … checking kTCCServiceSystemPolicyDownloadsFolder for Sorrel`). TCC stores the yes against the app's designated requirement, and an ad-hoc signature's requirement is `cdhash H"…"`, which is different for every build. Fix: `build.sh` signs with a free self-signed certificate (`tools/make-signing-identity.sh`, kept in `~/.config/sorrel/signing.keychain-db`), so the requirement is `identifier … and certificate leaf = H"…"` for every build. Verified with the test build: a copy with a new code hash and the same certificate was allowed without asking; the existing sandbox container opened without a prompt after the switch from ad-hoc. Updates install fine (`tools/update-test.sh`). The first launch after the switch asks once more (Downloads, and camera/microphone/location when used).

### claude.ai (and other sites) call Sorrel an outdated browser on other Macs (fixed 2026-11-16, branch `ua-compat`)
- **Reported:** on another person's Mac running macOS newer than 15 (exact version unknown), Sorrel 0.2.0. Most likely macOS 26: the binary records SDK 15.4 (SwiftPM uses Package.swift's minimum), and macOS 26 reports "16.x" to such apps, so the old code sent `Version/16.0`, which claude.ai's check flags (verified: `Version/16.0` -> `"browser"`). This Mac (macOS 27.2) no longer does that, so it couldn't be reproduced natively; `SORREL_FAKE_OS=16.0` simulates it.
- **Repro:** Sorrel on macOS 15.x or 26.x, open claude.ai.
- **Expected:** treated like that Mac's Safari (18.x), no warning.
- **Actual:** the user agent said `Version/15.4 Safari/605.1.15`. claude.ai's own check (`p5()` in its bundle; minimum Safari 17, Chrome 127, Firefox 128) returns `"browser"`, which shows its unsupported/outdated-browser banner. Reproduced by running that check inside SorrelTest with the 15.x user agent; on this Mac (macOS 27.2 = Safari 27.2) the old code happened to be right.
- **Cause:** the Safari version in the user agent was the macOS version. They match only from macOS 26 on; macOS 15.x ships Safari 18.x. Fix: `Engine.safariVersion` reads the installed Safari's `CFBundleShortVersionString` (same system WebKit; readable under the sandbox, confirmed), falling back to macOS 26+ = same number, macOS 15.x = 18.x. After: real path `Version/27.2`, simulated 15.4 (`SORREL_FAKE_OS=15.4`) `Version/18.4`, both pass claude.ai's check. Also: the Chrome user agent used only on Proton's sign-in pages was frozen at Chrome 131 (Nov 2024); it now counts forward from Chrome 142 (2025-10-28) at one release per 31 days (154 on 2026-11-16).

### Proton Pass pop-up: header but blank item list and details (fixed 2026-11-16, branch `proton-list`)
- **Repro (owner's signed-in profile):** click the Proton Pass icon (also after a minute idle).
- **Expected:** the password list and the selected item's details.
- **Actual:** header, search and "All (353)" showed; the list and details were blank. (Earlier on 2026-11-15/16 the background crashed instead: `runtime.onUpdateAvailable` undefined; the wake-up and guard fixes on `proton-popup`/`proton-guard` stopped that.)
- **Cause:** `applyDeclaredSize` gave the page only `min-width/min-height`. Proton sizes `html`/`body`/`.app-root` with `height: 100%`, which resolves against the real height (small while WebKit measures the pop-up), so the app area shrank to its header (600x115 of 600x430) and the list panes got 0 height. Found with temporary on-device layout diagnostics (removed). Fix: real `width/height` on html and body. Owner confirmed it works. Also on the branch: pop-ups never count as hidden (`keepPopupAwake`; suspected first, not the cause, kept because covered pop-ups and test windows now draw) and the pop-up speed work in CLAUDE.md.

### Command bar flickers while typing (fixed 2026-11-16, branch `command-bar-fluid`)
- **Repro:** ⌘T (or ⌘L), with search suggestions on, type a word at a normal pace.
- **Expected:** rows that still fit stay put, new ones fill in smoothly below, the bar glides to its new size.
- **Actual:** after every letter the suggestion rows vanished and came back ~0.2 s later, so the list collapsed and regrew (`SORREL_TYPETEST=nephro`: 8 shrink-then-grow reversals in 6 letters, list rebuilt 12 times); the shadow snapped to the end size while the panel was still resizing.
- **Cause:** suggestions were shown only for the exact text they were fetched for, and every keystroke ran `reloadData`. Now the previous suggestions that still fit stay up until the new answer arrives, rows are matched by a key and updated in place (new ones fade in, gone ones fade out), and the list height follows a display-synced spring that re-lays out the whole bar each frame (`CommandBar.setListHeight`). After: the list holds its rows while typing, 2 rebuilds (opening only), field never moves.


### Centered command bar moves while typing (fixed 2026-11-15, branch `command-bar`)
- **Repro:** ⌘T, type something that fills several suggestion rows.
- **Expected:** the line you type on stays where it opened; the list grows below it.
- **Actual:** the whole bar re-centered as rows appeared, so the text field slid upward on every keystroke.
- **Cause:** the panel was pinned by its vertical center. It is now pinned by its top edge, placed from the window height only (`CommandBar.positionCentered`).

- **Proton Pass pop-up empty / no password list** (2026-11-15, branch `proton-popup`; fixed in test profiles only, the owner's real profile still fails: see Open). Repro: Proton enabled, leave it idle 30 s+ (WebKit stops its background), then click its icon or open its settings. Expected: the pop-up shows Proton. Actual: an empty 50×50 box, or a background crash (`runtime.onUpdateAvailable` undefined) that left every later pop-up empty. Cause: when a pop-up or an extension page restarts a stopped service-worker background, WebKit starts it badly; fix: Sorrel wakes the background itself first (`Extensions.wakeBackground`, used by the toolbar button, its shortcut, and any extension page loading in a tab).
