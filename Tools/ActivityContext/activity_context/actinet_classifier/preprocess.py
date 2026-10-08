"""``actinet-prep-1``: WHOOP NPB1 raw IMU -> ActiNet 30 s epochs (ACTINET_CLASSIFIER.md §2).

Upstream's default path is actinet 0.7.2 ``actinet.read`` -> actipy 3.8.0 ``process`` ->
``ActivityClassifier.predict_from_frame``. The table gives each step and what this revision does with it. Any
change here is a new preprocessing version, and the preprocessing digest in the cache identity changes with it.

==================  ===========================================================  ==================================
upstream step       upstream behaviour (code, not the methods page)              actinet-prep-1
==================  ===========================================================  ==================================
read                CSV x/y/z parsed as float32 g; duplicate times dropped        NPB1 i16 x 1/4096 g, exact in
                    (first kept)                                                  float32; duplicate second refused
lowpass             ``lowpass_hz=None``: none. The methods page's 20 Hz           none
                    Butterworth is not in this code path.
calibrate_gravity   on. A van Hees fit over 10 s stationary windows (std below    NOT APPLIED (deviation D1)
                    15 mg on every axis). It runs only with >= 50 such windows
                    that reach every cube face beyond 0.3 g; otherwise the data
                    is left unchanged.
detect_nonwear      on. Stationary by the same test for > 90 min -> samples set   NOT APPLIED (deviation D2)
                    to NaN. A missing sample is never stationary, so gaps break
                    a stretch.
resample            'uniform': nearest neighbour onto the native-rate grid.        identity. A run is uniform by
                    Skipped when the index is already uniform, which makes it     construction; a timing step off
                    an identity there.                                            the grid splits it. Never
                                                                                  re-gridded.
segment             ``resample('30s', origin='start')`` bins from the first       30 s bins from each run's first
                    sample. Per bin: n == 3000 kept; n > 3000 truncated;           sample (``run``) or from the
                    1500 < n < 3000 wrap-padded; else NaN. Any NaN -> dropped.    request start (``request``). Only
                                                                                  fully covered bins are kept; the
                                                                                  rest are invalid epochs with a
                                                                                  reason (deviation D3).
resize              ``resize(X, 900)``: scipy ``interp1d(kind='linear')`` from    the same arithmetic, own code,
                    ``linspace(0, 1, L)`` to ``linspace(0, 1, 900)`` per window   in float64 (upstream's precision
                    (no filter)                                                   whenever any bin is invalid)
model input         ``float32 [B, 3, 900]``                                       same
==================  ===========================================================  ==================================

Each valid epoch is a pure function of its own 3000 samples, so the model inputs do not depend on chunking. Gaps
are never interpolated across: a run ends at the first missing second, and an epoch never spans two runs.

Deterministic and pure: no I/O, no RNG, numpy only.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import numpy as np

from ..preprocess import WHOOP_ACCEL_SCALE, WHOOP_SAMPLE_COUNT, PreprocessError, _asof_split
from . import (DEFAULT_GRID, EPOCH_S, EPOCH_SOURCE_SAMPLES, GRIDS, MODEL_SAMPLES, PREPROCESSING_VERSION,
               REASON_NO_DATA, REASON_PARTIAL, SOURCE_HZ)

# A timing step whose length differs from 1/fs by more than this fraction of the period splits a dataset run
# (the WHOOP path is uniform by construction and never needs it).
MAX_STEP_ERROR = 1e-3
_TIME_EPS = 1e-9


@dataclass(frozen=True)
class Run:
    """A contiguous run on a uniform clock: sample ``k`` sits at ``t0 + k / fs``; ``x`` float32 ``[N, 3]`` in g."""
    t0: float
    fs: float
    x: np.ndarray

    @property
    def n(self) -> int:
        return int(self.x.shape[0])

    @property
    def end(self) -> float:
        """Exclusive end: the time one period after the last sample."""
        return self.t0 + self.n / self.fs


@dataclass(frozen=True)
class Epoch:
    """One 30 s epoch ``[s, e)``. A valid epoch reads ``window_len(fs)`` samples of run ``run`` from ``i0``. An
    invalid one carries a reason and the seconds of its span that some run covers."""
    s: float
    e: float
    valid: bool
    reason: Optional[str] = None
    run: int = -1
    i0: int = -1
    covered_s: float = 0.0


def window_len(fs: float) -> int:
    """Samples per 30 s epoch at ``fs``: upstream's ``int(window_sec * sample_freq)`` (3000 at 100 Hz)."""
    return int(EPOCH_S * float(fs))


def validate_grid(grid: str) -> str:
    if grid not in GRIDS:
        raise PreprocessError(f"grid must be one of {list(GRIDS)}, got {grid!r}")
    return grid


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------

def runs_from_seconds(seconds: Sequence[Tuple[int, np.ndarray]]) -> List[Run]:
    """(ts, int16 columns[600]) seconds -> uniform 100 Hz accelerometer runs.

    Runs are split by the shared HART decoder's own splitter (``activity_context.preprocess._asof_split``, the first
    step of ``decode_seconds``), with the same refusals:
    - duplicate second -> error;
    - clock reset -> error;
    - gap > 1 s -> new run;
    - columns that are not int16[600] -> error.

    Only the accelerometer block (the first 300 i16 of each second) is converted, straight to float32: i16/4096 is
    exact there. This is the same value ``decode_seconds`` gives in float64, without building the six-channel
    float64 array of a whole day.

    An NPB1 second holds exactly 100 samples per axis, and a run is a sequence of consecutive seconds, so its clock
    is ``start_ts + k / 100`` by the format. The sample count is checked per run. Per-sample hardware timing inside a
    second is not observable in NPB1."""
    out: List[Run] = []
    for start_ts, cols in _asof_split(seconds):
        n_s = cols.shape[0]
        acc = cols[:, 0:3 * WHOOP_SAMPLE_COUNT].reshape(n_s, 3, WHOOP_SAMPLE_COUNT).transpose(0, 2, 1)
        acc = (acc.reshape(n_s * WHOOP_SAMPLE_COUNT, 3).astype(np.float32) * np.float32(WHOOP_ACCEL_SCALE))
        if acc.shape[0] != WHOOP_SAMPLE_COUNT * n_s or n_s < 1:
            raise PreprocessError(f"run at {start_ts}: {acc.shape[0]} samples for {n_s} s is not a uniform "
                                  f"{SOURCE_HZ} Hz run")
        out.append(Run(t0=float(start_ts), fs=float(SOURCE_HZ), x=np.ascontiguousarray(acc)))
    return out


def runs_from_array(t: np.ndarray, xyz: np.ndarray, fs: float,
                    max_step_error: float = MAX_STEP_ERROR) -> List[Run]:
    """Offline datasets. Timestamps ``t`` (s) and ``xyz`` ``[N, 3]`` in g at nominal ``fs`` -> uniform runs.

    A new run starts at:
    - any nonfinite sample (the sample is dropped);
    - a non-increasing timestamp;
    - a step whose length differs from ``1/fs`` by more than ``max_step_error`` of the period.

    Samples are never moved, filled or re-gridded. Run ``k`` keeps its first timestamp as ``t0``."""
    t = np.asarray(t, dtype=np.float64)
    xyz = np.asarray(xyz)
    if t.ndim != 1 or xyz.ndim != 2 or xyz.shape != (t.shape[0], 3):
        raise PreprocessError(f"need t [N] and xyz [N, 3], got {t.shape} and {xyz.shape}")
    fs = float(fs)
    if not (math.isfinite(fs) and fs > 0):
        raise PreprocessError(f"invalid sample rate {fs!r}")
    if not np.isfinite(t).all():
        raise PreprocessError("nonfinite timestamps rejected")
    n = t.shape[0]
    ok = np.isfinite(xyz).all(axis=1)
    cut = np.zeros(n, dtype=bool)                             # True: sample i cannot continue sample i - 1
    if n > 1:
        cut[1:] = ~(np.abs(np.diff(t) * fs - 1.0) <= max_step_error) | ~ok[:-1]   # also catches steps <= 0
    starts = np.flatnonzero(ok & np.r_[True, cut[1:]])
    out: List[Run] = []
    for k, i in enumerate(starts):
        stop = int(starts[k + 1]) if k + 1 < starts.shape[0] else n
        bad = np.flatnonzero(~ok[i:stop])
        j = i + int(bad[0]) if bad.shape[0] else stop
        out.append(Run(t0=float(t[i]), fs=fs, x=np.ascontiguousarray(xyz[i:j], dtype=np.float32)))
    return out


# ---------------------------------------------------------------------------
# Epochs
# ---------------------------------------------------------------------------

def _bin(run: Run, s: float) -> Tuple[int, int]:
    """Sample index range ``[a, b)`` of ``run`` whose times fall in ``[s, s + 30)`` (unclipped)."""
    a = math.ceil((s - run.t0) * run.fs - _TIME_EPS)
    b = math.ceil((s + EPOCH_S - run.t0) * run.fs - _TIME_EPS)
    return a, b


def _covered(run: Run, s: float) -> float:
    lo, hi = max(s, run.t0), min(s + EPOCH_S, run.end)
    return max(0.0, hi - lo)


def epochs(runs: Sequence[Run], start: float, end: float, grid: str = DEFAULT_GRID) -> List[Epoch]:
    """30 s epochs of ``runs`` that start inside ``[start, end)``, sorted by start.

    A valid epoch lies fully inside one run and inside ``[start, end]``; it reads ``window_len`` samples of that
    run. ``n > window_len`` samples in a bin are truncated, as upstream does; that happens only for non-integer
    rates.

    - ``grid='run'``: bins at ``run.t0 + 30 k``. Only a run's last, incomplete bin is invalid (``partial_window``).
      It keeps its nominal span and may overlap the next run's first epoch; it carries no output.
    - ``grid='request'``: bins at ``start + 30 k`` until ``end`` (a last bin that crosses ``end`` is listed as
      invalid). A bin fully inside one run and the request is valid. A bin partly covered by one or more runs is
      ``partial_window``. A bin no run touches is ``no_data``."""
    validate_grid(grid)
    if not (math.isfinite(start) and math.isfinite(end)) or end <= start:
        raise PreprocessError(f"invalid interval [{start}, {end})")
    out: List[Epoch] = []
    if grid == "run":
        for ri, run in enumerate(runs):
            if run.n == 0 or run.end <= start or run.t0 >= end:
                continue
            k0 = max(0, math.ceil((start - run.t0) / EPOCH_S - _TIME_EPS))
            k = k0
            while True:
                s = run.t0 + k * EPOCH_S
                if s >= min(run.end, end) - _TIME_EPS:
                    break
                out.append(_epoch_in_run(runs, ri, s, end))
                k += 1
    else:
        n_bins = int(math.ceil((end - start) / EPOCH_S - _TIME_EPS))
        for k in range(n_bins):
            s = start + k * EPOCH_S
            out.append(_epoch_on_request_grid(runs, s, end))
    out.sort(key=lambda ep: (ep.s, not ep.valid))
    return out


def _epoch_in_run(runs: Sequence[Run], ri: int, s: float, end: float) -> Epoch:
    run = runs[ri]
    a, b = _bin(run, s)
    e = s + EPOCH_S
    wl = window_len(run.fs)
    if a >= 0 and b <= run.n and b - a >= wl and e <= end + _TIME_EPS:
        return Epoch(s=s, e=e, valid=True, run=ri, i0=a, covered_s=float(EPOCH_S))
    return Epoch(s=s, e=e, valid=False, reason=REASON_PARTIAL, covered_s=_covered(run, s))


def _epoch_on_request_grid(runs: Sequence[Run], s: float, end: float) -> Epoch:
    e = s + EPOCH_S
    covered = 0.0
    for ri, run in enumerate(runs):
        c = _covered(run, s)
        if c <= 0:
            continue
        covered += c
        a, b = _bin(run, s)
        if a >= 0 and b <= run.n and b - a >= window_len(run.fs) and e <= end + _TIME_EPS:
            return Epoch(s=s, e=e, valid=True, run=ri, i0=a, covered_s=float(EPOCH_S))
    if covered <= 0:
        return Epoch(s=s, e=e, valid=False, reason=REASON_NO_DATA)
    return Epoch(s=s, e=e, valid=False, reason=REASON_PARTIAL, covered_s=min(float(EPOCH_S), covered))


def epoch_samples(runs: Sequence[Run], valid: Sequence[Epoch]) -> np.ndarray:
    """float32 ``[B, L, 3]`` source samples of valid epochs, all at one rate (``L = window_len``)."""
    if not valid:
        return np.zeros((0, EPOCH_SOURCE_SAMPLES, 3), dtype=np.float32)
    rates = {runs[ep.run].fs for ep in valid}
    if len(rates) != 1:
        raise PreprocessError(f"epochs at mixed sample rates {sorted(rates)}")
    wl = window_len(rates.pop())
    out = np.empty((len(valid), wl, 3), dtype=np.float32)
    for i, ep in enumerate(valid):
        if not ep.valid:
            raise PreprocessError(f"epoch at {ep.s} is not valid")
        out[i] = runs[ep.run].x[ep.i0:ep.i0 + wl]
    return out


# ---------------------------------------------------------------------------
# Resize (upstream actinet.utils.utils.resize: interp1d linear on linspace(0, 1, L) -> linspace(0, 1, 900))
# ---------------------------------------------------------------------------

def _resize_plan(n_in: int, n_out: int):
    t_in = np.linspace(0.0, 1.0, n_in, endpoint=True)
    t_out = np.linspace(0.0, 1.0, n_out, endpoint=True)
    hi = np.clip(np.searchsorted(t_in, t_out, side="left"), 1, n_in - 1)
    lo = hi - 1
    return lo, hi, (t_in[hi] - t_in[lo]), (t_out - t_in[lo])


def resize(x: np.ndarray, n_out: int = MODEL_SAMPLES) -> np.ndarray:
    """Linear resize along axis 1 of ``x`` ``[B, L, C]`` -> float64 ``[B, n_out, C]``.

    The arithmetic is that of scipy ``interp1d(kind='linear')`` on the endpoint-inclusive unit grids, in float64:
    difference, division by the grid step, scale, add.

    Upstream's own precision depends on the rest of the file. ``make_windows`` stacks every bin of the recording,
    and any invalid bin is ``np.full(..., nan)`` float64, which promotes the whole stack to float64. Without such a
    bin, the stack stays float32 and interp1d takes float32 differences. Nara always takes float64 differences,
    which is upstream's result for any recording with at least one invalid bin. On WHOOP input the two are equal:
    i16/4096 values subtract exactly in float32. Checked bit for bit against goldens made with upstream code."""
    x = np.asarray(x, dtype=np.float64)
    if x.ndim != 3 or x.shape[1] < 2:
        raise PreprocessError(f"resize needs [B, L >= 2, C], got {x.shape}")
    if not np.isfinite(x).all():
        raise PreprocessError("nonfinite samples cannot be resized")
    lo, hi, dt, off = _resize_plan(x.shape[1], int(n_out))
    y_lo, y_hi = x[:, lo, :], x[:, hi, :]
    slope = (y_hi - y_lo) / dt[None, :, None]
    return slope * off[None, :, None] + y_lo


def model_input(resized: np.ndarray) -> np.ndarray:
    """float64 ``[B, 900, 3]`` -> the model tensor float32 ``[B, 3, 900]`` (upstream ``NormalDataset``)."""
    r = np.asarray(resized)
    if r.ndim != 3 or r.shape[1:] != (MODEL_SAMPLES, 3):
        raise PreprocessError(f"expected [B, {MODEL_SAMPLES}, 3], got {r.shape}")
    return np.ascontiguousarray(np.transpose(r.astype(np.float32), (0, 2, 1)))


def model_batch(runs: Sequence[Run], valid: Sequence[Epoch]) -> np.ndarray:
    """Valid epochs -> float32 ``[B, 3, 900]``. A 30 Hz run needs no resize, as upstream skips it then."""
    raw = epoch_samples(runs, valid)
    if raw.shape[0] == 0:
        return np.zeros((0, 3, MODEL_SAMPLES), dtype=np.float32)
    if raw.shape[1] != MODEL_SAMPLES:
        return model_input(resize(raw))
    return model_input(raw.astype(np.float64))


__all__ = ["PREPROCESSING_VERSION", "MAX_STEP_ERROR", "PreprocessError", "Run", "Epoch", "window_len",
           "validate_grid", "runs_from_seconds", "runs_from_array", "epochs", "epoch_samples", "resize",
           "model_input", "model_batch"]
