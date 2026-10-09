-- 20261009140100_anomaly_window_reason_codes.sql — canonical data reason codes on anomaly window rows.
--
-- Additive only. `anomaly_window_scores.withheld_reason` keeps the anomaly service's own short values (off_wrist,
-- low_hr_coverage, activity, recovery, context_unknown, calibrating); stored rows and readers depend on them. Each row
-- now also carries the canonical reason of contracts/reason-codes.json (`data-reason-1`): `reason_code` ("code" or
-- "code/subcode", e.g. context_not_comparable/recovery) and `reason_certainty` (confirmed | inferred | unknown |
-- measured). The service sends both (Tools/AnomalyService reasons.py); for a payload without them (a service
-- released before this change) publish maps withheld_reason through internal.anomaly_withheld_reason, the same
-- table as the contract's legacy.anomaly_withheld. Existing rows are not rewritten (the table is pruned after 30
-- days); a reader maps a row with a null reason_code from its withheld_reason the same way.
--
-- New withheld value `recovery`: the service now withholds a window that overlaps the recovery after an exercise
-- session (rule exercise-session-1); withheld_reason has no check constraint, so no constraint changes.
--
-- publish_anomaly_result_v1 is re-created with its signature, grants and behaviour unchanged except that it also
-- writes the two columns. Deploy order does not matter: an old service against this function gets the mapped
-- codes; the new service against the old function has its extra fields ignored.
--
-- Rollback: re-create publish_anomaly_result_v1 from 20261007180000_anomaly_service.sql, drop the function
-- internal.anomaly_withheld_reason(text) and the two columns.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table public.anomaly_window_scores add column if not exists reason_code text;
alter table public.anomaly_window_scores add column if not exists reason_certainty text;

do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.anomaly_window_scores'::regclass
                    and conname = 'anomaly_window_scores_reason_code_check') then
    alter table public.anomaly_window_scores add constraint anomaly_window_scores_reason_code_check
      check (reason_code is null or reason_code ~ '^[a-z][a-z_]{0,63}(/[a-z][a-z_]{0,63})?$');
  end if;
  if not exists (select 1 from pg_constraint where conrelid = 'public.anomaly_window_scores'::regclass
                    and conname = 'anomaly_window_scores_reason_certainty_check') then
    alter table public.anomaly_window_scores add constraint anomaly_window_scores_reason_certainty_check
      check (reason_certainty is null or reason_certainty in ('confirmed', 'inferred', 'unknown', 'measured'));
  end if;
end $$;

comment on column public.anomaly_window_scores.reason_code is
  'Canonical data reason (contracts/reason-codes.json data-reason-1) for withheld_reason: code or code/subcode.';
comment on column public.anomaly_window_scores.reason_certainty is
  'Certainty of reason_code: confirmed | inferred | unknown | measured.';

-- contracts/reason-codes.json legacy.anomaly_withheld (pinned by supabase/tests/anomaly_window_reason_codes.sql).
create or replace function internal.anomaly_withheld_reason(p_reason text, out code text, out certainty text)
language sql immutable set search_path = '' as $$
  select m.code, m.certainty
    from (values ('off_wrist', 'off_wrist', 'inferred'),
                 ('low_hr_coverage', 'insufficient_coverage', 'measured'),
                 ('activity', 'context_not_comparable/movement', 'inferred'),
                 ('recovery', 'context_not_comparable/recovery', 'inferred'),
                 ('context_unknown', 'context_unknown', 'unknown'),
                 ('calibrating', 'learning', 'measured')) m(reason, code, certainty)
   where m.reason = p_reason
$$;
revoke all on function internal.anomaly_withheld_reason(text) from public, anon, authenticated;

-- Fenced publish (20261007180000) + reason_code / reason_certainty on window rows.
create or replace function public.publish_anomaly_result_v1(p_token uuid, p_revision bigint, p_payload jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare j public.anomaly_jobs; c jsonb; w jsonb; v_from timestamptz; v_to timestamptz; keys text[] := '{}'; n bigint := 0;
  v_code text; v_certainty text;
begin
  select * into j from public.anomaly_jobs where lease_token = p_token for update;
  if not found or j.lease_until <= clock_timestamp() or j.input_revision <> p_revision then return null; end if;
  if jsonb_typeof(p_payload) is distinct from 'object'
     or jsonb_typeof(p_payload -> 'candidates') is distinct from 'array'
     or jsonb_typeof(p_payload -> 'window_scores') is distinct from 'array' then
    raise exception 'invalid_anomaly_payload';
  end if;
  if octet_length(p_payload::text) > 4194304 then raise exception 'invalid_anomaly_size'; end if;
  v_from := (p_payload ->> 'scored_from')::timestamptz;
  v_to := (p_payload ->> 'scored_to')::timestamptz;
  if v_from is null or v_to is null or v_to <= v_from then raise exception 'invalid_anomaly_range'; end if;

  for c in select * from jsonb_array_elements(p_payload -> 'candidates') loop
    keys := keys || (c ->> 'candidate_key');
    insert into public.anomaly_candidates as a (user_id, device_id, candidate_key, start_ts, end_ts, local_day, channels,
        flagged_by, model_p, score, severity, direction, expected, observed, context, quality, model_versions,
        status, suppressed_reason, input_fingerprint)
    values (j.user_id, j.device_id, c ->> 'candidate_key', (c ->> 'start_ts')::timestamptz, (c ->> 'end_ts')::timestamptz,
        (c ->> 'local_day')::date,
        array(select jsonb_array_elements_text(c -> 'channels')),
        coalesce(array(select jsonb_array_elements_text(c -> 'flagged_by')), '{}'::text[]),
        coalesce(c -> 'model_p', '{}'::jsonb), (c ->> 'score')::double precision, c ->> 'severity',
        (c ->> 'direction')::smallint, coalesce(c -> 'expected', '{}'::jsonb), coalesce(c -> 'observed', '{}'::jsonb),
        coalesce(c -> 'context', '{}'::jsonb), coalesce(c -> 'quality', '{}'::jsonb),
        coalesce(c -> 'model_versions', '{}'::jsonb), coalesce(c ->> 'status', 'candidate'),
        c ->> 'suppressed_reason', c ->> 'input_fingerprint')
    on conflict (user_id, device_id, candidate_key) do update set
        start_ts = excluded.start_ts, end_ts = excluded.end_ts, local_day = excluded.local_day,
        channels = excluded.channels, flagged_by = excluded.flagged_by, model_p = excluded.model_p,
        score = excluded.score, severity = excluded.severity, direction = excluded.direction,
        expected = excluded.expected, observed = excluded.observed, context = excluded.context,
        quality = excluded.quality, model_versions = excluded.model_versions, status = excluded.status,
        suppressed_reason = excluded.suppressed_reason, input_fingerprint = excluded.input_fingerprint,
        result_revision = nextval('public.anomaly_result_revision_seq'), computed_at = clock_timestamp()
      where (a.score, a.status, a.end_ts, a.flagged_by, a.channels)
            is distinct from (excluded.score, excluded.status, excluded.end_ts, excluded.flagged_by, excluded.channels);
    n := n + 1;
  end loop;

  update public.anomaly_candidates a set status = 'retracted', suppressed_reason = 'not_in_rescore',
         result_revision = nextval('public.anomaly_result_revision_seq'), computed_at = clock_timestamp()
   where a.user_id = j.user_id and a.device_id = j.device_id and a.status <> 'retracted'
     and a.start_ts >= v_from and a.start_ts < v_to and not (a.candidate_key = any(keys));

  for w in select * from jsonb_array_elements(p_payload -> 'window_scores') loop
    v_code := w ->> 'reason_code';
    v_certainty := w ->> 'reason_certainty';
    if v_code is null and w ->> 'withheld_reason' is not null then
      select m.code, m.certainty into v_code, v_certainty from internal.anomaly_withheld_reason(w ->> 'withheld_reason') m;
    end if;
    insert into public.anomaly_window_scores as s (user_id, device_id, window_start, window_end, channel_group, model,
        score, p, context_kind, usable, withheld_reason, reason_code, reason_certainty)
    values (j.user_id, j.device_id, (w ->> 'window_start')::timestamptz, (w ->> 'window_end')::timestamptz,
        w ->> 'channel_group', w ->> 'model', (w ->> 'score')::double precision, (w ->> 'p')::double precision,
        w ->> 'context_kind', coalesce((w ->> 'usable')::boolean, false), w ->> 'withheld_reason', v_code, v_certainty)
    on conflict (user_id, device_id, window_start, channel_group, model) do update set
        window_end = excluded.window_end, score = excluded.score, p = excluded.p, context_kind = excluded.context_kind,
        usable = excluded.usable, withheld_reason = excluded.withheld_reason, reason_code = excluded.reason_code,
        reason_certainty = excluded.reason_certainty, computed_at = clock_timestamp();
  end loop;

  update public.anomaly_jobs set completed_revision = p_revision, lease_token = null, lease_until = null,
         consecutive_failures = 0, last_completed_at = clock_timestamp(), last_error = null,
         last_duration_ms = (p_payload ->> 'run_ms')::bigint, last_worker = left(p_payload ->> 'worker', 120),
         success_count = success_count + 1, watermark_ts = greatest(coalesce(watermark_ts, v_to), v_to)
   where user_id = j.user_id and device_id = j.device_id;
  return n;
end $$;

revoke all on function public.publish_anomaly_result_v1(uuid, bigint, jsonb) from public, anon, authenticated;
grant execute on function public.publish_anomaly_result_v1(uuid, bigint, jsonb) to service_role;

commit;
