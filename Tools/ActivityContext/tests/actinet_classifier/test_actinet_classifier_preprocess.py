"""``actinet-prep-1``: gaps preserved, no cross-gap epochs, upstream resize parity, grid alignment, invalid epochs."""

import numpy as np
import pytest

from activity_context.actinet_classifier import EPOCH_S, MODEL_SAMPLES, REASON_NO_DATA, REASON_PARTIAL
from activity_context.actinet_classifier import preprocess as P
from activity_context.preprocess import PreprocessError

from . import synth
from ._helpers import fixture, load_json


def _seconds(spec):
    out = []
    for r in synth.spec_runs(spec):
        out += [(r["start_ts"] + i, c) for i, c in enumerate(synth.columns(r["counts"]))]
    return out


def test_runs_follow_the_shared_decoder_and_keep_samples_exact():
    spec = ((0, 61, "walk", 1), (63, 40, "desk", 2))          # seconds 61, 62 missing -> two runs
    runs = P.runs_from_seconds(_seconds(spec))
    assert [(r.t0 - synth.T0, r.n, r.fs) for r in runs] == [(0.0, 6100, 100.0), (63.0, 4000, 100.0)]
    for r, (_, dur, kind, seed) in zip(runs, spec):
        assert r.x.dtype == np.float32
        np.testing.assert_array_equal(r.x, synth.counts(dur, kind, seed) / 4096.0)   # i16 / 4096 exact, no fill


def test_accel_only_decode_equals_the_shared_decoder():
    from activity_context.preprocess import decode_seconds
    sec = _seconds(((0, 7, "run", 3), (9, 4, "sleep", 4)))
    shared = decode_seconds(sec)
    mine = P.runs_from_seconds(sec)
    assert [r.start_ts for r in shared] == [int(r.t0) for r in mine]
    for a, b in zip(shared, mine):
        np.testing.assert_array_equal(b.x, a.samples[:, 0:3].astype(np.float32))
        assert np.array_equal(b.x.astype(np.float64), a.samples[:, 0:3])           # exact, not just close


def test_duplicate_and_clock_reset_are_refused():
    sec = _seconds(((0, 5, "still", 1),))
    with pytest.raises(PreprocessError):
        P.runs_from_seconds(sec + [sec[-1]])
    with pytest.raises(PreprocessError):
        P.runs_from_seconds(sec + [(sec[0][0], sec[0][1])])


def test_no_epoch_crosses_a_gap():
    spec = ((0, 50, "walk", 1), (52, 70, "walk", 2), (130, 30, "run", 3))
    runs = P.runs_from_seconds(_seconds(spec))
    for grid in ("run", "request"):
        for ep in P.epochs(runs, float(synth.T0), float(synth.T0 + 160), grid):
            if ep.valid:
                r = runs[ep.run]
                assert r.t0 <= ep.s and ep.e <= r.end
                assert ep.i0 == int(round((ep.s - r.t0) * 100))
    run_grid = P.epochs(runs, float(synth.T0), float(synth.T0 + 160), "run")
    assert [(ep.s - synth.T0, ep.valid) for ep in run_grid] == [
        (0.0, True), (30.0, False), (52.0, True), (82.0, True), (112.0, False), (130.0, True)]


def test_window_alignment_of_the_two_grids():
    spec = ((15, 75, "desk", 1),)                               # starts 15 s off the request grid
    runs = P.runs_from_seconds(_seconds(spec))
    start, end = float(synth.T0), float(synth.T0 + 120)
    run_grid = [(ep.s - synth.T0, ep.valid, ep.reason) for ep in P.epochs(runs, start, end, "run")]
    assert run_grid == [(15.0, True, None), (45.0, True, None), (75.0, False, REASON_PARTIAL)]
    req_grid = [(ep.s - synth.T0, ep.valid, ep.reason) for ep in P.epochs(runs, start, end, "request")]
    assert req_grid == [(0.0, False, REASON_PARTIAL), (30.0, True, None), (60.0, True, None),
                        (90.0, False, REASON_NO_DATA)]


def test_epochs_stay_inside_the_request():
    runs = P.runs_from_seconds(_seconds(((0, 100, "walk", 1),)))
    eps = P.epochs(runs, float(synth.T0 + 10), float(synth.T0 + 75), "run")
    # the run's own grid is kept (0, 30, 60, 90); epochs before the request start are not listed
    assert [(ep.s - synth.T0, ep.valid) for ep in eps] == [(30.0, True), (60.0, False)]
    with pytest.raises(PreprocessError):
        P.epochs(runs, 5.0, 5.0, "run")
    with pytest.raises(PreprocessError):
        P.epochs(runs, 0.0, 10.0, "hourly")


def test_resize_is_bit_identical_to_upstream_golden():
    """Upstream actipy.process(uniform) + make_windows + resize (actinet 0.7.2, actipy 3.8.0, numpy 1.24) on an
    exactly uniform 100 Hz segment: the sample values pass unchanged and the model input matches bit for bit."""
    meta = load_json("golden_resize.json")
    assert meta["resample_skipped"] and meta["actipy_values_unchanged"] and meta["actipy_index_unchanged"]
    assert meta["actipy_info"]["CalibOK"] == 0 and meta["actipy_info"]["NumNonwearEpisodes"] == 0
    golden = np.load(fixture("golden_resize.npz"))["resized"]
    g = synth.contiguous_float32(meta["n_seconds"], seed=meta["seed"])
    runs = P.runs_from_array(synth.T0 + np.arange(g.shape[0]) / 100.0, g, 100.0)
    eps = P.epochs(runs, float(synth.T0), float(synth.T0 + meta["n_seconds"]), "request")
    valid = [ep for ep in eps if ep.valid]
    assert [ep.s - synth.T0 for ep in valid] == meta["bin_starts_s"][:3]
    resized = P.resize(P.epoch_samples(runs, valid))
    assert resized.dtype == np.float64 and np.array_equal(resized, golden)
    x = P.model_batch(runs, valid)
    assert x.dtype == np.float32 and x.shape == (3, 3, MODEL_SAMPLES)
    np.testing.assert_array_equal(x, np.transpose(golden.astype(np.float32), (0, 2, 1)))


def test_partial_tail_is_invalid_where_upstream_wrap_pads_it():
    """Deviation D3: upstream keeps a last bin of 1500-3000 samples by wrap-padding it; Nara marks it invalid."""
    meta = load_json("golden_resize.json")
    assert meta["tail_bin_valid_in_upstream"] is True and meta["bin_starts_s"][3] == 90.0
    g = synth.contiguous_float32(meta["n_seconds"], seed=meta["seed"])
    runs = P.runs_from_array(synth.T0 + np.arange(g.shape[0]) / 100.0, g, 100.0)
    tail = P.epochs(runs, float(synth.T0), float(synth.T0 + 120), "request")[3]
    assert (tail.s - synth.T0, tail.valid, tail.reason, tail.covered_s) == (90.0, False, REASON_PARTIAL, 20.0)


def test_resize_matches_scipy_interp1d():
    interpolate = pytest.importorskip("scipy.interpolate")

    def ref(x):
        n = x.shape[1]
        return interpolate.interp1d(np.linspace(0, 1, n), x, kind="linear", axis=1, assume_sorted=True)(
            np.linspace(0, 1, 900))
    whoop = (synth.counts(90, "run", 4).astype(np.float64) / 4096.0).astype(np.float32).reshape(3, 3000, 3)
    # WHOOP values (i16 / 4096) subtract exactly in float32, so both of upstream's precisions agree with Nara
    assert np.array_equal(P.resize(whoop), ref(whoop)) and np.array_equal(P.resize(whoop), ref(whoop.astype(np.float64)))
    # arbitrary float32 (a dataset in m/s^2 / 9.80665): Nara is upstream's float64 stack (any invalid bin in a file)
    other = (synth.counts(90, "run", 4).astype(np.float64) / 4096.0 * 9.80665 / 9.81).astype(np.float32)
    other = other.reshape(3, 3000, 3)
    assert np.array_equal(P.resize(other), ref(other.astype(np.float64)))
    assert np.abs(P.resize(other) - ref(other)).max() < 1e-7                # the float32 stack: within an ulp
    odd = other[:, :2571]                                                   # GOTOV-like 600/7 Hz epochs
    assert np.array_equal(P.resize(odd), ref(odd.astype(np.float64)))
    with pytest.raises(PreprocessError):
        P.resize(np.full((1, 3000, 3), np.nan, np.float32))


def test_dataset_runs_split_and_are_never_regridded():
    fs = 100.0
    t = synth.T0 + np.arange(9000) / fs
    t[4500:] += 0.004                                            # a 14 ms step: off the grid -> split
    x = (synth.counts(90, "walk", 1) / 4096.0).astype(np.float32)
    x[7000] = np.nan                                             # a dropout -> dropped, split
    jitter = t.copy()
    jitter[1:4500] += 1e-6                                       # < 0.1 % of the period: not a split
    runs = P.runs_from_array(jitter, x, fs)
    assert [(round(r.t0 - synth.T0, 3), r.n) for r in runs] == [(0.0, 4500), (45.004, 2500), (70.014, 1999)]
    np.testing.assert_array_equal(runs[1].x, x[4500:7000])      # samples untouched
    with pytest.raises(PreprocessError):
        P.runs_from_array(t[:10], x[:9], fs)


def test_non_integer_rate_truncates_like_upstream():
    fs = 600.0 / 7.0
    assert P.window_len(fs) == 2571 and P.window_len(100.0) == 3000
    n = int(95 * fs)
    x = (synth.counts(96, "desk", 2)[:n] / 4096.0).astype(np.float32)
    runs = P.runs_from_array(synth.T0 + np.arange(n) / fs, x, fs)
    eps = [ep for ep in P.epochs(runs, float(synth.T0), float(synth.T0 + 95), "run") if ep.valid]
    assert [ep.i0 for ep in eps] == [0, 2572, 5143]           # bins hold 2571 or 2572 samples; first 2571 used
    assert P.model_batch(runs, eps).shape == (3, 3, MODEL_SAMPLES)


def test_empty_and_30hz_inputs():
    assert P.model_batch([], []).shape == (0, 3, MODEL_SAMPLES)
    x = (synth.counts(10, "walk", 1)[:900] / 4096.0).astype(np.float32)
    runs = P.runs_from_array(synth.T0 + np.arange(900) / 30.0, x, 30.0)
    eps = [ep for ep in P.epochs(runs, float(synth.T0), float(synth.T0 + EPOCH_S), "run") if ep.valid]
    np.testing.assert_array_equal(P.model_batch(runs, eps)[0], x.T)   # a 30 Hz epoch is not resized (upstream)


def test_model_inputs_do_not_depend_on_chunking():
    spec = ((0, 180, "walk", 3),)
    runs = P.runs_from_seconds(_seconds(spec))
    whole = P.epochs(runs, float(synth.T0), float(synth.T0 + 180), "run")
    xa = P.model_batch(runs, whole)
    part = P.epochs(runs, float(synth.T0 + 60), float(synth.T0 + 180), "run")
    xb = P.model_batch(runs, part)
    np.testing.assert_array_equal(xa[2:], xb)
