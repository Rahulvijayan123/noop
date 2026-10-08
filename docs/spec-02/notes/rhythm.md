# Spec 02 — temperature rhythm + history (label `rhythm`)

Branch `spec02/temperature-rhythm-20261007`, worktree `nara-spec02-rhythm`, from foundation `fedeceb49`.
Scope: spec §3 (multi-day thermal history, cosinor, phase relations, drift) and §4 last bullets
(IS/IV/L5/M10/RA); CONTRACT §5.1 `rhythm_history` and §5.4.

## 1. What is implemented

| Piece | Where | State |
| --- | --- | --- |
| Per-day hourly fold of skin temperature, worn HR and gravity movement | `Tools/CloudWorker/Sources/frwhoop-worker/SleepFeatureRhythmHistory.swift` (`buildDay`) | done |
| Per-day cache = the day's own published snapshot (`rhythmDay`) | `DayScoring.swift` enrichment block | done |
| Bounded history loader (one indexed query) + wire assembly (`rhythm_history`) | `SleepFeatureRhythmHistory.loadDays` / `assemble`, call site `attachSleepFeatures` | done |
| Request key `rhythm_history` | `SleepFeatureEnrichment.AssemblyInput.rhythmHistory` + 3 lines in `buildRequest` | done |
| Weighted cosinor, SEs, gate, phase status, temperature regularity | `features/rhythm.py` | done |
| Phase relations (HR − temp, sleep midpoint − temp) | `features/rhythm.py` | done (sleep midpoint needs `history.days[].nights`, see §7) |
| Phase drift, clock changes, observed re-alignment | `features/rhythm.py` | done |
| Rest-activity rhythm IS/IV/L5/M10/RA | `features/rhythm.py`, wired in `compute.py` | done |
| Cross-midnight IV in the old helper | `features/thermal.py` `intradaily_variance` | fixed |
| Decoder status `unavailable` | `SleepFeatureDocument.swift` | added |
| 24hAlign, LIDS, kRA/kAR | — | deferred (listed in the block's `deferred`) |

## 2. Data source and cost (the critical-section question)

**Where the read would run.** `scoreAndBuildPayloads` runs inside `runV2Once`'s REPEATABLE READ transaction, which
holds the `scoring_jobs_v2` row lock for the whole pass and, when `FRWHOOP_V2_INPUT_GATE_SECONDS > 0`, the
session-level shared `scoring-inputs-v2:<user>` advisory lock that every upload needs exclusively. The enrichment
(and therefore any history read) is inside that critical section. I cannot move it out without editing
`ScoringLane.swift` (Spec 01).

**A raw-table aggregate is too expensive there** (production, read-only, owner account, `EXPLAIN (ANALYZE, BUFFERS)`):

| Query | Cost |
| --- | --- |
| One local day (2026-10-06, ~85 k rows per stream): minute aggregates of temperature (median), HR presence, gravity one-second adjacencies (window `lag`) | **13.7 s cold** (≈ 5 000 pages read, sort spilled 6.8 MB to disk), **0.49 s warm** |
| 14 days, three streams, one statement | exceeded the 30 s statement timeout |

35 such days per pass is impossible inside the lock.

**What I did instead.** Each day is folded once, near the source, from the rows its own scoring pass has already loaded.
The 84 h night window covers the whole local day, so there are no extra stream reads. `buildDay` produces minute
rules, then UTC-hour bins. The bins are published in that day's snapshot under the top-level payload key `rhythmDay`
(about 3 KB). The snapshot is the per-day, per-revision cache:

- A late upload re-scores the day, through the invalidation trigger (`day..through+2`) and the day-closure pass.
- That republishes the day's bins under a new `result_revision`.

A later day's request reads the last 34 days' `rhythmDay` with one lateral query. It makes one index probe per day
on `scoring_snapshot_read_v2`, taking the newest revision only. The claim day itself comes from the in-memory rows.

| Query (production, owner) | Cost |
| --- | --- |
| `loadSQL` (34 days, newest snapshot per day, `payload->'rhythmDay'`) | **221 ms** first run of the session (14 pages read, 121 ms planning), **1.6 ms** warm |
| Old regularity-history form (`result_revision = (select max(...))` correlated) for comparison | 2.4 s (touches all ~7 400 revisions) |

The read runs under `db.isolatingFailures`, a savepoint, so a failure only drops `rhythm_history`. It is gated by the
same dormant default as the enrichment, so without `FRWHOOP_INFERENCE_URL` the snapshot is byte-identical.
`buildDay` is pure Swift over arrays the pass already holds. Its cost on 3 × 302 k rows (84 h at 1 Hz) is printed by
`testBuildDayCostOnAFullScoringWindow` (see §8).

**Freshness.** `rhythm_history.revision_digest` = sha256 of:

- `day:revision|…` per day, using the snapshot `result_revision`, or the claim's `input_revision` for the claim day;
- `identity=<conversion identity>`;
- `rules=<rules text incl. rules_version>`.

The sidecar echoes the digest as `history_revision_digest` on both rhythm blocks.

**Consequence: history accrues after deploy.** Snapshots published before this change have no `rhythmDay`. The rhythm
becomes available once 5 qualifying days have been re-published, which is about 5 days of normal scoring. A one-off
backfill would be `invalidate_scoring_history_v2` over the last 35 days per user. That is 35 re-scores per user and
the owner's decision. I did not do it.

## 3. Coverage finding (prod, owner device `155ad9d4…`, read-only)

| Stream | Coverage per local day, 2026-09-30 … 10-07 |
| --- | --- |
| `noop_gravity_samples` (1 Hz gravity vector from the history records, NOT the duty-cycled raw IMU) | 1 368–1 421 minutes with ≥ 30 s; 24/24 hours every day |
| `noop_skin_temp_samples` | 1 371–1 421 minutes; 24/24 hours |
| `noop_hr_samples` | 1 276–1 421 valid minutes; 24/24 hours |

This device's data starts 2026-09-29. Full-day movement coverage therefore exists: the 1 Hz gravity stream is
persisted all day, and the duty-cycled stream is only the 100 Hz raw IMU. So the rest-activity rhythm is computed, not
withheld.

- Signal: `gravity_movement_seconds_per_minute`, worn minutes only. It is an orientation-change proxy: seconds whose
  1 Hz gravity vector moved ≥ 0.01 g from the previous second.
- Withheld cases, each with its reason:
  - movement absent: `movement_history_absent`;
  - sleep-only or sparse movement: `insufficient_days`, `insufficient_daytime_movement`, `quadrant_unobserved`;
  - incomplete 24 h profile: `incomplete_daily_profile`, and L5/M10/RA stay null.
- Activity-decoder labels never fill gaps. No count threshold is applied and nothing is binarised.

## 4. Definitions (Python `features/rhythm.py`)

- **Bins.** UTC-hour aligned. The worker emits a bin only when some signal has data. A missing signal is `null` with
  0 minutes, never 0. A bin supports a signal with ≥ `hour_min_valid_minutes` (30) valid minutes.
- **Worker minute rules.** These are the CONTRACT §5.1 rules, recorded in `rules`:
  - a minute is worn with ≥ 30 distinct plausible HR seconds (20–250 bpm);
  - a temperature minute is the median of its in-band distinct seconds, valid when worn with ≥ 30 of them;
  - an HR minute is the mean of its plausible seconds;
  - a movement minute is 60 × moving / eligible true one-second gravity adjacencies, threshold
    `SleepStager.gravityStillThresholdG` (0.01 g), valid when worn with ≥ 30 adjacencies.
- **Hour values.** Temperature is the median of the valid minute medians, kept in the raw register domain. HR is the
  mean of the valid minute means. Movement is pooled: 60 × Σ moving / Σ eligible.
- **Conversion.** One conversion is used for the whole history, at assembly:
  - WHOOP 5/MG: `raw / 100` (the `skinTempCelsius` map). Identity `whoop5-centidegree`. The 28–42 °C band is applied
    per second.
  - WHOOP 4.0: the provisional affine map with one history-wide anchor, the median of the 4.0 hours' raw medians
    (global anchor if fewer than 24 hours). Identity `whoop4-provisional-affine:anchor=…:slope=0.05`.
    - Its raw worn band applies per second, and the 28–42 °C band applies to the converted hour.
    - The per-pass anchor that the nightly path uses would shift each day's offset and fake a rhythm.
- **Mixed families.** Days of different families mark the history `device_family = conversion_identity = "mixed"`,
  with per-day identities. The sidecar then returns `mixed_devices`.
- **Gate.** This is the existing `CONFIG.rhythm_min_days` (5) and `CONFIG.rhythm_day_coverage` (0.80).
  - A day qualifies when its supported hours are ≥ 80 % of its true local length (23/24/25 h).
  - The 06–12 and 12–18 local quadrants must be observed, else `insufficient_daytime_temperature`. A night-only trace
    therefore fails.
  - 00–06 and 18–24 must be observed, else `quadrant_unobserved`.
  - Fewer than 5 qualifying days gives `insufficient_days`.
- **Cosinor.**
  - Model `y = M + a cos ωt + b sin ωt`, ω = 2π/24 h, fitted by weighted least squares on the supported bins of the
    qualifying days.
  - t is the bin midpoint in actual UTC time. It is DST-free, so the fit survives midnight and DST by construction.
  - Weights are valid minutes / 60.
  - Fit quality is the weighted R².
  - The acrophase is reported in UTC (`acrophase_utc_h`) and on the claim zone's local clock (`acrophase_h`, with
    `acrophase_local_timezone` and its offset).
  - The pooled fit and the jackknife come from additive 3×3 sufficient statistics.
- **Uncertainty.**
  - Delta method on the WLS covariance `s²(X'WX)⁻¹`, with `s² = Σw r²/(n−3)`:
    - `var A = (a²Vaa + b²Vbb + 2abVab)/A²`;
    - `var φ = (b²Vaa + a²Vbb − 2abVab)/A⁴`.
  - A delete-one-day jackknife is also computed.
  - `acrophase_se_h` and `amplitude_se_c` are the larger of the two. Both components are also reported. Hourly
    residuals are autocorrelated within a day, so OLS alone is optimistic.
  - The delta-method SE is checked against a 400-replicate Monte Carlo (within 15 %) and against the closed form
    σ√(2/n) for amplitude.
- **Phase status.**
  - `zero_amplitude` when the amplitude is below 0.05 °C, or below 2 × its SE.
  - `unstable_phase` when the acrophase SE is above 1.5 h, or the circular SD of the qualifying days' own acrophases is
    above 3 h.
  - `mixed_devices` as above.
  - An unavailable phase nulls `acrophase_h` and `acrophase_utc_h` and sets status `partial`. Mesor and amplitude stay.
  - A failed gate gives status `withheld` with all values null.
  - Naps and non-main nights get `not_applicable` (`nap` / `not_main_night`).
  - No history gives `multi_day_history_not_requested`.
- **Temperature regularity** (`regularity_name = temperature_regularity`):
  - IS = n·Σ_h(x̄_h − x̄)² / (p·Σ(x_i − x̄)²), with local clock-hour groups and p = observed groups.
  - IV = [Σ_pairs (Δx)²/P] / [Σ(x − x̄)²/N]. A pair is two supported bins exactly 3600 s apart in UTC, so pairs cross
    midnight and gaps break them.
  - Without gaps P = N − 1, which is exactly n·Σ(Δx)²/((n−1)·Σ(x−x̄)²). With gaps it equals pyActigraphy's own pandas
    behaviour on a NaN-gapped grid, `diff().pow(2).mean()/var(ddof=0)`: valid-pair normalisation. Tests check both.
  - With unbalanced hour groups, for example after a time-zone change, IS can slightly exceed 1. That is a property of
    the formula, and it is reported as computed.
- **Phase relations.**
  - Circular differences in [−12, 12) h of independently supported UTC phases, with both components in UTC and local
    (`a_h`, `b_h`, `a_utc_h`, `b_utc_h`).
  - HR: the same cosinor and gate on the same history's HR bins, with a 1 bpm amplitude floor.
  - Sleep midpoint: the circular mean of ≥ 5 non-nap sleep-period midpoints inside the history span. The periods come
    from `history.days[].nights` plus the request's main night.
  - Withheld reasons: `temperature_phase_unavailable`, `hr_insufficient_days`, `hr_zero_amplitude`,
    `hr_unstable_phase`, `insufficient_daytime_heart_rate`, `hr_quadrant_unobserved`, `insufficient_sleep_periods`.
- **Phase drift.**
  - The OLS slope of the unwrapped daily UTC acrophases (qualifying days, amplitude ≥ floor) against elapsed UTC days,
    when there are ≥ 5 daily phases.
  - `clock_changes` lists every time-zone change between consecutive days (`kind: timezone`) and every DST transition
    within a day (`kind: dst`), with from/to offsets, over the whole history. A relabelling alone produces zero drift
    (test: LA → NY with constant UTC physiology gives |drift| < 0.05 h/day).
  - `observed_realignment` describes the latest change of ≥ 0.5 h:
    - `clock_shift_h`, and `required_utc_shift_h = −clock_shift_h`;
    - `utc_phase_change_h`, from the latest post-change daily phase minus the circular mean of the pre-change phases;
    - `fraction_realigned`, `days_since_change`.
    - It is descriptive. There is no forecast.
- **Rest-activity** (`rest-activity-1`):
  - IS and IV as above, on movement.
  - L5 and M10 are the least and most active 5 / 10 consecutive hours of the cyclic local-hour mean profile; their
    start hours are local.
  - RA = (M10 − L5)/(M10 + L5).
  - Gate: ≥ 5 days with movement in ≥ 80 % of local hours, plus all quadrants.

## 5. Wire fields

**Request**
- `rhythm_history` as in CONTRACT §5.1.
- Added, optional: per day `device_family` and `conversion_identity`, parsed in `contract.py`.
- `rules` carries `rules_version` and descriptive extras: `hr_plausible_bpm`, `movement_minute_min_adjacencies`, and
  the value definitions.

**Snapshot.** New top-level payload key `rhythmDay` (`schema: rhythm-day-1`, `rules_version: rhythm-rules-1`), holding:
- `day`, `timezone`, `day_start_utc`, `day_end_utc`, `device_family`, `temp_scale: raw_register`;
- `bins[]`, each with `start`, `skin_temp_raw`, `skin_temp_valid_minutes`, `hr_mean_bpm`, `hr_valid_minutes`,
  `movement_s_per_min`, `movement_valid_minutes`.

**`observed_skin_temp_rhythm`.** All CONTRACT §5.4 keys, plus these additive keys:
- `acrophase_utc_h`, `acrophase_local_timezone`, `acrophase_local_utc_offset_h`;
- `fit_hours`, `residual_sd_c`, `iv_valid_pairs`, `regularity_hours`, `regularity_name`;
- `conversion_identity`, `weighting`, `config`;
- `coverage.{daytime_local_hours, days_with_data, duplicate_days_dropped, duplicate_bins_dropped, invalid_timezone_days}`;
- `uncertainty.{acrophase_delta_se_h, amplitude_delta_se_c, acrophase_jackknife_se_h, amplitude_jackknife_se_c}`;
- relation `a_utc_h`, `b_utc_h`;
- drift `span_days` and `notes`, and per daily phase `timezone`, `amplitude_c`, `hours`;
- clock change `from_timezone`, `to_timezone`;
- re-alignment `clock_change_day`, `required_utc_shift_h`, `definition`.

`phase_status.status` is `available`, `unavailable` or `not_applicable`.

**`rest_activity_rhythm`.** All CONTRACT §5.4 keys, plus:
- `unit`, `binarized`, `count_threshold` (null), `movement_threshold_g`;
- `iv_definition`, `iv_valid_pairs`, `hours_used`;
- `history_revision_digest`, `deferred`, `config`, `notes`.

**Unchanged.** CONTRACT field names. `algorithm_version` stays `nara-sleep-features-1` and `CONFIG_VERSION` stays as is.
The new thresholds live in the frozen `RhythmConfig`, reported as `config` inside each block, and outside
`dependencies.config`.

## 6. Reason codes added (for the UI wording map)

**Temperature rhythm.** `multi_day_history_not_requested` (existing), `insufficient_days`,
`insufficient_daytime_temperature`, `quadrant_unobserved`, `zero_amplitude`, `unstable_phase`, `mixed_devices`,
`fit_failed`, `module_error`, `nap`, `not_main_night`.

**Relations.** `temperature_phase_unavailable`, `hr_insufficient_days`, `insufficient_daytime_heart_rate`,
`hr_quadrant_unobserved`, `hr_zero_amplitude`, `hr_unstable_phase`, `hr_fit_failed`, `insufficient_sleep_periods`,
`unstable_sleep_midpoint`, `phase_unavailable`.

**Drift and re-alignment.** `insufficient_days`, `no_clock_change`, `insufficient_days_around_clock_change`,
`unstable_phase`.

**Rest-activity.** `multi_day_history_not_requested`, `movement_history_absent`, `insufficient_days`,
`insufficient_daytime_movement`, `quadrant_unobserved`, `incomplete_daily_profile`, `zero_variance`,
`no_consecutive_hour_pairs`, `zero_activity`.

## 7. Edits to files outside my core set

**`features/contract.py` (root).** `RhythmDayIn` gains optional `conversion_identity` and `device_family`, parsed and
validated per day. This is additive.

**`features/compute.py` (root).**
- Imports `rhythm`.
- Adds `rest_activity_block, _ = _isolated(rhythm.rest_activity_rhythm, req, CONFIG)`.
- Adds the document key `rest_activity_rhythm`.

**`features/thermal.py`.**
- `_rhythm_withheld_block` delegates to `rhythm.not_requested_block()`.
- New `_rhythm_block` isolates rhythm failures.
- `_withheld_block(req, night)` and `compute_night` call it, on the main night.
- `intradaily_variance` now includes the pairs across midnight; its old test value is corrected.
- The module docstring is updated.
- Nightly thermal definitions are untouched.

**`SleepFeatureDocument.swift` (root).** `SleepMetricStatus` gains `case unavailable`. There are no exhaustive switches.
`SleepFeatureCards.swift:223` (UI owner) lists not-showable statuses and should add `.unavailable`.

**`SleepFeatureEnrichment.swift`.**
- `AssemblyInput.rhythmHistory` (`var … = nil`, so existing call sites compile).
- Three lines in `buildRequest`.
- The transport, busy and history-night sections are untouched (Spec 01 / respiratory).

**`DayScoring.swift`.**
- In the enrichment block, builds `rhythmDay` and stores it in the snapshot.
- `attachSleepFeatures` gains a `rhythmDay:` parameter, loads and assembles the history, and passes it in.

**Dependencies on other agents.**
- Sleep-midpoint relation: needs the respiratory agent's `history.days[].nights` population. Until it lands, the
  relation is withheld with `insufficient_sleep_periods`, because only the current main night is available.
- `CircadianEngine` relabelling: the thermal agent's job. The skin-temperature phase is kept distinct.
- Spec 01: a post-commit hook in `ScoringLane` would let the history read leave the lock entirely. It is not needed
  now (1.6 ms warm).

## 8. Tests

**Python, from `Tools/InferenceWorker`.**
- Command: `uv run --frozen pytest -o addopts="" -q tests/test_contract.py tests/test_features_continuity.py
  tests/test_features_physiology.py tests/test_features_regularity.py tests/test_features_settling.py
  tests/test_features_integration.py tests/test_server.py tests/test_features_rhythm.py --deselect
  tests/test_features_integration.py::test_full_night_fixture_reproduces_the_committed_response_within_budget`.
- Result: **252 passed, 1 deselected** (219 at foundation + 33 new). `test_features_rhythm.py` alone: **34 passed**.
- The deselected golden-content test now also differs by the new keys only. A diff script shows only
  `observed_skin_temp_rhythm.{method_version, phase_status, …}` and the document-level `rest_activity_rhythm`. The lead
  must regenerate `SleepFeatureWireFixtures/sleep_features_response.json` at integration.

**Acceptance fixtures covered** (`tests/test_features_rhythm.py`):
- known cosine recovered (mesor ±0.03, amplitude ±0.04, acrophase ±0.2 h), with sane SEs;
- Monte Carlo and closed-form SE checks;
- flat input gives `zero_amplitude`, with no divide-by-zero;
- unstable phase;
- night-only gives `insufficient_daytime_temperature`;
- 4 days gives `insufficient_days`;
- 80 % boundary (20 h qualifies, 19 h does not);
- thin hours;
- missing quadrant;
- naps and non-main nights;
- no history;
- mixed identities, and top-level `mixed`;
- duplicate days (newest revision wins) and duplicate bins (first wins);
- DST week (25 h day, 25 bins, UTC phase constant, drift ≈ 0, local label 20 → 19 h);
- time-zone change alone (no drift, fraction ≈ 0);
- eastward re-alignment (fraction ≈ 1);
- acrophase wrap at midnight;
- IV across midnight vs reference and vs the pandas variant;
- IV with gaps (valid-pair normalisation);
- IS vs reference and pyActigraphy;
- block pairs (143 for 6 days);
- phase relations available, and withheld without HR or sleep history;
- flat HR;
- rest-activity hand-computed L5/M10/RA/IS/IV, absent, sleep-only, incomplete profile;
- parser per-day identity, and the exact worker shape;
- compute integration;
- producer → app golden (`Packages/StrandAnalytics/Tests/StrandAnalyticsTests/Goldens/SleepFeatures/spec02_rhythm_blocks.json`,
  regenerate with `FRWHOOP_WRITE_RHYTHM_GOLDEN=1`).

**Python timing** (35-day history, 840 bins, 161 KB request part; 7 runs, min / median, Mac load average 190–800):

| Step | Time |
| --- | --- |
| parse | 2.1 / 2.2 ms |
| temperature rhythm block | 6.5 / 9.0 ms |
| rest-activity | 2.4 / 5.0 ms |
| whole `compute` on the committed full night | 1 648 ms without history vs 1 699 ms with it |

The whole-document time is load-dominated (the foundation recorded the same fixture at 1.92 s under load, against the test's 0.75 s idle limit); the rhythm blocks add ~11 ms of it. Response growth is
about 10 KB (rhythm block) plus 1.7 KB (rest-activity).

**Swift**, all through `_build-scratch/spec02/sbuild.sh`:

| Run | Result | Log |
| --- | --- | --- |
| `wk-test --filter SleepFeature` | **27 run, 0 failures**: `SleepFeatureRhythmHistoryTests` 10, plus the existing `SleepFeatureEnrichmentTests` 17 | `logs/rhythm-wk-test-140221.log` |
| `wk-test --filter SleepFeatureRhythm`, after the cost-ratio edit | 10 run, 0 failures | `logs/rhythm-wk-test-140746.log` |
| `sa-test --filter SleepFeature` | **4 run, 0 failures**: `SleepFeatureRhythmGoldenTests` 3 (producer golden decodes field for field, `unavailable` phase status) and `SleepFeatureCrossLanguageTests` 1 | `logs/rhythm-sa-test-140836.log` |

Worker tests cover:
- the minute rules (worn gate, thin minutes, out-of-band, duplicates first-wins, adjacency-only movement, true 0 vs
  unknown);
- the 25 h DST day (25 bins);
- the snapshot record round trip and rules-version isolation;
- the loader (one query, newest record only, skips a missing or other-rules record);
- assembly: raw/100, nulls with 0 minutes, newest 35 days, ≤ 26 bins per day, a digest that changes with any revision,
  newest-revision dedupe, implausible hours nulled, one 4.0 anchor, mixed families;
- request key presence and absence.

**`buildDay` cost.** On the full 84 h window (3 × 302 400 rows), debug build, load average around 500: 3 168 ms. A
single plain loop over the same rows took 626 ms in the same run, so `buildDay` costs **5.1× one plain pass over its
inputs**. Absolute debug times under this load are not meaningful. A release build is expected to take a few
milliseconds per plain pass, but that was not measured here because release builds are not run through the wrapper.
The common path does one order check plus binary-search slicing; there is no copy or sort.
