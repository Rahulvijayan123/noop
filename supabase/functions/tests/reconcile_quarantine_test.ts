import { assertEquals } from 'jsr:@std/assert';
import { makeMemRest } from './helpers.ts';
import { reconcileObjects } from '../_shared/workers.ts';

// Verification quarantine parity (repair-attest 20261003205900): the edge-side
// reconcile scan must exclude quarantined manifests exactly like the worker's
// candidateSQL (verification_failure_code IS NULL), so a deterministically
// unverifiable object is never re-reconciled (re-HEADed / re-PATCHed / promoted)
// by the edge sweep after the worker has durably quarantined it.

const USER = '7f2c9a10-4b3e-4d8a-9c11-00000000f001';

Deno.test('reconcile skips verification-quarantined manifests (same predicate as VerificationLane.candidateSQL)', async () => {
  const rest = await makeMemRest();
  await rest.upsert('object_manifests', [
    {
      id: 'q1', user_id: USER, object_key: 'quarantined-key', status: 'ready',
      verification_failure_code: 'digest_mismatch',
      verification_failed_at: '2026-10-03T00:00:00Z', verification_attempts: 3,
    },
    {
      id: 'q2', user_id: USER, object_key: 'quarantined-pending-key', status: 'pending',
      verification_failure_code: 'missing_wire_digest',
      verification_failed_at: '2026-10-03T00:00:00Z', verification_attempts: 1,
    },
    { id: 'g1', user_id: USER, object_key: 'gone-key', status: 'ready' },
  ]);

  const report = await reconcileObjects({
    rest: rest as any,
    // Every HEAD misses, so a non-quarantined ready row is marked corrupt; a
    // quarantined row must never reach that decision path.
    objectStore: { head: async () => null } as any,
    userId: USER,
    listPrefix: async () => [],
  });

  const byId = Object.fromEntries([...rest.manifests.entries()].map(([id, r]: any) => [id, r]));
  // Quarantined rows: untouched (still ready/pending, code intact, never re-checked).
  assertEquals(byId.q1.status, 'ready');
  assertEquals(byId.q1.verification_failure_code, 'digest_mismatch');
  assertEquals(byId.q2.status, 'pending');
  assertEquals(byId.q2.verification_failure_code, 'missing_wire_digest');
  // Non-quarantined ready row is still reconciled as before.
  assertEquals(byId.g1.status, 'corrupt');
  assertEquals(report.ready_missing_object, 1);
  // Quarantined rows are never counted as missing objects.
  assertEquals(report.pending_missing_object, 0);
});

Deno.test('quarantined rows stay visible to the orphan census without being re-reconciled', async () => {
  const rest = await makeMemRest();
  await rest.upsert('object_manifests', [
    {
      id: 'q1', user_id: USER, object_key: 'v3/core/users/u/quarantined.json',
      status: 'ready', verification_failure_code: 'digest_mismatch',
    },
  ]);
  const report = await reconcileObjects({
    rest: rest as any,
    objectStore: { head: async () => null } as any,
    userId: USER,
    listPrefix: async () => ['v3/core/users/u/quarantined.json'],
  });
  // The object exists in B2 and its manifest is still indexed, so it is NOT an
  // orphan; the quarantine only stopped re-verification, not the census.
  assertEquals(report.orphan_objects, 0);
  assertEquals(report.ready_missing_object, 0);
  assertEquals(rest.manifests.get('q1').status, 'ready');
});
