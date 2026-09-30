-- Deployed definition for public.scoring_legacy_seal_snapshot
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:35.488569
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='scoring_legacy_seal_snapshot';"
CREATE OR REPLACE FUNCTION public.scoring_legacy_seal_snapshot(p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  if current_setting('transaction_isolation')<>'repeatable read' then
    raise exception 'baseline snapshot requires repeatable read' using errcode='25001';
  end if;
  perform public.noop_intake_canary_validate(p_user,p_device);
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  update public.scoring_work_items set snapshot_captured_at=clock_timestamp()
    where user_id=p_user and device_id=p_device and day=p_day and input_revision=p_revision
      and claimed_revision=p_revision and lease_token=p_lease_token and run_id=p_run_id
      and status='running' and lease_expires_at>clock_timestamp()
      and snapshot_transaction_id=txid_current() and snapshot_captured_at is null;
  if not found then raise exception 'baseline snapshot claim changed' using errcode='40001'; end if;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
end $function$

