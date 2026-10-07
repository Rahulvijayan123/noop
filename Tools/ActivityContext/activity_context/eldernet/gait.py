"""Window-local gait detection and quality (ELDERNET.md §3/§4).

Upstream (``gait_quality/detection.py:72-134``) skips windows whose variance is at or below a recording-relative
Otsu threshold capped at ``STATIC_VARIANCE_CEILING`` (0.013² g²) and arg-maxes the detector's two logits on the
rest. Nara uses the ceiling alone — ``mean_axis(var(window)) <= 0.013²`` -> pre-filtered — so a window's answer
depends only on that window. Upstream's effective threshold is ``min(otsu, ceiling)``, so Nara pre-filters a
superset of upstream's pre-filtered windows (the extra ones are stiller than 0.013 g std on every axis on
average); the audit measures how often that changes a call (ELDERNET.md §3).

Per window: ``gait_prob = sigmoid((z_gait - z_not) / T)`` (T = 1 unless a VAL-fitted temperature is loaded,
then equal to upstream's softmax), ``is_gait = gait_prob >= gait_threshold`` (0.5 = upstream argmax). Quality
heads run on ``is_gait`` windows only — upstream runs them on windows re-cut inside merged bouts, which at the
same start second are the same samples and so the same numbers. Regression outputs are clipped to
``[0, max_mu]`` (upstream ranges). A window with any nonfinite model output is omitted and counted.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import DEFAULT_GAIT_THRESHOLD, QUALITY_HEADS, STATIC_VARIANCE_CEILING

CALIBRATION_SCHEMA = "nara.eldernet.calibration/1"
ROUND = 6


@dataclass(frozen=True)
class GaitCalibration:
    """A VAL-fitted temperature for gait_prob plus the operating threshold (both versioned, VAL-only)."""
    T: float = 1.0
    threshold: float = DEFAULT_GAIT_THRESHOLD
    fit: str = "val"
    calibration_id: Optional[str] = None

    def __post_init__(self):
        if not (math.isfinite(self.T) and self.T > 0):
            raise ValueError(f"temperature must be positive, got {self.T!r}")
        if not (0.0 < self.threshold < 1.0):
            raise ValueError(f"gait threshold must be in (0, 1), got {self.threshold!r}")
        if self.fit != "val":
            raise ValueError("a gait calibration may only be fitted on VAL subjects")

    def wire(self) -> Dict[str, Any]:
        return {"gait_prob": {"method": "temperature", "T": round(float(self.T), ROUND), "fit": self.fit}}

    @classmethod
    def from_doc(cls, doc: Mapping[str, Any]) -> "GaitCalibration":
        if doc.get("schema") != CALIBRATION_SCHEMA:
            raise ValueError(f"calibration schema must be {CALIBRATION_SCHEMA!r}, got {doc.get('schema')!r}")
        g = doc["gait_prob"]
        if g.get("method") != "temperature":
            raise ValueError("only temperature calibration is supported")
        return cls(T=float(g["T"]), threshold=float(doc["gait_threshold"]), fit=str(g.get("fit", "")),
                   calibration_id=doc.get("calibration_id"))


def window_variance(batch: np.ndarray) -> np.ndarray:
    """Upstream's pre-filter statistic: per-axis variance over the window (ddof 0), averaged over axes."""
    return np.var(np.asarray(batch, dtype=np.float64), axis=1).mean(axis=1)


def prefilter_mask(batch: np.ndarray, ceiling: float = STATIC_VARIANCE_CEILING) -> np.ndarray:
    """True where the window is too still to be gait (variance <= ceiling); nonfinite -> not pre-filtered."""
    v = window_variance(batch)
    return np.isfinite(v) & (v <= ceiling)


def gait_probability(logits: np.ndarray, T: float = 1.0) -> np.ndarray:
    """sigmoid((z1 - z0) / T) == softmax(z / T)[1], computed stably."""
    z = (np.asarray(logits, np.float64)[:, 1] - np.asarray(logits, np.float64)[:, 0]) / float(T)
    out = np.empty_like(z)
    pos = z >= 0
    out[pos] = 1.0 / (1.0 + np.exp(-z[pos]))
    ez = np.exp(z[~pos])
    out[~pos] = ez / (1.0 + ez)
    return out


@dataclass
class WindowScores:
    """Raw per-window outputs (unrounded) for B windows; ``metrics[head]`` is NaN off gait windows."""
    prefiltered: np.ndarray        # bool [B]
    logit_diff: np.ndarray         # float [B] (z1 - z0; NaN when pre-filtered)
    gait_prob: np.ndarray          # float [B] (0 when pre-filtered)
    is_gait: np.ndarray            # bool [B]
    metrics: Dict[str, np.ndarray]  # head -> float [B]
    finite: np.ndarray             # bool [B]: every output the window carries is finite


def score_windows(heads, batch: np.ndarray, calibration: Optional[GaitCalibration] = None,
                  ceiling: float = STATIC_VARIANCE_CEILING, quality: bool = True) -> WindowScores:
    """``heads`` is an :class:`~activity_context.eldernet.model.ElderNetHeads` (or a test double)."""
    cal = calibration or GaitCalibration()
    batch = np.asarray(batch, dtype=np.float64)
    B = batch.shape[0]
    pre = prefilter_mask(batch, ceiling) if B else np.zeros(0, bool)
    active = np.flatnonzero(~pre)
    diff = np.full(B, np.nan)
    prob = np.zeros(B)
    finite = np.ones(B, bool)
    if active.size:
        logits = heads.detect(batch[active])
        d = logits[:, 1] - logits[:, 0]
        diff[active] = d
        ok = np.isfinite(logits).all(axis=1)
        finite[active] = ok
        p = np.zeros(active.size)
        p[ok] = gait_probability(logits[ok], cal.T)
        prob[active] = p
    is_gait = (~pre) & finite & (prob >= cal.threshold)
    metrics = {name: np.full(B, np.nan) for name in QUALITY_HEADS}
    gi = np.flatnonzero(is_gait)
    if quality and gi.size:
        q = heads.quality(batch[gi])
        for name, (_, max_mu, _, _) in QUALITY_HEADS.items():
            v = np.asarray(q[name], np.float64)
            finite[gi] &= np.isfinite(v)
            metrics[name][gi] = np.clip(v, 0.0, max_mu)
    return WindowScores(prefiltered=pre, logit_diff=diff, gait_prob=prob, is_gait=is_gait, metrics=metrics,
                        finite=finite)


def wire_windows(windows: Sequence, scores: WindowScores) -> Tuple[List[Dict[str, Any]], int]:
    """(wire window objects, n_dropped_nonfinite) for windows with ``.s`` / ``.e`` (ELDERNET.md §4)."""
    out: List[Dict[str, Any]] = []
    dropped = 0
    for i, w in enumerate(windows):
        if not scores.finite[i]:
            dropped += 1
            continue
        item: Dict[str, Any] = {"s": w.s, "e": w.e, "gait_prob": round(float(scores.gait_prob[i]), ROUND),
                                "is_gait": bool(scores.is_gait[i])}
        if scores.prefiltered[i]:
            item["prefiltered"] = True
        if scores.is_gait[i]:
            for name, (key, _, _, _) in QUALITY_HEADS.items():
                item[key] = round(float(scores.metrics[name][i]), ROUND)
        out.append(item)
    return out, dropped


__all__ = ["CALIBRATION_SCHEMA", "GaitCalibration", "window_variance", "prefilter_mask", "gait_probability",
           "WindowScores", "score_windows", "wire_windows"]
