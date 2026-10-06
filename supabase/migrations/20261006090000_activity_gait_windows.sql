-- ElderNet gait quality, SHADOW / CANDIDATE storage (Tools/ActivityContext/ELDERNET.md §6).
-- One row per (owner, device, UTC day, model version, mode): the model's provenance (version, per-head weight
-- digests and their combined digest, upstream commit, preprocessing, threshold), compact per-window gait outputs,
-- counts and, in candidate mode, a second decode of the day with the ElderNet gait channel as decoder evidence (or
-- why that was withheld).
--
-- Additive only: a new table, a new sequence, ONE new fenced publish function and a retention function. Nothing
-- here changes the activity job queue, activity_context_epochs, activity_context_days, activity_encoder_windows,
-- activity_motion_heads_days, their publish functions or the read surface, and nothing reads this table for
-- scoring or display: the published activity documents are untouched whether the worker has ElderNet enabled or
-- not. Rollback = disable ElderNet in the worker (FRWHOOP_ELDERNET_ENABLED unset); the table can stay.
--
-- Why a table of its own rather than rows in activity_encoder_windows: that table is read by the phone (through the
-- scores route) and by the stream-day decoder as HART encoder evidence, keyed by (day, algorithm_version); a gait
-- row there would have to be filtered out by every existing reader. Here no existing reader can ever see it.
--
-- Size: the per-window outputs are stored columnar in small integers (`gait-windows-1`: gait probability per mille,
-- gait / pre-filter flags, and on gait windows speed cm/s, cadence steps/min, stride cm, regularity %, steps × 10),
-- about 0.45 MB per full day at a 5-s hop, at most 1 MiB; `prune_activity_gait_windows_days` deletes rows older
-- than 30 days (the worker calls it every few hours while ElderNet is on).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table public.activity_gait_windows_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  model_version text not null check (model_version ~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}$'),
  mode text not null check (mode in ('shadow', 'candidate')),
  algorithm_version text not null check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  model_id text not null check (model_id = 'eldernet'),
  -- sha256 per fine-tuned head as served, and their combined digest (what a deployment pins):
  -- sha256('eldernet-weights-1\n' || name=sha\n per head in name order).
  weights jsonb not null check (jsonb_typeof(weights) = 'object'),
  weights_digest text not null check (weights_digest ~ '^[0-9a-f]{64}$'),
  upstream_commit text not null check (upstream_commit ~ '^[0-9a-f]{7,40}$'),
  preprocessing_version text not null check (preprocessing_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  gait_schema text not null check (gait_schema = 'gait-quality-1'),
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  window_s integer not null check (window_s = 10),
  hop_s integer not null check (hop_s in (1, 2, 5, 10)),
  gait_threshold double precision not null check (gait_threshold > 0 and gait_threshold < 1),
  n_windows integer not null check (n_windows between 0 and 100000),
  n_gait integer not null check (n_gait >= 0 and n_gait <= n_windows),
  n_prefiltered integer not null check (n_prefiltered >= 0 and n_gait + n_prefiltered <= n_windows),
  n_dropped integer not null check (n_dropped >= 0),
  withheld_reason text check (withheld_reason is null or length(withheld_reason) between 1 and 240),
  summary jsonb not null check (jsonb_typeof(summary) = 'object'),
  -- Columnar per-window outputs (`gait-windows-1`; null when they were larger than the worker's cap; the summary
  -- says so).
  windows jsonb check (windows is null or (jsonb_typeof(windows) = 'object' and windows ->> 'format' = 'gait-windows-1')),
  -- Candidate mode only: the comparison ActivityContextDayDocument decoded with the gait channel. Never published,
  -- never copied into activity_context_days.
  candidate_document jsonb check (candidate_document is null or jsonb_typeof(candidate_document) = 'object'),
  result_revision bigint not null,
  created_at timestamptz not null default clock_timestamp(),
  computed_at timestamptz not null,
  primary key (user_id, device_id, day, model_version, mode),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (mode = 'candidate' or (candidate_document is null and withheld_reason is null)),
  check (mode = 'shadow' or ((candidate_document is null) <> (withheld_reason is null))),
  -- A comparison document always names the gait evidence that shaped it, whatever writes the row.
  constraint activity_gait_windows_days_candidate_stamped check (candidate_document is null
    or (mode = 'candidate' and jsonb_typeof(candidate_document -> 'versions' -> 'gait_quality') = 'string'))
);
create sequence if not exists public.activity_gait_windows_days_result_revision_seq;
grant usage, select on sequence public.activity_gait_windows_days_result_revision_seq to service_role;

-- Worker-written, owner-readable (select only), the same shape as the other activity tables.
alter table public.activity_gait_windows_days enable row level security;
revoke all on public.activity_gait_windows_days from public, anon, authenticated;
grant all on public.activity_gait_windows_days to service_role;
grant select on public.activity_gait_windows_days to authenticated;
create policy activity_gait_windows_days_service on public.activity_gait_windows_days
  for all to service_role using (true) with check (true);
create policy activity_gait_windows_days_select_own on public.activity_gait_windows_days
  for select to authenticated using ((select auth.uid()) = user_id);

-- Fenced publication of one day's gait windows. Same fence as publish_activity_context_day: the lease must be
-- alive and the revision current, otherwise NULL and nothing is written. Like the day document it does NOT
-- complete the job, clear the lease or dirty scoring: the worker calls it in the same transaction, after the day
-- document and the Inertia row and before the v1 publish, under a savepoint, so a rejection here can never block
-- any of them. A malformed payload raises a stable message and writes nothing.
-- Payload (written by Tools/CloudWorker ActivityGaitWindowsDays.payload):
--   {"day": "YYYY-MM-DD", "mode": "shadow"|"candidate", "schema": "gait-quality-1",
--    "model": {model_id, model_version, weights: {head: sha256}, upstream_commit, preprocessing_version,
--              window_s, hop_s, calibration, gait_threshold},
--    "weights_digest": sha256, "summary": {n_windows, n_gait, n_prefiltered, n_dropped_nonfinite, ..., track_report},
--    "windows": <gait-windows-1>|null, "withheld_reason": text|null, "candidate_document": {...}|null}
-- gait-windows-1: {"format": "gait-windows-1", "n": n_windows, "w": 10, "h": hop_s, "s0": first start|null,
--                  "ds": [start deltas], "gp": [gait prob ‰], "g": [0|1], "pf": [0|1], "sp": [cm/s|-1],
--                  "cad": [steps/min|-1], "st": [cm|-1], "rg": [%|-1], "stp": [steps × 10|-1]}, every array n long.
create function public.publish_activity_gait_windows_day(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.activity_context_jobs; m jsonb; sm jsonb; w jsonb; cd jsonb; v_mode text; withheld text;
  n_win integer; n_gait integer; n_pf integer; n_drop integer; rev bigint; computed timestamptz; col text;
  h record; canonical text; digest text;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_gait_windows_payload';
  end if;
  if (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_gait_windows_payload';
  end if;
  if octet_length(p_payload::text) > 16 * 1024 * 1024 then
    raise exception 'invalid_gait_windows_size';
  end if;
  if p_payload ->> 'schema' is distinct from 'gait-quality-1' then
    raise exception 'invalid_gait_windows_schema';
  end if;
  v_mode := p_payload ->> 'mode';
  if jsonb_typeof(p_payload -> 'mode') is distinct from 'string' or v_mode not in ('shadow', 'candidate') then
    raise exception 'invalid_gait_windows_payload';
  end if;

  -- Provenance: plain identifiers only, known heads with sha256 digests, the contract's window and threshold.
  m := p_payload -> 'model';
  if jsonb_typeof(m) is distinct from 'object'
    or m ->> 'model_id' is distinct from 'eldernet'
    or jsonb_typeof(m -> 'model_version') is distinct from 'string'
    or (m ->> 'model_version') !~ '^[A-Za-z0-9][A-Za-z0-9._:+-]{0,127}$'
    or jsonb_typeof(m -> 'weights') is distinct from 'object'
    or jsonb_typeof(m -> 'weights' -> 'gait_detection') is distinct from 'string'
    or jsonb_typeof(m -> 'upstream_commit') is distinct from 'string'
    or (m ->> 'upstream_commit') !~ '^[0-9a-f]{7,40}$'
    or jsonb_typeof(m -> 'preprocessing_version') is distinct from 'string'
    or (m ->> 'preprocessing_version') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    or not internal.activity_day_num_ok(m -> 'window_s', 10, 10, true)
    or not internal.activity_day_num_ok(m -> 'hop_s', 1, 10, true)
    or not internal.activity_day_num_ok(m -> 'gait_threshold', 0, 1, false)
    or coalesce(jsonb_typeof(m -> 'calibration'), 'null') not in ('object', 'null') then
    raise exception 'invalid_gait_windows_model';
  end if;
  -- Casts only after the types were proven (a separate statement, so no cast runs on an unchecked value).
  if (m ->> 'hop_s')::integer not in (1, 2, 5, 10)
    or (m ->> 'gait_threshold')::double precision <= 0 or (m ->> 'gait_threshold')::double precision >= 1 then
    raise exception 'invalid_gait_windows_model';
  end if;
  for h in select key, value from jsonb_each(m -> 'weights') loop
    if h.key not in ('gait_detection', 'gait_speed', 'gait_length', 'cadence', 'regularity', 'step_count')
      or jsonb_typeof(h.value) is distinct from 'string' or (h.value #>> '{}') !~ '^[0-9a-f]{64}$' then
      raise exception 'invalid_gait_windows_model';
    end if;
  end loop;
  -- The combined digest is recomputed here: a row can never name weights other than the ones it carries.
  select 'eldernet-weights-1' || chr(10) || string_agg(key || '=' || (value #>> '{}') || chr(10), '' order by key collate "C")
    into canonical from jsonb_each(m -> 'weights');
  digest := encode(sha256(convert_to(canonical, 'UTF8')), 'hex');
  if jsonb_typeof(p_payload -> 'weights_digest') is distinct from 'string'
    or (p_payload ->> 'weights_digest') is distinct from digest then
    raise exception 'invalid_gait_windows_model';
  end if;

  sm := p_payload -> 'summary';
  if jsonb_typeof(sm) is distinct from 'object'
    or not internal.activity_day_num_ok(sm -> 'n_windows', 0, 100000, true)
    or not internal.activity_day_num_ok(sm -> 'n_gait', 0, 100000, true)
    or not internal.activity_day_num_ok(sm -> 'n_prefiltered', 0, 100000, true)
    or not internal.activity_day_num_ok(sm -> 'n_dropped_nonfinite', 0, 10000000, true) then
    raise exception 'invalid_gait_windows_summary';
  end if;
  n_win := (sm ->> 'n_windows')::integer;
  n_gait := (sm ->> 'n_gait')::integer;
  n_pf := (sm ->> 'n_prefiltered')::integer;
  n_drop := (sm ->> 'n_dropped_nonfinite')::integer;
  if n_gait + n_pf > n_win then raise exception 'invalid_gait_windows_summary'; end if;

  -- Columnar windows (gait-windows-1): every column exactly n_windows long, at most 1 MiB.
  w := p_payload -> 'windows';
  if coalesce(jsonb_typeof(w), 'null') not in ('object', 'null') then raise exception 'invalid_gait_windows_windows'; end if;
  if jsonb_typeof(w) = 'object' then
    if w ->> 'format' is distinct from 'gait-windows-1'
      or octet_length(w::text) > 1024 * 1024
      or not internal.activity_day_num_ok(w -> 'n', 0, 100000, true)
      or not internal.activity_day_num_ok(w -> 'w', 10, 10, true)
      or not internal.activity_day_num_ok(w -> 'h', 1, 10, true) then
      raise exception 'invalid_gait_windows_windows';
    end if;
    if (w ->> 'n')::integer <> n_win or (w ->> 'h')::integer <> (m ->> 'hop_s')::integer then
      raise exception 'invalid_gait_windows_windows';
    end if;
    foreach col in array array['ds', 'gp', 'g', 'pf', 'sp', 'cad', 'st', 'rg', 'stp'] loop
      if jsonb_typeof(w -> col) is distinct from 'array' or jsonb_array_length(w -> col) <> n_win then
        raise exception 'invalid_gait_windows_windows';
      end if;
    end loop;
  else
    w := null;
  end if;

  withheld := case when jsonb_typeof(p_payload -> 'withheld_reason') = 'string' then p_payload ->> 'withheld_reason' end;
  if coalesce(jsonb_typeof(p_payload -> 'withheld_reason'), 'null') not in ('string', 'null')
    or (withheld is not null and length(withheld) not between 1 and 240) then
    raise exception 'invalid_gait_windows_candidate';
  end if;
  cd := p_payload -> 'candidate_document';
  if coalesce(jsonb_typeof(cd), 'null') not in ('object', 'null') then raise exception 'invalid_gait_windows_candidate'; end if;
  if jsonb_typeof(cd) is distinct from 'object' then cd := null; end if;
  -- Shadow rows carry neither; a candidate row carries exactly one of the comparison or its withheld reason, and a
  -- comparison document must name the gait evidence that shaped it.
  if v_mode = 'shadow' and (cd is not null or withheld is not null) then raise exception 'invalid_gait_windows_candidate'; end if;
  if v_mode = 'candidate' and ((cd is null) = (withheld is null)) then raise exception 'invalid_gait_windows_candidate'; end if;
  if cd is not null and (jsonb_typeof(cd -> 'versions') is distinct from 'object'
      or jsonb_typeof(cd -> 'versions' -> 'gait_quality') is distinct from 'string'
      or jsonb_typeof(cd -> 'runs') is distinct from 'array') then
    raise exception 'invalid_gait_windows_candidate';
  end if;

  computed := clock_timestamp();
  rev := nextval('public.activity_gait_windows_days_result_revision_seq');
  insert into public.activity_gait_windows_days(user_id, device_id, day, model_version, mode, algorithm_version,
    model_id, weights, weights_digest, upstream_commit, preprocessing_version, gait_schema, job_fingerprint,
    input_revision, window_s, hop_s, gait_threshold, n_windows, n_gait, n_prefiltered, n_dropped, withheld_reason,
    summary, windows, candidate_document, result_revision, computed_at)
  values(j.user_id, j.device_id, j.day, m ->> 'model_version', v_mode, j.algorithm_version, 'eldernet',
    m -> 'weights', digest, m ->> 'upstream_commit', m ->> 'preprocessing_version', 'gait-quality-1', j.fingerprint,
    j.input_revision, 10, (m ->> 'hop_s')::integer, (m ->> 'gait_threshold')::double precision, n_win, n_gait, n_pf,
    n_drop, withheld, sm, w, cd, rev, computed)
  on conflict (user_id, device_id, day, model_version, mode) do update set
    algorithm_version = excluded.algorithm_version, weights = excluded.weights,
    weights_digest = excluded.weights_digest, upstream_commit = excluded.upstream_commit,
    preprocessing_version = excluded.preprocessing_version, gait_schema = excluded.gait_schema,
    job_fingerprint = excluded.job_fingerprint, input_revision = excluded.input_revision,
    window_s = excluded.window_s, hop_s = excluded.hop_s, gait_threshold = excluded.gait_threshold,
    n_windows = excluded.n_windows, n_gait = excluded.n_gait, n_prefiltered = excluded.n_prefiltered,
    n_dropped = excluded.n_dropped, withheld_reason = excluded.withheld_reason, summary = excluded.summary,
    windows = excluded.windows, candidate_document = excluded.candidate_document,
    result_revision = excluded.result_revision, computed_at = excluded.computed_at;
  return rev;
end $$;

revoke all on function public.publish_activity_gait_windows_day(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_activity_gait_windows_day(uuid, bigint, jsonb) to service_role;

-- Retention. Deletes at most p_max_rows rows whose computed_at is older than p_keep_days days (oldest first) and
-- returns how many it deleted. The worker calls it every few hours while ElderNet is on
-- (ActivityLane.pruneGaitWindowsIfDue); a deployment without ElderNet can run it from cron instead:
--   select public.prune_activity_gait_windows_days(30, 10000);
create function public.prune_activity_gait_windows_days(p_keep_days integer default 30,
                                                        p_max_rows integer default 10000)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_keep_days is null or p_keep_days < 1 or p_keep_days > 3650
    or p_max_rows is null or p_max_rows < 1 or p_max_rows > 1000000 then
    raise exception 'invalid_gait_windows_retention';
  end if;
  with doomed as (
    select ctid from public.activity_gait_windows_days
    where computed_at < clock_timestamp() - make_interval(days => p_keep_days)
    order by computed_at
    limit p_max_rows
  )
  delete from public.activity_gait_windows_days d using doomed where d.ctid = doomed.ctid;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.prune_activity_gait_windows_days(integer, integer) from public, anon, authenticated;
grant execute on function public.prune_activity_gait_windows_days(integer, integer) to service_role;

commit;
