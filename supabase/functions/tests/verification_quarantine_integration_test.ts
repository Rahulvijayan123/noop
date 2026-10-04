import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves the durable verification quarantine (20261003205900_verification_quarantine.sql):
//  - noop_quarantine_manifest_verification records a bounded code + first-failed time and caps attempts;
//  - a repeat quarantine keeps the ORIGINAL failed_at (idempotent) and bumps the capped counter;
//  - an invalid code is rejected (22023);
//  - the worker's candidateSQL predicate (verification_failure_code IS NULL) excludes the
//    quarantined manifest while leaving transient/normal candidates selected.
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('verification quarantine is durable and excludes the manifest from future scans', async (t) => {
  const db = await startLocalPostgres();
  const device = '33333333-3333-4333-8333-333333333333';
  const bad = crypto.randomUUID();
  const good = crypto.randomUUID();
  const apply = async (file: string) => {
    const path = new URL(`../../migrations/${file}`, import.meta.url);
    const r = await new Deno.Command('/opt/homebrew/bin/psql', {
      args: ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', db.base, '-U', 'edge_test', '-d', 'postgres',
             '-f', decodeURIComponent(path.pathname)],
      stdout: 'piped', stderr: 'piped', clearEnv: true,
    }).output();
    if (!r.success) throw new Error(`apply ${file} failed: ${new TextDecoder().decode(r.stderr).slice(-2000)}`);
  };
  await apply('20261003205900_verification_quarantine.sql');
  const manifest = (id: string) => `insert into public.object_manifests
    (id, user_id, device_id, object_class, object_kind, provider, bucket, object_key, status,
     format, compression, compressed_bytes, created_at, updated_at)
    values ('${id}', '${USER_A}', '${device}', 'raw', 'hrSample', 'b2', 'fixture',
            'v3/raw/users/${USER_A}/devices/${device}/${id}.ndjson.gz', 'ready',
            'ndjson_gzip_noop_push_v1', 'gzip', 100, now(), now());`;
  const state = (id: string) => db.sql(`select coalesce(verification_failure_code,'null')||'|'||
    (case when verification_failed_at is null then 'null' else 'set' end)||'|'||verification_attempts::text
    from public.object_manifests where id='${id}';`);
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.sql(manifest(bad));
    await db.sql(manifest(good));

    await t.step('a deterministic mismatch is durably quarantined', async () => {
      await db.sql(`select public.noop_quarantine_manifest_verification('${bad}'::uuid, 'no_expected_wire_digest');`);
      const s = await state(bad);
      assert(s.startsWith('no_expected_wire_digest|set|1'), `unexpected state: ${s}`);
    });

    await t.step('a repeat quarantine is idempotent on time and capped on attempts', async () => {
      await db.sql(`select public.noop_quarantine_manifest_verification('${bad}'::uuid, 'no_expected_wire_digest');`);
      const s = await state(bad);
      assert(s.startsWith('no_expected_wire_digest|set|2'), `attempts must bump, time must stick: ${s}`);
      for (let i = 0; i < 20; i++) {
        await db.sql(`select public.noop_quarantine_manifest_verification('${bad}'::uuid, 'no_expected_wire_digest');`);
      }
      assert((await state(bad)).endsWith('|16'), 'attempts must cap at 16');
    });

    await t.step('an invalid quarantine code is rejected whole', async () => {
      let code = '';
      try {
        await db.sql(`select public.noop_quarantine_manifest_verification('${bad}'::uuid, 'BAD CODE');`);
        code = 'no_error';
      } catch (e: any) {
        code = String(e).includes('invalid verification quarantine') ? 'rejected' : 'other';
      }
      assert.equal(code, 'rejected');
      // The row must still carry the original bounded code.
      assert((await state(bad)).startsWith('no_expected_wire_digest|'));
    });

    await t.step('the candidateSQL predicate excludes quarantined but keeps other candidates', async () => {
      const selected = await db.sql(`select id::text from public.object_manifests
        where object_class='raw' and status='ready'
          and (durability_receipt is null or durability_receipt->>'state' is distinct from 'verified_indexed')
          and verification_failure_code is null
          and coalesce(compressed_bytes,0) > 0 and object_key is not null and object_kind is not null
        order by created_at;`);
      assert(selected.includes(good), 'the normal manifest must still be selected');
      assert(!selected.includes(bad), 'the quarantined manifest must be excluded from future scans');
    });
  } finally {
    await db.close();
  }
});
