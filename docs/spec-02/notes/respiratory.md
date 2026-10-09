# Spec 02 — respiratory / context owner notes

Branch `spec02/respiratory-context-20261007` (worktree `nara-spec02-resp`), from foundation `fedeceb49`.
Build label `resp`. Spec sections: §2 (respiratory summaries), §4 bullet 2 (rebound); CONTRACT §5.2, §5.5, §6.

## 1. What was implemented

### 1.1 `respiratory_variability` additions (Python, `features/respiration.py`)

`method_version: "resp-variability-2"`. Every pre-existing key keeps its definition and value (checked against the
committed full-night fixture: no existing key changed). New keys:

| Key | Definition |
| --- | --- |
| `config` | the frozen `RespVariabilityConfig` below (block-local; `features/config.py` unchanged so `dependencies.config` is stable) |
| `supported_range` | `detector_band_bpm [6, 24]`, `min_peak_spacing_s 2.5`, `display_rate_range_bpm [8, 25]`, `source "SleepStager.respBreathTrack"` (mirrors `RespBreathTrack.swift` and `SleepStager.respPlausibleRangeBpm`) |
| `interval_distribution` | `status`, `reasons`, `n_intervals`, `usable_windows`, `median_s`, `iqr_s`, `p05_s`, `p10_s`, `p25_s`, `p75_s`, `p90_s`, `p95_s`, `unit "s"`, `quantile_method "linear_interpolation"` (numpy default), `source "consecutive_intervals_within_usable_runs"` |
| `stable_modulation` | `status`, `reasons`, `definition_version "stable-resp-modulation-1"`, `criteria` (numeric map), `stable_minutes`, `evaluated_minutes`, `unknown_minutes`, `night_minutes`, `windows_total`, `windows_evaluated`, `windows_stable`, `stable_fraction_of_evaluated`, `stable_fraction_of_night`, `unit "min"` |
| `stage_conditioned[stage]` | + `sd_interval_s`, `rmssd_interval_s`, `median_interval_s`, `iqr_interval_s`, `true_intervals` |

**True interval.** Breaths are exported by Swift stamped at the floor second of the later peak; runs are inclusive
`[start, end]` wall-clock seconds. An interval is *true* when both peaks lie in one run: `ts <= run.end` and
`ts + 1 - seconds >= run.start` (1 s allowance for the floor). A pseudo-interval spanning the gap between two runs
fails the second test, so **a gap never becomes a long breath**. The distribution set = usable-window intervals
(the existing A7 gates: ≥ 20 intervals, ≥ 80 % run coverage, stage purity) ∩ true intervals.
`interval_distribution` needs ≥ 2 usable windows (`distribution_min_windows`, the stage-summary minimum), else
`withheld` / `insufficient_usable_windows` (no intervals: `no_true_intervals_in_usable_windows`).

**Stable modulation (`stable-resp-modulation-1`).** The night's 5-minute grid (anchored at night start, as A4/A7). A
window is *evaluated* when exported runs cover ≥ 80 % of it **and** it holds ≥ 20 true intervals; otherwise it is
*unknown*. An evaluated window is *stable* when the CV (sample SD / mean) of its true intervals is ≤ 0.25. Unknown
time is never stable; `stable_fraction_of_night` keeps unknown time in its denominator. No evaluated window →
`withheld` / `no_evaluable_windows`, `stable_minutes` and both fractions null (never 0). Stage labels are not used.
CV 0.25 is a project default, not a physiological cutoff (RSA-derived intervals; no airflow reference exists).

**Per stage.** SD (sample), RMSSD over adjacent true intervals of the same run (never across a run boundary or an
excluded interval), median and IQR (numpy linear) of the stage's true usable-window intervals.

Not added (spec §2): tachypnea/bradypnea/pause/apnea counts, composite score, cardiorespiratory coupling, RSA
validation, I:E, tidal volume, periodic breathing.

Known asymmetry: the legacy night-level `rate_bpm`/`sd_interval_s`/`cv_interval` and per-stage `rate_bpm`/`cv_interval`
keep their original definition (all usable-window intervals, no true-interval test). On real Swift exports the two
sets are identical (Swift computes intervals inside runs); they differ only on malformed/synthetic gap-spanning input
(`test_inserted_gap_does_not_create_a_long_breath` documents this).

### 1.2 `rebound` (Python, new `features/rebound.py`; document level)

`definition_version "sleep-rebound-1"`. Keys: `status`, `reasons`, `history_revision_digest` (=
`context.history_revision_digest`), `rules` (numeric map), `unit "min"`, `notes`, `descriptive_only true`,
`personal_reference` (`median_asleep_min`, `median_awake_min`, `nights`, `days_evaluated`), `after_short` /
`after_fragmented` (`pairs`, `next_night_asleep_diff_min` and `next_night_awake_diff_min` as `{median, iqr,
segments}`, `pair_days`), `pairs_evaluated`.

Rules (all in `rules`): a history day's night = its longest non-nap published entry (scorer's primary-session rule);
valid when `asleep_min` and `awake_min` are present and sum > 0. Pair = nights of consecutive calendar days D, D+1
with the second starting at/after the first ends. Per pair, the reference is the median of every *other* valid night
in the window (leave-pair-out; ≥ `min_reference_nights` 7). Short: `asleep ≤ ref_asleep − 60`; fragmented:
`awake ≥ ref_awake + 30` (both possible). Differences: `next − ref` (minutes). Median/IQR only with ≥ `min_pairs` 3
pairs, else null with `<set>_insufficient_pairs`. Withheld: `history_nights_not_in_request` (worker sent no
nights), `insufficient_reference_nights` (< 9 valid nights). Other reasons: `duplicate_history_day_resolved`,
`history_nights_without_minutes_excluded`, `no_consecutive_night_pairs`, `no_short_nights_observed`,
`no_fragmented_nights_observed`, `pair_spans_timezone_change`. No causal, probability or forecast wording.

The target day itself is never in history (the loader reads days strictly before it), so the newest pair ends on
the day before the target.

### 1.3 Worker history request (`SleepFeatureEnrichment.swift`, request assembly + history loader only)

The worker did **not** send `history.days[].nights` / `timezone`. Added (no new query, no transport/busy edits):

- `loadHistory` query 1 also selects `payload->>'timezone' as tz` (same row, same bounded query); each day's
  `payload->'sleep'` entries (already parsed for the minute grid) are parsed into `SleepFeatureHistoryNight`
  (`start/end` from `start_at/end_at`, `is_nap`, `asleep_min`, `awake_min`, `efficiency`; a value missing or
  outside the sidecar's accepted range is nil so the request is never refused).
- `SleepFeatureHistory` gains `nightsByDay` / `timezoneByDay` (defaulted `var`s; old call sites compile).
- `buildRequest` emits `nights` (≤ 8 per day, the longest kept, start order) and `timezone` per history day.
- `efficiency` is forwarded as the snapshot publishes it (`AnalyticsEngine` session efficiency, a 0–1 fraction);
  rebound does not read it.
- Freshness: the nights come from the same snapshot revision the minute grid folds, so the existing
  `history_revision_digest` (day:revision) already versions them.

Coordination: the rhythm agent adds a `rhythm_history` loader in this file; my edits are confined to
`SleepFeatureHistory`, the new `SleepFeatureHistoryNight` type, `loadHistory` and the history block of
`buildRequest`.

### 1.4 Physiology context: post-exertion respiratory return (`PCExertionBouts.swift`)

`BoutRecovery.respiratoryRecovery: RespiratoryRecovery?` (method `pc-resp-recovery-1` =
`ExertionConfig.respiratoryRecoveryVersion`, `PolicyVersions.respiratoryRecovery`). Inputs: the day's
`respiratory_rate` measurements the engine already passes (causally filtered). Only window estimates are read
(not `snapshot.*`, support ≤ 600 s), one per support (duplicates: lowest method id, then lowest value).

1. **Reference.** Estimates wholly inside `[start − 900, start)` (never inside the previous bout's respiratory
   follow-up) whose support shows HR-independent stillness (bout evidence: no movement seconds, stationary ≥ 90 %).
   Needs ≥ 2 non-overlapping estimates; reference = median. Else `unknown` + `respiratory_reference_unavailable`,
   no observations, no timing (**no result**).
2. **Boundary.** If `[end, end + maxPauseS)` lacks motion evidence (the bout's `ended_at_evidence_gap` rule), the
   end is uncertain → `unknown` + `ended_at_evidence_gap`, `respiratory_follow_up_unobserved`.
3. **Follow-up** `[end, end + 1200)`, truncated (censoring in time order) at the next bout (`next_bout`), a recorded
   break (`disconnect`), the cutoff (`cutoff_reached`), or renewed movement after subsidence (`continued_movement`).
4. **Motion subsided** = start of the first contiguous stationary run ≥ 60 s after the end (HR-independent evidence).
   None → `unknown` + `respiratory_follow_up_unobserved` (+ `continued_movement` censoring when movement was observed,
   `follow_up_motion_unobserved` when evidence was missing).
5. **Observations** = still estimates with support in `[subsided, truncation)`. Offsets are support **end** − bout
   end (when the estimate was complete). None → `unknown` + `respiratory_follow_up_unobserved`.
6. **Return** = first estimate with `|bpm − ref| ≤ 2.0` confirmed by the next independent estimate (support starting
   at/after its end, ≤ 60 s later, within tolerance, nothing out of tolerance in between).
   - an out-of-tolerance estimate preceded it → `returned`, interval-censored `(lastAboveOffsetS, returnedAtOffsetS]`;
   - none preceded (first observation already within) → `returned_by` + `respiratory_returned_by_first_observation`
     with `returnedByOffsetS` an **upper bound** (the early recovery was not observed);
   - within at the end but no confirming estimate before truncation → `unknown` + `respiratory_return_unconfirmed`;
   - otherwise → `not_returned` + `respiratory_not_returned_in_follow_up` (right-censored).
   Any observation adds `respiratory_observations_resumed`.
7. `BoutRecovery.respiratory` channel: `supported` + `respiratory_observations_resumed` when estimates were read,
   else `unavailable` with the recovery's reasons (previously always `no_supported_post_bout_respiratory_estimator`).

New fields on `RespiratoryRecovery` (my type): `referenceIndependentEstimates: Int?`, `units: String?`
(`breaths_per_min`); doc of `offsetS` changed from support start to support end (no consumer existed).

Parameters: `ExertionConfig.respiratoryRecovery: RespiratoryRecoveryConfig` (`preWindowS 900`,
`preMinIndependentEstimates 2`, `stationaryShareMin 0.9`, `maxEstimateWindowS 600`, `followUpS 1200`,
`subsideStillS 60`, `toleranceBpm 2.0`, `sustainMaxGapS 60`). They are encoded with the policy, so every one enters
`Policy.fingerprint`. `ExertionConfig.version` (which keys the bout regime) is unchanged, so `hr_response.*` /
`hr_recovery_*` regimes do not split.

### 1.5 Stable-awake respiratory reference (`PCReferences.swift`)

Awake RR inputs **do** exist: `ContextInputs.seriesMeasurements` maps `IntradaySeries.respPoints`
(`series.resp_rate.2min`, one per minute, support `[b − 60, b + 60)`, withheld when the wrist is ambulatory) for the
whole day, and each envelope already gets a System B `stable_awake_rest` verdict from HR-independent motion context
(`Eligibility.evaluate` ignores the HR-reading decoder track). So no stand-in was needed and no exercise RR is ever
read.

Explicit adapter `ContextReferences.respiratoryStableAwakeValues` (`ReferenceConfig.stableAwakeMetrics` now includes
`.respiratoryRate`; the generic 5-minute loop explicitly skips RR): an envelope qualifies when it is a window estimate
(`windowS` < 300, not `snapshot.*`), validity `valid`, stable-awake `eligible`, and wholly inside one 5-minute window
of the day's local-midnight grid. A window takes the median of its estimates when it holds ≥ 2 non-overlapping ones
(`stableAwakeRespMinEstimatesPerWindow`). The daily `resp_rate.stable_awake_5min` value is the median of window values
with ≥ `stableAwakeMinWindows` (3) windows; plus `.band_HH_HH` strata. Reasons `stable_awake_windows`,
`stable_awake_respiration_window`. It flows through the existing compare / change / selection machinery
(`Eligibility.hasReferenceSeries` and `enteredEnvelopes` pick it up via `stableAwakeSeriesKey`). In causal mode it
carries no distance (`partial_day_composition`, like every stable-awake series). Scale floor `resp_rate.` 0.3.

### 1.6 Nightly RR versus prior 7 / 28 days (`PCReferences`, verified, not duplicated)

`resp_rate.sleep_night` already exists (nightly snapshot `resp_rate_bpm`, sleep-measurement eligible). Verified by
tests: `HistoryIndex(before: t)` drops the target day and later (`future_history_ignored`); rolling = days
`[t − 28, t − 1]` (min 7, ready 14), recent = `[t − 7, t − 1]` (min 3) with the rolling scale; `supportDays`,
`fromDay`, `toDay` report baseline support. **Zero MAD:** the scale is floored at 0.3 breaths/min (`resp_rate.`
floor), `scale_floored` + `constant_history` reasons, so a constant history never gives infinite certainty. The
comparisons reach `DayDocument.comparisons` and the nightly envelope's own `comparisons` (single-source daily value,
`Engine.attach`).

## 2. Wire fields / reason codes

Reason codes declared in owner `reasonCodes` arrays (the UI agent must map wording in
`MeasurementContextWording.swift`; `PhysiologyContextWordingCoverageTests` will fail until mapped):

| Code | Array |
| --- | --- |
| `respiratory_reference_unavailable` | `ExertionBouts.reasonCodes` |
| `respiratory_observations_resumed` | `ExertionBouts.reasonCodes` |
| `respiratory_returned_by_first_observation` | `ExertionBouts.reasonCodes` |
| `respiratory_not_returned_in_follow_up` | `ExertionBouts.reasonCodes` |
| `respiratory_follow_up_unobserved` | `ExertionBouts.reasonCodes` |
| `respiratory_return_unconfirmed` (new, not in CONTRACT's reserved list) | `ExertionBouts.reasonCodes` |
| `stable_awake_respiration_window` | `ContextReferences.reasonCodes` |

Respiratory recovery `state` vocabulary: `returned`, `returned_by`, `not_returned`, `unknown`.

Sleep-features reasons (plain strings in the document, for the UI's sleep cards): `insufficient_usable_windows`,
`no_true_intervals_in_usable_windows`, `no_evaluable_windows`, `unknown_time_never_stable`, and the rebound reasons
in §1.2.

Swift decoder (`SleepFeatureDocument.swift`, foundation) already matched every key I emit; no edit. Extra keys I emit
that the decoder ignores (kept in storage): `config`, `interval_distribution.usable_windows/unit/quantile_method`,
`stable_modulation.night_minutes/windows_*/unit`, `stage_conditioned[*].true_intervals`, `rebound.unit/
descriptive_only/pairs_evaluated/personal_reference.days_evaluated/after_*.pair_days`. `criteria` and `rules` are
numeric-only maps because the decoder reads `[String: Double]`.

## 3. Edits to root-owned / shared files

- `features/compute.py`: import `rebound`; `rebound_block, _ = _isolated(rebound.compute, req)`; `"rebound":
  rebound_block` in the document (module errors isolate to a withheld block).
- `features/contract.py`: none (the foundation parser already accepts `history.days[].nights/timezone`).
- `PCContract.swift`, `PCEngine.swift`: none (the foundation already passes RR measurements to `detect` and versions
  `respiratoryRecovery`). On this branch `PolicyVersions.respiratoryRecovery` and the fingerprint include
  `exertion.respiratoryRecoveryVersion` **unconditionally** (foundation behaviour). The pc-cardiac branch
  (`635bb95a7`) adds `Policy.respiratoryRecoveryComputes = false`, which blanks that version while false; since the
  detector computes on this branch, the lead must keep that flag **true** at merge (expect small conflicts in
  `Policy.versions` / `fingerprint`).
- `SleepFeatureEnrichment.swift` (temperature-owned): request assembly / history loader only, §1.3.
- `SleepFeatureDocument.swift`: none.

## 4. Persistence and API

- Physiology context: bouts (with `recovery.respiratory_recovery`) and daily values (`resp_rate.stable_awake_5min*`)
  go worker → `publish_physiology_context_v1` → `physiology_context_days.document` (summary JSON),
  `physiology_context_bouts.payload`, `physiology_context_daily_values.payload`, all stored verbatim (the SQL
  validates only identity / type / length; series keys ≤ 160 chars). `physiology_context_read_v1` and
  `physiology_context_history_read_v1` return the stored JSON unprojected, and `_shared/physiologyContext.ts` only
  parses queries, so no edge-function change or route-test change was needed. Round trip tested in Swift
  (`testBoutWithRespiratoryRecoveryRoundTripsThroughTheContextCoder`, including an old document without the field).
- **Policy fingerprint**: `ExertionConfig.respiratoryRecovery` and `ReferenceConfig.stableAwakeMetrics` /
  `stableAwakeRespMinEstimatesPerWindow` change `Policy.fingerprint`, so every stored PC document gets a new policy
  key and is recomputed once after deploy (the same one-time invalidation the foundation's `pulse` config causes;
  pc-cardiac does the same for pulse — one combined invalidation if deployed together).
- Sleep features: `SleepFeatureEnrichment.validateResponse` returns the object verbatim (checks only schema, status,
  night ids, JSON validity), so the new keys are not stripped; they land in `snapshot.daily.sleep_features`.
  Python → Swift decoder fixture test: `PCRespiratoryContextTests.testPythonRespiratoryAndReboundBlocksDecode`.

## 5. Tests (all run 2026-10-08 on this branch)

| Suite | Command | Result | Log |
| --- | --- | --- | --- |
| Python sidecar | `uv run --frozen pytest -o addopts="" -q tests/test_features_respiration_spec02.py tests/test_contract.py tests/test_features_{continuity,physiology,regularity,settling,integration}.py tests/test_server.py --deselect …within_budget` | 236 passed, 1 deselected, 0 failed (219 before + 17 new) | terminal |
| StrandAnalytics | `sbuild.sh … resp sa-test --filter 'PC\|Exertion\|Reference\|Eligibility\|Physiology\|SleepFeature'` | 335 run, 4 skipped, 0 failures (19 new in `PCRespiratoryContextTests`) | `_build-scratch/spec02/logs/resp-sa-test-132131.log` |
| CloudWorker | `sbuild.sh … resp wk-test --filter 'SleepFeature\|ContextLane'` | 75 run, 15 skipped (database-backed tests without a local DB), 0 failures (2 new) | `_build-scratch/spec02/logs/resp-wk-test-142846.log` |

New Python tests (`tests/test_features_respiration_spec02.py`): inserted gap does not create a long breath; quantiles
match numpy linear; distribution withheld below two usable windows; no breaths → nulls, never zeros; duplicate and
irregular breaths; stable modulation components with unknown never stable; gap-heavy window unknown; per-stage true
interval statistics; supported range and no clinical counts; rebound hand-computed (60 / IQR 10), consecutive days
only, short + fragmented coincide, leave-pair-out reference, main night / null / duplicate day handling, withheld
without history or reference, timezone change flagged, history nights read from the wire shape.

New Swift tests (`PCRespiratoryContextTests`): interval-censored return, `returned_by` upper bound, late subsidence
leaves early recovery unknown, right-censored not-returned, next-bout truncation and moving estimates ignored,
no reference → no result, movement never subsides, unobserved end boundary, cutoff censoring + unconfirmed,
ongoing bout / nightly values never read, duplicates + irregular sampling deterministic, fingerprint and version,
encode → decode round trip (and legacy decode), stable-awake respiratory adapter (window rule, straddling /
ineligible / degraded excluded, never zero-filled, explicit config), selection + comparison through the existing
machinery, nightly RR references exclude the target day and later with 7 / 28-day support, zero-MAD floor, and the
Python → Swift decoder fixture for `respiratory_variability` and `rebound`.

New worker tests: history loader carries published nights and zone (nulls for missing / out-of-range values);
request sends ≤ 8 nights per day keeping the main night, nulls not zeros.

Not run: the macOS `StrandTests` (UI agent's area; `PhysiologyContextWordingCoverageTests` needs the new reason codes
mapped), the deselected wall-clock golden test (now also differs by the new keys; lead regenerates the golden pair).

## 6. Not supported / left for others

- UI: wording for the new reason codes; rendering of interval distribution, stable modulation, per-stage fields,
  rebound, respiratory return and the awake RR reference. Note for the UI agent:
  `MeasurementContextWording.dayStableAwakeComparisons` derives the series from the envelope's own `windowS`, so a
  2-minute RR envelope looks for `resp_rate.stable_awake_2min`; it should use `resp_rate.stable_awake_5min` (the
  adapter's window) for respiratory envelopes.
- Golden pair `SleepFeatureWireFixtures/*` must be regenerated by the lead: `test_full_night_fixture_reproduces_the_
  committed_response_within_budget` now differs by the new keys only (existing values identical, checked).
- Pre-midnight RR estimates are not in the PC inputs (series are built per local day), so a bout in the first 15
  minutes after midnight has no pre-bout respiratory reference (`respiratory_reference_unavailable`).
- `outlier_fraction_vs_personal` remains withheld (no personal nightly breathing baseline in the sidecar).
