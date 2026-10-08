// Shared plumbing for Sana's threads, memory and context modules (docs/COACH_MEMORY.md §5 and §6).
//
// - `callUtility`: every cheap-model pass (titles, follow-ups, starters, recall map/reduce, curator,
//   consolidation). It takes the utility quota first, bounds tokens and time per pass, treats a truncated
//   reply as a failure, records token usage, and never logs or returns prompt or reply text on failure.
// - The deterministic rules the model output is held to: normalised tokens that keep numbers and dates,
//   jaccard/containment near-duplicates within a topic family, and the curator guards.
// - Small request helpers the route modules share (errors, bounded JSON bodies, ISO timestamps, short refs).
import { isUuid } from './keys.ts';
import type { SupabaseRest } from './rest.ts';
import type { CoachConfig } from './coach.ts';

export interface CoachDeps {
  rest: SupabaseRest;
  cfg: CoachConfig;
  fetchImpl: typeof fetch;
  /** Wall clock in milliseconds. */
  now: () => number;
  /** Runs work after the response (EdgeRuntime.waitUntil); null runs it inline before answering. */
  background: ((work: Promise<unknown>) => void) | null;
  /** Multiplies every model timeout and the recall deadline (1 in production; tests shrink it). */
  timeScale: number;
}

// ------------------------------------------------------------------------------------------------
// Request helpers
// ------------------------------------------------------------------------------------------------

export function fail(code: string, status: number): Error {
  return Object.assign(new Error(code), { code, status });
}

export const isObject = (v: unknown): v is Record<string, any> => !!v && typeof v === 'object' && !Array.isArray(v);

export const SMALL_BODY_BYTES = 256_000;

export async function readJson(req: Request, maxBytes = 6_000_000): Promise<any> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > maxBytes) throw fail('payload_too_large', 413);
  try { return JSON.parse(new TextDecoder().decode(bytes)); }
  catch { throw fail('invalid_body', 400); }
}

/** A body that may be empty (`{}` is implied). */
export async function readOptionalJson(req: Request, maxBytes = SMALL_BODY_BYTES): Promise<Record<string, any>> {
  const bytes = new Uint8Array(await req.arrayBuffer());
  if (bytes.length > maxBytes) throw fail('payload_too_large', 413);
  const raw = new TextDecoder().decode(bytes).trim();
  if (!raw) return {};
  let body: unknown;
  try { body = JSON.parse(raw); } catch { throw fail('invalid_body', 400); }
  if (!isObject(body)) throw fail('invalid_body', 400);
  return body;
}

/** Whitespace collapsed to single spaces and trimmed; '' for anything that is not a string. */
export function collapse(v: unknown): string {
  return typeof v === 'string' ? v.replace(/\s+/g, ' ').trim() : '';
}

/** At most `max` characters, cut at a word boundary when one is close, with an ellipsis when cut. */
export function clip(s: string, max: number): string {
  if (s.length <= max) return s;
  const head = s.slice(0, Math.max(1, max - 1));
  const space = head.lastIndexOf(' ');
  return `${(space > max * 0.6 ? head.slice(0, space) : head).trimEnd()}…`;
}

export function clampInt(v: unknown, min: number, max: number, fallback: number): number {
  const n = typeof v === 'string' && v.trim() ? Number(v) : typeof v === 'number' ? v : NaN;
  return Number.isFinite(n) ? Math.max(min, Math.min(max, Math.trunc(n))) : fallback;
}

/** A lowercased uuid, or null. */
export function uuidOf(v: unknown): string | null {
  return typeof v === 'string' && isUuid(v) ? v.toLowerCase() : null;
}

export const enc = encodeURIComponent;

/** A PostgREST filter value inside `or=(…)`, double-quoted so timestamps and ids parse as one value. */
export const quoted = (v: string) => `"${String(v).replace(/["\\]/g, '')}"`;

/** `Date#toISOString()` of a database timestamp, or null. */
export function iso(v: unknown): string | null {
  if (typeof v !== 'string' && typeof v !== 'number') return null;
  const t = typeof v === 'number' ? v : Date.parse(v);
  return Number.isFinite(t) ? new Date(t).toISOString() : null;
}

/** Sort key with the microseconds PostgREST timestamps carry ("…12:00:00.123456+00:00"); NaN when unparseable. */
export function tsKey(v: unknown): number {
  if (typeof v !== 'string') return NaN;
  const ms = Date.parse(v);
  if (!Number.isFinite(ms)) return NaN;
  const frac = /T\d{2}:\d{2}:\d{2}\.(\d+)/.exec(v)?.[1] ?? '';
  return ms * 1000 + Number((frac + '000000').slice(3, 6));
}

/** `YYYY-MM-DD` (UTC) of a timestamp, or ''. */
export function day(v: unknown): string {
  return iso(v)?.slice(0, 10) ?? '';
}

/**
 * A client-supplied window bound as an ISO timestamp. A bare date is the start of that UTC day; with
 * `endOfDay` it is the start of the next one, so `to: "2026-08-31"` includes the 31st.
 */
export function windowBound(v: unknown, endOfDay = false): string | null {
  if (typeof v !== 'string' || v.length > 40) return null;
  const s = v.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    const t = Date.parse(`${s}T00:00:00Z`);
    if (!Number.isFinite(t) || new Date(t).toISOString().slice(0, 10) !== s) return null;
    return new Date(t + (endOfDay ? 86_400_000 : 0)).toISOString();
  }
  return iso(s);
}

const LOCALE = /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$/;

/** A BCP-47 tag, default `en`. */
export function cleanLocale(v: unknown): string {
  const s = typeof v === 'string' ? v.trim().replace(/_/g, '-') : '';
  return s.length <= 35 && LOCALE.test(s) ? s : 'en';
}

/** The English name of the locale's language for prompts ("Spanish"), or the tag itself. */
export function languageName(locale: string): string {
  try {
    return new Intl.DisplayNames(['en'], { type: 'language' }).of(locale.split('-')[0]) ?? locale;
  } catch {
    return locale;
  }
}

/** Short references for prompts (`m1`, `t2`, `c3`): models never see uuids, the server maps them back. */
export class Refs {
  private readonly byRef = new Map<string, string>();
  private readonly byId = new Map<string, string>();
  constructor(private readonly prefix: string) {}

  ref(id: string): string {
    let r = this.byId.get(id);
    if (!r) {
      r = `${this.prefix}${this.byId.size + 1}`;
      this.byId.set(id, r);
      this.byRef.set(r, id);
    }
    return r;
  }

  resolve(ref: unknown): string | undefined {
    if (typeof ref !== 'string') return undefined;
    const m = /^\[?\s*([a-z])\s*(\d{1,3})\s*\]?$/i.exec(ref.trim());
    return m && m[1].toLowerCase() === this.prefix ? this.byRef.get(`${this.prefix}${Number(m[2])}`) : undefined;
  }

  get size(): number { return this.byId.size; }
}

// ------------------------------------------------------------------------------------------------
// The cheap model (§5)
// ------------------------------------------------------------------------------------------------

export type UtilityPass = 'title' | 'followups' | 'suggestions' | 'map' | 'reduce' | 'curator' | 'consolidation';

export const UTILITY_PASSES: Record<UtilityPass, { maxTokens: number; timeoutMs: number; temperature: number }> = {
  title: { maxTokens: 60, timeoutMs: 6_000, temperature: 0.3 },
  followups: { maxTokens: 260, timeoutMs: 8_000, temperature: 0.6 },
  suggestions: { maxTokens: 360, timeoutMs: 9_000, temperature: 0.7 },
  map: { maxTokens: 450, timeoutMs: 9_000, temperature: 0 },
  reduce: { maxTokens: 600, timeoutMs: 5_000, temperature: 0.1 },
  curator: { maxTokens: 1_400, timeoutMs: 15_000, temperature: 0.1 },
  consolidation: { maxTokens: 2_400, timeoutMs: 20_000, temperature: 0 },
};

export type ChatTurn = { role: 'system' | 'user'; content: string };

/** True when a cheap-model key is configured at all; without one every pass takes its deterministic fallback. */
export const utilityConfigured = (d: CoachDeps) => Boolean(d.cfg.utilityKey || d.cfg.fireworksKey);

/** Takes `units` of the owner's daily utility budget atomically. Any failure reads as "no budget". */
export async function takeUtilityUnits(d: CoachDeps, userId: string, units = 1): Promise<boolean> {
  try {
    return (await d.rest.rpc('coach_take_utility_quota', {
      p_user_id: userId, p_limit: d.cfg.dailyUtilityLimit, p_units: Math.max(1, Math.trunc(units)),
    })) === true;
  } catch {
    return false;
  }
}

/**
 * One cheap-model pass. Returns the parsed JSON object, or null on any failure (no key, no budget, timeout,
 * HTTP error, truncated reply, unparseable reply); the caller then falls back. `prepaid` skips the quota
 * because the caller already took it (recall takes `chunks + 1` units in one call).
 */
export async function callUtility(
  d: CoachDeps, userId: string, pass: UtilityPass, messages: ChatTurn[],
  opts: { prepaid?: boolean; signal?: AbortSignal; timeoutMs?: number } = {},
): Promise<Record<string, any> | null> {
  const key = d.cfg.utilityKey || d.cfg.fireworksKey;
  if (!key) return null;
  if (!opts.prepaid && !(await takeUtilityUnits(d, userId, 1))) return null;
  const limits = UTILITY_PASSES[pass];
  const timeoutMs = Math.max(1, Math.round(Math.min(opts.timeoutMs ?? Infinity, limits.timeoutMs * d.timeScale)));
  const timeout = AbortSignal.timeout(timeoutMs);
  const signal = opts.signal ? AbortSignal.any([opts.signal, timeout]) : timeout;
  try {
    const res = await d.fetchImpl(d.cfg.upstreamUrl, {
      method: 'POST',
      headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' },
      signal,
      body: JSON.stringify({
        model: d.cfg.models.utility, messages, stream: false, max_tokens: limits.maxTokens,
        temperature: limits.temperature, response_format: { type: 'json_object' },
        ...(d.cfg.utilityReasoning ? { reasoning_effort: d.cfg.utilityReasoning } : {}),
      }),
    });
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    const json = await raceAbort(res.json(), signal);
    const tokens = Number(json?.usage?.total_tokens);
    if (Number.isFinite(tokens) && tokens > 0) {
      try { await d.rest.rpc('coach_add_utility_tokens', { p_user_id: userId, p_tokens: Math.trunc(tokens) }); }
      catch { /* accounting is best effort */ }
    }
    const choice = json?.choices?.[0];
    if (!choice || choice.finish_reason === 'length') return null;
    const parsed = parseJsonReply(choice.message?.content);
    return isObject(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function raceAbort<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(signal.reason);
    signal.addEventListener('abort', onAbort, { once: true });
    work.then(resolve, reject).finally(() => signal.removeEventListener('abort', onAbort));
  });
}

/**
 * The model's JSON object. Same idea as `coach_visual.ts`'s parser (strip code fences), plus what cheap
 * models add: `<think>` blocks and prose around the object, from which the first balanced object is taken.
 */
export function parseJsonReply(content: unknown): any {
  if (typeof content !== 'string') return null;
  const s = content.replace(/<think>[\s\S]*?(?:<\/think>|$)/gi, '').replace(/<\/think>/gi, '').trim()
    .replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim();
  try { return JSON.parse(s); } catch { /* look for the first object */ }
  const start = s.indexOf('{');
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < s.length; i++) {
    const c = s[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') inString = false;
    } else if (c === '"') inString = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) {
      try { return JSON.parse(s.slice(start, i + 1)); } catch { return null; }
    }
  }
  return null;
}

// ------------------------------------------------------------------------------------------------
// Tokens and near-duplicates (§6)
// ------------------------------------------------------------------------------------------------

// The stop words of internal.coach_memory_tokens, minus the negations: "does not eat meat" and "eats meat"
// must never read as the same fact.
const STOP_WORDS = new Set([
  'the', 'and', 'for', 'are', 'but', 'you', 'all', 'any', 'can', 'had', 'her', 'was', 'one', 'our', 'out',
  'has', 'have', 'him', 'his', 'how', 'its', 'may', 'now', 'she', 'too', 'use', 'who', 'did', 'get', 'got',
  'let', 'with', 'that', 'this', 'from', 'they', 'them', 'then', 'than', 'there', 'their', 'what', 'when',
  'where', 'which', 'while', 'will', 'would', 'about', 'after', 'again', 'also', 'been', 'being', 'both',
  'each', 'into', 'just', 'like', 'more', 'most', 'much', 'must', 'only', 'other', 'over', 'same', 'some',
  'such', 'very', 'were', 'your', 'yours', 'because', 'before', 'between', 'could', 'does', 'doing', 'during',
  'should', 'these', 'those', 'through', 'under', 'until', 'here', 'having', 'user', 'users',
]);

const MONTHS = new Set([
  'january', 'february', 'march', 'april', 'june', 'july', 'august', 'september', 'october', 'november',
  'december', 'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
]);

function stem(w: string): string {
  let s = w;
  // Plural first, then the verb ending, so "hamstrings" and "hamstring" meet at "hamstr".
  if (s.endsWith('ies') && s.length > 4) s = `${s.slice(0, -3)}y`;
  else if (s.endsWith('es') && s.length > 4) s = s.slice(0, -2);
  else if (s.endsWith('s') && !s.endsWith('ss') && s.length > 3) s = s.slice(0, -1);
  if (s.endsWith('ing') && s.length > 5) s = s.slice(0, -3);
  else if (s.endsWith('ed') && s.length > 4) s = s.slice(0, -2);
  // "running" → "runn" → "run"; "race", "races" and "racing" → "rac".
  if (s.length > 3 && /([b-df-hj-np-tv-z])\1$/.test(s) && !/(?:ll|ss|ff|zz)$/.test(s)) s = s.slice(0, -1);
  if (s.length > 3 && s.endsWith('e')) s = s.slice(0, -1);
  return s;
}

// A distance or event marker ("5k", "10km", "400m", "26.2mi") names what a fact is about, so it counts as a
// word: "5k personal best" and "10k personal best" are two facts, not one whose figure changed. Other units
// ("100kg", "3x", "6am", "2nd") are measurements and stay figures.
const SUBJECT_FIGURE = /^[0-9]+(?:[.,][0-9]+)?(?:k|km|mi|m)$/;

/** A number or date token: anything with a digit (except a distance like "5k"), or a month name. */
export const isFigureToken = (t: string) => !SUBJECT_FIGURE.test(t) && (/[0-9]/.test(t) || MONTHS.has(t) || t === 'may');

/**
 * Normalised tokens: NFKC, lowercase, words of 3+ characters minus stop words with light stemming, and
 * every number and date token whatever its length ("5", "10:30", "2026-10-07", "april"). A unit written
 * against its number stays on it ("10k", "400m", "100kg"), and "half marathon" is one word, so neither
 * distance reads as the other.
 */
export function memoryTokens(text: unknown): string[] {
  if (typeof text !== 'string') return [];
  const norm = text.slice(0, 4000).normalize('NFKC').toLowerCase().replace(/n[’']t\b/g, ' not')
    .replace(/\b(half|ultra)[\s-]+marathon/g, '$1marathon');
  const raw = norm.match(/[0-9]+(?:[.,:/-][0-9]+)*(?:[a-z]{1,3}(?!\p{L}))?|\p{L}+/gu) ?? [];
  const out = new Set<string>();
  raw.forEach((w, i) => {
    if (/[0-9]/.test(w)) out.add(w.replace(/^([0-9]+(?:[.,][0-9]+)?(?:k|km))s$/, '$1'));
    else if (MONTHS.has(w)) out.add(w);
    // "may" is a month only next to a number ("3 May", "May 12").
    else if (w === 'may') { if (/[0-9]/.test(raw[i - 1] ?? '') || /[0-9]/.test(raw[i + 1] ?? '')) out.add(w); }
    else if (w === 'no' || w === 'never') out.add('not');
    else if (w.length >= 3 && !STOP_WORDS.has(w)) out.add(stem(w));
  });
  return [...out];
}

export const tokenSet = (text: unknown) => new Set(memoryTokens(text));

function intersection(a: Set<string>, b: Set<string>): number {
  let n = 0;
  for (const t of a) if (b.has(t)) n++;
  return n;
}

export function jaccard(a: Set<string>, b: Set<string>): number {
  if (!a.size && !b.size) return 0;
  const shared = intersection(a, b);
  return shared / (a.size + b.size - shared);
}

/** How much of the smaller set the larger contains. */
export function containment(a: Set<string>, b: Set<string>): number {
  const small = Math.min(a.size, b.size);
  return small ? intersection(a, b) / small : 0;
}

const setEq = (a: Set<string>, b: Set<string>) => a.size === b.size && intersection(a, b) === a.size;
const subsetOf = (a: Set<string>, b: Set<string>) => intersection(a, b) === a.size;
export const wordTokens = (s: Set<string>) => new Set([...s].filter((t) => !isFigureToken(t)));
const words = wordTokens;
const figures = (s: Set<string>) => new Set([...s].filter(isFigureToken));
const without = (s: Set<string>, t: string) => new Set([...s].filter((x) => x !== t));

// Who a fact is about. "User's daughter has asthma" is not "User has asthma", however many words they share.
const RELATION = new Set([
  'partner', 'wife', 'wives', 'husband', 'spouse', 'fiance', 'fiancee', 'girlfriend', 'boyfriend', 'daughter', 'son',
  'kid', 'child', 'children', 'baby', 'mother', 'father', 'mom', 'mum', 'dad', 'parent', 'brother', 'sister', 'sibling',
  'grandmother', 'grandfather', 'family', 'friend', 'coach', 'trainer', 'client', 'athlete', 'teammate', 'colleague',
  'coworker', 'boss', 'roommate', 'dog', 'cat', 'pet',
].map(stem));
const relations = (s: Set<string>) => new Set([...s].filter((t) => RELATION.has(t)));

/** Both texts are about the same person: the same relation words (none, for the user's own facts). */
export const sameSubject = (a: Set<string>, b: Set<string>) => setEq(relations(a), relations(b));

/**
 * The same statement in words, figures aside: word-jaccard >= 0.72 over at least two shared words (or one
 * identical word), with nothing swapped ("left knee" / "right knee"): the smaller side's words all appear in
 * the larger one.
 */
function sameWords(aw: Set<string>, bw: Set<string>): boolean {
  if (!aw.size || !bw.size || jaccard(aw, bw) < 0.72) return false;
  if (intersection(aw, bw) < 2 && !setEq(aw, bw)) return false;
  return aw.size <= bw.size ? subsetOf(aw, bw) : subsetOf(bw, aw);
}

/**
 * How a new memory relates to an existing one:
 * - `same`: identical token sets (confirm the old row);
 * - `supersede`: the same words with different numbers or dates, or with the polarity flipped (update the old
 *   row to the new content);
 * - `longer`: a near-duplicate that says more (update to the new content);
 * - `covered`: a near-duplicate the old row already covers (confirm);
 * - null: a different fact, including one about someone else.
 */
export type NearDuplicate = 'same' | 'supersede' | 'longer' | 'covered';

export function nearDuplicate(next: string, old: string): NearDuplicate | null {
  const a = tokenSet(next);
  const b = tokenSet(old);
  if (!a.size || !b.size) return null;
  if (setEq(a, b)) return 'same';
  if (!sameSubject(a, b)) return null;
  const aw = words(a);
  const bw = words(b);
  const af = figures(a);
  const bf = figures(b);
  if (af.size && !setEq(af, bf) && sameWords(aw, bw)) return 'supersede';
  // The same statement with its polarity flipped ("eats meat" / "does not eat meat") replaces the old one too.
  if (a.has('not') !== b.has('not') && sameWords(without(aw, 'not'), without(bw, 'not'))) return 'supersede';
  // Containment only counts when the smaller side says enough: "User is vegan" is contained in many longer
  // sentences that are not the same fact.
  const contained = containment(a, b) >= 0.9 && (Math.min(a.size, b.size) >= 3 || jaccard(a, b) >= 0.5);
  if (jaccard(a, b) >= 0.72 || contained) {
    // Longer only replaces when nothing specific is lost: every number or date of the old row survives.
    const keepsFigures = [...bf].every((t) => a.has(t));
    return next.length > old.length && keepsFigures ? 'longer' : 'covered';
  }
  return null;
}

/**
 * Token-set similarity used against forget tombstones (which keep tokens only) and for "another memory already
 * covers this one". Containment stays broad here (forgetting "has a dog named Max" also keeps "has a dog" out),
 * but a fact about someone else never matches the user's own, and the words-only match needs the same words.
 */
export function tokensNearMatch(a: Set<string>, b: Set<string>): boolean {
  if (!a.size || !b.size) return false;
  if (setEq(a, b)) return true;
  if (!sameSubject(a, b)) return false;
  if (jaccard(a, b) >= 0.72 || containment(a, b) >= 0.9) return true;
  return sameWords(words(a), words(b));
}

/**
 * The save_memory path's looser match against one same-family row (word-jaccard >= 0.45, same subject):
 * `supersedes` when the new text keeps every word and figure of the old one and says more (update the row),
 * `covered` when the old row already says everything the new one does (confirm it), null otherwise.
 */
export function toolOverlap(next: string, old: string): 'supersedes' | 'covered' | null {
  const a = tokenSet(next);
  const b = tokenSet(old);
  if (!a.size || !b.size || !sameSubject(a, b)) return null;
  const aw = words(a);
  const bw = words(b);
  if (!aw.size || !bw.size || jaccard(aw, bw) < 0.45) return null;
  if (subsetOf(b, a) && a.size > b.size) return 'supersedes';
  if (subsetOf(a, b)) return 'covered';
  return null;
}

/**
 * Two memories that look like one fact told twice: same topic family and subject, and word-jaccard >= 0.45 or
 * containment >= 0.8 with at least 4 tokens on the smaller side. Cheap and deliberately loose; it only decides
 * which pairs a targeted consolidation pass shows the model.
 */
export function likelyDuplicates(a: MemoryLike, b: MemoryLike): boolean {
  if (!sameFamily(a.topic, b.topic)) return false;
  const ta = tokenSet(a.content);
  const tb = tokenSet(b.content);
  if (!ta.size || !tb.size || !sameSubject(ta, tb)) return false;
  const aw = words(ta);
  const bw = words(tb);
  if (aw.size && bw.size && jaccard(aw, bw) >= 0.45) return true;
  return Math.min(ta.size, tb.size) >= 4 && containment(ta, tb) >= 0.8;
}

/** Every word of `part` (at least `share` of them) and every figure of it appear in `whole`. */
export function covers(whole: string, part: string, share = 0.8): boolean {
  const w = tokenSet(whole);
  const p = tokenSet(part);
  const pw = words(p);
  if (!pw.size || !sameSubject(w, p)) return false;
  return intersection(pw, w) / pw.size >= share && [...figures(p)].every((t) => w.has(t));
}

export const MEMORY_TOPICS = new Set([
  'goal', 'injury', 'preference', 'achievement', 'lifestyle', 'routine', 'health', 'training', 'nutrition', 'sleep',
  'general',
]);

export function memoryTopic(v: unknown): string {
  const t = typeof v === 'string' ? v.trim().toLowerCase() : '';
  return MEMORY_TOPICS.has(t) ? t : 'general';
}

const FAMILY: Record<string, string> = {
  goal: 'goal', achievement: 'goal', training: 'goal',
  injury: 'health', health: 'health',
  preference: 'life', lifestyle: 'life', routine: 'life', nutrition: 'life', sleep: 'life',
};

/** Dedupe compares within a topic family; `general` (or anything unknown) matches every family. */
export function sameFamily(a: string, b: string): boolean {
  const fa = FAMILY[a];
  const fb = FAMILY[b];
  return !fa || !fb || fa === fb;
}

export interface MemoryLike { id: string; content: string; topic: string }

const RANK: Record<NearDuplicate, number> = { same: 3, supersede: 2, longer: 1, covered: 1 };

/** The existing memory a new one duplicates, preferring an exact match, then the most similar. */
export function findNearDuplicate<T extends MemoryLike>(content: string, topic: string, pool: T[]): { row: T; kind: NearDuplicate } | null {
  const mine = tokenSet(content);
  let best: { row: T; kind: NearDuplicate; score: number } | null = null;
  for (const row of pool) {
    if (!sameFamily(topic, row.topic)) continue;
    const kind = nearDuplicate(content, row.content);
    if (!kind) continue;
    const score = RANK[kind] * 10 + jaccard(mine, tokenSet(row.content));
    if (!best || score > best.score) best = { row, kind, score };
  }
  return best && { row: best.row, kind: best.kind };
}

// ------------------------------------------------------------------------------------------------
// Curator guards (§6)
// ------------------------------------------------------------------------------------------------

export const TRANSIENT = /\b(?:today|yesterday|tonight|last night|this week|this morning|right now)\b/i;
export const METRIC_READING = /\b\d+(?:[.,]\d+)?\s*(?:bpm|ms|kcal|hrs?|hours|steps)\b|\b\d+(?:[.,]\d+)?\s*%/i;

const SENSITIVE: RegExp[] = [
  /\bself[-\s]?harm|\bcut(?:s|ting)? (?:myself|himself|herself|themselves)|\bhurt(?:s|ing)? (?:myself|himself|herself|themselves)/i,
  /\bsuicid|\bkill (?:myself|himself|herself|themselves)|\bend (?:my|his|her|their) life|\boverdos/i,
  /\bpurg(?:e|es|ed|ing)\b|\bbing(?:e|es|ed|eing|ing)\b|\bbulimi|\banorexi|\blaxative|\bvomit|\bthrow(?:s|ing)? up after|\bstarv(?:e|es|ed|ing) (?:myself|himself|herself|themselves)|\bmak(?:e|es|ing) (?:myself|himself|herself|themselves) sick/i,
  /[\w.+-]+@[\w-]+\.[\w.-]+/,
  /\bhttps?:\/\/|\bwww\./i,
  /\b\d{1,5}\s+\w+(?:\s+\w+)?\s+(?:street|st|avenue|ave|road|rd|lane|ln|drive|dr|boulevard|blvd)\b/i,
];
// Another person's name: "wife Sarah", "friend named John", "called Max". Case-sensitive on the name.
const OTHER_PERSON = /\bDr\.?\s+[A-Z][a-z]{2,}|\b(?:wife|husband|partner|girlfriend|boyfriend|fianc[eé]e?|son|daughter|kid|child|mother|father|mom|mum|dad|brother|sister|friend|coach|trainer|doctor|physio|therapist|boss|colleague|roommate|named|called)(?:'s)?,?\s+(?:is\s+)?[A-Z][a-z]{2,}/;

// A phone number has 9 or more digits; ISO dates ("2026-10-07") do not count.
const PHONE = /\+?\(?\d[\d\s().-]{6,}\d/g;
const hasPhone = (text: string) =>
  (text.match(PHONE) ?? []).some((m) => m.replace(/\D/g, '').length >= 9 && !/\d{4}-\d{2}-\d{2}/.test(m));

export function isSensitive(text: string): boolean {
  return SENSITIVE.some((re) => re.test(text)) || OTHER_PERSON.test(text) || hasPhone(text);
}

export interface GuardContext {
  /** Tokens of the batch's new user messages. */
  userTokens: Set<string>;
  /** The batch's new user text, for the explicit "remember" exception. */
  userText: string;
  /** Token sets of forget tombstones from the last 365 days. */
  tombstones: Set<string>[];
}

/**
 * Why an add or an update's new content is dropped, or null when it passes: (a) grounding below 40% of its
 * word tokens in the user's own messages, (b) transient phrasing or a metric reading, (c) sensitive content
 * the user did not ask to remember, (d) a near-match of a forgotten fact.
 */
export function guardMemoryContent(content: string, ctx: GuardContext): string | null {
  const own = words(tokenSet(content));
  if (!own.size) return 'ungrounded';
  if (intersection(own, ctx.userTokens) / own.size < 0.4) return 'ungrounded';
  if (TRANSIENT.test(content) || METRIC_READING.test(content)) return 'transient';
  if (isSensitive(content) && !/\bremember\b/i.test(ctx.userText)) return 'sensitive';
  const mine = tokenSet(content);
  if (ctx.tombstones.some((t) => tokensNearMatch(mine, t))) return 'forgotten';
  return null;
}

/** At least one word token in common with the user's new messages (the floor for confirm and retire). */
export function mentions(content: string, userTokens: Set<string>): boolean {
  return intersection(words(tokenSet(content)), userTokens) > 0;
}

// ------------------------------------------------------------------------------------------------
// Sanitisers for model-written strings
// ------------------------------------------------------------------------------------------------

const EMOJI = /\p{Extended_Pictographic}|[\u{1F1E6}-\u{1F1FF}\uFE0F\u200D\u20E3]/gu;
const QUOTES = /["“”«»„`]|(^|\s)['‘’]+|['‘’]+(?=\s|$)/g;
const TITLE_FILLER = /^(?:(?:a|an|the|my)\s+)?(?:chat|chats|question|questions|conversation|discussion|talk|inquiry|query|queries|asking|request|help)\s+(?:about|on|regarding|re|for|with|of)\s*:?\s+/i;
const TRAILING_PUNCT = /[\s.!?,;:…\-–—]+$/u;

function deco(raw: string): string {
  return collapse(raw.normalize('NFKC').replace(EMOJI, '').replace(QUOTES, '$1'));
}

/** A model title: no quotes, emoji or trailing punctuation, no "Chat about …", at most 48 characters. */
export function sanitizeTitle(raw: unknown, max = 48): string | null {
  if (typeof raw !== 'string' || raw.length > 400 || /[\n{}<>]/.test(raw)) return null;
  let s = deco(raw).replace(/^title\s*:\s*/i, '');
  for (let i = 0; i < 2; i++) s = s.replace(TITLE_FILLER, '');
  s = s.replace(/^[\s\-–—:,.]+/u, '').replace(TRAILING_PUNCT, '');
  if (s.length > max) s = cutWords(s, max);
  s = s.replace(TRAILING_PUNCT, '');
  if (s.length < 2 || !/\p{L}/u.test(s)) return null;
  return s[0].toUpperCase() + s.slice(1);
}

function cutWords(s: string, max: number): string {
  if (s.length <= max) return s;
  const head = s.slice(0, max + 1);
  const space = head.lastIndexOf(' ');
  return (space > 0 ? head.slice(0, space) : s.slice(0, max)).trim();
}

/** The deterministic title: the first six words of the question. */
export function fallbackTitle(question: unknown): string | null {
  const s = deco(typeof question === 'string' ? question.slice(0, 600) : '').split(' ').slice(0, 6).join(' ');
  const t = cutWords(s, 48).replace(TRAILING_PUNCT, '');
  return t.length >= 1 && /[\p{L}\p{N}]/u.test(t) ? t[0].toUpperCase() + t.slice(1) : null;
}

/** One model-written line (a follow-up, a starter): collapsed, unquoted, without list markers. */
export function sanitizeLine(raw: unknown, max: number): string | null {
  if (typeof raw !== 'string' || raw.length > max * 4) return null;
  const s = deco(raw).replace(/^(?:[-*•]|\d+[.)])\s+/u, '').trim();
  if (!s || s.length > max || !/\p{L}/u.test(s)) return null;
  return s;
}

/** The key two lines are compared by: case, punctuation and spacing ignored. */
export function lineKey(s: string): string {
  return s.normalize('NFKC').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

// Starters and follow-ups never ask for a diagnosis or a dose, and never talk about models or vendors.
const OFF_LIMITS = /\b(?:diagnos\w*|dosage|doses?|dosing|mg|milligrams?|prescri\w*|ai model|language model|llm|gpt|chatgpt|openai|deepseek|fireworks|anthropic|claude|gemini|vendor)\b/i;

export const offLimits = (s: string) => OFF_LIMITS.test(s);
