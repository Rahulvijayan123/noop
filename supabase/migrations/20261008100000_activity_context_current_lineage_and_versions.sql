-- Activity context: one current lineage per UTC day for current readers, and re-derivation when the
-- worker's decoder / ontology / feature schema / HART model change (audit D5-02 / D3-02 / D5-03).
--
-- 1. activity_context_epochs keeps every published lineage (PK user, device, start_ts, fingerprint), and
--    that history stays: a causal replay (physiology context, `causalLive` with an availability cutoff)
--    has to see the lineage that was current at its cutoff, and a replay can be asked for any past cutoff.
--    No compaction is added, deliberately: dropping a lineage superseded N days ago would change the
--    answer of every replay whose cutoff fell inside that lineage's lifetime, and nothing records which
--    cutoffs will be replayed. What changes is how CURRENT readers read: the new view
--    `activity_context_epochs_current` holds only the newest publish of each (user, device, UTC day) — the
--    highest result_revision of the day — which is the rule DayScoring now applies per UTC day, and the
--    new index makes that per-day maximum an index lookup instead of a scan of every lineage.
--
-- 2. Version registry. The worker registers what it runs (decoder, ontology, feature schema, publish
--    interval, decoder-config recipe and, for the raw-IMU lane, the HART model / preprocessing it resolved
--    from the service) as one row per lane. The registered tag is folded into the raw-IMU day fingerprint
--    (in place of the trigger's literal 'hart-activity-v1' / 'hart-activity-preprocess-v1' / 'v1') and into
--    the stream-day fingerprint. A newer tag re-fingerprints at once the days the existing reconcile paths
--    already look at — the raw-IMU days whose objects ended within reconcile_activity_context's lookback (7
--    days) and the stream days enqueue_activity_stream_days considers recent (36 h) — and leaves every older
--    day to the bounded sweep (3). The registration carries an ordinal (the worker's
--    `ActivityContextDays.versionsOrdinal`): an older build never overwrites a newer build's row, so two
--    builds side by side during a rolling deploy cannot flip the tag back and forth and re-queue those days
--    on every reconcile.
--
-- 2a. Settled days. A day's waking hours count as "awake" in its document only once the day has been over
--    for 12 h (the worker's `ActivityContextDays.sleepKnown`, audit D1-02); before that they are "unknown".
--    That decision is an input of the decode, so it is part of both day fingerprints: a day decoded before it
--    settled gets a new fingerprint, and is decoded again, once it has. The database settles a day 10 minutes
--    after the worker does, so a job queued by the settled fingerprint always decodes as settled even with a
--    few minutes of clock skew between the two. Applying this migration therefore re-derives, once, the
--    settled days those reconcile paths look at; with no versions registered an unsettled day's fingerprints
--    are exactly what they were.
--
-- 3. reconcile_activity_context_versions: registers the calling worker's versions and, bounded (newest
--    UTC day first, at most p_limit jobs per call, and only while that lane's queue holds fewer than
--    p_limit pending jobs, so a version bump never starves live days), re-fingerprints the jobs with a
--    stored day document whose fingerprint is not the one the registered versions (and the day's settled
--    state) give today — whatever part of the tag changed: decoder, ontology, feature schema, HART model or
--    preprocessing, decoder-config recipe, lookback or publish interval. The new fingerprint bumps
--    input_revision through the normal enqueue path.
--
-- Additive: one index, one view, one table, four internal helpers, one new RPC, and CREATE OR REPLACE of
-- the raw-IMU ready trigger function, reconcile_activity_context and enqueue_activity_stream_days with
-- their signatures and grants unchanged (each body is the previous one with the fingerprint line swapped
-- for the helper).
--
-- Rollback: drop reconcile_activity_context_versions, the view, the registry table and the helpers, and
-- re-create the three replaced functions from 20261003120000_activity_context.sql and
-- 20261003140000_activity_context_stream_days.sql.
--
-- Drafted as 20261007120000; renamed so it sorts after every migration on main (`nara/main` 3b4ee16a5), whose
-- newest are 20261007140000 .. 20261008010000 (sensor_biomarkers, sensor_biomarkers_claim_throttle,
-- coach_threads_memory, anomaly_service, metric_insights, metric_insight_background_sweep):
-- `supabase db push` refuses a local version older than the remote's newest one. Which of those production has
-- applied was not re-checked here; list the remote versions immediately before any deploy. No migration between
-- the old and the new timestamp touches these objects (metric_insights reads physiology_context_days only).
-- Production order: main's migrations through 20261008010000, then 20261008100000, 20261008100100,
-- 20261008100200, 20261008100300 (if present), 20261008100400; Spec 01's 20261008120000_ppg_transport_anchor
-- touches only noop_reserve_object_manifest_lifecycle_core and sorts after all of them.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- 1. Current lineage per UTC day.
create index if not exists activity_context_epochs_day_revision
  on public.activity_context_epochs(user_id, device_id, day, result_revision desc);

create or replace view public.activity_context_epochs_current with (security_invoker = true) as
select e.*
  from public.activity_context_epochs e
 where e.result_revision = (select max(x.result_revision) from public.activity_context_epochs x
                             where x.user_id = e.user_id and x.device_id = e.device_id and x.day = e.day);

comment on view public.activity_context_epochs_current is
  'Activity context v1 epochs of the newest publish of each (user, device, UTC day): the current answer, one '
  'row per 30 s slot. activity_context_epochs keeps every lineage for causal replay; current readers read here '
  'and stitch a local day from every UTC day it overlaps.';

revoke all on public.activity_context_epochs_current from public, anon, authenticated;
grant select on public.activity_context_epochs_current to authenticated, service_role;

-- 2. What the worker runs, per lane.
create table if not exists public.activity_context_lane_versions (
  algorithm_version text primary key
    check (algorithm_version in ('hart-activity-1', 'streams-activity-1')),
  versions jsonb not null check (jsonb_typeof(versions) = 'object'),
  versions_tag text not null check (versions_tag ~ '^[A-Za-z0-9][A-Za-z0-9._:;=+-]{0,255}$'),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.activity_context_lane_versions enable row level security;
revoke all on public.activity_context_lane_versions from public, anon, authenticated;
grant all on public.activity_context_lane_versions to service_role;
drop policy if exists activity_context_lane_versions_service on public.activity_context_lane_versions;
create policy activity_context_lane_versions_service on public.activity_context_lane_versions
  for all to service_role using (true) with check (true);

-- Whether a UTC day has settled as of p_now (2a): 12 h after its end, plus 10 minutes of clock-skew margin
-- over the worker's own rule.
create or replace function internal.activity_day_settled(p_day date, p_now timestamptz default clock_timestamp())
returns boolean language sql immutable set search_path = '' as $$
  select p_now >= ((p_day + 1)::timestamp at time zone 'UTC') + interval '12 hours 10 minutes'
$$;

-- The raw-IMU day fingerprint: the trigger's historical literals until a worker registers its versions,
-- then the registered HART model / preprocessing and the full tag; ';settled' once the day has settled.
create or replace function internal.activity_hart_day_fingerprint(p_digests text[], p_day date,
  p_now timestamptz default clock_timestamp())
returns text language sql stable set search_path = '' as $$
  select public.activity_context_fingerprint(p_digests,
    extract(epoch from (p_day::timestamp at time zone 'UTC'))::bigint,
    extract(epoch from ((p_day + 1)::timestamp at time zone 'UTC'))::bigint - 1,
    'hart-activity-1',
    coalesce(nullif(v.versions ->> 'model', ''), 'hart-activity-v1'),
    coalesce(nullif(v.versions ->> 'preprocessing', ''), 'hart-activity-preprocess-v1'),
    case when v.versions_tag is null then 'v1' else 'v1;' || v.versions_tag end
      || case when internal.activity_day_settled(p_day, p_now) then ';settled' else '' end)
  from (select 1) one
  left join public.activity_context_lane_versions v on v.algorithm_version = 'hart-activity-1'
$$;

-- The completed scoring revisions a stream day depends on (scoring days D-1..D+1), as enqueue hashes them.
create or replace function internal.activity_stream_day_marker(p_user uuid, p_device uuid, p_day date)
returns text language sql stable set search_path = '' as $$
  select string_agg(f.day::text || ':' || f.completed_revision::text, ',' order by f.day)
    from public.scoring_jobs_v2 f
   where f.user_id = p_user and f.device_id = p_device and f.completed_revision > 0
     and f.day between p_day - 1 and p_day + 1
$$;

create or replace function internal.activity_stream_day_fingerprint(p_user uuid, p_device uuid, p_day date, p_marker text,
  p_now timestamptz default clock_timestamp())
returns text language sql stable set search_path = '' as $$
  select encode(extensions.digest(convert_to(
    'activity-streams-v1' || E'\n' || p_user::text || E'\n' || p_device::text || E'\n' ||
    p_day::text || E'\n' || p_marker ||
    coalesce(E'\n' || (select v.versions_tag from public.activity_context_lane_versions v
                        where v.algorithm_version = 'streams-activity-1'), '') ||
    case when internal.activity_day_settled(p_day, p_now) then E'\nsettled' else '' end,
    'UTF8'), 'sha256'), 'hex')
$$;

revoke all on function internal.activity_day_settled(date, timestamptz) from public, anon, authenticated;
revoke all on function internal.activity_hart_day_fingerprint(text[], date, timestamptz)
  from public, anon, authenticated;
revoke all on function internal.activity_stream_day_marker(uuid, uuid, date) from public, anon, authenticated;
revoke all on function internal.activity_stream_day_fingerprint(uuid, uuid, date, text, timestamptz)
  from public, anon, authenticated;

-- 2b. The raw-IMU ready trigger and its reconcile path, with the fingerprint from the helper.
create or replace function internal.activity_raw_imu_ready() returns trigger
language plpgsql security definer set search_path='' as $$
declare d date; f text; digests text[]; ids uuid[];
begin
  if new.object_kind is distinct from 'rawImuSession' then return null; end if;
  if new.status is distinct from 'ready' then return null; end if;
  if tg_op = 'UPDATE' and old.status = 'ready' then return null; end if;
  if new.user_id is null or new.device_id is null or new.start_at is null or new.end_at is null
    or new.sha256 is null then return null; end if;
  if not exists(select 1 from public.devices where id = new.device_id and user_id = new.user_id) then
    return null;
  end if;
  if (new.end_at - new.start_at) > interval '8 days' then return null; end if;
  for d in select generate_series((new.start_at at time zone 'UTC')::date,
      (new.end_at at time zone 'UTC')::date, interval '1 day')::date
  loop
    select array_agg(m.id order by m.start_at, m.id), array_agg(lower(m.sha256) order by m.start_at, m.id)
      into ids, digests
    from public.object_manifests m
    where m.user_id = new.user_id and m.device_id = new.device_id
      and m.object_kind = 'rawImuSession' and m.status = 'ready'
      and m.sha256 is not null and m.start_at is not null and m.end_at is not null
      and m.start_at < ((d + 1)::timestamp at time zone 'UTC')
      and m.end_at > (d::timestamp at time zone 'UTC')
      and (m.end_at - m.start_at) <= interval '8 days';
    if ids is null or cardinality(ids) = 0 then continue; end if;
    f := internal.activity_hart_day_fingerprint(digests, d);
    perform public.enqueue_activity_context(new.user_id, new.device_id, d, ids, digests, f);
  end loop;
  return null;
end $$;
revoke all on function internal.activity_raw_imu_ready() from public, anon, authenticated, service_role;

create or replace function public.reconcile_activity_context(p_lookback interval default '7 days')
returns void language plpgsql security definer set search_path='' as $$
declare r record; d date; f text; ids uuid[]; digests text[];
begin
  if p_lookback is null or p_lookback < interval '0' then raise exception 'invalid_lookback'; end if;
  for r in
    select distinct m.user_id, m.device_id,
      greatest((m.start_at at time zone 'UTC')::date, (clock_timestamp() - p_lookback)::date) as first_day,
      (m.end_at at time zone 'UTC')::date as last_day
    from public.object_manifests m
    where m.object_kind = 'rawImuSession' and m.status = 'ready'
      and m.verified_at is not null and m.sha256 is not null
      and m.start_at is not null and m.end_at is not null
      and m.end_at > clock_timestamp() - p_lookback
      and (m.end_at - m.start_at) <= interval '8 days'
  loop
    for d in select generate_series(r.first_day, r.last_day, interval '1 day')::date loop
      select array_agg(x.id order by x.start_at, x.id),
             array_agg(lower(x.sha256) order by x.start_at, x.id)
        into ids, digests
      from public.object_manifests x
      where x.user_id = r.user_id and x.device_id = r.device_id
        and x.object_kind = 'rawImuSession' and x.status = 'ready'
        and x.sha256 is not null and x.start_at is not null and x.end_at is not null
        and x.start_at < ((d + 1)::timestamp at time zone 'UTC')
        and x.end_at > (d::timestamp at time zone 'UTC')
        and (x.end_at - x.start_at) <= interval '8 days';
      if ids is null or cardinality(ids) = 0 then continue; end if;
      f := internal.activity_hart_day_fingerprint(digests, d);
      perform public.enqueue_activity_context(r.user_id, r.device_id, d, ids, digests, f);
    end loop;
  end loop;
end $$;

-- 2c. Stream days: the same queueing rules, the fingerprint from the helper (marker + registered tag).
create or replace function public.enqueue_activity_stream_days(
  p_lookback interval default interval '36 hours',
  p_backfill_limit integer default 25,
  p_min_interval interval default interval '10 minutes')
returns integer language plpgsql security definer set search_path='' as $$
declare touched integer;
begin
  if p_lookback is null or p_lookback < interval '0' or p_lookback > interval '400 days'
    or p_backfill_limit is null or p_backfill_limit < 0 or p_backfill_limit > 1000
    or p_min_interval is null or p_min_interval < interval '0' or p_min_interval > interval '1 day' then
    raise exception 'invalid_arguments';
  end if;

  with finished as (
    select s.user_id, s.device_id, s.day, s.completed_revision, s.last_completed_at
      from public.scoring_jobs_v2 s
     where s.completed_revision > 0
       and s.day >= date '2020-01-01'
       and s.day <= (clock_timestamp() at time zone 'UTC')::date + 1
  ), cand as (
    select f.user_id, f.device_id, (f.day + o.k) as day, max(f.last_completed_at) as touched_at
      from finished f cross join lateral (values (-1), (0), (1)) as o(k)
     where (f.day + o.k) <= (clock_timestamp() at time zone 'UTC')::date
     group by f.user_id, f.device_id, (f.day + o.k)
  ), recent as (
    select c.user_id, c.device_id, c.day from cand c
     where c.touched_at > clock_timestamp() - p_lookback
  ), absent as (
    select c.user_id, c.device_id, c.day from cand c
     where not exists (select 1 from public.activity_context_jobs j
                        where j.user_id = c.user_id and j.device_id = c.device_id
                          and j.day = c.day and j.algorithm_version = 'streams-activity-1')
     order by c.day desc, c.user_id, c.device_id
     limit p_backfill_limit
  ), want as (
    select r.user_id, r.device_id, r.day from recent r
    union
    select a.user_id, a.device_id, a.day from absent a
  ), marked as (
    select w.user_id, w.device_id, w.day,
           (select string_agg(f.day::text || ':' || f.completed_revision::text, ',' order by f.day)
              from finished f
             where f.user_id = w.user_id and f.device_id = w.device_id
               and f.day between w.day - 1 and w.day + 1) as marker
      from want w
  ), upserted as (
    insert into public.activity_context_jobs as t(user_id, device_id, day, algorithm_version,
      input_object_ids, input_digests, fingerprint, model_version, preprocessing_version,
      ontology_version, input_revision, reason)
    select m.user_id, m.device_id, m.day, 'streams-activity-1', '{}'::uuid[], '{}'::text[],
           internal.activity_stream_day_fingerprint(m.user_id, m.device_id, m.day, m.marker),
           'streams-activity-1', 'streams-v1', 'v2.0', 1, 'streams'
      from marked m
     where m.marker is not null
    on conflict (user_id, device_id, day, algorithm_version) do update set
      fingerprint = excluded.fingerprint,
      input_revision = t.input_revision + 1,
      dirty_at = clock_timestamp(),
      consecutive_failures = 0,
      dead_letter = false,
      last_error = null,
      not_before = greatest(clock_timestamp(),
                            coalesce(t.last_completed_at, '-infinity'::timestamptz) + p_min_interval),
      reason = 'streams'
    where t.fingerprint is distinct from excluded.fingerprint
    returning 1
  )
  select count(*)::integer into touched from upserted;
  return touched;
end $$;

-- 3. Register the worker's versions and re-derive, bounded, the days decoded by anything else.
-- p_versions: {"tag", "decoder", "ontology", "feature_schema", optional "model" / "preprocessing" and an
-- optional "ordinal" (a decimal string; absent counts as 0). A registration with a lower ordinal than the
-- stored one is refused: nothing is written, nothing is swept, and the call returns 0.
create or replace function public.reconcile_activity_context_versions(p_algorithm text, p_versions jsonb,
  p_limit integer default 4)
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; touched integer := 0; pending integer; stored jsonb;
begin
  if p_algorithm is null or p_algorithm not in ('hart-activity-1', 'streams-activity-1')
    or jsonb_typeof(p_versions) is distinct from 'object'
    or jsonb_typeof(p_versions -> 'tag') is distinct from 'string'
    or (p_versions ->> 'tag') !~ '^[A-Za-z0-9][A-Za-z0-9._:;=+-]{0,255}$'
    or jsonb_typeof(p_versions -> 'decoder') is distinct from 'string'
    or jsonb_typeof(p_versions -> 'ontology') is distinct from 'string'
    or jsonb_typeof(p_versions -> 'feature_schema') is distinct from 'string'
    or coalesce(jsonb_typeof(p_versions -> 'ordinal'), 'string') is distinct from 'string'
    or coalesce(p_versions ->> 'ordinal', '0') !~ '^[0-9]{1,9}$'
    or p_limit is null or p_limit < 0 or p_limit > 100 then
    raise exception 'invalid_arguments';
  end if;

  insert into public.activity_context_lane_versions as v(algorithm_version, versions, versions_tag)
  values (p_algorithm, p_versions, p_versions ->> 'tag')
  on conflict (algorithm_version) do update set
    versions = excluded.versions, versions_tag = excluded.versions_tag, updated_at = clock_timestamp()
  where v.versions is distinct from excluded.versions
    and coalesce(v.versions ->> 'ordinal', '0')::integer <= coalesce(excluded.versions ->> 'ordinal', '0')::integer;
  -- An older build (lower ordinal) leaves the newer build's registration, and its days, alone.
  select v.versions into stored from public.activity_context_lane_versions v where v.algorithm_version = p_algorithm;
  if stored is distinct from p_versions then return 0; end if;

  if p_limit = 0 then return 0; end if;
  -- A version bump re-derives history only while the lane's queue is nearly idle.
  select count(*) into pending from public.activity_context_jobs q
   where q.algorithm_version = p_algorithm and q.completed_revision < q.input_revision and not q.dead_letter;
  if pending >= p_limit then return 0; end if;

  for r in
    select j.user_id, j.device_id, j.day, j.input_object_ids, j.input_digests, c.fp
      from public.activity_context_days d
      join public.activity_context_jobs j
        on j.user_id = d.user_id and j.device_id = d.device_id and j.day = d.day
       and j.algorithm_version = d.algorithm_version
     cross join lateral (
       select case when p_algorithm = 'hart-activity-1'
                   then internal.activity_hart_day_fingerprint(j.input_digests, j.day)
                   else internal.activity_stream_day_fingerprint(j.user_id, j.device_id, j.day,
                          internal.activity_stream_day_marker(j.user_id, j.device_id, j.day)) end as fp) c
     where d.algorithm_version = p_algorithm
       and j.completed_revision = j.input_revision and not j.dead_letter
       and (j.lease_until is null or j.lease_until <= clock_timestamp())
       and c.fp is not null and c.fp is distinct from j.fingerprint
       and (p_algorithm <> 'hart-activity-1' or cardinality(j.input_object_ids) > 0)
     order by j.day desc, j.user_id, j.device_id
     limit (p_limit - pending)
  loop
    if p_algorithm = 'hart-activity-1' then
      perform public.enqueue_activity_context(r.user_id, r.device_id, r.day, r.input_object_ids,
        r.input_digests, r.fp);
    else
      -- The enqueue's default rebuild spacing: a day built minutes ago waits, as it would for new scoring.
      update public.activity_context_jobs set fingerprint = r.fp, input_revision = input_revision + 1,
        dirty_at = clock_timestamp(),
        not_before = greatest(clock_timestamp(),
                              coalesce(last_completed_at, '-infinity'::timestamptz) + interval '10 minutes'),
        consecutive_failures = 0,
        dead_letter = false, last_error = null, reason = 'versions'
       where user_id = r.user_id and device_id = r.device_id and day = r.day
         and algorithm_version = 'streams-activity-1';
    end if;
    touched := touched + 1;
  end loop;
  return touched;
end $$;

revoke all on function public.reconcile_activity_context_versions(text, jsonb, integer)
  from public, anon, authenticated;
grant execute on function public.reconcile_activity_context_versions(text, jsonb, integer) to service_role;

commit;
