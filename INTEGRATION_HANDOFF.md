# Integration handoff: seven branches on `a1560f37e`

Branch `integration/seven-branches-20261008` (worktree `nara-integration-7`), cut from `a1560f37e` (main, the build on
the owner's phone). **Nothing here has been pushed, merged into `main`, deployed, or applied to production.** No
production database, edge function, VPS, unit file or environment was touched; every database run used a local
scratch Postgres. Deploying is the next stage's job (section 13).

> Deployed to production on 2026-10-09; what was deployed, the evidence and the open blockers are in
> `PRODUCTION_VALIDATION.md`.

## 0. Summary

- All seven branches are merged, conflicts resolved semantically, and the pipeline is wired end to end:
  strap/phone → `push` → Supabase → worker (scoring, activity, measurement context, sidecar models) → Supabase →
  `scores` routes → app screens and the coach.
- The integrated tree builds for iOS (device, Debug) and macOS, and the worker builds and tests on Linux from the
  packaged release (section 10). Every failing test is either fixed here or fails identically on `a1560f37e`
  (section 11). Not run here: Android unit tests (no SDK), a Linux sidecar run, and eight Deno files that need
  fixtures exported from the Swift/Android test suites.
- Nine new Supabase migrations apply in order on a fresh database of all 203, and re-apply cleanly (section 6).
- What is not live on deploy, and why, is listed per feature (section 2) and per model (section 3). No mock or
  stand-in value is displayed, and nothing shadow or candidate shapes a canonical value; release modes are only ever
  lowered downstream. One exception is shown on screen: the walking screens display ElderNet gait readings from
  shadow rows, labelled as wrist estimates from a gait model (Spec 01 left this to the owner, section 12).
- The decisions a human must make before or during deploy are in section 12.

## 1. Branches and hashes

| Branch | Tip merged | Integration commit | Conflicts and how they were resolved |
| --- | --- | --- | --- |
| `fix/hang-audit-20261008` | `f888a533e` | `a7368b102` | none |
| `fix/morning-sync-20261008` | `34be38f82` | `b369092e7` | `AppModel.swift`, `SleepView.swift`: both sides kept (sync notice + calculating state on main's layout) |
| `feat/metric-detail-redesign-20261008` (with the Sana handoff `80bb931c9`, an ancestor of the tip) | `6845757dd` | `6fd21f97d`, `755e65f04` | coach files, `HorizontalScrubSurface`, `MetricInsightCard`: both sides kept. `755e65f04` restores the route from `MetricDetailView` to `KeyMetricDetailView`, which main's UI-cleanup merge had dropped; without it the redesign is unreachable. It is a separate, revertable commit |
| `feat/spec01-model-integration-20261007` | `ae14dc662` | `f4bed02fc` | `TimesFMCoreML.swift`, `UniTSCoreML.swift`: main's removal of the stand-ins kept, Spec 01's identity hooks kept |
| `feat/spec03-pretrained-models-20261007` | `05543b43a` | `f5a319772` | none |
| `feat/spec02-feature-reuse-20261007` | `e3a05d9d0` | `d967991cb` | `BodyClockDialCard`, `SkinTempCardsView`, `SleepFeatureCards`, `StressView`, `DayScoring.swift`: main's layouts with Spec 02's wording and fields |
| `feat/activity-measurement-context-20261007` | `69b165fe4`, then the tail `c1ae9ee21` | `8afcb237b`, `42296183e` | see the `8afcb237b` message: Spec 01 release authority shapes canonical decodes; main's `ChargeBaselines.asOf` fold; main's Watchdog expectation design with the branch's phase-correct HRV centre; WhoopStore `v50` main, `v51` activity |
| (integration) | | `a57729570` | migration renumber (Spec 01's `20261008100000` → `20261008100600`) and re-runnable `20261008100000` |
| (integration) | | `c847318b2` and the commit carrying this file | the wiring and cross-branch test fixes listed in section 9 |

Source refs used for the merges: `refs/integ-src/{hang,morning,metricdetail,metricdetail-sana,spec01,spec02,spec03,activity}`.

## 2. Per-feature status

Legend: **Live** = runs and is shown once deployed with default settings. **Live (data-gated)** = runs, shows
"not available: reason" until enough data exists. **Off** = shipped behind a flag that defaults off. **Shadow** =
computed and stored, never displayed and never shapes a canonical value. **Not wired** = deliberately not connected
(reason given). Every server-side "Live" row also needs its worker lane switched on; those switches default off and
are listed in section 8.

| Feature | Branch | Status | Where it is consumed |
| --- | --- | --- | --- |
| Watchdog baseline replay off the main thread; Sentry idle-run-loop hang filter | hang | Live (app) | app runtime |
| Uploads no longer wait on scoring passes (no owner advisory lock in push triggers) | morning | Live after migration `20261008020000` | every upload |
| 5k-row upload batches, closed-app sync notice, Sleep tab "calculating" state | morning | Live (app) | Sync, Sleep tab |
| Key-metric screens in the HRV concept style, baselines, 24-hour windows, Ask Sana | metric-detail | Live (app) | Key metric screens via `755e65f04` |
| HRV intraday chart with weak slots drawn as hatched bands, `context_pending` slots visible | metric-detail + activity | Live | HRV screen |
| Runtime identity (worker heartbeat, sidecar `/healthz`), release packaging, `release-host.sh` | spec01 | Live after the release-layout move (section 8) | operations |
| Activity release authority (`shadow` < `candidate` < `production`), stored on every expert row | spec01 | Live after migration `20261008100600` | worker, `scores` gait/activity routes, phone decoder |
| Persisted, fair physiology-candidate queue | spec01 | Live after migration `20261008110000` (worker switches within 5 min) | `physiology_candidate_results`, no app reader |
| PPG transport anchor (NPB1 format 3, protocol 1.5) | spec01 | Off (`NOOP_PUSH_ADVERTISE_PPG_ANCHOR`, phone `noop.cloud.ppgAnchorUpload`) | worker sensor lane |
| Sensor biomarker families (`sensor.biomarkers.v1`) | spec01 | computed and stored (descriptive families); research families and rhythm Off; app section Off (`noop.sensorBiomarkersEnabled`, default off) | `/scores/sensor-biomarkers`, `SensorBiomarkersSection` |
| Pretrained-model eligibility, ActiNet and wav2sleep evaluation | spec03 | Not wired (section 3) | docs and isolation tests only |
| HF/LF power repair (`lomb_scargle_psd_ms2_v2`) | spec02 | Live (on-device) | Stress screen |
| Sleep analytics `-2`: pNN50, stage movement, post-wake slope repair, 30-min morning response | spec02 | Live after worker deploy | Sleep → Sleep analytics |
| Sleep features: respiratory variability, rebound, PRV nonlinear, skin-temp and rest-activity rhythms | spec02 | Live (data-gated; rhythms need about 5 re-published days) | Sleep → Sleep details; coach `get_sleep_details` |
| Physiology context: awake vs asleep HR, pulse episodes, stable-awake RR, post-exertion RR return | spec02 | Live after worker deploy | Measurement-context sheet, history; coach `get_measurement_context` |
| CircadianEngine relabelled "Heart-rate rhythm" (iOS and Android wording) | spec02 | Live | Sleep dial, Health card |
| Activity decoder `hsmm-1.9`, agreement-gated posture caps, `personal-profile-3` | activity | Live (phone) | day timeline, stretches, every context consumer |
| Measurement context on intervals (settled stats, vehicle detail, wear, provenance), WhoopStore `v51` | activity | Live (phone, migrates on first launch) | HRV/RHR/HR context, coach |
| Server context lane: current lineage, one epoch revision per UTC day, transition onset/source | activity | Live after migrations `100000`–`100200` + worker | PC engine, `/context` |
| PC posture strata, dose-scaled post-bout exclusion, predecessor regimes | activity | Live; seated and upright strata never form today (section 12) | physiology-context comparisons |
| Layer 1 context references (`lb-context-1`) and Watchdog usuals trained only on screened minutes | activity + main | Live (phone) | Watchdog, baselines |
| Retrospective smoothing `ctx-retro-2` (final days, phone-only table) | activity | Live (phone) | coach look-back only |
| Stretch corrections (read-time overlay), ground-truth labels incl. `confirmation` source | activity | Live after migration `20261008100500` + `scores` | stretches UI; labels endpoint |
| Account deletion no longer fails on the revision trigger | activity | Live after migration `20261008100400` (production defect fix) | account-deletion service |
| Personal sit/stand head (`sitstand-orient-1`, gate `sitstand-gate-1`, calibration-v4) | activity tail | Not wired in the app (library + server label source only, section 12) | nothing sets `ActivityDecoderConfig.sitStandHead` |
| Coach reads measurement context and sleep details (`get_measurement_context`, `get_sleep_details`) | integration | Live | coach |

## 3. Model inventory

Every model, where it runs, how its weights arrive, and whether its output can reach a person.

| Model / provider | Runs on | Weights and pin | Licence | Release mode | Storage → API → consumer | Status |
| --- | --- | --- | --- | --- | --- | --- |
| Activity decoder `hsmm-1.9` + `personal-profile-3` | phone (StrandAnalytics) | code only | repo | canonical | WhoopStore → day timeline, context, Watchdog | Live |
| HART v0 (`hart-wisdm-v0`) | worker host, Python child (`activity_context.serve`) | operator copies `config.json`, `manifest.json`, `model.safetensors` (sha256 `39dc12e0…`) to `/var/lib/frwhoop/activity-model`; not in git | MIT (EdgeIntelligenceLab/HART), WISDM data | production | `activity_encoder_windows` (`hart-windows-1`) → `/scores/activity-windows` → phone decoder | Live where the host has the model (`model_status: hart_loaded`) |
| Transition expert (in HART's service) | worker host | with HART | MIT | HART lineage | `transition` in `hart-windows-1` | Not deployed (activity status §6) |
| ElderNet standalone (gait quality) | worker host, Python child | `python -m activity_context.eldernet.weights fetch` from `yonbrand/gait-quality@437a38bc`, size + sha256 checked (`ELDERNET_WEIGHTS_DIR`) | Oxford Academic Use Licence (commercial use excluded) | `shadow` (default) / `candidate` (`FRWHOOP_ELDERNET_MODE`) | `activity_gait_windows_days` → `/scores/gait-windows` → walking card (descriptive), never the decode | Shadow; licence decision open |
| ElderNet embedded in HART | worker host | with HART | as above | always `shadow` | `g_*` in `hart-windows-1` | Shadow, stripped from canonical decodes |
| Inertia-1 motion heads | worker host | stand-in fixture only; no real checkpoint exists | n/a | `shadow` | `activity_motion_heads_days` | Shadow, no consumer |
| ActiNet encoder (motion heads) | worker host | not fetched by default | Oxford Academic Use Licence | `shadow` | `activity_motion_heads_days` | Shadow, no consumer |
| ActiNet classifier | — | `activity_context.actinet_classifier.weights fetch/convert` exists for evaluation | Oxford Academic Use Licence | — | — | Not wired (licence; spec03 isolation tests enforce non-reference) |
| Joint activity candidate + ablations | worker | n/a | n/a | `candidate`, never published | `activity_candidate_days` (service role) | Shadow, unread |
| `production.runs.v1` (HRV candidate run) | sidecar | code | repo | candidate (canonical HRV stays Swift) | `physiology_candidate_results` | Shadow, no consumer |
| `neurokit2.shadow.v1` (HRV) | sidecar | pinned wheel hash | MIT | `shadow` | same | Shadow, no consumer |
| `hypnospy.hr-boundary.v1` (sleep boundary) | sidecar | vendored at pinned revision | MIT (metadata unverified) | `shadow` | same | Shadow, no consumer |
| `sleepecg.wrn-gru-mesa.v1` (sleep stage) | sidecar | bundled zip, sha256 verified; readiness-required | BSD-3-Clause | `shadow` | same | Shadow, no consumer |
| `/v1/sleep-features` (Spec 02 Python features) | sidecar, isolated `sleep_features` lane, 3 s budget | code only | repo | enrichment | `daily.sleep_features` in the scoring snapshot → `scores` → Sleep details, coach | Live |
| `sensor.biomarkers.v1` descriptive families | sidecar | code only | repo | descriptive | `sensor_biomarker_days` → `/scores/sensor-biomarkers` → `SensorBiomarkersSection` | Stored; app section off by default (`noop.sensorBiomarkersEnabled`) |
| ParaDigMa tremor / arm swing | sidecar subprocess venv | 3 pinned artifacts | Apache-2.0 | research, flag off | same, not rendered | Off |
| DeepBeat / SiamAF rhythm | sidecar | 1 pinned artifact each | GPL-3.0 / MIT | `shadow`, flag off; withheld `unverified_sample_clock` | same (`raw_scores`), not rendered | Off |
| wav2sleep | — | 2 artifacts staged by spec03 tooling | MIT | — | — | Not wired: needs anchored, packet-timing-verified overnight PPG; today `packet_timing_verified=false` |
| no_eeg_sleep_staging, rr_estimation | — | — | MIT | — | — | Not wired: need raw high-rate PPG/IMU the product does not store |
| stepcount, cnn_wrist_model_freeliving | — | — | academic-only / unlicensed | — | — | Blocked by licence |
| Personal sit/stand head | phone | fitted per wearer from guided holds + confirmations | repo | gated per wearer | decoder `sitStandHead` | Not wired in the app |
| Anomaly service | separate unit (`Tools/AnomalyService`, own `install.sh`) | own models root | repo | unchanged by these branches | `anomaly-candidates` route | Unchanged |

Sidecar manifest: `Tools/InferenceWorker/models/manifest.json` (`manifest_version` 1.1.0, 11 entries, rights verdicts
and readiness flags per entry). Full provider-to-consumer detail: `docs/model-integration/README.md`; licence reading:
`docs/pretrained-models/integration/licence-corrections.md`.

## 4. Data flow

```
WHOOP strap ──BLE──> phone (WhoopProtocol decode, WhoopStore GRDB v51)
   │  on-device: activity decoder hsmm-1.9, Layer 1 lb-context references, Watchdog, HRV/stress (HF repair),
   │             ctx-retro-2, Charge (ChargeBaselines.asOf)
   ▼
push edge function ──> B2 objects (NPB1, rawImuSession, PPG anchor when enabled) + noop_* projections
   │                    triggers bump scoring_v2 jobs without waiting (20261008020000)
   ▼
Supabase tables (scoring_v2 jobs, activity_context_jobs, physiology_candidate_pending, sensor lanes …)
   ▼
frwhoop-worker (systemd, /opt/noop/current)
   ├─ ScoringLane: DayScorer → publish_scoring_snapshot_v2 (sleep_analytics_v1 -2, sleep_features via sidecar,
   │               hrv_series.context, rhythmDay bins)
   ├─ Activity lane: HART / ElderNet / Inertia children → activity_encoder_windows, gait/motion rows with
   │               release_mode + authority; server decode with production sources only
   ├─ Context lane: current lineage per UTC day → PC engine (posture strata, bouts, pulse episodes,
   │               stable-awake RR) → physiology-context day documents
   ├─ Candidate stage: persisted queue → sidecar candidate providers → physiology_candidate_results
   └─ Sensor lane: sensor.biomarkers.v1 → sensor_biomarker_days
   ▼
frwhoop-inference sidecar (loopback): /v1/infer, /v1/sleep-features, sensor.biomarkers.v1
   ▼
scores edge function: /, /days, /series, /activity-windows, /gait-windows, /context, /context/history,
                      /sensor-biomarkers, /ground-truth-labels, /stretch-feedback, /insights, …
   ▼
app repositories (ServerScoreRepository, PhysiologyContextRepository/Store, SensorBiomarkerRepository,
                  IntradaySeriesStore, GaitWindowStore) → screens and coach tools
```

The coach reads the same stores the screens render: `get_measurement_context` goes through
`PhysiologyContextStore` (the measurement-context sheet's source) and `get_sleep_details` through the cached
scoring snapshot then `scores` (the Sleep details section's source). Both say when context is stale, pending or
missing instead of answering from totals.

## 5. Activity and measurement context: where each guarantee is enforced

| Guarantee | Enforced in |
| --- | --- |
| Walking HR is never compared with resting HR | Layer 1 strata need known intensity ≤ 0.40, posture agreement and class confidence ≥ 0.6 (`LongitudinalBaselineContext.swift`, `lb-context-1`); a vehicle ride is never rest (added here); PC strata need `hsmm-1.9`, confidence ≥ 0.8 and never key from a ride (`PCPostureTransitions.swift`, worker `ContextInputs.swift`); post-bout exclusion is dose-scaled (`PCExertionBouts.swift`) |
| HRV is read with motion and quality context | `HRVWindow.swift` fails closed on missing motion and is transition-aware; HRV slots carry `context` (weak slots hatched, unpublished context shown as pending); spot HRV joins context by time (WhoopStore `v51`) |
| Respiratory metrics separate rest, sleep and activity | stable-awake RR reference `resp_rate.stable_awake_5min` (`PCReferences.swift`); nightly RR against 7/28-day baselines; post-exertion RR return (`PCExertionBouts.swift`); sleep-features respiratory variability is per night and per stage |
| Baselines compare like with like | PC posture strata (`pc-posture-2`), predecessor regimes; Charge scored against its own causal, era- and method-scoped baseline (`ChargeBaselines.asOf`); Watchdog expectations come only from established Layer 1 references and usuals train only on minutes a reference screened (`WatchdogExpectation.swift`) |
| Uncertainty is preserved | release modes only lowered; stretch confidence and provisional tail; sit/stand only ever "likely"; "Not evaluated" vs "None found"; stale/pending context said by screens and coach |

## 6. Migrations

203 files in `supabase/migrations`. The base commit's newest is `20261008010000_metric_insight_background_sweep.sql`;
whether production has applied it was not checked (no production access in this stage). The nine new ones, in this
order:

| # | File | From | What | Re-runnable |
| --- | --- | --- | --- | --- |
| 1 | `20261008020000_ingest_no_scoring_wait.sql` | morning | push triggers enqueue scoring with `SKIP LOCKED`, no owner advisory lock | yes |
| 2 | `20261008100000_activity_context_current_lineage_and_versions.sql` | activity | current-lineage view, version-driven re-derivation | yes (made so in `a57729570`) |
| 3 | `20261008100100_activity_context_epochs_day_revision_rows_index.sql` | activity | one epoch revision per UTC day, index | yes |
| 4 | `20261008100200_activity_context_transitions_onset_source.sql` | activity | transition `onset_ts` / `source` | yes |
| 5 | `20261008100400_bump_user_revision_skip_deleted_owner.sql` | activity | **production defect fix**: account deletion no longer fails with FK 23503 | yes (function body only) |
| 6 | `20261008100500_activity_ground_truth_confirmation_source.sql` | activity tail | ground-truth `source='confirmation'` | yes |
| 7 | `20261008100600_activity_release_authority.sql` | spec01 (renamed from `100000`) | `release_mode` / `authority` on expert rows; joint candidate table | yes |
| 8 | `20261008110000_physiology_candidate_pending.sql` | spec01 | persisted candidate queue (running worker switches within 5 min) | yes |
| 9 | `20261008120000_ppg_transport_anchor.sql` | spec01 | protocol 1.5 objects | yes |

`20261008100300` is unused. Spec 02 needs no migration (new fields ride existing jsonb).

Before applying, list production's applied versions read-only
(`select version from supabase_migrations.schema_migrations where version >= '20261008' order by 1;`). If any of
these nine names already exists there under a different file (for example Spec 01's old `20261008100000`), stop:
the rename assumed none of these branches reached production. Apply with `psql -v ON_ERROR_STOP=1 -1 -f` per file,
following `docs/BACKEND.md`; never `supabase db push`.

App store: WhoopStore `v50-ppg-legacy-record-identity` (main) then `v51-activity-context-provenance` (activity).
A dev install that ran the activity branch's own build under its old `v50` name must be wiped; no shipped build used it.

## 7. Edge functions

`supabase/functions/push/index.ts` and seven `_shared` modules changed (`config`, `durability`,
`groundTruthLabels`, `objects`, `ppgTransport`, `registry`, `serverScores`). Through imports that reaches `push`,
`scores`, `reconcile`, `ingest-verify`, `retention-sweep` and `account-deletion`. Deploy every function from this
commit after migrations 1–9 (the `scores` gait/activity routes select columns from migration 7).
`NOOP_PUSH_ADVERTISE_PPG_ANCHOR` stays unset until an owner decides (section 12).

## 8. VPS: workers, dependencies, commands

**Prerequisite.** `deploy/frwhoop-worker.service` now runs `/opt/noop/current/Tools/CloudWorker/.build/release/frwhoop-worker`
with only `/var/lib/frwhoop` writable. A host still on the pre-release layout must first do the one-time move in
`deploy/README.md` ("Moving an existing host to releases"), keeping `/opt/noop/{Tools,contracts,deploy}` as the
rollback target.

**Worker (Swift 6.0.3, Ubuntu 24.04).** System packages as `deploy/provision.sh` installs them (`build-essential clang
pkg-config libpq-dev zlib1g-dev libssl-dev libzstd-dev postgresql-client python3`) and its private SQLite 3530400
built with `-DSQLITE_ENABLE_SNAPSHOT=1` in `/opt/sqlite`. **Do not install `libsqlite3-dev` on the host:** its
`libsqlite3.so` sits in a directory the linker searches before `-L/opt/sqlite`, the link then lacks
`sqlite3_snapshot_*` and `release-host.sh build` fails (reproduced in the Linux run, section 10).

```bash
# workstation, clean tree at the integration commit
deploy/package-release.sh --out DIR            # tarball + .sha256 + release.json + release-host.sh
# host
release-host.sh install DIR/nara-release-<id>.tar.gz
/opt/noop/releases/<id>/deploy/release-host.sh build <id>   # swift build -c release + swift test; refuses on failure
/opt/noop/releases/<id>/deploy/release-host.sh switch <id>
systemctl restart frwhoop-worker
```

**Lane switches the server features depend on.** All default off; check the host's `/etc/frwhoop/worker.env`
read-only before claiming any server feature is live:

| Switch | Off means |
| --- | --- |
| `FRWHOOP_CONTEXT_ENABLED=1` (exactly `1`) | no physiology-context documents: no awake/asleep HR, pulse episodes, stable-awake RR, posture strata, and the coach's `get_measurement_context` reports no data |
| `FRWHOOP_INFERENCE_URL=http://127.0.0.1:8787` | no sleep-features enrichment (Sleep details, `get_sleep_details`) and no physiology-candidate lane |
| `FRWHOOP_ACTIVITY_ENABLED=1` (+ the `FRWHOOP_ACTIVITY_*` paths) | no HART windows or server activity days |
| `FRWHOOP_SENSOR_BIOMARKERS_ENABLED=1`, `FRWHOOP_SENSOR_PPG_ENABLED=1` | no sensor-biomarker days (IMU / PPG families) |

New worker settings (all optional, defaults shown in `deploy/worker.env.example`): `FRWHOOP_CANDIDATE_SCHEDULER=persisted`
(needs migration 8), `FRWHOOP_CANDIDATE_MAX_ATTEMPTS`, `FRWHOOP_CANDIDATE_REASSEMBLY_BUDGET`,
`FRWHOOP_CANDIDATE_LEASE_SECONDS`, `FRWHOOP_ACTIVITY_THREADS`/`ELDERNET_THREADS`/`INERTIA_THREADS` (1 each),
`FRWHOOP_RELEASE_STAMP`, `FRWHOOP_ACTIVITY_HOME=/opt/noop/current/Tools/ActivityContext`. Keep
`FRWHOOP_ELDERNET_MODE` and `FRWHOOP_INERTIA_MODE` unset (shadow). Do not set `ACTIVITY_GAIT_EXPERT`.

**Activity Python children** (`/var/lib/frwhoop/activity-venv`, CPU torch 2.8.0): HART artifacts as in
`deploy/README.md` "Activity context lane"; the ping must answer `"model_status": "hart_loaded"`. ElderNet weights
only if the owner accepts the licence reading (section 12).

**Sidecar (`frwhoop-inference`, Python 3.12, uv 0.9.5).** `deploy/provision.sh --sidecar-only` from the new
release builds `/opt/frwhoop-inference/venvs/<id>` with `uv sync --frozen`, stages and verifies model artifacts
into `/opt/frwhoop-models/<rev>` (`materialize_model_root.py`), probes as `frwhoop-inf`, and only then links
`/opt/frwhoop-inference/venv`. Admission knobs are in `deploy/inference.env.example`; raise `MemoryHigh` before
`FRWHOOP_INFERENCE_MAX_ACTIVE=2`.

**Identity checks after deploy** (read-only): heartbeat `meta.identity.executable.sha256` equals
`sha256sum /proc/<pid>/exe` with `matches_release: true`; sidecar `/healthz` `identity` model revision equals
`readlink /opt/frwhoop-models/current`; per-area queries in `docs/model-integration/README.md` "Read-only runtime
checklist".

## 9. Changes made during integration (beyond the merges)

| Change | Why |
| --- | --- |
| Coach tools `get_measurement_context`, `get_sleep_details` (`CoachServerContext.swift`, `CoachTools.swift`, prompt, visual-evidence list) | the coach answered "why is my HRV low" from totals; now it reads the same context documents the screens show, with stale/pending/missing said plainly |
| `LongitudinalBaselineContext.still` excludes `in_vehicle` rows | a still ride is seated but not rest; the worker's PC strata already excluded rides, the phone's Layer 1 did not |
| Sleep details hide Continuity/Architecture only when the analytics document is current for the night's sessions (`SleepAnalyticsStaleness`) | a stale analytics document hid those chapters with nothing in their place |
| Health card titled "Heart-rate rhythm" | Spec 02's relabel was lost under main's layout |
| `ActivityFamily.of` maps "Likely sitting"/"Likely standing" | the sit/stand tail added the labels without app families; they fell into "unclear" |
| `CoachTools` awaits the actor-isolated cache read | device build error |
| Tests: Watchdog phase-usual tests follow main's expectation design; replay and key-metric tests pass Spec 02's new members; the activity branch's candidate-gait-promotion test removed | Spec 01's `ActivityPhoneAuthorityTests` pins the integrated (stricter) rule |
| Migrations renumbered and made re-runnable (`a57729570`) | duplicate `20261008100000`; second apply failed |

## 10. Test evidence

All runs on this machine (macOS 26, Xcode at `/Volumes/External SSD/Xcode.app`), integration tree.

| Suite | Command (abridged) | Result |
| --- | --- | --- |
| iOS device build | `xcodebuild -scheme NOOPiOS -configuration Debug -destination generic/platform=iOS build` | BUILD SUCCEEDED |
| macOS app tests | `xcodebuild test -scheme Strand -destination platform=macOS -only-testing:StrandTests` (from an internal-disk copy, section 14) | 3596 tests, 13 skipped; 3 test cases fail (11 assertions), all pre-existing (section 11). The new coach readback test, the label-family fix and Spec 01's gait-authority test pass |
| StrandAnalytics | `swift test --skip LongitudinalBaselineTests` | 4022 tests, 10 skipped, 0 failures |
| StrandAnalytics `LongitudinalBaselineTests` | `swift test --filter LongitudinalBaselineTests` | 1 failure then a crash; identical on base (section 11) |
| WhoopStore | `swift test` | 687 tests, 0 failures |
| NoopPush | `swift test` | 203 tests, 0 failures |
| StrandDesign | `swift test` | 0 failures |
| CloudWorker (macOS, scratch DB) | `FRWHOOP_TEST_DB_URL=<scratch> swift test` | 781 tests, 4 skipped (opt-in profiling and a corpus check), 0 failures |
| CloudWorker (Linux, from the release tarball) | `release-host.sh install` + `build` in `swift:6.0.3-noble` (arm64), provision.sh's packages and its pinned snapshot SQLite 3530400 in `/opt/sqlite` | release build OK; 781 tests, 82 skipped (no DB), 0 failures; `--print-identity` `matches_release: true`; `BUILD.json` written (binary sha256 `915285f9…86e18`, arm64 — the x86_64 droplet's digest will differ) |
| Release packaging | `deploy/package-release.sh` at `c847318b2` | 1685 files, closure StrandAnalytics, WhoopProtocol, WhoopStore, OuraProtocol |
| Migrations | all 203 on a fresh scratch Postgres; the 9 new ones applied a second time | clean |
| SQL contracts | `activity_context_contract.sql` (39 PASS), `activity_release_authority_contract.sql` (4 PASS), `physiology_candidate_pending_contract.sql` (9 ok), account-deletion cascade, ground-truth confirmation, ingest-no-wait | all pass |
| Deno edge tests (one process per file) | 50 files | 34 pass; 8 need exported Swift/Android fixtures not generated here; 8 fail identically on base (section 11) |
| InferenceWorker pytest | `pytest` with `PYTHONPATH=src` ahead of the venv (venv from the Spec 01 worktree, whose `uv.lock` and `pyproject.toml` equal this tree's; offline `uv sync` was impossible without a cached torch) | 789 passed, 55 skipped, 0 failed |
| ActivityContext pytest | `pytest` with `PYTHONPATH=.` (venv from the activity worktree: torch 2.8.0, numpy 1.26.4, no scipy) | 428 passed, 71 skipped, 13 failed, 9 errors; the same 13 + 9 fail on base (section 11) |
| Android | — | not run: no Android SDK on this machine. The schema oracle twin is byte-identical to WhoopStore's (`cmp`), and lists `v50` then `v51` |

## 11. Pre-existing failures (fail identically on `a1560f37e`)

| Failure | Evidence on base |
| --- | --- |
| `LongitudinalBaselineTests.testQualityMixDoesNotTrainOutOfRangeOrMissing` fails, then `testSleepHRVLnConvertsBandToMs` crashes the process (`try!` on `XCTUnwrap`, line 330) | same two, same lines, base worktree `_build-scratch/integ-base-a1560` |
| macOS app tests: `ActivityCalibrationSessionTests.testBeginWithAnEmptyProtocolEndsCleanly`, `…testStepsChainBackToBackAndEveryActivityEndsWithDone`, `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` | the same 11 assertions at the same lines on a base build (`xcodebuild test -only-testing:` those two classes, from an internal-disk copy of `a1560f37e`) |
| Deno: `auth_isolation_sql` (both trees expose `activity_context_at` and `metric_insight_day_values_v1`, both from older migrations), `coach_timezone`, `intake_consumer_sql`, `intake_deadline`, `metric_insights_sql`, `placement_route`, `production_append_compatibility`, `server_pipeline_sql` | identical failures on a base scratch DB; none of the nine new migrations adds a client-callable function |
| ActivityContext pytest: 13 failures + 9 errors | identical on base; causes are a missing `scipy` in the borrowed venv and git-provenance tests run inside a worktree |

## 12. Blockers, limitations and owner decisions

**Decisions only a human can make**
- Push, open a PR, merge into `main`, deploy.
- Deploy migration 5 (`20261008100400`): it fixes a live defect (deleting a user with data fails with FK 23503).
- ElderNet's Oxford Academic Use Licence: keep fetching weights for shadow use, or not. ActiNet stays unwired.
  Spec 03's licence-text corrections (`docs/pretrained-models/integration/licence-corrections.md` §6) are proposed,
  not applied; for example the vendored `inertia/vendor/ssl_wearables_resnet.py` header still says CC BY-NC 4.0 where
  the upstream text is the Oxford Academic Use Licence.
- Turning on the PPG anchor (`NOOP_PUSH_ADVERTISE_PPG_ANCHOR`, then `noop.cloud.ppgAnchorUpload`; about 80 bytes per
  optical second).
- Whether the walking screens (`WalkingInsightsSection`, `WalkingDetailView`, `DayActivityDetailViews`) should keep
  showing ElderNet gait readings from shadow rows, or hide them until ElderNet is released and its licence settled.
  They never shape the decode.
- Physiology-context back-fill after the policy-key change (Spec 02 §5): closed days keep old documents until re-run.
- The "every stationary posture validated" profile rule (activity status §6).

**Known limitations (not regressions)**
- Personal sit/stand head is not wired: no app UI collects confirmations and nothing sets `sitStandHead`.
- Seated and upright PC strata never form (stored sit/stand confidence ≤ 0.75 vs the 0.8 floor); only recumbent-awake forms.
- Layer 1 (phone, class confidence ≥ 0.6) and the PC engine (worker, ≥ 0.8) use different floors on purpose: Layer 1
  also needs posture agreement and evidence ≥ 0.5. The PC strata require decoder `hsmm-1.9`; Layer 1 has no
  decoder-version gate (it reads the phone's own current decode).
- Motion heads run on stand-in weights and have no consumer; `activity_candidate_days` and
  `physiology_candidate_results` have no reader.
- HRV windows feed only a diagnostic line in the context sheet.
- Raw IMU is recorded one minute in three on WHOOP 5/MG; HART is absent most of the time.
- Main's metric-insight SQL reads physiology-context days without a version filter (mixing risk owned by main).
- The Charge breakdown's confidence chip uses the engine's tier when the engine scored the shown number; for a
  vendor-imported row it falls back to a raw-HRV maturity count, not the ln fold.
- Android reads none of the new server documents.
- The sidecar manifest's `wav2sleep` entry (unwired) still points at mutable `huggingface.co/…/resolve/main/` URLs
  with `provider_id: sleep_stage`; Spec 03's pinned revision (`18fc32f0`) and provider id `wav2sleep.ppg-only.v1`
  live in its own constants. Fix the entry before it is ever staged.
- `calibration-v4` defines a jittered cue (2–5 s); the app's `ActivityCalibrationSession` uses only the nominal
  `cueSeconds` (the range's lower bound), so the cue never varies.
- No Linux sidecar run in this stage. Spec 01 recorded one at its own tip; since then `uv.lock` and `pyproject.toml`
  are unchanged but Spec 02/03 changed 46 files under `Tools/InferenceWorker` (pure-Python features and tests, passing
  on macOS). `provision.sh --sidecar-only` probes the new venv before linking it, so a Linux-only failure stops there.

## 13. Deployment checklist (next stage)

1. Read-only: production's applied migrations (section 6), worker heartbeat identity, sidecar `/healthz`, and the
   lane switches in `/etc/frwhoop/worker.env` (section 8).
2. Owner decisions in section 12.
3. Migrations 1–9 in order, each with `ON_ERROR_STOP` in one transaction.
4. All edge functions from this commit.
5. Host: release-layout move if not done; `package-release.sh` → `install` → `build` (tests must pass on the host) → `switch`.
6. Sidecar: `provision.sh --sidecar-only` from the same release; restart `frwhoop-inference`.
7. Restart `frwhoop-worker`; check identity, `activity_context_jobs`, candidate queue claims, heartbeat counters.
8. App build from this commit (WhoopStore migrates to `v51` on first launch).
9. Verify: a day's `/scores` snapshot carries `sleep_analytics_v1` `-2` and `sleep_features`; `/context` carries
   `day_night_heart_rate`; activity rows carry `release_mode`; no expert row is `production`; the coach's
   `get_measurement_context` answers for today.

Rollback: `release-host.sh rollback` + restart; previous sidecar release's `provision.sh --sidecar-only`; migration 5
by re-applying the previous function body from `20260824180000`; the others are additive.

## 14. Reproducing the local runs

```bash
# scratch database (never production)
DOCKER_CONTEXT=colima-cexi-compute NARA_PIPELINE_DIR=/tmp/nara-integ-pipeline supabase/tests/e2e/pipeline_db.sh up
source /tmp/nara-integ-pipeline/pipeline.env   # PIPELINE_TEST_DATABASE_URL
# worker tests
cd Tools/CloudWorker && PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig \
  FRWHOOP_TEST_DB_URL="$PIPELINE_TEST_DATABASE_URL" swift test
# app. Many StrandTests read source files through #filePath; run them from a copy on the internal disk
# (git ls-files -co --exclude-standard | tar …), or the rebuilt test host blocks in open() waiting for
# macOS's removable-volume permission.
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests
# teardown
NARA_PIPELINE_DIR=/tmp/nara-integ-pipeline supabase/tests/e2e/pipeline_db.sh down
```
