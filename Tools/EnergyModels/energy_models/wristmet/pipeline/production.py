"""Train the production WristMET models, export the artifact and verify it (build time)."""

from __future__ import annotations

import json
import os
import platform
import time
from importlib import metadata
from pathlib import Path
from typing import Callable

import numpy as np

from .. import features as F
from .. import ood as O
from ..model import WristMetModel
from . import export as E
from . import modeling as M
from .dataset import WindowDataset, upstream_window_arrays

MODEL_ID = "wristmet-v1"
ARTIFACT_NAME = f"{MODEL_ID}.json.gz"
LIBRARIES = ("numpy", "pandas", "scikit-learn", "xgboost", "scipy", "openpyxl", "joblib", "threadpoolctl")
# A made-up young, lean adult, far outside the cohort (25-64 y, BMI 30.5-46.2). It only documents in the manifest
# what an out-of-cohort wearer scores on `ood_demographic`; it is not a real person's data.
OUT_OF_COHORT_EXAMPLE = {"age": 22.0, "sex": "male", "weight_kg": 70.0, "height_cm": 175.0}

GOLDEN_PICKS = (  # (participant, activity) -> first matching window; chosen to span the class range
    (1002, "Rest"),
    (1005, "Typing on a computer while seated"),
    (1012, "Lying down while doing nothing"),
    (1015, "Walking 3.5 mph on treadmill"),
    (1020, "General aerobics video"),
    (1023, "Running 4 mph on a treadmill"),
)
GOLDEN_DEMOGRAPHICS = {"age": 45.0, "sex": "female", "weight_kg": 100.0, "height_cm": 165.0}
GOLDEN_DECIMALS = 3


def library_versions() -> dict:
    out = {"python": platform.python_version()}
    for name in LIBRARIES:
        try:
            out[name] = metadata.version(name)
        except metadata.PackageNotFoundError:
            pass
    return out


def train_production(a: M.Assembled, seed: int = M.DEFAULT_SEED):
    """Fit both stages on all participants with the upstream default hyperparameters (``n_jobs=1``: the result
    does not depend on the thread count, this just keeps the build reproducible on any machine)."""
    clf = M.make_classifier(seed, n_jobs=1)
    clf.fit(a.X_cls, a.y_cls)
    rf = M.make_regressor(seed, n_jobs=1)
    m = a.reg_train_mask
    rf.fit(a.X_reg[m], a.met[m])
    return clf, rf


def _jsonable(v):
    if isinstance(v, float) and not np.isfinite(v):
        return str(v)
    if isinstance(v, (int, float, str, bool, type(None))):
        return v
    return str(v)


def effective_hyperparameters(clf, rf) -> dict:
    booster_cfg = json.loads(clf.get_booster().save_config())
    return {
        "xgboost": {
            "constructor": "XGBClassifier(random_state=seed, n_jobs=1)  # all other arguments at library defaults",
            "sklearn_params": {k: _jsonable(v) for k, v in clf.get_params().items() if v is not None},
            "tree_train_param": booster_cfg["learner"]["gradient_booster"]["tree_train_param"],
            "n_estimators_effective": int(clf.get_booster().num_boosted_rounds()),
        },
        "random_forest": {
            "constructor": "RandomForestRegressor(random_state=seed, n_jobs=1)  # all other arguments at library defaults",
            "params": {k: _jsonable(v) for k, v in rf.get_params().items()},
        },
    }


def signal_matrix(a: M.Assembled, windows_model: np.ndarray) -> np.ndarray:
    return O.signal_feature_matrix(a.X_cls, a.X_reg[:, [3, 8]], O.acc_norm_median(windows_model))


def calibrate_gravity_angle(a: M.Assembled, gv: np.ndarray) -> tuple[float, dict]:
    """``theta_ok``: 99th percentile of the leave-one-participant-out nearest-direction angle, rounded up to 5 degrees."""
    ang = np.full(len(gv), np.nan)
    for p in a.participants:
        te = a.groups == p
        ref = gv[~te]
        ref = ref[np.isfinite(ref).all(axis=1)]
        ang[te] = O.nearest_angle_deg(gv[te], ref)
    v = ang[np.isfinite(ang)]
    p99 = float(np.percentile(v, 99))
    theta_ok = float(5.0 * np.ceil(p99 / 5.0))
    q = np.percentile(v, [50, 90, 95, 99, 99.9, 100])
    return theta_ok, {
        "loso_nearest_direction_angle_deg": {k: round(float(x), 2) for k, x in zip(("p50", "p90", "p95", "p99", "p99.9", "max"), q)},
        "theta_ok_deg": theta_ok,
        "n_windows_with_defined_direction": int(v.size),
    }


def loso_ood_calibration(a: M.Assembled, sig: np.ndarray, gv: np.ndarray, theta_ok: float) -> dict:
    """How often ``ood_signal`` fires for held-out participants (envelope fitted without them)."""
    combined = np.zeros(len(sig))
    rng = np.zeros(len(sig))
    grav = np.zeros(len(sig))
    for p in a.participants:
        te = a.groups == p
        env = O.SignalEnvelope.fit(sig[~te], gv[~te], angle_ok_deg=theta_ok)
        sc = env.score(sig[te])
        combined[te], rng[te], grav[te] = sc.ood_signal, sc.ood_range, sc.ood_gravity
    out = {}
    for name, arr in (("ood_signal", combined), ("ood_range", rng), ("ood_gravity", grav)):
        out[name] = {
            "quantiles_p50_p90_p95_p99_max": [round(float(x), 3) for x in np.quantile(arr, [0.5, 0.9, 0.95, 0.99, 1.0])],
            "fraction_above_0.1": round(float((arr > 0.1).mean()), 4),
            "fraction_above_0.25": round(float((arr > 0.25).mean()), 4),
            "fraction_above_0.5": round(float((arr > 0.5).mean()), 4),
        }
    return out


def frame_reference(a: M.Assembled) -> list[dict]:
    cols = list(O.ACC_MEAN_COLUMNS)
    g = a.X_cls[:, cols]
    rows = []
    for act, idx in a.meta.groupby("activity").indices.items():
        med = np.median(g[idx], axis=0)
        rows.append(
            {
                "activity": str(act).strip(),
                "n_windows": int(len(idx)),
                "median_window_mean_acc_m_s2_xyz": [round(float(x), 2) for x in med],
            }
        )
    rows.sort(key=lambda r: -r["n_windows"])
    return rows


def stress_tests(model: WristMetModel, windows_model: np.ndarray, sample: int | None = None) -> dict:
    """Fraction of training windows whose ``ood_signal`` exceeds 0.5 after a simulated integration error."""
    w = windows_model if sample is None else windows_model[:: max(1, len(windows_model) // sample)]
    demo = {"age": 45.0, "sex": "female", "weight_kg": 100.0, "height_cm": 165.0}

    def swap(arr, i, j):
        out = arr.copy()
        out[:, :, [i, j]] = out[:, :, [j, i]]
        return out

    def flip(arr, idx):
        out = arr.copy()
        out[:, :, idx] *= -1.0
        return out

    def scale(arr, sl, k):
        out = arr.copy()
        out[:, :, sl] *= k
        return out

    cases = {
        "unmodified": lambda x: x,
        "acc_in_g_instead_of_m_s2": lambda x: scale(x, slice(3, 6), 1 / 9.80665),
        "acc_scaled_x1.1": lambda x: scale(x, slice(3, 6), 1.1),
        "gyr_in_deg_s_instead_of_rad_s": lambda x: scale(x, slice(0, 3), 180.0 / np.pi),
        "swap_acc_x_y": lambda x: swap(x, 3, 4),
        "swap_acc_x_z": lambda x: swap(x, 3, 5),
        "swap_acc_y_z": lambda x: swap(x, 4, 5),
        "flip_acc_x": lambda x: flip(x, 3),
        "flip_acc_y": lambda x: flip(x, 4),
        "flip_acc_z": lambda x: flip(x, 5),
        "flip_acc_xyz": lambda x: flip(x, [3, 4, 5]),
        "left_wrist_not_mirrored": lambda x: flip(x, [3, 1, 2]),
    }
    out = {"n_windows": int(len(w))}
    for name, fn in cases.items():
        r = model.predict_windows(fn(w), **demo)
        out[name] = {
            "median_ood_signal": round(float(np.median(r.ood_signal)), 3),
            "fraction_above_0.5": round(float((r.ood_signal > 0.5).mean()), 3),
        }
    return out


def verify_features_against_upstream(ds: WindowDataset, a: M.Assembled, windows_model: np.ndarray, n_literal: int = 40) -> dict:
    """Compare ``features.py`` with literal copies of the upstream functions on every training window."""
    import pandas as pd

    from . import upstream_reference as U

    n = len(a.groups)
    ref42 = U.extract_features([np.ascontiguousarray(windows_model[i].T) for i in range(n)])
    ref_rmssd = np.empty(n)
    ref_freq = np.empty(n)
    n_acc = ds.meta["n_acc"].to_numpy()
    frames = []
    for i in range(n):
        acc = ds.windows[i, : int(min(n_acc[i], ds.n_samples)), 3:6]
        df = pd.DataFrame({"accX": acc[:, 0], "accY": acc[:, 1], "accZ": acc[:, 2]})
        frames.append(df)
        ref_rmssd[i] = U.get_rmssd(df, norm="l1")
        ref_freq[i] = U.get_freq_intensity_fast(df, 100, 1)
    literal = list(range(0, n, max(1, n // n_literal)))
    literal_ok = all(
        U.get_freq_intensity(frames[i], 100, 1) == ref_freq[i] for i in literal
    )
    return {
        "n_windows": n,
        "classifier_features_42_bitwise_equal": bool(np.array_equal(ref42, a.X_cls)),
        "classifier_features_max_abs_diff": float(np.abs(ref42 - a.X_cls).max()),
        "intensity_rmssd_l1_bitwise_equal": bool(np.array_equal(ref_rmssd, a.X_reg[:, 8])),
        "intensity_freq_bitwise_equal": bool(np.array_equal(ref_freq, a.X_reg[:, 3])),
        "literal_o_n2_freq_function_windows_checked": len(literal),
        "literal_o_n2_freq_function_equals_hoisted_fft_variant": bool(literal_ok),
    }


def parity_report(model: WristMetModel, clf, rf, a: M.Assembled, windows_model: np.ndarray, ds: WindowDataset) -> dict:
    p_ref = clf.predict_proba(a.X_cls)[:, 1].astype(np.float64)
    p_new = model.classify_features(a.X_cls).astype(np.float64)
    r_ref = rf.predict(a.X_reg)
    r_new = model.regress_features(a.X_reg)
    cls_ref = clf.predict(a.X_cls).astype(bool)
    all_idx = np.ones(len(a.groups), dtype=bool)
    _, _, est_ref = M.predict_pipeline(clf, rf, a, all_idx)
    est_new = np.full(len(a.groups), np.nan)
    active_new = np.zeros(len(a.groups), dtype=bool)
    for d in ds.demos:
        idx = np.nonzero(a.groups == int(d.participant))[0]
        r = model.predict_windows(
            windows_model[idx], age=d.age_years, sex=d.sex, weight_kg=d.weight_kg, height_cm=d.height_cm
        )
        est_new[idx] = r.met
        active_new[idx] = r.is_active
    return {
        "n_windows": int(len(a.groups)),
        "classifier_probability_max_abs_diff": float(np.abs(p_ref - p_new).max()),
        "classifier_decisions_identical": bool(np.array_equal(cls_ref, p_new > 0.5)),
        "regressor_max_abs_diff_all_windows": float(np.abs(r_ref - r_new).max()),
        "end_to_end_met_max_abs_diff": float(np.nanmax(np.abs(est_ref - est_new))),
        "end_to_end_class_decisions_identical": bool(np.array_equal(cls_ref, active_new)),
        "end_to_end_all_finite": bool(np.isfinite(est_new).all()),
        "tolerances": {"regressor": 1e-6, "classifier_probability": 1e-5},
    }


def speed_report(model: WristMetModel, windows_model: np.ndarray) -> dict:
    demo = {"age": 45.0, "sex": "female", "weight_kg": 100.0, "height_cm": 165.0}
    batch = windows_model[:200]
    model.predict_windows(batch[:5], **demo)  # warm-up
    t = time.perf_counter()
    model.predict_windows(batch, **demo)
    per_window_batch = (time.perf_counter() - t) / len(batch)
    t = time.perf_counter()
    for i in range(50):
        model.predict_windows(batch[i : i + 1], **demo)
    per_window_single = (time.perf_counter() - t) / 50
    return {
        "ms_per_window_batch_of_200": round(per_window_batch * 1e3, 3),
        "ms_per_window_single_call": round(per_window_single * 1e3, 3),
        "machine": f"{platform.machine()} {platform.system()} cpu_count={os.cpu_count()}",
        "numpy": np.__version__,
    }


def golden_fixture(
    model: WristMetModel,
    clf,
    rf,
    a: M.Assembled,
    windows_model: np.ndarray,
    artifact_sha256: str,
) -> dict:
    """<= 8 model-space windows with the reference outputs from scikit-learn / XGBoost and from the numpy evaluator."""
    idx = []
    for participant, activity in GOLDEN_PICKS:
        hit = np.nonzero((a.groups == participant) & (a.meta["activity"].str.strip() == activity).to_numpy())[0]
        if hit.size == 0:
            raise RuntimeError(f"golden pick P{participant} / {activity!r} not found")
        idx.append(int(hit[len(hit) // 2]))
    w = np.round(windows_model[idx], GOLDEN_DECIMALS)
    d = GOLDEN_DEMOGRAPHICS
    cf = F.classifier_features(w)
    inten = F.regression_intensity_features(w)
    rf_in = F.regressor_features(inten, age=d["age"], sex=d["sex"], weight_kg=d["weight_kg"], height_cm=d["height_cm"])
    res = model.predict_windows(w, **d)
    p_xgb = clf.predict_proba(cf)[:, 1].astype(np.float64)
    met_rf = np.maximum(rf.predict(rf_in), 1.0)
    return {
        "description": (
            "Golden regression fixture for WristMET. 'windows' are model-space windows (right-wrist frame, 20 Hz, "
            f"m/s^2 and rad/s) rounded to {GOLDEN_DECIMALS} decimals, taken from the public Zenodo dataset "
            "(CC BY 4.0, doi:10.5281/zenodo.14858226). 'expected' holds the outputs of the build-time "
            "scikit-learn/XGBoost models and of the numpy evaluator for the demographics below."
        ),
        "artifact_sha256": artifact_sha256,
        "model_id": MODEL_ID,
        "demographics": d,
        "windows": w.tolist(),
        "source": [
            {
                "participant": f"P{GOLDEN_PICKS[k][0]}",
                "activity": GOLDEN_PICKS[k][1],
                "measured_met": None if not np.isfinite(a.met[i]) else round(float(a.met[i]), 3),
            }
            for k, i in enumerate(idx)
        ],
        "expected": {
            "classifier_features": cf.tolist(),
            "regressor_features": rf_in.tolist(),
            "xgboost_p_active": p_xgb.tolist(),
            "sklearn_met_if_active": met_rf.tolist(),
            "met": [float(x) for x in res.met],
            "p_active": [float(x) for x in res.p_active],
            "ood_signal": [round(float(x), 6) for x in res.ood_signal],
            "ood_demographic": res.ood_demographic,
        },
    }


def build_production(
    ds: WindowDataset,
    out_dir: Path,
    golden_path: Path | None,
    *,
    seed: int = M.DEFAULT_SEED,
    log: Callable[[str], None] = print,
) -> dict:
    a = M.assemble(ds)
    windows_model, _ = upstream_window_arrays(ds, mirror=True)
    log("[pipeline] training production models")
    clf, rf = train_production(a, seed)

    sig = signal_matrix(a, windows_model)
    gv = O.gravity_unit_vectors(a.X_cls)
    theta_ok, angle_info = calibrate_gravity_angle(a, gv)
    signal_env = O.SignalEnvelope.fit(sig, gv, angle_ok_deg=theta_ok)
    demo = ds.demographics("primary")
    demo_env = O.DemographicEnvelope.fit(demo["age"].to_numpy(), demo["BMI"].to_numpy(), demo["gender"].to_numpy())
    reg_env = E.regression_feature_envelope(a.X_reg[a.reg_train_mask], len(ds.demos))
    frame_ref = frame_reference(a)

    versions = library_versions()
    training = {
        "seed": seed,
        "n_participants": len(ds.demos),
        "n_windows_classifier": int(len(a.groups)),
        "n_windows_regressor": int(a.reg_train_mask.sum()),
        "n_sedentary_windows": int((a.y_cls == 0).sum()),
        "n_nonsedentary_windows": int((a.y_cls == 1).sum()),
        "hyperparameters": effective_hyperparameters(clf, rf),
        "library_versions": versions,
        "left_handed_participants_mirrored": [f"P{d.participant}" for d in ds.demos if d.left_handed],
    }

    def make_spec(clf_, rf_):
        return E.assemble_spec(
            model_id=MODEL_ID,
            clf=clf_,
            rf=rf_,
            signal_envelope=signal_env,
            demographic_envelope=demo_env,
            regression_envelope=reg_env,
            frame_reference=frame_ref,
            training_summary=training,
        )

    spec = make_spec(clf, rf)
    info = E.write_artifact(spec, out_dir / ARTIFACT_NAME)
    log(f"[pipeline] artifact {info['path']}: {info['bytes_gz']} bytes gz, {info['bytes_json']} bytes json, sha256 {info['sha256']}")

    clf2, rf2 = train_production(a, seed)
    again = E.dumps_canonical(make_spec(clf2, rf2))
    determinism = {"rebuilt_json_identical": again == E.dumps_canonical(spec)}
    log(f"[pipeline] deterministic rebuild identical: {determinism['rebuilt_json_identical']}")

    model = WristMetModel.load(out_dir / ARTIFACT_NAME, expected_sha256=info["sha256"])
    parity = parity_report(model, clf, rf, a, windows_model, ds)
    log(f"[pipeline] parity {parity}")
    feature_check = verify_features_against_upstream(ds, a, windows_model)
    log(f"[pipeline] features vs upstream code {feature_check}")
    speed = speed_report(model, windows_model)
    stress = stress_tests(model, windows_model)
    loso_ood = loso_ood_calibration(a, sig, gv, theta_ok)
    out_of_cohort = model.predict_windows(windows_model[:1], **OUT_OF_COHORT_EXAMPLE)
    in_sample = model.predict_windows(windows_model[: len(windows_model)], **GOLDEN_DEMOGRAPHICS)

    if golden_path is not None:
        fixture = golden_fixture(model, clf, rf, a, windows_model, info["sha256"])
        golden_path.parent.mkdir(parents=True, exist_ok=True)
        golden_path.write_text(json.dumps(fixture, separators=(",", ":")))
        info["golden_fixture_bytes"] = golden_path.stat().st_size

    return {
        "artifact": info,
        "determinism": determinism,
        "parity": parity,
        "feature_parity_vs_upstream_code": feature_check,
        "speed": speed,
        "training": training,
        "envelope_summary": {
            "signal": {
                "n_windows": signal_env.n_windows,
                "n_descriptors": len(signal_env.names),
                "range_scale_e0": signal_env.range_scale,
                "gravity_angle_ok_deg": signal_env.angle_ok_deg,
                "gravity_angle_max_deg": signal_env.angle_max_deg,
                "n_gravity_directions": int(signal_env.gravity_unit_vectors.shape[0]),
                **angle_info,
            },
            "demographic": demo_env.to_dict(),
            "regression_features": {k: v for k, v in reg_env.items() if k != "features"},
        },
        "ood": {
            "signal_loso_false_alarm_rates": loso_ood,
            "signal_in_sample_fraction_above_0.5": round(float((in_sample.ood_signal > 0.5).mean()), 4),
            "stress_tests_on_training_windows": stress,
            "out_of_cohort_example": {
                **OUT_OF_COHORT_EXAMPLE, "ood_demographic": round(float(out_of_cohort.ood_demographic), 4),
            },
        },
        "frame_reference": frame_ref,
    }
