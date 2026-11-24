# Control+Tab recency

Spec 1.0.0. Fixture: `tab-recency` (10 scenarios on the real store). Source: `Models.swift` (Store.cycleTab, endTabCycle, select, cycleOrder), `App.swift` (key monitor), `TabSwitcher.swift`.

## Inputs

- `ctrl+tab` → `tab.cycleNext`, `ctrl+shift+tab` → `tab.cyclePrevious` (remappable). A physical key press while Control is held is **holding**; letting go of Control, pressing a key without Control, a click that selects a tab, switching space, focus moving to another window, or opening a window **ends the cycle**. The same commands run from a menu or the command bar are not holding.
- **Eligible tabs** = the current space's `cycleOrder` (favorites, then pinned tabs depth-first through folders and splits, then unpinned tabs depth-first), minus tabs on screen in another window.
- **Recent list**: per window, in memory only. On every selection the previous and the new tab move to the front (new first). Private windows never contribute.

## Recency on (`controlTabUsesRecency`, default true)

When a cycle starts, its order is fixed: the selected tab, then the recent list, then every other eligible tab by `lastActive` (newest first, ties in sidebar order), duplicates and ineligible tabs removed. Each press moves one step (+1, or −1 with Shift), wrapping; the order stays the same while Control is held (tabs that disappear are skipped). So a quick press-and-release always returns to the previous tab, and repeated quick presses toggle between two tabs. A press without holding (menu) ends the cycle afterwards, so it also toggles. With one eligible tab nothing changes; with none, nothing happens.

## Recency off

Next/previous in `cycleOrder`, wrapping; no selection → the first tab.

`tab.next`/`tab.previous` (⌥⌘↓/↑, menus) always use sidebar order.

## Switcher

While a held cycle is active, a centred switcher shows the cycle order with the selected tab highlighted (`switcher` in the fixture; `[]` = hidden). Release keeps the selection and hides it; Escape hides it and leaves the current tab selected; clicking a tile selects it. Not shown for single-tab spaces or non-holding commands. No network, nothing saved.
