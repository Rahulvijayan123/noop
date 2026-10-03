"""Baseline heuristic classifier tests (operational baseline, spec s7)."""

import numpy as np
import pytest

from activity_context.baseline import classify_window, extract_features
from activity_context.preprocess import Window


def _window_from_fn(fn, seconds=4, hz=30, seed=0):
    rng = np.random.default_rng(seed)
    n = int(seconds * hz)
    t = np.arange(n) / hz
    data = fn(t, rng)
    return Window(s=0.0, e=seconds, data=data.astype(np.float64))


def _walking_window():
    def fn(t, rng):
        cad = 1.8
        ax = 0.10 * np.sin(2 * np.pi * cad * t) + 0.01 * rng.standard_normal(len(t))
        ay = 0.08 * np.sin(2 * np.pi * cad * t + 0.7)
        az = 1.0 + 0.10 * np.sin(2 * np.pi * cad * t) + 0.03 * np.sin(2 * np.pi * 2 * cad * t)
        gx = 10.0 * np.sin(2 * np.pi * cad * t)
        gy = 8.0 * np.sin(2 * np.pi * cad * t + 0.5)
        gz = 2.0 * np.sin(2 * np.pi * cad * t)
        return np.stack([ax, ay, az, gx, gy, gz], axis=1)
    return _window_from_fn(fn)


def _running_window():
    def fn(t, rng):
        cad = 2.8
        ax = 0.30 * np.sin(2 * np.pi * cad * t)
        ay = 0.25 * np.sin(2 * np.pi * cad * t + 0.7)
        az = 1.0 + 0.25 * np.sin(2 * np.pi * cad * t) + 0.05 * np.sin(2 * np.pi * 2 * cad * t)
        gx = 30.0 * np.sin(2 * np.pi * cad * t)
        gy = 24.0 * np.sin(2 * np.pi * cad * t + 0.3)
        gz = 10.0 * np.sin(2 * np.pi * cad * t)
        return np.stack([ax, ay, az, gx, gy, gz], axis=1)
    return _window_from_fn(fn)


def _stationary_window():
    def fn(t, rng):
        data = 0.001 * rng.standard_normal((len(t), 6))
        data[:, 2] += 1.0                      # gravity only
        return data
    return _window_from_fn(fn)


def test_walking_classified_walking():
    res = classify_window(_walking_window())
    assert res.label == "walking"
    assert res.probs["walking"] == 1.0


def test_running_classified_running():
    res = classify_window(_running_window())
    assert res.label == "running"


def test_stationary_classified_stationary():
    res = classify_window(_stationary_window())
    assert res.label == "stationary"


def test_golden_walking_windows_all_walking():
    import json, os
    from activity_context.preprocess import decode_frame_hex, windows_from_seconds
    fixtures = os.path.join(os.path.dirname(__file__), "..", "fixtures")
    gj = json.load(open(os.path.join(fixtures, "golden_imu_frames.json")))
    seconds = []
    for hx in gj["frames"]:
        base_ts, cols = decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    wins = windows_from_seconds(seconds, start, end)
    assert wins
    for w in wins:
        assert classify_window(w).label == "walking"


def test_nonfinite_window_never_stationary():
    w = _stationary_window()
    w.data[0, 0] = np.nan
    res = classify_window(w)
    assert res.label == "unknown"


def test_features_match_expected_ranges():
    f = extract_features(_walking_window())
    assert 1.2 <= f.cadence_hz <= 3.5
    assert f.cadence_strength >= 0.30
    assert f.accel_energy_g > 0.02
    f2 = extract_features(_stationary_window())
    assert f2.accel_energy_g < 0.02
    assert f2.cadence_hz is None


def test_probs_are_heuristic_not_calibrated():
    res = classify_window(_walking_window())
    # one-hot heuristic: sum to 1 but documented as uncalibrated
    assert abs(sum(res.probs.values()) - 1.0) < 1e-9
