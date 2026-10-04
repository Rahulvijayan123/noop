# G2-Attestation — Workstream 3 findings
## Daily attestation, archive/manifest reconciliation, deterministic replay

- Agent: `g2-attestation` (Workstream 3, spec sections 4.4–4.6, 7.3, G2+G6 archive side)
- Tree: `/Volumes/External SSD/Nara Whoop App V2/nara-core-plumbing`, branch `audit/core-plumbing-20261003`
- HEAD: `4c85df9a` (docs: add core-plumbing audit spec), baseline `56809066`, clean tree.
- Date: 2026-10-03. Verification types: CODE-VERIFIED (file:line), TEST-VERIFIED (ran locally), NOT VERIFIED (blocked).

---

## 1. Daily attestation / versioned per-day completeness (spec 4.4) — G2

### Verdict: FAIL (no active versioned per-day completeness record)

**What exists:**
- `public.day_completeness` table (created 2026-08-30): `supabase/migrations/20260830202224_day_completeness.sql:8-17` — PK `(user_id, day)`, `status in ('open','complete','degraded')`, `result jsonb`, `finalized_at`, `timezone_name`. Later extended with `overnight_state / overnight_reason / input_fingerprint / last_trigger / last_attempt_at / overnight_finalized_at` in `20260830202241_overnight_finalization.sql:9-22`.
- `public.ingest_gaps` (provenance/resolution) in the same migrations.

**Why it is NOT the active mechanism:**
- Grep over all `.swift/.ts/.js/.md` (excluding migrations) for `day_completeness`, `computeDayCompleteness`, `overnight_finalization`, `overnight_state`, `ingest_gaps`: **zero code references**. The only hits are the 4 migration files themselves and the deletion-table list in `supabase/functions/_shared/workers.ts:48`.
- No RPC, edge function, or worker writes/reads `day_completeness`; no reader in the phone (`Strand`, `Packages/NoopPush`), and no trigger attaches it to stream tables. It is dormant schema.

**What actually holds per-day state in the current tree:**
- `scoring_jobs_v2 (user_id, device_id, day, algorithm_version, input_revision, completed_revision, dead_letter, not_before)` — `supabase/migrations/20260918010000_production_scoring_durability.sql:13-27`.
- Immutable versioned snapshots `scoring_snapshots_v2` (identity result_revision, unique `(user,device,day,algo,input_revision)`, immutability trigger `reject_snapshot_update_v2`, `...:13-27, 310-313`), payload carries `inputRevision`, `resultRevision`, `computedAt`, `coverage`, `timezone`, `dataThrough`.
- Per-stream acquisition counts: snapshot `payload.coverage` built by `DayScoring.swift:472-486` — only `received` counts per stream (hr/rr/resp/gravity/skinTemp/spo2/events/bandSleepState/steps + nightWindow bounds). No gaps, no largest gap, no off-body/unknown duration, no handoff watermarks, no archive verification status, no projection-revision linkage.
- `server_pipeline_diagnostics` (`supabase/migrations/20260921101000_server_pipeline_diagnostics.sql:6-...`) — metadata-only trace distinguishing accepted/projected/queued/claimed/computed/published/selected; explicitly `'acquired','status','not_measured','reason','requires_device_capture_evidence'` and `'decoded'/'displayed' not_measured`. Honest diagnostic, not a 4.4 record.
- `server_metric_series` and `physiology_worker_heartbeats` hold derived status, not attestation.

**Gap vs spec 4.4 minimum:** no single versioned per-day record carries identity/time (canonical day identity, zone policy version, assigned UTC intervals, revision, as_of, input generation), capability (firmware/decoder versions, cadence, recoverable vs realtime-only), acquisition (durations, rejected/duplicate counts, missing intervals, largest gap, off-body/unknown), handoff (phone watermarks, durably-accepted IDs, backlog age), archive (manifest refs, checksum status, missing/corrupt/orphan, last archived event time), projection (input revision, completed/failed, algorithm version, readable snapshot revision), context/quality. The `coverage` object is counts-only.

**Recommended repair:** either (a) resurrect `day_completeness` with a service-role-only writer fed by the v2 scoring pass (fill from the same inputs `DayScorer` loads), or (b) define a successor projection/attestation table versioned by `input_revision` with a maintenance function writing on claim/publish. Wire the `/diagnostics` route (`serverScores.ts:135`, `server_pipeline_diagnostics`) to surface it. Note the existing `day_completeness` RLS is `authenticated` read / service-role write already (`20260830202255_day_completeness_harden.sql:5-7`).

---

## 2. Midnight closure and late-data revision (spec 4.5) — G2

### Verdict: FAIL for zone-based closure; PASS for event-time late-data attribution

**No per-user-zone boundary scheduling exists.**
- Only pg_cron workers: retention-sweep hourly, reconcile every 6 h, account-deletion every 15 min — `supabase/migrations/20260911140000_scheduled_workers_pg_cron.sql:47-78`; plus invalidation expansion every minute `20260930235500_expand_scoring_invalidations_cron.sql`. None closes days at any zone's midnight.
- No `midnight`/`overnight`/`finalize` references anywhere in `supabase/functions/_shared|push|scores|reconcile|retention-sweep` (grep). The dormant `day_completeness.overnight_state` machinery has no driver.

**What closes/advances a day is purely event-driven:**
- Day dirtiness is triggered by stream-table changes (`scoring_dirty_projection` triggers on `noop_hr_samples, noop_rr_intervals, noop_resp_samples, noop_gravity_samples, noop_events, noop_step_samples, noop_sleep_state_samples, noop_event_labels, sessions, sleep_nights` — `20260918010000_physiology_revisions.sql:193-199`) which call `scoring_enqueue_day` (2 s debounce) through `scoring_affected_days`.
- `claim_scoring_v2` orders: oldest-served user first, then "day waiting over an hour" escape, then `q.day > owner_today` false first, `day desc` — `20260930210000_claim_today_before_unbegun_days.sql:20-45`. So a "closed" day only becomes settled when a pass publishes (`completed_revision = input_revision`). No `closed-to-new-calendar-time` / `pending-reconciliation` state exists.
- **Consequence:** a quiet day (no new samples, phone offline) never gets any boundary processing server-side — the day stays `pending` with `completed_revision < input_revision` forever. Spec 4.5's "enqueue bounded, per-user work, including quiet streams with no next sample" is not implemented server-side. (Phone-side quiet-day handling is the g1/g3 workstream's scope.)

**Late-data revision is by event-time overlap — PASS (T05 partial).**
- `scoring_affected_days(p_user, p_start, p_end)` maps a UTC span to affected local days using `scoring_timezone_history` segments plus dependency-policy context days — `20260918010000_physiology_revisions.sql:76-98`. Unrepresentable clocks return empty (raw kept, no fabricated day).
- Raw object replay dirties days by object `start_at`/`end_at` overlap, not by filename/period_day: `noop_history_inventory_page` computes `affected_days` from `extract(epoch from m.start_at)`, `extract(epoch from m.end_at)` — `20260923160000_retained_history_recovery.sql:23-31`; `retained_history_recovery.sql:39` same for requeue. `server_pipeline_diagnostics` is the only place that filters objects by `period_day=p_day`, and it is explicitly a metadata-only diagnostic.
- DST-aware: `scoring_day_segments` (`20260918050000_physiology_calendar_ownership.sql:5-22`) and worker `DayScoring.dayStartUnix/nextDayStartUnix` use calendar arithmetic (`DayScoring.swift:28-49`), never `+86400`.
- Older-revision protection on raw append projection: `noop_apply_projection_rows` upsert ordering guard "a delayed archive repair cannot replace a newer accepted correction" — `20260918040000_production_projection_debt.sql:144-147`; replacement windows are tombstoned (`noop_projection_replacements`) and gated by `later_windows` (`...:235-240`). Local test `older unprojected archive cannot overwrite a newer correction; stale lease is fenced` PASSED.

**Recommended repair (closure):** add a bounded per-owner zone-boundary worker (or a `pg_cron` sweep keyed on `scoring_timezone_history`) that enqueues `scoring_enqueue_day` for each user's yesterday in that user's zone after local midnight + a settle window, and mark a per-day reconciliation state. Keep the existing event-time dirtying as the primary path.

---

## 3. Archive integrity and manifest reconciliation (spec 4.6) — G2

### Verdict: PASS (byte-level verification), with one gap (scheduled derived-object verify is HEAD/size-only)

**Byte verification — real hash-verified reads:**
- Object-lane completion: `verifyStoredObject` streams the verified copy, hashes wire + decoded content (SHA-256), checks both sizes and digest scope, and only then commits the receipt — `supabase/functions/_shared/durability.ts:62-171`; called from `completeDurableObject` (`durability.ts:224-...`). This is an independent hash-verified read, not a size-only HEAD.
- `noop_commit_object_receipt` atomically writes the receipt + `noop_signal_windows` index in one transaction and refuses mismatches (`object_verification_mismatch`, `receipt_immutable`) — `20260921060000_production_intake_durability.sql:168-...`.
- Verification lane re-downloads and re-hashes pending arrivals (wire digest, size, content digest for gzip) and re-uploads exact bytes to the verified key — `Tools/CloudWorker/Sources/frwhoop-worker/VerificationLane.swift:157-217`.
- Archive lane computes SHA-256 of the exact uploaded payload bytes and validates via `complete_scoring_archive_v2` (fenced on lease token) — `ArchiveLane.swift:67-96`; outbox path validates object identity (`sha256/size/owner/format`) before completing — `ArchiveLane.swift:180-236`.
- Projection replay re-verifies wire + content digests before applying rows (`ProjectionLane.swift:169-190`) and re-registers client-claimed digests as `server_verified` (`ProjectionLane.swift:195-204`).

**Reconciliation paths:**
- `supabase/functions/reconcile/index.ts:23-36` runs: `reconcileObjectVerification` (async-verification debt), `reconcileIntake` (pending/repair objects, byte-verifying, 16/invocation, persistent cursor), `reconcileProjections` (seed + claim + readVerifiedArchive + commit; 16/invocation), `sweepCopyIntents`, then `reconcileObjects`.
- `reconcileObjects` (`_shared/workers.ts`): object-without-manifest / manifest-without-object / orphan census / HEAD existence for derived rows; raw rows are explicitly excluded there ("Raw intake has its own paginated, byte-verifying, atomic-index reconciler") — `workers.ts:121-` and the raw skip at `reconcileObjects` head.
- Corrupt derived row: `reconcile marks derived ready row corrupt when B2 HEAD is missing` — TEST-VERIFIED PASS (workers_test.ts).

**Gap:** scheduled `reconcileObjects` uses HEAD + size for non-raw (derived) rows and `verifyChecksums` defaults to false (`workers.ts` `reconcileObjects` call in `reconcile/index.ts`). So stale derived objects are detected as missing/corrupt on HEAD only; byte re-verification of derived objects happens at upload time, not in the 6-hourly sweep. Acceptable given ArchiveLane's upload-time verification, but not a periodic byte-verification of stored derived objects.

**Blocked:** actual B2 permissions/checksum behavior, the deployment schedule, and backlog drain are staging/deployed checks — NOT VERIFIED here.

---

## 4. ACK vs verified archival (spec 2 invariant; DURABILITY_RECEIPT.md) — G2

### Verdict: PASS (code-verified)

- `supabase/functions/DURABILITY_RECEIPT.md`: the receipt `state: verified_indexed` attests stored bytes + index, not scorer completion; no bare ready flag / HTTP 2xx / legacy ACK is a receipt; legacy repaired objects without batch/source metadata are retained until the original intent retry binds identity.
- Inline path ordering: WAL append (`noop_push_wal`) → archive object (`archiveObject`) → `commitProjection` (`noop_commit_push_projection`) — ACK (with `durabilityReceipt.state=verified_indexed`) is returned only after the object is archived+verified and rows projected, and WAL is trimmed only inside that settlement — `supabase/functions/_shared/ingest.ts:418-451`; atomic settlement `20260918040000_production_projection_debt.sql:153-278` (applies rows, saves ACK, deletes WAL, completes debt in one transaction; replays return the stored ACK without re-application, `:179-185`).
- Object lane: `completeObject` → presigned PUT → server COPY to verified key → full `verifyStoredObject` → receipt; only then do windows/projection/ACK exist. Async completion defers to `noop_object_verification_debt`, and the worker's verification lane settles it — no `ready` row implies a check that was never run (objects.ts `SHA_SOURCE` comment).
- Outbox (legacy `server_physiology_results`) is retained until archive succeeds: `physiology_archive_outbox` rows only reach `status='verified'` after the object is uploaded and the manifest registered in ONE fenced transaction (`ArchiveLane.swift:180-236`); a lost lease rolls back the manifest insert and the row retries with backoff.
- `noop_upload_receipts` (the phone-facing acceptance record) is written separately from the durability receipt, matching "server acceptance ACK and verified cloud archival completion are different milestones".
- TEST-VERIFIED: `intake_integration_test.ts` (22/23 steps pass), `copy_intents_integration_test.ts` (13/13), `object_verification_integration_test.ts` (all but 1 message-masking step), `scalar_integration_test.ts` (3 steps fail on message masking only).

---

## 5. Deterministic replay (T12) — G2

### Verdict: PARTIAL — code supports replay; no wipe-and-rebuild harness; projection lane OFF in production

- Projection lane exists and replays verified archives (`noop_projection_debt` → download → digest verify → `noop_commit_push_projection`), and the edge-side `reconcileProjections` (`_shared/projections.ts:92-`) does the same for inline NDJSON.
- **Projection lane is OFF in production** (documented drop-in `FRWHOOP_DISABLE_LANES=projection`, docs/BACKEND.md; code honors `disabledLanes`, `main.swift:181-209`). Queue holds ~16,000 stale rows from other test devices that fail on every attempt (BACKEND.md Known issues). So today the only active replay path is the edge `reconcile` function's `reconcileIntake`/`reconcileProjections`.
- Derived wipe/rebuild: `reproject_scoring_legacy_v2(user, version)` rebuilds `server_daily_scores`/`server_sleep_nights` from immutable snapshots (derived rows only, idempotent) — `20261001190000_baseline_device_selection.sql`; `server_metric_series` is "derived, rebuildable" (rebuilt by the next scoring pass, BACKEND.md). No full "wipe derived tables and rebuild from verified archives" RPC/harness exists.
- Local replay-convergence tests that DO run and PASS: `intake_integration_test.ts` steps "server-only replay repairs archive-to-projection crash and invalidates a settled score", "lost settlement response and duplicate replay cannot overwrite a later correction or reinvalidate", "older unprojected archive cannot overwrite a newer correction; stale lease is fenced", "concurrent pending settlement commits one projection and one invalidation generation", "delayed replacement replay preserves newer overlapping corrections and deletions"; `scalar_integration_test.ts` "server-only replay repairs verified archive crash and dirties settled scores" (step itself passes; the file fails only on unrelated message-masking asserts).
- The history-v3 stateful lineage (`scoring_history_checkpoints_v3`, `claim_scoring_history_v3`, `publish_scoring_history_v3` — `20260918050000_production_scoring_history.sql`) exists in schema but is NOT referenced by the worker or any edge function (grep). It is dormant.

**Blocked (NOT VERIFIED):** full `real_recording_replay_sql_test.ts` requires a Docker DB + a private real recording (`PIPELINE_TEST_REAL_RECORDING`), and `bounded_recovery_intake_sql_test.ts` / `multiuser_sql_test.ts` / `multiuser_worker_sql_test.ts` / `intake_consumer_sql_test.ts` require `PIPELINE_TEST_DATABASE_CONTAINER`. No wipe-and-rebuild-from-verified-archives acceptance test exists in the local harness; this is an open requirement per spec 4.6 ("A replay unavailable under the configured database transport is an open requirement").

**Recommended repair:** add a test-only `wipe_derived_then_replay(user, day_range)` SQL fixture (truncate `server_daily_scores`, `server_sleep_nights`, `server_metric_series`, `scoring_snapshots_v2` derived? — careful: snapshots are immutable and archived, so wipe only derived read models) then re-run `reproject_scoring_legacy_v2` + a fresh scoring pass; assert identity/count/day/coverage equality against the pre-wipe baseline with numerical tolerances. Decide whether to dead-letter the 16,000 stale projection-debt rows so the lane can run again (see §7).

---

## 6. Older-revision publication fencing (T31) — G2/G5

### Verdict: PASS for snapshots; GAP (low) for the intraday series side channel

**Snapshot publication is fenced atomically:**
- `publish_scoring_snapshot_v2` locks the job row `for update` and returns NULL (not success) when `j.lease_until<=clock_timestamp()` or `j.input_revision<>p_revision`, when the algorithm is disabled, or when an invalidation covers the day — `20260918010000_production_scoring_durability.sql:230-240`. The worker parses the result and never treats NULL as success (`ScoringLane.swift:343-375`, `releaseV2Lease` at `:600-620`). An older revision finishing later therefore cannot replace a newer snapshot.
- Snapshots are immutable (`reject_snapshot_update_v2` trigger) and revision-unique (`unique (user,device,day,algo,input_revision)`).
- The legacy fleet lane is likewise fenced on lease token + run id (`scoring_legacy_finish_work` `'done'`/`'failed'` branches; `ScoringLane.swift:226-292`).
- history v3 publication has generation + predecessor + profile/config revision checks (`20260918050000_production_scoring_history.sql`, `publish_scoring_history_v3`) but is dormant (not wired).

**Gap — intraday series is not input-revision fenced:**
- `publish_metric_series_v1` validates the calling device is the day's canonical device (`selected_scoring_device_v2`) but has NO `input_revision` check — `20261001210000_metric_series.sql:60-110`. `publishSeries` runs AFTER the snapshot transaction commits (`ScoringLane.swift:494-540`). Sequence: pass A publishes rev N, commits, then a slow series write; upload bumps rev N+1; pass B publishes rev N+1 and writes its series; A's delayed series write (same device) overwrites B's buckets with rev-N values. Every scoring pass rebuilds the whole day and the next pass repairs it, and a new upload re-dirties the day, so impact is bounded and self-healing — but T31's "latest projections remain newer" does not strictly hold for this derived side channel. A stale series write cannot touch `scoring_snapshots_v2`, `server_daily_scores` (guarded by `refresh_scoring_legacy_v2` within the fenced publish), or baselines.

**Recommended repair:** pass the claimed `input_revision`/`result_revision` into `publish_metric_series_v1` and return `not_selected`/`stale` when the job row's current `input_revision` or the snapshot's `result_revision` is newer; or record `result_revision` in the payload and have the function reject writes older than the latest committed snapshot revision for the day.

---

## 7. Worker failure boundaries / convergence — G2

### Verdict: PASS with one convergence gap

- **ProjectionLane decode failures are now durably recorded** (prior audit P1-1 defect FIXED in this tree): decode/`projectionRows`/`keepKeys` throws route through `failDebt` (`ProjectionLane.swift:203-214`); deterministic non-projectable kinds are classified `skipped` (bounded, not a lane error, `:120-135`); missing objects are `deferred` (never burn a retry, `:141-152`). `noop_fail_projection_debt` backs off with exponential `not_before` (`failures capped at 16, ≤1 h`) — `20260918040000_production_projection_debt.sql:106-113`.
- **Gap:** projection debt has **no dead-letter state** (documented in `ProjectionLane.swift:13-20`). Deterministic poison rows are retried hourly forever; the ~16,000 stale rows from 12–20 September (other test devices) are exactly why the lane is off in production (BACKEND.md Known issues). They cannot block other work (claim is `ORDER BY not_before,created_at ... SKIP LOCKED`, `:94-98`) but the backlog never converges and the lane's budget burns on it.
- Scoring v2: `fail_scoring_v2` dead-letters at 8 consecutive failures with exponential backoff — `20260918010000_production_scoring_durability.sql:162-167`. Archive v2: dead-letters at 12 — `:337-342`. Legacy work items: `exhausted` at 8 (`scoring_legacy_finish_work`).
- The scoring lane distinguishes `connectionLost` (lease expiry recovers), `serialization/stale` (retried with jitter, never recorded as failure), `deterministic` (settled failed) — `ScoringLane.swift:12-35, 251-293`; failure settlement is fenced and its success verified (`failuresPersisted` vs `failuresUnsettled` counters).
- Heartbeat records per-lane counters, last error (sanitized to the column CHECK), queue ages per lane, revision, and distinguishes `db_blocked` from idle — `main.swift` (`queueAgeQuery`, `pollState`, `heartbeat`), TEST-VERIFIED by `WorkerHardeningTests` (26 tests) and lane wiring in `main.swift:181-320`.
- All 134 worker unit tests pass locally (`swift test --filter "VerificationLaneTests|DayScoringAdapterTests|InputGateTests|WorkerHardeningTests|LegacyClaimGateTests|IntradaySeriesTests|PushBatchTests"` — 134 executed, 1 skipped [on-disk fixture corpus], 0 failures).

**Recommended repair:** add a terminal disposition to `noop_fail_projection_debt` (e.g. `state='quarantined'` with reason after 16 failures, kept as evidence), then clear/dead-letter the 16,000 stale rows under operator review so the projection lane can be re-enabled.

---

## 8. Quarantine of malformed records — G2

### Verdict: PASS (bounded evidence + reason accounting), one gap

- Conflicting/duplicate measurements are recorded, not silently resolved: `noop_projection_conflicts (user,device,stream,measurement_key,detected_at,reason)` — `20260921111000_wearable_lifecycle.sql:40-46`; the append projection writes the conflict key, deletes the stored row and refuses that key thereafter (BACKEND.md Known issues; `noop_project_append_batch` and `set_based_append_projection`). Raw evidence stays in `noop_projection_observations`.
- RR clock conflicts: `noop_rr_clock_conflicts` (`wearable_lifecycle.sql:49-53`).
- Invalid CRCs / unsupported layouts retain evidence with reason accounting: `noop_projection_observations`, `noop_projection_debt.last_error`, `noop_rr_packet_provenance` raw bytes, and the `noop_projection_conflicts.reason` column. The DURABILITY_RECEIPT.md explicitly: "Signal-window sample counts remain client declarations"; `sensor_raw_coverage_unknown` trigger nulls coverage for ppg/imu/v18Aux/rawBatch so client intake cannot self-qualify (`20260921120000_sensor_acquisition_windows.sql:8-13`).
- Malformed records do not block valid work: append conflicts refuse only their own key; projection debt rows back off individually and claims are SKIP LOCKED; retention-sweep holds unsettled NDJSON (server repair source) rather than deleting bytes (`_shared/workers.ts` `sweepExpiredManifests`).
- **Gap:** no bounded evidence-bucket for the *content* of malformed raw records (only identity keys + reason + row_data in `noop_projection_observations`); a rejected record's row_data is retained unbounded. Confirm retention policy is bounded as required (research objects are indefinite by design, `_shared/retention.ts`).

---

## Test commands found and run (read-only, throwaway local PG)

Cheap no-DB Deno tests (all PASS):
```
cd supabase/functions
deno test --allow-env --allow-read tests/workers_test.ts tests/zstd_bounds_test.ts tests/keys_test.ts
deno test --allow-env --allow-read tests/bounded_recovery_test.ts tests/ingest_verify_test.ts tests/registry_test.ts tests/push_diagnostics_test.ts tests/zstd_ios_golden_test.ts tests/worker_auth_test.ts
deno test --allow-env --allow-read tests/append_projection_test.ts tests/staging_test.ts tests/s3_test.ts tests/result_days_test.ts tests/standard_hr_receipt_test.ts
```
Local-Postgres harness tests (need `EDGE_TEST_ARTIFACTS` outside checkout; throwaway cluster, no shared DB):
```
deno test --cached-only --allow-env --allow-read --allow-write=<artifacts> \
  --allow-run=/opt/homebrew/bin/initdb,/opt/homebrew/bin/pg_ctl,/opt/homebrew/bin/psql,/opt/homebrew/bin/postgrest \
  --allow-net=127.0.0.1,localhost tests/<file>.ts
# PASS: input_selection_test, identity_provenance_integration_test, copy_intents_integration_test
# FAIL (message-masking only): intake_integration_test (22/23 steps pass), object_verification_integration_test, scalar_integration_test
```
Swift worker unit tests (macOS; `PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig`):
```
cd Tools/CloudWorker
PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig swift build --build-tests
PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig swift test --filter "VerificationLaneTests|DayScoringAdapterTests|InputGateTests|WorkerHardeningTests|LegacyClaimGateTests|IntradaySeriesTests|PushBatchTests"
# 134 executed, 1 skipped (on-disk fixture corpus missing), 0 failures
```
Blocked (require external services/fixtures): `real_recording_replay_sql_test.ts` (Docker + private recording), `multiuser_sql_test.ts`/`multiuser_worker_sql_test.ts`/`intake_consumer_sql_test.ts`/`server_pipeline_sql_test.ts`/`bounded_recovery_intake_sql_test.ts` (Docker `PIPELINE_TEST_DATABASE_CONTAINER`), `object_representation_integration_test.ts` (external Swift fixture `representation-compatibility.json`).

## Test-suite finding (regression in THIS tree)

- `supabase/functions/_shared/rest.ts:12-16` masks every 401/403/`42501` RPC response into `RestAuthorityError('supabase_authority_rejected')` (deliberate: "Arbitrary SQL messages/codes remain private"). The repo's own integration tests assert on propagated error codes/messages:
  - `tests/intake_integration_test.ts:73` expects `/device_owner_conflict/` from a foreign-device intent.
  - `tests/object_verification_integration_test.ts:247` expects `/permission denied/` from an unfenced RPC.
  - `tests/scalar_integration_test.ts:102` expects `error.code === 'device_owner_conflict' && error.status === 403`.
- With the current `rest.ts`, all three fail; the underlying durability/projection/verification steps themselves pass (22/23 in intake, 13/13 in copy_intents). This is an internal test/implementation mismatch at HEAD, not a data-durability defect. Either tests should assert `supabase_authority_rejected` + HTTP status, or `rest.ts` should expose a safe `code` field for these specific server conditions.

## NOT VERIFIED / blocked checks (exact)

1. Deployed worker revision identity: `FRWHOOP_SOURCE_REVISION` env vs actual running binary (droplet) — code hashes non-40-hex values (`main.swift:170-180`), but the deployed env value is not inspectable here. Prior audit (2026-09-30) found the deployed env stale; re-verify on the host.
2. Actual B2 provider checksum/ETag/versioning behavior, object copy/delete latency, retention schedule drain — needs deployed/staging storage.
3. Zone-based midnight closure in production (does not exist in code; nothing to verify on device).
4. Full replay determinism harness (wipe derived read models, rebuild, compare counts) — no local test exists; `real_recording_replay_sql_test.ts` needs Docker + private recording.
5. The 16,000 stale projection-debt rows and whether the projection lane is actually disabled by the systemd drop-in on the host.
6. Heart-rate conflict history (BACKEND.md: ~51,838 removed seconds, 30 Sep–2 Oct) — live-data repair decision pending; cannot be verified here.
7. `server_metric_series` stale-write window (T31 series gap) — needs a live two-pass race to confirm; code-path analysis only.
8. `day_completeness`/`ingest_gaps` tables' actual state in the deployed DB (rows may exist from the older lineage) — deployed DB read required.

## Files that need changes (recommended next actions)

1. `supabase/functions/_shared/rest.ts` + `tests/intake_integration_test.ts`, `object_verification_integration_test.ts`, `scalar_integration_test.ts` — reconcile error-code propagation (align tests to the masked contract or expose safe codes).
2. New migration: revive or replace `day_completeness` as a service-role-written, versioned per-day attestation record fed by the v2 scoring pass (spec 4.4 fields), or document the snapshot `coverage` as the sole attestation.
3. New migration + worker change: per-user-zone midnight closure work (enqueue quiet days after local midnight in `scoring_timezone_history` zones) and a `closed/pending_reconciliation` day state.
4. `publish_metric_series_v1` (migration `20261001210000_metric_series.sql`) + `ScoringLane.publishSeries` — add input/result-revision fencing.
5. `noop_fail_projection_debt` (migration `20260918040000_production_projection_debt.sql`) — add dead-letter/quarantine after 16 failures; operator-cleared stale backlog so the projection lane can re-enable.
6. Add a wipe-derived-then-replay acceptance fixture/test for T12.
