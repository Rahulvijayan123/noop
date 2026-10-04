# EnergyModels — motion evidence for the energy estimator

Raw wrist IMU in, one JSON record per minute out. The two models here are **inputs** to the Swift fusion in
`Packages/StrandAnalytics/Sources/StrandAnalytics/Energy/`; the weighing against heart rate, activity context
and priors happens there, never here.

```
raw accelerometer (+ gyroscope) ──energy-evidence──▶ energy-motion-evidence-v1 JSON ──▶ MotionEvidenceDocument (Swift)
                                     │                                                       │
                              WristMET (numpy)  +  wrist CNN (numpy)                MetabolicEstimator: activity-aware fusion
```

## What each model is, honestly

| | WristMET | Wrist CNN |
| --- | --- | --- |
| Role | primary motion-based MET estimator | supporting evidence only |
| Source | Wei et al., *Sci Rep* 2025; code MIT, data CC BY 4.0 (Zenodo 14858226) | Nawaratne et al., *J Sports Sci* 2021; upstream repo has **no licence** |
| Weights | **retrained here** from the public code and data; the authors publish no weights | fetched from the upstream repo at a pinned commit, sha256-verified, **never committed** |
| Input | 60 s, 20 Hz, accelerometer **and gyroscope** + age, sex, weight, height | 60 s, 100 Hz, accelerometer only |
| Label it learned | indirect calorimetry (lab, 26 adults with obesity) | waist-ActiGraph-derived expenditure, not calorimetry |
| Accuracy | **did not reproduce the paper**: leave-one-participant-out 60 s RMSE 0.76 MET (paper 0.28); 0.32 on sedentary windows, 1.31 on non-sedentary ones | reproduces its own proxy labels to 0.74 MET RMSE on the public sample; error against true expenditure is larger |
| Out-of-distribution | `ood` (signal) and `demog_ood` (age/BMI/sex vs the cohort) per minute | `ood` per minute (a data-quality gate; not calibrated against error) |

What this means for the estimate, all of it enforced in Swift: WristMET's sedentary call is trusted tightly and
its regressor loosely (`EnergyConfig.wristMETSigmaSedentary/Active`, kept equal to the manifest by
`tests/test_evidence.py`); a wearer outside the cohort (e.g. young and lean — `ood_demographic` 0.82 for a 22 y,
70 kg, 175 cm example, see `ood.out_of_cohort_example` in the manifest) widens it further; the CNN is never
tighter than WristMET's sedentary call.

Details and numbers: `artifacts/wristmet/manifest.json` (`loso`, `ood`, `limitations`),
`artifacts/wristmet/NOTICE.md`, `energy_models/wrist_cnn/README.md`, `artifacts/wrist_cnn/NOTICE.md`.

## Run it

Inference needs numpy only (`numpy==2.2.6`).

```bash
python3.11 -m venv ~/venvs/energy-models && ~/venvs/energy-models/bin/pip install -e '.[dev]'

# CNN weights (optional): downloads the pinned upstream files, verifies sha256, converts. Not committed.
scripts/fetch_wrist_cnn.sh

energy-evidence --imu day.npz --profile profile.json --out evidence.json
```

* `--imu` — `.npz` with `t_ms` (unix epoch milliseconds), `acc` `[M,3]` (g, gravity included) and optional `gyr`
  `[M,3]` (deg/s); or a `.csv` with the header `t_ms,ax,ay,az[,gx,gy,gz]`. Other units: `--acc-unit m/s2`,
  `--gyr-unit rad/s`. An acceleration that is plainly in the wrong unit is refused.
* `--profile` — `{"age": 35, "sex": "male", "weight_kg": 70, "height_cm": 175, "wrist": "left"}`. These feed
  WristMET's regressor and are **not** written to the output (only `demog_ood` is).
* `--cnn auto|on|off` — `auto` (default) uses the CNN if its weights are present and says so if not.
* `--cnn-policy active|all` — which minutes the CNN runs on (below).
* `--axis-map file.json` — `{"wristmet": {"acc_source": [..], "acc_sign": [..], "gyr_source": [..], "gyr_sign": [..]}, "cnn": [[3x3]]}`.

## What it does to the signal

* One record per wall-clock minute (`t` a multiple of 60), each window cut from that minute's own samples, so a
  dropout cannot shift later minutes off the estimator's grid.
* A minute is modelled only when its 60 s are covered without a gap above 500 ms. Anything else is skipped and
  counted in `provenance.counts`; nothing is interpolated across a hole.
* The models run independently on the same samples. The CNN is scheduled on minutes WristMET calls non-sedentary:
  its regression head reads ~1.40 MET on motionless input, so running it on rest minutes would add a small
  upward offset to the biggest block of the day for no information. Without a gyroscope WristMET cannot run and
  the CNN covers every minute that is not motionless.
* Model ids pin the weights: `wristmet-v1-<artifact sha256 prefix>`, `wrist-cnn-<upstream commit prefix>`.

## Limits you should know before using the numbers

* **The strap's axes are assumed to equal the training watch's** (`AxisMap` identity). Nothing here verifies
  that; check your strap against the measured postures in `energy_models/wristmet/preprocess.py` and pass a map.
* WristMET was trained on the dominant wrist; a strap is usually on the other one (`"wrist": "left"` mirrors).
* Free-living behaviour, younger or leaner wearers and non-dominant-wrist wear are outside WristMET's training
  distribution. The random forest cannot predict above the 7.6 MET it saw.
* **Days recorded before raw IMU was captured have no motion evidence at all.** The estimator then runs on
  heart rate, step counter and activity context, with lower confidence — it does not guess.
* Research use only; not a medical device.

## Rebuild and test

```bash
python -m pytest                                   # numpy-only environment: the pipeline tests skip themselves
python scripts/build_wristmet.py --research-dir …  # rebuild the WristMET artifact (needs requirements-wristmet-build.txt)
scripts/fetch_wrist_cnn.sh --check                 # verify the CNN weights on disk
```

`tests/test_evidence.py` also decodes-by-contract the JSON this package writes
(`tests/fixtures/energy_motion_evidence_v1.example.json`) from Swift (`MotionEvidenceContractTests`); regenerate
it after an intentional format change with `UPDATE_FIXTURES=1 python -m pytest tests/test_evidence.py`.
`tests/fixtures/wristmet_golden.json` holds six 60 s windows from the public CC BY 4.0 dataset (attributed in
`artifacts/wristmet/NOTICE.md`); delete it and the tests that need it skip.
