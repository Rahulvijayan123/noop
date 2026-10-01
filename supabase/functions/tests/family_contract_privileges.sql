-- Disposable fully migrated database only; no application data required or modified.
begin;
do $$ declare role_name text; begin
 foreach role_name in array array['anon','authenticated','service_role'] loop
  assert not has_function_privilege(role_name,'public.server_scoring_read_contract_before_families(uuid,date,uuid)','execute'),
    'pre-family-selection reader must not remain an exposed RPC';
  assert not has_table_privilege(role_name,'public.compute_family_approvals','insert'),
    'API or worker identity may not create its own scientific approval';
  assert not has_table_privilege(role_name,'public.compute_family_selections','insert'),
    'API or worker identity may not promote a family';
  assert not has_table_privilege(role_name,'public.compute_family_revocations','delete'),
    'API or worker identity may not remove a revocation';
 end loop;
 assert has_function_privilege('authenticated','public.server_scoring_read_contract(uuid,date,uuid)','execute');
 assert has_function_privilege('service_role','public.server_scoring_read_contract(uuid,date,uuid)','execute');
 assert not has_function_privilege('anon','public.server_scoring_read_contract(uuid,date,uuid)','execute');
end $$;
rollback;
