-- Reviewer-owned isolated PostgreSQL regression; synthetic inputs, no production approvals or data.
begin;
set local request.jwt.claim.role='service_role';
do $$
declare u uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); src uuid:=gen_random_uuid();
 req uuid:=gen_random_uuid(); session uuid:=gen_random_uuid(); old_day date:=(now() at time zone 'UTC')::date-20;
 today date:=(now() at time zone 'UTC')::date; old_fp text; denied_fp text; granted_fp text; original jsonb;
 old_config bigint; latest_config bigint; current_consent jsonb;
begin
 insert into auth.users(id) values(u);
 insert into public.profiles(id,timezone) values(u,'UTC') on conflict(id) do update set timezone='UTC';
 insert into public.devices(id,user_id,source_kind,device_family) values(d,u,'noop_push','whoop5');
 insert into public.compute_account_sources(user_id,source_id) values(u,src);
 insert into public.physiology_work_items(user_id,device_id,day) values(u,d,old_day) on conflict do nothing;
 original:=jsonb_build_object('id',req,'family','insights','session_id',session,
   'event_start',to_char(old_day-20,'YYYY-MM-DD')||'T00:00:00Z','event_end',to_char(old_day,'YYYY-MM-DD')||'T12:00:00Z',
   'timezone_id','UTC','input_revision',0,'algorithm_version','vps-only-1','configuration_version','vps-only-1',
   'consent',true,'expires_at',null);
 perform public.submit_compute_session_request(u,d,src,original);
 -- This prior grant is valid at the old request's event day, but must not override a later denial.
 insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
   expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
 values(u,d,'config','primary',old_day-21,'{"schemaVersion":1,"journalContextEnabled":true}',false,
   0,gen_random_uuid(),gen_random_uuid(),1,old_day-21) returning revision into old_config;
 old_fp:=public.compute_session_source_fingerprint(req);
 insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
   expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
 values(u,d,'config','primary',today,'{"schemaVersion":1,"journalContextEnabled":false}',false,
   old_config,gen_random_uuid(),gen_random_uuid(),1,today) returning revision into latest_config;
 denied_fp:=public.compute_session_source_fingerprint(req);
 assert old_fp is distinct from denied_fp,
   'current consent denial must invalidate an old request fingerprint, not consult only historical consent';
 current_consent:=public.compute_session_journal_consent(u,d);
 assert current_consent->'allowed'='false'::jsonb and (current_consent->>'revision')::bigint=latest_config;
 assert public.compute_session_journal_consent(gen_random_uuid(),d)->'allowed'='false'::jsonb,
   'missing or another-owner consent cannot authorize retained journal use';
 insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
   expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
 values(u,d,'config','primary',today,'{"schemaVersion":1,"journalContextEnabled":true}',false,
   latest_config,gen_random_uuid(),gen_random_uuid(),1,today) returning revision into latest_config;
 assert public.compute_session_journal_consent(u,d)->'allowed'='true'::jsonb;
 granted_fp:=public.compute_session_source_fingerprint(req);
 assert granted_fp is distinct from denied_fp;
 -- Future-effective denial is not current consent; this also tests explicit hosted-calendar ownership.
 insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
   expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
 values(u,d,'config','primary',today+1,'{"schemaVersion":1,"journalContextEnabled":false}',false,
   latest_config,gen_random_uuid(),gen_random_uuid(),1,today+1);
 assert public.compute_session_journal_consent(u,d)->'allowed'='true'::jsonb;
 assert granted_fp=public.compute_session_source_fingerprint(req);
 insert into public.scoring_history_inputs_v3(user_id,device_id,kind,entity,effective_day,payload,deleted,
   expected_revision,client_id,client_mutation_id,client_revision,invalidated_from)
 values(u,d,'config','primary',today,'{}',true,
   latest_config,gen_random_uuid(),gen_random_uuid(),1,today);
 assert public.compute_session_journal_consent(u,d)->'allowed'='false'::jsonb,
   'a deleted current config is not a surviving historic consent grant';
 assert (select request=original from public.compute_session_requests where id=req),
   'consent withdrawal must preserve original request bytes and identity';
 assert not has_function_privilege('authenticated','public.compute_session_journal_consent(uuid,uuid)','execute');
 assert not has_function_privilege('anon','public.compute_session_journal_consent(uuid,uuid)','execute');
 assert has_function_privilege('service_role','public.compute_session_journal_consent(uuid,uuid)','execute');
end $$;
rollback;
