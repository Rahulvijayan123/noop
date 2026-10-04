import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// P2-3 regression (audit-g5g6-isolation): during the account-deletion freeze window
// the closure sweep must NOT enqueue day-closure work for a frozen owner. A
// noop_account_retirements tombstone (the same one begin_noop_account_deletion
// inserts, 20260921113000) excludes the owner from the sweep; an active owner is
// unaffected. Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('midnight closure skips frozen owners and leaves active owners unaffected', async (t) => {
  const db = await startLocalPostgres();
  const devA = '33333333-3333-4333-8333-333333333333';
  const devB = '44444444-4444-4444-8444-444444444444';
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  await db.sql(`create table if not exists public.day_completeness (
    user_id uuid not null references auth.users(id) on delete cascade,
    day date not null,
    timezone_name text not null default 'UTC',
    status text not null default 'open'
      constraint day_completeness_status_check check (status in ('open','complete','degraded')),
    result jsonb not null default '{}'::jsonb,
    finalized_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (user_id, day)
  );
  alter table public.day_completeness enable row level security;
  revoke all on table public.day_completeness from public, anon;
  grant select on table public.day_completeness to authenticated;
  grant all on table public.day_completeness to service_role;`);
  // The harness does not carry 20260921113000; create the retirement tombstone the
  // same way begin_noop_account_deletion does.
  await db.sql(`create table if not exists public.noop_account_retirements (
    user_id uuid primary key, requested_at timestamptz not null default clock_timestamp());
    alter table public.noop_account_retirements enable row level security;
    revoke all on table public.noop_account_retirements from anon, authenticated;
    grant all on table public.noop_account_retirements to service_role;`);
  await apply('20261003204000_day_attestation.sql');
  await apply('20261003205000_day_closure_scheduling.sql');
  await apply('20261003230100_repair_attest_fence_scope_and_retirement.sql');

  const zone = 'Pacific/Kiritimati'; // UTC+14, no DST — deterministic local date
  const yesterday = (await db.sql(`select ((clock_timestamp() at time zone '${zone}')::date - 1)::text;`)).trim();
  const revision = (uid: string, dev: string) => db.sql(`select input_revision::text from public.scoring_jobs_v2
    where user_id='${uid}' and device_id='${dev}' and day='${yesterday}' and algorithm_version='frwhoop-server-1';`);
  try {
    for (const [uid, dev] of [[USER_A, devA], [USER_B, devB]] as const) {
      await db.rest.rpc('noop_register_push_device', {
        p_user_id: uid, p_device_id: dev, p_external_device_id: dev,
      });
      await db.sql(`insert into public.profiles(id, timezone) values ('${uid}', '${zone}')
        on conflict (id) do update set timezone = excluded.timezone;`);
      await db.sql(`insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision)
        values ('${uid}','${dev}','${yesterday}','frwhoop-server-1',1,0);`);
    }
    // Freeze USER_A (as begin_noop_account_deletion would).
    await db.sql(`insert into public.noop_account_retirements(user_id) values ('${USER_A}');`);

    await t.step('a frozen owner gets no closure enqueue', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '1', 'only the active owner may be enqueued');
      assert.equal((await revision(USER_A, devA)).trim(), '1', 'frozen owner revision must NOT bump');
      assert.equal((await revision(USER_B, devB)).trim(), '2', 'active owner must be enqueued (revision bumped)');
    });

    await t.step('the frozen owner stays un-enqueued on the next sweep too', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '0', 'nothing left to enqueue');
      assert.equal((await revision(USER_A, devA)).trim(), '1');
    });

    await t.step('an active owner with no pending job is still ignored', async () => {
      // USER_B's day is now closure-marked pending; nothing further to do.
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '0');
    });
  } finally {
    await db.close();
  }
});
