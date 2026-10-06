// The physiology context routes of the `scores` function (docs/physiology-context/contracts.md §8, §10):
// query parsing for GET /context and GET /context/history, and the exposure-event envelope, validator and
// submit path for POST /exposures, plus the query of GET /exposures.
//
// Everything here only shapes requests. Ownership comes from the credential the route resolved; the
// database functions (20261006050000_physiology_context.sql) re-check owner and device and repeat every
// exposure rule as a backstop (internal.exposure_event_invalid_reason). Keep the two rule sets equal.
import type { SupabaseRest } from './rest.ts';

export const PHYSIOLOGY_CONTEXT_MODES = ['causal_live', 'retrospective'] as const;
/** At most this many local days per history request (the RPC's own limit). */
export const CONTEXT_HISTORY_MAX_DAYS = 120;

export const EXPOSURE_MAX_EVENTS = 25;
/** POST /exposures only; every other body-carrying route keeps the 8 KiB default. */
export const EXPOSURE_MAX_BODY_BYTES = 64 * 1024;
export const EXPOSURE_READ_MAX_RANGE_SECONDS = 366 * 86_400;
export const EXPOSURE_KINDS = ['medication', 'supplement', 'caffeine', 'alcohol', 'meal', 'heat', 'travel',
  'symptom', 'other'] as const;
export const EXPOSURE_TIME_PRECISIONS = ['exact', 'approximate', 'day_only'] as const;
export const EXPOSURE_SOURCES = ['user_entered', 'journal_day_answer', 'imported', 'inferred_candidate'] as const;
export const EXPOSURE_CONFIRMATIONS = ['confirmed', 'denied', 'candidate', 'retracted'] as const;
export const EXPOSURE_DOSE_PROVENANCES = ['user_entered', 'imported', 'catalog_default'] as const;
const MIN_TS = 946_684_800; // 2000-01-01
const MAX_TS = 4_102_444_800; // 2100-01-01
const MAX_OCCURRENCE_SECONDS = 31 * 86_400;
const EVENT_ID_RE = /^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$/;
const METRIC_RE = /^[a-z][a-z0-9_]{0,47}$/;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
// C0 controls except NUL (separately), DEL and C1 controls: the same class the SQL backstop refuses.
const CONTROL_RE = /[\u0001-\u001f\u007f-\u009f]/;
const LONE_SURROGATE_RE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/;

function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** Length in code points, which is what PostgreSQL's char_length counts. */
function codePoints(text: string): number {
  let count = 0;
  for (const _ of text) count++;
  return count;
}

/** Text PostgreSQL can store and the database rule accepts: no NUL, no lone surrogate, no control character. */
function cleanText(value: unknown, min: number, max: number): value is string {
  if (typeof value !== 'string' || value.includes('\u0000') || LONE_SURROGATE_RE.test(value)
      || CONTROL_RE.test(value)) return false;
  const size = codePoints(value);
  return size >= min && size <= max;
}

function intIn(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[]): value is T {
  return typeof value === 'string' && (allowed as readonly string[]).includes(value);
}

/** A real calendar day `yyyy-MM-dd` (2026-02-30 is refused, like the database refuses it). */
export function parseDay(value: string | null): string | null {
  if (value == null || !DAY_RE.test(value)) return null;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value ? value : null;
}

function parseMode(params: URLSearchParams): string | null {
  const mode = params.get('mode');
  if (mode == null || mode === '') return null;
  if (!oneOf(mode, PHYSIOLOGY_CONTEXT_MODES)) throw fail('invalid_mode', 400);
  return mode;
}

/** `GET /context?deviceId=&day=YYYY-MM-DD[&mode=causal_live|retrospective][&metric=hrv_rmssd]`. */
export function parseContextQuery(params: URLSearchParams) {
  const day = parseDay(params.get('day'));
  if (!day) throw fail('invalid_day', 400);
  const mode = parseMode(params);
  const rawMetric = params.get('metric');
  let metric: string | null = null;
  if (rawMetric != null && rawMetric !== '') {
    if (!METRIC_RE.test(rawMetric)) throw fail('invalid_metric', 400);
    metric = rawMetric;
  }
  return { day, mode, metric };
}

/** `GET /context/history?deviceId=&from=YYYY-MM-DD&to=YYYY-MM-DD[&mode=]`: at most 120 local days, inclusive. */
export function parseContextHistoryQuery(params: URLSearchParams) {
  const from = parseDay(params.get('from'));
  const to = parseDay(params.get('to'));
  if (!from || !to) throw fail('invalid_range', 400);
  const span = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000;
  if (span < 0 || span > CONTEXT_HISTORY_MAX_DAYS - 1) throw fail('invalid_range', 400);
  return { from, to, mode: parseMode(params) };
}

/** `GET /exposures?from=<unix>&to=<unix>[&history=1]`: a half-open range of at most 366 days. */
export function parseExposureReadQuery(params: URLSearchParams) {
  const from = params.get('from');
  const to = params.get('to');
  if (from == null || to == null || !/^\d{1,10}$/.test(from) || !/^\d{1,10}$/.test(to)) throw fail('invalid_range', 400);
  const start = Number(from);
  const end = Number(to);
  if (end <= start || end - start > EXPOSURE_READ_MAX_RANGE_SECONDS) throw fail('invalid_range', 400);
  const raw = params.get('history');
  if (raw != null && !['0', '1', 'true', 'false'].includes(raw)) throw fail('invalid_history', 400);
  return { from: start, to: end, history: raw === '1' || raw === 'true' };
}

/** The ExposureEventRevision JSON (snake_case) the database stores. received_at is the server's, never sent. */
export interface ExposureEventInput {
  event_id: string;
  revision: number;
  kind: typeof EXPOSURE_KINDS[number];
  label: string;
  occurred: { start: number; end: number };
  time_precision: typeof EXPOSURE_TIME_PRECISIONS[number];
  recorded_at: number;
  source: typeof EXPOSURE_SOURCES[number];
  confirmation: typeof EXPOSURE_CONFIRMATIONS[number];
  dose_amount: number | null;
  dose_unit: string | null;
  dose_provenance: typeof EXPOSURE_DOSE_PROVENANCES[number] | null;
}

export interface ExposureResult {
  event_id: string | null;
  revision: number | null;
  status: 'saved' | 'ignored' | 'rejected';
  reason: string | null;
  received_at?: number | null;
}

/**
 * One event, judged on its own. Unknown keys are ignored (a newer app may send more); a client
 * `received_at` is dropped. The reason codes are the database's: invalid_event, invalid_event_id,
 * invalid_revision, invalid_kind, invalid_label, invalid_occurred, invalid_time_precision,
 * invalid_recorded_at, invalid_source, invalid_confirmation (also an inferred candidate marked confirmed),
 * invalid_dose_amount, invalid_dose_unit, invalid_dose_provenance.
 */
export function validateExposureEvent(raw: unknown):
  { ok: true; event: ExposureEventInput } | { ok: false; rejection: ExposureResult } {
  const echoId = isPlainObject(raw) && typeof raw.event_id === 'string' && EVENT_ID_RE.test(raw.event_id)
    ? raw.event_id : null;
  const echoRevision = isPlainObject(raw) && intIn(raw.revision, 1, 2_147_483_647) ? raw.revision as number : null;
  const reject = (reason: string) => ({
    ok: false as const,
    rejection: { event_id: echoId, revision: echoRevision, status: 'rejected' as const, reason },
  });
  if (!isPlainObject(raw)) return reject('invalid_event');
  if (typeof raw.event_id !== 'string' || !EVENT_ID_RE.test(raw.event_id)) return reject('invalid_event_id');
  if (!intIn(raw.revision, 1, 2_147_483_647)) return reject('invalid_revision');
  if (!oneOf(raw.kind, EXPOSURE_KINDS)) return reject('invalid_kind');
  if (!cleanText(raw.label, 1, 200)) return reject('invalid_label');
  const occurred = raw.occurred;
  if (!isPlainObject(occurred) || !intIn(occurred.start, MIN_TS, MAX_TS) || !intIn(occurred.end, MIN_TS, MAX_TS)
      || (occurred.end as number) <= (occurred.start as number)
      || (occurred.end as number) - (occurred.start as number) > MAX_OCCURRENCE_SECONDS) {
    return reject('invalid_occurred');
  }
  if (!oneOf(raw.time_precision, EXPOSURE_TIME_PRECISIONS)) return reject('invalid_time_precision');
  if (!intIn(raw.recorded_at, MIN_TS, MAX_TS)) return reject('invalid_recorded_at');
  if (!oneOf(raw.source, EXPOSURE_SOURCES)) return reject('invalid_source');
  if (!oneOf(raw.confirmation, EXPOSURE_CONFIRMATIONS)
      || (raw.source === 'inferred_candidate' && raw.confirmation === 'confirmed')) {
    return reject('invalid_confirmation');
  }
  const dose = raw.dose_amount ?? null;
  if (dose !== null && (typeof dose !== 'number' || !Number.isFinite(dose) || dose < 0 || dose > 1e9)) {
    return reject('invalid_dose_amount');
  }
  const unit = raw.dose_unit ?? null;
  if (unit !== null && !cleanText(unit, 1, 32)) return reject('invalid_dose_unit');
  const provenance = raw.dose_provenance ?? null;
  if (provenance !== null && !oneOf(provenance, EXPOSURE_DOSE_PROVENANCES)) return reject('invalid_dose_provenance');
  return {
    ok: true,
    event: {
      event_id: raw.event_id,
      revision: raw.revision as number,
      kind: raw.kind,
      label: raw.label as string,
      occurred: { start: occurred.start as number, end: occurred.end as number },
      time_precision: raw.time_precision,
      recorded_at: raw.recorded_at as number,
      source: raw.source,
      confirmation: raw.confirmation,
      dose_amount: dose as number | null,
      dose_unit: unit as string | null,
      dose_provenance: provenance as ExposureEventInput['dose_provenance'],
    },
  };
}

/** The `events` array of a POST body, or a 400 `invalid_events` (not an object, missing, empty, over 25). */
export function parseExposureEnvelope(body: unknown): unknown[] {
  const events = isPlainObject(body) ? body.events : undefined;
  if (!Array.isArray(events) || events.length < 1 || events.length > EXPOSURE_MAX_EVENTS) {
    throw fail('invalid_events', 400);
  }
  return events;
}

/**
 * `POST /exposures {events: [...]}`: validate each event; record the valid ones in order, one RPC each, with
 * the owner and source from the credential. Each record is its own transaction, so a retried batch whose
 * first events already landed gets `ignored`/`duplicate` for them. Results keep the request order.
 */
export async function submitExposureEvents({ rest, userId, sourceId, body }: {
  rest: Pick<SupabaseRest, 'rpc'>; userId: string; sourceId: string; body: unknown;
}): Promise<{ results: ExposureResult[] }> {
  const events = parseExposureEnvelope(body);
  const results: ExposureResult[] = [];
  for (const raw of events) {
    const checked = validateExposureEvent(raw);
    if (!checked.ok) {
      results.push(checked.rejection);
      continue;
    }
    const outcome = await rest.rpc('record_exposure_event_v1', {
      p_owner: userId, p_source: sourceId, p_event: checked.event,
    });
    const status = ['saved', 'ignored', 'rejected'].includes(outcome?.status) ? outcome.status : null;
    if (!status) throw new Error('exposure_record_unexpected_result');
    results.push({
      event_id: checked.event.event_id,
      revision: checked.event.revision,
      status,
      reason: typeof outcome?.reason === 'string' ? outcome.reason : null,
      received_at: Number.isSafeInteger(outcome?.received_at) ? outcome.received_at : null,
    });
  }
  return { results };
}
