import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// P2 (audit-g2-durability, outbox): physiology_archive_outbox now has a bounded
// dead-letter (20261003230200). Mirrors projection debt:
//  - attempts 1..15 keep the row retryable with the 30 s backoff and NO dead-letter;
//  - the 16th release dead-letters (status='failed', dead_letter=true, bounded reason);
//  - the claim predicate excludes dead-lettered rows;
//  - release respects the cap (a release past the cap is terminal, not another backoff).
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('outbox dead-letters after the attempt cap and the claim excludes it', async (t) => {
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
  await apply('20261003230200_repair_attest_round2.sql');
  const token = crypto.randomUUID();
  // Force the row due before each claim: releaseOutboxLease backs it off 30 s,
  // and the test must not wait for wall-clock time between iterations.
  const makeDue = () => db.sql(`update public.physiology_archive_outbox
    set next_attempt_at = now() - interval '1 second' where id=1;`);
  const claim = () => db.sql(`
    WITH claimed AS (
      SELECT id FROM public.physiology_archive_outbox
       WHERE status IN ('pending','retry','uploading') AND NOT dead_letter
         AND coalesce(next_attempt_at, '-infinity'::timestamptz) <= now()
         AND (lease_expires_at IS NULL OR lease_expires_at <= now())
       ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED
    )
    UPDATE public.physiology_archive_outbox o
      SET status='uploading', lease_token='${token}',
          lease_expires_at=now()+make_interval(secs => 300), attempts=attempts+1, last_error=NULL
      FROM claimed WHERE o.id = claimed.id
    RETURNING o.id::text, o.attempts::text;`);
  const release = (reason: string) => db.sql(`
    UPDATE public.physiology_archive_outbox
       SET status = CASE WHEN attempts >= 16 THEN 'failed' ELSE 'retry' END,
           dead_letter = (attempts >= 16),
           dead_letter_reason = CASE WHEN attempts >= 16 THEN 'archive_upload_exhausted' ELSE NULL END,
           lease_token=NULL, lease_expires_at=NULL,
           next_attempt_at = now() + make_interval(secs => CASE WHEN attempts >= 16 THEN 0 ELSE 30 END),
           last_error='${reason}'
     WHERE id=1 AND lease_token='${token}' AND lease_expires_at > now()
    RETURNING id::text;`);
  const row = () => db.sql(`select attempts::text||'|'||status||'|'||(case when dead_letter then 't' else 'f' end)||'|'||
      coalesce(dead_letter_reason,'')||'|'||(case when next_attempt_at > now()+interval '20 seconds' then 'backed_off' else 'due' end)
    from public.physiology_archive_outbox where id=1;`);
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

    await t.step('attempts 1..15 stay retryable with backoff and no dead-letter', async () => {
      for (let i = 1; i <= 15; i++) {
        await makeDue();
        await claim();
        await release(`failure ${i}`);
        const r = await row();
        const [attempts, status, dead, reason, due] = r.trim().split('|');
        assert.equal(attempts, String(i), `attempt ${i} must be counted`);
        assert.equal(status, 'retry', `attempt ${i} must be retry`);
        assert.equal(dead, 'f', `attempt ${i} must NOT be dead-lettered`);
        assert.equal(reason, '', `attempt ${i} must have no dead-letter reason`);
        assert.equal(due, 'backed_off', `attempt ${i} must apply the 30 s backoff`);
      }
    });

    await t.step('the 16th release dead-letters with a bounded reason', async () => {
      await makeDue();
      await claim();
      await release('failure 16');
      const r = await row();
      const [attempts, status, dead, reason] = r.trim().split('|');
      assert.equal(attempts, '16');
      assert.equal(status, 'failed', 'terminal status must be failed');
      assert.equal(dead, 't');
      assert.equal(reason, 'archive_upload_exhausted');
    });

    await t.step('the claim excludes a dead-lettered row', async () => {
      const c = await claim();
      assert.equal(c.trim(), '', 'a dead-lettered outbox row must not be claimable');
    });

    await t.step('release respects the cap (no backoff after dead-letter)', async () => {
      // Force a fresh lease on the dead-lettered row and release again: it must
      // stay terminal (failed/dead_lettered), not bounce back to retry.
      await db.sql(`update public.physiology_archive_outbox set lease_token='${token}',
        lease_expires_at=now()+interval '5 minutes' where id=1;`);
      await release('after cap');
      const r = await row();
      const [, status, dead, reason] = r.trim().split('|');
      assert.equal(status, 'failed');
      assert.equal(dead, 't');
      assert.equal(reason, 'archive_upload_exhausted');
    });
  } finally {
    await db.close();
  }
});
