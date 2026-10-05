-- ActivityContext v2: the canonical activity class on the server read surface.
--
-- A run in a day document now carries `activity_class` (one of the app's 15 snake_case classes, e.g.
-- sitting_desk, walking, running, off_wrist, unknown) and `class_confidence` (0..1), derived by the same
-- StrandAnalytics classifier the phone uses, so a downstream query can label a measurement with the
-- class without re-implementing the mapping from the posture / locomotion / arm head probabilities.
--
-- Additive and order-independent: both keys are optional in the document, a document written before
-- them reads as NULL, and no existing column, argument or privilege changes. The migration can be
-- applied before or after the worker upgrade; documents published before the worker is rebuilt
-- simply keep NULL classes until their day is recomputed.
--
-- What changes:
--   1. internal.activity_day_run_valid also checks the two keys WHEN PRESENT, so a malformed value is
--      rejected at publish time instead of failing every read of the views below.
--   2. public.activity_context_runs gains activity_class and class_confidence at the end.
--   3. public.activity_context_at gains the same two columns at the end. A function's result type cannot
--      change in place, so it is dropped and created again inside this transaction with its grants.
--
-- Rollback: re-create activity_context_runs and activity_context_at from
-- 20261003140000_activity_context_stream_days.sql (drop view / function first: columns cannot be removed
-- with CREATE OR REPLACE) and activity_day_run_valid from 20261003130000_activity_context_days.sql.
-- Stored documents are untouched either way.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. Run validation. Everything before the two new checks is the function it replaces, line for line;
--    the privileges of the existing function are kept by CREATE OR REPLACE.
create or replace function internal.activity_day_run_valid(r jsonb, p_lo bigint, p_end bigint)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(r) is distinct from 'object' then return false; end if;
  if not internal.activity_day_num_ok(r -> 's', p_lo, p_end - 1, true) then return false; end if;
  if not internal.activity_day_num_ok(r -> 'e', p_lo + 1, p_end, true) then return false; end if;
  if (r ->> 'e')::numeric <= (r ->> 's')::numeric then return false; end if;
  if not internal.activity_day_num_ok(r -> 'n', 1, 100000, true) then return false; end if;
  if not internal.activity_day_num_ok(r -> 'overall_confidence', 0, 1, false) then return false; end if;
  if not internal.activity_day_num_ok(r -> 'overall_uncertainty', 0, 1, false) then return false; end if;
  if coalesce(jsonb_typeof(r -> 'intensity'), 'null') not in ('number', 'null') then return false; end if;
  if jsonb_typeof(r -> 'posture') is distinct from 'object'
    or jsonb_typeof(r -> 'locomotion') is distinct from 'object'
    or jsonb_typeof(r -> 'arm_behavior') is distinct from 'object' then return false; end if;
  if jsonb_typeof(r -> 'sleep') is distinct from 'string' or length(r ->> 'sleep') > 32 then return false; end if;
  if jsonb_typeof(r -> 'wear') is distinct from 'string' or length(r ->> 'wear') > 32 then return false; end if;
  if coalesce(jsonb_typeof(r -> 'display_context'), 'null') not in ('string', 'null')
    or length(coalesce(r ->> 'display_context', '')) > 64 then return false; end if;
  -- The class is a short snake_case code, not a closed list: a taxonomy that grows a class must not
  -- need a migration and a worker deployed in lock step.
  if coalesce(jsonb_typeof(r -> 'activity_class'), 'null') not in ('string', 'null') then return false; end if;
  if jsonb_typeof(r -> 'activity_class') = 'string'
    and (r ->> 'activity_class') !~ '^[a-z][a-z0-9_]{0,31}$' then return false; end if;
  if coalesce(jsonb_typeof(r -> 'class_confidence'), 'null') <> 'null'
    and not internal.activity_day_num_ok(r -> 'class_confidence', 0, 1, false) then return false; end if;
  return true;
end $$;

-- 2. The runs view. New columns can only be appended, so every existing column keeps its name, type
--    and position.
create or replace view public.activity_context_runs with (security_invoker = true) as
select d.user_id, d.device_id, d.day, d.algorithm_version,
       (r.value ->> 's')::bigint as start_ts,
       (r.value ->> 'e')::bigint as end_ts,
       to_timestamp((r.value ->> 's')::bigint) as start_at,
       to_timestamp((r.value ->> 'e')::bigint) as end_at,
       ((r.value ->> 'e')::bigint - (r.value ->> 's')::bigint)::integer as duration_s,
       r.value ->> 'display_context' as display_context,
       (r.value ->> 'overall_confidence')::real as confidence,
       (r.value ->> 'overall_uncertainty')::real as uncertainty,
       (r.value ->> 'intensity')::real as intensity,
       r.value ->> 'sleep' as sleep_state,
       r.value ->> 'wear' as wear_state,
       (r.value ->> 'n')::integer as states,
       r.value -> 'posture' as posture,
       r.value -> 'locomotion' as locomotion,
       r.value -> 'arm_behavior' as arm_behavior,
       d.model_version, d.decoder_version, d.ontology_version, d.feature_schema,
       d.encoder_id, d.encoder_version, d.result_revision, d.computed_at,
       case d.algorithm_version when 'hart-activity-1' then 1 else 2 end as source_rank,
       r.value ->> 'activity_class' as activity_class,
       (r.value ->> 'class_confidence')::real as class_confidence
  from public.activity_context_days d
 cross join lateral jsonb_array_elements(d.document -> 'runs') as r(value);

comment on view public.activity_context_runs is
  'ActivityContext v2: one row per decoded run (exact start/end unix seconds, display_context, confidence, '
  'uncertainty, posture/locomotion/arm head probabilities). UTC days; source_rank 1 = raw-IMU (HART) '
  'document, 2 = measurement-stream document. Join a measurement timestamp ts with start_ts <= ts < end_ts. '
  'activity_class / class_confidence: the canonical class (sleeping, lying_down, sitting, sitting_desk, '
  'standing, stationary, fidgeting, light_activity, walking, brisk_walking, running, cycling, '
  'vigorous_activity, off_wrist, unknown) and how sure the classifier was; NULL on a document written '
  'before they existed.';

-- 3. The lookup. Same body and ordering, two more columns at the end.
drop function public.activity_context_at(uuid, uuid, bigint);
create function public.activity_context_at(p_user uuid, p_device uuid, p_ts bigint)
returns table (algorithm_version text, start_ts bigint, end_ts bigint, display_context text,
               confidence real, uncertainty real, intensity real, sleep_state text, wear_state text,
               states integer, posture jsonb, locomotion jsonb, arm_behavior jsonb,
               model_version text, decoder_version text, computed_at timestamptz,
               activity_class text, class_confidence real)
language sql stable set search_path='' as $$
  select r.algorithm_version, r.start_ts, r.end_ts, r.display_context, r.confidence, r.uncertainty,
         r.intensity, r.sleep_state, r.wear_state, r.states, r.posture, r.locomotion, r.arm_behavior,
         r.model_version, r.decoder_version, r.computed_at, r.activity_class, r.class_confidence
    from public.activity_context_runs r
   where r.user_id = p_user and r.device_id = p_device
     and r.day = (to_timestamp(p_ts) at time zone 'UTC')::date
     and r.start_ts <= p_ts and p_ts < r.end_ts
   order by r.source_rank, r.algorithm_version
$$;

revoke all on function public.activity_context_at(uuid, uuid, bigint) from public, anon;
grant execute on function public.activity_context_at(uuid, uuid, bigint) to authenticated, service_role;

commit;
