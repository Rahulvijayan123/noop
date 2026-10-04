# repair-daybucket — G1 day-bucketing + timezone write

Branch: audit/core-plumbing-20261003 · Worktree: nara-core-plumbing
Worker: repair-daybucket (findings g1-day-ui.md T05/T06 second half)
Date: 2026-10-03

## What was done

1. **Shared day bucketing switched to `LocalDayWindows` (T06, headline DST defect).**
   - `AnalyticsEngine.analyzeDay` gained `dayWindow: LocalDayWindow? = nil`. When supplied, the
     day-membership filters (`tsInDay`) use the zone-correct half-open `[start, end)` bounds from
     `LocalDayWindows`; the key and the bucket come from the SAME lookup, so they agree by
     construction. `nil` (the default) keeps the old fixed-offset + 86,400 block, byte-identical for
     every existing pure-function caller/test on UTC.
   - New `AnalyticsEngine.localDayWindow(day:zone:) -> LocalDayWindow?` (switch-over helper).
   - `LocalDayWindows.window(ofDayKey:)` added (parse a `YYYY-MM-DD` key into a window).
   - No metric formulas changed — plumbing only. The sleep-detector `tzOffsetSeconds` guard, the
     main-night scored pick, and the habitual-midsleep learner are untouched.

2. **IntelligenceEngine multi-day scan (task 2): the single pass-time offset is gone.**
   - New `IntelligenceEngine.localDayRun(endingAt:count:zone:)` builds the trailing local-day run from
     `LocalDayWindows` (newest first; each entry is a `LocalDayWindow`).
   - `analyzeRecent` (the 21-day scan) derives `dayStart`/`day`/the calendar-day read bounds/the
     `analyzeDay` `dayWindow`/the day-cache prune set / the pass-2 `oldestDay`/`newestDay` / the
     legacy-snapshot day-start lookup / the heal-window membership / the edit-day attribution from the
     run instead of `nowLocalMidnight - offset * 86_400` + `dayString(_, offsetSec:)`.
   - The sleep read-window END for a PAST day now uses the day's zone-correct next local midnight
     (was `dayStart + 86_400`, an hour short on a 25 h day). The pinned `sleepReadWindowEnd` function
     itself is unchanged (its StrandTests were not touched); only the call site in `analyzeRecent`
     passes the corrected bound, byte-identical for every 24 h day.
   - `recomputeFitnessAgeOnly` and the 60-day steps-calibration run use `localDayRun` keys too.
   - Byte-identical to the old arithmetic on every non-DST day (locked by tests, see below); the
     zone-correct answer on DST days.

3. **Timezone write (task 3 / contract C2).**
   - `ProfileStore` gained a persisted `timezone` field (default `TimeZone.current.identifier` on a
     fresh install), included in `cloudSnapshot` (the upload payload), refreshed from the device by
     `refreshTimezoneFromDevice()` (marks dirty on change → travel propagates), and NEVER adopted from
     the cloud in `applyCloud` (the phone is the timezone authority; a server `'UTC'` default must not
     win — the mismatch is pushed instead).
   - `CloudProfile` gained `timezone: String?`. `ProfileCloudSync.reconcile()` refreshes the zone at
     each sync and pushes when: dirty, stored-fields-with-no-remote, zone changed, or the remote zone
     is non-nil and disagrees with the phone.
   - `CloudEnrollment.swift` NOT touched: the enrollment payload carries no profile fields, so the
     timezone travels via the profile sync that runs on app-active / after enrollment.

## Tests run

- `Packages/StrandAnalytics`: `swift test` → **2167 passed, 0 failed** (baseline 2163; +4 new
  `AnalyticsEngineDayBoundsTests`).
  - New pins: (a) non-DST day: `dayWindow` == fixed-offset path == formatter pre-filter
    (byte-identical, incl. fractional +5:45); (b) DST days: shipped answer == the zone-correct
    bounds (spring-forward 2025-03-09 no longer double-counts 03-10's first hour; fall-back
    2025-11-02 no longer drops the day's last hour); (c) exact boundary instants pinned.
- `Tools/CloudWorker`: `CPATH=/opt/homebrew/opt/libpq/include LIBRARY_PATH=/opt/homebrew/opt/libpq/lib swift test`
  → **243 passed, 6 skipped, 0 failed** (package change is source-compatible with the worker).
- macOS `StrandTests` (xcodebuild): ProfileCloudSyncTests 7/7 + new ProfileTimezoneSyncTests 4/4,
  and a 111-test batch covering the Intelligence*/day-boundary/day-cache/repair suites → **all passed**.
  (One earlier batch showed 4 transient failures while a sibling worker's `xcodebuild` was running
  concurrently; the identical batch then passed 111/111 twice — environment interference, not the
  change.)
- Full `StrandTests` suite: **2473 executed, 2 skipped, 3 failures — all three PRE-EXISTING at HEAD**
  (verified by running the same test at a pristine `HEAD` worktree): SkinTempAbsoluteDisplayTests +
  SleepCarriedStampTests (the documented Pacific-time caption pair) and
  IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets (a 90 s-freshness
  boundary fixture that fails at HEAD too). **No new failures from this change.**

Re-audit test results: StrandAnalytics `swift test` → **2169 passed / 0 failed** (was 2167;
  +2 F4 tests). macOS StrandTests: ZoneHistoryDayRunTests 4/4 + ProfileTimezoneSyncTests 4/4 +
  ProfileCloudSyncTests 7/7, and the 139-test Intelligence/day-boundary batch → **all passed**.
  Full StrandTests suite at this snapshot also shows failures in SIBLING-owned in-flight domains
  (IntradaySeriesTests/IntradaySeriesStore, PlacementTests/Placement — both untracked/in-tree
  sibling work; TestBundleRobustnessTests; RescoreBackgroundScheduler + SleepWearHistoryRepair which
  pass 27/27 in isolation) plus the 3 pre-existing-at-HEAD failures. None touch this worker's files.

## Contract decisions applied

- C2 half-open `[start, end)` bounds everywhere in the scoring paths; never fixed 86,400 blocks
  (the read-window call sites now use the zone-correct next midnight; the pinned
  `sleepReadWindowEnd` helper itself is unchanged).
- Timezone authority = phone's local IANA zone, written on profile sync (+ enrollment via the
  subsequent reconcile). Server claims read `profiles.timezone` unchanged.
- Byte-identity on non-DST days is a hard requirement and is locked by tests.

## Re-audit round (audit-g1-day F4 + F3) — 2026-10-03

**F4 (LA DST pins + zone-change-mid-window) — DONE, engine already correct.** Added to
`AnalyticsEngineDayBoundsTests`:
- `testLocalDayWindowIsTheShippedDSTAnswerInLosAngeles`: America/Los_Angeles spring-forward
  (2025-03-09, 23 h, [08:00Z, 08:00Z+23h)) and fall-back (2025-11-02, 25 h, [07:00Z, 07:00Z+25h))
  pins through `analyzeDay` (steps total + last-hour sleep attribution follow LA's own windows; the
  old fixed-offset answer differed only where it was wrong).
- `testZoneChangeMidRunWindowsFollowEachZonesRule`: the same UTC instant (2025-11-02 05:00Z) is
  Nov 2 in America/New_York and Nov 1 in America/Los_Angeles; each zone's window contains the
  instant exactly as its key says, and each starts at its own local midnight. (The mid-run zone
  change is expressible at this layer as two windows — the `window(ofDayKey:)`/`localDayWindow`
  APIs take a zone per call.)
- Verified `LocalDayWindows.window(ofDayKey:)` against these fixtures — **no engine defect found**;
  test additions only.

**F3 (travel zone-history for `localDayRun`) — DONE, took the preferred option (phone-side
effective-dated zone journal).**
- `ProfileStore` gained `TimezoneChange { zoneId, effectiveFrom }` and a persisted
  `timezoneHistory` journal (`profile.timezoneHistory`): seeded with the current zone on first use
  (a fresh install / pre-journal upgrade), appended in `refreshTimezoneFromDevice()` whenever the
  device's zone id changes. Mirrors the server's `scoring_timezone_history`.
- `IntelligenceEngine.localDayRun` now resolves each historical day in the zone effective for it
  from `zoneHistory` (via `IntelligenceEngine.zone(at:journal:fallback:)`), instead of the phone's
  CURRENT zone for every day. After travel, a past day keeps the zone it actually happened in, so
  the app's historical bounds agree with SQL for the same instants. `zoneHistory: []` (the default)
  keeps the pre-journal behavior; all three call sites (analyzeRecent, recomputeFitnessAgeOnly,
  steps calibration) pass `profile.timezoneHistory`.
- Documented bounded divergence (not redesigned): a zone change landing MID-day buckets that whole
  day in the pre-change zone (all-or-nothing day window), where the server's per-instant
  `scoring_local_day_v2` splits it.
- Tests (`StrandTests/ZoneHistoryDayRunTests.swift`, NEW): NY→LA travel — pre-travel day stays in NY
  (05:00Z), post-travel day in LA (08:00Z); empty journal uses the default zone; `zone(at:)` picks
  the latest effective entry / falls back; ProfileStore seeds + appends the journal.

**P1 server gap — now RESOLVED in-tree by another worker.** `supabase/functions/_shared/coach.ts`
now accepts/validates/persists `timezone` (`PROFILE_COLUMNS`, `profileInput`, `publicProfile`,
400 on an invalid zone via the `scoring_record_timezone` trigger). The app-side write from this
worker + that server-side change complete the loop; my earlier "server needs no change" finding is
superseded (the claim side was already correct; the WRITE side was the gap and is now fixed).

## Re-audit ROUND 3 (audit-g1-day F3-P1: stale-zone-journal regression) — 2026-10-03

**The regression (confirmed):** the zone journal is always seeded and appended ONLY via
`refreshTimezoneFromDevice()` → `ProfileCloudSync.reconcile`, gated on cloud mode. A non-cloud /
pre-first-sync user whose zone changed got EVERY day — including TODAY — bucketed in the stale
launch-time zone, while the dashboard reads `TimeZone.current` → mis-keyed/blank Today after a
date-line trip. Worse than the pre-fix live-`TimeZone.current` behavior.

**Fix (auditor option (a) + a non-cloud hook) — DONE, in my files only:**
1. `Strand/Data/Profile.swift` init: when `TimeZone.current.identifier != timezoneHistory.last?.zoneId`,
   APPEND `(current, now)` at launch (and update the persisted `timezone` + mark `cloudDirty`), so the
   journal never goes stale at launch after travel.
2. `Strand/Data/Profile.swift` init: register an observer for the EXISTING `Repository.dayKeyDidChange`
   (posted by repair-dayui's DayRolloverCoordinator on `NSSystemTimeZoneDidChange` / significant-time
   change) that calls `refreshTimezoneFromDevice()` — an UN-GATED (non-cloud) zone-change hook so a
   mid-session zone change appends to the journal immediately for every user. Repository/AppModel NOT
   edited. Observer removed in `deinit`.
3. `Strand/Data/IntelligenceEngine.swift` `localDayRun`: TODAY (offset 0) always resolves in the phone's
   CURRENT zone (`defaultZone` = `TimeZone.current`), never a stale journal zone — the invariant holds
   even before the launch-append/observer have run. Past days keep their effective-dated journal zones.
4. Tests (`StrandTests/ZoneHistoryDayRunTests.swift`): `testStaleJournalNeverMisBucketsToday`
   (stale journal [LA@0], current zone NY: today = NY 05:00Z, past day = LA 08:00Z),
   `testProfileStoreLaunchAppendsWhenTheJournalIsStale` (stale persisted journal + timezone → launch
   appends current, count 2, cloudDirty true), `testZoneChangeNotificationRefreshesTheJournalWithoutCloudMode`
   (posts `Repository.dayKeyDidChange` → observer reverts a stale timezone and appends, no cloud).
5. Bounded divergences still documented (mid-day travel day all-or-nothing window; per-instant server
   split differs).

**Round-3 test results:** ZoneHistoryDayRunTests 7/7; ProfileTimezoneSyncTests 4/4 + ProfileCloudSyncTests
7/7; 142-test Intelligence/day-boundary batch 0 failures; FULL StrandTests suite 2499 executed,
2 skipped, 3 failures — all three are the documented PRE-EXISTING-at-HEAD pair + the IntradayWording
boundary test; zero new failures. StrandAnalytics 2169/0; CloudWorker 247/6skip/0; app build SUCCEEDED.

## Worker behavior change + rollout note (task 4)

- The worker links the same `StrandAnalytics` package, so the NEW `dayWindow:` parameter is available
  to it. **However, the worker call site still needs to pass it** —
  `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift:372-385` currently calls
  `AnalyticsEngine.analyzeDay(...)` with only `tzOffsetSeconds:` (the offset at the claimed day's
  start), so its internal re-bucketing keeps the old fixed-offset + 86,400 window: on the 23 h
  spring-forward day it double-counts the boundary hour into the next day, and on the 25 h fall-back
  day it drops the day's last hour from sleep attribution. That file is NOT in this worker's
  ownership; the required one-line change is:
  `dayWindow: LocalDayWindows(timeZone: tz).window(ofDayKey: claim.day)` (the worker already computes
  `dayStart`/`dayEnd` calendar-correctly).
  - Effect of the fix on worker behavior: DST transition days only (23 h/25 h days and days on the far
    side of a transition) — boundary-hour samples/sessions move to the correct day; every other day is
    byte-identical.
  - Rollout: a DEPLOYED WORKER REBUILD is required before server results change. Not executed here
    (rollout is out of scope for this worker).

## Gaps / NOT VERIFIED / follow-ups

- **P1 — server profile route does not persist `timezone`.** The task stated "server side needs no
  change", but the deployed profile endpoint
  (`supabase/functions/_shared/coach.ts`) does NOT accept the field: `profileInput()` handles only
  `displayName`/`dateOfBirth`/`sex`/`heightCm`/`weightKg`, `PROFILE_COLUMNS` excludes `timezone`, and
  `publicProfile()` does not return it. The app now SENDS `timezone` on every profile upload, but the
  server silently ignores it, so `profiles.timezone` stays `'UTC'` until coach.ts is extended
  (add `timezone` to `profileInput` — validate it against `pg_timezone_names` —, `PROFILE_COLUMNS`, and
  `publicProfile`). coach.ts is not in this worker's ownership; flag to the parent/attest owner.
- **Transient extra PUT per foreground while the server gap exists**: because `publicProfile` does not
  echo a stored zone, `reconcile()` cannot confirm the server holds the phone zone and re-uploads on
  each app-active (a small, idempotent PUT; converges the moment the server returns the field).
- **Known residual (out of scope, documented):** `AppModel.syncHostedResults` "yesterday" key still
  uses `localDayKey(now - 86_400)` (findings Q5/Q8) — AppModel.swift is repair-dayui's file.
  `computeHabitualSleep` and `sleepEditedDaily` still key/score with the pass-time offset (learner and
  main-night math, not day attribution); left unchanged to keep the pinned tests and formulas stable.
- **Not executed:** deployed worker rebuild; device/staging verification of DST fixtures end-to-end
  (app→backend→SQL); the Android twin still pins the old fixed-offset answer and will diverge on DST
  days until its twin switch-over lands (separate workstream).
