-- G4 manual placement baseline (docs/core-plumbing/spec.md §6; g34-wear-placement findings item 1).
-- Additive only: one new owner-scoped, effective-dated placement_intervals table plus one
-- security-definer RPC that mirrors the phone's correction semantics (Strand/Data/PlacementStore.swift).
--
-- Half-open [effective_start, effective_end) semantics everywhere; effective_end NULL means "open".
-- Unannotated history stays UNKNOWN: nothing here ever backfills placement before the first
-- user declaration. Corrections close the overlapping interval and insert a new one (revision
-- bump); past rows are never silently rewritten.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table public.placement_intervals (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references auth.users(id) on delete cascade,
  device_id uuid references public.devices(id) on delete set null,
  placement text not null check (placement in ('wrist','bicep','other','unknown')),
  effective_start timestamptz not null,
  effective_end timestamptz,
  recorded_at timestamptz not null default clock_timestamp(),
  source text not null default 'user' check (source in ('user','device')),
  revision bigint not null default 1 check (revision >= 1),
  check (effective_end is null or effective_end > effective_start)
);

create index placement_intervals_owner_start_idx
  on public.placement_intervals (owner, effective_start);
create index placement_intervals_owner_device_start_idx
  on public.placement_intervals (owner, device_id, effective_start);

alter table public.placement_intervals enable row level security;
revoke all on public.placement_intervals from public, anon;
grant select, insert, update, delete on public.placement_intervals to service_role;
grant select on public.placement_intervals to authenticated;

create policy placement_service on public.placement_intervals
  for all to service_role using (true) with check (true);
create policy placement_select_own on public.placement_intervals
  for select to authenticated using ((select auth.uid()) = owner);

-- One write path for a manual placement declaration: "as of p_effective_start the owner declares
-- placement = p_placement (for device p_device when given; a NULL device is a user-level
-- declaration and only ever touches other user-level rows). The phone and the edge route both
-- call this, so an offline change replays with its original effective time. Guarantees the
-- intervals stay non-overlapping and half-open:
--   1. every existing interval strictly containing p_effective_start is closed there;
--   2. an interval that starts exactly at p_effective_start is the degenerate "close at the new
--      declaration" case and is replaced in place (placement/source/revision bump);
--   3. the new open interval is capped at the next interval's start, so a future-dated interval
--      is never overwritten.
-- History is never silently rewritten: rows are cut (effective_end = T) or superseded by an
-- explicit declaration, never deleted.
create function public.set_placement_interval(
  p_owner uuid,
  p_placement text,
  p_effective_start timestamptz,
  p_device uuid default null,
  p_effective_end timestamptz default null,
  p_source text default 'user')
returns public.placement_intervals
language plpgsql security definer set search_path = public as $$
declare
  inserted public.placement_intervals;
  next_start timestamptz;
  new_revision bigint;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_owner then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_placement not in ('wrist','bicep','other','unknown') then
    raise exception 'invalid_placement';
  end if;
  if p_source not in ('user','device') then
    raise exception 'invalid_source';
  end if;
  if p_effective_start is null then
    raise exception 'invalid_effective_start';
  end if;
  if p_effective_end is not null and p_effective_end <= p_effective_start then
    raise exception 'invalid_effective_end';
  end if;
  if p_device is not null
     and not exists(select 1 from public.devices where id = p_device and user_id = p_owner) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;

  -- 1. Close every interval strictly containing the declaration time (same device scope).
  update public.placement_intervals
     set effective_end = p_effective_start
   where owner = p_owner
     and ((p_device is null and device_id is null) or (p_device is not null and device_id = p_device))
     and effective_start < p_effective_start
     and (effective_end is null or effective_end > p_effective_start);

  -- 2. Degenerate same-start declaration: replace in place (the new declaration supersedes it).
  update public.placement_intervals
     set placement = p_placement,
         source = p_source,
         recorded_at = clock_timestamp(),
         revision = coalesce((select max(revision) from public.placement_intervals
                              where owner = p_owner), 0) + 1
   where owner = p_owner
     and ((p_device is null and device_id is null) or (p_device is not null and device_id = p_device))
     and effective_start = p_effective_start
     and (effective_end is null or effective_end > p_effective_start)
   returning * into inserted;
  if inserted.id is not null then
    return inserted;
  end if;

  -- 3. New interval, capped at the next future-dated interval so nothing overlaps.
  select min(effective_start) into next_start
    from public.placement_intervals
   where owner = p_owner
     and ((p_device is null and device_id is null) or (p_device is not null and device_id = p_device))
     and effective_start > p_effective_start;

  select coalesce(max(revision), 0) + 1 into new_revision
    from public.placement_intervals where owner = p_owner;

  insert into public.placement_intervals
    (owner, device_id, placement, effective_start, effective_end, recorded_at, source, revision)
  values (p_owner, p_device, p_placement, p_effective_start,
          case when next_start is not null and (p_effective_end is null or next_start <= p_effective_end)
               then next_start
               else p_effective_end end,
          clock_timestamp(), p_source, new_revision)
  returning * into inserted;
  return inserted;
end;
$$;

revoke all on function public.set_placement_interval(uuid,text,timestamptz,uuid,timestamptz,text)
  from public, anon;
grant execute on function public.set_placement_interval(uuid,text,timestamptz,uuid,timestamptz,text)
  to authenticated, service_role;

comment on table public.placement_intervals is
  'Effective-dated manual strap placement (G4). Half-open [effective_start, effective_end); NULL end is open. Unannotated history stays UNKNOWN; never backfilled.';
comment on column public.placement_intervals.owner is 'Owning user (auth.users). RLS: owner may read own rows; writes go through set_placement_interval.';
comment on column public.placement_intervals.device_id is 'Device the placement applies to; NULL = user-level declaration.';
comment on column public.placement_intervals.placement is 'Manual placement: wrist, bicep, other, unknown.';
comment on column public.placement_intervals.source is 'Who declared it: user (manual baseline) or device (future validated model inference).';
comment on column public.placement_intervals.revision is 'Per-owner monotonic revision; bumped on every declaration/correction.';

commit;
