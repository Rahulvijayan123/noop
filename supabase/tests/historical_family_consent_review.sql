-- Independent SQL authorization-contract fixture ONLY. Numbers and signatures
-- below are synthetic; this is not producer, reference, VPS or phone evidence.
-- Requires an isolated full-schema database and PGAPPNAME=build373-family-consent-review.
begin;
set local request.jwt.claim.role='service_role';
do $$
declare
  u uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); src uuid:=gen_random_uuid();
  u2 uuid:=gen_random_uuid(); d2 uuid:=gen_random_uuid();
  today date:=(now() at time zone 'UTC')::date; old_day date:=today-20;
  version text:='frwhoop-server-2-history'; key_id text;
  secret bytea:=extensions.gen_random_bytes(32); approval uuid; family text; metric text;
  manifest jsonb; candidate jsonb; candidates jsonb:='{}'; signed text; snapshot jsonb; snapshot_id bigint;
  initial_config bigint; current_config bigint; before_revision text; before_payload jsonb;
  page_before jsonb; page_after jsonb; response jsonb; revoked jsonb;
  bad_revision jsonb; test_input bigint; test_snapshot bigint;
begin
  assert current_setting('application_name')='build373-family-consent-review', 'disposable-review invocation required';
  key_id:=encode(sha256(secret),'hex');
  insert into auth.users(id) values(u);
  insert into public.profiles(id,timezone) values(u,'UTC') on conflict(id) do update set timezone='UTC';
  insert into public.devices(id,user_id,source_kind,device_family,is_active) values(d,u,'noop_push','whoop5',true);
  insert into public.compute_account_sources(user_id,source_id) values(u,src);
  insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
    values(u,d,'config','primary',old_day-1,'{"schemaVersion":1,"journalContextEnabled":true,"cycleAwarenessEnabled":true}',false,
      0,gen_random_uuid(),gen_random_uuid(),1,old_day-1) returning revision into initial_config;
  insert into internal.physiology_approval_keys values(key_id,secret,'disposable-consent-review',null);
  foreach family in array array['illness','cycle'] loop
    metric:=case family when 'illness' then 'illness_score' else 'cycle_phase' end;
    manifest:=jsonb_build_object('schema_version',1,'family',family,'algorithm_version',version,'implementation_sha256',repeat('a',64));
    candidate:=jsonb_build_object('owner','server','owner_id',u,'device_id',d,'window',old_day,
      'timezone_id','UTC','algorithm_version',version,'configuration_version',initial_config::text,
      'feature_manifest',manifest,'feature_manifest_canonical',manifest::text,
      'feature_manifest_hash',encode(sha256(convert_to(manifest::text,'UTF8')),'hex'),
      'values',jsonb_build_object(metric,case family when 'illness' then '42'::jsonb else '"follicular"'::jsonb end),
      'producer_generated',jsonb_build_array(metric),'canonical_input_eligible',jsonb_build_array(metric),
      'details',jsonb_build_object('current_configuration_revision',initial_config));
    candidates:=candidates||jsonb_build_object(family,candidate);
    approval:=gen_random_uuid();
    signed:=jsonb_build_object('schema_version',1,'purpose','compute_family_promotion','approval_id',approval,
      'key_id',key_id,'reviewer','disposable-consent-review','decision','approved','family',family,
      'algorithm_version',version,'feature_manifest_hash',candidate->>'feature_manifest_hash',
      'implementation_sha256',repeat('a',64),'approved_metrics',jsonb_build_array(metric),
      'evaluation_sha256',repeat('b',64),'policy_sha256',repeat('c',64),'reference_artifact_sha256',repeat('d',64),
      'reference_kind','qualified_'||family||'_reference','evaluation_partition','test',
      'participant_disjoint',true,'functional_gates_passed',true,'promotion_policy_passed',true,'input_contract_verified',true,
      'policy_frozen_at','2020-01-01T00:00:00Z','evaluation_started_at','2020-01-02T00:00:00Z',
      'evaluation_finished_at','2020-01-03T00:00:00Z','approved_at','2020-01-04T00:00:00Z')::text;
    insert into public.compute_family_approvals(approval_id,family,algorithm_version,feature_manifest_hash,
      implementation_sha256,approved_metrics,key_id,signed_payload,signature_hex)
      values(approval,family,version,candidate->>'feature_manifest_hash',repeat('a',64),array[metric],key_id,signed,
        encode(extensions.hmac(convert_to(signed,'UTF8'),secret,'sha256'),'hex'));
    insert into public.compute_family_selections(user_id,device_id,family,approval_id) values(u,d,family,approval);
  end loop;
  -- Explicit synthetic completed-history fixture. No trigger is disabled and no
  -- real worker/receipt qualification is claimed by this contract-only setup.
  insert into public.scoring_algorithms_v2(algorithm_version,enabled,active) values(version,true,false)
    on conflict(algorithm_version) do update set enabled=true;
  insert into public.scoring_history_algorithms_v3(algorithm_version,state_schema_version) values(version,1) on conflict do nothing;
  insert into public.scoring_jobs_v2(user_id,device_id,day,algorithm_version,input_revision,completed_revision)
    values(u,d,old_day,version,1,1);
  insert into public.scoring_history_heads_v3(user_id,device_id,algorithm_version,generation,latest_day)
    values(u,d,version,1,old_day) on conflict(user_id,device_id,algorithm_version)
      do update set dirty_from=null;
  snapshot:=jsonb_build_object('timezone','UTC','dataThrough',old_day::text||'T12:00:00Z','family_candidates',candidates);
  insert into public.scoring_snapshots_v2(user_id,device_id,day,algorithm_version,input_revision,computed_at,payload)
    values(u,d,old_day,version,1,now(),snapshot) returning result_revision into snapshot_id;
  insert into public.scoring_history_checkpoints_v3(result_revision,user_id,device_id,algorithm_version,day,input_revision,
    generation,timezone,configuration_revision,profile_revision,state)
    values(snapshot_id,u,d,version,old_day,1,1,'UTC',initial_config,0,'{}');
  set constraints all immediate;
  response:=public.server_scoring_read_contract(u,old_day,d);
  foreach family in array array['illness','cycle'] loop
    assert response->'compute'->'families'->family->>'status'='available', 'positive selected contract missing: '||family;
  end loop;
  before_revision:=response->'compute'->'families'->'illness'->>'result_revision';
  select payload into before_payload from public.scoring_snapshots_v2 where result_revision=snapshot_id;
  page_before:=public.server_result_days_page(u,d,src,0,8,null);

  -- Malformed captured revisions must withhold through the actual public reader,
  -- not throw a bigint cast error. Roll back these synthetic complete snapshots
  -- in a subtransaction before testing permission changes on the original.
  begin
    for bad_revision in select value from jsonb_array_elements('[null,"1",0,-1,1.5,9223372036854775808,1e1000]'::jsonb) loop
      set constraints scoring_history_publication_v3 deferred;
      update public.scoring_jobs_v2 set input_revision=input_revision+1,completed_revision=input_revision+1
        where user_id=u and device_id=d and day=old_day and algorithm_version=version returning input_revision into test_input;
      update public.scoring_history_heads_v3 set dirty_from=null where user_id=u and device_id=d and algorithm_version=version;
      snapshot:=jsonb_set(before_payload,'{family_candidates,illness,details,current_configuration_revision}',bad_revision);
      insert into public.scoring_snapshots_v2(user_id,device_id,day,algorithm_version,input_revision,computed_at,payload)
        values(u,d,old_day,version,test_input,now(),snapshot) returning result_revision into test_snapshot;
      insert into public.scoring_history_checkpoints_v3(result_revision,user_id,device_id,algorithm_version,day,input_revision,
        generation,timezone,configuration_revision,profile_revision,state)
        values(test_snapshot,u,d,version,old_day,test_input,1,'UTC',initial_config,0,'{}');
      set constraints scoring_history_publication_v3 immediate;
      response:=public.server_scoring_read_contract(u,old_day,d);
      assert response->'compute'->'families'->'illness'->'values'->'illness_score'='null'::jsonb,
        'malformed revision authorized selected result';
      assert response->'compute'->'families'->'illness'->>'reason'='historical_input_admission_required',
        'malformed revision did not yield precise input-admission reason';
    end loop;
    raise exception using errcode='ZX001',message='rollback synthetic malformed snapshots';
  exception when sqlstate 'ZX001' then null;
  end;

  insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
    values(u,d,'config','primary',today,'{"schemaVersion":1,"journalContextEnabled":false,"cycleAwarenessEnabled":false}',false,
      initial_config,gen_random_uuid(),gen_random_uuid(),1,today) returning revision into current_config;
  revoked:=public.server_scoring_read_contract(u,old_day,d);
  foreach family in array array['illness','cycle'] loop
    metric:=case family when 'illness' then 'illness_score' else 'cycle_phase' end;
    assert revoked->'compute'->'families'->family->'values'->metric='null'::jsonb,
      'current consent denial must withdraw already published historical family: '||family;
    assert revoked->'compute'->'families'->family->>'status' is distinct from 'available';
  end loop;
  assert (select payload=before_payload from public.scoring_snapshots_v2 where result_revision=snapshot_id), 'consent rewrote immutable candidate';
  assert before_revision='sha256:'||encode(sha256(convert_to(before_payload::text,'UTF8')),'hex');
  page_after:=public.server_result_days_page(u,d,src,0,8,null);
  assert page_before is distinct from page_after, 'consent withdrawal did not wake result discovery';

  -- A future-effective grant cannot override today's denial.
  insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
    values(u,d,'config','primary',today+1,'{"schemaVersion":1,"journalContextEnabled":true,"cycleAwarenessEnabled":true}',false,
      current_config,gen_random_uuid(),gen_random_uuid(),1,today+1);
  response:=public.server_scoring_read_contract(u,old_day,d);
  assert response->'compute'->'families'->'illness'->'values'->'illness_score'='null'::jsonb, 'future consent enabled a present read';
  insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
    values(u,d,'config','primary',today,'{"schemaVersion":1,"journalContextEnabled":true,"cycleAwarenessEnabled":true}',false,
      current_config,gen_random_uuid(),gen_random_uuid(),1,today) returning revision into current_config;
  response:=public.server_scoring_read_contract(u,old_day,d);
  assert response->'compute'->'families'->'illness'->>'status'='available', 'explicit current grant not admitted';
  assert response->'compute'->'families'->'illness'->>'result_revision'=before_revision, 'grant manufactured replacement immutable revision';
  insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
    values(u,d,'config','primary',today,'{"schemaVersion":1,"journalContextEnabled":true,"cycleAwarenessEnabled":true,"maxHR":191}',false,
      current_config,gen_random_uuid(),gen_random_uuid(),1,today) returning revision into current_config;
  response:=public.server_scoring_read_contract(u,old_day,d);
  assert response->'compute'->'families'->'illness'->>'status'='available', 'unrelated current config created permanent historical debt';
  assert response->'compute'->'families'->'illness'->>'result_revision'=before_revision;
  insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
    expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
    values(u,d,'config','primary',today,'{}',true,current_config,gen_random_uuid(),gen_random_uuid(),1,today);
  response:=public.server_scoring_read_contract(u,old_day,d);
  assert response->'compute'->'families'->'illness'->'values'->'illness_score'='null'::jsonb, 'deleted current config revived old grant';
  assert public.compute_historical_configuration(u,d)->'deleted'='true'::jsonb;
  assert public.compute_historical_configuration(u,d)->>'current_day'=today::text;
  assert public.compute_historical_configuration(u,d)->>'timezone_id'='UTC';
  begin
    perform public.compute_historical_configuration(gen_random_uuid(),d);
    raise exception 'wrong owner current configuration leaked';
  exception when insufficient_privilege then null;
  end;
  assert not has_function_privilege('anon','public.compute_historical_configuration(uuid,uuid)','execute');
  assert not has_function_privilege('authenticated','public.compute_historical_configuration(uuid,uuid)','execute');
  assert has_function_privilege('service_role','public.compute_historical_configuration(uuid,uuid)','execute');
  insert into auth.users(id) values(u2);
  insert into public.profiles(id,timezone) values(u2,'Pacific/Kiritimati') on conflict(id) do update set timezone='Pacific/Kiritimati';
  insert into public.scoring_timezone_history(user_id,effective_at,timezone_id,provenance)
    values(u2,now()-interval '1 second','Pacific/Kiritimati','synthetic_review_already_effective_timezone');
  insert into public.devices(id,user_id,source_kind,device_family,is_active) values(d2,u2,'noop_push','whoop5',true);
  response:=public.compute_historical_configuration(u2,d2);
  assert response->'deleted'='true'::jsonb and response->'revision'='0'::jsonb, 'absent configuration is not denial';
  assert response->>'current_day'=((now() at time zone 'Pacific/Kiritimati')::date)::text,
    'current permission ignored hosted civil calendar';
  assert response->>'timezone_id'='Pacific/Kiritimati';
end $$;
rollback;
select 'PASS historical family consent contract, synthetic fixture only' as result;
