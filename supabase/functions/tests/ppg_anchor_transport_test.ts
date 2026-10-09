import assert from 'node:assert/strict';
import { gunzipSync } from 'node:zlib';
import { PpgAnchorValidator, ppgSampleFlags } from '../_shared/ppgTransport.ts';
import {
  ALL_STREAMS, OBJECT_PROTOCOL_VERSIONS, PUSH_PROTOCOL_VERSIONS, advertisedProtocolVersions, capabilitiesBody,
  negotiateProtocol, schemaVersionFor, streamsForVersion,
} from '../_shared/registry.ts';
import { validateObjectIntent } from '../_shared/objects.ts';
import { pushConfig } from '../_shared/config.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { PPG_ANCHOR_GOLDEN, unhex, vector } from './ppg_anchor_golden.ts';
const PHONE_HEADER = '1.5,1.4,1.3,1.2,1.1,1.0';

function validate(bytes: Uint8Array, manifest: any, chunk = bytes.length) {
  const parser = new PpgAnchorValidator(manifest.sampleCount, manifest.startTs, manifest.endTs);
  for (let offset = 0; offset < bytes.length; offset += chunk) parser.push(bytes.subarray(offset, offset + chunk));
  return parser.finish();
}

Deno.test('1.5 is supported but advertised only when the operator opts in', () => {
  assert.deepEqual(PUSH_PROTOCOL_VERSIONS, ['1.3', '1.2', '1.1', '1.0']);
  assert.equal(negotiateProtocol(PHONE_HEADER), '1.3', 'default advertisement is unchanged');
  assert.equal(negotiateProtocol(PHONE_HEADER, advertisedProtocolVersions()), '1.3');
  assert.equal(negotiateProtocol(PHONE_HEADER, advertisedProtocolVersions({ ppgAnchor: true })), '1.5');
  // An installed phone predating 1.5 keeps its exact version under either setting.
  assert.equal(negotiateProtocol('1.4,1.3,1.2,1.1,1.0', advertisedProtocolVersions({ ppgAnchor: true })), '1.3');
  assert.equal(negotiateProtocol('1.0', advertisedProtocolVersions({ ppgAnchor: true })), '1.0');
  assert.ok(OBJECT_PROTOCOL_VERSIONS.includes('1.5'));
  assert.equal(streamsForVersion('1.5'), ALL_STREAMS);
  assert.equal(pushConfig({}).advertisePpgAnchor, false);
  assert.equal(pushConfig({ NOOP_PUSH_ADVERTISE_PPG_ANCHOR: '1' }).advertisePpgAnchor, true);
  assert.equal(pushConfig({ NOOP_PUSH_ADVERTISE_PPG_ANCHOR: 'true' }).advertisePpgAnchor, false, 'exactly "1" enables');
  const caps = capabilitiesBody({ receiverStateId: '00000000-0000-4000-8000-000000000000', protocolVersion: '1.5',
    streams: ['ppgWaveformSample', 'rawImuSession', 'hrSample'],
    objectLane: { endpoint: '/functions/v1/push/objects', maxObjectBytes: 1024, urlTtlSec: 60 } });
  assert.deepEqual(caps.objectLane.streams, ['ppgWaveformSample', 'rawImuSession']);
});

Deno.test('schema 3 exists for ppgWaveformSample at 1.5 only; other streams keep the 1.3 contract', () => {
  assert.equal(schemaVersionFor('ppgWaveformSample', '1.5'), 3);
  assert.equal(schemaVersionFor('ppgWaveformSample', '1.4'), 2);
  assert.equal(schemaVersionFor('ppgWaveformSample', '1.3'), 2);
  assert.equal(schemaVersionFor('ppgWaveformSample', '1.2'), 1);
  for (const stream of ['v18AuxSample', 'stepSample', 'sleepStateSample', 'ppgHrSample', 'rawImuSession', 'hrSample']) {
    assert.equal(schemaVersionFor(stream, '1.5'), 1, stream);
  }
});

Deno.test('golden phone manifest is a valid 1.5 intent; mismatched schema claims are refused', () => {
  for (const name of ['phone_real_frames', 'all_members']) {
    const manifest = vector(name).manifest;
    const ok = validateObjectIntent(manifest);
    assert.deepEqual(ok.errors, []);
    assert.equal(ok.schemaVersion, 3);
    assert.equal(ok.protocolVersion, '1.5');
    assert.deepEqual(validateObjectIntent({ ...manifest, schemaVersion: 3 }).errors, []);
    assert.deepEqual(validateObjectIntent({ ...manifest, schemaVersion: 2 }).errors, ['schemaVersion']);
    assert.deepEqual(validateObjectIntent({ ...manifest, protocolVersion: '1.3', schemaVersion: 3 }).errors, ['schemaVersion']);
    assert.deepEqual(validateObjectIntent({ ...manifest, protocolVersion: '1.6' }).errors, ['protocolVersion']);
  }
  const imu = { ...vector('phone_real_frames').manifest, stream: 'rawImuSession', contentEncoding: 'zstd' };
  assert.equal(validateObjectIntent(imu).schemaVersion, 1);
  // The anchor-less twin of the same seconds is the unchanged 1.3 contract.
  const legacy = validateObjectIntent(vector('phone_real_frames_legacy_v2').manifest);
  assert.deepEqual(legacy.errors, []);
  assert.equal(legacy.protocolVersion, '1.3');
  assert.equal(legacy.schemaVersion, 2);
});

Deno.test('golden bytes: Swift gzip decodes here, digests agree and the validator accepts every chunking', () => {
  const expected = {
    phone_real_frames: { records: 4, anchoredRecords: 4, recordIndexRecords: 0, strapClockRecords: 4,
      saturatedRecords: 1, subsecRecords: 0, frontEndFlagRecords: 0 },
    all_members: { records: 4, anchoredRecords: 3, recordIndexRecords: 2, strapClockRecords: 3,
      saturatedRecords: 1, subsecRecords: 2, frontEndFlagRecords: 2 },
  } as Record<string, Record<string, number>>;
  for (const v of PPG_ANCHOR_GOLDEN.vectors.filter((v: any) => v.protocol_version === '1.5')) {
    const decoded = unhex(v.decoded_hex);
    const wire = Uint8Array.from(atob(v.wire_base64), (c) => c.charCodeAt(0));
    assert.equal(sha256Hex(decoded), v.decoded_sha256);
    assert.equal(sha256Hex(wire), v.wire_sha256);
    assert.deepEqual(new Uint8Array(gunzipSync(wire)), decoded);
    assert.equal(v.manifest.contentSha256, v.decoded_sha256);
    assert.equal(v.manifest.uncompressedBytes, decoded.length);
    assert.equal(v.manifest.compressedBytes, wire.length);
    for (const row of v.rows) assert.equal(ppgSampleFlags(unhex(row.samples_hex)), row.sampleFlags);
    for (const chunk of [1, 2, 3, 7, 17, 64, decoded.length]) {
      assert.deepEqual(validate(decoded, v.manifest, chunk), { version: 1, format: 3, ...expected[v.name] }, `${v.name}/${chunk}`);
    }
  }
});

Deno.test('malformed or mislabelled format 3 bytes never validate', () => {
  const v = vector('all_members');
  const bytes = unhex(v.decoded_hex), m = v.manifest;
  const patched = (offset: number, value: number) => { const b = bytes.slice(); b[offset] = value; return b; };
  const rejects = (b: Uint8Array, code: string, manifest = m) =>
    assert.throws(() => validate(b, manifest), (e: any) => e.code === code, code);
  rejects(patched(4, 2), 'invalid_ppg_envelope');
  rejects(patched(5, 4), 'invalid_ppg_envelope');
  rejects(bytes, 'ppg_count_mismatch', { ...m, sampleCount: m.sampleCount + 1 });
  rejects(bytes, 'ppg_identity_window', { ...m, endTs: m.endTs - 1 });
  rejects(bytes, 'ppg_window_mismatch', { ...m, startTs: m.startTs - 1 });
  // First record: header 10 | rowId 8 | ts 8 | index 1+8 | burst 1+4 -> hasAnchor at 40.
  rejects(patched(26, 2), 'ppg_presence');
  rejects(patched(40, 2), 'ppg_presence');
  rejects(patched(45, 7), 'ppg_clock_source');
  rejects(patched(51, 1), 'ppg_sample_flags');
  rejects(patched(51, 2), 'ppg_sample_flags');
  const extended = new Uint8Array(bytes.length + 1); extended.set(bytes);
  assert.throws(() => validate(extended, m), (e: any) => e.code === 'ppg_trailing_bytes');
  for (const size of [0, 9, 10, 30, bytes.length - 1]) {
    assert.throws(() => validate(bytes.subarray(0, size), m), (e: any) =>
      ['ppg_truncated_envelope', 'invalid_ppg_envelope'].includes(e.code), String(size));
  }
  // Format 2 bytes under a 1.5 manifest are refused rather than read as format 3.
  const twin = vector('phone_real_frames_legacy_v2');
  assert.equal(unhex(twin.decoded_hex)[4], 2);
  assert.throws(() => validate(unhex(twin.decoded_hex), vector('phone_real_frames').manifest),
    (e: any) => e.code === 'invalid_ppg_envelope');
});
