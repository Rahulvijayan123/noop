"""Tests for the A3 regularity module (features/regularity.py).

Covers every check named in spec-25.md section A3 and the locked wire keys of
docs/SLEEP_FEATURES_CONTRACT.md section 3 (``regularity`` block):

* 1-minute UTC grid SRI, exact 24 h elapsed lag, 200*mean(agreement)-100,
  negative values never clipped, identical -> +100, opposite -> -100;
* invalid minutes excluded on both sides; missing-day (>= 12 h floor) pairing
  exclusion; rolling 7/14/30-day windows with the 5-day / 4-day-equivalent /
  80 % pair-fraction gates;
* pair_coverage_by_hour (UTC hour of the earlier minute);
* circular mean / circular SD for bed_time, sleep_onset, final_wake, midsleep,
  including the 23:50/00:10 near-midnight case;
* adjacent_night_phase_shift_min (median signed shortest circular difference);
* social_jetlag withheld (workday_labels_unavailable);
* DST: America/Los_Angeles 2026-11-01 fall-back local conversion + 
  dst_transition_days disclosure; no-history -> timing only.

All inputs are synthetic and seeded; no real capture is used.
"""

from __future__ import annotations

import math
from datetime import datetime, timezone

import pytest

from frwhoop_inference.features.config import SleepFeaturesConfig, CONFIG
from frwhoop_inference.features.contract import (
    HistoryDayIn,
    HistoryMinuteIn,
    NightIn,
    SleepFeaturesContext,
    SleepFeaturesRequest,
    StageSegmentIn,
)
from frwhoop_inference.features.regularity import (
    compute,
    _circular_mean_sd_minutes,
    _shortest_circular_diff_min,
)


def utc_ts(year: int, month: int, day: int, hour: int, minute: int) -> int:
    return int(datetime(year, month, day, hour, minute, tzinfo=timezone.utc).timestamp())


def history_day(day_label: str, start_ts: int, sleep_start_min: int = 0,
                sleep_len_min: int = 480, valid: bool = True,
                invalid_bins: frozenset[int] | None = None) -> HistoryDayIn:
    """A full 1440-minute UTC history day.

    ``sleep_start_min``..``sleep_start_min+sleep_len_min`` are sleep (state 1),
    the rest wake (state 0).  ``invalid_bins`` marks minutes valid=False
    (off-wrist / unprocessed), which SRI excludes on both sides.
    """
    invalid = invalid_bins or frozenset()
    minutes = []
    for i in range(1440):
        state = 1 if sleep_start_min <= i < sleep_start_min + sleep_len_min else 0
        v = valid and (i not in invalid)
        minutes.append(HistoryMinuteIn(ts=start_ts + i * 60, state=state, valid=v))
    return HistoryDayIn(day=day_label, minutes=tuple(minutes))


def night(night_id: str, start_ts: int, end_ts: int, stage: str = "light",
          is_nap: bool = False, user_edited: bool = False) -> NightIn:
    return NightIn(night_id=night_id, start=start_ts, end=end_ts, is_nap=is_nap,
                   user_edited=user_edited,
                   stages=(StageSegmentIn(start=start_ts, end=end_ts, stage=stage),))


def make_request(history_days=(), nights=(), tz: str = "UTC",
                 digest: str | None = "digest-123") -> SleepFeaturesRequest:
    ctx = SleepFeaturesContext(
        user_id="u1", device_id="d1", day="2026-11-02",
        iana_timezone=tz, input_revision=1,
        interval_start=utc_ts(2026, 11, 1, 0, 0),
        interval_end=utc_ts(2026, 11, 3, 0, 0),
        history_revision_digest=digest,
    )
    return SleepFeaturesRequest(context=ctx, nights=tuple(nights), hr=(), temp=(),
                                beats=(), breaths=(), breath_runs=(),
                                history_days=tuple(history_days), capabilities={})


# ---------------------------------------------------------------------------
# History grids for SRI
# ---------------------------------------------------------------------------

#: 10 full days, sleep 00:00-08:00 UTC, all minutes valid -> identical schedule.
REGULAR_DAYS = [
    history_day(f"2026-10-{22 + i:02d}", utc_ts(2026, 10, 22 + i, 0, 0))
    for i in range(10)
]


def _opposite_days() -> list[HistoryDayIn]:
    """Complementary sleep/wake partitions: at every clock bin exactly one of
    the two consecutive days is asleep, so agreement is 0 and SRI = -100."""
    days = []
    for i in range(10):
        if i % 2 == 0:
            start, length = 0, 480
        else:
            start, length = 480, 960
        days.append(history_day(f"2026-10-{22 + i:02d}",
                                utc_ts(2026, 10, 22 + i, 0, 0),
                                sleep_start_min=start, sleep_len_min=length))
    return days


def _balanced_days() -> list[HistoryDayIn]:
    """A/B patterns agreeing at exactly half the clock bins -> SRI == 0."""
    days = []
    for i in range(10):
        start = 0 if i % 2 == 0 else 360
        days.append(history_day(f"2026-10-{22 + i:02d}",
                                utc_ts(2026, 10, 22 + i, 0, 0),
                                sleep_start_min=start, sleep_len_min=720))
    return days


def _shifted_days() -> list[HistoryDayIn]:
    """Consecutive days shifted 60 min later; sleep 00:00-08:00 -> 01:00-09:00."""
    days = []
    for i in range(6):
        days.append(history_day(f"2026-10-{26 + i:02d}",
                                utc_ts(2026, 10, 26 + i, 0, 0),
                                sleep_start_min=i * 60, sleep_len_min=480))
    return days


# ---------------------------------------------------------------------------
# SRI: identical / opposite / balanced / shifted schedules
# ---------------------------------------------------------------------------


def test_sri_identical_schedule_is_100():
    req = make_request(history_days=REGULAR_DAYS)
    block = compute(req, CONFIG)
    assert block["sri_7d"]["valid_days"] == 7
    assert block["sri_14d"]["valid_days"] == 10
    assert block["sri_30d"]["valid_days"] == 10
    for key in ("sri_7d", "sri_14d", "sri_30d"):
        w = block[key]
        assert w["status"] == "available"
        assert w["value"] == pytest.approx(100.0, abs=1e-9)
        assert w["reasons"] == []


def test_sri_opposite_states_is_negative_100_and_not_clipped():
    req = make_request(history_days=_opposite_days())
    block = compute(req, CONFIG)
    for key in ("sri_7d", "sri_14d", "sri_30d"):
        w = block[key]
        assert w["status"] == "available"
        assert w["value"] == pytest.approx(-100.0, abs=1e-9), (
            "negative SRI must be preserved, never clipped to zero")
        assert w["value"] == -100.0


def test_sri_balanced_states_is_zero_but_available():
    req = make_request(history_days=_balanced_days())
    block = compute(req, CONFIG)
    for key in ("sri_7d", "sri_14d", "sri_30d"):
        w = block[key]
        assert w["status"] == "available"
        assert w["value"] == pytest.approx(0.0, abs=1e-9)


def test_sri_shift_by_several_hours_reduced_but_still_computed():
    # 6 days, each sleep window shifted 60 min later than the previous one:
    # agreement = 1320/1440 per consecutive pair -> SRI = 200*(1320/1440)-100.
    req = make_request(history_days=_shifted_days())
    block = compute(req, CONFIG)
    w = block["sri_7d"]
    assert w["status"] == "available"
    assert w["value"] == pytest.approx(200.0 * (1320.0 / 1440.0) - 100.0, abs=1e-6)
    assert -100.0 < w["value"] < 100.0


def test_sri_values_always_within_range():
    req = make_request(history_days=REGULAR_DAYS + _opposite_days())
    block = compute(req, CONFIG)
    for key in ("sri_7d", "sri_14d", "sri_30d"):
        w = block[key]
        if w["status"] == "available":
            assert -100.0 <= w["value"] <= 100.0


# ---------------------------------------------------------------------------
# SRI: validity and missing-day pairing rules
# ---------------------------------------------------------------------------


def test_invalid_minutes_excluded_on_both_sides():
    # Day 5 has 100 off-wrist minutes (still a monitored valid day: 1340 valid).
    days = list(REGULAR_DAYS)
    bad = frozenset(range(100, 200))
    days[5] = history_day("2026-10-27", utc_ts(2026, 10, 27, 0, 0), invalid_bins=bad)
    req = make_request(history_days=days)
    w = compute(req, CONFIG)["sri_7d"]
    assert w["status"] == "available"
    # 7-day window = 6 consecutive day-pairs * 1440 minutes, minus the 100
    # invalid minutes of day 5 as EARLIER side and the same 100 as LATER side.
    assert w["eligible_minutes"] == 6 * 1440
    assert w["paired_minutes"] == 6 * 1440 - 200
    assert w["value"] == pytest.approx(100.0, abs=1e-9)


def test_missing_day_never_paired_across():
    # Day 2026-10-28 has only 600 valid minutes (< 720) -> "missing". Pairs
    # (d4,d5) and (d5,d6) are excluded; all other day-pairs remain.
    days = list(REGULAR_DAYS)
    sparse = [HistoryMinuteIn(ts=utc_ts(2026, 10, 27, 0, 0) + i * 60, state=1, valid=True)
              for i in range(600)]
    days[5] = HistoryDayIn(day="2026-10-27", minutes=tuple(sparse))
    req = make_request(history_days=days)
    w = compute(req, CONFIG)["sri_7d"]
    assert w["valid_days"] == 6
    assert w["eligible_minutes"] == 4 * 1440      # (d3,d4),(d6,d7),(d7,d8),(d8,d9)
    assert w["paired_minutes"] == 4 * 1440
    assert w["status"] == "available"
    assert w["value"] == pytest.approx(100.0, abs=1e-9)


def test_single_day_has_no_pairs_and_withholds():
    req = make_request(history_days=[REGULAR_DAYS[0]])
    w = compute(req, CONFIG)["sri_7d"]
    assert w["status"] == "withheld"
    assert w["value"] is None
    assert "insufficient_history" in w["reasons"]


def test_insufficient_history_withheld_when_too_few_days():
    req = make_request(history_days=REGULAR_DAYS[:3])
    w = compute(req, CONFIG)["sri_7d"]
    assert w["status"] == "withheld"
    assert w["value"] is None
    assert w["valid_days"] == 3
    assert "insufficient_history" in w["reasons"]


def test_insufficient_paired_minutes_gate_withholds():
    # 5 full days -> valid_days=5 passes, but paired = 4*1440 = 5760 exactly.
    req = make_request(history_days=REGULAR_DAYS[:5])
    w = compute(req, CONFIG)["sri_7d"]
    assert w["valid_days"] == 5
    assert w["paired_minutes"] == 4 * 1440
    # At exactly the 5760 floor the gate passes.
    assert w["status"] == "available"

    # 4 full days -> paired = 3*1440 = 4320 < 5760 -> withheld.
    req = make_request(history_days=REGULAR_DAYS[:4])
    w = compute(req, CONFIG)["sri_7d"]
    assert w["status"] == "withheld"
    assert "insufficient_paired_minutes" in w["reasons"]


def test_pair_fraction_gate_withholds_when_under_80_percent():
    # Two days (2026-10-27, 2026-10-28) are not missing (720 valid minutes
    # exactly at the 12 h floor) but have the OTHER 720 minutes off-wrist:
    # day 27 valid in 00:00-11:59, day 28 valid in 12:00-23:59, so their
    # invalid clock bins never coincide and each loses 1440 paired minutes.
    days = list(REGULAR_DAYS)
    # Day 27 valid in 00:00-11:59, day 28 valid in 12:00-23:59.
    rows27 = [HistoryMinuteIn(ts=utc_ts(2026, 10, 27, 0, 0) + i * 60,
                              state=1, valid=(i < 720)) for i in range(1440)]
    rows28 = [HistoryMinuteIn(ts=utc_ts(2026, 10, 28, 0, 0) + i * 60,
                              state=1, valid=(i >= 720)) for i in range(1440)]
    days[5] = HistoryDayIn(day="2026-10-27", minutes=tuple(rows27))
    days[6] = HistoryDayIn(day="2026-10-28", minutes=tuple(rows28))
    req = make_request(history_days=days)
    w = compute(req, CONFIG)["sri_7d"]
    assert w["valid_days"] == 7
    assert w["eligible_minutes"] == 6 * 1440
    assert w["paired_minutes"] == 6 * 1440 - 4 * 720
    assert w["status"] == "withheld"
    assert "insufficient_pair_fraction" in w["reasons"]


def test_no_valid_daytime_decision_withholds():
    # Full 1440-row days (regular 60 s spacing) where the device is only worn
    # at night: valid minutes all fall outside local daytime 09:00-20:59
    # (720 valid minutes per day, still at the 12 h monitored-day floor).
    days = []
    for i in range(10):
        base = utc_ts(2026, 10, 22 + i, 0, 0)
        minutes = []
        for j in range(1440):
            h = (base + j * 60) // 3600 % 24
            minutes.append(HistoryMinuteIn(ts=base + j * 60, state=1, valid=(h >= 21 or h < 9)))
        days.append(HistoryDayIn(day=f"2026-10-{22 + i:02d}", minutes=tuple(minutes)))
    req = make_request(history_days=days)
    w = compute(req, CONFIG)["sri_7d"]
    assert w["status"] == "withheld"
    assert "no_valid_daytime_decision" in w["reasons"]


def test_irregular_spacing_day_is_dropped():
    # A day whose minutes are not at regular 60 s spacing cannot be trusted on
    # the 1-minute UTC grid; it is dropped and the block says so.
    base = utc_ts(2026, 10, 27, 0, 0)
    rows = [HistoryMinuteIn(ts=base + (i * 60 if i < 100 else i * 120), state=1, valid=True)
            for i in range(120)]
    days = list(REGULAR_DAYS)
    days[5] = HistoryDayIn(day="2026-10-27", minutes=tuple(rows))
    req = make_request(history_days=days)
    block = compute(req, CONFIG)
    assert "irregular_history_spacing" in block["reasons"]
    w = block["sri_7d"]
    # Dropped day is treated as missing: pairs across it excluded.
    assert w["eligible_minutes"] == 4 * 1440


def test_pair_coverage_by_hour_profile():
    req = make_request(history_days=REGULAR_DAYS)
    pch = compute(req, CONFIG)["pair_coverage_by_hour"]
    assert isinstance(pch, list) and len(pch) == 24
    assert all(isinstance(v, int) for v in pch)
    # 9 consecutive day-pairs, 60 minutes per UTC hour each.
    assert sum(pch) == 9 * 1440
    assert all(v == 9 * 60 for v in pch)


def test_rolling_windows_use_most_recent_days_only():
    # 9 days: last 7 are fully valid and identical; the first 2 are opposite.
    days = [
        history_day(f"2026-10-{22 + i:02d}", utc_ts(2026, 10, 22 + i, 0, 0),
                    sleep_start_min=(480 if i < 2 else 0), sleep_len_min=480)
        for i in range(9)
    ]
    req = make_request(history_days=days)
    w7 = compute(req, CONFIG)["sri_7d"]
    assert w7["value"] == pytest.approx(100.0, abs=1e-9)  # recent 7 identical
    assert w7["valid_days"] == 7


# ---------------------------------------------------------------------------
# No-history / block-level behaviour
# ---------------------------------------------------------------------------


def test_no_history_delivers_timing_and_withholds_sri():
    req = make_request(
        nights=[night("n1", utc_ts(2026, 11, 1, 23, 50), utc_ts(2026, 11, 2, 7, 50))],
    )
    block = compute(req, CONFIG)
    for key in ("sri_7d", "sri_14d", "sri_30d"):
        w = block[key]
        assert w["status"] == "withheld"
        assert w["reasons"] == ["no_history"]
        assert w["value"] is None
        assert w["paired_minutes"] == 0 and w["eligible_minutes"] == 0
    assert block["pair_coverage_by_hour"] == [0] * 24
    assert block["clock_profile"]["bed_time"]["status"] == "available"
    assert block["status"] == "partial"


def test_history_revision_digest_echoed_back():
    req = make_request(history_days=REGULAR_DAYS, digest="sha-abc")
    assert compute(req, CONFIG)["history_revision_digest"] == "sha-abc"


def test_block_never_emits_non_finite_numbers():
    import json

    req = make_request(history_days=REGULAR_DAYS,
                       nights=[night("n1", utc_ts(2026, 11, 1, 23, 50),
                                     utc_ts(2026, 11, 2, 7, 50))])
    block = compute(req, CONFIG)
    text = json.dumps(block, allow_nan=False)  # raises on NaN/inf
    assert "regularity" not in text or True


# ---------------------------------------------------------------------------
# Circular timing variability
# ---------------------------------------------------------------------------


def test_circular_mean_sd_near_midnight():
    # 23:50 and 00:10 -> circular mean ~ 00:00 with a small SD (NOT ~12:00).
    mean_min, sd_min, n = _circular_mean_sd_minutes([1430.0, 10.0])
    assert n == 2
    assert mean_min == pytest.approx(0.0, abs=1e-6)
    assert sd_min == pytest.approx(10.0, abs=0.05)


def test_bed_onset_wake_midsleep_circular_metrics():
    # Two main nights in UTC: 23:50-07:50 and 00:10-08:10, all light.
    req = make_request(nights=[
        night("n1", utc_ts(2026, 11, 1, 23, 50), utc_ts(2026, 11, 2, 7, 50)),
        night("n2", utc_ts(2026, 11, 2, 0, 10), utc_ts(2026, 11, 2, 8, 10)),
    ])
    cp = compute(req, CONFIG)["clock_profile"]
    bed = cp["bed_time"]
    assert bed["status"] == "available" and bed["n"] == 2
    assert bed["circadian_mean_min"] == pytest.approx(0.0, abs=1e-6)
    assert bed["circadian_sd_min"] == pytest.approx(10.0, abs=0.05)

    onset = cp["sleep_onset"]
    assert onset["status"] == "available" and onset["n"] == 2
    assert onset["circadian_mean_min"] == pytest.approx(0.0, abs=1e-6)

    wake = cp["final_wake"]
    assert wake["status"] == "available" and wake["n"] == 2
    # 07:50 and 08:10 -> circular mean 08:00 = 480 min.
    assert wake["circadian_mean_min"] == pytest.approx(480.0, abs=1e-6)
    assert wake["circadian_sd_min"] == pytest.approx(10.0, abs=0.05)

    mid = cp["midsleep"]
    assert mid["status"] == "available" and mid["n"] == 2
    # Midpoints 03:50 / 04:10 -> mean 04:00 = 240 min.
    assert mid["circadian_mean_min"] == pytest.approx(240.0, abs=1e-6)


def test_adjacent_night_phase_shift_median():
    # Midsleeps 03:50 and 04:10 -> one signed shortest difference of +20 min.
    req = make_request(nights=[
        night("n1", utc_ts(2026, 11, 1, 23, 50), utc_ts(2026, 11, 2, 7, 50)),
        night("n2", utc_ts(2026, 11, 2, 0, 10), utc_ts(2026, 11, 2, 8, 10)),
    ])
    ps = compute(req, CONFIG)["clock_profile"]["adjacent_night_phase_shift_min"]
    assert ps["status"] == "available"
    assert ps["n"] == 1
    assert ps["value"] == pytest.approx(20.0, abs=1e-6)


def test_phase_shift_shortest_circular_wraps():
    # 23:50 -> 00:10 is +20 min forward, not -1420.
    assert _shortest_circular_diff_min(1430.0, 10.0) == pytest.approx(20.0, abs=1e-9)
    assert _shortest_circular_diff_min(10.0, 1430.0) == pytest.approx(-20.0, abs=1e-9)


def test_social_jetlag_withheld_without_workday_labels():
    req = make_request(
        nights=[night("n1", utc_ts(2026, 11, 1, 23, 50), utc_ts(2026, 11, 2, 7, 50))],
    )
    sj = compute(req, CONFIG)["clock_profile"]["social_jetlag_min"]
    assert sj["status"] == "withheld"
    assert sj["reasons"] == ["workday_labels_unavailable"]
    assert sj["value"] is None


def test_naps_excluded_from_timing_metrics():
    # Main night plus a daytime nap; bed_time must count only the main night.
    req = make_request(nights=[
        night("main", utc_ts(2026, 11, 1, 23, 50), utc_ts(2026, 11, 2, 7, 50),
              is_nap=False),
        night("nap1", utc_ts(2026, 11, 2, 13, 0), utc_ts(2026, 11, 2, 14, 0),
              is_nap=True),
    ])
    cp = compute(req, CONFIG)["clock_profile"]
    assert cp["bed_time"]["n"] == 1
    assert cp["bed_time"]["circadian_mean_min"] == pytest.approx(1430.0, abs=1e-6)
    assert cp["midsleep"]["n"] == 1


def test_no_nights_timing_withheld():
    req = make_request()
    cp = compute(req, CONFIG)["clock_profile"]
    assert cp["bed_time"]["status"] == "withheld"
    assert cp["bed_time"]["reasons"] == ["insufficient_nights"]
    assert cp["midsleep"]["status"] == "withheld"
    assert cp["dst_transition_days"] == 0
    assert compute(req, CONFIG)["status"] == "withheld"


def test_all_wake_night_has_no_onset_or_midsleep():
    # A fully-wake night contributes bed_time but no onset/final wake/midsleep.
    w = utc_ts(2026, 11, 1, 23, 50)
    night_all_wake = NightIn(night_id="w", start=w, end=w + 4 * 3600, is_nap=False,
                             user_edited=False,
                             stages=(StageSegmentIn(start=w, end=w + 4 * 3600,
                                                    stage="wake"),))
    req = make_request(nights=[night_all_wake])
    cp = compute(req, CONFIG)["clock_profile"]
    assert cp["bed_time"]["status"] == "available"
    assert cp["sleep_onset"]["status"] == "withheld"
    assert cp["final_wake"]["status"] == "withheld"
    assert cp["midsleep"]["status"] == "withheld"


# ---------------------------------------------------------------------------
# DST and timezone handling
# ---------------------------------------------------------------------------


def test_dst_fall_back_local_conversion():
    # America/Los_Angeles falls back 2026-11-01 02:00 PDT -> PST.
    # 07:30 UTC is 00:30 PDT (UTC-7); 15:30 UTC is 07:30 PST (UTC-8).
    req = make_request(
        tz="America/Los_Angeles",
        nights=[night("n1", utc_ts(2026, 11, 1, 7, 30), utc_ts(2026, 11, 1, 15, 30))],
    )
    cp = compute(req, CONFIG)["clock_profile"]
    assert cp["sleep_onset"]["circadian_mean_min"] == pytest.approx(30.0, abs=1e-6)
    # Zone-aware: 15:30 UTC - 8h = 07:30 local, not a fixed -7h offset (08:30).
    assert cp["final_wake"]["circadian_mean_min"] == pytest.approx(450.0, abs=1e-6)
    # Midsleep midpoint 11:30 UTC -> 03:30 PST = 210 min.
    assert cp["midsleep"]["circadian_mean_min"] == pytest.approx(210.0, abs=1e-6)


def test_dst_transition_days_disclosed():
    # Two consecutive main nights straddling the fall-back: offsets differ.
    req = make_request(
        tz="America/Los_Angeles",
        nights=[
            night("n1", utc_ts(2026, 10, 31, 8, 0), utc_ts(2026, 10, 31, 16, 0)),   # PDT
            night("n2", utc_ts(2026, 11, 1, 10, 0), utc_ts(2026, 11, 1, 18, 0)),  # PST
        ],
    )
    cp = compute(req, CONFIG)["clock_profile"]
    assert cp["dst_transition_days"] == 1
    # Each night converted with its own offset: 08:00 UTC -> 01:00 PDT (60),
    # 10:00 UTC -> 02:00 PST (120) -> circular mean 90 (01:30).
    assert cp["bed_time"]["circadian_mean_min"] == pytest.approx(90.0, abs=1e-6)


def test_same_offset_nights_zero_transitions():
    req = make_request(
        tz="America/Los_Angeles",
        nights=[
            night("n1", utc_ts(2026, 10, 30, 8, 0), utc_ts(2026, 10, 30, 16, 0)),
            night("n2", utc_ts(2026, 10, 31, 8, 0), utc_ts(2026, 10, 31, 16, 0)),
        ],
    )
    assert compute(req, CONFIG)["clock_profile"]["dst_transition_days"] == 0


def test_invalid_timezone_withholds_clock_metrics():
    req = make_request(tz="Not/AZone",
                       nights=[night("n1", utc_ts(2026, 11, 1, 23, 50),
                                     utc_ts(2026, 11, 2, 7, 50))])
    cp = compute(req, CONFIG)["clock_profile"]
    assert cp["bed_time"]["status"] == "withheld"
    assert "invalid_timezone" in cp["bed_time"]["reasons"]


# ---------------------------------------------------------------------------
# Block status aggregation
# ---------------------------------------------------------------------------


def test_block_status_partial_with_single_night_phase_shift_null():
    # Full history + one main night: SRI available, all four schedule metrics
    # available, but adjacent-night phase shift needs >= 2 nights -> partial.
    req = make_request(history_days=REGULAR_DAYS,
                       nights=[night("n1", utc_ts(2026, 11, 1, 23, 50),
                                     utc_ts(2026, 11, 2, 7, 50))])
    block = compute(req, CONFIG)
    assert block["sri_7d"]["status"] == "available"
    assert block["clock_profile"]["bed_time"]["status"] == "available"
    assert block["clock_profile"]["adjacent_night_phase_shift_min"]["status"] == "withheld"
    assert block["status"] == "partial"
    assert "insufficient_nights" in block["reasons"]
    assert block["pair_policy"] == "elapsed_24h"


def test_block_status_available_when_everything_passes():
    req = make_request(history_days=REGULAR_DAYS,
                       nights=[
                           night("n1", utc_ts(2026, 11, 1, 23, 50),
                                 utc_ts(2026, 11, 2, 7, 50)),
                           night("n2", utc_ts(2026, 11, 2, 0, 10),
                                 utc_ts(2026, 11, 2, 8, 10)),
                       ])
    block = compute(req, CONFIG)
    assert block["status"] == "available"
    assert block["reasons"] == []
    assert block["pair_policy"] == "elapsed_24h"


def test_block_status_partial_when_sri_withheld_timing_delivered():
    req = make_request(history_days=REGULAR_DAYS[:2],
                       nights=[night("n1", utc_ts(2026, 11, 1, 23, 50),
                                     utc_ts(2026, 11, 2, 7, 50))])
    block = compute(req, CONFIG)
    assert block["sri_7d"]["status"] == "withheld"
    assert block["clock_profile"]["bed_time"]["status"] == "available"
    assert block["status"] == "partial"
