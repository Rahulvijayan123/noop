import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves the F6 fix (20261003231500_placement_same_start_effective_end.sql): a same-start
// declaration (effective_start == an existing interval's start) honors an explicitly supplied
// p_effective_end instead of silently dropping it, capped at the next interval so the half-open
// non-overlap invariant holds; a same-start re-declaration WITHOUT an end keeps the existing end.
// Applies the full placement chain (table + P2-2 lock + F6) and re-pins the sequential semantics.
// Runs against the throwaway local-PG harness (EDGE_TEST_ARTIFACTS), never a shared DB.

Deno.test('placement same-start replacement preserves explicit effective_end', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  await apply('20261003210000_placement_intervals.sql');
  await apply('20261003231000_placement_concurrency_lock.sql');
  await apply('20261003231500_placement_same_start_effective_end.sql');
  await db.sql("notify pgrst, 'reload schema';");
  await new Promise((resolve) => setTimeout(resolve, 700));

  const T1 = '2026-10-01T00:00:00Z';
  const T2 = '2026-10-01T01:00:00Z';
  const T3 = '2026-10-01T02:00:00Z';
  const rowOf = (call: { status: number; body: unknown }) => {
    assert.ok(call.status === 200 || call.status === 201, `RPC should succeed, got ${call.status}`);
    return Array.isArray(call.body) ? (call.body as any[])[0] : call.body as any;
  };
  const rpc = (body: Record<string, unknown>) =>
    db.request('rpc/set_placement_interval', 'authenticated', USER_A, 'POST', body);

  try {
    await db.sql(`insert into public.devices(id,user_id,source_kind,external_device_id)
      values ('${device}','${USER_A}','whoop','${device}');`);

    await t.step('same-start replace with explicit end preserves it', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      // First declaration [T1, null) wrist.
      rowOf(await rpc({ p_owner: USER_A, p_device: device, p_placement: 'wrist', p_effective_start: T1 }));
      // Same-start re-declaration at T1 with an explicit end T2, placement bicep.
      const replaced = rowOf(await rpc({
        p_owner: USER_A, p_device: device, p_placement: 'bicep',
        p_effective_start: T1, p_effective_end: T2,
      }));
      assert.equal(replaced.placement, 'bicep');
      assert.equal(replaced.revision, 2);
      const endOk = await db.sql(
        `select count(*) from public.placement_intervals
         where owner='${USER_A}' and effective_end = '${T2}'::timestamptz;`);
      assert.equal(endOk.trim(), '1', 'explicit p_effective_end must be preserved');
      const count = await db.sql(
        `select count(*) from public.placement_intervals where owner='${USER_A}';`);
      assert.equal(count.trim(), '1', 'same-start replace must not duplicate rows');
    });

    await t.step('same-start explicit end is capped at the next interval', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      // A declaration whose explicit end lands BEFORE the next interval keeps that end.
      rowOf(await rpc({ p_owner: USER_A, p_device: device, p_placement: 'other', p_effective_start: T3 }));
      const before = rowOf(await rpc({
        p_owner: USER_A, p_device: device, p_placement: 'wrist',
        p_effective_start: T1, p_effective_end: T2,
      }));
      const beforeEnd = await db.sql(
        `select count(*) from public.placement_intervals
         where owner='${USER_A}' and effective_end = '${T2}'::timestamptz;`);
      assert.equal(beforeEnd.trim(), '1', 'an end before the next interval is kept');

      // A declaration whose explicit end lands AFTER the next interval is capped at it, so the
      // half-open non-overlap invariant holds.
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      rowOf(await rpc({ p_owner: USER_A, p_device: device, p_placement: 'other', p_effective_start: T3 }));
      const late = rowOf(await rpc({
        p_owner: USER_A, p_device: device, p_placement: 'wrist',
        p_effective_start: T1, p_effective_end: '2026-10-01T03:00:00Z',
      }));
      const cappedAt = await db.sql(
        `select count(*) from public.placement_intervals
         where owner='${USER_A}' and effective_end = '${T3}'::timestamptz;`);
      assert.equal(cappedAt.trim(), '1', 'explicit end past the next interval must be capped at it');
      const overlap = await db.sql(`
        select count(*) from public.placement_intervals a
        join public.placement_intervals b on a.owner=b.owner and a.id<>b.id
        where a.owner='${USER_A}'
          and a.effective_start < coalesce(b.effective_end, 'infinity'::timestamptz)
          and b.effective_start < coalesce(a.effective_end, 'infinity'::timestamptz);`);
      assert.equal(overlap.trim(), '0', 'capped end must never overlap the next interval');
    });

    await t.step('same-start replace without an end keeps the existing end', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      // [T1, T2) wrist (explicit closed interval).
      rowOf(await rpc({ p_owner: USER_A, p_device: device, p_placement: 'wrist',
                        p_effective_start: T1, p_effective_end: T2 }));
      // Same-start re-declaration with no end: end T2 must be kept (not widened to null, not shrunk).
      const replaced = rowOf(await rpc({ p_owner: USER_A, p_device: device,
                                         p_placement: 'bicep', p_effective_start: T1 }));
      assert.equal(replaced.placement, 'bicep');
      const kept = await db.sql(
        `select count(*) from public.placement_intervals
         where owner='${USER_A}' and effective_end = '${T2}'::timestamptz;`);
      assert.equal(kept.trim(), '1', 'existing end must be preserved when no end is supplied');
    });

    await t.step('sequential semantics + non-overlap still hold with all three migrations', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      rowOf(await rpc({ p_owner: USER_A, p_device: device, p_placement: 'wrist', p_effective_start: T1 }));
      const corrected = rowOf(await rpc({ p_owner: USER_A, p_device: device, p_placement: 'bicep', p_effective_start: T2 }));
      assert.equal(corrected.revision, 2);
      const rows = await db.sql(
        `select count(*) from public.placement_intervals where owner='${USER_A}';`);
      assert.equal(rows.trim(), '2');
      const closedAt = await db.sql(
        `select count(*) from public.placement_intervals where owner='${USER_A}' and effective_end = '${T2}'::timestamptz;`);
      assert.equal(closedAt.trim(), '1');
    });
  } finally {
    await db.close();
  }
});
