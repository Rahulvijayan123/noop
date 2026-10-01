-- Independent regression of actual append function. Disposable DB only; everything rolls back.
begin;
select set_config('request.jwt.claim.role','service_role',true);
insert into auth.users(id) values ('a1411111-1111-4111-8111-111111111111'); insert into public.devices(id,user_id,source_kind,external_device_id) values ('a1433333-3333-4333-8333-333333333333','a1411111-1111-4111-8111-111111111111','noop','installation:a1422222-2222-4222-8222-222222222222:fixture'),('a1444444-4444-4444-8444-444444444444','a1411111-1111-4111-8111-111111111111','noop','whoop-ABCDEF123'); insert into public.noop_enrollment_codes(id,user_id,code_hash,expires_at) values ('a1422222-2222-4222-8222-222222222222','a1411111-1111-4111-8111-111111111111',repeat('c',64),now()+interval '1 day'); insert into public.noop_app_installations(source_id,user_id,enrollment_code_id,platform,app_version) values ('a1422222-2222-4222-8222-222222222222','a1411111-1111-4111-8111-111111111111','a1422222-2222-4222-8222-222222222222','ios','independent-fixture');
with b(first,last,batch) as (values (1,2,md5('hrSample-batch-0')::uuid),(3,3,md5('hrSample-batch-1')::uuid)) insert into public.noop_hr_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","bpm") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,60+i%40 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('rrInterval-batch-0')::uuid),(3,3,md5('rrInterval-batch-1')::uuid)) insert into public.noop_rr_intervals("user_id","device_id","source_id","ts","batch_id","ingested_at","rrMs","seq","ord","srcChannel","tsSuspect") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,800+i%20,i%3,i%3,5,0 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('rrPacketProvenance-batch-0')::uuid),(3,3,md5('rrPacketProvenance-batch-1')::uuid)) insert into public.noop_rr_packet_provenance("user_id","device_id","source_id","ts","batch_id","ingested_at","packetId","sensorTs","recordIndex","rawHex","srcChannel","schemaVersion","decoderVersion","clockVersion","timestampPrecisionSeconds","clockOffsetSeconds","declaredCount") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,md5(i::text)||md5('packet'||i::text),(1789889755::bigint+(i-1)::bigint*170351/3),i,repeat('a1',124),5,1,'whoop5-v18-original-words-v1','sensor-second-unmapped',1,0,2 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('standardHRReceipt-batch-0')::uuid),(3,3,md5('standardHRReceipt-batch-1')::uuid)) insert into public.noop_standard_hr_receipts("user_id","device_id","source_id","ts","batch_id","ingested_at","receiptId","sessionId","notificationOrdinal","receivedUnixMs","receivedMonotonicNs","rawHex","schemaVersion","clockVersion") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,'a1422222-2222-4222-8222-222222222222:'||i,'a1422222-2222-4222-8222-222222222222',i,(1789889755::bigint+(i-1)::bigint*170351/3)*1000,i::bigint*1000000,repeat('a1',case when i%100=0 then 10 when i%100<5 then 6 when i%100=5 then 2 else 4 end),1,'host-arrival-unmapped' from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('stepSample-batch-0')::uuid),(3,3,md5('stepSample-batch-1')::uuid)) insert into public.noop_step_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","counter","activityClass","activity_class") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,i%65535,1,1 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('sleepStateSample-batch-0')::uuid),(3,3,md5('sleepStateSample-batch-1')::uuid)) insert into public.noop_sleep_state_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","state","raw_byte") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,1,1 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('ppgHrSample-batch-0')::uuid),(3,3,md5('ppgHrSample-batch-1')::uuid)) insert into public.noop_ppg_hr_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","bpm","conf") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,60+i%40,0.9 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('event-batch-0')::uuid),(3,3,md5('event-batch-1')::uuid)) insert into public.noop_events("user_id","device_id","source_id","ts","batch_id","ingested_at","kind","payloadJSON") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,'fixture','{"fixture":true}' from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('battery-batch-0')::uuid),(3,3,md5('battery-batch-1')::uuid)) insert into public.noop_battery_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","soc","mv","charging") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,90,4000,false from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('spo2Sample-batch-0')::uuid),(3,3,md5('spo2Sample-batch-1')::uuid)) insert into public.noop_spo2_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","red","ir") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,1000,2000 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('skinTempSample-batch-0')::uuid),(3,3,md5('skinTempSample-batch-1')::uuid)) insert into public.noop_skin_temp_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","raw","aux1Raw","aux2Raw") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,3300,1,2 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('respSample-batch-0')::uuid),(3,3,md5('respSample-batch-1')::uuid)) insert into public.noop_resp_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","raw") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,16 from b cross join lateral generate_series(b.first,b.last) g(i);
with b(first,last,batch) as (values (1,2,md5('gravitySample-batch-0')::uuid),(3,3,md5('gravitySample-batch-1')::uuid)) insert into public.noop_gravity_samples("user_id","device_id","source_id","ts","batch_id","ingested_at","x","y","z","dynAccel") select 'a1411111-1111-4111-8111-111111111111'::uuid,'a1433333-3333-4333-8333-333333333333'::uuid,'a1422222-2222-4222-8222-222222222222'::uuid,(1789889755::bigint+(i-1)::bigint*170351/3),b.batch,'2026-09-21T00:00:00Z'::timestamptz,0.1,0.2,0.9,0.01 from b cross join lateral generate_series(b.first,b.last) g(i);
do $$ declare u uuid:='a1411111-1111-4111-8111-111111111111'; s uuid:='a1422222-2222-4222-8222-222222222222'; d uuid:='a1433333-3333-4333-8333-333333333333'; st record; st_target text; st_keys text[]; r jsonb; bad jsonb; ident jsonb; key text; b uuid; b2 uuid; n bigint; expected bigint; before_obs bigint; cases integer:=0; begin
 for st in select * from (values
 ('hrSample','bpm','99'::jsonb),('rrInterval','ord','99'),('rrPacketProvenance','clockOffsetSeconds','99'),('standardHRReceipt','rawHex','"ffff"'),('stepSample','counter','99'),('sleepStateSample','state','2'),('ppgHrSample','bpm','99'),('event','payloadJSON','"different"'),('battery','mv','3999'),('spo2Sample','red','999'),('skinTempSample','raw','999'),('respSample','raw','99'),('gravitySample','x','0.8')) v(stream,field,val) loop
  select table_name,key_columns into st_target,st_keys from noop_projection_target(st.stream);
  execute format('select to_jsonb(t) from %I t where user_id=$1 order by to_jsonb(t)::text limit 1',st_target) into r using u;
  b:=md5('independent140-'||st.stream)::uuid;
  b2:=md5('independent140-conflict-'||st.stream)::uuid;
  r:=r||jsonb_build_object('batch_id',b);
  if r ? 'ts' then r:=r||jsonb_build_object('ts',(r->>'ts')::bigint+1000000); end if;
  if st.stream='rrPacketProvenance' then r:=r||jsonb_build_object('sensorTs',(r->>'sensorTs')::bigint+1000000,'packetId',repeat('b',64)); end if;
  if st.stream='standardHRReceipt' then r:=r||jsonb_build_object('notificationOrdinal',100,'receiptId',s::text||':100','receivedUnixMs',(r->>'ts')::bigint*1000); end if;
  -- All typed identity components reject explicit NULL and omission before any observation writes.
  foreach key in array st_keys loop
   begin
    perform noop_project_append_batch(u,d,s,b,st.stream,jsonb_build_array(r||jsonb_build_object(key,null)));
    raise exception 'NULL accepted: % %',st.stream,key;
   exception when sqlstate '22023' then cases:=cases+1; end;
   begin
    perform noop_project_append_batch(u,d,s,b,st.stream,jsonb_build_array(r-key));
    raise exception 'missing key accepted: % %',st.stream,key;
   exception when sqlstate '22023' then cases:=cases+1; end;
  end loop;
  assert not exists(select 1 from noop_projection_observations where user_id=u and batch_id=b),'null guard wrote observations';
  assert noop_project_append_batch(u,d,s,b,st.stream,jsonb_build_array(r))=1,'fresh insert failed';
  execute format('select count(*) from %I where user_id=$1',st_target) into n using u;
  assert n=4,'fresh insert count'; cases:=cases+1;
  execute format('select count(*) from %I t where user_id=$1 and to_jsonb(t) @> $2',st_target) into n using u,r;
  assert n=1,'fresh typed payload changed';
  assert noop_project_append_batch(u,d,s,b,st.stream,jsonb_build_array(r))=1,'retry failed';
  assert (select count(*) from noop_projection_observations where user_id=u and batch_id=b)=1,'retry duplicated observation';
  execute format('select count(*) from %I where user_id=$1',st_target) into n using u;
  assert n=4,'retry duplicated typed row'; cases:=cases+1;
  bad:=r||jsonb_build_object(st.field,st.val);
  begin
   perform noop_project_append_batch(u,d,s,b,st.stream,jsonb_build_array(bad));
   raise exception 'mutated batch accepted: %',st.stream;
  exception when unique_violation then cases:=cases+1; end;
  -- Same first key, different second/third key must remain independent (RR and event).
  expected:=4;
  if cardinality(st_keys)>1 then
   foreach key in array st_keys[2:cardinality(st_keys)] loop
    bad:=r||jsonb_build_object('batch_id',md5(st.stream||key)::uuid);
    if key='kind' then bad:=bad||jsonb_build_object(key,'distinct-kind');
    else bad:=bad||jsonb_build_object(key,(r->>key)::bigint+10); end if;
    if st.stream='rrPacketProvenance' then bad:=bad||jsonb_build_object('packetId',repeat('c',64)); end if;
    assert noop_project_append_batch(u,d,s,(bad->>'batch_id')::uuid,st.stream,jsonb_build_array(bad))=1,'composite insert';
    expected:=expected+1; cases:=cases+1;
   end loop;
  end if;
  bad:=r||jsonb_build_object(st.field,st.val,'batch_id',b2);
  assert noop_project_append_batch(u,d,s,b2,st.stream,jsonb_build_array(bad))=1,'conflict call failed';
  assert (select count(*) from noop_projection_conflicts where user_id=u and stream=st.stream)=1,'conflict not quarantined';
  execute format('select count(*) from %I where user_id=$1',st_target) into n using u;
  assert n=expected-1,'conflict DELETE failed or deleted composite sibling'; cases:=cases+1;
  -- Original receipt retry cannot resurrect quarantined identity.
  perform noop_project_append_batch(u,d,s,b,st.stream,jsonb_build_array(r));
  execute format('select count(*) from %I where user_id=$1',st_target) into n using u;
  assert n=expected-1,'conflicted retry resurrected row'; cases:=cases+1;
  -- Mid-batch validation error must roll back its earlier observation, conflict and typed work.
  before_obs:=(select count(*) from noop_projection_observations where user_id=u);
  bad:=r||jsonb_build_object('batch_id',md5('atomic-'||st.stream)::uuid);
  begin
   perform noop_project_append_batch(u,d,s,(bad->>'batch_id')::uuid,st.stream,jsonb_build_array(bad,bad||jsonb_build_object(st_keys[1],null)));
   raise exception 'partial batch accepted';
  exception when sqlstate '22023' then cases:=cases+1; end;
  assert (select count(*) from noop_projection_observations where user_id=u)=before_obs,'partial observation committed';
  execute format('select count(*) from %I where user_id=$1',st_target) into n using u;
  assert n=expected-1,'partial typed mutation committed';
  raise notice 'STREAM_PASS %',jsonb_build_object('stream',st.stream,'casesSoFar',cases,'nullKeys',st_keys,'typedRemaining',n);
 end loop;
 -- Guards common to every target remain outside the changed predicate.
 select to_jsonb(t)||jsonb_build_object('batch_id',b) into r from noop_hr_samples t where user_id=u limit 1;
 perform set_config('request.jwt.claim.role','authenticated',true);
 begin perform noop_project_append_batch(u,d,s,b,'hrSample',jsonb_build_array(r)); raise exception 'auth accepted'; exception when insufficient_privilege then cases:=cases+1; end;
 perform set_config('request.jwt.claim.role','service_role',true);
 begin perform noop_project_append_batch(u,d,s,b,'hrSample',jsonb_build_array(r||jsonb_build_object('source_id',d))); raise exception 'wrong source accepted'; exception when insufficient_privilege then cases:=cases+1; end;
 begin perform noop_project_append_batch(u,d,s,b,'hrSample','[]'); raise exception 'empty accepted'; exception when sqlstate '22023' then cases:=cases+1; end;
 begin perform noop_project_append_batch(u,d,s,b,'hrSample',(select jsonb_agg(r) from generate_series(1,5001))); raise exception '5001 accepted'; exception when sqlstate '22023' then cases:=cases+1; end;
 begin perform noop_project_append_batch(u,d,s,b,'unknown',jsonb_build_array(r)); raise exception 'unknown accepted'; exception when sqlstate '22023' then cases:=cases+1; end;
 begin perform noop_project_append_batch(u,d,s,b,'hrSample',jsonb_build_array(r||'{"unknown_column":1}')); raise exception 'unknown column accepted'; exception when sqlstate '22023' then cases:=cases+1; end;
 update noop_app_installations set revoked_at=now() where source_id=s;
 begin perform noop_project_append_batch(u,d,s,b,'hrSample',jsonb_build_array(r)); raise exception 'revoked accepted'; exception when insufficient_privilege then cases:=cases+1; end;
  update noop_app_installations set revoked_at=null where source_id=s;
 begin
  update noop_app_installations set retired_at=now(),retirement_id=gen_random_uuid() where source_id=s;
  begin perform noop_project_append_batch(u,d,s,b,'hrSample',jsonb_build_array(r)); raise exception 'retired accepted'; exception when insufficient_privilege then null; end;
  raise no_data_found;
 exception when no_data_found then cases:=cases+1; end;
 begin perform noop_project_append_batch(u,'a1455555-5555-4555-8555-555555555555',s,b,'hrSample',jsonb_build_array(r)); raise exception 'unowned accepted'; exception when insufficient_privilege then cases:=cases+1; end;
 insert into noop_wearable_aliases(user_id,source_id,provisional_device_id,canonical_device_id,evidence) values(u,s,d,'a1444444-4444-4444-8444-444444444444','{}');
 begin perform noop_project_append_batch(u,d,s,b,'hrSample',jsonb_build_array(r)); raise exception 'alias accepted'; exception when sqlstate 'PT409' then cases:=cases+1; end;
 delete from noop_wearable_aliases where user_id=u;
 -- Packet clock quarantine also blocks later RR interval representations at the same clock.
 select to_jsonb(t) into r from noop_rr_intervals t where user_id=u limit 1;
 select ts into n from noop_rr_clock_conflicts where user_id=u limit 1;
 assert n is not null,'packet conflict lost clock quarantine';
 b:=md5('clock-quarantine')::uuid;
 r:=r||jsonb_build_object('ts',n,'batch_id',b);
 perform noop_project_append_batch(u,d,s,b,'rrInterval',jsonb_build_array(r));
 assert not exists(select 1 from noop_rr_intervals where user_id=u and ts=n),'clock-quarantined RR resurrected';
 assert exists(select 1 from noop_projection_conflicts where user_id=u and stream='rrInterval' and reason='packet_clock_or_bytes_disagreement'),'missing clock conflict'; cases:=cases+1;
 raise notice 'SEMANTICS_PASS cases=%',cases;
end $$;
select jsonb_build_object('observations',count(*),'rows',jsonb_agg(to_jsonb(t)-'received_at' order by stream,batch_id,measurement_key::text)) from noop_projection_observations t where user_id='a1411111-1111-4111-8111-111111111111';
select jsonb_build_object('conflicts',count(*),'rows',jsonb_agg(to_jsonb(t)-'detected_at' order by stream,measurement_key::text)) from noop_projection_conflicts t where user_id='a1411111-1111-4111-8111-111111111111';
rollback;
