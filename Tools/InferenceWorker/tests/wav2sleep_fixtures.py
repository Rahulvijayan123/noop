"""SYNTHETIC PPG fixtures for the wav2sleep adapter tests - not a recording of anyone.

No live overnight anchored capture exists yet, so every fixture here is a deterministic,
seeded synthetic PPG-like signal at a native WHOOP rate, shaped exactly like the anchored
segments the Spec 01 worker sends (docs/model-integration/README.md "PPG segments" on the Spec 01
branch, commits ff143411e + 0fd8b94d3): absolute ADC counts (a ~3.8e5-count DC level, an inverted
pulsatile component, slow drift, respiratory wander, a little noise), 300-s pieces carrying
``run_id``, ``config.identity`` (the optical configuration only - no burst counter),
``config.known``, ``config.stable`` and a ``clock`` with ``packet_timing_verified`` and
``samples_per_second`` (plus provenance-only ``source``/``grid``/``endpoint``).

The default rate is 25 Hz, the anchored v26 convention Spec 01 pinned in 0fd8b94d3 (anchor + 24
deltas per record; the next record's anchor is the 26th point). 24 Hz builders exercise the
earlier convention, which the adapter still accepts when declared.

The signal is engineered to be PPG-SHAPED for transport, preprocessing and parity tests. It has
no sleep-stage ground truth, and nothing computed from it is evidence of accuracy.
"""

from __future__ import annotations

import copy
import hashlib
from typing import Any, Optional, Sequence

import numpy as np

ANCHORED_RATE_HZ = 25
LEGACY_RATE_HZ = 24
SEGMENT_SECONDS = 300
#: 2026-06-08T07:00:07Z - deliberately 7 s past a UTC 30-s boundary, so run edges are exercised.
DEFAULT_START = 1_780_902_007
SYNTHETIC_NOTE = "SYNTHETIC fixture (tests/wav2sleep_fixtures.py); not a recording"
#: The optical configuration only (gain/drive/channel/LED) - never a per-burst counter.
DEFAULT_IDENTITY = "srcA=2;drvA=40;rngA=3;offA=0;led=green"


def clock_block(rate: int = ANCHORED_RATE_HZ) -> dict[str, Any]:
    return {"packet_timing_verified": True, "samples_per_second": int(rate),
            "source": "synthetic fixture: strap record ts",
            "grid": f"start_unix + j/{int(rate)}",
            "endpoint": "the next record's anchor belongs to the next second"}


def config_block(identity: str = DEFAULT_IDENTITY, burst_index: int = 1) -> dict[str, Any]:
    return {"stable": True, "identity": identity, "known": True, "burst_index": burst_index}


def synthetic_ppg(seconds: int, *, rate: int = ANCHORED_RATE_HZ, seed: int = 20261007,
                  t_offset: float = 0.0, dc: float = 380_000.0, ac: float = 1_500.0) -> np.ndarray:
    """``seconds * rate`` absolute ADC counts (int64) of a PPG-like waveform.

    Heart rate drifts 52-72 bpm with a ~90-min cycle, respiration ~14/min modulates baseline and
    pulse amplitude, the optical DC drifts slowly, and N(0, 25) noise is added. The pulse is
    inverted (more blood -> less light at the photodiode), as on a raw optical channel.
    """
    n = int(seconds) * int(rate)
    t = t_offset + np.arange(n, dtype=np.float64) / float(rate)
    hr_bpm = 62.0 + 7.0 * np.sin(2 * np.pi * t / 5400.0) + 3.0 * np.sin(2 * np.pi * t / 1700.0 + 1.0)
    phase = np.cumsum(hr_bpm / 60.0) / float(rate)
    frac = phase - np.floor(phase)
    systolic = np.exp(-0.5 * ((frac - 0.20) / 0.07) ** 2)
    diastolic = 0.45 * np.exp(-0.5 * ((frac - 0.48) / 0.10) ** 2)
    resp = np.sin(2 * np.pi * t * (14.0 / 60.0) + 0.3 * np.sin(2 * np.pi * t / 900.0))
    pulse = (systolic + diastolic) * (1.0 + 0.10 * resp)
    baseline = dc + 4_000.0 * np.sin(2 * np.pi * t / 20_000.0) + 150.0 * resp
    rng = np.random.default_rng(seed)
    signal = baseline - ac * pulse + rng.normal(0.0, 25.0, n)
    return np.rint(signal).astype(np.int64)


def segments_for_run(start: int, samples: np.ndarray, *, run_id: Optional[str],
                     rate: int = ANCHORED_RATE_HZ, config_identity: str = DEFAULT_IDENTITY,
                     piece_seconds: int = SEGMENT_SECONDS) -> list[dict[str, Any]]:
    """Split one contiguous run into endpoint-owned pieces (CONTRACTS section 4 + Spec 01)."""
    seconds = samples.size // rate
    out = []
    cursor = 0
    while cursor < seconds:
        span = min(piece_seconds, seconds - cursor)
        piece = samples[cursor * rate:(cursor + span) * rate]
        segment = {
            "start_unix": int(start + cursor),
            "duration_s": int(span),
            "samples": [int(v) for v in piece],
            "sample_count_per_second": int(rate),
            "config": config_block(config_identity),
            "clock": clock_block(rate),
        }
        if run_id is not None:
            segment["run_id"] = run_id
        out.append(segment)
        cursor += span
    return out


def night(runs: Sequence[tuple[int, int]], *, start: int = DEFAULT_START, seed: int = 20261007,
          rate: int = ANCHORED_RATE_HZ, window: Optional[tuple[int, int]] = None,
          lead_s: int = 120, tail_s: int = 60, identities: Optional[Sequence[str]] = None,
          run_ids: Optional[Sequence[Optional[str]]] = None) -> dict[str, Any]:
    """A night of runs given as ``(offset_s, seconds)`` from ``start``.

    The signal is ONE continuous synthetic waveform sampled at the run offsets, so a gap removes
    real samples instead of re-starting the waveform. Returns the request ``input`` payload plus
    per-run arrays (``_runs``) for tests.
    """
    total = max(offset + seconds for offset, seconds in runs)
    full = synthetic_ppg(total, rate=rate, seed=seed)
    segments: list[dict[str, Any]] = []
    run_arrays = []
    for k, (offset, seconds) in enumerate(runs):
        samples = full[offset * rate:(offset + seconds) * rate]
        identity = identities[k] if identities else DEFAULT_IDENTITY
        run_id = run_ids[k] if run_ids is not None else f"run-{k}"
        segments.extend(segments_for_run(start + offset, samples, run_id=run_id, rate=rate,
                                         config_identity=identity))
        run_arrays.append({"start": start + offset, "end": start + offset + seconds,
                           "samples": samples, "run_id": run_id})
    if window is None:
        window = (start - lead_s, start + total + tail_s)
    return {
        "window": {"start_utc": int(window[0]), "end_utc": int(window[1])},
        "ppg": {"native_rate_hz": int(rate), "units": "adc_counts", "segments": segments},
        "input_revision": "sha256:synthetic-fixture",
        "_runs": run_arrays,
        "_rate": int(rate),
        "_note": SYNTHETIC_NOTE,
    }


def payload(fixture: dict[str, Any], **config) -> dict[str, Any]:
    """The wire ``input`` (test-only keys stripped), optionally with gate overrides."""
    out = {k: v for k, v in fixture.items() if not k.startswith("_")}
    out = copy.deepcopy(out)
    if config:
        out["config"] = dict(config)
    return out


def context(fixture: dict[str, Any]) -> dict[str, Any]:
    return {
        "user_id": "11111111-2222-3333-4444-555555555555",
        "device_id": "whoop5-synthetic",
        "interval_start_utc": fixture["window"]["start_utc"],
        "interval_end_utc": fixture["window"]["end_utc"],
        "iana_timezone": "Europe/London",
        "profile_version": "p1",
        "config_version": "c1",
        "corrections_version": "k1",
    }


def run_digest(fixture: dict[str, Any]) -> str:
    """sha256 over the fixture's rate, run starts/ends and int64 samples (fixture identity)."""
    digest = hashlib.sha256()
    digest.update(f"rate={fixture['_rate']};".encode())
    for run in fixture["_runs"]:
        digest.update(f"{run['start']}:{run['end']};".encode())
        digest.update(np.ascontiguousarray(run["samples"], dtype="<i8").tobytes())
    return digest.hexdigest()


# Named fixtures used by the tests and by the official-code reference run ----------------------

#: A UTC 30-s boundary. 8 h + 1 s from here gives 960 whole epochs, so the pinned
#: predict_on_folder(max_length_hours=8) grid lies inside the run (no padding at all).
PARITY_START = 1_780_902_000


def parity_night_8h(rate: int = ANCHORED_RATE_HZ) -> dict[str, Any]:
    return night([(0, 8 * 3600 + 1)], start=PARITY_START, rate=rate, lead_s=0, tail_s=0,
                 window=(PARITY_START, PARITY_START + 8 * 3600 + 1))


def parity_night_gap(rate: int = ANCHORED_RATE_HZ) -> dict[str, Any]:
    """Two runs (4 h 10 min and 3 h 20 min) with a 17-min gap, unaligned starts."""
    return night([(0, 4 * 3600 + 600), (4 * 3600 + 600 + 1020, 3 * 3600 + 1200)], rate=rate)


def ten_hour_night(rate: int = ANCHORED_RATE_HZ) -> dict[str, Any]:
    """A full 10-hour window (the official max sequence) covered by one run."""
    return night([(0, 36_000)], start=PARITY_START, rate=rate, lead_s=0, tail_s=0,
                 window=(PARITY_START, PARITY_START + 36_000))


#: (name, builder, rate) for the official-code reference run and the real-weight parity tests.
PARITY_FIXTURES = (
    ("parity_8h_25hz", parity_night_8h, ANCHORED_RATE_HZ),
    ("parity_gap_25hz", parity_night_gap, ANCHORED_RATE_HZ),
    ("ten_hour_25hz", ten_hour_night, ANCHORED_RATE_HZ),
    ("parity_8h_24hz", parity_night_8h, LEGACY_RATE_HZ),
    ("parity_gap_24hz", parity_night_gap, LEGACY_RATE_HZ),
    ("ten_hour_24hz", ten_hour_night, LEGACY_RATE_HZ),
)
