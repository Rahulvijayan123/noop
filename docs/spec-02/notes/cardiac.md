# Spec 02 — cardiac / PRV owner notes

Branch `spec02/cardiac-prv-20261007` (worktree `nara-spec02-cardiac`), from foundation `fedeceb49`.
Scope delivered here: spec §1 HF power correctness repair, pNN50 (CONTRACT §4.1), stage-associated movement
(CONTRACT §4.4), sample entropy + DFA α1 (CONTRACT §5.3). Pulse episodes / day-night HR (`PCPulseEpisodes.swift`,
`PCSleepRhythm.swift`) were not in this agent's assignment (another agent, `pccard`, holds them).

## 1. HF / LF power repair — `HRVFreqDomain.swift` (method `lomb_scargle_psd_ms2_v2`)

**Defect (confirmed at `fedeceb49`).** v1 rebuilt time as the cumulative sum of the *cleaned* intervals (every
removed beat and every recording gap was spliced out of the time axis) and divided the Lomb–Scargle periodogram by
`2·variance` (dimensionless) while labelling band integrals ms². Its tests only checked relative band dominance.

**Definition now.**
1. *Interval-END timing.* Sample `rr_k` sits at the time its interval ends. Inside a contiguous run
   `t_k = Σ_{j≤k} rr_j` over **all raw** intervals (a cleaning-removed beat keeps its elapsed time; its sample is
   missing, nothing shifts).
2. *Discontinuities split, never bridge.* Stored timestamps are whole seconds on the record carrying the interval:
   `ts_k = floor(t_k + θ)` for one unknown offset θ per run. A run continues while some θ satisfies every beat
   (`ts_k − 0.25 ≤ θ + T_k < ts_k + 1 + 0.25`); a missing beat, wall-clock gap, re-stamped duplicate delivery, or a
   source-channel change makes it infeasible → new run. Beats consistent with both the old and the new timing at a
   break are excluded from both (`ambiguousBeats`). Exact retransmissions are removed first by observation identity
   (`SleepAnalyticsPrv.dedupByObservationIdentity`). Cleaning = canonical `HRVAnalyzer.cleanRRGapAware`
   (unchanged); a removed stretch > 3 s between retained samples splits the run, shorter ones stay missing samples
   (Clifford & Tarassenko 2005: Lomb–Scargle with removed — not interpolated — beats).
   Checked on a real WHOOP 5 night (owner, 2026-10-07 04:00–07:00 PT, history channel 5, read-only DB): the END
   convention fits (START breaks 2–3× more runs); slack 0.25 s keeps ~90 % of beats in runs ≥ 60 beats.
3. *Absolute PSD.* `P(f) = ½[(Σy cos ω(t−τ))²/Σcos² + (Σy sin ω(t−τ))²/Σsin²]` (Lomb 1976; Scargle 1982 eq. 10;
   = `scipy.signal.lombscargle(normalize=False)` on mean-removed data), one-sided density
   `S(f) = 2·Δt̄·P(f)` ms²/Hz with `Δt̄ = (t_N − t_1)/(N−1)` (Parseval scaling of the classical periodogram, which
   P equals for even sampling — Scargle 1982 §II). Band power = trapezoid ∫S df in ms²; a sinusoid of amplitude A
   integrates to A²/2. Grid step ≤ min(0.005 Hz, 1/(5·span)); evaluated with the Press–Rybicki recurrence
   (re-seeded every 64 steps).
4. *Windows.* 300 s tiles (Task Force short-term length) of each split segment. Gates per window: ≥ 20 retained
   samples, span ≥ 60 s (HF) / ≥ 250 s (full: LF, LF/HF, total), cleaning-rejected fraction ≤ 20 %. Band edges
   unchanged (VLF 0.0033–0.04 total only, LF 0.04–0.15, HF 0.15–0.40 Hz).
5. *Combination.* With ≥ 1 full window: span-weighted mean over FULL windows only (spans 250–300 s — the
   Bartlett/Welch principle of averaging equal-length spectra; reduces variance, never mixes resolutions); LF/HF =
   ratio of the averaged powers (not a mean of ratios). Without a full window: HF only, from the single longest
   60–250 s window (short windows differ in resolution and are not averaged).

**API.** `HRVFreqDomain.analyze(rr:) -> Outcome {bands?, unavailableReason?, diagnostics}`;
`freqDomain(rr:)` = `analyze(rr:).bands`. `Bands` now carries `tier`, `windowCount`, `usedSpanSec`, `usedBeats`,
`observedSpanSec`, `coverageFraction`, `rejectedFraction`, `method`, `unit` (`ms²`), `source` (`prv_optical`).
The untimestamped `freqDomain(rawRR:)` was REMOVED; its honest replacement `analyze(assumingContiguousRR:)` is
documented as reference-only (gapless ECG NN fixtures), and nothing in the app calls it.

**Consumer.** `Strand/Screens/StressView.swift` (frequency-domain section only): `freqHRV` is the `Outcome`; tiles
"HF power" (`N ms²`, caption `0.15–0.40 Hz · optical PRV`) and "LF/HF ratio" (only with a full window, caption
`Optical PRV · descriptive`); a coverage footnote (`N uninterrupted five-minute stretches: X of Y min of today's
R-R … not a measure of nervous-system balance`), an HF-only footnote, or the withheld reason. The old
"Autonomic balance (LF/HF) … higher leans sympathetic" and "Parasympathetic (rest) band" wording is gone (causal /
autonomic claims). New strings use `String(localized:)` with new keys — **the UI agent must add them to
`Localizable.xcstrings`**. Not persisted anywhere (CONTRACT §2: in-app only).

**Android twin (not built here — no Android toolchain in this environment).** `HrvFreqDomain.kt` mirrors the Swift
algorithm (`analyze`, `analyzeAssumingContiguous`, same constants/tiers/reasons), `StressScreen.kt` mirrors the
tiles/footnote (literal strings, as the existing captions there), `HrvFreqDomainTest.kt` mirrors the Swift
fixtures and reference values, `HrvFreqAgreementTest.kt` (local-only fixture) now calls
`analyzeAssumingContiguous`. One additive parity edit outside the listed files: `HrvAnalyzer.kt`
`CleanSeries.keptOriginalIndices` (defaulted; the Swift twin already had it). Needs `./gradlew testDebugUnitTest`.

**Reference values (independent: scipy 1.18.1 / numpy 2.5.3 in the sidecar venv, `scipy.signal.lombscargle`
normalize=False, same grid, S = 2·Δt̄·P).** Fixture: `rr = floor(base + A·sin(2π f0 t) + 0.5)` ms with t the
previous END time, stamped `T0 + floor(t)`, 299 s.

| Fixture | HF ms² | LF ms² | VLF ms² | closed form |
| --- | --- | --- | --- | --- |
| A=30, f0=0.25 | 448.612207270 | 0.380885395 | 0.078985421 | HF 450 |
| A=60, f0=0.25 | 1785.227739745 | 1.614300138 | 0.324295382 | HF 1800 |
| A=30, f0=0.10 | 1.131841221 | 448.182016470 | 1.060352268 | LF 450 |
| fixed timestamps, y=30 sin, mean-removed | 448.1293897089 (×2 amplitude → ratio 4.000000000000) | | | |
| white noise (LCG seed 12345, 1 s even), ∫0.0033–0.499 / var | 0.9948579251 | | | 1 |

The Python mirror (scratch only, not committed) also showed: 7 removed split beats — narrow-band (0.24–0.26 Hz)
power with true timing 447 vs clean 434 (+3 %), spliced (v1) timing 382 (−12 %); a 900→1100 ms level shift across
a bridged gap → LF 194 ms² spurious. Real WHOOP 5 night above (3 h): 112 timing runs, 60 cleaning splits,
8 full windows (2 274 s of 10 800 s), HF ≈ LF ≈ 2 000 ms².

## 2. pNN50 — `SleepAnalyticsPrv.swift` (CONTRACT §4.1)

`HRVAnalyzer.pnn50GapAware` is called per eligible window on the contiguous cleaned slice holding that window's
pairs, with the mask `isTruePair[i]` = cleaner-contiguous AND an original ts/seq/ord/source adjacency (the exact
SD1/SD2 pair set; asserted `pnn50_pair_count == valid_pairs`). Fills `nightly_pnn50_pct` (pooled
100·ΣNN50/Σpairs, unit `%`), `pnn50_pair_count`, `nn50_count`, `pnn50_method`
(`pnn50GapAware_original_adjacency_v1`), per window `pnn50_pct`, `nn50_count`. No eligible window → all three
unavailable with SD1's reason; config-disabled → disabled. SD1/SD2 code paths unchanged.
`SleepAnalyticsConfig.prvPnn50ThresholdMs` is still not read (the canonical function fixes 50 ms), so it stays
OUT of the fingerprint (brief rule 6). **Version:** not bumped here (my tests don't need it); the lead bumps
`nara-sleep-analytics-1`→`-2` / `v1`→`v2` at integration so stored documents recompute and gain these keys.

## 3. Stage-associated movement — `SleepAnalyticsMovement.swift` (CONTRACT §4.4)

Each classified adjacency (t−1, t) is joined to the normalized timeline label at second t through
`SleepAnalyticsMovementStageJoin` (forward pointer over sorted intervals). A second in a label-supported interval
takes its label; unsupported / `unknown` / uncovered seconds are `unknown` (never forward-filled). A movement bout
is attributed to the label at its FIRST moving second. Per label (wake, light, deep, rem, unknown):
`eligible_seconds`, `movement_seconds`, `movement_percentage` (%), `movement_bout_starts`,
`movement_bouts_per_eligible_hour` (per_h; available with ≥ `primaryRateMinObservedSeconds` = 1800 eligible s,
else partial). No classified adjacency at all → every metric `no_samples`; a label with zero eligible seconds →
`eligible_seconds` 0 (real exposure), ratios `zero_denominator`. `stage_movement_note` =
`stages_may_depend_on_motion`. Per-label sums equal the group totals (tested). Existing movement metrics unchanged.

## 4. Sample entropy + DFA α1 — `features/prv_nonlinear.py` (CONTRACT §5.3)

`method_version` `prv-nonlinear-1`, `source` `prv_optical`, `secondary` true, `neurokit2` version, frozen
`PrvNonlinearConfig` reported as `config`: `segment_beats` 300, `sampen_dimension` 2, `sampen_delay` 1,
`sampen_tolerance_sd` 0.2 (r = 0.2·SD(segment, ddof=1)), `dfa_scales` [4, 16] (every integer box 4…16 — the Peng
1995 α1; NeuroKit's `hrv_nonlinear` default is 4–11 with overlap, so this is NOT its DFA_alpha1), `dfa_overlap`
false, `dfa_order` 1, `min_segments` 3, `max_segments` 24, `time_budget_s` 0.4, `splice_tolerance_s` 3.0.
Adjacency reuses the stage-physiology rules: `providers.hrv.continuous_runs` (3 s) + split at a source-channel
change + `clean_rr_gap_aware` per run; stretches of true-adjacent cleaned intervals; non-overlapping segments of
exactly 300 from each stretch start (remainder discarded); main night only. Per segment
`nk.entropy_sample` / `nk.fractal_dfa`; a segment with either statistic undefined is rejected for both. Summary:
median + IQR (`segments` count). Up to 24 segments, evenly spaced over the night (deterministic). Output also
carries `segments_available`, `segments_evaluated` (`used + rejected == evaluated`).

Validation (tests): NeuroKit values equal independent textbook implementations (Richman & Moorman SampEn, Peng
non-overlapping DFA-1) to 1e-12 / 1e-10 on 3 random series; synthetic medians over 20 series: white α1 ≈ 0.575
(DFA-1 small-box bias; band 0.45–0.65), 1/f ≈ 1.00, Brownian ≈ 1.49; SampEn white ≈ 2.19, 1/f ≈ 1.84,
periodic ≈ 0.16.

Latency (min-of-N CPU cost; the host's load average was 400–1000 during measurement, medians are 5–20× worse):
SampEn 0.33 ms + DFA 1.7 ms per segment; segmentation of the committed full-night fixture (26 400 beats) 113 ms.
Profiled under load, NeuroKit's DFA (Python polyval loops) dominates. Hence the 24-segment cap, skipping runs
shorter than one segment (no result change), and a 0.4 s wall-clock guard that WITHHOLDS the block
(`compute_budget_exceeded`) rather than risk the route's 3 s budget for every other block (it never changes a
published value, only whether one is published; on a loaded host the block may therefore flap to withheld).
Wired in `compute.py` as one more isolated per-night module (`_isolated`: a raise → `module_error`, rest survives).

Swift decoder (`SleepFeatureDocument.swift`, additive): `SleepPrvNonlinear.segmentsAvailable/segmentsEvaluated`,
`SleepPrvNonlinearConfig.dfaOverlap/maxSegments`. A Swift test decodes the literal Python output.

## Reason codes added (for UI / wording)

| Where | Code | Meaning |
| --- | --- | --- |
| `HRVFreqDomain.UnavailableReason` (in-app) | `no_rr_intervals` | no R-R today |
| | `no_contiguous_window` | no ≥ 60 s stretch with ≥ 20 retained beats and consistent timing |
| | `rejected_fraction_too_high` | stretches exist but > 20 % of beats rejected in each |
| `HRVFreqDomain.Tier` (in-app) | `full_windows`, `short_window_hf_only` | which windows the powers come from |
| `prv_nonlinear.reasons` | `not_main_night` (status `not_applicable`) | naps |
| | `no_rr_beats` | no beats in the night |
| | `insufficient_segments` | fewer than 3 usable 300-interval segments |
| | `compute_budget_exceeded` | wall-clock guard tripped; block withheld |
| `stage_movement_note` | `stages_may_depend_on_motion` | disclosure |

pNN50 and stage movement use existing `SleepAnalyticsReason` values only.

## Root-owned / shared files touched

- `SleepFeatureDocument.swift`: the four additive optional decoder fields above.
- `features/compute.py`: import + one `("prv_nonlinear", prv_nonlinear.compute_night)` entry.
- `android/.../HrvAnalyzer.kt`: additive `CleanSeries.keptOriginalIndices` (defaulted) for the Kotlin twin.
- `SleepAnalyticsV1.swift`, `features/contract.py`: NOT edited (foundation types and the request already suffice:
  the request carries every beat in the night span with seq/ord/src_channel).

## Path to storage

- `sleep_analytics_v1` (pNN50, stage movement): `DayScoring` → `SleepAnalyticsAttach.sleepAnalyticsPayload`
  encodes the whole `SleepAnalyticsDocument` with `JSONEncoder` (all CodingKeys, so the new optional keys are
  emitted) → `snapshotDaily["sleep_analytics_v1"]` → `publish_scoring_snapshot_v2` stores the free-form jsonb
  payload (`p_payload || {...}`; no key filtering, no size cap on snapshots) → `readHostedSnapshot` returns
  `payload.daily` verbatim (`sleep_analytics_route_test.ts` pins deep equality) → `ServerScoreRepository` decodes
  `daily.sleep_analytics_v1` into the shared Swift type (optional fields decode).
- `sleep_features` (prv_nonlinear): sidecar `compute()` → `SleepFeatureEnrichment.validateResponse` (structural
  checks only; the object is attached verbatim) → `daily["sleep_features"]` → same jsonb passthrough → app decodes
  `SleepFeatureDocument` (tolerant).
- HF/LF: computed on device, never persisted.

## Tests run

| Suite | Result | Log |
| --- | --- | --- |
| Swift `sa-test --filter 'HRVFreq\|SleepAnalytics\|HRVAnalyzer\|SleepFeature\|SleepPrvNonlinear'` | 167 run, 0 failures, 0 skipped, exit 0 | `_build-scratch/spec02/logs/cardiac-sa-test-134959.log` |
| (earlier run, filter without SleepFeature) | 164 run, 2 failures — my stage-movement fixture had a non-epoch-aligned REM end (4100 s); fixed to 4110 s, class rerun 4/4 + decode 2/2 pass | `cardiac-sa-test-132322.log`, `cardiac-sa-test-133814.log` |
| Python `tests/test_features_prv_nonlinear.py` | 14 passed | — |
| Python contract + features_* + integration + server + prv_nonlinear (golden wall-clock test deselected) | 232 passed, 1 failed (`test_committed_fixture_pair_round_trips_over_real_http`: only extra night key `prv_nonlinear`, expected until the lead regenerates the golden pair), 1 deselected | — |
| Android (`HrvFreqDomainTest`, `StressScreen.kt`) | NOT RUN — no Android toolchain in this environment | — |
| macOS app build `sbuild.sh … mac` (compiles the changed StressView) | BUILD SUCCEEDED, exit 0, no errors | `cardiac-mac-135011.log` |

## Integration notes for the lead

- `tests/test_features_integration.py::test_committed_fixture_pair_round_trips_over_real_http` FAILS on this
  branch only because the night key set gains `prv_nonlinear` (verified: the sole diff). Regenerate the committed
  pair (`SleepFeatureWireFixtures/*`) after merging; the deselected golden test changes for the same reason.
- Bump `nara-sleep-analytics-1`→`-2` / `v1`→`v2` with the thermal change (pNN50 and stage movement are new keys
  only; existing values unchanged).
- Add the new StressView strings to `Localizable.xcstrings`; map the prv_nonlinear reasons in the sleep-features UI.
- `docs/CURRENT_ALGORITHMS.md:84` mentions `HRVFreqDomain`; update to "absolute ms², Stress screen only".
- Android: run `HrvFreqDomainTest` and `StressScreen` compile; not runnable here.
