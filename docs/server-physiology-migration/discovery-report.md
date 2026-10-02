# Discovery report — FRWHOOP server-side physiology migration

Status: discovery/reference document for branch `feat/server-physiology-models-20261001`
(base `59f0415a`). Evidence-only: every claim below cites a findings file or a repo file:line.

Method: read-only inspection of the worktree
`/Volumes/External SSD/Nara Whoop App V2/noop-physiology` and of the findings set in
`/tmp/frwhoop-physiology/findings/`. **No Droplet, database, B2 bucket or production
credential was accessed.** Anything that would require the host or the live database is
marked UNVERIFIED and is also listed in section 6.

---

## 1. The deployed stack

### 1.1 Repository, branch, base SHA

| Item | Value | Evidence |
| --- | --- | --- |
| Deployed repo (local checkout) | `/Volumes/External SSD/Nara Whoop App V2/noop` | parent-notes.md §Baseline |
| Remotes | `origin=github.com/Rahulvijayan123/noop.git`, `nara=github.com/Rahulvijayan123/Nara-App.git` | parent-notes.md §Baseline |
| Product branch | `nara-main` @ `59f0415a` | parent-notes.md §Baseline |
| Migration branch | `feat/server-physiology-models-20261001` @ `59f0415a` (worktree `noop-physiology`) | `git rev-parse HEAD` in the worktree; findings/validation-fixtures.md §0 |
| Branch delta vs base | no commits; only untracked new files (spec, package, migration, worker client, deploy files) | findings/validation-fixtures.md §0; `git status --porcelain` in the worktree |
| Main checkout state | 37 changed paths of unrelated in-flight work, preserved and untouched | findings/validation-fixtures.md §0 |
| Not the deployed product | `Whoop-Nara` is a separate older checkout (detached `9abbcf22`) | parent-notes.md §Baseline |

The branch carries no commits: `59f0415a44976b5887076ac3e9d42f735eda878e` is both the base
and the current HEAD of the migration worktree (`git rev-parse HEAD` in the worktree;
findings/validation-fixtures.md §0).

### 1.2 Droplet and systemd service

| Item | Value | Evidence |
| --- | --- | --- |
| Droplet | `frwhoop-worker-2`, sfo3, 4 vCPU / 8 GB, Ubuntu 24.04, IPv6 | `deploy/README.md:7` |
| Public IPv4 | `143.198.62.4` documented in the repo | `deploy/OPERATIONS.md:3` — repo-documented, NOT verified on the host |
| Service | `frwhoop-worker.service` (user `frwhoop`, `ProtectHome=true`, `HOME=/var/lib/frwhoop`) | `deploy/README.md:8-10`, `deploy/frwhoop-worker.service:11-13,29-30` |
| Code path | `/opt/noop`; release binary `Tools/CloudWorker/.build/release/frwhoop-worker` | `deploy/README.md:11`, `deploy/frwhoop-worker.service:17` |
| Secrets | `/etc/frwhoop/worker.env` (0600 root) + `/etc/frwhoop/supabase-ca-chain.pem` (0644) | `deploy/README.md:11`, `deploy/frwhoop-worker.service:11` |
| DB TLS | `sslmode=verify-full` against the pinned Supabase CA; plaintext refused unless `FRWHOOP_ALLOW_INSECURE_DB=1` | `PostgresClient.swift:54-61`, `deploy/README.md:12-13` |
| Restart policy | `Restart=always`, `RestartSec=5`, `KillSignal=SIGTERM`, `TimeoutStopSec=90` | `deploy/frwhoop-worker.service:18-19,24-25` |
| Resource limits on the worker | none set (no `CPUQuota`/`MemoryMax`/`TasksMax`) | findings/deployment-do.md §a5 |
| Listening sockets | none: the worker is outbound-only and links no HTTP server | findings/deployment-do.md §0.1, §a6 |
| Production lane override | systemd drop-in `no-projection-replay.conf` sets `FRWHOOP_DISABLE_LANES=projection` | `deploy/OPERATIONS.md:9-11`, `docs/BACKEND.md` ("Production configuration") |

### 1.3 Swift worker lanes

| Item | Value | Evidence |
| --- | --- | --- |
| Lanes | `projection`, `scoring` (+ sub-flag `series`), `archive`, `verify` | `main.swift:25-26,277-278` |
| Lane enable/disable | `FRWHOOP_DISABLE_LANES`, comma-separated | `main.swift:81-84,169` |
| Threading | one thread per lane on ONE concurrent `DispatchQueue`; heartbeat on the main thread | `main.swift:282-368,589-621` |
| DB connections | 5 libpq connections held for process life (heartbeat + 4 lanes) | `main.swift:104-118` |
| Budgets (defaults) | projection 8, scoring 4, archive 8, verify 4, reconcile 4 | `main.swift:76-80` |
| Poll / heartbeat | 1000 ms / 15000 ms | `main.swift:85-86` |
| Queues | projection `noop_projection_debt`; scoring legacy `physiology_work_items`; scoring v2 `scoring_jobs_v2`; archive v2 `scoring_archive_jobs_v2`; archive legacy `physiology_archive_outbox`; heartbeat `scoring_service_heartbeats` | `deploy/OPERATIONS.md:15-22`, findings/deployment-do.md §a4 |
| v2 claim/publish | `claim_scoring_v2` → `publish_scoring_snapshot_v2`; dense series `publish_metric_series_v1` after commit | `ScoringLane.swift:303-347`, `:355-381` |
| Leases / retries | `leaseSeconds = 300`; `publishAttempts = 3` for serialization/stale races | `ScoringLane.swift:44,46-47,282-299` |
| Heartbeat rows | `scoring_service_heartbeats` (singleton) + `physiology_worker_heartbeats` (per instance) | `main.swift:528-576` |

**Transaction boundary that constrains the new lane.** The v2 scoring path performs claim +
input load + score + publish inside ONE `REPEATABLE READ` transaction (`ScoringLane.swift:301-347`);
the fleet path seals its claim in a committed transaction and then computes in a second
`REPEATABLE READ` transaction (`ScoringLane.swift:146-241`). Candidate inference must therefore
run OUTSIDE those transactions, and only the result write belongs inside a fresh transaction
(findings/deployment-do.md §0.5, §b6).

### 1.4 Supabase

| Item | Value | Evidence |
| --- | --- | --- |
| Postgres | Supabase-managed; `[db] major_version = 17` in the project config | `supabase/config.toml:18` |
| REST row cap | `[api] max_rows = 1000` | `supabase/config.toml:13` |
| Edge functions | `push`, `coach`, `retention-sweep`, `reconcile`, `account-deletion`, `ingest-verify`, `scores`; every one `verify_jwt = false` and does its own bearer auth | `supabase/config.toml:49-71`, findings/supabase-contracts.md §4 |
| Migrations | 151 files in `supabase/migrations/` in this worktree; newest `20260930235900_coach_harness.sql` | findings/impl-supabase.md §7.1; `git ls-files supabase/migrations` count |
| Production history drift | `supabase_migrations.schema_migrations` records only up to `20260921104000`; the 39 later migrations were applied with SQL directly | `docs/BACKEND.md` ("Migrations") |
| Durability surfaces | `scoring_jobs_v2` (PK user/device/day/algorithm_version), immutable `scoring_snapshots_v2`, `claim_scoring_v2`, `publish_scoring_snapshot_v2`, `invalidate_scoring_stream_v2`, `refresh_scoring_legacy_v2`, `expand_scoring_invalidations_v2` | findings/supabase-contracts.md §2, §3 |
| Legacy surfaces | `algorithm_results` / `metric_runs` are pre-lineage only, NOT the v2 surface | findings/supabase-contracts.md §5.7 |
| Ingest receipt tables | `noop_upload_receipts`, `object_manifests`, `noop_signal_windows` | findings/supabase-contracts.md §2.10, findings/validation-fixtures.md §2.3 |
| RLS | only `get_server_score_snapshot_v2` is granted to `authenticated` among the scoring RPCs | findings/supabase-contracts.md §2.9 |

### 1.5 B2 storage

| Item | Value | Evidence |
| --- | --- | --- |
| Role | private raw archive + manifests; object bytes are uploaded with a presigned PUT and never transit the function | `supabase/functions/_shared/keys.ts:134-143` |
| Object-lane streams | `ppgWaveformSample` (`bin.gz`), `v18AuxSample` (`bin.gz`), `rawBatch` (`pb.zst`), `rawImuSession` (`bin.zst`) | `supabase/functions/_shared/keys.ts:60-62`, findings/conditional-models.md §1 |
| Retention class | `ppgWaveformSample`, `rawImuSession`, `rawBatch` are `research`; `v18AuxSample` is `diag` | `supabase/functions/_shared/keys.ts:125-128` |
| Sampling clock | deliberately NOT asserted for those streams (`OBJECT_LANE_RECORD_HZ = null`) — "Receipt member counts do not establish a qualified sampling clock or temporal coverage" | `supabase/functions/_shared/keys.ts:145-150` |
| Integrity | archive lane stores `sha256` / `content_sha256` / `compressed_bytes`; the verify lane re-hashes decoded content against the manifest | findings/deployment-do.md §a9 |

### 1.6 Document-vs-code: the surface the spec assumed does not exist

The spec's implementation map (§2) names a Node/Express backend with
`whoop/backend/metrics/engine.js`, `host/routes.js` and `GET /api/days`. None of that is in this
checkout: the repo root has no Node server, and the read path is the `scores` edge function plus
PostgREST RPCs (findings/supabase-contracts.md §4.2; parent decisions D5/Open item). The spec
itself flags that its map is "not verification of the current GitHub checkout".

---

## 2. The actual data path

### 2.1 Capture → durable receipt → archive → projection → acknowledgement

```
strap BLE -> Strand/Push/CloudCapture.swift -> Strand/Push/CloudJournal.swift (local SQLite outbox)
  -> CloudBatchBuilder.swift -> POST /functions/v1/push (gzip NDJSON)
  -> supabase/functions/_shared/registry.ts -> noop_* projection tables
```
Evidence: findings/validation-fixtures.md §2.1.

Server-side acceptance order (findings/supabase-contracts.md §4.1, from
`_shared/ingest.ts`): `WAL commit -> B2 archive (manifest.ready + durabilityReceipt) ->
Supabase projection -> ack -> noop_upload_receipts row -> wal.saveAck`. The ack shape is
`{protocolVersion, batchId, stream, deviceId, endCursor, acceptedRows, status:'accepted'}` plus a
version-1 durability receipt (`version, state:'verified_indexed', receiptId, ownerUserId,
deviceId, objectId, batchId, sourceId, stream, schemaVersion, objectKey, contentSha256,
wireSha256, compressedBytes, uncompressedBytes, verifiedAt, indexedAt`).

Two facts matter for this migration:

1. Acknowledgement never waits for scoring. Spec §4.2 item 1 is already satisfied; candidate
   inference must not be inserted before the ack (findings/supabase-contracts.md §4.1).
2. Replay is idempotent: an identical batch returns the same ack and the same receipt
   (deterministic `uuidFromParts([...])` receipt id) (findings/supabase-contracts.md §4.1).

### 2.2 Scoring → publication → reads

```
scoring_jobs_v2 -> claim_scoring_v2 (lease) -> load inputs -> score -> publish_scoring_snapshot_v2
  -> publish_metric_series_v1 (after commit) -> scoring_snapshots_v2 / server_metric_series
reads: scores edge function -> _shared/serverScores.ts -> PostgREST RPCs
```
Evidence: `deploy/OPERATIONS.md:15-22`, `ScoringLane.swift:303-347,355-381`,
findings/supabase-contracts.md §3.1-§3.5.

Read routes (`_shared/serverScores.ts:132-146`), all `cache-control: no-store`:

| Route | RPC |
| --- | --- |
| `GET /` | `server_scoring_pending_contract` / `server_scoring_for_device_day` (+ `hosted_snapshot` for installation-bearer requests) |
| `GET /days?cursor=&limit=&scopeRevision=` | `server_result_days_page` |
| `GET /series?from=&to=` | `server_metric_series_read` |
| `GET /diagnostics?day=` | `server_pipeline_diagnostics` |
| `POST /devices`, `POST /sleep-overrides`, `POST/GET /compute-requests` | `register_account_compute_source`, `enrolled_physiology_sleep_override`, `submit_compute_session_request` / `read_compute_session_result` |

The day cursor carries `scopeRevision` = `md5(...)` of the selection/qualification/policy state
computed inside `server_result_days_page` (`20260923150000_result_day_pagination.sql:47-90`), so a
provider switch MUST change that md5 or clients never re-walk days
(findings/supabase-contracts.md §4.2; parent decision D2).

### 2.3 Signals that actually exist

The iOS client can only journal streams that are cases of `CloudStreamKind`
(`Strand/Push/CloudJournal.swift:12-40`): `hrSample`, `rrInterval`, `event`, `battery`,
`spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`, `stepSample`, `sleepStateSample`,
`standardHRReceipt`, `journal`, `sleepSession`, `workout`, `dailyMetric`, `rawBatch`.
`CloudCapture.rows()` builds rows for exactly the scalar set (`CloudCapture.swift:125-235`), and
`CloudBatchBuilder.appendTable(for:)` returns nil for `journal`/`sleepSession`/`workout`/
`dailyMetric`/`rawBatch` (`CloudBatchBuilder.swift:72-82`).

| Signal | Server table | Cadence / unit | Timestamp semantics | Evidence |
| --- | --- | --- | --- | --- |
| HR | `noop_hr_samples` | 1 sample/s, integer bpm | unix seconds (1 s resolution; two readings in one second collide on the PK) | findings/validation-fixtures.md §2.3 |
| RR | `noop_rr_intervals` | one row per beat; `rrMs`, `seq`, `ord`, `srcChannel`, `tsSuspect`; PK `(user, device, ts, rrMs, seq)` | `ts` = unix seconds bucket (whole seconds) | findings/validation-fixtures.md §2.3; `Streams.swift:88-89` |
| Gravity/motion | `noop_gravity_samples` | 1 Hz vector `x,y,z` + scalar `dynAccel` (g) | unix seconds | `Streams.swift:315-337`; findings/validation-fixtures.md §2.3 |
| Band sleep state | `noop_sleep_state_samples` | 1 row/s; `state=(rawByte>>4)&3` (0 wake/1 still/2 asleep/3 up) | unix seconds | findings/validation-fixtures.md §2.3 |
| Derived PPG HR | `noop_ppg_hr_samples` | 1 Hz bpm + `conf` (a number, NOT a waveform) | unix seconds | findings/validation-fixtures.md §2.3 |
| Respiration raw | `noop_resp_samples` | raw ADC int | unix seconds | findings/validation-fixtures.md §2.3 |
| Steps | `noop_step_samples` | cumulative u16 counter + activity class | unix seconds | findings/validation-fixtures.md §2.3 |
| SpO2 / skin temp | `noop_spo2_samples`, `noop_skin_temp_samples` | raw ADC pairs | unix seconds | findings/validation-fixtures.md §2.3 |

`RRInterval.ts` is declared as "wall-clock unix seconds" (`Streams.swift:88-89`), i.e. whole
seconds — the single most consequential fact for the HRV candidate
(findings/hrv-neurokit.md §4b).

### 2.4 Raw waveform: operator-issued research objects only

Two statements are both true and must not be conflated:

1. **From the iOS fleet there is no raw PPG and no high-rate acceleration.** `CloudStreamKind` has
   no case for `ppgWaveformSample`, `rawImuSession` or `v18AuxSample`, and the sealer explicitly
   excludes `rawBatch` (`CloudJournal.swift:626-634`). The 24 Hz v26 PPG waveform
   (`WhoopStore/Database.swift:540-575`) and the 100 Hz 6-axis IMU
   (`ImuSessionFileStore.swift:1-14`) are captured locally and exported manually; neither has a
   cloud upload path (findings/validation-fixtures.md §2.1-§2.2).
2. **The server can hold raw waveform objects**, but only as operator-issued research windows:
   `sensor_acquisition_contracts(kind in {beat_timing, ppg, imu, temperature})` with
   `scope_end_s - scope_start_s = 300`, "Evidence is issued by the operator after capture review.
   Client intake cannot self-qualify", and coverage/sampling clock forced to `null` for those
   streams (`20260921120000_sensor_acquisition_windows.sql:9-13,21-33`;
   findings/conditional-models.md §1).

Consequence: raw-waveform eligibility is per user, per device, per 300 s window, and cannot be
assumed for a population (findings/conditional-models.md §1).

---

## 3. Active algorithms before this migration

### 3.1 HRV (`Packages/StrandAnalytics`, shared by iOS and the worker)

| Rule | Value | Evidence |
| --- | --- | --- |
| Range filter | 300-2000 ms | `HRVAnalyzer.swift:29,31,115-117` |
| Ectopic rejection | Malik, deviation 0.20, centred window radius 2, median excludes the beat under test | `HRVAnalyzer.swift:36,40,125-145` |
| Clean series | `rejectEctopic(rangeFilter(rr))` | `HRVAnalyzer.swift:148-150` |
| Gap-aware adjacency | `contiguous[i] = keptOrig[i] == keptOrig[i-1] + 1`; index 0 always false | `HRVAnalyzer.swift:167-203` |
| RMSSD | `sqrt(sum d^2 / pairCount)` over contiguous pairs only | `HRVAnalyzer.swift:209-223` |
| Minimum clean intervals | **20** (`minBeats`) | `HRVAnalyzer.swift:33`, enforced at `SleepStager.swift:3053-3054` |
| Windows | 5-minute TUMBLING (`windowS = 300`), final window closed on `end` | `SleepStager.swift:3012,3028-3036` |
| Session value | plain arithmetic MEAN over usable windows, then the over-count gate | `SleepStager.swift:2958-2973` |
| Day value | duration-weighted mean of per-session means | `AnalyticsEngine.swift:753-759` |
| Over-count gate | refuses a session whose own R-R banks more beat-time than its wall span | `SleepStager.swift:2971,2980-2995`; `HRVAnalyzer.swift:477-484` |
| Coverage verdicts | `plausible` / `underCovered` / `sameSecondOverCount` / `crossSecondOverCount` / `unmeasurable`; ceiling 1.10 | `HRVAnalyzer.swift:392-411,575-594` |
| Server-side reference (already shipping, **not in this branch**) | pooled `sumSq`/pairs across continuous runs, `spliceToleranceSeconds = 3.0`, separate pairs/coverage | findings/hrv-neurokit.md §5c (`IntradaySeries.swift:213-269`) |

### 3.2 Sleep detection and staging

| Item | Value | Evidence |
| --- | --- | --- |
| Detector entry | `SleepStager.detectSleep(hr:rr:resp:gravity:tzOffsetSeconds:...)` | `SleepStager.swift:1318` |
| Requires gravity | `if grav.count < 2 { return [] }` — a gravity-stillness detector, not HR-only | `SleepStager.swift:1391` |
| Stillness thresholds | still 0.01 g, window 15 min, fraction 0.70, max gap 20 min, merge 15 min, min sleep 60 min | `SleepStager.swift:88-98` |
| Daytime/nap guards | daytime band 11:00-20:00 local, night-continuation gap 90 min, daytime min 90 min, HR dip 0.95 | `SleepStager.swift:112-129` |
| Over-count gate order | minSleep → maxMainSleepSpan (16 h) → `confirmSleepWithHR` → off-wrist fraction (0.5) → daytime/morning | `SleepStager.swift:1504-1619` |
| Stager selection | `useSleepStagerV2` parameter defaults `false` (`:1325`) but the shipped call site threads `PuffinExperiment.experimentalSleepV2Enabled`, default ON (`:1304-1313`) | findings/sleep-boundary-stager.md §4.6 |
| Boundaries | onset = first of 3 consecutive Cole-Kripke sleep flags; final wake = last true flag else `n-1` | `SleepStager.swift:1647-1662` |
| awake/wake | `SleepStageVocabulary.isWake` is a predicate true for `wake` or `awake`; segment rows canonicalise to `wake`, minute dicts to `awake` | findings/sleep-boundary-stager.md §4.7 |
| Four-stage display | `SleepStageTotals.Minutes {awake, light, deep, rem}`, `asleep = light+deep+rem`; unknown stage strings are silently skipped | `SleepStageTotals.swift:9-16,30-38` |
| Day semantics | the analysis core still uses `AnalyticsEngine.dayStartUtcSeconds` + `dayString` (fixed 86,400 s blocks); `LocalDayWindows` is not yet wired in | findings/sleep-boundary-stager.md §4.9 |
| User corrections | an edited window is first-class and outranks any candidate; wake date is explicit | `SleepEditGuard.swift:60`; `SleepStager.swift:1665-1668` |

### 3.3 Baselines

Personal nightly baselines are Winsorized EWMA: a robust EWMA centre plus an EWMA of absolute
deviations (floored), hard outlier rejection, Winsor clamping, cold-start gating and staleness
status (`Baselines.swift:1-16,427`, `Baselines+Trace.swift:27-99`; `ReadinessEngine.swift:261-270`).
`DaytimeBaselines.swift:11,111` uses the same `Baselines.foldHistory` spine for daytime metrics.
Consequence for this migration: an algorithm change shifts a person's baseline even with no
physiological change, so histories must stay identifiable by method and dependency version
(spec §7).

### 3.4 Preserved outputs

RHR definition, Rest/recovery weights, strain, calories and step accumulation are unchanged by
this branch. The candidate lane is additive and ships with every metric `mode='off'`; the
canonical publish path is not modified (findings/impl-supabase.md §3.1, §5.12; parent decision D5).

---

## 4. Document-vs-code discrepancies found

| # | Spec / document claim | Actual code | Evidence |
| --- | --- | --- | --- |
| 1 | Node/Express backend with `whoop/backend/**` and `GET /api/days` (spec §2, §6) | No Node server exists; the read path is the `scores` edge function + PostgREST | findings/supabase-contracts.md §4.2; findings/impl-supabase.md §8 |
| 2 | HRV "minimum 30 clean intervals" (spec §5) | 20 (`HRVAnalyzer.minBeats`) | `HRVAnalyzer.swift:33`; findings/hrv-neurokit.md §5d |
| 3 | HRV "maximum 20% artifact fraction" nightly gate (spec §5) | No nightly artifact-fraction gate exists; a 35% ceiling exists only on the SPOT path and on intraday buckets | `HRVAnalyzer.swift:46`; findings/hrv-neurokit.md §5d |
| 4 | HRV "minimum three usable windows" (spec §5) | No such gate in code | findings/hrv-neurokit.md §5d |
| 5 | HRV "median-window aggregation" (spec §5) | Plain mean over windows; duration-weighted at session/day level | `SleepStager.swift:2972`, `AnalyticsEngine.swift:753-759` |
| 6 | 5-minute windows (spec §5) | Confirmed: 300 s tumbling | `SleepStager.swift:3012` |
| 7 | Server-side HRV reference "already shipping" in `IntradaySeries.swift` | `Tools/CloudWorker/Sources/frwhoop-worker/IntradaySeries.swift` is **NOT in this branch**; it exists only as uncommitted in-flight work in the dirty main checkout | findings/impl-swift-client.md §5.1; `git status` in the worktree |
| 8 | Spec's sleep "in-bed interval, onset, wake" contract | Current display contract has four stages only; there is no field or vocabulary for a three-class wake/REM/NREM result | findings/sleep-boundary-stager.md §4.8; `SleepStageTotals.swift:9-16` |
| 9 | Spec's IANA timezone semantics for boundaries | The shipped detector takes a single fixed `tzOffsetSeconds`; `LocalDayWindows` is called only by its own tests | findings/sleep-boundary-stager.md §4.9 |
| 10 | Spec §6 implies the migration is applied from the current `supabase/migrations/` tree | The findings' lineage (153 files, incl. `20261001190000`, `20261001210000`) is NOT this worktree's lineage (151 files, newest `20260930235900`); the extra files are untracked work in the dirty checkout | findings/impl-supabase.md §7.1 |
| 11 | `server_metric_series` bounds used as precedent for candidate bounds | `20261001210000_metric_series.sql` is absent from this worktree; the candidate bounds cite it but it is not present here | findings/impl-supabase.md §3.2, §7.1 |

Discrepancy 7 is the one with the widest blast radius: the HRV candidate's `splice_tolerance_s =
3.0` default is taken from the findings, not from a symbol present in this branch, and must be
re-checked if that file lands (findings/impl-swift-client.md §5.1).

---

## 5. Baseline test matrix (before this migration)

All rows below were actually run on the worktree at base `59f0415a`
(findings/validation-fixtures.md §1). They are the baseline this branch must not regress.

| Suite | Command (abridged) | Result |
| --- | --- | --- |
| `StrandAnalytics` | `cd Packages/StrandAnalytics && swift test --scratch-path <tmp>` | 2102 tests, 0 failures, 0 skipped — PASS |
| `WhoopProtocol` | `cd Packages/WhoopProtocol && swift test --scratch-path <tmp>` | 812 tests, 1 skipped, 0 failures — PASS |
| `NoopPush` | `cd Packages/NoopPush && swift test --scratch-path <tmp>` | 192 tests, 0 failures — PASS |
| `frwhoop-worker` | `cd Tools/CloudWorker && PKG_CONFIG_PATH=<libpq>:<zstd>:<openssl@3> swift test --scratch-path <tmp>` | 98 tests, 1 skipped, 0 failures — PASS |
| macOS `StrandTests` (the declared main suite) | `xcodegen generate` then `xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -only-testing:StrandTests` | 2303 tests, 2 skipped, **2 failures** — the two documented Pacific-time caption tests (`SkinTempAbsoluteDisplayTests.testTheSecondaryLeadsTheCaptionSoItSitsUnderTheValue`, `SleepCarriedStampTests.testPriorDayValueIsCarriedAndStamped`); accepted baseline |
| Supabase Deno edge tests (fixture-free subset) | `deno test --frozen --lock=deno.lock ...` over the 33 runnable files | 215 tests, 214 passed, **1 failed** — a MISSING PREREQUISITE, not a code defect: `tests/intake_deadline_test.ts:39` spawns `infra/vps/scripts/test-scoped-canary-guard.py`, and `infra/` does not exist in this repo |
| Supabase Deno tests needing `EDGE_TEST_ARTIFACTS` | — | 15 files BLOCKED, NOT RUN (the fixture exporter `Tests/ServerFixtureNative` is absent) |
| `supabase/tests` SQL fixtures | — | BLOCKED, NOT RUN (see section 6) |

The macOS `StrandTests` run needs a generated Xcode project: `Strand.xcodeproj/project.pbxproj` is
gitignored and absent from both checkouts, so generation was done in a throwaway copy
(findings/validation-fixtures.md §1.2).

Other referenced-but-absent infrastructure (findings/validation-fixtures.md §1.5):
`Tests/ServerFixtureNative`, `Tests/ServerIntakeBench`, `Tools/server-score-contract`,
`infra/vps/scripts/test-scoped-canary-guard.py`, `scoring-service/`. There is no CI: no
`.github/` directory and no tracked Makefile.

### 5.1 Real-input fixtures

No real overnight capture exists locally in any form. The only in-repo artifact that claims
observed hardware is `StrandTests/Resources/whoop5_rr_paired_capture.json` (1.3 KB, 2 cases),
whose own provenance says "This is paired RR evidence, not an unmodified capture"
(findings/validation-fixtures.md §2.5). Accuracy evidence cannot be produced from local material;
only decoder/wire contract parity can.

---

## 6. Environment blockers

| # | Blocker | Impact | Evidence |
| --- | --- | --- | --- |
| 1 | No Droplet access (no production access by instruction) | Unverified: Cloud Firewall rules, `ufw` state, listening ports (`ss -ltnp`) and whether port 8787 is free, disk size/free space, swap, whether `do-agent` is installed, and the real `FRWHOOP_*` values | findings/deployment-do.md §e.1 |
| 2 | A local, unrelated Supabase stack holds the DB ports | `supabase db start` fails ("Bind for :::54322 failed: port is already allocated") because project `euhtvcptjkgvivaeunze` (up 43 h) holds 54322/54321 and `priorities-e2e-pg` holds 55432. Both were left untouched, so `supabase/tests` SQL fixtures could not run | findings/validation-fixtures.md §1.4 |
| 3 | `supabase/tests/run-enrollment-postgres.sh` is dead in this repo | It reads `scoring-service/service/src/test/resources/physiology_queue_bootstrap.sql`; `scoring-service/` does not exist (0 tracked files) | findings/validation-fixtures.md §1.4 (BLOCKER A) |
| 4 | Full-lineage migration apply is not reproducible | Applying every `supabase/migrations/*.sql` in filename order on a plain PostgreSQL applied **130 of 151**; 21 failures are environmental or pre-existing ordering issues (missing `realtime` schema, `pg_cron`/`pg_net` unavailable in Homebrew PG18, and `object_manifests.durability_receipt` used by `20260918040000` but added by the later `20260921060000`) | findings/impl-supabase.md §2.2 |
| 5 | The repository's own harness does not apply the lineage in filename order either | `supabase/functions/tests/local_postgres.ts` reorders and subsets; the new migration's own suite uses a documented 12-file prerequisite subset | findings/impl-supabase.md §2.2-§2.3 |
| 6 | No real capture corpus | The capability report's coverage/gap/drift/provenance rows cannot be filled without a read-only production session | findings/validation-fixtures.md §2.5, §5.5 |
| 7 | `wrn-gru-mesa` cannot produce frequency-domain features on real ECG | `_nanpsd` raises whenever no 270 s window is free of out-of-range RR intervals (measured: scipy's own shipped toy ECG has 1.34% out-of-range RRIs, `nan_free_windows = 0`); not fixed by pinning scipy 1.13.1 | findings/impl-sleep-providers.md §1.4 |
| 8 | TensorFlow is not installable on the arm64 development host | The documented `sleepecg.load_classifier` path raises `ModuleNotFoundError`; the adapter loads the checkpoint with standalone Keras 3 instead and records which loader ran | findings/impl-sleep-providers.md §1.2 |
| 9 | Deployed Supabase PostgreSQL version and live schema drift are unverified | All SQL evidence is PostgreSQL 18.3 (Homebrew); nothing was applied to a remote database | findings/impl-supabase.md §8 |
| 10 | Cross-thread read of lane stats | `ScoringLane` is a global `var` mutated by the lane thread and read by the heartbeat (pre-existing pattern; the candidate counters follow it) | findings/impl-swift-client.md §5.5; findings/review-swift-client.md R11 |

---

## 7. What this branch does NOT do

* No production deploy, no live default change: every metric ships `mode='off'`
  (findings/impl-supabase.md §3.1).
* No iOS change: capture, upload, HealthKit provenance and local overlays are untouched.
* No sensor enablement, firmware work, BLE repair or new raw-stream ingestion.
* No model weights in the repo; artifacts stay in `/tmp/frwhoop-physiology/ckpt/` and are pinned by
  manifest only (findings/impl-inference-hrv.md §1c, §4).
