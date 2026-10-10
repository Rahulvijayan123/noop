import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest, parseExerciseWindowsQuery } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/exercise-windows: the RecGym head's SHADOW windows in a time range, owner + device from the credential
// (never the query), oldest first, paged; every row says it is shadow (20261009160000_activity_exercise_windows.sql).

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };
const T0 = 1_791_000_000;

function row(s: number) {
  return { window_start: new Date(s * 1000).toISOString(), window_s: 4, model_id: 'recgym-cnn-transformer',
    model_version: 'recgym-cnn-transformer-e085ac0', weights_sha256: 'a'.repeat(64),
    scaler_version: 'recgym-wrist-imu-scaler-1', preprocessing_version: 'recgym-prep-1', placement: 'bicep',
    placement_supported: false, placement_reason: 'placement_unsupported', top_class: 'Null', top_p: 0.98,
    p_null: 0.98, probs: { Null: 0.98 }, input_sha256: 'b'.repeat(64), release_mode: 'shadow', input_revision: 7,
    result_revision: 3, computed_at: '2026-10-07T10:31:00Z' };
}

function fakeRest(starts: number[], reads: string[]) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') { assert(query.includes(`user_id=eq.${USER}`)); return [{ id: DEVICE }]; }
    if (table === 'activity_exercise_windows') {
      reads.push(query);
      assert(query.includes(`user_id=eq.${USER}`) && query.includes(`device_id=eq.${DEVICE}`), 'owner + device scoped');
      assert(query.includes('order=window_start.asc'), 'oldest first');
      const gte = Date.parse(decodeURIComponent(/window_start=gte\.([^&]+)/.exec(query)![1])) / 1000;
      const lt = Date.parse(decodeURIComponent(/window_start=lt\.([^&]+)/.exec(query)![1])) / 1000;
      const limit = Number(/limit=(\d+)/.exec(query)![1]);
      return starts.filter((s) => s >= gte && s < lt).sort((a, b) => a - b).slice(0, limit).map(row);
    }
    return [];
  };
  return rest;
}

function get(query: string, method = 'GET') {
  return new Request(`https://example.test/functions/v1/scores/exercise-windows?deviceId=${LOCAL_DEVICE}&${query}`, {
    method, headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('exercise windows: the range, oldest first, shadow, paged', async () => {
  const reads: string[] = [];
  const starts = [T0 + 2, T0 + 4, T0 + 6, T0 + 8, T0 + 400];
  const rest = fakeRest(starts, reads);
  const res = await handleScoresRequest(get(`from=${T0}&to=${T0 + 100}`), { rest, cfg });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('cache-control'), 'no-store');
  const body = await res.json();
  assertEquals(body.windows.length, 4);
  assertEquals(body.windows.map((w: any) => Date.parse(w.window_start) / 1000), [T0 + 2, T0 + 4, T0 + 6, T0 + 8]);
  assert(body.windows.every((w: any) => w.release_mode === 'shadow' && w.placement_supported === false));
  assertEquals(body.windows[0].input_revision, '7', 'int64 travels as a decimal string');
  assertEquals(body.next_from, null, 'not a full page');
  assertEquals(body.release_mode, 'shadow');

  const page = await (await handleScoresRequest(get(`from=${T0}&to=${T0 + 100}&limit=2`), { rest, cfg })).json();
  assertEquals(page.windows.length, 2);
  assertEquals(page.next_from, T0 + 5, 'continue after the last window');
  const rest2 = await (await handleScoresRequest(get(`from=${page.next_from}&to=${T0 + 100}&limit=2`), { rest, cfg })).json();
  assertEquals(rest2.windows.map((w: any) => Date.parse(w.window_start) / 1000), [T0 + 6, T0 + 8]);
});

Deno.test('exercise windows: a bad range or limit is refused before any read', async () => {
  for (const q of ['', `from=${T0}`, `from=${T0}&to=${T0}`, `from=${T0 + 10}&to=${T0}`, `from=${T0}&to=${T0 + 86_401}`,
    `from=x&to=${T0}`, `from=${T0}&to=${T0 + 10}&limit=0`, `from=${T0}&to=${T0 + 10}&limit=5001`]) {
    const reads: string[] = [];
    const res = await handleScoresRequest(get(q), { rest: fakeRest([], reads), cfg });
    assertEquals(res.status, 400, q);
    assertEquals(reads.length, 0, q);
  }
  assertEquals(parseExerciseWindowsQuery(new URLSearchParams(`from=${T0}&to=${T0 + 86_400}`)).limit, 5_000);
});

Deno.test('exercise windows: read only', async () => {
  const res = await handleScoresRequest(get(`from=${T0}&to=${T0 + 10}`, 'POST'), { rest: fakeRest([], []), cfg });
  assertEquals(res.status, 405);
});
