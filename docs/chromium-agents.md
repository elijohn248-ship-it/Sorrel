# Birch Chromium edition: agent plan and prompts

Written 2026-11-23 for the owner to paste into Claude Code sessions. It carries out `docs/dual-engine-plan.md` with one change of order the owner asked for on 2026-11-23: **the Chromium edition targets Windows first, then Linux.** The Mac keeps its WebKit edition; a Mac Chromium build is not needed for now.

## How many agents

**11 agent sessions in 5 waves. At most 4 run at once.** More would not be faster: in waves 2–5 they all work in one new codebase, and the slow parts are the engine gate and your checks on Windows, not typing code.

| Wave | Agents (run together) | Starts when |
|---|---|---|
| 1. Prove it | 1 CEF prototype · 2 Qt WebEngine prototype · 3 Shared spec | You have done "Before wave 1" below |
| 2. Foundation | 4 App shell on the chosen engine | You picked an engine from reports 1 and 2 |
| 3. Features | 5 Spaces & sidebar · 6 Command bar & shortcuts · 7 Privacy & extensions · 8 Peek, splits, downloads, Library | Agent 4's branch is merged |
| 4. Windows release | 9 Installer, updater, release script · 10 Security audit | Wave 3 is merged and you tried a Windows build |
| 5. Linux | 11 Linux packaging and release | Agent 9's branch is merged |

Waves 1 and 3 are the parallel ones. If a prototype fails its gate (section "Gates" in prompt 1), stop there: that is the plan's stop condition, not a reason to drop protections.

## Before wave 1 (owner)

1. **Merge `dual-engine-plan` into `main`** (it holds this file and the rule change from "WebKit only" to two editions). Without it, agents starting from `main` will refuse Chromium work.
2. **Decide how Windows and Linux builds get compiled.** This Mac can't compile or run Windows programs. Recommended: **GitHub Actions** (free for public repositories, has Windows and Linux machines). That means agents push their task branch to the public `origin` to run the build. The prompts below allow exactly that and nothing more (no releases, no `main`). If you'd rather not, say so and the agents will stop and ask.
3. **Tell agents if you have a Windows PC** (or a free Windows virtual machine, e.g. UTM). Automatic checks run in CI; feel, sign-ins and the installer need you on a real Windows machine.
4. **Proton Pass for testing:** agents 1, 2 and 7 will ask you for an unmodified copy of Proton Pass's Chrome package. The copy in Birch's profile was patched for WebKit and can't be used, and tests may not download from the Chrome Web Store.

## Things to know up front

- **One repository for everything.** The Chromium edition lives in the existing GitHub repository (`elijohn248-ship-it/Sorrel`) in its own `chromium/` folder, beside the Mac app. Its Windows and Linux downloads go on the same Releases page as the Mac zip and disk image, each with its own file names and update feed.

- **No paid code signing.** Windows will show "Windows protected your PC" on first run (More info ▸ Run anyway), like Gatekeeper's Open Anyway on the Mac. A free option for open-source projects (SignPath Foundation) exists; agent 9 may propose it, you decide.
- **Video codecs:** ready-made CEF and Qt WebEngine builds leave out H.264/AAC and have no Widevine (Netflix-style DRM). Most of YouTube works; some sites won't. The prototypes must report this.
- **Updates must never cross editions.** The Mac's `updates.json` must never offer a Windows build, and a Mac-only release must not break Windows updates. Agent 9 designs this; the update signing key stays on this Mac and never goes into CI.

## Shared rules (every agent reads these)

Every prompt below starts with "Follow `docs/chromium-agents.md` ▸ Shared rules". They are:

1. Read `AGENTS.md`, then `docs/dual-engine-plan.md`, `PROGRESS.md`, and the parts of `CLAUDE.md` your task touches. The stricter rule wins. If this file is missing from `main`, stop: the owner hasn't merged `dual-engine-plan`.
2. Start with `git worktree list` and `git status`. Work only in your own worktree: `cd ~/sorrel && git worktree add ../sorrel-<branch> -b <branch>` (branch name given in your prompt). Never edit, build or run `./build.sh` in `~/sorrel`.
3. New Chromium-edition code lives under `chromium/` (prototypes under `prototypes/<name>/`, shared spec under `spec/`). Don't change the Mac app (`Sources/`, `Resources/`, `build.sh`, `Package.swift`, `tools/release.sh`, the updater, `vendor/`) unless your prompt says so; agent 3 may add one test hook.
4. Security and privacy rules apply to every edition: AGENTS.md 2.2–2.4 and CLAUDE.md "Security invariants". In particular: no telemetry or new runtime network destinations (Chromium's own Google services must be switched off and proven off), private windows leave nothing on disk, permissions are never auto-granted, the address bar shows the real origin, blocking is on by default, updates install only with a verified signature, and no web page ever gets a bridge into the app. **Never ship or test with `--no-sandbox`** or any switch that disables Chromium's sandbox.
5. Dependencies (CEF, Qt, compilers, uBOL) are pinned to an exact version with a checksum, and their source and license are recorded in `chromium/THIRD_PARTY.md`. Downloaded binaries never go into git (add them to `.gitignore`). Don't install toolchains on this Mac or add Homebrew without asking the owner.
6. **CI:** you may add your own workflow file `.github/workflows/<branch>.yml` and push **your task branch only** to `origin` to run it (the repository is public: no secrets, keys, tokens, personal data or real-profile data in commits, logs or artifacts). Workflows must not publish releases, use repository secrets, or run on `main`. To read runs and artifacts, use the GitHub REST API with the token in `~/.config/sorrel/github-token` read-only; never print it. Never push `main`, tags or other branches.
7. Tests never touch a real profile. The Chromium edition takes its profile folder from `BIRCH_HOME` when set; every test sets it to a fresh scratch folder, and with it set, site data stays in memory. Test hooks are `BIRCH_*` environment variables (`BIRCH_HOME`, `BIRCH_OPEN`, `BIRCH_DELAY`, `BIRCH_SNAPSHOT`, plus your own), logging `<area>: expected=… got=…` lines, the same pattern as the Mac's `SORREL_*` hooks. On the owner's machine, test windows stay in the background.
8. Zero compiler warnings in Birch's own code (MSVC `/W4`, GCC/Clang `-Wall -Wextra`); record any third-party header warnings you can't avoid in `CLAUDE.md` ▸ Chromium edition.
9. Docs: keep a short **"Chromium edition"** section in `CLAUDE.md` (create it if missing; edit only your own subsection) and add your handoff line to the top of `PROGRESS.md`. Don't rewrite other sections.
10. Before saying done: commit on your branch, merge `main` into it, make CI green, rerun your checks, and report in plain words what was verified (and where: CI on Windows/Linux, or the owner) and what wasn't. **The owner decides merges**; don't merge into `main`. Stop and ask when a rule blocks you, rather than working around it.

---

## Wave 1

### Prompt 1: CEF prototype (branch `chromium-cef-proto`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: chromium-cef-proto. You are milestone 2 of docs/dual-engine-plan.md for CEF (Chromium Embedded Framework), Windows first, Linux second. Another agent is building the same prototype on Qt WebEngine at the same time; you'll be compared on the same gates, so be honest about failures.

Build a small throwaway browser in prototypes/cef/ (C++, CMake), compiled for Windows x64 and Linux x64 in GitHub Actions (.github/workflows/chromium-cef-proto.yml). Pin the latest CEF stable build from the official CEF automated builds (version + checksum in THIRD_PARTY.md, cached in CI). It is not the product: no sidebar polish, just enough window to test.

Gates (each gets PASS / FAIL / NOT TESTED with evidence, run in CI on Windows unless noted):
1. Two tabs, back/forward/reload, address bar showing the committed URL's real origin (a punycode lookalike shows as punycode), page teardown, a crashed renderer recovers to an error page.
2. Separate normal and private storage: a private window's cookies, cache and history are gone from disk after it closes (inspect the scratch folder).
3. A download into a scratch folder, with Windows' Mark of the Web (Zone.Identifier) set.
4. Sandbox: renderer/GPU processes run sandboxed on Windows (check the process command lines and Chromium's sandbox status page). Report what whole-app confinement exists or doesn't on Windows. Never use --no-sandbox.
5. Network: with BIRCH_HOME set, run against local fixtures only and record a NetLog (--log-net-log). The only connections allowed are to the local fixture server. List every Google/Chromium background service you had to switch off and how.
6. Permissions: camera/mic/location/notifications requests reach your code and are refused by default; nothing auto-granted.
7. HTTPS: a bad certificate shows an error, never loads silently.
8. Extensions: load uBlock Origin Lite's Chromium MV3 build (pinned upstream release, unmodified) and prove a known ad/tracker request is blocked. Then Proton Pass: ask the owner for an unmodified Chrome package (don't download from the Chrome Web Store, don't use the copy in Birch's profile). Report whether it loads, its pop-up opens, and whether Chrome Web Store installs are possible at all in CEF.
9. Interface: say how Birch's Arc-style sidebar would be built on CEF (CEF Views, native Win32/GTK, or HTML). If HTML, it needs a channel between Birch's own UI page and the app: that is rule 4 territory, so describe how it is kept unreachable from web content and flag it for the owner; don't build it without approval.
10. Codecs and DRM: which of H.264, AAC, VP9, AV1, Opus play; Widevine yes/no.
11. Linux: the same build compiles and gates 1, 2, 5 pass on ubuntu-latest (headless via Xvfb is fine). Note the Ubuntu 24.04 user-namespace/AppArmor sandbox issue and how it would be handled without disabling the sandbox.
12. Cost: download size, installed size, idle memory with one blank tab, CI build time, how often CEF ships security updates and what updating it takes.

Deliver prototypes/cef/REPORT.md with the gate table, evidence (log excerpts, not page content), licenses, and your recommendation. Put "Wave 1: CEF prototype" in PROGRESS.md. Don't merge.
```

### Prompt 2: Qt WebEngine prototype (branch `chromium-qt-proto`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: chromium-qt-proto. You are milestone 2 of docs/dual-engine-plan.md for Qt WebEngine (Chromium inside Qt), Windows first, Linux second. Another agent is building the same prototype on CEF at the same time; you'll be compared on the same gates, so be honest about failures.

Build a small throwaway browser in prototypes/qt/ (C++ with Qt Widgets or QML, CMake), compiled for Windows x64 and Linux x64 in GitHub Actions (.github/workflows/chromium-qt-proto.yml). Pin the newest Qt release whose WebEngine has the extension manager (6.10 or later), installed in CI with a pinned aqtinstall (versions + checksums in THIRD_PARTY.md, cached). Use Qt under the LGPL/GPL (Birch is GPL-3.0); no Qt account, no commercial licence. It is not the product: just enough window to test.

Run exactly the same 12 gates as the CEF prototype, word for word (copy them from docs/chromium-agents.md ▸ Prompt 1), with these Qt specifics:
- Gate 5: Qt WebEngine's Chromium flags via QTWEBENGINE_CHROMIUM_FLAGS; record the NetLog the same way.
- Gate 8: use QWebEngineExtensionManager for uBOL Lite (Chromium MV3 build, pinned upstream, unmodified) and Proton Pass (ask the owner for an unmodified package; no Chrome Web Store download, not the copy in Birch's profile). Note Qt documents no extensions in off-the-record profiles; say what that means for private windows.
- Gate 9: Qt draws the sidebar natively (QML or Widgets), so say how far Arc-style gradients, grain, hover reveal and smooth motion get you, with a screenshot from CI.
- Gate 12: also record which Chromium version this Qt release is based on and how quickly Qt ships Chromium security fixes compared with Chrome; an engine that lags months behind security fixes is a FAIL for gate 12.

Deliver prototypes/qt/REPORT.md with the gate table, evidence (log excerpts, not page content), licenses, and your recommendation. Put "Wave 1: Qt WebEngine prototype" in PROGRESS.md. Don't merge.
```

### Prompt 3: Shared spec and fixtures (branch `birch-spec`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: birch-spec. Goal: the Chromium edition (written in C++, possibly Qt) must behave like the Mac app without sharing its Swift code. You write the language-neutral specification and test fixtures it will be built and tested against, taken from the real Mac code. Read the Mac source; don't change its behaviour.

Write spec/ with one Markdown file per area plus JSON fixtures (input -> expected output):
1. Saved data: state.json (AppState, windows, spaces, items, folders, splits, favorites, theme), settings.json (every field, its default, and what an old file without it decodes to), keybindings (the defaults Birch writes to keybindings.default.json), archive.json, history.json, bangs.json. Mark which fields are portable between editions and which are WebKit-only (interactionState and other opaque engine state are never shared).
2. Typed text -> URL (Resolver), bangs (bundled + custom), URL cleaning (URLCleaner), address-box display (Site.display: leading www., long-host trimming, punycode), HTTPS-first rules (which hosts are upgraded, which never are).
3. Behaviour rules: tab sleep and archive timing (including memory-pressure intervals and Never), Peek decisions (which links open in Peek, excluded sites), split rules (2–4 panes, favorites never in splits, closing panes), Control+Tab recency, space colours (Theme.soften, gradient stops, grain, brightness) with numeric fixtures.
4. Security invariants as checkable statements, each with how a test would prove it in a Chromium edition.

Fixtures must come from the real Swift code, not from reading it by eye: add one test hook, SORREL_SPECDUMP=<scratch dir>, as its own `if env[...]` block in App.swift (see CLAUDE.md ▸ Working in parallel ▸ collision hotspots), that runs the real functions on your inputs and writes the JSON. Run it with build/SorrelTest.app in your worktree (./build.sh is fine there) and a fresh /private/tmp scratch SORREL_HOME. Verify: swift build and swift build -c release pass with no new warnings, and nearby hooks still pass (SORREL_TABRECENCYTEST=1, SORREL_BRIGHTNESSTEST=<dir>). The real profile is never read.

Add spec/README.md saying how an edition proves it matches (load each fixture, compare) and the version number of the spec. Put "Wave 1: shared spec" in PROGRESS.md. Don't merge.
```

---

## Wave 2

Before pasting prompt 4, read `prototypes/cef/REPORT.md` and `prototypes/qt/REPORT.md` (on their branches), pick one, and write it on the first line. Merge `birch-spec` first.

### Prompt 4: App shell on the chosen engine (branch `chromium-shell`)

```text
ENGINE: <owner writes CEF or Qt WebEngine here>

Follow docs/chromium-agents.md ▸ Shared rules. Your branch: chromium-shell. The owner picked the engine above after reading both prototype reports. If the line above is still a placeholder, stop and ask. Read that engine's REPORT.md (git show chromium-cef-proto:prototypes/cef/REPORT.md or chromium-qt-proto:prototypes/qt/REPORT.md) and spec/. Start chromium/ fresh: reuse what the prototype proved, not its throwaway code.

Build the foundation four other agents will work in at the same time after you, so the layout matters most:
1. chromium/ layout with clear modules and one owner each: core/ (spec model: spaces, items, windows, settings, persistence, all engine-free and UI-free), engine/ (the only code that touches CEF/Qt WebEngine), ui/ (windows, sidebar, controls), platform/ (Windows/Linux paths, file pickers, notifications), tests/. Write the module map into CLAUDE.md ▸ Chromium edition, with which wave-3 agent owns which folder.
2. core/ loads and saves state.json/settings.json per spec/ and passes every spec fixture it covers (a test runner that loads spec/ fixtures and prints expected/got).
3. A working browser: one window, a plain sidebar listing the current space's tabs, address bar showing the real origin, new/close/select tab, back/forward/reload, private window (non-persistent, nothing on disk after close), downloads to the user's Downloads folder with Mark of the Web, profile at %LOCALAPPDATA%\Birch (Windows) and ~/.local/share/birch (Linux), BIRCH_HOME for tests.
4. All the prototype's privacy settings carried over (Google services off, NetLog check against local fixtures only, sandbox on, permissions refused by default). Make the NetLog check a CI test that fails the build if anything but the fixture server is contacted.
5. CI (.github/workflows/chromium-shell.yml) builds and tests on windows-latest and ubuntu-latest and uploads a Windows zip as a CI artifact (not a release). Name: "Birch (Chromium) for Windows". Birch's existing birch-leaf icon from Resources/AppIcon.icns converted to .ico/.png at build time.

Report what CI verified on Windows and Linux, and give the owner one specific thing to try on a Windows machine (download the CI zip, unpack, run) and what to paste back. Don't merge.
```

---

## Wave 3 (paste all four after `chromium-shell` is merged)

### Prompt 5: Spaces, favorites and the sidebar (branch `cx-spaces-sidebar`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: cx-spaces-sidebar. You own chromium/ui/sidebar/ and the space/favorite/folder parts of chromium/core/ (see CLAUDE.md ▸ Chromium edition ▸ module map); three other agents work in chromium/ at the same time, so keep diffs elsewhere tiny.

Bring over, matching spec/ and the Mac behaviour described in CLAUDE.md ▸ How the pieces behave: spaces (name, emoji, colours with soften/gradient/grain/brightness from the spec fixtures, separate logins per space as separate engine storage), favorites shared across spaces, pinned tabs and folders per space, drag to reorder, the sidebar's pinned/hidden/hover-peek modes with the same settings (reveal width, delay, speed), space switching (click, shortcut; two-finger swipe where the platform offers it), session restore of windows and selections, archiving and tab sleeping (sleep releases the engine page and keeps its URL).

Motion: use one shared set of three curves (settle, leave, glide) like the Mac's Motion helpers, respect the OS's reduce-motion setting. Tests: hooks that check order, restore after relaunch (fresh scratch profile), theme fixtures and sleep/archive timing, in CI on Windows and Linux; screenshots as CI artifacts. Hover and swipe feel are the owner's to judge: give them a short list of things to try.
```

### Prompt 6: Command bar, bangs and shortcuts (branch `cx-commandbar`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: cx-commandbar. You own chromium/ui/commandbar/ and the commands/keybindings parts of chromium/core/; three other agents work in chromium/ at the same time, so keep diffs elsewhere tiny.

Bring over, matching spec/ and CLAUDE.md ▸ How the pieces behave ▸ Command bar and Control+Tab: the centered new-tab bar (Ctrl+T) and in-place address editing (Ctrl+L), typed text -> URL and bangs exactly per the spec fixtures, suggestions from history/open tabs/commands (search suggestions only from the same provider and under the same setting as the Mac; no new network destination), the commands registry with remappable keybindings (keybindings.json, same command ids as the Mac; Windows/Linux use Ctrl where the Mac uses Cmd, and document the mapping), Control+Tab recency with the switcher, and the menus/shortcuts that exist on the Mac where the platform allows.

Tests: every spec fixture for the resolver/bangs/keybindings passes in CI on Windows and Linux; hooks for typing into the bar and for recency order. Typing feel is the owner's.
```

### Prompt 7: Privacy, blocking and extensions (branch `cx-privacy-extensions`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: cx-privacy-extensions. You own chromium/engine/privacy/ and chromium/engine/extensions/ and the Privacy/Extensions settings pages; three other agents work in chromium/ at the same time. This is the security-critical branch: re-read AGENTS.md 2.3 and CLAUDE.md ▸ Security behaviour before starting.

Bring over: built-in uBlock Origin Lite (Chromium MV3, pinned upstream, unmodified; updates only with the same "more permissions = ask first" rule as the Mac), a per-site blocking toggle (never a global off switch), HTTPS-first with Birch's own not-secure warning whose Continue works only from that warning, permission prompts for camera/mic/location/notifications (never auto-granted, never remembered in private windows, hidden tabs refused), asking before opening other apps (except clicked mailto/tel), refusing main-frame data: navigations, downloads a page starts without a click asking once per site, JavaScript dialogs from hidden tabs cancelled, Clear Browsing Data with time ranges, Forget This Site, and the Chromium identity: the engine's own honest Chrome user agent with client hints reduced to the minimum; propose it to the owner before shipping (don't copy the Mac's Safari identity). Extensions: adding unpacked/packaged extensions, Proton Pass end to end (ask the owner for an unmodified package; no Chrome Web Store downloads from tests), and whether Chrome Web Store installs can be offered to users safely; if they need a bridge from the store page into the app, stop and ask (rule 4).

Tests in CI on Windows and Linux: each item above gets a hook with expected/got lines, plus the NetLog check (only local fixtures contacted, with uBOL on). Signed-in Proton Pass is the owner's: give them exact steps and what to paste back.
```

### Prompt 8: Peek, split view, downloads and Library (branch `cx-peek-split-library`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: cx-peek-split-library. You own chromium/ui/peek/, chromium/ui/split/, chromium/ui/library/ and the downloads/history parts of chromium/core/; three other agents work in chromium/ at the same time.

Bring over, matching spec/ and CLAUDE.md ▸ How the pieces behave: Peek (links to other sites open in a preview over the page, expand/close, excluded search engines, off for script-opened windows so sign-in pop-ups work), split view (2–4 panes as one sidebar item, focus follows the clicked pane, all the Mac's ways in/out), mini windows for links from other apps and private windows (isolated storage, never restored), downloads (progress in the sidebar, the Library button, recent list, open/show in folder; private downloads leave no record), Library with Downloads, History (search, delete one, Forget site) and Archive, Free Up Memory. Media mini player and Picture in Picture can wait; note them as not done.

Tests in CI on Windows and Linux: hooks with expected/got lines for each feature, including that a private window's download leaves nothing in history or downloads.json. Feel and drag-and-drop are the owner's.
```

---

## Wave 4

### Prompt 9: Windows installer, updater and release (branch `chromium-release-windows`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: chromium-release-windows. Read CLAUDE.md ▸ Updates first: the Windows edition must keep every property of the Mac updater (signed with the Ed25519 update key, size + sha256 + signature checked, only newer builds, failed installs reported, never left without a browser), without changing any Mac updater file (Sources/SorrelUpdateCore, Sources/SorrelUpdater, tools/release.sh, tools/update-sign.swift are protected).

1. Installer: per-user, no admin rights, into %LOCALAPPDATA%\Programs\Birch, Start menu shortcut, uninstaller that leaves the profile unless asked. Propose the tool (e.g. Inno Setup in CI, or a plain zip) and ask the owner before choosing. Optional "Make Birch the default browser" through Windows' own settings page.
2. Updater: the app checks a Windows feed, downloads, verifies the signature with the public key built into the app, and swaps the install on quit with a small helper. Design the feed so editions can never cross: the Mac's updates.json never names a Windows file, the Windows feed names only windows-x64 archives, the archive itself carries its edition/OS/arch inside the signed bytes and the installer refuses a mismatch, and a Mac-only GitHub release must not break or downgrade Windows updates (GitHub's releases/latest is shared by both editions). Ask the owner whether to reuse the existing update key or create a separate one for the Chromium edition; the private key never leaves this Mac and never goes into CI (CI builds the unsigned archive; signing happens on this Mac).
3. A release script for the Windows edition (separate from tools/release.sh) that downloads the CI artifact for a given commit, checks it, signs it locally, writes the feed and notes (including the "Windows protected your PC ▸ More info ▸ Run anyway" step), and commits; publishing stays a separate step that only runs with the owner's go-ahead. Code signing: unsigned for now; you may write a short proposal for the free SignPath Foundation programme for the owner, but configure nothing.

Test end to end in CI on Windows with throwaway builds and a test key (never the real key in CI): update installs, bad signature refused, wrong edition refused, older build refused, broken build reported with the old copy reopened. Cut nothing and publish nothing unless the owner asks.
```

### Prompt 10: Security audit before the first Windows release (branch `chromium-security-audit`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: chromium-security-audit. You are an independent reviewer of chromium/ before its first public Windows release. You did not write it; assume it has mistakes.

Check every rule in AGENTS.md 2.2–2.4 and CLAUDE.md ▸ Security invariants and ▸ Security behaviour against the Chromium edition, plus Chromium-specific risks: sandbox actually on for every process type on Windows and Linux (no --no-sandbox or equivalent anywhere, including docs and CI), every Google/Chromium background service off (re-run the NetLog check yourself with extra fixtures: a page with WebRTC, prefetch hints, a service worker), private windows leave nothing on disk (inspect the scratch folder after close, including the cache and crash dump folders), no channel from web content into the app, extension permissions and update holds, the updater's signature and edition checks (try tampered archives and feeds), the installer's file permissions, DLL search order and uninstaller, Mark of the Web on downloads, the address bar under lookalike domains and long hosts, and what crash reporting does (it must be off: no crash uploads).

Write chromium/SECURITY-AUDIT.md: each finding with severity, evidence and a fix. Fix only clear, small issues on your branch, each with a test; list the rest for the owner. Don't merge.
```

---

## Wave 5

### Prompt 11: Linux edition (branch `chromium-linux`)

```text
Follow docs/chromium-agents.md ▸ Shared rules. Your branch: chromium-linux. The Windows edition is merged; CI has built chromium/ on Linux since wave 2. Your job is a Linux download people can install, with the same privacy and update guarantees.

1. Packaging: an AppImage first (one file, no root), x86_64; propose .deb and Flatpak to the owner as later options. Desktop file, icon, MIME/URL handlers, profile at ~/.local/share/birch.
2. Sandbox: Chromium's sandbox must work out of the box. Handle Ubuntu 23.10+'s restriction on unprivileged user namespaces (AppArmor) properly: document the options (an AppArmor profile, the setuid sandbox helper, Flatpak's zypak) with their trade-offs and ask the owner before choosing. Never ship --no-sandbox or tell users to use it.
3. Updates: reuse agent 9's design with a linux-x64 feed and the same edition checks (AppImage self-replacement, keeping the old file until the new one verifies). Signing stays on this Mac.
4. Test in CI on ubuntu-latest and at least one other distribution image (e.g. Fedora in a container): launch, NetLog check, private window cleanup, spec fixtures, update install/refusals, sandbox status.

Extend the Windows release script (or add a sibling) for Linux; publish nothing without the owner's go-ahead. Report what CI verified and give the owner one thing to try on a Linux machine if they have one.
```
