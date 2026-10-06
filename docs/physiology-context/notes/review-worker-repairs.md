# Worker repairs from the independent reviews

Branch `pc/fix-worker`, from `204ea2c3` (lead repairs: `PlacementInput.scope`, retrospective engines use every
frozen reference passed in). Findings: [review-contract.md](review-contract.md) (RC-03, RC-13, RC-17, RC-18) and
[review-statistics.md](review-statistics.md) (R-F2, P5). Files: `Tools/CloudWorker/Sources/frwhoop-worker/Context*.swift`,
`Tools/CloudWorker/Tests/frwhoop-workerTests/ContextLane*Tests.swift`, [worker.md](worker.md) (§4, §5, §8, §12).
No package, migration or app change.

## Summary

| Finding | Fix | Test | Status |
| --- | --- | --- | --- |
| RC-03 (H) nightly supports | Pooled nightly fields (HRV, SDNN, resp, skin, SpO2) take the **main-sleep group** (the scorer's own main-night rule over the day's sessions) instead of the hull of every session; resting HR keeps its primary session. The source key records when the canonical aggregate also pooled sessions outside the support, and the split gap a support spans. | `ContextLaneReviewRepairTests.testRC03_*` (4): a nap day through `assemble` + `Engine.buildDay` is `sleep_measurement` eligible and has `hrv_rmssd.sleep_night`; split night; nap flags; the scorer's zone offset. `ContextLaneTests.testSnapshotParsingAndNightlyMeasurements` updated. | Repaired for nap days. Split nights with a gap ≥ 10 % of the hull remain (engine-side, below). |
| R-F2 (high) history length | `ContextInputs.historyDays(for: policy)` = `windowDays` + max(`rollingWindowDays`, `autocorrelationGuardDays` + `autocorrelationWindowDays`) = 90 + 70 = **160** (D−160 … D−1); the lane passes its own policy. Same indexed query, bounded by the range. | `testRF2_historyCoversTheChangeDetectorsFullBurnIn`; DB `testRF2_historyLoadReadsTheFullBurnInWindowBoundedAndIndexed` (6,400 rows read of 6,840 stored, plan has no sequential scan, load time measured). | Repaired. Load time below. |
| RC-13 (M) device attributes on rebuilt days | `ContextInputs.deviceRegime`: firmware **nil** (unknown) for every day; device family nil as well (a mutable label); source kind kept (immutable). | `testRC13_aRebuiltDayCarriesNoCurrentFirmwareOrFamilyLabel` (two current device rows → identical regimes, fingerprint and regime keys); `testAssembledInputCarriesIdentityRegimeAndRevisions` updated. | Repaired (latent until firmware is written). |
| RC-17 (L) placement scope | `parsePlacement` sets `scope: "device"` when `device_id` is set, `"account"` when null (the query's `user_level`); scope is the last sort key. | `testRC17_placementRecordsCarryTheirScope`; DB `testPlacementRowsArriveWithTheirScope`. | Passed through; the device-over-account resolution is the engine's (signal repair). |
| Frozen references per mode | Unchanged SQL, now explicit (`historyCutoffParameter`): retrospective reads every reference registered for the device, causal only those registered by the cutoff. | `testFrozenReferencesRetrospectiveReadsEveryRegisteredOneCausalOnlyByTheCutoff`; DB `testRetrospectiveJobsReadEveryRegisteredFrozenReferenceCausalOnlyByTheCutoff` (2 / 1 / 0 by mode and cutoff, another device's never). | Verified. |
| R1 (lead addendum, HIGH) optional reads swallowed every error | `ContextInputs.optionalRead`: only SQLSTATE 42P01 / 42883 / 42703 (the object is not installed) makes an optional input `*_unavailable`; every other error (lock / statement timeout, serialization, lost connection, privilege) is rethrown, so the job is settled by `fail_physiology_context_v1` and retried with backoff. | `testR1_onlyAMissingSchemaObjectMakesAnOptionalInputUnavailable` (classification and rethrow per SQLSTATE); DB `testR1_aTransientOptionalReadFailureFailsTheJobAndTheRetryPublishes` (a lock on `activity_context_epochs` + `lock_timeout` 2 s → job failed, no revision, failures = 1; after the lock, the retry publishes with no `*_unavailable`). | Repaired. |
| V10 (found by the DB suite) input revisions counted rows stored after the cutoff | `assemble` computes the `activity_epochs`, `activity_days`, `placement` and `exposures` input revisions over the causal view, not over every stored row. Latent before 204ea2c3 (the fingerprint ignored `inputRevisions`, so the replay was `unchanged` while its revisions already differed); the lead's RC-04 fingerprint made `testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff` publish a new revision for a late exposure. | `testRowsAppendedAfterTheCutoffDoNotChangeAReplay` now also appends a late exposure, placement, HART revision and decoder run (equal input revisions, fingerprint and bytes); DB V10 test passes again. | Repaired. |
| RC-18 / P5 (L) replay limits | Documented exactly (below); not reconstructable from stored columns. Telemetry `causal_history_after_cutoff` counts history rows a causal job could not read. | DB R-F2 test (a replay before publication reads none and counts 6,400). | Documented; storage fix belongs to backend-db. |

## RC-03: which sessions each nightly support covers

The snapshot's `sleep` array is exactly the scorer's `matched` list (sessions whose end falls on the local day,
`AnalyticsEngine.analyzeDay`). The canonical day aggregates are pooled over that whole list, naps included (the
scorer keeps the physiology aggregates day-wide on purpose, #525 note in `AnalyticsEngine`):

| Field | Canonical aggregate | Support now | Before |
| --- | --- | --- | --- |
| `resting_hr_bpm` | gated lowest 5-min bin of the primary session (longest motion-backed session) | primary session (longest, first on ties) | same |
| `hrv_rmssd_ms` | in-bed-weighted mean of per-session RMSSD, all sessions (main group only when the over-count gate refused a main fragment) | main-sleep group | hull of all sessions |
| `hrv_sdnn_ms` | SDNN index of in-session R-R, all sessions | main-sleep group | hull |
| `resp_rate_bpm` | median of per-session RSA estimates (or vendor rate), all sessions | main-sleep group | hull |
| `skin_temp_c` | worn-gated mean, all sessions | main-sleep group | hull |
| `spo2_candidate_pct` | in-band mean inside any session | main-sleep group | hull |

Main-sleep group = `SleepStageTotals.mainNightGroupIndices` over the day's sessions at the zone offset of the
snapshot day's start (snapshot `timezone`, else the job's) with no habitual midsleep — the call the scorer makes, so
the support is the night the scorer's sleep totals describe; `is_nap: true` sessions are never in it unless all
are. Support = `[first fragment start, last fragment end)`.

The value stays the canonical one (the context layer does not recompute scores). Where the aggregate's definition
reaches outside the support the measurement says so in `source.key`, which the envelope carries into the document:
`daily.<field>#aggregate_pools_sessions_outside_support=<n>`, `…support_spans_split_sleep_gap_s=<s>`,
`…main_sleep_from_nap_flagged_sessions`, and for resting HR `…primary_session_outside_main_sleep`. A one-session day
keeps the plain key. Counts are by definition, not contribution: the snapshot does not say whether a nap produced a
value (no beats, the over-count gate, the wear gate) or which sessions were HR-only.

**Remaining (engine-side).** `MeasurementInput.support` is one interval. For a split main night the hull includes the
inter-fragment gap, which no fragment measured. Checked with a scratch run (not committed): gaps of 1,200 s and
2,400 s (4 % and 8 % of the hull) stay `asleep` / eligible with a nightly value; a 3,000 s gap (10.4 %) is
`unknown (sleep_evidence_unknown)` and the night has no `hrv_rmssd.sleep_night` value. Fragmented nights with long
awakenings therefore still drop out. Repair options for the lead: multi-interval support (`supportParts`) used by the
join and `SleepRhythm.sleepWear`, or let System C treat a split group's own gap as part of the main night.

## R-F2: history length and load time

The first scored episode day is D−90; its rolling reference needs D−118 … D−91 and its φ̂ the consecutive pairs in
D−159 … D−104 (`autocorrelationWindowDays` 56 before the 14-day guard). 160 days covers both. The query is unchanged:
`physiology_context_daily_values` filtered by `(user_id, device_id, mode)` and a `day` range, served by the primary
key `(user_id, device_id, mode, day, series_key, regime_key)`; causal jobs add the per-row `EXISTS` on
`physiology_context_days`' primary key. Measured on the scratch database (`testRF2_…`, 160 days × 40 series = 6,400 rows read of 6,840 stored per
mode, median of 5 loads; debug build):

| Mode | History query | Plan (sequential scans priced out) | Whole `ContextInputs.load` (owner with no raw streams) |
| --- | --- | --- | --- |
| retrospective | 13 ms | Index Scan on `physiology_context_daily_values_pkey` | 83 ms |
| causal | 12 ms | Index Scan on `physiology_context_daily_values_pkey` + the per-row `EXISTS` on `physiology_context_days_pkey` | 91 ms |

An earlier run while the machine sat at a load average above 100 gave 26 / 363 ms for the query (causal as a
bitmap heap scan over the same index) and 3.6 / 2.4 s for the whole load; the history read stays a small share of a
job's load either way (a full stored day's load was 677 ms, worker.md §10).

The in-memory profile (`ContextLaneProfileTests`) now builds with 160 days of history; it was not re-run in release
for this change.

## RC-13: device attributes

The lane reads the current `devices` row while it rebuilds days up to 120 days old (placement corrections, the
28-day `history_changed` cascade, routine retrospective runs). Every device upsert in the migrations does
`firmware = coalesce(excluded.firmware, devices.firmware)` and `device_family = coalesce(excluded.device_family,
devices.device_family)`, and no history of either exists. So both are now nil on every day's regime (firmware
"unknown"; until an effective-dated firmware source exists, firmware cannot be a regime boundary at all). The family
is also nil: it is filled late or relabelled (`WHOOP`, `WHOOP 5.0 / MG`, `WHOOP 5B…` name one strap), and the device
id is already the history scope, so nothing is pooled across devices. `source_kind` stays (and the vendor derived
from it): it is part of the row's conflict key `(user_id, source_kind, external_device_id)` and nothing updates it.
The skin-temperature conversion still uses the current family, exactly as `DayScorer` does.

**Deploy note.** Regime keys of every series change once (family/firmware fields become "unknown"). History
published before this change carries the old keys, which the change detector reads as a regime boundary. The lane is
off by default; enable it on a database without stored context, or invalidate the stored range
(`invalidate_physiology_context_span_v1`, 120 days) when deploying.

## RC-18 and P5: what a causal replay cannot reproduce

A causal replay at cutoff C of a decision first taken live at C reads only rows available by C. Two storage
behaviours make it lose (never leak) information the live decision had.

**Placement corrections edit rows in place (RC-18).** `set_placement_interval` (the only write path; the edge route
never passes `p_effective_end`) does one of:

1. Close: every same-scope row strictly containing the new start T gets `effective_end = T`; its `recorded_at` and
   `revision` do not change. A new row is inserted at T (`recorded_at` = now).
2. Same-start replace: a row starting exactly at T has its placement, source, revision and `recorded_at` overwritten.
3. Insert: a new row at T, its end capped at the next same-scope row's start (both known at insert).

`Engine.causalView` keeps a placement record when `recordedAt ≤ C`. So, for a correction made after C:
case 1 leaves the closed row visible with its new end T and hides the row that closed it, so the replay shows
`unknown` placement over [T, C) where the live decision saw the old row's placement; case 2 hides the replaced row
entirely (its old placement is gone from storage), so the replay shows `unknown` over its whole span before C. Both
change the placement-keyed regimes of measurements in those spans, so the replayed document differs from the live
one. The worker cannot reconstruct the live state: a same-scope row starting at T with `recorded_at > C` is either the
row that closed the older one (case 1) or a row that existed at C and was replaced later (case 2), and the stored
columns cannot tell them apart, so a reconstruction could assert a placement the live decision never saw.
Fix (backend-db): record when an end was set (`end_recorded_at`) or make corrections insert-only (supersede rows with
`superseded_at` instead of editing them), and keep the replaced values of case 2.

**History rows are replaced on publish (P5).** `publish_physiology_context_v1` replaces daily values and bouts per
(user, device, mode, day); superseded day rows are deleted 24 h after they are superseded; frozen references are
insert-only and unaffected. The causal history filter keys on the publication of the CURRENT row (`published_at ≤ C`
through `context_revision`), so after a later republish of history day H (an operator replay, a causal run after
midnight, an invalidation) a replay at C reads no value for H where the live decision read the earlier one. The
earlier version is not recoverable. Telemetry `causal_history_after_cutoff` counts, per causal job, the history rows
in the read ranges whose current publication is after C (a row first published after C is counted too; the two cannot
be told apart), never in the document. Fix (backend-db): keep superseded daily values and bouts with their
publication time and select the latest version published at or before C.

## Test runs

Debug build, `Tools/CloudWorker`, scratch database from `supabase/tests/e2e/pipeline_db.sh` (every migration):

| Command | Result |
| --- | --- |
| `swift build` | clean |
| `swift test --filter ContextLane` (no DB URL) | 0 failures; DB and profile tests skip |
| Context suites in the final DB run | `ContextLaneTests` 30, `ContextLaneReviewRepairTests` 9, `ContextLaneFixtureTests` 1, `ContextLaneDatabaseTests` 13 (1 opt-in skipped), `ContextLaneProfileTests` 2 (opt-in, skipped): 0 failures |
| `FRWHOOP_TEST_DB_URL=… swift test` (whole worker suite) | **468 tests, 4 skipped** (the 3 opt-in profiles and the pre-existing `PushBatchTests.testEmbeddedFixturesMatchOnDiskCorpus`), **0 failures**, 218 s |

The first whole-suite run failed one test, `testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff` (the V10
input-revision defect above); repaired and re-run. The R1 DB test was also run against the old behaviour (every
error swallowed): it fails 8 assertions there (published with `activity_epochs_unavailable`, job done), so it pins
the repair. The scratch database ran on ports 55511–55513, not 55501–55503: after the colima VM restarted, a stale
lima ssh forwarder kept 55501/55503 bound to the dead VM. Not re-run: the release-build profiles
(`ContextLaneProfileTests`, opt-in).

## For the lead

1. `contracts.md` §7.2 still says history "daily values D-90..D-1" and "nightly snapshot values with the sleep session
   span": now D−160 … D−1 (`historyDays(for: policy)`) and the main-sleep group (resting HR: the primary session).
2. Split nights with an inter-fragment gap ≥ 10 % of the hull still have no `*.sleep_night` value: needs
   multi-interval support or a System C rule for a split group's own gap (RC-03, above).
3. Regime keys change once with RC-13 (family / firmware unknown): enable on an empty context store or invalidate the
   stored range when deploying.
4. RC-18 / P5 need storage changes (backend-db): `end_recorded_at` or insert-only placement corrections, and
   versioned daily values / bouts.
