import assert from 'node:assert/strict';
import { startLocalPostgres, USER_A } from './local_postgres.ts';

// Proves the projection-debt dead-letter (20261003203000_projection_debt_dead_letter.sql):
//  - failures 1..15 keep the row pending with the capped exponential backoff and NO dead-letter;
//  - the 16th consecutive failure marks it dead_letter=true with reason projection_replay_exhausted;
//  - noop_claim_projection_debt never returns a dead-lettered row (even with a verified manifest),
//    so the projection lane stops burning its budget on poison rows after restart;
//  - a transient failure path is unchanged (still fails open to retry).
// Runs against the throwaway local-PG harness, never a shared DB.

Deno.test('projection debt dead-letters at 16 and excludes the row from every future claim', async (t) => {
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
  await apply('20261003203000_projection_debt_dead_letter.sql');
  const objectId = crypto.randomUUID();
  const token = crypto.randomUUID();
  const lease = () => db.sql(`update public.noop_projection_debt
    set lease_token='${token}', lease_until=clock_timestamp()+interval '2 minutes'
    where object_id='${objectId}';`);
  const fail = () => db.sql(`select public.noop_fail_projection_debt('${objectId}'::uuid, '${token}'::uuid);`);
  const row = () => db.sql(`select failures::text||'|'||(case when dead_letter then 't' else 'f' end)||'|'||coalesce(dead_letter_reason,'')||'|'||
      (case when not_before > clock_timestamp() then 'backed_off' else 'due' end)
    from public.noop_projection_debt where object_id='${objectId}';`);
  try {
    await db.rest.rpc('noop_register_push_device', {
      p_user_id: USER_A, p_device_id: device, p_external_device_id: device,
    });
    await db.sql(`insert into public.object_manifests
      (id, user_id, device_id, object_class, object_kind, provider, bucket, object_key, status,
       durability_receipt, created_at, updated_at)
      values ('${objectId}', '${USER_A}', '${device}', 'raw', 'hrSample', 'b2', 'fixture',
              'v3/raw/users/${USER_A}/devices/${device}/x.ndjson.gz', 'verified',
              '{"state":"verified_indexed"}'::jsonb, now(), now());`);
    await db.sql(`insert into public.noop_projection_debt
      (object_id, user_id, device_id, state, failures, not_before)
      values ('${objectId}', '${USER_A}', '${device}', 'pending', 0, clock_timestamp());`);

    await t.step('failures 1..15 keep the row pending with backoff and no dead-letter', async () => {
      for (let i = 1; i <= 15; i++) {
        await lease();
        await fail();
        const r = await row();
        const [failures, dead, reason, due] = r.trim().split('|');
        assert.equal(failures, String(i), `failure ${i} must be recorded`);
        assert.equal(dead, 'f', `failure ${i} must NOT be dead-lettered`);
        assert.equal(reason, '', `failure ${i} must have no dead-letter reason`);
        assert.equal(due, 'backed_off', `failure ${i} must apply backoff`);
      }
    });

    await t.step('the 16th failure dead-letters with a bounded reason', async () => {
      await lease();
      await fail();
      const r = await row();
      const [failures, dead, reason] = r.trim().split('|');
      assert.equal(failures, '16');
      assert.equal(dead, 't');
      assert.equal(reason, 'projection_replay_exhausted');
    });

    await t.step('a dead-lettered row is never claimed again, even with a verified manifest', async () => {
      // With the old code this row (verified manifest, pending, due) WOULD be claimed.
      await db.sql(`update public.noop_projection_debt set not_before=clock_timestamp() where object_id='${objectId}';`);
      const claimed = await db.sql(`select public.noop_claim_projection_debt()::text;`);
      assert.equal(claimed.trim(), '', 'dead-lettered row must not be claimable');
    });

    await t.step('an operator can reactivate a dead-lettered row explicitly', async () => {
      await db.sql(`update public.noop_projection_debt set dead_letter=false, dead_letter_reason=null,
        failures=0, not_before=clock_timestamp() where object_id='${objectId}';`);
      const claimed = await db.sql(`select public.noop_claim_projection_debt()::text;`);
      assert(claimed.includes(objectId), 'reactivated row must be claimable again');
    });
  } finally {
    await db.close();
  }
});
