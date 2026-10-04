# Workstream G5 — Authentication, device/native-queue ownership, RLS/privileged APIs, cross-user isolation

Audit of the authorized checkout (branch `audit/core-plumbing-20261003`, baseline `56809066`, head `4c85df9a`).
Scope: `Strand/Push/` owner binding, `supabase/functions/` auth, `supabase/migrations/` RLS + definer
functions, `Tools/CloudWorker` privileged paths, object/signed-URL lane, account-deletion.
Method: code reading with file:line evidence; targeted Deno tests against the disposable local-PG
harness (`supabase/functions/tests/local_postgres.ts`); macOS StrandTests for the cloud-push layer.

## Summary of verdicts

| Item | Verdict |
|---|---|
| Identity model (Q1) | PASS (server fail-closed), one code-level gap in error-code mapping |
| Native queue ownership (Q2 / T23) | FAIL (latent): journal/object-lane stores are one shared SQLite file with no owner filter; currently unreachable via UI, blocked server-side by source rebinding |
| RLS coverage (Q3) | PASS (all account-scoped tables RLS-on, owner-scoped or service-only) |
| SECURITY DEFINER / search_path | PASS (339/339 set search_path) |
| Privileged writes / nested rows (T22) | PASS (owner checks + `projection_owner_mismatch`), with the error-code mapping caveat |
| Signed URLs / object lane (Q5) | PASS (owner+status+source validation, 15-min TTL, server-minted keys) |
| Two-user evidence (Q6 / T21/T22) | PASS (13 auth/isolation unit files green; 4 integration files red — 3 from one rest-layer message-swallowing defect, 1 blocked by missing Swift fixture) |
| Deletion / reassignment (Q7 / T25) | PASS with gaps (deletion_jobs + retirement tombstone rows intentionally remain; legacy claim path does not consult tombstone but rows cascade-delete) |
| Realtime / topics (Q8) | Code-verified intent owner-scoped; deployed schema NOT VERIFIED |

---

## Q1 — Identity model (which credentials, which routes, fallbacks)

Server-side identity (fail-closed, no dev-user fallback):

- `supabase/functions/_shared/tokens.ts:171-210` `resolveJwtUser` — JWT-shaped bearer validated against
  Supabase Auth (`/auth/v1/user`); malformed/expired/failed → 401 `authentication required`. No silent fallback.
- `supabase/functions/_shared/tokens.ts:213-266` `resolveUploadIdentity` — requires opaque `noop_…`
  bearer, SHA-256 lookup in `noop_ingest_tokens` (user_id + source_id must both be UUIDs), plus a second
  fleet credential in `x-noop-fleet-token` (`resolveFleetAuthorization`), plus a live, unrevoked
  `noop_app_installations` row (`user_id, source_id`). Legacy fleet-only uploads default OFF
  (`config.ts: allowLegacyFleetUploads` = `NOOP_ALLOW_LEGACY_FLEET_UPLOADS === 'true'`, default false).
- Routes: `push` (inline + objects + enroll), `scores`, `coach`, `reconcile`, `ingest-verify`,
  `retention-sweep`, `account-deletion`:
  - `push/index.ts:155-166` uploads use `resolveUploadIdentity` + per-request quota RPC `admit_noop_request`
    (which also requires `revoked_at is null and retired_at is null`, migration 20260921113000:63-66).
  - `scores/index.ts` accepts either installation token or a validated Supabase JWT **plus**
    `x-noop-source-id` cross-checked against `compute_account_sources` / `noop_app_installations`
    ownership and revocation (`_shared/serverScores.ts:330-345`).
  - `coach/index.ts` — `resolveUploadIdentity` + `authMode === 'installation'` only (`_shared/coach.ts:20540` region).
  - `reconcile` / `ingest-verify` / `account-deletion` / `retention-sweep` — `authorizeWorkerRequest`
    (`_shared/workerAuth.ts`): `WORKER_SECRET` or the service-role key, never anonymous.
- No payload owner id, path UUID, or device name is ever trusted as identity: the batch header's
  `sourceId` must equal the token's sourceId (`_shared/ingest.ts:292-295` `source_id_mismatch` 403), and
  `deviceId` is resolved per owner via `scopedExternalDeviceId` (provisional names become
  `installation:<sourceId>:<name>`, real `whoop-<serial>` is hardware evidence) in `_shared/devices.ts:24-38`.
- Enrollment: fleet bearer only; deterministic per (code, sourceId); a source already bound to another
  owner is refused `enrollment_source_already_bound` (migration 20260919200000:313) — one install cannot
  rebind to a different owner. This is the server-side backstop for the native-queue finding below.

### Code-level gap (Q1)

`_shared/rest.ts:61-70` collapses every 401/403/42501 PostgREST response into
`RestAuthorityError('supabase_authority_rejected')`, discarding the DB `code`/`message`. The mapping in
`_shared/durability.ts:35-46` (`intakeError` → `device_owner_conflict`/`object_owner_conflict` → 403) is
therefore DEAD CODE: those codes never reach it. A denied object intent now surfaces to the caller as a
generic 500 `push_failed` instead of the documented 403 `device_owner_conflict`
(`push/index.ts:231-239 handleObjectIntent` only maps `PushProtocolError`/`Response`).
Security effect: denial still happens (fail-closed); the wire error contract is wrong. Repro below (T22).

---

## Q2 — Native queue ownership (T23)

Phone-side intent is documented ("every journaled record is stamped with the owner that was signed in…
The prior owner's pending inputs stay isolated under their own owner id" — `CloudPushIdentity.swift:5-9`),
and the owner_id columns exist (`journal_record.owner_id`, `sealed_batch.owner_id`). But the enforcement
is incomplete:

1. **One shared SQLite file per install** — `CloudJournalStore` opens `journal.sqlite` once
   (`CloudJournal.swift:420-424`) and `CloudJournal.activate` reuses the store across owners
   (`CloudJournal.swift:1161-1178`): switching owners only overwrites `configuration`; no owner filter
   and no per-owner file/WAL.
2. **Sealer ignores owner** — `pendingGroups` selects `WHERE state = 0` grouped by `device_id, stream`
   with **no** `owner_id` predicate (`CloudJournal.swift:632-649`); `pendingEntries` likewise
   (`CloudJournal.swift:673-683`); `sealedBatches` likewise (`CloudJournal.swift:902-927`).
3. **Upload token is resolved at SEND time** from `CloudPushIdentityStore.current()`
   (`CloudUploadSession.swift:118`, `:182`; coordinator `sendEligible` reads batches without comparing
   `batch.ownerId` to the current identity — `CloudTransportCoordinator.swift:312-360`).
4. **No owner-vs-identity guard in the send path**: `sealReady(identity:)` stamps the batch with the
   CURRENT identity's sourceId (`CloudTransportCoordinator.swift:236-239`) while the candidate ownerId
   comes from the stale journal config; `registerSeal` overwrites the candidate's owner with
   `config.ownerId` (`CloudJournal.swift:1276-1288`).
5. **No sign-out/switch wiring**: `CloudPushIdentityStore.signOutCurrentOwner()` (`CloudPushIdentity.swift:78`)
   and `forget(ownerId:)` (`:87`) have NO callers in the tree (grep: only the definition + a comment in
   `RawDataSessionStore.swift:303`). The enrollment UI offers only enable/disable
   (`CloudEnrollmentView.swift:253-307`). `CloudPushRuntime.stop()` is never called
   (`CloudCapture.swift:628-637` is the only definition).
6. The object lane has the same shape: `ImuPushProgressStore` (`object-lane.sqlite`) keys its cursor and
   in-flight state by `(stream, device_id)` with no owner column (`ImuPushProgressStore.swift:44-72`).

**Why it is currently latent, not exploitable**: the server refuses to bind one sourceId to a second
owner (`redeem_noop_enrollment` → `enrollment_source_already_bound`, migration 20260919200000:313), and
there is no UI that can reach an A→B switch on the same install. A manual defaults wipe + re-enroll would
still hit the server refusal. The model nonetheless violates the stated invariant "A's records remain
under A or quarantined" — it is one future "switch account" button away from uploading A's pending rows
under B's token (the batch body carries only deviceId/stream, and `sealReady` would stamp B's sourceId,
so the receiver would attribute the rows to B's account).

**Verified**: `testScoreCacheRoundTripsAndRefusesAnotherOwnersEntry` (`StrandTests/CloudPushTests.swift:279`)
— the on-disk SCORE CACHE is owner-tagged and refuses another owner's entry (the one local store that does
enforce it). No test exercises the journal/sealer cross-owner path (confirmed by test inventory).

**Repair**: (a) filter `pendingGroups`/`pendingEntries`/`sealedBatches` by the configured owner_id;
(b) add a `batch.ownerId == identity().ownerId` guard in `sendEligible`/`cycle` before sealing or sending;
(c) make `activate` with a different owner either open a per-owner file or quarantine the old owner's
unacked rows; (d) wire `signOutCurrentOwner`/`stop()` into the UI before any account-switch feature ships.

---

## Q3 — RLS coverage (all account-scoped tables)

Complete inventory built by scanning all 156 migrations (static + `do $$ foreach` dynamic RLS):

- Every account-scoped table has RLS enabled; there are **no permissive cross-user policies**.
- Owner-scoped CRUD on the legacy surface: `profiles`, `user_settings`, `integration_connections`,
  `health_calibrations`, `daily_metrics`, `sessions`, `events`, `sleep_details`, `devices`,
  `object_manifests`, `daily_physiology_series`, `ingest_gaps`, `server_daily_scores`,
  `server_sleep_nights`, `server_metric_series`, `scoring_timezone_history`, `noop_*` projections etc.
  all use `using ((select auth.uid()) = user_id)` (e.g. production_persistence.sql:39-64 dynamic block;
  canonical_day_series_broadcast.sql:88-98; metric_series.sql; 20260917180000_server_score_user_reads.sql).
- Worker/service tables (`scoring_jobs_v2`, `scoring_snapshots_v2`, `scoring_invalidations_v2`,
  `scoring_archive_jobs_v2`, `physiology_archive_outbox`, `server_physiology_results`,
  `noop_projection_debt`, `noop_recovery_*`, `activity_context_*`, `noop_fleet_intake_*`,
  `scoring_fleet_*`, `noop_account_retirements`, `noop_intake_canary_state`, `noop_wearable_aliases`,
  `noop_collection_leases`, `noop_projection_conflicts`, `noop_rr_clock_conflicts`) are
  `revoke all … from public, anon, authenticated` + `grant … to service_role` + a
  `…_service`/`machine_access` policy for service_role only (e.g. production_scoring_durability.sql:591-606;
  physiology_publication.sql; wearable_lifecycle.sql; activity_context.sql:98-114).
  `server_physiology_results` additionally has `read_owner` select for authenticated
  (physiology_publication.sql `using ((select auth.uid()) = user_id)`).
- `internal.app_secrets`, `internal.integration_secrets`, `internal.settings_migration_audit` live in the
  `internal` schema with `revoke all` from clients (production_persistence.sql; database_security_hardening.sql).
- Global read-only catalogs (`energy_model_versions`, `physiology_feature_manifests`) have `using(true)`
  select to authenticated — metadata only, no user data.
- **All 339 SECURITY DEFINER functions set `search_path`** (scanned; 0 without). Many pin `''` or
  `pg_catalog, public`.

**Privileged RPCs** (`engine_publish_physiology` 20260918020000:231, `noop_reserve_object_manifest`
20260923180000:49, `noop_commit_push_projection` 20260918040000:153/20260922120000:241,
`scoring_canary_*` 20260922130000) are service-role-gated (`auth.role()='service_role'` or
`session_user='postgres'`) and/or secret-gated (`internal.assert_ingest_secret`), and check
`exists(select 1 from devices where id=… and user_id=…)`.

---

## Q4 — Privileged writes / nested-row validation (T22)

- Inline ingest: batch sourceId must match token (`_shared/ingest.ts:292-295`); streams/versions/schema
  validated before any write; canonical device resolved per owner (`devices.ts`); WAL/receipt binds
  owner+device+digest.
- Projection commit (`noop_commit_push_projection`, migration 20260918040000:153-193): validates manifest
  (status, format, receipt `contentSha256`, batchId/sourceId/stream/recordCount), then validates EVERY
  projected row with `x->>'user_id' is distinct from m.user_id::text or … is distinct from m.device_id::text`
  → `projection_owner_mismatch` (line 191). The 20260922120000 wrapper re-checks installation
  revoked/retired. This is the forged/mixed-owner nested-row guard.
- Object lane (`_shared/objects.ts`): manifest requires UUID objectId/batchId/sourceId, bounded sizes,
  server-side key minting (`rawObjectKeyV3` under the user prefix; `if (m.objectKey || m.object_key)
  errors.push('objectKey')`); `createIntent` rejects prior manifests owned by another user
  (`forbidden` 403), mismatched source/authMode, and `object_id_conflict` 409; completion re-checks
  `row.user_id === userId` + source + authMode (`objects.ts:17709-…` `completeObject`).
- Wearable confirm/handoff: `confirm_noop_wearable` (20260921111000:307-…) requires the provisional
  device to be the caller's `installation:<source>:` device and the canonical `whoop-<serial>` to be
  owned by the same user with a matching serial evidence; cross-user association raises
  `supported_serial_evidence_required` or `wearable_association_conflict`.
- Worker (direct DB): the scoring publish path is fenced (`publish_scoring_snapshot_v2` checks
  `lease_token`, lease expiry, `input_revision` equality and invalidation coverage before writing —
  20260918010000:228-…); the intake canary functions (20260922130000) validate (user, device) + active +
  un-retired; the legacy claim SQL excludes retired owners
  (`ScoringLane.swift` `not exists(select 1 from public.noop_account_retirements r where r.user_id = w.user_id)`).

**T22 finding (error-code mapping)**: the `device_owner_conflict` guard in
`noop_reserve_object_manifest` (20260923180000:49) fires (reproduced in a disposable cluster), but the
edge maps it to a generic `push_failed`/500 because `rest.request` converts 42501 → `RestAuthorityError`
(rest.ts:68) and `intakeError`'s code mapping is unreachable (durability.ts:35-46). See T22 below.

---

## Q5 — Signed URLs / object lane

- `UPLOAD_URL_TTL_SEC = 15*60` and `createPushObjects` rejects TTL outside 1..900 (`_shared/objects.ts:60`, `:863`).
- Presigned PUT/GET via hand-rolled SigV4 (`_shared/s3.ts:7522` region `presignPut`/`presignGet`).
- Keys are server-minted per owner/device/stream/start (`rawObjectKeyV3`), client-chosen keys rejected.
- Completion (`completeObject`) enforces owner + source + authMode + byte count via HEAD; async
  verification debt is owner-scoped; receipts bind owner/device/digest.
- No namespace-confusion path found: object keys always begin with `v<major>/…/users/<uuid>/`.
  `purgePrefixVersions` additionally refuses prefixes not matching `v[123]/…/users/<uuid>/`
  (`s3.ts:12206`).

---

## Q6 — Two-user evidence (T21/T22)

Ran with Deno 2.9.7 against the repo's disposable local-PostgreSQL + PostgREST harness
(`supabase/functions/tests/local_postgres.ts`; creates its own cluster, never touches a shared DB).

Green (code-verified in this tree):
- `tokens_test.ts` 14/14, `worker_auth_test.ts` 4/4, `intake_admission_test.ts` 7/7,
  `enrollment_test.ts` 7/7, `devices_test.ts` 6/6, `scores_auth_test.ts` 5/5,
  `server_scores_auth_test.ts` 4/4, `workers_test.ts` 11/11 (incl. deletion order), `keys_test.ts` 3/3,
  `coach_test.ts` 14/14 (owner isolation), `ingest_verify_test.ts` 9/9, `enrolled_scores_test.ts` 17/17,
  `result_days_test.ts` 3/3.
- Integration (real PG + PostgREST + loopback object HTTP): `enrolled_durability_integration_test.ts` 1/1,
  `identity_provenance_integration_test.ts` 1/1 (7 steps; includes "authenticated/anon roles cannot read
  other owners"), `copy_intents_integration_test.ts` 1/1 (13 steps).
- macOS StrandTests (xcodegen + xcodebuild, scheme Strand, `-only-testing:StrandTests/CloudPushTests
  -only-testing:StrandTests/IntradaySeriesTests -only-testing:StrandTests/ImuObjectLaneTests`):
  88 tests, 0 failures — includes `testScoreCacheRoundTripsAndRefusesAnotherOwnersEntry`.

Red (reproducible in this tree, same root cause — rest-layer message swallowing):
- `intake_integration_test.ts:73` — `foreignDevice.createIntent({userId: USER_B, …})` expects
  `/device_owner_conflict/`, got `PushIngestFailure: push_failed`.
- `scalar_integration_test.ts:102` — expects the denied registration of USER_A's device by USER_B to
  match a denied-message predicate; got `Error: supabase_authority_rejected` (validation returned false).
- `object_verification_integration_test.ts:247` — expects `/permission denied/` from
  `noop_reserve_copy_intent_unfenced`; got `Error: supabase_authority_rejected`.
- `object_representation_integration_test.ts:11` — BLOCKED in this environment: needs the Swift-exported
  fixture `/tmp/nara-edge-artifacts/representation-swift/representation-compatibility.json`
  (produced by Tests/ServerFixtureNative exporter, which is not present in this checkout). NOT RUN.

The three red tests are assertion-level failures caused by `_shared/rest.ts:61-70`
(RestAuthorityError collapses 401/403/42501, discarding code+message) after the rest client was hardened;
the tests still assert on the pre-hardening messages. Denial-of-access is correctly enforced in every
case (no owner writes/reads occurred), so this is an error-contract regression, not an isolation bypass.
Note: the repo pins Deno 2.5.6 (external npm path absent here); the failures are pure string assertions
and not runtime-version-dependent, but re-run with the pinned binary before merging changes.

Exact commands (read-only, disposable DB, no shared DB):
```
cd "<repo>/supabase/functions"
deno test --no-check --allow-env --allow-read --allow-write=$TMP   --allow-run=/opt/homebrew/bin/initdb,/opt/homebrew/bin/pg_ctl,/opt/homebrew/bin/psql,/opt/homebrew/bin/postgrest   --allow-net=127.0.0.1,localhost tests/tokens_test.ts … (per-file; EDGE_TEST_ARTIFACTS=$TMP)
```

---

## Q7 — Deletion / reassignment (T25)

- `account-deletion/index.ts` — worker-secret/service-role bearer only (`authorizeWorkerRequest`).
- `createDeletionService` (`_shared/workers.ts`): resumable `deletion_jobs` state machine;
  `begin_noop_account_deletion` inserts the `noop_account_retirements` tombstone and revokes all
  installations + ingest tokens (20260921113000:35-47); waits ≥16 min for presigned-URL expiry; censuses
  B2 keys and requires every key under the user's own prefixes (`deletion_object_owner_mismatch` guard);
  purges versions; deletes DELETION_TABLES rows by user_id; deletes integration credentials; deletes the
  Auth user LAST. `DELETION_TABLES` covers the legacy surface + activity_context_*.
- Residual rows after auth deletion (checked via FK scan): `noop_account_retirements` and
  `deletion_jobs` intentionally survive (tombstone/journal). All other account-scoped tables either are
  in DELETION_TABLES or cascade from `auth.users` (verified: `noop_ingest_tokens`, `noop_app_installations`,
  `noop_upload_receipts`, `noop_push_*`, `scoring_jobs_v2`, `scoring_snapshots_v2`,
  `server_physiology_results` → `physiology_archive_outbox`, `server_metric_series`, `activity_context_*`,
  `noop_projection_*`, `noop_*_samples`, `noop_wearable_aliases`/`noop_collection_leases`/
  `noop_projection_conflicts`/`noop_rr_clock_conflicts`/`scoring_fleet_reservations` cascade via
  `devices`, which is deleted in step 4).
- Queued-work resurrection is closed at intake (`admit_noop_request` requires un-revoked/un-retired
  installation; `noop_commit_push_projection` wrapper re-checks; `noop_intake_canary_validate` checks
  tombstone + active device; legacy claim excludes retired owners; `noop_reserve_object_manifest`
  re-checks installation). Gap: the legacy `internal.claim_scoring_v2`/`publish_scoring_snapshot_v2`
  path does NOT consult the tombstone; it relies on `scoring_jobs_v2` being cascade-deleted at auth
  erasure. During the deletion window a claimed job could still publish, but the snapshot row is also
  cascade-deleted — no cross-user exposure, just a window of wasted work.
- Device reassignment: `handoff_noop_collection` (120 s lease) and `confirm_noop_wearable` are
  owner-scoped; no prior-owner history exposure found (devices are per-user rows; aliases are per-user).

---

## Q8 — Realtime / broadcast authorization

- `internal.emit_user_invalidation` broadcasts on topic `'user:' || uid` with private=true
  (20260824220000:376-392), and the migration creates RLS on `realtime.messages`
  `topic = 'user:' || auth.uid()` for authenticated SELECT (20260824220000:442-448) — so a user can only
  subscribe to their own topic, by design.
- No client in this tree subscribes to Supabase Realtime (the app uses cursor-based `scores/days` polling);
  grep finds no Supabase client/wss in Swift or TS.
- Deployment caveats: the `realtime` schema/`realtime.send` are platform-managed, not created by any
  migration; the policy/trigger swallow `undefined_table`/`undefined_function` exceptions
  (20260824220000:442-450, emit trigger `exception when others then null`). If the deployed project lacks
  the realtime schema, the broadcast silently no-ops and the RLS policy is never installed. The prior
  audit's "realtime schema absent / ordering defect" claim could not be confirmed or refuted from this
  tree. **NOT VERIFIED (needs deployed/staging schema inspection).**

---

## NOT VERIFIED / blocked checks

1. Deployed migration history and applied grants/RLS on production (prior audit: versions recorded only
   to 20260921104000; 39 later migrations applied by hand). Needs staging/production DB introspection.
2. Whether the production project has the `realtime` schema + `realtime.send` and the
   `realtime.messages` RLS policy (realtime auth effective vs silent no-op).
3. `object_representation_integration_test.ts` — requires the Swift-exported representation fixture
   (Tests/ServerFixtureNative exporter absent in this checkout).
4. Physical-device account switch (T23 end-to-end) — no UI path exists, so this is code-verified as
   latent-only; needs a real install + switch UI before it can be exercised.
5. Two-user same-date outbox write isolation during a DB outage (T21's outage clause) — the fixture suite
   covers deterministic replay but not a live two-phone outage; needs staging.
6. Deno pinned version 2.5.6 not present; failures re-verified with 2.9.7 only.

## Recommended next actions

1. Fix `_shared/rest.ts` error classification to preserve known deny codes (`device_owner_conflict`,
   `object_owner_conflict`, and the `permission denied` variants the tests assert) while still hiding
   arbitrary SQL text; then re-run the three red integration tests.
2. Add owner filters to `CloudJournal.pendingGroups/pendingEntries/sealedBatches` and an
   `ownerId == currentIdentity.ownerId` guard in `CloudTransportCoordinator.sendEligible`; make
   `activate` quarantine a different owner's unacked rows (T23 hardening, currently latent).
3. Add a journal cross-owner regression test in `StrandTests/CloudPushTests.swift` (no test covers it today).
4. Decide whether `claim_scoring_v2`/`publish_scoring_snapshot_v2` should consult the retirement tombstone
   (currently relies on cascade delete) to shrink the deletion-window work.
5. Verify deployed `realtime` schema presence and production migration order before relying on broadcast
   invalidation.
