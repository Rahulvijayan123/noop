// Sana's chat history: threads, folders and the message store (docs/COACH_MEMORY.md §4).
//
// Messages are written only through coach_messages_save_v1, which resolves an old build's thread-less rows,
// rejects saves for deleted or foreign threads, creates missing threads and merges meta. Everything else here
// is owner-filtered PostgREST: every query carries `user_id=eq.<owner>`, and the owner always comes from the
// installation credential. Pages use opaque cursors over (created_at, id) or (last_message_at, id), encoded
// from the raw database values so microsecond timestamps never skip or repeat a row.
import { isUuid } from './keys.ts';
import {
  clampInt, collapse, type CoachDeps, enc, fail, isObject, iso, quoted, readJson, SMALL_BODY_BYTES, uuidOf,
} from './coach_llm.ts';

const MAX_TEXT_CHARS = 60_000;
const MAX_SAVE_ROWS = 40;

export const THREAD_COLUMNS =
  'id,title,title_source,folder_id,pinned,origin,created_at,updated_at,last_message_at,message_count,preview,summary_topics,summary_messages';
const FOLDER_COLUMNS = 'id,name,sort_order,created_at,updated_at';
const MESSAGE_COLUMNS = 'id,client_id,thread_id,role,content,meta,created_at';

/** The `Thread` shape; `snippet` only on search results. */
export function publicThread(r: any, snippet?: string | null) {
  const count = Number(r.message_count ?? 0);
  return {
    id: r.id, title: r.title ?? null, titleSource: r.title_source ?? 'none', folderId: r.folder_id ?? null,
    pinned: r.pinned === true, origin: r.origin ?? 'app', createdAt: iso(r.created_at), updatedAt: iso(r.updated_at),
    lastMessageAt: iso(r.last_message_at), messageCount: count, preview: r.preview ?? null,
    topics: Array.isArray(r.summary_topics) ? r.summary_topics : [],
    pendingMessages: Math.max(0, count - Number(r.summary_messages ?? 0)),
    ...(snippet !== undefined ? { snippet } : {}),
  };
}

export const publicFolder = (r: any) => ({
  id: r.id, name: r.name, sortOrder: Number(r.sort_order ?? 0), createdAt: iso(r.created_at), updatedAt: iso(r.updated_at),
});

// ------------------------------------------------------------------------------------------------
// Cursors
// ------------------------------------------------------------------------------------------------

/** Opaque page cursor: base64url of `[timestamp|null, id]`. */
export function encodeCursor(at: string | null, id: string): string {
  return btoa(JSON.stringify([at, id])).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function decodeCursor(raw: unknown, allowNullTime = false): { at: string | null; id: string } {
  if (typeof raw !== 'string' || raw.length > 200) throw fail('invalid_cursor', 400);
  try {
    const padded = raw.replace(/-/g, '+').replace(/_/g, '/');
    const [at, id] = JSON.parse(atob(padded + '='.repeat((4 - (padded.length % 4)) % 4)));
    const timeOk = at === null ? allowNullTime : typeof at === 'string' && at.length <= 40 && Number.isFinite(Date.parse(at));
    if (timeOk && isUuid(id)) return { at, id };
  } catch { /* fall through */ }
  throw fail('invalid_cursor', 400);
}

/** Rows strictly after the cursor in `created_at desc, id desc` order. */
export function olderThan(c: { at: string | null; id: string }, column = 'created_at'): string {
  return `&or=(${column}.lt.${enc(quoted(c.at!))},and(${column}.eq.${enc(quoted(c.at!))},id.lt.${c.id}))`;
}

/** Rows after the cursor in `last_message_at desc nulls last, id desc` order. */
function threadsAfter(c: { at: string | null; id: string }): string {
  if (c.at === null) return `&last_message_at=is.null&id=lt.${c.id}`;
  const at = enc(quoted(c.at));
  return `&or=(last_message_at.lt.${at},and(last_message_at.eq.${at},id.lt.${c.id}),last_message_at.is.null)`;
}

// ------------------------------------------------------------------------------------------------
// Messages
// ------------------------------------------------------------------------------------------------

const publicMessage = (r: any) => ({
  id: r.id, clientId: r.client_id, role: r.role, content: r.content, meta: r.meta ?? {}, createdAt: r.created_at,
});

function messageRow(m: any, now: number) {
  if (!isObject(m) || !isUuid(m.clientId) || !['user', 'assistant'].includes(m.role)
      || typeof m.content !== 'string' || m.content.length > MAX_TEXT_CHARS) throw fail('invalid_message', 400);
  if (m.threadId != null && !isUuid(m.threadId)) throw fail('invalid_message', 400);
  const meta = isObject(m.meta) ? m.meta : {};
  const metaText = JSON.stringify(meta);
  if (metaText.length > 20_000) throw fail('invalid_message', 400);
  const title = collapse(stripNul(m.threadTitle)).slice(0, 120);
  return {
    client_id: m.clientId.toLowerCase(), thread_id: m.threadId ? String(m.threadId).toLowerCase() : null,
    role: m.role, content: stripNul(m.content), meta: metaText.includes('\\u0000') ? stripNulDeep(meta) : meta,
    created_at: createdAt(m.createdAt, now), thread_title: title || null,
  };
}

// The row is written as one batch with the rest, so anything PostgreSQL would refuse is fixed here rather than
// failing the whole save (which the phone's outbox would retry forever): NUL characters, which text and jsonb
// cannot hold, and timestamps it cannot parse. A time is re-rendered as ISO; one outside 2000..2200 is now.
const stripNul = (v: unknown) => (typeof v === 'string' ? v.replace(/\u0000/g, '') : v);

function stripNulDeep(v: unknown): unknown {
  if (typeof v === 'string') return stripNul(v);
  if (Array.isArray(v)) return v.map(stripNulDeep);
  if (isObject(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [stripNul(k), stripNulDeep(x)]));
  return v;
}

function createdAt(v: unknown, now: number): string {
  const t = typeof v === 'string' && v.length <= 64 ? Date.parse(v) : NaN;
  return Number.isFinite(t) && t >= Date.UTC(2000, 0, 1) && t < Date.UTC(2200, 0, 1) ? new Date(t).toISOString() : new Date(now).toISOString();
}

export async function messagesRoute(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const owner = `user_id=eq.${userId}`;
  const params = new URL(req.url).searchParams;
  if (req.method === 'GET') {
    const threadId = params.get('threadId');
    if (threadId !== null) return await threadPage(d, userId, threadId, params);
    // The original single-conversation read: the latest N across every thread, oldest first, same shape.
    const limit = clampInt(params.get('limit') ?? '60', 1, 200, 60);
    const rows = await d.rest.select('coach_messages',
      `${owner}&client_id=not.is.null&order=created_at.desc,id.desc&limit=${limit}&select=id,client_id,role,content,meta,created_at`);
    return Response.json({ messages: rows.map(publicMessage).reverse() });
  }
  if (req.method === 'POST') {
    const body = await readJson(req);
    if (!Array.isArray(body?.messages) || !body.messages.length || body.messages.length > MAX_SAVE_ROWS) {
      throw fail('invalid_message', 400);
    }
    const now = d.now();
    const rows = body.messages.map((m: any) => messageRow(m, now));
    const result = await d.rest.rpc('coach_messages_save_v1', { p_user: userId, p_rows: rows });
    const rejected = Array.isArray(result?.rejected) ? result.rejected : [];
    return Response.json({
      saved: Number(result?.saved ?? 0),
      rejected: rejected.map((r: any) => ({ clientId: r?.client_id ?? null, reason: String(r?.reason ?? 'rejected') })),
    });
  }
  if (req.method === 'DELETE') {
    const threadId = params.get('threadId');
    if (threadId !== null) {
      const id = uuidOf(threadId);
      if (!id) throw fail('invalid_id', 400);
      await deleteThread(d, userId, id);
    } else {
      await deleteEverything(d, userId);
    }
    return Response.json({ deleted: true });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

async function threadPage(d: CoachDeps, userId: string, rawId: string, params: URLSearchParams): Promise<Response> {
  const threadId = uuidOf(rawId);
  if (!threadId) throw fail('invalid_id', 400);
  const limit = clampInt(params.get('limit') ?? '60', 1, 200, 60);
  const cursor = params.get('cursor') ? decodeCursor(params.get('cursor')) : null;
  const rows = await d.rest.select('coach_messages',
    `user_id=eq.${userId}&thread_id=eq.${threadId}${cursor ? olderThan(cursor) : ''}`
    + `&order=created_at.desc,id.desc&limit=${limit + 1}&select=${MESSAGE_COLUMNS}`);
  const page = rows.slice(0, limit);
  const oldest = page[page.length - 1];
  const hasMore = rows.length > limit;
  return Response.json({
    // A new shape, so its timestamps are ISO strings; the legacy read above keeps the database rendering.
    messages: page.reverse().map((r: any) => ({ ...publicMessage(r), threadId: r.thread_id ?? threadId, createdAt: iso(r.created_at) })),
    hasMore, nextCursor: hasMore && oldest ? encodeCursor(oldest.created_at, oldest.id) : null,
  });
}

/** Tombstone first, so an outbox save still in flight can never bring the thread back. */
async function deleteThread(d: CoachDeps, userId: string, threadId: string): Promise<void> {
  await d.rest.upsert('coach_thread_tombstones', { user_id: userId, thread_id: threadId, deleted_at: new Date(d.now()).toISOString() },
    { onConflict: 'user_id,thread_id', prefer: 'resolution=merge-duplicates,return=minimal' });
  // Messages go with their thread through the composite foreign key.
  await d.rest.delete('coach_threads', `user_id=eq.${userId}&id=eq.${threadId}`);
}

async function deleteEverything(d: CoachDeps, userId: string): Promise<void> {
  const stamp = new Date(d.now()).toISOString();
  let after = '';
  for (;;) {
    const ids = await d.rest.select('coach_threads', `user_id=eq.${userId}${after}&order=id.asc&limit=1000&select=id`);
    if (!ids.length) break;
    await d.rest.upsert('coach_thread_tombstones', ids.map((r: any) => ({ user_id: userId, thread_id: r.id, deleted_at: stamp })),
      { onConflict: 'user_id,thread_id', prefer: 'resolution=merge-duplicates,return=minimal' });
    if (ids.length < 1000) break;
    after = `&id=gt.${ids[ids.length - 1].id}`;
  }
  await d.rest.delete('coach_threads', `user_id=eq.${userId}`);
  await d.rest.delete('coach_messages', `user_id=eq.${userId}`);
  // Starters can point at deleted chats and searches name them; both go with the history.
  await d.rest.patch('coach_user_state', { suggestions: [], suggestions_fingerprint: null, suggestions_at: null, recent_searches: [], updated_at: stamp },
    `user_id=eq.${userId}`);
}

// ------------------------------------------------------------------------------------------------
// Threads
// ------------------------------------------------------------------------------------------------

export async function loadThread(d: CoachDeps, userId: string, threadId: string, columns = THREAD_COLUMNS): Promise<any | null> {
  const [row] = await d.rest.select('coach_threads', `user_id=eq.${userId}&id=eq.${threadId}&select=${columns}`);
  return row ?? null;
}

function titleInput(v: unknown): string {
  const title = collapse(v);
  if (typeof v !== 'string' || title.length < 1 || title.length > 120) throw fail('invalid_thread', 400);
  return title;
}

async function ownedFolder(d: CoachDeps, userId: string, folderId: string): Promise<void> {
  const rows = await d.rest.select('coach_folders', `user_id=eq.${userId}&id=eq.${folderId}&select=id`);
  if (!rows.length) throw fail('folder_not_found', 404);
}

export async function threadsRoute(req: Request, userId: string, sub: string[], d: CoachDeps): Promise<Response> {
  if (sub.length === 0) {
    if (req.method === 'GET') {
      const params = new URL(req.url).searchParams;
      const q = collapse(params.get('q')).slice(0, 200);
      return q ? await searchThreads(d, userId, q, params) : await listThreads(d, userId, params);
    }
    if (req.method === 'POST') return await createThread(req, userId, d);
    return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  }
  if (sub.length !== 1) return Response.json({ error: 'not_found' }, { status: 404 });
  const id = uuidOf(sub[0]);
  if (!id) throw fail('invalid_id', 400);
  if (req.method === 'GET') {
    const row = await loadThread(d, userId, id);
    if (!row) throw fail('thread_not_found', 404);
    return Response.json({ thread: publicThread(row) });
  }
  if (req.method === 'PATCH') {
    const body = await readJson(req, SMALL_BODY_BYTES);
    if (!isObject(body)) throw fail('invalid_thread', 400);
    const patch: Record<string, unknown> = {};
    if ('title' in body) {
      patch.title = titleInput(body.title);
      patch.title_source = 'user';
    }
    if ('folderId' in body) {
      if (body.folderId === null) patch.folder_id = null;
      else {
        const folderId = uuidOf(body.folderId);
        if (!folderId) throw fail('invalid_thread', 400);
        await ownedFolder(d, userId, folderId);
        patch.folder_id = folderId;
      }
    }
    if ('pinned' in body) {
      if (typeof body.pinned !== 'boolean') throw fail('invalid_thread', 400);
      patch.pinned = body.pinned;
    }
    if (!Object.keys(patch).length) throw fail('invalid_thread', 400);
    patch.updated_at = new Date(d.now()).toISOString();
    const [row] = await d.rest.patch('coach_threads', patch, `user_id=eq.${userId}&id=eq.${id}&select=${THREAD_COLUMNS}`) ?? [];
    if (!row) throw fail('thread_not_found', 404);
    return Response.json({ thread: publicThread(row) });
  }
  if (req.method === 'DELETE') {
    await deleteThread(d, userId, id);
    return Response.json({ deleted: true });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}

async function listThreads(d: CoachDeps, userId: string, params: URLSearchParams): Promise<Response> {
  const limit = clampInt(params.get('limit') ?? '50', 1, 100, 50);
  const folder = params.get('folderId');
  let inFolder = '';
  if (folder === 'none') inFolder = '&folder_id=is.null';
  else if (folder !== null && folder !== '') {
    const folderId = uuidOf(folder);
    if (!folderId) throw fail('invalid_id', 400);
    inFolder = `&folder_id=eq.${folderId}`;
  }
  const cursor = params.get('cursor') ? decodeCursor(params.get('cursor'), true) : null;
  const base = `user_id=eq.${userId}${inFolder}`;
  const order = 'order=last_message_at.desc.nullslast,id.desc';
  // Pinned threads lead the first page; the cursor walks the unpinned ones only.
  const [pinned, rows, folders] = await Promise.all([
    cursor ? Promise.resolve([]) : d.rest.select('coach_threads', `${base}&pinned=is.true&${order}&limit=100&select=${THREAD_COLUMNS}`),
    d.rest.select('coach_threads', `${base}&pinned=is.false${cursor ? threadsAfter(cursor) : ''}&${order}&limit=${limit + 1}&select=${THREAD_COLUMNS}`),
    d.rest.select('coach_folders', `user_id=eq.${userId}&order=sort_order.asc,created_at.asc,id.asc&limit=500&select=${FOLDER_COLUMNS}`),
  ]);
  const page = rows.slice(0, limit);
  const last = page[page.length - 1];
  const hasMore = rows.length > limit;
  return Response.json({
    threads: [...pinned, ...page].map((r: any) => publicThread(r)),
    folders: folders.map(publicFolder),
    hasMore, nextCursor: hasMore && last ? encodeCursor(last.last_message_at ?? null, last.id) : null,
  });
}

async function searchThreads(d: CoachDeps, userId: string, q: string, params: URLSearchParams): Promise<Response> {
  const limit = clampInt(params.get('limit') ?? '20', 1, 30, 20);
  const record = params.get('record') === '1' && q.length >= 3;
  const [result] = await Promise.all([
    d.rest.rpc('coach_search_v1', { p_user: userId, p_query: q, p_limit: 1, p_thread_limit: limit }),
    record ? recordSearch(d, userId, q) : Promise.resolve(),
  ]);
  // A query with no searchable words would browse by date; the sidebar wants matches only.
  const hits: any[] = Array.isArray(result?.terms) && result.terms.length && Array.isArray(result?.threads) ? result.threads : [];
  const ids = hits.map((h) => uuidOf(h?.thread_id)).filter((id): id is string => !!id);
  const rows = ids.length
    ? await d.rest.select('coach_threads', `user_id=eq.${userId}&id=in.(${ids.join(',')})&select=${THREAD_COLUMNS}`)
    : [];
  const byId = new Map(rows.map((r: any) => [String(r.id).toLowerCase(), r]));
  const threads = hits
    .map((h) => {
      const row = byId.get(String(h?.thread_id ?? '').toLowerCase());
      return row ? publicThread(row, typeof h.snippet === 'string' ? h.snippet : null) : null;
    })
    .filter(Boolean);
  return Response.json({ threads, query: q });
}

/** Newest first, case-insensitively unique, at most 10. Best effort: a lost race only drops one entry. */
async function recordSearch(d: CoachDeps, userId: string, q: string): Promise<void> {
  try {
    const [state] = await d.rest.select('coach_user_state', `user_id=eq.${userId}&select=recent_searches`);
    const prior: string[] = Array.isArray(state?.recent_searches) ? state.recent_searches.filter((s: unknown) => typeof s === 'string') : [];
    const entry = q.slice(0, 100);
    const next = [entry, ...prior.filter((s) => s.toLowerCase() !== entry.toLowerCase())].slice(0, 10);
    await d.rest.upsert('coach_user_state', { user_id: userId, recent_searches: next, updated_at: new Date(d.now()).toISOString() },
      { onConflict: 'user_id', prefer: 'resolution=merge-duplicates,return=minimal' });
  } catch { /* recent searches only flavour the starters */ }
}

async function createThread(req: Request, userId: string, d: CoachDeps): Promise<Response> {
  const body = await readJson(req, SMALL_BODY_BYTES);
  if (!isObject(body)) throw fail('invalid_thread', 400);
  const id = uuidOf(body.id);
  if (!id) throw fail('invalid_thread', 400);
  const title = body.title == null ? null : titleInput(body.title);
  let folderId: string | null = null;
  if (body.folderId != null) {
    folderId = uuidOf(body.folderId);
    if (!folderId) throw fail('invalid_thread', 400);
  }
  const [[existing], tombstones] = await Promise.all([
    d.rest.select('coach_threads', `id=eq.${id}&select=user_id,${THREAD_COLUMNS}`),
    d.rest.select('coach_thread_tombstones', `user_id=eq.${userId}&thread_id=eq.${id}&select=thread_id`),
  ]);
  if (tombstones.length) throw fail('thread_deleted', 410);
  if (existing) {
    if (existing.user_id !== userId) throw fail('thread_conflict', 409);
    return Response.json({ thread: publicThread(existing) });
  }
  if (folderId) await ownedFolder(d, userId, folderId);
  const stamp = new Date(d.now()).toISOString();
  try {
    // A client-supplied title is provisional, like the one a first message carries: the model may rename it.
    const [row] = await d.rest.request('coach_threads', {
      method: 'POST', query: `select=${THREAD_COLUMNS}`,
      body: { id, user_id: userId, title, title_source: title ? 'fallback' : 'none', folder_id: folderId, origin: 'app', created_at: stamp, updated_at: stamp },
    });
    return Response.json({ thread: publicThread(row) });
  } catch (err: any) {
    if (err?.status !== 409) throw err;
    // Lost a race with a message save or another device: the winner decides.
    const [row] = await d.rest.select('coach_threads', `id=eq.${id}&select=user_id,${THREAD_COLUMNS}`);
    if (!row || row.user_id !== userId) throw fail('thread_conflict', 409);
    return Response.json({ thread: publicThread(row) });
  }
}

// ------------------------------------------------------------------------------------------------
// Folders
// ------------------------------------------------------------------------------------------------

function folderName(v: unknown): string {
  const name = collapse(v);
  if (typeof v !== 'string' || name.length < 1 || name.length > 60) throw fail('invalid_folder', 400);
  return name;
}

export async function foldersRoute(req: Request, userId: string, sub: string[], d: CoachDeps): Promise<Response> {
  const owner = `user_id=eq.${userId}`;
  if (sub.length === 0) {
    if (req.method === 'GET') {
      const rows = await d.rest.select('coach_folders', `${owner}&order=sort_order.asc,created_at.asc,id.asc&limit=500&select=${FOLDER_COLUMNS}`);
      return Response.json({ folders: rows.map(publicFolder) });
    }
    if (req.method === 'POST') {
      const body = await readJson(req, SMALL_BODY_BYTES);
      if (!isObject(body)) throw fail('invalid_folder', 400);
      const id = uuidOf(body.id);
      if (!id) throw fail('invalid_folder', 400);
      const name = folderName(body.name);
      const sortOrder = clampInt(body.sortOrder, -1_000_000, 1_000_000, 0);
      const [existing] = await d.rest.select('coach_folders', `id=eq.${id}&select=user_id,${FOLDER_COLUMNS}`);
      if (existing) {
        if (existing.user_id !== userId) throw fail('folder_conflict', 409);
        return Response.json({ folder: publicFolder(existing) });
      }
      const stamp = new Date(d.now()).toISOString();
      try {
        const [row] = await d.rest.request('coach_folders', {
          method: 'POST', query: `select=${FOLDER_COLUMNS}`,
          body: { id, user_id: userId, name, sort_order: sortOrder, created_at: stamp, updated_at: stamp },
        });
        return Response.json({ folder: publicFolder(row) });
      } catch (err: any) {
        if (err?.status !== 409) throw err;
        const [row] = await d.rest.select('coach_folders', `id=eq.${id}&select=user_id,${FOLDER_COLUMNS}`);
        if (!row || row.user_id !== userId) throw fail('folder_conflict', 409);
        return Response.json({ folder: publicFolder(row) });
      }
    }
    return Response.json({ error: 'method_not_allowed' }, { status: 405 });
  }
  if (sub.length !== 1) return Response.json({ error: 'not_found' }, { status: 404 });
  const id = uuidOf(sub[0]);
  if (!id) throw fail('invalid_id', 400);
  if (req.method === 'PATCH') {
    const body = await readJson(req, SMALL_BODY_BYTES);
    if (!isObject(body)) throw fail('invalid_folder', 400);
    const patch: Record<string, unknown> = {};
    if ('name' in body) patch.name = folderName(body.name);
    if ('sortOrder' in body) {
      if (typeof body.sortOrder !== 'number' || !Number.isFinite(body.sortOrder)) throw fail('invalid_folder', 400);
      patch.sort_order = clampInt(body.sortOrder, -1_000_000, 1_000_000, 0);
    }
    if (!Object.keys(patch).length) throw fail('invalid_folder', 400);
    patch.updated_at = new Date(d.now()).toISOString();
    const [row] = await d.rest.patch('coach_folders', patch, `${owner}&id=eq.${id}&select=${FOLDER_COLUMNS}`) ?? [];
    if (!row) throw fail('folder_not_found', 404);
    return Response.json({ folder: publicFolder(row) });
  }
  if (req.method === 'DELETE') {
    // Its threads stay and fall back to no folder (on delete set null).
    await d.rest.delete('coach_folders', `${owner}&id=eq.${id}`);
    return Response.json({ deleted: true });
  }
  return Response.json({ error: 'method_not_allowed' }, { status: 405 });
}
