# Workstream g1-day-ui — Today/midnight rollover, timezone/DST policy, day attribution, UI/cache

Branch: audit/core-plumbing-20261003 (baseline 56809066) · Audit-only worktree: nara-core-plumbing
Scope: G1 (T01–T07, T30 where day-related). All evidence is code-verified from THIS tree (file:line).
No device/staging/deployed verification was possible; blocked checks are listed at the end.

## Summary verdicts

| Req/Test | Verdict | One-line reason |
| --- | --- | --- |
| T01 | FAIL | No next-boundary timer; rollover is data-driven (refreshSeq) or the 30-min backstop; logical day also rolls at 04:00, not midnight. |
| T02 | FAIL | Resume re-renders cached state; the day is recomputed only after a backfill/refresh completes (no pre-render date recompute). |
| T03 | PARTIAL (FAIL vs spec) | Past-day selection is @State only, not persisted; no explicit "Today" action (swipe/picker only). |
| T04 | PARTIAL (FAIL gap) | Day-keyed stores prevent cross-day overwrite, but IntradaySeriesStore has no revision/generation guard for the shared `…|live` key. |
| T05 | PARTIAL | SQL attributes by occurrence time (half-open); shared AnalyticsEngine fixed-86400 bucketing double-counts a boundary hour on DST days. |
| T06 | FAIL | Shared app/worker day bucketing uses fixed offset + 86400 blocks (`LocalDayWindows` correct primitive unused); app zone (phone local) ≠ SQL zone (profiles.timezone, default UTC). |
| T07 | PARTIAL (PASS structure) | Session bounds preserved; sleep grouped by wake date (Calendar); cross-midnight labeled; DST-day totals via AnalyticsEngine share T06 defect. |
| T30 | NOT VERIFIED (device) | Diagnostics/replay surfaces exist; resume-UI day/input revision equality needs a device capture. |
| G1 overall | FAIL | See T01–T06. |

---

## Q1 — Active timezone authority; is it consistent?

**App UI/local store: phone local IANA zone (`TimeZone.current`).**
- `Strand/Data/Repository.swift:727-730` — `dayKeyFormatter` has no `timeZone` set, so it formats in the system zone; `localDayKey(_:)` = system-zone `yyyy-MM-dd`.
- `Strand/Data/Repository.swift:741-743` — `logicalDay(_:)` = `now.addingTimeInterval(-4*3600)`; logical day rolls at 04:00 local (`logicalDayRolloverHour = 4`, line 733).
- `Strand/Data/IntelligenceEngine.swift:630-632` — local scoring captures `tzOffset = TimeZone.current.secondsFromGMT()` at pass time and keys days from it.

**SQL ingest day attribution: `profiles.timezone`, default `'UTC'`, never written by the app.**
- `supabase/migrations/20260819190000_frwhoop_base_schema.sql:32` — `timezone text not null default 'UTC'`.
- `supabase/migrations/20260918010000_production_scoring_durability.sql:490-493` — `invalidate_scoring_stream_v2` computes the affected day via `scoring_local_day_v2(b->>'ts', p.timezone)`.
- `supabase/migrations/20260921104000_server_unrepresentable_clock.sql:11` — `(observed at time zone coalesce((select name from pg_timezone_names where name=p_zone),'UTC'))::date`.
- `Strand/Data/Profile.swift:176-179` and `Strand/Data/ProfileCloudSync.swift:5-20` — `CloudProfile` syncs only displayName/dateOfBirth/sex/heightCm/weightKg; **no timezone field**. No app write to `profiles.timezone` exists anywhere in `Strand/`, `Packages/`, or `Tools/CloudWorker/`.

**Worker: `claim.timezoneId`, resolved from legacy work items, else physiology items, else UTC.**
- `Tools/CloudWorker/Sources/frwhoop-worker/ScoringLane.swift:592-606` — `resolveTimezone(...)` coalesce `scoring_work_items.timezone_id` → `physiology_work_items.timezone_id` → `'UTC'`; comment: "`scoring_jobs_v2` carries no timezone."
- `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift:255` — `TimeZone(identifier: claim.timezoneId) ?? UTC`.

**Conclusion: NOT CONSISTENT.** The app attributes local days in the phone zone; the server attributes by `profiles.timezone` (UTC by default, never synced from the app). A phone west of UTC, or any traveler, gets app-day ≠ server-day ownership for the same instant. This violates spec §3 "App, native code, backend, worker, and SQL must use the same policy" and the "Server OS timezone must never decide user day ownership" rule (a UTC default is a server-decided zone). The server does at least have the effective-dated machinery (`scoring_timezone_history`, `scoring_timezone_at`) — it is just never fed from the device.

---

## Q2 — Today rollover mechanics (T01)

**No next-boundary timer exists in either Today view or AppModel.**
- `Strand/Liquid/LiquidTodayView.swift:450` — `.task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)-\(dayCycleModeRaw)") { await load() }` — reload only on data/day-cycle/feature change.
- `Strand/Screens/TodayView.swift:1758-1759` — `.task(id: TodayLoadKey(seq: repo.refreshSeq, offset: selectedDayOffset, dayCycleMode: ...))`.
- `Strand/Screens/TodayView.swift:393-405` — "TodayView deliberately does NOT observe `LiveState` directly" (no 1 Hz re-render to re-evaluate `repo.today`).
- `Strand/App/AppModel.swift:674-725` — the only periodic driver is the 30-min backstop (`Task.sleep(nanoseconds: 1_800_000_000_000)`, line 724), and `Repository.refresh()` skips the publish+`refreshSeq` bump when merged caches are byte-identical (`Strand/Data/Repository.swift:1000-1006`), so a data-less tick does not even re-fire the Today reload.
- No `NSSystemTimeZoneDidChange`, no `UIApplication.significantTimeChange` / `applicationSignificantTimeChange`, no clock-change observer anywhere in `Strand/`, `StrandiOS/` (grep over the tree returns nothing).

**Consequences:**
1. Foreground, no new sensor data, no network, no DB revision change ⇒ the day does NOT roll over at midnight; it waits for the next data-driven refresh or the 30-min backstop. T01 (≤1 s rollover) FAILS.
2. The boundary is not local midnight anyway: `logicalDay` rolls at 04:00 local (`Repository.swift:732-743`), so between 00:00 and 04:00 "Today" still labels and shows the previous calendar day. The spec requires the new calendar day within 1 s of local midnight. Documented product decision (#144/#304; `Repository.swift:562-586` pre-04:00 local-night carve-out) but it directly conflicts with the spec contract, and it is not exposed as a setting.
3. Offline/new-day empty state: when the rollover finally runs, `resolveToday`/`resolveDisplayDay` show the new (empty) day or carry prior values with an explicit "Last night · <date>" label (`TodayView.swift:884-892` `lastScoredRecoveryDay`, carried-caption helpers), so the *copy* rule is respected; the problem is only WHEN the rollover happens.

---

## Q3 — Stale async responses (T04)

**Day-keyed storage prevents cross-day overwrite (good), with one live-key race (bad).**
- `Strand/Push/ServerScoreRepository.swift:148-176` — owner-tagged per-(owner,device,day) cache; a different owner's cache is not returned. `refresh(day:deviceId:)` (180-197) requests a specific day; `snapshot.day = scoring["day"] ?? requested day` (line 378) — response is bound to its day.
- `Strand/App/AppModel.swift:305-336` — `syncHostedResults` fetches `[localDayKey(now-86400), localDayKey(now)]` (line 316; NOTE fixed 86_400 "yesterday", wrong around DST) + changed days; a result is written only when `hostedWrittenRevision[day] != result.resultRevision` (line 324); `HostedResultMaterializer.persist` keys every write by `result.day` (`ServerScoreRepository.swift:663-682`), so a delayed pre-midnight response lands on the OLD day's row, never the new Today row. In-flight guard `hostedSyncInFlight` (line 306) serializes passes.
- `Strand/Push/IntradaySeriesStore.swift:40-54` — `refresh` writes `windows[bounds.key] = window` with NO revision/generation/cancellation guard. For line metrics (HRV/RHR/resp) the live key is constant `"<metric>|live"` (`Strand/Push/IntradaySeries.swift:237`), so a request started before midnight can land after midnight and overwrite the new day's window with an old window (its own from/to are drawn per `IntradaySeriesSection.swift:170-172`). Self-heals within the 30 s `keepFresh` loop (`IntradaySeriesSection.swift:33-47`), but the spec's "cannot block or reverse rollover" is not code-guaranteed.
- `TodayView` day-scoped cache is correctly keyed `(seq, viewed day key)` and explicitly "a day rollover misses even at an unchanged seq" (`TodayView.swift:5087-5097`).

---

## Q4 — Past-day browsing & yesterday preservation (T03, T01)

- `selectedDayOffset` is plain `@State = 0` in both `TodayView.swift:625` and `LiquidTodayView.swift:128`; no persistence (no @AppStorage, no store key). It survives while the view stays mounted, but not a process restart; SwiftUI TabView retention decides tab-switch behavior — not code-guaranteed.
- Explicit past-day selection stays selected while browsing (swipe/calendar set an offset, `.task(id:)` re-loads). "Today action returns to current date": there is no explicit Today action; the only paths back to offset 0 are swiping right until clamped or picking today's date in the graphical picker (`TodayView.swift:1478-1522`, `LiquidTodayView.swift:259-269`). T03 "Today action returns to current date" is only partially satisfied.
- Yesterday's row is a distinct day key (`DailyMetric.day`), never rewritten by the new day's row; post-rollover carries are explicitly labeled prior-day (`TodayView.swift:884-892`, `LiquidTodayView.swift:2094` "Last night · <date>"). No accumulator re-keying from yesterday into the new day was found in the Today paths; `RollingStepsAverage` is pure day-key arithmetic (`Strand/Data/RollingStepsAverage.swift:14-28`).

---

## Q5 — DST safety of every active day-derivation path (T06)

| Path | Mechanism | DST-safe? |
| --- | --- | --- |
| App `Repository.localDayKey` | system-zone DateFormatter | Yes (formats instant in zone) |
| App `Repository.logicalDay`/`logicalDayKey` | fixed −4 h shift then zone format | Yes for the key (zone format); it is a 04:00 logical boundary by design |
| App `Repository.logicalDayStart` | `Calendar.startOfDay` | Yes |
| App `IntelligenceEngine.midnightLocal` (shared scoring day floors) | `ts - floorMod(ts+offsetSec, 86400)` fixed offset | **NO** — off by an hour across a DST transition (engine's own admission) |
| Shared `AnalyticsEngine.dayString(ts, offsetSec:)` / `dayStartUtcSeconds` + `tsInDay` fixed `+86400` | fixed offset + fixed 86400 blocks | **NO** — see below |
| `LocalDayWindows` (StrandAnalytics) | zone-rule-correct, tested | Yes — but **unused** |
| Worker `DayScoring.dayStartUnix`/`nextDayStartUnix` | Calendar in claim zone | Yes |
| Worker `DayScoring.analyzeDay` call | passes `tz.secondsFromGMT(for: dayStart)` | Partially — day bounds yes, but engine re-buckets with fixed 86400 |
| Worker `IntradaySeries.Layout` | partitions `[dayStart, dayEnd)` | Yes |
| SQL `scoring_local_day_v2` / `(observed at time zone zone)::date` | zone conversion | Yes |
| SQL `physiology_calendar_ownership` (`20260918050000…:1-19`) | effective-dated timezone history, half-open segments | Yes (policy) |
| `AppModel.syncHostedResults` day list | `localDayKey(now − 86_400)` | No (fixed 86400 "yesterday" may be the same calendar day on a 25 h day) |

**The headline DST defect (shared app+worker scoring):** `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift:194-199` states verbatim: "This is a UTC midnight that callers pair with one captured offset and fixed 86,400-second blocks, so every boundary beyond a clock change sits an hour from the local midnight it names. `LocalDayWindows` is the zone-rule-correct primitive built to replace that, and is deliberately called by nothing yet." The day filter itself is `(ts + tzOffsetSeconds) >= dayStartUtc && < dayStartUtc+86_400` (`AnalyticsEngine.swift:502-504`), used for sleep-day attribution (`$0.end`, line 553) and day-stream derivation. On a 23 h spring-forward day this window overlaps the next day's first hour, so boundary samples are attributed to both days (double count) or neither, depending on the adjacent day's window. The worker runs this engine per day with the day's own start offset (`DayScoring.swift:372-384`), the local engine with ONE pass-time offset for the whole 21-day window (`IntelligenceEngine.swift:630-633`), so historical days are all bucketed with today's offset. `LocalDayWindowsTests.swift` pins both answers so the divergence is visible.

---

## Q6 — Cross-midnight / multi-day batch attribution (T05)

- SQL: samples attribute by occurrence time. `invalidate_scoring_stream_v2` derives `day` and `through_day` per row via `scoring_local_day_v2(row.ts, p.timezone)` (`20260918010000_production_scoring_durability.sql:490-504`), so a multi-day batch dirties each affected day; no batch label or upload date controls it. `period_day` on `server_sleep_nights` is the wake-day for a night (`20260916160000_scoring_service_state.sql:67,289-320`), i.e. wake-date sleep association, consistent with the app.
- Exact midnight: `(observed at time zone zone)::date` maps `00:00:00` local to the NEW date (once). Worker bounds are half-open `[dayStart, dayEnd)` (`DayScoring.swift:261-264`), so exact midnight belongs to the new day. PASS in SQL/worker.
- **Defect:** the shared engine's fixed-86400 bucketing (Q5) double-counts/mis-attributes the boundary hour on DST days — T05's "every correct day once" is violated on DST transition days in the daily aggregates and sleep attribution.
- App sleep display groups by wake date with Calendar arithmetic and labels cross-midnight spans ("Fri 13 → Sat 14 Jun", `SleepModel.swift:101-120,252-258`) — structurally correct.

---

## Q7 — Five-minute window day allocation (publish_metric_series_v1 shape)

- `Tools/CloudWorker/Sources/frwhoop-worker/IntradaySeries.swift` — 5-min HRV/RHR, 1-min resp/steps/calories buckets; `Layout` partitions `[dayStart, dayEnd)` anchored at the claimed LOCAL day's start: "buckets partition the day exactly whatever the timezone offset or DST length" (header comment); `index(ts) = (ts-dayStart)/width`, last bucket short on a 23 h day. Day allocation follows the calendar contract. PASS.
- App-side local HR trend buckets are epoch-aligned 5-min (`floor(ts/300)*300`, `Strand/Data/ShortcutHealthExport.swift:139`) displayed inside a local-calendar window (midnight→now; `TodayView.swift:5180-5186`), which the spec explicitly permits ("Five-minute UTC-aligned windows may remain UTC-aligned").
- Reading side: `IntradayRange.bounds` uses `Calendar.startOfDay` + `date(byAdding:.day:)` (DST-safe; `Strand/Push/IntradaySeries.swift:231-246`), day keys embed `from` so each day has its own cache key.

---

## Q8 — T02: suspended-across-midnight resume ordering

- iOS `scenePhase` `.active` (`StrandiOS/App/StrandiOSApp.swift:348-397`) does: `cloudBecameActive()` (cloud only; `AppModel.swift:281-293` → `syncHostedResults` + 30 s hosted refresh loop), `ble.requestSync(.foreground)`, then async `runDeferredRescoreIfOwed`, Health sync, widget/watch publish. **No date recompute step precedes the first Today render.**
- The Today view re-renders from cached `@State`/`repo` immediately; `selectedDayKey`/`displayDay`/`cachedDisplayDay` only update when `repo.refreshSeq` bumps, which happens after the backfill completes (`refreshAfterCompletedBackfill` → `repo.refresh()`) or after `syncHostedResults` writes ≥1 day (`AppModel.swift:334`). So after a multi-day suspension the first meaningful Today render is the OLD day, then it jumps once the sync lands. T02 (first meaningful resumed Today current before network catch-up) FAILS. Offline resume with no data change does not roll over at all (see Q2).

---

## Other observations on the way

- **Missing-vs-zero:** carried/prior values are explicitly labeled; missing recovery shows "No Data"/carry with date stamp (`TodayView.swift:884-892`, `LiquidTodayView.swift:2094`). Missing is not zero on the Today surfaces reviewed. (Full G2/G7 audit is another workstream.)
- **`syncHostedResults` yesterday key** `localDayKey(now − 86_400)` (`AppModel.swift:316`) can, around a 25 h DST day, request the same calendar day twice and skip the true previous day; the `/days` poll partially covers it.
- **No explicit day/today persisted state** — a fresh launch always shows Today (by design, `TodayView.swift:5069-5073`), and a past-day selection is lost on relaunch.

---


### Refinement: classic TodayView's ~10 s hint timer partially re-renders the label

`TodayView.swift:1435` `@State private var dayNavHint: String?` toggles every ~10 s via an async `.task`
(`TodayView.swift:1583-1593`, "roughly every 10s flash a one-word hint"). Toggling `@State` re-renders the
classic body, which re-evaluates the computed `displayDay` → `repo.today` (`Repository.swift:569-586`), so the
CLASSIC Today's date label/title would follow the 04:00 logical-day rollover within ~10 s even with no data
change. That does not rescue T01:
- the boundary is 04:00 local, not local midnight (spec requires midnight);
- the day-scoped data (HR trend, Rest sparkline, workouts, steps-by-day) is loaded only by `loadAll()`/`loadDayScoped()`
  keyed on `TodayLoadKey(seq: refreshSeq, offset:)` (`TodayView.swift:1758`), so the chart/numbers stay stale until
  `refreshSeq` bumps — a label/data split;
- the DEFAULT Today (Liquid, `RootView.swift:477`; `RootTabView` sets `liquidTodayEnabled = true`) has no hint timer:
  `cachedDisplayDay` is `@State` filled only in `load()` (`LiquidTodayView.swift:136,450`), so Liquid does not roll
  over at all without a `repo.refreshSeq` bump (data-driven or the 30-min backstop).

## Recommended repairs (smallest coherent set, G1 scope)

1. Add a next-boundary timer to the Today surfaces (and a shared day-change signal) that recomputes the logical/calendar day at the boundary independently of data, and re-keys `cachedDisplayDay`; also re-evaluate on `NSSystemTimeZoneDidChange` and `UIApplication.significantTimeChangeNotification` (spec A1). Target ≤1 s.
2. Decide and document the day boundary: either keep the 04:00 logical day as an explicit, user-visible setting with an unambiguous date label, or align Today with local-midnight per spec. Currently it is an undocumented hybrid (#144/#304).
3. Make the app write `profiles.timezone` (IANA id) on enrollment/profile sync so app/backend/SQL share one zone authority; default remains a server-decided UTC.
4. Switch the shared day bucketing to `LocalDayWindows` (already implemented + tested) in `AnalyticsEngine`/`IntelligenceEngine`; stop using fixed-offset + 86_400 day filters. This fixes T05/T06 for both app and worker with one change.
5. Fix `syncHostedResults` yesterday key with Calendar arithmetic (`calendar.date(byAdding:.day,value:-1,...)`).
6. Add a generation/coverage guard to `IntradaySeriesStore.refresh` so a pre-midnight response cannot overwrite the current live window (and honor Task cancellation before assignment).
7. Persist `selectedDayOffset` (or a selected-day key) and add an explicit "Today" action to satisfy T03.
8. On `.active`/resume, recompute the day and refresh the Today caches before rendering (or gate the first render on a fresh day-key resolve).

## NOT VERIFIED / blocked checks (need device/staging/deployed access)

- T01 actual rollover latency on a real iPhone (code shows no timer; a device capture is the only proof of the ≤1 s claim failing/passing).
- T02 first-render staleness timing after a real multi-day suspension with network catch-up in flight.
- T03 selection persistence across TabView tab switches (SwiftUI retention policy is runtime behavior).
- T06 fixtures end-to-end: `America/Los_Angeles` spring/fall, UTC, `Asia/Kolkata`, travel/date-line — the SQL side has fixture tests (e.g. `supabase/functions/tests/legacy_calendar_readback.sql`, `session_result_timezone_review.sql`) and `LocalDayWindowsTests` pins the Swift primitive, but no single app→backend→SQL fixture run was possible here (requires staged Postgres + worker).
- T30: resume UI showing the same day/input revision after repair/replay needs a device capture.
- Deployed `profiles.timezone` values are unknown (would confirm the UTC-default drift in production).
