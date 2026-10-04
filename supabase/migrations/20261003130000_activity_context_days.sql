-- ActivityContext v2 day documents: one decoded, versioned document per (owner, device, UTC day,
-- algorithm), written by the activity lane next to the v1 epochs.
-- Additive only: a new table, a new sequence, two validation helpers and ONE new fenced function.
-- Nothing here changes publish_activity_context_v2, the job queue or activity_context_epochs, and
-- the table is not read by scoring, so the migration can be applied (and the worker upgraded) with
-- the activity lane already running.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- The document is the shared StrandAnalytics ActivityContextDayDocument (probabilistic posture /
-- locomotion / arm heads coalesced into runs, transition events, day summary). The scalar columns
-- repeat what operators and readers filter on; the document stays the source of truth.
-- One row per lineage: a republish for the same day replaces it, so readers never merge versions.
create table public.activity_context_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  schema_version integer not null check (schema_version >= 2),
  ontology_version text not null check (ontology_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  decoder_version text not null check (decoder_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  feature_schema text not null check (feature_schema ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  encoder_id text check (encoder_id is null or encoder_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  encoder_version text check (encoder_version is null or encoder_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  model_version text not null,
  preprocessing_version text not null,
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  context_fp text check (context_fp is null or context_fp ~ '^[0-9a-f]{1,16}$'),
  publish_interval_s integer not null check (publish_interval_s between 1 and 3600),
  observed_s integer not null check (observed_s between 0 and 86400),
  data_through bigint,
  run_count integer not null check (run_count >= 0),
  event_count integer not null check (event_count >= 0),
  unclear_s integer not null check (unclear_s >= 0),
  mean_confidence real not null check (mean_confidence >= 0 and mean_confidence <= 1),
  document jsonb not null check (jsonb_typeof(document) = 'object'),
  result_revision bigint not null,
  computed_at timestamptz not null,
  primary key (user_id, device_id, day, algorithm_version),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create sequence if not exists public.activity_context_days_result_revision_seq;
grant usage, select on sequence public.activity_context_days_result_revision_seq to service_role;

-- Worker-written, owner-readable (select only), same shape as the v1 tables. The app reads
-- through an edge route; the select policy keeps direct PostgREST reads scoped to the owner.
alter table public.activity_context_days enable row level security;
revoke all on public.activity_context_days from public, anon, authenticated;
grant all on public.activity_context_days to service_role;
grant select on public.activity_context_days to authenticated;
create policy activity_context_days_service on public.activity_context_days
  for all to service_role using (true) with check (true);
create policy activity_context_days_select_own on public.activity_context_days
  for select to authenticated using ((select auth.uid()) = user_id);

-- Validation helpers. They answer true/false and never raise, so the publish function can count
-- bad elements set-based and reject the whole document with one stable error. Checks run as
-- sequential statements: a cast only happens after the type of the value was proven.
create function internal.activity_day_num_ok(p_value jsonb, p_lo numeric, p_hi numeric, p_integer boolean)
returns boolean language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
  if jsonb_typeof(p_value) is distinct from 'number' then return false; end if;
  n := (p_value #>> '{}')::numeric;
  if p_integer and n <> trunc(n) then return false; end if;
  return n >= p_lo and n <= p_hi;
end $$;

create function internal.activity_day_run_valid(r jsonb, p_lo bigint, p_end bigint)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(r) is distinct from 'object' then return false; end if;
  if not internal.activity_day_num_ok(r -> 's', p_lo, p_end - 1, true) then return false; end if;
  if not internal.activity_day_num_ok(r -> 'e', p_lo + 1, p_end, true) then return false; end if;
  if (r ->> 'e')::numeric <= (r ->> 's')::numeric then return false; end if;
  if not internal.activity_day_num_ok(r -> 'n', 1, 100000, true) then return false; end if;
  if not internal.activity_day_num_ok(r -> 'overall_confidence', 0, 1, false) then return false; end if;
  if not internal.activity_day_num_ok(r -> 'overall_uncertainty', 0, 1, false) then return false; end if;
  if coalesce(jsonb_typeof(r -> 'intensity'), 'null') not in ('number', 'null') then return false; end if;
  if jsonb_typeof(r -> 'posture') is distinct from 'object'
    or jsonb_typeof(r -> 'locomotion') is distinct from 'object'
    or jsonb_typeof(r -> 'arm_behavior') is distinct from 'object' then return false; end if;
  if jsonb_typeof(r -> 'sleep') is distinct from 'string' or length(r ->> 'sleep') > 32 then return false; end if;
  if jsonb_typeof(r -> 'wear') is distinct from 'string' or length(r ->> 'wear') > 32 then return false; end if;
  if coalesce(jsonb_typeof(r -> 'display_context'), 'null') not in ('string', 'null')
    or length(coalesce(r ->> 'display_context', '')) > 64 then return false; end if;
  return true;
end $$;

create function internal.activity_day_event_valid(ev jsonb, p_lo bigint, p_end bigint)
returns boolean language plpgsql immutable set search_path = '' as $$
begin
  if jsonb_typeof(ev) is distinct from 'object' then return false; end if;
  if jsonb_typeof(ev -> 'kind') is distinct from 'string'
    or length(ev ->> 'kind') not between 1 and 64 then return false; end if;
  if not internal.activity_day_num_ok(ev -> 'probability', 0, 1, false) then return false; end if;
  return internal.activity_day_num_ok(ev -> 'ts', p_lo, p_end, true);
end $$;

revoke all on function internal.activity_day_num_ok(jsonb, numeric, numeric, boolean)
  from public, anon, authenticated, service_role;
revoke all on function internal.activity_day_run_valid(jsonb, bigint, bigint)
  from public, anon, authenticated, service_role;
revoke all on function internal.activity_day_event_valid(jsonb, bigint, bigint)
  from public, anon, authenticated, service_role;

-- Fenced publication of one day document. Same fence as publish_activity_context_v2: the lease
-- must be alive and the revision current, otherwise NULL and nothing is written. Unlike the v1
-- publish it does NOT complete the job, clear the lease or dirty scoring: the worker calls it in
-- the same transaction, before the v1 publish, so the pair commits or rolls back together and the
-- v1 publish keeps being the only thing that completes a job. A malformed document raises
-- (stable message, nothing written); the worker runs this call under a savepoint so a rejected v2
-- document can never block the v1 epochs.
-- Payload: {"day": "YYYY-MM-DD", "model_version": text?, "preprocessing_version": text?,
--           "document": <ActivityContextDayDocument JSON>}
create function public.publish_activity_context_day(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.activity_context_jobs; d jsonb; v jsonb; sm jsonb;
  day_lo bigint; day_end bigint; n_runs integer; n_events integer; n_bad bigint;
  rev bigint; computed timestamptz; stamp_model text; stamp_pre text; through bigint;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'document') is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_activity_day_payload';
  end if;
  if (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_activity_day_payload';
  end if;
  if octet_length(p_payload::text) > 16 * 1024 * 1024 then
    raise exception 'invalid_activity_day_size';
  end if;

  d := p_payload -> 'document';
  v := d -> 'versions';
  sm := d -> 'summary';
  day_lo := extract(epoch from (j.day::timestamp at time zone 'UTC'))::bigint;
  day_end := day_lo + 86400;

  if jsonb_typeof(v) is distinct from 'object'
    or jsonb_typeof(sm) is distinct from 'object'
    or jsonb_typeof(d -> 'runs') is distinct from 'array'
    or jsonb_typeof(d -> 'events') is distinct from 'array'
    or not internal.activity_day_num_ok(d -> 'schema_version', 2, 1000, true)
    or not internal.activity_day_num_ok(d -> 'day_start', day_lo, day_lo, true)
    or not internal.activity_day_num_ok(d -> 'day_end', day_end, day_end, true)
    or not internal.activity_day_num_ok(d -> 'publish_interval_s', 1, 3600, true)
    or not internal.activity_day_num_ok(d -> 'observed_s', 0, 86400, true)
    or not internal.activity_day_num_ok(d -> 'generated_at', 0, 4102444800, true)
    or not internal.activity_day_num_ok(sm -> 'unclear_s', 0, 86400, true)
    or not internal.activity_day_num_ok(sm -> 'mean_confidence', 0, 1, false)
    or jsonb_typeof(sm -> 'label_s') is distinct from 'object'
    or coalesce(jsonb_typeof(d -> 'data_through'), 'null') not in ('number', 'null')
    or coalesce(jsonb_typeof(d -> 'context_fp'), 'null') not in ('string', 'null')
    or coalesce(jsonb_typeof(d -> 'latest'), 'null') not in ('object', 'null') then
    raise exception 'invalid_activity_day_document';
  end if;
  -- Version stamps decide whether a reader can use the document, so they must be plain identifiers
  -- and the schema stamp inside `versions` must agree with the document's own.
  if jsonb_typeof(v -> 'ontology') is distinct from 'string' or (v ->> 'ontology') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
    or jsonb_typeof(v -> 'decoder') is distinct from 'string' or (v ->> 'decoder') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
    or jsonb_typeof(v -> 'feature_schema') is distinct from 'string' or (v ->> 'feature_schema') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
    or (v ? 'schema' and (v -> 'schema') is distinct from (d -> 'schema_version'))
    or (coalesce(jsonb_typeof(v -> 'encoder'), 'null') not in ('string', 'null'))
    or (coalesce(jsonb_typeof(v -> 'encoder_version'), 'null') not in ('string', 'null'))
    or (v ->> 'encoder') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
    or (v ->> 'encoder_version') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'
    or (d ->> 'context_fp') !~ '^[0-9a-f]{1,16}$' then
    raise exception 'invalid_activity_day_versions';
  end if;
  if coalesce(jsonb_typeof(d -> 'data_through'), 'null') = 'number'
    and not internal.activity_day_num_ok(d -> 'data_through', day_lo, day_end, true) then
    raise exception 'invalid_activity_day_document';
  end if;

  n_runs := jsonb_array_length(d -> 'runs');
  n_events := jsonb_array_length(d -> 'events');
  if n_runs > 20000 or n_events > 10000 then raise exception 'invalid_activity_day_count'; end if;
  select count(*) into n_bad from jsonb_array_elements(d -> 'runs') as t(r)
    where not internal.activity_day_run_valid(r, day_lo, day_end);
  if n_bad > 0 then raise exception 'invalid_activity_day_run'; end if;
  select count(*) into n_bad from jsonb_array_elements(d -> 'events') as t(ev)
    where not internal.activity_day_event_valid(ev, day_lo, day_end);
  if n_bad > 0 then raise exception 'invalid_activity_day_event'; end if;

  computed := clock_timestamp();
  stamp_model := left(coalesce(nullif(p_payload ->> 'model_version', ''), j.model_version), 96);
  stamp_pre := left(coalesce(nullif(p_payload ->> 'preprocessing_version', ''), j.preprocessing_version), 96);
  through := case when jsonb_typeof(d -> 'data_through') = 'number' then (d ->> 'data_through')::bigint end;
  rev := nextval('public.activity_context_days_result_revision_seq');

  insert into public.activity_context_days(user_id, device_id, day, algorithm_version, schema_version,
    ontology_version, decoder_version, feature_schema, encoder_id, encoder_version,
    model_version, preprocessing_version, job_fingerprint, input_revision, context_fp,
    publish_interval_s, observed_s, data_through, run_count, event_count, unclear_s, mean_confidence,
    document, result_revision, computed_at)
  values(j.user_id, j.device_id, j.day, j.algorithm_version, (d ->> 'schema_version')::integer,
    v ->> 'ontology', v ->> 'decoder', v ->> 'feature_schema', v ->> 'encoder', v ->> 'encoder_version',
    stamp_model, stamp_pre, j.fingerprint, j.input_revision, d ->> 'context_fp',
    (d ->> 'publish_interval_s')::integer, (d ->> 'observed_s')::integer, through,
    n_runs, n_events, (sm ->> 'unclear_s')::integer, (sm ->> 'mean_confidence')::real,
    d, rev, computed)
  on conflict (user_id, device_id, day, algorithm_version) do update set
    schema_version = excluded.schema_version, ontology_version = excluded.ontology_version,
    decoder_version = excluded.decoder_version, feature_schema = excluded.feature_schema,
    encoder_id = excluded.encoder_id, encoder_version = excluded.encoder_version,
    model_version = excluded.model_version, preprocessing_version = excluded.preprocessing_version,
    job_fingerprint = excluded.job_fingerprint, input_revision = excluded.input_revision,
    context_fp = excluded.context_fp, publish_interval_s = excluded.publish_interval_s,
    observed_s = excluded.observed_s, data_through = excluded.data_through,
    run_count = excluded.run_count, event_count = excluded.event_count,
    unclear_s = excluded.unclear_s, mean_confidence = excluded.mean_confidence,
    document = excluded.document, result_revision = excluded.result_revision,
    computed_at = excluded.computed_at;
  return rev;
end $$;

revoke all on function public.publish_activity_context_day(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_activity_context_day(uuid, bigint, jsonb) to service_role;

commit;
