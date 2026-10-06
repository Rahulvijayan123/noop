"""transition-data loaders, windowing, and resampling tests.

All datasets below are tiny SYNTHETIC trees written into pytest's tmp_path in each dataset's
native format - no real corpus is required. Each test plants 1-2 transitions and asserts label
maps, unit conversions, event times, boundary derivation, session splitting, window labeling
(positive / none / ambiguous / excluded), and the exact crop/pad/length behavior of
resample_window_to_30hz.
"""

import numpy as np
import pytest

from activity_context import transition_data as td
from activity_context.preprocess import resample_poly_nd

STS = "sit_to_stand"
STD = "stand_to_sit"
LIE = "lie_down"
GET = "get_up"


# ---------------------------------------------------------------------------
# Synthetic corpus writers
# ---------------------------------------------------------------------------

def _write_hapt(tmp_path) -> str:
    raw = tmp_path / "hapt" / "RawData"
    raw.mkdir(parents=True)
    n1 = 200  # exp01_user01: 4 s @ 50 Hz
    acc1 = np.zeros((n1, 3)); acc1[:, 2] = 1.0
    gyr1 = np.full((n1, 3), 0.5)
    np.savetxt(raw / "acc_exp01_user01.txt", acc1)
    np.savetxt(raw / "gyro_exp01_user01.txt", gyr1)
    n2 = 400  # exp02_user02: 8 s @ 50 Hz
    acc2 = np.zeros((n2, 3)); acc2[:, 1] = 2.0
    gyr2 = np.full((n2, 3), 1.0)
    np.savetxt(raw / "acc_exp02_user02.txt", acc2)
    np.savetxt(raw / "gyro_exp02_user02.txt", gyr2)
    labels = "\n".join([
        "1 1 8 50 100",     # SIT_TO_STAND -> sit_to_stand, midpoint 1.5 s
        "1 1 7 120 180",    # STAND_TO_SIT -> stand_to_sit, midpoint 3.0 s
        "1 1 5 10 40",      # STANDING state -> none time
        "2 2 9 50 100",     # SIT_TO_LIE -> lie_down
        "2 2 10 120 180",   # LIE_TO_SIT -> get_up
        "2 2 11 200 260",   # STAND_TO_LIE -> lie_down
        "2 2 12 300 360",   # LIE_TO_STAND -> get_up
    ]) + "\n"
    (raw / "labels.txt").write_text(labels)
    return str(tmp_path / "hapt")


def _write_pamap2(tmp_path) -> str:
    proto = tmp_path / "PAMAP2_Dataset" / "Protocol"
    proto.mkdir(parents=True)
    # Columns: ts, act, hr, temp, acc16 xyz, acc6 xyz, gyro xyz.
    def row(ts, act, acc, gyr, nan_sensor=False):
        if nan_sensor:
            acc = "nan nan nan"
        else:
            acc = f"{acc[0]} {acc[1]} {acc[2]}"
        return f"{ts} {act} 80.0 30.0 {acc} 0.0 0.0 0.0 {gyr[0]} {gyr[1]} {gyr[2]}"
    lines = []
    for k in range(100):                    # 0.00..0.99 lying
        lines.append(row(round(k * 0.01, 6), 1, (0, 0, 9.80665), (1.0, 0.0, 0.0)))
    for k in range(100):                    # 1.00..1.99 transient (activityID 0)
        lines.append(row(round(1.0 + k * 0.01, 6), 0, (0, 0, 9.80665), (1.0, 0.0, 0.0)))
    for k in range(100):                    # 2.00..2.99 sitting
        lines.append(row(round(2.0 + k * 0.01, 6), 2, (0, 0, 9.80665), (1.0, 0.0, 0.0)))
    for k in range(100):                    # 3.00..3.99 standing (one NaN sensor row @3.50)
        lines.append(row(round(3.0 + k * 0.01, 6), 3, (0, 0, 9.80665), (1.0, 0.0, 0.0),
                         nan_sensor=(k == 50)))
    for k in range(50):                     # 5.00..5.49 lying (gap 3.99 -> 5.00 = 1.01 s)
        lines.append(row(round(5.0 + k * 0.01, 6), 1, (0, 0, 9.80665), (1.0, 0.0, 0.0)))
    for k in range(50):                     # 5.50..5.99 sitting
        lines.append(row(round(5.5 + k * 0.01, 6), 2, (0, 0, 9.80665), (1.0, 0.0, 0.0)))
    (proto / "subject101.dat").write_text("\n".join(lines) + "\n")
    # subject102: standing -> sitting -> lying -> standing, plus a NaN-activity row that must
    # NOT create a spurious transition.
    lines2 = []
    for k in range(100):                    # 0.00..0.99 standing
        lines2.append(row(round(k * 0.01, 6), 3, (0, 9.80665, 0), (0.0, 1.0, 0.0)))
    for k in range(100):                    # 1.00..1.99 sitting (one NaN-activity row @1.50)
        act = "nan" if k == 50 else 2
        lines2.append(row(round(1.0 + k * 0.01, 6), act, (0, 9.80665, 0), (0.0, 1.0, 0.0)))
    for k in range(100):                    # 2.00..2.99 lying
        lines2.append(row(round(2.0 + k * 0.01, 6), 1, (0, 9.80665, 0), (0.0, 1.0, 0.0)))
    for k in range(100):                    # 3.00..3.99 standing
        lines2.append(row(round(3.0 + k * 0.01, 6), 3, (0, 9.80665, 0), (0.0, 1.0, 0.0)))
    (proto / "subject102.dat").write_text("\n".join(lines2) + "\n")
    return str(tmp_path / "PAMAP2_Dataset")


def _write_wisdm(tmp_path) -> str:
    root = tmp_path / "wisdm-dataset" / "raw" / "watch"
    acc_dir = root / "accel"
    gyr_dir = root / "gyro"
    acc_dir.mkdir(parents=True)
    gyr_dir.mkdir(parents=True)
    acc_lines, gyr_lines = [], []
    ts = 1_000_000_000
    for letter, count in (("D", 20), ("E", 20), ("D", 20)):   # 20 Hz, 50 ms apart
        for _ in range(count):
            acc_lines.append(f"1600,{letter},{ts},0.0,0.0,9.80665;")
            gyr_lines.append(f"1600,{letter},{ts},1.0,0.0,0.0;")
            ts += 50_000_000
    (acc_dir / "data_1600_accel_watch.txt").write_text("\n".join(acc_lines) + "\n")
    (gyr_dir / "data_1600_gyro_watch.txt").write_text("\n".join(gyr_lines) + "\n")
    return str(tmp_path / "wisdm-dataset")


def _write_forth(tmp_path) -> str:
    root = tmp_path / "forth" / "part0"
    root.mkdir(parents=True)
    # Timestamps are written in MILLISECONDS, as the real corpus is (verified empirically:
    # median step 20 ms = 1000/51.2; the loader scales to seconds).
    def row(dev, ts_ms, label, acc=(0.0, 0.0, 9.80665), gyr=(1.0, 0.0, 0.0)):
        return f"{dev},{acc[0]},{acc[1]},{acc[2]},{gyr[0]},{gyr[1]},{gyr[2]},0.0,0.0,0.0,{ts_ms},{label}"
    def region(lines, dev, ts0, label, n=100, dt_ms=20.0):
        for k in range(n):
            lines.append(row(dev, round((ts0 * 1000.0) + k * dt_ms, 4), label))
    dev1 = []
    region(dev1, 1, 0.0, 2)     # none
    region(dev1, 1, 2.0, 9)     # sit_to_stand region [2, 4)
    region(dev1, 1, 4.0, 12)    # excluded region [4, 6)
    region(dev1, 1, 6.0, 1)     # none
    region(dev1, 1, 8.0, 8)     # stand_to_sit region [8, 10)
    region(dev1, 1, 10.0, 13)   # excluded region [10, 12)
    region(dev1, 1, 12.0, 3)    # none
    (root / "part0dev1.csv").write_text("\n".join(dev1) + "\n")
    dev2 = ["device_id,ax,ay,az,gx,gy,gz,mx,my,mz,timestamp,label"]  # header must be skipped
    region(dev2, 2, 0.0, 10)    # stand_to_sit
    region(dev2, 2, 2.0, 11)    # sit_to_stand
    (root / "part0dev2.csv").write_text("\n".join(dev2) + "\n")
    dev3 = []  # dev3 is NOT part of the loader (dev1/dev2 only)
    region(dev3, 3, 0.0, 9)
    (root / "part0dev3.csv").write_text("\n".join(dev3) + "\n")
    return str(tmp_path / "forth")


def _session(duration_s=30.0, hz=20.0, events=(), excluded=()):
    """Directly-constructed synthetic session for windowing tests."""
    n = int(round(duration_s * hz))
    data = np.zeros((n, 6))
    data[:, 2] = 1.0
    evs = [td.TransitionEvent(kind=k, ts=t, onset_ts=t, offset_ts=t, subject="s",
                              dataset="syn", placement="wrist", session_id="s-0")
           for (t, k) in events]
    return td.TransitionSession(subject="s", dataset="syn", placement="wrist",
                                session_id="s-0", hz=hz, t0_ts=0.0, data=data,
                                events=evs, excluded=tuple(excluded))


# ---------------------------------------------------------------------------
# HAPT
# ---------------------------------------------------------------------------

def test_hapt_labels_units_and_event_times(tmp_path):
    sessions = td.load_hapt(_write_hapt(tmp_path))
    assert [s.session_id for s in sessions] == ["exp01", "exp02"]
    s1, s2 = sessions
    for s in (s1, s2):
        assert s.dataset == "hapt" and s.placement == "waist" and s.hz == 50.0 and s.t0_ts == 0.0
    assert s1.subject == "user1" and s2.subject == "user2"
    assert s1.data.shape == (200, 6) and s2.data.shape == (400, 6)
    np.testing.assert_array_equal(s1.data[:, 0:3],
                                  np.column_stack([np.zeros(200), np.zeros(200), np.ones(200)]))
    # HAPT RawData gyro is rad/s; the loader converts to the deg/s the features expect.
    np.testing.assert_allclose(s1.data[:, 3:6], np.full((200, 3), 0.5 * td.RAD_S_TO_DEG_S))
    np.testing.assert_array_equal(s2.data[:, 1], np.full(400, 2.0))
    np.testing.assert_allclose(s2.data[:, 3], np.full(400, td.RAD_S_TO_DEG_S))
    assert [(e.kind, e.ts, e.onset_ts, e.offset_ts) for e in s1.events] == [
        (STS, 1.5, 1.0, 2.0), (STD, 3.0, 2.4, 3.6)]
    assert [(e.kind, e.ts) for e in s2.events] == [(LIE, 1.5), (GET, 3.0), (LIE, 4.6), (GET, 6.6)]
    for e in s1.events:
        assert e.dataset == "hapt" and e.placement == "waist" and e.session_id == "exp01"
        assert e.subject == "user1"


def test_hapt_deterministic(tmp_path):
    root = _write_hapt(tmp_path)
    a = td.load_hapt(root)
    b = td.load_hapt(root)
    assert [s.session_id for s in a] == [s.session_id for s in b]
    for sa, sb in zip(a, b):
        np.testing.assert_array_equal(sa.data, sb.data)
        assert [(e.kind, e.ts) for e in sa.events] == [(e.kind, e.ts) for e in sb.events]


# ---------------------------------------------------------------------------
# PAMAP2
# ---------------------------------------------------------------------------

def test_pamap2_units_events_and_gap_splitting(tmp_path):
    sessions = td.load_pamap2(_write_pamap2(tmp_path))
    assert [s.session_id for s in sessions] == ["subject101-0", "subject101-1", "subject102-0"]
    s0, s1, s2 = sessions
    for s in sessions:
        assert s.dataset == "pamap2" and s.placement == "wrist" and s.hz == 100.0
    assert s0.subject == "subject101" and s0.t0_ts == pytest.approx(0.0)
    assert s0.data.shape == (399, 6)          # 400 rows minus the one NaN-sensor row
    # accel 9.80665 m/s^2 -> 1 g; gyro 1 rad/s -> 57.29577951308232 deg/s
    np.testing.assert_allclose(s0.data[:, 2], 1.0, atol=1e-12)
    np.testing.assert_allclose(s0.data[:, 3], td.RAD_S_TO_DEG_S, atol=1e-9)
    assert [(e.kind, e.ts) for e in s0.events] == [(GET, 2.0), (STS, 3.0)]
    assert s1.t0_ts == pytest.approx(5.0)
    assert [(e.kind, e.ts) for e in s1.events] == [(GET, 0.5)]
    assert [(e.kind, e.ts) for e in s2.events] == [(STD, 1.0), (LIE, 2.0), (GET, 3.0)]
    # the NaN-activity row at 1.5 inside sitting must not create a transition, and its valid
    # sensors stay in the data
    assert s2.data.shape[0] == 400


# ---------------------------------------------------------------------------
# WISDM
# ---------------------------------------------------------------------------

def test_wisdm_blocks_units_and_boundary_events(tmp_path):
    sessions = td.load_wisdm(_write_wisdm(tmp_path))
    assert [s.session_id for s in sessions] == ["1600-0", "1600-1", "1600-2"]
    s0, s1, s2 = sessions
    for s in sessions:
        assert s.dataset == "wisdm" and s.placement == "wrist" and s.hz == 20.0
        assert s.subject == "1600" and s.data.shape == (20, 6)
    assert s0.events == [] and s0.t0_ts == pytest.approx(1.0)
    assert [(e.kind, e.ts, e.onset_ts, e.offset_ts) for e in s1.events] == [(STS, 0.0, 0.0, 0.0)]
    assert [(e.kind, e.ts, e.onset_ts, e.offset_ts) for e in s2.events] == [(STD, 0.0, 0.0, 0.0)]
    assert s1.t0_ts == pytest.approx(2.0) and s2.t0_ts == pytest.approx(3.0)
    # accel z = 9.80665 m/s^2 -> 1 g; gyro x = 1 rad/s -> deg/s (the train.py unit path)
    np.testing.assert_allclose(s0.data[:, 2], 1.0, atol=1e-9)
    np.testing.assert_allclose(s0.data[:, 3], td.RAD_S_TO_DEG_S, atol=1e-9)


# ---------------------------------------------------------------------------
# FORTH-TRACE
# ---------------------------------------------------------------------------

def test_forth_units_regions_excluded_and_dev12_only(tmp_path):
    sessions = td.load_forth_trace(_write_forth(tmp_path))
    assert [s.session_id for s in sessions] == ["part0dev1", "part0dev2"]  # dev3 never loaded
    s1, s2 = sessions
    for s in sessions:
        assert s.dataset == "forth" and s.placement == "wrist" and s.hz == 51.2
    # subject is the PARTICIPANT (part0), shared by both wrists so participant-held-out
    # splitting never splits left/right wrist across train/test (spec s12)
    assert s1.subject == "part0" and s2.subject == "part0"
    assert s1.session_id == "part0dev1" and s2.session_id == "part0dev2"
    assert s1.t0_ts == pytest.approx(0.0)
    assert s1.data.shape == (700, 6)
    np.testing.assert_allclose(s1.data[:, 2], 1.0, atol=1e-9)     # 9.80665 m/s^2 -> 1 g
    np.testing.assert_allclose(s1.data[:, 3], 1.0, atol=1e-9)     # gyro already deg/s
    assert [(e.kind, e.ts, e.onset_ts, e.offset_ts) for e in s1.events] == [
        (STS, 3.0, 2.0, 4.0), (STD, 9.0, 8.0, 10.0)]
    assert s1.excluded == ((4.0, 6.0), (10.0, 12.0))              # labels 12/13 -> excluded
    assert [(e.kind, e.ts) for e in s2.events] == [(STD, 1.0), (STS, 3.0)]  # labels 10/11
    for e in s1.events:
        assert e.subject == "part0" and e.session_id == "part0dev1"
    # the FORTH header row on dev2 was skipped; dev3 is not loaded at all
    assert s2.data.shape == (200, 6)


# ---------------------------------------------------------------------------
# iter_windows labeling (positive / none / ambiguous / excluded / clipping)
# ---------------------------------------------------------------------------

def test_iter_windows_positive_none_ambiguous():
    s = _session(30.0, hz=20.0, events=[(5.0, STS), (20.0, STD)])
    wins = {round(start, 6): (end, data, label)
            for start, end, data, label in td.iter_windows(s)}
    assert len(wins) == 15                      # 30 s / 2 s hop
    assert wins[2.0][2] == STS                  # event 5.0 in inner [3, 5]
    assert wins[4.0][2] == STS                  # event 5.0 in inner [5, 7]
    assert wins[10.0][2] == "none"              # no event within +-3 s
    assert wins[18.0][2] == STD                 # event 20.0 in inner [19, 21]
    assert wins[6.0][2] is None                 # event 5.0 in the outer band -> ambiguous
    assert wins[14.0][2] is None                # event 20.0 in the outer band -> ambiguous
    assert wins[0.0][2] is None                 # event 5.0 in the outer band [-3, 7]
    assert wins[28.0][2] == "none"              # event 20.0 is 8 s away (outside the +-3 s band)


def test_iter_windows_slices_are_native_rate_and_ordered():
    s = _session(30.0, hz=20.0, events=[(5.0, STS)])
    wins = [(start, end, data) for start, end, data, _ in td.iter_windows(s)]
    assert wins[0][2].shape == (80, 6)          # [0, 4] -> samples 0..80
    assert wins[1][2].shape == (80, 6)          # [2, 6] -> samples 40..120
    np.testing.assert_array_equal(wins[1][2], s.data[40:120])
    starts = [w[0] for w in wins]
    assert starts == [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0,
                      20.0, 22.0, 24.0, 26.0, 28.0]
    # clipped right edge
    assert wins[-1][1] == pytest.approx(30.0)


def test_iter_windows_clips_to_session_bounds():
    s = _session(3.0, hz=20.0)                  # shorter than one window
    wins = list(td.iter_windows(s))
    # hop positions 0 and 2, each clipped to the session end (3 s)
    assert [(w[0], w[1], w[3]) for w in wins] == [(0.0, 3.0, "none"), (2.0, 3.0, "none")]
    assert wins[0][2].shape == (60, 6)          # 3 s * 20 Hz


def test_iter_windows_excluded_region_is_ambiguous_not_none():
    # excluded [4, 4.8]; one event far away at 15.0 so only exclusion affects [2,6] and [4,8]
    s = _session(20.0, hz=20.0, events=[(15.0, STS)], excluded=[(4.0, 4.8)])
    wins = {round(start, 6): label for start, end, data, label in td.iter_windows(s)}
    assert wins[0.0] == "none"                  # excluded [4,4.8] does not overlap [0,4]
    assert wins[2.0] is None                    # excluded [4,4.8] overlaps [2,6]
    assert wins[4.0] is None                    # excluded [4,4.8] overlaps [4,8]
    assert wins[6.0] == "none"                  # [6,10]: no overlap, no outer event
    assert wins[14.0] == STS                    # event 15.0 in inner [15,17]
    assert wins[8.0] is None                    # event 15.0 in outer band [5,15]


def test_iter_windows_ambiguity_when_two_classes_in_inner():
    s = _session(12.0, hz=20.0, events=[(3.0, STS), (3.1, STD)])
    wins = {round(start, 6): label for start, end, data, label in td.iter_windows(s)}
    assert wins[0.0] == STS                     # event 3.0 alone in inner [1,3]
    assert wins[2.0] is None                    # both events in inner [3,5] -> ambiguous
    assert wins[8.0] == "none"                  # 12 s session -> [8,12] clear


# ---------------------------------------------------------------------------
# resample_window_to_30hz (exact lengths / crop / pad / DC)
# ---------------------------------------------------------------------------

def test_resample_zero_is_exactly_zero():
    out = td.resample_window_to_30hz(np.zeros((200, 6)), 50.0)
    assert out.shape == (120, 6)
    assert (out == 0).all() and out.dtype == np.float64


def test_resample_lengths_and_dc_interior():
    for hz, n in [(50.0, 200), (100.0, 400), (20.0, 80), (51.2, 204), (51.2, 205)]:
        out = td.resample_window_to_30hz(np.ones((n, 6)), hz)
        assert out.shape == (120, 6), (hz, n)
        # windowed-sinc polyphase resampler preserves DC in the interior (edges carry the
        # FIR transient); the repo resampler is the canonical contract.
        assert np.abs(out[20:100] - 1.0).max() < 0.01
        assert out.min() >= 0.0 and out.max() <= 1.6


def test_resample_pads_short_windows_centered():
    # 8 samples @ 20 Hz -> 12 @ 30 Hz -> zero-padded to exactly 120, centered at [54:66).
    x = np.arange(8 * 6, dtype=np.float64).reshape(8, 6) / 10.0
    out = td.resample_window_to_30hz(x, 20.0)
    assert out.shape == (120, 6)
    assert (out[:54] == 0).all() and (out[66:] == 0).all()
    ref = resample_poly_nd(x, 3, 2)
    assert ref.shape == (12, 6)
    np.testing.assert_array_equal(out[54:66], ref)


def test_resample_crops_long_windows_centered():
    # 205 samples @ 51.2 Hz -> 121 @ 30 Hz -> center-cropped to exactly 120.
    x = np.ones((205, 6))
    out = td.resample_window_to_30hz(x, 51.2)
    assert out.shape == (120, 6)
    ref = resample_poly_nd(x, 75, 128)
    assert ref.shape[0] == 121
    np.testing.assert_array_equal(out, ref[:120])


def test_resample_exact_120_at_all_rates_is_identity_path():
    # A native window that resamples to exactly 120 must be returned unchanged.
    x = np.arange(120 * 6, dtype=np.float64).reshape(120, 6) / 100.0
    x50 = td.resample_window_to_30hz(resample_poly_nd(x, 5, 3), 50.0)
    assert x50.shape == (120, 6)


def test_resample_unsupported_rate_raises():
    with pytest.raises(ValueError):
        td.resample_window_to_30hz(np.zeros((120, 6)), 30.0)
    with pytest.raises(ValueError):
        td.resample_window_to_30hz(np.zeros((0, 6)), 50.0)
    with pytest.raises(ValueError):
        td.resample_window_to_30hz(np.zeros((10, 4)), 50.0)


def test_ontology_constants_pinned():
    assert td.CLASSES == ("none", "sit_to_stand", "stand_to_sit", "lie_down", "get_up")
    assert td.EVENT_KINDS == td.CLASSES[1:]
