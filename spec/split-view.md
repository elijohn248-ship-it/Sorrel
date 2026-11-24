# Split view

Spec 1.0.0. Fixture: `split-view` (one sequence of 28 steps on the real store; run them in order). Source: `Models.swift` (Store split functions, `SplitLayout`), `MainWindow.swift`.

## Model

A split is one sidebar item whose `children` are **2–4 tabs** (`SplitLayout.maxPanes` = 4), with `stacked` (false = side by side, true = top to bottom) and `fractions` (see saved-data.md). It moves, pins, archives and saves as one unit. The selected tab of a space may be a pane: that is the **focused pane**, which the address box, ⌘L, ⌘W, find and extensions act on. Every pane of the selected split is on screen (all have pages).

## Rules

- **Making** `makeSplit(base, other, otherFirst, stacked, focus)`: refused (nothing changes) if the two are the same tab, either is a folder/split, either is a favorite, either isn't in a space, or either is on screen in another window. If `base` is already in a split: `other` joins it **right after base** (before it with `otherFirst`), refused when the split already has 4; if both are already in the same split only `stacked` changes. Otherwise a new split takes `base`'s place in its list with `[base, other]` (or `[other, base]`). `other` leaves wherever it was first. Fractions reset to equal whenever panes are added or removed. Focus goes to `focus`, else `other`. Pinned state follows the split: panes of a pinned split get `pinnedURL`, unpinned panes lose it.
- **Selecting a split** focuses its most recently used pane.
- **Closing a pane** of an **unpinned** split closes that tab (reopenable with ⌘⇧T). Of a **pinned** split: the pane's page is torn down and its address returns to `pinnedURL`; if the split is on screen the pane reloads at once, otherwise it sleeps. Focus moves to the most recently used other pane.
- **One pane left** → the split dissolves into that tab, in the split's place.
- **Remove from Split View**: the tab goes right after the split.
- **Separate** (⌃⇧-): every pane becomes its own tab in the split's place, in order.
- **Pin/unpin a pane** pins/unpins the whole split. Favoriting a pane takes it out of the split first. A split can never become a favorite (the move is ignored). × on a pinned split (`closeAndUnpin`) removes the whole split from the sidebar; ⌘⇧T reopens its tabs one by one, unpinned.
- **Resizing**: `setSplitFractions` is ignored unless the count matches the panes. **Rotate** moves the first pane (and its fraction) to the end. **Focus next/previous pane** (⌃⇧] / ⌃⇧[) wraps.
- Archiving: a split is archived only when all panes are stale (tab-lifecycle.md).

## Ways in (UI, not fixtures)

⌃⇧= (command bar picks a tab to open beside the current one), right-click a tab ▸ Open in Split View, drag a tab onto the page's left/right/top/bottom edge (left/top put it first; top/bottom make it stacked), drop a tab onto a split row, the split button on Peek. Refusals show a toast: "Favorites can’t go in a split view", "A split view holds up to 4 tabs", or "Those tabs can’t be split".
