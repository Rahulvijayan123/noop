"""Run -> model tensor, following the pinned wav2sleep conversion and normalization exactly.

Each contiguous run is treated as one official "recording" (the pinned pipeline has no notion of
a gap inside a recording: ``process_waveform_dataframe`` drops NaNs and linearly interpolates
across them, which would concatenate disjoint runs - so runs are never handed to it together).

Everything native is derived from the run's DECLARED rate ``r`` (24 or 25 Hz; never assumed).
For a run, with ``t0`` = the first UTC 30-s boundary at or after the run start:

1. native samples from ``t0`` onwards, at relative times ``j / r`` s (float64 ``j / float(r)``);
2. ``n = floor((t_last - t0) / 30)`` whole epochs: epoch ``e`` uses the pinned grid points
   ``(30e, 30(e+1)]`` (``k * 30/1024`` s, k = 1024e+1 .. 1024(e+1)); its last point is the next
   second's first native sample, so an epoch is staged only when that sample is in the run;
3. linear interpolation in time between native samples - ``np.interp`` here, bitwise identical
   to the pinned pandas ``interpolate(method='index', limit_area='inside')`` path (tested against
   the vendored function at both rates); every grid point lies inside the measured run, so the
   pinned ``fillna(0.0)`` never fires and nothing is padded;
4. ``float32`` cast (the pinned ``.astype(np.float32)``);
5. the pinned non-causal z-score over the run (vendored ``_zscore_normalize``: torch mean,
   unbiased std, 1e-6 floor).

The samples keep the sign they arrived with (``constants.POLARITY``): nothing is inverted.

Deviation D1 (recorded in PROVENANCE.md): the pinned default pads every recording with raw
zeros up to ``max_length_hours = 10``. Here the grid ends at the run's last whole epoch, i.e. the
pinned function is called with ``max_length_hours = n * 30 / 3600``. For a recording that is
exactly that long the two are identical; zero-padding absolute ADC counts (~3.8e5 counts DC)
would instead make the global z-score measure the padding step, not the pulse waveform.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from . import constants as C
from .contract import Run

#: The pinned grid step, 30/1024 s = 15/512 s: exactly representable, so k * step is exact.
GRID_STEP_S = C.EPOCH_SECONDS / C.MODEL_SAMPLES_PER_EPOCH


@dataclass
class EpochPlan:
    """Where a run's stageable epochs sit (all times whole unix seconds)."""

    run_index: int
    rate_hz: int                 # the declared native rate of the run
    t0: int                      # epoch origin (UTC 30-s boundary)
    n_epochs: int                # whole epochs whose pinned grid lies inside the run
    native_offset: int           # index of the native sample at t0 inside run.samples
    native_used: int             # native samples handed to the resampler (from t0 to run end)

    @property
    def epoch_starts(self) -> list[int]:
        return [self.t0 + C.EPOCH_SECONDS * e for e in range(self.n_epochs)]

    @property
    def end(self) -> int:
        return self.t0 + C.EPOCH_SECONDS * self.n_epochs


def plan_run(run: Run) -> EpochPlan:
    """The epochs a run can stage on the UTC 30-s grid, at the run's declared rate."""
    rate = int(run.rate_hz)
    t0 = -(-run.start // C.EPOCH_SECONDS) * C.EPOCH_SECONDS     # ceil to the 30-s grid
    span = run.end - t0                                          # whole seconds from t0
    # The last native sample is at run.end - 1/rate (rate >= 2), so epoch e is complete iff its
    # end sample t0 + 30(e+1) < run.end, i.e. n = floor((span - 1/rate) / 30) = (span - 1) // 30.
    n = (span - 1) // C.EPOCH_SECONDS if span >= 1 else 0
    offset = (t0 - run.start) * rate
    used = max(0, run.samples.size - offset) if n > 0 else 0
    return EpochPlan(run_index=run.index, rate_hz=rate, t0=int(t0), n_epochs=int(max(0, n)),
                     native_offset=int(offset), native_used=int(used))


def native_times(n_samples: int, rate_hz: int) -> np.ndarray:
    """Relative native sample times in seconds: ``j / float(rate)`` (the canonical float64 form)."""
    if int(rate_hz) not in C.SUPPORTED_NATIVE_RATES_HZ:
        raise ValueError(f"unsupported native rate {rate_hz!r}")
    return np.arange(n_samples, dtype=np.float64) / float(rate_hz)


def model_grid(n_epochs: int) -> np.ndarray:
    """The pinned grid ``k * 30/1024`` for ``k = 1 .. 1024 * n_epochs`` (exact float64)."""
    return np.arange(1, n_epochs * C.MODEL_SAMPLES_PER_EPOCH + 1, dtype=np.float64) * GRID_STEP_S


def resample_run(run: Run, plan: EpochPlan) -> np.ndarray:
    """Native run at its declared rate -> float32 signal on the pinned 1024-per-epoch grid."""
    if plan.n_epochs <= 0:
        raise ValueError("run has no complete epoch")
    values = run.samples[plan.native_offset:plan.native_offset + plan.native_used]
    times = native_times(values.size, plan.rate_hz)
    grid = model_grid(plan.n_epochs)
    if grid[-1] > times[-1]:
        # Would need the pinned fillna(0.0) (a raw zero sample): refused by construction.
        raise ValueError("model grid extends beyond the last native sample")
    return np.interp(grid, times, values).astype(np.float32)


def normalize(signal: np.ndarray) -> Any:
    """The pinned non-causal z-score (vendored ``_zscore_normalize``), returns a torch tensor."""
    import torch

    from ..wav2sleep_vendored.data.zscore import _zscore_normalize

    tensor = torch.from_numpy(np.ascontiguousarray(signal, dtype=np.float32))
    return _zscore_normalize({C.MODEL_SIGNAL: tensor})[C.MODEL_SIGNAL]


def native_provenance(run: Run, plan: EpochPlan) -> dict[str, Any]:
    """Per-run native-sample provenance: epoch e uses native samples
    ``native_offset + 30*r*e .. native_offset + 30*r*(e+1)`` inclusive (30*r + 1 samples)."""
    return {
        "run_index": run.index,
        "run_id": run.run_id,
        "run_id_piece": run.run_id_piece,
        "config_identity": run.config_identity,
        "segments": list(run.segment_indices),
        "native_rate_hz": plan.rate_hz,
        "clock_provenance": dict(run.clock_provenance),
        "run_start_unix": run.start,
        "run_end_unix": run.end,
        "native_samples": int(run.samples.size),
        "epoch_origin_unix": plan.t0,
        "native_index_of_epoch_origin": plan.native_offset,
        "native_samples_resampled": plan.native_used,
        "staged_epochs": plan.n_epochs,
        "native_samples_per_epoch_used": C.native_samples_per_epoch(plan.rate_hz) + 1,
        "model_samples_per_epoch": C.MODEL_SAMPLES_PER_EPOCH,
        "polarity": C.POLARITY,
        "non_causal_scope": "every epoch's output depends on the whole run (global z-score, "
                            "instance norm and the bidirectional sequence mixer)",
    }


def preprocessing_parameters() -> dict[str, Any]:
    """Everything that defines the tensor, for the preprocessing digest."""
    return {
        "revision": C.PREPROCESSING_REVISION,
        "epoch_seconds": C.EPOCH_SECONDS,
        "supported_native_rates_hz": list(C.SUPPORTED_NATIVE_RATES_HZ),
        "model_samples_per_epoch": C.MODEL_SAMPLES_PER_EPOCH,
        "grid": "k*30/1024, k=1..1024n, origin = first UTC 30-s boundary in the run",
        "native_time": "j/float(declared rate), float64",
        "interpolation": "np.interp (== pinned interpolate_index method='index', limit_area='inside')",
        "cast": "float32",
        "normalization": "pinned _zscore_normalize (torch.mean, torch.std unbiased, eps 1e-6)",
        "padding": "none (grid ends at the run's last whole epoch; deviation D1)",
        "polarity": C.POLARITY,
        "modalities": [C.MODEL_SIGNAL],
    }
