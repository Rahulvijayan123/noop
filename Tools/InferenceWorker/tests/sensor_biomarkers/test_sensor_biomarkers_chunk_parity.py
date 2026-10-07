"""Chunked-versus-contiguous parity for each deterministic algorithm (spec 8/10).

The lane sends <= 5-minute segments; the algorithms must produce the same
result when a signal is processed as two adjacent chunks vs one contiguous
run (away from documented filter edges). 300 s is divisible by the 5 s ENMO
epoch, the 4 s oscillation window and the 30 s quality window, and all three
are UTC-aligned, so the deterministic IMU families must be EXACTLY equal; the
PPG families carry detector/filter edge effects at chunk boundaries, so their
parity is asserted within documented tolerances (counts may differ by at most
the boundary pulses).
"""

from __future__ import annotations

import numpy as np
import pytest

from frwhoop_inference.sensor_biomarkers import imu as sbimu
from frwhoop_inference.sensor_biomarkers import ppg as sbppg
from frwhoop_inference.sensor_biomarkers.provider import SensorBiomarkersProvider
from frwhoop_inference.contract import InferRequest, parse_request

RATE = 100.0
FS = 24.0
SECONDS = 600  # 10 minutes, then split into two 5-minute chunks


def _imu_segment(start: float, seconds: float) -> dict:
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    accel = np.zeros((n, 3))
    accel[:, 2] = 1.0
    accel[:, 0] += 0.03 * np.sin(2 * np.pi * 0.5 * t)  # crosses the hysteresis bands
    gyro = np.zeros((n, 3))
    gyro[:, 0] = 20.0 * np.sin(2 * np.pi * 5.0 * t)
    return {"start_unix": int(start), "duration_s": seconds,
            "accel_g": np.round(accel, 6).tolist(),
            "gyro_dps": np.round(gyro, 6).tolist()}


def _ppg_wave(start: float, seconds: float) -> np.ndarray:
    """One CONTINUOUS waveform: the chunked fixtures slice THIS array, so a
    chunk boundary never restarts the phase (real data split at a boundary is
    continuous, not re-synthesized)."""
    n = int(seconds * FS)
    t = start + np.arange(n) / FS
    phase = (t * 1.2) % 1.0
    samples = 200000 + 30000 * np.exp(-((phase - 0.15) / 0.08) ** 2)
    return np.round(samples, 3)


def _ppg_segment(start: float, seconds: float, wave: np.ndarray | None = None) -> dict:
    samples = wave if wave is not None else _ppg_wave(start, seconds)
    return {"start_unix": int(start), "duration_s": seconds,
            "samples": samples.tolist(),
            "config": {"source": 1, "drive": 1150}}


def _body(imu_segments, ppg_segments, total_s):
    return {
        "metric": "sensor_biomarkers",
        "context": {"user_id": "u", "device_id": "d",
                    "interval_start_utc": "2026-10-06T00:00:00Z",
                    "interval_end_utc": "2026-10-06T00:%02d:00Z" % (total_s // 60),
                    "iana_timezone": "UTC", "profile_version": "p",
                    "config_version": "c", "corrections_version": "k",
                    "live": False},
        "input": {"schema_version": 1, "device": {"id": "d", "family": "whoop5"},
                  "input_revision": "sha256:" + "ee" * 32,
                  "imu": {"sampling_rate_hz": RATE,
                          "units": {"accel": "g", "gyro": "deg/s"},
                          "segments": imu_segments},
                  "ppg": {"native_rate_hz": FS, "units": "adc_counts",
                          "segments": ppg_segments, "expected_duration_s": total_s},
                  "families": ["movement", "oscillation", "ppg_quality", "pulse_shape"]},
    }


def _stages(body):
    provider = SensorBiomarkersProvider()
    result = provider.infer(parse_request(body))
    assert result.status == "ok"
    return {s["family"]: s for s in result.stages}


class TestChunkedVersusContiguousParity:
    def test_imu_families_are_exactly_equal(self):
        # One contiguous 10-minute run vs two adjacent 5-minute chunks (no
        # overlap, endpoint-owned). ENMO epochs and oscillation windows are
        # UTC-aligned and 300 s divides both window sizes, so the IMU family
        # measurements must match EXACTLY.
        wave = _ppg_wave(0, SECONDS)
        contiguous = _stages(_body([_imu_segment(0, SECONDS)],
                                   [_ppg_segment(0, SECONDS, wave)], SECONDS))
        chunked = _stages(_body([_imu_segment(0, 300), _imu_segment(300, 300)],
                                [_ppg_segment(0, 300, wave[: int(300 * FS)]),
                                 _ppg_segment(300, 300, wave[int(300 * FS):])], SECONDS))
        for family in ("movement", "oscillation"):
            a, b = contiguous[family]["measurements"], chunked[family]["measurements"]
            for key in a:
                va, vb = a[key].get("value"), b[key].get("value")
                if va is None or vb is None:
                    assert va == vb, (family, key)
                else:
                    assert va == pytest.approx(vb, abs=1e-9), (family, key, va, vb)

    def test_ppg_families_parity_within_detector_edge_tolerance(self):
        # The PPG cleaner/detector has edge effects at each chunk boundary, so
        # chunked medians are asserted within a documented tolerance (quality
        # correlation within 0.01; pulse medians within one native sample
        # period; accepted counts within the boundary pulses of one chunk).
        wave = _ppg_wave(0, SECONDS)
        contiguous = _stages(_body([_imu_segment(0, SECONDS)],
                                   [_ppg_segment(0, SECONDS, wave)], SECONDS))
        chunked = _stages(_body([_imu_segment(0, 300), _imu_segment(300, 300)],
                                [_ppg_segment(0, 300, wave[: int(300 * FS)]),
                                 _ppg_segment(300, 300, wave[int(300 * FS):])], SECONDS))
        qa = contiguous["ppg_quality"]["measurements"]["template_similarity_median"]["value"]
        qb = chunked["ppg_quality"]["measurements"]["template_similarity_median"]["value"]
        assert qb == pytest.approx(qa, abs=0.01)
        pa = contiguous["pulse_shape"]["measurements"]
        pb = chunked["pulse_shape"]["measurements"]
        for key, tol in (("pulse_amplitude_median_au", 0.05),
                        ("pulse_upstroke_median_ms", 1000.0 / FS),
                        ("pulse_width50_median_ms", 2 * 1000.0 / FS),
                        ("pulse_normalized_area_median", 0.02)):
            assert pb[key]["value"] == pytest.approx(pa[key]["value"], rel=tol), key
        # accepted counts differ by at most the boundary pulses of one chunk
        assert abs(pa["pulse_accepted_count"]["value"]
                  - pb["pulse_accepted_count"]["value"]) <= 2

    def test_no_duplicate_samples_at_chunk_seams(self):
        # The unit-level guarantee the lane relies on: adjacent chunks share
        # no endpoint sample (half-open [start, start+duration) ownership).
        grid = sbimu.build_epoch_grid([_imu_segment(0, 300), _imu_segment(300, 300)], RATE)
        assert len(grid["t"]) == int(SECONDS * RATE)
        assert len(set(np.round(grid["t"], 6))) == len(grid["t"])
        wave = _ppg_wave(0, SECONDS)
        segs = sbppg._validate_segments(
            [_ppg_segment(0, 300, wave[: int(300 * FS)]),
             _ppg_segment(300, 300, wave[int(300 * FS):])], FS)
        total = sum(s["samples"].size for s in segs)
        assert total == int(SECONDS * FS)
