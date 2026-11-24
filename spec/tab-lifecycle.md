# Tab sleep, archive and memory pressure

Spec 1.0.0. Fixture: `tab-lifecycle`. Sources: `Models.swift` (Store.sleepIdleTabs, sleepTabs, canSleep, archiveStaleTabs), `Cleanup.swift` (relieveMemoryPressure, freeMemory), `App.swift` (timers).

Every tab has `lastActive`: set when it is selected and when a page finishes loading. Selecting one pane of a split also refreshes the other panes (they are on screen).

## Sleeping

A sleeping tab stays in the sidebar; its engine page is released and its back/forward history and scroll position are kept **in memory only** (never saved, never shared between editions). Selecting it reloads it with that history.

**Who may sleep** (`canSleep`, all must hold):
- it has a live page;
- it is not on screen in any window (the selected tab, or every pane of the selected split);
- no media is playing (muted playback counts), not in Picture in Picture, not capturing camera or microphone, not loading;
- its current address is http(s) or empty (extension pages and bundled pages never sleep).

**When:**
- **Maintenance timer** every 5 minutes: tabs idle longer than `sleepTabsAfterMinutes` sleep. 0 = never.
- **Memory pressure** (OS warning/critical): first drop disposable caches (favicons in memory, URL response cache) even if sleeping is off; then, if `sleepTabsAfterMinutes` > 0, sleep tabs idle longer than `min(setting, critical ? 1 : 5)` minutes. Warning+critical together counts as critical. Normal pressure does nothing. Repeats are harmless.
- **Free Up Memory** (`tabs.sleepNow`) and "Put Other Tabs to Sleep": every eligible tab now, whatever its age, plus the engine's memory caches.

Fixture idle times: a 0.1, b 0.5, c 2, d 4, e 6, f 200 minutes. Example: warning with a 120-minute setting sleeps e, f (> 5 min); critical sleeps c–f (> 1 min); a 3-minute setting under warning sleeps d–f.

## Archiving

- Runs 20 s after launch and every 5 minutes, with `archiveAfterHours` (0 = never; the manual command `archive.now`, "Archive Unused Tabs Now", uses 24 when the setting is 0).
- Only top-level entries of each space's **unpinned** list are candidates. Pinned tabs, tabs in folders and favorites are never archived.
- A tab goes when idle longer than the setting, not selected in its space in the current window, and not on screen in any window. A split goes only when **every** pane qualifies; then all panes go.
- Each archived http(s) tab is added to the top of archive.json (`url`, display title, space id, now); other addresses (bundled pages) are removed from the sidebar without a record. The archive keeps 500 entries.
- Restoring opens a new unpinned tab in the original space (or the current one if that space is gone) and removes the entry.

Fixture: with a 24-hour setting, `old` and the split `s1|s2` are archived (3 records), `old-birch` disappears unrecorded, and the selected, recent, pinned, folder, favorite and partly-recent split stay.

## How to test in an edition

Run the fixture's cases against the edition's store with pages created but not loaded (or loaded from local fixtures), setting `lastActive` explicitly; expect the same `asleep`/`awake` lists and counts. Deliver a synthetic pressure event to the real handler, as the Mac's `SORREL_MEMORYTEST` does.
