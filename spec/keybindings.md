# Keyboard shortcuts and commands

Spec 1.0.0. Fixture: `keybindings` (its top-level `commands` lists all 87 command ids and titles). Source: `Commands.swift`.

## Commands

Every action has a stable id (`tab.new`, `space.next`, `split.add`, …). Menus, the command bar and shortcuts all run commands by id. Editions use **the same ids** for the same actions, so keybindings.json files and docs carry over.

## Stroke grammar

- A stroke is modifiers and a key joined with `+`: `cmd+shift+t`. Case-insensitive.
- Modifier names: `cmd`/`command`/`meta`/`super` → `cmd`; `ctrl`/`control` → `ctrl`; `alt`/`opt`/`option` → `alt`; `shift`. Any other modifier makes the stroke invalid (ignored).
- Normalized order: `ctrl`, `alt`, `shift`, `cmd`, then the key (`Cmd+Shift+T` → `shift+cmd+t`).
- Key aliases: `return` → `enter`, `esc` → `escape`, `plus` → `+`, `backspace` → `delete`. `cmd++` is the plus key. Named keys: `tab enter escape space delete left right up down`; others are the character typed without modifiers.
- A **chord** is strokes separated by spaces (`cmd+k cmd+t`); extra spaces are ignored; invalid strokes inside a chord are dropped. The second stroke must come within 1.5 s; a stroke that doesn't continue the chord is tried on its own.
- Mac display uses ⌃⌥⇧⌘ and ⇥ ↩ ⎋ Space ⌫ ← → ↑ ↓; other keys uppercase (`pretty` in the fixture).

**Platform mapping (Chromium edition):** the grammar and file are shared; the Mac's `cmd` is the primary modifier. The Windows/Linux edition decides and documents how `cmd` maps (normally Ctrl) and must keep Control+Tab as `ctrl+tab` (tab recency), avoiding collisions created by the mapping. Mac files are not copied verbatim to other platforms without that mapping.

## Files

- `keybindings.default.json`: rewritten at every launch with all default bindings (sorted object, stroke → command id). The fixture's first case holds the exact content: 58 bindings, including `ctrl+1…9` → `space.1…9` and `cmd+1…9` → `tab.select.1…9`.
- `keybindings.json`: the person's changes, created as `{\n}\n` if missing. `{"stroke": "command"}` adds a binding; `{"stroke": null}` or `""` removes the default on those keys. A user entry **replaces any default on the same normalized keys** (`shift+cmd+t` replaces the default `cmd+shift+t`). Invalid JSON → defaults only.
- Settings ▸ Shortcuts writes the user file: giving a command a new stroke removes its other user strokes and nulls its default strokes; choosing a command's own default stroke again removes the override; "reset all" writes `{}`. The fixture shows the exact file after each edit.

## Dispatch order

Birch's own bindings first, then shortcuts that extensions declare (manifest `commands`), so Birch wins a clash. Control+Tab details: tab-recency.md.
