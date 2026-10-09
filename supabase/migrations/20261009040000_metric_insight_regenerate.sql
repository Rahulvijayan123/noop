-- Regenerate a metric explanation on request (the "Regenerate" button on the key-metric screens).
--
-- The request RPC answers `ready` from the cache while the inputs are unchanged, so a second request never
-- re-runs the analysis. This function marks the current explanation as out of date (its fingerprint becomes a
-- value no inputs can produce) and then makes the ordinary request: the request sees an explanation that does
-- not match the inputs, queues the insight worker (input_revision + 1) and returns the old text marked stale
-- while the new one is written. The worker publishes under the job's real fingerprint, which supersedes the
-- marked row. Nothing new is writable by the app: the daily bound of 8 runs per metric still applies at the
-- claim, and a metric at its bound answers `unavailable` / `daily_limit` with its old text.
--
-- Additive and safe to re-run. Rollback: drop function public.metric_insight_regenerate_v1(uuid, text).

create or replace function public.metric_insight_regenerate_v1(p_user uuid, p_metric text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  j public.metric_insight_jobs;
  v_today date := (pg_catalog.now() at time zone 'UTC')::date;
  v_now timestamptz := pg_catalog.clock_timestamp();
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_user is null then
    raise exception 'invalid_arguments' using errcode = '22023';
  end if;
  if p_metric is null or p_metric not in ('resting_hr', 'hrv_rmssd', 'hrv_sdnn', 'skin_temp', 'resp_rate', 'spo2', 'heart_rate', 'steps', 'calories') then
    raise exception 'invalid_metric' using errcode = '22023';
  end if;

  -- A metric at its daily bound is not marked: its explanation stays current and the request says why.
  select * into j from public.metric_insight_jobs q where q.user_id = p_user and q.metric = p_metric;
  if found and j.runs_day = v_today and j.runs_count >= 8
     and (j.lease_until is null or j.lease_until <= v_now) then
    return public.metric_insight_request_v1(p_user, p_metric);
  end if;

  update public.metric_insights m set input_fingerprint = pg_catalog.repeat('0', 64)
   where m.user_id = p_user and m.metric = p_metric and m.superseded_at is null;
  return public.metric_insight_request_v1(p_user, p_metric);
end $$;

revoke all on function public.metric_insight_regenerate_v1(uuid, text) from public, anon, authenticated;
grant execute on function public.metric_insight_regenerate_v1(uuid, text) to service_role;
