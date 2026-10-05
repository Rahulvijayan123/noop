# Responses & function workstream notes (Systems D and G)

Branch `pc/responses` (from contract commit `71dce34a`). Files: `PhysiologyContext/PCExertionBouts.swift`,
`PhysiologyContext/PCFunctional.swift`, tests `PCExertionBoutsTests.swift`, `PCExertionEngineIntegrationTests.swift`,
`PCFunctionalTests.swift`. Every public signature of the skeleton is kept; fields were added with defaults (and
custom `init(from:)` so JSON written before the additions still decodes), plus new types and config fields.

## System D — exertion bouts, response, recovery

### Evidence and detection (never heart rate)

- **Evidence.** Per second: the HART label where HART has a known label with abstention < 0.5, else the strap-motion
  label (`still` / `low_movement` / `stepping` / `other_movement`), else HART's abstained span, else uncovered
  (`BoutEvidence`). HART wins where confident because it is the dedicated classifier; the strap fills HART's gaps
  (HART is usually absent). Neither reads HR.
- **Workouts.** Sources in `loggedWorkoutSources` (`manual`, `imported`) are bout sources (the person's own record).
  `detected` workouts come from `WorkoutDetector` / `AutoWorkoutDetector`, which threshold HR: using them would select
  bouts by the response, so they are never a source; an overlap is noted (`overlaps_hr_detected_workout`). If imported
  workouts turn out to be watch auto-detections, set `loggedWorkoutSources = ["manual"]`.
- **Segmentation.** Contiguous locomotion spans form runs. Runs and logged workouts merge when they overlap or are
  separated by ≤ `maxPauseS` = 60 s, unless the pause contains a recorded break (`SanitizedObservations.breaks`) or
  > `maxUncoveredInPauseS` = 10 s without motion evidence (no bridging). A group is a bout when it contains a logged
  workout or ≥ `minBoutLocomotionS` = 60 locomotion seconds. Segmentation runs over the whole read window so the
  previous/next bout is known across midnight; only bouts whose **start** is in the day window are returned.
- **Identity.** `id = fnv1a("bout|<deviceScope>|<start>")`; `day` = local day of the start. The start is fixed by
  earlier evidence only, so ids are stable across retries, later cutoffs and input order.
- **Kind.** `workout` for a group with a logged workout; else the dominant locomotion label when it holds ≥ 80 % of
  locomotion seconds (`walking` incl. `brisk_walking`, `running`, `stepping`), else `mixed_locomotion`.
- **Ongoing.** A bout is `ongoing` when its end + `maxPauseS` passes the cutoff (cessation not yet establishable) or a
  logged workout is clipped at the cutoff. Ongoing bouts keep their response, have no recovery, and are provisional.
- **Composition / confidence.** `composition` is `IntervalAlgebra.composition` over the whole bout on the merged
  evidence (source = the source with most covered seconds, `merged_hart_and_strap_evidence` when both contributed;
  per-source seconds in `evidenceSeconds`). `confidence` = locomotion share of the whole bout, kind
  `heuristic_score` (not a probability); `not_applicable` for logged workouts.
- **Pauses.** Gaps ≥ `minPauseS` = 10 s between a bout's runs that are mostly observed.

### Pre-bout context and response

- `preBout.preceding` = `IntervalAlgebra.precedingHistory` (lookback 1800 s) on the merged evidence.
  `state`: `recent_bout` (previous bout ended within the follow-up horizon, 615 s), else `rested` (still run ≥ 300 s,
  the stable-awake policy's preceding stillness), else `recent_movement` (still run ended by movement), else `unknown`.
- Pre-bout HR reference = median HR over `[start-180, start-30)` with ≥ 50 % coverage (≥ 75 samples at 1 Hz).
  The 30 s gap keeps anticipatory rise and label latency out of the reference.
- During the bout: median and p95 (`RobustStats.quantile`, type 7) with ≥ 50 % coverage; signed `hrRiseBpm` =
  median − reference, `hrPeakRiseBpm` = p95 − reference; `endHrBpm` = median of the final 30 s (after any break).
  `HeartRateRecovery` uses the *max* of the final 30 s; the median is used here because free-living optical HR has
  spikes. HR range 30–250 bpm (as `HeartRateRecovery`).
- **Respiratory response during movement: unavailable** (`respiration_unavailable_during_movement`): the estimator is
  RSA/RR-derived and not valid during movement (research note 6). Post-bout respiration: unavailable
  (`no_supported_post_bout_respiratory_estimator`) — no estimator in the layer is validated for that window.
- **HRV during recovery: unavailable** (`hrv_recovery_window_unsupported`): post-exercise RR is non-stationary and
  this layer has no method with validated window/quality constraints there. Time to plateau is not implemented.

### Recovery ("post-effort HR decline")

- Offsets `[60, 120, 300, 600]` s after the end; each reading is the median of ≥ 3 samples within ±15 s, no
  interpolation (the `HeartRateRecovery` conventions). `declineBpm` = end HR − reading (positive = decline);
  `aboveReferenceBpm` = reading − reference; `fractionRecovered` = (end − reading) / (end − reference) only when the
  rise end − reference ≥ 5 bpm (else `rise_too_small_for_fraction`). Values above 1 are kept (an elevated reference).
- **Truncation (censoring)** at the first of, ties in this order:
  `disconnect` — a recorded break in the follow-up, or an HR gap > 10 s (`HeartRateRecovery.maximumContinuousGapSeconds`);
  `no_follow_up` — no HR sample at all after the end; `next_bout` — the next bout's start (so every reading belongs
  to exactly one bout and the next bout's pre-window is never also counted as this bout's outcome);
  `continued_movement` — ≥ 10 contiguous seconds of locomotion or other movement after cessation;
  `cutoff_reached` — the cutoff falls inside the follow-up (also when the stream stops short of such a cutoff:
  late-arriving data is not a disconnect). A reading whose window reaches the truncation point is `censored`; one
  with too few samples before truncation is `unobserved`. Nothing is estimated from elapsed stationary time.
- `timeToReturnS` = the first offset whose reading is within 5 bpm of the reference, only when every earlier offset
  was observed (offset resolution: "returned by"). nil with `not_returned_by_last_observed_offset`,
  `return_undetermined_earlier_offset_unobserved`, `rise_too_small_for_return` or `pre_bout_reference_unavailable`.
- Status: `complete` (no censoring, all readings observed), `censored`, or `ongoing`. Response fields are kept
  whatever the recovery status.
- Readings where the motion evidence of `[end, window end)` has > 10 uncovered seconds carry
  `follow_up_motion_unobserved` (continued movement cannot be excluded there).
- Framing: free-living recovery has no standardized peak, posture or cool-down; it is not clinical HRR and its
  protocol cut-offs (12/18/22 bpm) do not apply (`post_effort_hr_decline_not_clinical_hrr`; research note 9).

### Matching, history, daily values

- `BoutMatchKey.key` = `<activityKind>.<cadenceBand>.<durationBand>.<precedingState>`, e.g.
  `walking.c80_110.d600_1800s.rested`. Duration bands from edges 180/600/1800 s; cadence bands from 80/110/140 counter
  steps/min, or `cadence_unavailable`. For workouts `activityKind` = `workout_<logged type>` (`workout_mixed`,
  `workout_unspecified`). `workloadLimitations` is always `speed_unavailable, grade_unavailable,
  external_load_unavailable, ambient_unavailable`: nothing in the input measures them (research note 10).
- `recentRefs`: bouts ended at or before `ts`, within the longest window (72 h), newest first, de-duplicated by id.
- `windows`: per configured window, `boutCount` = bouts overlapping, `locomotionS` = union of bout seconds clipped
  to the window. `observedS` from `DayCoverage`: a fully contained day adds its observed seconds; a partially
  overlapped day adds exact seconds when `observedIntervals` is set, else a prorated share with
  `observedLowerS`/`observedUpperS` bounds (`observed_prorated_partial_day`). Any part of the window without coverage
  → `observedS = nil` (`coverage_unknown_for_part_of_window`). Zero observed → `no_motion_observed_in_window`.
- `dailyValues`: `hr_response.<match key>` = median `hrRiseBpm` of the day's ended bouts with that key (censored
  recovery does not remove the response); `hr_recovery_60s.<activityKind>` = median 60 s decline over readings
  observed before any truncation. `supportUnit = bout`, `sourceIds` = bout ids, metric `heart_rate`, units `bpm`.
  No value without a supported bout. **Finality**: provisional in causal mode or when any contributing bout is
  provisional; a bout is provisional in causal mode, when ongoing or cutoff-censored, or when the cutoff is earlier
  than day end + 30 h (`finalAfterDayEndS`, mirroring `JoinConfig.finalAfterDayEndS`). Lead: reconcile with the
  document finality if they should be identical by construction.

## System G — functional features and feature registry

- **Evaluated interval** `[day start, min(day end, cutoff))`; `day_incomplete_at_cutoff` when shorter.
- **Waking denominator**: evaluated seconds minus sleep episodes (`sleep.episodes`); with no episode the whole
  interval counts and `sleep_not_excluded_from_waking_time` is set.
- **Wear** per minute: not worn while the latest wear event is off-wrist; otherwise worn when the minute has
  ≥ 30 HR samples (heart-signal presence), locomotion evidence, or an on-wrist state with motion samples. Basis
  `heart_rate_signal`, `wear_events` (joined with `+`, plus `locomotion_evidence` when it added minutes); `none`
  when neither HR nor wear events exist (then `observedWearS = nil`, `wear_evidence_unavailable`). HR presence is
  heart-derived; acceptable for a wear denominator (it never enters a physiological value) and declared
  (`wear_denominator_uses_heart_signal_presence`). Quiet motion alone never establishes wear.
- **totalsComparable** = wear known, worn waking ≥ 70 % of waking time, and the day complete. Wear-normalized values
  need ≥ 4 worn waking hours (`ratesSupported`). Below 70 %: `insufficient_wear_coverage`,
  `wear_missingness_may_be_informative` — a lower captured total is missingness, never decline (V14).
- **Features**: bout count, duration median / p90 / max, bout seconds; locomotion seconds of the waking evidence
  (bouts and shorter walks) and per worn waking hour; bouts per worn hour; pauses (count, median, per bout hour);
  cadence (minute-weighted mean of bouts' counter cadence, median within-bout CV); stationary↔locomotion transitions
  on the evidence (≤ 30 s of other movement may sit between; gaps, unknown labels and sleep boundaries break the
  chain); fragmentation `activeToRestPerActiveMin` (≥ 5 active minutes) and `restToActivePerRestMin` (≥ 30 rest
  minutes); rest after activity = median still seconds after each ended bout until the next movement, capped at
  3600 s (ends not observed — gap, unknown, day end — are excluded, `rest_after_bout_right_censored`).
- **Daily values** (only when wear is known): with `ratesSupported` — `functional.locomotion_s_per_worn_hour`,
  `functional.bouts_per_worn_hour`, `functional.median_bout_s`, `functional.pauses_per_bout_hour`,
  `functional.cadence_steps_per_min`, `functional.cadence_within_bout_cv`, `functional.active_to_rest_per_min`,
  `functional.rest_after_bout_median_s`; with `totalsComparable` — `functional.locomotion_s`, `functional.bout_count`.
- **Feature registry** `pc-features-1`: 11 general definitions (the series above plus `functional.bout_duration_p90_s`;
  `technical_verification_only`) and 6 specialized definitions (`not_validated`): `specialized.gait_speed`,
  `stride_length`, `tremor_index`, `respiratory_event_index`, `autonomic_index`, `symptom_classifier`, each with
  required sensors, placement, labels, reference assessments, timing, population and units. `evaluate` computes the
  general ones from the summary (unavailable with the blocking reasons otherwise) and returns specialized ones as
  `unavailable` with `missing_sensor:*`, `missing_placement:*`, `missing_label:*`, `missing_reference_assessment:*`
  and `no_validated_definition`. Only `ppg_waveform` (availability row `ppg_waveform_quality` supported) and
  `spo2_validated` (spo2 candidate supported) can ever be satisfied from inputs; no label input exists, so specialized
  features cannot compute. No coefficients, no diagnoses. A user-entered symptom is an observed report
  (`user_reported_symptom_is_observed_report_not_diagnosis` on the symptom classifier).

## Limitations

- No speed, grade, external load or ambient input: HR response is not effort-normalized and is not fitness.
- Wrist cadence = uncalibrated step-counter ticks per minute (`stepTicksPerStep` not applied; legacy unclassed
  counters also count some non-step motion, `step_counter_unclassed_legacy`); it is not gait speed or stride length.
- Optical HR during movement is not validated here (`optical_hr_during_movement_unvalidated`).
- Respiratory response during movement and HRV during recovery are unavailable.
- Partial-day trailing-window coverage is prorated unless `DayCoverage.observedIntervals` is supplied.
- The strap track is built by the signal workstream; all tests here construct tracks with `IntervalAlgebra.resolve`.
  Synthetic fixtures verify arithmetic and invariants, not real-world accuracy.

## Reason codes

`ExertionBouts.reasonCodes` (42) and `Functional.reasonCodes` are the registries. Censoring: `disconnect`,
`no_follow_up`, `next_bout`, `continued_movement`, `cutoff_reached`. Bout: `bout_ongoing`, `ended_at_evidence_gap`,
`merged_hart_and_strap_evidence`, `overlaps_hr_detected_workout`, `workout_without_locomotion_evidence`,
`workout_clipped_at_cutoff`, `insufficient_follow_up_samples`. Pre-bout: `pre_bout_hr_insufficient_coverage`,
`pre_bout_window_in_prior_recovery`, `pre_bout_window_overlaps_prior_bout`, `preceding_state_unknown`. Response:
`hr_insufficient_coverage_during_bout`, `pre_bout_reference_unavailable`, `end_hr_unavailable`,
`optical_hr_during_movement_unvalidated`, `respiration_unavailable_during_movement`,
`no_supported_post_bout_respiratory_estimator`, `hrv_recovery_window_unsupported`. Readings:
`insufficient_samples_at_offset`, `follow_up_motion_unobserved`, `rise_too_small_for_fraction`,
`rise_too_small_for_return`, `not_returned_by_last_observed_offset`, `return_undetermined_earlier_offset_unobserved`,
`post_effort_hr_decline_not_clinical_hrr`. Cadence: `cadence_unavailable`, `insufficient_cadence_minutes`,
`step_counter_unclassed_legacy`, `uncalibrated_step_counter`, `wrist_cadence_not_gait_speed`. Workload:
`speed_unavailable`, `grade_unavailable`, `external_load_unavailable`, `ambient_unavailable`. Windows:
`coverage_unknown_for_part_of_window`, `observed_prorated_partial_day`, `no_motion_observed_in_window`. Functional:
`day_not_started_at_cutoff`, `day_incomplete_at_cutoff`, `wear_evidence_unavailable`, `insufficient_wear_coverage`,
`insufficient_worn_time_for_rates`, `wear_missingness_may_be_informative`, `sleep_not_excluded_from_waking_time`,
`no_waking_time`, `activity_evidence_unavailable`, `no_bouts`, `wear_denominator_uses_heart_signal_presence`,
`rest_after_bout_right_censored`, `transition_denominator_too_small`, `observed_behaviour_not_diagnosis`. Registry:
`no_validated_definition`, `missing_sensor:*`, `missing_placement:*`, `missing_label:*`,
`missing_reference_assessment:*`.

## Tests ↔ verification cases

| Case | Test |
| --- | --- |
| Bouts never from HR alone | `testHeartRateRiseWithoutLocomotionCreatesNoBout`, `testDetectedWorkoutIsAnnotationNotSource` |
| Response / complete recovery (hand-derived offsets, fractions, time-to-return) | `testWalkingBoutResponseAndCompleteRecovery` |
| V07 disconnect during follow-up | `testV07RecoveryInterruptedByDisconnectIsCensoredWithoutTimeToReturn` |
| V07 workout ends inside a disconnect | `testV07WorkoutEndingInsideADisconnectHasNoRecoveryAtAll` |
| V07 continued movement | `testV07ContinuedMovementAfterCessationTruncatesRecovery` |
| V07 follow-up beyond causal cutoff / ongoing | `testV07FollowUpBeyondTheCausalCutoffIsCensoredAndProvisional`, `testBoutReachingTheCutoffIsOngoingWithResponseButNoRecovery`, `testCausalDocumentHasAnOngoingProvisionalBout` |
| V08 overlapping recovery windows, single attribution, dedup | `testV08EarlierRecoveryEndsAtTheNextBoutAndEachOutcomeCountsOnce` |
| V08 stable ids across reruns / input order | `testV08IdsAndResultsAreStableAcrossRerunsAndInputOrder` |
| No bridging across breaks; pauses | `testShortPauseMergesButNotAcrossABreak`, `testLocomotionShorterThanTheMinimumIsNotABout` |
| Workouts, HART/strap merge, day ownership | `testLoggedWorkoutAbsorbsOverlappingLocomotion`, `testHartLabelsWinWhereConfidentAndStrapFillsTheRest`, `testDayOwnershipIsTheLocalDayOfTheStart` |
| Cadence (wrap-aware counter) | `testCadenceFromTheStepCounter` |
| 24/48/72 h windows with partial / unknown coverage | `testTrailingWindowsReportPartialAndUnknownCoverage`, `testFullyObservedWindowWithoutMotionSaysSo` |
| V14 reduced activity with reduced wear | `testV14ReducedActivityWithReducedWearIsMissingnessNotDecline`, `testTotalsAreUnavailableUnderReducedWearWhileRatesAreComputed` |
| Wear / sleep denominators, partial day | `testFullWearDayFeatures`, `testNoWearEvidenceGivesNoDenominatorAndNoValues`, `testCausalPartialDayIsNeverATotal`, `testUnknownSleepIsNotSilentlyExcluded`, `testPausesAndCadenceAggregateFromBouts` |
| Registry: specialized unavailable with missing evidence | `testRegistryDeclaresRequirementsAndValidationStatus`, `testSpecializedFeaturesAreUnavailableWithTheMissingEvidenceNamed` |
| JSON round trip, old JSON decodes | `testBoutsRoundTripThroughTheCanonicalCodersAndOldJSONDecodes`, `testSummaryRoundTripsAndOldJSONDecodes`, `testBoutFlowsThroughTheDocument` |

A mutation check (removing the `next_bout` event, the break check in pause bridging, and the continued-movement
event) made the V08, break and V07 continued-movement tests fail, as intended.

## Commands and results

Run in `Packages/StrandAnalytics`:

- `swift build` — Build complete.
- `swift test --filter "PCExertion|PCFunctional"` — 31 tests, 0 failures.
- `swift test --parallel` — 2579 XCTest cases, exit 0, no failures (includes the 5 lead `PCEngineTests`).
- Probe (not committed): 60 h read window, 24 k strap spans, 216 k HR and step samples → detect 0.04 s, functional
  0.06 s (debug build).

## Requests to the lead

1. `Engine.motionCoverage`: set `DayCoverage.observedIntervals` for today (merged covered spans of the tracks) so
   trailing windows clip today exactly instead of prorating (in causal mode proration over the whole day
   under-estimates the observed part).
2. Bout / daily-value finality: bouts use the same 30 h rule as `documentFinality` via `ExertionConfig.finalAfterDayEndS`;
   if the document's finality should override, the engine can overwrite `bout.finality`.
3. Consolidate the reason codes above into `contracts.md` §12, and the series keys `hr_response.<match key>`,
   `hr_recovery_60s.<activityKind>` and the `functional.*` list into §5.
