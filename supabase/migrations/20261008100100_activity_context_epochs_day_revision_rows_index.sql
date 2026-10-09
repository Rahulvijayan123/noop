-- Read index for the physiology-context lane's per-day epoch lineage (ContextSQL.activityEpochs, D3-02).
--
-- Additive only. activity_context_epochs keeps every published fingerprint's rows (up to ~200 lineages of one
-- UTC day in production). The context lane now reads ONE revision per UTC epoch day: the newest one, or in a
-- causal replay the newest one computed by its cutoff. This index lets that probe walk (user, device, day) by
-- descending revision and stop at the first match, and serves the rows of that revision in start order, so a
-- job no longer reads every lineage (~85x the rows it uses on the owner's 12 measured device-days). The query
-- is correct without the index.
--
-- Named `_rows`, distinct from `activity_context_epochs_day_revision` (user, device, day, result_revision desc)
-- that 20261008100000_activity_context_current_lineage_and_versions.sql (WP4) creates for the current-lineage
-- view: with one shared name, whichever migration ran second would silently do nothing. This index's leading
-- columns also serve that per-day maximum (a b-tree is scanned backwards), so once both are applied one of the
-- two can be dropped.
--
-- Drafted as 20261007130000; renamed so it sorts after every migration on main (`nara/main` 3b4ee16a5), whose
-- newest are 20261007140000 .. 20261008010000 (sensor_biomarkers, sensor_biomarkers_claim_throttle,
-- coach_threads_memory, anomaly_service, metric_insights, metric_insight_background_sweep):
-- `supabase db push` refuses a local version older than the remote's newest one. Which of those production has
-- applied was not re-checked here; list the remote versions immediately before any deploy. No migration between
-- the old and the new timestamp touches these objects (metric_insights reads physiology_context_days only).
-- Production order: main's migrations through 20261008010000, then 20261008100000, 20261008100100,
-- 20261008100200, 20261008100300 (if present), 20261008100400; Spec 01's 20261008120000_ppg_transport_anchor
-- touches only noop_reserve_object_manifest_lifecycle_core and sorts after all of them.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '300s';

create index if not exists activity_context_epochs_day_revision_rows
  on public.activity_context_epochs (user_id, device_id, day, result_revision, start_ts)
  include (computed_at);

comment on index public.activity_context_epochs_day_revision_rows is
  'Physiology-context lane: newest epoch revision per (user, device, UTC day), optionally computed by a cutoff.';

commit;
