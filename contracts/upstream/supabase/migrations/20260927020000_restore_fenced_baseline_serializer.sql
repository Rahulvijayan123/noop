-- Restore the frozen baseline serializer after the observed function-body inversion.
-- The hosted publisher reached the private denial stub and returned HTTP403 after
-- computation. Restore its original serializer while retaining the PUBLIC denial;
-- restoring only the private body would reopen the unfenced rolling-upgrade entry.
-- No result, queue, lease, recovery run, revision or archive row is changed here.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create or replace function internal.engine_ingest_scored(p_secret text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_version text;
  r jsonb;
  n_daily integer := 0;
  n_nights integer := 0;
begin
  perform internal.assert_ingest_secret(p_secret);
  v_user := nullif(p_payload->>'user_id', '')::uuid;
  if v_user is null then
    raise exception 'user_id required';
  end if;
  v_version := nullif(p_payload->>'algorithm_version', '');
  if v_version is null then
    raise exception 'algorithm_version required';
  end if;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'daily_metrics', '[]'::jsonb))
  loop
    insert into public.server_daily_scores (
      user_id, day, algorithm_version, source_device_id,
      hrv_rmssd_ms, hrv_sdnn_ms, resting_hr_bpm, overnight_hr_bpm, readiness_level,
      sleep_total_min, sleep_in_bed_min, sleep_awake_min,
      sleep_light_min, sleep_deep_min, sleep_rem_min,
      sleep_efficiency, sleep_onset_at, wake_onset_at, disturbances,
      resp_rate_bpm, skin_temp_c, skin_temp_dev_c, spo2_pct,
      confidence, provenance, computed_at
    ) values (
      v_user,
      (r->>'day')::date,
      v_version,
      nullif(r->>'source_device_id', '')::uuid,
      nullif(r->>'hrv_rmssd_ms', '')::numeric,
      nullif(r->>'hrv_sdnn_ms', '')::numeric,
      nullif(r->>'resting_hr_bpm', '')::numeric,
      nullif(r->>'overnight_hr_bpm', '')::numeric,
      nullif(r->>'readiness_level', ''),
      nullif(r->>'sleep_total_min', '')::numeric,
      nullif(r->>'sleep_in_bed_min', '')::numeric,
      nullif(r->>'sleep_awake_min', '')::numeric,
      nullif(r->>'sleep_light_min', '')::numeric,
      nullif(r->>'sleep_deep_min', '')::numeric,
      nullif(r->>'sleep_rem_min', '')::numeric,
      nullif(r->>'sleep_efficiency', '')::numeric,
      nullif(r->>'sleep_onset_at', '')::timestamptz,
      nullif(r->>'wake_onset_at', '')::timestamptz,
      nullif(r->>'disturbances', '')::integer,
      nullif(r->>'resp_rate_bpm', '')::numeric,
      nullif(r->>'skin_temp_c', '')::numeric,
      nullif(r->>'skin_temp_dev_c', '')::numeric,
      nullif(r->>'spo2_pct', '')::numeric,
      coalesce(r->'confidence', '{}'::jsonb),
      coalesce(r->'provenance', '{}'::jsonb),
      coalesce(nullif(r->>'computed_at', '')::timestamptz, now())
    )
    on conflict (user_id, day, algorithm_version) do update set
      source_device_id = excluded.source_device_id,
      hrv_rmssd_ms = excluded.hrv_rmssd_ms,
      hrv_sdnn_ms = excluded.hrv_sdnn_ms,
      resting_hr_bpm = excluded.resting_hr_bpm,
      overnight_hr_bpm = excluded.overnight_hr_bpm,
      readiness_level = excluded.readiness_level,
      sleep_total_min = excluded.sleep_total_min,
      sleep_in_bed_min = excluded.sleep_in_bed_min,
      sleep_awake_min = excluded.sleep_awake_min,
      sleep_light_min = excluded.sleep_light_min,
      sleep_deep_min = excluded.sleep_deep_min,
      sleep_rem_min = excluded.sleep_rem_min,
      sleep_efficiency = excluded.sleep_efficiency,
      sleep_onset_at = excluded.sleep_onset_at,
      wake_onset_at = excluded.wake_onset_at,
      disturbances = excluded.disturbances,
      resp_rate_bpm = excluded.resp_rate_bpm,
      skin_temp_c = excluded.skin_temp_c,
      skin_temp_dev_c = excluded.skin_temp_dev_c,
      spo2_pct = excluded.spo2_pct,
      confidence = excluded.confidence,
      provenance = excluded.provenance,
      computed_at = excluded.computed_at;
    n_daily := n_daily + 1;
  end loop;

  for r in select value from jsonb_array_elements(coalesce(p_payload->'sleep_nights', '[]'::jsonb))
  loop
    insert into public.server_sleep_nights (
      user_id, device_id, period_day, start_at, end_at, is_nap,
      in_bed_min, asleep_min, awake_min, light_min, deep_min, rem_min,
      efficiency, overnight_hr_bpm, resting_hr_bpm, hrv_rmssd_ms,
      resp_rate_bpm, disturbances, stages, hypnogram,
      algorithm_version, computed_at
    ) values (
      v_user,
      nullif(r->>'device_id', '')::uuid,
      (r->>'period_day')::date,
      (r->>'start_at')::timestamptz,
      (r->>'end_at')::timestamptz,
      coalesce((r->>'is_nap')::boolean, false),
      nullif(r->>'in_bed_min', '')::numeric,
      nullif(r->>'asleep_min', '')::numeric,
      nullif(r->>'awake_min', '')::numeric,
      nullif(r->>'light_min', '')::numeric,
      nullif(r->>'deep_min', '')::numeric,
      nullif(r->>'rem_min', '')::numeric,
      nullif(r->>'efficiency', '')::numeric,
      nullif(r->>'overnight_hr_bpm', '')::numeric,
      nullif(r->>'resting_hr_bpm', '')::numeric,
      nullif(r->>'hrv_rmssd_ms', '')::numeric,
      nullif(r->>'resp_rate_bpm', '')::numeric,
      nullif(r->>'disturbances', '')::integer,
      coalesce(r->'stages', '[]'::jsonb),
      coalesce(r->'hypnogram', '[]'::jsonb),
      v_version,
      coalesce(nullif(r->>'computed_at', '')::timestamptz, now())
    )
    on conflict (user_id, start_at, algorithm_version) do update set
      device_id = excluded.device_id,
      period_day = excluded.period_day,
      end_at = excluded.end_at,
      is_nap = excluded.is_nap,
      in_bed_min = excluded.in_bed_min,
      asleep_min = excluded.asleep_min,
      awake_min = excluded.awake_min,
      light_min = excluded.light_min,
      deep_min = excluded.deep_min,
      rem_min = excluded.rem_min,
      efficiency = excluded.efficiency,
      overnight_hr_bpm = excluded.overnight_hr_bpm,
      resting_hr_bpm = excluded.resting_hr_bpm,
      hrv_rmssd_ms = excluded.hrv_rmssd_ms,
      resp_rate_bpm = excluded.resp_rate_bpm,
      disturbances = excluded.disturbances,
      stages = excluded.stages,
      hypnogram = excluded.hypnogram,
      computed_at = excluded.computed_at;
    n_nights := n_nights + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'user_id', v_user,
    'algorithm_version', v_version,
    'daily_metrics', n_daily,
    'sleep_nights', n_nights
  );
end;
$$;

create or replace function public.engine_ingest_scored(p_secret text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
  raise exception 'token-aware baseline publication required' using errcode='42501';
end $$;

revoke all on function internal.engine_ingest_scored(text,jsonb),
  public.engine_ingest_scored_legacy_internal(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.engine_ingest_scored(text,jsonb) from public,anon,authenticated;
grant execute on function public.engine_ingest_scored(text,jsonb) to service_role;
comment on function internal.engine_ingest_scored(text,jsonb) is
  'Frozen original baseline serializer; private implementation reachable through fenced publication only.';
comment on function public.engine_ingest_scored(text,jsonb) is
  'Denied unfenced baseline publication; use the owner/device/revision/lease-fenced publisher.';

notify pgrst,'reload schema';
commit;
