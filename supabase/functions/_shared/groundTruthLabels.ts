import { isSafeExternalDeviceId, isUuid } from './keys.ts';
import { findNoopDevice } from './devices.ts';
import type { SupabaseRest } from './rest.ts';

/**
 * Validation, normalisation and submission for `POST /scores/ground-truth-labels`: what a person
 * actually did over an interval, captured during guided calibration (`source='guided'`), from a
 * stretch-feedback correction (`source='stretch_feedback'`), imported (`source='imported'`) or an
 * in-the-moment "Right now: sitting / standing / neither?" answer (`source='confirmation'`).
 *
 * A confirmation carries only the posture head: `seated_likely` (sitting), `upright_stationary`
 * (standing) or `unknown` (neither: a certain negative for both, not an abstain), with no transition
 * and an interval of at most 120 s (20261008100500_activity_ground_truth_confirmation_source.sql).
 *
 * Pure for the validation half: no I/O. The envelope is all-or-nothing (a malformed envelope throws
 * a 400); every item is judged on its own, so one bad item comes back in `rejected` with a short
 * reason code and never fails the rest. Only items that pass here reach
 * `upsert_activity_ground_truth_labels`; the table's CHECK constraints mirror these rules as a
 * backstop. `submitGroundTruthLabels` is the route half (device resolution + the RPC), mirroring
 * the stretch-feedback submit path.
 */

export const GROUND_TRUTH_LABELS_MAX_ITEMS = 25;
export const GROUND_TRUTH_LABELS_MAX_BODY_BYTES = 128 * 1024;
/** Per jsonb object field (cue_context, sensor_quality, model_context_at_label_time). */
export const GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES = 16 * 1024;
/** raw_refs (an array) gets the same compact-JSON budget as the object fields. */
export const GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES = 16 * 1024;
/** Levels of arrays/objects in a jsonb field; deeper than any real model output, and stops a 16 KiB body of nothing but brackets. */
export const GROUND_TRUTH_LABELS_MAX_JSON_DEPTH = 32;
export const GROUND_TRUTH_LABELS_MIN_START_TS = 946_684_800;
export const GROUND_TRUTH_LABELS_MAX_SPAN_SECONDS = 86_400;

export const GROUND_TRUTH_SOURCES = ['guided', 'stretch_feedback', 'imported', 'confirmation'] as const;
/** Longest interval a `confirmation` answer may cover. */
export const GROUND_TRUTH_CONFIRMATION_MAX_SPAN_SECONDS = 120;
/** The posture answers a `confirmation` may carry: sitting, standing, neither. */
export const GROUND_TRUTH_CONFIRMATION_POSTURES = ['seated_likely', 'upright_stationary', 'unknown'] as const;
export const GROUND_TRUTH_POSTURES = [
  'recumbent', 'seated_likely', 'upright_stationary', 'postural_transition', 'unknown',
] as const;
export const GROUND_TRUTH_LOCOMOTIONS = [
  'stationary', 'walking', 'brisk_walking', 'running', 'stairs', 'cycling', 'vehicle_motion',
  'other', 'unknown',
] as const;
export const GROUND_TRUTH_ARM_BEHAVIORS = [
  'quiet', 'desk_like', 'fidgeting', 'repetitive_hand_motion', 'active_gesturing',
  'exercise_motion', 'other', 'unknown',
] as const;
/** Ground-truth transition kinds are definitive (no `_like` suffix; those belong to model output). */
export const GROUND_TRUTH_TRANSITION_KINDS = [
  'sit_to_stand', 'stand_to_sit', 'lying_down', 'getting_up', 'walk_start', 'walk_stop',
  'run_start', 'run_stop',
] as const;
export const GROUND_TRUTH_SEMANTIC_TAGS = [
  'typing', 'mouse_work', 'phone_use', 'writing', 'eating', 'reading', 'fidgeting', 'desk_work',
] as const;

const LABEL_KEY_RE = /^[A-Za-z0-9:_.-]+$/;
const ISO_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/;
const LONE_SURROGATE_RE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/;

export type GroundTruthSource = typeof GROUND_TRUTH_SOURCES[number];

/** One validated item, in the shape `upsert_activity_ground_truth_labels` reads. */
export interface GroundTruthLabelItem {
  client_id: string;
  label_key: string;
  source: GroundTruthSource;
  session_id: string | null;
  protocol_version: string | null;
  repetition: number | null;
  /** The app's own device id as sent, when it is a safe id; the route resolves it to `device_id`. */
  external_device_id: string | null;
  /** Internal device uuid. Always null from the validator; the route fills it in when the id resolves. */
  device_id: string | null;
  start_ts: number;
  end_ts: number;
  posture: string | null;
  locomotion: string | null;
  arm_behavior: string | null;
  transition_kind: string | null;
  transition_ts: number | null;
  semantic_tag: string | null;
  label_confidence: number | null;
  user_unsure: boolean;
  note: string | null;
  cue_context: Record<string, unknown>;
  sensor_quality: Record<string, unknown>;
  raw_refs: unknown[];
  model_context_at_label_time: Record<string, unknown>;
  app_version: string | null;
  app_build: string | null;
  tz_offset_s: number | null;
  client_created_at: string | null;
  client_updated_at: string;
}

export interface GroundTruthLabelRejection {
  label_key: string | null;
  reason: string;
}

export interface GroundTruthLabelsValidation {
  valid: GroundTruthLabelItem[];
  rejected: GroundTruthLabelRejection[];
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
  if (!container || depth > GROUND_TRUTH_LABELS_MAX_JSON_DEPTH) return false;
  if (Array.isArray(value)) return value.every((entry) => contextShapeOk(entry, depth + 1));
  return Object.entries(value as Record<string, unknown>).every(([key, entry]) =>
    storable(key) && contextShapeOk(entry, depth + 1));
}

/** One of the jsonb object fields: a plain object, bounded shape and 16 KiB compact JSON. */
function jsonField(value: unknown): Checked<Record<string, unknown>> {
  if (value === undefined) return ok({});
  if (!isPlainObject(value) || !contextShapeOk(value, 1)) return bad;
  const bytes = new TextEncoder().encode(JSON.stringify(value)).length;
  return bytes <= GROUND_TRUTH_LABELS_MAX_JSON_FIELD_BYTES ? ok(value) : bad;
}

/** raw_refs: an array of plain objects (the phone's own evidence facts), bounded shape and 16 KiB. */
function rawRefs(value: unknown): Checked<unknown[]> {
  if (value === undefined) return ok([]);
  if (!Array.isArray(value) || !contextShapeOk(value, 1) || !value.every(isPlainObject)) return bad;
  const bytes = new TextEncoder().encode(JSON.stringify(value)).length;
  return bytes <= GROUND_TRUTH_LABELS_MAX_RAW_REFS_BYTES ? ok(value) : bad;
}

function oneOf<T extends string>(value: unknown, allowed: readonly T[]): Checked<T> {
  return typeof value === 'string' && (allowed as readonly string[]).includes(value) ? ok(value as T) : bad;
}

/** An optional vocabulary value: absent/null/'' mean "not given"; anything else must be in the list. */
function optionalOneOf<T extends string>(value: unknown, allowed: readonly T[]): Checked<T | null> {
  if (value === undefined || value === null || value === '') return ok(null);
  return oneOf(value, allowed);
}

/**
 * The `labels` array of a request body, or a 400 `invalid_labels` when the body is not an object or
 * `labels` is missing, not an array, empty or longer than 25.
 */
export function parseGroundTruthLabelsEnvelope(body: unknown): unknown[] {
  const labels = isPlainObject(body) ? body.labels : undefined;
  if (!Array.isArray(labels) || labels.length < 1 || labels.length > GROUND_TRUTH_LABELS_MAX_ITEMS) {
    throw envelopeError('invalid_labels');
  }
  return labels;
}

/** The label key to echo in a rejection: only a well-formed one, never arbitrary client text. */
function echoableKey(raw: unknown): string | null {
  const key = isPlainObject(raw) ? raw.label_key : undefined;
  return typeof key === 'string' && key.length >= 1 && key.length <= 96 && LABEL_KEY_RE.test(key) ? key : null;
}

export function validateGroundTruthLabelItem(raw: unknown):
  { ok: true; item: GroundTruthLabelItem } | { ok: false; rejection: GroundTruthLabelRejection } {
  const reject = (reason: string) => ({ ok: false as const, rejection: { label_key: echoableKey(raw), reason } });
  if (!isPlainObject(raw)) return reject('invalid_item');

  const labelKey = boundedText(raw.label_key, 1, 96);
  if (!labelKey.ok || !LABEL_KEY_RE.test(labelKey.value)) return reject('invalid_label_key');
  if (!isUuid(raw.id)) return reject('invalid_id');
  const source = oneOf(raw.source, GROUND_TRUTH_SOURCES);
  if (!source.ok) return reject('invalid_source');

  const start = integerIn(raw.start_ts, GROUND_TRUTH_LABELS_MIN_START_TS + 1, Number.MAX_SAFE_INTEGER);
  const end = integerIn(raw.end_ts, 1, Number.MAX_SAFE_INTEGER);
  if (!start.ok || !end.ok || end.value <= start.value
      || end.value - start.value > GROUND_TRUTH_LABELS_MAX_SPAN_SECONDS) return reject('invalid_time_range');

  const sessionId = optionalText(raw.session_id, 64);
  if (!sessionId.ok) return reject('invalid_session_id');
  const protocolVersion = optionalText(raw.protocol_version, 32);
  if (!protocolVersion.ok) return reject('invalid_protocol_version');
  let repetition: number | null = null;
  if (raw.repetition !== undefined && raw.repetition !== null) {
    const checked = integerIn(raw.repetition, 0, Number.MAX_SAFE_INTEGER);
    if (!checked.ok) return reject('invalid_repetition');
    repetition = checked.value;
  }

  const posture = optionalOneOf(raw.posture, GROUND_TRUTH_POSTURES);
  if (!posture.ok) return reject('invalid_posture');
  const locomotion = optionalOneOf(raw.locomotion, GROUND_TRUTH_LOCOMOTIONS);
  if (!locomotion.ok) return reject('invalid_locomotion');
  const armBehavior = optionalOneOf(raw.arm_behavior, GROUND_TRUTH_ARM_BEHAVIORS);
  if (!armBehavior.ok) return reject('invalid_arm_behavior');
  const transitionKind = optionalOneOf(raw.transition_kind, GROUND_TRUTH_TRANSITION_KINDS);
  if (!transitionKind.ok) return reject('invalid_transition_kind');
  let transitionTs: number | null = null;
  if (raw.transition_ts !== undefined && raw.transition_ts !== null) {
    const checked = integerIn(raw.transition_ts, start.value, end.value);
    if (!checked.ok) return reject('invalid_transition_ts');
    transitionTs = checked.value;
  }
  const semanticTag = optionalOneOf(raw.semantic_tag, GROUND_TRUTH_SEMANTIC_TAGS);
  if (!semanticTag.ok) return reject('invalid_semantic_tag');
  if (source.value === 'confirmation') {
    if (end.value - start.value > GROUND_TRUTH_CONFIRMATION_MAX_SPAN_SECONDS) return reject('invalid_confirmation_span');
    if (posture.value === null
        || !(GROUND_TRUTH_CONFIRMATION_POSTURES as readonly string[]).includes(posture.value)) {
      return reject('invalid_confirmation_posture');
    }
    if (transitionKind.value !== null || transitionTs !== null) return reject('invalid_confirmation_transition');
  }

  let confidence: number | null = null;
  if (raw.label_confidence !== undefined && raw.label_confidence !== null) {
    if (typeof raw.label_confidence !== 'number' || !Number.isFinite(raw.label_confidence)
        || raw.label_confidence < 0 || raw.label_confidence > 1) return reject('invalid_label_confidence');
    confidence = raw.label_confidence;
  }
  let unsure = false;
  if (raw.user_unsure !== undefined && raw.user_unsure !== null) {
    if (typeof raw.user_unsure !== 'boolean') return reject('invalid_user_unsure');
    unsure = raw.user_unsure;
  }

  const note = optionalText(raw.note, 280);
  if (!note.ok) return reject('invalid_note');
  const cueContext = jsonField(raw.cue_context);
  if (!cueContext.ok) return reject('invalid_cue_context');
  const sensorQuality = jsonField(raw.sensor_quality);
  if (!sensorQuality.ok) return reject('invalid_sensor_quality');
  const refs = rawRefs(raw.raw_refs);
  if (!refs.ok) return reject('invalid_raw_refs');
  const modelContext = jsonField(raw.model_context_at_label_time);
  if (!modelContext.ok) return reject('invalid_model_context_at_label_time');
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
      label_key: labelKey.value,
      source: source.value,
      session_id: sessionId.value,
      protocol_version: protocolVersion.value,
      repetition,
      external_device_id: externalDevice,
      device_id: null,
      start_ts: start.value,
      end_ts: end.value,
      posture: posture.value,
      locomotion: locomotion.value,
      arm_behavior: armBehavior.value,
      transition_kind: transitionKind.value,
      transition_ts: transitionTs,
      semantic_tag: semanticTag.value,
      label_confidence: confidence,
      user_unsure: unsure,
      note: note.value,
      cue_context: cueContext.value,
      sensor_quality: sensorQuality.value,
      raw_refs: refs.value,
      model_context_at_label_time: modelContext.value,
      app_version: appVersion.value,
      app_build: appBuild.value,
      tz_offset_s: offset,
      client_created_at: createdAt,
      client_updated_at: updatedAt.value,
    },
  };
}

/** Parses the envelope (throws a 400) and splits the items into those to store and those refused. */
export function validateGroundTruthLabels(body: unknown): GroundTruthLabelsValidation {
  const valid: GroundTruthLabelItem[] = [];
  const rejected: GroundTruthLabelRejection[] = [];
  for (const raw of parseGroundTruthLabelsEnvelope(body)) {
    const result = validateGroundTruthLabelItem(raw);
    if (result.ok) valid.push(result.item);
    else rejected.push(result.rejection);
  }
  return { valid, rejected };
}

/**
 * `POST /ground-truth-labels` submit path: validate every item, resolve each item's optional device
 * to one the caller owns (an id that does not resolve is stored as no device, never an error), and
 * hand only the valid items to `upsert_activity_ground_truth_labels` with the owner taken from the
 * credential. Rejected items are reported back individually; the last-writer-wins decision (saved
 * vs ignored/stale) and the raw_refs server-side enrichment are the RPC's.
 */
export async function submitGroundTruthLabels({ rest, userId, sourceId, body }: {
  rest: Pick<SupabaseRest, 'select' | 'rpc'>; userId: string; sourceId: string; body: unknown;
}) {
  const { valid, rejected } = validateGroundTruthLabels(body);
  const resolved = new Map<string, string | null>();
  const items = [];
  for (const item of valid) {
    const external = item.external_device_id;
    if (external != null && !resolved.has(external)) {
      resolved.set(external, await findNoopDevice({ rest, userId, sourceId, externalDeviceId: external }));
    }
    items.push({ ...item, device_id: external != null ? (resolved.get(external) ?? null) : null });
  }
  let saved: unknown[] = [];
  let ignored: unknown[] = [];
  if (items.length > 0) {
    const result = await rest.rpc('upsert_activity_ground_truth_labels', { p_owner: userId, p_items: items });
    saved = Array.isArray(result?.saved) ? result.saved : [];
    ignored = Array.isArray(result?.ignored) ? result.ignored : [];
  }
  return { saved, ignored, rejected };
}
