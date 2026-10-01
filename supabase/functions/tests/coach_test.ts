import { assert, assertEquals } from 'jsr:@std/assert';
import { coachConfig, handleCoachRequest, normalizeSseChunk } from '../_shared/coach.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';

const cfg = coachConfig({ FIREWORKS_AI_API_KEY: 'fw-test-key', COACH_DAILY_CALL_LIMIT: '3' });

/** makeMemRest for the auth tables; the coach tables get just enough PostgREST semantics (eq/in/order/limit/offset). */
async function fixture() {
  const base = makeMemRest() as any;
  await base.upsert('noop_ingest_tokens', [
    { id: 'personal', token_hash: hashIngestToken('noop_personal'), token_kind: 'installation', user_id: USER, source_id: SOURCE },
    { id: 'other', token_hash: hashIngestToken('noop_other'), token_kind: 'installation', user_id: OTHER, source_id: OTHER_SOURCE },
    { id: 'fleet', token_hash: hashIngestToken('noop_fleet'), token_kind: 'fleet' },
  ]);
  await base.upsert('noop_app_installations', [{ user_id: USER, source_id: SOURCE }, { user_id: OTHER, source_id: OTHER_SOURCE }]);

  const coach = new Map<string, any[]>([['coach_memory_items', []], ['coach_messages', []]]);
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
      for (const r of rows) {
        const list = coach.get(table)!;
        const i = list.findIndex((x) => x.user_id === r.user_id && x.client_id === r.client_id);
        if (i >= 0) list[i] = { ...list[i], ...r };
        else list.push({ id: crypto.randomUUID(), ...r });
      }
    },
    async rpc(name: string, args: any) {
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

  for (let i = 0; i < 60; i++) await save({ content: `fact ${i}`, importance: 2 });
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
  assertEquals(got[1].meta, { pending: 'accepted' });
  assertEquals((await (await handleCoachRequest(call('messages', { token: 'noop_other' }), deps)).json()).messages, []);

  for (const bad of [{ ...msg(0), clientId: 'nope' }, { ...msg(0), role: 'system' }, { ...msg(0), content: 5 }]) {
    assertEquals((await post([bad])).status, 400);
  }
  assertEquals((await post([])).status, 400);

  for (let batch = 0; batch < 13; batch++) {
    await post(Array.from({ length: 40 }, (_, i) => ({ clientId: crypto.randomUUID(), role: 'user', content: 'bulk', createdAt: new Date(Date.UTC(2026, 8, 30, 11, 0, batch * 40 + i)).toISOString() })));
  }
  assertEquals(rest.coach.get('coach_messages').length, 500);
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
