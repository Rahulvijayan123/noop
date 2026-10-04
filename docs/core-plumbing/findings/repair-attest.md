# repair-attest — server/worker durability repairs

- Agent: `repair-attest` (g2-attestation items 1/2/3/4/5 + g56 P2 + root task 7).
- Tree: `nara-core-plumbing`, branch `audit/core-plumbing-20261003`.
- Date: 2026-10-03. Verification: TEST-VERIFIED against the throwaway local-PG harness
  (`EDGE_TEST_ARTIFACTS=/tmp/net`) and the Swift worker suite. No shared/production DB touched.
- Deno version note: repo pins Deno 2.5.6 (external npm package, not present in this
  environment); every Deno run used local Deno 2.9.7 (same as the g2/g5 audit workers) and
  two runs re-verified with `--cached-only --frozen --lock=deno.lock` (no dependency drift).

---

## 1. rest.ts error-code propagation (C4; g2 regression at HEAD)

**Root cause (root-verified):** `rest.ts` collapsed every receiver authority rejection into
`supabase_authority_rejected` except the single `intake_admission_scope_mismatch` special case,
so the repo's own integration tests (which assert on propagated codes) failed.

**Fix (`supabase/functions/_shared/rest.ts`):**
- `RestAuthorityError` now accepts any bounded receiver code and exposes `error.code`
  (`receiverCode ?? 'supabase_authority_rejected'`).
- The authority branch propagates `json.message` when it matches `/^[a-z0-9_]{3,64}$/`
  (device_owner_conflict, object_owner_conflict, intake_admission_scope_mismatch, recovery_*);
  the standard Postgres `permission denied ...` family is surfaced as the bounded canonical
  phrase `permission denied` (no object names); everything else stays `supabase_authority_rejected`.
- `durability.ts:intakeError` needed no change: it already maps the propagated message to
  `PushProtocolError(code, 403)`.

**Tests (all previously red, now green):**
- `intake_integration_test.ts` — 24/24 steps PASS (was 22/23, the foreign-device
  `/device_owner_conflict/` assert now passes).
- `scalar_integration_test.ts` — 19/19 steps PASS (was 16/19; `error.code ===
  'device_owner_conflict' && error.status === 403` and `object_owner_conflict` now pass).
- `object_verification_integration_test.ts` — 14/14 steps PASS (was all-but-1; the
  `/permission denied/` unfenced-RPC assert now passes).
- Regression: no-DB suite (14 files, 86 tests) + local-PG regression (input_selection,
  identity_provenance, copy_intents, intake, object_verification, scalar — 8 tests / 77 steps)
  all PASS, including `bounded_recovery_test.ts` (authority/recovery classification unchanged).

## 2. physiology_archive_outbox 'retry' status (g56 P2 / C5)

**Root cause:** `20260918020000_physiology_publication.sql` CHECK allowed only
`('pending','uploading','uploaded','verified','failed')`, but `ArchiveLane.swift:256`
`releaseOutboxLease` writes `status='retry'`; the write failed, rows looped on 300 s lease
expiry re-uploading with no backoff.

**Fix (`supabase/migrations/20261003201000_outbox_retry_status.sql`):** drop/re-add the status
CHECK (auto-named `physiology_archive_outbox_status_check`) admitting `'retry'`; additive, IF EXISTS.

**Test (`supabase/functions/tests/outbox_retry_integration_test.ts`, 3 steps PASS):** applies
`20260918020000` + the fix, then drives the exact claim/release SQL from ArchiveLane.swift:
release commits (pre-fix it raised 23514), status='retry', 30 s backoff applied, lease cleared,
claim skips a backing-off row and picks a due 'retry' row.

## 3. publish_metric_series_v1 input-revision fence (g2 item 4 / T31)

**Fix (`supabase/migrations/20261003202000_metric_series_input_revision_fence.sql`):** new
fenced 6-arg `publish_metric_series_v1(..., p_input_revision bigint)`; null/<=0 revision raises
22023 (cannot be bypassed); a claimed revision older than the day's latest
`scoring_jobs_v2.input_revision` (same user/device/day) returns
`{applied:false, reason:'superseded', claimed_input_revision, latest_input_revision}` with NO
write. The 6-arg body is the current 5-arg body (incl. `metric_bucket_seconds`) plus the fence.
The legacy 5-arg stays callable for the psql fixture and back-compat (service-role only); the
production writer now uses the fenced form.

**Worker (`ScoringLane.swift`):** `publishSeries` passes `claim.inputRevision` via new static
`seriesPublishSQL` (6-arg) and classifies the reply with the new pure
`classifySeriesOutcome` (`.applied/.superseded/.skipped/.malformed`); superseded is counted in
the new `seriesSuperseded` counter — never success, never failure.

**Tests:** `supabase/functions/tests/metric_series_fence_integration_test.ts` (5 steps PASS:
stale→superseded+nothing written, current→applied, null→22023, not_selected, 5-arg compat) and
`Tools/CloudWorker/Tests/frwhoop-workerTests/SeriesFenceTests.swift` (8 PASS).

## 4. Projection debt dead-letter (g2 item 5)

**Fix (`supabase/migrations/20261003203000_projection_debt_dead_letter.sql`):** adds
`noop_projection_debt.dead_letter boolean` + `dead_letter_reason`; `noop_fail_projection_debt`
now dead-letters at the 16th consecutive failure (`projection_replay_exhausted`) while keeping
the capped exponential backoff for transient failures; `noop_claim_projection_debt` excludes
`not q.dead_letter` (mirrors `claim_scoring_v2`). Migration comment documents the operator path
(inspect / batch dead-letter / reactivate / purge) for the existing ~16 k stale rows — NO
production rows touched.

**Worker:** no ProjectionLane change needed (signature unchanged; the lane already routes
failures through `noop_fail_projection_debt`).

**Test (`supabase/functions/tests/projection_debt_dead_letter_integration_test.ts`, 4 steps
PASS):** failures 1..15 stay pending+backed off, 16th dead-letters with bounded reason, claim
never returns a dead-lettered row (even with a verified manifest), operator reactivation works.

## 5. Day attestation revival (g2 item 2 / spec 4.4)

**Fix (`supabase/migrations/20261003204000_day_attestation.sql`):** revives the dormant
`day_completeness` table: adds `device_id`, `input_revision`, `attestation jsonb`,
`attestation_version`; new service-role `publish_day_attestation_v1` upserts ONE versioned
record per (user, day) fenced on input_revision (older refused as superseded; equal revision
accepted only from the same device = idempotent retry). `status` stays 'open' (no fabricated
continuity verdict).

**Worker (`DayScoring.swift` + `ScoringLane.swift`):** after a successful snapshot publish,
`publishAttestation` writes a compact spec-4.4 record built by the new pure
`DayScorer.dayAttestation` — identity/time (owner, device, day, zone, policy version
'job-calendar-1', calendar-correct day bounds, input_revision, as_of, algorithm), real stream
counts + status/dataThrough from the published snapshot, factual projection completion
(snapshot_result_revision), and explicit `not_measured` markers for everything the pass cannot
know (coverage durations, gaps, rejected/duplicates, off-body/unknown, handoff watermarks,
archive/manifest status, wear/placement/arbitration). Never throws.

**Tests:** `supabase/functions/tests/day_attestation_integration_test.ts` (5 steps PASS) and
`Tools/CloudWorker/Tests/frwhoop-workerTests/DayAttestationTests.swift` (7 PASS, incl. DST
bounds and not_measured coverage).

## 6. Zone-aware midnight closure (g2 item 3 / spec 4.5)

**Fix (`supabase/migrations/20261003205000_day_closure_scheduling.sql`):** adds
`day_completeness.closure_state` (`pending_reconciliation` / `closed`) and service-role
`scoring_enqueue_due_day_closure(p_limit=16, p_version='frwhoop-server-1', p_settle_seconds=600)`:
scans each user's active devices, computes local YESTERDAY from `profiles.timezone` via
Postgres `AT TIME ZONE`, and — once yesterday's local midnight + settle window has passed and
the v2 job is still pending (completed_revision < input_revision, not dead_lettered) and not
already closure-marked — enqueues `enqueue_scoring_v2(...,'day_closure')` and marks
`pending_reconciliation` in ONE transaction (idempotent). `publish_day_attestation_v1` is
re-created to advance `pending_reconciliation → closed` when a publish lands for that day.

**Worker (`ScoringLane.swift`):** `maybeSweepDayClosure` runs on the existing poll loop,
throttled to once per 60 s (`dayClosureSweepIntervalSeconds`), bounded batch 16; failures are
counted (`dayClosureFailed`) and never fail a cycle. No new cron.

**Tests:** `supabase/functions/tests/day_closure_integration_test.ts` (5 steps PASS: enqueue
once + mark pending, idempotent no-op, publish→closed, closed stays quiet, no-job day ignored)
and `Tools/CloudWorker/Tests/frwhoop-workerTests/DayClosureTests.swift` (5 PASS). Boundary
math documentation: authoritative = Postgres `AT TIME ZONE` in the RPC; worker tests pin the
mirror helper `DayScorer.closureDue` + the statement shape (documented in the test file).

## 7. Verification-lane durable quarantine (root task 7 / spec 4.6)

**Root cause (live trace):** a wire-scope manifest with NO recorded digest is deterministically
unverifiable (`VerificationLane.swift:558`); `rememberNegative` is in-process only, so after
every restart the manifest is re-downloaded + re-hashed + re-rejected forever.

**Fix (`supabase/migrations/20261003205900_verification_quarantine.sql` + `VerificationLane.swift`):**
- Migration: `object_manifests.verification_failure_code` (CHECK `^[a-z0-9_]{3,64}$`),
  `verification_failed_at` (first-quarantine, idempotent), `verification_attempts` (capped 16);
  service-role `noop_quarantine_manifest_verification`.
- Worker: `candidateSQL` now requires `verification_failure_code IS NULL`; a deterministic
  mismatch (new pure `isDeterministicMismatch` + `quarantineCode`) durably quarantines the
  object (best-effort, never crashes the cycle); the in-process negative cache is kept.
- Transient mismatches (torn upload, gunzip/zstd failure, plain wire/compressed-size mismatch,
  missing object) stay bounded-retry/deferred and never get a code.

**Tests:** `supabase/functions/tests/verification_quarantine_integration_test.ts` (4 steps PASS:
quarantine recorded, repeat idempotent + capped, invalid code rejected whole, candidateSQL
predicate excludes quarantined / keeps normal) and `VerificationLaneTests.swift` (+9 PASS:
deterministic vs transient classification, bounded code mapping, candidateSQL exclusion +
transient still selected).

---

## Files changed (all inside the ownership list)

- `supabase/functions/_shared/rest.ts` (modified)
- `supabase/migrations/20261003201000_outbox_retry_status.sql` (new)
- `supabase/migrations/20261003202000_metric_series_input_revision_fence.sql` (new)
- `supabase/migrations/20261003203000_projection_debt_dead_letter.sql` (new)
- `supabase/migrations/20261003204000_day_attestation.sql` (new)
- `supabase/migrations/20261003205000_day_closure_scheduling.sql` (new)
- `supabase/migrations/20261003205900_verification_quarantine.sql` (new)
- `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift` (modified)
- `Tools/CloudWorker/Sources/frwhoop-worker/ScoringLane.swift` (modified)
- `Tools/CloudWorker/Sources/frwhoop-worker/VerificationLane.swift` (modified)
- `Tools/CloudWorker/Tests/frwhoop-workerTests/SeriesFenceTests.swift` (new)
- `Tools/CloudWorker/Tests/frwhoop-workerTests/DayAttestationTests.swift` (new)
- `Tools/CloudWorker/Tests/frwhoop-workerTests/DayClosureTests.swift` (new)
- `Tools/CloudWorker/Tests/frwhoop-workerTests/VerificationLaneTests.swift` (modified, +9 tests)
- `supabase/functions/tests/outbox_retry_integration_test.ts` (new)
- `supabase/functions/tests/metric_series_fence_integration_test.ts` (new)
- `supabase/functions/tests/projection_debt_dead_letter_integration_test.ts` (new)
- `supabase/functions/tests/day_attestation_integration_test.ts` (new)
- `supabase/functions/tests/day_closure_integration_test.ts` (new)
- `supabase/functions/tests/verification_quarantine_integration_test.ts` (new)
- `supabase/functions/tests/_repair_attest_smoke_test.ts` (new; ordered-apply smoke test)

`durability.ts`, `ProjectionLane.swift`, `PostgresClient.swift` were NOT changed (the
intakeError mapping and the dead-letter path needed no worker-side change).

## Test results (summary)

- Swift worker: `CPATH=/opt/homebrew/opt/libpq/include swift test` →
  **243 executed, 6 skipped (baseline), 0 failures** (baseline 214/6; +29 new tests all pass).
- Deno no-DB regression (14 files): **86 passed, 0 failed**.
- Deno local-PG regression (6 files incl. the 3 previously-red): **8 tests / 77 steps, 0 failed**.
- Deno new migration tests (6 files): **6 tests / 26 steps, 0 failed**.
- Combined ordered-apply smoke of all six new migrations: **PASS**.

## Contract decisions applied

- C1: new migrations only, one transaction, house style (security definer + search_path, RLS
  service-role writers, column comments); never touched a real DB.
- C2: day bounds are calendar-correct local midnights (`AT TIME ZONE` / Calendar arithmetic);
  closure uses `profiles.timezone`; no fixed 86400 anywhere.
- C3: no owner reassignment anywhere; all new writers validate device ownership.
- C4: receiver codes propagate through rest.ts when safe; `supabase_authority_rejected` only as
  fallback; bodies stay out of logs (only the bounded code/phrase is surfaced).
- C5: outbox 'retry' is now a legal status; projection debt dead-letters at 16 with capped backoff.
- C6/C7: tests run with the exact commands; report in `docs/core-plumbing/findings/repair-attest.md`.

## Remaining gaps / NOT VERIFIED

1. Pinned Deno 2.5.6 binary not present in this environment; all Deno runs used 2.9.7
   (matching prior audit workers). Two new-test runs re-verified with `--frozen --lock=deno.lock`.
2. The legacy unfenced 5-arg `publish_metric_series_v1` remains callable (service-role only) for
   the psql fixture/back-compat; it cannot be fenced because it carries no claimed revision.
   The production writer always uses the fenced 6-arg form.
3. Edge-side `reconcileIntake`/`reconcileObjects` (supabase/functions/_shared/workers.ts, not in
   this ownership) still selects raw `status='ready'` manifests without the
   `verification_failure_code IS NULL` predicate; a durably-quarantined raw object could still be
   re-examined there (bounded/paginated, not the worker's convergence loop). Recommend extending
   those predicates in the diag/reconcile workstream.
4. The ~16 k stale projection-debt rows are NOT dead-lettered here (operator action only, per the
   migration comment); the projection lane remains OFF in production until an operator reviews.
5. `day_completeness` in the deployed DB may hold older-lineage rows; my fence advances only on
   newer input_revision, so stale legacy rows are simply not overwritten until a v2 pass publishes
   at a newer revision.
6. Zone-closure sweep runs only while the v2 scoring lane's poll loop is alive (single worker);
   if the worker is down at a user's midnight, the day is picked up on the next sweep (bounded,
   idempotent) — no realtime guarantee.


---

## Addendum — dayWindow wiring at the analyzeDay call site (repair-daybucket integration)

- **Change (exactly one call-site parameter):** `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift`
  `scoreAndBuildPayloads` now passes
  `dayWindow: LocalDayWindows(timeZone: tz).window(ofDayKey: claim.day)` to
  `AnalyticsEngine.analyzeDay` (placed after `tzOffsetSeconds:`, matching the signature's declared
  argument order). Verified against `Packages/StrandAnalytics/.../LocalDayWindows.swift`
  (`public func window(ofDayKey:) -> LocalDayWindow?`) and the new
  `dayWindow: LocalDayWindow? = nil` parameter (nil falls back byte-identical to the old
  fixed-offset + 86,400 block). On DST transition days the worker now re-buckets with the
  zone-correct half-open window, matching the app; every non-DST day stays byte-identical.
- **Focused worker tests** (natural hook: the value of the exact expression at the call site):
  added to `DayScoringAdapterTests` — (a) `dayWindow` `[start, end)` equals the worker's own
  `dayStartUnix`/`nextDayStartUnix` for spring/fall/normal days, (b) the window is 23 h on
  2026-03-08 (America/New_York), 25 h on 2026-11-01, 24 h on a normal day (never a fixed 86,400
  block). A regression to the old fixed-offset value fails these tests.
- **Verification:** `CPATH=/opt/homebrew/opt/libpq/include swift test` →
  **245 executed, 6 skipped (baseline), 0 failures** (243 baseline + 2 new focused tests).


---

## Addendum 2 — re-audit repair round (audit-g5g6-isolation P2-1 + P2-3)

- **New migration `supabase/migrations/20261003230100_repair_attest_fence_scope_and_retirement.sql`**
  (in the re-audit range 20261003230000-20261003230999), additive, one transaction:
  - **P2-1 (metric-series fence scope):** `publish_metric_series_v1` (6-arg) fence now uses
    `max(input_revision)` over `scoring_jobs_v2 WHERE user_id=p_user AND day=p_day` — the USER/DAY
    max across all of the day's devices — instead of the calling device's own max. `server_metric_series`
    writes/deletes are device-agnostic (keyed (user, metric, bucket_start)), so freshness must be
    day-scoped; a stale pass from a device whose own job row holds an older revision (the A→B→A
    mid-day selected-device switch) is now rejected as `superseded`. The `selected_scoring_device_v2`
    'not_selected' gate is unchanged.
  - **P2-3 (closure resurrection window):** `scoring_enqueue_due_day_closure` now excludes owners
    present in `noop_account_retirements` (the tombstone `begin_noop_account_deletion` inserts,
    20260921113000), so a frozen owner gets NO closure enqueues during the deletion-freeze window.
    CLAIM-PATH RESIDUAL (documented in the migration comment, not changed): `enqueue_scoring_v2` /
    `claim_scoring_v2` still do not check retirements, so a job queued BEFORE a freeze can still be
    claimed/published until the cascade delete completes — bounded and self-cleaning (reads already
    blocked by retirement checks; rows cascade-deleted at deletion completion). Left as a documented
    residual because a claim-side check was judged too invasive for this minimal repair.
  - Note: the retirement subquery uses the table alias `ret` (not `r`) — a subquery alias matching
    the PL/pgSQL loop record variable would resolve to the record and raise "record r is not assigned
    yet" (a PL/pgSQL variable-substitution quirk, reproduced and fixed during testing).
- **New test `supabase/functions/tests/metric_series_fence_user_scope_test.ts`** (4 steps PASS):
  deviceA job rev 3 + deviceB job rev 5 with deviceA selected → stale deviceA pass claiming 3 is
  rejected `superseded` with `latest_input_revision=5` (proves the user/day scope, not deviceA's 3);
  newest pass via ANY device (deviceB at 5, selected) applies; after the applied write, a stale
  deviceA pass is still rejected and the applied series survives; the not_selected gate is unchanged.
- **New test `supabase/functions/tests/day_closure_retirement_test.ts`** (3 steps PASS):
  a `noop_account_retirements`-frozen owner gets NO closure enqueue (revision stays 1, no
  pending marker) while an active owner is enqueued; the frozen owner stays un-enqueued on the next
  sweep.
- **Regression:** all 9 migration/integration tests (33 steps) PASS, including the earlier
  `metric_series_fence_integration_test.ts`, `day_closure_integration_test.ts`, outbox, projection
  debt, day attestation, verification quarantine, and the ordered-apply smoke test (now extended to
  apply `20261003230100` and assert the retirement filter + user/day fence body).
- **Swift worker:** unchanged in this round; previous state 245/6/0 still holds.


---

## Addendum 3 — re-audit repair round 2 (audit-g2-durability P2s 1/3/4/5 + ScoringLane zone fix)

### New migration `supabase/migrations/20261003230200_repair_attest_round2.sql` (in range, additive, one txn)
1. **Outbox dead-letter** (`physiology_archive_outbox`): adds `dead_letter boolean` +
   `dead_letter_reason text` (attempts/last_error already existed). ArchiveLane.swift (now owned):
   claim SQL adds `AND NOT dead_letter`; `releaseOutboxLease` dead-letters at
   `attempts >= 16` (status='failed', reason='archive_upload_exhausted', no backoff) else
   keeps the 30 s backoff; the upload-failure path releases the lease (best-effort) so a
   persistently-failing row converges instead of looping on the 300 s lease.
2. **Closure skip visibility**: new `day_closure_skips(user_id, device_id, reason, seen_at)`
   bounded ledger (PK per user/device/reason) written by the sweep for `invalid_zone` and
   `missing_profile` — the silent drop is now operator-visible while enqueue stays a silent skip.
3. **Closure dead-lettered days**: `day_completeness.closure_reason` added (CHECK:
   dead_lettered/invalid_zone/missing_profile); the sweep now marks dead-lettered v2 days
   `closure_state='closed', closure_reason='dead_lettered'` (fresh OR previously-pending),
   so they are not stuck invisible. Phase B/C use an always-valid `tz` by construction plus a
   `valid` flag — a PG planner quirk eagerly evaluates `at time zone z.tz` in WHERE clauses
   even against rows the join filters out, so invalid zones must never reach it (reproduced and
   fixed in testing).
4. **Verification un-quarantine**: new service-role `noop_unquarantine_manifest_verification(uuid)`
   clears verification_failure_code/failed_at/attempts (object_not_found on missing). Operator
   runbook + the recorded-digest unbounded-retry tradeoff are documented in the migration header.

### ScoringLane.resolveTimezone (quiet-day zone, audit P2 note A)
`ScoringLane.resolveTimezone` now falls back to the owner's `profiles.timezone` (validated
against pg_timezone_names; invalid -> 'UTC') between the work-item lookups and the UTC fallback,
via the new static `resolveTimezoneSQL`. A quiet non-UTC day's claim now carries the profile zone,
so its attestation day bounds are zone-correct instead of UTC.

### Tests (all targeted deno + worker swift)
- New `outbox_dead_letter_integration_test.ts` (4 steps): attempts 1..15 retry+backoff, 16th
  dead-letters, claim excludes, release respects the cap.
- New `day_closure_visibility_integration_test.ts` (3 steps): invalid-zone + missing-profile
  surfaced in the ledger (no enqueue), dead-lettered day marked closed/dead_lettered, sweep quiet.
- New `verification_unquarantine_integration_test.ts` (2 steps): quarantine->un-quarantine clears
  + re-selects; missing object raises object_not_found.
- New `quiet_day_timezone_integration_test.ts` (4 steps): quiet non-UTC day resolves to the
  profile zone (not UTC), invalid profile zone -> UTC, work item wins, profile zone yields
  zone-correct 23 h bounds.
- Worker Swift: +2 tests (resolveTimezoneSQL profile-fallback pin; non-UTC quiet-day attestation
  bounds) in DayAttestationTests.
- Ordered-apply smoke extended with 20261003230200 + artifact assertions.
- Full regression: **13 deno migration/integration tests, 46 steps, 0 failed**;
  `CPATH=/opt/homebrew/opt/libpq/include swift test` → **247 executed, 6 skipped (baseline), 0 failed**.
