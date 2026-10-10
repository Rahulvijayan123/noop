import { assert, assertEquals, assertFalse } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { validateManualEventRevision, manualEventRevisionProblem, MANUAL_EVENTS_MAX_BODY_BYTES } from '../_shared/manualEvents.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

const USER = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const SOURCE = '33333333-3333-4333-8333-333333333333';
const OTHER_SOURCE = '44444444-4444-4444-8444-444444444444';
const ID = '55555555-5555-4555-8555-555555555555';
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture-public' };
function revision(over: Record<string, unknown> = {}) {
  return { revision_id: ID, updated_at_ms: 1791000000000, entry: { id: ID, kind: 'event', label: 'Walking',
    symbol: 'figure.walk', typeId: SOURCE, favorite: false, startUnixSeconds: 1791000000,
    endUnixSeconds: 1791000300, timeZoneIdentifier: 'America/Los_Angeles', archived: false, ...over } };
}
async function fixture() {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'a', token_hash: hashIngestToken('noop_a'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: USER, source_id: SOURCE },
    { id: 'b', token_hash: hashIngestToken('noop_b'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: OTHER, source_id: OTHER_SOURCE },
  ]);
  await rest.upsert('noop_app_installations', [{ user_id: USER, source_id: SOURCE }, { user_id: OTHER, source_id: OTHER_SOURCE }]);
  const calls: any[] = [];
  rest.rpc = (name: string, args: any) => {
    calls.push({ name, args });
    if (name === 'manual_event_contexts_v1') return { contexts: args.p_ids.map((id: string) => ({ event: { id }, status: 'ready' })) };
    return { saved: args.p_items.map((r: any) => r.revision_id), rejected: [] };
  };
  return { rest, calls };
}
function request(method: string, body?: unknown, token = 'noop_a', query = '') {
  return new Request(`https://test.invalid/functions/v1/scores/manual-events${query}`, {
    method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: ['GET', 'DELETE'].includes(method) ? undefined : JSON.stringify(body),
  });
}

Deno.test('manual events: completed, running, archived, custom types and duration presets validate', () => {
  assert(validateManualEventRevision(revision()));
  assert(validateManualEventRevision(revision({ endUnixSeconds: null })));
  assert(validateManualEventRevision(revision({ archived: true, archivedAt: 1791001000 })));
  assert(validateManualEventRevision(revision({ kind: 'event_type', label: 'My custom event', favorite: true })));
  assert(validateManualEventRevision(revision({ kind: 'preset', durationMinutes: 5 })));
  assert(validateManualEventRevision(revision({ activityKind: 'walking' })));
  assert(validateManualEventRevision(revision({ kind: 'event_type', activityKind: 'other' })));
});
Deno.test('manual events: reject invalid labels, ranges, presets, ownership fields and malformed text', () => {
  for (const over of [{ label: '' }, { label: ' ' }, { label: 'a'.repeat(101) }, { label: '\0' },
    { label: '\uD800' }, { endUnixSeconds: 1 }, { startUnixSeconds: NaN }, { archived: true },
    { kind: 'preset', durationMinutes: 0 }, { kind: 'preset', durationMinutes: 1441 },
    { note: 'a'.repeat(2001) }, { user_id: OTHER }, { typeId: 'bad' },
    { kind: 'event_type', startUnixSeconds: {} }, { kind: 'event_type', durationMinutes: 'five' },
    { activityKind: 'sprinting' }, { startUnixSeconds: 1000, endUnixSeconds: 2000 }]) {
    assertFalse(validateManualEventRevision(revision(over)), JSON.stringify(over));
  }
  assertFalse(validateManualEventRevision({ ...revision(), owner: OTHER }));
});
Deno.test('manual events: POST derives owner and source from the verified installation', async () => {
  const { rest, calls } = await fixture();
  const response = await handleScoresRequest(request('POST', { revisions: [revision()] }), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(calls[0].args.p_user, USER); assertEquals(calls[0].args.p_source, SOURCE);
  assertEquals(calls[0].name, 'append_manual_event_revisions');
  assertEquals((await response.json()).saved, [ID]);
});
Deno.test('manual events: no deletion, injected owner, unbounded batch, oversized body or unauthenticated request', async () => {
  const { rest, calls } = await fixture();
  assertEquals((await handleScoresRequest(request('DELETE'), { rest, cfg })).status, 405);
  assertEquals((await handleScoresRequest(request('GET', undefined, ''), { rest, cfg })).status, 401);
  for (const body of [{ revisions: [revision()], user_id: OTHER }, { revisions: [] },
    { revisions: Array(26).fill(revision()) }, { revisions: 'all' }]) {
    assertEquals((await handleScoresRequest(request('POST', body), { rest, cfg })).status, 400);
  }
  assertEquals((await handleScoresRequest(request('POST', { padding: 'x'.repeat(MANUAL_EVENTS_MAX_BODY_BYTES) }), { rest, cfg })).status, 413);
  assertEquals(calls.length, 0);
});
Deno.test('manual events: GET filters by credential owner and retains archive payloads', async () => {
  const { rest } = await fixture();
  let scope = '';
  const original = rest.select;
  rest.select = (table: string, query: string) => {
    if (table !== 'manual_event_revisions') return original(table, query);
    scope = query;
    return [{ seq: '8', body: revision({ archived: true, archivedAt: 1791001000 }) }];
  };
  const response = await handleScoresRequest(request('GET', undefined, 'noop_b', '?after=7'), { rest, cfg });
  assertEquals(response.status, 200); assert(scope.startsWith(`user_id=eq.${OTHER}&seq=gt.7&`));
  const page = await response.json();
  assertEquals(page.next, '8'); assertEquals(page.revisions[0].entry.archived, true);
  assertEquals(page.identity.userId, OTHER);
  for (const query of ['?after=-1', '?after=oops', `?user_id=${USER}`]) {
    assertEquals((await handleScoresRequest(request('GET', undefined, 'noop_b', query), { rest, cfg })).status, 400);
  }
});
Deno.test('manual events: paginates retained history without dropping the extra row', async () => {
  const { rest } = await fixture();
  const original = rest.select;
  rest.select = (table: string, query: string) => table !== 'manual_event_revisions' ? original(table, query)
    : Array.from({ length: 101 }, (_, i) => ({ seq: i + 1, body: revision() }));
  const response = await handleScoresRequest(request('GET'), { rest, cfg });
  const page = await response.json();
  assertEquals(page.revisions.length, 100); assertEquals(page.next, '100'); assertEquals(page.has_more, true);
});
Deno.test('manual events: one invalid revision is refused on its own and never holds back the batch', async () => {
  const { rest, calls } = await fixture();
  const good = revision({ id: OTHER_SOURCE });
  const bad = { ...revision({ label: '' }), revision_id: OTHER };
  const response = await handleScoresRequest(request('POST', { revisions: [bad, good, { junk: true }] }), { rest, cfg });
  assertEquals(response.status, 200);
  const reply = await response.json();
  assertEquals(calls.length, 1); assertEquals(calls[0].args.p_items.length, 1);
  assertEquals(reply.saved, [ID]);
  assertEquals(reply.rejected, [{ revision_id: OTHER, reason: 'invalid_label' }, { revision_id: null, reason: 'invalid_revision' }]);
  assertEquals(manualEventRevisionProblem(revision({ note: 'a'.repeat(2001) })), 'invalid_note');
  assertEquals(manualEventRevisionProblem(revision({ endUnixSeconds: 1 })), 'invalid_time');
});
Deno.test('manual events: the database refusal of a conflicting UUID is passed through per revision', async () => {
  const { rest } = await fixture();
  rest.rpc = () => ({ saved: [], rejected: [{ revision_id: ID, reason: 'revision_conflict' }] });
  const reply = await (await handleScoresRequest(request('POST', { revisions: [revision()] }), { rest, cfg })).json();
  assertEquals(reply.saved, []); assertEquals(reply.rejected, [{ revision_id: ID, reason: 'revision_conflict' }]);
});
Deno.test('manual events: context is read for the credential owner only, with bounded ids', async () => {
  const { rest, calls } = await fixture();
  const contextRequest = (query: string) => new Request(
    `https://test.invalid/functions/v1/scores/manual-events/context${query}`, { headers: { authorization: 'Bearer noop_b' } });
  const ok = await handleScoresRequest(contextRequest(`?ids=${ID.toUpperCase()},${ID},${SOURCE}`), { rest, cfg });
  assertEquals(ok.status, 200);
  const reply = await ok.json();
  assertEquals(calls[0].name, 'manual_event_contexts_v1');
  assertEquals(calls[0].args.p_user, OTHER); assertEquals(calls[0].args.p_ids, [ID, SOURCE]);
  assertEquals(reply.contexts.length, 2); assertEquals(reply.identity.userId, OTHER);
  const many = Array.from({ length: 26 }, () => crypto.randomUUID()).join(',');
  for (const query of ['', '?ids=', '?ids=bad', `?ids=${many}`, `?ids=${ID}&user_id=${USER}`]) {
    assertEquals((await handleScoresRequest(contextRequest(query), { rest, cfg })).status, 400, query);
  }
  const post = new Request('https://test.invalid/functions/v1/scores/manual-events/context', {
    method: 'POST', headers: { authorization: 'Bearer noop_b' }, body: '{}' });
  assertEquals((await handleScoresRequest(post, { rest, cfg })).status, 405);
  assertEquals(calls.length, 1);
});
