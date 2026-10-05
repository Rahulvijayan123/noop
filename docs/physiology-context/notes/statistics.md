# Physiology context — statistics (System F)

Owner: statistics workstream. Code: `Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyContext/`
`PCReferences.swift` (daily values, reference views), `PCChangeDetection.swift` (episodes, multi-signal),
`PCRobustStats.swift` (primitives), `PCEvaluation.swift` (synthetic evaluation harness). Tests:
`PCReferenceTests`, `PCChangeDetectionTests`, `PCEvaluationTests`, `PCEvaluationReportTests` (env-gated report).

**What the numbers here are.** Everything below is verified on arithmetic and on synthetic series: AR(1) Gaussian
noise with known steps, drifts, artifacts and missing days. None of it says how often a real night shifts, how any
WHOOP signal behaves, or anything about disease. In the readiness vocabulary of spec C12 this system is
*implemented* and *arithmetic-tested*. It is not integration-tested by this workstream (the lead wires it). It is not
accuracy-validated and not clinically validated.

- [1. Daily values](#1-daily-values)
- [2. Reference views](#2-reference-views)
- [3. Episodes](#3-episodes)
- [4. Multi-signal dependence](#4-multi-signal-dependence)
- [5. Evaluation plan (spec §14)](#5-evaluation-plan-spec-14)
- [6. Evaluation results](#6-evaluation-results)
- [7. Choice of defaults](#7-choice-of-defaults)
- [8. Limitations](#8-limitations)
- [9. Reason codes](#9-reason-codes)
- [10. Tests and verification cases](#10-tests-and-verification-cases)
- [11. Commands and results](#11-commands-and-results)
- [12. Requests to the lead](#12-requests-to-the-lead)

## 1. Daily values

`ContextReferences.dailyValues(envelopes:identity:mode:finality:config:)` produces one value per
(day, series, regime, mode). The independent unit of every reference is the **day**: one supported day counts once,
however many windows support it.

| Series | Source envelopes | Rule |
| --- | --- | --- |
| `hrv_rmssd.sleep_night`, `resting_hr.sleep_night`, `resp_rate.sleep_night`, `skin_temp.sleep_night`, `heart_rate.sleep_night`, `hrv_sdnn_index.sleep_night` | `snapshot.*` methods | Eligible for `sleep_measurement`, validity `valid` or `degraded` (reason `degraded_validity_included`), finite value. The night belongs to the local day containing its support end (contracts §2). If several qualify, the longest support wins (`multiple_nightly_values_longest_kept`). Skin temperature carries `relative_use_only`. SpO2 is never a comparison input. Whole-session SDNN is excluded because it grows with recording length (Shaffer & Ginsberg 2017, research note 3); only an SDNN index (`mean_over_windows`) is admitted. |
| `hrv_rmssd.stable_awake_5min`, `hrv_sdnn.stable_awake_5min`, `heart_rate.stable_awake_5min` | 5-minute series / context windows (`windowS == 300`) | Eligible for `stable_awake_rest` with validity `valid` (degraded excluded) and a support start inside the day. The value is the median of the windows. It needs at least 3 **non-overlapping** windows (`supportCount`). Overlapping windows still enter the median but are not counted as support (`overlapping_windows_not_counted`). |
| `<stable-awake series>.band_HH_HH` | Same windows | The same rule per local-time band (bands start at 00, 06, 12 and 18 h, `localTime.secondsOfDay`); a band needs its own 3 windows (`time_band_stratum`). These strata feed only the conditioned view. |

- **No zero-filling.** No qualifying envelope means no daily value.
- **Regimes stay apart.** Values from different `regimeKey`s are separate daily values.
- **HRV definitions stay apart.** RMSSD, SDNN and SDNN index keep separate series keys, and units never pool them.
- **Excluded series.** Series in `excludedSeriesPrefixes` (default `coverage.`) are never compared.

## 2. Reference views

`ContextReferences.compare(...)` returns, for every value of the day:

- parent series: one `recent`, one `rolling` and one `frozen` comparison;
- time-band strata: one `conditioned` comparison.

**What is pooled.** Only history of the same series, the same `regimeKey` and the same mode is pooled; regime keys must
be equal (the System A rule `identical_regime`). History from `day` or later is dropped even when the caller passes it
(`future_history_ignored`). Today's value therefore never enters its own references: it is scored before it can be
incorporated (spec §12.1, V10). Duplicate history days are resolved deterministically: largest support first, then
lowest value, then source ids (`duplicate_history_day_resolved`).

**Units.**

| Field | Scale |
| --- | --- |
| `center`, `signedDifference`, `centerUncertainty` | Original units |
| `scale`, `robustZ`, `transformedCenter` | The `transform` scale |
| `transformedDifference` | The ln ratio `ln(value / center)` (ln series only) |

**Transform.** RMSSD and SDNN are compared on the ln scale:

- They are right-skewed and vary multiplicatively.
- Day-to-day monitoring practice uses Ln rMSSD (Plews 2012–2014, Buchheit 2014, research note 2). Buchheit gives no
  formal rationale.
- The existing readiness engine already uses ln RMSSD (`Baselines.swift`, `readiness_hrv_ln`).

All other series use the identity transform.

**`robustZ` is a distance in robust-scale units, never a probability** (research note 1). It maps to Gaussian tail
probabilities only if the history is roughly normal and symmetric, which nothing here establishes.

### 2.1 Estimators

| View | Window (calendar days before `day`) | Center | Scale | Status |
| --- | --- | --- | --- | --- |
| recent | 7 | median | rolling scale when the rolling view has ≥ 7 days (`scale_from_rolling_view`); else its own floored MAD scale, provisional (`scale_from_recent_window`) | insufficient below 3 days |
| rolling | 28 | median | `1.4826 · MAD · b_n`, floored | insufficient < 7 days, provisional 7–13, ready ≥ 14 |
| frozen | registered once (see 2.3) | median of the selection | `1.4826 · MAD · b_n` of the selection, floored | ready once registered; insufficient / unavailable before |
| conditioned | child band 28, parent rolling 28 | `w·child + (1−w)·parent`, `w = n/(n+7)` | `sqrt(w·s_c² + (1−w)·s_p²)`, floored | see 2.4 |

- **`1.4826`** is the normal-consistency constant of the MAD (Rousseeuw & Croux 1993). The median and MAD have a 50 %
  breakdown point: one artifact moves the median by at most one rank. The MAD's Gaussian efficiency is only 37 %,
  which shows up in the false-alarm numbers (§6).
- **`b_n`, the small-sample factor** (`RobustStats.madSmallSampleFactor`). The raw MAD averages 0.911 σ at n = 10,
  0.959 σ at n = 20 and 0.978 σ at n = 40 (Rousseeuw & Croux, Table 1), which would inflate z by 4–9 % on 7–28-day
  windows.
  - For n ≥ 10 the factor is `n/(n − 0.8)`, which reproduces those table values within 1 %.
  - For n ≤ 9 it is our own Monte Carlo: 400 000 Gaussian samples per n, numpy seed 20261005, same even-n median
    convention.
  - §6 re-checks the corrected mean at 0.993–1.001.
  - Turning the factor off raises null false episodes slightly (0.034 vs 0.030 per week at φ = 0.3).
- **`centerUncertainty`** is `1.2533 · scale / √n`, the asymptotic standard error of a median of independent Gaussian
  values. For ln series it is mapped to original units by the delta method (`center · se`). It is labelled
  `median_se_iid_normal_approx` with reason `center_uncertainty_approximate`. Autocorrelated days have fewer effective
  samples, so it understates the real uncertainty.
- **Adaptation guard.**
  - The default reference (median / MAD over 28 days) needs no extra weighting: an isolated artifact cannot move it
    (§6: maximum center shift about 0.1 SD).
  - Winsorizing the inputs would not change a median / MAD reference at all.
  - The alternative `rollingEstimator = winsorized_mean_sd` takes mean and SD of values winsorized at median ± 2.5
    robust scales (Leys et al. 2013 cutoff), with SD rescaled by the winsorized-normal variance (0.9776 at k = 2.5).
    It is more efficient and less robust; it is reported in the sensitivity table.
  - Raw values are never modified: the daily value keeps the artifact and the comparison reports it.
- **Staleness.** When the newest supported day is more than 7 days old the comparison carries `stale_history`; the
  status is unchanged.

### 2.2 Scale floors

A zero or tiny MAD never gives infinite certainty. A constant history gets the floor, `scaleFloored = true`,
`scale_floored` and `constant_history`. An identical value then has distance 0. Neither paper gives a numeric floor
(research note 1), so the floors are engineering choices.

| Series prefix | Floor | Basis |
| --- | --- | --- |
| `hrv_rmssd.`, `hrv_sdnn` | 0.05 ln (≈ 5 %) | Below half the ~12 % typical error of resting Ln rMSSD (Buchheit 2014); it binds only when the personal spread is implausibly tight. Unlisted ln series use the same value. |
| `resting_hr.`, `heart_rate.`, `hr_response.` | 1.0 bpm | Integer bpm resolution: a MAD of integer data collapses to 0 when more than half the values tie |
| `resp_rate.` | 0.3 breaths/min | Engineering choice |
| `skin_temp.` | 0.1 °C | Engineering choice |
| others | 2 % of \|center\| (min 1e-6) | Engineering choice |

The sensitivity table includes resting HR at floors of 0.5, 1 and 2 bpm. At 2 bpm, 92 % of 1-bpm-SD shifts are
missed. At 0.5 bpm, null and frozen false episodes rise.

### 2.3 Frozen reference

- **Selection.** The first 14 supported days of the (series, regime) that fit within 42 calendar days, in the
  **loaded** history (the worker loads 90 days). Recorded verbatim as
  `first_14_supported_days_within_42_calendar_days_of_loaded_regime_history`.
- **Storage.** `version = 1`; id = `frz_` + FNV-1a(`series|regime|version|fromDay`); median and floored MAD scale on
  the transform scale.
- **When it registers.** Only in retrospective mode (`frozenRegistrationModes`), because storage keys frozen
  references by (series, regime, version) without the mode. Causal mode reads a stored reference and otherwise
  reports `frozen_not_registered` and `frozen_registers_in_other_mode`.
- **Never replaced.** A stored reference is used as is. A later policy floor can raise the scale used in comparisons
  (`frozen_scale_floored_by_current_policy`); the stored value is never rewritten.
- **New regimes.** A new regime gets its own frozen reference.
- **Labelling.** Every frozen comparison carries `frozen_reference_is_historical_not_healthy`: it is a historical
  reference, not a healthy baseline.
- **Leakage.** Frozen z is computed only for days after `toDay`; scoring the selection against itself would be
  in-sample.

### 2.4 Conditioned view (partial pooling)

Hard-stratifying stable-awake values by time of day would create sparse baselines (spec §12.2). Instead:

- **Shrinkage.** A band value (child) is compared with its own band history, shrunk toward the all-day parent rolling
  reference. The child weight is `w = n_c / (n_c + k)` with k = 7 days, and `pooledContribution = 1 − w`.
- **No population level.** There is no population prior (`no_population_prior`): no population data exists to fit one.
- **Statuses.**
  - ready: ≥ 7 child days and a ready parent;
  - provisional: pooled (`pooled_toward_parent`), parent only (`context_unsupported_parent_only`, contribution 1), or
    child only when the parent is insufficient (`parent_insufficient_child_only`);
  - insufficient: neither child nor parent has enough support.
- **Uncertainty.** `sqrt((w·se_c)² + ((1−w)·se_p)²)`. It ignores the positive correlation between child and parent
  (the parent contains the same days), so it understates the uncertainty.
- **Nightly series.** They are already conditioned on sleep and have no stratum. No conditioned comparison is
  emitted for them: no further covariate is justified by the inputs that exist.

## 3. Episodes

`ChangeDetection.episodes(...)` analyses every (series, regime) with a value in the trailing 90 days. Each supported
day d in the window is scored sequentially, with no look-ahead:

- `z_d` against the rolling reference of days `[d − 28, d − 1]` (exactly the `rolling` view's estimator, so the
  episode z equals the comparison z shown on the envelope);
- `z_d` against the frozen reference (days after its selection only).

Missing days are skipped, never zero-filled. A gap of more than 7 days resets the detectors (`gap_reset`). A regime
boundary inside the series also resets them (`split_at_regime_boundary`), so an episode never spans a boundary.
Strata do not get episodes (`episodesForStrata = false`).

### 3.1 Detectors

**Default: autocorrelation-adjusted two-sided CUSUM on the daily robust z.**

`S_t = min(cap, max(0, S_{t−1} + dir · c(z_t) / a_t − k))`, where:

- **Clamp.** `c(z)` clamps z to ±2. One extreme day then contributes at most (2 − 0.25)/7 ≈ 25 % of the evidence an
  alarm needs.
- **Autocorrelation adjustment.** `a_t = sqrt((1 + φ̂)/(1 − φ̂))` is the AR(1) long-run SD factor. φ̂ is a robust
  lag-1 autocorrelation of consecutive-day pairs: MAD-scaled deviations winsorized at ±3, clamped to [0, 0.8], at
  least 20 pairs.
  - φ̂ is estimated on days d−69…d−14. The 14-day guard band stops a fresh change from inflating its own φ̂.
  - Without the adjustment, autocorrelated days count as independent evidence and false episodes multiply with φ
    (research note 8; §6).
- **Parameters.** k = 0.25 and h = 7 in long-run SD units; cap = 1.25·h.
- **Episode shape.**
  - A run (S > 0) becomes a `persistent_shift` once S > h, and stays ongoing while S > h.
  - `startDay` is the first day of the run, the standard CUSUM change-point estimate. With a small k it can precede a
    real step by several days.
  - `alarmDay` is the first day S > h; `detectionDelayDays` is the calendar days from start to alarm.
  - `lastDay` is the last day that pushed S up while the alarm held.
- **Never on rolling means.** The CUSUM runs on daily values, never on rolling means (research note 8).

**Alternative: persistence rule.** At least 3 of the last 5 supported days have |z| ≥ 2 in the same direction
(`detector = "persistence"`). It is always computed. Each primary episode records `alternative_detector_agrees` or
`alternative_detector_silent`.

**Frozen persistence.** At least 5 of the last 7 frozen-scored days have |z_frozen| ≥ 2 in one direction. It keeps
fixed-reference deviations visible after the rolling reference adapts (spec §12.3):

- If it fires on the latest day and the rolling detector had closed a same-direction episode, that episode is
  extended and ongoing (`rolling_adapted_frozen_deviation_persists`).
- Otherwise it opens a `persistent_shift` with `detector = "frozen_persistence"` and `frozen_reference_deviation`,
  plus `gradual_drift` when no rolling alarm covers it.

Closed rolling episodes carry `returned_toward_reference` or `rolling_adapted_not_proof_of_recovery`. A rolling
baseline can describe a changed state without proving recovery.

### 3.2 States

| State | Definition |
| --- | --- |
| `transient_deviation` | Same-direction days with \|z_rolling\| ≥ 2.5 (Leys et al. 2013 cutoff), merged across ≤ 1 non-deviating supported day, outside a same-direction persistent episode (`isolated_excursion`) |
| `recurring_episode` | ≥ 2 same-direction transients, each starting ≤ 28 days after the previous ended. Reported once (start = first, last = last, `occurrences`); its members are not repeated. |
| `persistent_shift` | CUSUM alarm sustained, or the frozen persistence rule as above |
| `usual_variation` | Status entry: ≥ 7 scored days in the window and no ongoing non-usual episode |
| `insufficient_evidence` | Status entry: < 7 scored days (`too_few_supported_days`, plus `no_reference` when nothing could be scored) |

Every episode carries:

- `descriptive_not_diagnostic`;
- `rollingMagnitude` / `frozenMagnitude`: median `value − center` in original units;
- `medianRollingZ` / `medianFrozenZ`;
- `trendPerWeek`: Theil–Sen slope of the raw values over the window, in original units per week. Theil 1950 / Sen 1968
  are standard, not opened here; the slope is robust to single artifacts.
- `trendDays`, `peakStatistic`, `units`, `transform`, `frozenReferenceId`, `supportDays` (scored days).

Rolling and frozen agreement is recorded as `frozen_and_rolling_agree`, `frozen_and_rolling_disagree` or
`frozen_unavailable`. An episode starting within ±1 day of a regime boundary carries
`coincides_with_regime_boundary`. Boundaries come from two sources:

- the provided `RegimeBoundary`s, by UTC day, with the tolerance covering the zone offset;
- regime-key changes in the series' own history.

**Ids and ongoing.** `id = "ep_" + FNV-1a(series|regime|startDay|direction|policyFingerprint)`. At most one episode
exists per (start day, direction); the stronger state wins. An episode is `ongoing` only if its condition holds on the
latest scored day **and** that day is within 3 days of `day` (`no_recent_support` otherwise). An episode reaching back
to the first scored day of the window carries `starts_at_window_start`. Nothing is called disease progression.
Nothing notifies.

## 4. Multi-signal dependence

`ChangeDetection.multiSignal(...)` takes today's `rolling` comparisons that are ready or provisional with
|z| ≥ 2.5 (strata excluded) and builds dependence groups:

1. **Map each series to members.** A series maps to its metric (`hrv_rmssd`, `respiratory_rate`, …) plus the
   selection it shares:
   - `sleep_detector` for `*.sleep_night` series, because sleep eligibility reads heart rate;
   - `eligibility_stillness` for `*.stable_awake*` series (strap-motion stillness).
2. **Assign groups.** Each series gets every `DependenceNote.group` whose members intersect its own.
3. **Connect.** Series that share any group are connected (union-find).

`independentGroupCount` is the number of connected components. It is an upper bound on independent lines of evidence,
not proof of independence (`distinct_groups_not_proven_independent`).

Reasons:

- `shared_inputs_not_independent` when a component holds more than one series. HRV and respiratory rate share
  `beat_intervals` → one group (V13).
- `selection_reads_heart_rate` for nightly series.
- `no_declared_dependence` for series without a declared group.

A day with comparisons but nothing deviating returns one summary with count 0 and `no_deviating_series`.

## 5. Evaluation plan (spec §14)

Defined before tuning; what it covers here and what remains for real data:

1. **Separate questions.**
   - Context classification (Systems A–B: eligibility, validity), physiological prediction and disease validity are
     evaluated separately.
   - This workstream evaluates only the **arithmetic** of references and change detection on synthetic series with
     known truth. It makes no physiological or disease claim.
   - Classification accuracy of eligibility labels needs independent reference labels (not available).
2. **Splits.**
   - Personalized references and detectors are evaluated **forward chronologically only**: each day is scored with
     earlier days (the production path `ChangeDetection.analyze`).
   - There are no random splits, and no overlapping windows are ever shared across a train/test boundary.
   - Any general model fitted later (population priors, φ priors, thresholds learned from many users) must be
     evaluated **subject-held-out** (leave users out). The final temporal test set is reserved untouched.
3. **Fitting discipline.**
   - Reference centers, scales, φ̂ and frozen selections are computed only from permitted earlier days.
   - When real data are used, any threshold tuned on users A must be tested on users B.
   - Purge and embargo: the evaluation must leave out a gap at least as long as the longest lookback before each test
     block — 28 d rolling + 70 d φ̂ + 90 d episode window (research note 13).
4. **Availability cutoffs.** The engine's `causalView` handles availability before System F runs. System F adds
   day-level guards: history from `day` or later is ignored and outputs are unchanged when later days are appended
   (V10 tests). Real replays must also check that late-arriving values change only documents built after their
   availability.
5. **Multiple comparisons.**
   - Thresholds were selected on development sweeps with seed 777 (100 replicates) and reported on seed 20261005.
   - One exploratory run before tuning used the reporting seed with 100 replicates, which are the first 100 of the 400
     reported. It showed the false-alarm problem that the tuning then addressed. The reporting seed is therefore not
     fully untouched; the real safeguard is the reserved real-data test set.
   - Every variant tried is listed in §6.
   - Several series per person multiply false episodes. The multi-signal summary counts dependence groups and does not
     treat co-deviation as corroboration.
6. **Intervals.**
   - Per-replicate statistics (delay, missed rate): percentile bootstrap over independent replicate series, which act
     like users.
   - Per-week rates: stationary bootstrap of weeks within replicates (Politis & Romano 1994, mean block 4 weeks,
     covering the 28-day reference horizon; research note 14).
   - No independent-sample interval is ever computed over overlapping windows.
7. **Coverage and abstention.** Every comparison reports support days and status. Insufficient and unavailable
   states are explicit; real-data reports must give the share of days scored alongside any detection rate.
8. **Calibration.** No output of System F is a calibrated probability, so no calibration or proper-scoring evaluation
   applies. `robustZ` is a distance, and no `Confidence` is emitted.
9. **Simple alternatives and sensitivity.** The CUSUM is compared with the persistence rule. Sensitivity covers
   recent and rolling windows, k / h / clamp, the autocorrelation adjustment and its guard band, persistence variants,
   estimator, small-sample factor, frozen threshold and scale floors (§6).
10. **Selection bias.**
    - Daily values exist only on eligible days. Eligibility (System B) reports per-day selection and represented share
      (`SelectionSummary`).
    - The synthetic evaluation covers missing-at-random days only (30 %). Informative missingness (e.g. no stable
      awake rest on days the person is unwell) is **not** evaluated and would bias references toward good days. It
      must be checked on real data by relating exclusion to symptoms and exposures.

## 6. Evaluation results

Produced by `PC_EVAL_REPORT=1 swift test --filter PCEvaluationReportTests` in `Packages/StrandAnalytics` (seed
20261005, 400 replicates per cell, 200 in the sensitivity table, 500 bootstrap resamples; ≈ 62 s on an M-series Mac).
The output is deterministic: two runs gave identical numbers. The synthetic RMSSD spec is 45 ms with SD 0.12 on the
ln scale. The resting-HR spec is 55 bpm with SD 1.2 bpm, rounded to integer bpm. "SD" means the marginal SD of the
synthetic daily noise. **Synthetic arithmetic checks only.**

**Null (no change), default policy, nightly ln RMSSD spec, 400 days, counted after day 35.** Rates per series-week,
95 % stationary-bootstrap interval (mean block 4 weeks).

| φ | missing | CUSUM persistent / wk | persistence-rule / wk | frozen persistence / wk | excursions / wk | recurring / wk | ≥1 CUSUM alarm in 90 d |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0.0 | 0 % | 0.030 (0.028–0.033) | 0.011 (0.009–0.013) | 0.006 (0.005–0.007) | 0.164 (0.157–0.171) | 0.037 (0.034–0.039) | 33 % |
| 0.3 | 0 % | 0.030 (0.028–0.033) | 0.025 (0.022–0.027) | 0.020 (0.018–0.022) | 0.159 (0.153–0.165) | 0.035 (0.033–0.037) | 38 % |
| 0.5 | 0 % | 0.022 (0.020–0.024) | 0.044 (0.040–0.046) | 0.043 (0.040–0.047) | 0.159 (0.152–0.165) | 0.031 (0.029–0.033) | 31 % |
| 0.3 | 30 % | 0.022 (0.019–0.024) | 0.020 (0.018–0.022) | 0.008 (0.007–0.010) | 0.148 (0.142–0.154) | 0.029 (0.027–0.032) | 32 % |

**Sustained step down at day 70, horizon 28 days.** Delay in days from the step among detected series; 95 % percentile
bootstrap over replicates. "Detected" includes series already in a same-direction alarm at the step (no delay).

| φ | step | missing | CUSUM missed | CUSUM delay median (CI) | p25–p75 / p90 | persistence-rule missed / median | frozen-rule missed / median | rolling adapted by +42 d | frozen still ≥ 2 at +42 d |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.0 | -1 SD | 0 % | 26 % (0.21–0.30) | 9.0 (9.0–10.0) | 6–14 / 18 | 86 % / 6.0 | 82 % / 11.5 | 96 % | 10 % |
| 0.0 | -2 SD | 0 % | 0 % (0.00–0.00) | 5.0 (5.0–5.0) | 4–6 / 8 | 54 % / 3.0 | 33 % / 6.0 | 96 % | 49 % |
| 0.3 | -1 SD | 0 % | 46 % (0.41–0.51) | 10.0 (9.0–11.0) | 7–14 / 20 | 78 % / 6.0 | 73 % / 10.0 | 92 % | 16 % |
| 0.3 | -2 SD | 0 % | 5 % (0.03–0.07) | 7.0 (6.0–7.0) | 5–10 / 13 | 48 % / 3.0 | 29 % / 6.0 | 92 % | 50 % |
| 0.5 | -1 SD | 0 % | 62 % (0.57–0.66) | 11.0 (9.0–12.0) | 7–15 / 20 | 68 % / 5.0 | 66 % / 10.0 | 83 % | 18 % |
| 0.5 | -2 SD | 0 % | 20 % (0.16–0.24) | 8.0 (8.0–9.0) | 6–12 / 15 | 39 % / 3.0 | 23 % / 6.0 | 83 % | 53 % |
| 0.3 | -1 SD | 30 % | 59 % (0.54–0.63) | 12.0 (11.0–14.0) | 7–17 / 22 | 84 % / 7.0 | 78 % / 11.0 | 87 % | 14 % |
| 0.3 | -2 SD | 30 % | 21 % (0.17–0.26) | 8.0 (8.0–9.0) | 5–13 / 18 | 60 % / 4.0 | 34 % / 9.0 | 87 % | 52 % |

**Gradual drift down (0.05 SD/day for 60 days = 3 SD), read through `ChangeDetection.episodes` on the last day.**
The reported trend is the Theil–Sen slope over the 90-day window, which includes 30 flat days, so a ratio below 1 is
expected.

| φ | median rolling z (last 7 d) | median frozen z (last 7 d) | ongoing persistent shift | of which frozen-sourced | CUSUM alarmed during drift | reported trend / true trend |
| --- | --- | --- | --- | --- | --- | --- |
| 0.0 | -0.66 | -2.96 | 92 % | 8 % | 96 % | 0.78 |
| 0.3 | -0.70 | -3.06 | 87 % | 18 % | 92 % | 0.80 |
| 0.5 | -0.67 | -3.07 | 81 % | 38 % | 76 % | 0.79 |

**Isolated artifact (one day +8 SD at day 80), paired with the same series without it.**

| φ | artifact day → transient only | CUSUM alarm ≤ 14 d (with / without) | max rolling-center shift (SD) | max scale ratio | raw value preserved |
| --- | --- | --- | --- | --- | --- |
| 0.0 | 91 % | 6 % / 5 % | 0.098 | 1.180 | yes |
| 0.3 | 92 % | 6 % / 6 % | 0.116 | 1.170 | yes |
| 0.5 | 92 % | 5 % / 6 % | 0.104 | 1.188 | yes |

**Recent window (trajectory view), φ = 0.3.**

| recent window | null SD of recent center (SD) | days until center follows a 2-SD step by ≥ 1 SD |
| --- | --- | --- |
| 3 d | 0.77 | 2.0 |
| 5 d | 0.65 | 3.0 |
| 7 d | 0.56 | 4.0 |
| 10 d | 0.47 | 5.0 |

**CUSUM arithmetic check.** Known-parameter two-sided ARL0 (days to the first false alarm) of the production CUSUM fed
the true standardized values. Research note 8 gives ≈ 168–172 (φ = 0), ≈ 54 (φ = 0.3) and ≈ 35 (φ = 0.5) for
k = 0.5, h = 4.

| φ | k = 0.5, h = 4 | k = 0.25, h = 7 (unadjusted, unclamped) |
| --- | --- | --- |
| 0.0 | 163.4 | 216.4 |
| 0.3 | 54.0 | 70.8 |
| 0.5 | 33.9 | 41.8 |

**Small-sample MAD factor (Gaussian, mean of 1.4826·MAD; target 1.000).**

| n | raw | corrected |
| --- | --- | --- |
| 3 | 0.669 | 0.994 |
| 5 | 0.821 | 0.999 |
| 7 | 0.879 | 1.001 |
| 10 | 0.914 | 0.993 |
| 14 | 0.943 | 1.000 |
| 28 | 0.972 | 1.001 |

**Sensitivity, φ = 0.3.** Null false persistent episodes per week for the variant's primary detector; 1-SD and 2-SD
steps down, 28-day horizon.

| variant | null / wk (CI) | frozen rule null / wk | 1 SD missed | 1 SD median delay | 2 SD missed | 2 SD median delay |
| --- | --- | --- | --- | --- | --- | --- |
| default: AR-adjusted CUSUM k=0.25 h=7, clamp 2, rolling 28 d median/MAD | 0.030 (0.027–0.033) | 0.022 | 47 % | 10.0 | 4 % | 6.0 |
| AR-adjusted CUSUM k=0.25 h=6 | 0.051 (0.047–0.055) | 0.022 | 32 % | 9.0 | 2 % | 5.0 |
| AR-adjusted CUSUM k=0.25 h=8 | 0.018 (0.016–0.020) | 0.022 | 57 % | 11.0 | 12 % | 7.0 |
| AR-adjusted CUSUM k=0.5 h=5 | 0.015 (0.013–0.017) | 0.022 | 76 % | 8.0 | 25 % | 6.0 |
| AR-adjusted CUSUM clamp 3 | 0.048 (0.044–0.052) | 0.022 | 36 % | 9.0 | 3 % | 5.0 |
| unadjusted CUSUM k=0.25 h=7 | 0.103 (0.098–0.108) | 0.022 | 10 % | 7.0 | 0 % | 4.0 |
| unadjusted classic CUSUM k=0.5 h=4, no clamp | 0.175 (0.170–0.182) | 0.022 | 11 % | 5.0 | 1 % | 2.0 |
| AR-adjusted, no autocorrelation guard band | 0.029 (0.026–0.032) | 0.022 | 53 % | 10.0 | 16 % | 7.0 |
| persistence 3 of 5, abs z ≥ 2 | 0.023 (0.020–0.026) | 0.022 | 77 % | 6.0 | 50 % | 3.0 |
| persistence 4 of 7, abs z ≥ 2 | 0.008 (0.006–0.010) | 0.022 | 88 % | 7.0 | 62 % | 4.0 |
| persistence 3 of 5, abs z ≥ 2.5 | 0.005 (0.004–0.007) | 0.022 | 94 % | 6.0 | 76 % | 3.0 |
| rolling 14 d (min 7) | 0.021 (0.019–0.024) | 0.022 | 77 % | 8.0 | 34 % | 6.0 |
| rolling 42 d | 0.034 (0.030–0.037) | 0.022 | 32 % | 11.0 | 1 % | 6.0 |
| winsorized mean/SD reference | 0.022 (0.019–0.024) | 0.022 | 47 % | 10.0 | 6 % | 7.0 |
| no small-sample MAD factor | 0.034 (0.031–0.037) | 0.027 | 45 % | 9.0 | 3 % | 6.0 |
| frozen rule abs z ≥ 1.5, 5 of 7 | 0.030 (0.027–0.033) | 0.057 | 47 % | 10.0 | 4 % | 6.0 |
| resting HR (integer bpm), floor 1 bpm (default) | 0.013 (0.010–0.015) | 0.016 | 66 % | 10.0 | 8 % | 7.0 |
| resting HR, floor 0.5 bpm | 0.018 (0.016–0.021) | 0.036 | 62 % | 10.0 | 7 % | 7.0 |
| resting HR, floor 2 bpm | 0.000 (0.000–0.001) | 0.000 | 92 % | 12.0 | 32 % | 10.0 |

Development sweeps used other seeds (100 replicates) over:

- estimator (median/MAD, winsorized);
- rolling window 28 / 42 / 56;
- (k, h) ∈ {(0.5, 4–8), (0.75, 4–5), (0.25, 6–10), (0.3, 6), (0.35, 6–6.5), (0.4, 6)};
- clamp 2 / 2.5 / 3;
- autocorrelation adjustment on/off and guard band 0 / 14;
- frozen rule z ∈ {1.5, 2} × {4, 5} of 7.

Only the configurations above are reported with the final seed.

## 7. Choice of defaults

- **CUSUM over the persistence rule.** At a similar null rate (~0.02–0.03 per series-week at φ = 0.3), the
  persistence rule (3 of 5, |z| ≥ 2) misses 50 % of 2-SD steps within 28 days. The CUSUM misses 4–5 %. Stricter
  persistence rules are quieter but miss most steps. The persistence rule stays computed as the comparison
  (`alternative_detector_*`).
- **Autocorrelation adjustment.** Without it, false episodes depend on the unknown day-to-day autocorrelation:
  unadjusted k = 0.25, h = 7 gives 0.103 per week at φ = 0.3; the classic k = 0.5, h = 4 gives 0.175 per week
  (≈ 6 per series-year). With it, the rate is 0.022–0.030 at every φ tested.
  - The price is sensitivity on autocorrelated series: a 1-SD step is missed 46–62 % of the time at φ = 0.3–0.5.
    Autocorrelated days carry less independent information.
  - The guard band (φ̂ from days 14–69 before) cuts 2-SD misses from 16 % to 4 % at no false-rate cost.
- **k = 0.25, h = 7, clamp 2.**
  - Under an adaptive 28-day reference, a real step's z decays as the median absorbs it. A small k integrates the
    decaying evidence: k = 0.5, h = 5 at a lower false rate misses 25 % of 2-SD steps.
  - h = 7 sets ≈ 0.03 false episodes per series-week (≈ 1.5 per series-year; about 1 in 3 series shows one within any
    90 days). This is a descriptive summary with magnitudes and reasons, not an alarm. h = 8 cuts the false rate by
    about 40 % and triples 2-SD misses.
  - Clamp 2 bounds one day's contribution. With clamp 3 the false rate rises to 0.048. In the development sweeps
    (100 replicates, so noisy) clamp 3 showed more persistent alarms within 14 days of a +8 SD artifact than without
    one (14 % vs 6 % at φ = 0.3). With clamp 2 the final run shows no difference (§6 artifact table: 6 % with vs 6 %
    without).
- **Rolling 28 days, median / MAD.** These are the spec's and the research notes' transparent defaults, inside the
  28-day cross-day invalidation horizon (contracts §6).
  - 42 days would detect 1-SD steps better (32 % missed vs 47 %) at a similar false rate. It would make comparisons
    depend on history outside the cascade horizon (see §12).
  - The winsorized mean / SD reference gives a slightly lower false rate at the same sensitivity but gives up the
    50 % breakdown. It stays an option.
- **Recent 7 days (min 3).** Spec range 2–7. The center follows a 2-SD step by 1 SD in 4 days, with null noise
  0.56 SD; 3 days is noisier (0.77 SD).
- **Frozen rule: 5 of 7, |z| ≥ 2.** At |z| ≥ 1.5 the frozen null rate nearly triples (0.057 per week). Fixed
  references accumulate estimation error and autocorrelated wander; their false rate grows with φ (0.006 → 0.043).
  This is documented rather than adjusted: the frozen view exists to keep large long-term deviations visible.

## 8. Limitations

- **Synthetic only.**
  - Gaussian AR(1) noise is a stand-in. Real nightly RMSSD may be heavy-tailed, seasonal, weekday-patterned and
    non-stationary.
  - The rates in §6 hold for the generator, not for people. The research notes require calibration on held-out real
    users before any threshold is treated as validated (research note 8).
- **Several series per person.** Several series per person multiply false episodes; the multi-signal summary counts
  shared-input groups but does not adjust for multiplicity.
- **Frozen references.** A frozen reference built from the first 14 loaded days may come from an atypical period; it
  is labelled historical, not healthy. Its estimation error is permanent for that reference.
- **Center uncertainty.** It assumes independent Gaussian days and understates the uncertainty under autocorrelation.
  The conditioned view's uncertainty also ignores the child–parent correlation.
- **Change-point estimates.** CUSUM change-point estimates are imprecise with k = 0.25: starts can precede a real step
  by several days.
- **Missingness.** It was evaluated only as missing at random. Informative missingness and eligibility-driven
  selection bias are not evaluated (§5 item 10).
- **Boundary days.** Regime boundaries are matched to local days by UTC day with ±1-day tolerance.
- **Conditioned view.** It exists only for stable-awake time bands; no other covariate is justified by the inputs that
  exist.
- **Not covered.** No population priors and no calibrated probabilities. Disease relevance of any episode is
  unaddressed by design.

## 9. Reason codes

Registries: `ContextReferences.reasonCodes`, `ChangeDetection.reasonCodes`. A test checks that every code emitted in
a set of scenarios is registered.

| Code | Meaning |
| --- | --- |
| `nightly_snapshot` / `stable_awake_windows` / `time_band_stratum` | How a daily value was built |
| `degraded_validity_included` | A degraded nightly value was admitted |
| `multiple_nightly_values_longest_kept` | Several nightly values qualified; the longest support was kept |
| `overlapping_windows_not_counted` | Overlapping windows entered the median but not the support count |
| `relative_use_only` | Skin temperature: deviation from own history only, never core temperature |
| `no_history` / `insufficient_history` / `provisional_support` | Support states of a view |
| `history_in_other_regime_only` / `other_regime_history_not_pooled` | Regime mismatch: other-regime history is never pooled |
| `stale_history` | Newest supported day is more than 7 days old |
| `history_values_excluded` | Non-finite (or ≤ 0 for ln) history values were ignored |
| `duplicate_history_day_resolved` | Two values for one day; one was kept by rule |
| `future_history_ignored` | History from the scored day or later was ignored |
| `scale_floored` / `constant_history` | The floor replaced a smaller scale / the history is constant |
| `log_transform` / `non_positive_value_for_log` | ln scale used / value cannot be log-transformed (no distance) |
| `small_sample_scale_correction` | `b_n` applied (n < 40) |
| `center_uncertainty_approximate` | `centerUncertainty` is the iid-normal approximation |
| `winsorized_mean_estimator` | The non-default rolling estimator is in use |
| `scale_from_rolling_view` / `scale_from_recent_window` | Which scale the recent view used |
| `frozen_reference_is_historical_not_healthy` | On every frozen comparison |
| `frozen_registered_this_run` / `frozen_not_registered` / `frozen_registers_in_other_mode` / `frozen_scale_floored_by_current_policy` | Frozen lifecycle |
| `pooled_toward_parent` / `context_unsupported_parent_only` / `parent_insufficient_child_only` / `no_population_prior` | Conditioned pooling |
| `detector_cusum` / `detector_persistence` | Which detector produced the episode |
| `alternative_detector_agrees` / `alternative_detector_silent` | The other detector's view of the same span |
| `frozen_and_rolling_agree` / `frozen_and_rolling_disagree` / `frozen_unavailable` | Reference agreement |
| `rolling_adapted_frozen_deviation_persists` | Rolling absorbed the shift; the frozen deviation persists |
| `rolling_adapted_not_proof_of_recovery` / `returned_toward_reference` | How a closed episode ended |
| `frozen_reference_deviation` / `gradual_drift` | Frozen-sourced persistent shift (drift without a rolling alarm) |
| `coincides_with_regime_boundary` / `split_at_regime_boundary` / `gap_reset` | Boundaries and gaps |
| `isolated_excursion` / `recurring_within_window` | Transient / recurring |
| `too_few_supported_days` / `no_reference` / `no_recent_support` / `starts_at_window_start` | Status and censoring |
| `descriptive_not_diagnostic` | On every episode |
| `shared_inputs_not_independent` / `selection_reads_heart_rate` / `no_declared_dependence` / `no_deviating_series` / `distinct_groups_not_proven_independent` | Multi-signal |

## 10. Tests and verification cases

| Case | Test (file `Tests/StrandAnalyticsTests/…`) | Expectation |
| --- | --- | --- |
| V10 | `PCReferenceTests.testRollingCenterAndScaleComeOnlyFromStrictlyEarlierDays`, `testAppendingLaterDaysNeverChangesAnEarlierDaysComparisons`; `PCChangeDetectionTests.testAppendingFutureDaysNeverChangesAnEarlierDaysEpisodes` | Today and later days in history change nothing; future frozen references ignored |
| V11 artifact | `PCChangeDetectionTests.testIsolatedArtifactIsTransientRawIsPreservedAndTheReferenceIsNotContaminated`; `PCEvaluationTests.testIsolatedArtifactIsMostlyTransientAndBarelyMovesTheReference` | One-day transient, no persistent shift, raw value kept, center shift < 0.25 SD |
| V11 step | `PCChangeDetectionTests.testSustainedStepIsAPersistentShiftWithItsDelayAndMagnitude`; `PCEvaluationTests.testStepsAreDetectedWithBoundedDelayAndTheCusumBeatsThePersistenceRule` | Persistent shift, alarm ≤ 6 days after the step, delay and magnitude reported |
| V11 adaptation | `PCChangeDetectionTests.testRollingAdaptsWhileTheFrozenDeviationStaysVisible` | Rolling \|z\| < 2.5, frozen z < −2, ongoing episode with `rolling_adapted_frozen_deviation_persists` |
| V11 drift | `PCChangeDetectionTests.testGradualDriftKeepsTheFrozenDeviationAndTheRawTrendVisible`; `PCEvaluationTests.testDriftKeepsTheFrozenDeviationVisibleAndReportsTheTrend` | Frozen z < −2, more extreme than rolling; negative Theil–Sen trend near the truth |
| V12 | `PCReferenceTests.testSupportStatesAreExplicitAndSparseHistoriesNeverScore`, `testConstantHistoryGetsTheFloorNotInfiniteCertainty`, `testStableAwakeValueIsTheMedianOfEnoughIndependentEligibleWindowsAndNeverZeroFilled`; `PCChangeDetectionTests.testSparseHistoryIsInsufficientEvidenceWithoutDistances`, `testMissingDaysAreSkippedNotZeroFilledAndALongGapResetsTheDetector`, `testConstantSeriesIsUsualVariationWithFlooredFiniteDistances` | Explicit statuses, floors, no NaN or infinity (all outputs encode), no z when insufficient |
| V13 | `PCChangeDetectionTests.testHrvAndRespiratoryRateDeviatingTogetherAreOneIndependentGroup`, `testOnlySeriesWithoutSharedDeclaredInputsCountAsSeparateGroups` | HRV + respiration = 1 group with `shared_inputs_not_independent` |
| V04 (System F part) | `PCReferenceTests.testOtherRegimeHistoryIsNeverPooled`, `testRegimesMethodsAndHrvDefinitionsStaySeparate`; `PCChangeDetectionTests.testRegimeBoundarySplitsTheSeriesAndIsReportedSeparately` | No cross-regime pooling; boundary episodes flagged and not merged |
| C05 | `PCReferenceTests.testReferencesAreReproducibleAndOrderIndependent`, `testFrozenReferenceIsRegisteredOnceVersionedAndNeverReplaced`, `testConditionedBandShrinksTowardTheAllDayParentWithReportedContribution`; `PCChangeDetectionTests.testEpisodeIdsAreDeterministicAndInputOrderDoesNotMatter` | Byte-identical output under shuffling; distinct, versioned views |
| Harness | `PCEvaluationTests` (determinism, generator, MAD factor, known-parameter ARL vs research note 8, null bounds, bootstrap) | See §6 |

## 11. Commands and results

All commands were run in `Packages/StrandAnalytics` on branch `pc/statistics`.

| Command | Result |
| --- | --- |
| `swift build` | OK |
| `swift test --filter "PCReference\|PCChange\|PCEvaluation"` | 15 + 18 + 9 tests passed; the report test is skipped unless `PC_EVAL_REPORT=1` |
| `PC_EVAL_REPORT=1 swift test --filter PCEvaluationReportTests` | Tables in §6, ≈ 62 s. Optional `PC_EVAL_REPLICATES`, `PC_EVAL_SENS_REPLICATES`, `PC_EVAL_SEED`, `PC_EVAL_OUT=<path>` |
| `swift test --parallel` | 2 591 XCTest cases passed, exit 0 |

## 12. Requests to the lead

1. **Cross-day horizon.** Comparisons depend on 28 days (rolling, conditioned child) and 7 days (recent), all inside
   the 28-day `history_changed` cascade. Episodes depend on 90 days of values, plus a φ̂ estimate from days 14–69
   before each scored day. Only the latest day's episode view is stored, and it is rebuilt with each new day, so stale
   episodes self-correct on the next day's run. Please keep the cascade at ≥ 28 days if any window grows.
2. **Series keys.** Please add the stratum keys `<stable-awake series>.band_HH_HH` (`hrv_rmssd.stable_awake_5min.band_06_12`,
   …), plus `hrv_sdnn_index.sleep_night`, `heart_rate.sleep_night` and `hrv_sdnn.stable_awake_5min`, to the
   contracts §5 table. They persist through `physiology_context_daily_values` like any other series; no schema change.
3. **Frozen registration race.** Registration happens only in retrospective mode; storage is insert-only on (series,
   regime, version). A replay of an older day with a different loaded history may compute a different candidate,
   which the database ignores (`on conflict do nothing`), while that day's document lists it in
   `newFrozenReferences`. Consider having the publish path drop `newFrozenReferences` that lost the insert, or
   re-reading stored references before building.
4. **Dependence notes.** HR and RR-derived metrics both come from the same optical pulse detection, but the engine's
   notes put `heart_rate` and `hrv_rmssd` in different groups. A shared group (e.g. `optical_pulse`) would make
   co-deviating HR and HRV count as one group. That is the more conservative choice.
5. **New fields.** New fields with defaults and tolerant decoding:
   - `ReferenceComparison`: `transformedCenter`, `centerUncertaintyMethod`, `estimator`, `parentSupportDays`.
   - `ChangeEpisode`: `detector`, `alarmDay`, `detectionDelayDays`, `supportDays`, `occurrences`, `rollingMagnitude`,
     `frozenMagnitude`, `medianRollingZ`, `medianFrozenZ`, `frozenReferenceId`, `trendPerWeek`, `trendDays`,
     `peakStatistic`, `units`, `transform`.
   - `MultiSignalSummary`: `components`.
   - New types: `ScaleFloor`, `DependenceComponent`.
6. **App copy.** Present `robustZ` as "typical-spread units" (never a percentile). Present `center` and
   `signedDifference` in original units. Present a frozen reference as "historical reference from <fromDay>–<toDay>",
   never "healthy baseline".
