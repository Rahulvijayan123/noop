import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves the fenced 6-arg publish_metric_series_v1 (20261003202000_metric_series_input_revision_fence.sql):
//  - a pass claiming an OLDER input_revision than the day's latest scoring_jobs_v2 revision is refused
//    with applied=false reason=superseded (and nothing is written);
//  - a pass claiming the CURRENT revision is applied;
//  - a null revision is a hard validation error (the fence cannot be bypassed);
//  - the selected-device check still gates (not_selected);
//  - the legacy 5-arg form still works (fixture compatibility).
// The worker calls the RPC through direct SQL (PostgresClient), so these calls go through psql — the
// same execution path — rather than PostgREST's schema cache, which is built before extra migrations
// are applied here. Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('metric series input-revision fence refuses stale writes and keeps current ones', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const otherDevice = '44444444-4444-4444-8444-444444444444';
  const day = '2026-09-20';
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  for (const file of ['20261001190000_baseline_device_selection.sql',
                      '20261001210000_metric_series.sql',
                      '20261002120000_metric_series_per_metric_buckets.sql',
                      '20261003202000_metric_series_input_revision_fence.sql']) {
    await apply(file);
  }
  const payloadJSON = (ts: number) => JSON.stringify({
    algorithm_version: 'frwhoop-series-1', bucket_seconds: 300,
    window: { start: ts, end: ts + 600 },
    metrics: { steps: [[ts, 10, 1, 0.5, null], [ts + 300, 20, 1, 0.5, null]] },
  });
  const fenced = async (rev: number | null, ts: number): Promise<any> => {
    const revSql = rev === null ? 'NULL' : String(rev);
    const out = await db.sql(`select public.publish_metric_series_v1(
      '${USER_A}'::uuid, '${device}'::uuid, '${day}'::date, 'frwhoop-server-1',
      '${payloadJSON(ts).replaceAll("'", "''")}'::jsonb, ${revSql})::text;`);
    return JSON.parse(out);
  };
  const legacy5 = async (ts: number): Promise<any> => {
    const out = await db.sql(`select public.publish_metric_series_v1(
      '${USER_A}'::uuid, '${device}'::uuid, '${day}'::date, 'frwhoop-server-1',
      '${payloadJSON(ts).replaceAll("'", "''")}'::jsonb)::text;`);
    return JSON.parse(out);
  };
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: otherDevice, p_external_device_id: otherDevice,
    });
    await db.sql(`insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision)
      values ('${USER_A}','${device}','${day}','frwhoop-server-1',5);`);
    await db.sql(`insert into public.scoring_snapshots_v2
      (user_id,device_id,day,algorithm_version,input_revision,computed_at,payload)
      values ('${USER_A}','${device}','${day}','frwhoop-server-1',5,'2026-09-20T00:00:00Z',
        '{"status":"available","coverage":{"hr":{"received":2000}},"daily":{},"sleep":[]}'::jsonb);`);

    await t.step('a stale claimed revision is refused as superseded and writes nothing', async () => {
      const r = await fenced(4, 1_790_000_000);
      assert.equal(r.applied, false);
      assert.equal(r.reason, 'superseded');
      assert.equal(r.claimed_input_revision, 4);
      assert.equal(r.latest_input_revision, 5);
      const rows = await db.sql(`select count(*) from public.server_metric_series where user_id='${USER_A}';`);
      assert.equal(rows.trim(), '0', 'stale write must not touch the series table');
    });

    await t.step('the current claimed revision is applied', async () => {
      const r = await fenced(5, 1_790_000_600);
      assert.equal(r.applied, true);
      assert.equal(r.upserted, 2);
      const rows = await db.sql(`select count(*) from public.server_metric_series where user_id='${USER_A}';`);
      assert.equal(rows.trim(), '2');
    });

    await t.step('a null revision is a hard validation error (fence cannot be bypassed)', async () => {
      const code = await db.sql(`create or replace function pg_temp.try_err(p_sql text) returns text language plpgsql as $$
        begin execute p_sql; return 'no_error';
        exception when others then return sqlstate; end $$;
        select pg_temp.try_err($$select public.publish_metric_series_v1(
          '${USER_A}'::uuid, '${device}'::uuid, '${day}'::date, 'frwhoop-server-1',
          '${payloadJSON(1_791_000_000).replaceAll("'", "''")}'::jsonb, NULL)$$);`);
      assert.equal(code.trim(), '22023', `null revision must raise 22023, got: ${code}`);
    });

    await t.step('a write from a non-selected device is refused as not_selected', async () => {
      await db.sql(`insert into public.scoring_source_preferences_v2(user_id,device_id)
        values ('${USER_A}','${otherDevice}');`);
      const r = await fenced(5, 1_790_001_200);
      assert.equal(r.applied, false);
      assert.equal(r.reason, 'not_selected');
    });

    await t.step('the legacy 5-arg form still applies (fixture compatibility)', async () => {
      await db.sql(`delete from public.scoring_source_preferences_v2 where user_id='${USER_A}';`);
      const r = await legacy5(1_790_001_800);
      assert.equal(r.applied, true);
    });
  } finally {
    await db.close();
  }
});
