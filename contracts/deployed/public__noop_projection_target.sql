-- Deployed definition for public.noop_projection_target
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:18.900437
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_projection_target';"
CREATE OR REPLACE FUNCTION public.noop_projection_target(p_stream text)
 RETURNS TABLE(table_name text, key_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select table_name,key_columns from (values
    ('hrSample','noop_hr_samples',array['ts']),
    ('rrInterval','noop_rr_intervals',array['ts','rrMs','seq']),
    ('rrPacketProvenance','noop_rr_packet_provenance',array['sensorTs','recordIndex']),
    ('standardHRReceipt','noop_standard_hr_receipts',array['receiptId']),
    ('stepSample','noop_step_samples',array['ts']),
    ('sleepStateSample','noop_sleep_state_samples',array['ts']),
    ('ppgHrSample','noop_ppg_hr_samples',array['ts']),
    ('event','noop_events',array['ts','kind']),
    ('battery','noop_battery_samples',array['ts']),
    ('spo2Sample','noop_spo2_samples',array['ts']),
    ('skinTempSample','noop_skin_temp_samples',array['ts']),
    ('respSample','noop_resp_samples',array['ts']),
    ('gravitySample','noop_gravity_samples',array['ts'])
  ) t(stream,table_name,key_columns) where stream=p_stream;
$function$

