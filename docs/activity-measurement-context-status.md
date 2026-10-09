# Handoff: activity classification and measurement context

Last state checked: 2026-10-08, evening. Branch `feat/activity-measurement-context-20261007`
(worktree `/Volumes/Untitled/Nara Whoop App V2/nara-activity-context-audit`). The final commit SHA is in
section 1. Nothing was pushed, merged into `main`, or deployed.

Every result below is marked:
- **Verified** means I re-ran it on the final integrated branch, or on the commit named, on 2026-10-08.
- **Reported** means it was taken from an earlier run or an agent report and was not re-run.
- **Not done** means it is still open.

The algorithm description lives in `docs/CURRENT_ALGORITHMS.md`, section 9 (9a–9j). This file covers status,
evidence and handoff only.

---

## 0. Summary

- All decoder and server review items are fixed. The unmerged INT-B work in progress (`acx/int-b-decoder-gaps`, `e6620d557`) is
  **superseded** by `acx/r1-decoder` and was never merged.
- The three unfinished requirements are done:
  - D8-10 retrospective smoothing (`ctx-retro-2`);
  - D6-14 HRV chart de-emphasis;
  - D4-09 predecessor-regime baselines.
- `CURRENT_ALGORITHMS.md` is updated.
- **Verified** on the final branch:
  - StrandAnalytics, WhoopStore and the worker pass, including **all database-gated worker tests**.
  - Migrations apply in order on a fresh Postgres.
  - The macOS app tests have 3 failures. They also fail on `nara/main`, so they are not caused by this branch.
  - The iOS app builds.
  - The final decoder benchmark was re-run.
- **One real production defect was found and fixed: account deletion.** It needs a deploy decision (section 7).
- **One regression was caught before it shipped.** The first retrospective smoother (`ctx-retro-1`) roughly
  quintupled wrong posture claims on free-living data. It was reworked so it can never add a posture claim
  (section 4D).
- **The branch was not merged with `main`.** It is 133 commits ahead and 118 behind `nara/main` (`3b4ee16a5`).
  Main must be merged before any release (section 7).

---

## 1. Branch and commits

Merge commits added this round, in first-parent order after the previous status commit `de6896268`:

| Commit | What |
| --- | --- |
| `2e2aa46a8` | Status-document rewrite left uncommitted by the previous session |
| `1c396f4b8` | `acx/r3-app`: D6-14 worker slot flags and chart de-emphasis, PC reason wording, corrections overlaid on HRV windows |
| `56d374264` | `acx/r2-server`: account-deletion trigger fix (`20261008100400`), direct event-filter test, migration headers, DB teardowns that throw |
| `7eb8b9551`, `d15e8e41e` | `acx/r4-baselines`: D8-10 smoother (first version), D4-09 strata and predecessor fallback, PC version bumps, one source for each PC version |
| `dd561e73a` | `acx/r1-decoder`: `hsmm-1.9`, `personal-profile-3`, lane tag carrying versions |
| `475e88d64` | `acx/r3-app` round 2: retrospective rows written for final days; predecessor and stratum wording |
| `1adad2205`, `7fc4d7f16` | `acx/r6-docs`: `CURRENT_ALGORITHMS.md` section 9 |
| `a3578736a` | `acx/r5-review`: independent review fixes, plus a DB test for the predecessor SQL |
| `e2655bd97` | `acx/r3-app` round 3: HRV slots with pending context stay visible; wording |
| `0364c811d` | `acx/r4-baselines` round 2: `ctx-retro-2`; predecessor quality read from the predecessor's own last 14 days; store records an empty smoothing result |
| `7036e9515` | Docs: this document; `CURRENT_ALGORITHMS.md` for `ctx-retro-2`, `context_pending`, strata gates |
| `b8f753e8a` | `acx/r3-app` round 4: every final day stamps the smoother version in the store (an empty result is recorded); UserDefaults marker removed |
| (head) | This final status update. The packages, worker and migrations are unchanged since `0364c811d`, so the section-5 package, worker and DB results apply to the head |

Agent reports with full detail are in `/Volumes/Untitled/Nara Whoop App V2/_acx-scratch/r-round/`
(`r1-decoder`, `r2-server`, `r3-app`, `r4-baselines`, `r5-review` `-REPORT.md`). Benchmark outputs are in
`_acx-scratch/final-eval/`. Verification logs are in `_acx-scratch/verify-final/`.

---

## 2. What was already working (Verified, unchanged by this round)

- The integration head `2e2aa46a8` reproduced the previous session's INT-B "after" benchmark **exactly**: 1594 of 1594
  metrics were identical. The INT-A/C/D merges did not change decoder output, so the inherited section-5
  numbers from the previous document are reproducible.
- Sleep recall (0.996 on Capture-24), locomotion recall, transition direction, event latency, walk start and stop
  latency, and short-stand event survival were already in place and are unchanged.
- The causal Charge as-of baseline, fail-closed HRV windows, the correction overlay, and the coach status.

---

## 3. Failure modes found this round

| # | Failure | Where | Fixed by |
| --- | --- | --- | --- |
| 1 | Restless claims ("Sitting/Standing, restless") reached 0.90 on wrist evidence alone. Their confidence added the seated and upright mass together | `ActivityContextClass.swift` | r1: one posture's mass, under the same cap |
| 2 | The sit/stand cap was lifted when any learned source merely **spoke**, not when it agreed | classifier | r1: `learned_posture` agreement gate. The cap is 0.75, or 0.85 with agreement, and is never lifted |
| 3 | Vehicle mass pushed an ordinary sitting claim above the cap (0.97 with no agreement) | classifier | r5 |
| 4 | Lying down used heart-rate level 0.15 and the other transitions used 0.20, so heart rate leaned a shift toward bed rest | `ActivityContextModel.swift` | r1: one level, 0.20 |
| 5 | The personal-profile guard pooled across classes. A minority class could be wholly mis-claimed (lying read as sitting 0 → 97 %) and still pass | `ActivityPersonalProfile.swift` | r1: per-class guard, plus "every stationary posture validated"; `personal-profile-3` |
| 6 | The decoder version stayed `hsmm-1.8` after behaviour changes. The worker lane tag ignored the taxonomy and interval versions | decoder, worker | r1: `hsmm-1.9`; lane tag `t=act-class-4;n=ctx-int-2`; `versionsOrdinal` 2 |
| 7 | **Account deletion fails** for a user with sessions or daily metrics. The `bump_user_revision` trigger upserts `user_sync_state` for an owner the cascade already removed (FK 23503). This is a production defect, proven on a scratch DB | migration `20260824180000` | r2: migration `20261008100400` |
| 8 | The event-filter test could pass without exercising the filter | worker test | r2 |
| 9 | Migration headers named the wrong production range | `20261008100000`, `20261008100100` | r2 |
| 10 | The PC policy versions were not bumped after INT-C changed event placement. `PostureEvidence.version` was still `pc-posture-1` while its config said 2 | PhysiologyContext | r4: `pc-eligibility-4`, `pc-join-3`, `pc-reference-4`, `pc-posture-2`, each with one source |
| 11 | The context strata accepted `hsmm-1.8` rows, whose sit/stand confidence was not agreement-gated | `PCPostureTransitions.swift` | r5: minimum decoder version is now `hsmm-1.9` |
| 12 | A car ride could form a `.ctx_seated` reference | strata, worker SQL | r5: in-vehicle seconds excluded, with reason `context_in_vehicle_not_used` |
| 13 | **The first retrospective smoother (`ctx-retro-1`) manufactured posture claims** (section 4D) | `ActivityContextRetrospective.swift` | r4 round 2: `ctx-retro-2` |
| 14 | Today's HRV line disappeared whenever the activity lane had not published yet | D6-14, first version | r3 round 3: `context_pending` is not weak |
| 15 | The predecessor signal-quality check read the scored day's window, so it was usually "unknown" and passed | PCEngine | r4 round 2 |
| 16 | `hsmm-1.9` broke one DB test that r1 never ran | worker DB test | r5 |

---

## 4. Measured results (Verified unless marked)

Harness: `_acx-scratch/final-eval/` (D7 replays, `hart` arm, the same scorer as INT-B).

Variants:
- `head` is the integration head `2e2aa46a8`, before this round.
- `final2` is `0364c811d`, which has every decoder and classifier change from this round.
- `hsmm-1.7` is **Reported**, from the D7 audit outputs scored by INT-B.

### A. Over-confident posture claims (states, then intervals)

| Replay | Restless claims > 0.75: head → final | Max sit/stand/restless confidence: head → final | Max posture interval confidence: head → final |
| --- | --- | --- | --- |
| Capture-24, oracle nights | 815 of 851 → **0** | 0.904 → 0.718 | 0.901 → 0.734 |
| Capture-24, awake | 839 of 877 → **0** | 0.904 → 0.718 | 0.901 → 0.734 |
| FORTH-L | 12 of 12 → 0 | 0.881 → 0.707 | 0.698 → 0.698 |
| FORTH-R | 16 of 16 → 0 | 0.893 → 0.708 | 0.856 → 0.710 |
| PAMAP2 | 22 of 23 → 0 | 0.899 → 0.715 | 0.898 → 0.708 |
| PAMAP2 + HART fine | 175 of 185 → **0** | 0.905 → 0.718 | 0.902 → 0.710 |
| FORTH-L + HART fine | 41 of 46 → 0 | 0.892 → 0.710 | 0.888 → 0.711 |

### B. Everything else, head → final

The full diff is in `final-eval/head_vs_final2.txt`. It shows 87 of 1594 metrics changed.

- **Changed, all small, all in calibration of still states.**
  - Capture-24 ECE 0.139 → 0.138; still-state mean confidence 0.917 → 0.913.
  - PAMAP2 + HART still-state mean confidence 0.879 → 0.807 and ECE 0.147 → 0.136.
  - FORTH-L + HART ECE 0.124 → 0.116.
  - Lowering the restless confidence removed over-confidence without changing any class.
- **Unchanged.** These are identical: per-class recall, precision and confusion; abstention rates; transitions;
  short-stand survival; interval rows and fragmentation. Specifically:
  - transition direction 40 of 40;
  - event latency median 5 s (p90 6 s);
  - walk start / stop latency median 13 / 5 s;
  - false posture events in steady stillness 0 per hour;
  - stand→sit state latency median 17 s;
  - wrong posture state claims at ≥ 0.5: 390 (Capture-24), 4 (PAMAP2);
  - Capture-24 sleep recall 0.996, locomotion recall 0.808, sitting precision 0.858;
  - abstention: still-unresolved 0.381, unknown 0.006.
- **The one exception.** On PAMAP2 + HART, one state moved from still-unresolved to active: still-unresolved went
  0.138 → 0.137 and sitting family recall 0.878 → 0.876.

### C. Short stands (forthshort: 15 bouts each of sit → stand L s → sit)

| L | Sit-to-stand event kept | Both events, in order | Interval boundary inside the episode | Standing state |
| --- | --- | --- | --- | --- |
| 5 s | 11 | 8 | 8 | 0 |
| 10 s | 11 | **3** | 11 | 0 |
| 15 s | 11 | 10 | 11 | 0 |

These counts are identical at head, final, and final with retrospective intervals. Two notes:
- **The weak 10 s result predates this round, and it is limited by evidence, not by smoothing.** In every one of
  the 24 bouts where the sit-back event was lost, the peak transition mass in the sit-down window was ≤ 0.09. Where
  it was detected, the peak was 0.05–0.62. The wrist barely registered those sit-downs.
- I did not lower the event floor (0.20) without labelled strap data.

### D. Retrospective smoothing (D8-10)

Rows compare causal intervals, the first smoother `ctx-retro-1`, and the final `ctx-retro-2`. Measures are per
interval second.

| Replay | Wrong posture claims (s) | Sitting precision | Standing claims | Intervals per hour |
| --- | --- | --- | --- | --- |
| Capture-24, oracle | 1760 / **8717** / 1760 | 0.871 / 0.905 / 0.871 | none / 2949 s at **0.081** / none | 36.8 / 38.7 / 36.8 |
| Capture-24, awake | 1760 / 8717 / 1760 | 0.707 / 0.522 / 0.707 | none / 7864 s at 0.03 / none | 38.2 / 40.2 / 38.2 |
| FORTH-L | 0 / **750** / 0 | 1.000 / 0.746 / 1.000 | none | 50.6 / 45.9 / 50.6 |
| FORTH-R | 0 / 977 / 0 | 1.000 / 0.728 / 1.000 | none | 53.2 / 45.8 / 53.2 |
| PAMAP2 + HART | 63 / – / 63 | | precision 0.698 → **1.0** (`ctx-retro-2`) | 67.7 / – / 67.4 |

Notes on the table:
- **Why `ctx-retro-1` was reworked.** It spread a posture across stretches that the causal decoder had
  deliberately left `stationary`, and committed those claims at ≥ 0.5.
- **What `ctx-retro-2` may do.** It can only demote a contradicted causal posture claim to `stationary`, merge rows
  that then match, and move a walk or run stop boundary back. A move is at most 10 s, never into a posture claim,
  and never leaves a walk shorter than 10 s.
- **What a guard and a property test enforce.** Over 150 random sequences: retrospective claim seconds ⊆ causal
  same-posture seconds; per-second confidence ≤ causal; rows ≤ causal.
- **The cost of boundary refinement.** Locomotion recall drops 0.3–0.7 points and active precision rises 0.3–1.0
  points (`final-eval/final2_vs_retro.txt`). Setting `stopOnsetMaxLeadS = 0` turns it off.
- **Short-stand survival is identical to causal.**
- **Honest summary.** With `hsmm-1.9`, the causal decoder no longer produces the walk → standing → stationary →
  sitting pattern that D8-10 described on these replays. So `ctx-retro-2` rarely changes anything. It is safe, but
  not yet a measurable improvement.

### E. Resource use

| Measurement | Value | Status |
| --- | --- | --- |
| Full replay decode, 9 replays, about 300 h of data, final decoder | 108 s wall, 70 s user CPU, about 1.45 GB peak RSS | Verified. Includes the build check. Load average was 100–800 from other sessions, so treat as an upper bound |
| Earlier `head` run | 1844 s wall | Measured during an extreme-load period, so not comparable |

No per-second latency profiling was done.

---

## 5. Test results on the final branch (Verified)

| Suite | Run | Skipped | Failures | Command / log |
| --- | --- | --- | --- | --- |
| StrandAnalytics (`--skip LongitudinalBaselineTests`, whose fixtures are missing on main) | 3771 | 8 | 0 | `verify-final/sa-b.log` |
| WhoopStore | 682 | 0 | 0 | `verify-final/ws-b.log` |
| CloudWorker, no DB | 702 | 74 (DB-gated) | 0 | `verify-final/wt-b.log` |
| **CloudWorker, with a scratch DB** | **702** | 4 (3 opt-in profiling, 1 missing fixture dir) | **0** | `verify-final/wt-db.log` |
| SQL `activity_context_contract.sql` | 39 PASS | | 0 | `verify-final/db-*.txt` |
| SQL `account-deletion-revision-cascade.sql` and `account-deletion-retired-installation.sql` | pass | | 0 | same |
| macOS `StrandTests`, at `e6c3fb9bf` (= head minus docs) | 3193 | 13 | 3 (pre-existing on main; below) | `_acx-dd/r3-mac-results10-3.xcresult` (agent run) |
| iOS `NOOPiOS`, generic device, `CODE_SIGNING_ALLOWED=NO`, at `e6c3fb9bf` | BUILD SUCCEEDED | | | r3 report, round 4 |

The scratch DB:
- ran on ports 54512–54514, Docker context `colima-cexi-compute`;
- had all branch migrations applied in `ordered_migrations.sh` order on a fresh container, ending with `20261008100400`;
- was torn down afterwards. No containers are left on those ports, and `auth.users` was empty after the suite.

**The 3 macOS failures pre-exist on `nara/main`.** I ran them on `nara/main` `3b4ee16a5` and got the same 3 tests
and the same 11 assertions (`r-round/main-mac-3tests.log`):
- `ActivityCalibrationSessionTests.testBeginWithAnEmptyProtocolEndsCleanly`
- `ActivityCalibrationSessionTests.testStepsChainBackToBackAndEveryActivityEndsWithDone`
- `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets`

The likely cause of the first two: `finish()` guards on `isRunning`, which is still `.idle`. They are not fixed
here, because they are out of scope and identical on main.

**The three macOS compile breakages reported at `3aa15d665` no longer exist.** `6b839c488` fixed them. The three
files are byte-identical to `nara/main`.

Main's combined migration order was **Reported** by the r2 agent: this branch, plus main's four newer migrations,
plus spec01's `20261008120000`, 199 migrations in all, applied cleanly to a fresh DB and passed the SQL tests.

---

## 6. Remaining limitations

**From the sensors and the data:**
- **A wrist cannot reliably separate sitting from standing.**
  - Standing precision on Capture-24 was 0.13 or lower before this work.
  - Wrist-only standing is never committed now, so sit→stand state latency is "never" on FORTH without HART.
  - The system says `stationary` instead, which is the intended behaviour.
- **The seated and upright-stationary baseline strata currently never form.**
  - Stored interval confidence for sit/stand is ≤ 0.75, and the stratum floor is 0.8.
  - Per-second learned-posture agreement does not yet propagate into runs.
  - Only `recumbent_awake` can form. This is correct abstention under the "no stand-in models" rule, but it means
    the D4-09 posture strata deliver lying-awake references only.
- **Lying awake versus sitting in the daytime is weak.** PAMAP2 lying-awake recall is still about 0.12 or lower.
- **Raw IMU is recorded only 1 minute in 3** on WHOOP 5/MG. HART and the posture heads are absent most of the time.
  The transition expert is not deployed.
- **No fitted calibration map (D9-08).** All thresholds were tuned on lab and free-living replays, not on labelled
  strap data. That covers: posture caps 0.75/0.85, stratum floor 0.8, predecessor ×1.5 / 0.25 / 14 d / 56 d, smoother
  dwell, and event floor 0.20.
- **Short sit-backs with little wrist motion are missed** (section 4C).

**Personal-profile rule needing an owner decision:**
- The new "every stationary posture validated" rule refuses sit/stand profiles from any protocol that lacks a
  lie-down.
- Without the rule, an end-to-end run doubled wrong claims on an unseen day (25 % → 50 %).
- It lives in one function, `validatesEveryStationaryPosture`.

**Device family and firmware are not on the regime key:**
- An effective-dated firmware source does not exist, and family labels get relabelled.
- Predecessor compatibility uses the hardware family identified on each device row instead.
- A bare "WHOOP" label counts as unknown, so the fallback abstains for those rows.
- Firmware is never compared, and every borrowed reference is flagged `predecessor_firmware_unknown`.

**Open, small:**
- D9-02(b) is not done: stamping runs with whether heart rate shaped them.
- The Python HSMM port is still `hsmm-1.6`.
- The worker and the store's `*Ctx` views do not see user corrections.
- `recent_activity_s` changed meaning without a version marker (C10).
- Walking classes below the minimum seconds pass the profile guard silently. Stationary classes fail closed.
- Retrospective rows are read only by the coach look-back. History screens still read causal rows.

---

## 7. Deployment handoff (not executed)

### Release order

1. **Merge `nara/main` into this branch first.** Known conflicts, from the previous document's dry run of 14 paths:
   - `Baselines+AsOf.swift`, add/add: main has its own causal as-of Charge fold. Choose one and keep both test sets.
   - The UniTS / Watchdog stand-ins: main removed them.
   - WhoopStore migration registration: ours is registered **after** main's `v50-ppg-legacy-record-identity`
     and renamed `v51-activity-context-provenance`, because `SchemaOracleTests` requires the prefixes to run
     1…N. Ours never shipped (`7a3664fda` exists only on this line), so renaming it was safe; a dev database
     that ran the branch build under the old name must be wiped.
   - The schema oracles: regenerate both copies byte-identical.
   - The app files listed in the old section 6A.
   - Then re-run every suite in section 5.
2. **Supabase migrations, production order:**
   1. main's through `20261008010000`;
   2. `20261008100000`;
   3. `20261008100100`;
   4. `20261008100200`;
   5. `20261008100400`;
   6. spec01's `20261008120000_ppg_transport_anchor`.

   `20261008100300` is unused. Before deploying, list the migrations production has actually applied. If spec01
   reaches production first, our migrations must be renamed to later timestamps.
3. **Worker build**, after the migrations.
4. **App build.** The new store columns and table are created by app migration `v50` on first launch.

### Re-derivation and historical data

- **Decoder `hsmm-1.9`, lane `versionsOrdinal` 2.**
  - Stored activity days and lanes are stale by version and are re-derived on the next pass.
  - Changes are numeric only on the replays (restless confidence, ≤ 0.006 on posture heads), plus about one state per
    PAMAP2+HART replay.
  - Expect lower restless confidence and no class changes in history.
  - Old rows keep their `hsmm-1.8` stamps until they are re-derived.
- **`personal-profile-3`.** Adopted v2 profiles are re-validated at the next refit. Many will be refused under the
  per-class and stationary rules, and the wearer falls back to population defaults. A v2 profile stays in use until
  the refit runs. There is no crash and no mixing.
- **PC versions** (`pc-eligibility-4`, `pc-join-3`, `pc-reference-4`, `pc-posture-2`).
  - They change the policy fingerprint, so a re-run day stores a new revision.
  - **There is no backfill trigger.** Days that are not re-run keep the old versions.
  - Main's metric-insights SQL and `Tools/MetricInsight` read physiology-context days without filtering by version.
    That is a mixing risk owned by main.
- **Retrospective `ctx-retro-2`.** Rows are written for final days only, on the phone, in a separate table. No
  server table exists. A final day returning to provisional deletes its retrospective rows. No production rows exist
  from `ctx-retro-1`.
- **HRV slots.** `daily.hrv_series.context` is additive. Older apps ignore it, and a newer app reading an older
  snapshot renders as before.
- **Cache invalidation** happens through the version stamps and fingerprints above. Nothing else needs flushing.

### Rollback

- App and worker: redeploy the previous build. All new fields are additive or optional. The new store table and
  columns are ignored by old code.
- `20261008100400` only replaces a function body, with the same signature. To roll back, re-apply the previous body
  from `20260824180000`.
- The other three new migrations are additive (lineage, index, onset/source columns).

### Decisions only a human can make

- Push, open a PR, merge main into this branch, and merge into main.
- Deploy `20261008100400`, the account-deletion fix. It fixes a live defect: direct or racing deletions of users
  with data fail with FK 23503. Account recovery can fail too.
- Migration order relative to spec01.
- Whether to keep the "every stationary posture validated" profile rule.
- Whether to keep `ctx-retro-2`'s walk-stop boundary refinement.
- Which Charge as-of baseline to keep when main is merged.

---

## 8. Commands that work

```bash
export DEVELOPER_DIR="/Volumes/External SSD/Xcode.app/Contents/Developer"
XS="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
R="/Volumes/Untitled/Nara Whoop App V2/nara-activity-context-audit"
"$XS" test --package-path "$R/Packages/StrandAnalytics" --skip LongitudinalBaselineTests
"$XS" test --package-path "$R/Packages/WhoopStore"
export PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig
"$XS" build --build-tests --package-path "$R/Tools/CloudWorker" && "$XS" test --skip-build --package-path "$R/Tools/CloudWorker"
# Worker with a scratch DB, the SQL tests, and teardown: _acx-scratch/verify-final/run_db.sh
# Benchmark: _acx-scratch/final-eval/scripts/final2.sh (copies the harness test in, decodes, removes it, scores)
```

The Python venv for the harness is `/Volumes/Untitled/Nara Whoop App V2/_acx-scratch/venv-ac`.
`~/.cache/nara-acx` was deleted externally again at about 12:55 on 2026-10-08. Do not rely on it.

## 9. Gotchas

- **Never run a bare `git stash`.** The stash is shared by every worktree on the machine.
- **Never commit `Config/*Secrets.xcconfig` or the generated Xcode project.**
- **The internal disk is nearly full.** Keep derived data in `/Volumes/Untitled/Nara Whoop App V2/_acx-dd/`.
- **The external drive, which holds Xcode, unmounts intermittently.**
- **Machine load ran into the hundreds** from other sessions. macOS test runners sometimes failed to connect; a clean
  retry worked.
- **Keep production access read-only.** Never apply migrations to production from an agent session.

## 10. Do not

- Push, open a PR, merge into main, or deploy without explicit human approval.
- Re-record golden files without reviewing the diff. This round's re-record is classified in
  `r-round/r1-decoder-REPORT.md`: no genuine regressions; numeric deltas ≤ 0.006, from the heart-rate level unification.
- Delete `_acx-wt/`, `_acx-scratch/` or `_acx-dd/` until the human confirms.
