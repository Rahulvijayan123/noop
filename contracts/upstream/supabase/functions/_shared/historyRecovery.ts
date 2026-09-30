import { isUuid } from './keys.ts';
import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import { verifyStoredObject } from './durability.ts';
import { boundedIntakeClients, INTAKE_ATTEMPT_BUDGET_MS } from './intakeConsumer.ts';

export type HistoryScope = { project: string; userId: string; deviceId: string; sourceRevision: string };
export type HistoryCheckpoint = { schemaVersion: 1; scope: HistoryScope; startedAt: string; cursor: string | null; complete: boolean; pages: number };

export function historyCheckpoint(scope: HistoryScope, prior?: HistoryCheckpoint): HistoryCheckpoint {
  if (!/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(scope.project) || !isUuid(scope.userId) ||
      !isUuid(scope.deviceId) || !/^[a-f0-9]{40}$/.test(scope.sourceRevision)) throw Error('history_scope_invalid');
  if (prior) {
    if (prior.schemaVersion !== 1 || Object.keys(scope).some(k => scope[k as keyof HistoryScope] !== prior.scope?.[k as keyof HistoryScope]) ||
        (prior.cursor !== null && !isUuid(prior.cursor)) || typeof prior.complete !== 'boolean' ||
        !Number.isSafeInteger(prior.pages) || prior.pages < 0 || !Number.isFinite(Date.parse(prior.startedAt))) throw Error('history_checkpoint_scope_mismatch');
    return prior;
  }
  return { schemaVersion: 1, scope: { ...scope }, startedAt: new Date().toISOString(), cursor: null, complete: false, pages: 0 };
}

/** Returns an immutable inventory page; caller persists it before its continuation. */
export async function recoverHistoryPage(rest: SupabaseRest, raw: S3Store | null,
  checkpoint: HistoryCheckpoint, { limit = 32, verifyRaw = false, requeue = false } = {}) {
  historyCheckpoint(checkpoint.scope, checkpoint);
  if (checkpoint.complete) throw Error('history_sweep_already_complete');
  if (!Number.isInteger(limit) || limit < 1 || limit > 64) throw Error('invalid_history_limit');
  if (verifyRaw && !raw) throw Error('history_storage_identity_required');
  const { userId, deviceId } = checkpoint.scope;
  const page = await rest.rpc('noop_history_inventory_page', { p_user: userId, p_device: deviceId,
    p_after: checkpoint.cursor, p_limit: limit, p_before: checkpoint.startedAt });
  if (page?.schema_version !== 1 || page.user_id !== userId || page.device_id !== deviceId ||
      !Array.isArray(page.items) || page.items.length > limit || typeof page.scan_complete !== 'boolean' ||
      Date.parse(page.inventory_cutoff) !== Date.parse(checkpoint.startedAt) ||
      (!page.scan_complete && (!isUuid(page.next_cursor) || page.next_cursor === checkpoint.cursor))) {
    throw Error('history_page_identity_mismatch');
  }
  // Validate the entire returned page before any storage reads or queue writes.
  let previous = checkpoint.cursor;
  for (const item of page.items) {
    const m = item.object;
    if (!isUuid(m?.id) || m.user_id !== userId || m.device_id !== deviceId ||
        (previous && m.id <= previous)) throw Error('history_object_identity_mismatch');
    previous = m.id;
  }
  if (!page.scan_complete && previous !== page.next_cursor) throw Error('history_cursor_mismatch');
  for (const item of page.items) {
    const m = item.object;
    const receipt = m.durability_receipt;
    item.raw_readability = 'NOT_MEASURED';
    item.derived_archive_readability = 'NOT_MEASURED';
    if (verifyRaw && receipt?.state === 'verified_indexed') {
      if (receipt.ownerUserId !== userId || receipt.deviceId !== deviceId || receipt.objectId !== m.id ||
          receipt.objectKey !== m.object_key || !isUuid(receipt.receiptId)) throw Error('history_receipt_identity_mismatch');
      let operation = 'HEAD';
      try {
        const bounded = boundedIntakeClients(rest, raw!, AbortSignal.timeout(INTAKE_ATTEMPT_BUDGET_MS));
        const head = await bounded.raw.head(receipt.objectKey);
        if (!head?.exists || head.contentLength !== receipt.compressedBytes) throw Error('history_object_unreadable');
        operation = 'GET_HASH';
        const verified = await verifyStoredObject(bounded.raw, m, receipt.objectKey);
        if (head.versionId && verified.storageVersionId !== head.versionId) {
          throw Error('history_object_version_changed');
        }
        if (verified.wireSha256 !== receipt.wireSha256 || verified.contentSha256 !== receipt.contentSha256 ||
            verified.compressedBytes !== receipt.compressedBytes || verified.uncompressedBytes !== receipt.uncompressedBytes) {
          throw Error('history_object_digest_mismatch');
        }
        item.raw_readability = 'PASS';
        item.raw_readback = { objectKey: receipt.objectKey, versionId: verified.storageVersionId ?? null,
          version_status: verified.storageVersionId ? 'VERIFIED_GET_VERSION' : 'NOT_MEASURED',
          receiptId: receipt.receiptId, ...verified };
      } catch {
        item.raw_readability = 'FAIL';
        item.first_failed_operation = operation;
      }
    }
    if (requeue && item.raw_readability === 'PASS' && item.affected_days?.some((d: any) => d.state === 'projected_not_queued')) {
      item.replay = await rest.rpc('noop_history_requeue_object', { p_user: userId, p_device: deviceId,
        p_object: m.id, p_receipt: receipt.receiptId });
    }
  }
  return { page, checkpoint: { ...checkpoint, cursor: page.next_cursor ?? null,
    complete: page.scan_complete, pages: checkpoint.pages + 1 } satisfies HistoryCheckpoint };
}
