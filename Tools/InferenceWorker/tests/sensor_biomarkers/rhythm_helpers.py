"""Synthetic rhythm test helpers (no real capture).

``ppg_payload`` builds a CONTRACTS-shaped ``input.ppg`` object with seeded
synthetic waveform data; ``family_request`` wraps it in the sensor-biomarker
request envelope. The rhythm tests never assume a synthetic input must be
classified a particular way; the fail-closed assertions are about withholding.
"""

from __future__ import annotations

import numpy as np


def ppg_payload(
    *,
    samples_per_segment: int = 7200,
    segments: int = 1,
    native_rate_hz: float = 24.0,
    stable: bool = True,
    seed: int = 7,
    start_unix: int = 1_780_917_232,
    waveform: str = "sine",
) -> dict:
    """A CONTRACTS-shaped ``input.ppg`` object with synthetic waveform data.

    ``samples_per_segment`` is the total count for each segment at the native
    rate. The payload carries absolute reconstructed ADC counts (arbitrary
    units), exactly as the lane sends them.
    """
    rng = np.random.default_rng(seed)
    segs = []
    for s in range(segments):
        if waveform == "sine":
            t = np.arange(samples_per_segment)
            wave = 1000.0 + 300.0 * np.sin(2 * np.pi * 1.2 * t / native_rate_hz)
            samples = wave + rng.normal(0, 5.0, samples_per_segment)
        elif waveform == "flat":
            samples = np.full(samples_per_segment, 1000.0)
        elif waveform == "constant_noise":
            samples = rng.normal(0, 1e-12, samples_per_segment)
        else:  # pragma: no cover
            raise ValueError(waveform)
        segs.append({
            "start_unix": start_unix + s * int(samples_per_segment / native_rate_hz),
            "duration_s": samples_per_segment / native_rate_hz,
            "samples": [float(v) for v in samples],
            "sample_count_per_second": int(native_rate_hz),
            "config": {"stable": stable},
        })
    return {
        "native_rate_hz": native_rate_hz,
        "units": "adc_counts",
        "segments": segs,
    }


def family_request(payload: dict, *, families=None) -> dict:
    return {
        "schema_version": 1,
        "device": {"id": "whoop5-abc", "family": "whoop5"},
        "input_revision": "sha256:" + "0" * 64,
        "day_utc": "2026-10-06",
        "ppg": payload,
        "families": families or ["rhythm_shadow"],
    }
