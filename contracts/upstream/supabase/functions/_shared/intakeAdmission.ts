/** Admission limits worker claims; incoming raw durability remains independent. */
export type IntakeAdmission = Readonly<{ mode: 'all-eligible' } |
  { mode: 'canary'; ownerId: string; deviceId: string } |
  { mode: 'bounded-recovery'; ownerId: string; deviceId: string; runId: string;
    imageDigest: string; policyHash: string; projectRef: string; databaseId: string }>;

export class IntakeAdmissionError extends Error {
  constructor() { super('intake_admission_scope_mismatch'); }
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

export function intakeAdmissionFromEnv(env: Record<string, string | undefined>): IntakeAdmission {
  const mode = env.INTAKE_ADMISSION_MODE;
  const ownerId = env.INTAKE_CANARY_OWNER_ID, deviceId = env.INTAKE_CANARY_DEVICE_ID;
  if (mode === 'all-eligible' && !ownerId && !deviceId) return Object.freeze({ mode });
  if (mode === 'canary' && ownerId && deviceId && uuid.test(ownerId) && uuid.test(deviceId)) {
    return Object.freeze({ mode, ownerId, deviceId });
  }
  if (mode === 'bounded-recovery' && ownerId && deviceId && uuid.test(ownerId) && uuid.test(deviceId) &&
      uuid.test(env.INTAKE_RECOVERY_RUN_ID ?? '') && /^sha256:[0-9a-f]{64}$/.test(env.INTAKE_WORKER_IMAGE_DIGEST ?? '') &&
      /^[0-9a-f]{64}$/.test(env.INTAKE_RECOVERY_POLICY_HASH ?? '') && /^[a-z0-9]{20}$/.test(env.INTAKE_EXPECTED_SUPABASE_PROJECT ?? '') &&
      uuid.test(env.INTAKE_EXPECTED_DATABASE_ID ?? '')) {
    return Object.freeze({mode,ownerId,deviceId,runId:env.INTAKE_RECOVERY_RUN_ID!,imageDigest:env.INTAKE_WORKER_IMAGE_DIGEST!,
      policyHash:env.INTAKE_RECOVERY_POLICY_HASH!,projectRef:env.INTAKE_EXPECTED_SUPABASE_PROJECT!,databaseId:env.INTAKE_EXPECTED_DATABASE_ID!});
  }
  throw new IntakeAdmissionError();
}

export function intakeAdmissionArguments(admission?: IntakeAdmission): Record<string, string> {
  return admission?.mode === 'canary' ? { p_user_id: admission.ownerId, p_device_id: admission.deviceId } : {};
}

/** Check before object I/O, retry settlement or any other mutation of the returned work. */
export function assertIntakeScope(row: unknown, admission?: IntakeAdmission): void {
  if (!admission || admission.mode === 'all-eligible') return;
  const value = row as { user_id?: unknown; device_id?: unknown } | null;
  if (value?.user_id !== admission.ownerId || value?.device_id !== admission.deviceId) throw new IntakeAdmissionError();
}

export function isIntakeAdmissionError(error: unknown): boolean {
  return error instanceof IntakeAdmissionError ||
    (error as {receiverCode?: string})?.receiverCode === 'intake_admission_scope_mismatch';
}
