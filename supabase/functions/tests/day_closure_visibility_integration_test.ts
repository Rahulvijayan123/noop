import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';

// P2s (audit-g2-durability, closure visibility) fixed by 20261003230200:
//  - an INVALID profile timezone (and a MISSING profiles row) is no longer silently
//    dropped: the sweep writes a bounded day_closure_skips ledger row and the device
//    gets no closure work;
//  - a DEAD-LETTERED v2 day is marked closure_state='closed' with closure_reason=
//    'dead_lettered' (fresh or previously-pending), so it is not stuck invisible;
//  - an active owner with a valid zone is unaffected.
// Profiles are per-user, so the valid/invalid/missing cases use three users.
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('closure surfaces invalid/missing zones and settles dead-lettered days', async (t) => {
  const db = await startLocalPostgres();
  const USER_C = '66666666-6666-4666-8666-666666666666';
  const devValid = '33333333-3333-4333-8333-333333333333';
  const devInvalid = '44444444-4444-4444-8444-444444444444';
  const devNoProfile = '55555555-5555-4555-8555-555555555555';
  const zone = 'Pacific/Kiritimati'; // UTC+14, no DST — deterministic local date
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  await db.sql(`create table if not exists public.noop_account_retirements (
    user_id uuid primary key, requested_at timestamptz not null default clock_timestamp());
    alter table public.noop_account_retirements enable row level security;
    revoke all on table public.noop_account_retirements from anon, authenticated;
    grant all on table public.noop_account_retirements to service_role;`);
  await db.sql(`create table if not exists public.day_completeness (
    user_id uuid not null references auth.users(id) on delete cascade,
    day date not null,
    timezone_name text not null default 'UTC',
    status text not null default 'open' check (status in ('open','complete','degraded')),
    result jsonb not null default '{}'::jsonb,
    finalized_at timestamptz,
    updated_at timestamptz not null default now(),
    primary key (user_id, day)
  );
  alter table public.day_completeness enable row level security;
  revoke all on table public.day_completeness from public, anon;
  grant select on table public.day_completeness to authenticated;
  grant all on table public.day_completeness to service_role;`);
  await apply('20260918020000_physiology_publication.sql');  // physiology_archive_outbox
  for (const file of ['20261003204000_day_attestation.sql',
                      '20261003205000_day_closure_scheduling.sql',
                      '20261003230100_repair_attest_fence_scope_and_retirement.sql',
                      '20261003230200_repair_attest_round2.sql']) {
    await apply(file);
  }
  const yesterday = (await db.sql(`select ((clock_timestamp() at time zone '${zone}')::date - 1)::text;`)).trim();
  const skips = () => db.sql(`select device_id::text||'|'||reason from public.day_closure_skips order by device_id;`);
  const closureOf = () => db.sql(`select coalesce(closure_state,'null')||'|'||coalesce(closure_reason,'')
    from public.day_completeness where user_id='${USER_A}' and day='${yesterday}';`);
  try {
    await db.sql(`insert into auth.users(id) values ('${USER_C}');`);
    await db.rest.rpc('noop_register_push_device', { p_user_id: USER_A, p_device_id: devValid, p_external_device_id: devValid });
    await db.rest.rpc('noop_register_push_device', { p_user_id: USER_B, p_device_id: devInvalid, p_external_device_id: devInvalid });
    await db.rest.rpc('noop_register_push_device', { p_user_id: USER_C, p_device_id: devNoProfile, p_external_device_id: devNoProfile });
    // The harness auto-creates a default profile; drop it to simulate a MISSING profile row.
    await db.sql(`delete from public.profiles where id='${USER_C}';`);
    await db.sql(`insert into public.profiles(id, timezone) values ('${USER_A}', '${zone}')
      on conflict (id) do update set timezone = excluded.timezone;`);
    await db.sql(`insert into public.profiles(id, timezone) values ('${USER_B}', 'Not/AZone')
      on conflict (id) do update set timezone = excluded.timezone;`);
    // USER_C has NO profile row (missing).
    await db.sql(`insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision)
      values ('${USER_A}','${devValid}','${yesterday}','frwhoop-server-1',1,0);`);

    await t.step('invalid-zone and missing-profile devices are surfaced in the skip ledger', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '1', 'only the valid-zone pending day is enqueued');
      const s = await skips();
      assert(s.includes(`${devInvalid}|invalid_zone`), `invalid zone must be surfaced, got: ${s}`);
      assert(s.includes(`${devNoProfile}|missing_profile`), `missing profile must be surfaced, got: ${s}`);
      assert(!s.includes(devValid), 'valid-zone device must not be in the skip ledger');
      // The valid owner was enqueued (pending_reconciliation).
      assert((await closureOf()).startsWith('pending_reconciliation|'));
    });

    await t.step('a dead-lettered v2 day is marked closed with reason dead_lettered', async () => {
      await db.sql(`update public.scoring_jobs_v2 set dead_letter=true where user_id='${USER_A}'
        and device_id='${devValid}' and day='${yesterday}' and algorithm_version='frwhoop-server-1';`);
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '1', 'dead-lettered day must be processed (closed)');
      const c = await closureOf();
      assert(c.startsWith('closed|dead_lettered'), `must be closed with reason, got: ${c}`);
    });

    await t.step('a later sweep stays quiet (everything is settled)', async () => {
      const n = (await db.sql(`select public.scoring_enqueue_due_day_closure(16, 'frwhoop-server-1', 0)::text;`)).trim();
      assert.equal(n, '0');
    });
  } finally {
    await db.close();
  }
});
