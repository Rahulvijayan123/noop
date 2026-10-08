# sensor_biomarkers test fixtures (W1 — raw input layer)

All fixtures are SMALL synthetic byte payloads built by the generator script (no personal data, no
real captures except the two already-published WhoopProtocol v26 frames in
`sensor_biomarkers_v26_frames.json`, which are the same captured frames the WhoopProtocol test suite
pins). Every fixture embeds its `decoded_sha256`, so a test verifies the digest before decoding —
exactly the worker's own contract.

## sensor_biomarkers_imu.json
One NPB1 `rawImuSession` object (kind 4). `decoded_hex` is the exact NPB1 wire bytes
(`Npb1ImuDecoder` layout: magic `NPB1` | version 1 | kind 4 | u32 count; per record i64 rowId | i64 ts
| u32 1200 | 600 i16 LE axis-major `ax[100], ay[100], az[100], gx[100], gy[100], gz[100]`).
`zstd_base64` is the stored B2 object (zstd of `decoded_hex`); the worker verifies
`sha256(decompressed) == decoded_sha256` before decoding.
Records: ts 1758001000 stationary (`az = 4096` counts = 1.0 g, `gz = 16384` counts = 1000 deg/s),
ts 1758001001 stationary, ts 1758001002 45/45 orientation (`ax=ay=2048, az=3072` → magnitude
~1.0309 g), missing ts 1758001003 (gap), ts 1758001004 stationary.

## sensor_biomarkers_ppg_wire.json
Three NPB1 `ppgWaveformSample` objects (kind 1, gzip wire):
- `burst-1-2-v2` (v2 with recordIndex): bursts 1 then 2; records at ts 1000..1007 including a
  saturated +rail delta (32767), a saturated −rail delta (−32768), a 25-delta record (unsupported
  native rate), and an empty record (no samples).
- `overlap-v2`: ts 1007..1009 with an identical duplicate (ts 1008 twice, identical) and a
  conflicting duplicate (ts 1009 twice, different samples/recordIndex).
- `legacy-v1` (v1, no recordIndex): a single clean burst with no burst counter.
These are formats 1 and 2, which carry NO absolute anchor (`baseCode` was a phone-side DB column),
so every record decodes with `baseCode == null` — those seconds are withheld `missing_ppg_anchor`,
never emitted. Format 3 (push protocol 1.5) carries the anchor; its fixture is the shared golden below.

## sensor_biomarkers_ppg_records.json
Decoded per-second v26 PPG records (the reconstruction layer's `PpgWaveformInput` shape) with
explicit anchors, covering: clean anchored seconds, a missing-anchor second, flat, both saturated
delta rails, a config change (burstIndex 1 → 2), a 25-delta record, an empty record, an
out-of-20-bit-domain reconstruction (`baseCode = 524287` + positive delta), and a dark block
(drive == 0). `expected_absolutes` are the independently computed base + cumulative-delta windows
(25 points, sample 0 = baseCode), written explicitly by the generator.

## sensor_biomarkers_v26_frames.json
The two REAL WHOOP 5/MG type-47 v26 frames already published and pinned in
`Packages/WhoopProtocol/Tests/WhoopProtocolTests/Whoop5PpgWaveformTests.swift` (real captured
fixtures, not invented): u32 unix @15, u16 burst_index @21, u32 ppg_base_code @23, 24 i16 LE deltas
@27..75, CRC32 trailer over bytes 8..end. `absolute_window` (base + running sum) is written
explicitly and independently of WhoopProtocol. A corrupted trailer must be rejected by
WhoopProtocol's `parseFrame`/`extractHistoricalStreams` (failed-CRC records never become input).

## Shared PPG anchor golden (not in this directory)
`Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json` is the cross-stack byte
fixture for NPB1 format 3: written by NoopPush `PpgAnchorTransportTests` (the phone's streaming
encoder), read unchanged by the receiver's Deno tests and by `PpgTransportTests` here (path relative to
`Tools/CloudWorker`). Vectors: `phone_real_frames` (the two real v26 frames above plus two synthetic
neighbours, as the phone banks them), `all_members` (every format 3 member and edge value) and
`phone_real_frames_legacy_v2` (the same seconds as a 1.3 sender carried them, without the anchor).

## sensor_biomarkers_request_envelope.json
The exact `POST /v1/infer` body `SensorBiomarkerInputs.buildRequests` + `SensorBiomarkerLane.inferenceBody`
produce for the `phone_real_frames` golden plus two seconds of synthetic stationary IMU: 25 Hz PPG
segments with `run_id`, `config` and `clock`, the request `coverage` and recorded `placement`. Written
by `PpgTransportTests.testRequestEnvelopeGolden` (set `FRWHOOP_SENSOR_ENVELOPE_OUTPUT` to regenerate);
the sidecar tests consume it.

## Regeneration
Run the generator script (tools/fixture_generator.py in this directory if present) and commit the
four JSON files; keep `decoded_sha256` values in sync with the bytes they describe.
