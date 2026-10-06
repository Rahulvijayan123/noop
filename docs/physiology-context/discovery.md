# Physiology context — discovery

Audit of the repository before implementation (spec §3, §20.1). Every claim cites the file it was read from at the
checked head. Verified by reading code; "documented" means only a doc says it.

## 1. Checked head and concurrent work

| Item | Value |
| --- | --- |
| Remote | `nara` = `https://github.com/Rahulvijayan123/Nara-App.git` (`origin` = the older `noop` repo) |
| `nara/main` | `15c0627e0e785eefe77059e87c5cfa773a16f116` "Bring in the dormant candidate physiology lane without touching how days are scored today" — equal to the spec snapshot |
| Feature branch | `feat/physiology-context-20261005`, worktree `nara-physiology-context`, created from `nara/main`, upstream unset (nothing can be pushed to `main` by accident) |
| Concurrent work | Worktree `nara-physiology-audit` (branch `audit/activity-context-physiology-20261005` at `744355cc`, an ancestor of main) holds ~1.9 k uncommitted lines of activity-classifier tightening (ActivityContext*.swift, ImuFeatureExtractor, Tools/ActivityContext, worker activity lane) and an untracked, unwired `ContextBaselines.swift` (`ContextFamily`, `ContextMetricDefinition`). Last edited 2026-10-05 01:30. **Not touched.** This branch adds no file it edits and uses the nested `PhysiologyContext` namespace so the two can merge without name collisions. |
| Other dirty worktrees | `nara-release` (Key Metrics UI), `nara-activity`, `nara-energy`, `Whoop-Nara` — unrelated, not touched. |

## 2. Source / caller map

| Area | Finding | Evidence |
| --- | --- | --- |
| v1 activity (HART) | `ActivityEpoch` 30-s epochs; never reads HR; wear/sleep default `unknown`; published by the worker activity lane (off by default, `FRWHOOP_ACTIVITY_ENABLED=1`) to `activity_context_epochs`. Read by production scoring only for Energy fusion. | `ActivityContextTypes.swift:88`, `ActivityContextPolicy.swift:76`, `DayScoring.swift:1231`, `Energy/EnergySignals.swift:166` |
| v2 activity decoder | HSMM over HR reserve, HR slope, gravity, steps, IMU. **Reads heart rate**; marks every second with data `onWrist`. Intervals stored on the phone (`activityContextInterval`), day documents on the server (`activity_context_days`, not served). | `ActivityContextModel.swift:355-380`, `ActivityContextTrack.swift:192`, `ActivityContextDays.swift` |
| `ActivityContextJoin.context` | Divides shares by **covered** epoch seconds (uncovered time leaves the denominator); sums overlapping epochs twice; `recentActivity` scans epochs inside the interval. Callers: `Strand/Screens/ActivityContextViews.swift:226,354` (wording only). | `ActivityContextJoin.swift:30-102` |
| `restingEligibility` | Policy ≥ 90 % stationary, ≥ 90 % coverage (both over the window), ≥ 300 s prior stillness, on-wrist and awake epochs. **No production caller** (tests only). With the inputs the system produces it can never return eligible: the worker builds v1 sleep sessions with `stages: []`, so no epoch is ever `awake`. | `ActivityContextJoin.swift:162`, `ActivityLane.swift:1195`, `ActivityContextPolicy.swift:222-230` |
| Baselines | Winsorized EWMA per night (`Baselines.swift`), daytime P10/P50 hourly aggregates (`DaytimeBaselines.swift`); no context matching; the median/MAD/quantile helpers are module-internal and duplicated. | `Baselines.swift:205-631`, `CyclePhaseEngine.swift:297` |
| Circadian | Single cosinor over hourly mean HR (production input is HR only) — a proxy, not endogenous phase. | `CircadianEngine.swift`, `AppModel.swift:2744` |
| Sleep detection | Gravity-stillness spine **confirmed with HR**; V2 staging uses HR, HRV and RSA respiration. Sessions have no nap flag; the snapshot's `sleep[]` entries carry `is_nap`. Day ownership = local day containing the session end. | `SleepStager.swift:927,1318`, `SleepStagerV2.swift:40`, `DayScoring.swift:1269-1291`, `AnalyticsEngine.swift:618` |
| HR recovery | `HeartRateRecovery.calculate` (workout end, +60/+120/+300 s medians, no interpolation); UI only. | `HeartRateRecovery.swift`, `Repository.swift:3531` |
| Activity cost / dose response / illness | Day-level journal-tag associations to next-day Charge/HRV; illness composite is a z-count heuristic. None is causal or clinically validated; none feeds scoring. | `ActivityCostEngine.swift`, `DoseResponseEngine.swift`, `IllnessSignalEngine.swift` |
| Journal | `journal` table keyed `(deviceId, day, question)`: day-granular, no id / time / unit / revision / history; edits overwrite, deletes are physical. **Not uploaded from iOS** (`CloudBatchBuilder.appendTable` returns nil for `.journal`). | `Database.swift:154-163`, `JournalWorkoutAppleCache.swift:88-149`, `CloudBatchBuilder.swift:68-83` |
| Other exposures | Caffeine: timed, mg, local UserDefaults, **pruned after 48 h**. Medication, meals, travel, symptoms: no model (`TabRoute.medication` → ComingSoon). | `CaffeineLog.swift:207`, `TabRoute.swift:84` |
| Placement | Effective-dated `placement_intervals` (server) + local store; uploaded through `/scores/placement`; **the worker never reads it**. Unknown history is never back-filled. | `Placement.swift`, `PlacementStore.swift`, `20261003210000_placement_intervals.sql` |
| Hosted scoring | Scoring lane claims `scoring_jobs_v2`, publishes `scoring_snapshots_v2` (immutable, `result_revision`) then the dense series, attestation and the candidate stage after commit. | `ScoringLane.swift:510-583` |
| Dense series | `server_metric_series` (per user, device-agnostic PK). Support behind each bucket: HRV = that 5-min bucket; resting HR = min of qualifying 5-min means over the trailing 60 min; respiratory rate = trailing 2 min. | `IntradaySeries.swift:262-416` |
| Candidate lane | Gated by `FRWHOOP_INFERENCE_URL` (unset = off); providers default `off`; active is demoted without a signed approval and never republished. Not duplicated or changed here. | `InferenceClient.swift:521`, `CandidateStage.swift`, `20261002090000_physiology_candidate_providers.sql` |
| Raw tables | All typed sample tables are whole-second `ts bigint` with `ingested_at` (availability time exists). RR rows keyed `(user, device, ts, rrMs, seq)`: equal intervals in one second are distinct beats. Conflicting duplicate values are deleted (server keeps neither). | `20260907133000…`, `20260907133100…`, `20260928010000…` |
| Devices | `devices.device_family` / `firmware` exist but are not written for push devices → regime attributes are mostly unknown. | `20260918110000…:20-39` |
| Edge routes | `scores` function: `/`, `/days`, `/series`, `/placement`, stretch feedback; unknown route → 405. | `_shared/serverScores.ts:155-378` |
| App metric pages | HRV and resting HR are the generic `MetricDetailView` (`MetricExplorerView.swift:684`); `ActivityContextLine` shows only for hrv/resp/spo2 (`activityMetrics`, :760). | `MetricExplorerView.swift` |

## 3. Real input availability

| Input | Server availability | Consequence |
| --- | --- | --- |
| HR 1 Hz, RR (whole-second), gravity + dynamic acceleration, steps (5.0/MG), skin temperature raw, band sleep state, wrist on/off events | Present for uploading devices, with `ingested_at` | HR-independent motion evidence (gravity, steps) exists for every strap; causal cutoffs are enforceable |
| v1 HART epochs | Only when the activity lane is enabled and raw IMU sessions were uploaded | Usually absent → strap motion is the main activity source |
| v2 day documents | Same lane; reads HR | Display/audit only |
| Placement | Present when the person set it; history before the first record is unknown | Regime placement is `unknown` before the first record |
| Device family / firmware | Not written for push devices | Regime attributes recorded as unknown; boundaries still detected when they appear |
| Journal / exposures | Not on the server from iOS | New revisioned exposure path required |
| Continuous PPG waveform | Absent | PPG waveform quality is `unsupported` |
| SpO2 | Unverified strap byte, night only | `unverified`, excluded from comparisons |
| Core temperature | Absent | Not claimed; skin temperature is relative only |
| Disease / reference labels | Absent | Specialized features registered as unavailable |

## 4. Existing vs missing capability

| Capability | Existing | Missing (built here) |
| --- | --- | --- |
| Whole-interval activity join | Covered-denominator join; double-counts overlaps | `IntervalAlgebra` (resolution, whole-interval denominator, separate preceding window) |
| Per-metric signal validity | Scattered gates inside HRV/resp/RHR engines | One per-metric assessment with reason codes, regimes, availability matrix |
| Measurement eligibility | Unwired `restingEligibility` | Stable-awake / sleep / activity-response policies with tri-state and dependence |
| Sleep/wake history | Session detection, day ownership | Episodes with main/nap, wake-relative timing, causal completeness, sleep loss and timing change |
| Exertion response | Workout HRR in UI | Bouts from HR-free evidence, response, recovery with censoring, 24/48/72 h history |
| Exposure timing | Day-granular local journal; 48 h caffeine | Revisioned events with occurrence vs availability, sync, invalidation |
| Context-matched baselines | Per-night EWMA | Recent / rolling / frozen / conditioned references from daily context-conditioned values |
| Persistent change | Illness composite z-count | Descriptive episodes with regime boundaries and dependence |
| Functional features | Steps, stand reminder | Bout lengths, pauses, fragmentation, per-wear-hour activity, feature registry |
| Persistence / API / UI | Snapshot, series, activity days | Context jobs, documents, values, bouts, episodes, frozen references, routes, metric-page card |

## 5. Pre-existing defects found (recorded, not changed here)

1. `ActivityContextJoin.context` normalizes by covered seconds and double-counts overlapping epochs (the context layer
   uses `IntervalAlgebra` instead; the old function keeps its UI caller).
2. Activity lane "re-dirty the score" goes through `scoring_dirty_span` → `physiology_work_items` / legacy
   `scoring_work_items` only, never `scoring_jobs_v2`, so v2 snapshots attach new epochs only on the next unrelated
   v2 dirtying (`ARCHITECTURE.md:122` and `BACKEND.md:543` say otherwise).
3. `readPublishedActivityEpochs` keeps a single latest `result_revision` across a local day that spans two UTC job
   days (`DayScoring.swift:1488`).
4. The invalidation window (`d..through+2`) does not cover the full night read window of day D-1.
5. Heartbeat reads scoring stats from the main thread while the scoring thread mutates them (`main.swift:657,891`).
6. Placement: local device id (`my-whoop`) differs from the upload id (`whoop-<serial>`); uploads skip the
   `CloudLocalDataBinding.isOwner` gate; placement tables are not in `deviceScopedTables`.
7. The iOS Events tab and Watchdog view show made-up sample data (`EventsView.swift:148`, `MonitorView.swift:83`).
8. `activity_context_at` is granted to `authenticated` but missing from `CLIENT_CALLABLE_FUNCTIONS`.
9. Caffeine intakes are pruned after 48 h (`CaffeineLog.swift:207`).

Items 2–9 are outside this task's scope; they are listed so they are not mistaken for behaviour of the new layer.

## 6. Integration decisions

1. **Pure core in `StrandAnalytics`** (`PhysiologyContext/`), shared by worker and app; deterministic, clock-free.
2. **Own worker lane** (`context`, off by default) with its own queue, enqueued from scoring completions by
   fingerprint — the pattern of `enqueue_activity_stream_days`. It reads published products and raw streams and never
   writes anything scoring reads, so context failure cannot block scoring, series, BLE or uploads.
3. **Measurements are published products**: series points (with their real trailing supports) and snapshot nightly
   values, plus engine-derived 5-minute HR means. Canonical fields are never rewritten.
4. **HR-independent eligibility evidence**: HART epochs when present, else strap gravity/steps; the v2 decoder is
   display-only for HR-derived metrics.
5. **Day documents + normalized tables**: one immutable document per (device, day, mode, revision), plus current
   daily values, bouts, episodes and insert-only frozen references for queries and history.
6. **Exposure events** get a new revisioned table and route, fed by the existing journal and caffeine flows and a
   small timed-event editor.
7. **UI**: a context card on the HRV and resting-HR pages with a detail sheet and a route to bout/episode history.
