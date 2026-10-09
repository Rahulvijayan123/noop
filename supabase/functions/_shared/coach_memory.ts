// Sana's durable memories (docs/COACH_MEMORY.md §3 coach_memory_apply_v1 and §4 memories routes).
//
// Every write goes through coach_memory_apply_v1, which audits it in coach_memory_events, enforces the cap of
// 200 active rows (soft eviction) and keeps tombstones for forgotten facts. Reads ignore retired rows. A save
// that near-duplicates an active row (same topic family, §6) confirms or updates that row instead of adding.
import {
  clampInt, collapse, type CoachDeps, fail, findNearDuplicate, iso, jaccard, memoryTokens, memoryTopic, MEMORY_TOPICS,
  readJson, sameFamily, SMALL_BODY_BYTES, tokenSet, toolOverlap, tsKey, uuidOf, wordTokens,
} from './coach_llm.ts';

const DEFAULT_LIST = 50;
const MAX_LIST = 200;
/** Every active row (the cap is 200) plus headroom for rows evicted in the same breath. */
export const ACTIVE_SCAN = 400;
export const MEMORY_COLUMNS = 'id,content,topic,importance,created_at,updated_at,last_confirmed_at,source,source_thread_id,confirmations,version';

/** The `expect_version` guard of an update or retire (coach_memory_apply_v1 answers `stale` when it moved). */
export const versionGuard = (r: any) => (Number.isInteger(Number(r?.version)) && r?.version != null ? { expect_version: Number(r.version) } : {});

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

function memoryInput(body: any) {
  const content = typeof body?.content === 'string' ? body.content.trim() : '';
  if (!content || content.length > 500) throw fail('invalid_memory', 400);
  const importance = Number.isFinite(body.importance) ? Math.max(1, Math.min(5, Math.round(body.importance))) : 3;
  return { content, importance, topic: memoryTopic(body.topic) };
}

export async function memoriesRoute(req: Request, userId: string, tail: string[], d: CoachDeps): Promise<Response> {
  if (req.method === 'GET') return await listMemories(req, userId, d);
  if (req.method === 'POST') return await saveMemory(req, userId, d);
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
  if (req.method === 'PATCH' && tail[0]) return await editMemory(req, userId, tail[0], d);
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

/**
 * The person's own edit of one active memory: new text, and optionally a topic or importance. Guarded by the row's
 * version, so an edit never overwrites a change the curator made after the list was read (409 `stale`).
 */
async function editMemory(req: Request, userId: string, rawId: string, d: CoachDeps): Promise<Response> {
  const id = uuidOf(rawId);
  if (!id) throw fail('invalid_id', 400);
  const body = await readJson(req, SMALL_BODY_BYTES);
  const content = typeof body?.content === 'string' ? body.content.trim() : '';
  if (!content || content.length > 500) throw fail('invalid_memory', 400);
  const [row] = await d.rest.select('coach_memory_items',
    `user_id=eq.${userId}&id=eq.${id}&retired_at=is.null&select=${MEMORY_COLUMNS}`);
  if (!row) throw fail('not_found', 404);
  const topic = typeof body?.topic === 'string' ? memoryTopic(body.topic) : row.topic;
  const importance = Number.isFinite(body?.importance)
    ? Math.max(1, Math.min(5, Math.round(body.importance))) : Number(row.importance ?? 3);
  const [res] = await applyMemoryOps(d, userId,
    [{ op: 'update', id, content, topic, importance, ...versionGuard(row) }], 'user');
  if (!res?.applied) {
    if (res?.reason === 'stale') throw fail('stale', 409);
    if (res?.reason === 'invalid_content') throw fail('invalid_memory', 400);
    throw fail('not_found', 404);
  }
  // The cached starters may quote the old text.
  await dropStarterCache(d, userId);
  const stamp = new Date(d.now()).toISOString();
  return Response.json({ memory: publicMemory({ ...row, content, topic, importance, updated_at: stamp }) });
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

async function saveMemory(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  const input = memoryInput(body);
  const threadId = uuidOf(body?.threadId);
  // The user asked for this explicitly, so a near-match of a forgotten fact is still saved; duplicates are not.
  // The update is guarded by the row's version; when another writer moved it first, the match is redone once.
  for (let attempt = 0; attempt < 2; attempt++) {
    const target = saveTarget(input.content, input.topic, await activeMemories(d, userId));
    if (!target) break;
    const { row } = target;
    if (target.update) {
      const importance = Math.max(Number(row.importance ?? 3), input.importance);
      const topic = row.topic === 'general' ? input.topic : row.topic;
      const [res] = await applyMemoryOps(d, userId,
        [{ op: 'update', id: row.id, content: input.content, topic, importance, ...versionGuard(row) }], 'tool', threadId);
      if (res?.applied) {
        const stamp = new Date(d.now()).toISOString();
        return Response.json({ memory: publicMemory({ ...row, content: input.content, topic, importance, updated_at: stamp }), deduped: true, updated: true });
      }
      if (res?.reason !== 'stale') break;
    } else {
      const [res] = await applyMemoryOps(d, userId, [{ op: 'confirm', id: row.id }], 'tool', threadId);
      if (res?.applied) {
        return Response.json({ memory: publicMemory({ ...row, confirmations: Number(row.confirmations ?? 1) + 1 }), deduped: true });
      }
    }
  }
  const results = await applyMemoryOps(d, userId, [{ op: 'add', ...input, source: 'tool' }], 'tool', threadId);
  const added = results.find((r) => r?.op === 'add' && r.applied && r.id);
  if (!added) throw fail('memory_not_saved', 502);
  // Past the cap the lowest-scoring row is evicted, which may be the one just saved.
  const kept = !results.some((r) => r?.op === 'evict' && r.id === added.id);
  const [row] = await d.rest.select('coach_memory_items', `user_id=eq.${userId}&id=eq.${added.id}&select=${MEMORY_COLUMNS}`);
  const stamp = new Date(d.now()).toISOString();
  return Response.json({
    memory: publicMemory(row ?? { id: added.id, ...input, created_at: stamp, updated_at: stamp, source: 'tool', confirmations: 1 }),
    kept,
  });
}

/** Newest-confirmed first; ties by id. */
export const byRecency = (a: any, b: any) =>
  (tsKey(b.last_confirmed_at ?? b.created_at) - tsKey(a.last_confirmed_at ?? a.created_at)) || String(a.id).localeCompare(String(b.id));
