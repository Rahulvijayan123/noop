-- Disposable PostgreSQL only. These are admission/fencing fixtures, not physiology results.
begin;
set local statement_timeout='30s';
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.users(id) values('a2411111-1111-4111-8111-111111111111'),('b2411111-1111-4111-8111-111111111111');
insert into devices(id,user_id,source_kind) values
 ('a2422222-2222-4222-8222-222222222222','a2411111-1111-4111-8111-111111111111','noop_push'),
 ('b2422222-2222-4222-8222-222222222222','b2411111-1111-4111-8111-111111111111','noop_push');
update noop_recovery_database_identity set project_ref='abcdefghijklmnopqrst';
insert into noop_recovery_runs(id,user_id,device_id,project_ref,source_revision,policy_hash,intake_image,scoring_image,
 intake_instance,scoring_instance,supervisor_token,expires_at,maximum_expires_at,intake_container,scoring_container)
select (p||'2433333-3333-4333-8333-333333333333')::uuid,(p||'2411111-1111-4111-8111-111111111111')::uuid,
 (p||'2422222-2222-4222-8222-222222222222')::uuid,'abcdefghijklmnopqrst',repeat('a',40),repeat('b',64),
 'sha256:'||repeat('c',64),'sha256:'||repeat('d',64),
 (p||'2444444-4444-4444-8444-444444444444')::uuid,(p||'2455555-5555-4555-8555-555555555555')::uuid,
 (p||'2466666-6666-4666-8666-666666666666')::uuid,clock_timestamp()+interval '8 minutes',clock_timestamp()+interval '1 hour',repeat(p,64),repeat('e',64)
from unnest(array['a','b']) p;
insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,status,sha256_source,sha256,
 created_at,compressed_bytes,uncompressed_bytes)
select ('a2477777-7777-4777-8777-'||lpad(i::text,12,'0'))::uuid,
 'a2411111-1111-4111-8111-111111111111','a2422222-2222-4222-8222-222222222222','ppgWaveformSample',
 'synthetic-recovery/'||i,'binary',now()-interval '2 days',now()-interval '1 day','pending','client_claimed',repeat('a',64),
 now()-interval '3 days'+i*interval '1 second',1024,2048 from generate_series(1,10000) i;
do $$
declare r uuid:='a2433333-3333-4333-8333-333333333333'; i uuid:='a2444444-4444-4444-8444-444444444444';
 p uuid:=gen_random_uuid(); a jsonb; b jsonb; s jsonb; n integer; before_count integer; original_hash text;
begin
 select count(*),md5(string_agg(id::text||':'||object_key||':'||sha256,',' order by id)) into before_count,original_hash
  from object_manifests where user_id='a2411111-1111-4111-8111-111111111111';
 assert before_count=10000;
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
  raise exception 'unsupervised claim accepted'; exception when insufficient_privilege then null; end;
 perform noop_recovery_supervise(r,'a2466666-6666-4666-8666-666666666666',repeat('b',64),jsonb_build_object(
  'intake_container',repeat('a',64),'scoring_container',repeat('e',64),'intake_image','sha256:'||repeat('c',64),
  'scoring_image','sha256:'||repeat('d',64),'source_revision',repeat('a',40),'resources_healthy',true,'captured_at',clock_timestamp()));
 assert not has_function_privilege('service_role','public.noop_recovery_validate(uuid,boolean)','execute'),'supervisor secret helper exposed';
 assert not has_function_privilege('service_role','public.noop_recovery_assert_attempt(uuid,uuid,uuid)','execute');
 assert not has_function_privilege('service_role','public.noop_recovery_release(uuid,uuid,uuid,boolean,text,boolean)','execute');
 begin
  perform noop_recovery_confirm_stopped(r,null,i,repeat('a',64)); raise exception 'null supervisor accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_recovery_confirm_stopped(r,'a2466666-6666-4666-8666-666666666666',null,null); raise exception 'null stopped identity accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform recovery_target_identity(r,null,null); raise exception 'null owner accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_recovery_claim(r,p,null,repeat('a',40),'sha256:'||repeat('c',64),'legacy'); raise exception 'null instance accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_recovery_claim(r,p,i,null,'sha256:'||repeat('c',64),'legacy'); raise exception 'null source accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),null,'legacy'); raise exception 'null image accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),null); raise exception 'null lane accepted';
 exception when insufficient_privilege then null; end;
 begin
  perform scoring_recovery_claim_one(r,p,'a2455555-5555-4555-8555-555555555555',repeat('a',40),'sha256:'||repeat('d',64),40,8,null,null,null);
  raise exception 'null scoring scope accepted'; exception when insufficient_privilege then null; end;
 loop
  s:=noop_recovery_inventory_page(r,256); exit when (s->>'complete')::boolean;
 end loop;
 assert (select count(*) from noop_recovery_inventory where run_id=r)=10000,'keyset inventory lost identity';
 s:=noop_recovery_status(r);
 assert (s#>>'{legacy,pending_at_least}')::integer=1000 and (s#>>'{legacy,truncated}')::boolean,'old debt count changed';
 assert s->>'inventory_input_processed'='0' and s->>'backfill_computed_readback'='NOT_MEASURED';
 a:=noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
 assert a->>'objectId'='a2477777-7777-4777-8777-000000000001','history oldest lost';
 assert noop_recovery_claim(r,gen_random_uuid(),i,repeat('a',40),'sha256:'||repeat('c',64),'legacy') is null,'duplicate worker exceeds slot';
 perform noop_recovery_intake_call(r,p,(a->>'recoveryToken')::uuid,'legacy_failure','{"reason":"b2_timeout","retryable":true}');
 assert (select reason='b2_timeout' and failures=1 and not quarantined from noop_recovery_object_state where run_id=r and object_id=(a->>'objectId')::uuid and lane='legacy');
 assert noop_recovery_status(r)->>'inventory_verified'='0','retry became completion';
 begin
  perform noop_recovery_intake_call(r,p,(a->>'recoveryToken')::uuid,'legacy_failure','{}');
  raise exception 'released token accepted'; exception when insufficient_privilege then null; end;
 -- Fresh data is admitted without erasing historical debt; alternation then returns to oldest good history.
 insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,status,sha256_source,sha256,compressed_bytes,uncompressed_bytes)
 values('a2488888-8888-4888-8888-888888888888','a2411111-1111-4111-8111-111111111111','a2422222-2222-4222-8222-222222222222',
  'ppgWaveformSample','synthetic-live','binary',now(),now(),'pending','client_claimed',repeat('b',64),100,200);
 b:=noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
 assert b->>'objectId'='a2488888-8888-4888-8888-888888888888','live starvation';
 perform noop_recovery_intake_call(r,p,(b->>'recoveryToken')::uuid,'legacy_failure','{"reason":"invalid_compressed_object","retryable":false}');
 a:=noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
 assert a->>'objectId'='a2477777-7777-4777-8777-000000000002','good history starved by corrupt live';
 -- Scope substitution fails before any object operation.
 begin
  perform noop_recovery_intake_call(r,p,(a->>'recoveryToken')::uuid,'noop_current_object_receipt',
   '{"p_object_id":"a2477777-7777-4777-8777-000000000003"}');
  raise exception 'wrong object accepted'; exception when insufficient_privilege then null; end;
 update noop_recovery_attempts set lease_until=clock_timestamp()-interval '1 second' where token=(a->>'recoveryToken')::uuid;
 assert noop_recovery_claim(r,gen_random_uuid(),i,repeat('a',40),'sha256:'||repeat('c',64),'legacy') is null,'uncertain expired slot reused';
 assert noop_recovery_status(r)#>>'{active,uncertain}'='1';
 begin
  perform noop_recovery_intake_call(r,p,(a->>'recoveryToken')::uuid,'legacy_failure','{}');
  raise exception 'expired token settled'; exception when insufficient_privilege then null; end;
 assert (select count(*) from object_manifests where user_id='a2411111-1111-4111-8111-111111111111')=10001;
 assert original_hash=(select md5(string_agg(id::text||':'||object_key||':'||sha256,',' order by id)) from object_manifests
  where user_id='a2411111-1111-4111-8111-111111111111' and id<>'a2488888-8888-4888-8888-888888888888'),'retained identities mutated';
 perform noop_recovery_confirm_stopped(r,'a2466666-6666-4666-8666-666666666666',i,repeat('a',64));
 assert not exists(select 1 from noop_recovery_attempts where run_id=r and released_at is null);
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
  raise exception 'stopped run claimed'; exception when insufficient_privilege then null; end;
end $$;
-- A second scope can run only after the first confirmed stop. Large/unknown
-- declaration handling and shared slots remain independent of retained count.
insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,status,sha256_source,sha256,
 created_at,compressed_bytes,uncompressed_bytes)
select ('b2477777-7777-4777-8777-'||lpad(i::text,12,'0'))::uuid,
 'b2411111-1111-4111-8111-111111111111','b2422222-2222-4222-8222-222222222222','ppgWaveformSample','second-scope/'||i,
 'binary',now()-interval '2 days',now()-interval '1 day','pending','client_claimed',repeat('a',64),
 now()-interval '2 days'+i*interval '1 second',case when i=1 then 33554433 else 1024 end,case when i=2 then null else 2048 end
 from generate_series(1,1001) i;
do $$
declare r uuid:='b2433333-3333-4333-8333-333333333333'; p uuid:=gen_random_uuid(); i uuid:='b2444444-4444-4444-8444-444444444444'; a jsonb;
begin
 perform noop_recovery_supervise(r,'b2466666-6666-4666-8666-666666666666',repeat('b',64),jsonb_build_object(
  'intake_container',repeat('b',64),'scoring_container',repeat('e',64),'intake_image','sha256:'||repeat('c',64),
  'scoring_image','sha256:'||repeat('d',64),'source_revision',repeat('a',40),'resources_healthy',true,'captured_at',clock_timestamp()),clock_timestamp()+interval '9 minutes');
 a:=noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
 assert a->>'objectId'='b2477777-7777-4777-8777-000000000002';
 assert (a->>'reservedDecodedBytes')::bigint=134217728,'unknown decoded length underreserved';
 perform scoring_canary_enqueue_legacy('b2411111-1111-4111-8111-111111111111','b2422222-2222-4222-8222-222222222222',current_date,'UTC',0);
 assert not exists(select 1 from scoring_recovery_claim_one(r,gen_random_uuid(),'b2455555-5555-4555-8555-555555555555',repeat('a',40),
  'sha256:'||repeat('d',64),40,8,'b2411111-1111-4111-8111-111111111111','b2422222-2222-4222-8222-222222222222',current_date)),
  'scorer exceeded shared decoded budget';
 assert noop_recovery_status(r)#>>'{active,decoded_bytes}'='134217728','blocked scorer charged extra bytes';
 assert exists(select 1 from noop_recovery_object_state where run_id=r and reason='blocked_by_recovery_size_budget');
 assert noop_recovery_status(r)#>>'{legacy,truncated}'='true';
 perform noop_recovery_intake_call(r,p,(a->>'recoveryToken')::uuid,'legacy_failure','{"reason":"unknown_size","retryable":false}');
 -- Policy expiration and stale observer cannot admit new work or extend authority.
 update noop_recovery_runs set observed_at=clock_timestamp()-interval '21 seconds' where id=r;
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
  raise exception 'stale supervision admitted'; exception when insufficient_privilege then null; end;
 update noop_recovery_runs set observed_at=clock_timestamp(),created_at=clock_timestamp()-interval '20 minutes',expires_at=clock_timestamp()-interval '1 second' where id=r;
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
  raise exception 'expired run admitted'; exception when insufficient_privilege then null; end;
 update noop_recovery_runs set expires_at=clock_timestamp()+interval '1 minute' where id=r;
 perform noop_recovery_supervise(r,'b2466666-6666-4666-8666-666666666666',repeat('b',64),jsonb_build_object(
  'intake_container',repeat('b',64),'scoring_container',repeat('e',64),'intake_image','sha256:'||repeat('c',64),
  'scoring_image','sha256:'||repeat('d',64),'source_revision',repeat('a',40),'resources_healthy',true,'captured_at',clock_timestamp()),clock_timestamp()+interval '9 minutes');
 assert exists(select 1 from noop_recovery_events where run_id=r and kind='renewal'),'renewal lost audit';
 update devices set is_active=false where id='b2422222-2222-4222-8222-222222222222';
 begin
  perform noop_recovery_claim(r,p,i,repeat('a',40),'sha256:'||repeat('c',64),'legacy');
  raise exception 'revoked device claimed'; exception when insufficient_privilege then null; end;
end $$;
rollback;
