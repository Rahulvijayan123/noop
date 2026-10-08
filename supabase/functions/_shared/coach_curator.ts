// Sana's cheap-model side calls (docs/COACH_MEMORY.md §5): thread titles, follow-up questions, personalised
// starters, and per-thread maintenance (the rolling summary plus memory curation, then consolidation).
//
// None of these are chat messages and none spend the chat quota. Each pass has a deterministic fallback, so a
// spent utility budget or a model fault degrades to plain behaviour instead of an error. Model output is never
// trusted as written: titles and lines are sanitised, thread and memory references are short refs mapped back
// here, and memory ops pass the §6 guards before coach_thread_publish_v1 applies them with the summary.
import {
  callUtility, type ChatTurn, cleanLocale, clip, collapse, type CoachDeps, covers, day, enc, fail, fallbackTitle,
  findNearDuplicate, guardMemoryContent, type GuardContext, isObject, isSensitive, languageName, likelyDuplicates,
  lineKey, MEMORY_TOPICS, memoryTokens, memoryTopic, mentions, METRIC_READING, offLimits, quoted, readJson,
  readOptionalJson, Refs, sameFamily, sanitizeLine, sanitizeTitle, SMALL_BODY_BYTES, takeUtilityUnits, tokenSet,
  tokensNearMatch, TRANSIENT, tsKey, uuidOf, jaccard,
} from './coach_llm.ts';
import { activeMemories, applyMemoryOps, versionGuard } from './coach_memory.ts';
import { loadThread, QUIET_MS, summaryDue } from './coach_store.ts';

const REGENERABLE = new Set(['none', 'fallback', 'legacy']);

// ------------------------------------------------------------------------------------------------
// Titles
// ------------------------------------------------------------------------------------------------

const titleSystem = (language: string) =>
  `You name chats for Sana, a health and fitness assistant. Reply with JSON only: {"title": "..."}. `
  + `The title is 2 to 6 words in Title Case, in ${language}, naming the specific subject of the user's first question `
  + '(the metric, plan, goal or problem). No quotes, emoji or trailing punctuation; never start with "Chat about", '
  + '"Question about" or anything like it.';

const titleTurns = (language: string, question: string, answer: string): ChatTurn[] => [
  { role: 'system', content: titleSystem(language) },
  { role: 'user', content: `Question: ${clip(question, 600)}${answer ? `\n\nAnswer: ${clip(answer, 1200)}` : ''}` },
];

const titleRule = (language: string) =>
  `title: 2 to 6 words in Title Case in ${language} naming the chat's subject; no quotes, emoji or trailing punctuation.`;

/**
 * Stores a model title (`auto`), or when there is none the first-words fallback on a thread that has no title
 * yet. The PATCH is filtered on the title source, so a rename that lands first always wins.
 */
async function storeTitle(d: CoachDeps, userId: string, threadId: string, modelTitle: string | null, question: string) {
  const stamp = new Date(d.now()).toISOString();
  const owner = `user_id=eq.${userId}&id=eq.${threadId}`;
  if (modelTitle) {
    const rows = await d.rest.patch('coach_threads', { title: modelTitle, title_source: 'auto', updated_at: stamp },
      `${owner}&title_source=in.(none,fallback,legacy)&select=id`);
    return rows?.length ? { title: modelTitle, titleSource: 'auto', generated: true } : null;
  }
  const fallback = fallbackTitle(question);
  if (!fallback) return null;
  const rows = await d.rest.patch('coach_threads', { title: fallback, title_source: 'fallback', updated_at: stamp },
    `${owner}&title_source=eq.none&select=id`);
  return rows?.length ? { title: fallback, titleSource: 'fallback', generated: false } : null;
}

export async function titleRoute(req: Request, userId: string, rawId: string, d: CoachDeps): Promise<Response> {
  const threadId = uuidOf(rawId);
  if (!threadId) throw fail('invalid_id', 400);
  const body = await readJson(req, SMALL_BODY_BYTES);
  const question = collapse(body?.question).slice(0, 4000);
  if (!question) throw fail('invalid_title_request', 400);
  const answer = collapse(body?.answer);
  const language = languageName(cleanLocale(body?.locale));
  const thread = await loadThread(d, userId, threadId, 'id,title,title_source');
  if (!thread) throw fail('thread_not_found', 404);
  if (!REGENERABLE.has(thread.title_source)) {
    return Response.json({ title: thread.title ?? null, titleSource: thread.title_source, generated: false });
  }
  const raw = await callUtility(d, userId, 'title', titleTurns(language, question, answer));
  const stored = await storeTitle(d, userId, threadId, sanitizeTitle(raw?.title), question);
  if (stored) return Response.json(stored);
  const now = await loadThread(d, userId, threadId, 'id,title,title_source');
  return Response.json({ title: now?.title ?? null, titleSource: now?.title_source ?? 'none', generated: false });
}

// ------------------------------------------------------------------------------------------------
// Follow-ups
// ------------------------------------------------------------------------------------------------

function followUpsSystem(language: string, minor: boolean, wantTitle: boolean): string {
  return [
    'You suggest what the user might ask Sana, a health and fitness assistant, right after its answer. '
      + `Reply with JSON only: {"follow_ups": ["...", "...", "..."]${wantTitle ? ', "title": "..."' : ''}}.`,
    `follow_ups: exactly 3 questions in ${language}, written as the user would type them (first person), each 8 to 80 characters `
      + '(aim for under 70; a longer one is discarded).',
    'Each one is specific to what this answer covered (its metric, figures, plan or claim) and leads somewhere new: '
      + 'not a rephrase of the question, not a question already asked, not generic.',
    'Never ask for a diagnosis, a medication or a dosage, and never ask about AI models, vendors or Sana itself.',
    minor ? 'The user is under 18: keep questions age-appropriate, with no weight-loss, dieting or supplement questions.' : '',
    wantTitle ? titleRule(language) : '',
  ].filter(Boolean).join('\n');
}

const TOPIC_WORDS: [RegExp, string][] = [
  [/\bhrv\b|heart rate variability/i, 'HRV'], [/\bresting heart rate\b|\brhr\b/i, 'resting heart rate'],
  [/\bsleep/i, 'sleep'], [/\brecovery\b|\bcharge\b/i, 'recovery'], [/\bstrain\b|\beffort\b|training load/i, 'training load'],
  [/\bvo2/i, 'VO2 max'], [/\bsteps\b/i, 'step count'], [/\bstress\b/i, 'stress'], [/\bweight\b/i, 'weight'],
  [/\b(?:workouts?|training|runs?|running|lifting|strength)\b/i, 'training'], [/\b(?:diet|nutrition|protein|calories)\b/i, 'nutrition'],
];

/** The deterministic follow-ups: the answer's main topics in fixed English templates. */
export function keywordFollowUps(question: string, answer: string, asked: string[] = []): string[] {
  const text = `${answer}\n${question}`;
  const [a, b] = TOPIC_WORDS.filter(([re]) => re.test(text)).map(([, t]) => t);
  const lines = a
    ? [`How has my ${a} trended lately?`, `What would improve my ${b ?? a} the most?`, 'How should this change my plan this week?']
    : ['What should I focus on this week?', 'How am I trending overall?', 'What one change would help me most?'];
  const seen = new Set([question, ...asked].map(lineKey));
  return lines.filter((l) => !seen.has(lineKey(l)));
}

/** Model follow-ups: bounded, safe, and new against the question, the asked list and each other. */
export function validFollowUps(raw: unknown, question: string, asked: string[]): string[] {
  const prior = [question, ...asked];
  const seen = new Set(prior.map(lineKey));
  const priorTokens = prior.map((p) => tokenSet(p)).filter((t) => t.size);
  const out: string[] = [];
  for (const item of Array.isArray(raw) ? raw.slice(0, 8) : []) {
    const s = sanitizeLine(item, 80);
    if (!s || s.length < 8 || offLimits(s)) continue;
    const key = lineKey(s);
    const mine = tokenSet(s);
    if (!key || seen.has(key) || (mine.size >= 3 && priorTokens.some((t) => jaccard(mine, t) >= 0.8))) continue;
    seen.add(key);
    priorTokens.push(mine);
    out.push(s);
    if (out.length === 3) break;
  }
  return out;
}

function ageBelow18(dob: unknown, now: number): boolean {
  if (typeof dob !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(dob)) return false;
  const [y, m, dd] = dob.split('-').map(Number);
  const t = new Date(now);
  const passed = t.getUTCMonth() + 1 > m || (t.getUTCMonth() + 1 === m && t.getUTCDate() >= dd);
  return t.getUTCFullYear() - y - (passed ? 0 : 1) < 18;
}

/** The phone waits 12 s for follow-ups; a title retry only runs inside this. */
const FOLLOWUPS_DEADLINE_MS = 11_000;

export async function followupsRoute(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const started = performance.now();
  const body = await readJson(req, SMALL_BODY_BYTES);
  const question = collapse(body?.question).slice(0, 4000);
  const answer = collapse(body?.answer).slice(0, 20_000);
  if (!question || !answer) throw fail('invalid_followups', 400);
  const threadId = body?.threadId == null ? null : uuidOf(body.threadId);
  if (body?.threadId != null && !threadId) throw fail('invalid_id', 400);
  const locale = cleanLocale(body?.locale);
  const language = languageName(locale);
  const sentAsked = Array.isArray(body?.asked);
  const [thread, ranked, profile, storedAsked] = await Promise.all([
    threadId ? loadThread(d, userId, threadId, 'id,title,title_source,summary') : Promise.resolve(null),
    d.rest.rpc('coach_memories_ranked_v1', { p_user: userId, p_query: question.slice(0, 2000), p_limit: 4, p_pin_safety: true })
      .catch(() => null),
    d.rest.select('profiles', `id=eq.${userId}&select=date_of_birth`).catch(() => []),
    // Without a list from the phone, the thread's own non-blocked questions.
    threadId && !sentAsked
      ? d.rest.select('coach_messages', `user_id=eq.${userId}&thread_id=eq.${threadId}&role=eq.user&blocked=is.false`
        + '&order=created_at.desc,id.desc&limit=12&select=content').catch(() => [])
      : Promise.resolve([]),
  ]);
  const asked = (sentAsked ? body.asked : storedAsked.map((r: any) => r.content))
    .filter((s: unknown) => typeof s === 'string').slice(-12).map((s: string) => collapse(s).slice(0, 300)).filter(Boolean);
  const memories = (Array.isArray(ranked?.memories) ? ranked.memories : []).slice(0, 4);
  const minor = ageBelow18(profile?.[0]?.date_of_birth, d.now());
  const wantTitle = body?.wantTitle === true && !!thread && REGENERABLE.has(thread.title_source);
  // The first answer's title was asked for before the chat's first save landed (a slow or retried outbox flush):
  // the phone asks POST threads/:id/title once the rows are saved, instead of keeping the first-words title.
  const titlePending = body?.wantTitle === true && !!threadId && !thread;

  const raw = await callUtility(d, userId, 'followups', [
    { role: 'system', content: followUpsSystem(language, minor, wantTitle) },
    {
      role: 'user', content: [
        thread?.summary ? `Chat so far: ${clip(collapse(thread.summary), 600)}` : '',
        asked.length ? `Already asked:\n${asked.map((q: string) => `- ${q}`).join('\n')}` : '',
        memories.length ? `What Sana knows about the user:\n${memories.map((m: any) => `- ${collapse(m.content)}`).join('\n')}` : '',
        `Question: ${clip(question, 3000)}`,
        `Answer: ${clip(answer, 3000)}`,
      ].filter(Boolean).join('\n\n'),
    },
  ]);
  let followUps = validFollowUps(raw?.follow_ups ?? raw?.followUps, question, asked);
  // The keyword fallback is English; other languages get none and the phone shows its own.
  if (!followUps.length && locale.toLowerCase().startsWith('en')) followUps = keywordFollowUps(question, answer, asked);
  const result: { followUps: string[]; title?: string; titlePending?: boolean } = { followUps, ...(titlePending ? { titlePending } : {}) };
  if (wantTitle && thread) {
    let title = sanitizeTitle(raw?.title);
    if (!title) {
      // The combined reply failed or left the title out. The phone only asks for a title with the first answer,
      // so one title pass runs in the time it still waits; otherwise the first-words title would stay for good.
      const left = FOLLOWUPS_DEADLINE_MS * d.timeScale - (performance.now() - started);
      if (left >= 1_000 * d.timeScale) {
        title = sanitizeTitle((await callUtility(d, userId, 'title', titleTurns(language, question, answer), { timeoutMs: left }))?.title);
      }
    }
    const stored = await storeTitle(d, userId, thread.id, title, question);
    if (stored?.title) result.title = stored.title;
  }
  return Response.json(result);
}

// ------------------------------------------------------------------------------------------------
// Starter suggestions
// ------------------------------------------------------------------------------------------------

const SUGGESTIONS_VERSION = 1;
const SUGGESTIONS_TTL_MS = 12 * 3_600_000;
const KINDS = new Set(['continue', 'state', 'goal', 'explore']);
const MEMORY_PRIORITY: Record<string, number> = { goal: 0, injury: 0, routine: 1, preference: 1 };

type Starter = { text: string; kind: string; threadId?: string };

/** The phone's coarse state: short keys, primitive values, short string lists. Keys sorted for the fingerprint. */
function cleanState(v: unknown): Record<string, unknown> | null {
  if (!isObject(v)) return null;
  const out: Record<string, unknown> = {};
  for (const key of Object.keys(v).sort().slice(0, 32)) {
    const val = v[key];
    if (!/^[A-Za-z][A-Za-z0-9_]{0,31}$/.test(key)) continue;
    if (typeof val === 'string') out[key] = collapse(val).slice(0, 80);
    else if (typeof val === 'number' && Number.isFinite(val)) out[key] = Math.round(val * 10) / 10;
    else if (typeof val === 'boolean') out[key] = val;
    else if (Array.isArray(val)) out[key] = val.filter((x) => typeof x === 'string').slice(0, 8).map((x) => collapse(x).slice(0, 40));
  }
  return out;
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function cachedStarters(v: unknown): Starter[] {
  if (!Array.isArray(v)) return [];
  return v.filter(isObject).map((s) => ({
    text: sanitizeLine(s.text, 64) ?? '', kind: KINDS.has(s.kind) ? s.kind : 'explore',
    ...(s.kind === 'continue' && uuidOf(s.threadId) ? { threadId: uuidOf(s.threadId)! } : {}),
  })).filter((s) => s.text && (s.kind !== 'continue' || s.threadId)).slice(0, 4);
}

/** Model starters: at most 4, ≤ 64 characters, at most 2 `continue` items and only for chats it was shown. */
export function validStarters(raw: unknown, refs: Refs, avoid: string[]): Starter[] {
  const seen = new Set(avoid.map(lineKey));
  const out: Starter[] = [];
  let continues = 0;
  for (const item of Array.isArray(raw) ? raw.slice(0, 8) : []) {
    if (!isObject(item)) continue;
    const text = sanitizeLine(item.text, 64);
    if (!text || offLimits(text) || seen.has(lineKey(text))) continue;
    const kind = KINDS.has(item.kind) ? item.kind : 'explore';
    let threadId: string | undefined;
    if (kind === 'continue') {
      threadId = refs.resolve(item.thread ?? item.threadId);
      if (!threadId || continues >= 2) continue;
      continues++;
    }
    seen.add(lineKey(text));
    out.push({ text, kind, ...(threadId ? { threadId } : {}) });
    if (out.length === 4) break;
  }
  return out;
}

function suggestionsSystem(language: string): string {
  return [
    'You write 4 conversation starters for the empty chat screen of Sana, a health and fitness assistant. '
      + 'Reply with JSON only: {"suggestions": [{"text": "...", "kind": "continue|state|goal|explore", "thread": "t1"}]}.',
    `Exactly 4 items in ${language}, each at most 64 characters, in the first person as something the user would tap to ask `
      + '("How did my sleep…", "Help me plan…").',
    'kind "continue" picks up one of the recent chats listed and sets "thread" to its ref (at most 2, only listed chats; '
      + 'prefer chats with something left open). kind "state" is about the current state, and when the state has flags at least '
      + 'one item is about a flag. kind "goal" is about a remembered goal, injury or routine. kind "explore" is something new and useful.',
    'Make them specific to this user and different from each other and from the recent questions. '
      + 'No diagnosis, medication or dosage questions.',
  ].join('\n');
}

export async function suggestionsRoute(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const body = await readOptionalJson(req);
  const state = cleanState(body.state);
  const fallback: Starter[] = (Array.isArray(body.fallback) ? body.fallback : [])
    .map((s: unknown) => sanitizeLine(s, 64)).filter((s: string | null): s is string => !!s && !offLimits(s))
    .slice(0, 12).map((text: string) => ({ text, kind: 'explore' }));
  const locale = cleanLocale(body.locale);
  const owner = `user_id=eq.${userId}`;
  const [[row], threads, memoryRows, questionRows] = await Promise.all([
    d.rest.select('coach_user_state', `${owner}&select=suggestions,suggestions_fingerprint,suggestions_at,recent_searches,memory_revision`),
    d.rest.select('coach_threads', `${owner}&message_count=gt.0&order=last_message_at.desc.nullslast,id.desc&limit=6`
      + '&select=id,title,last_message_at,summary_topics,open_loops'),
    d.rest.select('coach_memory_items', `${owner}&retired_at=is.null&order=importance.desc,last_confirmed_at.desc&limit=40&select=id,content,topic,importance`),
    d.rest.select('coach_messages', `${owner}&role=eq.user&blocked=is.false&order=created_at.desc,id.desc&limit=10&select=content`),
  ]);
  const searches: string[] = (Array.isArray(row?.recent_searches) ? row.recent_searches : [])
    .filter((s: unknown) => typeof s === 'string').slice(0, 5);
  const dayPart = typeof state?.dayPart === 'string' ? state.dayPart : '';
  const fingerprint = await sha256(JSON.stringify([
    SUGGESTIONS_VERSION, state, locale, Number(row?.memory_revision ?? 0),
    threads.map((t: any) => [t.id, t.last_message_at]), searches, dayPart,
  ]));
  const fresh = row?.suggestions_at && d.now() - Date.parse(row.suggestions_at) < SUGGESTIONS_TTL_MS;
  if (body.refresh !== true && row?.suggestions_fingerprint === fingerprint && fresh) {
    // A `continue` chip only ever names one of the recent chats, which the fingerprint covers; checked anyway.
    const live = new Set(threads.map((t: any) => String(t.id).toLowerCase()));
    const cached = cachedStarters(row.suggestions).filter((s) => !s.threadId || live.has(s.threadId));
    if (cached.length) return Response.json({ suggestions: cached, source: 'cache' });
  }

  const refs = new Refs('t');
  const memories = [...memoryRows].sort((a: any, b: any) => (MEMORY_PRIORITY[a.topic] ?? 2) - (MEMORY_PRIORITY[b.topic] ?? 2)).slice(0, 8);
  const questions = questionRows.map((r: any) => clip(collapse(r.content), 160)).filter(Boolean);
  const threadLines = threads.map((t: any) => {
    const loops = (Array.isArray(t.open_loops) ? t.open_loops : []).map((l: any) => (typeof l === 'string' ? l : l?.text))
      .filter((l: unknown) => typeof l === 'string').slice(0, 2);
    const topics = Array.isArray(t.summary_topics) ? t.summary_topics.slice(0, 4) : [];
    return `[${refs.ref(t.id)}] "${collapse(t.title) || 'Untitled chat'}" (${day(t.last_message_at)})`
      + `${topics.length ? ` topics: ${topics.join(', ')}` : ''}${loops.length ? `; open: ${loops.map((l: string) => clip(collapse(l), 100)).join('; ')}` : ''}`;
  });
  const prompt = [
    `Now: ${[state?.weekday, dayPart].filter((s) => typeof s === 'string' && s).join(' ') || day(d.now())}`,
    state ? `State: ${JSON.stringify(state)}` : 'State: unknown',
    memories.length ? `What Sana remembers:\n${memories.map((m: any) => `- [${m.topic}] ${clip(collapse(m.content), 200)}`).join('\n')}` : '',
    threadLines.length ? `Recent chats:\n${threadLines.join('\n')}` : 'Recent chats: none',
    questions.length ? `Recent questions:\n${questions.map((q: string) => `- ${q}`).join('\n')}` : '',
    searches.length ? `Recent searches:\n${searches.map((s) => `- ${clip(collapse(s), 80)}`).join('\n')}` : '',
  ].filter(Boolean).join('\n\n');
  const raw = await callUtility(d, userId, 'suggestions', [
    { role: 'system', content: suggestionsSystem(languageName(locale)) },
    { role: 'user', content: prompt },
  ]);
  const picked = validStarters(raw?.suggestions, refs, questions);
  if (!picked.length) return Response.json({ suggestions: fallback.slice(0, 4), source: 'fallback' });
  const keys = new Set(picked.map((s) => lineKey(s.text)));
  for (const f of fallback) {
    if (picked.length >= 4) break;
    if (!keys.has(lineKey(f.text))) { picked.push(f); keys.add(lineKey(f.text)); }
  }
  try {
    await d.rest.upsert('coach_user_state', {
      user_id: userId, suggestions: picked, suggestions_fingerprint: fingerprint,
      suggestions_at: new Date(d.now()).toISOString(), updated_at: new Date(d.now()).toISOString(),
    }, { onConflict: 'user_id', prefer: 'resolution=merge-duplicates,return=minimal' });
  } catch { /* the cache is an optimisation */ }
  return Response.json({ suggestions: picked, source: 'model' });
}

// ------------------------------------------------------------------------------------------------
// Maintenance: rolling summary + memory curation, then consolidation
// ------------------------------------------------------------------------------------------------

const LEASE_SECONDS = 120;
const LOAD_MESSAGES = 72;
const BATCH_MESSAGES = 24;
const BATCH_CHARS = 14_000;
const BATCH_MESSAGE_CHARS = 1_500;
const MAX_BATCHES = 3;
const MAX_CANDIDATES = 24;
const MAX_OPS = 4;
const MAX_MEMORY_CHARS = 300;
const SUMMARY_CHARS = 1_200;

export interface MaintainResult { status: 'done' | 'skipped' | 'busy'; summarized: boolean; memoryOps: number; consolidated: boolean }

interface PoolMemory {
  id: string; content: string; topic: string; importance: number; source?: string; source_thread_id?: string | null;
  created_at?: string; updated_at?: string; version?: number; pending?: boolean;
}

export async function maintainRoute(req: Request, userId: string, rawId: string, d: CoachDeps): Promise<Response> {
  const threadId = uuidOf(rawId);
  if (!threadId) throw fail('invalid_id', 400);
  await readOptionalJson(req);
  if (d.background) {
    d.background(runMaintain(d, userId, threadId).catch(() => undefined));
    return Response.json({ status: 'queued' }, { status: 202 });
  }
  const result = await runMaintain(d, userId, threadId);
  if (result.status === 'busy' && !(await loadThread(d, userId, threadId, 'id'))) throw fail('thread_not_found', 404);
  return Response.json(result);
}

const laterOf = (a: string | null | undefined, b: string | null | undefined) =>
  !a ? b ?? null : !b ? a : tsKey(a) >= tsKey(b) ? a : b;

/** One message as the curator reads it; a photo turn carries what the vision model saw. */
export function curatorLine(m: any): string {
  const seen = m.role === 'user' && typeof m.meta?.imageContext === 'string' ? collapse(m.meta.imageContext) : '';
  const text = `${seen ? `[Photo: ${clip(seen, 400)}] ` : ''}${collapse(String(m.content ?? ''))}`;
  return `[${day(m.created_at)}] ${m.role === 'user' ? 'User' : 'Sana'}: ${clip(text, BATCH_MESSAGE_CHARS)}`;
}

/** Oldest first: at most 24 messages and 14,000 characters per batch, at most 3 batches. */
export function maintenanceBatches(rows: any[]): any[][] {
  const batches: any[][] = [];
  let current: any[] = [];
  let chars = 0;
  for (const r of rows) {
    const size = curatorLine(r).length + 1;
    if (current.length && (current.length >= BATCH_MESSAGES || chars + size > BATCH_CHARS)) {
      batches.push(current);
      if (batches.length === MAX_BATCHES) return batches;
      current = [];
      chars = 0;
    }
    current.push(r);
    chars += size;
  }
  if (current.length) batches.push(current);
  return batches.slice(0, MAX_BATCHES);
}

/** A memory the assistant's save_memory tool wrote during this chat. */
const savedHere = (m: PoolMemory, threadId: string) => m.source === 'tool' && m.source_thread_id === threadId;

function curatorPrompt(o: {
  summary: string | null; batch: any[]; candidates: PoolMemory[]; refs: Refs; wantSummary: boolean; wantMemory: boolean; threadId: string;
}): ChatTurn[] {
  const keys = [
    o.wantSummary ? '"summary": "...", "topics": ["..."], "open_loops": ["..."]' : '',
    o.wantMemory ? '"memory_ops": [...]' : '',
  ].filter(Boolean).join(', ');
  const rules = [
    "You maintain the running summary and the long-term memory of a user's chat with Sana, a health and fitness assistant.",
    `Reply with JSON only: {${keys}}. The date in brackets is when each message was sent.`,
  ];
  if (o.wantSummary) {
    rules.push(
      `summary: at most ${SUMMARY_CHARS} characters, third person ("The user ..."), absolute dates (YYYY-MM-DD). Fold the new messages `
        + 'into the summary so far, keeping goals, plans, figures discussed, decisions and what Sana advised; drop small talk. '
        + 'It covers this chat only: never bring in facts from the saved memories or from other chats.',
      'topics: up to 6 short lowercase topics of the whole chat. open_loops: up to 3 short phrases for things left open '
        + '(a plan to report back on, a question not yet answered); [] if none.',
    );
  }
  if (o.wantMemory) {
    rules.push(
      'memory_ops: at most 4 of {"op":"add","topic":"goal|injury|preference|achievement|lifestyle|routine|health|training|nutrition|sleep|general",'
        + '"importance":1-5,"content":"..."}, {"op":"update","ref":"m3","content":"...","importance":1-5}, {"op":"confirm","ref":"m2"}, '
        + '{"op":"retire","ref":"m5","reason":"..."}, {"op":"merge","refs":["m1","m4"],"content":"...","topic":"...","importance":1-5}.',
      'Memory rules: store only durable facts the USER stated about themselves (goals, injuries, conditions, preferences, routines, '
        + "equipment, schedule, achievements). Never store Sana's advice, daily metric readings or passing states (how they feel today, "
        + 'last night\'s sleep). Content is one fact in the third person ("User ..."), at most 200 characters, with an absolute date '
        + '(YYYY-MM-DD) for anything time-bound (a race, when an injury started) and no date on a lasting fact. '
        + 'If a saved memory already says it, confirm or update that memory instead of adding. Use retire only when a user message '
        + 'here contradicts the memory. No ops is the preferred outcome: return [] unless the user said something durable and new.',
      'Memories listed as saved during this chat were written by Sana while it answered. When one of them states the same fact '
        + 'as another saved memory, or updates it, merge them: one merge op with both refs and the combined fact (the newest '
        + 'information, every date and figure kept). Never update one copy and leave the other.',
    );
  }
  const line = (m: PoolMemory) => `${o.refs.ref(m.id)} [${m.topic}, importance ${m.importance}] ${clip(collapse(m.content), 300)}`;
  const here = o.candidates.filter((m) => savedHere(m, o.threadId));
  const others = o.candidates.filter((m) => !savedHere(m, o.threadId));
  const memoryLines = here.length
    ? ['Saved during this chat:', ...here.map(line), ...(others.length ? ['Saved earlier:', ...others.map(line)] : [])]
    : others.map(line);
  const user = [
    o.wantSummary ? `Summary so far: ${o.summary ? clip(o.summary, 2400) : '(none yet)'}` : '',
    o.wantMemory ? `Saved memories (from all of the user's chats; for memory_ops only):\n${memoryLines.join('\n') || '(none)'}` : '',
    `New messages:\n${o.batch.map(curatorLine).join('\n')}`,
  ].filter(Boolean).join('\n\n');
  return [{ role: 'system', content: rules.join('\n') }, { role: 'user', content: user }];
}

const cleanMemory = (v: unknown) => {
  const s = collapse(v);
  return s && s.length <= MAX_MEMORY_CHARS ? s : null;
};

const importanceOf = (v: unknown, fallback: number) =>
  Number.isFinite(Number(v)) && v !== null && v !== '' ? Math.max(1, Math.min(5, Math.round(Number(v)))) : fallback;

function cleanSummary(v: unknown): string | null {
  const s = collapse(v);
  return s.length >= 20 ? clip(s, SUMMARY_CHARS) : null;
}

const cleanList = (v: unknown, max: number, len: number) =>
  (Array.isArray(v) ? v : []).map((x) => collapse(typeof x === 'string' ? x : isObject(x) ? x.text : ''))
    .filter(Boolean).slice(0, max).map((s) => clip(s, len));

const SAFETY_TOPICS = new Set(['injury', 'health']);
const isSafety = (m: any) => SAFETY_TOPICS.has(m?.topic) && Number(m?.importance ?? 3) >= 4;

/**
 * The topic and importance of a merged row. Importance is never below its strongest member's, and a safety
 * memory (injury or health, importance 4+) keeps its topic, so a merge can never unpin it from the prompt. An
 * unknown topic keeps the kept row's.
 */
export function mergedAttributes(op: any, members: any[], keep: any): { topic: string; importance: number } {
  const strongest = Math.max(...members.map((m) => Number(m.importance ?? 3)));
  const importance = Math.max(importanceOf(op?.importance, strongest), strongest);
  const asked = typeof op?.topic === 'string' ? op.topic.trim().toLowerCase() : '';
  const wanted = MEMORY_TOPICS.has(asked) ? asked : memoryTopic(keep.topic);
  const safety = members.filter(isSafety).sort((a, b) => Number(b.importance) - Number(a.importance))[0];
  return { topic: safety && !SAFETY_TOPICS.has(wanted) ? safety.topic : wanted, importance };
}

/** The version guard of a merge: every member at the version it was read at (coach_memory_apply_v1 `versions`). */
function versionsOf(members: any[]): { versions?: Record<string, number> } {
  const known = members.filter((m) => Number.isInteger(Number(m.version)) && m.version != null);
  return known.length === members.length ? { versions: Object.fromEntries(known.map((m) => [m.id, Number(m.version)])) } : {};
}

const oldestFirst = (a: any, b: any) => (tsKey(a.created_at) - tsKey(b.created_at)) || String(a.id).localeCompare(String(b.id));

/** A merge into the oldest member, with its guards. */
function mergeOp(members: any[], content: string, op: any = {}) {
  const [keep, ...others] = [...members].sort(oldestFirst);
  const { topic, importance } = mergedAttributes(op, members, keep);
  return { keep, others, topic, importance, op: { op: 'merge', keep_id: keep.id, ids: others.map((m) => m.id), content, topic, importance, ...versionsOf(members) } };
}

/** A merged text restates its members and what the user said in this batch, and is never a passing state. */
function mergeAllowed(content: string, members: PoolMemory[], guard: GuardContext): boolean {
  const own = memoryTokens(content);
  if (!own.length) return false;
  const pooled = new Set([...members.flatMap((m) => memoryTokens(m.content)), ...guard.userTokens]);
  if (own.filter((t) => pooled.has(t)).length / own.length < 0.8) return false;
  if (TRANSIENT.test(content) || METRIC_READING.test(content)) return false;
  return !isSensitive(content) || members.some((m) => isSensitive(m.content)) || /\bremember\b/i.test(guard.userText);
}

/**
 * The curator's ops, resolved against this batch's refs and held to the §6 guards. Adds that near-duplicate an
 * existing row become a confirm or an update of it (number-aware), so the store never gains a second copy. A
 * `merge` folds duplicates (typically a memory the save_memory tool wrote in this chat) into the oldest row; and an
 * update whose new text fully restates a memory saved in this chat (or that is itself such a memory, restating an
 * older one) becomes that merge too, so one fact never ends up in two rows. Updates, retires and merges carry the
 * version each row was read at, so a row another writer changed or forgot meanwhile is left alone (`stale`).
 */
export function resolveCuratorOps(raw: unknown, refs: Refs, pool: PoolMemory[], guard: GuardContext, threadId: string | null = null): any[] {
  const out: any[] = [];
  const touched = new Set<string>();
  const byId = (id: string | undefined) => (id ? pool.find((p) => p.id === id && !p.pending) : undefined);
  const bump = (row: PoolMemory) => { if (row.version != null) row.version = Number(row.version) + 1; };
  const merge = (members: PoolMemory[], content: string, op: any = {}) => {
    const m = mergeOp(members, content, op);
    out.push(m.op);
    Object.assign(m.keep, { content, topic: m.topic, importance: m.importance });
    bump(m.keep);
    for (const r of members) touched.add(r.id);
    for (const r of m.others) pool.splice(pool.indexOf(r), 1);
  };
  // An update of `row` to `content`, or a merge when that content also restates a memory saved in this chat.
  const update = (row: PoolMemory, content: string, importance: number | null) => {
    const fold = threadId ? pool.find((p) => !p.pending && p.id !== row.id && !touched.has(p.id) && sameFamily(p.topic, row.topic)
      && (savedHere(p, threadId) || savedHere(row, threadId)) && covers(content, p.content)) : undefined;
    if (fold) return merge([row, fold], content, importance != null ? { importance } : {});
    out.push({ op: 'update', id: row.id, content, ...(importance != null ? { importance } : {}), ...versionGuard(row) });
    row.content = content;
    if (importance != null) row.importance = importance;
    bump(row);
    touched.add(row.id);
  };
  for (const op of Array.isArray(raw) ? raw.slice(0, 16) : []) {
    if (out.length >= MAX_OPS) break;
    if (!isObject(op)) continue;
    if (op.op === 'add') {
      const content = cleanMemory(op.content);
      if (!content || guardMemoryContent(content, guard)) continue;
      const topic = memoryTopic(op.topic);
      const importance = importanceOf(op.importance, 3);
      const dup = findNearDuplicate(content, topic, pool);
      if (dup) {
        const row = dup.row;
        if (row.pending || touched.has(row.id)) continue;
        if (dup.kind === 'supersede' || dup.kind === 'longer') {
          update(row, content, Math.max(row.importance, importance));
        } else {
          out.push({ op: 'confirm', id: row.id });
          touched.add(row.id);
        }
        continue;
      }
      out.push({ op: 'add', content, topic, importance, source: 'curator' });
      pool.push({ id: `pending:${pool.length}`, content, topic, importance, pending: true });
    } else if (op.op === 'update') {
      const row = byId(refs.resolve(op.ref));
      if (!row || touched.has(row.id)) continue;
      const content = op.content == null || op.content === '' ? null : cleanMemory(op.content);
      if (op.content != null && op.content !== '' && !content) continue;
      const importance = op.importance == null ? null : importanceOf(op.importance, row.importance);
      if (content ? guardMemoryContent(content, guard) : !mentions(row.content, guard.userTokens)) continue;
      const sameText = content ? lineKey(content) === lineKey(row.content) : true;
      if (sameText && (importance == null || importance === row.importance)) {
        if (!mentions(row.content, guard.userTokens)) continue;
        out.push({ op: 'confirm', id: row.id });
        touched.add(row.id);
      } else if (content && !sameText) {
        update(row, content, importance);
      } else {
        out.push({ op: 'update', id: row.id, ...(importance != null ? { importance } : {}), ...versionGuard(row) });
        if (importance != null) row.importance = importance;
        bump(row);
        touched.add(row.id);
      }
    } else if (op.op === 'merge') {
      const ids = [...new Set((Array.isArray(op.refs) ? op.refs : []).map((r: unknown) => refs.resolve(r)))];
      const members = ids.map((id) => byId(id as string | undefined)).filter((m): m is PoolMemory => !!m && !touched.has(m.id));
      if (members.length < 2 || members.length !== ids.length) continue;
      const content = cleanMemory(op.content);
      if (!content || !mergeAllowed(content, members, guard)) continue;
      merge(members, content, op);
    } else if (op.op === 'confirm') {
      const row = byId(refs.resolve(op.ref));
      if (!row || touched.has(row.id) || !mentions(row.content, guard.userTokens)) continue;
      out.push({ op: 'confirm', id: row.id });
      touched.add(row.id);
    } else if (op.op === 'retire') {
      // Retiring needs a contradiction in the user's own words: at least the memory's subject must come up.
      const row = byId(refs.resolve(op.ref));
      if (!row || touched.has(row.id) || !mentions(row.content, guard.userTokens)) continue;
      out.push({ op: 'retire', id: row.id, reason: clip(collapse(op.reason), 120) || 'contradicted', tokens: memoryTokens(row.content), ...versionGuard(row) });
      touched.add(row.id);
      pool.splice(pool.indexOf(row), 1);
    }
  }
  return out;
}

async function memoryCandidates(d: CoachDeps, userId: string, threadId: string, userText: string, pool: PoolMemory[]): Promise<PoolMemory[]> {
  const chosen = new Map<string, PoolMemory>();
  const add = (m: PoolMemory | undefined) => {
    if (m && !m.pending && chosen.size < MAX_CANDIDATES && !chosen.has(m.id)) chosen.set(m.id, m);
  };
  const real = pool.filter((p) => !p.pending);
  real.filter((m) => m.source === 'tool' && m.source_thread_id === threadId).forEach(add);
  const ranked = await d.rest.rpc('coach_memories_ranked_v1', {
    p_user: userId, p_query: userText.slice(0, 4000), p_limit: 12, p_pin_safety: false,
  }).catch(() => null);
  for (const r of Array.isArray(ranked?.memories) ? ranked.memories : []) add(real.find((p) => p.id === r.id));
  real.forEach(add);
  return [...chosen.values()];
}

async function loadTombstones(d: CoachDeps, userId: string): Promise<Set<string>[]> {
  const since = new Date(d.now() - 365 * 86_400_000).toISOString();
  const rows = await d.rest.select('coach_memory_events',
    `user_id=eq.${userId}&op=eq.forget&created_at=gte.${enc(since)}&order=created_at.desc&limit=1000&select=tokens`);
  return rows.map((r: any) => new Set<string>((Array.isArray(r.tokens) ? r.tokens : []).filter((t: unknown) => typeof t === 'string')))
    .filter((s: Set<string>) => s.size > 0);
}

export async function runMaintain(d: CoachDeps, userId: string, threadId: string): Promise<MaintainResult> {
  const idle = (status: MaintainResult['status']): MaintainResult => ({ status, summarized: false, memoryOps: 0, consolidated: false });
  const claim = await d.rest.rpc('coach_thread_claim_v1', { p_user: userId, p_thread: threadId, p_lease_seconds: LEASE_SECONDS });
  if (claim?.claimed !== true || !claim.token) return idle('busy');
  const token = claim.token;
  let published = false;
  const publish = async (patch: Record<string, unknown>, ops: unknown[]) => {
    published = true;
    return await d.rest.rpc('coach_thread_publish_v1', { p_user: userId, p_thread: threadId, p_token: token, p_patch: patch, p_ops: ops });
  };
  try {
    // 2. Everything newer than the older of the two cursors. Blocked turns are loaded only to be counted.
    const summaryCut: string | null = claim.summary_through ?? null;
    const curatedCut: string | null = claim.curated_through ?? null;
    const mineAfter = laterOf(curatedCut, claim.memory_floor_at);
    const loadAfter = summaryCut && curatedCut ? (tsKey(summaryCut) <= tsKey(curatedCut) ? summaryCut : curatedCut) : null;
    const loaded = await d.rest.select('coach_messages',
      `user_id=eq.${userId}&thread_id=eq.${threadId}${loadAfter ? `&created_at=gt.${enc(loadAfter)}` : ''}`
      + `&order=created_at.asc,id.asc&limit=${LOAD_MESSAGES}&select=id,role,content,meta,created_at,blocked`);
    const rows = loaded.filter((r: any) => r.blocked !== true);
    const newForSummary = (m: any) => !summaryCut || tsKey(m.created_at) > tsKey(summaryCut);
    const newForMemory = (m: any) => m.role === 'user' && (!mineAfter || tsKey(m.created_at) > tsKey(mineAfter));

    // Blocked turns are never folded, but they count as handled: the summary cursor moves over the ones that
    // directly follow what has been folded, so `pendingMessages` reaches 0 and a chat that ends on a blocked
    // turn is not offered for maintenance again on every launch.
    const overBlocked = (through: string | null): string | null => {
      let end = through;
      for (const m of loaded) {
        if (!newForSummary(m) || (end && tsKey(m.created_at) <= tsKey(end))) continue;
        if (m.blocked !== true) break;
        end = m.created_at;
      }
      return end;
    };
    const cursorPatch = (through: string | null, curated: string | null): Record<string, unknown> => {
      const patch: Record<string, unknown> = {};
      if (through) {
        const folded = loaded.filter((m: any) => newForSummary(m) && tsKey(m.created_at) <= tsKey(through)).length;
        Object.assign(patch, { summary_through: through, summary_messages: Number(claim.summary_messages ?? 0) + folded });
      }
      const next = laterOf(curated, through);
      if (next && (!curatedCut || tsKey(next) > tsKey(curatedCut))) patch.curated_through = next;
      return patch;
    };

    // 3. Memory ops on any new user message; the summary on 4 new messages, 2 when there is none yet, or whatever
    // is left once the chat has been quiet for 10 minutes (so the last turns of a finished chat are folded too).
    const wantMemory = rows.some(newForMemory);
    const pending = rows.filter(newForSummary).length;
    const lastAt: unknown = claim.last_message_at ?? loaded[loaded.length - 1]?.created_at;
    const quiet = Number.isFinite(tsKey(lastAt)) && d.now() * 1000 - tsKey(lastAt) >= QUIET_MS * 1000;
    const wantSummary = summaryDue(pending, Boolean(claim.summary), quiet);
    if (!wantMemory && !wantSummary) {
      // Nothing new from the user to mine: the memory cursor steps over what was read (Sana's replies, blocked
      // turns, messages older than the forget-all floor), so `needsMaintenance` stops offering the chat until
      // something new arrives or it goes quiet with turns left to fold.
      await publish(cursorPatch(overBlocked(null), loaded.length ? loaded[loaded.length - 1].created_at : null), []);
      return idle('skipped');
    }

    const pool: PoolMemory[] = wantMemory ? (await activeMemories(d, userId)).map((r: any) => ({
      id: r.id, content: r.content, topic: r.topic, importance: Number(r.importance ?? 3), source: r.source,
      source_thread_id: r.source_thread_id ?? null, created_at: r.created_at, updated_at: r.updated_at,
      ...(r.version != null ? { version: Number(r.version) } : {}),
    })) : [];
    const tombstones = wantMemory ? await loadTombstones(d, userId) : [];
    let summary: string | null = claim.summary ?? null;
    let topics: string[] | null = null;
    let loops: string[] | null = null;
    let summaryThrough: string | null = null;
    let curatedThrough: string | null = null;
    const ops: any[] = [];

    // 4-7. Batches fold into the summary oldest first; each batch's ops are guarded before they are kept.
    for (const batch of maintenanceBatches(rows)) {
      const end = batch[batch.length - 1].created_at;
      const batchSummary = wantSummary && batch.some(newForSummary);
      const fresh = batch.filter(newForMemory);
      const batchMemory = wantMemory && fresh.length > 0;
      if (!batchSummary && !batchMemory) {
        curatedThrough = end;
        continue;
      }
      const userText = fresh.map((m: any) => collapse(m.content)).join('\n');
      const candidates = batchMemory ? await memoryCandidates(d, userId, threadId, userText, pool) : [];
      const refs = new Refs('m');
      candidates.forEach((c) => refs.ref(c.id));
      const raw = await callUtility(d, userId, 'curator',
        curatorPrompt({ summary, batch, candidates, refs, wantSummary: batchSummary, wantMemory: batchMemory, threadId }));
      if (!raw) break;
      if (batchSummary) {
        const next = cleanSummary(raw.summary);
        if (!next) break;
        summary = next;
        topics = cleanList(raw.topics, 6, 40).map((t) => t.toLowerCase());
        loops = cleanList(raw.open_loops, 3, 160);
        summaryThrough = end;
      }
      if (batchMemory) {
        ops.push(...resolveCuratorOps(raw.memory_ops, refs, pool, { userTokens: tokenSet(userText), userText, tombstones }, threadId));
      }
      curatedThrough = end;
    }

    // 8. Publish together; each cursor moves only over the work that ran (and the blocked turns right after it).
    const patch = cursorPatch(overBlocked(summaryThrough), curatedThrough);
    if (summaryThrough) {
      Object.assign(patch, { summary, summary_topics: topics ?? [], open_loops: loops ?? [], summarized_at: new Date(d.now()).toISOString() });
    }
    if (!Object.keys(patch).length && !ops.length) {
      await publish({}, []);
      return idle('skipped');
    }
    const result = await publish(patch, ops);
    if (result?.applied !== true) return idle('busy');
    // memory_reset: a forget or forget-all landed while this pass ran. Publish applied the summary but none of the
    // ops and kept curated_through, so the next pass mines those messages again against the new floor and tombstones.
    const reset = result.reason === 'memory_reset';
    const memoryOps = reset ? 0 : (Array.isArray(result.ops) ? result.ops : []).filter((o: any) => o?.applied && o.op !== 'evict').length;
    // 9. The periodic consolidation when it is due; otherwise, after memory work, a targeted pass over any pair of
    // memories that now look like one fact told twice (a tool save next to the curator's copy, say).
    const full = await consolidate(d, userId);
    const consolidated = full ?? (wantMemory && !reset ? await dedupePairs(d, userId) : false);
    return { status: 'done', summarized: Boolean(summaryThrough), memoryOps, consolidated };
  } finally {
    if (!published) {
      try { await publish({}, []); } catch { /* the lease expires on its own */ }
    }
  }
}

// 9. Consolidation: merges and retires duplicates across every active memory.

const consolidationSystem = () => [
  "You tidy a user's long-term memory for Sana, a health and fitness assistant. You get every saved memory, labelled m1, m2, ...",
  'Reply with JSON only: {"ops": [...]} with at most 12 of {"op":"merge","refs":["m1","m4"],"content":"...","topic":"...","importance":1-5} '
    + 'and {"op":"retire","ref":"m7","reason":"superseded|duplicate"}.',
  'merge two or more memories that state the same fact or one fact in pieces; content is the combined fact in the third person '
    + '("User ..."), at most 200 characters, keeping every date and figure, the highest importance and an injury or health topic. '
    + 'retire a memory only when another memory says the same or replaces it with newer information. Never invent facts. '
    + 'No ops is fine when the memory is already tidy.',
].join('\n');

const DEDUPE_NOTE = 'These memories were picked because some of them look alike. Merge the ones that state the same fact (or one fact '
  + 'in pieces) and leave the others alone; they may be different facts that only share words.';

export function resolveConsolidationOps(raw: unknown, refs: Refs, rows: any[]): any[] {
  const out: any[] = [];
  const used = new Set<string>();
  const byId = new Map(rows.map((r) => [r.id, r]));
  for (const op of Array.isArray(raw) ? raw.slice(0, 12) : []) {
    if (!isObject(op)) continue;
    if (op.op === 'merge') {
      const ids = [...new Set((Array.isArray(op.refs) ? op.refs : []).map((r: unknown) => refs.resolve(r)).filter((id: unknown): id is string => !!id))];
      if (ids.length < 2 || ids.some((id) => used.has(id))) continue;
      const members = ids.map((id) => byId.get(id)).filter(Boolean);
      if (members.length < 2) continue;
      const content = cleanMemory(op.content);
      if (!content) continue;
      // The merged text may only restate its members.
      const pooled = new Set(members.flatMap((m: any) => memoryTokens(m.content)));
      const own = memoryTokens(content);
      if (!own.length || own.filter((t) => pooled.has(t)).length / own.length < 0.6) continue;
      out.push(mergeOp(members, content, op).op);
      ids.forEach((id) => used.add(id));
    } else if (op.op === 'retire') {
      const id = refs.resolve(op.ref);
      const row = id ? byId.get(id) : undefined;
      if (!row || used.has(row.id)) continue;
      // Only a row another surviving memory already covers.
      const mine = tokenSet(row.content);
      const covered = rows.some((r) => r.id !== row.id && !used.has(r.id) && tokensNearMatch(mine, tokenSet(r.content)));
      if (!covered) continue;
      out.push({ op: 'retire', id: row.id, reason: op.reason === 'superseded' ? 'superseded' : 'duplicate', tokens: [...mine], ...versionGuard(row) });
      used.add(row.id);
    }
  }
  return out;
}

const memoryLine = (refs: Refs) => (r: any) =>
  `${refs.ref(r.id)} [${r.topic}, importance ${r.importance}, ${day(r.created_at)}] ${clip(collapse(r.content), 300)}`;

/** Re-reviewing the same memories gains nothing: within 6 h of the last pass it takes 8 new or changed ones. */
const CONSOLIDATION_GAP_MS = 6 * 3_600_000;
const CONSOLIDATION_GROWTH = 8;

/**
 * Whether the count-based pass may be claimed now. coach_consolidation_claim_v1 claims above 120 active memories
 * however recent the last pass was, so on its own a user near the 200 cap would get a full pass after every turn.
 */
async function consolidationDue(d: CoachDeps, userId: string): Promise<boolean> {
  const [state] = await d.rest.select('coach_user_state', `user_id=eq.${userId}&select=consolidated_at`);
  const at = state?.consolidated_at;
  if (typeof at !== 'string' || !(d.now() - Date.parse(at) < CONSOLIDATION_GAP_MS)) return true;
  const since = enc(quoted(at));
  const changed = await d.rest.select('coach_memory_items',
    `user_id=eq.${userId}&retired_at=is.null&or=(created_at.gt.${since},updated_at.gt.${since})&select=id&limit=${CONSOLIDATION_GROWTH}`);
  return changed.length >= CONSOLIDATION_GROWTH;
}

/** The count-based pass: true when it ran, false when it was claimed but failed, null when it was not due. */
async function consolidate(d: CoachDeps, userId: string): Promise<boolean | null> {
  try {
    if (!(await consolidationDue(d, userId))) return null;
    if ((await d.rest.rpc('coach_consolidation_claim_v1', { p_user: userId, p_lease_seconds: LEASE_SECONDS })) !== true) return null;
    // Without budget the lease simply expires and a later pass tries again.
    if (!(await takeUtilityUnits(d, userId, 1))) return false;
    const rows = await activeMemories(d, userId, 200);
    const refs = new Refs('m');
    const raw = await callUtility(d, userId, 'consolidation', [
      { role: 'system', content: consolidationSystem() },
      { role: 'user', content: `Memories:\n${rows.map(memoryLine(refs)).join('\n')}` },
    ], { prepaid: true });
    // A failed pass still closes the lease, so a broken reply is not retried on every maintenance call.
    const ops = raw ? resolveConsolidationOps(raw.ops, refs, rows) : [];
    await applyMemoryOps(d, userId, [...ops, { op: 'consolidated' }], 'consolidator');
    return raw !== null;
  } catch {
    return false;
  }
}

const DEDUPE_WINDOW_MS = 30 * 60_000;
const DEDUPE_MAX_ROWS = 12;

/** The members of every pair of active memories that look like duplicates (`likelyDuplicates`) with a fresh member, at most `max` rows. */
export function duplicatePairs(rows: any[], fresh: (m: any) => boolean, max = DEDUPE_MAX_ROWS): any[] {
  const picked = new Map<string, any>();
  const recent = rows.filter(fresh);
  for (const a of recent) {
    for (const b of rows) {
      if (a.id === b.id || (picked.has(a.id) && picked.has(b.id)) || !likelyDuplicates(a, b)) continue;
      if (picked.size + (picked.has(a.id) ? 0 : 1) + (picked.has(b.id) ? 0 : 1) > max) continue;
      picked.set(a.id, a);
      picked.set(b.id, b);
    }
  }
  return [...picked.values()];
}

/**
 * The targeted consolidation (separate from the count-based one): when a maintenance pass leaves two memories that
 * look like one fact, the cheap model sees just those and may merge them. At most once per 30 minutes per user: the
 * pass holds coach_user_state.consolidation_until for that long (the count-based claim waits for it too). Only pairs
 * with a member written since the last review are offered, so a pair the model left alone is not offered again; the
 * last review is the last full pass (`consolidated_at`) or the start of the last targeted one (its lease minus 30
 * minutes), so a pair that forms while the lease is held is still reviewed by the next pass.
 */
async function dedupePairs(d: CoachDeps, userId: string): Promise<boolean> {
  try {
    const [state] = await d.rest.select('coach_user_state', `user_id=eq.${userId}&select=consolidated_at,consolidation_until`);
    const until = tsKey(state?.consolidation_until);
    if (until > d.now() * 1000) return false;
    const reviewed = Math.max(tsKey(state?.consolidated_at) || -Infinity, Number.isFinite(until) ? until - DEDUPE_WINDOW_MS * 1000 : -Infinity);
    const rows = await activeMemories(d, userId, 200);
    const fresh = (m: any) => Math.max(tsKey(m.created_at) || -Infinity, tsKey(m.updated_at) || -Infinity) > reviewed;
    const picked = duplicatePairs(rows, fresh);
    if (!picked.length) return false;
    const stamp = new Date(d.now()).toISOString();
    await d.rest.upsert('coach_user_state', { user_id: userId }, { onConflict: 'user_id', prefer: 'resolution=ignore-duplicates,return=minimal' });
    const leased = await d.rest.patch('coach_user_state',
      { consolidation_until: new Date(d.now() + DEDUPE_WINDOW_MS).toISOString(), updated_at: stamp },
      `user_id=eq.${userId}&or=(consolidation_until.is.null,consolidation_until.lte.${enc(quoted(stamp))})&select=user_id`);
    if (!Array.isArray(leased) || !leased.length) return false;
    const refs = new Refs('m');
    const raw = await callUtility(d, userId, 'consolidation', [
      { role: 'system', content: `${consolidationSystem()}\n${DEDUPE_NOTE}` },
      { role: 'user', content: `Memories:\n${picked.map(memoryLine(refs)).join('\n')}` },
    ]);
    if (!raw) return false;
    const ops = resolveConsolidationOps(raw.ops, refs, picked);
    if (ops.length) await applyMemoryOps(d, userId, ops, 'consolidator');
    return true;
  } catch {
    return false;
  }
}
