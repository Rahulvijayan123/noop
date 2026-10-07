// In-memory stand-in for the coach's tables and RPCs (docs/COACH_MEMORY.md §2-§3) plus a scripted cheap model,
// for route-level tests of the `coach` function. It speaks enough PostgREST (eq/neq/gt/gte/lt/lte/in/is, not.,
// or=(…and(…)), fts, order with nulls, limit/offset, select projections, upsert on conflict, return=minimal) and
// fakes each RPC with a plain JS version of its contract: legacy thread resolution, tombstones, meta merge,
// thread stats triggers, lexical search, memory ranking with safety pins, the lease, and audited memory ops
// with the 200-row cap. The SQL itself is proven against Postgres in coach_threads_sql_test.ts.
import { type CoachConfig, coachConfig, handleCoachRequest } from '../_shared/coach.ts';
import { RestAuthorityError } from '../_shared/rest.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

export const USER = '11111111-1111-4111-8111-111111111111';
export const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';

const TS_COLUMNS = new Set([
  'created_at', 'updated_at', 'last_message_at', 'last_confirmed_at', 'summary_through', 'curated_through', 'summarized_at',
  'maintenance_until', 'retired_at', 'deleted_at', 'suggestions_at', 'consolidated_at', 'consolidation_until', 'memory_floor_at',
]);
const TS = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;

/** Microsecond sort key of a timestamp string. */
export function micros(v: unknown): number {
  if (typeof v !== 'string') return NaN;
  const ms = Date.parse(v);
  const frac = /:\d{2}\.(\d+)/.exec(v)?.[1] ?? '';
  return ms * 1000 + Number((frac + '000000').slice(3, 6));
}

/** PostgREST's rendering of a timestamptz: `2026-10-07T12:00:00.123456+00:00`, trailing zeros trimmed. */
export function pgTime(us: number): string {
  const ms = Math.floor(us / 1000);
  const base = new Date(ms).toISOString().slice(0, 19);
  const frac = `${String(ms % 1000).padStart(3, '0')}${String(us % 1000).padStart(3, '0')}`.replace(/0+$/, '');
  return `${base}${frac ? `.${frac}` : ''}+00:00`;
}

const normTs = (v: unknown) => (typeof v === 'string' && TS.test(v) && Number.isFinite(Date.parse(v)) ? pgTime(micros(v)) : v);

function restError(status: number, message = 'conflict'): Error {
  return Object.assign(new Error(`fake ${status} ${message}`), { status });
}

// ------------------------------------------------------------------------------------------------
// Lexemes: a rough english tsvector for the fake's full-text search
// ------------------------------------------------------------------------------------------------

const PG_STOP = new Set(['a', 'an', 'the', 'and', 'or', 'but', 'is', 'are', 'was', 'were', 'be', 'been', 'to', 'of', 'in', 'on', 'for',
  'with', 'at', 'by', 'from', 'my', 'i', 'me', 'we', 'you', 'it', 'this', 'that', 'what', 'how', 'did', 'do', 'does', 'about', 'as',
  'so', 'if', 'not', 'no', 'your', 'our', 'can', 'will', 'just', 'have', 'has', 'had', 'any', 'all', 'there', 'when', 'than', 'then']);

export function lexemes(text: unknown): Set<string> {
  const out = new Set<string>();
  for (const raw of String(text ?? '').toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []) {
    if (PG_STOP.has(raw)) continue;
    let w = raw;
    if (w.length > 5 && w.endsWith('ing')) w = w.slice(0, -3);
    else if (w.length > 4 && w.endsWith('ed')) w = w.slice(0, -2);
    else if (w.length > 4 && w.endsWith('es')) w = w.slice(0, -2);
    else if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) w = w.slice(0, -1);
    out.add(w);
  }
  return out;
}

function mark(content: string, terms: Set<string>): string {
  const words = content.replace(/\s+/g, ' ').trim().split(' ');
  const at = Math.max(0, words.findIndex((w) => [...lexemes(w)].some((l) => terms.has(l))));
  return words.slice(Math.max(0, at - 6), at + 20)
    .map((w) => ([...lexemes(w)].some((l) => terms.has(l)) ? `«${w}»` : w)).join(' ');
}

// ------------------------------------------------------------------------------------------------
// PostgREST query parsing
// ------------------------------------------------------------------------------------------------

type Cond = { col: string; op: string; value: string; not: boolean } | { logic: 'or' | 'and'; items: Cond[] };

function splitTop(s: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let quoted = false;
  let cur = '';
  for (const c of s) {
    if (c === '"') quoted = !quoted;
    if (!quoted && c === '(') depth++;
    if (!quoted && c === ')') depth--;
    if (!quoted && depth === 0 && c === ',') { out.push(cur); cur = ''; continue; }
    cur += c;
  }
  if (cur) out.push(cur);
  return out;
}

function parseCond(col: string, expr: string): Cond {
  let not = false;
  if (expr.startsWith('not.')) { not = true; expr = expr.slice(4); }
  const dot = expr.startsWith('fts(') ? expr.indexOf(').') + 1 : expr.indexOf('.');
  const op = expr.slice(0, dot);
  let value = expr.slice(dot + 1);
  if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
  return { col, op, value, not };
}

function parseLogic(kind: 'or' | 'and', body: string): Cond {
  const inner = body.replace(/^\(/, '').replace(/\)$/, '');
  return {
    logic: kind,
    items: splitTop(inner).map((item) => {
      const m = /^(or|and)\((.*)\)$/s.exec(item);
      if (m) return parseLogic(m[1] as 'or' | 'and', `(${m[2]})`);
      const dot = item.indexOf('.');
      return parseCond(item.slice(0, dot), item.slice(dot + 1));
    }),
  };
}

interface Query { conds: Cond[]; select?: string; order?: string; limit?: number; offset: number }

function parseQuery(q = ''): Query {
  const query: Query = { conds: [], offset: 0 };
  for (const [k, v] of new URLSearchParams(q)) {
    if (k === 'select') query.select = v;
    else if (k === 'order') query.order = v;
    else if (k === 'limit') query.limit = Number(v);
    else if (k === 'offset') query.offset = Number(v);
    else if (k === 'on_conflict') continue;
    else if (k === 'or' || k === 'and') query.conds.push(parseLogic(k, v));
    else query.conds.push(parseCond(k, v));
  }
  return query;
}

function compare(a: unknown, b: unknown): number | null {
  if (a == null || b == null) return null;
  if (typeof a === 'number' || typeof b === 'number') return Number(a) - Number(b);
  if (typeof a === 'boolean' || typeof b === 'boolean') return String(a) === String(b) ? 0 : String(a) < String(b) ? -1 : 1;
  const sa = String(a);
  const sb = String(b);
  if (TS.test(sa) && TS.test(sb)) return micros(sa) - micros(sb);
  return sa < sb ? -1 : sa > sb ? 1 : 0;
}

function searchText(table: string, row: any): string {
  if (table === 'coach_threads') return `${row.title ?? ''} ${row.summary ?? ''}`;
  if (table === 'coach_memory_items') return `${row.topic ?? ''} ${row.content ?? ''}`;
  return String(row.content ?? '');
}

function test(table: string, row: any, c: Cond): boolean {
  if ('logic' in c) return c.logic === 'or' ? c.items.some((i) => test(table, row, i)) : c.items.every((i) => test(table, row, i));
  const v = row[c.col];
  let ok: boolean;
  switch (c.op) {
    case 'eq': ok = compare(v, c.value) === 0 || String(v).toLowerCase() === c.value.toLowerCase(); break;
    case 'neq': ok = v != null && compare(v, c.value) !== 0; break;
    case 'gt': ok = (compare(v, c.value) ?? 0) > 0 && v != null; break;
    case 'gte': ok = v != null && (compare(v, c.value) ?? -1) >= 0; break;
    case 'lt': ok = v != null && (compare(v, c.value) ?? 0) < 0; break;
    case 'lte': ok = v != null && (compare(v, c.value) ?? 1) <= 0; break;
    case 'in': ok = c.value.replace(/^\(|\)$/g, '').split(',').map((x) => x.toLowerCase()).includes(String(v).toLowerCase()); break;
    case 'is': ok = c.value === 'null' ? v == null : v === (c.value === 'true'); break;
    case 'fts(english)': {
      const have = lexemes(searchText(table, row));
      const any = c.value.split(/\s*[|&]\s*/).flatMap((t) => [...lexemes(t)]);
      ok = c.value.includes('&') ? any.every((t) => have.has(t)) : any.some((t) => have.has(t));
      break;
    }
    default: throw new Error(`fake PostgREST: unsupported operator ${c.op}`);
  }
  return c.not ? !ok : ok;
}

function sortRows(rows: any[], order?: string): any[] {
  if (!order) return rows;
  const keys = order.split(',').map((o) => {
    const [col, dir = 'asc', nulls] = o.split('.');
    return { col, desc: dir === 'desc', nullsFirst: nulls ? nulls === 'nullsfirst' : dir === 'desc' };
  });
  return [...rows].sort((a, b) => {
    for (const k of keys) {
      const x = a[k.col];
      const y = b[k.col];
      if (x == null && y == null) continue;
      if (x == null) return k.nullsFirst ? -1 : 1;
      if (y == null) return k.nullsFirst ? 1 : -1;
      const c = compare(x, y) ?? 0;
      if (c !== 0) return k.desc ? -c : c;
    }
    return 0;
  });
}

function project(row: any, select?: string): any {
  if (!select || select === '*') return structuredClone(row);
  const out: any = {};
  for (const col of select.split(',')) out[col] = row[col] === undefined ? null : structuredClone(row[col]);
  return out;
}

const KEYS: Record<string, string[]> = {
  coach_threads: ['id'], coach_folders: ['id'], coach_messages: ['user_id', 'client_id'], coach_memory_items: ['id'],
  coach_memory_events: ['id'], coach_user_state: ['user_id'], coach_thread_tombstones: ['user_id', 'thread_id'], profiles: ['id'],
};

// ------------------------------------------------------------------------------------------------
// The fake database
// ------------------------------------------------------------------------------------------------

export class FakeCoachDb {
  /** Wall clock in ms; every default timestamp and lease check reads it. */
  clock = Date.UTC(2026, 9, 7, 12, 0, 0);
  /** Microseconds added to successive `now()` stamps so rows written in one tick still order. */
  private tick = 0;
  private eventSeq = 0;
  messageCap = 50_000;
  readonly usage = new Map<string, { calls: number; utility_calls: number; utility_tokens: number }>();
  readonly rpcCalls: { name: string; args: any }[] = [];
  /** Names of RPCs that throw, to exercise failure paths. */
  readonly failing = new Set<string>();

  constructor(readonly tables: Map<string, any[]> = new Map()) {}

  rows(table: string): any[] {
    if (!this.tables.has(table)) this.tables.set(table, []);
    return this.tables.get(table)!;
  }

  now(): string {
    return pgTime(this.clock * 1000 + (this.tick++ % 1000));
  }

  advance(ms: number): void { this.clock += ms; }

  private defaults(table: string): any {
    const now = this.now();
    switch (table) {
      case 'coach_threads': return {
        title: null, title_source: 'none', folder_id: null, pinned: false, origin: 'app', created_at: now, updated_at: now,
        last_message_at: null, message_count: 0, preview: null, summary: null, summary_topics: [], open_loops: [],
        summary_through: null, summary_messages: 0, curated_through: null, summarized_at: null, maintenance_token: null, maintenance_until: null,
      };
      case 'coach_folders': return { sort_order: 0, created_at: now, updated_at: now };
      case 'coach_messages': return { id: crypto.randomUUID(), meta: {}, thread_id: null, client_id: null, created_at: now };
      case 'coach_memory_items': return {
        id: crypto.randomUUID(), topic: 'general', importance: 3, created_at: now, updated_at: now, last_confirmed_at: now,
        confirmations: 1, source: 'tool', source_thread_id: null, version: 1, retired_at: null, retired_reason: null,
      };
      case 'coach_memory_events': return { id: ++this.eventSeq, created_at: now, before: null, after: null, thread_id: null, reason: null, tokens: null };
      case 'coach_user_state': return {
        suggestions: [], suggestions_fingerprint: null, suggestions_at: null, recent_searches: [], consolidated_at: null,
        consolidation_until: null, memory_revision: 0, memory_floor_at: null, updated_at: now,
      };
      case 'coach_thread_tombstones': return { deleted_at: now };
      default: return {};
    }
  }

  private normalise(table: string, row: any): any {
    for (const k of Object.keys(row)) if (TS_COLUMNS.has(k)) row[k] = normTs(row[k]);
    if (table === 'coach_messages') {
      const b = row.meta?.blocked;
      row.blocked = b === true || (typeof b === 'string' && ['true', 't', 'yes', 'y', 'on', '1'].includes(b.trim().toLowerCase()));
    }
    for (const k of ['id', 'user_id', 'thread_id', 'folder_id', 'client_id', 'source_thread_id']) {
      if (typeof row[k] === 'string') row[k] = row[k].toLowerCase();
    }
    return row;
  }

  private findKey(table: string, row: any): number {
    const keys = KEYS[table] ?? ['id'];
    return this.rows(table).findIndex((r) => keys.every((k) => r[k] != null && String(r[k]) === String(row[k])));
  }

  /** Foreign keys and triggers the routes rely on. */
  private check(table: string, row: any): void {
    if (table === 'coach_threads' && row.folder_id) {
      const folder = this.rows('coach_folders').find((f) => f.id === row.folder_id);
      if (folder && folder.user_id !== row.user_id) throw new RestAuthorityError(403, 'folder_not_owned');
      if (!folder) throw restError(409, 'folder fk');
    }
    if (table === 'coach_messages' && row.thread_id
        && !this.rows('coach_threads').some((t) => t.id === row.thread_id && t.user_id === row.user_id)) {
      throw restError(409, 'thread fk');
    }
  }

  // PostgREST surface -----------------------------------------------------------------------------

  select(table: string, q?: string): any[] {
    const query = parseQuery(q);
    let rows = this.rows(table).filter((r) => query.conds.every((c) => test(table, r, c)));
    rows = sortRows(rows, query.order);
    rows = rows.slice(query.offset, query.limit === undefined ? undefined : query.offset + query.limit);
    return rows.map((r) => project(r, query.select));
  }

  insert(table: string, body: any, q?: string): any[] {
    const out: any[] = [];
    for (const input of Array.isArray(body) ? body : [body]) {
      const row = this.normalise(table, { ...this.defaults(table), ...structuredClone(input) });
      if (this.findKey(table, row) >= 0) throw restError(409, 'duplicate key');
      this.check(table, row);
      this.rows(table).push(row);
      out.push(row);
    }
    if (table === 'coach_messages') this.refreshThreads(out.map((r) => r.thread_id));
    return out.map((r) => project(r, parseQuery(q).select));
  }

  upsert(table: string, body: any, opts: { onConflict?: string; prefer?: string } = {}): any[] | null {
    const out: any[] = [];
    for (const input of Array.isArray(body) ? body : [body]) {
      const incoming = this.normalise(table, structuredClone(input));
      const at = this.findKey(table, { ...this.defaults(table), ...incoming });
      if (at >= 0) {
        if (opts.prefer?.includes('ignore-duplicates')) continue;
        const merged = this.normalise(table, { ...this.rows(table)[at], ...incoming });
        this.check(table, merged);
        this.rows(table)[at] = merged;
        out.push(merged);
      } else {
        const row = this.normalise(table, { ...this.defaults(table), ...incoming });
        this.check(table, row);
        this.rows(table).push(row);
        out.push(row);
      }
    }
    if (table === 'coach_messages') this.refreshThreads(out.map((r) => r.thread_id));
    return opts.prefer?.includes('return=minimal') ? null : out.map((r) => structuredClone(r));
  }

  patch(table: string, body: any, q: string): any[] {
    const query = parseQuery(q);
    const out: any[] = [];
    const list = this.rows(table);
    list.forEach((r, i) => {
      if (!query.conds.every((c) => test(table, r, c))) return;
      const next = this.normalise(table, { ...r, ...structuredClone(body) });
      this.check(table, next);
      list[i] = next;
      out.push(next);
    });
    if (table === 'coach_messages') this.refreshThreads(out.map((r) => r.thread_id));
    return out.map((r) => project(r, query.select));
  }

  remove(table: string, q: string): any[] {
    const query = parseQuery(q);
    const gone = this.rows(table).filter((r) => query.conds.every((c) => test(table, r, c)));
    this.tables.set(table, this.rows(table).filter((r) => !gone.includes(r)));
    if (table === 'coach_threads') {
      // coach_messages (thread_id, user_id) → coach_threads on delete cascade.
      const keys = new Set(gone.map((t) => `${t.id}|${t.user_id}`));
      this.tables.set('coach_messages', this.rows('coach_messages').filter((m) => !keys.has(`${m.thread_id}|${m.user_id}`)));
    }
    if (table === 'coach_folders') {
      // coach_threads.folder_id on delete set null.
      const ids = new Set(gone.map((f) => f.id));
      for (const t of this.rows('coach_threads')) if (ids.has(t.folder_id)) t.folder_id = null;
    }
    if (table === 'coach_messages') this.refreshThreads(gone.map((r) => r.thread_id));
    return gone.map((r) => structuredClone(r));
  }

  /** internal.coach_messages_thread_stats. */
  refreshThreads(ids: (string | null)[]): void {
    for (const id of new Set(ids.filter((x): x is string => !!x))) {
      const thread = this.rows('coach_threads').find((t) => t.id === id);
      if (!thread) continue;
      const msgs = sortRows(this.rows('coach_messages').filter((m) => m.thread_id === id && m.user_id === thread.user_id),
        'created_at.desc,id.desc');
      thread.message_count = msgs.length;
      thread.last_message_at = msgs[0]?.created_at ?? null;
      thread.preview = msgs[0] ? String(msgs[0].content).replace(/\s+/g, ' ').trim().slice(0, 160) || null : null;
      thread.updated_at = this.now();
    }
  }

  // RPCs ---------------------------------------------------------------------------------------------

  rpc(name: string, args: any): any {
    this.rpcCalls.push({ name, args: structuredClone(args) });
    if (this.failing.has(name)) throw new Error(`relation "${name}" exploded with secret row content`);
    switch (name) {
      case 'coach_take_quota': return this.take(args.p_user_id, 'calls', 1, args.p_limit);
      case 'coach_take_utility_quota': return this.take(args.p_user_id, 'utility_calls', Math.max(1, args.p_units ?? 1), args.p_limit);
      case 'coach_add_utility_tokens': {
        this.usageOf(args.p_user_id).utility_tokens += Math.max(0, args.p_tokens ?? 0);
        return null;
      }
      case 'coach_messages_save_v1': return this.saveMessages(args.p_user, args.p_rows);
      case 'coach_search_v1': return this.search(args);
      case 'coach_memories_ranked_v1': return this.rankMemories(args.p_user, args.p_query, args.p_limit ?? 8, args.p_pin_safety ?? true);
      case 'coach_context_manifest_v1': return this.manifest(args.p_user, args.p_thread ?? null, args.p_query ?? null);
      case 'coach_thread_claim_v1': return this.claim(args.p_user, args.p_thread, args.p_lease_seconds ?? 120);
      case 'coach_thread_publish_v1': return this.publish(args.p_user, args.p_thread, args.p_token, args.p_patch, args.p_ops);
      case 'coach_memory_apply_v1': return this.applyOps(args.p_user, args.p_ops, args.p_actor, args.p_thread ?? null);
      case 'coach_consolidation_claim_v1': return this.claimConsolidation(args.p_user, args.p_lease_seconds ?? 120);
      default: throw new Error(`fake rpc ${name} not implemented`);
    }
  }

  private usageOf(user: string) {
    if (!this.usage.has(user)) this.usage.set(user, { calls: 0, utility_calls: 0, utility_tokens: 0 });
    return this.usage.get(user)!;
  }

  private take(user: string, key: 'calls' | 'utility_calls', units: number, limit: number): boolean {
    const u = this.usageOf(user);
    if (u[key] + units > limit) return false;
    u[key] += units;
    return true;
  }

  private state(user: string): any {
    let row = this.rows('coach_user_state').find((s) => s.user_id === user);
    if (!row) {
      row = this.normalise('coach_user_state', { ...this.defaults('coach_user_state'), user_id: user });
      this.rows('coach_user_state').push(row);
    }
    return row;
  }

  saveMessages(user: string, input: any[]): any {
    const rejected: any[] = [];
    const threads: any[] = [];
    const isId = (v: unknown) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
    const work: any[] = [];
    let legacy: string | null = null;
    let legacyLast = 0;
    const ordered = input.map((r, ord) => ({ r, ord })).sort((a, b) =>
      (micros(normTs(a.r?.created_at ?? this.now())) - micros(normTs(b.r?.created_at ?? this.now()))) || a.ord - b.ord);
    for (const { r, ord } of ordered) {
      if (!r || typeof r !== 'object' || !isId(r.client_id) || !['user', 'assistant'].includes(r.role) || typeof r.content !== 'string'
          || (r.thread_id != null && !isId(r.thread_id))) {
        rejected.push({ client_id: r?.client_id ?? null, reason: 'invalid_row' });
        continue;
      }
      const clientId = r.client_id.toLowerCase();
      const created = String(normTs(r.created_at ?? this.now()));
      let thread: string | null = r.thread_id ? r.thread_id.toLowerCase() : null;
      if (!thread) {
        thread = this.rows('coach_messages').find((m) => m.user_id === user && m.client_id === clientId)?.thread_id ?? null;
        if (!thread) {
          const t = micros(created) / 1000;
          if (legacy && Math.abs(t - legacyLast) <= 3 * 3_600_000) thread = legacy;
          else {
            const near = sortRows(this.rows('coach_threads').filter((x) => x.user_id === user && x.origin === 'legacy_client'
              && x.last_message_at && Math.abs(micros(x.last_message_at) / 1000 - t) <= 3 * 3_600_000), 'last_message_at.desc,id.asc')[0];
            thread = near?.id ?? crypto.randomUUID();
            legacy = thread;
            legacyLast = near ? micros(near.last_message_at) / 1000 : t;
          }
          legacyLast = Math.max(legacyLast, t);
        }
      }
      work.push({ ord, r, clientId, thread, legacy: !r.thread_id, created, title: r.thread_title ? String(r.thread_title).slice(0, 120) : null });
    }
    const status = new Map<string, string>();
    for (const thread of new Set(work.map((w) => w.thread))) {
      const group = work.filter((w) => w.thread === thread);
      if (this.rows('coach_thread_tombstones').some((t) => t.user_id === user && t.thread_id === thread)) {
        status.set(thread, 'thread_deleted');
        continue;
      }
      const existing = this.rows('coach_threads').find((t) => t.id === thread);
      const title = group.find((w) => w.title)?.title ?? null;
      if (!existing) {
        const first = group.map((w) => w.created).sort((a, b) => micros(a) - micros(b))[0];
        this.insert('coach_threads', {
          id: thread, user_id: user, title, title_source: title ? 'fallback' : 'none',
          origin: group.every((w) => w.legacy) ? 'legacy_client' : 'app', created_at: first,
        });
        status.set(thread, 'ok');
        threads.push({ id: thread, created: true });
        continue;
      }
      if (existing.user_id !== user) {
        status.set(thread, 'thread_conflict');
        continue;
      }
      if (title && existing.title == null && existing.title_source === 'none') Object.assign(existing, { title, title_source: 'fallback' });
      status.set(thread, 'ok');
      threads.push({ id: thread, created: false });
    }
    let saved = 0;
    for (const w of [...work].sort((a, b) => a.ord - b.ord)) {
      if (status.get(w.thread) !== 'ok') {
        rejected.push({ client_id: w.clientId, reason: status.get(w.thread) });
        continue;
      }
      const meta = w.r.meta && typeof w.r.meta === 'object' && !Array.isArray(w.r.meta) ? w.r.meta : {};
      const prior = this.rows('coach_messages').find((m) => m.user_id === user && m.client_id === w.clientId);
      if (prior) {
        const oldThread = prior.thread_id;
        Object.assign(prior, { content: w.r.content, role: w.r.role, meta: { ...prior.meta, ...meta }, thread_id: prior.thread_id ?? w.thread });
        this.normalise('coach_messages', prior);
        this.refreshThreads([oldThread, prior.thread_id]);
      } else {
        this.insert('coach_messages', { user_id: user, client_id: w.clientId, thread_id: w.thread, role: w.r.role, content: w.r.content, meta, created_at: w.created });
      }
      saved++;
    }
    const mine = sortRows(this.rows('coach_messages').filter((m) => m.user_id === user), 'created_at.desc,id.desc');
    if (mine.length > this.messageCap) {
      const drop = new Set(mine.slice(this.messageCap));
      const touched = [...drop].map((m) => m.thread_id);
      this.tables.set('coach_messages', this.rows('coach_messages').filter((m) => !drop.has(m)));
      this.refreshThreads(touched);
    }
    return { saved, rejected, threads };
  }

  search(a: any): any {
    const limit = Math.min(Math.max(a.p_limit ?? 20, 1), 50);
    const threadLimit = Math.min(Math.max(a.p_thread_limit ?? 8, 1), 30);
    const user = a.p_user;
    const terms = [...lexemes(a.p_query)].slice(0, 16);
    const inWindow = (at: string) => (!a.p_from || micros(at) >= micros(a.p_from)) && (!a.p_to || micros(at) < micros(a.p_to));
    const all = this.rows('coach_messages').filter((m) => m.user_id === user && !m.blocked && m.thread_id);
    const msgs = all.filter((m) => inWindow(m.created_at) && m.thread_id !== a.p_exclude_thread);
    const threadOf = (id: string) => this.rows('coach_threads').find((t) => t.id === id && t.user_id === user);
    if (!terms.length) {
      const last = new Map<string, string>();
      for (const m of msgs) if (!last.has(m.thread_id) || micros(m.created_at) > micros(last.get(m.thread_id)!)) last.set(m.thread_id, m.created_at);
      const top = [...last].sort((x, y) => micros(y[1]) - micros(x[1])).slice(0, threadLimit);
      return {
        terms: [], dropped_terms: [], total_hits: 0, months: [], hits: [],
        threads: top.map(([id]) => threadOf(id)).filter(Boolean).map((t: any) => ({
          thread_id: t.id, title: t.title, last_message_at: t.last_message_at, hits: 0, best_rank: 0, snippet: null,
          summary: t.summary ? String(t.summary).slice(0, 300) : null, topics: t.summary_topics ?? [],
        })),
      };
    }
    let kept = terms;
    let dropped: string[] = [];
    if (terms.length >= 2 && all.length >= 40) {
      const common = terms.filter((t) => all.filter((m) => lexemes(m.content).has(t)).length > 0.15 * all.length);
      if (common.length < terms.length) { kept = terms.filter((t) => !common.includes(t)); dropped = common; }
    }
    const keep = new Set(kept);
    const rank = (text: string, at: string) => {
      const have = lexemes(text);
      const n = kept.filter((t) => have.has(t)).length;
      const age = (this.clock - micros(at) / 1000) / 86_400_000;
      return n ? (n / 10) * (1 + 0.25 * Math.exp(-Math.max(age, 0) / 90)) : 0;
    };
    const matches = msgs.map((m) => ({ m, rank: rank(m.content, m.created_at) })).filter((x) => x.rank > 0);
    const byThread = new Map<string, { hits: number; best: number; bestMsg: any }>();
    for (const x of matches) {
      const g = byThread.get(x.m.thread_id) ?? { hits: 0, best: 0, bestMsg: null };
      g.hits++;
      if (x.rank > g.best) { g.best = x.rank; g.bestMsg = x.m; }
      byThread.set(x.m.thread_id, g);
    }
    for (const t of this.rows('coach_threads').filter((t) => t.user_id === user && t.message_count > 0 && t.id !== a.p_exclude_thread)) {
      const r = rank(`${t.title ?? ''} ${t.summary ?? ''}`, t.last_message_at ?? t.created_at);
      if (r > 0 && all.some((m) => m.thread_id === t.id) && (!a.p_from || micros(t.last_message_at) >= micros(a.p_from))
          && (!a.p_to || micros(t.created_at) < micros(a.p_to))) {
        const g = byThread.get(t.id) ?? { hits: 0, best: 0, bestMsg: null };
        g.best = Math.max(g.best, r);
        byThread.set(t.id, g);
      }
    }
    const top = [...byThread].map(([id, g]) => ({ id, ...g, t: threadOf(id) })).filter((x) => x.t)
      .sort((x, y) => (y.best * (1 + Math.log(Math.max(y.hits, 1)))) - (x.best * (1 + Math.log(Math.max(x.hits, 1))))
        || micros(y.t.last_message_at) - micros(x.t.last_message_at))
      .slice(0, threadLimit);
    const months = new Map<string, number>();
    for (const x of matches) months.set(x.m.created_at.slice(0, 7), (months.get(x.m.created_at.slice(0, 7)) ?? 0) + 1);
    return {
      terms: kept, dropped_terms: dropped, total_hits: matches.length,
      months: [...months].sort().map(([month, hits]) => ({ month, hits })),
      hits: [...matches].sort((x, y) => (y.rank - x.rank) || micros(y.m.created_at) - micros(x.m.created_at)).slice(0, limit).map((x) => ({
        thread_id: x.m.thread_id, message_id: x.m.id, role: x.m.role, created_at: x.m.created_at, rank: x.rank, snippet: mark(x.m.content, keep),
      })),
      threads: top.map((x) => ({
        thread_id: x.id, title: x.t.title, last_message_at: x.t.last_message_at, hits: x.hits, best_rank: x.best,
        snippet: x.bestMsg ? mark(x.bestMsg.content, keep) : mark(`${x.t.summary ?? x.t.title ?? ''}`, keep),
        summary: x.t.summary ? String(x.t.summary).slice(0, 300) : null, topics: x.t.summary_topics ?? [],
      })),
    };
  }

  rankMemories(user: string, query: string | null, limitIn: number, pinSafety: boolean): any {
    const limit = Math.min(Math.max(limitIn, 1), 200);
    const active = this.rows('coach_memory_items').filter((m) => m.user_id === user && m.retired_at == null);
    const pins = pinSafety
      ? sortRows(active.filter((m) => ['injury', 'health'].includes(m.topic) && m.importance >= 4), 'importance.desc,last_confirmed_at.desc').slice(0, Math.min(3, limit))
      : [];
    const q = lexemes(query ?? '');
    const lex = (m: any) => { const have = lexemes(`${m.topic} ${m.content}`); return [...q].filter((t) => have.has(t)).length; };
    const rest = active.filter((m) => !pins.includes(m));
    const maxLex = Math.max(0, ...rest.map(lex));
    const score = (m: any) => 3 * (maxLex ? lex(m) / maxLex : 0) + m.importance / 5
      + 0.5 * Math.exp(-Math.max(0, this.clock - micros(m.last_confirmed_at) / 1000) / 86_400_000 / 120) + 0.2 * Math.log(1 + m.confirmations);
    const ranked = [...rest].sort((a, b) => (score(b) - score(a)) || micros(b.last_confirmed_at) - micros(a.last_confirmed_at)).slice(0, Math.max(0, limit - pins.length));
    const topics: Record<string, number> = {};
    for (const m of active) topics[m.topic] = (topics[m.topic] ?? 0) + 1;
    const shape = (m: any, pinned: boolean) => ({
      id: m.id, content: m.content, topic: m.topic, importance: m.importance, created_at: m.created_at, updated_at: m.updated_at,
      source: m.source, confirmations: m.confirmations, pinned,
    });
    return { memories: [...pins.map((m) => shape(m, true)), ...ranked.map((m) => shape(m, false))], total: active.length, topics };
  }

  manifest(user: string, threadId: string | null, query: string | null): any {
    const ranked = this.rankMemories(user, query, 8, true);
    const t = threadId ? this.rows('coach_threads').find((x) => x.id === threadId && x.user_id === user) : null;
    const nonEmpty = this.rows('coach_threads').filter((x) => x.user_id === user && x.message_count > 0);
    const others = sortRows(nonEmpty.filter((x) => x.id !== threadId), 'last_message_at.desc.nullslast,id.asc');
    const relevant = lexemes(query ?? '').size
      ? this.search({ p_user: user, p_query: query, p_limit: 1, p_thread_limit: 3, p_exclude_thread: threadId }).threads
        .map((x: any) => ({ id: x.thread_id, title: x.title, last_message_at: x.last_message_at, snippet: x.snippet }))
      : [];
    const weekAgo = this.clock - 7 * 86_400_000;
    const loops = sortRows(nonEmpty.filter((x) => x.id !== threadId && x.summarized_at && micros(x.summarized_at) / 1000 >= weekAgo), 'summarized_at.desc')
      .flatMap((x) => (x.open_loops ?? []).map((l: any) => ({ thread_id: x.id, title: x.title, text: typeof l === 'string' ? l : l?.text })))
      .filter((l: any) => l.text).slice(0, 3);
    return {
      memories: ranked.memories, memory_count: ranked.total, memory_topics: ranked.topics,
      thread: t ? {
        id: t.id, title: t.title, summary: t.summary, summary_through: t.summary_through, summary_messages: t.summary_messages,
        message_count: t.message_count, open_loops: t.open_loops,
      } : null,
      library: {
        thread_count: nonEmpty.length,
        first_at: sortRows(nonEmpty, 'created_at.asc')[0]?.created_at ?? null,
        last_at: sortRows(nonEmpty, 'last_message_at.desc')[0]?.last_message_at ?? null,
        recent: others.slice(0, 5).map((x) => ({ id: x.id, title: x.title, last_message_at: x.last_message_at })),
        relevant,
      },
      open_loops: loops,
      memory_revision: this.rows('coach_user_state').find((s) => s.user_id === user)?.memory_revision ?? 0,
    };
  }

  claim(user: string, threadId: string, lease: number): any {
    const t = this.rows('coach_threads').find((x) => x.id === threadId && x.user_id === user);
    if (!t || (t.maintenance_until && micros(t.maintenance_until) / 1000 > this.clock)) return { claimed: false };
    t.maintenance_token = crypto.randomUUID();
    t.maintenance_until = pgTime((this.clock + lease * 1000) * 1000);
    return {
      claimed: true, token: t.maintenance_token, summary: t.summary, summary_through: t.summary_through,
      summary_messages: t.summary_messages, curated_through: t.curated_through, message_count: t.message_count, title: t.title,
      title_source: t.title_source, memory_floor_at: this.rows('coach_user_state').find((s) => s.user_id === user)?.memory_floor_at ?? null,
    };
  }

  publish(user: string, threadId: string, token: string, patch: any, ops: any[]): any {
    const t = this.rows('coach_threads').find((x) => x.id === threadId && x.user_id === user);
    if (!t || !token || t.maintenance_token !== token || !t.maintenance_until || micros(t.maintenance_until) / 1000 <= this.clock) {
      return { applied: false, reason: 'lease_lost', ops: [] };
    }
    const allowed = ['summary', 'summary_topics', 'open_loops', 'summary_through', 'summary_messages', 'curated_through', 'summarized_at'];
    for (const k of allowed) if (patch && k in patch) t[k] = TS_COLUMNS.has(k) ? normTs(patch[k]) : structuredClone(patch[k]);
    t.maintenance_token = null;
    t.maintenance_until = null;
    return { applied: true, reason: 'published', ops: Array.isArray(ops) && ops.length ? this.applyOps(user, ops, 'curator', threadId) : [] };
  }

  private event(user: string, memoryId: string | null, op: string, actor: string, extra: any = {}): void {
    this.rows('coach_memory_events').push({ ...this.defaults('coach_memory_events'), user_id: user, memory_id: memoryId, op, actor, ...extra });
  }

  private revises = (m: any) => m && m.importance >= 4 && ['goal', 'injury', 'health', 'training'].includes(m.topic);

  applyOps(user: string, ops: any[], actor: string, threadId: string | null): any[] {
    if (!['tool', 'curator', 'user', 'consolidator'].includes(actor)) throw new Error('invalid_actor');
    const state = this.state(user);
    const results: any[] = [];
    let bump = false;
    const items = () => this.rows('coach_memory_items');
    const topic = (v: unknown) => {
      const t = String(v ?? '').trim().toLowerCase();
      return ['goal', 'injury', 'preference', 'achievement', 'lifestyle', 'routine', 'health', 'training', 'nutrition', 'sleep', 'general'].includes(t) ? t : 'general';
    };
    const imp = (v: unknown, d: number) => (Number.isFinite(Number(v)) && v != null ? Math.max(1, Math.min(5, Math.round(Number(v)))) : d);
    const content = (v: unknown) => (typeof v === 'string' && v.trim().length >= 1 && v.trim().length <= 500 ? v.trim() : null);
    const tokensOf = (m: any, op: any) => (Array.isArray(op.tokens) ? op.tokens.slice(0, 64) : [...lexemes(m.content)]);
    for (const op of ops) {
      const kind = op?.op;
      const id = op?.id ?? op?.keep_id;
      const now = this.now();
      if (kind === 'add') {
        const text = content(op.content);
        if (!text) { results.push({ op: 'add', id: null, applied: false, reason: 'invalid_content' }); continue; }
        const row = this.normalise('coach_memory_items', {
          ...this.defaults('coach_memory_items'), user_id: user, content: text, topic: topic(op.topic), importance: imp(op.importance, 3),
          source: ['tool', 'curator', 'user', 'legacy'].includes(op.source) ? op.source : actor === 'consolidator' ? 'curator' : actor,
          source_thread_id: threadId,
        });
        items().push(row);
        this.event(user, row.id, 'add', actor, { after: structuredClone(row), thread_id: threadId });
        bump ||= this.revises(row);
        results.push({ op: 'add', id: row.id, applied: true });
      } else if (['update', 'confirm', 'retire', 'forget'].includes(kind)) {
        const row = items().find((m) => m.id === id && m.user_id === user);
        if (!row) { results.push({ op: kind, id, applied: false, reason: 'not_found' }); continue; }
        if (row.retired_at && kind !== 'forget') { results.push({ op: kind, id, applied: false, reason: 'retired' }); continue; }
        const before = structuredClone(row);
        if (kind === 'update') {
          const text = typeof op.content === 'string' ? content(op.content) : row.content;
          if (!text) { results.push({ op: 'update', id, applied: false, reason: 'invalid_content' }); continue; }
          Object.assign(row, {
            content: text, topic: typeof op.topic === 'string' ? topic(op.topic) : row.topic, importance: imp(op.importance, row.importance),
            version: row.version + 1, updated_at: now, last_confirmed_at: now,
          });
          this.event(user, id, 'update', actor, { before, after: structuredClone(row), thread_id: threadId });
          bump ||= this.revises(before) || this.revises(row);
        } else if (kind === 'confirm') {
          Object.assign(row, { confirmations: row.confirmations + 1, last_confirmed_at: now });
          this.event(user, id, 'confirm', actor, { thread_id: threadId });
        } else if (kind === 'retire') {
          Object.assign(row, { retired_at: now, retired_reason: String(op.reason || 'retired').slice(0, 300) });
          this.event(user, id, 'retire', actor, { before, thread_id: threadId, reason: row.retired_reason, tokens: tokensOf(before, op) });
          bump ||= this.revises(before);
        } else {
          this.tables.set('coach_memory_items', items().filter((m) => m !== row));
          for (const e of this.rows('coach_memory_events')) if (e.memory_id === id) { delete e.before?.content; delete e.after?.content; }
          this.event(user, id, 'forget', actor, { thread_id: threadId, tokens: tokensOf(before, op), reason: op.reason ?? null });
          bump ||= this.revises(before);
        }
        results.push({ op: kind, id, applied: true });
      } else if (kind === 'merge') {
        const keep = items().find((m) => m.id === id && m.user_id === user && !m.retired_at);
        const others = items().filter((m) => m.user_id === user && !m.retired_at && m.id !== id && (op.ids ?? []).includes(m.id));
        if (!keep || !others.length) { results.push({ op: 'merge', id, applied: false, reason: keep ? 'nothing_to_merge' : 'not_found' }); continue; }
        const before = structuredClone(keep);
        Object.assign(keep, {
          content: content(op.content) ?? keep.content, topic: typeof op.topic === 'string' ? topic(op.topic) : keep.topic,
          importance: imp(op.importance, keep.importance), confirmations: keep.confirmations + others.reduce((n, m) => n + m.confirmations, 0),
          version: keep.version + 1, updated_at: now,
        });
        this.event(user, id, 'merge', actor, { before, after: { ...structuredClone(keep), merged_ids: others.map((m) => m.id) } });
        for (const m of others) {
          Object.assign(m, { retired_at: now, retired_reason: 'merged' });
          this.event(user, m.id, 'merge', actor, { reason: 'merged' });
        }
        bump ||= [before, keep, ...others].some(this.revises);
        results.push({ op: 'merge', id, applied: true });
      } else if (kind === 'forget_all') {
        for (const m of items().filter((x) => x.user_id === user)) {
          this.event(user, m.id, 'forget', actor, { tokens: [...lexemes(m.content)], reason: 'forget_all' });
        }
        this.tables.set('coach_memory_items', items().filter((m) => m.user_id !== user));
        Object.assign(state, { memory_floor_at: now, recent_searches: [], suggestions: [], suggestions_fingerprint: null, suggestions_at: null });
        bump = true;
        results.push({ op: 'forget_all', id: null, applied: true });
      } else if (kind === 'consolidated') {
        Object.assign(state, { consolidated_at: now, consolidation_until: null });
        results.push({ op: 'consolidated', id: null, applied: true });
      } else {
        results.push({ op: kind, id, applied: false, reason: 'unknown_op' });
      }
    }
    const active = items().filter((m) => m.user_id === user && !m.retired_at);
    if (active.length > 200) {
      const score = (m: any) => m.importance / 5 + 0.5 * Math.exp(-Math.max(0, this.clock - micros(m.last_confirmed_at) / 1000) / 86_400_000 / 120)
        + 0.2 * Math.log(1 + m.confirmations);
      const victims = [...active].sort((a, b) => (score(a) - score(b)) || micros(a.last_confirmed_at) - micros(b.last_confirmed_at)
        || micros(a.created_at) - micros(b.created_at) || String(a.id).localeCompare(String(b.id))).slice(0, active.length - 200);
      for (const v of victims) {
        Object.assign(v, { retired_at: this.now(), retired_reason: 'evict' });
        this.event(user, v.id, 'evict', actor, { reason: 'cap' });
        bump ||= this.revises(v);
        results.push({ op: 'evict', id: v.id, applied: true, reason: 'cap' });
      }
    }
    const month = this.clock - 30 * 86_400_000;
    this.tables.set('coach_memory_items', items().filter((m) => !(m.user_id === user && m.retired_at && micros(m.retired_at) / 1000 < month)));
    if (bump) state.memory_revision += 1;
    return results;
  }

  claimConsolidation(user: string, lease: number): boolean {
    const state = this.state(user);
    const active = this.rows('coach_memory_items').filter((m) => m.user_id === user && !m.retired_at).length;
    const free = !state.consolidation_until || micros(state.consolidation_until) / 1000 <= this.clock;
    const due = active > 120 || (active > 40 && (!state.consolidated_at || micros(state.consolidated_at) / 1000 < this.clock - 72 * 3_600_000));
    if (!free || !due) return false;
    state.consolidation_until = pgTime((this.clock + lease * 1000) * 1000);
    return true;
  }

  // Seeding helpers --------------------------------------------------------------------------------

  thread(user: string, over: Record<string, unknown> = {}): any {
    return this.insert('coach_threads', { id: crypto.randomUUID(), user_id: user, ...over })[0];
  }

  message(user: string, threadId: string, role: 'user' | 'assistant', content: string, over: Record<string, unknown> = {}): any {
    return this.insert('coach_messages', { user_id: user, thread_id: threadId, client_id: crypto.randomUUID(), role, content, ...over })[0];
  }

  memory(user: string, content: string, over: Record<string, unknown> = {}): any {
    return this.insert('coach_memory_items', { user_id: user, content, source: 'tool', ...over })[0];
  }

  threadRow(id: string): any { return this.rows('coach_threads').find((t) => t.id === id); }
  activeMemories(user = USER): any[] { return this.rows('coach_memory_items').filter((m) => m.user_id === user && !m.retired_at); }
}

/** A PostgREST-shaped client over the fake db for the coach tables, and helpers.ts' fake for the auth tables. */
export function fakeRest(db: FakeCoachDb, coachTables: (table: string) => boolean = (t) => t.startsWith('coach_') || t === 'profiles') {
  const base = makeMemRest() as any;
  const route = (path: string) => path.split('?')[0];
  const rest = {
    configured: true,
    base,
    async select(table: string, q?: string) { return coachTables(table) ? db.select(table, q) : base.select(table, q); },
    async request(path: string, opts: any = {}) {
      const table = route(path);
      if (!coachTables(table)) return base.request(path, opts);
      const method = opts.method ?? 'GET';
      if (method === 'POST') return db.insert(table, opts.body, opts.query);
      if (method === 'PATCH') return db.patch(table, opts.body, opts.query ?? '');
      if (method === 'DELETE') return db.remove(table, opts.query ?? '');
      return db.select(table, opts.query);
    },
    async upsert(table: string, rows: any, opts: any = {}) { return coachTables(table) ? db.upsert(table, rows, opts) : base.upsert(table, rows, opts); },
    async patch(table: string, body: any, q: string) { return coachTables(table) ? db.patch(table, body, q) : base.patch(table, body, q); },
    async delete(table: string, q: string) { return coachTables(table) ? db.remove(table, q) : base.delete(table, q); },
    async rpc(name: string, args: any) { return name.startsWith('coach_') ? db.rpc(name, args) : base.rpc(name, args); },
  };
  return rest;
}

export async function seedIdentities(base: any): Promise<void> {
  await base.upsert('noop_ingest_tokens', [
    { id: 'personal', token_hash: hashIngestToken('noop_personal'), token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE },
    { id: 'other', token_hash: hashIngestToken('noop_other'), token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: OTHER, source_id: OTHER_SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
  ]);
  await base.upsert('noop_app_installations', [{ user_id: USER, source_id: SOURCE }, { user_id: OTHER, source_id: OTHER_SOURCE }]);
}

// ------------------------------------------------------------------------------------------------
// The scripted cheap model
// ------------------------------------------------------------------------------------------------

export type Pass = 'title' | 'followups' | 'suggestions' | 'map' | 'reduce' | 'curator' | 'consolidation';

/** Which pass a request is, from its system prompt. */
export function passOf(system: string): Pass | null {
  if (/You name chats/.test(system)) return 'title';
  if (/what the user might ask Sana/.test(system)) return 'followups';
  if (/conversation starters/.test(system)) return 'suggestions';
  if (/pull out what bears on a question/.test(system)) return 'map';
  if (/merge notes/.test(system)) return 'reduce';
  if (/maintain the running summary/.test(system)) return 'curator';
  if (/tidy a user's long-term memory/.test(system)) return 'consolidation';
  return null;
}

export interface ModelCall { pass: Pass | null; body: any; system: string; user: string; authorization: string | null; startedAt: number }

/** A reply with transport options; a plain object is sent as the JSON content. */
export interface Scripted { __scripted: true; json?: unknown; content?: string; delayMs?: number; status?: number; finish?: string; tokens?: number }
export const reply = (json: unknown, opts: Omit<Scripted, '__scripted' | 'json'> = {}): Scripted => ({ __scripted: true, json, ...opts });

type Handler = unknown | ((call: ModelCall) => unknown | Promise<unknown>);

function sleep(ms: number, signal?: AbortSignal | null): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(signal.reason);
    const t = setTimeout(resolve, ms);
    signal?.addEventListener('abort', () => { clearTimeout(t); reject(signal.reason ?? new DOMException('aborted', 'AbortError')); }, { once: true });
  });
}

export function fakeModel(script: Partial<Record<Pass, Handler>> = {}) {
  const calls: ModelCall[] = [];
  const stats = { inFlight: 0, maxInFlight: 0 };
  const fetchImpl = (async (_url: string, init: any) => {
    const body = JSON.parse(init.body);
    const system = body.messages?.find((m: any) => m.role === 'system')?.content ?? '';
    const user = body.messages?.find((m: any) => m.role === 'user')?.content ?? '';
    const call: ModelCall = { pass: passOf(system), body, system, user, authorization: new Headers(init.headers).get('authorization'), startedAt: performance.now() };
    calls.push(call);
    stats.inFlight++;
    stats.maxInFlight = Math.max(stats.maxInFlight, stats.inFlight);
    try {
      const handler = call.pass ? script[call.pass] : undefined;
      const out = typeof handler === 'function' ? await (handler as (c: ModelCall) => unknown)(call) : handler;
      if (out === undefined) return new Response('{"error":"no script for this prompt"}', { status: 500 });
      if (out instanceof Error) throw out;
      const r: Scripted = (out as any)?.__scripted ? out as Scripted : { __scripted: true, json: out };
      if (r.delayMs) await sleep(r.delayMs, init.signal);
      if (r.status) return new Response('{"error":"upstream echoed the secret prompt"}', { status: r.status });
      const content = r.content ?? JSON.stringify(r.json);
      return Response.json({ choices: [{ message: { content }, finish_reason: r.finish ?? 'stop' }], usage: { total_tokens: r.tokens ?? 120 } });
    } finally {
      stats.inFlight--;
    }
  }) as typeof fetch;
  const of = (pass: Pass) => calls.filter((c) => c.pass === pass);
  return { fetchImpl, calls, stats, of };
}

// ------------------------------------------------------------------------------------------------
// A ready harness
// ------------------------------------------------------------------------------------------------

export function coachRequest(path: string, { method = 'GET', body, token = 'noop_personal', raw }: { method?: string; body?: unknown; token?: string; raw?: string } = {}) {
  const headers: Record<string, string> = { 'content-type': 'application/json', authorization: `Bearer ${token}`, 'x-noop-fleet-token': 'noop_fleet' };
  return new Request(`https://test.invalid/functions/v1/coach/${path}`, {
    method, headers, body: raw ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
}

export interface Harness {
  db: FakeCoachDb;
  rest: ReturnType<typeof fakeRest>;
  model: ReturnType<typeof fakeModel>;
  cfg: CoachConfig;
  deps: Parameters<typeof handleCoachRequest>[1];
  send: (path: string, init?: Parameters<typeof coachRequest>[1]) => Promise<Response>;
  json: (path: string, init?: Parameters<typeof coachRequest>[1]) => Promise<{ status: number; body: any }>;
}

/** A coach function over a fresh fake db and a scripted model; maintenance runs inline. */
export async function harness(script: Partial<Record<Pass, unknown>> = {}, env: Record<string, string> = {},
  over: Partial<Harness['deps']> = {}): Promise<Harness> {
  const db = new FakeCoachDb();
  const rest = fakeRest(db);
  await seedIdentities(rest.base);
  const model = fakeModel(script);
  const cfg = coachConfig({ FIREWORKS_AI_API_KEY: 'fw-test-key', NOOP_ALLOW_LEGACY_ENROLLMENT: 'true', ...env });
  const deps = { rest: rest as any, cfg, fetchImpl: model.fetchImpl, now: () => db.clock, background: null, timeScale: 1, ...over };
  const send = (path: string, init?: Parameters<typeof coachRequest>[1]) => handleCoachRequest(coachRequest(path, init), deps);
  const json = async (path: string, init?: Parameters<typeof coachRequest>[1]) => {
    const res = await send(path, init);
    return { status: res.status, body: await res.json() };
  };
  return { db, rest, model, cfg, deps, send, json };
}

/** Every uuid in a string (prompts must have none). */
export const uuidsIn = (s: string) => s.match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi) ?? [];
