-- Re-audit repair round (audit-g5g6-isolation P2-1 + P2-3).
--
-- P2-1 (metric-series fence scope): `publish_metric_series_v1`'s input-revision
-- fence read the max `scoring_jobs_v2.input_revision` for the CALLING device
-- (`device_id = p_device`), but `server_metric_series` writes/deletes are
-- DEVICE-AGNOSTIC (keyed per (user, metric, bucket_start)). A mid-day selected-
-- device switch A->B->A let a stale A-pass whose own job row still held the older
-- revision pass the fence and overwrite B's newer series. The
-- `selected_scoring_device_v2` 'not_selected' gate still applies as-is; the fence
-- is now the USER/DAY max input_revision across all of the day's devices, which is
-- the true freshness of the device-agnostic write target.
--
-- P2-3 (closure resurrection window): `scoring_enqueue_due_day_closure` had no
-- `noop_account_retirements` check, so during the account-deletion freeze window
-- (begin_noop_account_deletion, 20260921113000) the closure sweep could enqueue
-- fresh v2 work for a frozen owner; the worker could then publish and resurrect
-- the deleted owner's day rows until the cascade delete completed. The sweep now
-- excludes owners present in `noop_account_retirements` (the same tombstone the
-- existing legacy claim predicates check), mirroring the pattern in
-- ScoringLane.legacyCandidatesSQL. CLAIM-PATH RESIDUAL (documented, not changed):
-- `enqueue_scoring_v2` / `claim_scoring_v2` themselves do not check retirements
-- (20260918010000 behaviour), so a job ALREADY queued before a freeze can still be
-- claimed and published until the cascade delete completes; reads are already
-- blocked by retirement checks in every read RPC, and the rows are cascade-
-- deleted when deletion completes, so the window is bounded and self-cleaning.
-- Closing the claim side was judged too invasive for this repair and is left to a
-- follow-up if the auditor requires it.
--
-- Additive only. One transaction.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- P2-1: fence the device-agnostic series write on the user/day max revision.
create or replace function public.publish_metric_series_v1(
  p_user uuid, p_device uuid, p_day date, p_version text, p_payload jsonb, p_input_revision bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  metrics constant text[] := array['hrv_rmssd_ms','resting_hr_bpm','resp_rate_bpm','steps','calories_kcal'];
  m text;
  bucket integer;
  metric_bucket integer;
  widths jsonb;
  algo text;
  w_start timestamptz;
  w_end timestamptz;
  points jsonb;
  stamps timestamptz[];
  n integer;
  total_upserted integer := 0;
  total_deleted integer := 0;
  per jsonb := '{}'::jsonb;
  latest_rev bigint;
begin
  if p_user is null or p_device is null or p_day is null or coalesce(p_version, '') = ''
     or jsonb_typeof(p_payload) is distinct from 'object'
     or jsonb_typeof(p_payload -> 'metrics') is distinct from 'object' then
    raise exception 'metric series: invalid arguments' using errcode = '22023';
  end if;
  bucket := (p_payload ->> 'bucket_seconds')::integer;
  algo := p_payload ->> 'algorithm_version';
  w_start := to_timestamp((p_payload #>> '{window,start}')::bigint);
  w_end := to_timestamp((p_payload #>> '{window,end}')::bigint);
  if bucket is null or bucket not between 60 and 3600
     or algo is null or length(algo) not between 1 and 64
     or w_start is null or w_end is null or w_end <= w_start or w_end - w_start > interval '50 hours'
     or exists (select 1 from jsonb_object_keys(p_payload -> 'metrics') k where k <> all (metrics)) then
    raise exception 'metric series: invalid payload' using errcode = '22023';
  end if;

  widths := coalesce(p_payload -> 'metric_bucket_seconds', '{}'::jsonb);
  if jsonb_typeof(widths) is distinct from 'object'
     or exists (select 1 from jsonb_object_keys(widths) k where k <> all (metrics))
     or exists (select 1 from jsonb_each(widths) e
                 where not (case when jsonb_typeof(e.value) = 'number' and e.value::text ~ '^[0-9]{2,4}$'
                                 then e.value::text::integer between 60 and 3600
                                 else false end)) then
    raise exception 'metric series: invalid metric bucket widths' using errcode = '22023';
  end if;

  if not exists (select 1 from devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'metric series: device does not belong to the user' using errcode = '42501';
  end if;
  if not exists (select 1 from scoring_algorithms_v2 a where a.algorithm_version = p_version) then
    raise exception 'metric series: % is not a scoring algorithm', p_version using errcode = '22023';
  end if;
  if p_input_revision is null or p_input_revision <= 0 then
    raise exception 'metric series: a positive input revision is required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('metric_series:' || p_user::text || ':' || p_day::text, 0));
  if public.selected_scoring_device_v2(p_user, p_day, p_version) is distinct from p_device then
    return jsonb_build_object('applied', false, 'reason', 'not_selected');
  end if;

  -- Input-revision fence (P2-1): the write target is user/day-scoped (the series
  -- table is keyed (user, metric, bucket_start), not per device), so freshness is
  -- the max input_revision across ALL of the day's devices for this user. A stale
  -- pass for any device — including one whose OWN job row still holds an older
  -- revision after a mid-day selected-device switch — must not overwrite the
  -- newer series. Mirrors publish_scoring_snapshot_v2's job-row guard.
  select max(input_revision) into latest_rev from public.scoring_jobs_v2
    where user_id = p_user and day = p_day;
  if latest_rev is not null and p_input_revision < latest_rev then
    return jsonb_build_object('applied', false, 'reason', 'superseded',
      'claimed_input_revision', p_input_revision, 'latest_input_revision', latest_rev);
  end if;

  foreach m in array metrics loop
    -- A metric that is absent leaves what is stored alone; one that is present, even empty, replaces the window.
    if not (p_payload -> 'metrics') ? m then
      continue;
    end if;
    points := p_payload -> 'metrics' -> m;
    if jsonb_typeof(points) is distinct from 'array' or jsonb_array_length(points) > 1500 then
      raise exception 'metric series: invalid points for %', m using errcode = '22023';
    end if;
    metric_bucket := coalesce((widths ->> m)::integer, bucket);

    select coalesce(array_agg(to_timestamp((e ->> 0)::bigint)), '{}'::timestamptz[]) into stamps
      from jsonb_array_elements(points) e;
    if exists (select 1 from unnest(stamps) t where t < w_start or t >= w_end) then
      raise exception 'metric series: % has a point outside the window', m using errcode = '22023';
    end if;

    with incoming as (
      select distinct on (to_timestamp((e ->> 0)::bigint))
             to_timestamp((e ->> 0)::bigint) as bucket_start,
             (e ->> 1)::double precision as value,
             coalesce((e ->> 2)::integer, 0) as sample_count,
             (e ->> 3)::real as coverage,
             (e ->> 4)::real as motion
        from jsonb_array_elements(points) e
       order by to_timestamp((e ->> 0)::bigint)
    ), written as (
      insert into server_metric_series as s
        (user_id, metric, bucket_start, bucket_seconds, value, sample_count, coverage, motion, device_id, algorithm_version)
      select p_user, m, i.bucket_start, metric_bucket, i.value, i.sample_count, i.coverage, i.motion, p_device, algo
        from incoming i
      on conflict (user_id, metric, bucket_start) do update
        set bucket_seconds = excluded.bucket_seconds, value = excluded.value, sample_count = excluded.sample_count,
            coverage = excluded.coverage, motion = excluded.motion, device_id = excluded.device_id,
            algorithm_version = excluded.algorithm_version, computed_at = now()
        where (s.bucket_seconds, s.value, s.sample_count, s.coverage, s.motion, s.device_id, s.algorithm_version)
              is distinct from
              (excluded.bucket_seconds, excluded.value, excluded.sample_count, excluded.coverage, excluded.motion,
               excluded.device_id, excluded.algorithm_version)
      returning 1
    )
    select count(*) into n from written;
    total_upserted := total_upserted + n;
    per := per || jsonb_build_object(m, jsonb_build_object('upserted', n));

    delete from server_metric_series s
     where s.user_id = p_user and s.metric = m and s.bucket_start >= w_start and s.bucket_start < w_end
       and s.bucket_start <> all (stamps);
    get diagnostics n = row_count;
    total_deleted := total_deleted + n;
    per := jsonb_set(per, array[m, 'deleted'], to_jsonb(n));
  end loop;

  return jsonb_build_object('applied', true, 'upserted', total_upserted, 'deleted', total_deleted, 'metrics', per);
end $$;

revoke all on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb, bigint)
  from public, anon, authenticated;
grant execute on function public.publish_metric_series_v1(uuid, uuid, date, text, jsonb, bigint)
  to service_role;

-- P2-3: closure sweep skips frozen owners (noop_account_retirements tombstone).
create or replace function public.scoring_enqueue_due_day_closure(
  p_limit integer default 16, p_version text default 'frwhoop-server-1',
  p_settle_seconds integer default 600)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  n integer := 0;
  r record;
begin
  if p_limit is null or p_limit < 1 or p_limit > 256 then
    raise exception 'invalid day-closure limit' using errcode = '22023';
  end if;
  if p_settle_seconds is null or p_settle_seconds < 0 or p_settle_seconds > 86400 then
    raise exception 'invalid day-closure settle window' using errcode = '22023';
  end if;
  if not exists (select 1 from public.scoring_algorithms_v2 a where a.algorithm_version = p_version and a.enabled) then
    raise exception 'day closure: scoring algorithm not enabled' using errcode = '22023';
  end if;

  for r in
    select z.user_id, z.device_id,
           ((clock_timestamp() at time zone z.tz)::date - 1) as day,
           z.tz
      from (
        select d.user_id, d.id as device_id,
               coalesce(nullif(btrim(p.timezone), ''), 'UTC') as tz
          from public.devices d
          join public.profiles p on p.id = d.user_id
         where d.is_active
      ) z
      join pg_timezone_names t on t.name = z.tz
     where clock_timestamp() >=
             (((clock_timestamp() at time zone z.tz)::date - 1)::timestamp at time zone z.tz)
             + make_interval(secs => p_settle_seconds)
       -- P2-3: a frozen owner (account deletion in progress) must get NO closure
       -- work. Same tombstone the legacy claim predicates check. (The table alias
       -- is NOT named r: a subquery alias matching the PL/pgSQL loop record
       -- variable would resolve to the record and raise "record r is not
       -- assigned yet".)
       and not exists (select 1 from public.noop_account_retirements ret
                        where ret.user_id = z.user_id)
       -- The day's local boundary has passed; it must still be pending v2 work.
       and exists (select 1 from public.scoring_jobs_v2 j
                    where j.user_id = z.user_id and j.device_id = z.device_id
                      and j.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                      and j.algorithm_version = p_version
                      and j.completed_revision < j.input_revision and not j.dead_letter)
       -- Idempotency: never re-enqueue a day already marked pending or closed.
       and not exists (select 1 from public.day_completeness c
                        where c.user_id = z.user_id
                          and c.day = ((clock_timestamp() at time zone z.tz)::date - 1)
                          and c.closure_state is not null)
     order by z.user_id, z.device_id
     limit p_limit
  loop
    perform public.enqueue_scoring_v2(r.user_id, r.device_id, r.day, p_version, 'day_closure');
    insert into public.day_completeness (user_id, day, closure_state, updated_at)
      values (r.user_id, r.day, 'pending_reconciliation', clock_timestamp())
      on conflict (user_id, day) do update
        set closure_state = 'pending_reconciliation', updated_at = clock_timestamp()
        where public.day_completeness.closure_state is null;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.scoring_enqueue_due_day_closure(integer, text, integer)
  from public, anon, authenticated;
grant execute on function public.scoring_enqueue_due_day_closure(integer, text, integer)
  to service_role;

notify pgrst, 'reload schema';
commit;
