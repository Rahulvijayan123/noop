-- Run after the real frozen-v1 JDBC publication tests in a disposable database.
-- Never manufacture a published payload to prove calendar propagation.
begin;
set local statement_timeout='30s';
select set_config('request.jwt.claim.role','service_role',true);
do $$
declare s record; f record; body jsonb; matched integer:=0; non_utc integer:=0;
begin
  for s in select * from (
    select r.*,row_number() over(partition by r.payload->'calendar'->>'timezone_id'
      order by r.period_day,r.user_id,r.input_revision desc) as calendar_sample
    from public.server_physiology_results r
    join public.devices d on d.id=r.device_id and d.user_id=r.user_id and d.is_active
    where r.algorithm_version='frwhoop-server-1'
      and not exists(select 1 from public.noop_account_retirements a where a.user_id=r.user_id)
      and r.payload->'calendar'->>'policy_version'='job-calendar-1'
  ) samples where calendar_sample<=4 loop
    body:=public.server_scoring_read_contract(s.user_id,s.period_day,s.device_id);
    for f in select key,value from jsonb_each(body->'compute'->'families') loop
      if f.value->>'result_revision'='sha256:'||s.payload_hash then
        if f.value->>'owner_id' is distinct from s.user_id::text
          or f.value->>'device_id' is distinct from s.device_id::text
          or f.value->>'window' is distinct from s.period_day::text
          or f.value->>'input_revision' is distinct from s.input_revision::text
          or f.value->>'timezone_id' is distinct from s.payload->'calendar'->>'timezone_id'
          or f.value->'details'->'publication_calendar' is distinct from s.payload->'calendar' then
          raise exception 'immutable calendar binding failed for % %',s.payload_hash,f.key;
        end if;
        matched:=matched+1;
        if s.payload->'calendar'->>'timezone_id'<>'UTC' then non_utc:=non_utc+1; end if;
      end if;
    end loop;
  end loop;
  if matched=0 or non_utc=0 then
    raise exception 'actual selected v1 UTC and non-UTC publication fixtures required';
  end if;
  raise notice 'PASS: % exact immutable selected-family calendar bindings (% non-UTC)',matched,non_utc;
end $$;
rollback;
