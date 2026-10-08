# Spec 03 pretrained additions: eligibility

Audit date 2026-10-08 (UTC). Branch `feat/spec03-pretrained-models-20261007` at `dab2124f3`. Machine-readable
copy: [eligibility.json](eligibility.json).

Every production check was read-only: the `frwhoop-worker-2` Droplet and the production database. Only
aggregate counts were taken from the database. Nothing was trained, calibrated or fine-tuned. Downloads are
outside git under `research/spec03-artifacts/` (see [Artifacts](#artifacts)). "Owner" is the project owner's
account; "beta tester" is any other account. No account ids appear here.

## Decisions

| # | Candidate | Decision | Why |
|---|---|---|---|
| 1 | **ActiNet native classifier** (upstream default `walmsley`: sleep / sedentary / light / MVPA) | **Admitted for adapter work, shadow only. Activation deferred.** | No Nara bundle has this label space or output type. Complete 30-s, 100 Hz windows in g exist. Parity is not yet shown (motion agent). Owner licence decision is open. |
| 2 | **wav2sleep**, PPG only | **Deferred entirely.** The checkpoint identity is verified. Do not register or enable a provider. | Every production PPG second lacks its anchor. The Spec 01 transport is not built. No overnight waveform exists. No PPG+PSG evaluation set exists. |
| 3 | **ActiTect / RBDisco** | **Deferred entirely.** The assets are acquired and verified. | No complete raw-accelerometer night exists. Upstream resampling would interpolate the part-time gaps. |
| 4 | **Pulsewatch** | **Deferred entirely.** | The checkpoint needs a Google sign-in. The 0.5–20 Hz band cannot be reproduced from 24 Hz data. PPG and ACC were never captured together. |
| 5 | Pulse-PPG / PaPaGei / AnyPPG / SIGMA-PPG | **None found.** Nothing to keep or retire. | No file, package, unit or source reference on the Droplet or in the repository. |

Only candidate 1 goes forward. It produces a separate trained output (labels). It does not replace canonical
sleep staging, and no published activity document consumes it.

## Gate table

Status is `pass`, `fail` or `unknown`. Paths are repository-relative unless they start with `research/` (the
project folder, outside git) or `host:` (the Droplet).

| Candidate | Gate item | Status | Evidence |
|---|---|---|---|
| ActiNet | No already-working equivalent trained Nara head bundle | **pass** (no equivalent exists) | Deployed bundle `shadow-ncsa-primary-actukb` (bundle_sha256 `aba9a811…`) has posture/locomotion/arm/transition heads in Nara's label space plus `movement_intensity`. That head is a 1-output sigmoid regression of `clip(ln MET/ln 12,0,1)` (INERTIA1.md:204-211). It is not in `test_gate.json`, and the decoder only logs it (ActivityContextMotionHeadsFusion.swift:23; INERTIA1.md:390-391). No bundle has the Walmsley label space. The `c24` encoder is the Willetts backbone (actinet.py:41-49). |
| ActiNet | Suitable raw accelerometer windows (window level) | **pass** | Raw IMU arrives as NPB1 `rawImuSession`: 600 i16 per second, 100 Hz, axis-major (Npb1ImuDecoder.swift:10-16). The scale is 1/4096 g (preprocess.py:47). Runs split at gaps > 1 s and are never filled (preprocess.py:18-24; ActivityLane.swift:13-21). Production holds about 2,400 complete non-overlapping 30-s windows (2026-10-05 to 10-08, from the owner and two beta testers; one tester contributed 19). |
| ActiNet | Contiguous runs for the documented temporal processing (HMM, sleep correction, daily summaries) | **fail** | Part-time capture is on by default: 60 s in every 180 s (ActivityImuCapture.swift:31-37). The median run is 52–56 s and the median gap 127 s. The longest overnight run is 554 s. Upstream Viterbi runs across gaps, then `restore_labels_after_gaps` puts back the raw label on the first epoch after each gap. With 1–2 epochs per run, the HMM either does nothing or smooths across 2-minute gaps, so it cannot be applied faithfully. Do not use daily imputation. |
| ActiNet | Frozen classifier plus original preprocessing reproduces upstream output | **unknown** | The motion agent owns this check. The artifact is `ssl-ukb-c24-rw-30s-20260128.joblib.lzma`: 40,902,237 B, sha256 `07dfd748…`, md5 `a829041b…`. That md5 matches actinet 0.7.2 `__classifiers__["walmsley"]`. |
| ActiNet | Licence fits the intended use (owner decision) | **unknown** | Upstream is the Oxford **Academic Use Licence**, not CC BY-NC 4.0. Evidence: actinet `LICENSE.md` (sha256 `9a4f1846…`, identical in sdists 0.5.2–0.7.2) clause 1.1(b), and ssl-wearables v1.0.0 `LICENSE.md` (blob `64ed9bef…`). NOTICE.md:347 and registry.py:37 say CC BY-NC 4.0. |
| wav2sleep | Spec 01 PPG transport fixed | **fail** | The production wire carries no `baseCode`, so every v26 second is withheld `missing_ppg_anchor` (SensorBiomarkerInputs.swift:18-22, 438-443; docs/sensor-biomarkers/validation.md:147-150). The Spec 01 branch has contract text only (`ff143411e`). Its `spec01/ppg-transport-20261007` worktree has no changes. |
| wav2sleep | Contiguous overnight waveform with verified clock and quality | **fail** | 429 `ppgWaveformSample` objects from 5 users, 2026-08-13 to 2026-09-22. Nothing has arrived since. They hold at most 2.05 h of record-seconds per day, scattered across objects that span up to 41 h. All are anchorless. v26 appears only in strap-chosen stretches of the night (PpgHr.swift:3-9). `sensor_biomarker_days` has no PPG family on any day. |
| wav2sleep | CPU and memory budget | **pass** (headroom; per-night cost not measured) | 4 vCPU, 7,941 MiB RAM, no swap. The daily mean CPU is 2.0–20.6% busy (sar, 10-04 to 10-07); the peak 10-minute average was 81% on 10-07. Available memory never fell below 3,118,808 kB (10-07). The sidecar uses 835 MB of its 3 GiB `MemoryMax`, with a CPUQuota of 150%. |
| wav2sleep | An actual sleep-stage evaluation set with PPG | **fail** | Nothing local has a PPG waveform and PSG labels. `research/psg/sleep-accel-1.0.0` (on External SSD; the Untitled copy is empty dirs) has Apple Watch HR, ~50 Hz acceleration and PSG labels for 31 subjects, but no PPG. `har-datasets/DOWNLOADS.md` lists none. |
| wav2sleep | HF source identity matches the manifest pin | **pass** (content), with a fix needed | The `state_dict.pth` LFS sha256 `ea6fb441…` and 9,666,562 B match the HF tree at `main` (`8b6e46ab…`), last changed in `18fc32f0…`. `config.yaml` is 749 B, git blob `f5a5bcc1…`. The manifest `revision` `278e3046…` is **not an HF revision** (the HF API says "Invalid rev id"). It is the GitHub code head. The artifact URLs use the mutable `resolve/main` (manifest.json:140, 155, 163). |
| ActiTect | Complete, compatible raw accelerometer nights | **fail** | 0 complete nights. Overnight raw IMU covers 28–30% of 22:00–08:00 on 3 nights (2 users), with runs of at most 554 s. `resample_df_uniform` reindexes the whole span and fills it with `interpolate(method='nearest')` (processing/resampling.py), so any gap would be filled. |
| ActiTect | Units, placement and preprocessing checked | **pass** (on paper) | Upstream wants `time`, `x,y,z` in g (README). It was trained on Axivity AX6 at 100 Hz, ±8 g, on the wrist, over 6–7 nights per recording (paper). WHOOP is 100 Hz, ±8 g (i16 at 4096 LSB/g), in g, on the wrist. The axis frame is not mapped, and the strap can be worn on the bicep. Preprocessing: 0.8–20 Hz Butterworth, calibration, non-wear detection, HDCZA SPTW (≥3 h wear per noon-to-noon day). |
| ActiTect | Released model assets acquired and verified | **pass** | Four `.joblib` files at `a088d8e9…`. Size, sha256 and git blob all match the published tree (see [Artifacts](#artifacts)). A static pickle scan shows `CustomCalibratedClassifierCV(XGBClassifier, sigmoid)`. They were not loaded, because unpickling executes code. |
| Pulsewatch | Exact checkpoint obtained | **fail** (blocked: needs owner action) | The expected file is `train_RNN_GRU_20240712_fold_1_epoch_0033_val_loss_0.1207.pt` in Drive folder `TestRNNGRU_HR_ACC_rescaleHR` (utils/my_pathdef.py:175-181). Every Drive folder link answers HTTP 302 to `accounts.google.com/ServiceLogin`, and `embeddedfolderview` returns 401. |
| Pulsewatch | Architecture, classes and preprocessing reproduced | **fail** (documented, not reproduced) | The code documents a bi-GRU with 3 classes (NSR / AF / PAC-PVC). Input is 4 × 1500 samples (30 s at 50 Hz): PPG, beat HR, ACC magnitude in m/s², rescaled HR. It cannot be reproduced without the checkpoint. |
| Pulsewatch | Synchronized PPG, HR and ACC | **fail** | No raw-IMU object overlaps any PPG object in time (0 of 1,076). The default IMU-only arm requests no optical collection (BLEManager.swift:2404-2409). Both streams stamp whole seconds. HR is the strap's 1 Hz stream, not per-sample beat HR. |
| Pulsewatch | Credible bandwidth and domain comparison | **fail** | WHOOP native rate is 24 Hz (Nyquist 12 Hz), and 41% of the 0.5–20 Hz band lies above that. After upsampling, the 12–20 Hz energy is 0–0.9% of the reference. What survives is imaging (r = 0.08 / −0.01 with the original). The peak upstroke slope falls about 30%. |
| Excluded | Running Pulse-PPG-type integration | **pass** (none present) | `git grep` finds nothing. On the host, nothing matches in /opt, /var/lib/frwhoop, /etc/systemd/system, the venv site-packages, or the sources of the inference, anomaly, metric-insight and worker trees. The sidecar's providers are `hrv.py` only. |

## 1. ActiNet

**What the worker runs** (`host:`, at 05:02 UTC):

- **Flags.** `FRWHOOP_INERTIA_ENABLED=1` and `FRWHOOP_INERTIA_MODE=candidate`.
  - `FRWHOOP_INERTIA_BUNDLE_DIR=/var/lib/frwhoop/inertia-bundles/shadow-ncsa-primary-actukb`
  - `FRWHOOP_INERTIA_BUNDLE_SHA256=aba9a811c32c04c58afca23955597bdcfdaece8c3e25ed62d629bf3e81468b63`
  - `FRWHOOP_INERTIA_CHECKPOINT=/var/lib/frwhoop/actinet-weights/ssl-wearables-harnet30-ukb-v1.0.0.pt`
  - `FRWHOOP_INERTIA_THREADS=2`
- **Process.** Child pid 431826 runs `activity_context.inertia.serve ... --expect-bundle-sha256 aba9a811…`. The
  journal logged "inertia candidate enabled" at 2026-10-07 23:27:20.
- **Bytes on disk.** The checkpoint sha256 is `28f8bcd7…`, which is pinned. The bundle `manifest.json` sha256
  is `59ced24f…`, identical to the local copy.
- **Not on the host.** Neither the `c24` (Willetts) weights nor any ActiNet classifier.

**Rows in production** (`activity_motion_heads_days`, 05:44 UTC). All rows come from bundle `shadow-ncsa-primary-actukb`, encoder kind `actinet`, tier
`candidate`:

| mode | account | rows | days | windows | OOD | candidate documents |
|---|---|---|---|---|---|---|
| candidate | owner | 2 | 10-07…10-08 | 3,807 | 414 | 2 |
| candidate | beta tester | 2 | 10-07…10-08 | 2,575 | 174 | 2 |
| shadow | owner | 1 | 10-07 | 986 | 75 | 0 |

Candidate documents are comparison-only and never published. Nothing in `supabase/functions` or the app reads
this table.

**Why no existing bundle is an equivalent.** The four ActiNet bundles in
`research/inertia-bundles/shadow-ncsa-{primary,ood}-act{c24,ukb}` are all sealed at the `candidate` tier. The
deployed one is `actukb`.

| | ActiNet `walmsley` (target) | `actukb` `movement_intensity` | `actukb` class heads |
|---|---|---|---|
| Output type | One label per 30-s epoch (argmax, then HMM Viterbi). Upstream publishes labels, not probabilities (`sslmodel.predict(output_logits=False)`). | Scalar regression in [0, 1] | Calibrated probabilities over supported classes |
| Label space | sleep, sedentary, light, moderate-vigorous (static scan of the artifact) | Proxy for log-MET; no sleep class (sleep MET 0.95 maps to 0) | posture(4), locomotion(8), arm(7), transition events(8) |
| Evaluation | Capture-24 is in-sample: the classifier was fitted on all of it. | Test MAE 0.085 (constant 0.137), R² 0.627, n = 96,146 public windows. Not in the test gate. | Final gate: mostly `abstain`. Strong: `vehicle_motion`, `seated_likely`. |
| Consumer | None yet (must be named before activation) | Logged only | Candidate comparison document only |

Cutting `movement_intensity` at MET 1.5 and 3.0 would be a new derived rule, not a trained classifier. It also
has no sleep class. The `c24` bundle's intensity head has R² −0.008 on Capture-24 test, which is in-sample for
that encoder. **Gate item 1 passes: no equivalent exists.**

The repository pins the wrong ActiNet artifact for this label space.
- Pinned: `ssl-ukb-c24-mw-30s-20260128.joblib.lzma` (sha256 `9034d6c9…`, md5 `59a9492b…` = `willetts`). Its
  labels are bicycling, mixed, sit-stand, sleep, vehicle and walking.
- Needed: the default `walmsley` file `ssl-ukb-c24-rw-30s-20260128.joblib.lzma`.

The motion agent found this, and I confirmed it with a static UTF-32 label scan of both files, without
unpickling.

**Raw IMU contract and coverage.**

- **Capture policy.**
  - Default mode is `partTime`: 60 s on at the start of every 180 s, aligned to the wall clock. Edges can land
    up to one 30-s tick late (ActivityImuCapture.swift:31-37). `continuous` is available but not the default;
    its battery cost is unmeasured (lines 10-12).
  - Lean raw capture is on by default (lines 43-50). The IMU-only arm requests no optical collection
    (BLEManager.swift:2404-2409). If that arm fails, the fallback shared raw start banks both raw optical (v20)
    and raw IMU (v21) (BLEManager.swift:2388-2391).
- **Format.** 100 Hz, six axes. Accelerometer 1/4096 g per LSB (±8 g); gyroscope 2000/32768 deg/s. Raw strap
  axis frame. Sample time is `ts + i/100`.
- **Storage.** NPB1 `rawImuSession` objects in B2, indexed in `object_manifests`.
- **Handoff.** The worker decodes each object and splits runs at gaps > 1 s. It sends `columns_b64` per run;
  head and tail boundary seconds never cross a gap (ActivityLane.swift:1946-1960).
- **Coverage.** Measured from HART window starts in `activity_encoder_windows` (4-s windows, 2-s hop):

| day (UTC) | account | runs | covered h | median run s | longest s | non-overlapping 30-s windows |
|---|---|---|---|---|---|---|
| 10-05 | owner | 17 | 3.67 | 52 | 12,351 (16:43–20:09 local, daytime) | 428 |
| 10-06 | owner | 412 | 6.12 | 56 | 226 | 509 |
| 10-06 | beta tester A | 13 | 0.19 | 52 | 120 | 19 |
| 10-07 | owner | 429 | 8.06 | 56 | 2,868 | 722 |
| 10-07 | beta tester B | 462 | 6.61 | 54 | 168 | 528 |
| 10-08 (part) | owner / B | 87 / 93 | 1.26 / 1.35 | 52 / 54 | 228 / 82 | 92 / 108 |

Earlier raw IMU was negligible: 2,183 record-seconds across 2026-09-08, 09-09 and 09-16.

Over 22:00–08:00 local, coverage was 28–30% of the window on three nights. The longest overnight runs were 170,
96 and 554 s. No raw IMU night is complete in the database or locally; `research/user-night*` holds 1 Hz
streams only.

**What the adapter must respect** (from the upstream code and the methods page):

- **Windowing.** Upstream bins non-overlapping 30-s windows from the recording start
  (`resample("30s", origin="start")`). It keeps a window with more than 450 of 900 samples and pads it: wrap
  mode in the code, zero in the docs. For Nara, emit only complete windows inside a contiguous run, or mark
  padded windows and exclude them.
- **Whole-recording steps.** Calibration fits gain and offset to stationary periods gathered over the whole
  recording. Non-wear detection needs more than 90 minutes of stillness. Neither can be computed from 60-s bursts.
- **HMM.** Run it only inside contiguous runs, and record when it was skipped.
- **Imputation and sleep.** Never use the daily imputation as observed data. The ActiNet sleep label must not
  replace canonical staging.

**Evaluation data available.** Capture-24 is in-sample for this classifier.
- External sets: GOTOV, with COSMED-measured MET, and PAMAP2, with protocol MET. Use only their test splits
  for a head-to-head with `actukb`, because the Nara heads trained on their train splits. sleep-accel has PSG
  labels and covers sleep vs wake only.
- WHOOP references: 12 guided labels from one account and 40 stretch verdicts from two accounts. No intensity
  labels exist.

**Licence (owner decision).** Both upstreams are under the Oxford Academic Use Licence:
- actinet `LICENSE.md` on master, sha256 `9a4f1846…`.
- ssl-wearables v1.0.0 `LICENSE.md`. The ssl-wearables README limits use to academic research, excludes
  commercial use, and points commercial users to Oxford University Innovation.

Clause 1.1(b) of the actinet licence forbids using the software on behalf of a third party or "to provide a
service". Neither the actinet README, the readthedocs pages, the ssl-wearables README nor the sdists grant
separate weight terms. No "CC BY" text appears in any actinet or actipy sdist.

This is the same question as ElderNet's licence-scope note (ELDERNET.md:12-20): does an internal service on
beta testers' data qualify? It already applies today. The live `actukb` lane runs the ssl-wearables weights on
one beta tester's account (2 rows). ElderNet (`FRWHOOP_ELDERNET_ENABLED=1`, `MODE=candidate`) runs on one beta
tester's account (3 rows of `activity_gait_windows_days`). ELDERNET.md:17-19 says the lane should not be
switched on for other people's data until that decision is made. NOTICE.md:342-348 and registry.py:37 should
say Academic Use Licence, not CC BY-NC 4.0.

## 2. wav2sleep (PPG only)

The physiology agent has written a shadow adapter that is off by default and not registered
([WAV2SLEEP.md](WAV2SLEEP.md)). Under this result it must stay unregistered and disabled, and the manifest
entry stays `blocked_input`. The spec admits only candidates whose real inputs exist, so whether to keep that
code until the gates pass is the lead's call.

**Current manifest entry** (Tools/InferenceWorker/models/manifest.json:136-170):

```json
{"id": "wav2sleep", "kind": "model_checkpoint", "revision": "278e30463c8149c4e6899b8784da492fec695bd9",
 "revision_date": "2026-07-16", "source_url": "https://huggingface.co/joncarter/wav2sleep", "license": "MIT",
 "status": "blocked_input",
 "status_reason": "requires a raw ECG/PPG waveform at 1024 samples per 30 s epoch (34.133 Hz); the product stores only derived ppg_hr_samples (bpm, confidence) on the default path",
 "provider_id": "sleep_stage", "wired": false,
 "artifacts": [{"name": "state_dict.pth", "url": "https://huggingface.co/joncarter/wav2sleep/resolve/main/state_dict.pth",
                "size_bytes": 9666562, "sha256": "ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc"},
               {"name": "config.yaml", "url": "https://huggingface.co/joncarter/wav2sleep/resolve/main/config.yaml",
                "size_bytes": 749, "sha256": "b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509"}],
 "required_for_readiness": false}
```

The host's model root is the older revision `ffc93db27d79` (manifest sha256 `ffc93db2…`). Repo HEAD's
manifest is `8d776cc4…`. On the host, wav2sleep is `blocked_input` and unwired, and no wav2sleep bytes are
staged; only `sleepecg` is.

**Anchor behaviour.**
- The worker decodes NPB1 `ppgWaveformSample` records: 24 signed deltas per second at 24 Hz
  (SensorBiomarkerInputs.swift:52).
- It rebuilds absolute samples only when `baseCode` is present (`ppgWaveformAbsolute`, HistoricalStreams.swift:505).
  The wire never carries it, so every second is withheld `missing_ppg_anchor` (`__init__.py`:63 lists the
  reason).
- Old server deltas cannot be re-anchored (Spec 01 §3).

**Spec 01 progress** (read-only, 05:38 UTC). The branch adds `ff143411e`, which pins the segment members
`run_id`, `config.identity`, `clock.packet_timing_verified` and `clock.samples_per_second`. It changes
documentation only. The PPG transport worktree has no commits or edits yet. After the code lands, a phone
build, a receiver/worker deploy and re-uploads of recoverable local records are still needed.

**Capture and coverage.** v26 is strap-banked history. The strap writes it in some stretches of the night in
place of the v18 summary. Nara does not schedule it, so it is neither continuous nor a Nara duty cycle. Raw
optical (v20) is suppressed by lean capture. In production, `ppgWaveformSample` per day:

| days | users | record-seconds per day |
|---|---|---|
| 08-13, 08-15, 08-17, 09-09 | 1 | 5,000 each (spread over spans of ~41 h) |
| 09-11 … 09-22 (11 days) | 1–2 | 360–7,366 |
| after 09-22 | — | none |

`noop_ppg_hr_samples` has 0 rows.

**Domain caveat** for the physiology agent; this is not a gate. The model contract is 1024 samples per 30 s,
about 34.13 Hz (`settings.py` at `278e3046`, sha256 `69c6e4d7…`). That is above WHOOP's native 24 Hz, so the
resampled input holds nothing above 12 Hz. Keep the native rate explicit.

**Manifest fix to hand to Spec 01** (it owns manifest.json):
- Pin the artifact URLs to `resolve/18fc32f095f10c1f7a91a56298e7598d02c58529/…`; the bytes are identical at
  `8b6e46ab…`.
- Record `278e3046…` as the GitHub code revision, which is `main` on 2026-07-16.
- The first HF upload (`b0d9856c…`) had a different `state_dict.pth`: 11,899,656 B, sha256 `51605afc…`.

## 3. ActiTect / RBDisco

- **Source.** `bozeklab/actitect` @ `a088d8e97ac324c40755c8c28fa7a7227664c7f5` (2026-08-14). This is newer
  than tag `v1.0.0` (`736560cf…`).
- **Licence.** `LICENSE` (sha256 `929369ca…`):
  - Code is PolyForm Noncommercial 1.0.0, with its Distribution section changed to forbid any distribution.
  - Models are CC BY-NC-SA 4.0.
  - So no code or weights can enter the repository. Use the operator-fetch pattern from ElderNet.
- **Input contract.**
  - CSV with `time` in ISO8601 and `x,y,z` in g, or a `.cwa`/`.bin`/`.gt3x` file.
  - `actitect.rbdisco.predict(data, model='multiCenterCore', return_level='night'|'patient')`.
- **Preprocessing.** `config/default_preprocessing.yaml` (git blob `d878e729…`):
  - `resample_rate: infer`; bandpass from `highpass_hz: .8` to `lowpass_hz: 20`.
  - `calibrate`, `detect_nonwear` and `detect_sleep` are all on (HDCZA, `processing/sleep.py:20-31`).
  - Movement bouts use the threshold max(mean + std of |a| in the SPTW, 0.1) (`processing/movements.py`).
- **Feature order.** `build_aggregated_feature_list(order='dataloader')` gives 724 names. The 8 aggregations
  (mean, std, skew, kurt, mad, iqr, 10th, 90th percentile) form the outer loop over 88 local features. The 20
  global features follow (`rbdisco/configs/external_test.yaml`, blob `3f6e5861…`).
- **Model.** `joblib.load(...)['model2']` holds (estimator, hps with `selected_features`, processing, thresholds,
  meta). The robust scaler is applied, then the selected features, then `predict_proba[:,1]`, then the night
  threshold.
- **Night-level aggregation.** `aggregation.py`: mean probability > 0.5, majority vote ≥ n/2 nights, and the
  ensemble rule from `meta`. The evaluation configs use `min_patient_nights_eval: 4`.

**Nara comparison.** Rate, range and units match, and the wrist placement matches in principle. The input does
not: no night has complete raw IMU, and 1-in-3 capture would be nearest-interpolated across 2-minute gaps. HDCZA
takes its percentile threshold from each noon-to-noon day's distribution. The spec forbids interpolating these
gaps. **Deferred.** The model score is a research RBD-associated pattern score, not a REM event and not a
diagnosis.

**Descriptive motion summaries Nara already computes** (expose these first):

1. `daily.sleep_analytics_v1.movement` (SleepAnalyticsMovement.swift; fields at SleepAnalyticsV1.swift:688-728).
   Built from the continuous 1 Hz gravity stream:
   - movement seconds, % and bout count, and bouts per eligible hour;
   - complete and censored immobility bouts, longest, median and p90;
   - `threshold_g`, `source_resolution: gravity_1hz_adjacent`.

   It is on `nara/main` (worker attach `0190b35ba`/`6636467be`, DayScoring.swift:1416-1442). Production does
   not carry it: 0 of the 13,879 snapshots computed in the last 7 days, because the live worker `10f5727…`
   does not contain it.
2. The `sensor_biomarker_days` `movement` family (ENMO 5-s epochs, low-movement bouts) and `oscillation` family
   (gyro 3–7 Hz power) (sensor_biomarkers/imu.py). They run in production (10 rows, 2026-10-05 to 10-08, both
   families `ok`), but only on the part-time raw IMU and per day, not joined to stages. The stage join is Spec 02 §4.

**Adapter brief, for when continuous overnight capture exists:**

- **Location.** `Tools/ActivityContext/activity_context/actitect/`, a separate serve child like ElderNet.
  Upstream code and weights are fetched by the operator to a pinned directory and verified by sha256 before
  `joblib.load`. Load them in an isolated venv (Python 3.9, xgboost 2.0.3 as the README recommends,
  scikit-learn per the pickle's `sklearn_version`).
- **Admission per night.** Accept a night only when the noon-to-noon day it belongs to is gap-free at 100 Hz:
  no gap > 1 s, and at least the HDCZA wear minimum. Refuse any gapped input before calling upstream, as
  `incomplete_raw_night`. Upstream would fill it.
- **Input conversion.** Accelerometer = the first 300 i16 of each NPB1 second × 1/4096 g, at `ts + i/100`.
  Drop the gyroscope. Write ISO8601 microsecond timestamps.
- **Reproduce upstream.** Use `actitect.api.process` and `compute_sleep_motor_features` with default settings.
  Preserve the 724-name dataloader order and the per-model `selected_features`. Keep night-level output:
  `proba_rbd`, the threshold and the model flavour. Aggregate to patient level only with ≥ 4 nights.
- **Parity fixture.** The release asset `example.cwa`: 337,117,184 B, published digest
  `sha256:4f7ad878d6c24abbc59bb5e10f9e77eb6a9546d7c8f1726bf2c2b73c1b4e650f`. It was not downloaded.
- **Release.** Shadow only, labelled research. A named consumer must exist before activation.

## 4. Pulsewatch

- **Source.** `Cassey2016/PulsewatchRelease` @ `82ed0412ef3dcb7f55c4fc5903b7e53a435ec4a6`, MIT.
- **Best model.** "PPG + HR + ACC + magHR", `data_dim='1D_PPG_HR_ACC_rescaleHR'` (pretrainedmodels/README.md
  model 12 = model 2; train/README.md:9-17).
- **Classes.** 3: NSR, AF and PAC/PVC (train/run_train_model_four_channels.py:23).
- **Network.** Bidirectional GRU, then dense layers (model/my_RNN_GRU_model.py:16-63).
- **Inputs.** `ppg_size = 1500`, 50 Hz (utils/my_dataloader.py:18, 175). Scaling (my_dataloader.py:1509-1548):

| channel | content | scaling |
|---|---|---|
| PPG | pre-filtered, 0.5–20 Hz band per the study | per-segment min-max |
| HR | per-sample beat HR | (HR − 30)/(220 − 30) |
| ACC | magnitude in m/s² (Samsung watch) | ÷ 20 |
| magHR | the same HR | per-segment min-max |

- **Outputs.** Window-level classes only: no beat-level ectopy, and no separate PAC and PVC counts.

**Bandwidth** (`_build-scratch/spec03-eligibility/pulsewatch_band.py`). The test signal is a deterministic
sharp-upstroke pulse at 75 bpm with harmonics to 20 Hz. It is band-limited to 0.5–20 Hz at 50 Hz, sampled at
24 Hz with anti-aliasing, then brought back to 50 Hz:

| upsampler | 12–20 Hz energy vs reference | correlation of its 12–20 Hz part with the original | NRMSE | peak upstroke slope |
|---|---|---|---|---|
| polyphase 25/12 | 0.9% | 0.08 | 0.16 | 0.70 × |
| FFT | 0.0% | — | 0.16 | 0.70 × |
| linear | 11.9% (imaging) | −0.01 | 0.20 | 0.67 × |

41% of the passband lies above WHOOP's Nyquist frequency. Upsampling adds no information. HR would have to be
re-derived per beat from anchored PPG, which does not exist. ACC was never co-captured. **Deferred.** A
faithful adaptation would need a different checkpoint or retraining, which is out of scope.

## 5. Excluded list

No Pulse-PPG, PaPaGei, AnyPPG or SIGMA-PPG integration exists.
- **Repository.** `git grep` finds nothing.
- **Host.** No file names, site-packages or source references; no systemd unit. The inference sidecar's
  editable install points at `/opt/noop/Tools/InferenceWorker/src`, whose providers are `hrv.py` only.

There is no trained head, consumer, flag or table to inventory. Recommendation: keep excluded; no retirement
work.

## Remaining gates and who clears them

| Gate | Candidates | Cleared by |
|---|---|---|
| Upstream parity of the frozen `walmsley` classifier plus original preprocessing, on fixtures and real windows | ActiNet | Motion agent |
| A named downstream consumer and a shadow store for 4-class labels (labels, not probabilities) | ActiNet | Lead and motion agent (Spec 01 authority rules) |
| Out-of-sample comparison: GOTOV/PAMAP2 test splits, sleep-accel sleep vs wake, any WHOOP labels; final features, coverage and runtime against `actukb` | ActiNet | Motion agent; more WHOOP labels from the owner |
| Licence scope of the Oxford Academic Use Licence for a service on beta testers' data. It covers ActiNet and ssl-wearables, which is already live in `actukb`, and also ElderNet. Then correct NOTICE.md and registry.py. | ActiNet (and the live lanes) | **Owner**, or a licence from Oxford University Innovation |
| Anchored, versioned PPG transport (codec, receiver, worker), then phone build, deploy and re-upload of recoverable local records | wav2sleep, Pulsewatch | Spec 01 PPG transport, then owner deploy |
| Contiguous overnight PPG with verified packet timing and quality | wav2sleep | Capture policy (owner); v26 is strap-driven |
| A PPG + PSG sleep-stage evaluation set | wav2sleep | **Owner**. None is local; the usual sources (NSRR, PhysioNet credentialed) need registration or a data-use agreement, which was not attempted. |
| Manifest URLs pinned to an HF revision; code revision recorded separately | wav2sleep | Spec 01 (manifest owner) |
| Complete raw IMU nights (continuous overnight capture; battery cost unmeasured) | ActiTect | Capture policy (**owner**) |
| Access to the Pulsewatch Google Drive folder (sign-in) | Pulsewatch | **Owner** (or the authors) |
| ≥ 50 Hz PPG with a 0.5–20 Hz band, plus synchronized ACC | Pulsewatch | Not achievable from WHOOP's native 24 Hz without retraining |

## Artifacts

All of these are outside git under `research/spec03-artifacts/` on the Untitled volume. They are treated as
untrusted data: nothing was executed from them, and Python reads used `python -I` from the scratch directory.

Fetched in this audit:

| artifact | URL | bytes | sha256 | local path |
|---|---|---|---|---|
| actitect source @ a088d8e9 | https://codeload.github.com/bozeklab/actitect/tar.gz/a088d8e97ac324c40755c8c28fa7a7227664c7f5 | 4,904,780 | `c89d42e670e5d3e065b93aefc15348a49c10e9e36827bb7bcce252af21a513ba` | `actitect/source-a088d8e97ac3/` (+ `extracted/`) |
| ↳ `multiCenterCore.joblib` | (in tarball) | 1,146,694 | `408433f2fe53b5fe947394a388c6274306116d09b9c86f098b317abd5c79d763` | git blob `c6c1d5bd…` = published tree |
| ↳ `multiCenterExtended.joblib` | (in tarball) | 929,286 | `8cb1be61fcfd671060f870adc5d8da61b485b64ba0ca0da57470987fe57356c4` | git blob `85ceb445…` = published tree |
| ↳ `singleCenterCore.joblib` | (in tarball) | 845,686 | `3c407f7235c09abd952a36448a103657fecb3c9543133382fdbcbb27c0ae189a` | git blob `595e65fc…` = published tree |
| ↳ `singleCenterExtended.joblib` | (in tarball) | 966,550 | `9fbc96781eb5b9043bfbc5b3a1de203f415de82bc736baa648fab54cb5f64ae4` | git blob `1453eb17…` = published tree |
| actitect LICENSE | https://raw.githubusercontent.com/bozeklab/actitect/a088d8e97ac324c40755c8c28fa7a7227664c7f5/LICENSE | 4,465 | `929369ca02e97ade77843a5ab6fe874d1f0afa65916fd2d96979d73eaa5304c3` | `actitect/eligibility-LICENSE-a088d8e97ac3/` |
| PulsewatchRelease source @ 82ed0412 | https://codeload.github.com/Cassey2016/PulsewatchRelease/tar.gz/82ed0412ef3dcb7f55c4fc5903b7e53a435ec4a6 | 4,110,976 | `553896be9c5a5842b7b42794d9725214f43708238885899ea339ad6292b39a95` | `pulsewatch/source-82ed0412ef3d/` (+ `extracted/`) |
| actinet LICENSE.md (master) | https://raw.githubusercontent.com/OxWearables/actinet/master/LICENSE.md | 6,176 | `9a4f1846fcf3aaa94575f0b01c3ec9ad901d1c1b2d8fe48fb9e12ebe88e9ecf8` | `actinet/eligibility-actinet-LICENSE-master/` |
| ssl-wearables README @ v1.0.0 | https://raw.githubusercontent.com/OxWearables/ssl-wearables/v1.0.0/README.md | 6,890 | `1323fc0640e30e239bd718de5526f893424fe801e2964fa18d8be5b09bd60c8c` | `actinet/eligibility-ssl-wearables-README-v1.0.0/` |
| wav2sleep settings.py @ 278e3046 | https://raw.githubusercontent.com/joncarter1/wav2sleep/278e30463c8149c4e6899b8784da492fec695bd9/src/wav2sleep/settings.py | 1,817 | `69c6e4d78a283a6bcf066b9c877ea2a13411be857a48d38042de434e459b28e6` | `wav2sleep/eligibility-settings-py-278e3046/` |

Verified read-only, downloaded by the sibling agents:

| artifact | bytes | sha256 | published hash |
|---|---|---|---|
| `ssl-ukb-c24-rw-30s-20260128.joblib.lzma` (walmsley) | 40,902,237 | `07dfd7482350dc30f0d69a4d59216caf0835bcca2d71d8e10a1243c8f7697fba` | md5 `a829041ba84b18084b4b2897fb1b36a6` (actinet 0.7.2) ✓ |
| `ssl-ukb-c24-mw-30s-20260128.joblib.lzma` (willetts, repo pin) | 40,905,601 | `9034d6c944f6af005b1387c0774e559ae24722d367366c843669d6375cf24b4a` | md5 `59a9492b50ee922c7a31f88888c5f14b` ✓ |
| wav2sleep `state_dict.pth` | 9,666,562 | `ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc` | HF LFS oid at `18fc32f0`/`main` ✓ |
| wav2sleep `config.yaml` | 749 | `b92f4e26f3290f5207b53be343d82a4e338968b54782718f13429e800f114509` | git blob `f5a5bcc1…` = HF tree ✓ |
| host `ssl-wearables-harnet30-ukb-v1.0.0.pt` | 41,966,691 | `28f8bcd719735496588eefb7f80c83209576aca3068fa61e9eae9874278e73f8` | repo pin ✓ |
| `shadow-ncsa-primary-actukb` (host and External SSD) | — | manifest `59ced24f…`; bundle_sha256 `aba9a811…` | files match manifest ✓ |

Not fetched:
- **Pulsewatch checkpoints.** Blocked: they need a Google sign-in. Root folder
  https://drive.google.com/drive/folders/1HubliJ6l6fQP3BpHVmC7KvGQVlVfFZP-, model folder
  https://drive.google.com/drive/folders/107pCHkm7K8vcmIlLU5XHABjcIuMnu3vT.
- **actitect `example.cwa`.** Not needed yet.

## Incidental findings

- **The documented read-only DB connection is not read-only.** The Supabase session pooler ignores `PGOPTIONS`:
  `show default_transaction_read_only` returned `off`. This audit set it with
  `set default_transaction_read_only = on` as the first statement of every session.
- **BACKEND.md is out of date.** docs/BACKEND.md:777-779 says candidate decodes run only for `inertia1`. The
  code and migration `20261007100000` also accept `actinet`.
- **Worker log noise.** The worker logs a `40001` serialization failure in `scoring_legacy_claim_one` about every
  15 s (journal, 2026-10-08). This is outside this spec.
