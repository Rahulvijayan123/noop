"""100 Hz transition-timestamp refinement (spec s9) — the WHEN, separate from the WHAT.

The learned transition expert decides WHAT happened on a resampled 4 s window; the HSMM
publishes events on a 1 s grid. Transitions themselves last 1-3 s, so a window-level decision
plus a 1 s grid can be seconds coarse. This module refines the timestamp of an already-decided
transition window using the ORIGINAL 100 Hz stream the resampler consumed: it locates the
strongest physically plausible rotation instant inside the window (a gyro-magnitude / jerk /
orientation-change-rate composite peak), gated by the same physics the heuristic uses (a real
posture change rotates the wrist hard AND leaves it somewhere new).

Deliberately direction-agnostic: WHICH transition happened is the classifier's job; this only
places it in time. Fails closed to None (no qualifying peak -> keep the window-centre
timestamp); never raises on ordinary bad input.

Reference: the composite peak s = 0.4*gyro + 0.3*jerk + 0.3*orientation-rate (each normalized by
its window max) recovers a planted synthetic transition within ~0.1 s; a reach-and-return
gesture produces a peak but fails the net-orientation gate and yields None.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Tuple

import numpy as np

# Class-conditional floors: sit<->stand rotates the wrist harder than lying down / getting up.
GYRO_FLOOR_DPS = {"sit_to_stand": 25.0, "stand_to_sit": 25.0,
                  "lie_down": 15.0, "get_up": 15.0}
DEFAULT_GYRO_FLOOR_DPS = 20.0
NET_FLOOR_DEG = 15.0        # a real posture change leaves the wrist somewhere new
_SMOOTH_MS = 50.0           # boxcar smoothing width for the composite signals
_GRAVITY_SPAN_S = 0.25      # orientation-change rate: angle across this span, stepped by it


@dataclass(frozen=True)
class RefinedTs:
    """Outcome of one refinement attempt (None ts -> no qualifying peak, keep window centre)."""
    ts: Optional[float]              # refined unix-ish time (window-relative + window start)
    quality: float                   # peak prominence over the window median (0..1-ish)
    kind: str                        # which term dominated: gyro | jerk | orientation_rate
    net_change_deg: Optional[float]  # net gravity angle across the peak (the gesture gate)


def _boxcar(x: np.ndarray, width: int) -> np.ndarray:
    if width <= 1 or x.size == 0:
        return x.copy()
    width = min(width, x.size)
    c = np.concatenate([[0.0], np.cumsum(x)])
    half = width // 2
    # centered rolling mean, edge-clamped
    lo = np.arange(x.size) - half
    hi = np.minimum(lo + width, x.size)
    lo = np.maximum(lo, 0)
    return (c[hi] - c[lo]) / np.maximum(hi - lo, 1)


def refine_event_ts(data: np.ndarray, hz: float, window_start_ts: float,
                    cls: str) -> Optional[RefinedTs]:
    """Refine WHEN a transition of class ``cls`` happened inside one native-rate window.

    ``data``: (n, 6) window at the ORIGINAL rate (100 Hz in production), g + deg/s.
    ``window_start_ts``: unix time of data[0]. Returns None on unresolvable input (never raises);
    the caller keeps the un-refined timestamp then.
    """
    try:
        if data.ndim != 2 or data.shape[1] != 6 or data.shape[0] < 8 or hz <= 0:
            return None
        acc = data[:, 0:3]
        gyr = data[:, 3:6]
        n = data.shape[0]
        dt = 1.0 / hz

        gyro_mag = np.linalg.norm(gyr, axis=1)
        amag = np.linalg.norm(acc, axis=1)
        jerk = np.abs(np.diff(amag)) / dt
        jerk = np.concatenate([[jerk[0]] if jerk.size else [0.0], jerk])

        # Orientation-change rate: angle between mean gravity [i-s, i] and [i, i+s].
        span = max(1, int(round(_GRAVITY_SPAN_S * hz)))
        orient_rate = np.zeros(n)
        means = []
        for i in range(0, n, span):
            m = acc[i:i + span].mean(axis=0)
            means.append((i, m))
        for (i0, a), (i1, b) in zip(means, means[1:]):
            na, nb = float(np.linalg.norm(a)), float(np.linalg.norm(b))
            if na < 0.5 or nb < 0.5:
                continue
            cos = float(np.dot(a, b)) / (na * nb)
            ang = float(np.degrees(np.arccos(min(1.0, max(-1.0, cos)))))
            orient_rate[i1:i1 + span] = ang / ((i1 - i0) * dt)

        sm = max(1, int(round(_SMOOTH_MS / 1000.0 * hz)))
        gs = _boxcar(gyro_mag, sm)
        js = _boxcar(jerk, sm)

        def _norm(v):
            m = float(v.max()) if v.size else 0.0
            return v / m if m > 1e-9 else np.zeros_like(v)

        composite = 0.4 * _norm(gs) + 0.3 * _norm(js) + 0.3 * _norm(orient_rate)
        i_star = int(np.argmax(composite))
        peak = composite[i_star]

        # Physics gates: a real posture transition rotates the wrist AND leaves it somewhere new.
        gyro_floor = GYRO_FLOOR_DPS.get(cls, DEFAULT_GYRO_FLOOR_DPS)
        edge = max(1, int(round(0.5 * hz)))
        first, last = acc[:edge].mean(axis=0), acc[-edge:].mean(axis=0)
        nf, nl = float(np.linalg.norm(first)), float(np.linalg.norm(last))
        net = None
        if nf >= 0.5 and nl >= 0.5:
            cos = float(np.dot(first, last)) / (nf * nl)
            net = float(np.degrees(np.arccos(min(1.0, max(-1.0, cos)))))
        if float(gs[i_star]) < gyro_floor:
            return None
        if net is None or net < NET_FLOOR_DEG:
            return None

        quality = float(peak - np.median(composite))
        terms = {"gyro": 0.4 * _norm(gs)[i_star], "jerk": 0.3 * _norm(js)[i_star],
                 "orientation_rate": 0.3 * _norm(orient_rate)[i_star]}
        kind = max(sorted(terms), key=lambda k: terms[k])
        ts = window_start_ts + i_star * dt
        return RefinedTs(ts=ts, quality=quality, kind=kind, net_change_deg=net)
    except Exception:
        return None
