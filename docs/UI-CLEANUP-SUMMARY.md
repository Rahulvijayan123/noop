# Nara UI cleanup: status

Status as of 2026-10-08. Read this first. It says what is on the integration branch, what was verified, and what is still open.

Nothing has been pushed, deployed or merged into `main`.

## Where the work is

- **Integration branch:** `ui/cleanup-integration-20261008`, in the worktree `nara-ui-final`. It was cut from the design-system branch `feat/ui-cleanup-design-system-20261007` (`3fada62e1`), not from `main`, because `main` has diverged from it and the kit is the base every area was built on.
- **Area branches** (`ui/<area>-20261007`) were merged one at a time, in this order: more, sleep, activity, insights, events, monitor, workouts, today, metric. Each merge commit is titled `Merge ui/<area>: ...`.
- The four conflict files named in the handoff (`TabRoute.swift`, `DemoLaunchArgs.swift`, `AppModel.swift`, the `DemoScreens` switch in `StrandiOSApp.swift`) were resolved by keeping every branch's cases. `QuietMotionCoverageTests` exemptions for the Coach files were removed.

## What changed, by area

- **Today:** the kit tiles and score rings; a Browse list for the screens that have no tab; the heart-rate card reads its high and low from the stored buckets, not from the drawn points. Fresh installs show 8 key metrics (`KeyMetric.defaultEnabled`), the rest stay available in Customize.
- **Metric detail and Explorer:** one anatomy for every metric (readout, range control, chart, stats, readings, an About disclosure). Units, axes and cadence come from a per-metric presentation table. Scrubbing and history work on every range. Rows with an HRV of zero or below are dropped, and `.above` thresholds are converted to the display unit.
- **Sleep:** the cloud and night backdrop is gone. A per-night page, a restyled Alarms screen, and a Consistency tile that does not open an empty page. The stage chart now shows the chart placeholder until the first load lands.
- **Monitor:** a rebuilt root with one page per Baseline vital, and a rebuilt Watchdog. The old sample snapshot is DEBUG only.
- **Events:** the fabricated sample events are DEBUG and demo only (`DemoLaunch.showsSampleEvents`). A release build with no events shows "No events yet."
- **Activity:** heart-rate day, Live, Breathe, interval timer and calibration. Live says why Start workout and HRV reading are disabled when no strap is connected.
- **Workouts:** the kit chart, zone and recovery pages. Estimated zone minutes are marked "Includes estimates".
- **Insights:** Health, Stress, Trends, Insights, Lab Book, Rhythm, Hydration, Compare and Intelligence. Compare breaks its lines at missing days and dots isolated readings.
- **More:** Sana chat, Devices, Data sources, Backup, Power saving, Limitations, Test Centre, Pair and onboarding.
- **Coach (Sana) motion:** the ungated loops are gone. Scroll and bubble animations honour Reduce Motion.
- **Copy:** no em dashes in any string the rebuild added.

## Review findings fixed after the merge

Each area got an adversarial pass. These are the findings that changed code:

- Fabricated sample data shipped in release builds (Events, legacy Monitor snapshot). Now DEBUG only.
- Double-pushed navigation: `.tabRouteDestinations()` registered twice or not at all on Settings and the quick screens. Registered exactly once per stack.
- Nested navigation stacks on macOS for Metric Explorer, Trends, Workouts and Sleep. They now use `MorePaneNavigation`.
- Compare drew straight lines across missing days.
- Heart-rate card min and max came from the thinned points, not the data.
- HRV zero or negative values pulled the axis and the "low".
- Metric thresholds were compared in stored units while the display unit differed.
- Treatment calendar cells were under 44 pt and carried no non-colour cue or VoiceOver label.
- Baseline vital page said "days" for sleep, which is counted in nights.
- Workout zone totals did not say they include estimates, and the estimate cache outlived a zone-key change.
- Coach scroll animations ignored Reduce Motion.
- `KeyMetric.defaultEnabled` was out of canonical order (failed `KeyMetricPrefsDecodeTests`).
- Sleep stage chart painted real stage colours while the rest of the page was redacted for loading.
- Watchdog line and Journal status truncated at the largest accessibility text size. They now wrap.

## Verification (final commit)

| Check | Result |
|---|---|
| iPhone build (`NOOPiOS`) | Succeeds |
| macOS build (`Strand`) and test build | Succeeds |
| watchOS build (`NOOPWatch`) | Succeeds |
| StrandDesign package tests | 294 tests, 0 failures |
| `StrandTests`, full macOS run, before the last three small commits | 3160 tests, 3 failing cases that were already failing on the base (see below), plus `KeyMetricPrefsDecodeTests.testDefaultEnabledIsAnOrderedSubsetOfTheUniverse`, which was then fixed |
| `StrandTests`, the classes touched by later commits (`KeyMetricPrefsDecodeTests`, `EventsPresentationTests`, `MetricPresentationTests`, `TodayLayoutPrefsTests`, `LiquidTodayTileValueTests`) | Pass |
| i18n audit (`python3.13 Tools/i18n_audit.py`) | Runs. `ru` is missing 1 key and `zh-Hant` 79 keys in the app catalog. All other locales have 0 missing |

**Failures that predate this work:** `ActivityCalibrationSessionTests.testBeginWithAnEmptyProtocolEndsCleanly`, `ActivityCalibrationSessionTests.testStepsChainBackToBackAndEveryActivityEndsWithDone`, and `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets`. They fail the same way on the base commit. The last one compares a wall-clock age ("newest bucket ended 30 s ago") and may be time dependent. The calibration ones fail on cue and step sequencing. I did not change calibration code.

The full `StrandTests` suite was not rerun after the last three commits (Sleep loading placeholder, Dynamic Type wrapping, key-metric order). Those touch views and one array order, and the classes that cover them were rerun.

### Screenshots

iPhone simulator, light mode. Under `_build-scratch/ui-shots/final/`:

- `full/` (120 days): today, metric detail, sleep and night page, monitor, events, heart-rate day, workouts, stress, health, trends, Sana. Reviewed.
- `sparse/` (3 days): the same routes. Reviewed for Today, metric HRV and Sleep. The chart on HRV shows only the three real days and leaves the earlier days of the week empty.
- `empty/` (0 days): the same routes minus Sana. Reviewed for Today, Events, Sleep and metric HRV. Events says "No events yet." and no fabricated events appear.
- `loading/` (`--demo-load-delay 60` over a populated store): today, metric HRV, sleep, monitor, stress, workouts. Today, HRV, Sleep, Monitor and Stress show placeholders. **Workouts shows data during the delay**: it reads the local store and has no loading state.
- `dyntype/`, `dyntype2/` (accessibility extra large): today, metric HRV, sleep, monitor, events.

Not done: dark mode, a runtime macOS visual check (the Mac builds and its tests ran, but I did not launch and look at it), a runtime Reduce Motion capture (covered by the `QuietMotionCoverageTests` source census and by code review of the Coach files), and a run on a physical device.

## Still open

1. **Translations.** The strings the rebuild added are not in `Localizable.xcstrings`, so they fall back to English. The audit only counts keys already in the catalog, so it does not show this gap.
2. **Settings rows for visual preferences that no longer do anything** (sky, card transparency, trend chart style). `SettingsView.swift` belongs to another session and was not edited.
3. **Dynamic Type on `MetricTile`.** The label is one line by design so every tile in a grid has the same height. At the largest accessibility sizes "Respiratory rate" truncates to "Respirat...". Wrapping it needs a kit decision about tile height.
4. **DST stepping in `FullDayChartView`** is not covered.
5. **Live heart-rate trace** stays on the last value if the strap stalls, instead of showing a gap.
6. **Alarm rows** have tap targets under 44 pt on some rows.
7. **Oura "Forget access"** still uses the old button style.
8. **Default key-metric set of 8:** users who never customised Today now see 8 tiles instead of 11. This is a product choice to confirm.
9. **Monitor sync handler** rescoring uses `rescore(preferReadySeries: false)`. Review before shipping.
10. **`MonitorView` legacy code** is still compiled for the old Monitor path.
11. **Workouts** has no loading state.
12. **The base failures** listed above.
13. **Branch base.** This branch is based on the design-system branch, not on `main`. `main` has diverged, so merging to `main` will need a conflict pass.

## Deviations from the brief

- The five area branches that were unfinished WIP commits did not compile. The compile fixes were made on the integration branch after the merges, not on each area branch.
- Sub-agents were not used for the final work. Everything after the quota stop was done directly.

## Housekeeping

- Build caches are on `/Volumes/External SSD/nara-ui-dd/`. No other session's files were deleted. I removed stale lock directories only under my own `final/ios` slot.
- Simulator `nara-ui-final` was created for the screenshots.

## Tools

In `_build-scratch/tools/`: `ui-build.sh <worktree> <name> ios|mac|test|watch|pkg`, `ui-sim.sh` (install, tour, shot), `areas.json`. Demo launch arguments are in `Strand/Data/DemoLaunchArgs.swift` and are DEBUG only.
