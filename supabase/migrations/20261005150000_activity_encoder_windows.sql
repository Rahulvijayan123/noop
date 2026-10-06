-- HART encoder windows: the per-window output of the raw-IMU activity lane, kept so the phone's own
-- ActivityContext decoder (and the server's stream-day decoder) can read it.
--
-- The raw-IMU lane already infers 4 s windows (100 Hz IMU resampled to 30 Hz, HART) for every UTC day that
-- has rawImuSession objects, but it only stored them folded into 30 s v1 epochs and the v2 day document.
-- The phone decodes its own timeline from the strap streams and had no way to see the windows. This table
-- holds them, compactly, one row per (owner, device, UTC day, lineage); a republish replaces the row.
--
-- Additive. Nothing reads the table yet when this is applied, and the new publish function is only called
-- by a worker built from the same revision, so the order "migration, then worker" is safe; a worker that
-- predates it simply never writes the table.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- `windows` is the compact `hart-windows-1` document written by the worker (ActivityEncoderWindows.swift):
--   { "format": "hart-windows-1", "t0": <UTC day start>, "labels": [..., "unknown"],
--     "features": [feature keys], "s": [start - t0], "e": [end - t0], "l": [label index],
--     "p": [[probability per label, per mille]], "b": [1 when the heuristic baseline produced it],
--     "f": [[feature value or null, per feature key]] }
-- The parallel arrays all have `window_count` elements. Readers parse it defensively.
create table public.activity_encoder_windows (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  encoder_id text not null check (encoder_id ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  model_version text not null check (model_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  preprocessing_version text not null check (preprocessing_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  feature_schema text check (feature_schema is null or feature_schema ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  window_count integer not null check (window_count between 0 and 100000),
  first_ts bigint,
  last_ts bigint,
  windows jsonb not null check (jsonb_typeof(windows) = 'object'),
  result_revision bigint not null,
  computed_at timestamptz not null,
  primary key (user_id, device_id, day, algorithm_version),
  check ((first_ts is null) = (last_ts is null)),
  check (first_ts is null or first_ts <= last_ts),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade
);
create sequence if not exists public.activity_encoder_windows_result_revision_seq;
grant usage, select on sequence public.activity_encoder_windows_result_revision_seq to service_role;

-- Worker-written, owner-readable (select only), like the other activity tables. The app reads through
-- the scores edge route; the policy keeps any direct read scoped to the owner.
alter table public.activity_encoder_windows enable row level security;
revoke all on public.activity_encoder_windows from public, anon, authenticated;
grant all on public.activity_encoder_windows to service_role;
grant select on public.activity_encoder_windows to authenticated;
create policy activity_encoder_windows_service on public.activity_encoder_windows
  for all to service_role using (true) with check (true);
create policy activity_encoder_windows_select_own on public.activity_encoder_windows
  for select to authenticated using ((select auth.uid()) = user_id);

-- Fenced like publish_activity_context_day: the caller must hold the job's live lease at the revision it
-- computed, so a superseded run can never overwrite a newer one. Returns the new result revision, or NULL
-- when fenced. The shape checks are structural (types, equal array lengths, bounded size); every element is
-- validated by the readers, which drop what they cannot use.
create function public.publish_activity_encoder_windows(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.activity_context_jobs; w jsonb; n integer; day_lo bigint; rev bigint;
  lo bigint; hi bigint; encoder text; model text; pre text; schema text;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'windows') is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_activity_windows_payload';
  end if;
  if (p_payload ->> 'day')::date is distinct from j.day then raise exception 'invalid_activity_windows_payload'; end if;
  if octet_length(p_payload::text) > 24 * 1024 * 1024 then raise exception 'invalid_activity_windows_size'; end if;

  w := p_payload -> 'windows';
  day_lo := extract(epoch from (j.day::timestamp at time zone 'UTC'))::bigint;
  if (w ->> 'format') is distinct from 'hart-windows-1'
    or jsonb_typeof(w -> 't0') is distinct from 'number' or (w ->> 't0')::numeric <> day_lo
    or jsonb_typeof(w -> 'labels') is distinct from 'array'
    or jsonb_typeof(w -> 'features') is distinct from 'array'
    or jsonb_typeof(w -> 's') is distinct from 'array' or jsonb_typeof(w -> 'e') is distinct from 'array'
    or jsonb_typeof(w -> 'l') is distinct from 'array' or jsonb_typeof(w -> 'p') is distinct from 'array'
    or jsonb_typeof(w -> 'b') is distinct from 'array' or jsonb_typeof(w -> 'f') is distinct from 'array' then
    raise exception 'invalid_activity_windows_document';
  end if;
  n := jsonb_array_length(w -> 's');
  if n > 100000 or jsonb_array_length(w -> 'e') <> n or jsonb_array_length(w -> 'l') <> n
    or jsonb_array_length(w -> 'p') <> n or jsonb_array_length(w -> 'b') <> n
    or jsonb_array_length(w -> 'f') <> n then
    raise exception 'invalid_activity_windows_count';
  end if;

  encoder := coalesce(nullif(p_payload ->> 'encoder_id', ''), 'hart');
  model := left(coalesce(nullif(p_payload ->> 'model_version', ''), j.model_version), 96);
  pre := left(coalesce(nullif(p_payload ->> 'preprocessing_version', ''), j.preprocessing_version), 96);
  schema := nullif(p_payload ->> 'feature_schema', '');
  if n > 0 then
    lo := day_lo + (w -> 's' ->> 0)::bigint;
    hi := day_lo + (w -> 'e' ->> (n - 1))::bigint;
  end if;
  rev := nextval('public.activity_encoder_windows_result_revision_seq');

  insert into public.activity_encoder_windows(user_id, device_id, day, algorithm_version, encoder_id,
    model_version, preprocessing_version, feature_schema, job_fingerprint, input_revision, window_count,
    first_ts, last_ts, windows, result_revision, computed_at)
  values(j.user_id, j.device_id, j.day, j.algorithm_version, encoder, model, pre, schema, j.fingerprint,
    j.input_revision, n, lo, hi, w, rev, clock_timestamp())
  on conflict (user_id, device_id, day, algorithm_version) do update set
    encoder_id = excluded.encoder_id, model_version = excluded.model_version,
    preprocessing_version = excluded.preprocessing_version, feature_schema = excluded.feature_schema,
    job_fingerprint = excluded.job_fingerprint, input_revision = excluded.input_revision,
    window_count = excluded.window_count, first_ts = excluded.first_ts, last_ts = excluded.last_ts,
    windows = excluded.windows, result_revision = excluded.result_revision,
    computed_at = excluded.computed_at;
  return rev;
end $$;

revoke all on function public.publish_activity_encoder_windows(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_activity_encoder_windows(uuid, bigint, jsonb) to service_role;

commit;
