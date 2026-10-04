"""Signal helpers for WristMET: resampling, frame conventions, windowing (numpy only).

Training data frame (verified against the Zenodo Phase 2 data, see the build notes
in ``artifacts/wristmet/manifest.json``): Fossil Sport Gen 4 (Wear OS) watch worn on the
*dominant* wrist, accelerometer in m/s^2 including gravity, gyroscope in rad/s,
20 Hz, channel order ``(gyr_x, gyr_y, gyr_z, acc_x, acc_y, acc_z)``. Left-handed
participants were mirrored to a right-wrist frame (``mirror_to_right_wrist``).

**Limitation that matters for deployment.** Nothing here proves that the axes of a
WHOOP strap are oriented like the axes of the Fossil watch used for training.
``AxisMap`` defaults to the identity, i.e. it *assumes* the strap frame equals the
watch frame. A wrong axis permutation or sign changes ``mean/median/min/max`` of the
gravity-bearing accelerometer axes and of the gyroscope axes; the classifier
features are not rotation invariant.

What the training frame looks like (median over windows of the 60 s mean
accelerometer vector, right-wrist frame, m/s^2; see ``frame_reference`` in the
manifest): walking or standing with the arms hanging ~ (+8.8, -3.9, 0.0), the
"Rest" class (the most frequent label) ~ (+1.1, -7.1, +4.1), typing at a desk
~ (-1.0, -4.4, +8.6), lying down ~ (-6.7, -1.0, +6.1). So the training watch's
x axis runs along the forearm (towards the elbow) when the arm hangs; this is
*measured*, not the Android "x to the right of the display" convention one would
assume. A WHOOP integration should check its own readings in these postures and
set ``AxisMap`` accordingly.

``WristMetModel.predict_windows`` reports an ``ood_signal`` that reacts when the
per-axis gravity components fall outside the range seen in training and when the
mean gravity direction was never seen in training, but it cannot detect every
wrong mapping (for example a sign flip of an axis whose training range is
symmetric, or a permutation that lands on directions that were also seen). The
model was also trained on the dominant wrist, while a strap is usually worn on
the non-dominant one.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

SAMPLE_RATE_HZ = 20.0
WINDOW_SECONDS = 60.0
WINDOW_SAMPLES = 1200

STANDARD_GRAVITY_MS2 = 9.80665  # Android SensorManager.GRAVITY_EARTH
DEG_TO_RAD = np.pi / 180.0

#: Channel positions inside a window ``[N, 6]`` that are negated to mirror a left
#: wrist onto a right wrist (Kyritsis et al., arXiv:2010.07051 Eq. 1): acc_x, gyr_y, gyr_z.
MIRROR_NEGATE_CHANNELS = (3, 1, 2)


def interpolate_at(
    times_ms: np.ndarray,
    values: np.ndarray,
    grid_ms: np.ndarray,
    gap_tolerance_ms: float | None = None,
) -> np.ndarray:
    """Linear interpolation of ``values`` (``[M, C]``) at ``grid_ms`` using the upstream arithmetic.

    The bracketing samples are found with ``searchsorted(side="left")`` and the value is
    evaluated as ``m * t + b`` with ``m = (s2 - s1) / (t2 - t1)``, ``b = s1 - m * t1``
    (``sort_resample_organize.interpolate``). Grid points that are not bracketed, or whose
    bracketing samples are more than ``gap_tolerance_ms`` apart, become NaN.
    """
    t = np.asarray(times_ms, dtype=np.float64)
    x = np.asarray(values, dtype=np.float64)
    grid = np.asarray(grid_ms, dtype=np.float64)
    n = t.shape[0]
    idx = np.clip(np.searchsorted(t, grid, side="left"), 1, n - 1)
    t1 = t[idx - 1]
    t2 = t[idx]
    s1 = x[idx - 1]
    s2 = x[idx]
    with np.errstate(invalid="ignore", divide="ignore"):
        slope = (s2 - s1) / (t2 - t1)[:, None]
        intercept = s1 - slope * t1[:, None]
        out = slope * grid[:, None] + intercept
    out[~((t1 <= grid) & (grid <= t2))] = np.nan
    if gap_tolerance_ms is not None:
        out[np.abs(t2 - t1) > gap_tolerance_ms] = np.nan
    return out


def resample_linear(
    times_ms: np.ndarray,
    values: np.ndarray,
    rate_hz: float = SAMPLE_RATE_HZ,
    gap_tolerance_ms: float | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """Reproduce upstream ``sort_resample_organize.resample`` (vectorised).

    The output grid starts at the first input timestamp (value copied) and then advances
    in steps of ``1000 / rate_hz`` ms up to the last full step not exceeding the last
    input timestamp. ``gap_tolerance_ms=None`` interpolates across any gap, which is what
    the shipped training data did. ``times_ms`` must be sorted ascending.
    Returns ``(times_out_ms, values_out)``.
    """
    t = np.asarray(times_ms, dtype=np.float64)
    x = np.asarray(values, dtype=np.float64)
    if x.ndim == 1:
        x = x[:, None]
    if t.ndim != 1 or t.shape[0] != x.shape[0]:
        raise ValueError("times_ms must be 1-D and match the first axis of values")
    if t.shape[0] < 2:
        return t.copy(), x.copy()
    step = 1000.0 / rate_hz
    n_steps = int(np.floor((t[-1] - t[0]) / step))
    grid = t[0] + np.arange(1, n_steps + 1) * step
    out = np.empty((grid.shape[0] + 1, x.shape[1]), dtype=np.float64)
    out[0] = x[0]
    if grid.size:
        out[1:] = interpolate_at(t, x, grid, gap_tolerance_ms)
    return np.concatenate([[t[0]], grid]), out


def mirror_to_right_wrist(windows: np.ndarray) -> np.ndarray:
    """Return a copy of ``windows`` (``[..., 6]``) with acc_x, gyr_y and gyr_z negated."""
    out = np.array(windows, dtype=np.float64, copy=True)
    out[..., list(MIRROR_NEGATE_CHANNELS)] *= -1.0
    return out


@dataclass(frozen=True)
class AxisMap:
    """Map a device's sensor axes onto the training-device frame.

    Model channel ``i`` of the accelerometer is ``acc_sign[i] * source_acc[:, acc_source[i]]``
    (same for the gyroscope). The default is the identity: **this is an assumption, not a
    verified property of the WHOOP strap** (see the module docstring).
    """

    acc_source: tuple[int, int, int] = (0, 1, 2)
    acc_sign: tuple[float, float, float] = (1.0, 1.0, 1.0)
    gyr_source: tuple[int, int, int] = (0, 1, 2)
    gyr_sign: tuple[float, float, float] = (1.0, 1.0, 1.0)

    def __post_init__(self) -> None:
        for name in ("acc_source", "gyr_source"):
            if sorted(getattr(self, name)) != [0, 1, 2]:
                raise ValueError(f"{name} must be a permutation of (0, 1, 2)")
        for name in ("acc_sign", "gyr_sign"):
            if any(s not in (-1.0, 1.0) for s in getattr(self, name)):
                raise ValueError(f"{name} entries must be +1 or -1")

    @property
    def is_identity(self) -> bool:
        return self == AxisMap()

    def apply(self, acc: np.ndarray, gyr: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        acc = np.asarray(acc, dtype=np.float64)
        gyr = np.asarray(gyr, dtype=np.float64)
        acc_out = acc[:, list(self.acc_source)] * np.asarray(self.acc_sign)
        gyr_out = gyr[:, list(self.gyr_source)] * np.asarray(self.gyr_sign)
        return acc_out, gyr_out


@dataclass
class RawWindows:
    """Output of :func:`windows_from_raw`."""

    windows: np.ndarray  # [n, window_samples, 6]; windows that span a gap contain NaN
    start_ms: np.ndarray  # [n] timestamp of the first sample of each window
    valid: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=bool))  # [n] no NaN


def to_dataset_units(
    acc: np.ndarray,
    gyr: np.ndarray,
    *,
    acc_unit: str = "g",
    gyr_unit: str = "deg/s",
) -> tuple[np.ndarray, np.ndarray]:
    """Convert to the training units (acc m/s^2 with gravity, gyr rad/s)."""
    acc = np.asarray(acc, dtype=np.float64)
    gyr = np.asarray(gyr, dtype=np.float64)
    if acc_unit == "g":
        acc = acc * STANDARD_GRAVITY_MS2
    elif acc_unit not in ("m/s2", "m/s^2"):
        raise ValueError(f"unsupported acc_unit {acc_unit!r}; use 'g' or 'm/s2'")
    if gyr_unit in ("deg/s", "dps", "deg/sec"):
        gyr = gyr * DEG_TO_RAD
    elif gyr_unit not in ("rad/s", "rad/sec"):
        raise ValueError(f"unsupported gyr_unit {gyr_unit!r}; use 'deg/s' or 'rad/s'")
    return acc, gyr


def _sorted_unique(t: np.ndarray, x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    finite = np.isfinite(t)
    t, x = t[finite], x[finite]
    order = np.argsort(t, kind="stable")
    t, x = t[order], x[order]
    if t.size:
        keep = np.concatenate([[True], np.diff(t) > 0.0])
        t, x = t[keep], x[keep]
    return t, x


def windows_from_raw(
    acc_t_ms: np.ndarray,
    acc: np.ndarray,
    gyr: np.ndarray,
    gyr_t_ms: np.ndarray | None = None,
    *,
    acc_unit: str = "g",
    gyr_unit: str = "deg/s",
    axis_map: AxisMap | None = None,
    wrist: str = "right",
    window_samples: int = WINDOW_SAMPLES,
    hop_samples: int | None = None,
    rate_hz: float = SAMPLE_RATE_HZ,
    gap_tolerance_ms: float | None = 500.0,
) -> RawWindows:
    """Turn raw WHOOP-style IMU samples into model windows.

    ``acc`` ``[M, 3]`` (default unit g) and ``gyr`` ``[M, 3]`` (default deg/s) at any
    sampling rate (typically 100 Hz) with timestamps in milliseconds. If ``gyr_t_ms``
    is ``None`` the gyroscope shares ``acc_t_ms``.

    Steps: finite-timestamp filter, stable sort and duplicate-timestamp removal;
    ``axis_map`` (assumed identity unless given); conversion to m/s^2 and rad/s;
    linear interpolation of both sensors onto one common ``rate_hz`` grid with the
    upstream arithmetic (``interpolate_at``; output samples inside a gap longer than
    ``gap_tolerance_ms`` become NaN); mirroring of a left wrist to the right-wrist
    frame; consecutive windows of ``window_samples`` samples (non-overlapping by default,
    like the upstream code). Only complete windows are returned; windows that contain NaN
    are flagged ``valid=False`` and should be fed to the model anyway only if you want a
    NaN result back.
    """
    if wrist not in ("right", "left"):
        raise ValueError("wrist must be 'right' or 'left'")
    axis_map = axis_map or AxisMap()
    acc_t = np.asarray(acc_t_ms, dtype=np.float64)
    gyr_t = acc_t if gyr_t_ms is None else np.asarray(gyr_t_ms, dtype=np.float64)
    acc = np.asarray(acc, dtype=np.float64)
    gyr = np.asarray(gyr, dtype=np.float64)
    if acc.shape != (acc_t.shape[0], 3) or gyr.shape != (gyr_t.shape[0], 3):
        raise ValueError("acc and gyr must have shape [M, 3] matching their timestamps")

    empty = RawWindows(np.empty((0, window_samples, 6)), np.empty(0), np.empty(0, dtype=bool))
    acc, gyr = axis_map.apply(acc, gyr)
    acc, gyr = to_dataset_units(acc, gyr, acc_unit=acc_unit, gyr_unit=gyr_unit)
    acc_t, acc = _sorted_unique(acc_t, acc)
    gyr_t, gyr = _sorted_unique(gyr_t, gyr)
    if acc_t.size < 2 or gyr_t.size < 2:
        return empty

    step = 1000.0 / rate_hz
    t0 = max(acc_t[0], gyr_t[0])
    t_end = min(acc_t[-1], gyr_t[-1])
    n_grid = int(np.floor((t_end - t0) / step)) + 1
    if n_grid < window_samples:
        return empty
    grid = t0 + np.arange(n_grid) * step
    acc_r = interpolate_at(acc_t, acc, grid, gap_tolerance_ms)
    gyr_r = interpolate_at(gyr_t, gyr, grid, gap_tolerance_ms)
    stacked = np.concatenate([gyr_r, acc_r], axis=1)  # (gyr_xyz, acc_xyz)
    if wrist == "left":
        stacked = mirror_to_right_wrist(stacked)

    hop = hop_samples or window_samples
    starts = np.arange(0, n_grid - window_samples + 1, hop)
    windows = np.stack([stacked[s : s + window_samples] for s in starts])
    valid = np.isfinite(windows).all(axis=(1, 2))
    return RawWindows(windows, grid[starts], valid)
