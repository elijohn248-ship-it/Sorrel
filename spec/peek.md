# Peek (link preview)

Spec 2.0.0. Fixture: `peek` (every case is a transcription of `Engine.shouldPeek` and the link branch of `Engine`'s navigation policy in `Web.swift`, because WebKit's navigation action object can't be built outside WebKit; the site checks inside are the real `Site` functions with real settings).

## Decision, in order

For a navigation in a tab's main frame:

1. A scheme other than http, https, about, blob, data, file, javascript (or an extension page) → **ask to open another app** (security-invariants.md). Not a preview.
2. Not a **user link click** (typed, redirect, form submit, script `window.open`, reload) or not http(s) → **navigate** normally.
3. Cmd-click or middle-click → **background tab** (from a private window: a new private window instead).
4. The page is not a sidebar tab (mini window, private window, Peek itself) → navigate.
5. Shift-click → **peek**, regardless of settings or sites.
6. The page's host is on the excluded list (`peekExcludedSites` plus the search engine's host, matched with `Site.host(_:isIn:)`) → navigate. Search results open in the tab.
7. Settings: `peekLinksFromAllTabs`, or `peekLinksFromPinnedTabs` and the tab is pinned or a favorite; otherwise navigate.
8. "Here" = the page's host, or if the page has no address yet, its `pinnedURL`'s host. No "here" or no link host → navigate.
9. Different website (`Site.same` false, i.e. different `Site.key`) → **peek**; same website → navigate.

Links with `target=_blank` go through the same decision (WebKit's new-window callback); script-opened windows never peek, so sign-in pop-ups work.

## The preview

- Opens over the current page in the same window, using the source tab's login store (its space's `profileID`). One at a time: a new preview replaces the old.
- Close: Esc (when the command bar is closed), the × button, or clicking the dimmed area. Expand (⌘O, `mini.expand`): becomes a new unpinned tab at the top of the current space's list, keeping the live page. Split (`split.peek` button): opens beside the current tab as a split.
- Previews are not tabs: no sidebar entry, no session restore.
