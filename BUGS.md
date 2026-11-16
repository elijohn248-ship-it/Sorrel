# Bugs

## Fixed

- **Proton Pass pop-up empty / no password list** (2026-11-15, branch `proton-popup`). Repro: Proton enabled, leave it idle 30 s+ (WebKit stops its background), then click its icon or open its settings. Expected: the pop-up shows Proton. Actual: an empty 50×50 box, or a background crash (`runtime.onUpdateAvailable` undefined) that left every later pop-up empty. Cause: when a pop-up or an extension page restarts a stopped service-worker background, WebKit starts it badly; fix: Sorrel wakes the background itself first (`Extensions.wakeBackground`, used by the toolbar button, its shortcut, and any extension page loading in a tab).
