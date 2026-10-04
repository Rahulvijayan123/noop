# g1-day-ui repair — G1 Today/midnight rollover, day policy, selection persistence, stale intraday guard

Audit branch: audit/core-plumbing-20261003 · Author: repair-dayui workstream · Date: 2026-10-03
Implements the G1 (day-ui) findings in `docs/core-plumbing/findings/g1-day-ui.md`; contracts per
`docs/core-plumbing/spec.md` §3 and the frozen shared contracts C2/C7 (parent).

## Files changed

| File | Change |
| --- | --- |
| `Strand/Data/Repository.swift` | Day-rollover signal (`dayRolloverSeq`, `rolloverDayKey`, `noteDayRolledOver`, `dayKeyDidChange` notification); `logicalDayRolloverHour` 4 → 0 (local-midnight Today); doc comments updated to the new policy + audit reference. |
| `Strand/App/AppModel.swift` | New `DayRolloverCoordinator` (shared day-boundary driver); `let dayRollover` wired in init; `recomputeTodayDay()`; `cloudBecameActive` recomputes; `syncHostedResults` yesterday key now Calendar-based (`-1 day`) instead of fixed 86,400s. |
| `Strand/App/StrandApp.swift` | `scenePhase == .active` recomputes Today before sync/refresh (macOS). |
| `StrandiOS/App/StrandiOSApp.swift` | `scenePhase == .active` recomputes Today synchronously before any network catch-up (iOS; the T02 ordering hook). |
| `Strand/Screens/TodayView.swift` | `selectedDayOffset` persisted via `@AppStorage(TodayView.selectedDayOffsetKey)` + clamp on appear; explicit "Today" action (iOS top bar + macOS nav row); `TodayLoadKey` + reload task include `repo.dayRolloverSeq`. |
| `Strand/Liquid/LiquidTodayView.swift` | `selectedDayOffset` persisted via the same shared key + clamp on appear; explicit "Today" action in the header; reload task includes `repo.dayRolloverSeq`. |
| `Strand/Push/IntradaySeriesStore.swift` | Stale-generation guard: `dayGeneration` bumped on `Repository.dayKeyDidChange` (or `noteDayRolledOver()`); `refresh` drops a write when the generation changed or the task was cancelled mid-await. |
| `StrandTests/TodayDayRolloverTests.swift` | NEW: midnight policy, rollover signal, coordinator injected-clock rollover/resume/timezone, persistence key + clamp. |
| `StrandTests/IntradayStaleResponseTests.swift` | NEW: gated URLProtocol proves a pre-midnight in-flight response is dropped after a day rollover; cancellation drop; same-generation control. |

## What each task did (verified in source before changing)

1. **T01/T02 next-boundary rollover** — `DayRolloverCoordinator` (AppModel.swift): recomputes the local
   Today key on launch (init seed), on scenePhase `.active` / `didBecomeActive` / `didEnterBackground`
   (timer gating), on `NSSystemTimeZoneDidChange`, and on significant-time-change (`UIApplication
   .significantTimeChangeNotification` iOS, `NSWorkspace.didWakeNotification` macOS). Keeps a
   next-local-midnight `Task.sleep` timer (visible-app only) that recomputes + re-anchors within ~1s of
   local midnight, with a 1s retry if it wakes a hair early. The driver only bumps
   `Repository.dayRolloverSeq` / posts `dayKeyDidChange`; it does not touch data. Both Today surfaces
   include `repo.dayRolloverSeq` in their reload key, so labels, counters, chart bounds and day-scoped
   queries re-key at midnight with NO dependency on `repo.refreshSeq`, a sensor reading, network, or a
   DB revision (findings: LiquidTodayView.swift:450, TodayView.swift:1758, AppModel.swift:724 backstop).
2. **Today selection persistence (T03)** — `@AppStorage("today.selectedDayOffset")` on both Today
   surfaces (same key); restored on relaunch/re-mount; clamped to the navigable range on appear
   (`TodayView.restoredDayOffset`). Explicit "Today" action buttons added (iOS top bar, macOS nav row,
   Liquid header), shown only while browsing a past day.
3. **New-day empty state** — the 04:00 logical-day hybrid is retired (`logicalDayRolloverHour = 0`), so
   Today resolves the new local-calendar day at midnight and renders its honest empty/pending state;
   `resolveToday`/`widgetAnchor`/`lastVitalsDay` carry logic is unchanged (still labelled "Last night ·
   <date>"), never copies yesterday's totals. Sleep wake-date keying untouched.
4. **T04 stale-response guard** — `IntradaySeriesStore` bumps `dayGeneration` on every day re-key; a
   refresh started before midnight drops its write (and its failure record) if the generation moved or
   the task was cancelled before assignment, so the shared `"<metric>|live"` key can never be
   overwritten by an old day's window (findings IntradaySeriesStore.swift:48, IntradaySeries.swift:237).
5. **syncHostedResults keys + resume ordering** — yesterday is `Calendar.current.date(byAdding:.day,
   value:-1)` (DST-safe; was `now - 86,400`); resume recomputes the Today date synchronously before the
   first meaningful render (StrandiOSApp.swift scenePhase + StrandApp.swift + `cloudBecameActive`).
6. **Repository day policy docs + signal** — the day policy (local-midnight Today, wake-date sleep
   association, zone authority = phone local IANA) is documented at `logicalDayRolloverHour` /
   `logicalDay` / `resolveToday` / `widgetAnchor`; `dayKeyDidChange` notification + `dayRolloverSeq`
   publisher exposed for observers.
7. **C2** — `logicalDayRolloverHour = 0` for Today row selection; sleep wake-date keying untouched;
   04:00-explaining comments updated to describe the new policy and reference the audit.

## Contract decisions applied

- C2: local-midnight Today; wake-date sleep keying untouched; half-open calendar bounds.
- The pre-audit #144/#304 04:00 carve-outs are retained as pure code (tests still pass with explicit
  keys) but are dead under the new constant; documented as retired.
- `TodayView.launchDayOffset` (the #860 "fresh launch always lands on today" pure function) is left
  UNCHANGED along with its tests; the persisted-selection contract (parent task 2) now governs actual
  launch restoration, so #860's in-session intent and the persistence contract are both preserved at
  the function level. Flagged for the parent: this is a deliberate policy change vs. #860.

## Test results (run 2026-10-03, macOS, Pacific zone machine)

`xcodegen generate && xcodebuild test -project Strand.xcodeproj -scheme Strand -destination
'platform=macOS' -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests`

- **Executed 2448 tests, 2 skipped, 4 failures.**
- My 11 new tests: **all pass** (TodayDayRolloverTests 8/8, IntradayStaleResponseTests 3/3).
- All day-rollover-adjacent existing suites pass: WidgetAnchorTests, TodayDayNavClampTests,
  TodayResolverEffortScaleTests, LocalDayMidnightTests, LiquidChargeCarryTests, TodayLaunchLandTests,
  IntradaySeriesTests, ReadSpineActiveDeviceTests, HugeImportFirstPaintStressTests,
  TodayWorkoutsWindowTests.
- 2 failures = the KNOWN pre-existing Pacific-time caption tests (parent baseline):
  `SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue`,
  `SleepCarriedStampTests.testPriorDayValueIsCarriedAndStamped`.
- 2 additional failures, both PRE-EXISTING and unrelated to this workstream (verified: no changed file
  is in either test's path; both also fail in isolation):
  1. `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` — deterministic test
     boundary bug: the test calls `describe(now: lastBucketEnd + 90s)` while `IntradayFormat.age` says
     "just now" only for `< 90s`, so the text reads "(ends 1 min ago)" not "(ends just now)".
  2. `TestBundleRobustnessTests.testActiveDomainsIncludesUniversalOnlyWhenAModeIsOn` — environmental:
     the dev machine's UserDefaults still has `testcentre.active.battery = 1` (verified via `defaults
     read`), so `activeDomains()` reports `.universal` ("any mode on") even though the test only
     isolates the `sleep` key. Clearing that stale Test Centre flag makes the environment match the
     test's assumption.
- 2 skips are the standard baseline: iOS-only data-protection test + `XIAOMI_REAL_DB`-gated import test.

## Tests

- `StrandTests/TodayDayRolloverTests.swift` (new, @MainActor):
  - `testLogicalDayRollsAtLocalMidnight` — C2 constant == 0; 23:59:59 → 15th, 00:00:01 → 16th; the
    retired 04:00 shift would still say 15th (guard assertion).
  - `testRepositoryRolloverSignalBumpsOnlyOnRealDayChange`, `testRepositoryPostsDayKeyDidChangeOnRollover`.
  - `testCoordinatorRollsTodayAtLocalMidnightWithoutAnyDataRefresh` — injected clock, no refresh().
  - `testResumeAfterMultiDaySuspensionReKeysTodayBeforeAnyDataRefresh` — T02.
  - `testTimezoneChangeEdgeReKeysToday`.
  - `testSelectedDayOffsetPersistsAcrossRelaunchUnderTheSharedKey`, `testRestoredDayOffsetClampsIntoTheNavigableRange`.
- `StrandTests/IntradayStaleResponseTests.swift` (new, @MainActor): gated URLProtocol suspends a refresh,
  day rolls, response released → dropped (window + failure untouched); cancelled in-flight read dropped;
  same-generation control writes.

## BLOCKED — shared-worktree build breaker (NOT mine)

The macOS `Strand` target currently fails to compile at
`Strand/Data/PlacementStore.swift:121:13: error: cannot assign to value: 'folded' is a 'let' constant`
(also `folded` declared `let` at line 93). `PlacementStore.swift` is untracked, in-progress code owned
by the **g34-wear-placement** workstream (it also has `?? Strand/Data/Placement.swift`); it is NOT in
this workstream's ownership list and was NOT touched here. The app-target compile error blocks the
`StrandTests` bundle (which links the app module), so the macOS test suite cannot run until g34 fixes
that file. All batches containing this workstream's files compiled with zero errors; the only error in
the whole build is PlacementStore.swift:121. Reported to the parent for coordination; once unblocked,
run: `xcodegen generate && xcodebuild test -project Strand.xcodeproj -scheme Strand -destination
'platform=macOS' -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests`.

## NOT VERIFIED / remaining gaps

- Actual runtime rollover latency on a real device (timer + notification edges are code-verified via the
  coordinator tests; a device capture is the only proof of the ≤1 s claim end-to-end).
- The two pre-existing macOS caption failures (SkinTempAbsoluteDisplayTests, SleepCarriedStampTests) on
  Pacific-time Macs are expected and will be reported as pre-existing once the suite runs.
- The Liquid Today header's "Today" button and iOS top-bar button are UI additions reviewed in source;
  they need a device/UI pass (no UI-harness tests in this suite).
- `profiles.timezone` app-side write is a separate G1/T06 workstream item, not in this workstream's file
  ownership (documented in findings; not changed here).


---

## Re-audit repair round (audit-g1-day F1/F2/F6) — 2026-10-03

Fixes for the three material findings in the independent audit (docs/core-plumbing/findings/audit-g1-day.md).

### F1 — DayRolloverCoordinator (AppModel.swift)
- **(a) timer retry no longer skips the crossed boundary**: `recomputeTodayIfNeeded()` now runs at the
  TOP of the midnight-timer loop (before deriving the next boundary) AND after each sleep, so a wake
  that lands a hair BEFORE local midnight (the `UInt64(delay*1e9)` truncation) rolls the day on the 1 s
  retry instead of re-arming a ~24 h sleep past the boundary it missed. Also added an injectable `sleep`
  seam so the loop is deterministic in tests; `testTimerLoopRecomputesTheBoundaryItWakesJustBefore`
  drives the sub-second wake + crossing and pins the rollover.
- **(b) same-day zone change re-keys day-scoped context**: new `Repository.zoneContextSeq` +
  `noteZoneContextChanged()`; `significantTimeChange()` now bumps it (and posts `dayKeyDidChange`) even
  when the local day key is unchanged. Both Today reload keys (TodayView `TodayLoadKey`,
  LiquidTodayView task id) include `zoneContextSeq`. Pinned by
  `testSameDayZoneChangeBumpsZoneContextEvenWhenDayUnchanged`.
- **(c) DST self-correction**: the boundary + its delay are re-derived from the CURRENT clock and
  `Calendar.current` at every arm (macOS has no significantTimeChange notification; a fall-back
  transition can no longer leave the re-armed deadline an hour late).

### F2 — the second 04:00 twin (NEW ownership: Strand/Screens/VitalSignsSummary.swift)
- `BodyVitalSigns.logicalDayKey` default `rolloverHour` 4 → 0, aligned with
  `Repository.logicalDayRolloverHour = 0`. This fixes the Health "Vital Signs – Latest" tile's "Today"
  label + logical-day reading selection (VitalSignsSummary.swift:112,140-229) and the Sleep tab headline
  carry/stamp (SleepModel.swift:410-415) between local midnight and 04:00 (they no longer treat
  yesterday as today). SleepModel uses `BodyVitalSigns.logicalDayKey` with the default, so it is aligned
  by the same change; its doc comment updated.
- Stale 04:00 comments updated in TodayView.swift (`selectedLogicalDay`, `selectedDayKey`, HR-trend
  window) and SleepModel.swift.
- Pinned by `testBodyVitalSignsLogicalDayRollsAtLocalMidnight`, `testSleepHeadlineCarryUsesTheMidnightBoundary`,
  `testSleepHeadlineStampsAPriorDayCarryAcrossMidnight`.

### F6 — IntradaySeriesStore residuals
- **(a) inFlight release on rollover**: `noteDayRolledOver()` also clears `inFlight`, so a stale
  pre-midnight refresh no longer blocks the new day's refresh on the shared `|live` key until the
  ≤30 s keepFresh tick. Pinned by `testDayRolloverReleasesTheInFlightSlotForTheLiveKey`.
- **(b) loadCached prior-day guard**: `loadCached` now captures the day generation before the await and
  re-checks it after, and for the constant `|live` key never applies a cached window whose `to` is
  before the current local midnight (a cold-launch-after-midnight cache from yesterday must not paint as
  the new day's window). Pinned by `testLoadCachedSkipsAPriorDayLiveWindow` +
  `testLoadCachedAppliesACurrentDayLiveWindow`.

### Re-audit test results (focused + touched suites)
- TodayDayRolloverTests: 13/13 pass (8 original + 5 new).
- IntradayStaleResponseTests: 6/6 pass (3 original + 3 new).
- Sleep suites (SleepModelStaleCarryTests, SleepModelDebtTests, SleepNapDebtTests,
  SleepNightSpanLabelTests, HabitualSleepFinishedNightsTests): all pass.
- Vitals suites (VitalSourceResolutionTests, VitalReadingsTableTests, TodayVitalCardTests,
  TodayEmptyVitalCaptionTests): all pass.
- SkinTempAbsoluteDisplayTests: 10 executed, 1 failure = the known pre-existing Pacific caption test
  (`testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue`); no new failures from the boundary change.

### Full-suite re-run (round 2) deltas after the F1/F2/F6 fixes
- `IntradaySeriesTests.testTheStorePaintsTheCachedWindowFirstAndNeverOverwritesALiveOne` regressed under
  F6b (it pinned the OLD behavior of seeding a `|live` view from a PRIOR-DAY cached window). Updated the
  test's fixture to a current-dated window so it exercises the intended "cache paints first" path; the
  prior-day case is now covered by `testLoadCachedSkipsAPriorDayLiveWindow`.
- `DetectedWorkoutReconciliationTests.testOptInCandidatePublishesTwelveMinutesAndOnlyLogsTenFifteenMinuteShadows`
  failed in one full-suite run but passes in isolation — a timing flake, not caused by these changes.
- `PlacementTests.testEligibilityWearStates` fails in isolation too — a NEW test owned by the
  g34-wear-placement workstream (Placement.swift); not this workstream's file. Reported for the parent.

### Final full-suite confirmation (fresh derived data, after all F1/F2/F6 fixes)
- **2496 tests executed, 2 skipped, 3 failures** (the count rose from 2448 because concurrent
  workstreams added tests: g34 PlacementTests, a ZoneHistoryDayRunTests suite, etc.).
- The 3 failures are all pre-existing and NOT from this workstream:
  1. `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` — deterministic test
     boundary bug (now = lastBucketEnd + 90 s vs age threshold `< 90 s`), verified in isolation.
  2. `SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue` — the known
     pre-existing Pacific-time caption failure (parent baseline).
  3. `SleepCarriedStampTests.testPriorDayValueIsCarriedAndStamped` — the known pre-existing Pacific-time
     caption failure (parent baseline).
- `DetectedWorkoutReconciliationTests.testOptInCandidatePublishesTwelveMinutes…` failed in one full run
  but passes in isolation AND in the final full run — a timing flake, not caused by these changes.
- g34's `PlacementTests.testEligibilityWearStates` failed in one full run but passed in the final full
  run — g34's in-progress file, intermittent, not this workstream's.
- Focused suites after the fixes: TodayDayRolloverTests 13/13, IntradayStaleResponseTests 6/6,
  IntradaySeriesTests (incl. the F6b-updated store test) pass, all sleep + vitals suites pass.
