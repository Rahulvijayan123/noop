-- ActivityContext v2 "stream days": a server-side day document for EVERY day that has stored
-- measurements, not only the days that happen to have a raw-IMU upload, plus the read surface
-- downstream jobs use to ask "what was the user doing at second T, how sure were we, and when did
-- it change".
--
-- Additive, with ONE deliberate edit to an existing function (claim_activity_context_v2, below).
-- Nothing here writes to a table that already existed except the shared job queue
-- (activity_context_jobs, new rows with algorithm_version 'streams-activity-1') and the existing
-- day-document table through the already-deployed publish_activity_context_day. It does not touch
-- scoring, the v1 epochs or any ingest table, and it never calls scoring_dirty_span, so a stream
-- day can never feed back into the scoring work that triggers it.
--
-- Rollback: drop the three stream functions, the two views and activity_context_at, delete the
-- 'streams-activity-1' rows from activity_context_jobs / activity_context_days if wanted, and
-- re-create claim_activity_context_v2 from 20261003120000_activity_context.sql.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. The raw-IMU claim must never hand out a stream-day job. A worker that predates the stream
--    lane (or runs with the stream source off) would otherwise claim one, find no input objects and
--    burn its failure budget on a job it cannot interpret. Everything else is the function it
--    replaces, byte for byte; grants are kept by CREATE OR REPLACE and restated at the end.
create or replace function public.claim_activity_context_v2(p_lease_seconds integer default 300)
returns setof public.activity_context_jobs language plpgsql security definer set search_path='' as $$
declare j public.activity_context_jobs;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  select q.* into j from public.activity_context_jobs q
  where q.completed_revision < q.input_revision and not q.dead_letter and q.not_before <= clock_timestamp()
    and q.algorithm_version <> 'streams-activity-1'
    and (q.lease_until is null or q.lease_until <= clock_timestamp())
  order by coalesce((select max(s.last_claimed_at) from public.activity_context_jobs s where s.user_id = q.user_id),
                    '-infinity'::timestamptz),
           (q.dirty_at < clock_timestamp() - interval '1 hour') desc,
           case when q.dirty_at < clock_timestamp() - interval '1 hour' then q.dirty_at end,
           q.day desc, q.dirty_at, q.device_id
  for update of q skip locked limit 1;
  if not found then return; end if;
  return query update public.activity_context_jobs q set lease_token = gen_random_uuid(),
    lease_until = clock_timestamp() + make_interval(secs => p_lease_seconds),
    last_claimed_at = clock_timestamp(), claim_count = q.claim_count + 1,
    lease_expiry_count = q.lease_expiry_count + case when q.lease_token is null then 0 else 1 end
  where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day
    and q.algorithm_version = j.algorithm_version
  returning q.*;
end $$;

-- 2. The stream-day claim: the same lease and fairness rules, restricted to stream-day jobs. Renew
--    and fail are keyed by the lease token alone, so the existing renew_activity_context_v2 /
--    fail_activity_context_v2 serve these jobs unchanged (bounded backoff, dead-letter at 8).
create function public.claim_activity_stream_day(p_lease_seconds integer default 300)
returns setof public.activity_context_jobs language plpgsql security definer set search_path='' as $$
declare j public.activity_context_jobs;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  select q.* into j from public.activity_context_jobs q
  where q.completed_revision < q.input_revision and not q.dead_letter and q.not_before <= clock_timestamp()
    and q.algorithm_version = 'streams-activity-1'
    and (q.lease_until is null or q.lease_until <= clock_timestamp())
  order by coalesce((select max(s.last_claimed_at) from public.activity_context_jobs s where s.user_id = q.user_id),
                    '-infinity'::timestamptz),
           (q.dirty_at < clock_timestamp() - interval '1 hour') desc,
           case when q.dirty_at < clock_timestamp() - interval '1 hour' then q.dirty_at end,
           q.day desc, q.dirty_at, q.device_id
  for update of q skip locked limit 1;
  if not found then return; end if;
  return query update public.activity_context_jobs q set lease_token = gen_random_uuid(),
    lease_until = clock_timestamp() + make_interval(secs => p_lease_seconds),
    last_claimed_at = clock_timestamp(), claim_count = q.claim_count + 1,
    lease_expiry_count = q.lease_expiry_count + case when q.lease_token is null then 0 else 1 end
  where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day
    and q.algorithm_version = j.algorithm_version
  returning q.*;
end $$;

-- 3. Which UTC days need a stream document, and when to rebuild one.
--
--    The signal that a day's measurements changed is the scoring service finishing work for it:
--    scoring is data-driven, so every batch of new heart-rate / motion / step / event rows ends in a
--    completed scoring revision. A stream day for UTC day D therefore depends on the completed scoring
--    revisions of the three scoring days D-1, D and D+1 (a UTC day overlaps up to three local days);
--    that list of (day, revision) pairs is hashed into the job fingerprint, so a changed list bumps
--    input_revision exactly like a changed raw-IMU object set does for the other lane.
--
--    Two sets of days are touched on each call, both bounded:
--      * days whose scoring work completed within p_lookback (the live and just-corrected days), and
--      * up to p_backfill_limit days that have scoring history but no stream job yet, newest first
--        (the one-off historical backfill, which a call with a larger limit can finish at once).
--    A rebuild of an existing job is held back until p_min_interval has passed since its last
--    completion, so a live day that scores every few minutes is rebuilt at most that often. An
--    unchanged marker is a no-op that writes nothing. Returns the number of jobs created or bumped.
create function public.enqueue_activity_stream_days(
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
    -- A UTC day that has not started cannot hold measurements yet. Dropping it here, before the backfill
    -- limit, keeps the days that never get a job from using up the limit on every call.
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
           encode(extensions.digest(convert_to(
             'activity-streams-v1' || E'\n' || m.user_id::text || E'\n' || m.device_id::text || E'\n' ||
             m.day::text || E'\n' || m.marker, 'UTF8'), 'sha256'), 'hex'),
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

-- 4. Complete a stream-day job. The document (when there is one) goes through the same validating
--    publish_activity_context_day as every other day document, in the same transaction as the
--    completion, so a rejected document completes nothing and the job is retried with backoff.
--    p_payload NULL / JSON null means "this day has no measurements to describe": the job is
--    completed without a document and any earlier document is left alone.
--    Returns the document's result revision (> 0), 0 when completed without a document, and NULL
--    when the fence says the lease or revision is no longer ours (nothing written).
create function public.complete_activity_stream_day(p_token uuid, p_revision bigint,
  p_payload jsonb, p_duration_ms bigint)
returns bigint language plpgsql security definer set search_path='' as $$
declare j public.activity_context_jobs; rev bigint := 0; finished_at timestamptz;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;
  if j.algorithm_version <> 'streams-activity-1' then raise exception 'not_a_stream_day_job'; end if;
  if p_payload is not null and p_payload <> 'null'::jsonb then
    rev := public.publish_activity_context_day(p_token, p_revision, p_payload);
    if rev is null then return null; end if;
  end if;
  finished_at := clock_timestamp();
  update public.activity_context_jobs set completed_revision = p_revision,
    lease_token = null, lease_until = null, consecutive_failures = 0, dead_letter = false,
    last_error = null, last_completed_at = finished_at, last_duration_ms = greatest(0, p_duration_ms),
    success_count = success_count + 1
  where user_id = j.user_id and device_id = j.device_id and day = j.day
    and algorithm_version = j.algorithm_version;
  return rev;
end $$;

-- 5. The read surface. Every state the decoder published, one row per run, with the exact second
--    it began and ended, how sure the decoder was, and what it believed about posture, locomotion
--    and arm behaviour. Runs partition the observed time without overlap, so a measurement taken at
--    second T has at most one row per algorithm covering it (none when nothing was observed then).
--    security_invoker makes the views run with the caller's rights: an owner sees their own rows
--    through the days table's select policy, the service role sees all.
create view public.activity_context_runs with (security_invoker = true) as
select d.user_id, d.device_id, d.day, d.algorithm_version,
       (r.value ->> 's')::bigint as start_ts,
       (r.value ->> 'e')::bigint as end_ts,
       to_timestamp((r.value ->> 's')::bigint) as start_at,
       to_timestamp((r.value ->> 'e')::bigint) as end_at,
       ((r.value ->> 'e')::bigint - (r.value ->> 's')::bigint)::integer as duration_s,
       r.value ->> 'display_context' as display_context,
       (r.value ->> 'overall_confidence')::real as confidence,
       (r.value ->> 'overall_uncertainty')::real as uncertainty,
       (r.value ->> 'intensity')::real as intensity,
       r.value ->> 'sleep' as sleep_state,
       r.value ->> 'wear' as wear_state,
       (r.value ->> 'n')::integer as states,
       r.value -> 'posture' as posture,
       r.value -> 'locomotion' as locomotion,
       r.value -> 'arm_behavior' as arm_behavior,
       d.model_version, d.decoder_version, d.ontology_version, d.feature_schema,
       d.encoder_id, d.encoder_version, d.result_revision, d.computed_at,
       case d.algorithm_version when 'hart-activity-1' then 1 else 2 end as source_rank
  from public.activity_context_days d
 cross join lateral jsonb_array_elements(d.document -> 'runs') as r(value);

-- Every flagged change of state (sit to stand, start of walking, wrist on / off, ...) with the exact
-- second it was first flagged and the decoder's probability that it really happened.
create view public.activity_context_transitions with (security_invoker = true) as
select d.user_id, d.device_id, d.day, d.algorithm_version,
       (e.value ->> 'ts')::bigint as ts,
       to_timestamp((e.value ->> 'ts')::bigint) as at,
       e.value ->> 'kind' as kind,
       (e.value ->> 'probability')::real as probability,
       d.model_version, d.decoder_version, d.ontology_version, d.feature_schema,
       d.encoder_id, d.encoder_version, d.result_revision, d.computed_at,
       case d.algorithm_version when 'hart-activity-1' then 1 else 2 end as source_rank
  from public.activity_context_days d
 cross join lateral jsonb_array_elements(d.document -> 'events') as e(value);

comment on view public.activity_context_runs is
  'ActivityContext v2: one row per decoded run (exact start/end unix seconds, display_context, confidence, '
  'uncertainty, posture/locomotion/arm head probabilities). UTC days; source_rank 1 = raw-IMU (HART) '
  'document, 2 = measurement-stream document. Join a measurement timestamp ts with start_ts <= ts < end_ts.';
comment on view public.activity_context_transitions is
  'ActivityContext v2: every flagged change of state with its exact unix-second timestamp and probability.';

-- What was the user doing at this second? One row per algorithm that has a document for the UTC
-- day containing p_ts and a run covering it, best source first. The caller's rights apply.
create function public.activity_context_at(p_user uuid, p_device uuid, p_ts bigint)
returns table (algorithm_version text, start_ts bigint, end_ts bigint, display_context text,
               confidence real, uncertainty real, intensity real, sleep_state text, wear_state text,
               states integer, posture jsonb, locomotion jsonb, arm_behavior jsonb,
               model_version text, decoder_version text, computed_at timestamptz)
language sql stable set search_path='' as $$
  select r.algorithm_version, r.start_ts, r.end_ts, r.display_context, r.confidence, r.uncertainty,
         r.intensity, r.sleep_state, r.wear_state, r.states, r.posture, r.locomotion, r.arm_behavior,
         r.model_version, r.decoder_version, r.computed_at
    from public.activity_context_runs r
   where r.user_id = p_user and r.device_id = p_device
     and r.day = (to_timestamp(p_ts) at time zone 'UTC')::date
     and r.start_ts <= p_ts and p_ts < r.end_ts
   order by r.source_rank, r.algorithm_version
$$;

-- 6. Privileges. The three queue functions are the worker's (service role) only. The views and the
--    lookup are readable by signed-in users, scoped to their own rows by the days table's policy.
revoke all on function public.claim_activity_context_v2(integer) from public, anon, authenticated;
revoke all on function public.claim_activity_stream_day(integer) from public, anon, authenticated;
revoke all on function public.enqueue_activity_stream_days(interval, integer, interval) from public, anon, authenticated;
revoke all on function public.complete_activity_stream_day(uuid, bigint, jsonb, bigint) from public, anon, authenticated;
revoke all on function public.activity_context_at(uuid, uuid, bigint) from public, anon;
revoke all on public.activity_context_runs from public, anon, authenticated;
revoke all on public.activity_context_transitions from public, anon, authenticated;
grant execute on function public.claim_activity_context_v2(integer) to service_role;
grant execute on function public.claim_activity_stream_day(integer) to service_role;
grant execute on function public.enqueue_activity_stream_days(interval, integer, interval) to service_role;
grant execute on function public.complete_activity_stream_day(uuid, bigint, jsonb, bigint) to service_role;
grant execute on function public.activity_context_at(uuid, uuid, bigint) to authenticated, service_role;
grant select on public.activity_context_runs to authenticated, service_role;
grant select on public.activity_context_transitions to authenticated, service_role;

commit;
