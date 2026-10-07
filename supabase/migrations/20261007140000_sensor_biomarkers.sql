-- Sensor biomarkers (spec-31 sections 8-9): durable job queue + day documents, per
-- docs/sensor-biomarkers/CONTRACTS.md sections 1/5. Additive only; NEVER applied to
-- production by this task. Mirrors the activity_context lease/fence pattern
-- (20261003120000_activity_context.sql / 20261003130000_activity_context_days.sql):
-- a fenced claim/publish pair, a deterministic PK so retries upsert instead of
-- duplicating, and a bounded periodic reconcile scan that maps newly verified
-- rawImuSession + ppgWaveformSample objects into affected (owner, device, UTC day)
-- jobs. A day document replaces only its own (user_id, device_id, day, analysis_version)
-- row; a stale worker can never overwrite a newer result.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- The v1 family set. Family keys are stable (CONTRACTS.md section 2); new families arrive
-- with a schema revision, not by widening this check.
create function internal.sensor_biomarker_family_set() returns text[] language sql immutable
set search_path='' as $$
  select array['movement','oscillation','ppg_quality','pulse_shape',
               'perfusion_research','tremor','arm_swing','rhythm_shadow']::text[]
$$;
revoke all on function internal.sensor_biomarker_family_set() from public, anon, authenticated, service_role;

-- Deterministic input fingerprint: sorted content digests, then UTC range, then the analysis
-- version. The lane must call this same function (or replicate the canonical form exactly) so a
-- late verified object or an analysis-version change produces a distinct fingerprint and a
-- bounded recomputation via input_revision bump. Family set changes are handled by the enqueue
-- (families are part of the job row), not by the fingerprint.
create function public.sensor_biomarkers_fingerprint(p_digests text[], p_start bigint, p_end bigint,
  p_analysis text)
returns text language sql immutable set search_path='' as $$
  select encode(extensions.digest(convert_to(
    'sensor-biomarkers-input-v1' || E'\n' ||
    coalesce(array_to_string(array_agg(lower(x) order by x), E'\n'), '') || E'\n' ||
    p_start::text || E'\n' || p_end::text || E'\n' ||
    coalesce(p_analysis, ''), 'UTF8'), 'sha256'), 'hex')
  from unnest(p_digests) as d(x)
$$;
revoke all on function public.sensor_biomarkers_fingerprint(text[],bigint,bigint,text)
  from public, anon, authenticated;
grant execute on function public.sensor_biomarkers_fingerprint(text[],bigint,bigint,text)
  to service_role;

-- One job per (owner, device, UTC day, analysis version). Deterministic PK makes retries upsert
-- instead of duplicating; the fingerprint change drives input_revision, the lease/fence pair
-- follows the activity_context durability contract exactly. `enabled_families` is the worker's
-- current family set: a change to it (a flag toggled in the lane) is a dirty event that bumps
-- input_revision and recomputes the day, so enabling a family never needs an object change.
create table public.sensor_biomarker_jobs (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  analysis_version text not null default 'sensor-biomarkers/1.0.0'
    check (analysis_version ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$'),
  input_object_ids uuid[] not null default '{}'::uuid[],
  input_digests text[] not null default '{}'::text[],
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  enabled_families text[] not null default '{}'::text[]
    check (enabled_families <@ internal.sensor_biomarker_family_set()),
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
  primary key (user_id, device_id, day, analysis_version),
  check ((lease_token is null) = (lease_until is null)),
  check (completed_revision <= input_revision),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index sensor_biomarker_jobs_due on public.sensor_biomarker_jobs(analysis_version, not_before, day desc)
  where completed_revision < input_revision and not dead_letter;
create unique index sensor_biomarker_job_token on public.sensor_biomarker_jobs(lease_token)
  where lease_token is not null;
create index sensor_biomarker_user_last_claim on public.sensor_biomarker_jobs(user_id, last_claimed_at desc nulls last);

-- One decoded, versioned document per (owner, device, UTC day, analysis version), written by the
-- lane next to the queue. `document` is the source of truth (CONTRACTS.md section 3); the scalar
-- columns repeat what readers filter on. A republish replaces the row, so readers never merge
-- versions. Payload budget: <= 256 KiB per day document.
create table public.sensor_biomarker_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  analysis_version text not null check (analysis_version ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$'),
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision text not null check (input_revision ~ '^sha256:[0-9a-f]{64}$'),
  interval_start_utc timestamptz not null,
  interval_end_utc timestamptz not null,
  status text not null check (status in ('provisional','completed')),
  document jsonb not null check (jsonb_typeof(document) = 'object'
    and octet_length(document::text) <= 262144),
  families_ok text[] not null default '{}'::text[]
    check (families_ok <@ internal.sensor_biomarker_family_set()),
  withheld_reasons text[] not null default '{}'::text[],
  run_ms bigint check (run_ms is null or run_ms >= 0),
  model_revisions jsonb,
  published_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  primary key (user_id, device_id, day, analysis_version),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (interval_end_utc > interval_start_utc),
  check (interval_start_utc >= (day::timestamp at time zone 'UTC')
    and interval_end_utc <= ((day + 1)::timestamp at time zone 'UTC'))
);

-- Worker tables are service-role only; owners get a select-only read policy mirroring the
-- activity_context shape. Reads for the app go through the scores edge route.
do $$ declare t text; begin
  foreach t in array array['sensor_biomarker_jobs','sensor_biomarker_days'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy sensor_biomarkers_service on public.%I for all to service_role using (true) with check (true)', t);
    execute format('create policy sensor_biomarkers_select_own on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- Idempotent upsert with lossless merge: a changed fingerprint (late verified object, corrected
-- range, analysis-version change) or a changed enabled_families (a flag toggled in the lane)
-- bumps input_revision and re-dirties the day so a bounded recomputation replaces the prior
-- output; an unchanged fingerprint + unchanged families replays as a no-op. Ready-flips that race
-- under READ COMMITTED can enqueue a per-object subset after the job already exists: the conflict
-- branch MERGES the new ids/digests into the existing arrays (sorted, deduplicated) so no
-- object's contribution is ever overwritten. Failure state (dead_letter, consecutive_failures,
-- not_before backoff) is sticky across a same-input enqueue and only resets when the fingerprint
-- or family set actually changes, so a dead-lettered or backed-off job cannot be resurrected by
-- an identical replay. Skip/not-ready optional providers are explicit withheld results in the
-- document, never endless retries here.
create function public.enqueue_sensor_biomarker_day(p_user uuid, p_device uuid, p_day date,
  p_object_ids uuid[], p_digests text[], p_fingerprint text,
  p_enabled_families text[] default '{}'::text[])
returns void language plpgsql security definer set search_path='' as $$
declare v_families text[];
begin
  if p_fingerprint is null or p_fingerprint !~ '^[0-9a-f]{64}$' then raise exception 'invalid_fingerprint'; end if;
  if p_object_ids is null or p_digests is null or cardinality(p_object_ids) <> cardinality(p_digests)
    or cardinality(p_object_ids) = 0 then raise exception 'invalid_sensor_biomarker_inputs'; end if;
  if p_enabled_families is not null and exists(
      select 1 from unnest(p_enabled_families) as t(x)
      where t.x is null or t.x = '' or not (t.x = any(internal.sensor_biomarker_family_set()))) then
    raise exception 'invalid_enabled_families';
  end if;
  if not exists(select 1 from public.devices where id = p_device and user_id = p_user) then
    raise exception 'device_owner_mismatch';
  end if;
  v_families := (select coalesce(array_agg(distinct x order by x), '{}'::text[])
    from unnest(coalesce(p_enabled_families, '{}'::text[])) as t(x));
  insert into public.sensor_biomarker_jobs(user_id, device_id, day, analysis_version,
    input_object_ids, input_digests, fingerprint, enabled_families, input_revision, reason)
  values(p_user, p_device, p_day, 'sensor-biomarkers/1.0.0', p_object_ids, p_digests, p_fingerprint,
    v_families, 1, 'input')
  on conflict(user_id, device_id, day, analysis_version) do update set
    input_object_ids = (select coalesce(array_agg(distinct x order by x), '{}'::uuid[])
      from unnest(sensor_biomarker_jobs.input_object_ids || excluded.input_object_ids) as t(x)),
    input_digests = (select coalesce(array_agg(distinct x order by x), '{}'::text[])
      from unnest(sensor_biomarker_jobs.input_digests || excluded.input_digests) as t(x)),
    fingerprint = excluded.fingerprint,
    enabled_families = excluded.enabled_families,
    input_revision = case when sensor_biomarker_jobs.fingerprint is distinct from excluded.fingerprint
      or sensor_biomarker_jobs.enabled_families is distinct from excluded.enabled_families
      then sensor_biomarker_jobs.input_revision + 1 else sensor_biomarker_jobs.input_revision end,
    dirty_at = case when sensor_biomarker_jobs.fingerprint is distinct from excluded.fingerprint
      or sensor_biomarker_jobs.enabled_families is distinct from excluded.enabled_families
      then clock_timestamp() else sensor_biomarker_jobs.dirty_at end,
    consecutive_failures = case when sensor_biomarker_jobs.fingerprint is distinct from excluded.fingerprint
      or sensor_biomarker_jobs.enabled_families is distinct from excluded.enabled_families
      then 0 else sensor_biomarker_jobs.consecutive_failures end,
    dead_letter = case when sensor_biomarker_jobs.fingerprint is distinct from excluded.fingerprint
      or sensor_biomarker_jobs.enabled_families is distinct from excluded.enabled_families
      then false else sensor_biomarker_jobs.dead_letter end,
    not_before = case when sensor_biomarker_jobs.fingerprint is distinct from excluded.fingerprint
      or sensor_biomarker_jobs.enabled_families is distinct from excluded.enabled_families
      then clock_timestamp() else sensor_biomarker_jobs.not_before end,
    last_error = case when sensor_biomarker_jobs.fingerprint is distinct from excluded.fingerprint
      or sensor_biomarker_jobs.enabled_families is distinct from excluded.enabled_families
      then null else sensor_biomarker_jobs.last_error end,
    reason = 'input';
end $$;

-- FOR UPDATE SKIP LOCKED claim with token grant; the eligibility gates mirror
-- claim_activity_context_v2.
create function public.claim_sensor_biomarker_day(p_lease_seconds integer default 300)
returns setof public.sensor_biomarker_jobs language plpgsql security definer set search_path='' as $$
declare j public.sensor_biomarker_jobs;
begin
  if p_lease_seconds < 1 or p_lease_seconds > 3600 then raise exception 'invalid_lease'; end if;
  select q.* into j from public.sensor_biomarker_jobs q
  where q.completed_revision < q.input_revision and not q.dead_letter and q.not_before <= clock_timestamp()
    and (q.lease_until is null or q.lease_until <= clock_timestamp())
  order by coalesce((select max(s.last_claimed_at) from public.sensor_biomarker_jobs s where s.user_id = q.user_id),
                    '-infinity'::timestamptz),
           (q.dirty_at < clock_timestamp() - interval '1 hour') desc,
           case when q.dirty_at < clock_timestamp() - interval '1 hour' then q.dirty_at end,
           q.day desc, q.dirty_at, q.device_id
  for update of q skip locked limit 1;
  if not found then return; end if;
  return query update public.sensor_biomarker_jobs q set lease_token = gen_random_uuid(),
    lease_until = clock_timestamp() + make_interval(secs => p_lease_seconds),
    last_claimed_at = clock_timestamp(), claim_count = q.claim_count + 1,
    lease_expiry_count = q.lease_expiry_count + case when q.lease_token is null then 0 else 1 end
  where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day
    and q.analysis_version = j.analysis_version
  returning q.*;
end $$;

create function public.renew_sensor_biomarker_day(p_token uuid, p_seconds integer default 300)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  if p_seconds < 1 or p_seconds > 3600 then raise exception 'invalid_lease'; end if;
  update public.sensor_biomarker_jobs set lease_until = clock_timestamp() + make_interval(secs => p_seconds),
    renewal_count = renewal_count + 1
  where lease_token = p_token and lease_until > clock_timestamp();
  return found;
end $$;

-- Bounded exponential backoff with dead-letter at 8 consecutive failures; a stale revision
-- release cleans the lease without failure accounting (a superseded worker is never punished).
create function public.fail_sensor_biomarker_day(p_token uuid, p_revision bigint, p_error text)
returns void language plpgsql security definer set search_path='' as $$
begin
  update public.sensor_biomarker_jobs set
    consecutive_failures = case when input_revision = p_revision then consecutive_failures + 1 else 0 end,
    dead_letter = (input_revision = p_revision and consecutive_failures + 1 >= 8),
    not_before = case when input_revision = p_revision then clock_timestamp() +
      make_interval(secs => least(3600, 5 * power(2, least(consecutive_failures, 10)))::integer)
      else clock_timestamp() end,
    last_error = case when input_revision = p_revision then left(p_error, 2000) else null end,
    lease_token = null, lease_until = null
  where lease_token = p_token and lease_until > clock_timestamp();
end $$;

-- Fenced publication of one day document. Same fence as publish_activity_context_v2: the lease
-- must be alive and the revision current, otherwise NULL and nothing is written (a stale worker
-- can never overwrite a newer result). Validates the CONTRACTS.md section 3 document before
-- writing: day/version stamps, family keys and statuses, the 256 KiB budget, and UTC interval
-- bounds. Completes the job (clears the lease, resets failures, records duration) in the same
-- transaction.
-- Payload: {"day": "YYYY-MM-DD", "status": "provisional|completed", "run_ms": int,
--           "model_revisions": {family: revision}?,
--           "document": <SensorBiomarkerDayDocument JSON>}
create function public.publish_sensor_biomarker_day(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path='' as $$
declare j public.sensor_biomarker_jobs; d jsonb; fam jsonb; fam_key text;
  day_lo timestamptz; day_hi timestamptz; lo_ts timestamptz; hi_ts timestamptz;
  computed timestamptz; n_fam integer;
  status_value text; run_ms_value bigint; model_revs jsonb;
  families_ok text[] := '{}'::text[]; withheld text[] := '{}'::text[];
begin
  select * into j from public.sensor_biomarker_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'document') is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_sensor_biomarker_payload';
  end if;
  if (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_sensor_biomarker_payload';
  end if;
  status_value := coalesce(nullif(p_payload ->> 'status', ''), 'completed');
  if status_value not in ('provisional','completed') then raise exception 'invalid_sensor_biomarker_status'; end if;
  if coalesce(jsonb_typeof(p_payload -> 'run_ms'), 'null') not in ('number','null')
    or ((p_payload -> 'run_ms') is not null and (p_payload ->> 'run_ms')::bigint < 0) then
    raise exception 'invalid_sensor_biomarker_run_ms';
  end if;
  run_ms_value := case when jsonb_typeof(p_payload -> 'run_ms') = 'number'
    then (p_payload ->> 'run_ms')::bigint else null end;
  if coalesce(jsonb_typeof(p_payload -> 'model_revisions'), 'null') not in ('object','null') then
    raise exception 'invalid_sensor_biomarker_model_revisions';
  end if;

  d := p_payload -> 'document';
  if octet_length(d::text) > 262144 then raise exception 'invalid_sensor_biomarker_size'; end if;
  if jsonb_typeof(d -> 'schema_version') is distinct from 'number'
    or (d ->> 'schema_version')::int < 1
    or jsonb_typeof(d -> 'analysis_version') is distinct from 'string'
    or (d ->> 'analysis_version') !~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$'
    or (d ->> 'analysis_version') is distinct from j.analysis_version
    or jsonb_typeof(d -> 'input_revision') is distinct from 'string'
    or (d ->> 'input_revision') !~ '^sha256:[0-9a-f]{64}$'
    or jsonb_typeof(d -> 'families') is distinct from 'object'
    or jsonb_typeof(d -> 'interval_start_utc') is distinct from 'string'
    or (d ->> 'interval_start_utc') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
    or jsonb_typeof(d -> 'interval_end_utc') is distinct from 'string'
    or (d ->> 'interval_end_utc') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'
    or coalesce(jsonb_typeof(d -> 'processed_at_utc'), 'null') not in ('string','null')
    or (d -> 'processed_at_utc') is not null
      and (d ->> 'processed_at_utc') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$' then
    raise exception 'invalid_sensor_biomarker_document';
  end if;
  day_lo := j.day::timestamp at time zone 'UTC';
  day_hi := (j.day + 1)::timestamp at time zone 'UTC';
  lo_ts := (d ->> 'interval_start_utc')::timestamptz;
  hi_ts := (d ->> 'interval_end_utc')::timestamptz;
  if lo_ts < day_lo or hi_ts > day_hi or hi_ts <= lo_ts then
    raise exception 'invalid_sensor_biomarker_interval';
  end if;

  n_fam := (select count(*)::int from jsonb_object_keys(d -> 'families'));
  if n_fam = 0 then raise exception 'invalid_sensor_biomarker_families'; end if;
  -- Validate every family stage: known family key, whitelisted status/tier, plain provider
  -- revision, object measurement/reason shapes, non-negative numeric coverage.
  for fam_key in select jsonb_object_keys(d -> 'families') loop
    if not (fam_key = any(internal.sensor_biomarker_family_set())) then
      raise exception 'invalid_sensor_biomarker_family';
    end if;
    fam := d -> 'families' -> fam_key;
    if jsonb_typeof(fam) is distinct from 'object'
      or jsonb_typeof(fam -> 'status') is distinct from 'string'
      or coalesce(fam ->> 'status', '') not in ('ok','withheld','error')
      or jsonb_typeof(fam -> 'release_tier') is distinct from 'string'
      or coalesce(fam ->> 'release_tier', '') not in ('descriptive','research','shadow')
      or jsonb_typeof(fam -> 'provider_revision') is distinct from 'string'
      or (fam ->> 'provider_revision') !~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,95}$'
      or jsonb_typeof(fam -> 'measurements') is distinct from 'object'
      or coalesce(jsonb_typeof(fam -> 'reason_counts'), 'null') not in ('object','null')
      or coalesce(jsonb_typeof(fam -> 'reason'), 'null') not in ('string','null')
      or coalesce(jsonb_typeof(fam -> 'contact_state'), 'null') not in ('string','null')
      or coalesce(jsonb_typeof(fam -> 'observed_seconds'), 'null') not in ('number','null')
      or (fam -> 'observed_seconds') is not null and (fam ->> 'observed_seconds')::double precision < 0
      or coalesce(jsonb_typeof(fam -> 'eligible_seconds'), 'null') not in ('number','null')
      or (fam -> 'eligible_seconds') is not null and (fam ->> 'eligible_seconds')::double precision < 0 then
      raise exception 'invalid_sensor_biomarker_family';
    end if;
    if (fam ->> 'status') = 'ok' then
      families_ok := array_append(families_ok, fam_key);
    else
      if coalesce(fam ->> 'reason', '') <> '' then
        withheld := array_append(withheld, fam ->> 'reason');
      else
        withheld := array_append(withheld, fam ->> 'status');
      end if;
    end if;
  end loop;
  families_ok := (select coalesce(array_agg(x order by x), '{}'::text[]) from unnest(families_ok) as t(x));
  withheld := (select coalesce(array_agg(distinct x order by x), '{}'::text[]) from unnest(withheld) as t(x));

  -- model_revisions: the payload's own map when present, otherwise the per-family
  -- provider_revision values (the versions the LANE resolved).
  if jsonb_typeof(p_payload -> 'model_revisions') = 'object' then
    model_revs := p_payload -> 'model_revisions';
  else
    model_revs := (select jsonb_object_agg(fk, d -> 'families' -> fk -> 'provider_revision')
      from jsonb_array_elements_text(to_jsonb(families_ok)) as t(fk));
  end if;

  computed := clock_timestamp();
  insert into public.sensor_biomarker_days(user_id, device_id, day, analysis_version, job_fingerprint,
    input_revision, interval_start_utc, interval_end_utc, status, document, families_ok,
    withheld_reasons, run_ms, model_revisions, published_at, updated_at)
  values(j.user_id, j.device_id, j.day, j.analysis_version, j.fingerprint, d ->> 'input_revision',
    lo_ts, hi_ts, status_value, d, families_ok, withheld, run_ms_value, model_revs, computed, computed)
  on conflict (user_id, device_id, day, analysis_version) do update set
    job_fingerprint = excluded.job_fingerprint, input_revision = excluded.input_revision,
    interval_start_utc = excluded.interval_start_utc, interval_end_utc = excluded.interval_end_utc,
    status = excluded.status, document = excluded.document, families_ok = excluded.families_ok,
    withheld_reasons = excluded.withheld_reasons, run_ms = excluded.run_ms,
    model_revisions = excluded.model_revisions, published_at = excluded.published_at,
    updated_at = excluded.updated_at;
  update public.sensor_biomarker_jobs set completed_revision = p_revision,
    lease_token = null, lease_until = null, consecutive_failures = 0, dead_letter = false,
    last_error = null, last_completed_at = computed, last_duration_ms = greatest(0, coalesce(run_ms_value, 0)),
    success_count = success_count + 1
  where user_id = j.user_id and device_id = j.device_id and day = j.day
    and analysis_version = j.analysis_version;
  return 1;
end $$;

-- Bounded reconcile path (CONTRACTS.md section 5): the sensor-biomarker lane calls this each
-- cycle. Scans rawImuSession + ppgWaveformSample objects that are ready (verified receipt,
-- sha256 present) with an end newer than the lookback, and for every UTC day they cover
-- re-aggregates the complete ready input set exactly like the enqueue contract, then re-enqueues
-- idempotently. Safe to run repeatedly: an already-current job is a no-op (same fingerprint and
-- family set, no revision bump), a job whose object was missed by a racing reconcile is repaired
-- by the enqueue merge, and no day documents are ever written here. `p_enabled_families` is the
-- worker's current family set; a toggled flag shows up here as a family-set change and recomputes
-- the day.
create function public.reconcile_sensor_biomarkers(p_lookback interval default '7 days',
  p_enabled_families text[] default '{}'::text[])
returns void language plpgsql security definer set search_path='' as $$
declare r record; d date; lo bigint; hi bigint; f text; ids uuid[]; digests text[];
  families text[];
begin
  if p_lookback is null or p_lookback < interval '0' then raise exception 'invalid_lookback'; end if;
  if p_enabled_families is not null and exists(
      select 1 from unnest(p_enabled_families) as t(x)
      where t.x is null or t.x = '' or not (t.x = any(internal.sensor_biomarker_family_set()))) then
    raise exception 'invalid_enabled_families';
  end if;
  families := (select coalesce(array_agg(distinct x order by x), '{}'::text[])
    from unnest(coalesce(p_enabled_families, '{}'::text[])) as t(x));
  for r in
    select distinct m.user_id, m.device_id,
      greatest((m.start_at at time zone 'UTC')::date, (clock_timestamp() - p_lookback)::date) as first_day,
      (m.end_at at time zone 'UTC')::date as last_day
    from public.object_manifests m
    where m.object_kind in ('rawImuSession','ppgWaveformSample') and m.status = 'ready'
      and m.verified_at is not null and m.sha256 is not null
      and m.start_at is not null and m.end_at is not null
      and m.end_at > clock_timestamp() - p_lookback
      and (m.end_at - m.start_at) <= interval '8 days'
  loop
    for d in select generate_series(r.first_day, r.last_day, interval '1 day')::date loop
      -- Same aggregation the lane's own enqueue uses so fingerprints converge: every ready
      -- object of BOTH modalities overlapping the UTC day, digest-sorted.
      select array_agg(x.id order by x.start_at, x.id),
             array_agg(lower(x.sha256) order by x.start_at, x.id)
        into ids, digests
      from public.object_manifests x
      where x.user_id = r.user_id and x.device_id = r.device_id
        and x.object_kind in ('rawImuSession','ppgWaveformSample') and x.status = 'ready'
        and x.sha256 is not null and x.start_at is not null and x.end_at is not null
        and x.start_at < ((d + 1)::timestamp at time zone 'UTC')
        and x.end_at > (d::timestamp at time zone 'UTC')
        and (x.end_at - x.start_at) <= interval '8 days';
      if ids is null or cardinality(ids) = 0 then continue; end if;
      lo := extract(epoch from (d::timestamp at time zone 'UTC'))::bigint;
      hi := extract(epoch from ((d + 1)::timestamp at time zone 'UTC'))::bigint - 1;
      f := public.sensor_biomarkers_fingerprint(digests, lo, hi, 'sensor-biomarkers/1.0.0');
      perform public.enqueue_sensor_biomarker_day(r.user_id, r.device_id, d, ids, digests, f, families);
    end loop;
  end loop;
end $$;

revoke all on function public.enqueue_sensor_biomarker_day(uuid,uuid,date,uuid[],text[],text,text[])
  from public, anon, authenticated;
revoke all on function public.claim_sensor_biomarker_day(integer) from public, anon, authenticated;
revoke all on function public.renew_sensor_biomarker_day(uuid,integer) from public, anon, authenticated;
revoke all on function public.fail_sensor_biomarker_day(uuid,bigint,text) from public, anon, authenticated;
revoke all on function public.publish_sensor_biomarker_day(uuid,bigint,jsonb) from public, anon, authenticated;
revoke all on function public.reconcile_sensor_biomarkers(interval,text[]) from public, anon, authenticated;
grant execute on function public.enqueue_sensor_biomarker_day(uuid,uuid,date,uuid[],text[],text,text[])
  to service_role;
grant execute on function public.claim_sensor_biomarker_day(integer) to service_role;
grant execute on function public.renew_sensor_biomarker_day(uuid,integer) to service_role;
grant execute on function public.fail_sensor_biomarker_day(uuid,bigint,text) to service_role;
grant execute on function public.publish_sensor_biomarker_day(uuid,bigint,jsonb) to service_role;
grant execute on function public.reconcile_sensor_biomarkers(interval,text[]) to service_role;

commit;
