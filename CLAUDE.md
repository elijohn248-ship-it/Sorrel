# Drift

Drift is the owner's daily macOS browser: Arc-style Spaces and sidebar, Safari's engine (WebKit), Helium-style privacy, bangs, and Safari-style extensions with uBlock Origin Lite built in. It is a single-person project; there are no other users yet.

## Name

**The product is being renamed to Sorrel ("Sorrel Browser").** Chosen 2026-11-14 after checking conflicts: Flow, Breeze, Cove, Wren, Lagoon, Tern, Fern and Moss are already used by other browsers (many of them new Arc replacements launched in Oct–Nov 2026). `sorrelbrowser.com`, `sorrel-browser.com` and the GitHub names `sorrelbrowser`/`sorrel-browser` were free that day; a US trademark search is still the owner's to do. The app icon is already Sorrel's (an arrow-shaped sorrel leaf on the original gradient tile, `tools/make-icon.swift`). Done so far (2026-11-14): the app is `build/Sorrel.app` (executable `Sorrel`), and every name a person sees says Sorrel. Still Drift on purpose: the bundle id, the SwiftPM target and `Sources/Drift`, class names, `DRIFT_*` test variables, the `drift://` address of bundled pages (saved tabs use it), the profile folder `Application Support/Drift`, and one error string inside ChromeCompat (changing it would re-patch installed extensions). **Do not change the bundle id (`app.drift.browser`) on its own.** WebKit keys cookies, logins and extension data by it, so the rename happens together with the App Sandbox move, with a data migration.

## Non-negotiables

- **WebKit (WKWebView), never Chromium.** The owner values battery life and low upkeep. Don't propose Chromium, CEF or Electron.
- **Free to run.** No paid Apple developer account (the app is ad-hoc signed), no paid services. Phone sync, when it comes, is a PWA on Cloudflare's free tier.
- **As private as Helium.** No telemetry. Ads and trackers blocked. Only two deliberate exceptions to "sites see Safari": the sites a Chrome-store extension lists under `externally_connectable` (e.g. Proton's sign-in pages) see a Chrome user agent and get a `chrome.runtime` bridge, because that's how they hand off to the extension.
- **Never touch the real profile from tests.** The real profile is `~/Library/Application Support/Drift`. Every test run must set `DRIFT_HOME` to a scratch folder (see Testing).
- **Test windows must stay in the background.** The owner uses the Mac while work happens. Test runs (any run with `DRIFT_SNAPSHOT` set) open behind other windows, take no focus and show no Dock icon. Keep that behaviour; `DRIFT_LOUD=1` is the only override. Warn before anything that will take focus.
- **Don't loop on state only the owner can see.** Signed-in extension behaviour, hover feel, drag and drop: after one or two rounds, stop and give the owner a specific thing to try and what to paste back.

## Build and run

Only Command Line Tools are installed (no Xcode), so this is a SwiftPM build that `build.sh` wraps into an app bundle.

```
./build.sh            # release build -> build/Sorrel.app
./build.sh run        # build and open
./build.sh install    # build and copy to /Applications
open build/Sorrel.app  # open the current build
```

Minimum macOS is 15.4 (needed for `WKWebExtension`). The owner runs the build from `build/`; after a rebuild they must quit and reopen Drift to get it. Say so every time.

`Info.plist` sets `MallocSpaceEfficient=1` (see Memory). `main.swift` re-execs once with it if a launch lacks it.

Signing is ad-hoc **with the hardened runtime** (`build.sh`: `--options runtime --entitlements Resources/Drift.entitlements`). The entitlements only allow camera and microphone; add one there if a new capability is refused under the runtime. ATS uses `NSAllowsArbitraryLoadsInWebContent`: web pages may still load http://, but Drift's own requests (lists, updates, favicons, suggestions) must be HTTPS.

## Layout

```
Sources/Drift/
  main.swift          entry; allocator re-exec; accessory activation policy in test mode
  App.swift           AppDelegate: commands, menus, engine wiring, and ALL test hooks (runDebugHooks)
  Support.swift       Settings (settings.json), Theme, Paths, isQuietTest, small helpers
  Models.swift        Item (tab/folder), Space, Store (state.json), archive, tab sleeping
  Data.swift          favicons, History, ZoomStore, Bangs, Resolver (typed text -> URL), URLCleaner
  Web.swift           Page (one WKWebView), Engine (navigation/UI delegate, downloads, peek decisions)
  Commands.swift      Commands registry, Keybindings (keybindings.json, chords, recorder support)
  MainWindow.swift    window, sidebar modes (pinned/hidden/peeking), hover logic, peek overlay host
  Sidebar.swift       sidebar outline, favorites grid, address pill (+ extension icons), space bar
  CommandBar.swift    ⌘T centered bar / ⌘L in-place editor, suggestions
  Peek.swift          link preview overlay; Site.key/same/host helpers
  Split.swift         split view: PaneView, PaneDivider, sidebar SplitCell (ContentCard in MainWindow.swift lays panes out)
  MiniWindow.swift    mini windows (links from other apps) and private windows
  ThemeEditor.swift   "Customize Space" popover (name, emoji grid, colors, gradient)
  EmojiPicker.swift   full emoji sheet that slides up inside Customize Space (search, categories, drag/pull down to close)
  SettingsWindow.swift General / Privacy / Extensions / Tabs / Sidebar / Shortcuts
  Blocker.swift       EasyList/EasyPrivacy -> WKContentRuleList converter and lifecycle
  Extensions.swift    WKWebExtension host: discovery, loading, tabs/windows adapters, pop-ups, Chrome Web Store installs, uBOL self-update
  ChromeCompat.swift  script injected into Chrome-store extensions so they run on WebKit
Resources/            Info.plist, welcome.html (drift://welcome), bangs.json (slimmed Kagi list), emoji.tsv, AppIcon.icns
vendor/ubol/ext       uBlock Origin Lite (Safari build, unmodified, GPL-3.0); build.sh bundles it
vendor/kagi-bangs     bang source list (MIT)
tools/make-icon.swift app icon generator (Sorrel leaf; `swift tools/make-icon.swift X.iconset && iconutil -c icns X.iconset -o Resources/AppIcon.icns`)
tools/make-emoji-list.py  Resources/emoji.tsv from Unicode's emoji-test.txt (rerun when a new Emoji version ships; emoji the Mac's font can't draw are hidden at runtime)
```

User data (per profile folder): `state.json` (spaces/tabs), `settings.json`, `keybindings.json` (+ `keybindings.default.json` reference, rewritten each launch), `bangs.json` (custom bangs), `history.json`, `archive.json`, `zoom.json`, `blocker.json` + `rulelists/`, `Extensions/` (added extensions), `BundledExtensions/ubol-<version>/`.

## How the pieces behave

- **Sidebar hover:** `MainWindowController` modes `pinned` / `hidden` / `peeking`. Reveal strip width, overshoot reach, hide delay and slide speed are all in `settings.json` and Settings ▸ Sidebar. While peeking, a 40 ms timer watches the real cursor (events stop arriving once it leaves the window; plain timers pause during menus/drags, which is wanted).
- **Command bar:** ⌘T = centered bar. ⌘L and clicking the address box = in-place editor anchored on the pill. A `focusHolder` on `DriftWindow` stops pages stealing focus while the bar is open.
- **Peek (link preview):** any clicked link to a different site opens over the page; ⌘O expands, Esc closes. Excluded on search engines (`peekExcludedSites`) and off for script-opened windows (sign-in pop-ups must still work).
- **Split view:** a split is an `Item` with `split: SplitLayout` (stacked flag + pane fractions) and 2–4 tabs in `children`, so it moves, pins, archives and saves as one unit, shown as one sidebar row. `Space.selectedID` is the *focused pane*, so the address box, ⌘L, ⌘W, find and extensions all act on it. Clicking into a pane focuses it (local mouse-down monitor). Closing a pane of an unpinned split closes that tab; in a pinned split it sleeps. One tab left = the split dissolves. Favorites can't be in a split. Store API: `makeSplit`, `removeFromSplit`, `unsplit`, `split(containing:)`, `unit(_:)`. Ways in: ⌃⇧= (command bar opens a pick beside the current tab), right-click a tab ▸ Open in Split View, drag a tab onto the page's left/right/top/bottom, drop a tab on a split row, or the split button on Peek. ⌃⇧- separates, ⌃⇧] / ⌃⇧[ move focus.
- **Row button (`TabActionButton`, Sidebar.swift):** pinned tabs and pinned split rows show "−" on hover while loaded (unload = `Store.close`, which sleeps them), then the two strokes rotate into "×", which runs `Store.closeAndUnpin` (out of the sidebar; ⌘⇧T reopens each tab unpinned). Clicks within 0.35 s of the change are ignored so a double-click can't remove the tab. Unpinned tabs show "×" as before. The strokes sit in one group layer so their transparency isn't doubled where they overlap.
- **Spaces:** each can keep separate logins (`profileID` -> `WKWebsiteDataStore(forIdentifier:)`). Favorites are shared across spaces.
- **Archiving / sleeping:** unpinned tabs idle > `archiveAfterHours` are archived (Tabs ▸ Archived Tabs). Any tab idle > `sleepTabsAfterMinutes` is unloaded; `interactionState` is saved so it wakes with history and scroll.
- **Blocking:** built-in lists (`Blocker.swift`) always cover private windows and the first 25 s after launch; once uBlock Origin Lite's rules are active it takes over on normal pages (`blockerInCharge`). **Never call `removeAllContentRuleLists()`**: it wipes the extension's rules too. Remove only our own lists.
- **Extensions:** `Extensions.shared` hosts them; `ExtensionTab`/`ExtensionWindow` adapt Drift's model. Bundled uBOL is unpacked to `BundledExtensions/` because **WebKit crashes (SIGKILL) if an extension's files sit inside the app bundle.** Safari extensions found in `/Applications/*/Contents/PlugIns/*.appex` are listed off-by-default. Chrome Web Store installs download the `.crx`, strip its header, and keep the real 32-letter id as `uniqueIdentifier`/base URL (the extension's own site addresses it by that id).
- **ChromeCompat:** adds inert stand-ins for Chrome-only APIs (`runtime.onUpdateAvailable`, `offscreen`, `idle`, …), a `requestIdleCallback` polyfill (and a private copy inside page-world scripts that need it), and **pins `globalThis.chrome`/`browser`** because Proton Pass replaces them with a locked Proxy and WebKit then silently drops every message. It only ever *adds*; **never wrap or Proxy the extension API, and never reassign `sendMessage`/`addListener`, even for tracing: delivery stops.** Bump `ChromeCompat.version` when you change it so installed copies re-patch.
- **Pop-up sizing:** WebKit sizes action pop-ups to content; Chrome pop-ups that declare a fixed size (Proton: 600×430) collapse to a strip. `applyDeclaredSize` reads the size from the extension's stylesheet (not the live page) and sets `min-width/min-height` so WebKit's popover grows. Hosting `popupWebView` in our own popover does not work (WebKit keeps resizing it).

- **Security behaviour (keep it):** HTTPS-first (`httpsFirst`, on by default): main-frame http:// GETs to ordinary hosts are retried as https://; if that fails or bounces back to http://, `showInsecureWarning` shows Drift's own page, and its Continue button (`drift-insecure:continue`, honoured only while that warning is up in that web view) allows the host until quit. Local names, IPs and non-80 ports are never upgraded. Drift's own error/warning pages go through `loadInternalPage` so navigation policy lets them through. Pages opening other apps (`openInOtherApp`) ask first, except clicked mailto/tel/sms/facetime links; grants last until quit. Main-frame `data:` navigations are blocked. Downloads are quarantined (WebKit does it; Drift drops the source addresses for private windows). ⌘/middle-click from a private window opens another private window, never a normal tab. Camera/mic choices are keyed by asker + top site, and never remembered in private windows. Favicon fetches are https only and carry the page's user agent. Extensions get only manifest-required permissions on switch-on; optional ones go through the prompt delegates and approvals persist in `settings.json` `extensionGrants`.

## Memory

Measure with `footprint -p <pid>`, not resident size: WebKit leaves 1 GB+ of reclaimable pages that `ps` counts. With uBOL on, the main process was ~235 MB of true footprint from malloc fragmentation after rule loading; `MallocSpaceEfficient=1` brings it to ~45 MB. Things that did not help: `malloc_zone_pressure_relief`, `MallocAggressiveMadvise`, trimming uBOL's unused rule sets.

## Testing

There is no test target. Tests are the app itself, driven by environment variables read in `App.swift` (`runDebugHooks`). Pattern:

```
S=/some/scratch; rm -rf $S/p1 && mkdir -p $S/p1
DRIFT_HOME=$S/p1 DRIFT_SNAPSHOT=$S/shot.png DRIFT_DELAY=8 DRIFT_OPEN=https://example.com build/Sorrel.app/Contents/MacOS/Sorrel 2>&1 | grep -E '^(selected|hover|peek|ext|ui|diag|autofill):?'
```

`DRIFT_SNAPSHOT` = quiet test mode + where to write a PNG of the window; the app quits itself after `DRIFT_DELAY` seconds. Useful hooks: `DRIFT_OPEN` (tab to open), `DRIFT_RUN=cmd,cmd` (commands), `DRIFT_SIDEBAR=hidden|peek`, `DRIFT_COMMAND=<text>` (type into ⌘T bar), `DRIFT_EDITADDR`, `DRIFT_HOVERTEST`, `DRIFT_PEEKTEST=expand|close|unpinned|samesite|othersite`, `DRIFT_FEATURETEST` (shortcuts, archive, private), `DRIFT_DAILYTEST` (sleep, downloads, suggestions, history, update check), `DRIFT_BLOCKTEST`, `DRIFT_EXTTEST=1|ui|protonpass`, `DRIFT_EXTDIAG=<id part>` (passive extension diagnostics: errors, a read-only message listener, heartbeat, pop-up layout dump), `DRIFT_AUTOFILLTEST`, `DRIFT_SECTEST` (HTTPS upgrade + not-secure warning + Continue, private ⌘-click, data: block, other-app prompt, download quarantine; `DRIFT_SECTEST_HTTP=<http url>` picks the no-https site, default expired.badssl.com), `DRIFT_SPLITTEST=1|reopen` (split view end to end; `reopen` just logs what a relaunch restored), `DRIFT_EMOJITEST=open|search:<q>,pick` (emoji sheet; pair with `DRIFT_SNAPSHOT_CUSTOMIZE=<png>`), `DRIFT_EXTERNALTEST`, `DRIFT_EXT_STORE=<uuid>` (persistent extension store for a test; delete `~/Library/WebKit/app.drift.browser/WebExtensions/<uuid>` afterwards), `DRIFT_DOWNLOADS=<dir>`.

To test an extension the owner has added, copy it from the real profile's `Extensions/` into the scratch profile; never run tests against the real profile. **Chrome Web Store downloads are not allowed from tests** (blocked as external communication); use the copy that is already installed. A tiny echo extension (manifest + one-line background that answers messages) is the fastest way to separate a WebKit limit from an extension quirk. In quiet test mode pages are `visibilityState: hidden`, so CSS fade-ins never run and pop-up screenshots can be blank even when the page rendered; check `innerText`, not pixels.

Known limits of what tests can show: real mouse feel, drag and drop, and anything behind the owner's sign-ins. Ask the owner for those.

## Known gaps and decisions

- Proton Pass (Chrome version, added by the owner) signs in and autofills. Its item-list site logos stay blank (`api-proxy/core/v4/images/logo`: Chrome serves them via a service-worker fetch handler WebKit lacks). Telling it that it is a pop-up (correcting `tabs.getCurrent`) blanked the signed-in list and was reverted; it renders its full-tab layout inside the 600×430 pop-up, which the owner accepted. The Safari version of Proton Pass cannot work (needs its companion app over native messaging).
- uBOL reports `Promise is not a constructor … ProceduralFiltererAPI` on some sites: its own Safari limitation for a few advanced cosmetic filters; network blocking is unaffected.
- One main window only. Not built yet: second window, passkeys, site location/notification permissions, phone sync (owner said later; plan is PWA + Cloudflare free tier, like `~/stint`).
- Not installed to /Applications and not the default browser; that is the owner's call (`./build.sh install`, then Settings ▸ General ▸ Make Drift the Default Browser).

## Working with the owner

Medical student, daily Safari user, former heavy Arc user. Wants Arc's feel (Spaces, hover sidebar, Peek, mini window) with Helium's privacy. Prefers plain, short explanations of what changed and what was verified versus not. Keep test output short and batched. Commit locally when asked; don't push or deploy anything without a go-ahead.
