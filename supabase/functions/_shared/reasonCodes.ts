// The canonical reasons a reading is missing, unreliable or not comparable (contracts/reason-codes.json,
// data-reason-1). Every layer mirrors that file: Swift DataReason.swift, SQL public.reason_codes /
// public.reason_code_legacy (20261009130000_reason_codes.sql) and this table. tests/reason_codes_parity_test.ts
// fails when this table or the SQL seed drifts from the JSON; edit the JSON first, then all three.

export const REASON_CODES_VERSION = 'data-reason-1';

export type ReasonCertainty = 'confirmed' | 'inferred' | 'unknown' | 'measured';
export type ReasonEffect = 'excluded' | 'degraded' | 'withheld' | 'not_comparable' | 'display_only';

export interface ReasonCode {
  code: string;
  family: string;
  default_certainty: ReasonCertainty;
  effect: ReasonEffect;
  subcodes?: readonly string[];
}

/** One reason on a stored row or a response: the canonical code and how sure we are of the cause. */
export interface DataReason {
  code: string;
  certainty: ReasonCertainty;
  subcode?: string;
}

export const REASON_CODES: readonly ReasonCode[] = [
  { code: 'off_wrist', family: 'wear', default_certainty: 'inferred', effect: 'excluded' },
  { code: 'strap_not_recording', family: 'link', default_certainty: 'inferred', effect: 'excluded' },
  { code: 'charging', family: 'wear', default_certainty: 'confirmed', effect: 'excluded' },
  { code: 'just_put_on', family: 'wear', default_certainty: 'confirmed', effect: 'degraded' },
  { code: 'held_value_at_off', family: 'wear', default_certainty: 'confirmed', effect: 'excluded' },
  { code: 'loose_fit', family: 'contact', default_certainty: 'inferred', effect: 'degraded' },
  { code: 'sensor_dropout', family: 'contact', default_certainty: 'inferred', effect: 'excluded' },
  { code: 'motion_artifact', family: 'motion', default_certainty: 'inferred', effect: 'degraded' },
  { code: 'hr_in_motion_unverified', family: 'motion', default_certainty: 'inferred', effect: 'degraded' },
  { code: 'optical_saturation', family: 'quality', default_certainty: 'confirmed', effect: 'excluded' },
  { code: 'strap_link_down', family: 'link', default_certainty: 'confirmed', effect: 'display_only' },
  { code: 'strap_reset', family: 'link', default_certainty: 'confirmed', effect: 'degraded' },
  { code: 'app_not_running', family: 'pipeline', default_certainty: 'unknown', effect: 'display_only' },
  { code: 'awaiting_offload', family: 'pipeline', default_certainty: 'confirmed', effect: 'withheld' },
  { code: 'awaiting_upload', family: 'pipeline', default_certainty: 'inferred', effect: 'withheld' },
  { code: 'awaiting_processing', family: 'pipeline', default_certainty: 'confirmed', effect: 'withheld' },
  { code: 'data_lost', family: 'pipeline', default_certainty: 'confirmed', effect: 'excluded' },
  { code: 'no_verified_input', family: 'pipeline', default_certainty: 'confirmed', effect: 'withheld' },
  { code: 'stale', family: 'pipeline', default_certainty: 'confirmed', effect: 'display_only' },
  { code: 'insufficient_coverage', family: 'coverage', default_certainty: 'measured', effect: 'withheld' },
  { code: 'artifact_rejected', family: 'quality', default_certainty: 'inferred', effect: 'degraded' },
  { code: 'implausible_value', family: 'quality', default_certainty: 'inferred', effect: 'excluded' },
  { code: 'clock_unverified', family: 'clock', default_certainty: 'inferred', effect: 'withheld' },
  { code: 'context_not_comparable', family: 'context', default_certainty: 'inferred', effect: 'not_comparable',
    subcodes: ['movement', 'recent_exercise', 'in_session', 'recovery', 'transition', 'not_steady_state'] },
  { code: 'context_unknown', family: 'context', default_certainty: 'unknown', effect: 'not_comparable' },
  { code: 'placement_unknown', family: 'placement', default_certainty: 'unknown', effect: 'not_comparable' },
  { code: 'placement_unsupported', family: 'placement', default_certainty: 'confirmed', effect: 'not_comparable' },
  { code: 'learning', family: 'model', default_certainty: 'measured', effect: 'withheld' },
  { code: 'model_unavailable', family: 'model', default_certainty: 'confirmed', effect: 'withheld' },
  { code: 'user_confounder', family: 'user', default_certainty: 'confirmed', effect: 'display_only' },
];

/** Legacy vocabularies (the names each layer used before data-reason-1) mapped to canonical reasons. */
export const LEGACY_REASONS: Readonly<Record<string, Readonly<Record<string, DataReason>>>> = {
  watchdog_quality: {
    wrist_off_event: { code: 'off_wrist', certainty: 'confirmed' },
    optical_baseline_zero: { code: 'off_wrist', certainty: 'inferred' },
    charging: { code: 'charging', certainty: 'confirmed' },
    strap_reset_unrecovered: { code: 'strap_reset', certainty: 'confirmed' },
    hr_absent: { code: 'sensor_dropout', certainty: 'inferred' },
    skin_temp_unconfirmed: { code: 'context_unknown', certainty: 'unknown' },
    rr_pileup: { code: 'artifact_rejected', certainty: 'inferred' },
    optical_saturation: { code: 'optical_saturation', certainty: 'confirmed' },
    contact_not_detected: { code: 'loose_fit', certainty: 'inferred' },
    optical_sentinel: { code: 'motion_artifact', certainty: 'inferred' },
    motion_mode_optics: { code: 'motion_artifact', certainty: 'inferred' },
    beat_coverage_low: { code: 'insufficient_coverage', certainty: 'measured' },
    beat_overcount: { code: 'artifact_rejected', certainty: 'inferred' },
    hr_in_motion_unverified: { code: 'hr_in_motion_unverified', certainty: 'inferred' },
    optical_sentinel_at_rest: { code: 'loose_fit', certainty: 'inferred' },
    optical_baseline_high: { code: 'loose_fit', certainty: 'inferred' },
    strap_not_recording: { code: 'strap_not_recording', certainty: 'confirmed' },
    transport_gap: { code: 'awaiting_upload', certainty: 'inferred' },
    settling_after_wrist_on: { code: 'just_put_on', certainty: 'confirmed' },
    no_signal_metadata: { code: 'context_unknown', certainty: 'unknown' },
    no_motion_sample: { code: 'context_unknown', certainty: 'unknown' },
  },
  watchdog_unavailable: {
    wristOff: { code: 'off_wrist', certainty: 'confirmed' },
    coverage: { code: 'insufficient_coverage', certainty: 'measured' },
    gap: { code: 'insufficient_coverage', certainty: 'measured' },
    stale: { code: 'stale', certainty: 'confirmed' },
    empty: { code: 'insufficient_coverage', certainty: 'measured' },
  },
  anomaly_withheld: {
    off_wrist: { code: 'off_wrist', certainty: 'inferred' },
    low_hr_coverage: { code: 'insufficient_coverage', certainty: 'measured' },
    activity: { code: 'context_not_comparable', certainty: 'inferred', subcode: 'movement' },
    recovery: { code: 'context_not_comparable', certainty: 'inferred', subcode: 'recovery' },
    context_unknown: { code: 'context_unknown', certainty: 'unknown' },
    calibrating: { code: 'learning', certainty: 'measured' },
  },
  sensor_biomarker: {
    insufficient_coverage: { code: 'insufficient_coverage', certainty: 'measured' },
    unknown_wrist_placement: { code: 'placement_unknown', certainty: 'unknown' },
    unverified_sample_clock: { code: 'clock_unverified', certainty: 'inferred' },
    unverified_optical_dc: { code: 'no_verified_input', certainty: 'confirmed' },
    no_verified_input: { code: 'no_verified_input', certainty: 'confirmed' },
    model_unavailable: { code: 'model_unavailable', certainty: 'confirmed' },
    adapter_broken: { code: 'model_unavailable', certainty: 'confirmed' },
    artifact_unavailable: { code: 'no_verified_input', certainty: 'unknown' },
  },
  layer1: {
    low_coverage: { code: 'insufficient_coverage', certainty: 'measured' },
    out_of_range: { code: 'implausible_value', certainty: 'inferred' },
    poor_signal: { code: 'artifact_rejected', certainty: 'inferred' },
    charging: { code: 'charging', certainty: 'confirmed' },
    device_off: { code: 'strap_not_recording', certainty: 'inferred' },
    app_fail: { code: 'app_not_running', certainty: 'unknown' },
    stale: { code: 'stale', certainty: 'confirmed' },
  },
};

const BY_CODE: ReadonlyMap<string, ReasonCode> = new Map(REASON_CODES.map((c) => [c.code, c]));

export function reasonCode(code: string): ReasonCode | null {
  return BY_CODE.get(code) ?? null;
}

/**
 * The canonical reason for a legacy value of `vocabulary` (e.g. `watchdog_quality` / `motion_mode_optics` →
 * `{code: 'motion_artifact', certainty: 'inferred'}`). A value that is already canonical maps to itself at its
 * default certainty. Anything else is null: the caller keeps the raw value rather than guessing a cause.
 */
export function canonicalize(vocabulary: string, legacyCode: string): DataReason | null {
  const mapped = Object.hasOwn(LEGACY_REASONS, vocabulary) && Object.hasOwn(LEGACY_REASONS[vocabulary], legacyCode)
    ? LEGACY_REASONS[vocabulary][legacyCode] : null;
  if (mapped) return { ...mapped };
  const own = BY_CODE.get(legacyCode);
  return own ? { code: own.code, certainty: own.default_certainty } : null;
}
