# Rollout plan (core plumbing repairs)

Branch: `audit/core-plumbing-20261003`. All changes additive; no destructive operations. DO NOT deploy anything from this document without the separate authorization the spec requires. This plan is the reviewable sequence.

## 0. Order of application

Every migration below is new (timestamp-ranged, additive, transaction-wrapped). Apply with the documented production procedure (docs/BACKEND.md): `psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -f supabase/migrations/<file>.sql` then `supabase migration repair --status applied <version>`. NEVER `supabase db push` (production history only records up to 20260921104000; 39 later migrations were applied directly with SQL).

Worker rebuild requirement: any change under Packages/StrandAnalytics (day bucketing switch), Tools/CloudWorker (attestation, fences, quarantine, ActivityLane wear wiring, series revision fence), or contracts requires rebuilding + redeploying frwhoop-worker per deploy/README.md. Recommend the versioned-release layout (`.build/release-<git-sha>` + symlink switch) which also fixes the deployed-revision identity problem (currently plain `release/` + mislabeled `FRWHOOP_SOURCE_REVISION`).

## 1. Migrations (to be finalized from the repair diff)

- 20261003201000_outbox_retry_status.sql — physiology_archive_outbox status CHECK admits 'retry' (release path now commits with 30s backoff).
- 20261003202000_metric_series_input_revision_fence.sql — fenced 6-arg publish_metric_series_v1 (p_input_revision; stale -> applied:false/superseded; legacy 5-arg kept for fixtures, service-role only).
- 20261003203000_projection_debt_dead_letter.sql — noop_projection_debt dead_letter + reason at 16 failures; claim excludes dead-lettered; operator path documented for the ~16k stale rows.
- 20261003204000_day_attestation.sql — day_completeness revived (device_id/input_revision/attestation/attestation_version); publish_day_attestation_v1 fenced upsert.
- 20261003205000_day_closure_scheduling.sql — closure_state pending_reconciliation/closed + scoring_enqueue_due_day_closure (per-user-zone via profiles.timezone AT TIME ZONE).
- 20261003205900_verification_quarantine.sql — object_manifests verification_failure_code/failed_at/attempts + noop_quarantine_manifest_verification; candidateSQL + edge reconcileObjects exclude quarantined.
- 20261003210000_placement_intervals.sql — placement_intervals (RLS owner-scoped; set_placement_interval with cross_user_caller + device-owner guards; half-open effective dating).
- 20261003220000_server_pipeline_diagnostics_extended.sql — server_pipeline_diagnostics v2 (day bounds/zone, streams/coverage/largest gap, queue ages/revisions, durable-vs-verified archive, blockers).
- 20261003230100_repair_attest_fence_scope_and_retirement.sql — series fence scoped to user/day max revision (re-audit P2-1); closure sweep excludes retired owners (P2-3).
- 20261003230200_repair_attest_round2.sql — archive outbox dead_letter cap (16, archive_upload_exhausted); day_closure_skips visibility ledger; day_completeness.closure_reason + dead-lettered-day closure markers; noop_unquarantine_manifest_verification operator RPC.
- 20261003231000_placement_concurrency_lock.sql — set_placement_interval pg_advisory_xact_lock (concurrent declarations serialize; re-audit P2-2).
- 20261003231500_placement_same_start_effective_end.sql — same-start replacement honors explicit p_effective_end.

Apply in filename order (all later than the newest existing file). Each is additive and independently transactional; verify each with `supabase migration repair --status applied <version>` after applying.

## 2. Worker redeploy steps (requires authorization)

1. Merge/checkout the audited revision; build per deploy/README.md (Linux, pinned SQLite, `swift build -c release`), `swift test` on the host first.
2. Stop: `systemctl stop frwhoop-worker` (graceful, TimeoutStopUSec=90s).
3. Apply migrations (section 1).
4. Switch the release symlink; `systemctl start frwhoop-worker`; verify heartbeat (`scoring_service_heartbeats` fresh, no last_error), verify-lane no longer rescans quarantined manifests, archive outbox 'retry' rows drain with backoff.
5. Fix `/etc/frwhoop/worker.env` `FRWHOOP_SOURCE_REVISION` to the actual deployed sha (identity hygiene).

## 3. Compatibility

- App: all changes behind existing settings; no data migration on device; local SQLite schema changes (PlacementStore) are additive tables.
- Server: new columns/tables only; old worker ignores them until redeployed (verify: 'retry' status is only written by the NEW ArchiveLane release — current deployed code never writes 'retry'... NOTE: it DOES today (releaseOutboxLease) and fails on the CHECK; after the migration the CURRENT deployed binary's failed releases start succeeding — acceptable, the backoff is written with them).
- Scoring behavior change (day bucketing + Today midnight): DST-day and small-hours (00:00-04:00) results change by design; historical snapshots are not rewritten automatically. Optional backfill: re-dirty affected DST days after redeploy (bounded per-user work) — decide separately.

## 4. Verification checkpoints (post-deploy, read-only)

- Heartbeat lanes healthy; last_error clear.
- `select status, count(*) from physiology_archive_outbox group by 1` — 'retry' rows present only transiently, draining with next_attempt_at backoff.
- Bad manifest 6ad53e16 excluded from the verify scan (durable quarantine recorded with reason).
- day_completeness-style attestation rows appear as days settle.
- placement_intervals writes appear when the app syncs (post app release).
- Series fence: no stale series writes after superseded passes (compare computed_at vs input_revision on server_metric_series).

## 5. Rollback

- Migrations: all additive; rollback = leave tables/columns in place (harmless) or drop the new objects in reverse order (each file documents its objects).
- Worker: keep previous release artifact; switch symlink back + restart.
- App: revert the branch; on-device PlacementStore table is additive/ignored by the old build. Today-rollover behavior rollback = revert logicalDayRolloverHour change (documented in repair diff).

## 6. Explicitly NOT authorized in this run

No deploy, no production writes/migrations, no firmware experiments, no infrastructure purchases/resizes, no HART retraining, no destructive production data operations (including clearing the 16k stale projection rows — operator path documented, decision separate).
