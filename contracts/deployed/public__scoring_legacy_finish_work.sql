-- Deployed definition for public.scoring_legacy_finish_work
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:36.282963
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='scoring_legacy_finish_work';"
CREATE OR REPLACE FUNCTION public.scoring_legacy_finish_work(p_user uuid, p_device uuid, p_day date, p_revision bigint, p_lease_token uuid, p_run_id uuid, p_outcome text, p_duration_ms integer DEFAULT NULL::integer, p_error text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare failures integer; newer boolean; previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  if p_outcome not in ('done','waiting','failed') then raise exception 'invalid outcome'; end if;
  begin
    perform public.scoring_legacy_begin_publication(p_user,p_device,p_day,p_revision,p_lease_token,p_run_id);
  exception when serialization_failure then return false; end;
  select input_revision>p_revision,case when failure_revision=p_revision then consecutive_failures else 0 end
    into newer,failures from public.scoring_work_items where user_id=p_user and device_id=p_device and day=p_day;
  if p_outcome='failed' and not newer then failures:=failures+1;
  elsif p_outcome='done' or newer then failures:=0; end if;
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  update public.scoring_work_items set done_at=case when p_outcome='done' and not newer then clock_timestamp() end,
    dirty_at=case when newer then coalesce(newer_dirty_at,dirty_at) else dirty_at end,newer_dirty_at=null,
    claimed_at=null,claimed_revision=null,claimed_measurement_revision=null,claimed_timezone_id=null,
    snapshot_transaction_id=null,snapshot_captured_at=null,lease_token=null,run_id=null,lease_expires_at=null,
    consecutive_failures=failures,failure_revision=input_revision,attempts=failures,
    status=case when newer then 'pending' when p_outcome='failed'
      then case when failures>=8 then 'exhausted' else 'retry' end else p_outcome end,
    next_attempt_at=case when newer then coalesce(newer_dirty_at,clock_timestamp())
      else clock_timestamp()+make_interval(secs=>case when p_outcome='failed'
        then least(3600,5*power(2,least(failures-1,10))) when p_outcome='waiting' then 300 else 0 end) end,
    last_error=case when p_outcome='done' or newer then null else left(p_error,2000) end,last_duration_ms=p_duration_ms
  where user_id=p_user and device_id=p_device and day=p_day;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
  return true;
end $function$

