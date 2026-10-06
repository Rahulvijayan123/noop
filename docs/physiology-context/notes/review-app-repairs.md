# App wording repairs after the independent reviews

Branch `pc/fix-app`, from `204ea2c3`. Inputs: [review-contract.md](review-contract.md) (RC-06 app side, RC-14,
RC-15, RC-16 app side, RC-19, RC-22) and [review-statistics.md](review-statistics.md) (P6). Spec §16, contracts §9.
Only app files changed: the four `Strand/Screens` context files and their tests. No package, worker or database
change.

## Findings and repairs

| ID | Repair | Test |
| --- | --- | --- |
| RC-15 | `PhysiologyContextWording.reasonPhrases` (a dictionary keyed by raw code) and `diagnosticsOnlyReasons` (a set) together cover every code in the 11 registries: IntervalAlgebra, Engine, SignalValidityEngine, MotionEvidence, Eligibility, SleepRhythm, ExertionBouts, Exposures, ContextReferences, ChangeDetection and Functional. That is 319 unique codes: 280 have a plain phrase and 39 are diagnostics-only. Diagnostics-only codes cover input hygiene, motion basis, record resolution, estimators, detector names and daily-value provenance. `reasonList` and `topReason` drop them, and the Diagnostics "Reason codes" row lists them raw. That row now also includes the sleep/wear, wake, reference and day-status codes. The guessed names the first table carried were never emitted, so they are removed (`insufficient_stationary_share`, `recent_exertion`, `no_bout`, `signal_missing`, `walking_during_support`, `not_implemented`, …). An unknown code from a newer server still reads as humanized words, and the forbidden-term guard still applies to it. | `PhysiologyContextWordingCoverageTests` (4 tests): every registered code is phrased XOR diagnostics-only; no entry for an unregistered code; phrases are short, have no full stop, contain no `_` and make no forbidden, recovery, diagnosis or medication claim. `testDiagnosticsOnlyCodesStayInDiagnostics`: none of them reaches the card, detail or history. |
| RC-05 | The engine now handles this (deciding reasons first). The app keeps showing the first shown reason, skipping only diagnostics-only codes. | `testDiagnosticsOnlyCodesStayInDiagnostics` |
| RC-14 | A `denied` category with `deniedCoverage < 1` (or with no coverage reported) reads "Recorded as none for part of this period". The note says "33% of this period; the rest is not recorded", and the share is capped at 99%. The section footnote says which period the status covers: "the days before this measurement" for the envelope's coverage, or "this day". | `testAPartialDenialIsNotNoneForTheWholePeriod` |
| RC-06 | `boutStatus` shows `censoringCause`. That is `recovery.censoring.first`. If it is absent, it is the System D censoring code among the reasons (older documents), then `insufficient_follow_up_samples`, then plain "Follow-up incomplete". It is never the alphabetically first reason. | `testACensoredBoutNamesItsCensoringCause` |
| RC-16 | When the headline is a window with no comparisons of its own, the card may use the day's stable-awake comparison. It finds it in `document.comparisons` by the window's stable-awake series (`<metric>.stable_awake_<n>min`, same regime first; time-band strata excluded). The card says "Today's stable awake median: +6 ms vs your 28-day reference". The detail lists those rows as `day-reference-*`, with the note "Today's stable awake median, not this window alone". A window's own comparison, which exists when it is the day's only value, is still shown as its own. A nightly value never takes the day's stable-awake comparison. | `testAWindowShowsTodaysMedianComparisonOnlyAsTheMedians` |
| RC-19 | "Persistent change from historical reference" is shown only when the frozen reference found the shift or confirms it: `detector == "frozen_persistence"`, or the reasons include `frozen_reference_deviation`, `rolling_adapted_frozen_deviation_persists` or `frozen_and_rolling_agree`. Otherwise the text is "Persistent change from your recent usual range". The state-only wording never claims a historical reference. | `testPersistentChangeNamesTheReferenceItWasDetectedAgainst` |
| P6 | The reference centre reads "Reference 52 ms ± 2 ms (approx.)" (`referenceCenter`). | `testTheReferenceUncertaintyIsMarkedApproximate` |
| RC-22 | Posture classes read as likelihoods everywhere: "Likely standing", "Likely sitting" (also for `sitting_desk`) and "Likely lying down". Every decoder estimate is "Likely …", and its note says "A likely activity or posture, not a confirmed one." The availability row reads "Posture (likelihood only)", with "Arm orientation gives only a likely posture, never a confirmed one". The assessment names the engine actually emits (`spo2_signal_validity`, `respiratory_signal_validity`, …) now have names. | `testDecoderPostureIsShownAsALikelihood` |

## Integration review addendum (R8, R9, R11)

The lead extended ownership to `Strand/Push/PhysiologyContextRepository.swift` and `PhysiologyContextStore.swift`
for these items.

| ID | Repair | Test |
| --- | --- | --- |
| R8 | Polling uses a bounded backoff (`PhysiologyContextStore.pollDelaysS`, 30 s up to 180 s, about 15 min in total), where it used to stop after 10 × 30 s. That is longer than the server's ≥ 10 min re-queue cadence. `.task` cancels it when the card disappears. After the last read the card says "…The update is taking longer than usual. Check back later." (stale) or "…Check back later." (pending), never "on its way". `Job` now decodes `dead_letter`, `leased`, `input_revision`, `completed_revision` and `reasons`. A dead-lettered day with no document, or with a stale one, is `unavailable(.processingFailed)`: "Context unavailable for this day.", not polled, and a failed re-read keeps it. A current document with a dead-lettered job stays available. The detail then says "Couldn't be updated with the latest data", and Diagnostics shows the job. | `testADeadLetteredJobIsUnavailableNotOnItsWay`, `testPollingCoversTheServersCadenceAndThenSaysCheckBackLater` |
| R9 | A 404 on either context route maps to `.unsupportedServer`, like 405, and ends the candidate walk. This is the new-edge-function, missing-migration case. | `testAMissingContextMigrationsFourOhFourIsUnsupportedNotAnError` |
| R11 | The detail's "Local day" is `document.header.identity.day`, the day that owns the document, where it used to show the night's start date. When the support crosses midnight, a note gives "From <start date, time> to <end date, time>". | `testTheDetailsLocalDayIsTheDayThatOwnsTheDocument` |

The existing tests now use registered codes in place of the retired guessed names. Persistent-shift fixtures that
expect the historical phrase now carry a frozen detector or frozen reason. The forbidden-words test now covers every
registered code. It also covers the partial-denial, median, approximate-centre and likelihood strings, plus a frozen
and a rolling persistent episode.

## Results

See "Results" in [app.md](app.md).

## Not done here: merging `pc/fix-signal`

`pc/fix-signal` (aaae6cd0) adds reason codes, verdict notes and new versions. It was not merged into this branch,
because the session's permissions blocked the merge and any read of that branch. After the lead merges it,
`PhysiologyContextWordingCoverageTests.testEveryRegisteredReasonCodeHasAPhraseOrIsDiagnosticsOnly` lists every new
code that has no phrase. `testTheTableCarriesNoCodeTheEngineNeverEmits` lists every code the merge removed. Add or
remove those entries in `reasonPhrases` / `diagnosticsOnlyReasons`. No screen reads `representedShare`.

