import { RestAuthorityError, type SupabaseRest } from './rest.ts';
import { S3OperationError, type S3Store } from './s3.ts';
import { completeDurableObject } from './durability.ts';
import { commitArchivedBatch, readVerifiedArchive } from './projections.ts';
import { PushProtocolError } from './registry.ts';
import { IntakeAdmissionError, isIntakeAdmissionError, type IntakeAdmission } from './intakeAdmission.ts';

export function isRecoveryAuthorityError(error: unknown): boolean {
  return isIntakeAdmissionError(error) || error instanceof RestAuthorityError ||
    (error instanceof PushProtocolError && /^recovery_[a-z0-9_]+$/.test(error.code));
}

export type RecoveryIdentity = Readonly<{ runId: string; imageDigest: string; policyHash: string }>;
type WorkerIdentity = { processId: string; instanceId: string; sourceRevision: string;
  admission: Extract<IntakeAdmission, {mode: 'bounded-recovery'}> };

export async function recoveryPreflight(rest: SupabaseRest, identity: WorkerIdentity) {
  const a = identity.admission;
  const value = await rest.rpc('recovery_target_identity', {p_run:a.runId,p_user:a.ownerId,p_device:a.deviceId});
  if (value?.owner_id !== a.ownerId || value?.device_id !== a.deviceId || value?.policy_hash !== a.policyHash ||
      value?.algorithm_version !== 'frwhoop-server-1' || value?.database_id !== a.databaseId ||
      value?.project_ref !== a.projectRef || !(Date.parse(value?.expires_at) > Date.now())) throw new IntakeAdmissionError();
  return value;
}

/** The claim reserves all active capacity before COPY/GET; every durable mutation
 * goes through a single SQL transaction that also checks the recovery fence. */
export async function recoveryPoll(rest: SupabaseRest, raw: S3Store, identity: WorkerIdentity,
  lane: 'verification' | 'projection' | 'legacy') {
  const a = identity.admission;
  const started = performance.now();
  const job = await rest.rpc('noop_recovery_claim', {p_run:a.runId,p_process:identity.processId,
    p_instance:identity.instanceId,p_source_revision:identity.sourceRevision,p_image_digest:a.imageDigest,p_lane:lane});
  const report = {lane,claimed:0,completed:0,failures:0,claimMs:Math.round(performance.now()-started),attemptMs:0,
    stagesMs:{} as Record<string,number>};
  if (!job) {
    await rest.rpc('noop_recovery_poll',{p_run:a.runId,p_lane:lane,p_completed:0,p_failures:0});
    return report;
  }
  if (job.manifest?.user_id !== a.ownerId || job.manifest?.device_id !== a.deviceId ||
      !job.recoveryToken || !Number.isSafeInteger(job.reservedWireBytes) || !Number.isSafeInteger(job.reservedDecodedBytes)) {
    throw new IntakeAdmissionError();
  }
  report.claimed=1;
  const call = (operation: string, args: unknown) => rest.rpc('noop_recovery_intake_call', {
    p_run:a.runId,p_process:identity.processId,p_token:job.recoveryToken,p_operation:operation,p_args:args});
  const scopedRest: SupabaseRest = {...rest, rpc:call, request:(path, options) => {
    // Existing error handling may mark a legacy manifest failed. Recovery keeps
    // the original identity untouched and records durable per-object retry debt.
    if (path.startsWith('object_manifests?') && options?.method === 'PATCH') return Promise.resolve(null);
    return rest.request(path, options);
  }};
  const scoped = {mode:'canary',ownerId:a.ownerId,deviceId:a.deviceId} as const;
  const manifest = {...job.manifest,recovery_max_decoded_bytes:job.reservedDecodedBytes,recovery_max_wire_bytes:job.reservedWireBytes};
  let failure: unknown;
  try {
    if (lane === 'projection') {
      const readStarted=performance.now();
      const bytes = await readVerifiedArchive(raw, manifest);
      report.stagesMs.download_verify=Math.round(performance.now()-readStarted);
      if (bytes.length > job.reservedDecodedBytes) throw new PushProtocolError('recovery_size_limit',413);
      const projectionStarted=performance.now();
      const ack = await commitArchivedBatch(scopedRest,manifest.durability_receipt,bytes,job.leaseToken,scoped);
      report.stagesMs.projection=Math.round(performance.now()-projectionStarted);
      report.completed=ack.recoveryProjectionComplete === true ? 1 : 0;
    } else {
      await completeDurableObject({rest:scopedRest,raw,row:manifest,
        verificationToken:lane === 'verification' ? job.token : undefined,admission:scoped,
        onStage:(stage,milliseconds)=>{report.stagesMs[stage]=milliseconds;}});
      if (lane === 'verification') await call('noop_finish_object_verification', {p_object_id:manifest.id,
        p_failure_code:null,p_failure_status:503,p_retryable:true,p_verification_ms:Math.round(performance.now()-started)});
      report.completed=1;
    }
  } catch (error) {
    failure=error;
    // Failed observation, authorization or fencing is a process stop, not an
    // ordinary object failure. Its reservation remains charged for supervision.
    if (isRecoveryAuthorityError(error)) throw error;
    if ((error instanceof PushProtocolError || error instanceof S3OperationError) && [401,403].includes(error.status)) throw new IntakeAdmissionError();
    const code = error instanceof PushProtocolError ? error.code : 'object_io_failed';
    const status = error instanceof PushProtocolError ? error.status : 503;
    const retryable = status === 408 || status === 429 || status >= 500;
    if (lane === 'verification') await call('noop_finish_object_verification', {p_object_id:manifest.id,
      p_failure_code:code,p_failure_status:status,p_retryable:retryable,p_verification_ms:Math.round(performance.now()-started)});
    else if (lane === 'projection') await call('noop_fail_projection_debt',{p_object_id:manifest.id});
    else await call('legacy_failure',{reason:code,retryable});
    report.failures=1;
  }
  report.attemptMs=Math.round(performance.now()-started);
  // An object failure is accounted separately; a successful poll remains healthy.
  await rest.rpc('noop_recovery_poll',{p_run:a.runId,p_lane:lane,p_completed:report.completed,p_failures:failure ? 1 : 0});
  return report;
}
