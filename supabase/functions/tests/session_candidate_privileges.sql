-- Reviewer-owned disposable-schema check. No credentials, application data or production mutations.
begin;
do $$ declare role_name text; column_name text; begin
 foreach role_name in array array['anon','authenticated','service_role'] loop
  assert not has_function_privilege(role_name,'public.read_compute_session_result_before_numerical(uuid,uuid,uuid,uuid)','execute'),
    'old session reader must not bypass candidate qualification and withdrawal';
  assert not has_table_privilege(role_name,'public.compute_session_numerical_candidates','insert'),
    'candidate insertion must use exact scoped publication';
  assert not has_table_privilege(role_name,'public.compute_session_numerical_candidates','update'),
    'published numerical candidates must be immutable';
  assert not has_table_privilege(role_name,'public.compute_session_requests','delete'),
    'request scheduling cannot erase immutable source requests';
  assert not has_table_privilege(role_name,'public.compute_session_requests','truncate'),
    'request scheduling cannot truncate the retained request journal';
  foreach column_name in array array['request','consent','user_id','device_id','source_id','event_start','event_end','expires_at'] loop
   assert not has_column_privilege(role_name,'public.compute_session_requests',column_name,'update'),
     'request scheduling cannot rewrite identity consent or event bounds';
  end loop;
 end loop;
 foreach column_name in array array['numerical_attempted_at','numerical_retry_after','numerical_last_error'] loop
  assert has_column_privilege('service_role','public.compute_session_requests',column_name,'update'),
    'worker must retain bounded scheduling progress';
 end loop;
 assert has_function_privilege('service_role','public.read_compute_session_result(uuid,uuid,uuid,uuid)','execute');
 assert not has_function_privilege('authenticated','public.read_compute_session_result(uuid,uuid,uuid,uuid)','execute');
end $$;
rollback;
