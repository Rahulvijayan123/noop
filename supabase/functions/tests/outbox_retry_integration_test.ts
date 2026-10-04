import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves the physiology_archive_outbox 'retry' status fix (G56 P2 / contract C5):
//  1. the CHECK now admits status='retry' (20261003201000_outbox_retry_status.sql);
//  2. the exact releaseOutboxLease write ArchiveLane.swift:253-261 uses commits with
//     the 30 s next_attempt_at backoff and clears the lease;
//  3. the claim predicate (ArchiveLane.swift:130-147, which lists 'retry') picks a
//     due 'retry' row but leaves one whose backoff has not elapsed alone.
// Runs against the throwaway local-PG harness (EDGE_TEST_ARTIFACTS), never a shared DB.

Deno.test('outbox retry status: CHECK admits retry, lease release commits with backoff, claim picks due retry rows', async (t) => {
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
  await apply('20260918020000_physiology_publication.sql');
  await apply('20261003201000_outbox_retry_status.sql');
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.sql(`insert into public.server_physiology_results
      (user_id,device_id,period_day,algorithm_version,input_revision,run_id,manifest_hash,payload,payload_hash,
       observed_through,computed_at,publication_status)
      values ('${USER_A}','${device}','2026-09-20','frwhoop-server-1',1,
        '44444444-4444-4444-8444-444444444444', repeat('a',64), '{}'::jsonb, repeat('b',64),
        '2026-09-20T12:00:00Z','2026-09-20T12:00:00Z','provisional');`);
    await db.sql(`insert into public.physiology_archive_outbox
      (user_id,device_id,period_day,algorithm_version,input_revision,object_key)
      values ('${USER_A}','${device}','2026-09-20','frwhoop-server-1',1,
        'v3/derived/users/${USER_A}/devices/${device}/days/2026-09-20/frwhoop-server-1/revisions/1/x.json.zst');`);

    await t.step('CHECK admits status=retry (the exact releaseOutboxLease UPDATE commits)', async () => {
      const constraint = await db.sql(`
        select pg_get_constraintdef(oid) from pg_constraint
         where conname='physiology_archive_outbox_status_check' and conrelid='public.physiology_archive_outbox'::regclass;`);
      assert(constraint.includes("'retry'"), `constraint must admit retry, got: ${constraint}`);

      // Claim the row the way ArchiveLane.archiveOneOutbox does.
      const claimed = await db.sql(`
        WITH claimed AS (
          SELECT id FROM public.physiology_archive_outbox
           WHERE status IN ('pending','retry','uploading')
             AND coalesce(next_attempt_at, '-infinity'::timestamptz) <= now()
             AND (lease_expires_at IS NULL OR lease_expires_at <= now())
           ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED
        )
        UPDATE public.physiology_archive_outbox o
          SET status='uploading', lease_token=gen_random_uuid(),
              lease_expires_at=now()+make_interval(secs => 300), attempts=attempts+1, last_error=NULL
          FROM claimed WHERE o.id = claimed.id
        RETURNING o.id::text, o.lease_token::text, o.status;`);
      assert(claimed.includes('|uploading'), `claim should set uploading, got: ${claimed}`);
      const token = claimed.split('|')[1];

      // The exact releaseOutboxLease write (ArchiveLane.swift:253-261): must commit (fix) and back off 30 s.
      const released = await db.sql(`
        UPDATE public.physiology_archive_outbox
           SET status='retry', lease_token=NULL, lease_expires_at=NULL,
               next_attempt_at = now() + make_interval(secs => 30), last_error='fixture'
         WHERE id=1 AND lease_token='${token}' AND lease_expires_at > now()
        RETURNING id::text;`);
      assert.equal(released, '1', 'releaseOutboxLease must update the row (pre-fix: check-constraint error)');
      const row = await db.sql(`
        select status, lease_token is null as lease_null, lease_expires_at is null as expiry_null,
               (extract(epoch from (next_attempt_at - now())))::int as backoff_seconds
        from public.physiology_archive_outbox where id=1;`);
      const cols = row.trim().split('|');
      assert.equal(cols[0], 'retry', `status must be retry, got: ${row}`);
      assert.equal(cols[1], 't', `lease_token must be null, got: ${row}`);
      assert.equal(cols[2], 't', `lease_expires_at must be null, got: ${row}`);
      const backoff = Number(cols[3]);
      assert(backoff >= 25 && backoff <= 40, `next_attempt_at must back off ~30 s, got: ${row}`);
    });

    await t.step('claim skips a retry row still inside its backoff window', async () => {
      const due = await db.sql(`
        SELECT id FROM public.physiology_archive_outbox
         WHERE status IN ('pending','retry','uploading')
           AND coalesce(next_attempt_at, '-infinity'::timestamptz) <= now()
           AND (lease_expires_at IS NULL OR lease_expires_at <= now())
         ORDER BY id LIMIT 1;`);
      assert.equal(due.trim(), '', `backing-off retry row must not be claimable yet, got: ${due}`);
    });

    await t.step('claim picks a retry row whose backoff has elapsed', async () => {
      await db.sql(`update public.physiology_archive_outbox set next_attempt_at=now()-interval '1 second' where id=1;`);
      const due = await db.sql(`
        SELECT id FROM public.physiology_archive_outbox
         WHERE status IN ('pending','retry','uploading')
           AND coalesce(next_attempt_at, '-infinity'::timestamptz) <= now()
           AND (lease_expires_at IS NULL OR lease_expires_at <= now())
         ORDER BY id LIMIT 1;`);
      assert.equal(due.trim(), '1', 'due retry row must be claimable (predicate lists retry)');
    });
  } finally {
    await db.close();
  }
});
