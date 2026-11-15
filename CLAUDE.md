# Sorrel

Sorrel (formerly Drift) is the owner's daily macOS browser: Arc-style Spaces and sidebar, Safari's engine (WebKit), Helium-style privacy, bangs, and Safari-style extensions with uBlock Origin Lite built in. It is a single-person project; there are no other users yet.

## Name, and the rename from Drift

The app was called **Drift** until 2026-11-14; it is now **Sorrel** ("Sorrel Browser"). The name was chosen after conflict checks: Flow, Breeze, Cove, Wren, Lagoon, Tern, Fern and Moss are already used by other browsers (many are new Arc replacements from Oct–Nov 2026, as Arc shuts down on 2026-12-22). `sorrelbrowser.com`, `sorrel-browser.com` and the GitHub names `sorrelbrowser`/`sorrel-browser` were free then; the US trademark search is still the owner's to do. The icon is an arrow-shaped sorrel leaf on the original gradient tile (`tools/make-icon.swift`).

Everything is renamed: bundle id `app.sorrel.browser`, `Sources/Sorrel`, the `Sorrel` SwiftPM target, `SORREL_*` test variables, `sorrel://` for bundled pages, the profile folder `~/Library/Application Support/Sorrel`, and the project folder `~/sorrel` (`~/drift` is a symlink to it so old references still resolve). The only deliberate "drift" left in code is a `drift://` -> `sorrel://` fallback in `Engine.load`.

**The Drift -> Sorrel copy** ran on the owner's first Sorrel launch (2026-11-14). Its code was replaced by the sandbox move below (it is in git history before the `sandbox` branch). **The Drift originals (`Application Support/Drift`, `WebKit/app.drift.browser`, `HTTPStorages/app.drift.browser*`) are the owner's backup: delete them only when the owner says so.**

## Sandbox

Sorrel runs in the macOS **App Sandbox** (`Resources/Sorrel.entitlements`, ad-hoc signed, hardened runtime). The point: a page or extension that compromised Sorrel's main process still couldn't read the owner's files, SSH keys, other apps' data, or run things freely. Inside it, Foundation's home folder (`NSHomeDirectory`, `homeDirectoryForCurrentUser`, `~/Library` lookups) is the container `~/Library/Containers/app.sorrel.browser/Data`; use `Sandbox.realHome` / `Sandbox.downloads` (Support.swift) when you mean the person's real folders. `Sandbox.isOn` tells you if it's active.

- **Entitlements, keep the list short:** network client; camera + microphone; `~/Downloads` read-write; files the person picks in an Open panel (read-only: uploads, adding an extension); printing; and read-only temporary exceptions for `~/Applications` (Safari extensions, fallback browser) and the pre-sandbox data the move copies. Add an entitlement only when a feature is refused under the sandbox, and say why in the file.
- **Child processes inherit the sandbox but not access to picked files**: `ditto` unpacks a private copy of a picked zip (Extensions.add). `screencapture` from inside the app no longer works.
- **Ad-hoc signing is fine**: a rebuilt app (new code hash) keeps opening its container without prompts (tested 2026-11-14). No certificate needed.
- **Layout inside the container differs from outside** (found by experiment): WebKit keeps `Library/WebKit/WebsiteData`, `WebExtensions`, `ContentRuleLists` *without* the bundle-id folder, and the cookie jar is `Library/Cookies/Cookies.binarycookies`, not `HTTPStorages/<id>.binarycookies`.
- **The move (`Migration.swift`, first thing in `main.swift`).** On the first sandboxed launch (no `SORREL_HOME`; container has no `Application Support/Sorrel`; the real one exists) Sorrel COPIES, never moves: each item of `~/Library/WebKit/app.sorrel.browser/` -> `WebKit/<item>`, `HTTPStorages/app.sorrel.browser.binarycookies` -> `Cookies/Cookies.binarycookies`, `HTTPStorages/app.sorrel.browser/`, then `Application Support/Sorrel` (last; it marks the move done), via `.migrating` temp names; anything already in the way is set aside as `*.before-migration-<time>`. Then it merges the old preferences plist and writes `moved-into-sandbox.txt`. It refuses while an older Sorrel is running (offers to quit it), and on failure quits without keeping a partial copy, so the next launch retries. **The originals in `~/Library` stay as the owner's backup** and are what an unsandboxed build would still open. Verified end to end with the test build (cookie + open tab carried over); the owner's real move is theirs to run. `SORREL_MIGRATE_TEST=<from Library>:<to Library>` runs just the copy between stand-in folders.
- **Window snapshots can't see page content under the sandbox**: `SORREL_SNAPSHOT` (cacheDisplay) shows the web area blank; the page is fine. Use `SORREL_WEBSNAPSHOT=<png>` for WebKit's own picture of the selected page.

## Non-negotiables

- **WebKit (WKWebView), never Chromium.** The owner values battery life and low upkeep. Don't propose Chromium, CEF or Electron.
- **Free to run.** No paid Apple developer account (the app is ad-hoc signed), no paid services. Phone sync, when it comes, is a PWA on Cloudflare's free tier.
- **As private as Helium.** No telemetry. Ads and trackers blocked. Only two deliberate exceptions to "sites see Safari": the sites a Chrome-store extension lists under `externally_connectable` (e.g. Proton's sign-in pages) see a Chrome user agent and get a `chrome.runtime` bridge, because that's how they hand off to the extension.
- **Never touch the real profile from tests.** The real profile is in Sorrel's container (`~/Library/Containers/app.sorrel.browser`), with the pre-sandbox copy in `~/Library/Application Support/Sorrel`. Every test run uses **`build/SorrelTest.app`** (bundle id `app.sorrel.browser.test`: its own container, preferences and site data) and sets `SORREL_HOME` to a scratch folder under `/private/tmp` (see Testing). `Sorrel.app` refuses to start with `SORREL_HOME` set. With it set, cookies and site data also stay in memory (`Engine.store(for:)` returns one non-persistent store): WebKit files persistent site data by bundle id, not by profile folder, so before 2026-11-14 test runs were writing into the owner's real cookie jar. Keep it that way. Launching the app without `SORREL_HOME` is the owner's job, never an agent's.
- **Test windows must stay in the background.** The owner uses the Mac while work happens. Test runs (any run with `SORREL_SNAPSHOT` set) open behind other windows, take no focus and show no Dock icon. Keep that behaviour; `SORREL_LOUD=1` is the only override. Warn before anything that will take focus.
- **Don't loop on state only the owner can see.** Signed-in extension behaviour, hover feel, drag and drop: after one or two rounds, stop and give the owner a specific thing to try and what to paste back.

## Working in parallel (several agents at once)

The owner runs several Claude sessions at the same time. **Sessions must not share a working folder**: one session's half-finished edit breaks every other session's build (it happened twice on 2026-11-14).

- `~/sorrel` is `main` and the copy the owner runs (`build/Sorrel.app`). While other sessions are active, don't do feature work directly in it.
- Each task gets its own git worktree and branch: `cd ~/sorrel && git worktree add ../sorrel-<task> -b <task>` (or Claude Code's worktree option). Edit, build and test only there; each worktree has its own `.build/` and `build/`, and its first build takes a few minutes.
- Start every session with `git worktree list` and `git status` to see what's in flight.
- Before reporting a task done: commit on its branch, merge `main` into it, rebuild, and rerun the tests that cover what changed. Resolve conflicts in the worktree, never in `~/sorrel`.
- **The owner decides what merges.** Agents don't merge into `main` or push unless asked. When asked: `cd ~/sorrel && git merge <task> && ./build.sh`, then `git worktree remove ../sorrel-<task> && git branch -d <task>`, and tell the owner to quit and reopen Sorrel.
- Collision hotspots, so keep diffs there small and local: `App.swift` (every test hook; add a new hook as its own `if env[...]` block, don't reshuffle others), `Web.swift`, `SettingsWindow.swift`, `Support.swift` (each new setting needs a field AND a decoder line), and this file (edit only the section you're changing).
- Tests from different worktrees can run at the same time: each uses its own scratch `SORREL_HOME` and in-memory site data. Each test launch still opens a background window, so keep runs batched.

## Build and run

Only Command Line Tools are installed (no Xcode), so this is a SwiftPM build that `build.sh` wraps into an app bundle.

```
./build.sh            # release build -> build/Sorrel.app
./build.sh run        # build and open
./build.sh install    # build and copy to /Applications
open build/Sorrel.app  # open the current build
```

Minimum macOS is 15.4 (needed for `WKWebExtension`). The owner runs the build from `build/`; after a rebuild they must quit and reopen Sorrel to get it. Say so every time.

`Info.plist` sets `MallocSpaceEfficient=1` (see Memory). `main.swift` re-execs once with it if a launch lacks it.

Signing is ad-hoc **with the hardened runtime and the App Sandbox** (`build.sh`: `--options runtime --entitlements Resources/Sorrel.entitlements`; see Sandbox). Every build makes two apps from one compile: `build/Sorrel.app` (the owner's) and `build/SorrelTest.app` (tests only; `build.sh` derives its Info.plist and entitlements from the real ones: bundle id `+.test`, display name Sorrel Test, no http/https handler, plus read-write on `/private/tmp/`). ATS uses `NSAllowsArbitraryLoadsInWebContent`: web pages may still load http://, but Sorrel's own requests (lists, updates, favicons, suggestions) must be HTTPS.

## Layout

```
Sources/Sorrel/
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
Resources/            Info.plist, welcome.html (sorrel://welcome), bangs.json (slimmed Kagi list), emoji.tsv, AppIcon.icns
vendor/ubol/ext       uBlock Origin Lite (Safari build, unmodified, GPL-3.0); build.sh bundles it
vendor/kagi-bangs     bang source list (MIT)
tools/make-icon.swift app icon generator (Sorrel leaf; `swift tools/make-icon.swift X.iconset && iconutil -c icns X.iconset -o Resources/AppIcon.icns`)
tools/make-emoji-list.py  Resources/emoji.tsv from Unicode's emoji-test.txt (rerun when a new Emoji version ships; emoji the Mac's font can't draw are hidden at runtime)
```

User data (per profile folder, inside the container's `Library/Application Support/Sorrel`): `state.json` (spaces/tabs), `settings.json`, `keybindings.json` (+ `keybindings.default.json` reference, rewritten each launch), `bangs.json` (custom bangs), `history.json`, `archive.json`, `zoom.json`, `blocker.json` + `rulelists/`, `Extensions/` (added extensions), `BundledExtensions/ubol-<version>/`.

## How the pieces behave

- **Sidebar hover:** `MainWindowController` modes `pinned` / `hidden` / `peeking`. Reveal strip width, overshoot reach, hide delay and slide speed are all in `settings.json` and Settings ▸ Sidebar. While peeking, a 40 ms timer watches the real cursor (events stop arriving once it leaves the window; plain timers pause during menus/drags, which is wanted).
- **Command bar:** ⌘T = centered bar. ⌘L and clicking the address box = in-place editor anchored on the pill. A `focusHolder` on `SorrelWindow` stops pages stealing focus while the bar is open.
- **Peek (link preview):** any clicked link to a different site opens over the page; ⌘O expands, Esc closes. Excluded on search engines (`peekExcludedSites`) and off for script-opened windows (sign-in pop-ups must still work).
- **Split view:** a split is an `Item` with `split: SplitLayout` (stacked flag + pane fractions) and 2–4 tabs in `children`, so it moves, pins, archives and saves as one unit, shown as one sidebar row. `Space.selectedID` is the *focused pane*, so the address box, ⌘L, ⌘W, find and extensions all act on it. Clicking into a pane focuses it (local mouse-down monitor). Closing a pane of an unpinned split closes that tab; in a pinned split it sleeps. One tab left = the split dissolves. Favorites can't be in a split. Store API: `makeSplit`, `removeFromSplit`, `unsplit`, `split(containing:)`, `unit(_:)`. Ways in: ⌃⇧= (command bar opens a pick beside the current tab), right-click a tab ▸ Open in Split View, drag a tab onto the page's left/right/top/bottom, drop a tab on a split row, or the split button on Peek. ⌃⇧- separates, ⌃⇧] / ⌃⇧[ move focus.
- **Row button (`TabActionButton`, Sidebar.swift):** pinned tabs and pinned split rows show "−" on hover while loaded (unload = `Store.close`, which sleeps them), then the two strokes rotate into "×", which runs `Store.closeAndUnpin` (out of the sidebar; ⌘⇧T reopens each tab unpinned). Clicks within 0.35 s of the change are ignored so a double-click can't remove the tab. Unpinned tabs show "×" as before. The strokes sit in one group layer so their transparency isn't doubled where they overlap.
- **Spaces:** each can keep separate logins (`profileID` -> `WKWebsiteDataStore(forIdentifier:)`). Favorites are shared across spaces.
- **Archiving / sleeping:** unpinned tabs idle > `archiveAfterHours` are archived (Tabs ▸ Archived Tabs). Any tab idle > `sleepTabsAfterMinutes` is unloaded; `interactionState` is saved so it wakes with history and scroll.
- **Blocking:** built-in lists (`Blocker.swift`) always cover private windows and the first 25 s after launch; once uBlock Origin Lite's rules are active it takes over on normal pages (`blockerInCharge`). **Never call `removeAllContentRuleLists()`**: it wipes the extension's rules too. Remove only our own lists.
- **Extensions:** `Extensions.shared` hosts them; `ExtensionTab`/`ExtensionWindow` adapt Sorrel's model. Bundled uBOL is unpacked to `BundledExtensions/` because **WebKit crashes (SIGKILL) if an extension's files sit inside the app bundle.** Safari extensions found in `/Applications/*/Contents/PlugIns/*.appex` are listed off-by-default. Chrome Web Store installs download the `.crx`, strip its header, and keep the real 32-letter id as `uniqueIdentifier`/base URL (the extension's own site addresses it by that id).
- **ChromeCompat:** adds inert stand-ins for Chrome-only APIs (`runtime.onUpdateAvailable`, `offscreen`, `idle`, …), a `requestIdleCallback` polyfill (and a private copy inside page-world scripts that need it), and **pins `globalThis.chrome`/`browser`** because Proton Pass replaces them with a locked Proxy and WebKit then silently drops every message. It only ever *adds*; **never wrap or Proxy the extension API, and never reassign `sendMessage`/`addListener`, even for tracing: delivery stops.** Bump `ChromeCompat.version` when you change it so installed copies re-patch.
- **Pop-up sizing:** WebKit sizes action pop-ups to content; Chrome pop-ups that declare a fixed size (Proton: 600×430) collapse to a strip. `applyDeclaredSize` reads the size from the extension's stylesheet (not the live page) and sets `min-width/min-height` so WebKit's popover grows. Hosting `popupWebView` in our own popover does not work (WebKit keeps resizing it).

- **Security behaviour (keep it):** HTTPS-first (`httpsFirst`, on by default): main-frame http:// GETs to ordinary hosts are retried as https://; if that fails or bounces back to http://, `showInsecureWarning` shows Sorrel's own page, and its Continue button (`sorrel-insecure:continue`, honoured only while that warning is up in that web view) allows the host until quit. Local names, IPs and non-80 ports are never upgraded. Sorrel's own error/warning pages go through `loadInternalPage` so navigation policy lets them through. Pages opening other apps (`openInOtherApp`) ask first, except clicked mailto/tel/sms/facetime links; grants last until quit. Main-frame `data:` navigations are blocked. Downloads are quarantined (WebKit does it; Sorrel drops the source addresses for private windows). ⌘/middle-click from a private window opens another private window, never a normal tab. Camera/mic choices are keyed by asker + top site, and never remembered in private windows. Favicon fetches are https only and carry the page's user agent. Extensions get only manifest-required permissions on switch-on; optional ones go through the prompt delegates and approvals persist in `settings.json` `extensionGrants`.

## Memory

Measure with `footprint -p <pid>`, not resident size: WebKit leaves 1 GB+ of reclaimable pages that `ps` counts. With uBOL on, the main process was ~235 MB of true footprint from malloc fragmentation after rule loading; `MallocSpaceEfficient=1` brings it to ~45 MB. Things that did not help: `malloc_zone_pressure_relief`, `MallocAggressiveMadvise`, trimming uBOL's unused rule sets.

## Testing

There is no test target. Tests are the app itself, driven by environment variables read in `App.swift` (`runDebugHooks`). Pattern:

```
S=/some/scratch; rm -rf $S/p1 && mkdir -p $S/p1
SORREL_HOME=$S/p1 SORREL_SNAPSHOT=$S/shot.png SORREL_DELAY=8 SORREL_OPEN=https://example.com build/SorrelTest.app/Contents/MacOS/Sorrel 2>&1 | grep -E '^(selected|hover|peek|ext|ui|diag|autofill):?'
```

Scratch folders must be under `/private/tmp` (the only place outside its container the sandboxed test build may write). `SORREL_SNAPSHOT` = quiet test mode + where to write a PNG of the window (web content comes out blank under the sandbox: add `SORREL_WEBSNAPSHOT=<png>` for the page itself); the app quits itself after `SORREL_DELAY` seconds. Useful hooks: `SORREL_OPEN` (tab to open), `SORREL_RUN=cmd,cmd` (commands), `SORREL_SIDEBAR=hidden|peek`, `SORREL_COMMAND=<text>` (type into ⌘T bar), `SORREL_EDITADDR`, `SORREL_HOVERTEST`, `SORREL_PEEKTEST=expand|close|unpinned|samesite|othersite`, `SORREL_FEATURETEST` (shortcuts, archive, private), `SORREL_DAILYTEST` (sleep, downloads, suggestions, history, update check), `SORREL_BLOCKTEST`, `SORREL_EXTTEST=1|ui|protonpass`, `SORREL_EXTDIAG=<id part>` (passive extension diagnostics: errors, a read-only message listener, heartbeat, pop-up layout dump), `SORREL_AUTOFILLTEST`, `SORREL_MIGRATE_TEST=<from>:<to>` (runs the sandbox move's copy between two stand-in Library folders and exits), `SORREL_COOKIETEST=set|check` (a lasting example.com cookie across launches; only meaningful without `SORREL_HOME`, i.e. in SorrelTest's own container profile), `SORREL_SECTEST` (HTTPS upgrade + not-secure warning + Continue, private ⌘-click, data: block, other-app prompt, download quarantine; `SORREL_SECTEST_HTTP=<http url>` picks the no-https site, default expired.badssl.com), `SORREL_SPLITTEST=1|reopen` (split view end to end; `reopen` just logs what a relaunch restored), `SORREL_EMOJITEST=open|search:<q>,pick` (emoji sheet; pair with `SORREL_SNAPSHOT_CUSTOMIZE=<png>`), `SORREL_EXTERNALTEST`, `SORREL_EXT_STORE=<uuid>` (persistent extension store for a test, inside SorrelTest's container), `SORREL_DOWNLOADS=<dir>`.

To test an extension the owner has added, copy it from the real profile's `Extensions/` into the scratch profile; never run tests against the real profile. **Chrome Web Store downloads are not allowed from tests** (blocked as external communication); use the copy that is already installed. A tiny echo extension (manifest + one-line background that answers messages) is the fastest way to separate a WebKit limit from an extension quirk. In quiet test mode pages are `visibilityState: hidden`, so CSS fade-ins never run and pop-up screenshots can be blank even when the page rendered; check `innerText`, not pixels.

Known limits of what tests can show: real mouse feel, drag and drop, and anything behind the owner's sign-ins. Ask the owner for those.

## Known gaps and decisions

- Proton Pass (Chrome version, added by the owner) signs in and autofills. Its item-list site logos stay blank (`api-proxy/core/v4/images/logo`: Chrome serves them via a service-worker fetch handler WebKit lacks). Telling it that it is a pop-up (correcting `tabs.getCurrent`) blanked the signed-in list and was reverted; it renders its full-tab layout inside the 600×430 pop-up, which the owner accepted. The Safari version of Proton Pass cannot work (needs its companion app over native messaging).
- uBOL reports `Promise is not a constructor … ProceduralFiltererAPI` on some sites: its own Safari limitation for a few advanced cosmetic filters; network blocking is unaffected.
- One main window only. Not built yet: second window, passkeys, site location/notification permissions, phone sync (owner said later; plan is PWA + Cloudflare free tier, like `~/stint`).
- Not installed to /Applications and not the default browser; that is the owner's call (`./build.sh install`, then Settings ▸ General ▸ Make Sorrel the Default Browser).

## Working with the owner

Medical student, daily Safari user, former heavy Arc user. Wants Arc's feel (Spaces, hover sidebar, Peek, mini window) with Helium's privacy. Prefers plain, short explanations of what changed and what was verified versus not. Keep test output short and batched. Commit locally when asked; don't push or deploy anything without a go-ahead.
