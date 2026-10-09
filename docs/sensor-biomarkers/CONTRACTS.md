# Sensor biomarkers: shared contracts

Parent-owned contract for the additive sensor-biomarker feature (spec-31). Every worker codes
against this document; changes here require parent approval. The spec
(`/Volumes/Untitled/Downloads/spec-31.md`, mirrored decisions below) is authoritative for scope;
repository code is authoritative for transport, units, identity and storage.

Branch: `feat/sensor-biomarkers-20261006` (from `origin/main` fae049a). Preserve existing scoring
behavior; nothing here may touch canonical scoring, HRV RR filtering or sleep pipelines.

**Spec 01 (model integration) changes, 2026-10-08.** The request gained run, configuration and clock
members (§4), PPG is computed per contiguous configuration-compatible run, optional families are reached
through the aggregate route with distinct failure reasons (§3), and anchored v26 PPG is sent at its
recorded 25 Hz. Details: `docs/model-integration/sensor-families.md` and
`docs/model-integration/ppg-transport.md`; the shared segment rules are in
`docs/model-integration/README.md`.

## 1. Tiers and families

| Family | Tier | Provider revision | Enabled flag (worker env) |
| --- | --- | --- | --- |
| `movement` (ENMO, low-movement bouts, transitions) | descriptive | `imu-biomarkers/1.0.0` | `FRWHOOP_SENSOR_BIOMARKERS_ENABLED` |
| `oscillation` (gyro 3–7 Hz band power) | descriptive | `imu-biomarkers/1.0.0` | `FRWHOOP_SENSOR_BIOMARKERS_ENABLED` |
| `ppg_quality` (corruption/missingness/clipping/flatness, template similarity) | descriptive | `ppg-biomarkers/1.0.0` | `FRWHOOP_SENSOR_BIOMARKERS_ENABLED` |
| `pulse_shape` (amplitude, upstroke, width50, normalized area) | descriptive | `ppg-biomarkers/1.0.0` | `FRWHOOP_SENSOR_BIOMARKERS_ENABLED` |
| `perfusion_research` (guarded AC/DC ratio) | gated research | `ppg-biomarkers/1.0.0` | `FRWHOOP_PERFUSION_RESEARCH_ENABLED` |
| `tremor` (ParaDigMa rest-tremor) | research | `paradigma/1.0.0` | `FRWHOOP_PARADIGMA_ENABLED` |
| `arm_swing` (ParaDigMa gait) | research | `paradigma/1.0.0` | `FRWHOOP_PARADIGMA_ENABLED` |
| `rhythm_shadow` (DeepBeat; optional SiamAF) | shadow (never user-facing) | `deepbeat/1.0.0`, `siamaf/1.0.0` | `FRWHOOP_DEEPBEAT_SHADOW_ENABLED`, `FRWHOOP_SIAMAF_SHADOW_ENABLED` |

All worker flags are OFF by default (exactly `"1"` enables, mirroring `FRWHOOP_ACTIVITY_ENABLED`).
The Swift sidecar request carries `families` = the enabled set; the sidecar computes only those.

## 2. Measurement keys (stable, spec section 8)

Movement: `enmo_median_mg`, `enmo_p95_mg`, `low_movement_seconds`, `low_movement_fraction`,
`low_movement_bout_count`, `low_movement_bout_median_seconds`, `low_movement_bout_max_seconds`,
`low_movement_censored_bout_count`, `low_movement_continuation_count`,
`low_to_moving_transition_count`, `low_to_moving_transitions_per_observed_hour`,
`low_movement_bouts_per_observed_hour` (explicitly descriptive, not a GGIR fragmentation score).

Oscillation: `wrist_oscillation_power_3_7hz_median`, `wrist_oscillation_power_3_7hz_p95`.

PPG quality: `valid_waveform_fraction`, `template_similarity_median`, `template_similarity_p25`.

Pulse shape: `pulse_amplitude_median_au`, `pulse_amplitude_iqr_au`, `pulse_upstroke_median_ms`,
`pulse_upstroke_iqr_ms`, `pulse_width50_median_ms`, `pulse_width50_iqr_ms`,
`pulse_normalized_area_median`, `pulse_normalized_area_iqr`, `pulse_accepted_count`,
`pulse_rejected_count`.

Tremor (research): `eligible_rest_seconds`, `classified_tremor_seconds`, `rest_tremor_time_percent`,
`tremor_frequency_median_hz`, `paradigma_tremor_power_median`.

Arm swing (research): `eligible_arm_swing_seconds`, `arm_swing_bout_count`, `arm_swing_rom_median_deg`,
`arm_swing_rom_p95_deg`, `arm_swing_peak_velocity_median_dps`, `arm_swing_peak_velocity_p95_dps`.

Perfusion (gated research): `estimated_ac_dc_ratio_percent`.

Rhythm (shadow): `deepbeat_quality_scores`, `deepbeat_rhythm_scores`, `siamaf_rhythm_scores`
(ordered model score vectors + class labels + preprocessing/domain status; never a burden field).

Every measurement entry carries: key, finite value or null, unit, denominator where relevant,
sample/window/pulse count, method, native resolution when relevant, and configuration identity for
pulse shape. Null + reason, never a fabricated zero.

## 3. Family document (JSONB stored in `sensor_biomarker_days.document`)

```json
{
  "schema_version": 1,
  "analysis_version": "sensor-biomarkers/1.0.0",
  "input_revision": "sha256:<64-hex>",
  "interval_start_utc": "2026-10-06T00:00:00Z",
  "interval_end_utc": "2026-10-07T00:00:00Z",
  "processed_at_utc": "2026-10-07T00:05:00Z",
  "families": {
    "movement": {
      "status": "ok|withheld|error",
      "release_tier": "descriptive",
      "provider_revision": "imu-biomarkers/1.0.0",
      "observed_seconds": 0,
      "eligible_seconds": 0,
      "contact_state": "unknown",
      "measurements": {"enmo_median_mg": {"value": 12.5, "unit": "mg", "denominator": "valid 5s epochs", "count": 17280}},
      "reason_counts": {},
      "reason": null
    },
    "tremor": {"status": "withheld", "release_tier": "research", "reason": "unknown_wrist_placement", "measurements": {}}
  }
}
```

A zero-eligible family must never publish fabricated values. Family statuses are independent; a
failed optional family never discards valid families. Payload budget: <= 256 KiB per day document.

Reason vocabulary (extends the sidecar `WithheldReason` enum with detail codes in
`reason`/`reason_counts`): `unverified_sample_clock`, `missing_ppg_anchor`, `saturated_delta`,
`unverified_optical_dc`, `unknown_wrist_placement`, `unknown_orientation`,
`insufficient_eligible_time`, `unsupported_native_rate`, `preprocessing_unverified`,
`no_verified_input`, `model_unavailable`, `not_enough_valid_data`, plus the sidecar's existing enum
values. `no_verified_input` (no verified object / no usable second reached the family: an empty slot,
a dark block, a missing modality) and `model_unavailable` (the family's model or pinned weights are not
available, or the sidecar answered nothing for a family it was sent) are the canonical codes of
`contracts/reason-codes.json`. Before 2026-10-09 both were published as `artifact_unavailable`; stored
documents keep that value, readers accept it and show a reason that claims neither cause, and nothing
writes it any more.

Added by Spec 01: `family_disabled` (flag off), `runtime_unavailable` (an optional family's isolated
runtime is missing), `adapter_broken` (status `error`; detail `adapter_import_error`,
`adapter_interface_mismatch` or `adapter_exception` in `reason_counts`), `blocked_input` (for PPG:
`clock.samples_per_second` differs from `native_rate_hz`), `ppg_run_id_discontinuity` (count: a `run_id`
reused across a gap or a configuration change was split), `ppg_run_shorter_than_detector_window`,
`ppg_run_no_pulses_detected`, `configuration_unidentified` (count: amplitude-bearing results withheld or
reported per run because the transport did not identify gain/drive/channel) and
`unverified_sample_clock_runs` (count, rhythm). A broken adapter, missing weights and a disabled flag are
always distinguishable, and one failing family never discards another.

`pulse_shape` documents add `computation: "per_run"`, `native_rate_hz`, `native_sample_period_ms`,
`runs` (bounded listing of runs with their status and eligible seconds), `configurations[]` (one block per
configuration identity; never pooled across identities; `pooled_across_configurations: false`) and, for
unidentified configurations, `amplitude_scope: "per_run"` with `run_amplitudes` (one amplitude summary per
run, at most 12 listed).

## 4. Sidecar request/response (POST /v1/infer, metric `sensor_biomarkers`)

One request per (device, contiguous chunk-group); the lane is responsible for chunk/rejoin parity.

```json
{
  "metric": "sensor_biomarkers",
  "context": {"interval_start_utc": "...", "interval_end_utc": "...", "iana_timezone": "UTC", "live": false},
  "input": {
    "schema_version": 1,
    "device": {"id": "...", "family": "whoop5"},
    "input_revision": "sha256:<hex>",
    "day_utc": "2026-10-06",
    "imu": {
      "sampling_rate_hz": 100,
      "units": {"accel": "g", "gyro": "deg/s"},
      "segments": [
        {"start_unix": 1780917232, "duration_s": 300,
         "accel_g": [[x, y, z], ...], "gyro_dps": [[x, y, z], ...]}
      ]
    },
    "ppg": {
      "native_rate_hz": 25,
      "units": "adc_counts",
      "segments": [
        {"start_unix": 1780917232, "duration_s": 40,
         "samples": [ ... absolute reconstructed ADC counts ... ],
         "sample_count_per_second": 25,
         "run_id": "ppg-1780917232",
         "config": {"stable": true, "identity": "unknown", "known": false, "burst_index": 1},
         "clock": {"source": "strap_record_second", "grid": "uniform-25hz-v26-continuity",
                   "endpoint": "own_record", "record_period_s": 1, "phase_s": null,
                   "sample_time": "start_unix + phase_s + k/25", "grid_evidence": "...",
                   "samples_per_second": 25, "packet_timing_verified": false}}
      ]
    },
    "watch_side": "left|right|unknown",
    "device_orientation": "screen_up|screen_down|unknown",
    "families": ["movement", "oscillation", "ppg_quality", "pulse_shape", "tremor", "arm_swing", "rhythm_shadow"]
  }
}
```

Rules:
- `imu`/`ppg` keys are omitted when no verified raw objects exist for that modality; the
  corresponding families answer `withheld` with a precise reason (`no_verified_input`).
- PPG `samples` are ABSOLUTE reconstructed values (baseCode + cumulative deltas, per 1-second v26
  record). Anchored records (NPB1 format 3, protocol 1.5) are sent at their recorded 25 Hz: the anchor
  plus 24 deltas are 25 distinct samples and the next record's anchor is the 26th
  (`docs/model-integration/ppg-transport.md` has the evidence and the one-place switch back to the
  24-point convention). Older envelopes at 24 Hz still validate; the sidecar takes the rate from
  `native_rate_hz` and never assumes one. Delta-only records (no baseCode) are never sent as
  amplitudes: the segment builder withholds those seconds with `missing_ppg_anchor`.
- `run_id`, `config.identity`/`config.known` and `clock` (all optional on the wire; always sent by the
  Spec 01 worker) follow `docs/model-integration/README.md`. Segments sharing a `run_id` are one
  contiguous run with one configuration; different runs are never joined into one signal. `config.identity`
  is `"unknown"` and `config.known` false whenever the transport does not identify gain, drive and
  channel (every v26 record). `clock.samples_per_second` must equal `native_rate_hz`;
  `clock.packet_timing_verified` gates `rhythm_shadow`.
- Segment boundaries carry no duplicated samples (endpoint ownership: a sample belongs to exactly one
  segment; consecutive segments share no endpoint sample).
- Serialized request stays under the sidecar `MAX_BODY_BYTES` (8 MiB); shorten chunks if needed.
- Segments of one request must be time-ordered and non-overlapping.

Response: standard `_render` envelope with `status: "ok"`, `label_space:
"sensor_biomarkers.families/1"`, `result.stages` = one stage object per computed family (the exact
family document object from section 3, minus nothing), `raw_scores` = rhythm shadow score vectors,
`coverage` = per-family eligible/observed seconds, `diagnostics.reason_counts`. The Swift lane
re-assembles `families` from `stages`.

Provider id: `sensor.biomarkers.v1` (mode `production`, `publishable` = true only for descriptive
families; research/shadow families carry `release_tier` inside the stage object).

The aggregate provider is the worker's only route to every family, optional ones included: tremor and
arm_swing (ParaDigMa) and rhythm_shadow (DeepBeat/SiamAF) are dispatched through
`sensor_biomarkers/optional.py` to the same functions the standalone providers use. `GET /v1/providers`
reports each family's readiness under the aggregate provider's `capability.families`
(`state` ∈ `ready|disabled|artifact_unavailable|runtime_unavailable|adapter_broken`, with `reason`).

## 5. Persistence and lifecycle (SQL)

Two new tables, additive migration `20261007140000_sensor_biomarkers.sql` (NEVER applied to
production by this task):

- `public.sensor_biomarker_jobs` — mirrors `activity_context_jobs` (lease/fencing, deterministic PK
  `(user_id, device_id, day, analysis_version)`, `input_revision bigint`, `enabled_families text[]`,
  fingerprint function `sensor_biomarkers_fingerprint` over sorted object digests + UTC range +
  analysis version, claim/publish/retry functions `claim_sensor_biomarker_day` /
  `publish_sensor_biomarker_day` / fencing identical in spirit to `claim_activity_context_v2`).
  A stale worker (expired lease) must never overwrite a newer result.
- `public.sensor_biomarker_days` — `(user_id, device_id, day, analysis_version)` PK, `input_revision
  text`, `interval_start_utc`/`interval_end_utc` timestamptz, `status` (`provisional|completed`),
  `document jsonb <= 256 KiB`, `families_ok text[]`, `withheld_reasons text[]`, `published_at`,
  `updated_at`, `run_ms bigint`, `model_revisions jsonb`. RLS: owner read-only (`auth.uid() = user_id`);
  writes service-role only.

Enqueue mechanism: a bounded periodic scan in the lane (mirroring `reconcile_activity_context`)
reconciles newly verified `rawImuSession` and `ppgWaveformSample` objects into affected
(user, device, UTC day) pairs with idempotent unique job keys. Never enqueue from a client request;
never scan unbounded history.

## 6. Read route

`GET /functions/v1/scores/sensor-biomarkers?day=YYYY-MM-DD&deviceId=...` served by
`supabase/functions/scores` (handled in `_shared/serverScores.ts`), installation-credential or
session auth, owner from the credential, bounded to <= 31 days per request. Cache on the phone per
(owner, device, day); cleared at sign-out/account switch (follow `ServerScoreRepository`).

## 7. Artifacts and provenance

Existing mechanism: `models/manifest.json` + `verify_at_startup` sha256 checks against the artifact
root (`/opt/frwhoop-models` in production; local tests use `FRWHOOP_MODEL_ROOT`). Nothing downloads at
inference time. New entries (parent merges into manifest.json):

- `paradigma` — tremor/gait/filtering classifier pkls; tremor pkl sha256
  `4be2ac2b511c501257ea8186068f06a94d0084d653840e907be72cd103dc5b0e`; other two hashes computed
  from actual downloaded bytes and recorded. Apache-2.0.
- `deepbeat` — `deepbeat.h5` (~1.5 MB, GPL-3.0), disabled research provider.
- `siamaf` — `proposed/saved_models/final_model.pt` (~10.9 MB, MIT), optional shadow adapter.

Provisioning scripts live under `Tools/InferenceWorker/scripts/` and stage bytes into the local
artifact root (gitignored); they record source URL, pinned commit, filename, sha256, size, license.
Only pinned trusted assets verified by the manifest are ever unpickled/loaded. Missing optional
artifacts -> provider `not_ready` (adapter state `artifact_unavailable`, family reason
`model_unavailable`); existing services unaffected.

## 8. Ownership map (one writer per file)

| Worker | Owns (exclusive) |
| --- | --- |
| W1 raw-input (Swift) | `Tools/CloudWorker/Sources/frwhoop-worker/SensorBiomarkerInputs.swift`, `Tools/CloudWorker/Tests/frwhoop-workerTests/SensorBiomarkerInputsTests.swift`, fixtures under `Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/` |
| W2 deterministic algorithms (Python) | `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/{__init__.py,contract.py,imu.py,ppg.py,provider.py,perfusion.py}`, tests `Tools/InferenceWorker/tests/sensor_biomarkers/` |
| W3 ParaDigMa (Python) | `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/paradigma/{__init__.py,provider.py,axes.py}`, provisioning `Tools/InferenceWorker/scripts/provision_paradigma.py`, tests |
| W4 rhythm adapters (Python) | `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/rhythm/{__init__.py,deepbeat.py,siamaf.py,provider.py}`, provisioning scripts, tests |
| W5 backend (Swift/SQL/TS) | `Tools/CloudWorker/Sources/frwhoop-worker/{SensorBiomarkerLane.swift,main.swift edits}`, `supabase/migrations/20261007140000_sensor_biomarkers.sql`, `supabase/functions/_shared/serverScores.ts` route, `supabase/functions/tests/sensor_biomarkers*` |
| W6 iOS | `Strand/Push/SensorBiomarkerRepository.swift`, `Strand/Screens/SensorBiomarkersSection.swift`, flag plumbing in `Strand/` |
| Reviewer | read-only + `docs/sensor-biomarkers/validation.md` findings |
| Parent | `docs/sensor-biomarkers/CONTRACTS.md`, `contract.py` METRICS/routing seam, `providers/__init__.py` seam, `sensor_biomarkers` stub seams, manifest.json merge, final integration/commits |

Shared files NOT owned by workers (parent edits): `Tools/InferenceWorker/src/frwhoop_inference/contract.py`
(seam pre-wired), `Tools/InferenceWorker/src/frwhoop_inference/providers/__init__.py` (seam pre-wired),
`Tools/InferenceWorker/models/manifest.json` (parent merges worker-reported entries),
`Tools/InferenceWorker/pyproject.toml` + `uv.lock` (parent applies dependency additions after
worker evidence), `Tools/CloudWorker/Package.swift` (if needed), `project.yml`/XcodeGen (iOS new
files), `docs/sensor-biomarkers/CONTRACTS.md`.

## 9. Non-negotiables (from spec, enforced in review)

- No ElderNet, sleep, baselines, duplicate metrics, training, clinical claims.
- Rhythm outputs stay in shadow mode; withheld when input/preprocessing/metadata gates unresolved.
- No model runs on the phone; the phone only reads published documents.
- Fail-closed on unresolved gates; never publish a zero for withheld data.
- Preserve existing decode/scoring outputs byte-for-byte; existing tests must stay green.
- Migration files are delivered unapplied; no production deployment.
