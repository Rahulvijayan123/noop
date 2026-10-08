// Sana's context library (docs/COACH_MEMORY.md §1, §4 and §5 Recall).
//
// The RLM idea adapted to a phone-side tool loop: the model never gets the user's history pasted in. It gets
// a manifest of what exists (`POST context`, no contents), typed inspection tools with capped results
// (`context/search`, `context/thread`), and one recursive step, `context/recall`: lexical candidates (or the
// thread summaries of a date window) are partitioned into at most four chunks, a cheap model maps over them
// in one concurrent wave, and a reduce step merges the notes only when they do not fit as they are. The
// answer is evidence for the chat model, never the reply, and it reports its coverage. Only recall calls a
// model; the other three routes are database reads.
import {
  callUtility, type ChatTurn, clampInt, clip, collapse, type CoachDeps, day, enc, fail, isObject, iso, quoted,
  readOptionalJson, Refs, takeUtilityUnits, tsKey, utilityConfigured, uuidOf, windowBound,
} from './coach_llm.ts';
import { publicMemory } from './coach_memory.ts';
import { decodeCursor, encodeCursor, loadThread, olderThan } from './coach_store.ts';

export async function contextRoute(req: Request, userId: string, sub: string[], d: CoachDeps): Promise<Response> {
  if (req.method !== 'POST') return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  if (sub.length > 1) return Response.json({ error: 'not_found' }, { status: 404 });
  const body = await readOptionalJson(req);
  if (sub.length === 0) return Response.json(await manifest(d, userId, body));
  if (sub[0] === 'search') return Response.json(await search(d, userId, body));
  if (sub[0] === 'thread') return Response.json(await threadExcerpt(d, userId, body));
  if (sub[0] === 'recall') return Response.json(await recall(d, userId, body));
  return Response.json({ error: 'not_found' }, { status: 404 });
}

const num = (v: unknown) => (Number.isFinite(Number(v)) ? Number(v) : 0);
const str = (v: unknown) => (typeof v === 'string' ? v : null);

function optionalThread(v: unknown): string | null {
  if (v == null || v === '') return null;
  const id = uuidOf(v);
  if (!id) throw fail('invalid_id', 400);
  return id;
}

function windowOf(body: Record<string, any>, now: number): { from: string | null; to: string | null } {
  const from = body.from == null || body.from === '' ? null : windowBound(body.from);
  const to = body.to == null || body.to === '' ? null : windowBound(body.to, true);
  if ((body.from != null && body.from !== '' && !from) || (body.to != null && body.to !== '' && !to)) throw fail('invalid_window', 400);
  if (!from && body.days != null) {
    const days = clampInt(body.days, 1, 4000, 0);
    if (days) return { from: new Date(now - days * 86_400_000).toISOString(), to };
  }
  return { from, to };
}

/** Open loops are stored as strings (or `{text}` objects from other writers). */
function loopTexts(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.map((e) => (typeof e === 'string' ? e : isObject(e) && typeof e.text === 'string' ? e.text : ''))
    .map((s) => collapse(s)).filter(Boolean);
}

// ------------------------------------------------------------------------------------------------
// POST context: the manifest
// ------------------------------------------------------------------------------------------------

async function manifest(d: CoachDeps, userId: string, body: Record<string, any>) {
  const threadId = optionalThread(body.threadId);
  const question = collapse(body.question).slice(0, 2000) || null;
  const m = await d.rest.rpc('coach_context_manifest_v1', { p_user: userId, p_thread: threadId, p_query: question }) ?? {};
  const t = isObject(m.thread) ? m.thread : null;
  const lib = isObject(m.library) ? m.library : {};
  const list = (v: unknown) => (Array.isArray(v) ? v.filter(isObject) : []);
  return {
    memories: list(m.memories).map(publicMemory),
    memoryCount: num(m.memory_count),
    memoryTopics: isObject(m.memory_topics) ? m.memory_topics : {},
    thread: t && {
      id: t.id, title: str(t.title), summary: str(t.summary), summaryThrough: iso(t.summary_through),
      summaryMessages: num(t.summary_messages), messageCount: num(t.message_count), openLoops: loopTexts(t.open_loops),
    },
    library: {
      threadCount: num(lib.thread_count), firstAt: iso(lib.first_at), lastAt: iso(lib.last_at),
      recent: list(lib.recent).map((r) => ({ id: r.id, title: str(r.title), lastMessageAt: iso(r.last_message_at) })),
      relevant: list(lib.relevant).map((r) => ({
        id: r.id, title: str(r.title), lastMessageAt: iso(r.last_message_at), snippet: str(r.snippet),
      })),
    },
    openLoops: list(m.open_loops).map((l) => ({ threadId: l.thread_id ?? null, title: str(l.title), text: collapse(l.text) }))
      .filter((l) => l.text),
    memoryRevision: num(m.memory_revision),
  };
}

// ------------------------------------------------------------------------------------------------
// POST context/search
// ------------------------------------------------------------------------------------------------

async function search(d: CoachDeps, userId: string, body: Record<string, any>) {
  const query = collapse(body.query).slice(0, 500);
  const { from, to } = windowOf(body, d.now());
  const limit = clampInt(body.limit, 1, 50, 20);
  const exclude = optionalThread(body.excludeThreadId);
  const res = await d.rest.rpc('coach_search_v1', {
    p_user: userId, p_query: query, p_limit: limit, p_thread_limit: query ? 8 : Math.max(8, Math.min(30, limit)),
    p_exclude_thread: exclude, p_from: from, p_to: to,
  }) ?? {};
  const terms: string[] = Array.isArray(res.terms) ? res.terms : [];
  // A query with no searchable words (only stop words or punctuation) makes the RPC browse the newest chats.
  // Browsing is for an empty query; here nothing matched, and recent chats must not read as matches.
  const noTerms = query !== '' && !terms.length;
  const threads: any[] = !noTerms && Array.isArray(res.threads) ? res.threads.filter(isObject) : [];
  const hits: any[] = !noTerms && Array.isArray(res.hits) ? res.hits.filter(isObject) : [];
  const titles = new Map<string, string | null>(threads.map((t) => [String(t.thread_id), str(t.title)]));
  const missing = [...new Set(hits.map((h) => String(h.thread_id)).filter((id) => !titles.has(id) && uuidOf(id)))];
  if (missing.length) {
    const rows = await d.rest.select('coach_threads', `user_id=eq.${userId}&id=in.(${missing.join(',')})&select=id,title`);
    for (const r of rows) titles.set(String(r.id), str(r.title));
  }
  return {
    terms,
    droppedTerms: Array.isArray(res.dropped_terms) ? res.dropped_terms : [],
    totalHits: noTerms ? 0 : num(res.total_hits),
    months: !noTerms && Array.isArray(res.months) ? res.months.filter(isObject).map((m: any) => ({ month: String(m.month), hits: num(m.hits) })) : [],
    hits: hits.map((h) => ({
      threadId: h.thread_id, title: titles.get(String(h.thread_id)) ?? null, at: iso(h.created_at), role: h.role, snippet: str(h.snippet),
    })),
    threads: threads.map((t) => ({
      threadId: t.thread_id, title: str(t.title), lastMessageAt: iso(t.last_message_at), hits: num(t.hits),
      snippet: str(t.snippet), summary: str(t.summary), topics: Array.isArray(t.topics) ? t.topics : [],
    })),
    ...(noTerms ? { noTerms: true } : {}),
  };
}

// ------------------------------------------------------------------------------------------------
// POST context/thread: one capped window of an earlier chat
// ------------------------------------------------------------------------------------------------

const EXCERPT_CHARS = 8_000;
const EXCERPT_MESSAGE_CHARS = 1_500;
const MATCH_WINDOWS = 4;

/** A plain OR tsquery of the query's words; only letters and digits survive, so it can never be malformed. */
export function orQuery(text: string, max = 12): string {
  const words = [...new Set((text.normalize('NFKC').toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []).filter((w) => w.length > 1))];
  return words.slice(0, max).join(' | ');
}

async function threadExcerpt(d: CoachDeps, userId: string, body: Record<string, any>) {
  const threadId = uuidOf(body.threadId);
  if (!threadId) throw fail('invalid_id', 400);
  const query = collapse(body.query).slice(0, 300);
  const cursor = body.cursor ? decodeCursor(body.cursor) : null;
  const limit = clampInt(body.limit, 1, 40, 16);
  const thread = await loadThread(d, userId, threadId, 'id,title,created_at,last_message_at,message_count,summary');
  if (!thread) throw fail('thread_not_found', 404);
  const info = {
    id: thread.id, title: str(thread.title), createdAt: iso(thread.created_at), lastMessageAt: iso(thread.last_message_at),
    messageCount: num(thread.message_count), summary: str(thread.summary),
  };
  const base = `user_id=eq.${userId}&thread_id=eq.${threadId}&blocked=is.false`;
  const cols = 'select=id,role,content,created_at';
  const line = (r: any) => ({ role: r.role, at: iso(r.created_at), content: clip(String(r.content ?? ''), EXCERPT_MESSAGE_CHARS) });

  const tsq = query && !cursor ? orQuery(query) : '';
  if (tsq) {
    const matches = await d.rest.select('coach_messages',
      `${base}&search=fts(english).${enc(tsq)}&order=created_at.desc,id.desc&limit=${MATCH_WINDOWS}&${cols}`);
    if (matches.length) {
      // Each match with the message either side of it.
      const sides = await Promise.all(matches.map((m: any) => {
        const at = enc(quoted(m.created_at));
        return Promise.all([
          d.rest.select('coach_messages', `${base}&or=(created_at.lt.${at},and(created_at.eq.${at},id.lt.${m.id}))&order=created_at.desc,id.desc&limit=1&${cols}`),
          d.rest.select('coach_messages', `${base}&or=(created_at.gt.${at},and(created_at.eq.${at},id.gt.${m.id}))&order=created_at.asc,id.asc&limit=1&${cols}`),
        ]);
      }));
      const ranked = [...matches, ...sides.flat(2)];
      const picked = new Map<string, any>();
      let used = 0;
      let truncated = false;
      for (const r of ranked) {
        if (picked.has(r.id)) continue;
        const size = line(r).content.length;
        if (picked.size && used + size > EXCERPT_CHARS) { truncated = true; continue; }
        picked.set(r.id, r);
        used += size;
      }
      const ordered = [...picked.values()].sort((a, b) => (tsKey(a.created_at) - tsKey(b.created_at)) || String(a.id).localeCompare(String(b.id)));
      return { thread: info, messages: ordered.map(line), window: 'around_matches', hasMore: truncated || matches.length === MATCH_WINDOWS, nextCursor: null };
    }
  }

  const rows = await d.rest.select('coach_messages',
    `${base}${cursor ? olderThan(cursor) : ''}&order=created_at.desc,id.desc&limit=${limit + 1}&${cols}`);
  const taken: any[] = [];
  let used = 0;
  for (const r of rows.slice(0, limit)) {
    const size = line(r).content.length;
    if (taken.length && used + size > EXCERPT_CHARS) break;
    taken.push(r);
    used += size;
  }
  const oldest = taken[taken.length - 1];
  const hasMore = rows.length > taken.length;
  return {
    thread: info, messages: taken.reverse().map(line), window: 'recent', hasMore,
    nextCursor: hasMore && oldest ? encodeCursor(oldest.created_at, oldest.id) : null,
  };
}

// ------------------------------------------------------------------------------------------------
// POST context/recall: partition, map, reduce
// ------------------------------------------------------------------------------------------------

const RECALL_DEADLINE_MS = 18_000;
const MAX_CHUNKS = 4;
const CHUNK_CHARS = 10_000;
const SUMMARIES_PER_CHUNK = 12;
const RECALL_MESSAGE_CHARS = 1_200;
const NEIGHBOUR_WINDOW_MS = 15 * 60_000;
const DIRECT_NOTES_CHARS = 2_500;

interface Section { threadId: string; ref: string; title: string; at: string | null; text: string; messages: number; hitsLeft: number }
interface Chunk { text: string; sections: Section[] }
interface Note { threadId: string; text: string }

const MAP_SYSTEM = (
  'You read excerpts from a user\'s earlier chats with Sana, a health and fitness assistant, and pull out what bears on a question. '
  + 'Reply with JSON only: {"relevant": true or false, "notes": ["..."]}. '
  + 'Rules: at most 5 notes, each at most 220 characters, each starting with the date (YYYY-MM-DD) of the message or chat it comes from, '
  + 'then the chat\'s ref in brackets, like "2026-08-01 [t2] User planned a 16-week marathon block". '
  + 'Keep figures, plans and decisions exactly as written and say whether the user or Sana said it. '
  + 'Use only the excerpts. If nothing in them bears on the question, reply {"relevant": false, "notes": []}.'
);

const REDUCE_SYSTEM = (
  'You merge notes taken from a user\'s earlier chats with Sana into one briefing that answers a question. '
  + 'Reply with JSON only: {"briefing": "..."}. Rules: at most 1400 characters; keep dates (YYYY-MM-DD) and figures exactly as given; '
  + 'order by time and point out changes or contradictions over time; use only the notes; if they do not answer the question, say what they do cover.'
);

const headerOf = (ref: string, title: string, first: unknown, last: unknown) => {
  const a = day(first);
  const b = day(last);
  return `## [${ref}] "${title}" (${a}${b && b !== a ? ` to ${b}` : ''})`;
};

const MESSAGE_LINE = /^\d{4}-\d{2}-\d{2} (?:User|Sana): /;

const messageLine = (m: any) =>
  `${day(m.created_at)} ${m.role === 'user' ? 'User' : 'Sana'}: ${clip(collapse(String(m.content ?? '')), RECALL_MESSAGE_CHARS)}`;

const unmark = (s: unknown) => collapse(typeof s === 'string' ? s.replace(/[«»]/g, '') : '');

/**
 * Each matched chat's share of the four chunks, so one long chat cannot crowd out the rest. It follows how
 * `packChunks` fills them: with k = ceil(chats / 4) sections per chunk, k sections and their separators fit in one
 * chunk, so up to 16 chats are all examined (10,000 characters each for up to 4 chats, 4,999 for 5 to 8).
 */
export function recallShare(chats: number): number {
  const k = Math.ceil(Math.max(1, chats) / MAX_CHUNKS);
  return Math.max(2_000, Math.floor((CHUNK_CHARS - 2 * (k - 1)) / k));
}

/** Packs sections into at most four chunks of 10,000 characters; a section too large for one is split. */
function packChunks(sections: Section[], perChunk: number): { chunks: Chunk[]; dropped: Section[] } {
  const pieces: Section[] = [];
  for (const s of sections) {
    if (s.text.length <= CHUNK_CHARS) { pieces.push(s); continue; }
    const [header, ...lines] = s.text.split('\n');
    let piece = { ...s, text: header, messages: 0 };
    for (const l of lines) {
      if (piece.text.length + l.length + 1 > CHUNK_CHARS && piece.text !== header) {
        pieces.push(piece);
        piece = { ...s, text: header, messages: 0 };
      }
      piece.text += `\n${l.slice(0, CHUNK_CHARS - header.length - 1)}`;
      if (MESSAGE_LINE.test(l)) piece.messages++;
    }
    pieces.push(piece);
  }
  const chunks: Chunk[] = [];
  const dropped: Section[] = [];
  for (const p of pieces) {
    const last = chunks[chunks.length - 1];
    if (last && last.text.length + p.text.length + 2 <= CHUNK_CHARS && last.sections.length < perChunk) {
      last.text += `\n\n${p.text}`;
      last.sections.push(p);
    } else if (chunks.length < MAX_CHUNKS) {
      chunks.push({ text: p.text, sections: [p] });
    } else {
      dropped.push(p);
    }
  }
  return { chunks, dropped };
}

/** Messages around the thread's hits (the hit and one non-blocked neighbour either side), in one call. */
async function hitWindows(d: CoachDeps, userId: string, threadId: string, hits: any[]): Promise<any[]> {
  const spans = hits.slice(0, 12).map((h) => {
    const t = Date.parse(h.created_at);
    const lo = enc(quoted(new Date(t - NEIGHBOUR_WINDOW_MS).toISOString()));
    const hi = enc(quoted(new Date(t + NEIGHBOUR_WINDOW_MS).toISOString()));
    return `and(created_at.gte.${lo},created_at.lte.${hi})`;
  });
  if (!spans.length) return [];
  return await d.rest.select('coach_messages',
    `user_id=eq.${userId}&thread_id=eq.${threadId}&blocked=is.false&or=(${spans.join(',')})`
    + '&order=created_at.asc,id.asc&limit=120&select=id,role,content,created_at');
}

function parseNotes(raw: Record<string, any> | null, chunk: Chunk, refs: Refs): { relevant: boolean; notes: Note[] } | null {
  if (!raw) return null;
  const notes: Note[] = [];
  for (const n of Array.isArray(raw.notes) ? raw.notes.slice(0, 5) : []) {
    let text = clip(collapse(typeof n === 'string' ? n : ''), 220);
    if (!text) continue;
    const ref = /\[(t\d{1,3})\]/i.exec(text)?.[1];
    const owner = chunk.sections.find((s) => s.threadId === refs.resolve(ref)) ?? chunk.sections[0];
    text = collapse(text.replace(/\s*\[t\d{1,3}\]\s*:?/gi, ' '));
    if (!/^\d{4}-\d{2}-\d{2}/.test(text) && owner?.at) text = `${day(owner.at)} ${text}`;
    notes.push({ threadId: owner.threadId, text });
  }
  return { relevant: raw.relevant === true && notes.length > 0, notes: raw.relevant === true ? notes : [] };
}

/** The notes under `[title, date]` headers, one group per chat, in chunk order. */
function joinNotes(notes: Note[], sections: Map<string, Section>): string {
  const groups = new Map<string, string[]>();
  for (const n of notes) groups.set(n.threadId, [...(groups.get(n.threadId) ?? []), n.text]);
  return [...groups].map(([id, list]) => {
    const s = sections.get(id);
    return `[${s?.title ?? 'Earlier chat'}, ${day(s?.at)}]\n${list.map((t) => `- ${t}`).join('\n')}`;
  }).join('\n\n');
}

async function recall(d: CoachDeps, userId: string, body: Record<string, any>) {
  const question = collapse(body.question).slice(0, 1000);
  if (!question) throw fail('invalid_recall', 400);
  const keywords = collapse(body.keywords).slice(0, 300);
  const current = optionalThread(body.threadId);
  const exclude = body.includeCurrent === true ? null : current;
  const { from, to } = windowOf(body, d.now());
  const started = performance.now();
  const deadline = started + RECALL_DEADLINE_MS * d.timeScale;
  const left = () => deadline - performance.now();

  const found = await d.rest.rpc('coach_search_v1', {
    p_user: userId, p_query: keywords || question, p_limit: 40, p_thread_limit: 6, p_exclude_thread: exclude, p_from: from, p_to: to,
  }) ?? {};
  const terms: string[] = Array.isArray(found.terms) ? found.terms : [];
  const matched: any[] = terms.length && Array.isArray(found.threads) ? found.threads.filter(isObject) : [];
  const totalHits = num(found.total_hits);
  const refs = new Refs('t');
  const sections: Section[] = [];
  let threadsMatched = matched.length;
  let messagesExamined = 0;
  let perChunk = Number.MAX_SAFE_INTEGER;
  let lexical = '';

  if (matched.length) {
    // 1-2. Matched chats: title, dates, summary, and each hit with a neighbour either side.
    const ids = matched.map((t) => uuidOf(t.thread_id)).filter((id): id is string => !!id);
    const rows = await d.rest.select('coach_threads',
      `user_id=eq.${userId}&id=in.(${ids.join(',')})&select=id,title,created_at,last_message_at,summary`);
    const byId = new Map(rows.map((r: any) => [String(r.id), r]));
    const hitsByThread = new Map<string, any[]>();
    for (const h of Array.isArray(found.hits) ? found.hits.filter(isObject) : []) {
      hitsByThread.set(String(h.thread_id), [...(hitsByThread.get(String(h.thread_id)) ?? []), h]);
    }
    const windows = await Promise.all(ids.map((id) => hitWindows(d, userId, id, hitsByThread.get(id) ?? [])));
    const share = recallShare(ids.length);
    ids.forEach((id, i) => {
      const t = byId.get(id);
      if (!t) return;
      const ref = refs.ref(id);
      const title = collapse(t.title) || 'Untitled chat';
      const head = [headerOf(ref, title, t.created_at, t.last_message_at)];
      if (t.summary) head.push(`Summary: ${clip(collapse(t.summary), RECALL_MESSAGE_CHARS)}`);
      const meta = matched.find((m) => String(m.thread_id) === id);
      const loaded = windows[i];
      const picked = new Map<string, any>();
      let size = head.join('\n').length;
      let hitsLeft = 0;
      for (const h of hitsByThread.get(id) ?? []) {
        const at = loaded.findIndex((r: any) => r.id === h.message_id);
        // Not loaded (the window read is capped): reported through coverage rather than dropped silently.
        if (at < 0) { hitsLeft++; continue; }
        let group = loaded.slice(Math.max(0, at - 1), at + 2).filter((r: any) => !picked.has(r.id));
        let add = group.reduce((n: number, r: any) => n + messageLine(r).length + 1, 0);
        // The first hit always gets in, if need be without its neighbours, so the section stays within its share.
        if (!picked.size && size + add > share) {
          group = [loaded[at]];
          add = messageLine(loaded[at]).length + 1;
        }
        if (size + add > share) { hitsLeft++; continue; }
        for (const r of group) picked.set(r.id, r);
        size += add;
      }
      if (!picked.size && meta?.snippet) head.push(`Match: ${unmark(meta.snippet)}`);
      const lines = [...picked.values()].sort((a, b) => (tsKey(a.created_at) - tsKey(b.created_at)) || String(a.id).localeCompare(String(b.id)));
      sections.push({ threadId: id, ref, title, at: t.last_message_at ?? null, text: [...head, ...lines.map(messageLine)].join('\n'), messages: lines.length, hitsLeft });
    });
    lexical = matched.map((m) => {
      const t = byId.get(String(m.thread_id));
      return `[${collapse(t?.title ?? m.title) || 'Untitled chat'}, ${day(m.last_message_at)}] ${unmark(m.snippet)}`;
    }).join('\n');
  } else {
    // No lexical match: the summaries of the window (or of the latest chats), newest first.
    const windowed = Boolean(from || to || !terms.length);
    const rows = await d.rest.select('coach_threads',
      `user_id=eq.${userId}&summary=not.is.null&message_count=gt.0${exclude ? `&id=neq.${exclude}` : ''}`
      + `${from ? `&last_message_at=gte.${enc(from)}` : ''}${to ? `&created_at=lt.${enc(to)}` : ''}`
      + `&order=last_message_at.desc.nullslast,id.desc&limit=${windowed ? 36 : 6}&select=id,title,created_at,last_message_at,summary`);
    threadsMatched = rows.length;
    perChunk = SUMMARIES_PER_CHUNK;
    for (const t of rows) {
      const ref = refs.ref(String(t.id));
      const title = collapse(t.title) || 'Untitled chat';
      sections.push({
        threadId: String(t.id), ref, title, at: t.last_message_at ?? null, messages: 0, hitsLeft: 0,
        text: `${headerOf(ref, title, t.created_at, t.last_message_at)}\nSummary: ${clip(collapse(t.summary), RECALL_MESSAGE_CHARS)}`,
      });
    }
    lexical = rows.slice(0, 8).map((t: any) => `[${collapse(t.title) || 'Untitled chat'}, ${day(t.last_message_at)}] ${clip(collapse(t.summary), 300)}`).join('\n');
  }

  const empty = { chunks: 0, subcalls: 0, messages: 0 };
  if (!sections.length) {
    return {
      answer: '', sources: [], coverage: { threadsMatched: 0, threadsExamined: 0, totalHits, truncated: false },
      examined: empty, status: 'nothing_found',
    };
  }

  const { chunks, dropped } = packChunks(sections, perChunk);
  const examinedIds = new Set(chunks.flatMap((c) => c.sections.map((s) => s.threadId)));
  for (const c of chunks) for (const p of c.sections) messagesExamined += p.messages;
  const sectionById = new Map(sections.map((s) => [s.threadId, s]));
  const hitsLoaded = Array.isArray(found.hits) ? found.hits.length : 0;
  const coverage = {
    threadsMatched, threadsExamined: examinedIds.size, totalHits,
    truncated: dropped.length > 0 || threadsMatched > examinedIds.size || sections.some((s) => s.hitsLeft > 0)
      || (matched.length > 0 && totalHits > hitsLoaded),
  };
  const sourcesOf = (notes: Note[]) => [...new Set(notes.map((n) => n.threadId))].map((id) => {
    const s = sectionById.get(id);
    return { threadId: id, title: s?.title ?? null, at: iso(s?.at) };
  });
  const lexicalAnswer = clip(lexical, DIRECT_NOTES_CHARS);
  const examined = { chunks: chunks.length, subcalls: 0, messages: messagesExamined };

  // 3. Budget: one unit per chunk plus one for the reduce, taken together.
  if (!utilityConfigured(d)) return { answer: lexicalAnswer, sources: [], coverage, examined, status: 'unavailable' };
  if (!(await takeUtilityUnits(d, userId, chunks.length + 1))) {
    return { answer: lexicalAnswer, sources: [], coverage, examined, status: 'budget' };
  }

  // 4. Map: every chunk at once, bounded by the deadline.
  const wave = new AbortController();
  const results: ({ relevant: boolean; notes: Note[] } | null | undefined)[] = chunks.map(() => undefined);
  const prompt = (c: Chunk): ChatTurn[] => [
    { role: 'system', content: MAP_SYSTEM },
    { role: 'user', content: `Question: ${question}\n\nExcerpts:\n${c.text}` },
  ];
  const tasks = chunks.map((c, i) =>
    callUtility(d, userId, 'map', prompt(c), { prepaid: true, signal: wave.signal, timeoutMs: left() })
      .then((raw) => { results[i] = parseNotes(raw, c, refs); }));
  examined.subcalls = chunks.length;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timedOut = await Promise.race([
    Promise.all(tasks).then(() => false),
    new Promise<boolean>((resolve) => { timer = setTimeout(() => resolve(true), Math.max(0, left())); }),
  ]);
  clearTimeout(timer);
  if (timedOut) wave.abort();

  const done = results.filter((r): r is { relevant: boolean; notes: Note[] } => !!r);
  const notes = done.filter((r) => r.relevant).flatMap((r) => r.notes);
  const joined = joinNotes(notes, sectionById);
  if (timedOut) {
    return { answer: joined || lexicalAnswer, sources: sourcesOf(notes), coverage: { ...coverage, truncated: true }, examined, status: 'partial' };
  }
  if (!done.length) return { answer: lexicalAnswer, sources: [], coverage, examined, status: 'unavailable' };
  if (!notes.length) return { answer: '', sources: [], coverage, examined, status: 'nothing_found' };

  // 5. Reduce only when the notes do not stand on their own.
  const relevantChunks = done.filter((r) => r.relevant).length;
  if (relevantChunks <= 2 && joined.length <= DIRECT_NOTES_CHARS) {
    return { answer: joined, sources: sourcesOf(notes), coverage, examined, status: 'answered' };
  }
  if (left() > 0) {
    examined.subcalls++;
    const raw = await callUtility(d, userId, 'reduce', [
      { role: 'system', content: REDUCE_SYSTEM },
      { role: 'user', content: `Question: ${question}\n\nNotes:\n${joined}` },
    ], { prepaid: true, timeoutMs: left() });
    const briefing = clip(collapse(typeof raw?.briefing === 'string' ? raw.briefing : ''), 1_400);
    if (briefing) return { answer: briefing, sources: sourcesOf(notes), coverage, examined, status: 'answered' };
  }
  const status = left() <= 0 ? 'partial' : 'answered';
  return { answer: clip(joined, 4_000), sources: sourcesOf(notes), coverage, examined, status };
}
