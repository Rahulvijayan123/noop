"""Out-of-distribution scores for WristMET (numpy only).

The model was trained on 26 adults (BMI 30-46, ages 25-64) wearing a Fossil Sport Gen 4 watch
on the dominant wrist, in a scripted lab session. Two scalars quantify how far an input is from that
training distribution. They are *heuristics derived from the training envelope*, not calibrated
probabilities, and a low score does not certify that the estimate is accurate (the model's
held-out error is large, see ``manifest.json``).

Signal score (per window) -- ``ood_signal`` in [0, 1]
------------------------------------------------------
Let ``v`` be the 46 signal descriptors of a window (names in ``SIGNAL_FEATURE_NAMES``): the 42
classifier features (six channels x median/mean/max/min/range/std/rms), the two intensity features of
the regressor, ``acc_mean_norm = ||(mean_acc_x, mean_acc_y, mean_acc_z)||`` and
``acc_norm_median = median_t ||acc_t||`` (the typical accelerometer magnitude, which is the gravity
magnitude, 9.8 m/s^2, in almost every window; it makes a wrong accelerometer unit or scale obvious).
The envelope stores, per descriptor, the training minimum/maximum and the 0.5th / 99.5th percentiles
(``numpy.percentile``, linear interpolation) over all training windows.

1. *Range excess.* With ``lo_f = p0.5``, ``hi_f = p99.5`` and
   ``w_f = max(hi_f - lo_f, 1e-6 + 1e-3 * max(|lo_f|, |hi_f|))``::

       e_f      = max(0, lo_f - v_f, v_f - hi_f) / w_f
       s_range  = 1 - exp(-max_f(e_f) / E0)           (E0 = 0.5)

   A window whose worst descriptor sits ``E0`` envelope-widths outside the 0.5-99.5 % band scores 0.63;
   one that is a full width outside scores 0.86; ten widths outside, 1.0. Per-axis gravity components are covered
   because ``median/mean/max/min`` of every accelerometer axis are descriptors, so a strap whose gravity axis
   falls outside the training range of that axis is flagged. Unit errors (g instead of m/s^2, deg/s
   instead of rad/s) change ``acc_mean_norm`` / gyroscope magnitudes by 10x / 57x and are flagged.

2. *Gravity direction.* If ``acc_mean_norm >= 1 m/s^2`` the unit vector ``u`` of the window's mean
   acceleration is compared with the unit vectors of all training windows (stored in the envelope);
   ``theta`` is the angle (degrees) to the nearest one::

       s_gravity = clip((theta - theta_ok) / (theta_max - theta_ok), 0, 1)

   ``theta_ok`` is the 99th percentile of ``theta`` for held-out participants in the leave-one-participant-out
   evaluation rounded up to a multiple of 5 degrees (so roughly 1 % of unseen *training-like* windows
   exceed it), ``theta_max = theta_ok + 30`` degrees. This catches orientations never seen in training even
   if every individual axis stays within its marginal range (for example a strap rotated by 90 degrees).
   It cannot detect a frame error that maps the gravity directions seen in training onto other directions
   that were also seen.

3. ``ood_signal = max(s_range, s_gravity)``; windows that cannot be evaluated (NaN) score 1.

Suggested reading: below 0.1 typical of the training data, 0.25-0.5 marginal, 0.5 or more outside what the model
has seen (treat the estimate as unreliable).

Demographic score (scalar) -- ``ood_demographic`` in [0, 1]
-------------------------------------------------------------
The regressor sees ``gender, age, BMI`` and products of them but only 26 distinct people. With
``age_min/age_max/age_sd`` and ``bmi_min/bmi_max/bmi_sd`` of the training participants::

       z_age = max(0, age_min - age, age - age_max) / age_sd
       z_bmi = max(0, bmi_min - bmi, bmi - bmi_max) / bmi_sd
       ood_demographic = 1 - exp(-sqrt(z_age^2 + z_bmi^2))

and 1 if the sex was not present among the training participants. Zero means "inside the age x BMI
box of the training participants", not "well supported": the forest was fit on 26 individuals.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .features import CLASSIFIER_FEATURE_NAMES

INTENSITY_FEATURE_NAMES = ("Intensity (Freq)", "Intensity (RMSSD_l1)")
DERIVED_FEATURE_NAMES = ("acc_mean_norm", "acc_norm_median")
SIGNAL_FEATURE_NAMES = CLASSIFIER_FEATURE_NAMES + INTENSITY_FEATURE_NAMES + DERIVED_FEATURE_NAMES

SIGNAL_FORMULA = (
    "descriptors v (46): 42 classifier features, Intensity (Freq), Intensity (RMSSD_l1), "
    "acc_mean_norm = ||mean acc||, acc_norm_median = median_t ||acc_t||. For each descriptor f: "
    "lo_f = p0.5, hi_f = p99.5 of the training windows, w_f = max(hi_f - lo_f, 1e-6 + 1e-3*max(|lo_f|,|hi_f|)), "
    "e_f = max(0, lo_f - v_f, v_f - hi_f) / w_f; s_range = 1 - exp(-max_f(e_f) / 0.5). "
    "Gravity direction: if ||mean acc|| >= 1 m/s^2, theta = angle in degrees from the unit vector of the mean "
    "acceleration to the nearest training-window unit vector; s_gravity = clip((theta - theta_ok) / 30, 0, 1) "
    "with theta_ok = 99th percentile of the leave-one-participant-out theta rounded up to 5 degrees. "
    "ood_signal = max(s_range, s_gravity); windows containing NaN/inf score 1."
)
DEMOGRAPHIC_FORMULA = (
    "z_age = max(0, age_min - age, age - age_max) / age_sd; z_bmi = max(0, bmi_min - bmi, bmi - bmi_max) / bmi_sd "
    "(min/max/sd over the 26 training participants, sd with ddof=1); "
    "ood_demographic = 1 - exp(-sqrt(z_age^2 + z_bmi^2)); 1 if the sex does not occur in the training participants."
)

LOW_PERCENTILE = 0.5
HIGH_PERCENTILE = 99.5
RANGE_SCALE_E0 = 0.5
GRAVITY_MIN_NORM = 1.0
GRAVITY_ANGLE_SPAN_DEG = 30.0
ACC_MEAN_COLUMNS = tuple(CLASSIFIER_FEATURE_NAMES.index(f"mean_acc_{axis}") for axis in "xyz")
_ANGLE_CHUNK = 256  # windows per block when comparing with the ~2,000 training gravity directions


def acc_norm_median(windows: np.ndarray) -> np.ndarray:
    """Median over time of the accelerometer magnitude, ``[n, N, 6]`` -> ``[n]``."""
    acc = np.asarray(windows, dtype=np.float64)[:, :, 3:6]
    return np.median(np.sqrt(np.sum(acc * acc, axis=2)), axis=1)


def signal_feature_matrix(
    classifier_features: np.ndarray, intensity: np.ndarray, acc_norm_median_: np.ndarray
) -> np.ndarray:
    """``[n, 46]`` descriptors from the ``[n, 42]`` classifier features, ``[n, 2]`` intensity features and ``[n]``
    median accelerometer magnitude (see :func:`acc_norm_median`)."""
    cf = np.asarray(classifier_features, dtype=np.float64)
    it = np.asarray(intensity, dtype=np.float64).reshape(-1, 2)
    g = cf[:, list(ACC_MEAN_COLUMNS)]
    norm = np.sqrt(np.sum(g * g, axis=1, keepdims=True))
    med = np.asarray(acc_norm_median_, dtype=np.float64).reshape(-1, 1)
    return np.concatenate([cf, it, norm, med], axis=1)


def gravity_unit_vectors(classifier_features: np.ndarray, min_norm: float = GRAVITY_MIN_NORM) -> np.ndarray:
    """Unit vectors of the mean acceleration (``[n, 3]``); NaN rows where the mean is shorter than ``min_norm``."""
    g = np.asarray(classifier_features, dtype=np.float64)[:, list(ACC_MEAN_COLUMNS)]
    norm = np.sqrt(np.sum(g * g, axis=1, keepdims=True))
    with np.errstate(invalid="ignore", divide="ignore"):
        u = g / norm
    u[~(norm[:, 0] >= min_norm)] = np.nan
    return u


def nearest_angle_deg(unit_vectors: np.ndarray, reference: np.ndarray) -> np.ndarray:
    """Angle in degrees from each row of ``unit_vectors`` to its nearest row in ``reference`` (NaN rows stay NaN)."""
    u = np.asarray(unit_vectors, dtype=np.float64)
    out = np.full(u.shape[0], np.nan)
    ok = np.nonzero(np.all(np.isfinite(u), axis=1))[0]
    if ok.size and reference.shape[0]:
        ref = reference / np.sqrt(np.sum(reference * reference, axis=1, keepdims=True))
        # Three explicit products rather than ``u @ ref.T``: numpy's BLAS-backed matmul raises spurious floating-point
        # warnings on some macOS builds, and the explicit sum is bit-reproducible across BLAS implementations.
        for lo in range(0, ok.size, _ANGLE_CHUNK):
            idx = ok[lo : lo + _ANGLE_CHUNK]
            v = u[idx]
            cos = v[:, 0:1] * ref[:, 0] + v[:, 1:2] * ref[:, 1] + v[:, 2:3] * ref[:, 2]
            out[idx] = np.degrees(np.arccos(np.clip(cos.max(axis=1), -1.0, 1.0)))
    return out


@dataclass(frozen=True)
class SignalScores:
    ood_signal: np.ndarray
    ood_range: np.ndarray
    ood_gravity: np.ndarray
    worst_feature: np.ndarray  # index into SIGNAL_FEATURE_NAMES of the largest range excess
    gravity_angle_deg: np.ndarray


@dataclass(frozen=True)
class SignalEnvelope:
    names: tuple[str, ...]
    minimum: np.ndarray
    maximum: np.ndarray
    p_low: np.ndarray
    p_high: np.ndarray
    gravity_unit_vectors: np.ndarray  # [m, 3] training windows with ||mean acc|| >= gravity_min_norm
    gravity_min_norm: float
    angle_ok_deg: float
    angle_max_deg: float
    range_scale: float
    n_windows: int

    @property
    def width(self) -> np.ndarray:
        floor = 1e-6 + 1e-3 * np.maximum(np.abs(self.p_low), np.abs(self.p_high))
        return np.maximum(self.p_high - self.p_low, floor)

    @classmethod
    def fit(
        cls,
        features: np.ndarray,
        gravity_vectors: np.ndarray,
        *,
        angle_ok_deg: float,
        angle_span_deg: float = GRAVITY_ANGLE_SPAN_DEG,
        range_scale: float = RANGE_SCALE_E0,
        gravity_min_norm: float = GRAVITY_MIN_NORM,
    ) -> "SignalEnvelope":
        f = np.asarray(features, dtype=np.float64)
        if f.ndim != 2 or f.shape[1] != len(SIGNAL_FEATURE_NAMES):
            raise ValueError(f"features must be [n, {len(SIGNAL_FEATURE_NAMES)}], got {f.shape}")
        lo, hi = np.percentile(f, [LOW_PERCENTILE, HIGH_PERCENTILE], axis=0)
        gv = np.asarray(gravity_vectors, dtype=np.float64)
        gv = np.round(gv[np.all(np.isfinite(gv), axis=1)], 4)  # stored with 4 decimals in the artifact
        return cls(
            names=SIGNAL_FEATURE_NAMES,
            minimum=f.min(axis=0),
            maximum=f.max(axis=0),
            p_low=lo,
            p_high=hi,
            gravity_unit_vectors=gv,
            gravity_min_norm=float(gravity_min_norm),
            angle_ok_deg=float(angle_ok_deg),
            angle_max_deg=float(angle_ok_deg + angle_span_deg),
            range_scale=float(range_scale),
            n_windows=int(f.shape[0]),
        )

    def score(self, features: np.ndarray) -> SignalScores:
        """Score ``[n, 46]`` descriptors (see :func:`signal_feature_matrix`). Rows with non-finite values score 1."""
        f = np.asarray(features, dtype=np.float64)
        finite = np.all(np.isfinite(f), axis=1)
        safe = np.where(finite[:, None], f, 0.0)
        excess = np.maximum(np.maximum(self.p_low - safe, safe - self.p_high), 0.0) / self.width
        e_max = excess.max(axis=1)
        worst = excess.argmax(axis=1)
        s_range = 1.0 - np.exp(-e_max / self.range_scale)
        u = gravity_unit_vectors(safe[:, :42], self.gravity_min_norm)
        theta = nearest_angle_deg(u, self.gravity_unit_vectors)
        s_grav = np.clip(
            (np.nan_to_num(theta, nan=0.0) - self.angle_ok_deg) / (self.angle_max_deg - self.angle_ok_deg), 0.0, 1.0
        )
        combined = np.maximum(s_range, s_grav)
        s_range = np.where(finite, s_range, 1.0)
        s_grav = np.where(finite, s_grav, 1.0)
        combined = np.where(finite, combined, 1.0)
        return SignalScores(combined, s_range, s_grav, worst, theta)

    def to_dict(self) -> dict:
        def stat(a: np.ndarray) -> list[float]:
            return [float(x) for x in a]

        return {
            "n_windows": self.n_windows,
            "percentiles": [LOW_PERCENTILE, HIGH_PERCENTILE],
            "features": {
                name: {"min": float(self.minimum[i]), "max": float(self.maximum[i]),
                       "p0.5": float(self.p_low[i]), "p99.5": float(self.p_high[i])}
                for i, name in enumerate(self.names)
            },
            "gravity": {
                "min_norm": self.gravity_min_norm,
                "angle_ok_deg": self.angle_ok_deg,
                "angle_max_deg": self.angle_max_deg,
                "unit_vectors": [[round(float(x), 4) for x in row] for row in self.gravity_unit_vectors],
            },
            "range_scale_e0": self.range_scale,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "SignalEnvelope":
        feats = d["features"]
        names = tuple(feats.keys())
        if names != SIGNAL_FEATURE_NAMES:
            raise ValueError("signal envelope feature names/order do not match this version of the code")
        col = lambda key: np.array([feats[n][key] for n in names], dtype=np.float64)  # noqa: E731
        g = d["gravity"]
        return cls(
            names=names,
            minimum=col("min"),
            maximum=col("max"),
            p_low=col("p0.5"),
            p_high=col("p99.5"),
            gravity_unit_vectors=np.asarray(g["unit_vectors"], dtype=np.float64).reshape(-1, 3),
            gravity_min_norm=float(g["min_norm"]),
            angle_ok_deg=float(g["angle_ok_deg"]),
            angle_max_deg=float(g["angle_max_deg"]),
            range_scale=float(d["range_scale_e0"]),
            n_windows=int(d["n_windows"]),
        )


@dataclass(frozen=True)
class DemographicEnvelope:
    n_participants: int
    age_min: float
    age_max: float
    age_mean: float
    age_sd: float
    bmi_min: float
    bmi_max: float
    bmi_mean: float
    bmi_sd: float
    sex_counts: dict

    @classmethod
    def fit(cls, age: np.ndarray, bmi: np.ndarray, gender: np.ndarray) -> "DemographicEnvelope":
        age = np.asarray(age, dtype=np.float64)
        bmi = np.asarray(bmi, dtype=np.float64)
        gender = np.asarray(gender)
        return cls(
            n_participants=int(age.size),
            age_min=float(age.min()),
            age_max=float(age.max()),
            age_mean=float(age.mean()),
            age_sd=float(age.std(ddof=1)),
            bmi_min=float(bmi.min()),
            bmi_max=float(bmi.max()),
            bmi_mean=float(bmi.mean()),
            bmi_sd=float(bmi.std(ddof=1)),
            sex_counts={"female": int((gender == 0).sum()), "male": int((gender == 1).sum())},
        )

    def score(self, age: float, bmi: float, gender: float) -> float:
        z_age = max(0.0, self.age_min - age, age - self.age_max) / self.age_sd
        z_bmi = max(0.0, self.bmi_min - bmi, bmi - self.bmi_max) / self.bmi_sd
        score = 1.0 - float(np.exp(-np.hypot(z_age, z_bmi)))
        key = "male" if gender == 1.0 else "female"
        if self.sex_counts.get(key, 0) == 0:
            return 1.0
        return float(min(max(score, 0.0), 1.0))

    def to_dict(self) -> dict:
        return {
            "n_participants": self.n_participants,
            "age": {"min": self.age_min, "max": self.age_max, "mean": self.age_mean, "sd": self.age_sd},
            "bmi": {"min": self.bmi_min, "max": self.bmi_max, "mean": self.bmi_mean, "sd": self.bmi_sd},
            "sex_counts": dict(self.sex_counts),
            "sd_ddof": 1,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "DemographicEnvelope":
        return cls(
            n_participants=int(d["n_participants"]),
            age_min=float(d["age"]["min"]),
            age_max=float(d["age"]["max"]),
            age_mean=float(d["age"]["mean"]),
            age_sd=float(d["age"]["sd"]),
            bmi_min=float(d["bmi"]["min"]),
            bmi_max=float(d["bmi"]["max"]),
            bmi_mean=float(d["bmi"]["mean"]),
            bmi_sd=float(d["bmi"]["sd"]),
            sex_counts=dict(d["sex_counts"]),
        )
