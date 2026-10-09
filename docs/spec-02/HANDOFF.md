# Spec 02 — integration handoff

Branch `feat/spec02-feature-reuse-20261007` (worktree `nara-spec02-features`), cut from `nara/main` `dab2124f3`.
Source spec: `/Volumes/Untitled/Downloads/spec-02-feature-reuse.md`. Contract: [CONTRACT.md](CONTRACT.md).
Per-owner detail (definitions, parameters, citations, every test): [notes/](notes/).

Nothing in this document has been pushed, merged into `main` or deployed.

## 1. What landed

| Area | Output | Producer (single owner) | Document / surface | Owner notes |
| --- | --- | --- | --- | --- |
| Cardiac | HF / LF band power repair (absolute ms², true beat timing) | `HRVFreqDomain.swift` | Stress screen only (on-device, never stored) | [cardiac](notes/cardiac.md) §1 |
| Cardiac | pNN50 on the SD1/SD2 pair set | `SleepAnalyticsPrv.swift` | `daily.sleep_analytics_v1.prv_diagnostics` | [cardiac](notes/cardiac.md) §2 |
| Cardiac | Stage-associated movement | `SleepAnalyticsMovement.swift` | `sleep_analytics_v1.movement.stage_movement` | [cardiac](notes/cardiac.md) §3 |
| Cardiac | Sample entropy, DFA α1 (secondary research stats) | `features/prv_nonlinear.py` | `daily.sleep_features.nights[].prv_nonlinear` | [cardiac](notes/cardiac.md) §4 |
| Cardiac | Awake vs sleep HR (both medians, coverage, % dip) | `PCSleepRhythm.swift` | physiology context `sleep.day_night_heart_rate` | [pc-cardiac](notes/pc-cardiac.md) §1 |
| Cardiac | Sustained high/low pulse episodes, HR rise with movement | `PCPulseEpisodes.swift` | physiology context `pulse_episodes` | [pc-cardiac](notes/pc-cardiac.md) §2 |
| Respiratory | Interval distribution, stable modulation, per-stage interval stats, supported range | `features/respiration.py` | `sleep_features.nights[].respiratory_variability` | [respiratory](notes/respiratory.md) §1 |
| Respiratory | Next-night rebound observations | `features/rebound.py` | `sleep_features.rebound` | [respiratory](notes/respiratory.md) §2 |
| Respiratory | Nightly RR vs prior 7/28-day baselines | `PCReferences.swift` (existing, verified) | physiology context `comparisons` | [respiratory](notes/respiratory.md) §3 |
| Respiratory | Stable-awake respiratory reference | `PCReferences.swift` adapter | `resp_rate.stable_awake_5min` daily values | [respiratory](notes/respiratory.md) §4 |
| Respiratory | Post-exertion respiratory return | `PCExertionBouts.swift` | `bouts[].recovery.respiratory_recovery` | [respiratory](notes/respiratory.md) §5 |
| Temperature | Post-wake slope repair (bins built once) | `SleepAnalyticsThermal.swift` | `sleep_analytics_v1.thermal` | [thermal](notes/thermal.md) §1 |
| Temperature | 30-minute morning response | `SleepAnalyticsMorning.swift` | `sleep_analytics_v1.morning_response` | [thermal](notes/thermal.md) §2 |
| Temperature | `CircadianEngine` relabelled as an observed heart-rate rhythm heuristic | `CircadianEngine.swift` (+ Android twin wording) | Sleep dial, Health card | [thermal](notes/thermal.md) §3 |
| Temperature | Bounded rhythm history (per-day hourly bins) | worker `SleepFeatureRhythmHistory.swift` | snapshot key `rhythmDay`; request `rhythm_history` | [rhythm](notes/rhythm.md) §2 |
| Temperature | Observed skin-temperature rhythm, phase relations, drift | `features/rhythm.py` via `thermal.py` | `sleep_features.nights[main].thermal.observed_skin_temp_rhythm` | [rhythm](notes/rhythm.md) §4 |
| Movement | Rest-activity rhythm (IS, IV, L5, M10, RA) | `features/rhythm.py` | `sleep_features.rest_activity_rhythm` | [rhythm](notes/rhythm.md) §3–4 |
| Readback | Hidden sleep-details sections fixed; every metric above rendered | `Strand/Screens/*` | app | [ui](notes/ui.md) |

Not delivered, by design or by the spec's own deferral: LIDS, kRA/kAR, 24hAlign, any apnea / I:E / tidal-volume /
periodic-breathing / arousal model, tachypnea/bradypnea/pause counts, cardiorespiratory coupling, a breathing score,
AF/PAC/PVC classification, jet-lag forecasts. Section 9 lists the remaining limitations.

## 2. The two correctness repairs

### 2.1 HF power (`HRVFreqDomain`, method `lomb_scargle_psd_ms2_v2`)

Defect: time was rebuilt from cumulative sums of the cleaned intervals (gaps and removed beats vanished) and the
Lomb–Scargle power was divided by the variance, so the "ms²" was dimensionless.

Method now:
- Each interval sits at its END timestamp (checked on 3 h of the owner's WHOOP 5 R-R: the end convention fits).
  Inside a contiguous run, time is the cumulative sum of ALL raw intervals, so a beat removed by cleaning leaves
  its sample missing at its true time.
- A run continues only while one constant offset fits every beat's whole-second timestamp (±0.25 s). A missing
  beat, wall-clock gap, re-stamped delivery or source-channel change starts a new run; a removed stretch longer
  than 3 s also splits. Exact duplicates are removed first. Nothing is bridged.
- Absolute PSD: Lomb–Scargle with Scargle's τ, one-sided density S = 2·Δt̄·P in ms²/Hz, so a sinusoid of
  amplitude A integrates to A²/2 ms².
- 300 s windows, existing band edges and span gates per window (≥ 20 beats; ≥ 60 s for HF, ≥ 250 s for LF;
  ≤ 20 % of beats rejected). Bands are the span-weighted mean over full (≥ 250 s) windows only; with no full
  window, HF alone comes from the single longest window (`short_window_hf_only`).
- The untimestamped `freqDomain(rawRR:)` is gone; `analyze(assumingContiguousRR:)` remains for reference only and
  has no app caller. Canonical RMSSD filtering is unchanged.

Validation (`HRVFreqDomainTests`): known sinusoid 448.61 ms² vs 450 expected, matching SciPy `lombscargle`
(448.612207270) to 1e-6; doubling the amplitude at fixed timestamps gives 4.000000000×; white noise integrates to
its variance (ratio 0.9949); gaps retained; a level shift across a gap does not become LF power; removed beats stay
at their true times; irregular spacing, duplicates, channel changes, invalid intervals.

### 2.2 Post-wake temperature slope (`SleepAnalyticsThermal`)

Defect: minute medians were built only for in-fragment minutes and the post-wake slope `[end, end + 30 min)` was
then fitted from those same minutes, so it was always unavailable (the pre-onset window was clipped the same way).

Method now: `thermalMinuteBins` builds every qualified UTC-minute bin once over
`[min(first fragment start, onset − 60 min, end − 30 min), end + 30 min)` with the unchanged worn, raw-band,
plausibility, off-wrist, ≥ 30-distinct-second and re-wear rules. The nightly summary uses only in-fragment minutes;
the pre-onset slope `[onset − 60, onset)` and post-wake slope `[end, end + 30)` use their own subsets. The same bins
feed the morning response. The worker already passes the full 84 h read (`[midnight − 30 h, midnight + 54 h)`), so no
input widening was needed; a worker test now pins that the streams are never trimmed.

A second defect surfaced while testing: the OLS slope lost precision at unix-second magnitudes (0.6005 instead of
0.6 °C/h). It now uses the mean-centred formula, exact on a straight line.

Validation (`SleepAnalyticsThermalRepairTests`): linear ramps give exactly 0.6 °C/h before onset and −1.2 °C/h after
the window end; no post-wake slope without post-wake data; the nightly median is identical with no, normal and
wildly different post-wake data; thin minutes, the 5-vs-6-minute missing-run limit, re-wear inside and before the
window, duplicates and a DST night.

## 3. Wire contracts

### 3.1 `daily.sleep_analytics_v1` — `nara-sleep-analytics-2`, config `v2`

Versions moved from `-1`/`v1` because the thermal meaning changed. `schema_version` stays 1; the app checks only the
schema, so `-1` documents keep decoding and rendering until their day is re-scored. `SleepAnalyticsConfig.v1` is
kept as a source-compatible alias that now reports `v2`.

Additions (all optional on decode):
- `prv_diagnostics`: `nightly_pnn50_pct`, `pnn50_pair_count`, `nn50_count`, `pnn50_method`
  (`pnn50GapAware_original_adjacency_v1`), per window `pnn50_pct`, `nn50_count`. Pooled 100·ΣNN50/Σpairs; the pair
  count equals the SD1/SD2 valid pairs (tested). The unread `prvPnn50ThresholdMs` config was removed: 50 ms is the
  statistic's definition.
- `movement.stage_movement[]` (labels wake/light/deep/rem/unknown: `eligible_seconds`, `movement_seconds`,
  `movement_percentage`, `movement_bout_starts`, `movement_bouts_per_eligible_hour`, partial below 1800 eligible
  seconds) and `movement.stage_movement_note = stages_may_depend_on_motion`.
- `morning_response` (`morning-response-1`), exactly CONTRACT §4.3: anchor at the effective window end, 60
  one-minute points per signal (`heart_rate` bpm, `skin_temperature` °C, `movement` s/min), separate coverage per
  signal, before/after medians and change with ≥ 20 valid minutes per side, `interpretation =
  response_around_detected_boundary_not_awakening_physiology`. A malformed group decodes as missing.
- `gateFingerprint` adds the morning gates.

### 3.2 `daily.sleep_features` — `nara-sleep-features-1` (unchanged; each new block carries its own version)

- `respiratory_variability` (`resp-variability-2`): `supported_range`, `interval_distribution`
  (`consecutive_intervals_within_usable_runs`), `stable_modulation` (`stable-resp-modulation-1`: 5-minute windows,
  evaluated with ≥ 80 % run coverage and ≥ 20 true intervals, stable when interval CV ≤ 0.25; unknown is never
  stable), per-stage `sd_interval_s`, `rmssd_interval_s`, `median_interval_s`, `iqr_interval_s`, `true_intervals`.
- `prv_nonlinear` (`prv-nonlinear-1`): NeuroKit2 0.2.13, segments of exactly 300 true-adjacent cleaned intervals,
  SampEn (m = 2, r = 0.2·SD), DFA α1 on box sizes 4–16 non-overlapping (Peng 1995 — not NeuroKit's default
  4–11 overlapping), median/IQR, withheld below 3 segments, at most 24 segments evenly spread. Extra keys beyond the
  contract: `segments_available`, `segments_evaluated`, `dfa_overlap`, `max_segments`. A CPU-time guard
  (`time_budget_s` 0.4, this thread's CPU) withholds the block with `compute_budget_exceeded` on a pathological
  input; it is CPU time so a loaded host cannot flip a stored block (lead change, `5bdfe49ab`).
- `rebound` (document level, `sleep-rebound-1`): consecutive-day night pairs against the median of all other
  nights; short = asleep ≥ 60 min below it, fragmented = awake ≥ 30 min above it; median/IQR only with ≥ 3 pairs.
- `nights[main].thermal.observed_skin_temp_rhythm` (`skin-temp-rhythm-1`): weighted 24 h cosinor in elapsed UTC
  (mesor, amplitude, acrophase local and UTC, fit quality), uncertainty = max(delta-method SE, delete-one-day
  jackknife), the spec's gate (≥ 5 qualifying days with ≥ 80 % of the true local-day hours, every 6-hour quadrant),
  `phase_status` (`zero_amplitude`, `unstable_phase`, `mixed_devices`, `insufficient_daytime_temperature`, …),
  temperature IS/IV (`regularity_name` says temperature regularity; IV counts consecutive valid hours across
  midnight), `phase_relations` (HR − temperature, sleep midpoint − temperature, each only with both phases
  independently supported), `phase_drift` (UTC, with time-zone and DST changes listed separately; descriptive
  re-alignment, no forecast). The old thermal IV helper is fixed to include day-boundary pairs.
- `rest_activity_rhythm` (document level, `rest-activity-1`): IS/IV/L5/M10/RA on hourly
  `gravity_movement_seconds_per_minute` of worn minutes; not binarised, no count threshold, gaps stay gaps.
- `SleepMetricStatus` gains `unavailable` (used by `phase_status`).

Request additions the worker now sends: `history.days[].nights` (≤ 8 per day, main night kept, out-of-range values
null) and `history.days[].timezone` from the same snapshot row the history already reads; `rhythm_history`
(`rhythm-history-1`, ≤ 35 days) with per-day `conversion_identity` / `device_family` and a revision digest over
day:revision + conversion identity + rules, echoed in both rhythm blocks.

### 3.3 Physiology-context day document

- `sleep.day_night_heart_rate` (`pc-day-night-hr-1`): awake and sleep medians over exactly the series the existing
  contrast uses (one shared helper, so the contrast value is unchanged), difference, percent dip
  100·(awake − sleep)/awake with `percent_dip_definition`, per-side counts, eligible seconds and coverage.
- `pulse_episodes` (`pc-pulse-1`): qualified inactive seconds only (single plausible HR value, not stuck, still on
  HR-independent motion evidence for ≥ 300 s, outside bouts and 600 s after them); high enters ≥ 100 bpm and exits
  after 60 s below 95, low enters ≤ 40 and exits after 60 s above 43, ≥ 600 usable seconds; censored at run edges,
  never bridged; HR-rise-with-movement events (≥ 10 bpm within 15 s of a movement onset) on the same timeline with
  `cause_not_attributed` and `not_rhythm_classification`. Fixed, configurable, descriptive thresholds (no stable
  second-level personal HR reference exists to anchor them).
- `bouts[].recovery.respiratory_recovery` (`pc-resp-recovery-1`): reference = still estimates in the 15 min before
  the bout (≥ 2 non-overlapping); follow-up starts after 60 s of HR-independent stillness; return = first estimate
  within ±2 br/min confirmed by the next independent one; outcomes `returned`, `returned_by` (upper bound only),
  `not_returned` (right-censored) or `unknown`.
- `resp_rate.stable_awake_5min` daily values via the explicit adapter (`respiratoryStableAwakeValues`); RR is
  withheld during motion by the estimator and never invented.
- `PolicyVersions.pulse`, `PolicyVersions.respiratoryRecovery`; every pulse and respiratory-recovery parameter is in
  `Policy.fingerprint` (a test edits each pulse field and checks the key moves; a Mirror check catches new fields).

## 4. Reason codes

Every new physiology-context code is declared in its owner's `reasonCodes` and mapped in
`MeasurementContextWording.swift` (enforced by `PhysiologyContextWordingCoverageTests`). Codes added beyond
CONTRACT §6's reserved list: `episode_censored_window`, `respiratory_return_unconfirmed`. Sleep-features block
reasons are listed per owner (cardiac §6, respiratory §6, rhythm §6) and mapped by the readback branch
(see §6 below).

## 5. Versioning, recomputation and migration

- **Sleep analytics.** `-1` → `-2` makes the worker publish new documents as days are re-scored. No migration.
- **Physiology context.** The default policy key changes (pulse config, day/night version, respiratory recovery,
  reference config). Each rebuild publishes one new revision even with identical inputs. Nothing re-queues on a
  policy change: the live day and recently scored days pick up the new blocks quickly; older closed days keep their
  old documents until their job runs again or `invalidate_physiology_context_span_v1` is run over them. Decide
  whether to back-fill before deploy. Persistent-change episode IDs include the policy key, so they change on rebuild.
- **Rhythm history.** Existing snapshots have no `rhythmDay`. After deploy the rhythm becomes available once about
  5 qualifying days have been re-published with bins. Optional back-fill: re-score the last 35 days per user.
- **No SQL migration.** All new fields ride existing jsonb (`publish_scoring_snapshot_v2` and the physiology-context
  publish RPC store documents without key filtering; `readHostedSnapshot` and `/context` pass them through). Deno
  route tests pin the pass-through for both documents.
- **Worker redeploy required** for any of this to reach production (the worker and app share StrandAnalytics).

## 6. App readback

Detail: [notes/ui.md](notes/ui.md).

**Section-hiding regression, fixed.** `SleepFeatureSection.load()` returned nothing whenever
`daily.sleep_analytics_v1` existed, which hid regularity, stage physiology, settling and breathing on every night the
worker attached analytics. A `SleepFeatureSectionPlan` / `SleepFeatureDisplayModel` now decides chapters: with
analytics present, only Continuity and Architecture (and the continuity numbers in the headline strip) step aside to
the analytics section; regularity, stage physiology, settling, breathing, temperature rhythm, rest-activity rhythm,
rebound and the secondary PRV statistics still render. Without analytics the section renders exactly as before.

| Document | Where | What renders |
| --- | --- | --- |
| `sleep_analytics_v1` | Sleep → Sleep analytics (`SleepAnalyticsSection.swift`) | pNN50 beside SD1/SD2 ("12.4% · 1,190 of 9,600 adjacent pairs differ by > 50 ms", optical PRV, not ECG); slopes labelled "Hour before sleep onset" / "30 min after estimated window end"; "Around the end of the sleep window" (HR, skin temperature, movement before → after medians, each with its own valid minutes, anchor time, disclaimer, version; curves decoded, not drawn); "Movement by estimated stage" with the may-depend-on-motion note. Rows always show; unavailable reads "Unavailable · reason". |
| `sleep_features` | Sleep → Sleep details (`SleepFeatureCards.swift`, `SleepFeatureDisplayModel.swift`) | Breathing interval SD/RMSSD, median/IQR and percentiles, stable-modulation components (not a score), per-stage rate and variability, supported range, source, version; pulse-interval research statistics (labelled secondary, segments evaluated of available); skin-temperature rhythm (mesor, amplitude ± SE, acrophase ± SE, coverage, temperature-regularity IS/IV, phase relations, drift, clock changes, re-alignment); rest-activity rhythm; rebound. New chapters show "Not available: reason", never placeholder numbers; existing chapters keep their hide-when-unavailable convention. |
| Physiology context | Resting-HR / HR context detail (`MeasurementContextDetailView.swift`), history (`PhysiologyContextHistoryView.swift`) | "Awake and asleep heart rate" (both medians with their own coverage, difference, dip with its definition); "Sustained pulse episodes" (exposure, counts — nil reads "Not evaluated", 0 reads "None found" — episodes with censoring, HR rises with movement, thresholds; says it is not a rhythm classification and attributes no cause); a breathing-return line on history bout rows. |

Robustness: `LenientDayDocument` has a lenient `pulseEpisodes` member; a malformed spec-02 member is dropped and
named in `undecodedMembers` so its carrier still decodes; `HostedDayResult.sleepAnalytics` retries without a
spec-02 group that fails to decode (a broken core group is still rejected); a malformed `morning_response` decodes as
missing. The stable-awake RR envelope lookup now uses `resp_rate.stable_awake_5min` (it looked for a `_2min` name).

Wording: every new physiology-context code is phrased in `MeasurementContextWording.swift`; ~100 sleep-feature
reason phrases in `SleepFeatureWording` (unknown codes read as plain words); 161 new `Localizable.xcstrings` keys in
en + de, es, fr, it, pl, pt-PT, ru, zh-Hans, zh-Hant (including the Stress screen's 11 new frequency strings), plus
the 16 `CircadianEngine` relabel keys. Card labels inside the two sleep sections stay English, like the rest of
those sections.

Producer output decoded but not displayed (none is a headline metric): `DayNightHeartRate.method/units/
minSamplesPerSide/awakeWindow`; pulse `coverage/evidence_source/window`; rhythm `config`, `fit_hours`,
`iv_valid_pairs`, the delta/jackknife SE split, daily-phase `amplitude_c/hours`; rest-activity `notes`, `hours_used`,
`binarized`, `deferred`; stable-modulation `windows_*`, `night_minutes`; rebound `pair_days`, `pairs_evaluated`,
`days_evaluated`; morning-response per-minute curves.

**Producer-to-app round trips** (real producers, not hand-written values):
- `Spec02SleepAnalyticsProducerRoundTripTests`: `SleepAnalyticsV1.compute(.v2)` on an 8 h native night → the worker's
  encoder → `daily.sleep_analytics_v1` → JSON bytes → `HostedDayResult` → display model; the decoded document equals
  the producer's and every displayed pNN50 / slope / morning / stage-movement value equals it.
- `Spec02PhysiologyContextProducerRoundTripTests`: `Engine.buildDay` → `StoredDocument.split` with
  `PhysiologyContext.encoder()` → context envelope → `PhysiologyContextRepository.parseDay` / `parseHistory` (lenient
  app path) → detail rows; day/night, pulse episodes and a `returned` respiratory recovery match the engine.
- `Spec02SleepFeaturesProducerRoundTripTests`: `StrandTests/Resources/spec02_sleep_features_producer.json` is produced
  by the real Python `compute()` (`tests/test_spec02_app_fixture.py` recomputes it and asserts equality; every spec-02
  block is `available` in it) and decoded beside an analytics document; every displayed value matches an
  independent JSON parse.
- Deno `spec02_readback_route_test.ts`: the scores route, `/context` and `/context/history` pass every new field
  through verbatim; an older snapshot is unchanged.

## 7. Runtime and performance

| Path | Measurement | Notes |
| --- | --- | --- |
| Sleep-features route, whole document (integrated branch, load average ~27) | committed full-night request 0.143 s CPU; full-availability request (every spec-02 block computes, 30-day rhythm history, history nights) 0.216 s CPU — **+73 ms** against the 3 s budget | median of 5 after warm-up, `time.process_time`; the golden CPU test (`< 0.75 s`) passes |
| `prv_nonlinear` | SampEn 0.33 ms + DFA 1.7 ms per segment (minimum CPU); segmentation of a 26 400-beat night 113 ms; ≤ 24 segments | CPU guard 0.4 s |
| Rhythm blocks (35 days, 840 bins, 161 KB request) | parse 2.1 ms, temperature block 6.5 ms, rest-activity 2.4 ms (~11 ms total); response +12 KB | |
| Rhythm history read (prod, read-only, owner) | 1.6 ms warm, 221 ms first in session; one index probe per day | raw re-aggregation was 13.7 s cold per day and a 14-day form hit the 30 s timeout — rejected |
| Worker `buildDay` | single linear pass per stream over rows already loaded; 5.1× one plain loop in a debug build | release cost not measured |
| `SleepAnalyticsV1.compute` (24 h of 1 Hz, 8 h night, debug, loaded host) | full compute 1479 ms → 355–719 ms; thermal 379 → 5–36 ms; morning ~4 ms | the thermal group now reads its ~5.5 h window instead of the whole 84 h read |
| Snapshot size | `morning_response` ≈ 11 KB, `rhythmDay` ≈ 3 KB on a 100–150 KB snapshot | |

Scoring lock: the sleep-features enrichment, and so the rhythm history read, runs inside the scoring transaction
that holds the job-row lock and, with the input gate on, the per-user `scoring-inputs-v2` lock. The history read was
made cheap (one indexed read of already-aggregated per-day bins, under a savepoint so a failure drops only the
history) rather than moved, because moving it needs `ScoringLane.swift` (Spec 01). The new Swift sleep-analytics
work makes the scoring pass shorter, not longer.

## 8. Spec 01 and Spec 03 boundaries

- **Spec 01** edits the transport/busy section of `SleepFeatureEnrichment.swift` (busy document, `transportBudgetMS`).
  This branch edits only request assembly (`buildRequest`, history nights, `rhythmHistory`) and the history loader;
  expect a textual merge, no semantic conflict. A Spec 01 busy document will carry no `rebound`,
  `rest_activity_rhythm` or `prv_nonlinear` keys — the app treats a missing block as absent.
- **Spec 01 dependency (optional):** a post-commit hook in `ScoringLane` would take the history read out of the
  locked section entirely. Not needed at 1.6 ms warm.
- **Spec 01 dependency:** the sleep-features route's 3 s budget and admission (`server.py`) are unchanged here;
  this branch adds ~11 ms of rhythm work and a bounded, CPU-guarded nonlinear block.
- **Spec 03** touches `wav2sleep` contracts only; no overlap with these files.

## 9. Test evidence and remaining limitations

Integrated branch, final runs (logs under `_build-scratch/spec02/logs/`):

| Suite | Result | Log |
| --- | --- | --- |
| StrandAnalytics `swift test --skip LongitudinalBaselineTests` | 3594 run, 7 skipped, **0 failures** (foundation: 3494) | `lead-sa-test-150417.log` |
| CloudWorker `swift test` | 672 run, 63 skipped (database-backed), **0 failures** | `lead-wk-test-155314.log` |
| Python sidecar `pytest tests` | **543 passed**, 42 skipped, 0 failed (foundation: 477 passed, 1 load-dependent failure) | terminal |
| macOS `StrandTests` (full) | 3255 run, 13 skipped, 3 failing tests (11 assertions) — exactly the three that fail on `main` (below); every spec-02 test passes | `lead-mac-test-155124.log` |
| macOS spec-02 classes (readback, producer round trips, wording coverage) | 28 run, 0 failures | `lead-mac-test-155100.log` |
| iOS simulator build (`NOOPiOS`) | BUILD SUCCEEDED | `lead-ios-155154.log` |
| macOS app build | succeeded (as part of the test run) | `lead-mac-test-155124.log` |
| Deno `sleep_analytics_route_test.ts` + `physiology_context_routes_test.ts` | 23 passed, 0 failed | terminal |
| Deno `spec02_readback_route_test.ts` | 5 passed (readback branch) | [notes/ui.md](notes/ui.md) |
| Android unit tests | **not run** (no Android toolchain) | — |

Per-feature acceptance fixtures (spec "Acceptance" section) live in: `HRVFreqDomainTests` (sinusoid, 4× power, gaps),
`SleepAnalyticsPrv*`/pNN50 tests and `test_features_prv_nonlinear.py` (adjacency, unavailable, NeuroKit and textbook
references), `test_features_*` respiratory tests (true intervals, gaps never create long breaths or stable time,
baselines exclude the target night), `SleepAnalyticsThermalRepairTests` (both slopes, median unchanged by post-wake
data), `test_features_rhythm.py` (midnight/DST, flat or thin data withheld, a time-zone change is not drift), and the
producer-to-app round trips in §6.

Known limitations:
- `LongitudinalBaselineTests` needs `Packages/StrandAnalytics/Baseline/fixtures/*.csv`, which were never in git and
  are not on this machine (the whole `Baseline/` directory, including its plan documents, lived in another person's
  checkout). Without them the class crashes the test process (`try!` on a missing fixture), so suite runs skip it.
  No replacement data was invented.
- `test_sleep_providers_wiring.py::test_stage_inference_renders_three_class_stages_over_the_real_path` returned
  `withheld` once on the foundation baseline run (load average ~600) and passed on the integrated run: it is
  load-sensitive and outside Spec 02.
- Three macOS `StrandTests` fail on `main` itself and are untouched here: `ActivityCalibrationSessionTests` ×2 and
  `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets`.
- Under heavy load, or with another `NOOP Staging` test host open, `xcodebuild test` can fail with "the test runner
  hung before establishing connection" before any test runs; rerun with no competing macOS test host.
- Android: the HF repair and the circadian wording are mirrored but not built or run (no Android toolchain). The
  Android Health card's "Heart-rate rhythm" overline is a hard-coded English literal and engine notes are shown in
  English (both as before).
- New translations (Swift xcstrings and Android strings) were written by the agents; a native-speaker review is
  advisable.
- The morning response has its own gravity-acceptance helper using the movement group's rules over a window that
  crosses the fragment end; it was deliberately not merged with the in-fragment movement pass.
- 15 CloudWorker database-backed tests (and 63 in the full worker suite) skip without a local database.
- Pre-midnight RR estimates are not in the physiology-context inputs, so bouts just after midnight get
  `respiratory_reference_unavailable`.
- WHOOP 4.0 temperature uses the provisional anchor; the history uses one anchor across all days, so phase and
  relative amplitude are valid, absolute level is not.
