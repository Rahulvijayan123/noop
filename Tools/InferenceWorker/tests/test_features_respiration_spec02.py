"""spec-02 respiratory additions (docs/spec-02/CONTRACT.md 5.2) and next-night rebound (5.5).

Acceptance (spec "Acceptance and stop conditions"): respiratory distributions use true intervals;
inserted gaps do not create long breaths, stable time or episodes. Rebound is descriptive, pairs
consecutive days only, and never scores a night against itself.
"""

from __future__ import annotations

import json
import math
import statistics

import numpy
import pytest

from frwhoop_inference.features import rebound, respiration
from frwhoop_inference.features.config import CONFIG
from frwhoop_inference.features.contract import (
    BreathIn,
    BreathRunIn,
    HistoryDayIn,
    HistoryNightIn,
    NightIn,
    SleepFeaturesContext,
    SleepFeaturesRequest,
    StageSegmentIn,
    fmt_utc,
    parse_request,
)
from frwhoop_inference.features.timeline import build_timeline

T0 = 1_800_000_000
CFG = CONFIG


def _ctx(start: int, end: int, digest: str | None = None) -> SleepFeaturesContext:
    return SleepFeaturesContext(
        user_id="resp-test", device_id="whoop5-test", day="2026-10-19",
        iana_timezone="UTC", input_revision=1, interval_start=start, interval_end=end,
        history_revision_digest=digest)


def _night(stages, end: int | None = None) -> NightIn:
    start = min(s.start for s in stages)
    return NightIn(night_id="n1", start=start, end=end if end is not None else max(s.end for s in stages),
                   is_nap=False, user_edited=False, stages=tuple(stages))


def _req(night, breaths=(), runs=(), history=(), digest=None) -> SleepFeaturesRequest:
    return SleepFeaturesRequest(
        context=_ctx(night.start, night.end, digest), nights=(night,), hr=(), temp=(), beats=(),
        breaths=tuple(sorted(breaths, key=lambda b: b.ts)), breath_runs=tuple(runs),
        history_days=tuple(history), capabilities={})


def _cadence(start: int, end: int, seconds, step: int = 4, phase: int = 5) -> list[BreathIn]:
    """Breaths every ``step`` s in [start+phase, end); ``seconds`` is a value or a cycle of values."""
    vals = seconds if isinstance(seconds, (list, tuple)) else [seconds]
    out, ts, i = [], start + phase, 0
    while ts < end:
        out.append(BreathIn(ts=ts, seconds=float(vals[i % len(vals)])))
        ts += step
        i += 1
    return out


def _resp(night, breaths, runs):
    return respiration.compute_night(_req(night, breaths, runs), build_timeline(night), CFG)


def _walk_keys(obj, out):
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.add(k)
            _walk_keys(v, out)
    elif isinstance(obj, list):
        for v in obj:
            _walk_keys(v, out)
    return out


# ---------------------------------------------------------------------------
# interval_distribution: true intervals only
# ---------------------------------------------------------------------------


def test_inserted_gap_does_not_create_a_long_breath():
    """A 15 s pseudo-interval stamped just after a 10 s run gap spans the gap: it is not a breath,
    so it enters neither the distribution nor the stage statistics (the legacy night SD, whose
    definition is unchanged, still sees it - documented)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 1200, stage="light")])
    run1 = BreathRunIn(start=T0, end=T0 + 590)
    run2 = BreathRunIn(start=T0 + 600, end=T0 + 1200)
    breaths = _cadence(T0, T0 + 590, 4.0) + _cadence(T0 + 600, T0 + 1200, 4.0, phase=9)
    gap_breath = BreathIn(ts=T0 + 605, seconds=15.0)  # earlier "peak" at T0+590 < run2.start
    block = _resp(night, breaths + [gap_breath], [run1, run2])
    dist = block["interval_distribution"]
    assert block["method_version"] == "resp-variability-2"
    assert dist["status"] == "available"
    assert dist["source"] == "consecutive_intervals_within_usable_runs"
    assert dist["n_intervals"] == len(breaths)  # the gap interval is not counted
    for key in ("p05_s", "p10_s", "p25_s", "median_s", "p75_s", "p90_s", "p95_s"):
        assert dist[key] == 4.0, key
    assert dist["iqr_s"] == 0.0
    light = block["stage_conditioned"]["light"]
    assert light["sd_interval_s"] == 0.0
    assert light["rmssd_interval_s"] == 0.0
    assert light["median_interval_s"] == 4.0 and light["iqr_interval_s"] == 0.0
    # the legacy night-level SD keeps its documented definition (all usable-window intervals)
    assert block["sd_interval_s"] > 0.0


def test_distribution_quantiles_match_numpy_linear():
    night = _night([StageSegmentIn(start=T0, end=T0 + 1800, stage="light")])
    cycle = [3.0, 3.5, 4.0, 4.5, 5.0, 6.5]
    breaths = _cadence(T0, T0 + 1800, cycle)
    block = _resp(night, breaths, [BreathRunIn(start=T0, end=T0 + 1800)])
    dist = block["interval_distribution"]
    ds = numpy.array([b.seconds for b in breaths])
    for q, key in ((5, "p05_s"), (10, "p10_s"), (25, "p25_s"), (50, "median_s"), (75, "p75_s"),
                   (90, "p90_s"), (95, "p95_s")):
        assert dist[key] == pytest.approx(float(numpy.percentile(ds, q)), abs=1e-12), key
    assert dist["median_s"] == statistics.median(ds.tolist())
    assert dist["iqr_s"] == pytest.approx(float(numpy.percentile(ds, 75) - numpy.percentile(ds, 25)))
    assert dist["n_intervals"] == len(breaths)
    assert dist["usable_windows"] == 6


def test_distribution_withheld_below_two_usable_windows():
    night = _night([StageSegmentIn(start=T0, end=T0 + 300, stage="light")])
    block = _resp(night, _cadence(T0, T0 + 300, 4.0), [BreathRunIn(start=T0, end=T0 + 300)])
    dist = block["interval_distribution"]
    assert dist["status"] == "withheld"
    assert dist["reasons"] == ["insufficient_usable_windows"]
    assert dist["median_s"] is None and dist["p95_s"] is None and dist["iqr_s"] is None


def test_no_breaths_everything_null_never_zero():
    night = _night([StageSegmentIn(start=T0, end=T0 + 1200, stage="light")])
    block = _resp(night, [], [])
    assert block["interval_distribution"]["status"] == "withheld"
    assert block["interval_distribution"]["median_s"] is None
    sm = block["stable_modulation"]
    assert sm["status"] == "withheld"
    assert sm["stable_minutes"] is None
    assert sm["stable_fraction_of_evaluated"] is None and sm["stable_fraction_of_night"] is None
    assert sm["evaluated_minutes"] == 0.0 and sm["unknown_minutes"] == 20.0
    for stage in ("wake", "light", "deep", "rem"):
        e = block["stage_conditioned"][stage]
        assert e["sd_interval_s"] is None and e["rmssd_interval_s"] is None
        assert e["median_interval_s"] is None and e["iqr_interval_s"] is None


def test_duplicate_and_irregular_breaths_are_handled():
    """Duplicate breath rows at the same second and irregular stamping keep every statistic
    finite; a duplicated row is a zero-difference adjacent pair inside its run (as the Swift
    track would export it), never a cross-run pair."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    breaths = _cadence(T0, T0 + 600, [3.8, 4.2, 4.0], step=4)
    breaths += [BreathIn(ts=breaths[10].ts, seconds=breaths[10].seconds)]
    irregular = [BreathIn(ts=b.ts + (i % 3), seconds=b.seconds) for i, b in enumerate(breaths)]
    block = _resp(night, irregular, [BreathRunIn(start=T0, end=T0 + 600)])
    assert block["interval_distribution"]["status"] == "available"
    assert math.isfinite(block["stage_conditioned"]["light"]["rmssd_interval_s"])
    json.dumps(block, allow_nan=False)


# ---------------------------------------------------------------------------
# stable_modulation
# ---------------------------------------------------------------------------


def test_stable_modulation_components_and_unknown_never_stable():
    """6 windows: 2 constant (stable), 2 alternating 2.5/5.5 s (evaluated, CV 0.375 > 0.25),
    1 run-covered but too sparse (unknown), 1 without any run (unknown)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 1800, stage="light")])
    stable = _cadence(T0, T0 + 600, 4.0)
    variable = _cadence(T0 + 600, T0 + 1200, [2.5, 5.5], phase=6)
    sparse = _cadence(T0 + 1200, T0 + 1500, 4.0, step=20, phase=10)  # 15 intervals < 20
    runs = [BreathRunIn(start=T0, end=T0 + 1500)]
    sm = _resp(night, stable + variable + sparse, runs)["stable_modulation"]
    assert sm["definition_version"] == "stable-resp-modulation-1"
    assert sm["status"] == "available"
    assert sm["criteria"] == {"window_s": 300.0, "min_run_coverage": 0.8, "min_intervals": 20.0,
                              "max_cv_interval": 0.25}
    assert sm["windows_total"] == 6 and sm["windows_evaluated"] == 4 and sm["windows_stable"] == 2
    assert sm["stable_minutes"] == 10.0
    assert sm["evaluated_minutes"] == 20.0
    assert sm["unknown_minutes"] == 10.0
    assert sm["stable_fraction_of_evaluated"] == 0.5
    assert sm["stable_fraction_of_night"] == pytest.approx(10.0 / 30.0)
    assert "unknown_time_never_stable" in sm["reasons"]


def test_gap_heavy_window_is_unknown_not_stable():
    """Perfectly constant intervals in a window whose runs cover only half of it: the window is
    unknown (a gap never becomes stable time)."""
    night = _night([StageSegmentIn(start=T0, end=T0 + 300, stage="light")])
    breaths = _cadence(T0, T0 + 150, 4.0, step=2)  # 73 intervals, but only 150 s of run
    sm = _resp(night, breaths, [BreathRunIn(start=T0, end=T0 + 150)])["stable_modulation"]
    assert sm["windows_evaluated"] == 0
    assert sm["stable_minutes"] is None
    assert sm["unknown_minutes"] == 5.0


# ---------------------------------------------------------------------------
# per-stage additions, supported range, wording
# ---------------------------------------------------------------------------


def test_stage_conditioned_true_interval_statistics():
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light"),
                    StageSegmentIn(start=T0 + 600, end=T0 + 1200, stage="deep")])
    light = _cadence(T0, T0 + 600, [3.5, 4.5])
    deep = _cadence(T0 + 600, T0 + 1200, 5.0, step=5, phase=6)
    block = _resp(night, light + deep, [BreathRunIn(start=T0, end=T0 + 1200)])
    sl, sd = block["stage_conditioned"]["light"], block["stage_conditioned"]["deep"]
    lds = [b.seconds for b in light]
    assert sl["median_interval_s"] == statistics.median(lds)
    assert sl["sd_interval_s"] == pytest.approx(statistics.stdev(lds))
    assert sl["rmssd_interval_s"] == pytest.approx(1.0)  # |3.5-4.5| every adjacent pair
    assert sl["iqr_interval_s"] == pytest.approx(float(numpy.percentile(lds, 75) - numpy.percentile(lds, 25)))
    assert sd["median_interval_s"] == 5.0 and sd["sd_interval_s"] == 0.0 and sd["rmssd_interval_s"] == 0.0
    assert block["stage_conditioned"]["rem"]["median_interval_s"] is None


def test_supported_range_and_no_clinical_counts():
    night = _night([StageSegmentIn(start=T0, end=T0 + 600, stage="light")])
    block = _resp(night, _cadence(T0, T0 + 600, 4.0), [BreathRunIn(start=T0, end=T0 + 600)])
    assert block["supported_range"] == {"detector_band_bpm": [6.0, 24.0], "min_peak_spacing_s": 2.5,
                                        "display_rate_range_bpm": [8.0, 25.0],
                                        "source": "SleepStager.respBreathTrack"}
    keys = _walk_keys(block, set())
    for banned in ("tachypnea", "bradypnea", "apnea_count", "pause", "score", "coupling"):
        assert not any(banned in k for k in keys), banned
    json.dumps(block, allow_nan=False)


# ---------------------------------------------------------------------------
# rebound
# ---------------------------------------------------------------------------


def _day(i: int, asleep, awake=30.0, *, tz="UTC", is_nap=False, extra=()) -> HistoryDayIn:
    day = f"2026-09-{i + 1:02d}"
    start = T0 + i * 86_400
    nights = (HistoryNightIn(start=start, end=start + 8 * 3600, is_nap=is_nap, asleep_min=asleep,
                             awake_min=awake, efficiency=None),) + tuple(extra)
    return HistoryDayIn(day=day, minutes=(), nights=nights, timezone=tz)


def _rebound(days, digest="abc"):
    night = _night([StageSegmentIn(start=T0 + 40 * 86_400, end=T0 + 40 * 86_400 + 600, stage="light")])
    return rebound.compute(_req(night, history=days, digest=digest))


def _baseline_with_short(short_at=(2, 6, 10), next_asleep=(480.0, 470.0, 490.0), n=14):
    days = []
    nxt = dict(zip([s + 1 for s in short_at], next_asleep))
    for i in range(n):
        asleep = 300.0 if i in short_at else nxt.get(i, 420.0)
        days.append(_day(i, asleep))
    return days


def test_rebound_after_short_nights_hand_computed():
    block = _rebound(_baseline_with_short())
    assert block["definition_version"] == "sleep-rebound-1"
    assert block["status"] == "available"
    assert block["history_revision_digest"] == "abc"
    # leave-pair-out reference of every pair is 420 / 30 -> next-night diffs 60, 50, 70 and 0
    s = block["after_short"]
    assert s["pairs"] == 3
    assert s["pair_days"] == [["2026-09-03", "2026-09-04"], ["2026-09-07", "2026-09-08"],
                              ["2026-09-11", "2026-09-12"]]
    assert s["next_night_asleep_diff_min"] == {"median": 60.0, "iqr": 10.0, "segments": 3}
    assert s["next_night_awake_diff_min"] == {"median": 0.0, "iqr": 0.0, "segments": 3}
    assert block["after_fragmented"]["pairs"] == 0
    assert block["after_fragmented"]["next_night_asleep_diff_min"]["median"] is None
    assert "no_fragmented_nights_observed" in block["reasons"]
    ref = block["personal_reference"]
    assert ref["nights"] == 14 and ref["median_asleep_min"] == 420.0 and ref["median_awake_min"] == 30.0
    assert set(block["rules"]) == {"short_below_reference_min", "fragmented_above_reference_min",
                                   "min_reference_nights", "min_pairs"}
    assert all(isinstance(v, float) for v in block["rules"].values())
    keys = _walk_keys(block, set())
    for banned in ("probability", "cause", "predict", "score"):
        assert not any(banned in k for k in keys), banned


def test_rebound_needs_consecutive_days():
    days = [d for d in _baseline_with_short() if d.day != "2026-09-08"]  # the day after the 2nd short
    s = _rebound(days)["after_short"]
    assert s["pairs"] == 2
    assert s["next_night_asleep_diff_min"]["median"] is None  # below min_pairs: null, not zero
    assert "short_insufficient_pairs" in _rebound(days)["reasons"]


def test_rebound_fragmented_and_short_can_coincide():
    days = []
    for i in range(14):
        if i in (2, 6, 10):
            days.append(_day(i, 300.0, awake=80.0))
        elif i in (3, 7, 11):
            days.append(_day(i, 450.0, awake=20.0))
        else:
            days.append(_day(i, 420.0))
    block = _rebound(days)
    assert block["after_short"]["pairs"] == 3 and block["after_fragmented"]["pairs"] == 3
    assert block["after_fragmented"]["next_night_awake_diff_min"]["median"] == -10.0
    assert block["after_fragmented"]["next_night_asleep_diff_min"]["median"] == 30.0


def test_rebound_reference_is_leave_pair_out():
    """With exactly 9 valid nights a pair has 7 others; a pair's own nights never enter its
    reference (the next night 600 min would otherwise shift a 9-night median)."""
    asleep = [420.0, 300.0, 600.0, 420.0, 420.0, 420.0, 420.0, 400.0, 400.0]
    block = _rebound([_day(i, a) for i, a in enumerate(asleep)])
    s = block["after_short"]
    assert s["pairs"] == 1
    assert s["pair_days"] == [["2026-09-02", "2026-09-03"]]
    # others: 420 x5, 400 x2 -> median 420 -> 600 - 420 = 180 (below min_pairs: count only)
    assert s["next_night_asleep_diff_min"]["median"] is None


def test_rebound_main_night_nulls_naps_and_duplicates():
    nap = HistoryNightIn(start=T0 + 13 * 3600, end=T0 + 14 * 3600, is_nap=False, asleep_min=50.0,
                         awake_min=5.0, efficiency=None)
    days = _baseline_with_short()
    days[0] = _day(0, 420.0, extra=(nap,))  # the longer entry is the main night
    days[4] = _day(4, None)                 # null minutes: excluded, never zero
    days.append(_day(13, 420.0))            # duplicate day: last occurrence kept
    block = _rebound(days)
    assert "history_nights_without_minutes_excluded" in block["reasons"]
    assert "duplicate_history_day_resolved" in block["reasons"]
    assert block["personal_reference"]["nights"] == 13
    assert block["after_short"]["pairs"] == 3


def test_rebound_withheld_without_history_or_reference():
    empty = _rebound([HistoryDayIn(day="2026-09-01", minutes=(), nights=(), timezone=None)])
    assert empty["status"] == "withheld" and empty["reasons"] == ["history_nights_not_in_request"]
    assert empty["after_short"]["pairs"] == 0
    few = _rebound([_day(i, 420.0) for i in range(5)])
    assert few["status"] == "withheld" and few["reasons"] == ["insufficient_reference_nights"]


def test_rebound_flags_timezone_change_inside_a_pair():
    days = _baseline_with_short()
    days[3] = _day(3, 480.0, tz="Europe/London")
    assert "pair_spans_timezone_change" in _rebound(days)["reasons"]


def test_rebound_reads_history_nights_from_the_wire():
    """The wire shape the worker sends (history.days[].nights / timezone) parses into the block."""
    def wire_day(i, asleep):
        start = T0 + i * 86_400
        return {"day": f"2026-09-{i + 1:02d}", "minutes": [], "timezone": "UTC",
                "nights": [{"start": start, "end": start + 28_800, "is_nap": False,
                            "asleep_min": asleep, "awake_min": 30.0, "efficiency": 0.93}]}
    asleep = {2: 300.0, 3: 480.0, 6: 300.0, 7: 470.0, 10: 300.0, 11: 490.0}
    n0 = T0 + 40 * 86_400
    body = {
        "schema_version": 1, "algorithm_version": "nara-sleep-features-1",
        "context": {"user_id": "u", "device_id": "d", "day": "2026-10-10", "iana_timezone": "UTC",
                    "input_revision": 1, "interval_start_utc": fmt_utc(n0 - 3600),
                    "interval_end_utc": fmt_utc(n0 + 7200), "stage_algorithm_version": "v",
                    "history_revision_digest": "d" * 64},
        "nights": [{"night_id": "n", "start_utc": fmt_utc(n0), "end_utc": fmt_utc(n0 + 3600),
                    "is_nap": False, "user_edited": False,
                    "stages": [{"start": n0, "end": n0 + 3600, "stage": "light"}]}],
        "history": {"pair_policy": "elapsed_24h",
                    "days": [wire_day(i, asleep.get(i, 420.0)) for i in range(14)]},
    }
    req = parse_request(body)
    block = rebound.compute(req)
    assert block["status"] == "available"
    assert block["history_revision_digest"] == "d" * 64
    assert block["after_short"]["next_night_asleep_diff_min"]["median"] == 60.0
