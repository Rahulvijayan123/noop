"""eldernet-prep-1: upstream-identical nearest-neighbour 30 Hz, request-anchored grid, runs never bridged."""

import numpy as np
import pytest

from activity_context.eldernet import WINDOW_SAMPLES
from activity_context.eldernet.preprocess import (PreprocessError, nearest_index_uniform, resample_timestamps,
                                                  resample_uniform, stack_windows, window_indices,
                                                  windows_from_array, windows_from_seconds)

from ._helpers import T0, g_to_columns, seconds_from_columns, synth_g


def _actipy_nearest(n, fs):
    """actipy.processing.resample (3.7/3.8) index map, re-run with pandas exactly as upstream calls it."""
    pd = pytest.importorskip("pandas")
    index = pd.date_range("2000-01-01", periods=n, freq=f"{int(round(1000 / fs))}ms")
    t0, tf = index[0], index[-1]
    nt = int(np.around((tf - t0).total_seconds() * 30)) + 1
    t = pd.date_range(t0, t0 + pd.Timedelta((nt - 1) / 30, unit="s"), periods=nt)
    return index.get_indexer(t, method="nearest", tolerance=pd.Timedelta("1s"), limit=1)


@pytest.mark.parametrize("n,fs", [(100, 100), (1001, 100), (1002, 100), (1005, 100), (12345, 100), (60000, 100),
                                  (777, 50), (5000, 50)])
def test_nearest_map_equals_actipy(n, fs):
    assert np.array_equal(nearest_index_uniform(n, fs), _actipy_nearest(n, fs))


def test_100hz_map_pattern_and_window_reads_only_its_own_ten_seconds():
    idx = nearest_index_uniform(1000, 100)
    assert idx[:7].tolist() == [0, 3, 7, 10, 13, 17, 20]
    w = window_indices(7, 100)
    assert w[0] == 700 and w[-1] == 1697 and len(w) == WINDOW_SAMPLES
    assert np.array_equal(w, 700 + window_indices(0, 100))


def test_resample_timestamps_matches_uniform_on_a_uniform_clock():
    x = synth_g(30, "walk", seed=2)
    t = 5.0 + np.arange(len(x)) / 100.0
    assert np.array_equal(resample_timestamps(t, x), resample_uniform(x, 100))


def test_resample_rejects_nonfinite_and_bad_shapes():
    x = synth_g(12, "still")
    x[5, 1] = np.nan
    with pytest.raises(PreprocessError):
        resample_uniform(x, 100)
    with pytest.raises(PreprocessError):
        resample_uniform(np.zeros((10, 2)), 100)


def test_grid_is_anchored_at_request_start_and_inside_the_run():
    cols = g_to_columns(synth_g(40, "walk"))
    secs = seconds_from_columns(cols, T0 - 3)                       # run starts 3 s before the request
    w = windows_from_seconds(secs, T0, T0 + 30, hop_s=5)
    assert [x.s - T0 for x in w] == [0, 5, 10, 15, 20]
    assert all(x.e == x.s + 10 for x in w)
    assert all(x.data.shape == (WINDOW_SAMPLES, 3) for x in w)


def test_gap_splits_runs_and_no_window_spans_it():
    cols = g_to_columns(synth_g(60, "walk"))
    secs = seconds_from_columns(cols[:25], T0) + seconds_from_columns(cols[27:], T0 + 27)   # 2 s gap
    w = windows_from_seconds(secs, T0, T0 + 60, hop_s=1)
    for x in w:
        assert x.e <= T0 + 25 or x.s >= T0 + 27
    assert {x.s - T0 for x in w} == set(range(0, 16)) | set(range(27, 51))


def test_duplicate_and_clock_reset_are_errors():
    cols = g_to_columns(synth_g(20, "still"))
    secs = seconds_from_columns(cols, T0)
    with pytest.raises(PreprocessError):
        windows_from_seconds(secs[:10] + [secs[9]] + secs[10:], T0, T0 + 20, 1)
    with pytest.raises(PreprocessError):
        windows_from_seconds(secs[:10] + [(T0 + 3, cols[10])], T0, T0 + 20, 1)


def test_bad_hop_is_rejected():
    cols = g_to_columns(synth_g(20, "still"))
    with pytest.raises(PreprocessError):
        windows_from_seconds(seconds_from_columns(cols, T0), T0, T0 + 20, 3)


def test_chunking_independence_of_window_samples():
    cols = g_to_columns(synth_g(120, "walk", seed=5))
    secs = seconds_from_columns(cols, T0)
    whole = {w.s: w.data for w in windows_from_seconds(secs, T0, T0 + 120, 1)}
    a = windows_from_seconds(secs[:70], T0, T0 + 70, 1)
    b = windows_from_seconds(secs[50:], T0 + 50, T0 + 120, 1)
    for w in a + b:
        assert np.array_equal(w.data, whole[w.s])
    assert len({w.s for w in a + b}) == len(whole)                  # the overlap covers every window


def test_whoop_path_equals_offline_array_path():
    acc = synth_g(45, "walk", seed=9)
    cols = g_to_columns(acc)
    q = np.array([c[:300].reshape(3, 100).T for c in cols]).reshape(-1, 3) / 4096.0
    off = windows_from_array(q, 100, hop_s=1, t0=T0)
    on = windows_from_seconds(seconds_from_columns(cols, T0), T0, T0 + 45, 1)
    assert [w.s for w in off] == [w.s for w in on]
    assert np.array_equal(stack_windows(off), stack_windows(on))


def test_offline_nonfinite_samples_split_the_recording():
    acc = synth_g(40, "walk")
    acc[1500:1510] = np.nan                                          # 15.00-15.10 s
    w = windows_from_array(acc, 100, hop_s=1)
    for x in w:
        assert x.e <= 15.0 or x.s >= 15.1
    assert np.isfinite(stack_windows(w)).all()
