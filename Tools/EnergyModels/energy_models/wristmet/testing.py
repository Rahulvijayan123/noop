"""Synthetic windows and a tiny hand-written model spec for tests (numpy only; no dataset, no real artifact)."""

from __future__ import annotations

import numpy as np

from . import features as F
from . import ood as O
from .model import SCHEMA

WINDOW_SAMPLES = 1200

IDX_STD_ACC_Y = F.CLASSIFIER_FEATURE_NAMES.index("std_acc_y")
IDX_RANGE_GYR_X = F.CLASSIFIER_FEATURE_NAMES.index("range_gyr_x")
IDX_RMSSD = F.REGRESSOR_FEATURE_NAMES.index("Intensity (RMSSD_l1)")
IDX_GENDER = F.REGRESSOR_FEATURE_NAMES.index("gender")
IDX_BMI = F.REGRESSOR_FEATURE_NAMES.index("BMI")

SYNTHETIC_GRAVITY = (1.0, -7.0, 4.0)  # roughly the resting wrist orientation of the training data (m/s^2)


def synthetic_windows(
    n: int,
    *,
    seed: int = 0,
    active: bool = False,
    gravity: tuple[float, float, float] = SYNTHETIC_GRAVITY,
    length: int = WINDOW_SAMPLES,
) -> np.ndarray:
    """``[n, length, 6]`` windows (gyr_xyz, acc_xyz): gravity plus noise, and a 2 Hz arm swing if ``active``."""
    rng = np.random.default_rng(seed)
    t = np.arange(length) / 20.0
    acc = np.asarray(gravity, dtype=np.float64) + rng.normal(0.0, 0.03, (n, length, 3))
    gyr = rng.normal(0.0, 0.02, (n, length, 3))
    if active:
        phase = rng.uniform(0, 2 * np.pi, (n, 1))
        swing = np.sin(2 * np.pi * 2.0 * t[None, :] + phase)
        acc[:, :, 1] += 3.0 * swing
        acc[:, :, 2] += 1.5 * np.cos(2 * np.pi * 2.0 * t[None, :] + phase)
        gyr[:, :, 0] += 1.5 * swing
    return np.concatenate([gyr, acc], axis=2)


def _xgb_tree(feature: int, threshold: float, left_leaf: float, right_leaf: float, default_left: int = 1) -> dict:
    return {
        "feature": [feature, -1, -1],
        "split_condition": [threshold, left_leaf, right_leaf],
        "left": [1, -1, -1],
        "right": [2, -1, -1],
        "default_left": [default_left, 0, 0],
    }


def synthetic_classifier_trees() -> list[dict]:
    return [
        _xgb_tree(IDX_STD_ACC_Y, 0.5, -3.0, 3.0),
        _xgb_tree(IDX_RANGE_GYR_X, 0.2, -0.5, 0.5, default_left=0),
    ]


def synthetic_regressor_trees() -> list[dict]:
    stump = {
        "feature": [IDX_RMSSD, -1, -1],
        "threshold": [0.05, 0.0, 0.0],
        "left": [1, -1, -1],
        "right": [2, -1, -1],
        "value": [0.0, 2.0, 5.0],
    }
    deeper = {
        "feature": [IDX_GENDER, IDX_BMI, -1, -1, -1],
        "threshold": [0.5, 30.0, 0.0, 0.0, 0.0],
        "left": [1, 2, -1, -1, -1],
        "right": [4, 3, -1, -1, -1],
        "value": [0.0, 0.0, 1.5, 2.5, 3.0],
    }
    return [stump, deeper]


def synthetic_spec(n_envelope_windows: int = 120) -> dict:
    """A complete, valid model spec (schema ``nara.wristmet.model/1``) with two tiny trees per stage.

    The envelope is fitted on synthetic resting and swinging windows with the real feature code.
    """
    rest = synthetic_windows(n_envelope_windows // 2, seed=1)
    swing = synthetic_windows(n_envelope_windows // 2, seed=2, active=True)
    w = np.concatenate([rest, swing])
    cf = F.classifier_features(w)
    inten = F.regression_intensity_features(w)
    sig = O.signal_feature_matrix(cf, inten, O.acc_norm_median(w))
    gv = O.gravity_unit_vectors(cf)
    signal_env = O.SignalEnvelope.fit(sig, gv, angle_ok_deg=10.0)
    demo_env = O.DemographicEnvelope.fit(
        age=np.array([30.0, 40.0, 50.0, 60.0]),
        bmi=np.array([30.0, 35.0, 40.0, 45.0]),
        gender=np.array([0, 1, 0, 1]),
    )
    return {
        "schema": SCHEMA,
        "model_id": "wristmet-synthetic",
        "window": {"seconds": 60, "sample_rate_hz": 20, "samples": WINDOW_SAMPLES},
        "features": {
            "classifier": {"names": list(F.CLASSIFIER_FEATURE_NAMES)},
            "regressor": {"names": list(F.REGRESSOR_FEATURE_NAMES)},
        },
        "pipeline": {"sedentary_met": 1.0, "min_met": 1.0},
        "classifier": {"decision_threshold": 0.5, "base_margin": 0.25, "trees": synthetic_classifier_trees()},
        "regressor": {"trees": synthetic_regressor_trees()},
        "training_envelope": {"signal": signal_env.to_dict(), "demographic": demo_env.to_dict()},
    }
