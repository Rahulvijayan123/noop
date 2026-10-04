"""imu-feat-1 window features: encoder-independent facts about one 4 s / 30 Hz window."""

import math

import numpy as np
import pytest

from activity_context.features import FEATURE_SCHEMA, orientation_change_deg, window_features
from activity_context.preprocess import TARGET_HZ, WINDOW_SAMPLES, Window

KEYS = {"accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz", "cadence_strength",
        "orientation_change_deg"}


def _window(data: np.ndarray) -> Window:
    return Window(s=0.0, e=WINDOW_SAMPLES / TARGET_HZ, data=data)


def _still(gravity=(0.0, 0.0, 1.0), noise=0.0005, gyro=0.2, seed=1) -> np.ndarray:
    rng = np.random.default_rng(seed)
    d = np.zeros((WINDOW_SAMPLES, 6))
    d[:, 0:3] = np.array(gravity) + rng.normal(0, noise, (WINDOW_SAMPLES, 3))
    d[:, 3:6] = rng.normal(0, gyro, (WINDOW_SAMPLES, 3))
    return d


def _walking(cadence_hz=2.0, amp=0.25) -> np.ndarray:
    t = np.arange(WINDOW_SAMPLES) / TARGET_HZ
    d = np.zeros((WINDOW_SAMPLES, 6))
    d[:, 2] = 1.0 + amp * np.sin(2 * math.pi * cadence_hz * t)
    d[:, 0] = 0.4 * amp * np.sin(2 * math.pi * cadence_hz * t + 0.8)
    d[:, 3] = 30.0 * np.sin(2 * math.pi * cadence_hz * t)
    return d


def test_schema_name_is_pinned():
    assert FEATURE_SCHEMA == "imu-feat-1"


def test_still_wrist_reads_as_quiet():
    f = window_features(_window(_still()))
    assert set(f) == KEYS
    assert f["accel_rms_g"] < 0.005
    assert f["gyro_rms_dps"] < 1.0
    assert f["cadence_hz"] is None
    assert f["orientation_change_deg"] == pytest.approx(0.0, abs=1.0)


def test_walking_has_a_cadence_in_the_gait_band():
    f = window_features(_window(_walking(2.0)))
    assert f["accel_rms_g"] > 0.1
    assert f["gyro_rms_dps"] > 15
    assert f["cadence_hz"] == pytest.approx(2.0, abs=0.25)
    assert f["cadence_strength"] > 0.5


def test_a_faster_cadence_is_reported_faster():
    slow = window_features(_window(_walking(1.6)))["cadence_hz"]
    fast = window_features(_window(_walking(2.8)))["cadence_hz"]
    assert slow is not None and fast is not None
    assert fast > slow + 0.5


def test_a_turned_wrist_reports_the_turn():
    d = _still()
    half = WINDOW_SAMPLES // 2
    angle = math.radians(70)
    d[half:, 0:3] = np.array([math.sin(angle), 0.0, math.cos(angle)])
    assert orientation_change_deg(d) == pytest.approx(70.0, abs=2.0)
    assert window_features(_window(d))["orientation_change_deg"] == pytest.approx(70.0, abs=2.0)


def test_gravity_that_cannot_be_resolved_gives_none_not_a_guess():
    d = np.zeros((WINDOW_SAMPLES, 6))
    assert orientation_change_deg(d) is None
    assert window_features(_window(d))["orientation_change_deg"] is None


def test_every_value_is_finite_or_none():
    for data in (_still(), _walking(), np.zeros((WINDOW_SAMPLES, 6))):
        for value in window_features(_window(data)).values():
            assert value is None or math.isfinite(value)


def test_reusing_the_baselines_features_gives_the_same_answer():
    from activity_context.baseline import classify_window
    w = _window(_walking(2.2))
    assert window_features(w) == window_features(w, classify_window(w).features)
