"""WristMET inference (numpy only): ``WristMetModel.load(path).predict_windows(...)``.

This is a retrained re-implementation of the wrist-based MET estimator of Wei, Romano, Pedram,
Nolan, Morelli and Alshurafa (Scientific Reports 2025, https://doi.org/10.1038/s41598-025-99963-0),
trained from the authors' public code (MIT, HABits Lab) and public data (Zenodo record 14858226,
CC BY 4.0). It is **not** the authors' pretrained model; see ``artifacts/wristmet/NOTICE.md``.

Pipeline (one 60 s window of 20 Hz IMU data)::

    42 statistics  --XGBoost classifier-->  P(non-sedentary)
        p <= 0.5  -> MET = 1.0
        p >  0.5  -> MET = RandomForest(9 features)   (gender, age, BMI, interactions,
                                                       two accelerometer intensity measures)

Inputs
------
``windows``: float array ``[n, 1200, 6]``, channels ``(gyr_x, gyr_y, gyr_z, acc_x, acc_y, acc_z)``,
20 Hz, **accelerometer in m/s^2 including gravity, gyroscope in rad/s** (the units of the
training data, verified from the recordings; the dataset README claims g and deg/s and is wrong),
expressed in the right-wrist frame (left wrist: ``preprocess.mirror_to_right_wrist``).
Use ``preprocess.windows_from_raw`` to build windows from 100 Hz WHOOP-style samples (g, deg/s).

Honest limitations (also in ``manifest.json``)
----------------------------------------------
* Trained on 26 adults with obesity (BMI 30-46, age 25-64), a Fossil Sport Gen 4 watch on the
  dominant wrist and scripted lab activities. ``ood_demographic`` and ``ood_signal`` quantify
  how far an input is from that.
* Under genuine leave-one-participant-out validation the retrained model's error (about 0.76 MET
  RMSE over all windows) is far above the published 0.28 (see the manifest); the regression stage
  explains only about a quarter of the variance of non-sedentary METs for held-out people.
  Treat ``met`` as a coarse estimate, not a measurement.
* The WHOOP strap's axes are *assumed* to equal the training watch's axes
  (see ``preprocess`` for the measured training frame).

Numerics: XGBoost trees are evaluated in float32 exactly as XGBoost does (``x < split``),
random-forest trees as scikit-learn does (``float32(x) <= threshold``); the exported thresholds
are the float32 values that make both rules exact.
"""

from __future__ import annotations

import gzip
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import features as F
from . import ood as O
from .preprocess import AxisMap, RawWindows, windows_from_raw

SCHEMA = "nara.wristmet.model/1"
_CHUNK = 2048  # feature rows evaluated per tree-traversal batch (bounds memory)
_WINDOW_CHUNK = 256  # windows turned into features at once (a day of 60 s windows is 1,440)


@dataclass(frozen=True)
class WristMetResult:
    """Per-window outputs of :meth:`WristMetModel.predict_windows` (all arrays have length ``n``)."""

    met: np.ndarray  # METs, >= 1.0; NaN for invalid windows
    p_active: np.ndarray  # classifier P(non-sedentary); NaN for invalid windows
    ood_signal: np.ndarray  # [0, 1]; 1.0 for invalid windows (see ood.py)
    ood_demographic: float  # [0, 1], one value for the person
    valid: np.ndarray  # bool: complete window without NaN/inf
    is_active: np.ndarray  # bool: p_active > 0.5 (regressor used); False for invalid windows
    met_if_active: np.ndarray  # raw regressor output (>= 1.0) for every valid window, NaN otherwise
    ood_range: np.ndarray  # range-excess component of ood_signal
    ood_gravity: np.ndarray  # gravity-direction component of ood_signal
    worst_feature: tuple[str | None, ...]  # descriptor with the largest range excess (None if invalid)


class _TreeEnsemble:
    """Concatenated trees evaluated level by level with numpy fancy indexing."""

    def __init__(self, trees: list[dict], *, kind: str):
        self.kind = kind
        feature, thr, left, right, dleft, value, roots = [], [], [], [], [], [], []
        offset = 0
        for t in trees:
            f = np.asarray(t["feature"], dtype=np.int64)
            n = f.shape[0]
            is_leaf = f < 0
            lc = np.asarray(t["left"], dtype=np.int64)
            rc = np.asarray(t["right"], dtype=np.int64)
            idx = np.arange(n, dtype=np.int64)
            lc = np.where(is_leaf, idx, lc) + offset  # leaves point to themselves
            rc = np.where(is_leaf, idx, rc) + offset
            feature.append(np.where(is_leaf, 0, f))
            if kind == "xgboost":
                cond = np.asarray(t["split_condition"], dtype=np.float32)
                thr.append(np.where(is_leaf, np.float32(0), cond))
                value.append(np.where(is_leaf, cond, np.float32(0)))
                dleft.append(np.asarray(t["default_left"], dtype=bool))
            else:
                thr.append(np.asarray(t["threshold"], dtype=np.float32))
                value.append(np.asarray(t["value"], dtype=np.float64))
                dleft.append(np.zeros(n, dtype=bool))
            left.append(lc)
            right.append(rc)
            roots.append(offset)
            offset += n
        self.feature = np.concatenate(feature)
        self.threshold = np.concatenate(thr)
        self.left = np.concatenate(left)
        self.right = np.concatenate(right)
        self.default_left = np.concatenate(dleft)
        self.value = np.concatenate(value)
        self.is_leaf = self.left == np.arange(self.left.shape[0])
        self.roots = np.asarray(roots, dtype=np.int64)
        self.n_trees = len(trees)

    def leaves(self, x32: np.ndarray) -> np.ndarray:
        """Leaf values ``[n_trees, n]`` for float32 features ``x32`` of shape ``[n, n_features]``."""
        n = x32.shape[0]
        node = np.repeat(self.roots[:, None], n, axis=1)
        rows = np.arange(n)[None, :]
        while True:
            active = ~self.is_leaf[node]
            if not active.any():
                break
            x = x32[rows, self.feature[node]]
            thr = self.threshold[node]
            if self.kind == "xgboost":
                go_left = np.where(np.isnan(x), self.default_left[node], x < thr)
            else:
                go_left = x <= thr
            nxt = np.where(go_left, self.left[node], self.right[node])
            node = np.where(active, nxt, node)
        return self.value[node]


def _read_json(path: Path) -> dict:
    raw = Path(path).read_bytes()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return json.loads(raw)


class WristMetModel:
    """Numpy evaluator of the exported WristMET model (see ``pipeline/export.py`` for the schema)."""

    def __init__(self, spec: dict):
        if spec.get("schema") != SCHEMA:
            raise ValueError(f"unsupported model schema {spec.get('schema')!r}; expected {SCHEMA!r}")
        self.spec = spec
        self.model_id: str = spec["model_id"]
        win = spec["window"]
        self.window_samples: int = int(win["samples"])
        self.sample_rate_hz: float = float(win["sample_rate_hz"])
        feats = spec["features"]
        if tuple(feats["classifier"]["names"]) != F.CLASSIFIER_FEATURE_NAMES:
            raise ValueError("classifier feature names/order differ from features.py")
        if tuple(feats["regressor"]["names"]) != F.REGRESSOR_FEATURE_NAMES:
            raise ValueError("regressor feature names/order differ from features.py")
        clf, reg = spec["classifier"], spec["regressor"]
        self._clf = _TreeEnsemble(clf["trees"], kind="xgboost")
        self._rf = _TreeEnsemble(reg["trees"], kind="forest")
        self._base_margin = np.float32(clf["base_margin"])
        self._threshold = float(clf["decision_threshold"])
        self._sedentary_met = float(spec["pipeline"]["sedentary_met"])
        self._min_met = float(spec["pipeline"]["min_met"])
        self.signal_envelope = O.SignalEnvelope.from_dict(spec["training_envelope"]["signal"])
        self.demographic_envelope = O.DemographicEnvelope.from_dict(spec["training_envelope"]["demographic"])

    @classmethod
    def load(cls, path: str | Path, *, expected_sha256: str | None = None) -> "WristMetModel":
        """Load an exported model (``.json`` or ``.json.gz``). ``expected_sha256`` checks the file bytes."""
        path = Path(path)
        if expected_sha256 is not None:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest != expected_sha256.lower():
                raise ValueError(f"sha256 mismatch for {path}: {digest} != {expected_sha256}")
        return cls(_read_json(path))

    @property
    def classifier_feature_names(self) -> tuple[str, ...]:
        return F.CLASSIFIER_FEATURE_NAMES

    @property
    def regressor_feature_names(self) -> tuple[str, ...]:
        return F.REGRESSOR_FEATURE_NAMES

    def ood_demographic(self, *, age: float, sex: str | int | float, weight_kg: float, height_cm: float) -> float:
        """Demographic out-of-distribution score in [0, 1] (formula in ``ood.py``)."""
        age, gender, weight_kg, height_cm = _check_demographics(age, sex, weight_kg, height_cm)
        bmi = weight_kg / (height_cm / 100.0) ** 2
        return self.demographic_envelope.score(age, bmi, gender)

    def classify_features(self, classifier_features: np.ndarray) -> np.ndarray:
        """P(non-sedentary) (float32 sigmoid of the float32 tree margin) for ``[n, 42]`` features."""
        x32 = np.ascontiguousarray(classifier_features, dtype=np.float32)
        out = np.empty(x32.shape[0], dtype=np.float32)
        for lo in range(0, x32.shape[0], _CHUNK):
            leaves = self._clf.leaves(x32[lo : lo + _CHUNK])
            margin = np.full(leaves.shape[1], self._base_margin, dtype=np.float32)
            for t in range(leaves.shape[0]):  # tree order, float32: same accumulation as XGBoost
                margin += leaves[t]
            out[lo : lo + _CHUNK] = np.float32(1.0) / (np.float32(1.0) + np.exp(-margin))
        return out

    def regress_features(self, regressor_features: np.ndarray) -> np.ndarray:
        """Random-forest mean prediction (float64) for ``[n, 9]`` features."""
        x32 = np.ascontiguousarray(regressor_features, dtype=np.float32)
        out = np.empty(x32.shape[0], dtype=np.float64)
        for lo in range(0, x32.shape[0], _CHUNK):
            leaves = self._rf.leaves(x32[lo : lo + _CHUNK])
            acc = np.zeros(leaves.shape[1], dtype=np.float64)
            for t in range(leaves.shape[0]):  # tree order, float64: same accumulation as scikit-learn
                acc += leaves[t]
            out[lo : lo + _CHUNK] = acc / leaves.shape[0]
        return out

    def predict_windows(
        self,
        windows: np.ndarray,
        *,
        age: float,
        sex: str | int | float,
        weight_kg: float,
        height_cm: float,
    ) -> WristMetResult:
        """Estimate METs for 60 s windows ``[n, 1200, 6]`` (see the module docstring for units and frame).

        A window containing NaN/inf, or an input with fewer than ``window_samples`` samples per
        window, yields ``met = NaN`` (never a number computed from missing data) and
        ``ood_signal = 1``. More than ``window_samples`` samples per window raises ``ValueError``.
        """
        age_f, gender, weight_f, height_f = _check_demographics(age, sex, weight_kg, height_cm)
        arr = np.asarray(windows, dtype=np.float64)
        if arr.ndim == 2:
            arr = arr[None]
        if arr.ndim != 3 or arr.shape[2] != 6:
            raise ValueError(f"windows must have shape [n, {self.window_samples}, 6], got {arr.shape}")
        n, length = arr.shape[0], arr.shape[1]
        if length > self.window_samples:
            raise ValueError(
                f"windows have {length} samples; the model needs exactly {self.window_samples} "
                "(use preprocess.windows_from_raw to cut longer signals)"
            )
        bmi = weight_f / (height_f / 100.0) ** 2
        ood_demo = self.demographic_envelope.score(age_f, bmi, gender)

        met = np.full(n, np.nan)
        p_active = np.full(n, np.nan)
        met_if_active = np.full(n, np.nan)
        ood_signal = np.ones(n)
        ood_range = np.ones(n)
        ood_gravity = np.ones(n)
        worst: list[str | None] = [None] * n
        valid = np.zeros(n, dtype=bool) if length < self.window_samples else np.isfinite(arr).all(axis=(1, 2))
        is_active = np.zeros(n, dtype=bool)

        names = self.signal_envelope.names
        valid_idx = np.nonzero(valid)[0]
        for lo in range(0, valid_idx.size, _WINDOW_CHUNK):  # bounds peak memory; results do not depend on the chunking
            idx = valid_idx[lo : lo + _WINDOW_CHUNK]
            w = arr[idx]
            cf = F.classifier_features(w)
            intensity = F.regression_intensity_features(w)
            rf_in = F.regressor_features(intensity, age=age_f, sex=gender, weight_kg=weight_f, height_cm=height_f)
            p = self.classify_features(cf).astype(np.float64)
            reg = np.maximum(self.regress_features(rf_in), self._min_met)
            active = p > self._threshold
            p_active[idx] = p
            met_if_active[idx] = reg
            is_active[idx] = active
            met[idx] = np.where(active, reg, self._sedentary_met)
            scores = self.signal_envelope.score(O.signal_feature_matrix(cf, intensity, O.acc_norm_median(w)))
            ood_signal[idx] = scores.ood_signal
            ood_range[idx] = scores.ood_range
            ood_gravity[idx] = scores.ood_gravity
            for k, j in enumerate(idx):
                worst[j] = names[int(scores.worst_feature[k])]
        return WristMetResult(
            met=met,
            p_active=p_active,
            ood_signal=ood_signal,
            ood_demographic=float(ood_demo),
            valid=valid,
            is_active=is_active,
            met_if_active=met_if_active,
            ood_range=ood_range,
            ood_gravity=ood_gravity,
            worst_feature=tuple(worst),
        )

    def predict_raw(
        self,
        acc_t_ms: np.ndarray,
        acc: np.ndarray,
        gyr: np.ndarray,
        gyr_t_ms: np.ndarray | None = None,
        *,
        age: float,
        sex: str | int | float,
        weight_kg: float,
        height_cm: float,
        acc_unit: str = "g",
        gyr_unit: str = "deg/s",
        axis_map: AxisMap | None = None,
        wrist: str = "right",
    ) -> tuple[RawWindows, WristMetResult]:
        """Convenience: raw WHOOP-style samples -> non-overlapping 60 s windows -> :meth:`predict_windows`."""
        raw = windows_from_raw(
            acc_t_ms,
            acc,
            gyr,
            gyr_t_ms,
            acc_unit=acc_unit,
            gyr_unit=gyr_unit,
            axis_map=axis_map,
            wrist=wrist,
            window_samples=self.window_samples,
            rate_hz=self.sample_rate_hz,
        )
        result = self.predict_windows(
            raw.windows, age=age, sex=sex, weight_kg=weight_kg, height_cm=height_cm
        )
        return raw, result


def _check_demographics(age: float, sex: str | int | float, weight_kg: float, height_cm: float) -> tuple[float, float, float, float]:
    gender = F.sex_to_gender(sex)
    vals = []
    for name, v in (("age", age), ("weight_kg", weight_kg), ("height_cm", height_cm)):
        f = float(v)
        if not np.isfinite(f) or f <= 0.0:
            raise ValueError(f"{name} must be a positive finite number, got {v!r}")
        vals.append(f)
    return vals[0], gender, vals[1], vals[2]
