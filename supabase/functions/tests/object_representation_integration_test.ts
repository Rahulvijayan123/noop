import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createPushObjects } from '../_shared/objects.ts';
import { createUploadReceiptStore } from '../_shared/receipts.ts';
import { noopDeviceId, uuidFromParts } from '../_shared/keys.ts';
import { registerDevice } from '../_shared/durability.ts';
import { startLocalPostgres, USER_A, USER_B } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

Deno.test('representation upgrade: populated old receipts, concurrent identities and exact Swift Zstd wire receipts', async (t) => {
  const fixture = JSON.parse(await Deno.readTextFile(
    `${Deno.env.get('EDGE_TEST_ARTIFACTS')}/representation-swift/representation-compatibility.json`));
  const db = await startLocalPostgres({ installationLifecycle: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  let originalSQLFailure = '';
  const beforeRest = { ...db.rest, rpc: async (name: string, args: unknown) => {
    try { return await db.rest.rpc(name, args); }
    catch (error) { originalSQLFailure = String(error); throw error; }
  } };
  const before = createPushObjects({ cfg, rest: beforeRest, raw: bucket.raw });
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw,
    receiptStore: createUploadReceiptStore({ rest: db.rest }) });
  const old = fixture.legacy, fresh = fixture.streamed;
  const ship = async (client: typeof objects, representation: any) => {
    const intent = await client.createIntent({ userId: USER_A, manifest: representation.manifest });
    const wire = new Uint8Array(Buffer.from(representation.wire_base64, 'base64'));
    const response = await fetch(intent.uploadUrl!, { method: 'PUT', headers: intent.requiredHeaders, body: wire });
    await response.body?.cancel(); assert.equal(response.status, 200);
    return (await client.completeObject({ userId: USER_A, objectId: representation.manifest.objectId })).durabilityReceipt;
  };
  try {
    const original = await ship(before, old);
    const legacyAudit = {
      id: uuidFromParts([USER_A, 'upload-receipt', 'object', old.manifest.batchId]),
      user_id: USER_A, source_id: old.manifest.sourceId, device_id: original.deviceId, token_id: null,
      auth_mode: 'legacy_fleet', lane: 'object', stream: old.manifest.stream, batch_id: old.manifest.batchId,
      object_id: old.manifest.objectId, body_sha256: old.manifest.contentSha256,
      accepted_status: 'ready', accepted_rows: old.manifest.sampleCount, accepted_at: '2026-09-01T00:00:00Z',
    };
    await db.rest.upsert('noop_upload_receipts', legacyAudit, { onConflict: 'id' });
    const storedBefore = await db.rest.select('noop_upload_receipts', `id=eq.${legacyAudit.id}`);

    await t.step('old uniqueness independently reproduces the second-representation failure', async () => {
      await assert.rejects(before.createIntent({ userId: USER_A, manifest: fresh.manifest }),
        (error: any) => error.message === 'push_failed' && error.stage === 'archive_manifest');
      assert.match(originalSQLFailure, /object_manifests_user_batch_uidx/);
      assert.equal((await db.rest.select('object_manifests', `batch_id=eq.${old.manifest.batchId}`)).length, 1);
    });
    await db.sql(await Deno.readTextFile(new URL('../../migrations/20260923180000_object_representation_identity.sql', import.meta.url)));

    await t.step('populated migration preserves old rows and both verified wire receipts replay exactly', async () => {
      const second = await ship(objects, fresh);
      assert.notEqual(original.receiptId, second.receiptId);
      assert.equal(original.contentSha256, second.contentSha256);
      assert.equal(original.wireSha256, old.wire_sha256);
      assert.equal(second.wireSha256, fresh.wire_sha256);
      assert.equal(original.compressedBytes, old.manifest.compressedBytes);
      assert.equal(second.compressedBytes, fresh.manifest.compressedBytes);
      for (const [representation, receipt] of [[old, original], [fresh, second]]) {
        const retry = await objects.createIntent({ userId: USER_A, manifest: representation.manifest });
        assert.equal(retry.uploadUrl, undefined);
        assert.deepEqual(retry.durabilityReceipt, receipt);
        assert.deepEqual((await objects.completeObject({ userId: USER_A, objectId: receipt.objectId })).durabilityReceipt, receipt);
      }
      assert.deepEqual(await db.rest.select('noop_upload_receipts', `id=eq.${legacyAudit.id}`), storedBefore);
      const receipts = await db.rest.select('noop_upload_receipts', `batch_id=eq.${old.manifest.batchId}`);
      assert.equal(receipts.length, 2);
      assert.equal(new Set(receipts.map((r: any) => r.object_id)).size, 2);
      assert.equal((await db.rest.select('noop_push_acks', `batch_id=eq.${old.manifest.batchId}`)).length, 0);
      await Deno.writeTextFile(`${db.base}/wire-receipts.json`, JSON.stringify({ original, second, receipts }, null, 2));
    });

    // Force the normal preflight to miss both concurrent first admissions. The real RPC and
    // PostgreSQL unique binding must arbitrate; a sequential Edge check cannot pass this test.
    const raceRest = { ...db.rest, select: async (table: string, query = '') =>
      table === 'object_manifests' && query.includes('batch_id=eq.') ? [] : db.rest.select(table, query) };
    const racing = createPushObjects({ cfg, rest: raceRest, raw: bucket.raw });
    for (const user of [USER_A, USER_B]) {
      for (const device of [old.manifest.deviceId, 'second-physical-device']) {
        await registerDevice(db.rest, { id: noopDeviceId(user, device), user_id: user, external_device_id: device });
      }
    }
    await t.step('concurrent first admissions permit exact decoded representations', async () => {
      const batchId = crypto.randomUUID();
      const manifests = [old, fresh].map((r) => ({ ...r.manifest, batchId, objectId: crypto.randomUUID() }));
      const accepted = await Promise.all(manifests.map((manifest) => racing.createIntent({ userId: USER_A, manifest })));
      assert.equal(new Set(accepted.map((r) => r.objectKey)).size, 2);
      assert.equal((await db.rest.select('object_manifests', `user_id=eq.${USER_A}&batch_id=eq.${batchId}`)).length, 2);
    });
    await t.step('concurrent conflicting content, source, canonical device and original span admit one winner', async () => {
      for (const patch of [{ contentSha256: 'a'.repeat(64) }, { sourceId: crypto.randomUUID() },
        { deviceId: 'second-physical-device' }, { startTs: old.manifest.startTs - 1 },
        { sampleCount: old.manifest.sampleCount + 1 }, { uncompressedBytes: old.manifest.uncompressedBytes + 1 }]) {
        const batchId = crypto.randomUUID();
        const manifests = [{ ...old.manifest, batchId, objectId: crypto.randomUUID() },
          { ...fresh.manifest, ...patch, batchId, objectId: crypto.randomUUID() }];
        const results = await Promise.allSettled(manifests.map((manifest) => racing.createIntent({ userId: USER_A, manifest })));
        assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1, JSON.stringify(patch));
        const failure = results.find((r) => r.status === 'rejected') as PromiseRejectedResult;
        assert.equal(failure.reason.code, 'batch_id_conflict');
        assert.equal((await db.rest.select('object_manifests', `user_id=eq.${USER_A}&batch_id=eq.${batchId}`)).length, 1);
      }
    });
    await t.step('owner separation and database-only binding remain enforced', async () => {
      const other = { ...fresh.manifest, objectId: crypto.randomUUID() };
      await objects.createIntent({ userId: USER_B, manifest: other });
      await assert.rejects(objects.completeObject({ userId: USER_B, objectId: original.objectId }),
        (err: any) => err.code === 'forbidden');
      const stored = (await db.rest.select('object_manifests', `id=eq.${original.objectId}`))[0];
      await assert.rejects(db.rest.upsert('object_manifests', {
        ...stored, id: crypto.randomUUID(), sha256: 'b'.repeat(64), object_key: 'synthetic/must-not-land',
      }, { onConflict: 'id' }), /batch_id_conflict/);
      await assert.rejects(db.sql('set role authenticated; select * from public.noop_object_batch_identities'), /permission denied/);
      const counts = await db.sql(`select count(*) from public.noop_object_batch_identities where user_id='${USER_A}' and batch_id='${old.manifest.batchId}'`);
      assert.equal(counts, '1');
    });
    await t.step('wire-scoped inline identities still cannot acquire a second object', async () => {
      const stored = (await db.rest.select('object_manifests', `id=eq.${original.objectId}`))[0];
      const wireScoped = { ...stored, id: crypto.randomUUID(), batch_id: crypto.randomUUID(),
        object_kind: 'hrSample', format: 'ndjson_gzip_noop_push_v1', compression: 'gzip',
        digest_scope: 'wire', push_protocol_version: '1.1', object_key: `synthetic/${crypto.randomUUID()}` };
      await db.rest.rpc('noop_reserve_object_manifest', { p_manifest: wireScoped });
      await assert.rejects(db.rest.rpc('noop_reserve_object_manifest', { p_manifest: {
        ...wireScoped, id: crypto.randomUUID(), object_key: `synthetic/${crypto.randomUUID()}`,
      } }), /batch_id_conflict/);
      assert.equal((await db.rest.select('object_manifests', `batch_id=eq.${wireScoped.batch_id}`)).length, 1);
    });
    await t.step('installation withdrawal rejects a second representation without altering existing data', async () => {
      const source = crypto.randomUUID(), enrollmentCode = crypto.randomUUID(), batchId = crypto.randomUUID();
      await db.sql(`insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
        values('${enrollmentCode}','${USER_A}',repeat('d',64),now()+interval '1 day');
        insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
        values('${source}','${USER_A}','${enrollmentCode}','ios','fixture');`);
      const identity = { userId: USER_A, sourceId: source, authMode: 'installation' as const };
      const first = { ...old.manifest, sourceId: source, batchId, objectId: crypto.randomUUID() };
      await objects.createIntent({ ...identity, manifest: first });
      const beforeWithdrawal = await db.rest.select('object_manifests', `batch_id=eq.${batchId}`);
      await db.sql(`update noop_app_installations set revoked_at=clock_timestamp() where source_id='${source}'`);
      await assert.rejects(objects.createIntent({ ...identity,
        manifest: { ...fresh.manifest, sourceId: source, batchId, objectId: crypto.randomUUID() } }),
      (err: any) => err.message === 'push_failed' && err.stage === 'archive_manifest');
      assert.deepEqual(await db.rest.select('object_manifests', `batch_id=eq.${batchId}`), beforeWithdrawal);
      assert.equal((await db.rest.select('noop_upload_receipts', `batch_id=eq.${batchId}`)).length, 0);
    });
  } finally { await bucket.close(); await db.close(); }
});
