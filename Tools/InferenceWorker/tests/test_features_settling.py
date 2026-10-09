"""Tests for the worker-settling modules: features/settling.py (spec A5) and
features/thermal.py (spec A6), covering every check named in the spec.

Wire keys and status semantics follow docs/SLEEP_FEATURES_CONTRACT.md section 3.
All fixtures are synthetic, deterministic, and built from declared ground truth.
"""

from __future__ import annotations

import json
import math
import statistics

import pytest

from frwhoop_inference.features.config import CONFIG
from frwhoop_inference.features.contract import (
    BeatIn,
    HrSampleIn,
    NightIn,
    SleepFeaturesContext,
    SleepFeaturesRequest,
    StageSegmentIn,
    TempSampleIn,
)
from frwhoop_inference.features.settling import (
    compute_night as settling_compute,
)
from frwhoop_inference.features.thermal import (
    compute_night as thermal_compute,
    cosinor_fit,
    find_thermal_transition,
    interdaily_stability,
    intradaily_variance,
    rhythm_gate,
)
from frwhoop_inference.features.timeline import build_timeline

S = 1_700_000_000  # anchor onset (unix seconds)
VALID_STATUSES = {"available", "partial", "withheld", "not_applicable"}


def make_context() -> SleepFeaturesContext:
    return SleepFeaturesContext(
        user_id="u1", device_id="whoop5-x", day="2026-10-19",
        iana_timezone="Europe/London", input_revision=1,
        interval_start=0, interval_end=0, history_revision_digest=None,
    )


def make_request(hr=(), temp=(), beats=(), nights=()) -> SleepFeaturesRequest:
    return SleepFeaturesRequest(
        context=make_context(), nights=tuple(nights), hr=tuple(hr), temp=tuple(temp),
        beats=tuple(beats), breaths=(), breath_runs=(), history_days=(),
        capabilities={},
    )


def night_with_onset(s: int, sleep_s: int = 8 * 3600,
                     wake_before: int = 3600, wake_after: int = 3600) -> NightIn:
    start = s - wake_before
    end = s + sleep_s + wake_after
    stages = (
        StageSegmentIn(start=start, end=s, stage="wake"),
        StageSegmentIn(start=s, end=s + sleep_s, stage="light"),
        StageSegmentIn(start=s + sleep_s, end=end, stage="wake"),
    )
    return NightIn(night_id="n1", start=start, end=end, is_nap=False,
                   user_edited=False, stages=stages)


def night_no_sleep(s: int = S) -> NightIn:
    start = s - 3600
    end = s + 3600
    return NightIn(night_id="n1", start=start, end=end, is_nap=False,
                   user_edited=False,
                   stages=(StageSegmentIn(start=start, end=end, stage="wake"),))


# -- sample generators (1 Hz: 60 distinct seconds per minute) ----------------


def minute_samples(s: int, m: int, value: float, n: int = 60) -> list[tuple[int, float]]:
    return [(s + m * 60 + i, value) for i in range(n)]


def hr_series(s: int, lo: int, hi: int, fn) -> list[HrSampleIn]:
    out: list[HrSampleIn] = []
    for m in range(lo, hi):
        for ts, bpm in minute_samples(s, m, fn(m)):
            out.append(HrSampleIn(ts=ts, bpm=bpm))
    return out


def temp_series(s: int, lo: int, hi: int, fn) -> list[TempSampleIn]:
    out: list[TempSampleIn] = []
    for m in range(lo, hi):
        for ts, celsius in minute_samples(s, m, fn(m)):
            out.append(TempSampleIn(ts=ts, celsius=celsius))
    return out


def beat_series(s: int, m_lo: int, m_hi: int, base: float = 1000.0,
                amp: float = 25.0) -> list[BeatIn]:
    beats: list[BeatIn] = []
    i = 0
    t = s + m_lo * 60
    end = s + m_hi * 60
    while t < end:
        rr = base + amp * math.sin(i * 0.7)
        beats.append(BeatIn(ts=t, rr_ms=rr, seq=i, ordn=0, src_channel=1))
        t += 1
        i += 1
    return beats


def walk_numeric_leaves(node, out):
    if isinstance(node, dict):
        for value in node.values():
            walk_numeric_leaves(value, out)
    elif isinstance(node, list):
        for item in node:
            walk_numeric_leaves(item, out)
    elif isinstance(node, (int, float)) and not isinstance(node, bool):
        out.append(node)
    return out


def assert_no_nonfinite(block):
    leaves = []
    walk_numeric_leaves(block, leaves)
    for value in leaves:
        assert math.isfinite(value), f"non-finite leaf {value}"


# ===========================================================================
# A5 — settling
# ===========================================================================


def test_a5_gradual_decline_negative_early_slope_and_positive_drop():
    """Gradual decline -> negative early slope and positive drop (pre - post)."""
    night = night_with_onset(S)

    def hr_fn(m):
        if m < 0:
            return 72.0
        if m < 30:
            return 72.0 - 0.4 * m
        return 60.0

    hr = hr_series(S, -30, 90, hr_fn)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    assert block["status"] in VALID_STATUSES
    assert block["hr_pre_onset_slope_bpm_min"] is not None
    assert abs(block["hr_pre_onset_slope_bpm_min"]) < 0.05          # flat pre-onset
    assert block["hr_early_sleep_slope_bpm_min"] is not None
    assert block["hr_early_sleep_slope_bpm_min"] < -0.2             # negative slope
    assert block["hr_drop_bpm"] is not None
    assert block["hr_drop_bpm"] > 2.0                               # positive drop
    # plateau eventually detected once the flat tail dominates the 10-min window
    assert block["hr_settling_latency_min"] is not None
    assert 20 <= block["hr_settling_latency_min"] <= 30
    # raw curves preserved
    assert len(block["hr_curve"]) == 120
    assert all(e["valid"] for e in block["hr_curve"])


def test_a5_flat_hr_no_drop_zero_slope_and_plateau_detected():
    """Flat HR -> no drop, slope ~0, plateau detected at the first window."""
    night = night_with_onset(S)
    hr = hr_series(S, -30, 90, lambda m: 65.0)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    assert abs(block["hr_pre_onset_slope_bpm_min"]) <= 1e-9
    assert abs(block["hr_early_sleep_slope_bpm_min"]) <= 1e-9
    assert block["hr_drop_bpm"] is not None
    assert abs(block["hr_drop_bpm"]) <= 1e-9
    assert block["hr_settling_latency_min"] == 0
    assert block["hr_nadir_latency_min"] == 0
    assert block["status"] == "available"


def test_a5_sustained_rising_hr_positive_slope_no_plateau():
    """Sustained rising HR -> positive slope, no plateau (or none early)."""
    night = night_with_onset(S)
    hr = hr_series(S, -30, 90, lambda m: 60.0 + 0.5 * m)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    assert block["hr_early_sleep_slope_bpm_min"] > 0.4
    assert block["hr_drop_bpm"] is not None
    assert block["hr_drop_bpm"] < 0                                # rise -> negative drop
    assert block["hr_settling_latency_min"] is None
    assert "no_detected_plateau" in block["reasons"]


def test_a5_isolated_artifact_spike_slope_robust():
    """Isolated artifact spikes do not move the robust slopes; raw curve keeps them."""
    night = night_with_onset(S)

    def hr_fn(m):
        if m in (-10, 10):
            return 120.0
        return 65.0

    hr = hr_series(S, -30, 90, hr_fn)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    assert abs(block["hr_pre_onset_slope_bpm_min"]) <= 1e-9
    assert abs(block["hr_early_sleep_slope_bpm_min"]) <= 1e-9
    curve = {e["ts"]: e for e in block["hr_curve"]}
    assert curve[S + 10 * 60]["bpm"] == 120.0   # raw spike preserved for the UI
    assert curve[S - 10 * 60]["bpm"] == 120.0


def test_a5_truncated_pre_onset_record_thin_data():
    """Truncated pre-onset record -> pre-onset slope null + thin_data."""
    night = night_with_onset(S)
    # HR exists only from minute -2 onwards: fewer than 4 valid pre-onset minutes.
    hr = hr_series(S, -2, 90, lambda m: 65.0)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    assert block["hr_pre_onset_slope_bpm_min"] is None
    assert "thin_data" in block["reasons"]
    # early sleep side is unaffected
    assert block["hr_early_sleep_slope_bpm_min"] is not None
    assert abs(block["hr_early_sleep_slope_bpm_min"]) <= 1e-9


def test_a5_gap_around_onset_invalid_minutes_and_both_sides_computed():
    """A data gap around onset marks invalid minutes; windows on both sides compute."""
    night = night_with_onset(S)
    # no HR samples for minutes [-3, 2] around onset
    gap = {-3, -2, -1, 0, 1, 2}
    hr = [s for m in range(-30, 90)
          if m not in gap
          for s in minute_samples(S, m, 65.0)]
    hr = [HrSampleIn(ts=ts, bpm=v) for ts, v in hr]
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    curve = {e["ts"]: e for e in block["hr_curve"]}
    for m in gap:
        e = curve[S + m * 60]
        assert e["valid"] is False
        assert e["bpm"] is None
    # both sides still computed
    assert block["hr_pre_onset_slope_bpm_min"] is not None
    assert block["hr_early_sleep_slope_bpm_min"] is not None
    assert abs(block["hr_pre_onset_slope_bpm_min"]) <= 1e-9
    assert abs(block["hr_early_sleep_slope_bpm_min"]) <= 1e-9


def test_a5_no_sleep_onset_withheld():
    night = night_no_sleep()
    block = settling_compute(make_request(nights=(night,)), build_timeline(night), CONFIG)
    assert block["status"] == "withheld"
    assert "no_sleep_onset" in block["reasons"]


def test_a5_nadir_earliest_minimum_window():
    """hr_nadir_latency is the earliest minute of the minimum 5-min mean."""
    night = night_with_onset(S)

    def hr_fn(m):
        if 20 <= m < 60:
            return 55.0
        return 70.0

    hr = hr_series(S, -30, 90, hr_fn)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)
    assert block["hr_nadir_latency_min"] == 20


def test_a5_hrv_early_sleep_curve_and_log_slope():
    """HRV early-sleep curve entries carry ts/rmssd_ms/pairs/coverage; >=4 windows -> slope."""
    night = night_with_onset(S)
    hr = hr_series(S, -30, 90, lambda m: 65.0)
    beats = beat_series(S, 0, 60, base=1000.0, amp=25.0)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    curve = block["hrv_early_sleep_curve"]
    assert len(curve) == 12
    for entry in curve:
        assert set(entry) == {"ts", "rmssd_ms", "pairs", "coverage"}
        assert entry["rmssd_ms"] is not None and entry["rmssd_ms"] > 0
        assert entry["pairs"] >= 1
        assert 0.0 < entry["coverage"] <= 1.0
        assert (entry["ts"] - S) % 300 == 0
    assert block["hrv_early_sleep_log_slope_per_min"] is not None
    assert math.isfinite(block["hrv_early_sleep_log_slope_per_min"])


def test_a5_hrv_thin_log_slope():
    """Fewer than 4 usable HRV windows -> log slope null + thin_data."""
    night = night_with_onset(S)
    hr = hr_series(S, -30, 90, lambda m: 65.0)
    beats = beat_series(S, 0, 10)  # only 2 windows of beats
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)
    assert block["hrv_early_sleep_log_slope_per_min"] is None
    assert "thin_data" in block["reasons"]


def test_a5_curves_span_shape_and_temp_curve():
    """hr_curve and temp_curve span [-30,+90) minutes with exact wire keys."""
    night = night_with_onset(S)
    hr = hr_series(S, -30, 90, lambda m: 65.0)
    temp = temp_series(S, -30, 90, lambda m: 30.0 + 0.01 * m)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, temp=temp, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)

    assert len(block["hr_curve"]) == 120
    assert len(block["temp_curve"]) == 120
    assert block["hr_curve"][0]["ts"] == S - 30 * 60
    assert block["hr_curve"][-1]["ts"] == S + 89 * 60
    for entry in block["hr_curve"]:
        assert set(entry) == {"ts", "bpm", "valid"}
    for entry in block["temp_curve"]:
        assert set(entry) == {"ts", "celsius", "valid"}
    assert block["temp_curve"][60]["celsius"] == pytest.approx(30.3, abs=1e-9)  # minute 30


def test_a5_block_no_nonfinite_numbers():
    night = night_with_onset(S)
    hr = hr_series(S, -30, 90, lambda m: 65.0)
    beats = beat_series(S, 0, 60)
    block = settling_compute(make_request(hr=hr, beats=beats, nights=(night,)),
                             build_timeline(night), CONFIG)
    assert_no_nonfinite(block)
    json.dumps(block, allow_nan=False)


# ===========================================================================
# A6 — thermal nightly metrics
# ===========================================================================


def test_a6_nightly_metrics_baseline_delta_rise_peak_prewake():
    """baseline/delta/rise slope/peak latency/pre-wake slope on a synthetic profile."""
    night = night_with_onset(S, sleep_s=8 * 3600)

    def temp_fn(m):
        if m < 0:
            return 30.0
        if m < 30:
            return 30.0 + 0.01 * m
        return 30.3

    temp = temp_series(S, -60, 480, temp_fn)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)

    assert block["baseline_c"] == pytest.approx(30.0, abs=1e-9)
    assert block["early_sleep_delta_c"] == pytest.approx(0.3, abs=1e-9)
    assert block["rise_slope_c_min"] == pytest.approx(0.01, abs=1e-6)
    # earliest 5-min window whose median is the maximum (window [28,33) is all 30.3)
    assert block["peak_latency_min"] == 28
    assert block["pre_wake_slope_c_min"] is not None
    assert abs(block["pre_wake_slope_c_min"]) <= 1e-9  # flat tail before wake


def test_a6_thermal_rise_absent_not_supported():
    """Absent thermal rise -> thermal_transition.supported false + no_detectable_transition."""
    night = night_with_onset(S)
    temp = temp_series(S, -60, 480, lambda m: 30.0)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)

    transition = block["thermal_transition"]
    assert transition["supported"] is False
    assert transition["improvement_pct"] == pytest.approx(0.0, abs=1e-9)
    assert "no_detectable_transition" in block["reasons"]


def test_a6_breakpoint_found_at_known_minute():
    """A synthetic flat-then-rising profile yields the known breakpoint at m=0."""
    night = night_with_onset(S)

    def temp_fn(m):
        if m < 0:
            return 30.0
        return 30.0 + 0.05 * m

    temp = temp_series(S, -45, 46, temp_fn)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)

    transition = block["thermal_transition"]
    assert transition["supported"] is True
    assert transition["onset_min"] == 0
    assert transition["post_slope_c_min"] == pytest.approx(0.05, abs=1e-6)
    assert transition["improvement_pct"] >= 20.0
    assert transition["sustained_c"] >= transition["sustained_threshold_c"]
    assert block["thermal_to_sleep_latency_min"] == pytest.approx(0.0, abs=1e-9)


def test_a6_thermal_to_sleep_latency_sign_preserved():
    """Thermal onset before sleep onset -> positive latency; after -> negative."""
    night = night_with_onset(S)

    def temp_fn(m, rise_at):
        if m < rise_at:
            return 30.0
        return 30.0 + 0.05 * (m - rise_at)

    # rise starts 10 minutes BEFORE onset -> latency +10
    before = temp_series(S, -45, 46, lambda m: temp_fn(m, -10))
    block_before = thermal_compute(make_request(temp=before, nights=(night,)),
                                   build_timeline(night), CONFIG)
    assert block_before["thermal_transition"]["supported"] is True
    assert block_before["thermal_transition"]["onset_min"] == -10
    assert block_before["thermal_to_sleep_latency_min"] == pytest.approx(10.0, abs=1e-9)

    # rise starts 15 minutes AFTER onset -> latency -15
    after = temp_series(S, -45, 46, lambda m: temp_fn(m, 15))
    block_after = thermal_compute(make_request(temp=after, nights=(night,)),
                                  build_timeline(night), CONFIG)
    assert block_after["thermal_transition"]["supported"] is True
    assert block_after["thermal_transition"]["onset_min"] == 15
    assert block_after["thermal_to_sleep_latency_min"] == pytest.approx(-15.0, abs=1e-9)


def test_a6_thermal_thin_data_reasons():
    """Sparse temperature -> nightly thermal metrics null with thin_data."""
    night = night_with_onset(S)
    # only minutes [-20, -19) populated: fewer than 4 valid minutes in [-45,-15)
    temp = temp_series(S, -20, -18, lambda m: 30.0)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)
    assert block["baseline_c"] is None
    assert "thin_data" in block["reasons"]


def test_a6_no_sleep_onset_withheld():
    night = night_no_sleep()
    block = thermal_compute(make_request(nights=(night,)), build_timeline(night), CONFIG)
    assert block["status"] == "withheld"
    assert "no_sleep_onset" in block["reasons"]


def test_a6_multi_day_rhythm_withheld_not_requested():
    """One-day request -> observed rhythm sub-block withheld, nightly keys present."""
    night = night_with_onset(S)
    temp = temp_series(S, -60, 480, lambda m: 30.0)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)
    rhythm = block["observed_skin_temp_rhythm"]
    assert rhythm["status"] == "withheld"
    assert "multi_day_history_not_requested" in rhythm["reasons"]
    for key in ("mesor_c", "amplitude_c", "acrophase_h", "fit_quality",
                "is", "iv", "daily_amplitude_c", "phase_stability_h"):
        assert key in rhythm and rhythm[key] is None
    # nightly keys are still present
    assert "baseline_c" in block
    assert "thermal_to_sleep_latency_min" in block


def test_a6_notes_flag_exploratory_and_wear_caveats():
    night = night_with_onset(S)
    temp = temp_series(S, -60, 480, lambda m: 30.0)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)
    notes = " ".join(block["notes"]).lower()
    assert "not an established sleep-onset detector" in notes
    assert "room temperature" in notes
    assert "charging" in notes  # charging/wear exclusion is flagged, not applied
    rhythm_notes = " ".join(block["observed_skin_temp_rhythm"]["notes"]).lower()
    assert "skin-temperature acrophase" in rhythm_notes
    assert "dlmo" in rhythm_notes


def test_a6_sparse_minute_invalid_in_block():
    """A minute with weak time support is marked invalid and excluded from windows."""
    night = night_with_onset(S)
    temp = temp_series(S, -60, 120, lambda m: 30.0)
    # replace minute 5 with only 10 observed seconds
    sparse_ts = {S + 5 * 60 + i for i in range(10)}
    filtered = [t for t in temp if t.ts not in sparse_ts]
    filtered = list(filtered) + [TempSampleIn(ts=t, celsius=30.0) for t in sparse_ts]
    block = thermal_compute(make_request(temp=filtered, nights=(night,)),
                            build_timeline(night), CONFIG)
    # the sparse minute is a single invalid minute: baseline/rise unaffected
    assert block["baseline_c"] == pytest.approx(30.0, abs=1e-9)
    assert block["rise_slope_c_min"] == pytest.approx(0.0, abs=1e-9)


def test_a6_thermal_block_no_nonfinite_numbers():
    night = night_with_onset(S)
    temp = temp_series(S, -60, 480, lambda m: 30.0 + 0.01 * m)
    block = thermal_compute(make_request(temp=temp, nights=(night,)),
                            build_timeline(night), CONFIG)
    assert_no_nonfinite(block)
    json.dumps(block, allow_nan=False)


# ===========================================================================
# A6 — cosinor / rhythm pure functions
# ===========================================================================


def _days(hours_per_day=24, n_days=7, value_fn=None):
    days = []
    for d in range(n_days):
        day = []
        for h in range(hours_per_day):
            day.append(value_fn(d, h) if value_fn else 30.0)
        days.append(day)
    return days


def test_a6_cosinor_recovers_synthetic_cosine():
    """Known synthetic cosine -> mesor/amplitude/acrophase recovered within tolerance."""
    bins = []
    for d in range(7):
        for h in range(24):
            t = d * 24.0 + h
            bins.append((t, 30.0 + 2.0 * math.cos(2.0 * math.pi * (h - 5.0) / 24.0)))
    fit = cosinor_fit(bins)
    assert fit["mesor_c"] == pytest.approx(30.0, abs=1e-6)
    assert fit["amplitude_c"] == pytest.approx(2.0, abs=1e-6)
    assert fit["acrophase_h"] == pytest.approx(5.0, abs=1e-6)
    assert fit["fit_quality"] == pytest.approx(1.0, abs=1e-6)
    assert fit["n_bins"] == 7 * 24


def test_a6_cosinor_flat_signal_null_phase():
    """Flat signal -> null acrophase / null fit quality (zero variance handled)."""
    bins = [(d * 24.0 + h, 32.0) for d in range(7) for h in range(24)]
    fit = cosinor_fit(bins)
    assert fit["mesor_c"] == pytest.approx(32.0, abs=1e-6)
    assert fit["amplitude_c"] is not None and fit["amplitude_c"] <= 1e-6
    assert fit["acrophase_h"] is None
    assert fit["fit_quality"] is None


def test_a6_cosinor_reference_shift_acrophase():
    """Shifting the time reference by 6 h shifts the acrophase by 6 h (mod 24)."""
    bins = []
    for d in range(7):
        for h in range(24):
            t = d * 24.0 + h
            bins.append((t, 30.0 + 2.0 * math.cos(2.0 * math.pi * (h - 5.0) / 24.0)))
    shifted = [(t + 6.0, v) for t, v in bins]
    fit = cosinor_fit(bins)
    fit_shift = cosinor_fit(shifted)
    assert fit_shift["mesor_c"] == pytest.approx(fit["mesor_c"], abs=1e-6)
    assert fit_shift["amplitude_c"] == pytest.approx(fit["amplitude_c"], abs=1e-6)
    assert fit_shift["acrophase_h"] == pytest.approx((fit["acrophase_h"] + 6.0) % 24.0, abs=1e-6)


def test_a6_rhythm_gate_nocturnal_only_withheld():
    """Nocturnal-only input -> gate withholds insufficient_daytime_temperature."""
    # only hours 22, 23, 0..5 observed each day
    days = []
    for _ in range(7):
        day = [None] * 24
        for h in list(range(0, 6)) + [22, 23]:
            day[h] = 30.0
        days.append(day)
    gate = rhythm_gate(days, CONFIG)
    assert gate["status"] == "withheld"
    assert "insufficient_daytime_temperature" in gate["reasons"]


def test_a6_rhythm_gate_insufficient_days():
    """Fewer than cfg.rhythm_min_days qualified days -> withheld insufficient_days."""
    days = _days(n_days=2, value_fn=lambda d, h: 30.0)
    gate = rhythm_gate(days, CONFIG)
    assert gate["status"] == "withheld"
    assert "insufficient_days" in gate["reasons"]


def test_a6_rhythm_gate_available_with_complete_days():
    days = _days(n_days=7, value_fn=lambda d, h: 30.0 + h)
    gate = rhythm_gate(days, CONFIG)
    assert gate["status"] == "available"
    assert gate["reasons"] == []
    assert gate["qualifying_days"] == 7


def test_a6_is_iv_exact_spec_formulas():
    """IS/IV match the spec's population-moment formulas on a hand-computed case."""
    # value = hour index, identical every day: IS = 1.0 exactly
    days = _days(n_days=5, value_fn=lambda d, h: float(h))
    is_value = interdaily_stability(days)
    iv_value = intradaily_variance(days)
    assert is_value == pytest.approx(1.0, abs=1e-9)
    # spec-02: IV pairs cross midnight (23 -> 0 between consecutive days counts):
    # IV = (n/(n-1)) * (5*23*1 + 4*23^2) / (5*1150) with n = 120
    assert iv_value == pytest.approx(
        (120.0 / 119.0) * (5.0 * 23.0 + 4.0 * 529.0) / (5.0 * 1150.0), abs=1e-9)


def test_a6_is_iv_zero_variance_null():
    """Flat input -> IS/IV null (zero overall variance, never divide by zero)."""
    days = _days(n_days=5, value_fn=lambda d, h: 31.0)
    assert interdaily_stability(days) is None
    assert intradaily_variance(days) is None


def test_a6_is_iv_require_complete_days():
    """IS/IV refuse incomplete days rather than join nonadjacent hours."""
    incomplete = [[30.0] * 23 for _ in range(5)]
    assert interdaily_stability(incomplete) is None
    assert intradaily_variance(incomplete) is None
    assert interdaily_stability([]) is None
    assert intradaily_variance([]) is None


def test_a6_breakpoint_search_thin_sides_not_supported():
    """Fewer than 15 valid minutes per side -> no candidate breakpoint."""
    valid = {m: 30.0 for m in range(-45, -25)}        # 20 minutes: no 15-per-side split
    transition = find_thermal_transition(valid, CONFIG)
    assert transition["supported"] is False
    assert transition["onset_min"] is None
