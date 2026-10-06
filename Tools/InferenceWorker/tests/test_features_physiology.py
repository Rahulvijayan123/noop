"""Tests for worker-physiology: stage-conditioned physiology (A4) and
RSA-derived respiratory variability (A7) blocks.

Covers every check named for the worker in spec sections A4/A7 plus the shared
wire rules (finite leaves, status vocabulary, not_applicable honesty entries,
no clinical claims).
"""

from __future__ import annotations

import math
import statistics

import pytest

from frwhoop_inference.features import physiology, respiration
from frwhoop_inference.features.config import CONFIG
from frwhoop_inference.features.contract import (
    BeatIn,
    BreathIn,
    BreathRunIn,
    HrSampleIn,
    NightIn,
    SleepFeaturesContext,
    SleepFeaturesRequest,
    StageSegmentIn,
    TempSampleIn,
)
from frwhoop_inference.features.timeline import build_timeline
from frwhoop_inference.providers.hrv import HrvTuning, continuous_runs
from frwhoop_inference.features.physiology import _analyze_window

# A minute- and window-aligned anchor so minutes/windows line up with the night.
T0 = 1_800_000_000
CFG = CONFIG


def _ctx(start: int, end: int) -> SleepFeaturesContext:
    return SleepFeaturesContext(
        user_id="physiology-test", device_id="whoop5-test",
        day="2026-10-19", iana_timezone="America/New_York",
        input_revision=1, interval_start=start, interval_end=end,
        history_revision_digest=None,
    )


def _night(stages, end: int | None = None, night_id: str = "n1") -> NightIn:
    start = min(s.start for s in stages)
    if end is None:
        end = max(s.end for s in stages)
    return NightIn(night_id=night_id, start=start, end=end, is_nap=False,
                   user_edited=False, stages=tuple(stages))


def _req(night, hr=(), temp=(), beats=(), breaths=(), runs=()):
    return SleepFeaturesRequest(
        context=_ctx(night.start, night.end), nights=(night,),
        hr=tuple(hr), temp=tuple(temp), beats=tuple(beats),
        breaths=tuple(breaths), breath_runs=tuple(runs),
        history_days=(), capabilities={},
    )


def _beats(n: int, start: int = T0, rr_ms: float = 1000.0) -> list[BeatIn]:
    return [BeatIn(ts=start + i, rr_ms=rr_ms, seq=i, ordn=0, src_channel=1)
            for i in range(n)]


def _breaths(start: int, end: int, cadence_s: float, seconds: float,
             phase: int = 5) -> list[BreathIn]:
    out = []
    ts = start + phase
    while ts < end:
        out.append(BreathIn(ts=ts, seconds=seconds))
        ts += int(round(cadence_s))
    return out


def _walk(obj, fn):
    """Recursively visit every value in a JSON-like structure."""
    if isinstance(obj, dict):
        for v in obj.values():
            _walk(v, fn)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            _walk(v, fn)
    else:
        fn(obj)


def _assert_finite_or_none(block: dict) -> None:
    bad = []

    def check(v):
        if isinstance(v, float) and not math.isfinite(v):
            bad.append(v)

    _walk(block, check)
    assert bad == [], f"non-finite leaves: {bad}"


# ---------------------------------------------------------------------------
# A4: stage-conditioned physiology
# ---------------------------------------------------------------------------


def test_a4_stage_boundary_crossing_window_is_excluded():
    """A 5-min window spanning wake->light has no majority reaching the purity
    gate and is excluded; its duration counts as excluded mixed-stage."""
    night = _night([
        StageSegmentIn(start=T0, end=T0 + 240, stage="wake"),
        StageSegmentIn(start=T0 + 240, end=T0 + 900, stage="light"),
    ])
    req = _req(night, beats=_beats(900))
    tl = build_timeline(night)
    block = physiology.compute_night(req, tl, CFG)

    light = block["stages"]["light"]
    wake = block["stages"]["wake"]
    # windows fully inside light are usable
    assert light["windows"] == 2
    assert light["rmssd_ms"]["windows"] == 2
    assert light["rmssd_ms"]["median"] is not None
    # the mixed window (majority wake, purity 240/300 = 0.80) is excluded
    assert wake["windows"] == 0
    assert wake["excluded_mixed_stage_min"] == 5.0
    assert wake["status"] == "withheld"
    assert "no_windows" in wake["reasons"]
    _assert_finite_or_none(block)


def test_a4_equal_rr_distinct_identities_survive():
    """Two beats with equal R-R values but distinct identities are both kept."""
    beats = _beats(600)
    # a second genuine beat in the same second, same value, distinct identity
    beats.append(BeatIn(ts=T0 + 300, rr_ms=1000.0, seq=301, ordn=1, src_channel=1))
    beats.sort(key=lambda b: (b.ts, b.seq, b.ordn))
    values = [b.rr_ms for b in beats]
    outcome = _analyze_window([values], 300, HrvTuning())
    assert outcome["n_input"] == 601
    assert outcome["n_clean"] == 601          # equal-value beats survived
    assert outcome["n_ectopic_rejected"] == 0
    assert outcome["valid_pairs"] == 600      # both are adjacent in the run

    # and the block accepts the window (no dedup by value anywhere)
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    req = _req(night, beats=beats)
    block = physiology.compute_night(req, build_timeline(night), CFG)
    assert block["stages"]["light"]["windows"] == 2


def test_a4_ectopic_rejection_breaks_adjacency():
    """A Malik-rejected ectopic is removed and the pair crossing it is not
    counted (production adjacency semantics)."""
    beats = _beats(300)
    beats = [b for b in beats if b.seq != 150]
    beats.append(BeatIn(ts=T0 + 150, rr_ms=1000.0, seq=301, ordn=0, src_channel=1))
    beats.append(BeatIn(ts=T0 + 150, rr_ms=380.0, seq=302, ordn=1, src_channel=1))
    beats.sort(key=lambda b: (b.ts, b.seq, b.ordn))
    values = [b.rr_ms for b in beats]
    outcome = _analyze_window([values], 300, HrvTuning())
    assert outcome["n_input"] == 301
    assert outcome["n_ectopic_rejected"] == 1
    assert outcome["n_clean"] == 300
    # 300 kept beats would give 299 contiguous pairs; the pair spanning the
    # ectopic (kept_orig 150 -> 152) is not adjacent, so one pair is lost
    assert outcome["valid_pairs"] == 298


def test_a4_missing_beat_breaks_adjacency():
    """A wall-clock hole (dropped beats) splits the contiguous run exactly like
    the production provider; the pair across the hole is not counted."""
    beats = _beats(300)
    dropped = [b for b in beats if not (150 <= b.seq <= 153)]  # 4 beats dropped
    tuning = HrvTuning()
    runs = continuous_runs(dropped, tuning.splice_tolerance_s)
    assert len(runs) == 2  # the 5 s hole exceeds the splice tolerance
    segments = [[b.rr_ms for b in run] for run in runs]
    outcome = _analyze_window(segments, 300, tuning)
    assert outcome["n_clean"] == 296
    # 296 contiguous beats would give 295 pairs; the boundary pair is lost
    assert outcome["valid_pairs"] == 294


def test_a4_absent_deep_sleep_stage_withheld():
    """A night with no deep stage publishes a withheld deep entry."""
    night = _night([
        StageSegmentIn(start=T0, end=T0 + 300, stage="wake"),
        StageSegmentIn(start=T0 + 300, end=T0 + 1500, stage="light"),
        StageSegmentIn(start=T0 + 1500, end=T0 + 1800, stage="rem"),
    ])
    req = _req(night, beats=_beats(1800))
    block = physiology.compute_night(req, build_timeline(night), CFG)
    deep = block["stages"]["deep"]
    assert deep["status"] == "withheld"
    assert "no_windows" in deep["reasons"]
    assert deep["windows"] == 0
    assert deep["rmssd_ms"]["median"] is None
    assert deep["rmssd_ms"]["iqr"] is None
    # a stage with a single usable window is thin-data, not withheld
    assert block["stages"]["wake"]["thin_data"] is True
    assert "thin_data" in block["stages"]["wake"]["reasons"]
    assert block["stages"]["light"]["windows"] == 4


def test_a4_off_wrist_minutes_excluded():
    """Minutes without enough observed HR seconds are invalid and excluded from
    stage HR stats (time support, not rows)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 1200, stage="light")])
    hr: list[HrSampleIn] = []
    for m in range(20):
        if m == 5:            # fully off-wrist minute: no HR at all
            continue
        if m == 8:            # sparse minute: only 30 observed seconds < 45
            for s in range(30):
                hr.append(HrSampleIn(ts=T0 + m * 60 + s, bpm=60.0 + m))
            continue
        for s in range(60):   # full minute at ~1 Hz
            hr.append(HrSampleIn(ts=T0 + m * 60 + s, bpm=60.0 + m))
    req = _req(night, hr=hr, beats=_beats(1200))
    block = physiology.compute_night(req, build_timeline(night), CFG)
    light = block["stages"]["light"]
    assert light["valid_min"] == 18
    expected = [60.0 + m for m in range(20) if m not in (5, 8)]
    assert light["hr_median_bpm"] == statistics.median(expected)
    assert light["windows"] == 4  # HR gaps do not break the beat windows


def test_a4_metadata_and_honesty_entries():
    """Block carries stage_source/model_dependent and not_applicable movement
    and oxygen entries; no movement stream and no qualified oxygen exist."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    req = _req(night, hr=_hr_1hz(600, 60.0), temp=_temp_1hz(600, 31.0),
               beats=_beats(600),
               breaths=_breaths(T0, T0 + 600, 4.0, 4.0),
               runs=(BreathRunIn(start=T0, end=T0 + 600),))
    block = physiology.compute_night(req, build_timeline(night), CFG)
    assert block["stage_source"] == "sleep-v2"
    assert block["model_dependent"] is True
    assert block["status"] in ("available", "partial", "withheld")
    assert isinstance(block["reasons"], list)
    light = block["stages"]["light"]
    assert light["movement_events_per_h"] is None
    assert light["movement"]["status"] == "not_applicable"
    assert "movement_stream_not_in_request" in light["movement"]["reasons"]
    assert light["oxygen"]["status"] == "not_applicable"
    assert "oxygen_unverified_sparse" in light["oxygen"]["reasons"]
    assert light["status"] == "available"
    assert light["skin_temp_median_c"] == 31.0
    _assert_finite_or_none(block)


def _hr_1hz(n: int, bpm: float = 60.0, start: int = T0) -> list[HrSampleIn]:
    return [HrSampleIn(ts=start + i, bpm=bpm) for i in range(n)]


def _temp_1hz(n: int, celsius: float = 31.0, start: int = T0) -> list[TempSampleIn]:
    return [TempSampleIn(ts=start + i, celsius=celsius) for i in range(n)]


# ---------------------------------------------------------------------------
# A7: RSA-derived respiratory variability
# ---------------------------------------------------------------------------


def test_a7_constant_intervals_zero_cv_and_rmssd():
    """Constant estimated breath intervals -> CV 0 and RMSSD 0, and the
    rate-unit conversion holds (60/median seconds = bpm)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 1800, stage="light")])
    breaths = _breaths(T0, T0 + 1800, 4.0, 4.0)
    runs = (BreathRunIn(start=T0, end=T0 + 1800),)
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["status"] == "available"
    assert block["intervals_valid"] == len(breaths)
    # rate-unit conversion: 60 / median(4.0 s) = 15 bpm
    assert block["rate_bpm"] == 15.0
    assert block["rate_bpm"] == 60.0 / statistics.median([b.seconds for b in breaths])
    assert block["sd_interval_s"] == 0.0
    assert block["cv_interval"] == 0.0
    assert block["rmssd_interval_s"] == 0.0
    assert block["valid_run_min"] == 30.0
    assert block["quality"]["usable_windows"] == 6
    assert block["stage_conditioned"]["light"]["windows"] == 6
    assert block["stage_conditioned"]["light"]["rate_bpm"] == 15.0
    assert block["stage_conditioned"]["light"]["cv_interval"] == 0.0
    assert block["stage_conditioned"]["wake"]["windows"] == 0
    assert block["stage_conditioned"]["deep"]["windows"] == 0
    assert block["stage_conditioned"]["rem"]["windows"] == 0
    _assert_finite_or_none(block)


def test_a7_real_variability_is_positive():
    """Varying estimated intervals produce positive CV, SD and RMSSD."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 1800, stage="light")])
    breaths = []
    ts = T0 + 5
    i = 0
    while ts < T0 + 1800:
        d = 4.0 + 0.6 * math.sin(i * 0.7)
        breaths.append(BreathIn(ts=ts, seconds=round(d, 3)))
        ts += 4
        i += 1
    runs = (BreathRunIn(start=T0, end=T0 + 1800),)
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["status"] == "available"
    assert block["sd_interval_s"] is not None and block["sd_interval_s"] > 0
    assert block["cv_interval"] is not None and block["cv_interval"] > 0
    assert block["rmssd_interval_s"] is not None and block["rmssd_interval_s"] > 0
    assert block["rate_bpm"] == 60.0 / statistics.median(
        b.seconds for b in breaths if b.ts < T0 + 1800)


def test_a7_run_boundary_does_not_enter_rmssd():
    """Adjacent-interval variability never crosses a run boundary: two constant
    runs at different rates yield RMSSD 0 even though the boundary pair sits in
    one usable window."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 1200, stage="light")])
    run1 = _breaths(T0, T0 + 500, 4.0, 4.0)          # 4.0 s cadence
    run2 = _breaths(T0 + 500, T0 + 900, 5.0, 5.0, phase=0)  # 5.0 s cadence
    breaths = sorted(run1 + run2, key=lambda b: b.ts)
    runs = (BreathRunIn(start=T0, end=T0 + 500),
            BreathRunIn(start=T0 + 500, end=T0 + 900))
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["status"] == "available"
    # the window [T0+300, T0+600) contains BOTH runs; the boundary pair (4.0 ->
    # 5.0) must not contribute, so RMSSD stays exactly 0
    assert block["rmssd_interval_s"] == 0.0
    # rate/cv reflect the pooled constant runs
    assert block["cv_interval"] is not None and block["cv_interval"] > 0
    assert block["rate_bpm"] > 0


def test_a7_sparse_intervals_windows_withheld():
    """Too few estimated breath intervals -> every window is unusable and the
    block is withheld (sparse R-R erases the RSA estimate)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    breaths = _breaths(T0, T0 + 120, 20.0, 4.0)  # only 6 intervals
    runs = (BreathRunIn(start=T0, end=T0 + 600),)
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["status"] == "withheld"
    assert "no_usable_windows" in block["reasons"]
    assert block["rate_bpm"] is None
    assert block["cv_interval"] is None
    assert block["rmssd_interval_s"] is None
    assert block["intervals_valid"] == 0


def test_a7_rate_unit_conversion():
    """rate_bpm = 60 / median(seconds)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    breaths = _breaths(T0, T0 + 600, 4.0, 4.0)
    runs = (BreathRunIn(start=T0, end=T0 + 600),)
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["status"] == "available"
    assert block["rate_bpm"] == 15.0




def test_a7_window_boundary_within_run_keeps_adjacency():
    """Adjacency is scoped to RUNS, not windows: two adjacent intervals inside
    one run across a 5-minute window boundary still contribute to RMSSD."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    # one run; constant 4.0 s except a single step right at the window edge
    breaths: list[BreathIn] = []
    ts = T0 + 5
    i = 0
    while ts < T0 + 600:
        d = 4.0 if i != 74 else 5.0  # step at ts ~ T0+301 (window boundary)
        breaths.append(BreathIn(ts=ts, seconds=d))
        ts += 4
        i += 1
    runs = (BreathRunIn(start=T0, end=T0 + 600),)
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["status"] == "available"
    # if the window-boundary pair were dropped, all diffs would be 0; the step
    # is inside one run, so it must be counted
    assert block["rmssd_interval_s"] == pytest.approx(1.0 / 74.0 ** 0.5, rel=1e-6)



def test_a7_estimate_wording_and_baseline_withheld():
    """Estimate source, honesty notes and the wave-1 personal-baseline gate."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    breaths = _breaths(T0, T0 + 600, 4.0, 4.0)
    runs = (BreathRunIn(start=T0, end=T0 + 600),)
    req = _req(night, breaths=breaths, runs=runs)
    block = respiration.compute_night(req, build_timeline(night), CFG)
    assert block["estimate_source"] == "rsa_derived_rr"
    assert block["unobserved_breath_is_not_apnea"] is True
    assert "not an apnea" in block["notes"]
    assert "RSA" in block["notes"]
    assert block["algorithm_source"] == "SleepStager.respBreathTrack(rr)"
    outlier = block["outlier_fraction_vs_personal"]
    assert outlier["status"] == "withheld"
    assert "no_personal_baseline" in outlier["reasons"]
    assert outlier["fraction"] is None
