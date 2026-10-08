"""Secondary nonlinear PRV statistics (spec-02 §1, CONTRACT §5.3; owner: cardiac).

Validates ``features/prv_nonlinear.py``:

* the per-segment NeuroKit2 0.2.13 values equal independent textbook implementations
  (Richman & Moorman 2000 SampEn, Peng et al. 1995 non-overlapping DFA-1) to machine precision;
* known synthetic behaviour: white noise alpha-1 ~ 0.5 (DFA-1's known small-box upward bias puts the
  median near 0.57 at 4-16 beats), 1/f noise ~ 1.0, Brownian ~ 1.5; a periodic series has low SampEn;
* segmentation keeps original adjacency: gaps, removed beats and channel changes split stretches,
  only exactly-``segment_beats`` segments exist, nothing is concatenated;
* withheld / not-applicable reasons, config/version provenance, the latency cap, and the block's
  presence in the assembled document.
"""

from __future__ import annotations

import json
import math
import os
import time

import numpy as np
import pytest

from frwhoop_inference.features import prv_nonlinear as pn
from frwhoop_inference.features.compute import compute
from frwhoop_inference.features.config import CONFIG
from frwhoop_inference.features.contract import BeatIn, NightIn, StageSegmentIn, parse_request
from frwhoop_inference.features.timeline import build_timeline


# ---------------------------------------------------------------------------
# Independent textbook references
# ---------------------------------------------------------------------------


def sampen_textbook(x, m: int, r: float) -> float:
    """Richman & Moorman (2000): B = template pairs (i<j) of length m within r (Chebyshev, <=),
    A = the same for length m+1, both over the first N-m templates; SampEn = -ln(A/B)."""
    x = np.asarray(x, dtype=float)
    n_t = len(x) - m

    def pairs(length: int) -> int:
        dist = np.zeros((n_t, n_t))
        for k in range(length):
            col = x[k:k + n_t]
            dist = np.maximum(dist, np.abs(col[:, None] - col[None, :]))
        iu = np.triu_indices(n_t, k=1)
        return int(np.sum(dist[iu] <= r))

    return -math.log(pairs(m + 1) / pairs(m))


def dfa_textbook(x, scales) -> float:
    """Peng et al. (1995) DFA-1: integrate the mean-removed series, split into non-overlapping boxes
    of size n from the start, remove each box's least-squares line, F(n) = RMS residual, alpha = the
    log-log slope."""
    x = np.asarray(x, dtype=float)
    y = np.cumsum(x - x.mean())
    fluct = []
    for n in scales:
        nb = len(y) // n
        boxes = y[:nb * n].reshape(nb, n)
        t = np.arange(n, dtype=float)
        resid = []
        for box in boxes:
            slope, intercept = np.polyfit(t, box, 1)
            resid.append(box - (slope * t + intercept))
        fluct.append(math.sqrt(float(np.mean(np.concatenate(resid) ** 2))))
    return float(np.polyfit(np.log(scales), np.log(fluct), 1)[0])


def _pink(n: int, rng) -> np.ndarray:
    f = np.fft.rfftfreq(n)
    amp = np.zeros_like(f)
    amp[1:] = f[1:] ** -0.5
    return np.fft.irfft(amp * np.exp(1j * rng.uniform(0, 2 * np.pi, len(f))), n)


# ---------------------------------------------------------------------------
# Reference agreement
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_neurokit_matches_textbook_implementations(seed):
    rng = np.random.default_rng(seed)
    x = 900 + 40 * rng.normal(size=300) + 25 * np.sin(np.arange(300) / 4)
    cfg = pn.PRV_NONLINEAR_CONFIG
    sampen, alpha = pn.segment_statistics(x, cfg)
    r = cfg.sampen_tolerance_sd * float(np.std(x, ddof=1))
    assert sampen == pytest.approx(sampen_textbook(x, cfg.sampen_dimension, r), rel=1e-12, abs=1e-12)
    lo, hi = cfg.dfa_scales
    assert alpha == pytest.approx(dfa_textbook(x, list(range(lo, hi + 1))), rel=1e-10, abs=1e-12)


def test_known_synthetic_behaviour():
    rng = np.random.default_rng(7)

    def median_stats(gen, n=20):
        vals = [pn.segment_statistics(900 + 30 * gen()) for _ in range(n)]
        return (float(np.median([v[0] for v in vals if v[0] is not None])),
                float(np.median([v[1] for v in vals if v[1] is not None])))

    white_s, white_a = median_stats(lambda: rng.normal(size=300))
    pink_s, pink_a = median_stats(lambda: _pink(4096, rng)[:300])
    brown_s, brown_a = median_stats(lambda: np.cumsum(rng.normal(size=300)))
    periodic_s, _ = median_stats(lambda: np.sin(2 * np.pi * np.arange(300) / 12) + rng.normal(0, 0.01, 300))
    assert 0.45 <= white_a <= 0.65          # ~0.5 (+ DFA-1 small-box bias)
    assert 0.85 <= pink_a <= 1.15           # ~1.0
    assert 1.35 <= brown_a <= 1.65          # ~1.5
    assert white_s > 1.9                    # irregular
    assert periodic_s < 0.3                 # regular -> low SampEn
    assert periodic_s < pink_s < white_s


def test_undefined_statistics_are_none():
    flat = [900.0] * 300
    assert pn.segment_statistics(flat) == (None, None)


# ---------------------------------------------------------------------------
# Segmentation on original adjacency
# ---------------------------------------------------------------------------


T0 = 1_791_000_000
#: the default config with the wall-clock guard relaxed, so a loaded test host cannot flip a result
RELAXED = pn.PrvNonlinearConfig(time_budget_s=60.0)


def _beats(values, start=T0, channel=1, hole_after=None, hole_s=0):
    """Beats stamped with the whole second their interval ends (cumulative), optional wall-clock hole."""
    out, t = [], float(start)
    for k, v in enumerate(values):
        if hole_after is not None and k == hole_after + 1:
            t += hole_s           # interval k is the first one after the hole
        t += v / 1000.0
        out.append(BeatIn(ts=int(t), rr_ms=float(v), seq=k, ordn=k, src_channel=channel))
    return out


def _series(n, seed=0):
    rng = np.random.default_rng(seed)
    return list(np.round(950 + 30 * rng.normal(size=n)))


def test_segments_are_exactly_segment_beats_and_never_span_a_gap():
    vals = _series(700)
    # gapless: 700 adjacent intervals -> 2 segments of 300 (remainder 100 discarded)
    stretches = pn.adjacency_stretches(_beats(vals))
    assert [len(s) for s in stretches] == [700]
    segs = pn.equal_length_segments(stretches, 300)
    assert [len(s) for s in segs] == [300, 300]
    assert segs[0] == vals[:300] and segs[1] == vals[300:600]
    # a 20 s wall-clock hole after interval 349: two stretches (350, 350) -> one segment each
    gapped = pn.adjacency_stretches(_beats(vals, hole_after=349, hole_s=20))
    assert [len(s) for s in gapped] == [350, 350]
    segs = pn.equal_length_segments(gapped, 300)
    assert segs == [vals[:300], vals[350:650]]


def test_removed_beat_and_channel_change_split_stretches():
    vals = _series(700)
    ectopic = list(vals)
    ectopic[400] = 450.0          # Malik-rejected: the intervals either side are not adjacent
    stretches = pn.adjacency_stretches(_beats(ectopic))
    assert [len(s) for s in stretches] == [400, 299]
    assert 450.0 not in stretches[0] + stretches[1]

    a = _beats(vals[:350], channel=5)
    b = _beats(vals[350:], start=a[-1].ts, channel=7)
    assert [len(s) for s in pn.adjacency_stretches(a + b)] == [350, 350]


def test_latency_cap_spreads_evenly():
    assert pn.evenly_spaced(10, 24) == list(range(10))
    picks = pn.evenly_spaced(88, 24)
    assert len(picks) == 24 and picks[0] == 0 and picks[-1] == 87
    assert picks == sorted(picks)


# ---------------------------------------------------------------------------
# Block: statuses, reasons, provenance
# ---------------------------------------------------------------------------


def _request_with(beats, *, is_nap=False, start=T0, end=None):
    end = end or (beats[-1].ts + 1 if beats else start + 3600)
    night = NightIn(night_id="n1", start=start, end=end, is_nap=is_nap, user_edited=False,
                    stages=(StageSegmentIn(start=start, end=end, stage="light"),))

    class Req:  # the module reads only .beats; the timeline is built from the night
        pass

    req = Req()
    req.beats = tuple(beats)
    return req, build_timeline(night)


def test_available_block_shape_and_provenance():
    beats = _beats(_series(300 * 4 + 10, seed=3))
    req, tl = _request_with(beats)
    assert pn.PRV_NONLINEAR_CONFIG.to_wire()["time_budget_s"] == 0.4
    blk = pn.compute_night(req, tl, CONFIG, RELAXED)
    assert blk["status"] == "available" and blk["reasons"] == []
    assert blk["method_version"] == "prv-nonlinear-1"
    assert blk["neurokit2"] == "0.2.13"
    assert blk["source"] == "prv_optical" and blk["secondary"] is True
    assert blk["config"] == {"segment_beats": 300, "sampen_dimension": 2, "sampen_delay": 1,
                             "sampen_tolerance_sd": 0.2, "dfa_scales": [4, 16], "dfa_overlap": False,
                             "dfa_order": 1, "min_segments": 3, "max_segments": 24,
                             "time_budget_s": 60.0, "splice_tolerance_s": 3.0}
    assert blk["segments_available"] == 4 and blk["segments_used"] == 4 and blk["segments_rejected"] == 0
    segs = pn.equal_length_segments(pn.adjacency_stretches(beats), 300)
    expected = [pn.segment_statistics(s) for s in segs]
    assert blk["sample_entropy"]["median"] == pytest.approx(float(np.median([e[0] for e in expected])))
    assert blk["dfa_alpha1"]["median"] == pytest.approx(float(np.median([e[1] for e in expected])))
    assert blk["sample_entropy"]["iqr"] == pytest.approx(
        float(np.percentile([e[0] for e in expected], 75) - np.percentile([e[0] for e in expected], 25)))
    assert blk["sample_entropy"]["segments"] == 4 and blk["dfa_alpha1"]["segments"] == 4
    json.dumps(blk, allow_nan=False)


def test_insufficient_segments_is_withheld_with_null_values():
    beats = _beats(_series(300 * 2 + 50))
    req, tl = _request_with(beats)
    blk = pn.compute_night(req, tl, CONFIG, RELAXED)
    assert blk["status"] == "withheld"
    assert blk["reasons"] == ["insufficient_segments"]
    assert blk["segments_used"] == 2
    assert blk["sample_entropy"]["median"] is None and blk["dfa_alpha1"]["median"] is None


def test_no_beats_and_naps():
    req, tl = _request_with([], end=T0 + 3600)
    blk = pn.compute_night(req, tl, CONFIG)
    assert blk["status"] == "withheld" and blk["reasons"] == ["no_rr_beats"]
    beats = _beats(_series(1300))
    req, tl = _request_with(beats, is_nap=True)
    nap = pn.compute_night(req, tl, CONFIG)
    assert nap["status"] == "not_applicable" and nap["reasons"] == ["not_main_night"]
    assert nap["sample_entropy"]["median"] is None


def test_time_guard_withholds_instead_of_publishing_partial_work():
    beats = _beats(_series(300 * 4 + 10, seed=3))
    req, tl = _request_with(beats)
    blk = pn.compute_night(req, tl, CONFIG, pn.PrvNonlinearConfig(time_budget_s=0.0))
    assert blk["status"] == "withheld" and blk["reasons"] == ["compute_budget_exceeded"]
    assert blk["sample_entropy"]["median"] is None


def test_gap_concatenation_would_change_the_answer_but_does_not_happen():
    # Two stretches of 299 intervals at different levels: concatenating would make segments; the
    # producer must find none (withheld), never pool across the hole.
    vals = _series(299, seed=1) + [v + 200 for v in _series(299, seed=2)]
    beats = _beats(vals, hole_after=298, hole_s=60)
    req, tl = _request_with(beats)
    blk = pn.compute_night(req, tl, CONFIG)
    assert blk["segments_available"] == 0
    assert blk["status"] == "withheld"


def test_block_is_assembled_per_night_within_latency_budget():
    base = os.path.join(os.path.dirname(__file__), "..", "..", "CloudWorker", "Tests",
                        "frwhoop-workerTests", "SleepFeatureWireFixtures")
    req = parse_request(json.load(open(os.path.join(base, "sleep_features_request.json"))))
    doc = compute(req, budget_ms=60000)
    blk = doc["nights"][0]["prv_nonlinear"]
    assert blk["method_version"] == "prv-nonlinear-1"
    assert "prv_nonlinear" not in doc["nights"][0]["metric_status"]["module_errors"]
    assert blk["segments_evaluated"] <= pn.PRV_NONLINEAR_CONFIG.max_segments
    # Added cost on the committed full-night fixture (26 400 beats): generous bound for a loaded host.
    tl = build_timeline(req.nights[0])
    started = time.perf_counter()
    pn.compute_night(req, tl, CONFIG)
    assert time.perf_counter() - started < 1.5
