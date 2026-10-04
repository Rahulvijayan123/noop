# Pretrained wrist CNN: numpy inference port

A dependency-light (numpy only) forward pass of the two pretrained networks published with
Nawaratne et al., *Deep learning to predict energy expenditure and activity intensity in free
living conditions using wrist-specific accelerometry*, J Sports Sci 2021;39(6):683-690
([doi:10.1080/02640414.2020.1841394](https://doi.org/10.1080/02640414.2020.1841394)), plus a
safe fetch-and-verify workflow for the weights and the tooling used to check the port.

Read this first:

* **The weights are not in this repository and must not be added.** The upstream repository
  (<https://github.com/razmik/cnn-wrist-model-freeliving>) ships no licence, so all rights stay
  with its authors. We download the two `.h5` files at a pinned commit, accept them only if their
  sha256 matches, convert them locally, and keep the result in the git-ignored
  `artifacts/wrist_cnn/`. See `artifacts/wrist_cnn/NOTICE.md`.
* **The labels are not calorimetry.** The networks were trained against energy-expenditure
  estimates that upstream's `ReferenceMethod.update_reference_ee` computes from the activity
  counts of a **waist-worn ActiGraph** with the Freedson VM3 Combination (11) equation, not
  against indirect calorimetry. The output is an activity-intensity index on a MET-like scale,
  **supporting evidence, not ground truth**. At rest it reads about 1.40, not a calorimetric
  1.0 MET.
* **Every accuracy number below is in-sample or synthetic.** The only real data available are
  the upstream repository's 1 292 sample windows (one participant, one day), drawn from the same
  free-living experiment the pretrained models were developed on, with no train/test split
  documented. The paper's held-out figures (r = 0.86, 83.7% intensity accuracy) are the better
  guide to what to expect on new people, and WHOOP data adds device and placement differences
  nobody has measured (see "Mismatch risks").

## Files

| File | Role | Needs |
| --- | --- | --- |
| `model.py` | `WristCNN` forward pass (both heads), batching, skip mask, `load_model`, `predict_met`, `predict_proba` | numpy |
| `inputs.py` | `prepare_windows` (100 Hz recording to model windows), layout helpers, `quiet_mask` | numpy |
| `ood.py` | `ood_signal(windows) -> [0, 1]` plausibility score | numpy |
| `spec.py`, `pins.py` | architecture constants; pinned commit, sizes, sha256 digests (no I/O) | stdlib |
| `integrity.py` | size + sha256 verification and the artifact directory; the loader runs it on every load | stdlib |
| `fetch.py` | download, verify, convert; the only module that touches the network or h5py | numpy (h5py to convert) |
| `verify_keras.py` | numpy-vs-Keras parity harness, golden-fixture writer | TensorFlow + tf_keras |
| `evaluate.py`, `ood_eval.py` | sample-data evaluation, orientation sensitivity, OOD checks, benchmark | numpy |
| `manifest.py` | writes `artifacts/wrist_cnn/manifest.json` | stdlib |
| `synthetic.py`, `testing.py` | deterministic test signals; tiny model and fake upstream for tests | numpy |

Importing `energy_models.wrist_cnn` imports numpy only (checked by a test).

## Get the weights

```bash
scripts/fetch_wrist_cnn.sh            # download, verify, convert, verify again; idempotent
scripts/fetch_wrist_cnn.sh --check    # offline: verify the converted files on disk (exit 1 if not ok)
```

Conversion needs `h5py` (`requirements-cnn-convert.txt`); if the interpreter lacks it the script
builds a throwaway virtualenv with the pins and deletes it afterwards. Exit status 2 means a
sha256 mismatch: the file was refused and nothing was converted. The loader re-verifies the
converted file's pinned sha256 on every load. Pinned digests (also in `manifest.json`):

| File | Size (bytes) | sha256 |
| --- | --- | --- |
| upstream `regression/.../best_model.013-0.28.h5` | 17 524 696 | `31a5769b14514996d114af462e7f2d142ed17ebdce7b4a70596499e0955a5d8c` |
| upstream `classification/.../best_model.007-0.36.h5` | 17 530 824 | `83b04e0946e2a2999918a64db992431f9a1d591225380b2ca87a16dd661c7747` |
| `wrist_cnn_regression_f32.npz` | 5 825 782 | `4c5af0c81fb44a118c71280eaba64f04529c4aaf8c896b7722a84c113f5db7ef` |
| `wrist_cnn_classification_f32.npz` | 5 827 710 | `9b545f211bfaff6b2c49f0380e9b51bf2e1bab73baa0e3984f588f99fe40d4fc` |

Upstream commit `9ca77ea104074ad82c648ec75c3a48e2bd82deeb` (2020-04-14). The `.npz` writer is
byte-deterministic: the converted digests were reproduced under five Python/numpy/h5py
combinations (Python 3.9 to 3.13, numpy 2.0.2 to 2.5.3, h5py 3.14.0 to 3.16.0), and the pinned
`.h5` digests by a from-scratch download.

## Use it

```python
import numpy as np
from energy_models.wrist_cnn import QUIET_MET_BASELINE, load_model, ood_signal, prepare_windows, quiet_mask

# acc: [N, 3] float, columns x, y, z in g, gravity included, uniform 100 Hz, NaN where missing
# (or pass timestamps=t_seconds and let prepare_windows resample onto the 100 Hz grid)
prep = prepare_windows(acc)                       # one 60 s window per minute, upstream layout
ood = ood_signal(prep.windows)                    # [n] in [0, 1]; above ~0.5 do not trust the CNN
use = prep.valid & (ood <= 0.5)

met = np.full(prep.n, np.nan, dtype=np.float32)
met[use] = load_model("regression").predict(prep.windows[use])        # MET-like index
proba = load_model("classification").predict(prep.windows[use])       # [m, 3] SED / LPA / MVPA

# optional: skip motionless minutes (about 9% of the sample, error <= 0.022 MET)
quiet = quiet_mask(prep.windows)
met2 = load_model("regression").predict(prep.windows, skip=quiet | ~prep.valid)   # NaN where skipped
met2[quiet & prep.valid] = QUIET_MET_BASELINE
```

`predict` runs in batches (`batch_size=16`, results do not depend on it), accepts `skip=` and
`on_invalid="nan"`, and refuses NaN windows by default. `WristCNN.load(head, artifacts_dir)`
gives the object API; `NARA_WRIST_CNN_DIR` overrides the artifact directory.

## What the weights expect (measured on the sample, not assumed)

| Item | Value | Evidence |
| --- | --- | --- |
| Units | g | all 266 quiet windows (every axis std < 0.15 g) have a median vector magnitude within 0.043 g of 1 g |
| Gravity | included | no filtering anywhere upstream; `feature_normalize` in upstream `utils.py` is never called |
| Scaling | none | raw values go straight into the first Conv1D |
| Rate / window | 100 Hz, 6 000 samples (60 s) | training windows overlap 50% |
| Range / resolution | rails at +-8 g, steps of about 3.9 mg | ActiGraph GT3X+ raw export: values are multiples of 1 mg, adjacent distinct values differ by 3 or 4 mg, largest magnitude 7.996 g (= 2047 x 16 g / 4096) |
| Layout | **three axes concatenated in time, then re-chopped into rows of three** | see below |

**The layout quirk.** `preprocess/prepare_train_data.py` builds each window as
`np.asarray([xs, ys, zs]).reshape(6000, 3)` without a transpose. The network was therefore
trained on `flat = [x0..x5999, y0..y5999, z0..z5999]` read in rows of three, i.e. a
convolution over three consecutive samples of one axis at a time, not over `[time, axis]`.
`prepare_windows` reproduces that by default (`layout="upstream"`). On the public sample the
same weights give RMSE 0.741 MET / bias +0.074 in the upstream layout and RMSE 2.213 MET /
bias -1.539 when fed the natural `[time, axis]` layout. The natural layout is available
(`layout="natural"`) for analysis only.

**Outputs.** Regression head: one linear float (not clipped). Classification head: softmax over
three classes, named SED / LPA / MVPA upstream. On the sample the head follows the energy bands
<1.5, 1.5 to <3, >=3 MET (91% agreement), while the sample's own `activity_classes` codes do
not follow that scheme (48% agreement; their counts, 646 / 542 / 104, do not match the
energy-band counts, 506 / 123 / 663), so treat the class names as upstream's, not a verified
clinical mapping. Label floor: upstream's label equation is MET = 0.001092 x VA counts + 1.336129
(capped at 2.9999) while the VM3 count rate is below 2453 per minute, and
0.000863 x VM3 + 0.668876 above that. Accordingly all 58 fully frozen sample windows (every
sample identical) carry the label 1.336, and the regression head returns 1.402 +- 0.010
(n = 116) on motionless windows.

## Architecture (read from the h5 configs, 1 455 621 / 1 456 103 parameters)

```
Reshape (18000) -> (6000, 3)
Conv1D 80  k10 valid relu  -> 5991     Conv1D 100 -> 5982     MaxPool1D 3 -> 1994
Conv1D 160 -> 1985         Conv1D 180 -> 1976                 MaxPool1D 3 -> 658 (2 trailing steps dropped)
Conv1D 220 -> 649          Conv1D 240 -> 640                  GlobalMaxPool1D -> 240
Dropout 0.5 (identity at inference)
Dense 1 linear (regression)   |   Dense 3 softmax (classification)       two separate networks
```

1.975 GMAC per window per head. Convolutions are cross-correlations (Keras convention, no kernel
flip), computed as im2col plus one float32 GEMM per layer, with bias and ReLU in place.

## Evidence

### Numerical parity with Keras

Reference: `tf_keras` 2.21.0 (legacy Keras 2 API; Keras 3 mis-reads the Keras 2.2.4 input shape)
on TensorFlow 2.21.0, CPU, float32, loading the pinned `.h5` with `compile=False`. Tolerance:
max absolute difference <= 1e-4.

| Head | Inputs | Max abs diff | Result |
| --- | --- | --- | --- |
| Regression (MET) | 96 real + 12 Gaussian + 15 synthetic + 5 edge windows | 1.1e-5 | pass |
| Regression (MET) | 4 uniform-noise stress windows | 3.8e-6 | pass |
| Classification (probability) | same sets | 5.1e-7 | pass |
| Classification (probability) | stress | 6.0e-8 | pass |

Layer by layer (ten stages), the numpy float32 path matches Keras to float32 rounding; on eight
windows both are within 4e-7 of a float64 numpy evaluation of the same weights.
`tests/fixtures/wrist_cnn_golden.npz` freezes three synthetic windows (still, walking-like,
running-like) and the Keras outputs for them, so parity is re-checked by the test suite with the
fetched weights but without TensorFlow.

### Sample-data accuracy (**in-sample**, one participant)

Participant LSM146, one day, 7 segments, 1 292 windows from the upstream training-ready sample.
The upstream training script uses the same folder for training and testing and the repository
documents no split, so assume the pretrained weights saw this participant.

| Quantity | Value |
| --- | --- |
| Regression vs window-mean energy label | RMSE 0.741 MET, MAE 0.452, bias +0.074, Pearson r 0.941, R2 0.862 |
| Per segment | RMSE 0.43 to 1.73 (the 1.73 segment has 40 windows and r = 0.65) |
| Regression-implied 3 classes vs energy bands | accuracy 0.903 (majority baseline 0.513) |
| Classification head vs energy bands | accuracy 0.910, balanced 0.870 |
| Classification head vs the sample's own class codes | accuracy 0.480 (codes do not follow the head's scheme) |
| Natural layout instead of upstream layout | RMSE 2.213 MET, bias -1.539, r 0.769 |

The paper's held-out result for comparison: r = 0.86, intensity accuracy 83.7%.

### Orientation sensitivity (public sample, regression head)

| Transform of the input axes | Mean abs change in output | Signed mean shift | Largest single-window change |
| --- | --- | --- | --- |
| five non-identity axis permutations | 0.10 to 0.14 MET | -0.02 to 0 | 1.6 MET |
| flip one axis | 0.14 to 0.24 | +0.00 to +0.15 | 2.1 |
| negate all three | 0.33 | +0.17 | 2.9 |

Axis order barely matters; axis **sign** does. The WHOOP-to-ActiGraph mapping is not
established, so `prepare_windows(axis_transform=R)` is only a research hook.

### Speed (Apple M4 Max, Python 3.11.13, numpy 2.2.6)

| Configuration | ms / window | 1 440 windows (one day), one head |
| --- | --- | --- |
| numpy macOS arm64 wheel (Accelerate), default threading | 3.6 wall (5.2 CPU) | 5.2 s |
| same, `VECLIB_MAXIMUM_THREADS=1` | 4.8 | 6.9 s |
| numpy `macosx_11_0_arm64` wheel (OpenBLAS, generic NEON kernels) | 41.5 | 59.8 s |
| Keras reference (TensorFlow 2.21.0, batch 12) | about 6.2 | not measured |

Best of 5 runs over 96 windows (OpenBLAS row: best of 3 runs over 16); the host was shared with
other workloads (load average 12 to 17), so the median is 2 to 4% higher. Time per window is
independent of batch size (1 to 64).
**The numpy build matters by an order of magnitude**: hosts without a tuned BLAS should expect
the OpenBLAS row or worse (x86 was not measured). Both heads cost the same. Scratch memory is
about 59 MB per thread plus 5.8 MB of weights per head. Around the model: `ood_signal` 0.17
ms/window, `quiet_mask` 0.04 ms/window, `prepare_windows` on 24 h of 100 Hz data (104 MB)
0.12 s. The whole test suite also passes under the OpenBLAS build.

### OOD signal

`ood_signal(windows) -> float32 [n]` in [0, 1]. It is the maximum of five components computed
from simple statistics (vector magnitude VM, per-axis std and range, mean vector norm, sample
to sample change, saturation and frozen-run coverage), all invariant to axis permutation and sign:

| Component | Formula | Catches |
| --- | --- | --- |
| nonfinite | 1 if any sample is NaN or inf | missing data |
| saturation | s / (s + 0.005), s = share of samples with any \|axis\| >= 7.9 g | railed sensor |
| flat | clip((c - 0.5) / 0.4, 0, 1), c = share of samples in runs of >= 1 s of identical values | frozen data |
| gravity | e / (e + 1), e = max(\|median VM - 1\| - 0.06, 0) / 0.05, only when every axis std < 0.15 g | wrong units, gravity removed, gain errors on still windows |
| envelope | max over 11 features of e / (e + 1), e = distance outside [p0.5 - 0.25w, p99.5 + 0.25w] of the public windows in units of the side's half-width w | everything far from the sample |

Reading it: below about 0.2 unremarkable, above 0.5 treat the CNN output as unsupported, near 1
a unit mismatch or dead/railed/missing data. Measured on the public windows (all in-sample or
synthetic):

| Check | Result |
| --- | --- |
| Synthetic still / walking-like (1.8 Hz) | 0.00 / 0.00 |
| Synthetic running-like (2.8 Hz) | 0.40 mean (0.19 to 0.56): the sample's envelope is one person's |
| Saturated +-8 g / constant / NaN block | 0.995 / 1.0 / 1.0 |
| Units: m/s^2, milli-g, raw LSB | 0.99 to 1.00 (100% above 0.5) |
| Gravity removed / scale x0.5 / scale x2 | 0.82 / 0.84 / 0.61 mean |
| Scale x1.5 | 0.34 mean, 30% above 0.5 (partial) |
| White noise 0.05 g / 0.3 g / 1.0 g | 0.00 / 0.21 / 0.80 mean; 0.3 g noise moves the MET output by 0.56 on average and is **not** flagged |
| Leave-one-segment-out false alarms (score > 0.5) | 9.4% (1.7% without the `flat` component) |

Known weaknesses, all real:

* The envelope comes from one participant, one day, 7 segments. Stronger movement than theirs is
  scored as unusual although the weights saw it in training; in-envelope statistics say nothing
  about placement, axis sign or sensor-noise differences.
* Univariate envelopes miss joint inconsistencies; only the gravity rule is joint.
* 24% of the public windows contain at least 1 s of repeated samples (consistent with ActiGraph
  idle-sleep mode) and 7.7% are flagged `flat`. The network saw such inputs, but a frozen minute from a WHOOP strap is a
  data fault, so the flag stays; expect false alarms on genuinely still, quantised data.
* The score is **not calibrated against error**: in-sample, Spearman(score, |error|) = -0.10, and
  windows scoring >= 0.5 have a lower mean |error| (0.11 MET, n = 100) than windows scoring < 0.2
  (0.49 MET, n = 1 166), because the high scorers are mostly easy frozen minutes. Use it as a
  data-quality gate, never as an uncertainty.

## Mismatch risks for WHOOP data

1. **Axis frame.** Sign errors shift output by up to 0.17 MET on average and 2.9 MET on single
   windows (table above); permutations matter much less. Calibrate the mapping against
   labelled data before trusting individual windows.
2. **Signal character.** Training data are ActiGraph wrist signals in 3.9 mg steps; WHOOP raw is
   1/4096 g (0.24 mg) with its own noise and filtering. Response to that difference was not
   measured here.
3. **Wear site.** Trained on the wrist; a strap on the upper arm has different motion statistics.
4. **Labels.** Waist-ActiGraph estimates from one free-living cohort. The model reproduces that
   algorithm's view of the wrist signal, including its floor (the equation's 1.336 intercept at
   zero counts), not metabolic cost. Do not report its output as measured calories.
5. **Gaps.** Windows need uniform 100 Hz; `prepare_windows` marks windows with more than 5%
   missing samples or a gap longer than 0.5 s as invalid instead of papering over them.

## Tests

```bash
python -m pytest tests -o addopts="" -q -p no:cacheprovider -W error
```

Covers: tiny-architecture comparison against an explicit-loop float64 reference (both heads),
golden-fixture parity (skips cleanly if artifacts are absent), digest-mismatch refusal on
download/cache/convert/load, architecture-mutation refusals, deterministic `.npz` writer,
shape and NaN handling, batching and skip-mask equivalence, thread safety, window preparation,
OOD behaviour on still / walking-like / saturated / flat / NaN signals, manifest and requirements
consistency with the pins, the fetch script's exit codes, and a check that no weight files are
tracked. Only the real-weights tests need the fetched artifacts; they skip cleanly without them.
Tests that build a fake Keras file need `h5py` and the live Keras comparison needs `tf_keras`;
both skip when those are absent.

Git note: a repository-root `.gitignore` rule (`Fixtures/`) also matches `tests/fixtures/`, which
hides `wrist_cnn_golden.npz` (and the WristMET golden file) from `git add`. Re-include it with
`!tests/fixtures/` in `Tools/EnergyModels/.gitignore`, or `git add -f` the file. The golden test
fails loudly, rather than skipping, if the fixture is missing.

## Reproduce the reported numbers

```bash
SAMPLE=<clone of upstream>/data/train_ready/window-6000-overlap-3000
python -m energy_models.wrist_cnn.verify_keras --sample-dir $SAMPLE --report parity.json   # requirements-cnn-verify.txt
python -m energy_models.wrist_cnn.evaluate     --sample-dir $SAMPLE --json eval.json
python -m energy_models.wrist_cnn.ood_eval     --sample-dir $SAMPLE --json ood.json
python -m energy_models.wrist_cnn.manifest --parity parity.json --eval eval.json --ood ood.json
```

The sample data are upstream's and are not copied into this repository.
