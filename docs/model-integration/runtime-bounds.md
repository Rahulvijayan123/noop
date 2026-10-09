# Runtime bounds and scheduling (Spec 01 §5)

Area branch `spec01/runtime-20261007`. This page covers how the inference sidecar bounds its own
work, how the worker reacts when the sidecar is full, and how candidate metrics are scheduled so
none of them starves. The shared contract (busy answer, identity) is in [README.md](README.md).

## What changed and why

| Problem at the base | Change |
|---|---|
| `server.py` ran each computation on a daemon thread, joined it with a timeout and answered `timeout` while the thread kept computing. Repeated timeouts grew live threads and CPU without bound. `ThreadingHTTPServer` made one thread per connection. | `execution.py`: every computation runs in a warm worker **process** of a lane with a fixed number of processes. An overrun process is terminated, reaped and replaced before its slot is free again. HTTP is served by a fixed pool of handler threads. |
| A full sidecar had no way to say so. | HTTP 429 `{"status":"error","error":{"code":"busy",...}}` + `Retry-After`. `InferenceClient` maps it to `InferenceClientError.busy`. No caller records it as a result. |
| Candidate metrics ran in a fixed order inside a per-drain run budget (default 2). A budget skip was only a counter, so with more enabled metrics than the budget the last ones never ran for a day unless the day was re-scored. | Persisted pending queue (`20261008110000_physiology_candidate_pending.sql`): every enabled metric of a scored day is a row at the claim's input revision; each drain runs the oldest due rows first. A budget, deadline or busy skip stays pending with that reason. |
| `active` mode recorded `active_promotion_deferred` in row diagnostics only. | Requested and effective mode are reported in the selection read, in the stage's mode report and in the heartbeat. |

Redesigns against round 1: none. Round 1's design (process lanes, persisted queue called from
`CandidateStage.swift`) is kept. Round 2 added the missing SQL, wired the queue into the scoring
lane and the heartbeat, and fixed three defects found while testing (below).

## Execution model (sidecar)

- Two lanes: `infer` (`POST /v1/infer`) and `sleep_features` (`POST /v1/sleep-features`). A lane
  owns `workers` processes; one process runs one job at a time. Nothing computes on an HTTP thread.
- **Warm processes.** A process imports and builds its registry (or the sleep-feature code) once,
  calls every provider's `readiness()` once (which loads checkpoints), and only then reports `hello`.
  The parent's readiness and manifest are computed once at startup (`FRWHOOP_INFERENCE_READINESS`,
  default `worker`: readiness reported by the warm worker).
- **Admission.** A request takes an idle process, or waits at most `queue_wait_ms` for one
  (`start_wait_ms` only while a process is still warming up). At most `max_waiting` requests wait per
  lane. Anything else gets HTTP 429 `busy` at once.
- **Budget.** The handler waits for the result until the job's budget (`FRWHOOP_REQUEST_TIMEOUT_MS`
  for `infer`, `FRWHOOP_SLEEP_FEATURES_BUDGET_MS` for sleep features). On overrun the response is the
  same as before (`withheld` + `timeout`; for sleep features the degraded `status:"timeout"`
  document). The process gets SIGTERM at once; the lane supervisor waits `kill_grace_ms`, sends
  SIGKILL if needed, reaps it, starts a replacement, and only then frees the slot. The HTTP handler
  never waits for the replacement.
- **Crash.** A process that dies is reaped and respawned with backoff; the request it was running gets
  a `provider_error` answer (sleep features: the degraded `error` document, `worker_crashed: ...`).
- **Quarantine.** All `infer` providers share one worker, and every budget overrun costs that worker
  a kill and a warm restart (about 60 s here) during which every other provider is answered 429.
  After `FRWHOOP_INFERENCE_QUARANTINE_AFTER` (3) consecutive overruns a provider is quarantined for
  `FRWHOOP_INFERENCE_QUARANTINE_SECONDS` (600): its requests are answered at once, without dispatch,
  `withheld` `timeout` with `diagnostics.withheld_detail = "provider_quarantined"`,
  `worker_terminated: false`, `consecutive_timeouts`, `until_utc` and `retry_after_s`. After the
  cool-off the next request is a real trial: another overrun re-arms the quarantine at once, a result
  resets the count. So an always-overrunning provider cannot keep the others out.
- **Loaded identity.** The warm worker's `hello` reports what it measured it loaded; `/healthz`
  reports it only while the worker that sent it is alive (it disappears when that worker is reaped,
  and a replacement's report takes its place).
- **Readiness.** Readiness is adopted once, from the first warm worker. A replacement whose report
  differs is logged (`a replacement worker's readiness differs ...`) and listed in
  `execution.provider_readiness.disagreements`; the adopted readiness is kept.
- **Math threads.** Each process starts with `OMP/OPENBLAS/MKL/NUMEXPR/VECLIB/BLIS/NUMBA/TF_*` thread
  variables set to `FRWHOOP_INFERENCE_MATH_THREADS` before the interpreter imports anything; torch is
  capped after warm-up. `pin_model_root(os.environ)` runs first in `main()`, so children inherit it.
- **HTTP.** A fixed pool of handler threads and a bounded accept backlog; a connection beyond the
  backlog gets an immediate 429 `busy` (lane `http`) and is closed. `/healthz` is answered by the
  same pool and never waits for a job.

## Limits and how they were chosen

Host: `frwhoop-worker-2`, 4 vCPU / 8 GB, shared with the Swift worker and its activity Python
children. Sidecar unit: `CPUQuota=150%`, `CPUWeight=50`, `MemoryHigh=2G`, `MemoryMax=3G`,
`MemorySwapMax=0`, `TasksMax=64`.

- One process per lane: two concurrent single-threaded jobs fit `CPUQuota=150%` with headroom for
  the parent and the HTTP threads; a second `infer` process would double the largest resident cost
  (torch + keras + the sleepecg model) for a lane whose callers (one scoring thread, one sensor
  thread) are serial anyway.
- `max_waiting` 2 (`infer`) / 1 (`sleep_features`): the worker's two lanes that call `/v1/infer`
  (candidate stage, sensor biomarkers) each send one request at a time, and the scoring lane sends
  one sleep-features request at a time.
- `queue_wait_ms` 250: short enough that a full sidecar answers `busy` well inside every caller's
  transport budget (sleep features: 3500 ms around the 3000 ms compute budget).
- HTTP threads 12 against `TasksMax=64`: the parent's threads + 12 handlers + two process trees with
  math threads at 1 stay far below it.

### Measurements (2026-10-08, this branch)

Method: `_build-scratch/spec01/runtime/scripts/measure_pool.py` starts the real server
(`create_server(..., provider_readiness="worker")`), starts both lanes, waits for `hello`, reads
`/healthz` and measures each process with `ps -o rss` and macOS `footprint`;
`measure_rss.py` builds the full default registry in one process. Model root: the deploy area's
provisioned smoke revision `rev-a784abfae6243237` (copied to the runtime scratch dir;
`manifest.json` sha256 `bfa5e1de...fe08a`, `sleepecg/0.5.9/wrn-gru-mesa.zip` `5622a858...e869`,
`classifier.keras` `0b392209...6ffd8`). All six default providers reported ready.

| Process | RSS | phys_footprint | threads | warm-up |
|---|---|---|---|---|
| parent (HTTP + supervisors) | 46 MB | 59 MB | 18 | 2.2 s build |
| `infer` worker (full registry warm: torch, keras, sleepecg, neurokit2, yasa) | 281 MB | 424 MB | 4 | 60 s |
| `sleep_features` worker | 45 MB | 189 MB | 1 | 28 s |
| total RSS | 373 MB | | | |

A single process building the full registry peaked at 432 MB RSS (`measure_rss.py`). These were
measured on the shared macOS arm64 build machine while its load average was 300-900 (warm-up times
are inflated accordingly), not on the Linux Droplet; Linux RSS for the same wheels is expected to be
of the same order, but that is not measured. With one process per lane the sidecar sits near
0.4-0.6 GB, well under `MemoryHigh=2G`; a second `infer` process would add about 0.3-0.45 GB.

## Environment variables (sidecar)

| Variable | Default | Range | Meaning |
|---|---|---|---|
| `FRWHOOP_INFERENCE_MAX_ACTIVE` | 1 | 1–8 | `infer` worker processes (= jobs that can be active) |
| `FRWHOOP_INFERENCE_MAX_WAITING` | 2 | 0–32 | `infer` requests that may wait for a process |
| `FRWHOOP_INFERENCE_QUEUE_WAIT_MS` | 250 | 0–5000 | how long one of them waits before `busy` |
| `FRWHOOP_SLEEP_FEATURES_MAX_ACTIVE` | 1 | 1–8 | sleep-features processes |
| `FRWHOOP_SLEEP_FEATURES_MAX_WAITING` | 1 | 0–32 | |
| `FRWHOOP_SLEEP_FEATURES_QUEUE_WAIT_MS` | 250 | 0–5000 | |
| `FRWHOOP_SLEEP_FEATURES_BUDGET_MS` | `features.BUDGET_MS` (3000) | 100–120000 | sleep-features compute budget |
| `FRWHOOP_INFERENCE_START_WAIT_MS` | 30000 | 0–120000 | wait allowed while a process is still warming up |
| `FRWHOOP_INFERENCE_START_TIMEOUT_MS` | 180000 | 1000–600000 | a process with no `hello` by then is killed and restarted |
| `FRWHOOP_INFERENCE_KILL_GRACE_MS` | 1000 | 50–10000 | SIGTERM to SIGKILL grace |
| `FRWHOOP_INFERENCE_MATH_THREADS` | 1 | 1–4 | numerical-library threads per process |
| `FRWHOOP_INFERENCE_HTTP_THREADS` | 12 | 2–64 | HTTP handler threads |
| `FRWHOOP_INFERENCE_HTTP_BACKLOG` | 16 | 0–256 | accepted connections that may queue for a handler |
| `FRWHOOP_INFERENCE_HTTP_IDLE_TIMEOUT_S` | 60 | 1–600 | keep-alive / slow-client read timeout |
| `FRWHOOP_REQUEST_TIMEOUT_MS` | 20000 (unchanged) | | `infer` budget |
| `FRWHOOP_INFERENCE_READINESS` | `worker` | `worker` \| `parent` | who computes provider readiness |
| `FRWHOOP_INFERENCE_QUARANTINE_AFTER` | 3 | 0–20 | consecutive overruns before a provider is quarantined (0 = never) |
| `FRWHOOP_INFERENCE_QUARANTINE_SECONDS` | 600 | 10–86400 | quarantine length |

Out-of-range values are clamped. Unset means the default.

## Environment variables (worker)

| Variable | Default | Meaning |
|---|---|---|
| `FRWHOOP_INFERENCE_URL` | unset | unset or empty: the candidate lane and sleep-feature enrichment are off; scoring is byte-identical to the pre-lane worker (no client, no extra SQL) |
| `FRWHOOP_INFERENCE_BUDGET` | 2 | candidate runs (sidecar calls) per scoring drain |
| `FRWHOOP_CANDIDATE_SCHEDULER` | `persisted` | `memory` forces the in-memory pass even when the migration is applied |
| `FRWHOOP_CANDIDATE_MAX_ATTEMPTS` | 4 (1–20) | real attempts a pending item gets before it settles withheld `attempts_exhausted:<reason>` |
| `FRWHOOP_CANDIDATE_REASSEMBLY_BUDGET` | 1 (0–4) | read-only day re-assemblies per drain for pending items whose day is not being scored; 0 = items wait until their day is re-scored |
| `FRWHOOP_CANDIDATE_LEASE_SECONDS` | 300 (60–3600) | pending-item lease |

The drain's wall-clock cap (`CandidateStage.maxDrainSeconds`, 30 s) is unchanged.

## `/healthz` additions

All existing keys are unchanged. Added: `execution` (schema `sidecar-execution/1`):

```
execution: {
  schema, limits: {math_threads, http: {threads, backlog, idle_timeout_s}, sleep_features_budget_ms,
                   quarantine: {after_timeouts, seconds}},
  http: {threads, busy, ...},                     # handler pool state
  provider_readiness: {source, reported_at_utc, disagreements: [{at_utc, providers: {id:
                       {adopted_ready, reported_ready, reported_reason}}}]},
  quarantine: {<provider_id>: {consecutive_timeouts, quarantined, until_utc, quarantines}},
  lanes: { infer | sleep_features: {
    capacity, ready, idle, active, starting, stopping, waiting, max_waiting,
    queue_wait_ms, start_wait_ms, kill_grace_ms, budget_ms, started, closed,
    counters: {...}, last_start_error, last_exit,
    workers: [{index, state, pid, jobs, started_at_utc, ready_at_utc, startup_ms,
               rss_kb_at_ready, framework_threads}] } }
}
```

`active <= capacity` always holds; `waiting <= max_waiting`.

## Busy contract

- Sidecar: HTTP 429, body `{"status":"error","error":{"code":"busy","message":...,"lane":"infer"|"sleep_features"|"http","retry_after_s":N}}`, header `Retry-After: N` (N >= 1).
- Worker `InferenceClient`: 429 with code `busy` -> `InferenceClientError.busy("retry_after_s=N ...")`,
  description prefix `inference_busy`, transient, `retryAfterSeconds` parsed from it. Every exhaustive
  switch handles it. A 429 without code `busy` stays `non200` (`provider_error`).
- Candidate stage: never recorded. The item stays pending with reason `busy`, due again after
  `Retry-After`, the attempt is not counted, and the drain makes no further sidecar call.
  In-memory path: nothing is written and the drain stops calling.
- Sleep-feature enrichment: busy is not a result. The core snapshot is published as before and
  carries the day's newest published `daily.sleep_features` over unchanged
  (`SleepFeatureEnrichment.loadPublishedDocument`, same device and algorithm, read inside the v2
  transaction). A day with no published document publishes without the key, exactly as with the
  sidecar off. Leaving the key out on a day that has a document is not an option:
  `publish_scoring_snapshot_v2` stores a new full payload per revision, so an omitted key erases the
  old value. The next ordinary scoring pass of the day asks again. No extra pass is scheduled: a
  re-enqueue would bump the input revision (superseding candidate work) and, under sustained busy,
  repeat whole-day re-scores. Round 2 published a `status: "busy"` document with every block
  withheld `sidecar_busy`; that placeholder is never carried over. The phone decodes it as
  `.unknown` if one was ever published.
- Sensor biomarkers lane: uses the same client; owned by the sensor area.

Compatibility: an old sidecar never answers 429, so a new worker behaves as before. An old worker
treats a 429 as `non200` and records a withheld `provider_error` candidate (the old behaviour for
any non-200); it never retries in a loop.

## Persisted candidate scheduling

### Schema (`public.physiology_candidate_pending`)

Primary key `(user_id, device_id, period_day, metric)`. Columns: `input_revision` (the scoring
input revision; every settle is fenced on it), `provider_id/provider_version/config_version`,
`requested_mode` (`shadow`|`active`), `state` (`pending`|`done`|`withheld`|`superseded`), `attempts`
(real attempts only), `last_reason`, `candidate_id`, `pending_since` (fair order), `next_attempt_at`,
`lease_token/lease_owner/lease_until`, `claimed_at`, `settled_at`. `user_id` cascades from
`auth.users`. One row per day and metric, so the table grows with days x enabled metrics and needs
no pruning job. RLS on, no policy; client roles revoked; service role granted.

### RPCs (service role only; `security definer`, `search_path=''`)

| Function | Returns | Notes |
|---|---|---|
| `physiology_candidate_pending_enqueue(p_user uuid, p_device text, p_day date, p_input_revision bigint, p_entries jsonb)` | integer (rows inserted or re-armed) | entries `[{metric, provider_id, provider_version, config_version, requested_mode, has_input}]`. Same revision + same selection: no change. Newer revision or changed selection: re-armed (attempts 0, lease dropped). Older than the day's current revision: refused (0). `has_input=false` settles withheld `no_input` at once. Deleted owner / foreign device: 0. Malformed: 22023. |
| `physiology_candidate_pending_claim(p_owner text, p_lease_seconds integer)` | jsonb item or NULL | oldest due row under a new lease. Rows whose day has a newer revision are superseded (`stale_input_revision`) inside the call, never returned. An expired unsettled lease counts one attempt (`lease_expired`). |
| `physiology_candidate_pending_settle(p_user, p_device, p_day, p_metric, p_input_revision, p_lease_token, p_outcome, p_reason, p_candidate_id, p_count_attempt, p_retry_after_seconds, p_max_attempts)` | `{"settled":true,"state","attempts","reason"}` or `{"settled":false,"refused":"not_found"\|"stale_input_revision"\|"not_pending"\|"lease_lost"}` | outcomes `done`, `withheld`, `superseded`, `retry`. A refusal changes nothing. `retry` with a counted attempt that reaches `p_max_attempts` settles withheld `attempts_exhausted:<reason>`. |
| `physiology_candidate_pending_stats()` | `{pending, due, leased, oldest_pending_age_s, by_metric, by_reason, withheld_24h, superseded_24h, at}` | heartbeat |
| `physiology_candidate_current_revision(p_user, p_device, p_day)` | bigint or NULL | the same three-step lookup `physiology_record_candidate_result` fences on |
| `physiology_selected_provider(p_user, p_metric)` (replaced, same signature) | jsonb | existing keys unchanged; adds `requested_mode`, `demoted`, `effective_mode`, `mode_reason` |

A client JWT subject is refused (`cross_user_caller`, 22023) by claim and stats, and by the per-user
functions when it is not the owner, as in the other candidate functions.

### Fairness rule

Claim order is `pending_since`, then day, then the metric order
(`hrv, sleep_boundary, sleep_stage, respiration`), then owner. `pending_since` is set when a row
becomes pending and is kept when a newer revision re-arms a row that has not run: one still
pending, or one the claim superseded only because its revision went stale before the re-score's
enqueue arrived. A row that ran (`done`, `withheld`) goes to the back when re-armed. So a metric
the budget skipped keeps its place while the day is re-scored, and the metrics that just ran go
behind it. With budget B and k runnable metrics on a day that is re-scored before every drain, every
metric runs within ceil(k / B) drains (`CandidatePendingSchedulerTests`, the contract's "fair
order" step). Days that are not re-scored are drained on idle scoring drains
(`CandidateStage.drainBacklog`, at most once per 15 s unless the last look made progress: a call,
a final settle or an assembly; re-queuing the head for budget or deadline is not progress), with their
inputs re-assembled read-only by `ScoringCandidateAssembler` (DayScorer's own
`scoreAndBuildPayloads` in a rolled-back REPEATABLE READ transaction, no series, no attestation, no
sleep-feature call, at most `FRWHOOP_CANDIDATE_REASSEMBLY_BUDGET` per drain). Re-assembled inputs
are kept for the next drains (the two most recent days), so a re-assembly that uses up the drain's
cap is followed by a call in the next drain rather than by the same re-assembly again; a stale-debt
answer drops them.

Outcomes per item:

| Outcome | Settlement | Counted attempt |
|---|---|---|
| recorded / already present / fenced by the record RPC | `done` | yes |
| sidecar result withheld or error (deterministic) | `done` (the row is the withheld/error result) | yes |
| no payload for the metric | `withheld no_input` (at enqueue) | no |
| demoted `active` | `withheld <gate reason>` | no |
| payload would not encode | `withheld input_digest_failed` | no |
| client timeout / refused / not_ready, or sidecar `timeout` | `retry <reason>` with backoff 30 s x 2^n (cap 1 h); the last attempt records a withheld row and settles `withheld attempts_exhausted:<reason>` | yes |
| store error, write failure, re-assembly failure | `retry <reason>` (backoff) | yes; bounded by the SQL |
| busy | `retry busy` after `Retry-After` | no |
| sidecar answered `provider_quarantined` (nothing ran) | `retry provider_quarantined` after its `retry_after_s` | no |
| client timeout of an attempt the drain cap cut below the client's full timeout | `retry deadline` (in memory: nothing recorded) | no |
| run budget spent | `retry budget` (due at once, keeps its place) | no |
| drain deadline | `retry deadline` | no |
| needs a re-assembly this drain cannot afford | `retry awaiting_input_assembly` | no |
| stale debt (input arrived after the inputs were sealed) | `retry stale_debt` (30 s) | no |
| owner deleted / device inactive | `superseded owner_not_live` | no |
| selection switched off | `superseded selection_off` | no |
| day has a newer revision | `superseded stale_input_revision` | no |

A settle refused for a lost lease or a stale revision changes nothing; the stage counts it in
`candidate_pending_settle_refused`. The candidate result itself is still written only by
`physiology_record_candidate_result`, with its own input-revision fence, so stale work cannot
overwrite a newer revision in either table.

Without the migration (`to_regprocedure('public.physiology_candidate_pending_claim(text,integer)')`
is NULL; re-probed every 5 minutes, a failed probe is not cached) the stage runs the in-memory pass:
nothing is persisted, metrics run least-recently-run first (a metric moves back only when its call
reached a result, not when it was answered busy), a budget skip is a counter.

**Behaviour change on apply (intended).** Applying `20261008110000` switches a running worker of
this branch from in-memory to persisted scheduling within 5 minutes (the probe's negative cache),
with no flag set. `FRWHOOP_CANDIDATE_SCHEDULER=memory` keeps the in-memory pass. While every metric
is `off` (the shipped default) neither path does anything.

## Active mode visibility

`SelectedProvider.requested` (from `requested_mode`, or derived from `source` on a database without
this migration), `effectiveMode` (`shadow` for every computed mode) and `modeReason`
(`promotion_approval_required` / `promotion_gate_unavailable` for a demotion,
`active_promotion_deferred` for an approved `active`). They appear in:

- `physiology_selected_provider` (new keys above);
- candidate row diagnostics (unchanged: `active_promotion_deferred`);
- heartbeat `meta.inference.candidate.modes.<metric> = {requested, effective, reason, provider_id}`
  and `meta.inference.candidate.skipped_demoted`.

Nothing canonical changes: an `active` result is still recorded only as a candidate row, and the
scoring lane only logs `active hrv substitution deferred`. A validated selection path would need:
a signed promotion approval checked at publish time (not only at selection), a fenced canonical
republish of the day through `publish_scoring_snapshot_v2` at the same input revision, provenance
of the substituted value in the snapshot, and a rollback path. None of that is in this branch.

## Heartbeat additions

Scoring lane counters (only when the candidate lane is on): `candidate_busy`,
`candidate_provider_quarantined`,
`candidate_skipped_demoted`, `candidate_pending_{enqueued,claimed,done,withheld,superseded,retried,settle_refused}`,
`candidate_reassembled`, `candidate_reassembly_failures`, and from the queue stats (read at most
once a minute) `candidate_pending_queue`, `candidate_pending_due`, `candidate_pending_oldest_age_s`.
`meta.inference.candidate` gains `scheduling` (`persisted` | `in_memory` | `unknown`), `busy`,
`skipped_demoted`, `pending` (the stats object) and `modes`. With `FRWHOOP_INFERENCE_URL` unset
`meta.inference` is still JSON null and no counter is added.

## Migration ordering and compatibility

- `20261008110000_physiology_candidate_pending.sql` needs `20261002090000_physiology_candidate_providers.sql`
  (for `physiology_candidate_activation`) and the scoring tables (`scoring_jobs_v2`,
  `scoring_algorithms_v2`, `devices`). It is additive and idempotent (re-applied in the contract run).
  It sorts before `20261008120000_ppg_transport_anchor.sql`, which it does not touch.
- New worker, old database: the probe is false, the in-memory pass runs (round-1 behaviour plus
  least-recently-run order).
- Old worker, new database: the old worker never calls the queue; the extra selection keys are
  ignored by its parser.
- Rolling back the worker leaves pending rows that nothing reads; they are harmless and cascade with
  the owner.
- New worker x old sidecar: no 429 ever arrives. Old worker x new sidecar: 429 is `non200`, recorded
  withheld `provider_error` (bounded, no retry loop).

## Read-only runtime checklist

Run on the Droplet; none of these writes anything.

```
# Sidecar pool state and limits
curl -s http://127.0.0.1:8787/healthz | jq '.execution | {limits, http, lanes: (.lanes | map_values({capacity, active, waiting, idle, starting, counters, workers: [.workers[] | {pid, state, jobs, rss_kb_at_ready}]}))}'
# Process tree and memory of the sidecar unit
systemctl show frwhoop-inference -p MemoryCurrent -p TasksCurrent -p CPUUsageNSec
ps -o pid,ppid,rss,nlwp,etime,args --ppid "$(systemctl show -p MainPID --value frwhoop-inference)"
# Pending queue (psql with a read-only role)
select state, metric, coalesce(last_reason,'new') reason, count(*), min(pending_since)
  from public.physiology_candidate_pending group by 1,2,3 order by 1,2,3;
select public.physiology_candidate_pending_stats();
# Heartbeat counters and modes
select last_poll_at, meta->'inference'->'candidate' from public.scoring_service_heartbeats where id=1;
select meta->'lanes' from public.scoring_service_heartbeats where id=1;   -- scoring lane counters
# Journal lines
journalctl -u frwhoop-worker --since -1h | grep -E 'candidate (pending|inference)|active hrv substitution deferred'
journalctl -u frwhoop-inference --since -1h | grep -E 'frwhoop-inference: (infer|sleep_features) worker pid=.* (ready|stopped)|not reaped'
```

Expected with every metric `off` (the shipped default): `candidate.modes` empty, queue empty,
`scheduling` `persisted` (or `in_memory` before the migration), pool `active` 0.

## Extension points for Specs 02 and 03

- **New candidate metric.** Add it to `CandidateStage.metrics` (order is only a tie-break), give
  `DayScorer.CandidateInputs.input(for:)` its payload, and add it to the metric CHECK lists and the
  `array_position` order in a new migration (`physiology_candidate_pending`, `physiology_candidate_results`,
  the provider tables). The queue, fairness, fences and heartbeat need no other change. A metric
  whose payload cannot be built is enqueued with `has_input=false` and shows as withheld `no_input`.
- **New provider for an existing metric.** Only the selection changes; a changed provider triple at
  the same revision re-arms the row, so the new provider runs for days already done.
- **Input assembly.** Pending items for a day that is not being scored get inputs from
  `ScoringCandidateAssembler`, which calls `DayScorer.scoreAndBuildPayloads(..., candidateLane: true)`.
  New inputs added to `buildCandidateInputs` are therefore available to re-assembled items too.
- **Sleep features (Spec 02).** Computation added to `/v1/sleep-features` runs in the
  `sleep_features` lane's process with the same budget and isolation. Knobs:
  `FRWHOOP_SLEEP_FEATURES_BUDGET_MS`, `FRWHOOP_SLEEP_FEATURES_MAX_ACTIVE`,
  `FRWHOOP_SLEEP_FEATURES_MAX_WAITING`, `FRWHOOP_SLEEP_FEATURES_QUEUE_WAIT_MS`. Keep the worker's
  transport budget (`FRWHOOP_SLEEP_FEATURES_TIMEOUT_MS`, `SleepFeatureEnrichment.swift`) above the
  compute budget. Heavy new imports belong in the worker process's warm-up, not per request.

## Defects fixed in round 2

1. The SQL the scheduler called did not exist (no migration). Written, with a contract test.
2. The scheduler was never wired: `ScoringLane` did not create the pending store, never drained the
   backlog and never passed an assembler, so the persisted path was unreachable and budget-skipped
   metrics of days that were not re-scored still starved. Wired (`ScoringLane.drain`,
   `ScoringCandidateAssembler`, `main.swift` candidate block).
3. A failed presence probe (database briefly unreachable) was cached as "migration absent" for
   5 minutes, silently switching to in-memory scheduling. Now only a real answer is cached.
4. A row whose worker died mid-run (expired lease) was re-run without bound. The claim now counts it
   and the stage settles it withheld `attempts_exhausted:lease_expired` at the bound.
5. With re-assembly off, an item awaiting assembly was re-claimed on every idle drain; it now waits
   5 minutes.
6. Sidecar: the `terminations` counter missed overruns whose process exited on the first SIGTERM
   before the supervisor looked (`execution.py`).

## Verification record (round 2)

All runs on this machine, 2026-10-08, against throwaway local state only.

- SQL contract: throwaway cluster from `_build-scratch/spec01/runtime/scripts/pg_bootstrap.sh`
  (PostgreSQL 18.3 on 127.0.0.1:55531, Supabase role/auth stand-ins, the candidate lane's prerequisite
  migrations, `20261002090000`, `20261008110000`), then
  `psql -X -qAt -v ON_ERROR_STOP=1 -f supabase/functions/tests/physiology_candidate_pending_contract.sql`:
  9/9 steps ok (security, enqueue, fair order, leases, stale revision, attempts, stats, caller
  isolation, selection modes). The migration re-applies cleanly. Two mutants (no place kept on
  re-arm; expired lease accepted) each fail the contract at the expected step.
- Worker (Xcode 26.3 toolchain, `xcrun swift test --filter` with `FRWHOOP_TEST_DB_URL` at that
  cluster): `CandidatePendingSchedulerTests` 13, `CandidatePendingDatabaseTests` 2 (ran, not skipped),
  `CandidateStageTests` 46, `InferenceClientTests` 30, `SleepFeatureEnrichmentTests` 17,
  `DayScoringCandidateInputTests` 26: 134 tests, 0 failures.
- Worker full suite (same DB URL): 700 tests, 59 skipped, 18 failures (6 test cases), none in this
  area: `ActivityElderNetStageTests` (3) and `ActivityInertiaStageTests` (2) (activity cache /
  child args), and `SensorBiomarkerInputsDatabaseTests.testObjectResolutionSQLFindsOnlyVerifiedIndexedDayObjects`,
  which needs `object_manifests.durability_receipt` from a migration this scratch cluster does not apply.
- Sidecar full suite (`uv run --frozen pytest -q -o addopts=""`, load average 300-900 throughout):
  582 passed, 8 failed, 44 skipped in 59 min. Re-run alone: `tests/test_execution.py` 16/16 after the
  fixes below; `test_worker_envelope_http.py` and `test_committed_fixture_pair_round_trips_over_real_http`
  pass; `test_full_night_fixture_reproduces_the_committed_response_within_budget` (a 0.75 s wall-clock
  assertion, features area) failed at 1.30 s, as it did at round 1's baseline; the three
  `test_provisioning.py` probe tests exceed even a 580 s timeout here (their child builds the full
  registry, 72 s in-process at this load) and passed in the parent's integration run.
  Two sidecar fixes from this run: `terminations` is now counted where SIGTERM is sent
  (`_begin_stop`), because the supervisor often found the process already gone and missed it
  (`test_repeated_timeouts_never_grow_processes_or_threads`: 3 != 5); and the lane-independence test
  gets a 10 s infer budget instead of 300 ms (it measured the host, not the lanes).
- Not verified: `ScoringCandidateAssembler` against a real database (needs the full scoring schema
  and stream data); anything on the Droplet (no access was used).

## Review fixes (round 3)

| Item | Fix | Test |
|---|---|---|
| 4 deadline-cut timeout became `attempts_exhausted:timeout` | cut attempt's timeout settles `retry deadline` uncounted; in memory nothing is recorded | `testADeadlineCutTimeoutIsNeverCountedAsAnAttempt`, `testStalledSidecarIsCappedByTheDrainDeadline` |
| 8 idle drains could repeat a whole-day re-assembly forever | assemblies kept across drains; throttle skipped only after progress | `testASlowReassemblyIsKeptForTheNextDrain`, `testAnIdleDrainWithoutProgressKeepsTheThrottle` |
| 9 one always-overrunning provider kept the shared worker restarting | per-provider consecutive-timeout quarantine in the sidecar; worker treats it as not an attempt | `test_an_always_overrunning_provider_is_quarantined_and_others_keep_running` (real processes), `testAQuarantinedProviderAnswerIsNotAnAttempt` |
| 6 busy replaced a good sleep_features document with a blank | carry the published document over, or omit the key | `testBusyKeepsThePublishedDocumentOrOmitsTheKey`, `testLoadPublishedDocumentReadsTheNewestSnapshotsSleepFeatures` |
| 11 a dead worker's loaded identity stayed in /healthz | report kept with its pid, served only while that pid is a live lane worker | `test_a_dead_workers_loaded_identity_is_not_reported` |
| 12 a replacement's differing readiness was ignored silently | logged and listed in `provider_readiness.disagreements` | `test_worker_reported_readiness_is_adopted_once` |
| 15 re-arm after a stale-revision supersede went to the back | keeps `pending_since` | contract "stale revision" step |
| 16 in-memory busy metric lost its turn | `lastRunAt` set only after a result | `testABusyMetricKeepsItsTurnInTheInMemoryOrder` |

Also: the `terminations` counter is taken before the supervisor is woken (an earlier fix could count
one stop twice).

Round 3 runs (2026-10-08, load average 300-900): contract SQL 9/9 on a fresh throwaway cluster
(plus a mutant without the item-15 rule failing at the new step); worker
`--filter "CandidatePendingSchedulerTests|CandidatePendingDatabaseTests|CandidateStageTests|InferenceClientTests|SleepFeatureEnrichmentTests|DayScoringCandidateInputTests"`
with `FRWHOOP_TEST_DB_URL`: 141 tests, 0 failures, 0 skipped; sidecar `tests/test_execution.py` 20 passed;
`tests/test_server.py tests/test_identity.py tests/test_contract.py` 97 passed.

## Requests to parent

- `deploy/inference.env.example` / sidecar unit: document the sidecar variables above (defaults need
  no change). If `FRWHOOP_INFERENCE_MAX_ACTIVE` is ever raised to 2, raise `MemoryHigh` by the
  measured per-process RSS first.
- `deploy/worker.env.example`: `FRWHOOP_CANDIDATE_SCHEDULER`, `FRWHOOP_CANDIDATE_MAX_ATTEMPTS`,
  `FRWHOOP_CANDIDATE_REASSEMBLY_BUDGET`, `FRWHOOP_CANDIDATE_LEASE_SECONDS` (all optional).
- README "Inventory and checklist": link this page's checklist.
- Apply `20261008110000` before (or with) the worker build that contains this branch; either order is
  safe.
