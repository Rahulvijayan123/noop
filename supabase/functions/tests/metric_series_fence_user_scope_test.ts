import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// P2-1 regression (audit-g5g6-isolation): the metric-series input-revision fence
// must be USER/DAY-scoped, not per-device, because server_metric_series writes are
// device-agnostic (keyed (user, metric, bucket_start)). Scenario A->B->A mid-day:
//   - deviceA's job row holds revision 3, deviceB's holds revision 5;
//   - the OLD fence (max per p_device) let a stale deviceA pass claiming 3 pass
//     (3 >= 3) and overwrite deviceB newer series;
//   - the NEW fence uses max(input_revision) across ALL of the day's devices
//     (5), so the stale deviceA pass is rejected as superseded;
//   - the newest pass via ANY device applies (deviceB at 5).
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('metric series fence is user/day-scoped across devices (A->B->A stale pass rejected)', async (t) => {
  const db = await startLocalPostgres();
  const deviceA = '33333333-3333-4333-8333-333333333333';
  const deviceB = '44444444-4444-4444-8444-444444444444';
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
                      '20261003202000_metric_series_input_revision_fence.sql',
                      '20261003230100_repair_attest_fence_scope_and_retirement.sql']) {
    await apply(file);
  }
  const payloadJSON = (ts: number) => JSON.stringify({
    algorithm_version: 'frwhoop-series-1', bucket_seconds: 300,
    window: { start: ts, end: ts + 600 },
    metrics: { steps: [[ts, 10, 1, 0.5, null]] },
  });
  const fenced = async (rev: number, dev: string, ts: number): Promise<any> => {
    const out = await db.sql(`select public.publish_metric_series_v1(
      '${USER_A}'::uuid, '${dev}'::uuid, '${day}'::date, 'frwhoop-server-1',
      '${payloadJSON(ts).replaceAll("'", "''")}'::jsonb, ${rev})::text;`);
    return JSON.parse(out);
  };
  const seriesRows = () => db.sql(`select count(*) from public.server_metric_series where user_id='${USER_A}';`);
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: deviceA, p_external_device_id: deviceA,
    });
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: deviceB, p_external_device_id: deviceB,
    });
    // deviceA job at revision 3, deviceB job at revision 5 (B is the newer writer).
    await db.sql(`insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision)
      values ('${USER_A}','${deviceA}','${day}','frwhoop-server-1',3),
             ('${USER_A}','${deviceB}','${day}','frwhoop-server-1',5);`);
    // Force deviceA selected (A->B->A scenario: A is selected again when its stale
    // pass runs, so the not_selected gate does NOT mask the fence).
    await db.sql(`insert into public.scoring_source_preferences_v2(user_id,device_id)
      values ('${USER_A}','${deviceA}');`);
    await db.sql(`insert into public.scoring_snapshots_v2
      (user_id,device_id,day,algorithm_version,input_revision,computed_at,payload)
      values ('${USER_A}','${deviceA}','${day}','frwhoop-server-1',3,'2026-09-20T00:00:00Z',
        '{"status":"available","coverage":{"hr":{"received":2000}},"daily":{},"sleep":[]}'::jsonb);`);

    await t.step('a stale deviceA pass claiming 3 is rejected because user/day max is 5 (via deviceB)', async () => {
      const r = await fenced(3, deviceA, 1_790_000_000);
      assert.equal(r.applied, false, 'stale A pass must be refused');
      assert.equal(r.reason, 'superseded');
      assert.equal(r.latest_input_revision, 5, 'the fence must see the newer revision via deviceB');
      assert.equal((await seriesRows()).trim(), '0', 'stale pass must write nothing');
    });

    await t.step('the newest pass via ANY device applies (deviceB at 5)', async () => {
      await db.sql(`delete from public.scoring_source_preferences_v2 where user_id='${USER_A}';
        insert into public.scoring_source_preferences_v2(user_id,device_id) values ('${USER_A}','${deviceB}');`);
      const r = await fenced(5, deviceB, 1_790_000_600);
      assert.equal(r.applied, true);
      assert.equal(r.upserted, 1);
      assert.equal((await seriesRows()).trim(), '1');
    });

    await t.step('a stale deviceA pass is still rejected after deviceB newer series is applied', async () => {
      // A->B->A: A is selected again, its job still at 3, but the day is at 5.
      await db.sql(`delete from public.scoring_source_preferences_v2 where user_id='${USER_A}';
        insert into public.scoring_source_preferences_v2(user_id,device_id) values ('${USER_A}','${deviceA}');`);
      const r = await fenced(3, deviceA, 1_790_001_200);
      assert.equal(r.applied, false);
      assert.equal(r.reason, 'superseded');
      assert.equal(r.latest_input_revision, 5);
      assert.equal((await seriesRows()).trim(), '1', 'the applied deviceB series must survive');
    });

    await t.step('the not_selected device gate is unchanged (non-selected device refused)', async () => {
      // deviceB is now non-selected; its stale write must be refused by the gate.
      const r = await fenced(5, deviceB, 1_790_001_800);
      assert.equal(r.applied, false);
      assert.equal(r.reason, 'not_selected');
    });
  } finally {
    await db.close();
  }
});
