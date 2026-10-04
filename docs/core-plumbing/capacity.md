# Capacity evidence and decision

## Measured (read-only production, 2026-10-03 — findings/root-deployment-baseline.md)

- Host: droplet `frwhoop-worker-2`, 4 vCPU / 8 GB, Ubuntu 24.04, 140 GB free disk, load average 0.14/0.10/0.09.
- Worker: RSS ~199-246 MB (peak ~268 MB), ~7.4% avg CPU over 12h46m, 0 restarts since 08:09 UTC.
- Queues at snapshot: scoring_jobs_v2 490 rows (10 pending, 0 dead-letter); scoring_archive_jobs_v2 15,738 (0 pending); noop_projection_debt 72,667 rows (10,691 failing; lane OFF in production); heartbeat fresh (~6s).
- Scale: 29 auth users / 29 profiles, 5 users with published scores, 173 published day scores.
- Intraday series: 1,019 series publishes, 30,553 rows written, 0 failed.

## What is NOT measured (blocked, named)

- No staged multi-user load run exists (no staging environment; production is read-only). T24 recovery observability and T26 tier reports are NOT VERIFIED until the staged run executes the workbook below.
- The committed capacity harness (capacity_evidence_test.ts) targets the JVM physiology worker, not the Swift frwhoop-worker, and references infra/vps/launch-capacity.json + docker-compose.fleet.yml which are absent from the repo (repair-diag: fail-open + templates/workbook).

## Current supported workload (evidence-backed statement)

The deployed configuration (c3e30be1 sources, 5 lanes with projection+activity off) has sustained the observed workload (5 active scored users, 173 days, ~30k series rows, 15.7k archive jobs all complete, heartbeat fresh, no dead letters) with CPU headroom ~92% and RAM headroom ~97%. This is a statement about the OBSERVED workload, not a supported-user claim. No upgrade is indicated at this scale.

## Staged capacity plan

See [capacity-workbook.md](capacity-workbook.md) (repair-diag): declared stream rates, tier plan (2-user functional -> 10/50/100 workload scenarios), budgets (p95 durable ingest <= 2s from server receipt; p95 projection lag <= 60s from eligibility; compact day reads p95 <= 2s; bounded queues; declared recovery deadlines), measurement commands, and pass/fail criteria per spec 7.4. Execute on a staging environment; production stays read-only.

## Upgrade decision framework

- Upgrade trigger: sustained CPU/RAM pressure or queue-age growth beyond recovery deadlines AT the measured tier — measured, not assumed. Current droplet has no measured pressure.
- No infrastructure purchase/resize is authorized or recommended from current evidence.
