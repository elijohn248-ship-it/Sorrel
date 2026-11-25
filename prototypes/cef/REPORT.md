# Birch on CEF: wave-1 prototype report

Branch `chromium-cef-proto`, worktree `~/sorrel-chromium-cef-proto`, 2026-11-25. Milestone 2 of `docs/dual-engine-plan.md` for CEF, Windows first, Linux second. Everything below was built and run in GitHub Actions (`.github/workflows/chromium-cef-proto.yml`). Nothing CEF-related ran on the Mac, and no one ran it on a real Windows desktop (the owner has none). Evidence lines are copied from the CI logs. They contain fixture hosts (`*.birch.test` on 127.0.0.1), counts and Chromium diagnostics only.

- **Engine:** CEF `158.0.3+g8c29be2+chromium-158.0.8127.18` (stable, built 2026-11-20): the official "minimal" binary distributions for Windows x64 and Linux x64, pinned by size, SHA-1 and SHA-256 (`deps.json`, `chromium/THIRD_PARTY.md`).
- **Extension:** uBlock Origin Lite `2026.1122.1948`, Chromium MV3 build, unmodified, pinned by SHA-256.
- **Green CI runs with every gate below:** https://github.com/elijohn248-ship-it/Sorrel/actions/runs/45525460574 (commit `3911509`, the last code change) and https://github.com/elijohn248-ship-it/Sorrel/actions/runs/45522413210 (commit `b8890ed`). Numbers in this report are from those runs; build times vary by ±40% between runs.

## Gate table

| # | Gate | Windows (CI) | Linux (CI) | Evidence |
|---|---|---|---|---|
| 1 | Two tabs, back/forward/reload, real origin + punycode, teardown, crash recovery | **PASS** | **PASS** | 18/18 checks on each OS. Example: `tabs: lookalike shown as punycode expected=http://xn--pple-43d.birch.test:… got=… -> PASS`. A crashed renderer goes to Birch's `birch://error` page and the tab then loads again. A closed tab reaches `OnBeforeClose` |
| 2 | A private window's cookies, cache and history gone from disk | **PASS** | **PASS** | After exit, 0 profile files contain private-window markers. Normal-window markers turn up in cookies, history, cache and local storage, which proves the scan works. No private markers anywhere else in the temp folder |
| 3 | Download to a scratch folder with Mark of the Web | **PASS** | n/a | Both downloads (Alloy tab and Chrome-style window) got `[ZoneTransfer] ZoneId=3 HostUrl=http://dl.birch.test:…/download/birch-test.bin`. Chromium wrote it itself, so Birch's fallback writer was never used |
| 4 | Sandbox on Windows | **PASS** | see 11 | Renderers: `integrity=untrusted restricted=true job=true`. GPU: `low`, restricted. Storage service: `untrusted`. Network service: AppContainer/LPAC (after Birch turned it on; Chromium's default leaves it unsandboxed). No process has `--no-sandbox`. Whole-app confinement: **none** |
| 5 | Network: only the fixture server | **PASS** | **PASS** | 75 s idle after browsing: `non-fixture requests/connections: none`. In the same scenario, stock CEF contacted `update.googleapis.com`, `clients2.google.com`, `edgedl.me.gvt1.com`, `redirector.gvt1.com` and `www.google.com`. One OS-level item remains on Windows: a WPAD DNS lookup (owner decision below) |
| 6 | Permissions refused by default | **PASS** (code paths) | n/a | 9/9 checks: camera and microphone give `NotAllowedError`, location `error1`, notifications `denied`. Each request reached Birch's handler (`perm: prompt … types=geolocation decision=deny`). Real devices and prompts: NOT TESTED (no desktop) |
| 7 | Bad certificate never loads silently | **PASS** | n/a | `tls: certificate error -202 … decision=cancel` in both Alloy and Chrome style. Birch's error page shows, and the server got 0 requests for the page |
| 8 | Extensions | uBOL **PASS**; Proton Pass **NOT TESTED** | n/a | With uBOL: `{"adsense":"blocked","analytics":"blocked","control":"loaded"}` in both styles, and the ad hosts reached the server 0 times (without uBOL: 2). uBOL is listed `ENABLED` with 0 errors, and its pop-up page renders. Chrome Web Store installs: likely possible in Chrome style (from source), not tried |
| 9 | Interface approach | analysis | analysis | Recommended: thin CEF Views shell with an HTML sidebar. That needs an owner-approved UI-only channel (rule 4). Not built |
| 10 | Codecs and DRM | result | n/a | VP9, AV1 and Opus play. **H.264 and AAC don't** (`canPlayType` empty, media error 4). **Widevine: no** (`NotSupportedError`). ClearKey works |
| 11 | Linux: same build compiles; gates 1, 2, 5 pass | — | **PASS** | ubuntu-24.04 with Xvfb. chrome://sandbox: `Namespace`, `Seccomp-BPF sandbox Yes`, `You are adequately sandboxed`. Renderers run with `seccomp=2` in their own user namespace. The AppArmor userns restriction is handled with a per-binary profile |
| 12 | Cost | numbers | numbers | Windows: CEF download 172 MiB, app 420 MiB, zip ~186 MiB, idle with one blank tab 121 MiB private / 296 MiB working set. Linux: app 1.5 GiB (unstripped), zip ~362 MiB, idle 372 MiB PSS. CEF shipped 116 stable builds in 12 months |

## Details per gate

### 1. Tabs, navigation, origin, teardown, crash

The prototype window uses CEF Views in Alloy style: back, forward and reload buttons, an address field and tab buttons, with one CEF BrowserView per tab.

The address field shows `scheme://host[:port]` of the **committed** URL, as Chromium canonicalised it. So an international domain stays punycode, which matches Birch's rule that lookalikes always show as punycode.

The checks (`BIRCH_TEST=tabs`):
- origin display
- back to page 1, can-go-forward, forward
- reload (the page's navigation type reads `reload`)
- a second tab, with the address following the active tab
- `http://аpple.birch.test` (Cyrillic а) shown as `http://xn--pple-43d.birch.test:…`
- renderer crash: `OnRenderProcessTerminated` leads to Birch's `birch://error` page, and the same tab then loads a page again
- a web page can't open or fetch `birch://` (display-isolated scheme)
- closing one tab tears its browser down (`OnBeforeClose`) and leaves the other tab active with the right address

The crash is triggered with DevTools `Page.crash`, with Chromium's `chrome://kill` as a fallback (the fallback never ran in the final run).

**Linux finding:** Ubuntu pipes core dumps to `systemd-coredump` even for sandboxed renderers (`fs.suid_dumpable=2`). That kept a deliberately crashed renderer alive for minutes, so the tab hung instead of showing the error page. CI turns core dumps off for test runs (`core_pattern=core`, `suid_dumpable=0`, `ulimit -c 0`). It's the test environment, not the browser. On users' Ubuntu machines, a crashing tab might hang the same way. Wave 5 should check this, for example by setting `RLIMIT_CORE=0` for child processes.

### 2. Normal vs private storage

The run uses an on-disk normal profile inside the scratch `BIRCH_HOME` (`BIRCH_PERSIST=1`).
- The normal window sets a cookie, localStorage and a cacheable script on `normal.birch.test`.
- The private window does the same on `private.birch.test`. It is a CEF request context with an empty cache path, which is Chromium's off-the-record profile.
- Both visit `shared.birch.test`, and neither sees the other's cookie.

After the private window closes and the app exits, `tools/gates.py` scans every profile file (ASCII and UTF-16) for the private host and both private cookie names. **0 files** match on Windows and on Linux. The normal markers are found in Cookies, History, the HTTP cache and Local Storage, which proves the scan would have found private data. Nothing written to the temp folder during the run contained the private markers either.

Not covered: memory forensics, the Windows pagefile, crash dumps (none were produced).

### 3. Download and Mark of the Web

`OnBeforeDownload` saves to `BIRCH_HOME/Downloads` without a dialog. Both downloads got a `Zone.Identifier` stream with `ZoneId=3` (Internet) and `HostUrl`, written by Chromium's own quarantine code. The app checked it, and `gates.py` checked it again by reading the NTFS stream.

Not exercised: how Windows SmartScreen reacts to the mark (needs a real desktop).

### 4. Sandbox on Windows, and whole-app confinement

**Bootstrap.** Since M138, the sandbox library can only be linked by Chromium's own toolchain, so the Windows sandbox needs CEF's **bootstrap**: `birch_cef.exe` is CEF's prebuilt `bootstrapc.exe`, and Birch's code lives in `birch_cef.dll`. Safeguards:
- The build refuses `USE_SANDBOX=OFF`.
- The app refuses to start without sandbox info.
- `--no-sandbox`, `--disable-gpu-sandbox`, `--disable-setuid-sandbox` and `--no-zygote-sandbox` are stripped if passed.

**Process tokens.** `gates.py` inspected every process during the run (ctypes):

| Process | Token |
|---|---|
| Renderers | `untrusted`, restricted token, in a job |
| Storage service | `untrusted` |
| GPU | `low`, restricted |
| Network service | AppContainer (`S-1-15-2-…`), `low` |

chrome://sandbox works in an Alloy tab and reports the same (renderers `Lockdown`, `S-1-16-0 Untrusted`, mitigation flags).

**Hardening added:** Chromium 158's default leaves the network service **"Not Sandboxed"** on Windows (`NetworkServiceSandbox` disabled; seen in the first runs). Birch turns it on (`--enable-features=NetworkServiceSandbox`, merged with CEF's own list), and the build grants the app folder to restricted app packages, as CEF's CMake does. All gates still pass with it on.

**Whole-app confinement on Windows: none.** The browser process runs with the user's full rights. (In CI it showed `integrity=high` only because the runner is an administrator.) Nothing like the Mac App Sandbox keeps a compromised browser process away from the user's files, SSH keys or other apps. Possible options, none tried:
- an AppContainer/MSIX package. Chromium's own sandbox inside an AppContainer is untested and probably unsupported.
- system-wide Windows policies such as WDAC (the owner's machine, not the app).

This is a real step down from the Mac edition and should be accepted knowingly.

### 5. Network

**Setup:**
- `BIRCH_HOME` is set, and `--host-resolver-rules` maps `*.birch.test` to 127.0.0.1. Everything else uses real DNS, so a background service would actually reach the internet and show up.
- NetLog via `--log-net-log`, with a persistent profile.
- Browsing (two tabs, a private window, a Chrome-style window with Chrome's location bar), then 75 s idle.
- The analyser counts every host Chromium asked for (URL requests, DNS lookups, stream jobs) and every address it connected to or sent packets to.

**Result on both OSes: nothing but the fixture server.** Two non-fixture items remain, and neither is a Google service:
- **`wpad` (Windows only).** Windows' proxy auto-detection asks the local network's DNS server for `wpad`. It follows the OS setting "Automatically detect settings". Stopping it means ignoring the system proxy (`--no-proxy-server`), which breaks corporate proxies. **Owner decision.**
- **`2001:4860:4860::8888`.** A UDP `connect()` with **no packet sent**. This is Chromium's IPv6 reachability probe asking the OS for a route; nothing leaves the machine.

**What had to be switched off, and how.** Stock CEF 158 contacted the hosts in the first two rows within 75 s.

| Service | Host it contacted | Switched off by |
|---|---|---|
| Component updater (CRLSet, certificate-transparency lists, CDMs, …) | `update.googleapis.com`, `clients2.google.com`, `edgedl.me.gvt1.com`, `redirector.gvt1.com`, `*.gvt1.com` | `--disable-component-update`, local-state pref `component_updates.component_updates_enabled=false`, feature `CertificateTransparencyComponentUpdater` off |
| "AI Mode" eligibility check (Chrome style starts it at launch) | `www.google.com/async/folae` | features `AimEnabled`, `AimServerEligibilityEnabled`, `AimServerRequestOnStartupEnabled` and `AimUrlNavigationFetchEnabled` off, pref `omnibox.ai_mode_settings=1` |
| Background networking (variations, network time, …) | — | `--disable-background-networking`, feature `NetworkTimeServiceQuerying` off |
| Optimization guide and hints | — | features `OptimizationHints`, `OptimizationHintsFetching`, `OptimizationGuideModelDownloading` and `OptimizationTargetPrediction` off |
| Safe Browsing, client-side phishing model | — | pref `safebrowsing.enabled=false`, `--disable-client-side-phishing-detection` |
| Spelling dictionaries and spelling service | — | `--disable-spell-checking`, prefs `browser.enable_spellchecking=false` and `spellcheck.use_spelling_service=false` |
| Preconnect/prefetch, search suggestions, alternate error pages | — | prefs `net.network_prediction_options=2`, `search.suggest_enabled=false` and `alternate_error_pages.enabled=false` |
| Translate, Autofill server, Media Router/Cast, sync, domain reliability, hyperlink pings, DNS-over-HTTPS auto-upgrade, metrics | — | features `Translate`, `AutofillServerCommunication`, `MediaRouter`, `DialMediaRouteProvider`, `CastMediaRouteProvider` and `DnsOverHttps` off; `--disable-sync`, `--disable-domain-reliability`, `--no-pings`; local-state `dns_over_https.mode=off` and `user_experience_metrics.reporting_enabled=false` |
| Crash uploads | — | Nothing to switch off: CEF only uploads crashes when a `crash_reporter.cfg` exists, and Birch doesn't ship one. `--disable-breakpad` as well |

"—" means the service was switched off before it showed up in a NetLog; those rows are defence in depth.

**Pitfall found:** CEF passes its own `--disable-features` list. Appending a second one replaced it and crashed every Chrome-style window (0xC0000005). The prototype merges the two lists.

Not covered: WebRTC (STUN) and pages with service workers, signed-in use, and very long idle periods. Some component and Safe Browsing timers run longer than 75 s. The switches above cover them, but no NetLog was recorded over hours.

### 6. Permissions

The test page is on `http://127.0.0.1` (a secure context), and each request is triggered with a user gesture via DevTools.
- Camera and microphone reach `OnRequestMediaAccessPermission` and are cancelled. CI uses fake capture devices so the request gets as far as the permission step. `--use-fake-ui-for-media-stream`, which auto-accepts, is never used.
- Location and notifications reach `OnShowPermissionPrompt` and get `DENY`.
- Afterwards `navigator.permissions` reports camera and microphone `prompt`, location and notifications `denied`: nothing granted.

NOT TESTED: a real prompt UI, real devices and the Windows privacy settings (no desktop).

### 7. Bad certificate

The HTTPS fixture uses a self-signed certificate. In both Alloy and Chrome style, `OnCertificateError` always cancels. Birch's own error page shows, and the fixture server never receives the HTTP request. Chrome's warning page with its "Proceed (unsafe)" link never appears, because Birch handles the callback itself.

### 8. Extensions

**uBlock Origin Lite: PASS.**
- It loads unpacked with `--load-extension`, from the unmodified upstream zip.
- `chrome://extensions` (`chrome.developerPrivate`) lists it as `ENABLED`, `UNPACKED`, with 0 manifest and 0 runtime errors.
- Its declarativeNetRequest rules block `pagead2.googlesyndication.com/pagead/…` (EasyList) and `b.scorecardresearch.com` (EasyPrivacy, third-party) in **both Alloy-style and Chrome-style** tabs, while a non-ad host loads.
- A control run without the extension shows both ad requests reaching the server.
- Its pop-up page (`chrome-extension://…/popup.html`) renders (65 elements).

The toolbar button and its pop-up bubble need a real click in a Chrome-style window: NOT TESTED. As in Chrome, extensions don't run in private windows unless allowed per extension.

**Proton Pass: NOT TESTED.** The owner has no unmodified package.

What the owner would supply later:
- Proton Pass's **unmodified Chrome package**. Either the `.crx` exactly as the store served it, or the folder Chrome itself unpacked (`<Chrome profile>/Extensions/ghmbeldphafepmbegfdlkpapadhbakde/<version>/`), copied unchanged.
- Keep it **outside the public repo**, for example `~/.config/sorrel/test-extensions/proton-pass-<version>.crx`, and give its SHA-256 (`shasum -a 256 <file>`).
- It can't go through CI on this public repo, because artifacts are public. The test would run on a machine the owner controls.

How it would be tested:
1. Unpack it (strip the CRX3 header) and load it with `--load-extension` in a fresh scratch profile.
2. Read `chrome.developerPrivate.getExtensionsInfo()`: does it load, and with what errors?
3. Wait for its service worker.
4. Open `chrome-extension://ghmbeldphafepmbegfdlkpapadhbakde/popup.html` in a Chrome-style window. These same steps already pass for uBOL.
5. The owner clicks its toolbar button, signs in on `account.proton.me` and tries autofill on a local login form.

**Chrome Web Store installs** (from CEF's documentation and source; not tried):
- CEF 158 runs on Chrome's own browser layer, and its extension support *is* Chrome's extension system. CEF's patches in `chrome/browser/extensions/…` only expose Alloy-style tabs to extensions.
- The store's "Add to Chrome" flow is Chrome's `webstorePrivate` API, granted to `chromewebstore.google.com` and living in that same layer. So store installs are **likely possible in a Chrome-style window**. Not verified, because tests may not download from the store.
- If Birch offered it, that would add network destinations: the store itself, plus Google's extension update service unless Birch updates extensions itself as the Mac does. That needs owner approval under rule 2. It is not a Birch page bridge.

### 9. Interface: how Birch's sidebar would be built on CEF (analysis, nothing built)

| Option | What it gives | Limits |
|---|---|---|
| **CEF Views** (Chromium's own toolkit; this prototype uses it) | One C++ interface for Windows and Linux, native keyboard focus and accessibility, no extra dependency | CEF exposes only panels, buttons, text fields, scroll views, overlays and solid colours: no custom painting, gradients, grain, blur or animation. Arc-style space colours, hover-reveal motion and the Peek card can't be drawn with it |
| **Native per OS** (Win32/WinUI and GTK, hosting CEF browser views) | Full control, native feel | Two interfaces to build and maintain; the most upkeep |
| **HTML** (sidebar, command bar and Peek frame as Birch's own pages in separate browser views, inside a thin CEF Views shell) | One interface for both OSes. CSS gradients, grain and motion make Arc's look straightforward; Chrome and Arc draw much of their own interface this way | Needs a channel from Birch's own interface pages to the app (select a tab, switch space, …): **AGENTS.md rule 4 territory** |

**Recommendation:** a thin CEF Views shell (window, layout, menus, focus order) with the sidebar and command bar in HTML. **Flag for the owner: this needs approval for an interface-only channel. It was not built.**

How it would be kept unreachable from web content:
1. Interface pages load only from `birch://ui/…`, bundled in the app. The scheme is display-isolated, so web pages can't link to it, frame it or fetch it. Gate 1 shows that a page's `location.href='birch://…'` and `fetch('birch://…')` both fail.
2. Interface pages run in their own browser views with their own request context (separate storage), plus a request handler that cancels every request that isn't `birch://ui/…`. Chromium's site isolation keeps them in processes web content never shares.
3. The JavaScript entry point (CEF's message router) is installed by the render-process handler only for browsers created with an "is Birch UI" flag in `extra_info`, and only in the main frame at origin `birch://ui`. Web tabs never get it.
4. The browser process accepts a message only from an interface browser it created, from its main frame at origin `birch://ui`, and only for allow-listed commands with typed, validated arguments. Anything else is dropped and logged.
5. Replies are structured data. Nothing from web pages is pasted into JavaScript source.

### 10. Codecs and DRM

The media files are generated in CI (ffmpeg on Ubuntu) and played muted from a secure origin.

| | Plays? |
|---|---|
| VP9 | yes |
| AV1 | yes |
| Opus | yes |
| H.264 | **no** (`canPlayType` empty, media error 4) |
| AAC | **no** (same) |
| Widevine | **no** (`requestMediaKeySystemAccess('com.widevine.alpha')` gives `NotSupportedError`) |
| ClearKey | yes |

The official CEF builds leave out proprietary codecs. What that means:
- Most of YouTube works (VP9/AV1/Opus).
- Sites that only serve H.264/AAC won't play: some news and video players, many MP4 links.
- No Widevine streaming: Netflix, Disney+, Spotify's web player, Apple TV+.

H.264/AAC would need CEF built from source with `proprietary_codecs=true ffmpeg_branding=Chrome`: hours of build time per release, plus patent-licensing questions for a public download. Widevine needs Google's CDM and a browser signed and verified by Google (VMP), which a free, self-signed project can't get. **Owner decision.**

### 11. Linux

The same sources and CMake file build on ubuntu-24.04 (GCC 13, `-Wall -Wextra -Werror`, 0 warnings in Birch's code). Gates 1, 2 and 5 pass under Xvfb.

Sandbox:
- chrome://sandbox reports `Layer 1 Sandbox: Namespace`, PID and network namespaces `Yes`, `Seccomp-BPF sandbox: Yes` and "You are adequately sandboxed".
- Renderers and the storage service run with `Seccomp: 2` in their own user namespace.
- The GPU process and the network service run without seccomp, as in Chromium on Linux by default. CI has no GPU; the GPU process sandbox wasn't checked on real hardware.

**Ubuntu 23.10+/24.04 user-namespace restriction.** The runner has `kernel.apparmor_restrict_unprivileged_userns=1`. Without an AppArmor profile, Chromium finds no usable sandbox and aborts (`exit=133`): "The SUID sandbox helper binary was found, but is not configured correctly. Rather than run without sandboxing I'm aborting now." Refusing to run unsandboxed is the right behaviour.

CI installs a per-binary AppArmor profile, the same approach Ubuntu ships for Chrome:

```
profile birch_cef "<path>/birch_cef" flags=(unconfined) { userns, }
```

With it, the sandbox works fully.

For users, wave 5 chooses, with the owner's approval:
- ship that AppArmor profile in a .deb (needs root at install), or
- ship `chrome-sandbox` setuid-root (also needs root), or
- use Flatpak with `zypak` (Flatpak's own sandbox; no root).

An AppImage alone can do neither without root. Never `--no-sandbox`.

### 12. Cost and upkeep

| | Windows x64 | Linux x64 |
|---|---|---|
| CEF minimal distribution (CI download) | 172 MiB | 323 MiB |
| App folder (installed size) | 420 MiB | 1.5 GiB (`libcef.so` is unstripped in the minimal build; stripping would remove most of that) |
| Zip of the app folder (rough download size) | 186 MiB | 362 MiB |
| Idle with one blank tab, ~14 s after start | 121 MiB private bytes, 296 MiB working set, 7 processes | 372 MiB PSS, 919 MiB RSS (shared pages counted per process), 10 processes |
| Build time (CEF cached, clean app build) | 141-230 s; whole job with all gates ~9 min | 70-100 s; whole job ~6 min |

For comparison, the Mac edition's whole download is a few MB, because it uses the system's WebKit.

**Security updates.** CEF publishes a new stable build for each Chrome stable or security release. The CEF build index lists **116 stable Windows x64 builds in the 12 months to 2026-11-23** (2-14 a month), across 15 Chromium major versions (138 to 158). Fixes usually land within days of Chrome's own release.

**What an update takes:**
1. Change the version, file names, sizes and checksums in `deps.json`.
2. Rebuild in CI and rerun the gates.

Patch updates keep the API. A major update (every ~4 weeks) can change CEF's C++ API. The Windows build compiles against `CEF_API_VERSION_LAST`, which CEF keeps backwards compatible, so most majors are a rebuild plus fixing deprecations. Each update ships to users as a full ~190 MiB download on Windows, unless the updater learns to send only differences.

## Licenses

- **CEF:** BSD-3-Clause.
- **Chromium:** BSD-3-Clause plus many third-party licenses. The distribution's `LICENSE.txt`/`CREDITS.html` must ship with any build.
- **uBlock Origin Lite:** GPL-3.0.
- **GitHub Actions used:** MIT.

All are compatible with distributing Birch under GPL-3.0. Proprietary codecs would add patent questions.

## Recommendation

**CEF clears the wave-1 gates and is a workable engine for Birch's Windows and Linux edition.** Every automated gate passes on Windows, and gates 1, 2 and 5 pass on Linux, with the Chromium sandbox on everywhere and Google's background services provably off. uBOL Lite works unmodified in both styles. Windows' own Mark of the Web and certificate handling work without extra code.

Things that count against it, or need the owner:
1. **No whole-app confinement on Windows.** Chromium's process sandbox is strong, but the browser process itself has the user's full rights. The Mac edition is better here.
2. **Codecs/DRM:** no H.264/AAC and no Widevine in official builds. Fixing that means building Chromium ourselves, or accepting the gap.
3. **Size and churn:** a ~190 MiB download and roughly 2-14 engine updates a month to keep current. Birch's updater and CI must be built for that.
4. **The interface:** CEF Views can't draw Arc's look, so the real choice is an HTML interface (needs an owner-approved, locked-down interface channel, rule 4) or native code per OS.
5. **Proton Pass is unproven** until the owner provides a package.

If the Qt WebEngine report shows comparable privacy results, the deciding points are probably security-update speed (CEF follows Chrome within days) and how the sidebar gets drawn.

## Owner decisions this report raises

- WPAD on Windows: keep honouring the system's "Automatically detect proxy settings" (one DNS lookup for `wpad` on the local network), or force no proxy.
- An interface-only channel for an HTML sidebar (rule 4), as designed in gate 9.
- Codecs and DRM: accept no H.264/AAC/Widevine, or build CEF from source.
- Linux sandbox packaging (AppArmor profile in a .deb, setuid helper, or Flatpak).
- Whether to offer Chrome Web Store installs (new network destinations).
- A Proton Pass package for testing, kept outside the repo.

## How to rerun

Push to `chromium-cef-proto`, or start the workflow manually. Jobs:
- `media` generates the media files.
- `windows` and `linux` fetch and verify the pinned CEF and uBOL (cached), build, and run `tools/gates.py`.

Results (`summary.md`, `gates.json`, logs, NetLogs that contain only fixture hosts) are uploaded as the `results-windows` / `results-linux` artifacts for 14 days. Test hooks are described in CLAUDE.md ▸ Chromium edition ▸ CEF prototype.

## What was not verified

- Anything that needs a real Windows desktop: real camera/microphone/location prompts and devices, SmartScreen on a marked download, clicking an extension's toolbar button, how the interface feels, DPI scaling, keyboard shortcuts. The owner has no Windows machine; only code paths ran in CI.
- Proton Pass (no package) and Chrome Web Store installs (store downloads are forbidden in tests).
- Background traffic over idle periods longer than 75 s, WebRTC/STUN, sites with heavy service-worker use, signed-in sites.
- Alternatives for whole-app confinement on Windows (none tried).
- The GPU sandbox on real GPU hardware (CI has no GPU).
- macOS (out of scope: the Mac keeps WebKit).
