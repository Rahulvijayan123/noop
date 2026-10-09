// Protocol 1.5 PPG transport (NPB1 format 3, schema 3): the receiver's side of
// docs/model-integration/ppg-transport.md. Byte layout per record, all little-endian:
//
//   i64 rowId | i64 ts | u8 hasRecordIndex + [i64 recordIndex] | u8 hasBurst + [i32 burstIndex]
//   | u8 hasAnchor + [u32 anchor] | u8 clockSource | u8 hasSubsec + [u16 subsecQ15]
//   | u8 hasFlags + [u8 frontEndFlags] | u8 sampleFlags | u32 sampleBytes | sampleBytes of i16 deltas
//
// Mirrors NoopPush `PushBinaryCodec.ppgRecordFields` and the worker's `SensorBiomarkerInputs.PpgCodec`.
import { PushProtocolError } from './registry.ts';

export const PPG_ANCHOR_FORMAT = 3;
/** Clock sources a format 3 record may name; anything else is a client the receiver does not know. */
export const PPG_CLOCK_SOURCES = Object.freeze({ unknown: 0, strapRecordSecond: 1 });
/** Saturation flag bit 0: a delta sits at an i16 rail. The other bits are reserved and must be zero. */
export const PPG_SAMPLE_FLAG_DELTA_AT_RAIL = 0x01;
const MAX_SAMPLE_BYTES = 4 * 1024;

const invalid = (code: string): never => { throw new PushProtocolError(code, 422); };
const view = (bytes: Uint8Array) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);

/** Bit 0 when any complete little-endian i16 pair sits at a rail (the encoder's clamp). */
export function ppgSampleFlags(samples: Uint8Array): number {
  for (let i = 0; i + 1 < samples.length; i += 2) {
    const value = samples[i] | (samples[i + 1] << 8);
    if (value === 0x7fff || value === 0x8000) return PPG_SAMPLE_FLAG_DELTA_AT_RAIL;
  }
  return 0;
}

export type PpgAnchorValidation = {
  version: 1; format: 3; records: number;
  anchoredRecords: number; recordIndexRecords: number; strapClockRecords: number;
  saturatedRecords: number; subsecRecords: number; frontEndFlagRecords: number;
};

/**
 * Incremental framing check for a protocol 1.5 PPG object while its decoded bytes stream past.
 * Buffers one field at a time (at most 4 KiB of samples), never the object. A declared schema 3 object
 * whose bytes are not format 3 kind 1, whose count or half-open window disagree with the manifest,
 * whose presence bytes or clock source are unknown, or whose saturation flag disagrees with its
 * deltas never earns a receipt.
 */
export class PpgAnchorValidator {
  private parser: Generator<number, PpgAnchorValidation, Uint8Array>;
  private next: IteratorResult<number, PpgAnchorValidation>;
  private piece = new Uint8Array(0);
  private used = 0;

  constructor(sampleCount: number, startTs: number, endTs: number) {
    this.parser = this.records(sampleCount, startTs, endTs);
    this.next = this.parser.next();
    this.allocate();
  }
  private allocate() {
    if (!this.next.done) this.piece = new Uint8Array(this.next.value);
    this.used = 0;
  }
  push(bytes: Uint8Array) {
    let offset = 0;
    while (offset < bytes.length) {
      if (this.next.done) invalid('ppg_trailing_bytes');
      const length = Math.min(bytes.length - offset, this.piece.length - this.used);
      this.piece.set(bytes.subarray(offset, offset + length), this.used);
      offset += length; this.used += length;
      if (this.used === this.piece.length) {
        this.next = this.parser.next(this.piece);
        this.allocate();
      }
    }
  }
  finish(): PpgAnchorValidation {
    if (!this.next.done) invalid('ppg_truncated_envelope');
    return this.next.value as PpgAnchorValidation;
  }
  private *records(sampleCount: number, startTs: number, endTs: number): Generator<number, PpgAnchorValidation, Uint8Array> {
    const header = yield 10;
    if (new TextDecoder().decode(header.subarray(0, 4)) !== 'NPB1' || header[4] !== PPG_ANCHOR_FORMAT || header[5] !== 1) {
      invalid('invalid_ppg_envelope');
    }
    const count = view(header).getUint32(6, true);
    if (count !== sampleCount || count === 0) invalid('ppg_count_mismatch');
    const out: PpgAnchorValidation = { version: 1, format: 3, records: count, anchoredRecords: 0,
      recordIndexRecords: 0, strapClockRecords: 0, saturatedRecords: 0, subsecRecords: 0, frontEndFlagRecords: 0 };
    const flag = (value: number) => { if (value !== 0 && value !== 1) invalid('ppg_presence'); return value === 1; };
    let min = Infinity, max = -Infinity;
    for (let row = 0; row < count; row++) {
      const identity = view(yield 17);
      const rowId = identity.getBigInt64(0, true);
      const ts = Number(identity.getBigInt64(8, true));
      if (rowId <= 0n || !Number.isSafeInteger(ts) || ts < startTs || ts >= endTs) invalid('ppg_identity_window');
      min = Math.min(min, ts); max = Math.max(max, ts);
      if (flag(identity.getUint8(16))) {
        const index = view(yield 8).getBigInt64(0, true);
        if (index < 0n || index > 4294967295n) invalid('ppg_index_range');
        out.recordIndexRecords++;
      }
      if (flag((yield 1)[0])) yield 4;
      if (flag((yield 1)[0])) { yield 4; out.anchoredRecords++; }
      const clock = (yield 1)[0];
      if (clock !== PPG_CLOCK_SOURCES.unknown && clock !== PPG_CLOCK_SOURCES.strapRecordSecond) invalid('ppg_clock_source');
      if (clock === PPG_CLOCK_SOURCES.strapRecordSecond) out.strapClockRecords++;
      if (flag((yield 1)[0])) { yield 2; out.subsecRecords++; }
      if (flag((yield 1)[0])) { yield 1; out.frontEndFlagRecords++; }
      const sampleFlags = (yield 1)[0];
      const length = view(yield 4).getUint32(0, true);
      if (length > MAX_SAMPLE_BYTES) invalid('ppg_sample_length');
      const samples = length > 0 ? yield length : new Uint8Array(0);
      if (sampleFlags !== ppgSampleFlags(samples)) invalid('ppg_sample_flags');
      if (sampleFlags) out.saturatedRecords++;
    }
    if (min !== startTs || max + 1 !== endTs) invalid('ppg_window_mismatch');
    return out;
  }
}
