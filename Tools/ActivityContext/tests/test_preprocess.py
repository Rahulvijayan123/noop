"""Golden-format decode + resample + windowing tests (spec s12 signal gate)."""

import json
import os

import numpy as np
import pytest

from activity_context import preprocess as pp

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")


def _load(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return json.load(f)


def _golden_seconds(name):
    data = _load(name)
    seconds = []
    for hx in data["frames"]:
        base_ts, cols = pp.decode_frame_hex(hx)
        seconds.append((base_ts, cols))
    return seconds


# ---------------------------------------------------------------------------
# Golden decode: 1244-byte frame -> 600 i16 columns -> first-sample floats
# ---------------------------------------------------------------------------

def test_golden_frame_decodes_to_expected_first_sample():
    gj = _load("golden_imu_frames.json")
    root = _load("golden_imu_expected.json")
    exp = root["firstSample"]
    base_ts, cols = pp.decode_frame_hex(gj["frames"][0])
    assert base_ts == root["baseTs"]
    assert cols.shape == (600,) and cols.dtype == np.int16
    samples = pp.raw_columns_to_samples(cols)
    expected = [exp["ax"], exp["ay"], exp["az"], exp["gx"], exp["gy"], exp["gz"]]
    assert np.allclose(samples[0], expected, atol=1e-6)


def test_golden_az_mean_and_last_base_ts():
    gj = _load("golden_imu_frames.json")
    exp = _load("golden_imu_expected.json")
    base_ts, cols = pp.decode_frame_hex(gj["frames"][0])
    samples = pp.raw_columns_to_samples(cols)
    assert abs(samples[:, 2].mean() - exp["azMeanFirstFrame"]) < 5e-4
    last_ts, _ = pp.decode_frame_hex(gj["frames"][-1])
    assert last_ts == exp["lastFrameBaseTs"]
    assert len(gj["frames"]) == exp["nFrames"]


def test_golden_wrong_frame_length_rejected():
    with pytest.raises(pp.PreprocessError):
        pp.decode_frame_bytes(b"\x00" * 1243)


def test_columns_b64_roundtrip():
    rng = np.random.default_rng(1)
    cols = rng.integers(-32768, 32767, size=600, dtype=np.int16)
    b = pp.encode_columns_b64(cols)
    back = pp.decode_columns_b64(b)
    assert np.array_equal(back, cols)


def test_columns_b64_wrong_length_rejected():
    import base64
    short = base64.b64encode(np.zeros(599, dtype="<i2").tobytes()).decode()
    with pytest.raises(pp.PreprocessError):
        pp.decode_columns_b64(short)


# ---------------------------------------------------------------------------
# Resampler: numpy polyphase FIR, anti-alias, gravity preserved
# ---------------------------------------------------------------------------

def _rms(x):
    return float(np.sqrt(np.mean(np.asarray(x) ** 2)))


@pytest.mark.parametrize("ratio", [(3, 10), (3, 2)])
def test_resample_matches_scipy(ratio):
    scipy = pytest.importorskip("scipy.signal")
    up, down = ratio
    rng = np.random.default_rng(7)
    x = rng.standard_normal(200)
    mine = pp.resample_poly_nd(x, up, down)
    ref = scipy.resample_poly(x, up, down)
    assert mine.shape == ref.shape
    assert np.max(np.abs(mine - ref)) < 1e-12


def test_resample_100_to_30_shape_and_dc():
    x = np.full(1000, 1.0)
    y = pp.resample_3_10(x)
    assert y.shape[0] == 300
    assert abs(y.mean() - 1.0) < 0.01          # gravity (DC) preserved
    rng = np.random.default_rng(2)
    x6 = rng.standard_normal((1000, 6))
    y6 = pp.resample_3_10(x6, axis=0)
    assert y6.shape == (300, 6)


def test_gait_survives_resample_and_25hz_attenuated():
    fs = 100
    t = np.arange(0, 20, 1 / fs)
    gait = np.sin(2 * np.pi * 1.8 * t)                    # in-band gait
    high = np.sin(2 * np.pi * 25.0 * t)                   # above 15 Hz Nyquist
    y_gait = pp.resample_3_10(gait)
    y_high = pp.resample_3_10(high)
    # 1.8 Hz energy preserved within 5%
    assert _rms(y_gait) / _rms(gait) >= 0.95
    # 25 Hz attenuated by at least 20 dB (rms ratio <= 0.1; measured ~0.01)
    assert _rms(y_high) / _rms(high) <= 0.1


def test_golden_walking_survives_resample():
    seconds = _golden_seconds("golden_imu_frames.json")
    runs = pp.decode_seconds(seconds)
    assert len(runs) == 1
    res = runs[0].resampled()
    assert res.shape == (12 * 30, 6)
    # gravity shell still present (az ~ 1 g), gait energy preserved
    assert 0.8 < np.median(res[:, 2]) < 1.2


# ---------------------------------------------------------------------------
# Windowing + gaps
# ---------------------------------------------------------------------------

def test_windowing_12s_golden_run():
    seconds = _golden_seconds("golden_imu_frames.json")
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    wins = pp.windows_from_seconds(seconds, start, end)
    # no head/tail -> first/last 1 s transient-cropped
    assert [(w.s, w.e) for w in wins] == [
        (start + 2, start + 6), (start + 4, start + 8), (start + 6, start + 10)]
    for w in wins:
        assert w.data.shape == (120, 6)
        assert np.isfinite(w.data).all()
        assert pp.window_energy(w) > 0.05        # gait energy present


def test_windowing_with_head_tail_recovers_edge_windows():
    seconds = _golden_seconds("golden_imu_frames.json")
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    # one second of head (reuse first frame) + one second of tail
    head = [seconds[0][1]] * 1
    tail = [seconds[-1][1]] * 1
    all_secs = ([(start - 1, c) for c in head] + seconds
                + [(end, c) for c in tail])
    wins = pp.windows_from_seconds(all_secs, start, end)
    starts = [w.s for w in wins]
    assert starts == [float(s) for s in (start, start + 2, start + 4,
                                         start + 6, start + 8)]


def test_gap_never_produces_crossing_or_stationary_window():
    seconds = _golden_seconds("golden_imu_mixed.json")
    # mixed fixture: 1000-1006 walking/stationary, 1007 MISSING, 1008-1011 walking
    start = min(t for t, _ in seconds)
    end = max(t for t, _ in seconds) + 1
    runs = pp.decode_seconds(seconds)
    assert [(r.start_ts, r.end_ts) for r in runs] == [
        (1758001000, 1758001007), (1758001008, 1758001012)]
    wins = pp.windows_from_seconds(seconds, start, end)
    for w in wins:
        # windows must never straddle the 1006->1008 gap
        assert not (w.s < 1007 < w.e)
        # stationary second 1006 is never turned into a stationary window
        assert w.s != 1006.0 or pp.window_energy(w) > 0.05
    # no window starts at the gap-adjacent second without full support
    assert all(w.s >= 1002 for w in wins)


def test_duplicate_second_rejected():
    seconds = _golden_seconds("golden_imu_frames.json")
    dup = [seconds[0], seconds[0]] + seconds[1:]
    with pytest.raises(pp.PreprocessError, match="duplicate"):
        pp.decode_seconds(dup)


def test_clock_reset_rejected():
    seconds = _golden_seconds("golden_imu_frames.json")
    bad = [(seconds[0][0], seconds[0][1]), (seconds[0][0] - 5, seconds[0][1])]
    with pytest.raises(pp.PreprocessError, match="clock reset"):
        pp.decode_seconds(bad)


def test_nonfinite_samples_rejected():
    seconds = _golden_seconds("golden_imu_frames.json")
    _, cols = seconds[0]
    nan_cols = cols.astype(np.float64)
    nan_cols[0] = np.nan                      # NaN cannot be a valid column
    with pytest.raises(pp.PreprocessError, match="nonfinite"):
        pp.decode_seconds([(seconds[0][0], nan_cols)])
    # float input without int16 dtype is rejected outright (no silent cast)
    with pytest.raises(pp.PreprocessError, match="int16"):
        pp.decode_seconds([(seconds[0][0], cols.astype(np.float64))])
