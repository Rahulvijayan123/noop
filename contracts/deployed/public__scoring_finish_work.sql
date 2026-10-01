-- Deployed definition for public.scoring_finish_work
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:27.539450
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='scoring_finish_work';"
CREATE OR REPLACE FUNCTION public.scoring_finish_work(p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer DEFAULT NULL::integer, p_error text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare finished boolean; r public.scoring_fleet_reservations%rowtype;
begin
  -- The original function still owns all publication, revision and lease validation.
  finished:=public.scoring_finish_work_core(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id,
    p_outcome,p_duration_ms,p_error);
  delete from public.scoring_fleet_reservations where lease_token=p_lease_token and user_id=p_user
    and device_id=p_device and day=p_day and input_revision=p_revision and run_id=p_run_id returning * into r;
  if found then
    insert into public.scoring_fleet_completions(run_id,user_id,work_class,outcome,queue_seconds,service_seconds,latency_seconds)
      values(r.run_id,r.user_id,r.work_class,case when finished then p_outcome else 'superseded' end,
        greatest(0,extract(epoch from r.acquired_at-r.queued_at)),
        greatest(0,extract(epoch from clock_timestamp()-r.acquired_at)),
        greatest(0,extract(epoch from clock_timestamp()-r.queued_at))) on conflict do nothing;
  end if;
  return finished;
end $function$

