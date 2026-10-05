-- Physiology context: the persistence, queue and read surface for the context layer
-- (docs/physiology-context/contracts.md §6, §7, §8, §10). Additive only: new tables, new functions,
-- one new trigger on placement_intervals. No existing table, function, grant or row is changed, nothing
-- here writes to a scoring, series, noop_* or sessions table, and nothing here calls scoring_dirty_span,
-- so a context failure can never block scoring, uploads or BLE.
--
-- Tables (all owner-cascading; device-scoped ones carry the composite FK to devices(user_id, id)):
--   physiology_context_jobs               queue, one row per (user, device, local day, mode)
--   physiology_context_days               one immutable row per published revision (header + summary document)
--   physiology_context_envelope_tables    the revision's interned envelopes, one EnvelopeTable per metric
--   physiology_context_daily_values       current daily values per (user, device, mode, day, series, regime)
--   physiology_context_bouts              current exertion bouts per (user, device, mode, bout)
--   physiology_context_episodes           current change episodes per (user, device, mode, episode)
--   physiology_context_frozen_references  insert-only historical references (UPDATE is rejected)
--   exposure_event_revisions              immutable exposure history (UPDATE is rejected)
--   exposure_events                       current state per (owner, event)
--
-- Days are the owner's LOCAL days in profiles.timezone (the same days scoring_jobs_v2 uses); an unknown or
-- invalid zone is UTC. Mode 'causal_live' is the owner's local today, 'retrospective' every earlier day.
--
-- Privileges: RLS on every table; clients (authenticated) may only SELECT their own rows of the product and
-- exposure tables, nothing on the queue; anon nothing. Every function is SECURITY DEFINER with an empty
-- search_path and EXECUTE revoked from public, anon and authenticated (Supabase's default privileges grant
-- EXECUTE on new functions, so the revokes are load-bearing); the public RPCs are granted to service_role
-- only. Helpers and trigger functions live in `internal`.
--
-- Deletion: deleting the auth user (or a device) removes every row through the foreign keys. The
-- immutability triggers block UPDATE only, never DELETE, and no foreign key here is ON DELETE SET NULL on
-- an immutable table, so the account cascade is never blocked.
--
-- Safe to re-run (if not exists / create or replace / drop ... if exists). Rollback: drop the trigger
-- physiology_context_placement_changed on placement_intervals, then the functions and tables below; nothing
-- else depends on them.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- ---------------------------------------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------------------------------------

-- The queue. Same lease/fence shape as scoring_jobs_v2 and activity_context_jobs: a change to the inputs
-- bumps input_revision; a worker holds a lease token and may only publish while the lease is live and its
-- revision is still the current input_revision.
create table if not exists public.physiology_context_jobs (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  day date not null,
  mode text not null check (mode in ('causal_live', 'retrospective')),
  input_revision bigint not null default 1 check (input_revision >= 1),
  completed_revision bigint not null default 0 check (completed_revision >= 0),
  lease_token uuid,
  lease_until timestamptz,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  dead_letter boolean not null default false,
  not_before timestamptz not null default clock_timestamp(),
  dirty_at timestamptz not null default clock_timestamp(),
  -- Dependency fingerprint (internal.physiology_context_dependency_fingerprint): set by the enqueue and
  -- re-stamped at every claim, so a change after the worker read its inputs is detected afterwards.
  fingerprint text check (fingerprint is null or fingerprint ~ '^[0-9a-f]{64}$'),
  -- Why the job is due (distinct, sorted, at most 16): scoring_completed, inputs_changed, finality_due,
  -- exposure_changed, placement_changed, history_changed, or an operator's own code. Cleared on completion.
  reasons text[] not null default '{}'::text[],
  -- Replay: when set, the worker uses this availability cutoff instead of the claim time. Cleared on a
  -- successful publish.
  cutoff_override bigint,
  last_claimed_at timestamptz,
  last_completed_at timestamptz,
  last_duration_ms bigint,
  last_error text,
  last_worker text,
  last_outcome text,
  last_context_revision bigint,
  claim_count bigint not null default 0,
  success_count bigint not null default 0,
  unchanged_count bigint not null default 0,
  renewal_count bigint not null default 0,
  lease_expiry_count bigint not null default 0,
  primary key (user_id, device_id, day, mode),
  check ((lease_token is null) = (lease_until is null)),
  check (completed_revision <= input_revision),
  check (cardinality(reasons) <= 16),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index if not exists physiology_context_jobs_due
  on public.physiology_context_jobs (not_before)
  where completed_revision < input_revision and not dead_letter;
create unique index if not exists physiology_context_jobs_token
  on public.physiology_context_jobs (lease_token) where lease_token is not null;
create index if not exists physiology_context_jobs_user_last_claim
  on public.physiology_context_jobs (user_id, last_claimed_at desc nulls last);

create table if not exists public.physiology_context_days (
  -- Identity with a fixed sequence name: the publish allocates the new revision (nextval) before it marks
  -- the previous row superseded, because the partial unique index allows one current row per key.
  context_revision bigint generated by default as identity
    (sequence name public.physiology_context_revision_seq) primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  day date not null,
  mode text not null check (mode in ('causal_live', 'retrospective')),
  job_revision bigint not null check (job_revision >= 1),
  finality text not null check (finality in ('provisional', 'final')),
  status text not null check (status in ('available', 'partial', 'no_data', 'unavailable')),
  availability_cutoff bigint not null,
  generated_at bigint not null,
  contract_version text not null check (contract_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  schema_version integer not null check (schema_version between 1 and 1000),
  policy_fingerprint text not null check (policy_fingerprint ~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$'),
  input_fingerprint text not null check (input_fingerprint ~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$'),
  versions jsonb not null default '{}'::jsonb check (jsonb_typeof(versions) = 'object'),
  -- The scoring snapshot this document was built against (scoring_snapshots_v2.result_revision /
  -- input_revision). The only columns a later identical publish may raise (see publish).
  scoring_result_revision bigint,
  scoring_input_revision bigint,
  -- The SUMMARY document of StoredDocument.split (contracts.md §6.1): envelopes empty, envelope_index listing the
  -- tables in physiology_context_envelope_tables. A plain document (no index) is accepted too.
  document jsonb not null check (jsonb_typeof(document) = 'object'),
  document_bytes integer not null check (document_bytes between 2 and 16777216),
  envelope_count integer not null default 0 check (envelope_count >= 0),
  published_at timestamptz not null default clock_timestamp(),
  superseded_by bigint,
  superseded_at timestamptz,
  check ((superseded_by is null) = (superseded_at is null)),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create unique index if not exists physiology_context_days_current
  on public.physiology_context_days (user_id, device_id, day, mode) where superseded_by is null;
create unique index if not exists physiology_context_days_fingerprints
  on public.physiology_context_days (user_id, device_id, day, mode, policy_fingerprint, input_fingerprint);
create index if not exists physiology_context_days_device_mode_day
  on public.physiology_context_days (user_id, device_id, mode, day);

-- One interned EnvelopeTable (PCStoredDocument.swift, wire pc-wire-1) per metric of a published revision. Written in
-- the same transaction as its day row and removed with it (cascade), so a document and its tables always match.
-- A metric page reads the summary plus one row.
create table if not exists public.physiology_context_envelope_tables (
  context_revision bigint not null references public.physiology_context_days(context_revision) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  metric text not null check (metric ~ '^[a-z][a-z0-9_]{0,47}$'),
  envelope_count integer not null check (envelope_count >= 0),
  table_bytes integer not null check (table_bytes between 2 and 16777216),
  envelope_table jsonb not null check (jsonb_typeof(envelope_table) = 'object'),
  primary key (context_revision, metric),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index if not exists physiology_context_envelope_tables_owner
  on public.physiology_context_envelope_tables (user_id, device_id);

-- The documents and tables are large, repetitive JSON: compress them with lz4 where the server supports it
-- (PostgreSQL 14+ built with lz4, as Supabase's image is); pglz otherwise.
do $$
begin
  if exists (select 1 from pg_settings where name = 'default_toast_compression' and 'lz4' = any (enumvals)) then
    alter table public.physiology_context_days alter column document set compression lz4;
    alter table public.physiology_context_envelope_tables alter column envelope_table set compression lz4;
  end if;
end $$;

-- The history source for references: one value per (day, series, regime, mode), replaced for
-- (user, device, mode, day) on every publish. payload is the DailyValue exactly as the worker encoded it.
create table if not exists public.physiology_context_daily_values (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  mode text not null check (mode in ('causal_live', 'retrospective')),
  day date not null,
  series_key text not null check (char_length(series_key) between 1 and 160),
  regime_key text not null check (char_length(regime_key) between 1 and 160),
  metric text,
  value double precision not null,
  units text not null,
  support_count integer not null check (support_count >= 0),
  support_unit text not null,
  support_s bigint not null check (support_s >= 0),
  finality text not null check (finality in ('provisional', 'final')),
  context_revision bigint not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  primary key (user_id, device_id, mode, day, series_key, regime_key),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index if not exists physiology_context_daily_values_series
  on public.physiology_context_daily_values (user_id, device_id, mode, series_key, day);

-- Exertion bouts, replaced for (user, device, mode, day) on publish. A bout belongs to the local day
-- containing its start; its id is deterministic, so a re-run never duplicates it.
create table if not exists public.physiology_context_bouts (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  mode text not null check (mode in ('causal_live', 'retrospective')),
  bout_id text not null check (char_length(bout_id) between 1 and 160),
  day date not null,
  start_ts bigint not null,
  end_ts bigint not null,
  kind text not null,
  status text not null,
  duration_s bigint not null check (duration_s >= 0),
  context_revision bigint not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  primary key (user_id, device_id, mode, bout_id),
  check (end_ts > start_ts),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index if not exists physiology_context_bouts_day
  on public.physiology_context_bouts (user_id, device_id, mode, day);
create index if not exists physiology_context_bouts_start
  on public.physiology_context_bouts (user_id, device_id, mode, start_ts);

-- Change episodes. The (user, device, mode) set is replaced only by a publish whose day is on or after the
-- latest day already published for that key, so an older day's view never overwrites a newer one.
create table if not exists public.physiology_context_episodes (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  mode text not null check (mode in ('causal_live', 'retrospective')),
  episode_id text not null check (char_length(episode_id) between 1 and 160),
  series_key text not null,
  regime_key text not null,
  state text not null check (state in ('usual_variation', 'transient_deviation', 'recurring_episode',
    'persistent_shift', 'insufficient_evidence')),
  direction smallint not null check (direction between -1 and 1),
  start_day date not null,
  last_day date not null,
  ongoing boolean not null,
  duration_days integer not null check (duration_days >= 0),
  finality text not null check (finality in ('provisional', 'final')),
  as_of_day date not null,
  context_revision bigint not null,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  primary key (user_id, device_id, mode, episode_id),
  check (last_day >= start_day),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create index if not exists physiology_context_episodes_last_day
  on public.physiology_context_episodes (user_id, device_id, mode, last_day);

-- Frozen references: explicitly versioned, insert-only (on conflict do nothing), never replaced.
create table if not exists public.physiology_context_frozen_references (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  reference_id text not null check (char_length(reference_id) between 1 and 160),
  series_key text not null,
  regime_key text not null,
  version integer not null check (version >= 1),
  from_day date not null,
  to_day date not null,
  support_days integer not null check (support_days >= 0),
  center double precision not null,
  scale double precision not null,
  transform text not null,
  selection_rule text not null,
  created_for_day date not null,
  policy_fingerprint text not null,
  context_revision bigint not null,
  registered_at timestamptz not null default clock_timestamp(),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  primary key (user_id, device_id, reference_id),
  unique (user_id, device_id, series_key, regime_key, version),
  check (to_day >= from_day),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);

-- Exposure events (spec §11): account-level, so `owner` (the newest convention) and no device.
-- Occurrence ([occurred_start, occurred_end) unix seconds) and availability (received_at, set by the
-- server) are distinct; recorded_at is the client's entry time.
create table if not exists public.exposure_event_revisions (
  owner uuid not null references auth.users(id) on delete cascade,
  event_id text not null check (event_id ~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$'),
  revision integer not null check (revision >= 1),
  kind text not null check (kind in ('medication', 'supplement', 'caffeine', 'alcohol', 'meal', 'heat',
    'travel', 'symptom', 'other')),
  label text not null check (char_length(label) between 1 and 200),
  occurred_start bigint not null check (occurred_start >= 946684800),
  occurred_end bigint not null check (occurred_end <= 4102444800),
  time_precision text not null check (time_precision in ('exact', 'approximate', 'day_only')),
  recorded_at bigint not null check (recorded_at between 946684800 and 4102444800),
  received_at bigint not null,
  source text not null check (source in ('user_entered', 'journal_day_answer', 'imported', 'inferred_candidate')),
  confirmation text not null check (confirmation in ('confirmed', 'denied', 'candidate', 'retracted')),
  dose_amount double precision check (dose_amount is null or (dose_amount >= 0 and dose_amount <= 1e9)),
  dose_unit text check (dose_unit is null or char_length(dose_unit) between 1 and 32),
  dose_provenance text check (dose_provenance is null or dose_provenance in ('user_entered', 'imported',
    'catalog_default')),
  upload_source_id uuid,
  content_digest text not null check (content_digest ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default clock_timestamp(),
  primary key (owner, event_id, revision),
  check (occurred_end > occurred_start and occurred_end - occurred_start <= 2678400),
  check (not (source = 'inferred_candidate' and confirmation = 'confirmed'))
);

create table if not exists public.exposure_events (
  owner uuid not null references auth.users(id) on delete cascade,
  event_id text not null check (event_id ~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$'),
  revision integer not null check (revision >= 1),
  kind text not null,
  label text not null,
  occurred_start bigint not null,
  occurred_end bigint not null,
  time_precision text not null,
  recorded_at bigint not null,
  received_at bigint not null,
  source text not null,
  confirmation text not null,
  dose_amount double precision,
  dose_unit text,
  dose_provenance text,
  content_digest text not null,
  revision_count integer not null default 1 check (revision_count >= 1),
  first_received_at bigint not null,
  updated_at timestamptz not null default clock_timestamp(),
  primary key (owner, event_id),
  check (occurred_end > occurred_start),
  foreign key (owner, event_id, revision) references public.exposure_event_revisions(owner, event_id, revision)
    on delete cascade
);
create index if not exists exposure_events_owner_start
  on public.exposure_events (owner, occurred_start);

-- ---------------------------------------------------------------------------------------------------------
-- 2. Row-level security and table privileges
-- ---------------------------------------------------------------------------------------------------------

alter table public.physiology_context_jobs enable row level security;
revoke all on public.physiology_context_jobs from public, anon, authenticated;
grant all on public.physiology_context_jobs to service_role;
drop policy if exists physiology_context_jobs_service on public.physiology_context_jobs;
create policy physiology_context_jobs_service on public.physiology_context_jobs
  for all to service_role using (true) with check (true);

do $$
declare t text;
begin
  foreach t in array array['physiology_context_days', 'physiology_context_envelope_tables',
    'physiology_context_daily_values', 'physiology_context_bouts', 'physiology_context_episodes',
    'physiology_context_frozen_references'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_service', t);
    execute format('create policy %I on public.%I for all to service_role using (true) with check (true)',
      t || '_service', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_own', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) = user_id)',
      t || '_select_own', t);
  end loop;
  foreach t in array array['exposure_event_revisions', 'exposure_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_service', t);
    execute format('create policy %I on public.%I for all to service_role using (true) with check (true)',
      t || '_service', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_own', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) = owner)',
      t || '_select_own', t);
  end loop;
end $$;

revoke all on sequence public.physiology_context_revision_seq from public, anon, authenticated;
grant usage, select on sequence public.physiology_context_revision_seq to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 3. Internal helpers (never client-reachable; the internal schema has no client USAGE)
-- ---------------------------------------------------------------------------------------------------------

-- The owner's zone: profiles.timezone when PostgreSQL knows it, else UTC (the scoring convention).
create or replace function internal.physiology_context_zone(p_user uuid) returns text
language plpgsql stable security definer set search_path = '' as $$
declare z text;
begin
  select nullif(btrim(p.timezone), '') into z from public.profiles p where p.id = p_user;
  if z is null then return 'UTC'; end if;
  perform (pg_catalog.now() at time zone z);
  return z;
exception when invalid_parameter_value then
  return 'UTC';
end $$;

create or replace function internal.physiology_context_today(p_user uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (pg_catalog.now() at time zone internal.physiology_context_zone(p_user))::date
$$;

-- An integral JSON number (no fraction, no exponent) as bigint, else NULL.
create or replace function internal.physiology_context_json_int(p jsonb) returns bigint
language sql immutable set search_path = '' as $$
  select case when pg_catalog.jsonb_typeof(p) = 'number' and (p #>> '{}') ~ '^-?[0-9]{1,18}$'
              then (p #>> '{}')::bigint end
$$;

-- A yyyy-MM-dd calendar date, else NULL (never raises).
create or replace function internal.physiology_context_parse_day(p text) returns date
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or p !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then return null; end if;
  return p::date;
exception when others then
  return null;
end $$;

-- A non-empty bounded string without whitespace or control characters (series, regime, ids).
create or replace function internal.physiology_context_is_key(p jsonb, p_max integer default 160) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(pg_catalog.jsonb_typeof(p) = 'string'
    and pg_catalog.char_length(p #>> '{}') between 1 and p_max
    and (p #>> '{}') !~ '[\x01-\x20\x7f-\x9f]', false)
$$;

create or replace function internal.physiology_context_merge_reasons(p_reasons text[], p_reason text)
returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array_agg(x.r order by x.r), '{}'::text[])
    from (select distinct u.r from unnest(coalesce(p_reasons, '{}'::text[]) || array[p_reason]) as u(r)
           where u.r is not null order by u.r limit 16) x
$$;

-- What a day's context depends on, outside the worker's own computation: the completed scoring revisions of
-- D-1..D+1 (a night window reaches across midnight), the activity day documents of D-1..D+1, the placement
-- declarations overlapping the window, the exposure events whose occurrence reaches the window (from D-4,
-- the worker's exposure read window), and the zone. sha256, hex.
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
          where pi.owner = p_user and (pi.device_id is null or pi.device_id = p_device)
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

-- Create the job, or bump it: a new input_revision fences any in-flight publish, the failure state resets
-- (the inputs changed) and the job is due at once. p_fingerprint NULL keeps the stored one.
create or replace function internal.physiology_context_touch(p_user uuid, p_device uuid, p_day date,
  p_mode text, p_reason text, p_fingerprint text)
returns void language sql security definer set search_path = '' as $$
  insert into public.physiology_context_jobs as j
    (user_id, device_id, day, mode, input_revision, completed_revision, fingerprint, reasons)
  values (p_user, p_device, p_day, p_mode, 1, 0, p_fingerprint, array[p_reason])
  on conflict (user_id, device_id, day, mode) do update set
    input_revision = j.input_revision + 1,
    dirty_at = pg_catalog.clock_timestamp(),
    not_before = pg_catalog.clock_timestamp(),
    consecutive_failures = 0,
    dead_letter = false,
    last_error = null,
    fingerprint = coalesce(excluded.fingerprint, j.fingerprint),
    reasons = internal.physiology_context_merge_reasons(j.reasons, p_reason)
$$;

-- Invalidate [p_from, p_to] (local days) for one device or (p_device NULL) every device of the owner. The
-- span is clamped to the owner's today and to its most recent 120 days. Today maps to causal_live, earlier
-- days to retrospective. Only (device, day) pairs that have scoring work or a context job are touched: a
-- day a device never recorded has no context to invalidate (it is enqueued from scoring if data arrives).
-- A retired owner (account deletion in progress) is never touched. Returns the number of jobs touched.
create or replace function internal.physiology_context_invalidate(p_user uuid, p_device uuid, p_from date,
  p_to date, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_today date;
  v_from date;
  v_to date;
  n integer := 0;
  r record;
begin
  if p_user is null or p_from is null or p_to is null or p_to < p_from then
    raise exception 'invalid_span' using errcode = '22023';
  end if;
  if p_reason is null or p_reason !~ '^[a-z][a-z0-9_]{0,47}$' then
    raise exception 'invalid_reason' using errcode = '22023';
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = p_user) then
    return 0;
  end if;
  v_today := internal.physiology_context_today(p_user);
  v_to := least(p_to, v_today);
  v_from := greatest(p_from, v_to - 119);
  if v_from > v_to then
    return 0;
  end if;
  for r in
    select d.id as device_id, g.day::date as day
      from public.devices d
      cross join generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') as g(day)
     where d.user_id = p_user and (p_device is null or d.id = p_device)
       and (exists (select 1 from public.scoring_jobs_v2 s
                     where s.user_id = p_user and s.device_id = d.id and s.day = g.day::date)
            or exists (select 1 from public.physiology_context_jobs j
                        where j.user_id = p_user and j.device_id = d.id and j.day = g.day::date))
     order by d.id, g.day
  loop
    perform internal.physiology_context_touch(p_user, r.device_id, r.day,
      case when r.day >= v_today then 'causal_live' else 'retrospective' end, p_reason, null);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Rejects every UPDATE of an immutable row. DELETE stays possible so the account / device cascade works.
create or replace function internal.physiology_context_reject_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception '%_immutable', tg_table_name using errcode = '55000';
end $$;

-- Placement corrections invalidate from the local day of the earliest instant whose placement changed
-- through the owner's today (capped at 120 days), for the declared device or, for a user-level declaration,
-- every device of the owner. Fires only for placement/source/effective_start/effective_end changes, so the
-- device FK's ON DELETE SET NULL (device or account deletion) never fires it.
create or replace function internal.physiology_context_placement_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_from timestamptz;
  v_day date;
  v_today date;
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
  -- A context problem must never fail a placement declaration: the invalidation runs in its own
  -- subtransaction and a failure is only reported as a warning (the next enqueue still sees the placement
  -- change through the dependency fingerprint).
  begin
    perform internal.physiology_context_invalidate(new.owner, new.device_id, v_day, v_today, 'placement_changed');
  exception when others then
    raise warning 'physiology context placement invalidation skipped: %', sqlstate;
  end;
  return null;
end $$;

-- Why an exposure event revision cannot be stored, or NULL when it can. The edge function applies the same
-- rules first (_shared/physiologyContext.ts validateExposureEvent); this is the backstop.
create or replace function internal.exposure_event_invalid_reason(p jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v_rev bigint;
  v_start bigint;
  v_end bigint;
  v_recorded bigint;
begin
  if p is null or jsonb_typeof(p) is distinct from 'object' then
    return 'invalid_event';
  end if;
  if jsonb_typeof(p -> 'event_id') is distinct from 'string'
     or (p ->> 'event_id') !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$' then
    return 'invalid_event_id';
  end if;
  v_rev := internal.physiology_context_json_int(p -> 'revision');
  if v_rev is null or v_rev < 1 or v_rev > 2147483647 then
    return 'invalid_revision';
  end if;
  if jsonb_typeof(p -> 'kind') is distinct from 'string' or (p ->> 'kind') not in ('medication', 'supplement',
     'caffeine', 'alcohol', 'meal', 'heat', 'travel', 'symptom', 'other') then
    return 'invalid_kind';
  end if;
  if jsonb_typeof(p -> 'label') is distinct from 'string' or char_length(p ->> 'label') not between 1 and 200
     or (p ->> 'label') ~ '[\x01-\x1f\x7f-\x9f]' then
    return 'invalid_label';
  end if;
  v_start := internal.physiology_context_json_int(p #> '{occurred,start}');
  v_end := internal.physiology_context_json_int(p #> '{occurred,end}');
  if jsonb_typeof(p -> 'occurred') is distinct from 'object' or v_start is null or v_end is null
     or v_start < 946684800 or v_end <= v_start or v_end - v_start > 2678400 or v_end > 4102444800 then
    return 'invalid_occurred';
  end if;
  if jsonb_typeof(p -> 'time_precision') is distinct from 'string'
     or (p ->> 'time_precision') not in ('exact', 'approximate', 'day_only') then
    return 'invalid_time_precision';
  end if;
  v_recorded := internal.physiology_context_json_int(p -> 'recorded_at');
  if v_recorded is null or v_recorded < 946684800 or v_recorded > 4102444800 then
    return 'invalid_recorded_at';
  end if;
  if jsonb_typeof(p -> 'source') is distinct from 'string'
     or (p ->> 'source') not in ('user_entered', 'journal_day_answer', 'imported', 'inferred_candidate') then
    return 'invalid_source';
  end if;
  if jsonb_typeof(p -> 'confirmation') is distinct from 'string'
     or (p ->> 'confirmation') not in ('confirmed', 'denied', 'candidate', 'retracted')
     or ((p ->> 'source') = 'inferred_candidate' and (p ->> 'confirmation') = 'confirmed') then
    return 'invalid_confirmation';
  end if;
  if coalesce(jsonb_typeof(p -> 'dose_amount'), 'null') <> 'null' then
    if jsonb_typeof(p -> 'dose_amount') <> 'number' then
      return 'invalid_dose_amount';
    end if;
    if (p ->> 'dose_amount')::numeric < 0 or (p ->> 'dose_amount')::numeric > 1e9 then
      return 'invalid_dose_amount';
    end if;
  end if;
  if coalesce(jsonb_typeof(p -> 'dose_unit'), 'null') <> 'null'
     and (jsonb_typeof(p -> 'dose_unit') <> 'string' or char_length(p ->> 'dose_unit') not between 1 and 32
          or (p ->> 'dose_unit') ~ '[\x01-\x1f\x7f-\x9f]') then
    return 'invalid_dose_unit';
  end if;
  if coalesce(jsonb_typeof(p -> 'dose_provenance'), 'null') <> 'null'
     and (jsonb_typeof(p -> 'dose_provenance') <> 'string'
          or (p ->> 'dose_provenance') not in ('user_entered', 'imported', 'catalog_default')) then
    return 'invalid_dose_provenance';
  end if;
  return null;
end $$;

-- One exposure revision as the ExposureEventRevision JSON the app and the worker decode.
create or replace function internal.exposure_revision_json(p public.exposure_event_revisions) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'event_id', p.event_id, 'revision', p.revision, 'kind', p.kind, 'label', p.label,
    'occurred', jsonb_build_object('start', p.occurred_start, 'end', p.occurred_end),
    'time_precision', p.time_precision, 'recorded_at', p.recorded_at, 'received_at', p.received_at,
    'source', p.source, 'confirmation', p.confirmation, 'dose_amount', p.dose_amount,
    'dose_unit', p.dose_unit, 'dose_provenance', p.dose_provenance)
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 4. Service RPCs: queue
-- ---------------------------------------------------------------------------------------------------------

-- Enqueue from scoring completions (algorithm frwhoop-server-1, the owner's last 120 local days):
--   * a (device, day) with its own completed scoring and no job for its mode is created (today first, then
--     the newest days), so the live day, a day that just closed (its retrospective job) and the backfill all
--     come from here (a neighbour without scoring of its own gets no job: it has no measurements);
--   * an existing, completed (or dead-lettered) job whose scoring of D-1..D+1 completed again after it was
--     last dirtied is bumped when its dependency fingerprint changed and it was last dirtied at least
--     10 minutes ago (a live day is rebuilt at most every 10 minutes; a pending job is never bumped here);
--   * a current retrospective 'provisional' document whose cutoff predates day end + 30 h is bumped once
--     now >= day end + 30 h (finality_due).
-- At most p_limit jobs are created or bumped per call. Retired owners are skipped. Reads scoring tables,
-- never writes them. Returns the number of jobs created or bumped.
create or replace function public.enqueue_physiology_context_days_v1(p_limit integer default 50)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n integer := 0;
  r record;
  v_fp text;
begin
  if p_limit is null or p_limit < 1 or p_limit > 1000 then
    raise exception 'invalid_limit' using errcode = '22023';
  end if;

  for r in
    with owners as materialized (
      select o.user_id, internal.physiology_context_today(o.user_id) as today
        from (select distinct s.user_id from public.scoring_jobs_v2 s
               where s.algorithm_version = 'frwhoop-server-1' and s.completed_revision > 0
                 and s.day >= (pg_catalog.now() at time zone 'UTC')::date - 122) o
       where not exists (select 1 from public.noop_account_retirements x where x.user_id = o.user_id)
    ), finished as (
      select s.user_id, s.device_id, s.day, s.last_completed_at, o.today
        from public.scoring_jobs_v2 s
        join owners o on o.user_id = s.user_id
       where s.algorithm_version = 'frwhoop-server-1' and s.completed_revision > 0
         and s.day between o.today - 120 and o.today + 1
    ), cand as (
      select f.user_id, f.device_id, (f.day + k.k) as day,
             max(coalesce(f.last_completed_at, '-infinity'::timestamptz)) as touched_at, min(f.today) as today,
             bool_or(k.k = 0) as own
        from finished f
        cross join (values (-1), (0), (1)) as k(k)
       where f.day + k.k between f.today - 119 and f.today
       group by f.user_id, f.device_id, f.day + k.k
    ), keyed as (
      select c.user_id, c.device_id, c.day, c.touched_at, c.own,
             case when c.day >= c.today then 'causal_live' else 'retrospective' end as mode
        from cand c
       where exists (select 1 from public.devices d where d.id = c.device_id and d.user_id = c.user_id)
    )
    select k.user_id, k.device_id, k.day, k.mode, j.fingerprint as job_fingerprint, (j.user_id is null) as absent
      from keyed k
      left join public.physiology_context_jobs j
        on j.user_id = k.user_id and j.device_id = k.device_id and j.day = k.day and j.mode = k.mode
     where (j.user_id is null and k.own)
        or ((j.completed_revision >= j.input_revision or j.dead_letter)
            and k.touched_at > j.dirty_at
            and j.dirty_at <= pg_catalog.clock_timestamp() - interval '10 minutes')
     order by (k.mode = 'causal_live') desc, (j.user_id is null) asc, k.day desc, k.user_id, k.device_id
  loop
    exit when n >= p_limit;
    v_fp := internal.physiology_context_dependency_fingerprint(r.user_id, r.device_id, r.day);
    if r.absent then
      insert into public.physiology_context_jobs (user_id, device_id, day, mode, fingerprint, reasons)
      values (r.user_id, r.device_id, r.day, r.mode, v_fp, array['scoring_completed'])
      on conflict (user_id, device_id, day, mode) do nothing;
      if found then n := n + 1; end if;
    elsif r.job_fingerprint is distinct from v_fp then
      perform internal.physiology_context_touch(r.user_id, r.device_id, r.day, r.mode, 'inputs_changed', v_fp);
      n := n + 1;
    end if;
  end loop;

  if n < p_limit then
    for r in
      select d.user_id, d.device_id, d.day
        from public.physiology_context_days d
        join public.physiology_context_jobs j
          on j.user_id = d.user_id and j.device_id = d.device_id and j.day = d.day and j.mode = d.mode
       where d.mode = 'retrospective' and d.superseded_by is null and d.finality = 'provisional'
         and d.day <= (pg_catalog.now() at time zone 'UTC')::date
         and j.completed_revision >= j.input_revision and not j.dead_letter
         and not exists (select 1 from public.noop_account_retirements x where x.user_id = d.user_id)
         and d.availability_cutoff <
             extract(epoch from ((d.day + 1)::timestamp at time zone internal.physiology_context_zone(d.user_id)))::bigint + 108000
         and extract(epoch from pg_catalog.now())::bigint >=
             extract(epoch from ((d.day + 1)::timestamp at time zone internal.physiology_context_zone(d.user_id)))::bigint + 108000
       order by d.day desc, d.user_id, d.device_id
       limit p_limit - n
    loop
      perform internal.physiology_context_touch(r.user_id, r.device_id, r.day, 'retrospective', 'finality_due', null);
      n := n + 1;
    end loop;
  end if;
  return n;
end $$;

-- Explicit invalidation (operators, the exposure RPC, the placement trigger). See
-- internal.physiology_context_invalidate for the rules. A device that is not the owner's is refused.
create or replace function public.invalidate_physiology_context_span_v1(p_user uuid, p_device uuid,
  p_from date, p_to date, p_reason text)
returns integer language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_device is not null
     and not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;
  return internal.physiology_context_invalidate(p_user, p_device, p_from, p_to, p_reason);
end $$;

-- One due job under a fresh lease: FOR UPDATE SKIP LOCKED; the least recently served owner first; within an
-- owner causal_live (newest day first) before retrospective (OLDEST day first, so references are built from
-- already-computed earlier days and a backfill does not cascade into days computed out of order). Re-stamps
-- the dependency fingerprint as of the claim. Retired owners are never handed out.
create or replace function public.claim_physiology_context_v1(p_worker text, p_lease_seconds integer default 300)
returns table (user_id uuid, device_id uuid, day date, mode text, input_revision bigint, lease_token uuid,
  lease_until timestamptz, timezone_id text, day_start bigint, day_end bigint, cutoff_override bigint,
  reasons text[], claim_count bigint)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  j public.physiology_context_jobs;
  v_zone text;
  v_fp text;
begin
  if p_lease_seconds is null or p_lease_seconds < 1 or p_lease_seconds > 3600 then
    raise exception 'invalid_lease' using errcode = '22023';
  end if;
  if p_worker is null or p_worker !~ '^[A-Za-z0-9._:@/-]{1,128}$' then
    raise exception 'invalid_worker' using errcode = '22023';
  end if;
  select q.* into j from public.physiology_context_jobs q
   where q.completed_revision < q.input_revision and not q.dead_letter
     and q.not_before <= pg_catalog.clock_timestamp()
     and (q.lease_until is null or q.lease_until <= pg_catalog.clock_timestamp())
     and not exists (select 1 from public.noop_account_retirements x where x.user_id = q.user_id)
   order by coalesce((select max(s.last_claimed_at) from public.physiology_context_jobs s
                       where s.user_id = q.user_id), '-infinity'::timestamptz),
            (q.mode = 'causal_live') desc,
            case when q.mode = 'causal_live' then q.day end desc,
            q.day asc, q.dirty_at, q.device_id
   for update of q skip locked limit 1;
  if not found then
    return;
  end if;
  v_zone := internal.physiology_context_zone(j.user_id);
  v_fp := internal.physiology_context_dependency_fingerprint(j.user_id, j.device_id, j.day);
  return query
  update public.physiology_context_jobs q set
    lease_token = gen_random_uuid(),
    lease_until = pg_catalog.clock_timestamp() + make_interval(secs => p_lease_seconds),
    last_claimed_at = pg_catalog.clock_timestamp(),
    claim_count = q.claim_count + 1,
    lease_expiry_count = q.lease_expiry_count + case when q.lease_token is null then 0 else 1 end,
    last_worker = p_worker,
    fingerprint = v_fp
  where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode
  returning q.user_id, q.device_id, q.day, q.mode, q.input_revision, q.lease_token, q.lease_until, v_zone,
    extract(epoch from (q.day::timestamp at time zone v_zone))::bigint,
    extract(epoch from ((q.day + 1)::timestamp at time zone v_zone))::bigint,
    q.cutoff_override, q.reasons, q.claim_count;
end $$;

create or replace function public.renew_physiology_context_v1(p_token uuid, p_lease_seconds integer default 300)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if p_lease_seconds is null or p_lease_seconds < 1 or p_lease_seconds > 3600 then
    raise exception 'invalid_lease' using errcode = '22023';
  end if;
  update public.physiology_context_jobs q set
    lease_until = pg_catalog.clock_timestamp() + make_interval(secs => p_lease_seconds),
    renewal_count = q.renewal_count + 1
  where q.lease_token = p_token and q.lease_until > pg_catalog.clock_timestamp();
  return found;
end $$;

-- A failed attempt under a live lease. Same revision: backoff min(3600, 5 * 2^failures) seconds and a dead
-- letter at the 8th consecutive failure. Different revision (the inputs changed meanwhile): a clean release
-- with no failure accounting, due at once. A lost or expired lease changes nothing.
-- Returns {status: failed|released|lease_lost|lease_expired, consecutive_failures, dead_letter, not_before}.
create or replace function public.fail_physiology_context_v1(p_token uuid, p_revision bigint, p_error text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  j public.physiology_context_jobs;
begin
  select * into j from public.physiology_context_jobs q where q.lease_token = p_token for update;
  if not found then
    return jsonb_build_object('status', 'lease_lost');
  end if;
  if j.lease_until <= pg_catalog.clock_timestamp() then
    return jsonb_build_object('status', 'lease_expired');
  end if;
  if p_revision is distinct from j.input_revision then
    update public.physiology_context_jobs q set lease_token = null, lease_until = null,
      not_before = pg_catalog.clock_timestamp(), consecutive_failures = 0, last_outcome = 'released'
    where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode
    returning * into j;
    return jsonb_build_object('status', 'released', 'consecutive_failures', j.consecutive_failures,
      'dead_letter', j.dead_letter, 'not_before', j.not_before);
  end if;
  update public.physiology_context_jobs q set
    consecutive_failures = q.consecutive_failures + 1,
    dead_letter = (q.consecutive_failures + 1 >= 8),
    not_before = pg_catalog.clock_timestamp()
      + make_interval(secs => least(3600, 5 * power(2, least(q.consecutive_failures, 10)))::integer),
    last_error = left(coalesce(p_error, 'unspecified'), 2000),
    last_outcome = 'failed',
    lease_token = null, lease_until = null
  where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode
  returning * into j;
  return jsonb_build_object('status', 'failed', 'consecutive_failures', j.consecutive_failures,
    'dead_letter', j.dead_letter, 'not_before', j.not_before);
end $$;

-- Fenced publication (contracts.md §6). Payload:
--   {header: {mode, day, finality, status, availability_cutoff, generated_at, contract_version,
--             schema_version, policy_fingerprint, input_fingerprint, versions},
--    document (the summary: envelopes empty, envelope_index set), envelope_tables[] ({metric, envelope_count,
--    table}), scoring_result_revision, scoring_input_revision, duration_ms,
--    daily_values[], bouts[], episodes[], new_frozen_references[]}
-- Outcomes ({applied, context_revision, reason, cascaded_days, ...}):
--   lease_lost / lease_expired     nothing written
--   stale_revision                 the lease is released (the inputs changed meanwhile); nothing written
--   owner_retired                  the lease is released; nothing written
--   unchanged                      the current document already has these (policy, input) fingerprints: no new
--                                  row or envelope table, values/bouts/episodes untouched, job completed (the
--                                  pairing columns may be raised to the newer scoring snapshot the identical
--                                  document was built for)
--   published                      new immutable row plus its envelope tables; the previous current row is marked
--                                  superseded, and superseded rows of this key older than 24 h are deleted with
--                                  their tables (retention: the current row, plus superseded rows for 24 h); values and bouts of the
--                                  day replaced; episodes replaced only when this day >= the latest day already
--                                  published for (user, device, mode); frozen references inserted (existing
--                                  ones untouched); job completed; and when the retrospective daily values of
--                                  the day changed, the device's existing retrospective jobs for D+1 ..
--                                  min(today - 1, D + 28) are bumped (history_changed).
-- A malformed payload raises (22023, invalid_physiology_context_*) and rolls everything back; the worker then
-- reports it through fail_physiology_context_v1.
create or replace function public.publish_physiology_context_v1(p_token uuid, p_revision bigint, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_key record;
  j public.physiology_context_jobs;
  h jsonb;
  doc jsonb;
  dv jsonb;
  bt jsonb;
  ep jsonb;
  fr jsonb;
  et jsonb;
  v_index jsonb;
  v_table_metrics text[] := '{}'::text[];
  v_table_envelopes integer := 0;
  v_table_bytes bigint := 0;
  e jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_finality text;
  v_status text;
  v_cutoff bigint;
  v_generated bigint;
  v_contract text;
  v_schema bigint;
  v_policy text;
  v_input text;
  v_versions jsonb;
  v_scoring_result bigint;
  v_scoring_input bigint;
  v_duration bigint;
  v_bytes bigint;
  v_envelopes integer;
  v_existing_rev bigint;
  v_existing_current boolean;
  v_prev bigint;
  v_rev bigint;
  v_latest date;
  v_old jsonb;
  v_new jsonb;
  v_changed boolean;
  v_episodes boolean := false;
  v_frozen integer := 0;
  v_frozen_conflicts integer := 0;
  v_cascaded integer := 0;
  v_today date;
  v_s bigint;
  v_e bigint;
  r record;
begin
  if p_token is null or p_revision is null then
    raise exception 'invalid_arguments' using errcode = '22023';
  end if;
  -- Serialize publications per (user, device, mode) BEFORE taking any row lock, so the episode rule reads the
  -- latest published day of a concurrent publish and two publishes of one device never deadlock.
  select q.user_id, q.device_id, q.mode into v_key from public.physiology_context_jobs q where q.lease_token = p_token;
  if not found then
    return jsonb_build_object('applied', false, 'context_revision', null, 'reason', 'lease_lost', 'cascaded_days', 0);
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'physiology-context-publish:' || v_key.user_id::text || ':' || v_key.device_id::text || ':' || v_key.mode, 0));
  select * into j from public.physiology_context_jobs q where q.lease_token = p_token for update;
  if not found then
    return jsonb_build_object('applied', false, 'context_revision', null, 'reason', 'lease_lost', 'cascaded_days', 0);
  end if;
  if j.lease_until <= v_now then
    return jsonb_build_object('applied', false, 'context_revision', null, 'reason', 'lease_expired', 'cascaded_days', 0);
  end if;
  if j.input_revision <> p_revision then
    update public.physiology_context_jobs q set lease_token = null, lease_until = null, not_before = v_now,
      last_outcome = 'stale_revision'
     where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode;
    return jsonb_build_object('applied', false, 'context_revision', null, 'reason', 'stale_revision', 'cascaded_days', 0);
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = j.user_id) then
    update public.physiology_context_jobs q set lease_token = null, lease_until = null, last_outcome = 'owner_retired'
     where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode;
    return jsonb_build_object('applied', false, 'context_revision', null, 'reason', 'owner_retired', 'cascaded_days', 0);
  end if;

  -- Validation -------------------------------------------------------------------------------------------
  if jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'invalid_physiology_context_payload' using errcode = '22023';
  end if;
  h := p_payload -> 'header';
  doc := p_payload -> 'document';
  if jsonb_typeof(h) is distinct from 'object' then
    raise exception 'invalid_physiology_context_header' using errcode = '22023';
  end if;
  if jsonb_typeof(doc) is distinct from 'object' then
    raise exception 'invalid_physiology_context_document' using errcode = '22023';
  end if;
  if (h ->> 'mode') is distinct from j.mode or (h ->> 'day') is distinct from to_char(j.day, 'YYYY-MM-DD') then
    raise exception 'invalid_physiology_context_identity' using errcode = '22023';
  end if;
  v_finality := h ->> 'finality';
  v_status := h ->> 'status';
  v_cutoff := internal.physiology_context_json_int(h -> 'availability_cutoff');
  v_generated := internal.physiology_context_json_int(h -> 'generated_at');
  v_contract := h ->> 'contract_version';
  v_schema := internal.physiology_context_json_int(h -> 'schema_version');
  v_policy := h ->> 'policy_fingerprint';
  v_input := h ->> 'input_fingerprint';
  v_versions := coalesce(nullif(h -> 'versions', 'null'::jsonb), '{}'::jsonb);
  if v_finality is null or v_finality not in ('provisional', 'final')
     or v_status is null or v_status not in ('available', 'partial', 'no_data', 'unavailable')
     or v_cutoff is null or v_generated is null
     or v_contract is null or v_contract !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
     or v_schema is null or v_schema < 1 or v_schema > 1000
     or v_policy is null or v_policy !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$'
     or v_input is null or v_input !~ '^[A-Za-z0-9][A-Za-z0-9:._-]{0,127}$'
     or jsonb_typeof(v_versions) <> 'object' then
    raise exception 'invalid_physiology_context_header' using errcode = '22023';
  end if;
  -- The document may not contradict the header it is published under.
  if ((doc #>> '{header,identity,day}') is not null and (doc #>> '{header,identity,day}') <> to_char(j.day, 'YYYY-MM-DD'))
     or ((doc #>> '{header,interpretation,mode}') is not null and (doc #>> '{header,interpretation,mode}') <> j.mode)
     or ((doc #>> '{header,policy_fingerprint}') is not null and (doc #>> '{header,policy_fingerprint}') <> v_policy)
     or ((doc #>> '{header,input_fingerprint}') is not null and (doc #>> '{header,input_fingerprint}') <> v_input) then
    raise exception 'invalid_physiology_context_identity' using errcode = '22023';
  end if;
  v_bytes := octet_length(doc::text);
  if v_bytes > 16777216 then
    raise exception 'invalid_physiology_context_document_size' using errcode = '22023';
  end if;
  v_envelopes := case when jsonb_typeof(doc -> 'envelopes') = 'array' then jsonb_array_length(doc -> 'envelopes') else 0 end;
  if coalesce(jsonb_typeof(p_payload -> 'scoring_result_revision'), 'null') <> 'null' then
    v_scoring_result := internal.physiology_context_json_int(p_payload -> 'scoring_result_revision');
    if v_scoring_result is null or v_scoring_result < 1 then
      raise exception 'invalid_physiology_context_scoring_revision' using errcode = '22023';
    end if;
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'scoring_input_revision'), 'null') <> 'null' then
    v_scoring_input := internal.physiology_context_json_int(p_payload -> 'scoring_input_revision');
    if v_scoring_input is null or v_scoring_input < 1 then
      raise exception 'invalid_physiology_context_scoring_revision' using errcode = '22023';
    end if;
  end if;
  if coalesce(jsonb_typeof(p_payload -> 'duration_ms'), 'null') <> 'null' then
    v_duration := internal.physiology_context_json_int(p_payload -> 'duration_ms');
    if v_duration is null or v_duration < 0 then
      raise exception 'invalid_physiology_context_payload' using errcode = '22023';
    end if;
  end if;

  dv := coalesce(nullif(p_payload -> 'daily_values', 'null'::jsonb), '[]'::jsonb);
  bt := coalesce(nullif(p_payload -> 'bouts', 'null'::jsonb), '[]'::jsonb);
  ep := coalesce(nullif(p_payload -> 'episodes', 'null'::jsonb), '[]'::jsonb);
  fr := coalesce(nullif(p_payload -> 'new_frozen_references', 'null'::jsonb), '[]'::jsonb);
  if jsonb_typeof(dv) <> 'array' or jsonb_array_length(dv) > 4000 then
    raise exception 'invalid_physiology_context_daily_value' using errcode = '22023';
  end if;
  if jsonb_typeof(bt) <> 'array' or jsonb_array_length(bt) > 1000 then
    raise exception 'invalid_physiology_context_bout' using errcode = '22023';
  end if;
  if jsonb_typeof(ep) <> 'array' or jsonb_array_length(ep) > 4000 then
    raise exception 'invalid_physiology_context_episode' using errcode = '22023';
  end if;
  if jsonb_typeof(fr) <> 'array' or jsonb_array_length(fr) > 1000 then
    raise exception 'invalid_physiology_context_frozen_reference' using errcode = '22023';
  end if;

  for e in select x.value from jsonb_array_elements(dv) as x(value) loop
    if jsonb_typeof(e) <> 'object'
       or (e ->> 'day') is distinct from to_char(j.day, 'YYYY-MM-DD')
       or (e ->> 'mode') is distinct from j.mode
       or not internal.physiology_context_is_key(e -> 'series_key')
       or not internal.physiology_context_is_key(e -> 'regime_key')
       or jsonb_typeof(e -> 'value') is distinct from 'number'
       or jsonb_typeof(e -> 'units') is distinct from 'string' or char_length(e ->> 'units') > 32
       or coalesce(internal.physiology_context_json_int(e -> 'support_count'), -1) not between 0 and 2147483647
       or jsonb_typeof(e -> 'support_unit') is distinct from 'string' or char_length(e ->> 'support_unit') > 32
       or coalesce(internal.physiology_context_json_int(e -> 'support_s'), -1) < 0
       or (e ->> 'finality') is null or (e ->> 'finality') not in ('provisional', 'final')
       or coalesce(jsonb_typeof(e -> 'metric'), 'null') not in ('null', 'string') then
      raise exception 'invalid_physiology_context_daily_value' using errcode = '22023';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(dv))
     <> (select count(distinct (x.value ->> 'series_key') || E'\n' || (x.value ->> 'regime_key'))
           from jsonb_array_elements(dv) as x(value)) then
    raise exception 'invalid_physiology_context_daily_value_duplicate' using errcode = '22023';
  end if;

  for e in select x.value from jsonb_array_elements(bt) as x(value) loop
    v_s := internal.physiology_context_json_int(e #> '{interval,start}');
    v_e := internal.physiology_context_json_int(e #> '{interval,end}');
    if jsonb_typeof(e) <> 'object'
       or not internal.physiology_context_is_key(e -> 'id')
       or (e ->> 'day') is distinct from to_char(j.day, 'YYYY-MM-DD')
       or v_s is null or v_e is null or v_e <= v_s
       or jsonb_typeof(e -> 'kind') is distinct from 'string' or char_length(e ->> 'kind') not between 1 and 64
       or jsonb_typeof(e -> 'status') is distinct from 'string' or char_length(e ->> 'status') not between 1 and 32
       or coalesce(internal.physiology_context_json_int(e -> 'duration_s'), -1) < 0 then
      raise exception 'invalid_physiology_context_bout' using errcode = '22023';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(bt))
     <> (select count(distinct x.value ->> 'id') from jsonb_array_elements(bt) as x(value)) then
    raise exception 'invalid_physiology_context_bout_duplicate' using errcode = '22023';
  end if;

  for e in select x.value from jsonb_array_elements(ep) as x(value) loop
    if jsonb_typeof(e) <> 'object'
       or not internal.physiology_context_is_key(e -> 'id')
       or not internal.physiology_context_is_key(e -> 'series_key')
       or not internal.physiology_context_is_key(e -> 'regime_key')
       or (e ->> 'state') is null or (e ->> 'state') not in ('usual_variation', 'transient_deviation',
          'recurring_episode', 'persistent_shift', 'insufficient_evidence')
       or coalesce(internal.physiology_context_json_int(e -> 'direction'), 9) not in (-1, 0, 1)
       or internal.physiology_context_parse_day(e ->> 'start_day') is null
       or internal.physiology_context_parse_day(e ->> 'last_day') is null
       or internal.physiology_context_parse_day(e ->> 'last_day') < internal.physiology_context_parse_day(e ->> 'start_day')
       or jsonb_typeof(e -> 'ongoing') is distinct from 'boolean'
       or coalesce(internal.physiology_context_json_int(e -> 'duration_days'), -1) not between 0 and 2147483647
       or (e ->> 'finality') is null or (e ->> 'finality') not in ('provisional', 'final') then
      raise exception 'invalid_physiology_context_episode' using errcode = '22023';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(ep))
     <> (select count(distinct x.value ->> 'id') from jsonb_array_elements(ep) as x(value)) then
    raise exception 'invalid_physiology_context_episode_duplicate' using errcode = '22023';
  end if;

  for e in select x.value from jsonb_array_elements(fr) as x(value) loop
    if jsonb_typeof(e) <> 'object'
       or not internal.physiology_context_is_key(e -> 'id')
       or not internal.physiology_context_is_key(e -> 'series_key')
       or not internal.physiology_context_is_key(e -> 'regime_key')
       or coalesce(internal.physiology_context_json_int(e -> 'version'), 0) not between 1 and 2147483647
       or internal.physiology_context_parse_day(e ->> 'from_day') is null
       or internal.physiology_context_parse_day(e ->> 'to_day') is null
       or internal.physiology_context_parse_day(e ->> 'to_day') < internal.physiology_context_parse_day(e ->> 'from_day')
       or internal.physiology_context_parse_day(e ->> 'created_for_day') is null
       or coalesce(internal.physiology_context_json_int(e -> 'support_days'), -1) not between 0 and 2147483647
       or jsonb_typeof(e -> 'center') is distinct from 'number'
       or jsonb_typeof(e -> 'scale') is distinct from 'number'
       or jsonb_typeof(e -> 'transform') is distinct from 'string' or char_length(e ->> 'transform') not between 1 and 32
       or jsonb_typeof(e -> 'selection_rule') is distinct from 'string'
       or char_length(e ->> 'selection_rule') not between 1 and 200
       or not internal.physiology_context_is_key(e -> 'policy_fingerprint', 128) then
      raise exception 'invalid_physiology_context_frozen_reference' using errcode = '22023';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(fr))
     <> (select count(distinct x.value ->> 'id') from jsonb_array_elements(fr) as x(value))
     or (select count(*) from jsonb_array_elements(fr))
     <> (select count(distinct (x.value ->> 'series_key') || E'\n' || (x.value ->> 'regime_key') || E'\n'
                                || (x.value ->> 'version'))
           from jsonb_array_elements(fr) as x(value)) then
    raise exception 'invalid_physiology_context_frozen_reference_duplicate' using errcode = '22023';
  end if;

  -- Envelope tables: each {metric, envelope_count, table} with table.metric = metric and table.rows of exactly
  -- envelope_count rows, one per metric; when the summary carries an envelope_index it must list exactly these
  -- (metric, envelope_count) pairs, and tables without an index are refused.
  et := coalesce(nullif(p_payload -> 'envelope_tables', 'null'::jsonb), '[]'::jsonb);
  if jsonb_typeof(et) <> 'array' or jsonb_array_length(et) > 16 then
    raise exception 'invalid_physiology_context_envelope_table' using errcode = '22023';
  end if;
  for e in select x.value from jsonb_array_elements(et) as x(value) loop
    if jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e -> 'metric') is distinct from 'string' or (e ->> 'metric') !~ '^[a-z][a-z0-9_]{0,47}$'
       or coalesce(internal.physiology_context_json_int(e -> 'envelope_count'), -1) not between 0 and 1000000
       or jsonb_typeof(e -> 'table') is distinct from 'object'
       or (e #>> '{table,metric}') is distinct from (e ->> 'metric')
       or jsonb_typeof(e #> '{table,wire_version}') is distinct from 'string'
       or (e #>> '{table,wire_version}') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'
       or jsonb_typeof(e #> '{table,rows}') is distinct from 'array'
       or jsonb_array_length(e #> '{table,rows}') <> internal.physiology_context_json_int(e -> 'envelope_count')
       or octet_length((e -> 'table')::text) > 16777216 then
      raise exception 'invalid_physiology_context_envelope_table' using errcode = '22023';
    end if;
    if (e ->> 'metric') = any (v_table_metrics) then
      raise exception 'invalid_physiology_context_envelope_table_duplicate' using errcode = '22023';
    end if;
    v_table_metrics := v_table_metrics || (e ->> 'metric');
    v_table_envelopes := v_table_envelopes + internal.physiology_context_json_int(e -> 'envelope_count')::integer;
    v_table_bytes := v_table_bytes + octet_length((e -> 'table')::text);
  end loop;
  v_index := doc -> 'envelope_index';
  if coalesce(jsonb_typeof(v_index), 'null') = 'null' then
    if jsonb_array_length(et) > 0 then
      raise exception 'invalid_physiology_context_envelope_index' using errcode = '22023';
    end if;
  elsif jsonb_typeof(v_index) <> 'array'
     or (select coalesce(jsonb_agg(jsonb_build_object('metric', x.value -> 'metric',
                  'envelope_count', x.value -> 'envelope_count') order by x.value ->> 'metric' collate "C"), '[]'::jsonb)
           from jsonb_array_elements(v_index) as x(value))
        is distinct from
        (select coalesce(jsonb_agg(jsonb_build_object('metric', x.value -> 'metric',
                  'envelope_count', x.value -> 'envelope_count') order by x.value ->> 'metric' collate "C"), '[]'::jsonb)
           from jsonb_array_elements(et) as x(value)) then
    raise exception 'invalid_physiology_context_envelope_index' using errcode = '22023';
  end if;

  -- Idempotency ------------------------------------------------------------------------------------------
  select d.context_revision, (d.superseded_by is null) into v_existing_rev, v_existing_current
    from public.physiology_context_days d
   where d.user_id = j.user_id and d.device_id = j.device_id and d.day = j.day and d.mode = j.mode
     and d.policy_fingerprint = v_policy and d.input_fingerprint = v_input;
  if v_existing_rev is not null and v_existing_current then
    update public.physiology_context_days d set
      scoring_result_revision = v_scoring_result,
      scoring_input_revision = coalesce(v_scoring_input, d.scoring_input_revision)
     where d.context_revision = v_existing_rev and v_scoring_result is not null
       and (d.scoring_result_revision is null or d.scoring_result_revision < v_scoring_result);
    update public.physiology_context_jobs q set
      completed_revision = p_revision, lease_token = null, lease_until = null, consecutive_failures = 0,
      dead_letter = false, last_error = null, last_completed_at = v_now,
      last_duration_ms = coalesce(v_duration, q.last_duration_ms), success_count = q.success_count + 1,
      unchanged_count = q.unchanged_count + 1, reasons = '{}'::text[], cutoff_override = null,
      last_outcome = 'unchanged', last_context_revision = v_existing_rev
     where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode;
    return jsonb_build_object('applied', false, 'context_revision', v_existing_rev, 'reason', 'unchanged',
      'cascaded_days', 0, 'document_bytes', v_bytes);
  end if;
  if v_existing_rev is not null then
    -- The same fingerprints as a retained superseded row (A -> B -> A): drop the old copy (its tables cascade) so
    -- the revision keeps increasing and the unique fingerprint key holds.
    delete from public.physiology_context_days d where d.context_revision = v_existing_rev;
  end if;

  -- New revision -----------------------------------------------------------------------------------------
  select d.context_revision into v_prev from public.physiology_context_days d
   where d.user_id = j.user_id and d.device_id = j.device_id and d.day = j.day and d.mode = j.mode
     and d.superseded_by is null
   for update;
  select max(d.day) into v_latest from public.physiology_context_days d
   where d.user_id = j.user_id and d.device_id = j.device_id and d.mode = j.mode and d.superseded_by is null;
  v_rev := nextval('public.physiology_context_revision_seq');
  if v_prev is not null then
    update public.physiology_context_days d set superseded_by = v_rev, superseded_at = v_now
     where d.context_revision = v_prev;
  end if;
  insert into public.physiology_context_days (context_revision, user_id, device_id, day, mode, job_revision,
    finality, status, availability_cutoff, generated_at, contract_version, schema_version, policy_fingerprint,
    input_fingerprint, versions, scoring_result_revision, scoring_input_revision, document, document_bytes,
    envelope_count, published_at)
  values (v_rev, j.user_id, j.device_id, j.day, j.mode, p_revision, v_finality, v_status, v_cutoff, v_generated,
    v_contract, v_schema, v_policy, v_input, v_versions, v_scoring_result, v_scoring_input, doc, v_bytes,
    v_envelopes + v_table_envelopes, v_now);
  insert into public.physiology_context_envelope_tables (context_revision, user_id, device_id, metric,
    envelope_count, table_bytes, envelope_table)
  select v_rev, j.user_id, j.device_id, x.value ->> 'metric',
         internal.physiology_context_json_int(x.value -> 'envelope_count')::integer,
         octet_length((x.value -> 'table')::text), x.value -> 'table'
    from jsonb_array_elements(et) as x(value);
  -- Retention: the current row; a superseded row (and its tables, by cascade) once superseded for 24 h.
  delete from public.physiology_context_days d
   where d.user_id = j.user_id and d.device_id = j.device_id and d.day = j.day and d.mode = j.mode
     and d.superseded_by is not null and d.superseded_at < v_now - interval '24 hours';

  -- Daily values: replaced for the day; compared first for the cross-day cascade.
  select coalesce(jsonb_agg(v.payload order by v.series_key collate "C", v.regime_key collate "C"), '[]'::jsonb)
    into v_old
    from public.physiology_context_daily_values v
   where v.user_id = j.user_id and v.device_id = j.device_id and v.mode = j.mode and v.day = j.day;
  select coalesce(jsonb_agg(x.value order by (x.value ->> 'series_key') collate "C",
                                             (x.value ->> 'regime_key') collate "C"), '[]'::jsonb)
    into v_new
    from jsonb_array_elements(dv) as x(value);
  v_changed := v_old is distinct from v_new;
  delete from public.physiology_context_daily_values v
   where v.user_id = j.user_id and v.device_id = j.device_id and v.mode = j.mode and v.day = j.day;
  insert into public.physiology_context_daily_values (user_id, device_id, mode, day, series_key, regime_key,
    metric, value, units, support_count, support_unit, support_s, finality, context_revision, payload)
  select j.user_id, j.device_id, j.mode, j.day, x.value ->> 'series_key', x.value ->> 'regime_key',
         x.value ->> 'metric', (x.value ->> 'value')::double precision, x.value ->> 'units',
         internal.physiology_context_json_int(x.value -> 'support_count')::integer, x.value ->> 'support_unit',
         internal.physiology_context_json_int(x.value -> 'support_s'), x.value ->> 'finality', v_rev, x.value
    from jsonb_array_elements(dv) as x(value);

  -- Bouts: replaced for the day. A bout id already stored under another day moves to this one.
  delete from public.physiology_context_bouts b
   where b.user_id = j.user_id and b.device_id = j.device_id and b.mode = j.mode and b.day = j.day;
  insert into public.physiology_context_bouts as b (user_id, device_id, mode, bout_id, day, start_ts, end_ts,
    kind, status, duration_s, context_revision, payload)
  select j.user_id, j.device_id, j.mode, x.value ->> 'id', j.day,
         internal.physiology_context_json_int(x.value #> '{interval,start}'),
         internal.physiology_context_json_int(x.value #> '{interval,end}'),
         x.value ->> 'kind', x.value ->> 'status', internal.physiology_context_json_int(x.value -> 'duration_s'),
         v_rev, x.value
    from jsonb_array_elements(bt) as x(value)
  on conflict (user_id, device_id, mode, bout_id) do update set
    day = excluded.day, start_ts = excluded.start_ts, end_ts = excluded.end_ts, kind = excluded.kind,
    status = excluded.status, duration_s = excluded.duration_s, context_revision = excluded.context_revision,
    payload = excluded.payload;

  -- Episodes: only a view from the latest published day (or a newer one) replaces the set.
  if v_latest is null or j.day >= v_latest then
    delete from public.physiology_context_episodes x
     where x.user_id = j.user_id and x.device_id = j.device_id and x.mode = j.mode;
    insert into public.physiology_context_episodes (user_id, device_id, mode, episode_id, series_key, regime_key,
      state, direction, start_day, last_day, ongoing, duration_days, finality, as_of_day, context_revision, payload)
    select j.user_id, j.device_id, j.mode, x.value ->> 'id', x.value ->> 'series_key', x.value ->> 'regime_key',
           x.value ->> 'state', internal.physiology_context_json_int(x.value -> 'direction')::smallint,
           (x.value ->> 'start_day')::date, (x.value ->> 'last_day')::date, (x.value ->> 'ongoing')::boolean,
           internal.physiology_context_json_int(x.value -> 'duration_days')::integer, x.value ->> 'finality',
           j.day, v_rev, x.value
      from jsonb_array_elements(ep) as x(value);
    v_episodes := true;
  end if;

  -- Frozen references: insert-only; an existing id or (series, regime, version) is left exactly as it is.
  insert into public.physiology_context_frozen_references (user_id, device_id, reference_id, series_key,
    regime_key, version, from_day, to_day, support_days, center, scale, transform, selection_rule,
    created_for_day, policy_fingerprint, context_revision, payload)
  select j.user_id, j.device_id, x.value ->> 'id', x.value ->> 'series_key', x.value ->> 'regime_key',
         internal.physiology_context_json_int(x.value -> 'version')::integer, (x.value ->> 'from_day')::date,
         (x.value ->> 'to_day')::date, internal.physiology_context_json_int(x.value -> 'support_days')::integer,
         (x.value ->> 'center')::double precision, (x.value ->> 'scale')::double precision,
         x.value ->> 'transform', x.value ->> 'selection_rule', (x.value ->> 'created_for_day')::date,
         x.value ->> 'policy_fingerprint', v_rev, x.value
    from jsonb_array_elements(fr) as x(value)
  on conflict do nothing;
  get diagnostics v_frozen = row_count;
  -- A proposed reference whose (series, regime, version) is already registered under ANOTHER id is not stored: the
  -- registered one stays the authority (never silently replaced). The day's document still describes the reference
  -- it computed from its own strictly-earlier history; the count makes that visible instead of silent.
  select count(*) into v_frozen_conflicts
    from jsonb_array_elements(fr) as x(value)
    join public.physiology_context_frozen_references f
      on f.user_id = j.user_id and f.device_id = j.device_id and f.series_key = x.value ->> 'series_key'
     and f.regime_key = x.value ->> 'regime_key'
     and f.version = internal.physiology_context_json_int(x.value -> 'version')::integer
     and f.reference_id <> x.value ->> 'id';

  update public.physiology_context_jobs q set
    completed_revision = p_revision, lease_token = null, lease_until = null, consecutive_failures = 0,
    dead_letter = false, last_error = null, last_completed_at = v_now,
    last_duration_ms = coalesce(v_duration, q.last_duration_ms), success_count = q.success_count + 1,
    reasons = '{}'::text[], cutoff_override = null, last_outcome = 'published', last_context_revision = v_rev
   where q.user_id = j.user_id and q.device_id = j.device_id and q.day = j.day and q.mode = j.mode;

  -- Cross-day dependency horizon: later retrospective days read this day's values as history.
  if j.mode = 'retrospective' and v_changed then
    v_today := internal.physiology_context_today(j.user_id);
    for r in
      select q.day from public.physiology_context_jobs q
       where q.user_id = j.user_id and q.device_id = j.device_id and q.mode = 'retrospective'
         and q.day between j.day + 1 and least(v_today - 1, j.day + 28)
       order by q.day
    loop
      perform internal.physiology_context_touch(j.user_id, j.device_id, r.day, 'retrospective', 'history_changed', null);
      v_cascaded := v_cascaded + 1;
    end loop;
  end if;

  return jsonb_build_object('applied', true, 'context_revision', v_rev, 'reason', 'published',
    'cascaded_days', v_cascaded, 'superseded_revision', v_prev, 'document_bytes', v_bytes,
    'envelope_tables', to_jsonb(v_table_metrics), 'table_bytes', v_table_bytes,
    'daily_values_changed', v_changed, 'episodes_replaced', v_episodes, 'frozen_references_inserted', v_frozen,
    'frozen_references_conflicting', v_frozen_conflicts);
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 5. Service RPCs: reads (the scores edge function calls these with the owner from the credential)
-- ---------------------------------------------------------------------------------------------------------

-- One device-day's context (contracts.md §6/§8). p_mode NULL picks retrospective when a retrospective
-- document exists, else causal_live when one exists, else whichever mode has a job (retrospective first).
-- status: pending when that mode's job is queued (completed_revision < input_revision, not dead-lettered),
-- else available when a document exists, else none. A pending status still returns the current (older)
-- document so the caller can show it as updating. document is the stored summary; envelope_tables holds the
-- revision's EnvelopeTable JSON, only p_metric's table when given (MetricKind raw value), every table otherwise;
-- the client rebuilds with StoredDocument.join(summary:tables:). (A plain document's own envelopes, if any, are
-- filtered by p_metric too.)
-- pairing compares the newest frwhoop-server-1 snapshot of the day with the snapshot the document was built
-- against; consistent is true only when a document exists and the two are equal (both NULL counts as equal).
create or replace function public.physiology_context_read_v1(p_user uuid, p_device uuid, p_day date,
  p_mode text default null, p_metric text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_modes jsonb;
  v_mode text := p_mode;
  r public.physiology_context_days;
  v_found boolean;
  jb public.physiology_context_jobs;
  v_job boolean;
  v_pending boolean := false;
  v_snapshot bigint;
  v_doc jsonb;
  v_returned integer;
  v_tables jsonb;
  v_table_bytes bigint;
  v_table_envelopes bigint;
  v_stored_table_bytes bigint;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_user is null or p_device is null or p_day is null then
    raise exception 'invalid_arguments' using errcode = '22023';
  end if;
  if p_mode is not null and p_mode not in ('causal_live', 'retrospective') then
    raise exception 'invalid_mode' using errcode = '22023';
  end if;
  if p_metric is not null and p_metric !~ '^[a-z][a-z0-9_]{0,47}$' then
    raise exception 'invalid_metric' using errcode = '22023';
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = p_user) then
    raise exception 'account_retired' using errcode = '42501';
  end if;
  if not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(d.mode order by d.mode), '[]'::jsonb) into v_modes
    from public.physiology_context_days d
   where d.user_id = p_user and d.device_id = p_device and d.day = p_day and d.superseded_by is null;
  if v_mode is null then
    v_mode := case
      when v_modes ? 'retrospective' then 'retrospective'
      when v_modes ? 'causal_live' then 'causal_live'
      when exists (select 1 from public.physiology_context_jobs q where q.user_id = p_user
                     and q.device_id = p_device and q.day = p_day and q.mode = 'retrospective') then 'retrospective'
      else 'causal_live' end;
  end if;

  select * into r from public.physiology_context_days d
   where d.user_id = p_user and d.device_id = p_device and d.day = p_day and d.mode = v_mode
     and d.superseded_by is null;
  v_found := found;
  select * into jb from public.physiology_context_jobs q
   where q.user_id = p_user and q.device_id = p_device and q.day = p_day and q.mode = v_mode;
  v_job := found;
  if v_job then
    v_pending := jb.completed_revision < jb.input_revision and not jb.dead_letter;
  end if;
  select s.result_revision into v_snapshot from public.scoring_snapshots_v2 s
   where s.user_id = p_user and s.device_id = p_device and s.day = p_day and s.algorithm_version = 'frwhoop-server-1'
   order by s.result_revision desc limit 1;

  if v_found then
    v_doc := r.document;
    if p_metric is not null and jsonb_typeof(v_doc -> 'envelopes') = 'array' then
      v_doc := jsonb_set(v_doc, '{envelopes}', coalesce((
        select jsonb_agg(x.value order by x.ord)
          from jsonb_array_elements(v_doc -> 'envelopes') with ordinality as x(value, ord)
         where x.value ->> 'metric' = p_metric), '[]'::jsonb));
    end if;
    select coalesce(jsonb_agg(t.envelope_table order by t.metric collate "C"), '[]'::jsonb),
           coalesce(sum(t.table_bytes), 0), coalesce(sum(t.envelope_count), 0)
      into v_tables, v_table_bytes, v_table_envelopes
      from public.physiology_context_envelope_tables t
     where t.context_revision = r.context_revision and (p_metric is null or t.metric = p_metric);
    select coalesce(sum(t.table_bytes), 0) into v_stored_table_bytes
      from public.physiology_context_envelope_tables t where t.context_revision = r.context_revision;
    v_returned := v_table_envelopes::integer + case when jsonb_typeof(v_doc -> 'envelopes') = 'array'
                       then jsonb_array_length(v_doc -> 'envelopes') else 0 end;
  end if;

  return jsonb_build_object(
    'status', case when v_pending then 'pending' when v_found then 'available' else 'none' end,
    'mode', v_mode,
    'day', p_day,
    'available_modes', v_modes,
    'context_revision', case when v_found then r.context_revision end,
    'header', case when v_found then jsonb_build_object(
        'mode', r.mode, 'day', r.day, 'finality', r.finality, 'status', r.status,
        'availability_cutoff', r.availability_cutoff, 'generated_at', r.generated_at,
        'contract_version', r.contract_version, 'schema_version', r.schema_version,
        'policy_fingerprint', r.policy_fingerprint, 'input_fingerprint', r.input_fingerprint,
        'versions', r.versions, 'published_at', r.published_at) end,
    'document', v_doc,
    'envelope_tables', v_tables,
    'metric', p_metric,
    'document_bytes', case when v_found then r.document_bytes end,
    'stored_table_bytes', v_stored_table_bytes,
    'returned_table_bytes', v_table_bytes,
    'envelope_count', case when v_found then r.envelope_count end,
    'returned_envelope_count', v_returned,
    'pairing', jsonb_build_object(
        'snapshot_result_revision', v_snapshot,
        'context_scoring_result_revision', case when v_found then r.scoring_result_revision end,
        'consistent', v_found and (v_snapshot is not distinct from r.scoring_result_revision)),
    'job', case when v_job then jsonb_build_object(
        'pending', v_pending, 'dirty_at', jb.dirty_at, 'input_revision', jb.input_revision,
        'completed_revision', jb.completed_revision, 'dead_letter', jb.dead_letter,
        'leased', jb.lease_until is not null and jb.lease_until > pg_catalog.clock_timestamp(),
        'reasons', to_jsonb(jb.reasons)) end);
end $$;

-- Episodes, bouts, daily values and frozen references of one device and mode (default retrospective) over at
-- most 120 local days [p_from, p_to]. Items are the exact JSON the worker published (DailyValue,
-- ExertionBout, ChangeEpisode, FrozenReference), so they decode into the shared Swift types.
create or replace function public.physiology_context_history_read_v1(p_user uuid, p_device uuid, p_from date,
  p_to date, p_mode text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_mode text := coalesce(p_mode, 'retrospective');
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_user is null or p_device is null then
    raise exception 'invalid_arguments' using errcode = '22023';
  end if;
  if v_mode not in ('causal_live', 'retrospective') then
    raise exception 'invalid_mode' using errcode = '22023';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 119 then
    raise exception 'invalid_range' using errcode = '22023';
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = p_user) then
    raise exception 'account_retired' using errcode = '42501';
  end if;
  if not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'mode', v_mode, 'from', p_from, 'to', p_to,
    'days', (select coalesce(jsonb_agg(jsonb_build_object(
               'day', d.day, 'context_revision', d.context_revision, 'finality', d.finality, 'status', d.status,
               'availability_cutoff', d.availability_cutoff, 'generated_at', d.generated_at,
               'published_at', d.published_at, 'document_bytes', d.document_bytes,
               'scoring_result_revision', d.scoring_result_revision) order by d.day), '[]'::jsonb)
               from public.physiology_context_days d
              where d.user_id = p_user and d.device_id = p_device and d.mode = v_mode
                and d.superseded_by is null and d.day between p_from and p_to),
    'daily_values', (select coalesce(jsonb_agg(v.payload order by v.day, v.series_key collate "C",
                       v.regime_key collate "C"), '[]'::jsonb)
               from public.physiology_context_daily_values v
              where v.user_id = p_user and v.device_id = p_device and v.mode = v_mode
                and v.day between p_from and p_to),
    'bouts', (select coalesce(jsonb_agg(b.payload order by b.start_ts, b.bout_id collate "C"), '[]'::jsonb)
               from public.physiology_context_bouts b
              where b.user_id = p_user and b.device_id = p_device and b.mode = v_mode
                and b.day between p_from and p_to),
    'episodes', (select coalesce(jsonb_agg(x.payload order by x.start_day, x.episode_id collate "C"), '[]'::jsonb)
               from public.physiology_context_episodes x
              where x.user_id = p_user and x.device_id = p_device and x.mode = v_mode
                and x.start_day <= p_to and x.last_day >= p_from),
    'episodes_as_of', (select jsonb_build_object('day', max(x.as_of_day), 'context_revision', max(x.context_revision))
               from public.physiology_context_episodes x
              where x.user_id = p_user and x.device_id = p_device and x.mode = v_mode),
    'frozen_references', (select coalesce(jsonb_agg(f.payload order by f.series_key collate "C",
                       f.regime_key collate "C", f.version), '[]'::jsonb)
               from public.physiology_context_frozen_references f
              where f.user_id = p_user and f.device_id = p_device),
    'pending_days', (select count(*) from public.physiology_context_jobs q
              where q.user_id = p_user and q.device_id = p_device and q.mode = v_mode
                and q.day between p_from and p_to and q.completed_revision < q.input_revision
                and not q.dead_letter));
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 6. Service RPCs: exposure events (contracts.md §10)
-- ---------------------------------------------------------------------------------------------------------

-- Record one ExposureEventRevision for p_owner (the owner comes from the edge credential, never the body).
-- received_at is set here (server receipt = availability time); a client value is ignored.
--   revision >  current          saved: the revision is stored, current state replaced, affected days invalidated
--   revision == current, same    ignored (duplicate)
--   revision == current, differs rejected (revision_conflict)
--   revision <  current          ignored (duplicate) when that exact revision is stored, else rejected
--                                (stale_revision)
--   invalid                      rejected (invalid_<field>), nothing stored
-- Affected days (mirrors Swift Exposures.affectedDays), in the owner's zone, for every device of the owner: the
-- local days covering the CLOSED instant range [min(start) - 24 h, max(end) + 72 h] over the old and new revision,
-- with end = max(end, start + 1) for a point event. The end instant is included because Exposures.refs keeps an
-- event whose end is exactly 72 h before a measurement (support.start - occurred.end <= lookback). Clamped to
-- days <= the owner's today and the most recent 120 days.
-- Returns {status, event_id, revision, reason, received_at, invalidated_days}.
create or replace function public.record_exposure_event_v1(p_owner uuid, p_source uuid, p_event jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_reason text;
  v_id text;
  v_rev integer;
  cur public.exposure_events;
  v_has_current boolean;
  v_digest text;
  v_received bigint := extract(epoch from pg_catalog.clock_timestamp())::bigint;
  v_start bigint;
  v_end bigint;
  v_lo bigint;
  v_hi bigint;
  v_zone text;
  v_count integer := 0;
  v_row public.exposure_event_revisions;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_owner then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_owner is null or not exists (select 1 from auth.users u where u.id = p_owner) then
    raise exception 'invalid_owner' using errcode = '22023';
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = p_owner) then
    raise exception 'account_retired' using errcode = '42501';
  end if;
  if p_source is not null
     and (exists (select 1 from public.noop_app_installations i where i.source_id = p_source and i.user_id <> p_owner)
          or exists (select 1 from public.compute_account_sources c where c.source_id = p_source and c.user_id <> p_owner)) then
    raise exception 'source_owner_mismatch' using errcode = '42501';
  end if;

  v_reason := internal.exposure_event_invalid_reason(p_event);
  if v_reason is not null then
    return jsonb_build_object('status', 'rejected',
      'event_id', case when jsonb_typeof(p_event -> 'event_id') = 'string' then left(p_event ->> 'event_id', 128) end,
      'revision', internal.physiology_context_json_int(p_event -> 'revision'),
      'reason', v_reason, 'received_at', null, 'invalidated_days', 0);
  end if;
  v_id := p_event ->> 'event_id';
  v_rev := internal.physiology_context_json_int(p_event -> 'revision')::integer;
  v_start := internal.physiology_context_json_int(p_event #> '{occurred,start}');
  v_end := internal.physiology_context_json_int(p_event #> '{occurred,end}');
  v_digest := encode(pg_catalog.sha256(convert_to(concat_ws(E'\x1f',
    p_event ->> 'kind', p_event ->> 'label', v_start::text, v_end::text, p_event ->> 'time_precision',
    (p_event ->> 'recorded_at')::bigint::text, p_event ->> 'source', p_event ->> 'confirmation',
    coalesce(((p_event ->> 'dose_amount')::double precision)::text, ''), coalesce(p_event ->> 'dose_unit', ''),
    coalesce(p_event ->> 'dose_provenance', '')), 'UTF8')), 'hex');

  perform pg_advisory_xact_lock(hashtextextended('exposure-event:' || p_owner::text || ':' || v_id, 0));
  select * into cur from public.exposure_events x where x.owner = p_owner and x.event_id = v_id for update;
  v_has_current := found;
  if v_has_current and v_rev <= cur.revision then
    if exists (select 1 from public.exposure_event_revisions x
                where x.owner = p_owner and x.event_id = v_id and x.revision = v_rev and x.content_digest = v_digest) then
      return jsonb_build_object('status', 'ignored', 'event_id', v_id, 'revision', v_rev, 'reason', 'duplicate',
        'received_at', (select x.received_at from public.exposure_event_revisions x
                         where x.owner = p_owner and x.event_id = v_id and x.revision = v_rev),
        'invalidated_days', 0);
    end if;
    return jsonb_build_object('status', 'rejected', 'event_id', v_id, 'revision', v_rev,
      'reason', case when v_rev = cur.revision then 'revision_conflict' else 'stale_revision' end,
      'received_at', null, 'invalidated_days', 0);
  end if;

  insert into public.exposure_event_revisions (owner, event_id, revision, kind, label, occurred_start,
    occurred_end, time_precision, recorded_at, received_at, source, confirmation, dose_amount, dose_unit,
    dose_provenance, upload_source_id, content_digest)
  values (p_owner, v_id, v_rev, p_event ->> 'kind', p_event ->> 'label', v_start, v_end,
    p_event ->> 'time_precision', (p_event ->> 'recorded_at')::bigint, v_received, p_event ->> 'source',
    p_event ->> 'confirmation', (p_event ->> 'dose_amount')::double precision, p_event ->> 'dose_unit',
    p_event ->> 'dose_provenance', p_source, v_digest)
  returning * into v_row;

  insert into public.exposure_events as x (owner, event_id, revision, kind, label, occurred_start, occurred_end,
    time_precision, recorded_at, received_at, source, confirmation, dose_amount, dose_unit, dose_provenance,
    content_digest, revision_count, first_received_at, updated_at)
  values (p_owner, v_id, v_rev, v_row.kind, v_row.label, v_start, v_end, v_row.time_precision, v_row.recorded_at,
    v_received, v_row.source, v_row.confirmation, v_row.dose_amount, v_row.dose_unit, v_row.dose_provenance,
    v_digest, 1, v_received, pg_catalog.clock_timestamp())
  on conflict (owner, event_id) do update set
    revision = excluded.revision, kind = excluded.kind, label = excluded.label,
    occurred_start = excluded.occurred_start, occurred_end = excluded.occurred_end,
    time_precision = excluded.time_precision, recorded_at = excluded.recorded_at,
    received_at = excluded.received_at, source = excluded.source, confirmation = excluded.confirmation,
    dose_amount = excluded.dose_amount, dose_unit = excluded.dose_unit, dose_provenance = excluded.dose_provenance,
    content_digest = excluded.content_digest, revision_count = x.revision_count + 1,
    updated_at = excluded.updated_at;

  v_lo := case when v_has_current then least(v_start, cur.occurred_start) else v_start end;
  v_hi := case when v_has_current
               then greatest(greatest(v_end, v_start + 1), greatest(cur.occurred_end, cur.occurred_start + 1))
               else greatest(v_end, v_start + 1) end;
  v_zone := internal.physiology_context_zone(p_owner);
  v_count := internal.physiology_context_invalidate(p_owner, null,
    (to_timestamp(v_lo - 86400) at time zone v_zone)::date,
    (to_timestamp(v_hi + 259200) at time zone v_zone)::date,
    'exposure_changed');
  return jsonb_build_object('status', 'saved', 'event_id', v_id, 'revision', v_rev, 'reason', null,
    'received_at', v_received, 'invalidated_days', v_count);
end $$;

-- Current exposure events of p_owner whose occurrence overlaps [p_from, p_to) (unix seconds, at most 366 days,
-- at most 2000 events, earliest first), each as ExposureEventRevision JSON plus revision_count; with
-- p_include_history also every stored revision of those events.
-- Returns {events: [...], revisions: [...] (only with history), truncated}.
create or replace function public.exposure_events_read_v1(p_owner uuid, p_from bigint, p_to bigint,
  p_include_history boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_events jsonb;
  v_ids text[];
  v_total integer;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_owner then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_owner is null or p_from is null or p_to is null or p_to <= p_from or p_to - p_from > 366 * 86400 then
    raise exception 'invalid_range' using errcode = '22023';
  end if;
  if exists (select 1 from public.noop_account_retirements x where x.user_id = p_owner) then
    raise exception 'account_retired' using errcode = '42501';
  end if;
  select count(*)::integer into v_total from public.exposure_events e
   where e.owner = p_owner and e.occurred_start < p_to and e.occurred_end > p_from
     and e.occurred_start > p_from - 2678400;
  select coalesce(jsonb_agg(t.item order by t.occurred_start, t.event_id collate "C"), '[]'::jsonb),
         coalesce(array_agg(t.event_id), '{}'::text[])
    into v_events, v_ids
    from (select e.occurred_start, e.event_id,
                 jsonb_build_object(
                   'event_id', e.event_id, 'revision', e.revision, 'kind', e.kind, 'label', e.label,
                   'occurred', jsonb_build_object('start', e.occurred_start, 'end', e.occurred_end),
                   'time_precision', e.time_precision, 'recorded_at', e.recorded_at, 'received_at', e.received_at,
                   'source', e.source, 'confirmation', e.confirmation, 'dose_amount', e.dose_amount,
                   'dose_unit', e.dose_unit, 'dose_provenance', e.dose_provenance,
                   'revision_count', e.revision_count) as item
            from public.exposure_events e
           where e.owner = p_owner and e.occurred_start < p_to and e.occurred_end > p_from
             and e.occurred_start > p_from - 2678400
           order by e.occurred_start, e.event_id collate "C"
           limit 2000) t;
  return jsonb_build_object(
    'events', v_events,
    'revisions', case when coalesce(p_include_history, false) then (
        select coalesce(jsonb_agg(internal.exposure_revision_json(x) order by x.event_id collate "C", x.revision),
                        '[]'::jsonb)
          from public.exposure_event_revisions x
         where x.owner = p_owner and x.event_id = any (v_ids)) end,
    'truncated', v_total > 2000);
end $$;

-- ---------------------------------------------------------------------------------------------------------
-- 7. Triggers
-- ---------------------------------------------------------------------------------------------------------

drop trigger if exists physiology_context_frozen_reference_immutable on public.physiology_context_frozen_references;
create trigger physiology_context_frozen_reference_immutable
  before update on public.physiology_context_frozen_references
  for each row execute function internal.physiology_context_reject_update();

drop trigger if exists exposure_event_revision_immutable on public.exposure_event_revisions;
create trigger exposure_event_revision_immutable
  before update on public.exposure_event_revisions
  for each row execute function internal.physiology_context_reject_update();

drop trigger if exists physiology_context_placement_changed on public.placement_intervals;
create trigger physiology_context_placement_changed
  after insert or update of placement, source, effective_start, effective_end on public.placement_intervals
  for each row execute function internal.physiology_context_placement_changed();

-- ---------------------------------------------------------------------------------------------------------
-- 8. Function privileges: service role only; helpers nobody but their owner
-- ---------------------------------------------------------------------------------------------------------

revoke all on function internal.physiology_context_zone(uuid) from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_today(uuid) from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_json_int(jsonb) from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_parse_day(text) from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_is_key(jsonb, integer) from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_merge_reasons(text[], text) from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_dependency_fingerprint(uuid, uuid, date)
  from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_touch(uuid, uuid, date, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_invalidate(uuid, uuid, date, date, text)
  from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_reject_update() from public, anon, authenticated, service_role;
revoke all on function internal.physiology_context_placement_changed() from public, anon, authenticated, service_role;
revoke all on function internal.exposure_event_invalid_reason(jsonb) from public, anon, authenticated, service_role;
revoke all on function internal.exposure_revision_json(public.exposure_event_revisions)
  from public, anon, authenticated, service_role;

revoke all on function public.enqueue_physiology_context_days_v1(integer) from public, anon, authenticated;
revoke all on function public.invalidate_physiology_context_span_v1(uuid, uuid, date, date, text)
  from public, anon, authenticated;
revoke all on function public.claim_physiology_context_v1(text, integer) from public, anon, authenticated;
revoke all on function public.renew_physiology_context_v1(uuid, integer) from public, anon, authenticated;
revoke all on function public.fail_physiology_context_v1(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.publish_physiology_context_v1(uuid, bigint, jsonb) from public, anon, authenticated;
revoke all on function public.physiology_context_read_v1(uuid, uuid, date, text, text) from public, anon, authenticated;
revoke all on function public.physiology_context_history_read_v1(uuid, uuid, date, date, text)
  from public, anon, authenticated;
revoke all on function public.record_exposure_event_v1(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.exposure_events_read_v1(uuid, bigint, bigint, boolean) from public, anon, authenticated;

grant execute on function public.enqueue_physiology_context_days_v1(integer) to service_role;
grant execute on function public.invalidate_physiology_context_span_v1(uuid, uuid, date, date, text) to service_role;
grant execute on function public.claim_physiology_context_v1(text, integer) to service_role;
grant execute on function public.renew_physiology_context_v1(uuid, integer) to service_role;
grant execute on function public.fail_physiology_context_v1(uuid, bigint, text) to service_role;
grant execute on function public.publish_physiology_context_v1(uuid, bigint, jsonb) to service_role;
grant execute on function public.physiology_context_read_v1(uuid, uuid, date, text, text) to service_role;
grant execute on function public.physiology_context_history_read_v1(uuid, uuid, date, date, text) to service_role;
grant execute on function public.record_exposure_event_v1(uuid, uuid, jsonb) to service_role;
grant execute on function public.exposure_events_read_v1(uuid, bigint, bigint, boolean) to service_role;

-- ---------------------------------------------------------------------------------------------------------
-- 9. Comments
-- ---------------------------------------------------------------------------------------------------------

comment on table public.physiology_context_jobs is
  'Physiology context queue: one job per (user, device, local day, mode). Fenced like scoring_jobs_v2 (input_revision/completed_revision, lease token, backoff, dead letter at 8). Service role only.';
comment on table public.physiology_context_days is
  'One immutable physiology context summary document per published revision of (user, device, local day, mode); its envelopes are in physiology_context_envelope_tables. superseded_by IS NULL marks the current row; a superseded row is deleted (with its tables) once superseded for 24 h. Written only by publish_physiology_context_v1.';
comment on table public.physiology_context_envelope_tables is
  'One interned EnvelopeTable (PCStoredDocument.swift, pc-wire-1) per metric of a published physiology context revision; deleted with its day row. Rebuild a document with StoredDocument.join(summary:tables:).';
comment on table public.physiology_context_daily_values is
  'Current context-conditioned daily values (DailyValue JSON in payload) per (user, device, mode, day, series, regime); replaced on each publish of the day. History source for references.';
comment on table public.physiology_context_bouts is
  'Current exertion bouts (ExertionBout JSON in payload) per (user, device, mode, bout id); replaced for the owning day on publish.';
comment on table public.physiology_context_episodes is
  'Current change episodes (ChangeEpisode JSON in payload) per (user, device, mode); replaced only by a publish of the latest published day or a newer one (as_of_day).';
comment on table public.physiology_context_frozen_references is
  'Explicitly versioned historical references (FrozenReference JSON in payload). Insert-only; UPDATE is rejected by a trigger; rows go only with the account or device.';
comment on table public.exposure_event_revisions is
  'Immutable exposure event revisions (ExposureEventRevision). received_at is the server receipt (availability). UPDATE is rejected by a trigger; rows go only with the account.';
comment on table public.exposure_events is
  'Current state (latest stored revision) of each exposure event per owner; revision_count counts stored revisions. Written only by record_exposure_event_v1.';
comment on function public.publish_physiology_context_v1(uuid, bigint, jsonb) is
  'Fenced, idempotent publication of one physiology context day (contracts.md §6). Returns {applied, context_revision, reason, cascaded_days, ...}.';
comment on function public.physiology_context_read_v1(uuid, uuid, date, text, text) is
  'One device-day context read for the scores edge route: {status, mode, context_revision, header, document, pairing, job, ...}.';

commit;
