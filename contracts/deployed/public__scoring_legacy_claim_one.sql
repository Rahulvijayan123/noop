-- Deployed definition for public.scoring_legacy_claim_one
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:34.902720
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='scoring_legacy_claim_one';"
CREATE OR REPLACE FUNCTION public.scoring_legacy_claim_one(p_lease_seconds integer DEFAULT 300, p_max_failures integer DEFAULT 8, p_user uuid DEFAULT NULL::uuid, p_device uuid DEFAULT NULL::uuid, p_day date DEFAULT NULL::date)
 RETURNS SETOF scoring_work_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare previous text:=current_setting('physiology.legacy_queue_write',true); candidate record; claimed public.scoring_work_items;
begin
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  for candidate in select w.user_id,w.device_id,w.day from public.scoring_work_items w
    join public.devices d on d.id=w.device_id and d.user_id=w.user_id and d.is_active
    where w.done_at is null and w.next_attempt_at<=clock_timestamp()
      and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
      and (w.failure_revision<>w.input_revision or w.consecutive_failures<p_max_failures)
      and not exists(select 1 from public.noop_account_retirements r where r.user_id=w.user_id)
      and (p_user is null or w.user_id=p_user) and (p_device is null or w.device_id=p_device)
      and (p_day is null or w.day=p_day)
    order by w.next_attempt_at,w.dirty_at,w.user_id,w.device_id,w.day limit 64
  loop
    -- Match lifecycle -> device -> queue lock order without waiting behind another claimant.
    if not pg_try_advisory_xact_lock(hashtextextended('account-admission:'||candidate.user_id::text,0)) then continue; end if;
    if not pg_try_advisory_xact_lock(hashtextextended(candidate.user_id::text||':'||candidate.device_id::text,230918)) then continue; end if;
    perform public.noop_intake_canary_validate(candidate.user_id,candidate.device_id);
    select w.* into claimed from public.scoring_work_items w
      where w.user_id=candidate.user_id and w.device_id=candidate.device_id and w.day=candidate.day
        and w.done_at is null and w.next_attempt_at<=clock_timestamp()
        and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp()) for update skip locked;
    if not found then continue; end if;
    update public.scoring_work_items w set claimed_at=clock_timestamp(),claimed_revision=w.input_revision,
      claimed_measurement_revision=w.measurement_revision,claimed_timezone_id=w.timezone_id,
      snapshot_transaction_id=txid_current(),snapshot_captured_at=null,newer_dirty_at=null,
      lease_token=gen_random_uuid(),run_id=gen_random_uuid(),status='running',
      lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
    where w.user_id=candidate.user_id and w.device_id=candidate.device_id and w.day=candidate.day returning * into claimed;
    return next claimed;
    exit;
  end loop;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
end $function$

