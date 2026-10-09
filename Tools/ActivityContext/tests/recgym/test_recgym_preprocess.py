"""``recgym-prep-1``: units, gravity removal, anti-aliased 20 Hz, the absolute 2 s grid, runs and digests."""

import hashlib

import numpy as np
import pytest

from activity_context.preprocess import PreprocessError, Run, resample_poly_nd
from activity_context.recgym import STANDARD_GRAVITY
from activity_context.recgym import preprocess as P

from ._helpers import T0, imu_to_columns, seconds_from_columns, synth_imu


def test_unit_mapping_matches_recgyms_released_scale():
    a = np.array([[0.0, 40.0, -40.0], [8.0, -80.0, 0.01]])
    w = np.array([[0.0, 800.0, -800.0], [160.0, 2000.0, -0.0625]])
    u = P.to_recgym_units(a, w)
    assert np.allclose(u[0], [0.5, 1.0, 0.0, 0.5, 1.0, 0.0])
    assert np.allclose(u[1], [0.6, 0.0, 0.500125, 0.6, 1.0, 0.5 - 0.0625 / 1600])
    assert u.min() >= 0.0 and u.max() <= 1.0


@pytest.mark.parametrize("gravity", [(0, 0, 1), (1, 0, 0), (0, -1, 0), (0.6, 0.0, 0.8), (-0.5, 0.5, -0.7071)])
def test_a_still_strap_has_no_linear_acceleration_in_any_orientation(gravity):
    g = np.asarray(gravity, np.float64)
    g = g / np.linalg.norm(g)
    x = np.zeros((1000, 6))
    x[:, 0:3] = g
    lin = P.linear_acceleration_ms2(x)
    # Madgwick's normalised gradient step keeps a beta-sized jitter around the exact attitude (~1 mrad): ~0.01 m/s^2,
    # far below the 0.14 m/s^2 a still wrist reads in RecGym
    assert np.max(np.abs(lin)) < 0.03


def test_gravity_is_tracked_through_rotation_with_the_gyroscope():
    acc, gyr = synth_imu(30, kind="curl", seed=1)
    x = np.concatenate([acc, gyr], axis=1)
    lin = P.linear_acceleration_ms2(x)
    # the strap only rotates: its true linear acceleration is ~0; without gravity removal it would be ~10 m/s^2
    settled = lin[300:]
    assert np.sqrt(np.mean(settled ** 2)) < 0.5
    naive = (acc - acc.mean(axis=0)) * STANDARD_GRAVITY
    assert np.sqrt(np.mean(naive[300:] ** 2)) > 3.0


def test_the_initial_orientation_reproduces_the_measured_gravity():
    for g in ([0.0, 0.0, 1.0], [0.3, -0.4, 0.866], [-1.0, 0.0, 0.0], [0.0, 0.0, -1.0]):
        q0, q1, q2, q3 = P.initial_quaternion(np.asarray([g]))
        est = [2 * (q1 * q3 - q0 * q2), 2 * (q0 * q1 + q2 * q3), q0 * q0 - q1 * q1 - q2 * q2 + q3 * q3]
        assert np.allclose(est, np.asarray(g) / np.linalg.norm(g), atol=1e-12)


def test_resampling_is_scipys_resample_poly_and_removes_aliases():
    rng = np.random.default_rng(3)
    x = rng.normal(size=(1000, 6))
    got = resample_poly_nd(x, 1, 5)
    signal = pytest.importorskip("scipy.signal")
    assert np.max(np.abs(got - signal.resample_poly(x, 1, 5, axis=0))) < 1e-12
    t = np.arange(2000) / 100.0
    tone = np.sin(2 * np.pi * 17.0 * t)[:, None]          # above the 10 Hz Nyquist of the 20 Hz stream
    assert np.sqrt(np.mean(resample_poly_nd(tone, 1, 5)[40:-40] ** 2)) < 0.02


def test_windows_sit_on_the_absolute_even_second_grid_inside_the_request_and_run_margins():
    acc, gyr = synth_imu(40, kind="walk")
    cols = imu_to_columns(acc, gyr)
    secs = seconds_from_columns(cols, T0 + 1)              # run starts on an odd second
    wins = P.windows_from_seconds(secs, T0 + 1, T0 + 41)
    starts = [w.s for w in wins]
    assert all(s % 2 == 0 for s in starts)
    assert starts[0] == T0 + 1 + P.HEAD_MARGIN_S + 1       # first even second after the head margin
    assert starts[-1] + 4 <= T0 + 41 - P.TAIL_MARGIN_S
    assert np.all(np.diff(starts) == 2)
    assert all(w.e == w.s + 4 and w.data.shape == (80, 6) for w in wins)
    assert all(0.0 <= w.data.min() and w.data.max() <= 1.0 for w in wins)
    # the request bounds the windows, the head/tail seconds only feed the filters
    inner = P.windows_from_seconds(secs, T0 + 10, T0 + 20)
    assert [w.s for w in inner] == [T0 + 10, T0 + 12, T0 + 14, T0 + 16]


def test_the_input_digest_names_the_raw_seconds_a_window_covers():
    acc, gyr = synth_imu(20, kind="walk")
    cols = imu_to_columns(acc, gyr)
    wins = P.windows_from_seconds(seconds_from_columns(cols), T0, T0 + 20)
    w = wins[0]
    h = hashlib.sha256()
    for t in range(w.s, w.s + 4):
        h.update(cols[t - T0].astype("<i2").tobytes())
    assert w.input_sha256 == h.hexdigest()
    assert len({x.input_sha256 for x in wins}) == len(wins)


def test_gaps_split_runs_and_never_produce_windows_across_them():
    acc, gyr = synth_imu(60, kind="walk")
    cols = imu_to_columns(acc, gyr)
    secs = [s for s in seconds_from_columns(cols) if not (T0 + 20 <= s[0] < T0 + 25)]
    wins = P.windows_from_seconds(secs, T0, T0 + 60)
    for w in wins:
        assert w.e <= T0 + 20 - P.TAIL_MARGIN_S or w.s >= T0 + 25 + P.HEAD_MARGIN_S


def test_bad_seconds_are_refused():
    acc, gyr = synth_imu(10, kind="still")
    cols = imu_to_columns(acc, gyr)
    secs = seconds_from_columns(cols)
    with pytest.raises(PreprocessError):
        P.windows_from_seconds(secs + [secs[-1]], T0, T0 + 10)
    with pytest.raises(PreprocessError):
        P.windows_from_seconds([(T0, np.zeros(599, np.int16))], T0, T0 + 1)


def test_windows_are_deterministic_and_chunking_only_touches_the_filter_start():
    acc, gyr = synth_imu(120, kind="curl", seed=5)
    cols = imu_to_columns(acc, gyr)
    secs = seconds_from_columns(cols)
    whole = {w.s: w for w in P.windows_from_seconds(secs, T0, T0 + 120)}
    again = {w.s: w for w in P.windows_from_seconds(secs, T0, T0 + 120)}
    assert all(np.array_equal(whole[k].data, again[k].data) for k in whole)
    # a chunk of the same run that starts later (with 3 s of head context, as the worker sends it)
    chunk = {w.s: w for w in P.windows_from_seconds(secs[57:], T0 + 60, T0 + 120)}
    assert set(chunk) <= set(whole)
    assert T0 + 60 in chunk
    late = [k for k in chunk if k >= T0 + 80]
    assert late and max(np.max(np.abs(chunk[k].data - whole[k].data)) for k in late) < 2e-3


def test_a_still_strap_maps_to_the_recgym_centre():
    acc, gyr = synth_imu(20, kind="still")
    wins = P.windows_from_seconds(seconds_from_columns(imu_to_columns(acc, gyr)), T0, T0 + 20)
    data = np.stack([w.data for w in wins])
    assert np.max(np.abs(data - 0.5)) < 0.01
