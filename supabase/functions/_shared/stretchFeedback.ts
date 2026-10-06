import { isSafeExternalDeviceId, isUuid } from './keys.ts';

/**
 * Validation and normalisation for `POST /scores/stretch-feedback`: a person's verdict on one detected
 * activity stretch, stored with what the model predicted so the label can later tune the model.
 *
 * Pure: no I/O. The envelope is all-or-nothing (a malformed envelope throws a 400); every item is judged
 * on its own, so one bad item comes back in `rejected` with a short reason code and never fails the rest.
 * Only items that pass here reach `upsert_activity_stretch_feedback`; the table's CHECK constraints
 * mirror these rules as a backstop.
 */

export const STRETCH_FEEDBACK_MAX_ITEMS = 25;
export const STRETCH_FEEDBACK_MAX_BODY_BYTES = 128 * 1024;
export const STRETCH_FEEDBACK_MAX_CONTEXT_BYTES = 16 * 1024;
/** Levels of arrays/objects in model_context; deeper than any real model output, and stops a 16 KiB body of nothing but brackets. */
export const STRETCH_FEEDBACK_MAX_CONTEXT_DEPTH = 32;
export const STRETCH_FEEDBACK_MIN_START_TS = 946_684_800;
export const STRETCH_FEEDBACK_MAX_SPAN_SECONDS = 86_400;

export const STRETCH_KINDS = ['activity_context', 'strap_state'] as const;
export const STRETCH_VERDICTS = ['correct', 'incorrect'] as const;
export const STRETCH_CORRECTED_LABELS = [
  'sitting', 'standing', 'lying_down', 'asleep', 'walking', 'brisk_walking', 'running', 'stairs',
  'cycling', 'in_vehicle', 'desk_work', 'typing', 'fidgeting', 'exercise', 'other_movement',
  'not_wearing', 'other',
] as const;

const STRETCH_KEY_RE = /^[A-Za-z0-9:_.-]+$/;
const ISO_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/;
const LONE_SURROGATE_RE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

export type StretchKind = typeof STRETCH_KINDS[number];
export type StretchVerdict = typeof STRETCH_VERDICTS[number];

/** One validated item, in the shape `upsert_activity_stretch_feedback` reads. */
export interface StretchFeedbackItem {
  client_id: string;
  stretch_key: string;
  kind: StretchKind;
  /** The app's own device id as sent, when it is a safe id; the route resolves it to `device_id`. */
  external_device_id: string | null;
  /** Internal device uuid. Always null from the validator; the route fills it in when the id resolves. */
  device_id: string | null;
  start_ts: number;
  end_ts: number;
  predicted_label: string;
  predicted_class: string | null;
  predicted_confidence: number | null;
  verdict: StretchVerdict;
  corrected_label: string | null;
  note: string | null;
  model_context: Record<string, unknown>;
  app_version: string | null;
  app_build: string | null;
  tz_offset_s: number | null;
  client_created_at: string | null;
  client_updated_at: string;
}

export interface StretchFeedbackRejection {
  stretch_key: string | null;
  reason: string;
}

export interface StretchFeedbackValidation {
  valid: StretchFeedbackItem[];
  rejected: StretchFeedbackRejection[];
}

type Checked<T> = { ok: true; value: T } | { ok: false };
const ok = <T>(value: T): Checked<T> => ({ ok: true, value });
const bad: Checked<never> = { ok: false };

function envelopeError(code: string): Error {
  return Object.assign(new Error(code), { code, status: 400 });
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/** Length in code points, which is what PostgreSQL's char_length counts. */
function length(text: string): number {
  let count = 0;
  for (const _ of text) count++;
  return count;
}

/** PostgreSQL text and jsonb cannot hold NUL, and jsonb rejects an unpaired surrogate. */
function storable(text: string): boolean {
  return !text.includes('\u0000') && !LONE_SURROGATE_RE.test(text);
}

function boundedText(value: unknown, min: number, max: number): Checked<string> {
  if (typeof value !== 'string' || !storable(value)) return bad;
  const size = length(value);
  return size >= min && size <= max ? ok(value) : bad;
}

/** Absent and null both mean "not given"; an empty string is normalised to the same. */
function optionalText(value: unknown, max: number): Checked<string | null> {
  if (value === undefined || value === null || value === '') return ok(null);
  const text = boundedText(value, 1, max);
  return text.ok ? ok(text.value) : bad;
}

function integerIn(value: unknown, min: number, max: number): Checked<number> {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= min && value <= max
    ? ok(value) : bad;
}

function daysInMonth(year: number, month: number): number {
  return [31, year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];
}

/**
 * ISO-8601 with an explicit zone, checked field by field (a lenient date parser would roll 2026-02-30
 * into March, and PostgreSQL would then refuse the string we forwarded). Returns the instant as a
 * canonical UTC string at millisecond precision, which is what the last-writer-wins comparison uses.
 */
function isoInstant(value: unknown): Checked<string> {
  if (typeof value !== 'string') return bad;
  const match = ISO_RE.exec(value);
  if (!match) return bad;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  if (month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month)
      || hour > 23 || minute > 59 || second > 59) return bad;
  let offsetMinutes = 0;
  const zone = match[8];
  if (zone !== 'Z') {
    const zoneHour = Number(zone.slice(1, 3));
    const zoneMinute = Number(zone.slice(4, 6));
    if (zoneHour > 23 || zoneMinute > 59) return bad;
    offsetMinutes = (zone[0] === '-' ? -1 : 1) * (zoneHour * 60 + zoneMinute);
  }
  const millis = Number((match[7] ?? '').padEnd(3, '0').slice(0, 3));
  const at = new Date(0);
  at.setUTCFullYear(year, month - 1, day);
  at.setUTCHours(hour, minute, second, millis);
  const instant = at.getTime() - offsetMinutes * 60_000;
  const normalised = new Date(instant);
  if (!Number.isFinite(instant) || normalised.getUTCFullYear() < 1 || normalised.getUTCFullYear() > 9999) return bad;
  return ok(normalised.toISOString());
}

/** Walks the value once: JSON types only, finite numbers, storable text, at most 32 levels of arrays/objects. */
function contextShapeOk(value: unknown, depth: number): boolean {
  if (value === null || typeof value === 'boolean') return true;
  if (typeof value === 'number') return Number.isFinite(value);
  if (typeof value === 'string') return storable(value);
  const container = Array.isArray(value) || isPlainObject(value);
  if (!container || depth > STRETCH_FEEDBACK_MAX_CONTEXT_DEPTH) return false;
  if (Array.isArray(value)) return value.every((entry) => contextShapeOk(entry, depth + 1));
  return Object.entries(value as Record<string, unknown>).every(([key, entry]) =>
    storable(key) && contextShapeOk(entry, depth + 1));
}

function modelContext(value: unknown): Checked<Record<string, unknown>> {
  if (value === undefined) return ok({});
  if (!isPlainObject(value) || !contextShapeOk(value, 1)) return bad;
  const bytes = new TextEncoder().encode(JSON.stringify(value)).length;
  return bytes <= STRETCH_FEEDBACK_MAX_CONTEXT_BYTES ? ok(value) : bad;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[]): Checked<T> {
  return typeof value === 'string' && (allowed as readonly string[]).includes(value) ? ok(value as T) : bad;
}

/**
 * The `feedback` array of a request body, or a 400 `invalid_feedback` when the body is not an object or
 * `feedback` is missing, not an array, empty or longer than 25.
 */
export function parseStretchFeedbackEnvelope(body: unknown): unknown[] {
  const feedback = isPlainObject(body) ? body.feedback : undefined;
  if (!Array.isArray(feedback) || feedback.length < 1 || feedback.length > STRETCH_FEEDBACK_MAX_ITEMS) {
    throw envelopeError('invalid_feedback');
  }
  return feedback;
}

/** The stretch key to echo in a rejection: only a well-formed one, never arbitrary client text. */
function echoableKey(raw: unknown): string | null {
  const key = isPlainObject(raw) ? raw.stretch_key : undefined;
  return typeof key === 'string' && key.length >= 1 && key.length <= 96 && STRETCH_KEY_RE.test(key) ? key : null;
}

export function validateStretchFeedbackItem(raw: unknown):
  { ok: true; item: StretchFeedbackItem } | { ok: false; rejection: StretchFeedbackRejection } {
  const reject = (reason: string) => ({ ok: false as const, rejection: { stretch_key: echoableKey(raw), reason } });
  if (!isPlainObject(raw)) return reject('invalid_item');

  const stretchKey = boundedText(raw.stretch_key, 1, 96);
  if (!stretchKey.ok || !STRETCH_KEY_RE.test(stretchKey.value)) return reject('invalid_stretch_key');
  if (!isUuid(raw.id)) return reject('invalid_id');
  const kind = oneOf(raw.kind, STRETCH_KINDS);
  if (!kind.ok) return reject('invalid_kind');

  const start = integerIn(raw.start_ts, STRETCH_FEEDBACK_MIN_START_TS + 1, Number.MAX_SAFE_INTEGER);
  const end = integerIn(raw.end_ts, 1, Number.MAX_SAFE_INTEGER);
  if (!start.ok || !end.ok || end.value <= start.value
      || end.value - start.value > STRETCH_FEEDBACK_MAX_SPAN_SECONDS) return reject('invalid_time_range');

  const label = boundedText(raw.predicted_label, 1, 64);
  if (!label.ok) return reject('invalid_predicted_label');
  const predictedClass = optionalText(raw.predicted_class, 64);
  if (!predictedClass.ok) return reject('invalid_predicted_class');
  let confidence: number | null = null;
  if (raw.predicted_confidence !== undefined && raw.predicted_confidence !== null) {
    if (typeof raw.predicted_confidence !== 'number' || !Number.isFinite(raw.predicted_confidence)
        || raw.predicted_confidence < 0 || raw.predicted_confidence > 1) return reject('invalid_predicted_confidence');
    confidence = raw.predicted_confidence;
  }

  const verdict = oneOf(raw.verdict, STRETCH_VERDICTS);
  if (!verdict.ok) return reject('invalid_verdict');
  // A correction only means something on an "incorrect" verdict, so a label sent with "correct" is
  // refused rather than quietly dropped: the two disagree about what the person meant.
  let corrected: string | null = null;
  if (raw.corrected_label !== undefined && raw.corrected_label !== null) {
    const chosen = oneOf(raw.corrected_label, STRETCH_CORRECTED_LABELS);
    if (!chosen.ok || verdict.value !== 'incorrect') return reject('invalid_corrected_label');
    corrected = chosen.value;
  }

  const note = optionalText(raw.note, 280);
  if (!note.ok) return reject('invalid_note');
  const context = modelContext(raw.model_context);
  if (!context.ok) return reject('invalid_model_context');
  const appVersion = optionalText(raw.app_version, 32);
  if (!appVersion.ok) return reject('invalid_app_version');
  const appBuild = optionalText(raw.app_build, 32);
  if (!appBuild.ok) return reject('invalid_app_build');
  let offset: number | null = null;
  if (raw.tz_offset_s !== undefined && raw.tz_offset_s !== null) {
    const checked = integerIn(raw.tz_offset_s, -64_800, 64_800);
    if (!checked.ok) return reject('invalid_tz_offset');
    offset = checked.value;
  }
  let createdAt: string | null = null;
  if (raw.client_created_at !== undefined && raw.client_created_at !== null) {
    const checked = isoInstant(raw.client_created_at);
    if (!checked.ok) return reject('invalid_client_created_at');
    createdAt = checked.value;
  }
  const updatedAt = isoInstant(raw.client_updated_at);
  if (!updatedAt.ok) return reject('invalid_client_updated_at');

  // The device never fails an item: anything that is not a safe external id is simply not stored.
  const externalDevice = typeof raw.device_id === 'string' && isSafeExternalDeviceId(raw.device_id)
    ? raw.device_id : null;

  return {
    ok: true,
    item: {
      client_id: (raw.id as string).toLowerCase(),
      stretch_key: stretchKey.value,
      kind: kind.value,
      external_device_id: externalDevice,
      device_id: null,
      start_ts: start.value,
      end_ts: end.value,
      predicted_label: label.value,
      predicted_class: predictedClass.value,
      predicted_confidence: confidence,
      verdict: verdict.value,
      corrected_label: corrected,
      note: note.value,
      model_context: context.value,
      app_version: appVersion.value,
      app_build: appBuild.value,
      tz_offset_s: offset,
      client_created_at: createdAt,
      client_updated_at: updatedAt.value,
    },
  };
}

/** Parses the envelope (throws a 400) and splits the items into those to store and those refused. */
export function validateStretchFeedback(body: unknown): StretchFeedbackValidation {
  const valid: StretchFeedbackItem[] = [];
  const rejected: StretchFeedbackRejection[] = [];
  for (const raw of parseStretchFeedbackEnvelope(body)) {
    const result = validateStretchFeedbackItem(raw);
    if (result.ok) valid.push(result.item);
    else rejected.push(result.rejection);
  }
  return { valid, rejected };
}
