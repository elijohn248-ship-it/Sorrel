# Birch behaviour spec

**Spec version: 1.0.0** (2026-11-23). Generated from the Mac (WebKit) edition at the commit that adds this folder.

Birch has two editions: the existing Mac app (Swift, AppKit, WebKit) and a Chromium edition (C++, Windows first, then Linux). They share no code. This folder is the contract between them: plain-language rules plus JSON fixtures (input → expected output) produced by running the Mac app's **real Swift functions**. An edition proves it behaves like Birch by loading every fixture and getting the same answers.

## Files

| Area | Document | Fixtures |
|---|---|---|
| Saved data: state.json, settings.json, archive.json, history.json, bangs.json; what is portable | [saved-data.md](saved-data.md) | `state-decode`, `state-derived`, `settings-fields`, `settings-decode`, `archive-history-decode`, `history-behaviour` |
| Keyboard shortcuts and command ids | [keybindings.md](keybindings.md) | `keybindings` |
| Typed text → URL, bangs, tracking-parameter removal, address-box text, HTTPS-first | [address-and-search.md](address-and-search.md) | `resolver`, `bangs`, `url-cleaner`, `site`, `https-first` |
| Tab sleep, archive, memory pressure | [tab-lifecycle.md](tab-lifecycle.md) | `tab-lifecycle` |
| Peek (link preview) decisions | [peek.md](peek.md) | `peek` |
| Split view rules | [split-view.md](split-view.md) | `split-view` |
| Control+Tab recency | [tab-recency.md](tab-recency.md) | `tab-recency` |
| Space colours (OKLab softening, gradients, grain, brightness) | [space-colours.md](space-colours.md) | `theme`, `theme-math` |
| Security invariants as checkable statements | [security-invariants.md](security-invariants.md) | (uses `site`, `https-first`, `state-derived`) |

## Fixture format

Every file in `fixtures/` is one JSON object:

```json
{
  "spec_version": "1.0.0",
  "fixture": "resolver",
  "area": "address-and-search",
  "generated_by": "SORREL_SPECDUMP (Sources/Sorrel/SpecDump.swift)",
  "sources": ["which Swift functions produced it"],
  "notes": ["how to read the cases"],
  "cases": [
    { "name": "typed \"example.com\"", "input": { ... }, "expected": { ... } }
  ]
}
```

Some files carry one extra top-level key (`written_by_birch` in `state-decode`, `commands` in `keybindings`, `table` in `bangs`).

Per case:

- `name`: unique within the file; use it in test output.
- `input`: everything the behaviour depends on. Anything not given is the default (`settings-fields`), and the fresh-profile state.
- `expected`: what the Mac app produced. JSON `null` means "none" (no URL, no match, field absent).
- `source` (optional): `"transcribed: …"` marks the few cases where the decision lives inside a WebKit callback that can't be called on its own (Peek, the HTTPS upgrade rewrite, the address-box composition, the bundled-page name check). The gate logic there was copied line for line from the Swift source named; every comparison inside it is still the real function. All other cases are pure real-code output.
- `informative` (optional): the Mac answer comes from a quirk of Apple's URL parser on garbage input. Editions should log a mismatch, not fail.
- `applied_after_previous_case: true` (in `split-view`): the cases are one sequence; run them in order on one state.

## How an edition proves it matches

1. Build a test runner (in the edition's own language) that, for each file in `spec/fixtures/`, checks `spec_version` starts with the major version it implements, feeds each case's `input` to the edition's equivalent function, and compares with `expected`.
2. Print one line per case, the same pattern as the Mac hooks: `spec: <fixture> <name> expected=<…> got=<…>`, and a summary `spec: <fixture> passed=N failed=M informative=K`.
3. Comparison rules:
   - Strings, booleans, integers, arrays and objects: exact (object key order never matters).
   - Floating-point numbers in `theme` and `theme-math`: absolute tolerance **1e-6** per component. Hex colours (`#RRGGBB`) may differ by 1 in a channel only where that channel's float is within 1e-6 of a rounding edge (x·255 ending in .5). `is_dark` may differ only where a luminance is within 1e-6 of 0.55.
   - Other numbers (minutes, hours, widths): exact.
   - Error strings in `*-decode` fixtures are informative; compare only `decodes` (true/false) and, where you report it, the failing field.
4. CI fails on any mismatch that is not `informative`. Fixtures are never edited by hand to make an edition pass: if Birch's behaviour should change, change the Mac app, regenerate, bump the version, and update both editions.
5. Behaviour that can't be a fixture (layout, motion, prompts, sandboxing) is stated in the Markdown files as rules with "How to test" lines; editions add their own hooks for those.

## Version numbers

`MAJOR.MINOR.PATCH`. MAJOR: a fixture's expected output changed (an edition that passed may now fail). MINOR: new fixtures or cases only. PATCH: wording. Bump it in `Sources/Sorrel/SpecDump.swift` (`specVersion`) and here.

## Regenerating

The fixtures come from the Mac test hook `SORREL_SPECDUMP=<dir>` (CLAUDE.md ▸ Testing). In a task worktree, never in `~/sorrel`:

```sh
./build.sh
S=$(mktemp -d /private/tmp/sorrel-test.XXXXXX); mkdir "$S/p1" "$S/out"
SORREL_HOME="$S/p1" SORREL_SNAPSHOT="$S/shot.png" SORREL_DELAY=12 SORREL_SPECDUMP="$S/out" \
  build/SorrelTest.app/Contents/MacOS/Sorrel 2>&1 | grep '^specdump:'
cp "$S/out"/*.json spec/fixtures/
```

It uses a fresh scratch profile (run it without `SORREL_OPEN`), synthetic inputs only (`*.example` hosts, made-up spaces), and never reads a real profile or the network: test tabs use `birch://spec-<label>`, which names no bundled page, so nothing loads. Two runs give byte-identical files. It also writes `bangs-all.tsv` (every bundled bang resolved, 1.3 MB, not committed; its SHA-256 is in `fixtures/bangs.json` ▸ `table.sha256`).

The Mac results depend on the macOS URL parser (Foundation on macOS 27 at generation time). Where a later macOS changes an answer, regenerate and bump MAJOR.
