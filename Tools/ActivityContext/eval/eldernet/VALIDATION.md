# ElderNet gait quality — validation (weights frozen)

Model `eldernet-437a38b` (yonbrand/gait-quality @ `437a38bc`, six pinned heads), preprocessing `eldernet-prep-1`,
served detector (window-local static pre-filter, `gait_prob` = upstream softmax, threshold 0.5) unless stated.
Machine-readable: `VALIDATION.json`. Nara trained nothing; the only fitted quantities are a temperature and an
operating threshold on VAL subjects (`calibration.json`). Splits: the frozen subject splits in `splits/`.
Truth from the audited crosswalk (`label_mappings.json`, locomotion head): walking / brisk walking / stairs =
gait; stationary / cycling / vehicle = non-gait; running reported separately; mixed or null labels masked; a
10 s window (hop 5 s) takes a label only if >= 90 % of its samples carry it.

## 1. Parity with upstream `pipelines.general`

| check | result |
|---|---|
| upstream toy example (13 min, Mobilise-D) | 416 / 416 bout windows, 6 / 6 bouts, 7.83 min walking identical; every metric within upstream's own 1e-4 tolerance (max 2.4e-5 cadence) |
| 3 h Capture-24 segments (P001 / P002 / P004, literal `pipelines.general --device cpu`) | is_gait agreement 1.000 on 10,791 windows each; bouts, walking minutes, bout windows identical (43 / 35 / 27 bouts); quality max abs diff <= 3.6e-5 (cadence, step count) |
| detector probability | max abs diff vs upstream <= 3.6e-6 (torch 2.8 here vs 2.0.1 upstream) |
| resampler | nearest-neighbour index map bit-identical to `actipy.processing.resample` |
| model code | upstream's own `models.py`, imported from the operator's sha256-verified checkout (no Oxford code in Nara's repo; ELDERNET.md "Licence"): all six heads bit-identical to the previously vendored copy on 919 windows (200 random + 719 Capture-24 hop-5); the three 3 h segments re-run byte-identical (arrays, CSVs, compare reports). The vendored copy itself had matched upstream `build_model` within 3.6e-7 (detection), 0 (regression heads) |
| bout rules | upstream's own `gait_quality.detection` / `quality` functions through the same adapter (toy example and 3 h segments above) |
| determinism | bit-identical across reruns, batch positions and request chunking (no edge exclusion needed) |

Whole-day departures (six full Capture-24 VAL days, 24-30 h each):

* **Static pre-filter**: upstream's Otsu threshold was 0.0012-0.0015 g² on every day, always above the
  0.013² g² ceiling, so upstream used the ceiling too — the window-local pre-filter matched upstream on 100 % of
  windows (0 extra pre-filtered windows on all six days).
* **Gravity calibration** (upstream runs actipy's auto-calibration; Nara does not — it needs the whole recording):
  on the 4 / 6 days where calibration changed the data (error 13.7-15.8 -> 3.3-9.4 mg), is_gait flipped on
  19-115 of ~17,600-21,400 hop-5 windows (0.1-0.6 % of windows; up to ~13 % of that day's gait windows),
  max |Δ gait_prob| 0.27-0.56. This is the main known difference from upstream on uncalibrated straps.

Resampling (not a departure from upstream inference, but from upstream fine-tuning): served 100 → 30 Hz is
nearest-neighbour without anti-aliasing, exactly as upstream inference; upstream fine-tuning resampled band-limited
(`scipy.signal.resample` per 10 s window). Against a polyphase anti-aliased resampler (`resample_poly` 3/10) is_gait
flips on **2.5 %** of hop-5 windows (161 / 6,477 on the three 3 h segments above, Capture-24 train subjects; gait
windows 1,197 vs 1,200; mean cadence / speed shift on windows both call gait ≤ 0.02 steps/min / 0.01 m/s),
re-measured 2026-10-06. On labelled VAL windows of six Capture-24 VAL subjects (74,460 windows, 6,022 gait) there
is no accuracy loss: F1 0.539 nearest-neighbour vs 0.537 band-limited per window vs 0.557 polyphase, AUROC 0.957 /
0.959 / 0.956, ECE 0.017 / 0.022 / 0.029; nearest vs band-limited flip 0.46 % of those windows (the audit's
measurement, re-run 2026-10-06 through the upstream adapter with identical results). WHOOP's high-frequency
content is unmeasured; check on WHOOP walking before candidate use.

## 2. Gait detection on the frozen TEST subjects (evaluated once)

> **Provenance: transcribed from non-persisted console output of the single TEST run by the agent; not
> machine-verifiable** (the run's report and ledger line were lost in an SSD disconnect). Counts and hashes are
> consistent: test_sha256 `677165e7…`, calibration `cal:16191350862fb8de` (bundle
> `eldernet-437a38b+cal:16191350862fb8de`); the 2026-10-06 audit recomputed the split hash and the per-dataset
> window and subject counts from the extraction parts' identity and truth columns only (no TEST predictions
> read). The ledger was not reconstructed and TEST was not re-run (owner decision).

| TEST set | subjects | gait / non-gait windows | P | R | F1 | AUROC | ECE |
|---|---|---|---|---|---|---|---|
| Capture-24 (free-living) | 50 | 52,369 / 463,101 | 0.876 [0.834, 0.909] | 0.522 [0.445, 0.588] | 0.654 | 0.967 | 0.019 |
| WISDM-2019 watch | 8 | 516 / 3,212 | 0.944 [0.918, 0.971] | 0.950 [0.894, 0.991] | 0.947 | 0.998 | 0.050 |
| PAMAP2 * | 2 | 124 / 697 | 0.975 | 0.935 | 0.955 | 0.997 | 0.062 |
| HHAR watch * | 2 | 309 / 342 | 1.000 | 0.990 | 0.995 | 1.000 | 0.046 |
| MHEALTH * | 2 | 36 / 103 | 0.973 | 1.000 | 0.986 | 1.000 | 0.062 |
| Opportunity * | 1 | 8 / 290 | 0.318 | 0.875 | 0.467 | 0.981 | 0.141 |
| pooled (dataset-stratified) | 65 | 53,362 / 467,745 | 0.879 [0.838, 0.910] | 0.530 [0.455, 0.595] | 0.661 | 0.967 | 0.018 |

Brackets: 95 % subject-cluster bootstrap. * small sample (< 5 subjects or < 50 windows of a class): CIs not
trustworthy. Running windows (not in P/R): called gait in 4.1 % (Capture-24), 7.3 % (WISDM), 33 % (MHEALTH).

**Integrity note.** These numbers are the console output of the single TEST evaluation (ledger stamp time
1791310368 = 2026-10-06T18:12:48Z as printed, bundle `eldernet-437a38b+cal:16191350862fb8de`, test_sha256
`677165e7…`). The machine report and the ledger line were lost when the external SSD disconnected uncleanly
about two minutes after the run. They have **not** been regenerated: doing so needs a recorded rerun
(`rerun_reason=artifact_lost_identical_rebuild`), which is left to the owner. `test_ledger.jsonl` therefore holds
only the external-set entries (GOTOV, OxWalk). The lost evaluation stays binding through a forward guard, not a
ledger edit: `activity_context/eldernet/integrity_ext.py` `SPENT_EXPERIMENTS` lists this experiment (and the two
external sets), and `validate test` refuses it before loading anything unless given an enumerated rerun reason
plus detail, recording any such run as a rerun of this opening (ELDERNET.md §7).

Reading: on lab protocols and older adults (GOTOV, below) detection is near-perfect; in free-living Capture-24
precision is 0.88 but recall 0.52. Capture-24's camera-annotated "walking" episodes include standing pauses and
short shuffles inside a label (VAL false negatives were mostly "walking household without observable loads");
AUROC 0.967 says the ranking is good and the shortfall is largely the 0.5 operating point on short or
interrupted household gait.

### Calibration and operating point (VAL only, `calibration.json`)

* Temperature on free-living VAL windows (Capture-24, 20 subjects): **T = 1.047** — upstream's softmax is already
  calibrated on free-living data (Capture-24 TEST ECE 0.019 uncalibrated, 0.017 calibrated). An equal-weight fit
  over all six VAL datasets (T = 0.557) was rejected on VAL before TEST was opened: it tripled free-living ECE.
* Operating threshold for >= 95 % precision (`inertia.abstention.select_operating_point`, cluster bootstrap q05
  >= 0.95, stable above tau): **tau = 0.93** ("strong", VAL precision 0.974, recall 0.27). On TEST:
  Capture-24 P 0.982 [0.970, 0.991] / R 0.312; pooled P 0.983 / R 0.316. A high-precision setting, not a default.
* **Decoder π** (Capture-24 VAL, hop 5; `validate prior`, VALIDATION.json `decoder_prior`). The gait term is
  r(gait) = q/π, r(non-gait) = (1 − q)/(1 − π); it is mean-neutral over the windows the decoder sees exactly when
  π = E[q] over those windows. They are all served windows of worn time — labelled, masked, unlabelled, and
  pre-filtered (q = 0 on the wire):

  | Capture-24 VAL windows (20 subjects) | n | share | mean served gait_prob | pre-filtered |
  |---|---|---|---|---|
  | **all (what the decoder sees)** | 376,755 | 1.00 | **0.0849** (subject-bootstrap 95 % CI 0.076-0.095; per subject 0.056-0.130) | 0.44 |
  | labelled gait / non-gait | 225,188 | 0.60 | 0.061 (gait prevalence **0.065**: 14,707 / 225,188) | 0.48 |
  | labelled but masked (mixed, other, running) | 27,869 | 0.07 | 0.227 | 0.02 |
  | unlabelled | 123,698 | 0.33 | 0.096 | 0.46 |
  | not pre-filtered | 210,777 | 0.56 | 0.152 (gait prevalence 0.125) | 0 |

  **Recommended π = 0.085.** The previous value, the labelled-window prevalence 0.065, gives E[q/π] = 1.31 over
  the windows the decoder sees — a standing pull toward gait. Pooled VAL labelled prevalence (all six datasets)
  0.068. Lab datasets are protocol-driven (0.11-0.99) and should not set π.

### Running, cycling and vehicle windows (VAL only; for the decoder's gait-row compat)

Served gait_prob on VAL windows whose truth is running (>= 90 % pure) or whose majority label is exactly cycling /
vehicle in the crosswalk (and >= 90 % non-gait); `validate other-motion`, VALIDATION.json `val_other_motion`.
"q > π" uses π = 0.085.

| VAL windows | n | subjects | mean | p10 / p25 / median / p75 / p90 | >= 0.5 | >= 0.93 | q > π |
|---|---|---|---|---|---|---|---|
| running, pooled | 351 | 11 | 0.096 | 0.005 / 0.016 / 0.055 / 0.099 / 0.201 | 3.4 % | 0.3 % | 32 % |
| — WISDM-2019 jogging (B) | 308 | 8 | 0.096 | 0.005 / 0.016 / 0.057 / 0.103 / 0.194 | 3.2 % | 0.3 % | 34 % |
| — MHEALTH jogging (10) | 21 | 2 | 0.022 | 0.009 / 0.013 / 0.019 / 0.029 / 0.035 | 0 % | 0 % | 0 % |
| — MHEALTH running (11) | 21 | 2 | 0.163 | 0.015 / 0.036 / 0.055 / 0.176 / 0.481 | 9.5 % | 0 % | 29 % |
| — PAMAP2 running (5) | 1 | 1 | 0.177 | — | 0 | 0 | 1 / 1 |
| — Capture-24 running | 0 | — | (no running in the 20 VAL subjects) | | | | |
| cycling, pooled | 3,462 | 13 | 0.061 | 0.015 / 0.021 / 0.032 / 0.059 / 0.136 | 0.8 % | 0 % | 17 % |
| — Capture-24 bicycling | 3,401 | 9 | 0.061 | 0.015 / 0.021 / 0.032 / 0.059 / 0.135 | 0.9 % | 0 % | 17 % |
| vehicle (Capture-24 driving, car, bus, vehicle) | 14,183 | 13 | 0.091 | 0.001 / 0.006 / 0.028 / 0.114 / 0.273 | 2.9 % | 0.1 % | 30 % |
| reference: walking / stairs (gait), pooled | 15,636 | 33 | 0.538 | 0.094 / 0.214 / 0.465 / 0.953 / 0.994 | 48 % | 28 % | 91 % |
| reference: stationary, pooled | 197,295 | 32 | 0.025 | 0.000 / 0.000 / 0.000 / 0.010 / 0.060 | 0.7 % | 0.1 % | 8 % |

Reading: ElderNet does not call running gait (it was fine-tuned on walking only): two thirds of running windows sit
at or below π, so a `run` entry in the gait row would push run down on most running seconds; neutral (today's
compat) matches the data. Cycling and vehicle look like non-gait. Small samples: running is 351 windows from 11
lab subjects, none free-living.

## 3. External sets (never used for fitting; evaluated once through the ledger)

**GOTOV** (35 older adults, 59.5-81.3 y, GENEActiv wrist, protocol activities; `VALIDATION_GOTOV.json`):

* Detection: P 0.966 [0.941, 0.983], R 0.996 [0.992, 0.999], F1 0.981, specificity 0.986, AUROC 0.999 (3,697 gait /
  9,296 non-gait windows). At tau 0.93: P 0.998, R 0.953. Recall by pace: slow 0.999, normal 0.993, fast 0.998,
  stairs up 0.935.
* Speed ordinal check (per-participant medians over detected gait): slow < normal < fast in 19 / 21 participants
  with all three paces (pooled medians 1.26 / 1.44 / 1.50 m/s; normal − slow > 0 in 21 / 21, Wilcoxon p 5e-7;
  fast − normal > 0 in 19 / 21, p 1.5e-4). Cadence: 20 / 21 ordered (106 / 115 / 121 steps/min).

**OxWalk** (39 healthy adults 18+, one hour of unscripted free living each, dominant-wrist Axivity AX3 100 Hz,
video-annotated heel strikes; `VALIDATION_OXWALK.json`). Rules fixed before evaluation (`oxwalk.py`): a window is
gait if it holds >= 6 annotated steps, non-gait if 0, masked if 1-5 (2,142 of 27,213 windows).

* Detection: P 0.983 [0.972, 0.990], R 0.869 [0.809, 0.914], F1 0.922, specificity 0.994, AUROC 0.994
  (7,566 gait / 17,505 non-gait windows). At tau 0.93: P 0.999, R 0.474.
* Step count per 10 s window (6,572 windows that are gait by truth and detected): bias −0.34 steps, MAE 1.02
  (7.1 %), Pearson r 0.86, 95 % limits of agreement [−3.8, +3.1] (true mean 16.8 steps). Cadence vs 6 × annotated
  steps: bias +4.7 steps/min, MAE 7.1 (10.5 %), r 0.84.
* Per-participant hour totals (non-overlapping 10 s windows, detection included): median absolute error 15 %
  (IQR 6-34 %); 55,574 predicted vs 62,841 annotated steps overall (−11.6 %). The largest relative errors are
  participants with few steps (e.g. 258 annotated, 76 predicted), i.e. short gait the detector does not call.
  112 detected windows had no annotated step (mean 8.9 predicted steps).

## 4. Serve latency and memory (`python -m activity_context.eldernet.serve`, 1 torch thread, batch 64)

arm64 Mac, 16 cores, **shared and heavily loaded** (1-min load average 14-40 from other jobs during the
runs) — treat as upper bounds. Load to first ping 1.0-1.9 s; peak RSS **~650 MB**; request 5.8 MB per hour.

| 1-hour request | hop 5 s (served default) | hop 1 s (upstream stride) |
|---|---|---|
| rest (every window pre-filtered) | 0.03-0.10 s | 0.06-0.36 s |
| Capture-24 hour (108 / 719 gait) | 2.4 s | 11.1 s |
| gait-dense (toy recording tiled, 474 / 719 gait) | 14.8 s (load 30-40) | 33.1 s (load 30-40) |

Cost is ~1.7-1.9 ms per window per head with NNPACK disabled, as served. Re-measured 2026-10-06
(`python -m activity_context.eldernet.bench --nnpack --npy <Capture-24 hour>`: the 640 non-pre-filtered hop-5
windows, torch 2.8.0, 1 thread, batch 64, best of 2, 1-min load average 7-9): with NNPACK enabled torch routes the
depthwise anti-alias convolution through NNPACK one group at a time, 71-74 ms per window per head, **39-44x
slower**; outputs differ by at most **7.6e-6 in the detection logits** (the audit's 64-window sample: 3.9e-6),
**3.8e-5 steps/min cadence** (audit: 2.3e-5), 4.1e-5 steps per window, <= 2.7e-6 for speed / stride /
regularity (VALIDATION.json `bench.nnpack_check`). The earlier "~15x, ~1e-8" note was wrong. A gait-dense hour at
hop 1 can approach the default 60 s timeout on a loaded host: the worker should keep hop 5 and <= 1 h requests.

Request chunking: windows are cut only fully inside a request's `[start_ts, end_ts]`, so the hop-5 window that
would straddle a chunk boundary (start `end_ts − 5`) is never produced — at the worker's 1-hour chunks, 719 of 720
hop-5 windows per hour (ELDERNET.md §2.4). Every window that is produced is bit-identical whatever the chunking.

## 5. Not measured / limitations

* Step / cadence agreement is measured on healthy adults only (OxWalk); none in older adults.
* Speed / stride length have no reference in these datasets beyond GOTOV's ordinal paces; ElderNet was fine-tuned
  on older adults with impaired gait and a systematic shift is expected on young healthy wearers.
* No WHOOP-recorded ground truth: all wrist data here are other devices (Axivity, GENEActiv, smartwatches) with
  their own axis frames; the WHOOP strap's frame and wrist position are not validated.
* Gravity calibration is not applied (§1); its effect on WHOOP straps is unmeasured.
* Anti-aliasing: nearest-neighbour resampling (as upstream inference) vs the band-limited resampling of upstream
  fine-tuning flips ~2.5 % of Capture-24 windows (§1); WHOOP's high-frequency content is unmeasured.
* The frozen-split TEST numbers (§2) are a transcript, not a machine report (§2 provenance).
