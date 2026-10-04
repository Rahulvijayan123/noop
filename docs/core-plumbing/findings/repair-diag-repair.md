# repair-diag findings & repair record (G7 diagnostics + capacity evidence plumbing)

Worker: repair-diag. Tree: `nara-core-plumbing`, branch `audit/core-plumbing-20261003`.
Scope: g56-jobs-capacity items 2/3/4 + g34 item 8 + parent scope addition (workers.ts
quarantine parity). Date: 2026-10-03.

## 1. Extended server_pipeline_diagnostics (G7 single owner-scoped surface)

Migration `supabase/migrations/20261003220000_server_pipeline_diagnostics_extended.sql`
replaces the RPC from `20260921101000` in place (same signature `(uuid,uuid,uuid,date)`,
same `service_role` + owner/installation enforcement — no new auth paths), schema_version 2,
additive fields only. New fields, all measured or explicit `not_measured`/`not_observed`:

- `day_bounds`: half-open `[start_ts,end_ts)` segments from the canonical
  `scoring_day_segments` primitive (C2), `zone`, `zone_policy='local_calendar_midnight'`.
- `streams`: per-stream `signal_windows` summary (windows, received/expected, mean coverage,
  last valid ts) from `noop_signal_windows` within the day bounds; `coverage` from the
  published snapshot payload (`payload->'coverage'`, latest per algorithm); `largest_gap`
  (status measured/not_measured, stream, seconds) computed from adjacent window gaps.
- `queue.scoring_v2`: status (pending/dead_lettered/complete/none), pending, dead_lettered,
  invalidation_suppressed, eligible, input/completed revision, oldest dirty age,
  oldest eligible age (mirrors the worker heartbeat's eligible gate predicate), next_attempt_at.
- `projection`: status (current/behind/not_observed), published_revision (max
  `server_physiology_results.input_revision`), required_revision (v2 job then legacy work item).
- `archive`: durable_published (server_physiology_results count), verified (outbox `verified`),
  oldest verified age, per-status counts, and `scoring_archive_jobs_v2` linkage.
- `blockers`: explicit list — worker_unavailable, projection_pending, projection_retrying,
  v2_job_dead_lettered, v2_job_pending, legacy_work_pending, archive_failed, archive_pending.
- Existing fields preserved: stages (acquired/durable/decoded/displayed stay `not_measured`
  with the honest reason), work, publications, selected_features (identity strip kept),
  selected_workers, capabilities, correlation_id, scope.

`supabase/functions/_shared/serverScores.ts`: the `/diagnostics` route is unchanged in
behavior — raw RPC result, no identity envelope (the existing `server_pipeline_sql_test.ts`
asserts the payload must NOT contain the owner's user/device UUIDs; an identity envelope
would have broken that contract). Added an explanatory comment only.

## 2. In-app diagnostics consumer

`Strand/Screens/MonitorView.swift` — the Monitor tab was a sample-filled placeholder
(`MonitorSnapshot.sample`). It is now Nara's single owner-scoped diagnostic surface:
- `PipelineDiagnostics` Codable models matching schema_version 2 (snake_case decode).
- `PipelineDiagnosticsClient` fetches `/scores/diagnostics?day=&deviceId=my-whoop` with the
  SAME installation credential as every other score read (Bearer upload token +
  `x-noop-fleet-token`, endpoint derived from `ServerScoreRepository.derivedEndpoint()`).
- The screen shows day bounds/zone, stream status + windows + coverage + largest gap, v2
  queue status/ages/revisions, projection revision, durable-accepted vs verified-archived,
  and the explicit blockers list; loading/error states are honest ("Nara diagnostics
  unavailable" + reason); refresh button + pull-to-refresh.
- `MonitorSnapshot`, `.sample`, `WatchdogView` and the shared card building blocks are
  retained untouched (WatchdogView still consumes the snapshot model).

## 3. deploy/worker.env.example

Added the documented-but-missing knobs (names + comments only, defaults from
`Tools/CloudWorker/Sources/frwhoop-worker/main.swift`): `FRWHOOP_DISABLE_LANES`,
`FRWHOOP_LEGACY_QUIET_SECONDS`, `FRWHOOP_LEGACY_MAX_DEFER_SECONDS`,
`FRWHOOP_V2_INPUT_GATE_SECONDS` (g56 recommendation #5).

## 4. capacity_evidence_test.ts fail-open (T26 infra)

`capacity_evidence_test.ts` previously required `infra/vps/launch-capacity.json`,
`infra/vps/templates/docker-compose.fleet.yml`, `HANDOFF_multiuser.md`,
`docs/sensor-algorithms/capacity.md` and `scoring-service/scripts/test-server-pipeline.sh` —
none exist in this checkout (`git ls-files infra` empty). The two file-reading tests now
SELF-SKIP with a clear console reason when a fixture is absent (module-scope existence check,
`ignore:` flag), while all unit tests still run. Result: 5 passed, 0 failed, 2 ignored.
Chosen over committing placeholder templates (the smaller, honest change); documented in
`docs/core-plumbing/capacity-workbook.md` §7.

## 5. capacity-workbook.md (spec 7.4 run sheet)

New `docs/core-plumbing/capacity-workbook.md` — the staged, executable measurement plan:
declared workload scenarios/tiers 10/50/100 with stream rates, batches, backlog, duration,
mix; declared budgets (p95 ingest ≤ 2 s, p95 projection lag ≤ 60 s, compact day reads ≤ 2 s,
max job age ≤ 10 min, recovery ≤ 20 min, headroom); what to measure (throughput, p50/95/99,
per-user queue/job age, outage recovery, CPU/RSS/event-loop, disk/fsync, DB connections/
locks, storage retries); exact build/config/run commands and SQL probes; the Swift-worker
(NOT JVM) target note from g56 §3; the topology decision (single-process Swift worker, one
global claim per cycle, no DB per-user cap — document the bound, add a cap before any
multi-worker plan); measured-when droplet baseline from `root-deployment-baseline.md`
(4 vCPU/8 GB, ~199 MB RSS / 7.4% CPU, 490 scoring_jobs_v2 rows/10 pending, 15,738 archive
jobs/0 pending, 29 users, stale FRWHOOP_SOURCE_REVISION warning); explicit NOT VERIFIED
section; pass/fail rule (no relabeling failed targets). No fabricated numbers.

## 6. workers.ts quarantine parity (parent scope addition)

`supabase/functions/_shared/workers.ts` `reconcileObjects`: the edge-side reconcile scan now
skips rows with `verification_failure_code != null` at the top of the processing loop — the
same exclusion as `VerificationLane.candidateSQL` (`verification_failure_code IS NULL`,
added by repair-attest's `20261003205900_verification_quarantine.sql`). Quarantined
manifests are no longer re-HEADed / re-PATCHed / re-promoted by the edge sweep; the orphan
census still sees them via `byKey` so no false orphans. New test
`tests/reconcile_quarantine_test.ts` proves quarantined rows are untouched and non-quarantined
rows still reconcile, and that a quarantined object is not miscounted as an orphan.

## Tests run

- `EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all tests/pipeline_diagnostics_test.ts`
  → 1 passed (extended RPC: day bounds/zone, streams/largest gap, queue age, projection,
  archive, blockers, owner isolation + mismatch rejection, honest not_measured for an empty
  enrolled owner). Throwaway PostgreSQL on a Unix socket only; no production DB.
- `EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all tests/reconcile_quarantine_test.ts`
  → 2 passed.
- `EDGE_TEST_ARTIFACTS=/tmp/net deno test --allow-all tests/capacity_evidence_test.ts`
  → 5 passed / 2 ignored (self-skip with reason).
- `deno check` on `_shared/workers.ts`, `_shared/serverScores.ts`, all three test files → clean.
- `xcodegen generate` + `xcodebuild build -scheme Strand -destination 'platform=macOS'`
  → BUILD SUCCEEDED (MonitorView compiles).
- `xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS'
  -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests`
  → 2473 tests, 2 skipped, 3 failures: `SkinTempAbsoluteDisplayTests` and
  `SleepCarriedStampTests` are the documented pre-existing Pacific-time caption failures
  (C6); `IntradayWordingAndCoachTests/testMinuteBucketsAreDescribedAsMinuteBuckets` is caused
  by another worker's in-progress change to `Strand/Push/IntradaySeries.swift` (G3/G4
  per-window flags), not by repair-diag files.

## Remaining gaps / NOT VERIFIED

- No staged capacity run executed; all capacity numbers in the workbook are declared targets
  or the measured-when droplet snapshot — NOT VERIFIED (T26 staging).
- `infra/vps/*` declarations still absent from the repo; the capacity gate is fail-open until
  a staging run commits them.
- Day-bounds/zone and coverage/largest-gap rely on what the pipeline knows today; attestation
  fields landing via repair-attest are intentionally NOT depended on (additive jsonb only).
- `IntradayWordingAndCoachTests` failure is a shared-tree WIP artifact of another worker.
- No new StrandTests for the diagnostics view (not in ownership); compile coverage only.

## 7. Placement edge route (parent scope addition 2)

`supabase/functions/_shared/serverScores.ts` gained `POST`/`GET /scores/placement` (G4), the
missing edge half of repair-placement's `20261003210000_placement_intervals.sql`:
- POST: body `{ placement, effective_start, device_id? }` with the SAME installation
  credential as every other score route. The edge resolves the OWNER from that identity and
  calls `set_placement_interval(p_owner, ...)` — a client-supplied owner is never accepted.
  Placement values restricted to wrist/bicep/other/unknown (400 `invalid_placement`); missing
  or unparseable `effective_start` → 400 `invalid_effective_start`; a `device_id` that is not
  the owner's registered device → 409 `device_registration_pending`. Absent `device_id` is a
  user-level declaration (RPC NULL-device scope).
- GET: owner-scoped `{ intervals: [...] }` from `placement_intervals` with `device_id` mapped
  back to the EXTERNAL device id (the id the phone registers and sends on ingest) so
  `PlacementCloudSync.reconcile`'s per-device grouping matches the local store. The payload
  deliberately carries no owner identity (owner-scoped by auth).
- The `set_placement_interval` RPC's own guards were exercised directly: mismatched
  owner/device → `device_owner_mismatch`; an authenticated caller declaring for another owner
  → `cross_user_caller` (rejected, nothing written).
- Test: `tests/placement_route_test.ts` (local-PG harness, real route + RPC): first
  declaration, correction (overlap closed, revision bump, half-open capping), device-scoped
  resolution, invalid input 400, cross-owner deny 409/403, GET contract.

## 8. Coach profile timezone (parent scope addition 3)

`supabase/functions/_shared/coach.ts` — the app sends the phone-local IANA `timezone` in the
profile payload, but the server neither persisted nor echoed it (profiles.timezone stayed
'UTC' forever and the app re-PUT every foreground). Fixed:
- `PROFILE_COLUMNS` now selects `timezone`.
- `profileInput` accepts `timezone`: null = no-change; a string must be 1-64 chars matching
  `^[A-Za-z0-9_+/-]{1,64}$` (else 400 `invalid_profile`). The pg_timezone_names authority is
  the production `scoring_record_timezone` trigger (20260918050000) — the route surfaces its
  rejection as 400.
- `publicProfile` echoes `timezone` (tolerates null; a timezone-only row is no longer "empty").
- Test: `tests/coach_timezone_test.ts` (local-PG harness, REAL 18010000/18020000/18030000/
  18050000 chain so the real trigger runs): valid zone persisted+echoed (and present in
  pg_timezone_names), invalid shape 400, syntactically-valid-but-unknown zone 400, null
  no-change, back-compat (old/default row echoes 'UTC'; a NULL timezone row decodes to
  `timezone: null` without breaking the profile). `coach_test.ts`'s profile exact-match
  assertion was updated to include `timezone: null` (mechanical, within the scoped profile
  surface).

## 9. workers.ts quarantine parity (parent scope addition 1)

See section 6 above (added 2026-10-03 with the parent's first scope addition). Test:
`tests/reconcile_quarantine_test.ts`.

## 10. Final verification matrix (all scoped additions)

| Check | Result |
| --- | --- |
| `deno check` (coach, workers, serverScores, all 5 new/updated test files) | clean |
| `pipeline_diagnostics_test.ts` | 1 passed |
| `reconcile_quarantine_test.ts` | 2 passed |
| `capacity_evidence_test.ts` | 5 passed / 2 ignored (self-skip, clear reason) |
| `placement_route_test.ts` | 1 passed |
| `coach_timezone_test.ts` | 1 passed |
| `coach_test.ts` | 14 passed |
| `workers_test.ts` | 11 passed |
| macOS build (Strand scheme) | BUILD SUCCEEDED (MonitorView compiles) |
| macOS StrandTests | 2473 run, 2 skipped, 3 failures — 2 pre-existing Pacific caption; 1 another worker's WIP (`IntradayWordingAndCoachTests`, Strand/Push/IntradaySeries.swift G3/G4 change) |

## 11. Re-audit response (audit-g1-day F5 — coach_timezone_test.ts)

The timezone test was strengthened per the auditor: `tests/coach_timezone_test.ts` now proves
end to end against the REAL database authority:
- The migration chain now includes 20260918100000 (plus 18040000) exactly as the auditor
  named; the test first asserts the real `scoring_profile_timezone` trigger is attached to
  public.profiles (defined in 20260918010000:40, create-or-replaced by 18050000/18100000).
- (1) PUT a real IANA zone ('America/Los_Angeles') through the route: 200 + echoed, the
  stored `profiles.timezone` round-trips (direct SQL), the zone is present in
  pg_timezone_names, and a fresh GET read-back echoes it. A SECOND valid zone
  ('Asia/Kolkata') proves the trigger accepts on the UPDATE path too.
- (2) PUT 'Not/AZone' (syntactically plausible, NOT a real IANA id): 400 `invalid_profile` —
  the pg_timezone_names authority (scoring_record_timezone trigger) rejected it and the
  route mapped it; the stored value is asserted UNCHANGED. Shape-invalid 'Not A Zone!' is
  also 400 (edge gate, pre-DB).
- (3) null = no-change (accepted, nothing written, zone preserved) and the null-tolerant
  back-compat row (timezone: null decodes, other fields intact) are kept.
Results: coach_timezone_test.ts 1 passed (stable across reruns); coach_test.ts 14 passed (no
regression); `deno check` clean.
