import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { historyCheckpoint, recoverHistoryPage } from '../_shared/historyRecovery.ts';
import { createS3, sha256Hex } from '../_shared/s3.ts';

const owner = '11111111-1111-4111-8111-111111111111';
const device = '22222222-2222-4222-8222-222222222222';
const object = '33333333-3333-4333-8333-333333333333';
const receiptId = '44444444-4444-4444-8444-444444444444';
const scope = { project: 'https://abcdefghijklmnopqrst.supabase.co', userId: owner, deviceId: device, sourceRevision: 'a'.repeat(40) };
const plain = new TextEncoder().encode('retained immutable fixture bytes');
const wire = new Uint8Array(gzipSync(plain));
function fixture() {
  const receipt = { state: 'verified_indexed', version: 1, receiptId, ownerUserId: owner, deviceId: device, objectId: object,
    objectKey: 'immutable/original.gz', compressedBytes: wire.length, uncompressedBytes: plain.length,
    wireSha256: sha256Hex(wire), contentSha256: sha256Hex(plain) };
  return { schema_version: 1, user_id: owner, device_id: device, items: [{
    object: { id: object, user_id: owner, device_id: device, object_key: receipt.objectKey, durability_receipt: receipt,
      compression: 'gzip', compressed_bytes: wire.length, uncompressed_bytes: plain.length,
      format: 'binary', sha256: sha256Hex(plain), digest_scope: 'decoded' },
    affected_days: [{ day: '2026-08-01', timezone: 'America/Los_Angeles', state: 'projected_not_queued' }],
  }], next_cursor: null, scan_complete: true };
}

Deno.test('history recovery binds resumable checkpoint to exact owner device project and candidate', () => {
  const checkpoint = historyCheckpoint(scope);
  assert.deepEqual(historyCheckpoint(scope, checkpoint), checkpoint);
  for (const changed of [{ userId: device }, { deviceId: owner }, { project: 'https://bcdefghijklmnopqrstuq.supabase.co' },
    { sourceRevision: 'b'.repeat(40) }]) assert.throws(() => historyCheckpoint({ ...scope, ...changed }, checkpoint));
});

Deno.test('history discovery preserves original object identities and bounds resumed requests', async () => {
  let calls = 0;
  const rest: any = { rpc: async (name: string, args: any) => {
    calls++; assert.equal(name, 'noop_history_inventory_page'); assert.equal(args.p_limit, 1);
    return { ...fixture(), inventory_cutoff: args.p_before };
  } };
  const result = await recoverHistoryPage(rest, null, historyCheckpoint(scope), { limit: 1 });
  assert.equal(result.page.items[0].object.id, object);
  assert.equal(result.page.items[0].affected_days[0].day, '2026-08-01');
  assert.equal(result.page.items[0].raw_readability, 'NOT_MEASURED');
  assert.equal(result.page.items[0].derived_archive_readability, 'NOT_MEASURED');
  await assert.rejects(recoverHistoryPage(rest, null, result.checkpoint), /already_complete/);
  assert.equal(calls, 1);
});

Deno.test('history whole-page owner validation precedes reads and replay', async () => {
  let calls = 0;
  const page = fixture(); page.items.push(structuredClone(page.items[0])); page.items[1].object.user_id = device;
  const rest: any = { rpc: async (_name: string, args: any) => { calls++; return { ...page, inventory_cutoff: args.p_before }; } };
  await assert.rejects(recoverHistoryPage(rest, null, historyCheckpoint(scope)), /identity_mismatch/);
  assert.equal(calls, 1);
});

Deno.test('history HEAD and immutable GET hash are separate from derived archive settlement', async () => {
  for (const failure of ['none', 'HEAD', 'GET_HASH']) {
    const replayed: any[] = [];
    const rest: any = { rpc: async (name: string, args: any) => {
      if (name === 'noop_history_inventory_page') return { ...fixture(), inventory_cutoff: args.p_before };
      replayed.push(args); return { queued_days: 1 };
    } };
    const raw = createS3({ endpoint: 'https://fixture.invalid', bucket: 'fixture', region: 'fixture',
      accessKeyId: 'fixture', secretAccessKey: 'fixture', fetchImpl: async (_url, init) => {
        if (init?.method === 'HEAD') return failure === 'HEAD' ? new Response(null, { status: 403 }) :
          new Response(null, { headers: { 'content-length': String(wire.length), 'x-amz-version-id': 'exact-version' } });
        return new Response(failure === 'GET_HASH' ? new Uint8Array([1]) : wire,
          { headers: { 'x-amz-version-id': 'exact-version' } });
      } });
    const result = await recoverHistoryPage(rest, raw, historyCheckpoint(scope), { verifyRaw: true, requeue: true });
    const item = result.page.items[0];
    assert.equal(item.derived_archive_readability, 'NOT_MEASURED');
    if (failure === 'none') {
      assert.equal(item.raw_readability, 'PASS'); assert.equal(item.raw_readback.versionId, 'exact-version');
      assert.deepEqual(replayed, [{ p_user: owner, p_device: device, p_object: object, p_receipt: receiptId }]);
    } else {
      assert.equal(item.raw_readability, 'FAIL'); assert.equal(item.first_failed_operation, failure);
      assert.deepEqual(replayed, []);
    }
  }
});
