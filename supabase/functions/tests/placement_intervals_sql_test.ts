import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// Proves the G4 manual placement baseline (20261003210000_placement_intervals.sql):
//  1. the table exists with the effective-dated contract (half-open, open-ended nullable end,
//     source/revision, owner + optional device, no overlap, no backfill rule documented);
//  2. RLS: an owner reads only their own rows; service role writes; the write path is the
//     set_placement_interval RPC;
//  3. set_placement_interval: cross_user_caller guard, device ownership validation, corrections
//     close the overlapping interval and bump revision, same-start replacement, future-dated cap,
//     invalid placement/source/effective-range rejections.
// Runs against the throwaway local-PG harness (EDGE_TEST_ARTIFACTS), never a shared DB.

Deno.test('placement intervals: schema, RLS, correction semantics', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const deviceB = '44444444-4444-4444-8444-444444444444';
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  // PostgREST caches the schema at startup; the migration was applied after it started, so ask it
  // to reload before exercising the table/RPC through PostgREST.
  await apply('20261003210000_placement_intervals.sql');
  await db.sql("notify pgrst, 'reload schema';");
  await new Promise((resolve) => setTimeout(resolve, 700));

  // PostgREST returns composite-typed RPC results as an array of rows; normalize defensively.
  const rowOf = (call: { status: number; body: unknown }) => {
    assert.ok(call.status === 200 || call.status === 201, `RPC should succeed, got ${call.status}`);
    return Array.isArray(call.body) ? (call.body as any[])[0] : call.body as any;
  };
  const T1 = '2026-10-01T00:00:00Z';
  const T2 = '2026-10-01T01:00:00Z';
  const rows = () => db.sql(
    `select placement from public.placement_intervals where owner='${USER_A}' order by effective_start;`);
  const countRows = () => db.sql(
    `select count(*) from public.placement_intervals where owner='${USER_A}';`);
  const setRpc = (placement: string, start: string, pDevice: string | null = device) =>
    db.request('rpc/set_placement_interval', 'authenticated', USER_A, 'POST', {
      p_owner: USER_A, p_device: pDevice, p_placement: placement, p_effective_start: start,
    });

  try {
    await db.sql(`insert into public.devices(id,user_id,source_kind,external_device_id)
      values ('${device}','${USER_A}','whoop','${device}'),('${deviceB}','${USER_B}','whoop','${deviceB}');`);

    await t.step('schema: effective-dated half-open contract', async () => {
      const cols = await db.sql(`
        select column_name || ':' || data_type || ':' || is_nullable
        from information_schema.columns where table_schema='public' and table_name='placement_intervals'
        order by ordinal_position;`);
      assert(cols.includes('owner:uuid:NO'));
      assert(cols.includes('device_id:uuid:YES'), 'device_id must be nullable (user-level declaration)');
      assert(cols.includes('placement:text:NO'));
      assert(cols.includes('effective_start:timestamp with time zone:NO'));
      assert(cols.includes('effective_end:timestamp with time zone:YES'), 'open interval = NULL end');
      assert(cols.includes('source:text:NO'));
      assert(cols.includes('revision:bigint:NO'));
      const constraint = await db.sql(`
        select pg_get_constraintdef(oid) from pg_constraint
         where conrelid='public.placement_intervals'::regclass and contype='c';`);
      for (const value of ["'wrist'", "'bicep'", "'other'", "'unknown'", "'user'", "'device'"]) {
        assert(constraint.includes(value), `placement/source CHECK must admit ${value}, got: ${constraint}`);
      }
      assert(constraint.includes('effective_end'), 'half-open end must be CHECKed');
      assert(constraint.includes('effective_start'), 'start must be CHECKed');
      const comment = await db.sql(`select obj_description('public.placement_intervals'::regclass,'pg_class');`);
      assert(comment.toLowerCase().includes('half-open'), 'half-open semantics must be documented');
      assert(comment.toLowerCase().includes('unknown'), 'no-backfill/UNKNOWN rule must be documented');
    });

    await t.step('RLS: owner reads only own rows, service role writes', async () => {
      await db.sql(`insert into public.placement_intervals
        (owner,device_id,placement,effective_start,effective_end,recorded_at,source,revision)
        values ('${USER_A}',null,'wrist','${T1}',null,now(),'user',1),
               ('${USER_B}',null,'bicep','${T1}',null,now(),'user',1);`);
      const own = await db.request('placement_intervals?owner=eq.' + USER_A, 'authenticated', USER_A);
      assert.equal(own.status, 200);
      assert.equal(own.body.length, 1, 'owner must see only their own rows');
      assert.equal(own.body[0].placement, 'wrist');
      const other = await db.request('placement_intervals?owner=eq.' + USER_B, 'authenticated', USER_A);
      assert.equal(other.status, 200);
      assert.equal(other.body.length, 0, 'a different owner must not see USER_B rows');
      await db.sql('delete from public.placement_intervals;');
    });

    await t.step('set_placement_interval: cross_user_caller guard', async () => {
      const call = await db.request('rpc/set_placement_interval', 'authenticated', USER_A, 'POST', {
        p_owner: USER_B, p_placement: 'wrist', p_effective_start: T1,
      });
      assert.equal(call.status, 403);
      assert.match(JSON.stringify(call.body), /cross_user_caller/);
    });

    await t.step('set_placement_interval: device ownership is validated', async () => {
      const call = await db.request('rpc/set_placement_interval', 'authenticated', USER_A, 'POST', {
        p_owner: USER_A, p_placement: 'wrist', p_effective_start: T1, p_device: deviceB,
      });
      assert.equal(call.status, 403);
      assert.match(JSON.stringify(call.body), /device_owner_mismatch/);
    });

    await t.step('set_placement_interval: invalid placement and effective range are rejected', async () => {
      const badPlacement = await db.request('rpc/set_placement_interval', 'authenticated', USER_A, 'POST', {
        p_owner: USER_A, p_placement: 'ankle', p_effective_start: T1,
      });
      assert.equal(badPlacement.status, 400);
      assert.match(JSON.stringify(badPlacement.body), /invalid_placement/);
      const badRange = await db.request('rpc/set_placement_interval', 'authenticated', USER_A, 'POST', {
        p_owner: USER_A, p_placement: 'wrist', p_effective_start: T2, p_effective_end: T1,
      });
      assert.equal(badRange.status, 400);
      assert.match(JSON.stringify(badRange.body), /invalid_effective_end/);
    });

    await t.step('first declaration is open-ended; unannotated history is absent', async () => {
      const row = rowOf(await setRpc('wrist', T1));
      assert.equal(row.placement, 'wrist');
      assert.equal(row.effective_end, null, 'a fresh declaration is open-ended');
      assert.equal(row.revision, 1);
      assert.equal((await countRows()).trim(), '1');
      const open = await db.sql(
        `select count(*) from public.placement_intervals
         where owner='${USER_A}' and effective_end is null;`);
      assert.equal(open.trim(), '1', 'the first declaration is the only open interval');
    });

    await t.step('correction closes the overlapping interval and bumps revision', async () => {
      const row = rowOf(await setRpc('bicep', T2));
      assert.equal(row.revision, 2);
      assert.equal((await countRows()).trim(), '2');
      // The wrist interval [T1, T2) is closed exactly at T2 (half-open).
      const closed = await db.sql(
        `select (effective_end = '${T2}'::timestamptz) from public.placement_intervals
         where owner='${USER_A}' and placement='wrist';`);
      assert.equal(closed.trim(), 't', 'the overlapping interval must be closed at T2');
      // The bicep interval is open with revision 2.
      const bicep = await db.sql(
        `select (effective_end is null) from public.placement_intervals
         where owner='${USER_A}' and placement='bicep';`);
      assert.equal(bicep.trim(), 't');
      const rev = await db.sql(`select max(revision) from public.placement_intervals where owner='${USER_A}';`);
      assert.equal(rev.trim(), '2');
      // No overlap: exactly one interval covers T2 (half-open boundary).
      const covering = await db.sql(
        `select count(*) from public.placement_intervals
         where owner='${USER_A}' and effective_start <= '${T2}'::timestamptz
           and (effective_end is null or effective_end > '${T2}'::timestamptz);`);
      assert.equal(covering.trim(), '1', 'half-open [start, end) must never double-cover a time');
    });

    await t.step('same-start declaration replaces in place without duplicating', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      await setRpc('wrist', T1);
      const replaced = rowOf(await setRpc('other', T1));
      assert.equal(replaced.placement, 'other');
      assert.equal(replaced.revision, 2);
      assert.equal((await countRows()).trim(), '1', 'same-start declaration must not duplicate rows');
    });

    await t.step('future-dated interval is capped, never overwritten', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      await setRpc('bicep', T2);
      const now = rowOf(await setRpc('wrist', T1));
      assert.equal(now.revision, 2);
      assert.equal((await countRows()).trim(), '2');
      // The new wrist interval is capped at the future bicep interval.
      const capped = await db.sql(
        `select (effective_end = '${T2}'::timestamptz) from public.placement_intervals
         where owner='${USER_A}' and placement='wrist';`);
      assert.equal(capped.trim(), 't', 'new interval must be capped at the next interval start');
      // The future-dated bicep interval is untouched and open.
      const bicep = await db.sql(
        `select (effective_end is null and placement='bicep') from public.placement_intervals
         where owner='${USER_A}' and effective_start = '${T2}'::timestamptz;`);
      assert.equal(bicep.trim(), 't', 'future-dated interval is never overwritten');
      // No overlap anywhere.
      const overlap = await db.sql(`
        select count(*) from public.placement_intervals a
        join public.placement_intervals b on a.owner = b.owner and a.id <> b.id
        where a.owner='${USER_A}'
          and a.effective_start < coalesce(b.effective_end, 'infinity'::timestamptz)
          and b.effective_start < coalesce(a.effective_end, 'infinity'::timestamptz);`);
      assert.equal(overlap.trim(), '0', 'intervals must never overlap');
    });
  } finally {
    await db.close();
  }
});
