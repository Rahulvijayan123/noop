import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { readActivityWindows, readGaitWindows } from '../_shared/serverScores.ts';

// Activity DB contracts on the whole migration chain (docs/model-integration/activity-authority.md), in the
// throwaway harness only: every activity *_contract.sql (each rolls back), then the /gait-windows and
// /activity-windows reads through real PostgREST against rows written by the real publish functions, so the
// release columns, the trigger and the route's select lists are proven together.

const CONTRACTS = [
  'activity_context_contract.sql',
  'activity_encoder_windows_contract.sql',
  'activity_gait_windows_contract.sql',
  'activity_motion_heads_contract.sql',
  'activity_release_authority_contract.sql',
];

async function psqlFile(base: string, file: URL) {
  const r = await new Deno.Command('/opt/homebrew/bin/psql', {
    args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', base, '-U', 'edge_test', '-d', 'postgres',
      '-f', decodeURIComponent(file.pathname)],
    stdout: 'piped', stderr: 'piped', clearEnv: true,
  }).output();
  const err = new TextDecoder().decode(r.stderr);
  if (!r.success) throw new Error(`${file.pathname.split('/').pop()} failed: ${err.slice(-2000)}`);
  return err;
}

Deno.test('activity contracts and release-aware routes on the full migration chain', async (t) => {
  const db = await startLocalPostgres({ fullChain: true });
  try {
    for (const name of CONTRACTS) {
      await t.step(name, async () => {
        const notices = await psqlFile(db.base, new URL(name, import.meta.url));
        assert.match(notices, /PASS/, `${name} reports its passes`);
      });
    }

    await t.step('the migration is idempotent: applied again, its contract still holds', async () => {
      await psqlFile(db.base, new URL('../../migrations/20261008100600_activity_release_authority.sql', import.meta.url));
      const notices = await psqlFile(db.base, new URL('activity_release_authority_contract.sql', import.meta.url));
      assert.match(notices, /PASS 4 privileges/);
    });

    await t.step('routes read the release columns written by the real publish functions', async () => {
      const device = 'e0000000-0000-4000-8000-000000000011';
      const day = '2026-12-05';
      await db.sql(`
        insert into public.devices(id,user_id,source_kind) values ('${device}','${USER_A}','noop_push');
        do $$
        declare fp text; lo bigint := extract(epoch from ('${day}'::date::timestamp at time zone 'UTC'))::bigint;
          j record; w jsonb; dg text; m jsonb;
        begin
          fp := public.activity_context_fingerprint(array[repeat('7',64)],lo,lo+86399,'hart-activity-1',
            'hart-activity-v1','hart-activity-preprocess-v1','v1');
          perform public.enqueue_activity_context('${USER_A}','${device}','${day}',array[gen_random_uuid()],
            array[repeat('7',64)],fp);
          select * into j from public.claim_activity_context_v2(300);
          select jsonb_object_agg(h, repeat('a', 64)) into w
            from unnest(array['gait_detection','gait_speed','gait_length','cadence','regularity','step_count']) as h;
          select encode(sha256(convert_to('eldernet-weights-1' || chr(10)
            || string_agg(key || '=' || (value #>> '{}') || chr(10), '' order by key collate "C"), 'UTF8')), 'hex')
            into dg from jsonb_each(w);
          m := jsonb_build_object('model_id','eldernet','model_version','eldernet-437a38b','weights',w,
            'upstream_commit','437a38bcc69f42717fe73c1f7dbea7e1f7a50d23','preprocessing_version','eldernet-prep-1',
            'window_s',10,'hop_s',5,'gait_threshold',0.5);
          perform public.publish_activity_gait_windows_day(j.lease_token, j.input_revision, jsonb_build_object(
            'day','${day}','mode','candidate','schema','gait-quality-1','model',m,'weights_digest',dg,
            'summary',jsonb_build_object('n_windows',0,'n_gait',0,'n_prefiltered',0,'n_dropped_nonfinite',0,
              'authority',jsonb_build_object('policy','expert-authority-1','release_mode','shadow','use','none',
                'reason','model_not_pinned','input_revision',j.input_revision::text)),
            'windows',null,'withheld_reason','model_not_pinned','candidate_document',null));
        end $$;`);
      const legacy = await readGaitWindows({ rest: db.rest, userId: USER_A, deviceId: device, days: [day],
        known: new Map() });
      assert.equal(legacy.length, 1);
      assert.equal((legacy[0] as any).model, undefined, 'a phone without the capability gets no decoder model');
      assert.equal((legacy[0] as any).release_mode, 'shadow');
      const rows = await readGaitWindows({ rest: db.rest, userId: USER_A, deviceId: device, days: [day],
        known: new Map(), authorityAware: true });
      assert.equal(rows.length, 1);
      const row: any = rows[0];
      assert.equal(row.mode, 'candidate');
      assert.equal(row.release_mode, 'shadow', 'the block lowered the candidate row to shadow');
      assert.equal(row.authority.reason, 'model_not_pinned');
      assert.equal(row.authority.release_mode, 'shadow');
      assert.match(row.input_revision, /^[0-9]+$/);
      assert.equal(row.identity.model_id, 'eldernet');
      assert.match(row.identity.weights_digest, /^[0-9a-f]{64}$/);
      assert.equal(row.candidate_document, undefined, 'the candidate decode is never sent');
      const windows = await readActivityWindows({ rest: db.rest, userId: USER_A, deviceId: device, days: [day],
        known: new Map() });
      assert.equal(windows.length, 0, 'no HART windows were stored for this day');
      // The candidate table is the worker's alone: an owner token cannot read it through PostgREST.
      const owner = await db.request('activity_candidate_days?select=day');
      assert.notEqual(owner.status, 200, 'no owner read of the candidate table');
    });
  } finally {
    await db.close();
  }
});
