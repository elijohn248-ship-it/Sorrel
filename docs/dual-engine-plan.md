# One Birch, two browser engines

Planning checkpoint: 2026-11-19. No second engine has been implemented.

## What the owner approved

Birch will keep its WebKit edition and gain a Chromium edition, with availability beyond the Mac. Both should feel like the same browser: the same spaces, sidebar, tabs, commands, settings and privacy expectations wherever the platforms allow. Start with two builds; switching engines inside a running browser is outside the initial scope.

The owner approved replacing the WebKit-only rule. That approval does not authorize weaker protections, paid services, new runtime network destinations, changes to protected build/security/updater files, access to real profiles, merging, pushing or publication. The existing daily browser remains supported throughout.

## The recommendation in plain language

Share the rules for how Birch behaves. Put a small translation layer between those rules and each website engine. Keep operating-system work, such as windows and file pickers, separate too.

First prove that a Chromium foundation can meet the important requirements, especially protection from hostile websites, blocking and Proton Pass. Then gradually connect the existing Mac browser to shared controls. Avoid rewriting the whole interface before those difficult parts work.

Investigate CEF (Chromium Embedded Framework) first as a prototype candidate. It embeds Chromium in desktop apps and has distributions for Mac, Windows and Linux. This makes it a plausible starting point, not a selected production dependency or evidence of extension/security parity. [CEF usage documentation](https://github.com/chromiumembedded/cef/blob/master/docs/general_usage.md)

Keep the current AppKit interface for the first Mac experiment. Before porting the full interface, compare a shared desktop interface with native interfaces driven by one shared browser core. The choice must account for both WebKit and Chromium surfaces, accessibility, keyboard input, smooth motion and maintenance. No new interface framework or shared-core language is selected yet.

## Proposed device support

These are planning targets, not announced support. Only the existing Apple Silicon Mac WebKit build is implemented today. Exact OS versions and processor support for new builds need testing.

| Device | WebKit edition | Chromium edition | Planned order |
|---|---|---|---|
| Mac | Keep the existing WKWebView edition | First isolated prototype, then a matching edition | First engine comparison |
| Windows | Research only; no release commitment | Desktop target, subject to the prototype gates | Early build proof, then full features |
| Linux | Candidate using WebKitGTK; separate integration and extension assessment needed | Desktop target, subject to the prototype gates | Early build proof; WebKit exploration after engine foundation |
| Android | No selected supported WebKit route | Separate mobile feasibility study | After desktop foundation |
| iPhone/iPad | Candidate using Apple's WebKit; distribution feasibility unresolved | No initial commitment | Separate mobile decision |

WebKit is a family of platform ports, not one package that runs everywhere. Its documentation identifies Apple ports and Linux ports with regular releases/security advisories; its Windows port serves development and testing. That is why a production Windows WebKit edition is not promised. [WebKit port documentation](https://docs.webkit.org/Ports/Introduction.html)

Do not assume the desktop extension host carries over to Linux or mobile. A WebKitGTK rendering surface does not establish support for Birch's WKWebExtension-based extension implementation.

Apple's documented EU alternative-engine route requires specific entitlements and ongoing qualification. It is not an ordinary drop-in route for a worldwide Chromium iPhone edition. Mobile distribution must also fit the owner's no-paid-account rule; no paid account or entitlement request is authorized here. Recheck requirements when mobile work begins. [Apple alternative browser engines](https://developer.apple.com/support/alternative-browser-engines/)

## What the current code tells us

| Existing area | Evidence | Work needed |
|---|---|---|
| Pages and navigation | `Web.swift`: `Page` owns `SorrelWebView`; `Engine` implements WebKit delegates | Engine-neutral page controls and events, with WebKit behavior preserved |
| Spaces and tabs | `Models.swift`: saved data includes spaces, items, splits and windows; runtime items also own `Page`, `ExtensionTab` and opaque sleeping state | Separate durable browser data from engine runtime objects; keep old files readable |
| Interface | `MainWindow.swift`: content cards/find bar take WKWebView; sidebar, commands and themes use AppKit | Shared behavior plus engine surfaces and platform window/input adapters |
| Settings and themes | `Support.swift` combines Codable settings with AppKit colors/views | Separate portable settings/theme values from Mac drawing without unrelated cleanup |
| Extensions and blocking | `Extensions.swift` uses WKWebExtension; `Blocker.swift` produces WKContentRuleList rules | Separate engine implementations meeting the same permission/blocking policy |
| Packaging and updates | `Package.swift` declares macOS 15.4; the updater uses macOS XPC | New platform packaging and update implementations; protected-file review first |

An engine interface alone will not make this AppKit application cross-platform. Likewise, adopting Chromium alone will not supply Birch's interface or prove Chrome extension compatibility.

## How the pieces should fit

| Piece | Its job | What belongs outside it |
|---|---|---|
| Shared browser core | Spaces, tab/folder order, pinning, window selections, commands, portable settings, safe persistence and policy decisions | WKWebView, CEF objects, native colors/windows and engine-specific cookie files |
| Engine implementation | Create/close pages; navigate; report committed URL/loading/title; manage isolated website storage; enforce engine-side permissions, downloads and blocking | Independent copies of space/tab rules or arbitrary access from websites to app commands |
| Platform interface and services | Draw Birch, host the engine view, handle keyboard/accessibility, file pickers, notifications and installation | Security decisions that silently differ from the shared policy |

Start the page controls with load/back/forward/reload/stop, committed URL and loading changes, focus/zoom/find, new-page requests, close and teardown. Add typed permission/download/error events as the real implementation requires them. UI labels must follow the committed navigation and real origin, not a page-provided display string.

Report supported capabilities explicitly. A missing capability must be visible and documented rather than silently bypassing a protection. A shared security policy must be enforced inside each engine at the relevant boundary; it cannot just be a checkbox in the interface.

Do not add a website-to-app command bridge to share the interface. Native engine callbacks do not require giving arbitrary page JavaScript access to the app. Preserve the narrow, reviewed extension companion-site rules.

## Foundation options to compare

| Option | Why consider it | What needs proving |
|---|---|---|
| CEF with Birch's own browser core/interface | Embedding approach with desktop distributions; preserves freedom to host native surfaces | Sandboxing, Mac App Sandbox compatibility, safe self-signed packaging, extension APIs, blocking, update workload and real Proton Pass behavior |
| Qt WebEngine and a shared Qt interface | Potential shared desktop interface and Chromium integration | A maintained WebKit integration for the other edition, extension gaps, Mac protections, motion/accessibility and dependency/update cost |
| A full Chromium fork | More direct access to Chromium's browser implementation | Much larger build/patch/security-update responsibility, and a second integration path for the WebKit edition |
| Electron | Desktop framework to compare for completeness | Documented partial extension compatibility; would still need a WebKit integration and interface/security work |

CEF's Chromium subprocess sandbox and Birch's macOS App Sandbox are different protections. CEF documents platform-specific setup; it does not prove our existing whole-app confinement works unchanged. Failure to retain required protection is a stop condition, not permission to use `--no-sandbox` or drop App Sandbox. [CEF sandbox setup](https://chromiumembedded.github.io/cef/sandbox_setup)

CEF packaging also has executable-specific signing and entitlement requirements. Inspect the pinned release before proposing exact protected-file changes. Never apply an example's entitlement list to Birch automatically. [CEF signing documentation](https://chromiumembedded.github.io/cef/code_signing.html)

Qt 6.10 documents local Manifest V3 extension installation/loading, with no loading into off-the-record profiles. That is a candidate capability, not proof that Proton Pass, uBOL or Chrome Store installation work. [Qt extension manager](https://doc.qt.io/qt-6.10/qwebengineextensionmanager.html)

Electron explicitly does not aim for arbitrary Chrome Store extension compatibility, making it a weaker starting candidate for this browser's extension priorities. [Electron extension support](https://www.electronjs.org/docs/latest/api/extensions)

A full Chromium Mac build documents Xcode and additional tooling, beyond this repository's Command Line Tools workflow. Do not start a large source checkout or install a new toolchain as part of this planning milestone. [Chromium Mac build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)

## Milestones and chat-sized handoffs

### 1. Review this foundation plan — this checkpoint

Deliver the platform table, code reuse map, candidate comparison and acceptance gates. Record the approved two-engine direction in AGENTS.md and CLAUDE.md. No new engine dependency, profile migration or production behavior changes.

Owner review: desktop-first scope and the proposed CEF feasibility experiment. Final shared-core language and cross-platform interface choices remain open until the experiment supplies evidence.

### 2. Prove the risky Chromium requirements

Use an isolated prototype and fresh scratch data. Pin a maintained candidate version and record provenance/integrity, license notices, download size and build prerequisites before using it. Keep new dependencies out of tracked vendor code unless separately approved. Present exact build/plist/entitlement changes for approval before modifying protected files.

Prove two tabs, back/forward, origin display, page teardown, crash handling, separate normal/private storage and a download. Use local fixtures for routine checks and local extension fixtures for extension tests. Obtain an owner-approved local Proton Pass package if needed; do not read the real profile or download from the Chrome Store in tests.

Check permission denial/cancellation, HTTPS/certificate failure handling, blocking, file isolation, unsolicited external-app launches and background network activity. Test both subprocess confinement and whole-app confinement. Verify signed-in Proton Pass only with the owner's participation in a separate test profile when available; record unverified behavior honestly.

Exit: a written pass/fail report, proposed engine choice and exact unresolved blockers. Do not start a broad port if privacy, safe packaging or essential extension support fails. No security exception is pre-approved by this plan.

### 3. Establish shared controls and prove portability

Wrap a small existing WebKit path without behavior changes, then connect the same controls to the proven Chromium prototype. Choose shared-core language and desktop interface approach using actual build/integration evidence. Begin with tab/window state and navigation; do not abstract every engine API in advance.

Establish minimal Windows and Linux builds before porting the full feature set. Record required machines/toolchains and test access. A Mac compilation is not Windows/Linux verification. Free build services may be proposed but do not configure third-party uploads or publication without approval.

Exit: matching small browser behavior in both Mac engines and documented build/runtime results for the non-Mac prototypes. Split the extraction, second-engine hookup and each platform proof into separate chats if needed.

### 4. Bring over the Birch experience in groups

Suggested chat-sized groups: (a) spaces/favorites/pins/folders and restore, (b) command bar/shortcuts and sidebar, (c) Peek/splits/mini windows, (d) Library/downloads/import, (e) media/PiP/sleep/memory handling. Each group gets matching behavior checks in both editions and appropriate OS-specific checks. Preserve current WebKit regression coverage throughout.

Exit: a feature table with verified, unsupported and awaiting-owner states for each target combination; shared behavior has a common specification and fixtures, not separate drifting implementations.

### 5. Complete privacy, extensions and releases

Complete engine-specific blockers, extension hosting, permission UX and data clearing. Compare both engines against the same adversarial fixtures and allowed-network list. Review default built-in extensions, services and background requests; being Chromium-based does not establish Helium-level privacy. Test popular media formats and protected playback before promising streaming compatibility; resolve distribution constraints within the free-to-run rule.

Design separate artifact identities and update selection for OS/architecture/engine so an update cannot replace the wrong edition. Retain signature verification, tamper rejection, newer-build checks and failure recovery. The existing WebKit feed must not send users a Chromium build accidentally. No changes to updater files, production feeds or signing keys are authorized here.

Exit: reproducible packages and a release checklist for each tested target. The owner separately authorizes merging, pushing and publishing.

### 6. Decide mobile scope

Use the shared browser data/behavior where practical, with a touch interface. Reassess Android embedding choices, extension feasibility, background behavior, private storage, build tools and free distribution. Separately assess iPhone/iPad engines and distribution requirements. Phone sync remains the existing separate, opt-in project; this plan does not authorize relay work or deployment.

Exit: a reviewed mobile proposal before promising either engine on either phone platform.

## Data and safety rules for both editions

- Use separate application identities and profile directories for experiments/editions. Do not open one engine's cookie databases, extension state or opaque session data with the other engine.
- Share a versioned portable format for spaces, URLs, pinned tabs and compatible settings. Imports must be explicit, validated and compatible with older saved data. Test with synthetic fixtures; real-profile access still requires owner approval.
- Engine-specific back/forward snapshots and sleeping-page state stay engine-specific. Opening the same tab list does not imply shared sign-ins, shared live files or automatic sync.
- Private windows retain no browser-managed history, cookies or session restore on disk. Explicitly saved download files are user-chosen output; do not add private download metadata to persistent browser history. Test temporary/spool cleanup and interruption behavior separately.
- Keep engine versions/security patch status recorded. System WebKit updates and bundled Chromium updates need separate verification and maintenance plans. Never pin an obsolete engine to keep a feature working.
- Preserve current Mac Safari identity behavior. Review Chromium and other platform identities before implementation, including client hints; no broad Safari spoofing is selected here.

## What is verified at this checkpoint

Repository inspection confirms the Mac/AppKit/WebKit coupling described above. Official documentation supports the candidate/platform distinctions; these are research findings, not implementation tests. No CEF, Qt, Windows, Linux or mobile runtime has been installed or exercised in this milestone.

The handoff in PROGRESS.md records local build verification. Future chats should start by reading AGENTS.md, PROGRESS.md and this plan, checking the worktree/branch and continuing from the first incomplete milestone. Retain decisions and test evidence in the handoff; do not restart the architecture discussion without new evidence.
