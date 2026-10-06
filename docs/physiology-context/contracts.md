# Physiology context — contracts

Branch `feat/physiology-context-20261005`, based on `nara/main` `15c0627e`. This file is the shared contract for every
workstream. The Swift types it describes are compiled code in
`Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyContext/`; when this text and the code disagree, the code
signature wins and this file is corrected.

- [1. Scope and naming](#1-scope-and-naming)
- [2. Temporal semantics](#2-temporal-semantics)
- [3. Core Swift contract](#3-core-swift-contract)
- [4. System contracts (A–G)](#4-system-contracts-ag)
- [5. Daily values, references and episodes](#5-daily-values-references-and-episodes)
- [6. Persistence](#6-persistence)
- [7. Worker lane](#7-worker-lane)
- [8. HTTP API](#8-http-api)
- [9. App](#9-app)
- [10. Exposure events end to end](#10-exposure-events-end-to-end)
- [11. Ownership map](#11-ownership-map)
- [12. Reason codes](#12-reason-codes)
- [13. Versions](#13-versions)

## 1. Scope and naming

- Everything lives under the namespace `PhysiologyContext` (Swift) and the prefix `physiology_context_` /
  `exposure_event` (SQL). Nothing in this layer reuses or changes an existing canonical field, score, provider gate or
  baseline. The concurrent, uncommitted activity-classifier work in the `nara-physiology-audit` worktree adds a
  module-level `ContextBaselines.swift` (`ContextFamily`, `ContextMetricDefinition`, …); the nested namespace keeps
  every name here collision-free with it.
- Files are prefixed `PC` and sit in `PhysiologyContext/`. Tests are `Tests/StrandAnalyticsTests/PC*Tests.swift`.
- JSON is produced by `PhysiologyContext.encoder()` (`convertToSnakeCase`, sorted keys) and read by
  `PhysiologyContext.decoder()`. Codable types use camelCase without consecutive capitals and never encode a Swift
  dictionary (keyed data is an array of named entries). NaN and infinity must never reach the encoder (it throws).

## 2. Temporal semantics

| Rule | Contract |
| --- | --- |
| Time unit | Unix seconds (`Int`), UTC. Intervals are half-open `[start, end)` (`PhysiologyContext.Interval`). |
| Day | Local day `yyyy-MM-dd` in `DayIdentity.timezoneId`; `dayWindow` is `[local midnight, next local midnight)` (23 h / 25 h on DST days, `Engine.dayInterval`). |
| Sleep ownership | Existing rule: a sleep session belongs to the local day containing its **end**. |
| Bout ownership | The local day containing the bout **start**. |
| Availability | Every observation/record carries `availableAt` (server `ingested_at`, exposure `received_at`). Unknown availability falls back to sensor time and is reported (`InputContractReport.availabilityBasis`). |
| Causal live | `mode = causal_live`. `Engine.causalView` removes every observation/record with sensor time ≥ cutoff or availability > cutoff **before any system runs**. A live document must not read a later sleep end, a next-day awakening, smoothing, or a later correction, and does not record how much was excluded (that count is itself future information). |
| Retrospective | `mode = retrospective`. May use the whole day, later days and later corrections. `final` once `availabilityCutoff ≥ dayWindow.end + 30 h` (`JoinConfig.finalAfterDayEndS`), else `provisional`. |
| Storage | Causal and retrospective documents are separate rows (`mode` is part of the key) and are never presented as each other. |
| Determinism | `Engine.buildDay(input, history, policy)` reads no clock. Equal inputs (after the causal view) and policy give byte-identical documents; `header.inputFingerprint` is computed over the inputs actually used. |
| History | `HistoryInput` items from the document's day or later are dropped (`history_from_future_dropped`). References are built from strictly earlier days, so an observation is always scored before it can enter an adaptive reference. |
| Revisions | Overlapping/revised activity records resolve per second by `revision`, then `availableAt`, then a stable id; each second counts once (`IntervalAlgebra.resolve`). |
| RR identity | `(ts, rrMs, seq)`. Equal RR values are distinct beats; de-duplication is by observation identity only. Storage is whole-second; no sub-second beat time is reconstructed. |
| Ordering | `SanitizedObservations` streams are sorted by `ts` (then identity); every system may rely on it. |
| No bridging | Nothing interpolates across a disconnection, source change, clock reset or unsupported transition (`SanitizedObservations.breaks`). |

## 3. Core Swift contract

`PCContract.swift` (lead) defines the shared types. The key ones:

- **`DayInput`** — identity, mode, cutoff, `generatedAt`; raw observations (`HeartRateObservation`,
  `BeatIntervalObservation`, `MotionObservation`, `StepObservation`, `SkinTemperatureObservation`,
  `WearEventObservation`, `BandSleepStateObservation`); context records (`MeasurementInput`, `SleepSessionInput`,
  `WorkoutInput`, `ActivityEpochInput` (v1, HR-free), `ActivityIntervalInput` (v2, HR-dependent), `PlacementInput`,
  `DeviceRegimeInput`, `ExposureEventRevision`); `inputRevisions`.
- **`HistoryInput`** — earlier `DailyValue`s, `ExertionBout`s, `FrozenReference`s and sleep sessions.
- **`MeasurementInput`** — a published value with its **actual support interval** (`support`) and the display bucket
  when different. The worker produces these (§7.2).
- **`MeasurementEnvelope`** (spec §6.1):

| Field group | Envelope fields |
| --- | --- |
| Identity | `id` (`<method.id>@<start>-<end>`), `metric`, `method` (`MethodRef`: id, algorithm version, aggregation, window, units), `source` (`SourceRef`: product, key, input/result revision), `regimeKey` → `DayDocument.regimes.registry` |
| Time | `support`, `displayBucket`, `localTime` (zone, offset, local day, seconds of day); document header: cutoff, `generatedAt` |
| Validity | `validity` (`SignalValidity`: state, reasons, coverage, observed seconds, diagnostics, confidence kind) |
| Activity | `activity` (HR-independent `ActivityComposition` over the whole support), `decoderActivity` (v2, HR-dependent, display only), `preceding` (`PrecedingHistory`) |
| Sleep and wear | `sleepWear` (`SleepWearContext`: states, evidence sources, HR dependence, reasons) |
| History | `history` (`HistoryContext`: wake reference, recent bouts, 24/48/72 h exertion, exposure refs, exposure category status) |
| Baseline | `comparisons` (`ReferenceComparison`s for envelopes that are themselves daily values) |
| Interpretation | `finality`; document header: mode, versions, policy/input fingerprints |

- **`ActivityComposition`** invariant: `Σ labels.seconds + unknownS + uncoveredS == intervalS` (tolerance 1e-6 s).
  `IntervalAlgebra.reconciles` checks it. Shares use the **whole** interval as denominator. `mixed` when two labels
  each hold ≥ 10 %; `dominantLabel` only at ≥ 90 % of the whole interval.
- **Activity sources** (`ActivitySource`): `hart_epochs` (v1 HART, IMU only), `strap_motion` (gravity / dynamic
  acceleration + step counter), `decoder_intervals` (v2, reads HR — never eligibility evidence for an HR-derived
  metric), `none`. The engine uses the HR-independent source with more covered seconds over each support
  (`Engine.preferredTrack`, HART on ties).
- **Vocabulary** (`MotionVocabulary`): stationary = `stationary, still, low_movement, sleeping, lying_down, sitting,
  sitting_desk, standing`; locomotion = `walking, running, stepping, brisk_walking, cycling`; other movement =
  `other_movement, fidgeting, light_activity, vigorous_activity`. Anything else, and `nil`, is unknown.
- **`DayDocument`** — header, status, input report, availability matrix, regime timeline (+ registry), envelopes,
  sleep summary, bouts, exertion windows, exposure summary, daily values, comparisons, new frozen references,
  episodes, multi-signal summaries, functional summary, feature evaluations, dependence notes, selection summaries.
- **`Policy`** — every tunable, grouped per system; `Policy.fingerprint` (FNV-1a of the canonical encoding plus the
  feature-registry version) goes into every cache and reprocessing key.

The engine derives one measurement family itself: 5-minute heart-rate means on the local-midnight grid from samples
in 30–220 bpm (`context.heart_rate.5min_mean`, source `context_derived`). Windows without samples produce nothing.

## 4. System contracts (A–G)

Signatures are compiled in the files named. A workstream may add fields (with defaults), types, private helpers and
config fields in its own files, and must keep every public signature below. Each system declares its reason codes as
static constants plus a `reasonCodes` array.

### A — Signal validity and regime (`PCSignalValidity.swift`, `PCMotionEvidence.swift`)

| Function | Must |
| --- | --- |
| `SignalValidityEngine.sanitize(_:config:)` | De-duplicate by observation identity only (HR: one value per `ts`; conflicting duplicates are rejected and counted, not averaged; RR: `(ts, rrMs, seq)`); detect non-monotonic time, clock resets / large backward jumps, out-of-range units (bpm outside 20–250, RR outside 50–30000 ms rejected as contract failures; plausibility is a separate validity step), timestamps beyond the read window; produce `breaks` at disconnections (gaps), clock resets and source changes; set `availabilityBasis`. Never drop an observation silently; every rejection is counted in `InputContractReport.counts` with a reason. |
| `assess(_:observations:motion:config:)` | Separate decisions per metric. HR: coverage, plausible range, flatline. HRV (RMSSD/SDNN): valid adjacent beat pairs (gap-aware, reuse `HRVAnalyzer.cleanRRGapAware` / `classifyCoverage` / `beatValuesAreTrustworthy`), rejected counts, over-count diagnostics, motion share; SDNN only comparable at equal window lengths. Respiratory rate: beats, breath intervals, motion. Skin temperature: in-band samples and worn evidence; never core. SpO2 candidate: always `unverified`. PPG waveform quality: `unsupported` (no qualified waveform). A physiological extreme is not an artifact by itself. |
| `regimeTimeline(_:config:)` | Placement segments from `PlacementInput` (unknown before the first record; **never back-filled** from today's placement); boundaries at placement, device family, firmware, source kind and method changes. |
| `regime(for:timeline:device:)` | The measurement's regime; `key` = FNV-1a of (vendor, family, source kind, firmware, placement, method id, aggregation, window, units). Equal key ⇒ comparable. |
| `comparability(_:_:config:)` | `.comparable(rule:)` only under a documented rule; different vendor, placement, method, aggregation or window are always incompatible. |
| `availabilityMatrix(_:observations:config:)` | One entry per metric × assessment × source, including explicit `unsupported` / `unverified` rows (PPG waveform, SpO2, core temperature, posture). |
| `MotionEvidence.strapTrack(motion:steps:window:config:)` | Per-second labels `still` / `low_movement` / `stepping` / `other_movement` from dynamic acceleration and the step counter (HR-free), resolved into spans; seconds with no motion sample are uncovered. |

### B — Eligibility (`PCEligibility.swift`)

- `Eligibility.comparisons(for:method:)`: which `ComparisonKind`s apply to a metric/method.
- `Eligibility.evaluate(...)`: `eligible` / `ineligible` / `unknown` with reasons and evidence.
  - **Stable awake rest** starts from `ActivityContextJoin.restingEligibility`'s policy (≥ 90 % stationary over the
    whole support, ≥ 90 % qualified coverage, ≥ 300 s preceding stillness, awake and worn evidence) but evaluates it
    on the context layer's composition / preceding history. Unknown awake or wear evidence → `unknown`, never
    eligible. Recent exertion and recovery history are recorded as evidence (and as a configurable exclusion).
  - **Sleep measurement**: inside a supported sleep episode (staging not required).
  - **Activity response**: inside or within the post-bout window of a supported bout.
  - Never gate on the target metric's value. A target-dependent quality gate is listed in `targetDependentGates`.
  - Evidence from HR-dependent sources is listed in `dependsOn` (e.g. `sleep_detector_uses_heart_rate`).
  - Wrist posture stays a likelihood; no confirmed standing/orthostatic event from arm orientation.
- `Eligibility.selection(envelopes:observations:dayWindow:)`: per (comparison, metric) counts, represented share of
  observed time, exclusion reasons.

### C — Sleep and rhythm (`PCSleepRhythm.swift`)

- `episodes(...)`: main sleep vs nap (scorer's `isNap` when present, else a documented rule), split sleep, cross-
  midnight, DST, incomplete nights (`complete = false` when the session reaches the cutoff in causal mode), day
  ownership by end.
- `sleepWear(for:...)`: sleep evidence from detected sessions (HR-dependent) and band sleep state; awake only from
  positive evidence (e.g. inside a period the detector covered and found no sleep) and flagged HR-dependent; wear from
  wear events and HR-signal presence. Quiet motion never establishes awake, asleep or worn.
- `wakeReference(at:...)`: seconds since the supported awakening before `ts`; never a future awakening in causal mode.
- `summary(...)`: durations, naps, fragmentation where supported, recent sleep loss and timing change vs prior nights,
  local and wake-relative timing with explicit zone, rhythm descriptors as proxies (not endogenous phase), dependence
  notes (sleep labels read HR/RR).

### D — Exertion bouts (`PCExertionBouts.swift`)

- `detect(...)`: bouts from HART epochs, strap motion / steps and workouts — never from HR. Deterministic ids. Pre-bout
  context, HR response (pre-bout reference, during-bout summary), respiratory response only when the method supports
  it (else explicit unavailable), recovery at supported offsets with signed return toward the pre-bout reference,
  time-to-return only when observed, censoring (`disconnect`, `continued_movement`, `next_bout`, `cutoff_reached`,
  `no_follow_up`). Overlapping bouts: each outcome is attributed to exactly one bout.
- `recentRefs(before:...)`, `windows(endingAt:...)` (24/48/72 h, with observed coverage), `dailyValues(...)`.
- Matching keys record available workload information; speed, grade, load and ambient conditions are recorded as
  unavailable, not invented.

### E — Exposures (`PCExposures.swift`)

- `current(_:mode:cutoff:)`: latest available revision per event; `retracted` events leave current state but keep
  history (`revisionCount`).
- `refs(for:...)`, `categoryStatus(for:...)` (`recorded` / `denied` / `candidate_only` / `unrecorded`),
  `daySummary(...)` (event-aligned before/after descriptions with concurrent events and confounding reasons; never a
  causal label), `affectedDays(...)` (mirrored by SQL invalidation).

### F — References and change (`PCReferences.swift`, `PCChangeDetection.swift`, `PCRobustStats.swift`)

See §5.

### G — Functional features and registry (`PCFunctional.swift`)

- `Functional.daySummary(...)`: bout lengths, cadence and variability where measurable, pauses, transitions,
  fragmentation, rest after activity, activity per observed wear time; `totalsComparable = false` when wear coverage
  is insufficient.
- `Functional.dailyValues(...)`: wear-normalized values only, or totals only when comparable.
- `FeatureRegistry.definitions` / `evaluate(...)`: versioned definitions with required sensors, placement, labels,
  reference assessments, timing, intended population, units, validation status. Specialized definitions (gait speed,
  stride length, tremor, respiratory events, autonomic indices, symptom classifiers) are registered and evaluate to
  `unavailable` with the missing evidence named.

## 5. Daily values, references and episodes

- **`DailyValue`** is the unit of every reference and episode: one value per (day, `seriesKey`, `regimeKey`, mode).
  `seriesKey` names the context condition. Producers: `ContextReferences.dailyValues` (envelopes),
  `ExertionBouts.dailyValues`, `Functional.dailyValues`, and the engine (`coverage.motion_observed_s`).
  `supportCount`/`supportUnit` count independent units (nights, windows, bouts), never overlapping seconds.
- Series keys (initial set; owners may add, never rename):

| Series key | Producer | Definition |
| --- | --- | --- |
| `hrv_rmssd.sleep_night` | F | Nightly snapshot RMSSD whose envelope is sleep-measurement eligible |
| `resting_hr.sleep_night` | F | Nightly snapshot resting HR, sleep-measurement eligible |
| `resp_rate.sleep_night` | F | Nightly snapshot respiratory rate, sleep-measurement eligible |
| `skin_temp.sleep_night` | F | Nightly snapshot skin temperature (relative use only) |
| `hrv_rmssd.stable_awake_5min` | F | Median of stable-awake-eligible 5-minute RMSSD windows (≥ configured windows) |
| `heart_rate.stable_awake_5min` | F | Median of stable-awake-eligible 5-minute HR means |
| `heart_rate.sleep_night`, `hrv_sdnn_index.sleep_night` | F | Nightly snapshot HR / SDNN index (whole-session SDNN is excluded: length-dependent) |
| `hrv_sdnn.stable_awake_5min`, `<stable-awake series>.band_HH_HH` | F | 5-minute SDNN windows; local-time band strata (conditioned view only) |
| `hr_response.<match key>` | D | Median HR response of matched bouts |
| `hr_recovery_60s.<kind>` | D | Median post-effort HR decline at +60 s from uncensored readings |
| `functional.*` | G | Functional features (wear-normalized) |
| `coverage.motion_observed_s` | engine | Observed motion seconds of the day |

- **Views** (`ReferenceView`): `recent` (short trailing window of supported days), `rolling` (longer trailing
  window), `frozen` (explicitly versioned `FrozenReference`, never replaced; a historical reference, not a healthy
  baseline; selection rule recorded), `conditioned` (hierarchy / partial pooling for sparse contexts with
  `pooledContribution`). All references use only days strictly before the scored day and only values whose regime is
  comparable.
- **`ReferenceComparison`** carries the signed difference in original units, the transformed difference (e.g. ln for
  RMSSD), the robust distance (`robustZ`, never a probability), the center uncertainty when estimable, status and
  reasons. Scale floors are explicit; zero MAD never produces infinite certainty.
- **`ChangeEpisode`** states: `usual_variation`, `transient_deviation`, `recurring_episode`, `persistent_shift`,
  `insufficient_evidence`. Ids are deterministic from (series, regime, start day, direction, policy). Regime boundaries
  split series and are reported separately from unexplained changes.
- **`MultiSignalSummary`** counts dependence groups (`DependenceNote.group`), not metrics.

## 6. Persistence

Migration owner: backend-db. One migration file `supabase/migrations/20261005120000_physiology_context.sql` (and,
if needed, `20261005121000_exposure_events.sql`), additive only, in the house style (header, `begin; set local
lock_timeout='5s'; set local statement_timeout='60s'; … commit;`, RLS + explicit revokes, `security definer set
search_path = ''`, function EXECUTE revoked from `public, anon, authenticated`). Every user-owned table has
`user_id uuid not null references auth.users(id) on delete cascade` (or `owner` for exposure tables, matching the
newest convention) and device-scoped tables carry the composite FK to `devices(user_id, id) on delete cascade`. New
service RPCs are added to `SERVICE_ONLY_FUNCTIONS` in `supabase/functions/tests/auth_isolation_sql_test.ts`; no new
client-callable function.

| Table | Grain / key | Lifecycle |
| --- | --- | --- |
| `physiology_context_jobs` | (user_id, device_id, day, mode) | Queue. `input_revision` / `completed_revision`, lease token / until, failures, dead letter, `not_before`, `dirty_at`, `fingerprint`, `reasons text[]`, `cutoff_override bigint` (replay). Same shape as `scoring_jobs_v2`. |
| `physiology_context_days` | `context_revision` (identity PK); unique current row per (user, device, day, mode) where `superseded_by is null`; unique (user, device, day, mode, policy_fingerprint, input_fingerprint) | One immutable row per published revision: header columns + `document jsonb` (the **summary** document from `StoredDocument.split`: envelopes empty, `envelope_index` set) + `document_bytes`. A publish with an identical fingerprint pair is a no-op returning the existing revision. Retention keeps the current row; a superseded row is deleted once it has been superseded for 24 h. |
| `physiology_context_envelope_tables` | (context_revision, metric); FK to `physiology_context_days(context_revision) on delete cascade` | One interned `EnvelopeTable` per metric of a published revision (`envelope_table jsonb`, `envelope_count`, `table_bytes`, user_id/device_id for RLS). A metric page reads only its table. |
| `physiology_context_daily_values` | (user, device, mode, day, series_key, regime_key) | Replaced for (user, device, mode, day) on each publish. History source for references. |
| `physiology_context_bouts` | (user, device, mode, bout_id) | Replaced for (user, device, mode, day) on publish. |
| `physiology_context_episodes` | (user, device, mode, episode_id) | Replaced for (user, device, mode) only when the publishing day ≥ the latest day already published for that key (an older day's view never overwrites a newer one). |
| `physiology_context_frozen_references` | (user, device, reference_id); unique (user, device, series_key, regime_key, version) | Insert-only (`on conflict do nothing`); an update trigger rejects changes. |
| `exposure_event_revisions` | (owner, event_id, revision) | Immutable history (no update; delete only by account cascade). |
| `exposure_events` | (owner, event_id) | Current state (latest revision). |

RLS: owner `select` for authenticated on day/value/bout/episode/reference/exposure tables (`(select auth.uid()) =
user_id|owner`); all writes service-role only; jobs table service-only.

RPCs (all service-only, fenced like the activity lane):

| RPC | Contract |
| --- | --- |
| `enqueue_physiology_context_days_v1(p_limit int) → int` | From `scoring_jobs_v2` completions (algorithm `frwhoop-server-1`, last 120 days): dependency fingerprint over completed revisions of D-1..D+1, the activity day row, placement and exposure revisions in the window; enqueue/bump when it changed and `now() - dirty_at ≥ 10 min`; mode `causal_live` for the owner's local today, `retrospective` for earlier days; also enqueue `retrospective` for a closed day with no retrospective row and for a provisional retrospective row once `now ≥ day end + 30 h`. Skips retired owners. Never touches scoring tables. |
| `invalidate_physiology_context_span_v1(p_user, p_device, p_from date, p_to date, p_reason text) → int` | Bumps or creates jobs for each day (device null ⇒ every device of the user); today → `causal_live`, earlier → `retrospective`; span capped at 120 days. |
| `claim_physiology_context_v1(p_worker text, p_lease_seconds int) → setof record` | `for update skip locked`, owner fairness, `causal_live` before `retrospective`, `not_before ≤ now()`, not dead-lettered, `completed_revision < input_revision`. Returns user_id, device_id, day, mode, input_revision, lease_token, timezone_id, cutoff_override. |
| `renew_physiology_context_v1(p_token, p_lease_seconds)` / `fail_physiology_context_v1(p_token, p_revision, p_error)` | Backoff `min(3600, 5·2^n)`, dead letter at 8, revision mismatch = clean release. |
| `publish_physiology_context_v1(p_token uuid, p_revision bigint, p_payload jsonb) → jsonb` | Fenced on live lease and `input_revision = p_revision`. Payload keys: `header` (mode, day, finality, status, availability_cutoff, generated_at, contract_version, schema_version, policy_fingerprint, input_fingerprint, versions), `document` (summary), `envelope_tables[]` (`{metric, envelope_count, table}`), `scoring_result_revision`, `scoring_input_revision`, `daily_values[]`, `bouts[]`, `episodes[]`, `new_frozen_references[]`. Idempotent on (policy, input) fingerprints. Replaces values/bouts, applies the episode rule, inserts frozen references, completes the job. If the day's retrospective daily values changed, invalidates the same device's retrospective days D+1..min(today, D+28) (`history_changed`) — the cross-day dependency horizon. Returns `{applied, context_revision, reason, cascaded_days}`. |
| `physiology_context_read_v1(p_user, p_device, p_day date, p_mode text, p_metric text) → jsonb` | `{status: available|pending|none, mode, context_revision, header…, document (the summary), envelope_tables: [EnvelopeTable JSON] (only `p_metric`'s table when given, all otherwise), pairing: {snapshot_result_revision, context_scoring_result_revision, consistent}, job: {pending, dirty_at}}`. Mode null ⇒ retrospective when present, else causal_live. Clients rebuild with `StoredDocument.join(summary:tables:)`. |
| `physiology_context_history_read_v1(p_user, p_device, p_from date, p_to date, p_mode text) → jsonb` | Episodes, bouts and daily values in range (≤ 120 days). |
| `record_exposure_event_v1(p_owner uuid, p_source uuid, p_event jsonb) → jsonb` | Validates; accepts `revision > current` (equal revision + identical content ⇒ `ignored`, equal revision + different content ⇒ `rejected`); inserts the revision, upserts current, invalidates affected days for all of the owner's devices (old and new occurrence range plus the 72 h lookahead). Returns `{status: saved|ignored|rejected, event_id, revision, reason}`. |
| `exposure_events_read_v1(p_owner, p_from bigint, p_to bigint, p_include_history bool) → jsonb` | Current events overlapping the range (and revisions when asked). |

Placement corrections: a trigger on `placement_intervals` invalidates from the effective start's local day through
today (device-specific, or every device when `device_id` is null), capped at 120 days. No trigger is added to any
scoring or `noop_*` table.

### 6.1 Stored form

A fully observed day carries ~2,300 envelopes (~10 MB as plain JSON, measured by `PCDocumentSizeTests`). The stored
and served form is `StoredDocument.split(doc)`: a summary document plus one interned `EnvelopeTable` per metric
(`PCStoredDocument.swift`; wire version `pc-wire-1`). Pooled sub-objects store times relative to each row's support
start; seconds-since-wake and seconds-before-bout are derived on decode with per-row overrides when a derivation would
not reproduce the value. `join(split(doc)) == doc` is tested on synthetic full days and real nights. Measured stored
size for a fully observed synthetic day: summary 54 KB, HR 301 KB, HRV 430 KB, resting HR 333 KB, respiratory rate
1.5 MB (budget 3 MB; a metric page reads summary + one table, budget 0.6 MB). Postgres TOAST compresses both further.

## 7. Worker lane

Owner: worker. Files: `Tools/CloudWorker/Sources/frwhoop-worker/ContextLane.swift`, `ContextInputs.swift`,
`ContextSQL.swift`; wiring in `main.swift` (config, connection, lane state, heartbeat). Tests:
`Tools/CloudWorker/Tests/frwhoop-workerTests/ContextLane*Tests.swift`.

1. Off unless `FRWHOOP_CONTEXT_ENABLED=1`; `context` in `FRWHOOP_DISABLE_LANES` also disables it. Own
   `PostgresClient`, own `LaneState`, `to_regclass('public.physiology_context_jobs')` guard (no table ⇒ lane idles
   and reports it). Knobs: `FRWHOOP_CONTEXT_BUDGET` (2), `FRWHOOP_CONTEXT_LEASE_SECONDS` (300),
   `FRWHOOP_CONTEXT_ENQUEUE_INTERVAL_SECONDS` (120).
2. Per job: read the latest snapshot of the day (`scoring_snapshots_v2`), the raw streams with `ingested_at` over the
   night window, recompute the series points with `IntradaySeries.build` (same inputs as scoring) and map them to
   `MeasurementInput`s with their actual support: HRV `[b, b+300)`; resting HR trailing 12 buckets
   `[b-3300, b+300)`; respiratory rate `[b-60, b+60)` with display bucket `[b, b+60)`; nightly snapshot values with the
   sleep session span. Load v1 epochs, v2 day runs when present, placement, device row (family, firmware, source),
   exposure revisions (window D-4..D+1), history (daily values D-90..D-1 same mode, bouts D-3..D-1, frozen
   references, prior 14 nights of sleep from earlier snapshots).
3. Cutoff: `causal_live` uses the claim time (or `cutoff_override`); `retrospective` uses the claim time with mode
   retrospective. `generatedAt` = claim time.
4. Publish under the lease; renew before heavy work. Never write `noop_*`, `sessions`, scoring tables; never call
   `scoring_dirty_span`; never run inside the scoring transaction. A context failure is counted and retried and never
   affects scoring, series, BLE or uploads.
5. Heartbeat counters: claimed, published, unchanged, failed, cascaded, mean/max build ms, mean/max document bytes.

## 8. HTTP API

Owner: backend-db. Routes in `supabase/functions/_shared/serverScores.ts`, same auth as `/scores/series`
(installation bearer or JWT + `x-noop-source-id`; owner from the credential, device from `deviceId` via
`findNoopDevice`). `cache-control: no-store`. Old clients never call them; an old server answers 405, which new
clients treat as "context unavailable".

| Route | Response |
| --- | --- |
| `GET /scores/context?deviceId=&day=YYYY-MM-DD[&mode=][&metric=]` | `{context: <physiology_context_read_v1>, identity}` |
| `GET /scores/context/history?deviceId=&from=&to=[&mode=]` | `{history: <physiology_context_history_read_v1>, identity}` (≤ 120 days) |
| `POST /scores/exposures` `{events: [ExposureEventRevision JSON]}` (≤ 25) | `{results: [{event_id, revision, status, reason}], identity}` |
| `GET /scores/exposures?from=&to=[&history=1]` | `{events, identity}` |

## 9. App

Owner: app. `Strand/Push/PhysiologyContextRepository.swift` (fetch + per-owner cache, mirroring
`ServerScoreRepository.intradaySeries`), `Strand/Push/PhysiologyContextStore.swift` (`@MainActor`, reset on account
end, read candidates), `Strand/Screens/MeasurementContextCard.swift`, `MeasurementContextDetailView.swift`,
`PhysiologyContextHistoryView.swift`; minimal insertions in `Strand/Screens/MetricExplorerView.swift` (HRV and resting
HR pages) and `Strand/App/AppModel.swift` (reset, read candidates, exposure flush call). The document decodes with
`PhysiologyContext.decoder()` into the shared Swift types. Copy uses "stable awake measurement", "recent walking",
"insufficient context", "persistent change from historical reference"; it never infers an illness, a medication
effect or a psychological state. Developer detail lives behind a diagnostics disclosure.

## 10. Exposure events end to end

Owner: exposures (core + app side). The phone keeps `exposureEventRevision` rows (account-scoped, in the shared
store via `registryWriter`, like `PlacementStore`), uploads pending revisions with `POST /scores/exposures`, and
reconciles with `GET`. Sources:

- Journal answers (`Repository.saveJournalAnswer` / `saveJournalNumeric` / `clearJournalAnswer`): event id is
  deterministic from (owner, day, canonical question); `yes` ⇒ `confirmed`, `no` ⇒ `denied`, cleared ⇒ `retracted`;
  `occurred` = the local day, `time_precision = day_only`, `source = journal_day_answer`; numeric value ⇒ dose with the
  catalog unit (`dose_provenance = catalog_default` for the unit).
- Caffeine intakes (`CaffeineLogStore`): event id = intake UUID; exact time; mg dose (`user_entered`, or `imported`
  for HealthKit).
- A small timed-event editor (medication, supplement, meal, alcohol, caffeine, heat, travel, symptom, other) with
  occurrence time or range, precision, optional dose and unit, edit and delete (retract) — reachable from the context
  detail view.

Kinds map from journal questions by a documented table; unknown questions are `other` with the question as label.
Uploads respect `CloudLocalDataBinding.isOwner` and never upload one account's rows as another's.

## 11. Ownership map

| Workstream | Owns (create/edit) | Must not edit |
| --- | --- | --- |
| lead | `PCContract.swift`, `PCIntervalAlgebra.swift`, `PCEngine.swift`, `PCIntervalAlgebraTests.swift`, `PCEngineTests.swift`, `docs/physiology-context/*.md` (except `notes/`) | — |
| signal | `PCSignalValidity.swift`, `PCMotionEvidence.swift`, `PCEligibility.swift`, `PCSignal*Tests.swift`, `PCEligibility*Tests.swift`, `PCMotion*Tests.swift`, `docs/physiology-context/notes/signal.md` | everything else |
| sleep | `PCSleepRhythm.swift`, `PCSleep*Tests.swift`, `notes/sleep.md` | everything else |
| exposures | `PCExposures.swift`, `PCExposure*Tests.swift`, `Strand/Data/ExposureEvent*.swift`, `Strand/Data/ExposureJournalBridge.swift`, `Strand/Screens/ExposureEvent*View.swift`, journal-write functions in `Strand/Data/Repository.swift`, `Strand/Data/CaffeineLog.swift`, `StrandTests/ExposureEvent*Tests.swift`, `notes/exposures.md` | AppModel, MetricExplorerView, supabase |
| responses | `PCExertionBouts.swift`, `PCFunctional.swift`, `PCExertion*Tests.swift`, `PCFunctional*Tests.swift`, `notes/responses.md` | everything else |
| statistics | `PCReferences.swift`, `PCChangeDetection.swift`, `PCRobustStats.swift`, `PCReference*Tests.swift`, `PCChange*Tests.swift`, `PCEvaluation*.swift` (package, pure), `notes/statistics.md` | everything else |
| backend-db | `supabase/migrations/2026100512*.sql`, `supabase/functions/_shared/serverScores.ts` (new routes only), `supabase/functions/tests/physiology_context*_test.ts`, `exposure*_test.ts`, `SERVICE_ONLY_FUNCTIONS` additions in `auth_isolation_sql_test.ts`, `supabase/tests/e2e/ordered_migrations.sh` (append), `notes/backend-db.md` | Swift |
| worker | `Tools/CloudWorker/Sources/frwhoop-worker/Context*.swift`, minimal wiring in `main.swift`, `Tools/CloudWorker/Tests/frwhoop-workerTests/Context*Tests.swift`, `deploy/worker.env.example` (new keys), `notes/worker.md` | package, supabase |
| app | `Strand/Push/PhysiologyContext*.swift`, `Strand/Screens/MeasurementContext*.swift`, `Strand/Screens/PhysiologyContextHistoryView.swift`, minimal insertions in `MetricExplorerView.swift` and `AppModel.swift`, `StrandTests/PhysiologyContext*Tests.swift`, `notes/app.md` | package, supabase, exposure files |

Cross-cutting requests (a new shared field, a renamed signature) go to the lead; nobody edits another workstream's
files.

## 12. Reason codes

Each system declares its codes as static constants plus a `reasonCodes` array; the table below is generated from those
declarations (333 distinct codes). Meanings are in the owning workstream note (`notes/<workstream>.md`, reason-code
section). The app maps every registered code either to a plain-language phrase or to "diagnostics only"
(`PhysiologyContextWordingCoverageTests` fails on any unmapped code). Ordering rule: in an `EligibilityVerdict` the
deciding (gating) reasons come first and non-gating observations are also listed in `notes`; in an `ExertionBout` the
first reason is the censoring / ongoing cause.

| System | Codes |
| --- | --- |
| Join (lead) (`PCIntervalAlgebra.swift`, 12) | `gap`, `heart_rate_dependent_source`, `invalid_interval`, `lookback_limit`, `mixed_states`, `mostly_uncovered`, `movement`, `no_activity_records`, `overlapping_records_resolved`, `uncovered_time`, `unknown_label`, `unknown_label_time` |
| Engine (lead) (`PCEngine.swift`, 9) | `activity_evidence_unavailable`, `history_from_future_dropped`, `labels_read_heart_rate`, `motion_shared_across_systems`, `no_measurements`, `no_observations`, `shared_beat_intervals`, `shared_optical_sensor`, `sleep_evidence_unavailable` |
| A — validity / regime (`PCSignalValidity.swift`, 91) | `aggregation_differs`, `algorithm_version_differs`, `availability_basis_sensor_time`, `awake_evidence_unavailable`, `beat_values_untrustworthy`, `beats_outside_kernel_range`, `clock_reset_detected`, `conflicting_duplicates_rejected`, `contains_break`, `device_clock_ahead`, `device_family_differs`, `device_family_unknown`, `disconnection`, `display_only`, `ectopic_rejection`, `elevated_rejected_beats`, `equal_value_beats_kept`, `exact_duplicates_collapsed`, `excess_rejected_beats`, `excluded_from_comparisons`, `firmware_differs`, `firmware_unknown`, `flatline`, `flatline_run`, `future_timestamp`, `heart_rate_dependent_motion_ignored`, `heart_rate_independent_source`, `hr_plausible_band`, `insufficient_beat_coverage`, `insufficient_beats`, `insufficient_breath_intervals`, `insufficient_clean_beats`, `insufficient_coverage`, `insufficient_in_band_samples`, `insufficient_run_coverage`, `insufficient_valid_pairs`, `invalid_interval`, `method_differs`, `method_version_changed`, `mostly_out_of_band`, `motion_contaminated`, `motion_present`, `motion_unobserved`, `no_beat_intervals`, `no_core_temperature_sensor`, `no_gravity_vector`, `no_heart_rate_samples`, `no_in_band_samples`, `no_qualified_waveform`, `no_skin_temperature_samples`, `no_source_records`, `non_monotonic_timestamps`, `out_of_band_samples`, `out_of_contract_units`, `outside_read_window`, `overlapping_timelines_suspected`, `partial_beat_coverage`, `partial_coverage`, `partial_in_band`, `partial_run_coverage`, `partial_window_coverage`, `placement_changed`, `placement_differs`, `placement_history_starts`, `placement_mixed`, `placement_record_gap`, `placement_unknown`, `regime_key_differs`, `rr_coverage_unmeasurable`, `rr_kernel_range`, `rr_over_count_cross_second`, `rr_over_count_same_second`, `rr_under_covered`, `rsa_only_estimate`, `skin_not_core_temperature`, `sleep_detector_hr_confirmation`, `sleep_detector_uses_heart_rate`, `sleep_evidence_unavailable`, `source_change`, `source_kind_differs`, `source_kind_unknown`, `step_counter_present`, `timestamp_spike`, `units_differs`, `unverified_strap_estimate`, `vendor_differs`, `wear_evidence_unavailable`, `wear_from_heart_rate_signal`, `window_differs`, `window_length_dependent`, `wrist_orientation_likelihood_only` |
| A — motion evidence (`PCMotionEvidence.swift`, 5) | `motion_basis_dynamic_acceleration`, `motion_basis_gravity_delta`, `motion_magnitude_unavailable`, `no_motion_samples`, `step_counter_stepping` |
| B — eligibility (`PCEligibility.swift`, 31) | `after_exertion_bout`, `asleep`, `awake_evidence_unknown`, `exertion_history_exceeds_limit`, `heart_rate_dependent_activity_ignored`, `inside_locomotion`, `inside_supported_sleep`, `insufficient_activity_coverage`, `insufficient_preceding_stillness`, `insufficient_stationary`, `invalid_interval`, `movement_in_support`, `no_supported_exertion`, `not_asleep`, `not_worn`, `preceding_stillness_unobserved`, `recent_exertion_bout`, `recent_locomotion`, `recent_locomotion_unobserved`, `signal_degraded`, `signal_invalid`, `signal_unsupported`, `signal_unverified`, `signal_validity_missing`, `sleep_detector_hr_confirmation`, `sleep_evidence_unknown`, `sleep_wake_mixed`, `stable_awake_low_movement`, `wear_evidence_unknown`, `wear_from_heart_rate_presence`, `wear_mixed` |
| C — sleep / rhythm (`PCSleepRhythm.swift`, 51) | `band_state_inputs_undocumented`, `classification_provisional`, `detector_input_missing`, `detector_lag_window`, `detector_may_extend`, `detector_owner_days_unread`, `endogenous_phase_unmeasured`, `hr_only_session`, `inside_sleep_episode`, `inside_split_sleep_gap`, `invalid_support`, `labels_read_heart_rate`, `main_night_rule_applied`, `main_sleep_incomplete`, `nap_after_main_wake`, `no_completed_sleep_before`, `no_detector_output`, `no_main_sleep`, `no_main_sleep_reference`, `no_sleep_episodes`, `no_wear_evidence`, `overlapping_session_superseded`, `overlaps_incomplete_episode`, `owner_day_provisional`, `partially_in_detected_sleep`, `prior_nights_insufficient`, `prior_zone_assumed_same`, `reference_beyond_lookback`, `reference_time_after_cutoff`, `rhythm_proxy_only`, `rhythm_proxy_reads_heart_rate`, `rhythm_samples_insufficient`, `scorer_nap_flag`, `session_availability_basis_end`, `session_end_clipped_to_cutoff`, `session_reaches_cutoff`, `session_revision_resolved`, `sleep_evidence_insufficient`, `sleep_in_progress`, `sleep_labels_read_heart_signals`, `sleep_sources_disagree`, `source_day_differs_from_owner_day`, `split_sleep`, `stages_unavailable`, `stages_unverified`, `timezone_history_unknown`, `utc_offset_changed_in_window`, `wake_may_be_revised`, `wear_evidence_insufficient`, `wear_from_heart_signal`, `wear_sources_disagree` |
| D — exertion (`PCExertionBouts.swift`, 41) | `ambient_unavailable`, `bout_ongoing`, `cadence_unavailable`, `continued_movement`, `coverage_unknown_for_part_of_window`, `cutoff_reached`, `disconnect`, `end_hr_unavailable`, `ended_at_evidence_gap`, `external_load_unavailable`, `follow_up_motion_unobserved`, `grade_unavailable`, `hr_insufficient_coverage_during_bout`, `hrv_recovery_window_unsupported`, `insufficient_cadence_minutes`, `insufficient_follow_up_samples`, `insufficient_samples_at_offset`, `merged_hart_and_strap_evidence`, `next_bout`, `no_follow_up`, `no_motion_observed_in_window`, `no_supported_post_bout_respiratory_estimator`, `not_returned_by_last_observed_offset`, `observed_prorated_partial_day`, `optical_hr_during_movement_unvalidated`, `overlaps_hr_detected_workout`, `post_effort_hr_decline_not_clinical_hrr`, `pre_bout_hr_insufficient_coverage`, `pre_bout_reference_unavailable`, `pre_bout_window_in_prior_recovery`, `pre_bout_window_overlaps_prior_bout`, `preceding_state_unknown`, `respiration_unavailable_during_movement`, `rise_too_small_for_fraction`, `rise_too_small_for_return`, `speed_unavailable`, `step_counter_unclassed_legacy`, `uncalibrated_step_counter`, `workout_clipped_at_cutoff`, `workout_without_locomotion_evidence`, `wrist_cadence_not_gait_speed` |
| E — exposures (`PCExposures.swift`, 15) | `aligned_events_limited`, `association_only`, `behavior_change`, `behavior_unobserved`, `candidate_not_confirmed`, `concurrent_events`, `insufficient_measurements`, `invalid_dose_dropped`, `invalid_revisions_ignored`, `late_entries_included`, `no_exposure_records`, `pharmacology_not_modelled`, `regime_change`, `time_uncertain`, `window_partially_searched` |
| F — references (`PCReferences.swift`, 38) | `center_uncertainty_approximate`, `constant_history`, `context_unsupported_parent_only`, `degraded_validity_included`, `duplicate_history_day_resolved`, `frozen_created_after_day_ignored`, `frozen_not_registered`, `frozen_reference_is_historical_not_healthy`, `frozen_registered_this_run`, `frozen_registers_in_other_mode`, `frozen_scale_floored_by_current_policy`, `frozen_window_not_complete_for_day`, `future_history_ignored`, `history_in_other_regime_only`, `history_values_excluded`, `insufficient_history`, `log_transform`, `multiple_nightly_values_longest_kept`, `nightly_snapshot`, `no_history`, `no_population_prior`, `non_positive_value_for_log`, `other_regime_history_not_pooled`, `overlapping_windows_not_counted`, `parent_insufficient_child_only`, `partial_day_composition`, `pooled_toward_parent`, `provisional_support`, `relative_use_only`, `scale_floor_default`, `scale_floored`, `scale_from_recent_window`, `scale_from_rolling_view`, `small_sample_scale_correction`, `stable_awake_windows`, `stale_history`, `time_band_stratum`, `winsorized_mean_estimator` |
| F — change (`PCChangeDetection.swift`, 30) | `alternative_detector_agrees`, `alternative_detector_silent`, `autocorrelation_assumed_conservative`, `coincides_with_regime_boundary`, `descriptive_not_diagnostic`, `detector_burn_in`, `detector_cusum`, `detector_persistence`, `distinct_groups_not_proven_independent`, `frozen_and_rolling_agree`, `frozen_and_rolling_disagree`, `frozen_reference_deviation`, `frozen_unavailable`, `gap_reset`, `gradual_drift`, `isolated_excursion`, `no_declared_dependence`, `no_deviating_series`, `no_recent_support`, `no_reference`, `partial_day_value_excluded`, `recurring_within_window`, `returned_toward_reference`, `rolling_adapted_frozen_deviation_persists`, `rolling_adapted_not_proof_of_recovery`, `selection_reads_heart_rate`, `shared_inputs_not_independent`, `split_at_regime_boundary`, `starts_at_window_start`, `too_few_supported_days` |
| G — functional / registry (`PCFunctional.swift`, 17) | `activity_evidence_unavailable`, `day_incomplete_at_cutoff`, `day_not_started_at_cutoff`, `insufficient_motion_coverage`, `insufficient_wear_coverage`, `insufficient_worn_time_for_rates`, `motion_evidence_unavailable`, `no_bouts`, `no_validated_definition`, `no_waking_time`, `observed_behaviour_not_diagnosis`, `rest_after_bout_right_censored`, `sleep_not_excluded_from_waking_time`, `transition_denominator_too_small`, `wear_denominator_uses_heart_signal_presence`, `wear_evidence_unavailable`, `wear_missingness_may_be_informative` |

## 13. Versions

Every version is part of `Policy.fingerprint`, so a bump changes every reprocessing key (rollout.md §5).

| Component | Version |
| --- | --- |
| Contract | `pc-contract-1` (schema 1) |
| Stored form | `pc-wire-1` |
| Join | `pc-join-1` |
| Engine | `pc-engine-1` |
| Validity / motion / eligibility | `pc-validity-2` / `pc-motion-1` / `pc-eligibility-2` |
| Sleep | `pc-sleep-1` |
| Exertion | `pc-exertion-1` |
| Exposure | `pc-exposure-1` |
| Reference / change | `pc-reference-2` / `pc-change-2` |
| Functional / features | `pc-functional-2` / `pc-features-1` |
| Derived HR windows | `pc-hr-window-1` |

## 14. Changes since the first contract draft

Made during integration and the independent reviews (each with a regression test):

- **Device regime key.** Device-level daily values (`hr_response.*`, `hr_recovery_*`, `functional.*`) use
  `dev-<fnv>` over vendor, family, source kind, firmware, the placement covering most of the day, and the product
  version (`pc-exertion-*` / `pc-functional-*`), so the key is stable whatever measurement families exist that day and
  values from different definitions never pool.
- **`PlacementInput.scope`** (`device` | `account`, nil = device); a device-scoped record wins where they overlap.
- **`SleepSessionInput.dataThrough` / `timezoneId`.** Causal sessions are known only once published (unknown
  publication = at the session end).
- **`DayDocument.envelopeIndex`** and the stored form (§6.1).
- **Comparisons** are attached to an envelope only when its daily value is that envelope's own value; aggregate
  comparisons (e.g. the stable-awake median) stay document-level.
- **`EligibilityVerdict.notes`**; `SelectionSummary.representedShare` now means "entered a daily value", with
  `eligibleShare`, `enteredCount`, `enteredSupportS` and `enteredObservedS` beside it; `targetDependentGates` is set
  per verdict (`signal_invalid`, `hr_plausible_band`, `rr_kernel_range`, `ectopic_rejection`,
  `sleep_detector_hr_confirmation`, `wear_from_heart_rate_presence`).
- **Frozen references.** Retrospective runs see every registered reference; a registered one is the authority, a day
  inside its window gets `frozen_window_not_complete_for_day`; causal runs ignore references created on or after the
  day. Publish reports `frozen_references_conflicting`.
- **Change detection** burns in until a series' history covers its 28-day rolling window; φ̂ is gap-aware with a
  conservative φ = 0.5 when it cannot be estimated; causal partial-day stable-awake and functional values carry no
  distance (`partial_day_composition`). `ChangeEpisode.detectionDelayDays` was renamed `alarmAfterStartDays`.
- **Input fingerprint** covers every input (records and history through the canonical encoder) and, for
  retrospective documents, finality.
- **Worker** loads 160 days of daily values (90-day episode window + 14-day guard + 56-day φ̂ window).
- **Invalidation** also cascades 14 days on a sleep-episode change and 3 days on a bout-only change, always refreshes
  the device's newest retrospective day after a values change, applies queue updates in (user, device, day, mode)
  order, invalidates on decoder day documents, and clears a replay cutoff on new inputs.
