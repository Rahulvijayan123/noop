# Model integration (Spec 01): shared contracts

Status: implemented on `feat/spec01-model-integration-20261007` (from `nara/main` dab2124f3), all five
areas integrated; not pushed, merged to main or deployed. The verification record is at the end.

Specs 02 and 03 are being built on other branches. They should read this page first: it lists the
interfaces this branch changed and the extension points they plug into.

## Areas and file ownership

| Area | Spec section | Detail doc | Owns |
| --- | --- | --- | --- |
| Deployment and release | §1 | [provisioning.md](provisioning.md) | `deploy/` (except unit resource limits agreed with Runtime), `Tools/InferenceWorker/scripts/`, `Tools/InferenceWorker/src/frwhoop_inference/{artifacts,identity}.py`, `Tools/InferenceWorker/models/manifest.json`, `Tools/CloudWorker/Sources/frwhoop-worker/RuntimeIdentity.swift`, release packaging |
| Runtime bounds and scheduling | §5 | [runtime-bounds.md](runtime-bounds.md) | `Tools/InferenceWorker/src/frwhoop_inference/server.py` (and new execution modules), `Tools/CloudWorker/Sources/frwhoop-worker/{CandidateStage,ScoringLane,InferenceClient}.swift`, candidate work storage migrations |
| Activity authority and fusion | §2 | [activity-authority.md](activity-authority.md) | `Tools/CloudWorker/Sources/frwhoop-worker/Activity*.swift`, `Tools/ActivityContext/`, `Packages/StrandAnalytics/Sources/StrandAnalytics/ActivityContext*`, the phone's activity stores and fetch path, the activity routes in `supabase/functions/` |
| PPG transport | §3 (transport, reconstruction, segments) | [ppg-transport.md](ppg-transport.md) | `Packages/NoopPush/`, the phone's PPG capture and upload, the push receiver's PPG handling, `Tools/CloudWorker/Sources/frwhoop-worker/SensorBiomarker*.swift` |
| Sensor families and provider dispatch | §3 (run-aware computation), §4 | [sensor-families.md](sensor-families.md) | `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/`, `Tools/InferenceWorker/src/frwhoop_inference/providers/`, `docs/sensor-biomarkers/CONTRACTS.md` |

Shared files (`main.swift`, lockfiles, `docs/ARCHITECTURE.md`, `deploy/README.md`, this page) are
integrated by the parent.

## Runtime identity

What a process has loaded is reported by that process, from bytes it measured. A configured
revision string is reported only as a claim (`claimed_source_revision`), never as proof.

- **Worker heartbeat.** `scoring_service_heartbeats.meta.identity` is the worker's own identity.
  Each lane reports what it measured in `meta.lanes[].identity` (a string map, set through
  `LaneSnapshot.identity`), for example the activity child's loaded checkpoint digests.
- **Inference sidecar.** `GET /healthz` and `GET /v1/providers` carry an `identity` block
  (`frwhoop_inference/identity.py`, schema `runtime-identity/1`) beside the per-provider
  readiness they already report.
  Checkpoints load in the warm infer worker process, so each provider's `providers.<id>.loaded` comes from
  that worker's own report (`loaded_source: "worker"`, carried in its `hello` and published as
  `worker_loaded_identity`); `loaded_source: "process"` means the HTTP process answered for itself, before a
  worker reported. SleepECG reports the archive and model sha256 its load measured; ParaDigMa and the rhythm
  models report the verified bytes they would load, and only while they can load. Field list:
  [provisioning.md](provisioning.md#identity-fields).
- **Activity lane.** `meta.lanes[].identity` adds `expert_policy`, `selection_digest`, and each child's
  `<child>.<loaded key>` and `loaded_digest` ([activity-authority.md](activity-authority.md)).

## Sidecar admission and backpressure

The inference sidecar admits a small configured number of active jobs. When it cannot admit a request
it answers at once with HTTP 429, `{"status":"error","error":{"code":"busy",...}}` and a
`Retry-After` header (seconds). `InferenceClient` maps that to `InferenceClientError.busy`. A busy
answer is not a result: no caller records it as a withheld or failed computation, and it does not
consume a job's failure budget. The caller leaves the work pending and comes back later.

## PPG segments sent to `sensor.biomarkers.v1`

The worker builds `input.ppg.segments[]` (docs/sensor-biomarkers/CONTRACTS.md §4). Existing members
are unchanged in meaning (`start_unix`, `duration_s`, `samples` as absolute ADC counts at the native rate,
`sample_count_per_second`, `config.stable`). The native rate is whatever the request declares: recorded v26
packets show 25 distinct samples per record (the anchor plus 24 deltas, with the next record's anchor as the
26th), so anchored v26 segments are sent at 25 Hz rather than the earlier 24-point convention; the evidence
and the one-place switch are in [ppg-transport.md](ppg-transport.md). New members, all optional on the wire so an older worker
and an older sidecar keep working, and always sent by this branch's worker:

- `run_id` (string): the contiguous, configuration-compatible run the segment belongs to. Segments that
  share a `run_id` are consecutive pieces of one run with no gap between them. Segments with different
  `run_id`s are never joined into one signal. A segment without `run_id` is its own run.
- `config.identity` (string): the optical configuration identity; equal strings mean compatible
  configurations, so amplitudes may be compared. `config.known` (bool) is true only when gain, drive and
  channel are actually identified by the transport, not inferred. Further descriptive `config` members
  (burst index, source/drive/range/offset) may accompany them. Without `config.identity` the sidecar
  keeps its legacy identity (sorted `config` members).
- `clock` (object): native clock provenance. The sidecar interprets two members:
  `packet_timing_verified` (bool: the per-second grid was checked against recorded packet timing, not
  inferred from a sample count) and `samples_per_second` (int; must equal `ppg.native_rate_hz`, else the PPG
  families are withheld `blocked_input`). Other members (`source`, `grid`, `endpoint`) are provenance,
  carried through and not interpreted. `rhythm_shadow` requires `packet_timing_verified: true` and is
  otherwise withheld `unverified_sample_clock`; descriptive families record the flag. A segment without
  `clock` is legacy (rhythm keeps its old `config.stable` gate).

Rules both sides hold to:

- `config.identity` names the optical configuration only (gain, drive, channel, LED), never a per-burst or
  per-record counter; burst and record identity go in `run_id` or in descriptive `config` members. When the
  transport does not identify the configuration, `config.identity` is `"unknown"` and `config.known` is
  false; the sidecar then never pools amplitude across runs (amplitude is reported per run and marked
  `configuration_unidentified`), while gain-independent timing features (upstroke, width50) are pooled with
  exposure weights.
- Segments sharing a `run_id` are time-contiguous (each starts where the previous one ended) and share one
  `config.identity`. A violation is split, never joined, and counted as `ppg_run_id_discontinuity`.
- `config.stable: true` is still sent, because an older sidecar's rhythm gate reads it.
- The worker's request builder writes a golden envelope with these members to
  `Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sensor_biomarkers_request_envelope.json`;
  the sidecar tests consume that file.
- The lane merges per-request family stages into the day document without dropping later requests'
  per-configuration blocks, per-run exposure blocks or rhythm score vectors; per-identity blocks are pooled
  (counts summed, distribution bins pooled), per-run blocks are concatenated.

The sidecar computes pulse detection, shape, quality and rhythm preprocessing within one run at a time,
aggregates with the real exposure of each run, and reports amplitude-bearing results per configuration
identity, never pooled across identities. The samples it receives are never modified in place.

## Release modes

Every model output carries the release mode it was produced under, and that mode is never raised
downstream. A cache, route, store or decoder may lower it (for example to `shadow` when a pin does
not match), never raise it. Vocabulary per producer is recorded in the inventory below.

## Release-mode vocabulary

| Producer | Modes it can carry | Who may lower it |
| --- | --- | --- |
| HART (+ transition expert) | `production` | n/a |
| ElderNet standalone | `shadow`, `candidate` (`FRWHOOP_ELDERNET_MODE`; candidate needs pins and π) | policy (missing pin/prior, input revision mismatch, model differs) |
| ElderNet embedded in HART | none recorded, read as `shadow` | always shadow; superseded by the standalone route |
| Motion heads (Inertia-1 / ActiNet) | `shadow`, `candidate` (`FRWHOOP_INERTIA_MODE`), never above the bundle's `evidence_tier_max`; stand-in encoders always `shadow` | policy |
| Physiology candidates (`physiology_candidate_results`) | requested `shadow`/`active`; effective always `shadow` | `active_promotion_deferred` |
| Sensor families | tier `descriptive` / `research` / `shadow` per family | n/a (rhythm is shadow by construction) |

No store, route, cache or decoder raises a mode. Rows written before Spec 01 read as their recorded mode, never
as production.

## Provider-to-consumer inventory

| Model / provider | Input contract | Release | Storage | API | App consumer |
| --- | --- | --- | --- | --- | --- |
| HART v0 (`activity_context.serve`) | raw IMU 20 Hz chunks | production | `activity_encoder_windows` (`hart-windows-1`), `activity_context_*` | `/scores/activity-windows`, activity documents | phone decoder |
| Transition expert (in HART's service) | HART windows | HART lineage | `transition` in `hart-windows-1` | same | phone decoder (unchanged) |
| ElderNet standalone | IMU chunks → 30 Hz, 10 s / 5 s hop | shadow / candidate | `activity_gait_windows_days` (+`release_mode`, `authority`) | `/scores/gait-windows` | walking card (see Decisions); decoder only through the policy, i.e. never today |
| ElderNet embedded in HART | HART chunks | shadow | `g_*` in `hart-windows-1` | `/scores/activity-windows` (`embedded_gait_release_mode: shadow`) | none |
| Motion heads, Inertia-1 / ActiNet encoders | 30 s @ 20 Hz windows | shadow (no real weights / no trained Nara heads) | `activity_motion_heads_days` | none | none |
| Joint activity candidate + ablations | the job's selection | candidate, never published | `activity_candidate_days` (service role only) | none | none |
| `production.runs.v1` (HRV) | scoring candidate inputs | candidate run of the production algorithm; canonical HRV stays the Swift scoring path | `physiology_candidate_results` | none | none |
| `neurokit2.shadow.v1` (HRV) | RR runs | shadow | `physiology_candidate_results` | none | none |
| `hypnospy.hr-boundary.v1` (sleep boundary) | HR series | shadow | `physiology_candidate_results` | none | none |
| `sleepecg.wrn-gru-mesa.v1` (sleep stage) | RR/HR series | shadow | `physiology_candidate_results` | none | none |
| `/v1/sleep-features` | sleep feature request (Spec 02 owns the schema) | enrichment | `sleep_features` in the scoring snapshot | scores | `SleepFeatureCards` |
| `sensor.biomarkers.v1` descriptive families | IMU segments; PPG runs (`run_id`/`config`/`clock`) | descriptive | `sensor_biomarker_days` | `/scores/sensor-biomarkers` | `SensorBiomarkersSection` (flagged) |
| ParaDigMa tremor / arm_swing (via the aggregate route) | IMU + placement/orientation | research, flag off | same | same (not rendered) | none |
| DeepBeat / SiamAF rhythm (via the aggregate route) | PPG runs with a verified packet clock | shadow, flag off; withheld `unverified_sample_clock` today | same (`raw_scores`) | same (not rendered) | none |
| Phone anchored PPG source | banked v26 rows with `baseCode` | raw input, flag off | B2 object + `object_manifests` (protocol 1.5, schema 3) | `POST /push/objects` | none |

Area detail: [activity-authority.md](activity-authority.md), [runtime-bounds.md](runtime-bounds.md),
[ppg-transport.md](ppg-transport.md), [sensor-families.md](sensor-families.md), [provisioning.md](provisioning.md).

## Read-only runtime checklist (droplet)

Nothing here writes. Run as the service users or a read-only database role.

1. **What runs.** [deploy/OPERATIONS.md "Runtime identity checklist"](../../deploy/OPERATIONS.md#runtime-identity-checklist):
   heartbeat `meta.identity.executable.sha256` equals `sha256sum /proc/<pid>/exe` and `matches_release`;
   sidecar `/healthz` `identity` (code revision, `uv.lock` and manifest digests, `model_revision` equal to
   `readlink /opt/frwhoop-models/current`, artifacts `verified`, `providers.<id>.loaded` with
   `loaded_source: "worker"`).
2. **Flags.** `systemctl show frwhoop-worker frwhoop-inference -p Environment` and the env files: every Spec 01
   knob at its default unless deliberately set (`FRWHOOP_ELDERNET_MODE`, `FRWHOOP_INERTIA_MODE`,
   `FRWHOOP_CANDIDATE_SCHEDULER`, `NOOP_PUSH_ADVERTISE_PPG_ANCHOR`, family flags).
3. **Resources.** `systemctl status` memory/tasks of both units; `/healthz` `execution` (active, waiting,
   terminations, per-lane RSS); `ps -o pid,rss,nlwp,args --ppid <worker pid>` for the activity children.
4. **One request per provider.** Over loopback with the committed fixtures ([sensor-families.md](sensor-families.md)
   checklist for `sensor.biomarkers.v1`; [runtime-bounds.md](runtime-bounds.md#read-only-runtime-checklist)
   for `/v1/infer` and `/v1/sleep-features`).
5. **Persisted and app-visible consumers.** The per-area queries: activity rows' `release_mode`/`authority`
   and that nothing expert-shaped is production ([activity-authority.md](activity-authority.md#read-only-runtime-checklist-droplet));
   the candidate queue and `physiology_selected_provider` modes ([runtime-bounds.md](runtime-bounds.md#read-only-runtime-checklist));
   `object_manifests` by protocol/schema and the sensor lane counters ([ppg-transport.md](ppg-transport.md#read-only-runtime-checklist));
   `sensor_biomarker_days` families.

No droplet session was used for this branch: none of the above has been run against the live host.

## Decisions and deviations

1. **Anchored v26 PPG is 25 Hz, not the spec's 24-point convention.** In recorded data the anchor plus 24
   deltas are 25 distinct samples. Two independent checks: the next record's anchor is not the 25th point
   (exact in 1.8% of 3,528 pairs), and the strap's own v20 optical frames carry 25 absolute samples per second
   that equal the reconstructed v26 points exactly in 823 of 824 overlapping seconds (the exception is a
   saturated-delta second that is withheld anyway). The 24-point convention would drop one real sample per
   second and misplace the rest by 4%. One enum (`ppgGrid`) switches back; legacy 24 Hz envelopes still
   validate. `clock.packet_timing_verified` stays false because arrival times (historical offload) cannot
   bound the hardware clock, so rhythm stays withheld. Evidence: [ppg-transport.md](ppg-transport.md).
2. **v26 carries no gain, drive or channel**, so `config.identity` is `"unknown"` and amplitude is reported per
   run, never pooled.
3. **No expert is production.** The canonical activity decode on server and phone uses only production-released
   expert sources; today that means HART alone. Days whose stored HART windows still carry embedded ElderNet
   windows decode without them (on both sides).
4. **`active` stays non-canonical.** It is visible as requested `active` / effective `shadow` /
   `active_promotion_deferred`; what a validated promotion path needs is listed in runtime-bounds.md.
5. **Worker unit memory ceiling not set**: measured child RSS is recorded, the droplet's worker RSS is not
   (deploy/README.md, "Rolling out the Spec 01 model-integration changes").
6. **Owner decisions left open**: the walking card shows ElderNet gait quality from the newest row of any mode
   (shadow included) as a descriptive reading; it never shapes the decode. Whether it should be hidden until
   ElderNet is released is the owner's call. Turning on `NOOP_PUSH_ADVERTISE_PPG_ANCHOR` and
   `noop.cloud.ppgAnchorUpload` (adds about 80 bytes of upload per optical second) is also the owner's call.

## Interfaces for Specs 02 and 03

- **New optional checkpoint (Spec 03).** Add it to `models/manifest.json` as an optional entry with a
  machine-readable `source`; the provisioner stages and verifies it, and a missing one withholds only its
  provider ([provisioning.md](provisioning.md#extension-points-for-specs-0203)). Report measured digests from
  `loaded_identity()` on the provider so `/healthz` shows them.
- **New activity expert or head bundle (Spec 03).** Produce rows carrying `mode` and `summary.authority`; add a
  source type to `ActivityExpertSelection.select` so it joins candidate arms and ablations automatically. It
  cannot become production without a production-tier bundle, pins and a policy change
  ([activity-authority.md](activity-authority.md#extension-points-for-specs-0203)).
- **New candidate metric (Spec 02/03).** Add it to `CandidateStage.metrics`, give `DayScorer.CandidateInputs`
  its payload, and extend the metric CHECK lists in a new migration; the queue, fairness and fences need no other
  change ([runtime-bounds.md](runtime-bounds.md#extension-points-for-specs-02-and-03)).
- **Sleep-features computation (Spec 02).** It runs in the isolated `sleep_features` process lane under
  `FRWHOOP_SLEEP_FEATURES_BUDGET_MS`; busy and timeout keep the core snapshot. The request schema is Spec 02's.
- **New PPG or IMU feature (Spec 02).** Consume `input.ppg.segments` runs as delivered (`run_id`,
  `config.identity`, `clock`, native rate from the request) inside the sidecar's per-run computation
  ([sensor-families.md](sensor-families.md#extension-points-for-specs-02-and-03),
  [ppg-transport.md](ppg-transport.md#extension-points-for-specs-02-and-03)).
- **New optional sensor family.** Implement the three-member adapter interface in `sensor_biomarkers/optional.py`.

## Verification record

Integration commit `80ab2dc6b` (all five areas, three rounds, the independent review's fixes). Run by the parent on
2026-10-08 on a shared macOS host (load average often 300-900 from other sessions) and in the colima VM `nara-sh`
(arm64 Linux, Swift 6.0.3). Logs: `_build-scratch/spec01/parent/` (outside git). Area docs record their own focused
runs.

| Check | Result |
| --- | --- |
| Worker `xcrun swift test` (Xcode 26.3 toolchain) | 725 tests, 71 skipped (DB suites), 0 failures |
| Worker `xcrun swift test` with `FRWHOOP_TEST_DB_URL` on a throwaway full-chain cluster | 725 tests, 4 skipped, 1 failure: `ContextLaneDatabaseTests.testTheLaneIdlesWhenTheTablesAreMissing`, which derives a second database URL by splitting the URL path and cannot with a Unix-socket `host=` URL (harness limitation, not Spec 01 code). The other ContextLane DB tests pass only with session user `postgres`, which the intake admission check (`20260922130000`) requires. |
| Linux release from the packaged tarball (`deploy/package-release.sh` at `80ab2dc6b`, 1,555 files, all four local packages) through `release-host.sh install / build / switch / status` | build exit 0; `swift build -c release` and `swift test` 725 tests, 71 skipped, 0 failures; `sha256sum` of the binary = `--print-identity` = `508ac13881e4…ff0d`, `matches_release: true`; release tree sealed `dr-xr-xr-x` (arm64; the droplet's x86_64 digest differs) |
| Packaged sidecar deploy tests on Linux (pinned uv, read-only release tree, unprivileged user) | 66 passed, 1 deselected (needs git history, which a release does not carry) |
| Sidecar `uv run --frozen pytest -q -o addopts=""` (macOS) | 605 passed, 44 skipped, 0 failed |
| StrandAnalytics `xcrun swift test --skip LongitudinalBaselineTests` | 3,503 tests, 7 skipped, 0 failures |
| NoopPush `xcrun swift test` | 203 tests, 0 failures |
| ActivityContext `pytest` | 639 passed, 45 skipped, 3 failed: `tests/inertia/test_inertia_golden.py` (3), which fail identically on the base `dab2124f3` code with the same environment |
| Deno: activity routes and full-chain activity SQL, gait/activity window routes, physiology candidates, PPG anchor transport + integration (local Postgres), registry, objects | 50 passed (38 steps), 0 failed |
| Full migration chain on one fresh cluster; the three Spec 01 migrations re-applied; `activity_release_authority_contract.sql` and `physiology_candidate_pending_contract.sql` before and after | all steps pass (idempotent) |
| iOS compile (`NOOPiOS`, generic/platform=iOS, unsigned) | BUILD SUCCEEDED |
| macOS StrandTests (`-only-testing:StrandTests`, `test-without-building`; the first attempt's test host was killed at launch while other sessions ran their own app tests) | 3,228 tests, 13 skipped, 11 assertion failures in 3 cases, all pre-existing: `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` (known time-zone failure) and `ActivityCalibrationSessionTests.{testBeginWithAnEmptyProtocolEndsCleanly, testStepsChainBackToBackAndEveryActivityEndsWithDone}` (reproduced with the base files) |

Acceptance evidence against the spec:

- **Provisioning fixture** enumerates the real manifest schema (11 entries, 18 nested artifacts), verifies required
  bundled/extracted SleepECG artifacts, withholds optional ones per provider, keeps the previous revision on failure,
  and probes as the service user (`test_provisioning.py`; [provisioning.md](provisioning.md)).
- **Shadow cannot affect production**: worker replay (`ActivityAuthorityReplayTests`: published bytes identical with
  experts off / shadow / candidate; all off = HART alone; disabling an expert reproduces its ablation), phone replay
  (`ActivityPhoneAuthorityTests`), DB release clamp (`activity_release_authority_contract.sql`), and old phones get no
  decoder evidence (route tests).
- **PPG chain**: one byte golden shared by NoopPush, the receiver (Deno) and the worker; the phone source uploads the
  golden's exact bytes; anchorless data stays `missing_ppg_anchor`; gaps/config changes split runs
  ([ppg-transport.md](ppg-transport.md)).
- **Families** reach their real adapters through `sensor.biomarkers.v1` over HTTP with the worker's golden envelope;
  one failed family keeps the others ([sensor-families.md](sensor-families.md)).
- **Runtime bounds**: real-process tests show repeated timeouts never grow processes or threads, slots free only after
  reap, quarantine stops one overrunning provider from starving the rest; scheduler starvation tests with budget 1-2;
  stale revisions and lost leases refused in SQL ([runtime-bounds.md](runtime-bounds.md)).
- **Inventory and checklist**: above. **Droplet: not accessed**; nothing in the checklist has been run live, and no
  deployment is claimed.

Independent review: a separate reviewer agent read `dab2124f3..HEAD` across all components (no edits) and reported 3
high, 6 medium and 8 low findings; every one was fixed in round 3 except the residual below. Doc nits were applied.

Not resolved in code (by design or out of reach):

- An installed phone keeps gait days it stored before the server change in its own store and decode until the app
  updates; the server can no longer send it decoder evidence, but cannot reach what is already on the device.
- Pre-existing failures outside Spec 01: the three inertia golden tests above; `ActivityCalibrationSessionTests` (2)
  and the known time-zone StrandTests failures, which reproduce on the base.
