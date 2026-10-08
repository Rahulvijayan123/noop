# Sensor families and provider dispatch (Spec 01 §3 computation rules, §4)

Owner area: sensor families. Code: `Tools/InferenceWorker/src/frwhoop_inference/sensor_biomarkers/`
(`provider.py`, `optional.py`, `ppg.py`, `contract.py`, `paradigma/`, `rhythm/`) and their tests under
`Tools/InferenceWorker/tests/sensor_biomarkers/`. The wire contract for the request is in
[README.md](README.md) ("PPG segments sent to `sensor.biomarkers.v1`"); the family document, reason
vocabulary and storage are in [../sensor-biomarkers/CONTRACTS.md](../sensor-biomarkers/CONTRACTS.md).

## What was wrong

- `sensor.biomarkers.v1` (the provider the worker calls) imported `compute_tremor`, `compute_arm_swing`
  and `compute_rhythm_shadow`, none of which exist. The `ImportError` was swallowed by `except Exception:
  pass`, so the aggregate route could never reach ParaDigMa or the rhythm adapters. A separately
  registered provider (`sensor.biomarkers.paradigma.v1`, `sensor.biomarkers.rhythm.v1`) answering was no
  evidence that the worker's route could.
- `ppg.py` pooled every segment into one configuration (`config` was only `{stable: true}`) and joined
  disjoint segments with `np.concatenate`, so a gap or a configuration change could produce a pulse that
  straddled the boundary, and amplitudes from different optical settings were pooled.

## Dispatch design

One seam, `sensor_biomarkers/optional.py`. Each optional adapter package (`paradigma`, `rhythm`) exposes:

| Member | Meaning |
| --- | --- |
| `FAMILIES` | family keys the adapter serves (`tremor`, `arm_swing`; `rhythm_shadow`) |
| `adapter_state()` | cheap, side-effect-free readiness: flag, artifacts, runtime |
| `compute_family_documents(input_payload, families, *, deadline_s=None)` | one family document per requested family |

The aggregate provider loads adapters by module path (`DEFAULT_ADAPTER_MODULES`; a provider instance may
point one elsewhere, which is how tests inject doubles and how a later checkpoint plugs in). The
standalone providers call the same functions, so each family has **one implementation**; the aggregate
`sensor.biomarkers.v1` is the canonical surface for the worker.

Failure isolation: each optional family runs inside its own guard. Deployment and data problems come
back as withheld documents; an exception means the adapter itself is broken and becomes an `error`
document for that adapter's families only. Successful families in the same request are always kept.
An optional family is not started with less than `MIN_OPTIONAL_SECONDS` (1 s) left in the request budget
and is then reported `timeout`, not dropped.

### Reason codes (stable)

| State | Family status | `reason` | `reason_counts` detail |
| --- | --- | --- | --- |
| flag off | withheld | `family_disabled` | |
| pinned weights missing / mismatched | withheld | `artifact_unavailable` | `artifact_mismatch` when bytes differ from the manifest |
| isolated runtime missing (ParaDigMa subprocess env) | withheld | `runtime_unavailable` | |
| import error | error | `adapter_broken` | `adapter_import_error` |
| interface mismatch (missing/incompatible callable) | error | `adapter_broken` | `adapter_interface_mismatch` |
| exception inside the adapter | error | `adapter_broken` | `adapter_exception` |

`GET /v1/providers` reports the same states per family under the aggregate provider's
`capability.families.<family>`: `tier`, `publishable` (always false for optional families), `adapter`,
`implementation`, `ready`, `state`, `reason`, `detail` (and `detail_code`, `flags`, `models`, `runtime`
when the adapter reports them). A broken adapter is visible there without sending a request.

### Placement, orientation and provenance

`watch_side` and `device_orientation` are passed through as sent; anything outside the allowed values
becomes `unknown`, never a guess. ParaDigMa `arm_swing` withholds `unknown_wrist_placement` /
`unknown_orientation` (also while the WHOOP axis convention is unverified); `tremor` does not need them.
`input_revision` and the segment `run_id`/`config`/`clock` members are carried into every family's
provenance.

### Shadow-only rhythm

`rhythm_shadow` always carries tier `shadow` and `publishable: false`. Its stage may contain only the
score vectors (`deepbeat_quality_scores`, `deepbeat_rhythm_scores`, `siamaf_rhythm_scores`); a stage that
uses any key containing `burden`, `episode`, `alert`, `notif` or `diagnos` is replaced by an error
document and never published. The phone's sensor section renders descriptive families only
(`Strand/Screens/SensorBiomarkersSection.swift`).

## Run-aware PPG computation

`ppg.build_ppg_runs` groups segments into runs: consecutive segments sharing a `run_id`, the same
`config.identity`, and time-contiguous; anything else starts a new run (a `run_id` reused across a gap or a
config change is split and counted `ppg_run_id_discontinuity`). A legacy segment without `run_id` is its
own run. Pulse detection (MSPTDfast v2), cleaning (Elgendi), template quality and rhythm windowing run
within one run at a time; a run shorter than the 6 s detector window is listed
`shorter_than_detector_window`, never padded or joined. Input arrays are copied once and never modified.

Aggregation:

- **Exposure.** Every family reports `observed_seconds` and `eligible_seconds` from the real runs used;
  `pulse_shape.eligible_seconds` is the summed duration of accepted pulses.
- **Identified configurations** (`config.known: true`): one block per `config.identity` in
  `pulse_shape.configurations[]`, amplitude pooled within the identity only. With one block, its values are
  also the top-level measurements; with more, the top level stays empty and
  `pooled_across_configurations: false`.
- **Unidentified configuration** (`config.identity: "unknown"`, every real v26 record today): amplitude is
  reported **per run** in `run_amplitudes` (`configuration_unidentified: true`, bounded to 12 listed runs),
  while gain-independent timing features (upstroke, width50, normalized area) are pooled across runs with
  exposure weights (`amplitude_scope: "per_run"`).
- **Native resolution** stays explicit: `native_rate_hz` and `native_sample_period_ms` in every PPG family
  document; DeepBeat/SiamAF record the native rate and the rate they resampled to.
- **Clock.** `clock.samples_per_second` must equal `ppg.native_rate_hz`, else the PPG families are withheld
  `blocked_input`. `rhythm_shadow` requires `clock.packet_timing_verified: true` on a run, else it is withheld
  `unverified_sample_clock` (counted in `unverified_sample_clock_runs`). Today's worker sends `false`, so
  rhythm stays withheld (see [ppg-transport.md](ppg-transport.md)).
- **Native rate** comes from the request: anchored v26 is 25 Hz, legacy envelopes 24 Hz. Nothing in the
  sidecar assumes either.

What this enables: the existing MSPTDfast/NeuroKit pulse quality, amplitude (per run or per identified
configuration), upstroke and width50. It does not establish calibrated perfusion, vascular stiffness,
SpO₂ or dicrotic-notch accuracy, and pyPPG was not added.

## Compatibility

| Request | Result |
| --- | --- |
| Old worker (no `run_id`, `config` = `{stable: true}`, no `clock`) | Validates. Each segment is its own run; legacy identity is the sorted `config` members; corrupt-signal gate is the old request-wide one; rhythm keeps its old `config.stable` gate. Results are the same or more conservative. |
| New worker, old sidecar | The old sidecar ignores the new members (it reads `config.stable`), which is exactly its old behaviour. |
| New worker, new sidecar | Run-aware computation as above. |

## Tests (in `Tools/InferenceWorker/tests/sensor_biomarkers/`)

- `test_family_dispatch.py`: disabled / missing weights / missing runtime / broken are distinct; interface
  mismatch and exceptions are `adapter_broken`; one broken family never discards the others; exhausted
  budget is a timeout; `/v1/providers` capability per family; rhythm tier is always shadow and a stage
  breaking the shadow contract is never published; every stage revision is one the day table accepts.
- `test_ppg_runs.py` (+ `ppg_run_helpers.py`): no cross-boundary pulse at gaps or config changes,
  `run_id` discontinuity split, exposure-weighted pooling, per-identity and per-run amplitude, immutability.
- `test_worker_envelope_http.py` (+ `worker_envelope.py`): the worker's golden request envelope
  (`Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sensor_biomarkers_request_envelope.json`,
  written by the Swift builder) sent through the real HTTP server (`POST /v1/infer`) reaches every family;
  legacy envelopes from committed fixtures; disabled families are reported by the route.
- `paradigma/test_paradigma_aggregate_route.py`: the aggregate route runs the real ParaDigMa pipeline when
  its pinned runtime and artifacts are present locally (skips with the reason otherwise); a test double at
  the adapter seam proves the request, including placement, reaches the adapter.

Results on the integration branch are recorded in [README.md](README.md) ("Verification record").

## Provider-to-consumer rows

| Family | Producer | Input contract | Release | Storage | API | App consumer |
| --- | --- | --- | --- | --- | --- | --- |
| movement, oscillation | `sensor.biomarkers.v1` (imu) | `input.imu.segments` 100 Hz | descriptive | `sensor_biomarker_days.document` | `GET scores/sensor-biomarkers` | `SensorBiomarkersSection` |
| ppg_quality, pulse_shape | `sensor.biomarkers.v1` (ppg) | anchored `input.ppg.segments` with `run_id`/`config`/`clock` | descriptive | same | same | same |
| perfusion_research | `sensor.biomarkers.v1` (ppg) | as above, plus verified optical DC (never available on v26) | research, flag | same | same (not rendered) | none |
| tremor, arm_swing | ParaDigMa via the optional seam | imu + `watch_side`/`device_orientation` | research, flag | same | same (not rendered) | none |
| rhythm_shadow | DeepBeat (+ SiamAF) via the optional seam | ppg runs with verified packet clock | shadow, flag | same (`raw_scores`) | same (not rendered) | none |

## Read-only runtime checklist (droplet)

1. `curl -s localhost:<sidecar port>/v1/providers | jq '.providers[] | select(.id=="sensor.biomarkers.v1") | .capability.families'`:
   each optional family's `state` and `reason`; `adapter_broken` must not appear.
2. One loopback request per family with the golden envelope (copy it to the host; set `families` to one
   family): `curl -s -XPOST localhost:<port>/v1/infer -d @envelope.json | jq '.result.stages[] | {family, status, reason}'`.
3. `select day, families_ok, withheld_reasons, model_revisions from sensor_biomarker_days order by updated_at desc limit 5;`
   (read-only role).
4. `jq '.result.stages[] | select(.family=="pulse_shape") | {native_rate_hz, amplitude_scope, runs: .runs.count}'`
   on one response: 25 Hz for anchored data, `per_run` for v26.

## Extension points for Specs 02 and 03

- **A new optional family or checkpoint.** Add an adapter package exposing `FAMILIES`, `adapter_state()` and
  `compute_family_documents(...)`, add it to `OPTIONAL_FAMILY_ADAPTERS`/`DEFAULT_ADAPTER_MODULES` and to
  `FAMILY_TIERS` (research or shadow; never descriptive without validation), its artifacts to
  `models/manifest.json` as optional (see [provisioning.md](provisioning.md)). Missing weights then read
  `artifact_unavailable` and only that family is withheld.
- **A new PPG feature (Spec 02).** Compute it inside `_analyse_run`/`_pulse_metrics` so it inherits run
  boundaries; gain-dependent features join `AMPLITUDE_KEYS` (never pooled across identities), gain-
  independent ones join `GAIN_INDEPENDENT_KEYS`. Do not re-derive runs from timestamps.

## Requests to parent

None outstanding. `docs/sensor-biomarkers/CONTRACTS.md` §3–§4 and §7 are updated in this branch to the run-aware
request members, the new reason codes and the 25 Hz anchored native rate.
