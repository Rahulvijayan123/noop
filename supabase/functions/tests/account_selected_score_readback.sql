\set ON_ERROR_STOP on
begin isolation level repeatable read;
do $$ begin
  assert current_database()='physiology_queue_test' and inet_server_addr()='127.0.0.1'::inet,
    'disposable local queue database required';
end $$;

create temporary table account_route_fixture(key text primary key,value jsonb);
grant select on account_route_fixture to authenticated,service_role,anon;
create function pg_temp.strip_route_annotations(envelope jsonb) returns jsonb language sql as $$
  select jsonb_set(envelope->'server_scoring','{compute}',
    ((envelope#>'{server_scoring,compute}')-array['project','source_id','families'])||
    jsonb_build_object('families',(select jsonb_object_agg(key,value-array['project','source_id'])
      from jsonb_each(envelope#>'{server_scoring,compute,families}'))))
$$;
create function pg_temp.expect_rejection(statement text,expected_state text) returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if sqlstate=expected_state then return; end if;
    raise;
  end;
  raise exception 'expected rejection %',expected_state;
end $$;

do $$
declare
  owner uuid:='bb271000-0000-4000-8000-000000000001';
  other uuid:='bb271000-0000-4000-8000-000000000002';
  source uuid:='bb271000-0000-4000-8000-000000000003';
  source_two uuid:='bb271000-0000-4000-8000-000000000004';
  foreign_source uuid:='bb271000-0000-4000-8000-000000000005';
  device uuid:='bb271000-0000-4000-8000-000000000006';
  device_two uuid:='bb271000-0000-4000-8000-000000000007';
  provisional uuid:='bb271000-0000-4000-8000-000000000008';
  code uuid:='bb271000-0000-4000-8000-000000000009';
  claim public.scoring_work_items; payload jsonb; manifest text; hash text; day date;
begin
  insert into auth.users(id) values(owner),(other);
  insert into profiles(id,timezone) values(owner,'UTC'),(other,'UTC') on conflict(id) do nothing;
  insert into compute_account_sources(source_id,user_id) values(source,owner),(source_two,owner),(foreign_source,other);
  insert into noop_enrollment_codes(id,user_id,code_hash,expires_at)
    values(code,owner,repeat('b',64),now()+interval '1 hour');
  insert into noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version)
    values(source,owner,code,'ios','test');
  insert into devices(id,user_id,source_kind,external_device_id) values
    (device,owner,'noop_push','installation:'||source||':local-device'),
    (device_two,owner,'noop_push','installation:'||source_two||':local-device'),
    (provisional,owner,'noop_push','installation:'||source||':provisional-device');
  insert into noop_wearable_aliases(user_id,source_id,provisional_device_id,canonical_device_id,evidence)
    values(owner,source,provisional,device,'{"kind":"synthetic_test"}');
  payload:=jsonb_build_object('daily',jsonb_build_object('resting_hr_bpm',51,'sleep_total_min',450,
      'sleep_in_bed_min',480,'sleep_awake_min',30,'sleep_light_min',200,'sleep_deep_min',120,
      'sleep_rem_min',130,'sleep_efficiency',0.9375),'nights','[]'::jsonb,'measurements','[]'::jsonb,
      'input_eligibility',jsonb_build_object('policy_version','legacy-rr-excluded-1','rr_input','excluded'));
  hash:=encode(sha256(convert_to(payload::text,'UTF8')),'hex');
  select manifest_hash into manifest from physiology_algorithm_versions where algorithm_version='frwhoop-server-1';
  foreach day in array array['2026-09-26'::date,'2026-09-25'::date] loop
    perform scoring_enqueue_legacy_fenced(owner,device,day,'UTC',0);
    select * into strict claim from scoring_legacy_claim_one(300,8,owner,device,day);
    perform scoring_legacy_seal_snapshot(owner,device,day,claim.input_revision,claim.lease_token,claim.run_id);
    perform scoring_legacy_begin_publication(owner,device,day,claim.input_revision,claim.lease_token,claim.run_id);
    insert into server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,
      run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
    values(owner,device,day,'frwhoop-server-1',claim.input_revision,claim.run_id,
      case when day='2026-09-25' then repeat('0',64) else manifest end,payload,hash,now(),'final');
  end loop;
  perform set_config('request.jwt.claim.role','service_role',true);
  insert into account_route_fixture values
    ('expected',server_scoring_for_device_day(owner,'2026-09-26',device)),
    ('manifest_mismatch',server_scoring_for_device_day(owner,'2026-09-25',device)),
    ('hash',to_jsonb(hash)),('manifest',to_jsonb(manifest)),('payload',payload);
  assert not exists(select 1 from scoring_snapshots_v2 where user_id=owner),'fixture copied to legacy snapshots';
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','bb271000-0000-4000-8000-000000000001',true),
  set_config('request.jwt.claim.role','authenticated',true),
  set_config('request.jwt.claims','{"iss":"https://sgoyxzcagqyxexmsidtk.supabase.co/auth/v1"}',true);
do $$ declare body jsonb; f record; bad text; begin
  assert not has_table_privilege(current_user,'public.compute_account_sources','select'),
    'test must exercise the restricted account role';
  body:=public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'local-device');
  assert pg_temp.strip_route_annotations(body)=(select value from account_route_fixture where key='expected'),
    'account RPC differs from enrollment read contract';
  assert body#>>'{identity,userId}'='bb271000-0000-4000-8000-000000000001';
  assert body#>>'{identity,sourceId}'='bb271000-0000-4000-8000-000000000003';
  assert body#>>'{identity,deviceId}'='bb271000-0000-4000-8000-000000000006';
  assert body#>>'{identity,externalDeviceId}'='local-device';
  assert body#>>'{identity,project}'='https://sgoyxzcagqyxexmsidtk.supabase.co';
  assert (select count(*) from jsonb_each(body#>'{server_scoring,compute,families}'))=27;
  for f in select value from jsonb_each(body#>'{server_scoring,compute,families}') loop
    assert f.value->>'project'=body#>>'{identity,project}' and
      f.value->>'source_id'=body#>>'{identity,sourceId}','family route identity missing';
  end loop;
  assert body#>>'{server_scoring,compute,families,sleep,result_revision}'=
    'sha256:'||(select value#>>'{}' from account_route_fixture where key='hash');
  assert body#>'{server_scoring,compute,families,sleep,manifest_hash}'=
    (select value from account_route_fixture where key='manifest');
  assert body#>>'{server_scoring,compute,families,sleep,algorithm_version}'='frwhoop-server-1';
  assert body#>>'{server_scoring,compute,families,sleep,values,sleep_total_min}'='450';
  assert current_setting('response.headers')::jsonb='[{"Cache-Control":"no-store"}]'::jsonb;
  -- Calling the original overload remains the original camelCase snapshot contract.
  body:=public.get_server_score_snapshot_v2('2026-09-26',null::text);
  assert body->>'schemaVersion'='2' and not body ? 'server_scoring','legacy RPC shape changed';
  body:=public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'provisional-device');
  assert body#>>'{identity,deviceId}'='bb271000-0000-4000-8000-000000000006','alias not resolved';
  body:=public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000004'::uuid,'local-device');
  assert body#>>'{identity,deviceId}'='bb271000-0000-4000-8000-000000000007','source scope crossed';
  assert body#>'{server_scoring,compute,families,sleep,result_revision}'='null'::jsonb;
  body:=public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'missing-device');
  assert body#>'{identity,deviceId}'='null'::jsonb;
  assert body#>>'{server_scoring,compute,families,sleep,reason}'='device_registration_pending';
  body:=public.get_server_score_snapshot_v2('2026-09-25','bb271000-0000-4000-8000-000000000003'::uuid,'local-device');
  assert pg_temp.strip_route_annotations(body)=(select value from account_route_fixture where key='manifest_mismatch');
  assert body#>'{server_scoring,compute,families,sleep,result_revision}'='null'::jsonb,'manifest mismatch became readable';
  perform pg_temp.expect_rejection($q$select public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000005'::uuid,'local-device')$q$,'PT403');
  perform pg_temp.expect_rejection($q$select public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000010'::uuid,'local-device')$q$,'PT401');
  foreach bad in array array['','  ','person@example.invalid','+1 555-555-5555',E'bad\ndevice',repeat('x',256)] loop
    perform pg_temp.expect_rejection(format('select public.get_server_score_snapshot_v2(%L,%L::uuid,%L)',
      '2026-09-26','bb271000-0000-4000-8000-000000000003',bad),'22023');
  end loop;
  perform set_config('request.jwt.claims','{"iss":"https://wrong-project.supabase.co/auth/v1"}',true);
  perform pg_temp.expect_rejection($q$select public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'local-device')$q$,'42501');
  perform set_config('request.jwt.claims','{"iss":"https://sgoyxzcagqyxexmsidtk.supabase.co/auth/v1"}',true);
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.expect_rejection($q$select public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'local-device')$q$,'42501');
end $$;
reset role;

-- A source revoked in either registry fails even if the other registry is live.
update noop_app_installations set revoked_at=now() where source_id='bb271000-0000-4000-8000-000000000003';
update compute_account_sources set user_id='bb271000-0000-4000-8000-000000000002'
  where source_id='bb271000-0000-4000-8000-000000000003';
set local role authenticated;
select set_config('request.jwt.claim.sub','bb271000-0000-4000-8000-000000000001',true);
select pg_temp.expect_rejection($q$select public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'local-device')$q$,'PT403');
reset role;
update compute_account_sources set user_id='bb271000-0000-4000-8000-000000000001'
  where source_id='bb271000-0000-4000-8000-000000000003';
set local role authenticated;
select set_config('request.jwt.claim.sub','bb271000-0000-4000-8000-000000000001',true);
select pg_temp.expect_rejection($q$select public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'local-device')$q$,'PT401');
reset role;
update noop_app_installations set revoked_at=null where source_id='bb271000-0000-4000-8000-000000000003';
select set_config('request.jwt.claim.role','service_role',true);
select scoring_enqueue_legacy_fenced('bb271000-0000-4000-8000-000000000001',
  'bb271000-0000-4000-8000-000000000006','2026-09-26','UTC',0);
insert into account_route_fixture values('withdrawn',server_scoring_for_device_day(
  'bb271000-0000-4000-8000-000000000001','2026-09-26','bb271000-0000-4000-8000-000000000006'));
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
do $$ declare body jsonb; begin
  body:=public.get_server_score_snapshot_v2('2026-09-26','bb271000-0000-4000-8000-000000000003'::uuid,'local-device');
  assert pg_temp.strip_route_annotations(body)=(select value from account_route_fixture where key='withdrawn');
  assert body#>'{server_scoring,compute,families,sleep,result_revision}'='null'::jsonb,
    'withdrawn immutable revision leaked through account route';
end $$;
reset role;
do $$ begin
  assert (select encode(sha256(convert_to(prosrc,'UTF8')),'hex') from pg_proc
    where oid='public.get_server_score_snapshot_v2(date,text)'::regprocedure)=
    '55d657a5a0683ed7cdf8672f62e834e0ea493d08eda45676b3c7805d90a19e01',
    'legacy public snapshot body changed';
  assert (select encode(sha256(convert_to(prosrc,'UTF8')),'hex') from pg_proc
    where oid='internal.get_server_score_snapshot_v2(date,text)'::regprocedure)=
    'ea63a295b2a19a9b087b09e3463ad8cf9fbe797936e394b8fd86768f67a579d9',
    'legacy internal snapshot body changed';
  assert not has_function_privilege('anon','public.get_server_score_snapshot_v2(date,uuid,text)','execute');
  assert not has_function_privilege('service_role','public.get_server_score_snapshot_v2(date,uuid,text)','execute');
  assert has_function_privilege('authenticated','public.get_server_score_snapshot_v2(date,uuid,text)','execute');
  assert not exists(select 1 from scoring_snapshots_v2 where user_id='bb271000-0000-4000-8000-000000000001');
  assert (select payload=(select value from account_route_fixture where key='payload') from server_physiology_results
    where user_id='bb271000-0000-4000-8000-000000000001' and period_day='2026-09-26'),
    'read path changed immutable publication bytes';
end $$;
rollback;
select '{"status":"PASS","fixture":"synthetic_account_selected_score_readback","legacy_snapshot_contract_preserved":true,"physical_acceptance":"NOT_MEASURED"}'::jsonb;
