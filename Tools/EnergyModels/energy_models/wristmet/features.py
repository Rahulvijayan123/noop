"""WristMET feature functions (numpy only).

Exact re-implementations of the feature code in the public repository
https://github.com/HAbitsLab/WristBased-EE-Estimation (MIT, commit
3d3517cb95ef490d5e867ebf6a7207b8f7278788), so that a model trained on features
produced by the upstream code can be evaluated on features produced here.

A window is a float array ``[N, 6]`` with columns ordered
``(gyr_x, gyr_y, gyr_z, acc_x, acc_y, acc_z)``, sampled at 20 Hz
(N = 1200 for the 60 s model), in dataset-native units (accelerometer in
m/s^2 *including gravity*, gyroscope in rad/s; see ``preprocess.py``).

Reproduced upstream behaviour, including quirks that differ from the paper's
prose (every one of them is part of what the published model was trained on):

* The 42 classification features are, in this order, the statistics
  ``median, mean, max, min, range, std, rms`` (``helper_preprocess.py:158-175``),
  each computed over the six channels in column order (stat-major layout).
  ``std`` is the population standard deviation (ddof=0), ``rms`` is
  ``sqrt(mean(x**2))``.
* ``Intensity (RMSSD_l1)`` (``in-lab.py:165-197``): every accelerometer axis is
  divided by its own sum of absolute values (sklearn ``normalize(norm="l1")`` on
  a ``(3, N)`` matrix, i.e. per-axis), then
  ``sqrt(sum_i (dx_i^2 + dy_i^2 + dz_i^2) / N)``; the divisor is ``N`` (not
  ``N - 1``) because the loop runs over ``N - 1`` differences.
* ``Intensity (Freq)`` (``in-lab.py:199-227``): the signal is the accelerometer
  *magnitude with gravity* of samples ``1 .. N-1`` (the first sample is skipped),
  there is **no band-pass filter** (the paper describes one; the code has none),
  the one-sided FFT bins ``[: n // 2]`` are used (DC bin included), the second
  largest ``|FFT|`` value is picked (the DC bin is nearly always the largest, so
  this is the dominant non-DC bin) and its frequency is ``k / T`` with
  ``T = n / fs``. The upstream call hard-codes ``fs = 100`` although the data are
  sampled at 20 Hz, so the reported "frequency" is 5x the physical value. The
  hard-coded value is kept (``UPSTREAM_FREQ_FS``) because the regressor was
  trained on it.
* Demographic regression features (``in-lab.py:74-82, 491``): ``gender``
  (male = 1), ``age``, ``BMI``, ``Intensity (Freq)``, ``gender_age``,
  ``gender_BMI``, ``age_BMI``, ``age_gender_BMI``, ``Intensity (RMSSD_l1)``.
"""

from __future__ import annotations

import numpy as np

CHANNELS = ("gyr_x", "gyr_y", "gyr_z", "acc_x", "acc_y", "acc_z")
STATISTICS = ("median", "mean", "max", "min", "range", "std", "rms")
CLASSIFIER_FEATURE_NAMES = tuple(f"{stat}_{ch}" for stat in STATISTICS for ch in CHANNELS)
REGRESSOR_FEATURE_NAMES = (
    "gender",
    "age",
    "BMI",
    "Intensity (Freq)",
    "gender_age",
    "gender_BMI",
    "age_BMI",
    "age_gender_BMI",
    "Intensity (RMSSD_l1)",
)
DEMOGRAPHIC_FREE_REGRESSOR_FEATURE_NAMES = ("Intensity (Freq)", "Intensity (RMSSD_l1)")

SAMPLE_RATE_HZ = 20
UPSTREAM_FREQ_FS = 100.0
ACC_SLICE = slice(3, 6)
GYR_SLICE = slice(0, 3)


def _as_windows(windows: np.ndarray) -> np.ndarray:
    arr = np.asarray(windows, dtype=np.float64)
    if arr.ndim == 2:
        arr = arr[None]
    if arr.ndim != 3 or arr.shape[2] != 6:
        raise ValueError(f"windows must have shape [n, N, 6] or [N, 6], got {arr.shape}")
    return arr


def classifier_features(windows: np.ndarray) -> np.ndarray:
    """The 42 classification features for ``windows`` of shape ``[n, N, 6]`` -> ``[n, 42]``.

    Mirrors ``helper_preprocess.extract_features``: the statistics are reduced over
    the time axis of a C-contiguous ``(6, N)`` matrix per window, which is what
    makes the floating point summation order identical to the upstream code.
    """
    arr = _as_windows(windows)
    m = np.ascontiguousarray(np.transpose(arr, (0, 2, 1)))  # [n, 6, N]
    mx = np.max(m, axis=2)
    mn = np.min(m, axis=2)
    parts = (
        np.median(m, axis=2),
        np.mean(m, axis=2),
        mx,
        mn,
        mx - mn,
        np.std(m, axis=2),
        np.sqrt(np.mean(m**2, axis=2)),
    )
    return np.concatenate(parts, axis=1)


def rmssd_l1(acc: np.ndarray) -> float:
    """Upstream ``get_rmssd(df, norm="l1")`` for one window of accelerometer data ``[N, 3]``."""
    x = np.asarray(acc, dtype=np.float64)
    if x.ndim != 2 or x.shape[1] != 3 or x.shape[0] < 1:
        raise ValueError(f"acc must have shape [N, 3] with N >= 1, got {x.shape}")
    data = np.ascontiguousarray(x.T)  # (3, N), C-contiguous like np.array([accX, accY, accZ])
    norms = np.abs(data).sum(axis=1)
    norms = np.where(norms == 0.0, 1.0, norms)  # sklearn _handle_zeros_in_scale
    data = data / norms[:, None]
    diff = data[:, 1:] - data[:, :-1]
    # The upstream loop adds (dx^2, dy^2, dz^2) of successive differences left to right; an
    # accumulate over the interleaved squares reproduces that summation order bit for bit.
    total = float(np.cumsum((diff * diff).T.reshape(-1))[-1]) if diff.size else 0.0
    return float((total / data.shape[1]) ** 0.5)


def freq_intensity(acc: np.ndarray, fs: float = UPSTREAM_FREQ_FS, top: int = 1) -> float:
    """Upstream ``get_freq_intensity(df, fs, top)`` for one window of accelerometer data ``[N, 3]``."""
    x = np.asarray(acc, dtype=np.float64)
    if x.ndim != 2 or x.shape[1] != 3 or x.shape[0] < 1:
        raise ValueError(f"acc must have shape [N, 3] with N >= 1, got {x.shape}")
    y = np.sqrt(x[1:, 0] ** 2 + x[1:, 1] ** 2 + x[1:, 2] ** 2)
    n = y.shape[0]
    half = n // 2
    if half < top + 1:
        return float("nan")
    k = np.arange(n)
    period = n / fs
    frq = (k / period)[:half]
    spectrum = np.fft.fft(y) / n
    magnitude = np.abs(spectrum[:half])
    ranked = np.sort(magnitude)[::-1]
    target = ranked[top]
    return float(frq[int(np.argmax(magnitude == target))])


def regression_intensity_features(windows: np.ndarray) -> np.ndarray:
    """``[n, 2]`` array of (``Intensity (Freq)``, ``Intensity (RMSSD_l1)``) per window."""
    arr = _as_windows(windows)
    out = np.empty((arr.shape[0], 2), dtype=np.float64)
    for i in range(arr.shape[0]):
        acc = arr[i, :, ACC_SLICE]
        out[i, 0] = freq_intensity(acc)
        out[i, 1] = rmssd_l1(acc)
    return out


def demographic_features(age: float, sex: str | int | float, weight_kg: float, height_cm: float) -> dict[str, float]:
    """Scalar demographic inputs of the regressor.

    ``sex``: ``"male"``/``"m"``/``1`` -> 1.0, ``"female"``/``"f"``/``0`` -> 0.0
    (upstream: first letter ``"M"`` -> 1, everything else -> 0).
    """
    gender = sex_to_gender(sex)
    bmi = float(weight_kg) / (float(height_cm) / 100.0) ** 2
    age = float(age)
    return {
        "gender": gender,
        "age": age,
        "BMI": bmi,
        "gender_age": age * gender,
        "gender_BMI": bmi * gender,
        "age_BMI": age * bmi,
        "age_gender_BMI": age * gender * bmi,
    }


def sex_to_gender(sex: str | int | float) -> float:
    if isinstance(sex, str):
        s = sex.strip().lower()
        if s in ("m", "male", "man", "1"):
            return 1.0
        if s in ("f", "female", "woman", "0"):
            return 0.0
        raise ValueError(f"unrecognised sex {sex!r}; use 'male' or 'female'")
    if float(sex) in (0.0, 1.0):
        return float(sex)
    raise ValueError(f"unrecognised sex {sex!r}; use 'male'/'female' or 1/0")


def regressor_features(
    intensity: np.ndarray,
    *,
    age: float,
    sex: str | int | float,
    weight_kg: float,
    height_cm: float,
) -> np.ndarray:
    """Assemble the 9 regression features (order ``REGRESSOR_FEATURE_NAMES``) -> ``[n, 9]``.

    ``intensity`` is the ``[n, 2]`` output of :func:`regression_intensity_features`.
    """
    intensity = np.asarray(intensity, dtype=np.float64).reshape(-1, 2)
    demo = demographic_features(age, sex, weight_kg, height_cm)
    n = intensity.shape[0]
    out = np.empty((n, len(REGRESSOR_FEATURE_NAMES)), dtype=np.float64)
    out[:, 0] = demo["gender"]
    out[:, 1] = demo["age"]
    out[:, 2] = demo["BMI"]
    out[:, 3] = intensity[:, 0]
    out[:, 4] = demo["gender_age"]
    out[:, 5] = demo["gender_BMI"]
    out[:, 6] = demo["age_BMI"]
    out[:, 7] = demo["age_gender_BMI"]
    out[:, 8] = intensity[:, 1]
    return out
