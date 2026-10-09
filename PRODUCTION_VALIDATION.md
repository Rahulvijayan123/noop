# Production validation: integration branch deployed on 2026-10-09

Branch `integration/seven-branches-20261008` (see `INTEGRATION_HANDOFF.md`) is live in production: Supabase project
`sgoyxzcagqyxexmsidtk` (FRWHOOP) and the worker host `frwhoop-worker-2`. Every claim below was checked against the
production database, the edge-function logs or the host itself; times are UTC. Nothing was pushed to a git remote or
merged into `main`.

## 0. Summary

- The nine branch migrations and three fix migrations found during validation are applied and recorded; all seven
  edge functions are redeployed; the worker and the inference sidecar run from stamped releases; the owner's phone
  runs Nara 11.8.0 (431) built from this branch.
- v2 scoring was blocked for every user from about 03:13 to 04:05: the owner's live day failed to publish on a
  serialization conflict with its own uploads and stayed first in the queue. Fixed by migration `20261009010000`
  (section 8); v2 resumed within a minute and Postgres has logged no serialization failure since. A second, narrower
  blocker (one day whose cross-midnight night another day held) was fixed by `20261009020000`.
- Every lane the new measurements need is on and producing rows from real uploads: scoring v2, measurement context,
  activity context with ElderNet gait and ActiNet motion (candidate mode, every user), sensor biomarkers (eight
  families, ParaDigMa tremor/arm swing, PPG quality and pulse shape), and the server physiology candidates (HRV,
  sleep boundary, sleep stage in shadow).
- PPG anchor upload is on end to end: the receiver advertises it, the app defaults it on, and anchored PPG objects
  (`push_protocol_version` 1.5, schema 3) arrive and are processed.
- The morning-sync migration fixed the ingest error rate: `push` 5xx went from 5–21% per hour (p95 10–11 s) in the
  day before to 0.9% (p95 5.6 s) in the first full hour after.
- The database was starved for reads by a pre-existing full-table scan in the verification lane (about 82% of all
  block reads); a one-row partial index (`20261009030000`) took that call from about 56 s to under 1 ms.
- Six defects found here were fixed and committed (section 9). Remaining blockers are in section 10; none loses data.

## 1. What is deployed

| Component | Version | Where |
| --- | --- | --- |
| Worker | release `e517e2c16a79145f2a20c9cf387815071e0d9ddf`, binary sha256 `51a38227…`; built and tested on the host (783 tests, 0 failures, 82 database tests skipped) | `/opt/noop/current`, unit `frwhoop-worker` |
| Inference sidecar | venv from release `8adb95afc` (inference code unchanged since); model revision `rev-47c2fc7cad2d1ac9` | `/opt/frwhoop-inference/venv`, `/opt/frwhoop-models/current`, unit `frwhoop-inference` |
| Edge functions | from `45092fa61`: push v22, scores v23, coach v10, reconcile, ingest-verify, retention-sweep, account-deletion v12 (deployed 02:14, no `--prune`) | Supabase |
| App | Nara 11.8.0 (431) from `dbd6f1c7a`, bundle `com.rahulvijayan.noop` | owner's iPhone |

Release `282721cae` stays on disk as `/opt/noop/previous`, and `45092fa61` and `8adb95afc` under
`/opt/noop/releases`; the pre-release tree under `/opt/noop/Tools` was left in place.

Configuration changed (key names only; values that are secrets stay on the host):

- `/etc/frwhoop/worker.env` (backed up as `worker.env.bak-<timestamp>` before each edit):
  `FRWHOOP_ACTIVITY_HOME=/opt/noop/current/Tools/ActivityContext`, `FRWHOOP_SOURCE_REVISION=<release commit>`,
  `FRWHOOP_SENSOR_PPG_ENABLED=1`, `FRWHOOP_PERFUSION_RESEARCH_ENABLED=1`, `FRWHOOP_PARADIGMA_ENABLED=1`,
  `FRWHOOP_DEEPBEAT_SHADOW_ENABLED=1`, `FRWHOOP_SIAMAF_SHADOW_ENABLED=1`, `FRWHOOP_CANDIDATE_SCHEDULER=persisted`.
  ElderNet and Inertia were already `candidate` with pinned weights; there is no per-user gate, so they run for every
  user.
- `/etc/frwhoop/inference.env`: `FRWHOOP_PARADIGMA_ENABLED=1`, `FRWHOOP_DEEPBEAT_SHADOW_ENABLED=1`,
  `FRWHOOP_SIAMAF_SHADOW_ENABLED=1`.
- Edge secret `NOOP_PUSH_ADVERTISE_PPG_ANCHOR=1`, set after the new worker was live (the order in
  `docs/model-integration/ppg-transport.md`).
- `physiology_provider_defaults`: `hrv` → `production.runs.v1`, `sleep_boundary` → `hypnospy.hr-boundary.v1`,
  `sleep_stage` → `sleepecg.wrn-gru-mesa.v1`, all `mode='shadow'`, enabled one at a time with the effective selection
  checked through `physiology_selected_provider`. `respiration` stays `off`: there is no respiration provider.
- App defaults (commit `dbd6f1c7a`): `noop.cloud.ppgAnchorUpload` and the sensor-biomarker settings section default on.

## 2. Migrations

Applied on the host with `psql -v ON_ERROR_STOP=1 -1 -f`, one transaction each, in order, after a schema and data
backup of every affected object (`/root/nara-backup-20261009-predeploy`, copied to the external SSD with
`SHA256SUMS`); the index migration is the one exception, explained below the table. Each is recorded in
`supabase_migrations.schema_migrations`; none was rerun.

| Migration | Purpose |
| --- | --- |
| `20261008020000_ingest_no_scoring_wait` | uploads stop waiting on scoring locks (`SKIP LOCKED` + `scoring_dirty_marks_v2`, folded by pg_cron every minute) |
| `20261008100000_activity_context_current_lineage_and_versions` | activity context lineage and lane versions |
| `20261008100100_activity_context_epochs_day_revision_rows_index` | index for epoch reads |
| `20261008100200_activity_context_transitions_onset_source` | transition onset source |
| `20261008100400_bump_user_revision_skip_deleted_owner` | revision bump skips deleted owners |
| `20261008100500_activity_ground_truth_confirmation_source` | ground-truth confirmation source |
| `20261008100600_activity_release_authority` | ElderNet/ActiNet release authority and candidate days |
| `20261008110000_physiology_candidate_pending` | persisted candidate queue |
| `20261008120000_ppg_transport_anchor` | PPG anchor transport |
| `20261009010000_result_day_touch_snapshot_writers` | fix found here (section 8): snapshot writers queue their result-day touch on a conflict; pg_cron folds it every minute |
| `20261009020000_refresh_legacy_nights_cross_day` | fix found here (section 8): the legacy night refresh moves a night another day holds instead of failing on it |
| `20261009030000_object_manifests_verify_pending_index` | fix found here (section 8): partial index for the verification lane's arrival scan |

The two function fixes were tested first on a scratch Postgres: each reproduced the production error with the
function it replaces, then passed with the new one and re-applied cleanly. For the first, the racing publish
succeeded, the fold advanced the cursor and READ COMMITTED writers behaved as before. Both were applied the same way,
after backing up the function each replaces (and the cron job list).

The index was tested on 400,000 scratch rows with the lane's two statements copied from the Swift source: a
parallel full scan (22,000 buffers) became an index read (24 buffers with a custom plan, 137 generic) returning the
same rows. A plain `CREATE INDEX IF NOT EXISTS` takes the table's share lock even when the index exists (checked on
the scratch database), which would hold up uploads behind any open writer. So in production the index was built
with `CREATE INDEX CONCURRENTLY` (05:16:49–05:18:41, writers never blocked); the script checked that it is valid and
that `pg_get_indexdef` matches the migration's definition exactly, then recorded the migration without executing
its file.

Backfill after the switch (`deploy_backfill_20261009`): 146 scoring days from the last 14 days re-queued across 17
devices, and 136 measurement-context days invalidated so they rebuild with the new lanes. It drains in the background
behind live work.

## 3. Models and inference

Sidecar `/healthz` reports the release identity and these providers ready:

| Provider | Version | Mode |
| --- | --- | --- |
| `production.runs.v1` | `frwhoop-inference.adapter/1.0.0` | HRV candidate, shadow |
| `neurokit2.shadow.v1` | `frwhoop-inference.adapter/1.0.0` | shadow |
| `hypnospy.hr-boundary.v1` | `hypnospy.hr-boundary.v1/1.0.0` | sleep boundary candidate, shadow |
| `sleepecg.wrn-gru-mesa.v1` | `sleepecg.wrn-gru-mesa.v1/1.0.0` | sleep stage candidate, shadow |
| `sensor.biomarkers.v1` | | sensor families |
| `sensor.biomarkers.paradigma.v1` | ParaDigMa 1.1.2 | tremor, arm swing |
| `sensor.biomarkers.rhythm.v1` | DeepBeat / SiamAF | rhythm shadow |

Inference lane counters after the first 20 minutes: 184 admitted, 183 completed, 0 errors, crashes, timeouts or
respawns.

Real results since the switch (02:53:50):

- Sensor biomarkers, 7 device-days: movement and oscillation ok on all 7, tremor ok on 6 (real ParaDigMa
  classification), `ppg_quality` and `pulse_shape` ok on device `155ad9d4` day 10-07. Withheld by design:
  arm swing `unknown_wrist_placement` (5), PPG families `artifact_unavailable` on days before anchored PPG (6),
  rhythm `unverified_sample_clock`, perfusion `unverified_optical_dc`. Two `adapter_broken` results came from the
  ParaDigMa short-run defect; both days were recomputed after the fix in `8adb95afc` with no adapter failure
  (section 9), and `155ad9d4` day 10-08 now also has PPG quality and pulse shape ok.
- ElderNet gait: 4 device-days in `release_mode=candidate`, model `eldernet-437a38b`, 5,792 windows, 251 gait windows,
  none withheld. ActiNet motion: 4 activity candidate days across 3 devices.
- Physiology candidates, shadow. Before `e517e2c16` every HRV result was `provider_error` (section 9). After it,
  for device `155ad9d4` day 09-30 (main sleep 08:40:30–17:00:15, 24,378 R-R rows in the interval), each against the
  canonical value for the same day:

  | Metric | Provider | Candidate | Canonical | Runtime |
  | --- | --- | --- | --- | --- |
  | HRV | `production.runs.v1` | 83.75 ms RMSSD | 83.73 ms | 1.7 s |
  | Sleep boundary | `hypnospy.hr-boundary.v1` | 29,835 s | 29,985 s in bed | 1.4 s |
  | Sleep stage | `sleepecg.wrn-gru-mesa.v1` | 28,320 s asleep | 27,930 s (465.5 min) | 5.6 s |

  A day with no input (device `62caa9f2` day 09-26) is withheld `insufficient_coverage` rather than guessed. More
  results arrive as the backfilled scoring days complete (section 10).

## 4. Services and health

- Worker: `--print-identity` reports `matches_release: true` for the release and binary digest; started with
  `revision=<release commit>`, `sslmode=verify-full`; every lane reports enabled in the journal (scoring, legacy fleet,
  activity, context, sensor biomarkers with all eight families, candidates with the persisted scheduler).
- Sidecar: release identity matches; memory about 1.2 GB. At 05:25, twenty minutes after the last restart: worker
  and sidecar active with 0 unit restarts, sidecar `/healthz` 7 of 7 providers ready, worker about 0.9 GB, host
  7.9 GB with 3.8 GB available.
- pg_cron `frwhoop-fold-scoring-dirty-marks` succeeds every minute; dirty marks fold within minutes.
- Also on the host and untouched: `frwhoop-worker-oura.service`, a worker from another branch
  (`/opt/noop-oura`, revision `4ac27110b`, running since 10-07) that runs only `--lane oura` under the same worker
  name.

## 5. Tables and flows

Strap → phone → `push` (manifests and objects) → `object_manifests` → worker lanes → result tables → `scores` and
`coach` routes → app and chatbot. Rows written by the new worker since the switch:

| Table | Rows since switch |
| --- | --- |
| `physiology_context_days` | 79 (final and provisional; available, partial, no_data) |
| `activity_context_days` | 7 days, 4 devices, 992 events |
| `activity_gait_windows_days` | 4 (candidate) |
| `activity_candidate_days` | 4 |
| `sensor_biomarker_days` | 7 (5 completed, 2 provisional for today) |
| `object_manifests` (`ppgWaveformSample`, 1.5 / schema 3) | 48 ready |

## 6. Activity context

Activity context is computed from the release's `Tools/ActivityContext` (`FRWHOOP_ACTIVITY_HOME`), which the child
imports from its working directory; an import test on the host passed. Gait and motion heads publish in candidate
mode only; nothing candidate shapes a canonical value. The context documents feed the physiology context, which the
`scores/context` route and the coach read.

## 7. Frontend and chatbot

From the owner's phone (user agent `Nara/431`) after the deploy, all 200: `scores`, `scores/days`, `scores/insights`,
`scores/context`, `scores/anomaly-candidates`, `scores/placement`, `scores/gait-windows`, `scores/exposures`,
`scores/activity-windows`, `scores/series`, `scores/diagnostics`, and the coach routes (`profile`, `settings`,
`context`, `memories`, `threads`, `visual`, `suggestions`, `followups`, `status`).

Chat end to end: a user message at 03:14:37 (`POST coach/chat` 200), the coach's `scores/context` reads, and the
assistant reply stored at 03:14:55; no coach errors logged. No screen layouts were changed; the only app change is
the two defaults above.

## 8. Reliability

- Restart: `systemctl restart frwhoop-worker` stopped in about 3 s with a final heartbeat, restarted with the same
  identity, and resumed claiming. Two leases the old process held (one context day, one sensor day) were not
  released on stop; they expired after 5 minutes and the new process reclaimed and finished them
  (`lease_expiry_count=1`). Cost: up to 5 minutes' delay, no lost or duplicated work.
- Release cutover to `8adb95afc` (03:47): worker stopped, sidecar restarted and ready with all seven providers,
  worker started; both report the new release identity and 0 unit restarts. A mistyped env edit left the worker's
  revision label wrong for about a minute (it only labels the per-process heartbeat row); fixed from the backup taken
  by the edit, the only changed key verified, and the worker restarted.
- Duplicates: none in current `physiology_context_days`, `sensor_biomarker_days`, `activity_gait_windows_days`,
  `physiology_candidate_results` or PPG manifests.
- Serialization: counted from the Postgres log, not the worker journal. The worker's heartbeat reprinted the scoring
  lane's last error every 15.5 s for the life of the process (about 230 lines an hour from one failure); fixed in
  `282721cae`. Postgres logged 1–11 serialization failures an hour on 10-08, all in the result-day trigger under the
  v2 publish, 17 and 15 in the hours after the morning-sync migration, and none since `20261009010000`.
- v2 scoring livelock (found and fixed during validation). An upload bumps the day's `server_result_days` row
  through the `scoring_work_items` trigger. The v2 pass claims, scores and publishes in one REPEATABLE READ
  transaction, and its `scoring_snapshots_v2` insert touches the same row, so an upload committed during the pass
  failed the publish with 40001. The rollback also discards the claim, so the user stays the least recently served
  and is claimed first again. The owner's live day takes about 2 minutes to score and his phone re-dirties it every
  few seconds once uploads stopped waiting on the scoring gate (`20261008020000`), so from about 03:13 every v2 pass
  was that day failing at publish: no v2 day completed for any user from 03:15 to 04:05 while 129 waited.
  `20261009010000` keeps the trigger unchanged for READ COMMITTED writers; a snapshot writer whose row moved queues
  the touch in `internal.server_result_day_touches`, and pg_cron (`frwhoop-fold-result-day-touches`) applies it
  under the same advisory lock a minute later, so the change cursor still advances. After it: 50 v2 days
  completed across 5 users in the next 24 minutes, pending fell from 129 to 79, and the fold job succeeds every
  minute.
- A second v2 blocker behind the first (found once the scoring lane's error field was truthful). From 04:36 one
  day (user `05997396`, day 10-06) failed every attempt on `server_sleep_nights_pkey` inside
  `refresh_scoring_legacy_v2`. Its night starting 10-06 22:28 crosses midnight, so day 10-07's payload holds it
  too; the legacy ingest upserts nights on `(user_id, start_at, algorithm_version)` and had moved the row to 10-07,
  keeping the id derived from 10-06. The 10-06 refresh deletes only rows labelled 10-06, then inserted that id
  again. Nine failures in twenty minutes, each after a 100-second pass and each rolling back the claim.
  `20261009020000` also deletes the user's rows that hold one of the snapshot's nights under another day before
  inserting, so the night moves to the day being republished, as the legacy ingest already does in the other
  direction.
- Database read load (pre-existing, found while v2 sat at 79 pending after the switch to `e517e2c16`). Every active
  worker session was waiting on `DataFileRead`, including a 44-second `object_manifests` select. The instance has
  512 MB of shared buffers for a 20 GB database. Two statements from the verification lane's arrival scan
  (`VerificationLane.candidateSQL`, unchanged since 10-05) had read about 1.75 billion blocks since Postgres started
  on 09-30, about 82% of all block reads, because no index matches their filter and every call scans the 634 MB
  heap. By 10-09 each call took about 56 s and read about 525 MB from disk, and the lane makes two calls a cycle (the
  cursor page finds nothing, then the head page re-serves the same unverifiable object from 09-08).
  `20261009030000` adds a partial index over exactly the rows that scan can return; it holds one row.
- Ingest: `push` 5xx per hour, day before vs first full hour after the morning-sync migration:

  | Window | Requests | 5xx | p95 |
  | --- | --- | --- | --- |
  | 10-08 12:00 – 10-09 02:00, hourly | 700–2,200 | 4.9–21.4% | 10.1–11.2 s |
  | 10-09 03:00 | 469 | 0.9% (retryable 503) | 5.6 s |

  Counting every `/push` path (a wider filter than the table): 03:00 1,303 requests, 0.8% 5xx, p95 5.1 s; 04:00
  1,687, 0.7%, 5.7 s; 05:00–05:25 585, none. Since the index (05:18:41) Postgres has logged no errors other than
  expected stale-lease rejections (`PT409`, a superseded claim).

  Upload commits timed out waiting on the scoring-inputs lock 80–330 times an hour on 10-08; the last one was at
  02:10:06, when `20261008020000` landed. Ten requests hit the statement timeout between 02:16 and 04:32, half of
  them in `reconcile_confirm_noop_wearable`'s scan of the user's manifests (section 10) and one each in five other
  places. The phone retried them, and every one of the 4,570 objects created since 02:00 is `ready` (none stuck).

## 9. Fixes made during the deploy

- `dbd6f1c7a`: PPG anchor upload and the sensor-biomarker section default on in the app (tests updated; 49 macOS
  tests pass).
- `8adb95afc`: ParaDigMa runs shorter than one window (4 s tremor, 6 s gait) are left out of the runner job. One such
  run made upstream classification fail for the whole request ("tuple index out of range"), so tremor and arm swing
  published `adapter_broken` on otherwise good days. Reproduced on the host with synthetic runs (4.0 s fails, 4.1 s
  passes; gait 5.5 s fails, 6.5 s passes); regression test added, and it fails on the previous provider; the
  ParaDigMa suite passes on the host (40 passed, 1 skipped). Released as `8adb95afc` (only this fix, its test and
  `deploy/README.md` differ from `45092fa61`; Swift build without re-running the unchanged Swift tests), sidecar
  re-provisioned from it, both services restarted with verified identities. The two affected days were re-queued:
  device `6f9f9748` day 10-06 went from tremor and arm swing `adapter_broken` to tremor ok (468 eligible seconds) and
  arm swing withheld `unknown_wrist_placement`; device `155ad9d4` day 10-08 went from 20 failed ParaDigMa runs
  (tremor 4,908 eligible seconds, arm swing `adapter_broken`) to no failures (tremor 11,804 eligible seconds, arm swing
  withheld `unknown_wrist_placement`, PPG quality and pulse shape ok).
- Backfill reason renamed to `deploy_backfill_20261009` (the context function accepts `[a-z0-9_]` only; the first
  attempt rolled back whole).
- `282721cae`: migration `20261009010000` (the v2 livelock above) and the scoring lane now retires its last error
  after a scored or superseded day, as the archive lane already did. Released as `282721cae` (Swift build, tests
  skipped for this two-line change); after the restart the heartbeat's `last_error` is empty and every lane reports
  no error.
- `e517e2c16`: the HRV candidate is sent only the R-R rows inside its interval. The day's rows span the 84-hour
  night window, so every HRV result in production was `provider_error`: 400 `out_of_bounds_input` on days worn only
  on a neighbouring night, and 413 on the owner's continuously worn day (69,774 beats, over the sidecar's 8 MiB
  limit). Both providers only read beats inside the interval, so results do not change. Two unit tests added.
  Built and tested on the host (783 tests, 0 failures, both new tests passed), released, worker restarted at 05:04:55
  with `matches_release=true`; its first HRV result was `ok` and matches the canonical RMSSD (section 3).
- `20261009020000`: the legacy night refresh moves a cross-midnight night from the day that held it (section 8).
  Reproduced on a scratch database with production's function (the same primary-key error at the same line), passed
  with the new one; the deployed body differs from production's only by the added delete. Applied 05:04:24; no
  `server_sleep_nights` key error since. The stuck day published at 05:17:30 and the next day at 05:21:49; the night
  is one row (on 10-06, id `3d10924a…`), no duplicate.
- `20261009030000`: the verification lane's arrival scan reads a one-row partial index instead of the whole
  `object_manifests` heap (section 8). After it: under 1 ms a call, no disk reads, 1–2 buffers, against about 56 s
  and 67,000 disk blocks a call before; the lane went from 2 calls in ten minutes to about 25 a minute.

## 10. Known issues and blockers

- `retention-sweep` fails every hour with a statement timeout on its unbounded `object_manifests` query. It has done
  so for at least 24 hours before this deploy. Left alone on purpose: the sweep deletes archived objects from B2, and
  turning it back on is a destructive change that needs its own review.
- Live-day scoring latency: each scoring cycle serves the legacy fleet queue before v2, and a live day is re-dirtied
  while its phone uploads, so the backfill drains over hours. The knobs are `FRWHOOP_LEGACY_QUIET_SECONDS` (20 s),
  the legacy maximum deferral (1,800 s) and `FRWHOOP_SCORING_BUDGET` (4); changing them trades upload batching and
  database load for latency, so they were left at their defaults as a product decision.
- `scores/manual-events` returns 405 to Nara 432/433 builds from another branch; that route is not in this lineage.
- Arm swing stays withheld until a verified wrist side and orientation are recorded (and the WHOOP axis convention is
  verified). Rhythm and perfusion stay withheld behind their clock and optical-DC verification gates.
- Carried over from the handoff: ActiNet classifier has no Swift stage; wav2sleep needs raw 34 Hz waveforms with
  verified packet timing; no respiration provider; the Oura migration is not in this lineage; the projection lane is
  intentionally disabled.
- The sidecar logs idle keep-alive "Request timed out" lines; the inference lane itself reports 0 timeouts.
- The verification lane's heartbeat still shows the statement timeout from its last full scan before
  `20261009030000` (05:14) as its last error. Like the scoring lane before `282721cae`, it keeps its last error until
  it next succeeds. Its only candidate is one `v18AuxSample` object from 09-08 with no durability receipt or digest
  source, which it has re-served every cycle for a month without verifying, so the stale text stays until a new
  arrival is verified.
- A cross-midnight night belongs to whichever day last wrote it: the legacy ingest moves it to the later day, the
  v2 refresh to the day being republished. Both now succeed and keep a single row; which day should own it is a
  product decision.
- `reconcile_confirm_noop_wearable` (from `20261004161000`, already in production before this deploy) checks every
  manifest on the user's provisional device without a bound, and ran into the statement timeout five times in three
  hours after the deploy. The caller retries; it is not touched here.

## 11. Rollback

- Worker: `/opt/noop/current/deploy/release-host.sh rollback && systemctl restart frwhoop-worker` (back to the
  release in `/opt/noop/previous`; `45092fa61` and `8adb95afc` stay installed under `/opt/noop/releases`). To the pre-release tree: `install -m 644 /opt/noop/deploy/frwhoop-worker.service
  /etc/systemd/system/`, restore the `worker.env` backup, `systemctl daemon-reload && systemctl restart
  frwhoop-worker`.
- Sidecar: `/opt/noop/releases/<previous>/deploy/provision.sh --sidecar-only && systemctl restart frwhoop-inference`;
  previous model revision `ffc93db27d79` is kept.
- Candidates: `update physiology_provider_defaults set mode='off', provider_id='none', provider_version='none',
  config_version='none' where metric=...`.
- PPG anchor: unset `NOOP_PUSH_ADVERTISE_PPG_ANCHOR`; phones fall back to the unanchored lane.
- Migrations are additive; the pre-deploy backup is the recovery source for the objects they changed. To undo
  `20261009010000`: run `select internal.fold_server_result_day_touches()` until it returns 0, unschedule
  `frwhoop-fold-result-day-touches`, and restore `touch_server_result_day` from
  `touch_server_result_day.pre-20261009010000.sql` in the backup directory (this brings the livelock back). To
  undo `20261009020000`, restore `refresh_scoring_legacy_v2.pre-20261009020000.sql` from the same directory. To
  undo `20261009030000`, `drop index concurrently public.object_manifests_verify_pending_idx` (no data involved).
