"""Conservative heuristic activity classifier — the operational baseline.

Spec s7: "Start with an operational conservative baseline using existing
activity ticks and ImuFeatureExtractor. It establishes end-to-end wiring and
a comparison point. Do not call its heuristic scores calibrated probabilities."

This module re-derives the ImuFeatureExtractor features
(Packages/StrandAnalytics/Sources/StrandAnalytics/ImuFeatureExtractor.swift)
in pure numpy over a 4 s / 120-sample @ 30 Hz window and maps them to the
ontology v1 motion label (C2) with deliberately conservative rules.

Confidence contract: the returned probs are a HEURISTIC one-hot with the
chosen label at 1.0 (or a flat 0.25 distribution for unknown). They are NOT
calibrated probabilities, never feed a physiological gate, and every window
produced here is flagged ``baseline: true`` by the caller. The HART model
(spec s7) is the calibrated path.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

import numpy as np

from .preprocess import Window, TARGET_HZ

MOTION_LABELS: tuple = ("stationary", "walking", "running", "other_movement", "unknown")

# Feature / rule constants (ImuFeatureExtractor.swift parity where available).
CADENCE_BAND_HZ = (1.2, 3.5)          # ImuFeatureExtractor.cadenceBand
MIN_CADENCE_STRENGTH = 0.20           # ImuFeatureExtractor.minCadenceStrength
# Conservative rule thresholds (see module docstring; tuned on golden fixtures
# where the synthetic gait reads accel-energy ~0.20 g / gyro ~33 deg/s and the
# stationary second reads ~0.001 g / ~0.2 deg/s — margins of 10x+).
STATIONARY_ACCEL_MAX_G = 0.02         # RMS accel-magnitude AC (g)
STATIONARY_GYRO_MAX_DPS = 5.0         # mean gyro magnitude (deg/s)
RHYTHMIC_STRENGTH = 0.30              # cadence strength required for walking/running
RUNNING_CADENCE_MIN_HZ = 2.2          # >= 132 steps/min -> running (conservative)


@dataclass
class ImuFeatures:
    """Mirror of ImuActivityFeatures (ImuFeatureExtractor.swift)."""
    accel_energy_g: float
    gyro_energy_dps: float
    jerk_rms: float
    cadence_hz: Optional[float]
    cadence_strength: float
    sample_count: int


def extract_features(window: Window) -> ImuFeatures:
    """ImuFeatureExtractor-style features over one 120-sample window.

    cadence comes from the normalized autocorrelation peak of the accel-
    magnitude AC in the gait band (1.2-3.5 Hz); strength < 0.20 -> None.
    """
    s = window.data
    n = s.shape[0]
    if n < 8:
        return ImuFeatures(0.0, 0.0, 0.0, None, 0.0, n)
    amag = np.linalg.norm(s[:, 0:3], axis=1)
    gmag = np.linalg.norm(s[:, 3:6], axis=1)
    gyro_energy = float(gmag.mean())
    mean = float(amag.mean())
    ac = amag - mean
    accel_energy = float(np.sqrt(np.mean(ac * ac)))
    jerk = float(np.sqrt(np.mean(np.diff(amag) ** 2))) if n > 1 else 0.0

    ac0 = float(np.dot(ac, ac))
    best_f: Optional[float] = None
    best_s = 0.0
    if ac0 > 0:
        lo = max(1, int(round(TARGET_HZ / CADENCE_BAND_HZ[1])))
        hi = min(n - 1, int(round(TARGET_HZ / CADENCE_BAND_HZ[0])))
        for lag in range(lo, hi + 1):
            strength = float(np.dot(ac[:-lag], ac[lag:])) / ac0
            if strength > best_s:
                best_s = strength
                best_f = TARGET_HZ / lag
    cadence = best_f if best_s >= MIN_CADENCE_STRENGTH else None
    return ImuFeatures(accel_energy, gyro_energy, jerk, cadence, max(0.0, best_s), n)


@dataclass
class BaselineResult:
    label: str
    probs: Dict[str, float]
    features: ImuFeatures


def classify_window(window: Window) -> BaselineResult:
    """Conservative heuristic label for one window (baseline; not calibrated).

    Rules, in order:
      1. nonfinite/empty input            -> unknown
      2. accel-energy <= 0.02 g AND
         gyro-energy  <= 5.0 deg/s        -> stationary   (low observed wrist
                                                           movement only)
      3. rhythmic cadence (strength >= 0.30):
            cadence >= 2.2 Hz             -> running
            cadence <  2.2 Hz             -> walking
      4. cadence strength in [0.20, 0.30) -> unknown      (rhythmic but weak;
                                                           ambiguous, fall back)
      5. otherwise                        -> other_movement
    """
    f = extract_features(window)
    if not np.isfinite(window.data).all() or window.data.shape[0] == 0:
        return BaselineResult("unknown", _unknown_probs(), f)

    if (f.accel_energy_g <= STATIONARY_ACCEL_MAX_G
            and f.gyro_energy_dps <= STATIONARY_GYRO_MAX_DPS):
        label = "stationary"
    elif f.cadence_hz is not None and f.cadence_strength >= RHYTHMIC_STRENGTH:
        label = "running" if f.cadence_hz >= RUNNING_CADENCE_MIN_HZ else "walking"
    elif f.cadence_hz is not None and f.cadence_strength >= MIN_CADENCE_STRENGTH:
        label = "unknown"                       # weak rhythm, ambiguous
    else:
        label = "other_movement"
    return BaselineResult(label, _one_hot(label), f)


def _one_hot(label: str) -> Dict[str, float]:
    return {lab: (1.0 if lab == label else 0.0) for lab in MOTION_LABELS}


def _unknown_probs() -> Dict[str, float]:
    return {lab: (1.0 / len(MOTION_LABELS)) for lab in MOTION_LABELS}
