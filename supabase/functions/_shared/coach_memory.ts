// Sana's durable memories (docs/COACH_MEMORY.md §3 coach_memory_apply_v1 and §4 memories routes).
//
// Every write goes through coach_memory_apply_v1, which audits it in coach_memory_events, enforces the cap of
// 200 active rows (soft eviction) and keeps tombstones for forgotten facts and for the old wording of the user's
// own edits. Reads ignore retired rows. A save that near-duplicates an active row (same topic family, §6) confirms
// or updates that row instead of adding. A row the user edited or added (source 'user') is the user's wording: the
// curator, the consolidator and automatic saves never reword it.
import {
  clampInt, collapse, type CoachDeps, enc, fail, findNearDuplicate, isObject, iso, jaccard, memoryTokens, memoryTopic,
  MEMORY_TOPICS, readJson, sameFamily, SMALL_BODY_BYTES, tokenSet, tokensNearMatch, toolOverlap, tsKey, uuidOf, wordTokens,
} from './coach_llm.ts';

const DEFAULT_LIST = 50;
const MAX_LIST = 200;
/** Every active row (the cap is 200) plus headroom for rows evicted in the same breath. */
export const ACTIVE_SCAN = 400;
export const MEMORY_COLUMNS = 'id,content,topic,importance,created_at,updated_at,last_confirmed_at,source,source_thread_id,confirmations,version';

/** The `expect_version` guard of an update or retire (coach_memory_apply_v1 answers `stale` when it moved). */
export const versionGuard = (r: any) => (Number.isInteger(Number(r?.version)) && r?.version != null ? { expect_version: Number(r.version) } : {});

/** A row in the user's own words (edited or added in the memory sheet): only the user rewords it. */
export const isUserRow = (r: any) => r?.source === 'user';

/**
 * Token sets of the tombstones from the last 365 days: forgotten facts, and the old wording of the user's own edits
 * (an `update` event by the user that keeps `tokens`, §3). The curator never learns one again, and neither does an
 * automatic save.
 */
export async function loadTombstones(d: CoachDeps, userId: string): Promise<Set<string>[]> {
  const since = new Date(d.now() - 365 * 86_400_000).toISOString();
  const rows = await d.rest.select('coach_memory_events',
    `user_id=eq.${userId}&or=(op.eq.forget,and(op.eq.update,actor.eq.user))&created_at=gte.${enc(since)}`
    + '&order=created_at.desc&limit=1000&select=tokens');
  return rows.map((r: any) => new Set<string>((Array.isArray(r.tokens) ? r.tokens : []).filter((t: unknown) => typeof t === 'string')))
    .filter((s: Set<string>) => s.size > 0);
}

/** The text near-matches a tombstone (§6 `tokensNearMatch`). */
export function nearTombstone(content: string, tombstones: Set<string>[]): boolean {
  const mine = tokenSet(content);
  return tombstones.some((t) => tokensNearMatch(mine, t));
}

/** Forgetting one memory also drops the cached starters, which may quote it. Best effort. */
async function dropStarterCache(d: CoachDeps, userId: string): Promise<void> {
  try {
    await d.rest.patch('coach_user_state', {
      suggestions: [], suggestions_fingerprint: null, suggestions_at: null, updated_at: new Date(d.now()).toISOString(),
    }, `user_id=eq.${userId}`);
  } catch { /* the cache also expires on its own */ }
}

/** The `memories` row shape: the original fields, plus the optional ones a thread-aware server knows. */
export function publicMemory(r: any) {
  return {
    id: r.id, content: r.content, topic: r.topic, importance: r.importance, createdAt: r.created_at,
    ...(r.updated_at != null ? { updatedAt: iso(r.updated_at) } : {}),
    ...(r.source != null ? { source: r.source } : {}),
    ...(r.confirmations != null ? { confirmations: Number(r.confirmations) } : {}),
    ...(r.pinned != null ? { pinned: r.pinned === true } : {}),
    ...(r.version != null ? { version: Number(r.version) } : {}),
  };
}

/** The owner's active memories, highest importance and newest first. */
export async function activeMemories(d: CoachDeps, userId: string, limit = ACTIVE_SCAN): Promise<any[]> {
  return await d.rest.select('coach_memory_items',
    `user_id=eq.${userId}&retired_at=is.null&order=importance.desc,created_at.desc&limit=${limit}&select=${MEMORY_COLUMNS}`);
}

export async function applyMemoryOps(d: CoachDeps, userId: string, ops: unknown[], actor: string, threadId: string | null = null): Promise<any[]> {
  const result = await d.rest.rpc('coach_memory_apply_v1', { p_user: userId, p_ops: ops, p_actor: actor, p_thread: threadId });
  return Array.isArray(result) ? result : [];
}

const MAX_MEMORY_CHARS = 500;

/**
 * A memory's text, screened as every other stored text is: NUL characters (which PostgreSQL refuses) dropped, and
 * whitespace collapsed, since a memory is one line of the prompt's remembered block. 1..500 characters.
 */
function memoryText(v: unknown): string {
  const content = collapse(typeof v === 'string' ? v.replace(/\u0000/g, '') : '');
  if (!content || content.length > MAX_MEMORY_CHARS) throw fail('invalid_memory', 400);
  return content;
}

const importanceInput = (v: unknown) => Math.max(1, Math.min(5, Math.round(v as number)));

function memoryInput(body: any) {
  const content = memoryText(body?.content);
  const importance = Number.isFinite(body.importance) ? importanceInput(body.importance) : 3;
  return { content, importance, topic: memoryTopic(body.topic) };
}

export async function memoriesRoute(req: Request, userId: string, tail: string[], d: CoachDeps): Promise<Response> {
  if (req.method === 'GET') return await listMemories(req, userId, d);
  if (req.method === 'POST') return await saveMemory(req, userId, d);
  if (req.method === 'PATCH' && tail[0]) {
    const id = uuidOf(tail[0]);
    if (!id) throw fail('invalid_id', 400);
    return await editMemory(req, userId, id, d);
  }
  if (req.method === 'DELETE') {
    if (tail[0]) {
      const id = uuidOf(tail[0]);
      if (!id) throw fail('invalid_id', 400);
      // The tombstone keeps the fact's tokens (never its text), so the curator will not learn it again.
      const [row] = await d.rest.select('coach_memory_items', `user_id=eq.${userId}&id=eq.${id}&select=id,content`);
      if (row) {
        const [res] = await applyMemoryOps(d, userId, [{ op: 'forget', id, tokens: memoryTokens(row.content) }], 'user');
        if (res?.applied) await dropStarterCache(d, userId);
      }
    } else {
      await forgetAll(d, userId);
    }
    return Response.json({ deleted: true });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

/** coach_memory_apply_v1 takes at most 100 ops per call. */
const OPS_PER_CALL = 99;

/**
 * Forget-all. Each row is forgotten with this function's own tokens (§6) first, so the tombstones match what the
 * curator guard compares against; the closing `forget_all` then sets the memory floor, clears the cached
 * starters and searches, bumps the revision, and tombstones anything left (with the database's approximation).
 */
async function forgetAll(d: CoachDeps, userId: string): Promise<void> {
  const rows = await d.rest.select('coach_memory_items', `user_id=eq.${userId}&order=created_at.asc,id.asc&limit=1000&select=id,content`);
  const chunks: unknown[][] = [];
  rows.forEach((r: any, i: number) => {
    if (i % OPS_PER_CALL === 0) chunks.push([]);
    chunks[chunks.length - 1].push({ op: 'forget', id: r.id, tokens: memoryTokens(r.content), reason: 'forget_all' });
  });
  if (!chunks.length || chunks[chunks.length - 1].length >= OPS_PER_CALL) chunks.push([]);
  chunks[chunks.length - 1].push({ op: 'forget_all' });
  for (const ops of chunks) await applyMemoryOps(d, userId, ops, 'user');
}

async function listMemories(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const params = new URL(req.url).searchParams;
  const q = collapse(params.get('q')).slice(0, 500);
  const topic = (params.get('topic') ?? '').trim().toLowerCase();
  if (topic && !MEMORY_TOPICS.has(topic)) return Response.json({ memories: [] });
  const limit = clampInt(params.get('limit') ?? String(DEFAULT_LIST), 1, MAX_LIST, DEFAULT_LIST);
  if (!q) {
    const rows = await d.rest.select('coach_memory_items',
      `user_id=eq.${userId}&retired_at=is.null${topic ? `&topic=eq.${topic}` : ''}`
      + `&order=importance.desc,created_at.desc&limit=${limit}&select=${MEMORY_COLUMNS}`);
    return Response.json({ memories: rows.map(publicMemory) });
  }
  const ranked = await d.rest.rpc('coach_memories_ranked_v1', {
    p_user: userId, p_query: q, p_limit: topic ? MAX_LIST : limit, p_pin_safety: true,
  });
  const rows: any[] = Array.isArray(ranked?.memories) ? ranked.memories : [];
  return Response.json({ memories: rows.filter((r) => !topic || r.topic === topic).slice(0, limit).map(publicMemory) });
}

/**
 * The active row a save repeats, and whether the save replaces its text or only confirms it: first the §6
 * near-duplicate rules, then the save path's looser overlap (a same-family row with word-jaccard >= 0.45 that the
 * new text fully restates and extends, or that already says everything the new text does).
 */
export function saveTarget(content: string, topic: string, active: any[]): { row: any; update: boolean } | null {
  const match = findNearDuplicate(content, topic, active);
  if (match) return { row: match.row, update: match.kind === 'supersede' || match.kind === 'longer' };
  const mine = wordTokens(tokenSet(content));
  let best: { row: any; update: boolean; score: number } | null = null;
  for (const row of active) {
    if (!sameFamily(topic, row.topic)) continue;
    const kind = toolOverlap(content, row.content);
    if (!kind) continue;
    const score = jaccard(mine, wordTokens(tokenSet(row.content)));
    if (!best || score > best.score) best = { row, update: kind === 'supersedes', score };
  }
  return best && { row: best.row, update: best.update };
}

/**
 * POST memories. Three callers: Sana's save_memory tool (the user asked it to remember, or shared a critical fact),
 * the user adding a fact in the memory sheet (`source: 'user'`), and an automatic note nobody asked for (`auto: true`,
 * the "Ask Sana" handoff from a screen). The first two are explicit, so a near-match of a forgotten fact is still
 * saved; an automatic note that near-matches a tombstone (a forgotten fact, or the old wording of an edit) is not, and
 * never rewords a row in the user's own words. Duplicates are never added: the matching row is updated or confirmed.
 * An update is guarded by the row's version; when another writer moved it first, the match is redone once.
 */
async function saveMemory(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  const input = memoryInput(body);
  const threadId = uuidOf(body?.threadId);
  const byUser = body?.source === 'user';
  const auto = !byUser && body?.auto === true;
  const actor = byUser ? 'user' : 'tool';
  if (auto && nearTombstone(input.content, await loadTombstones(d, userId))) return Response.json({ skipped: 'forgotten' });
  for (let attempt = 0; attempt < 2; attempt++) {
    const target = saveTarget(input.content, input.topic, await activeMemories(d, userId));
    if (!target) break;
    const { row } = target;
    if (target.update && !(auto && isUserRow(row))) {
      const importance = Math.max(Number(row.importance ?? 3), input.importance);
      const topic = row.topic === 'general' ? input.topic : row.topic;
      // The user's own rewording leaves the old wording's tokens behind as an edit tombstone (§3).
      const tokens = byUser ? { tokens: memoryTokens(row.content) } : {};
      const [res] = await applyMemoryOps(d, userId,
        [{ op: 'update', id: row.id, content: input.content, topic, importance, ...tokens, ...versionGuard(row) }], actor, threadId);
      if (res?.applied) {
        const stamp = new Date(d.now()).toISOString();
        const version = row.version != null ? { version: Number(row.version) + 1 } : {};
        const source = byUser ? { source: 'user' } : {};
        return Response.json({
          memory: publicMemory({ ...row, content: input.content, topic, importance, updated_at: stamp, ...version, ...source }), deduped: true, updated: true,
        });
      }
      if (res?.reason !== 'stale') break;
    } else {
      const [res] = await applyMemoryOps(d, userId, [{ op: 'confirm', id: row.id }], actor, threadId);
      if (res?.applied) {
        return Response.json({ memory: publicMemory({ ...row, confirmations: Number(row.confirmations ?? 1) + 1 }), deduped: true });
      }
    }
  }
  const source = byUser ? 'user' : 'tool';
  const results = await applyMemoryOps(d, userId, [{ op: 'add', ...input, source }], actor, threadId);
  const added = results.find((r) => r?.op === 'add' && r.applied && r.id);
  if (!added) throw fail('memory_not_saved', 502);
  // Past the cap the lowest-scoring row is evicted, which may be the one just saved.
  const kept = !results.some((r) => r?.op === 'evict' && r.id === added.id);
  const [row] = await d.rest.select('coach_memory_items', `user_id=eq.${userId}&id=eq.${added.id}&select=${MEMORY_COLUMNS}`);
  const stamp = new Date(d.now()).toISOString();
  return Response.json({
    memory: publicMemory(row ?? { id: added.id, ...input, created_at: stamp, updated_at: stamp, source, confirmations: 1, version: 1 }),
    kept,
  });
}

/**
 * PATCH memories/<id> `{content?, topic?, importance?, version}`: the user's own edit from the memory sheet, guarded
 * by the version the sheet read. 409 `version_conflict` (with the current row) when another writer changed it first,
 * 404 when it is forgotten or retired. The row becomes source 'user', so no curator or consolidation pass rewords,
 * merges or retires it again (confirming it and moving its importance stay allowed); a changed text leaves the old
 * wording's tokens as an edit tombstone, so neither the curator nor an automatic save learns it again. The cached
 * starters go too, since one may quote the old wording. Returns `{memory}` as it now reads, `version` included.
 */
async function editMemory(req: Request, userId: string, id: string, d: CoachDeps): Promise<Response> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  if (!isObject(body)) throw fail('invalid_memory', 400);
  const version = Number.isInteger(body.version) && body.version >= 1 ? Number(body.version) : null;
  if (version == null) throw fail('invalid_memory', 400);
  const op: Record<string, unknown> = { op: 'update', id, expect_version: version };
  if ('content' in body) op.content = memoryText(body.content);
  if ('topic' in body) {
    const topic = typeof body.topic === 'string' ? body.topic.trim().toLowerCase() : '';
    if (!MEMORY_TOPICS.has(topic)) throw fail('invalid_memory', 400);
    op.topic = topic;
  }
  if ('importance' in body) {
    if (typeof body.importance !== 'number' || !Number.isFinite(body.importance)) throw fail('invalid_memory', 400);
    op.importance = importanceInput(body.importance);
  }
  if (!('content' in op || 'topic' in op || 'importance' in op)) throw fail('invalid_memory', 400);

  const current = async () =>
    (await d.rest.select('coach_memory_items', `user_id=eq.${userId}&id=eq.${id}&retired_at=is.null&select=${MEMORY_COLUMNS}`))[0];
  const conflict = (row: any) => Response.json({ error: 'version_conflict', memory: publicMemory(row) }, { status: 409 });
  const row = await current();
  if (!row) throw fail('memory_not_found', 404);
  if (Number(row.version) !== version) return conflict(row);
  if (typeof op.content === 'string') op.tokens = memoryTokens(row.content);
  const [res] = await applyMemoryOps(d, userId, [op], 'user');
  if (!res?.applied) {
    if (res?.reason === 'invalid_content') throw fail('invalid_memory', 400);
    // Another writer got there between the read and the write: forgotten or retired (404), or changed (409).
    const now = await current();
    if (!now) throw fail('memory_not_found', 404);
    if (res?.reason === 'stale') return conflict(now);
    throw fail('memory_not_saved', 502);
  }
  await dropStarterCache(d, userId);
  const saved = await current();
  if (!saved) throw fail('memory_not_found', 404);
  return Response.json({ memory: publicMemory(saved) });
}

/** Newest-confirmed first; ties by id. */
export const byRecency = (a: any, b: any) =>
  (tsKey(b.last_confirmed_at ?? b.created_at) - tsKey(a.last_confirmed_at ?? a.created_at)) || String(a.id).localeCompare(String(b.id));
