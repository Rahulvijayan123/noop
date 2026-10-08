# Activity and measurement context: what has been done

Status document for the activity-classification, transition, measurement-context and baseline work.
Branch: `feat/activity-measurement-context-20261007` (HEAD `81967173c` when this was written).

This is a plain account of what was changed, what was verified, and what is still open.
Where a claim comes from a sub-agent's report and was not re-run here, it says so.

## 1. Where the work lives

Every change is on this branch, merged from the work packages below. Nothing was pushed.

| Area | Result | Commit(s) |
| --- | --- | --- |
| Audit findings D1–D9 | Reconciled into 8 work packages (WP1–WP8) plus an integration round (INT-A to INT-D) | see below |
| Python replay tools (D9-09) | Replay export writes the current `jerk_rms_gps` key; the Python HSMM port declares the Swift version it reproduces | `918e2b3d9` |
| WP1–WP6 | Merged with the latest `nara/main` (`947678ee6`) | `2ba97f1b4`, `910df3320`, `7ad200f7f`, `c3d58c541`, `5b1a30d9c`, `bfa4f8ee8` |
| WP7 baselines, WP8 Watchdog | Merged; the Charge, daytime-stress, UniTS, stress-onset and Watchdog fixes are in | `7a6269834`, `e22dd6fc3` |
| Cross-package wiring | Today's stress, the Watchdog HRV usual, the nudge copy and HRV readiness wired to the new context | `0f72ae44e` |
| INT-A (storage) | Interval context fields stored and read back; vehicle detail; settled statistics; day-boundary events | `52b6f9d78` |
| INT-D (consumers) | Fail-closed HRV windows, kind-aware recovery, user-correction overlay, coach status | `b8064df3c` |
| INT-B (decoder gaps) | Posture-neutral heart rate; wrist-only sit/stand confidence cap; personal orientation rows | `b97649235` |
| INT-C (server) | Migrations renamed after production's applied versions; transitions onset/source on the server surface; candidate comparisons use the published config; `join-2` marker; heartbeat counters | `81967173c` |

Two things are deliberately **not** on the integration branch:

- `acx/int-b-decoder-gaps` at `e6620d557` is a labelled **WIP** commit with unverified partial review fixes.
  It breaks 204 golden tests and must not be merged as-is.
- The fix rounds for INT-B and INT-C were cut off by the API daily rate limit. Their remaining review items are open (section 5).

## 2. What changed in this session

1. **Merge conflict in `ActivityContextInterval.swift` (INT-D into the integration branch).**
   INT-A added the settled and detail fields; INT-D added `provenance`. Both sets are kept.
2. **Build error after that merge.** INT-D removed `HRVWindowBuilder.Config.recoveryGuardS`, which INT-A's
   `hrvEventLookbackS` still read. It now reads `recovery.requiredLookbackS`, the longest recovery the
   HRV-baseline policy needs before a window. The lookback is still at least 120 s plus the detection lag.
3. **Two persistence tests updated** (`ActivityContextPersistenceTests`). Both encoded the older rule that a
   window with no history before the day reads as steady rest. Under the merged policy it reads as
   `unknown` and is not baseline-eligible. The tests' own comments describe that situation, so the
   assertions now match the policy.
4. **Committed what was in progress.** INT-B's uncommitted fixer edits are preserved as the labelled WIP
   commit `e6620d557`. The INT-B and INT-C committed heads (`769526e64`, `024ad2940`) are merged.

No code was added on top of the sub-agents' work beyond items 1–3.

## 3. Verification

Run on the merged branch in this session:

| Check | Result |
| --- | --- |
| `StrandAnalytics` full suite (skipping `LongitudinalBaselineTests`, whose fixtures are missing on `main`) | 3730 run, 8 skipped, **0 failures** |
| `WhoopStore` full suite | 678 run, **0 failures** |
| `CloudWorker` build with tests | **builds** |
| `CloudWorker` tests without a database | 691 run, 71 skipped (database-gated), **0 failures** |

Reported by the implementers on their own branches; **not re-run here**:

- The worker database suites against a scratch Postgres (INT-C). The full run reported 691 tests, 4 skipped, 0 failures.
  INT-C also reported a causal-replay failure that was a test-isolation bug, not a production defect.
- The final before/after benchmark on the integrated decoder (INT-B). Its report says all nine replays were
  decoded for both variants and the table written to the scratch folder, but I have not re-checked those numbers.

**Not run at all in this session:**

- The macOS app test target (`StrandTests`).
- The iOS app build.
- The full database suite on the merged branch.

The acceptance criteria require all of these. They are the next step.

## 4. Measured results (from the sub-agent reports and the replay harness)

These come from the D7 replays (FORTH-TRACE, PAMAP2, Capture-24) and the sub-agents' reports. They are not
independently re-measured on the merged branch.

| Measure | Before | After |
| --- | --- | --- |
| FORTH left wrist: wrong posture claims on still truth, confidence ≥ 0.5 | 117 | 0 |
| FORTH right wrist: same | 135 | 23 |
| FORTH: transition direction correct | 15 of 35 | 40 of 40 |
| FORTH: posture events detected | 35 of 61 | 40 of 61 |
| FORTH, 10 s stand (15 bouts): standing state shown | 1 of 15 | 12 of 15 |
| FORTH, 10 s stand: sit-to-stand event kept | 1–3 of 15 | 10–11 of 15 |
| FORTH, 10 s stand: both stand and sit events in order | 2 of 15 | 3 of 15 |
| PAMAP2: wrong claims at confidence ≥ 0.5 | 145 | 8 |
| PAMAP2: lying-awake recall | 0 | 0.12 |
| Capture-24: wrong claims at confidence ≥ 0.5 | 4060 | 1629 (on about 4× fewer claims) |
| Capture-24: sleep recall / locomotion recall | 0.996 / 0.804 | 0.996 / 0.809 |
| Capture-24: intervals per hour | 23 | about 36 |
| FORTH walk start / end error (median) | 24 / 17 s | 12 / 5 s |
| Charge z-score drift against a causal fold (synthetic) | mean 0.65, max 1.36 | 0 by construction: the as-of fold is causal, so this is a consistency check rather than an empirical result |

Trade-offs to read with these numbers:

- On free-living data (Capture-24) the posture claims that remain are **not** more accurate. There are fewer of
  them, and the ones left are often still wrong. Standing precision is about 0.11.
- On the lab datasets (FORTH, PAMAP2), committed posture claims are almost always right, but confidence is
  capped near 0.6–0.75, so the calibration error on lab data went up.

## 5. Open items

These are the review findings that were **not** fixed.

**Decoder (INT-B committed head):**

- Fidgeting is not capped. `Sitting, restless` and `Standing, restless` reach about 0.90 confidence from wrist
  signals alone, so the statement "every sit/stand claim is at or below 0.718" is incomplete.
- The personal-profile wrong-claim guard pools across classes. A minority class can be wholly mis-claimed and
  still pass. The reviewer estimated the typical wearer's wrong claims rise by 6–11 points with a profile;
  I did not re-measure that.
- The wrist-only cap is lifted when any learned source is present, not when that source agrees with the claim.
- The lying-down transition still uses a different heart-rate level (0.15 against 0.20 for the other transitions).
- The personal recumbent-orientation cap has no test.
- Some comments are stale. The decoder version is still `hsmm-1.8` although its behaviour changed. Consumers
  cannot tell the two apart, and the worker's version tag ignores the taxonomy bump.
- D9-02 part (b) is not done: runs and intervals are not stamped with whether heart rate shaped them.
- D9-08: no labelled strap data exists to fit a calibration map. Only a cap was added.

**Server (INT-C committed head):**

- `EligibilityConfig.version` and `JoinConfig.version` were not bumped. Historical days decided under the old
  event placement can mix with new ones without any signal.
- The test that checks a causal replay no longer checks the document's event filter. The filter itself is
  untested.
- The account teardown in `ActivityStreamDaysDatabaseTests` uses `try?`, so failures are silent. It also
  points at a possible production defect: the `bump_user_revision` trigger on `sessions` appears to make
  deleting an account fail. This was not proven on a database and must not be changed in production without
  a test.
- The migration header states the wrong production range (it should end at `20261008010000`).
- `20261008120000_ppg_transport_anchor` exists on another branch. If it reaches production first, the
  ordering comes back. Re-check the order against production immediately before deploying.

**Consumers and app (INT-D and WP7 reports):**

- Whether the reviewer's remaining minor items on the app side are resolved has not been checked.
- The Watchdog activity label in coach text is the label of the latest minute. The text now says so; it is not an
  activity summary of the whole scored window.
- Calendar-day HRV readiness, the Watchdog's per-device timelines and the HR-only workout classification are
  implemented as reported, but the macOS app tests that exercise them have not been run here.

**Infrastructure:**

- The internal disk was nearly full during the build runs. Derived data is on the external drive now.
- Another session deleted `~/.cache/nara-acx/impl/*` at about 14:12. Durable copies are under
  `/Volumes/Untitled/Nara Whoop App V2/_acx-scratch/`.

## 6. Limits that come from the sensors and the data

- A wrist cannot reliably tell sitting from standing. In free-living data, wrist-only sit/stand reaches
  roughly 0.6–0.7 balanced accuracy, and some people are close to chance. The system reports `stationary`
  when it cannot tell.
- Lying awake versus sitting is poorly separated on a wrist. Forearm angle helps at night, but daytime
  lying with a raised arm is untested.
- Raw 100 Hz IMU is recorded only one minute in three on WHOOP 5/MG, so posture models and the transition
  expert are absent most of the time. The expert is not deployed.
- Heart-rate-based posture evidence is circular unless it is kept out of posture decisions. Only part of this
  is done (INT-B).
- Thresholds were tuned on the lab and free-living replays, not fitted on labelled strap data.
- The owner's production verdicts on sitting stretches were right 7 of 18 times (per the audit), so real-world
  accuracy on this device is still unproven.

## 7. What to do next

1. Run the macOS app tests and the iOS build on the merged branch.
2. Run the worker database suites against a scratch Postgres on the merged branch, then apply the migrations in
   their production order.
3. Finish the open review items above, starting with fidgeting and the cross-class guard in INT-B.
4. Re-run the final benchmark on the merged decoder and check it against section 4.
5. Update `docs/CURRENT_ALGORITHMS.md` (not done in this round).
