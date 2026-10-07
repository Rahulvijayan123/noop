import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest, parseAnomalyCandidatesQuery } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/anomaly-candidates: VPS model anomaly windows after a result_revision cursor, owner + device from the
// credential (never the query), oldest change first, retracted rows included so the phone can drop them.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

function row(rev: number, status = 'candidate') {
  return { candidate_key: `joint:beat:${rev}`, start_ts: '2026-10-07T10:00:00Z', end_ts: '2026-10-07T10:30:00Z',
    local_day: '2026-10-07', channels: ['HR', 'HRV'], flagged_by: ['timesfm-3.0', 'units-x128'],
    model_p: { 'timesfm-3.0': 0.0001, 'units-x128': 0.0003 }, score: 4.1, severity: 'strong', direction: 1,
    expected: {}, observed: {}, context: {}, quality: {}, model_versions: {}, status, suppressed_reason: null,
    result_revision: rev, computed_at: '2026-10-07T10:31:00Z' };
}

function fakeRest(rows: Array<ReturnType<typeof row>>, reads: string[]) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') { assert(query.includes(`user_id=eq.${USER}`)); return [{ id: DEVICE }]; }
    if (table === 'anomaly_candidates') {
      reads.push(query);
      assert(query.includes(`user_id=eq.${USER}`) && query.includes(`device_id=eq.${DEVICE}`), 'owner + device scoped');
      assert(query.includes('order=result_revision.asc'), 'oldest change first');
      const since = Number(/result_revision=gt\.(\d+)/.exec(query)![1]);
      return rows.filter((r) => r.result_revision > since).sort((a, b) => a.result_revision - b.result_revision);
    }
    return [];
  };
  return rest;
}

function get(query: string) {
  return new Request(`https://example.test/functions/v1/scores/anomaly-candidates?deviceId=${LOCAL_DEVICE}&${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('anomaly candidates: rows after the cursor, cursor advances, retractions included', async () => {
  const reads: string[] = [];
  const rest = fakeRest([row(5), row(9, 'retracted'), row(12)], reads);
  const res = await handleScoresRequest(get('since=6'), { rest, cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.candidates.map((c: any) => c.result_revision), [9, 12]);
  assertEquals(body.candidates[0].status, 'retracted');
  assertEquals(body.cursor, 12);
  assertEquals(res.headers.get('cache-control'), 'no-store');
});

Deno.test('anomaly candidates: empty page keeps the cursor', async () => {
  const reads: string[] = [];
  const res = await handleScoresRequest(get('since=40'), { rest: fakeRest([row(5)], reads), cfg });
  const body = await res.json();
  assertEquals(body.candidates, []);
  assertEquals(body.cursor, 40);
});

Deno.test('anomaly candidates: bad cursor / limit are 400', () => {
  for (const q of ['since=-1', 'since=abc', 'limit=0', 'limit=201']) {
    let threw = false;
    try { parseAnomalyCandidatesQuery(new URLSearchParams(q)); } catch { threw = true; }
    assert(threw, q);
  }
  assertEquals(parseAnomalyCandidatesQuery(new URLSearchParams('')), { since: 0, limit: 200 });
});

Deno.test('anomaly candidates: POST is not allowed', async () => {
  const req = new Request(`https://example.test/functions/v1/scores/anomaly-candidates?deviceId=${LOCAL_DEVICE}`,
    { method: 'POST', headers: { authorization: 'Bearer noop_test-token' }, body: '{}' });
  const res = await handleScoresRequest(req, { rest: fakeRest([], []), cfg });
  assertEquals(res.status, 405);
});
