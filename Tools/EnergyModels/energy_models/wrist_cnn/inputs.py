"""Input conventions and window builder for the wrist CNN.

What the pretrained weights actually expect (measured on the public sample windows,
see README.md for the evidence):

* units: **g** (ActiGraph GT3X+ raw export: 3 decimals, steps of 3-4 mg, rails at +-8 g, largest
  sample value 7.996 g);
* **gravity included**, no filtering, no scaling or standardisation (``feature_normalize`` in
  upstream ``utils.py`` is never called);
* 100 Hz, 6000-sample (60 s) windows, 50 % overlap in training;
* the **upstream layout**: ``preprocess/prepare_train_data.py`` builds each window as
  ``np.asarray([xs, ys, zs]).reshape(6000, 3)`` *without a transpose*. The array the network
  sees is therefore the three axes concatenated in time, ``flat = [x_0..x_5999, y_0.., z_0..]``,
  re-chopped into rows of three consecutive samples (row r = ``flat[3r:3r+3]``). It is NOT
  ``[time, axis]``. The pretrained weights were trained on that layout, so inference must
  reproduce it; ``prepare_windows`` does so by default.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

from .spec import N_AXES, SAMPLE_RATE_HZ, SENSOR_RANGE_G, WINDOW_SAMPLES

LAYOUTS = ("upstream", "natural")


def to_upstream_layout(natural: np.ndarray) -> np.ndarray:
    """[n, T, 3] with columns = (x, y, z) at each time step -> the layout the CNN was trained on."""
    a = np.asarray(natural)
    if a.ndim != 3 or a.shape[2] != N_AXES:
        raise ValueError(f"expected [n, T, {N_AXES}] (time, axis); got {a.shape}")
    n, t, _ = a.shape
    return np.ascontiguousarray(np.swapaxes(a, 1, 2)).reshape(n, t, N_AXES)


def from_upstream_layout(model_windows: np.ndarray) -> np.ndarray:
    """Inverse of :func:`to_upstream_layout`: recover [n, T, 3] = (time, axis)."""
    a = np.asarray(model_windows)
    if a.ndim != 3 or a.shape[2] != N_AXES:
        raise ValueError(f"expected [n, T, {N_AXES}] in upstream layout; got {a.shape}")
    n, t, _ = a.shape
    return np.ascontiguousarray(np.swapaxes(a.reshape(n, N_AXES, t), 1, 2))


def apply_axis_transform(acc: np.ndarray, r: np.ndarray) -> np.ndarray:
    """Rotate/permute/flip device axes: ``out[..., i] = sum_j r[i, j] * acc[..., j]`` (float32)."""
    rm = np.asarray(r, dtype=np.float32)
    if rm.shape != (N_AXES, N_AXES):
        raise ValueError("axis transform must be 3x3")
    a = np.asarray(acc, dtype=np.float32)
    return np.einsum("...j,ij->...i", a, rm, optimize=False)    # einsum: no BLAS, so no spurious FP flags


def axes_major(windows: np.ndarray, layout: str = "upstream") -> np.ndarray:
    """[n, 3, T] view/array of per-axis time series (x, y, z) for either layout."""
    a = np.asarray(windows)
    if layout == "upstream":
        n, t, _ = a.shape
        return a.reshape(n, N_AXES, t)
    if layout == "natural":
        return np.swapaxes(a, 1, 2)
    raise ValueError(f"layout must be one of {LAYOUTS}")


QUIET_MAX_STD_G = 0.03
QUIET_GRAVITY_TOL_G = 0.1
# Regression-head output on the public sample's quiet windows (per-axis std < 0.03 g, n = 116 of 1 292):
# mean 1.402, sd 0.010, range 1.380..1.416 MET. A skipped quiet window can be filled with this value.
QUIET_MET_BASELINE = 1.402


def quiet_mask(
    windows: np.ndarray,
    layout: str = "upstream",
    *,
    max_std_g: float = QUIET_MAX_STD_G,
    gravity_tol_g: float = QUIET_GRAVITY_TOL_G,
) -> np.ndarray:
    """True for windows that are motionless and look like 1 g of gravity: cheap candidates for ``skip=``.

    A window is quiet when every axis has std < ``max_std_g`` AND the median vector magnitude is
    within ``gravity_tol_g`` of 1 g (so unit or scale mistakes are never silently skipped).
    Non-finite windows are never quiet. For such windows the regression head returns
    ``QUIET_MET_BASELINE`` +- 0.02 MET on the public sample; the classification head is less
    constant (P(sedentary) as low as 0.31), so only use the shortcut for MET.
    """
    a = np.asarray(windows)
    if a.ndim != 3 or a.shape[2] != N_AXES:
        raise ValueError(f"windows must have shape [n, T, {N_AXES}]; got {a.shape}")
    n = a.shape[0]
    quiet = np.zeros(n, dtype=bool)
    for s in range(0, n, 64):
        x = axes_major(np.asarray(a[s : s + 64], dtype=np.float32), layout)
        finite = np.isfinite(x).all(axis=(1, 2))
        calm = finite & (x.std(axis=2, dtype=np.float64) < max_std_g).all(axis=1)
        for i in np.flatnonzero(calm):
            vm = np.sqrt((x[i] * x[i]).sum(axis=0, dtype=np.float32))
            quiet[s + i] = abs(float(np.median(vm)) - 1.0) <= gravity_tol_g
    return quiet


@dataclass(frozen=True)
class PreparedWindows:
    windows: np.ndarray           # [n, 6000, 3] float32 (upstream layout unless layout="natural")
    start_index: np.ndarray       # [n] int64, index of each window's first sample in the input
    valid: np.ndarray             # [n] bool, False => do not run the model (windows keep their NaNs)
    missing_fraction: np.ndarray  # [n] float32, share of samples with a non-finite axis
    longest_gap: np.ndarray       # [n] int32, longest run of consecutive missing samples
    clipped_fraction: np.ndarray  # [n] float32, share of samples clipped to +-clip_g
    layout: str
    fs: float
    step_samples: int
    grid_t0: float | None = None  # timestamp of sample 0 when built from timestamps

    @property
    def n(self) -> int:
        return int(self.windows.shape[0])

    def start_time_s(self) -> np.ndarray:
        """Window start times (seconds) if built from timestamps, else sample-index / fs."""
        t0 = 0.0 if self.grid_t0 is None else self.grid_t0
        return t0 + self.start_index / self.fs


def regularize_timestamps(
    t_s: np.ndarray,
    acc_g: np.ndarray,
    *,
    fs: float = SAMPLE_RATE_HZ,
    max_gap_s: float = 0.5,
) -> tuple[float, np.ndarray]:
    """Resample irregular ``(t_s, acc_g[N, 3])`` onto a uniform ``fs`` grid starting at ``t_s[0]``.

    Linear interpolation between neighbouring samples; grid points whose bracketing samples are
    more than ``max_gap_s`` apart (or that lie outside the data) become NaN, so dropped packets
    are visible as gaps instead of being papered over.
    """
    t = np.asarray(t_s, dtype=np.float64)
    a = np.asarray(acc_g, dtype=np.float32)
    if t.ndim != 1 or a.ndim != 2 or a.shape != (t.shape[0], N_AXES):
        raise ValueError(f"need t_s [N] and acc_g [N, {N_AXES}]; got {t.shape} and {a.shape}")
    keep = np.isfinite(t)
    t, a = t[keep], a[keep]
    if t.size < 2:
        raise ValueError("need at least two timestamped samples")
    if np.any(np.diff(t) < 0):
        raise ValueError("timestamps must be sorted in non-decreasing order")
    t, first = np.unique(t, return_index=True)
    a = a[first]
    t0 = float(t[0])
    n_grid = int(np.floor((t[-1] - t0) * fs + 1e-9)) + 1
    grid = t0 + np.arange(n_grid, dtype=np.float64) / fs
    right = np.clip(np.searchsorted(t, grid, side="left"), 1, t.size - 1)
    left = right - 1
    span = t[right] - t[left]
    frac = np.divide(grid - t[left], span, out=np.zeros_like(grid), where=span > 0)
    out = a[left] * (1.0 - frac)[:, None].astype(np.float32) + a[right] * frac[:, None].astype(np.float32)
    # exact hits keep their sample (avoids 0 * NaN contaminating a good sample next to a NaN one)
    exact = grid == t[right]
    out[exact] = a[right[exact]]
    exact_left = grid == t[left]
    out[exact_left] = a[left[exact_left]]
    gap = span > (max_gap_s + 1e-9)
    out[gap & ~(exact | exact_left)] = np.nan
    return t0, out


def _longest_run(mask: np.ndarray) -> int:
    if not mask.any():
        return 0
    d = np.diff(np.concatenate(([0], mask.astype(np.int8), [0])))
    return int((np.flatnonzero(d == -1) - np.flatnonzero(d == 1)).max())


def prepare_windows(
    acc_g_100hz: np.ndarray,
    *,
    timestamps: np.ndarray | None = None,
    fs: float = SAMPLE_RATE_HZ,
    window_s: float = 60.0,
    step_s: float = 60.0,
    start: int = 0,
    max_gap_s: float = 0.5,
    max_missing_frac: float = 0.05,
    clip_g: float | None = SENSOR_RANGE_G,
    axis_transform: np.ndarray | None = None,
    layout: str = "upstream",
) -> PreparedWindows:
    """Cut a continuous 100 Hz tri-axial recording (g, gravity included) into CNN windows.

    ``acc_g_100hz``: [N, 3] columns (x, y, z) in g on a uniform ``fs`` grid; missing samples are
    NaN. If ``timestamps`` (seconds, [N]) is given the data are first resampled onto a uniform
    grid (see :func:`regularize_timestamps`) and ``start_index`` refers to that grid.

    Windows are ``window_s`` long, start every ``step_s`` seconds (``step_s=60`` -> one
    non-overlapping window per minute, ``step_s=30`` -> the 50 % overlap used in training), and
    never straddle the end of the data. A window is ``valid`` only if its missing-sample share is
    <= ``max_missing_frac`` and its longest gap <= ``max_gap_s``; missing samples inside valid
    windows are filled by linear interpolation (edges hold the nearest value), invalid windows are
    returned untouched (NaN preserved) so they cannot be fed to the model by accident.

    ``clip_g`` emulates the +-8 g rail of the training sensor (``None`` disables). ``axis_transform``
    is an optional 3x3 matrix ``R`` applied as ``acc @ R.T`` (research hook for mapping a device's
    axes onto the ActiGraph wrist convention; the correct mapping for WHOOP is not established).

    ``layout="upstream"`` (default) returns what ``WristCNN.predict`` expects; ``"natural"`` returns
    [n, T, 3] = (time, axis) for analysis only.
    """
    if layout not in LAYOUTS:
        raise ValueError(f"layout must be one of {LAYOUTS}")
    window = int(round(window_s * fs))
    step = int(round(step_s * fs))
    if abs(window - window_s * fs) > 1e-6 or abs(step - step_s * fs) > 1e-6:
        raise ValueError("window_s * fs and step_s * fs must be whole numbers of samples")
    if window < 1 or step < 1:
        raise ValueError("window and step must be positive")
    if layout == "upstream" and window != WINDOW_SAMPLES:
        raise ValueError(f"the pretrained CNN needs {WINDOW_SAMPLES}-sample windows (60 s at {SAMPLE_RATE_HZ} Hz)")
    max_gap = int(round(max_gap_s * fs))

    grid_t0: float | None = None
    if timestamps is not None:
        grid_t0, acc = regularize_timestamps(timestamps, acc_g_100hz, fs=fs, max_gap_s=max_gap_s)
    else:
        acc = np.asarray(acc_g_100hz, dtype=np.float32)
    if acc.ndim != 2 or acc.shape[1] != N_AXES:
        raise ValueError(f"acc_g_100hz must be [N, {N_AXES}] (columns x, y, z); got {acc.shape}")
    if axis_transform is not None:
        with np.errstate(invalid="ignore"):  # NaN samples are legitimate here
            acc = apply_axis_transform(acc, axis_transform)
    if start < 0:
        raise ValueError("start must be >= 0")

    n_total = acc.shape[0]
    n_win = 0 if n_total - start < window else (n_total - start - window) // step + 1
    starts = (start + step * np.arange(n_win)).astype(np.int64)
    if n_win == 0:
        empty = np.empty((0, window, N_AXES), dtype=np.float32)
        return PreparedWindows(empty, starts, np.zeros(0, bool), np.zeros(0, np.float32), np.zeros(0, np.int32),
                               np.zeros(0, np.float32), layout, float(fs), step, grid_t0)

    axes = sliding_window_view(acc[start:], window, axis=0)[::step][:n_win]      # [n, 3, T] view
    windows = np.array(axes, dtype=np.float32, copy=True)                        # axes-major == upstream flat order
    bad = ~np.isfinite(windows).all(axis=1)                                      # [n, T]
    missing_fraction = bad.mean(axis=1).astype(np.float32)
    longest_gap = np.zeros(n_win, dtype=np.int32)
    for i in np.flatnonzero(bad.any(axis=1)):
        longest_gap[i] = _longest_run(bad[i])
    valid = (missing_fraction <= max_missing_frac) & (missing_fraction < 1.0) & (longest_gap <= max_gap)

    for i in np.flatnonzero(valid & bad.any(axis=1)):
        t_idx = np.arange(window)
        good = ~bad[i]
        for ax in range(N_AXES):
            windows[i, ax] = np.interp(t_idx, t_idx[good], windows[i, ax, good])

    clipped_fraction = np.zeros(n_win, dtype=np.float32)
    if clip_g is not None:
        over = np.abs(windows) > clip_g                                          # NaN compares False
        clipped_fraction = over.any(axis=1).mean(axis=1).astype(np.float32)
        np.clip(windows, -clip_g, clip_g, out=windows)                           # NaN stays NaN

    if layout == "upstream":
        windows = windows.reshape(n_win, window, N_AXES)                         # no transpose: the upstream quirk
    else:
        windows = np.ascontiguousarray(np.swapaxes(windows, 1, 2))
    return PreparedWindows(windows, starts, valid, missing_fraction, longest_gap, clipped_fraction,
                           layout, float(fs), step, grid_t0)
