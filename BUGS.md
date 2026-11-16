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

### Proton Pass background crashes in the owner's real profile (NOT fixed; reported 2026-11-15, still failing 2026-11-16)
- **Repro (owner's profile only):** Sorrel signed in to Proton Pass (Chrome Web Store build 1.43.0). Click the Proton icon, also after waiting a minute idle.
- **Expected:** Proton's pop-up with the password list.
- **Actual:** a dark, empty pop-up at full size. Proton's Settings ▸ "Problems it reported" (2026-11-15, before the v14 guard): `TypeError: undefined is not an object (evaluating 'r_.runtime.onUpdateAvailable.addListener') (background.js:62:39368)` / `The background content failed to load due to an error.` **The error text after the v14 guard hasn't been captured yet; get it from the owner first.**
- **Tried, merged into `main`, did not fix it for the owner:**
  1. `proton-popup` (merged 8eda812): wake the background before a pop-up opens and before any extension page loads in a tab (`Extensions.wakeBackground`, Web.swift navigation policy). Fixed every repro in test profiles (10/10 crashes before, 0 after).
  2. `proton-guard` (merged 7521e29, ChromeCompat 14): rewrite Chrome-only event listeners in the extension's code to optional chaining (`onUpdateAvailable?.addListener(`). Confirmed applied to the owner's installed copy on 2026-11-16 (manifest `sorrel_compat` 14, background.js has the guarded line and no unguarded one). With the shim switched off in a test profile, the background still started, yet the owner says it is not fixed.
- **Couldn't reproduce outside the owner's profile:** fresh test profiles and a persistent extension store (`SORREL_EXT_STORE`, two launches) both pass with the current code. Differences left: signed-in state (Proton's own timers/alarms restarting the worker), the owner's real tabs, WebKit data accumulated in the real container (possibly a cached copy of the old worker script), and whatever WebKit does on the owner's machine that a test window doesn't (visible window, focus).
- **2026-11-16 update (branch `proton-list`):** the owner's new screenshot shows the background now works (header, "All (353)", the selected item's title) but the item list and item details are blank. Both are drawn with Proton's `anime-fade-in` (CSS animation, `both` fill: opacity 0 until it runs), and the list is sized by react-virtualized's AutoSizer, which updates on an animation frame. A test showed that when macOS reports the pop-up's window as occluded, WebKit counts the page as hidden: `visibilityState=hidden`, `requestAnimationFrame` never fires, every fade-in stays `running@0`. That reproduces the picture exactly. Fix: the pop-up web view gets `_windowOcclusionDetectionEnabled = false` (`Extensions.keepPopupAwake`), so WebKit counts it visible whenever its window is visible. What occludes it on the owner's screen is not known. Verified with a copy of the owner's installed Proton (signed out, idle 40 s, then clicked; `SORREL_EXTTEST=ui SORREL_UI_EXT=chrome-ghmb SORREL_UI_NODASH=1 SORREL_UI_PREWAIT=40`): before, `visibility=hidden rAF=stalled`, fade-ins `running@0`; after, `visibility=visible rAF=ok`, fade-ins `finished`, and the pop-up screenshot shows the sign-in screen, though its window is still reported occluded. **That was not the owner's cause:** the owner still saw the blank list with it.
- **Real cause (found 2026-11-16 from on-device layout diagnostics, `PopupDiagnostics.swift`, temporary):** the owner's pop-up was visible with animations running, but Proton's `.app-root` was 600x115 inside the 600x430 pop-up and both list panes were 0 tall. Proton sizes `html`/`body`/`.app-root` with `height: 100%`; `applyDeclaredSize` only set `min-height`, and a percentage height resolves against the parent's `height` (here the small height WebKit lays the pop-up out at to measure it), not its minimum. So the app area shrank to its content: header and filter bar, nothing for the list. Fix: `applyDeclaredSize` sets a real `width`/`height` (600x430) on html and body as well. Verified signed out: `.app-root` 600x338 -> 600x430, and the plain band at the bottom of the sign-in screen is gone. Owner's signed-in check pending (build at `build-fix/Sorrel.app`).
- **Leads for the next attempt:** (a) get the current "Problems it reported" text: same `onUpdateAvailable` error at the same position would mean WebKit is not running the patched files (cached worker?); a different error is the next missing piece. (b) Check whether the background fails at launch or only after idle (ask the owner to open the pop-up right after launch). (c) Never test against the real profile; reproduce with a copy in `SORREL_HOME`.

## Fixed

### Centered command bar moves while typing (fixed 2026-11-15, branch `command-bar`)
- **Repro:** ⌘T, type something that fills several suggestion rows.
- **Expected:** the line you type on stays where it opened; the list grows below it.
- **Actual:** the whole bar re-centered as rows appeared, so the text field slid upward on every keystroke.
- **Cause:** the panel was pinned by its vertical center. It is now pinned by its top edge, placed from the window height only (`CommandBar.positionCentered`).

- **Proton Pass pop-up empty / no password list** (2026-11-15, branch `proton-popup`; fixed in test profiles only, the owner's real profile still fails: see Open). Repro: Proton enabled, leave it idle 30 s+ (WebKit stops its background), then click its icon or open its settings. Expected: the pop-up shows Proton. Actual: an empty 50×50 box, or a background crash (`runtime.onUpdateAvailable` undefined) that left every later pop-up empty. Cause: when a pop-up or an extension page restarts a stopped service-worker background, WebKit starts it badly; fix: Sorrel wakes the background itself first (`Extensions.wakeBackground`, used by the toolbar button, its shortcut, and any extension page loading in a tab).
