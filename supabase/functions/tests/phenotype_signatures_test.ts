import { assert, assertEquals, assertFalse } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { manualEventRevisionProblem, validateManualEventRevision } from '../_shared/manualEvents.ts';
import { readSignatureReport, SIGNATURE_REPORT_VERSION } from '../_shared/personalEvents.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';

// docs/PHENOTYPE_SIGNATURES.md: observation periods and onset uncertainty in the manual log, and
// GET /scores/event-detection/signature?typeId=<uuid>.
const A = '11111111-1111-4111-8111-111111111111', B = '22222222-2222-4222-8222-222222222222';
const S = '33333333-3333-4333-8333-333333333333', T = '44444444-4444-4444-8444-444444444444';
const T2 = '55555555-5555-4555-8555-555555555555', ID = '66666666-6666-4666-8666-666666666666';
const cfg = { supabaseUrl: 'https://test.invalid', supabaseAnonKey: 'fixture' };

function revision(over: Record<string, unknown> = {}) {
  return { revision_id: ID, updated_at_ms: 1791000000000, entry: { id: ID, kind: 'event', label: 'Absence',
    symbol: 'brain.head.profile', typeId: T, favorite: false, startUnixSeconds: 1791000000,
    endUnixSeconds: 1791000060, timeZoneIdentifier: 'UTC', archived: false, ...over } };
}
function observation(over: Record<string, unknown> = {}) {
  const { typeId: _t, ...entry } = revision().entry;
  return { ...revision(), entry: { ...entry, kind: 'observation', label: 'Observation', symbol: 'eye',
    startUnixSeconds: 1791000000, endUnixSeconds: 1791007200, ...over } };
}

Deno.test('observation periods: a closed window of at most a day, with no type of its own', () => {
  assert(validateManualEventRevision(observation()));
  assert(validateManualEventRevision(observation({ note: 'Watched all afternoon', deviceId: 'my-whoop' })));
  assert(validateManualEventRevision(observation({ endUnixSeconds: 1791000000 + 86400 })));
  assert(validateManualEventRevision(observation({ archived: true, archivedAt: 1791010000 })));
  assert(validateManualEventRevision(observation({ typeId: null })));
  const refused: [Record<string, unknown>, string][] = [
    [{ endUnixSeconds: null }, 'invalid_time'], [{ endUnixSeconds: 1791000000 }, 'invalid_time'],
    [{ endUnixSeconds: 1790999999 }, 'invalid_time'], [{ endUnixSeconds: 1791000000 + 86401 }, 'invalid_time'],
    [{ startUnixSeconds: null }, 'invalid_time'], [{ startUnixSeconds: 1000, endUnixSeconds: 2000 }, 'invalid_time'],
    [{ typeId: T }, 'invalid_entry'], [{ activityKind: 'rest' }, 'invalid_entry'], [{ durationMinutes: 60 }, 'invalid_entry'],
    [{ onsetUncertaintyMinutes: 5 }, 'invalid_onset_uncertainty'], [{ kind: 'observations' }, 'invalid_entry'],
    [{ label: '' }, 'invalid_label'], [{ user_id: B }, 'invalid_entry']];
  for (const [over, reason] of refused) assertEquals(manualEventRevisionProblem(observation(over)), reason, JSON.stringify(over));
});

Deno.test('onset uncertainty: 0, 5, 15 or 60 minutes, on events only', () => {
  for (const minutes of [0, 5, 15, 60]) assert(validateManualEventRevision(revision({ onsetUncertaintyMinutes: minutes })));
  assert(validateManualEventRevision(revision({ onsetUncertaintyMinutes: null })));
  for (const minutes of [1, 10, 30, -5, 5.5, '5', true, 1440]) {
    assertEquals(manualEventRevisionProblem(revision({ onsetUncertaintyMinutes: minutes })), 'invalid_onset_uncertainty');
  }
  for (const kind of ['event_type', 'preset']) {
    assertEquals(manualEventRevisionProblem(revision({ kind, durationMinutes: 5, onsetUncertaintyMinutes: 5 })),
      'invalid_onset_uncertainty');
  }
});

async function fixture(runs: any[]) {
  const rest = makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens', [
    { id: 'a', token_hash: hashIngestToken('noop_a'), token_kind: 'installation', provisioning_method: 'supabase_auth', user_id: A, source_id: S }]);
  await rest.upsert('noop_app_installations', [{ user_id: A, source_id: S }]);
  const reads: { table: string; query: string }[] = [];
  const select = rest.select;
  // The runs table as PostgREST would filter it on user_id and type_id (order and json filters are left to the route).
  rest.select = (table: string, query: string) => {
    if (table !== 'event_detector_runs') return select.call(rest, table, query);
    reads.push({ table, query });
    const user = /user_id=eq\.([^&]+)/.exec(query)?.[1], type = /type_id=eq\.([^&]+)/.exec(query)?.[1];
    return runs.filter(r => r.user_id === user && r.type_id === type);
  };
  return { rest, reads };
}
const report = (status: string, extra: Record<string, unknown> = {}) =>
  ({ version: SIGNATURE_REPORT_VERSION, type_id: T, generated_at: 1791600000, status, alerts_enabled: false, ...extra });
const get = (suffix: string, token = 'noop_a') => new Request(
  `https://test.invalid/functions/v1/scores/event-detection/signature${suffix}`,
  { method: 'GET', headers: { authorization: `Bearer ${token}` } });

Deno.test('signature route: the newest signature-report-1 of the caller and type, never another owner', async () => {
  const runs = [
    { user_id: A, type_id: T, id: '1', created_at: '2026-10-09T08:00:00.000000+00:00', report: report('individual_context') },
    { user_id: A, type_id: T, id: '2', created_at: '2026-10-09T10:00:00.000000+00:00', report: report('emerging', { unknown_field: [1] }) },
    // Newer, but another version, another type or another owner.
    { user_id: A, type_id: T, id: '3', created_at: '2026-10-09T11:00:00.000000+00:00', report: { version: 'grid-report-0', status: 'active' } },
    { user_id: A, type_id: T2, id: '4', created_at: '2026-10-09T12:00:00.000000+00:00', report: report('established') },
    { user_id: B, type_id: T, id: '5', created_at: '2026-10-09T12:00:00.000000+00:00', report: report('established') },
  ];
  const { rest, reads } = await fixture(runs);
  const response = await handleScoresRequest(get(`?typeId=${T}`), { rest, cfg });
  assertEquals(response.status, 200);
  assertEquals(response.headers.get('cache-control'), 'no-store');
  const body = await response.json();
  assertEquals(body.report.status, 'emerging');
  assertEquals(body.report.unknown_field, [1], 'the report is returned as stored');
  assertEquals(body.identity, { userId: A, sourceId: S });
  assertEquals(reads.length, 1);
  assert(reads[0].query.startsWith(`user_id=eq.${A}&type_id=eq.${T}&report->>version=eq.signature-report-1`));
  assert(reads[0].query.includes('order=created_at.desc') && reads[0].query.includes('limit=1'));
  // Upper-case type ids name the same type.
  assertEquals((await (await handleScoresRequest(get(`?typeId=${T.toUpperCase()}`), { rest, cfg })).json()).report.status, 'emerging');
});

Deno.test('signature route: no report yet is null; bad queries are 400; no credential is 401; writes are refused', async () => {
  const { rest, reads } = await fixture([]);
  const empty = await handleScoresRequest(get(`?typeId=${T}`), { rest, cfg });
  assertEquals(empty.status, 200);
  assertEquals((await empty.json()).report, null);
  for (const suffix of ['', '?typeId=bad', `?typeId=${T}&user_id=${B}`, `?typeId=${T}&typeId=${T2}`, `?type=${T}`,
    `?typeId=${T}'`]) {
    assertEquals((await handleScoresRequest(get(suffix), { rest, cfg })).status, 400, suffix);
  }
  assertEquals((await handleScoresRequest(get(`?typeId=${T}`, ''), { rest, cfg })).status, 401);
  const post = new Request('https://test.invalid/functions/v1/scores/event-detection/signature',
    { method: 'POST', headers: { authorization: 'Bearer noop_a', 'content-type': 'application/json' }, body: '{}' });
  assertEquals((await handleScoresRequest(post, { rest, cfg })).status, 405);
  assertEquals(reads.length, 1, 'only the valid request read the table');
});

Deno.test('signature route: rows the database should have filtered are filtered again', async () => {
  const rest = { select: async () => [
    { user_id: B, type_id: T, id: '9', created_at: '2026-10-10', report: report('established') },
    { user_id: A, type_id: T, id: '8', created_at: '2026-10-10', report: 'not an object' },
    { user_id: A, type_id: T, id: '7', created_at: '2026-10-09', report: report('no_reliable_signature') },
  ] } as any;
  assertEquals((await readSignatureReport(rest, A, new URLSearchParams({ typeId: T }))).report.status, 'no_reliable_signature');
  assertFalse((await readSignatureReport({ select: async () => [] } as any, A, new URLSearchParams({ typeId: T }))).report);
});
