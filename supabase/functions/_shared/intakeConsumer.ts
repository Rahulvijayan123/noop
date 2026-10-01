import type { SupabaseRest } from './rest.ts';
import type { S3Store } from './s3.ts';
import { reconcileObjectVerification } from './objectVerification.ts';
import { reconcileIntake } from './durability.ts';
import { reconcileProjections } from './projections.ts';
import { intakeAdmissionFromEnv, type IntakeAdmission } from './intakeAdmission.ts';
import { isRecoveryAuthorityError, recoveryPoll, recoveryPreflight } from './boundedRecovery.ts';

export const INTAKE_CONTRACT_VERSION = 2;
export const INTAKE_LANES = ['verification', 'projection', 'legacy'] as const;
export type IntakeLane = typeof INTAKE_LANES[number];
export type IntakeIdentity = { processId: string; instanceId: string; sourceRevision: string; admission: IntakeAdmission };

// A complete lane attempt, including all sequential object operations, must fit
// inside the unchanged 30-second canary observation limit.
export const INTAKE_ATTEMPT_BUDGET_MS = 20_000;
export const INTAKE_REPORT_BUDGET_MS = 5_000;

export function boundedIntakeClients(rest: SupabaseRest, raw: S3Store, signal: AbortSignal,
  settlementSignal?: () => AbortSignal) {
  // Only debt settlement and receipt readback may use the shared cleanup/report
  // budget after cancellation. Claims, raw I/O and all publication RPCs stay aborted.
  const settlementPaths = new Set(['rpc/noop_fail_projection_debt', 'rpc/noop_abandon_copy_intent',
    'rpc/noop_defer_object_verification', 'rpc/noop_finish_object_verification', 'rpc/noop_current_object_receipt',
    'rpc/noop_recovery_poll']);
  const request: SupabaseRest['request'] = (path, options) => {
    const recoveryCleanup = path === 'rpc/noop_recovery_intake_call' &&
      ['legacy_failure','noop_fail_projection_debt','noop_finish_object_verification','noop_abandon_copy_intent']
        .includes((options?.body as {p_operation?: string})?.p_operation ?? '');
    return rest.request(path, { ...options,
      signal: signal.aborted && (settlementPaths.has(path) || recoveryCleanup) && settlementSignal ? settlementSignal() : signal });
  };
  return {
    rest: { ...rest, request,
      rpc: (name: string, args: unknown) => request(`rpc/${name}`, { method: 'POST', body: args || {} }),
      select: async (table: string, query?: string) => {
        const rows = await request(table, { query: query || 'select=*' });
        return Array.isArray(rows) ? rows : [];
      },
    },
    raw: { ...raw,
      head: (key: string) => raw.head(key, signal),
      getObjectStream: (key: string) => raw.getObjectStream(key, signal),
      copyObject: (source: string, destination: string) => raw.copyObject(source, destination, signal),
    },
  };
}

export function validateIntakeEnvironment(env: Record<string, string | undefined>, packagedRevision: string) {
  const sourceRevision = env.INTAKE_WORKER_SOURCE_REVISION ?? '';
  const instanceId = env.INTAKE_WORKER_INSTANCE_ID ?? '';
  const project = env.INTAKE_EXPECTED_SUPABASE_PROJECT ?? '';
  if (!/^[0-9a-f]{40}$/.test(sourceRevision) || sourceRevision !== packagedRevision.trim() ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(instanceId) ||
      !/^[a-z0-9]{20}$/.test(project)) throw new Error('intake_identity_required');
  const url = new URL(env.SUPABASE_URL ?? '');
  if (url.protocol !== 'https:' || url.hostname !== `${project}.supabase.co` ||
      url.username || url.password || url.port || !['', '/'].includes(url.pathname) || url.search || url.hash ||
      !env.SUPABASE_SERVICE_ROLE_KEY) throw new Error('intake_project_binding_required');
  return { sourceRevision, instanceId, processId: crypto.randomUUID(), admission: intakeAdmissionFromEnv(env) };
}

/** No timer heartbeat: a lane records progress only after its real bounded queue call returns. */
export function createIntakeConsumer(rest: SupabaseRest, raw: S3Store, identity: IntakeIdentity) {
  // Copy and validate even programmatic callers; a mutable identity cannot widen the scope later.
  const admission = intakeAdmissionFromEnv({ INTAKE_ADMISSION_MODE: identity.admission?.mode,
    INTAKE_CANARY_OWNER_ID: identity.admission?.mode !== 'all-eligible' ? identity.admission.ownerId : undefined,
    INTAKE_CANARY_DEVICE_ID: identity.admission?.mode !== 'all-eligible' ? identity.admission.deviceId : undefined,
    ...(identity.admission?.mode === 'bounded-recovery' ? {INTAKE_RECOVERY_RUN_ID:identity.admission.runId,
      INTAKE_WORKER_IMAGE_DIGEST:identity.admission.imageDigest,INTAKE_RECOVERY_POLICY_HASH:identity.admission.policyHash,
      INTAKE_EXPECTED_SUPABASE_PROJECT:identity.admission.projectRef,INTAKE_EXPECTED_DATABASE_ID:identity.admission.databaseId} : {}) });
  async function preflight() {
    if (admission.mode === 'bounded-recovery') {
      await recoveryPreflight(rest,{...identity,admission}); return;
    }
    const contract = await rest.rpc('noop_intake_consumer_contract', {});
    if (contract?.contract_version !== INTAKE_CONTRACT_VERSION || contract.completion !== 'verified_indexed' ||
        contract.projection !== 'atomic_lifecycle_v1' ||
        JSON.stringify(contract.lanes) !== JSON.stringify(INTAKE_LANES) ||
        JSON.stringify(contract.admission_modes) !== JSON.stringify(['canary', 'all-eligible'])) throw new Error('intake_contract_mismatch');
    if (admission.mode === 'canary') await rest.rpc('noop_intake_canary_validate',
      { p_user: admission.ownerId, p_device: admission.deviceId });
  }
  async function poll(lane: IntakeLane) {
    let cleanup: AbortSignal | undefined;
    // One deadline, not five seconds per cleanup request. Together with the
    // operation budget this stays below the unchanged supervision threshold.
    const settlementSignal = () => cleanup ??= AbortSignal.timeout(INTAKE_REPORT_BUDGET_MS);
    const bounded = boundedIntakeClients(rest, raw, AbortSignal.timeout(INTAKE_ATTEMPT_BUDGET_MS), settlementSignal);
    if (admission.mode === 'bounded-recovery') return recoveryPoll(bounded.rest,bounded.raw,{...identity,admission},lane);
    let claimed: number, completed: number, failures: number;
    if (lane === 'verification') {
      const r = await reconcileObjectVerification(bounded.rest, bounded.raw, { limit: 1, admission });
      claimed = r.claimed; completed = r.verifiedIndexed; failures = r.retry + r.paused + r.leaseLost;
    } else if (lane === 'projection') {
      const r = await reconcileProjections(bounded.rest, bounded.raw, 1, admission);
      claimed = r.scanned; completed = r.settled; failures = r.deferred;
    } else {
      const r = await reconcileIntake(bounded.rest, bounded.raw, 1, admission);
      claimed = r.scanned; completed = r.verifiedIndexed; failures = r.deferred;
    }
    await rest.request('rpc/noop_intake_consumer_poll_v2', { method: 'POST', signal: settlementSignal(),
      body: { p_process: identity.processId, p_instance: identity.instanceId,
      p_source_revision: identity.sourceRevision, p_lane: lane, p_claimed: claimed, p_completed: completed, p_failures: failures,
      p_admission_mode: admission.mode, p_user_id: admission.mode === 'canary' ? admission.ownerId : null,
      p_device_id: admission.mode === 'canary' ? admission.deviceId : null } });
    return { lane, claimed, completed, failures };
  }
  return { preflight, poll };
}

/** Independent single-concurrency lanes keep storage verification separate from scalar projection. */
export async function runIntakeConsumer(consumer: ReturnType<typeof createIntakeConsumer>, {
  signal, once = false, sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)),
  report = (_event: { lane: IntakeLane; claimed?: number; completed?: number; failures?: number; error?: string }) => {},
}: { signal?: AbortSignal; once?: boolean; sleep?: (ms: number) => Promise<void>;
  report?: (event: { lane: IntakeLane; claimed?: number; completed?: number; failures?: number; error?: string }) => void } = {}) {
  await consumer.preflight();
  const stopped = new AbortController();
  await Promise.all(INTAKE_LANES.map(async (lane) => {
    do {
      if (signal?.aborted || stopped.signal.aborted) break;
      let progressed = false;
      try {
        const result = await consumer.poll(lane); report(result); progressed = result.completed > 0;
      } catch (error) {
        if (isRecoveryAuthorityError(error)) {
          stopped.abort(); report({ lane, error: 'intake_admission_scope_mismatch' }); throw error;
        }
        report({ lane, error: 'intake_lane_failed' });
        if (once) throw new Error('intake_lane_failed');
      }
      if (once || signal?.aborted || stopped.signal.aborted) break;
      await sleep(progressed ? 10 : 1000);
    } while (!signal?.aborted && !stopped.signal.aborted);
  }));
}
