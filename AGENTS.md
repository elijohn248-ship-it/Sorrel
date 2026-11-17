# AGENTS.md: how to work on Sorrel

This file is for AI coding agents picking up Sorrel. Read all of it before you change anything. It is written as plain rules and checklists on purpose: follow them literally. When this file says "ask the owner", stop and ask. Do not guess.

Three other files matter:

| File | What it is | When to read it |
|---|---|---|
| `AGENTS.md` (this file) | Rules, goals, current state, step-by-step recipes | First, every session |
| `CLAUDE.md` | The detailed technical handbook: how every part works, every test hook, every past pitfall | Before touching a part of the app, read that part's section there |
| `BUGS.md` | Bug list: Open (to fix) and Fixed (with causes) | Before fixing a bug; update it after |
| `PROGRESS.md` | Unfinished work handed between sessions | Start of session; update it at the end. **Warning:** on `main` it is partly out of date (see "Current state") |

If this file and `CLAUDE.md` seem to disagree about a **rule**, the stricter one wins. If they disagree about a **technical fact**, trust the code, then `CLAUDE.md`, then tell the owner the docs disagree.

---

## 1. What Sorrel is (read this so your choices fit)

Sorrel is a **web browser for the Mac**, written in **Swift** with **AppKit** and **WebKit** (`WKWebView`, the engine Safari uses). It was called **Drift** until 2026-11-14.

It is the owner's **daily browser**. They are a former heavy user of the Arc browser (Arc shuts down on 2026-12-22) and a daily Safari user. The one-line goal, in the owner's words: **"a Safari version of Arc"** with the privacy and security of the **Helium** browser, plus Helium-style **bangs** (`!w wikipedia`, `!yt video`).

The project is also **open source** (GPL-3.0, public on GitHub at `elijohn248-ship-it/Sorrel`) and has a published release, so other people can install it. Treat every change as something real users will receive.

### What makes it Sorrel (the features the owner cares about most)

- **Spaces** (Arc-style): each space has its own tabs, its own colours/gradient/grain, an emoji icon, and optionally separate logins.
- **Favorites** shared across all spaces; **pinned tabs** and **folders** per space.
- **A sidebar that hides and reveals on hover**, "identical to Arc".
- **Peek**: clicking a link to another site opens a preview over the page. ⌘O expands it to a tab, Esc closes it.
- **Mini window** for links opened from other apps.
- **Command bar**: ⌘T opens a centred bar; ⌘L / clicking the address box edits in place.
- **Split view** (2-4 tabs side by side), **space swipe** (two-finger swipe between spaces).
- **Privacy**: ad and tracker blocking (built-in lists plus **uBlock Origin Lite** bundled), HTTPS-first, no telemetry, App Sandbox.
- **Extensions**: Safari-style web extensions through WebKit's `WKWebExtension` API, plus installs from the **Chrome Web Store**. The owner's password manager is **Proton Pass** (Chrome version), which works through a compatibility layer (`ChromeCompat.swift`).
- **Self-updater** from GitHub releases, signed with Ed25519.
- **Browser import** from Arc, Chrome-family browsers, Firefox/Zen, Safari, bookmarks HTML.
- **Library** (downloads, history, archived tabs), Arc-style download animations.
- **Fluid motion** everywhere (shared animation helpers).

### The phase the project is in

**Polish phase.** Sorrel is basically built. The job now is: fix bugs, harden security and privacy, and make it feel smooth. **Prefer small, verified changes over rewrites.** Do not restructure files, rename things, or "clean up" code you were not asked to touch.

---

## 2. Non-negotiable rules

Break none of these. If a task seems to need breaking one, **stop and ask the owner**, and explain which rule and why.

### 2.1 Product rules

1. **WebKit only. Never Chromium, CEF or Electron.** Do not suggest them. The owner values battery life and low upkeep.
2. **Free to run.** No paid Apple developer account ($99/yr), no paid services, no paid tiers. The app is self-signed. Online pieces (tab sync relay) run on **Cloudflare's free tier**. Do not suggest the App Store, notarization, CloudKit/iCloud sync or anything that costs money unless the owner asks.
3. **Sites see this Mac's Safari.** The user agent's `Version/` is the installed Safari's version (`Engine.safariVersion`), never the macOS version. The only exception: sites that a Chrome-store extension lists under `externally_connectable` (today only Proton's `account.proton.me` and `pass.proton.me`) see a Chrome user agent and get a `chrome.runtime` bridge.
4. **As private as Helium.** No analytics, no crash reporting, no telemetry, ever. Ads and trackers blocked by default.

### 2.2 Hard rules for code (the owner wrote these)

1. **Never weaken a security or privacy setting to fix a bug.** If a site breaks because of blocking, the sandbox or a permission prompt, add a **narrow per-site exception** or ask. A privacy browser that leaks once isn't private.
2. **No new outbound network calls.** Allowed today: page loads, filter-list / uBOL updates, Chrome Web Store extension updates, the Sorrel updater, opt-in search suggestions, favicons, and (only when sync is on, on the `sync` branch) the owner's sync relay. Nothing else. No analytics or telemetry, ever.
3. **No new entitlements or temporary exceptions.** `Resources/Sorrel.entitlements` should only shrink. **Ask before touching it.**
4. **No page-to-app JavaScript bridge.** There are no `WKScriptMessageHandler`s; keep it that way unless the owner approves one. Scripts the app injects must **never paste page-controlled strings into JavaScript source**. Pass values as arguments (`callAsyncJavaScript(_:arguments:...)`).
5. **Every bug fix gets verified** (see section 6), and the build must pass before you say you're done.
6. **Don't add compiler warnings.** The release build has a known baseline (see section 8). Keep it at that number or fewer.
7. **Don't hand-edit `vendor/`.** It's third-party code (uBlock Origin Lite, Kagi bangs). Update it only by replacing it from upstream.
8. **Don't run `./build.sh` in `~/sorrel` without asking.** Its first step deletes `build/Sorrel.app`, the copy the owner is usually running right now. In a task worktree it is fine. To check that code compiles, use `swift build`.

### 2.3 Security invariants (re-check whenever you touch related code)

- Private windows always use a **non-persistent** `WKWebsiteDataStore` (`Web.swift`: `makeConfiguration`, `store(for:)`), never the default store. Private downloads, history and session restore leave nothing on disk.
- **Never auto-grant a permission.** Camera/mic in private windows ask every time. Location asks every time, "Don't Allow" is the default button, nothing is remembered.
- The `sorrel-insecure:` link works only from Sorrel's own warning page, only while that warning is showing. A web page must not be able to use it.
- The Chrome `chrome.runtime` page bridge goes only to exact hosts an extension lists in `externally_connectable` (`Extensions.swift`: `companionSites`; `ChromeCompat.exactHostPatterns` drops wildcard hosts). Don't widen it.
- `openInOtherApp` always asks before launching another app. File uploads reach only files the user picked.
- The address bar always shows the page's **real** origin. Only a *leading* `www.` is dropped. Lookalike international domains show as punycode. Long hosts are cut at the front so the real domain stays visible.
- Content blocking stays on by default. A broken site gets a per-site toggle, never a global off switch.
- The updater installs only updates whose **signature verifies**. Never weaken that. `SorrelUpdater` (the XPC service) is deliberately signed **without** entitlements and **without** the sandbox; keep it that way. It must never take file paths from the app (it receives open `FileHandle`s).

### 2.4 Safety rules for the owner's data and machine

- **Never touch the owner's real profile.** It lives in `~/Library/Containers/app.sorrel.browser/` (the live one, inside the sandbox container). There is also an old pre-sandbox copy in `~/Library/Application Support/Sorrel`, and Drift-era data (`Application Support/Drift`, `WebKit/app.drift.browser`, `HTTPStorages/app.drift.browser*`). **All of those are the owner's. Do not read, edit, move or delete them.** The Drift and pre-sandbox copies are the owner's backup: delete only if the owner explicitly says so.
- **Never launch `build/Sorrel.app` yourself** (or the app without `SORREL_HOME`). That is the owner's real browser. You only ever launch `build/SorrelTest.app` with `SORREL_HOME` pointing at a scratch folder (section 7). The code enforces part of this: `Sorrel.app` refuses to start with `SORREL_HOME` set and ignores all `SORREL_*` test variables.
- **Secrets live in `~/.config/sorrel/`, outside the repo**: `update-signing-key` (Ed25519 private key for releases), `github-token`, `sync-relay-url`, `sync-house-key`, and (once created) `signing.keychain-db`. **Never print, copy, commit or paste their contents anywhere.** Don't `cat` them. Scripts read them; you don't need to.
  - **If `update-signing-key` is lost, no installed copy can ever update again.** Never delete, move, regenerate or overwrite it.
- **The GitHub repo is public.** Everything committed and pushed (this file included) is visible to everyone. Never commit keys, tokens, the relay address, the owner's personal data, or anything read from their profile. Some audit reports are kept out of git on purpose (e.g. `SECURITY-AUDIT.md` in the `security-audit` worktree, `GAPS.md` in `sorrel-gap-audit`): don't commit them.
- **Commands you must never run:** `rm -rf` (anything), `sudo`, `git push --force` / `-f`, `curl … | sh` / `| bash`.
- **Commands you must ask before running:** `git push`, `git reset`, `git checkout` (switching branches/discarding), `git clean`, `codesign` by hand, `tools/release.sh` (any form), `./build.sh` inside `~/sorrel`.
- **Files you must ask before editing:** `Resources/Sorrel.entitlements`, `Resources/Info.plist`, `Resources/SorrelUpdater.plist`, `build.sh`, `Package.swift`, anything in `Sources/SorrelUpdateCore/` or `Sources/SorrelUpdater/` (the updater), `tools/release.sh`, `tools/update-sign.swift`, anything in `vendor/`, anything in `.claude/`.

(Claude Code enforces those last three lists through `.claude/settings.json`. **If you are not Claude Code, nothing enforces them for you. Follow them by hand.**)

### 2.5 Rules for working with the owner

- **The owner decides what merges, what gets pushed and what gets published.** You may commit on your own task branch. You do **not** merge into `main`, push to GitHub, or publish a release unless the owner asks for that specific thing in this session. Approval for one step (e.g. "merge it") is **not** approval for the next (e.g. "push it").
- **The owner uses the Mac while you work.** Test windows must stay in the background (section 7). Warn before anything that will pop up a window or take focus.
- **Don't loop on things only the owner can see.** Hover feel, animation feel, drag and drop, real mouse behaviour, anything behind their sign-ins (Proton Pass signed in, their real tabs), macOS permission prompts on their screen. After **one or two** test rounds, stop and give them a **specific** check: what to click, what to look for, what to paste back. Say plainly which parts you verified and which are waiting on them.
- **After any rebuild of `~/sorrel`, tell the owner to quit and reopen Sorrel** to get the new build. Say it every time.
- **Report in plain, short language**: what changed, what you verified (and how), what you did not verify, what the owner needs to do. No walls of test output.

---

## 3. Working in parallel: worktrees (mandatory)

The owner often runs several AI sessions at the same time. **Two sessions must never edit the same folder**: one session's half-finished edit breaks the other's build. This happened twice.

- `~/sorrel` holds the `main` branch **and** the owner's running app (`build/Sorrel.app`). **Do not do feature or bug work directly in `~/sorrel`.**
- Every task gets **its own git worktree and branch**.

### 3.1 Start of every session (do all of these, in order)

```sh
cd ~/sorrel
git worktree list        # what other work is in flight, and where
git status -sb           # is main clean? how far ahead of origin?
git log --oneline -10    # what landed recently
```

Then read `BUGS.md` and `PROGRESS.md`, and the `CLAUDE.md` sections for the area you'll touch.

### 3.2 Start a task

Pick a short kebab-case task name, e.g. `find-bar-count`. Check it isn't already a branch (`git branch -a`).

```sh
cd ~/sorrel
git worktree add ../sorrel-find-bar-count -b find-bar-count
cd ../sorrel-find-bar-count
./build.sh        # OK here: this worktree's build/ is its own. First build takes a few minutes.
```

From now on, **edit, build and test only inside that worktree folder.**

### 3.3 Finish a task (before you say "done")

1. `swift build` passes in the worktree (and no new warnings: section 8).
2. Commit on the task branch (see 3.4 for the message format).
3. Merge the latest `main` into your branch: `git merge main`. Resolve any conflict **in the worktree**, never in `~/sorrel`.
4. Rebuild in the worktree (`./build.sh`) and **rerun the tests that cover what you changed**.
5. Update `BUGS.md` / `PROGRESS.md` / the relevant `CLAUDE.md` section (edit only the section you changed) and commit that.
6. Tell the owner: branch name, worktree folder, what's verified, what needs them. **Do not merge into main** unless asked.

### 3.4 Commits

- Commit messages: one short line saying what changed in plain words (look at `git log` for the style, e.g. "Space icon row scrolls when spaces overflow").
- Commit only your own task's files. Never `git add -A` blindly: check `git status` first (watch for `.DS_Store`, scratch files, audit reports).

### 3.5 When the owner says "merge it"

```sh
cd ~/sorrel
git merge <task>                 # usually a fast-forward if you merged main first
```

Then **ask** whether to rebuild `~/sorrel` (rule 8: it deletes the running app). If yes: `./build.sh`, then tell the owner to quit and reopen Sorrel. Remove the worktree and branch only if the owner agrees:

```sh
git worktree remove ../sorrel-<task>
git branch -d <task>
```

Pushing (`git push`) is a **separate** go-ahead.

### 3.6 Collision hotspots (keep diffs small and local here)

Many tasks touch these files. Make the smallest possible change; don't reorder or reformat other code.

- `App.swift`: every test hook and every command. Add a new hook as **its own `if env["SORREL_…"] … { }` block**; never reshuffle others.
- `Web.swift`, `SettingsWindow.swift`, `Sidebar.swift`.
- `Support.swift`: each new setting needs **a field AND a decoder line** (recipe in section 9).
- `CLAUDE.md`: edit only the section you are changing.

---

## 4. Current state (snapshot as of 2026-11-16, verify with git before trusting)

This section goes stale. Always confirm with `git worktree list`, `git log` and `git status`.

### 4.1 Branches and releases

- `main` and `origin/main` are in step as of 2026-11-16 (pushed at the owner's request, after the 0.2.3 release commit).
- **Latest published release: v0.2.3 (build 5)**, published 2026-11-16, cut from `main` in `~/sorrel-release-0.2.3` (branch `release-0.2.3`, local only; the temporary remote branch was deleted). It is the first release with the working updater (open files instead of paths) and the sidebar update card. `tools/update-test.sh` passed on that exact build before publishing. Before it: v0.2.0 (build 2).
- **v0.2.1 (build 3)** and **v0.2.2 (build 4)** were cut locally (worktrees `~/sorrel-release`, `~/sorrel-release-0.2.2`; tags local only) and **never published. Never publish them**: 0.2.3 supersedes both. The next release will be build 6.
- **Copies on 0.2.0 most likely cannot install updates themselves** (old updater service). The 0.2.3 release notes tell those users to download it by hand once. From 0.2.3 on, updates should install by themselves.
- **0.2.3 is signed ad-hoc** (the self-signed identity didn't exist yet), so macOS asks again for Downloads/camera/mic/location after each update until the identity is created and used for a release.

### 4.2 Worktrees that exist

| Folder | Branch | State |
|---|---|---|
| `~/sorrel` | `main` | The owner's copy. Don't work here. |
| `~/sorrel-sync` | `sync` | **Active, not merged.** Tab sync, rounds 1-2 of 4 done (section 5.2). |
| `~/sorrel-sidebar-player` | `sidebar-player` | Sidebar mini player: play/pause, tab audio mute, source selection. Not merged; owner music-site/feel check pending. |
| `~/sorrel-release`, `~/sorrel-release-0.2.2` | `release-0.2.1`, `release-0.2.2` | Unpublished, superseded releases. Don't publish. Remove only when the owner says. |
| `~/sorrel-gap-audit` | `feature-gap-audit` | Holds an untracked `GAPS.md` (feature gap list, 2026-11-15). Useful as an idea list; parts are already done (see 5.3). Don't commit it. |
| `~/sorrel-sandbox`, `~/sorrel-security-audit`, `~/sorrel-downloads`, `~/sorrel-claude-setup` | various | Already merged. Kept until the owner says to remove them. `sorrel-security-audit` holds the git-excluded `SECURITY-AUDIT.md`. |

### 4.3 Recent important facts

- **Updater fix (2026-11-16):** macOS's app-data protection (TCC `SystemPolicyAppDataDetailed`) blocks the unsandboxed updater service from any path inside the app's container. So the app now opens the zip and log itself and passes them to the service as `FileHandle`s. Real installs were most likely always refused before this.
- **Signing identity not created yet.** `build.sh` signs with a self-signed identity from `~/.config/sorrel/signing.keychain-db` if it exists; it **does not exist yet**, so builds are signed ad-hoc, and macOS re-asks for Downloads/camera/mic/location permission after every rebuild or update. The fix is for the **owner** to run `tools/make-signing-identity.sh` (an agent's attempt was blocked by the permission system). Don't run it yourself without the owner's explicit go-ahead in this session. After it exists: owner quits Sorrel, `./build.sh`, one last permission prompt.
- **Proton Pass pop-up is fixed** (owner confirmed 2026-11-16, "It works!"). Cause was pop-up sizing (`applyDeclaredSize` set only `min-height`).
- **`PROGRESS.md` on `main` is out of date in two places**: it still says Proton Pass is broken (fixed, see `BUGS.md` ▸ Fixed) and that browser import is unmerged (it is merged). If your task touches `PROGRESS.md`, correct those lines.
- **`BUGS.md` ▸ Open is empty.** Fixed items with causes are listed there.
- `CLAUDE.md` ▸ "Known gaps" still lists location as missing; website location was added 2026-11-16 (it's in the Security behaviour section).

### 4.4 Waiting on the owner (don't try to verify these yourself)

- The **feel** of: fluid motion, space swipe ("feels good" confirmed), space icon row scrolling, download flight, command bar typing, Arc-style colours/grain, the update card in their real sidebar, the import card motion.
- Real Open-panel "Allow" flow for browser import; Safari's folder access.
- Website location on Top Hat (the owner's attendance site) by hand.
- A clicked download starting without a prompt; the extension-update prompt's wording.
- The iPhone sync app on their real phone.

---

## 5. Goals and roadmap

### 5.1 Overall goals, in priority order

1. **Be a dependable daily browser.** Nothing the owner does every day should break: tabs, spaces, sign-ins, Proton Pass autofill, downloads, updates.
2. **Private and secure** at least to Helium's level, without sacrificing (1). The owner said losing some ad blocking would be acceptable for Proton Pass, but nothing was sacrificed, and they want it "as private and secure as Helium".
3. **Feel like Arc**: smooth, fluid, Arc's interactions.
4. **Stay free** and low-maintenance.
5. **Be releasable to others** (open source, Zen-style): generic first run (done: one "Home" space + welcome page), README, working self-updates.

### 5.2 Tab sync (branch `sync`, in `~/sorrel-sync`, not merged)

Arc-style sync across the owner's Macs and iPhone, free, **end-to-end encrypted** with a sync password, through a **relay on Cloudflare's free tier** (`sync-relay/`: a Worker + one SQLite Durable Object per sync). The iPhone side is a **read-only PWA** served by the relay. Full details: the "Tab sync" section of `~/sorrel-sync/CLAUDE.md` and `docs/sync-format.md` there.

- Round 1 (done): engine (`SyncModel.swift`, per-field last-writer-wins with a hybrid logical clock), `Sync.swift`, Settings ▸ Sync. It **sends and shows but never changes the sidebar.**
- Round 2 (done): relay deployed online with the owner's existing Wrangler login (from their Stint project). The owner confirmed Start Syncing works on their Mac. iPhone app not yet confirmed.
- **Round 3 (next):** apply the merged replica to the sidebar (`Store`) live, add "undo last sync", and de-duplicate identical pages when a second Mac with imported tabs joins (different UUIDs, same URLs).
- Round 4 (optional): send tabs from the phone, pin/close from the phone, history.
- The relay is the **one approved exception to rule 2**, and only when sync is on. The relay address and house key are in `~/.config/sorrel/` and must **never** go into the public repo. Tests against the live relay must erase what they create. **Deploying the relay** is outward-facing: ask first.

### 5.3 Candidate work (not started; get the owner's choice before starting any)

From `~/sorrel-gap-audit/GAPS.md` and `CLAUDE.md` ▸ Known gaps. Already done since that list: Arc import, History window (⌘Y) with search and per-entry delete, Clear Browsing Data with time range, website location.

- **Second main window (⌘N)**: only one main window exists.
- Site info panel (click the lock): certificate details, see/revoke camera/mic, per-site data, blocking toggle.
- Screen sharing in web meetings (`getDisplayMedia`), untested.
- Link hover status bubble (needs a private WebKit delegate).
- Per-tab audio indicator and mute.
- Share / AirDrop (`NSSharingServicePicker`).
- Find bar match count, ⌘G / ⇧⌘G.
- Back/forward history menu; drag links/files onto the window; File ▸ Open File.
- Pop-up blocked notice with "allow for this site"; autoplay control; reader mode (bundled Readability.js, local); on-device translate (Apple Translation framework).
- Global Privacy Control; per-site JavaScript off; clear-on-quit for non-pinned sites.
- **Known impossible or blocked:** passkeys/WebAuthn (needs Apple's paid restricted entitlement); Web Bluetooth (doesn't exist in WebKit); Safari version of Proton Pass (needs its companion app); a built-in password manager (would need a page-to-app bridge, rule 4).

Check each candidate against the hard rules before proposing it, and tell the owner which rule it would touch.

---

## 6. Bug workflow (follow every step)

1. **Write it down.** Find the bug in `BUGS.md` ▸ Open, or add it there: **Repro** (steps), **Expected**, **Actual**.
2. **Make a worktree** for it (section 3.2). One bug per session where possible.
3. **Reproduce it first**, with `SorrelTest.app` and the test hooks (section 7) or a written repro. If you can't reproduce it, **say so** to the owner. Do not "fix" something you haven't seen fail unless the owner agrees.
4. **Find the root cause.** Read the code path. Add temporary logging if needed (remove it after). Don't guess-and-patch.
5. **Fix the root cause with the smallest change that works.** Don't refactor around it.
6. **Verify:** `swift build` passes with no new warnings; the repro now behaves correctly; nearby features still work (run their hooks too).
7. **Record it:** move the entry to `BUGS.md` ▸ Fixed with a one-line **Cause** and what fixed it. Put anything unfinished in `PROGRESS.md`.
8. **Report** to the owner (section 2.5 style). If the bug only shows in their profile or by feel, hand them a specific check.

**When a bug only shows in the owner's real profile** (as happened with Proton Pass): a temporary on-device diagnostics output that records **layout/state facts only, never page text or personal data**, which you read yourself, worked better than asking the owner to use Web Inspector. Remove it afterwards. If the owner is running a build from your worktree, put test builds in a separate folder (e.g. `build-fix/`) so you don't delete the app they're running.

**If the owner says to stop working on a bug, stop.** Record what you know in `BUGS.md` and don't attempt further fixes.

---

## 7. Building and testing

### 7.1 Tools available

- **Only Apple's Command Line Tools are installed, not Xcode.** Don't use `xcodebuild`. There is no `.xcodeproj`. It's a SwiftPM package (`Package.swift`) wrapped into an app bundle by `build.sh`.
- `gh` and Homebrew are **not** installed.
- Minimum macOS is **15.4** (needed for `WKWebExtension`). Apple Silicon only.

### 7.2 Commands

| Purpose | Command | Where it's allowed |
|---|---|---|
| Fast compile check (debug) | `swift build` | Anywhere |
| Release compile check | `swift build -c release` | Anywhere |
| Build both apps into `build/` | `./build.sh` | **Task worktrees only.** In `~/sorrel`: ask first |
| Build and open | `./build.sh run` | Never (opens the real app) unless the owner asks |
| Build and install to /Applications | `./build.sh install` | Only when the owner asks |
| Updater end-to-end test | `tools/update-test.sh` | Task worktrees |

`./build.sh` makes **two apps from one compile**:
- `build/Sorrel.app`: the real browser (bundle id `app.sorrel.browser`). **You never launch this.**
- `build/SorrelTest.app`: for tests only (bundle id `app.sorrel.browser.test`, its own container and site data, may write to `/private/tmp`). **This is the only app you launch.**

### 7.3 How tests work

There is **no XCTest target**. Tests are the app itself, driven by `SORREL_*` environment variables read in `App.swift` (`runDebugHooks`, plus some in other files). Each hook does something, logs lines to stderr with a fixed prefix (e.g. `swipe:`, `dl:`, `clean:`, `updater:`), optionally writes PNGs, and the app quits itself after `SORREL_DELAY` seconds.

The basic pattern (copy it exactly, change only the hook variables):

```sh
S=$(mktemp -d /private/tmp/sorrel-test.XXXXXX); mkdir "$S/p1"
SORREL_HOME="$S/p1" SORREL_SNAPSHOT="$S/shot.png" SORREL_DELAY=8 \
SORREL_OPEN=https://example.com \
build/SorrelTest.app/Contents/MacOS/Sorrel 2>&1 | grep -E '^(selected|hover|peek|ext|ui|diag|autofill):?'
```

Rules for every test run:

1. **Always** set `SORREL_HOME` to a **fresh** folder made with `mktemp -d /private/tmp/sorrel-test.XXXXXX`. It **must** be under `/private/tmp` (the only place the sandboxed test build can write). Make a new one each run; don't reuse or delete old ones.
2. **Always** set `SORREL_SNAPSHOT=<path>.png`. This turns on **quiet test mode**: window opens behind others, no focus, no Dock icon. Without it, hooks don't run at all. Never set `SORREL_LOUD=1` (it makes the window take focus) unless the owner asks.
3. **Always** run `build/SorrelTest.app/Contents/MacOS/Sorrel`, never `Sorrel.app`.
4. **Batch checks** into as few launches as possible. Every launch shows a window on the owner's screen. Tell the owner beforehand that test windows will appear briefly and use a throwaway profile, not their tabs.
5. **Never leave a test instance running** after your command ends. Hooks quit by themselves after `SORREL_DELAY`; if a run hangs, kill only that test process (by PID), never `Sorrel.app`.
6. Pipe output through `grep` for the hook's prefix so results stay short.

### 7.4 Things tests cannot show (don't keep trying)

- **Page pixels:** under the sandbox, `SORREL_SNAPSHOT` shows the web area **blank**. Use `SORREL_WEBSNAPSHOT=<png>` for WebKit's own picture of the page.
- **Fade-ins:** test pages are `visibilityState: hidden`, so CSS fade-ins never run and screenshots can look blank. Check text with `SORREL_EVAL='document.body.innerText'` instead of pixels.
- **Location prompt:** WebKit holds hidden pages' location requests; the owner must try it by hand.
- **Real mouse feel, drag and drop, hover timing, anything signed in.** Ask the owner.
- `screencapture` doesn't work from inside the sandboxed app.

### 7.5 Most useful hooks (full list with options: `CLAUDE.md` ▸ Testing)

| Variable | What it does |
|---|---|
| `SORREL_OPEN=<url>` | Open a tab |
| `SORREL_RUN=cmd.id,cmd.id` | Run commands by id (ids from `Commands.shared.register` in `App.swift`) |
| `SORREL_SIDEBAR=hidden\|peek` | Set the sidebar mode |
| `SORREL_COMMAND=<text>` | Type into the ⌘T bar |
| `SORREL_EVAL=<js>` / `SORREL_EVALASYNC=<body>` | Run JavaScript in the page; logs `eval:` / `evalasync:` |
| `SORREL_WEBSNAPSHOT=<png>` | Picture of the page itself |
| `SORREL_DOWNLOADS=<dir>` | Downloads go to a scratch folder |
| `SORREL_FEATURETEST`, `SORREL_DAILYTEST` | Broad smoke tests (shortcuts, archive, private; sleep, downloads, history) |
| `SORREL_SECTEST`, `SORREL_SECTEST2` | Security behaviour (HTTPS-first, warnings, private ⌘-click, data:, dialogs, downloads) |
| `SORREL_PEEKTEST`, `SORREL_HOVERTEST`, `SORREL_SPLITTEST`, `SORREL_SWIPETEST`, `SORREL_SPACEROWTEST`, `SORREL_TYPETEST`, `SORREL_THEMETEST`, `SORREL_CLEANTEST`, `SORREL_FLIGHTTEST`, `SORREL_DOWNLOADTEST`, `SORREL_IMPORTTEST`, `SORREL_GEOTEST` | Feature-specific end-to-end checks |
| `SORREL_EXTTEST=1\|ui\|protonpass`, `SORREL_EXTDIAG=<id part>` | Extensions; passive diagnostics |
| `SORREL_UPDATETEST=…` + `SORREL_UPDATE_FEED=file:///…` | The updater (or just run `tools/update-test.sh`) |

**When you change a feature, find its hook in `CLAUDE.md` ▸ Testing and run it before and after.** If a feature has no hook and you need one, add it (recipe 9.3).

### 7.6 Extension testing rules

- To test an extension the owner added, **copy it** from a profile's `Extensions/` into your scratch profile. Never run tests against the real profile. (Ask the owner before reading anything from their real profile.)
- **Never download from the Chrome Web Store in tests.** The code refuses (with `SORREL_HOME` set, store/uBOL update checks don't run). Use local `.crx` files via `SORREL_CRX_DIR`.
- A tiny **echo extension** (manifest + a one-line background that answers messages) is the fastest way to tell a WebKit limit from an extension quirk.

---

## 8. Compile warnings baseline

Measured on a clean release build of `main` at 750aaf2 (2026-11-16):

- **2 distinct Swift source warnings** (this is the baseline that matters):
  - `Extensions.swift:687`: `'weak' ownership of capture 'self' differs from implicitly-captured strong reference`
  - `MainWindow.swift:479`: `'showsBaselineSeparator' was deprecated in macOS 15.0`
- **5 linker lines** `ld: warning: search path '/Library/Developer/CommandLineTools/…' not found`. These come from the Command Line Tools install, not from the code. Ignore them.

`CLAUDE.md` rule 6 says "9 known warnings". That number is out of date: a plain `grep -c "warning:"` happens to print 9 because the compiler repeats each warning's text in its code excerpt. **Don't use that count.** Count distinct source warnings like this, in a fresh scratch folder so nothing is cached:

```sh
swift build -c release --scratch-path /private/tmp/sorrel-warncheck 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -E '^/.*\.swift:[0-9]+:[0-9]+: warning:' | sort -u
```

Your branch must not list more source warnings than `main` does. A clean build takes about 40 seconds to a few minutes.

---

## 9. Recipes (exact steps for common changes)

### 9.1 Add a user setting

Example: a Bool `fooEnabled`, default `false`.

1. `Sources/Sorrel/Support.swift`, in `struct Settings`: add the field **with a doc comment** saying what it does and why the default is what it is:
   ```swift
   /// Does X. Off by default: <reason>.
   var fooEnabled = false
   ```
2. In the same file, inside `init(from decoder:)`, add the decoder line (**without this, the setting resets on every launch for anyone whose settings.json lacks it**):
   ```swift
   fooEnabled = try c.decodeIfPresent(Bool.self, forKey: .fooEnabled) ?? d.fooEnabled
   ```
3. Read it in code as `Settings.current.fooEnabled`.
4. If it should appear in Settings: `SettingsWindow.swift`, in the right tab's section, copy an existing checkbox, e.g.
   ```swift
   checkbox("Do X", s.fooEnabled) { [weak self] on in self?.mutate { $0.fooEnabled = on } }
   ```
5. **Privacy check:** a new setting that loosens privacy or security must default to the private/safe value.

### 9.2 Add a command (and optionally a shortcut and menu item)

1. `App.swift`, where the other `c.register(...)` calls are (around line 200): `c.register("area.verb", "Title Shown in Command Bar") { [unowned self] in … }`. Command ids look like `tab.reload`, `space.next`, `history.show`.
2. Default shortcut (optional): `Commands.swift`, `Keybindings.defaults`, add `("cmd+shift+x", "area.verb")`. **Check the key isn't already used** (search the list, and note extensions' shortcuts lose to Sorrel's). Chords are written with a space: `"cmd+k cmd+t"`.
3. Menu item (optional): in `App.swift`'s menu building, `menu.addItem(item("area.verb"))` in the right menu.
4. Test with `SORREL_RUN=area.verb`.

### 9.3 Add a test hook

1. In `App.swift` ▸ `runDebugHooks()`, add a **new, separate** block. Don't edit or reorder other blocks:
   ```swift
   if env["SORREL_FOOTEST"] != nil {
       // What this checks, and what it can't check.
       …
       log("foo: step=… expected=… got=…")
   }
   ```
2. Log lines start with a **unique short prefix** (`foo:`) and print **expected and actual values side by side** so the result can be read from grep output.
3. Never log page text, titles, URLs from imports, or anything personal. Counts and layout numbers only.
4. Never make the hook answer "yes" to a permission (that would show a macOS prompt on the owner's screen).
5. Document it in `CLAUDE.md` ▸ Testing (one entry in the list).

### 9.4 Add an animation

Use the shared helpers in `Support.swift` (`Motion`): `settle` (arriving), `leave` (going), `glide` (state change); `Motion.run`, `Motion.layer`, `CALayer.popIn/popOut/press`, `NSView.fade(in:)`. **Don't invent ad-hoc durations or flip `isHidden` directly.** Respect Reduce Motion (drop movement, keep fades). The owner judges the feel: hand it to them.

### 9.5 Change ChromeCompat (extension compatibility shim)

- It must only **add** things (inert stand-ins, polyfills, pinning globals).
- **Never wrap or Proxy the extension API, and never reassign `sendMessage` / `addListener`, not even for tracing.** Message delivery silently stops.
- **Bump `ChromeCompat.version`** so installed copies re-patch.
- Test with a fresh profile and the real loader (diagnostic code in the loader has hidden crashes before).

### 9.6 Content blocking

- **Never call `removeAllContentRuleLists()`** on a page's content controller. It wipes uBlock Origin Lite's rules too. Remove only Sorrel's own lists by name.
- Built-in lists cover private windows and the first ~25 s after launch; then uBOL takes over (`blockerInCharge`).

### 9.7 Cut a release (ONLY when the owner asks)

1. Make a worktree from current `main` (never cut in `~/sorrel`: `build.sh` deletes the running app): `git worktree add ../sorrel-release-<ver> -b release-<ver>`.
2. In it: `tools/release.sh <version>` (e.g. `0.2.3`). It bumps the version and build number, builds, signs the zip with `~/.config/sorrel/update-signing-key`, writes `dist/`, commits and tags.
3. **Rewrite `dist/notes.md` by hand** in user-facing language. The auto notes list every internal commit. Include the "Open Anyway" first-launch note, and (for the next release) that 0.2.0 users need one manual download.
4. Fast-forward `main` to the release commit (so the next build number goes up) **only if the owner agrees**.
5. **Publishing (`tools/release.sh publish`) needs a separate, explicit go-ahead.** It reaches every installed copy. It pushes the current branch, so afterwards delete the temporary remote release branch (ask first).
6. Build numbers must only ever go up. Downgrades are refused by every copy.

---

## 10. Map of the code

All app code is in `Sources/Sorrel/`. Biggest files: `Sidebar.swift` (~2400 lines), `App.swift` (~2000), `Extensions.swift`, `ImportView.swift`, `Web.swift`, `Models.swift`.

| File | What's in it |
|---|---|
| `main.swift` | Entry point. Runs the sandbox migration, drops `SORREL_*` vars in the real app, re-execs once with `MallocSpaceEfficient=1`, test-mode activation policy |
| `App.swift` | `AppDelegate`: command registrations, menus, engine wiring, quit handling, **all test hooks** (`runDebugHooks`) |
| `Support.swift` | `Settings` (settings.json), `Theme`, `Paths`, `Sandbox.realHome`/`Sandbox.downloads`, `isQuietTest`, `Motion`, small helpers |
| `Models.swift` | `Item` (tab/folder/split), `Space`, `Store` (state.json): tabs, pinning, archive, tab sleeping |
| `Data.swift` | Favicons, `History`, `ZoomStore`, `Bangs`, `Resolver` (typed text -> URL), `URLCleaner` (strips tracking params) |
| `Web.swift` | `Page` (one `WKWebView`), `Engine` (navigation/UI delegate, downloads, Peek decisions, user agent, HTTPS-first, permissions) |
| `Commands.swift` | `Commands` registry, `Keybindings` (keybindings.json, chords) |
| `MainWindow.swift` | Main window, sidebar modes (`pinned`/`hidden`/`peeking`), hover logic, Peek host, `ContentCard` (split layout) |
| `Sidebar.swift` | Sidebar outline, favorites grid, address pill with extension icons, space bar |
| `SpaceSwipe.swift` | Swiping between spaces; space icon row scrolling |
| `CommandBar.swift` | ⌘T bar and ⌘L in-place editor, suggestions |
| `Peek.swift` | Link preview overlay; `Site` helpers (host display) |
| `Split.swift` | Split view panes and divider |
| `MiniWindow.swift` | Mini windows and private windows |
| `Downloads.swift`, `DownloadFlight.swift`, `Library.swift` | Downloads UI, the flying icon, Library (Downloads/History/Archive) |
| `Cleanup.swift`, `ClearDataPanel.swift` | Clearing data, Forget This Site, sizes, Free Up Memory |
| `Importer.swift`, `ImportView.swift` | Browser import (readers + UI card) |
| `ThemeEditor.swift`, `ThemeLook.swift`, `EmojiPicker.swift` | Customize Space popover, OKLab colours/grain, emoji sheet |
| `SettingsWindow.swift` | Settings tabs: General, Privacy, Memory & Storage, Extensions, Tabs, Sidebar, Shortcuts |
| `Blocker.swift` | EasyList/EasyPrivacy -> WebKit content rule lists |
| `Extensions.swift` | `WKWebExtension` host: loading, tab/window adapters, pop-ups, Chrome Web Store installs/updates, uBOL updates, background wake-ups |
| `ChromeCompat.swift` | Script injected into Chrome-store extensions so they run on WebKit |
| `Migration.swift` | One-time copy of the pre-sandbox profile into the container (already ran for the owner) |
| `Updater.swift`, `UpdateCard.swift` | Update checks/downloads/verification; the sidebar "update ready" card |
| `Sources/SorrelUpdateCore/` | Shared by app and updater: config (repo, feed, **public key**), manifest, Ed25519 verify, XPC protocol. **Ask before editing.** |
| `Sources/SorrelUpdater/` | Unsandboxed XPC service that swaps the app bundle. **Ask before editing.** |
| `Resources/` | `Info.plist`, `Sorrel.entitlements`, `welcome.html` (`sorrel://welcome`), `bangs.json`, `emoji.tsv`, icon |
| `vendor/` | uBlock Origin Lite, Kagi bangs. **Don't edit.** |
| `tools/` | `release.sh`, `update-sign.swift`, `update-test.sh`, `make-signing-identity.sh`, `make-icon.swift`, `make-emoji-list.py` |

**User data files** (per profile folder): `state.json` (spaces/tabs), `settings.json`, `keybindings.json`, `bangs.json`, `history.json`, `downloads.json`, `archive.json`, `zoom.json`, `blocker.json` + `rulelists/`, `Extensions/`, `BundledExtensions/`, `Updates/`. Any change to the shape of these must still **load old files** (use `decodeIfPresent` with defaults; make new fields optional).

**Sandbox paths:** inside the app, `NSHomeDirectory()` and `~/Library` lookups point at the **container**, not the real home. Use `Sandbox.realHome` / `Sandbox.downloads` when you mean the person's real folders.

---

## 11. Pitfalls that already cost hours (don't repeat them)

1. **WebKit crashes (SIGKILL) if an extension's files sit inside the app bundle.** That's why bundled uBOL is unpacked to `BundledExtensions/` in the profile.
2. **`removeAllContentRuleLists()` wipes the extension's rules.** Never call it.
3. **Wrapping/Proxying the extension API or reassigning `sendMessage`/`addListener` silently breaks message delivery.** Diagnose passively (`SORREL_EXTDIAG`).
4. **WebKit unloads idle extension backgrounds after 30 s**, and a pop-up or extension page that restarts a service-worker background gets a broken worker. Sorrel wakes the background first (`Extensions.wakeBackground`). Keep that.
5. **Pop-up sizing:** Chrome pop-ups with a fixed size need real `width/height` **and** `min-width/min-height` on html and body (`applyDeclaredSize`). Minimums alone collapse `height:100%` layouts.
6. **Memory:** measure with `footprint -p <pid>`, not resident size (WebKit's reclaimable pages read 1 GB+). `MallocSpaceEfficient=1` is what keeps uBOL's fragmentation down; `malloc_zone_pressure_relief`, `MallocAggressiveMadvise` and trimming uBOL rule sets did **not** help.
7. **Under the sandbox, per-process memory of WebKit's web processes can't be read** (`proc_pid_rusage` gives EPERM). Use Mac-wide numbers.
8. **The updater XPC service inherits part of the app's environment**: its Foundation home is the app's container (use `getpwuid` for the real home), and `SORREL_*` variables don't reach it. It cannot touch paths in the app's container (TCC), so it gets open files.
9. **TCC (macOS permissions) are tied to the signature.** Ad-hoc signing = new identity every build = re-prompt every build. The self-signed identity fixes it.
10. **Main-queue blocks don't run during "terminate later"**; answer through `RunLoop.main.perform`.
11. **Plain `Timer`s pause during menus and drags**; use common run-loop mode when they must keep running.
12. **User agent version** must be Safari's real version, not macOS's (macOS 26 even reports "16.x" to apps built against the 15.4 SDK).
13. **Test windows are "hidden" to WebKit**: no animations, no location prompts, blank fades. Don't mistake that for a bug.
14. **Name checks:** many nature names are taken by new Arc replacements (Wren, Cove, Lagoon, Tern, Fern, Flow, Breeze, Moss). Check before suggesting names for anything public.

---

## 12. Self-check before you report "done"

Go through every line. If any answer is "no" or "not sure", fix it or tell the owner.

- [ ] I worked in my own worktree, not `~/sorrel`.
- [ ] `swift build` passes. Release warnings are not above the baseline.
- [ ] I reproduced the problem before fixing it (or told the owner I couldn't).
- [ ] I ran the hooks covering what I changed, with a fresh `SORREL_HOME` under `/private/tmp`, in `SorrelTest.app`, in quiet mode. No test instance is still running.
- [ ] I didn't launch `Sorrel.app`, read the owner's profile, or print anything from `~/.config/sorrel`.
- [ ] No new entitlement, network call, telemetry, script message handler, permission auto-grant, or JavaScript built by pasting strings.
- [ ] Settings changes have both the field and the decoder line; old data files still load.
- [ ] I scanned my diff for the risky patterns below (the Claude Code security hook does this automatically; other agents must do it by hand):
  ```sh
  git diff main -- . ':!*.md' | grep '^+' | grep -nE 'NSAllowsArbitraryLoads|NSExceptionAllowsInsecureHTTPLoads|URLCredential\s*\(\s*trust:|SecTrustSetExceptions|serverTrust|addScriptMessageHandler|WKScriptMessageHandler|allowFileAccessFromFileURLs|allowUniversalAccessFromFileURLs|allowingReadAccessTo|WKWebsiteDataStore\s*\.\s*default\s*\(|isFraudulentWebsiteWarningEnabled\s*=\s*false|javaScriptCanOpenWindowsAutomatically\s*=\s*true|\.grant\b|removeAllContentRuleLists|removeContentRuleList|URLSession|URLRequest\s*\(|sorrel-insecure|temporary-exception|files\.all|network\.server|cs\.allow-jit|disable-library-validation|get-task-allow'
  ```
  Every hit must be justified against section 2. **List every hit in your report to the owner** so they can review it.
- [ ] Committed on my branch; merged `main` in; rebuilt and retested after the merge.
- [ ] Updated `BUGS.md` / `PROGRESS.md` / the right `CLAUDE.md` section (and section 4 of this file if the state changed).
- [ ] Nothing committed contains secrets or personal data (the repo is public).
- [ ] I did not merge to `main`, push, publish or deploy without the owner asking for that exact step.
- [ ] My report says: what changed, what's verified and how, what's not verified, what the owner should try, and (if `~/sorrel` was rebuilt) "quit and reopen Sorrel".

---

## 13. When in doubt

- **Ask the owner** before: anything in section 2.4's ask lists; any new entitlement, network call or permission; anything that costs money; any merge, push, publish or deploy; deleting anything that isn't your own scratch file; starting a feature they haven't chosen.
- **Don't ask** about things you can find out yourself by reading the code, `CLAUDE.md`, `BUGS.md` or git history.
- **If you're stuck after two honest attempts**, stop, write down what you tried and what you learned in `BUGS.md` / `PROGRESS.md`, and tell the owner. A clear "here's where it stands" is better than a third guess.
