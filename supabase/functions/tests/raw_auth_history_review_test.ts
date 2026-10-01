import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createPushObjects } from '../_shared/objects.ts';
import { createUploadReceiptStore } from '../_shared/receipts.ts';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';

Deno.test('review: failed representation admission and corrupt bytes never poison or acknowledge an original batch', async (t) => {
  const fixture = JSON.parse(await Deno.readTextFile(
    `${Deno.env.get('EDGE_TEST_ARTIFACTS')}/representation-swift/representation-compatibility.json`));
  const db = await startLocalPostgres({ objectRepresentations: true });
  const bucket = startObjectHttp();
  const objects = createPushObjects({ cfg: { b2KeyId: 'fixture', b2ApplicationKey: 'fixture',
    b2Bucket: 'fixture', rawStore: 'b2' } as any, rest: db.rest, raw: bucket.raw,
    receiptStore: createUploadReceiptStore({ rest: db.rest }) });
  const first = { ...fixture.streamed.manifest, batchId: crypto.randomUUID(), objectId: crypto.randomUUID() };
  const second = { ...fixture.legacy.manifest, batchId: first.batchId, objectId: crypto.randomUUID() };
  const put = async (intent: any, bytes: Uint8Array) => {
    const response = await fetch(intent.uploadUrl, { method: 'PUT', headers: intent.requiredHeaders, body: new Uint8Array(bytes) });
    await response.body?.cancel(); assert.equal(response.status, 200);
  };
  try {
    await t.step('failed first installation admission rolls back logical reservation', async () => {
      await assert.rejects(objects.createIntent({ userId: USER_A, sourceId: first.sourceId,
        authMode: 'installation', manifest: first }), /push_failed/);
      assert.equal(await db.sql(`select count(*) from noop_object_batch_identities where batch_id='${first.batchId}'`), '0');
      assert.equal((await db.rest.select('object_manifests', `batch_id=eq.${first.batchId}`)).length, 0);
    });
    const firstIntent = await objects.createIntent({ userId: USER_A, manifest: first });
    await put(firstIntent, new Uint8Array(Buffer.from(fixture.streamed.wire_base64, 'base64')));
    const firstReceipt = (await objects.completeObject({ userId: USER_A, objectId: first.objectId })).durabilityReceipt;
    const firstAudit = await db.rest.select('noop_upload_receipts', `object_id=eq.${first.objectId}`);
    await t.step('same physical object cannot acquire changed event bounds or wire length', async () => {
      for (const patch of [{ startTs: first.startTs - 1 }, { compressedBytes: first.compressedBytes + 1 }]) {
        await assert.rejects(objects.createIntent({ userId: USER_A, manifest: { ...first, ...patch } }), /object_id_conflict/);
      }
      assert.deepEqual((await objects.completeObject({ userId: USER_A, objectId: first.objectId })).durabilityReceipt, firstReceipt);
    });
    await t.step('corrupt second wire object gets no receipt and cannot alter the first', async () => {
      const intent = await objects.createIntent({ userId: USER_A, manifest: second });
      const bad = new Uint8Array(Buffer.from(fixture.legacy.wire_base64, 'base64'));
      bad.fill(0);
      await put(intent, bad);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: second.objectId }));
      assert.equal((await db.rest.select('noop_upload_receipts', `object_id=eq.${second.objectId}`)).length, 0);
      assert.equal((await db.rest.select('object_manifests', `id=eq.${second.objectId}`))[0].durability_receipt, null);
      assert.deepEqual(await db.rest.select('noop_upload_receipts', `object_id=eq.${first.objectId}`), firstAudit);
      assert.deepEqual((await objects.completeObject({ userId: USER_A, objectId: first.objectId })).durabilityReceipt, firstReceipt);
      await put(intent, new Uint8Array(Buffer.from(fixture.legacy.wire_base64, 'base64')));
      const corrected = (await objects.completeObject({ userId: USER_A, objectId: second.objectId })).durabilityReceipt;
      assert.equal(corrected.wireSha256, fixture.legacy.wire_sha256);
      assert.notEqual(corrected.receiptId, firstReceipt.receiptId);
      assert.equal(corrected.contentSha256, firstReceipt.contentSha256);
    });
    await t.step('expired physical source stays unavailable and preserves original receipt', async () => {
      await db.sql(`update object_manifests set status='expired' where id='${second.objectId}'`);
      const before = await db.rest.select('object_manifests', `id=eq.${second.objectId}`);
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: second.objectId }), /object_unavailable/);
      assert.deepEqual(await db.rest.select('object_manifests', `id=eq.${second.objectId}`), before);
      assert.deepEqual((await objects.completeObject({ userId: USER_A, objectId: first.objectId })).durabilityReceipt, firstReceipt);
    });
  } finally { await bucket.close(); await db.close(); }
});

Deno.test('review: account auth outage and forbidden responses never become installation revocation', async () => {
  for (const status of [401, 403, 429, 500, 503]) {
    let reads = 0;
    const rest: any = { configured: true, select: async () => { reads++; throw Error('unexpected source read'); },
      patch: async () => { throw Error('auth failure mutated credential'); },
      rpc: async () => { throw Error('auth failure queried results'); } };
    const response = await handleScoresRequest(new Request('https://fixture.invalid/functions/v1/scores/days?deviceId=whoop-review',
      { headers: { authorization: 'Bearer header.payload.signature', 'x-noop-source-id': crypto.randomUUID() } }),
    { rest, cfg: { supabaseUrl: 'https://fixture.invalid', supabaseAnonKey: 'fixture' },
      fetchImpl: async () => new Response(null, { status }) });
    const body = await response.json();
    assert.equal(response.status, status === 401 ? 401 : status === 403 ? 403 : 503);
    assert.equal(body.error, status === 401 ? 'unauthorized' : status === 403 ? 'forbidden' : 'auth_service_unavailable');
    assert.equal(reads, 0);
  }
});
