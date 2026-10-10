-- Placement switches are logged and switch what depends on placement (hsmm-2.0, docs/bicep-posture/README.md).
--
-- 1. public.placement_change_events: an append-only record of every effective placement declaration or correction
--    (owner, device, from -> to, effective span, revision, source), with what the switch re-queued: physiology-context
--    days (as before), measurement-context days (as before) and, new here, activity-context days. placement_intervals
--    is a folded model whose earlier rows are closed by UPDATE, so this table is the history. UPDATE and DELETE are
--    rejected (rows go only with the account).
-- 2. internal.physiology_context_placement_changed(): additionally re-queues the activity-context jobs (raw-IMU and
--    stream days) of the declared strap and the straps it is bound to, from the day before the change, so the server
--    re-decodes with the placement-aware decoder (srv-cfg-2) instead of keeping days decoded under the old placement,
--    and writes one placement_change_events row per change (a failed invalidation is recorded there, never raised).
--
-- Depends on 20261009150100_placement_device_resolution.sql (internal.placement_strap_devices_v1).

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.placement_change_events (
  id bigint generated always as identity primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  op text not null check (op in ('INSERT', 'UPDATE')),
  placement text not null check (placement in ('wrist', 'bicep', 'other', 'unknown')),
  previous_placement text check (previous_placement is null
    or previous_placement in ('wrist', 'bicep', 'other', 'unknown')),
  effective_start timestamptz not null,
  effective_end timestamptz,
  revision bigint,
  source text,
  -- The first local day the change re-derives, and what it re-queued.
  invalidated_from date,
  activity_jobs_requeued integer not null default 0,
  straps_touched integer not null default 0,
  invalidation_error text,
  logged_at timestamptz not null default clock_timestamp()
);
create index if not exists placement_change_events_owner on public.placement_change_events(owner, logged_at desc);

alter table public.placement_change_events enable row level security;
revoke all on public.placement_change_events from public, anon, authenticated;
grant select on public.placement_change_events to authenticated;
grant all on public.placement_change_events to service_role;
drop policy if exists placement_change_events_service on public.placement_change_events;
create policy placement_change_events_service on public.placement_change_events
  for all to service_role using (true) with check (true);
drop policy if exists placement_change_events_select_own on public.placement_change_events;
create policy placement_change_events_select_own on public.placement_change_events
  for select to authenticated using ((select auth.uid()) = owner);

-- Append-only: an UPDATE is always rejected; a DELETE only when the owner still exists (an account deletion
-- cascades through auth.users and must be allowed through).
create or replace function internal.placement_change_events_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'placement_change_events is append-only' using errcode = '42501';
  end if;
  if exists (select 1 from auth.users u where u.id = old.owner) then
    raise exception 'placement_change_events is append-only' using errcode = '42501';
  end if;
  return old;
end $$;
drop trigger if exists placement_change_events_guard on public.placement_change_events;
create trigger placement_change_events_guard before update or delete on public.placement_change_events
  for each row execute function internal.placement_change_events_guard();
revoke all on function internal.placement_change_events_guard() from public, anon, authenticated, service_role;

create or replace function internal.physiology_context_placement_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_from timestamptz;
  v_day date;
  v_today date;
  v_strap uuid;
  v_requeued integer := 0;
  v_rows integer;
  v_straps integer := 0;
  v_error text;
begin
  if tg_op = 'INSERT' then
    v_from := new.effective_start;
  elsif new.placement is distinct from old.placement or new.source is distinct from old.source then
    v_from := least(old.effective_start, new.effective_start);
  else
    v_from := null;
    if new.effective_start is distinct from old.effective_start then
      v_from := least(old.effective_start, new.effective_start);
    end if;
    if new.effective_end is distinct from old.effective_end then
      -- least() ignores NULL (an open end), so this is the earlier of the two finite ends.
      v_from := least(v_from, old.effective_end, new.effective_end);
    end if;
  end if;
  if v_from is null then
    return null;
  end if;
  if not exists (select 1 from public.devices d
                  where d.user_id = new.owner and (new.device_id is null or d.id = new.device_id)) then
    return null;
  end if;
  v_today := internal.physiology_context_today(new.owner);
  v_day := (v_from at time zone internal.physiology_context_zone(new.owner))::date;
  if v_day <= v_today then
    -- A context problem must never fail a placement declaration: the invalidation runs in its own subtransaction and
    -- a failure is reported as a warning and recorded in the change log.
    begin
      perform internal.physiology_context_invalidate(new.owner, new.device_id, v_day, v_today, 'placement_changed');
      -- The straps the declaration covers: the declared device's straps (installation / alias bindings), or every
      -- device of the owner for an account-level declaration.
      for v_strap in
        select new.device_id where new.device_id is not null
        union
        select s from internal.placement_strap_devices_v1(new.owner, new.device_id) s
         where new.device_id is not null
        union
        select d.id from public.devices d where d.user_id = new.owner and new.device_id is null
      loop
        v_straps := v_straps + 1;
        -- (The declared device itself was invalidated above; its bound straps and an account's devices here.)
        if v_strap is distinct from new.device_id then
          perform internal.physiology_context_invalidate(new.owner, v_strap, v_day, v_today, 'placement_changed');
        end if;
        if to_regclass('internal.measurement_context_work') is not null then
          execute 'update internal.measurement_context_work set queued_at = coalesce(queued_at, clock_timestamp())
                    where user_id = $1 and device_id = $2 and day >= $3'
            using new.owner, v_strap, v_day - 1;
        end if;
        -- Activity days decoded under the old placement are decoded again (the UTC job day before the local day
        -- covers a local day that starts the previous UTC day).
        update public.activity_context_jobs j
           set input_revision = j.input_revision + 1, reason = 'placement_changed',
               dirty_at = clock_timestamp(), not_before = least(j.not_before, clock_timestamp()),
               consecutive_failures = 0
         where j.user_id = new.owner and j.device_id = v_strap and j.day >= v_day - 1 and not j.dead_letter;
        get diagnostics v_rows = row_count;
        v_requeued := v_requeued + v_rows;
      end loop;
    exception when others then
      v_error := sqlstate || ': ' || sqlerrm;
      raise warning 'physiology context placement invalidation skipped: %', sqlstate;
    end;
  end if;
  begin
    insert into public.placement_change_events(owner, device_id, op, placement, previous_placement, effective_start,
                                               effective_end, revision, source, invalidated_from,
                                               activity_jobs_requeued, straps_touched, invalidation_error)
    values (new.owner, new.device_id, tg_op, new.placement,
            case when tg_op = 'UPDATE' then old.placement end,
            new.effective_start, new.effective_end, new.revision, new.source,
            case when v_day <= v_today then v_day end, v_requeued, v_straps, v_error);
  exception when others then
    raise warning 'placement change log skipped: %', sqlstate;
  end;
  return null;
end $$;

commit;
