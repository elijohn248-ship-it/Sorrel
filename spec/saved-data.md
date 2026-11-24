# Saved data

Spec 1.0.0. Fixtures: `state-decode`, `state-derived`, `settings-fields`, `settings-decode`, `archive-history-decode`, `history-behaviour`. Sources: `Models.swift`, `Support.swift`, `Data.swift`.

The profile folder holds plain JSON files. Each edition has **its own** profile folder (Mac: inside the `app.sorrel.browser` container; Chromium: `%LOCALAPPDATA%\Birch`, `~/.local/share/birch`). An edition never opens another edition's folder directly; moving data across is an explicit, validated import (dual-engine-plan.md ▸ Data and safety rules).

## Common encoding rules

- **Dates**: ISO 8601 strings, UTC, written without fractional seconds (`"2026-11-20T09:30:00Z"`). Reading accepts fractional seconds and offsets (`…00.250Z`, `…+01:00`); a number is an error.
- **Ids**: UUID strings, written uppercase. Reading accepts lowercase. Anything that isn't a UUID is an error.
- **Unknown keys are ignored** everywhere, and dropped on the next save (Birch does not round-trip them).
- **A file that fails to decode is not partially used.** Each file has its own fallback (below).

## state.json (spaces, tabs, windows)

Written by `Store.saveNow` (pretty-printed, keys unsorted) 0.8 s after any change and on quit. `fixtures/state-decode.json ▸ written_by_birch` is a complete file with every kind of item.

```
AppState  { version: Int (1), spaces: [Space], favorites: [Item], currentSpaceID: UUID,
            windows: [BrowserWindowState]? , sidebarCollapsed: Bool, sidebarWidth: Double }
Space     { id, name, icon (an emoji), theme: Theme, pinned: [Item], today: [Item],
            profileID: UUID?, selectedID: UUID? }
Item      { id, isFolder: Bool, title: String, customTitle: String?, url: String?, pinnedURL: String?,
            children: [Item], expanded: Bool, lastActive: Date, split: SplitLayout? }
SplitLayout { stacked: Bool, fractions: [Double] }
Theme     { colors: [String], angle: Double, intensity: Double, grain: Double?, brightness: Double? }
BrowserWindowState { id, currentSpaceID, selections: [UUID: UUID] }
```

Required vs optional is exactly as above: **every non-optional key is required**, even ones with an obvious default. Missing `sidebarWidth`, `sidebarCollapsed`, `version`, an item's `expanded`/`children`/`isFolder`/`title`/`lastActive`, a split's `stacked`/`fractions`, a space's `icon`/`pinned`, or a theme's `intensity`/`angle` makes the whole file unreadable (fixture cases show each). Optional keys may be absent or `null`.

- **Item kinds**: a tab (`isFolder` false, no `split`), a folder (`isFolder` true; `children` are tabs, folders or splits; only in `pinned`), a split (`split` set; `children` are 2–4 tabs; see split-view.md). Favorites are single tabs only.
- `pinned` = the space's pinned area (folders allowed); `today` = unpinned tabs, newest at the top.
- `pinnedURL` = where a pinned tab or favorite returns when closed. Set when an item becomes pinned/favorite, cleared when it moves to `today`.
- `customTitle`: the person's rename; `displayTitle` = non-empty customTitle, else title, else "Folder" for folders, else the URL's host, else "New Tab"; a split shows its panes' titles joined by `" | "` (`state-derived`).
- `fractions`: each pane's share. Used only when its count equals the pane count and all are > 0; then normalized to sum 1; otherwise equal shares (`state-derived ▸ SplitLayout.normalized`).
- `profileID`: nil = the shared login store; a UUID = this space keeps separate cookies/logins. The UUID names an **engine store** (WebKit `WKWebsiteDataStore(forIdentifier:)`); the setting is portable, the data inside is not.
- `selections` in a window record is a **flat array of alternating keys and values** (`[spaceID, tabID, spaceID, tabID, …]`), not a JSON object (an object fails to decode). Pair order is unspecified; compare as a set of pairs.
- Bundled pages are saved as `birch://<name>`. Old `sorrel://` and `drift://` addresses load the same page and are saved back as `birch://` (`state-derived ▸ BundledPage`).

### On launch

- Decodes, and `spaces` is non-empty → use it.
- Otherwise (decode error, or no spaces) → copy the file to `state.unreadable-<unix seconds>.json` in the profile and start a **fresh profile**: one space "Home", icon 🏠, theme preset 0, one unpinned tab `birch://welcome` titled "Welcome to Birch", selected; no favorites (`state-derived ▸ fresh profile seed`). Never silently discard a file.
- `windows` non-empty → one window per record. Otherwise one window from `currentSpaceID` and each space's `selectedID`.
- A window whose `currentSpaceID` names no space shows the first space. Selections that point to a missing tab, or to a tab in a different space (favorites excepted), are dropped. A tab already shown in another window is never shown twice (the later window gets no selection).
- When saving with windows open: `windows` = every open normal window, `currentSpaceID` and each space's `selectedID` = the focused window's. Private windows are never saved.

### Not saved (runtime only)

Live page objects, extension tab ids, the parent link (rebuilt from nesting), the window a tab is in, and a sleeping tab's back/forward history and scroll position (WebKit `interactionState`, kept in memory only). **No opaque engine state is ever written to state.json**, and none may be added to a shared format.

## settings.json

Written pretty-printed with sorted keys. `settings-fields.json` lists all 31 fields with their Swift type, the default for a new profile, and what an old file without the key decodes to. In short: **every missing field takes its default, except `settingsVersion`, which reads as 1**.

Loading (`settings-decode.json`):

- Missing file → defaults, written out.
- A `null` value → that field's default. An integer where a Double is expected is fine. An empty list stays empty (not the default list).
- **One field of the wrong type, or invalid JSON → the whole file is replaced by defaults** (Birch's current behaviour; an edition must not keep partial values either).
- Migration: `settingsVersion` < 2 → if `sidebarHoverEdgeWidth` is exactly 8 it becomes 14; then version 2 is written back. A version-2 file keeps 8.

| Field | Default | Portable? |
|---|---|---|
| `searchEngineName`, `searchEngineURL` (`%s` = query) | DuckDuckGo, `https://duckduckgo.com/?q=%s` | yes |
| `stripTrackingParameters` | true | yes |
| `httpsFirst` | true | yes |
| `blockAds` | true | yes (policy; each engine implements blocking its own way) |
| `blockCookieNotices` | false | yes (policy) |
| `blockingDisabledSites` | [] | yes |
| `sleepTabsAfterMinutes` (0 = never) | 120 | yes |
| `archiveAfterHours` (0 = never) | 24 | yes |
| `removeHistoryAfterDays` (0 = never) | 0 | yes |
| `emptyCacheOnQuit` | false | yes |
| `searchSuggestions` | false | yes |
| `controlTabUsesRecency` | true | yes |
| `peekLinksFromAllTabs`, `peekLinksFromPinnedTabs`, `peekExcludedSites` | true, true, 14 search sites | yes |
| `externalLinksOpenInMiniWindow` | true | yes |
| `sidebarHoverEdgeWidth`, `sidebarOvershootReach`, `sidebarHideDelay`, `sidebarExitTolerance`, `sidebarAnimationDuration`, `sidebarHoverWhenInactive` | 14, 90, 0.12, 14, 0.2, true | yes (points/seconds) |
| `checkForUpdates`, `installUpdatesAutomatically` | true, false | yes (each edition has its own feed) |
| `autoUpdateBlocker` | true | yes (meaning: keep the built-in uBlock Origin Lite current) |
| `settingsVersion` | 2 | yes |
| `fallbackBrowser` | "Helium" | **edition-specific** (an app name on this OS) |
| `extensionStates`, `extensionGrants`, `extensionApproved` | {} | **edition-specific** (keyed by the engine's extension id; grants are WebKit permission strings `perm:`/`match:`/`url:`) |

Settings UI choices (for matching menus): archive Never/12 h/24 h/7 d/30 d (0/12/24/168/720); sleep Never/30 min/1 h/2 h/6 h (0/30/60/120/360); remove history Never/1 d/1 wk/2 wk/1 mo/1 yr (0/1/7/14/30/365). Peek menu: "From every tab" = all true; "From pinned tabs and favorites only" = all false, pinned true; "Never" = both false.

## archive.json

A JSON array of `{url, title, spaceID, date}` (date = when archived), newest first, at most 500 (older ones dropped). All four keys required. Only http(s) tabs are recorded (tab-lifecycle.md). Unreadable → treated as empty. Portable.

## history.json

A JSON array of `{url, title, visits, last}`, all required, unordered. One entry per exact URL string. Only `http`/`https` pages are recorded, on page load finish, never from private windows. A visit adds 1 and sets `last` to now; an empty page title keeps the old title. Saved 3 s after a change; when more than 20,000 pages exist, the newest 15,000 are kept. Unreadable → empty. Portable. Behaviour fixtures: `history-behaviour.json` (list order, search ranking, the command bar's "top host match", import merging, removal by site/date).

## bangs.json (custom bangs)

A JSON array, created as `[\n]` if missing and never rewritten. Same entry format as the bundled list (Kagi's): `t` trigger (required), `u` URL template (required; `{{{s}}}` or `%s` marks the query), optional `s` name (default: the trigger), `d` domain, `ts` extra triggers, `fmt` flags (only `url_encode_space_to_plus` changes behaviour). Custom entries override bundled ones with the same trigger. Invalid JSON → ignored (bundled bangs only). Portable. Behaviour: address-and-search.md.

## Other files (not covered by fixtures)

`keybindings.json` / `keybindings.default.json`: keybindings.md. `zoom.json` (`{host: level}`, 1 omitted), `downloads.json`, `blocker.json` + `rulelists/`, `Extensions/`, `BundledExtensions/`, `Updates/` and `favicons/` are edition-specific or engine output; don't share them.
