"""wav2sleep preprocessing parity against the pinned code's own resampling and normalization.

The oracle is the vendored, byte-identical pinned code (wav2sleep_vendored/data/*): the adapter's
numpy fast path must reproduce ``process_waveform_dataframe`` bit for bit at every supported
DECLARED native rate (25 Hz anchored v26, 24 Hz earlier convention), and its z-score must be the
pinned ``_zscore_normalize``. Fixtures are SYNTHETIC (tests/wav2sleep_fixtures.py).
"""

import numpy as np
import pandas as pd
import pytest
import torch

import wav2sleep_fixtures as F
from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C
from frwhoop_inference.frwhoop_sleep.wav2sleep import preprocessing as P
from frwhoop_inference.frwhoop_sleep.wav2sleep.contract import Run, parse_night
from frwhoop_inference.frwhoop_sleep.wav2sleep_vendored.data.preprocessing import \
    process_waveform_dataframe
from frwhoop_inference.frwhoop_sleep.wav2sleep_vendored.data.zscore import _zscore_normalize
from frwhoop_inference.frwhoop_sleep.wav2sleep_vendored.settings import (COLS_TO_SAMPLES_PER_EPOCH,
                                                                         INTEGER_LABEL_MAPS,
                                                                         TRAINING_LENGTH_HOURS)

RATES = C.SUPPORTED_NATIVE_RATES_HZ


def _run(start, seconds, rate, seed=11):
    samples = F.synthetic_ppg(seconds, rate=rate, seed=seed).astype(np.float64)
    return Run(index=0, run_id="r", config_identity="cfg", start=start, end=start + seconds,
               samples=samples, rate_hz=rate)


def _pinned(run, plan, hours=None):
    """The pinned path: a recording whose index is seconds since its first sample (j/rate)."""
    values = run.samples[plan.native_offset:]
    df = pd.DataFrame({"PPG": values}, index=pd.Index(P.native_times(values.size, run.rate_hz)))
    hours = plan.n_epochs * C.EPOCH_SECONDS / 3600 if hours is None else hours
    return process_waveform_dataframe(df, ["PPG"], max_length_hours=hours)["PPG"].dropna().values


def test_contract_constants_are_the_pinned_settings():
    assert COLS_TO_SAMPLES_PER_EPOCH["PPG"] == C.MODEL_SAMPLES_PER_EPOCH == 1024
    assert TRAINING_LENGTH_HOURS == C.TRAINING_LENGTH_HOURS == 10
    assert C.MAX_EPOCHS == 1200
    # 4-class map: W->0, N1->1, N2->1, N3->2, REM->3 => wake, light, deep, rem
    assert INTEGER_LABEL_MAPS[4] == {0: 0, 1: 1, 2: 1, 3: 2, 4: 3}
    assert C.CLASS_ORDER == ("wake", "light", "deep", "rem")
    assert abs(C.MODEL_RATE_HZ - 34.1333333) < 1e-6
    assert [C.native_samples_per_epoch(r) for r in RATES] == [720, 750]


def test_model_grid_is_the_pinned_target_index_exactly():
    for n in (1, 7, 960, 1200):
        hours = n * C.EPOCH_SECONDS / 3600
        pinned = np.arange(0, hours * 60 * 60 + 1e-9, 30 / 1024)[1:]
        mine = P.model_grid(n)
        assert mine.size == pinned.size == n * 1024
        assert np.array_equal(mine, pinned)
        assert mine[0] == 30 / 1024 and mine[-1] == 30.0 * n


def test_native_time_is_derived_from_the_declared_rate():
    assert np.array_equal(P.native_times(4, 25), np.array([0.0, 0.04, 0.08, 0.12]))
    assert P.native_times(25 * 30 + 1, 25)[-1] == 30.0
    assert P.native_times(24 * 30 + 1, 24)[-1] == 30.0
    with pytest.raises(ValueError, match="unsupported native rate"):
        P.native_times(10, 32)


@pytest.mark.parametrize("rate", RATES)
@pytest.mark.parametrize("start, seconds, t0, epochs", [
    (1_780_902_000, 30, 1_780_902_000, 0),          # the end sample of epoch 0 is not in the run
    (1_780_902_000, 31, 1_780_902_000, 1),
    (1_780_902_000, 8 * 3600 + 1, 1_780_902_000, 960),
    (1_780_902_000, 8 * 3600, 1_780_902_000, 959),  # the last epoch's end sample is the next run's
    (1_780_902_007, 3600, 1_780_902_030, 119),      # unaligned start: partial leading epoch unused
])
def test_epoch_plan_and_endpoint_ownership(rate, start, seconds, t0, epochs):
    run = _run(start, seconds, rate)
    plan = P.plan_run(run)
    assert (plan.t0, plan.n_epochs, plan.rate_hz) == (t0, epochs, rate)
    assert plan.native_offset == (t0 - start) * rate
    if epochs:
        per_epoch = C.native_samples_per_epoch(rate)
        last_native = plan.native_offset + per_epoch * epochs
        assert last_native < run.samples.size
        # native times are relative to the epoch origin t0 (sample native_offset is at 0.0 s)
        assert P.native_times(per_epoch * epochs + 1, rate)[-1] == 30.0 * epochs == P.model_grid(epochs)[-1]


@pytest.mark.parametrize("rate", RATES)
def test_numpy_fast_path_is_bitwise_the_pinned_pandas_resampler(rate):
    run = _run(1_780_902_007, 2 * 3600 + 45, rate)
    plan = P.plan_run(run)
    mine = P.resample_run(run, plan)
    pinned = _pinned(run, plan)
    assert mine.dtype == np.float32 and pinned.dtype == np.float32
    assert mine.size == plan.n_epochs * 1024
    assert np.array_equal(mine, pinned)


def test_the_same_waveform_at_24_and_25_hz_resamples_to_the_same_grid_shape():
    a, b = _run(1_780_902_000, 3601, 24), _run(1_780_902_000, 3601, 25)
    pa, pb = P.plan_run(a), P.plan_run(b)
    assert pa.n_epochs == pb.n_epochs == 120
    assert P.resample_run(a, pa).size == P.resample_run(b, pb).size == 120 * 1024


@pytest.mark.parametrize("rate", RATES)
def test_no_grid_point_is_ever_extrapolated(rate):
    run = _run(1_780_902_000, 3600, rate)
    plan = P.plan_run(run)
    plan.n_epochs += 1          # would need a sample the run does not have
    with pytest.raises(ValueError, match="beyond the last native sample"):
        P.resample_run(run, plan)


def test_zscore_is_the_pinned_normalization():
    run = _run(1_780_902_000, 2 * 3600 + 1, 25)
    signal = P.resample_run(run, P.plan_run(run))
    previous = torch.get_num_threads()
    torch.set_num_threads(1)
    try:
        mine = P.normalize(signal)
        pinned = _zscore_normalize({"PPG": torch.from_numpy(signal.copy())})["PPG"]
    finally:
        torch.set_num_threads(previous)
    assert torch.equal(mine, pinned)
    assert mine.dtype == torch.float32
    as64 = (signal.astype(np.float64) - signal.mean(dtype=np.float64)) / signal.std(ddof=1, dtype=np.float64)
    assert np.max(np.abs(mine.numpy() - as64)) < 1e-4       # float32 arithmetic


def test_polarity_is_kept_exactly_through_resampling_and_normalization():
    """No silent flip: a negated run produces the exactly negated model tensor."""
    run = _run(1_780_902_000, 2 * 3600 + 1, 25)
    neg = Run(index=0, run_id="r", config_identity="cfg", start=run.start, end=run.end,
              samples=-run.samples, rate_hz=25)
    plan = P.plan_run(run)
    pos_signal, neg_signal = P.resample_run(run, plan), P.resample_run(neg, P.plan_run(neg))
    assert np.array_equal(neg_signal, -pos_signal)
    assert torch.equal(P.normalize(neg_signal), -P.normalize(pos_signal))
    assert P.preprocessing_parameters()["polarity"] == C.POLARITY == "as_received"


def test_pinned_default_zero_padding_would_measure_the_padding_not_the_pulse():
    """Deviation D1: the pinned default pads to max_length_hours=10 with RAW zeros."""
    run = _run(1_780_902_000, 2 * 3600 + 1, 25)
    plan = P.plan_run(run)
    padded = _pinned(run, plan, hours=TRAINING_LENGTH_HOURS)
    assert padded.size == 1200 * 1024
    last_native_time = P.native_times(run.samples.size - plan.native_offset, 25)[-1]
    beyond = P.model_grid(1200) > last_native_time
    assert beyond.sum() > 0.79 * padded.size
    assert np.all(padded[beyond] == 0.0), "the pinned default zero-fills beyond the recording"
    z_padded = _zscore_normalize({"PPG": torch.from_numpy(padded)})["PPG"].numpy()
    z_adapter = P.normalize(P.resample_run(run, plan)).numpy()
    head = z_padded[:plan.n_epochs * 1024]
    # the measured night collapses to a near-constant ~+2 sigma plateau; the pulse all but vanishes
    assert np.std(z_adapter) == pytest.approx(1.0, abs=1e-3)
    assert np.std(head) < 0.05 * np.std(z_adapter)
    assert np.mean(head) > 1.5


def test_runs_are_never_bridged_across_a_gap():
    """Deviation D2: the pinned resampler interpolates across a gap after dropna(); the adapter
    hands it one run at a time, so no model sample is ever placed inside a gap."""
    fixture = F.night([(0, 4 * 3600), (4 * 3600 + 1200, 4 * 3600)])
    night = parse_night(F.payload(fixture), F.context(fixture))
    assert len(night.runs) == 2
    gap_lo, gap_hi = night.runs[0].end, night.runs[1].start
    for run in night.runs:
        plan = P.plan_run(run)
        lo = plan.t0 + 30 / 1024
        hi = plan.t0 + 30.0 * plan.n_epochs
        assert hi <= gap_lo or lo >= gap_hi           # the run's grid never touches the gap
    # what the pinned code would do to the concatenated night: a straight line through the gap
    a, b = night.runs
    times = np.concatenate([P.native_times(a.samples.size, 25),
                            (b.start - a.start) + P.native_times(b.samples.size, 25)])
    df = pd.DataFrame({"PPG": np.concatenate([a.samples, b.samples])}, index=pd.Index(times))
    bridged = process_waveform_dataframe(df, ["PPG"], max_length_hours=8.3)["PPG"].values
    grid = P.model_grid(int(8.3 * 120))
    inside = (grid > (gap_lo - a.start)) & (grid < (gap_hi - a.start))
    assert inside.sum() > 30_000 and np.all(np.isfinite(bridged[inside]))


def test_run_assembly_joins_pieces_of_one_run_id_only():
    fixture = F.night([(0, 3 * 3600), (3 * 3600, 3 * 3600)], run_ids=["a", "b"])
    night = parse_night(F.payload(fixture), F.context(fixture))
    assert [(r.run_id, r.seconds) for r in night.runs] == [("a", 10800), ("b", 10800)]
    assert night.runs[0].end == night.runs[1].start          # touching, still two runs
    joined = F.night([(0, 6 * 3600)], run_ids=["a"])
    one = parse_night(F.payload(joined), F.context(joined))
    assert [(r.run_id, r.seconds) for r in one.runs] == [("a", 21600)]
    assert np.array_equal(one.runs[0].samples,
                          np.concatenate([night.runs[0].samples, night.runs[1].samples]))


def test_runs_are_clipped_to_the_window_and_samples_are_never_modified():
    fixture = F.night([(0, 5 * 3600)])
    payload = F.payload(fixture)
    payload["window"] = {"start_utc": F.DEFAULT_START + 600, "end_utc": F.DEFAULT_START + 4 * 3600}
    before = [list(s["samples"]) for s in payload["ppg"]["segments"]]
    night = parse_night(payload, F.context(fixture))
    assert night.runs[0].start == F.DEFAULT_START + 600
    assert night.runs[0].end == F.DEFAULT_START + 4 * 3600
    assert night.runs[0].samples.size == (4 * 3600 - 600) * 25
    assert [list(s["samples"]) for s in payload["ppg"]["segments"]] == before
