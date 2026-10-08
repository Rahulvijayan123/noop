// Threads, folders and the message store behind Sana's chat history (docs/COACH_MEMORY.md §4), over the
// in-memory fake of the coach tables and RPCs.
import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert';
import { decodeCursor, encodeCursor } from '../_shared/coach_store.ts';
import { harness, OTHER, SHIPPED_REFUSALS, USER } from './coach_fake.ts';

const uuid = () => crypto.randomUUID();
const THREAD_KEYS = ['createdAt', 'folderId', 'id', 'lastMessageAt', 'messageCount', 'needsMaintenance', 'origin', 'pendingMessages',
  'pinned', 'preview', 'title', 'titleSource', 'topics', 'updatedAt'];

const row = (over: Record<string, unknown> = {}) => ({
  clientId: uuid(), role: 'user', content: 'hello', createdAt: '2026-10-07T10:00:00Z', meta: {}, ...over,
});

Deno.test('coach status: advertises threads and context to a thread-aware app', async () => {
  const h = await harness();
  const { status, body } = await h.json('status');
  assertEquals(status, 200);
  assertEquals(body.features, { threads: 1, context: 1 });
  assertEquals(body.ok, true);
  assertEquals(body.configured, true);
});

Deno.test('coach status: COACH_THREADS_DISABLED is the rollback switch: no features, the new data rules unchanged', async () => {
  for (const value of ['1', 'true']) {
    const h = await harness({}, { COACH_THREADS_DISABLED: value });
    const { status, body } = await h.json('status');
    assertEquals([status, body.ok, 'features' in body], [200, true, false]);
  }
  const h = await harness({}, { COACH_THREADS_DISABLED: '1' });
  // The routes old and new builds keep using still follow the new rules: saves go through the RPC (50,000 rows),
  // memories are capped at 200 active rows and retired rows stay hidden.
  const tid = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: tid })] } });
  assertEquals(h.db.rpcCalls.filter((c) => c.name === 'coach_messages_save_v1').length, 1);
  h.db.memory(USER, 'Retired fact', { retired_at: '2026-10-01T00:00:00Z' });
  assertEquals((await h.json('memories')).body.memories, []);
  assertEquals((await harness({}, { COACH_THREADS_DISABLED: '0' })).cfg.threadsDisabled, false);
});

Deno.test('coach messages: a new thread is created by its first save, with the client fallback title', async () => {
  const h = await harness();
  const tid = uuid().toUpperCase();
  const save = await h.json('messages', { method: 'POST', body: { messages: [
    row({ threadId: tid, threadTitle: '  How should I   taper ', content: 'How should I taper before my race?', createdAt: '2026-10-07T10:00:00Z' }),
    row({ threadId: tid, role: 'assistant', content: 'Cut volume by a third in the final week.', createdAt: '2026-10-07T10:00:04Z' }),
  ] } });
  assertEquals(save, { status: 200, body: { saved: 2, rejected: [] } });

  const { body: list } = await h.json('threads');
  assertEquals(list.threads.length, 1);
  const t = list.threads[0];
  assertEquals(Object.keys(t).sort(), THREAD_KEYS);
  assertEquals(t.id, tid.toLowerCase());
  assertEquals([t.title, t.titleSource, t.origin, t.messageCount, t.pendingMessages], ['How should I taper', 'fallback', 'app', 2, 2]);
  assertEquals(t.needsMaintenance, true, 'nothing curated yet');
  assertEquals(t.preview, 'Cut volume by a third in the final week.');
  assertEquals(t.lastMessageAt, '2026-10-07T10:00:04.000Z');
  assertEquals(t.createdAt, new Date(t.createdAt).toISOString());
  assertEquals(list.folders, []);
  assertEquals([list.hasMore, list.nextCursor], [false, null]);

  const one = await h.json(`threads/${tid}`);
  assertEquals(one.body.thread, t);
  assertEquals((await h.json(`threads/${uuid()}`)).status, 404);
  assertEquals((await h.json(`threads/${tid}`, { token: 'noop_other' })).body, { error: 'thread_not_found' });
});

Deno.test('coach messages: an old build without threadId still saves, grouped into legacy threads by 3-hour gaps', async () => {
  const h = await harness();
  const old = (content: string, createdAt: string, extra = {}) => ({ clientId: uuid(), role: 'user', content, createdAt, meta: {}, ...extra });
  const a = old('first', '2026-10-07T08:00:00Z');
  assertEquals((await h.json('messages', { method: 'POST', body: { messages: [a, old('second', '2026-10-07T08:30:00Z')] } })).body,
    { saved: 2, rejected: [] });
  await h.json('messages', { method: 'POST', body: { messages: [old('third', '2026-10-07T10:00:00Z')] } });
  await h.json('messages', { method: 'POST', body: { messages: [old('much later', '2026-10-07T15:00:00Z')] } });
  // A re-save of a stored row keeps its thread.
  await h.json('messages', { method: 'POST', body: { messages: [{ ...a, content: 'first, edited', createdAt: '2026-10-07T16:00:00Z' }] } });

  const threads = h.db.rows('coach_threads').filter((t) => t.user_id === USER);
  assertEquals(threads.map((t) => [t.origin, t.message_count]).sort(), [['legacy_client', 1], ['legacy_client', 3]]);

  // GET messages without threadId: the original shape and semantics, oldest first across every thread.
  const { body } = await h.json('messages?limit=10');
  assertEquals(body.messages.map((m: any) => m.content), ['first, edited', 'second', 'third', 'much later']);
  for (const m of body.messages) assertEquals(Object.keys(m).sort(), ['clientId', 'content', 'createdAt', 'id', 'meta', 'role']);
  assertEquals(Object.keys(body), ['messages']);
  assertEquals((await h.json('messages?limit=2')).body.messages.map((m: any) => m.content), ['third', 'much later']);
  // Rows without a client id (none exist after the backfill) are skipped.
  h.db.rows('coach_messages').push({ ...h.db.rows('coach_messages')[0], id: uuid(), client_id: null, content: 'orphan', created_at: '2026-10-07T23:00:00+00:00' });
  assert(!(await h.json('messages?limit=10')).body.messages.some((m: any) => m.content === 'orphan'));
});

Deno.test('coach messages: meta merges on re-save, blocked turns are stored as blocked, and bad batches are refused', async () => {
  const h = await harness();
  const tid = uuid();
  const first = row({ threadId: tid, meta: { toolNames: ['Recovery'] } });
  await h.json('messages', { method: 'POST', body: { messages: [first, row({ threadId: tid, content: 'refused', meta: { blocked: true } })] } });
  await h.json('messages', { method: 'POST', body: { messages: [{ ...first, meta: { followUps: ['Why?'] } }] } });
  const stored = h.db.rows('coach_messages').find((m) => m.client_id === first.clientId);
  assertEquals(stored.meta, { toolNames: ['Recovery'], followUps: ['Why?'] });
  assertEquals(h.db.rows('coach_messages').find((m) => m.content === 'refused').blocked, true);

  const bad: unknown[] = [
    [], Array.from({ length: 41 }, () => row({ threadId: tid })), [row({ threadId: 'not-a-uuid' })], [row({ clientId: 'x' })],
    [row({ role: 'system' })], [row({ content: 7 })], [row({ meta: { blob: 'x'.repeat(20_001) } })],
  ];
  for (const messages of bad) assertEquals((await h.send('messages', { method: 'POST', body: { messages } })).status, 400);
  assertEquals((await h.send('messages', { method: 'POST', raw: '{oops' })).status, 400);
});

Deno.test('coach messages: rows for another owner\'s or a deleted thread come back as rejected with a 2xx', async () => {
  const h = await harness();
  const theirs = uuid();
  await h.json('messages', { method: 'POST', token: 'noop_other', body: { messages: [row({ threadId: theirs })] } });
  const mine = uuid();
  const ok = row({ threadId: mine });
  const clash = row({ threadId: theirs });
  const res = await h.json('messages', { method: 'POST', body: { messages: [ok, clash] } });
  assertEquals(res.status, 200);
  assertEquals(res.body, { saved: 1, rejected: [{ clientId: clash.clientId, reason: 'thread_conflict' }] });
  assertEquals(h.db.rows('coach_messages').filter((m) => m.thread_id === theirs).map((m) => m.user_id), [OTHER]);

  assertEquals((await h.json(`threads/${mine}`, { method: 'DELETE' })).body, { deleted: true });
  const late = row({ threadId: mine, content: 'still in the outbox' });
  assertEquals((await h.json('messages', { method: 'POST', body: { messages: [late] } })).body,
    { saved: 0, rejected: [{ clientId: late.clientId, reason: 'thread_deleted' }] });
  assert(!h.db.rows('coach_messages').some((m) => m.thread_id === mine), 'messages go with their thread');
});

Deno.test('coach messages: a thread pages oldest-first through an opaque (created_at, id) cursor without skipping ties', async () => {
  const h = await harness();
  const tid = uuid();
  // Seven rows, three of them in the same microsecond.
  const stamps = ['10:00:00.000001', '10:00:00.000002', '10:00:00.000002', '10:00:00.000002', '10:00:01', '10:00:02.5', '10:00:03'];
  await h.json('messages', { method: 'POST', body: { messages: stamps.map((s, i) => row({ threadId: tid, content: `m${i}`, createdAt: `2026-10-07T${s}Z` })) } });
  // Another thread and another owner never leak in.
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: uuid(), content: 'elsewhere' })] } });

  const seen: string[] = [];
  let cursor: string | null = null;
  let pages = 0;
  do {
    const q: string = `messages?threadId=${tid}&limit=3${cursor ? `&cursor=${cursor}` : ''}`;
    const { body } = await h.json(q);
    assert(body.messages.length <= 3);
    for (const m of body.messages) {
      assertEquals(Object.keys(m).sort(), ['clientId', 'content', 'createdAt', 'id', 'meta', 'role', 'threadId']);
      assertEquals(m.threadId, tid);
    }
    seen.unshift(...body.messages.map((m: any) => m.content));
    cursor = body.nextCursor;
    assertEquals(body.hasMore, cursor !== null);
    pages++;
  } while (cursor && pages < 10);
  assertEquals(pages, 3);
  assertEquals(seen.sort(), ['m0', 'm1', 'm2', 'm3', 'm4', 'm5', 'm6']);
  const latest = (await h.json(`messages?threadId=${tid}&limit=2`)).body.messages.map((m: any) => m.content);
  assertEquals(latest, ['m5', 'm6']);

  assertEquals((await h.json(`messages?threadId=${tid}`, { token: 'noop_other' })).body.messages, []);
  assertEquals((await h.json(`messages?threadId=${tid}&cursor=garbage`)).status, 400);
  assertEquals((await h.json('messages?threadId=nope')).status, 400);
  const c = encodeCursor('2026-10-07T10:00:00.000002+00:00', tid);
  assertEquals(decodeCursor(c), { at: '2026-10-07T10:00:00.000002+00:00', id: tid });
});

Deno.test('coach threads: create is idempotent; another owner\'s id is 409 and a deleted one 410', async () => {
  const h = await harness();
  const id = uuid();
  const first = await h.json('threads', { method: 'POST', body: { id, title: 'Knee rehab' } });
  assertEquals(first.status, 200);
  assertEquals([first.body.thread.title, first.body.thread.titleSource, first.body.thread.messageCount], ['Knee rehab', 'fallback', 0]);
  assertEquals((await h.json('threads', { method: 'POST', body: { id } })).body.thread.id, id);
  assertEquals(h.db.rows('coach_threads').length, 1);

  assertEquals(await h.json('threads', { method: 'POST', body: { id }, token: 'noop_other' }), { status: 409, body: { error: 'thread_conflict' } });
  await h.json(`threads/${id}`, { method: 'DELETE' });
  assertEquals(await h.json('threads', { method: 'POST', body: { id } }), { status: 410, body: { error: 'thread_deleted' } });
  for (const body of [{}, { id: 'x' }, { id: uuid(), title: '' }, { id: uuid(), title: 'x'.repeat(121) }, { id: uuid(), folderId: 'nope' }]) {
    assertEquals((await h.send('threads', { method: 'POST', body })).status, 400);
  }
  assertEquals((await h.json('threads', { method: 'POST', body: { id: uuid(), folderId: uuid() } })).body, { error: 'folder_not_found' });
});

Deno.test('coach threads: rename, pin and move; a user title is marked as such; owners are isolated', async () => {
  const h = await harness();
  const id = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: id, threadTitle: 'Sleep debt' })] } });
  const folder = uuid();
  assertEquals((await h.json('folders', { method: 'POST', body: { id: folder, name: 'Health' } })).status, 200);

  const renamed = (await h.json(`threads/${id}`, { method: 'PATCH', body: { title: '  My   sleep ', pinned: true, folderId: folder } })).body.thread;
  assertEquals([renamed.title, renamed.titleSource, renamed.pinned, renamed.folderId], ['My sleep', 'user', true, folder]);
  const out = (await h.json(`threads/${id}`, { method: 'PATCH', body: { folderId: null } })).body.thread;
  assertEquals([out.folderId, out.title, out.pinned], [null, 'My sleep', true]);

  const theirFolder = uuid();
  await h.json('folders', { method: 'POST', body: { id: theirFolder, name: 'Theirs' }, token: 'noop_other' });
  assertEquals((await h.json(`threads/${id}`, { method: 'PATCH', body: { folderId: theirFolder } })).body, { error: 'folder_not_found' });
  assertEquals((await h.json(`threads/${id}`, { method: 'PATCH', body: { title: 'Mine now' }, token: 'noop_other' })).status, 404);
  assertEquals(h.db.threadRow(id).title, 'My sleep');
  for (const body of [{}, { pinned: 'yes' }, { title: 5 }, { folderId: 'x' }]) {
    assertEquals((await h.send(`threads/${id}`, { method: 'PATCH', body })).status, 400);
  }
  await h.json(`threads/${id}`, { method: 'DELETE', token: 'noop_other' });
  assert(h.db.threadRow(id), 'another owner cannot delete it');
  assertEquals((await h.json(`threads/${id}`, { method: 'PUT', body: {} })).status, 405);
});

Deno.test('coach threads: pinned first on page one, then a cursor over the unpinned ones; folder filters', async () => {
  const h = await harness();
  const folder = uuid();
  await h.json('folders', { method: 'POST', body: { id: folder, name: 'Training' } });
  const ids: string[] = [];
  for (let i = 0; i < 7; i++) {
    const id = uuid();
    ids.push(id);
    await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: id, content: `t${i}`, createdAt: `2026-10-0${i + 1}T09:00:00Z` })] } });
  }
  const empty = uuid();
  await h.json('threads', { method: 'POST', body: { id: empty } });
  await h.json(`threads/${ids[0]}`, { method: 'PATCH', body: { pinned: true } });
  await h.json(`threads/${ids[2]}`, { method: 'PATCH', body: { folderId: folder } });

  const p1 = (await h.json('threads?limit=3')).body;
  // The filed chat comes along on page one although it is older than the page, so its folder is complete.
  assertEquals(p1.threads.map((t: any) => t.preview), ['t0', 't6', 't5', 't4', 't2']);
  assertEquals(p1.threads[0].pinned, true);
  assertEquals(p1.folders.map((f: any) => [f.id, f.name, f.sortOrder]), [[folder, 'Training', 0]]);
  assert(p1.hasMore);
  const p2 = (await h.json(`threads?limit=3&cursor=${p1.nextCursor}`)).body;
  assertEquals(p2.threads.map((t: any) => t.preview), ['t3', 't2', 't1'], 'later pages are by date only');
  const p3 = (await h.json(`threads?limit=3&cursor=${p2.nextCursor}`)).body;
  assertEquals(p3.threads.map((t: any) => t.id), [empty], 'a thread with no messages sorts last');
  assertEquals([p3.hasMore, p3.nextCursor], [false, null]);

  assertEquals((await h.json(`threads?folderId=${folder}`)).body.threads.map((t: any) => t.preview), ['t2']);
  assertEquals((await h.json('threads?folderId=none&limit=3')).body.threads.map((t: any) => t.preview), ['t0', 't6', 't5', 't4'],
    'a folder filter returns only its own page');
  assertEquals((await h.json('threads?folderId=none&limit=100')).body.threads.length, 7);
  assertEquals((await h.json('threads?folderId=bad')).status, 400);
  assertEquals((await h.json('threads?cursor=bad')).status, 400);
  assertEquals((await h.json('threads', { token: 'noop_other' })).body.threads, []);
  // A pinned chat in a folder is listed once, among the pinned.
  await h.json(`threads/${ids[0]}`, { method: 'PATCH', body: { folderId: folder } });
  assertEquals((await h.json('threads?limit=3')).body.threads.map((t: any) => t.preview), ['t0', 't6', 't5', 't4', 't2']);
});

Deno.test('coach folders: idempotent create, rename and reorder, delete leaves its chats unfiled', async () => {
  const h = await harness();
  const a = uuid();
  const b = uuid();
  assertEquals((await h.json('folders', { method: 'POST', body: { id: a, name: ' Running ' } })).body.folder.name, 'Running');
  assertEquals((await h.json('folders', { method: 'POST', body: { id: a, name: 'Other name' } })).body.folder.name, 'Running');
  await h.json('folders', { method: 'POST', body: { id: b, name: 'Food' } });
  assertEquals(await h.json('folders', { method: 'POST', body: { id: a, name: 'x' }, token: 'noop_other' }), { status: 409, body: { error: 'folder_conflict' } });
  for (const body of [{ id: uuid(), name: '' }, { id: uuid(), name: 'x'.repeat(61) }, { id: 'x', name: 'ok' }]) {
    assertEquals((await h.send('folders', { method: 'POST', body })).status, 400);
  }
  const moved = (await h.json(`folders/${a}`, { method: 'PATCH', body: { sortOrder: 5, name: 'Runs' } })).body.folder;
  assertEquals([moved.name, moved.sortOrder], ['Runs', 5]);
  assertEquals(Object.keys(moved).sort(), ['createdAt', 'id', 'name', 'sortOrder', 'updatedAt']);
  assertEquals((await h.json('folders')).body.folders.map((f: any) => f.name), ['Food', 'Runs']);
  assertEquals((await h.json(`folders/${a}`, { method: 'PATCH', body: { name: 'x' }, token: 'noop_other' })).status, 404);
  assertEquals((await h.json(`folders/${a}`, { method: 'PATCH', body: {} })).status, 400);

  const t = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: t })] } });
  await h.json(`threads/${t}`, { method: 'PATCH', body: { folderId: a } });
  assertEquals((await h.json(`folders/${a}`, { method: 'DELETE' })).body, { deleted: true });
  assertEquals((await h.json(`threads/${t}`)).body.thread.folderId, null);
  assertEquals((await h.json('folders')).body.folders.map((f: any) => f.id), [b]);
});

Deno.test('coach threads: search is thread-grouped with snippets, skips blocked turns, and records searches on request', async () => {
  const h = await harness();
  const knee = uuid();
  const sleep = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [
    row({ threadId: knee, threadTitle: 'Knee', content: 'My left knee hurts after hill repeats', createdAt: '2026-09-01T10:00:00Z' }),
    row({ threadId: sleep, threadTitle: 'Sleep', content: 'I slept badly', createdAt: '2026-09-02T10:00:00Z' }),
    row({ threadId: sleep, content: 'secret knee thing', meta: { blocked: true }, createdAt: '2026-09-02T10:01:00Z' }),
  ] } });
  const found = (await h.json('threads?q=knee&record=1')).body;
  assertEquals(found.query, 'knee');
  assertEquals(found.threads.map((t: any) => t.id), [knee]);
  assertEquals(Object.keys(found.threads[0]).sort(), [...THREAD_KEYS, 'snippet'].sort());
  assert(found.threads[0].snippet.includes('«knee»'));
  assertEquals((await h.json('threads?q=the')).body.threads, [], 'a query without searchable words finds nothing');

  for (const q of ['Hill', 'knee', 'KNEE', 'ab']) await h.json(`threads?q=${q}&record=1`);
  await h.json('threads?q=sleep');
  const state = h.db.rows('coach_user_state').find((s) => s.user_id === USER);
  assertEquals(state.recent_searches, ['KNEE', 'Hill'], 'newest first, case-insensitively unique, 3+ characters, only with record=1');
  for (let i = 0; i < 12; i++) await h.json(`threads?q=query${i}&record=1`);
  assertEquals(h.db.rows('coach_user_state').find((s) => s.user_id === USER).recent_searches.length, 10);
  assertEquals((await h.json('threads?q=knee', { token: 'noop_other' })).body.threads, []);
});

Deno.test('coach messages: DELETE clears one thread, or tombstones everything and the searches that name it', async () => {
  const h = await harness();
  const a = uuid();
  const b = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: a }), row({ threadId: b })] } });
  await h.json('messages', { method: 'POST', token: 'noop_other', body: { messages: [row({ threadId: uuid() })] } });
  await h.json('threads?q=hello&record=1');

  assertEquals((await h.json(`messages?threadId=${a}`, { method: 'DELETE' })).body, { deleted: true });
  assertEquals(h.db.rows('coach_threads').filter((t) => t.user_id === USER).map((t) => t.id), [b]);
  assertEquals((await h.json('messages?threadId=x', { method: 'DELETE' })).status, 400);

  assertEquals((await h.json('messages', { method: 'DELETE' })).body, { deleted: true });
  assertEquals(h.db.rows('coach_threads').filter((t) => t.user_id === USER), []);
  assertEquals(h.db.rows('coach_messages').filter((m) => m.user_id === USER), []);
  assertEquals(h.db.rows('coach_thread_tombstones').filter((t) => t.user_id === USER).map((t) => t.thread_id).sort(), [a, b].sort());
  assertEquals(h.db.rows('coach_user_state').find((s) => s.user_id === USER).recent_searches, []);
  assertEquals(h.db.rows('coach_messages').filter((m) => m.user_id === OTHER).length, 1);
  const again = row({ threadId: b });
  assertEquals((await h.json('messages', { method: 'POST', body: { messages: [again] } })).body.rejected, [{ clientId: again.clientId, reason: 'thread_deleted' }]);
});

Deno.test('coach store: database faults stay generic and never echo row content', async () => {
  const h = await harness();
  assertEquals((await h.json('threads/a/b/c')).status, 404);
  h.db.failing.add('coach_messages_save_v1');
  const res = await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: uuid(), content: 'private words' })] } });
  assertEquals(res, { status: 502, body: { error: 'coach_unavailable' } });
  const select = h.rest.select;
  h.rest.select = (table: string, q?: string) => table === 'coach_threads'
    ? Promise.reject(new Error('relation "coach_threads" leaked: private words')) : select(table, q);
  const list = await h.json('threads');
  assertEquals(list, { status: 502, body: { error: 'coach_unavailable' } });
  assertNotEquals(JSON.stringify(list).includes('private'), true);
});

Deno.test('coach threads: deletes go through coach_thread_delete_v1, which tombstones even an unknown id (I4)', async () => {
  const h = await harness();
  const a = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: a })] } });
  assertEquals((await h.json(`threads/${a}`, { method: 'DELETE' })).body, { deleted: true });
  const unknown = uuid();
  assertEquals((await h.json(`threads/${unknown}`, { method: 'DELETE' })).body, { deleted: true });
  assertEquals(h.db.rpcCalls.filter((c) => c.name === 'coach_thread_delete_v1').map((c) => c.args), [
    { p_user: USER, p_thread: a }, { p_user: USER, p_thread: unknown },
  ]);
  // A save still in the outbox for a thread deleted before its first save landed is refused too.
  const late = row({ threadId: unknown });
  assertEquals((await h.json('messages', { method: 'POST', body: { messages: [late] } })).body.rejected, [{ clientId: late.clientId, reason: 'thread_deleted' }]);

  // Everything: every thread, and rows without a thread (none after the backfill, but never left behind).
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: uuid() })] } });
  h.db.rows('coach_messages').push({ ...h.db.rows('coach_messages')[0], id: uuid(), client_id: uuid(), thread_id: null, content: 'orphan' });
  await h.json('messages', { method: 'DELETE' });
  assertEquals(h.db.rpcCalls.filter((c) => c.name === 'coach_thread_delete_v1').at(-1)!.args, { p_user: USER, p_thread: null });
  assertEquals(h.db.rows('coach_messages').filter((m) => m.user_id === USER), []);
  assertEquals(h.db.rows('coach_threads').filter((t) => t.user_id === USER), []);
});

Deno.test("coach messages: an old build's refusal and its question are stored as blocked; its thread is named after a real question (I5)", async () => {
  const h = await harness();
  const old = (role: string, content: string, createdAt: string) => ({ clientId: uuid(), role, content, createdAt, meta: {} });
  const refusal = SHIPPED_REFUSALS[2];
  await h.json('messages', { method: 'POST', body: { messages: [
    old('user', 'How much testosterone should I take?', '2026-10-07T10:00:00Z'),
    old('assistant', refusal, '2026-10-07T10:00:02Z'),
    old('user', 'What about creatine for sprinting?', '2026-10-07T10:01:00Z'),
    old('assistant', 'Creatine is one of the best-studied supplements.', '2026-10-07T10:01:05Z'),
  ] } });
  const stored = (content: string) => h.db.rows('coach_messages').find((m) => m.content === content);
  assertEquals([stored('How much testosterone should I take?').blocked, stored(refusal).blocked], [true, true]);
  assertEquals([stored('What about creatine for sprinting?').blocked, stored('Creatine is one of the best-studied supplements.').blocked], [false, false]);
  const t = h.db.rows('coach_threads').find((x) => x.user_id === USER);
  assertEquals([t.origin, t.title, t.title_source], ['legacy_client', 'What about creatine for sprinting?', 'legacy']);

  // The question saved by an earlier call is marked when its refusal arrives (within 3 s); an older one is not.
  await h.json('messages', { method: 'POST', body: { messages: [old('user', 'Give me a steroid cycle', '2026-10-07T10:02:00Z')] } });
  await h.json('messages', { method: 'POST', body: { messages: [old('assistant', SHIPPED_REFUSALS.at(-1)!, '2026-10-07T10:02:01Z')] } });
  assertEquals(stored('Give me a steroid cycle').blocked, true);
  await h.json('messages', { method: 'POST', body: { messages: [old('user', 'How do I pace a 10k?', '2026-10-07T10:03:00Z')] } });
  await h.json('messages', { method: 'POST', body: { messages: [old('assistant', SHIPPED_REFUSALS[0], '2026-10-07T10:03:09Z')] } });
  assertEquals(stored('How do I pace a 10k?').blocked, false);
  assertEquals(SHIPPED_REFUSALS.length, 11, 'every refusal text any build shipped');
});

Deno.test('coach threads: the sidebar search is light; needsMaintenance follows the forget-all floor (I6, I7)', async () => {
  const h = await harness();
  const id = uuid();
  await h.json('messages', { method: 'POST', body: { messages: [row({ threadId: id, content: 'My knee hurts', createdAt: '2026-10-07T11:00:00Z' })] } });
  await h.json('threads?q=knee');
  assertEquals(h.db.rpcCalls.filter((c) => c.name === 'coach_search_v1').at(-1)!.args.p_light, true);
  assertEquals((await h.json(`threads/${id}`)).body.thread.needsMaintenance, true);
  // Forget all: what was said before it is never mined, and the one message is not enough for a summary yet.
  h.db.advance(60_000);
  await h.json('memories', { method: 'DELETE' });
  h.db.clock = Date.parse('2026-10-07T11:05:00Z');
  assertEquals((await h.json(`threads/${id}`)).body.thread.needsMaintenance, false);
  h.db.clock = Date.parse('2026-10-07T11:10:00Z');
  assertEquals((await h.json('threads')).body.threads[0].needsMaintenance, true, 'quiet: the summary is due');
});
