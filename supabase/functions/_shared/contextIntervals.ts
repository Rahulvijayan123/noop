// The phone's activity-context intervals (20261009190000_phone_context_intervals.sql): input of the server's Layer 1
// context-strata baselines (Tools/PersonalEventDetection/personal_events/layer1_context.py).
import type { SupabaseRest } from './rest.ts';

/** At most this many intervals per call (a day is far fewer; the phone splits a range that has more). */
export const CONTEXT_INTERVALS_MAX = 5000;
export const CONTEXT_INTERVALS_MAX_BODY_BYTES = 2 * 1024 * 1024;
const MAX_RANGE_SECONDS = 2 * 86400;
const EARLIEST = 1577836800;
const CLOCK_SLACK_SECONDS = 86400;
const VERSION_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9 ._:-]{0,63}$/;

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

export type ContextInterval = {
  start_ts: number; end_ts: number; activity_class: string; confidence: number; evidence_quality: number;
  posture: string | null; locomotion: string | null; sleep_state: string; wear_state: string;
  intensity: number | null; hr_samples: number; hr_mean: number | null; rmssd: number | null; rr_beats: number;
  rr_diff_sq_sum_ms2: number; rr_diff_count: number; detail: string | null; arm_behavior: string | null;
};

function label(value: unknown, required: boolean): string | null | undefined {
  if (value == null) return required ? undefined : null;
  return typeof value === 'string' && LABEL_RE.test(value) ? value : undefined;
}

function real(value: unknown, fallback: number | null): number | null | undefined {
  if (value == null) return fallback;
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function count(value: unknown): number | undefined {
  if (value == null) return 0;
  return Number.isInteger(value) && (value as number) >= 0 && (value as number) <= 1_000_000
    ? value as number : undefined;
}

/**
 * `POST /context-intervals` body: `{device_id, version, source_id?, from, to, intervals: [...]}`. Replaces the strap's
 * intervals starting in [from, to) (at most 2 days) with `intervals`, every start inside the range, no start twice.
 */
export function validateContextIntervals(body: unknown, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw fail('invalid_body', 400);
  const { version, source_id: sourceId, from, to, intervals } = body as Record<string, unknown>;
  if (typeof version !== 'string' || !VERSION_RE.test(version)) throw fail('invalid_version', 400);
  if (sourceId != null && (typeof sourceId !== 'string' || sourceId.length > 128)) throw fail('invalid_source', 400);
  if (!Number.isInteger(from) || !Number.isInteger(to) || (from as number) < EARLIEST || (to as number) <= (from as number)
      || (to as number) - (from as number) > MAX_RANGE_SECONDS || (from as number) > nowSeconds + CLOCK_SLACK_SECONDS) {
    throw fail('invalid_range', 400);
  }
  if (!Array.isArray(intervals) || intervals.length > CONTEXT_INTERVALS_MAX) throw fail('invalid_intervals', 400);
  const lo = from as number;
  const hi = to as number;
  const seen = new Set<number>();
  const out: ContextInterval[] = [];
  for (const item of intervals) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) throw fail('invalid_interval', 400);
    const r = item as Record<string, unknown>;
    const start = r.start_ts;
    const end = r.end_ts;
    if (!Number.isInteger(start) || !Number.isInteger(end) || (start as number) < lo || (start as number) >= hi
        || (end as number) <= (start as number) || (end as number) - (start as number) > 86400) {
      throw fail('invalid_interval', 400);
    }
    if (seen.has(start as number)) throw fail('duplicate_interval', 400);
    seen.add(start as number);
    const cls = label(r.activity_class, true);
    const posture = label(r.posture, false);
    const locomotion = label(r.locomotion, false);
    const sleep = label(r.sleep_state, false);
    const wear = label(r.wear_state, false);
    const detail = label(r.detail, false);
    const arm = label(r.arm_behavior, false);
    const confidence = real(r.confidence, 0);
    const evq = real(r.evidence_quality, 0);
    const intensity = real(r.intensity, null);
    const hrMean = real(r.hr_mean, null);
    const rmssd = real(r.rmssd, null);
    const sq = real(r.rr_diff_sq_sum_ms2, 0);
    const hrSamples = count(r.hr_samples);
    const rrBeats = count(r.rr_beats);
    const rrDiffCount = count(r.rr_diff_count);
    if (cls == null || posture === undefined || locomotion === undefined || sleep === undefined || wear === undefined
        || detail === undefined || arm === undefined || confidence == null || evq == null || intensity === undefined
        || hrMean === undefined || rmssd === undefined || sq == null || hrSamples === undefined
        || rrBeats === undefined || rrDiffCount === undefined) {
      throw fail('invalid_interval', 400);
    }
    out.push({
      start_ts: start as number, end_ts: end as number, activity_class: cls, confidence, evidence_quality: evq,
      posture, locomotion, sleep_state: sleep ?? 'unknown', wear_state: wear ?? 'unknown', intensity,
      hr_samples: hrSamples, hr_mean: hrMean, rmssd, rr_beats: rrBeats, rr_diff_sq_sum_ms2: sq,
      rr_diff_count: rrDiffCount, detail, arm_behavior: arm,
    });
  }
  return { version, sourceId: (sourceId as string | undefined) ?? null, from: lo, to: hi, intervals: out };
}

export async function submitContextIntervals({ rest, userId, deviceId, body }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; deviceId: string; body: unknown;
}) {
  const v = validateContextIntervals(body);
  const out = await rest.rpc('phone_context_intervals_replace_v1', {
    p_user: userId, p_device: deviceId, p_source: v.sourceId, p_version: v.version, p_from: v.from, p_to: v.to,
    p_intervals: v.intervals,
  });
  return { accepted: Number(out?.accepted ?? 0), deleted: Number(out?.deleted ?? 0) };
}
