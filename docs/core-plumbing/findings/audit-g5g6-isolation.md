# Audit: G5/G6 isolation, counter/capacity surfaces (independent)

Auditor: audit-g5g6-isolation. Date: 2026-10-03. Branch `audit/core-plumbing-20261003`.
Scope: spec §7–8 + T21–T28; the eight 202610032x migrations (RLS/definer/grants),
`supabase/functions/_shared/{serverScores,workers,coach}.ts`, `Strand/Push/{CloudJournal,
CloudTransportCoordinator,CloudUploadSession,CloudPushIdentity}.swift`, `deploy/worker.env.example`,
`tests/capacity_evidence_test.ts`, `capacity-workbook.md` + `capacity.md`.

The auditor did NOT author any of these changes. Every verdict below is code-verified in this
working tree; nothing is confirmed from repair-report prose alone.

## Verdicts per challenge

| # | Challenge | Verdict | Evidence |
| --- | --- | --- | --- |
| 1 | New-migration RLS/definer/grants audit (all 8) | PASS (2 P2 notes below) | see §1 |
| 2 | Placement routes auth / 409-vs-404 enumeration | PASS | see §2 |
| 3 | Diagnostics replacement auth parity | PASS | see §3 |
| 4 | Coach timezone injection / pg_timezone_names | PASS | see §4 |
| 5 | Phone owner guards (repair-ble) | PASS | see §5 |
| 6 | Capacity honesty / fail-open / env names-only | PASS | see §6 |
| 7 | T25 deletion interplay of NEW tables | PARTIAL PASS (P2) | see §7 |
| 8 | Realtime exposure from new routes | PASS | see §8 |

## §1 New migrations — RLS / definer / grants (T21/T22/T31, spec 7.1–7.3)

- `20261003201000_outbox_retry_status.sql`: no definer function, no grants touched; drop/re-add
  of ONE status CHECK admitting `'retry'`. Additive, sane.
- `20261003202000_metric_series_input_revision_fence.sql`: `publish_metric_series_v1`
  (6-arg) is SECURITY DEFINER, `set search_path = public`, `revoke all … public, anon,
  authenticated` + `grant … service_role` only. Device-ownership check
  (`devices.id=p_device and user_id=p_user`) and `pg_advisory_xact_lock` before write. The
  legacy 5-arg form stays service-role-only (unchanged grants). PASS.
  - Challenge question: **can a stale caller fence-block a NEWER pass? — No.** The fence rejects
    only `p_input_revision < latest_rev` (migration :74-79); a newer pass claims the max
    `input_revision` and is never rejected by a stale pass's presence. The fence check and the
    writes are inside one transaction under the per-(user,day) advisory lock, so no TOCTOU
    between check and write for same-user callers. PASS for the asked direction.
  - **P2-1** (per-device fence vs per-user write): the fence reads `scoring_jobs_v2 …
    device_id = p_device` (migration :73-79) but the write target `server_metric_series` is
    keyed per-(user, metric, bucket_start) and the DELETE is device-agnostic
    (:100-103). If a day's selected device changes mid-day (source preference or job-row
    switch), a stale pass for the OLD device (whose own job row still holds the older
    revision) can pass the fence and overwrite the NEW device's newer series. The
    `selected_scoring_device_v2` gate (migration :53-56) rejects non-selected devices at call
    time and mostly closes this; the residual window is device switch A→B→A mid-day. Not
    exercised by `metric_series_fence_integration_test.ts` (same-device only). Minimal repair:
    fence against the user/day max `input_revision` across the day's devices (the write target
    is user-scoped), or key the series by device.
- `20261003203000_projection_debt_dead_letter.sql`: `noop_fail_projection_debt` /
  `noop_claim_projection_debt` recreated with `set search_path=pg_catalog,public`; grants were
  service-role-only before (20260918040000 loop revokes public/anon/authenticated, grants
  service_role) and are untouched by the `create or replace`. Dead-letter at 16 with bounded
  reason; claim predicate adds `not q.dead_letter`. PASS.
- `20261003204000_day_attestation.sql`: `publish_day_attestation_v1` definer, search_path
  pinned, service_role only, device-belongs-to-user guard, pg_timezone_names check, revision
  fence (equal-rev accepted only from the same device = idempotent retry; older always refused;
  newer always advances). PASS.
- `20261003205000_day_closure_scheduling.sql`: `scoring_enqueue_due_day_closure` definer,
  search_path `pg_catalog,public`, service_role only, no user param (scans all active devices),
  AT TIME ZONE boundary math, one transaction (enqueue+marker atomic → crash can never
  double-enqueue), idempotency marker. `publish_day_attestation_v1` recreated with identical
  fence + `closure_state` advance. PASS.
- `20261003205900_verification_quarantine.sql`: `noop_quarantine_manifest_verification`
  definer, search_path pinned, service_role only, bounded code CHECK, idempotent
  `verification_failed_at`, capped attempts. No user param but service-role-only (trusted
  worker), so acceptable. PASS.
- `20261003210000_placement_intervals.sql`: table RLS enabled, `revoke all … public, anon`,
  `grant select … authenticated` + own-row select policy, `grant all … service_role`.
  `set_placement_interval` definer, search_path pinned, `auth.uid() is distinct from p_owner →
  cross_user_caller` guard, device-ownership check, grants `authenticated, service_role`
  (intended: the phone calls through the edge with the service key; direct authenticated calls
  are guarded by auth.uid()). PASS.
  - **P2-2** (non-overlap invariant not concurrency-safe): the function has NO advisory lock.
    Two concurrent declarations for one owner (e.g. wrist@T1 and bicep@T2, T2>T1, fresh state)
    each run step-1/step-3 under READ COMMITTED and can both compute `next_start = NULL`,
    leaving two overlapping OPEN intervals. The SQL test (`placement_intervals_sql_test.ts`
    "future-dated interval is capped" + the no-overlap assertion) is single-session and cannot
    see this. The route is single-owner (no cross-user risk) but the G4 "intervals stay
    non-overlapping" contract is per-concurrency, not absolute. Minimal repair: take
    `pg_advisory_xact_lock(hashtextextended('placement:'||p_owner||':'||coalesce(p_device,'user'),0))`
    at the top of `set_placement_interval`.

## §2 Placement routes auth (spec 7.1, T21/T22)

- Owner is resolved ONLY from installation/JWT identity in `handleScoresRequest`
  (serverScores.ts:150-168); the POST passes `p_owner: user.id` (serverScores.ts:251) — a
  client-supplied owner is never accepted.
- Device-scoped POST resolves through `findNoopDevice`, which filters `user_id=eq.${userId}`
  (devices.ts:41-57). A foreign owner's device and a nonexistent device BOTH yield
  `null → 409 device_registration_pending` (serverScores.ts:246-248) — uniform, so no
  enumerate-another-owner's-device oracle (409 vs 404 leak absent). Verified by
  placement_route_test.ts step 5 (cross-owner device → 409, same code as not-found).
- GET /placement is owner-scoped: `owner=eq.${user.id}` filter (serverScores.ts:268) + RLS
  `placement_select_own` backstop; returns ONLY owner rows, and no device is ever queried by a
  client-supplied id. The route queries through the service key (rest.ts), so the owner filter
  is the sole guard there — correct because `user.id` is server-resolved.
- POST cannot auto-register a device: it calls `findNoopDevice`, NOT the resolver
  (serverScores.ts:245-248) — a device is never created by a placement call.

## §3 Diagnostics replacement parity (T30, spec 9)

- `20261003220000` replaces `server_pipeline_diagnostics` with the SAME signature and the SAME
  auth surface: `revoke all … public, anon, authenticated` + `grant … service_role` only
  (:249-252), identical to 20260921101000. `auth.role() is distinct from 'service_role'` +
  device-ownership + live-installation guard are unchanged (new migration :32-39).
- No-owner-identity-in-payload preserved: `correlation_id` stays a SHA-256 of the scope tuple;
  new fields (day, zone, stream summaries, queue ages, blocker codes, worker instance ids) carry
  no raw owner/source UUID. Route sets `cache-control: no-store`.
- Honest not_measured surface verified by pipeline_diagnostics_test.ts (OTHER's enrolled-empty
  response: not_observed / not_measured, OWNER data never leaks).

## §4 Coach timezone (T06, spec G1/C2)

- The DB trigger `scoring_record_timezone` is the exact authority: `if not exists(select 1 from
  pg_timezone_names where name=new.timezone) then raise exception 'invalid IANA timezone'`
  (20260918100000). The coach.ts regex (`^[A-Za-z0-9_+/-]{1,64}$`) is only a shape pre-filter —
  weaker, but storage is blocked by the trigger, so no arbitrary string can reach `AT TIME ZONE`.
  The day-closure sweep additionally validates via `join pg_timezone_names` (20261003205000), so
  a garbage zone simply never gets enqueued.
- 400 mapping: the catch maps any error whose message contains "timezone" to `invalid_profile`
  (coach.ts:367-373) — the client sees only the bounded code, no SQL text leaks. Zone values are
  parameterized through PostgREST (no SQL injection). coach_timezone_test.ts exercises a real
  invalid zone rejection through the trigger.

## §5 Phone owner guards (repair-ble, T23 latent / T22)

- Sealer: `pendingGroups`/`pendingEntries`/`registerSeal` mark/`sealedBatches`/`rescheduleFailed`/
  `stats`/`countBatches` all filter by `owner_id` (CloudJournal.swift:624-686, 770-780, 902-936,
  1017-1050); actor facades pass `configuration.ownerId`, and `sealCandidates` stamps
  `config.ownerId` (CloudJournal.swift:1273-1296).
- Send paths: `uploadForeground(…expectedOwnerId:)` refuses when current `identity.ownerId !=
  expectedOwnerId` (CloudUploadSession.swift:154-160); `enqueueBackground` returns -1 on the
  same mismatch (:192-196). The coordinator checks `batch.ownerId == identity.ownerId` before
  either lane and quarantines mismatches with `markFailed(… blocked: true)` (CloudTransportCoordinator.swift:361-376, 386-395). No send path resolves the token from the current
  pointer without first proving batch owner == current owner. `rebuildBatch` binds the receipt to
  `batch.ownerId` (the acquisition owner), not the current identity (:525-546).
- Quarantine: `markFailed` never touches `owner_id`; a blocked batch is retained under its
  original owner, and `resealBlockedBatches` (start) iterates only the CONFIGURED owner's blocked
  rows, so it cannot be re-sealed under a different owner (CloudJournal.swift:833-856,
  coordinator start).
- HR ledger: `CloudHeartRateLedger` is a dedup hint, seeded from the durable journal tail on
  activate (`activateLedgerFromJournalTail`), reset on stop. Re-enable re-seeds the same journal
  seconds, so it neither double-sends journaled seconds nor drops them; seconds claimed but not
  yet committed at a stop are re-offered once — identical to a process death, deduped server-side
  by content-derived batch ids. Verified by the 3 new tests
  (`LedgerSeedMarksSecondsHeldAndResetForgetsThem`, `CrossOwnerBatchIsQuarantined…`,
  `UploadSessionRefusesToSendAnotherOwnersBatch`).
- CloudPushTests (macOS, run by this auditor): 46 tests, 0 failures.

## §6 Capacity honesty (T26, spec 7.4)

- capacity.md: every number is labeled measured-when (droplet baseline) vs NOT MEASURED; the
  "Current supported workload" paragraph explicitly disclaims being a supported-user claim.
- capacity-workbook.md: header is PLAN ONLY — NOT VERIFIED; declares tiers 10/50/100 as workload
  scenarios, budgets, pass/fail rule; §7 lists the exact NOT VERIFIED items; §8 pass/fail rule
  forbids relabeling.
- `capacity_evidence_test.ts` fail-open is honest: the two infra-file tests are `ignore: true`
  with a console SKIP naming the missing files; the always-running unit tests still pass. Run by
  this auditor: 7 passed / 2 ignored (both self-skipped with reasons), no fabricated pass.
- worker.env.example additions are commented knobs, names only — no secrets.

## §7 T25 deletion interplay of the NEW tables (PARTIAL PASS, P2-3)

- Orphan leak after completed deletion: NONE. Every new/modified table's owner FK is
  `references auth.users(id) on delete cascade` — placement_intervals.owner, day_completeness.user_id,
  noop_projection_debt.user_id, physiology_archive_outbox.user_id, server_metric_series.user_id,
  server_physiology_results.user_id, scoring_jobs_v2.user_id, scoring_snapshots_v2.user_id,
  physiology_work_items/scoring_work_items/user_timezone_history/noop_signal_windows/
  noop_upload_receipts all cascade; the account-deletion worker deletes devices/profiles rows and
  finally `adminDeleteAuthUser`, which fires the cascades. `placement_intervals.device_id` is
  `on delete set null` (rows become user-level, still owner-scoped, then cascade at auth delete).
- **P2-3** (resurrection window during deletion, T25): `begin_noop_account_deletion` freezes only
  installations/ingest tokens; it does NOT deactivate devices (20260921113000). The NEW
  `scoring_enqueue_due_day_closure` (20261003205000) selects `devices d join profiles p …
  where d.is_active` with NO `noop_account_retirements` filter, and neither `enqueue_scoring_v2`
  nor `claim_scoring_v2` checks retirements (20260918010000). During the ~16+ minute deletion
  window (the worker waits for signed-URL expiry before deleting rows/auth), the closure sweep
  can enqueue and the worker can publish fresh snapshots/series for a frozen owner. The data is
  cascade-deleted when the deletion completes, and reads are already blocked by retirement checks
  in every read RPC, so it is a bounded, invisible, self-cleaning window — but it violates the
  letter of "prevent old queued jobs from resurrecting removed data". Minimal repair: add
  `and not exists(select 1 from public.noop_account_retirements r where r.user_id = z.user_id)`
  to the closure sweep's selection (and, for completeness, a retirement filter to
  `claim_scoring_v2`).
- NOT VERIFIED: there is NO automated account-deletion test covering the new tables (the deno
  suite has only `s3_test.ts` deleteObject unit tests; `DELETION_TABLES` in workers.ts omits the
  new tables by design — they rely on FK cascade). The cascade coverage above is from reading the
  migration SQL, not from a running test.

## §8 Realtime exposure (T22 realtime row)

- None: no `realtime` schema reference in any of the eight migrations or the changed edge/Swift
  files (grep over the changed surface). The placement and diagnostics routes are plain
  PostgREST RPC/select with no publication; diagnostics is service-role-only.

## Tests run by this auditor (all targeted, per instructions)

- deno (EDGE_TEST_ARTIFACTS=/tmp/net, `--allow-all`): capacity_evidence_test (7 pass / 2
  self-skip), reconcile_quarantine_test (2 pass), placement_route_test (1 pass), placement_intervals_sql_test (9 steps pass), coach_timezone_test (1 pass), pipeline_diagnostics_test (1 pass), day_closure_integration_test (5 steps pass), metric_series_fence_integration_test (5 steps pass), verification_quarantine_integration_test (4 steps pass), day_attestation_integration_test (5 steps pass), projection_debt_dead_letter_integration_test (4 steps pass), outbox_retry_integration_test (3 steps pass). All green.
- macOS: `xcodebuild -only-testing:StrandTests/CloudPushTests` → 46 tests, 0 failures.
- Full suites NOT re-run (root already ran them authoritatively: macOS 2473/2/3, deno 250/9/14, worker 245/6/0).

## NOT VERIFIED (blocked checks)

1. Device-switch mid-day series overwrite under the per-device fence (P2-1) — no fixture/test
   exists; verified only by reading the SQL paths.
2. Concurrent `set_placement_interval` overlap (P2-2) — no concurrency test; single-session SQL
   test only.
3. Automated account-deletion coverage of the NEW tables (P2-3) — no deletion test in the deno
   suite; FK cascade verified by reading SQL only.
4. Deployed migration order / realtime schema presence / B2 behavior — deployment-phase checks
   (root's rollout verification), not re-verified here.


## Re-audit round (2026-10-03, after all fix rounds)

Re-verified against the CURRENT working tree (uncommitted). Each finding below is checked
against its fix migration + the targeted test that pins it, plus a re-check that the fix did
not introduce a new issue in the G5/G6 audit scope.

### P2-1 — metric-series fence per-device vs per-user target: PASS (one new residual risk)

- Fix: `20261003230100_repair_attest_fence_scope_and_retirement.sql` recreates
  `publish_metric_series_v1` with the fence now reading
  `select max(input_revision) from scoring_jobs_v2 where user_id=p_user and day=p_day`
  (user/day max across ALL devices; `selected_scoring_device_v2` gate unchanged). The
  device-agnostic write target (server_metric_series keyed (user, metric, bucket_start)) is
  now fenced on the true freshness of that target.
- Pinned by `metric_series_fence_user_scope_test.ts` (4 steps): stale A-pass at 3 rejected when
  user/day max is 5 (the exact A->B->A scenario I raised); newest pass via ANY device applies;
  stale A-pass still rejected after B's series landed; not_selected gate unchanged. All 4 steps
  PASS (run by this auditor). Original `metric_series_fence_integration_test.ts` (5 steps) and
  `SeriesFenceTests` (Swift) still pass — no regression.
- NEW RESIDUAL (low severity, documented here): the user/day max can now BLOCK the selected
  device's legitimate pass when a NON-selected device's job row for the same day holds a higher
  input_revision (e.g. a second strap uploaded more during the day). The selected device's
  series is then suppressed until its own revision catches up, while the day's snapshot (fenced
  per job row) is still published — a snapshot-present/series-stale (or missing) divergence.
  This is the deliberate trade-off of "latest input across the day wins" for the
  device-agnostic target; the alternative (per-device fence) was the overwrite bug. Self-corrects
  on the next selected-device upload. If the series must always reflect the SELECTED device,
  fence against the selected device's revision (or device-key the series) instead. Not tested
  either way (the test pins the intended rejection, not the starvation).

### P2-2 — set_placement_interval no advisory lock: PASS

- Fix: `20261003231000_placement_concurrency_lock.sql` adds
  `pg_advisory_xact_lock(hashtextextended('placement:'||p_owner||':'||coalesce(p_device::text,'user'),0))`
  taken before the interval computation/writes. `20261003231500_placement_same_start_effective_end.sql`
  recreates the same function (keeps the lock) with the F6 same-start effective_end fix.
- Pinned by `placement_concurrent_intervals_test.ts` (5 steps): lock present + guards preserved;
  two concurrent declarations -> non-overlapping, exactly one open, earlier closed at later
  start; 5-way concurrent burst -> contiguous [T1,T2),[T2,T3),…,one open tail, zero overlap;
  held-lock serialization proof (second declaration blocks ~1 s); user-level declarations
  serialize on their own lock. All 5 steps PASS (run by this auditor).
- Scope check: user-level and device-scoped declarations take DIFFERENT lock keys but operate on
  disjoint row sets (every statement filters by the same scope predicate), so no cross-scope
  overlap is possible. Original `placement_intervals_sql_test.ts` (9 steps),
  `placement_route_test.ts`, and `placement_effective_end_test.ts` (4 steps) all still pass.
  Grant/guard surface unchanged (cross_user_caller, device_owner_mismatch, SECURITY DEFINER,
  authenticated+service_role).

### P2-3 — deletion-freeze resurrection in the closure sweep: PASS (documented residual accepted)

- Fix: same `20261003230100` adds `and not exists (select 1 from public.noop_account_retirements
  ret where ret.user_id = z.user_id)` to the closure sweep; the round-2 rewrite
  (`20261003230200`) RETAINS the retirement filter in all three phases (A skip-ledger, B
  dead-lettered-day settle, C pending enqueue).
- Pinned by `day_closure_retirement_test.ts` (3 steps): frozen owner's job revision NOT bumped,
  active owner enqueued, frozen stays un-enqueued on repeat sweeps. All 3 steps PASS (run by
  this auditor). Original `day_closure_integration_test.ts` (5 steps) still passes.
- Residual assessment (asked by root): the claim-path residual — `enqueue_scoring_v2` /
  `claim_scoring_v2` (20260918010000) do not check retirements, so jobs ALREADY queued before a
  freeze can still be claimed/published during the ~16 min deletion window. ACCEPTED as a
  bounded window: (a) the only NEW-enqueue sources during a freeze are now closed (closure sweep
  fixed; uploads already blocked by `admit_noop_request`/installation revocation retirement
  checks), so the residual is exactly the finite pre-existing queue; (b) every read RPC blocks
  retired owners (42501), so the data is never readable; (c) rows are cascade-deleted when
  deletion completes; (d) the behaviour predates this repair round. Hardening (a retirement
  filter in `claim_scoring_v2`) is a worthwhile follow-up but not a blocker for this fix.

### Round-2 changes re-checked in this audit's scope

- Outbox dead-letter (`20261003230200` + ArchiveLane.swift): claim adds `AND NOT dead_letter`;
  `releaseOutboxLease` dead-letters at attempts>=16 with bounded reason, terminal status
  'failed' (admitted by the CHECK), no further backoff. Pinned by `outbox_dead_letter_integration_test.ts`
  (4 steps) — all PASS. Attempts are incremented at claim time, so the cap counts real attempts.
- Closure visibility: `day_closure_skips` table (service_role-only RLS; no anon/authenticated
  grants), `day_completeness.closure_reason` CHECK bounded; sweep Phase A surfaces
  invalid_zone/missing_profile, Phase B settles dead-lettered days to closed/dead_lettered.
  Pinned by `day_closure_visibility_integration_test.ts` (3 steps) — PASS. Both phases keep the
  retirement filter. day_closure_skips.user_id -> auth.users ON DELETE CASCADE (deletion-clean).
- `noop_unquarantine_manifest_verification`: service-role only, definer, search_path pinned,
  clears quarantine, raises object_not_found. Pinned by `verification_unquarantine_integration_test.ts`
  (2 steps) — PASS. No widening of the verification surface.
- Quiet-day profile zone: `ScoringLane.resolveTimezoneSQL` now falls back to profiles.timezone
  (validated against pg_timezone_names) before 'UTC'; invalid profile zones fall back to UTC
  (snapshot contract). Pinned by `quiet_day_timezone_integration_test.ts` (4 steps) and
  DayAttestationTests.resolveTimezoneSQL (Swift) — PASS.

### Tests run this round (targeted only, all green)

- deno: metric_series_fence_user_scope (4), day_closure_retirement (3), placement_concurrent_intervals (5),
  placement_effective_end (4), outbox_dead_letter (4), day_closure_visibility (3),
  verification_unquarantine (2), quiet_day_timezone (4) — 8 files / 29 steps, 0 failed.
- deno regression re-runs of my original pins: placement_intervals_sql (9), placement_route (1),
  day_closure_integration (5), metric_series_fence_integration (5), verification_quarantine (4),
  outbox_retry (3) — 6 files / 27 steps, 0 failed (no regression from the recreated functions).
- Swift worker: DayClosureTests + SeriesFenceTests + DayAttestationTests + DayScoringAdapterTests +
  VerificationLaneTests = 67 tests, 0 failures. (Note: first swift run failed at LINK time — libpq
  symbols unresolved without PKG_CONFIG_PATH/LIBRARY_PATH for homebrew libpq; with
  `PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/libpq/lib/pkgconfig:...` the suite
  built and passed. Environment, not code.)
- Full suites not re-run (root's authoritative runs stand).

### Remaining risks after this round (unchanged from round 1)

1. P2-1 residual: selected-device series can be suppressed while any non-selected device's day
   revision is higher (derived series only; snapshot unaffected; self-corrects). Not tested.
2. No automated account-deletion test covers the new tables (FK-cascade coverage is from SQL
   reading; day_closure_skips and day_completeness.closure_reason additions are cascade-clean by
   FK). Still NOT VERIFIED as an automated gate.
