-- server_daily_scores is the table the rolling baselines are folded from (the worker's loadBaselines reads
-- it for frwhoop-server-1), and the v2 projection filled it from "the lowest device UUID that has a job
-- that day". Every profile save and history correction queues jobs for ALL of an owner's devices, so an
-- empty installation-scoped duplicate with a low UUID wins routinely and hides the strap's real night
-- (a read-only dry run over production found 43 owner-days where a no_data device hid one holding
-- 20k-300k heart-rate samples). The projection also wrote NULL skin temperature, SpO2 and confidence, so
-- the skin-temperature baseline stayed empty even when the selected snapshot carried the value.
--
-- 1. selected_scoring_device_v2 prefers the device whose latest snapshot holds the most for that day.
--    An explicit scoring_source_preferences_v2 row still overrides it.
-- 2. refresh_scoring_legacy_v2 projects skin_temp_c, skin_temp_dev_c, spo2_pct and confidence from the
--    snapshot. Everything else in the body is unchanged.
-- 3. reproject_scoring_legacy_v2 re-runs the projection from the immutable snapshots and runs once below.
--    It only rewrites derived server_daily_scores / server_sleep_nights rows; raw noop_* rows, snapshots
--    and server_physiology_results are never touched, and it is safe to run again.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create or replace function public.selected_scoring_device_v2(p_user uuid,p_day date,p_version text)
returns uuid language sql stable security invoker set search_path=public as $$
  select coalesce(
    (select s.device_id from scoring_source_preferences_v2 s join devices d on d.id=s.device_id and d.user_id=s.user_id
       where s.user_id=p_user),
    (select q.device_id
       from scoring_jobs_v2 q
       join devices d on d.id=q.device_id and d.user_id=q.user_id
       left join lateral (
         select s.payload from scoring_snapshots_v2 s
         where s.user_id=q.user_id and s.device_id=q.device_id and s.day=q.day
           and s.algorithm_version=q.algorithm_version
         order by s.result_revision desc limit 1) latest on true
       where q.user_id=p_user and q.day=p_day and q.algorithm_version=p_version
       order by
         case when latest.payload is null then 3
              else case latest.payload->>'status' when 'available' then 0 when 'partial' then 1 else 2 end end,
         (select count(*) from unnest(array['hrv_rmssd_ms','resting_hr_bpm','resp_rate_bpm','sleep_total_min','skin_temp_c']) k
            where latest.payload#>>array['daily',k] is not null) desc,
         coalesce(d.external_device_id,'') like 'installation:%',
         case when jsonb_typeof(latest.payload#>'{coverage,hr,received}')='number'
              then (latest.payload#>>'{coverage,hr,received}')::numeric else 0 end desc,
         q.device_id
       limit 1))
$$;

comment on function public.selected_scoring_device_v2(uuid,date,text) is
  'Device whose snapshot feeds server_daily_scores for a day: the owner''s explicit source preference, else the candidate with the best latest snapshot (status, then scored metrics, then serial-scoped over installation-scoped, then heart-rate coverage, then lowest id).';

create or replace function public.refresh_scoring_legacy_v2(p_user uuid,p_day date,p_version text)
returns void language plpgsql security definer set search_path=public as $$
declare s scoring_snapshots_v2; d jsonb; n jsonb; dev uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_user::text||p_day::text||p_version,0));
  dev:=selected_scoring_device_v2(p_user,p_day,p_version);
  select * into s from scoring_snapshots_v2 where user_id=p_user and day=p_day
    and algorithm_version=p_version and device_id=dev order by result_revision desc limit 1;
  if not found then
    delete from server_daily_scores where user_id=p_user and day=p_day and algorithm_version=p_version;
    delete from server_sleep_nights where user_id=p_user and period_day=p_day and algorithm_version=p_version;
    return;
  end if;
  d:=s.payload->'daily';
  insert into server_daily_scores(user_id,day,algorithm_version,source_device_id,
    hrv_rmssd_ms,hrv_sdnn_ms,resting_hr_bpm,resp_rate_bpm,sleep_total_min,sleep_in_bed_min,sleep_awake_min,
    sleep_light_min,sleep_deep_min,sleep_rem_min,sleep_efficiency,sleep_onset_at,wake_onset_at,
    overnight_hr_bpm,disturbances,skin_temp_c,skin_temp_dev_c,spo2_pct,confidence,provenance,computed_at)
  values(p_user,p_day,p_version,dev,(d->>'hrv_rmssd_ms')::numeric,(d->>'hrv_sdnn_ms')::numeric,
    (d->>'resting_hr_bpm')::numeric,(d->>'resp_rate_bpm')::numeric,(d->>'sleep_total_min')::numeric,
    (d->>'sleep_in_bed_min')::numeric,(d->>'sleep_awake_min')::numeric,(d->>'sleep_light_min')::numeric,
    (d->>'sleep_deep_min')::numeric,(d->>'sleep_rem_min')::numeric,(d->>'sleep_efficiency')::numeric,
    (d->>'sleep_onset_at')::timestamptz,(d->>'wake_onset_at')::timestamptz,(d->>'overnight_hr_bpm')::numeric,
    (d->>'disturbances')::integer,(d->>'skin_temp_c')::numeric,(d->>'skin_temp_dev_c')::numeric,
    (d->>'spo2_pct')::numeric,case when jsonb_typeof(d->'confidence')='object' then d->'confidence' else '{}'::jsonb end,
    jsonb_build_object('schemaVersion',2,'resultRevision',s.result_revision),s.computed_at)
  on conflict(user_id,day,algorithm_version) do update set source_device_id=excluded.source_device_id,
    hrv_rmssd_ms=excluded.hrv_rmssd_ms,hrv_sdnn_ms=excluded.hrv_sdnn_ms,resting_hr_bpm=excluded.resting_hr_bpm,
    resp_rate_bpm=excluded.resp_rate_bpm,sleep_total_min=excluded.sleep_total_min,sleep_in_bed_min=excluded.sleep_in_bed_min,
    sleep_awake_min=excluded.sleep_awake_min,sleep_light_min=excluded.sleep_light_min,sleep_deep_min=excluded.sleep_deep_min,
    sleep_rem_min=excluded.sleep_rem_min,sleep_efficiency=excluded.sleep_efficiency,sleep_onset_at=excluded.sleep_onset_at,
    wake_onset_at=excluded.wake_onset_at,overnight_hr_bpm=excluded.overnight_hr_bpm,disturbances=excluded.disturbances,
    readiness_level=null,skin_temp_c=excluded.skin_temp_c,skin_temp_dev_c=excluded.skin_temp_dev_c,
    spo2_pct=excluded.spo2_pct,confidence=excluded.confidence,
    provenance=excluded.provenance,computed_at=excluded.computed_at;
  delete from server_sleep_nights where user_id=p_user and period_day=p_day and algorithm_version=p_version;
  for n in select value from jsonb_array_elements(s.payload->'sleep') loop
    insert into server_sleep_nights(id,user_id,device_id,period_day,start_at,end_at,is_nap,
      in_bed_min,asleep_min,awake_min,light_min,deep_min,rem_min,efficiency,resting_hr_bpm,hrv_rmssd_ms,
      stages,algorithm_version,computed_at)
    values(md5('legacy-sleep-v3|'||p_user||'|'||dev||'|'||p_day||'|'||p_version||'|'||(n->>'id'))::uuid,
      p_user,dev,p_day,(n->>'start_at')::timestamptz,(n->>'end_at')::timestamptz,
      (n->>'is_nap')::boolean,(n->>'in_bed_min')::numeric,(n->>'asleep_min')::numeric,(n->>'awake_min')::numeric,
      (n->>'light_min')::numeric,(n->>'deep_min')::numeric,(n->>'rem_min')::numeric,(n->>'efficiency')::numeric,
      (n->>'resting_hr_bpm')::numeric,(n->>'hrv_rmssd_ms')::numeric,n->'stages',p_version,s.computed_at);
  end loop;
end $$;

-- A day whose projection fails (for example a sleep row that collides with another night's start_at) is
-- reported and skipped so one bad day cannot block the rest; the return value is the number refreshed.
create or replace function public.reproject_scoring_legacy_v2(p_user uuid default null,p_algorithm_version text default null)
returns integer language plpgsql security definer set search_path=public as $$
declare r record; refreshed integer:=0;
begin
  for r in select distinct user_id,day,algorithm_version from scoring_snapshots_v2
    where (p_user is null or user_id=p_user)
      and (p_algorithm_version is null or algorithm_version=p_algorithm_version)
    order by user_id,day,algorithm_version loop
    begin
      perform refresh_scoring_legacy_v2(r.user_id,r.day,r.algorithm_version);
      refreshed:=refreshed+1;
    exception when others then
      raise warning 'reproject_scoring_legacy_v2 skipped % % %: % (%)',
        r.user_id,r.day,r.algorithm_version,sqlerrm,sqlstate;
    end;
  end loop;
  return refreshed;
end $$;

revoke all on function public.reproject_scoring_legacy_v2(uuid,text) from public, anon, authenticated;
grant execute on function public.reproject_scoring_legacy_v2(uuid,text) to service_role;

do $$ declare refreshed integer;
begin
  refreshed:=public.reproject_scoring_legacy_v2();
  raise notice 'reproject_scoring_legacy_v2: % owner-day(s) refreshed', refreshed;
end $$;

notify pgrst, 'reload schema';
commit;
