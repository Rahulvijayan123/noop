# RecGym gym-exercise recognition — SHADOW head (contract)

`activity_context.recgym` runs the public pretrained CNN + Transformer of
[`MKorp7/HAR_IMU_CNN-Transformer`](https://github.com/MKorp7/HAR_IMU_CNN-Transformer) (MIT) over the strap's raw IMU
and stores twelve class probabilities per 4 s window. It is a **shadow** expert: nothing reads its output for a
decode, a canonical value, the Watchdog or the exercise-session rule (`docs/context-watchdog/EXERCISE_SESSION.md`).
It was ported because the owner's gym evenings read as "still" to the wrist classifiers (he wears the strap on the
upper arm, and lifting between and during sets barely moves it); §8 says what it does on his data: **on an
upper-arm strap it does not separate gym from non-gym time better than plain movement intensity.**

## 1. What is pinned

| Item | Pin |
| --- | --- |
| Upstream repository / commit | `MKorp7/HAR_IMU_CNN-Transformer` @ `e085ac0e116aa5997d5f593ac1d0dd0c801859b1`, MIT, "Copyright (c) 2025 MKorp7" |
| Archive | `models.zip`, 6,321,334 B, sha256 `eb779a1f…cdfe8` (`https://raw.githubusercontent.com/MKorp7/HAR_IMU_CNN-Transformer/<commit>/models.zip`) |
| Checkpoint | member `models/wrist_-_imu_only_best.pt` (wrist, IMU only, 6 channels, 12 classes), 774,140 B, sha256 `7f0c4adf…8f5d9`; a strict `state_dict` |
| Architecture | `vendor/imu_transformer.py` = upstream `src/models/imu_transformer.py` byte for byte (sha256 `edd1801e…278c`), `IMUCNNTransformer(in_channels=6, num_classes=12, d_model=64, n_heads=4, num_layers=2, dropout=0.2)` |
| Scaler | `recgym_wrist_imu_scaler.json` (`recgym-wrist-imu-scaler-1`), reproduced (§1.2) |
| Classes | `sorted(df["Workout"].unique())`: Adductor, ArmCurl, BenchPress, LegCurl, LegPress, **Null** (index 5), Riding, RopeSkipping, Running, Squat, StairClimber, Walking |
| Wire / model / preprocessing | `exercise-windows-1` / `recgym-cnn-transformer-e085ac0` / `recgym-prep-1` |

The checkpoint is never committed. The deployment stages it from the sidecar model manifest (entry
`recgym_cnn_transformer`: the archive by url + sha256, the member by `zip_member`) with `deploy/provision.sh`; a host
without the provisioner uses `python -m activity_context.recgym.weights fetch --dest DIR`. The serve process only
verifies (size, then sha256) before `torch.load(weights_only=True)`.

### 1.1 Upstream training, as shipped

RecGym wrist windows, subjects 1–7 train / 8 val / 9–10 test, AdamW, 45 epochs, `ReduceLROnPlateau` on val accuracy.
Upstream keeps `best_state = model.state_dict()` (a live reference, not a copy), so the saved "best" weights are the
epoch-45 weights; the reported test accuracy was computed with those same weights, so the two are consistent.

### 1.2 The scaler, reproduced

Upstream fits `StandardScaler` on the training windows flattened to `(N, 80·6)` and does not ship it. The scaler is
therefore **per (time step, channel)**: 480 means and 480 scales (the per-channel summary is in the file; the means of
one channel differ by at most 8e-4 across time steps). `reproduce.py` refits it exactly:

- Data: the RecGym CSV from the Kaggle mirror upstream's notebook downloads
  (`zhaxidelebsz/10-gym-exercises-with-615-abstracted-features`, version 6). The Kaggle API answers this public dataset
  without credentials (a signed storage redirect). Archive sha256 `0abc140f…6f92`, `RecGym.csv` sha256 `2031c077…40e9`
  (4,703,320 rows; its first rows equal the notebook's printed head). The UCI copy (dataset 1128, CC BY 4.0) is
  **unusable**: its archive (sha256 `9713a9ca…41de`, identical on two downloads) has ~60 MB of zero bytes where its
  local file header and data should be.
- Procedure: upstream's own windowing (`vendor/recgym_data.py`, byte for byte): wrist only, per (Subject, Session),
  80 samples, step 40, majority label ≥ 0.6 else dropped → 39,560 windows (28,820 train, 3,668 val, 7,072 test).
- Check (`reproduce.py` refuses to write otherwise): the shipped checkpoint with the refit scaler gives **test accuracy
  0.9634, loss 0.1516** (upstream reported 0.963 / 0.1516) and **val 0.9673 / 0.1357** (the notebook's epoch 45:
  0.967 / 0.1357). Test recall per class: Adductor 0.858, ArmCurl 0.996, BenchPress 0.985, LegCurl 0.966, LegPress
  0.984, Null 0.965, Riding 0.944, RopeSkipping 0.878, Running 0.977, Squat 0.942, StairClimber 0.998, Walking 0.976.

## 2. Units and axes (`recgym-prep-1`)

### 2.1 RecGym's units, measured from the data

The dataset documentation says only "normalized". The data say (wrist, 1.63 M rows; `G-models` scripts in the build
scratch):

| Channel | Grid | Unclipped range | Reading |
| --- | --- | --- | --- |
| A_x, A_y, A_z | 0.5 + k/8000 exactly | 0.5 ± 39.99/80 | linear acceleration in m/s², 0.01 m/s² steps, `clip(0.5 + a/80, 0, 1)` (±40 m/s²) |
| G_x, G_y, G_z | 0.5 + round(6.25·n)/160000 | 0.5 ± 799.9/1600 | angular rate in deg/s, 1/16 deg/s steps printed to 0.01, `clip(0.5 + w/1600, 0, 1)` (±800 deg/s) |

The accelerometer is **gravity-free**: a still wrist (gyro < 3 deg/s for 2 s, 21,724 samples) reads |a| = 0.14 m/s²
whatever its orientation, and every workout's mean acceleration is ~0. That is the output of a fusion IMU
(the quantisation matches a BNO055's linear-acceleration and gyro registers). Clipping is real (≤ 2e-4 of samples at
0 or 1), matching the paper's "normalized to 0−1 with a threshold in both directions". The ±40 could also be ±4000 mg
(a 2 % scale difference); m/s² is the fusion IMU's default unit.

### 2.2 WHOOP → RecGym

WHOOP raw IMU (`activity_context.preprocess`): 100 Hz, accelerometer 1/4096 g per LSB **with gravity**, gyroscope
2000/32768 deg/s per LSB. Per contiguous run (gaps and clock resets split runs, nothing is filled):

1. gravity removed with a Madgwick IMU filter (6-axis, gain 0.1 — the reference implementation's default) at 100 Hz,
   initialised from the first 0.5 s mean acceleration; linear acceleration = (a − g_sensor) · 9.80665 m/s²;
2. linear acceleration and angular rate resampled 100 → 20 Hz with the package's anti-alias polyphase FIR
   (`resample_poly_nd(x, 1, 5)` = `scipy.signal.resample_poly`; RecGym itself point-sampled its sensor at 20 Hz);
3. mapped with the clipping above;
4. cut into 4 s windows (80 samples) on the **absolute 2 s grid** (window starts are even unix seconds, so a window's
   key never depends on how the worker chunked the day), fully inside the request, at least 2 s after a run start
   (filter settling; inside the worker's 3 s head context) and 1 s before its end (FIR support).

Domain gaps, recorded rather than hidden: Madgwick is not the BNO055's proprietary fusion (residual gravity leaks
during fast rotation; a still strap reads ~0.01 m/s²); the model saw point-sampled, quantised values.

### 2.3 Axes and placement

Axes pass through (`axis_mapping: identity_unverified`): RecGym's sensor axes relative to the wrist are undocumented
and the WHOOP axis convention is itself unverified (`docs/model-integration/sensor-families.md`). §8 tried seven other
proper rotations; none helps. The model was trained on a **wrist**; the owner wears the strap on the **upper arm**
(`placement_unsupported`). The publish function records the declared placement and `placement_supported` with every
window.

## 3. Golden and unit tests (`tests/recgym/`, 48 tests)

- `make_golden.py` runs **upstream's own files** (copied out of the clone, sha256-checked, `python -I`, isolated venv)
  on twelve real RecGym test windows (one per class) and two seeded inputs → `fixtures/recgym/golden_upstream.json`.
  The port's logits equal upstream's within **7.6e-6** (`|logit|` reaches 62, where a float32 ulp is 3.8e-6; the only
  difference is NNPACK, which the port disables like the other activity children: with it on the difference is 0).
  The scaler's `transform` equals sklearn's exactly (0.0) and round-trips.
- Weight-free: vendored files byte for byte, architecture keys/shapes, class order, pins and verification, scaler
  provenance and refusals, units, gravity removal (any orientation; a rotating strap), the resampler (= scipy; a 17 Hz
  tone removed), the grid and margins, gaps, digests, determinism, chunk boundaries, the serve protocol with a stand-in
  model, a live process without a checkpoint, and import isolation (HART never imports recgym; recgym imports no scipy,
  pandas, scikit-learn, Inertia or ElderNet).
- Run: `RECGYM_WEIGHTS_PATH=<checkpoint> python -m pytest -o addopts="" -q tests/recgym` (the four golden tests skip
  without it). Passes on numpy 1.26.4 / Python 3.11 and numpy 2.2.6 / Python 3.12 (the droplet's venv).

## 4. Serve protocol (`python -m activity_context.recgym.serve`)

Line-delimited JSON, `ping` / `infer` / `shutdown`, SIGALRM timeout, 12 MiB response cap — `eldernet.serve`'s framing.
`infer` takes the HART-identical `run` (100 Hz, `[ax..gz]`, g / deg/s, `columns_b64`, ≤ 3 s head/tail) and answers
`exercise-windows-1`: identity (`model_id`, `model_version`, `weights_sha256`, `upstream_commit`,
`preprocessing_version`, `scaler_version`, `scaler_sha256`, `classes`, `null_class`, `trained_placement: wrist`,
`axis_mapping`, `window_s 4`, `hop_s 2`, `rate_hz 20`) and `windows: [{s, e, p[12], input_sha256}]`, plus
`n_dropped_nonfinite`. `ping` adds `model_available`, `model_status` (`recgym_loaded` | `recgym_unavailable`) and the
measured `loaded` map (code, checkpoint and scaler digests, threads; all strings). Errors: `malformed`,
`model_missing`, `weights_mismatch`, `timeout`, `internal`, `output_too_large`.

## 5. Worker stage (`Tools/CloudWorker/.../ActivityExerciseWindows.swift`)

`FRWHOOP_EXERCISE_ENABLED` (off by default), `FRWHOOP_EXERCISE_WEIGHTS_PATH` (required), `FRWHOOP_EXERCISE_MODE`
(only `shadow`; anything else keeps it off), pins `FRWHOOP_EXERCISE_WEIGHTS_SHA256` / `_MODEL_VERSION` (checked
against what the child measured it loaded), `_PYTHON`, `_TIMEOUT_SECONDS` (60, ≤ lease/3), `_JOB_BUDGET_SECONDS` (300),
`_THREADS` (1), `_RETENTION_DAYS` (14). Outside the readiness gate; per chunk after HART, Inertia and ElderNet; its own
lease renewal; every failure classified and counted, the HART payloads byte-identical whatever it does. Answers are
cached by request and measured identity, and a chunk whose windows a committed publish already carried is neither
asked nor sent again. The job's new chunks go to `publish_activity_exercise_windows` under a savepoint before the v1
publish, clipped to the job's UTC day, with `ActivityExpertAuthority.shadowOnly(.exerciseRecognition)`; chunk keys are
marked published only after the commit. Heartbeat: `exercise_*` counters, `recgym.*` identity, `recgym.mode shadow`.

## 6. Storage and release (`20261009160000_activity_exercise_windows.sql`)

One row per window, PK `(user_id, device_id, model_id, window_start)`: `window_s`, `model_version`,
`weights_sha256`, `scaler_version`, `preprocessing_version`, `placement` (declared at that instant, NULL undeclared),
`placement_supported`, `placement_reason` (`placement_unsupported` | `placement_unknown`), `top_class`, `top_p`,
`p_null`, `probs` (class → p, 4 decimals), `input_sha256` (the four raw seconds), `release_mode` (CHECK = shadow),
lineage `day`, `job_fingerprint`, `input_revision`, `result_revision`, `computed_at`. Owner select, service-only
writes through the fenced publish (lease + revision fence; authority block must be shadow / use none, through
`internal.activity_expert_release`; a chunk span is replaced as a whole; identical rows are not rewritten; placement
from `internal.placement_intervals_for_device_v1`). BRIN on `window_start`; `prune_activity_exercise_windows(keep_days,
max_rows)` (window time). ~0.6 KB per row, 43,200 rows per fully captured day. Release policy:
`ActivityExpertSelection.Channel.exerciseRecognition`, which no selection source carries (`use == .none` always).
Read: `GET /scores/exercise-windows?deviceId=&from=&to=[&limit=]` (owner and device from the credential, ≤ 1 day,
≤ 5,000 rows a page, `next_from`).

## 7. Resources

macOS (M-series), 1 thread, `python -m activity_context.resources --hours 2 -- -m activity_context.recgym.serve
--weights-path …`: load 0.9 s, RSS 197 MB after load, 338 MB after requests, peak 440 MB, ~0.86 s per one-hour chunk
(gravity filter ~0.4 s, model ~0.3 s for 1,800 windows). Not measured on the droplet.

## 8. Evaluation on the owner's data (2026-10-09)

Raw IMU sessions pulled read-only from the owner's phone (`RawImuSessions/activity-my-whoop`, 113,436 seconds,
10-06 12:00 → 10-09 13:00 PDT; capture was partial, ~1,200 s per hour, until 10-08 17:00), decoded with
`ImuSessionFileStore`'s NOOPIMU2 format, run through this package exactly as the worker chunks it. Spans (PDT): gym
10-06 21:00–23:30, 10-07 21:00–00:30, 10-08 21:00–00:30 (9,702 windows); non-gym daytime 10-06 12–18, 10-07 9–18,
10-08 11–20:30 (18,838); sleep 10-09 01:30–06:30 (8,944). No workout or lift set was logged on the phone, so "gym" is
the owner's stated evenings (rest between sets included), not per-set labels.

| | gym | day | sleep |
| --- | --- | --- | --- |
| p_exercise = 1 − P(Null): p10 / p25 / p50 / p75 / p90 | 0 / 0 / 0.000 / 0.129 / 0.977 | 0 / 0 / 0.000 / 0.014 / 0.787 | 0 / 0 / 0 / 0 / 0 |
| windows with top class ≠ Null | 19.5 % | 13.3 % | 1.5 % |
| top classes | Null 80.5 %, BenchPress 6.2 %, Adductor 3.9 %, Walking 3.5 %, LegCurl 2.2 %, Running 1.6 %, LegPress 1.4 % | Null 86.7 %, **Adductor 10.7 %**, LegCurl 2.3 % | Null 98.5 %, Adductor 1.2 % |

- **p_exercise does not separate the gym from daytime**: AUC 0.53 (gym vs sleep 0.70). The daytime "exercise" is
  almost all **Adductor / LegCurl on near-still windows** (the machine classes where RecGym's wrist rests on a
  handle): still daytime windows (gyro RMS < 5 deg/s) score higher than still gym windows (mean p_exercise 0.18 vs 0.12).
- The upper-body / cardio classes are specific but insensitive: P(BenchPress, ArmCurl, Squat, Running, Walking, Riding,
  RopeSkipping, StairClimber) ≥ 0.5 in 12.3 % of gym windows, 0.3 % of daytime, 0 % of sleep (AUC 0.64; 5-min blocks
  0.80). Within the gym it rises with heart rate (mean p_exercise 0.09 at HR < 90, 0.17 at 90–105, 0.38 at 105–120,
  0.64 at ≥ 120).
- **Movement intensity alone does as well or better**: at the same 0.3 % daytime false-positive rate, the gravity-free
  acceleration RMS (≥ 3.0 m/s²) flags 15.3 % of gym windows vs the model's 12.6 %; 5-min-block AUC is 0.83 for gyro RMS
  vs 0.80 for the model's upper+cardio score.
- No axis assignment rescues it: seven other proper rotations of the strap frame give p_exercise AUC 0.50–0.57 and a
  lower upper+cardio hit rate at 0.3 % FPR (0.4–12 %) than the identity.

**Verdict:** on an upper-arm strap this head is not a usable exercise detector (it carries no information beyond
movement intensity, and its machine classes fire on stillness). Keep it shadow; do not feed it to the exercise-session
rule or the Watchdog. It may become useful for a wrist-worn strap (placement `wrist`, `placement_supported` true),
which the rows let anyone check later.

## 9. Not done / open

- Droplet resource measurement and the deploy itself (operator; `deploy/README.md` "RecGym exercise head").
- Placement is resolved when a chunk is published; a later placement correction reaches a window only when its chunk
  is republished (a changed chunk, a new day, or a worker restart).
- Owner decisions: whether to enable the shadow at all given §8 (it costs ~0.3–0.4 GB RSS and up to ~26 MB/day of
  rows per fully captured day before retention); the retention (14 days); whether to evaluate it on a wrist-worn week.
