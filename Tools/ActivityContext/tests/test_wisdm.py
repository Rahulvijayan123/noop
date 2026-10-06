"""WISDM watch loader (wisdm-watch-loader-2) on synthetic WISDM-format files.

The fixture reproduces what broke v0's training data: activities whose timestamps jump backwards
between activities (the per-subject gyro array is not sorted), a gyro file in a different activity
order from the accel file, a 50 Hz accel / 25 Hz gyro block, a 20 Hz -> 100 Hz switch inside a block,
a block without gyro, a >1 s gap, a 300 ms dropout, one dropped sample and duplicated rows. Every
signal is an analytic function of the timestamp, so each 30 Hz output sample can be checked against
the truth at its own time.
"""

import json
import math
import os

import numpy as np
import pytest

from activity_context import train as T
from activity_context import wisdm as W
from activity_context.preprocess import Run, resample_poly_nd, windows_from_run

G = 9.80665
DEG = math.pi / 180.0
SUBJECT = 1700


def acc_g(t):
    t = np.asarray(t, dtype=np.float64)
    return np.stack([0.3 * np.sin(2 * np.pi * 1.0 * t), 0.2 * np.cos(2 * np.pi * 0.7 * t),
                     1.0 + 0.1 * np.sin(2 * np.pi * 1.3 * t)], axis=-1)


def gyr_dps(t):
    t = np.asarray(t, dtype=np.float64)
    return np.stack([20.0 * np.sin(2 * np.pi * 0.9 * t + 0.3), 15.0 * np.cos(2 * np.pi * 1.1 * t),
                     5.0 * np.sin(2 * np.pi * 0.5 * t)], axis=-1)


def _ts(start_ns, rate_hz, seconds, drop=()):
    step = int(round(1e9 / rate_hz))
    n = int(round(seconds * rate_hz))
    ts = start_ns + step * np.arange(n, dtype=np.int64)
    return np.delete(ts, list(drop)) if drop else ts


def _rows(act, ts, sensor):
    t = ts / 1e9
    v = acc_g(t) * G if sensor == "accel" else gyr_dps(t) * DEG
    return [(act, int(a), *map(float, b)) for a, b in zip(ts, v)]


# (activity, accel ts, gyro ts) in ACCEL FILE order. Timestamps jump backwards between activities.
def scenario(base=0):
    s = {}
    s["A"] = (_ts(base + 5_000_000_000_000, 20, 40, drop=[300]),      # one dropped sample (both)
              _ts(base + 5_000_000_000_000, 20, 40, drop=[300]))
    s["D"] = (_ts(base + 1_000_000_000_000, 20, 30), _ts(base + 1_000_000_000_000, 20, 30))
    # 50 Hz accel, gyro on every other accel instant at 25 Hz (subjects 1637-1640)
    s["B"] = (_ts(base + 3_000_000_000_000, 50, 40), _ts(base + 3_000_000_000_000, 25, 40))
    s["E"] = (_ts(base + 2_000_000_000_000, 20, 20), None)              # no gyro at all
    # C: 20 s, 3 s gap (new recording), 20 s with a 300 ms dropout after 10 s
    c1 = _ts(base + 4_000_000_000_000, 20, 20)
    c2 = _ts(base + 4_000_000_000_000 + 23_000_000_000, 20, 20)
    c2 = c2[(c2 < c2[0] + 10_000_000_000) | (c2 >= c2[0] + 10_300_000_000)]
    s["C"] = (np.r_[c1, c2], np.r_[c1, c2])
    # F: 20 Hz for 15 s then 100 Hz for 15 s inside one recording
    f1 = _ts(base + 6_000_000_000_000, 20, 15)
    f2 = _ts(int(f1[-1]) + 10_000_000, 100, 15)
    s["F"] = (np.r_[f1, f2], np.r_[f1, f2])
    return s


def write_subject(root, subject, scen, gyro_order=("B", "C", "A", "F", "D"), duplicate_d=True):
    acc_dir = os.path.join(root, "raw", "watch", "accel")
    gyr_dir = os.path.join(root, "raw", "watch", "gyro")
    os.makedirs(acc_dir, exist_ok=True)
    os.makedirs(gyr_dir, exist_ok=True)
    acc_lines, gyr_lines = [], []
    for act, (ta, _) in scen.items():
        rows = _rows(act, ta, "accel")
        if act == "D" and duplicate_d:
            rows = rows + rows[:50]                     # duplicated rows (subject 1629's files)
        acc_lines += [f"{subject},{a},{t},{x:.9f},{y:.9f},{z:.9f};" for a, t, x, y, z in rows]
    for act in gyro_order:
        tg = scen[act][1]
        if tg is None:
            continue
        gyr_lines += [f"{subject},{a},{t},{x:.9f},{y:.9f},{z:.9f};"
                      for a, t, x, y, z in _rows(act, tg, "gyro")]
    with open(os.path.join(acc_dir, f"data_{subject}_accel_watch.txt"), "w") as f:
        f.write("\n".join(acc_lines) + "\n")
    with open(os.path.join(gyr_dir, f"data_{subject}_gyro_watch.txt"), "w") as f:
        f.write("\n".join(gyr_lines) + "\n")


@pytest.fixture(scope="module")
def wisdm_dir(tmp_path_factory):
    root = str(tmp_path_factory.mktemp("wisdm"))
    write_subject(root, SUBJECT, scenario())
    return root


@pytest.fixture(scope="module")
def subject_data(wisdm_dir):
    return W.load_subject(wisdm_dir, SUBJECT)


def _interior(p, margin_s=1.0):
    m = int(margin_s * 30)
    k = np.arange(m, p.n - m)
    t = p.t0_ns / 1e9 + k / 30.0
    return k, t


# ---------------------------------------------------------------------------
# The fixture really triggers v0's bug
# ---------------------------------------------------------------------------

def test_fixture_reproduces_the_v0_zero_fill(wisdm_dir):
    """v0's merge: searchsorted every accel timestamp into the file-order gyro array (not sorted),
    zero where nothing is within 100 ms. On this fixture whole activities that HAVE gyro get zeros."""
    acc = W.parse_raw(W.subject_paths(wisdm_dir, SUBJECT)[0], SUBJECT)
    gyr = W.parse_raw(W.subject_paths(wisdm_dir, SUBJECT)[1], SUBJECT)
    assert np.any(np.diff(gyr.ts_ns) < 0)                       # unsorted across activities
    idx = np.clip(np.searchsorted(gyr.ts_ns, acc.ts_ns), 0, len(gyr.ts_ns) - 1)
    matched = np.abs(gyr.ts_ns[idx] - acc.ts_ns) <= 100_000_000
    per_act = {a: matched[acc.activity == a].mean() for a in "ABCDF"}   # all have gyro
    assert min(per_act.values()) < 0.05                         # an activity got all-zero gyro
    assert (~matched[acc.activity != "E"]).mean() > 0.15


# ---------------------------------------------------------------------------
# Loader behaviour
# ---------------------------------------------------------------------------

def test_no_zero_gyro_and_gyro_matches_its_own_timestamps(subject_data):
    assert subject_data.pieces
    for p in subject_data.pieces:
        assert np.isfinite(p.samples).all()
        for k in W.window_starts(p.n):
            assert not np.all(p.samples[k:k + 120, 3:6] == 0.0)
        k, t = _interior(p)
        # A's single missing sample (index 300, t = 15 s) is a linear interpolation: exclude 1 s around
        keep = np.abs(t - (5_000_000_000_000 / 1e9 + 15.0)) > 1.0
        k, t = k[keep], t[keep]
        np.testing.assert_allclose(p.samples[k, 3:6], gyr_dps(t + p.offset_s), atol=0.15)
        np.testing.assert_allclose(p.samples[k, 0:3], acc_g(t), atol=3e-3)


def test_block_without_gyro_is_excluded_and_reported(subject_data):
    assert not [p for p in subject_data.pieces if p.activity == "E"]
    rec = [r for r in subject_data.recordings if r.activity == "E"]
    assert len(rec) == 1 and rec[0].reason == "no_gyro" and rec[0].n_windows == 0


def test_50hz_accel_25hz_gyro_block_keeps_real_time(subject_data):
    ps = [p for p in subject_data.pieces if p.activity == "B"]
    assert len(ps) == 1
    p = ps[0]
    assert (p.acc_nominal_hz, p.gyr_nominal_hz) == (50, 25)
    assert p.acc_ratio == (3, 5) and p.gyr_ratio == (6, 5)
    assert abs(p.duration_s - 40.0) < 0.1                       # not 2.5x stretched (v0: 100 s)
    k, t = _interior(p)
    np.testing.assert_allclose(p.samples[k, 0:3], acc_g(t), atol=3e-3)
    np.testing.assert_allclose(p.samples[k, 3:6], gyr_dps(t + p.offset_s), atol=0.15)


def test_rate_switch_inside_a_block_gives_one_piece_per_rate(subject_data):
    ps = sorted([p for p in subject_data.pieces if p.activity == "F"], key=lambda p: p.t0_ns)
    assert [p.acc_nominal_hz for p in ps] == [20, 100]
    assert [p.acc_ratio for p in ps] == [(3, 2), (3, 10)]
    for p in ps:
        k, t = _interior(p)
        np.testing.assert_allclose(p.samples[k, 0:3], acc_g(t), atol=3e-3)


def test_gap_and_dropout_split_and_no_window_spans_them(subject_data):
    ps = sorted([p for p in subject_data.pieces if p.activity == "C"], key=lambda p: p.t0_ns)
    recs = [r for r in subject_data.recordings if r.activity == "C"]
    assert len(recs) == 2                                       # the 3 s gap starts a new recording
    assert len(ps) == 3                                         # 300 ms dropout splits recording 1
    base = 4_000_000_000_000 / 1e9
    holes = [(base + 20.0, base + 23.0), (base + 33.0, base + 33.3)]
    for p in ps:
        t0 = p.t0_ns / 1e9
        for k in W.window_starts(p.n):
            ws, we = t0 + k / 30.0, t0 + (k + 120) / 30.0
            for h0, h1 in holes:
                assert we <= h0 + 1e-6 or ws >= h1 - 1e-6


def test_single_dropout_repaired_and_duplicates_collapsed(subject_data):
    assert subject_data.acc_stats.n_repaired == 1 and subject_data.gyr_stats.n_repaired == 1
    ps = [p for p in subject_data.pieces if p.activity == "A"]
    assert len(ps) == 1 and abs(ps[0].duration_s - 40.0) < 0.1
    k, t = _interior(ps[0])                     # near the repair: linear-interpolation error only
    np.testing.assert_allclose(ps[0].samples[k, 3:6], gyr_dps(t), atol=1.0)
    assert subject_data.acc_stats.n_exact_duplicates == 50
    assert subject_data.acc_stats.n_conflicting_dropped == 0


def test_conflicting_duplicates_dropped():
    ts = np.array([3, 1, 2, 2, 4], dtype=np.int64)
    xyz = np.array([[3, 3, 3], [1, 1, 1], [2, 2, 2], [9, 9, 9], [4, 4, 4]], dtype=np.float64)
    t, v, n_exact, n_conf = W.sorted_unique(ts, xyz)
    assert t.tolist() == [1, 3, 4] and n_exact == 0 and n_conf == 2
    assert v[:, 0].tolist() == [1, 3, 4]


def test_jittered_50hz_clock_is_fitted():
    """Delivery jitter like the 1637-1640 watches (+-1.5 ms per timestamp plus late/early pairs that
    sum to two periods): no break, no repair, and the least-squares clock keeps samples on time."""
    rng = np.random.default_rng(3)
    ta = _ts(7_000_000_000_000, 50, 30)
    ja = ta + rng.integers(-1_500_000, 1_500_000, ta.size)
    for i in (100, 400, 900, 1200):
        ja[i] += 17_000_000                     # one late delivery, the next sample on time
    tg = ta[::2] + rng.integers(-1_500_000, 1_500_000, ta[::2].size)
    st = W.StreamStats()
    segs_a = W.constant_rate_segments(ja, acc_g(ta / 1e9), st)
    segs_g = W.constant_rate_segments(tg, gyr_dps(ta[::2] / 1e9), st)
    assert len(segs_a) == 1 and len(segs_g) == 1 and st.n_repaired == 0 and st.n_breaks == 0
    assert abs(segs_a[0].rate_hz - 50.0) < 0.01 and abs(segs_g[0].rate_hz - 25.0) < 0.01
    ps = W.align_segments(segs_a[0], segs_g[0], SUBJECT, "B", 0)
    assert len(ps) == 1
    k, t = _interior(ps[0])
    np.testing.assert_allclose(ps[0].samples[k, 0:3], acc_g(t), atol=0.01)
    np.testing.assert_allclose(ps[0].samples[k, 3:6], gyr_dps(t + ps[0].offset_s), atol=0.6)


# ---------------------------------------------------------------------------
# Resampler and ratio
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("up,down", [(3, 2), (6, 5), (3, 5), (3, 10), (29, 24), (26, 43), (2, 3)])
def test_direct_polyphase_equals_repo_resampler(up, down):
    x = np.random.default_rng(up * 31 + down).standard_normal((613, 3))
    np.testing.assert_allclose(W.resample_poly_direct(x, up, down),
                               resample_poly_nd(x, up, down, axis=0), rtol=0, atol=1e-12)


def test_rational_ratio():
    assert W.rational_ratio(20.0, 180.0)[:2] == (3, 2)
    assert W.rational_ratio(25.0, 180.0)[:2] == (6, 5)
    assert W.rational_ratio(50.0, 180.0)[:2] == (3, 5)
    assert W.rational_ratio(100.0, 180.0)[:2] == (3, 10)
    for rate in (20.0153, 49.627, 24.8135, 100.31):
        up, down, eps = W.rational_ratio(rate, 180.0)
        assert abs(eps) * 180.0 <= W.MAX_RATE_DRIFT_S
        assert abs(up / down - 30.0 / rate) / (30.0 / rate) == pytest.approx(abs(eps), rel=1e-6)


def test_window_starts_match_serve_windowing():
    run = Run(start_ts=1000, samples=np.zeros((180 * 100, 6)), end_ts=1180)
    serve = [round((w.s - 1000) * 30) for w in windows_from_run(run, 1000, 1180)]
    assert W.window_starts(180 * 30) == serve
    assert len(serve) == 87 and serve[0] == 60


# ---------------------------------------------------------------------------
# Training path end to end (no torch)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def three_subjects(tmp_path_factory):
    root = str(tmp_path_factory.mktemp("wisdm3"))
    for i, s in enumerate((1600, 1601, 1602)):
        write_subject(root, s, scenario(base=i * 10_000_000_000))
    return root


def test_train_path_windows_have_real_gyro(three_subjects):
    rep = {}
    blocks = T.load_all_blocks(three_subjects, [1600, 1601, 1602], report=rep)
    x, y, subj, sess = T.windows_from_blocks(blocks, 120, 60)
    assert T.zero_gyro_fraction(x) == 0.0
    assert "E" not in set(y.tolist())
    assert len(x) == sum(len(W.window_starts(b.samples.shape[0])) for b in blocks)
    assert rep["excluded_no_gyro"] == ["1600-E-0", "1601-E-0", "1602-E-0"]
    assert rep["alignment"]["n_slips"] == 0


def test_split_universe_is_independent_of_surviving_blocks(three_subjects):
    blocks = T.load_all_blocks(three_subjects, [1600, 1601, 1602])
    full = T.split_blocks(blocks, 0.34, 0.34, 42, subjects=[1600, 1601, 1602])[3]
    fewer = T.split_blocks([b for b in blocks if b.subject != 1601], 0.34, 0.34, 42,
                           subjects=[1600, 1601, 1602])[3]
    for k in ("train_subjects", "val_subjects", "test_subjects"):
        assert full[k] == fewer[k]


def test_train_main_writes_report_and_enforces_split(three_subjects, tmp_path):
    out = str(tmp_path / "out")
    args = ["--wisdm", three_subjects, "--out", out, "--seed", "42",
            "--test-fraction", "0.34", "--val-fraction", "0.34"]
    assert T.main(args) == 0
    man = json.load(open(os.path.join(out, "manifest.json")))
    pre = man["data"]["preprocessing"]
    assert pre["loader"] == W.LOADER_VERSION
    assert pre["zero_gyro_window_fraction"] == {"train": 0.0, "val": 0.0, "test": 0.0}
    assert man["model_version"] == "hart-wisdm-v1"
    split_path = os.path.join(out, "split_manifest.json")
    assert T.main(args + ["--out", str(tmp_path / "again"), "--expect-split", split_path]) == 0
    bad = json.load(open(split_path))
    bad["test_subjects"] = [1600]
    bad_path = str(tmp_path / "bad_split.json")
    json.dump(bad, open(bad_path, "w"))
    with pytest.raises(SystemExit, match="split mismatch"):
        T.main(args + ["--out", str(tmp_path / "bad"), "--expect-split", bad_path])
