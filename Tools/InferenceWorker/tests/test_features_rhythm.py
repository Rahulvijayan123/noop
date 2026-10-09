"""Tests for features/rhythm.py (spec-02 sections 3-4; docs/spec-02/CONTRACT.md 5.1 / 5.4):
the observed multi-day skin-temperature rhythm, its phase relations / drift, and the
document-level rest-activity rhythm.

Every fixture is synthetic, deterministic and built from declared ground truth in ACTUAL
UTC time (bins are UTC-hour aligned, as the worker sends them).
"""

from __future__ import annotations

import json
import os
import math
import random
import statistics
import time
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import numpy as np
import pytest

from frwhoop_inference.features import rhythm, thermal
from frwhoop_inference.features.compute import compute
from frwhoop_inference.features.config import CONFIG
from frwhoop_inference.features.contract import (
    HistoryDayIn,
    HistoryNightIn,
    NightIn,
    SleepFeaturesContext,
    SleepFeaturesRequest,
    StageSegmentIn,
    _parse_rhythm_history,
)
from frwhoop_inference.features.timeline import build_timeline

LA = "America/Los_Angeles"
NY = "America/New_York"


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------


def local_midnight(d: date, tz: str) -> int:
    return int(datetime(d.year, d.month, d.day, tzinfo=ZoneInfo(tz)).timestamp())


def utc_hour(ts: float) -> float:
    return (ts % 86400) / 3600.0


def cosine(mesor: float, amp: float, acro_utc_h: float):
    return lambda t: mesor + amp * math.cos(2 * math.pi * (utc_hour(t) - acro_utc_h) / 24.0)


def day_wire(d: date, tz: str, temp_fn=None, hr_fn=None, mov_fn=None, keep=None,
             minutes: int = 60, revision: int = 1, noise: float = 0.0, rng=None,
             identity: str | None = None) -> dict:
    """One rhythm-history day: UTC-hour bins whose start lies in [local midnight, next)."""
    ds = local_midnight(d, tz)
    de = local_midnight(d + timedelta(days=1), tz)
    rng = rng or random.Random(0)
    bins = []
    start = ds - ds % 3600 + (3600 if ds % 3600 else 0)
    while start < de:
        mid = start + 1800
        lh = datetime.fromtimestamp(mid, ZoneInfo(tz)).hour
        if keep is None or keep(lh, start):
            b = {"start": start,
                 "skin_temp_c": None, "skin_temp_valid_minutes": 0,
                 "hr_mean_bpm": None, "hr_valid_minutes": 0,
                 "movement_s_per_min": None, "movement_valid_minutes": 0}
            if temp_fn is not None:
                b["skin_temp_c"] = round(temp_fn(mid) + rng.gauss(0, noise), 4)
                b["skin_temp_valid_minutes"] = minutes
            if hr_fn is not None:
                b["hr_mean_bpm"] = round(hr_fn(mid), 3)
                b["hr_valid_minutes"] = minutes
            if mov_fn is not None:
                b["movement_s_per_min"] = round(min(60.0, max(0.0, mov_fn(mid, lh))), 4)
                b["movement_valid_minutes"] = minutes
            bins.append(b)
        start += 3600
    out = {"day": d.isoformat(), "timezone": tz, "revision": revision,
           "day_start_utc": ds, "day_end_utc": de, "bins": bins}
    if identity is not None:
        out["conversion_identity"] = identity
    return out


def history_wire(days: list[dict], family="whoop5", identity="whoop5-centidegree") -> dict:
    return {"schema": "rhythm-history-1", "device_family": family,
            "conversion_identity": identity, "bin_seconds": 3600,
            "rules": {"minute_min_distinct_seconds": 30, "worn_minute_min_hr_seconds": 30,
                      "skin_temp_plausible_c": [28.0, 42.0], "movement_threshold_g": 0.01},
            "revision_digest": "d" * 64, "days": days}


def main_night(end_day: date, tz: str = LA, night_id: str = "main") -> NightIn:
    end = local_midnight(end_day, tz) + 7 * 3600
    start = end - 8 * 3600
    return NightIn(night_id=night_id, start=start, end=end, is_nap=False, user_edited=False,
                   stages=(StageSegmentIn(start=start, end=end, stage="light"),))


def make_request(history: dict | None, nights=(), tz: str = LA,
                 history_days=()) -> SleepFeaturesRequest:
    ctx = SleepFeaturesContext(user_id="u", device_id="d", day="2026-10-20", iana_timezone=tz,
                               input_revision=1, interval_start=0, interval_end=0,
                               history_revision_digest=None)
    return SleepFeaturesRequest(
        context=ctx, nights=tuple(nights), hr=(), temp=(), beats=(), breaths=(),
        breath_runs=(), history_days=tuple(history_days), capabilities={},
        rhythm_history=_parse_rhythm_history(history) if history is not None else None)


def days_range(first: date, n: int) -> list[date]:
    return [first + timedelta(days=i) for i in range(n)]


def rhythm_for(days: list[dict], tz: str = LA, end_day: date | None = None, **kw) -> dict:
    hist = history_wire(days, **kw)
    end = end_day or date.fromisoformat(days[-1]["day"])
    night = main_night(end, tz)
    return rhythm.observed_skin_temp_rhythm(make_request(hist, nights=(night,), tz=tz), night)


def assert_json_safe(obj):
    json.dumps(obj, allow_nan=False)


FIRST = date(2026, 10, 1)


# ---------------------------------------------------------------------------
# Cosinor: recovery, SE, flat
# ---------------------------------------------------------------------------


def test_known_cosine_is_recovered_with_sane_uncertainty():
    rng = random.Random(7)
    fn = cosine(33.5, 0.8, 3.0)  # UTC 03:00 = 20:00 PDT
    days = [day_wire(d, LA, temp_fn=fn, noise=0.1, rng=rng) for d in days_range(FIRST, 7)]
    block = rhythm_for(days)
    assert block["status"] == "available", block["reasons"]
    assert block["method_version"] == "skin-temp-rhythm-1"
    assert block["mesor_c"] == pytest.approx(33.5, abs=0.03)
    assert block["amplitude_c"] == pytest.approx(0.8, abs=0.04)
    assert block["acrophase_utc_h"] == pytest.approx(3.0, abs=0.2)
    assert block["acrophase_h"] == pytest.approx(20.0, abs=0.2)  # local PDT clock
    assert block["acrophase_local_timezone"] == LA
    assert block["fit_quality"] > 0.9
    unc = block["uncertainty"]
    assert 0.0 < unc["acrophase_se_h"] < 0.3
    assert 0.0 < unc["amplitude_se_c"] < 0.05
    assert unc["acrophase_se_h"] >= unc["acrophase_delta_se_h"]
    assert block["phase_status"] == {"status": "available", "reasons": []}
    assert block["qualifying_days"] == 7 and block["days_evaluated"] == 7
    assert block["coverage"]["quadrants_observed"] == [True, True, True, True]
    assert block["coverage"]["day_hours_supported"] == 7 * 12
    assert block["coverage"]["night_hours_supported"] == 7 * 12
    assert block["history_revision_digest"] == "d" * 64
    assert block["iv_definition"] == "consecutive_valid_hour_pairs_across_midnight"
    assert block["regularity_name"] == "temperature_regularity"
    assert_json_safe(block)


def test_delta_method_se_matches_monte_carlo():
    """The delta-method SEs agree with the empirical spread over replicate datasets
    (independent noise, where the OLS covariance is exact to first order)."""
    rng = np.random.default_rng(11)
    ts = [1_790_000_000 + 3600 * i + 1800 for i in range(5 * 24)]
    truth = np.array([33.0 + 0.6 * math.cos(2 * math.pi * (utc_hour(t) - 15.0) / 24) for t in ts])
    acro, amp, se_acro, se_amp = [], [], [], []
    for _ in range(400):
        fit = rhythm.cosinor_weighted(ts, truth + rng.normal(0, 0.3, len(ts)))
        acro.append(fit["acrophase_utc_h"])
        amp.append(fit["amplitude"])
        se_acro.append(fit["se_acrophase_h"])
        se_amp.append(fit["se_amplitude"])
    emp_acro = statistics.pstdev([rhythm.circ_diff_h(a, 15.0) for a in acro])
    emp_amp = statistics.pstdev(amp)
    assert statistics.fmean(se_acro) == pytest.approx(emp_acro, rel=0.15)
    assert statistics.fmean(se_amp) == pytest.approx(emp_amp, rel=0.15)
    # closed form for balanced hourly sampling: SE(A) = SE(phi_rad) * A = sigma * sqrt(2/n)
    assert statistics.fmean(se_amp) == pytest.approx(0.3 * math.sqrt(2 / len(ts)), rel=0.1)


def test_cosinor_matches_closed_form_on_balanced_grid():
    ts = [1_790_000_000 + 3600 * i + 1800 for i in range(48)]
    ys = [30.0 + 1.5 * math.cos(2 * math.pi * (utc_hour(t) - 22.75) / 24) for t in ts]
    fit = rhythm.cosinor_weighted(ts, ys)
    assert fit["mesor"] == pytest.approx(30.0, abs=1e-9)
    assert fit["amplitude"] == pytest.approx(1.5, abs=1e-9)
    assert fit["acrophase_utc_h"] == pytest.approx(22.75, abs=1e-9)
    assert fit["r2"] == pytest.approx(1.0, abs=1e-12)


def test_flat_temperature_is_zero_amplitude_and_phase_unavailable():
    rng = random.Random(3)
    days = [day_wire(d, LA, temp_fn=lambda t: 33.2, noise=0.05, rng=rng)
            for d in days_range(FIRST, 7)]
    block = rhythm_for(days)
    assert block["status"] == "partial"
    assert block["phase_status"] == {"status": "unavailable", "reasons": ["zero_amplitude"]}
    assert block["acrophase_h"] is None and block["acrophase_utc_h"] is None
    assert block["mesor_c"] == pytest.approx(33.2, abs=0.02)
    assert block["amplitude_c"] is not None and block["amplitude_c"] < 0.05
    rel = block["phase_relations"]
    assert rel["hr_minus_temp"]["difference_h"] is None
    assert "temperature_phase_unavailable" in rel["hr_minus_temp"]["reasons"]
    assert_json_safe(block)


def test_exactly_flat_temperature_never_divides_by_zero():
    days = [day_wire(d, LA, temp_fn=lambda t: 33.0) for d in days_range(FIRST, 6)]
    block = rhythm_for(days)
    assert block["phase_status"]["reasons"] == ["zero_amplitude"]
    assert block["is"] is None and block["iv"] is None
    assert_json_safe(block)


def test_unstable_daily_phase_is_unavailable():
    rng = random.Random(5)
    acros = [2.0, 10.0, 18.0, 6.0, 14.0, 22.0, 4.0]
    days = [day_wire(d, LA, temp_fn=cosine(33.0, 0.8, a), noise=0.05, rng=rng)
            for d, a in zip(days_range(FIRST, 7), acros)]
    block = rhythm_for(days)
    assert block["phase_status"]["status"] == "unavailable"
    assert block["phase_status"]["reasons"] in (["unstable_phase"], ["zero_amplitude"])
    assert block["acrophase_h"] is None


# ---------------------------------------------------------------------------
# Gate: days, coverage, quadrants, night-only
# ---------------------------------------------------------------------------


def test_night_only_history_is_withheld_insufficient_daytime_temperature():
    night_hours = lambda lh, s: lh >= 22 or lh < 7  # noqa: E731
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), keep=night_hours)
            for d in days_range(FIRST, 10)]
    block = rhythm_for(days)
    assert block["status"] == "withheld"
    assert "insufficient_daytime_temperature" in block["reasons"]
    assert "insufficient_days" in block["reasons"]
    assert block["phase_status"]["status"] == "unavailable"
    assert "insufficient_daytime_temperature" in block["phase_status"]["reasons"]
    assert block["mesor_c"] is None and block["acrophase_h"] is None
    assert block["coverage"]["day_hours_supported"] == 10 * 1  # 06:00-07:00 only
    assert block["coverage"]["quadrants_observed"] == [True, True, False, True]


def test_four_qualifying_days_is_insufficient_days():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0)) for d in days_range(FIRST, 4)]
    block = rhythm_for(days)
    assert block["status"] == "withheld"
    assert block["reasons"] == ["insufficient_days"]
    assert block["qualifying_days"] == 4


def test_day_coverage_boundary_80_percent():
    # 20 of 24 hours = 83 % qualifies; 19 of 24 = 79 % does not.
    def keep(n_missing):
        return lambda lh, s: not (8 <= lh < 8 + n_missing)
    ok = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), keep=keep(4))
          for d in days_range(FIRST, 5)]
    assert rhythm_for(ok)["qualifying_days"] == 5
    thin = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), keep=keep(5))
            for d in days_range(FIRST, 5)]
    assert rhythm_for(thin)["qualifying_days"] == 0


def test_thin_hours_do_not_count_as_support():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), minutes=29)
            for d in days_range(FIRST, 7)]
    block = rhythm_for(days)
    assert block["status"] == "withheld"
    assert "insufficient_days" in block["reasons"]
    assert block["coverage"]["days_with_data"] == 0


def test_missing_quadrant_is_reported():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), keep=lambda lh, s: lh >= 6)
            for d in days_range(FIRST, 7)]
    block = rhythm_for(days)
    assert block["status"] == "withheld"
    assert "quadrant_unobserved" in block["reasons"]
    assert block["coverage"]["quadrants_observed"] == [False, True, True, True]


def test_naps_and_other_nights_are_not_applicable():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0)) for d in days_range(FIRST, 7)]
    hist = history_wire(days)
    nap = NightIn(night_id="nap", start=local_midnight(date(2026, 10, 7), LA) + 14 * 3600,
                  end=local_midnight(date(2026, 10, 7), LA) + 15 * 3600, is_nap=True,
                  user_edited=False, stages=())
    main = main_night(date(2026, 10, 7))
    req = make_request(hist, nights=(main, nap))
    block = rhythm.observed_skin_temp_rhythm(req, nap)
    assert block["status"] == "not_applicable" and block["reasons"] == ["nap"]
    assert block["phase_status"]["status"] == "not_applicable"
    assert rhythm.observed_skin_temp_rhythm(req, main)["status"] == "available"


def test_absent_history_keeps_multi_day_history_not_requested():
    night = main_night(date(2026, 10, 7))
    block = rhythm.observed_skin_temp_rhythm(make_request(None, nights=(night,)), night)
    assert block["status"] == "withheld"
    assert block["reasons"] == ["multi_day_history_not_requested"]
    for key in ("mesor_c", "amplitude_c", "acrophase_h", "fit_quality", "is", "iv",
                "daily_amplitude_c", "phase_stability_h"):
        assert block[key] is None


# ---------------------------------------------------------------------------
# Mixed devices, duplicates
# ---------------------------------------------------------------------------


def test_mixed_conversion_identities_make_the_phase_unavailable():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0),
                     identity="whoop5-centidegree" if i < 4 else "whoop4-provisional-affine:anchor=1290")
            for i, d in enumerate(days_range(FIRST, 8))]
    block = rhythm_for(days)
    assert block["status"] == "withheld"
    assert block["reasons"] == ["mixed_devices"]
    assert block["phase_status"] == {"status": "unavailable", "reasons": ["mixed_devices"]}
    assert block["mesor_c"] is None and block["amplitude_c"] is None
    days2 = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0)) for d in days_range(FIRST, 8)]
    assert rhythm_for(days2, family="mixed", identity="mixed")["reasons"] == ["mixed_devices"]


def test_duplicate_days_and_bins_are_deduplicated():
    rng = random.Random(9)
    clean = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), noise=0.05, rng=rng)
             for d in days_range(FIRST, 7)]
    base = rhythm_for(clean)
    stale = json.loads(json.dumps(clean[2]))
    stale["revision"] = 0
    for b in stale["bins"]:
        b["skin_temp_c"] = 40.0  # an older revision of the same day must lose
    overlap = json.loads(json.dumps(clean[3]))
    overlap["day"] = "2026-10-30"  # a different day label re-sending day 4's bins
    overlap["day_start_utc"] = clean[3]["day_start_utc"]
    dup = rhythm_for([stale] + clean + [overlap], end_day=date(2026, 10, 7))
    assert dup["coverage"]["duplicate_days_dropped"] == 1
    assert dup["coverage"]["duplicate_bins_dropped"] == len(clean[3]["bins"])
    for key in ("mesor_c", "amplitude_c", "acrophase_h", "is", "iv"):
        assert dup[key] == pytest.approx(base[key], abs=1e-9), key


# ---------------------------------------------------------------------------
# Midnight / DST / timezone change: no fake drift
# ---------------------------------------------------------------------------


def test_dst_week_keeps_utc_phase_and_lists_the_clock_change():
    # DST ends in Los Angeles on 2026-11-01 (a 25 h local day). UTC physiology is constant.
    rng = random.Random(1)
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), noise=0.05, rng=rng)
            for d in days_range(date(2026, 10, 28), 8)]
    assert len(days[4]["bins"]) == 25
    block = rhythm_for(days)
    assert block["status"] == "available"
    assert block["qualifying_days"] == 8
    assert block["acrophase_utc_h"] == pytest.approx(3.0, abs=0.15)
    drift = block["phase_drift"]
    assert drift["status"] == "available"
    assert abs(drift["utc_drift_h_per_day"]) < 0.05
    changes = drift["clock_changes"]
    assert changes == [{"day": "2026-11-01", "kind": "dst", "from_timezone": LA,
                        "to_timezone": LA, "from_offset_h": -7.0, "to_offset_h": -8.0}]
    local = {p["day"]: p["acrophase_local_h"] for p in drift["daily_phases"]}
    # The local clock label moves by the relabeling (20:00 PDT -> 19:00 PST), the body does not.
    assert local["2026-10-29"] == pytest.approx(20.0, abs=0.3)
    assert local["2026-11-03"] == pytest.approx(19.0, abs=0.3)
    assert block["phase_stability_h"] < 0.3


def test_timezone_change_alone_produces_no_drift():
    rng = random.Random(2)
    days = [day_wire(d, LA if i < 4 else NY, temp_fn=cosine(33.5, 0.8, 3.0), noise=0.05, rng=rng)
            for i, d in enumerate(days_range(FIRST, 9))]
    block = rhythm_for(days, tz=NY)
    drift = block["phase_drift"]
    assert abs(drift["utc_drift_h_per_day"]) < 0.05
    tz_changes = [c for c in drift["clock_changes"] if c["kind"] == "timezone"]
    assert tz_changes == [{"day": "2026-10-05", "kind": "timezone", "from_timezone": LA,
                           "to_timezone": NY, "from_offset_h": -7.0, "to_offset_h": -4.0}]
    real = drift["observed_realignment"]
    assert real["status"] == "available"
    assert real["clock_shift_h"] == pytest.approx(3.0)
    assert real["required_utc_shift_h"] == pytest.approx(-3.0)
    assert real["utc_phase_change_h"] == pytest.approx(0.0, abs=0.2)
    assert real["fraction_realigned"] == pytest.approx(0.0, abs=0.1)
    # local acrophase now reported on the New York clock: 03:00 UTC = 23:00 EDT
    assert block["acrophase_h"] == pytest.approx(23.0, abs=0.2)


def test_observed_realignment_after_eastward_travel():
    # The UTC phase moves 1 h earlier per day after the change, then holds at -3 h.
    shifts = [0, 0, 0, 0, -1, -2, -3, -3, -3]
    rng = random.Random(4)
    days = [day_wire(d, LA if i < 4 else NY, temp_fn=cosine(33.5, 0.8, (3.0 + s) % 24),
                     noise=0.03, rng=rng)
            for i, (d, s) in enumerate(zip(days_range(FIRST, 9), shifts))]
    block = rhythm_for(days, tz=NY)
    real = block["phase_drift"]["observed_realignment"]
    assert real["utc_phase_change_h"] == pytest.approx(-3.0, abs=0.2)
    assert real["fraction_realigned"] == pytest.approx(1.0, abs=0.07)
    assert real["days_since_change"] == 4
    assert block["phase_drift"]["utc_drift_h_per_day"] < -0.3  # real UTC movement is drift


def test_acrophase_near_midnight_wraps():
    rng = random.Random(6)
    days = [day_wire(d, LA, temp_fn=cosine(33.0, 0.7, 23.8 if i % 2 else 0.2), noise=0.02,
                     rng=rng)
            for i, d in enumerate(days_range(FIRST, 7))]
    block = rhythm_for(days)
    assert block["status"] == "available"
    assert abs(rhythm.circ_diff_h(block["acrophase_utc_h"], 0.0)) < 0.3
    assert block["phase_stability_h"] < 0.5
    assert abs(block["phase_drift"]["utc_drift_h_per_day"]) < 0.2


# ---------------------------------------------------------------------------
# IS / IV against the reference formulas
# ---------------------------------------------------------------------------


def _reference_iv(series: list[float | None]) -> float:
    """pyActigraphy on a regular NaN-gapped grid: diff().pow(2).mean() / var(ddof=0)."""
    x = np.array([np.nan if v is None else v for v in series], dtype=float)
    d = np.diff(x)
    num = np.nanmean(d ** 2)
    return float(num / np.nanvar(x))


def test_iv_counts_consecutive_hours_across_midnight():
    start = 1_790_000_000 - 1_790_000_000 % 3600
    vals = [float(h % 24) for h in range(5 * 24)]
    pts = [(start + 3600 * i, v) for i, v in enumerate(vals)]
    iv, pairs, n = rhythm.intradaily_variability(pts)
    n_ref = len(vals)
    ref = n_ref * sum((b - a) ** 2 for a, b in zip(vals, vals[1:])) / (
        (n_ref - 1) * sum((v - statistics.fmean(vals)) ** 2 for v in vals))
    assert pairs == n - 1 == 119
    assert iv == pytest.approx(ref, rel=1e-12)
    assert iv == pytest.approx(_reference_iv(vals), rel=1e-12)
    # the old within-day-only variant would have been ~27x smaller here
    within_day_only = (120 / 119) * (5 * 23) / (5 * 1150)
    assert iv > 10 * within_day_only


def test_iv_preserves_gaps_with_valid_pair_normalisation():
    rng = random.Random(8)
    start = 1_790_000_000 - 1_790_000_000 % 3600
    series: list[float | None] = [33 + math.sin(i / 3.0) + rng.gauss(0, 0.1) for i in range(72)]
    for i in (5, 6, 30, 47, 48, 49):
        series[i] = None
    pts = [(start + 3600 * i, v) for i, v in enumerate(series) if v is not None]
    iv, pairs, n = rhythm.intradaily_variability(pts)
    assert n == 66
    # a pair needs both hours valid AND truly adjacent: gaps remove the pairs on both sides
    assert pairs == sum(1 for a, b in zip(series, series[1:]) if a is not None and b is not None)
    assert iv == pytest.approx(_reference_iv(series), rel=1e-12)


def test_is_matches_reference_formula_and_pyactigraphy_on_complete_days():
    rng = random.Random(10)
    days = [[30 + math.cos(2 * math.pi * h / 24) + rng.gauss(0, 0.2) for h in range(24)]
            for _ in range(6)]
    pts = [(h, v) for d in days for h, v in enumerate(d)]
    is_value = rhythm.interdaily_stability(pts)
    vals = [v for _, v in pts]
    xbar = statistics.fmean(vals)
    hour_means = [statistics.fmean(d[h] for d in days) for h in range(24)]
    ref = len(vals) * sum((m - xbar) ** 2 for m in hour_means) / (
        24 * sum((v - xbar) ** 2 for v in vals))
    assert is_value == pytest.approx(ref, rel=1e-12)
    # pyActigraphy: groupby(hour).mean().var(ddof=0) / var(ddof=0)
    assert is_value == pytest.approx(float(np.var(hour_means) / np.var(vals)), rel=1e-12)
    assert is_value == pytest.approx(thermal.interdaily_stability(days), rel=1e-12)
    # thermal's complete-day helper now agrees with the series IV (pairs across midnight)
    start = 1_790_000_000 - 1_790_000_000 % 3600
    iv, _, _ = rhythm.intradaily_variability([(start + 3600 * i, v) for i, v in enumerate(vals)])
    assert thermal.intradaily_variance(days) == pytest.approx(iv, rel=1e-12)


def test_temperature_regularity_uses_cross_midnight_pairs_in_block():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0)) for d in days_range(FIRST, 6)]
    block = rhythm_for(days)
    # 6 complete 24 h days -> 144 hours, 143 consecutive pairs (5 of them across midnight)
    assert block["regularity_hours"] == 144
    assert block["iv_valid_pairs"] == 143
    assert block["is"] == pytest.approx(1.0, abs=1e-6)  # identical every day


# ---------------------------------------------------------------------------
# Phase relations
# ---------------------------------------------------------------------------


def _history_days_with_nights(dates: list[date], mid_utc_h: float) -> list[HistoryDayIn]:
    out = []
    for d in dates:
        day0 = int(datetime(d.year, d.month, d.day, tzinfo=ZoneInfo("UTC")).timestamp())
        mid = day0 + int(mid_utc_h * 3600)
        out.append(HistoryDayIn(day=d.isoformat(), minutes=(), nights=(
            HistoryNightIn(start=mid - 4 * 3600, end=mid + 4 * 3600, is_nap=False,
                           asleep_min=420.0, awake_min=40.0, efficiency=90.0),
            HistoryNightIn(start=mid + 8 * 3600, end=mid + 9 * 3600, is_nap=True,
                           asleep_min=50.0, awake_min=5.0, efficiency=90.0)), timezone=LA))
    return out


def test_phase_relations_need_independent_supported_phases():
    rng = random.Random(12)
    dates = days_range(FIRST, 7)
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), hr_fn=cosine(62.0, 6.0, 23.0),
                     noise=0.03, rng=rng) for d in dates]
    hist = history_wire(days)
    night = main_night(dates[-1])
    req = make_request(hist, nights=(night,), history_days=_history_days_with_nights(dates, 10.0))
    block = rhythm.observed_skin_temp_rhythm(req, night)
    hr = block["phase_relations"]["hr_minus_temp"]
    assert hr["status"] == "available"
    assert hr["difference_h"] == pytest.approx(-4.0, abs=0.2)  # 23:00 - 03:00 UTC
    assert hr["a_utc_h"] == pytest.approx(23.0, abs=0.1) and hr["b_utc_h"] == pytest.approx(3.0, abs=0.2)
    assert hr["a_h"] == pytest.approx(16.0, abs=0.1)  # local PDT
    assert hr["support_days"] == 7
    sl = block["phase_relations"]["sleep_midpoint_minus_temp"]
    assert sl["status"] == "available"
    assert sl["difference_h"] == pytest.approx(7.0, abs=0.2)  # 10:00 - 03:00 UTC
    assert sl["support_days"] >= 5


def test_phase_relations_withheld_without_hr_or_sleep_history():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0)) for d in days_range(FIRST, 7)]
    block = rhythm_for(days)
    hr = block["phase_relations"]["hr_minus_temp"]
    assert hr["status"] == "withheld" and hr["difference_h"] is None
    assert "hr_insufficient_days" in hr["reasons"]
    sl = block["phase_relations"]["sleep_midpoint_minus_temp"]
    assert sl["status"] == "withheld" and "insufficient_sleep_periods" in sl["reasons"]


def test_flat_hr_rhythm_is_not_a_supported_phase():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0), hr_fn=lambda t: 60.0)
            for d in days_range(FIRST, 7)]
    hr = rhythm_for(days)["phase_relations"]["hr_minus_temp"]
    assert hr["status"] == "withheld"
    assert "hr_zero_amplitude" in hr["reasons"]


# ---------------------------------------------------------------------------
# Rest-activity rhythm
# ---------------------------------------------------------------------------


def _activity(mid: float, lh: int) -> float:
    # active 08-22 local (20 s/min with a midday peak), quiet at night (1 s/min)
    if 8 <= lh < 22:
        return 20.0 + (5.0 if 12 <= lh < 14 else 0.0)
    return 1.0


def ra_request(days: list[dict]) -> SleepFeaturesRequest:
    return make_request(history_wire(days), nights=(main_night(date.fromisoformat(days[-1]["day"])),))


def test_rest_activity_rhythm_matches_hand_computed_values():
    days = [day_wire(d, LA, mov_fn=_activity) for d in days_range(FIRST, 7)]
    block = rhythm.rest_activity_rhythm(ra_request(days))
    assert block["status"] == "available", block["reasons"]
    assert block["signal"] == "gravity_movement_seconds_per_minute"
    assert block["epoch_seconds"] == 3600 and block["binarized"] is False
    assert block["count_threshold"] is None
    assert block["movement_threshold_g"] == 0.01
    assert block["days_used"] == 7 and block["hours_used"] == 168
    profile = [_activity(0, h) for h in range(24)]
    l5 = 1.0                                      # any 5 h inside 22:00-08:00
    m10 = statistics.fmean(sorted(profile)[-10:])  # 10 h incl. the 12-14 peak
    assert block["l5"] == pytest.approx(l5)
    assert block["m10"] == pytest.approx(m10, abs=1e-4)
    assert block["l5_start_h"] == 0.0             # earliest of the tied quiet windows
    assert 8 <= block["m10_start_h"] <= 12
    assert block["ra"] == pytest.approx((m10 - l5) / (m10 + l5), abs=1e-4)
    assert block["is"] == pytest.approx(1.0, abs=1e-9)
    vals = profile * 7
    assert block["iv"] == pytest.approx(_reference_iv(vals), rel=1e-4)
    assert block["deferred"] == ["lids", "kra_kar", "24h_align"]
    assert_json_safe(block)


def test_rest_activity_withheld_without_movement_history():
    days = [day_wire(d, LA, temp_fn=cosine(33.5, 0.8, 3.0)) for d in days_range(FIRST, 7)]
    block = rhythm.rest_activity_rhythm(ra_request(days))
    assert block["status"] == "withheld" and block["reasons"] == ["movement_history_absent"]
    assert block["is"] is None and block["l5"] is None
    no_hist = rhythm.rest_activity_rhythm(make_request(None))
    assert no_hist["reasons"] == ["multi_day_history_not_requested"]


def test_rest_activity_never_presents_sleep_only_movement_as_full_day():
    night_only = lambda lh, s: lh >= 22 or lh < 7  # noqa: E731
    days = [day_wire(d, LA, mov_fn=_activity, keep=night_only) for d in days_range(FIRST, 10)]
    block = rhythm.rest_activity_rhythm(ra_request(days))
    assert block["status"] == "withheld"
    assert "insufficient_days" in block["reasons"]
    assert "insufficient_daytime_movement" in block["reasons"]
    assert block["is"] is None and block["ra"] is None


def test_rest_activity_incomplete_profile_withholds_l5_m10():
    # every day misses local 03:00 (still >= 80 % coverage): IS/IV computable, L5/M10 are not
    days = [day_wire(d, LA, mov_fn=_activity, keep=lambda lh, s: lh != 3)
            for d in days_range(FIRST, 7)]
    block = rhythm.rest_activity_rhythm(ra_request(days))
    assert block["status"] == "partial"
    assert block["reasons"] == ["incomplete_daily_profile"]
    assert block["is"] is not None and block["l5"] is None and block["ra"] is None


# ---------------------------------------------------------------------------
# Wire / integration / budget
# ---------------------------------------------------------------------------


def test_parser_accepts_per_day_identity_and_refuses_bad_values():
    days = [day_wire(FIRST, LA, temp_fn=cosine(33, 1, 3), identity="whoop5-centidegree")]
    parsed = _parse_rhythm_history(history_wire(days))
    assert parsed.days[0].conversion_identity == "whoop5-centidegree"
    bad = history_wire(days)
    bad["days"][0]["conversion_identity"] = ""
    from frwhoop_inference.features.contract import ContractError
    with pytest.raises(ContractError):
        _parse_rhythm_history(bad)


def _full_night_request(history: dict | None) -> SleepFeaturesRequest:
    import os
    from frwhoop_inference.features.contract import parse_request
    base = os.path.join(os.path.dirname(__file__), "..", "..", "CloudWorker", "Tests",
                        "frwhoop-workerTests", "SleepFeatureWireFixtures")
    body = json.load(open(os.path.join(base, "sleep_features_request.json")))
    if history is not None:
        body["rhythm_history"] = history
    return parse_request(body)


def _realistic_history(end_day: date, n_days: int = 35) -> dict:
    rng = random.Random(21)
    days = [day_wire(d, LA, temp_fn=cosine(33.6, 0.9, 4.0), hr_fn=cosine(64.0, 7.0, 22.0),
                     mov_fn=lambda mid, lh: _activity(mid, lh) + rng.random(), noise=0.15,
                     rng=rng, revision=100 + i)
            for i, d in enumerate(days_range(end_day - timedelta(days=n_days - 1), n_days))]
    return history_wire(days)


def test_compute_wires_rhythm_into_main_night_and_document_within_budget():
    plain = _full_night_request(None)
    end_day = date.fromisoformat(plain.context.day)
    hist = _realistic_history(end_day)
    req = _full_night_request(hist)
    assert sum(len(d.bins) for d in req.rhythm_history.days) <= 35 * 26
    t0 = time.perf_counter()
    doc = compute(plain, budget_ms=60000)
    t_plain = time.perf_counter() - t0
    t0 = time.perf_counter()
    doc = compute(req, budget_ms=60000)
    t_with = time.perf_counter() - t0
    t0 = time.perf_counter()
    main = req.main_night()
    rhythm.observed_skin_temp_rhythm(req, main)
    rhythm.rest_activity_rhythm(req)
    t_rhythm = time.perf_counter() - t0
    print(f"\ncompute without history {t_plain*1000:.0f} ms, with 35-day history "
          f"{t_with*1000:.0f} ms, rhythm blocks alone {t_rhythm*1000:.1f} ms")
    json.dumps(doc, allow_nan=False)
    mains = [n for n in doc["nights"] if not n["is_nap"]]
    block = mains[0]["thermal"]["observed_skin_temp_rhythm"]
    assert block["status"] == "available", block["reasons"]
    assert block["qualifying_days"] == 35
    assert block["phase_relations"]["hr_minus_temp"]["status"] == "available"
    ra = doc["rest_activity_rhythm"]
    assert ra["status"] == "available"
    assert ra["history_revision_digest"] == "d" * 64
    # generous: the 3 s route budget is shared with the whole night; rhythm must be small
    assert t_rhythm < 1.0


# ---------------------------------------------------------------------------
# Producer -> app golden (decoded by StrandAnalytics SleepFeatureRhythmGoldenTests)
# ---------------------------------------------------------------------------

GOLDEN = os.path.join(os.path.dirname(__file__), "..", "..", "..", "Packages", "StrandAnalytics",
                      "Tests", "StrandAnalyticsTests", "Goldens", "SleepFeatures",
                      "spec02_rhythm_blocks.json")


def golden_blocks() -> dict:
    """A deterministic 9-day history with an eastward time-zone change, an HR rhythm,
    sleep periods and full-day movement: every rhythm sub-block is populated."""
    shifts = [0, 0, 0, 0, -1, -2, -3, -3, -3]
    dates = days_range(FIRST, 9)
    rng = random.Random(31)
    days = [day_wire(d, LA if i < 4 else NY, temp_fn=cosine(33.5, 0.8, (3.0 + s) % 24),
                     hr_fn=cosine(62.0, 6.0, (23.0 + s) % 24), mov_fn=_activity, noise=0.03,
                     rng=rng, revision=50 + i)
            for i, (d, s) in enumerate(zip(dates, shifts))]
    hist = history_wire(days)
    night = main_night(dates[-1], NY)
    req = make_request(hist, nights=(night,), tz=NY,
                       history_days=_history_days_with_nights(dates, 10.0))
    return {"observed_skin_temp_rhythm": rhythm.observed_skin_temp_rhythm(req, night),
            "rest_activity_rhythm": rhythm.rest_activity_rhythm(req)}


def test_committed_rhythm_golden_matches_the_producer():
    """The golden the Swift decoder test reads is exactly what this producer emits (regenerate
    with FRWHOOP_WRITE_RHYTHM_GOLDEN=1 after checking a changed output is correct)."""
    blocks = json.loads(json.dumps(golden_blocks(), allow_nan=False))
    if os.environ.get("FRWHOOP_WRITE_RHYTHM_GOLDEN") == "1":
        os.makedirs(os.path.dirname(GOLDEN), exist_ok=True)
        with open(GOLDEN, "w") as f:
            json.dump(blocks, f, indent=1, sort_keys=True)
            f.write("\n")
    committed = json.load(open(GOLDEN))
    assert blocks == committed
    t = blocks["observed_skin_temp_rhythm"]
    assert t["status"] == "available"
    assert t["phase_relations"]["hr_minus_temp"]["status"] == "available"
    assert t["phase_relations"]["sleep_midpoint_minus_temp"]["status"] == "available"
    assert t["phase_drift"]["observed_realignment"]["status"] == "available"
    assert blocks["rest_activity_rhythm"]["status"] == "available"


def test_parser_accepts_the_exact_worker_shape():
    """The shape SleepFeatureRhythmHistory.assemble emits (rules with lists and strings,
    per-day family/identity, null signals with 0 minutes) parses and computes."""
    worker = {
        "schema": "rhythm-history-1", "device_family": "whoop5",
        "conversion_identity": "whoop5-centidegree", "bin_seconds": 3600,
        "rules": {"rules_version": "rhythm-rules-1", "minute_min_distinct_seconds": 30,
                  "worn_minute_min_hr_seconds": 30, "hr_plausible_bpm": [20, 250],
                  "skin_temp_plausible_c": [28.0, 42.0], "movement_threshold_g": 0.01,
                  "movement_minute_min_adjacencies": 30,
                  "temp_minute_value": "median_of_in_band_seconds",
                  "hour_temp_value": "median_of_valid_minute_medians",
                  "hour_hr_value": "mean_of_valid_minute_means",
                  "hour_movement_value": "60 * moving_adjacencies / eligible_adjacencies",
                  "worn_evidence": "hr_seconds_in_minute"},
        "revision_digest": "a" * 64,
        "days": [{"day": "2026-09-10", "timezone": "UTC", "revision": 105,
                  "day_start_utc": 1788998400, "day_end_utc": 1789084800,
                  "device_family": "whoop5", "conversion_identity": "whoop5-centidegree",
                  "bins": [{"start": 1788998400, "skin_temp_c": 33.02,
                            "skin_temp_valid_minutes": 60, "hr_mean_bpm": 60.0,
                            "hr_valid_minutes": 60, "movement_s_per_min": None,
                            "movement_valid_minutes": 0}]}],
    }
    parsed = _parse_rhythm_history(worker)
    b = parsed.days[0].bins[0]
    assert b.skin_temp_c == 33.02 and b.movement_s_per_min is None and b.movement_valid_minutes == 0
    assert parsed.days[0].device_family == "whoop5"
    req = make_request(worker, nights=(main_night(date(2026, 9, 10), "UTC"),), tz="UTC")
    block = rhythm.observed_skin_temp_rhythm(req, req.nights[0])
    assert block["status"] == "withheld" and "insufficient_days" in block["reasons"]
    assert rhythm.rest_activity_rhythm(req)["reasons"] == ["movement_history_absent"]
