# Spec 02 — what has been built so far

Date: 2026-10-08
Branch: `feat/spec02-feature-reuse-20261007` (worktree `nara-spec02-features`), cut from `nara/main` `dab2124f3`.
Source spec: `/Volumes/Untitled/Downloads/spec-02-feature-reuse.md`.

**Status: work in progress.** This commit is the shared contract and the foundation. It computes no new metric, and no existing output changes.

## 1. Short version

- Wrote the shared contract, [CONTRACT.md](CONTRACT.md): what each output is, who owns it, its wire shape, its reason codes, and how the four owner workstreams split the files.
- Added typed Swift and Python parsing for the new fields the spec needs, so producers and the app build against the same shapes. Every new field is optional and absent until its owner computes it.
- Stubbed the computations that do not exist yet. The pulse-episode detector and the morning-response group return nothing.
- Checked the spec's claims against the code. The spec is right on every point I checked (section 4), and I found one new problem: the sleep-details section can hide itself.
- I have not spawned the sub-agents the spec asks for. The ownership split is written down, so they can start from it.

## 2. Verification

| Check | Result |
| --- | --- |
| `swift build --build-tests` in `Packages/StrandAnalytics` (library and tests) | Passed, exit 0 (228.9 s) |
| `swift test --filter 'PC\|SleepAnalytics\|SleepFeature\|HRVAnalyzer\|HRVFreq\|Exertion\|Physiology\|Circadian\|Stress'` | 504 run, 4 skipped, 0 failures |
| `uv run pytest` on `test_contract.py`, `test_features_*.py`, `test_server.py` | 219 passed, 1 deselected, exit 0 |
| Deselected: `test_full_night_fixture_reproduces_the_committed_response_within_budget` | Fails on wall-clock time only (1.92 s against a 0.75 s limit, with the Mac's load average above 100). The golden-content assertion before it passes. This is environmental and was already happening before my edits. |
| Full StrandAnalytics suite at base `dab2124f3`, before any edit | 3494 run, 7 skipped, 0 failures, with `LongitudinalBaselineTests` skipped. That suite's fixture CSVs are caught by the `Fixtures/` rule in `.gitignore`. |
| Not run | CloudWorker `swift test`, the app's `StrandTests`, and anything deployed. Both the worker and the app consume the changed package. The changes are additive, but neither build has been checked. |

## 3. What changed, by file

| File | Change |
| --- | --- |
| `docs/spec-02/CONTRACT.md` (new) | The contract: outputs and owners, common rules, the `sleep_analytics_v1` additions, the `sleep_features` blocks, physiology-context additions, file ownership, and the integration protocol. |
| `docs/spec-02/PROGRESS.md` (new) | This file. |
| `Packages/StrandAnalytics/.../SleepAnalyticsV1.swift` | Optional pNN50 fields on the PRV group (`nightly_pnn50_pct`, `pnn50_pair_count`, `nn50_count`, `pnn50_method`) and per window (`pnn50_pct`, `nn50_count`). Optional `stage_movement` and its note on the movement group, with its type. A new `morning_response` group with its curve-point, signal-window and group types. New config fields for the morning windows and the pNN50 threshold. Versions unchanged (section 5). |
| `.../SleepAnalyticsMorning.swift` (new) | Returns nil. The owner replaces the body. |
| `.../SleepAnalyticsComputation.swift` | Passes the morning group (nil) into the document. |
| `.../SleepFeatureDocument.swift` | Tolerant decoders for `rebound`, `rest_activity_rhythm`, `prv_nonlinear` (with its config), and the new `observed_skin_temp_rhythm` fields: method, coverage, uncertainty, phase status, phase relations, phase drift and realignment. Also the respiratory `supported_range`, `interval_distribution` and `stable_modulation`, and per-stage SD, RMSSD, median and IQR. Nothing renders these yet. |
| `.../PhysiologyContext/PCContract.swift` | `PolicyVersions.pulse`, `PolicyVersions.respiratoryRecovery`, `Policy.pulse`, and `DayDocument.pulseEpisodes`. All optional or defaulted. |
| `.../PhysiologyContext/PCPulseEpisodes.swift` (new) | Types for pulse episodes and heart-rate accelerations, thresholds with hysteresis, and the reason codes. The detector returns nil. |
| `.../PhysiologyContext/PCSleepRhythm.swift` | `DayNightHeartRate` (both medians, coverage, and the percent-dip definition) and `SleepRhythmSummary.dayNightHeartRate`, which is nil for now. |
| `.../PhysiologyContext/PCExertionBouts.swift` | `RespiratoryRecovery` types, `ExertionConfig.respiratoryRecoveryVersion`, and `BoutRecovery.respiratoryRecovery` (nil for now). `ExertionBouts.detect` takes the day's respiratory-rate measurements, but nothing reads them yet. |
| `.../PhysiologyContext/PCEngine.swift` | Passes respiratory-rate measurements to bout detection, filtered by the same causal rule the envelopes use. Calls the pulse stub. |
| `Tools/InferenceWorker/src/frwhoop_inference/features/contract.py` | Accepts `history.days[].nights` (main night, naps and edits, at most 8 per day), `history.days[].timezone`, and `rhythm_history` (schema `rhythm-history-1`, hourly bins, with bounds checked). These are parsed only. `compute.py` does not use them yet. |

## 4. Spec claims checked against the code

Confirmed:

- `HRVFreqDomain` rebuilds time from cumulative sums of cleaned intervals, so the observed timestamps and the gaps are lost. Its Lomb–Scargle power is divided by the variance, so it is not in ms². The stress screen shows the HF band as a bare number (`Strand/Screens/StressView.swift:494`).
- `SleepAnalyticsThermal.swift` builds its minute bins from in-fragment minutes only, so the post-wake slope window `[end, end + 30 min)` never has data. The nightly summary itself is correct.
- The Python thermal rhythm is withheld with `multi_day_history_not_requested` (`features/thermal.py`). The IV in `intradaily_variance` counts only pairs inside one day, so it drops the 23→0 pairs at midnight.
- `CircadianEngine` gets per-hour mean heart rate (`Strand/App/AppModel.swift:2983–2989`). It converts the heart-rate acrophase into a "temperature minimum" with a fixed 12-hour offset (`acrophaseAfterCbtMinHours`). That is a heart-rate heuristic, not a temperature measurement.
- `PCReferences.stableAwakeMetrics` is `[hrvRmssd, hrvSdnn, heartRate]`, with no respiratory rate.
- `SleepStager.respPlausibleRangeBpm` is 8–25, and the breath detector's band is 6–24 breaths per minute. Tachypnea and bradypnea claims are therefore out of range.
- The awake-vs-sleep contrast (`PCSleepRhythm.dayNightContrast`) returns only the difference, with no medians and no coverage.

New finding, not in the spec:

- `SleepFeatureSection.load()` (`Strand/Screens/SleepFeatureCards.swift`) returns nothing whenever `daily.sleep_analytics_v1` exists. The worker now attaches the analytics document on every day with sessions, so the regularity, physiology, settling and breathing cards are hidden on those nights. The readback work has to fix this section-level guard, not only the cards.

## 5. Decisions made

- **Versions are unchanged** (`nara-sleep-analytics-1`, config `v1`). I bumped them to `-2` and `v2`, then reverted. Nothing computes differently yet, and existing tests pin `-1` and `v1`. The bump lands with the first change that alters a meaning, which is the thermal post-wake slope.
- **Spec-02 config fields stay out of the gate fingerprint** until the groups that read them compute. Identical inputs keep identical fingerprints.
- **Ownership** is split in CONTRACT section 7 into cardiac/PRV, respiratory/context, temperature/circadian, and readback/UI. Each owner works on its own branch and file set, and the lead integrates.

## 6. Decisions needed from you

1. **Policy fingerprint.** `Policy.fingerprint` now includes `pulse` and `respiratoryRecoveryVersion`. Once this is deployed, every stored physiology-context document gets a new policy key and is recomputed once. Nothing is deployed. Should the pulse config stay in `Policy` now, or move in with the detector?
2. **Sub-agents.** Should I spawn the four owner workstreams now, from CONTRACT section 7?

## 7. Not done yet

| Spec section | Item | Status |
| --- | --- | --- |
| 1 | pNN50 computed on the same adjacency mask as SD1/SD2 | Types only |
| 1 | HF power repair: observed timestamps, absolute PSD, ms² | Not started |
| 1 | Sample entropy and DFA α1 | Swift decoder only; Python producer not started |
| 1 | Awake-vs-sleep medians, coverage and percent dip | Type only |
| 1 | Sustained pulse episodes and HR acceleration with movement | Stub |
| 2 | Interval distribution, stable modulation, per-stage fields | Decoders only |
| 2 | Nightly RR against 7- and 28-day baselines; post-exertion RR return; awake RR reference | Respiratory recovery type only |
| 3 | Thermal bins built once; post-wake slope; 30-minute morning response | Not started |
| 3 | Multi-day thermal history adapter, cosinor, phase relations and drift | Request validation only |
| 3 | `CircadianEngine` relabeling and its wording | Not started |
| 4 | Morning heart-rate, temperature and movement curves | Stub |
| 4 | Stage-associated movement | Type only |
| 4 | Next-night rebound | Decoder only |
| 4 | IS, IV, L5, M10 and RA | Decoder only; the cross-midnight IV rule is not changed yet |
| 4 | 24hAlign (optional in the spec) | Not started |
| — | Readback fix for the hidden sleep-details section (section 4) | Not started |
| — | Regenerating the golden fixtures | After the owners land their changes |

## 8. How to check this commit

Python, from `Tools/InferenceWorker`:

```bash
uv run --frozen pytest -o addopts="" -q tests/test_contract.py tests/test_features_continuity.py tests/test_features_physiology.py tests/test_features_regularity.py tests/test_features_settling.py tests/test_features_integration.py tests/test_server.py --deselect tests/test_features_integration.py::test_full_night_fixture_reproduces_the_committed_response_within_budget
```

Swift, from `Packages/StrandAnalytics`:

```bash
swift build --build-tests
```
