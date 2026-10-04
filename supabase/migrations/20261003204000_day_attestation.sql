-- Day attestation: revive the dormant day_completeness table as the compact,
-- versioned per-day attestation written by the v2 scoring pass (G2-attestation
-- item 2 / spec 4.4).
--
-- day_completeness (20260830202224_day_completeness.sql + harden) has zero code
-- references and its (user_id, day) PK carries no device or revision. This
-- migration adds the minimal columns the v2 pass can HONESTLY write and a
-- service-role RPC that upserts ONE versioned attestation per (user, day),
-- fenced so an older revision can never overwrite a newer one. The record
-- carries spec 4.4 fields the pass actually knows (identity/time, stream counts,
-- day bounds, projection completion, scoring status) and explicit
-- 'not_measured' markers for everything it cannot know (firmware versions,
-- archive/manifest status, phone handoff watermarks, gaps, off-body durations).
-- It never fabricates a continuity verdict: `status` stays 'open' (the table's
-- default "ambiguous or in progress"); the scoring status travels INSIDE the
-- attestation payload where it is truthful.
--
-- The record is written only after a successful publish_scoring_snapshot_v2, so
-- projection completion is factual. RLS already makes day_completeness
-- service-role-write-only (20260830202255_day_completeness_harden.sql); this RPC
-- is the only writer.
--
-- Additive only. One transaction. No production row is rewritten or deleted.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.day_completeness
  add column if not exists device_id uuid,
  add column if not exists input_revision bigint not null default 0,
  add column if not exists attestation jsonb not null default '{}'::jsonb,
  add column if not exists attestation_version text;

comment on column public.day_completeness.device_id is
  'The device/assignment scope of the attestation the v2 scoring pass wrote (spec 4.4 identity).';
comment on column public.day_completeness.input_revision is
  'The scoring input revision the attestation describes; writes are fenced on this (only newer revisions advance the record).';
comment on column public.day_completeness.attestation is
  'Compact versioned daily attestation (attestation_version) written by the v2 scoring pass after a successful snapshot publish. Never a continuity verdict; unknown fields are explicit not_measured markers.';
comment on column public.day_completeness.attestation_version is
  'Shape version of the attestation payload, e.g. nara-day-completeness-v1.';

create or replace function public.publish_day_attestation_v1(
  p_user uuid, p_device uuid, p_day date, p_input_revision bigint,
  p_timezone text, p_attestation jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  applied boolean;
begin
  if p_user is null or p_device is null or p_day is null or p_input_revision is null or p_input_revision <= 0
     or coalesce(p_timezone, '') = '' or jsonb_typeof(p_attestation) is distinct from 'object' then
    raise exception 'day attestation: invalid arguments' using errcode = '22023';
  end if;
  if not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'day attestation: device does not belong to the user' using errcode = '42501';
  end if;
  if not exists (select 1 from pg_timezone_names where name = p_timezone) then
    raise exception 'day attestation: invalid timezone' using errcode = '22023';
  end if;

  insert into public.day_completeness
    (user_id, day, timezone_name, device_id, input_revision, attestation, attestation_version, updated_at)
  values (p_user, p_day, p_timezone, p_device, p_input_revision, p_attestation,
          'nara-day-completeness-v1', clock_timestamp())
  on conflict (user_id, day) do update
    set timezone_name = excluded.timezone_name,
        device_id = excluded.device_id,
        input_revision = excluded.input_revision,
        attestation = excluded.attestation,
        attestation_version = excluded.attestation_version,
        updated_at = clock_timestamp()
    -- Fence: only a strictly newer revision advances the record; an equal
    -- revision is accepted ONLY from the same device (idempotent retry of the
    -- same pass). An older revision, or a different device at the same
    -- revision, cannot overwrite the day's attestation.
    where public.day_completeness.input_revision < excluded.input_revision
       or (public.day_completeness.input_revision = excluded.input_revision
           and public.day_completeness.device_id = excluded.device_id);
  get diagnostics applied = row_count;

  if applied then
    return jsonb_build_object('applied', true, 'input_revision', p_input_revision);
  end if;
  return jsonb_build_object('applied', false, 'reason', 'superseded',
    'claimed_input_revision', p_input_revision);
end $$;

revoke all on function public.publish_day_attestation_v1(uuid, uuid, date, bigint, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_day_attestation_v1(uuid, uuid, date, bigint, text, jsonb)
  to service_role;

comment on function public.publish_day_attestation_v1(uuid, uuid, date, bigint, text, jsonb) is
  'Versioned per-day attestation upsert from the v2 scoring pass; refused (applied=false, reason=superseded) when an equal or newer input_revision already owns the day.';

notify pgrst, 'reload schema';
commit;
