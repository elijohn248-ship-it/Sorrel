# Parity: changes another edition still needs

Owner rule (2026-11-25): **every change goes to every edition of Birch**, unless it is specific to one platform. The rule itself is in `CLAUDE.md` ▸ Every change goes to every edition. This file is the list of changes made in this repository (Mac WebKit edition, Chromium edition for Windows and Linux) that another edition has not received yet.

The iPhone/iPad app keeps the same list for its own changes in `~/birch-mobile/docs/PARITY.md`. **A catch-up session reads both files for rows that name its edition.**

## How to use it

- A normal session changes one edition and adds a row here, in the same commit, for every other edition that needs it.
- Catch-up sessions (one per edition, when the owner asks) clear an edition's rows: delete its name from the row (and the row once no edition is left), in the same commit as the catch-up.
- Security and privacy fixes don't wait here: they go to every edition at once.
- Editions: **Mac** (`Sources/`), **Chromium** (`chromium/`; one codebase, verified on both Windows and Linux in CI), **iOS** (`~/birch-mobile`, iPhone and iPad), **Android** (not started; until it exists it gets changes through `spec/`, see the rule, so it never gets rows here).
- Not a row: a feature an edition doesn't have yet (the Chromium wave 3 work, for example). When that feature is ported, it is ported as it is then, including every later fix. Only changes to something an edition already has are owed.

## Owed

| Date | Change (branch / commit) | Still needed by | Why not done yet / what's left |
|---|---|---|---|
| | _none_ | | |
