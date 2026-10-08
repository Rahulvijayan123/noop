# wav2sleep: proposed changes to shared files (fragments for the lead)

The wav2sleep work on `feat/spec03-pretrained-models-20261007` adds new files only. Spec 01 owns
every file below (the manifest, the provider registry, `identity.py`, the Swift worker,
`supabase/`), so the changes are proposals here. Apply them in two phases:

- **Phase A, now:** the manifest entry update. The provider stays unregistered, and no existing test
  changes.
- **Phase B, after Spec 01's anchored PPG transport lands:** the registration line, the identity
  block, the request path and the consumer store.

**Do not apply Phase B while wav2sleep's six activation gates are unmet** (WAV2SLEEP.md §11).

## 0. Re-checked against Spec 01 @ `783ac84da` (2026-10-08)

Spec 01's code has landed on its branch since this fragment was first written. The re-check was run on a
throwaway local merge of both branches (`_build-scratch/spec03-spec01-merge`, branch
`check/spec03-on-spec01-20261008`, not pushed; the merge is clean and no file is touched by both).

| Item | Finding | Change made here |
| --- | --- | --- |
| Manifest | `test_manifest.py` now requires `source` on every artifact; readiness is gated on the entry, not the artifact; the materializer stages only wired entries with status `eligible`/`shadow_eligible`, and the test pins `staged == 7` | Fragment gains `source: {kind: url}` on both artifacts and drops the artifact-level `required_for_readiness`. Applied in memory to the merged manifest: **24/24** `test_manifest.py` tests pass; staged-root verify gives both `verified`, empty root gives both `missing`, not required. |
| Identity | Spec 01 added an optional per-provider hook `loaded_identity() -> Mapping` (`identity.py:260-271`): flat strings, ≤ 32 keys, ≤ 200 characters | The provider and shim now implement `loaded_identity()`. §3's proposed `identity.py` hunk is **withdrawn**; it would have overwritten Spec 01's `providers` key. **Open Spec 01 gap:** the hook runs in the HTTP parent, but models load in the worker processes (`READINESS_WORKER`), and the worker `hello` does not carry loaded identity, so the parent cannot report what a worker loaded. |
| Registry | The registry is pickled to worker processes (`server.py:943-948`) | The provider pickles (151 bytes when disabled). |
| Golden envelope | `Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sensor_biomarkers_request_envelope.json` exists | `test_the_spec01_golden_envelope_segments_parse` now reads it from the repository when present. On the merged tree the adapter parses its PPG block and **withholds `unverified_sample_clock`**, as it must. |
| Transport today | The worker always sends `clock.packet_timing_verified: false` and `config.known: false` (`SensorBiomarkerLane.swift:175-181`) | wav2sleep's input gates cannot pass on today's transport, whatever the capture. This is a seventh practical blocker under gate 1. |
| Request shape | `sensor.biomarkers.v1` requests carry ≤ 300 s segments split at 20 s seams | wav2sleep needs **one request per night** (§4.3). It needs its own request builder; it cannot reuse `buildRequests`. |
| Bounds | `ExecutionConfig`: `FRWHOOP_INFERENCE_MAX_ACTIVE` 1, `FRWHOOP_INFERENCE_MATH_THREADS` default 1, 20 s request budget; the unit has `MemoryHigh=2G` | A 10-h night peaks at ~1.3 GB in one process (Mac). That fits under 2 GB only with no other heavy provider in the same worker. Not measured on the Droplet. |
| Duplication | Spec 01 has no wav2sleep wiring or entry of its own beyond the existing `blocked_input` row | None. |

The Spec 03 side of these is tested in `tests/test_wav2sleep_isolation.py` (unregistered and unreferenced, the
six gates, no artifact identity when disabled) and in the provider and real-weight tests (`loaded_identity()`).

## 1. Manifest: update the existing `wav2sleep` entry (Phase A)

[`manifest-wav2sleep.json`](manifest-wav2sleep.json) holds the complete replacement for
`entries[]` item `"id": "wav2sleep"` in `Tools/InferenceWorker/models/manifest.json`. It keeps the
same position and does not add a second entry. Drop the `_fragment` and `_phase_b` keys when merging.

Changes from the current entry:

| Field | Current | Proposed | Why |
| --- | --- | --- | --- |
| `provider_id` | `sleep_stage` (a metric name) | `wav2sleep.ppg-only.v1` | the real provider id; `Application.blocking_checks` keys on it |
| `status` | `blocked_input` | `blocked_input`, kept | there is still no live input; `status_reason` now records that the adapter exists and matches the official code |
| `wired` | `false` | `false` (Phase A) → `true` (Phase B) | |
| `revision` | `278e3046…`, described as the HF revision | `278e3046…`, kept, with `revision_kind: code_commit` | it is the GitHub code commit; `test_manifest.py` pins the prefix |
| new | | `code_revision`, `code_content_identical_since`, `weights_revision` `18fc32f0…`, `weights_revision_note` | code commit, weights revision and digests are separate facts |
| `artifacts[].url` | `.../resolve/main/...` | `.../resolve/18fc32f095f10c1f7a91a56298e7598d02c58529/...` | immutable; the suggested `resolve/278e3046…` URL returns 404 |
| `artifacts[].source` | `{kind: url}` (Spec 01) | `{kind: url}`, kept | required by Spec 01's `test_every_artifact_declares_a_machine_readable_source` |
| `input_contract` | raw ECG/PPG epoch + hydra config | the anchored PPG transport contract | |
| new | | `release_mode: shadow`, `label_space`, `class_order`, `vendored_code`, `loader`, `consumer`, `activation_gates`, `accuracy_label: unverified_accuracy_shadow_only` | |

**Checked in memory.** `_build-scratch/spec03-physio/check_manifest_fragment.py` swapped the entry
into the parsed manifest without writing any file. Results on Spec 01 `783ac84da` (merged tree):

- All 24 tests in `tests/test_manifest.py` pass against the patched manifest (18 on `dab2124f3`).
- With the staged root, `verify_manifest` reports both artifacts `verified`.
- With an empty root it reports both `missing` and not required for readiness.
- `test_server.py` expects `models["wav2sleep"]["status"] == "blocked_input"`, which still holds.

**Phase B delta** (with the registration in section 2): set `"wired": true`. With `blocked_input`
the materializer still stages nothing (`artifacts.entry_stage_decision`). Change `status` to
`shadow_eligible` only after a real anchored overnight night has passed the adapter's gates on the
Droplet, and raise the `staged == 7` pin in `test_manifest.py` in the same change.

## 2. Registration hunk (Phase B): `Tools/InferenceWorker/src/frwhoop_inference/providers/__init__.py`

```diff
@@ def default_providers() -> list[Provider]:
     from ..frwhoop_sleep.registry_adapter import sleep_providers
+    from ..frwhoop_sleep.wav2sleep import make_providers as wav2sleep_providers
     from ..sensor_biomarkers import collect_optional_providers, collect_providers
 
     return [
         HrvProductionProvider(),
         HrvNeurokitShadowProvider(),
         *sleep_providers(),
+        *wav2sleep_providers(),  # Spec 03 shadow stager; off unless FRWHOOP_WAV2SLEEP_SHADOW_ENABLED=1
         *collect_providers(),
         *collect_optional_providers(),
     ]
```

How the provider behaves once registered:

- **Importing it is cheap.** `frwhoop_sleep.wav2sleep` does not import torch; the model loads
  lazily.
- **It never becomes the default `sleep_stage` provider.** It is registered after
  `sleepecg.wrn-gru-mesa.v1` and is not publishable, and `ProviderRegistry.default_for_metric` picks
  the first publishable provider, otherwise the first registered one.
- **Disabled (the default):** readiness is `true` and requests are withheld `not_ready` /
  `lane_disabled`. Process readiness is unchanged.
- **Enabled:** it warm-loads at readiness. If the artifacts are missing or wrong it reports
  `blocked_artifact: …`, the same rule as the rhythm lanes.

Tests that pin the exact provider set need these updates in the same change:

| File | Update |
| --- | --- |
| `tests/test_registry_integration.py::test_default_providers_registers_both_sleep_candidates` | `for_metric("sleep_stage") == [STAGE_ID, "wav2sleep.ppg-only.v1"]` |
| `tests/test_server.py::test_healthz_reports_readiness_per_provider` | add `"wav2sleep.ppg-only.v1"` to the provider set and assert it is ready and disabled (`providers[...]["ready"] is True`) |
| `tests/test_server.py::test_providers_lists_capabilities_and_recorded_models` | add the id to the `by_id` set; the `wired` set gains `"wav2sleep"` (Phase B manifest) |
| `tests/test_manifest.py::test_only_the_landed_providers_are_wired` | add `"wav2sleep"` to the wired ids |

`register_into` / `sleep_providers()` are deliberately left alone, so
`test_register_into_appends_without_disturbing_hrv` is unaffected.

## 3. Identity (Phase B): use Spec 01's `loaded_identity()` hook

**Superseded on 2026-10-08.** Spec 01's `identity.py` already calls an optional `loaded_identity()` on each
provider. The provider and shim implement it: a flat string map of `provider_id`, `adapter_version`,
`release_mode`, `enabled`, `loaded`, `code_commit`, `weights_revision`, `model_code_digest`,
`preprocessing_digest_default_gates` and `threads`, plus `state_dict.pth.sha256`, `config.yaml.sha256` and
`artifact_digest` once the model is loaded in that process. **No `identity.py` change is needed**, and the
hunk below must not be applied. The richer `runtime_identity()` block is kept for the adapter's own
diagnostics. The original proposal, for the record:

```json
{"provider_id": "wav2sleep.ppg-only.v1", "adapter_version": "wav2sleep.ppg-only.v1/1.0.0",
 "release_mode": "shadow", "enabled": true, "loaded": true,
 "model_root_resolved": "/opt/frwhoop-models/revisions/<id>",
 "code_commit": "278e30463c8149c4e6899b8784da492fec695bd9",
 "weights_revision": "18fc32f095f10c1f7a91a56298e7598d02c58529",
 "artifacts": {"state_dict.pth": {"path": "...", "size_bytes": 9666562, "sha256": "ea6fb441..."},
               "config.yaml": {"path": "...", "size_bytes": 749, "sha256": "b92f4e26..."}},
 "artifact_digest": "<sha256 over both artifact sha256 + vendored model code>",
 "model_code_digest": "<sha256 over the vendored model files on disk>",
 "preprocessing_digest_default_gates": "<sha256>", "threads": 1,
 "loaded_at_unix": 1780000000.0, "load_seconds": 0.05}
```

`artifacts` is `null` until the model has been loaded, which happens at enabled readiness. Every
digest in the block is computed from bytes on disk; none comes from configuration. Proposed hunk:

```diff
 def runtime_identity(app: Any) -> dict[str, Any]:
     ...
         "manifest": {...},
+        # What each provider measured from the bytes it loaded (providers without the hook are omitted).
+        "providers": {
+            provider.provider_id: provider.runtime_identity()
+            for provider in app.registry.all()
+            if callable(getattr(provider, "runtime_identity", None))
+        },
     }
```

## 4. Request path (after Spec 01 lands): how the Swift worker sends an overnight night

The worker already reconstructs anchored PPG in `SensorBiomarkerInputs`
(`reconstructPPG` → `ppgRuns` → `ppgSegments`). With Spec 01's transport, every segment carries
`run_id`, `config.identity`/`known`/`stable` and `clock`. Proposed wav2sleep step:

1. **Trigger.** Start after the canonical night is published for (user, device, wake day). The
   window is that night's in-bed interval, at most 10 h. Longer nights are not sent; the adapter
   would refuse them as `night_too_long`.
2. **Inputs.** Resolve the verified `ppgWaveformSample` objects that overlap the window, using the
   existing `objectResolutionSQL` gates. Reconstruct them, keep only emitted seconds (anchored and
   unsaturated) and build the runs and ≤ 300-s segments. Pass the producer's withheld-second counts
   as `ppg.withheld_seconds` (for example `{"missing_ppg_anchor": n, "saturated_delta": n}`), so an
   anchor-less night is withheld `missing_ppg_anchor` rather than `no_ppg_segments`.
3. **One request per night.** The z-score, instance norm and bidirectional sequence mixer each need
   the whole run in a single call, so segments are not split across requests the way
   `buildRequests` splits them for `sensor.biomarkers.v1`. Size:
   - measured 6.96 MB for a 10-h night (Python JSON with ", " separators);
   - with the worker's "," writer, about 6.1 MB for 6-digit counts;
   - worst case with signed 20-bit values is under 7.0 MB.

   This always fits the 7.5 MB packing budget and the sidecar's 8 MiB `MAX_BODY_BYTES`.
4. **Call.** POST `/v1/infer`:

   ```json
   {"metric": "sleep_stage",
    "provider": {"provider_id": "wav2sleep.ppg-only.v1",
                 "expected_versions": {"adapter": "wav2sleep.ppg-only.v1/1.0.0",
                                       "model": "wav2sleep@ea6fb4410315"}},
    "context": {"user_id": "...", "device_id": "...", "interval_start_utc": "<in-bed start>",
                "interval_end_utc": "<in-bed end>", "iana_timezone": "...", "profile_version": "...",
                "config_version": "...", "corrections_version": "..."},
    "input": {"window": {"start_utc": 0, "end_utc": 0}, "input_revision": "sha256:<sorted object digests>",
              "ppg": {"native_rate_hz": 25, "units": "adc_counts", "withheld_seconds": {},
                      "segments": ["<Spec 01 segments (run_id, config.identity/known/stable, clock.packet_timing_verified, clock.samples_per_second)>"]}}}
   ```

   - The client timeout is 20 s. Measured `infer` time is about 1 s, estimated 2–4 s on the Droplet.
   - A 429 `busy` leaves the night pending. It is not a result and does not use a failure attempt
     (Spec 01 README).
5. **Do not use the candidate lane.** `CandidateStage` runs one selected provider per (user,
   metric). Selecting wav2sleep for `sleep_stage` would displace the SleepECG candidate, and the
   candidate RPC stores a single scalar/stages row, not a comparison. The step writes to the store
   in section 5 instead.
6. **Identity.** Record the sidecar's `diagnostics.digests` (`input`, `artifact`, `preprocessing`,
   `cache_key`) and the runtime identity block. Skip the call when a row with the same `cache_key`
   exists. A changed weight byte, gate or sample changes the key.

The clock members are the ones Spec 01 pinned (docs/model-integration/README.md, "PPG segments",
commits ff143411e and 0fd8b94d3): `clock.packet_timing_verified` must be true, and
`clock.samples_per_second` must equal `ppg.native_rate_hz`. The native rate is 25 Hz for anchored
v26 segments, and 24 Hz is also accepted. Spec 01's `ppg-transport.md` is not on its branch yet, so
if it later names these differently, change `contract._parse_segment` (one function) and the
contract test cases.

## 5. Storage and consumer proposal: `sleep_stage_shadow_comparison`

This is a sketch of a new migration. It is not written to `supabase/` and not applied:

```sql
create table public.sleep_stage_shadow_comparisons (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  night_start_at timestamptz not null,
  night_end_at timestamptz not null,
  provider_id text not null,
  release_mode text not null default 'shadow' check (release_mode = 'shadow'),
  input_revision text not null,
  cache_key text not null,
  input_digest text not null,
  artifact_digest text not null,
  preprocessing_digest text not null,
  adapter_version text not null,
  preprocessing_revision text not null,
  label_space text not null,
  status text not null check (status in ('ok', 'withheld')),
  withheld_reason text,
  reason_detail text,
  epochs jsonb,               -- the response raw_scores block (columnar, ~160 KB per 10 h)
  canonical_stager_version text,
  comparison jsonb,           -- see below
  created_at timestamptz not null default now(),
  primary key (user_id, device_id, night_start_at, provider_id, input_revision)
);
alter table public.sleep_stage_shadow_comparisons enable row level security;  -- service role only
```

Comparison job:

- Join wav2sleep epochs to the canonical stager's epochs on the UTC 30-s grid. Canonical epochs are
  `[session_start + 30 i, …)`. If `session_start` is not on a 30-s boundary, assign each canonical
  epoch to the wav2sleep epoch it overlaps by at least 15 s.
- Map canonical stage strings to `wake/light/deep/rem`, using `SleepStageVocabulary.isWake` for
  `wake`/`awake`.
- Use only epochs that both sides scored. Store:
  - each side's coverage;
  - the 4×4 confusion matrix;
  - per-class agreement and Cohen's kappa;
  - the wav2sleep mean maximum probability.
- Never average or merge the two outputs; their label spaces are different by construction.
- Agreement with the canonical stager is disagreement monitoring, **not accuracy**. The canonical
  stager has no WHOOP PSG validation either. Promotion needs the evaluation set (WAV2SLEEP.md §11).
- The app never reads this table. Rows keep `release_mode = 'shadow'`, and no route may raise it.

## 6. Runtime and bounds (for Spec 01 §5)

- **Thread cap.** The adapter sets `torch.set_num_threads(cap)` around the z-score and forward and
  restores the previous value afterwards. torch's intra-op pool is process-global, so run this
  provider in the bounded worker process from Spec 01 §5, where the cap is the process cap.
  Default 1, maximum 4.
- **Concurrency and memory.** One forward per process (a semaphore) plus `max_epochs = 1200`
  bounds the activation peak at about 0.9 GB. The process peaks at about 1.3 GB for a 10-h night.
  Put a memory limit of about 1.6 GB on that process. Do not co-schedule it with other heavy model
  loads.
- **No downloads.** The artifacts are staged by the materializer at the manifest paths and verified
  (size + sha256) by both `verify_manifest` and the adapter before load.

## 7. Dependencies

None. The vendored code needs only torch, numpy, pandas (test oracle only) and PyYAML, all already
in `uv.lock`. `pyproject.toml` and `uv.lock` are unchanged. No hydra, omegaconf, lightning, einops,
numba, pyarrow, pyedflib or huggingface_hub is imported; `test_wav2sleep_vendored.py` enforces this.
