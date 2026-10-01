-- Matched snapshot-aware baseline required. No existing publication or source is rewritten.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

alter table public.scoring_work_items
  add column snapshot_transaction_id bigint,
  add column snapshot_captured_at timestamptz,
  add column claimed_measurement_revision bigint,
  add column claimed_timezone_id text,
  add column newer_dirty_at timestamptz,
  add column minimum_readable_revision bigint not null default 0;

-- The independent v2 claim RPC historically returns the v1 composite type. Keep
-- its existing columns by name without pretending that v2 owns a v1 snapshot.
-- A positional RETURNING w.* would break every v2 claim after the columns above.
create or replace function public.scoring_claim_one_core(p_lease_seconds integer default 300,p_max_failures integer default 8,
  p_user uuid default null,p_device uuid default null,p_day date default null)
returns setof public.scoring_work_items language plpgsql security definer set search_path='' as $$
begin
  return query with candidate as (
    select w.user_id,w.device_id,w.day from public.physiology_work_items w
    where w.done_at is null and w.next_attempt_at<=clock_timestamp()
      and (w.lease_expires_at is null or w.lease_expires_at<=clock_timestamp())
      and (w.failure_revision<>w.input_revision or w.consecutive_failures<p_max_failures)
      and (p_user is null or w.user_id=p_user) and (p_device is null or w.device_id=p_device)
      and (p_day is null or w.day=p_day)
    order by w.next_attempt_at,w.dirty_at,w.user_id,w.device_id,w.day
    for update skip locked limit 1
  ) update public.physiology_work_items w set claimed_at=clock_timestamp(),claimed_revision=w.input_revision,
    lease_token=gen_random_uuid(),run_id=gen_random_uuid(),status='running',
    lease_expires_at=clock_timestamp()+make_interval(secs=>greatest(1,least(p_lease_seconds,3600)))
  from candidate c where w.user_id=c.user_id and w.device_id=c.device_id and w.day=c.day
  returning (jsonb_populate_record(null::public.scoring_work_items,to_jsonb(w))).*;
end $$;

-- A pre-upgrade lease cannot attest to an atomic input snapshot. Release only that
-- authority; keep input debt, immutable publications and all source bytes.
do $$
declare previous text:=current_setting('physiology.legacy_queue_write',true);
begin
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  update public.scoring_work_items set claimed_at=null,claimed_revision=null,lease_token=null,
    run_id=null,lease_expires_at=null,done_at=null,status='pending',
    next_attempt_at=least(next_attempt_at,clock_timestamp()) where lease_token is not null;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
end $$;

create or replace function public.scoring_enqueue_legacy_fenced(p_user uuid,p_device uuid,p_day date,p_timezone text,
  p_debounce_seconds integer default 0) returns bigint
language plpgsql security definer set search_path='' as $$
declare revision bigint; previous text:=current_setting('physiology.legacy_queue_write',true);
  append_only boolean:=current_setting('physiology.legacy_append_only',true)=txid_current()::text;
  w public.scoring_work_items%rowtype; preserve_snapshot boolean; due timestamptz;
begin
  perform public.scoring_lock_device(p_user,p_device);
  if not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'device does not belong to user' using errcode='23503';
  end if;
  if not exists(select 1 from pg_timezone_names where name=p_timezone) then
    raise exception 'invalid timezone' using errcode='22023';
  end if;
  due:=clock_timestamp()+make_interval(secs=>greatest(0,least(p_debounce_seconds,2)));
  perform set_config('physiology.legacy_queue_write',txid_current()::text,true);
  select * into w from public.scoring_work_items where user_id=p_user and device_id=p_device and day=p_day for update;
  if not found then
    insert into public.scoring_work_items(user_id,device_id,day,timezone_id,dirty_at,next_attempt_at)
      values(p_user,p_device,p_day,p_timezone,clock_timestamp(),due) returning input_revision into revision;
  else
    preserve_snapshot:=coalesce(append_only,false) and w.status='running' and w.snapshot_captured_at is not null
      and w.lease_expires_at>clock_timestamp() and w.claimed_timezone_id=p_timezone;
    update public.scoring_work_items set input_revision=w.input_revision+1,
      measurement_revision=w.measurement_revision+1,failure_revision=w.input_revision+1,
      timezone_id=p_timezone,
      minimum_readable_revision=case when coalesce(append_only,false) and w.timezone_id=p_timezone
        then w.minimum_readable_revision else w.input_revision+1 end,
      dirty_at=case when w.done_at is null then w.dirty_at else clock_timestamp() end,
      newer_dirty_at=case when preserve_snapshot then coalesce(w.newer_dirty_at,clock_timestamp()) end,
      done_at=null,claimed_at=case when preserve_snapshot then w.claimed_at end,
      claimed_revision=case when preserve_snapshot then w.claimed_revision end,
      claimed_measurement_revision=case when preserve_snapshot then w.claimed_measurement_revision end,
      claimed_timezone_id=case when preserve_snapshot then w.claimed_timezone_id end,
      snapshot_transaction_id=case when preserve_snapshot then w.snapshot_transaction_id end,
      snapshot_captured_at=case when preserve_snapshot then w.snapshot_captured_at end,
      lease_token=case when preserve_snapshot then w.lease_token end,run_id=case when preserve_snapshot then w.run_id end,
      lease_expires_at=case when preserve_snapshot then w.lease_expires_at end,
      attempts=0,consecutive_failures=0,status=case when preserve_snapshot then 'running' else 'pending' end,last_error=null,
      next_attempt_at=case when w.done_at is null and w.status in ('pending','running')
        then least(w.next_attempt_at,due) else due end
    where user_id=p_user and device_id=p_device and day=p_day returning input_revision into revision;
  end if;
  perform set_config('physiology.legacy_queue_write',coalesce(previous,''),true);
  return revision;
end $$;

create or replace function public.scoring_legacy_claim_one(p_lease_seconds integer default 300,p_max_failures integer default 8,
  p_user uuid default null,p_device uuid default null,p_day date default null)
returns setof public.scoring_work_items language plpgsql security definer set search_path='' as $$
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
end $$;

create function public.scoring_legacy_seal_snapshot(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid) returns void language plpgsql security definer set search_path='' as $$
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
end $$;
revoke all on function public.scoring_legacy_seal_snapshot(uuid,uuid,date,bigint,uuid,uuid) from public,anon,authenticated;
grant execute on function public.scoring_legacy_seal_snapshot(uuid,uuid,date,bigint,uuid,uuid) to service_role;

create or replace function public.scoring_legacy_begin_publication(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare w public.scoring_work_items%rowtype;
begin
  perform public.noop_intake_canary_validate(p_user,p_device);
  perform public.scoring_lock_device(p_user,p_device);
  select * into w from public.scoring_work_items q where q.user_id=p_user and q.device_id=p_device and q.day=p_day for update;
  if not found or w.claimed_revision is distinct from p_revision or w.input_revision<p_revision
    or w.minimum_readable_revision>p_revision or w.snapshot_captured_at is null
    or w.claimed_measurement_revision is null or w.claimed_timezone_id is null
    or w.lease_token is distinct from p_lease_token or w.run_id is distinct from p_run_id
    or w.lease_token is null or w.run_id is null or w.lease_expires_at is null
    or w.lease_expires_at<=clock_timestamp() or w.status<>'running' then
    raise exception 'stale scoring lease or input revision' using errcode='40001';
  end if;
  if exists(select 1 from public.server_physiology_results r where r.user_id=p_user and r.device_id=p_device
    and r.period_day=p_day and r.algorithm_version='frwhoop-server-1' and r.input_revision>p_revision) then
    raise exception 'newer baseline already published' using errcode='40001';
  end if;
end $$;

create or replace function public.scoring_legacy_finish_work(p_user uuid,p_device uuid,p_day date,p_revision bigint,
  p_lease_token uuid,p_run_id uuid,p_outcome text,p_duration_ms integer default null,p_error text default null)
returns boolean language plpgsql security definer set search_path='' as $$
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
end $$;

create or replace function public.scoring_capture_measurement_revision() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform public.scoring_lock_device(new.user_id,new.device_id);
  if new.algorithm_version='frwhoop-server-1' then
    select q.claimed_measurement_revision into new.measurement_revision from public.scoring_work_items q
      where q.user_id=new.user_id and q.device_id=new.device_id and q.day=new.period_day
        and q.claimed_revision=new.input_revision and q.run_id=new.run_id and q.snapshot_captured_at is not null for update;
  else
    select q.measurement_revision into new.measurement_revision from public.physiology_work_items q
      where q.user_id=new.user_id and q.device_id=new.device_id and q.day=new.period_day
        and q.input_revision=new.input_revision for update;
  end if;
  if new.measurement_revision is null then raise exception 'measurement snapshot is no longer owned' using errcode='40001'; end if;
  return new;
end $$;

-- Projection append marker, immutable publication calendar, and withdrawal read fence follow.

create or replace function public.scoring_dirty_projection() returns trigger language plpgsql security definer
set search_path='' as $$
declare q text; r record; previous text:=current_setting('physiology.legacy_append_only',true);
begin
  if tg_op='UPDATE' then
    q := '(select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] as j from new_rows n
      except select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o)
      union (select to_jsonb(o)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from old_rows o
      except select to_jsonb(n)-ARRAY[''ingested_at'',''updated_at'',''batch_id'',''replacement_id''] from new_rows n)';
  elsif tg_op='INSERT' then q := 'select to_jsonb(n) as j from new_rows n';
  else q := 'select to_jsonb(o) as j from old_rows o'; end if;
  for r in execute 'with changed as materialized ('||q||')
    select distinct d.user_id,d.id from (
      select distinct (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device
      from changed
    ) identities join public.devices d
      on d.user_id=identities.owner and (identities.device is null or d.id=identities.device)
      order by d.user_id,d.id'
  loop perform public.scoring_lock_device(r.user_id,r.id); end loop;
  for r in execute 'with changed as materialized ('||q||'), spans as (
    select (j->>''user_id'')::uuid as owner,(j->>''device_id'')::uuid as device,
      coalesce((j->>''ts'')::bigint,(j->>''start_ts'')::bigint,
        extract(epoch from (j->>''start_at'')::timestamptz)::bigint) as first_ts,
      coalesce((j->>''end_ts'')::bigint,extract(epoch from (j->>''end_at'')::timestamptz)::bigint,
        case when j->>''ts'' is not null then least((j->>''ts'')::numeric+1,9223372036854775807)::bigint end,
        case when j->>''start_ts'' is not null then least((j->>''start_ts'')::numeric+1,9223372036854775807)::bigint end) as last_ts
    from changed
  ), coalesced as (
    select owner,device,min(first_ts) as first_ts,max(last_ts) as last_ts from spans
    where first_ts is not null group by owner,device,first_ts/3600
  ) select distinct s.owner,d.id as device,a.day,a.timezone_id
    from coalesced s join public.devices d on d.user_id=s.owner and (s.device is null or d.id=s.device)
    cross join lateral public.scoring_affected_days(s.owner,s.first_ts,s.last_ts) a
    where s.first_ts is not null order by s.owner,d.id,a.day,a.timezone_id'
  loop
    perform set_config('physiology.legacy_append_only',case when tg_op='INSERT' and tg_table_name in (
      'noop_hr_samples','noop_rr_intervals','noop_resp_samples','noop_gravity_samples','noop_events',
      'noop_step_samples','noop_sleep_state_samples','noop_skin_temp_samples','noop_ppg_hr_samples',
      'noop_rr_packet_provenance','noop_standard_hr_receipts') then txid_current()::text else '' end,true);
    perform public.scoring_enqueue_day(r.owner,r.device,r.day,r.timezone_id);
    perform set_config('physiology.legacy_append_only',coalesce(previous,''),true);
  end loop;
  return null;
end $$;
create or replace function internal.engine_publish_legacy_fenced(p_secret text,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare u uuid:=(p_payload->>'user_id')::uuid; d uuid:=(p_payload->>'device_id')::uuid;
  period date:=(p_payload->>'day')::date; revision bigint:=(p_payload->>'input_revision')::bigint;
  token uuid:=(p_payload->>'lease_token')::uuid; run uuid:=(p_payload->>'run_id')::uuid;
  item jsonb; stored jsonb; manifest text; content_hash text; snapshot public.scoring_work_items;
begin
  perform internal.assert_ingest_secret(p_secret);
  if u is null or d is null or period is null or revision is null or token is null or run is null
      or p_payload->>'algorithm_version' is distinct from 'frwhoop-server-1' then
    raise exception 'baseline publication identity required' using errcode='22023';
  end if;
  -- A producer gate receipt is not a beat qualification or model approval. Only
  -- the explicit RR-excluded transport may assert this exact immutable marker.
  if p_payload ? 'input_eligibility' and p_payload->'input_eligibility' is distinct from
    '{"policy_version":"legacy-rr-excluded-1","rr_input":"excluded"}'::jsonb then
    raise exception 'invalid legacy input eligibility' using errcode='22023';
  end if;
  perform public.scoring_legacy_begin_publication(u,d,period,revision,token,run);
  select * into snapshot from public.scoring_work_items where user_id=u and device_id=d and day=period;
  if p_payload->>'revision_protocol' is distinct from 'fenced_snapshot_v1'
    or p_payload#>>'{calendar,policy_version}' is distinct from 'job-calendar-1'
    or p_payload#>>'{calendar,timezone_id}' is distinct from snapshot.claimed_timezone_id then
    raise exception 'baseline snapshot calendar required' using errcode='22023';
  end if;
  if not exists(select 1 from public.devices where id=d and user_id=u) then
    raise exception 'device owner mismatch' using errcode='42501';
  end if;
  if jsonb_typeof(p_payload->'daily_metrics') is distinct from 'array'
      or jsonb_array_length(p_payload->'daily_metrics')<>1
      or jsonb_typeof(p_payload->'sleep_nights') is distinct from 'array' then
    raise exception 'one baseline day and episode array required' using errcode='22023';
  end if;
  item:=p_payload->'daily_metrics'->0;
  if item->>'source_device_id' is distinct from d::text or item->>'day' is distinct from period::text
      or item->>'computed_at' is null then
    raise exception 'baseline daily owner mismatch' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(p_payload->'sleep_nights') loop
    if item->>'device_id' is distinct from d::text or item->>'period_day' is distinct from period::text
        or item->>'start_at' is null or item->>'end_at' is null
        or not ((item->>'end_at')::timestamptz>(item->>'start_at')::timestamptz) then
      raise exception 'baseline episode owner mismatch' using errcode='22023';
    end if;
  end loop;
  if exists(select 1 from public.server_physiology_results where user_id=u and device_id=d
      and period_day=period and algorithm_version='frwhoop-server-1' and input_revision=revision) then
    return jsonb_build_object('ok',true,'input_revision',revision);
  end if;
  -- The original serializer's upsert locks retain this device's serialized rows until
  -- its immutable snapshot is captured. Another device can never supply this snapshot.
  -- Do not call the pre-fence compatibility wrapper or acquire its inverted owner lock.
  perform internal.engine_ingest_scored(p_secret,p_payload);
  select manifest_hash into manifest from public.physiology_algorithm_versions where algorithm_version='frwhoop-server-1';
  stored:=public.scoring_legacy_snapshot(u,d,period)||jsonb_build_object(
    'nights',coalesce((select jsonb_agg(to_jsonb(n) order by n.start_at)
      from public.server_sleep_nights n where n.user_id=u and n.device_id=d and n.period_day=period
        and n.algorithm_version='frwhoop-server-1' and exists(
          select 1 from jsonb_array_elements(p_payload->'sleep_nights') e
          where (e->>'start_at')::timestamptz=n.start_at)),'[]'::jsonb),
    'schema_version',2,'user_id',u,'device_id',d,'day',period,'algorithm_version','frwhoop-server-1',
    'input_revision',revision,'run_id',run,'manifest_hash',manifest,'measurements','[]'::jsonb,
    'computed_at',p_payload#>'{daily_metrics,0,computed_at}','publication_status','provisional',
    'observed_through',null,'computation_mode','retrospective','revision_protocol','fenced_snapshot_v1',
    'snapshot_captured_at',snapshot.snapshot_captured_at,'calendar',p_payload->'calendar');
  if stored is null then raise exception 'baseline snapshot missing after serialization' using errcode='22023'; end if;
  if p_payload ? 'input_eligibility' then
    stored:=stored||jsonb_build_object('input_eligibility',p_payload->'input_eligibility');
  end if;
  content_hash:=encode(sha256(convert_to(stored::text,'UTF8')),'hex');
  insert into public.server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
    run_id,manifest_hash,payload,payload_hash,observed_through,computed_at,publication_status)
  values(u,d,period,'frwhoop-server-1',revision,run,manifest,stored,content_hash,null,
    (stored->>'computed_at')::timestamptz,'provisional');
  insert into public.physiology_archive_outbox(user_id,device_id,period_day,algorithm_version,input_revision,object_key)
  values(u,d,period,'frwhoop-server-1',revision,
    format('v3/derived/users/%s/devices/%s/days/%s/frwhoop-server-1/revisions/%s/%s.json.zst',u,d,period,revision,content_hash));
  return jsonb_build_object('ok',true,'input_revision',revision,'payload_hash',content_hash);
end $$;




create function public.scoring_legacy_minimum_readable_revision(p_user uuid,p_device uuid,p_day date)
returns bigint language plpgsql stable security definer set search_path='' as $$
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  return coalesce((select w.minimum_readable_revision from public.scoring_work_items w
    where w.user_id=p_user and w.device_id=p_device and w.day=p_day),0);
end $$;
revoke all on function public.scoring_legacy_minimum_readable_revision(uuid,uuid,date) from public,anon;
grant execute on function public.scoring_legacy_minimum_readable_revision(uuid,uuid,date) to authenticated,service_role;

create or replace function public.server_scoring_read_contract_before_signals(p_user uuid, p_day date, p_device uuid default null)
returns jsonb language plpgsql stable security invoker set search_path = pg_catalog, public as $$
declare
  feature_key text; device uuid; version text; result jsonb; stored_manifest text;
  expected_manifest text; expected_feature_manifest text;
  daily jsonb := '{}'::jsonb; nights jsonb := '[]'::jsonb;
  measurements jsonb := '[]'::jsonb; sleep_overrides jsonb := '[]'::jsonb;
  features jsonb := '{}'::jsonb; processing jsonb;
  current_revision bigint; result_revision bigint;
  is_stale boolean := false; feature_stale boolean;
  computed timestamptz; feature_computed timestamptz;
  key text; keys text[]; unavailable_reason text; feature_status text;
  selected_versions text[] := '{}'::text[]; selected_devices uuid[] := '{}'::uuid[];
begin
  if auth.uid() is distinct from p_user and auth.role() is distinct from 'service_role' then
    raise exception 'owner required' using errcode='42501';
  end if;
  if p_device is not null and not exists(select 1 from public.devices where id=p_device and user_id=p_user) then
    raise exception 'owned device required' using errcode='42501';
  end if;
  for feature_key in select feature from public.physiology_feature_defaults order by feature loop
    device := null; version := null;
    select s.device_id,s.algorithm_version into device,version
      from public.physiology_source_selection s
      where s.user_id=p_user and s.feature=feature_key and (p_device is null or s.device_id=p_device);
    if device is null then
      device := p_device;
      if device is null then
        select d.id into device from public.devices d where d.user_id=p_user
          order by (select max(h.ts) from public.noop_hr_samples h
            where h.user_id=p_user and h.device_id=d.id) desc nulls last,
            d.last_seen_at desc nulls last,d.id limit 1;
      end if;
      select algorithm_version into version from public.physiology_feature_defaults where feature=feature_key;
    end if;
    if device is null or not exists(select 1 from public.devices where id=device and user_id=p_user) then
      features := features || jsonb_build_object(feature_key,jsonb_build_object(
        'status','unavailable','reason','source_selection_required'));
      is_stale := true;
      continue;
    end if;
    selected_versions := array_append(selected_versions,version);
    selected_devices := array_append(selected_devices,device);
    if not public.physiology_feature_is_canonical(version,feature_key) then
      features := features || jsonb_build_object(feature_key,jsonb_build_object(
        'status','unavailable','reason','unqualified_version','device_id',device,'algorithm_version',version));
      is_stale := true;
      continue;
    end if;

    result := null; result_revision := null; feature_computed := null; stored_manifest := null;
    unavailable_reason := null;
    select v.manifest_hash into expected_manifest from public.physiology_algorithm_versions v
      where v.algorithm_version=version;
    select m.manifest_sha256 into expected_feature_manifest from public.physiology_feature_manifests m
      where m.algorithm_version=version and m.feature=feature_key;
    select r.payload,r.input_revision,r.computed_at,r.manifest_hash
      into result,result_revision,feature_computed,stored_manifest
      from public.server_physiology_results r where r.user_id=p_user and r.device_id=device
        and r.period_day=p_day and r.algorithm_version=version order by r.input_revision desc limit 1;
    -- Do not silently fall back to an older result when the newest release identity is incompatible.
    if result is not null and (stored_manifest is distinct from expected_manifest
      or (version<>'frwhoop-server-1' and (expected_feature_manifest is null
        or result->'feature_manifest_hashes'->>feature_key is distinct from expected_feature_manifest))) then
      result := null; unavailable_reason := 'manifest_mismatch';
    elsif result is null and version='frwhoop-server-1' then
      select jsonb_build_object('daily',to_jsonb(d),'nights',coalesce((
          select jsonb_agg(to_jsonb(n) order by n.start_at) from public.server_sleep_nights n
          where n.user_id=p_user and n.device_id=device and n.period_day=p_day and n.algorithm_version=version
        ),'[]'::jsonb)),d.computed_at into result,feature_computed
        from public.server_daily_scores d where d.user_id=p_user and d.source_device_id=device
          and d.day=p_day and d.algorithm_version=version;
    end if;
    if version='frwhoop-server-1' and public.scoring_legacy_minimum_readable_revision(p_user,device,p_day)>coalesce(result_revision,0) then
      result:=null; unavailable_reason:='source_revision_withdrawn';
    end if;
    if version='frwhoop-server-1' and result is not null then
      result:=public.server_legacy_read_eligibility(result);
    end if;
    processing := public.physiology_processing_metadata(p_user,device,p_day,version,result_revision);
    current_revision := (processing->>'required_revision')::bigint;
    feature_stale := case when version='frwhoop-server-1' and result_revision is null
      then result is null or not coalesce((processing->>'legacy_result_current')::boolean,false)
      else result is null or coalesce(result_revision<current_revision,false)
        or (result_revision is null and current_revision is not null) end;
    is_stale := is_stale or feature_stale;
    unavailable_reason := coalesce(unavailable_reason,nullif(result->>'unavailable_reason',''),
      case when result is null then 'awaiting_result' end);
    feature_status := case when unavailable_reason is not null then 'unavailable'
      when feature_stale then 'stale' else 'available' end;
    if result is not null and feature_computed is not null then computed := greatest(computed,feature_computed); end if;
    features := features || jsonb_build_object(feature_key,jsonb_build_object(
      'status',feature_status,'reason',coalesce(unavailable_reason,case when feature_stale then 'newer_input_pending' end),
      'device_id',device,'algorithm_version',version,'input_revision',result_revision,
      'required_revision',current_revision,'computed_at',feature_computed,
      'observed_through',result->'observed_through','publication_status',result->'publication_status',
      'manifest_hash',case when result is not null then expected_manifest end,
      'feature_manifest_hash',case when result is not null then expected_feature_manifest end,
      'canonical_qualification',case when version='frwhoop-server-1' then 'retained_legacy'
        else 'signed_reference_approval' end,
      'input_eligibility',result->'input_eligibility','metric_availability',result->'metric_availability',
      'computation_mode',result->'computation_mode',
      'archive_status',processing->'archive_status','processing_status',processing->'processing_status',
      'revision_protocol',processing->'revision_protocol','timezone_id',processing->'timezone_id',
      'timezone_ids',processing->'timezone_ids','day_intervals',processing->'day_intervals',
      'context_intervals',processing->'context_intervals',
      'supports_boundary_overrides',feature_key='sleep' and version='frwhoop-physiology-2'));
    if feature_status='unavailable' then continue; end if;
    keys := case feature_key
      when 'hrv' then array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm','hrv_summary','heart_rate_windows',
        'recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c']
      when 'respiration' then array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason']
      when 'sleep' then array['rest','sleep_total_min','sleep_in_bed_min','sleep_awake_min','sleep_light_min','sleep_deep_min',
        'sleep_rem_min','sleep_efficiency','sleep_onset_at','wake_onset_at','sleep_unstaged_min','state_unknown_min',
        'off_body_min','main_sleep_group_id','opportunity_kind','disturbances','full_day_sleep_epochs']
      else '{}'::text[] end;
    foreach key in array keys loop daily := daily || jsonb_build_object(key,result->'daily'->key); end loop;
    measurements := measurements || coalesce((select jsonb_agg(m) from jsonb_array_elements(
      coalesce(result->'measurements','[]'::jsonb)) m where m->>'feature'=feature_key),'[]'::jsonb);
    if feature_key='sleep' then
      nights := coalesce(result->'nights','[]'::jsonb);
      sleep_overrides := public.physiology_owned_sleep_overrides(p_user,device,p_day);
    end if;
  end loop;
  -- Sleep ownership alone cannot authorize embedded physiology from a different snapshot.
  if not coalesce(features->'hrv'->>'status' in ('available','stale')
    and features->'hrv'->>'algorithm_version'=features->'sleep'->>'algorithm_version'
    and features->'hrv'->>'device_id'=features->'sleep'->>'device_id'
    and (features->'hrv'->'input_revision') is not distinct from (features->'sleep'->'input_revision'),false) then
    select coalesce(jsonb_agg(n-array['hrv_rmssd_ms','hrv_sdnn_ms','resting_hr_bpm','overnight_hr_bpm',
      'hrv_summary','heart_rate_windows','recovery','strain','spo2_pct','skin_temp_c','skin_temp_dev_c'] order by ordinal),'[]'::jsonb)
      into nights from jsonb_array_elements(nights) with ordinality as episode(n,ordinal);
  end if;
  if not coalesce(features->'respiration'->>'status' in ('available','stale')
    and features->'respiration'->>'algorithm_version'=features->'sleep'->>'algorithm_version'
    and features->'respiration'->>'device_id'=features->'sleep'->>'device_id'
    and (features->'respiration'->'input_revision') is not distinct from (features->'sleep'->'input_revision'),false) then
    select coalesce(jsonb_agg(n-array['resp_rate_bpm','respiration_summary','respiration_unavailable_reason'] order by ordinal),'[]'::jsonb)
      into nights from jsonb_array_elements(nights) with ordinality as episode(n,ordinal);
  end if;
  return jsonb_build_object('schema_version',2,'contract_revision',1,'user_id',p_user,'day',p_day,
    'algorithm_version',case when cardinality(array(select distinct unnest(selected_versions)))=1
      then selected_versions[1] else 'per_feature' end,
    'daily',case when computed is null then null else daily || jsonb_build_object('day',p_day,'computed_at',computed,
      'source_device_id',case when cardinality(array(select distinct unnest(selected_devices)))=1
        then selected_devices[1] else null end) end,
    'nights',nights,'features',features,'measurements',measurements,'sleep_overrides',sleep_overrides,
    'computed_at',computed,'stale',is_stale);
end $$;

commit;
