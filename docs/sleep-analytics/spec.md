# Nara sleep analytics: implementation and evidence specification

Research date: 6 October 2026. Repository: https://github.com/Rahulvijayan123/Nara-App.

Inspected baseline: `main` at `3ef5595956d51948b07a71f9f8e03d3908eca488`, committed 6 October 2026. This is a source-code audit, not confirmation of the version installed on a phone or deployed on the worker. Research and repository inspection were performed for this specification; the app was not built, modified, or clinically validated in this research task.

## 1. Decision and authorized implementation scope

Implement Phase 1: descriptive sleep continuity, stage dynamics, wrist movement, and skin-temperature trends using signals already loaded by the Swift scoring worker. Implement strictly gated SD1/SD2 pulse-interval diagnostics in the same shared Swift package; their presentation is optional and secondary. Keep the existing sleep detection, stage assignments, Rest/Charge scores, canonical RMSSD, and recovery calculations unchanged.

The easiest integration is a pure extractor in `Packages/StrandAnalytics`, published as an additive `daily.sleep_analytics_v1` object in the existing v2 hosted snapshot. Read that object through the existing owner-scoped server result and disk cache. No new production model, Python service, raw-data upload format, metrics table, BLE acquisition mode, or training pipeline is necessary for Phase 1.

“High confidence” means that the specified arithmetic and input lineage can be checked. It does not mean that a WHOOP-derived stage is equivalent to a PSG stage, that quiet movement proves sleep, or that wrist temperature identifies a true circadian phase. Display these features as estimates and observations.

Implement and test Phase 1 completely. Phase 2 and Phase 3 below document future work and its admission gates; they are not instructions to build every research idea now. Do not turn deferred features into placeholder numbers or enlarge Phase 1 to collect new sensor data. Build a reviewable feature branch and release notes. Live deployment, production backfills, and merging are outside this implementation task.

### Recommended order

| Priority | Deliverable | Engineering cost relative to this repo | Confidence and useful interpretation |
| --- | --- | --- | --- |
| 1 | Observed sleep continuity: wake after onset, sleep bouts, estimated awakenings, onset delay | Low, from existing timestamped stages | Strong arithmetic; measurement inherits the existing stager/source and coverage |
| 2 | Stage bouts, REM/deep latency, adjacent-stage transitions | Low, same normalized timeline | Describes estimated architecture; does not independently validate it |
| 3 | Movement percentage, movement bouts per observed hour, immobility bouts | Low, existing 1 Hz gravity + wear evidence | Wrist-movement descriptors, not EEG fragmentation or limb-movement diagnosis |
| 4 | Nightly temperature median/IQR and peri-sleep slopes | Low, existing skin-temperature stream and conversion gates | Approximate wrist-temperature trends; slope availability depends on pre/post coverage |
| 5 | SD1, SD2 and their ratio in valid 5-minute windows | Low arithmetic, stricter input-quality work | Optional PRV diagnostics; SD1 adds little information beyond existing RMSSD |

## 2. Audit of every proposed metric family

| Proposed family | Research and reusable method | Applicability to Nara and decision |
| --- | --- | --- |
| PPG autonomic arousals / amplitude drops | Published PWA-drop detectors measure peak-to-trough amplitude changes [3,4]. This is a deterministic algorithm, not a need for a new neural network. | Promising research candidate, not Phase 1. Continuous, correctly decoded amplitude and optical configuration are required. PWA drops are autonomic proxies and are not interchangeable with EEG arousals. |
| Sleep cycles / architecture | Feinberg/Floyd-style NREM–REM period rules are implemented by SleepCycles; hypnoR exposes alternative cycle policies [5,6]. | Stage summaries and latency can ship as estimates. A full cycle count stays deferred: policies differ, Nara combines N1/N2 as light, and current timing priors already encourage conventional cycles. |
| Stage dynamics | Standard hypnogram statistics, bouts and transition matrices are documented by YASA [1,2]. | Phase 1. Use deterministic Swift formulas and preserve gaps. Probability entropy requires actual model vectors; the current canonical stage segments contain labels only. |
| CPC stable/unstable sleep | Cardiopulmonary coupling uses coherent spectral power between beat intervals and independently derived respiration [7,8]. | Deferred research. Scalar breaths/minute is insufficient. Current default cloud inputs do not include the needed waveform. A generic coherence ratio is not automatically a validated stable-sleep percentage. |
| IMU fragmentation: kRA/kAR/SFI | Lim-style duration-dependent rest/activity hazards are implemented by pyActigraphy; GGIR handles raw-actigraphy workflows [9,10]. | Simple movement/immobility summaries ship first. Published kRA/kAR and actigraphy SFI need an explicitly comparable activity signal, epoching and thresholds. Naive transition counts are not the same estimator. |
| Nonlinear PRV | Poincaré SD1/SD2 have clear formulas; NeuroKit documents them and explicitly notes SD1's redundancy with RMSSD [11]. SampEn, DFA and multiscale entropy require more care. | SD1/SD2 can be optional diagnostics with strict beat/coverage gates. Defer entropy, DFA, multiscale entropy and HR-fragmentation interpretation pending a fixed protocol and validation. |
| PPG morphology | pyPPG extracts standardized fiducials and biomarkers [12]. | Deferred. It needs a waveform, reliable pulse timing and quality control. Finger-PPG feature validation does not establish WHOOP wrist validity, blood pressure or vascular age. |
| Respiratory events / ApSense | Author code uses fingertip PPG features and 60-second overlapping windows [13]. | Deferred. The inspected repository has training/evaluation code but no released checkpoint or license file. It is not a verified pretrained drop-in, and fingertip-to-wrist transfer is unvalidated. |
| Thermal sleep dynamics | A 2026 EEG-linked study supports peri-sleep distal-temperature trajectories [14]. | Descriptive wrist-temperature trends ship. A temperature-derived sleep-onset detector does not: the study measured finger temperature with Oura and used semi-automated rules with activity/nonwear exclusions. |
| Circadian IS/IV/M10/L5/RA/acrophase | Standard nonparametric rest-activity formulas are implemented by pyActigraphy [15–17]. | Later, after complete multi-day motion support is available. Current Nara cosinor uses hourly HR means; those are not interchangeable with actigraphy activity. Do not call its inferred phase a measured temperature minimum. |
| Oxygen ODI3/ODI4/T90/hypoxic burden | Event-associated desaturation area has primary cohort evidence and a published implementation [18,29]. | Blocked by sensor calibration and event provenance. Raw red/IR values and the repo's unresolved SpO2 candidate byte cannot support valid oxygen percentages or desaturation events. No algorithm can remove that blocker. |

### Important corrections to the earlier feature rationale

The frequently quoted 90.8% sensitivity and 99.6% specificity concern automated detection of human-marked PWA drops, not EEG arousal recognition [3,19]. A separate small study of 10 recordings reported approximately 65% sensitivity and 71% positive predictive value for visually scored EEG microarousals [4]. Therefore do not advertise a 91% sensitive arousal detector, AHI, or a validated autonomic-arousal severity score.

The current `SleepStagerV2.swift` has explicit early-deep/late-REM timing priors and a first-REM guard. Its historical transition-rule ablation reports four-class PSG kappa around 0.36 and wake sensitivity around 31%; a later settled-onset change reports kappa 0.399 and pre-onset wake recall 80%, with constants selected on that 31-subject cohort. These are different comparisons and repository-reported results, not a newly reproduced overall accuracy estimate or proof of independent generalization. Counts, cycles and “normal-looking architecture” derived from that output are not independent physiological evidence. Do not score stage reversals as abnormal or use the new descriptors to increase confidence in the same model that generated them.

## 3. Repository facts that determine the implementation

Read `AGENTS.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/CURRENT_ALGORITHMS.md`, `docs/IOS.md`, `docs/BACKEND.md`, and `deploy/README.md` before editing.

| Existing component | Fact and required reuse |
| --- | --- |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift` | Shared app/worker day computation. `DayResult.mainNightBlocks` carries the resolved main-night group. Use this group, including split nights; do not pick the longest session independently. |
| `SleepStageTotals.swift`, `SleepStageVocabulary.swift` | Shared night grouping and stage naming. Reuse them. DayResult selection and edit/recompute selection must refer to the same effective fragments. |
| `SleepStager.swift`, `SleepStagerV2.swift` | `StageSegment` contains start/end/label, not a probability vector. Some gaps can receive carried segment labels; labeled duration alone does not prove sensor support. |
| `Tools/CloudWorker/Sources/frwhoop-worker/DayScoring.swift` | Already loads HR, RR, respiration, gravity, skin temperature, wrist events and sleep state. Its broad read window is not the analysis window. Filter to the selected night and the explicitly defined peri-sleep intervals. |
| `snapshotDaily(...)` in `DayScoring.swift` | Add the new object to the v2 snapshot daily object, not the legacy column projection. |
| `contracts/deployed/public__publish_scoring_snapshot_v2.sql` | Stores the v2 JSON payload, including free-form `daily`, and allocates the result revision. Do not introduce a duplicate revision allocator. |
| `supabase/functions/_shared/serverScores.ts` | `readHostedSnapshot` passes through `payload.daily`. Preserve owner/device authentication and revision behavior. A contract test must prove the new nested object survives this route. |
| `Strand/Push/ServerScoreRepository.swift` | Contains `HostedDayResult`, retained raw snapshot JSON, disk cache and `HostedResultMaterializer`. Extend this path for typed sleep analytics. There is no separate `HostedResultMaterializer.swift` file. |
| `Strand/Screens/SleepModel.swift`, `SleepView.swift` | Existing night display and card/layout machinery. Use actual source stages, not synthetic intervals manufactured for totals-only imports. Keep expensive work outside SwiftUI body evaluation. |
| `HRVAnalyzer.swift` | Gap-aware cleaning and source/reliability rules already exist. Maintain original beat identity and adjacency. Strict new PRV diagnostic gates do not change canonical HRV. |
| `Tools/InferenceWorker` | Persistent loopback Python inference service already exists, with provider contracts, budgets, artifact hashes and shadow isolation. Phase 1 needs no call to it. Future waveform experiments should reuse it. |

### Signal audit: avoid the most expensive mistaken assumption

`ppgHrSample` is derived BPM/confidence, not an optical waveform. It cannot reconstruct pulse amplitude, pulse area, systolic time or respiration modulation.

Local `ppgWaveformSample` rows contain a v26 window: **one absolute base plus 24 signed differences, representing 25 reconstructed samples**. Use `ppgWaveformAbsolute(baseCode:deltas:)` in `Packages/WhoopProtocol/Sources/WhoopProtocol/HistoricalStreams.swift`. A missing base returns no absolute waveform. Old delta-only records must not be assigned a fake zero base. `isSaturatedPpgDelta` identifies encoding saturation that makes reconstruction approximate. Check `burstIndex`, boundaries, repeated endpoints and actual timing before joining windows. Neither one stored row per second nor 24 differences proves the acquisition rate.

The separate v20 parser `Whoop5RawOptical.swift` exposes multiple optical/configuration blocks. Their identifiers do not establish wavelength, gain calibration or continuity. Configuration changes can resemble amplitude drops. These sources are banked locally; the default cloud upload/scoring path does not supply continuous raw optical nights. The IMU object lane is a useful transport pattern for a later optical lane, not evidence that such an optical lane already exists.

Default sleep movement input is 1 Hz gravity, with optional `dynAccel`. Raw six-axis 100 Hz IMU is a separate capture/object workflow; its activity classifier lane is optional and disabled by default. Do not make Phase 1 depend on that classifier, assume raw IMU is present, or apply a 1 Hz gravity threshold to 100 Hz acceleration.

Skin-temperature conversion is family-aware. Reuse `skinTempCelsius(raw:family:anchorRaw:)` and `AnalyticsEngine.skinTempFunnel`. WHOOP 4 calibration is provisional; WHOOP 5/MG conversion follows the existing centidegree path. Preserve existing approximate-temperature labeling. The SpO2 candidate is expressly unresolved in the source and is not a calibrated oxygen input.

## 4. Shared extractor and timeline contract

Add `SleepAnalyticsV1.swift` to `Packages/StrandAnalytics/Sources/StrandAnalytics`. Split normalization, motion or thermal helpers into additional files only when it improves clarity. Public models/functions must be `Codable` where appropriate, `Equatable`, and `Sendable`; computation must be pure, deterministic, Linux-compatible and free of UI, DB, network and model-loading dependencies.

Suggested API, with exact names adjustable to repository conventions:

```swift
public enum SleepAnalyticsV1 {
    public static func compute(
        input: SleepAnalyticsInput,
        config: SleepAnalyticsConfig = .v1
    ) -> SleepAnalyticsDocument
}
```

`SleepAnalyticsInput` must carry selected effective fragments with stable IDs, start/end, source labels, source epoch resolution, edits/revision lineage; HR/gravity/temperature/RR within the bounded read; device family/calibration identity; timezone; optional explicit attempted-sleep marker; and stage/source support metadata. Adapters construct the input. The extractor must not choose a different main night or re-run a stager.

### Normalize once, then derive all timeline metrics

1. Use half-open intervals `[start, end)` and elapsed UTC seconds. Sort, clip to each effective fragment, discard invalid zero/negative spans and report their count. Day ownership/timezone follows the existing calendar-aware day logic; never assume a day is always 86,400 seconds.
2. Collapse exact duplicates and union overlapping intervals carrying the same label and source. Resolve source revision/edits before normalization. Conflicting overlapping labels at equal precedence become `unknown` over the conflict; do not add their durations or arbitrarily choose the label that yields nicer sleep.
3. Map labels through the shared vocabulary to wake/light/deep/REM. Unscored/artifact/unsupported labels become unknown. Do not invent N1/N2 from light or light/deep from NREM.
4. For native WHOOP stages, construct an input-support mask from the raw streams used by that stager. In v1, a native 30-second epoch is label-supported when at least 15 distinct seconds have valid HR or gravity evidence consistent with available wear evidence. Explicit off-wrist intervals override support. Record both actual distinct input-supported seconds and label-supported epoch duration: qualifying an epoch does not turn its missing raw seconds into observed sensor time. This is an engineering presence check, not a calibrated confidence probability. Put the definition in `SleepAnalyticsConfig` and expose its version. For clipped native epochs use the same ≥50% distinct-second rule against the clipped duration.
5. A low-cadence/timed external hypnogram can still support label summaries at its real resolution. Report `sensor_support_unknown`; do not imply that its physiological sensor coverage was verified from WHOOP data. Totals-only or synthetic imported timelines cannot support bout/transition/latency metrics. Mark those metrics `unsupported_source`.
6. Uncovered spans inside a fragment and unsupported native epochs are unknown, even if the stager carried a label over them. Do not forward-fill, interpolate, or treat absent samples as awake/asleep/still.
7. The existing canonical day aggregation explicitly treats certain bridged inter-fragment gaps as inferred awake via `SleepStageTotals.interFragmentAwakeSeconds`. Preserve existing totals. In the new document retain those gaps separately with origin `inferred_inter_fragment_awake`; they never create sensor coverage, completed bouts, or observed stage transitions. Return observed WASO and this inferred gap contribution separately. An optional combined estimate must state that it includes the existing gap assumption.
8. Keep discontinuities at fragment/source/resolution boundaries even when timestamps touch. Do not count a transition or join a bout across them.
9. Reconstruct native 30-second labels only where the original stager resolution and alignment are established. Do not subdivide coarse imported stages to manufacture 30-second self-transitions. Duration metrics can use actual interval lengths; the epoch transition matrix is unavailable for an unsupported/variable-resolution source.

Return the normalized timeline and masks internally, plus provenance/coverage in the document. Preserve original data; this extractor does not rewrite the hypnogram.

### Quality and missingness

Quality is per group/metric, not one attractive overall percentage. Compute covered time using interval unions and timestamp-aware support, not row counts. Expose fragment span, whole group span, observed labeled seconds, unknown seconds, inferred gap-awake seconds, actual input-supported seconds/fraction, label-supported fraction and source resolution. For HR/gravity/temperature retain received, valid, duplicate, rejected and supported-duration diagnostics. A metric called observed here is observed in the supported input/label record, not an independently observed PSG state.

Engineering defaults: complete stage summary requires at least 95% label-supported coverage of fragment time and, for native WHOOP output, at least 95% actual input-supported seconds. For external timestamped hypnograms the label gate can pass while sensor support remains explicitly unknown. Motion requires at least 80% eligible observed time and 30 observed minutes; thermal rules are in section 6; PRV rules are in section 7. These are conservative product rules, not published physiological validity thresholds. Version them and test their boundaries. Below a completeness gate, retain observed totals/bout lower bounds as partial, with denominator/coverage visible; withhold whole-night rates or claims that require complete observation. No input yields null/unavailable, never a fabricated zero.

For onset/first-REM/first-deep latency, the relevant timeline prefix must contain no unknown interval, irrespective of the overall 95% gate. If the first observed sleep run touches a left-censored source boundary without an observed preceding wake epoch, its true onset is not observed: report the detected-window delay only as a boundary estimate and withhold marker-based/physiological latency. A qualifying marker must precede the supported onset, share owner/device/session lineage, and lie within a fully observed attempted-sleep interval; future/ambiguous marks produce a reason, not negative latency.

Counts can be zero when qualifying observed exposure exists and no event occurs. A REM latency with no observed REM is null with `no_observed_rem`; with incomplete early coverage use `onset_not_observed` instead. A missing attempted-sleep marker is `missing_marker`, not zero latency.

## 5. Phase 1 continuity and stage metrics

All stage-related UI text says “estimated” or clearly identifies the source's estimate. Formulas follow ordinary hypnogram arithmetic [1,2], with additional Nara-specific gap handling.

| Field | Exact definition / unit |
| --- | --- |
| `observed_asleep_seconds` | Union duration of supported light+deep+REM intervals. Unknown excluded. |
| `observed_waso_seconds` | Supported wake duration between first observed asleep onset and last observed asleep end. Excludes initial/terminal wake, unknown time and inter-fragment gaps. |
| `inferred_gap_awake_seconds_within_sleep_period` | Existing canonical inferred inter-fragment awake duration intersecting that sleep period. Separate from observed WASO. |
| `estimated_waso_including_inferred_gaps_seconds` | Sum of the previous two fields when usable; explicitly an estimate, never “observed”. No changes to existing canonical daily totals. |
| `onset_delay_from_window_seconds` | First supported asleep onset minus effective detected-window start, only if the prefix is observed. This is not clinical SOL. |
| `sleep_onset_latency_from_marker_seconds` | First supported asleep onset minus a verified, explicitly intended attempted-sleep/lights-out marker paired to this night. Otherwise null. Map existing sleep marks only after confirming their semantics; do not add an unrequested diary system. |
| `rem_latency_from_sleep_onset_seconds` | First supported REM start minus first supported asleep start. Null if missing REM or a gap could conceal its first occurrence. YASA's documented default REM latency starts at recording start, so the oracle must subtract SOL [1]. |
| `deep_latency_from_sleep_onset_seconds` | Same rule for the first supported deep interval. Descriptive estimate, no clinical threshold. |
| `longest_observed_sleep_bout_seconds` | Longest continuously observed run of any asleep labels, allowing light/deep/REM changes. Wake, unknown and source/fragment boundaries split the run. Include a censoring flag when the run touches an unobserved edge. |
| `awakening_bout_count` | Wake bouts inside the sleep period with an observed sleep-to-wake entry and observed return to sleep. Edge/unknown-censored wake stretches are reported separately, not silently counted as complete awakenings. These are label-level awakenings, not EEG arousals. |
| `sleep_to_wake_transition_count` | All valid adjacent asleep-to-wake label changes inside fragments, including a terminal observed wake change. Preserve separately from complete awakening count. |
| `sleep_to_wake_transitions_per_asleep_hour` | Previous count divided by observed asleep seconds/3600; primary rate requires the complete-stage gate and ≥30 minutes observed asleep time. Counts still exist for short fixtures/naps. Named definition rather than ambiguous “SFI”. |
| `stage_bouts` | For each label: observed bout count, complete/censored counts, longest observed seconds, median and p90 complete-bout seconds. Median/p90 require at least 3 complete bouts; otherwise null. |
| `stage_seconds` | Union durations for wake/light/deep/REM/unknown. Do not add overlaps. |
| `epoch_transitions` | 4×4 counts on genuinely adjacent valid native epochs, including self transitions; rows are origin, columns destination, order `[wake, light, deep, rem]`. Store row exposure, row-normalized probabilities, native epoch duration and eligible pair count. A row with no outgoing pairs has null probabilities, not a zero-probability row. |
| `stage_change_count` | Number of eligible adjacent epoch pairs with different labels. For coarse timed imports expose actual observed bout changes separately; do not claim a native epoch matrix. |

Use nearest-rank p90: sorted value at `ceil(0.9*n)-1`; median is the mean of the two middle values for even n. Preserve seconds in storage and convert to minutes only for presentation. Bouts touching a fragment edge or unknown span carry left/right censoring flags. Never calculate clinical “abnormality”, neurological risk or an optimal transition score from these descriptors.

Do not construct probability vectors from labels. HMM emission scores are not calibrated probabilities. If an existing shadow model already returns vectors, preserve class order and provenance in its own candidate output. Entropy/hypnodensity remains a candidate diagnostic, not a Phase 1 UI promise or a requirement to retrofit posterior inference into the Swift stager.

## 6. Phase 1 movement and thermal metrics

### Movement

Use the existing one-second gravity stream and valid wear evidence in the selected fragments. For consecutive, unique, finite, plausibly decoded samples at t−1 and t, compute `delta_g = norm(g[t] - g[t-1])`. The v1 threshold is the shared stager stillness threshold `SleepStager.gravityStillThresholdG` (0.01 g at the inspected baseline). Document that this is a device-specific movement proxy. `dynAccel` is not interchangeable without a separate validated feature definition; default v1 does not substitute it.

Only a true one-second supported adjacency contributes a classified second. Missing samples, off-wrist intervals and source/configuration changes break runs. Prefer the repository's verified wear evidence; where using valid contemporaneous HR as a presence proxy, record that method. Absent HR is unknown evidence, not proof of nonwear. Do not derive movement from a plotted/smoothed chart.

Return movement seconds, eligible seconds, movement percentage `100*moving/eligible`, movement-bout count, movement bouts per eligible observed hour, complete/censored immobility-bout counts, longest observed immobility, and median/p90 complete immobility-bout durations. Use at least 3 complete bouts for quantiles and the section 4 exposure gate for the primary UI rate. Keep thresholds/source resolution/algorithm version with the output. Quiet wrist time is not called sleep, limb movements, PLMI, apnea, posture or cortical arousal.

Do not call the above kRA/kAR. The published pyActigraphy estimator uses run-duration survival/hazard curves, LOWESS smoothing and a weighted plateau estimate [9]. It is not simply `rest→activity transitions / rest epochs`. SFI also has conflicting actigraphy and hypnogram definitions. If later implemented, name and pin the exact definition and activity source; no generic fragmentation score in Phase 1.

### Temperature

Factor a reusable accepted-temperature sample helper from the existing funnel if necessary. Preserve the original funnel's means, inclusivity and callers exactly; the new extractor can apply its own half-open analysis windows. Reuse family/anchor conversion, valid-worn-HR tolerance appropriate to that device, WHOOP 4 raw-band rejection, and the existing 28–42 °C plausibility band. Do not silently apply WHOOP 5 conversion to WHOOP 4 or combine devices/anchors in a trend.

Aggregate accepted readings into UTC-minute bins using medians. A WHOOP 1 Hz minute requires at least 30 distinct accepted sample seconds; for other device families use an explicit cadence policy or withhold the WHOOP-specific summary. No empty-bin interpolation. Calculate:

| Field | Definition / gate |
| --- | --- |
| `night_median_c`, `night_iqr_c` | Median and Q75−Q25 over valid in-fragment minute medians. At least 30 valid minutes and 80% eligible-minute coverage for a primary summary. Use documented linear-interpolation quantiles for IQR. |
| `night_p95_minus_p05_c` | Q95−Q05 of those minute medians; descriptive spread only. |
| `pre_onset_slope_c_per_hour` | Ordinary least-squares slope of minute medians against actual elapsed time during `[first observed onset−60 min, first observed onset)`. Require onset observability, ≥45 of 60 valid minute bins and no missing run >5 min. |
| `post_wake_slope_c_per_hour` | Same regression during `[effective final night end, end+30 min)`, require ≥20 of 30 valid minutes and no missing run >5 min. Label the window as after the estimated window end; do not mislabel it as a measured awakening. |

Return endpoint/span/sample counts and coverage for each slope. Exclude a configurable 5-minute equilibration period after an explicit re-wear/device-reset event; mark this as an engineering rule and report exclusions. If event provenance is unavailable, state that warmup was not verified, rather than inventing a re-wear event. Ambient temperature/bedding are unmeasured confounders. Do not calculate core temperature, DLMO, true thermal sleep onset or a body-clock minimum.

The 2026 Oura study measured finger temperature, anchored to attempted sleep and independently measured N2 onset, and excluded nonwear/equilibration artifacts [14]. That supports investigating trajectories; it does not validate applying an absolute finger-temperature threshold or its semi-automated detector to WHOOP wrist temperature. Phase 1 slopes are observations, not a reproduction or substitute for that detector.

## 7. Phase 1 PRV diagnostics with optional presentation

Implement this group and its tests in Phase 1. Set `prvDiagnosticsEnabled=true` in the v1 extractor config, but calculate values only after the gates below pass; a disabled config produces `disabled`, and failed input produces the specific unavailable reason. No primary dashboard tile is required. Compute Poincaré SD1/SD2 directly in shared Swift. No new runtime dependency is required. Optical pulse intervals must be labeled PRV; do not imply ECG-equivalent HRV or estimate intervals from 1 Hz BPM. Use the existing source-specific beat reliability and coarse-bank timing vetoes. Primary simultaneous PPG/ECG research shows agreement depends on physiological conditions and peripheral effects [30]; it does not validate this WHOOP interval source.

Reuse range/ectopic cleaning and original observation identity from `HRVAnalyzer`. `CleanSeries.contiguous` tracks rejected-beat splices, but wall-clock gaps/source changes must also be excluded. Retain sequence/ordinal evidence when multiple beats share a whole-second timestamp. Unresolved adjacency produces `unresolved_adjacency`; do not sort by RR value, deduplicate equal interval values, concatenate gaps, or interpolate removed beats.

For true adjacent cleaned pairs `(a,b)` in milliseconds, form `u=(b-a)/sqrt(2)` and `v=(a+b)/sqrt(2)`. SD1 is sample standard deviation of u, SD2 sample standard deviation of v (`ddof=1`); the ratio is SD1/SD2, null when SD2 is zero. Implement the direct pair-space definition to avoid unjustified algebraic equivalence with differently centered window statistics [11].

Use UTC-aligned 5-minute windows entirely contained in a single continuous selected-fragment run. A clipped window shorter than 300 seconds is withheld as `insufficient_duration`. New diagnostics require ≥200 valid adjacent pairs, ≥90% supported interval-duration coverage, ≤5% rejected original observations, resolved timing and the existing beat-accuracy gate. Compute coverage from the union of trustworthy original beat-duration spans clipped to the window, not summed RR values that can overcount. Rejection fraction uses original deduplicated observation count before cleaning as denominator. These are explicit engineering gates, deliberately stricter than canonical HRV's 20-beat floor; they must not alter the existing RMSSD path. Report valid pairs, rejection fraction, timing method, source, eligible windows and withheld windows. Summarize a night with the median of eligible window SD1/SD2 values, preserving windows; never concatenate the whole night into one series. The nightly ratio is the ratio of those two summary values, null if summary SD2 is zero, and labeled as such rather than a mean of ratios.

SD1 is closely related to RMSSD and is usually redundant [11]. Keep this group in diagnostics/detail initially, without a new “autonomic balance” score. Do not call SD2 sympathetic tone. Defer SampEn, DFA alpha1/alpha2, multiscale entropy and HR fragmentation until window lengths, missingness/ectopy handling and intended interpretation are specified and evaluated. Do not call `neurokit2.hrv_nonlinear` wholesale to generate a large unreviewed metric set.

## 8. JSON, worker and app integration

### Versioned contract

Define a typed `SleepAnalyticsDocument` with `schema_version=1`, `algorithm_version="nara-sleep-analytics-1"`, `config_version`, `scope="main_night"`, timezone, effective UTC start/end, selected fragment IDs/source/edited bounds, stage-source version, native epoch resolution, and groups `continuity`, `stage_dynamics`, `movement`, `thermal`, `prv_diagnostics`.

Each group has quality/exposure metadata and typed metric values. Metric wrapper: `value`, `unit`, `status`, and optional `reason`. Use statuses `available`, `partial`, `unavailable`, `disabled`; machine-readable reasons include `insufficient_coverage`, `insufficient_duration`, `unsupported_source`, `missing_marker`, `invalid_marker`, `onset_not_observed`, `no_observed_sleep`, `no_observed_rem`, `no_observed_deep`, `insufficient_bouts`, `unresolved_adjacency`, `unreliable_beats`, `zero_denominator`, `source_mismatch`, `stale_edit`, `computation_failed`, and `no_samples`. A status is not a calibrated probability. JSON null is explicit; never emit NaN or Infinity.

Example shape only, not sample measurements:

```json
{
  "schema_version": 1,
  "algorithm_version": "nara-sleep-analytics-1",
  "config_version": "v1",
  "scope": "main_night",
  "timezone": "Etc/UTC",
  "start_at": "2026-10-05T23:00:00Z",
  "end_at": "2026-10-06T07:00:00Z",
  "fragments": [],
  "continuity": {
    "quality": {
      "status": "unavailable",
      "observed_seconds": 0,
      "unknown_seconds": 28800,
      "inferred_gap_awake_seconds": 0
    },
    "observed_waso_seconds": {
      "value": null,
      "unit": "s",
      "status": "unavailable",
      "reason": "no_samples"
    }
  }
}
```

All groups/fields described above belong in the real typed contract; omitted fields in this shortened example do not authorize an incomplete implementation. Refer to outer hosted `inputRevision` and `resultRevision` for freshness. Publication allocates result revision after extraction, so do not invent an inner pre-publication result revision. Include selected-fragment/source edit lineage or a deterministic fingerprint to detect stale documents when effective bounds change.

### Worker steps

1. Adapt `AnalyticsEngine.DayResult.mainNightBlocks` and matched effective source sessions into the new input. If edits have a separate cache/provided-session path, normalize those effective bounds through the existing resolver. Add regression tests before changing shared grouping behavior.
2. Reuse arrays already loaded by `DayScoring`. No per-metric requery and no 14-day history expansion. Ensure existing pre/post read bounds actually cover the defined thermal windows; if not, one bounded batch expansion is allowed and must be measured.
3. Compute once after the effective canonical result is resolved. Prefer exposing the optional new document on `DayResult` so app/local computation and hosted computation call the same pure function. Keep serialization in the worker adapter.
4. Add `daily["sleep_analytics_v1"]` only in `snapshotDaily(...)`. Do not require new legacy columns or write it into `server_daily_scores`.
5. Keep existing job fencing, owner/device scope, canonical payload, pending/stale semantics and failure handling. A failure in the additive extractor withholds its document and emits bounded diagnostics; it must not prevent existing score publication or kill the scoring drain.
6. Follow the existing scoring-version/input invalidation mechanism so an enabled new extractor is actually recomputed for requested days. Document the chosen algorithm version/config fingerprint and bounded development backfill; do not alter global version strings casually or backfill production. Check that new fields do not change the algorithm version reported by legacy compatibility code unintentionally.
7. Log structured counts/reasons, not raw physiological arrays or credentials. Target one O(n log n) normalization plus linear passes, no quadratic all-sample joins, and a ≤64 KiB document without raw waveforms or per-second arrays. A compact native transition matrix and aggregate/window diagnostics are sufficient.

### App steps

1. Extend `HostedDayResult` / `ServerScoreRepository` to parse `daily.sleep_analytics_v1` into the shared model and retain it through the existing owner/device/revision disk cache. Ignore unknown future fields. An absent/unsupported version preserves old-result behavior.
2. Keep the existing hosted result as authority in cloud mode. Do not start a second local stager or calculate a competing nightly value to fill a server gap. Offline/developer local mode may use the same extractor through its normal compute path; show source and freshness consistently.
3. Add a compact “Sleep details” area within the existing Sleep screen/detail cards, using its typography and layout preferences. Primary rows: estimated wake after onset (with gap contribution explained when present), longest observed sleep stretch, complete estimated awakenings, REM latency, movement percentage/bouts and approximate temperature spread. Slopes/transition matrices/stage-bout quantiles/PRV belong in expandable detail rather than creating a wall of numbers.
4. Show null as unavailable with a short human-readable reason and coverage, never 0, “excellent”, a clinical alert, or a misleading full-night count. Partial totals are clearly marked observed/partial. Avoid normative red/green cutoffs. Implement accessibility labels and sensible minute/temperature formatting.
5. After an edit/delete/source switch, immediately withhold a document whose fragment fingerprint no longer matches and request the existing invalidated hosted refresh. Do not let a stale pre-edit analytics card accompany a new edited night. Owner switch/sign-out cannot expose another owner's cached document.
6. Extend an existing Sleep detail/layout section when practical. If a new section enum entry is required, preserve saved order/hidden preferences and default migration behavior. No new top-level tab. Do not broaden this task to Android parity unless the actual delivery target includes Android; preserve compatible hosted JSON for it.

## 9. Pretrained-model and package audit

The desired Phase 1 features do not need a pretrained model. For improving the underlying staging later, use this verified distinction between executable artifacts, advertised weights, papers and mismatched inputs.

| Candidate | What was actually verified | Nara fit / action |
| --- | --- | --- |
| SleepECG `wrn-gru-mesa` | Official package bundles a trained classifier; BSD-3-Clause project [20]. Nara already has `sleepecg.wrn-gru-mesa.v1`, cached hashes and a non-publishable shadow adapter. Its manifest records a prior real inference check, not independent accuracy validation. | Cheapest existing pretrained comparator, already integrated. RR timing must satisfy its gates. It predicts Wake/REM/NREM, not Light/Deep; the extra undefined column is not a fourth physiological class. Keep it shadow-only. |
| wav2sleep | Author GitHub and public HF files verified: MIT code/model card, `state_dict.pth` about 9.67 MB plus `config.yaml` [21,22]. Four-class cardio-respiratory model; modality subsets supported; noncausal/bidirectional. | Best next raw-PPG staging experiment after waveform admission, not a Phase 1 dependency. Needs 1,024 ECG/PPG samples per 30-second epoch, or 34.133… Hz after correct preprocessing. Already listed `blocked_input` in Nara's manifest. |
| SPPPPG-Net | Public HF model card advertises released reproduction weights and a noncommercial research license [23]. The exact weight file/revision/hash was not independently verified in this audit. | Secondary benchmark only. Requires waveform and its record/preprocessing framework. Do not label it a verified ready-to-run checkpoint or treat the license as MIT. |
| ApSense | Official code/tree inspected at `45661e3fa0ddec235716160a429d7f58a7d12387`: training/evaluation/notebooks, no checkpoint file or LICENSE found [13]. | Not a verified drop-in. No training, random-weight placeholder, respiratory event count or AHI in this task. |
| InsightSleepNet | Author repository at `cf328d464fa7fbf70236e6b2b0cb5c62fa60683c` contains a notebook and README; no released weights or LICENSE found [24]. | Research reference, not a ready pretrained integration. |
| CSleep / DCA-Sleep | Primary publications exist [25,26]. No usable author-released checkpoint with reproducible loader/license was verified here. | Papers are not proof of downloadable production weights. Keep deferred; do not invent artifact URLs or assert that no checkpoint could exist elsewhere. |
| `no-eeg-sleep-staging` | Nara manifest pins trained LightGBM files/meta/sample fixture; author repository is public and describes HR plus higher-rate wrist acceleration [27]. | Lower runtime weight than a waveform neural net, but 1 Hz gravity is not the training accelerometer signal. Current input adaptation remains unvalidated; do not silently substitute it. |

Keep model artifact SHA256, code commit, weight repository revision, config hash, preprocessing version and label mapping as separate fields. The wav2sleep code revision is `278e30463c8149c4e6899b8784da492fec695bd9`; it is not automatically the HF weights revision. Existing Nara manifest digests are provenance leads, not newly computed checks in this research task:

```text
SleepECG wrn-gru-mesa.zip:
5622a858c855b0090e1fbcbdc35334ea459707c830eae1a26a4375e33091e869
SleepECG classifier.keras:
0b392209aff8d72383de4d1fdb1e41e85ab060b65a3facb2835e262aa0f6ffd8
wav2sleep state_dict.pth:
ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc
wav2sleep config.yaml:
b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509
```

NeuroKit2 0.2.13 is already pinned in the inference sidecar and is MIT. Use its SD1/SD2 definitions as an independent development oracle, not a reason to route simple Swift statistics through Python. YASA is BSD-3-Clause and useful for hypnogram checks; its EEG sleep stager is not a WHOOP input-compatible model. SleepCycles and pyActigraphy are GPL-3.0; pyPPG has GPL-3.0 text plus an academic-research header that needs a clear rights assessment before any product integration. Do not wholesale vendor these packages into the Swift app. Prefer independently written mathematical implementations, with source attribution, and keep research tools separate until their exact licenses/dependencies fit the intended use.

## 10. Phase 2: bounded raw-PPG research plan, not part of Phase 1 build

Do the smallest input audit before promising waveform features:

1. On authorized real WHOOP exports, identify v20/v26 format, device/firmware, base availability, bursts, capture cadence, within-window sample timing, overlaps and optical settings. Demonstrate absolute reconstruction and continuity; distinguish delta saturation, ADC clipping and missing rows. Validate units and which source is the same physical optical channel. Never mix settings to recover longer coverage.
2. Build a read-only audit/export adapter first. Produce clip manifests with source, rate/timebase evidence, decoder version, calibration/configuration, valid duration and discontinuities. Exclude absent-base windows. Do not increase BLE sampling or launch all-night raw capture until bandwidth, battery, retention and continuity have been checked.
3. Only if genuine continuous nights exist, design a verified immutable optical object lane using the existing IMU pattern, owner scope, hashes, durable cursor/ack and bounded retrieval. Do not upload one relational row per high-rate optical sample. This is a separate feature project with an explicit data contract.
4. Reuse `Tools/InferenceWorker` for offline/shadow waveform experiments. Cache and hash-check weights before startup, forbid runtime downloads, bound memory/time, and isolate missing artifacts/provider failure from canonical scoring. Keep outputs non-publishable and versioned.

### Candidate experiments after those gates

**PWA drops:** derive per-beat peak−nadir amplitude after documented filtering and pulse-quality checks. The Hirotsu method uses a stable preceding five-pulse baseline, a >30% reduction and event-duration/pulse criteria, with artifact exclusions [3]. Reproduce the complete method before claiming comparability. Reject motion/configuration/saturation artifacts; do not merge drops across gaps. Report drop count per valid sleep-waveform hour, depth, duration and normalized area with exposure. Call them PPG amplitude-drop candidates, not EEG arousals; risk direction is not a universal “more is worse” rule.

**Morphology:** start with quality-controlled pulse amplitude, area and interval features, not second-derivative vascular indices on a low-rate/uncertain waveform. Verify pyPPG fiducial performance on this wrist input before interpreting systolic/diastolic durations. No blood-pressure inference.

**wav2sleep:** implement a pinned preprocessing adapter and correct modality mask. Reconstruct absolute samples before filtering/resampling; never feed deltas, BPM, or fake respiratory waveforms. Preserve true gaps and trained normalization; resampling does not add lost bandwidth. Run retrospective whole-night inference with its four-class mapping and raw probability vectors. Compare against PSG on held-out subjects, not agreement with Nara's current stager. Keep calibration unverified until tested.

**CPC:** use true beat intervals plus waveform-derived respiratory modulation independently justified from PPG amplitude/area/baseline, not a scalar respiratory rate or a respiratory series circularly calculated from the same RR tachogram. The published ECG method resamples at 2 Hz and uses 1,024-sample (~8.53-minute) analysis windows, overlapping subwindows and coherent spectral power [7]. Follow its actual spectral/quality rules before borrowing labels. Until PPG/WHOOP transfer is validated, expose research spectral-coupling features, not validated stable/unstable-sleep percentages.

**Cycle segmentation:** if later wanted, freeze a coarse four-class policy based on the published rules: minimum qualifying NREM periods, different first/subsequent REM rules, handling of short REM intrusions, awake interruptions and incomplete terminal cycles [5]. Original SleepCycles can require interactive choices, including splitting very long NREM periods. Light cannot recover N1 versus N2. A simplified deterministic implementation must be labeled its own estimated-cycle policy and tested with omitted-REM/fragmented/short-night fixtures; do not call hypnoR's simplified “aasm” mode an AASM standard [6].

**Probability entropy:** only from real class vectors with a verified mask, class order and calibration disclaimer. Never one-hot labels or heuristic scores. A prediction can be confidently wrong; low entropy is not proof of healthy sleep.

## 11. Phase 3: multi-day activity and oxygen admission gates

For rest-activity rhythms use actual activity/motion, not current hourly-HR `CircadianEngine` bins. First establish a stable activity definition, cadence, wear mask and at least 7 valid days (prefer 14). Avoid repeatedly reading 14 days on every dirty-day job; use bounded daily activity summaries if a later implementation justifies persistence.

For a balanced hourly series x of N=D×24 values, p=24, mean x̄ and hourly profile means m_h: `IS = N*sum_h((m_h-x̄)^2)/(p*sum_i((x_i-x̄)^2))`; `IV = N*sum_i>1((x_i-x_i-1)^2)/((N-1)*sum_i((x_i-x̄)^2))`. M10/L5 are the highest/lowest circular contiguous 10-/5-hour mean windows of the mean 24-hour activity profile; RA=(M10−L5)/(M10+L5) [15–17]. These are rest-activity descriptors, not sleep-stage or intrinsic circadian phase measurements.

The simplest reproducible first policy for that later project uses ≥7 complete 24-hour days with ≥95% observed support in every hourly bin. Exclude DST-transition/travel/timezone-change days from these textbook balanced formulas and explain the reason; do not duplicate an hour, fill nonwear with zero, or compress missing timestamps so IV joins nonadjacent hours. Constant activity yields a zero denominator and null metrics. No new circadian phase card in Phase 1.

ODI3/4, T90 and hypoxic burden require a calibrated, quality-screened time-resolved saturation series; hypoxic burden also needs a specified event definition/reference and sleep denominator [18,29]. The original hypoxic-burden cohort study uses respiratory-event-associated desaturation area and found an association with cardiovascular mortality; this is not justification to substitute an uncalibrated optical byte or infer individual clinical risk. A nightly mean saturation would still be insufficient for event area. Nara currently has neither validated calibration nor event provenance on the default path. Return no oxygen-burden output. Do not approximate SpO2 with raw-channel ratios or use an arbitrary linear curve to unblock it.

## 12. Build and test plan

Tests verify mathematical correctness, data lineage, missingness and integration. They do not establish clinical accuracy.

### Hand-calculated reference fixture

Use a 6-minute, fully supported native 30-second timeline:

```text
[wake, light, light, deep, deep, light, rem, rem, wake, light, light, wake]
```

Expected observed sleep: 270 s; wake: 90 s; first asleep at 30 s; last asleep end at 330 s; observed WASO 30 s; longest observed sleep bout 210 s; onset delay 30 s; REM latency from asleep onset 150 s; deep latency 60 s; one complete internal awakening; two sleep→wake changes including terminal wake; 7 total stage changes among 11 eligible epoch pairs. Expected nonzero epoch counts: W→L=2, L→L=2, L→D=1, D→D=1, D→L=1, L→R=1, R→R=1, R→W=1, L→W=1. The primary per-asleep-hour rate is withheld by the 30-minute exposure floor. None of the four origin rows is absent here; use a separate all-wake fixture to check null probabilities for the three absent rows.

### Required suites and cases

| Layer | Meaningful acceptance tests |
| --- | --- |
| Shared timeline/metrics | Hand fixture; empty input; all wake; no REM; 3-class NREM source; totals-only import; same-label duplicate overlap; conflicting overlap; reversed bounds; source/fragment boundaries; clipped edits; censored bouts; huge gap carrying labels; explicit off-wrist support; prefix gap withholding latency; threshold boundaries; quantile definitions. Shift all UTC timestamps by a constant and verify durations/transition counts remain unchanged. |
| Main-night selection | Nap longer than one fragment; fragmented main night plus nap; canonical inter-fragment inferred-wake contribution reported separately; no fabricated transition across the gap; edited/deleted/imported source and habitual-midnight cases matching existing selection. |
| Motion | Stationary/known moving sequence; exactly-one-second vs missing adjacency; duplicate timestamps; nonfinite axes; unknown/nonwear; source change; no quiet/sleep equivalence; absent raw IMU/classifier still computes from eligible gravity. |
| Thermal | WHOOP 4/5 family conversion and anchor isolation; parity of existing funnel before/after refactor; duplicate minute samples cannot inflate coverage; plausible-range rejection; linear warm/cool trace gives exact slope; constant trace gives zero slope; insufficient pre/post span is null; re-wear exclusion; window boundaries and DST elapsed time. |
| PRV | Independent direct pair-space oracle; constant intervals; a removed ectopic beat must not form a new adjacent pair; equal legitimate RR values retained; retransmitted identity removed once; whole-second ordering unresolved; wall-clock/source gaps; strict window gate boundaries; zero SD2 ratio null; canonical RMSSD unchanged. |
| Worker/backend | New document in v2 only; scores route preserves nested JSON; bounded failure leaves old canonical fields intact; no additional inference call/query per metric; finite JSON; schema/version behavior; owner/device fences and input-revision lease rejection continue to work. |
| App/cache/UI | New and old snapshots parse; offline/relaunch preserves eligible document; unknown future fields ignored; owner switch isolation; stale pending results; edited night never shows old matching-looking data; partial/unavailable/zero-event states render differently; saved Sleep layout preferences preserved. |
| Regression/performance | Existing canonical sleep/HRV/Rest values unchanged on fixed inputs; full-night realistic fixture including gaps; document size ≤64 KiB; runtime/memory benchmark recorded against baseline, without repeated DB reads or SwiftUI-body analytics. |

For an independent formula oracle, compare complete regular four-class fixtures against pinned YASA `Hypnogram.sleep_statistics()`/`transition_matrix()` and compare SD1/SD2 against a small direct NumPy pair calculation (optionally the pinned NeuroKit definitions). Document the REM-latency origin difference. Do not import YASA assumptions about a gap-free uniform hypnogram into Nara's gapped input.

Run package tests and worker tests with the repository's actual platform prerequisites. On Linux the worker needs snapshot-enabled SQLite and its native libraries as described in `deploy/README.md`, not the distro's incompatible SQLite build. Typical worker checks from `Tools/CloudWorker`:

```bash
swift test -Xcc -I/opt/sqlite -Xlinker -L/opt/sqlite
LD_LIBRARY_PATH=/opt/sqlite swift build -c release -Xcc -I/opt/sqlite -Xlinker -L/opt/sqlite
```

On macOS generate the Xcode project after adding/removing sources, then run the main suite from `docs/IOS.md`:

```bash
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' -derivedDataPath /tmp/nara-dd-mac -only-testing:StrandTests
```

Use the existing unsigned/simulator build path for UI compilation if signing credentials are unavailable. Do not put service-role keys or other secrets in the app. Record baseline failures before editing; `docs/IOS.md` names existing caption/timezone and wording failures. Do not suppress new regressions as “known failures”. Local Supabase integration tests follow `supabase/tests/e2e/README.md`; do not exercise production just to complete tests.

The public PhysioNet sleep-accel dataset already used by `Tools/SleepPSG` contains 31 participants, Apple Watch motion/HR and PSG labels [28]. It can support stage-estimator benchmarking, but has no raw PPG for waveform model validation and no matching WHOOP thermal signal. Synthetic traces validate arithmetic, not a new sensor/model. Any future accuracy claim requires an independent held-out subject cohort, wake sensitivity, per-class performance, kappa, duration/latency errors and explicit device/domain limitations. Do not tune and report accuracy on the same subjects or treat WHOOP vendor stages as PSG truth.

## 13. Completion and release criteria

The implementation is complete when all Phase 1 groups are supported end to end with typed contracts, actual missingness, regression protection, hosted/offline readback, coherent UI and documented test results. A source that fails admission must produce a reason rather than blocking eligible other groups. Do not claim a deferred feature was implemented merely because its JSON key exists.

Update `docs/CURRENT_ALGORITHMS.md` with definitions, units, denominators, gates, versions and interpretation limits. Keep `spec.md` in the repository as the implementation authority and record any justified deviations. Retain required license/notice files; preserve internal NOOP/Strand IDs, preferences and data directories. Never commit generated Xcode project files, real user exports or credentials.

Deliver: feature-branch commits; changed-files summary; test commands/results and baseline failures; sample redacted new/old/partial JSON; UI states; runtime/document-size evidence; list of sources that remain withheld; and a worker/app rollout plan. A scoring package change requires rebuilding both app and worker. Deploy the worker before enabling the app's new reader, with existing old-snapshot compatibility, bounded reprocessing and a rollback to the prior worker/app behavior. Prepare this plan and artifacts, but do not deploy or mutate production as part of the build/test task.

## 14. Primary sources and verification links

All sources below were checked during this audit; some publisher/PMC full-text endpoints were access-limited, so paper-level details are distinguished from executed/released artifacts above. Exact Nara paths refer to the inspected commit. Public code can change after the research date; pin the selected version before using it.

1. YASA, hypnogram sleep statistics and REM-latency convention: https://yasa-sleep.org/generated/yasa.Hypnogram.sleep_statistics.html
2. YASA, transition matrices and general hypnogram support: https://yasa-sleep.org/generated/yasa.Hypnogram.transition_matrix.html and https://yasa-sleep.org/generated/yasa.Hypnogram.html
3. Hirotsu et al., 2020, PWA drops in a general population: https://doi.org/10.1093/sleep/zsz322 and https://pmc.ncbi.nlm.nih.gov/articles/PMC7355400/
4. Delessert et al., 2010, PWA and cortical activity: https://pmc.ncbi.nlm.nih.gov/articles/PMC2982739/
5. Blume & Cajochen, 2021, SleepCycles, MethodsX 8:101318: https://doi.org/10.1016/j.mex.2021.101318 ; full method https://www.chronobiology.ch/wp-content/uploads/2021/09/main.pdf ; code https://github.com/ChristineBlume/SleepCycles
6. hypnoR cycle policy documentation: https://hypnor.circadia-lab.uk/reference/compute_cycles
7. Ibrahim et al., 2010, CPC method: https://pmc.ncbi.nlm.nih.gov/articles/PMC2864879/
8. CPC chapter covering ECG/PPG, 2022: https://pubmed.ncbi.nlm.nih.gov/36217085/
9. pyActigraphy kRA estimator and linked Lim et al. method: https://ghammad.github.io/pyActigraphy/_autosummary/pyActigraphy.metrics.MetricsMixin.kRA.html ; https://doi.org/10.5665/sleep.1400 ; code https://github.com/ghammad/pyActigraphy
10. GGIR cut-point and circadian workflows: https://wadpac.github.io/GGIR/articles/chapter11_DescribingDataCutPoints.html and https://wadpac.github.io/GGIR/
11. NeuroKit nonlinear HRV definitions/source: https://neuropsychology.github.io/NeuroKit/_modules/neurokit2/hrv/hrv_nonlinear.html
12. pyPPG publication and code/license: https://doi.org/10.1088/1361-6579/ad33a2 and https://github.com/mike-live/pyPPG
13. ApSense author code, input features and training workflow: https://github.com/IoBT-VISTEC/ApSense
14. Jouvencel et al., 2026, finger-temperature trajectories: https://doi.org/10.1016/j.sleep.2026.109074 ; publisher https://www.sciencedirect.com/science/article/pii/S1389945726003138 ; PubMed https://pubmed.ncbi.nlm.nih.gov/42330816/
15. pyActigraphy IS: https://ghammad.github.io/pyActigraphy/_autosummary/pyActigraphy.metrics.MetricsMixin.IS.html
16. pyActigraphy IV: https://ghammad.github.io/pyActigraphy/_autosummary/pyActigraphy.metrics.MetricsMixin.IV.html
17. pyActigraphy rest-activity metrics implementation, including M10/L5/RA: https://github.com/ghammad/pyActigraphy/blob/master/pyActigraphy/metrics/metrics.py
18. Event-based hypoxic burden author implementation: https://github.com/JindrichA/HB_event_based
19. Environmental noise study clarifying human PWA-drop comparison: https://doi.org/10.1093/sleep/zsab302 and https://academic.oup.com/sleep/article/45/3/zsab302/6489046
20. SleepECG official bundled models/class order and license: https://sleepecg.readthedocs.io/en/stable/classification/ and https://github.com/cbrnr/sleepecg
21. wav2sleep author code/paper: https://github.com/joncarter1/wav2sleep and https://arxiv.org/abs/2411.04644
22. wav2sleep released checkpoint/model card/files: https://huggingface.co/joncarter/wav2sleep and https://huggingface.co/joncarter/wav2sleep/tree/main
23. SPPPPG-Net public reproduction model card: https://huggingface.co/sleep-is-all-you-need/SPPPPG-Net
24. InsightSleepNet author code and publication: https://github.com/BorumNam/InsightSleepNet and https://pmc.ncbi.nlm.nih.gov/articles/PMC10865603/
25. CSleep, primary publication record: https://pubmed.ncbi.nlm.nih.gov/40030746/
26. DCA-Sleep, Diagnostics 2026;16(5):802: https://doi.org/10.3390/diagnostics16050802
27. HR/accelerometer LightGBM comparator: https://github.com/akaneriya1/no-eeg-sleep-staging
28. PhysioNet sleep-accel 1.0.0, signal inventory and validation domain: https://physionet.org/content/sleep-accel/1.0.0/
29. Azarbarzin et al., 2019, event-associated hypoxic burden and cohort outcomes: https://doi.org/10.1093/eurheartj/ehy624 and https://pmc.ncbi.nlm.nih.gov/articles/PMC6451769/
30. Chen et al., 2015, simultaneous PPG/ECG variability comparison under different autonomic conditions: https://doi.org/10.3892/etm.2015.2784 and https://www.spandidos-publications.com/10.3892/etm.2015.2784
