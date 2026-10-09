-- Placement re-scope repair for straps whose placement was declared on installation-scoped devices.
-- REVIEWED OPERATOR SCRIPT. DRY RUN BY DEFAULT: it reports and rolls back unless -v apply=1 is given.
--
-- Needs 20261009150100_placement_device_resolution.sql applied first (it uses the resolver). Run as the database
-- owner (postgres) on the target project, owner by owner:
--
--   psql "$DB" -X -v ON_ERROR_STOP=1 -v owner=<auth user uuid> -f deploy/placement-rescope-strap.sql            # report
--   psql "$DB" -X -v ON_ERROR_STOP=1 -v owner=<uuid> -v apply=1 -f deploy/placement-rescope-strap.sql           # requeue
--   psql "$DB" -X -v ON_ERROR_STOP=1 -v owner=<uuid> -v apply=1 -v copy=1 -f deploy/placement-rescope-strap.sql # + copy
--
-- WHAT IT DOES
-- With the resolver deployed every lane already reads the right placement for NEW work. Outputs computed before it
-- still say "unknown": nothing re-runs them by itself, because the sensor-biomarker fingerprint covers only object
-- digests and the physiology-context fingerprint is re-checked only when scoring of a day completes again.
--   report  (always)  the strap's resolved placement timeline, the declarations it uses that sit on other devices
--                     (alias / installation), and the strap's derived days the timeline reaches.
--   apply=1           re-queue those days: physiology context (public.invalidate_physiology_context_span_v1, at most
--                     the last 120 days, reason placement_changed), sensor biomarkers (input_revision + 1 on the
--                     strap's jobs from the first declared UTC day; the worker recomputes and republishes), and the
--                     built measurement-context days (re-queued for the 5-minute builder). No placement or alias row
--                     is written.
--   apply=1 copy=1    also re-declares each resolved piece that came from another device on the strap itself
--                     (public.set_placement_interval, same placement / start / end / source), so the strap's own rows
--                     say what the resolver infers. Additive: the original rows stay where they are. Optional: no
--                     reader needs it once 20261009150100 is deployed.
-- It never writes noop_wearable_aliases: an alias re-routes the installation's uploads and needs the strap's serial
-- as evidence (confirm_noop_wearable), which only the phone has.
--
-- OWNER (c4383464-61b3-48e1-b2cb-b57153ace67e), expected from production as read on 2026-10-09:
--   strap 155ad9d4-b797-5e90-a495-9396939a9906 (whoop-<serial>); declarations: bicep on 5cfe8f4a (installation
--   60e90bf8, which uploaded to the strap 10-04 23:46 .. 10-06 18:57 UTC, no other strap) from 10-04 21:49:41 UTC,
--   bicep on 3395021e (installation fc420611, uploading to the strap since 10-06 19:08 UTC) from 10-07 07:12:03 UTC.
--   Resolved: bicep [10-04 21:49:41, 10-07 07:12:03) basis installation 5cfe8f4a, bicep [10-07 07:12:03, open)
--   basis installation 3395021e; no account-level row.
--   apply=1: physiology-context days 2026-10-04 .. today re-queued (10 jobs exist), sensor-biomarker jobs
--   2026-10-05 .. 2026-10-09 bumped (5 jobs; their days now withhold unknown_wrist_placement and will withhold the
--   wrist-trained tremor / arm-swing families as placement_unsupported, and carry body_location bicep), built
--   measurement-context days from 2026-10-03 re-queued.
--   copy=1: two placement rows on 155ad9d4: bicep [10-04 21:49:41, 10-07 07:12:03) and bicep [10-07 07:12:03, open),
--   source user. The placement trigger then also invalidates the strap's context days (already re-queued above).
\set ON_ERROR_STOP on
\if :{?owner}
\else
  \echo 'set -v owner=<auth user uuid>'
  \quit
\endif
\if :{?apply}
\else
  \set apply 0
\endif
\if :{?copy}
\else
  \set copy 0
\endif
select (:'apply' = '1') as do_apply, (:'apply' = '1' and :'copy' = '1') as do_copy \gset

begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';
select set_config('rescope.owner', :'owner', true) \g /dev/null

do $$ begin
  if to_regprocedure('internal.placement_intervals_for_device_v1(uuid,uuid,timestamptz,timestamptz)') is null then
    raise exception 'apply 20261009150100_placement_device_resolution.sql first';
  end if;
  if not exists (select 1 from auth.users where id = current_setting('rescope.owner')::uuid) then
    raise exception 'no such owner';
  end if;
end $$;

-- The owner's straps (devices that are not installation-scoped) and their resolved device pieces.
create temp table rescope_pieces on commit drop as
select d.id as strap, d.external_device_id as strap_external, r.*,
       x.external_device_id as declared_external
  from public.devices d
 cross join lateral internal.placement_intervals_for_device_v1(d.user_id, d.id, null, null) r
  left join public.devices x on x.id = r.declared_device_id and x.user_id = d.user_id
 where d.user_id = current_setting('rescope.owner')::uuid
   and coalesce(d.external_device_id, '') not like 'installation:%'
   and r.scope = 'device';

\echo '== resolved placement per strap (device pieces) =='
select strap, basis, placement, effective_start, coalesce(effective_end::text, 'open') as effective_end,
       declared_external, revision
  from rescope_pieces order by strap, effective_start;

\echo '== pieces declared on another device (what the repair is about) =='
create temp table rescope_targets on commit drop as
select strap, min(effective_start) as first_at
  from rescope_pieces where basis in ('alias', 'installation') group by strap;
select t.strap, t.first_at,
       (t.first_at at time zone internal.physiology_context_zone(current_setting('rescope.owner')::uuid))::date
         as first_local_day,
       (select count(*) from public.physiology_context_jobs j
         where j.user_id = current_setting('rescope.owner')::uuid and j.device_id = t.strap
           and j.day >= (t.first_at at time zone internal.physiology_context_zone(j.user_id))::date) as context_jobs,
       (select count(*) from public.sensor_biomarker_jobs s
         where s.user_id = current_setting('rescope.owner')::uuid and s.device_id = t.strap
           and s.day >= (t.first_at at time zone 'UTC')::date) as sensor_jobs
  from rescope_targets t order by t.strap;

\if :do_apply
  \echo '== apply: re-queue derived days =='
  select t.strap,
         public.invalidate_physiology_context_span_v1(
           current_setting('rescope.owner')::uuid, t.strap,
           (t.first_at at time zone internal.physiology_context_zone(current_setting('rescope.owner')::uuid))::date,
           internal.physiology_context_today(current_setting('rescope.owner')::uuid), 'placement_changed')
           as context_days_requeued
    from rescope_targets t;
  update public.sensor_biomarker_jobs s
     set input_revision = s.input_revision + 1, dirty_at = clock_timestamp(), not_before = clock_timestamp(),
         consecutive_failures = 0, dead_letter = false, last_error = null, reason = 'placement_changed'
    from rescope_targets t
   where s.user_id = current_setting('rescope.owner')::uuid and s.device_id = t.strap
     and s.day >= (t.first_at at time zone 'UTC')::date;
  do $$ begin
    if to_regclass('internal.measurement_context_work') is not null then
      update internal.measurement_context_work w set queued_at = coalesce(w.queued_at, clock_timestamp())
        from rescope_targets t
       where w.user_id = current_setting('rescope.owner')::uuid and w.device_id = t.strap
         and w.day >= (t.first_at at time zone 'UTC')::date - 1;
    end if;
  end $$;
  \if :do_copy
    \echo '== apply: copy the resolved pieces onto the strap =='
    select p.strap, p.placement, p.effective_start, p.effective_end,
           (public.set_placement_interval(current_setting('rescope.owner')::uuid, p.placement, p.effective_start,
                                          p.strap, p.effective_end, p.source)).id as new_interval
      from rescope_pieces p
     where p.basis in ('alias', 'installation')
     order by p.strap, p.effective_start;
  \endif
  commit;
  \echo 'applied'
\else
  rollback;
  \echo 'dry run: nothing written (add -v apply=1 to re-queue, and -v copy=1 to also copy onto the strap)'
\endif
