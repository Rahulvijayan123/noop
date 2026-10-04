"""Serialise fitted WristMET models into the portable JSON consumed by ``energy_models.wristmet.model``.

JSON layout (schema ``nara.wristmet.model/1``), all arrays are per tree and indexed by node:

``classifier``  XGBoost ``binary:logistic``: ``feature`` (-1 = leaf), ``split_condition`` (float32 threshold, or the
leaf value for leaves), ``left``, ``right``, ``default_left``. Go left iff ``float32(x) < split_condition`` (NaN follows
``default_left``). ``margin = base_margin + sum(leaf values)`` (float32, tree order), ``p = 1/(1+exp(-margin))``,
non-sedentary iff ``p > decision_threshold``.

``regressor``  scikit-learn ``RandomForestRegressor``: ``feature`` (-1 = leaf), ``threshold``, ``left``, ``right``,
``value`` (leaves only; internal nodes hold 0). Go left iff ``float32(x) <= threshold``; the prediction is the mean of
the leaf values over trees. scikit-learn compares float32 features with float64 thresholds; storing, as threshold,
the largest float32 not above the float64 threshold gives identical decisions for every float32 input.
"""

from __future__ import annotations

import gzip
import hashlib
import json
from pathlib import Path

import numpy as np

from .. import features as F
from .. import ood as O

SCHEMA = "nara.wristmet.model/1"

PROVENANCE = {
    "paper": {
        "citation": (
            "Wei B, Romano C, Pedram M, Nolan B, Morelli WA, Alshurafa N. Developing and comparing a new BMI "
            "inclusive energy expenditure algorithm on wrist-worn wearables. Scientific Reports 15 (2025). "
            "doi:10.1038/s41598-025-99963-0"
        ),
        "url": "https://www.nature.com/articles/s41598-025-99963-0",
    },
    "code": {
        "repository": "https://github.com/HAbitsLab/WristBased-EE-Estimation",
        "commit": "3d3517cb95ef490d5e867ebf6a7207b8f7278788",
        "license": "MIT",
        "copyright": "Copyright (c) 2025 The HABits Lab",
    },
    "data": {
        "title": "Wrist-Based Energy Expenditure Estimation In-lab Dataset",
        "zenodo_record": 14858226,
        "doi": "10.5281/zenodo.14858226",
        "file": "Phase 2 - Data.zip",
        "bytes": 800154464,
        "md5": "1840803700111c0a1871e9af3eacc9be",
        "license": "CC BY 4.0",
        "creators": "Wei, Romano, Pedram, Nolan, Morelli, Alshurafa",
    },
    "weights": (
        "Retrained from the public code and data by this project. These are NOT the authors' pretrained weights "
        "and NOT the model evaluated in the paper."
    ),
}


def float32_floor(x: np.ndarray) -> np.ndarray:
    """Largest float32 that is <= each float64 in ``x``."""
    x = np.asarray(x, dtype=np.float64)
    t = x.astype(np.float32)
    over = t.astype(np.float64) > x
    t[over] = np.nextafter(t[over], np.float32(-np.inf))
    return t


def _json_f32(a: np.ndarray) -> list[float]:
    """float32 values as JSON numbers: the shortest decimal that parses back to the same float32."""
    a = np.asarray(a, dtype=np.float32)
    out = []
    for v in a:
        short = float(str(v))
        out.append(short if np.float32(short) == v else float(v))
    return out


def _json_f64(a: np.ndarray) -> list[float]:
    return [float(v) for v in np.asarray(a, dtype=np.float64)]


def classifier_block(clf) -> dict:
    raw = json.loads(clf.get_booster().save_raw("json"))
    learner = raw["learner"]
    if learner["objective"]["name"] != "binary:logistic":
        raise ValueError(f"unsupported objective {learner['objective']['name']!r}")
    base_score = np.float32(float(learner["learner_model_param"]["base_score"].strip("[]")))
    if not 0.0 < float(base_score) < 1.0:
        raise ValueError(f"degenerate XGBoost base_score {float(base_score)!r}: the classifier was fitted on one class only")
    base_margin = np.float32(-np.log(np.float32(1.0) / base_score - np.float32(1.0)))
    trees = []
    for t in learner["gradient_booster"]["model"]["trees"]:
        if any(int(s) != 0 for s in t["split_type"]):
            raise ValueError("categorical splits are not supported")
        left = np.asarray(t["left_children"], dtype=np.int64)
        right = np.asarray(t["right_children"], dtype=np.int64)
        leaf = left == -1
        feature = np.where(leaf, -1, np.asarray(t["split_indices"], dtype=np.int64))
        trees.append(
            {
                "feature": feature.tolist(),
                "split_condition": _json_f32(np.asarray(t["split_conditions"], dtype=np.float32)),
                "left": left.tolist(),
                "right": right.tolist(),
                "default_left": [int(v) for v in t["default_left"]],
            }
        )
    return {
        "type": "xgboost.binary:logistic",
        "positive_class": "non_sedentary",
        "decision_threshold": 0.5,
        "base_score": float(base_score),
        "base_margin": float(base_margin),
        "split_rule": "go left iff float32(x) < split_condition; NaN follows default_left; leaves store the leaf value in split_condition",
        "n_trees": len(trees),
        "trees": trees,
    }


def regressor_block(rf) -> dict:
    trees = []
    for est in rf.estimators_:
        t = est.tree_
        leaf = t.children_left == -1
        feature = np.where(leaf, -1, t.feature)
        thr = float32_floor(np.where(leaf, 0.0, t.threshold))
        value = np.where(leaf, t.value[:, 0, 0], 0.0)
        trees.append(
            {
                "feature": feature.astype(np.int64).tolist(),
                "threshold": _json_f32(thr),
                "left": t.children_left.astype(np.int64).tolist(),
                "right": t.children_right.astype(np.int64).tolist(),
                "value": _json_f64(value),
            }
        )
    return {
        "type": "sklearn.RandomForestRegressor",
        "split_rule": "go left iff float32(x) <= threshold (threshold = largest float32 <= scikit-learn's float64 threshold)",
        "n_trees": len(trees),
        "prediction": "mean of leaf values over trees",
        "trees": trees,
    }


def regression_feature_envelope(x_reg: np.ndarray, n_participants: int) -> dict:
    x = np.asarray(x_reg, dtype=np.float64)
    lo, hi = np.percentile(x, [O.LOW_PERCENTILE, O.HIGH_PERCENTILE], axis=0)
    return {
        "n_windows": int(x.shape[0]),
        "n_participants": n_participants,
        "note": "computed over the windows the regressor was trained on (non-sedentary activities)",
        "features": {
            name: {"min": float(x[:, i].min()), "max": float(x[:, i].max()), "p0.5": float(lo[i]), "p99.5": float(hi[i])}
            for i, name in enumerate(F.REGRESSOR_FEATURE_NAMES)
        },
    }


def assemble_spec(
    *,
    model_id: str,
    clf,
    rf,
    signal_envelope: O.SignalEnvelope,
    demographic_envelope: O.DemographicEnvelope,
    regression_envelope: dict,
    frame_reference: list[dict],
    training_summary: dict,
) -> dict:
    return {
        "schema": SCHEMA,
        "model_id": model_id,
        "description": (
            "WristMET-style two-stage wrist MET estimator (XGBoost sedentary/non-sedentary classifier + "
            "RandomForest regressor), retrained from public code and data. See provenance."
        ),
        "provenance": PROVENANCE,
        "window": {"seconds": 60, "sample_rate_hz": 20, "samples": 1200, "overlap": "none (training windows do not overlap)"},
        "input": {
            "channels": list(F.CHANNELS),
            "units": {"acc": "m/s^2, gravity included", "gyr": "rad/s"},
            "frame": (
                "right-wrist frame of the Fossil Sport Gen 4 training watch (worn on the dominant wrist; "
                "left-handed participants mirrored)"
            ),
            "mirror_left_wrist": {
                "negate_channels": ["acc_x", "gyr_y", "gyr_z"],
                "reference": "Kyritsis et al., arXiv:2010.07051, Eq. 1",
            },
            "invalid_window_policy": "any NaN/inf, or fewer than `samples` samples -> met = NaN",
        },
        "features": {
            "classifier": {
                "names": list(F.CLASSIFIER_FEATURE_NAMES),
                "layout": "statistic-major: for each of median, mean, max, min, range, std (ddof=0), rms the six channels in order",
            },
            "regressor": {
                "names": list(F.REGRESSOR_FEATURE_NAMES),
                "intensity_freq": {
                    "signal": "acc magnitude of samples 1..N-1",
                    "fs_hz_used": F.UPSTREAM_FREQ_FS,
                    "note": "upstream hard-codes fs=100 for 20 Hz data; reproduced because the model was trained on it",
                },
                "gender_coding": {"male": 1, "female": 0},
                "age": "years at the time of the visit",
                "BMI": "weight_kg / (height_cm / 100) ** 2",
            },
        },
        "pipeline": {
            "sedentary_met": 1.0,
            "min_met": 1.0,
            "rule": "p_active <= decision_threshold -> met = sedentary_met; otherwise met = max(regressor, min_met)",
        },
        "classifier": classifier_block(clf),
        "regressor": regressor_block(rf),
        "training_envelope": {
            "signal": signal_envelope.to_dict(),
            "regression_features": regression_envelope,
            "demographic": demographic_envelope.to_dict(),
        },
        "frame_reference": frame_reference,
        "training": training_summary,
    }


def dumps_canonical(spec: dict) -> bytes:
    return json.dumps(spec, separators=(",", ":"), allow_nan=False).encode("utf-8")


def write_artifact(spec: dict, path: Path) -> dict:
    """Write ``spec`` as deterministic gzip JSON (fixed mtime, no filename); return size and checksums."""
    raw = dumps_canonical(spec)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as fh:
        with gzip.GzipFile(filename="", mode="wb", fileobj=fh, compresslevel=9, mtime=0) as gz:
            gz.write(raw)
    data = path.read_bytes()
    return {
        "path": path.name,
        "bytes_gz": len(data),
        "bytes_json": len(raw),
        "sha256": hashlib.sha256(data).hexdigest(),
        "sha256_json": hashlib.sha256(raw).hexdigest(),
    }
