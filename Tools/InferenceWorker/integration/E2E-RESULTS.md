# FRWHOOP physiology migration — end-to-end integration results (impl-e2e)

Worker: `impl-e2e` (child of the FRWHOOP physiology migration parent). Date: 2026-10-02.
Worktree: `/Volumes/External SSD/Nara Whoop App V2/noop-physiology` (branch
`feat/server-physiology-models-20261001`, base `59f0415a`). Nothing committed, no push.
No subagent, no production DB, no cloud, no network, no model download.

## 1. What was built (owned paths only)

| Path | Purpose |
| --- | --- |
| `Tools/InferenceWorker/scripts/lib_e2e.sh` | Shared helpers: assertion/evidence counters, disposable unix-socket PostgreSQL, loopback sidecar lifecycle, HTTP helpers |
| `Tools/InferenceWorker/scripts/e2e_sidecar_http.sh` | Sidecar HTTP contract, loopback-only, per-provider readiness, blocked-artifact gate |
| `Tools/InferenceWorker/scripts/e2e_candidate_roundtrip.sh` | The real loop: seeded stream rows → sidecar inference → the worker's own RPC text → a real candidate row |
| `Tools/InferenceWorker/scripts/swift_record_call.py` | Extracts `PhysiologyCandidateSQL.recordCandidate` **verbatim** from the Swift source, enforces its contract checks, reproduces the Swift parameter encoding, and binds it |
| `Tools/InferenceWorker/scripts/build_hrv_request.py` | Mirrors `DayScorer.hrvInput`/`CandidateStage.runOne` so the sidecar receives the worker's real payload shape |
| `Tools/InferenceWorker/scripts/build_sleep_stage_request.py` | Builds a real `sleep_stage` request from the project's own `tests/sleep_fixtures.py` |
| `Tools/InferenceWorker/scripts/materialize_model_root.py` | Materializes the sleep-staging artifact root from the **installed wheel** (mirrors the `sleep_model_root` pytest fixture) |
| `Tools/InferenceWorker/integration/E2E-RESULTS.md` | This file |

## 2. Commands and results

```sh
cd '/Volumes/External SSD/Nara Whoop App V2/noop-physiology/Tools/InferenceWorker'
bash scripts/e2e_sidecar_http.sh          # exit 0
bash scripts/e2e_candidate_roundtrip.sh   # exit 0
```

| Run | Result | Transcript |
| --- | --- | --- |
| `e2e_sidecar_http.sh` | **61 passed, 0 failed, 0 skipped**, exit 0 | `/tmp/frwhoop-physiology/sc-run4.out` (run dir `e2e/sidecar-http-*`) |
| `e2e_candidate_roundtrip.sh` | **81 passed, 0 failed, 0 skipped**, exit 0 | `/tmp/frwhoop-physiology/e2e-roundtrip-run2.txt` (run dir `e2e/candidate-roundtrip-48912`) |

Counts were 62 assertions before the S-1 repair; section H (below) adds 19, and the
pre-repair run recorded 80 passed / 1 failed only because one new assertion compared
`20` to jq's `20.0` text — the value assertion itself passed in both runs.

Both scripts are rerunnable. They allocate a fresh run directory under
`$E2E_ROOT` (default `/tmp/frwhoop-physiology/e2e`, always outside the checkout),
keep every artifact there, and print `PASS`/`FAIL` per assertion.

### 2.1 Safety properties observed in the runs

* The disposable cluster binds **no TCP port**: `listen_addresses=''` plus a
  private Unix socket (`-k <run-dir>/pg`), asserted by `show listen_addresses` = `''`.
* The reserved ports `54321/54322/54323/55432` and the unit's default `8787` were
  never bound. The sidecar took an **ephemeral** loopback port and `lsof` shows the
  listening socket on `127.0.0.1:<port>` only.
* No artifact was downloaded: the sleep checkpoint was copied from the already
  installed `sleepecg` wheel and both sha256 digests were verified against
  `models/manifest.json` before use.
* The only environment variables used are the ones the scripts set; no credential
  is read.

## 3. The real loop, and the honest scope of the Swift leg

The round-trip run executes this chain:

```
noop_hr_samples + noop_rr_intervals (seeded, 90 RR rows)
  -> GET /healthz (ready=true, artifacts verified)
  -> POST /v1/infer  with the payload DayScorer.hrvInput assembles
       (rmssd_ms = 7.1743926650525305, unit ms, valid_pairs = 89, sha256 = ff3dfff2...)
  -> physiology_record_candidate_result bound with the SQL text extracted from
       Tools/CloudWorker/Sources/frwhoop-worker/CandidateStage.swift
  -> row 953205c2-a0bc-46fd-b29e-4e1b8dac44d5 in public.physiology_candidate_results
```

**The Swift leg is a build + SQL-level binding, not an in-process Swift test.**
Concretely:

* `swift build` compiles the worker from this worktree, so the statement text and
  the parameter encoder under test are the compiled ones.
* `swift test --filter 'CandidateStageTests|InferenceClientTests|DayScoringCandidateInputTests'`
  runs the worker's candidate suites against a stub sidecar and a protocol-level
  fake store: **Executed 83 tests, with 0 failures**.
* The RPC itself is then bound **from SQL** by the script, using the worker's own
  statement text (extracted at run time, so drift cannot go unnoticed) and its own
  NULL encoding (absent = `''` → `nullif` → SQL NULL).

Why not an in-process Swift test: `Tools/CloudWorker/**` is owned by another worker
and the CloudWorker test target cannot be extended from this worker's owned paths
(`Tools/InferenceWorker/**`). The residual unproven hop is therefore exactly
`PostgresClient` → `PQexecParams` (the C-string binding of the 23 parameters) plus
deployed Supabase behaviour. Everything on either side of that hop is asserted here:
the encoded string vector (checks in section 4.2) and the migration's real
parameter list (assertion A0 below).

## 4. Assertion-by-assertion evidence

### 4.1 `scripts/e2e_sidecar_http.sh` — 61 passed / 0 failed

**0. materialize the sleep-staging artifact root from the installed wheel**

- `PASS  the empty artifact root is really empty`

**1. sidecar on 127.0.0.1, ephemeral port, EMPTY artifact root**

- `PASS  ephemeral port (not 8787, not a Supabase port)`
- `PASS  sidecar avoided every reserved port (54321 54322 54323 55432 8787)`
- `PASS  the listening socket is bound to 127.0.0.1 only`
- `PASS  GET /healthz is 200`
- `PASS  process readiness is false while the checkpoint is missing`
- `PASS  manifest.ok is false`
- `PASS  the manifest reason names the missing entry`
- `PASS  provider production.runs.v1 is ready (no model bytes needed)`
- `PASS  provider production.runs.v1 reports no reason`
- `PASS  provider production.runs.v1 reports a version`
- `PASS  provider neurokit2.shadow.v1 is ready (no model bytes needed)`
- `PASS  provider neurokit2.shadow.v1 reports no reason`
- `PASS  provider neurokit2.shadow.v1 reports a version`
- `PASS  provider hypnospy.hr-boundary.v1 is ready (no model bytes needed)`
- `PASS  provider hypnospy.hr-boundary.v1 reports no reason`
- `PASS  provider hypnospy.hr-boundary.v1 reports a version`
- `PASS  sleepecg.wrn-gru-mesa.v1 is NOT ready`
- `PASS  its reason is blocked_artifact`
- `PASS  the failed check is reported as missing`
- `PASS  GET /v1/providers is 200`
- `PASS  capability listing carries all four wired providers`
- `PASS  the recorded (unwired) models are listed with their status`

**2. POST /v1/infer hrv with the WORKER payload shape (empty root: HRV is unaffected)**

- `PASS  hrv infer is 200`
- `PASS  hrv status is ok`
- `PASS  hrv provider is production.runs.v1`
- `PASS  hrv unit is ms`
- `PASS  hrv value is a finite number`
- `PASS  hrv input sha256 is 64 hex chars`
- `PASS  hrv coverage reports the valid pair count (89 of 90 beats)`
- `PASS  hrv production dependency version is the pinned numeric stack`
- `PASS  hrv adapter version is reported`
- `PASS  hrv preprocessing version is reported`
- `PASS  hrv model version is null (no model bytes for this provider)`
- `PASS  hrv runtime_ms is an integer`
- `PASS  the process-level readiness flag is still false`
- `PASS  the HRV request was counted`

**2b. the gated comparison provider (neurokit2) is reachable and never publishable**

- `PASS  neurokit2 infer is 200`
- `PASS  provider id is neurokit2.shadow.v1`
- `PASS  the shadow provider can never publish`
- `PASS  it is labelled unverified_accuracy`
- `PASS  its dependency version is the pinned neurokit2`

**3. sleep_stage with an EMPTY artifact root is refused with blocked_artifact**

- `PASS  sleep_stage is refused with 503 while the checkpoint is missing`
- `PASS  the error code is provider_not_ready`
- `PASS  the refusal names blocked_artifact`

**4. sidecar with the POPULATED artifact root: sleep_stage is served**

- `PASS  healthz is 200`
- `PASS  manifest.ok is true`
- `PASS  process readiness is true`
- `PASS  every provider is ready`
- `PASS  the staging provider reports no reason`
- `PASS  sleep_stage infer is 200`
- `PASS  sleep_stage status is ok`
- `PASS  sleep_stage provider id`
- `PASS  label space is the three-class space`
- `PASS  the stage array is non-empty`
- `PASS  every stage label is inside the declared label space`
- `PASS  the uncalibrated scores are not labelled calibrated`
- `PASS  the stage provider is not publishable`
- `PASS  its accuracy label is unverified_accuracy`

**5. non-loopback bind is refused**

- `PASS  the CLI exits 2 for a non-loopback host`
- `PASS  and says loopback only`

### 4.2 `scripts/e2e_candidate_roundtrip.sh` — 81 passed / 0 failed

**A. Swift leg: build the worker from THIS worktree and run its candidate suites**

- `PASS  swift build of the worker from the worktree (log: swift-build.log)`
- `PASS  the candidate suites ran and reported 0 failures`

**A0. the Swift statement text and the migration's parameter list agree**

- `PASS  the extracted Swift statement satisfies its own contract checks`
- `PASS  the statement has 23 distinct placeholders`
- `PASS  nullif covers $16..$23 but never the jsonb object $15`

**B. disposable PostgreSQL: unix socket only, never a TCP port**

- `PASS  listen_addresses is empty, so no TCP port is bound`
- `PASS  the cluster socket exists in the run directory`
- `PASS  the socket path is inside the run dir (outside the checkout)`

**C. apply the curated prerequisite subset + the candidate migration**

- `PASS  12 prerequisite migrations + 20261002090000_physiology_candidate_providers.sql applied`
- `PASS  the candidate migration re-applies cleanly (idempotent)`
- `PASS  all four metrics are seeded off`
- `PASS  every candidate table has RLS enabled`
- `PASS  no policy exists on the candidate tables (service-role only)`
- `PASS  authenticated cannot execute the record RPC`
- `PASS  the migration's 23 parameters are named and ordered as the Swift list`

**D. seed a synthetic day (HR rows + RR rows) and open the hrv lane**

- `PASS  60 HR rows seeded`
- `PASS  90 RR rows seeded`
- `PASS  no candidate debt while every metric is off (dormancy gate)`
- `PASS  the unconfigured metric resolves to mode=off`
- `PASS  hrv now selects the shadow provider`
- `PASS  a new stream insert now records candidate debt (trigger family fires)`
- `PASS  the debt read RPC reports it`
- `PASS  the day has a current input revision`

**E. the sidecar serves the seeded night (real inference on DB rows)**

- `PASS  the sidecar is fully ready (every provider, artifacts verified)`
- `PASS  the request is built from the DB's own RR rows`
- `PASS  the sidecar answers 200`
- `PASS  status is ok`
- `PASS  provider is production.runs.v1`
- `PASS  the RMSSD value is finite`
- `PASS  the response carries the input sha256 the worker records`

**F. bind the RPC with the EXACT SQL text from CandidateStage.swift**

- `PASS  the bound statement nullif's exactly the three absent optionals ('' -> NULL)`
- `PASS  p_dependency_versions is passed as a jsonb object, never ''`
- `PASS  the RPC returned a candidate_id (a real row was written)`
- `PASS  exactly one candidate row exists`
- `PASS  the stored envelope is exactly the sidecar's answer + the selected triple`
- `PASS  the interval is the sidecar's interval`
- `PASS  dependency_versions keeps the provider's dependency/model versions`
- `PASS  coverage is stored as the sidecar's coverage object`
- `PASS  diagnostics record the mode, transport and row counts`
- `PASS  the canonical lane is untouched: the candidate write changed no canonical row`

**G1. replay is idempotent (ON CONFLICT DO NOTHING)**

- `PASS  the identical call returns NULL (nothing new written)`
- `PASS  and the row count is unchanged`

**G2. a stale input revision is refused by the guard**

- `PASS  the newer generation really is newer`
- `PASS  a claim from the superseded generation is refused (NULL)`
- `PASS  and nothing was written`
- `PASS  the same claim at the CURRENT revision is accepted`
- `PASS  so the stale refusal above was the guard, not the uniqueness key`

**G3. a provider generation that is no longer selected is refused**

- `PASS  a moved provider_version is refused (NULL)`
- `PASS  and nothing was written`

**G4. mode=off is a total no-op for the lane**

- `PASS  the metric now resolves to off`
- `PASS  an off-mode write is refused (NULL)`
- `PASS  and nothing was written`
- `PASS  the lane is back on shadow`

**G5. a withheld result persists with its contract fields**

- `PASS  the withheld candidate is recorded`
- `PASS  it stores null value + the machine-readable reason`
- `PASS  row count is now 3`

**G6. malformed shapes raise 22023 and write nothing**

- `PASS  an ok result with neither value nor stages is rejected`
- `PASS  and nothing was written`
- `PASS  an hrv value of 5000 ms is rejected by the metric bounds`
- `PASS  and nothing was written`

**G7. ownership: another device cannot be written to**

- `PASS  a device the user does not own is refused (NULL)`
- `PASS  row count is still 3`

**H. multi-window night (audit S-1): the candidate value is the session mean**

- `PASS  6480 night beats seeded`
- `PASS  the night has a current input revision`
- `PASS  the night request is built from every seeded night beat`
- `PASS  the worker payload states its intent ONLY in input.config`
- `PASS  and sends NO top-level input.aggregation (the pre-repair worker shape)`
- `PASS  the sidecar answers 200`
- `PASS  status is ok`
- `PASS  the parser mirrored input.config and took the session aggregation`
- `PASS  all 108 windows were scored`
- `PASS  and the interval really is a 108-window night`
- `PASS  the first window's OWN RMSSD is the 20 ms the pre-repair code returned`
- `PASS  the sidecar value equals the independent session mean over windows` (59.44444444444444)
- `PASS  and it is NOT the first window's value (S-1 regression guard)`
- `PASS  the multi-window candidate is recorded`
- `PASS  the RECORDED candidate value equals the session mean over windows`
- `PASS  and the recorded value is not the first window's 20 ms`
- `PASS  the recorded interval is the night the beats describe`
- `PASS  the stored coverage reports all 108 windows usable`
- `PASS  the night row is stored ok with a value`

The expectation (59.44444444444444 ms) is computed in the script from the fixture's own
arithmetic — every window's RR alternates `+a`/`-a`, so its RMSSD is exactly `2a`, and
`a = 10 + (window % 5) * 10` — never from the provider's aggregation. The 108-window
night is seeded as 60 beats per window (one per second for the first 60 s of it) rather
than 300: the first full-density attempt (32,400 rows) passed every assertion but made
the statement-level invalidation triggers spend minutes on one INSERT, which is a bad
trade for an e2e script. Window count, per-window floor clearance and the analytic
expectation are unchanged.

**I. scope statement (what this run does and does not prove)**


### 4.3 The bound statement (extracted from `CandidateStage.swift`, verbatim)

`scripts/swift_record_call.py --dump` reports
`{"placeholder_count": 23, "missing": [], "extra": [], "nullif_params": [16,17,18,19,20,21,22,23]}`,
i.e. `$1..$23` present, `$16..$23` nullif'd, and `$15` (`p_dependency_versions`) deliberately
**not** nullif'd. The generated call for the ok record (`call-ok.sql`) is:

```sql
select coalesce((select public.physiology_record_candidate_result(
                 '11111111-1111-4111-8111-111111111111'::uuid, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::text, 'hrv'::text, '2026-09-30'::date,
                 '2026-09-30T20:25:40Z'::timestamptz, '2026-09-30T20:29:09Z'::timestamptz,
                 'ff3dfff215bd6b48d1b327f9396c7916d122e59cc1a567177375f17ec80475b3'::text, '4'::bigint,
                 'production.runs.v1'::text, '1.0.0'::text, 'frwhoop-inference.adapter/1.0.0'::text, 'hrv.preprocess.production.runs.v1'::text, 'cfg-1'::text,
                 'ok'::text,
                 '{"dependency":"numpy==2.5.3"}'::jsonb,
                 nullif(''::text,''),
                 nullif('7.1743926650525305'::text,'')::numeric,
                 nullif('ms'::text,''),
                 nullif(''::text,'')::jsonb,
                 nullif(''::text,''),
                 nullif('{"clean_beat_ms":72801.0,...}'::text,'')::jsonb,
                 nullif('{"attempts":1,"client_elapsed_ms":0,...}'::text,'')::jsonb,
                 nullif('0'::text,'')::integer
               )::text), 'null') as candidate_id;
```

Three absent optionals (`$16 withheld_reason`, `$19 stages`, `$20 label_space`) become
`''` and are turned into SQL NULL by `nullif`, which is exactly what
`PhysiologyCandidateSQL.recordCandidateParameters` produces for a record with no
withheld reason and no stage payload.

### 4.4 Independent cross-checks worth keeping

1. **Signature agreement (A0/C).** The migration's 23 parameter names, in order, equal
   the order `PhysiologyCandidateSQL.recordCandidateParameters` encodes. This is the
   check that catches the F2-class drift the review ledgers flagged.
2. **Guard vs uniqueness (G2).** The stale-revision refusal is proven with a *different*
   `input_sha256`, and the same row is then accepted at the current revision — so the
   refusal is the revision guard, not the UNIQUE key.
3. **Dormancy (D).** With every metric `off`, a real stream insert records **zero**
   candidate debt; after `hrv` is set to `shadow`, the same insert records debt and
   `physiology_candidate_debt_read` reports `debt: true`.
4. **Envelope fidelity (F).** Every stored field (value, unit, triple, adapter and
   preprocessing versions, input sha256, runtime, coverage, dependency versions,
   diagnostics) equals the sidecar's own answer.

## 5. Integration seams and observations (not blockers)

1. **`input.window` is ignored; `input.config.aggregation` is MIRRORED (audit S-1, repaired).**
   `contract.parse_hrv_input` reads `input.beats`, optional `input.windows` and
   `input.aggregation`. The worker sends `input.window` (`start_sec`/`end_sec`), which is
   accepted and ignored; the window is still honoured because `CandidateStage.runOne`
   sets `context.interval_start_utc`/`interval_end_utc` from the same
   `CandidateInputs.intervalStart/End`, and the provider derives its windows from the
   context interval — the run above proves that path end to end.

   `input.config.aggregation` is no longer ignored. The pre-repair parser read neither
   the config copy nor a top-level key, defaulted to `window` and scored `outcomes[0]`,
   so the candidate HRV value was the **FIRST 5-minute window's** RMSSD while
   `coverage` described the whole night (audit S-1, P1). `contract._resolve_hrv_aggregation`
   now reads a top-level `input.aggregation` first and mirrors `input.config.aggregation`
   when the top-level key is absent, so a worker that states `mean_over_windows` only in
   its config — the shape `scripts/build_hrv_request.py` reproduces and section H drives —
   gets the session mean over usable windows. A withheld or floor-refused window
   (including the first one) no longer withholds the night (audit S-2). Section H is the
   regression test: it asserts the RECORDED value equals an independently computed
   session mean (59.44 ms) and not the first window's 20 ms.

   `input.aggregation` now accepts `window | mean_over_windows | session | day`
   (`session` is the legacy alias for `mean_over_windows`); an unknown spelling is
   refused with 400 `invalid_input` instead of being silently downgraded to `window`.
2. **`versions.dependency` differs per provider by design**: `production.runs.v1` reports
   `numpy==2.5.3` (the numeric stack it actually uses) and `neurokit2.shadow.v1` reports
   `neurokit2==0.2.13`. The manifest pins both.
3. **`runtime_ms` can be 0** for a 90-beat HRV window on this machine; the stored
   `runtime_ms` is therefore 0 and `diagnostics.client_elapsed_ms` is 0. The RPC accepts
   `p_runtime_ms = 0` (`p_runtime_ms < 0` raises), so this is valid, not a defect.
4. **`physiology_record_candidate_result` requires the SELECTED triple.** The stored
   `provider_version` is the selection's (`1.0.0`), never the response's echo, matching
   `CandidateStage`'s documented rule. G3 proves a moved generation is refused.

### 5.1 Recorded divergences and fail-closed repairs (audit S-3/S-4/S-5, DD-4)

**Spec section 5 thresholds vs the shipped code (S-3/S-4).** The spec's provisional
numbers are NOT implemented, because the shipped Swift code does not implement them and
this port is faithful to the shipped code. Recorded here, and in the provider module
docstring and `README.md`, so no reader assumes otherwise:

| Spec section 5 (provisional) | Shipped code / this port | Evidence |
| --- | --- | --- |
| minimum 30 clean intervals | `min_clean_beats = 20` | `HRVAnalyzer.swift:33` (`minBeats = 20`) |
| maximum 20 % artifact fraction | no nightly gate (`max_rejected_fraction = None`, `min_coverage = 0.0`) | `HRVAnalyzer.swift` has no such constant |
| minimum 3 usable windows | no floor; a one-window session is scored | `SleepStager.swift:2958-2973` |
| median-window aggregation | plain mean over windows | `SleepStager.sessionAvgHRV` |

Consequence recorded rather than implied: `low_coverage` and `high_rejected_fraction`
fire only when a caller tunes `min_coverage` / `max_rejected_fraction` away from their
shipped defaults, so `artifact_fraction` is reachable today only through the over-count
path. The aggregation seam itself is described in `README.md` and in
`scripts/build_hrv_request.py` (S-5).

**Artifact readiness fails closed on a missing digest (DD-4, package half).**
`ArtifactCheck.failed` now includes `no_sha256`, so a manifest entry that is marked
`verify_at_startup` but publishes no `sha256` FAILS readiness when its entry is
`required_for_readiness`, and is surfaced as a failed optional check otherwise.
`not_verified` (`verify_at_startup: false`) stays non-blocking by design. The deploy
half of DD-4 (`provision.sh` aborting instead of printing `SKIP`) belongs to the deploy
owner and is not touched here.

## 6. Blockers

None. Both scripts run to completion with exit 0 on this machine.

Unverified by design (not blockers, and not claimed anywhere above):

* the `PostgresClient` → `PQexecParams` transport hop itself (no in-process Swift test
  against Postgres is possible from this worker's owned paths);
* deployed Supabase version behaviour, RLS enforcement against a real PostgREST, and
  anything requiring the Droplet;
* provider accuracy (spec section 8 keeps accuracy separate from integration success);
* production defaults — all four metrics remain `off` in the migration's seed, and this
  run never changed a default outside its own disposable cluster.
