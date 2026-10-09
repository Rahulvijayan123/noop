-- Regression for 20261008100500_activity_ground_truth_confirmation_source.sql.
--
-- An in-the-moment "Right now: sitting / standing / neither?" answer is stored through the service-role RPC
-- upsert_activity_ground_truth_labels with source='confirmation': sitting = posture seated_likely, standing =
-- posture upright_stationary, neither = posture unknown with user_unsure false. A confirmation with a
-- transition, longer than 120 s or without a posture is refused, as is an unknown source; guided labels keep
-- every old rule (long, transition-bearing intervals still store); an authenticated user reads only own rows.
--
-- Everything runs in one transaction that is rolled back:
--   psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/activity-ground-truth-confirmation-source.sql
\set ON_ERROR_STOP on
\echo CASE activity-ground-truth-confirmation-source
begin;
set local statement_timeout = '30s';

insert into auth.users(id) values ('c5000000-0000-4000-8000-000000000001'), ('c5000000-0000-4000-8000-000000000002');

-- The RPC is service-role only; run the writes as service_role with no end-user JWT.
set local role service_role;

do $check$
declare
  u uuid := 'c5000000-0000-4000-8000-000000000001';
  other uuid := 'c5000000-0000-4000-8000-000000000002';
  t0 bigint := 1760072000;
  base jsonb;
  res jsonb;
  bad jsonb;
  refused boolean;
begin
  base := jsonb_build_object(
    'client_id', 'c5000000-0000-4000-8000-0000000000c1', 'source', 'confirmation',
    'start_ts', t0, 'end_ts', t0 + 60, 'label_confidence', 1, 'user_unsure', false,
    'model_context_at_label_time', jsonb_build_object('display', 'Sitting', 'p_sit', 0.71),
    'app_version', '11.9.0', 'client_updated_at', '2026-10-08T10:00:00Z');

  -- 1. Valid answers: sitting, standing (at the 120 s edge), neither.
  res := public.upsert_activity_ground_truth_labels(u, jsonb_build_array(
    base || jsonb_build_object('label_key', 'confirmation:prompt:1760072000', 'posture', 'seated_likely'),
    base || jsonb_build_object('label_key', 'confirmation:prompt:1760072300', 'posture', 'upright_stationary',
                               'start_ts', t0 + 300, 'end_ts', t0 + 420),
    base || jsonb_build_object('label_key', 'confirmation:prompt:1760072600', 'posture', 'unknown',
                               'start_ts', t0 + 600, 'end_ts', t0 + 630)));
  assert jsonb_array_length(res -> 'saved') = 3, 'three confirmations saved, got ' || res::text;
  assert (select count(*) from public.activity_ground_truth_labels
           where owner = u and source = 'confirmation' and session_id is null and transition_kind is null) = 3,
    'three confirmation rows with no session and no transition';
  assert (select posture from public.activity_ground_truth_labels
           where owner = u and label_key = 'confirmation:prompt:1760072600') = 'unknown',
    'neither is stored as posture unknown';
  assert (select not user_unsure and label_confidence = 1 from public.activity_ground_truth_labels
           where owner = u and label_key = 'confirmation:prompt:1760072600'),
    'neither keeps user_unsure false and the confidence';

  -- 2. Rejections: each raises a check violation and the whole call rolls back.
  foreach bad in array array[
    jsonb_build_object('transition_kind', 'sit_to_stand'),
    jsonb_build_object('transition_ts', t0 + 30),
    jsonb_build_object('end_ts', t0 + 121),
    jsonb_build_object('end_ts', t0 + 900),
    jsonb_build_object('posture', null),
    jsonb_build_object('posture', 'recumbent'),
    jsonb_build_object('posture', 'postural_transition'),
    jsonb_build_object('source', 'sleep'),
    jsonb_build_object('source', 'prompt')]
  loop
    refused := false;
    begin
      perform public.upsert_activity_ground_truth_labels(u, jsonb_build_array(
        base || jsonb_build_object('label_key', 'confirmation:prompt:1760079999', 'posture', 'seated_likely') || bad));
    exception when check_violation then
      refused := true;
    end;
    assert refused, 'must be refused: ' || bad::text;
  end loop;
  assert not exists (select 1 from public.activity_ground_truth_labels where label_key = 'confirmation:prompt:1760079999'),
    'no refused item was stored';

  -- 3. The guided path is unchanged: 15 minutes with a transition still stores, and so does posture NULL.
  res := public.upsert_activity_ground_truth_labels(u, jsonb_build_array(jsonb_build_object(
    'client_id', 'c5000000-0000-4000-8000-0000000000c2', 'label_key', 'guided:activity-session:1760073000',
    'source', 'guided', 'session_id', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'start_ts', t0 + 1000,
    'end_ts', t0 + 1900, 'posture', null, 'transition_kind', 'sit_to_stand', 'transition_ts', t0 + 1450,
    'client_updated_at', '2026-10-08T10:00:00Z')));
  assert (res -> 'saved' -> 0 ->> 'revision')::int = 1, 'guided label saved, got ' || res::text;
  -- stretch_feedback and imported likewise keep long intervals.
  res := public.upsert_activity_ground_truth_labels(u, jsonb_build_array(
    jsonb_build_object('client_id', 'c5000000-0000-4000-8000-0000000000c3', 'label_key', 'stretch:x:1760074000',
      'source', 'stretch_feedback', 'start_ts', t0 + 2000, 'end_ts', t0 + 5600, 'posture', 'recumbent',
      'client_updated_at', '2026-10-08T10:00:00Z'),
    jsonb_build_object('client_id', 'c5000000-0000-4000-8000-0000000000c4', 'label_key', 'imported:x:1760080000',
      'source', 'imported', 'start_ts', t0 + 8000, 'end_ts', t0 + 9000,
      'client_updated_at', '2026-10-08T10:00:00Z')));
  assert jsonb_array_length(res -> 'saved') = 2, 'stretch_feedback and imported saved, got ' || res::text;

  -- 4. A confirmation for the other account, for the RLS check.
  res := public.upsert_activity_ground_truth_labels(other, jsonb_build_array(
    base || jsonb_build_object('label_key', 'confirmation:prompt:1760072000', 'posture', 'upright_stationary')));
  assert jsonb_array_length(res -> 'saved') = 1, 'the other account''s confirmation saved';
end;
$check$;

-- 5. RLS: an authenticated user reads only their own rows and cannot write or call the RPC.
reset role;
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
set local role authenticated;

do $rls$
declare
  u uuid := 'c5000000-0000-4000-8000-000000000001';
  refused boolean;
begin
  assert (select count(*) from public.activity_ground_truth_labels) = 6,
    'the owner sees exactly their six rows, got ' || (select count(*) from public.activity_ground_truth_labels);
  assert not exists (select 1 from public.activity_ground_truth_labels where owner <> u), 'no other owner''s row is visible';
  assert (select count(*) from public.activity_ground_truth_labels where source = 'confirmation') = 3,
    'the owner sees their three confirmations';

  refused := false;
  begin
    insert into public.activity_ground_truth_labels(owner, client_id, label_key, source, start_ts, end_ts, posture,
      client_updated_at)
    values (u, 'c5000000-0000-4000-8000-0000000000c9', 'confirmation:prompt:1760090000', 'confirmation',
      1760090000, 1760090060, 'seated_likely', now());
  exception when insufficient_privilege then
    refused := true;
  end;
  assert refused, 'an authenticated user cannot insert directly';

  refused := false;
  begin
    perform public.upsert_activity_ground_truth_labels(u, '[]'::jsonb);
  exception when insufficient_privilege then
    refused := true;
  end;
  assert refused, 'an authenticated user cannot call the RPC';
end;
$rls$;

reset role;
select set_config('request.jwt.claims', '{"sub":"c5000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
set local role authenticated;

do $rls2$
begin
  assert (select count(*) from public.activity_ground_truth_labels) = 1, 'the other account sees only its one row';
  assert (select posture from public.activity_ground_truth_labels) = 'upright_stationary', 'and it is its own';
end;
$rls2$;

reset role;
\echo PASS activity-ground-truth-confirmation-source
rollback;
