# Wave 1: Qt WebEngine prototype report

Branch `chromium-qt-proto`, folder `prototypes/qt/`, 2026-11-24. Milestone 2 of `docs/dual-engine-plan.md` for **Qt WebEngine** (Chromium inside Qt), Windows first, Linux second, run against the same 12 gates as the CEF prototype (`docs/chromium-agents.md` ▸ Prompt 1).

**Short answer: Qt WebEngine fails three gates that matter most for Birch (4 sandbox, 8 extensions/blocking, 12 security-patch lag). I recommend not building Birch's Chromium edition on it.** Everything below was run in GitHub Actions on `windows-2025` and `ubuntu-24.04`; there is no Windows machine, and nothing was built or run on the Mac.

## What was built

- A throwaway C++20 / Qt Widgets browser (`src/`): tabs listed in a sidebar, an address label showing the committed page's real origin, back/forward/reload, crash recovery, private windows (off-the-record profile), downloads, permission and certificate handling, an Arc-style native sidebar (gradient, grain, hover reveal), and `BIRCH_*` test hooks (`src/Gates.cpp`) that log `<area>: <what> expected=… got=…`.
- `tests/run_gates.py` runs the app once per scenario, each with a fresh scratch `BIRCH_HOME`, against a local HTTP + HTTPS (self-signed) fixture server. `--host-resolver-rules` maps `*.test`, the lookalike `xn--80ak6aa92e.com` and one ad host to 127.0.0.1, so test traffic never leaves the runner and anything else the engine contacts shows up in the NetLog, in a per-process TCP monitor (Windows) and in `strace` (Linux).
- CI: `.github/workflows/chromium-qt-proto.yml` (push to this branch or by hand only; no secrets, no releases). Artifacts hold logs, screenshots and host summaries only (no NetLogs, profiles or Qt binaries).
- Birch's own code builds with **zero warnings** under MSVC `/W4 /WX` and GCC `-Wall -Wextra -Werror` (any warning fails the build). Qt's headers raised none either.

## Versions

| | |
|---|---|
| Qt | 6.12.0 (open source, LGPL-3.0; released 2026-09-30; an LTS line) |
| Qt WebEngine | **6.140.0** (a separately versioned product since Qt 6.12; binaries published 2026-11-13) |
| Chromium base | **140.0.7339.264** (Chrome 140 shipped in September 2025) |
| Security patches | backported **up to 157.0.8103.50** (Chrome shipped that on 2026-11-09) |
| Chrome stable today | 158 (2026-11-23, chromiumdash) |

Confirmed at runtime on both platforms: `version: qt=6.12.0 webengine=6.140.0 chromium=140.0.7339.264 security-patch=157.0.8103.50`.

## Gate table

Evidence run: https://github.com/elijohn248-ship-it/Sorrel/actions/runs/45516085607 (artifacts `results-windows`, `results-linux`: `summary.txt`, per-scenario logs, screenshots). Win = windows-2025, Linux = ubuntu-24.04 + Xvfb.

| # | Gate | Result | Evidence |
|---|---|---|---|
| 1 | Two tabs, back/forward/reload, real origin, punycode, teardown, crash recovery | **PASS** (Win + Linux) | `nav: back expected=/page1.html got=/page1.html`; `nav: lookalike-address-is-punycode expected=http://xn--80ak6aa92e.com:… got=http://xn--80ak6aa92e.com:…`; a pending page-started navigation to another site does not change the address; `teardown: renderer-exited expected=1 got=1`; `crash: recovered expected=1 got=1` (Win: real `chrome://crash`; Linux: `chrome://crash` did not crash, so the renderer was killed) |
| 2 | Private storage gone from disk after close | **PASS** (Win + Linux) | `private: files-with-private-marker-after-close expected=0 got=0` and `…-after-exit expected=0 got=0` (whole scratch tree scanned, ASCII and UTF-16); positive control found the normal site in `profile/Cookies`, the HTTP cache and Session Storage |
| 3 | Download to scratch folder with Mark of the Web | **PASS** (Win) | `motw: set-by-engine expected=1 got=1`, `motw: zone expected=3 got=3`; checked again from outside the app: `motw-external: zone-identifier-present … zone=['3']`. Linux has no Mark of the Web (download itself passes) |
| 4 | Renderer/GPU sandboxed on Windows; whole-app confinement | **FAIL** | Renderers are sandboxed (Win: `integrity=untrusted restricted=1 job=1`; Linux: `seccomp=2`, own PID namespace). **But there is no GPU process**: Qt forces `--in-process-gpu` and runs the network service in-process, so GPU and network code run in the unsandboxed app process; the video-capture utility is `Not Sandboxed` (Chromium's own `chrome://sandbox` page). No whole-app confinement on Windows (the app runs with the user's full rights). Never ran with `--no-sandbox`; the prototype refuses to start with it (`sandbox: exit-code-with---no-sandbox expected=3 got=3`) |
| 5 | Only fixture traffic; NetLog; background services switched off | **PASS** (Win + Linux, with Birch's settings) | Hardened scenarios: `netlog: non-fixture-hosts expected=0 got=0`, `tcp-monitor: non-local-connections expected=0 got=0`, `strace: packets-sent-to-non-local-ip expected=0 got=0`. Qt's defaults (baseline) do one thing Birch must switch off: on Windows a **WPAD proxy auto-discovery lookup** (`offender host=wpad event=HOST_RESOLVER_MANAGER_REQUEST source=PAC_FILE_DECIDER`). The only other non-local address is Chromium's IPv6 reachability check (a UDP `connect()` to 2001:4860:4860::8888 that sends no packet: `strace: udp-connect-only (no data)`) |
| 6 | Camera/mic/location/notifications reach the app, refused by default | **PASS** (Win + Linux) | `perm: request type=camera+microphone … action=deny` (same for location, notifications); page sees `AbortError` / `denied` / `denied`; nothing granted. Note: after a refusal Chromium does not ask again in the same tab, even after a reload, until the tab closes (`camera-mic-asked-app-times expected=2 got=1`); a new tab asks again (`expected=1 got=1`) |
| 7 | Bad certificate shows an error | **PASS** (Win + Linux) | `tls: certificate-error type=-202 overridable=1 action=reject`; `tls: load-succeeded expected=0 got=0`; `tls: secret-content-shown expected=false got=false` |
| 8 | uBOL Lite blocks; Proton Pass; Chrome Web Store | **FAIL** (uBOL) · **NOT TESTED** (Proton Pass) | uBOL installs and enables, its pop-up renders, but `ubol: tracker-request-loaded expected=false got=true`: its service worker crashes (`chrome.permissions` missing) and **declarativeNetRequest rules are not applied at all** (a minimal one-rule test extension also fails: `dnr-probe: tracker-request-loaded expected=false got=true`). No Chrome Web Store installs. Details below |
| 9 | How the Arc-style sidebar would be built | **PASS** (native Qt, no page-to-app bridge) | Screenshots `shots-main/sidebar-*.png`: OKLab gradient, grain, overlay slide-in over the page. `motion: reveal frames=13 duration-ms=258 mean-gap-ms=21.5 max-gap-ms=69` (CI software rendering). Details below |
| 10 | Codecs and DRM | **Measured** (Win + Linux, same) | Play: VP8, VP9, AV1 (WebM and MP4), Opus, Vorbis, MP3, FLAC. Don't play: **H.264, AAC, HEVC** (`canplay=no load=error4`). Widevine: Qt ships none, but **found and loaded the runner's installed Chrome's Widevine CDM** (`drm: widevine_webm got=yes:cdm-loaded`); Widevine with H.264 is impossible (`no:NotSupportedError`) |
| 11 | Linux: compiles; gates 1, 2, 5; Ubuntu 24.04 sandbox | **PASS** | GCC build with `-Werror` clean; gates 1, 2, 5 pass under Xvfb. Ubuntu 24.04 restricts user namespaces (`kernel.apparmor_restrict_unprivileged_userns = 1`): without a profile Chromium **silently** drops to seccomp-only (`Layer 1 Sandbox None ; PID namespaces No`); with a path-specific AppArmor profile granting `userns` to the app and `QtWebEngineProcess` (`results/apparmor-profile.txt`): `Layer 1 Sandbox Namespace ; PID namespaces Yes ; Network namespaces Yes ; Seccomp-BPF sandbox Yes` |
| 12 | Cost; security-update cadence | **FAIL** (security lag) | Windows zip **131 MB**, installed **319 MB** (137 files); idle with one blank tab: Win 2 processes, 66 MB private / 184 MB working set; Linux 5 processes, 136 MB anonymous memory. CI: Windows job ~7 min (Qt download 2 min uncached, build 1 min), Linux ~5 min. Qt WebEngine releases arrive **43–96 days apart**, on a Chromium base 18 milestones old (table below) |

## Gate notes

**1. Navigation.** The address label is built from `QUrl::host(QUrl::EncodeUnicode)`, so lookalikes show as punycode. Qt's *default* `QUrl::host()` shows `аррӏе.com` in Cyrillic (logged as `nav: qt-default-host-display host=аррӏе.com`): Birch must never use it for the address bar. Navigations to other apps' schemes and main-frame `data:` URLs are refused in `acceptNavigationRequest` (a real build would ask before opening another app).

**2. Private windows.** A private window gets its own off-the-record profile and the scan looks for its site name anywhere in the scratch tree (profile, cache, temp) while running and after exit. Rule 7 note: with `BIRCH_HOME` set the normal profile keeps cookies and cache in memory, except in this gate, where `BIRCH_PERSIST_SCRATCH=1` puts them on disk inside the scratch folder as the positive control. A named Qt profile always keeps a folder (needed for extensions); it is inside `BIRCH_HOME`.

**3. Downloads.** Qt WebEngine sets `Zone.Identifier` (ZoneId=3) itself on Windows; the prototype would write it if the engine didn't (`motw: present-after-birch`). Chromium did not set Linux's `user.xdg.origin.url` attribute.

**4. Sandbox.** Process facts read from Birch's own process tree (Windows tokens; Linux `/proc/<pid>/status`) and Chromium's own `chrome://sandbox` page, which Qt supports on both systems:

| Process | Windows | Linux (with the AppArmor profile) |
|---|---|---|
| App (browser) process: UI, **GPU, network service** | unsandboxed (CI runner: high integrity, because it runs as admin) | unsandboxed |
| Renderer | untrusted integrity, restricted token, job object | seccomp-BPF + PID/network namespaces |
| Audio service | low integrity, restricted | in a zygote |
| Video capture service | **not sandboxed** | **not sandboxed** |

Chrome itself sandboxes its GPU process (and, on Windows, its network service). Qt can't: it hard-codes `--in-process-gpu` and `NetworkServiceInProcess` (`src/core/web_engine_context.cpp`), and `QTWEBENGINE_DISABLE_SANDBOX` exists as a switch-off. A bug in GPU drivers or the network stack therefore lands in a process that can read the user's files. Whole-app confinement on Windows (an AppContainer around the browser process) is not something Qt or Chromium offers.

**5. Network.** Only these were switched off, and only the last one mattered:
- Chromium switches `--disable-background-networking --disable-component-update --disable-domain-reliability --no-pings --disable-breakpad` (defence in depth; Qt WebEngine already leaves out Safe Browsing, sync, the component updater, variations, crash upload and Google push messaging; the baseline scenario without them was equally clean on Linux).
- Qt settings: DNS prefetch off, hyperlink auditing off, WebRTC limited to public interfaces, push service off, spell checking off, no notification presenter, the "Google Hangouts" component extension unloaded.
- **Proxy auto-discovery**: with Qt's defaults, Windows resolves `wpad` on the local network (a known attack vector as well as a privacy leak). Chromium's `--no-proxy-server` is ignored by Qt; `QNetworkProxy::setApplicationProxy(NoProxy)` stops it. The cost is that system proxies are ignored; a real build would need an explicit proxy setting (owner decision).
- What remains: the IPv6 reachability probe (UDP connect, no packet sent, proven by `strace` on Linux). The NetLog covers Chromium's own network stack; Windows' own certificate revocation fetches (CryptoAPI) would not appear in it, and the TCP monitor saw only `127.0.0.1`/`::1`.

**6. Permissions.** All four permission kinds reach the app (`permissionRequested`) and are refused; the profile uses `AskEveryTime`. The per-tab memory of a refusal is Chromium behaviour; a real Birch would show its own prompt and should know that a second request from the same tab may never reach it.

**8. Extensions** (`QWebEngineExtensionManager`, uBOL Lite 2026.1122.1948, Chromium MV3, pinned and unmodified):
- Install and enable work; the pop-up page (`actionPopupUrl`) loads in a tab (Qt has no action pop-over; Birch would host it itself) with 67 elements, but shows no data because the background is dead.
- The service worker fails at `background.js:900` (`Cannot read properties of undefined (reading 'onRemoved')`, i.e. `browser.permissions`), then `Service worker registration failed. Status code: 15`.
- `declarativeNetRequest` exists as an object, but its rules are not applied to network requests: the probe extension in `tests/fixtures/dnr-probe/` (one static block rule, no background script) installs without error and the ad request still loads. **No MV3 content blocker can work on Qt WebEngine 6.140.**
- APIs Qt gives an extension page: `alarms, declarativeNetRequest, i18n, management, offscreen, runtime, storage, tabs`. Missing (among others): `permissions, action, scripting, userScripts, windows`. Qt documents no supported-API list.
- Every profile also carries "chromium-pdf" and "Google Hangouts" component extensions; the prototype unloads Hangouts.
- **Private windows**: Qt has no extensions off the record (uBOL is not active there: `private-ubol: ubol-active-in-private-window expected=0 got=0`). Blocking in private windows would need Birch's own blocker on `QWebEngineUrlRequestInterceptor`; a one-domain demo works (`tracker-loaded-with-birch-interceptor expected=false got=false`). Since DNR doesn't work in normal windows either, Birch would have to build its own filter-list engine for every window.
- **Chrome Web Store**: installs from the store page are impossible (its button needs Chrome's private `webstorePrivate` API; adding one would be a page-to-app bridge, rule 4). `installExtension()` accepts only a zip or a folder (no `.crx`, no signature check) and Qt has no extension updater, so Birch would have to download, verify and update store extensions itself, and most would hit the missing APIs.
- **Proton Pass: NOT TESTED** (no unmodified package). With `permissions`, `scripting`, `action` and `windows` missing it is very unlikely to work. If Qt were still a candidate, the owner would supply Proton Pass's unmodified Chrome package (the `.crx` or `.zip` exactly as published, e.g. saved from the Chrome Web Store with Chrome, or Proton's own release archive), kept **outside the repository** (for example `~/.config/sorrel/proton-pass-chrome.zip`); it would go to CI only as a manual, non-public input, or be installed on a Windows machine. The test: install and enable it, check its background starts without errors in the log, open its pop-up in a pop-up view, then the owner signs in on a throwaway profile and tries autofill on a local login-form fixture.

**9. Interface.** Qt draws the sidebar natively, so Birch's own UI needs no channel from a web page to the app (rule 4 untouched). With Qt Widgets: the gradient (16 stops mixed in OKLab, as `ThemeLook.swift` does) and the grain tile look right; translucent overlays composite over the web view; hover reveal uses a 40 ms pointer poll like the Mac. Motion is `QPropertyAnimation` with ease curves: ~13 frames over ~250 ms, but worst frame gaps of 50–70 ms on CI's software rendering; Widgets have no spring physics, no blur/vibrancy behind the sidebar (Windows 11 Mica/Acrylic would need native DWM calls) and paint on the CPU. Qt Quick (QML) would get closer to Arc (GPU scene graph, `SpringAnimation`, `MultiEffect` blur, shader grain). Real feel cannot be judged in CI.

**10. Codecs.** Qt's prebuilt WebEngine is built without proprietary codecs, so H.264/AAC/HEVC need a self-built Qt WebEngine plus codec licensing; MP4 files with AV1 play. Qt looks for a Widevine CDM in other browsers' install folders and loaded the runner's Chrome copy: on a user's PC with Chrome installed, Birch would load Google's binary from Chrome's folder; without Chrome, no DRM. Netflix-style services (H.264 + Widevine) won't work either way.

**11. Linux.** Built with GCC under the same warning rules; all scenarios run under Xvfb. The AppArmor profile is the approach Chrome's own Ubuntu package takes; a real package would install a profile for its own paths (an owner decision for wave 5), never `--no-sandbox`. The bad part is the silent fallback: without the profile nothing fails, the sandbox just loses a layer, so a Birch build would have to check `chrome://sandbox`-style status itself and warn.

## Security-patch lag (gate 12)

Qt WebEngine stays on one Chromium base (now 140) and backports Chrome's security fixes into its own releases. The fix level is good on release day, but fixes reach users only when Qt releases, and the gaps are long:

| Qt WebEngine release (git tag date) | Security patches up to | Chrome shipped that | Behind Chrome on release day | Days since the previous release |
|---|---|---|---|---|
| 6.10.0 (2025-10-02) | 140.0.7339.207 | 2025-09-23 | 9 days | — |
| 6.10.1 (2025-11-14) | 142.0.7444.162 | 2025-11-11 | 3 days | 43 |
| 6.10.2 (2026-01-24) | 144.0.7559.96 | 2026-01-20 | 4 days | 71 |
| 6.10.3 (2026-03-30) | 146.0.7680.164 | 2026-03-23 | 7 days | 65 |
| 6.11.0 (2026-03-17) | 146.0.7680.80 | 2026-03-14 | 3 days | — |
| 6.11.1 (2026-05-08) | 148.0.7778.96 | 2026-04-29 | 9 days | 52 |
| 6.11.2 (2026-08-12) | 151.0.7922.71 | 2026-07-29 | 14 days | **96** |
| 6.11.3 (2026-10-21) | 155.0.8059.85 | 2026-10-15 | 6 days | 70 |
| 6.140.0 (2026-11-10) | 157.0.8103.50 | 2026-11-09 | 1 day | 20 |

Sources: `CHROMIUM_VERSION` in each `qt/qtwebengine` tag; Chrome dates from chromiumdash's stable-channel history.

A fix Chrome ships just after a Qt release reaches Qt WebEngine users **43–96 days later (median about 65)**, plus Birch's own rebuild and release time. Right now Qt is already missing whatever Chrome shipped after 9 November (157.0.8103.51 onward and Chrome 158). That is months behind: **FAIL**.

Possible improvements, none proven: Qt says the separate WebEngine line exists to ship "point releases for critical Chromium security issues" faster (Qt blog, 2026-09-24), but there is only one such release so far. Qt 6.12 is an LTS, where open-source patch releases usually stop after the first year, so the open-source cadence could get worse. Building Qt WebEngine ourselves from its git branch (which gets fixes sooner) means compiling Chromium: hours per build, beyond free CI runners, and against the upkeep rule. Separately, the web platform is Chromium 140; the user agent says `Chrome/140`, so some sites will warn about an outdated browser, and features from Chrome 141–158 are missing.

## Licences

- Qt 6.12.0 and Qt WebEngine 6.140.0 under the **LGPL-3.0** (no Qt account, no commercial licence), dynamically linked; compatible with Birch's GPL-3.0. A shipped Birch must include Qt's licence texts and a source offer. Chromium inside it is BSD-3-Clause plus many third-party licences (listed in Qt's documentation).
- uBlock Origin Lite: GPL-3.0 (downloaded in CI, never committed). aqtinstall: MIT. Versions, sources and every SHA-256: `chromium/THIRD_PARTY.md`, `ci/pins.json`, `ci/requirements-aqt.txt`.
- No proprietary codecs and no Widevine ship with Qt.

## Recommendation

**Do not pick Qt WebEngine for Birch's Chromium edition.**

1. **Blocking and extensions don't work** (gate 8): declarativeNetRequest rules are not applied, uBOL's background crashes on missing APIs, and Chrome Web Store installs are impossible. Birch's "ads and trackers blocked" promise and Proton Pass both depend on this; the workaround is writing and maintaining our own blocker and giving up real Chrome extensions.
2. **Weaker sandbox than Chrome** (gate 4): GPU and network code run in the unsandboxed app process by Qt's design.
3. **Security fixes arrive months late** (gate 12), on an old Chromium base.

What Qt does well: navigation and origin display, private-window storage, Mark of the Web, certificate errors, permission refusal, very little background traffic (once proxy auto-discovery is pinned off), a native bridge-free UI, a small download (131 MB zipped on Windows) and short builds. If CEF also fails its gates, that is the plan's stop condition, not a reason to accept these gaps.

## Not verified

- Anything needing a real Windows desktop: real camera/microphone/location prompts on real hardware (CI used Chromium's fake media devices; the refusal path is code-tested only), hover and animation feel, GPU rendering on real graphics hardware, SmartScreen.
- Proton Pass (no package); signed-in or real-world sites (local fixtures only).
- Playback of real DRM content (only CDM loading was checked); background behaviour beyond the ~45 s idle window per NetLog scenario.
- Windows' own (non-Chromium) network activity on behalf of the app, such as certificate revocation checks.
