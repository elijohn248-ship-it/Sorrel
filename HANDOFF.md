# Handoff: cx-spaces-sidebar (prompt 5), 2026-11-25

Delete this file before the branch is merged.

**Task:** docs/chromium-agents.md ▸ Prompt 5 (Spaces, favorites, sidebar), plus ▸ Shared rules and ▸ Change of order. Rules: AGENTS.md, CLAUDE.md ▸ Chromium edition. The stricter rule wins.

**Where things are**
- Worktree: ~/sorrel-cx-spaces-sidebar, branch `cx-spaces-sidebar`. It already contains main, and main includes chromium-ui-host (the HTML UI host and UI-only channel).
- Everything is committed. The branch is pushed up to 3941df4. This file is a local-only commit.
- Commits on top of main:
  - bcf6295 WIP from Codex: core/theme.*, core/lifecycle.*, store/sidebar/channel changes, ui/sidebar/features.cc, lifecycle_host.cc, hooks/sidebar_hooks.cc, unit/sidebar_store_tests.cc.
  - f7ff955: the spec runner covers the tab-lifecycle archive case, plus a fix to on_screen/playing_media parsing.
  - 715bbc0: sidebar store tests and the sidebar app scenario are wired into CMake, the harness and .github/workflows/cx-spaces-sidebar.yml.
  - 1260bab: the sidebar overlay is destroyed before the window closes.
  - 3941df4: a diagnostic log of which page blocks window close.

**Current state: CI fails in "App tests" on Windows and Linux**
- Failing runs: 45734210088 (715bbc0) and 45736392089 (1260bab).
- Likely cause: a window doesn't finish closing, because a page/browser (probably the sidebar overlay's) never completes its close.
- Run 45740556011 (3941df4, the diagnostic) was queued at handoff. Read its results-linux/results-windows logs for the "blocks window close" line first.
- Remove the diagnostic log once it's fixed.

**Still to do (prompt 5)**
1. Make App tests green on both OSes, with every earlier check still passing: shell, channel isolation 42/42, spec, NetLog.
2. Check that the theme, theme-math and tab-lifecycle spec fixtures all pass.
3. Finish what's missing among: spaces UI (switching by click/shortcut/swipe), favorites, pinned/folders, drag reorder, the pinned/hidden/hover-peek sidebar modes with their settings, session restore, archiving and sleeping.
4. Update CLAUDE.md ▸ Chromium edition (your own subsection) and add a PROGRESS.md handoff line.
5. Report: what CI verified, screenshot artifact names, owner checks for Zorin OS 18.1 (hover peek, space switching, swipe feel), and what wasn't verified.

**Limits**
- Push only `cx-spaces-sidebar`; no main, tags or force-push. Don't merge into main: the owner decides.
- No `--no-sandbox` or anything else that weakens the sandbox. No new network destinations.
- New UI-only channel messages need typed arguments, validated in the browser process. Web content, frames, pop-ups, extensions and private pages must never reach the channel.
- Zero warnings in Birch's code. Tests use a fresh BIRCH_HOME.
- Don't touch the Mac app or run ./build.sh.
- Never print or commit anything from ~/.config/sorrel. Read the GitHub token only inside a command.
- Use few tokens: wait for CI once instead of polling, and read only the failing log tails.

**After prompt 5:** the order is one step at a time to save tokens: Prompt 6 (command bar) -> 8 (Peek/split/Library) -> 7 (privacy/extensions). Each gets its own worktree from main, after the previous step is merged.
