-- HART encoder windows contract (20261005150000_activity_encoder_windows.sql): the fenced window publish,
-- its payload checks and owner-only reads. Runs after
-- the activity migrations on a disposable, fully migrated cluster; every change rolls back.
--
--   psql -X -qAt -v ON_ERROR_STOP=1 -f ../../migrations/20261005150000_activity_encoder_windows.sql \
--        -f activity_encoder_windows_contract.sql
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
set local lock_timeout = '5s';

insert into auth.users(id) values
 ('b0000000-0000-4000-8000-000000000001'),
 ('b0000000-0000-4000-8000-000000000002');
insert into public.devices(id,user_id,source_kind) values
 ('b0000000-0000-4000-8000-000000000011','b0000000-0000-4000-8000-000000000001','noop_push'),
 ('b0000000-0000-4000-8000-000000000012','b0000000-0000-4000-8000-000000000002','noop_push');

-- A two-window hart-windows-1 document for the UTC day.
create function pg_temp.win_doc(p_day date) returns jsonb language sql as $$
  select jsonb_build_object('format','hart-windows-1',
    't0',extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint,
    'labels',jsonb_build_array('stationary','walking','running','other_movement','unknown'),
    'features',jsonb_build_array('accel_rms_g','gyro_rms_dps','jerk_rms','cadence_hz','cadence_strength','orientation_change_deg'),
    'feature_scale',jsonb_build_array(100000,1000,100000,1000,10000,100),
    's',jsonb_build_array(600,602),'e',jsonb_build_array(604,606),'l',jsonb_build_array(1,4),
    'p',jsonb_build_array(jsonb_build_array(50,910,0,40,0),jsonb_build_array(600,0,0,400,0)),
    'b',jsonb_build_array(0,0),
    'f',jsonb_build_array(jsonb_build_array(13542,41250,1234,1833,4521,null),null))
$$;
create function pg_temp.win_payload(p_day date, p_doc jsonb default null) returns jsonb language sql as $$
  select jsonb_build_object('day',p_day::text,'encoder_id','hart','model_version','hart-wisdm-v0',
    'preprocessing_version','1.0.0','feature_schema','imu-feat-1','windows',coalesce(p_doc,pg_temp.win_doc(p_day)))
$$;
create function pg_temp.rejects(p_tok uuid, p_rev bigint, p_payload jsonb, p_msg text) returns boolean
language plpgsql as $$
begin
  begin
    perform public.publish_activity_encoder_windows(p_tok, p_rev, p_payload);
  exception when others then
    return sqlerrm = p_msg;
  end;
  return false;
end $$;

-- W1. Fenced publish: a live lease at the job's revision stores the row; a republish replaces it; a stale
-- revision, an unknown token or an expired lease writes nothing. The window publish never completes the job.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-05';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; rev1 bigint; rev2 bigint; r record;
begin
  fp := public.activity_context_fingerprint(array[repeat('1',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('1',64)],fp);
  select * into j from public.claim_activity_context_v2(300);
  assert found and j.user_id=u, 'the job must be claimable';
  rev1 := public.publish_activity_encoder_windows(j.lease_token, j.input_revision, pg_temp.win_payload(v_day));
  assert rev1 is not null, 'a valid window set must be stored';
  select * into r from public.activity_encoder_windows where user_id=u and device_id=dev and day=v_day;
  assert found and r.algorithm_version='hart-activity-1' and r.encoder_id='hart'
     and r.model_version='hart-wisdm-v0' and r.preprocessing_version='1.0.0' and r.feature_schema='imu-feat-1',
    'identity and versions must be stamped';
  assert r.window_count=2 and r.first_ts=lo+600 and r.last_ts=lo+606, 'count and span must be mirrored';
  assert r.job_fingerprint=fp and r.input_revision=j.input_revision and r.result_revision=rev1,
    'the row must record the job lineage';
  assert r.windows = pg_temp.win_doc(v_day), 'the document must be stored verbatim';
  assert (select lease_token=j.lease_token and completed_revision=0 from public.activity_context_jobs
    where user_id=u and device_id=dev and day=v_day), 'the window publish must not complete the job';

  rev2 := public.publish_activity_encoder_windows(j.lease_token, j.input_revision, pg_temp.win_payload(v_day));
  assert rev2 > rev1, 'a republish must replace the row with a newer result revision';
  assert (select count(*)=1 from public.activity_encoder_windows where user_id=u and device_id=dev and day=v_day),
    'one row per lineage';

  assert public.publish_activity_encoder_windows(j.lease_token, j.input_revision + 1, pg_temp.win_payload(v_day)) is null,
    'a stale revision must be fenced';
  assert public.publish_activity_encoder_windows(gen_random_uuid(), j.input_revision, pg_temp.win_payload(v_day)) is null,
    'an unknown token must be fenced';
  update public.activity_context_jobs set lease_until = clock_timestamp() - interval '1 second'
    where lease_token = j.lease_token;
  assert public.publish_activity_encoder_windows(j.lease_token, j.input_revision, pg_temp.win_payload(v_day)) is null,
    'an expired lease must be fenced';
  assert (select result_revision=rev2 from public.activity_encoder_windows where user_id=u and device_id=dev and day=v_day),
    'a fenced publish must write nothing';
  raise notice 'PASS W1 fenced window publish';
end;
$$;

-- W2. Payload contract: each malformed document is rejected with a stable message and writes nothing.
do $$
declare
  u uuid := 'b0000000-0000-4000-8000-000000000001';
  dev uuid := 'b0000000-0000-4000-8000-000000000011';
  v_day date := '2026-10-06';
  lo bigint := extract(epoch from (v_day::timestamp at time zone 'UTC'))::bigint;
  fp text; j record; doc jsonb;
begin
  fp := public.activity_context_fingerprint(array[repeat('2',64)],lo,lo+86399,'hart-activity-1','hart-activity-v1','hart-activity-preprocess-v1','v1');
  perform public.enqueue_activity_context(u,dev,v_day,array[gen_random_uuid()],array[repeat('2',64)],fp);
  select * into j from public.claim_activity_context_v2(300);
  assert found and j.day=v_day, 'the W2 job must be claimable';
  doc := pg_temp.win_doc(v_day);
  assert pg_temp.rejects(j.lease_token, j.input_revision, jsonb_build_object('day',v_day::text), 'invalid_activity_windows_payload'),
    'a payload without windows must be rejected';
  assert pg_temp.rejects(j.lease_token, j.input_revision, pg_temp.win_payload(v_day + 1, doc), 'invalid_activity_windows_payload'),
    'another day must be rejected';
  assert pg_temp.rejects(j.lease_token, j.input_revision, pg_temp.win_payload(v_day, jsonb_set(doc,'{format}','"x"')),
    'invalid_activity_windows_document'), 'an unknown format must be rejected';
  assert pg_temp.rejects(j.lease_token, j.input_revision, pg_temp.win_payload(v_day, jsonb_set(doc,'{t0}',to_jsonb(lo+1))),
    'invalid_activity_windows_document'), 'a t0 that is not the day start must be rejected';
  assert pg_temp.rejects(j.lease_token, j.input_revision, pg_temp.win_payload(v_day, jsonb_set(doc,'{e}','[604]')),
    'invalid_activity_windows_count'), 'parallel arrays of different lengths must be rejected';
  assert pg_temp.rejects(j.lease_token, j.input_revision, pg_temp.win_payload(v_day, doc - 'f'),
    'invalid_activity_windows_document'), 'a missing array must be rejected';
  assert not exists(select 1 from public.activity_encoder_windows where user_id=u and day=v_day),
    'a rejected payload must write nothing';
  -- An empty set is a valid document (the day had no usable windows).
  assert public.publish_activity_encoder_windows(j.lease_token, j.input_revision, pg_temp.win_payload(v_day,
    doc || '{"s":[],"e":[],"l":[],"p":[],"b":[],"f":[]}'::jsonb)) is not null, 'an empty window set must be accepted';
  assert (select window_count=0 and first_ts is null and last_ts is null from public.activity_encoder_windows
    where user_id=u and day=v_day), 'an empty set has no span';
  raise notice 'PASS W2 payload validation';
end;
$$;

-- W3. Owner isolation: the owner can read their windows, another account cannot, and no client role can publish.
set local role authenticated;
select set_config('request.jwt.claim.sub','b0000000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $$
begin
  assert (select count(*)=0 from public.activity_encoder_windows), 'another account must not see the windows';
  begin
    perform public.publish_activity_encoder_windows(gen_random_uuid(), 1, '{}'::jsonb);
    raise exception 'authenticated publish allowed';
  exception when insufficient_privilege then null; end;
  begin
    delete from public.activity_encoder_windows;
    raise exception 'authenticated delete allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
select set_config('request.jwt.claim.sub','b0000000-0000-4000-8000-000000000001',true);
do $$
begin
  assert (select count(*)=2 from public.activity_encoder_windows), 'the owner must see their own windows';
end;
$$;
reset role;
set local role anon;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
do $$
begin
  begin
    perform count(*) from public.activity_encoder_windows;
    raise exception 'anon window read allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
do $$ begin raise notice 'PASS W3 owner isolation'; end $$;

rollback;
