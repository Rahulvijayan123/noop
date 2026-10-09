-- A night that crosses midnight cannot be republished for one day while the other day holds it.
--
-- WHY: refresh_scoring_legacy_v2 rewrites server_sleep_nights for one (user, day, version). It deletes
-- that day's rows, then inserts one row per snapshot night with an id derived from the day. A night
-- that crosses midnight is in both neighbouring days' payloads, and the legacy ingest upserts nights
-- on (user_id, start_at, algorithm_version), which moves the row to its own period_day and keeps the
-- id. The next refresh of the first day misses that row in its delete and fails on the primary key
-- (or on the start_at key) on every attempt; inside publish_scoring_snapshot_v2 that rolls the claim
-- back and keeps the user first in the v2 queue.
--
-- WHAT CHANGES: before inserting, the refresh also deletes this user's rows that hold one of the
-- snapshot's nights under another day (same start_at or same derived id), so the night moves to the
-- day being refreshed, as the legacy ingest already does in the other direction. The rest of the
-- function is unchanged.

begin;

create or replace function public.refresh_scoring_legacy_v2(p_user uuid, p_day date, p_version text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
  delete from server_sleep_nights x
   using jsonb_array_elements(coalesce(s.payload->'sleep','[]'::jsonb)) e
   where x.user_id=p_user and x.algorithm_version=p_version
     and (x.start_at=(e->>'start_at')::timestamptz
          or x.id=md5('legacy-sleep-v3|'||p_user||'|'||dev||'|'||p_day||'|'||p_version||'|'||(e->>'id'))::uuid);
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
end $function$;

commit;
