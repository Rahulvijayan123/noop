-- Regression for 20261009140000_candidate_withheld_unresolved_adjacency.sql. Run ONLY against an isolated,
-- disposable full-schema database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh). Everything
-- runs in one transaction that is rolled back, so the database is left as it was.
--
--   psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/candidate_withheld_unresolved_adjacency.sql
--
-- Expected: a withheld `unresolved_adjacency` candidate is recorded with that reason; the nine plan reasons
-- still record; an unknown reason still raises invalid_candidate_reason; an `error` row keeps accepting any
-- reason (unchanged); the function's privileges are unchanged (service_role only).
\set ON_ERROR_STOP on
begin;
do $$
declare u uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); id uuid; r text; n int:=0;
  sig text:='public.physiology_record_candidate_result(uuid,text,text,date,timestamptz,timestamptz,text,'
    || 'bigint,text,text,text,text,text,text,jsonb,text,numeric,text,jsonb,text,jsonb,jsonb,integer)';
  reasons text[]:=array['blocked_input','blocked_artifact','blocked_license','unverified',
    'insufficient_coverage','artifact_fraction','provider_error','timeout','not_ready','unresolved_adjacency'];
begin
  insert into auth.users(id) values(u);
  insert into public.devices(id,user_id,source_kind,external_device_id) values(d,u,'noop_push',d::text);
  insert into public.physiology_provider_overrides(user_id,metric,provider_id,provider_version,config_version,mode)
    values(u,'hrv','frwhoop.hrv.v1','1.0.0','cfg-1','shadow');

  -- Every sidecar reason records as itself (one row per reason: the input hash is part of the dedup key).
  foreach r in array reasons loop
    n:=n+1;
    id:=public.physiology_record_candidate_result(u,d::text,'hrv',date '2026-10-08',
      timestamptz '2026-10-08 03:00:00+00',timestamptz '2026-10-08 03:05:00+00',
      encode(extensions.digest(r,'sha256'),'hex'),1,'frwhoop.hrv.v1','1.0.0','adapter-1','pre-1','cfg-1',
      'withheld','{}'::jsonb,r,null,null,null,null,null,'{"withheld_detail":"ambiguous_seq_ord"}'::jsonb,12);
    assert id is not null, 'withheld ' || r || ' was not recorded';
    assert (select withheld_reason from public.physiology_candidate_results where candidate_id=id)=r,
      'stored reason differs for ' || r;
  end loop;
  assert (select count(*) from public.physiology_candidate_results where user_id=u)=n;
  assert (select count(*) from public.physiology_candidate_results
           where user_id=u and withheld_reason='unresolved_adjacency')=1;

  -- An unknown reason on a withheld row is still a caller defect.
  begin
    perform public.physiology_record_candidate_result(u,d::text,'hrv',date '2026-10-08',
      timestamptz '2026-10-08 03:00:00+00',timestamptz '2026-10-08 03:05:00+00',repeat('b',64),1,
      'frwhoop.hrv.v1','1.0.0','adapter-1','pre-1','cfg-1','withheld','{}'::jsonb,'banana',
      null,null,null,null,null,null,12);
    raise exception 'unknown withheld reason was accepted';
  exception when sqlstate '22023' then
    assert sqlerrm='invalid_candidate_reason', sqlerrm;
  end;

  -- An error row keeps accepting a free-form reason (unchanged by this migration).
  id:=public.physiology_record_candidate_result(u,d::text,'hrv',date '2026-10-08',
    timestamptz '2026-10-08 03:00:00+00',timestamptz '2026-10-08 03:05:00+00',repeat('c',64),1,
    'frwhoop.hrv.v1','1.0.0','adapter-1','pre-1','cfg-1','error','{}'::jsonb,'banana',
    null,null,null,null,null,null,12);
  assert id is not null, 'error row was refused';

  -- Privileges unchanged: service_role only.
  assert has_function_privilege('service_role', sig, 'execute');
  assert not has_function_privilege('authenticated', sig, 'execute');
  assert not has_function_privilege('anon', sig, 'execute');
  raise notice 'candidate_withheld_unresolved_adjacency: ok (% reasons)', n;
end $$;
rollback;
