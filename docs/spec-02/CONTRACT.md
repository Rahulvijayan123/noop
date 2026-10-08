# Spec 02: feature reuse, shared contract

Branch `feat/spec02-feature-reuse-20261007`, cut from `nara/main` `dab2124f3`. The spec's audited baseline is
`1a07ad22b`; the only commits between them (`2aa232963`, `dab2124f3`) touch metric insights and none of the files
below. Every claim the spec makes about this code was checked against `dab2124f3` before this contract was written:

| Spec claim | Where it holds at `dab2124f3` |
| --- | --- |
| HF power discards timestamps and is variance-normalized | `HRVFreqDomain.freqDomain(rawRR:)` cumsums cleaned intervals; `lombScarglePower` divides by `2·variance` |
| Thermal slopes read night-only minute medians | `SleepAnalyticsThermal.thermalGroup` keeps only in-fragment minutes, then fits `[end, end+30 min)` from them, so the post-wake slope is always unavailable |
| Python withholds the multi-day rhythm | `features/thermal.py` `_rhythm_withheld_block()` with `multi_day_history_not_requested` |
| Existing thermal IV drops day-boundary pairs | `features/thermal.py` `intradaily_variance` sums `h → h+1` inside each day only |
| `CircadianEngine` runs on hourly mean HR | `AppModel.swift:2983` pools `bpm` per hour; `tempMinHour = acrophase − 12 h` |
| Stable-awake references exclude respiration | `PCReferences.ReferenceConfig.stableAwakeMetrics = [.hrvRmssd, .hrvSdnn, .heartRate]` |
| Breath detector band 6–24 br/min, display 8–25 | `RespBreathTrack.swift` (2.5 s minimum peak spacing), `SleepStager.respPlausibleRangeBpm = 8…25` |
| Awake-vs-sleep HR difference exists | `PCSleepRhythm.dayNightContrast` publishes only the difference (no medians, no coverage) |
| Sleep features hide when sleep analytics exists | `SleepFeatureSection.load()` returns nil whenever `daily.sleep_analytics_v1` is present, so breathing, physiology, settling and regularity are never shown on those nights |

## 1. Scope boundaries

This branch owns feature calculations, feature documents, history loading and their app consumers. Spec 01 owns
shared transport, provider infrastructure, scheduling, manifests and model authority. Nothing here edits:

- `Tools/InferenceWorker/src/frwhoop_inference/server.py` (route budgets, bounded workers, admission: Spec 01 §5),
- `deploy/`, `models/manifest.json`, `artifacts.py`, `materialize_model_root.py` (Spec 01 §1),
- `CandidateStage.swift`, `ScoringLane.swift`, activity-authority files (Spec 01 §2),
- the NPB1 PPG transport and `sensor_biomarkers/` providers (Spec 01 §3–4).

Infrastructure dependencies are recorded in `docs/spec-02/HANDOFF.md` instead of being fixed twice.

## 2. One owner per metric

| Output | Single producer | Document |
| --- | --- | --- |
| SD1, SD2, pNN50 (night) | `SleepAnalyticsPrv.swift` | `daily.sleep_analytics_v1.prv_diagnostics` |
| Sample entropy, DFA α1 (night, secondary) | `features/prv_nonlinear.py` | `daily.sleep_features.nights[].prv_nonlinear` |
| HF/LF band power (today's R-R lens) | `HRVFreqDomain.swift` | in-app only (Stress screen) |
| Nightly thermal summary, pre-onset and 30-min post-wake slopes | `SleepAnalyticsThermal.swift` | `sleep_analytics_v1.thermal` |
| Morning HR / temperature / movement curves | `SleepAnalyticsMorning.swift` | `sleep_analytics_v1.morning_response` |
| Stage-associated movement | `SleepAnalyticsMovement.swift` | `sleep_analytics_v1.movement.stage_movement` |
| Python 3-minute settling / thermal blocks | `features/settling.py`, `features/thermal.py` (unchanged definitions) | `sleep_features.nights[].settling/thermal` |
| Observed skin-temperature rhythm, phase relations, drift | `features/thermal.py` (+ `features/rhythm.py`) | `sleep_features.nights[main].thermal.observed_skin_temp_rhythm` |
| Rest-activity rhythm (IS/IV/L5/M10/RA) | `features/rhythm.py` | `sleep_features.rest_activity_rhythm` |
| Respiratory distribution, stable modulation, supported range | `features/respiration.py` | `sleep_features.nights[].respiratory_variability` |
| Next-night rebound observations | `features/rebound.py` | `sleep_features.rebound` |
| Nightly RR vs prior 7/28-day references | `PCReferences.swift` (existing `resp_rate.sleep_night`) | physiology context `comparisons` |
| Stable-awake respiratory rate | `PCReferences.swift` / `PCEligibility.swift` | `resp_rate.stable_awake_5min` daily values |
| Post-exertion respiratory return | `PCExertionBouts.swift` | `bouts[].recovery.respiratory_recovery` |
| Awake vs sleep HR (both medians, coverage, % dip) | `PCSleepRhythm.swift` | `sleep.day_night_heart_rate` |
| Sustained high/low pulse episodes, HR acceleration with movement | `PCPulseEpisodes.swift` | `pulse_episodes` |
| HRR 1/2/5 min (workouts), free-living post-effort decline | `HeartRateRecovery.swift`, `PCExertionBouts.swift` (unchanged) | workout detail, `bouts[].recovery` |
| Personal multisignal anomaly | `IllnessSignalEngine` (unchanged) | existing heads-up surface |

Python never recomputes SD1/SD2; the Swift document never computes entropy or DFA. The app reads continuity,
architecture and nightly thermal from `sleep_analytics_v1` when it exists, and only regularity, stage physiology,
settling, breathing, rhythm, rebound and the secondary PRV statistics from `sleep_features`.

## 3. Common rules

- Missing data is `null` with a machine-readable reason, never zero. A genuine zero needs qualifying exposure.
- Every new metric carries unit, status and reason; every new block carries its method/definition version, the
  actual observation window and its valid exposure (seconds, minutes, pairs, windows, days, as applicable).
- New fields are optional/additive. Old documents keep decoding; old app builds ignore the new keys.
- Swift `Codable` additions to existing synthesized types are `var … ? = nil` so the memberwise initializers of
  existing call sites keep compiling and missing keys decode as nil.
- Physiology-context JSON goes through `PhysiologyContext.encoder()` (snake_case, no dictionaries; keyed data is
  `[Diagnostic]` or named entries).
- New Python thresholds live in a frozen dataclass inside the owning module and are reported inside that block
  (`config`, `method_version`). `features/config.py` `CONFIG` is not changed, so `dependencies.config` stays stable.
- Optical intervals are pulse-rate variability (`source: "prv_optical"`), never ECG-equivalent HRV.
- No clinical labels: no tachycardia/bradycardia/AF/apnea/autonomic-disease wording, no causal claims, no
  composite 0–100 breathing score, no jet-lag forecast.

## 4. `daily.sleep_analytics_v1` (Swift, `SleepAnalyticsV1.swift` types are root-owned)

Version: `algorithm_version` stays `nara-sleep-analytics-1` and `config_version` `v1` until the first spec-02 change that alters a meaning lands (the thermal post-wake slope, §4.2); that change bumps both to `-2` / `v2`. `schema_version` stays 1.

### 4.1 PRV diagnostics: pNN50 (owner: cardiac)

`prv_diagnostics` gains:

| Key | Type | Definition |
| --- | --- | --- |
| `nightly_pnn50_pct` | metric, unit `%` | 100 × Σ NN50 / Σ pairs over the night's eligible windows (pooled proportion, never a mean of window percentages) |
| `pnn50_pair_count` | count | denominator: true adjacent cleaned pairs inside eligible windows |
| `nn50_count` | count | numerator: of those pairs, `|ΔNN| > 50 ms` |
| `pnn50_method` | string | `pnn50GapAware_original_adjacency_v1` |
| `windows[].pnn50_pct`, `windows[].nn50_count` | number / int | the same statistic per eligible window |

The pair set is exactly the SD1/SD2 pair set: `HRVAnalyzer.pnn50GapAware(nn, contiguous)` called with a contiguity
mask built from `SleepAnalyticsPrv`'s original timestamp / seq / ord / source adjacency (a pair counts only when the
two cleaned beats were adjacent in the original series and their wall-clock spacing matches the interval). Window
gates are the existing PRV gates. No window → `null` with the same reason SD1 carries.

### 4.2 Thermal repair (owner: temperature)

Build every qualified UTC-minute bin once over `[first observed onset − 60 min, last fragment end + 30 min)`, with
the existing worn, plausibility, distinct-second and re-wear equilibration rules. Night summaries use the
in-fragment subset; the pre-onset slope uses `[onset − 60 min, onset)`; the post-wake slope uses
`[window end, window end + 30 min)`. Wire keys are unchanged. Python's three-minute tail
(`SleepFeatureEnrichment.tailSeconds`) and its `thermal`/`settling` blocks keep their own definitions.

### 4.3 `morning_response` group (owner: temperature)

New optional group `morning_response` (`SleepAnalyticsMorningResponseGroup`), anchored at the effective window end
(the same boundary the post-wake slope uses), over `[anchor − 30 min, anchor + 30 min)` at 1-minute resolution:

| Key | Meaning |
| --- | --- |
| `quality` | standard quality block |
| `anchor_kind` | `effective_window_end` |
| `anchor_ts`, `anchor_at` | unix seconds / ISO-8601 |
| `window_before_seconds`, `window_after_seconds` | 1800, 1800 |
| `heart_rate`, `skin_temperature`, `movement` | `SleepAnalyticsSignalWindow` each, with SEPARATE coverage |
| `algorithm_version` | `morning-response-1` |
| `interpretation` | `response_around_detected_boundary_not_awakening_physiology` |

`SleepAnalyticsSignalWindow`: `signal`, `unit` (`bpm`, `°C`, `s/min`), `minute_rule`, `points[]` (`offset_min`,
`value` or null, `support` seconds, `valid`), `before_valid_minutes`, `after_valid_minutes`,
`eligible_minutes_each_side` (30), `before_median`, `after_median`, `change` (after − before; metrics with the
usual status/reason; both sides need ≥ 20 valid minutes). HR minute = median of plausible HR seconds, valid with
≥ 30 distinct seconds. Temperature minute = the thermal group's accepted minute bin. Movement minute = moving
seconds among true one-second gravity adjacencies, valid with ≥ 30 eligible adjacencies, no off-wrist.

### 4.4 Stage-associated movement (owner: cardiac)

`movement.stage_movement` (`[SleepAnalyticsStageMovement]`, labels wake, light, deep, rem, unknown) joins each
classified one-second adjacency to the normalized timeline label at its second (unknown stays unknown):
`eligible_seconds`, `movement_seconds`, `movement_percentage`, `movement_bout_starts` (bouts whose first moving
second falls in the label), `movement_bouts_per_eligible_hour` (needs ≥ 1800 eligible seconds, else partial).
`movement.stage_movement_note` = `stages_may_depend_on_motion`.

## 5. `daily.sleep_features` (Python producer; Swift decoder `SleepFeatureDocument.swift` is root-owned)

`algorithm_version` stays `nara-sleep-features-1` (the request validator compares it), `CONFIG_VERSION` stays
`sleep-features-defaults-1`; every new block carries its own `method_version`.

### 5.1 Request additions (root-owned: `features/contract.py`, worker `SleepFeatureEnrichment.swift` = temperature)

`history.days[].nights` (optional, ≤ 8 per day): `{start, end, is_nap, asleep_min, awake_min, efficiency}` from the
day's published snapshot sleep entries (null where the snapshot has no value).

`history.days[].timezone` (optional IANA id of that day's claim).

`rhythm_history` (optional, bounded longer lookback, ≤ 35 days, ≤ 26 bins/day):

```json
{
  "schema": "rhythm-history-1",
  "device_family": "whoop5",
  "conversion_identity": "whoop5-centidegree",
  "bin_seconds": 3600,
  "rules": {"minute_min_distinct_seconds": 30, "worn_minute_min_hr_seconds": 30,
            "skin_temp_plausible_c": [28.0, 42.0], "movement_threshold_g": 0.01},
  "revision_digest": "<sha256 over day:revision|… + conversion identity + rules>",
  "days": [{"day": "2026-10-01", "timezone": "America/Los_Angeles", "revision": 123,
            "day_start_utc": 1790000000, "day_end_utc": 1790086400,
            "bins": [{"start": 1790000000,
                      "skin_temp_c": 33.41, "skin_temp_valid_minutes": 52,
                      "hr_mean_bpm": 61.2, "hr_valid_minutes": 59,
                      "movement_s_per_min": 4.2, "movement_valid_minutes": 57}]}]
}
```

Bins are UTC-hour aligned (`start` = unix hour start) and listed only when the hour has data; a missing signal in a
bin is `null`, never 0. Values are aggregated near the source (SQL minute aggregates, rolled up in the worker, cached
per day and revision) so the request stays a few hundred bins. `skin_temp_c` is the median of valid minute medians
of converted temperature; a minute is valid when worn (≥ 30 HR seconds) and it has ≥ 30 distinct in-band seconds.

### 5.2 `respiratory_variability` additions (owner: respiratory)

`method_version` `resp-variability-2`; `supported_range` (`detector_band_bpm` [6, 24], `min_peak_spacing_s` 2.5,
`display_rate_range_bpm` [8, 25], `source` `SleepStager.respBreathTrack`); `interval_distribution` (status,
reasons, `n_intervals`, `median_s`, `iqr_s`, `p05_s`, `p10_s`, `p25_s`, `p75_s`, `p90_s`, `p95_s`, `source`
`consecutive_intervals_within_usable_runs`); `stable_modulation` (status, reasons, `definition_version`
`stable-resp-modulation-1`, `criteria`, `stable_minutes`, `evaluated_minutes`, `unknown_minutes`,
`stable_fraction_of_evaluated`, `stable_fraction_of_night`); `stage_conditioned[stage]` gains `sd_interval_s`,
`rmssd_interval_s`, `median_interval_s`, `iqr_interval_s`. Unknown time is never stable; gaps never create long
breaths, stable time or episodes. No tachypnea/bradypnea/pause/apnea counts.

### 5.3 `prv_nonlinear` per night (owner: cardiac)

Status, reasons, `method_version` `prv-nonlinear-1`, `neurokit2` version, `source` `prv_optical`, `secondary`
true, `config` (`segment_beats` 300, `sampen_dimension` 2, `sampen_tolerance_sd` 0.2, `dfa_scales` [4, 16],
`min_segments` 3), `segments_used`, `segments_rejected`, `sample_entropy` and `dfa_alpha1` (`median`, `iqr`,
`segments`). Segments are non-overlapping runs of exactly `segment_beats` consecutive true-adjacent cleaned
intervals inside the main night; nothing is concatenated across gaps and only equal-length segments are pooled.

### 5.4 Rhythm (owner: temperature)

`nights[main].thermal.observed_skin_temp_rhythm` keeps its keys (`status`, `reasons`, `mesor_c`, `amplitude_c`,
`acrophase_h`, `fit_quality`, `is`, `iv`, `daily_amplitude_c`, `phase_stability_h`, `notes`) and adds
`method_version` `skin-temp-rhythm-1`, `history_revision_digest`, `qualifying_days`, `days_evaluated`,
`coverage` (`day_hours_supported`, `night_hours_supported`, `quadrants_observed`), `uncertainty`
(`acrophase_se_h`, `amplitude_se_c`, `method`), `phase_status` (`available` | `unavailable` + reason
`zero_amplitude` | `unstable_phase` | `mixed_devices` | `insufficient_days` | `insufficient_daytime_temperature`),
`iv_definition` (`consecutive_valid_hour_pairs_across_midnight`), `phase_relations`
(`hr_minus_temp_acrophase_h`, `sleep_midpoint_minus_temp_acrophase_h`, each with both components and status) and
`phase_drift` (`utc_drift_h_per_day`, `daily_phases`, `clock_changes`, `observed_realignment`). Gate: ≥ 5
qualifying days, each ≥ 80 % of its hours supported, every 6-hour local quadrant observed. Night-only data is
`insufficient_daytime_temperature`. Naps carry `not_applicable`.

`rest_activity_rhythm` (document level): status, reasons, `method_version` `rest-activity-1`, `signal`
(`gravity_movement_seconds_per_minute`), `epoch_seconds` 3600, `is`, `iv`, `l5`, `m10`, `l5_start_h`,
`m10_start_h`, `ra`, `days_used`, gate description. Withheld with a precise reason when movement history is absent.

### 5.5 `rebound` (document level, owner: respiratory)

Status, reasons, `definition_version` `sleep-rebound-1`, `history_revision_digest`, `personal_reference`
(`median_asleep_min`, `median_awake_min`, `nights`), `rules`, `after_short` and `after_fragmented` (`pairs`,
`next_night_asleep_diff_min` median/IQR, `next_night_awake_diff_min` median/IQR), `notes`. Descriptive only.

## 6. Physiology context (root-owned contract: `PCContract.swift`, `PCEngine.swift`)

- `PolicyVersions.pulse` (`pc-pulse-1`) and `PolicyVersions.respiratoryRecovery` (`pc-resp-recovery-1`), both
  optional on decode. `Policy.pulse: PulseEpisodeConfig`. Every version enters `Policy.fingerprint`.
- `DayDocument.pulseEpisodes: PulseEpisodeSummary?` (owner: cardiac, `PCPulseEpisodes.swift`).
- `SleepRhythmSummary.dayNightHeartRate: DayNightHeartRate?` (owner: cardiac, `PCSleepRhythm.swift`).
- `BoutRecovery.respiratoryRecovery: RespiratoryRecovery?` (owner: respiratory, `PCExertionBouts.swift`);
  `ExertionBouts.detect` receives the day's respiratory-rate measurements.
- `ReferenceConfig.stableAwakeMetrics` gains `.respiratoryRate` through an explicit adapter (owner: respiratory).

New reason codes are declared in the owner's `reasonCodes` array and must be mapped in
`MeasurementContextWording.swift` (`PhysiologyContextWordingCoverageTests`). Reserved:

| Owner | Codes |
| --- | --- |
| cardiac (pulse) | `pulse_episode_high`, `pulse_episode_low`, `hr_acceleration_with_movement`, `episode_censored_gap`, `episode_censored_qualification`, `qualified_inactive_hr_insufficient`, `cause_not_attributed`, `not_rhythm_classification` |
| cardiac (day/night) | `percent_dip_definition`, `awake_hr_insufficient`, `sleep_hr_insufficient` |
| respiratory | `respiratory_reference_unavailable`, `respiratory_observations_resumed`, `respiratory_returned_by_first_observation`, `respiratory_not_returned_in_follow_up`, `respiratory_follow_up_unobserved`, `stable_awake_respiration_window` |

## 7. Ownership and integration protocol

| Agent | Worktree / branch | Owns |
| --- | --- | --- |
| cardiac | `nara-spec02-cardiac` / `spec02/cardiac-prv-20261007` | `SleepAnalyticsPrv.swift`, `SleepAnalyticsMovement.swift`, `HRVFreqDomain.swift`, `PCPulseEpisodes.swift`, `PCSleepRhythm.swift`, `features/prv_nonlinear.py`, their tests |
| respiratory | `nara-spec02-resp` / `spec02/respiratory-context-20261007` | `features/respiration.py`, `features/rebound.py`, `PCExertionBouts.swift`, `PCReferences.swift`, `PCEligibility.swift`, their tests |
| temperature | `nara-spec02-thermal` / `spec02/temperature-circadian-20261007` | `SleepAnalyticsThermal.swift`, `SleepAnalyticsMorning.swift`, `CircadianEngine.swift`, `features/thermal.py`, `features/rhythm.py`, worker `SleepFeatureEnrichment.swift` and its call site in `DayScoring.swift`, their tests |
| readback/UI | `nara-spec02-ui` / `spec02/readback-ui-20261007` | `Strand/Screens/*`, `Strand/Push/*`, `Strand/App/AppModel.swift` (wording only), `Localizable.xcstrings`, `StrandTests/*` |
| root (lead) | `nara-spec02-features` / `feat/spec02-feature-reuse-20261007` | this file, `SleepAnalyticsV1.swift`, `SleepAnalyticsComputation.swift`, `SleepFeatureDocument.swift`, `PCContract.swift`, `PCEngine.swift`, `features/contract.py`, `features/compute.py`, golden fixtures, `docs/CURRENT_ALGORITHMS.md`, `HANDOFF.md` |

Agents commit only on their own branch, never push, never deploy, never touch another agent's files (ask the lead
for a contract change). The golden pair `Tools/CloudWorker/Tests/frwhoop-workerTests/SleepFeatureWireFixtures/*`
is regenerated by the lead after merging. Heavy builds go through
`_build-scratch/spec02/sbuild.sh` (shared slot limit).
