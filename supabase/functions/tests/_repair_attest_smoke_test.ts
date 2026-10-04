import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

Deno.test('all repair-attest migrations apply in order on a fresh harness DB', async () => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-3000)}`);
  };
  try {
    // The retirement tombstone the P2-3 closure sweep reads (created in prod by
    // 20260921113000, which the harness does not carry).
    await db.sql(`create table if not exists public.noop_account_retirements (
      user_id uuid primary key, requested_at timestamptz not null default clock_timestamp());
      alter table public.noop_account_retirements enable row level security;
      revoke all on table public.noop_account_retirements from anon, authenticated;
      grant all on table public.noop_account_retirements to service_role;`);
    // Create the dormant day_completeness lineage first (not in the harness set).
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
    await apply('20260918020000_physiology_publication.sql');  // creates physiology_archive_outbox
    await apply('20261001190000_baseline_device_selection.sql');
    await apply('20261001210000_metric_series.sql');           // creates the 5-arg series RPC
    await apply('20261002120000_metric_series_per_metric_buckets.sql');
    for (const file of ['20261003201000_outbox_retry_status.sql',
                        '20261003202000_metric_series_input_revision_fence.sql',
                        '20261003203000_projection_debt_dead_letter.sql',
                        '20261003204000_day_attestation.sql',
                        '20261003205000_day_closure_scheduling.sql',
                        '20261003205900_verification_quarantine.sql',
                        '20261003230100_repair_attest_fence_scope_and_retirement.sql',
                        '20261003230200_repair_attest_round2.sql']) {
      await apply(file);
    }
    // Spot-check every migration's artifact exists.
    const statusCheck = await db.sql(`select pg_get_constraintdef(oid) from pg_constraint
      where conname='physiology_archive_outbox_status_check';`);
    assert(statusCheck.includes("'retry'"));
    const fenced = await db.sql(`select count(*) from pg_proc where proname='publish_metric_series_v1';`);
    assert.equal(fenced.trim(), '2', '5-arg + 6-arg publish_metric_series_v1 must both exist');
    const dl = await db.sql(`select column_name from information_schema.columns
      where table_name='noop_projection_debt' and column_name='dead_letter';`);
    assert.equal(dl.trim(), 'dead_letter');
    const att = await db.sql(`select column_name from information_schema.columns
      where table_name='day_completeness' and column_name='attestation_version';`);
    assert.equal(att.trim(), 'attestation_version');
    const cl = await db.sql(`select column_name from information_schema.columns
      where table_name='day_completeness' and column_name='closure_state';`);
    assert.equal(cl.trim(), 'closure_state');
    const q = await db.sql(`select column_name from information_schema.columns
      where table_name='object_manifests' and column_name='verification_failure_code';`);
    assert.equal(q.trim(), 'verification_failure_code');
    // P2-3: the re-created closure sweep must reference the retirement tombstone.
    const closureDef = await db.sql(`select prosrc from pg_proc
      where proname='scoring_enqueue_due_day_closure';`);
    assert(closureDef.includes('noop_account_retirements'), 'closure sweep must check retirements');
    // P2-1: the re-created series fence must be user/day-scoped (no device_id filter).
    const fenceBody = await db.sql(`select prosrc from pg_proc
      where proname='publish_metric_series_v1' and pg_get_function_identity_arguments(oid) like '%bigint%';`);
    assert(fenceBody.includes('where user_id = p_user and day = p_day'),
           'series fence must be user/day-scoped');
    // Round 2 artifacts.
    const outboxDL = await db.sql(`select column_name from information_schema.columns
      where table_name='physiology_archive_outbox' and column_name='dead_letter';`);
    assert.equal(outboxDL.trim(), 'dead_letter');
    const skips = await db.sql(`select to_regclass('public.day_closure_skips')::text;`);
    assert.equal(skips.trim(), 'day_closure_skips');
    const closureReason = await db.sql(`select column_name from information_schema.columns
      where table_name='day_completeness' and column_name='closure_reason';`);
    assert.equal(closureReason.trim(), 'closure_reason');
    const unq = await db.sql(`select count(*) from pg_proc where proname='noop_unquarantine_manifest_verification';`);
    assert.equal(unq.trim(), '1');
  } finally {
    await db.close();
  }
});
