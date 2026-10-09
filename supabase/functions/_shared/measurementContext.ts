// Per-minute measurement context (docs/context-watchdog/MEASUREMENT_CONTEXT.md;
// 20261009130100_measurement_context_minutes.sql): the scores route's read of the stored minutes.
import type { SupabaseRest } from './rest.ts';

/** One call returns at most a day of minutes per device (and at most this many rows in all). */
export const CONTEXT_MINUTES_MAX_ROWS = 1440;
const CONTEXT_MINUTES_MAX_RANGE_SECONDS = CONTEXT_MINUTES_MAX_ROWS * 60;

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

/**
 * `GET /context-minutes?from=<unix>&to=<unix>[&deviceId=<id>]`: the half-open range [from, to) of at most 1440
 * minutes. Anything malformed is rejected before the database is asked.
 */
export function parseContextMinutesQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) {
    throw fail('invalid_range', 400);
  }
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > CONTEXT_MINUTES_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  return { from: new Date(start * 1000).toISOString(), to: new Date(end * 1000).toISOString() };
}

/**
 * The owner's minutes in the range: one device, or every device of the owner when `deviceId` is null. Rows come back
 * oldest first with canonical reasons (each with its effect and family), the version rows they reference, and
 * `truncated` when more than 1440 rows matched. Owner and device are checked again by the RPC.
 */
export async function readContextMinutes({ rest, userId, deviceId, from, to }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; deviceId: string | null; from: string; to: string;
}) {
  const read = await rest.rpc('measurement_context_minutes_read_v1', {
    p_user: userId, p_device: deviceId, p_from: from, p_to: to,
  });
  return {
    rows: Array.isArray(read?.rows) ? read.rows : [],
    versions: read?.versions && typeof read.versions === 'object' && !Array.isArray(read.versions) ? read.versions : {},
    truncated: read?.truncated === true,
  };
}

// ---- POST /quality-minutes: the phone's per-minute optical evidence (20261009130200) ----------------------------

/** At most a day of minutes per call; a minute's evidence is a few dozen bytes, so 512 KiB is ample. */
export const QUALITY_MINUTES_MAX = 1440;
export const QUALITY_MINUTES_MAX_BODY_BYTES = 512 * 1024;
const QUALITY_MINUTES_MAX_SPAN_SECONDS = 3 * 86_400;
const QUALITY_MINUTES_CLOCK_SLACK_SECONDS = 120;
const QUALITY_MINUTE_EARLIEST = 1_577_836_800; // 2020-01-01
const GRADES = new Set(['good', 'degraded', 'poor', 'unknown']);
const RECORD_GAPS = new Set(['paused', 'lost']);
const LEGACY_REASON_RE = /^[a-z][a-z0-9_]{0,63}$/;
const VERSION_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

export interface QualityMinute {
  minute_start: number;
  v18_n: number | null;
  sentinel_n: number | null;
  baseline_max: number | null;
  record_gap: 'paused' | 'lost' | null;
  hr_grade: string | null;
  beats_grade: string | null;
  reasons: string[] | null;
}

function count(value: unknown, max: number): number | null | undefined {
  if (value == null) return null;
  return Number.isInteger(value) && (value as number) >= 0 && (value as number) <= max ? value as number : undefined;
}

function oneOf(value: unknown, allowed: Set<string>): string | null | undefined {
  if (value == null) return null;
  return typeof value === 'string' && allowed.has(value) ? value : undefined;
}

/**
 * The body the phone sends: `{device_id, version, minutes: [{minute_start, v18_n, sentinel_n, baseline_max,
 * record_gap, hr_grade, beats_grade, reasons}]}` (docs/context-watchdog/MEASUREMENT_CONTEXT.md). Every field but
 * minute_start may be null or absent; unknown fields are ignored (a newer phone may send more). Returns the
 * normalized minutes, or throws a 400 with the first problem's code.
 */
export function validateQualityMinutes(body: unknown, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw fail('invalid_body', 400);
  const { version, minutes } = body as Record<string, unknown>;
  if (typeof version !== 'string' || !VERSION_RE.test(version)) throw fail('invalid_version', 400);
  if (!Array.isArray(minutes) || minutes.length < 1 || minutes.length > QUALITY_MINUTES_MAX) {
    throw fail('invalid_minutes', 400);
  }
  const seen = new Set<number>();
  const out: QualityMinute[] = [];
  for (const item of minutes) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) throw fail('invalid_minute', 400);
    const m = item as Record<string, unknown>;
    const start = m.minute_start;
    if (!Number.isInteger(start) || (start as number) % 60 !== 0 || (start as number) < QUALITY_MINUTE_EARLIEST) {
      throw fail('invalid_minute', 400);
    }
    if ((start as number) > nowSeconds + QUALITY_MINUTES_CLOCK_SLACK_SECONDS) throw fail('invalid_range', 400);
    if (seen.has(start as number)) throw fail('duplicate_minute', 400);
    seen.add(start as number);
    const v18 = count(m.v18_n, 120);
    const sentinel = count(m.sentinel_n, 120);
    const baseline = count(m.baseline_max, 65_535);
    const gap = oneOf(m.record_gap, RECORD_GAPS);
    const hr = oneOf(m.hr_grade, GRADES);
    const beats = oneOf(m.beats_grade, GRADES);
    if (v18 === undefined || sentinel === undefined || baseline === undefined || gap === undefined
        || hr === undefined || beats === undefined) throw fail('invalid_minute', 400);
    if (v18 != null && sentinel != null && sentinel > v18) throw fail('invalid_minute', 400);
    let reasons: string[] | null = null;
    if (m.reasons != null) {
      if (!Array.isArray(m.reasons) || m.reasons.length > 32
          || m.reasons.some((r) => typeof r !== 'string' || !LEGACY_REASON_RE.test(r))) {
        throw fail('invalid_minute', 400);
      }
      reasons = [...m.reasons as string[]];
    }
    out.push({ minute_start: start as number, v18_n: v18, sentinel_n: sentinel, baseline_max: baseline,
      record_gap: gap as QualityMinute['record_gap'], hr_grade: hr, beats_grade: beats, reasons });
  }
  const starts = out.map((m) => m.minute_start);
  if (Math.max(...starts) - Math.min(...starts) >= QUALITY_MINUTES_MAX_SPAN_SECONDS) {
    throw fail('invalid_range', 400);
  }
  return { version, minutes: out };
}

/**
 * Store the phone's evidence for the owner's device and re-derive those minutes
 * (measurement_context_quality_upsert_v1; idempotent). `accepted` counts the minutes stored (a minute that has not
 * ended yet is not), `changed` the minutes whose evidence differed from what was stored.
 */
export async function submitQualityMinutes({ rest, userId, deviceId, body }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; deviceId: string; body: unknown;
}) {
  const { version, minutes } = validateQualityMinutes(body);
  const out = await rest.rpc('measurement_context_quality_upsert_v1', {
    p_user: userId, p_device: deviceId, p_version: version, p_minutes: minutes,
  });
  return { accepted: Number(out?.accepted ?? 0), changed: Number(out?.changed ?? 0) };
}
