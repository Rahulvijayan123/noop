-- Activity context: the transitions read surface exposes each event's onset and detector (audit D2-05 / D5-07).
--
-- The day document's events now carry two optional keys (ActivityTransitionEvent, audit D2-05):
--   onset_ts  the decoder's causal back-date of the change: the second its posterior began to rise, at most
--             10 s before `ts` (the second it flagged the event) and never after it;
--   source    which detector flagged it: 'hsmm' (the decoder) or 'transition_expert'.
-- public.activity_context_transitions gains onset_ts, onset_at and source, appended after the existing columns
-- (CREATE OR REPLACE VIEW may only add columns at the end). They are NULL for documents decoded before the keys
-- existed, so a reader that wants "when did the change begin" uses coalesce(onset_ts, ts). `ts` keeps its
-- meaning: the second the event became known, which is what a causal reader filters on.
--
-- Additive: same rows, same leading columns and types, security_invoker kept; CREATE OR REPLACE keeps the
-- grants of 20261003140000_activity_context_stream_days.sql (select to authenticated and service_role only).
--
-- Rollback: re-create the view from 20261003140000_activity_context_stream_days.sql section 5 (drop it first:
-- CREATE OR REPLACE cannot remove columns) and re-apply that migration's revoke/grant on it.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create or replace view public.activity_context_transitions with (security_invoker = true) as
select d.user_id, d.device_id, d.day, d.algorithm_version,
       (e.value ->> 'ts')::bigint as ts,
       to_timestamp((e.value ->> 'ts')::bigint) as at,
       e.value ->> 'kind' as kind,
       (e.value ->> 'probability')::real as probability,
       d.model_version, d.decoder_version, d.ontology_version, d.feature_schema,
       d.encoder_id, d.encoder_version, d.result_revision, d.computed_at,
       case d.algorithm_version when 'hart-activity-1' then 1 else 2 end as source_rank,
       (e.value ->> 'onset_ts')::bigint as onset_ts,
       to_timestamp((e.value ->> 'onset_ts')::bigint) as onset_at,
       e.value ->> 'source' as source
  from public.activity_context_days d
 cross join lateral jsonb_array_elements(d.document -> 'events') as e(value);

comment on view public.activity_context_transitions is
  'ActivityContext v2: every flagged change of state with its exact unix-second timestamp (ts, when it was '
  'flagged) and probability; onset_ts is the decoder''s causal back-date of the change (at most 10 s before ts) '
  'and source the detector (hsmm | transition_expert), both NULL on documents decoded before the keys were written.';

commit;
