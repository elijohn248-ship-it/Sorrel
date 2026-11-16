# Bugs

## Security audit, 2026-11-15 (branch `security-audit`)

All fixed on the branch and verified with SorrelTest.app (`tools/update-test.sh`, `SORREL_SECTEST2`, `SORREL_SECTEST`, an extension fixture, window snapshots).

- [x] Updater service could install a different archive than it verified. Cause: it re-read the zip from the app's container after checking it. Now: verified bytes kept in a private copy outside the sandbox's reach.
- [x] Updater service wrote its log to any path the app named. Cause: log and app paths came from the app. Now: app = the bundle containing the service; log only the app's own update.log.
- [x] Address box could show a lookalike host as another site. Cause: `www.` removed anywhere in the host. Now: only a leading `www.`; long hosts cut at the front.
- [x] Extension updates gained new required permissions silently. Cause: every load granted the current manifest. Now: recorded at switch-on; more is held back until approved.
- [x] Not-secure Continue usable after leaving the warning. Cause: offer never expired. Now: only while the warning is showing.
- [x] Hidden tabs could raise app-modal dialogs. Cause: `runModal` fallback. Now: answered Cancel; repeated dialogs can be silenced.
- [x] `SORREL_*` test hooks honoured by Sorrel.app. Now: dropped at launch unless SorrelTest.app.
- [x] `sorrel://` names could climb out of the app bundle. Now: plain names only.
- [x] Pages could save downloads without a click. Now: asks once per site.
- [x] Wildcard `externally_connectable` hosts got the Chrome bridge. Now: exact hosts only.
- [x] No sign of an unencrypted page in the address box. Now: orange open lock.
- [x] release.sh put the GitHub token on curl's command line. Now: passed as a header file.
- [x] A page that kept crashing reloaded forever. Now: error page after the third crash in a minute.

Not changed: Web Inspector stays available on every page (owner's tool; only reachable by someone at this Mac).
Still to check by hand (owner): a clicked download starts without a prompt; the extension update prompt's wording.

## Fixed

### Centered command bar moves while typing (fixed 2026-11-15, branch `command-bar`)
- **Repro:** ⌘T, type something that fills several suggestion rows.
- **Expected:** the line you type on stays where it opened; the list grows below it.
- **Actual:** the whole bar re-centered as rows appeared, so the text field slid upward on every keystroke.
- **Cause:** the panel was pinned by its vertical center. It is now pinned by its top edge, placed from the window height only (`CommandBar.positionCentered`).
