# Physiology context — worker lane

Owner: worker. Branch `pc/worker`. Contract: [contracts.md](../contracts.md) §2, §3, §6, §6.1, §7. Migration read:
`supabase/migrations/20261005120000_physiology_context.sql` (backend-db, final at e5aca26a: envelope tables). Lead
branch merged through 2cfdaf4a (stored form; systems A, B, C, D, E, G real; F — references and change detection —
still a skeleton when these numbers were taken).

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
| Placement | `placement_intervals`, the device's rows and the owner's device-less rows overlapping the window | read window | `PlacementInput` (recordedAt = `recorded_at`; `scope` = `device` for the device's rows, `account` for device-less rows — the engine lets a device record win where they overlap, review RC-17) |
| Device | `devices` (family, firmware, source kind) | — | `DeviceRegimeInput`: vendor `whoop` (`oura` when the source kind says so), source kind; **family and firmware nil** (review RC-13: they are mutable columns of the current row and there is no history of them, so they are never stamped on a rebuilt day; the family still drives the skin conversion, as in the scorer); scoring `frwhoop-server-1`, series `frwhoop-series-2`; decoder version nil |
| Profile | `profiles` (same defaults as `DayScorer.loadProfile`, age at day start) | — | series inputs only (steps/calories) |
| Exposures | `exposure_event_revisions` of the owner, every revision whose occurrence overlaps `[start of D−4, end of D+1)`; availability = `received_at` | — | `ExposureEventRevision` |
| History values | `physiology_context_daily_values.payload`, same device and mode, D−160..D−1 (`ContextInputs.historyDays(for: policy)` = `windowDays` 90 + `autocorrelationGuardDays` 14 + `autocorrelationWindowDays` 56: the oldest scored episode day gets its full lookback, review R-F2) | — | `DailyValue` |
| History bouts | `physiology_context_bouts.payload`, same device and mode, D−3..D−1 | — | `ExertionBout` |
| Frozen references | `physiology_context_frozen_references.payload`, the device: retrospective every registered reference; causal those registered by the cutoff | — | `FrozenReference` |

Optional products (epochs, runs, placement, exposures, history) are read under a savepoint: a missing table or a
failing read empties that input, adds `<input>_unavailable` to `inputRevisions` and counts `inputs_unavailable`.
Raw streams, snapshots, device, profile and workouts are required (a failure ends the job and is retried).

**Causal mode.** `assemble` builds the full `DayInput`, calls `Engine.causalView` once (its exclusion counts go to
telemetry only: `causal_excluded_observations|records|exposure_revisions`, never into the document), and then
selects R-R transports and recomputes the series from the VISIBLE rows only, so a late upload can neither change
the transport chosen for an hour nor a series value. History is filtered by publication: daily values and bouts
whose publishing revision's `published_at` is after the cutoff, and frozen references registered after it, are
not read (how many history rows that left out goes to telemetry, `causal_history_after_cutoff`; never into the
document). Prior sleep published after the cutoff is dropped. A retrospective job reads every daily value and bout
of the range and every frozen reference registered for the device (the engine scores a back-filled day against the
registered reference, so it never registers a second "version 1").

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
support length (contract text; System A keys session aggregates by class, not length), source `scoring_snapshot`
key `daily.<field>` (plus notes, below) with the snapshot's input/result revision, `availableAt` = snapshot
`computed_at`.

"The day's sessions" = the snapshot's `sleep` array, which is exactly the scorer's `matched` list (every session
whose end falls on the local day). The **main-sleep group** is the scorer's own main-night rule over them:
`SleepStageTotals.mainNightGroupIndices` (two-tier bridge: gaps < 60 min, or < 90 min with an overnight onset;
learned-timing score) at the zone offset of the snapshot day's start (the snapshot's `timezone`, else the job's),
with no habitual midsleep (the server scorer passes none). Sessions flagged `is_nap: true` are excluded unless all
are. Support of the group = `[first fragment start, last fragment end)`.

| Field | Metric | Units | Canonical aggregate (AnalyticsEngine.analyzeDay) | Support |
| --- | --- | --- | --- | --- |
| `resting_hr_bpm` | `resting_heart_rate` | bpm | gated lowest 5-min bin of the primary session (the longest motion-backed session; HR-only only when the day has no other kind; a device-provided value for that session wins) | the primary session: longest snapshot session, first on ties |
| `hrv_rmssd_ms` | `hrv_rmssd` | ms | in-bed-weighted mean of per-session RMSSD over all the day's sessions (motion-backed preferred), naps included; only the main group when the over-count gate refused a main-group session | main-sleep group |
| `hrv_sdnn_ms` | `hrv_sdnn` | ms | 5-min SDNN index of the R-R inside all the day's sessions (motion-backed preferred) | main-sleep group |
| `resp_rate_bpm` | `respiratory_rate` | breaths_per_min | median of per-session RSA estimates over all the day's sessions (a vendor rate over all sessions wins) | main-sleep group |
| `skin_temp_c` | `skin_temperature` | degC | worn-gated mean over all the day's sessions | main-sleep group |
| `spo2_candidate_pct` | `spo2_candidate` | percent | mean of in-band (70–100) readings inside any of the day's sessions; `sampleCount` = `spo2_candidate_samples` | main-sleep group |

Source-key notes (`daily.<field>#<note>;<note>`, sorted; the key is plain when none applies — every one-session
day):

| Note | Fields | Meaning |
| --- | --- | --- |
| `aggregate_pools_sessions_outside_support=<n>` | pooled five | The aggregate's definition pools `n` of the day's sessions outside the support (naps, fragments not bridged into the main night). Whether each contributed is not published (beats, the over-count gate, the skin wear gate). |
| `support_spans_split_sleep_gap_s=<s>` | pooled five | Split main night: the support includes `s` seconds between fragments that no fragment measured. |
| `main_sleep_from_nap_flagged_sessions` | pooled five | Every session was flagged `is_nap: true`, so the rule ran over all of them. |
| `primary_session_outside_main_sleep` | resting HR | The longest session is not in the main group (a long daytime sleep that lost to a shorter overnight one on timing). |

`sessionId` is set when the support is exactly one session (resting HR always; the pooled fields when the main group
has one fragment). `skin_temp_dev_c` is a deviation, not a measurement, and is not mapped.

Known divergences from the scorer, both rare: the snapshot does not publish `hrOnly`, so the worker's primary
session is the longest of ALL sessions (the scorer prefers a motion-backed one when the day has both kinds); and the
engine's own main/nap classification (System C) uses a learned habitual midsleep, the scorer's (and so the worker's
support) does not. Remaining limit (engine-side, see review-worker-repairs.md): a split night whose inter-fragment
gap is ≥ 10 % of the hull is still judged `unknown` over the single-interval support and has no `*.sleep_night`
value.

## 6. Publish payload (stored form, contracts §6.1)

`{bouts, daily_values, document, duration_ms, envelope_tables, episodes, header, new_frozen_references,
scoring_input_revision, scoring_result_revision}`, each part encoded with `PhysiologyContext.encoder()` and embedded
byte for byte. `document` is the SUMMARY from `StoredDocument.split(doc)` (envelopes empty, `envelope_index` set);
`envelope_tables` = `[{envelope_count, metric, table}]`, one interned `EnvelopeTable` per metric in `MetricKind`
order (`join(summary, tables) == doc`, unit-tested on the payload itself). `header` = `{mode, day, finality, status,
availability_cutoff, generated_at, contract_version, schema_version, policy_fingerprint, input_fingerprint,
versions}` from the document. `scoring_*_revision` are the day snapshot's (JSON null without one). `duration_ms` =
load + build. The normalized `daily_values` and `bouts` are the document's items owned by the job's day (and mode
for values) — the RPC rejects others; any left out are counted as `products_out_of_day` and stay in the document.
Before sending, the summary and the largest table must each fit the 16 MiB jsonb cap, else `documents_too_large`
(deterministic failure).

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
summary_bytes_total, summary_bytes_max, summary_bytes_mean, table_bytes_total, table_bytes_max, table_bytes_mean
(per job, all tables together; `doc_bytes_*` = summary + tables), inputs_rows_max, measurements_max,
causal_excluded_observations, causal_excluded_records,
causal_excluded_exposure_revisions, causal_history_after_cutoff, inputs_unavailable, rows_skipped, products_out_of_day, day_window_mismatch,
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
| `ContextLaneDatabaseTests` (scratch DB, final migration e5aca26a) | 8 + 1 opt-in | pass |
| `ContextLaneProfileTests` | 2 opt-in | pass (numbers below) |
| Whole worker suite, no DB URL (early, before the backend merge) | 446, 31 skipped | 0 failures |
| Whole worker suite with the scratch DB (after every merge) | 455, 4 skipped (the 3 opt-in profiles and the pre-existing `PushBatchTests.testEmbeddedFixturesMatchOnDiskCorpus`) | 0 failures |

DB tests (each creates its own owners/devices and deletes them):

| Test | V-case | What it shows |
| --- | --- | --- |
| `testScoredDayBecomesAStoredContextDocumentWithItsProducts` | V17 | Stored streams → REAL `ScoringLane` snapshot → enqueue/claim/publish → one current `physiology_context_days` row (policy fingerprint matches) holding the summary, its `physiology_context_envelope_tables` joined back (`StoredDocument.join`), job completed, series + nightly + derived HR envelopes with the contracted supports, daily values and bouts rows equal to the document's, a stored bout decodes, `physiology_context_read_v1` returns `available` and `pairing.consistent = true`. Evidence run: 962 envelopes (918 with an eligible verdict), 3 daily values, 1 bout (HART epochs + logged walk), 2 sleep episodes, status `available`. |
| `testRetryingTheSameInputsStoresNoNewRevision` | V15 retry | Re-dirtied day → `unchanged`, no new revision, job completed with `last_outcome = unchanged` |
| `testAWorkerThatDiesMidJobIsReplacedByOneThatPublishesOnce` | V15 restart | Claimed lease blocks others; expired → reclaimed → one current revision; the dead worker's renew fails (`.stale`) and its prebuilt publish is fenced (`lease_lost`) |
| `testAnExposureCorrectionRevisesTheDay` | V15 correction | `record_exposure_event_v1` dirties the day → new revision with a new input fingerprint; a corrected revision → another new revision |
| `testACausalReplayIsUnchangedByDataThatArrivedAfterItsCutoff` | V10 | A `causal_live` replay with `cutoff_override` stores that cutoff, `generated_at` = claim time, no snapshot published after it; after late beats, a wear event and an exposure entered later, the same replay is `unchanged` with the same fingerprint |
| `testOwnersAndDevicesNeverSeeEachOthersData` | V16 | Two owners, a second device: only the device with data has envelopes; no product row under a foreign device |
| `testAFailingContextLaneDoesNotStopScoring` | V16 | §7 |
| `testTheLaneIdlesWhenTheTablesAreMissing` | deploy order | Against a database without the migration: idles, `context_tables_missing`, no claim |

## 10. Profiling (release build, Apple Silicon development machine)

After merging the lead branch through 272d8c06 (systems A, B, C, D, E, G real; F skeleton). Times are
assemble + `Engine.buildDay` + split/encode; "plain" is the unsplit document.

| Case | Rows read | Measurements / envelopes | Context time | Stored form | Scoring on the same streams |
| --- | --- | --- | --- | --- | --- |
| Representative day, in memory (86,400 HR, 92,775 beats, 86,400 gravity and steps; 90 days of history), retrospective | 353,095 | 2,020 / 2,308 | 47 + 432 + 553 = **1,034 ms** | summary **42 KB** + tables **3.9 MB** (largest 2.3 MB, respiratory); plain 13.7 MB | analyzeDay + series 107 ms (in memory) |
| same, causal_live at 20:00 | 353,095 | 1,682 / 1,917 | **805 ms** | 38 KB + 3.2 MB (plain 11.4 MB) | — |
| Largest read window, in memory (all streams 1 Hz over 60 h, two R-R transports, 7,200 HART epochs, 2,000 decoder runs, 200 exposure revisions), retrospective | 1,426,902 | 2,016 / 2,304 | 67 + 688 + 2,305 = **3,061 ms** | 314 KB + **32.5 MB** (respiratory table **20.2 MB > 16 MiB**: refused); plain 46.5 MB | 63 ms |
| same, causal_live | 1,426,902 | 1,678 / 1,912 | 2,391 ms | 252 KB + 27.0 MB (largest 16.8 MB: refused) | — |
| Stored full day through both lanes (scratch Postgres, final migration; 108,000 HR, 115,839 beats, 108,000 gravity) | 439,840 | 2,014 | load **677 ms** + build **948 ms**, wall 1.73 s (claim → publish) | summary 34 KB + tables 3.17 MB | scoring day `last_duration_ms` **1,043 ms**; scoring wall for the 4 dirty days 5.0 s |

Earlier points: with every system a skeleton the representative day built in 201 ms (3.4 MB plain); with C, D, E, G
real and before the stored form, 465 ms and 9.5 MB plain. The plain size is per-envelope context (≈ 2.7–6 KB per
envelope) × ≈ 2,300 envelopes a day (1,440 one-minute respiratory points); the stored form interns the repeated
sub-objects. Exposure references still multiply the respiratory table (largest case). A debug build is 5–10× slower;
time the release binary.

## 11. Whole-suite run after all merges

`swift test` with `FRWHOOP_TEST_DB_URL` set (scratch DB, final migration): 455 tests, 4 skipped, 0 failures. One
earlier run failed `ActivityStreamDaysDatabaseTests.testADayWithScoringButNoMeasurementsCompletesWithoutADocumentAndStaysDone`
because two owners from an earlier V17 run had leaked: deleting an owner who has a `sessions` row trips the existing
`bump_user_revision` trigger (it upserts `user_sync_state` for the user being deleted, FK violation), so the account
cascade failed and their queued stream days were claimed by the activity test. The context tests now delete
`sessions` rows first and fail loudly if an owner cannot be removed. The trigger behaviour itself is pre-existing.

## 12. Deviations and open issues (for the lead)

1. **Table size with many exposures.** The stored form brings a representative day to 42 KB + 3.9 MB, but the
   largest read-window case (200 exposure revisions over D−4..D+1) still yields a 20 MB respiratory table: the
   per-row `exposures` / `exposureCoverage` pools do not intern well when every minute sees a different set. The
   lane refuses a table over 16 MiB as a deterministic failure (dead letter after 8). Engine/System E decision:
   intern exposure refs per event, or cap respiratory envelopes.
2. **Retrospective finality loop (reproduced).** `Engine.inputFingerprint` ignores the cutoff in retrospective
   mode, so the provisional → final rebuild that `enqueue_physiology_context_days_v1` triggers (`finality_due`)
   publishes `unchanged`; the stored row stays `provisional` with its old cutoff, and every later enqueue bumps it
   again — a rebuild of every such day every enqueue interval (bounded by `p_limit`). Reproduced on the scratch DB
   with a throwaway probe (a settled day whose current row was set back to provisional with a pre-D+30 h cutoff):
   three enqueue rounds each returned 1 bump with `reasons = {finality_due}`, each publish was `unchanged`, the row
   stayed provisional. (When the day's history changed meanwhile the rebuild publishes a new, final revision and the
   loop ends, which is why it is easy to miss.) Fix in the engine (put finality, or `cutoff ≥ dayEnd + 30 h`, into
   the retrospective fingerprint) or in the RPC (raise finality/cutoff on `unchanged`, or skip `finality_due` when
   the last outcome for the same fingerprints was `unchanged`).
3. **Session aggregate windowS.** Following the contract text, nightly methods carry `windowS` = session length.
   If System A keys regimes on `windowS`, every night is its own regime and nightly references never pool; System
   A/F should ignore `windowS` for `aggregation = session`, or the contract should say `windowS = 0` for sessions.
4. **Placement scope** (resolved, RC-17). The lane passes every record with `scope` (`device` / `account`); the
   engine resolves device over account.
5. **Replay history** (documented, P5 / RC-18). History tables keep only current values, and placement corrections
   edit rows in place; a replay at an old cutoff loses (never leaks) what the original live run saw. Exact cases and
   the storage fix: review-worker-repairs.md. Telemetry: `causal_history_after_cutoff`.
6. **Availability basis.** `ingested_at` is the upload transaction's start; a row committed after the claim with an
   earlier `ingested_at` can be visible to a later replay at the same cutoff (bounded by the upload transaction's
   duration, seconds).
7. **Series values.** Recomputed, not read from `server_metric_series` (device-agnostic, selected device only).
   They equal the published buckets while the raw rows are unchanged since that scoring pass; R-R ties within
   `(ts, seq)` are ordered by `rrMs` here (scoring leaves that order unspecified).
8. `cutoff_override` is honoured for `causal_live` only (contracts §7.3); the queue clears it on publish.
9. Workouts come from `sessions` (`workout`, `manual_workout`); scoring no longer writes nights there, and if
   nothing writes workouts either, `workouts` is empty (bouts then rest on HART/strap evidence).
