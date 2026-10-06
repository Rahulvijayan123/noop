# Repairs: independent statistics review (System F)

Owner: statistics workstream. Branch `pc/fix-stats` from `204ea2c3`. Findings:
[review-statistics.md](review-statistics.md). Method and the re-run tables: [statistics.md](statistics.md) (§2.2,
§2.3, §2.5, §3.1, §4, §6, §7). Versions are now `pc-reference-2` and `pc-change-2`.

Everything here is verified on arithmetic and on synthetic series only. Nothing moves System F beyond
*implemented / arithmetic-tested*.

## Findings and repairs

| ID | Status | Repair | Regression tests |
| --- | --- | --- | --- |
| R-F2 cold start | Repaired | **Burn-in.** A scored day enters the detectors (CUSUM, persistence rule, excursions) only when the loaded history of its series began ≥ 28 days earlier (`detectorMinLookbackDays`), so its whole rolling window is loaded. Earlier days keep their display distance; entries say `detector_burn_in`. φ̂ falls back to 0.5 until estimable (R-F9). With the worker's 160-day load (90 + 14 + 56) a long-running series' document is **identical** to the evaluated full-lookback path. A reset (gap, regime boundary) on a non-detector day now carries to the next detector day. | `testReviewNinetyDayHistoryLoadInflatesFalseEpisodesVersusEvaluatedPath` (passes: 90-day load 0.217 vs full 0.297 docs with ≥ 1 episode, φ = 0.3, 300 reps); `testColdStartDaysAreScoredForDisplayButDoNotFeedTheDetectors`; `testWorkerHistoryLoadReproducesTheEvaluatedFullLookbackPath`; `testDocumentsBuiltFromTheWorkerHistoryLoadShowTheEvaluatedPath` |
| R-F9 sparse φ̂ | Repaired | **Gap-aware φ̂ plus a conservative fallback.** φ̂ pairs consecutive supported days ≤ `maxGapDays` (7) apart, the steps the CUSUM takes without a reset; with days missing at random the observed sequence is AR(1)-correlated with E[φ^gap], so the long-run factor is the right one. Below 20 pairs the CUSUM uses `autocorrelationFallback = 0.5` (`autocorrelation_assumed_conservative`), never "no adjustment". | `testMissingAutocorrelationEstimateUsesTheConservativeFallbackNotNoAdjustment`; `testSparseSeriesAndStartUpKeepTheNullRateBounded`; `testReviewPrintSparseAndFallbackRates` (numbers below) |
| R-F1 floors | Repaired | Native-resolution floors: `hr_recovery_` 1 bpm; `functional.*` by units (one count in the minimum denominator for rates, 1 for counts, 60 s / 30 s for seconds, 1 /min cadence, 0.01 CV); unlisted identity series max(2 % · \|center\|, 1 native unit) and unlisted ln series 0.05, both with `scale_floor_default`. 20 bout-free days then one bout in 4 h: z = 1 (was ≈ 250 000). | `testReviewZeroCenteredFunctionalSeriesMustNotGetMicroscopicScaleFloor`; `testReviewRecoverySeriesGetsTheIntegerBpmFloor`; `testCountAndRateSeriesGetNativeResolutionFloorsNotMicroscopicOnes` |
| R-F3 | Repaired | `hr_recovery_<s>s.*` → `heart_rate`, `exertion_bouts` (so `heart_rate`, `optical_pulse`, `strap_motion`). | `testReviewRecoverySeriesSharesHeartRateWithStableAwakeHeartRate`; `testEverySeriesKeyTheEngineEmitsMapsToADeclaredDependenceGroup` (fails on any undeclared key) |
| R-F4 | Repaired | `functional.*` → `functional_features` + `sleep_detector`, `sleep_wake`, `wear_state` (every functional value needs ≥ 4 worn waking hours; rates divide by them). Stable-awake series also get the awake-and-worn members (the P1 dependence). `selection_reads_heart_rate` covers nightly, stable-awake and functional series. The engine's `optical_pulse` note is used through the `heart_rate` metric. | `testReviewFunctionalRatesShareTheSleepDetectorWithNightlySeries`; `testOnlySeriesWithoutSharedDeclaredInputsCountAsSeparateGroups` |
| R-F7 | Repaired (with the lead's engine change) | A registered frozen reference for (series, regime, version) is the authority: no second one is ever registered; days inside or before its window get `unavailable` + `frozen_window_not_complete_for_day`. Episodes use the same authority. | `testReviewBackfilledDayUsesTheSameFrozenReferenceAsLaterDays`; `testRegisteredFrozenReferenceIsTheAuthorityAndBackfilledDaysNeverRegisterAnother` |
| P4 | Repaired | Causal mode ignores frozen references created for the day or later, or whose window ends on or after it (`frozen_created_after_day_ignored`), in `compare` and `episodes`. | `testReviewCausalCompareRejectsFrozenReferenceCreatedAfterTheDay`; same reference test |
| P2 | Repaired (provisional rule) | Causal parents of day-accumulating series (`.stable_awake_`, `functional.`) keep their reference but carry no distance (`partial_day_composition`; ready → provisional) and stay out of that day's episodes (`partial_day_value_excluded`). The like-for-like causal view is the time-band stratum (conditioned). Chosen because daily values carry no local-time coverage, so history cannot be restricted to the same slice. | `testReviewCausalPartialDayStableAwakeValueIsComparedLikeForLike` (z now nil); `testCausalPartialDayAccumulatingValuesCarryNoDistance`; `testCausalPartialDayValueStaysOutOfTheEpisodes` |
| P9 | Repaired | `ChangeEpisode.detectionDelayDays` renamed `alarmAfterStartDays` (alarm − detector start; old key decodes). The step table reports it next to the true delay (alarm − step). | `testSustainedStepIsAPersistentShiftWithItsDelayAndMagnitude` |
| R-F5 | Repaired by the lead (`204ea2c3`) | — | `testReviewHeartRateWindowsKeepContractValidBradycardia` passes |
| R-F8 | Signal workstream | — | `testReviewRepresentedShareReflectsWhatEntersReferences` still fails (not mine) |
| P1, P3, P5, P6, P10 | Open | Not in this repair list; P1 and P3 are restated in statistics.md §8. | — |
| P7, P8 | Documented | See below and statistics.md §7. | — |

## Test expectations changed, and why

- `PCChangeDetectionTests.testOnlySeriesWithoutSharedDeclaredInputsCountAsSeparateGroups` asserted that nightly HRV
  and `functional.bouts_per_worn_hour` are 2 groups under the engine's notes. That encoded R-F4. The mechanics are now
  tested on explicit notes where the two share nothing (2 groups), and the engine's notes give 1.
- `testReviewNinetyDayHistoryLoadInflatesFalseEpisodesVersusEvaluatedPath` is **unchanged**: it still models a
  90-day load. That is the stricter check (a short or truncated load must not inflate false episodes), so it stays.
  The 160-day load the worker now uses is covered by two new tests that require the document to be *identical* to
  the full-lookback path.
- `testReviewPrintSparseAndFallbackRates` and `testReviewPrintHighReplicateRechecks` print numbers and gate nothing.
  They now run only with `REVIEW_PRINT=1`: the 2000-replicate re-check takes about 11 minutes in a debug build.
- `PCChangeDetectionTests.testSustainedStepIsAPersistentShiftWithItsDelayAndMagnitude` reads the renamed field.

## Re-run numbers

`PC_EVAL_REPORT=1 swift test --filter PCEvaluationReportTests` (seed 20261005, 400 replicates; full tables in
statistics.md §6). **No default changed**; the reasons are in statistics.md §7.

| Cell | `pc-change-1` | `pc-change-2` |
| --- | --- | --- |
| Null CUSUM / series-week, dense, φ = 0 / 0.3 / 0.5 | 0.030 / 0.030 / 0.022 | 0.029 / 0.029 / 0.021 |
| Null, φ = 0.3, 30 % missing | 0.022 | 0.021 |
| Null, 50 % missing, φ = 0 / 0.3 / 0.5 (R-F9) | not reported (review: 0.050 at φ = 0.5, seed 99173) | 0.010 / 0.013 / 0.011 |
| Null, 70 % missing, φ = 0.5 | — | 0.000 (CUSUM effectively silent) |
| Null counted from day 0 (start-up included), φ = 0 / 0.3 / 0.5 | — | 0.027 / 0.027 / 0.019 |
| Document with ≥ 1 CUSUM episode, φ = 0.3: 90-day load / 160-day load / full lookback | review: 55 % / — / 31 % | 20 % / 30 % / 30 % (160-day ≡ full) |
| 2-SD step missed, φ = 0 / 0.3 / 0.5 | 0 / 5 / 20 % | 0 / 5 / 21 % |
| 2-SD step missed, φ = 0.3, 30 % / 50 % missing | 21 % / — | 18 % / 47 % |
| 2-SD step, φ = 0.3: true delay / documents' `alarmAfterStartDays` (medians) | 7 / — | 7 / 10 days |
| Drift: frozen z / rolling z, φ = 0.3 | −3.06 / −0.70 | −3.06 / −0.70 |
| Artifact → transient only, φ = 0.3 | 92 % | 92 % |

Reviewer print tests (`REVIEW_PRINT=1`), current code: null CUSUM per week at seed 99173, 200 replicates, φ = 0.5
dense 0.024 (0.021–0.026), **φ = 0.5 with 50 % missing 0.012 (0.010–0.015)** (was 0.050), φ = 0.3 with 50 % missing
0.012 (0.010–0.014) (was 0.030). 2000-replicate re-checks (seed 20261005 / 31337): 2-SD missed at φ = 0.5
23.1 % / 24.2 %, 1-SD at φ = 0.5 63.5 % / 66.7 %, 2-SD at φ = 0.3 4.7 % / 5.5 %; artifact CUSUM alarms ≤ 14 d with /
without at φ = 0: 7.4 / 6.2 % and 7.0 / 5.0 % (P8, now stated in statistics.md §6–7), at φ = 0.3: 6.2 / 6.2 % and
5.9 / 6.4 %. The R-F2 regression (φ = 0.3, 300 replicates): documents with ≥ 1 CUSUM episode 21.7 % with a 90-day
load vs 29.7 % with full lookback; episodes starting before D−56 fell from 180 of 262 (review) to 5 of 68.

## Requests to the lead

See statistics.md §12. In short: contracts §13 versions (`pc-reference-2`, `pc-change-2`) and §5 series keys
(`hr_recovery_60s.<kind>`); methods.md §7, §9 and §12.1 to follow statistics.md; keep the worker's history load at
160 days; optionally mark causal daily values built before the day end so complete-day causal values can keep a
distance (P2), and optionally add `sleep_detector` to the `strap_motion` note.
