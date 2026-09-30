-- Deployed definition for public.noop_project_append_batch_core
-- Captured from live DB (READ-ONLY), UTC 2026-09-30T08:14:17.961592
-- Command: psql -tA --pset pager=off -c "SELECT pg_get_functiondef(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='noop_project_append_batch_core';"
CREATE OR REPLACE FUNCTION public.noop_project_append_batch_core(p_user uuid, p_device uuid, p_source uuid, p_batch uuid, p_stream text, p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target_table text; conflict_columns text; columns_sql text; updates_sql text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'service role required' using errcode='42501';
  end if;
  select table_name,conflict_key into target_table,conflict_columns from (values
    ('hrSample','noop_hr_samples','user_id,device_id,ts'),
    ('rrInterval','noop_rr_intervals','user_id,device_id,ts,"rrMs",seq'),
    ('rrPacketProvenance','noop_rr_packet_provenance','user_id,device_id,"packetId"'),
    ('standardHRReceipt','noop_standard_hr_receipts','user_id,device_id,"receiptId"'),
    ('stepSample','noop_step_samples','user_id,device_id,ts'),
    ('sleepStateSample','noop_sleep_state_samples','user_id,device_id,ts'),
    ('ppgHrSample','noop_ppg_hr_samples','user_id,device_id,ts'),
    ('event','noop_events','user_id,device_id,ts,kind'),
    ('battery','noop_battery_samples','user_id,device_id,ts'),
    ('spo2Sample','noop_spo2_samples','user_id,device_id,ts'),
    ('skinTempSample','noop_skin_temp_samples','user_id,device_id,ts'),
    ('respSample','noop_resp_samples','user_id,device_id,ts'),
    ('gravitySample','noop_gravity_samples','user_id,device_id,ts')
  ) allowed(stream,table_name,conflict_key) where stream=p_stream;
  if target_table is null then raise exception 'unsupported append stream' using errcode='22023'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception 'append rows must be an array' using errcode='22023';
  end if;
  if jsonb_array_length(p_rows) not between 1 and 5000 then
    raise exception 'append batch size out of bounds' using errcode='22023';
  end if;
  if p_batch is null or not exists(select 1 from public.devices where id=p_device and user_id=p_user)
      or not exists(select 1 from public.noop_app_installations
        where source_id=p_source and user_id=p_user and revoked_at is null) then
    raise exception 'owned device and active installation required' using errcode='42501';
  end if;
  if exists(select 1 from jsonb_array_elements(p_rows) r where jsonb_typeof(r)<>'object'
      or (r->>'user_id')::uuid is distinct from p_user
      or (r->>'device_id')::uuid is distinct from p_device
      or (r->>'source_id')::uuid is distinct from p_source
      or (r->>'batch_id')::uuid is distinct from p_batch) then
    raise exception 'append row identity mismatch' using errcode='42501';
  end if;
  if exists(select 1 from jsonb_array_elements(p_rows) r cross join lateral jsonb_object_keys(r) k
      where not exists(select 1 from pg_catalog.pg_attribute a
        where a.attrelid=to_regclass('public.'||target_table) and a.attname=k
          and a.attnum>0 and not a.attisdropped and a.attgenerated='')) then
    raise exception 'unknown append column' using errcode='22023';
  end if;
  select string_agg(format('%I',k),',' order by k),
    string_agg(format('%I=excluded.%I',k,k),',' order by k)
    into columns_sql,updates_sql
    from (select distinct k from jsonb_array_elements(p_rows) r
      cross join lateral jsonb_object_keys(r) k) keys;

  if not pg_try_advisory_xact_lock_shared(
      hashtextextended('physiology-input:'||p_user::text||':'||p_device::text,230919)) then
    raise exception 'scoring_input_gate_busy' using errcode='55P03';
  end if;
  execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I,$1)
    on conflict (%s) do update set %s',target_table,columns_sql,columns_sql,target_table,conflict_columns,updates_sql)
    using p_rows;
  return jsonb_array_length(p_rows);
end $function$

