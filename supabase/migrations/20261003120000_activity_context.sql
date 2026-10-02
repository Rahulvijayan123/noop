-- Activity context (HART): durable job queue + epoch store, per contracts C5/C10.
-- Additive only. Mirrors the scoring_v2 lease/fence pattern; epochs replace only the
-- published fingerprint's range for the day. No production data is reassigned.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Deterministic input fingerprint: sorted content digests, then UTC range, then versions.
-- The activity worker must call this same function (or replicate the canonical form exactly)
-- so a late verified object or version change produces a distinct fingerprint and a bounded
-- recomputation via input_revision bump.
create function public.activity_context_fingerprint(p_digests text[], p_start bigint, p_end bigint,
  p_algorithm text, p_model text, p_preprocessing text, p_ontology text)
returns text language sql immutable set search_path='' as $$
  select encode(extensions.digest(convert_to(
    'activity-input-v1' || E'\n' ||
    coalesce(array_to_string(array_agg(lower(x) order by x), E'\n'), '') || E'\n' ||
    p_start::text || E'\n' || p_end::text || E'\n' ||
    coalesce(p_algorithm, '') || E'\n' || coalesce(p_model, '') || E'\n' ||
    coalesce(p_preprocessing, '') || E'\n' || coalesce(p_ontology, ''), 'UTF8'), 'sha256'), 'hex')
  from unnest(p_digests) as d(x)
$$;
revoke all on function public.activity_context_fingerprint(text[],bigint,bigint,text,text,text,text)
  from public, anon, authenticated;
grant execute on function public.activity_context_fingerprint(text[],bigint,bigint,text,text,text,text)
  to service_role;

-- One job per (owner, device, UTC day, algorithm). Deterministic PK makes retries upsert
-- instead of duplicating; the fingerprint change drives input_revision, the lease/fence pair
-- follows the scoring_v2 durability contract exactly.
create table public.activity_context_jobs (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null default 'hart-activity-1'
    check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  input_object_ids uuid[] not null default '{}'::uuid[],
  input_digests text[] not null default '{}'::text[],
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  model_version text not null default 'hart-activity-v1',
  preprocessing_version text not null default 'hart-activity-preprocess-v1',
  ontology_version text not null default 'v1',
  input_revision bigint not null default 0 check (input_revision >= 0),
  completed_revision bigint not null default 0 check (completed_revision >= 0),
  lease_token uuid,
  lease_until timestamptz,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  dead_letter boolean not null default false,
  not_before timestamptz not null default clock_timestamp(),
  dirty_at timestamptz not null default clock_timestamp(),
  last_claimed_at timestamptz,
  last_completed_at timestamptz,
  last_duration_ms bigint,
  last_error text,
  reason text not null default 'input',
  claim_count bigint not null default 0,
  success_count bigint not null default 0,
  renewal_count bigint not null default 0,
  lease_expiry_count bigint not null default 0,
  primary key (user_id, device_id, day, algorithm_version),
  check ((lease_token is null) = (lease_until is null)),
  check (completed_revision <= input_revision),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index activity_context_jobs_due on public.activity_context_jobs(algorithm_version, not_before, day desc)
  where completed_revision < input_revision and not dead_letter;
create unique index activity_context_job_token on public.activity_context_jobs(lease_token)
  where lease_token is not null;
create index activity_context_user_last_claim on public.activity_context_jobs(user_id, last_claimed_at desc nulls last);

-- Per-epoch rows for joins; the snapshot embeds the compact grid. PK includes the fingerprint
-- so one publish replaces only its own fingerprint lineage and prior output stays readable.
create table public.activity_context_epochs (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  start_ts bigint not null,
  end_ts bigint not null,
  motion_label text not null check (motion_label in ('stationary','walking','running','other_movement','unknown')),
  posture text not null default 'unknown' check (posture in ('sitting','standing','lying','unknown')),
  exercise_session text not null default 'unknown' check (exercise_session in ('true','false','unknown')),
  sleep_state text not null default 'unknown' check (sleep_state in ('awake','asleep','unknown')),
  exertion_context text not null default 'unknown' check (exertion_context in ('resting_candidate','active','post_activity','mixed','unknown')),
  wear_state text not null default 'unknown' check (wear_state in ('on_wrist','off_wrist','unknown')),
  confidence real not null check (confidence >= 0 and confidence <= 1),
  observed_s integer not null check (observed_s >= 0),
  valid_s integer not null check (valid_s >= 0 and valid_s <= observed_s),
  model_version text not null,
  preprocessing_version text not null,
  ontology_version text not null,
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  result_revision bigint not null,
  computed_at timestamptz not null,
  primary key (user_id, device_id, start_ts, fingerprint),
  check (end_ts > start_ts),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index activity_context_epochs_read on public.activity_context_epochs(user_id, device_id, day, start_ts);
create sequence if not exists public.activity_context_epochs_result_revision_seq;
grant usage, select on sequence public.activity_context_epochs_result_revision_seq to service_role;

-- Worker tables are service-role only; owners get a select-only read policy mirroring the
-- derived metric-series shape. Reads for the app go through the scores edge route.
do $$ declare t text; begin
  foreach t in array array['activity_context_jobs','activity_context_epochs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy activity_context_service on public.%I for all to service_role using (true) with check (true)', t);
    execute format('create policy activity_context_select_own on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- Idempotent upsert: identical fingerprint replays are no-ops; a changed fingerprint (late
-- verified object, corrected range, version change) bumps input_revision and re-dirties the
-- day so a bounded recomputation replaces the prior output.
create function public.enqueue_activity_context(p_user uuid, p_device uuid, p_day date,
  p_object_ids uuid[], p_digests text[], p_fingerprint text,
  p_model_version text default 'hart-activity-v1',
  p_preprocessing_version text default 'hart-activity-preprocess-v1',
  p_ontology_version text default 'v1')
returns void language plpgsql security definer set search_path='' as $$
begin
  if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
  if p_object_ids is null or p_digests is null or cardinality(p_object_ids) <> cardinality(p_digests)
    or cardinality(p_object_ids) = 0 then raise exception 'invalid_activity_inputs'; end if;
  if not exists(select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'device_owner_mismatch';
  end if;
  insert into public.activity_context_jobs(user_id, device_id, day, algorithm_version,
    input_object_ids, input_digests, fingerprint, model_version, preprocessing_version,
    ontology_version, input_revision, reason)
  values(p_user, p_device, p_day, 'hart-activity-1', p_object_ids, p_digests, p_fingerprint,
    p_model_version, p_preprocessing_version, p_ontology_version, 1, 'input')
  on conflict(user_id, device_id, day, algorithm_version) do update set
    input_object_ids = excluded.input_object_ids,
    input_digests = excluded.input_digests,
    fingerprint = excluded.fingerprint,
    model_version = excluded.model_version,
    preprocessing_version = excluded.preprocessing_version,
    ontology_version = excluded.ontology_version,
    input_revision = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then activity_context_jobs.input_revision + 1 else activity_context_jobs.input_revision end,
    dirty_at = case when activity_context_jobs.fingerprint is distinct from excluded.fingerprint
      then clock_timestamp() else activity_context_jobs.dirty_at end,
    consecutive_failures = 0, dead_letter = false, not_before = clock_timestamp(),
    last_error = null, reason = 'input';
end $$;

-- FOR UPDATE SKIP LOCKED claim with token grant; the eligibility gates mirror claim_scoring_v2
-- minus the algorithm/invalidation registries (activity has none in v1).
create function public.claim_activity_context_v2(p_lease_seconds integer default 300)
returns setof public.activity_context_jobs language plpgsql security definer set search_path='' as $$
declare j public.activity_context_jobs;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  select q.* into j from public.activity_context_jobs q
  where q.completed_revision < q.input_revision and not q.dead_letter and q.not_before <= clock_timestamp()
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

create function public.renew_activity_context_v2(p_token uuid, p_seconds integer default 300)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_seconds < 1 or p_seconds > 3600 then raise exception 'invalid_lease'; end if;
  update public.activity_context_jobs set lease_until = clock_timestamp() + make_interval(secs => p_seconds),
    renewal_count = renewal_count + 1
  where lease_token = p_token and lease_until > clock_timestamp();
  return found;
end $$;

-- Bounded exponential backoff with dead-letter at 8 consecutive failures; a stale revision
-- release cleans the lease without failure accounting.
create function public.fail_activity_context_v2(p_token uuid, p_revision bigint, p_error text)
returns void language plpgsql security definer set search_path='' as $$
begin
  update public.activity_context_jobs set
    consecutive_failures = case when input_revision = p_revision then consecutive_failures + 1 else 0 end,
    dead_letter = (input_revision = p_revision and consecutive_failures + 1 >= 8),
    not_before = case when input_revision = p_revision then clock_timestamp() +
      make_interval(secs => least(3600, 5 * power(2, least(consecutive_failures, 10)))::integer)
      else clock_timestamp() end,
    last_error = case when input_revision = p_revision then left(p_error, 2000) else null end,
    lease_token = null, lease_until = null
  where lease_token = p_token and lease_until > clock_timestamp();
end $$;

-- Fenced publication: lease alive + revision current, else NULL (a stale worker cannot touch
-- epochs). Validates the C10 epoch JSON shape, replaces only this job fingerprint's rows for
-- the day, stamps a fresh result_revision, clears the lease, and re-dirties affected scoring
-- days through scoring_dirty_span in the same transaction (the publish_scoring_snapshot_v2
-- invalidation ordering pattern).
create function public.publish_activity_context_v2(p_token uuid, p_revision bigint,
  p_payload jsonb, p_duration_ms bigint)
returns bigint language plpgsql security definer set search_path='' as $$
declare j public.activity_context_jobs; e jsonb; rev bigint; computed timestamptz;
  day_lo bigint; day_hi bigint; cnt integer := 0;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;
  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'epochs') is distinct from 'array'
    or p_payload -> 'day' is null
    or (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_activity_payload';
  end if;
  day_lo := extract(epoch from (j.day::timestamp at time zone 'UTC'))::bigint;
  day_hi := extract(epoch from ((j.day + 1)::timestamp at time zone 'UTC'))::bigint - 1;
  for e in select value from jsonb_array_elements(p_payload -> 'epochs') loop
    cnt := cnt + 1;
    if cnt > 2880 then raise exception 'invalid_activity_epoch_count'; end if;
    if jsonb_typeof(e) is distinct from 'object'
      or not (e ? 's' and e ? 'e' and e ? 'm' and e ? 'p' and e ? 'ex' and e ? 'sl'
        and e ? 'ec' and e ? 'w' and e ? 'c' and e ? 'os' and e ? 'vs')
      or coalesce(e ->> 'm', '') not in ('stationary','walking','running','other_movement','unknown')
      or coalesce(e ->> 'p', '') not in ('sitting','standing','lying','unknown')
      or coalesce(e ->> 'ex', '') not in ('true','false','unknown')
      or coalesce(e ->> 'sl', '') not in ('awake','asleep','unknown')
      or coalesce(e ->> 'ec', '') not in ('resting_candidate','active','post_activity','mixed','unknown')
      or coalesce(e ->> 'w', '') not in ('on_wrist','off_wrist','unknown')
      or (e ->> 's') is null or (e ->> 'e') is null or (e ->> 'c') is null
      or (e ->> 'os') is null or (e ->> 'vs') is null
      or (e ->> 's')::bigint < day_lo or (e ->> 'e')::bigint > day_hi
      or (e ->> 'e')::bigint <= (e ->> 's')::bigint
      or (e ->> 'os')::integer < 0 or (e ->> 'vs')::integer < 0
      or (e ->> 'c')::real < 0 or (e ->> 'c')::real > 1
      or (e ->> 'vs')::integer > (e ->> 'os')::integer then
      raise exception 'invalid_activity_epoch';
    end if;
  end loop;
  computed := clock_timestamp();
  rev := nextval('public.activity_context_epochs_result_revision_seq');
  delete from public.activity_context_epochs
    where user_id = j.user_id and device_id = j.device_id and day = j.day and fingerprint = j.fingerprint;
  for e in select value from jsonb_array_elements(p_payload -> 'epochs') loop
    insert into public.activity_context_epochs(user_id, device_id, day, start_ts, end_ts,
      motion_label, posture, exercise_session, sleep_state, exertion_context, wear_state,
      confidence, observed_s, valid_s, model_version, preprocessing_version, ontology_version,
      fingerprint, result_revision, computed_at)
    values(j.user_id, j.device_id, j.day, (e ->> 's')::bigint, (e ->> 'e')::bigint,
      e ->> 'm', e ->> 'p', e ->> 'ex', e ->> 'sl', e ->> 'ec', e ->> 'w',
      (e ->> 'c')::real, (e ->> 'os')::integer, (e ->> 'vs')::integer,
      j.model_version, j.preprocessing_version, j.ontology_version,
      j.fingerprint, rev, computed);
  end loop;
  update public.activity_context_jobs set completed_revision = p_revision,
    lease_token = null, lease_until = null, consecutive_failures = 0, dead_letter = false,
    last_error = null, last_completed_at = computed, last_duration_ms = greatest(0, p_duration_ms),
    success_count = success_count + 1
  where user_id = j.user_id and device_id = j.device_id and day = j.day
    and algorithm_version = j.algorithm_version;
  -- Re-dirty scoring days touched by this day's activity; coalesced by existing invalidation
  -- machinery, never once per raw sample/window.
  perform public.scoring_dirty_span(j.user_id, j.device_id, day_lo, day_hi);
  return rev;
end $$;

-- Enqueue activity jobs when a rawImuSession object becomes ready. One function/trigger name,
-- fully separate from the existing sensor_raw_dependency_change trigger on the same table so
-- the two paths never share state. Fires on INSERT too (defensive) but only when the row is
-- already ready; both the synchronous intake path and the async verification worker flip the
-- manifest to 'ready' by UPDATE, so this covers the whole lifecycle.
create function internal.activity_raw_imu_ready() returns trigger
language plpgsql security definer set search_path='' as $$
declare d date; f text; digests text[]; ids uuid[]; lo bigint; hi bigint;
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
    -- Aggregate every ready rawImuSession object overlapping the UTC day so a late object
    -- re-enqueues the complete input set and bumps the fingerprint-driven revision exactly once.
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
    lo := extract(epoch from (d::timestamp at time zone 'UTC'))::bigint;
    hi := extract(epoch from ((d + 1)::timestamp at time zone 'UTC'))::bigint - 1;
    f := public.activity_context_fingerprint(digests, lo, hi, 'hart-activity-1',
      'hart-activity-v1', 'hart-activity-preprocess-v1', 'v1');
    perform public.enqueue_activity_context(new.user_id, new.device_id, d, ids, digests, f);
  end loop;
  return null;
end $$;
revoke all on function internal.activity_raw_imu_ready() from public, anon, authenticated, service_role;
create trigger activity_raw_imu_ready after insert or update on public.object_manifests
  for each row execute function internal.activity_raw_imu_ready();

revoke all on function public.enqueue_activity_context(uuid,uuid,date,uuid[],text[],text,text,text,text)
  from public, anon, authenticated;
revoke all on function public.claim_activity_context_v2(integer) from public, anon, authenticated;
revoke all on function public.renew_activity_context_v2(uuid,integer) from public, anon, authenticated;
revoke all on function public.fail_activity_context_v2(uuid,bigint,text) from public, anon, authenticated;
revoke all on function public.publish_activity_context_v2(uuid,bigint,jsonb,bigint) from public, anon, authenticated;
grant execute on function public.enqueue_activity_context(uuid,uuid,date,uuid[],text[],text,text,text,text)
  to service_role;
grant execute on function public.claim_activity_context_v2(integer) to service_role;
grant execute on function public.renew_activity_context_v2(uuid,integer) to service_role;
grant execute on function public.fail_activity_context_v2(uuid,bigint,text) to service_role;
grant execute on function public.publish_activity_context_v2(uuid,bigint,jsonb,bigint) to service_role;

commit;
