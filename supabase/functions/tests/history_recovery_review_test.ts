import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { historyCheckpoint, recoverHistoryPage } from '../_shared/historyRecovery.ts';
import { createS3, sha256Hex } from '../_shared/s3.ts';

Deno.test('history raw readback cannot attribute an unversioned GET to a different HEAD version', async () => {
  const owner = 'a1111111-1111-4111-8111-111111111111';
  const device = 'a2222222-2222-4222-8222-222222222222';
  const object = 'a3333333-3333-4333-8333-333333333333';
  const receiptId = 'a4444444-4444-4444-8444-444444444444';
  const bytes = new TextEncoder().encode('original retained bytes unchanged across storage versions');
  const wire = new Uint8Array(gzipSync(bytes));
  const receipt = { state: 'verified_indexed', version: 1, receiptId, ownerUserId: owner, deviceId: device,
    objectId: object, objectKey: 'immutable/retained.gz', compressedBytes: wire.length,
    uncompressedBytes: bytes.length, wireSha256: sha256Hex(wire), contentSha256: sha256Hex(bytes) };
  let replayed = 0;
  let requestedVersion: string | null = null;
  const rest: any = { rpc: async (name: string, args: any) => {
    if (name === 'noop_history_requeue_object') { replayed++; return { queued_days: 1 }; }
    assert.equal(name, 'noop_history_inventory_page');
    return { schema_version: 1, user_id: owner, device_id: device, inventory_cutoff: args.p_before,
      scan_complete: true, next_cursor: null, items: [{ object: {
        id: object, user_id: owner, device_id: device, object_key: receipt.objectKey, durability_receipt: receipt,
        compression: 'gzip', format: 'binary', compressed_bytes: wire.length,
        uncompressed_bytes: bytes.length, sha256: sha256Hex(bytes), digest_scope: 'decoded',
      }, affected_days: [{ day: '2026-01-01', state: 'projected_not_queued' }] }] };
  } };
  const raw = createS3({ endpoint: 'https://fixture.invalid', bucket: 'fixture', region: 'fixture',
    accessKeyId: 'fixture', secretAccessKey: 'fixture', fetchImpl: async (input, init) => {
      if (init?.method === 'HEAD') return new Response(null, { headers: {
        'content-length': String(wire.length), 'x-amz-version-id': 'head-version' } });
      requestedVersion = new URL(String(input)).searchParams.get('versionId');
      return new Response(wire, { headers: {
        'x-amz-version-id': requestedVersion === 'head-version' ? 'head-version' : 'newer-same-bytes-version' } });
    } });
  const checkpoint = historyCheckpoint({ project: 'https://abcdefghijklmnopqrst.supabase.co',
    userId: owner, deviceId: device, sourceRevision: 'a'.repeat(40) });
  const result = await recoverHistoryPage(rest, raw, checkpoint, { verifyRaw: true, requeue: true });
  const item = result.page.items[0];
  if (requestedVersion === 'head-version') {
    assert.equal(item.raw_readability, 'PASS');
    assert.equal(item.raw_readback.versionId, 'head-version');
    assert.equal(replayed, 1);
  } else {
    assert.equal(item.raw_readability, 'FAIL', 'a matching digest does not prove which version GET read');
    assert.equal(item.first_failed_operation, 'GET_HASH');
    assert.equal(replayed, 0, 'unbound version readback cannot authorize historical replay');
  }
  assert.equal(item.derived_archive_readability, 'NOT_MEASURED');
});
