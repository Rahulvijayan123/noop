-- publish_metric_series_v1: input-revision fencing (G2-attestation item 4 / T31).
--
-- The 5-arg function (20261001210000_metric_series.sql, refined by
-- 20261002120000_metric_series_per_metric_buckets.sql) fences on the day's
-- selected device + an advisory lock only, so a stale scoring pass whose snapshot
-- already committed can still overwrite a NEWER revision's series after an upload
-- bumps input_revision. This is the derived intraday side channel: immutable
-- snapshots/server_daily_scores are unaffected, but the "latest projections remain
-- newer" invariant (T31) does not hold for the series.
--
-- This migration adds a fenced 6-arg form carrying the revision the caller
-- CLAIMED (ScoringLane.publishSeries passes claim.inputRevision). The function
-- rejects the write when a newer scoring_jobs_v2 input_revision exists for the
-- same (user, device, day): the stale pass must not overwrite the newer series.
-- The rejection is a normal result (applied=false, reason='superseded'), never an
-- exception, so the worker treats it as superseded, not as success or failure.
--
-- The legacy 5-arg signature is intentionally left callable for the existing psql
-- fixture (tests/metric_series.sql) and backward compatibility; it is
-- service-role-only and cannot be fenced because it carries no claimed revision.
-- The production writer must use the fenced 6-arg form below.
--
-- Additive only. One transaction.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.publish_metric_series_v1(
  p_user uuid, p_device uuid, p_day date, p_version text, p_payload jsonb, p_input_revision bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  metrics constant text[] := array['hrv_rmssd_ms','resting_hr_bpm','resp_rate_bpm','steps','calories_kcal'];
  m text;
  bucket integer;
  metric_bucket integer;
  widths jsonb;
  algo text;
  w_start timestamptz;
  w_end timestamptz;
  points jsonb;
  stamps timestamptz[];
  n integer;
  total_upserted integer := 0;
  total_deleted integer := 0;
  per jsonb := '{}'::jsonb;
  latest_rev bigint;
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

  widths := coalesce(p_payload -> 'metric_bucket_seconds', '{}'::jsonb);
  if jsonb_typeof(widths) is distinct from 'object'
     or exists (select 1 from jsonb_object_keys(widths) k where k <> all (metrics))
     or exists (select 1 from jsonb_each(widths) e
                 where not (case when jsonb_typeof(e.value) = 'number' and e.value::text ~ '^[0-9]{2,4}$'
                                 then e.value::text::integer between 60 and 3600
                                 else false end)) then
    raise exception 'metric series: invalid metric bucket widths' using errcode = '22023';
  end if;

  if not exists (select 1 from devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'metric series: device does not belong to the user' using errcode = '42501';
  end if;
  if not exists (select 1 from scoring_algorithms_v2 a where a.algorithm_version = p_version) then
    raise exception 'metric series: % is not a scoring algorithm', p_version using errcode = '22023';
  end if;
  if p_input_revision is null or p_input_revision <= 0 then
    raise exception 'metric series: a positive input revision is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('metric_series:' || p_user::text || ':' || p_day::text, 0));
  if public.selected_scoring_device_v2(p_user, p_day, p_version) is distinct from p_device then
    return jsonb_build_object('applied', false, 'reason', 'not_selected');
  end if;

  -- Input-revision fence (mirrors publish_scoring_snapshot_v2's job-row guard):
  -- a pass that claimed an OLDER revision than the day's current one has been
  -- superseded by a newer upload and must not overwrite the newer series.
  select input_revision into latest_rev from public.scoring_jobs_v2
    where user_id = p_user and device_id = p_device and day = p_day
    order by input_revision desc
    limit 1;
  if latest_rev is not null and p_input_revision < latest_rev then
    return jsonb_build_object('applied', false, 'reason', 'superseded',
      'claimed_input_revision', p_input_revision, 'latest_input_revision', latest_rev);
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
    metric_bucket := coalesce((widths ->> m)::integer, bucket);

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
      select p_user, m, i.bucket_start, metric_bucket, i.value, i.sample_count, i.coverage, i.motion, p_device, algo
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

revoke all on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb, bigint)
  from public, anon, authenticated;
grant execute on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb, bigint)
  to service_role;

comment on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb, bigint) is
  'Fenced dense-series writer: refuses (applied=false, reason=superseded) when the claimed input revision is older than the day''s latest scoring_jobs_v2 input_revision.';

notify pgrst, 'reload schema';
commit;
