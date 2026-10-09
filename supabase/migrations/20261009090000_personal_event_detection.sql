-- Prepared for maintainer deployment. Does not enable a worker or schedule by itself.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create view public.manual_events_current with (security_barrier = true) as
  select distinct on (user_id, entity_id) user_id, entity_id, revision_id, seq, received_at,
    body->'entry' as entry from public.manual_event_revisions
  order by user_id, entity_id, updated_at_ms desc, revision_id desc;
revoke all on public.manual_events_current from public, anon, authenticated;
grant select on public.manual_events_current to service_role;

create table public.event_detector_settings (
  user_id uuid not null references auth.users(id) on delete cascade,
  type_id uuid not null, enabled boolean not null default false,
  revision bigint not null default 1, state text not null default 'off',
  active_model_id uuid, last_training_at timestamptz, last_input_at timestamptz,
  detail jsonb not null default '{}', updated_at timestamptz not null default now(),
  primary key(user_id,type_id)
);
create table public.event_detector_jobs (
  user_id uuid not null, type_id uuid not null, kind text not null check(kind in ('train','infer')),
  due_at timestamptz not null default now(), lease_token uuid, lease_until timestamptz,
  settings_revision bigint, attempts integer not null default 0,
  primary key(user_id,type_id,kind), foreign key(user_id,type_id)
    references public.event_detector_settings on delete cascade
);
create table public.event_detector_models (
  user_id uuid not null, type_id uuid not null, id uuid not null,
  manifest jsonb not null, artifact bytea not null check(octet_length(artifact) <= 16777216),
  created_at timestamptz not null default now(),
  primary key(user_id,id), foreign key(user_id,type_id)
    references public.event_detector_settings on delete cascade
);
create table public.event_detector_runs (
  user_id uuid not null, type_id uuid not null, id uuid not null,
  snapshot text not null, report jsonb not null, created_at timestamptz not null default now(),
  primary key(user_id,id), foreign key(user_id,type_id)
    references public.event_detector_settings on delete cascade
);
create table public.event_detection_state (
  user_id uuid not null, type_id uuid not null, device_id uuid not null,
  day date not null, input_revision bigint not null default 0,
  state jsonb not null default '{}', primary key(user_id,type_id,device_id,day),
  foreign key(user_id,type_id) references public.event_detector_settings on delete cascade
);
create table public.event_detection_inputs (
  user_id uuid not null references auth.users(id) on delete cascade, device_id uuid not null,
  day date not null, revision bigint not null default 1, updated_at timestamptz not null default now(),
  primary key(user_id,device_id,day)
);
create table public.event_detection_input_changes (
  user_id uuid not null references auth.users(id) on delete cascade, device_id uuid not null,
  day date not null, revision bigint not null, first_ts double precision not null, last_ts double precision not null,
  primary key(user_id,device_id,day,revision)
);
-- One invalidation per device/day per SQL insert, not one job per sensor sample.
create function public.event_sensor_input_changed() returns trigger language plpgsql
security definer set search_path=public,pg_temp as $$ declare item record; rev bigint; begin
  for item in select x.user_id,x.device_id,d.input_day,min(x.ts) lo,max(x.ts) hi
    from inserted_samples x cross join lateral (
      select (to_timestamp(x.ts) at time zone 'UTC')::date as input_day
      union select (to_timestamp(x.ts+32) at time zone 'UTC')::date
    ) d where exists(select 1 from event_detector_settings s where s.user_id=x.user_id and s.enabled)
      and exists(select 1 from auth.users u where u.id=x.user_id)
    group by 1,2,3 loop
    insert into event_detection_inputs(user_id,device_id,day) values(item.user_id,item.device_id,item.input_day)
      on conflict(user_id,device_id,day) do update set revision=event_detection_inputs.revision+1,updated_at=now()
      returning revision into rev;
    insert into event_detection_input_changes values(item.user_id,item.device_id,item.input_day,rev,item.lo,item.hi);
  end loop;
  return null;
end $$;
create trigger event_hr_arrival after insert on public.noop_hr_samples
  referencing new table as inserted_samples for each statement execute function public.event_sensor_input_changed();
create trigger event_temperature_arrival after insert on public.noop_skin_temp_samples
  referencing new table as inserted_samples for each statement execute function public.event_sensor_input_changed();
create trigger event_hr_update after update on public.noop_hr_samples
  referencing new table as inserted_samples for each statement execute function public.event_sensor_input_changed();
create trigger event_hr_remove after delete on public.noop_hr_samples
  referencing old table as inserted_samples for each statement execute function public.event_sensor_input_changed();
create trigger event_temperature_update after update on public.noop_skin_temp_samples
  referencing new table as inserted_samples for each statement execute function public.event_sensor_input_changed();
create trigger event_temperature_remove after delete on public.noop_skin_temp_samples
  referencing old table as inserted_samples for each statement execute function public.event_sensor_input_changed();
revoke all on function public.event_sensor_input_changed() from public,anon,authenticated;
create table public.event_detections (
  user_id uuid not null, id uuid not null, type_id uuid not null, device_id uuid not null,
  start_at double precision not null, end_at double precision not null,
  model_id uuid not null, status text not null default 'pending'
    check(status in ('pending','confirmed','rejected','unsure','archived','superseded')),
  manual_event_id uuid, owns_manual_event boolean not null default false, historical boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key(user_id,id), check(start_at >= 0 and end_at >= start_at),
  foreign key(user_id,type_id) references public.event_detector_settings on delete cascade
);
create index event_detections_feed on public.event_detections(user_id,start_at desc,id);
create table public.event_detection_reviews (
  user_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null, body jsonb not null, created_at timestamptz not null default now(),
  primary key(user_id,id)
);
create table public.event_detection_revisions (
  seq bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  detection_id uuid not null, body jsonb not null, created_at timestamptz not null default now()
);
create function public.retain_detection_revision() returns trigger language plpgsql
security definer set search_path=public,pg_temp as $$ begin
  insert into event_detection_revisions(user_id,detection_id,body) values(new.user_id,new.id,to_jsonb(new));
  return new;
end $$;
create trigger event_detection_revision after insert or update on public.event_detections
  for each row execute function public.retain_detection_revision();
revoke all on function public.retain_detection_revision() from public,anon,authenticated;
-- Clients cannot access model bytes, job credentials or state. The API is owner-scoped.
do $$ declare t text; begin
  foreach t in array array['event_detector_settings','event_detector_jobs','event_detector_models',
    'event_detector_runs','event_detection_state','event_detections','event_detection_reviews','event_detection_inputs','event_detection_input_changes','event_detection_revisions'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
    execute format('grant select,insert,update,delete on public.%I to service_role',t);
  end loop;
end $$;
-- Reviews are append-only to the service. Whole-account deletion still cascades.
revoke update,delete on public.event_detection_reviews from service_role;
revoke insert,update,delete on public.event_detection_revisions from service_role;

create function public.event_detection_command(p_user uuid,p_source uuid,p_body jsonb)
returns jsonb language plpgsql security definer set search_path = public,pg_temp as $$
declare typ uuid; r public.event_detections; label jsonb; event_entry jsonb; eid uuid; created boolean := false; stamp bigint;
  old jsonb; outcome text; request_id uuid := (p_body->>'requestId')::uuid;
begin
  if not exists(select 1 from noop_app_installations where user_id=p_user and source_id=p_source and revoked_at is null)
    and not exists(select 1 from compute_account_sources where user_id=p_user and source_id=p_source and revoked_at is null)
    then raise exception 'event_source_mismatch' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('event-detection:'||p_user::text,0));
  if request_id is null then raise exception 'request_id_required'; end if;
  select body into old from event_detection_reviews where user_id=p_user and id=request_id;
  if found then
    if old <> p_body then raise exception 'request_conflict'; end if;
    return jsonb_build_object('saved',request_id);
  end if;
  typ := (p_body->>'typeId')::uuid;
  select entry into label from manual_events_current where user_id=p_user and entity_id=typ
    and entry->>'kind'='event_type' and (entry->>'archived')::boolean=false;
  if label is null then raise exception 'unknown_event_type'; end if;
  if p_body->>'action'='setting' then
    insert into event_detector_settings(user_id,type_id,enabled,state)
      values(p_user,typ,(p_body->>'enabled')::boolean,
        case when (p_body->>'enabled')::boolean then 'needs_examples' else 'off' end)
    on conflict(user_id,type_id) do update set enabled=excluded.enabled,
      revision=event_detector_settings.revision+1, updated_at=now(),
      state=case when not excluded.enabled then 'off'
        when event_detector_settings.active_model_id is not null then 'active' else 'needs_examples' end;
    -- Fence and release both lanes. Even off -> on must not revive a pre-disable lease.
    update event_detector_jobs set lease_token=null,lease_until=null,due_at=now()
      where user_id=p_user and type_id=typ;
    if not (p_body->>'enabled')::boolean then
      delete from event_detection_state where user_id=p_user and type_id=typ;
    end if;
  elsif p_body->>'action'='review' then
    select * into r from event_detections where user_id=p_user and id=(p_body->>'detectionId')::uuid for update;
    if not found then raise exception 'unknown_detection'; end if;
    outcome := p_body->>'outcome';
    if outcome not in ('confirmed','rejected','unsure','archived') then raise exception 'invalid_outcome'; end if;
    if outcome='confirmed' then
      -- A retry, another phone, or a matching manual log must not create another occurrence.
      eid := case when r.owns_manual_event then r.id else r.manual_event_id end;
      if eid is null then
        select entity_id into eid from manual_events_current where user_id=p_user
          and entry->>'kind'='event' and (entry->>'typeId')::uuid=typ
          and (entry->>'archived')::boolean=false
          and (entry->>'startUnixSeconds')::double precision <= (p_body->>'end')::double precision
          and coalesce((entry->>'endUnixSeconds')::double precision,extract(epoch from now())) >= (p_body->>'start')::double precision
          order by seq desc limit 1;
      end if;
      if eid is null then eid := r.id; end if;
      created := r.owns_manual_event or not exists(select 1 from manual_events_current where user_id=p_user and entity_id=eid);
      event_entry := jsonb_build_object('id',eid,'kind','event','typeId',typ,'label',label->>'label',
        'symbol',label->>'symbol','favorite',false,'startUnixSeconds',(p_body->>'start')::double precision,
        'endUnixSeconds',(p_body->>'end')::double precision,'deviceId',r.device_id,
        'timeZoneIdentifier','UTC','archived',false);
      -- Preserve a matching log. Only an explicit review of this detection's prior log edits it.
      if created then
        select greatest(floor(extract(epoch from clock_timestamp())*1000)::bigint,coalesce(max(updated_at_ms),0)+1)
          into stamp from manual_event_revisions where user_id=p_user and entity_id=eid;
        perform append_manual_event_revisions(p_user,p_source,jsonb_build_array(jsonb_build_object(
          'revision_id',request_id,'updated_at_ms',stamp,'entry',event_entry)));
      end if;
    elsif r.owns_manual_event then
      select c.entry into event_entry from manual_events_current c where c.user_id=p_user and c.entity_id=r.id;
      if event_entry is not null then
        event_entry := event_entry || jsonb_build_object('archived',true,'archivedAt',extract(epoch from now()));
        select greatest(floor(extract(epoch from clock_timestamp())*1000)::bigint,coalesce(max(updated_at_ms),0)+1)
          into stamp from manual_event_revisions where user_id=p_user and entity_id=r.id;
        perform append_manual_event_revisions(p_user,p_source,jsonb_build_array(jsonb_build_object(
          'revision_id',request_id,'updated_at_ms',stamp,'entry',event_entry)));
      end if;
    end if;
    update event_detections set status=outcome,manual_event_id=case when outcome='confirmed' then eid else null end,
      owns_manual_event=r.owns_manual_event or created,updated_at=now()
      where user_id=p_user and id=r.id;
  elsif p_body->>'action'='withdraw' then
    if not exists(select 1 from event_detection_reviews where user_id=p_user and id=(p_body->>'reviewId')::uuid
      and (body->>'typeId')::uuid=typ and body->>'action'='negative') then raise exception 'unknown_review'; end if;
  elsif p_body->>'action' <> 'negative' then raise exception 'invalid_action'; end if;
  insert into event_detection_reviews(user_id,id,body) values(p_user,request_id,p_body);
  return jsonb_build_object('saved',request_id);
end $$;
revoke all on function public.event_detection_command(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.event_detection_command(uuid,uuid,jsonb) to service_role;

-- Archiving a type stops detection and fences jobs even when the setting screen is not open.
create function public.event_type_archive_fence() returns trigger language plpgsql
security definer set search_path=public,pg_temp as $$ begin
  if new.body->'entry'->>'kind'='event_type' and exists(select 1 from manual_events_current
    where user_id=new.user_id and entity_id=new.entity_id and (entry->>'archived')::boolean) then
    update event_detector_settings set enabled=false,state='off',revision=revision+1,updated_at=now()
      where user_id=new.user_id and type_id=new.entity_id;
    update event_detector_jobs set lease_token=null,lease_until=null where user_id=new.user_id and type_id=new.entity_id;
    delete from event_detection_state where user_id=new.user_id and type_id=new.entity_id;
  end if;
  return new;
end $$;
create trigger event_type_archive after insert on public.manual_event_revisions
  for each row execute function public.event_type_archive_fence();
revoke all on function public.event_type_archive_fence() from public,anon,authenticated;

-- Event charts use only the requested owner's data and one physical device.
create function public.event_physiology(p_user uuid,p_device uuid,p_start double precision,p_end double precision)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare hr jsonb; hrv jsonb; movement jsonb; begin
  if p_end < p_start or p_end-p_start > 172800 or p_start < 0 then raise exception 'invalid_window'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('time',t,'value',v,'support',60) order by t),'[]') into hr
    from (select floor(ts/60)*60 t,avg(bpm) v from noop_hr_samples
      where user_id=p_user and device_id=p_device and ts>=p_start and ts<p_end and bpm between 20 and 250 group by 1) s;
  select coalesce(jsonb_agg(jsonb_build_object('time',extract(epoch from bucket_start),'value',value,'support',bucket_seconds)
    order by bucket_start),'[]') into hrv from server_metric_series where user_id=p_user and device_id=p_device
    and metric='hrv_rmssd_ms' and bucket_start>=to_timestamp(p_start) and bucket_start<to_timestamp(p_end);
  with docs as (select distinct on(day) day,windows from activity_encoder_windows
    where user_id=p_user and device_id=p_device and day between to_timestamp(p_start)::date and to_timestamp(p_end)::date
    order by day,computed_at desc), points as (
    select (windows->>'t0')::double precision+(windows->'s'->>i)::double precision t,
      (windows->'f'->i->>k)::double precision v,
      (windows->'e'->>i)::double precision-(windows->'s'->>i)::double precision duration
    from docs cross join lateral generate_series(0,jsonb_array_length(windows->'s')-1) i
      cross join lateral (select ordinality::int-1 k from jsonb_array_elements_text(windows->'features')
        with ordinality where value='accel_rms_g') f)
  select coalesce(jsonb_agg(jsonb_build_object('time',t,'value',v,'support',duration) order by t),'[]') into movement
    from points where t>=p_start and t<p_end and v>=0 and duration>0;
  return jsonb_build_object('heartRate',hr,'hrv',hrv,'movement',movement);
end $$;
revoke all on function public.event_physiology(uuid,uuid,double precision,double precision) from public,anon,authenticated;
grant execute on function public.event_physiology(uuid,uuid,double precision,double precision) to service_role;
commit;
