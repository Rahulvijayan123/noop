-- Placement of a strap, resolved from every declaration that is provably about that strap.
--
-- WHY
-- The phone declares wear placement under the id it knows the strap by locally ("my-whoop"). The scores route scopes
-- that id to the installation (installation:<source>:my-whoop), so the declaration lands on an installation-scoped
-- device that holds no samples, while every sample is stored under the strap's canonical device (whoop-<serial>).
-- Every server lane read placement for the canonical device only, so it read "unknown" (owner: bicep declared on
-- 5cfe8f4a / 3395021e, data on 155ad9d4; every sensor-biomarker day withheld unknown_wrist_placement; the
-- physiology-context regime never saw the upper-arm wear). Audit C-metadata R3 / F-deploy D1.
--
-- RULE (internal.placement_bound_devices_v1): a declaration on device X describes strap D when
--   strap         X = D;
--   alias         noop_wearable_aliases maps X (provisional) to D (canonical): the strap's serial proved it;
--   installation  X is installation-scoped (external id installation:<S>:<local id>), X is not aliased to another
--                 strap, and installation S uploaded data to D (noop_upload_receipts source_id = S, device_id = D).
--                 The binding is time-bounded by S's other straps (devices that are not installation-scoped): if S
--                 uploaded to another strap before D, it starts at S's first upload to D (else it is open to the
--                 past: a declaration made before the strap's first upload is about the only strap S ever used);
--                 if S uploaded to another strap after D, it ends at S's last upload to D (else it stays open). The
--                 time between two straps is claimed by neither. If S's uploads to another strap interleave with
--                 its uploads to D, which strap X meant is not provable and X is not used for D at all. Upload
--                 times (the receipts' accepted_at) bound the binding; they trail the data, so a bound errs on the
--                 side of "undeclared", never of the wrong strap.
--   Nothing else is used: a device of the owner that is not one of these never contributes.
-- RESOLUTION (internal.placement_intervals_for_device_v1): the declarations on D's bound devices, each clipped to its
-- binding, form one timeline for D. Where they overlap, the later declaration (effective_start, then revision) wins,
-- as set_placement_interval's "as of T the placement is P" means within one device. The result is non-overlapping
-- pieces (scope 'device', basis strap / alias / installation) plus the owner's device-less declarations as recorded
-- (scope 'account'); a consumer keeps its own rule that a device-scoped piece wins over an account-level one.
-- Undeclared time stays undeclared: nothing is back-filled.
--
-- WHAT CHANGES
--   index noop_upload_receipts (user_id, source_id, device_id, accepted_at): the binding probes (first / last upload
--     of an installation to a device) are index-only lookups. On production build it CONCURRENTLY first (deploy
--     notes); the statement below is then a no-op.
--   internal.placement_bound_devices_v1(user, device), internal.placement_intervals_for_device_v1(user, device, from,
--     to), internal.placement_for_device_v1(user, device, at), internal.placement_strap_devices_v1(user, declared).
--   public.placement_resolved_read_v1(user, device, from, to): service only, GET scores/placement?deviceId=.
--   internal.physiology_context_dependency_fingerprint: the placement part covers the bound devices' declarations
--     (unchanged for a device with no alias or installation binding, so no existing fingerprint moves).
--   internal.physiology_context_placement_changed: a declaration on a bound device also invalidates the strap's
--     context days and re-queues its built measurement-context days.
--   internal.build_measurement_context_minutes_v1: placement / placement_basis come from the resolver (was NULL /
--     not_resolved). Patched in place from its current definition (only the placement expression changes), so a
--     later 2026100913xxxx change to the builder is kept; the migration fails if the expression is not found.
-- No row of placement_intervals or noop_wearable_aliases is written or moved (deploy/placement-rescope-strap.sql is
-- the reviewed, dry-run-by-default repair a human may run).
--
-- Safe to re-run. Rollback: re-create the two physiology-context functions from 20261006050000, re-apply
-- 20261009130100's builder (placement NULL), drop the five functions above and the index.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

create index if not exists noop_upload_receipts_source_device_idx
  on public.noop_upload_receipts (user_id, source_id, device_id, accepted_at);

-- The devices whose declarations describe strap p_device, each with the span over which it does. Only installation
-- devices that carry a placement declaration are examined (the rule's only consumer is placement).
create or replace function internal.placement_bound_devices_v1(p_user uuid, p_device uuid)
returns table (declared_device_id uuid, basis text, bound_from timestamptz, bound_to timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_external text;
  x record;
  o record;
  v_source uuid;
  v_first timestamptz;
  v_last timestamptz;
  v_from timestamptz;
  v_to timestamptz;
  v_ambiguous boolean;
begin
  select coalesce(d.external_device_id, '') into v_external
    from public.devices d where d.id = p_device and d.user_id = p_user;
  if not found then return; end if;
  declared_device_id := p_device; basis := 'strap'; bound_from := '-infinity'; bound_to := 'infinity';
  return next;
  return query
    select a.provisional_device_id, 'alias'::text, '-infinity'::timestamptz, 'infinity'::timestamptz
      from public.noop_wearable_aliases a
     where a.user_id = p_user and a.canonical_device_id = p_device and a.provisional_device_id <> p_device;
  -- An installation-scoped device is never itself a strap other installations upload to.
  if v_external like 'installation:%' then return; end if;
  for x in
    select distinct d.id, d.external_device_id
      from public.placement_intervals pi
      join public.devices d on d.id = pi.device_id and d.user_id = p_user
     where pi.owner = p_user and pi.device_id is not null and pi.device_id <> p_device
       and d.external_device_id ~ '^installation:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:'
       and not exists (select 1 from public.noop_wearable_aliases a
                        where a.user_id = p_user and a.provisional_device_id = d.id)
  loop
    v_source := substring(x.external_device_id from '^installation:([0-9a-f-]{36}):')::uuid;
    select min(r.accepted_at), max(r.accepted_at) into v_first, v_last
      from public.noop_upload_receipts r
     where r.user_id = p_user and r.source_id = v_source and r.device_id = p_device;
    continue when v_first is null;
    v_from := '-infinity'; v_to := 'infinity'; v_ambiguous := false;
    -- The installation's other straps (not installation-scoped, not X, not D) and when it uploaded to them: one used
    -- before D bounds the binding at the first upload to D, one used after D at the last upload to D.
    for o in
      select d2.id,
             (select min(r.accepted_at) from public.noop_upload_receipts r
               where r.user_id = p_user and r.source_id = v_source and r.device_id = d2.id) as first_at,
             (select max(r.accepted_at) from public.noop_upload_receipts r
               where r.user_id = p_user and r.source_id = v_source and r.device_id = d2.id) as last_at
        from public.devices d2
       where d2.user_id = p_user and d2.id <> p_device and d2.id <> x.id
         and coalesce(d2.external_device_id, '') not like 'installation:%'
    loop
      continue when o.first_at is null;
      if o.last_at < v_first then
        v_from := v_first;
      elsif o.first_at > v_last then
        v_to := v_last;
      else
        v_ambiguous := true;
      end if;
    end loop;
    continue when v_ambiguous;
    declared_device_id := x.id; basis := 'installation'; bound_from := v_from; bound_to := v_to;
    return next;
  end loop;
end $$;
revoke all on function internal.placement_bound_devices_v1(uuid, uuid) from public, anon, authenticated, service_role;

-- Strap p_device's placement timeline overlapping [p_from, p_to) (NULL = unbounded): resolved device-scoped pieces
-- (scope 'device') and the owner's device-less declarations (scope 'account'), ordered by start (account first on a
-- tie). A piece's effective_start / effective_end are its own bounds after clipping and precedence; effective_end
-- NULL = open. interval_id / declared_device_id / revision / recorded_at / source name the declaration it came from.
create or replace function internal.placement_intervals_for_device_v1(p_user uuid, p_device uuid,
                                                                       p_from timestamptz, p_to timestamptz)
returns table (scope text, basis text, effective_start timestamptz, effective_end timestamptz, placement text,
               source text, revision bigint, recorded_at timestamptz, interval_id uuid, declared_device_id uuid)
language sql stable security definer set search_path = '' as $$
  with bound as (
    select * from internal.placement_bound_devices_v1(p_user, p_device)
  ), cand as (
    select pi.id, pi.placement, pi.source, pi.revision, pi.recorded_at, pi.device_id, pi.effective_start as declared,
           b.basis,
           greatest(pi.effective_start, b.bound_from) as s,
           least(coalesce(pi.effective_end, 'infinity'::timestamptz), b.bound_to) as e
      from public.placement_intervals pi
      join bound b on b.declared_device_id = pi.device_id
     where pi.owner = p_user
  ), c as (
    select * from cand where s < e
  ), edges as (
    select s as t from c union select e from c
  ), seg as (
    select t as a, lead(t) over (order by t) as z from edges
  ), win as (
    select seg.a, seg.z, w.id, w.placement, w.source, w.revision, w.recorded_at, w.device_id, w.basis
      from seg
     cross join lateral (select c.* from c where c.s <= seg.a and c.e >= seg.z
                          order by c.declared desc, c.revision desc, c.id limit 1) w
     where seg.z is not null
  ), brk as (
    select win.*, case when lag(win.id) over (order by win.a) = win.id and lag(win.z) over (order by win.a) = win.a
                       then 0 else 1 end as starts
      from win
  ), grp as (
    select brk.*, sum(brk.starts) over (order by brk.a) as g from brk
  ), pieces as (
    select min(grp.a) as s, max(grp.z) as e, grp.id, grp.placement, grp.source, grp.revision, grp.recorded_at,
           grp.device_id, grp.basis
      from grp group by grp.g, grp.id, grp.placement, grp.source, grp.revision, grp.recorded_at, grp.device_id,
                        grp.basis
  ), resolved as (
    select 'device'::text as scope, p.basis, p.s as effective_start,
           case when p.e = 'infinity'::timestamptz then null else p.e end as effective_end, p.placement, p.source,
           p.revision, p.recorded_at, p.id as interval_id, p.device_id as declared_device_id
      from pieces p
     where (p_to is null or p.s < p_to) and (p_from is null or p.e > p_from)
    union all
    select 'account', 'account', pi.effective_start, pi.effective_end, pi.placement, pi.source, pi.revision,
           pi.recorded_at, pi.id, null::uuid
      from public.placement_intervals pi
     where pi.owner = p_user and pi.device_id is null
       and exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user)
       and (p_to is null or pi.effective_start < p_to)
       and (p_from is null or pi.effective_end is null or pi.effective_end > p_from)
  )
  select * from resolved order by effective_start, (scope = 'account') desc, revision, interval_id
$$;
revoke all on function internal.placement_intervals_for_device_v1(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;

-- The placement in effect for strap p_device at p_at: the device-scoped piece holding it, else the account-level
-- declaration holding it, else no row (undeclared).
create or replace function internal.placement_for_device_v1(p_user uuid, p_device uuid, p_at timestamptz)
returns table (placement text, scope text, basis text, source text, effective_start timestamptz,
               effective_end timestamptz, interval_id uuid, declared_device_id uuid, revision bigint)
language sql stable security definer set search_path = '' as $$
  select r.placement, r.scope, r.basis, r.source, r.effective_start, r.effective_end, r.interval_id,
         r.declared_device_id, r.revision
    from internal.placement_intervals_for_device_v1(p_user, p_device, p_at, p_at + interval '1 microsecond') r
   where r.effective_start <= p_at and (r.effective_end is null or r.effective_end > p_at)
   order by (r.scope = 'device') desc, r.effective_start desc, r.revision desc
   limit 1
$$;
revoke all on function internal.placement_for_device_v1(uuid, uuid, timestamptz)
  from public, anon, authenticated, service_role;

-- The owner's straps a declaration on p_declared describes (other than p_declared itself): for invalidation.
create or replace function internal.placement_strap_devices_v1(p_user uuid, p_declared uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select d.id from public.devices d
   where d.user_id = p_user and d.id <> p_declared
     and exists (select 1 from internal.placement_bound_devices_v1(p_user, d.id) b
                  where b.declared_device_id = p_declared)
$$;
revoke all on function internal.placement_strap_devices_v1(uuid, uuid) from public, anon, authenticated, service_role;

-- GET scores/placement?deviceId=: the strap's resolved timeline for the route. Each piece says where the declaration
-- came from and what it means for a wrist-trained model (contracts/reason-codes.json): wrist none, bicep / other
-- placement_unsupported (confirmed: the wearer declared it), unknown placement_unknown (unknown).
create or replace function public.placement_resolved_read_v1(p_user uuid, p_device uuid,
                                                             p_from timestamptz default null,
                                                             p_to timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_device is null or not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'scope', r.scope, 'basis', r.basis, 'placement', r.placement,
             'effective_start', r.effective_start, 'effective_end', r.effective_end,
             'source', r.source, 'revision', r.revision, 'interval_id', r.interval_id,
             'declared_device_id', d.external_device_id,
             'wrist_model_reason', case r.placement
               when 'wrist' then null
               when 'unknown' then jsonb_build_object('code', 'placement_unknown', 'certainty', 'unknown')
               else jsonb_build_object('code', 'placement_unsupported', 'certainty', 'confirmed') end)
           order by r.effective_start, (r.scope = 'account') desc, r.revision)
      from internal.placement_intervals_for_device_v1(p_user, p_device, p_from, p_to) r
      left join public.devices d on d.id = r.declared_device_id and d.user_id = p_user), '[]'::jsonb);
end $$;
revoke all on function public.placement_resolved_read_v1(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
grant execute on function public.placement_resolved_read_v1(uuid, uuid, timestamptz, timestamptz) to service_role;

-- Physiology context: the dependency fingerprint's placement part reads the bound devices' declarations (20261006050000
-- read only p_device's). For a device with no alias and no installation binding the text is byte-identical.
create or replace function internal.physiology_context_dependency_fingerprint(p_user uuid, p_device uuid, p_day date)
returns text language sql stable security definer set search_path = '' as $$
  with z as (
    select internal.physiology_context_zone(p_user) as zone
  ), w as (
    select z.zone,
           extract(epoch from ((p_day - 1)::timestamp at time zone z.zone))::bigint as lo,
           extract(epoch from ((p_day + 2)::timestamp at time zone z.zone))::bigint as hi,
           extract(epoch from ((p_day - 4)::timestamp at time zone z.zone))::bigint as exposure_lo
      from z
  )
  select encode(pg_catalog.sha256(convert_to(
    'physiology-context-deps-v1' || E'\n' || p_user::text || E'\n' || p_device::text || E'\n'
    || to_char(p_day, 'YYYY-MM-DD')
    || E'\nzone:' || w.zone
    || E'\nscoring:' || coalesce((
         select string_agg(to_char(s.day, 'YYYY-MM-DD') || ':' || s.completed_revision::text, ',' order by s.day)
           from public.scoring_jobs_v2 s
          where s.user_id = p_user and s.device_id = p_device and s.algorithm_version = 'frwhoop-server-1'
            and s.day between p_day - 1 and p_day + 1), '')
    || E'\nactivity:' || coalesce((
         select string_agg(a.algorithm_version || ':' || to_char(a.day, 'YYYY-MM-DD') || ':' || a.result_revision::text, ','
                           order by a.algorithm_version collate "C", a.day)
           from public.activity_context_days a
          where a.user_id = p_user and a.device_id = p_device and a.day between p_day - 1 and p_day + 1), '')
    || E'\nplacement:' || coalesce((
         select string_agg(pi.id::text || ':' || pi.revision::text || ':' || pi.placement || ':' || pi.source || ':'
                           || extract(epoch from pi.effective_start)::bigint::text || ':'
                           || coalesce(extract(epoch from pi.effective_end)::bigint::text, '-'), ','
                           order by pi.id)
           from public.placement_intervals pi
          where pi.owner = p_user
            and (pi.device_id is null or pi.device_id = p_device
                 or pi.device_id in (select b.declared_device_id
                                       from internal.placement_bound_devices_v1(p_user, p_device) b))
            and pi.effective_start < to_timestamp(w.hi)
            and (pi.effective_end is null or pi.effective_end > to_timestamp(w.lo))), '')
    || E'\nexposures:' || coalesce((
         select string_agg(e.event_id || ':' || e.revision::text, ',' order by e.event_id collate "C")
           from public.exposure_events e
          where e.owner = p_user and e.occurred_start < w.hi and e.occurred_end > w.exposure_lo
            and e.occurred_start > w.exposure_lo - 2678400), ''),
    'UTF8')), 'hex')
  from w
$$;

-- Placement corrections invalidate from the local day of the earliest instant whose placement changed through the
-- owner's today (capped at 120 days), for the declared device or, for a user-level declaration, every device of the
-- owner (20261006050000) and now also every strap the declared device is bound to (installation / alias), whose
-- already-built measurement-context days are re-queued as well. Fires only for placement/source/effective_start/
-- effective_end changes, so the device FK's ON DELETE SET NULL never fires it.
create or replace function internal.physiology_context_placement_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_from timestamptz;
  v_day date;
  v_today date;
  v_strap uuid;
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
  if v_day > v_today then
    return null;  -- a future-dated declaration has no computed day to invalidate yet
  end if;
  -- A context problem must never fail a placement declaration: the invalidation runs in its own subtransaction and a
  -- failure is reported as a warning (see 20261006050000).
  begin
    perform internal.physiology_context_invalidate(new.owner, new.device_id, v_day, v_today, 'placement_changed');
    if new.device_id is not null then
      for v_strap in select s from internal.placement_strap_devices_v1(new.owner, new.device_id) s loop
        perform internal.physiology_context_invalidate(new.owner, v_strap, v_day, v_today, 'placement_changed');
        if to_regclass('internal.measurement_context_work') is not null then
          execute 'update internal.measurement_context_work set queued_at = coalesce(queued_at, clock_timestamp())
                    where user_id = $1 and device_id = $2 and day >= $3'
            using new.owner, v_strap, v_day - 1;
        end if;
      end loop;
    end if;
  exception when others then
    raise warning 'physiology context placement invalidation skipped: %', sqlstate;
  end;
  return null;
end $$;

-- Measurement context: placement per minute from the resolver (the placement in effect at the minute's start;
-- placement_basis declared_strap / declared_alias / declared_installation / declared_account, or undeclared).
do $patch$
declare
  v_fn regprocedure := to_regprocedure(
    'internal.build_measurement_context_minutes_v1(uuid,uuid,timestamptz,timestamptz,boolean)');
  v_def text;
  v_marker constant text := $m$g.sleep_state, g.sleep_basis, g.wear_state, g.wear_basis, null, 'not_resolved',$m$;
  v_new constant text := $n$g.sleep_state, g.sleep_basis, g.wear_state, g.wear_basis,
         (select r.placement
            from internal.placement_intervals_for_device_v1(p_user, p_device, to_timestamp(v_from), to_timestamp(v_to)) r
           where r.effective_start <= to_timestamp(g.m) and (r.effective_end is null or r.effective_end > to_timestamp(g.m))
           order by (r.scope = 'device') desc, r.effective_start desc, r.revision desc limit 1),
         coalesce((select 'declared_' || r.basis
            from internal.placement_intervals_for_device_v1(p_user, p_device, to_timestamp(v_from), to_timestamp(v_to)) r
           where r.effective_start <= to_timestamp(g.m) and (r.effective_end is null or r.effective_end > to_timestamp(g.m))
           order by (r.scope = 'device') desc, r.effective_start desc, r.revision desc limit 1), 'undeclared'),$n$;
begin
  if v_fn is null then
    raise notice 'measurement context builder absent: placement patch skipped';
    return;
  end if;
  v_def := pg_get_functiondef(v_fn);
  if position('placement_intervals_for_device_v1' in v_def) > 0 then
    return;  -- already patched
  end if;
  if position(v_marker in v_def) = 0 or position(v_marker in substr(v_def, position(v_marker in v_def) + 1)) > 0 then
    raise exception 'measurement context builder changed: the placement expression to replace was not found once';
  end if;
  execute replace(v_def, v_marker, v_new);
end $patch$;

comment on column public.measurement_context_minutes.placement is
  'Declared placement in effect at the minute (internal.placement_for_device_v1 rule, 20261009150100); NULL when '
  'nothing is declared. placement_basis: declared_strap / declared_alias / declared_installation / '
  'declared_account / undeclared (not_resolved on rows built before 20261009150100).';

commit;
