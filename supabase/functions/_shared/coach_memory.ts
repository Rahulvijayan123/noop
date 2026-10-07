// Sana's durable memories (docs/COACH_MEMORY.md §3 coach_memory_apply_v1 and §4 memories routes).
//
// Every write goes through coach_memory_apply_v1, which audits it in coach_memory_events, enforces the cap of
// 200 active rows (soft eviction) and keeps tombstones for forgotten facts. Reads ignore retired rows. A save
// that near-duplicates an active row (same topic family, §6) confirms or updates that row instead of adding.
import {
  clampInt, collapse, type CoachDeps, fail, findNearDuplicate, iso, memoryTokens, memoryTopic, MEMORY_TOPICS,
  readJson, SMALL_BODY_BYTES, tsKey, uuidOf,
} from './coach_llm.ts';

const DEFAULT_LIST = 50;
const MAX_LIST = 200;
/** Every active row (the cap is 200) plus headroom for rows evicted in the same breath. */
export const ACTIVE_SCAN = 400;
export const MEMORY_COLUMNS = 'id,content,topic,importance,created_at,updated_at,last_confirmed_at,source,source_thread_id,confirmations';

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
      if (row) await applyMemoryOps(d, userId, [{ op: 'forget', id, tokens: memoryTokens(row.content) }], 'user');
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

async function saveMemory(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  const input = memoryInput(body);
  const threadId = uuidOf(body?.threadId);
  const active = await activeMemories(d, userId);
  // The user asked for this explicitly, so a near-match of a forgotten fact is still saved; duplicates are not.
  const match = findNearDuplicate(input.content, input.topic, active);
  if (match) {
    const { row, kind } = match;
    if (kind === 'supersede' || kind === 'longer') {
      const importance = Math.max(Number(row.importance ?? 3), input.importance);
      const topic = row.topic === 'general' ? input.topic : row.topic;
      const [res] = await applyMemoryOps(d, userId, [{ op: 'update', id: row.id, content: input.content, topic, importance }], 'tool', threadId);
      if (res?.applied) {
        const stamp = new Date(d.now()).toISOString();
        return Response.json({ memory: publicMemory({ ...row, content: input.content, topic, importance, updated_at: stamp }), deduped: true, updated: true });
      }
    } else {
      await applyMemoryOps(d, userId, [{ op: 'confirm', id: row.id }], 'tool', threadId);
      return Response.json({ memory: publicMemory({ ...row, confirmations: Number(row.confirmations ?? 1) + 1 }), deduped: true });
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
