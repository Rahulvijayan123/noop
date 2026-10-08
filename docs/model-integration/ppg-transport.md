# PPG transport (Spec 01 §3, transport side)

Owner area: PPG transport. Shared contract: [README.md](README.md) ("PPG segments sent to
`sensor.biomarkers.v1`"). Sidecar wire contract: `docs/sensor-biomarkers/CONTRACTS.md` §4 (owned by the
Sensor families area).

## What changed and why

The NPB1 `ppgWaveformSample` record carried the v26 window's 24 deltas but not the absolute base code the
strap sends with them, so every uploaded second was a derivative with no level and the worker withheld it as
`missing_ppg_anchor`. On top of that, iOS never uploaded `ppgWaveformSample` at all: the phone's object lane
sent only `rawImuSession`. This area:

1. adds protocol 1.5 / NPB1 format 3, which carries the anchor, the record clock source, the raw header phase
   and flags byte (when known), and a saturation flag (`Packages/NoopPush`);
2. lets the receiver accept and verify format 3 behind an advertisement flag, with an additive migration
   (`supabase/functions/_shared/ppgTransport.ts`, `20261008120000_ppg_transport_anchor.sql`);
3. adds the phone source that uploads banked anchored rows through the existing object lane, default off
   (`Strand/Push/PpgObjectSource.swift`);
4. makes the worker decode all three formats, reconstruct anchored windows at their native resolution, and
   send runs with configuration and clock identity plus actual input coverage
   (`Tools/CloudWorker/Sources/frwhoop-worker/SensorBiomarker{Inputs,Lane}.swift`).

Old records keep their honest handling: an anchor-less second is still withheld `missing_ppg_anchor`, and
nothing infers an anchor, a clock, a configuration or a sample.

## Wire format

An NPB1 PPG object is `"NPB1"` | u8 format | u8 kind (1 = ppgWaveformSample) | u32 record count, then the
records, all little-endian. Per record:

| Field | Format 1 (≤ 1.2) | Format 2 (1.3, 1.4) | Format 3 (1.5) |
|---|---|---|---|
| i64 rowId, i64 ts | yes | yes | yes |
| u8 hasRecordIndex + [i64 recordIndex] | — | yes | yes |
| u8 hasBurst + [i32 burstIndex] | yes | yes | yes |
| u8 hasAnchor + [u32 anchor] | — | — | yes |
| u8 clockSource (0 unknown, 1 strap record second) | — | — | yes |
| u8 hasSubsec + [u16 subsecQ15] | — | — | yes |
| u8 hasFlags + [u8 frontEndFlags] | — | — | yes |
| u8 sampleFlags (bit 0: a delta at an i16 rail; other bits zero) | — | — | yes |
| u32 sampleBytes + i16 deltas | yes | yes | yes |

- `recordIndex` is the strap's u32 record counter carried in an i64: every encoder and decoder (NoopPush, the
  receiver, the worker) accepts exactly 0…4,294,967,295.
- `anchor` is the v26 `ppg_base_code` (u32 at frame offset 23), verbatim. `subsecQ15` is the header u16 at
  offset 19, `frontEndFlags` the header byte at offset 10, both verbatim when the phone kept them (it keeps
  neither today, so both are absent on every phone record). `sampleFlags` is derived from the deltas by every
  encoder and re-derived by every decoder; a disagreement is a broken encoder and fails the object.
- Older formats refuse format 3 members instead of dropping them (`PushBinaryCodec.ppgRecordFields`). Formats
  1 and 2 decode unchanged, with every format 3 member absent.
- Example (first record of the golden `phone_real_frames` vector, decoded hex):
  `f0a3266a00000000 f0a3266a00000000 00 01 01000000 01 c3c50500 01 00 00 00 30000000 68fa ccfa …`
  = rowId = ts = 1780917232, no record index, burst 1, anchor 378307, clock 1, no phase, no flags, no
  saturation, 48 bytes of deltas (-1432, -1332, …).
- The cross-stack byte golden is `Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json`
  (vectors `phone_real_frames`, `all_members`, `phone_real_frames_legacy_v2`). It is written by
  `PpgAnchorTransportTests.testGoldenVectorsMatchTheCodecAndTheStreamingPhonePath` (set
  `NOOP_PPG_ANCHOR_GOLDEN_OUTPUT=<path>` to regenerate) and read by the receiver's Deno tests
  (`ppg_anchor_transport_test.ts`, `ppg_anchor_integration_test.ts`), the worker's `PpgTransportTests`, and
  the phone's `PpgObjectLaneTests`.

## Negotiation

- `PushProtocol.ppgAnchorVersion = "1.5"`; `schemaVersion(ppgWaveformSample, 1.5) = 3`. 1.5 keeps the 1.3
  contract for every other stream (it is not a superset of 1.4: auxiliary identity and scalar provenance stay
  1.4-only).
- Receiver: accepts 1.5 whenever a client sends it, advertises it only with
  `NOOP_PUSH_ADVERTISE_PPG_ANCHOR=1` (`advertisedProtocolVersions`). Default negotiation is unchanged
  (`1.3,1.2,1.1,1.0`), so no phone uploads anchored PPG before the worker that reads it is deployed.
- Phone: `PushProtocol.capabilitiesAcceptVersions` (`1.5,1.4,…`) is what the package can speak.
  What a lane offers is `PushProtocol.acceptVersions(offeringPPGAnchor:)`:
  - the object lane (`ImuObjectTransport`) offers 1.5 only while `noop.cloud.ppgAnchorUpload` is on, because a
    receiver that advertises 1.5 negotiates it for every stream of that lane;
  - the NDJSON lane (`CloudUploadSession`) never offers 1.5 (`acceptVersionsWithoutPPGAnchor`), since it
    carries no PPG objects.
  With the flag off both lanes therefore send exactly the pre-Spec-01 header (`1.4,1.3,1.2,1.1,1.0`) and
  negotiate what they did before, whatever the receiver advertises. The object lane's cached capabilities
  are dropped when the flag flips, so the next pass renegotiates.

## Receiver bookkeeping

- `object_manifests` row: `object_kind = 'ppgWaveformSample'`, `push_protocol_version = '1.5'`,
  `schema_version = 3`. The migration `20261008120000_ppg_transport_anchor.sql` widens the reservation core's
  schema check to admit 3 for exactly (`ppgWaveformSample`, `1.5`); everything else keeps (1, 2). Additive,
  reversible, not applied to production by this branch.
- While the object streams through verification, `PpgAnchorValidator` checks format 3 framing (kind, count,
  half-open window against the manifest, presence bytes, clock source, saturation flag). The receipt is issued
  only if it passes (schema 3 receipts attest format 3 bytes); the per-object counts it computes are not
  persisted.
- Revision semantics are the object lane's: the object id is content-addressed (`binaryObjectBatch` identity
  over the decoded bytes), so an identical object is a duplicate, and a different object covering the same
  seconds is a separate object whose seconds the worker reconciles (below).

## Phone source and flag

- Flag: `PpgObjectUploadFeature`, UserDefaults key `noop.cloud.ppgAnchorUpload`, default OFF (absent = off).
  It is an owner decision because it adds phone upload volume: about 80 bytes decoded per optical second
  (a continuous optical hour is 3,600 records ≈ 290 KB decoded, gzip on the wire). There is no UI for it.
- Second gate: `PpgObjectUploadFeature.laneOpen` requires the negotiated version to be 1.5 and
  `objectLane.streams` to list `ppgWaveformSample`. The source itself also returns nothing unless the
  page's negotiated version is 1.5, so a 1.4-or-older receiver gets nothing (not deltas without anchors).
- Source: `PpgObjectSource` (`Strand/Push/PpgObjectSource.swift`) reads `WhoopStore.ppgWaveformSamples`
  (an existing read accessor; no WhoopStore change) through the app's own store handle, which `AppModel`
  hands over in one line (`PpgObjectSource.historyStore`). It runs in the same object-lane pass as raw IMU,
  over the same `ImuObjectTransport` and `ImuPushProgressStore` (cursors are keyed per stream and device), with
  its own `PushCoordinator` instance (the coordinator takes one source) and its own drain bound
  (`maxPpgObjectsPerPass = 4`).
- Record mapping: `rowId = ts` (the table's key is `(deviceId, ts)`), `burstIndex` = the stored v26 burst
  counter, `anchor` = the stored `baseCode`, `clockSource = strapRecordSecond`, deltas packed back exactly as
  the store packed them. The store keeps no record index, header phase or flags byte, so those are absent.
  Cursor fingerprint: `sha256("ppgWaveformSample\n<cloud device>\n<ts>\n<burst>")`.
- Never sent: a row without `baseCode` (banked before #2019 read it; the insert keeps the first copy of a
  second, so it never gains one), a base outside u32, a burst outside i32, empty deltas, or a delta outside
  i16. Such rows are skipped, not sent anchor-less.
- Devices: only the registry's active strap, under the cloud id `CloudStrapSerialStore` gives it (the raw-IMU
  mapping). If a different strap has since taken that local id (`hasReplacedStrap`), nothing is sent: the rows
  carry no strap identity of their own and may belong to the earlier strap.
- Capture policy is unchanged: the source only reads what the history offload already banked.

## Re-upload semantics

There are no iOS PPG objects on the server yet, so the first upload with the flag on is the re-upload of the
recoverable local history: exactly the anchored rows still on the phone. Bounds:

- Horizon: never older than 14 days (`lookbackSeconds`). The store's own retention is the newest 604,800 rows
  per device.
- Never at or below the durable cursor's second, even when the row the cursor names has been pruned and the
  coordinator restarts from an empty cursor (`sentThrough` reads the progress store on every page).
- One object holds at most 2,000 records (the coordinator's `PushWakeBudget.rowsPerJob`; the protocol's own
  ceiling of 5,000 is never reached), spans at most 3,600 s from its first anchored second
  (`targetObjectWindowSeconds`) and at most 4 MiB decoded, whichever binds first. A continuous optical hour
  therefore goes up as two objects (2,000 + 1,600 records); a typical 40 s burst every ~20 min fits in one. An hour with nothing newer after it goes out only once
  the phone clock is 15 minutes past its end (`settleSeconds`), because v26 rows arrive with the offload.
- Anchor-less stretches are crossed in bounded reads (2,000 rows, 8 reads per call) with the position
  remembered in memory, so they are neither sent nor able to stall the lane.
- The cursor advances only on a verified receipt; an interrupted object resumes onto the same object key. A
  second therefore goes up once from a phone, and a resent identical object is a receiver duplicate.
- Old anchor-less server objects (Android, or a 1.3 sender) are never rewritten. When an anchored copy of the
  same second arrives, the worker keeps the richer copy and counts it as superseded, not as a conflict; when
  none arrives, the second stays withheld `missing_ppg_anchor`.

## Worker reconstruction and the 24 vs 25 Hz decision

`SensorBiomarkerInputs` decodes formats 1–3 (the object's format must match its recorded schema; a
mismatch fails the object), merges duplicate seconds (identical copies collapse, an anchored copy supersedes
an anchor-less one, any other disagreement keeps the first by capture precedence and is counted), and
reconstructs each anchored record: `p[0] = anchor`, `p[i+1] = p[i] + delta[i]`. Original samples are never
modified; withheld seconds (`missing_ppg_anchor`, `saturated_delta`, out-of-domain, mixed delta counts) carry
no samples.

### Decision: anchored v26 is emitted at 25 Hz (a deliberate deviation from the spec text)

The spec says to reconstruct 25 points, emit the first 24 at `ts + i/24`, give the 25th to the next second,
and verify this against recorded packet timing. The recorded data contradict it: the 25th point is not the
next record's first sample, so the 24-point convention would drop one real sample every second. Anchored
records are therefore emitted as 25 samples at `start_unix + phase_s + k/25`.

Evidence (re-run in round 2; outputs in `_build-scratch/spec01/ppg-transport/evidence-r2.txt`, scripts in
`_build-scratch/spec01/ppg-transport/scripts/`, run as `python3 -I <script> <corpus files>`):

| Check | Script | Result |
|---|---|---|
| Corpus | — | FRWHOOP `_research/control_plane_v2/derived/ppg_raw.ndjson` (sha256 `bf8ef6b7…06fb2a`), fw 50.35.2.0, 5,978 records, 3,645 unique seconds, all 24 deltas, 93 bursts (89 of 40 s) |
| Boundary step `next base − (base + Σ24 deltas)` over 3,528 consecutive same-burst pairs | `v26_timing.py` | exactly 0 in 65 (1.84%); \|gap\| median 18, p90 81, vs in-window \|delta\| median 18, p90 82 |
| Is the boundary an ordinary sample step? | `v26_continuity.py` | corr(gap, last in-window delta) 0.769, corr(gap, next record's first delta) 0.844, reference corr of adjacent in-window deltas 0.803; in-window zero-delta rate 2.18% |
| **Independent transmission of the same samples** | `v26_v20_crosscheck.py` (+ `v26_v20_overlap.py`) | the v20 optical frame (`whoop5_optical_v20.ndjson`, sha256 `383eb027…083e8a`) carries 25 **absolute** samples per channel per record. In 823 of 824 seconds present in both streams, the 25 reconstructed v26 points equal v20 block 0 channel A (source 1, drive 3350, range 32) exactly. The one exception is a second with a delta at the rail (the worker withholds it). In 782 boundary pairs the next v26 base equals the **next** v20 record's sample 0 (778 only that, 4 where the step is 0); it never equals this record's 25th point alone |
| Header subsec (u16 @19, Q15) | `v26_subsec.py` | constant within 84 of 93 bursts: a per-burst phase, not a per-record time; it cannot bound the rate |
| Host arrival times | `v26_arrival_cadence.py` | every v26 and v20 record arrived by historical offload, 1.35 to 213 days after its strap second, up to 52 records per arrival second: arrival time says nothing about sampling |
| Declared rate | — | v26 header flags bit 7 and v20 flags (129 on all 27,503 records) both declare 25 Hz |

So every record holds 25 distinct consecutive samples, the next record's anchor is the 26th, and the
sequence is the same one v20 carries as 25 samples per record. With one record per strap second, that is a
uniform 25 Hz grid. The 24-point convention cannot be kept without dropping a sample per second, so 25 Hz
stays.

What this does not establish: the strap's clock. Every check is relative to the strap's own record seconds,
on one strap, one firmware, about 11 hours of overlap. No recording bounds the record period against an
independent clock. `clock.packet_timing_verified` therefore stays `false` (so `rhythm_shadow` stays withheld
`unverified_sample_clock`), and `clock.grid_evidence` names the corpus.

FRWHOOP's own docs call v26 "24 Hz, HR-locked". That check (autocorrelation lag and inter-beat interval of
the concatenated 24 deltas per record) cannot tell 24 from 25 samples per record: concatenating 24 values
per one-second record keeps the time axis at one second per record either way. It verified one record per
second, not the sample rate inside a record.

Compatibility implications:

- Request: `ppg.native_rate_hz = 25`, every segment `sample_count_per_second = 25` and
  `clock.samples_per_second = 25`. The sidecar withholds the PPG families (`blocked_input`) if
  `clock.samples_per_second` disagrees with `native_rate_hz`, so a mixed request cannot slip through.
- DeepBeat (25 s windows, FFT-resampled to 800 samples, 32 Hz) and SiamAF (30 s windows resampled to 2,400
  samples, 80 Hz) resample from the declared `native_rate_hz`: 625 or 750 native samples per window at
  25 Hz. Declaring 24 Hz for 25 Hz data would stretch every window by 4% and shift every rate-derived output
  by 4%. Both remain shadow-only and withheld while the clock is unverified.
- Legacy 24 Hz envelopes: requests built before this branch sent 24 points per second at `native_rate_hz` 24
  with no `clock` member. The sidecar still accepts them (legacy rhythm gate on `config.stable`); results
  computed from them are not comparable with 25 Hz results and are not re-labelled. The worker never mixes
  the two grids in one request.
- Day documents carry the grid in their provenance (`meta.lanes[].identity.ppg_grid`,
  `ppg_samples_per_second`).

How to revert (one line): in `SensorBiomarkerInputs.swift`, change `static let ppgGrid: PpgGrid = .uniform25`
to `.legacy24`. That restores 24 samples per record at `k/24`, endpoint owned by the next record, and
`native_rate_hz`/`samples_per_second` 24 everywhere (they derive from the enum). Then regenerate the request
golden with `FRWHOOP_SENSOR_ENVELOPE_OUTPUT=<path> swift test --filter PpgTransportTests/testRequestEnvelopeGolden`
and copy it to
`Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sensor_biomarkers_request_envelope.json`;
the test that pins the legacy grid (`PpgTransportTests`) keeps passing.

## Segments emitted

Per the shared contract. Runs split at a gap, a withheld second, a burst change, a clock-source or phase
change, and never join. `run_id = "ppg-<first second>"`. Each run becomes one or more segments of at most
300 s (`maxSegmentDurationSeconds`); every segment carries `run_id`, `config` and `clock`. Example (from the request golden; samples
truncated):

```json
{
  "start_unix": 1780917232, "duration_s": 2, "sample_count_per_second": 25,
  "samples": [378307, 376875, 375543, "… 50 absolute ADC counts"],
  "run_id": "ppg-1780917232",
  "config": {"identity": "unknown", "known": false, "burst_index": 1, "stable": true},
  "clock": {"source": "strap_record_second", "samples_per_second": 25, "record_period_s": 1,
            "phase_s": null, "endpoint": "own_record", "grid": "uniform-25hz-v26-continuity",
            "sample_time": "start_unix + phase_s + k/25", "packet_timing_verified": false,
            "grid_evidence": "frwhoop-v26-corpus fw=50.35.2.0 …"}
}
```

`config.identity` is `"unknown"` / `known: false` on every real record: v26 carries no gain, drive or channel,
and nothing infers them. (The v20 cross-check shows that in one recording the v26 stream was v20 block 0
channel A at drive 3350 and range 32; that is a fact about that recording, not something a v26 record states,
so it is not used.) Placement: the user's recorded body location when one exists, else unknown; device
orientation and watch side stay `unknown` (`not_recorded`); nothing is guessed.

## Coverage reporting

Every request carries `input.coverage` (and the day document `input_coverage`) per modality:
`expected_seconds` (seconds the worker has for the interval), `eligible_seconds`, `withheld_seconds`,
`withheld` by reason (`missing_ppg_anchor`, `saturated_delta`, …), `runs`, `segments`. Requests ask only for
families whose modality they carry; a family whose input is absent is withheld with the coverage reason and
counted in `families_without_input`. Lane counters: `ppg_expected_seconds`, `ppg_eligible_seconds`,
`sidecar_busy`, `deferred_busy`.

## Day merge of pulse shape for unidentified configurations

Every real v26 day is `config.identity: "unknown"`. Per request, the sidecar reports the unknown block's
gain-independent measurements (`pulse_upstroke_*`, `pulse_width50_*`, `pulse_normalized_area_*`,
`pulse_accepted_count`, `pulse_rejected_count`) at the top level, and amplitude only per run
(`run_amplitudes`). The worker's day merge does the same across requests (`SensorBiomarkerFamilyStage.merge`):

- the unknown blocks of all requests merge into one block: `runs`, `segments`, `accepted`, `observed_seconds`,
  `eligible_seconds` and `rejected.*` sum; the bounded-bin distributions pool per key; medians and IQRs are
  re-derived from the pooled bins (every accepted pulse counts once, so each hour weighs by its real
  exposure); counts sum;
- the day's top level carries that block's gain-independent measurements, with
  `extra.top_level_scope = "gain_independent_pooled_across_unidentified_runs"` and
  `pooled_across_configurations: false`. No amplitude key ever reaches the top level or the merged unknown
  block (`gainIndependentPulseKeys` allow-list, mirroring the sidecar's `GAIN_INDEPENDENT_KEYS`);
- `run_amplitudes.listed` concatenates every request's runs (bounded at 2,048), never pooled;
- a day with any known identity keeps the earlier rule: top level only for exactly one known identity.

This is tested against the sidecar's real output: `test_worker_pulse_shape_fixture.py` runs two hourly
requests built from the golden request envelope's `config`/`clock` members through the real provider and pins
the result as `Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/sidecar_pulse_shape_unknown_stages.json`
(`FRWHOOP_PULSE_SHAPE_FIXTURE_OUTPUT=<path>` rewrites it), and
`SensorBiomarkerLaneTests.testUnknownIdentityDayPoolsGainIndependentPulseShapeFromTheRealSidecarOutput`
merges it.

## Busy answers

A sidecar 429 (`busy`, the typed `InferenceClientError.busy`, or an `inference_busy` description) is isolated
in `SensorBiomarkerLane.isSidecarBusy`. A busy request is retried `busyRetriesPerRequest` (2) times within the
lease, each after its `Retry-After` (client default 5 s, capped at 10 s), renewing the lease before each retry.
Still busy, the job is deferred: its lease is shortened to 30 s, the wake stops, and nothing is stored or
counted as a failure (`sidecar_busy` counts every busy answer, `deferred_busy` every deferral). The answers the
job already got stay in memory (`AnsweredRequests`, keyed by the job's identity and input revision and by each
request body's sha256, one job at a time, at most 256 requests), so when the job is claimed again only the
unanswered requests go to the sidecar. They are cleared when the job publishes, is superseded or fails. A
worker restart loses them, which only costs re-sending.

## Bad PPG objects

A PPG object whose digest-verified bytes cannot be read under their recorded schema (format/schema mismatch,
or undecodable) is skipped, counted in `input_coverage.ppg.objects_skipped` by reason
(`ppg_object_format_mismatch`, `ppg_object_undecodable`) and in the lane counter `ppg_objects_skipped`; the day
still runs, IMU families included. A digest mismatch stays a retryable failure, because skipping a transient
bad read would publish a day that never re-runs.

## Compatibility matrix

| Phone | Receiver | Worker | Sidecar | Result |
|---|---|---|---|---|
| old (no PPG objects) | any | any | any | unchanged; no iOS PPG objects |
| new, flag off | any | any | any | offers `1.4,1.3,…`; byte-identical to before; no PPG objects |
| new, flag on | old (no 1.5) or new without `NOOP_PUSH_ADVERTISE_PPG_ANCHOR` | any | any | negotiates ≤ 1.4; `laneOpen` false; no PPG objects; raw IMU unchanged |
| new, flag on | new, advertising 1.5 | old (pre-Spec-01) | any | **do not deploy in this order**: the pre-Spec-01 worker's NPB1 reader accepts formats 1 and 2 only and throws `unsupportedVersion` on format 3; advertise only after the worker is deployed |
| new, flag on | new, advertising 1.5 | new | old | segments carry new optional members the old sidecar ignores; 25 Hz `native_rate_hz` is declared, so it computes on the right grid; rhythm keeps its legacy `config.stable` gate |
| new, flag on | new, advertising 1.5 | new | new | anchored 25 Hz runs with config/clock identity; rhythm withheld `unverified_sample_clock` |
| Android / 1.3 sender | new | new | new | format 2 objects decode unchanged; anchor-less seconds withheld `missing_ppg_anchor`; an anchored copy supersedes them |

Deploy order: migration → worker → receiver with `NOOP_PUSH_ADVERTISE_PPG_ANCHOR=1` → owner turns the
phone flag on.

## Provider-to-consumer rows

| Producer | Input contract | Release mode | Storage | API | App consumer |
|---|---|---|---|---|---|
| Phone `PpgObjectSource` | banked v26 rows with `baseCode` | n/a (raw input) | B2 object + `object_manifests` (1.5 / schema 3) | `POST /push/objects` | none |
| Worker sensor lane | NPB1 PPG formats 1–3 + raw IMU | inherits the family's | `sensor_biomarker` day document (`input_coverage`) | `sensor.biomarkers.v1` request | `SensorBiomarkerRepository` (behind `noop.sensorBiomarkersEnabled`) |

## Read-only runtime checklist

Run on the droplet with read-only credentials; none of these writes anything.

1. Objects by protocol/format:
   `select push_protocol_version, schema_version, count(*), max(created_at) from object_manifests where object_kind = 'ppgWaveformSample' group by 1, 2 order by 1, 2;`
   Expect no `1.5`/`3` rows until the receiver advertises 1.5 and a phone turns the flag on.
2. Receiver advertisement: `GET /functions/v1/push` with `noop-push-accept-version: 1.5,1.4,1.3` and an
   installation credential returns `protocolVersion` `1.5` only when `NOOP_PUSH_ADVERTISE_PPG_ANCHOR=1`.
3. Migration present: `select pg_get_functiondef('public.noop_reserve_object_manifest_lifecycle_core(jsonb)'::regprocedure) like '%schema_version = 3%';`
4. Worker identity and counters: the heartbeat's `meta.lanes[]` entry for the sensor lane shows
   `identity.ppg_grid = uniform-25hz-v26-continuity`, `ppg_samples_per_second = 25`,
   `ppg_npb1_formats = 1,2,3`, `ppg_packet_timing_verified = false`, and counters `ppg_expected_seconds`,
   `ppg_eligible_seconds`, `sidecar_busy`, `deferred_busy`, `families_without_input`.
5. One request's segments: from a recent day document, `input_coverage.ppg` (expected/eligible/withheld by
   reason, runs, segments); in the sidecar request log (if retained), each segment's `run_id`,
   `config.identity`, `clock.samples_per_second` and `ppg.native_rate_hz`.
6. App-visible consumer: the sensor-biomarker route for that day returns the same document; the app shows it
   only with `noop.sensorBiomarkersEnabled`.

No droplet session was available to this implementer; nothing above has been run against production.

## Extension points for Specs 02 and 03

- A new waveform consumer gets runs and identity from `SensorBiomarkerInputs.reconstructPPG(records:)`
  (`PpgReconstruction.seconds`, `.runs` with `runId`, `config`, `clock`) and segments from
  `ppgSegments(run:secondsByTs:)`. Do not re-derive runs from timestamps, and do not concatenate runs.
- The native rate is `SensorBiomarkerInputs.ppgNativeRateHz` (from `ppgGrid`); resample in the consumer from
  that, never from an assumed 24.
- New optical configuration identity: when a transport starts carrying gain/drive/channel, set it through the
  existing `PpgOpticalConfig` (its `identifiesConfiguration` makes `config.known` true). Do not infer it from
  v20 captured elsewhere unless a record states it.
- A new phone-side optical member (header phase or flags byte) goes into the existing format 3 presence
  fields; the store would need a column first (WhoopStore is read-only for this area).
- Coverage: add a modality to `ModalityCoverage` the same way (`expected/eligible/withheld/runs/segments`).

## Facts the Sensor families area needs

- `native_rate_hz` is 25 for anchored v26; `clock.samples_per_second` equals it on every segment.
- `config.identity` is always `"unknown"` and `config.known` false today; never pool amplitude across runs.
- `clock.packet_timing_verified` is false; `phase_s` is null (the phone does not persist header subsec).
- Runs are at most one burst (typically 40 s); bursts recur every ~1,240 s, so a 25 s DeepBeat or 30 s SiamAF
  window fits inside one run only when the run is long enough; never stitch runs to fill a window.
- Withheld seconds carry no samples; their reasons are in `input.coverage.ppg.withheld`.

## Tests

Round-2 runs on this branch (macOS, Xcode 26.3 toolchain via `DEVELOPER_DIR`; logs under
`_build-scratch/spec01/ppg-transport/`):

| Suite | Command | Result |
|---|---|---|
| NoopPush | `cd Packages/NoopPush && xcrun swift test` | 202 tests, 0 failures |
| Phone PPG + IMU object lane | `xcodebuild test … -only-testing:StrandTests/PpgObjectLaneTests -only-testing:StrandTests/ImuObjectLaneTests` | 35 tests (11 + 24), 0 failures |
| Full StrandTests | `xcodebuild test … -only-testing:StrandTests` | 3,217 tests, 13 skipped, 11 assertion failures in 3 cases: `IntradayWordingAndCoachTests.testMinuteBucketsAreDescribedAsMinuteBuckets` (known pre-existing) and `ActivityCalibrationSessionTests.{testBeginWithAnEmptyProtocolEndsCleanly, testStepsChainBackToBackAndEveryActivityEndsWithDone}` (reproduce alone; activity code this branch does not touch) |
| Worker PPG and sensor lane | `cd Tools/CloudWorker && FRWHOOP_TEST_DB_URL=<scratch Postgres> xcrun swift test --filter 'PpgTransportTests\|SensorBiomarker'` | 78 tests, 0 failures, 0 skipped (scratch cluster on 127.0.0.1:55547 from `scripts/worker_db.py`, 191 migrations, stopped afterwards); without the DB URL: 78, 9 skipped, 0 failures |
| Receiver PPG | `cd supabase/functions && EDGE_TEST_ARTIFACTS=<short path> deno test --frozen --lock=deno.lock … tests/ppg_anchor_transport_test.ts tests/ppg_anchor_integration_test.ts tests/registry_test.ts` | 15 passed (5 steps), 0 failed |
| Sidecar envelope consumers (read-only) | `cd Tools/InferenceWorker && uv run --frozen pytest -q tests/sensor_biomarkers` | 2 failures in `test_family_dispatch.py`; on retry one passes and `test_one_broken_family_never_discards_the_others` still fails with an optional family reporting `timeout` instead of `adapter_broken`. That test builds its own request and does not read the envelope this branch regenerated |
| iOS compile | `xcodebuild -scheme NOOPiOS -configuration Debug -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build` | BUILD SUCCEEDED |

What the phone tests prove: flag off stages nothing and the lane offers exactly `1.4,1.3,1.2,1.1,1.0` (so a
1.5-advertising receiver negotiates 1.3); flag on with a receiver at 1.2/1.3/1.4 gets nothing; flag on at 1.5
sends the golden's `phone_real_frames` rows, banked in a real `WhoopStore`, through the real `PushCoordinator`
and `ImuObjectTransport`, and the uploaded bytes equal the golden's `wire_base64`, its manifest identity and
its end cursor; a second pass sends nothing; anchor-less and out-of-range rows are never sent; paging by
cursor sends every anchored second within the horizon exactly once; a pruned cursor row does not restart the
upload; an open hour waits for the offload.

## Requests to parent

1. **Accept the 25 Hz deviation from the spec text** (§3 "first 24 at ts + i/24"). Evidence above: the v20
   cross-check shows the 25 reconstructed points are the strap's own 25 samples per second (823/824 seconds
   exact) and the next anchor is the next record's first sample (778/782 boundaries, never the 25th point).
   The 24-point convention would drop a real sample every second. Revert is one enum value. (The parent has
   updated `docs/sensor-biomarkers/CONTRACTS.md` to 25 Hz.)
2. Owner decision before anyone sets `noop.cloud.ppgAnchorUpload` or `NOOP_PUSH_ADVERTISE_PPG_ANCHOR=1`: added
   phone upload volume (~80 B per optical second), and the deploy order above.
3. `deploy/README.md` (not mine): add `NOOP_PUSH_ADVERTISE_PPG_ANCHOR` (default unset) to the receiver's
   environment list, with the deploy order.
4. `Strand/App/AppModel.swift` got one additive line (`PpgObjectSource.historyStore = …`) in
   `configureNaraAccount`; please keep it at merge.
