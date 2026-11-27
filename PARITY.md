# Parity: changes another edition still needs

Owner rule (2026-11-25): **every change goes to every edition of Birch**, unless it is specific to one platform. The rule itself is in `CLAUDE.md` ▸ Every change goes to every edition. This file is the list of changes made in this repository (Mac WebKit edition, Chromium edition for Windows and Linux) that another edition has not received yet.

The iPhone/iPad app keeps the same list for its own changes in `~/birch-mobile/docs/PARITY.md`. **A catch-up session reads both files for rows that name its edition.**

## How to use it

- A normal session changes one edition and adds a row here, in the same commit, for every other edition that needs it.
- Catch-up sessions (one per edition, when the owner asks) clear an edition's rows: delete its name from the row (and the row once no edition is left), in the same commit as the catch-up.
- Security and privacy fixes don't wait here: they go to every edition at once.
- Editions: **Mac** (`Sources/`), **Chromium** (`chromium/`; one codebase, verified on both Windows and Linux in CI), **iOS** (`~/birch-mobile`, iPhone and iPad), **Android** (not started; until it exists it gets changes through `spec/`, see the rule, so it never gets rows here).
- Not a row: a feature an edition doesn't have yet (the Chromium wave 3 work, for example). When that feature is ported, it is ported as it is then, including every later fix. Only changes to something an edition already has are owed.

## Owed

| Date | Change (branch / commit) | Still needed by | Why not done yet / what's left |
|---|---|---|---|
| 2026-11-27 | `cx-commandbar`: the Mac fixture `keybindings` (and `Commands.shared.all` listing) predates `find.next` / `find.previous` (Cmd+G, added with the find bar). Regenerate the fixtures with `SORREL_SPECDUMP` and bump the spec to 2.1.0 (new cases only), then drop the two test filters in `chromium/tests/spec/commandbar_spec.cc`. | **Mac** (regenerate fixtures) | needs a Mac session; the Chromium edition ignores those two for now |

Prompt 5 (`cx-spaces-sidebar`, 2026-11-25) ports existing Mac space/sidebar behavior. Its overlay shutdown, address focus, engine storage and native cursor fixes are specific to CEF/HTML UI; they create no owed change in Mac or iOS. Shared spec behavior was preserved.

The Linux test updater (`codex/linux-test-updater`, 2026-11-25) is platform/channel-specific: Debian packaging, polkit authorization and Linux sealed files. Mac/iOS updates are unchanged; future Windows updater work can reuse the signed feed format when that feature is ported. No parity debt is created.

Linux sidebar polish (`codex/linux-sidebar-polish`, 2026-11-26) corrects Chromium HTML gradient/grain rendering and clarifies its existing auto-hide button. Mac/iOS do not use this HTML overlay; palettes, theme fixtures and saved mode behaviour are unchanged. No parity debt.

Managed maximize and fullscreen coverage is specific to Linux Chromium CI. Openbox supplies X11 window management for the sidebar test, which checks the native window geometry and windowed size restoration.

Command bar, bangs and shortcuts (`cx-commandbar`, 2026-11-27) is new Chromium work, not a change to the Mac or iOS. Its Windows/Linux shortcut table is platform-specific (Ctrl for Cmd, Alt for the Mac's Control strokes); the resolver, bangs, keybindings grammar and recency behave exactly as the Mac fixtures say (nothing owed).
