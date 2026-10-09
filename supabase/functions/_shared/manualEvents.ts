import type { SupabaseRest } from './rest.ts';
import { isUuid } from './keys.ts';

// Routes of `scores` for the manual event log (docs/EVENT_LOGGING.md):
//   POST /manual-events           append revisions; every item is judged on its own
//   GET  /manual-events?after=    the account's retained history, a page of 100 after a cursor
//   GET  /manual-events/context?ids=a,b   the timestamp-aligned context of up to 25 logged events
// Ownership comes from the credential the route resolved. The database repeats the shape rules as a backstop.

export const MANUAL_EVENTS_MAX_BODY_BYTES = 256 * 1024;
export const MANUAL_EVENTS_MAX_ITEMS = 25;
export const MANUAL_EVENT_CONTEXT_MAX_IDS = 25;
/** What a logged activity was, in the activity classifier's terms; 'other' has no classifier counterpart. */
export const MANUAL_EVENT_ACTIVITY_KINDS = ['rest', 'walking', 'running', 'cycling', 'stairs', 'exercise', 'other'] as const;
/** 2000-01-01: an event before it is a clock or entry error (the ground-truth table refuses it too). */
const MIN_EVENT_START = 946_684_800;
const MAX_INSTANT = 32_503_680_000;
const fail = (code: string, status = 400) => Object.assign(new Error(code), { code, status });
const object = (v: unknown): v is Record<string, any> => v !== null && typeof v === 'object' && !Array.isArray(v);
const text = (v: unknown, max: number, required = false) => typeof v === 'string'
  && !v.includes('\u0000') && !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(v)
  && [...v].length <= max && (!required || v.trim().length > 0);
const optional = (v: unknown, check: (v: unknown) => boolean) => v == null || check(v);
const instant = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= MAX_INSTANT;
const entryKeys = new Set(['id', 'kind', 'label', 'symbol', 'typeId', 'favorite', 'durationMinutes',
  'startUnixSeconds', 'endUnixSeconds', 'note', 'deviceId', 'timeZoneIdentifier', 'archived', 'archivedAt',
  'activityKind']);

/** Why a revision is refused, or null when it is valid. */
export function manualEventRevisionProblem(value: unknown): string | null {
  if (!object(value) || Object.keys(value).some(k => !['revision_id', 'updated_at_ms', 'entry'].includes(k))
      || !isUuid(value.revision_id) || !Number.isSafeInteger(value.updated_at_ms)
      || value.updated_at_ms <= 0 || value.updated_at_ms > MAX_INSTANT * 1000 || !object(value.entry)) {
    return 'invalid_revision';
  }
  const e = value.entry;
  if (Object.keys(e).some(k => !entryKeys.has(k)) || !isUuid(e.id)
      || !['event', 'event_type', 'preset'].includes(e.kind)) return 'invalid_entry';
  if (!text(e.label, 100, true)) return 'invalid_label';
  if (!text(e.symbol, 80, true) || !text(e.timeZoneIdentifier, 100, true)
      || typeof e.favorite !== 'boolean' || typeof e.archived !== 'boolean'
      || !optional(e.deviceId, v => text(v, 128)) || !optional(e.typeId, isUuid)) return 'invalid_entry';
  if (!optional(e.note, v => text(v, 2000))) return 'invalid_note';
  if (!optional(e.activityKind, v => (MANUAL_EVENT_ACTIVITY_KINDS as readonly unknown[]).includes(v))) {
    return 'invalid_activity_kind';
  }
  if (!optional(e.startUnixSeconds, instant) || !optional(e.endUnixSeconds, instant)
      || !optional(e.archivedAt, instant) || e.archived !== (e.archivedAt != null)) return 'invalid_time';
  if (!optional(e.durationMinutes, v => Number.isInteger(v) && Number(v) >= 1 && Number(v) <= 1440)) {
    return 'invalid_duration';
  }
  if (e.kind === 'event') {
    if (!isUuid(e.typeId)) return 'invalid_entry';
    if (!instant(e.startUnixSeconds) || e.startUnixSeconds < MIN_EVENT_START
        || (e.endUnixSeconds != null && e.endUnixSeconds < e.startUnixSeconds)) return 'invalid_time';
  }
  if (e.kind === 'preset' && (!Number.isInteger(e.durationMinutes)
      || e.durationMinutes < 1 || e.durationMinutes > 1440)) return 'invalid_duration';
  return new TextEncoder().encode(JSON.stringify(value)).length <= 16384 ? null : 'too_large';
}

export function validateManualEventRevision(value: unknown): boolean {
  return manualEventRevisionProblem(value) === null;
}

/**
 * `POST /manual-events {revisions: [...]}`: a malformed envelope is a 400; otherwise every revision is
 * judged on its own. Valid ones go to the append RPC (which also refuses a UUID that already holds other
 * content), and the reply names each revision as saved or rejected with a reason, so one bad revision can
 * never hold back the rest of the account's queue.
 */
export async function submitManualEvents(rest: Pick<SupabaseRest, 'rpc'>, userId: string, sourceId: string, body: unknown) {
  if (!object(body) || Object.keys(body).length !== 1 || !Array.isArray(body.revisions)
      || body.revisions.length < 1 || body.revisions.length > MANUAL_EVENTS_MAX_ITEMS) throw fail('invalid_manual_events');
  const valid: unknown[] = [];
  const rejected: { revision_id: string | null; reason: string }[] = [];
  for (const revision of body.revisions) {
    const problem = manualEventRevisionProblem(revision);
    if (problem === null) valid.push(revision);
    else rejected.push({ revision_id: object(revision) && isUuid(revision.revision_id) ? revision.revision_id : null, reason: problem });
  }
  let saved: unknown[] = [];
  if (valid.length > 0) {
    const result = await rest.rpc('append_manual_event_revisions', { p_user: userId, p_source: sourceId, p_items: valid });
    saved = Array.isArray(result?.saved) ? result.saved : [];
    if (Array.isArray(result?.rejected)) rejected.push(...result.rejected);
  }
  return { saved, rejected };
}

export async function readManualEvents(rest: Pick<SupabaseRest, 'select'>, userId: string, params: URLSearchParams) {
  if ([...params.keys()].some(k => k !== 'after')) throw fail('invalid_manual_events_query');
  const after = params.get('after') ?? '0';
  if (!/^\d{1,16}$/.test(after) || !Number.isSafeInteger(Number(after))) throw fail('invalid_manual_events_cursor');
  const rows = await rest.select('manual_event_revisions',
    `user_id=eq.${userId}&seq=gt.${after}&select=seq,body&order=seq.asc&limit=101`);
  const page = rows.slice(0, 100);
  return { revisions: page.map(r => r.body), next: String(page.at(-1)?.seq ?? after), has_more: rows.length > 100 };
}

/**
 * `GET /manual-events/context?ids=<uuid>,<uuid>`: the stored context of each of the caller's events, rebuilt
 * when it is older than five minutes and can still change. Ids the caller does not own are simply absent.
 */
export async function readManualEventContexts(rest: Pick<SupabaseRest, 'rpc'>, userId: string, params: URLSearchParams) {
  if ([...params.keys()].some(k => k !== 'ids')) throw fail('invalid_manual_event_context_query');
  const ids = (params.get('ids') ?? '').split(',').filter(id => id.length > 0);
  if (ids.length < 1 || ids.length > MANUAL_EVENT_CONTEXT_MAX_IDS || !ids.every(isUuid)) {
    throw fail('invalid_manual_event_context_query');
  }
  const result = await rest.rpc('manual_event_contexts_v1', {
    p_user: userId, p_ids: [...new Set(ids.map(id => id.toLowerCase()))], p_max_age_seconds: 300,
  });
  return { contexts: Array.isArray(result?.contexts) ? result.contexts : [] };
}
