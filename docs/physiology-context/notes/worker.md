# Physiology context — worker lane

Owner: worker. Branch `pc/worker`. Contract: [contracts.md](../contracts.md) §2, §3, §6, §7. Migration read:
`supabase/migrations/20261005120000_physiology_context.sql` (backend-db, merged at 13161df2). Lead branch merged at
6c1f48c2 (systems C, D, E, G real; A, B, F still skeletons at the time of these notes).

## 1. Files

| File | Role |
| --- | --- |
| `Tools/CloudWorker/Sources/frwhoop-worker/ContextLane.swift` | The lane: guard, enqueue, claim, load, build, publish, settle; telemetry; publish payload |
| `Tools/CloudWorker/Sources/frwhoop-worker/ContextInputs.swift` | Job/window parsing, loaders (one read-only snapshot), pure `assemble` (causal view, transport selection, series recomputation, measurement mapping) |
| `Tools/CloudWorker/Sources/frwhoop-worker/ContextSQL.swift` | Every SQL statement of the lane |
| `Tools/CloudWorker/Sources/frwhoop-worker/main.swift` | Config fields, own connection, `LaneState("context")`, lane start, heartbeat entry, queue-age entry |
| `deploy/worker.env.example` | New keys, commented, defaults (off) |
| `Tools/CloudWorker/Tests/frwhoop-workerTests/ContextLane*Tests.swift` | Unit, fixture, DB-gated and profile tests |

## 2. Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `FRWHOOP_CONTEXT_ENABLED` | off | Exactly `1` turns the lane on (`true`, `yes`, ` 1` do not) |
| `FRWHOOP_DISABLE_LANES` | — | `context` in the list turns it off even when enabled |
| `FRWHOOP_CONTEXT_BUDGET` | 2 | Jobs per wake (min 1) |
| `FRWHOOP_CONTEXT_LEASE_SECONDS` | 300 | Lease (min 30; the RPC allows 1–3600) |
| `FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS` | 120 | Seconds between `enqueue_physiology_context_days_v1(200)` calls |

Off, the lane opens no connection, starts no thread and adds no SQL; the heartbeat lists it with `enabled: false` (like
`activity`) and the queue-age query is byte-identical to before. On, it gets its own `PostgresClient`; a failure to
open it is reported on the lane (`last_error_kind = context_connection`) and never stops the worker or marks the
database blocked.

## 3. Lane design

One wake (`ContextLane.drain`):

1. **Guard.** `ContextSQL.tablesPresent` (`to_regclass` of the jobs and days tables, `to_regprocedure` of the
   claim and publish RPCs). Missing → the lane idles, counts `context_tables_missing`, logs once, re-probes every
   60 s. A claim failing with 42P01/42883 resets the probe.
2. **Enqueue** every interval (idempotent; the RPC creates jobs for D−1..D+1 of every completed scoring day and
   bumps changed ones at most every 10 min).
3. **Claim** in its own committed transaction (service-role claim GUC set), with the database clock at the claim
   (`floor(extract(epoch from clock_timestamp()))`), so the cutoff is on the same clock as `ingested_at`.
   A failing claim backs the lane off for 60 s and is logged once.
4. **Cutoff** (contracts §7.3): `causal_live` → claim time, or `cutoff_override` when the queue carries one (replay);
   `retrospective` → claim time. `generatedAt` = claim time always.
5. **Renew → load → renew → build → publish.** Loads run in one `REPEATABLE READ READ ONLY` transaction, so every
   table is read at one snapshot; the build (`ContextInputs.assemble` + `Engine.buildDay` + encoding) runs with
   no transaction open. A lost lease at either renew throws `.stale` (nothing failed; the queue owns the job).
6. **Publish** (`publish_physiology_context_v1`, own transaction). Outcomes:

   | RPC result | Lane |
   | --- | --- |
   | `applied: true, reason: published` | `published`, `cascaded += cascaded_days` |
   | `applied: false, reason: unchanged, context_revision` | `unchanged` (identical fingerprint pair; the RPC completed the job) |
   | `lease_lost` / `lease_expired` / `stale_revision` / `owner_retired` / NULL | `not_completed`; release = renew, then `fail` with the CLAIMED revision (a moved revision is a clean release) |
   | raises (22023 `invalid_physiology_context_*`) | `failed`, settled through `fail_physiology_context_v1` |

7. **Failure settlement.** Any other error → `fail_physiology_context_v1(token, claimed revision, reason)`; the
   returned status `failed`/`released` counts as `failures_persisted`, `lease_lost`/`lease_expired` as
   `failures_unsettled`. A lost connection leaves the lease to expire. Reasons are one line, ≤ 300 characters,
   prefixed `context_<kind>: `, first line only (Postgres DETAIL/CONTEXT lines can quote values), UUIDs masked.
8. **Document cap.** A document whose encoding exceeds 16,777,216 bytes (the RPC's `document_bytes` check, measured
   on the stored jsonb text, which is never shorter) is refused before it is sent: `documents_too_large`,
   deterministic failure (backoff, dead letter at 8).

## 4. Inputs

All raw reads are scoped by `user_id = $1 and device_id = $2`, bounded by the read window and ordered by the
table's identity; `assemble` additionally sorts every collection by a total content key (linear on sorted input),
so the arrival order of rows can never change a document (tested by shuffling). Availability of a raw row is
`ceil(extract(epoch from ingested_at))` (rounded UP so a causal cutoff stays conservative).

| Input | Source | Window | Contract type |
| --- | --- | --- | --- |
| Heart rate | `noop_hr_samples` | `[dayStart−30 h, dayEnd+6 h)` | `HeartRateObservation` |
| R-R | `noop_rr_intervals` minus `srcChannel` 2 and `tsSuspect` 1; then `DayScorer.oneTransportPerHour` on the visible beats | same | `BeatIntervalObservation` (ts, rrMs, seq, ord, channel) |
| Gravity / dynamic acceleration | `noop_gravity_samples` | same | `MotionObservation` |
| Steps | `noop_step_samples` | same | `StepObservation` |
| Skin temperature | `noop_skin_temp_samples`, `skinTempCelsius(raw:family:)` with `DayScorer.skinTempFamilyForDevice` (4.0: device anchor) | same | `SkinTemperatureObservation` |
| Wear | `noop_events` `WRIST_OFF*` / `WRIST_ON*` | same | `WearEventObservation` |
| Band sleep state | `noop_sleep_state_samples` | same | `BandSleepStateObservation` |
| Day snapshot | newest `scoring_snapshots_v2` of (user, device, D, `frwhoop-server-1`) with `computed_at ≤ cutoff` | — | measurements (§5), sleep sessions |
| Neighbouring / prior sleep | newest snapshot per day for D−14..D+1 (newest revision picked from the read index first, the `ActivityLane.loadPublishedNights` pattern), `computed_at ≤ cutoff` | — | `SleepSessionInput` |
| Workouts | `sessions` kind `workout` (source `detected`) / `manual_workout` (`manual`), availability = last write | read window | `WorkoutInput` |
| HART epochs (v1) | `activity_context_epochs`, every revision, `revision = result_revision`, availability = `computed_at` | read window | `ActivityEpochInput` |
| Decoder runs (v2) | `activity_context_runs` from the best document of each UTC day (`source_rank`) | read window | `ActivityIntervalInput` (class, confidence, sleep, wear) |
| Placement | `placement_intervals`, the device's rows and the owner's device-less rows overlapping the window | read window | `PlacementInput` (recordedAt = `recorded_at`) |
| Device | `devices` (family, firmware, source kind) | — | `DeviceRegimeInput` (vendor `whoop`, `oura` when the source kind says so; scoring `frwhoop-server-1`, series `frwhoop-series-2`; decoder version nil) |
| Profile | `profiles` (same defaults as `DayScorer.loadProfile`, age at day start) | — | series inputs only (steps/calories) |
| Exposures | `exposure_event_revisions` of the owner, every revision whose occurrence overlaps `[start of D−4, end of D+1)`; availability = `received_at` | — | `ExposureEventRevision` |
| History values | `physiology_context_daily_values.payload`, same device and mode, D−90..D−1 | — | `DailyValue` |
| History bouts | `physiology_context_bouts.payload`, same device and mode, D−3..D−1 | — | `ExertionBout` |
| Frozen references | `physiology_context_frozen_references.payload`, the device | — | `FrozenReference` |

Optional products (epochs, runs, placement, exposures, history) are read under a savepoint: a missing table or a
failing read empties that input, adds `<input>_unavailable` to `inputRevisions` and counts `inputs_unavailable`.
Raw streams, snapshots, device, profile and workouts are required (a failure ends the job and is retried).

**Causal mode.** `assemble` builds the full `DayInput`, calls `Engine.causalView` once (its exclusion counts go to
telemetry only: `causal_excluded_observations|records|exposure_revisions`, never into the document), and then
selects R-R transports and recomputes the series from the VISIBLE rows only, so a late upload can neither change
the transport chosen for an hour nor a series value. History is filtered by publication: daily values and bouts
whose publishing revision's `published_at` is after the cutoff, and frozen references registered after it, are
not read. Prior sleep published after the cutoff is dropped.

**Sleep sessions** (lead update, sleep notes §9.5): the input carries every session of the newest D−1, D and D+1
snapshots with `sourceDay`, `availableAt` = snapshot `computed_at`, `dataThrough` (snapshot `dataThrough`, unix s)
and `timezoneId` (snapshot `timezone`); `HistoryInput.priorSleep` carries D−14..D−2. `isNap` is passed only when
the snapshot says `true` (the scorer writes a constant `false`). Duplicate ids keep the newest publication.

`inputRevisions` (header, content-derived only, sorted): `scoring_snapshot` (result revision), `scoring_input`,
`metric_series` (`frwhoop-series-2`), `activity_epochs` / `activity_days` (max revision), `placement`
(`count:max revision`), `exposures` (`count:max availability`), `other_day_snapshots`, `history_daily_values`,
`history_bouts`, `frozen_references` (counts), plus `<input>_unavailable`.

## 5. Measurements and their supports (exact)

The series are recomputed with `IntradaySeries.build` from the scorer's inputs (day heart rate, transport-selected
R-R, day gravity and steps, profile, `restingHR` = snapshot `daily.resting_hr_bpm`, energy nil — energy only feeds
calories). Every support is clipped to the day exactly as the builder clips its inputs.

| Metric | Method id | Aggregation / windowS / units | Support of point at bucket `b` | Display bucket |
| --- | --- | --- | --- | --- |
| `hrv_rmssd` | `series.hrv_rmssd.5min` | `window` / 300 / ms | `[b, min(b+300, dayEnd))` | — |
| `resting_heart_rate` | `series.resting_hr.60min_min5` | `minimum_of_bins` / 3600 / bpm | `[max(dayStart, b−3300), min(b+300, dayEnd))` (trailing 12 bins, the bucket included) | `[b, b+300)` |
| `respiratory_rate` | `series.resp_rate.2min` | `window` / 120 / breaths_per_min | `[max(dayStart, b−60), min(b+60, dayEnd))` (trailing 2 minutes) | `[b, b+60)` |
| `heart_rate` | `context.heart_rate.5min_mean` (engine-derived) | — | engine | — |

Series source: `metric_series`, key `<metric>@<b>` (e.g. `hrv_rmssd_ms@1759651200`), input/result revision of the
day's snapshot (the series is published with that pass). `availableAt` = the latest `ingested_at` among the heart
rate, beat and motion rows inside the support (per-minute index). `sampleCount`/`coverage` are the point's.

Nightly snapshot values → `snapshot.<name>.night`, algorithm `frwhoop-server-1`, aggregation `session`, windowS =
support length (contract text), source `scoring_snapshot` key `daily.<field>` with the snapshot's input/result
revision, `availableAt` = snapshot `computed_at`:

| Field | Metric | Units | Support |
| --- | --- | --- | --- |
| `resting_hr_bpm` | `resting_heart_rate` | bpm | the scorer's primary session (longest, first on ties) — the session `AnalyticsEngine` takes it from |
| `hrv_rmssd_ms` | `hrv_rmssd` | ms | hull of the day's sessions (in-bed weighted pool) |
| `hrv_sdnn_ms` | `hrv_sdnn` | ms | hull |
| `resp_rate_bpm` | `respiratory_rate` | breaths_per_min | hull (median over sessions) |
| `skin_temp_c` | `skin_temperature` | degC | hull |
| `spo2_candidate_pct` | `spo2_candidate` | percent | hull; `sampleCount` = `spo2_candidate_samples` |

`sessionId` is set when the support is one session (resting HR always; the others when the day has one session).
`skin_temp_dev_c` is a deviation, not a measurement, and is not mapped. With one session the hull is the session.

## 6. Publish payload

`{bouts, daily_values, document, duration_ms, episodes, header, new_frozen_references, scoring_input_revision,
scoring_result_revision}`, each part encoded with `PhysiologyContext.encoder()`; the document is embedded byte for
byte. `header` = `{mode, day, finality, status, availability_cutoff, generated_at, contract_version,
schema_version, policy_fingerprint, input_fingerprint, versions}` taken from the document. `scoring_*_revision`
are the day snapshot's (JSON null without one). `duration_ms` = load + build. The normalized `daily_values` and
`bouts` are the document's items owned by the job's day (and mode for values) — the RPC rejects others; any left
out are counted as `products_out_of_day` and stay in the document.

## 7. Failure isolation

- Own connection, thread and lane state; the scoring lane's transactions are never touched. The lane's SQL contains
  no `insert`/`update`/`delete` and no call to `scoring_dirty_span`, `enqueue_scoring_v2`, `publish_scoring_*` or
  `publish_metric_series_*` (unit-tested over every statement); its only writes are the fenced RPCs.
- DB test `testAFailingContextLaneDoesNotStopScoring`: a trigger makes every context insert of one owner fail; the
  lane records and persists the failure (`consecutive_failures = 1`, one-line reason) and the scoring lane then
  publishes a new snapshot for new data.

## 8. Telemetry (heartbeat lane counters)

`claimed, published, unchanged, failed, cascaded, not_completed, superseded, failures_persisted,
failures_unsettled, enqueued, enqueue_failures, claim_failures, context_tables_missing, builds, build_ms_total,
build_ms_max, build_ms_mean, load_ms_total, load_ms_max, doc_bytes_total, doc_bytes_max, doc_bytes_mean,
inputs_rows_max, measurements_max, causal_excluded_observations, causal_excluded_records,
causal_excluded_exposure_revisions, inputs_unavailable, rows_skipped, products_out_of_day, day_window_mismatch,
documents_too_large`. `budgets.context` is added to the heartbeat; the queue-age entry `context` is added only
while the lane runs and the table exists.

## 9. Tests

Build/run (this machine needs the pkg-config paths for libpq):

```bash
cd Tools/CloudWorker
export PKG_CONFIG_PATH=/opt/homebrew/opt/libpq/lib/pkgconfig:/opt/homebrew/opt/openssl@3/lib/pkgconfig:/opt/homebrew/opt/zstd/lib/pkgconfig
export CPATH=/opt/homebrew/opt/libpq/include
swift build
swift test --filter ContextLane                     # unit + fixture; DB tests skip without a URL
# scratch database (own ports/dir; stop it with `down` and the same variables):
NARA_PIPELINE_DB_PORT=55471 NARA_PIPELINE_REST_PORT=55472 NARA_PIPELINE_AUTH_PORT=55473 \
  NARA_PIPELINE_DIR="$HOME/.cache/pc-worker-pipeline" ../../supabase/tests/e2e/pipeline_db.sh up
FRWHOOP_TEST_DB_URL=postgresql://postgres:pipeline-postgres-never-used-outside-tests@127.0.0.1:55471/postgres \
  swift test --filter ContextLaneDatabaseTests
# profiles (release, as the worker runs):
FRWHOOP_CONTEXT_PROFILE=1 FRWHOOP_TEST_DB_URL=... swift test -c release -Xswiftc -enable-testing \
  --filter 'ContextLaneProfileTests|ContextLaneDatabaseTests/testProfileAFullDayAgainstTheScoringLane'
```

| Suite | Tests | Result |
| --- | --- | --- |
| `ContextLaneTests` (config default-off / exact `1` / `DISABLE_LANES`, queue-age composition, claim parsing and cutoff per mode, windows incl. DST, series supports and clipping, method ids, series → measurement source/availability, snapshot parsing and nightly supports, neighbouring/prior sleep stamps, row parsers, transport selection, causal assembly, V10 replay byte identity, prior sleep cutoff, shuffle determinism, payload shape and verbatim document, null revisions, day-owned rows, publish/fail result parsing, error sanitizing, size cap, SQL write audit) | 30 | pass |
| `ContextLaneFixtureTests` | 1 | pass |
| `ContextLaneDatabaseTests` (scratch DB, migrations incl. 20261005120000) | 8 + 1 opt-in | pass |
| `ContextLaneProfileTests` | 2 opt-in | pass (numbers below) |
| Whole worker suite, no DB URL (before the backend merge) | 446, 31 skipped | 0 failures |
| Whole worker suite with the scratch DB (after all merges) | see §11 | see §11 |

DB tests (each creates its own owners/devices and deletes them):

| Test | V-case | What it shows |
| --- | --- | --- |
| `testScoredDayBecomesAStoredContextDocumentWithItsProducts` | V17 | Stored streams → REAL `ScoringLane` snapshot → enqueue/claim/publish → one current `physiology_context_days` row (policy fingerprint matches), job completed, document decodes, series + nightly + derived HR envelopes with the contracted supports, daily values and bouts rows equal to the document's, a stored bout decodes, `physiology_context_read_v1` returns `available` and `pairing.consistent = true`. Evidence run: 962 envelopes, 3 daily values, 1 bout (HART epochs + logged walk), 2 sleep episodes, status `available`. |
| `testRetryingTheSameInputsStoresNoNewRevision` | V15 retry | Re-dirtied day → `unchanged`, no new revision, job completed with `last_outcome = unchanged` |
| `testAWorkerThatDiesMidJobIsReplacedByOneThatPublishesOnce` | V15 restart | Claimed lease blocks others; expired → reclaimed → one current revision; the dead worker's renew fails (`.stale`) and its prebuilt publish is fenced (`lease_lost`) |
| `testAnExposureCorrectionRevisesTheDay` | V15 correction | `record_exposure_event_v1` dirties the day → new revision with a new input fingerprint; a corrected revision → another new revision |
| `testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff` | V10 | A `causal_live` replay with `cutoff_override` stores that cutoff, `generated_at` = claim time, no snapshot published after it; after late beats, a wear event and an exposure entered later, the same replay is `unchanged` with the same fingerprint |
| `testOwnersAndDevicesNeverSeeEachOthersData` | V16 | Two owners, a second device: only the device with data has envelopes; no product row under a foreign device |
| `testAFailingContextLaneDoesNotStopScoring` | V16 | §7 |
| `testTheLaneIdlesWhenTheTablesAreMissing` | deploy order | Against a database without the migration: idles, `context_tables_missing`, no claim |

## 10. Profiling (release build, Apple Silicon development machine)

Systems C, D, E, G real; A, B, F skeletons at measurement time — rerun after integration.

| Case | Rows read | Measurements / envelopes | Context time | Document | Scoring on the same streams |
| --- | --- | --- | --- | --- | --- |
| Representative day, in memory (86,400 HR, 92,775 beats, 86,400 gravity and steps, 90 days of history), retrospective | 353,095 | 2,020 / 2,308 | assemble 50 + build 109 + encode 304 = **465 ms** | **9.5 MB** | analyzeDay + series 115 ms (in memory) |
| same, causal_live at 20:00 | 353,095 | 1,682 / 1,917 | **378 ms** | 8.0 MB | — |
| Largest read window, in memory (all streams 1 Hz over 60 h, two R-R transports, 7,200 HART epochs, 2,000 decoder runs, 200 exposure revisions), retrospective | 1,426,902 | 2,016 / 2,304 | 71 + 374 + 1,408 = **1,854 ms** | **42.9 MB — over the 16 MiB publish cap** (refused by the worker) | 69 ms |
| same, causal_live | 1,426,902 | 1,678 / 1,912 | 1,377 ms | 35.3 MB | — |
| Stored full day through both lanes (scratch Postgres; 108,000 HR, 115,839 beats, 108,000 gravity) | 439,841 | 2,018 | load **731 ms** + build **809 ms**, wall 1.75 s (claim → publish) | 6.1 MB encoded, 6.7 MB stored | scoring day `last_duration_ms` **1,352 ms**; scoring wall for the 4 dirty days 7.0 s |

Before the systems were merged (all skeletons) the same representative day built in 201 ms with a 3.4 MB
document: the size growth is the per-envelope context (≈ 2.7 KB per envelope: `history` ≈ 1 KB, `sleep_wear`
≈ 0.5 KB, `activity`, `preceding`), times ≈ 2,300 envelopes a day, 1,440 of them one-minute respiratory points;
exposure references multiply `history` (the largest case). A debug build is 5–10× slower; time the release binary.

## 11. Whole-suite run after all merges

Recorded at the end of the session: see the final report (`swift test` with `FRWHOOP_TEST_DB_URL` set).

## 12. Deviations and open issues (for the lead)

1. **Document size (blocking at scale).** A typical day is 6–10 MB of jsonb; with a few exposure events a day the
   per-envelope `history.exposures` pushes documents past the RPC's 16 MiB cap, which the lane then dead-letters
   after 8 attempts. Options: shared per-day reference tables inside the document (envelopes keep ids), fewer
   respiratory envelopes (e.g. every 5th minute), or compressing `document`. Not changed here (engine/backend).
2. **Retrospective finality loop.** `Engine.inputFingerprint` ignores the cutoff in retrospective mode, so the
   provisional → final rebuild that `enqueue_physiology_context_days_v1` triggers (`finality_due`) publishes
   `unchanged`; the stored row stays `provisional` with its old cutoff, and the next enqueue bumps it again — an
   endless rebuild of every such day every enqueue interval (bounded by `p_limit`). Fix in the engine (put finality
   or `cutoff ≥ dayEnd + 30 h` into the fingerprint) or in the RPC (update finality/cutoff on `unchanged`, or do
   not re-bump a job whose last outcome was `unchanged` for the same fingerprints). Not reproducible today against
   live data within one session (needs a day crossing D + 30 h after its first publish).
3. **Session aggregate windowS.** Following the contract text, nightly methods carry `windowS` = session length.
   If System A keys regimes on `windowS`, every night is its own regime and nightly references never pool; System
   A/F should ignore `windowS` for `aggregation = session`, or the contract should say `windowS = 0` for sessions.
4. **Placement scope.** `PlacementInput` has no device-vs-owner scope; the lane passes both the device's and the
   owner's device-less records, sorted by content. A scope field would let System A prefer the device record.
5. **Replay history.** History tables keep only current values; a replay at an old cutoff drops values published
   after it (never leaks) but cannot recover the values the original live run saw.
6. **Availability basis.** `ingested_at` is the upload transaction's start; a row committed after the claim with an
   earlier `ingested_at` can be visible to a later replay at the same cutoff (bounded by the upload transaction's
   duration, seconds).
7. **Series values.** Recomputed, not read from `server_metric_series` (device-agnostic, selected device only).
   They equal the published buckets while the raw rows are unchanged since that scoring pass; R-R ties within
   `(ts, seq)` are ordered by `rrMs` here (scoring leaves that order unspecified).
8. `cutoff_override` is honoured for `causal_live` only (contracts §7.3); the queue clears it on publish.
9. Workouts come from `sessions` (`workout`, `manual_workout`); scoring no longer writes nights there, and if
   nothing writes workouts either, `workouts` is empty (bouts then rest on HART/strap evidence).
