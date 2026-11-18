# Birch / Safari memory comparison

## Scope and measurement

Task: `webkit-memory-comparison`, based on `memory-efficiency` with local main merged.
Same Mac: Mac17,2, 16 GiB RAM; macOS 27.2.1 (26B131). Safari 27.2,
bundle build 22625.2.8.11.9; system WebKit short version 22625, build
22625.2.8.11.9. Birch identifies itself to ordinary sites using installed
Safari's version; its executable is release-built Birch 0.4.0 (8) plus
the inherited memory-pressure change. The user-agent's Safari/605.1.15 token
is not an engine build identifier.

Use `python3 tools/memory-sample.py --group MAIN_PID`. It reads
`proc_pid_rusage(RUSAGE_INFO_V0)` from the external shell, logging physical
footprint and resident size separately, in bytes, with timestamp and process
start identity. Explicit `main=PID content=PID gpu=PID network=PID` mode is
also supported. It never reads profiles, page text, titles, URLs, argv,
credentials, or environment variables. Keep raw output under `/private/tmp`,
outside git. Do not commit screenshots or browser logs.

The SDK's `rusage_info_v0` is 96 bytes. Self-process counters and the test
main/content processes were checked against `footprint -p PID --noCategories`.
An inaccessible/exited explicit PID produces an error, never a zero.
Footprint includes compressed/swapped charges; RSS alone does not measure
the pressure attributable to a process. Clean/reclaimable mappings and
accounting differences mean RSS minus footprint is not a measured quantity
of reclaimable memory. A high RSS is not by itself evidence of a leak.

Group mode uses the diagnostic private `PROC_PIDCOALITIONINFO` query (20,
40-byte result, two IDs and three reserved values), as defined by Apple's
XNU sources. It matches both resource and jetsam coalition IDs, and only
selects WebKit executable names from `ps ... comm`, never display titles.
This API is used by the external tool only, not shipped app code. It may
change on future macOS versions. Unqueryable candidate processes are skipped;
therefore a group is not guaranteed complete. Verify membership for each run.
It does not include every Safari helper service. A terminal-launched test
can share its coalition with other tests launched by that terminal; run only
one test instance at a time. PPID is insufficient: XPC processes have PPID 1.
`launchctl procinfo` requires root here; no privilege escalation was used.
Inside Birch's sandbox, WebKit per-process rusage queries are refused, as
previously documented. External shell measurements succeeded on this Mac;
no entitlement or security setting was changed.

Report main, all selected WebContent, GPU and networking separately. WebContent
can include extension backgrounds, cross-site frames, prewarmed processes,
and cached pages. GPU/networking serve several tabs; their full charge is not
one tab's allocation. A sum of kernel process charges is not a deduplicated
physical allocation total. For a deduplicated group analysis, use one
`footprint -p PID ...` invocation with all verified group PIDs; the installed
`man footprint` describes de-duplication of multiply mapped objects.
Never sum separate footprint reports and call that a deduplicated total.

## Matched workload protocol

1. Owner prepares sessions; agents never inspect real profile files or sign-ins.
   Use SorrelTest with a fresh `/private/tmp/sorrel-test.XXXXXX` profile,
   `SORREL_HOME`, `SORREL_SNAPSHOT`, bounded `SORREL_DELAY`, and no loud mode.
   It uses a non-persistent data store, unlike an ordinary Safari session.
   The test main process automatically re-execs with `MallocSpaceEfficient=1`.
2. Record total tabs, awake tabs/windows, private/normal mode, viewport/display
   scale, extension names/versions and blocking differences. Birch scratch has
   built-in blocking plus bundled uBOL 2026.1110.1816; no Proton Pass or other
   user-installed extension is copied. Leave protection enabled. Unknown
   extension state or unmatched tabs makes a causal comparison incomplete.
3. Test YouTube and UWorld separately with a blank/welcome baseline. Owner
   uses identical content without disclosing it. YouTube: same playback position,
   fixed resolution, codec if available, playback speed, muted/audio state,
   playing/paused state and foreground visibility. UWorld: same screen type,
   image/diagram state, question/review mode and sequence of interactions.
   A login page or a local video fixture cannot substitute for these workloads.
4. Sample baseline, then 15 and 30 seconds after completed navigation, then
   120 and 300 seconds of the same activity. Record actual elapsed times from
   the owner's load/play confirmation; do not call an already-open session
   an initial-load measurement. Avoid DevTools, snapshots, memory pressure
   commands, or cache purges during sampling. Quiet hidden playback is not
   equivalent to visible playback; owner must bring the test window into view.
5. Owner closes only the tested tab in each browser. Sample after 15, 60 and
   120 seconds while retaining baseline tabs. Re-enumerate PIDs each time;
   exiting/prewarmed processes may disappear or be reused. A persistent GPU
   or cached process after close is not proof that the Page is retained.
6. Repeat both workloads twice, reversing browser order on the second trial.
   Reuse each browser session for the second within-session trial to avoid
   excess launches; disclose warm caches. Report ranges and baseline-adjusted
   changes by role. If differences are smaller than run-to-run variation,
   call them inconclusive. A repeat is not independent when content, tab
   count, extension state, or elapsed use differs.

## Control observations

Before owner-prepared workloads, the scratch welcome-page main process had
44,271,656 bytes footprint versus 1,288,732,672 bytes resident (42.2 versus
1229.0 MiB). `footprint` independently reported 42 MB and a 527 MB peak.
A later idle sample had 51,546,536 bytes footprint versus 231,636,992 bytes
resident (49.2 versus 220.9 MiB). These are main-process controls, not tab
measurements or a Safari comparison. The transient startup peak is distinct
from steady memory. No deliberate pressure was applied.

## Prepared mixed-session measurements

Physical footprint in MiB (bytes / 1,048,576), by process role. WebContent is
the sum of process accounting charges, not an exact per-tab or deduplicated
allocation. Times are seconds after the owner's matched-setting confirmation.

| Elapsed | Browser | Main | All WebContent | GPU | Networking |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | Birch Test | 70.3 | 1939.5 | 59.7 | 27.5 |
| 0 | Safari | 182.7 | 1984.7 | 106.6 | 24.9 |
| 15 | Birch Test | 70.0 | 1999.1 | 52.2 | 26.6 |
| 15 | Safari | 183.8 | 1933.1 | 100.5 | 24.5 |
| 30 | Birch Test | 68.3 | 2064.2 | 49.9 | 25.5 |
| 30 | Safari | 183.7 | 1992.6 | 99.1 | 24.4 |
| 120 | Birch Test | 68.4 | 1909.9 | 50.7 | 20.3 |
| 120 | Safari | 184.0 | 2223.5 | 55.2 | 24.4 |
| 300 | Birch Test | 68.3 | 1864.3 | 50.4 | 19.6 |
| 300 | Safari | 184.0 | 2193.6 | 50.8 | 24.4 |

Largest individual WebContent footprint observed in this series: 1199.2 MiB
in Birch Test, 1327.1 MiB in Safari. These are real footprint charges and
cannot be dismissed as RSS inflation. They are not proven tab allocations.
An additional grouped `footprint` invocation, around 117 seconds into the
series, reported deduplicated totals of 2047.0 MiB for Birch Test and
2531.7 MiB for Safari, with no errors/warnings. Those are separate samples
from the rusage table and must not be treated as simultaneous exact totals.

Owner then closed only YouTube in both browsers. Times below start when the
owner reported closure; the exact click-to-confirmation delay is unknown.
UWorld and the remaining tab stayed open.

| After close | Browser | Main | All WebContent | GPU | Networking |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | Birch Test | 66.9 | 477.5 | 33.8 | 19.0 |
| 0 | Safari | 176.8 | 957.0 | 43.7 | 24.3 |
| 15 | Birch Test | 65.0 | 467.5 | 33.7 | 19.0 |
| 15 | Safari | 176.6 | 940.3 | 41.0 | 24.2 |
| 60 | Birch Test | 64.9 | 472.4 | 33.8 | 18.4 |
| 60 | Safari | 176.8 | 940.5 | 39.6 | 24.2 |
| 120 | Birch Test | 64.9 | 479.2 | 33.8 | 17.8 |
| 120 | Safari | 176.8 | 942.0 | 83.7 | 23.5 |

Between the last sustained sample and the 120-second post-close sample, WebContent charges
fell by 1385.1 MiB in Birch Test and 1251.6 MiB in Safari. That is a whole-group
change over an interval, not an exact allocation owned by the closed tab.

For the warm-session repeat, times start at the reopening confirmation.
The first rows are initial reopen observations, not precisely timed navigation
peaks. UWorld stayed open throughout.

| After reopen | Browser | Main | All WebContent | GPU | Networking |
| ---: | --- | ---: | ---: | ---: | ---: |
| 0 | Birch Test | 70.8 | 1472.9 | 143.9 | 19.2 |
| 0 | Safari | 184.9 | 2004.4 | 52.7 | 23.6 |
| 15 | Birch Test | 70.6 | 1526.9 | 58.0 | 19.2 |
| 15 | Safari | 184.7 | 2002.3 | 52.4 | 23.7 |
| 30 | Birch Test | 70.7 | 1572.4 | 56.4 | 19.1 |
| 30 | Safari | 184.8 | 2021.8 | 52.6 | 23.6 |
| 120 | Birch Test | 70.7 | 1548.2 | 51.3 | 19.0 |
| 120 | Safari | 184.6 | 2021.8 | 49.6 | 23.4 |

### Result and remaining checks

The measured scale is comparable to Safari's WebKit content memory. In these
prepared sessions, Birch's main process was much smaller, while content
memory overlapped Safari's range and fell substantially after YouTube closed.
This supports heavy WebKit/content work as the principal observed cost;
it does not establish that every 1 GB tab is expected, exclude a WebKit leak,
or isolate overhead from Birch's injected scripts/extensions. There is no
measured evidence here that another app change would reduce active-tab memory.

After YouTube closed, an additional category inspection of the largest remaining
content process found 412.9 MiB footprint in Birch Test and 573.0 MiB in Safari.
WebKit Malloc accounted for 338.3 and 486.6 MiB respectively. These heap
categories cannot distinguish website JavaScript from extension/injected
script allocations. The category's swapped/compressed subset is already
included in dirty accounting, not additional memory to sum again.

A repeat was requested with Safari reopened first, then Birch Test. The
six-minute waiting window before confirmation is excluded from playback
results. After the owner confirmed reopening, a second series sampled at
0, 15, 30 and 120 seconds. This was a warm-session repeat with UWorld kept
open; it was not a fresh independent launch or a repeat UWorld navigation.
Initial samples capture the aftermath of reopening, with unknown delay
between completed navigation and the owner's reply. No UWorld reload or
closure was forced: an unfinished test was left alone. Exact navigation-relative
initial loads, an isolated UWorld trial and post-UWorld-close samples remain
unverified. Extension versions, actual awake counts and equal
visibility/viewport/codecs also remain uncertain. Two within-session playback
trials do not establish a distribution across independent sessions.

The second YouTube-close request was not confirmed before the prepared test
app reached its 30-minute automatic timeout. Its exit is not counted as a
tab-close measurement, and no after-exit values are used. The first explicit
YouTube closure was sampled through 120 seconds. Post-UWorld closure remains
unverified.

Owner follow-up: when the test can safely be saved/exited, use the matched
workload protocol above for each site separately, including a blank baseline,
two navigations and post-close samples. Use only numeric role summaries and
settings in the report. Do not copy profile data or disclose page content.

## Interpretation and implementation review

### Prepared session conditions

Owner reported three total tabs in each browser, UWorld in a test, and
YouTube playing at 720p60 in Safari. Birch Test initially played at 480p60;
those setup observations are excluded. Sampling began after the owner
confirmed the request to match 720p60, playback position and UWorld screen.
Earlier replies mentioned everyday Birch; the latest direct clarification
said SorrelTest also contained both sites. Only the explicitly launched
SorrelTest process group and Safari are used for the prepared-session series.
The everyday Birch process is excluded. Owner-reported settings were not
verified by reading signed-in page content.

Birch Test: bundled uBOL only, plus built-in content blocking. Safari:
LibKey Nomad, uBlock Origin (owner's reported name), Zotero and Proton Pass;
versions and exact blocker package were not independently inspected.
Extensions, persistent versus ephemeral stores, awake tab counts, visibility,
viewport, codecs, caching and total prior session age are not fully controlled.
The resulting series is an observational comparison of the prepared mixed
sessions, not an isolated browser-overhead benchmark. Both sites were already
loaded before sampling; elapsed times start at confirmation, not navigation.
The two sites were not initially measured separately. Do not interpret
variation between samples as a measured leak rate.

The inherited optimization responds to OS warning/critical events by trimming
disposable app caches and sleeping eligible idle background tabs after five/one
minutes, respecting Never, shorter configured intervals, visible panes and
playback/capture/loading/PiP exclusions. It does not shrink a currently active
YouTube/UWorld tab. The fixture verifies actual Page/WKWebView release, not MB
saved. No additional app optimization is justified by the idle control alone.

Code review: closing normal tabs calls Page.teardown and clears item.page;
teardown invalidates observations, stops navigation, clears delegates and
detaches the web view. Media polling has one outstanding batch, weak page/item
captures, and removes state for closed pages. These facts do not constitute
a heap/leak proof for signed-in workloads. Extension scripts, content rules,
video buffers, images and WebKit caches remain potential contributors.

## Sources

- Apple, WWDC21: *Detect and diagnose memory issues*, explains dirty and
  compressed memory accounting.
- WebKit documentation: *Memory Inspection*, documents footprint and
  clean/reclaimable categories.
- WebKit documentation: *WebKit2*, explains shared session/network processes.
- Apple XNU: `bsd/sys/proc_info_private.h` defines the diagnostic coalition
  query; the installed SDK defines rusage v0. The installed `footprint` manual
  documents group deduplication.

No source establishes a universal expected 1 GB-per-tab budget. Interpret
these sites using the prepared-session measurements and their limitations,
rather than the idle main-process control alone.

## Verification and change scope

No additional app optimization was made from this comparison. It incorporates
the existing `memory-efficiency` pressure handler and its Settings explanation.
Added the external numeric sampler, this report and handbook corrections;
no entitlement, privacy setting, extension compatibility bridge, updater,
vendor file or app network behavior was changed by the comparison work.

Debug and release builds pass with the same two distinct source warnings
(weak capture ownership in Extensions, deprecated baseline separator in
MainWindow). The 17 pressure checks, 22 multi-window checks and silent
media/seek checks pass after incorporating main; pressure checks are rerun
on the rebuilt task bundle. The pressure fixture verifies release/wake of
Page/WKWebView and protection of visible/recent/playing tabs without creating
actual OS memory pressure. The security-pattern diff scan has no hits.
All 26 numeric table rows were compared programmatically against raw counters.
Sampler self counters, invalid PID reporting and footprint cross-checks pass.
Fresh throwaway profiles were used for automated tests; no test process is
left running. No real profile files or secrets were inspected, and no raw
browser logs/screenshots, page addresses, titles or question content are
committed. The owner's main rebuild and scoped worktree cleanup are explicitly
authorized for this task; nothing is pushed or published.
