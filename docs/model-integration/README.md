# Model integration (Spec 01): shared contracts

Status: in progress on `feat/spec01-model-integration-20261007` (from `nara/main` dab2124f3).
This file is the parent-owned contract for the Spec 01 work. Each area documents its own
interfaces in the files listed below; this page holds what more than one area depends on.

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

## Sidecar admission and backpressure

The inference sidecar admits a small configured number of active jobs. When it cannot admit a request
it answers at once with HTTP 429, `{"status":"error","error":{"code":"busy",...}}` and a
`Retry-After` header (seconds). `InferenceClient` maps that to `InferenceClientError.busy`. A busy
answer is not a result: no caller records it as a withheld or failed computation, and it does not
consume a job's failure budget. The caller leaves the work pending and comes back later.

## PPG segments sent to `sensor.biomarkers.v1`

The worker builds `input.ppg.segments[]` (docs/sensor-biomarkers/CONTRACTS.md §4). Existing members
are unchanged (`start_unix`, `duration_s`, `samples` as absolute ADC counts, 24 per second,
`sample_count_per_second`, `config.stable`). New members, all optional on the wire so an older worker
and an older sidecar keep working, and always sent by this branch's worker:

- `run_id` (string): the contiguous, configuration-compatible run the segment belongs to. Segments that
  share a `run_id` are consecutive pieces of one run with no gap between them. Segments with different
  `run_id`s are never joined into one signal. A segment without `run_id` is its own run.
- `config.identity` (string): the optical configuration identity; equal strings mean compatible
  configurations, so amplitudes may be compared. `config.known` (bool) is true only when gain, drive and
  channel are actually identified by the transport, not inferred. Further descriptive `config` members
  (burst index, source/drive/range/offset) may accompany them. Without `config.identity` the sidecar
  keeps its legacy identity (sorted `config` members).
- `clock` (object): native clock provenance (what the sample times are derived from, the per-second grid
  and endpoint ownership, and whether timing was checked against recorded packet timing).

The sidecar computes pulse detection, shape, quality and rhythm preprocessing within one run at a time,
aggregates with the real exposure of each run, and reports amplitude-bearing results per configuration
identity, never pooled across identities. The samples it receives are never modified in place.

## Release modes

Every model output carries the release mode it was produced under, and that mode is never raised
downstream. A cache, route, store or decoder may lower it (for example to `shadow` when a pin does
not match), never raise it. Vocabulary per producer is recorded in the inventory below.

## Inventory and checklist

Filled in at integration: the provider-to-consumer inventory, the read-only runtime checklist, and
the verification record.
