-- Result discovery is metadata only. Values still pass the selected, qualified read contract.
begin;
create sequence public.server_result_day_change_seq;
create table public.server_result_days (
  user_id uuid not null references auth.users on delete cascade,
  device_id uuid not null references public.devices on delete cascade,
  day date not null,
  change_revision bigint not null default nextval('public.server_result_day_change_seq'),
  primary key(user_id,device_id,day)
);
create index server_result_days_cursor on public.server_result_days(user_id,device_id,change_revision);
alter table public.server_result_days enable row level security;
revoke all on public.server_result_days,public.server_result_day_change_seq from public,anon,authenticated;
grant all on public.server_result_days,public.server_result_day_change_seq to service_role;
create policy machine_access on public.server_result_days for all to service_role using(true) with check(true);

create function public.touch_server_result_day() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare row_data jsonb:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  u uuid:=(row_data->>'user_id')::uuid; d uuid:=(row_data->>'device_id')::uuid;
  period date:=coalesce(row_data->>'period_day',row_data->>'day')::date;
begin
  if tg_op='DELETE' and not exists(select 1 from devices where id=d and user_id=u) then return null; end if;
  -- Serialize sequence allocation through commit per device, so a delayed transaction
  -- cannot commit an older cursor after the reader has already advanced past it.
  perform pg_advisory_xact_lock(hashtextextended('result-days:'||u::text||':'||d::text,0));
  insert into server_result_days(user_id,device_id,day) values(u,d,period)
  on conflict(user_id,device_id,day) do update set change_revision=nextval('public.server_result_day_change_seq');
  return null;
end $$;
revoke all on function public.touch_server_result_day() from public,anon,authenticated;
create trigger result_day_changed after insert or update or delete on public.server_physiology_results
  for each row execute function public.touch_server_result_day();
create trigger result_day_changed after insert or update or delete on public.server_compute_dispositions
  for each row execute function public.touch_server_result_day();
create trigger result_day_changed after insert or update or delete on public.scoring_work_items
  for each row execute function public.touch_server_result_day();
create trigger result_day_changed after insert or update or delete on public.physiology_work_items
  for each row execute function public.touch_server_result_day();

insert into server_result_days(user_id,device_id,day)
select user_id,device_id,period_day from server_physiology_results
union select user_id,device_id,day from server_compute_dispositions
union select user_id,device_id,day from scoring_work_items
union select user_id,device_id,day from physiology_work_items;

create function public.server_result_days_page(p_user uuid,p_device uuid,p_source uuid,
  p_after bigint default 0,p_limit integer default 8,p_scope_revision text default null)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare scope_revision text; after_revision bigint; page jsonb; last_revision bigint; more boolean;
begin
  if auth.role() is distinct from 'service_role' and auth.uid() is distinct from p_user then
    raise exception 'owner required' using errcode='42501'; end if;
  if not exists(select 1 from devices where id=p_device and user_id=p_user and is_active)
    or exists(select 1 from noop_account_retirements where user_id=p_user)
    or not (exists(select 1 from noop_app_installations where source_id=p_source and user_id=p_user and revoked_at is null and retired_at is null)
      or exists(select 1 from compute_account_sources where source_id=p_source and user_id=p_user and revoked_at is null))
    or exists(select 1 from noop_app_installations where source_id=p_source and (user_id<>p_user or revoked_at is not null or retired_at is not null))
    or exists(select 1 from compute_account_sources where source_id=p_source and (user_id<>p_user or revoked_at is not null)) then
    raise exception 'active owned source and device required' using errcode='42501'; end if;
  if p_after is null or p_after<0 or p_limit is null or p_limit not between 1 and 32 then
    raise exception 'invalid result cursor' using errcode='22023'; end if;
  -- Selection/qualification changes invalidate discovery independently of publication.
  select md5(jsonb_build_array(
    (select jsonb_agg(to_jsonb(s) order by feature) from physiology_source_selection s where user_id=p_user),
    (select jsonb_agg(to_jsonb(f) order by feature) from physiology_feature_defaults f),
    (select jsonb_agg(to_jsonb(q) order by algorithm_version,feature) from physiology_feature_qualifications q),
    (select jsonb_agg(to_jsonb(r) order by approval_id) from physiology_promotion_revocations r),
    (select jsonb_agg(to_jsonb(p) order by family) from compute_family_policy p),
    (select jsonb_agg(to_jsonb(z) order by effective_at) from scoring_timezone_history z where user_id=p_user))::text) into scope_revision;
  after_revision:=case when p_scope_revision=scope_revision then p_after else 0 end;
  select coalesce(jsonb_agg(jsonb_build_object('day',r.day,'change_revision',r.change_revision)
    order by r.change_revision),'[]'::jsonb),coalesce(max(r.change_revision),after_revision)
    into page,last_revision from (select day,change_revision from server_result_days
      where user_id=p_user and device_id=p_device and change_revision>after_revision
      order by change_revision limit p_limit) r;
  select exists(select 1 from server_result_days where user_id=p_user and device_id=p_device
    and change_revision>last_revision) into more;
  return jsonb_build_object('schema_version',1,'days',page,'next_cursor',last_revision,
    'has_more',more,'scope_revision',scope_revision,
    'timezone_id',public.scoring_timezone_at(p_user,now()));
end $$;
revoke all on function public.server_result_days_page(uuid,uuid,uuid,bigint,integer,text) from public,anon,authenticated;
grant execute on function public.server_result_days_page(uuid,uuid,uuid,bigint,integer,text) to service_role;
commit;
