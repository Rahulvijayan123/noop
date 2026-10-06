# Review repairs — signal, eligibility and functional (fix-signal)

Branch `pc/fix-signal` from `204ea2c3`. Repairs findings of `review-contract.md` and `review-statistics.md` in
`PCSignalValidity.swift`, `PCEligibility.swift`, `PCExertionBouts.swift` and `PCFunctional.swift`
(`PCMotionEvidence.swift` unchanged). Versions: `pc-validity-2`, `pc-eligibility-2`, `pc-functional-2`
(`pc-exertion-1` and `pc-motion-1` unchanged). Details: `signal.md` §2, §4–§6, §8 and §12; `responses.md` (System D
reason order, System G denominators, request 4).

## Findings

| Finding | Repair | Tests | Status |
| --- | --- | --- | --- |
| RC-05 (M) first eligibility reason is a note | `Eligibility.Builder` keeps fails, unknowns, positives and notes apart. `reasons` = deciding reasons first (fails then unknowns; the positive reason when eligible), then the non-deciding ones, which are also in the new `EligibilityVerdict.notes` (default `[]`, not written when empty, old JSON decodes). `decidingReasons` helper. Activity response's positive reason is now deciding when eligible, a note when the verdict failed. | `testRC05_…`; `PCEligibilityTests.testDecidingReasonsComeFirstAndNotesAreSeparated` | fixed |
| RC-06 (L) censored bout's first reason is alphabetical | `ExertionBout.reasons` starts with the status reason (`bout_ongoing`, `recovery.censoring.first`, or `insufficient_follow_up_samples`), then the rest sorted. | `testRC06_…`; assertions added to the V07 disconnect and ongoing tests | fixed |
| RC-11 (H) no motion evidence published as zero activity | Rates divide by **motion-observed worn waking time** (worn waking seconds with a known HR-independent label; strap labels count only when a step counter reported, since the strap cannot label locomotion without one). Below 4 h, or 0, the rates are nil with `motion_evidence_unavailable`, `locomotion_unobservable_without_step_counter` or `insufficient_motion_observed_time_for_rates`; nothing is published. Totals also need motion-observed worn time ≥ 70 % of waking time (`insufficient_motion_coverage`). Registry `missing` names the blockers. Summary fields `motionObservedWornWakingS`, `motionObservedShare`. V14 semantics unchanged (wear floors, missingness reasons). | `testRC11_…`; `PCFunctionalTests.testNoMotionEvidenceGivesNoRatesAndNoZeroValues`, `testRatesDivideByMotionObservedWornTime`, `testStrapMotionWithoutAStepCounterCannotShowLocomotion` | fixed |
| RC-20 (L) numerator and denominator over different minutes | Locomotion seconds and transitions are counted over the worn waking pieces only; `bouts_per_worn_hour` counts bouts overlapping them. | `testLocomotionOutsideWornTimeIsInNeitherNumeratorNorDenominator` | fixed (the bag-carried strap without an off-wrist event still counts as worn through locomotion: documented limitation) |
| R-F8 (low-med) selection accounting | Exclusion reasons count only deciding reasons (`decidingReasons`). New `SelectionSummary` fields `eligibleShare` (the old meaning), `enteredCount`, `enteredSupportS`, `enteredObservedS`. `representedShare` now = observed time inside envelopes that entered a daily value of the comparison (`*.stable_awake_*`, nightly series), nil for pairs with no envelope reference series (activity response). `selection(…, dailyValues:reference:)`; without values it rebuilds them with `ContextReferences.dailyValues`, so no engine change was needed. | `testReviewRepresentedShareReflectsWhatEntersReferences` (unchanged, passes); `PCEligibilityTests.testSelectionCountsWhatEnteredTheDailyValues` | fixed; request R6 |
| P1 (H plausible) + RC-21 (L) target-dependent gates undeclared | `targetDependentGates` is per verdict: `signal_invalid` always, plus `hr_plausible_band` (HR samples outside 30–220 bpm), `rr_kernel_range` and `ectopic_rejection` (HRV beats rejected) when the assessment applied them, and `sleep_detector_hr_confirmation` / `wear_from_heart_rate_presence` for optical-pulse metrics whose sleep / wake or required wear came from HR evidence. Availability-matrix rows declare the same gates. Selection-bias paragraph in `signal.md` §6. | `testTargetDependentGatesAreDeclaredWhenTheyApply`, `testSustainedHighHeartRateBeatsDeclareTheKernelRangeGate`, `testEngineDeclaresTheSleepDetectorGateOnNightlyHeartDerivedVerdicts` | declared; **not evaluated** (needs real days, `signal.md` §6) |
| RC-17 (L) placement scope | `regimeTimeline` resolves device-scoped records (`scope` nil / `device`) and account-level records (`account`) separately; device spans win wherever they exist, account spans fill only the rest; within a scope, revision → `recordedAt` → id. `PlacementSegment.scope = account` marks the fallback. | `PCSignalRegimeTests.testDeviceScopedPlacementWinsOverAnAccountLevelOneWhereTheyOverlap` | fixed |
| RC-13, RC-22 | worker / app | — | not in this lane |

## Test expectations changed

- `PCReviewContractRegressionTests.testRC02_…` (lead's regression test): the **fixture** gained a quiet strap motion
  stream and a non-counting step counter over its 5 worn hours. Its old fixture had heart rate only, so it relied on
  functional daily values existing without any motion evidence — exactly what RC-11 forbids. The assertion (one
  regime key whatever measurement families exist) is unchanged.
- `PCEligibilityTests.testSelectionCountsUnionOfEligibleSupportAndRepresentedShareOfObservedTime`: its hand-built
  unknown verdict now marks `recent_locomotion_unobserved` as a note, so it is no longer an exclusion reason; the
  eligibility-level 0.6 moved to `eligibleShare`, and `representedShare` is 0 (two overlapping windows give no daily
  value).

## Requests to the lead

1. **R6** — pass `dailyValues: dailyValues, reference: policy.reference` to `Eligibility.selection` in
   `Engine.buildDay` (correct today only under the default `ReferenceConfig`). If the statistics repair changes the
   signature of `ContextReferences.dailyValues`, `Eligibility.enteredEnvelopes` needs the same change.
2. **Functional version in the regime** (`responses.md` request 4): `pc-functional-2` changes rate denominators but
   `deviceRegimeKey` carries no product version.
3. `contracts.md` §13 versions (`pc-validity-2`, `pc-eligibility-2`, `pc-functional-2`) and §12 reason codes (new
   gate and functional codes, `EligibilityVerdict.notes`, the `SelectionSummary` fields).
4. App (RC-15 family): phrases for the new codes; optionally label `verdict.notes` in the detail view. The card needs
   no change, since `reasons.first` is now the deciding reason.
5. System F (statistics): the exclusion of degraded stable-awake windows is System F's own target-dependent gate. It
   is now measured (eligible vs entered), not declared on verdicts.

## Residual limitations

- Out-of-kernel-range beats still count as "rejected", so sustained HR > 200 or < 30 bpm can make HRV `invalid`
  (declared, kept with diagnostics, not given its own non-artifact state).
- The gates are declared whenever they acted on the input. That is a superset of "changed the state".
- The step-counter rule is per day: a counter that stops reporting part-way through the day still makes the strap's
  later labels count as locomotion-observable.

## Commands and results (in `Packages/StrandAnalytics`)

| Command | Result |
| --- | --- |
| `swift test --filter "PCSignal\|PCMotion\|PCEligibility\|PCExertion\|PCFunctional\|PCReviewContract\|testReviewRepresentedShare"` | 130 tests, 0 failures. Before the repairs, 5 of them failed: RC-05, RC-06, RC-11 and R-F8. |
| `swift test --parallel` | 2804 tests. 8 failures, all statistics-owned `PCReviewStatsRegressionTests`: R-F1, R-F1b, R-F2, R-F3, R-F4, R-F6/P4, R-F7 and P2. `testReviewRepresentedShareReflectsWhatEntersReferences` passes. |

Not run: worker, backend and app suites (no files there changed; the app's `PhysiologyContextAppTests` builds
`EligibilityVerdict` through the unchanged initializer), and real-data replay (no authorized days here).
