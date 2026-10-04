"""Deterministic synthetic wrist-acceleration windows (natural layout: [6000, 3] = time x axis, in g).

Used by the tests, the OOD sanity checks and the committed golden fixture so that no upstream
sample data has to be redistributed. They are crude signal generators, not a physical model of
a wrist: gravity + a few sinusoids + sensor noise, quantised in 3 mg steps (the training sensor's
steps are 3-4 mg).
"""

from __future__ import annotations

import numpy as np

from .spec import SAMPLE_RATE_HZ, SENSOR_RANGE_G, WINDOW_SAMPLES

QUANTUM_G = 0.003


def _time() -> np.ndarray:
    return np.arange(WINDOW_SAMPLES, dtype=np.float64) / SAMPLE_RATE_HZ


def _gravity(rng: np.random.Generator) -> np.ndarray:
    v = rng.normal(size=3)
    return v / np.linalg.norm(v)


def _finish(sig: np.ndarray, quantize: bool = True, clip: bool = True) -> np.ndarray:
    if quantize:
        sig = np.round(sig / QUANTUM_G) * QUANTUM_G
    if clip:
        sig = np.clip(sig, -SENSOR_RANGE_G, SENSOR_RANGE_G)
    return sig.astype(np.float32)


def still_window(seed: int = 0, noise_g: float = 0.002) -> np.ndarray:
    """Wrist at rest: gravity along a random direction + ~2 mg sensor noise."""
    rng = np.random.default_rng(seed)
    return _finish(_gravity(rng) + rng.normal(0.0, noise_g, size=(WINDOW_SAMPLES, 3)))


def oscillating_window(seed: int = 0, step_hz: float = 1.8, amplitude_g: float = 0.6, noise_g: float = 0.02) -> np.ndarray:
    """Walking-like: arm swing at half the step frequency plus its first harmonics, on top of gravity."""
    rng = np.random.default_rng(seed)
    t = _time()[:, None]
    f0 = step_hz / 2.0
    amp = amplitude_g * rng.uniform(0.5, 1.0, size=3)
    phase = rng.uniform(0.0, 2 * np.pi, size=(2, 3))
    sig = amp * np.sin(2 * np.pi * f0 * t + phase[0]) + 0.5 * amp * np.sin(2 * np.pi * step_hz * t + phase[1])
    return _finish(_gravity(rng) + sig + rng.normal(0.0, noise_g, size=(WINDOW_SAMPLES, 3)))


def running_window(seed: int = 0) -> np.ndarray:
    """Running-like: ~2.8 Hz step, multi-g peaks (clipped at the +-8 g rail like the training sensor)."""
    return oscillating_window(seed, step_hz=2.8, amplitude_g=2.2, noise_g=0.08)


def saturated_window(seed: int = 0) -> np.ndarray:
    """Square wave pinned to +-8 g on every axis (sensor railed)."""
    rng = np.random.default_rng(seed)
    sign = np.sign(np.sin(2 * np.pi * 2.0 * _time() + rng.uniform(0, 2 * np.pi)))[:, None]
    return _finish(np.repeat(sign, 3, axis=1) * SENSOR_RANGE_G, quantize=False, clip=False)


def flat_window(seed: int = 0) -> np.ndarray:
    """Perfectly constant output (stuck sensor / forward-filled data): gravity direction, zero variance."""
    rng = np.random.default_rng(seed)
    return np.tile(_finish(_gravity(rng)[None, :]), (WINDOW_SAMPLES, 1))


def nan_window(seed: int = 0, n_nan: int = 400) -> np.ndarray:
    """A walking-like window with a block of NaNs in the middle."""
    w = oscillating_window(seed).copy()
    start = WINDOW_SAMPLES // 2
    w[start : start + n_nan] = np.nan
    return w
