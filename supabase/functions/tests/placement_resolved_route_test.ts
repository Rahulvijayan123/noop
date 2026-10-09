import { assert, assertEquals } from 'jsr:@std/assert';
import { hashIngestToken } from '../_shared/tokens.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { makeMemRest } from './helpers.ts';

// GET /scores/placement?deviceId=: the strap's resolved placement (20261009150100) next to the owner's rows, the
// device resolved like every other route's. Without deviceId the response is unchanged.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';
const STRAP_ID = '11111111-1111-4111-8111-111111111111';
const SOURCE = '22222222-2222-4222-8222-222222222222';
const cfg = { supabaseUrl: 'https://example.test', supabaseAnonKey: 'anon', allowLegacyEnrollment: true };

function fakeRest(calls: Array<{ fn: string; args: any }>) {
  const rest = makeMemRest() as any;
  rest.select = async (table: string, query: string) => {
    if (table === 'noop_ingest_tokens') return query.includes(hashIngestToken('noop_test-token'))
      ? [{ id: 'tok', token_kind: 'installation', provisioning_method: 'enrollment_code', user_id: USER, source_id: SOURCE }]
      : [{ id: 'fleet', token_kind: 'fleet' }];
    if (table === 'noop_app_installations') return [{ user_id: USER, source_id: SOURCE }];
    if (table === 'placement_intervals') return [];
    if (table === 'devices') {
      assert(query.includes(`user_id=eq.${USER}`));
      return query.includes('external_device_id=eq.whoop-MGB0000001') ? [{ id: STRAP_ID }] : [];
    }
    return [];
  };
  rest.rpc = async (fn: string, args: any) => {
    calls.push({ fn, args });
    return [{ scope: 'device', basis: 'installation', placement: 'bicep',
      wrist_model_reason: { code: 'placement_unsupported', certainty: 'confirmed' } }];
  };
  return rest;
}

function get(query = '') {
  return new Request(`https://example.test/functions/v1/scores/placement${query}`, {
    headers: { authorization: 'Bearer noop_test-token', 'x-noop-fleet-token': 'noop_fleet' },
  });
}

Deno.test('placement GET: deviceId adds the strap\'s resolved timeline', async () => {
  const calls: Array<{ fn: string; args: any }> = [];
  const res = await handleScoresRequest(get('?deviceId=whoop-MGB0000001'), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200, await res.clone().text());
  const body = await res.json();
  assertEquals(body.intervals, []);
  assertEquals(body.resolved.device_id, 'whoop-MGB0000001');
  assertEquals(body.resolved.intervals[0].wrist_model_reason.code, 'placement_unsupported');
  assertEquals(calls, [{ fn: 'placement_resolved_read_v1', args: { p_user: USER, p_device: STRAP_ID } }]);
});

Deno.test('placement GET: without deviceId nothing changes; a bad or unknown device is refused', async () => {
  let calls: Array<{ fn: string; args: any }> = [];
  let res = await handleScoresRequest(get(), { rest: fakeRest(calls), cfg });
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { intervals: [] });
  assertEquals(calls.length, 0);
  res = await handleScoresRequest(get('?deviceId=whoop-UNKNOWN01'), { rest: fakeRest(calls = []), cfg });
  assertEquals(res.status, 409);
  assertEquals((await res.json()).error, 'device_registration_pending');
  res = await handleScoresRequest(get('?deviceId=me%40example.com'), { rest: fakeRest(calls = []), cfg });
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'invalid_device_id');
  assertEquals(calls.length, 0);
});
