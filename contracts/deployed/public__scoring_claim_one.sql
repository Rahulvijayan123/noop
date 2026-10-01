-- Deployed definition for public.scoring_claim_one
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:26.985464
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='scoring_claim_one';"
CREATE OR REPLACE FUNCTION public.scoring_claim_one(p_lease_seconds integer DEFAULT 300, p_max_failures integer DEFAULT 8, p_user uuid DEFAULT NULL::uuid, p_device uuid DEFAULT NULL::uuid, p_day date DEFAULT NULL::date)
 RETURNS SETOF scoring_work_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare c record; w public.scoring_work_items%rowtype; ticket bigint;
begin
  -- A short scheduler transaction, never held while loading inputs or computing.
  perform pg_advisory_xact_lock(21112000);
  delete from public.scoring_fleet_reservations where expires_at<=clock_timestamp();
  select * into c from public.scoring_fleet_candidates
    where (p_user is null or user_id=p_user) and (p_device is null or device_id=p_device)
      and (p_day is null or day=p_day)
      and (failure_revision<>input_revision or consecutive_failures<p_max_failures)
    order by class_rank,last_dispatch,next_attempt_at,dirty_at,user_id,device_id,day limit 1;
  if not found then return; end if;
  select * into w from public.scoring_claim_one_core(p_lease_seconds,p_max_failures,c.user_id,c.device_id,c.day);
  if not found then return; end if;
  update public.scoring_fleet_policy set dispatches=dispatches+1 returning dispatches into ticket;
  insert into public.scoring_fleet_tenants values(w.user_id,ticket)
    on conflict(user_id) do update set last_dispatch=excluded.last_dispatch;
  insert into public.scoring_fleet_reservations(lease_token,user_id,device_id,day,work_class,input_revision,
    run_id,queued_at,expires_at) values(w.lease_token,w.user_id,w.device_id,w.day,c.work_class,w.input_revision,
      w.run_id,w.dirty_at,w.lease_expires_at);
  return next w;
end $function$

