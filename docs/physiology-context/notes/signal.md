# Signal validity, regime, motion evidence and eligibility (Systems A and B)

Workstream: signal & eligibility. Branch `pc/signal` (from contract commit `71dce34a`).
Files: `PhysiologyContext/PCSignalValidity.swift`, `PCMotionEvidence.swift`, `PCEligibility.swift`; tests
`PCSignalFixtureTests.swift`, `PCSignalSanitizeTests.swift`, `PCSignalValidityTests.swift`, `PCSignalRegimeTests.swift`,
`PCMotionEvidenceTests.swift`, `PCEligibilityTests.swift`. Versions `pc-validity-1`, `pc-motion-1`, `pc-eligibility-1`.
Every public skeleton signature is unchanged. Additions: config fields (all defaulted, all in `Policy.fingerprint`),
`MotionBasis`, `StrapMotionEvidence`, `MotionEvidence.strapEvidence`, `SelectionSummary.eligibleObservedS`
(defaulted init parameter), `SanitizedObservations.breakSeparates`, `InputContractReport.count(_:)`,
`SignalValidity.diagnostic(_:)`, `EligibilityVerdict.evidence(_:)`, `SignalValidityEngine.readWindow(_:)`.

All thresholds below are engineering defaults inherited from existing kernels or literature conventions. None has been
validated as a classifier for this layer. They verify arithmetic and integration, not physiological accuracy.

## 1. Input contract: `SignalValidityEngine.sanitize`

The engine has already removed everything not available at the causal cutoff (`Engine.causalView`). So no count
here describes data a live decision could not see (tested: `testLiveReportNeverCountsDataBeyondTheCutoff`).

Per stream (heart rate, beat intervals, motion, steps, skin temperature, wear events, band sleep states), in order:

1. **Unit / range contract.** Rows that fail are rejected as `contract_rejected`:
   - bpm outside 20–250
   - RR outside 50–30000 ms
   - skin temperature nil, non-finite or outside 0–60 °C
   - step counter outside 0–65535
   - motion: `dynAccelG` that is negative, non-finite or above the decoder's 8 g gate (`GravitySample.dynAccel`) is
     nulled (`motion.dyn_accel_contract_rejected`). A gravity vector that is non-finite or has a norm above 4 g (other
     units such as mg, or corrupt) is nulled (`motion.vector_contract_rejected`). The row is rejected only when
     neither part survives.

   Physiological plausibility is not part of the contract. It is a separate per-metric step in `assess`.
2. **Read window and future time.** Rows outside `[dayStart − 30 h, dayEnd + 6 h)` are rejected
   (`outside_read_window`). So are rows whose sensor time is more than 300 s after `generatedAt` (`future_timestamp`).
3. **Transport order.** These checks run on the input order the caller supplied.
   - An isolated spike is rejected (`timestamp_spike`). A spike is a row more than 300 s away from both neighbours
     while the neighbours are within 300 s of each other.
   - Every backward step is counted (`non_monotonic_steps`).
   - A backward step of more than 300 s between rows with the **same availability time** (one delivery) is a clock
     reset (`clock_reset_detected`). The span the two timelines then share, `[new ts, running max + 1)`, becomes a
     break.
   - A backward step between rows with different availability is a backfill, not a reset
     (`testABackfillDeliveredLaterIsNotAClockReset`).
   - Limitation: input already sorted by `ts`, as the worker's SQL reads are, cannot reveal a reset this way. In stored
     data a reset shows up as conflicting duplicates (step 4), and a cluster of those is also a break (below).
4. **Identity de-duplication.**
   - Heart rate, motion, steps, skin, wear and band sleep: the identity is `ts`. Exact duplicates collapse, keeping
     the earliest known availability. Rows with differing values under one identity are **all** rejected
     (`conflicting_duplicates_rejected`, plus `conflicting_identities`). They are never averaged.
   - Beat intervals: the identity is `(ts, rrMs, seq)`. Only identity duplicates collapse. Equal RR values with
     different `seq` are distinct beats.
5. **Ordering** (contracts.md §2). Every stream is sorted by `ts`, and all non-RR streams hold one row per `ts`. Beat
   intervals are sorted by `(ts, ord, rrMs, seq)`:
   - The known transport position `ord` comes first within a second, so beat adjacency follows the order the strap
     emitted.
   - Without `ord`, the order falls back to the identity order `(rrMs, seq)`.
   - Tested with shuffled and reversed input: `testEveryStreamIsSortedBySensorTimeWhateverTheInputOrder`.
6. **Availability accounting.**
   - `without_availability` counts kept rows that have no `availableAt`.
   - `sensor_time_after_availability` (`device_clock_ahead`) counts rows whose sensor time is more than 120 s after
     their own availability. They are kept.

Breaks are sorted and merged, and are never bridged:

- **Disconnection.** More than 60 s between consecutive timestamps of the union of HR, RR and motion. The break is
  `[last + 1, next)`, the unobserved stretch.
- **RR source-channel change** (`RRSourceChannel`, both known and different): `[p + 1, n)` when a whole second lies
  between, else the second `[n, n + 1)`.
- **Clock-reset overlap span** (step 3).
- **Overlapping timelines.** A run of conflicting HR seconds (holes up to 2 s) spanning at least 30 s
  (`overlapping_timelines_suspected`).

Adjacency rule: observations at `a ≤ b` are not adjacent when a break intersects the closed span `[a, b]`
(`SanitizedObservations.breakSeparates`).

On a whole-second axis, a source change between adjacent seconds cannot be localized finer than one second. One
neighbouring pair is given up as well (`testASourceChannelChangeSplitsAdjacency`). Losing a pair is the safe
direction.

Availability basis:

- `ingested_at` when at least one observation is kept and every kept observation has `availableAt`.
- Otherwise `sensor_time`, with `availability_basis_sensor_time` when some row lacked it.

Counts (`InputContractReport.counts`):

- `<stream>.input` and `<stream>.kept` are always present.
- These counters appear only when non-zero (absent means 0): `contract_rejected`, `outside_read_window`,
  `future_timestamp_rejected`, `timestamp_spike_rejected`, `exact_duplicates_collapsed`,
  `conflicting_duplicates_rejected`, `conflicting_identities`, `non_monotonic_steps`, `clock_resets`,
  `without_availability`, `sensor_time_after_availability`, `motion.dyn_accel_contract_rejected`,
  `motion.vector_contract_rejected`, `breaks.{disconnection,source_change,conflict_cluster,clock_reset,merged,total_s}`
  and `observations.without_availability`.

## 2. Per-metric validity: `SignalValidityEngine.assess`

Shared rules:

- Decisions are keyed on `measurement.metric`. **No gate reads the measurement value (V03).**
- Gates are evaluated exhaustively. Any `fail` makes the state `invalid`. A `degrade` turns `valid` into `degraded`. A
  `note` records an interpretation limit and does not change the state.
- Confidence is always `not_applicable`. No heuristic score is defined, so none is fabricated.
- Diagnostics are reported rounded to 1e-4. Decisions use unrounded values.
- Incident counters (`out_of_range_beats`, `ectopic_rejected`, `equal_value_same_second_beats`, `breaks_in_support`,
  `out_of_band_samples`) are omitted when zero.

### Motion share for optical metrics

The motion share is computed from the HR-independent track the engine passes in.

- It is the movement share (locomotion plus other movement in `MotionVocabulary`) of the labelled (stationary plus
  movement) seconds of the support. It needs labelled seconds of at least 10 % of the support; otherwise the reason
  is `motion_unobserved` and no state change follows.
- This denominator matches `IntradaySeries.motionByBucket`, which uses the share of records rather than of time.
- Whole-interval shares are already in the envelope's `activity`.
- An HR-dependent track is ignored (`heart_rate_dependent_motion_ignored`).
- High motion makes optical beat timing `degraded` or `invalid` with `motion_contaminated`, a signal-quality reason.
  It never edits the IMU evidence: the motion labels and bouts are untouched.

### Heart rate (`heart_rate`, `resting_heart_rate`)

| Gate | Default | Source |
| --- | --- | --- |
| Coverage = distinct sample seconds / support seconds | < 0.10 invalid `insufficient_coverage`; < 0.50 degraded `partial_coverage` | engineering default |
| Plausible band per sample (diagnostic) | 30–220 bpm; > 50 % outside ⇒ degraded `mostly_out_of_band`, else note `out_of_band_samples`; never invalid on value | engine's derived windows (`Engine.heartRateWindows`) |
| Flatline (identical bpm, steps ≤ 2 s) | ≥ 300 s degraded `flatline_run`; ≥ 900 s and ≥ 80 % of support invalid `flatline` | conservative: smoothed integer bpm can hold a value for minutes in deep sleep |
| Motion | diagnostic `movement_share` only: movement raises HR, it does not corrupt the sample | spec §7 |

`resting_heart_rate` uses the same gates over its whole trailing support (worker: 60 min).

### HRV (`hrv_rmssd`, `hrv_sdnn`)

Beats in the support are split into unbroken runs at three kinds of point:

- a splice: wall clock ahead of the beat's own length by more than 3 s (`IntradaySeries.continuousRuns`,
  `SleepStager.rsaGapToleranceS`)
- an RR channel change
- any break (see the adjacency rule in §1)

Each run is cleaned with `HRVAnalyzer.cleanRRGapAware`. Valid pairs are the `contiguous` survivors. No pair is ever
formed across a run boundary.

Short supports (≤ 600 s) use the series gates:

| Gate | Default | Source |
| --- | --- | --- |
| Clean beats | ≥ 45 else invalid `insufficient_clean_beats` | `IntradaySeries.Tuning.hrvMinCleanBeats` |
| Valid pairs | ≥ 30 else invalid `insufficient_valid_pairs` | `hrvMinPairs` |
| Beat coverage = clean beat time / support | < 0.20 invalid `insufficient_beat_coverage`; < 0.50 degraded `partial_beat_coverage` | `hrvMinCoverage` (ultra-short RMSSD literature accepts 1 min; research.md §3) |

Longer supports (nightly snapshot) are judged on a 300 s grid:

- A window qualifies with ≥ 20 clean beats and ≥ 10 pairs (nightly kernel `HRVAnalyzer.minBeats`).
- No qualified window: invalid `insufficient_clean_beats`.
- Fewer than 50 % of windows qualified: degraded `partial_window_coverage`.

Both kinds of support then apply:

| Gate | Default | Source |
| --- | --- | --- |
| Rejected fraction (out-of-range + ectopic) | > 0.35 invalid `excess_rejected_beats`; > 0.20 degraded `elevated_rejected_beats` | `defaultSpotMaxRejectedFraction`; ≥ 80 % normal beats (Peltola 2012, research.md §4) |
| Out-of-kernel-band beats (300–2000 ms) | note `beats_outside_kernel_range` (a measurement limit, not an artifact claim) | `HRVAnalyzer.rrMinMs/rrMaxMs` |
| Over-count verdict (`classifyCoverage(rrCoverage, collapsedCoverage)`) | same-second / cross-second ⇒ invalid `rr_over_count_*`; under-covered / unmeasurable ⇒ note | `successiveDiffIsTrustworthy`, `beatSpreadIsTrustworthy` |
| Beat accuracy (`beatAccurateFraction` < 0.5) | SDNN invalid, RMSSD degraded `beat_values_untrustworthy` | `beatValuesAreTrustworthy` (HRVAnalyzer deliberately does not gate RMSSD here) |
| Motion share | > 0.30 invalid `motion_contaminated`; > 0.10 degraded `motion_present` | `DaytimeStress.activityMaskFraction`, `restingMaxAmbulatoryShare`; PRV vs motion (research.md §5) |
| Equal values in one second | note `equal_value_beats_kept`: distinct beats by `seq`, never de-duplicated by value | contracts.md §2 |
| SDNN | note `window_length_dependent`, diagnostic `window_s` | Shaffer & Ginsberg (research.md §3) |

### Respiratory rate (RSA from beat intervals)

- Beats are split into segments at breaks and channel changes. `SleepStager.respBreathTrack` is applied per segment;
  it splits at splices itself.
- Breath intervals are those whose ts lies in the support. Coverage is the run-covered seconds over the support.
- Gates (IntradaySeries respiratory tuning):
  - ≥ 30 beats (`insufficient_beats`)
  - ≥ 6 breath intervals (`insufficient_breath_intervals`)
  - coverage < 0.33 invalid (`insufficient_run_coverage`); < 0.50 degraded (`partial_run_coverage`)
  - over-count, as for HRV
  - beat accuracy invalid: respiration shares the SDNN gate, per HRVAnalyzer
  - motion > 0.30 invalid `motion_contaminated`; > 0.10 degraded. RSA is unreliable outside rest (Charlton
    2016/2018, research.md §6).
- `rsa_only_estimate` is always noted.
- The breath-track rate plausibility filter (`estimate`) is not used, because it is a value gate.

### Skin temperature

- In-band samples are those at 28–42 °C (`AnalyticsEngine.skinTempMinC/MaxC`). They are worn evidence, not an
  artifact judgement.
- No in-band sample: invalid `no_in_band_samples`. Every sample sits in the off-wrist or ambient range.
- Degraded when in-band samples < min(300, half the support seconds) (`insufficient_in_band_samples`;
  `AnalyticsEngine.minSkinTempSamples`).
- Degraded when the in-band share is < 0.5 (`partial_in_band`).
- `skin_not_core_temperature` is always noted (research.md §7). The state can still be valid.

### SpO2 candidate

Always `unverified` with `unverified_strap_estimate`, with no coverage and no confidence. Eligibility gives it no
comparisons.

## 3. Motion evidence: `MotionEvidence.strapTrack` / `strapEvidence`

- **Magnitude bases.**
  - `dynAccelG`, the strap's own gravity-removed magnitude, is preferred when present.
  - Otherwise the gravity delta `|g_t − g_{t−1}|`, computed **only** between samples exactly 1 s apart. A delta across
    a gap is never computed; the first sample after a gap is covered-unknown, not still
    (`testNoGravityDeltaIsComputedAcrossAGap`).
- **Smoothing.** A trailing mean over 5 s, same basis only, current second included. A label never depends on later
  data, and causal replays agree. The cost is a 4 s lag on falling edges (`testSmoothingLagsTheFallingEdge…`).
- **Thresholds** on the smoothed value, for either basis:
  - still ≤ 0.01 g (`SleepStager.gravityStillThresholdG` / `moveDeltaThresholdG`, `dynAccelStillThresholdG`)
  - `low_movement` ≤ 0.10 g (upper edge of SedentaryDetector's desk band, 0.05–0.10 g)
  - `other_movement` above
  - Each basis has its own config fields so they can diverge once real nights are compared.
- **Locomotion** comes only from the step counter (WHOOP 5.0/MG). A counted, plausible increment labels
  `(previous, current]` as `stepping` when the previous sample is ≤ 5 s earlier. The rules are StepsCounter's: classes
  1 and 2, bout blocks, wrap at 65536 and 4 ticks/s.
  - Stepping overrides the magnitude label and is emitted even for seconds without a gravity sample.
  - A zero increment, or a still-class increment, is not stillness evidence.
  - Without a step counter (WHOOP 4.0) there is no locomotion label. Movement still breaks stillness.
- **Coverage.** A second with no sample and no stepping evidence is uncovered: no record, never still. Quiet motion
  is evidence of stillness only. An off-wrist strap and a sleeping wearer both read `still`.
- **Basis visibility.** `ResolvedTrack` has no reason field, so the basis is carried by `StrapMotionEvidence`:
  - `counts`: `seconds.dynamic_acceleration`, `seconds.gravity_delta`, `seconds.stepping`,
    `seconds.stepping_without_motion_sample`, `seconds.unknown_magnitude`, `seconds.labelled`
  - `reasons`: `motion_basis_dynamic_acceleration`, `motion_basis_gravity_delta`, `step_counter_stepping`,
    `motion_magnitude_unavailable`, `no_motion_samples`
  - Both are surfaced in the availability-matrix `strap_motion` row. See request R1.

## 4. Regime and comparability

### `regimeTimeline`

- **Placement records.** Each `PlacementInput` is clipped to the read window; an open-ended record runs to the window
  end. Overlaps are resolved by `IntervalAlgebra.resolve`: revision, then `recordedAt`, then a stable id.
- **Unknown placement.** Time before the first record, and gaps between records, is `unknown` / `none`. It is never
  back-filled (V04).
- **Placement boundaries:**
  - `placement_history_start` at the first record
  - `placement` at every change, with `placement_changed`, or `placement_record_gap` when the change is into a gap
- **Method boundaries.** A `method` boundary marks a change of algorithm version, aggregation, window class or units
  between consecutive measurements with the same metric and method id (`method_version_changed`).
- **Days.** `DeviceRegimeInput` is per day, so device, firmware and source changes surface across days through
  `DailyValue.regimeKey`. Splitting a series on them is the statistics workstream's job.

### `regime(for:)`

- Placement is taken over the **whole support**. A support that spans a placement boundary is `mixed` and is
  comparable with neither side.
- The key is FNV-1a over `pc-regime-1 | vendor | family | sourceKind | firmware | placement | method id | algorithm
  version | aggregation | window class | units`. Strings are trimmed and lowercased (firmware is only trimmed); a
  nil attribute is `unknown`.

Key decisions:

- **`algorithmVersion` is in the key.** A scoring or series algorithm change is a method change. Values from two
  algorithms are not pooled without a bridging study.
- **`decoderVersion` is not in the key.** It is recorded in the regime, and the comparability rule names it. A decoder
  translates the same wire fields; a decoder change that alters values must bump the producing algorithm version. A
  decoder-only change therefore does not reset every reference.
- **Window class.** It is the exact `windowS` for windowed aggregates. For `session` / `day` aggregates it is the
  aggregation itself, because a night is one unit whatever its length. Keying nightly snapshots by session seconds
  would make every night its own regime.
- **Placement source** (`user` / `device`) is recorded, not keyed.
- **Unknown attributes.** Two unknown firmware values are equal, which is a limitation: push devices do not write
  firmware or family (discovery §3), so a firmware change can hide inside "unknown". Known versus unknown is
  incompatible (`firmware_unknown`).

### `comparability`

- An identical key is comparable, under one of these rules:
  - `identical_regime`
  - `identical_regime_session_length_varies` (two session aggregates of different length)
  - `identical_regime_decoder_differs` (both decoder versions known and different)
- Anything else is `incompatible`, naming every differing attribute. The reasons are `vendor_differs`,
  `device_family_{differs,unknown}`, `source_kind_{differs,unknown}`, `firmware_{differs,unknown}`,
  `placement_{differs,unknown,mixed}`, `method_differs`, `algorithm_version_differs`, `aggregation_differs`,
  `window_differs`, `units_differs`, and `regime_key_differs` as a fallback.
- Nothing is pooled across vendor, placement, method, algorithm, aggregation, window or units.

## 5. Availability matrix

Rows are listed in a fixed order. `comparability` is the rule applied across regimes.

| Assessment | Source | State | Comparability / reasons |
| --- | --- | --- | --- |
| `heart_rate_signal_validity`, `resting_heart_rate_signal_validity` | `strap_heart_rate` | supported / unavailable | `identical_regime_only` |
| `hrv_signal_validity` (RMSSD, SDNN) | `strap_rr_intervals` | supported; partial on a day-level over-count or untrustworthy beat values; unavailable | SDNN `identical_window_length_only` |
| `respiratory_signal_validity` | `strap_rr_intervals_rsa` | as RR | `rsa_only_estimate` |
| `skin_temperature_signal_validity` | `strap_skin_temperature` | supported / partial (no in-band) / unavailable | `relative_within_regime_only`, `skin_not_core_temperature` |
| `core_temperature` | none | **unsupported** | `no_core_temperature_sensor` |
| `spo2_signal_validity` | `strap_spo2_candidate_byte` | **unverified** | `excluded_from_comparisons` |
| `ppg_waveform_quality` | none | **unsupported** | `no_qualified_waveform` |
| `posture` | `strap_gravity_orientation` | **unverified** / unavailable | `wrist_orientation_likelihood_only` |
| `activity_composition` | `hart_epochs`, `strap_motion`, `decoder_intervals` | supported / unavailable | HR-independent or `heart_rate_dependent_source` + `display_only`; strap shows the motion basis |
| `stable_awake_eligibility` | `context_layer` | partial / unavailable | `sleep_detector_uses_heart_rate`, `wear_from_heart_rate_signal`, `awake_evidence_unavailable`, … |
| `sleep_measurement_eligibility` | `detected_sleep_sessions` | partial / unavailable | `sleep_detector_uses_heart_rate` |
| `activity_response_eligibility` | `context_layer` | supported / unavailable | — |
| `measurement_product` | `<product>:<method id>` | supported (SpO2 unverified) | per-metric rule |

In causal mode, measurement-product rows list only measurements available at the cutoff, using the engine's filter.

## 6. Eligibility

### Tri-state rule

- Every check contributes `fail` (determined and failed), `unknown` (could not be determined) or nothing.
- Any fail ⇒ `ineligible`. Otherwise any unknown ⇒ `unknown`. Otherwise `eligible`.
- All reasons are kept, so an ineligible verdict also lists what was unknown.
- An eligible verdict carries a positive reason: `stable_awake_low_movement`, `inside_supported_sleep`,
  `inside_locomotion` or `after_exertion_bout`.

### Value independence and dependence

- **No check reads the measurement value.** `evaluate` has no value parameter (V03).
- `targetDependentGates = [signal_invalid]` on every verdict. Validity reads the target's own signal and is declared
  for selection-bias review.
- Signal validity maps to: invalid ⇒ fail `signal_invalid`; degraded ⇒ note `signal_degraded`; missing / unsupported
  ⇒ unknown; unverified ⇒ fail.
- An HR-dependent composition, or the decoder as source, is never used. The verdict notes
  `heart_rate_dependent_activity_ignored`, adds `activity_labels_read_heart_rate` to `dependsOn`, and treats activity
  evidence as unavailable.
- `dependsOn` lists `sleep_detector_uses_heart_rate` and `wear_from_heart_rate_signal` when System C's evidence is
  heart-derived.
- Wrist posture is never read.

### `comparisons(for:method:)`

| Method | Comparisons |
| --- | --- |
| `series.*`, `context.*` | stable awake rest, sleep measurement, activity response |
| `snapshot.*` | sleep measurement |
| SpO2 candidate | none |
| Unknown ids | by aggregation: session / day ⇒ sleep measurement; else all three |

### Stable awake rest

This is "stable awake low movement", never calm or recovered. It starts from `ActivityContextJoin.restingEligibility`.

| Check | Default | Outcome |
| --- | --- | --- |
| Awake (`sleepWear.sleepState`) | — | asleep ⇒ fail `asleep`; mixed ⇒ fail `sleep_wake_mixed`; unknown ⇒ unknown `awake_evidence_unknown` |
| Worn (`wearState`) | — | not worn ⇒ fail `not_worn`; mixed ⇒ fail `wear_mixed`; unknown ⇒ unknown `wear_evidence_unknown` |
| Movement in support | `1 − movement share < 0.90` | fail `movement_in_support`: even all-stationary unlabelled time could not reach the floor |
| Qualified coverage (labelled stationary + movement / whole support) | ≥ 0.90 (`restingCoverageFloor`) | else unknown `insufficient_activity_coverage` |
| Stationary share of the WHOLE support | ≥ 0.90 (`restingStationaryFloor`) | else unknown `insufficient_stationary` |
| Preceding still run | ≥ 300 s (`ActivityPolicyConfig.minStillnessS`) | ended by movement ⇒ fail `insufficient_preceding_stillness`; by gap / unknown ⇒ unknown `preceding_stillness_unobserved` |
| Recent locomotion (`secondsSinceSupportedActivity`) | < 600 s (`postActivityWindowS`) | fail `recent_locomotion`; not fully observed ⇒ note `recent_locomotion_unobserved` |
| Recent bout (`BoutRef.secondsBeforeMeasurement`) | < 600 s (`postBoutExclusionS`, 0 disables) | fail `recent_exertion_bout` |
| 24 h locomotion | `maxLocomotion24hS = nil` (record only) | when set: fail `exertion_history_exceeds_limit` |

Evidence recorded:

- stationary share, movement share and qualified coverage
- preceding still run and seconds since locomotion
- recent bout count and seconds since the last bout
- `exertion_{24,48,72}h_locomotion_s`

Window counts and observed seconds stay in the envelope's `history.exertion`.

### Sleep measurement

- asleep ⇒ ok; awake ⇒ fail `not_asleep`; mixed ⇒ fail; unknown ⇒ unknown `sleep_evidence_unknown`.
- Worn is required.
- Staging is never read.

### Activity response

The verdict is eligible when either of these holds:

- locomotion share of the support ≥ 0.50 (`inside_locomotion`)
- a `BoutRef` ended ≤ 900 s before the support (`after_exertion_bout`)

Otherwise:

- no usable HR-independent activity ⇒ unknown
- qualified coverage < 0.50 ⇒ unknown `insufficient_activity_coverage`
- else fail `no_supported_exertion`

Asleep ⇒ fail. Not worn ⇒ fail. Unknown wear is noted only.

### `selection`

One summary per (comparison, metric) present:

- counts of eligible, ineligible and unknown verdicts
- `eligibleSupportS`: the union of eligible supports within the day, so overlapping trailing supports count once
- `observedS`: distinct observed seconds of the metric's input stream (HR samples, beat seconds, skin samples)
- `eligibleObservedS`: observed seconds inside eligible supports
- `representedShare = eligibleObservedS / observedS`, which is at most 1. The skeleton's "eligibleSupportS / observedS"
  could exceed 1 and is replaced; the doc comment is updated.
- the top 10 ineligible and unknown reasons

## 7. Policy sensitivity (stable awake rest)

`PCEligibilityTests.testStableAwakePolicySensitivitySweep` builds a deterministic synthetic waking day:

- 07:00–20:00 strap motion with quiet desk time at 0.003–0.005 g
- fidgets of 0.25 g lasting 2–6 s, at an hourly rate cycling 0.001 / 0.004 / 0.012 per second
- three walks with step-counter evidence (09:00–09:20, 12:30–12:45, 17:00–17:30)
- a 10-minute disconnection at 14:00

It evaluates 144 five-minute windows (08:00–20:00) as awake, worn and valid. Each cell is the eligible share:

| stationary floor \ preceding stillness | 120 s | 300 s (default) | 600 s |
| --- | --- | --- | --- |
| 0.80 | 0.500 | 0.382 | 0.229 |
| **0.90 (default)** | 0.472 | **0.375** | 0.229 |
| 0.95 | 0.424 | 0.340 | 0.215 |

Exclusions at the default (reasons per excluded window):

| Reason | Windows |
| --- | --- |
| `insufficient_preceding_stillness` | 85 |
| `movement_in_support` | 24 |
| `recent_locomotion` | 16 |
| `activity_evidence_unavailable` (the disconnection) | 2 |
| `preceding_stillness_unobserved` | 1 |

Eligible windows by fidget stratum:

| Fidget rate per second | Eligible windows |
| --- | --- |
| 0.001 | 38 / 48 |
| 0.004 | 13 / 48 |
| 0.012 | 3 / 48 |

Reading:

- The preceding-stillness requirement dominates. The stationary floor matters less (0.80 → 0.95 removes about 4–8
  points), and the effect is monotone.
- The selection is strongly stratified: restless hours are almost entirely excluded. Any reference built from
  stable-awake windows describes the quietest part of the day. That is the context-selection bias `selection`
  reports.
- These are synthetic numbers. They show the shape of the dependence, not real-world rates.
- **Defaults are not changed**: there is no evidence for a different value. Rerunning this sweep on authorized real
  days (with `selection.representedShare`) is the next step.

## 8. Reason codes

`SignalValidityEngine.reasonCodes`, input contract:

| Code | Meaning |
| --- | --- |
| `out_of_contract_units` | A row broke the unit or range contract (counts name the stream) |
| `outside_read_window` | Sensor time outside the read window |
| `future_timestamp` | Sensor time after generation (+300 s) |
| `timestamp_spike` | An isolated out-of-sequence timestamp was rejected |
| `exact_duplicates_collapsed` | Identity duplicates collapsed to one row |
| `conflicting_duplicates_rejected` | Differing values under one identity: all rejected, never averaged |
| `non_monotonic_timestamps` | Input order went backward |
| `clock_reset_detected` | A large backward jump inside one delivery; its overlap span is a break |
| `overlapping_timelines_suspected` | A ≥ 30 s cluster of conflicting HR seconds; break |
| `disconnection` | A > 60 s hole in HR, RR and motion; break |
| `source_change` | RR source channel changed; break |
| `availability_basis_sensor_time` | Some rows had no availability time |
| `device_clock_ahead` | Sensor time later than its own availability |

`SignalValidityEngine.reasonCodes`, validity:

| Code | Meaning |
| --- | --- |
| `invalid_interval` | Empty or inverted support |
| `no_heart_rate_samples` / `no_beat_intervals` / `no_skin_temperature_samples` | Missing input (state `missing`) |
| `insufficient_coverage` / `partial_coverage` | HR coverage below the invalid / valid bar |
| `flatline` / `flatline_run` | Stuck constant HR / a long constant run |
| `out_of_band_samples` / `mostly_out_of_band` | HR samples outside 30–220 bpm (never invalid on value) |
| `contains_break` | A break intersects the support; nothing is bridged |
| `insufficient_clean_beats` / `insufficient_valid_pairs` / `insufficient_beat_coverage` | HRV invalid gates |
| `partial_beat_coverage` / `partial_window_coverage` | HRV degraded coverage |
| `excess_rejected_beats` / `elevated_rejected_beats` | Rejected fraction above 0.35 / 0.20 |
| `beats_outside_kernel_range` | Beats outside 300–2000 ms (kernel limit) |
| `rr_over_count_same_second` / `rr_over_count_cross_second` | Over-counted capture (invalid) |
| `rr_under_covered` / `rr_coverage_unmeasurable` | Coverage verdict notes |
| `beat_values_untrustworthy` | Banked / decomposed beat values |
| `equal_value_beats_kept` | Equal intervals in one second kept as distinct beats |
| `motion_contaminated` / `motion_present` / `motion_unobserved` | Optical timing vs motion |
| `heart_rate_dependent_motion_ignored` | An HR-dependent track was not used |
| `window_length_dependent` | SDNN is comparable only at equal window length |
| `insufficient_beats` / `insufficient_breath_intervals` / `insufficient_run_coverage` / `partial_run_coverage` | Respiration gates |
| `rsa_only_estimate` | RSA-only respiration (interpretation limit) |
| `no_in_band_samples` / `insufficient_in_band_samples` / `partial_in_band` | Skin worn-band gates |
| `skin_not_core_temperature` | Skin temperature is relative only, never core |
| `unverified_strap_estimate` | SpO2 candidate |

`SignalValidityEngine.reasonCodes`, regime and matrix:

| Code | Meaning |
| --- | --- |
| `placement_changed` / `placement_history_starts` / `placement_record_gap` / `method_version_changed` | Boundaries |
| `vendor_differs` … `units_differs`, `regime_key_differs` | Comparability reasons (§4) |
| `no_qualified_waveform` / `no_core_temperature_sensor` / `wrist_orientation_likelihood_only` / `no_gravity_vector` | Unsupported or unverified rows |
| `heart_rate_independent_source` / `display_only` / `no_source_records` / `step_counter_present` | Activity sources |
| `sleep_detector_uses_heart_rate` / `wear_from_heart_rate_signal` / `awake_evidence_unavailable` / `wear_evidence_unavailable` / `sleep_evidence_unavailable` / `excluded_from_comparisons` | Eligibility availability |

`MotionEvidence.reasonCodes`: `motion_basis_dynamic_acceleration`, `motion_basis_gravity_delta`,
`step_counter_stepping`, `motion_magnitude_unavailable`, `no_motion_samples`.

`Eligibility.reasonCodes`: `stable_awake_low_movement`, `inside_supported_sleep`, `inside_locomotion`,
`after_exertion_bout`, `invalid_interval`, `signal_invalid`, `signal_degraded`, `signal_validity_missing`,
`signal_unverified`, `signal_unsupported`, `heart_rate_dependent_activity_ignored`, `activity_evidence_unavailable`,
`insufficient_activity_coverage`, `asleep`, `sleep_wake_mixed`, `awake_evidence_unknown`, `not_worn`, `wear_mixed`,
`wear_evidence_unknown`, `movement_in_support`, `insufficient_stationary`, `insufficient_preceding_stillness`,
`preceding_stillness_unobserved`, `recent_locomotion`, `recent_locomotion_unobserved`, `recent_exertion_bout`,
`exertion_history_exceeds_limit`, `not_asleep`, `sleep_evidence_unknown`, `no_supported_exertion`. `dependsOn`
labels: `sleep_detector_uses_heart_rate`, `wear_from_heart_rate_signal`, `activity_labels_read_heart_rate`.

## 9. Limitations and unsupported inputs

**Not supported or not claimed**

- No PPG waveform: PPG waveform quality is `unsupported`.
- No core temperature.
- SpO2 stays unverified.
- Posture is a wrist-orientation likelihood only, and no assessment uses it.

**Unvalidated thresholds**

- No threshold is validated against reference labels for this purpose. The motion thresholds on `dynAccelG` borrow
  the gravity-delta stillness cut, and the two measure different things (HistoricalStreams.swift comment).
- The HRV and respiration gates are the series kernel's. They come from ECG and resting literature; WHOOP PRV error
  modes differ (research.md §4–6).

**Clock and identity detection**

- Clock-reset detection needs transport order. Sorted input reveals resets only through conflicting duplicates and
  RR over-count.
- Firmware and device family are mostly unknown for push devices, so firmware changes inside "unknown" are not
  detectable.
- Whole-second RR storage: a source change in adjacent seconds costs one extra pair. No sub-second beat time is
  reconstructed.

**Strap motion**

- Labels lag falling edges by 4 s, from the trailing smoothing.
- WHOOP 4.0 has no step counter, so it gets no locomotion label.
- Stillness is never evidence of wear or sleep.

**Eligibility in the current integration**

- Stable-awake and sleep eligibility depend entirely on System C's `sleepWear`. Before System C was merged it returned
  `unknown`, so every stable-awake verdict was `unknown`. That is the honest result. The awake evidence the sleep
  workstream provides is heart-dependent (`sleep_detector_uses_heart_rate`).

**Document size**

- A full synthetic day of 1 Hz HR/RR/motion plus 2304 measurements yields a 6.56 MB document.
  - Validity: 0.77 MB
  - Eligibility: 2.37 MB, about 340 B per verdict, roughly 150 B of it the fixed verdict shape
  - Activity and preceding (lead): 1.43 MB
- Timing, debug build: `sanitize` 0.06 s, `buildDay` 0.26 s.

## 10. Test ↔ V-case map

| V-case | Tests |
| --- | --- |
| V02 quiet IMU, unknown wear / sleep | `PCEligibilityTests.testQuietMotionWithUnknownWearAndSleepIsUnknownWithExplicitReasons`, `testHeartRateDependentActivityIsNeverEligibilityEvidence`, `PCMotionEvidenceTests.testNoMotionMeansUncoveredNeverStill` |
| V03 elevated HR / low HRV | `PCEligibilityTests.testStableAwakeWithElevatedHeartRateAndLowHrvStaysEligibleAndValid`, `testEvaluateNeverReadsTheValue`, `PCSignalValidityTests.testHeartRateFullCoverageIsValidAndElevatedValuesAreNotArtifacts`, `testLowHrvAtRestIsValid` |
| V04 placement / firmware / method change | `PCSignalRegimeTests` (all), including `testPlacementChangeMidDayIsABoundaryWithDifferentRegimeKeys`, `testHistoryBeforeTheFirstPlacementRecordIsUnknownNotBackFilled`, `testFirmwareVendorAndUnknownAttributesAreIncompatible`, `testMethodAlgorithmAndWindowChangesAreIncompatible`, `testAlgorithmVersionChangeAcrossTheDayIsAMethodBoundary`, `testEngineDocumentRegistersBothPlacementRegimes` |
| V05 duplicates, equal RR, gaps, clock resets | `PCSignalSanitizeTests` (identity, contract, timing, ordering), `PCSignalValidityTests.testRepeatedEqualIntervalsInOneSecondAreDistinctBeatsWithValidAdjacency`, `testAGapSplitsRunsAndNoPairIsFabricatedAcrossIt`, `testASourceChannelChangeSplitsAdjacency`, over-count tests |
| V10 (report part) | `PCSignalSanitizeTests.testLiveReportNeverCountsDataBeyondTheCutoff`, `PCSignalRegimeTests.testAvailabilityMatrixInLiveModeListsOnlyMeasurementsAvailableAtTheCutoff` |
| V13 (eligibility dependence) | `PCEligibilityTests.testHeartDerivedEvidenceIsDeclaredInDependsOn` |
| §7 SpO2 / PPG / skin | `testSpo2CandidateIsAlwaysUnverified`, `testSkinTemperatureIsNeverCoreAndOffWristRangeIsInvalid`, `testAvailabilityMatrixStatesUnsupportedAndUnverifiedRowsExplicitly` |
| §8 sensitivity | `PCEligibilityTests.testStableAwakePolicySensitivitySweep` |

## 11. Commands and results

All commands run in `Packages/StrandAnalytics`:

```
swift build                                              # Build complete, no warnings in these files
swift test --filter "PCSignal|PCMotion|PCEligibility"    # Executed 73 tests, with 0 failures
swift test --parallel                                    # 2621 tests run (incl. lead's 18 PC tests), exit 0, 0 failures
```

Test files and counts:

| File | Tests |
| --- | --- |
| Fixtures | 2 |
| Sanitize | 14 |
| Validity | 20 |
| Regime / matrix | 10 |
| Motion | 11 |
| Eligibility | 16 |

Not run: the worker, backend and app suites (not touched by this workstream), and real-data replay (no authorized
real days in this worktree).

## 12. Requests to the lead (files I do not own)

- **R1 — motion basis on the track.** Add `reasons: [ReasonCode] = []` to `ResolvedTrack`, copied into
  `ActivityComposition.reasons` by `IntervalAlgebra.composition`. Then `strapTrack` can mark
  `motion_basis_gravity_delta` / `motion_basis_dynamic_acceleration` on every envelope's activity. Today the basis is
  visible only in `StrapMotionEvidence` and the availability-matrix `strap_motion` row.
- **R2 — RR ordering wording.** contracts.md §2 says "sorted by `ts` (then identity)". The implementation sorts beat
  intervals by `(ts, ord, rrMs, seq)`: within a second the known transport position comes first, because it is the
  emitted beat order and adjacency depends on it; otherwise identity order. Please adopt that wording, or tell me to
  drop `ord`.
- **R3 — snapshot `windowS`.** The worker should set nightly snapshot `MethodRef.windowS` to the session length with
  `aggregation = .session`. The regime key uses the aggregation class for session / day aggregates, so nights stay
  one regime.
- **R4 — verdict size.** `policyVersion` and `targetDependentGates` repeat on every verdict, about 60 B × 3 per
  envelope. Consider hoisting them to document level in a later schema.
- **R5 — engine read window.** `SignalValidityEngine.readWindow` uses `Engine.rawLookbackS` / `rawLookaheadS`
  (internal). Please keep those names stable, or expose the read window on `Engine`.
