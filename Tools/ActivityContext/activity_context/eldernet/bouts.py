"""Offline bout assembly through upstream's own functions (run.py only — the serve path is per-window).

Nothing here re-implements upstream: every rule is a call into the verified upstream modules
(:mod:`.upstream`, the operator's checkout of the pinned commit; University of Oxford Academic Use Licence):

* ``gait_quality.detection.window_predictions_to_seconds`` (centre-second voting), ``merge_bouts`` (gaps of
  <= ``merge_gap_s`` bridged, then runs shorter than ``min_bout_s`` dropped; upstream defaults 3 s / 10 s) and
  ``detect_bouts``;
* ``gait_quality.quality.windows_within_bouts`` for the window starts re-cut inside each bout (Nara's windows are
  then looked up by start second, so the samples are the ``eldernet-prep-1`` ones), ``summarise_bouts`` and
  ``summarise_recording`` (pandas; imported only here, never by the serve).

This module only converts between Nara's row dicts and upstream's arrays / DataFrames.
"""

from __future__ import annotations

from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import RATE_HZ, UPSTREAM_HOP_S, WINDOW_S, WINDOW_SAMPLES
from . import upstream


def second_labels(window_pred: np.ndarray, min_bout_s: int = 10, merge_gap_s: int = 3,
                  upstream_dir: Optional[str] = None) -> np.ndarray:
    """Per-window gait (hop 1 s) -> merged per-second labels (upstream detection rules)."""
    det = upstream.detection(upstream_dir)
    pred = np.asarray(window_pred, dtype=int)
    if not len(pred):
        return pred
    seconds = det.window_predictions_to_seconds(pred, WINDOW_S)
    return np.asarray(det.merge_bouts(seconds, min_bout_sec=min_bout_s, merge_gap_sec=merge_gap_s), dtype=int)


def detect_bouts(labels: np.ndarray, upstream_dir: Optional[str] = None) -> List[Dict[str, int]]:
    """Bout dicts (``bout_id``, ``start_sec``, ``end_sec``, ``duration_sec``, ``start_sample``, ``end_sample``)."""
    return upstream.detection(upstream_dir).detect_bouts(np.asarray(labels, dtype=int), RATE_HZ)


def bout_window_starts(bouts: Sequence[Dict[str, int]], n_samples_30hz: int,
                       upstream_dir: Optional[str] = None) -> List[Tuple[int, int]]:
    """(bout_id, start second) of every window upstream re-cuts inside each bout of an ``n_samples_30hz`` signal."""
    if not bouts:
        return []
    q = upstream.quality(upstream_dir)
    placeholder = np.zeros((int(n_samples_30hz), 3), dtype=np.int8)      # only the positions are used
    _, bout_ids, starts = q.windows_within_bouts(placeholder, list(bouts), WINDOW_SAMPLES, RATE_HZ * UPSTREAM_HOP_S)
    return [(int(b), int(s) // RATE_HZ) for b, s in zip(bout_ids, starts)]


def summarise(rows: List[Dict], labels: np.ndarray, metrics: Sequence[str],
              upstream_dir: Optional[str] = None) -> Tuple[List[Dict], Dict]:
    """(bout rows, recording summary) by upstream ``summarise_bouts`` / ``summarise_recording``."""
    import pandas as pd
    q = upstream.quality(upstream_dir)
    frame = pd.DataFrame(rows, columns=["timestamp", "bout_id", "start_sample"] + list(metrics))
    frame.attrs["window_sec"] = WINDOW_S
    frame.attrs["stride_sec"] = UPSTREAM_HOP_S
    bout_rows = q.summarise_bouts(frame).to_dict("records") if len(frame) else []
    return bout_rows, dict(q.summarise_recording(frame, np.asarray(labels)))


__all__ = ["second_labels", "detect_bouts", "bout_window_starts", "summarise"]
