import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// Proves the P2-2 concurrency fix (20261003231000_placement_concurrency_lock.sql): two (or more)
// concurrent same-owner placement declarations must serialize to NON-OVERLAPPING intervals.
//
// The original RPC (20261003210000) had no advisory lock: two concurrent declarations (READ
// COMMITTED, fresh state) could both compute next_start = NULL and leave two overlapping OPEN
// intervals — the single-session SQL test cannot see that. This test runs REAL concurrent psql
// sessions against the throwaway local-PG harness (EDGE_TEST_ARTIFACTS): a burst of same-owner
// declarations at distinct effective times is fired with Promise.all, and the final interval set
// must be exactly the half-open contiguous chain [T1,T2),[T2,T3),…,[Tn,∞) with no overlap —
// invariant under every serialization order once the advisory xact lock serializes the writes.

Deno.test('placement concurrent declarations serialize to non-overlapping intervals', async (t) => {
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

  try {
    await db.sql(`insert into public.devices(id,user_id,source_kind,external_device_id)
      values ('${device}','${USER_A}','whoop','${device}');`);

    await t.step('lock exists on the recreated RPC', async () => {
      const src = await db.sql(
        `select pg_get_functiondef('public.set_placement_interval(uuid,text,timestamptz,uuid,timestamptz,text)'::regprocedure);`);
      assert(src.includes('pg_advisory_xact_lock'), 'RPC body must take the advisory lock');
      assert(src.includes("'placement:'"), 'lock key must be placement-scoped');
      assert(src.includes("coalesce(p_device::text, 'user')"), 'nil-sentinel for user-level scope');
      // Signature + guards unchanged.
      assert(src.includes("cross_user_caller"), 'cross_user_caller guard preserved');
      assert(src.includes('device_owner_mismatch'), 'device ownership guard preserved');
      assert(src.toUpperCase().includes('SECURITY DEFINER'), 'still security definer');
    });

    await t.step('two concurrent same-owner declarations produce non-overlapping intervals', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      const T1 = '2026-10-01T00:00:00Z';
      const T2 = '2026-10-01T01:00:00Z';
      const [a, b] = await Promise.all([
        db.sql(`select public.set_placement_interval('${USER_A}','wrist','${T1}','${device}');`),
        db.sql(`select public.set_placement_interval('${USER_A}','bicep','${T2}','${device}');`),
      ]);
      assert(!a.toUpperCase().includes('ERROR'), `declaration A failed: ${a}`);
      assert(!b.toUpperCase().includes('ERROR'), `declaration B failed: ${b}`);

      const rows = await db.sql(`
        select placement || ':' || effective_start || ':' || coalesce(effective_end::text,'null')
        from public.placement_intervals where owner='${USER_A}' order by effective_start;`);
      const lines = rows.split('\n').map((s) => s.trim()).filter(Boolean);
      assert.equal(lines.length, 2, `expected 2 intervals, got: ${lines.join(' / ')}`);
      // Exactly one open interval (the later declaration), one closed at the other's start.
      const openCount = await db.sql(`
        select count(*) from public.placement_intervals
        where owner='${USER_A}' and effective_end is null;`);
      assert.equal(openCount.trim(), '1', 'exactly one OPEN interval after a serialized pair');
      const overlap = await db.sql(`
        select count(*) from public.placement_intervals a
        join public.placement_intervals b on a.owner=b.owner and a.id<>b.id
        where a.owner='${USER_A}'
          and a.effective_start < coalesce(b.effective_end, 'infinity'::timestamptz)
          and b.effective_start < coalesce(a.effective_end, 'infinity'::timestamptz);`);
      assert.equal(overlap.trim(), '0', 'no overlapping intervals after concurrent declarations');
      const closedAt = await db.sql(`
        select count(*) from public.placement_intervals
        where owner='${USER_A}' and effective_end = '${T2}'::timestamptz;`);
      assert.equal(closedAt.trim(), '1', 'the earlier declaration must be closed at the later one');
    });

    await t.step('concurrent burst of 5 declarations keeps the contiguous non-overlapping chain', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      const starts = [
        '2026-10-01T00:00:00Z', '2026-10-01T00:05:00Z', '2026-10-01T00:10:00Z',
        '2026-10-01T00:15:00Z', '2026-10-01T00:20:00Z',
      ];
      const placements = ['wrist', 'bicep', 'wrist', 'other', 'bicep'];
      const results = await Promise.all(starts.map((s, i) =>
        db.sql(`select public.set_placement_interval('${USER_A}','${placements[i]}','${s}','${device}');`)));
      for (const r of results) {
        assert(!r.toUpperCase().includes('ERROR'), `burst declaration failed: ${r}`);
      }
      const count = await db.sql(
        `select count(*) from public.placement_intervals where owner='${USER_A}';`);
      assert.equal(count.trim(), '5', 'the 5-way burst must fold to exactly 5 rows');
      // Every closed interval ends EXACTLY at the next interval's start: [T1,T2),[T2,T3),…,[T5,∞).
      const badEnds = await db.sql(`
        select count(*) from public.placement_intervals i
        where i.owner='${USER_A}' and i.effective_end is not null
          and i.effective_end <> (select min(i2.effective_start) from public.placement_intervals i2
                                  where i2.owner=i.owner and i2.effective_start > i.effective_start);`);
      assert.equal(badEnds.trim(), '0', 'each closed interval must end exactly at the next interval start');
      const openCount = await db.sql(`
        select count(*) from public.placement_intervals
        where owner='${USER_A}' and effective_end is null;`);
      assert.equal(openCount.trim(), '1', 'exactly one open interval at the chain tail');
      const overlap = await db.sql(`
        select count(*) from public.placement_intervals a
        join public.placement_intervals b on a.owner=b.owner and a.id<>b.id
        where a.owner='${USER_A}'
          and a.effective_start < coalesce(b.effective_end, 'infinity'::timestamptz)
          and b.effective_start < coalesce(a.effective_end, 'infinity'::timestamptz);`);
      assert.equal(overlap.trim(), '0', 'no overlap anywhere after a 5-way concurrent burst');
    });

    await t.step('a held lock blocks a second declaration until the first commits (serialization proof)', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      const T1 = '2026-10-01T00:00:00Z';
      const T2 = '2026-10-01T00:30:00Z';
      // Session A takes the advisory xact lock inside the RPC and HOLDS it for 1 s before
      // committing. Session B's declaration must block on A's lock; B's wall time therefore
      // grows to >= ~1 s. Without the lock, B would return in milliseconds and both would leave
      // overlapping OPEN intervals.
      const started = performance.now();
      const [a, b] = await Promise.all([
        db.sql(`begin; select public.set_placement_interval('${USER_A}','wrist','${T1}','${device}'); select pg_sleep(1); commit;`),
        db.sql(`select public.set_placement_interval('${USER_A}','bicep','${T2}','${device}');`),
      ]);
      const elapsedMS = performance.now() - started;
      assert(!a.toUpperCase().includes('ERROR'), `holder failed: ${a}`);
      assert(!b.toUpperCase().includes('ERROR'), `blocked declaration failed: ${b}`);
      assert(elapsedMS >= 900, `second declaration must block on the held lock (~1 s), got ${Math.round(elapsedMS)} ms`);
      // After both commit, the state is exactly the serialized non-overlapping pair.
      const rows = await db.sql(`
        select count(*) from public.placement_intervals where owner='${USER_A}';`);
      assert.equal(rows.trim(), '2');
      const closedAt = await db.sql(`
        select count(*) from public.placement_intervals
        where owner='${USER_A}' and effective_end = '${T2}'::timestamptz;`);
      assert.equal(closedAt.trim(), '1', 'the first declaration must be closed at the second start');
      const overlap = await db.sql(`
        select count(*) from public.placement_intervals a
        join public.placement_intervals b on a.owner=b.owner and a.id<>b.id
        where a.owner='${USER_A}'
          and a.effective_start < coalesce(b.effective_end, 'infinity'::timestamptz)
          and b.effective_start < coalesce(a.effective_end, 'infinity'::timestamptz);`);
      assert.equal(overlap.trim(), '0');
    });

    await t.step('user-level (NULL device) declarations also serialize on their own lock', async () => {
      await db.sql(`delete from public.placement_intervals where owner='${USER_A}';`);
      const T1 = '2026-10-01T00:00:00Z';
      const T2 = '2026-10-01T00:30:00Z';
      const [a, b] = await Promise.all([
        db.sql(`select public.set_placement_interval('${USER_A}','wrist','${T1}');`),
        db.sql(`select public.set_placement_interval('${USER_A}','other','${T2}');`),
      ]);
      assert(!a.toUpperCase().includes('ERROR'));
      assert(!b.toUpperCase().includes('ERROR'));
      const rows = await db.sql(`
        select count(*) from public.placement_intervals
        where owner='${USER_A}' and device_id is null;`);
      assert.equal(rows.trim(), '2', 'two user-level declarations must fold to two rows');
      const overlap = await db.sql(`
        select count(*) from public.placement_intervals a
        join public.placement_intervals b on a.owner=b.owner and a.id<>b.id
        where a.owner='${USER_A}' and a.device_id is null and b.device_id is null
          and a.effective_start < coalesce(b.effective_end, 'infinity'::timestamptz)
          and b.effective_start < coalesce(a.effective_end, 'infinity'::timestamptz);`);
      assert.equal(overlap.trim(), '0');
    });
  } finally {
    await db.close();
  }
});
