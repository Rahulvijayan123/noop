# Nara capacity workbook (spec 7.4 — staged, executable measurement plan)

Owner: repair-diag (G5/G7 diagnostics + capacity evidence plumbing).
Status: **PLAN ONLY — NOT VERIFIED.** No staged capacity run has been executed. Every number
below is either a predeclared target, a measured-when snapshot from the 2026-10-03 read-only
droplet baseline (`docs/core-plumbing/findings/root-deployment-baseline.md`), or a workload
declaration. Nothing here is a measured capacity result.

This workbook is the run sheet a staging operator executes. It declares the workload, budgets,
metrics, exact commands and config, and the pass/fail rule (spec 7.4: *capacity passes only for
the tested workload/configuration against those predeclared objectives with documented headroom;
do not relabel a failed target as passing after observing results*).

---

## 1. Topology decision (g56 item 4)

- Production compute is the **Swift `frwhoop-worker`** (`Tools/CloudWorker`), one process, one
  global v2 claim per cycle (`claim_scoring_v2` `limit 1`). This is the ONLY target of any
  staged capacity run.
- The JVM physiology worker's fleet scheduler (`20260921112000_fleet_scheduler.sql`,
  `scoring_claim_one`, per-user 2 / per-device 2 / max 4 replicas) **does not apply** to the
  Swift worker: grep shows zero references in `Tools/CloudWorker`. Existing staged tests that
  drive the JVM worker (`multiuser_worker_sql_test.ts` with `frwhoop-physiology-2`/JAVA_HOME)
  are **not** evidence for the Swift target.
- Today's bound is `processes = 1` and `global claims per cycle = 1`, plus the per-job 45 s
  cooldown and oldest-served-users-first ordering. There is **no DB-level per-user cap on the
  v2 lane**. If multi-worker deployment is ever planned, add a per-user reservation bound to
  the v2 claim first (g56 recommendation #4). Single-process topology is the documented
  decision for this audit.
- Projection lane is OFF in production (systemd drop-in; `deploy/OPERATIONS.md`). A staging run
  that wants projection evidence must enable it explicitly and say so.

---

## 2. Declared workload scenarios (tiers 10 / 50 / 100)

These are workload scenarios, not supported-user claims. Per run, declare **all** of the
following before starting (fill the table for each tier):

| Declaration | Tier 10 | Tier 50 | Tier 100 | Notes |
| --- | --- | --- | --- | --- |
| Active users (owners) | 10 | 50 | 100 | one device each unless declared |
| HR stream rate | 1 Hz | 1 Hz | 1 Hz | strap live notify |
| RR stream rate | burst, ~1 Hz while active | same | same | `rrPacketProvenance` |
| Resp / skin temp / spo2 | 1/min | 1/min | 1/min | generated per night |
| Gravity / steps / events | as captured | same | same | WHOOP event cadence |
| Batch size | 2 000 rows max | same | same | `CloudBatchBuilder` cap |
| Initial backlog per user | 0 | 24 h | 24 h | history seed before run |
| Run duration | ≥ 30 min | ≥ 60 min | ≥ 60 min | bounded per spec |
| Mix | live ingest + reads + 5-min compute + midnight closure + 24 h backfill | same | same | replay realistic cadence |

Backlog: preload each owner's last 24 h of strap history, then start live ingest. Midnight
closure: let one local-midnight rollover occur inside the run. Backfill: trigger a 24 h
`scoring_jobs_v2` invalidation mid-run.

## 3. Declared budgets (product targets, adjustable only with a written reason)

| Budget | Target | Contract basis |
| --- | --- | --- |
| Durable ingest response (server request receipt → accepted) | p95 ≤ 2 s | spec 7.4 |
| Projection processing lag (eligibility → published) | p95 ≤ 60 s | spec 7.4 |
| Compact day read (`GET /scores?day=…`) | p95 ≤ 2 s | spec 7.4 |
| Maximum job age (any eligible `scoring_jobs_v2` row) | ≤ 10 min | declared |
| Recovery deadline (drain after injected outage) | ≤ 20 min | declared |
| Headroom | CPU < 70%, RSS < 60% of 8 GB, DB connections < 80% of tier budget, queue non-growing | declared |

A five-minute HRV result is not due before its window closes; measure sensor-to-acceptance lag
separately (including late banked history and OS-suspended delivery).

## 4. What to measure

- **Throughput**: accepted batches/rows per minute (`noop_upload_receipts`), published snapshots
  per minute (`scoring_snapshots_v2`), series rows written.
- **Latency**: p50/p95/p99 for ingest HTTP → receipt, claim → publish, and day reads. Collect
  from edge/worker logs and a read probe; never from memory.
- **Per-user queue/job age**: `scoring_jobs_v2` pending + oldest `not_before`/`dirty_at` age per
  owner; heartbeat's `queue.oldest_eligible_seconds` per lane.
- **Outage recovery**: stop the worker for N seconds (or block uploads), then measure drain time
  to the declared recovery deadline and confirm no sustained queue growth.
- **CPU/RSS/event-loop delay**: `ps`/`docker stats` samples, worker event-loop stall if exposed.
- **Disk/fsync**: storage used, object retries, B2 upload failure counts (`physiology_archive_outbox`,
  `scoring_archive_jobs_v2`).
- **DB**: connection count vs budget, statement/query time, lock waits (advisory locks are
  per-owner by design; watch for cross-owner waits — there should be none).

## 5. Exact run sheet (Swift worker)

### 5.1 Build and unit gate (always green first)

```sh
cd Tools/CloudWorker
CPATH=/opt/homebrew/opt/libpq/include swift test     # 214 pass / 6 skip baseline
swift build -c release
```

### 5.2 Config (one `worker.env` per run; names only here, real values on the host)

```sh
FRWHOOP_DB_URL=postgres://<staging>@<host>:5432/postgres
FRWHOOP_DB_SSLMODE=verify-full
FRWHOOP_B2_KEY_ID=<staging key>
FRWHOOP_B2_APPLICATION_KEY=<staging key>
FRWHOOP_B2_BUCKET=FRWHOOP-STAGING
FRWHOOP_INGEST_SECRET=<staging ingest secret>
FRWHOOP_WORKER_NAME=frwhoop-worker-staging
FRWHOOP_SOURCE_REVISION=<git sha of the tree under test>   # never a stale label (see 6.3)
FRWHOOP_PROJECTION_BUDGET=8        # keep 0 (off) unless the run tests projection
FRWHOOP_SCORING_BUDGET=4
FRWHOOP_ARCHIVE_BUDGET=4
FRWHOOP_VERIFY_BUDGET=4
FRWHOOP_RECONCILE_BUDGET=2
FRWHOOP_POLL_INTERVAL_MS=1000
FRWHOOP_HEARTBEAT_INTERVAL_MS=15000
FRWHOOP_LEGACY_QUIET_SECONDS=20
FRWHOOP_LEGACY_MAX_DEFER_SECONDS=1800
FRWHOOP_V2_INPUT_GATE_SECONDS=10
# FRWHOOP_DISABLE_LANES=            # e.g. projection,verify,activity for a pure scoring run
# FRWHOOP_ACTIVITY_ENABLED=1        # only for an explicit HART run; off by default
```

Run: `env $(cat worker.env) /opt/noop/Tools/CloudWorker/.build/<triple>/release/frwhoop-worker`.

### 5.3 Load generation and measurement

- Ingest driver: POST gzip NDJSON batches to `/functions/v1/push` with the declared rates/batch
  sizes, replaying a real captured day per owner (`supabase/functions/tests` fixtures and
  `Tests/ServerFixtureNative` exports are the reference payload shapes).
- Read probe: `GET /functions/v1/scores?day=<local-day>&deviceId=<id>` on a loop, record p50/95/99.
- Queue probe (30 s cadence), per lane:

```sql
select algorithm_version, count(*) filter(where completed_revision<input_revision and not dead_letter) pending,
       count(*) filter(where dead_letter) dead,
       min(not_before) filter(where completed_revision<input_revision and not dead_letter) oldest_eligible
from scoring_jobs_v2 group by algorithm_version;
```

- Resource sampler: `ps -o rss=,pcpu= -p <worker pid>` and `docker stats --no-stream <db>` (or
  `pg_stat_activity` counts) at 10 s intervals → feed `summarizeResourceSamples` from
  `supabase/functions/tests/capacity_evidence.ts`.
- The Swift-worker staged run has **no in-repo automated test yet** (g56 T26 gap). The existing
  `multiuser_worker_sql_test.ts` drives the JVM worker and must not be cited as Swift evidence.
  Adding a Swift-worker variant (same cohort/quantile/recovery assertions, `SCORING_ALGORITHM_VERSION`
  pointed at the Swift binary, or driving `claim_scoring_v2` directly) is a prerequisite for a
  repeatable gate.

### 5.4 Outage recovery drill

1. Kill the worker (`systemctl stop frwhoop-worker` on the staging host) for 300 s.
2. Restart; measure time until `scoring_jobs_v2` pending drains to 0 and heartbeat queue ages
   return below 10 min.
3. Record the drain duration; pass requires ≤ the declared recovery deadline with no dead letters.

## 6. Measured-when droplet baseline (2026-10-03, read-only)

Source: `docs/core-plumbing/findings/root-deployment-baseline.md` (ssh `root@143.198.62.4`,
read-only psql over the worker's TLS config). These describe the CURRENT 5-user production
load, NOT a staged 10/50/100 run. Label: **measured-when**, not a capacity result.

| Item | Value (measured 2026-10-03) | Meaning |
| --- | --- | --- |
| Host | 4 vCPU / 7.8 GiB (779 MiB used), 140 GB free disk, load 0.14 | droplet, sfo3 |
| Worker RSS | ~199 MB (peak ~268 MB); CPU 7.4% avg over 12 h 46 m | idle-ish current load |
| Scoring lane counters | claimed 1109 / completed 1074 / superseded 35 / series_published 1019 / series_rows_written 30553 / legacy_deferred 32231; 0 dead letters | since process start |
| `scoring_jobs_v2` | 490 rows, 10 pending, 0 dead-lettered | snapshot |
| `noop_projection_debt` | 72 667 rows, 10 691 failing, oldest 2026-08-25 | projection OFF; backlog irrelevant to scoring |
| `scoring_archive_jobs_v2` | 15 738 total, 0 pending | archive healthy |
| Scale | 29 users / 29 profiles; 5 users with published scores; 173 published day scores | current tenant load |
| Heartbeat | fresh (`since_poll` ~6 s); `last_error` "digest mismatch … no expected wire digest" | VERIFY-lane lead, spec 4.6 |

## 7. NOT VERIFIED / not measured (explicit)

- **No staged Swift-worker capacity run exists.** T26 verdict from g56: NOT VERIFIED (staging).
- Deployed resource/latency behavior under 10/50/100 tiers: NOT MEASURED.
- `infra/vps/launch-capacity.json` and `infra/vps/templates/docker-compose.fleet.yml` are NOT in
  this checkout. `capacity_evidence_test.ts` now **self-skips with a clear reason** when those
  fixtures are absent (fail-open), and the unit tests in it still run. This workbook is the
  documented plan that a staging run (and the committed infra declaration) would execute — the
  smaller change was chosen over committing placeholder templates, and no capacity number was
  fabricated.
- Deployed revision label: `FRWHOOP_SOURCE_REVISION=a7ea5426` in `/etc/frwhoop/worker.env` names a
  revision that does not exist in the authorized clone. Do not read the deployed revision from
  env or from the heartbeat `source_revision` column; compare binary/source fingerprints
  (baseline proves deployed CloudWorker == `c3e30be1`).
- The verify-lane "digest mismatch: no expected wire digest" lead (spec 4.6) is open and is not
  a capacity question.

## 8. Pass/fail rule

A tier passes only if, for the DECLARED workload and config of that tier:

1. p95 durable-ingest ≤ 2 s, p95 projection lag ≤ 60 s, p95 compact day read ≤ 2 s;
2. steady-state queues bounded (no sustained growth) and max job age ≤ 10 min;
3. injected-outage backlog drains within the declared recovery deadline;
4. CPU/RSS/DB-headroom targets hold, with the measured numbers recorded.

Record every quantile, queue age, and resource sample in this workbook's evidence section
(none exists yet — the section is intentionally empty). Report saturated tiers rather than
"passing" them, and never relabel a failed target after seeing the numbers.
