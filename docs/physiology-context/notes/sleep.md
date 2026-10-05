# System C — sleep, waking time and daily rhythm (notes)

Workstream: sleep & history. Branch `pc/sleep`, based on the contract commit `71dce34a`.

| File | Content |
| --- | --- |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/PhysiologyContext/PCSleepRhythm.swift` | Implementation (`SleepRhythm`), config, sleep types |
| `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/PCSleepEpisodeTests.swift` | Episodes and wake reference (V06, V10) plus the shared `PCSleepFixture` |
| `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/PCSleepEvidenceSummaryTests.swift` | Sleep/wear evidence, summary, dependence (V02/V10 quiet motion, V06 travel, V13), engine integration |

Every contract signature is unchanged. Additions: fields with defaults on `SleepWearContext`, `SleepEpisode`,
`WakeReference` and `SleepRhythmSummary`; new types (`SleepStageSummary`, `MainSleepSummary`, `NapSummary`,
`SleepFragmentation`, `SleepLossSummary`, `SleepTimingSummary`, `RhythmDescriptor`, `RhythmPhaseEstimate`,
`SleepFeatureState`); config fields on `SleepConfig`; one extra public overload
`episodes(sessions:priorSleep:identity:mode:cutoff:config:)` (the contract overload calls it with no prior nights).

## 1. Inputs as they really are

- Sessions are the published snapshot's `sleep[]` entries. The detector is a gravity-stillness spine **confirmed with
  heart rate** (`SleepStager.confirmSleepWithHR`, `detectSleep`), with HR-only sessions possible. It reports a run only
  once it exceeds 60 min (`minSleepMin`), never longer than 16 h (`maxMainSleepSpanS`), and bridges re-onsets within
  90 min (`nightContinuationGapMin`, `sparseBridgeGapMin`). V2 staging reads HR, HRV and RSA respiration. Staging is
  unverified and never a condition here.
- **The scorer's `is_nap` is always `false`.** `legacyNights` in `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift`
  hardcodes `"is_nap": false`, so `false` carries no information. Only `isNap == true` is honored. Otherwise the app's
  own rule decides (`honorScorerNapFalse = false`). This deviates from "scorer isNap when present", but honoring the
  hardcoded `false` would turn every nap into a main sleep.
- A snapshot for day D publishes only the sessions **owned by D**, that is, ending on D (`AnalyticsEngine.analyzeDay`
  `matched`). Whether "no session here" means "awake" therefore depends on which owner days' snapshots were read
  (§3.2).
- Band sleep state is `(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up (`SleepStager.bandStateAsleep`). It is
  vendor-derived and its inputs are undocumented. `still` makes no sleep/wake claim.

## 2. Episodes — `episodes(sessions:identity:mode:cutoff:config:)`

1. **Availability.** Each record's availability is `availableAt`, or the session **end** when that is unknown,
   because a record that carries an end cannot exist before it (`session_availability_basis_end`). In causal mode, a
   record is dropped if it starts at or after the cutoff or became available after it. A record available before the
   cutoff that claims an end after it is clipped to the cutoff and marked incomplete
   (`session_end_clipped_to_cutoff`). No future end is ever produced.
2. **Revisions.** Records with the same id are resolved in this order: latest availability, then later end, then
   earlier start, then the record that came from the day's input, then an FNV tie-break over the canonical encoding
   (`session_revision_resolved`). Input order does not matter.
3. **Overlaps.** The detector never reports overlapping sleep, so overlapping records with different ids are versions
   of one night (a refined onset changes the id `sleep-<device>-<start>`). The preferred record wins
   (`overlapping_session_superseded`).
4. **Completeness** (both modes): `complete = end ≤ cutoff − completionMarginS` and the record was not clipped. An
   incomplete episode keeps its known interval. Its end is never used as an awakening, and the time after it is never
   presumed awake (`session_reaches_cutoff`, `owner_day_provisional`). A complete episode whose end is younger than
   `detectorExtensionHorizonS` is flagged `detector_may_extend`: its awakening is the one known at the cutoff, and a
   later re-onset could extend it retrospectively.
5. **Ownership.** The day's own sessions are owned by the local day, in the identity zone, that contains the end. This
   is the existing rule and is DST-correct through `localTime`. A history session keeps its `sourceDay` (the day it
   was scored in, in that day's zone). `source_day_differs_from_owner_day` records a disagreement.
6. **Main sleep vs nap**, per owner day:
   - `isNap == true` makes the session a nap (`scorer_nap_flag`).
   - Otherwise `SleepStageTotals.mainNightGroupIndices` decides. This is the app's rule: bridged groups (< 60 min
     gap, or < 90 min for an overnight-onset tail), then score = minutes + an alignment bonus to the learned habitual
     midsleep (≥ 14 days; else the 03:30 cold-start anchor). The winning group is `main_sleep` and every other session
     that day is a `nap` (`main_night_rule_applied`, basis `main_night_group_rule`).
   - The zone offset passed to that rule is the owner day's offset at local midday. The habitual midsleep comes from
     complete episodes of earlier owner days, so it needs the `priorSleep` overload. The contract overload passes no
     prior nights, which means cold start.
   - Classification is provisional (`classification_provisional`) while the cutoff is before the owner day's end or a
     member is incomplete.
7. **Split sleep.** Main fragments that the same two-tier bridge folds together share
   `splitGroupId = "split:<first fragment id>"` (`split_sleep`).
8. **Finality.** Causal episodes are always `provisional`. A retrospective episode is `final` once it is complete and
   the cutoff is at least `owner day end + finalAfterDayEndS` (30 h, mirroring `JoinConfig`).
9. **Stages.** The stage spans are clipped to the episode and recorded as light/deep/rem seconds, wake seconds,
   wake-after-onset segments and staged seconds. They are labelled `stage_derived_unverified` (`stages_unverified`)
   and are auxiliary only.

`unclassified` is reserved; every built episode is classified.

## 3. Sleep and wear evidence — `sleepWear(for:episodes:observations:config:)`

The support is cut into `coverageBinS` bins. The observations must be sorted by `ts`. Binary search is used; if the
slice boundaries show disorder, the code falls back to a full scan.

### 3.1 Sleep state

- **Asleep (detector):** seconds of the support inside episodes, using the union of complete and incomplete known
  parts.
- **Awake (detector), `outside_detected_sleep`.** This is positive evidence only. All three conditions must hold for
  the part outside episodes:
  1. HR coverage of that part is at least `detectorCoverageMinShare`. The detector cannot confirm sleep without HR, so
     a gap is not "no sleep". Failure gives `detector_input_missing`.
  2. Lag: `support.end ≤ HR data end − awakeEvidenceLagS`, or a later episode is already known. Failure gives
     `detector_lag_window`.
  3. Owner days read (§3.2). Failure gives `detector_owner_days_unread`.
- The time after an incomplete episode's known end is excluded from awake evidence (`overlaps_incomplete_episode`).
- **Band state** applies only outside episodes. Asleep (2) or awake (0, 3) counts when the detector gives no wake
  evidence. When the detector says awake but the band says asleep, the bin counts as neither
  (`sleep_sources_disagree`). Any band use adds `band_state_inputs_undocumented`.
- **State:** asleep or awake when its share is at least `stateMinShare`. `mixed` when both shares are at least
  `mixedFloorShare`. Otherwise `unknown`, with reasons (`sleep_evidence_insufficient` if nothing more specific
  applies).
- `inside_split_sleep_gap` marks a support that lies in the gap between fragments of one split main sleep.
- `sleepDependsOnHeartSignals = true` whenever any evidence was used. The detector reads HR, and the band's inputs are
  undocumented, so neither is independent.
- Quiet motion is never used for sleep or wake.

### 3.2 Which snapshots were read

A session that could cover the support ends after the support starts. It is published by the end of the HR data, and
it is at most 16 h long, so its owner day lies between `day(support.start+1)` and
`day(min(support.end−1+16 h, dataEnd))`.

If the support ends before the latest known episode end, a session from a later owner day would overlap that episode,
which the detector never produces. In that case the upper bound is `latestEnd`.

Every day in that range must be an owner or source day of some episode. Consequences:

- **Causal:** the HR data stops at the cutoff on day D. Only D's sessions are needed, and awake evidence works.
- **Retrospective without D+1 sessions:** a session owned by D+1 that started in D's afternoon or evening cannot be
  excluded, so those supports stay `unknown`. **The worker must include the next owner day's sessions in
  retrospective inputs.** See the requests below.
- A day whose snapshot had no session at all is indistinguishable from an unread day. The result is conservatively
  unknown.

### 3.3 Wear state

For each bin:

- An HR sample means `worn` (`heart_rate_signal_present`, `wear_from_heart_signal`, and
  `wearDependsOnHeartSignals = true`). If a wear event says off-wrist at the same time, the bin is still worn and
  `wear_sources_disagree` is recorded.
- Otherwise, an on-wrist event span with any HR or motion sample in the bin means `worn` (`wear_events`).
- Otherwise, an off-wrist span means `not_worn`.
- Otherwise the bin is unknown.

An event holds until the next event and never across a `SanitizedObservations.breaks` interval. The states
`worn`/`not_worn` need a share of at least `wearMinShare`; `mixed` needs both shares at least the mixed floor.
Unknown carries `no_wear_evidence` or `wear_evidence_insufficient`. Motion never establishes worn on its own.

## 4. Wake reference — `wakeReference(at:episodes:mode:cutoff:config:)`

The latest episode that started at or before `ts` decides first:

- If it is incomplete (or, in causal mode, ends after the cutoff), the result is `sleep_in_progress`.
- If it contains `ts`, the result is `inside_sleep_episode`. A person who is asleep has no "time since waking".

Otherwise the reference is the most recent **complete** main sleep that ended at or before `ts` within
`wakeReferenceMaxAgeS`. If a nap ended later, `nap_after_main_wake` and `latestNapEndAt` record it. If no main sleep
qualifies, the most recent complete nap is used (`no_main_sleep_reference`). The result is unknown with
`no_completed_sleep_before` (plus `reference_beyond_lookback` when the only awakening is too old).

Further flags:

- `wake_may_be_revised` is set when the reference episode is `detector_may_extend`.
- `inside_split_sleep_gap` is set inside a split night.

Seconds are real UTC seconds, so they stay correct across DST jumps. Causal mode never reads an episode ending after
the cutoff.

## 5. Summary — `summary(episodes:priorSleep:identity:observations:mode:cutoff:config:)`

- **Episodes:** all episodes passed in, sorted.
- **Main sleep:** the main episodes owned by the day. `mainSleepId` is the longest fragment.
  - `MainSleepSummary` holds the span, `durationS` (the sum of fragment durations, gaps excluded), `complete`, the
    split group, `fragmentGapS` (detector-derived) and `stageAsleepS` (auxiliary).
- **Naps and total sleep:** naps owned by the day, complete ones only. `totalSleepS` is nil when the day has no
  episode (missing is not zero) or while one is still in progress (`sleep_in_progress`).
- **Fragmentation:** stage-derived and unverified (`stagedShare` included). It is nil, with `stages_unavailable`, when
  the main sleep has no stages.
- **Prior nights:** history `priorSleep` is filtered to sessions ending at or before the day start. The input's own
  earlier-day episodes are added, then the same resolve and classify path runs. This is also a causal availability
  filter.
  - A prior night counts when its owner day lies in the last `priorNights` days and it has a complete main sleep.
  - The engine currently passes `rawHistory.priorSleep`, so this filter is what keeps same-day history out.
- **Sleep loss:** the day's main-sleep duration against the median of prior nights' main-sleep durations. It reports
  `differenceS`, `lossS = max(0, median − current)` and `supportNights`. It is `unknown` with
  `prior_nights_insufficient` (fewer than `minPriorNights`), `main_sleep_incomplete` or `no_main_sleep`.
- **Timing:**
  - Onset, midpoint and wake are `LocalTimeRef`s (zone, UTC offset, local day, seconds of day). Midpoint and wake are
    nil until the main sleep is complete.
  - The change against prior nights uses a circular median: prior values are unwrapped around their circular mean, so
    23:50 and 00:10 are 20 min apart. It reports a signed circular change in seconds.
  - Regularity is the circular SD of prior midpoints, reported at `minPriorNights` or more.
  - Prior nights are read on today's clock (`prior_zone_assumed_same`). `utc_offset_changed_in_window` marks a DST
    change inside the window; the comparison is on the wall clock.
- **Travel / zone.** The input carries only the day's zone. `timezone_history_unknown` is recorded and
  `changeVerifiable = false` is set when either:
  - midpoint and wake both shift by whole hours (at least 1 h, ± `timezoneShiftToleranceS`, and within that tolerance
    of each other), which is what a zone change looks like; or
  - a prior session's `sourceDay` disagrees with its end's local day in today's zone.
  - A recorded travel exposure is handled by System E.
- **Rhythm:** `proxy_hr_day_night_contrast`, the median awake HR on the day minus the median main-sleep HR.
  - It is marked `isProxy` and `dependsOnHeartSignals`, with `rhythm_proxy_only` and `labels_read_heart_rate`. The
    sleep side was selected with HR, so the contrast is partly built in.
  - It needs a complete main sleep and at least `rhythmMinSamples` samples on each side.
- **Phase:** always `unavailable` (`endogenous_phase_unmeasured`). The inputs (HR, behaviour) cannot measure
  endogenous phase or a core-temperature minimum (research §7, §12). Phase never blocks any other field.
- **Dependence (V13):**
  - `sleep_detector` with members [sleep_wake, sleep_stages, heart_rate, hrv_rmssd, respiratory_rate] and note
    `sleep_labels_read_heart_signals`. Always present.
  - `wear_heart_signal` with members [wear_state, heart_rate] and note `wear_from_heart_signal`. Always present.
  - `band_sleep_state` with note `band_state_inputs_undocumented`, when band samples exist.
  - `rhythm_proxy` with note `rhythm_proxy_reads_heart_rate`, when the contrast is computed.
- **Finality:** causal summaries are `provisional`. A retrospective summary is `final` once the cutoff is at least
  `day end + 30 h` and every episode the day owns is final.

**Live vs retrospective:**

- Causal features use only what was available by the cutoff, and only complete episodes for durations, loss, timing,
  rhythm and awakenings.
- Retrospective features use final sessions, later revisions and later owner days.
- V10: appending later sessions, late-published naps or a later awakening leaves the causal episodes and the encoded
  summary byte-identical.

## 6. Defaults

| Field | Default | Justification |
| --- | --- | --- |
| `completionMarginS` | 1800 | Detector end placement needs post-end data: 15-min centered still window (`stillWindowMin`) + 15-min run merge (`mergeMin`) ≈ 22.5 min, rounded up. |
| `detectorExtensionHorizonS` | 5400 | Re-onsets within 90 min are bridged (`nightContinuationGapMin`, `sparseBridgeGapMin`). |
| `honorScorerNapFalse` | false | The current scorer hardcodes `is_nap: false`. |
| `finalAfterDayEndS` | 108000 | Mirrors `JoinConfig.finalAfterDayEndS` (next night attributable until then). |
| `stateMinShare` / `mixedFloorShare` | 0.9 / 0.1 | Same floors as the join's dominant (90 %) and mixed (10 %) rules. |
| `detectorCoverageMinShare` | 0.8 | "Most of the support"; the detector needs HR to confirm sleep. |
| `coverageBinS` | 60 | The detector's assumed sample interval (`defaultIntervalS`). |
| `awakeEvidenceLagS` | 5400 | A run is reported only after 60 min (`minSleepMin`) + 30 min allowance for scoring latency. |
| `sessionSpanCapS` | 57600 | `SleepStager.maxMainSleepSpanS`. |
| `wearMinShare` | 0.8 | Same "most of the support" rule as coverage. |
| `wakeReferenceMaxAgeS` | 86400 | Beyond a day the reference would assume no undetected sleep since. |
| `priorNights` / `minPriorNights` | 14 / 5 | 14 nights is the history the worker loads (`HistoryInput.priorSleep`). A median of fewer than 5 nights is dominated by single nights; research §12 asks for whole weeks for regularity. |
| `timezoneShiftMinS` / `timezoneShiftToleranceS` | 3600 / 600 | Zone offsets are whole hours (half-hour zones are not detected; see §8). |
| `rhythmMinSamples` | 1800 | 30 min of 1 Hz HR per side. |

These are engineering starting points, not validated cutoffs. Every field is in `Policy.fingerprint`.

## 7. Reason codes (`SleepRhythm.reasonCodes`)

| Code | Where | Meaning |
| --- | --- | --- |
| `session_revision_resolved` | episode | Several records shared the id; the latest available won |
| `overlapping_session_superseded` | episode | An overlapping record (another version of the night) was dropped |
| `session_availability_basis_end` | episode | `availableAt` unknown; availability taken as the session end |
| `session_end_clipped_to_cutoff` | episode | Causal record claimed an end after the cutoff; clipped, incomplete |
| `session_reaches_cutoff` | episode | End within `completionMarginS` of the cutoff: incomplete, not an awakening |
| `detector_may_extend` | episode | Complete, but a re-onset could still extend it |
| `owner_day_provisional` | episode | Owner day from a provisional end |
| `source_day_differs_from_owner_day` | episode | Publishing day ≠ end's local day in the document zone |
| `classification_provisional` | episode | Owner day still open or a member incomplete |
| `scorer_nap_flag` | episode | Classified by the scorer's explicit nap flag |
| `main_night_rule_applied` | episode | Classified by the app's main-night group rule |
| `split_sleep` | episode, main summary | Fragment of a split main sleep |
| `hr_only_session` | episode | Detected from heart rate alone |
| `stages_unverified` | episode, summary | Stage figures are unverified and auxiliary |
| `invalid_support` | sleep/wear | Empty or inverted support |
| `no_detector_output` | sleep/wear | No episode at all; absence of sleep is not evidence |
| `detector_input_missing` | sleep/wear | HR coverage outside detected sleep below the floor |
| `detector_lag_window` | sleep/wear | Too close to the HR data end for the detector to have reported a run |
| `detector_owner_days_unread` | sleep/wear | A snapshot that could hold a covering session was not read |
| `partially_in_detected_sleep` | sleep/wear | Some but not most of the support is in detected sleep |
| `overlaps_incomplete_episode` | sleep/wear | Support touches an in-progress episode or follows its known end |
| `inside_split_sleep_gap` | sleep/wear, wake | Between fragments of one split night |
| `sleep_sources_disagree` | sleep/wear | Detector awake vs band asleep |
| `band_state_inputs_undocumented` | sleep/wear, dependence | Band state used; vendor-derived, undocumented inputs |
| `sleep_evidence_insufficient` | sleep/wear | Unknown with no more specific reason |
| `no_wear_evidence` / `wear_evidence_insufficient` | sleep/wear | No wear evidence / not enough of the support |
| `wear_sources_disagree` | sleep/wear | Off-wrist event while an HR signal is present |
| `wear_from_heart_signal` | sleep/wear, dependence | Wear evidence is heart-derived |
| `no_completed_sleep_before` | wake | No complete episode before the instant |
| `sleep_in_progress` | wake, summary | Latest episode incomplete; no final length / awakening yet |
| `inside_sleep_episode` | wake | The instant lies in sleep |
| `reference_beyond_lookback` | wake | Last awakening older than `wakeReferenceMaxAgeS` |
| `nap_after_main_wake` | wake | A nap ended after the reference main sleep |
| `no_main_sleep_reference` | wake | Reference is a nap |
| `wake_may_be_revised` | wake | Reference episode is `detector_may_extend` |
| `reference_time_after_cutoff` | wake | Causal instant after the cutoff |
| `no_sleep_episodes` / `no_main_sleep` / `main_sleep_incomplete` | summary | As named |
| `prior_nights_insufficient` | summary | Fewer than `minPriorNights` prior main sleeps |
| `stages_unavailable` | summary | Main sleep without stages: no fragmentation |
| `timezone_history_unknown` | summary | Timing change may be a zone change the input cannot verify |
| `prior_zone_assumed_same` | summary | Prior nights read on today's clock |
| `utc_offset_changed_in_window` | summary | DST change inside the comparison window |
| `rhythm_proxy_only` / `labels_read_heart_rate` | rhythm | Proxy; sleep side selected with HR |
| `rhythm_samples_insufficient` | rhythm | Too few HR samples |
| `endogenous_phase_unmeasured` | phase | Phase is never estimated |
| `sleep_labels_read_heart_signals` / `rhythm_proxy_reads_heart_rate` | dependence | Dependence notes |

## 8. Limitations

- **Short sleep is invisible.** The detector reports runs of at least 60 min. "Outside detected sleep" therefore means
  "no detected run of at least 60 min", and a 40-min nap reads as awake.
- **Incompleteness is judged against the cutoff, not the publishing run's data end.** A night whose data stopped
  syncing at E and was published then can look complete hours later. A `dataThrough` field is requested to fix this.
- **The HR data end stands in for the detector's data end** in the lag rule. Scoring latency beyond 30 min is not
  covered.
- **The zone heuristic is approximate.** It flags any genuine whole-hour shift that moves midpoint and wake together.
  It misses half-hour zones and small zone changes. A per-session zone is requested.
- **The contract overload of `episodes` classifies with cold-start timing.** It has no habitual midsleep, and earlier
  owner days are classified only from the sessions in the input.
- **Rejected sessions are not reported** (invalid intervals, superseded or unavailable records). `summary` only sees
  episodes.
- **The rhythm proxy is masked and partly circular.** Its "sleep" side was selected with heart rate. No SRI is computed
  (it needs minute-level state over whole weeks).
- **These tests verify arithmetic and integration only.** None is a physiological validation of the detector, the
  stager or the band state.

## 9. Requests (files I do not own)

1. **Engine (`PCEngine.swift`):**
   - Call `SleepRhythm.episodes(sessions:priorSleep:identity:mode:cutoff:config:)` with
     `history.value.priorSleep`. This enables the learned habitual midsleep and full prior-day classification.
   - Pass `history.value.priorSleep` (not `rawHistory.priorSleep`) to `summary`. I filter it anyway.
2. **Engine `causalView` / `inputFingerprint`:**
   - Sleep sessions are kept when `start < cutoff` and `availableAt ?? true`, so a later record with unknown
     availability enters the fingerprint. I drop it, but the document header changes, which breaks byte identity
     under V10.
   - Please filter with `(availableAt ?? interval.end) <= cutoff`, the same basis System C uses.
3. **Contract (`PCContract.swift`):** add to `SleepSessionInput`:
   - `dataThrough: Int?`, the publishing snapshot's `dataThrough`, for an exact "detector could still extend" test.
   - `timezoneId: String?`, the snapshot `timezone`, so a prior night's zone is known instead of inferred.
4. **Contract:** state that `SanitizedObservations` streams are sorted by `ts` (System C uses binary search, with a
   full-scan fallback).
5. **Worker (`ContextInputs.swift`):**
   - For `retrospective`, include the sessions owned by D+1 (and D−1) in `sleepSessions`, with `sourceDay`.
     Otherwise afternoon and evening awake evidence is `unknown` by design (§3.2).
   - Map `availableAt` to the publishing snapshot's time.
6. **contracts.md §12:** consolidate the table in §7.

## 10. Test ↔ verification-case map

| Test | V-case | Independent expectation |
| --- | --- | --- |
| `testSpringForwardNightIsMeasuredInRealSeconds` | V06 DST | Day window `[1772956800, 1773039600)` = 23 h; 23:00 PST → 07:00 PDT = 25200 s; wake +2 h = 7200 s; wake offset −25200 |
| `testWakeReferenceAcrossTheSpringJumpUsesRealSeconds` | V06 DST | 01:30 PST → 03:30 PDT = 3600 s (2 h on the wall clock) |
| `testFallBackDayHasTwentyFiveHoursAndANineHourNight` | V06 DST | 25 h day; 23:00 PDT → 07:00 PST = 32400 s |
| `testSplitSleepFragmentsAreBothMainSleepWithOneGroup` | V06 split, naps | Both fragments main with one group; 27000 s main; 1800 s gap; nap 3600 s; 900 s since wake inside the gap |
| `testNapsMainSleepAndCrossMidnightOwnershipByEnd` | V06 naps, cross-midnight | Owner by end; nap after main gives 34200 s since main wake |
| `testScorerNapTrueIsHonoredAndAnUninformativeFalseIsNot` | V06 naps | Explicit nap wins; `false` falls back to the rule |
| `testUnfinishedNightIsIncompleteLiveAndCompleteRetrospectively` | V06 unfinished, V10 | Live: incomplete, end ≤ cutoff, `sleep_in_progress`; identical with the final record appended (known or unknown availability); retrospective complete, 7200 s |
| `testRecentWakeIsUsableButFlaggedAsRevisable` | V06 | 45 min since wake, `wake_may_be_revised` |
| `testCausalSessionClaimingAnEndAfterTheCutoffIsClipped` | V10 | No future end |
| `testNoWakeReferenceWithoutAnEarlierCompleteEpisodeOrBeyondTheLookback` | V06 | Unknown reasons |
| `testRevisionsAndOverlappingVersionsResolveToTheLatestAvailable` | V10 / revisions | Order-independent; live sees only records available by the cutoff |
| `testAppendingLaterSessionsDoesNotChangeTheCausalSummary` | V10 | Encoded causal summary byte-identical after appending later and late-published sessions |
| `testQuietMotionWithoutSessionsIsUnknownSleepAndWear` | V02 / V10 | Unknown sleep and wear with reasons; no HR dependence claimed |
| `testAwakeNeedsHeartRateCoverageOutsideDetectedSleepAndIsHeartDependent` | V02 / V13 | Awake only with coverage and lag satisfied; asleep / mixed / lag / gap cases |
| `testRetrospectiveAfternoonNeedsTheNextOwnerDaySessions` | V06 / V10 | Unknown without D+1 sessions, awake with them |
| `testIncompleteNightEndIsNotPresumedAwake` | V06 | Not awake after an incomplete end |
| `testBandSleepStateAddsEvidenceAndConflictsAreNotResolvedSilently` | V13 | Band evidence flagged; conflict is unknown |
| `testWearEventsAndBreaks` | V02 | Events, motion with events, break, contradiction |
| `testRecentSleepLossAgainstPriorNightsMedian` | V06 / V12 | 6 h vs 8 h median gives −7200 s; 3 nights is unknown (not zero); live incomplete gives no loss |
| `testTimingChangeIsCircularAcrossMidnightWithARegularityDescriptor` | V06 | Median midpoint 0 (a linear median gives 1200); change 3600; SD ≈ 849 s |
| `testTravelShiftByWholeHoursIsFlaggedUnverifiable` | V06 travel | London → New York +5 h flagged; a genuine 2.5 h shift is verifiable |
| `testStageFragmentationIsAuxiliaryAndRhythmIsAProxyWithDependenceNotes` | V13 | One WASO segment, 2100 s wake; contrast 75 − 55 = 20 (proxy); phase unavailable; `sleep_detector` note members; JSON round trip |
| `testEmptyDayIsUnavailableNotZeroAndPhaseNeverBlocks` | V12 | Nil totals, structural dependence |
| `testEngineDocumentCarriesSleepContextAndRoundTrips` | V13 / integration | Envelope at noon awake, 5 h since wake; 03:00 asleep; document round trip |

A mutation check confirmed the tests discriminate. Three deliberate defects (availability basis = start, zone
heuristic disabled, linear median) made 5 assertions fail across 3 tests. The source was restored afterwards.

## 11. Commands and results

Run from `Packages/StrandAnalytics`:

```
swift build                      # Build complete
swift test --filter PCSleep      # 24 tests (PCSleepEpisodeTests 12, PCSleepEvidenceSummaryTests 12), 0 failures
swift test --parallel            # 2572 tests, exit 0 (≈2530 baseline + 18 lead + 24 sleep), 24 s wall
```

A throwaway probe (not committed) ran 1440 `sleepWear` + `wakeReference` calls against 216 000 HR and 216 000 motion
samples in about 0.02 s, with `summary` at about 0.001 s (debug build).
