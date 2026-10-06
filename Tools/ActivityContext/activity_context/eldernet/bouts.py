# Bout assembly ported from yonbrand/gait-quality gait_quality/detection.py (window_predictions_to_seconds,
# merge_bouts, detect_bouts) and gait_quality/quality.py (summarise_bouts, summarise_recording), upstream commit
# 437a38bcc69f42717fe73c1f7dbea7e1f7a50d23. Copyright © 2022, University of Oxford; University of Oxford
# SSL-wearables Academic Use Licence (Tools/ActivityContext/NOTICE.md). Re-expressed without pandas; same rules.
"""Offline bout assembly (run.py only — the serve path is per-window and never builds bouts).

* centre-second voting: window i (hop 1 s) votes for second ``i + 5``;
* gaps of <= ``merge_gap_s`` seconds between gait runs are bridged, then runs shorter than ``min_bout_s``
  dropped (upstream defaults 3 s and 10 s, ``pipelines/config.yaml``);
* bout summary = per-metric median over the bout's windows, ``duration = (n - 1) * stride + window``;
  recording summary = walking minutes, bout count, per-metric median / p10 / p90 (numpy linear percentiles).
"""

from __future__ import annotations

from typing import Dict, List, Sequence

import numpy as np

from . import WINDOW_S


def window_predictions_to_seconds(pred: np.ndarray, window_s: int = WINDOW_S) -> np.ndarray:
    pred = np.asarray(pred, dtype=int)
    n_seconds = len(pred) + window_s - 1
    out = np.zeros(max(n_seconds, 0), dtype=int)
    if len(pred):
        out[np.arange(len(pred)) + window_s // 2] = pred
    return out


def merge_bouts(pred: np.ndarray, min_bout_s: int = 10, merge_gap_s: int = 3) -> np.ndarray:
    pred = np.asarray(pred, dtype=int)
    if not len(pred):
        return pred
    d = np.diff(np.concatenate([[0], pred, [0]]))
    starts, ends = list(np.flatnonzero(d == 1)), list(np.flatnonzero(d == -1))
    if not starts:
        return np.zeros_like(pred)
    i = 0
    while i < len(starts) - 1:
        if starts[i + 1] - ends[i] <= merge_gap_s:
            ends[i] = ends[i + 1]
            starts.pop(i + 1)
            ends.pop(i + 1)
        else:
            i += 1
    merged = np.zeros_like(pred)
    for a, b in zip(starts, ends):
        if b - a >= min_bout_s:
            merged[a:b] = 1
    return merged


def detect_bouts(second_labels: np.ndarray) -> List[Dict[str, int]]:
    d = np.diff(np.concatenate([[0], np.asarray(second_labels, dtype=int), [0]]))
    return [{"bout_id": i, "start_sec": int(a), "end_sec": int(b), "duration_sec": int(b - a)}
            for i, (a, b) in enumerate(zip(np.flatnonzero(d == 1), np.flatnonzero(d == -1)), 1)]


def bout_window_starts(bouts: Sequence[Dict[str, int]], n_seconds_total: float, window_s: int = WINDOW_S,
                       stride_s: int = 1) -> List[tuple]:
    """(bout_id, start second) of every window re-cut inside each bout (upstream windows_within_bouts)."""
    out = []
    for b in bouts:
        end = min(b["end_sec"], n_seconds_total)
        for s in range(b["start_sec"], int(np.floor(end - window_s + 1e-9)) + 1, stride_s):
            out.append((b["bout_id"], s))
    return out


def summarise_bouts(rows: List[Dict], metrics: Sequence[str], window_s: int = WINDOW_S, stride_s: int = 1) -> List[Dict]:
    out = []
    for bid in sorted({r["bout_id"] for r in rows}):
        rs = [r for r in rows if r["bout_id"] == bid]
        item = {"bout_id": bid, "n_windows": len(rs), "duration_sec": (len(rs) - 1) * stride_s + window_s,
                "start_time": min(r["timestamp"] for r in rs)}
        for m in metrics:
            v = np.array([r[m] for r in rs], dtype=float)
            item[m] = float(np.median(v)) if len(v) else float("nan")
        out.append(item)
    return out


def summarise_recording(rows: List[Dict], second_labels: np.ndarray, metrics: Sequence[str]) -> Dict:
    s = {"walking_time_min": float(np.sum(second_labels)) / 60.0,
         "n_bouts": len({r["bout_id"] for r in rows}), "n_walking_windows": len(rows)}
    for m in metrics:
        v = np.array([r[m] for r in rows], dtype=float)
        v = v[np.isfinite(v)]
        s[f"{m}_median"] = float(np.median(v)) if len(v) else float("nan")
        s[f"{m}_p10"] = float(np.percentile(v, 10)) if len(v) else float("nan")
        s[f"{m}_p90"] = float(np.percentile(v, 90)) if len(v) else float("nan")
    return s


__all__ = ["window_predictions_to_seconds", "merge_bouts", "detect_bouts", "bout_window_starts",
           "summarise_bouts", "summarise_recording"]
