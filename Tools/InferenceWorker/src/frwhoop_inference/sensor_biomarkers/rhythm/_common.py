"""Shared helpers for the rhythm shadow adapters (W4-owned).

This module is pure plumbing: artifact-root resolution, env-flag gating,
sha256 verification, PPG payload parsing and windowing. It imports only the
standard library and numpy/scipy, so importing the ``rhythm`` package can
never pull in keras or torch (the heavy optional runtimes are imported lazily
inside the adapter constructors).
"""

from __future__ import annotations

import hashlib
import os
from typing import Any, Iterator

import numpy as np

#: Production artifact root (matches frwhoop_inference.artifacts.DEFAULT_MODEL_ROOT).
DEFAULT_ARTIFACT_ROOT = "/opt/frwhoop-models"

#: Local staging default used by the provisioning scripts (gitignored; the
#: parent-owned manifest records the real production paths under the root).
LOCAL_STAGING_ROOT = "/tmp/frwhoop-sensor-biomarkers/models"

#: Exactly "1" enables a worker flag (mirrors FRWHOOP_ACTIVITY_ENABLED).
_ENABLED_VALUE = "1"

#: PPG payload contract (CONTRACTS.md section 4): absolute reconstructed ADC
#: counts, 24 Hz native, per-second records with a stable optical config.
DEFAULT_NATIVE_RATE_HZ = 24


def artifact_root() -> str:
    """The artifact root for the current process.

    Order: ``FRWHOOP_MODEL_ROOT`` (tests and staging), then the production
    default. Nothing here downloads anything; a missing artifact simply makes
    the adapter report ``artifact_unavailable``.
    """
    return os.environ.get("FRWHOOP_MODEL_ROOT") or DEFAULT_ARTIFACT_ROOT


def flag_enabled(name: str) -> bool:
    """A worker env flag is enabled only when its value is exactly ``"1"``."""
    return os.environ.get(name) == _ENABLED_VALUE


def sha256_file(path: str, chunk: int = 1 << 20) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(chunk)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def verify_file_sha256(path: str, expected: str) -> str:
    """Return the sha256 of ``path``, raising ValueError on mismatch."""
    actual = sha256_file(path)
    if expected and actual.lower() != str(expected).lower():
        raise ValueError(
            f"{os.path.basename(path)} sha256 mismatch: got {actual}, expected {expected}")
    return actual


def parse_ppg_payload(payload: Any) -> dict[str, Any]:
    """Normalise the CONTRACTS ``input.ppg`` object.

    Returns ``{"native_rate_hz": float, "units": str, "segments": [{
    "start_unix": int, "duration_s": float, "samples": np.ndarray[float32],
    "config": dict}]}``. Raises ``ValueError`` with a stable code-style message
    on a malformed payload (the provider maps this to a diagnostics detail).
    """
    if payload is None:
        return {"native_rate_hz": float(DEFAULT_NATIVE_RATE_HZ), "units": "adc_counts",
                "segments": []}
    if not isinstance(payload, dict):
        raise ValueError("input.ppg must be an object")
    native = payload.get("native_rate_hz")
    if native is None:
        native = DEFAULT_NATIVE_RATE_HZ
    try:
        native = float(native)
    except (TypeError, ValueError) as exc:
        raise ValueError("input.ppg.native_rate_hz must be a number") from exc
    if not (1.0 <= native <= 1000.0):
        raise ValueError("input.ppg.native_rate_hz out of range")
    units = str(payload.get("units") or "adc_counts")
    raw_segments = payload.get("segments")
    if raw_segments is None:
        raw_segments = []
    if not isinstance(raw_segments, list):
        raise ValueError("input.ppg.segments must be a list")
    segments: list[dict[str, Any]] = []
    for i, seg in enumerate(raw_segments):
        if not isinstance(seg, dict):
            raise ValueError(f"input.ppg.segments[{i}] must be an object")
        samples = seg.get("samples")
        if samples is None:
            raise ValueError(f"input.ppg.segments[{i}].samples is required")
        arr = np.asarray(samples, dtype=np.float64)
        if arr.ndim != 1 or arr.size == 0:
            raise ValueError(f"input.ppg.segments[{i}].samples must be a non-empty 1-D list")
        if not np.isfinite(arr).all():
            raise ValueError(f"input.ppg.segments[{i}].samples contains non-finite values")
        segments.append({
            "start_unix": int(seg.get("start_unix") or 0),
            "duration_s": float(seg.get("duration_s") or (arr.size / native)),
            "samples": arr.astype(np.float32),
            "config": seg.get("config") or {},
        })
    # Clock verification: the rhythm adapters only accept segments whose sample
    # clock/optical config is verified (CONTRACTS.md ``config: {"stable": true}``).
    # Fail-closed: any segment without an explicit ``stable: true`` marks the
    # clock unverified, so unverified-clock input can never become a rhythm
    # classification (test requirement: flat/missing/short/mixed-channel/
    # unverified-clock inputs cannot become normal classifications).
    clock_verified = all(
        isinstance(seg.get("config") or {}, dict)
        and (seg.get("config") or {}).get("stable") is True
        for seg in segments)
    return {"native_rate_hz": native, "units": units, "segments": segments,
            "clock_verified": clock_verified}


def iter_windows(
    ppg: dict[str, Any],
    *,
    window_seconds: float,
    window_samples: int,
) -> Iterator[dict[str, Any]]:
    """Yield non-overlapping analysis windows from the PPG segments.

    A window is ``window_samples`` native samples (``window_seconds`` at the
    native rate). Only full windows are yielded (no zero padding, no splicing
    across segments); the yield includes ``start_unix`` so results stay
    time-ordered. ``window_samples`` is derived from the native rate by the
    caller, so a mismatched rate produces the caller's explicit error, never a
    silent re-interpretation.
    """
    native = float(ppg["native_rate_hz"])
    native_per_window = int(round(window_seconds * native))
    if native_per_window != window_samples:
        raise ValueError(
            f"unsupported_native_rate: {window_seconds:g}s at {native:g} Hz "
            f"is {native_per_window} samples, expected {window_samples}")
    for seg in ppg["segments"]:
        samples = seg["samples"]
        start = int(seg["start_unix"])
        for offset in range(0, samples.size - window_samples + 1, window_samples):
            yield {
                "start_unix": start + int(round(offset / native)),
                "window_samples": window_samples,
                "native_rate_hz": native,
                "samples": samples[offset:offset + window_samples],
            }


def is_flat(samples: np.ndarray, *, atol: float = 1e-9) -> bool:
    """Flat-segment guard: constant (or near-constant) input must never be fed
    as if it were a real waveform."""
    if samples.size == 0:
        return True
    span = float(np.max(samples) - np.min(samples))
    if not np.isfinite(span):
        return True
    return span <= atol


def min_max01(samples: np.ndarray) -> np.ndarray:
    """Per-window min-max normalisation to [0, 1].

    Used by the SiamAF source pipeline (make_whole_data.py, verified) and as
    the explicitly-marked compatibility normalisation for DeepBeat (the paper
    describes [0,1] normalisation but the exact filter settings are
    unresolved, so DeepBeat output is never publishable).
    """
    lo = float(np.min(samples))
    hi = float(np.max(samples))
    if hi - lo <= 1e-12:
        return np.zeros_like(samples, dtype=np.float32)
    return ((samples.astype(np.float32) - lo) / (hi - lo))


def score_vector(*, key: str, scores: list[list[float]], classes: list[str],
                 count: int, method: str, native_rate_hz: float,
                 segment_seconds: float, samples_per_segment: int,
                 preprocessing_status: str, publishable: bool,
                 domain: str, domain_status: str, unit: str = "model_score",
                 extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """One ordered model score vector measurement for the rhythm_shadow stage.

    ``scores`` is an ordered list of per-window score vectors (window order =
    time order); ``classes`` labels the index of each vector. Every vector
    carries its preprocessing/domain status and is never publishable unless
    the caller proves otherwise (both adapters keep ``publishable=False``).
    """
    entry: dict[str, Any] = {
        "key": key,
        "unit": unit,
        "count": int(count),
        "method": method,
        "native_rate_hz": float(native_rate_hz),
        "segment_seconds": float(segment_seconds),
        "samples_per_segment": int(samples_per_segment),
        "preprocessing_status": preprocessing_status,
        "publishable": bool(publishable),
        "domain": domain,
        "domain_status": domain_status,
    }
    if count > 0:
        entry["scores"] = [list(map(float, row)) for row in scores]
        entry["classes"] = list(classes)
    if extra:
        entry.update(extra)
    return entry


__all__ = [
    "DEFAULT_ARTIFACT_ROOT", "LOCAL_STAGING_ROOT", "artifact_root", "flag_enabled",
    "sha256_file", "verify_file_sha256", "parse_ppg_payload", "iter_windows",
    "is_flat", "min_max01", "score_vector",
]
