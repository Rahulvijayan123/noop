import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// P2 (audit-g2-durability, verification): noop_unquarantine_manifest_verification
// (20261003230200) gives operators a path to clear a stranded quarantine (e.g.
// `commit rejected` classified deterministic during a transient deployment
// misconfig). Proves:
//  - quarantine then un-quarantine clears code/failed_at/attempts;
//  - the candidate predicate re-selects the object after un-quarantine;
//  - un-quarantine of a missing object raises (object_not_found).
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('verification quarantine can be operator-cleared and the object re-selected', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const oid = crypto.randomUUID();
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  await apply('20260918020000_physiology_publication.sql');  // physiology_archive_outbox
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
  for (const file of ['20261003205900_verification_quarantine.sql',
                      '20261003230200_repair_attest_round2.sql']) {
    await apply(file);
  }
  const state = () => db.sql(`select coalesce(verification_failure_code,'null')||'|'||
    (case when verification_failed_at is null then 'null' else 'set' end)||'|'||verification_attempts::text
    from public.object_manifests where id='${oid}';`);
  const selected = () => db.sql(`select id::text from public.object_manifests
    where object_class='raw' and status='ready'
      and (durability_receipt is null or durability_receipt->>'state' is distinct from 'verified_indexed')
      and verification_failure_code is null
      and coalesce(compressed_bytes,0) > 0 and object_key is not null and object_kind is not null
    order by created_at;`);
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.sql(`insert into public.object_manifests
      (id, user_id, device_id, object_class, object_kind, provider, bucket, object_key, status,
       format, compression, compressed_bytes, created_at, updated_at)
      values ('${oid}', '${USER_A}', '${device}', 'raw', 'hrSample', 'b2', 'fixture',
              'v3/raw/users/${USER_A}/devices/${device}/${oid}.ndjson.gz', 'ready',
              'ndjson_gzip_noop_push_v1', 'gzip', 100, now(), now());`);

    await t.step('quarantine then un-quarantine clears the code/attempts and re-selects the object', async () => {
      await db.sql(`select public.noop_quarantine_manifest_verification('${oid}'::uuid, 'commit_rejected');`);
      assert((await state()).startsWith('commit_rejected|set|1'));
      assert(!(await selected()).includes(oid), 'quarantined object must not be selected');
      await db.sql(`select public.noop_unquarantine_manifest_verification('${oid}'::uuid);`);
      const s = await state();
      assert(s.startsWith('null|null|0'), `un-quarantine must clear everything, got: ${s}`);
      assert((await selected()).includes(oid), 'un-quarantined object must be re-selected');
    });

    await t.step('un-quarantine of a missing object raises object_not_found', async () => {
      let code = '';
      try {
        await db.sql(`select public.noop_unquarantine_manifest_verification('${crypto.randomUUID()}'::uuid);`);
        code = 'no_error';
      } catch (e: any) {
        code = String(e).includes('object_not_found') ? 'object_not_found' : 'other';
      }
      assert.equal(code, 'object_not_found');
    });
  } finally {
    await db.close();
  }
});
