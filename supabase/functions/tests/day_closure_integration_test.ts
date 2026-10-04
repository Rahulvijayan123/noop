import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves the zone-aware midnight closure (20261003205000_day_closure_scheduling.sql):
//  - a pending v2 day whose LOCAL yesterday (in the user's profiles.timezone) has passed its
//    midnight + settle window is enqueued exactly once and marked pending_reconciliation;
//  - a second sweep is a no-op (idempotent);
//  - a successful snapshot publish (publish_day_attestation_v1) advances closure to 'closed';
//  - a day that is NOT local-yesterday (today's job) is never touched by the sweep.
// Boundary math is authoritative in Postgres (`AT TIME ZONE`); the test asks Postgres for the
// exact local-yesterday value instead of re-implementing zone math in JS.
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('midnight closure enqueues due days per user zone and marks the attestation', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const otherDevice = '44444444-4444-4444-8444-444444444444';
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
  create index if not exists day_completeness_updated_idx
    on public.day_completeness (user_id, updated_at desc);
  drop trigger if exists day_completeness_updated on public.day_completeness;
  create trigger day_completeness_updated
    before update on public.day_completeness
    for each row execute function public.set_updated_at();
  alter table public.day_completeness enable row level security;
  revoke all on table public.day_completeness from public, anon;
  grant select on table public.day_completeness to authenticated;
  grant all on table public.day_completeness to service_role;
  drop policy if exists day_completeness_select_own on public.day_completeness;
  create policy day_completeness_select_own on public.day_completeness
    for select to authenticated using (user_id = (select auth.uid()));`);
  await apply('20261003204000_day_attestation.sql');
  await apply('20261003205000_day_closure_scheduling.sql');

  const zone = 'Pacific/Kiritimati'; // UTC+14, no DST — deterministic local date
  const yesterday = (await db.sql(`select ((clock_timestamp() at time zone '${zone}')::date - 1)::text;`)).trim();
  const today = (await db.sql(`select (clock_timestamp() at time zone '${zone}')::date::text;`)).trim();
  const closureOf = (day: string) => db.sql(`select coalesce(closure_state,'null') from public.day_completeness
    where user_id='${USER_A}' and day='${day}';`);
  const revision = (day: string, dev: string = device) => db.sql(`select input_revision::text from public.scoring_jobs_v2
    where user_id='${USER_A}' and device_id='${dev}' and day='${day}' and algorithm_version='frwhoop-server-1';`);
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: otherDevice, p_external_device_id: otherDevice,
    });
    await db.sql(`insert into public.profiles(id, timezone) values ('${USER_A}', '${zone}')
      on conflict (id) do update set timezone = excluded.timezone;`);

    // A pending v2 job for local-YESTERDAY on the first device; a fresh job for local-TODAY on the second.
    await db.sql(`insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision)
      values ('${USER_A}','${device}','${yesterday}','frwhoop-server-1',1,0);`);
    await db.sql(`insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision)
      values ('${USER_A}','${otherDevice}','${today}','frwhoop-server-1',1,0);`);

    await t.step('the sweep enqueues the due local-yesterday day exactly once and marks it pending', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '1', 'exactly one due day must be enqueued');
      assert.equal((await revision(yesterday)).trim(), '2', 'the enqueue must bump input_revision');
      assert.equal((await closureOf(yesterday)).trim(), 'pending_reconciliation');
      // The local-TODAY job must be untouched.
      assert.equal((await revision(today, otherDevice)).trim(), '1');
    });

    await t.step('a second sweep is a no-op (idempotent)', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '0');
      assert.equal((await revision(yesterday)).trim(), '2', 'revision must not bump again');
    });

    await t.step('a successful publish advances closure pending -> closed', async () => {
      const attest = JSON.stringify({ status: 'no_data', identity: { user_id: USER_A, device_id: device, day: yesterday } });
      const r = JSON.parse(await db.sql(`select public.publish_day_attestation_v1(
        '${USER_A}'::uuid, '${device}'::uuid, '${yesterday}'::date, 2,
        '${zone}', '${attest.replaceAll("'", "''")}'::jsonb)::text;`));
      assert.equal(r.applied, true);
      assert.equal((await closureOf(yesterday)).trim(), 'closed');
    });

    await t.step('the sweep stays quiet for an already-closed day', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '0');
    });

    await t.step('the sweep ignores a day that has no pending v2 job', async () => {
      // A device with no scoring_jobs_v2 row for yesterday must not be enqueued.
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '0');
    });
  } finally {
    await db.close();
  }
});
