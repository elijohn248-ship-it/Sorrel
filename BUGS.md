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


(none)

## Fixed

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
