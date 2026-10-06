# Physiology context — statistics (System F)

Owner: statistics workstream. Code: `Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyContext/`
`PCReferences.swift` (daily values, reference views), `PCChangeDetection.swift` (episodes, multi-signal),
`PCRobustStats.swift` (primitives), `PCEvaluation.swift` (synthetic evaluation harness). Tests:
`PCReferenceTests`, `PCChangeDetectionTests`, `PCEvaluationTests`, `PCEvaluationReportTests` (env-gated report),
`PCReviewStatsRegressionTests` (the independent review's findings, kept as regressions).

**Revision `pc-reference-2` / `pc-change-2`** repairs the independent review
([review-statistics.md](review-statistics.md); repairs and evidence in
[review-statistics-repairs.md](review-statistics-repairs.md)): detector burn-in (§3.1), gap-aware φ̂ with a
conservative fallback (§3.1), native-resolution scale floors (§2.2), the registered frozen reference as the authority
(§2.3), causal partial days (§2.5), dependence members for bout and functional series (§4), and
`alarmAfterStartDays` (formerly `detectionDelayDays`, §3.1). §6 and §7 hold the re-run evaluation.

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

Floors are in the series' native resolution (longest matching prefix wins). All are engineering choices.

| Series prefix | Floor | Basis |
| --- | --- | --- |
| `hrv_rmssd.`, `hrv_sdnn` | 0.05 ln (≈ 5 %) | Below half the ~12 % typical error of resting Ln rMSSD (Buchheit 2014); it binds only when the personal spread is implausibly tight |
| `resting_hr.`, `heart_rate.`, `hr_response.`, `hr_recovery_` | 1.0 bpm | Integer bpm resolution: a MAD of integer data collapses to 0 when more than half the values tie. Bout rises and post-effort declines are differences of integer-bpm readings |
| `resp_rate.` | 0.3 breaths/min | Engineering choice |
| `skin_temp.` | 0.1 °C | Engineering choice |
| `functional.bouts_per_worn_hour` | 0.25 /h | One bout in the 4 worn waking hours that admit a rate |
| `functional.locomotion_s_per_worn_hour` | 15 s/h | One 60-s minimum bout of locomotion in 4 worn waking hours |
| `functional.active_to_rest_per_min` | 0.2 /min | One transition in the 5 active minutes that admit the rate |
| `functional.pauses_per_bout_hour` | 6 /h | One pause per 10 minutes of bout time (the middle duration-band edge) |
| `functional.bout_count` | 1 | Integer count |
| `functional.locomotion_s` | 60 s | One minimum bout of locomotion |
| `functional.median_bout_s`, `functional.rest_after_bout_median_s` | 30 s | Half the 60-s minimum bout |
| `functional.cadence_steps_per_min` | 1 /min | Integer counter steps |
| `functional.cadence_within_bout_cv` | 0.01 | One percentage point |
| unlisted identity series | max(2 % of \|center\|, 1 native unit) | Conservative default (`scale_floor_default`): it can only shrink distances of a finely resolved series, and a zero-centred constant history no longer turns one count into near-infinite certainty |
| unlisted ln series | 0.05 ln | Same default as HRV (`scale_floor_default`) |

The rate floors are "one count in the minimum denominator": on a constant history of zeros a single extra count
alone reaches |z| = 1, never more. Before this revision unlisted series had `2 % · |center|` bounded only by 1e-6,
so 20 bout-free days followed by one bout in 4 hours gave z ≈ 250 000 (review R-F1); it now gives z = 1.

The sensitivity table includes resting HR at floors of 0.5, 1 and 2 bpm. At 2 bpm, 92 % of 1-bpm-SD shifts are
missed. At 0.5 bpm, null and frozen false episodes rise.

### 2.3 Frozen reference

- **Selection.** The first 14 supported days of the (series, regime) that fit within 42 calendar days, in the
  **loaded** history (the worker loads 160 days). Recorded verbatim as
  `first_14_supported_days_within_42_calendar_days_of_loaded_regime_history`.
- **Storage.** `version = 1`; id = `frz_` + FNV-1a(`series|regime|version|fromDay`); median and floored MAD scale on
  the transform scale.
- **When it registers.** Only in retrospective mode (`frozenRegistrationModes`), because storage keys frozen
  references by (series, regime, version) without the mode. Causal mode reads a stored reference and otherwise
  reports `frozen_not_registered` and `frozen_registers_in_other_mode`.
- **The registered reference is the authority.** If any reference is registered for (series, regime, version), no
  other is ever registered, whichever day is processed. It scores only days after its window: a day inside or before
  the window (for example a back-filled day) gets status `unavailable` with `frozen_window_not_complete_for_day` and
  its id. In retrospective mode the engine passes every registered reference, so a back-filled day no longer
  registers (and is scored against) a second "version 1" that the insert-only table would reject (review R-F7). If
  several are passed, the earliest selection wins deterministically.
- **Causal guard.** In causal mode a reference created for the scored day or later, or whose window ends on or after
  it, is ignored (`frozen_created_after_day_ignored`). The package no longer relies on the worker's registration-time
  filter alone (review P4).
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

### 2.5 Causal partial days

A causal (live) value of a day-accumulating series describes the day up to the cutoff: the median of the stable-awake
windows that ended before it, or a functional rate over the waking time so far. Its history holds earlier causal
values, which the worker last published at about the end of each day (whole days). Nothing records the local-time
coverage of either, so the comparison is not like for like: three morning windows at 58 bpm against a whole-day
history of about 70 bpm gave z = −7.8 from composition alone (review P2).

- **Rule.** In causal mode, parent series matching `causalPartialDaySeriesMarkers` (default `.stable_awake_` and
  `functional.`) keep their recent / rolling / frozen reference (center, scale, support) but carry no distance:
  `robustZ`, `signedDifference` and `transformedDifference` are nil, a ready status becomes provisional, and the
  reason is `partial_day_composition`. Multi-signal therefore ignores them.
- **Episodes.** Today's value of such a series does not enter that day's episodes; the series' episodes end with the
  previous supported day and carry `partial_day_value_excluded`.
- **Like-for-like view.** The stable-awake time-band strata keep their conditioned comparison: a band compares with
  the same band on earlier days. The band that contains the cutoff can itself be partial (for example 06:00–09:30
  of the 06–12 band), and the parent share of the pooled center (`1 − w`) is whole-day; both are limitations.
- **Why not compare against the same local-time slice of history.** That needs per-window coverage on the stored
  history values, which daily values do not carry. Nightly values are complete when published and bout responses
  are per-bout medians, so they are compared as before.
- **Retrospective mode** is unchanged: every value is a whole day.

## 3. Episodes

`ChangeDetection.episodes(...)` analyses every (series, regime) with a value in the trailing 90 days. Each supported
day d in the window is scored sequentially, with no look-ahead:

- `z_d` against the rolling reference of days `[d − 28, d − 1]` (exactly the `rolling` view's estimator, so the
  episode z equals the comparison z shown on the envelope);
- `z_d` against the frozen reference (days after its selection only).

Missing days are skipped, never zero-filled. A gap of more than 7 days resets the detectors (`gap_reset`). A regime
boundary inside the series also resets them (`split_at_regime_boundary`), so an episode never spans a boundary. A
reset that falls on a day without a detector score carries to the next detector day, so the detectors never bridge
it. Strata do not get episodes (`episodesForStrata = false`).

**Burn-in (review R-F2).** A scored day enters the detectors (CUSUM, persistence rule, transient and recurring
excursions) only when the loaded history of its (series, regime, mode) began at least `detectorMinLookbackDays = 28`
calendar days earlier, i.e. when its whole rolling window lies inside the loaded history. Earlier days keep their
display distance (the comparison and `medianRollingZ` use it) but feed nothing; every entry of such a window carries
`detector_burn_in`, and `starts_at_window_start` refers to the first detector day. The same rule covers a new user, a
new regime and a truncated history load. The evaluation discards the first 35 days of every synthetic series, so it
measures exactly the post-burn-in regime.

**History load.** The episode window needs `windowDays + autocorrelationGuardDays + autocorrelationWindowDays`
= 90 + 14 + 56 = 160 days of history for every scored day to have its full rolling and φ̂ lookback. With the
worker's 160-day load a long-running series' document is *identical* to the full-lookback (evaluated) path
(`testWorkerHistoryLoadReproducesTheEvaluatedFullLookbackPath`, `evaluateDocuments`, §6). With the earlier 90-day
load the first 28 days of the window are burn-in and the next 6 use the fallback φ; that only removes detector days.

### 3.1 Detectors

**Default: autocorrelation-adjusted two-sided CUSUM on the daily robust z.**

`S_t = min(cap, max(0, S_{t−1} + dir · c(z_t) / a_t − k))`, where:

- **Clamp.** `c(z)` clamps z to ±2. One extreme day then contributes at most (2 − 0.25)/7 ≈ 25 % of the evidence an
  alarm needs.
- **Autocorrelation adjustment.** `a_t = sqrt((1 + φ̂)/(1 − φ̂))` is the AR(1) long-run SD factor. φ̂ is a robust
  lag-1 autocorrelation of consecutive supported days: MAD-scaled deviations winsorized at ±3, clamped to [0, 0.8],
  at least 20 pairs.
  - **Gap-aware pairs.** A pair is two consecutive supported days at most `maxGapDays` (7) apart: the steps the
    CUSUM takes without a reset. φ̂ is thus the lag-1 autocorrelation of the sequence the CUSUM actually runs on.
    With days missing at random, AR(1) days observed with gaps are again AR(1)-correlated with coefficient
    E[φ^gap] (independent gaps multiply), so the long-run factor stays the right one. For a dense series nothing
    changes. Before this revision only calendar-consecutive pairs counted, so a sparse series had no φ̂ at all and
    ran unadjusted (review R-F9).
  - **Fallback.** When fewer than 20 pairs exist (the first days after the burn-in, or a very sparse series) the
    CUSUM uses `autocorrelationFallback = 0.5`, the largest φ the evaluation covers, with
    `autocorrelation_assumed_conservative` on the run and on the status entry. It over-corrects any smaller true φ:
    fewer false episodes, later detection. "No adjustment", the earlier behaviour, was the most liberal choice.
  - φ̂ is estimated on days d−69…d−14. The 14-day guard band stops a fresh change from inflating its own φ̂.
  - Without the adjustment, autocorrelated days count as independent evidence and false episodes multiply with φ
    (research note 8; §6).
- **Parameters.** k = 0.25 and h = 7 in long-run SD units; cap = 1.25·h.
- **Episode shape.**
  - A run (S > 0) becomes a `persistent_shift` once S > h, and stays ongoing while S > h.
  - `startDay` is the first day of the run, the standard CUSUM change-point estimate. With a small k it can precede a
    real step by several days.
  - `alarmDay` is the first day S > h. `alarmAfterStartDays` is the calendar days from `startDay` to `alarmDay`. It
    is **not** a detection delay: the true change day is unknown and the start estimate can precede it. The
    evaluation's delay is alarm − true step; §6 reports both (review P9; the field was `detectionDelayDays`, and the
    old key still decodes).
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
| `usual_variation` | Status entry: ≥ 7 detector days (scored, past the burn-in) in the window and no ongoing non-usual episode; it starts at the first detector day |
| `insufficient_evidence` | Status entry: < 7 detector days (`too_few_supported_days`, plus `no_reference` when nothing could be scored and `detector_burn_in` when the days were burn-in) |

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
to the first detector day of the window carries `starts_at_window_start`. Nothing is called disease progression.
Nothing notifies.

## 4. Multi-signal dependence

`ChangeDetection.multiSignal(...)` takes today's `rolling` comparisons that are ready or provisional with
|z| ≥ 2.5 (strata excluded) and builds dependence groups:

1. **Map each series to members** (`ChangeDetection.dependenceMembers`): its metric (the input it is computed from)
   plus the selection it shares.

   | Series | Members | Why |
   | --- | --- | --- |
   | `*.sleep_night` | metric, `sleep_detector`, `sleep_wake` | The sleep detector (gravity stillness confirmed by HR) selects the night |
   | `*.stable_awake*` | metric, `eligibility_stillness`, `sleep_detector`, `sleep_wake`, `wear_state` | Strap-motion stillness plus the awake-and-worn gate (sleep / wake detector, heart-signal wear) |
   | `hr_response.*`, `hr_recovery_<s>s.*` | `heart_rate`, `exertion_bouts` | HR around strap-motion bouts (review R-F3: the recovery series was undeclared) |
   | `functional.*` | `functional_features`, `sleep_detector`, `sleep_wake`, `wear_state` | Every functional value needs ≥ 4 worn waking hours, and the per-worn-hour / waking-time rates divide by them: waking time subtracts the HR-confirmed sleep episodes and wear reads heart-signal presence (review R-F4) |

   The metric `heart_rate` belongs to the engine's `heart_rate` and `optical_pulse` groups, so every HR-derived
   series (stable-awake HR, bout rises, post-effort declines) is connected with HR, resting HR, HRV and respiratory
   rate. A test fails when any series key the engine emits maps to no declared group.
2. **Assign groups.** Each series gets every `DependenceNote.group` whose members intersect its own.
3. **Connect.** Series that share any group are connected (union-find).

With the engine's notes nearly every pair of series now shares a declared input, so `independentGroupCount` is
usually 1. That is the conservative reading of the inputs: the sleep detector, heart-signal wear and the optical
pulse feed almost everything.

`independentGroupCount` is the number of connected components. It is an upper bound on independent lines of evidence,
not proof of independence (`distinct_groups_not_proven_independent`).

Reasons:

- `shared_inputs_not_independent` when a component holds more than one series. HRV and respiratory rate share
  `beat_intervals` → one group (V13).
- `selection_reads_heart_rate` for series whose selection reads the sleep detector (nightly, stable-awake and
  functional series).
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
   (V10 tests); causal mode also ignores frozen references created for the day or later (§2.3). Real replays must
   also check that late-arriving values change only documents built after their availability.
   - **The evaluated path is the document path.** §6 builds one document per null series through the public
     `ChangeDetection.episodes` from the history a worker loads (90 or 160 days) and from the whole series. With the
     160-day load the document equals the full-lookback path that the per-week rates measure.
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
    - The synthetic evaluation covers missing-at-random days only (30 %, 50 %, 70 %). Informative missingness (e.g. no stable
      awake rest on days the person is unwell) is **not** evaluated and would bias references toward good days. It
      must be checked on real data by relating exclusion to symptoms and exposures.

## 6. Evaluation results

Produced by `PC_EVAL_REPORT=1 swift test --filter PCEvaluationReportTests` in `Packages/StrandAnalytics` (seed
20261005, 400 replicates per cell, 200 in the sensitivity table, 500 bootstrap resamples). Re-run for
`pc-change-2` / `pc-reference-2` on branch `pc/fix-stats`: 2 284 s wall-clock in a debug build on a heavily loaded
machine (load average ≈ 90 on 16 cores; earlier runs without the document-path table took 62–162 s). The output is
deterministic. The synthetic RMSSD spec is 45 ms with SD 0.12 on the ln scale. The resting-HR spec is 55 bpm with SD
1.2 bpm, rounded to integer bpm. "SD" means the marginal SD of the synthetic daily noise. **Synthetic arithmetic
checks only.**

**What changed against `pc-change-1`** (the earlier tables, same seed):

- Dense null rates are unchanged within sampling error (0.029 / 0.029 / 0.021 per series-week at φ = 0 / 0.3 / 0.5,
  was 0.030 / 0.030 / 0.022). The share of series with an alarm in their first 90 monitored days fell (30 / 34 / 27 %,
  was 33 / 38 / 31 %): those days include the start of each series, now covered by the burn-in and the fallback φ.
- 30 % missing: gap-aware φ̂ no longer over-corrects. 2-SD misses fell from 21 % to 18 %, 1-SD misses from 59 % to
  57 %, at the same null rate (0.021, was 0.022).
- New rows: 50 % and 70 % missing (R-F9), start-up included, the document path (R-F2), a 2-SD step at 50 % missing,
  and the documents' `alarmAfterStartDays` next to the true delay (P9).
- Step, drift, artifact, recent-window, ARL, MAD-factor and sensitivity rows moved by at most 1–2 points (resting HR
  default 0.011 per week, was 0.013).

**Null (no change), default policy, nightly ln RMSSD spec, 400 days, counted after day 35.** Rates per series-week,
95 % stationary-bootstrap interval (mean block 4 weeks). Before this revision, the review measured 0.050 per week
(0.046–0.054) at φ = 0.5 with 50 % missing (no φ̂, so no adjustment; seed 99173).

| φ | missing | CUSUM persistent / wk | persistence-rule / wk | frozen persistence / wk | excursions / wk | recurring / wk | ≥1 CUSUM alarm in 90 d |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0.0 | 0 % | 0.029 (0.027–0.032) | 0.011 (0.009–0.013) | 0.006 (0.005–0.007) | 0.166 (0.159–0.174) | 0.037 (0.035–0.040) | 30 % |
| 0.3 | 0 % | 0.029 (0.027–0.032) | 0.025 (0.022–0.027) | 0.020 (0.018–0.022) | 0.161 (0.154–0.167) | 0.035 (0.033–0.037) | 34 % |
| 0.5 | 0 % | 0.021 (0.020–0.023) | 0.044 (0.040–0.046) | 0.043 (0.040–0.047) | 0.160 (0.154–0.166) | 0.032 (0.030–0.034) | 27 % |
| 0.3 | 30 % | 0.021 (0.019–0.023) | 0.020 (0.018–0.022) | 0.008 (0.007–0.010) | 0.148 (0.142–0.154) | 0.029 (0.027–0.031) | 22 % |
| 0.0 | 50 % | 0.010 (0.009–0.012) | 0.012 (0.010–0.013) | 0.003 (0.002–0.003) | 0.147 (0.141–0.154) | 0.028 (0.026–0.031) | 8 % |
| 0.3 | 50 % | 0.013 (0.011–0.014) | 0.021 (0.019–0.022) | 0.006 (0.005–0.008) | 0.147 (0.141–0.153) | 0.028 (0.026–0.030) | 13 % |
| 0.5 | 50 % | 0.011 (0.010–0.013) | 0.025 (0.022–0.027) | 0.014 (0.012–0.016) | 0.141 (0.136–0.146) | 0.022 (0.020–0.024) | 9 % |
| 0.5 | 70 % | 0.000 (0.000–0.000) | 0.010 (0.008–0.011) | 0.004 (0.003–0.005) | 0.101 (0.096–0.106) | 0.012 (0.011–0.014) | 0 % |

At 50 % missing the rate per *scored* day (0.010–0.013 per week over about 3.5 scored days) is at or below the dense
rate per scored day (0.021–0.029 over 7). At 70 % missing the 28-day reference rarely holds 7 days and φ̂ is rarely
estimable: the CUSUM is effectively silent (see the limitations).

**Start-up included (counted from day 0, burn-in and fallback φ in force), 400 days.** The start-up adds no false
episodes: its first 28 days feed no detector.

| φ | missing | CUSUM persistent / wk | excursions / wk | ≥1 CUSUM alarm in the first 90 d |
| --- | --- | --- | --- | --- |
| 0.0 | 0 % | 0.027 (0.025–0.029) | 0.157 (0.150–0.164) | 16 % |
| 0.3 | 0 % | 0.027 (0.025–0.029) | 0.151 (0.145–0.157) | 21 % |
| 0.5 | 0 % | 0.019 (0.018–0.021) | 0.150 (0.145–0.156) | 16 % |

**Document path (R-F2).** One document on day 300 of a null series, built by the public `ChangeDetection.episodes`
(90-day window) from the history a worker loads. Cells: share of documents with ≥ 1 CUSUM persistent shift / CUSUM
persistent shifts per document / share of the window's scored days that entered the detectors. With the 160-day load
the document is the full-lookback path exactly. Before the burn-in the review measured, for the 90-day load, 0.43 /
0.66 / 0.82 episodes per document at φ = 0 / 0.3 / 0.5 against 0.38 / 0.35 / 0.21 with full lookback (seed 4242001).

| φ | missing | 90-day load | 160-day load (worker) | full lookback (evaluated path) |
| --- | --- | --- | --- | --- |
| 0.0 | 0 % | 18 % / 0.19 / 75 % | 31 % / 0.35 / 100 % | 31 % / 0.35 / 100 % |
| 0.3 | 0 % | 20 % / 0.21 / 75 % | 30 % / 0.32 / 100 % | 30 % / 0.32 / 100 % |
| 0.5 | 0 % | 17 % / 0.19 / 75 % | 20 % / 0.22 / 100 % | 20 % / 0.22 / 100 % |
| 0.3 | 50 % | 4 % / 0.05 / 81 % | 12 % / 0.13 / 100 % | 12 % / 0.13 / 100 % |

**Sustained step down at day 70, horizon 28 days.** Delay in days from the step among detected series; 95 % percentile
bootstrap over replicates. "Detected" includes series already in a same-direction alarm at the step (no delay).
"Document `alarmAfterStartDays`" is what an episode reports: alarm minus the CUSUM's own start estimate, which on
precedes the step: the two medians differ by 2–6 days. It is not the delay.

| φ | step | missing | CUSUM missed | CUSUM delay median (CI) | p25–p75 / p90 | document alarmAfterStartDays median | persistence-rule missed / median | frozen-rule missed / median | rolling adapted by +42 d | frozen still ≥ 2 at +42 d |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.0 | -1 SD | 0 % | 26 % (0.21–0.30) | 9.0 (9.0–10.0) | 6–14 / 19 | 13.0 | 86 % / 6.0 | 82 % / 11.5 | 96 % | 10 % |
| 0.0 | -2 SD | 0 % | 0 % (0.00–0.00) | 5.0 (5.0–5.0) | 4–6 / 8 | 7.0 | 54 % / 3.0 | 33 % / 6.0 | 96 % | 49 % |
| 0.3 | -1 SD | 0 % | 47 % (0.42–0.52) | 10.0 (9.0–11.3) | 7–14 / 20 | 13.0 | 78 % / 6.0 | 73 % / 10.0 | 92 % | 16 % |
| 0.3 | -2 SD | 0 % | 5 % (0.03–0.07) | 7.0 (6.0–7.0) | 5–10 / 14 | 10.0 | 48 % / 3.0 | 29 % / 6.0 | 92 % | 50 % |
| 0.5 | -1 SD | 0 % | 63 % (0.58–0.68) | 11.0 (9.0–12.0) | 7–15 / 21 | 14.0 | 68 % / 5.0 | 66 % / 10.0 | 83 % | 18 % |
| 0.5 | -2 SD | 0 % | 21 % (0.17–0.25) | 8.0 (8.0–9.0) | 6–12 / 15 | 12.0 | 39 % / 3.0 | 23 % / 6.0 | 83 % | 53 % |
| 0.3 | -1 SD | 30 % | 57 % (0.53–0.62) | 11.0 (10.0–13.0) | 6–17 / 22 | 17.0 | 84 % / 7.0 | 78 % / 11.0 | 87 % | 14 % |
| 0.3 | -2 SD | 30 % | 18 % (0.14–0.22) | 8.0 (8.0–9.0) | 5–12 / 16 | 14.0 | 60 % / 4.0 | 34 % / 9.0 | 87 % | 52 % |
| 0.3 | -2 SD | 50 % | 47 % (0.42–0.52) | 11.0 (10.0–12.0) | 7–16 / 20 | 16.0 | 68 % / 6.0 | 38 % / 12.0 | 79 % | 47 % |

**Gradual drift down (0.05 SD/day for 60 days = 3 SD), read through `ChangeDetection.episodes` on the last day.**
The reported trend is the Theil–Sen slope over the 90-day window, which includes 30 flat days, so a ratio below 1 is
expected.

| φ | median rolling z (last 7 d) | median frozen z (last 7 d) | ongoing persistent shift | of which frozen-sourced | CUSUM alarmed during drift | reported trend / true trend |
| --- | --- | --- | --- | --- | --- | --- |
| 0.0 | -0.66 | -2.96 | 92 % | 8 % | 96 % | 0.78 |
| 0.3 | -0.70 | -3.06 | 87 % | 18 % | 93 % | 0.80 |
| 0.5 | -0.67 | -3.07 | 81 % | 38 % | 77 % | 0.79 |

**Isolated artifact (one day +8 SD at day 80), paired with the same series without it.** At φ = 0 the artifact raises
CUSUM alarms within 14 days slightly: 2000-replicate re-checks give 7.4 vs 6.2 % (seed 20261005) and 7.0 vs 5.0 %
(seed 31337); at φ = 0.3 6.2 vs 6.2 % and 5.9 vs 6.4 % (review P8).

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
| default: AR-adjusted CUSUM k=0.25 h=7, clamp 2, rolling 28 d median/MAD | 0.030 (0.027–0.033) | 0.022 | 47 % | 10.0 | 4 % | 6.5 |
| AR-adjusted CUSUM k=0.25 h=6 | 0.050 (0.046–0.054) | 0.022 | 32 % | 9.0 | 2 % | 5.0 |
| AR-adjusted CUSUM k=0.25 h=8 | 0.017 (0.015–0.019) | 0.022 | 58 % | 11.0 | 12 % | 7.0 |
| AR-adjusted CUSUM k=0.5 h=5 | 0.015 (0.012–0.017) | 0.022 | 76 % | 8.0 | 25 % | 6.0 |
| AR-adjusted CUSUM clamp 3 | 0.047 (0.043–0.051) | 0.022 | 36 % | 9.0 | 3 % | 5.0 |
| unadjusted CUSUM k=0.25 h=7 | 0.103 (0.098–0.108) | 0.022 | 10 % | 7.0 | 0 % | 4.0 |
| unadjusted classic CUSUM k=0.5 h=4, no clamp | 0.176 (0.170–0.182) | 0.022 | 11 % | 5.0 | 1 % | 2.0 |
| AR-adjusted, no autocorrelation guard band | 0.028 (0.025–0.031) | 0.022 | 53 % | 10.0 | 16 % | 7.0 |
| persistence 3 of 5, abs z ≥ 2 | 0.023 (0.020–0.026) | 0.022 | 77 % | 6.0 | 50 % | 3.0 |
| persistence 4 of 7, abs z ≥ 2 | 0.008 (0.006–0.010) | 0.022 | 88 % | 7.0 | 62 % | 4.0 |
| persistence 3 of 5, abs z ≥ 2.5 | 0.005 (0.004–0.007) | 0.022 | 94 % | 6.0 | 76 % | 3.0 |
| rolling 14 d (min 7) | 0.020 (0.018–0.023) | 0.022 | 77 % | 8.0 | 34 % | 6.0 |
| rolling 42 d | 0.033 (0.029–0.036) | 0.022 | 34 % | 11.0 | 1 % | 6.0 |
| winsorized mean/SD reference | 0.021 (0.018–0.023) | 0.022 | 47 % | 10.0 | 6 % | 7.0 |
| no small-sample MAD factor | 0.033 (0.030–0.036) | 0.027 | 45 % | 9.5 | 3 % | 6.0 |
| frozen rule abs z ≥ 1.5, 5 of 7 | 0.030 (0.027–0.033) | 0.057 | 47 % | 10.0 | 4 % | 6.5 |
| resting HR (integer bpm), floor 1 bpm (default) | 0.011 (0.009–0.013) | 0.016 | 66 % | 10.0 | 8 % | 7.0 |
| resting HR, floor 0.5 bpm | 0.016 (0.014–0.019) | 0.036 | 62 % | 10.0 | 7 % | 7.0 |
| resting HR, floor 2 bpm | 0.000 (0.000–0.001) | 0.000 | 92 % | 12.0 | 32 % | 10.0 |

**Reviewer re-checks (current code).** `REVIEW_PRINT=1 swift test --filter PCReviewStatsRegressionTests`:

| Check | Review (`pc-change-1`) | Now |
| --- | --- | --- |
| Null CUSUM / wk, φ = 0.5, dense (seed 99173, 200 reps) | 0.024 | 0.024 (0.021–0.026) |
| Null CUSUM / wk, φ = 0.5, 50 % missing | 0.050 (0.046–0.054) | 0.012 (0.010–0.015) |
| Null CUSUM / wk, φ = 0.3, 50 % missing | 0.030 | 0.012 (0.010–0.014) |
| 2-SD step missed, φ = 0.5, 2000 reps (seed 20261005 / 31337) | 22.8 / 23.7 % | 23.1 / 24.2 % |
| 1-SD step missed, φ = 0.5, 2000 reps | 62.9 / 66.3 % | 63.5 / 66.7 % |
| 2-SD step missed, φ = 0.3, 2000 reps | 4.6 / 5.4 % | 4.7 / 5.5 % |
| 90-day load vs full lookback, φ = 0.3, 300 reps: documents with ≥ 1 CUSUM episode | 55 % vs 31 % (400 reps) | 21.7 % vs 29.7 % |
| Episodes starting before D−56 (cold start), same run | 180 of 262 | 5 of 68 |

Development sweeps used other seeds (100 replicates) over:

- estimator (median/MAD, winsorized);
- rolling window 28 / 42 / 56;
- (k, h) ∈ {(0.5, 4–8), (0.75, 4–5), (0.25, 6–10), (0.3, 6), (0.35, 6–6.5), (0.4, 6)};
- clamp 2 / 2.5 / 3;
- autocorrelation adjustment on/off and guard band 0 / 14;
- frozen rule z ∈ {1.5, 2} × {4, 5} of 7.

Only the configurations above are reported with the final seed. The repair added no tuned threshold: the burn-in
(28 days = the rolling window) and the fallback (0.5 = the largest evaluated φ) are fixed by the design, not by
sweeps.

## 7. Choice of defaults

**The defaults are unchanged by the re-run** (§6: the dense cells moved by at most 1–2 points). The repair adds
three design constants, none tuned on the evaluation:

- **Burn-in 28 days** (`detectorMinLookbackDays`): the rolling window, so a detector day always has its whole
  reference loaded. It costs the first 28 days of a new series and adds no false episodes (start-up table: 0.027 per
  week from day 0 against 0.029 after day 35). Requiring the full 70-day φ̂ lookback instead would idle a new series
  for 70 days to replace a conservative fallback that is in force for only 6 of them.
- **Gap-aware φ̂** (pairs ≤ 7 days apart): the autocorrelation of the sequence the CUSUM runs on. It changes nothing
  for dense series and improves 30 %-missing detection (2-SD misses 21 % → 18 %) at the same null rate.
- **Fallback φ = 0.5** when φ̂ has < 20 pairs: the largest evaluated φ, conservative for every smaller one. With it
  a clamped day adds at most 2/√3 − 0.25 ≈ 0.90 to S, so h = 7 is reachable in 8 days, before a dense 28-day
  reference absorbs a step (about 14 days). `autocorrelationMax` = 0.8 (factor 3) would allow at most 0.42 per day,
  17 days: no step would ever alarm while the fallback holds. "No adjustment", the earlier behaviour, doubled the
  50 %-missing false rate (0.050 vs 0.024 dense).

The earlier choices:

- **CUSUM over the persistence rule.** At a similar null rate (~0.02–0.03 per series-week at φ = 0.3), the
  persistence rule (3 of 5, |z| ≥ 2) misses 50 % of 2-SD steps within 28 days. The CUSUM misses 4–5 %. Stricter
  persistence rules are quieter but miss most steps. The persistence rule stays computed as the comparison
  (`alternative_detector_*`). The rule has no autocorrelation adjustment (null 0.011 → 0.044 per week from φ = 0 to
  0.5), so the comparison is not at matched null rates for each φ (review P7); the conclusion holds at φ = 0.3, where
  the rates are similar (0.025 vs 0.029).
- **Autocorrelation adjustment.** Without it, false episodes depend on the unknown day-to-day autocorrelation:
  unadjusted k = 0.25, h = 7 gives 0.103 per week at φ = 0.3; the classic k = 0.5, h = 4 gives 0.176 per week
  (≈ 6 per series-year). With it, the rate is 0.021–0.029 at every dense φ tested, and 0.010–0.013 at 50 % missing.
  - The price is sensitivity on autocorrelated series: a 1-SD step is missed 47–63 % of the time at φ = 0.3–0.5.
    Autocorrelated days carry less independent information.
  - The guard band (φ̂ from days 14–69 before) cuts 2-SD misses from 16 % to 4 % at no false-rate cost.
  - **Sparse series lose sensitivity, not specificity.** At 50 % missing a 2-SD step is missed 47 % of the time
    (18 % at 30 %): the 28-day reference holds about 14 days and absorbs a step within about 7 of them. At 70 %
    missing the CUSUM is effectively silent. The frozen rule (38 % missed at 50 %) and the transient view still
    show such changes. A reference window counted in supported days rather than calendar days would help; it is not
    evaluated here and would change the cross-day horizon.
- **k = 0.25, h = 7, clamp 2.**
  - Under an adaptive 28-day reference, a real step's z decays as the median absorbs it. A small k integrates the
    decaying evidence: k = 0.5, h = 5 at a lower false rate misses 25 % of 2-SD steps.
  - h = 7 sets ≈ 0.03 false episodes per series-week (≈ 1.5 per series-year; about 1 in 3 documents shows one in
    its 90-day window: 30–31 % at φ = 0–0.3, 20 % at φ = 0.5, document-path table). This is a descriptive summary with magnitudes and reasons, not an alarm. h = 8 cuts the false rate by
    about 40 % and triples 2-SD misses.
  - Clamp 2 bounds one day's contribution. With clamp 3 the false rate rises to 0.047. In the development sweeps
    (100 replicates, so noisy) clamp 3 showed more persistent alarms within 14 days of a +8 SD artifact than without
    one (14 % vs 6 % at φ = 0.3). With clamp 2 the final run shows no difference at φ = 0.3 (6 % with vs 6 %
    without); at φ = 0 the 2000-replicate re-checks show a small increase (7.4 vs 6.2 % and 7.0 vs 5.0 %, review
    P8).
- **Rolling 28 days, median / MAD.** These are the spec's and the research notes' transparent defaults, inside the
  28-day cross-day invalidation horizon (contracts §6).
  - 42 days would detect 1-SD steps better (34 % missed vs 47 %) at a similar false rate. It would make comparisons
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
- **Missingness.** It was evaluated only as missing at random (0–70 % of days). Informative missingness and
  eligibility-driven selection bias are not evaluated (§5 item 10). Nightly HR-derived series are selected by a
  sleep detector that reads HR level (review P1); that target-dependent selection is declared, not evaluated.
- **Fallback φ.** `autocorrelationFallback = 0.5` covers true φ ≤ 0.5. A very sparse series whose true observed-day
  autocorrelation exceeds 0.5 would be under-corrected; with gaps the observed-day autocorrelation is E[φ^gap], well
  below φ, so this needs φ > 0.7 with mostly consecutive days, where φ̂ is estimable anyway.
- **Burn-in.** A new series (user, regime or device) has no detector output for its first 28 days, and uses the
  fallback φ until φ̂ has 20 pairs (about day 34 for a dense series). The start-up row of §6 shows that this adds no
  false episodes; it delays the first possible detection.
- **Causal partial days.** Causal stable-awake and functional parents carry no distance (§2.5). The like-for-like
  view is the time-band stratum, whose cutoff band can itself be partial. Causal frozen comparisons use references
  registered from retrospective values (review P3, open).
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
| `scale_floor_default` | No series-specific floor is listed; the default rule applied (§2.2) |
| `frozen_window_not_complete_for_day` | A registered frozen reference exists but its window does not end before the day: no frozen comparison, no second registration |
| `frozen_created_after_day_ignored` | Causal mode ignored a frozen reference created for the day or later |
| `partial_day_composition` | Causal value of a day-accumulating series: reference shown, no distance (§2.5) |
| `detector_burn_in` | Some days of the window were scored for display only (before 28 days of loaded history) |
| `autocorrelation_assumed_conservative` | φ̂ was not estimable; the CUSUM used φ = 0.5 |
| `partial_day_value_excluded` | Causal partial-day value left out of the episodes |

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
| R-F2 burn-in / history load | `PCChangeDetectionTests.testColdStartDaysAreScoredForDisplayButDoNotFeedTheDetectors`, `testWorkerHistoryLoadReproducesTheEvaluatedFullLookbackPath`; `PCEvaluationTests.testDocumentsBuiltFromTheWorkerHistoryLoadShowTheEvaluatedPath`; `PCReviewStatsRegressionTests.testReviewNinetyDayHistoryLoadInflatesFalseEpisodesVersusEvaluatedPath` | Burn-in days feed nothing; 160-day load ≡ full lookback; 90-day load never adds false episodes |
| R-F9 sparse φ̂ | `PCChangeDetectionTests.testMissingAutocorrelationEstimateUsesTheConservativeFallbackNotNoAdjustment`; `PCEvaluationTests.testSparseSeriesAndStartUpKeepTheNullRateBounded` | Gap-aware φ̂, fallback √3 factor, bounded sparse and start-up null rates |
| R-F1 floors (V12 count cases) | `PCReferenceTests.testCountAndRateSeriesGetNativeResolutionFloorsNotMicroscopicOnes`; review tests `testReviewZeroCenteredFunctionalSeriesMustNotGetMicroscopicScaleFloor`, `testReviewRecoverySeriesGetsTheIntegerBpmFloor` | One count on a zero history: \|z\| = 1 |
| R-F3 / R-F4 (V13) | `PCChangeDetectionTests.testEverySeriesKeyTheEngineEmitsMapsToADeclaredDependenceGroup`, `testOnlySeriesWithoutSharedDeclaredInputsCountAsSeparateGroups`; review tests `testReviewRecoverySeriesSharesHeartRateWithStableAwakeHeartRate`, `testReviewFunctionalRatesShareTheSleepDetectorWithNightlySeries` | No undeclared series; recovery + HR = 1 group; nightly HRV + functional = 1 group |
| R-F7 / P4 frozen authority | `PCReferenceTests.testRegisteredFrozenReferenceIsTheAuthorityAndBackfilledDaysNeverRegisterAnother`; review tests `testReviewBackfilledDayUsesTheSameFrozenReferenceAsLaterDays`, `testReviewCausalCompareRejectsFrozenReferenceCreatedAfterTheDay` | No second "version 1"; causal ignores later references |
| P2 causal partial day | `PCReferenceTests.testCausalPartialDayAccumulatingValuesCarryNoDistance`; `PCChangeDetectionTests.testCausalPartialDayValueStaysOutOfTheEpisodes`; review test `testReviewCausalPartialDayStableAwakeValueIsComparedLikeForLike` | No distance, no episode input; strata and nightly unaffected |

## 11. Commands and results

All commands were run in `Packages/StrandAnalytics` on branch `pc/fix-stats` (from `204ea2c3`).

| Command | Result |
| --- | --- |
| `swift build --build-tests` | OK |
| `swift test --filter "PCReference\|PCChange\|PCEvaluation\|PCReviewStats"` | 21 + 20 + 11 + 12 tests; the report and the two review print tests are skipped unless `PC_EVAL_REPORT=1` / `REVIEW_PRINT=1`; one failure, `testReviewRepresentedShareReflectsWhatEntersReferences` (R-F8, signal workstream) |
| `PC_EVAL_REPORT=1 swift test --filter PCEvaluationReportTests` | Tables in §6, 2 284 s on a loaded machine. Optional `PC_EVAL_REPLICATES`, `PC_EVAL_SENS_REPLICATES`, `PC_EVAL_SEED`, `PC_EVAL_OUT=<path>` |
| `REVIEW_PRINT=1 swift test --filter PCReviewStatsRegressionTests` | Re-check table in §6 (the 2000-replicate test takes about 11 minutes in debug) |
| `swift test --parallel` | 2 804 tests; 4 failures, none in System F: `testReviewRepresentedShareReflectsWhatEntersReferences` (R-F8, signal workstream) and the contract review's `testRC05_…`, `testRC06_…`, `testRC11_…` (eligibility, bout and functional workstreams; confirmed defects in review-contract.md, failing by design at `204ea2c3`) |

## 12. Requests to the lead

1. **Cross-day horizon.** Comparisons depend on 28 days (rolling, conditioned child) and 7 days (recent), all inside
   the 28-day `history_changed` cascade. Episodes depend on 90 days of values plus the 70-day lookback of their
   first scored day (rolling 28 and φ̂ on d−69…d−14), hence the 160-day history load. Only the latest day's episode
   view is stored, and it is rebuilt with each new day, so stale episodes self-correct on the next day's run. Please
   keep the cascade at ≥ 28 days if any window grows, and keep the worker's load at
   `windowDays + autocorrelationGuardDays + autocorrelationWindowDays` (160) if any of them changes.
2. **Series keys.** Please add the stratum keys `<stable-awake series>.band_HH_HH` (`hrv_rmssd.stable_awake_5min.band_06_12`,
   …), `hrv_sdnn_index.sleep_night`, `heart_rate.sleep_night`, `hrv_sdnn.stable_awake_5min` and
   `hr_recovery_60s.<activity kind>` to the contracts §5 table. They persist through
   `physiology_context_daily_values` like any other series; no schema change.
3. **Versions.** `ReferenceConfig.version` is now `pc-reference-2` and `ChangeConfig.version` `pc-change-2`
   (contracts §13). The policy fingerprint changes, so every document is rebuilt.
4. **Renamed field.** `ChangeEpisode.detectionDelayDays` is now `alarmAfterStartDays` (JSON `alarm_after_start_days`);
   the old key still decodes. No app, API or worker code reads it today.
5. **New fields and types.** With defaults and tolerant decoding: `ReferenceComparison`: `transformedCenter`,
   `centerUncertaintyMethod`, `estimator`, `parentSupportDays`. `ChangeEpisode`: `detector`, `alarmDay`,
   `alarmAfterStartDays`, `supportDays`, `occurrences`, `rollingMagnitude`, `frozenMagnitude`, `medianRollingZ`,
   `medianFrozenZ`, `frozenReferenceId`, `trendPerWeek`, `trendDays`, `peakStatistic`, `units`, `transform`.
   `MultiSignalSummary`: `components`. Types: `ScaleFloor`, `DependenceComponent`. Config: `ReferenceConfig`
   `causalPartialDaySeriesMarkers`, `defaultAbsoluteFloor`; `ChangeConfig` `detectorMinLookbackDays`,
   `autocorrelationFallback`.
6. **Methods page.** methods.md §7 (floors, detector row), §9 (dependence members) and §12.1 (numbers) should follow
   §2.2, §3.1, §4 and §6 here.
7. **Causal coverage (optional).** If the engine marked causal daily values built before the day end (for example
   a `day_incomplete_at_cutoff` reason, or the cutoff's local time), complete-day causal values could keep their
   distance and partial ones could be compared against the same local-time slice. Until then §2.5 applies.
8. **Dependence notes (optional).** The sleep detector is a gravity-stillness spine; adding `sleep_detector` to the
   `strap_motion` note would declare that link directly. Today it is reached through the series members (§4).
9. **App copy.** Present `robustZ` as "typical-spread units" (never a percentile). Present `center` and
   `signedDifference` in original units. Present a frozen reference as "historical reference from <fromDay>–<toDay>",
   never "healthy baseline". A comparison with `partial_day_composition` has a reference but no difference.
