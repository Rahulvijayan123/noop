-- Activity ground truth: a fourth label source, source='confirmation', for the in-the-moment prompt
-- "Right now: sitting / standing / neither?". The app uploads each answer through the existing path
-- (POST /scores/ground-truth-labels -> upsert_activity_ground_truth_labels), which needs no change: the RPC
-- copies `source` through and the table CHECKs are the backstop. The edge validator
-- (supabase/functions/_shared/groundTruthLabels.ts) mirrors the rules below.
--
-- Encoding of an answer (posture head only, from the existing vocabulary; nothing new is added to it):
--   sitting  -> posture 'seated_likely'
--   standing -> posture 'upright_stationary'
--   neither  -> posture 'unknown' with user_unsure = false. For a confirmation, 'unknown' does NOT mean
--               "abstain": the person answered with certainty that they were neither seated nor standing
--               still (lying, walking, ...). A consumer must read it as a negative for both sit and stand,
--               and must skip a confirmation row with user_unsure = true as it does for every source.
--               semantic_tag could not carry it ('neither' is not in its vocabulary) and posture NULL would
--               be indistinguishable from "posture not given".
-- A confirmation row must also: carry posture (one of the three above), have no transition (transition_kind
-- and transition_ts NULL), and cover at most 120 s (end_ts - start_ts <= 120; end_ts > start_ts is already
-- table-wide). label_confidence, session_id NULL, locomotion/arm_behavior/semantic_tag stay allowed as for
-- every source.
--
-- Every invariant for 'guided', 'stretch_feedback' and 'imported' is unchanged: the new check is a no-op for
-- them, and the source list only grows.
--
-- The original table (20261007090000) declared the source CHECK inline on the column, so its name is
-- auto-generated (activity_ground_truth_labels_source_check on every database built so far, but not
-- guaranteed). As 20261007090001 did for activity_stretch_feedback, a DO block finds it by definition (the only
-- table check containing `source = ANY`) and drops it, then a named constraint with the extended list is added.
-- Idempotent and order-safe: re-running drops both named constraints and re-creates them.
--
-- Rollback (only once no confirmation rows exist): drop activity_ground_truth_labels_confirmation_shape and
-- re-create activity_ground_truth_labels_source_check with ('guided', 'stretch_feedback', 'imported').
--
-- Sorts after every migration on main through 20261008010000 and after this branch line's 20261008100000,
-- 20261008100100, 20261008100200 and 20261008100400 (20261008100300 is unused). Which of those production has
-- applied was not re-checked here; list the remote versions immediately before any deploy. No migration between
-- 20261007090000 and this one touches activity_ground_truth_labels.
-- Production order: main's migrations through 20261008010000, then 20261008100000, 20261008100100,
-- 20261008100200, 20261008100300 (if present), 20261008100400, 20261008100500; Spec 01's
-- 20261008120000_ppg_transport_anchor touches only noop_reserve_object_manifest_lifecycle_core and sorts after
-- all of them.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $$
declare
  v_name text;
begin
  for v_name in
    select conname
      from pg_constraint
     where conrelid = 'public.activity_ground_truth_labels'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%source = ANY%'
  loop
    execute format('alter table public.activity_ground_truth_labels drop constraint %I', v_name);
  end loop;
end;
$$;

alter table public.activity_ground_truth_labels
  drop constraint if exists activity_ground_truth_labels_source_check;
alter table public.activity_ground_truth_labels
  add constraint activity_ground_truth_labels_source_check
  check (source in ('guided', 'stretch_feedback', 'imported', 'confirmation'));

alter table public.activity_ground_truth_labels
  drop constraint if exists activity_ground_truth_labels_confirmation_shape;
alter table public.activity_ground_truth_labels
  add constraint activity_ground_truth_labels_confirmation_shape
  check (source <> 'confirmation' or (
    posture is not null and posture in ('seated_likely', 'upright_stationary', 'unknown')
    and transition_kind is null
    and transition_ts is null
    and end_ts - start_ts <= 120));

comment on constraint activity_ground_truth_labels_source_check on public.activity_ground_truth_labels is
  'Accepted label sources; extended by 20261008100500 with confirmation (in-the-moment sitting/standing/neither prompt).';
comment on constraint activity_ground_truth_labels_confirmation_shape on public.activity_ground_truth_labels is
  'A confirmation answer: posture seated_likely (sitting), upright_stationary (standing) or unknown (neither: a certain negative for both, not an abstain); no transition; at most 120 s.';
comment on column public.activity_ground_truth_labels.source is
  'Where the label came from: guided calibration, stretch_feedback corrections, imported, or confirmation (an in-the-moment sitting/standing/neither answer; neither = posture unknown with user_unsure false).';
comment on table public.activity_ground_truth_labels is
  'Ground-truth activity labels from guided calibration, stretch-feedback corrections, in-the-moment confirmations and imports: what a person actually did over an interval, stored separately from model output. One row per (owner, label_key); last writer wins on client_updated_at. raw_refs references the raw IMU object_manifests covering the interval. Written only through upsert_activity_ground_truth_labels.';

commit;
