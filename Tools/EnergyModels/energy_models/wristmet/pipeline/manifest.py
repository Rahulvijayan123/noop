"""manifest.json and NOTICE.md for the WristMET artifact (build time)."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

from .. import ood as O
from . import export as E
from .dataset import WindowDataset, met_class

SCHEMA = "nara.wristmet.manifest/1"

MIT_LICENSE = """MIT License

Copyright (c) 2025 The HABits Lab

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

PIPELINE_DECISIONS = [
    "Training data: Zenodo record 14858226 ('Phase 2 - Data.zip', md5 1840803700111c0a1871e9af3eacc9be, CC BY 4.0): 26 participants (P1000, P1002-P1026). The paper analyses 27; P1001 is not in the public record.",
    "Wrist streams: the shipped 'Original' accelerometer/gyroscope chunk CSVs are re-sampled with a vectorised replica of sort_resample_organize.resample (grid t0 + k*50 ms, first sample copied, slope/intercept linear interpolation, no gap limit); the replica reproduces the shipped 'Resampled' CSVs exactly for all 26 participants and both sensors (build report). Chunks used: UTC date equal to, or the day after, the MetCart start date.",
    "Reference METs: MetCart text files parsed as in-lab.py (lines whose stripped length is 72 or 80; time = chars [:8]; METs = chars [21:24], so values >= 10 METs would be mis-parsed; dates from the hard-coded met_cart_dic, in-lab.py:34); local times converted with America/Chicago.",
    "Segments: activity-log rows with Include == 1 (columns located by header name). Windows: int((stop - start).seconds / W) back-to-back non-overlapping windows from the start time; the first 60/W*2 - 1 windows of each segment are skipped (1 at W=60, 7 at W=15; in-lab.py:271-321). The paper's text (50% overlap, first two minutes skipped, Butterworth filter) differs from the code; the code is reproduced. Result: 2,189 windows at 60 s (the paper's abstract count) and 7,112 at 15 s.",
    "Window MET = round(mean(MetCart METs inside the window), 3) with numpy rounding; values below 1.0 are set to 1.0; windows without MetCart rows keep NaN (3 windows at 60 s, dropped from the metrics like the upstream dropna).",
    "Class label = activity name: sedentary (label 0) for the upstream sedentary list (including 'Rest'), everything else non-sedentary (label 1). Reporting classes use the measured MET: <1.5 sedentary, 1.5-<3 light, >=3 moderate/vigorous (notebook set_intensity).",
    "Classifier features: median, mean, max, min, range, std (ddof=0), rms of the six channels (gyr_xyz, acc_xyz), stat-major (helper_preprocess.py:158-175). Regressor features: gender, age, BMI, Intensity (Freq), gender_age, gender_BMI, age_BMI, age_gender_BMI, Intensity (RMSSD_l1) (in-lab.py:491).",
    "Intensity (RMSSD_l1) (in-lab.py:165-197): per-axis L1 normalisation then sqrt(sum(dx^2+dy^2+dz^2)/N). Intensity (Freq) (in-lab.py:199-227): fs hard-coded to 100 although data are 20 Hz (so 5x the physical frequency), acc magnitude of samples 1..N-1, one-sided FFT bins [:n//2] including DC, second-largest magnitude, no band-pass filter although the paper describes one. All reproduced bit for bit (checked against a literal copy of the upstream functions on all 2,189 windows).",
    "Left-handed participants (ActiGraph hip worn on the right = non-dominant side: P1006, P1007, P1023) are mirrored to a right-wrist frame by negating acc_x, gyr_y, gyr_z (Kyritsis et al., arXiv:2010.07051 Eq. 1). The paper reports 4 left-handed participants of 27; the 4th is presumably the excluded P1001.",
    "Units verified on the recordings: accelerometer m/s^2 including gravity (|acc| = 9.81 at rest), gyroscope rad/s (rest |w| ~ 0.07, walking ~ 1.2, aerobics ~ 2.3). The dataset README (g and deg/s) is contradicted by its own example values.",
    "Models: XGBClassifier(random_state=0, n_jobs=1) and RandomForestRegressor(random_state=0, n_jobs=1), every other argument at the library default (upstream constructs them without arguments: helper_model.py:42, in-lab.py:496; upstream sets no seed). The classifier is fit on all windows; the regressor on windows of light/vigorous activities with a finite MET (in-lab.py:480-497). Sedentary prediction = 1.0 MET; otherwise the regressor output (>= 1.0).",
    "Demographics (training features): sex, age at the visit and weight from the ActiGraph header; height from the upstream notebook table (MetCart height, 0.1 in resolution; header heights are whole inches). The upstream age feature is 'year the script is run minus birth year' (1-3 years above the age at the visit); sensitivity runs for header heights, notebook ages and age+2 are in loso.w60_sensitivity.",
]

def limitations(loso: dict | None, dataset_info: dict) -> list[str]:
    """Plain-language limitations; every number is taken from this build's own results."""
    src = dataset_info["demographic_sources"]
    bmi_lo, bmi_hi = src["bmi_min_max"]
    age_lo, age_hi = src["age_years_min_max"]
    met_hi = dataset_info["window_met_range"][1]
    out = []
    if loso is None:
        out.append(
            "The published accuracy is NOT reproduced in this build's evaluation (the evaluation suite was skipped here; "
            "run scripts/build_wristmet.py without --skip-loso for the leave-one-participant-out numbers)."
        )
    else:
        p, paper = loso["w60_primary"], loso["paper"]["60s"]
        base = p["baselines"]
        rf_only = loso["w60_ablation_demographics_free"]["regressor_only_rmse_on_nonsedentary_windows"]["nine_features"]
        r2 = 1.0 - (rf_only / base["nonsedentary_rmse_constant_mean"]) ** 2
        out.append(
            "The published accuracy is NOT reproduced. Under genuine leave-one-participant-out validation the retrained "
            f"model has an overall 60 s RMSE of {p['rmse_overall']:.3f} MET (paper: {paper['rmse_overall']:.3f}); sedentary / light / "
            f"moderate-vigorous {p['rmse_sedentary']:.3f} / {p['rmse_light']:.3f} / {p['rmse_mod_vig']:.3f} (paper: "
            f"{paper['rmse_sedentary']:.3f} / {paper['rmse_light']:.3f} / {paper['rmse_mod_vig']:.3f}). On windows that really are "
            f"non-sedentary the random forest reaches {rf_only:.2f} MET RMSE for unseen people against {base['nonsedentary_rmse_constant_mean']:.2f} "
            f"for predicting the training mean (explained variance about {r2:.0%}); even knowing the activity leaves "
            f"{base['nonsedentary_rmse_activity_mean_oracle']:.2f}. The published LOSO loop in in-lab.py fits the classifier on all "
            "participants and calls a regression() helper that is not in the public repository, so the paper's figures could "
            "not be traced to code (see loso.w60_leakage_diagnostics for what leaking the held-out participant does)."
        )
        sp, pp = p["classifier_sedentary_positive"], paper["classifier_sedentary_positive"]
        out.append(
            "Under LOSO the retrained classifier separates sedentary from non-sedentary windows well "
            f"(accuracy {p['classifier_accuracy']:.3f}; sedentary-positive precision / recall / F1 "
            f"{sp['precision']:.3f} / {sp['recall']:.3f} / {sp['f1']:.3f} against {pp['precision']:.3f} / {pp['recall']:.3f} / "
            f"{pp['f1']:.3f} in the paper). Alternative label and metric definitions that were tried did not reproduce the "
            "paper's lower recall."
        )
    out += [
        f"{dataset_info['n_participants']} participants with obesity (BMI {bmi_lo}-{bmi_hi}, age {age_lo:.0f}-{age_hi:.0f}), scripted "
        "lab activities, a Fossil Sport Gen 4 watch on the dominant wrist. Younger or leaner people, free-living behaviour and "
        "non-dominant-wrist wear are outside the training distribution (ood_demographic / ood_signal quantify this).",
        "The WHOOP strap's axes are assumed to equal the training watch's axes (AxisMap identity). The training frame was "
        "measured (frame_reference): with the arm hanging, the window-mean accelerometer vector is ~(+8.8, -3.9, 0) m/s^2, "
        "i.e. +x runs along the forearm towards the elbow. A wrong mapping is only partly detectable "
        "(ood.stress_tests_on_training_windows).",
        "The regression stage is fit on the non-sedentary windows of the training participants only; the random forest "
        f"cannot extrapolate beyond the MET values it saw (largest measured window MET in the training data: {met_hi:.1f}).",
        "Not a medical device; research use only.",
    ]
    return out


def notice_text(model_id: str) -> str:
    return f"""# NOTICE - {model_id}

`{model_id}.json.gz` is a **model retrained by this project** from the public code and public data of the
WristMET study. It is **not** the authors' pretrained model, it does not reproduce the accuracy reported in the
paper (see `manifest.json`, `loso`), and it is not endorsed by the authors or by the HABits Lab.

## Sources

1. Paper: Wei B, Romano C, Pedram M, Nolan B, Morelli WA, Alshurafa N. *Developing and comparing a new BMI
   inclusive energy expenditure algorithm on wrist-worn wearables.* Scientific Reports 15 (2025).
   https://doi.org/10.1038/s41598-025-99963-0 (please cite it when using this model).
2. Code: https://github.com/HAbitsLab/WristBased-EE-Estimation, commit
   `3d3517cb95ef490d5e867ebf6a7207b8f7278788`, MIT licence. The feature definitions, window rules and
   hyper-parameters were re-implemented from it (`energy_models/wristmet/features.py`), and short literal
   excerpts are kept for verification in `energy_models/wristmet/pipeline/upstream_reference.py`.
3. Data: Wei B, Romano C, Pedram M, Nolan B, Morelli W, Alshurafa N. *Wrist-Based Energy Expenditure Estimation
   In-lab Dataset*, Zenodo, record 14858226, https://doi.org/10.5281/zenodo.14858226, licensed
   **CC BY 4.0** (https://creativecommons.org/licenses/by/4.0/). File `Phase 2 - Data.zip`, md5
   `1840803700111c0a1871e9af3eacc9be`.
   Changes made: the recordings were re-windowed (60 s), summarised into statistical features, and used to fit
   the model parameters in the artifact. The artifact contains no raw recordings; it stores tree parameters and
   summary statistics (feature ranges, gravity-direction unit vectors of the training windows, age/BMI ranges of
   the 26 participants). `tests/fixtures/wristmet_golden.json` contains six 60 s windows from that dataset
   (rounded to 3 decimals) as a numerical regression fixture.
4. Left-handed mirroring follows Kyritsis et al., arXiv:2010.07051, Eq. 1.

## MIT licence of the upstream code

{MIT_LICENSE}
## Build-time libraries (not redistributed)

numpy (BSD-3-Clause), pandas (BSD-3-Clause), scikit-learn (BSD-3-Clause), xgboost (Apache-2.0), scipy
(BSD-3-Clause), openpyxl (MIT). Exact versions: `requirements-wristmet-build.txt` and `manifest.json`.
Inference needs numpy only.

## Intended use and warnings

Research / experimentation. Not a medical device; the estimate is coarse (see `manifest.json`, `limitations`).
"""


def dataset_summary(ds60: WindowDataset, ds15: WindowDataset | None, zip_md5: str | None) -> dict:
    m = ds60.meta
    gap_acc = m["max_gap_acc_ms"] > 500.0
    gap_gyr = m["max_gap_gyr_ms"] > 500.0
    per_p = m.assign(gap=gap_acc | gap_gyr).groupby("participant")["gap"].agg(["sum", "size"])
    worst = per_p.sort_values("sum", ascending=False).head(3)
    checks = [
        r[key]
        for r in ds60.reports["participants"].values()
        for key in ("shipped_acc", "shipped_gyr")
        if key in r
    ]
    cls = met_class(m["met"].to_numpy()[np.isfinite(m["met"].to_numpy())])
    ages = ds60.demographics("primary")
    return {
        "zenodo_zip_md5": zip_md5,
        "zenodo_zip_md5_matches_record": zip_md5 == E.PROVENANCE["data"]["md5"] if zip_md5 else None,
        "n_participants": len(ds60.demos),
        "participants": [f"P{d.participant}" for d in ds60.demos],
        "n_windows_60s": int(len(m)),
        "n_windows_15s": int(len(ds15.meta)) if ds15 is not None else None,
        "n_windows_60s_without_reference_met": int(m["met"].isna().sum()),
        "window_met_range": [float(np.nanmin(m["met"].to_numpy())), float(np.nanmax(m["met"].to_numpy()))],
        "windows_by_activity_group_60s": {k: int(v) for k, v in m["activity_group"].value_counts().items()},
        "windows_by_measured_met_class_60s": {
            "sedentary(<1.5)": int((cls == 0).sum()),
            "light(1.5-<3)": int((cls == 1).sum()),
            "moderate_vigorous(>=3)": int((cls == 2).sum()),
        },
        "windows_60s_with_raw_sample_gap_over_500ms": {
            "accelerometer": int(gap_acc.sum()),
            "gyroscope": int(gap_gyr.sum()),
            "either": int((gap_acc | gap_gyr).sum()),
            "most_affected_participants": {f"P{int(p)}": f"{int(r['sum'])}/{int(r['size'])} windows" for p, r in worst.iterrows()},
            "note": "the shipped resampled data interpolate linearly across these gaps and the upstream pipeline trains on them; the faithful default keeps them (sensitivity: loso.w60_sensitivity)",
        },
        "resample_replica_vs_shipped_resampled_csv": {
            "n_sensor_files_compared": len(checks),
            "all_timestamps_equal": all(c["time_equal"] for c in checks),
            "max_abs_value_diff": float(max(c["max_abs_diff"] for c in checks)) if checks else None,
        },
        "demographic_sources": {
            "sex_age_weight": "ActiGraph AGD header (age at the visit)",
            "height": "upstream notebook table (MetCart height, 0.1 in resolution)",
            "participant_sex_counts": ds60.demographics("primary").groupby("gender").size().rename({0: "female", 1: "male"}).to_dict(),
            "age_years_min_max": [float(ages["age"].min()), float(ages["age"].max())],
            "bmi_min_max": [round(float(ages["BMI"].min()), 2), round(float(ages["BMI"].max()), 2)],
            "participant_1001": "absent from the public record (paper: 27 participants); appears only in the upstream notebook table (male, notebook age 49 = about 47-48 at the visit, 177.8 cm, 129.3 kg) and is not used",
        },
    }


def build_manifest(
    *,
    model_id: str,
    production: dict,
    loso: dict | None,
    dataset_info: dict,
    committed: bool,
) -> dict:
    manifest = {
        "schema": SCHEMA,
        "model_id": model_id,
        "artifact": {**production["artifact"], "committed_to_git": committed},
        "provenance": E.PROVENANCE,
        "dataset": dataset_info,
        "training": production["training"],
        "pipeline_decisions": PIPELINE_DECISIONS,
        "determinism": production["determinism"],
        "parity_vs_scikit_learn_and_xgboost": production["parity"],
        "feature_parity_vs_upstream_code": production["feature_parity_vs_upstream_code"],
        "speed": production["speed"],
        "envelope_summary": production["envelope_summary"],
        "ood": {
            "signal_formula": O.SIGNAL_FORMULA,
            "demographic_formula": O.DEMOGRAPHIC_FORMULA,
            **production["ood"],
        },
        "frame_reference": {
            "description": "median over training windows of the 60 s mean accelerometer vector (m/s^2, right-wrist frame, x y z) by activity",
            "rows": production["frame_reference"],
        },
        "limitations": limitations(loso, dataset_info),
        "reproduce": "python scripts/build_wristmet.py --research-dir <dir with zenodo/Phase_2_Data.zip> (see the script's --help)",
    }
    if loso is not None:
        manifest["loso"] = loso
    return manifest


def write_manifest(path: Path, manifest: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n")


def write_notice(path: Path, model_id: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(notice_text(model_id))
