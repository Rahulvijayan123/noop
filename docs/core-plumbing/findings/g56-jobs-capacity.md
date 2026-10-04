# Workstream 6 — Fair/bounded jobs, capacity measurement and diagnostics (g56-jobs-capacity)

Audit date: 2026-10-03. Worktree: `nara-core-plumbing` @ `56809066` (integration/phone-20261003),
branch `audit/core-plumbing-20261003`. Baseline: commit 4c85df9a (spec-16 doc commit) on top of 56809066.
All evidence below is CODE-VERIFIED in this tree unless marked NOT VERIFIED / deployment / device.

Scope: G5 capacity/fairness (spec 7.3–7.4), G6 counter/source integrity (spec 8), G7 diagnostics
(spec 9), tests T24, T26, T27, T28, T31.

Environment notes:
- Worker unit suite ran GREEN: `swift test` in Tools/CloudWorker = 214 tests, 0 failures, 6 skipped
  (5 ActivityAttachIsolationTests need a live DB; 1 PushBatch on-disk corpus). Needed
  `CPATH=/opt/homebrew/opt/libpq/include` on this Mac.
- StrandAnalytics `StepsCounterTests` ran GREEN: 16/16.
- Supabase/Deno staged tests were NOT run (require Docker postgres + worker binaries + missing infra
  files, see T26).

---

## 1. Lane/queue fairness, leases/fencing, backoff/dead-letter (T31)

### v2 scoring lane (the lane the app reads)
- Claim: `public.claim_scoring_v2` → `internal.claim_scoring_v2`
  (`supabase/migrations/20261002123000_claim_scoring_cooldown_45s.sql:10-41`), which is the newest of
  three replace-migrations (20260930210000, 20260930231500, 20261002123000). Semantics:
  - single global claim per call: `for update of q skip locked limit 1` (line 35), lease
    `lease_token=gen_random_uuid(), lease_until=clock_timestamp()+p_lease_seconds` (lines 38-40);
  - fairness: `order by coalesce(max(s.last_claimed_at) over owner, '-infinity')` — oldest-served
    users first (line 29); days waiting > 1 h take precedence (lines 30-33); `day desc` (newest day
    first); per-job cooldown `last_claimed_at < now - 45 s` (line 25); only `q.day <= o.today`
    (line 24, unbegun days never claimable).
  - base definition (lease cap 1..3600 s, default 300): `20260918010000_production_scoring_durability.sql:121-149`.
- Publish fence: `publish_scoring_snapshot_v2` returns NULL unless the caller still owns a LIVE lease
  with the SAME input_revision: `if not found or j.lease_until<=clock_timestamp() or j.input_revision<>p_revision then return null`
  (`20260918010000_production_scoring_durability.sql:236-237`), plus algorithm-enabled and
  invalidation checks (238-240). The worker PARSES the result and never treats NULL as success
  (`Tools/CloudWorker/Sources/frwhoop-worker/ScoringLane.swift:487-491`), rolling back and releasing
  the lease through the `renew_scoring_v2` + `fail_scoring_v2` pair (`ScoringLane.swift:616-631`).
  => An expired/fenced claimant CANNOT publish v2. **T31 PASS (code-verified).**
- Backoff/dead-letter (v2): `fail_scoring_v2` (`20260918010000:159-169`) — failure counted only when
  `input_revision` unchanged; `dead_letter` at 8 consecutive; `not_before = now + least(3600, 5*2^n)`.
  A revision move resets counters (clean release). Renewal: `renew_scoring_v2` (lines 150-157).

### Legacy fleet lane (served before v2)
- `claim_scoring_legacy`/`scoring_legacy_claim_one` (`20260918120000_fenced_baseline_transport.sql:83-103`):
  oldest-first (`order by next_attempt_at, dirty_at, user_id, device_id, day`, line 96), lease 300 s
  default, `for update skip locked`. Dead-letter is the `status='exhausted'` state at >= 8
  consecutive failures; backoff `least(3600, 5*2^(n-1))` (`scoring_legacy_finish_work`,
  `20260918120000:120-152`; exhausted excluded by the claim predicate, line 93).
- Fence: `scoring_legacy_begin_publication` raises `40001` on any lease/revision/run-id mismatch or
  expired lease (`20260918120000:68-81`); `engine_publish_legacy_fenced` calls it
  (`20260918120000:190`). The worker classifies 40001 as `.stale` (`PostgresClient.swift:508`) and
  treats it as superseded without recording a failure (`ScoringLane.swift:346-355`).
  => Legacy claimant cannot publish after lease loss. **T31 PASS.**

### Archive lane
- v2 archive: `claim_scoring_archive_v2` / `complete_scoring_archive_v2`
  (`20260918010000:310-332,347-367`) — completion returns false or raises on stale lease/token,
  worker counts `notCompleted`/`leaseLost` and never counts a false as success
  (`ArchiveLane.swift:109-123`); dead-letter at 12 with the same capped backoff (lines 336-343);
  explicit operator repair `retry_scoring_archive_v2` (lines 379-388).
- Outbox (legacy): fenced completion `WHERE lease_token=$2 AND lease_expires_at > now()`, rolled back
  with the manifest insert when lost (`ArchiveLane.swift:228-246`).

### Activity lane (off by default)
- Fenced `claim_activity_context_v2`/`publish_activity_context_v2`; NULL never success; renew around
  inference; dead-letter via fail RPC (`ActivityLane.swift:233-259,306-400`).

### Projection lane — prior-audit hot-loop is FIXED in this tree
- Non-projectable kinds/format are settled once and skipped; missing objects are deferred (not a
  failure); decode/commit failures go through bounded `noop_fail_projection_debt`
  (`ProjectionLane.swift:98-110,186-196,243-260`). DB backoff capped at 1 h, failures capped at 16,
  no dead-letter state (`20260918040000_production_projection_debt.sql:105-112`; claim lease 2 min,
  line 100). Projection is OFF in production (`deploy/OPERATIONS.md:8-10`, `docs/BACKEND.md:108-114`).

---

## 2. T24 — A's large backfill + failing job vs B's live writes/reads

- Live WRITES and READS are edge functions (`push`, `scores`) served by Supabase, NOT the worker.
  They are never blocked by the worker's queue (only by their own intake admission
  `admit_noop_request` rate limiter, `supabase/functions/push/index.ts:87-90`). => B's writes/reads
  cannot be starved by A's backfill at the worker level.
- B's SCORING turn: the claim is one job per cycle globally; the oldest-served-users-first order
  (20261002123000:29) plus the per-job 45 s cooldown (line 25) guarantee B gets a scoring pass at
  least every ~45 s + compute while A drains a backfill. Code-verified structure; a live 2-user
  measurement is **NOT VERIFIED (needs staging)**.
- Owner-scoped lock: uploads take `pg_advisory_xact_lock('scoring-inputs-v2:'||owner)` exclusively;
  the worker takes the same key SHARED from before its claim through commit (`ScoringLane.swift:512-561`;
  publish takes the shared xact lock, `20260918010000:235`). The lock is PER-OWNER, so A's compute
  blocks only A's uploads. A's compute (~7-8 s) can push A's own uploads past the API's 8 s statement
  timeout (~1% of uploads, documented known issue `docs/BACKEND.md:344-348`). Cross-owner blocking: none.
- Failing job bounded: dead-letter at 8 with capped exponential backoff (all lanes, section 1).
- 16 k stale `noop_projection_debt` rows (`docs/BACKEND.md:376-378`): they only matter to the
  projection lane, which is OFF in production, so they hold no owner lock there.
- Legacy queue is served before v2 (`ScoringLane.swift:162-164`), but legacy items whose owner is
  uploading are deferred (`legacyQuietSeconds` default 20, `legacyMaxDeferSeconds` 1800;
  `ScoringLane.swift:82-97,212-285`), and a revoked claim is never retried (`ScoringLane.swift:346-355`).
  So a streaming phone cannot starve v2 through the legacy queue.
- **Gap:** the Swift v2 lane has NO per-user reservation bound (the per-user 2 / per-device 2 /
  max_workers 4 fleet policy in `20260921112000_fleet_scheduler.sql` applies only to the JVM
  physiology worker via `scoring_claim_one`, which THIS worker never calls — grep shows zero
  references in Tools/CloudWorker). With one process and one global claim per cycle this is bounded,
  but there is no DB-level per-user cap on the v2 lane.
- Verdict: T24 **PASS at code level** (bounded work, fairness ordering, owner-scoped locks, dead-letter
  all present); the observable-recovery half is **NOT VERIFIED** (needs staging).

---

## 3. Capacity evidence (T26, spec 7.4)

### What the heartbeat/DB exposes today (measurement surface exists)
- Heartbeat every 15 s writes per-lane counters, budgets, db facts, `source_revision`, and a QUEUE
  AGE summary: eligible counts + oldest-eligible seconds per lane
  (`main.swift:482-561,620-657`; queue gates mirror the claim gates, incl. invalidation-suppressed
  rows excluded). Exits for systemd restart after 4 missed heartbeats (`main.swift:742-748`).
- Health-check queries exist: heartbeat staleness, upload receipts/hr, `scoring_jobs_v2` pending +
  dead_lettered counts, latest snapshots, per-owner series freshness, HR-conflict counts, series
  counters (`docs/BACKEND.md:296-341`).
- Documented measured values (LEADS, not reproducible from this tree): snapshot cadence ~45-46 s,
  upload failures ~1%, upload p90 ~4 s, input-gate deadlock fix (BACKEND.md:146-159); earlier legacy
  churn measurement (37 legacy claims / 46 in 12 min, BACKEND.md:128-132).
- Droplet size is documented, not measured: 4 vCPU/8 GB sfo3 (`deploy/README.md:9`,
  `deploy/OPERATIONS.md:4`). **Running CPU/RAM/disk, DB tier/limits are NOT VERIFIED (no deployed
  access).**

### Staging capacity harness (exists in code, cannot run as committed)
- `supabase/functions/tests/capacity_evidence.ts` — cohorts [10,100,750,1000], quantiles,
  `ownerFairness` (live vs backfill progress, first-completion p95), resource sampling (docker stats,
  ps RSS/CPU, DB connections), SLO constant 60 s p95.
- `supabase/functions/tests/multiuser_worker_sql_test.ts` — 10 owners × 2 devices, 4 worker replicas,
  27,001 HR rows, live + backfill classes, noisy-owner injection mid-run, per-user ≤ 2 reservations,
  connection budget ≤ 24, backoff recovery, writes `fleet-worker-capacity.json`. Gated on
  `PIPELINE_TEST_*` env (`ignore: !container || !binary`).
  - **Critical caveat:** this test drives the JVM physiology worker (`SCORING_ALGORITHM_VERSION
    frwhoop-physiology-2`, JAVA_HOME), i.e. NOT the current production Swift `frwhoop-worker`. The
    Swift v2 lane has no staged capacity test in this tree.
- `capacity_evidence_test.ts` REQUIRES `infra/vps/launch-capacity.json` and
  `infra/vps/templates/docker-compose.fleet.yml` (asserts `SCORING_FLEET_REPLICAS:-4` etc.) — neither
  file exists in this checkout (`git ls-files infra` empty; no history). That test cannot pass as-is.
- Verdict: T26 **NOT VERIFIED (staging)**. Staging plan knobs exist (declare rates/budgets/cohorts),
  but (a) no Swift-worker staged run exists, (b) the infra declaration files are missing from the
  repo, (c) no deployed resource/latency measurement is reproducible here.

---

## 4. G6 — step counter semantics, rollover, source arbitration (T27, T28)

### Counter semantics (T27)
- Source field: `step_motion_counter@57`, a CUMULATIVE u16 that wraps at 65536
  (`StepsCounter.swift:8-11`; `AnalyticsEngine.swift:981-985`). It does NOT reset at midnight; it is
  a monotonic wrap counter.
- Daily total = sum of wrap-aware deltas `(cur - prev) & 0xFFFF` over the day's samples, first sample
  of the day contributes 0 (`StepsCounter.swift:73-90`; `AnalyticsEngine.swift:992-1007`). Because
  each day is computed from its own window, there is NO yesterday carryover (the delta straddling
  midnight is dropped on both sides — conservative, deliberate).
- Reset/reboot/wrap guards: absolute `maxStepDelta = 512` and a ≤ 4 ticks/s rate gate
  (`StepsCounter.swift:41-64`); bout-block exception 6-20 ticks/≤ 2 s (lines 44-54).
- Unit-tested: wrap, big-gap drop, boundary exclusion, burst rejection, bout blocks, boundary-sample
  window summing (`StepsCounterTests.swift`; 16/16 green in this audit run).
- Intraday minute buckets attribute each delta to the LATER sample's bucket and sum to the day total
  (`IntradaySeries.swift:407-437`); cross-midnight safety verified (first bucket needs ≥ 2 samples).
- No "global monotonic guard" carrying yesterday's total exists on the phone display path: steps are
  day-windowed everywhere (server `analyzeDay` and app `IntelligenceEngine` slice `daySteps` to the
  local calendar day, `IntelligenceEngine.swift:1398-1403`). The only monotonic counters in the app
  are BLE reassembler drop tallies, not steps.
- Verdict: T27 **PASS (code-verified + unit tests)**. Physical strap reset/reconnect behavior remains
  device-verification only.

### HealthKit/WHOOP source arbitration (T28)
- Reads use `HKAnchoredObjectQuery` with per-type persisted anchors; anchor advances only after
  ingestion commits (`HealthKitBridge.swift:367-461`).
- The app's own write-back is EXCLUDED from reads via `notNoopAuthored`
  (`HealthKitBridge.swift:1416-1426`), closing the export/reimport loop for HR, HRV, RHR, sleep,
  workouts, vitals.
- Write-back is delete-then-write scoped to `HKSource.default()` (our own source) by external-UUID
  key or date range (HR uses a 48 h rewrite window behind a forward-only cursor,
  `HealthKitBridge.swift:1123-1160`); a source-scoped migration sweep is idempotent (lines 886-930).
- Imported values land under the separate `apple-health` source id (`appleDeviceId`), never merged
  into strap rows; strap HRV is computed from the strap's own R-R, and HealthKit HR (1/min buckets)
  is written back only as display/export data — no HR/RR series is concatenated into physiology.
  Imported dailies override only per-day computed fields via `HealthExportMerge` (`HealthKitBridge.swift:959-972`).
- Known acknowledged race (narrowed, not closed): a Watch workout can still be unknown during the
  observer-wake latency, so a strap bout may be detected before the overlapping Watch workout is
  seen (`HealthKitBridge.swift:314-326`). Off-device unverifiable.
- Verdict: T28 **PASS at code level** for provenance/deletion/separate-series; device verification of
  anchor-based live delivery and the workout race is **NOT VERIFIED**.

---

## 5. G7 — owner-scoped diagnostic surface

- EXISTS server-side: `GET /functions/v1/scores/diagnostics` (owner+fleet auth) →
  `server_pipeline_diagnostics` (`supabase/functions/_shared/serverScores.ts:135,233-241`;
  `20260921101000_server_pipeline_diagnostics.sql:6-95`). It reports: receipt window, projection
  pending/retrying + oldest pending, work items (input_revision, status, lease, failures,
  next_attempt_at, dirty_at), publications, worker heartbeats (source_revision, last_poll, status),
  and per-stage acquire→display status. Owner/device/installation ownership enforced inside the RPC
  (lines 20-23).
- The app DOES surface "Newer data is being scored" (pending) and partial-status reasons on Today
  (`TodayView.swift:283-294`), plus "Pending sync" strap-history captions (TodayView.swift:503-506,
  995-998).
- GAPS against spec 9:
  - `ingest-verify` is OPS-ONLY (WORKER_SECRET/service-role), NOT owner-scoped
    (`supabase/functions/ingest-verify/index.ts:2,24`).
  - `server_pipeline_diagnostics` does NOT include: stream coverage (the day snapshot's
    `coverage` object is not in this surface; `selected_features` strips `device_id`,
    `day_intervals`, `context_intervals`, `timezone_ids`, `20260921101000:27`), queue age for
    `scoring_jobs_v2` (only projection oldest-pending is reported), durable-acceptance vs
    verified-archival (archive status is per-feature `archive_status` only), projection revision,
    largest gap, or explicit blockers. Day-bound/zone-policy keys exist in the underlying
    `server_scoring_for_device_day` features (`timezone_id`, `day_intervals`, `context_intervals`,
    `20260919210000:76-85`) but are stripped from this surface.
  - In-app: `StorageView` is local storage only; the `Monitor` tab is a SAMPLE-FILLED placeholder
    (`MonitorView.swift:228 snapshot: .sample`) — no in-app surface consumes `/diagnostics`.
- Verdict: G7 **PARTIAL / FAIL for the minimal single-surface requirement**. The server surface is a
  strong base; the required fields (day bounds, coverage, queue age, largest gap, blockers) and an
  in-app consumer are missing. Minimal repair: extend `server_pipeline_diagnostics` (or add a
  small `scores/diagnostics` fields) with coverage, v2 queue age, archive status, and wire a
  settings/status read in the app.

---

## 6. Jobs-table health

- `scoring_jobs_v2`: dead-letter and pending are directly queryable (BACKEND.md:310-311); heartbeat
  reports eligible counts + oldest age per lane (main.swift:482-561).
- Restart/requeue: every claim is a leased transaction; leases expire (v2/legacy/archive/activity
  300 s, projection 120 s) and rows redeliver when `lease_until <= now`. The worker exits after 4
  consecutive heartbeat DB failures (`main.swift:742-748`) and systemd restarts it
  (`deploy/frwhoop-worker.service`: Restart=always, RestartSec=5, TimeoutStopSec=90).
- Requeue on restart for rows still `running`/`uploading`: all claim predicates accept expired leases
  (`(lease_until is null or lease_until<=clock_timestamp())`).
- **DEFECT (P2, code-verified): `physiology_archive_outbox` 'retry' status is not allowed.**
  `ArchiveLane.swift:256` sets `status='retry'`, but the table's CHECK allows only
  `('pending','uploading','uploaded','verified','failed')`
  (`20260918020000_physiology_publication.sql:93`). The `releaseOutboxLease` write therefore fails
  with a check-constraint error; the row stays `status='uploading'` with its lease and is re-claimed
  only after lease expiry (300 s), looping without the intended 30 s backoff and without any
  failure/dead-letter accounting, and re-uploading the object to B2 each cycle. The claim predicate
  also lists 'retry' (`ArchiveLane.swift:134`) which can never exist.
  Repair: extend the CHECK to include 'retry' (additive migration) or set `status='failed'`
  (already allowed) with the `next_attempt_at` backoff; add a unit/integration test for the
  release path.

---

## Cross-cutting NOT VERIFIED / blocked checks (need external access)

1. T24/T26 staged 2-user backfill-vs-live fairness + recovery run against the actual Swift
   `frwhoop-worker` (no such test exists; the only staged test drives the JVM physiology worker).
2. T26 deployed capacity: running revision identity (prior audit's FRWHOOP_SOURCE_REVISION mismatch),
   CPU/RAM/disk headroom, DB tier/limits, storage retries — droplet/DB access required.
3. T26 infra declaration files (`infra/vps/launch-capacity.json`,
   `infra/vps/templates/docker-compose.fleet.yml`) missing from the repo; `capacity_evidence_test.ts`
   cannot pass as committed.
4. T27 physical strap reset/reconnect/reboot step behavior (unit level covered; device level not).
5. T28 HealthKit anchored live delivery, observer wake cadence, and the Watch-workout overlap race
   (HealthKit has no simulator support).
6. Deployment claim that migration order/application matches this tree (39 migrations after
   20260921104000 applied directly via SQL per prior audit — re-verify against live schema).

## Recommended next actions (priority order)

1. Fix the outbox 'retry' CHECK-constraint defect (section 6) — small, code+SQL, testable.
2. Extend `server_pipeline_diagnostics` with coverage, v2 queue age, archive status, projection
   revision, and wire a minimal in-app status/settings consumer (G7).
3. Commit the missing `infra/vps/launch-capacity.json` + `docker-compose.fleet.yml` (or drop the
   test references) so the capacity gate is runnable; retarget the staged capacity test at the Swift
   worker or add a Swift-worker variant (T26).
4. Add a DB-level per-user bound to the v2 claim if multi-worker deployment is ever planned (single
   process today makes global=1 the bound; document that as the topology decision).
5. Update `deploy/worker.env.example` with FRWHOOP_LEGACY_QUIET_SECONDS, FRWHOOP_LEGACY_MAX_DEFER_SECONDS,
   FRWHOOP_V2_INPUT_GATE_SECONDS, FRWHOOP_DISABLE_LANES (exist in code, absent from the template).
