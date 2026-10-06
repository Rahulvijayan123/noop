-- Inertia-1 motion heads, SHADOW / CANDIDATE storage (Tools/ActivityContext/INERTIA1.md §8, spec §24 stages 1-2).
-- One row per (owner, device, UTC day, head bundle, mode): the bundle's provenance, compact per-window head
-- predictions, OOD counts and, in candidate mode, a second decode of the day with Inertia as decoder evidence
-- (or why that was withheld).
--
-- Additive only: a new table, a new sequence, ONE new fenced publish function and a retention function.
-- Nothing here changes the activity job queue, activity_context_epochs, activity_context_days, their publish
-- functions or the read surface, and nothing reads this table for scoring or display: the published activity
-- documents are untouched whether the worker has Inertia enabled or not. Rollback = disable Inertia in the
-- worker (FRWHOOP_INERTIA_ENABLED unset); the table can stay.
--
-- Size: the per-window predictions are stored columnar in small integers (`mh-col-1`: per head the top-class
-- index and its probability in percent, an OOD flag, start deltas), about 0.5 MB per full day per bundle at a
-- 5-s hop, at most 1 MiB; `prune_activity_motion_heads_days` deletes rows older than 30 days (the worker calls
-- it every few hours while Inertia is on).
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table public.activity_motion_heads_days (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  -- The head bundle id (`heads_version`) and the worker mode that wrote the row.
  bundle_id text not null check (bundle_id ~ '^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$'),
  mode text not null check (mode in ('shadow', 'candidate')),
  algorithm_version text not null check (algorithm_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$'),
  encoder_id text not null check (encoder_id ~ '^[A-Za-z0-9][A-Za-z0-9._:+/@-]{0,159}$'),
  -- `inertia1` only for a pinned, real Inertia-1 checkpoint; everything else is a stand-in.
  encoder_kind text not null check (encoder_kind in ('inertia1', 'standin')),
  encoder_version text not null check (length(encoder_version) between 1 and 160),
  checkpoint_sha256 text check (checkpoint_sha256 is null or checkpoint_sha256 ~ '^[0-9a-f]{64}$'),
  bundle_sha256 text not null check (bundle_sha256 ~ '^[0-9a-f]{64}$'),
  preprocessing_version text not null check (preprocessing_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  heads_schema text not null check (heads_schema = 'motion-heads-1'),
  evidence_tier_max text not null check (evidence_tier_max in ('shadow', 'candidate', 'production')),
  job_fingerprint text not null check (job_fingerprint ~ '^[0-9a-f]{64}$'),
  input_revision bigint not null check (input_revision >= 1),
  window_s integer not null check (window_s in (10, 30)),
  hop_s integer not null check (hop_s in (1, 2, 5, 10, 15, 30) and hop_s <= window_s),
  n_windows integer not null check (n_windows between 0 and 100000),
  n_ood integer not null check (n_ood >= 0 and n_ood <= n_windows),
  n_dropped integer not null check (n_dropped >= 0),
  withheld_reason text check (withheld_reason is null or length(withheld_reason) between 1 and 240),
  summary jsonb not null check (jsonb_typeof(summary) = 'object'),
  -- Columnar per-window predictions (`mh-col-1`; null when they were larger than the worker's cap; the
  -- summary says so).
  -- `is not distinct from`, so a missing or null `format` is false, never NULL (a NULL check passes).
  windows jsonb check (windows is null or (jsonb_typeof(windows) = 'object'
                                           and (windows ->> 'format') is not distinct from 'mh-col-1')),
  -- Candidate mode only: the comparison ActivityContextDayDocument decoded with Inertia evidence. Never
  -- published, never copied into activity_context_days.
  candidate_document jsonb check (candidate_document is null or jsonb_typeof(candidate_document) = 'object'),
  result_revision bigint not null,
  created_at timestamptz not null default clock_timestamp(),
  computed_at timestamptz not null,
  primary key (user_id, device_id, day, bundle_id, mode),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (mode = 'candidate' or (candidate_document is null and withheld_reason is null)),
  check (mode = 'shadow' or ((candidate_document is null) <> (withheld_reason is null))),
  -- Only a real Inertia-1 encoder whose bundle reached the candidate tier can ever have shaped a comparison
  -- document: a stand-in (which the decoder refuses as evidence) never stores one, whatever writes the row.
  constraint activity_motion_heads_days_candidate_document_inertia1 check (candidate_document is null
    or (encoder_kind = 'inertia1' and mode = 'candidate' and evidence_tier_max in ('candidate', 'production')))
);
create sequence if not exists public.activity_motion_heads_days_result_revision_seq;
grant usage, select on sequence public.activity_motion_heads_days_result_revision_seq to service_role;

-- Worker-written, owner-readable (select only), the same shape as the other activity tables.
alter table public.activity_motion_heads_days enable row level security;
revoke all on public.activity_motion_heads_days from public, anon, authenticated;
grant all on public.activity_motion_heads_days to service_role;
grant select on public.activity_motion_heads_days to authenticated;
create policy activity_motion_heads_days_service on public.activity_motion_heads_days
  for all to service_role using (true) with check (true);
create policy activity_motion_heads_days_select_own on public.activity_motion_heads_days
  for select to authenticated using ((select auth.uid()) = user_id);

-- Fenced publication of one day's motion heads. Same fence as publish_activity_context_day: the lease must
-- be alive and the revision current, otherwise NULL and nothing is written. Like the day document it does
-- NOT complete the job, clear the lease or dirty scoring: the worker calls it in the same transaction,
-- after the day document and before the v1 publish, under a savepoint, so a rejection here can never block
-- either. A malformed payload raises a stable message and writes nothing.
-- Payload (written by Tools/CloudWorker ActivityMotionHeadsDays.payload):
--   {"day": "YYYY-MM-DD", "mode": "shadow"|"candidate", "schema": "motion-heads-1",
--    "bundle": {encoder_id, encoder_kind, encoder_version, checkpoint_sha256, heads_version, bundle_sha256,
--               preprocessing_version, evidence_tier_max, window_s, hop_s, bundle: {heads, ood[, fusion]}},
--    "summary": {n_windows, n_ood, n_dropped_nonfinite, ..., track_report}, "windows": <mh-col-1>|null,
--    "withheld_reason": text|null, "candidate_document": {...}|null}
-- mh-col-1: {"format": "mh-col-1", "n": n_windows, "w": window_s, "s0": first start|null,
--            "ds": [start deltas], "x": [0|1 OOD], "mi": [intensity %|-1],
--            "heads": {head: {"i": [top-class index|-1], "p": [its probability %]}}}, every array n long.
create function public.publish_activity_motion_heads_day(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.activity_context_jobs; b jsonb; sm jsonb; w jsonb; cd jsonb; v_mode text; withheld text;
  n_win integer; n_ood integer; n_drop integer; rev bigint; computed timestamptz; ck text; col text; h record;
begin
  select * into j from public.activity_context_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;

  if jsonb_typeof(p_payload) is distinct from 'object'
    or jsonb_typeof(p_payload -> 'day') is distinct from 'string'
    or (p_payload ->> 'day') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'invalid_motion_heads_payload';
  end if;
  if (p_payload ->> 'day')::date is distinct from j.day then
    raise exception 'invalid_motion_heads_payload';
  end if;
  if octet_length(p_payload::text) > 16 * 1024 * 1024 then
    raise exception 'invalid_motion_heads_size';
  end if;
  if p_payload ->> 'schema' is distinct from 'motion-heads-1' then
    raise exception 'invalid_motion_heads_schema';
  end if;
  v_mode := p_payload ->> 'mode';
  if jsonb_typeof(p_payload -> 'mode') is distinct from 'string' or v_mode not in ('shadow', 'candidate') then
    raise exception 'invalid_motion_heads_payload';
  end if;

  -- Provenance: plain identifiers only, and the tier / kind vocabulary of the contract.
  b := p_payload -> 'bundle';
  if jsonb_typeof(b) is distinct from 'object'
    or jsonb_typeof(b -> 'encoder_id') is distinct from 'string'
    or (b ->> 'encoder_id') !~ '^[A-Za-z0-9][A-Za-z0-9._:+/@-]{0,159}$'
    or (b ->> 'encoder_kind') is null or (b ->> 'encoder_kind') not in ('inertia1', 'standin')
    or jsonb_typeof(b -> 'encoder_version') is distinct from 'string'
    or length(b ->> 'encoder_version') not between 1 and 160
    or coalesce(jsonb_typeof(b -> 'checkpoint_sha256'), 'null') not in ('string', 'null')
    or jsonb_typeof(b -> 'heads_version') is distinct from 'string'
    or (b ->> 'heads_version') !~ '^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$'
    or jsonb_typeof(b -> 'bundle_sha256') is distinct from 'string'
    or (b ->> 'bundle_sha256') !~ '^[0-9a-f]{64}$'
    or jsonb_typeof(b -> 'preprocessing_version') is distinct from 'string'
    or (b ->> 'preprocessing_version') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    or (b ->> 'evidence_tier_max') is null
    or (b ->> 'evidence_tier_max') not in ('shadow', 'candidate', 'production')
    or not internal.activity_day_num_ok(b -> 'window_s', 10, 30, true)
    or not internal.activity_day_num_ok(b -> 'hop_s', 1, 30, true)
    or jsonb_typeof(b -> 'bundle') is distinct from 'object' then
    raise exception 'invalid_motion_heads_bundle';
  end if;
  -- Casts only after the types were proven (a separate statement, so no cast runs on an unchecked value).
  if (b ->> 'window_s')::integer not in (10, 30)
    or (b ->> 'hop_s')::integer not in (1, 2, 5, 10, 15, 30)
    or (b ->> 'hop_s')::integer > (b ->> 'window_s')::integer then
    raise exception 'invalid_motion_heads_bundle';
  end if;
  ck := b ->> 'checkpoint_sha256';
  if ck is not null and ck !~ '^[0-9a-f]{64}$' then raise exception 'invalid_motion_heads_bundle'; end if;
  -- A real Inertia-1 claim needs its checkpoint digest.
  if (b ->> 'encoder_kind') = 'inertia1' and ck is null then raise exception 'invalid_motion_heads_bundle'; end if;

  sm := p_payload -> 'summary';
  if jsonb_typeof(sm) is distinct from 'object'
    or not internal.activity_day_num_ok(sm -> 'n_windows', 0, 100000, true)
    or not internal.activity_day_num_ok(sm -> 'n_ood', 0, 100000, true)
    or not internal.activity_day_num_ok(sm -> 'n_dropped_nonfinite', 0, 10000000, true) then
    raise exception 'invalid_motion_heads_summary';
  end if;
  n_win := (sm ->> 'n_windows')::integer;
  n_ood := (sm ->> 'n_ood')::integer;
  n_drop := (sm ->> 'n_dropped_nonfinite')::integer;
  if n_ood > n_win then raise exception 'invalid_motion_heads_summary'; end if;

  -- Columnar windows (mh-col-1): every column exactly n_windows long, at most 1 MiB.
  w := p_payload -> 'windows';
  if coalesce(jsonb_typeof(w), 'null') not in ('object', 'null') then raise exception 'invalid_motion_heads_windows'; end if;
  if jsonb_typeof(w) = 'object' then
    if w ->> 'format' is distinct from 'mh-col-1'
      or octet_length(w::text) > 1024 * 1024
      or not internal.activity_day_num_ok(w -> 'n', 0, 100000, true)
      or not internal.activity_day_num_ok(w -> 'w', 10, 30, true)
      or jsonb_typeof(w -> 'heads') is distinct from 'object' then
      raise exception 'invalid_motion_heads_windows';
    end if;
    if (w ->> 'n')::integer <> n_win or (w ->> 'w')::integer <> (b ->> 'window_s')::integer then
      raise exception 'invalid_motion_heads_windows';
    end if;
    foreach col in array array['ds', 'x', 'mi'] loop
      if jsonb_typeof(w -> col) is distinct from 'array' or jsonb_array_length(w -> col) <> n_win then
        raise exception 'invalid_motion_heads_windows';
      end if;
    end loop;
    for h in select key, value from jsonb_each(w -> 'heads') loop
      if h.key not in ('posture', 'locomotion', 'arm_behavior', 'transition')
        or jsonb_typeof(h.value) is distinct from 'object'
        or jsonb_typeof(h.value -> 'i') is distinct from 'array' or jsonb_array_length(h.value -> 'i') <> n_win
        or jsonb_typeof(h.value -> 'p') is distinct from 'array' or jsonb_array_length(h.value -> 'p') <> n_win then
        raise exception 'invalid_motion_heads_windows';
      end if;
    end loop;
  else
    w := null;
  end if;

  withheld := case when jsonb_typeof(p_payload -> 'withheld_reason') = 'string' then p_payload ->> 'withheld_reason' end;
  if coalesce(jsonb_typeof(p_payload -> 'withheld_reason'), 'null') not in ('string', 'null')
    or (withheld is not null and length(withheld) not between 1 and 240) then
    raise exception 'invalid_motion_heads_candidate';
  end if;
  cd := p_payload -> 'candidate_document';
  if coalesce(jsonb_typeof(cd), 'null') not in ('object', 'null') then raise exception 'invalid_motion_heads_candidate'; end if;
  if jsonb_typeof(cd) is distinct from 'object' then cd := null; end if;
  -- Shadow rows carry neither; a candidate row carries exactly one of the comparison or its withheld reason,
  -- and a comparison document must name the Inertia evidence that shaped it.
  if v_mode = 'shadow' and (cd is not null or withheld is not null) then raise exception 'invalid_motion_heads_candidate'; end if;
  if v_mode = 'candidate' and ((cd is null) = (withheld is null)) then raise exception 'invalid_motion_heads_candidate'; end if;
  if cd is not null and (jsonb_typeof(cd -> 'versions') is distinct from 'object'
      or jsonb_typeof(cd -> 'versions' -> 'motion_heads') is distinct from 'string'
      or jsonb_typeof(cd -> 'runs') is distinct from 'array') then
    raise exception 'invalid_motion_heads_candidate';
  end if;
  -- Only a real Inertia-1 candidate bundle can have shaped a comparison (the table CHECK says the same).
  if cd is not null and ((b ->> 'encoder_kind') is distinct from 'inertia1'
      or (b ->> 'evidence_tier_max') not in ('candidate', 'production')) then
    raise exception 'invalid_motion_heads_candidate';
  end if;

  computed := clock_timestamp();
  rev := nextval('public.activity_motion_heads_days_result_revision_seq');
  insert into public.activity_motion_heads_days(user_id, device_id, day, bundle_id, mode, algorithm_version,
    encoder_id, encoder_kind, encoder_version, checkpoint_sha256, bundle_sha256, preprocessing_version,
    heads_schema, evidence_tier_max, job_fingerprint, input_revision, window_s, hop_s, n_windows, n_ood,
    n_dropped, withheld_reason, summary, windows, candidate_document, result_revision, computed_at)
  values(j.user_id, j.device_id, j.day, b ->> 'heads_version', v_mode, j.algorithm_version,
    b ->> 'encoder_id', b ->> 'encoder_kind', b ->> 'encoder_version', ck, b ->> 'bundle_sha256',
    b ->> 'preprocessing_version', 'motion-heads-1', b ->> 'evidence_tier_max', j.fingerprint, j.input_revision,
    (b ->> 'window_s')::integer, (b ->> 'hop_s')::integer, n_win, n_ood, n_drop, withheld, sm, w, cd,
    rev, computed)
  on conflict (user_id, device_id, day, bundle_id, mode) do update set
    algorithm_version = excluded.algorithm_version, encoder_id = excluded.encoder_id,
    encoder_kind = excluded.encoder_kind, encoder_version = excluded.encoder_version,
    checkpoint_sha256 = excluded.checkpoint_sha256, bundle_sha256 = excluded.bundle_sha256,
    preprocessing_version = excluded.preprocessing_version, heads_schema = excluded.heads_schema,
    evidence_tier_max = excluded.evidence_tier_max, job_fingerprint = excluded.job_fingerprint,
    input_revision = excluded.input_revision, window_s = excluded.window_s, hop_s = excluded.hop_s,
    n_windows = excluded.n_windows, n_ood = excluded.n_ood, n_dropped = excluded.n_dropped,
    withheld_reason = excluded.withheld_reason, summary = excluded.summary, windows = excluded.windows,
    candidate_document = excluded.candidate_document, result_revision = excluded.result_revision,
    computed_at = excluded.computed_at;
  return rev;
end $$;

revoke all on function public.publish_activity_motion_heads_day(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_activity_motion_heads_day(uuid, bigint, jsonb) to service_role;

-- Retention. Deletes at most p_max_rows rows whose computed_at is older than p_keep_days days (oldest first)
-- and returns how many it deleted. The worker calls it every few hours while Inertia is on
-- (ActivityLane.pruneMotionHeadsIfDue); a deployment without Inertia can run it from cron instead:
--   select public.prune_activity_motion_heads_days(30, 10000);
create function public.prune_activity_motion_heads_days(p_keep_days integer default 30,
                                                        p_max_rows integer default 10000)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if p_keep_days is null or p_keep_days < 1 or p_keep_days > 3650
    or p_max_rows is null or p_max_rows < 1 or p_max_rows > 1000000 then
    raise exception 'invalid_motion_heads_retention';
  end if;
  with doomed as (
    select ctid from public.activity_motion_heads_days
    where computed_at < clock_timestamp() - make_interval(days => p_keep_days)
    order by computed_at
    limit p_max_rows
  )
  delete from public.activity_motion_heads_days d using doomed where d.ctid = doomed.ctid;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.prune_activity_motion_heads_days(integer, integer) from public, anon, authenticated;
grant execute on function public.prune_activity_motion_heads_days(integer, integer) to service_role;

commit;
