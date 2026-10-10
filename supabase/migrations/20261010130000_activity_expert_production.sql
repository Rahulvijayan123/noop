-- Activity expert PRODUCTION release (docs/model-integration/activity-authority.md).
--
-- 1. The two expert tables (ElderNet gait windows, Inertia / ActiNet motion heads) accept `mode = 'production'`.
--    A production row, like a shadow row, carries neither a candidate decode document nor a withheld reason (the
--    existing `<table>_check2` already says so); only a candidate row carries exactly one of them. The release a
--    row reads as is still never above its own mode: shadow, its mode, or candidate for a production row whose
--    producer's authority block lowered it there.
-- 2. `internal.activity_expert_release`: a production row without a block, or whose block says production, is
--    production; a block saying candidate lowers it to candidate; anything else shadow. Candidate rows unchanged.
--    Motion heads additionally cap at the bundle's evaluated tier: a candidate-tier bundle is at most candidate
--    (a stand-in or a shadow-tier bundle stays shadow, as before).
-- 3. The two publish functions are replaced by verbatim copies that accept `mode: production` (production rows
--    must carry neither a comparison document nor a withheld reason; the same exception names as shadow).
--    `publish_activity_motion_heads_day` also stores the validated payload bundle object in the new nullable
--    `activity_motion_heads_days.bundle_info`, so a reader can rebuild the decoder evidence (MotionHeadsBundleInfo,
--    its nested `bundle` manifest included). Older rows keep `bundle_info` null.
--
-- Constraint + function swap and one new nullable column; no data is rewritten and every existing row satisfies
-- the new checks. `activity_candidate_days` is untouched. Rollback = run the worker in shadow / candidate mode;
-- the columns and the looser checks can stay.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. Mode, payload and release checks ------------------------------------------------------------------------

alter table public.activity_gait_windows_days
  drop constraint if exists activity_gait_windows_days_mode_check,
  drop constraint if exists activity_gait_windows_days_mode_allowed,
  add constraint activity_gait_windows_days_mode_allowed
    check (mode in ('shadow', 'candidate', 'production')),
  drop constraint if exists activity_gait_windows_days_check3,
  drop constraint if exists activity_gait_windows_days_candidate_one_of,
  add constraint activity_gait_windows_days_candidate_one_of
    check (mode <> 'candidate' or ((candidate_document is null) <> (withheld_reason is null))),
  drop constraint if exists activity_gait_windows_days_release_mode_check,
  drop constraint if exists activity_gait_windows_days_release_not_above_mode,
  add constraint activity_gait_windows_days_release_not_above_mode
    check (release_mode is null or release_mode = 'shadow' or release_mode = mode
           or (mode = 'production' and release_mode = 'candidate'));

alter table public.activity_motion_heads_days
  drop constraint if exists activity_motion_heads_days_mode_check,
  drop constraint if exists activity_motion_heads_days_mode_allowed,
  add constraint activity_motion_heads_days_mode_allowed
    check (mode in ('shadow', 'candidate', 'production')),
  drop constraint if exists activity_motion_heads_days_check3,
  drop constraint if exists activity_motion_heads_days_candidate_one_of,
  add constraint activity_motion_heads_days_candidate_one_of
    check (mode <> 'candidate' or ((candidate_document is null) <> (withheld_reason is null))),
  drop constraint if exists activity_motion_heads_days_release_mode_check,
  drop constraint if exists activity_motion_heads_days_release_not_above_mode,
  add constraint activity_motion_heads_days_release_not_above_mode
    check (release_mode is null or release_mode = 'shadow' or release_mode = mode
           or (mode = 'production' and release_mode = 'candidate'));

-- The payload's bundle object as validated by the publish function (null on rows written before this migration).
alter table public.activity_motion_heads_days
  add column if not exists bundle_info jsonb;
alter table public.activity_motion_heads_days
  drop constraint if exists activity_motion_heads_days_bundle_info_check,
  add constraint activity_motion_heads_days_bundle_info_check
    check (bundle_info is null or jsonb_typeof(bundle_info) = 'object');

-- 2. Release ---------------------------------------------------------------------------------------------------

-- The release of a row: its mode, lowered (never raised) by the producer's block. A block whose release is
-- missing or unknown lowers to shadow.
create or replace function internal.activity_expert_release(p_mode text, p_authority jsonb)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_mode = 'candidate' then case
      when p_authority is null then 'candidate'
      when p_authority ->> 'release_mode' in ('candidate', 'production') then 'candidate'
      else 'shadow'
    end
    when p_mode = 'production' then case
      when p_authority is null then 'production'
      when p_authority ->> 'release_mode' = 'production' then 'production'
      when p_authority ->> 'release_mode' = 'candidate' then 'candidate'
      else 'shadow'
    end
    else 'shadow'
  end
$$;
revoke all on function internal.activity_expert_release(text, jsonb) from public, anon, authenticated, service_role;

-- Motion heads: a stand-in encoder or a bundle evaluated only to the shadow tier is shadow whatever the mode, and
-- a bundle evaluated to the candidate tier is at most candidate (the same lowering as
-- ActivityExpertSelection.motionRelease).
create or replace function internal.activity_motion_heads_authority()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.authority := case when jsonb_typeof(new.summary -> 'authority') = 'object' then new.summary -> 'authority' end;
  new.release_mode := case
    when new.encoder_kind not in ('inertia1', 'actinet') or new.evidence_tier_max = 'shadow' then 'shadow'
    else internal.activity_expert_release(new.mode, new.authority)
  end;
  if new.release_mode = 'production' and new.evidence_tier_max is distinct from 'production' then
    new.release_mode := 'candidate';
  end if;
  return new;
end $$;
revoke all on function internal.activity_motion_heads_authority() from public, anon, authenticated, service_role;

-- 3. Publish functions -----------------------------------------------------------------------------------------

-- Payload (written by Tools/CloudWorker ActivityGaitWindowsDays.payload): as 20261006090000, with
-- "mode": "shadow"|"candidate"|"production".
create or replace function public.publish_activity_gait_windows_day(p_token uuid, p_revision bigint, p_payload jsonb)
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
  if jsonb_typeof(p_payload -> 'mode') is distinct from 'string'
    or v_mode not in ('shadow', 'candidate', 'production') then
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
  -- Shadow and production rows carry neither; a candidate row carries exactly one of the comparison or its
  -- withheld reason, and a comparison document must name the gait evidence that shaped it.
  if v_mode in ('shadow', 'production') and (cd is not null or withheld is not null) then
    raise exception 'invalid_gait_windows_candidate';
  end if;
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

-- Payload (written by Tools/CloudWorker ActivityMotionHeadsDays.payload): as 20261007100000, with
-- "mode": "shadow"|"candidate"|"production"; the validated `bundle` object is stored whole in `bundle_info`.
create or replace function public.publish_activity_motion_heads_day(p_token uuid, p_revision bigint, p_payload jsonb)
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
  if jsonb_typeof(p_payload -> 'mode') is distinct from 'string'
    or v_mode not in ('shadow', 'candidate', 'production') then
    raise exception 'invalid_motion_heads_payload';
  end if;

  -- Provenance: plain identifiers only, and the tier / kind vocabulary of the contract.
  b := p_payload -> 'bundle';
  if jsonb_typeof(b) is distinct from 'object'
    or jsonb_typeof(b -> 'encoder_id') is distinct from 'string'
    or (b ->> 'encoder_id') !~ '^[A-Za-z0-9][A-Za-z0-9._:+/@-]{0,159}$'
    or (b ->> 'encoder_kind') is null or (b ->> 'encoder_kind') not in ('inertia1', 'actinet', 'standin')
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
  -- A pinned-encoder claim (inertia1 / actinet) needs its checkpoint digest.
  if (b ->> 'encoder_kind') in ('inertia1', 'actinet') and ck is null then raise exception 'invalid_motion_heads_bundle'; end if;

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
  -- Shadow and production rows carry neither; a candidate row carries exactly one of the comparison or its
  -- withheld reason, and a comparison document must name the Inertia evidence that shaped it.
  if v_mode in ('shadow', 'production') and (cd is not null or withheld is not null) then
    raise exception 'invalid_motion_heads_candidate';
  end if;
  if v_mode = 'candidate' and ((cd is null) = (withheld is null)) then raise exception 'invalid_motion_heads_candidate'; end if;
  if cd is not null and (jsonb_typeof(cd -> 'versions') is distinct from 'object'
      or jsonb_typeof(cd -> 'versions' -> 'motion_heads') is distinct from 'string'
      or jsonb_typeof(cd -> 'runs') is distinct from 'array') then
    raise exception 'invalid_motion_heads_candidate';
  end if;
  -- Only a pinned-encoder candidate bundle can have shaped a comparison (the table CHECK says the same).
  if cd is not null and ((b ->> 'encoder_kind') not in ('inertia1', 'actinet')
      or (b ->> 'evidence_tier_max') not in ('candidate', 'production')) then
    raise exception 'invalid_motion_heads_candidate';
  end if;

  computed := clock_timestamp();
  rev := nextval('public.activity_motion_heads_days_result_revision_seq');
  insert into public.activity_motion_heads_days(user_id, device_id, day, bundle_id, mode, algorithm_version,
    encoder_id, encoder_kind, encoder_version, checkpoint_sha256, bundle_sha256, preprocessing_version,
    heads_schema, evidence_tier_max, job_fingerprint, input_revision, window_s, hop_s, n_windows, n_ood,
    n_dropped, withheld_reason, summary, windows, candidate_document, bundle_info, result_revision, computed_at)
  values(j.user_id, j.device_id, j.day, b ->> 'heads_version', v_mode, j.algorithm_version,
    b ->> 'encoder_id', b ->> 'encoder_kind', b ->> 'encoder_version', ck, b ->> 'bundle_sha256',
    b ->> 'preprocessing_version', 'motion-heads-1', b ->> 'evidence_tier_max', j.fingerprint, j.input_revision,
    (b ->> 'window_s')::integer, (b ->> 'hop_s')::integer, n_win, n_ood, n_drop, withheld, sm, w, cd, b,
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
    candidate_document = excluded.candidate_document, bundle_info = excluded.bundle_info,
    result_revision = excluded.result_revision, computed_at = excluded.computed_at;
  return rev;
end $$;

revoke all on function public.publish_activity_motion_heads_day(uuid, bigint, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_activity_motion_heads_day(uuid, bigint, jsonb) to service_role;

commit;
