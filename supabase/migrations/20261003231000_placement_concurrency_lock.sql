-- P2-2 concurrency fix (audit-g5g6-isolation): serialize set_placement_interval per
-- (owner, device scope) so two concurrent declarations for the same owner can never both compute
-- next_start = NULL and leave two overlapping OPEN intervals. Recreates the RPC from
-- 20261003210000 with the advisory lock taken FIRST (before the effective-interval computation
-- and writes). Signature, guards and grants are unchanged; the fix is additive.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace function public.set_placement_interval(
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

  -- Serialize declarations for the same owner+device scope. Without this, two concurrent
  -- declarations (READ COMMITTED, fresh state) can both compute next_start = NULL and leave two
  -- overlapping OPEN intervals. The nil-sentinel 'user' keeps user-level and device-scoped
  -- declarations on disjoint locks because their interval sets are disjoint. The lock is released
  -- at transaction end (xact lock), so a later declaration in the queue sees the earlier one's
  -- committed rows.
  perform pg_advisory_xact_lock(
    hashtextextended('placement:' || p_owner::text || ':' || coalesce(p_device::text, 'user'), 0));

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

comment on function public.set_placement_interval(uuid,text,timestamptz,uuid,timestamptz,text) is
  'Manual placement declaration, serialized per (owner, device scope) with an advisory xact lock so concurrent declarations can never overlap.';

commit;
