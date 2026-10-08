"""Shared helpers for the rhythm shadow adapters (W4-owned).

This module is pure plumbing: artifact-root resolution, env-flag gating,
sha256 verification, PPG payload parsing and windowing. It imports only the
standard library, numpy and the run model in ``..ppg`` (numpy only), so
importing the ``rhythm`` package can never pull in keras or torch (the heavy
optional runtimes are imported lazily inside the adapter constructors).
"""

from __future__ import annotations

import functools
import hashlib
import math
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

#: Clock gates a rhythm request can be held to (``parse_ppg_payload``).
CLOCK_GATE_LEGACY = "legacy_config_stable"
CLOCK_GATE_PACKET_TIMING = "packet_timing_verified"


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


@functools.lru_cache(maxsize=16)
def _sha256_by_stat(path: str, size: int, mtime_ns: int) -> str:
    return sha256_file(path)


def cached_sha256(path: str) -> str:
    """sha256 of ``path``, re-hashed only when its size or mtime changes.

    For readiness reporting only; the bytes a model is loaded from are always
    hashed again at load time (``verify_file_sha256``).
    """
    stat = os.stat(path)
    return _sha256_by_stat(os.path.realpath(path), stat.st_size, stat.st_mtime_ns)


def verify_file_sha256(path: str, expected: str) -> str:
    """Return the sha256 of ``path``, raising ValueError on mismatch."""
    actual = sha256_file(path)
    if expected and actual.lower() != str(expected).lower():
        raise ValueError(
            f"{os.path.basename(path)} sha256 mismatch: got {actual}, expected {expected}")
    return actual


def parse_ppg_payload(payload: Any) -> dict[str, Any]:
    """Normalise the CONTRACTS ``input.ppg`` object into runs.

    Segments are validated and grouped by the same run model as the
    descriptive PPG families (``ppg.build_ppg_runs``), so a model window is
    drawn from one run at a time and never spans a gap, a configuration change
    or a run boundary. The native rate must be stated by the request; it is
    never assumed.

    Clock gate: a request whose segments carry ``clock`` (the run-aware
    transport) is held per run to ``clock.packet_timing_verified``; an older
    request without ``clock`` keeps its request-wide gate, every segment
    declaring ``config.stable: true``. Unverified-clock input can never become
    a rhythm classification.

    Returns ``{"native_rate_hz", "units", "segments", "runs", "clock_gate",
    "clock_verified", "run_counts"}`` where ``clock_verified`` says whether any
    run passed the gate. Raises ``ValueError`` (with a code-style message) on a
    malformed payload.
    """
    empty = {"units": "adc_counts", "segments": [], "runs": [], "clock_gate": None,
             "clock_verified": False, "run_counts": {}}
    if payload is None:
        return {"native_rate_hz": None, **empty}
    if not isinstance(payload, dict):
        raise ValueError("input.ppg must be an object")
    native = payload.get("native_rate_hz")
    if isinstance(native, bool) or not isinstance(native, (int, float)):
        raise ValueError("input.ppg.native_rate_hz is required and must be a number")
    native = float(native)
    if not (math.isfinite(native) and 1.0 <= native <= 1000.0):
        raise ValueError("input.ppg.native_rate_hz out of range")
    units = str(payload.get("units") or "adc_counts")
    raw_segments = payload.get("segments")
    if raw_segments is None:
        raw_segments = []
    if not isinstance(raw_segments, list):
        raise ValueError("input.ppg.segments must be a list")
    if not raw_segments:
        return {**empty, "native_rate_hz": native, "units": units}

    from ..ppg import _validate_segments, build_ppg_runs

    segments = _validate_segments(raw_segments, native)
    runs, run_counts = build_ppg_runs(segments)
    if any(seg["clock"] is not None for seg in segments):
        gate = CLOCK_GATE_PACKET_TIMING
        verified = {run.key: run.clock_verified is True for run in runs}
    else:
        gate = CLOCK_GATE_LEGACY
        all_stable = all(seg["config"].get("stable") is True for seg in segments)
        verified = {run.key: all_stable for run in runs}
    return {
        "native_rate_hz": native,
        "units": units,
        "segments": [{"start_unix": seg["start"], "duration_s": seg["duration"],
                      "samples": seg["samples"].astype(np.float32), "config": seg["config"]}
                     for seg in segments],
        "runs": [{"key": run.key, "run_id": run.run_id, "start_unix": run.start,
                  "duration_s": run.duration, "segments": len(run.segment_indices),
                  "configuration": run.configuration,
                  "configuration_unidentified": run.configuration_unidentified,
                  "clock_verified": verified[run.key],
                  "samples": run.samples.astype(np.float32)}
                 for run in runs],
        "clock_gate": gate,
        "clock_verified": any(verified.values()),
        "run_counts": run_counts,
    }


def iter_windows(
    ppg: dict[str, Any],
    *,
    window_seconds: float,
    window_samples: int,
) -> Iterator[dict[str, Any]]:
    """Yield non-overlapping analysis windows, one run at a time.

    A window is ``window_samples`` native samples (``window_seconds`` at the
    native rate). Only full windows inside one clock-verified run are yielded
    (no zero padding, no splicing across runs); each yield names its run and
    start time so results stay time-ordered and traceable. ``window_samples``
    is derived from the native rate by the caller, so a mismatched rate
    produces the caller's explicit error, never a silent re-interpretation.
    """
    native = float(ppg["native_rate_hz"])
    native_per_window = int(round(window_seconds * native))
    if native_per_window != window_samples:
        raise ValueError(
            f"unsupported_native_rate: {window_seconds:g}s at {native:g} Hz "
            f"is {native_per_window} samples, expected {window_samples}")
    for run in ppg["runs"]:
        if not run["clock_verified"]:
            continue
        samples = run["samples"]
        for offset in range(0, samples.size - window_samples + 1, window_samples):
            yield {
                "run": run["key"],
                "start_unix": run["start_unix"] + offset / native,
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
                 model_input_rate_hz: float | None = None,
                 windows: list[dict[str, Any]] | None = None,
                 extra: dict[str, Any] | None = None) -> dict[str, Any]:
    """One ordered model score vector measurement for the rhythm_shadow stage.

    ``scores`` is an ordered list of per-window score vectors (window order =
    time order); ``classes`` labels the index of each vector. Every vector
    carries its preprocessing/domain status, the native rate the samples came
    in at and the rate the model was fed after resampling, and is never
    publishable unless the caller proves otherwise (both adapters keep
    ``publishable=False``). ``windows`` gives each score row's run and start.
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
    if model_input_rate_hz is not None:
        entry["model_input_rate_hz"] = float(model_input_rate_hz)
    if count > 0:
        entry["scores"] = [list(map(float, row)) for row in scores]
        entry["classes"] = list(classes)
        if windows is not None:
            entry["window_runs"] = [str(w["run"]) for w in windows]
            entry["window_starts_unix"] = [float(w["start_unix"]) for w in windows]
    if extra:
        entry.update(extra)
    return entry


__all__ = [
    "DEFAULT_ARTIFACT_ROOT", "LOCAL_STAGING_ROOT", "artifact_root", "flag_enabled",
    "sha256_file", "cached_sha256", "verify_file_sha256", "parse_ppg_payload",
    "iter_windows", "is_flat", "min_max01", "score_vector",
    "CLOCK_GATE_LEGACY", "CLOCK_GATE_PACKET_TIMING",
]
