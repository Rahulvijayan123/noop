import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest, parseActivityWindowsQuery } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/activity-windows: HART's per-window output for the phone's own decoder. The owner and device
// come from the credential (never the query), at most three UTC days are read, and a day the phone already
// holds at its current revision comes back without its windows.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const DEVICE = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const LOCAL_DEVICE = 'whoop-MGB0214654';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

const DOC = { format: 'hart-windows-1', t0: 1791158400, labels: ['stationary', 'unknown'], features: [],
  feature_scale: [], s: [0], e: [4], l: [0], p: [[1000, 0]], b: [0], f: [null] };

function fakeRest(rows: Array<{ day: string; result_revision: number }>, reads: string[]) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'devices') { assert(query.includes(`user_id=eq.${USER}`)); return [{ id: DEVICE }]; }
    if (table === 'activity_encoder_windows') {
      reads.push(query);
      assert(query.includes(`user_id=eq.${USER}`) && query.includes(`device_id=eq.${DEVICE}`),
        'every read is scoped to the credential owner and the resolved device');
      assert(query.includes('algorithm_version=eq.hart-activity-1'));
      const days = /day=in\.\(([^)]*)\)/.exec(query)![1].split(',');
      const selected = rows.filter((r) => days.includes(r.day));
      return query.includes('windows')
        ? selected.map((r) => ({ day: r.day, result_revision: r.result_revision, windows: DOC }))
        : selected.map((r) => ({ day: r.day, encoder_id: 'hart', model_version: 'hart-wisdm-v0',
          preprocessing_version: '1.0.0', feature_schema: 'imu-feat-1', window_count: 1, first_ts: 1791158400,
          last_ts: 1791158404, input_revision: 5, result_revision: r.result_revision,
          computed_at: '2026-10-05T12:00:00Z' }));
    }
    return [];
  };
  return rest;
}

function get(query: string) {
  return new Request(`https://example.test/functions/v1/scores/activity-windows?deviceId=${LOCAL_DEVICE}&${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('activity windows: returns the owner\'s windows and skips a day the phone already holds', async () => {
  const reads: string[] = [];
  const rest = fakeRest([{ day: '2026-10-04', result_revision: 7 }, { day: '2026-10-05', result_revision: 12 }], reads);
  const res = await handleScoresRequest(get('days=2026-10-04,2026-10-05&known=2026-10-04:7'), { rest, cfg });
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.identity.deviceId, DEVICE);
  const byDay = Object.fromEntries(body.days.map((d: any) => [d.day, d]));
  assertEquals(byDay['2026-10-04'].unchanged, true);
  assertEquals(byDay['2026-10-04'].windows, undefined);
  assertEquals(byDay['2026-10-05'].result_revision, '12');
  assertEquals(byDay['2026-10-05'].windows.format, 'hart-windows-1');
  assertEquals(reads.length, 2);
  assert(reads[1].includes('day=in.(2026-10-05)'), 'only the changed day\'s document is read');
});

Deno.test('activity windows: a day with no stored windows is simply absent', async () => {
  const reads: string[] = [];
  const res = await handleScoresRequest(get('days=2026-10-05'), { rest: fakeRest([], reads), cfg });
  assertEquals(res.status, 200);
  assertEquals((await res.json()).days, []);
  assertEquals(reads.length, 1, 'nothing to download, no second read');
});

Deno.test('activity windows: malformed queries are rejected before the database is asked', async () => {
  for (const query of ['', 'days=2026-13-45', 'days=2026-10-01,2026-10-02,2026-10-03,2026-10-04',
    'days=2026-10-05,2026-10-05', 'days=2026-10-05&known=2026-10-04:3', 'days=2026-10-05&known=2026-10-05:x',
    'days=2026-10-05);drop', 'days=2026-02-30']) {
    const reads: string[] = [];
    const res = await handleScoresRequest(get(query), { rest: fakeRest([], reads), cfg });
    assertEquals(res.status, 400, query);
    assertEquals(reads.length, 0, query);
  }
});

Deno.test('activity windows: query parser', () => {
  const q = parseActivityWindowsQuery(new URLSearchParams('days=2026-10-04,2026-10-05&known=2026-10-05:99'));
  assertEquals(q.days, ['2026-10-04', '2026-10-05']);
  assertEquals(q.known.get('2026-10-05'), '99');
});

Deno.test('activity windows: every row says its input revision and release (HART production, embedded gait shadow)', async () => {
  const rest = fakeRest([{ day: '2026-10-04', result_revision: 7 }, { day: '2026-10-05', result_revision: 12 }], []);
  const res = await handleScoresRequest(get('days=2026-10-04,2026-10-05&known=2026-10-04:7'), { rest, cfg });
  const byDay = Object.fromEntries((await res.json()).days.map((d: any) => [d.day, d]));
  for (const day of ['2026-10-04', '2026-10-05']) {
    assertEquals(byDay[day].input_revision, '5', day);
    assertEquals(byDay[day].release_mode, 'production', day);
    assertEquals(byDay[day].embedded_gait_release_mode, 'shadow', day);
  }
});
