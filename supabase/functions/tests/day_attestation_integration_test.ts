import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves publish_day_attestation_v1 (20261003204000_day_attestation.sql):
//  - a first write at revision 5 is applied and stored with identity + not_measured fields;
//  - an OLDER revision (4) is refused as superseded and the row is unchanged;
//  - an equal revision from the SAME device is an idempotent retry (applied);
//  - an equal revision from a DIFFERENT device cannot overwrite (refused);
//  - a strictly newer revision from a different device wins (fenced advance);
//  - the continuity `status` column stays 'open' (no fabricated verdict).
// The worker calls the RPC through direct SQL, so these go through psql.
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('day attestation is versioned and fenced on input revision', async (t) => {
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
  // The harness does not carry the old day_completeness lineage; create the table
  // with its original DDL (minus the ingest_gaps part, which needs its own tables)
  // plus the service-role-write-only hardening, then apply the new migration.
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
  const attest = (rev: number, dev: string, tz = 'America/Los_Angeles') => JSON.stringify({
    identity: { user_id: USER_A, device_id: dev, day, timezone_id: tz, input_revision: rev },
    status: 'available', dataThrough: '2026-09-20T12:00:00Z',
    acquisition: { streams: { hr: { received: 2100 } }, largest_gap_s: 'not_measured' },
    archive: { manifest_refs: 'not_measured' },
    projection: { input_revision: rev, completed: true, snapshot_result_revision: 42 },
  });
  const call = (rev: number, dev: string) => db.sql(`select public.publish_day_attestation_v1(
    '${USER_A}'::uuid, '${dev}'::uuid, '${day}'::date, ${rev},
    'America/Los_Angeles', '${attest(rev, dev).replaceAll("'", "''")}'::jsonb)::text;`);
  const row = () => db.sql(`select input_revision::text||'|'||device_id::text||'|'||status||'|'||
    coalesce(attestation_version,'') from public.day_completeness where user_id='${USER_A}' and day='${day}';`);
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: otherDevice, p_external_device_id: otherDevice,
    });

    await t.step('a first write at the current revision is applied', async () => {
      const r = JSON.parse(await call(5, device));
      assert.equal(r.applied, true);
      assert.equal(r.input_revision, 5);
      const stored = await row();
      assert(stored.startsWith('5|'), `row must carry revision 5, got: ${stored}`);
      assert(stored.includes('|open|nara-day-completeness-v1'), 'continuity status must stay open');
    });

    await t.step('an older revision is refused as superseded and the row is unchanged', async () => {
      const r = JSON.parse(await call(4, device));
      assert.equal(r.applied, false);
      assert.equal(r.reason, 'superseded');
      assert.equal(r.claimed_input_revision, 4);
      const stored = await row();
      assert(stored.startsWith('5|'), `older write must not advance the row, got: ${stored}`);
    });

    await t.step('an equal revision from the same device is an idempotent retry', async () => {
      const r = JSON.parse(await call(5, device));
      assert.equal(r.applied, true);
      const stored = await row();
      assert(stored.startsWith(`5|${device}|`), `retry must keep device, got: ${stored}`);
    });

    await t.step('an equal revision from a different device cannot overwrite', async () => {
      const r = JSON.parse(await call(5, otherDevice));
      assert.equal(r.applied, false);
      const stored = await row();
      assert(stored.includes(`|${device}|`), `different device at same revision must not win, got: ${stored}`);
    });

    await t.step('a strictly newer revision from a different device advances the record', async () => {
      const r = JSON.parse(await call(6, otherDevice));
      assert.equal(r.applied, true);
      const stored = await row();
      assert(stored.startsWith(`6|${otherDevice}|`), `newer revision must win, got: ${stored}`);
    });
  } finally {
    await db.close();
  }
});
