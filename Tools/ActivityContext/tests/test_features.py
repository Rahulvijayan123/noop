"""imu-feat-2 window features: encoder-independent facts about one 4 s / 30 Hz window.

Pins the imu-feat-2 contract (WS-04-F01..F06): gyro RMS (not mean), jerk per-second (g/s),
0.8-3.5 Hz cadence band, 2-s orientation horizon, and the shared cross-runtime golden fixture.
"""

import json
import math
import os

import numpy as np
import pytest

from activity_context.features import FEATURE_SCHEMA, orientation_change_deg, window_features
from activity_context.preprocess import TARGET_HZ, WINDOW_SAMPLES, Window

KEYS = {"accel_rms_g", "gyro_rms_dps", "jerk_rms_gps", "cadence_hz", "cadence_strength",
        "orientation_change_deg"}

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")


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
    # imu-feat-2: jerk became per-second (g/s) and the cadence band widened to 0.8-3.5 Hz;
    # stored imu-feat-1 decoder output is invalidated by the bump (ActivityContextVersions).
    assert FEATURE_SCHEMA == "imu-feat-2"


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


# ---------------------------------------------------------------------------
# imu-feat-2 contract pins (WS-04-F01/F02/F05/F06)
# ---------------------------------------------------------------------------

def _golden_signal(hz=30, seconds=4.0, amp=0.25, cad=2.0, gyro_amp=45.0) -> np.ndarray:
    """Shared imu-feat-2 golden signal (see fixtures/imu_feat2_golden.json): a 2 Hz gait tone on
    gravity + a zero-mean 45 dps gyro sinusoid. The zero-mean gyro is exactly the case where
    RMS (31.82) differs from the old mean (28.65), so the fixture cannot hide a mean-vs-RMS bug."""
    n = int(seconds * hz)
    t = np.arange(n) / hz
    d = np.zeros((n, 6))
    d[:, 2] = 1.0 + amp * np.sin(2 * math.pi * cad * t)
    d[:, 3] = gyro_amp * np.sin(2 * math.pi * cad * t)
    return d


def test_gyro_is_rms_not_mean():
    # Zero-mean 45 dps sinusoid: RMS = 45/sqrt(2) = 31.82; the old mean read 28.65.
    f = window_features(_window(_golden_signal()))
    assert f["gyro_rms_dps"] == pytest.approx(31.82, abs=0.02)
    assert f["gyro_rms_dps"] > 31.0  # RMS, not the ~28.6 mean


def test_jerk_is_per_second_and_matches_the_golden_fixture():
    with open(os.path.join(FIXTURES, "imu_feat2_golden.json")) as fh:
        golden = json.load(fh)
    case = next(c for c in golden["cases"] if c["runtime"] == "python")
    f = window_features(_window(_golden_signal()))
    assert f["jerk_rms_gps"] == pytest.approx(case["jerk_rms_gps"], abs=0.001)
    # Units: per-second (g/s), not per-sample: the same window at 30 Hz must be > 1 g/s,
    # whereas the old per-sample value was ~0.073 (3.1x smaller at 100 Hz; WS-04-F02).
    assert f["jerk_rms_gps"] > 1.0


def test_cross_runtime_golden_fixture_values_pinned():
    """The committed golden fixture (python 30 Hz vs swift 100 Hz) stays numerically consistent:
    accel/gyro/cadence are rate-invariant and the per-second jerk agrees within the documented
    bandwidth tolerance (<=5% clean, WS-04-F02)."""
    with open(os.path.join(FIXTURES, "imu_feat2_golden.json")) as fh:
        golden = json.load(fh)
    py = next(c for c in golden["cases"] if c["runtime"] == "python")
    sw = next(c for c in golden["cases"] if c["runtime"] == "swift")
    f = window_features(_window(_golden_signal()))
    assert f["accel_rms_g"] == pytest.approx(py["accel_rms_g"], abs=0.001)
    assert f["gyro_rms_dps"] == pytest.approx(py["gyro_rms_dps"], abs=0.01)
    assert f["cadence_hz"] == pytest.approx(py["cadence_hz"], abs=0.01)
    assert f["cadence_strength"] == pytest.approx(py["cadence_strength"], abs=0.01)
    assert py["accel_rms_g"] == pytest.approx(sw["accel_rms_g"], abs=0.001)
    assert py["gyro_rms_dps"] == pytest.approx(sw["gyro_rms_dps"], abs=0.01)
    rel = abs(py["jerk_rms_gps"] - sw["jerk_rms_gps"]) / sw["jerk_rms_gps"]
    assert rel <= golden["tolerances"]["cross_rate_jerk_rel"]


def test_slow_gait_cadence_reported_in_the_widened_band():
    # imu-feat-2 band is 0.8-3.5 Hz (was 1.2-3.5): a 0.9 Hz (54 spm) gait is now reported instead of
    # None/other_movement. The FEATURE is honest; classifier thresholds stay conservative and slow
    # gait RECOGNITION still needs longer windows (~8 s; WS-04-F03).
    d = _golden_signal(cad=0.9, gyro_amp=30.0)
    f = window_features(_window(d))
    assert f["cadence_hz"] is not None
    assert 0.8 <= f["cadence_hz"] <= 3.5
    assert f["cadence_hz"] == pytest.approx(0.9, abs=0.15)
    assert f["cadence_strength"] >= 0.20


def test_effective_cadence_upper_bound_at_30_hz():
    # WS-04-F05: cadence is quantised to rate/lag, so the effective upper edge at 30 Hz is 30/9
    # = 3.333 Hz (not the documented 3.5). A 3.4 Hz tone must report the effective bound.
    d = _golden_signal(cad=3.4, gyro_amp=30.0)
    f = window_features(_window(d))
    assert f["cadence_hz"] is not None
    assert f["cadence_hz"] <= 3.333 + 1e-6


def test_orientation_horizon_is_two_seconds():
    # Constant 30 dps rotation: half-window centers are 2 s apart -> 60 deg (WS-04-F04).
    hz, seconds = 30, 4.0
    n = int(seconds * hz)
    t = np.arange(n) / hz
    d = np.zeros((n, 6))
    omega = math.radians(30.0)
    d[:, 1] = np.sin(omega * t)
    d[:, 2] = np.cos(omega * t)
    assert orientation_change_deg(d) == pytest.approx(60.0, abs=0.5)
