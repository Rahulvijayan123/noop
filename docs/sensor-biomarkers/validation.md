# Sensor biomarkers: validation record

Branch `feat/sensor-biomarkers-20261006` (from `origin/main` fae049a). Spec-31 (additive sensor
biomarkers) implementation record: what was built, what was actually tested, with which results,
and which release gates remain open. No production deployment and no migration application
happened as part of this work.

## 1. What was delivered

| Tier | Families | Where | Flags (all default OFF) |
| --- | --- | --- | --- |
| descriptive | movement (ENMO + low-movement bouts + transitions), oscillation (3-7 Hz gyro band power), ppg_quality, pulse_shape | Python sidecar `sensor.biomarkers.v1`; worker lane | `FRWHOOP_SENSOR_BIOMARKERS_ENABLED` (worker), `noop.sensorBiomarkersEnabled` (iOS) |
| gated research | perfusion_research (AC/DC ratio) | same | `FRWHOOP_PERFUSION_RESEARCH_ENABLED` |
| research | tremor, arm_swing (ParaDigMa 1.1.2, real pretrained classifiers) | same, narrow subprocess venv | `FRWHOOP_PARADIGMA_ENABLED` |
| shadow (never user-facing) | rhythm_shadow (DeepBeat; optional SiamAF) | same | `FRWHOOP_DEEPBEAT_SHADOW_ENABLED`, `FRWHOOP_SIAMAF_SHADOW_ENABLED` |

- Sidecar: `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/` (deterministic imu/ppg,
  provider, paradigma, rhythm) + manifest entries + provisioning scripts.
- Worker: `SensorBiomarkerInputs.swift` (verified-object loading, v26 PPG reconstruction, request
  building) + `SensorBiomarkerLane.swift` (job claim/lease/publish, chunk parity) + `main.swift`
  wiring behind `FRWHOOP_SENSOR_BIOMARKERS_ENABLED`.
- Backend: migration `supabase/migrations/20261007140000_sensor_biomarkers.sql` (UNAPPLIED to
  production; jobs + days tables, fingerprint/claim/renew/fail/publish/reconcile functions, RLS),
  read route `GET /functions/v1/scores/sensor-biomarkers` in `_shared/serverScores.ts`.
- iOS: `SensorBiomarkerRepository.swift` + `SensorBiomarkersSection.swift` (flag-gated details
  section on the HRV detail page), tests in `StrandTests/SensorBiomarkerTests.swift`.

## 2. Checks actually run and their results

### Python sidecar (uv, Python 3.12, CPU-only)

`cd Tools/InferenceWorker && UV_LINK_MODE=copy uv run pytest -q` (final run, junit):

- **515 tests, 0 failures, 0 errors, 0 skipped.** Includes:
  - 65 deterministic-family tests (ENMO stationary-1 g = 0 mg; analytic 1.05 g -> 50 mg exactly;
    hysteresis state machine incl. unknown middle band, gap = no transition + censored bout,
    day-boundary continuation; gyro 2 Hz vs 5 Hz band allocation; amplitude-squared scaling;
    Welch-vs-analytic A^2/2 reference at documented 5% tolerance; dominant-frequency null on flat
    data; unit-level exact pulse closed forms; config no-pooling; withheld semantics).
  - 3 chunked-vs-contiguous parity tests (IMU families EXACTLY equal across 5-minute chunk
    boundaries; PPG families within documented detector-edge tolerances; no duplicate samples at
    seams).
  - ParaDigMa tests against the REAL pinned assets: sha256 verification (tremor
    4be2ac2b... per spec; gait f2309bb8...; filtering 94068bca...), corruption rejection, upstream
    reference parity reproduced to machine precision (max diff <= 1e-6 on all prediction columns:
    tremor n=182, gait n=725, arm-activity n=50), deterministic CPU reproducibility, fail-closed
    gating (unknown watch side/orientation withholds arm_swing only; tremor runs without gait;
    5 Hz synthetic motion NOT asserted to be tremor).
  - Rhythm tests with the REAL staged weights: DeepBeat `deepbeat.h5` (GPL-3.0) loads in-env via
    `keras.saving.load_model(..., compile=False)` (keras 3.15.1 + torch backend; TF-2.16.1 parity
    max diff 5.96e-08 quality / 2.38e-07 rhythm, argmax 8/8); shapes (800,1)/(3,2); label mapping
    verified against upstream evaluation code; deterministic CPU inference. SiamAF
    `final_model.pt` (MIT) strict state-dict load (verified `module.` prefix strip,
    `weights_only=True`, CPU, eval + inference_mode), two-argument single-source wrapper, finite
    logits, CPU reproducibility. Both stay withheld `preprocessing_unverified` (DeepBeat original
    filter settings unresolved upstream) and never produce user-facing output.
  - Provider/server integration: full POST /v1/infer path, family independence (a failing family
    never discards others), missing-optional-artifact independence, manifest verification.

### CloudWorker (Swift, macOS)

`cd Tools/CloudWorker && PKG_CONFIG_PATH=<homebrew libs> FRWHOOP_TEST_DB_URL=<disposable local PG>
swift test`:

- **560 tests executed, 0 failures, 37 skipped** (the skips are other lanes' DB-backed suites that
  need their own migration sets, unchanged from before this feature).
- SensorBiomarkerInputsTests: 32 tests (31 pure + 1 DB-backed verified-object resolution against a
  faithful `object_manifests` schema: mixed-owner/ unverified/ not-ready rejection; v26 anchor
  reconstruction vs independently computed absolutes; delta-only seconds withheld
  `missing_ppg_anchor` (the production ppgWaveformSample wire carries NO baseCode, so PPG
  amplitude families are honestly withheld until an anchor side-channel exists); saturated
  rails/dark blocks/empty slots fail closed; endpoint ownership (24-of-25-point window, no
  boundary duplication); 25 Hz detection reported, never assumed; 8 MiB request budget).
- SensorBiomarkerLaneTests: 18 tests (claim/publish round trip via a stub sidecar; lease expiry
  reclaim; publish fence: a stale worker never overwrites a newer result; late input revision
  republishes one row; sidecar-missing independence with bounded backoff; chunk partition: every
  second owned exactly once, segments <= 5 min, all requests < 8 MiB).

### Supabase (Deno)

`cd supabase/functions && EDGE_TEST_ARTIFACTS=<external dir> deno test --allow-all tests/...`:

- `sensor_biomarkers_sql_test.ts`: **1 test, 11/11 steps passed** (schema/PK/RLS owner isolation
  via real PostgREST; fingerprint determinism; idempotent enqueue + input_revision bump for late
  objects AND family changes; claim/lease/renew/expiry; bounded backoff + dead-letter at 8;
  stale-publish fence (stale token / wrong revision / expired lease -> NULL, never writes, newer
  result never overwritten); document contract incl. the 256 KiB cap and family/status whitelist;
  reconcile idempotency; device/account cascades).
- `sensor_biomarkers_route_test.ts`: **8/8 passed** (owner+latest-per-day, 404 absent, 31-day
  bound, malformed rejection, 401, registered-device 409).
- Regression subset (activity_windows, enrolled_scores, scores auth, server scores auth,
  physiology context routes, stretch feedback, ground truth labels, result days, placement
  route): **93 passed, 1 failed** - `placement_route_test.ts`, which fails IDENTICALLY on HEAD
  (verified by swapping in the unmodified `serverScores.ts`); pre-existing, unrelated to this
  feature (a placement POST returns 400 where the test expects 200).

### iOS/macOS app

`xcodegen generate && xcodebuild test -project Strand.xcodeproj -scheme Strand
-destination 'platform=macOS' -only-testing:StrandTests/SensorBiomarkerTests`:

- **34 tests, 0 failures** (parent-verified on macOS after the Sentry build fix): valid/partial/
  withheld rendering (never a measured zero for withheld data), flag-off -> zero network requests
  and no section, owner/device/day cache scoping + sign-out reset, malformed + oversized (256 KiB)
  rejection, bounded retry (3 transient attempts max, no retry on 4xx), route/auth shape.
- Full StrandTests suite: **3035 tests, 8 skipped, 1 failure** - the pre-existing
  `IntradayWordingAndCoachTests` failure documented in docs/IOS.md as failing on a clean checkout
  (unrelated; code untouched by this feature).
- **Pre-existing macOS build break at HEAD fixed** (commit e6f2fee): HEAD's
  `enableReportNonFullyBlockingAppHangs` is exposed by the pinned Sentry binary on iOS only and
  broke the macOS build; gated `#if os(iOS)` (iOS behavior unchanged).

## 3. Performance evidence (measured, this machine, CPU-only)

Real sidecar server (`InferenceServer` on loopback), real requests through POST /v1/infer,
representative payloads (100 Hz IMU + 24 Hz PPG, 4 descriptive families):

| Scenario | Wall time | Request size | Response size |
| --- | --- | --- | --- |
| 5-minute chunk (mean of 3) | 0.51 s (max 0.57 s) | 1,556,193 B (~1.5 MB, well under the 8 MiB budget) | 10,132 B |
| Replayed day (288 x 5-minute chunks, sequential) | 189.1 s total (~0.66 s/chunk) | ~1.5 MB/chunk | - |

CPU: 157.4 s user + 2.6 s sys for the full-day replay; peak RSS ~782 MB (macOS ru_maxrss; dominated
by the shared scientific stack the sidecar already ships). A day's compute fits the day with
enormous margin on a single CPU thread. No GPU anywhere. The lane bounds concurrent model work and
subprocess lifetimes (see SensorBiomarkerLane).

## 4. Artifacts and provenance (all hashes measured from actual downloaded bytes)

| Artifact | Pinned source | Size | sha256 | License | Status |
| --- | --- | --- | --- | --- | --- |
| tremor_detection_clf_package.pkl | biomarkersParkinson/paradigma @ 4735d6d2 (v1.1.2) | 1,475 B | 4be2ac2b511c501257ea8186068f06a94d0084d653840e907be72cd103dc5b0e | Apache-2.0 | verified, real inference executed |
| gait_detection_clf_package.pkl | same | 11,497,247 B | f2309bb8cff87648a54a338493db2cedb25b4a9a60cd77bbdb2d17e010a7cc25 | Apache-2.0 | verified |
| gait_filtering_clf_package.pkl | same | 3,915 B | 94068bca1997755e17fddae662dd0433ac06c12a3cd32869c6d9dc586ab845f4 | Apache-2.0 | verified |
| deepbeat.h5 | AshleyLab/deepbeat @ f54004a8 | 1,502,052 B | 6df126f88855388f8706ea6e158b80902752a019b1f3c26d3ceab22991e4eee3 | GPL-3.0 (research shadow only) | verified, real inference executed |
| final_model.pt | chengstark/SiamAF @ c05be9e3 | 10,915,597 B | a141b91cf5a5ef8eb4a2a6142273852ee2810a36e6fba1642a4836b3402176be | MIT | verified, real inference executed |

All five are recorded in `models/manifest.json` with `verify_at_startup: true` and
`required_for_readiness: false` (a missing optional artifact never gates process readiness).
Provisioning scripts (deploy-prep only, never at inference time):
`scripts/provision_{paradigma,deepbeat,siamaf}.py`. ParaDigMa runs in a narrow optional subprocess
venv (python 3.12, numpy 2.5.3, scipy 1.18.1, pandas 2.3.3, scikit-learn 1.6.0 - the main env's
scikit-learn 1.9.1 is outside paradigma's <1.6.1 range), so no unrelated inference dependency was
upgraded. DeepBeat/SiamAF load in the main env (keras 3.15.1 + torch 2.14.1; TF parity verified).

## 5. Remaining release gates (open, by design)

1. **PPG anchor side-channel**: the production `ppgWaveformSample` object wire carries no
   `baseCode`, so every v26 second is honestly withheld `missing_ppg_anchor`. PPG amplitude/
   quality families need the phone to send anchors (a codec revision) before they produce values;
   IMU families deliver without it (spec Phase A accepts exactly this).
2. **Placement metadata**: `watch_side`/`device_orientation` are unknown in the lane, so ParaDigMa
   arm_swing is withheld `unknown_wrist_placement`/`unknown_orientation` (tremor-only runs).
   Placement enrichment is future work; the gates fail closed.
3. **DeepBeat preprocessing provenance**: upstream ships no preprocessing code; the original
   bandpass settings are unresolved, so rhythm outputs stay withheld `preprocessing_unverified`
   and are nonpublishable (spec 6.6 requires exactly this).
4. **WHOOP accuracy benchmarks**: none performed (spec: synthetic execution tests cannot satisfy
   clinical/domain gates). ParaDigMa portability needs annotated WHOOP captures; DeepBeat/SiamAF
   need ECG-labeled WHOOP recordings, subject/session-separated evaluation, sensitivity/
   specificity/false-alerts-per-day before any promotion out of shadow.
5. **Migration application**: `20261007140000_sensor_biomarkers.sql` is delivered UNAPPLIED;
   applying it to production is a separate, explicitly authorized step.
6. **Pre-existing failures (not this feature)**: `placement_route_test.ts` (Deno; fails on HEAD)
   and the docs/IOS.md-documented `IntradayWordingAndCoachTests` macOS failure. The Sentry macOS
   build break at HEAD was fixed (e6f2fee).
7. **iOS end-to-end against the live route**: the repository/parse/cache/retry layers are
   URLProtocol-stub-tested; a device-path test against a deployed backend was not run (no
   deployment was authorized).

## 6. Infra incident note

Mid-task the external SSD holding the worktree unmounted (bus error). All state was recovered
after remount; `git fsck` clean; all results above were re-verified in-place after remount.
