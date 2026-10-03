-- Dense intraday series for HRV, resting heart rate, respiratory rate, steps and calories.
--
-- The scorer publishes one value per metric per day (server_daily_scores). Baselines and event
-- detection want the shape of the day, so the worker also computes a value per 5-minute bucket from the
-- same raw streams and writes it here: about 1,400 small rows per user per day, replaced bucket by bucket
-- as new samples arrive. Nothing here feeds back into the scorer; the table is derived and rebuildable.
--
-- * server_metric_series         one row per (user, metric, bucket). The owner can read their own rows.
-- * publish_metric_series_v1     worker-only. Replaces one metric's buckets over one claimed day's window
--                                with the payload, writing only buckets whose content changed, and does
--                                nothing unless the calling device is the one the day's scores are read
--                                from (selected_scoring_device_v2), so a duplicate device cannot overwrite
--                                the strap's series. p_version is the SCORING algorithm that choice is made
--                                for (frwhoop-server-1), not the series' own version, which rides in the
--                                payload; an unregistered p_version is an error rather than a silent skip.
-- * server_metric_series_read    worker/edge-only. The buckets of a time range as one jsonb document, which
--                                keeps a full day (more than PostgREST's 1,000-row cap) in one response.
--
-- A point is [bucket_start_unix, value, sample_count, coverage, motion]; see
-- Tools/CloudWorker/Sources/frwhoop-worker/IntradaySeries.swift for what each metric means.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create table if not exists public.server_metric_series (
  user_id uuid not null references auth.users(id) on delete cascade,
  metric text not null,
  bucket_start timestamptz not null,
  bucket_seconds integer not null default 300,
  value double precision not null,
  sample_count integer not null default 0,
  coverage real,
  motion real,
  device_id uuid not null,
  algorithm_version text not null,
  computed_at timestamptz not null default now(),
  constraint server_metric_series_pkey primary key (user_id, metric, bucket_start),
  constraint server_metric_series_metric_check
    check (metric in ('hrv_rmssd_ms','resting_hr_bpm','resp_rate_bpm','steps','calories_kcal')),
  constraint server_metric_series_bucket_check check (bucket_seconds between 60 and 3600),
  constraint server_metric_series_value_check check (
    case metric
      when 'hrv_rmssd_ms' then value between 0 and 1000
      when 'resting_hr_bpm' then value between 20 and 250
      when 'resp_rate_bpm' then value between 4 and 40
      when 'steps' then value between 0 and 20000
      when 'calories_kcal' then value between 0 and 5000
    end),
  constraint server_metric_series_count_check check (sample_count >= 0),
  constraint server_metric_series_coverage_check check (coverage is null or coverage between 0 and 1),
  constraint server_metric_series_motion_check check (motion is null or motion between 0 and 1)
);

comment on table public.server_metric_series is
  'Worker-computed 5-minute series of HRV, resting HR, respiratory rate, steps and calories; derived, rebuildable.';

alter table public.server_metric_series enable row level security;
revoke all on table public.server_metric_series from public, anon, authenticated;
grant select on table public.server_metric_series to authenticated;
grant all on table public.server_metric_series to service_role;

drop policy if exists server_metric_series_select_own on public.server_metric_series;
create policy server_metric_series_select_own
  on public.server_metric_series for select to authenticated
  using ((select auth.uid()) = user_id);

create or replace function public.publish_metric_series_v1(
  p_user uuid, p_device uuid, p_day date, p_version text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  metrics constant text[] := array['hrv_rmssd_ms','resting_hr_bpm','resp_rate_bpm','steps','calories_kcal'];
  m text;
  bucket integer;
  algo text;
  w_start timestamptz;
  w_end timestamptz;
  points jsonb;
  stamps timestamptz[];
  n integer;
  total_upserted integer := 0;
  total_deleted integer := 0;
  per jsonb := '{}'::jsonb;
begin
  if p_user is null or p_device is null or p_day is null or coalesce(p_version, '') = ''
     or jsonb_typeof(p_payload) is distinct from 'object'
     or jsonb_typeof(p_payload -> 'metrics') is distinct from 'object' then
    raise exception 'metric series: invalid arguments' using errcode = '22023';
  end if;
  bucket := (p_payload ->> 'bucket_seconds')::integer;
  algo := p_payload ->> 'algorithm_version';
  w_start := to_timestamp((p_payload #>> '{window,start}')::bigint);
  w_end := to_timestamp((p_payload #>> '{window,end}')::bigint);
  if bucket is null or bucket not between 60 and 3600
     or algo is null or length(algo) not between 1 and 64
     or w_start is null or w_end is null or w_end <= w_start or w_end - w_start > interval '50 hours'
     or exists (select 1 from jsonb_object_keys(p_payload -> 'metrics') k where k <> all (metrics)) then
    raise exception 'metric series: invalid payload' using errcode = '22023';
  end if;
  if not exists (select 1 from devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'metric series: device does not belong to the user' using errcode = '42501';
  end if;
  if not exists (select 1 from scoring_algorithms_v2 a where a.algorithm_version = p_version) then
    raise exception 'metric series: % is not a scoring algorithm', p_version using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('metric_series:' || p_user::text || ':' || p_day::text, 0));
  if public.selected_scoring_device_v2(p_user, p_day, p_version) is distinct from p_device then
    return jsonb_build_object('applied', false, 'reason', 'not_selected');
  end if;

  foreach m in array metrics loop
    -- A metric that is absent leaves what is stored alone; one that is present, even empty, replaces the window.
    if not (p_payload -> 'metrics') ? m then
      continue;
    end if;
    points := p_payload -> 'metrics' -> m;
    if jsonb_typeof(points) is distinct from 'array' or jsonb_array_length(points) > 1500 then
      raise exception 'metric series: invalid points for %', m using errcode = '22023';
    end if;

    select coalesce(array_agg(to_timestamp((e ->> 0)::bigint)), '{}'::timestamptz[]) into stamps
      from jsonb_array_elements(points) e;
    if exists (select 1 from unnest(stamps) t where t < w_start or t >= w_end) then
      raise exception 'metric series: % has a point outside the window', m using errcode = '22023';
    end if;

    with incoming as (
      select distinct on (to_timestamp((e ->> 0)::bigint))
             to_timestamp((e ->> 0)::bigint) as bucket_start,
             (e ->> 1)::double precision as value,
             coalesce((e ->> 2)::integer, 0) as sample_count,
             (e ->> 3)::real as coverage,
             (e ->> 4)::real as motion
        from jsonb_array_elements(points) e
       order by to_timestamp((e ->> 0)::bigint)
    ), written as (
      insert into server_metric_series as s
        (user_id, metric, bucket_start, bucket_seconds, value, sample_count, coverage, motion, device_id, algorithm_version)
      select p_user, m, i.bucket_start, bucket, i.value, i.sample_count, i.coverage, i.motion, p_device, algo
        from incoming i
      on conflict (user_id, metric, bucket_start) do update
        set bucket_seconds = excluded.bucket_seconds, value = excluded.value, sample_count = excluded.sample_count,
            coverage = excluded.coverage, motion = excluded.motion, device_id = excluded.device_id,
            algorithm_version = excluded.algorithm_version, computed_at = now()
        where (s.bucket_seconds, s.value, s.sample_count, s.coverage, s.motion, s.device_id, s.algorithm_version)
              is distinct from
              (excluded.bucket_seconds, excluded.value, excluded.sample_count, excluded.coverage, excluded.motion,
               excluded.device_id, excluded.algorithm_version)
      returning 1
    )
    select count(*) into n from written;
    total_upserted := total_upserted + n;
    per := per || jsonb_build_object(m, jsonb_build_object('upserted', n));

    delete from server_metric_series s
     where s.user_id = p_user and s.metric = m and s.bucket_start >= w_start and s.bucket_start < w_end
       and s.bucket_start <> all (stamps);
    get diagnostics n = row_count;
    total_deleted := total_deleted + n;
    per := jsonb_set(per, array[m, 'deleted'], to_jsonb(n));
  end loop;

  return jsonb_build_object('applied', true, 'upserted', total_upserted, 'deleted', total_deleted, 'metrics', per);
end $$;

create or replace function public.server_metric_series_read(
  p_user uuid, p_from timestamptz, p_to timestamptz, p_metrics text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  all_metrics constant text[] := array['hrv_rmssd_ms','resting_hr_bpm','resp_rate_bpm','steps','calories_kcal'];
  wanted text[];
  doc jsonb;
begin
  if p_user is null or p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '72 hours' then
    raise exception 'metric series: invalid range' using errcode = '22023';
  end if;
  wanted := coalesce(p_metrics, all_metrics);
  if exists (select 1 from unnest(wanted) w where w <> all (all_metrics)) then
    raise exception 'metric series: unknown metric' using errcode = '22023';
  end if;

  select jsonb_build_object(
           'from', extract(epoch from p_from)::bigint,
           'to', extract(epoch from p_to)::bigint,
           'bucket_seconds', coalesce((select max(s.bucket_seconds) from server_metric_series s
              where s.user_id = p_user and s.bucket_start >= p_from and s.bucket_start < p_to), 300),
           'latest_computed_at', (select max(s.computed_at) from server_metric_series s
              where s.user_id = p_user and s.bucket_start >= p_from and s.bucket_start < p_to),
           'metrics', coalesce(jsonb_object_agg(w.metric, coalesce(g.points, '[]'::jsonb)), '{}'::jsonb))
    into doc
    from (select distinct unnest(wanted) as metric) w
    left join lateral (
      select jsonb_agg(jsonb_build_array(extract(epoch from s.bucket_start)::bigint, s.value, s.sample_count,
                                         s.coverage, s.motion) order by s.bucket_start) as points
        from server_metric_series s
       where s.user_id = p_user and s.metric = w.metric and s.bucket_start >= p_from and s.bucket_start < p_to
    ) g on true;
  return doc;
end $$;

revoke all on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb) from public, anon, authenticated;
grant execute on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb) to service_role;
revoke all on function public.server_metric_series_read(uuid, timestamptz, timestamptz, text[]) from public, anon, authenticated;
grant execute on function public.server_metric_series_read(uuid, timestamptz, timestamptz, text[]) to service_role;

notify pgrst, 'reload schema';
commit;
