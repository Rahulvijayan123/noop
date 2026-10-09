import { assert, assertEquals } from 'jsr:@std/assert';
import { ageOn, coachConfig, handleCoachRequest, normalizeSseChunk, syncHealth } from '../_shared/coach.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';

const cfg = coachConfig({ FIREWORKS_AI_API_KEY: 'fw-test-key', COACH_DAILY_CALL_LIMIT: '3', NOOP_ALLOW_LEGACY_ENROLLMENT: 'true' });

/**
 * makeMemRest for the auth tables; the coach tables get just enough PostgREST semantics (eq/in/order/limit/offset),
 * and the two RPCs every write now goes through get just enough of their contract (docs/COACH_MEMORY.md §3).
 * Threads, folders, the context library and the curator are covered over the fuller fake in coach_fake.ts.
 */
async function fixture() {
  const base = makeMemRest() as any;
  await base.upsert('noop_ingest_tokens', [
    { id: 'personal', token_hash: hashIngestToken('noop_personal'), token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE },
    { id: 'other', token_hash: hashIngestToken('noop_other'), token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: OTHER, source_id: OTHER_SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
  ]);
  await base.upsert('noop_app_installations', [{ user_id: USER, source_id: SOURCE }, { user_id: OTHER, source_id: OTHER_SOURCE }]);

  const coach = new Map<string, any[]>([
    ['coach_memory_items', []], ['coach_messages', []], ['profiles', []], ['user_settings', []],
    ['coach_threads', []], ['coach_thread_tombstones', []], ['coach_user_state', []],
  ]);
  const usage = new Map<string, number>();
  const query = (table: string, q = '') => {
    const params = new URLSearchParams(q);
    let rows = [...coach.get(table)!];
    for (const [k, v] of params) {
      if (v.startsWith('eq.')) rows = rows.filter((r) => String(r[k]) === v.slice(3));
      else if (v.startsWith('in.(')) rows = rows.filter((r) => v.slice(4, -1).split(',').includes(String(r[k])));
    }
    const order = params.get('order');
    if (order) {
      const keys = order.split(',').map((o) => o.split('.'));
      rows.sort((a, b) => {
        for (const [key, dir] of keys) {
          if (a[key] === b[key]) continue;
          return (a[key] < b[key] ? -1 : 1) * (dir === 'desc' ? -1 : 1);
        }
        return 0;
      });
    }
    const offset = Number(params.get('offset') ?? 0);
    const limit = params.get('limit') ? Number(params.get('limit')) : undefined;
    return rows.slice(offset, limit === undefined ? undefined : offset + limit);
  };
  let seq = 0;
  // coach_messages_save_v1: upsert on (user_id, client_id), first created_at kept, meta merged.
  const saveRows = (user: string, rows: any[]) => {
    const list = coach.get('coach_messages')!;
    for (const r of rows) {
      const prior = list.find((x) => x.user_id === user && x.client_id === r.client_id);
      if (prior) Object.assign(prior, { content: r.content, role: r.role, meta: { ...prior.meta, ...r.meta } });
      else list.push({ id: crypto.randomUUID(), user_id: user, client_id: r.client_id, thread_id: r.thread_id, role: r.role, content: r.content, meta: r.meta, created_at: r.created_at });
    }
    return { saved: rows.length, rejected: [], threads: [] };
  };
  // coach_memory_apply_v1: the ops these routes send.
  const applyOps = (user: string, ops: any[]) => ops.map((op) => {
    const list = coach.get('coach_memory_items')!;
    const row = list.find((x) => x.user_id === user && x.id === op.id);
    if (op.op === 'add') {
      const added = { id: crypto.randomUUID(), user_id: user, content: op.content, topic: op.topic, importance: op.importance, confirmations: 1, created_at: new Date(Date.UTC(2026, 8, 30, 0, 0, seq++)).toISOString() };
      list.push(added);
      return { op: 'add', id: added.id, applied: true };
    }
    if (op.op === 'forget_all') coach.set('coach_memory_items', list.filter((x) => x.user_id !== user));
    else if (!row) return { op: op.op, id: op.id, applied: false, reason: 'not_found' };
    else if (op.op === 'confirm') row.confirmations += 1;
    else if (op.op === 'update') Object.assign(row, { content: op.content ?? row.content, topic: op.topic ?? row.topic, importance: op.importance ?? row.importance });
    else if (op.op === 'forget') coach.set('coach_memory_items', list.filter((x) => x !== row));
    return { op: op.op, id: op.id ?? null, applied: true };
  });
  const rest = {
    ...base,
    coach,
    async select(table: string, q?: string) { return coach.has(table) ? query(table, q) : base.select(table, q); },
    async delete(table: string, q: string) {
      const gone = new Set(query(table, q));
      coach.set(table, coach.get(table)!.filter((r) => !gone.has(r)));
    },
    async request(table: string, opts: any = {}) {
      if (!coach.has(table)) return base.request(table, opts);
      const row = { id: crypto.randomUUID(), created_at: new Date(Date.UTC(2026, 8, 30, 0, 0, seq++)).toISOString(), ...opts.body };
      coach.get(table)!.push(row);
      return [row];
    },
    async upsert(table: string, rows: any, opts: any = {}) {
      if (!coach.has(table)) return base.upsert(table, rows, opts);
      const saved: any[] = [];
      for (const r of Array.isArray(rows) ? rows : [rows]) {
        const list = coach.get(table)!;
        const i = list.findIndex((x) => opts.onConflict === 'id' ? x.id === r.id : x.user_id === r.user_id && x.client_id === r.client_id);
        if (i >= 0) list[i] = { ...list[i], ...r };
        else list.push({ id: crypto.randomUUID(), ...r });
        saved.push(i >= 0 ? list[i] : list[list.length - 1]);
      }
      return saved;
    },
    async patch(table: string, body: any, q: string) {
      if (!coach.has(table)) return base.patch(table, body, q);
      const rows = query(table, q);
      for (const r of rows) Object.assign(r, body);
      return rows;
    },
    async rpc(name: string, args: any) {
      if (name === 'coach_messages_save_v1') return saveRows(args.p_user, args.p_rows);
      if (name === 'coach_memory_apply_v1') return applyOps(args.p_user, args.p_ops);
      // coach_thread_delete_v1 with no thread: every thread and message of the owner.
      if (name === 'coach_thread_delete_v1' && args.p_thread == null) {
        const threads = coach.get('coach_threads')!.filter((r) => r.user_id === args.p_user).length;
        coach.set('coach_messages', coach.get('coach_messages')!.filter((r) => r.user_id !== args.p_user));
        coach.set('coach_threads', coach.get('coach_threads')!.filter((r) => r.user_id !== args.p_user));
        return { deleted: threads };
      }
      assertEquals(name, 'coach_take_quota');
      const used = (usage.get(args.p_user_id) ?? 0) + 1;
      if (used > args.p_limit) return false;
      usage.set(args.p_user_id, used);
      return true;
    },
  };
  return { rest: rest as any, usage };
}

function call(path: string, { method = 'GET', body, token = 'noop_personal', fleet = 'noop_fleet' }: { method?: string; body?: unknown; token?: string; fleet?: string } = {}) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  if (fleet) headers['x-noop-fleet-token'] = fleet;
  return new Request(`https://test.invalid/functions/v1/coach/${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const sse = (...chunks: unknown[]) => new Response(
  [...chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`), 'data: [DONE]\n\n'].join(''),
  { headers: { 'content-type': 'text/event-stream' } },
);

function recordingFetch(response: () => Response) {
  const seen: { url: string; headers: Headers; body: any }[] = [];
  const fetchImpl = (async (url: string, init: any) => {
    seen.push({ url, headers: new Headers(init.headers), body: JSON.parse(init.body) });
    return response();
  }) as typeof fetch;
  return { seen, fetchImpl };
}

const hello = { mode: 'chat', messages: [{ role: 'user', content: 'hi' }] };

Deno.test('coach: every route needs the installation bearer plus the fleet credential', async () => {
  const { rest } = await fixture();
  const { seen, fetchImpl } = recordingFetch(() => sse({}));
  for (const [token, fleet] of [['', 'noop_fleet'], ['noop_fleet', ''], ['noop_personal', ''], ['header.payload.signature', 'noop_fleet']]) {
    for (const path of ['status', 'memories', 'messages']) {
      assertEquals((await handleCoachRequest(call(path, { token, fleet }), { rest, cfg, fetchImpl })).status, 401, `${path} ${token}/${fleet}`);
    }
    assertEquals((await handleCoachRequest(call('chat', { method: 'POST', body: hello, token, fleet }), { rest, cfg, fetchImpl })).status, 401);
  }
  assertEquals(seen.length, 0);
  assertEquals((await handleCoachRequest(call('status'), { rest, cfg, fetchImpl })).status, 200);
});

Deno.test('coach status: always the sync policy, and the caller\'s own sync health from account_sync_health_v1', async () => {
  const { rest } = await fixture();
  const NOW = Date.UTC(2026, 9, 9, 12, 0, 0);
  const calls: any[] = [];
  let answer: (args: any) => unknown = () => [];
  const health = { ...rest, async rpc(name: string, args: any) {
    if (name !== 'account_sync_health_v1') return rest.rpc(name, args);
    calls.push(args);
    return answer(args);
  } };
  const status = async (config = cfg, token = 'noop_personal') => {
    const res = await handleCoachRequest(call('status', { token }), { rest: health as any, cfg: config, now: () => NOW });
    assertEquals(res.status, 200);
    return await res.json();
  };
  const row = (user: string, at: string | null) =>
    ({ user_id: user, live_installations: 1, last_upload_at: at, never_uploaded: at === null, stale: false, silent: false });
  const env = { FIREWORKS_AI_API_KEY: 'fw-test-key', NOOP_ALLOW_LEGACY_ENROLLMENT: 'true' };

  answer = (args) => [row(args.p_user_id, '2026-10-09T10:00:00.123456+00:00')];
  const fresh = await status();
  assertEquals(fresh.syncPolicy, { required: true, staleAfterHours: 24 });
  assertEquals(fresh.sync, { required: true, lastUploadAt: '2026-10-09T10:00:00.123Z', stale: false, staleAfterHours: 24 });
  assertEquals(calls.at(-1), { p_stale_after_hours: 24, p_user_id: USER });
  assertEquals([fresh.ok, fresh.features], [true, { threads: 1, context: 1 }], 'the existing keys are unchanged');
  // The account is the credential's, never the request's.
  assertEquals((await status(cfg, 'noop_other')).sync.lastUploadAt, '2026-10-09T10:00:00.123Z');
  assertEquals(calls.at(-1).p_user_id, OTHER);

  // Stale strictly after the window; never uploaded is stale.
  answer = (args) => [row(args.p_user_id, '2026-10-08T11:59:59Z')];
  assertEquals((await status()).sync.stale, true);
  answer = (args) => [row(args.p_user_id, '2026-10-08T12:00:00Z')];
  assertEquals((await status()).sync.stale, false);
  answer = (args) => [row(args.p_user_id, null)];
  assertEquals((await status()).sync, { required: true, lastUploadAt: null, stale: true, staleAfterHours: 24 });

  // The operator's window goes to the RPC and the reply; the off switch is never stale.
  answer = (args) => [row(args.p_user_id, '2026-10-09T10:00:00Z')];
  const tight = await status(coachConfig({ ...env, NOOP_SYNC_STALE_AFTER_HOURS: '1' }));
  assertEquals([tight.syncPolicy, tight.sync.stale, calls.at(-1).p_stale_after_hours], [{ required: true, staleAfterHours: 1 }, true, 1]);
  answer = (args) => [row(args.p_user_id, null)];
  const off = await status(coachConfig({ ...env, NOOP_SYNC_REQUIRED: 'off' }));
  assertEquals(off.syncPolicy, { required: false, staleAfterHours: 24 });
  assertEquals(off.sync, { required: false, lastUploadAt: null, stale: false, staleAfterHours: 24 });
  // Rolled-back threads and a config built without a policy still carry it (the defaults).
  const bare = await status({ ...coachConfig({ ...env, COACH_THREADS_DISABLED: '1' }), syncPolicy: undefined });
  assertEquals(['features' in bare, bare.syncPolicy, bare.sync.stale], [false, { required: true, staleAfterHours: 24 }, true]);

  // Whatever goes wrong with the lookup, status answers 200 with the policy and without `sync`.
  for (const [label, broken] of [
    ['the RPC throws', () => { throw new Error('POST rpc/account_sync_health_v1 failed (404)'); }],
    ['the RPC rejects', () => Promise.reject(new Error('lock timeout'))],
    ['no row (unconfirmed or retired)', () => []],
    ['another account\'s row', () => [row(OTHER, '2026-10-09T10:00:00Z')]],
    ['not a list', () => ({ user_id: USER, last_upload_at: '2026-10-09T10:00:00Z' })],
    ['a malformed timestamp', (args: any) => [row(args.p_user_id, 'yesterday-ish')]],
    ['null', () => null],
  ] as const) {
    answer = broken as (args: any) => unknown;
    const body = await status();
    assertEquals(body.syncPolicy, { required: true, staleAfterHours: 24 }, label);
    assertEquals('sync' in body, false, label);
    assertEquals(body.ok, true, label);
  }
});

Deno.test('coach status: a slow sync-health lookup is abandoned rather than holding status', async () => {
  const hanging = { rpc: () => new Promise(() => {}) } as any;
  const started = Date.now();
  assertEquals(await syncHealth(USER, { required: true, staleAfterHours: 24 }, { rest: hanging, now: Date.now }, 20), null);
  assert(Date.now() - started < 1000);
  // A late rejection after the timeout is swallowed, never an unhandled rejection.
  let reject!: (err: Error) => void;
  const late = { rpc: () => new Promise((_, r) => { reject = r; }) } as any;
  assertEquals(await syncHealth(USER, { required: true, staleAfterHours: 24 }, { rest: late, now: Date.now }, 5), null);
  reject(new Error('late'));
  await new Promise((resolve) => setTimeout(resolve, 10));
});

Deno.test('coach chat: model and limits come from the server; effort is allow-listed; client parameters are dropped', async () => {
  const { rest } = await fixture();
  const roomy = { ...cfg, dailyCallLimit: 50 };
  const cases = [
    { sent: 'none', effort: 'none' }, { sent: 'high', effort: 'high' }, { sent: 'max', effort: 'low' }, { sent: undefined, effort: 'low' },
  ];
  for (const c of cases) {
    const { seen, fetchImpl } = recordingFetch(() => sse({ choices: [{ delta: { content: 'ok' } }] }));
    const res = await handleCoachRequest(call('chat', {
      method: 'POST',
      body: {
        mode: 'chat', messages: [{ role: 'system', content: 's', extra: 'x' }, { role: 'user', content: 'hi' }],
        max_tokens: 10_000_000, temperature: 9, model: 'evil/model', top_p: 1, user: 'u', reasoning_effort: c.sent,
        stream_options: { include_usage: false },
        tools: [{ type: 'function', function: { name: 'get_charge', description: 'd', parameters: { type: 'object', properties: {} }, strict: true }, extra: 1 }],
        tool_choice: 'auto',
      },
    }), { rest, cfg: roomy, fetchImpl });
    assertEquals(res.status, 200);
    await res.text();
    const sent = seen[0].body;
    assertEquals(sent.model, 'accounts/fireworks/models/deepseek-v4p1-flash');
    assertEquals(sent.reasoning_effort, c.effort);
    assertEquals(sent.max_tokens, 4096);
    assertEquals(sent.temperature, 1);
    assertEquals(sent.stream_options, { include_usage: true });
    assertEquals(Object.keys(sent).sort(), ['max_tokens', 'messages', 'model', 'reasoning_effort', 'stream', 'stream_options', 'temperature', 'tool_choice', 'tools']);
    assertEquals(sent.messages[0], { role: 'system', content: 's' });
    assertEquals(sent.tools[0], { type: 'function', function: { name: 'get_charge', description: 'd', parameters: { type: 'object', properties: {} } } });
    assertEquals(seen[0].headers.get('authorization'), 'Bearer fw-test-key');
  }
  const { seen, fetchImpl } = recordingFetch(() => sse({ choices: [{ delta: { content: 'ok' } }] }));
  await (await handleCoachRequest(call('chat', { method: 'POST', body: { ...hello, max_tokens: 1200 } }), { rest, cfg: roomy, fetchImpl })).text();
  assertEquals(seen[0].body.max_tokens, 1200);
});

Deno.test('coach chat: the usage chunk after the last choice is relayed untouched', async () => {
  const { rest } = await fixture();
  const { fetchImpl } = recordingFetch(() => sse(
    { choices: [{ delta: { content: 'Hi' }, finish_reason: 'stop' }] },
    { choices: [], usage: { prompt_tokens: 12, completion_tokens: 3, total_tokens: 15 } },
  ));
  const text = await (await handleCoachRequest(call('chat', { method: 'POST', body: hello }), { rest, cfg, fetchImpl })).text();
  assert(text.includes('"usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}'));
});

Deno.test('coach chat: stream is relayed with reasoning renamed and tool calls intact', async () => {
  const { rest } = await fixture();
  const { fetchImpl } = recordingFetch(() => sse(
    { choices: [{ delta: { reasoning_content: 'hm' } }] },
    { choices: [{ delta: { content: 'Hello' } }] },
    { choices: [{ delta: { tool_calls: [{ index: 0, id: 'c1', type: 'function', function: { name: 'get_charge', arguments: '{}' } }] }, finish_reason: 'tool_calls' }] },
  ));
  const res = await handleCoachRequest(call('chat', { method: 'POST', body: hello }), { rest, cfg, fetchImpl });
  assertEquals(res.headers.get('content-type'), 'text/event-stream');
  const text = await res.text();
  assert(text.includes('"reasoning":"hm"') && !text.includes('reasoning_content'));
  assert(text.includes('"content":"Hello"') && text.includes('"name":"get_charge"') && text.trim().endsWith('data: [DONE]'));
});

Deno.test('coach chat: SSE normalizer leaves non-JSON and [DONE] lines alone', () => {
  assertEquals(normalizeSseChunk('data: [DONE]'), 'data: [DONE]');
  assertEquals(normalizeSseChunk(': keep-alive'), ': keep-alive');
  assertEquals(normalizeSseChunk('data: {oops'), 'data: {oops');
});

Deno.test('coach chat: malformed requests are rejected before quota or provider', async () => {
  const { rest, usage } = await fixture();
  const { seen, fetchImpl } = recordingFetch(() => sse({}));
  const png = 'data:image/png;base64,AAAA';
  const bad: [string, unknown][] = [
    ['bad mode', { ...hello, mode: 'turbo' }],
    ['retired mode', { ...hello, mode: 'deep' }],
    ['no messages', { mode: 'chat', messages: [] }],
    ['bad role', { mode: 'chat', messages: [{ role: 'developer', content: 'x' }] }],
    ['image on text mode', { mode: 'chat', messages: [{ role: 'user', content: [{ type: 'image_url', image_url: { url: png } }] }] }],
    ['remote image url', { mode: 'vision', messages: [{ role: 'user', content: [{ type: 'image_url', image_url: { url: 'https://evil.example/x.png' } }] }] }],
    ['oversized text', { mode: 'chat', messages: [{ role: 'user', content: 'x'.repeat(60_001) }] }],
    ['bad tool name', { ...hello, tools: [{ type: 'function', function: { name: 'rm -rf', description: 'd', parameters: {} } }] }],
    ['too many tools', { ...hello, tools: Array.from({ length: 25 }, (_, i) => ({ type: 'function', function: { name: `t${i}`, description: 'd', parameters: {} } })) }],
    ['tool msg without id', { mode: 'chat', messages: [{ role: 'tool', content: 'x' }] }],
  ];
  for (const [label, body] of bad) {
    const res = await handleCoachRequest(call('chat', { method: 'POST', body }), { rest, cfg, fetchImpl });
    assert([400, 413].includes(res.status), `${label}: ${res.status}`);
  }
  assertEquals((await handleCoachRequest(call('chat', { method: 'POST' }), { rest, cfg, fetchImpl })).status, 400);
  assertEquals(seen.length, 0);
  assertEquals(usage.size, 0);
});

Deno.test('coach chat: daily budget is metered per owner and blocks before the provider', async () => {
  const { rest } = await fixture();
  const { seen, fetchImpl } = recordingFetch(() => sse({ choices: [{ delta: { content: 'ok' } }] }));
  for (let i = 0; i < 3; i++) {
    assertEquals((await handleCoachRequest(call('chat', { method: 'POST', body: hello }), { rest, cfg, fetchImpl })).status, 200);
  }
  const blocked = await handleCoachRequest(call('chat', { method: 'POST', body: hello }), { rest, cfg, fetchImpl });
  assertEquals(blocked.status, 429);
  assertEquals((await blocked.json()).error, 'daily_limit');
  assertEquals(seen.length, 3);
  assertEquals((await handleCoachRequest(call('chat', { method: 'POST', body: hello, token: 'noop_other' }), { rest, cfg, fetchImpl })).status, 200);
});

Deno.test('coach chat: vision mode accepts inline images, answers as JSON, and provider faults stay generic', async () => {
  const { rest } = await fixture();
  const image = { mode: 'vision', stream: false, messages: [{ role: 'user', content: [
    { type: 'text', text: 'describe' }, { type: 'image_url', image_url: { url: 'data:image/jpeg;base64,/9j/4AAQ' } },
  ] }], tools: [{ type: 'function', function: { name: 'ignored', description: 'd', parameters: {} } }] };
  const ok = recordingFetch(() => Response.json({ choices: [{ message: { content: 'a red plate', reasoning_content: 'secret' } }] }));
  const res = await handleCoachRequest(call('chat', { method: 'POST', body: image }), { rest, cfg, fetchImpl: ok.fetchImpl });
  assertEquals(await res.json(), { content: 'a red plate' });
  assertEquals(ok.seen[0].body.model, cfg.models.vision);
  assertEquals(ok.seen[0].body.reasoning_effort, 'none');
  assertEquals(ok.seen[0].body.stream, false);
  assert(!('tools' in ok.seen[0].body));

  const broken = recordingFetch(() => new Response('{"error":"leaky prompt echo"}', { status: 500 }));
  const down = await handleCoachRequest(call('chat', { method: 'POST', body: hello }), { rest, cfg, fetchImpl: broken.fetchImpl });
  assertEquals(down.status, 502);
  assertEquals(await down.json(), { error: 'upstream_error', status: 500 });
  const unconfigured = await handleCoachRequest(call('chat', { method: 'POST', body: hello }), { rest, cfg: { ...cfg, fireworksKey: '' }, fetchImpl: ok.fetchImpl });
  assertEquals(unconfigured.status, 503);
});

Deno.test('coach memories: save, dedupe, rank, cap, forget, and isolation between owners', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  const save = (body: unknown, token = 'noop_personal') => handleCoachRequest(call('memories', { method: 'POST', body, token }), deps);

  const first = await (await save({ content: '  Has a tight left hamstring  ', topic: 'INJURY', importance: 5 })).json();
  assertEquals(first.memory.content, 'Has a tight left hamstring');
  assertEquals(first.memory.topic, 'injury');
  const again = await (await save({ content: 'has a TIGHT left hamstring', importance: 1 })).json();
  assertEquals(again.deduped, true);
  assertEquals(again.memory.id, first.memory.id);

  assertEquals((await save({ content: 'x'.repeat(501) })).status, 400);
  assertEquals((await save({ content: '   ' })).status, 400);
  assertEquals((await (await save({ content: 'Odd topic', topic: 'nonsense', importance: 99 })).json()).memory.importance, 5);

  // Distinct facts: `fact ${i}` would now be one fact whose number keeps changing (a number-aware supersede, §6).
  const word = (i: number) => `${'abcdefghij'[i % 10]}${'abcdefghij'[Math.floor(i / 10)]}q`;
  for (let i = 0; i < 60; i++) await save({ content: `fact ${word(i)}`, importance: 2 });
  const listed = (await (await handleCoachRequest(call('memories'), deps)).json()).memories;
  assertEquals(listed.length, 50);
  assertEquals(listed[0].importance, 5);
  assert(listed.some((m: any) => m.id === first.memory.id), 'the high-importance fact survives eviction');

  await save({ content: 'Only mine' }, 'noop_other');
  const theirs = (await (await handleCoachRequest(call('memories', { token: 'noop_other' }), deps)).json()).memories;
  assertEquals(theirs.map((m: any) => m.content), ['Only mine']);
  assertEquals((await handleCoachRequest(call(`memories/${theirs[0].id}`, { method: 'DELETE' }), deps)).status, 200);
  assertEquals((await (await handleCoachRequest(call('memories', { token: 'noop_other' }), deps)).json()).memories.length, 1);

  assertEquals((await handleCoachRequest(call('memories/not-a-uuid', { method: 'DELETE' }), deps)).status, 400);
  await handleCoachRequest(call(`memories/${first.memory.id}`, { method: 'DELETE' }), deps);
  assert(!(await (await handleCoachRequest(call('memories'), deps)).json()).memories.some((m: any) => m.id === first.memory.id));
  await handleCoachRequest(call('memories', { method: 'DELETE' }), deps);
  assertEquals((await (await handleCoachRequest(call('memories'), deps)).json()).memories, []);
  assertEquals((await (await handleCoachRequest(call('memories', { token: 'noop_other' }), deps)).json()).memories.length, 1);
});

Deno.test('coach messages: idempotent by clientId, ordered oldest-first, bounded, clearable', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  const ids = Array.from({ length: 3 }, () => crypto.randomUUID());
  const msg = (i: number, extra: object = {}) => ({
    clientId: ids[i], role: i % 2 ? 'assistant' : 'user', content: `m${i}`, createdAt: `2026-09-30T10:00:0${i}Z`, meta: {}, ...extra,
  });
  const post = (messages: unknown[], token = 'noop_personal') => handleCoachRequest(call('messages', { method: 'POST', body: { messages }, token }), deps);

  assertEquals((await post([msg(0), msg(1, { meta: { toolNames: ['Recovery'] } })])).status, 200);
  await post([msg(1, { content: 'm1 edited', meta: { pending: 'accepted' } }), msg(2)]);
  const got = (await (await handleCoachRequest(call('messages?limit=10'), deps)).json()).messages;
  assertEquals(got.map((m: any) => m.content), ['m0', 'm1 edited', 'm2']);
  // A re-save merges meta (coach_messages.meta || excluded.meta) instead of replacing it.
  assertEquals(got[1].meta, { toolNames: ['Recovery'], pending: 'accepted' });
  assertEquals((await (await handleCoachRequest(call('messages', { token: 'noop_other' }), deps)).json()).messages, []);

  for (const bad of [{ ...msg(0), clientId: 'nope' }, { ...msg(0), role: 'system' }, { ...msg(0), content: 5 }]) {
    assertEquals((await post([bad])).status, 400);
  }
  assertEquals((await post([])).status, 400);

  for (let batch = 0; batch < 13; batch++) {
    await post(Array.from({ length: 40 }, (_, i) => ({ clientId: crypto.randomUUID(), role: 'user', content: 'bulk', createdAt: new Date(Date.UTC(2026, 8, 30, 11, 0, batch * 40 + i)).toISOString() })));
  }
  // Every save goes through coach_messages_save_v1, which owns retention now (50,000 rows, not 500).
  assertEquals(rest.coach.get('coach_messages').length, 523);
  assertEquals((await handleCoachRequest(call('messages', { method: 'DELETE' }), deps)).status, 200);
  assertEquals((await (await handleCoachRequest(call('messages'), deps)).json()).messages, []);
});

Deno.test('coach: unknown routes and provider-side surprises do not leak', async () => {
  const { rest } = await fixture();
  assertEquals((await handleCoachRequest(call('nope'), { rest, cfg })).status, 404);
  rest.select = async () => { throw new Error('relation "coach_memory_items" does not exist: secret row'); };
  const res = await handleCoachRequest(call('memories'), { rest, cfg });
  assertEquals(res.status, 502);
  assertEquals(await res.json(), { error: 'coach_unavailable' });
});

Deno.test('coach profile: saved fields read back, partial updates keep the rest, owners are isolated', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  const empty = await (await handleCoachRequest(call('profile'), deps)).json();
  assertEquals(empty, { profile: null });

  const put = await handleCoachRequest(call('profile', {
    method: 'PUT',
    body: { displayName: '  Rahul ', dateOfBirth: '1990-04-12', sex: 'male', heightCm: 180.5, weightKg: 77.1107 },
  }), deps);
  assertEquals(put.status, 200);
  const saved = (await put.json()).profile;
  assertEquals({ ...saved, updatedAt: null }, {
    displayName: 'Rahul', dateOfBirth: '1990-04-12', sex: 'male', heightCm: 180.5, weightKg: 77.1107,
    timezone: null, updatedAt: null,
  });

  await handleCoachRequest(call('profile', { method: 'PUT', body: { weightKg: 80 } }), deps);
  const after = (await (await handleCoachRequest(call('profile'), deps)).json()).profile;
  assertEquals([after.displayName, after.dateOfBirth, after.sex, after.heightCm, after.weightKg], ['Rahul', '1990-04-12', 'male', 180.5, 80]);

  const other = await (await handleCoachRequest(call('profile', { token: 'noop_other' }), deps)).json();
  assertEquals(other, { profile: null });
  assertEquals((rest as any).coach.get('profiles').map((r: any) => r.id), [USER]);
});

Deno.test('coach profile: the scorer age follows the birth date and stays inside its 18..90 range', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  const year = new Date().getUTCFullYear();
  const stored = () => (rest as any).coach.get('profiles')[0].reported_age_years;
  const save = (dateOfBirth: string) => handleCoachRequest(call('profile', { method: 'PUT', body: { dateOfBirth } }), deps);

  await save(`${year - 40}-01-01`);
  assertEquals(stored(), 40);
  await save(`${year - 10}-01-01`);
  assertEquals(stored(), null);
  await save(`${year - 95}-01-01`);
  assertEquals(stored(), null);

  assertEquals(ageOn('1990-06-15', new Date('2026-06-14T12:00:00Z')), 35);
  assertEquals(ageOn('1990-06-15', new Date('2026-06-15T00:00:00Z')), 36);
  assertEquals(ageOn('1990-06-15', new Date('2026-12-31T00:00:00Z')), 36);
});

Deno.test('coach profile: invalid values are rejected without touching the stored row', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  const bad: [string, unknown][] = [
    ['empty body', {}],
    ['not an object', [1]],
    ['unknown sex', { sex: 'robot' }],
    ['future birth date', { dateOfBirth: '2999-01-01' }],
    ['rolled-over date', { dateOfBirth: '2026-02-31' }],
    ['ancient birth date', { dateOfBirth: '1800-01-01' }],
    ['malformed date', { dateOfBirth: '12/04/1990' }],
    ['weight too small', { weightKg: 5 }],
    ['weight not a number', { weightKg: '80' }],
    ['height too large', { heightCm: 400 }],
    ['name too long', { displayName: 'x'.repeat(81) }],
    ['name not a string', { displayName: 7 }],
  ];
  for (const [label, body] of bad) {
    const res = await handleCoachRequest(call('profile', { method: 'PUT', body }), deps);
    assertEquals(res.status, 400, label);
    await res.body?.cancel();
  }
  assertEquals((rest as any).coach.get('profiles').length, 0);
  assertEquals((await handleCoachRequest(call('profile', { method: 'DELETE' }), deps)).status, 405);
  assertEquals((await handleCoachRequest(call('profile', { token: '' }), deps)).status, 401);
});

Deno.test('coach settings: the sign-up defaults are not a saved choice, and other keys in the row survive', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  // The row sign-up creates: column defaults nobody chose, plus a key an earlier client wrote.
  (rest as any).coach.get('user_settings').push({ user_id: USER, units: 'imperial', extra_settings: { wear_location: 'wrist' } });
  assertEquals(await (await handleCoachRequest(call('settings'), deps)).json(), { settings: null });

  const put = await handleCoachRequest(call('settings', {
    method: 'PUT', body: { units: 'metric', batteryAlerts: false, moveReminderMinutes: 45, hapticLiftRest: false },
  }), deps);
  assertEquals(put.status, 200);
  assertEquals((await put.json()).settings, { units: 'metric', moveReminderMinutes: 45, batteryAlerts: false, hapticLiftRest: false });
  const row = (rest as any).coach.get('user_settings')[0];
  assertEquals(row.units, 'metric', 'units is mirrored to the typed column');
  assertEquals(row.extra_settings.wear_location, 'wrist');

  await handleCoachRequest(call('settings', { method: 'PUT', body: { sanaEnabled: false, batteryAlerts: true } }), deps);
  const after = (await (await handleCoachRequest(call('settings'), deps)).json()).settings;
  assertEquals(after, { units: 'metric', sanaEnabled: false, moveReminderMinutes: 45, batteryAlerts: true, hapticLiftRest: false });

  assertEquals(await (await handleCoachRequest(call('settings', { token: 'noop_other' }), deps)).json(), { settings: null });
  assertEquals((rest as any).coach.get('user_settings').map((r: any) => r.user_id), [USER]);
});

Deno.test('coach settings: a first save creates the row, and invalid values never reach it', async () => {
  const { rest } = await fixture();
  const deps = { rest, cfg };
  const bad: [string, unknown][] = [
    ['empty body', {}],
    ['not an object', [true]],
    ['unknown units', { units: 'nautical' }],
    ['boolean as a string', { batteryAlerts: 'true' }],
    ['minutes below range', { moveReminderMinutes: 5 }],
    ['minutes not whole', { moveReminderMinutes: 47.5 }],
    ['buzzes above range', { moveReminderBuzzes: 9 }],
    ['minute of day past midnight', { moveReminderEndMinute: 1440 }],
  ];
  for (const [label, body] of bad) {
    const res = await handleCoachRequest(call('settings', { method: 'PUT', body }), deps);
    assertEquals(res.status, 400, label);
    await res.body?.cancel();
  }
  assertEquals((rest as any).coach.get('user_settings').length, 0);
  // A newer app's keys are not an error, and not stored either.
  const unknown = await handleCoachRequest(call('settings', { method: 'PUT', body: { somethingNew: true } }), deps);
  assertEquals(unknown.status, 200);
  assertEquals(await unknown.json(), { settings: null });
  assertEquals((rest as any).coach.get('user_settings').length, 0);

  const put = await handleCoachRequest(call('settings', { method: 'PUT', body: { zoneCoaching: true, somethingNew: 1 } }), deps);
  assertEquals((await put.json()).settings, { zoneCoaching: true });
  assertEquals((rest as any).coach.get('user_settings')[0].extra_settings, { nara: { zoneCoaching: true } });
  assertEquals((await handleCoachRequest(call('settings', { method: 'DELETE' }), deps)).status, 405);
  assertEquals((await handleCoachRequest(call('settings', { token: '' }), deps)).status, 401);
});
