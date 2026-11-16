# Bugs

## Fixed

### Centered command bar moves while typing (fixed 2026-11-15, branch `command-bar`)
- **Repro:** ⌘T, type something that fills several suggestion rows.
- **Expected:** the line you type on stays where it opened; the list grows below it.
- **Actual:** the whole bar re-centered as rows appeared, so the text field slid upward on every keystroke.
- **Cause:** the panel was pinned by its vertical center. It is now pinned by its top edge, placed from the window height only (`CommandBar.positionCentered`).
