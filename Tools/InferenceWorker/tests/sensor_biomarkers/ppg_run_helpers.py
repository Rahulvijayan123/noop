"""Synthetic PPG waves and run-aware segments for the run tests (no real capture)."""

from __future__ import annotations

from typing import Any

import numpy as np

from frwhoop_inference.contract import parse_request

UNKNOWN_CLOCK = {"source": "record_unix_second", "grid": "start_unix + k/25",
                 "samples_per_second": 25, "packet_timing_verified": False}
VERIFIED_CLOCK = {**UNKNOWN_CLOCK, "packet_timing_verified": True}


def pulse_wave(seconds: float, rate: float, *, bpm: float = 72.0, base: float = 200000.0,
               amp: float = 30000.0, upstroke_frac: float = 0.15, t0: float = 0.0) -> np.ndarray:
    """A single-peak pulse train in absolute ADC counts: fast upstroke, slower decay.

    ``t0`` is the time of the first sample, so slices of one long wave stay phase-continuous.
    """
    n = int(round(seconds * rate))
    t = t0 + np.arange(n) / rate
    phase = (t * bpm / 60.0) % 1.0
    up = np.exp(-((phase - upstroke_frac) / (upstroke_frac / 2.5)) ** 2)
    down = np.exp(-((phase - upstroke_frac) / ((1.0 - upstroke_frac) / 4.0)) ** 2)
    return np.round(base + amp * (0.85 * up + 0.15 * down), 3)


def segment(start: float, samples: Any, rate: float, *, run_id: str | None = None,
            identity: str | None = None, known: bool | None = None,
            clock: dict[str, Any] | None = None, stable: bool = True,
            config: dict[str, Any] | None = None) -> dict[str, Any]:
    """One request segment; run-aware members only when given (else a legacy segment)."""
    samples = list(np.asarray(samples, dtype=float)) if not isinstance(samples, list) else samples
    cfg: dict[str, Any] = dict(config) if config is not None else {"stable": stable}
    if identity is not None:
        cfg["identity"] = identity
    if known is not None:
        cfg["known"] = known
    seg: dict[str, Any] = {"start_unix": start, "duration_s": len(samples) / rate,
                           "samples": samples, "config": cfg}
    if run_id is not None:
        seg["run_id"] = run_id
    if clock is not None:
        seg["clock"] = dict(clock)
    return seg


def unknown_segment(start: float, samples: Any, rate: float = 25.0, *,
                    run_id: str | None = None, clock: dict[str, Any] | None = None
                    ) -> dict[str, Any]:
    """What the run-aware worker sends for v26: configuration unidentified, clock unverified."""
    return segment(start, samples, rate, run_id=run_id or f"ppg-{int(start)}",
                   identity="unknown", known=False, clock=clock or UNKNOWN_CLOCK)


def body(ppg_segments: list[dict[str, Any]], *, rate: float = 25.0,
         families: list[str] | None = None, imu: dict[str, Any] | None = None,
         expected_duration_s: float | None = None, **input_overrides: Any) -> dict[str, Any]:
    starts = [s["start_unix"] for s in ppg_segments] or [1_780_000_000]
    ends = [s["start_unix"] + s["duration_s"] for s in ppg_segments] or [1_780_000_060]
    ppg: dict[str, Any] = {"native_rate_hz": rate, "units": "adc_counts",
                           "segments": ppg_segments}
    if expected_duration_s is not None:
        ppg["expected_duration_s"] = expected_duration_s
    inp: dict[str, Any] = {
        "schema_version": 1,
        "device": {"id": "dev-1", "family": "whoop5"},
        "input_revision": "sha256:" + "cd" * 32,
        "families": families or ["ppg_quality", "pulse_shape"],
        "watch_side": "unknown",
        "device_orientation": "unknown",
    }
    if ppg_segments:
        inp["ppg"] = ppg
    if imu is not None:
        inp["imu"] = imu
    inp.update(input_overrides)
    from datetime import datetime, timezone

    def iso(ts: float) -> str:
        return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return {
        "metric": "sensor_biomarkers",
        "context": {"user_id": "u", "device_id": "dev-1",
                    "interval_start_utc": iso(min(starts)),
                    "interval_end_utc": iso(max(ends) + 1),
                    "iana_timezone": "UTC", "profile_version": "none",
                    "config_version": "sensor-biomarkers/1.0.0", "corrections_version": "none",
                    "live": False},
        "input": inp,
    }


def stages(provider: Any, request_body: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result = provider.infer(parse_request(request_body))
    assert result.status == "ok", result.diagnostics
    return {s["family"]: s for s in result.stages}
