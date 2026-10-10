-- POST scores/context-intervals: the phone's activity-context intervals, so the server builds Layer 1 baselines.
--
-- WHY
-- The phenotype-signature engine (Tools/PersonalEventDetection) compares HR and HRV with the person's Layer 1 v2
-- context-strata references (sleep, awake still by posture, steady walking, exercise session, after exercise), the
-- same baselines the Watchdog draws. Those strata are materialized from the phone's activity-context intervals
-- (HART decode + sleep + wear + posture, causal reading, the wearer's corrections overlaid), which only exist on the
-- phone. Until now the server had none, so every timeline it scored said Layer 1 was unavailable. The phone uploads
-- its intervals per day; the worker reads them with the history Layer 1 needs and materializes the strata with the
-- port of the phone's materializer (personal_events/layer1_context.py, lb-context-3).
--
-- WHAT CHANGES
--   public.phone_context_intervals          one row per (owner, strap device, interval start): the 18 interval fields
--                                           the materializer reads (ActivityContextIntervalRow names, snake case),
--                                           the phone's materializer version and source read id, received_at.
--                                           RLS: the owner selects their own rows; only service_role writes.
--   public.phone_context_intervals_replace_v1(user, device, source, version, from, to, intervals)
--                                           service only (the scores route, owner and device from the credential).
--                                           Replaces the strap's intervals whose start is in [from, to) with the
--                                           payload (at most 5000 intervals, a range of at most 2 days, every start
--                                           inside it). Idempotent; an empty payload clears the range (the phone
--                                           re-read that day and has nothing). Returns {accepted, deleted}.
--
-- Safe to re-run. Rollback: drop function public.phone_context_intervals_replace_v1(uuid, uuid, text, text, bigint,
-- bigint, jsonb); drop table public.phone_context_intervals.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.phone_context_intervals (
  user_id               uuid not null references auth.users(id) on delete cascade,
  device_id             uuid not null,
  start_ts              bigint not null,
  end_ts                bigint not null,
  activity_class        text not null,
  confidence            double precision not null default 0,
  evidence_quality      double precision not null default 0,
  posture               text,
  locomotion            text,
  sleep_state           text not null default 'unknown',
  wear_state            text not null default 'unknown',
  intensity             double precision,
  hr_samples            integer not null default 0,
  hr_mean               double precision,
  rmssd                 double precision,
  rr_beats              integer not null default 0,
  rr_diff_sq_sum_ms2    double precision not null default 0,
  rr_diff_count         integer not null default 0,
  detail                text,
  arm_behavior          text,
  source_id             text,
  materializer_version  text not null,
  received_at           timestamptz not null default now(),
  primary key (user_id, device_id, start_ts),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (end_ts > start_ts)
);
comment on table public.phone_context_intervals is
  'The phone''s activity-context intervals (causal reading, corrections overlaid) per strap, uploaded by POST '
  'scores/context-intervals (20261009190000). Input of the server''s Layer 1 context-strata baselines '
  '(Tools/PersonalEventDetection/personal_events/layer1_context.py).';
alter table public.phone_context_intervals enable row level security;
revoke all on public.phone_context_intervals from public, anon, authenticated;
grant select on public.phone_context_intervals to authenticated;
grant all on public.phone_context_intervals to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'phone_context_intervals'
                    and policyname = 'phone_context_intervals_owner_read') then
    create policy phone_context_intervals_owner_read on public.phone_context_intervals for select to authenticated
      using (user_id = (select auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'phone_context_intervals'
                    and policyname = 'phone_context_intervals_service') then
    create policy phone_context_intervals_service on public.phone_context_intervals for all to service_role
      using (true) with check (true);
  end if;
end $$;

create or replace function public.phone_context_intervals_replace_v1(p_user uuid, p_device uuid, p_source text,
                                                                     p_version text, p_from bigint, p_to bigint,
                                                                     p_intervals jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_now bigint := extract(epoch from clock_timestamp())::bigint;
  v_bad integer;
  v_deleted integer;
  v_accepted integer;
begin
  if p_user is null or p_device is null then raise exception 'invalid_context_intervals'; end if;
  if p_version is null or p_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' then
    raise exception 'invalid_context_intervals';
  end if;
  if p_source is not null and length(p_source) > 128 then raise exception 'invalid_context_intervals'; end if;
  if p_from is null or p_to is null or p_from < 1577836800 or p_to <= p_from or p_to - p_from > 2 * 86400
     or p_from > v_now + 86400 then
    raise exception 'invalid_context_intervals';
  end if;
  if jsonb_typeof(p_intervals) is distinct from 'array' or jsonb_array_length(p_intervals) > 5000 then
    raise exception 'invalid_context_intervals';
  end if;
  if not exists (select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'context_intervals_device_owner';
  end if;

  select count(*) into v_bad
    from jsonb_array_elements(p_intervals) e
   where not (
     jsonb_typeof(e) = 'object'
     and jsonb_typeof(e -> 'start_ts') = 'number' and (e ->> 'start_ts')::numeric % 1 = 0
     and jsonb_typeof(e -> 'end_ts') = 'number' and (e ->> 'end_ts')::numeric % 1 = 0
     and (e ->> 'start_ts')::numeric >= p_from and (e ->> 'start_ts')::numeric < p_to
     and (e ->> 'end_ts')::numeric > (e ->> 'start_ts')::numeric
     and (e ->> 'end_ts')::numeric - (e ->> 'start_ts')::numeric <= 86400
     and jsonb_typeof(e -> 'activity_class') = 'string' and length(e ->> 'activity_class') between 1 and 64
     and coalesce(jsonb_typeof(e -> 'confidence'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'evidence_quality'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'intensity'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'hr_mean'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'rmssd'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'rr_diff_sq_sum_ms2'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'hr_samples'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'rr_beats'), 'null') in ('null', 'number')
     and coalesce(jsonb_typeof(e -> 'rr_diff_count'), 'null') in ('null', 'number')
     and coalesce((e ->> 'hr_samples')::numeric, 0) between 0 and 1000000
     and coalesce((e ->> 'rr_beats')::numeric, 0) between 0 and 1000000
     and coalesce((e ->> 'rr_diff_count')::numeric, 0) between 0 and 1000000
     and coalesce((e ->> 'hr_samples')::numeric, 0) % 1 = 0
     and coalesce((e ->> 'rr_beats')::numeric, 0) % 1 = 0
     and coalesce((e ->> 'rr_diff_count')::numeric, 0) % 1 = 0
     and coalesce(jsonb_typeof(e -> 'posture'), 'null') in ('null', 'string')
     and coalesce(jsonb_typeof(e -> 'locomotion'), 'null') in ('null', 'string')
     and coalesce(jsonb_typeof(e -> 'sleep_state'), 'null') in ('null', 'string')
     and coalesce(jsonb_typeof(e -> 'wear_state'), 'null') in ('null', 'string')
     and coalesce(jsonb_typeof(e -> 'detail'), 'null') in ('null', 'string')
     and coalesce(jsonb_typeof(e -> 'arm_behavior'), 'null') in ('null', 'string')
     and coalesce(length(e ->> 'posture'), 0) <= 64 and coalesce(length(e ->> 'locomotion'), 0) <= 64
     and coalesce(length(e ->> 'sleep_state'), 0) <= 64 and coalesce(length(e ->> 'wear_state'), 0) <= 64
     and coalesce(length(e ->> 'detail'), 0) <= 64 and coalesce(length(e ->> 'arm_behavior'), 0) <= 64);
  if v_bad > 0 then raise exception 'invalid_context_intervals'; end if;
  if (select count(distinct (e ->> 'start_ts')::numeric) from jsonb_array_elements(p_intervals) e)
     <> jsonb_array_length(p_intervals) then
    raise exception 'invalid_context_intervals';  -- the same start twice
  end if;

  perform pg_advisory_xact_lock(hashtextextended('phone-context:' || p_user::text || ':' || p_device::text, 0));
  delete from public.phone_context_intervals t
   where t.user_id = p_user and t.device_id = p_device and t.start_ts >= p_from and t.start_ts < p_to;
  get diagnostics v_deleted = row_count;
  insert into public.phone_context_intervals (
    user_id, device_id, start_ts, end_ts, activity_class, confidence, evidence_quality, posture, locomotion,
    sleep_state, wear_state, intensity, hr_samples, hr_mean, rmssd, rr_beats, rr_diff_sq_sum_ms2, rr_diff_count,
    detail, arm_behavior, source_id, materializer_version)
  select p_user, p_device, (e ->> 'start_ts')::numeric::bigint, (e ->> 'end_ts')::numeric::bigint,
         e ->> 'activity_class', coalesce((e ->> 'confidence')::double precision, 0),
         coalesce((e ->> 'evidence_quality')::double precision, 0), e ->> 'posture', e ->> 'locomotion',
         coalesce(e ->> 'sleep_state', 'unknown'), coalesce(e ->> 'wear_state', 'unknown'),
         (e ->> 'intensity')::double precision, coalesce((e ->> 'hr_samples')::numeric::integer, 0),
         (e ->> 'hr_mean')::double precision, (e ->> 'rmssd')::double precision,
         coalesce((e ->> 'rr_beats')::numeric::integer, 0),
         coalesce((e ->> 'rr_diff_sq_sum_ms2')::double precision, 0),
         coalesce((e ->> 'rr_diff_count')::numeric::integer, 0), e ->> 'detail', e ->> 'arm_behavior',
         p_source, p_version
    from jsonb_array_elements(p_intervals) e;
  get diagnostics v_accepted = row_count;
  return jsonb_build_object('accepted', v_accepted, 'deleted', v_deleted);
end $$;
revoke all on function public.phone_context_intervals_replace_v1(uuid, uuid, text, text, bigint, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.phone_context_intervals_replace_v1(uuid, uuid, text, text, bigint, bigint, jsonb)
  to service_role;

commit;
