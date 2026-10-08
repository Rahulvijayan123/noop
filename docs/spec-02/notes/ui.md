# Spec 02: readback / UI notes (label `ui`)

Branch `spec02/readback-ui-20261007`, worktree `nara-spec02-ui`, cut from the foundation `fedeceb49`.
Owner scope: `Strand/Screens/*` (except StressView HF/LF and CircadianEngine / body-clock wording), `Strand/Push/*`,
`Localizable.xcstrings`, `MeasurementContextWording.swift`, `StrandTests/*`.

## 1. Section-hiding regression (fixed)

`SleepFeatureSection.load()` returned nothing whenever `daily.sleep_analytics_v1` existed. Now:

- The section always loads `sleep_features` for the night. `SleepFeatureSectionPlan` / `SleepFeatureDisplayModel`
  decide the chapters. With an analytics document present, **Continuity** and **Architecture** (and the continuity
  numbers in the headline strip) are left to the analytics section (CONTRACT §2: one owner per metric). Regularity,
  stage physiology, settling, breathing, the temperature rhythm, rest-activity rhythm, rebound and the secondary PRV
  statistics still render from `sleep_features`.
- Without an analytics document the section is unchanged: Continuity and Architecture render as before.
- The headline strip with analytics present shows Regularity, Breathing (est.) and "Lowest HR after" (settling).
  Without analytics it shows the original strip (Awake in bed, Longest stretch, Regularity).
- "Nightly thermal" was never rendered from `sleep_features`. It comes only from the analytics section (unchanged).

## 2. What renders where

### Sleep page, "Sleep analytics" section (`SleepAnalyticsSection.swift`, `daily.sleep_analytics_v1`)

| Metric | Where | Notes |
| --- | --- | --- |
| pNN50 | "Pulse-interval diagnostics" detail: row `pNN50 (optical PRV)` | Shows the persisted pooled value at 1 decimal (`12.4%`) and the denominator (`1,190 of 9,600 adjacent pairs differ by > 50 ms`). Also shows `Source: Optical pulse intervals (pulse-rate variability), not ECG` and the `pnn50_method`. An unavailable value shows `Unavailable · <reason>`. The rows appear only when the key exists, so an old document is unchanged. The summary adds `pNN50 x%`. |
| Thermal pre-onset / post-wake slopes (°C/h) | "Temperature trend" detail | Labels are now `Hour before sleep onset` and `30 min after estimated window end`. Nothing says "after waking". Each slope shows its valid/eligible minutes. |
| `morning_response` | New detail group `Around the end of the sleep window` (id `morningResponse`) | One row per signal: HR, skin temperature and movement, each as `before median → after median (change)`. Every signal has its own coverage (`before n of 30 min · after m of 30 min valid`). An unavailable side shows `Unavailable · too few valid minutes on one side`, never a median. The group also shows the anchor time (in the document's zone), the interpretation disclaimer and the `algorithm_version`. It does not draw curves: the minute points are decoded but not plotted. |
| `movement.stage_movement` | New detail group `Movement by estimated stage` (id `stageMovement`) | Each label shows `% of eligible time moving` and bouts/h. A partial rate is marked "(short exposure)". Unknown stays unknown and shows its reason. The note row always shows the "stages are estimated partly from wrist movement" disclosure. |

The convention follows the existing section: a detail row always renders, and an unavailable value reads
`Unavailable · reason`. The new groups are added only when the document carries them.

### Sleep page, "Sleep details" section (`SleepFeatureCards.swift` + new `SleepFeatureDisplayModel.swift`, `daily.sleep_features`)

| Block | Chapter | Content |
| --- | --- | --- |
| `respiratory_variability` (existing + §5.2) | Breathing | Rate, CV, interval SD and RMSSD, the interval distribution (median with IQR, p10–p90, p05–p95, and the number of consecutive intervals), stable modulation shown as components (stable / evaluated minutes and fraction, not-evaluated minutes, share of the night, `definition_version`), per-stage rate / SD / RMSSD / median (IQR) with window counts, coverage, supported range (`detected 6–24 · shown 8–25 br/min` with a note that rates outside are not measured), source ("estimated from the heart-rate rhythm, not measured airflow") and `method_version`. |
| `prv_nonlinear` | Pulse-interval research statistics | "Secondary" in the line. Sample entropy and DFA α1 (median with IQR, segment counts), segments used / rejected with `segments_evaluated` of `segments_available` (and `max_segments`), parameters (marked "non-overlapping boxes" when `dfa_overlap` is false), an "About this" row (optical PRV, not ECG, no health / fitness / training-zone claim), method and NeuroKit2 version. |
| `thermal.observed_skin_temp_rhythm` | Skin-temperature rhythm | Mesor, amplitude ± SE, acrophase (local clock) ± SE, fit, qualifying / evaluated days, day / night / quadrant coverage, IS / IV with the across-midnight IV note, both phase relations (with their components and support days), drift per day (elapsed time), clock changes ("not counted as drift"), observed realignment ("looking back only"), a disclaimer (not core temperature, not the body clock) and the method. An unavailable phase gate withholds the time and shows its reason. A withheld rhythm shows only the reason (plus qualifying days, when given). |
| `rest_activity_rhythm` | Rest-activity rhythm | IS, IV, L5 and M10 (with their start times), RA, days used, signal / epoch and method. When withheld (the likely case today) it shows only the reason and the definition, with no numbers. |
| `rebound` | After short or broken nights | The personal reference, then each set's next-night differences in asleep / awake time (median with IQR, number of pairs). A set with 0 pairs reads "No such nights in this period". Also an "About this" row (not a cause, not a prediction) and `definition_version`. |

Visibility convention: the existing chapters keep their old rule (hidden when their block is unavailable). The new
spec-02 chapters appear whenever their block is present. An unavailable block reads `Not available: <reason>` and
shows no numbers. Inside a chapter, a missing value is left out (the section's old convention). An unavailable
sub-block, such as the interval distribution or stable modulation, shows its reason row.

### Physiology context (`MeasurementContextDetailView.swift`, `PhysiologyContextHistoryView.swift`, `PhysiologyContextRepository.swift`)

- **Awake vs asleep HR** (`sleep.day_night_heart_rate`). A new section `Awake and asleep heart rate` (id
  `dayNightHeartRate`) on the **resting-HR / heart-rate** context detail. It appears even when that page has no
  measurement envelope. It shows both medians, each with its own coverage (`82% of 13 h 20 min observed · n readings`),
  plus awake minus asleep and the dip (%) with its definition. A missing side shows "Not available" and its reason. The
  footnote says sleep detection reads HR.
- **Pulse episodes** (`pulse_episodes`). A new section `Sustained pulse episodes` (id `pulseEpisodes`), on the same pages.
  It shows the inactive time checked (asleep / awake split), high and low counts with their time, and each episode
  (kind, local time range, median / extreme bpm, sleep context, censoring cause). It also shows the HR rises with
  movement (count and per-hour rates) and the thresholds (enter / exit, minimum duration). A nil count reads
  "Not evaluated" and 0 reads "None found". The footnote says it describes readings only, is not a heart-rhythm
  classification, and attributes no cause. The version, state and thresholds are under Diagnostics (`d-pulse`). The
  Diagnostics "Versions" row also lists `pulse` and `respiratoryRecovery` when present.
- **Post-bout respiratory return** (`bouts[].recovery.respiratory_recovery`). A new `breathing` line on each history
  bout row. "returned" gives the interval between the last offset above the level and the first offset within it.
  "returned_by" is an upper bound at the first reading. "not_returned" covers the observed follow-up. "unknown" gives
  the top reason. The earlier level (br/min) is shown when it exists.
- **Repository.** `PhysiologyContextDocument` now carries `pulseEpisodes` and `dayNightHeartRate` (via `sleep`). One
  malformed spec-02 member (`pulse_episodes`, `sleep.day_night_heart_rate`,
  `bouts[].recovery.respiratory_recovery`) is removed before decoding and named in `undecodedMembers`, so the sleep
  summary and the bout survive. The history parser does the same for bouts.

## 3. Reason codes mapped

**Physiology context** (`PhysiologyContextWording.reasonPhrases`, localized):
`pulse_episode_high`, `pulse_episode_low`, `hr_acceleration_with_movement`, `episode_censored_gap`,
`episode_censored_qualification`, `qualified_inactive_hr_insufficient`, `cause_not_attributed`,
`not_rhythm_classification`, `percent_dip_definition`, `awake_hr_insufficient`, `sleep_hr_insufficient`,
`respiratory_reference_unavailable`, `respiratory_observations_resumed`,
`respiratory_returned_by_first_observation`, `respiratory_not_returned_in_follow_up`,
`respiratory_follow_up_unobserved`.

**Diagnostics-only:** `stable_awake_respiration_window`. I read it as a provenance code, like
`stable_awake_windows`. If the respiratory owner meant it to be user-facing, move it to `reasonPhrases`.

**`PhysiologyContextWordingCoverageTests`** now includes the `PulseEpisodes` registry. It also has a test-side
`Spec02Reserved` list for the CONTRACT §6 day/night and respiratory codes, whose registries live on the producer
branches. Once those branches merge the list is redundant (the test takes a set) and can be deleted. Any further
producer code must be added to `reasonPhrases` or `diagnosticsOnlyReasons` (the test fails until it is).

**Sleep features** (`SleepFeatureWording.phrases`, localized; 60 codes): the existing Python reasons, plus the spec-02
codes `multi_day_history_not_requested`, `insufficient_daytime_temperature`, `zero_amplitude`, `unstable_phase`,
`mixed_devices`, `insufficient_days`, `not_applicable`, `no_adjacent_pairs_within_runs`, `no_breath_intervals`,
`insufficient_pairs`. Some codes are **guessed** because the producers had not published their codes yet:
`insufficient_intervals`, `insufficient_evaluated_minutes`, `insufficient_segments`, `movement_history_unavailable`,
`no_short_nights`, `no_fragmented_nights`. An unknown code reads as humanized words. To add a code, add a line to
`phrases` and its catalog entry.

Lead follow-ups folded in: the prv_nonlinear reasons `not_main_night`, `no_rr_beats`, `insufficient_segments`,
`compute_budget_exceeded` (cardiac); the respiration/rebound/rhythm codes seen on the producer branches
(`insufficient_usable_windows`, `no_evaluable_windows`, `no_true_intervals_in_usable_windows`,
`unknown_time_never_stable`, `history_nights_not_in_request`, `history_nights_without_minutes_excluded`,
`insufficient_reference_nights`, `no_consecutive_night_pairs`, `pair_spans_timezone_change`, `descriptive_only`,
`duplicate_history_day_resolved`, `movement_history_absent`, `insufficient_days_around_clock_change`,
`insufficient_daytime`, `insufficient_daytime_heart_rate`, `insufficient_daytime_movement`,
`insufficient_sleep_periods`, `incomplete_daily_profile`, `no_clock_change`, `no_consecutive_hour_pairs`,
`not_main_night`, `phase_unavailable`, `quadrant_unobserved`, `temperature_phase_unavailable`,
`unstable_sleep_midpoint`, `zero_activity`, `zero_variance`, `fit_failed`, `invalid_timezone_days`); PC codes
`episode_censored_window` (pc-cardiac, not in CONTRACT) and `respiratory_return_unconfirmed` (respiratory).
`cutoff_reached` was already worded. The rhythm producer's phase labels `heart_rate_acrophase`,
`skin_temp_acrophase`, `sleep_period_midpoint` are mapped.

**Respiratory / rhythm final branches** (`d074d8011`, `3d782eb8c`), also folded in: `nap`, `hr_insufficient_days`,
`hr_quadrant_unobserved`, `hr_zero_amplitude`, `hr_unstable_phase`, `hr_fit_failed`, `no_short_nights_observed`,
`no_fragmented_nights_observed`, `after_short_insufficient_pairs`, `after_fragmented_insufficient_pairs`. A rebound
set with pairs but no median (below `min_pairs`) reads "n pairs, too few to summarize". The temperature IS/IV row is
labelled "Temperature regularity (IS / IV)" (the producer's `regularity_name` = `temperature_regularity`). The
rest-activity chapter renders IS/IV/L5/M10/RA/days/signal when the block is available (tested), and its reason
when it is withheld. `SleepMetricStatus.unavailable` (rhythm branch's one-line enum addition, applied verbatim)
counts as not showable. **Bug fix:** `MeasurementContextSelection.dayStableAwakeComparisons` derived the series
name from the envelope's `windowS`, so a 2-minute RR envelope looked for `resp_rate.stable_awake_2min`. Respiratory
envelopes now use the reference's own 5-minute grid (`resp_rate.stable_awake_5min`). On this branch the foundation
`stableAwakeSeriesKey` returns nil for respiratory rate, so the fix only takes effect after the respiratory branch
merges. It has no test here.

**StressView (cardiac's rewritten frequency section)**: its new `String(localized:)` / `LocalizedStringKey`
strings are now catalog entries in all nine locales (`%lld ms²`, `0.15–0.40 Hz · optical PRV`, `LF/HF ratio`,
`Optical PRV · descriptive`, the full-window coverage footnote with positional `%1$lld/%2$lld/%3$lld`, the HF-only
note, and the three "not shown" reasons). `StressView.swift` itself is not edited on this branch (cardiac-owned);
the keys match the cardiac branch's literals byte for byte, so they apply once it merges.

**Sleep analytics** reasons are a closed Swift enum and already fully worded (`SleepAnalyticsWording`). I added
`morningReason`, so `insufficient_coverage` on a morning side reads "too few valid minutes on one side".

**Localization.** I added 118 new keys to `Strand/Resources/Localizable.xcstrings` (one-line entries at the top,
the same as existing entries), with en plus all nine locales present: de, es, fr, it, pl, pt-PT, ru, zh-Hans and
zh-Hant. They cover every new `String(localized:)` key: physiology-context wording and sections, the sleep-feature
reason phrases, and "another reason". "Not available" already existed. The card labels in the sleep sections stay
plain English, the same as the rest of those two sections, which were never localized. Localizing them is a separate
pass.

## 4. Edits to root-owned files

`Packages/StrandAnalytics/Sources/StrandAnalytics/SleepFeatureDocument.swift` (decode-only, additive):
0a. The rhythm branch's `SleepMetricStatus.unavailable` case, applied verbatim from `3d782eb8c` (an identical hunk).
0. The cardiac branch's `prv_nonlinear` decoder hunk (`segments_available`, `segments_evaluated`, `dfa_overlap`,
   `max_segments`) applied verbatim from `7f7f4ab60` (identical hunk, so it merges cleanly) so the card can render
   those fields.
1. `SleepPhaseRelations` now also decodes the CONTRACT §5.4 keys `hr_minus_temp_acrophase_h` and
   `sleep_midpoint_minus_temp_acrophase_h`. The foundation decoder read only `hr_minus_temp` and
   `sleep_midpoint_minus_temp`, so a contract-shaped document silently decoded to nil. Both spellings are accepted
   now; the encode keys are unchanged.
2. `SleepMetricGate` falls back to a single `reason` string when `reasons` is absent. CONTRACT §5.4 writes
   `phase_status` as status plus reason. Note that `"unavailable"` is not a `SleepMetricStatus` case, so it decodes
   as `.unknown`. The UI treats anything other than `available` as withheld.

## 5. Other robustness changes (app-owned)

- `HostedDayResult.sleepAnalytics(from:)`: `SleepAnalyticsDocument` is a strict decoder. If the full decode fails, it
  retries without one spec-02 part at a time (`morning_response`, then `stage_movement` plus its note, then the pNN50
  fields), then without all of them. A malformed new group therefore never loses the existing groups. A broken core
  group is still rejected.

## 6. Tests

- `StrandTests/Spec02SleepFeaturesReadbackTests` (new). Covers the regression (with and without analytics), the old
  document, a round trip for every new block, withheld blocks and sub-blocks, the decoder aliases, wording, and the
  no-clinical-claims scan.
- `StrandTests/Spec02SleepAnalyticsReadbackTests` (new). Covers exact decode, pNN50 available and unavailable, slope
  labels, the morning response with per-signal coverage, stage movement with its disclosure, the old document
  rendering identically, and survival of malformed groups.
- `StrandTests/Spec02PhysiologyContextReadbackTests` (new). Covers wire keys, day/night medians and coverage, a
  missing side, pulse episodes (exposure, thresholds, "not evaluated" versus 0, no clinical words), respiratory return
  through the history parser and all four states, the old document, and survival of malformed members.
- `StrandTests/PhysiologyContextWordingCoverageTests` (registry extended). `SleepFeatureDocumentTests.realisticFixture`
  is now internal, so the old-document fixture can be reused.
- `supabase/functions/tests/spec02_readback_route_test.ts` (new, Deno). The hosted snapshot and the scores route carry
  the spec-02 `sleep_analytics_v1` and `sleep_features` verbatim. The `/context` and `/context/history` responses pass
  the new members through verbatim. An older snapshot is unchanged. Result: **5 passed, 0 failed**. The existing
  `sleep_analytics_route_test.ts` passed 4/4.

Results: see §8.

## 7. Integration notes for the lead (producer field names I assumed)

- `DayNightHeartRate`: built against the foundation fields. The final pc-cardiac branch (`635bb95a7`) adds the
  optional `method`, `units`, `minSamplesPerSide` and `awakeWindow`, plus `PulseEpisode.coverage` /
  `evidence_source` and `PulseEpisodeSummary.units` / `window` / `evaluated_span` / `evidence_seconds`. None of these
  are shown yet; each would take one more row.
- `PulseEpisodeSummary.thresholds` diagnostic names (`high_enter_bpm`, `high_exit_bpm`, `low_enter_bpm`,
  `low_exit_bpm`, `min_duration_s`), episode `kind` (`sustained_high`, `sustained_low`) and `context` (`asleep`,
  `awake`, `mixed`, `unknown`) were checked against `635bb95a7`. They match.
- The day/night codes are string literals in `MeasurementContextDetailView`, because the
  `SleepRhythm.awakeHrInsufficient` and related constants exist only on the producer branch. Switch to the constants
  after the merge.
- `RespiratoryRecovery.state` values: `returned`, `returned_by`, `not_returned` and `unknown`.
- Phase-relation labels (`a_label` / `b_label`) are mapped for `hr_acrophase`, `temp_acrophase` and `sleep_midpoint`.
  Anything else is shown title-cased.
- `rest_activity_rhythm.signal == "gravity_movement_seconds_per_minute"` is worded as wrist movement seconds per
  minute.
- Clock-change `kind` values: `dst` and anything else (shown as a time-zone change).
- `acrophase_h`, `l5_start_h` and `m10_start_h` are shown as local clock hours (`HH:mm`).
- The `Spec02Reserved` list in the wording test can be removed once SleepRhythm, ExertionBouts and ContextReferences
  register their codes.
- The golden pair and `CURRENT_ALGORITHMS.md` are untouched.
