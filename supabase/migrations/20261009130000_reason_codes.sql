-- Canonical data reason codes: the registry every server writer and reader shares.
--
-- WHY
-- A reading can be missing, unreliable or not comparable for ~30 distinct causes, and until now each layer named
-- them its own way (Watchdog quality flags, the anomaly service's withheld values, sensor-biomarker withheld
-- reasons, Layer 1 quality reasons), with the certainty of the cause lost on the way (an inferred >60 s gap read
-- as "the strap disconnected"). contracts/reason-codes.json (version data-reason-1) is the one vocabulary: code,
-- family, default certainty (confirmed | inferred | unknown | measured), effect (excluded | degraded | withheld |
-- not_comparable | display_only) and the legacy maps. Swift (DataReason.swift), the edge (_shared/reasonCodes.ts)
-- and this table mirror it; tests/reason_codes_parity_test.ts fails when any of them drifts from the JSON.
--
-- WHAT CHANGES
--   public.reason_codes        one row per canonical code (seeded exactly from the JSON).
--   public.reason_code_legacy  (vocabulary, legacy_code) -> canonical code, subcode and certainty.
--   internal.canonical_reason(vocabulary, legacy_code)  the mapping as {code, certainty[, subcode]} jsonb, or
--                              NULL for a code the vocabulary does not list (callers keep the raw value).
-- Both tables are service-only reference data (RLS on, no client policy): readers get canonical reasons from the
-- routes that already carry them. The seed is an upsert, so a re-run (or a later data-reason version that edits a
-- row) converges on the JSON; nothing else writes these tables.
--
-- Safe to re-run. Rollback: drop function internal.canonical_reason(text, text); drop table
-- public.reason_code_legacy; drop table public.reason_codes. Nothing else depends on them except the
-- measurement-context functions of 20261009130100 (which read them at run time).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.reason_codes (
  code              text primary key check (code ~ '^[a-z][a-z_]{0,63}$'),
  family            text not null check (family in ('wear', 'contact', 'motion', 'link', 'pipeline', 'coverage',
                                                    'quality', 'clock', 'context', 'placement', 'model', 'user')),
  default_certainty text not null check (default_certainty in ('confirmed', 'inferred', 'unknown', 'measured')),
  effect            text not null check (effect in ('excluded', 'degraded', 'withheld', 'not_comparable',
                                                    'display_only')),
  description       text not null,
  confirmed_when    text,
  subcodes          text[] not null default '{}',
  version           text not null default 'data-reason-1'
);
comment on table public.reason_codes is
  'Canonical data reason codes (contracts/reason-codes.json). A reason on a stored row is {code, certainty[, '
  'subcode]}; certainty defaults to default_certainty unless the writer has better evidence (confirmed_when).';

create table if not exists public.reason_code_legacy (
  vocabulary  text not null check (vocabulary ~ '^[a-z][a-z0-9_]{0,63}$'),
  legacy_code text not null check (legacy_code ~ '^[A-Za-z][A-Za-z0-9_]{0,63}$'),
  code        text not null references public.reason_codes(code),
  subcode     text,
  certainty   text not null check (certainty in ('confirmed', 'inferred', 'unknown', 'measured')),
  primary key (vocabulary, legacy_code)
);
comment on table public.reason_code_legacy is
  'Legacy reason vocabularies (watchdog_quality, watchdog_unavailable, anomaly_withheld, sensor_biomarker, layer1) '
  'mapped to canonical codes with the certainty the legacy value carries.';

alter table public.reason_codes enable row level security;
alter table public.reason_code_legacy enable row level security;
revoke all on public.reason_codes, public.reason_code_legacy from public, anon, authenticated;
grant all on public.reason_codes, public.reason_code_legacy to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'reason_codes'
                    and policyname = 'reason_codes_service') then
    create policy reason_codes_service on public.reason_codes for all to service_role using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'reason_code_legacy'
                    and policyname = 'reason_code_legacy_service') then
    create policy reason_code_legacy_service on public.reason_code_legacy for all to service_role
      using (true) with check (true);
  end if;
end $$;

-- Seed: contracts/reason-codes.json `codes` (data-reason-1), in file order.
insert into public.reason_codes as r (code, family, default_certainty, effect, description, confirmed_when, subcodes)
values
  ('off_wrist', 'wear', 'inferred', 'excluded',
   'The strap was not on the body.',
   'a WRIST_OFF event (until the next WRIST_ON), a durable off state or a user note says so', '{}'::text[]),
  ('strap_not_recording', 'link', 'inferred', 'excluded',
   'The strap stored no records for this time.',
   'the strap''s record index steps by one across the gap (it paused recording) or the battery was dead', '{}'::text[]),
  ('charging', 'wear', 'confirmed', 'excluded',
   'The strap was charging.',
   null, '{}'::text[]),
  ('just_put_on', 'wear', 'confirmed', 'degraded',
   'Settling after the strap was put on (skin temperature and beat timing are not yet stable).',
   null, '{}'::text[]),
  ('held_value_at_off', 'wear', 'confirmed', 'excluded',
   'A repeated last value emitted in the seconds after the strap came off.',
   null, '{}'::text[]),
  ('loose_fit', 'contact', 'inferred', 'degraded',
   'Optical contact looked poor. Not validated against a reference; never shown as a fact.',
   'the user says the strap was loose', '{}'::text[]),
  ('sensor_dropout', 'contact', 'inferred', 'excluded',
   'Heart rate was absent while the strap was believed worn.',
   null, '{}'::text[]),
  ('motion_artifact', 'motion', 'inferred', 'degraded',
   'Movement made beat timing (R-R, HRV, beat-derived respiration) unusable; the bpm stream may still be usable.',
   null, '{}'::text[]),
  ('hr_in_motion_unverified', 'motion', 'inferred', 'degraded',
   'Heart rate during movement: continuous, but its accuracy is not verified against a reference.',
   null, '{}'::text[]),
  ('optical_saturation', 'quality', 'confirmed', 'excluded',
   'The strap reported optical or accelerometer saturation or an analog front-end reset.',
   null, '{}'::text[]),
  ('strap_link_down', 'link', 'confirmed', 'display_only',
   'The phone and strap were disconnected; the strap banks data and it is expected to arrive later.',
   null, '{}'::text[]),
  ('strap_reset', 'link', 'confirmed', 'degraded',
   'The strap rebooted or lost its clock; wear state is unknown until heart rate recovers.',
   null, '{}'::text[]),
  ('app_not_running', 'pipeline', 'unknown', 'display_only',
   'The app was not running, so nothing was collected live.',
   'the app lifecycle log shows it was terminated', '{}'::text[]),
  ('awaiting_offload', 'pipeline', 'confirmed', 'withheld',
   'The data is still on the strap.',
   null, '{}'::text[]),
  ('awaiting_upload', 'pipeline', 'inferred', 'withheld',
   'The data is on the phone and not uploaded yet.',
   'the phone holds the rows unsent', '{}'::text[]),
  ('awaiting_processing', 'pipeline', 'confirmed', 'withheld',
   'The data arrived and is waiting to be processed.',
   null, '{}'::text[]),
  ('data_lost', 'pipeline', 'confirmed', 'excluded',
   'The data is known to be unrecoverable.',
   null, '{}'::text[]),
  ('no_verified_input', 'pipeline', 'confirmed', 'withheld',
   'No verified input reached this calculation.',
   null, '{}'::text[]),
  ('stale', 'pipeline', 'confirmed', 'display_only',
   'The newest data is older than this view needs (not recent).',
   null, '{}'::text[]),
  ('insufficient_coverage', 'coverage', 'measured', 'withheld',
   'Too few samples in the window.',
   null, '{}'::text[]),
  ('artifact_rejected', 'quality', 'inferred', 'degraded',
   'Too many readings were rejected as artifacts.',
   null, '{}'::text[]),
  ('implausible_value', 'quality', 'inferred', 'excluded',
   'A value outside the physiological range or a flat line.',
   null, '{}'::text[]),
  ('clock_unverified', 'clock', 'inferred', 'withheld',
   'Sample timing could not be verified.',
   null, '{}'::text[]),
  ('context_not_comparable', 'context', 'inferred', 'not_comparable',
   'The reading''s context differs from the reference''s (it is compared with a matching reference, or none).',
   null, array['movement', 'recent_exercise', 'in_session', 'recovery', 'transition', 'not_steady_state']::text[]),
  ('context_unknown', 'context', 'unknown', 'not_comparable',
   'The context of the reading is not known.',
   null, '{}'::text[]),
  ('placement_unknown', 'placement', 'unknown', 'not_comparable',
   'Where the strap is worn is not known.',
   null, '{}'::text[]),
  ('placement_unsupported', 'placement', 'confirmed', 'not_comparable',
   'The declared placement is not one this calculation supports (e.g. upper arm for a wrist-trained model).',
   null, '{}'::text[]),
  ('learning', 'model', 'measured', 'withheld',
   'A personal reference or model is still collecting enough history.',
   null, '{}'::text[]),
  ('model_unavailable', 'model', 'confirmed', 'withheld',
   'The model or runtime is not available.',
   null, '{}'::text[]),
  ('user_confounder', 'user', 'confirmed', 'display_only',
   'The user logged something that explains this (exercise, alcohol, illness, travel...).',
   null, '{}'::text[])

on conflict (code) do update set family = excluded.family, default_certainty = excluded.default_certainty,
  effect = excluded.effect, description = excluded.description, confirmed_when = excluded.confirmed_when,
  subcodes = excluded.subcodes, version = excluded.version
where (r.family, r.default_certainty, r.effect, r.description, r.confirmed_when, r.subcodes, r.version)
  is distinct from (excluded.family, excluded.default_certainty, excluded.effect, excluded.description,
                    excluded.confirmed_when, excluded.subcodes, excluded.version);

-- Seed: contracts/reason-codes.json `legacy`, vocabulary by vocabulary.
insert into public.reason_code_legacy as l (vocabulary, legacy_code, code, subcode, certainty)
values
  ('watchdog_quality', 'wrist_off_event', 'off_wrist', null, 'confirmed'),
  ('watchdog_quality', 'optical_baseline_zero', 'off_wrist', null, 'inferred'),
  ('watchdog_quality', 'charging', 'charging', null, 'confirmed'),
  ('watchdog_quality', 'strap_reset_unrecovered', 'strap_reset', null, 'confirmed'),
  ('watchdog_quality', 'hr_absent', 'sensor_dropout', null, 'inferred'),
  ('watchdog_quality', 'skin_temp_unconfirmed', 'context_unknown', null, 'unknown'),
  ('watchdog_quality', 'rr_pileup', 'artifact_rejected', null, 'inferred'),
  ('watchdog_quality', 'optical_saturation', 'optical_saturation', null, 'confirmed'),
  ('watchdog_quality', 'contact_not_detected', 'loose_fit', null, 'inferred'),
  ('watchdog_quality', 'optical_sentinel', 'motion_artifact', null, 'inferred'),
  ('watchdog_quality', 'motion_mode_optics', 'motion_artifact', null, 'inferred'),
  ('watchdog_quality', 'beat_coverage_low', 'insufficient_coverage', null, 'measured'),
  ('watchdog_quality', 'beat_overcount', 'artifact_rejected', null, 'inferred'),
  ('watchdog_quality', 'hr_in_motion_unverified', 'hr_in_motion_unverified', null, 'inferred'),
  ('watchdog_quality', 'optical_sentinel_at_rest', 'loose_fit', null, 'inferred'),
  ('watchdog_quality', 'optical_baseline_high', 'loose_fit', null, 'inferred'),
  ('watchdog_quality', 'strap_not_recording', 'strap_not_recording', null, 'confirmed'),
  ('watchdog_quality', 'transport_gap', 'awaiting_upload', null, 'inferred'),
  ('watchdog_quality', 'settling_after_wrist_on', 'just_put_on', null, 'confirmed'),
  ('watchdog_quality', 'no_signal_metadata', 'context_unknown', null, 'unknown'),
  ('watchdog_quality', 'no_motion_sample', 'context_unknown', null, 'unknown'),
  ('watchdog_unavailable', 'wristOff', 'off_wrist', null, 'confirmed'),
  ('watchdog_unavailable', 'coverage', 'insufficient_coverage', null, 'measured'),
  ('watchdog_unavailable', 'gap', 'insufficient_coverage', null, 'measured'),
  ('watchdog_unavailable', 'stale', 'stale', null, 'confirmed'),
  ('watchdog_unavailable', 'empty', 'insufficient_coverage', null, 'measured'),
  ('anomaly_withheld', 'off_wrist', 'off_wrist', null, 'inferred'),
  ('anomaly_withheld', 'low_hr_coverage', 'insufficient_coverage', null, 'measured'),
  ('anomaly_withheld', 'activity', 'context_not_comparable', 'movement', 'inferred'),
  ('anomaly_withheld', 'recovery', 'context_not_comparable', 'recovery', 'inferred'),
  ('anomaly_withheld', 'context_unknown', 'context_unknown', null, 'unknown'),
  ('anomaly_withheld', 'calibrating', 'learning', null, 'measured'),
  ('sensor_biomarker', 'insufficient_coverage', 'insufficient_coverage', null, 'measured'),
  ('sensor_biomarker', 'unknown_wrist_placement', 'placement_unknown', null, 'unknown'),
  ('sensor_biomarker', 'unverified_sample_clock', 'clock_unverified', null, 'inferred'),
  ('sensor_biomarker', 'unverified_optical_dc', 'no_verified_input', null, 'confirmed'),
  ('sensor_biomarker', 'no_verified_input', 'no_verified_input', null, 'confirmed'),
  ('sensor_biomarker', 'model_unavailable', 'model_unavailable', null, 'confirmed'),
  ('sensor_biomarker', 'adapter_broken', 'model_unavailable', null, 'confirmed'),
  ('sensor_biomarker', 'artifact_unavailable', 'no_verified_input', null, 'unknown'),
  ('layer1', 'low_coverage', 'insufficient_coverage', null, 'measured'),
  ('layer1', 'out_of_range', 'implausible_value', null, 'inferred'),
  ('layer1', 'poor_signal', 'artifact_rejected', null, 'inferred'),
  ('layer1', 'charging', 'charging', null, 'confirmed'),
  ('layer1', 'device_off', 'strap_not_recording', null, 'inferred'),
  ('layer1', 'app_fail', 'app_not_running', null, 'unknown'),
  ('layer1', 'stale', 'stale', null, 'confirmed')

on conflict (vocabulary, legacy_code) do update set code = excluded.code, subcode = excluded.subcode,
  certainty = excluded.certainty
where (l.code, l.subcode, l.certainty) is distinct from (excluded.code, excluded.subcode, excluded.certainty);

-- {code, certainty[, subcode]} for a legacy value, NULL when the vocabulary does not list it.
create or replace function internal.canonical_reason(p_vocabulary text, p_legacy_code text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object('code', l.code, 'certainty', l.certainty, 'subcode', l.subcode))
    from public.reason_code_legacy l
   where l.vocabulary = p_vocabulary and l.legacy_code = p_legacy_code
$$;
revoke all on function internal.canonical_reason(text, text) from public, anon, authenticated, service_role;

commit;
