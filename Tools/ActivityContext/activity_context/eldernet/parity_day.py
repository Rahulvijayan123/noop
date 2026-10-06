"""Whole-day departures from upstream that a 3-hour segment cannot show (ELDERNET.md §3, §8).

    python -m activity_context.eldernet.parity_day --dataset capture24 --subjects P003 P005 ... --out day.json
        (needs actipy and the upstream checkout on PYTHONPATH for upstream's own Otsu and calibration)

Per whole recording (Capture-24: ~24 h contiguous at 100 Hz, so upstream runs calibration but no non-wear,
imputation or edge-day trimming below 72 h):

* **pre-filter** — upstream's Otsu threshold (``gait_quality.detection.otsu_threshold_log`` over every 1 s-stride
  window) capped at the ceiling vs Nara's ceiling alone. Windows with ``otsu < var <= ceiling`` are classified
  by upstream and pre-filtered by Nara; the detector is run on exactly those windows to count how many upstream
  would call gait (the only possible decision change).
* **calibration** — ``actipy.processing.calibrate_gravity`` exactly as ``preprocessing.preprocess`` calls it; if it
  succeeds and changes the data, the detector runs on calibrated and uncalibrated windows (hop 5) and the
  difference in gait_prob / is_gait is reported.

No labels are read: VAL participants can be used without touching any truth.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Dict, Optional, Sequence

import numpy as np

from . import STATIC_VARIANCE_CEILING
from . import RATE_HZ, WINDOW_SAMPLES
from .gait import score_windows
from .preprocess import resample_uniform, stack_windows, windows_from_array


def day_report(acc: np.ndarray, fs: float, heads) -> Dict:
    import actipy.processing as ap
    from gait_quality.detection import otsu_threshold_log
    from gait_quality.preprocessing import acc_to_dataframe
    x30 = resample_uniform(acc, fs)               # == windows_from_array on one contiguous recording
    view = np.lib.stride_tricks.sliding_window_view(x30, WINDOW_SAMPLES, axis=0)[::RATE_HZ]   # [n, 3, 300]
    var = np.concatenate([np.var(view[i:i + 4096], axis=2).mean(axis=1) for i in range(0, len(view), 4096)])
    otsu = float(otsu_threshold_log(var))
    thr = min(otsu, STATIC_VARIANCE_CEILING)
    diff = np.flatnonzero((var > thr) & (var <= STATIC_VARIANCE_CEILING))
    up_gait = 0
    if diff.size:
        logits = heads.detect(np.ascontiguousarray(view[diff].transpose(0, 2, 1)))
        up_gait = int((np.argmax(logits, axis=1) == 1).sum())
    rep = {"n_windows_1s": int(len(view)), "otsu_threshold": otsu, "effective_upstream_threshold": thr,
           "n_prefiltered_nara": int((var <= STATIC_VARIANCE_CEILING).sum()), "n_prefiltered_upstream": int((var <= thr).sum()),
           "n_nara_only_prefiltered": int(diff.size), "n_nara_only_prefiltered_upstream_gait": up_gait}
    df = acc_to_dataframe(acc, fs, "2000-01-01 00:00:00")
    dfc, info = ap.calibrate_gravity(df)
    rep["calibration"] = {k: (float(v) if isinstance(v, (int, float, np.floating)) else str(v)) for k, v in info.items()
                          if k in ("CalibOK", "CalibErrorBefore(mg)", "CalibErrorAfter(mg)", "CalibNumSamples")}
    accc = dfc[["x", "y", "z"]].to_numpy()
    changed = not np.array_equal(accc, acc)
    rep["calibration"]["changed_data"] = bool(changed)
    if changed:
        wa, wb = windows_from_array(acc, fs, hop_s=5), windows_from_array(accc, fs, hop_s=5)
        sa, sb = score_windows(heads, stack_windows(wa), quality=False), score_windows(heads, stack_windows(wb), quality=False)
        dp = np.abs(sa.gait_prob - sb.gait_prob)
        rep["calibration"].update({"n_windows_5s": len(wa), "max_abs_dprob": float(dp.max()),
                                   "p99_abs_dprob": float(np.percentile(dp, 99)),
                                   "n_is_gait_flips": int((sa.is_gait != sb.is_gait).sum()),
                                   "n_is_gait_uncal": int(sa.is_gait.sum()), "n_is_gait_cal": int(sb.is_gait.sum()),
                                   "n_prefilter_flips": int((sa.prefiltered != sb.prefiltered).sum())})
    return rep


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Whole-day pre-filter and calibration departures vs upstream")
    ap.add_argument("--dataset", default="capture24")
    ap.add_argument("--subjects", nargs="+", required=True)
    ap.add_argument("--weights-dir", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    from ..inertia.datasets import iter_recordings
    from .model import load_heads
    from .weights import resolve
    heads = load_heads(resolve(args.weights_dir))
    out = {}
    for subj in args.subjects:
        for rec in iter_recordings(args.dataset, subjects=[subj]):
            d = np.diff(rec.t)
            if not np.allclose(d, 1.0 / rec.source_hz, atol=1e-4):
                out[rec.session] = {"skipped": "not one contiguous uniform stream"}
                continue
            out[rec.session] = dict(day_report(rec.xyz_g, rec.source_hz, heads), hours=round(len(rec.t) / rec.source_hz / 3600, 2))
            print(json.dumps({rec.session: out[rec.session]}), file=sys.stderr, flush=True)
            with open(args.out, "w") as f:
                json.dump(out, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
