# Physiology context — validation

Acceptance and verification mapping, the checks actually executed, the independent reviews and how each finding was
resolved, performance, and the evidence limits (spec §18–§20.4). **Passing tests here are arithmetic and integration
evidence. Nothing in this document is evidence of real-world accuracy, disease validity or clinical usefulness.**

- [1. Readiness](#1-readiness)
- [2. Acceptance criteria](#2-acceptance-criteria)
- [3. Verification cases V01–V17](#3-verification-cases-v01v17)
- [4. Executed checks](#4-executed-checks)
- [5. Independent reviews](#5-independent-reviews)
- [6. Performance](#6-performance)
- [7. Evidence limitations and blockers](#7-evidence-limitations-and-blockers)

## 1. Readiness

Columns (spec C12): **implemented** — code exists and runs; **input-eligible** — the inputs it needs exist for real
WHOOP users today; **arithmetic-tested** — unit / property tests with independently derived expectations;
**integration-tested** — exercised through the real worker, Postgres, edge handler or app code paths;
**accuracy-validated** — compared against an independent reference on held-out data; **clinically validated** —
validated for an intended use in an intended population. **Y** = evidenced here, **partial** = evidenced for part,
**N** = not done, **NOT RUN** = never a pass. No cell is inferred.

| Product | Implemented | Input-eligible | Arithmetic-tested | Integration-tested | Accuracy-validated | Clinically validated |
| --- | --- | --- | --- | --- | --- | --- |
| Shared envelope, whole-interval join, causal cutoff | Y | Y | Y | Y (worker DB, real-night replay) | N | N |
| A — HR / HRV / respiratory / skin-temperature validity | Y | Y | Y | Y | NOT RUN | N |
| A — SpO2 candidate, PPG waveform quality, core temperature | Y (explicit `unverified` / `unsupported`) | N (no qualified input) | Y | Y | N | N |
| A — measurement regimes, placement, comparability | Y | partial (family / firmware not written for push devices) | Y | Y | N | N |
| A — HR-independent strap motion evidence | Y | Y (gravity on all straps; steps on 5.0/MG) | Y | Y | NOT RUN | N |
| B — stable-awake / sleep / activity-response eligibility | Y | partial (awake and wear evidence are heart-derived) | Y | Y | NOT RUN | N |
| C — sleep episodes, wake-relative timing, sleep loss / timing | Y | Y | Y | Y | NOT RUN | N |
| C — circadian phase | N (proxy only; phase `unavailable`) | N | — | — | N | N |
| D — exertion bouts, HR response, recovery censoring | Y | partial (cadence needs 5.0/MG steps; HART epochs only with the activity lane) | Y | Y | NOT RUN | N |
| D — respiratory response during movement, HRV during recovery | N (explicitly unavailable) | N | Y (unavailable state) | — | N | N |
| E — revisioned exposure events, timing, aligned summaries | Y | Y (journal, caffeine, editor) | Y | Y (route, SQL, real-stack e2e when the stack runs) | — (no accuracy claim) | N |
| F — recent / rolling / frozen / conditioned references | Y | Y | Y | Y | NOT RUN | N |
| F — persistent-change episodes | Y | Y | Y (synthetic evaluation §6 of statistics notes) | Y | NOT RUN (no labelled real changes) | N |
| G — general functional features | Y | partial (locomotion needs motion + step counter) | Y | Y | NOT RUN | N |
| G — specialized features (gait speed, stride, tremor, respiratory events, autonomic, symptom classifier) | Registered, always `unavailable` | N (missing sensors / labels named) | Y (unavailable state) | — | N | N |
| Persistence, invalidation, routes | Y | — | — | Y (SQL suites, route tests, worker DB tests) | — | — |
| App card / detail / history / exposure editor | Y | — | Y (view models, wording coverage) | Y (stubbed URL protocol with real stored bytes; real stack when it runs) | — | N |

Production status: **not deployed** — no migration applied to production, no function deployed, lane off by
default, branch not merged (rollout.md).

## 2. Acceptance criteria

| ID | Status | Evidence |
| --- | --- | --- |
| C01 seven systems with supported paths and explicit unsupported states | Met | §1 table; `availabilityMatrix` rows for PPG / SpO2 / core temperature / posture; specialized registry entries |
| C02 envelope preserves support, cutoff, provenance, uncertainty, revisions | Met | contracts §3; `PCEngineTests`, `PCRealReplayTests`, stored-form round trip |
| C03 metric/task-specific quality and eligibility; no favourable-value selection | Met, with declared heart-derived gates | `testEvaluateNeverReadsTheValue`, `testStableAwakeWithElevatedHeartRateAndLowHrvStaysEligibleAndValid`; gates in `targetDependentGates` (methods §3) |
| C04 joins reconcile whole interval and history incl. missing / mixed | Met | `PCIntervalAlgebraTests` (property test over random overlapping revisions), replay reconciliation |
| C05 distinct, reproducible, leakage-resistant references | Met | `PCReferenceTests` V10 cases, frozen authority regressions, burn-in regression |
| C06 response / recovery and functional features from actual bouts with missingness and censoring | Met | `PCExertionBoutsTests` V07/V08, `PCFunctionalTests` V14, RC-11 regression |
| C07 exposure corrections and temporal dependencies invalidate and replay | Met | `PCExposureTests` V09, `exposure_events_sql_test.ts`, worker `testAnExposureCorrectionRevisesTheDay`, cascade steps |
| C08 persistence, worker, API and app wired end to end | Met at integration level | §3 V17 |
| C09 ingestion, scoring authority, provider gates, owner isolation, old clients compatible | Met | worker `testAFailingContextLaneDoesNotStopScoring`; candidate lane untouched; RLS / auth isolation; 405 / 404 handling |
| C10 verification cases have evidence or a named blocker | Met | §3 |
| C11 independent reviewers; actionable defects repaired | Met | §5 |
| C12 readiness table separates evidence levels; nothing unrun marked passed | Met | §1 |

## 3. Verification cases V01–V17

| ID | Evidence (tests) | Result |
| --- | --- | --- |
| V01 transitions, gaps, overlapping revisions | `PCIntervalAlgebraTests` (11 cases incl. random property test), `testRC12_tiedEpochRecordsResolveIndependentlyOfInputOrder`; replay reconciliation on 8 real nights | Pass |
| V02 quiet IMU, unknown wear / sleep | `PCEligibilityTests.testQuietMotionWithUnknownWearAndSleepIsUnknownWithExplicitReasons`, `PCMotionEvidenceTests.testNoMotionMeansUncoveredNeverStill`, `testHeartRateDependentActivityIsNeverEligibilityEvidence` | Pass |
| V03 stable awake with elevated HR / low HRV | `testStableAwakeWithElevatedHeartRateAndLowHrvStaysEligibleAndValid`, `testEvaluateNeverReadsTheValue`, `testRC01_extremeHeartRateIsKeptInDerivedWindows` | Pass |
| V04 source / placement / firmware / method change | `PCSignalRegimeTests` (all), `testRC02_functionalRegimeKeyDoesNotDependOnWhichMeasurementsExist`, `testDeviceScopedPlacementWinsOverAnAccountLevelOneWhereTheyOverlap`, `PCReferenceTests.testOtherRegimeHistoryIsNeverPooled`, worker no-current-firmware test | Pass |
| V05 duplicate rows, equal RR, gaps, clock resets | `PCSignalSanitizeTests`, `testRepeatedEqualIntervalsInOneSecondAreDistinctBeatsWithValidAdjacency`, `testAGapSplitsRunsAndNoPairIsFabricatedAcrossIt`, `testRC10_…_holds` | Pass |
| V06 DST, travel, split sleep, naps, unfinished nights | `PCSleepEpisodeTests`, `PCSleepEvidenceSummaryTests`, `testLocalTimeHandlesDstAndZones`, worker DST test, RC-03 regressions (main-sleep support; `testASessionAggregateOverASplitNightLeavesTheGapBetweenFragmentsOut`, `testTheEngineLeavesTheGapOutOnlyForSessionAggregates`) | Pass |
| V07 workout ends in a disconnect / continued movement | `testV07RecoveryInterruptedByDisconnectIsCensoredWithoutTimeToReturn`, `testV07WorkoutEndingInsideADisconnectHasNoRecoveryAtAll`, `testV07ContinuedMovementAfterCessationTruncatesRecovery`, `testV07FollowUpBeyondTheCausalCutoffIsCensoredAndProvisional` | Pass |
| V08 nearby bouts, overlapping recoveries | `testV08EarlierRecoveryEndsAtTheNextBoutAndEachOutcomeCountsOnce`, `testV08IdsAndResultsAreStableAcrossRerunsAndInputOrder` | Pass |
| V09 exposure late / corrected / absent | `PCExposureTests` (late entry, correction keeps history and invalidates old + new days, retraction, unrecorded ≠ denied ≠ confirmed), `exposure_events_sql_test.ts`, app `ExposureEventTests` (18) | Pass |
| V10 future data appended to a historical replay | `PCEngineTests.testCausalReplayAtTheSameCutoffIgnoresLaterData` (byte-identical), reference / change "appending later days" tests, `testRC07_lateMeasurementDoesNotChangeTheCausalDocument`, worker `testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff`, real-night causal stability | Pass. Limitation: a causal replay after a later republish of an earlier day reads the republished history (review P5) |
| V11 artifact, step, drift | `PCChangeDetectionTests` (artifact transient, step persistent with delay, rolling adapts while frozen persists, drift), evaluation tables (methods §12.1) | Pass (synthetic) |
| V12 sparse, missing, constant histories | `testSupportStatesAreExplicitAndSparseHistoriesNeverScore`, `testConstantHistoryGetsTheFloorNotInfiniteCertainty`, R-F1 / R-F9 regressions | Pass |
| V13 shared inputs, circularity | `testHrvAndRespiratoryRateDeviatingTogetherAreOneIndependentGroup`, R-F3 / R-F4 regressions, "every series maps to a group" test, `testHeartDerivedEvidenceIsDeclaredInDependsOn` | Pass |
| V14 reduced activity with reduced wear | `testV14ReducedActivityWithReducedWearIsMissingnessNotDecline`, `testRC11_missingMotionEvidenceIsNotZeroActivity` | Pass |
| V15 retry, restart, backfill, correction, cross-day invalidation | Worker DB: `testRetryingTheSameInputsStoresNoNewRevision`, `testAWorkerThatDiesMidJobIsReplacedByOneThatPublishesOnce`, `testAnExposureCorrectionRevisesTheDay`; SQL: idempotent retry, restart, cascade horizons (values 28 + newest day, sleep 14, bouts 3), activity-day trigger, placement trigger; finality loop gone end to end (integration review) | Pass (see §4 for the final SQL run) |
| V16 two owners / devices, old clients, context failure | SQL RLS + PostgREST isolation; worker `testOwnersAndDevicesNeverSeeEachOthersData`, `testAFailingContextLaneDoesNotStopScoring`; route tests (405 unchanged); app 405 / 404 → unavailable | Pass |
| V17 end to end | (a) Worker DB test `testScoredDayBecomesAStoredContextDocumentWithItsProducts`: real ScoringLane → context lane → stored summary + tables → `physiology_context_read_v1`. (b) Integration review chain: real scoring + context lanes on Postgres → real `handleScoresRequest` through PostgREST with an installation bearer (`GET /context?metric=hrv_rmssd` 200, 273,617 B, `consistent: true`) → those exact bytes through the app repository, store and card models ("Sleep measurement", "Measured 9:00 PM–9:59 AM", "Qualifies for the sleep comparison", "−1 ms vs your 14-day reference", "Within usual variation"). (c) `NaraContextEndToEndTests` on the real-services stack: Supabase Auth sign-up with the emailed code → upload through `push` → strap confirmation → real worker scoring + context lanes → `GET /scores/context` through the app's repository (summary + every table joined, then a metric read with only its table) → card model → an exposure recorded in the app's store, uploaded by its sync, corrected (revision 2) → recomputed context lists both revisions; history route answers | (a) Pass, (b) Pass (history days in that chain were copied at the DB level, not engine-computed), (c) Pass on `92bb63e5` (§4.1). The stack's stored day had no HRV-from-sleep value (pre-existing scorer issue, §7), so (c) exercised HR / HRV / respiratory / resting-HR envelopes with `partial` status |

## 4. Executed checks

All on the development Mac (Apple Silicon, Xcode 26.3, Swift 6.2.4), local Docker / Postgres only. Dates 2026-10-05.

| Suite | Command | Result |
| --- | --- | --- |
| StrandAnalytics baseline (before any change) | `swift test --parallel` in `Packages/StrandAnalytics` | 2,530 tests, exit 0 |
| StrandAnalytics, integrated before review repairs | same | 2,767 tests, exit 0 |
| Context package tests after lead repairs | `swift test --filter PC` | 207 tests, 0 failures, 2 opt-in skipped |
| Real-night replay (8 de-identified nights, not committed) | `PC_REAL_REPLAY_DIR=… swift test --filter PCRealReplayTests` | Pass (table in methods §12.3) |
| Worker, integrated, with DB | `FRWHOOP_TEST_DB_URL=<scratch> swift test` in `Tools/CloudWorker` | 455 tests, 0 failures, 4 skipped (opt-in profiles) |
| Worker release profile | `FRWHOOP_CONTEXT_PROFILE=1 swift test -c release -Xswiftc -enable-testing --filter ContextLaneProfileTests` | §6 |
| SQL: context | `deno test -A --no-lock tests/physiology_context_sql_test.ts` (Docker pipeline, full ordered chain) | 15 steps pass before the lead SQL repairs; 17 after (§4.1) |
| SQL: exposures | `tests/exposure_events_sql_test.ts` | 6 steps pass |
| SQL: auth isolation | `tests/auth_isolation_sql_test.ts` | 11/12; the one failure is pre-existing (`activity_context_at` missing from `CLIENT_CALLABLE_FUNCTIONS`), identical before and after this migration; a copy listing it passes 12/12 |
| SQL: client privileges | `psql … -f supabase/tests/client-privileges.sql` | Fails only on pre-existing `compute_family_policy` (RLS off); ok with that excluded |
| Routes | `deno test --allow-env --allow-read --no-lock tests/physiology_context_routes_test.ts tests/activity_windows_route_test.ts` | 22 passed |
| App, full macOS StrandTests (before review repairs) | `xcodebuild test … -only-testing:StrandTests` | 2,913 tests, 7 skipped, 1 failure: `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets`, listed in docs/IOS.md as failing on a clean checkout |
| App context + exposure + wording coverage (after repairs) | `xcodebuild test … -only-testing:StrandTests/PhysiologyContextAppTests …/ExposureEventTests …/PhysiologyContextWordingCoverageTests` | 41 + 18 + 4 pass |
| iOS build | `xcodebuild -scheme NOOPiOS -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` | BUILD SUCCEEDED |
| Real-services e2e (existing `NaraEndToEndTests`) | `supabase/tests/e2e/stack.sh up` + `run_swift.sh` | 3 of 5 pass; `testSignupToScoredReadbackForOneAccount` and `testTwoAccountsStayIsolated…` fail **with the context lane off too**: the scorer reads 0 HR rows for the confirmed strap (`no_data: hr=0 rr=1800`), so no HRV series exists. Pre-existing on this checkout, not caused by this work (§7) |

### 4.1 Final integrated run

Every suite below ran on `92bb63e5` (all workstreams and repair branches merged, split-night repair included).
The scratch Postgres was rebuilt from the full ordered migration chain (`pipeline_db.sh down` + `up`) and reset
between suites. The app suites ran from a `git archive HEAD` copy on the internal disk, because hosted tests that
read their own sources hang on a removable-volume permission prompt when the checkout is on the external drive
(docs/IOS.md, `run_swift.sh`). That copy has no untracked `Config/*Secrets.xcconfig`, so the full `StrandTests` run is
a non-hosted build. For the real-services e2e the copy got a local config that only sets
`NOOP_FINAL_HOSTED_COMPUTE = YES` (no endpoint or keys; the tests inject the stack's), because capture is off in a
non-hosted build without the cloud override. It was deleted afterwards.

| Suite | Result |
| --- | --- |
| StrandAnalytics, full (`swift test --parallel`) | **2,852 tests, exit 0, no failures** |
| System C sleep suites after the split-night repair | 26 tests, 0 failures (2 new regressions) |
| Real-night replay (8 nights) | Pass; all 8 nights reconcile (table below) |
| Worker, full, with the scratch DB (`PKG_CONFIG_PATH=<libpq, openssl@3, zstd> FRWHOOP_TEST_DB_URL=… swift test`) | **479 tests, 0 failures, 4 skipped** (3 opt-in profiles + the PushBatch on-disk corpus); all 13 `ContextLaneDatabaseTests` with the DB ran and passed except the opt-in profile |
| SQL: context | **17 steps pass** (incl. cascade horizons by what changed, decoder-day trigger, touch clears a replay cutoff, real `scores` handler on the DB) |
| SQL: exposures | 6 steps pass |
| SQL: auth isolation | 11 of 12 steps; the one failure is the pre-existing `activity_context_at` listing (unchanged) |
| SQL: client privileges | Only the pre-existing `compute_family_policy` RLS error; every other check passes |
| Routes | 22 passed |
| App, full macOS `StrandTests` | **2,941 tests, 8 skipped, 1 failure**: the pre-existing `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` (docs/IOS.md) |
| App context + exposure + wording coverage | Pass inside the full run above (41 + 18 + 4 when run alone on `43d8c97d` + lead SQL; the coverage test now also checks the new `split_sleep_gap_excluded` phrase) |
| iOS build (`NOOPiOS`, generic iOS, Debug, no signing) | BUILD SUCCEEDED |
| Real-services e2e: `NaraContextEndToEndTests` (V17 c) | **Pass** (22 s): context revision 4, 49 envelopes (`heart_rate`, `hrv_rmssd`, `respiratory_rate`, `resting_heart_rate`), status `partial` (`activity_evidence_unavailable`, `sleep_evidence_unavailable`: the upload has no motion and no sleep); card "60-min window 2:50 AM–3:50 AM", "Can't tell whether it qualifies for the stable awake comparison: it is unclear whether you were awake", "No activity data for this measurement · signal 50%", "No reference comparison for this measurement yet"; the exposure correction produced a new revision listing revision 2 with both revisions kept |
| Real-services e2e: existing `NaraEndToEndTests` (same stack, context lane on) | 3 of 5 pass (relaunch / background upload, revoked installation + deleted account, account switching). `testSignupToScoredReadbackForOneAccount` and `testTwoAccountsStayIsolated…` fail with `no scored series within 180 s`; the worker logs `no_data: hr=0 rr=1800` for the 30-minute captures: the same pre-existing scorer issue as with the lane off (§7) |

Real-night replay on `92bb63e5`:

| Night | Envelopes | Valid | Degraded | Invalid | Sleep-eligible | Awake-eligible | Stored KB | Build ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-09-20 | 190 | 182 | 7 | 1 | 187 | 0 | 309 | 34 |
| 2026-09-22 | 49 | 47 | 2 | 0 | 47 | 0 | 100 | 7 |
| 2026-09-23 | 69 | 69 | 0 | 0 | 66 | 0 | 122 | 24 |
| 2026-09-30 | 212 | 207 | 4 | 1 | 210 | 0 | 395 | 36 |
| 2026-10-01 | 207 | 74 | 30 | 103 | 102 | 0 | 411 | 36 |
| 2026-10-02 | 213 | 100 | 9 | 104 | 98 | 3 | 439 | 39 |
| 2026-10-03 | 228 | 115 | 0 | 113 | 114 | 0 | 435 | 42 |
| 2026-10-04 | 119 | 118 | 1 | 0 | 118 | 0 | 230 | 19 |

These are invariant checks on one person's nights (reconciliation, causal stability, stored-form round trip), not
accuracy evidence. "Sleep-eligible" counts measurements the rules admit to the sleep comparison; no independent sleep
reference was available to check them against.

Not rerun on `92bb63e5`: the worker release profile (`ContextLaneProfileTests`, §6). Its numbers predate the
160-day history load and the hash-keyed pools. The worker agent measured the 160-day history read separately
(retrospective 26 ms index scan, causal 363 ms; notes/review-worker-repairs.md).

## 5. Independent reviews

Three fresh reviewers, none of them authors, reviewed commit `28f5e602`: statistics and leakage
([notes/review-statistics.md](notes/review-statistics.md)), contract and claims
([notes/review-contract.md](notes/review-contract.md)), backend / worker / app integration with executed end-to-end
checks ([notes/review-integration.md](notes/review-integration.md)). Their scratch tests are kept as regression tests
(`PCReviewStatsRegressionTests`, `PCReviewContractRegressionTests`). Repairs were made by the lead and by four fresh
repair workstreams (notes/review-*-repairs.md).

| Finding | Severity | Resolution |
| --- | --- | --- |
| R-F2 cold start in every document | high | Fixed: burn-in until the 28-day window is covered; worker loads 160 days; document = evaluated path |
| R-F1 microscopic scale floors | med-high | Fixed: unit floors for functional / bout series, default floor with reason |
| R-F9 sparse φ̂ fallback | medium | Fixed: gap-aware φ̂, conservative φ = 0.5; sparse sensitivity loss now documented |
| R-F5 / RC-01 HR windows dropped valid samples | medium | Fixed (engine) |
| R-F3 / R-F4 dependence mapping | medium | Fixed; every series must map to a group |
| R-F7 / P4 frozen reference authority | medium / low | Fixed (engine + references) |
| R-F8 selection accounting | low-med | Fixed (`representedShare` = entered a daily value; `eligibleShare` beside it) |
| P1 / RC-21 HR-selected nightly series; undeclared value gates | high (plausible) | Declared per verdict (`targetDependentGates`); **not evaluated** — needs real labelled data (§7) |
| P2 causal partial-day comparisons | medium | Fixed: no distance on unfinished days |
| P3 causal frozen built from retrospective values | medium | Accepted and documented: the reference was available at the cutoff |
| P5 / RC-18 causal replay after a later republish / placement edit | low | Documented limitation (history rows and placement ends are current-state) |
| P6 bare "±" | low | Fixed ("(approx.)") |
| P7 uneven persistence-rule comparison | low | Documented in statistics notes |
| P8 artifact effect at φ = 0 | low | Documented with 2000-replicate numbers |
| P9 delay field meaning | low | Fixed (renamed `alarmAfterStartDays`) |
| P10 noisy recent z | low | Documented |
| RC-11 missing motion read as zero activity | high | Fixed: motion-observed denominators; unavailable, never 0 |
| RC-02 unstable regime key for device-level series | high | Fixed: device regime key with product version |
| RC-03 nightly hull support dropped nap / split days | high | Fixed: worker main-sleep support for nap days; split nights by the lead (session aggregates are judged without the gaps between fragments, `pc-sleep-2`) |
| RC-04 fingerprint missed inputs | medium | Fixed: every input through the canonical encoder |
| RC-05 / RC-06 first reason not the deciding / censoring one | medium / low | Fixed (engine ordering + app) |
| RC-07 late measurement left a trace in causal documents | low | Fixed |
| RC-08 stored-form edge cases | low | Fixed (explicit flag, wrapping times, partial rebuild keeps the index, canonical order) |
| RC-12 non-unique tie-breaks | low | Fixed |
| RC-13 current firmware stamped on old days | medium (latent) | Fixed (firmware unknown until an effective-dated source exists) |
| RC-14 partial denial shown as "none" | medium | Fixed (app) |
| RC-15 reason phrase table mismatch | medium | Fixed: generated coverage test over all 334 registered codes |
| RC-16 day median shown as one window's difference | medium | Fixed (engine attach + app wording) |
| RC-17 placement scope | low | Fixed |
| RC-19 "historical reference" wording | low | Fixed |
| RC-20 functional numerator / denominator minutes | low | Fixed with RC-11 |
| RC-22 posture shown without likelihood | low | Fixed ("Likely …") |
| R1 transient input failure published as complete | high | Fixed (worker: only missing schema objects are "unavailable"; everything else fails and retries) |
| R2 cascade shorter than episode horizon | medium | Fixed: newest retrospective day refreshed after a values change; episodes in intermediate historical documents reflect history as known when they were built (documented) |
| R3 lock-order deadlock | low-med | Fixed: all job-touching paths apply in (user, device, day, mode) order |
| R4 fingerprint-only change never bumps | low-med | Fixed for decoder day documents (trigger); placement had a trigger already; comment corrected |
| R5 bouts-only change no cascade | low-med | Fixed (3-day horizon) |
| R6 prior sleep outside the fingerprint | low | Fixed via the 14-day sleep-episode cascade |
| R7 card trusts server pairing | low | Accepted: the hero and the pairing read the same latest snapshot; documented |
| R8 polling shorter than server cadence; dead letter | low | Fixed (backoff to ~15 min, dead letter shown as unavailable) |
| R9 404 with missing migration | low | Fixed (unsupported, not an error) |
| R10 replay cutoff survives bumps | low | Fixed |
| R11 local day label | low | Fixed |

## 6. Performance

Release build, Apple Silicon development Mac, worker profile (`ContextLaneProfileTests`), measured under heavy
concurrent load from other sessions (load average up to ~100), so times are upper-bound indications.

| Case | Context time | Stored size | Scoring on the same streams |
| --- | --- | --- | --- |
| Representative full day (86,400 HR, 92,775 beats, 86,400 gravity + steps, 90 days history), retrospective | 3.1 s (assemble 138 ms, build 1,274 ms, split + encode 1,666 ms) before hash-keyed pools; earlier quiet-machine run 1.0 s | summary 110 KB + tables 3.9 MB (plain 14.3 MB) | 400 ms in memory |
| Same, causal at 20:00 | 2.2 s | 87 KB + 3.2 MB | — |
| Largest read window (60 h at 1 Hz, two R-R transports, 7,200 HART epochs, 2,000 decoder runs, 200 exposure revisions) | 10.0 s before hash-keyed pools | 369 KB + 3.8 MB (largest table 2.1 MB, under the 16 MiB cap) | 199 ms |
| Stored full day through both lanes (scratch Postgres) | load 677 ms + build 948 ms; wall 1.7 s claim → publish | 34 KB + 3.2 MB | scoring day 1,043 ms |

The context lane is several times slower than scoring for a day; it runs in its own lane with a budget of 2 jobs per
wake and never blocks scoring. The stored-form pools were switched to hash keys after this profile (the split was the
largest cost); `PCDocumentSizeTests` now builds a fully observed synthetic day (2,309 envelopes) in ~1.1 s in a debug
-O build. Postgres stores tables with lz4 TOAST compression on the production image.

## 7. Evidence limitations and blockers

| Limitation | Effect | Runnable next step |
| --- | --- | --- |
| No independent reference labels (PSG, ECG, labelled activity, clinical outcomes) | Nothing is accuracy- or clinically validated | Collect a labelled cohort; evaluate with the plan in methods §11 |
| Real data limited to 8 de-identified nights of one person (HR, R-R, gravity) | Real-data checks are invariants only; no eligibility or change-detection calibration on real series | `PC_REAL_REPLAY_DIR` replay over more authorized nights; rerun the eligibility sensitivity sweep and the episode false-rate on real series |
| Heart-derived selection gates (sleep detector HR confirmation, HR-presence wear, RR kernel) | Possible selection bias in nightly and stable-awake references | Measure exclusion vs HR level / symptoms on labelled days (`SelectionSummary`) |
| Synthetic change-detection evaluation, missing-at-random only | Informative missingness untested; sparse series miss ~half of 2-SD shifts | Real longitudinal data with known events |
| HART epochs exist only with the activity lane and raw IMU uploads | Strap motion is the usual activity source | Enable the activity lane in a test environment |
| `devices.firmware` / `device_family` not written for push devices; no firmware history | Firmware boundaries cannot be detected yet | Write effective-dated firmware on device confirmation |
| Pre-existing e2e scoring failure on this checkout (scorer reads 0 HR rows for a confirmed strap, `no_data: hr=0 rr=1800`) | Two existing `NaraEndToEndTests` scenarios fail with or without the context lane; the context e2e passes but its stored day has no nightly values, so sleep-measurement eligibility and references were not exercised on the real stack (they are in the worker DB tests and the integration review chain) | Investigate HR device aliasing in push / scoring (outside this task) |
| No staging project | Activation can only be rehearsed locally | Create a staging Supabase project; follow rollout.md |
| Host instability during this work (external SSD disconnected twice; Docker VM restarted; load ~100) | Several runs had to be repeated; timings are upper bounds | Re-profile on the VPS-class host before choosing the lane budget |
| Pre-existing test failures (`activity_context_at` in auth isolation, `compute_family_policy` RLS, IntradayWording test) | Unrelated to this work | Fix in their owning areas |
