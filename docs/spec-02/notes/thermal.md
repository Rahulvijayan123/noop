# Spec 02 — temperature / thermal / circadian owner notes (label `thermal`)

Branch `spec02/temperature-thermal-20261007`, worktree `nara-spec02-thermal`, cut from foundation `fedeceb49`.
Scope of this branch: the Swift thermal repair, the 30-minute morning response, the `CircadianEngine`
relabel and its app wording, plus the worker input-window check. The Python thermal rhythm and the worker
`rhythm_history` loader belong to the rhythm agent; sleep cards (rendering `morning_response`) belong to the UI
agent.

## 1. Post-wake slope repair (CONTRACT §4.2)

**Defect (confirmed).** `SleepAnalyticsThermal.thermalGroup` built minute medians only for minutes whose start
lies inside a fragment and then fitted both slopes from those same medians. The post-wake window
`[window end, window end + 30 min)` is entirely outside the fragments, so the post-wake slope was always
`insufficient_coverage`; the pre-onset window `[onset − 60 min, onset)` was clipped to the part after the first
fragment start (only the in-bed wake prefix counted).

**Fix.** `thermalMinuteBins(timeline:input:config:)` builds every qualified UTC-minute bin ONCE:

- Span `[spanStart, spanEnd)`: `spanStart = min(first fragment start, first observed onset − 60 min, window end −
  30 min)`, `spanEnd = window end + max(30 min post-wake, 30 min morning)`. Samples are read on whole UTC minutes
  covering the span, so an edge bin holds exactly what it would hold with no filter.
- Rules unchanged and applied once: exact-second worn gate (plausible HR at that second), WHOOP 4.0 raw band before
  conversion, family/anchor conversion, 28–42 °C band, off-wrist rejection, first sample per second wins
  (duplicates counted, never support), ≥ 30 distinct accepted seconds per minute, median per minute, no
  interpolation.
- Re-wear equilibration (5 min after an off-wrist END) removes qualified minutes from every subset. Change: an
  event whose window starts just before the span now still excludes the overlapping minutes (previously ignored).
- Subsets: nightly summary = accepted bins whose minute start lies in a fragment (identical to before, and
  provably independent of post-wake data); pre-onset slope = accepted bins in `[onset − 60, onset)`; post-wake
  slope = accepted bins in `[end, end + 30)`; morning temperature curve = accepted bins in its window. The
  document path (`SleepAnalyticsV1.compute`) builds the bins once and passes them to both the thermal and the
  morning groups — no double aggregation.
- Slope method: OLS of minute medians against unix seconds (°C/h), now in the numerically stable centred form
  (the raw-sum form biased slopes by ~0.2 % at unix-second magnitudes); gates ≥ 45/60 and ≥ 20/30 valid
  minutes, longest missing run (edges included) ≤ 300 s, onset observability for the pre-onset slope.

**Diagnostics meaning changes (under the version bump).** `stream_counts.temp_received/valid/duplicate/rejected/…`
now count samples inside the analysis span (whole minutes), not the worker's whole 84-hour read.
`equilibration_excluded_minutes` / `temp_rewear_excluded_minutes` count qualified minutes excluded anywhere in
the span (was: in-fragment only). New `temp_span_accepted_minutes`. `temp_valid_minutes` /
`temp_eligible_minutes` keep their in-fragment meaning.

**Input window (worker).** `SleepAnalyticsAttach.sleepAnalyticsInput` passes the streams AS LOADED.
`DayScorer.scoreAndBuildPayloads` reads HR, gravity, skin temperature, RR and events over
`[local midnight − 30 h, local midnight + 54 h)`, a superset of `[onset − 60 min, end + 30 min)` for any main
night of the day, so nothing is clipped; the adapter comment now states this as a requirement, and a worker
test pins that post-wake/pre-onset samples reach the extractor and produce the slope and the morning group.
No widening was needed. (The app has no local `SleepAnalyticsV1.compute` caller.)

**Versions (meaning change, CONTRACT §4).** See section 6.

## 2. Morning response (`sleep_analytics_v1.morning_response`, CONTRACT §4.3)

`SleepAnalyticsMorning.swift`, `morningResponseGroup(timeline:input:config:thermalBins:)`. Wire shape exactly
as CONTRACT §4.3 (`SleepAnalyticsMorningResponseGroup` / `SleepAnalyticsSignalWindow` / `SleepAnalyticsCurvePoint`
from the foundation; no field changed).

- Anchor: effective window end (last fragment end) — `anchor_kind = effective_window_end`, `anchor_ts`,
  `anchor_at` (ISO UTC). Window `[anchor − 1800 s, anchor + 1800 s)`.
- Grid: the UTC minutes whose start lies in the window; `offset_min = floor((minute − anchor)/60)`, −30…29.
  UTC minutes (not anchor-relative) so temperature is literally the thermal bins and all three signals share one
  grid. With an off-grid anchor the straddling minute counts as "before" (same minute-start rule as the slopes).
- Heart rate (`bpm`): median of plausible HR seconds (config 20–250 bpm), first sample per second, explicit
  off-wrist seconds excluded; valid with ≥ 30 distinct seconds. `support` = distinct seconds.
  `minute_rule = median_plausible_hr_seconds_min_30_distinct_off_wrist_excluded`.
- Skin temperature (`°C`): the thermal group's accepted minute bin (median); `support` = distinct accepted seconds
  in that minute (so thin and equilibration-excluded minutes show their support but are invalid).
  `minute_rule = thermal_group_accepted_minute_bin`.
- Movement (`s/min`): count of moving adjacencies `(t − 1, t)`, `t` in the minute, both gravity samples valid
  (finite, |g| in 0.5–1.5 g, first per second), consecutive seconds, neither off-wrist, `deltaG ≥
  movementThresholdG` (0.01 g, the movement group's). Valid with ≥ 30 eligible adjacencies AND no explicit
  off-wrist time in the minute. The value is the raw count (never scaled up for missing adjacencies).
  `minute_rule = moving_seconds_among_true_1s_gravity_adjacencies_min_30_no_off_wrist`.
  The adjacency acceptance helper `morningGravityBySecond` lives in the morning file (same rules as
  `SleepAnalyticsMovement.movementGroup`'s inline loop) because the cardiac agent edits the movement file; the
  lead may fold both onto one helper at integration.
- Per signal: `before_valid_minutes`, `after_valid_minutes`, `eligible_minutes_each_side` 30, `before_median` /
  `after_median` (`available` with ≥ 20 valid minutes, `partial` with 1–19, `unavailable`/`no_samples` with
  none), `change = after − before` (`available` only with ≥ 20 on both sides, else null with
  `insufficient_coverage`, or `no_samples` when both sides are empty).
- Group `quality.status`: `available` when all three changes are available, `partial` when any minute is valid,
  else `unavailable`. `quality.source_resolution_seconds = 60`; `stream_counts` carries `hr_received/duplicate/
  rejected`, `gravity_received/duplicate/rejected`, `hr_valid_minutes`, `temp_valid_minutes`,
  `movement_valid_minutes`.
- `algorithm_version = morning-response-1`; `interpretation =
  response_around_detected_boundary_not_awakening_physiology`. nil only when there is no fragment.
- Python's 3-minute settling response is untouched (separate definition).

**Tolerant decode (root-owned edit).** `SleepAnalyticsDocument` now has an explicit `init(from:)`: all Phase 1
fields decode exactly as the synthesized decoder did; `morning_response` decodes with `try?`, so a malformed
morning group is nil and the rest of the document survives (spec acceptance: other groups survive one group's
failure).

## 3. `CircadianEngine` relabel (spec §3)

Production input is per-hour mean HR (`AppModel.computeCircadianPhase`), so the output is now named and worded as
an OBSERVED HEART-RATE RHYTHM HEURISTIC:

- `PhaseEstimate.tempMinHour` → `hrRhythmReferenceHour` (doc: HR acrophase − fixed 12 h; not a temperature
  minimum, DLMO, endogenous clock or chronotype). `tempMinHour` kept as a deprecated computed alias; the old
  `init(tempMinHour:…)` kept deprecated. New `basis: EstimateBasis` (`observed_heart_rate_rhythm_heuristic` for
  every production estimate; `supplied_temperature_minimum` only via the deprecated override).
- `estimatePhase(bins:daysObserved:habitualWakeHour:)` is the primary API; the `observedTempMinHour:` overload is
  deprecated (no production caller ever supplied it; mixing a temperature phase into the HR heuristic is what
  the spec forbids — the measured skin-temperature phase is the rhythm agent's Python output).
- `idealSleepWindow`, `sleepWindowOffsetHours`, `chronotype` take `referenceHour:`; the `tempMinHour:` labels are
  deprecated wrappers. Numbers are unchanged (pinned by the existing tests, migrated to the new names).
- Engine copy: notes say "Your heart-rate rhythm runs later/earlier than your schedule suggests" / "lines up
  with your schedule"; the planner's no-shift note says "schedule shift". Constant names
  (`cbtMinBeforeWakeHours`, `acrophaseAfterCbtMinHours`, `Chronotype`) kept for the Kotlin twin, docs corrected.

App wording (wording only; layout untouched):

| Where | Before | After |
| --- | --- | --- |
| Dial overline / Sleep layout item (`SleepLayoutPrefs`) / Health card overline | Body clock | Heart-rate rhythm |
| Dial subtitle | Last night against your clock | Last night against your heart-rate rhythm |
| Dial a11y label | Body clock dial | Heart-rate rhythm dial |
| Dial legend (reference arc) | Your clock | Rhythm estimate |
| Dial caption | In sync with / %@ later than / %@ earlier than your body clock | In line with your heart-rate rhythm / %@ later / earlier than your heart-rate rhythm suggests |
| Dial bucket | Morning / Intermediate / Evening type | Earlier / Mid-afternoon / Later daily heart-rate peak |
| Health card subtitle | Light + sleep timing only | From your heart rate, not temperature |
| Health card line | Estimated body-clock low around %@ (tempMinHour) | Heart rate typically peaks around %@ (**acrophaseHours**, the observed peak) |
| Health card notes | Your body clock looks later, with a night-owl tendency. (etc.) | Your heart-rate rhythm runs later than your sleep schedule suggests. (etc.) |
| Planner no-shift note | No meaningful body-clock shift is needed… | No meaningful schedule shift is needed… |

`Strand/Resources/Localizable.xcstrings`: 16 new keys with de, es, fr, it, pl, pt-PT, ru, zh-Hans, zh-Hant
translations (written by me; a native review is welcome). Nine now-unreferenced compact entries removed ("Last
night against your clock", "In sync with your body clock", "%@ later/earlier than your body clock",
"Morning/Intermediate/Evening type", "Body clock dial", "Your clock"). The older pretty-printed entries ("Body
clock", "Estimated body-clock low around %@", "Your body clock looks …", "Light + sleep timing only", "No
meaningful body-clock shift …") are left in place, unreferenced, to keep the diff away from other agents' hunks;
Xcode marks them stale. Several of those old entries carried Portuguese text in it/pl/ru/zh — moot now.

Not changed (for the lead): `Strand/System/AppChangelog.swift` past release notes still say "body clock" /
"chronotype" (historical copy); the Android twin (`android/.../CircadianEngine.kt`, `BodyClockDialCard.kt`) still
uses the old wording and `tempMinHour` — outside this branch's file set. `IllnessSignalEngine.swift:81` comment.

## 4. Persistence and API trace

`DayScoring.scoreAndBuildPayloads` → `sleepAnalyticsPayload` (`JSONEncoder` → JSON object, finite check) →
`snapshotDaily["sleep_analytics_v1"]` → `publish_scoring_snapshot_v2(p_payload)` stores the payload jsonb
verbatim (it validates only `sleep`, `coverage`, `daily` type, `dataThrough`, `timezone`, `status`; no size cap) →
`supabase/functions/_shared/serverScores.ts` `readHostedSnapshot` returns `payload.daily` unchanged →
`ServerScoreRepository.sleepAnalytics(from:)` (`JSONSerialization` → `JSONDecoder` → `SleepAnalyticsDocument`,
schema_version 1 only). No split/strip of `daily` keys anywhere on the path. The app compares only
`schema_version` (still 1), not `algorithm_version`, so the bump does not hide documents. Tests:
`SleepAnalyticsMorningResponseTests.testThermalAndMorningSurviveTheWireRoundTrip` (encode → JSON object →
re-serialize → decode, equality of thermal and morning groups), worker
`testAdapterPassesPeriSleepStreamsAndPayloadCarriesSlopeAndMorningResponse`, and the Deno route test now carries a
`morning_response` and asserts verbatim pass-through. Size: the morning group adds ≈ 11 KB of JSON per day (3 ×
60 points) to a 100–150 KB snapshot.

## 5. Performance

`SleepAnalyticsPerformanceTests.testFullNightComputeCost`: worker-shaped input — 1 Hz HR, gravity and skin
temperature over a 24-hour read (86 400 each), an 8-hour native-staged night, 31 305 R-R intervals. Median of 3,
`swift test` DEBUG build, Mac load average 500–1000 (absolute numbers are noisy; the ratio is the finding):

| Build | `compute` total | thermal group | morning group | Log |
| --- | --- | --- | --- | --- |
| Before (foundation `fedeceb49` + the perf test) | 1479 ms | 379 ms | 0 (stub) | `_build-scratch/spec02/logs/thermal-sa-test-122429.log` |
| After, run 1 | 719 ms | 4.6 ms | 4.3 ms | `thermal-sa-test-134704.log` |
| After, run 2 | 355 ms | 36 ms | 4.3 ms | `thermal-sa-test-140443.log` |

The wider window adds no cost: the thermal group previously walked every skin-temperature sample of the worker's
read (84 h superset) with a per-sample off-wrist scan; it now filters to the ~5.5 h analysis span first, so the
thermal group is ~10–80× cheaper. The morning group adds ~4 ms (one pass over HR and gravity with a range check,
3 × 60 minute cells). Net effect on the scoring pass that holds the per-user lock: lower, not higher. The total
is dominated by the other groups (normalization, PRV), which this branch does not touch.

## 6. Version strings and fingerprint (every pinned string changed)

| String | Before | After | Where |
| --- | --- | --- | --- |
| `SleepAnalyticsV1.algorithmVersion` / wire `algorithm_version` | `nara-sleep-analytics-1` | `nara-sleep-analytics-2` | `SleepAnalyticsV1.swift` |
| `SleepAnalyticsConfig.version` / wire `config_version` | `v1` | `v2` | `SleepAnalyticsV1.swift` |
| movement group `algorithm_version` (derived) | `nara-sleep-analytics-1-movement-1` | `nara-sleep-analytics-2-movement-1` | derived from the above |
| `morning_response.algorithm_version` | — | `morning-response-1` | new |
| `gateFingerprint` | `v1|…` | `v2|…|morning|1800|1800|20|30|30` | morning gates now read |

`SleepAnalyticsConfig.v2` added; `.v1` kept as an alias of the same defaults (it now reports `v2`). The worker
and `compute`'s default use `.v2`. Pins updated: `SleepAnalyticsDocumentWireTests` (package), worker
`SleepAnalyticsAttachTests` producer assertions, Deno `sleep_analytics_route_test.ts` fixture. Left on purpose:
hand-built OLD documents in worker `SleepAnalyticsAttachTests.documentDictionary` and
`StrandTests/SleepAnalyticsSectionTests.swift` keep `nara-sleep-analytics-1` — they test that old stored
documents still decode. The pNN50 threshold is NOT in the fingerprint on this branch (nothing reads it here);
the cardiac branch adds it when its PRV code reads it — expect a one-line merge on the fingerprint.

## 7. Root-owned edits

- `SleepAnalyticsV1.swift`: version constants and comments; `config.version = "v2"`, `static let v2`, `v1` alias;
  morning gates in `gateFingerprint`; `SleepAnalyticsDocument.init(from:)` (tolerant `morning_response`).
- `SleepAnalyticsComputation.swift`: build `thermalMinuteBins` once, pass to `thermalGroup(…, bins:)` and
  `morningResponseGroup(…, thermalBins:)`; default config `.v2`.

## 8. Reason codes

No new reason codes. The morning response uses existing `SleepAnalyticsReason` values: `no_samples`,
`insufficient_coverage` (and `computation_failed` from the metric sanitizer). Slopes keep `onset_not_observed`,
`insufficient_coverage`, `insufficient_duration`.

## 9. Tests

| Run | Result | Log |
| --- | --- | --- |
| `sa-test --filter 'SleepAnalytics\|Circadian'` (StrandAnalytics) | 116 run, 0 failures, 0 skipped | `_build-scratch/spec02/logs/thermal-sa-test-140443.log` |
| `wk-test --filter SleepAnalytics` (CloudWorker) | 18 run, 0 failures | `thermal-wk-test-142036.log` |
| `deno test supabase/functions/tests/sleep_analytics_route_test.ts` | 4 passed | — |
| `mac` app build (Strand, Debug, macOS) | BUILD SUCCEEDED; no deprecation warning from the renamed API in app code | `thermal-mac-143316.log` |

New suites: `SleepAnalyticsThermalRepairTests` (9), `SleepAnalyticsMorningResponseTests` (13),
`SleepAnalyticsPerformanceTests` (1); `CircadianEngineTests` +3 (now 29); worker +1. The first run of the new
suites failed 7 assertions only because the OLS slope was off by ~0.2 % (0.6005 vs 0.6 °C/h): the raw-sum
OLS cancelled at unix-second magnitudes. Fixed with the centred formula (`olsSlope`), which is exact on a line;
the pre-existing slope test only checked to 0.01 °C/h, which is why it never showed. Not run: the app's
`StrandTests` (`SleepAnalyticsSectionTests` decodes a hand-built `-1` document and is unaffected; no StrandTests
reference the changed strings).

## 10. Not done / unsupported

- Movement minute values are raw moving-adjacency counts; minutes with 30–59 eligible adjacencies are not
  rescaled (no extrapolation). Consumers should show `support`.
- The morning response has no personal baseline/reference; it is descriptive around the detected boundary only.
- Android twin and historical changelog wording (section 3).

## 11. Integration notes for the lead

- Commits: thermal repair + version bump (`36a29c361`), morning response (`45c0ef547`), CircadianEngine relabel
  and wording (`e31b1ad34`), these notes.
- Merge points: `SleepAnalyticsV1.swift` `gateFingerprint` (cardiac adds the pNN50 threshold next to my morning
  line); `SleepAnalyticsComputation.swift` compute() call list (cardiac/UI may touch neighbouring lines);
  `Localizable.xcstrings` (my lines sit after "The answer from the strap appears…", where the removed body-clock
  one-liners were).
- CONTRACT §4 says versions stay `-1`/`v1` "until the thermal change lands": it has landed here, so CONTRACT §4's
  first line and PROGRESS §5 should now read `nara-sleep-analytics-2` / `v2`.
- `morning_response` is produced, stored and decoded; the UI agent renders it (`SleepAnalyticsSection`). Suggested
  copy key: "around the estimated end of the night", never "after you woke".
- Golden pair `SleepFeatureWireFixtures/*` is unaffected (it is the Python `sleep_features` document).
- Deploy: the worker must be rebuilt for `-2` documents; old stored `-1` documents keep decoding in the app
  (schema_version unchanged) until their day is re-scored.
- Not on this branch: the Android `CircadianEngine.kt` / `BodyClockDialCard.kt` twin wording, the historical
  `AppChangelog.swift` entries.
