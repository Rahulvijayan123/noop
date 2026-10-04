# audit-g1-day — independent audit of the G1 day/UI/timezone repairs

Auditor: audit-g1-day (independent; authored NO repair code)
Branch: audit/core-plumbing-20261003 (working tree) · Date: 2026-10-03
Scope: spec §3 + T01–T07, T30-day-rows. Changed files owned by repair-dayui /
repair-daybucket, plus the integrations (repair-diag coach.ts timezone, repair-attest
worker dayWindow call-site).

## What was verified

Targeted tests run by this auditor (all pass):
- `xcodebuild … -only-testing:StrandTests/TodayDayRolloverTests` → 8/8
- `… -only-testing:StrandTests/IntradayStaleResponseTests` → 3/3
- `… -only-testing:StrandTests/ProfileTimezoneSyncTests` → 4/4
- `swift test --filter AnalyticsEngineDayBoundsTests` (StrandAnalytics) → 10/10
- `CPATH=…/libpq/include swift test --filter DayScoringAdapterTests` (worker) → 29/29
- `EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all tests/coach_test.ts` → 14/14

Full suites were NOT re-run (root ran them authoritatively).

## Verdicts per challenge

| # | Challenge | Verdict |
|---|-----------|---------|
| 1 | Rollover trigger completeness | PASS wiring + **P2** timer edge (F1) |
| 2 | Midnight vs 04:00 (no 86400/04:00 left; sleep wake-date unchanged) | **P2** — one 04:00 twin remains (F2); sleep keying unchanged (verified) |
| 3 | T04 stale-response (generation guard, loadCached, ServerScoreRepository) | PASS core + **P2** residual (F6) |
| 4 | Day-bucketing parity app/worker/SQL | PASS single-zone; **NOT VERIFIED** LA fixtures + zone-change-mid-window (F3/F4) |
| 5 | Timezone contract phone→profiles→claim→worker | PASS code-verified; **P2** test gap (F5) |
| 6 | #860 persisted selection + clamp (date-line) | PASS |
| 7 | Missing guards (rollover-vs-sync, thread safety, observer leaks) | PASS (see notes) |

## Material findings

### F1 (P2) — midnight-timer retry path can skip the recompute at the boundary
`Strand/App/AppModel.swift:3010-3036` (`DayRolloverCoordinator.scheduleMidnightTimer`).

The loop recomputes the day only AFTER `Task.sleep` returns at the boundary. If that
wake lands a hair BEFORE local midnight, `recomputeTodayIfNeeded()` returns false, the
task sleeps 1 s, and the loop TOP then re-derives the boundary as the FOLLOWING local
midnight (`calendar.date(byAdding:.day,1,to:startOfDay(for:current))` at 00:00:00.1 →
tomorrow) and sleeps ~24 h WITHOUT recomputing the boundary just crossed. The sub-µs
truncation of `UInt64(delay * 1e9)` makes an early wake genuinely reachable.

Consequence: for a continuously-foreground, data-quiet app (exactly T01's scenario),
Liquid Today (the DEFAULT surface; RootView liquidTodayEnabled=true) stays on the old
day until the next lifecycle edge, data refresh, 30-min backstop, or the NEXT midnight's
timer fire — a T01 "≤1 s rollover" miss that can last ~24 h. The classic Today label
partially self-heals via its ~10 s hint timer (TodayView.swift:1612-1622) but its
day-scoped DATA (HR trend/Rest) is reload-keyed on `dayRolloverSeq` and stays stale.

Not covered by tests: TodayDayRolloverTests never call `scheduleMidnightTimer` (they
drive `recomputeTodayIfNeeded()` with an injected clock).

Minimal repair: move `recomputeTodayIfNeeded()` to the TOP of the while loop (before the
boundary computation) so a retry re-checks the crossed boundary instead of re-arming a
full-day sleep.

Related (same finding): a timezone change that does NOT change the calendar date (e.g.
UTC+1→UTC+2 at 13:00) does not bump `dayRolloverSeq` (`recomputeTodayIfNeeded` returns
false), so the day-scoped Today reload does not re-key and the HR-trend/bounds keep the
OLD zone's midnight until a data refresh — spec §3 "recompute on timezone/profile
changes, update before rendering meaningful Today data" is only half-met. Also, on macOS
there is no `significantTimeChangeNotification`; an awake Mac across a fall-back DST
transition re-anchors the timer only on wake/zone-change, so the deadline lands 1 h late
on the day after fall-back (iOS is covered — DST posts significantTimeChange there).

### F2 (P2) — a second, independent 04:00 "logical day" survives the retirement
`Strand/Screens/VitalSignsSummary.swift:475` — `BodyVitalSigns.logicalDayKey(_:rolloverHour:
Int = 4)` still shifts by −4 h. Used by:
- the Health tab "Vital Signs – Latest" tile: "Today" label (VitalSignsSummary.swift:112)
  and the logical-day reading selection (:140, :163, :165, :229);
- the Sleep tab headline metric carry/stamp (SleepModel.swift:410-415).

Repository's twin now rolls at 00:00 (`logicalDayRolloverHour = 0`), so between local
midnight and 04:00 these surfaces still resolve the PREVIOUS day as "today" (yesterday's
reading shown with no carry stamp / labeled "Today"). The repair reports claim "the
04:00 hybrid is retired" — that is false for this helper. Contradicts spec §3 ("Today =
current local calendar date"; "switch all day labels … to the new day"). The repair's
tests assert only Repository's boundary, never this twin.

Minimal repair: default `rolloverHour: Int = 0` (or delegate to `Repository.logicalDayKey`),
and update the stale comments (TodayView.swift:762 "rolls at 04:00 like repo.today";
TodayView.swift:5234; SleepModel.swift:410 "same 04:00 boundary").

### F3 (P2) — zone-change mid-window parity gap (effective-dated policy)
`Strand/Data/IntelligenceEngine.swift:3615-3616` (`localDayRun`, `zone: TimeZone.current`)
and worker `DayScoring.swift:379` (`LocalDayWindows(timeZone: tz)` with claim.timezoneId)
apply ONE zone to every day in the scan/window. SQL implements the spec's effective-dated
policy (`scoring_day_segments` over `scoring_timezone_history`,
20260918050000_physiology_calendar_ownership.sql:3-22). After a user changes zone (travel),
historical days' local-midnight bounds can differ between the app (new zone) and SQL
claims (effective zone at event time) for the same instants — spec §3 "Timezone changes
require nonoverlapping, effective-dated policy intervals … App, native code, backend,
worker, and SQL must use the same policy." Pre-existing scope debt (the old code used a
single pass-time offset), NOT introduced by this repair, but T06's travel case is not
actually closed. Not covered by any new test.

### F4 (P2) — T06's America/Los_Angeles spring/fall fixtures are not pinned
The new tests pin America/New_York (AnalyticsEngineDayBoundsTests: 2025-03-09 / 2025-11-02;
DayScoringAdapterTests: 2026-03-08 / 2026-11-01 / 2026-06-15), plus UTC and Asia/Kolkata /
Asia/Kathmandu (+5:30 / +5:45). America/Los_Angeles spring/fall — explicitly named in the
T06 acceptance row — and a zone-change-mid-window fixture are absent. The primitive is
zone-generic so LA would pass, but nothing pins it. Recommend adding LA fixtures.

### F5 (P2) — coach.ts timezone persistence is not round-trip tested
coach.ts now accepts/persists/echoes `timezone` (coach.ts:283 PROFILE_COLUMNS, :324
profileInput with regex validation + DB-trigger 400, :353 publicProfile). The DB trigger
(scoring_record_timezone, 20260918050000) rejects unknown IANA ids — the route's
`/timezone/i` catch maps that to 400. BUT the deno tests use an in-memory REST stub that
never enforces the trigger; the only changed assertion is `timezone: null` in the echo
(coach_test.ts:336). No test PUTs a zone and reads it back, and no test exercises the
invalid-zone 400. The persistence path is code-verified but NOT test-verified.

### F6 (P2, minor) — IntradaySeriesStore residuals around the generation guard
`Strand/Push/IntradaySeriesStore.swift:73-88`:
- `inFlight` is keyed only by `bounds.key` (the constant `"<metric>|live"` key), so a
  pre-midnight in-flight refresh BLOCKS a post-midnight refresh for the same key; when the
  stale one is then dropped by the generation guard, nothing is written until the next
  30 s keepFresh tick (self-heals; the stale write itself IS correctly dropped).
- `loadCached` (:61-69) writes a cached window under `|live` with no generation check; on
  a cold launch after midnight it can surface yesterday's window for up to 30 s. The
  `windows[key] == nil` guard and the day-specific cumulative keys (`|day|<from>`) bound
  the impact. Core guard correct + tested (IntradayStaleResponseTests 3/3).

## What PASSED (code-verified, no finding)

- All lifecycle/zone/significant-time wires are present: init seed, scenePhase `.active`
  with `initial: true` (iOS + macOS), `didBecomeActive`/`didEnterBackground`,
  `NSSystemTimeZoneDidChange`, `UIApplication.significantTimeChangeNotification` (iOS),
  `NSWorkspace.didWakeNotification` (macOS). Backgrounding cancels the timer; the resume
  recompute covers the miss.
- Widgets/complications/watch read paths: no stale-day-as-Today. Widget snapshot uses
  calendar-derived `localDayNumber` (DST-safe; WidgetSnapshot.swift) and drops yesterday's
  curve; the watch complication shows honest recency labels (scoreDay/asOf), never a day key.
- Midnight vs 04:00: no remaining fixed-86400 day selection in the Today paths; the
  `syncHostedResults` yesterday key now uses Calendar arithmetic (AppModel.swift:335);
  `buildTodayFusedRecord`'s ±86,400 range read is a benign loose bound. Sleep wake-date
  keying (mergeSleep / IntelligenceEngine `period_day`) is UNCHANGED — no regression.
- T04: ServerScoreRepository materialization keys every write by `result.day`
  (ServerScoreRepository.swift:663-682) and the hosted revision guard serializes passes —
  delayed prior-day responses land on the OLD day's row.
- Day bucketing: app/worker pass the SAME LocalDayWindows-derived window; worker test pins
  dayWindow == DayScorer calendar math; AnalyticsEngine tests pin byte-identity on
  non-DST days, zone-correct 23 h/25 h answers, and exact-midnight-once.
- Timezone contract trace (single path): ProfileStore.timezone (device) →
  ProfileCloudSync.reconcile mismatch-push → CoachAPI.saveProfile PUT → coach.ts
  profileInput (validated) → profiles.timezone (trigger-validated) →
  scoring_work_items.timezone_id (20260918010000:297, coalesce from profiles.timezone) →
  claim.timezoneId → DayScoring `TimeZone(identifier:)` → `dayWindow`. App never adopts a
  cloud zone (`applyCloud` skips it; mismatch is pushed). Fallback to UTC is the designed
  default for never-synced profiles and converges on the first profile sync.
- #860 persisted selection: shared `@AppStorage("today.selectedDayOffset")`, clamp
  `restoredDayOffset` to [0, maxOffset] (never future, never past earliest banked day;
  negative bounds collapse to 0), explicit Today buttons on iOS top bar / macOS nav /
  Liquid header. Relative offsets are date-line safe by construction.
- Thread-safety/leaks: `Repository.noteDayRolledOver` is @MainActor (Repository is
  @MainActor); coordinator is @MainActor with `queue: .main` + `Task { @MainActor }`
  observers; observers are removed in deinit/stop (no leak); IntradaySeriesStore observer
  is `[weak self]`. Rollover during an in-flight scoring sync cannot cross-day overwrite
  (all writes are explicit day keys).

## NOT VERIFIED

- Actual ≤1 s rollover latency on a physical device (timer + notification edges are
  code-verified; the timer's real wake behavior is not testable in the macOS suite).
- LA spring/fall and zone-change-mid-window day-bounds parity end-to-end (F3/F4) — no
  fixture, and app↔SQL cross-parity needs a staged Postgres.
- coach.ts timezone round-trip against a real Postgres trigger (F5).
- T02 first-render timing after a real multi-day suspension with network catch-up.

---

## Re-audit round (fix verification, current working tree, 2026-10-03)

Re-verified ONLY the fixes to audit-g1-day's findings. Targeted tests run by this auditor (all pass):

- TodayDayRolloverTests 13/13 (was 8; +F1 timer-loop recompute, +F1b same-day zone bump, +3 F2 boundary/carry/stamp)
- IntradayStaleResponseTests 6/6 (was 3; +F6a in-flight release, +F6b loadCached prior-day/current-day)
- IntradaySeriesTests 27/27 (incl. the justified F6b fixture edit)
- ZoneHistoryDayRunTests 4/4 (F3)
- AnalyticsEngineDayBoundsTests 12/12 (was 10; +LA spring/fall, +zone-change-mid-run)
- coach_timezone_test.ts 1/1 against real local Postgres (F5, not in the parent's fix list but present)

### F1 (DayRolloverCoordinator timer edges) — PASS
`Strand/App/AppModel.swift:3010-3040` (`scheduleMidnightTimer`): the loop now calls
`recomputeTodayIfNeeded()` at the TOP of every iteration AND after each sleep; boundary and delay are
re-derived from a fresh `Calendar.current` on every arm; sleep is injectable
(`sleep: @escaping (UInt64) async -> Void`), and `testTimerLoopRecomputesTheBoundaryItWakesJustBefore`
drives the exact sub-boundary wake that previously re-armed a ~24 h sleep. Traced the fixed flow: an
early wake → 1 s retry → loop-top recompute rolls the crossed day before re-arming the next boundary.
F1b (same-date zone change) is wired end-to-end: `Repository.noteZoneContextChanged()` bumps
`zoneContextSeq` (+ posts `dayKeyDidChange`), and BOTH Today reload keys include it
(TodayView.swift:1810-1811, LiquidTodayView.swift:456); `testSameDayZoneChangeBumpsZoneContextEvenWhenDayUnchanged`
pins it. Remaining risk (documented, low): on macOS there is still no significantTimeChange
notification, so a continuously-active Mac across a fall-back DST transition fires the rollover ~1 h
late (the day still rolls, never skips; iOS re-anchors at the transition via significantTimeChange).

### F2 (VitalSignsSummary 04:00 twin) — PASS
`Strand/Screens/VitalSignsSummary.swift:475-483` now defaults `rolloverHour = 0`; SleepModel comment
updated (SleepModel.swift:410-415); grep confirms NO production `rolloverHour = 4` /
`logicalDayRolloverHour = 4` remains (only parameterized test usages). New tests pin the boundary and
the carry/stamp behavior (`testBodyVitalSignsLogicalDayRollsAtLocalMidnight`,
`testSleepHeadlineCarryUsesTheMidnightBoundary`, `testSleepHeadlineStampsAPriorDayCarryAcrossMidnight`).

### F4 (LA DST fixtures) — PASS
`AnalyticsEngineDayBoundsTests` + `testLocalDayWindowIsTheShippedDSTAnswerInLosAngeles` (spring 2025-03-09
23 h @ 08:00Z, fall 2025-11-02 25 h @ 07:00Z, exact instants) and + `testZoneChangeMidRunWindowsFollowEachZonesRule`.
Engine unchanged; 12/12.

### F5 (coach.ts timezone round-trip) — PASS (was not in the parent's fix list, but present and correct)
`supabase/functions/tests/coach_timezone_test.ts` loads the real migration chain onto a local Postgres,
proves the `scoring_profile_timezone` trigger is attached, PUTs real zones (round-trip stored + echoed),
rejects `Not/AZone` as 400 `invalid_profile` via the DB authority, tolerates null, and covers a
NULL-timezone back-compat row. Passed 1/1 against real Postgres.

### F6 (IntradaySeriesStore residuals) — PASS
`Strand/Push/IntradaySeriesStore.swift:56-59` — `noteDayRolledOver()` now also `inFlight.removeAll()` so a
pre-midnight refresh no longer blocks the new day's `|live` refresh (its write still dropped by the
generation guard). `loadCached` (61-71) captures the generation before the await, re-checks after, and
refuses to seed a `|live` window whose `to` does not reach the current local midnight. Three new tests
pin the slot-release, the prior-day rejection, and the current-day control. The `IntradaySeriesTests`
edit is JUSTIFIED: the original fixture window was dated 2026-10-01 (long past), which the new F6b rule
correctly refuses to seed; the test's intent (cache-first paint + never-overwrite-a-live-window) is
preserved with a current-dated fixture. Note: `noteDayRolledOver` now drops in-flight HISTORICAL-day
reads too (generation bump applies to all keys); those are day-specific and re-fetched ≤30 s later —
minor, self-healing, not a new correctness issue.

### F3 (effective-dated zone journal) — FAIL (new P1 regression in the fix)
The per-day journal resolution itself is implemented and tested (`IntelligenceEngine.localDayRun`
IntelligenceEngine.swift:3625-3638, `zone(at:)`, ZoneHistoryDayRunTests 4/4; bounded mid-day divergence
documented in the doc comment). BUT the fix introduces a regression for users who travel WITHOUT cloud
mode:

- The journal is ALWAYS seeded (never empty): Profile.swift:203 seeds `[TimezoneChange(current, 0)]`
  at first use and reloads the persisted journal on later launches (Profile.swift:201).
- It is appended ONLY in `refreshTimezoneFromDevice()` (Profile.swift:247-253), whose ONLY call site is
  `ProfileCloudSync.reconcile` (ProfileCloudSync.swift:66), gated on
  `CloudPushSettings.isEnabled && CoachAPI.shared.isAvailable` (ProfileCloudSync.swift:38).
- So for a non-cloud (or pre-first-sync) user whose device zone id changes (travel), `localDayRun`
  resolves EVERY day — including TODAY — in the stale launch-time zone (IntelligenceEngine.swift:3636:
  `zoneHistory.isEmpty ? defaultZone : zone(at:...)`; the journal is never empty, so the
  "empty journal = pre-journal behavior" escape is unreachable in production).
- Consequence: today's window/key come from the old zone while `Repository.localDayKey(Date())` uses
  live `TimeZone.current`; a date-line-crossing trip mis-keys today's scored data (dashboard reads the
  new-zone key → blank Today), and any zone-id travel shifts the day-window bounds by the offset
  difference. This is a REGRESSION vs the pre-fix code, which used live `TimeZone.current` for all days.
- NOT covered by ZoneHistoryDayRunTests: they test empty-journal and appended-journal, never a stale
  journal with a changed `TimeZone.current`.

Minimal repair (one of): (a) append a journal entry at `ProfileStore` init / on every launch when
`TimeZone.current.identifier != timezoneHistory.last?.zoneId`; or (b) call `refreshTimezoneFromDevice()`
from an app-active lifecycle hook that is NOT gated on cloud mode; or (c) in `localDayRun`, resolve
today (offset 0) always in `defaultZone` (live `TimeZone.current`) and use the journal only for past days.

### New-issue scan in the audited area
- `noteZoneContextChanged` posts `dayKeyDidChange` on every significant-time change (incl. DST
  transitions) → IntradaySeriesStore generation bumps and in-flight intraday reads drop more often than
  strictly needed; all self-heal ≤30 s. Not a correctness issue.
- No other regressions found in the F1/F2/F4/F5/F6 areas.

### F3 round-3 re-verification (final) — PASS
Round-3 landed by repair-daybucket addresses the P1 regression exactly per the named options.
Verified in the current tree:
1. Launch-time append — Strand/Data/Profile.swift:222-231: if `timezoneHistory.last?.zoneId != TimeZone.current.identifier`, init appends the live zone (effectiveFrom now), sets `timezone`, and marks `cloudDirty = true` so the next cloud sync pushes it. Journal can never be stale at launch after travel.
2. Un-gated zone-change observer — Profile.swift:235-240: observes the EXISTING `Repository.dayKeyDidChange` (posted by the coordinator on NSSystemTimeZoneDidChange / significant-time-change) and calls `refreshTimezoneFromDevice()` with NO cloud gate; removed in deinit (:241-243). `refreshTimezoneFromDevice()` is a no-op unless the zone changed, so the extra midnight/rollover notifications are cheap. Registered before the coordinator's own observer (ProfileStore property init precedes AppModel.init body), and `dayKeyDidChange` is a static name, so ordering is safe.
3. TODAY invariant — IntelligenceEngine.swift localDayRun: `offset == 0` always returns `reference.window(of: date)` in `defaultZone` (= TimeZone.current in production), never a journal zone; past days keep their journal zones. This blocks the regression even before the append/observer run: today's key/bounds always match `Repository.localDayKey(Date())`.
4. Tests: ZoneHistoryDayRunTests now 7 (was 4): `testStaleJournalNeverMisBucketsToday` (stale journal [LA@0], live NY: today in NY, past day in LA), `testProfileStoreLaunchAppendsWhenTheJournalIsStale` (persisted stale zone → launch appends live zone + cloudDirty), `testZoneChangeNotificationRefreshesTheJournalWithoutCloudMode` (post dayKeyDidChange → observer appends without cloud mode). These cover exactly the regression named in the round-2 audit.

Targeted tests run (all pass): ZoneHistoryDayRunTests 7/7, ProfileTimezoneSyncTests 4/4, TodayDayRolloverTests 13/13, IntradayStaleResponseTests 6/6 (macOS xcodebuild, EXIT 0); AnalyticsEngineDayBoundsTests 12/12 (StrandAnalytics). No full suites re-run.

Residual (documented, low, not blocking): a mid-session travel appends the journal only when the next `dayKeyDidChange`-posting event fires (sub-second for zone/significant-time changes); until then TODAY is already correct (live-zone invariant) and only a past day within the same run could still resolve in the pre-change zone — that day re-scores on the next pass with the appended journal. No new issues found in the audited area.
