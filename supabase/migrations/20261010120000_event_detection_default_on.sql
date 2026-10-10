-- Personal event detection is on by default: every live event type gets an enabled detector setting.
-- An existing setting (including one the person switched off) is never changed; archiving still fences.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create function public.event_type_default_on() returns trigger language plpgsql
security definer set search_path=public,pg_temp as $$ begin
  if new.body->'entry'->>'kind'='event_type' and exists(select 1 from manual_events_current
    where user_id=new.user_id and entity_id=new.entity_id and entry->>'kind'='event_type'
      and coalesce((entry->>'archived')::boolean,false)=false) then
    insert into event_detector_settings(user_id,type_id,enabled,state)
      values(new.user_id,new.entity_id,true,'needs_examples')
      on conflict(user_id,type_id) do nothing;
  end if;
  return new;
end $$;
create trigger event_type_default_on after insert on public.manual_event_revisions
  for each row execute function public.event_type_default_on();
revoke all on function public.event_type_default_on() from public,anon,authenticated;

insert into public.event_detector_settings(user_id,type_id,enabled,state)
  select c.user_id,c.entity_id,true,'needs_examples' from public.manual_events_current c
   where c.entry->>'kind'='event_type' and coalesce((c.entry->>'archived')::boolean,false)=false
     and exists(select 1 from auth.users u where u.id=c.user_id)
  on conflict(user_id,type_id) do nothing;

commit;
