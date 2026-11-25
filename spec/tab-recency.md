# Control+Tab recency

Spec 2.0.0. Fixture: `tab-recency` (12 scenarios on the real store). Source: `Models.swift` (Store.cycleTab, endTabCycle, select, cycleOrder), `App.swift` (key monitor), `TabSwitcher.swift`.

## Inputs

- `ctrl+tab` → `tab.cycleNext`, `ctrl+shift+tab` → `tab.cyclePrevious` (remappable). A physical key press while Control is held is **holding**; letting go of Control, pressing a key without Control, a click that selects a tab, switching space, focus moving to another window, or opening a window **ends the cycle**. The same commands run from a menu or the command bar are not holding.
- **Eligible tabs** = the current space's `cycleOrder` (favorites, then pinned tabs depth-first through folders and splits, then unpinned tabs depth-first), keeping only **open** tabs (a loaded page, or the selected tab), minus tabs on screen in another window. Tabs never opened since launch, pinned tabs or favorites put to sleep, and idle-slept tabs are left out, so Control+Tab never wakes a sleeping tab. In the fixture a tab is loaded once visited or when listed in `loaded_without_visit` (opened in the background); `close` on a pinned tab puts it to sleep.
- **Recent list**: per window, in memory only. On every selection the previous and the new tab move to the front (new first). Private windows never contribute.

## Recency on (`controlTabUsesRecency`, default true)

When a cycle starts, its order is fixed: the selected tab, then the recent list, then every other eligible tab by `lastActive` (newest first, ties in sidebar order), duplicates and ineligible tabs removed. Each press moves one step (+1, or −1 with Shift), wrapping; the order stays the same while Control is held (tabs that disappear are skipped). So a quick press-and-release always returns to the previous tab, and repeated quick presses toggle between two tabs. A press without holding (menu) ends the cycle afterwards, so it also toggles. With one eligible tab nothing changes; with none, nothing happens.

## Recency off

Next/previous among the open tabs of `cycleOrder`, wrapping; no selection → the first open tab.

`tab.next`/`tab.previous` (⌥⌘↓/↑, menus) always use sidebar order over every tab, sleeping ones included.

## Switcher

While a held cycle is active, a centred switcher shows the cycle order with the selected tab highlighted (`switcher` in the fixture; `[]` = hidden). Release keeps the selection and hides it; Escape hides it and leaves the current tab selected; clicking a tile selects it. Not shown when only one tab is open (single-tab spaces included) or for non-holding commands. No network, nothing saved.
