"""Fault handling: malformed/gapped/nonfinite input never becomes a valid
stationary window; gaps never manufacture windows (spec s6/s12)."""

import json
import os

import numpy as np
import pytest

from activity_context import preprocess as pp
from activity_context.baseline import classify_window

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")


def _golden_seconds():
    with open(os.path.join(FIXTURES, "golden_imu_frames.json")) as f:
        gj = json.load(f)
    seconds = []
    for hx in gj["frames"]:
        base_ts, cols = pp.decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    return seconds


def test_wrong_column_length_rejected():
    seconds = _golden_seconds()
    bad = np.zeros(599, dtype=np.int16)
    with pytest.raises(pp.PreprocessError, match="malformed"):
        pp.decode_seconds([(seconds[0][0], bad)])


def test_nan_columns_rejected_never_a_window():
    seconds = _golden_seconds()
    _, cols = seconds[0]
    nan_cols = cols.astype(np.float64)
    nan_cols[0] = np.nan
    with pytest.raises(pp.PreprocessError, match="nonfinite"):
        pp.decode_seconds([(seconds[0][0], nan_cols)])


def test_mixed_gap_never_crossing_and_never_stationary_from_gap():
    with open(os.path.join(FIXTURES, "golden_imu_mixed.json")) as f:
        mj = json.load(f)
    seconds = []
    for hx in mj["frames"]:
        base_ts, cols = pp.decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    wins = pp.windows_from_seconds(seconds, start, end)
    assert wins, "expected at least one window"
    for w in wins:
        # 1007 is missing: no window may straddle it
        assert not (w.s < 1007 < w.e)
        # the gap alone never yields stationary
        assert not (w.s == 1006.0 and pp.window_energy(w) < 0.05)


def test_window_with_nan_never_stationary():
    seconds = _golden_seconds()
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    wins = pp.windows_from_seconds(seconds, start, end)
    w = wins[0]
    w.data[10, 0] = np.nan
    assert classify_window(w).label == "unknown"


def test_duplicate_and_clock_reset_rejected():
    seconds = _golden_seconds()
    dup = [seconds[0], seconds[0]] + seconds[1:]
    with pytest.raises(pp.PreprocessError, match="duplicate"):
        pp.decode_seconds(dup)
    reset = [(seconds[0][0] + 5, seconds[0][1]), (seconds[0][0], seconds[0][1])]
    with pytest.raises(pp.PreprocessError, match="clock reset"):
        pp.decode_seconds(reset)


def test_empty_input_yields_no_windows():
    assert pp.windows_from_seconds([], 0, 1) == []
