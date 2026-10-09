import assert from 'node:assert/strict';
import { createPushObjects } from '../_shared/objects.ts';
import { registerDevice } from '../_shared/durability.ts';
import { noopDeviceId } from '../_shared/keys.ts';
import { startLocalPostgres, USER_A } from './local_postgres.ts';
import { startObjectHttp } from './local_objects.ts';
import { PPG_ANCHOR_GOLDEN, unhex, vector } from './ppg_anchor_golden.ts';

// Proves 20261008120000_ppg_transport_anchor.sql with the receiver code on real PostgreSQL and
// PostgREST plus the loopback object fixture: a protocol 1.5 PPG object from the Swift golden
// (the phone's own encoder output) reserves at schema 3, verifies its format 3 framing, earns a
// schema 3 receipt with the exact bytes archived, coexists with the anchor-less 1.3 twin of the same
// seconds, and nothing else can claim schema 3. Runs against the throwaway harness only.
Deno.test('1.5 PPG anchor objects: schema 3 reservation, format 3 receipts and legacy coexistence', async (t) => {
  const db = await startLocalPostgres({ objectRepresentations: true });
  const bucket = startObjectHttp();
  const cfg: any = { b2KeyId: 'fixture', b2ApplicationKey: 'fixture', b2Bucket: 'fixture', rawStore: 'b2' };
  const objects = createPushObjects({ cfg, rest: db.rest, raw: bucket.raw });
  const wireOf = (v: any): Uint8Array<ArrayBuffer> => Uint8Array.from(atob(v.wire_base64), (c) => c.charCodeAt(0));
  const get = async (id: string) => (await db.rest.select('object_manifests', `id=eq.${id}`))[0];
  async function ship(manifest: any, wire: Uint8Array<ArrayBuffer>) {
    const intent = await objects.createIntent({ userId: USER_A, manifest });
    const sent = await fetch(intent.uploadUrl!, { method: 'PUT', headers: intent.requiredHeaders, body: wire });
    await sent.body?.cancel(); assert.equal(sent.status, 200);
    return intent;
  }
  try {
    await registerDevice(db.rest, { id: noopDeviceId(USER_A, PPG_ANCHOR_GOLDEN.device_id), user_id: USER_A,
      external_device_id: PPG_ANCHOR_GOLDEN.device_id });

    await t.step('before the migration the reservation core refuses schema 3', async () => {
      const v = vector('phone_real_frames');
      await assert.rejects(objects.createIntent({ userId: USER_A, manifest: v.manifest }));
      assert.equal(await get(v.manifest.objectId), undefined);
    });
    await db.sql(await Deno.readTextFile(new URL('../../migrations/20261008120000_ppg_transport_anchor.sql', import.meta.url)));

    const receipts: Record<string, any> = {};
    await t.step('golden 1.5 objects reserve at schema 3 and earn a schema 3 receipt over exact bytes', async () => {
      for (const name of ['phone_real_frames', 'all_members']) {
        const v = vector(name);
        await ship(v.manifest, wireOf(v));
        const ack = await objects.completeObject({ userId: USER_A, objectId: v.manifest.objectId });
        assert.equal(ack.protocolVersion, '1.5');
        assert.equal(ack.durabilityReceipt.schemaVersion, 3);
        assert.equal(ack.durabilityReceipt.contentSha256, v.decoded_sha256);
        assert.equal(ack.durabilityReceipt.wireSha256, v.wire_sha256);
        assert.deepEqual(bucket.objects.get(ack.objectKey), wireOf(v));
        const row = await get(v.manifest.objectId);
        assert.equal(row.push_protocol_version, '1.5');
        assert.equal(row.schema_version, 3);
        assert.equal(row.sample_count, v.rows.length);
        assert.equal(row.durability_receipt.state, 'verified_indexed');
        receipts[name] = ack.durabilityReceipt;
        // A retry is the same object: no new upload URL, the identical receipt.
        const retry = await objects.createIntent({ userId: USER_A, manifest: v.manifest });
        assert.equal(retry.uploadUrl, undefined);
        assert.deepEqual(retry.durabilityReceipt, ack.durabilityReceipt);
      }
    });

    await t.step('the anchor-less 1.3 twin of the same seconds is a separate, unchanged schema 2 object', async () => {
      const twin = vector('phone_real_frames_legacy_v2');
      await ship(twin.manifest, wireOf(twin));
      const ack = await objects.completeObject({ userId: USER_A, objectId: twin.manifest.objectId });
      assert.equal(ack.protocolVersion, '1.3');
      assert.equal(ack.durabilityReceipt.schemaVersion, 2);
      const anchored = vector('phone_real_frames');
      assert.notEqual(twin.manifest.batchId, anchored.manifest.batchId);
      const sameSeconds = await db.rest.select('object_manifests',
        `user_id=eq.${USER_A}&object_kind=eq.ppgWaveformSample&start_at=eq.${encodeURIComponent(new Date(anchored.manifest.startTs * 1000).toISOString())}&status=eq.ready&select=id,schema_version,push_protocol_version`);
      assert.deepEqual(sameSeconds.map((r: any) => `${r.push_protocol_version}/${r.schema_version}`).sort(), ['1.3/2', '1.5/3']);
    });

    await t.step('format 2 bytes under a 1.5 manifest never earn a receipt', async () => {
      const twin = vector('phone_real_frames_legacy_v2');
      const lie = { ...vector('phone_real_frames').manifest, objectId: crypto.randomUUID(), batchId: crypto.randomUUID(),
        contentSha256: twin.decoded_sha256, uncompressedBytes: unhex(twin.decoded_hex).length,
        compressedBytes: wireOf(twin).length };
      await ship(lie, wireOf(twin));
      await assert.rejects(objects.completeObject({ userId: USER_A, objectId: lie.objectId }), /invalid_ppg_envelope/);
      const row = await get(lie.objectId);
      assert.equal(row.durability_receipt, null);
      assert.equal((await db.rest.select('noop_signal_windows', `object_id=eq.${lie.objectId}`)).length, 0);
    });

    await t.step('no other stream or version can reserve schema 3', async () => {
      const base = (await get(vector('phone_real_frames').manifest.objectId));
      for (const patch of [{ object_kind: 'rawImuSession' }, { push_protocol_version: '1.3' }, { push_protocol_version: '1.4' }]) {
        const manifest = { ...base, ...patch, id: crypto.randomUUID(), batch_id: crypto.randomUUID(),
          durability_receipt: null, status: 'pending', object_key: `synthetic/${crypto.randomUUID()}` };
        await assert.rejects(db.rest.rpc('noop_reserve_object_manifest', { p_manifest: manifest }),
          /invalid_object_manifest/, JSON.stringify(patch));
      }
    });
    await Deno.writeTextFile(`${db.base}/ppg-anchor-receipts.json`, JSON.stringify(receipts, null, 2));
    console.log(`ppg anchor proof: ${db.base}/ppg-anchor-receipts.json`);
  } finally { await bucket.close(); await db.close(); }
});
