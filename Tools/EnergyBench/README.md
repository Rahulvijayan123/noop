# EnergyBench

An offline harness that replays a wearer's real days through the app's own `AnalyticsEngine.analyzeDay`
twice and compares the two energy models side by side:

* **legacy** — the previous heart-rate-only estimator (`EnergyModelChoice.legacyHR`): Keytel above a 50 %-HRR
  gate, resting energy over observed seconds only. This is the number the app showed before.
* **fusion** — the multimodel metabolic estimator (`EnergyModelChoice.fusion`, the default): activity-aware
  fusion of heart-rate physiology, step cadence, wrist motion and (when raw IMU was recorded) WristMET and the
  wrist CNN, smoothed through time, with RMR counted over the full 24 hours.

It exists to check two properties the fusion estimator was built for, on days that already happened:

1. **Sustained moderate activity that stays below the old HR gate is credited** — at a MET a compendium
   would recognise, and strictly more than the old model credited.
2. **A light day is not re-inflated** — the failure mode of crediting every elevated reading at the exercise
   rate. A day with no workout, no sustained session and little locomotion must stay within a physical
   activity level (total energy ÷ 24 h RMR) of 1.55.

Neither estimator is calorimetry and there is no ground truth in this repository. The harness says where the
two disagree and whether the disagreement is the kind the new model is meant to produce; it does not
calibrate the model to anyone's expectation of their own total.

## Health data stays out of the repository

A day bundle is a person's heart-rate and motion record. The bundle directory is **always a command-line
argument**, lives outside the tree, and is never written to. `.gitignore` carries a backstop for the file
names the tool produces, but the rule is: do not put exports, bundles or reports under this directory.
`swift test` uses only invented, synthetic days.

## Quick start

```sh
cd Tools/EnergyBench
swift build -c release

.build/release/energybench --days /path/outside/the/repo/days \
    --report /path/outside/the/repo/report.md --json /path/outside/the/repo/report.json
```

| Flag | Meaning |
|---|---|
| `--days DIR` | directory of `energy-bench-day-v1` bundles (required) |
| `--only 2026-10-01,2026-10-02` | replay just these days |
| `--rmr 1850` | what-if: use a measured RMR (kcal/day) instead of the population equation |
| `--report FILE.md`, `--json FILE.json` | write the Markdown / JSON report |
| `--timeline 2026-10-02@21:30-22:55` | per-minute table (HR, motion, activity, MET ± σ, confidence, kcal, evidence, flags) |
| `--csv-day DAY --csv FILE.csv` | the same per-minute table for a whole day |
| `--min-bout`, `--cadence`, `--dyn`, `--light-pal` | override the harness's own definitions below |

Exit status: `0` every applicable check passed, `1` a check failed, `2` usage or I/O error.

Building needs the same toolchain as the app (Swift 5.9+, macOS 13+). It depends only on the local
`StrandAnalytics`, `WhoopProtocol` and `WhoopStore` packages.

## What it checks

| Check | Says |
|---|---|
| `legacy-total-reproduced` | the legacy column is exactly what `analyzeDay(.legacyHR)` publishes, so the comparison prices what the app priced (including a day with no resting HR being replayed as `nil`, not a stand-in) |
| `fusion-total-is-the-timeline` | `activeKcalEst` under fusion equals the sum of its minutes; workout energy is a subset of active energy and never added again |
| `resting-is-24h-and-coverage-independent` | resting energy = RMR ÷ 1440 × every elapsed minute, whatever the strap covered |
| `values-are-finite-and-bounded` | MET ≥ 1, kcal ≥ 0, σ ≥ 0, confidence in [0, 1] on every minute |
| `sub-threshold-moderate-activity-credited` | every found bout whose minutes all sit below the old gate is credited above the old model, with a mean MET inside its plausibility band |
| `light-days-not-overcounted` | complete light days stay at or under the PAL bound |

A check that has nothing to judge in the supplied days reports `N/A`, not `PASS`.

## Independent definitions

The harness finds activity **without the estimator** so that it is a witness and not the model grading
itself. The thresholds are fixed in `BenchOptions`, not read from `EnergyConfig`:

* **Locomotion bout** — ≥ 10 minutes at ≥ 80 step-counter ticks/min (≥ 0.15 g gravity-removed wrist motion on a
  day with no counter), bridging gaps of up to 2 non-moving minutes. MET band 2.0 – 5.5 (Compendium slow walk
  to very brisk walk).
* **Session** — ≥ 20 minutes at ≥ 30 % of heart-rate reserve with motion behind it (≥ 0.05 g or ≥ 20 ticks/min), bridging gaps of
  up to 3 minutes. A locomotion run mostly inside a session is reported once, as the session. MET band 2.0 – 8.0.
* **Sub-gate** — every minute's mean HR is below the legacy gate (`resting + 0.5 × (HRmax − resting)`).
  The harness keeps its own copy of that constant (it is internal to the package);
  `LegacyGateTests.testLegacyGateConstantMatchesTheEstimator` fails if the two drift.
* **Light day** — no detected workout, no session, fewer than 10 minutes at or above the gate and fewer than
  90 moving minutes.
* **30 %-gate column** — the earlier day model (gross Keytel above 30 % HRR) that over-counted ordinary days,
  shown for context only. It is itself a poor estimate and is not a bound.

## Reading the report

* *Legacy total* is resting + active as the old model reported it; *fusion total* is the 24 h RMR plus
  active energy; *PAL* is fusion total ÷ RMR. A partial (still-recording) day is marked `*` and is judged
  only up to its last sample, with a projected full-day figure in the second table.
* *Evidence minutes* counts which families of evidence reached each day's minutes. **Days recorded before raw
  IMU capture have no WristMET or wrist-CNN evidence**; the fusion then runs on heart rate, the strap's
  gravity-removed motion, the step counter and the activity priors, and WHOOP 4.0 days (no motion channel, no
  step counter) are heart-rate-only with lower confidence. The report says so rather than implying otherwise.
* *Active kcal below old gate* is the share of the day's active energy earned in minutes whose heart rate sat
  below the legacy gate — zero by construction for the legacy model, and the number that shows the gate is gone.
* `ms` is the estimator's own wall-clock for the day (best of three).

## Getting days into bundles

The bundle format is `energy-bench-day-v1`: one JSON file per **local** day (`format`, `day`,
`tz_offset_seconds`, `day_start`, optional `as_of` for a day still in progress, `profile`, optional
`resting_hr`, `sleep` rows, and the delta-encoded `hr`, `steps`, `gravity` streams). `scripts/export_queries.sql`
holds read-only query templates for the scoring database and `scripts/assemble_day_bundles.py` validates the
results and writes the bundles:

```sh
scripts/assemble_day_bundles.py --out /path/outside/the/repo/days --profile profile.json \
    --tz-offset -25200 --meta meta.json [--in-progress 2026-10-03] hr-and-steps-and-gravity-results.json …
```

Export one wearer at a time and only that wearer's rows. The scored nights are replayed as pre-staged sleep
sessions so the harness does not re-derive sleep from a stream that begins at local midnight, in the middle
of the previous night.

## Tests

`swift test` needs no data. It covers the bundle codec, the run finder, per-minute signals, the legacy-gate
constant, bout finding and the checks on synthetic days (including that each check fails when it should), and
the report renderers.

## Caveats worth keeping in mind

* No ground truth: bands are plausibility envelopes from published MET values, not measurements.
* Exports taken before raw-IMU capture exercise the heart-rate, cadence and wrist-motion paths only; the
  WristMET and wrist-CNN paths are covered by the Python package's tests and by synthetic evidence in the
  Swift tests.
* Sleep comes from the scored nights in the bundle. Where a night is mis-detected the estimator's
  heart-rate contradiction guard (`sleep_contradicted`) is what stops it zeroing a day's active energy.
