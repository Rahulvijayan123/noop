"""inertia-prep-1 tests (spec §21.1): rate, anti-alias, gravity, axes, units, determinism, gaps,
duplicates, clock resets, NaN/Inf, too-short runs, exact boundaries, golden WHOOP fixture."""

import json
import os

import numpy as np
import pytest

pytest.importorskip("scipy")
from scipy.signal import butter, filtfilt, resample_poly  # noqa: E402

from activity_context.inertia import preprocess as ip  # noqa: E402
from activity_context.inertia.make_golden import golden_prep  # noqa: E402
from activity_context.preprocess import PreprocessError, decode_frame_hex, resample_poly_nd  # noqa: E402

from ._helpers import INERTIA_FIXTURES, T0, constant_columns, seconds_from_columns  # noqa: E402


def _tone(freq, n=2000, fs=100.0, amp=0.5):
    t = np.arange(n) / fs
    return np.stack([amp * np.sin(2 * np.pi * freq * t)] * 3, axis=1)


def _interior_rms(y, fs=20, edge_s=2):
    e = int(edge_s * fs)
    return float(np.sqrt(np.mean(y[e:-e] ** 2)))


def test_100_to_20_matches_scipy_reference_and_numpy_twin():
    x = np.random.default_rng(0).normal(size=(3000, 3))
    ref = resample_poly(filtfilt(*butter(4, 10, fs=100), x, axis=0), 1, 5, axis=0)
    out = ip.resample_to_20hz(x, 100)
    assert out.dtype == np.float32 and out.shape == (600, 3)
    assert np.array_equal(out, ref.astype(np.float32))
    twin = resample_poly_nd(filtfilt(*butter(4, 10, fs=100), x, axis=0), 1, 5, axis=0)
    assert np.abs(twin - ref).max() < 1e-12


@pytest.mark.parametrize("freq,limit", [(15.0, 0.01), (30.0, 1e-3), (45.0, 1e-3)])
def test_anti_alias_attenuates_above_10hz(freq, limit):
    y = ip.resample_to_20hz(_tone(freq), 100)
    assert _interior_rms(y) / (0.5 / np.sqrt(2)) < limit


@pytest.mark.parametrize("freq", [1.0, 1.8, 2.0, 3.6])
def test_gait_band_preserved(freq):
    y = ip.resample_to_20hz(_tone(freq), 100)
    assert abs(_interior_rms(y) / (0.5 / np.sqrt(2)) - 1.0) < 0.005


def test_gravity_units_and_axis_order_in_windows():
    cols = constant_columns(40, ax=0.1, ay=-0.2, az=0.9)
    w = ip.windows_from_seconds(seconds_from_columns(cols, T0), T0, T0 + 40, 30, 5)
    assert w, "a 40 s run must yield windows"
    for win in w:
        assert win.data.shape == (3, 600) and win.data.dtype == np.float32
        expect = np.array([round(0.1 * 4096) / 4096, round(-0.2 * 4096) / 4096, round(0.9 * 4096) / 4096])
        assert np.abs(win.data - expect[:, None]).max() < 1e-6        # gravity kept, ax/ay/az rows


def test_units_int16_4096_is_one_g():
    w = ip.windows_from_seconds(seconds_from_columns(constant_columns(12, az=1.0), T0), T0, T0 + 12, 10, 1)
    assert len(w) == 1 and np.abs(w[0].data[2] - 1.0).max() < 1e-6 and np.abs(w[0].data[:2]).max() < 1e-6


def test_determinism():
    from ._helpers import synth
    cols = synth(60, seed=5)
    a = ip.windows_from_seconds(seconds_from_columns(cols, T0), T0, T0 + 60, 30, 5)
    b = ip.windows_from_seconds(seconds_from_columns(cols, T0), T0, T0 + 60, 30, 5)
    assert [(x.s, x.e) for x in a] == [(x.s, x.e) for x in b]
    assert all(np.array_equal(x.data, y.data) for x, y in zip(a, b))


def test_gaps_split_runs_and_no_window_crosses():
    cols = constant_columns(80)
    secs = seconds_from_columns(cols[:40], T0) + seconds_from_columns(cols[40:], T0 + 45)   # 5 s gap
    w = ip.windows_from_seconds(secs, T0, T0 + 85, 10, 1)
    assert w
    for win in w:
        assert win.e <= T0 + 40 - 1 or win.s >= T0 + 45 + 1, (win.s, win.e)


def test_duplicate_and_clock_reset_rejected():
    cols = constant_columns(5)
    dup = seconds_from_columns(cols, T0)
    dup.insert(2, (T0 + 1, cols[0]))
    with pytest.raises(PreprocessError):
        ip.windows_from_seconds(dup, T0, T0 + 5, 10, 1)
    reset = seconds_from_columns(cols, T0) + [(T0 + 2, cols[0])]
    with pytest.raises(PreprocessError):
        ip.windows_from_seconds(reset, T0, T0 + 5, 10, 1)


def test_nonfinite_rejected():
    bad = np.full(600, np.nan, dtype=np.float64)
    with pytest.raises(PreprocessError):
        ip.windows_from_seconds([(T0, bad)], T0, T0 + 1, 10, 1)
    x = np.ones((500, 3))
    x[10, 1] = np.inf
    with pytest.raises(PreprocessError):
        ip.resample_to_20hz(x, 100)


def test_too_short_runs_produce_no_windows():
    for n, want in ((31, 0), (32, 1)):
        w = ip.windows_from_seconds(seconds_from_columns(constant_columns(n), T0), T0, T0 + n, 30, 1)
        assert len(w) == want
    with pytest.raises(ip.SegmentTooShort):
        ip.resample_to_20hz(np.ones((15, 3)), 100)


def test_exact_boundaries():
    secs = seconds_from_columns(constant_columns(32), T0)
    w = ip.windows_from_seconds(secs, T0 + 1, T0 + 31, 30, 5)               # exactly fits
    assert [(x.s - T0, x.e - T0) for x in w] == [(1, 31)]
    assert ip.windows_from_seconds(secs, T0 + 1, T0 + 30, 30, 5) == []       # one second short
    w = ip.windows_from_seconds(secs, T0, T0 + 32, 30, 1)                    # grid start T0 is too close to edge
    assert [(x.s - T0, x.e - T0) for x in w] == [(1, 31)]
    assert ip.windows_from_seconds(secs, T0, T0 + 32, 30, 2) == []           # grid T0, T0+2: neither fits


def test_grid_anchored_at_request_start():
    secs = seconds_from_columns(constant_columns(130), T0 - 3)
    w = ip.windows_from_seconds(secs, T0, T0 + 120, 30, 15)
    assert [x.s - T0 for x in w] == [0, 15, 30, 45, 60, 75, 90]
    assert all(x.e - x.s == 30 for x in w)


def test_window_hop_validation():
    for window, hop in ((20, 5), (30, 3), (10, 15), (True, 1), (30, 2.5)):
        with pytest.raises(PreprocessError):
            ip.validate_window_hop(window, hop)
    assert ip.validate_window_hop(30, 30) == (30, 30) and ip.validate_window_hop(10.0, 5) == (10, 5)


def test_resample_to_20hz_other_rates():
    x = _tone(2.0, n=1000, fs=50.0)
    y = ip.resample_to_20hz(x, 50)
    ref = resample_poly(filtfilt(*butter(4, 10, fs=50), x, axis=0), 2, 5, axis=0).astype(np.float32)
    assert np.array_equal(y, ref)
    z = ip.resample_to_20hz(_tone(2.0, n=2560, fs=25.6), 25.6)               # non-integer -> interp
    assert z.shape == (int(np.floor(2559 * 20 / 25.6)) + 1, 3)
    # np.interp (the contract's method for non-integer rates) itself damps a 2 Hz tone by ~2% at 25.6 Hz.
    assert abs(_interior_rms(z) / (0.5 / np.sqrt(2)) - 1.0) < 0.03
    x20 = np.random.default_rng(1).normal(size=(100, 3))
    assert np.array_equal(ip.resample_to_20hz(x20, 20), x20.astype(np.float32))
    with pytest.raises(PreprocessError):
        ip.resample_to_20hz(x20, 10)


def test_segment_on_gaps():
    t = np.array([0.0, 0.01, 0.02, 1.5, 1.51, 1.51, 1.52, 0.5, 0.51])
    assert [(s.start, s.stop) for s in ip.segment_on_gaps(t)] == [(0, 3), (3, 5), (5, 7), (7, 9)]
    assert ip.segment_on_gaps(np.array([])) == []
    assert [(s.start, s.stop) for s in ip.segment_on_gaps(np.arange(5.0), max_gap_s=1.0)] == [(0, 5)]
    with pytest.raises(PreprocessError):
        ip.segment_on_gaps(np.array([0.0, np.nan]))


def test_golden_whoop_frames_fixture():
    with open(os.path.join(INERTIA_FIXTURES, "golden_inertia_prep.json")) as f:
        golden = json.load(f)
    fresh = golden_prep()
    assert [(w["s"], w["e"]) for w in fresh["windows"]] == [(w["s"], w["e"]) for w in golden["windows"]]
    assert [(w["s"] - golden["start_ts"], w["e"] - golden["start_ts"]) for w in golden["windows"]] == [(1, 11)]
    for a, b in zip(fresh["windows"], golden["windows"]):
        assert np.abs(np.array(a["data"]) - np.array(b["data"])).max() <= 1e-6
    # The decoded frames really are the WHOOP golden format (first frame decodes at baseTs).
    with open(os.path.join(INERTIA_FIXTURES, "..", "golden_imu_frames.json")) as f:
        ts, _cols = decode_frame_hex(json.load(f)["frames"][0])
    assert ts == golden["start_ts"]
