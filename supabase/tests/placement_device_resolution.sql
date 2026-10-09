-- Regression for 20261009150100_placement_device_resolution.sql. Run ONLY against an isolated, disposable full-schema
-- database (all migrations applied, e.g. supabase/tests/e2e/pipeline_db.sh). Everything runs in one transaction that
-- is rolled back:
--
--   PGAPPNAME=placement-device-resolution psql "$DISPOSABLE_URL" -X -v ON_ERROR_STOP=1 \
--     -f supabase/tests/placement_device_resolution.sql
--
-- (supabase/functions/tests/placement_resolution_sql_test.ts runs it the same way inside the pipeline container.)
--
-- The owner's shape: one strap D (whoop-<serial>, all data) and the phone's installation-scoped devices that carry
-- the placement declarations. Checks:
--   1. Bound devices: the strap itself, an alias, installations that uploaded to D (open, or time-bounded by the
--      installation's other strap), never an installation that uploaded only elsewhere, never one whose uploads to
--      another strap interleave with D's, never another owner's.
--   2. The resolved timeline of D: clipped bindings, later declaration wins, pieces, account rows apart; the point
--      resolver at instants in each piece and in the gaps; the other strap's own timeline.
--   3. The route read (public.placement_resolved_read_v1): external ids and the wrist-model reason.
--   4. Physiology context: the dependency fingerprint now covers bound declarations, and is byte-identical to the
--      20261006050000 formula for a device without bindings; a declaration on an installation device invalidates
--      the strap's context days.
--   5. Measurement context: the builder writes the resolved placement and its basis per minute.
--   6. Privileges: no client executes the resolver; the route read is service only.
\set ON_ERROR_STOP on

begin;
select gen_random_uuid() as u, gen_random_uuid() as v,
       gen_random_uuid() as d, gen_random_uuid() as d2, gen_random_uuid() as x1, gen_random_uuid() as x2,
       gen_random_uuid() as p, gen_random_uuid() as y, gen_random_uuid() as z, gen_random_uuid() as w,
       gen_random_uuid() as dv, gen_random_uuid() as xv,
       gen_random_uuid() as s1, gen_random_uuid() as s2, gen_random_uuid() as s3, gen_random_uuid() as s4,
       gen_random_uuid() as s5, gen_random_uuid() as s6, gen_random_uuid() as sv \gset
select set_config('pl.u', :'u', true), set_config('pl.v', :'v', true), set_config('pl.d', :'d', true),
       set_config('pl.d2', :'d2', true), set_config('pl.x1', :'x1', true), set_config('pl.x2', :'x2', true),
       set_config('pl.p', :'p', true), set_config('pl.y', :'y', true), set_config('pl.z', :'z', true),
       set_config('pl.w', :'w', true), set_config('pl.dv', :'dv', true), set_config('pl.xv', :'xv', true) \g /dev/null

do $$ begin
  assert current_setting('application_name') = 'placement-device-resolution', 'disposable-database invocation required';
end $$;

insert into auth.users (id) values (:'u'), (:'v');
insert into public.profiles (id, timezone) values (:'u', 'UTC'), (:'v', 'UTC')
  on conflict (id) do update set timezone = excluded.timezone;
insert into public.noop_app_installations (source_id, user_id, platform, app_version, provisioning_method)
values (:'s1', :'u', 'ios', '1.0', 'supabase_auth'), (:'s2', :'u', 'ios', '1.0', 'supabase_auth'),
       (:'s3', :'u', 'ios', '1.0', 'supabase_auth'), (:'s4', :'u', 'ios', '1.0', 'supabase_auth'),
       (:'s5', :'u', 'ios', '1.0', 'supabase_auth'), (:'s6', :'u', 'ios', '1.0', 'supabase_auth'),
       (:'sv', :'v', 'ios', '1.0', 'supabase_auth');
insert into public.devices (id, user_id, source_kind, external_device_id) values
  (:'d', :'u', 'noop_push', 'whoop-PLT0000001'),
  (:'d2', :'u', 'noop_push', 'whoop-PLT0000002'),
  (:'x1', :'u', 'noop_push', 'installation:' || :'s1' || ':my-whoop'),
  (:'x2', :'u', 'noop_push', 'installation:' || :'s2' || ':my-whoop'),
  (:'p', :'u', 'noop_push', 'installation:' || :'s3' || ':my-whoop'),
  (:'y', :'u', 'noop_push', 'installation:' || :'s4' || ':my-whoop'),
  (:'z', :'u', 'noop_push', 'installation:' || :'s5' || ':my-whoop'),
  (:'w', :'u', 'noop_push', 'installation:' || :'s6' || ':my-whoop'),
  (:'dv', :'v', 'noop_push', 'whoop-PLT0000009'),
  (:'xv', :'v', 'noop_push', 'installation:' || :'sv' || ':my-whoop');
insert into public.noop_wearable_aliases (user_id, source_id, provisional_device_id, canonical_device_id, evidence)
values (:'u', :'s3', :'p', :'d', '{"method": "device_information_serial_v1"}');

-- Upload receipts: who uploaded to which device, when.
create temp table pl_receipts (source_id uuid, device_id uuid, at timestamptz);
insert into pl_receipts values
  (:'s1', :'x1', '2026-10-04 21:49:16+00'),                                            -- S1: its own device first,
  (:'s1', :'d', '2026-10-04 23:46:58+00'), (:'s1', :'d', '2026-10-06 18:57:05+00'),    --     then only strap D
  (:'s2', :'d', '2026-10-06 19:08:38+00'), (:'s2', :'d', '2026-10-09 18:38:11+00'),    -- S2: only strap D
  (:'s4', :'d2', '2026-10-05 10:00:00+00'),                                            -- S4: only strap D2
  (:'s5', :'d', '2026-10-02 00:00:00+00'), (:'s5', :'d2', '2026-10-03 00:00:00+00'),   -- S5: D and D2 interleaved
  (:'s5', :'d', '2026-10-05 00:00:00+00'),
  (:'s6', :'d2', '2026-09-20 00:00:00+00'), (:'s6', :'d2', '2026-09-25 00:00:00+00'),  -- S6: D2, then D
  (:'s6', :'d', '2026-09-28 00:00:00+00'), (:'s6', :'d', '2026-10-01 00:00:00+00');
insert into public.noop_upload_receipts (id, user_id, source_id, device_id, auth_mode, lane, stream, batch_id,
                                         body_sha256, accepted_status, accepted_at)
select gen_random_uuid(), :'u', r.source_id, r.device_id, 'installation', 'inline', 'hr', gen_random_uuid(),
       repeat('a', 64), 'accepted', r.at
  from pl_receipts r;

-- Declarations (revision order = recorded order).
insert into public.placement_intervals (id, owner, device_id, placement, effective_start, effective_end, source, revision)
values
  ('00000000-0000-4000-8000-000000000001', :'u', :'x1', 'bicep', '2026-10-04 21:49:41+00', null, 'user', 1),
  ('00000000-0000-4000-8000-000000000002', :'u', :'x2', 'bicep', '2026-10-07 07:12:03+00', null, 'user', 2),
  ('00000000-0000-4000-8000-000000000003', :'u', :'d', 'wrist', '2026-09-29 00:00:00+00', '2026-10-03 00:00:00+00', 'user', 3),
  ('00000000-0000-4000-8000-000000000004', :'u', :'p', 'other', '2026-10-03 00:00:00+00', '2026-10-04 00:00:00+00', 'user', 4),
  ('00000000-0000-4000-8000-000000000005', :'u', :'y', 'wrist', '2026-10-06 00:00:00+00', null, 'user', 5),
  ('00000000-0000-4000-8000-000000000006', :'u', :'z', 'wrist', '2026-10-02 00:00:00+00', null, 'user', 6),
  ('00000000-0000-4000-8000-000000000007', :'u', :'w', 'unknown', '2026-09-24 00:00:00+00', '2026-09-29 00:00:00+00', 'user', 7),
  ('00000000-0000-4000-8000-000000000008', :'u', null, 'wrist', '2026-09-01 00:00:00+00', null, 'user', 8),
  ('00000000-0000-4000-8000-000000000009', :'v', :'xv', 'bicep', '2026-09-01 00:00:00+00', null, 'user', 1);

-- 1. Bound devices -----------------------------------------------------------------------------------------------
do $$
declare u uuid := current_setting('pl.u')::uuid; d uuid := current_setting('pl.d')::uuid;
  d2 uuid := current_setting('pl.d2')::uuid; got jsonb;
begin
  select jsonb_object_agg(b.declared_device_id::text, jsonb_build_array(b.basis, b.bound_from, b.bound_to)) into got
    from internal.placement_bound_devices_v1(u, d) b;
  assert got = jsonb_build_object(
    d::text, jsonb_build_array('strap', '-infinity'::timestamptz, 'infinity'::timestamptz),
    current_setting('pl.p'), jsonb_build_array('alias', '-infinity'::timestamptz, 'infinity'::timestamptz),
    current_setting('pl.x1'), jsonb_build_array('installation', '-infinity'::timestamptz, 'infinity'::timestamptz),
    current_setting('pl.x2'), jsonb_build_array('installation', '-infinity'::timestamptz, 'infinity'::timestamptz),
    -- S6 used D2 before D: the binding starts at its first upload to D.
    current_setting('pl.w'), jsonb_build_array('installation', '2026-09-28 00:00:00+00'::timestamptz,
                                               'infinity'::timestamptz)), got::text;
  -- D2: its own, S4 (only D2) and S6 until its last upload to D2 (it moved on to D). S5 interleaves: never.
  select jsonb_object_agg(b.declared_device_id::text, jsonb_build_array(b.basis, b.bound_from, b.bound_to)) into got
    from internal.placement_bound_devices_v1(u, d2) b;
  assert got = jsonb_build_object(
    d2::text, jsonb_build_array('strap', '-infinity'::timestamptz, 'infinity'::timestamptz),
    current_setting('pl.y'), jsonb_build_array('installation', '-infinity'::timestamptz, 'infinity'::timestamptz),
    current_setting('pl.w'), jsonb_build_array('installation', '-infinity'::timestamptz,
                                               '2026-09-25 00:00:00+00'::timestamptz)), got::text;
  -- An installation device is bound only to itself; another owner's strap is nobody's.
  assert (select count(*) from internal.placement_bound_devices_v1(u, current_setting('pl.x1')::uuid)) = 1;
  assert (select count(*) from internal.placement_bound_devices_v1(u, current_setting('pl.dv')::uuid)) = 0;
  assert (select array_agg(s order by s) from internal.placement_strap_devices_v1(u, current_setting('pl.x1')::uuid) s)
         = array[d];
  assert (select array_agg(s order by s) from internal.placement_strap_devices_v1(u, current_setting('pl.p')::uuid) s)
         = array[d];
  assert not exists (select 1 from internal.placement_strap_devices_v1(u, current_setting('pl.z')::uuid));
  assert (select array_agg(s::text order by s::text) from internal.placement_strap_devices_v1(u, current_setting('pl.w')::uuid) s)
         = (select array_agg(x order by x) from unnest(array[d::text, d2::text]) x);
end $$;

-- 2. The resolved timeline -----------------------------------------------------------------------------------------
do $$
declare u uuid := current_setting('pl.u')::uuid; d uuid := current_setting('pl.d')::uuid;
  d2 uuid := current_setting('pl.d2')::uuid; got text; r record;
begin
  select string_agg(format('%s/%s/%s/%s..%s/%s', t.scope, t.basis, t.placement,
                           to_char(t.effective_start at time zone 'UTC', 'MM-DD HH24:MI:SS'),
                           coalesce(to_char(t.effective_end at time zone 'UTC', 'MM-DD HH24:MI:SS'), 'open'),
                           right(t.interval_id::text, 1)), ' | ' order by t.effective_start, t.scope) into got
    from internal.placement_intervals_for_device_v1(u, d, null, null) t;
  assert got = 'account/account/wrist/09-01 00:00:00..open/8'
    || ' | device/installation/unknown/09-28 00:00:00..09-29 00:00:00/7'
    || ' | device/strap/wrist/09-29 00:00:00..10-03 00:00:00/3'
    || ' | device/alias/other/10-03 00:00:00..10-04 00:00:00/4'
    || ' | device/installation/bicep/10-04 21:49:41..10-07 07:12:03/1'
    || ' | device/installation/bicep/10-07 07:12:03..open/2', got;
  -- A window keeps each piece's own bounds.
  select string_agg(right(t.interval_id::text, 1) || ':' || to_char(t.effective_start at time zone 'UTC', 'MM-DD'), ','
                    order by t.effective_start) into got
    from internal.placement_intervals_for_device_v1(u, d, '2026-10-05', '2026-10-06') t;
  assert got = '8:09-01,1:10-04', got;
  -- D2: the account row, then S6's declaration up to S6's last upload to D2 (S4's wrist from 10-06 is D2's).
  select string_agg(format('%s/%s/%s..%s', t.basis, t.placement,
                           to_char(t.effective_start at time zone 'UTC', 'MM-DD'),
                           coalesce(to_char(t.effective_end at time zone 'UTC', 'MM-DD'), 'open')), ' | '
                    order by t.effective_start, t.scope) into got
    from internal.placement_intervals_for_device_v1(u, d2, null, null) t;
  assert got = 'account/wrist/09-01..open | installation/unknown/09-24..09-25 | installation/wrist/10-06..open', got;

  -- Point resolution: device pieces first, account rows in the gaps, nothing for another owner's strap.
  select * into r from internal.placement_for_device_v1(u, d, '2026-10-05 12:00+00');
  assert r.placement = 'bicep' and r.basis = 'installation' and r.declared_device_id = current_setting('pl.x1')::uuid;
  select * into r from internal.placement_for_device_v1(u, d, '2026-10-08 12:00+00');
  assert r.placement = 'bicep' and r.declared_device_id = current_setting('pl.x2')::uuid;
  select * into r from internal.placement_for_device_v1(u, d, '2026-10-07 07:12:02+00');
  assert r.declared_device_id = current_setting('pl.x1')::uuid, 'the earlier declaration holds until the later starts';
  select * into r from internal.placement_for_device_v1(u, d, '2026-10-03 12:00+00');
  assert r.placement = 'other' and r.basis = 'alias';
  select * into r from internal.placement_for_device_v1(u, d, '2026-10-04 10:00+00');
  assert r.placement = 'wrist' and r.scope = 'account', 'a gap in the device timeline falls back to the account row';
  select * into r from internal.placement_for_device_v1(u, d, '2026-09-28 12:00+00');
  assert r.placement = 'unknown' and r.basis = 'installation';
  select * into r from internal.placement_for_device_v1(u, d, '2026-09-26 12:00+00');
  assert r.scope = 'account', 'S6 between its straps is claimed by neither';
  select * into r from internal.placement_for_device_v1(u, d2, '2026-09-24 12:00+00');
  assert r.placement = 'unknown' and r.basis = 'installation';
  assert not exists (select 1 from internal.placement_for_device_v1(u, current_setting('pl.dv')::uuid, '2026-10-05'));
  assert not exists (select 1 from internal.placement_for_device_v1(current_setting('pl.v')::uuid, d, '2026-10-05')),
    'another owner never resolves this owner''s strap';
  select * into r from internal.placement_for_device_v1(current_setting('pl.v')::uuid,
                                                        current_setting('pl.dv')::uuid, '2026-10-05');
  assert r is null or r.placement is null, 'V''s strap: V''s installation never uploaded to it';
end $$;

-- 3. The route read --------------------------------------------------------------------------------------------------
do $$
declare u uuid := current_setting('pl.u')::uuid; d uuid := current_setting('pl.d')::uuid; r jsonb; piece jsonb;
begin
  r := public.placement_resolved_read_v1(u, d, '2026-10-05', '2026-10-08');
  assert jsonb_array_length(r) = 3, r::text;
  assert r -> 0 ->> 'scope' = 'account' and r -> 0 -> 'wrist_model_reason' = 'null'::jsonb;
  piece := r -> 1;
  assert piece ->> 'placement' = 'bicep' and piece ->> 'basis' = 'installation';
  assert piece ->> 'declared_device_id' = 'installation:' || (select split_part(external_device_id, ':', 2)
                                                                from public.devices where id = current_setting('pl.x1')::uuid)
                                          || ':my-whoop';
  assert piece -> 'wrist_model_reason' = '{"code": "placement_unsupported", "certainty": "confirmed"}', piece::text;
  assert (r -> 2 ->> 'effective_end') is null;
  r := public.placement_resolved_read_v1(u, d, '2026-09-28', '2026-09-29');
  assert r -> 1 -> 'wrist_model_reason' = '{"code": "placement_unknown", "certainty": "unknown"}', r::text;
  begin
    perform public.placement_resolved_read_v1(u, current_setting('pl.dv')::uuid);
    assert false, 'another owner''s device is refused';
  exception when insufficient_privilege then assert sqlerrm = 'device_owner_mismatch'; end;
end $$;

-- 4. Physiology context ------------------------------------------------------------------------------------------------
-- The 20261006050000 fingerprint, verbatim, for comparison.
create function pg_temp.fingerprint_20261006(p_user uuid, p_device uuid, p_day date) returns text
language sql stable as $$
  with z as (select internal.physiology_context_zone(p_user) as zone),
  w as (select z.zone, extract(epoch from ((p_day - 1)::timestamp at time zone z.zone))::bigint as lo,
               extract(epoch from ((p_day + 2)::timestamp at time zone z.zone))::bigint as hi,
               extract(epoch from ((p_day - 4)::timestamp at time zone z.zone))::bigint as exposure_lo from z)
  select encode(pg_catalog.sha256(convert_to(
    'physiology-context-deps-v1' || E'\n' || p_user::text || E'\n' || p_device::text || E'\n'
    || to_char(p_day, 'YYYY-MM-DD') || E'\nzone:' || w.zone
    || E'\nscoring:' || coalesce((select string_agg(to_char(s.day, 'YYYY-MM-DD') || ':' || s.completed_revision::text, ',' order by s.day)
           from public.scoring_jobs_v2 s where s.user_id = p_user and s.device_id = p_device
            and s.algorithm_version = 'frwhoop-server-1' and s.day between p_day - 1 and p_day + 1), '')
    || E'\nactivity:' || coalesce((select string_agg(a.algorithm_version || ':' || to_char(a.day, 'YYYY-MM-DD') || ':' || a.result_revision::text, ','
                           order by a.algorithm_version collate "C", a.day)
           from public.activity_context_days a where a.user_id = p_user and a.device_id = p_device
            and a.day between p_day - 1 and p_day + 1), '')
    || E'\nplacement:' || coalesce((select string_agg(pi.id::text || ':' || pi.revision::text || ':' || pi.placement || ':' || pi.source || ':'
                           || extract(epoch from pi.effective_start)::bigint::text || ':'
                           || coalesce(extract(epoch from pi.effective_end)::bigint::text, '-'), ',' order by pi.id)
           from public.placement_intervals pi where pi.owner = p_user and (pi.device_id is null or pi.device_id = p_device)
            and pi.effective_start < to_timestamp(w.hi) and (pi.effective_end is null or pi.effective_end > to_timestamp(w.lo))), '')
    || E'\nexposures:' || coalesce((select string_agg(e.event_id || ':' || e.revision::text, ',' order by e.event_id collate "C")
           from public.exposure_events e where e.owner = p_user and e.occurred_start < w.hi and e.occurred_end > w.exposure_lo
            and e.occurred_start > w.exposure_lo - 2678400), ''), 'UTF8')), 'hex')
  from w
$$;

do $$
declare u uuid := current_setting('pl.u')::uuid; d uuid := current_setting('pl.d')::uuid;
  v uuid := current_setting('pl.v')::uuid; dv uuid := current_setting('pl.dv')::uuid;
begin
  -- Unbound devices: byte-identical to the old formula (no existing fingerprint moves).
  assert internal.physiology_context_dependency_fingerprint(v, dv, '2026-10-05')
         = pg_temp.fingerprint_20261006(v, dv, '2026-10-05');
  assert internal.physiology_context_dependency_fingerprint(u, current_setting('pl.x1')::uuid, '2026-10-05')
         = pg_temp.fingerprint_20261006(u, current_setting('pl.x1')::uuid, '2026-10-05');
  -- The strap: the installation declaration now counts.
  assert internal.physiology_context_dependency_fingerprint(u, d, '2026-10-05')
         <> pg_temp.fingerprint_20261006(u, d, '2026-10-05');
end $$;

-- A declaration on an installation device invalidates the strap's context days (relative to today: the trigger only
-- reaches the last 120 days up to the owner's today).
do $$
declare u uuid := current_setting('pl.u')::uuid; d uuid := current_setting('pl.d')::uuid;
  x2 uuid := current_setting('pl.x2')::uuid; v_day date := (now() at time zone 'UTC')::date - 2; v_rev bigint;
begin
  perform internal.physiology_context_touch(u, d, v_day, 'retrospective', 'scoring', null);
  select input_revision into v_rev from public.physiology_context_jobs
   where user_id = u and device_id = d and day = v_day and mode = 'retrospective';
  perform public.set_placement_interval(u, 'wrist', (v_day::timestamp at time zone 'UTC') + interval '1 hour', x2);
  assert (select input_revision from public.physiology_context_jobs
           where user_id = u and device_id = d and day = v_day and mode = 'retrospective') = v_rev + 1,
    'the strap''s context day was invalidated by the installation declaration';
  assert (select 'placement_changed' = any(reasons) from public.physiology_context_jobs
           where user_id = u and device_id = d and day = v_day and mode = 'retrospective');
end $$;

-- 5. Measurement context: the builder writes the resolved placement --------------------------------------------------
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'u', :'d', :'s2', t, 70, :'s2'
  from generate_series(extract(epoch from timestamptz '2026-10-05 12:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-10-05 12:04:59+00')::bigint) t;
insert into public.noop_hr_samples (user_id, device_id, source_id, ts, bpm, batch_id)
select :'u', :'d', :'s2', t, 70, :'s2'
  from generate_series(extract(epoch from timestamptz '2026-10-04 10:00:00+00')::bigint,
                       extract(epoch from timestamptz '2026-10-04 10:01:59+00')::bigint) t;
do $$
declare u uuid := current_setting('pl.u')::uuid; d uuid := current_setting('pl.d')::uuid; r record;
begin
  perform internal.build_measurement_context_minutes(u, d, '2026-10-05 12:00+00', '2026-10-05 12:05+00');
  perform internal.build_measurement_context_minutes(u, d, '2026-10-04 10:00+00', '2026-10-04 10:02+00');
  select * into r from public.measurement_context_minutes
   where user_id = u and device_id = d and minute_start = '2026-10-05 12:03+00';
  assert r.placement = 'bicep' and r.placement_basis = 'declared_installation', format('%s %s', r.placement, r.placement_basis);
  select * into r from public.measurement_context_minutes
   where user_id = u and device_id = d and minute_start = '2026-10-04 10:01+00';
  assert r.placement = 'wrist' and r.placement_basis = 'declared_account', format('%s %s', r.placement, r.placement_basis);
  assert (select count(*) from public.measurement_context_minutes where user_id = u and device_id = d) = 7;
end $$;

-- 6. Privileges ---------------------------------------------------------------------------------------------------------
do $$ begin
  assert not has_function_privilege('authenticated', 'internal.placement_for_device_v1(uuid,uuid,timestamptz)', 'execute');
  assert not has_function_privilege('service_role', 'internal.placement_for_device_v1(uuid,uuid,timestamptz)', 'execute');
  assert not has_function_privilege('authenticated',
    'internal.placement_intervals_for_device_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
  assert not has_function_privilege('anon', 'internal.placement_bound_devices_v1(uuid,uuid)', 'execute');
  assert not has_function_privilege('authenticated',
    'public.placement_resolved_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
  assert not has_function_privilege('anon', 'public.placement_resolved_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
  assert has_function_privilege('service_role', 'public.placement_resolved_read_v1(uuid,uuid,timestamptz,timestamptz)', 'execute');
end $$;

rollback;
select 'placement_device_resolution: ok' as result;
