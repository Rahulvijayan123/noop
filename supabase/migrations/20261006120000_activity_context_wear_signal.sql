-- Wear-signal-quality on activity-context epochs (feat/wear-signal-quality V1).
--
-- Additive only: one nullable TEXT column carries the six-state
-- WearSignalState (`wsq` in the C10 epoch JSON) from the shared
-- StrandAnalytics engine next to the existing three-state wear_state.
-- The wear_state column and its CHECK are untouched; documents/rows
-- without a `wsq` key decode as NULL (missing evidence, never fabricated).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.activity_context_epochs
  add column wear_signal text
  check (wear_signal is null or wear_signal in
    ('on_wrist_good','on_wrist_loose','motion_artifact','off_wrist','sensor_dropout','unknown'));

-- The fenced publish gains the optional `wsq` epoch key: when present it must be one of the six
-- states, and it is stored in wear_signal. Everything else is byte-for-byte the v1 contract.
create or replace function public.publish_activity_context_v2(p_token uuid, p_revision bigint,
  p_payload jsonb, p_duration_ms bigint)
returns bigint language plpgsql security definer set search_path='' as $$
declare j public.activity_context_jobs; e jsonb; rev bigint; computed timestamptz;
  day_lo bigint; day_end bigint; day_hi bigint; cnt integer := 0;
  stamp_model text; stamp_pre text;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;
  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'epochs') is distinct from 'array'
    or p_payload -> 'day' is null
    or (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_activity_payload';
  end if;
  day_lo := extract(epoch from (j.day::timestamp at time zone 'UTC'))::bigint;
  day_end := extract(epoch from ((j.day + 1)::timestamp at time zone 'UTC'))::bigint;
  day_hi := day_end - 1;
  for e in select value from jsonb_array_elements(p_payload -> 'epochs') loop
    cnt := cnt + 1;
    if cnt > 2880 then raise exception 'invalid_activity_epoch_count'; end if;
    if jsonb_typeof(e) is distinct from 'object'
      or not (e ? 's' and e ? 'e' and e ? 'm' and e ? 'p' and e ? 'ex' and e ? 'sl'
        and e ? 'ec' and e ? 'w' and e ? 'c' and e ? 'os' and e ? 'vs')
      or coalesce(e ->> 'm', '') not in ('stationary','walking','running','other_movement','unknown')
      or coalesce(e ->> 'p', '') not in ('sitting','standing','lying','unknown')
      or coalesce(e ->> 'ex', '') not in ('true','false','unknown')
      or coalesce(e ->> 'sl', '') not in ('awake','asleep','unknown')
      or coalesce(e ->> 'ec', '') not in ('resting_candidate','active','post_activity','mixed','unknown')
      or coalesce(e ->> 'w', '') not in ('on_wrist','off_wrist','unknown')
      or (e ? 'wsq' and coalesce(e ->> 'wsq', '') not in
        ('on_wrist_good','on_wrist_loose','motion_artifact','off_wrist','sensor_dropout','unknown'))
      or (e ->> 's') is null or (e ->> 'e') is null or (e ->> 'c') is null
      or (e ->> 'os') is null or (e ->> 'vs') is null
      or (e ->> 's')::bigint < day_lo or (e ->> 'e')::bigint > day_end
      or (e ->> 'e')::bigint <= (e ->> 's')::bigint
      or (e ->> 'os')::integer < 0 or (e ->> 'vs')::integer < 0
      or (e ->> 'c')::real < 0 or (e ->> 'c')::real > 1
      or (e ->> 'vs')::integer > (e ->> 'os')::integer then
      raise exception 'invalid_activity_epoch';
    end if;
  end loop;
  computed := clock_timestamp();
  stamp_model := coalesce(nullif(p_payload ->> 'model_version', ''), j.model_version);
  stamp_pre := coalesce(nullif(p_payload ->> 'preprocessing_version', ''), j.preprocessing_version);
  update public.activity_context_jobs
     set model_version = stamp_model, preprocessing_version = stamp_pre
   where lease_token = p_token
     and user_id = j.user_id and device_id = j.device_id and day = j.day
     and algorithm_version = j.algorithm_version;
  rev := nextval('public.activity_context_epochs_result_revision_seq');
  delete from public.activity_context_epochs
    where user_id = j.user_id and device_id = j.device_id and day = j.day and fingerprint = j.fingerprint;
  for e in select value from jsonb_array_elements(p_payload -> 'epochs') loop
    insert into public.activity_context_epochs(user_id, device_id, day, start_ts, end_ts,
      motion_label, posture, exercise_session, sleep_state, exertion_context, wear_state, wear_signal,
      confidence, observed_s, valid_s, model_version, preprocessing_version, ontology_version,
      fingerprint, result_revision, computed_at)
    values(j.user_id, j.device_id, j.day, (e ->> 's')::bigint, (e ->> 'e')::bigint,
      e ->> 'm', e ->> 'p', e ->> 'ex', e ->> 'sl', e ->> 'ec', e ->> 'w', nullif(e ->> 'wsq', ''),
      (e ->> 'c')::real, (e ->> 'os')::integer, (e ->> 'vs')::integer,
      stamp_model, stamp_pre, j.ontology_version,
      j.fingerprint, rev, computed);
  end loop;
  update public.activity_context_jobs set completed_revision = p_revision,
    lease_token = null, lease_until = null, consecutive_failures = 0, dead_letter = false,
    last_error = null, last_completed_at = computed, last_duration_ms = greatest(0, p_duration_ms),
    success_count = success_count + 1
  where user_id = j.user_id and device_id = j.device_id and day = j.day
    and algorithm_version = j.algorithm_version;
  perform public.scoring_dirty_span(j.user_id, j.device_id, day_lo, day_hi);
  return rev;
end $$;

-- The RPC's grants/revokes are unchanged by the replace (function identity preserved).
commit;
