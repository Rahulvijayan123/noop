-- Motion heads: accept the pinned ActiNet encoder kind (Tools/ActivityContext/INERTIA1.md §4b).
-- `actinet` = ActiNet / ssl-wearables harnet30 weights pinned by sha256 in activity_context.inertia.registry; like
-- `inertia1` it needs its checkpoint digest and is the only other kind whose candidate bundle may shape a
-- comparison document. Stand-ins are unchanged. Constraint + function swap only; no data is rewritten.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.activity_motion_heads_days
  drop constraint activity_motion_heads_days_encoder_kind_check,
  add constraint activity_motion_heads_days_encoder_kind_check
    check (encoder_kind in ('inertia1', 'actinet', 'standin')),
  drop constraint activity_motion_heads_days_candidate_document_inertia1,
  add constraint activity_motion_heads_days_candidate_document_pinned check (candidate_document is null
    or (encoder_kind in ('inertia1', 'actinet') and mode = 'candidate'
        and evidence_tier_max in ('candidate', 'production')));

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
  if jsonb_typeof(p_payload -> 'mode') is distinct from 'string' or v_mode not in ('shadow', 'candidate') then
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
  -- Shadow rows carry neither; a candidate row carries exactly one of the comparison or its withheld reason,
  -- and a comparison document must name the Inertia evidence that shaped it.
  if v_mode = 'shadow' and (cd is not null or withheld is not null) then raise exception 'invalid_motion_heads_candidate'; end if;
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

commit;
