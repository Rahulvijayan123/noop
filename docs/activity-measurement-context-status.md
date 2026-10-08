# Handoff: activity classification and measurement context

Written so that another model or engineer can pick this up cold. Last state checked: 2026-10-08.
Branch `feat/activity-measurement-context-20261007`, HEAD `de6896268`.
Read sections 0, 1 and 7 before touching anything.

Provenance matters in this document. Each claim is one of:
- **Checked** — I re-ran it or re-read it on 2026-10-08.
- **Reported** — taken from an implementer's report or a benchmark file, not re-run.
- **Not done** — still open.

---

## 0. The four things that matter most

1. **The work lives in the copy on `/Volumes/Untitled`, not the original repo on the external drive.** The
   integration branch and all twelve `acx/*` branches exist only in `/Volumes/Untitled/Nara Whoop App V2/noop/.git`.
   The original repository, `/Volumes/External SSD/Nara Whoop App V2/noop`, has a branch with the same name
   that points at the pre-audit commit `5eded7bd7` and has no `acx/*` branches. Do not mistake that one for
   the current branch. **Checked.**
2. **The branch is 118 commits behind `nara/main` (`3b4ee16a5`), and a dry-run merge conflicts in 14 paths.**
   Merging main is the first task. Nothing has been merged into main or pushed. **Checked.**
3. **Nothing is deployed.** No migration, worker build or app build has reached production. Do not apply
   migrations to any production database without explicit human approval.
4. **Only the Swift packages and the worker build are verified on the merged branch.** The macOS app tests,
   the iOS build, and the worker database suites on the merged branch have not been run.

---

## 1. Where everything is

| What | Where |
| --- | --- |
| Integration worktree | `/Volumes/Untitled/Nara Whoop App V2/nara-activity-context-audit` (branch `feat/activity-measurement-context-20261007`) |
| Object store for that branch | `/Volumes/Untitled/Nara Whoop App V2/noop/.git` (the worktree's `.git` file points here). The external repo's same-named branch is stale, at `5eded7bd7`. Backups of the original link: `~/.cache/nara-acx/worktree-*.bak` |
| Remote | `nara` = `https://github.com/Rahulvijayan123/Nara-App.git`. `git ls-remote nara main` works. `git fetch nara main` has failed with "did not send all necessary objects" and has worked at other times. The copy has a broken ref `refs/heads/feat/ui-cleanup-design-system-20261007`, which prints "bad object" warnings |
| Work-package worktrees | `/Volumes/Untitled/Nara Whoop App V2/_acx-wt/` — `wp1-decoder-posture` … `wp8-watchdog`, `int-a-persistence-wiring` … `int-d-consumer-gaps`. Branches `acx/*`. All merged except `acx/int-b-decoder-gaps` (see section 6D) |
| Durable scratch and evidence | `/Volumes/Untitled/Nara Whoop App V2/_acx-scratch/` (see below) |
| Original scratch (partly deleted) | `~/.cache/nara-acx/`. `impl/` was deleted externally at about 14:12 on 2026-10-07. Do not rely on it |
| Derived build output | `/Volumes/Untitled/Nara Whoop App V2/_acx-dd/` — pass `-derivedDataPath` here. The internal disk is nearly full |
| Pipeline database helper | `supabase/tests/e2e/pipeline_db.sh` (needs Docker, via colima). Agents used ports 54462–54464, 54472–54474, 54482–54484. All torn down |
| Stale memory note | `~/.claude/projects/-Volumes-External-SSD-Nara-Whoop-App-V2/memory/activity-measurement-context-audit.md` is **out of date** (it names `3aa15d665` and old workflow ids). Trust this document |

Inside `_acx-scratch/`:
- `central/` — verified audit findings (`verified_D1.json` … `verified_D6.json`, `verified_D8.json`), the cross-check (`critic.json`), `D8_and_critic.txt`, `impl_digest.txt` (all WP reports), `impl_results.json`, `wp78_results.json`.
  `int_results.json` is missing from the copy but exists in `~/.cache/nara-acx/central/`.
- `D7-empirical/` — replays (`replays/`), scripts (`scripts/`), results. `D7-NOTES.md` and `D8-NOTES.md` are the evidence notes.
- `eval-harness/` — the D7 harness and `results-before/`.
- `final-eval/RESULTS.md` — the integrated benchmark (section 5).
- `verify/` — the test logs from today's merges (`sa-*.log`, `ws-*.log`, `worker-*.log`).

---

## 2. The goal, condensed

The priority is **reliable coarse context**, not finer labels. In order:

sleeping · lying awake · sitting · standing still · active · off-wrist · **unknown when evidence is insufficient**

Requirements that follow from this:
- Do not guess posture from elapsed time. A posture claim needs posture evidence. Otherwise say `stationary`.
- Wrist IMU cannot reliably separate sitting from standing. Keep that weak and keep its uncertainty visible.
- Short real transitions (a 10-second stand) must survive smoothing as events, without destabilising sustained-state intervals.
- Every physiological measurement must join deterministically to its context (support interval, posture, transitions, sleep, wear, validity, confidence, provenance, causal/retrospective, final/provisional, gaps).
- Baselines must be causal (no future nights), must not mix measurement regimes (device, method, posture), and must fall back hierarchically with explicit provenance.

---

## 3. What is on the branch

First-parent history since the integration base `bfa4f8ee8`:

| Commit | What |
| --- | --- |
| `918e2b3d9` | Python tools: replay export writes `jerk_rms_gps`; the HSMM port declares `hsmm-1.6` (**Checked**: `pytest tests/inertia/test_replay_feature_keys.py tests/test_hsmm_port_version.py` passes) |
| `2ba97f1b4` / `910df3320` / `7ad200f7f` / `c3d58c541` / `5b1a30d9c` | Merges of WP2 (transitions), WP4 (server), WP5 (physiology context), WP6 (consumers), WP3 (phone storage) |
| `bfa4f8ee8` | Merge of `nara/main` at `947678ee6` (two conflicts resolved: coordinator fingerprint, day-stream step dedup) |
| `7a6269834` / `e22dd6fc3` | Merges of WP7 (baselines) and WP8 (Watchdog) |
| `0f72ae44e` | Wiring: stress screen and curve get the day's sleep/context; Watchdog HRV usual is phase-correct; nudge copy depends on verified stillness; HRV readiness uses calendar days |
| `52b6f9d78` | Merge INT-A: interval context fields stored and read back; vehicle detail; settled statistics; previous day's tail feeds HRV windows |
| `b8064df3c` | Merge INT-D: fail-closed HRV windows; kind-aware recovery; correction overlay; coach status. Conflict resolved; one build error fixed (see below) |
| `b97649235` | Merge INT-B committed head `769526e64`: posture-neutral heart rate; wrist-only sit/stand confidence cap; personal orientation rows |
| `81967173c` | Merge INT-C: migrations renamed after production's applied versions; transitions onset/source on the server surface; candidate comparisons use the published config; `join_version` marker; heartbeat counters |
| `de6896268` | Status document (this file's previous version) |

Two merges in that list needed work beyond a clean merge:
- **INT-D.** Both INT-A and INT-D added fields to `ActivityContextInterval`. Both sets are kept.
  INT-D had removed `HRVWindowBuilder.Config.recoveryGuardS`, and INT-A's `hrvEventLookbackS` still read it.
  It now reads `recovery.requiredLookbackS`.
  Two persistence tests encoded the old "steady rest with no history" rule. They now expect `unknown` and not eligible.
- **INT-B.** Its WIP fixes were **not** merged; see 6D.

Version constants on the branch (**Checked** unless noted):

| Constant | Value |
| --- | --- |
| `ActivityContextVersions.decoder` | `hsmm-1.8` |
| `ActivityClassVersions.taxonomy` | `act-class-4` |
| `ActivityClassVersions.interval` | `ctx-int-2` |
| `ActivityContextJoin.version` | `join-2` |
| `EligibilityConfig.version` (PC) | `pc-eligibility-3` — **not bumped**; INT-C asked for `pc-eligibility-4` |
| `PersonalProfile.currentVersion` | `personal-profile-2` |
| WhoopStore migration | `v50-activity-context-provenance` (unshipped; edited in place) |
| Supabase migrations (new) | `20261008100000_…lineage_and_versions`, `20261008100100_…epochs_day_revision_rows_index`, `20261008100200_…transitions_onset_source` |
| `docs/CURRENT_ALGORITHMS.md` | **Not updated** — still says `hsmm-1.3`. **Checked** (0 mentions of `hsmm-1.8`) |

What the decoder now does, in one line each (**Reported**, from the WP1/WP2/INT-B reports):
- Posture comes from bounded posture evidence (arm pattern, held forearm angle, shift direction, learned heads, night). The dwell prior only governs how long a mode lasts.
- Heart rate has one level across bed rest, seated and upright. It separates stationary from exertion only.
- Sit/stand confidence is capped at 0.75 when no learned posture source backs it. Fidgeting is **not** capped (6D).
- Transition direction comes from the forearm axis at both ends of the shift. Every decoder event is stored at its peak probability, with onset and source.
- Runs follow the per-second class. Boundaries move back to the event onset. Resume equals a fresh decode at every cadence.
- Interval folding never absorbs off-wrist, unknown, gait, cycling, vigorous or ride fragments. In-vehicle rows keep `detail=in_vehicle` and get no rest statistics.
- Wear is `on_wrist` only with a valid pulse in the last 60 s.

---

## 4. Verification status

**Checked on 2026-10-08, on the merged branch:**

| Check | Result |
| --- | --- |
| `Packages/StrandAnalytics`, `--skip LongitudinalBaselineTests` (fixtures missing on main) | 3730 run, 8 skipped, **0 failures** |
| `Packages/WhoopStore` | 678 run, **0 failures** |
| `Tools/CloudWorker` build with tests | **builds** |
| `Tools/CloudWorker` tests, no database | 691 run, 71 skipped (database-gated), **0 failures** |

**Reported, not re-run:**
- Worker database suites against a scratch Postgres (INT-C): 691 tests with the database, 4 skipped, 0 failures. SQL contract tests: 39 PASS. INT-C says all migrations applied in `ordered_migrations.sh` order.
- Final benchmark (INT-B): `final-eval/RESULTS.md`.
- Each work package's own test counts (in `impl_digest.txt`).

**Not run at all:**
- The macOS app test target (`StrandTests`), including the app-side tests for WP3, WP6 and WP7 wiring.
- The iOS build (`NOOPiOS` scheme).
- The database suites on the merged branch.
- The migrations on a fresh database in production order, on the merged branch.

Base breakages that blocked the macOS test build at `3aa15d665` (**Reported**; not re-checked on main):
- `Strand/Screens/WatchdogView.swift` lines 288 and 1129: `.noopSheetPresentation` is iOS-only and is not guarded.
- `StrandTests/SleepFeatureDocumentTests.swift` line 62: two statements on one line.
- `StrandTests/ActivityCalibrationSessionTests.swift` lines 240, 242: a main-actor call from a nonisolated test.

---

## 5. Measured results

From `final-eval/RESULTS.md` (INT-B, decoder at `61b6813b5` + `769526e64`) and the WP reports. The numbers are **Reported**; the replays are in `_acx-scratch/D7-empirical/replays/`.

| Measure | Before (hsmm-1.7) | After |
| --- | --- | --- |
| FORTH left: wrong posture claims on still truth, confidence ≥ 0.5 | 117 | 0 |
| FORTH right: same | 135 | 23 |
| FORTH: transition direction correct | 15 of 35 | 40 of 40 |
| FORTH: posture events detected | 35 of 61 | 40 of 61 |
| FORTH, 10 s stand (15 bouts): standing state shown | 1 of 15 | 12 of 15 |
| FORTH, 10 s stand: sit-to-stand event kept | 1–3 of 15 | 10–11 of 15 |
| FORTH, 10 s stand: stand and sit events both in order | 2 of 15 | 3 of 15 |
| FORTH walk start / end error (median) | 24 / 17 s | 12 / 5 s |
| PAMAP2: wrong claims at confidence ≥ 0.5 | 145 | 8 |
| PAMAP2: lying-awake recall | 0 | 0.12 |
| Capture-24: wrong claims at confidence ≥ 0.5 | 4060 | 1629 (on about 4× fewer claims) |
| Capture-24: sleep recall / locomotion recall | 0.996 / 0.804 | 0.996 / 0.809 |
| Capture-24: intervals per hour | 23 | about 36 |
| Charge z-score drift vs a causal fold (synthetic) | mean 0.65, max 1.36 | 0 by construction — a consistency check, not a measurement |

Read these with the trade-offs:
- On free-living data (Capture-24), the posture claims left are fewer, but they are still often wrong. Standing precision is about 0.11.
- On lab data (FORTH, PAMAP2) committed posture claims are almost always right, but their confidence sits near 0.6–0.75, so calibration error on lab data went up.
- The owner's production verdicts on sitting stretches were right 7 of 18 times, at a mean confidence of 0.71 (**Reported**, from the D1 audit). Real-world accuracy on this device is still unproven.

---

## 6. Open problems, ranked

### A. Merging current `main` — the first task

`git merge-tree --write-tree --name-only HEAD nara/main` (a dry run; it changes nothing) reports 14 conflicted paths:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/Baselines+AsOf.swift` — **add/add**. Main added its own file with that name in `81ab84eb5`. Our WP7 added one in `d651ebdae`. Both are a causal as-of Charge fold.
  Main also has `96a87af6d` ("Score each Charge night against its causal as-of baseline"). **Two implementations of the same fix. Choose one, then keep tests from both.**
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/BaselinesAsOfTests.swift` — **add/add**, same cause.
- `Packages/StrandAnalytics/Sources/StrandAnalytics/UniTSRuntime.swift` and `Watchdog.swift` — main commit `43fda432f` removes "the on-device UniTS / TimesFM stand-ins". Our WP7 changed the UniTS fallbacks. Check whether our changes still apply to what main keeps.
- `Packages/WhoopStore/Sources/WhoopStore/Database.swift` — migration order. Our `v50-activity-context-provenance` and main's `v50-ppg-legacy-record-identity` both start with `v50`. Migrations run in registration order, so ours must be registered after main's `v50`. Then keep `v51` (if any) after both.
- `Packages/WhoopStore/Tests/WhoopStoreTests/ActivityContextStoreTests.swift`
- `Packages/WhoopStore/Tests/WhoopStoreTests/Resources/schema_oracle.json` and `android/app/src/test/resources/schema_oracle.json` — regenerate both copies. They must stay byte-identical.
- `Strand/Data/DaytimeStressMode.swift`, `Strand/Data/IntelligenceEngine.swift`, `Strand/Screens/ChargeBreakdownWiring.swift`, `Strand/Screens/CoupledView.swift`, `Strand/Screens/TodayView.swift`, `Strand/Watchdog/WatchdogService.swift`.

Main also has new migrations: `20261007160000_coach_threads_memory`, `20261007180000_anomaly_service`, `20261008000000_metric_insights`, `20261008010000_metric_insight_background_sweep`. Ours (`20261008100000` onward) sort after them. That is correct, but re-check it.

### B. App verification

- macOS: `StrandTests` must build and pass for the classes that touch the new code (`ActivityContextPersistenceAppTests`, `HRVSnapshotViewTests`, `ActivityContextUITests`, `CoachContextConsumersTests`, `CausalBaselineWiringTests`, `ChargeBreakdownWiringTests`, `WatchdogLayer1BaselineStoreTests`). Fix base breakages in section 4 if they are still there.
- iOS: `xcodebuild -scheme NOOPiOS -destination generic/platform=iOS`.
- Setup: `Config/*Secrets.xcconfig` are gitignored. Copy them from `/Volumes/Untitled/Nara Whoop App V2/nara-phone-build/Config/`. Run `xcodegen generate` in the worktree. Never commit the generated project or the secrets.

### C. Worker and database verification

- Start a scratch database with `supabase/tests/e2e/pipeline_db.sh up`, using ports that no other agent uses. Set `NARA_PIPELINE_DIR`, `NARA_PIPELINE_DB_PORT`, `NARA_PIPELINE_REST_PORT` and `NARA_PIPELINE_AUTH_PORT`.
- Apply all migrations in `ordered_migrations.sh` order. Run `supabase/functions/tests/activity_context_contract.sql` and the worker's database tests with `FRWHOOP_TEST_DB_URL` set.
- Tear down with `pipeline_db.sh down` when finished. Check that no containers are left running.

### D. Decoder open items (from the INT-B review)

- **Fidgeting is not capped.** `Sitting, restless` and `Standing, restless` reach about 0.90 from wrist signals alone. The "every sit/stand claim is at or below 0.718" statement is incomplete. Look at `ActivityContextClass.swift` around the cap (review pointed at lines ~366–405).
- **The personal-profile guard pools across classes.** A minority class can be wrongly claimed and still pass. The reviewer estimated the typical wearer's wrong claims rise 6–11 points with a profile. Not re-measured. See `ActivityPersonalProfile.swift` around lines 238, 293, 620–655.
- **The cap is lifted by any learned source, not by agreement.** See `ActivityContextClass.swift` around lines 294–296 and 454.
- **Lying-down uses heart-rate level 0.15 and the other transitions use 0.20.** See `ActivityContextModel.swift` around line 296.
- **The personal recumbent-orientation cap has no test.** `ActivityContextDecoder.swift` around lines 495–505.
- **Stale comments.** `ActivityContextClass.swift` around line 259 still says `act-class-3`; around line 285 it cites 0.88–0.90 for sitting, which is actually fidgeting.
- **Not done:** D9-02 part (b) (stamp runs and intervals with whether heart rate shaped them); D9-08 calibration map (no labelled strap data exists).
- **Decoder version.** The behaviour changed after `hsmm-1.8` was stamped, and the worker's lane tag ignores the taxonomy bump. Stored days cannot tell the builds apart.

**The WIP on `acx/int-b-decoder-gaps` at `e6620d557`** holds the partial fixes for the items above. It is **unverified**: 204 StrandAnalytics tests fail (`GaitQualityGoldenTests` 104, `ActivityContextGoldenTests` 78, `ActivityPersonalCalibrationEndToEndTests` 22), because the goldens were not re-recorded. Use it as a reference, not a merge. Re-record goldens only after the change is reviewed.

### E. Server open items (from the INT-C review)

- **Bump the PC versions.** `EligibilityConfig.version` (`PCEligibility.swift` around line 256) is `pc-eligibility-3`. Bump it to `pc-eligibility-4`, and bump the join config to `pc-join-3`. Without the bump, days decided under the old event placement mix with new ones silently.
- **The event-filter test is weak.** `ActivityContextDaysTests` around lines 583–591 can pass without exercising the filter in `dayDocument`. Add a direct unit test that passes a pre-`dayStart` and a post-`dayEnd` event and asserts both are dropped.
- **The database test teardown uses `try?`.** `ActivityStreamDaysDatabaseTests` around lines 63–69. Deleting an `auth.users` row that owns sessions fails, because the `bump_user_revision` trigger (`20260824180000_production_persistence.sql` around lines 611–641) upserts `user_sync_state` inside the cascade. **This may be a real production defect in account deletion.** Prove it on the scratch database before changing any production trigger, and make the teardown throw.
- **Migration headers.** `20261008100000` and `20261008100100` say production has applied versions up to `20261008000000`. Main also has `20261008010000`, so the range should end there.
- **Migration ordering.** `20261008120000_ppg_transport_anchor` exists on `spec01/ppg-transport-20261007` and is not on main. If it reaches production first, the ordering problem returns. Check the order against production immediately before any deploy.

### F. Consumer and app open items

- Check INT-D's and WP6's remaining minor review items (the reports list them in `impl_digest.txt` and `int_results.json`).
- **Not done:** D6-14 (de-emphasise HRV chart slots with unknown or locomotion context); D4-09 (a predecessor-regime baseline after a strap change); D8-10 (retrospective fixed-lag smoothing for finalised days).
- **Not done:** `docs/CURRENT_ALGORITHMS.md`.
- The Watchdog activity label in coach text is the latest minute's label, and the text now says so.

---

## 7. Next steps, in order

1. **Merge `nara/main`.**
   ```bash
   cd "/Volumes/Untitled/Nara Whoop App V2/nara-activity-context-audit"
   git fetch nara main          # if this fails, use: git ls-remote nara main, and see section 1
   git merge nara/main         # resolve the 14 paths in section 6A
   ```
   Re-run the StrandAnalytics and WhoopStore suites and the worker build after the merge.
2. **Build and test the app** (section 6B), on macOS and iOS.
3. **Run the worker database suites and apply the migrations in production order** (section 6C).
4. **Fix the decoder and server review items** (sections 6D and 6E). Start from the WIP only as a reference.
5. **Re-run the benchmark** on the merged decoder and compare it with section 5. Re-measure anything you cite.
6. **Update `docs/CURRENT_ALGORITHMS.md`** for `hsmm-1.8`, `act-class-4`, `ctx-int-2`, the posture-evidence model, the single heart-rate level, runs by class, settled statistics, the lineage rules and `join-2`.
7. **Stop before anything irreversible** and ask for the decisions in section 8.

---

## 8. Decisions only a human can make

- **Push, open a PR, or merge into main.** Nothing has been pushed.
- **Deploy.** The decoder change re-derives stored days. The migrations, the worker build and the app build all change production. Migrations must not be applied to production from an agent session.
- **Which Charge as-of baseline to keep** (section 6A): ours (WP7) or main's (`81ab84eb5` / `96a87af6d`).
- **Whether to accept the wrist sit/stand cap as it is**, given the fidgeting gap in 6D.
- **The account-deletion question** in 6E. It needs a decision on whether to change a production trigger.
- **The branch name.** A request mentioned a branch called "abrnahc". No such branch exists. The work is on `feat/activity-measurement-context-20261007`.

---

## 8a. Commands that work

Toolchain. The default `swift` on this machine is the Command Line Tools one, which has no XCTest. Use Xcode from the external drive:

```bash
export DEVELOPER_DIR="/Volumes/External SSD/Xcode.app/Contents/Developer"
XS="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
```

If the external drive is unmounted, Xcode is unavailable. Wait and retry; the drive unmounted several times on 2026-10-07.

```bash
R="/Volumes/Untitled/Nara Whoop App V2/nara-activity-context-audit"
# StrandAnalytics (about 1–2 min)
"$XS" test --package-path "$R/Packages/StrandAnalytics" --skip LongitudinalBaselineTests
# WhoopStore
"$XS" test --package-path "$R/Packages/WhoopStore"
# Worker: build with tests, then run the non-database tests
export PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig
"$XS" build --build-tests --package-path "$R/Tools/CloudWorker"
"$XS" test --skip-build --package-path "$R/Tools/CloudWorker"
# Python tools (Tools/ActivityContext). Use the analysis venv if it still exists; plain python3 may lack pytest.
cd "$R/Tools/ActivityContext"
PY=~/.cache/nara-acx/venv-ac/bin/python; [ -x "$PY" ] || PY=python3
"$PY" -m pytest tests/inertia/test_replay_feature_keys.py tests/test_hsmm_port_version.py -q
```

Put long runs under `nice -n 5`, and give them generous timeouts. Machine load reached several hundred while many agents ran.

Verification logs from today are in `_acx-scratch/verify/`.

---

## 9. Gotchas

- **Never run a bare `git stash`.** It is shared by every worktree on the machine.
- **Don't commit secrets.** `Config/*Secrets.xcconfig` are gitignored. Copy them from `nara-phone-build` when you need them.
- **Copied worktrees carry `.build` directories with absolute paths.** Those cause "PCH was compiled with module cache path …" errors. Delete `.build` after copying a worktree.
- **The internal disk is nearly full** (about 22 GB free). Keep derived data on `/Volumes/Untitled`.
- **The external drive unmounts intermittently.** It was the source of several "Permission denied" and "Device error" failures.
- **Parallel sub-agent runs hit the daily API token limit (HTTP 429).** Split the work into smaller rounds. Workflow results are cached by prompt and options, so check the journal before relaunching a failed agent.
- **Commit attribution.** The most recent instruction asked for `Co-Authored-By: Claude Haiku 5.5`. Earlier commits on this branch say Opus 5.5.
- **Production.** Read-only aggregate queries only. The connection details and rules are in the memory note `prod-db-readonly-access.md`.

---

## 10. Limits that come from the sensors and the data

- A wrist cannot reliably separate sitting from standing. Free-living balanced accuracy for wrist-only sit/stand is roughly 0.6–0.7, and some people are near chance. The system reports `stationary` when it cannot tell, and that is correct behaviour.
- Lying awake versus sitting is poorly separated on a wrist. Forearm angle helps at night; daytime lying with a raised arm is untested.
- Raw 100 Hz IMU is recorded one minute in three on WHOOP 5/MG, so posture models and the transition expert are absent most of the time. The expert is not deployed.
- Heart-rate-based posture evidence is circular unless it is kept out of posture decisions. Only part of that is done.
- Thresholds were tuned on lab and free-living replays, not fitted on labelled strap data.
- Some results rest on the owner's own data, which is small. Treat them as indicative until a labelled strap study exists.

---

## 11. Do not

- Push, open a PR, merge into main, or deploy without the human's explicit approval.
- Apply migrations, or write anything, to a production database.
- Change the account-deletion trigger without a proof on the scratch database.
- Re-record golden files to make tests pass without reviewing what changed.
- Delete `_acx-wt/`, `_acx-scratch/` or `_acx-dd/` until the human confirms they are no longer needed.
