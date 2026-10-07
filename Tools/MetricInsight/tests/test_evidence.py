from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from nara_metric_insight import evidence as ev
from nara_metric_insight.metrics import INSIGHT_METRICS, SIGNALS

RHR = INSIGHT_METRICS["resting_hr"]
ANCHOR = date(2026, 10, 6)


def scores(values: dict[date, dict]) -> dict[date, dict]:
    return {day: {"day": day, **row} for day, row in values.items()}


def week() -> dict[date, dict]:
    rhr = [47, 50, 51, 53, 51, 48, 45]
    hrv = [83.8, 74.1, 66.0, 53.7, None, 78.0, 85.4]
    out = {}
    for i in range(7):
        day = date(2026, 9, 30) + timedelta(days=i)
        out[day] = {"resting_hr_bpm": rhr[i], "hrv_rmssd_ms": hrv[i], "sleep_total_min": 420 + i,
                    "sleep_efficiency": 0.9, "resp_rate_bpm": 14.0, "source_device_id": "d"}
    out[date(2026, 10, 7)] = {"resting_hr_bpm": None, "hrv_rmssd_ms": None}  # a placeholder row, not a night
    return scores(out)


def test_missing_nights_are_none_never_zero():
    rows = scores({date(2026, 10, 1): {"resting_hr_bpm": 0}, date(2026, 10, 2): {"resting_hr_bpm": None},
                   date(2026, 10, 3): {"resting_hr_bpm": 52.4}})
    series = ev.nights(rows, SIGNALS["resting_hr"], date(2026, 9, 30), date(2026, 10, 3))
    assert series == [(date(2026, 9, 30), None), (date(2026, 10, 1), None), (date(2026, 10, 2), None),
                      (date(2026, 10, 3), 52.4)]
    payload = ev.metric_series(rows, RHR, date(2026, 10, 3), 7)
    assert [n["value"] for n in payload["nights"]] == [None] * 6 + [52]
    assert payload["measured_nights"] == 1 and payload["missing_nights"] == 6


def test_summary_without_context_uses_the_labelled_fallback_and_says_history_is_short():
    summary = ev.metric_summary(week(), RHR, ANCHOR, 90, None)
    assert summary["latest"] == {"day": "2026-10-06", "value": 45}
    assert summary["previous"] == {"day": "2026-10-05", "value": 48, "change": -3}
    # median of 47, 48, 50, 51, 51, 53 is 50.5: shown as 51, and the shown change is 45 - 51
    assert summary["baseline"]["nights"] == 6 and summary["baseline"]["median"] == 51
    assert summary["baseline"]["change_vs_median"] == -6 and summary["baseline"]["direction"] == "down"
    assert "usual_range" not in summary["baseline"]  # 6 earlier nights: no usual range yet
    assert summary["assessment"]["basis"] == "insufficient_history"
    assert summary["context_layer"] == {"available": False, "reason": "no_context_document"}
    assert summary["last_7_nights"] == {"measured": 7, "median": 50, "low": 45, "high": 53}
    assert ev.rounded(50.5, 0) == 51 and ev.rounded(-5.5, 0) == -6 and ev.rounded(0.05, 1) == 0.1


def test_personal_range_fallback_with_enough_nights():
    rows = {}
    for i in range(20):
        rows[ANCHOR - timedelta(days=20 - i)] = {"resting_hr_bpm": 50 + (i % 3)}
    rows[ANCHOR] = {"resting_hr_bpm": 60}
    summary = ev.metric_summary(scores(rows), RHR, ANCHOR, 90, None)
    assert summary["baseline"]["usual_range"]["low"] == 50 and summary["baseline"]["usual_range"]["high"] == 52
    assert summary["assessment"]["basis"] == "personal_range"
    assert summary["assessment"]["state"] == "unusual_for_this_person"
    rows[ANCHOR] = {"resting_hr_bpm": 51}
    assert ev.metric_summary(scores(rows), RHR, ANCHOR, 90, None)["assessment"]["state"] == "within_usual_range"


def test_context_layer_rules_match_the_app():
    comparisons = [
        {"series_key": "resting_hr.sleep_night", "view": "frozen", "status": "ready", "signed_difference": 9.0},
        {"series_key": "resting_hr.sleep_night", "view": "recent", "status": "provisional", "signed_difference": 2.0},
        {"series_key": "resting_hr.sleep_night", "view": "rolling", "status": "insufficient"},
    ]
    # A ready comparison with a difference wins over view order (rolling has none).
    assert ev.headline_reference(comparisons)["view"] == "frozen"
    assert ev.headline_reference(comparisons[1:])["view"] == "recent"
    assert ev.headline_reference(comparisons[2:])["view"] == "rolling"
    episodes = [
        {"id": "a", "series_key": "resting_hr.sleep_night", "regime_key": "r", "state": "transient_deviation", "last_day": "2026-10-05"},
        {"id": "b", "series_key": "resting_hr.sleep_night", "regime_key": "r", "state": "persistent_shift", "last_day": "2026-10-01"},
        {"id": "c", "series_key": "resting_hr.sleep_night", "regime_key": "other", "state": "recurring_episode", "last_day": "2026-10-06"},
        {"id": "d", "series_key": "hrv_rmssd.sleep_night", "regime_key": "r", "state": "persistent_shift", "last_day": "2026-10-06"},
    ]
    reference = {"series_key": "resting_hr.sleep_night", "regime_key": "r"}
    assert ev.headline_episode(reference, episodes, RHR)["id"] == "b"  # same regime first, then rank
    assert ev.headline_episode(None, episodes, RHR)["id"] == "b"     # page family, never the HRV series
    document = {"comparisons": [{"series_key": "resting_hr.sleep_night", "view": "rolling", "status": "ready",
                                 "signed_difference": -4.2, "center": 49.1, "robust_z": -2.31, "support_days": 28,
                                 "regime_key": "r"}],
                "episodes": episodes, "status": "available"}
    summary = ev.metric_summary(week(), RHR, ANCHOR, 90, document)
    assert summary["context_layer"]["reference"]["difference"] == -4
    assert summary["assessment"] == {"basis": "context_layer", "state": "persistent_shift", "robust_distance": -2.3,
                                     "note": "the app's own change detection against its personal reference"}


def test_related_signals_carry_estimated_from_the_document():
    document = {"availability": [{"metric": "respiratory_rate", "state": "supported", "reasons": ["rsa_only_estimate"]},
                                 {"metric": "hrv_rmssd", "state": "supported", "reasons": ["rr_kernel_range"]}]}
    related = {s["metric"]: s for s in ev.related_metrics(week(), RHR, ANCHOR, 90, document)["signals"]}
    assert related["resp_rate"]["estimated"] is True
    assert related["hrv_rmssd"]["estimated"] is False
    assert related["hrv_rmssd"]["latest"] == {"day": "2026-10-06", "value": 85}
    assert related["sleep_efficiency"]["latest"]["value"] == 90  # stored as a fraction, shown as a percentage
    assert related["sleep_total"]["estimated"] is True
    assert related["skin_temp_dev"]["latest"] is None and related["skin_temp_dev"]["measured_nights"] == 0


def test_sleep_events_and_quality():
    zone = ZoneInfo("America/Los_Angeles")
    rows = week()
    rows[ANCHOR]["sleep_onset_at"] = datetime(2026, 10, 6, 6, 20, tzinfo=timezone.utc)
    sleep = ev.sleep_context(rows, ANCHOR, zone, 3, None)
    assert sleep["nights"][-1]["onset_local"] == "23:20" and sleep["estimated"] is True
    assert sleep["nights"][-1]["duration_h"] == 7.1
    start = int(datetime(2026, 10, 5, 8, 0, tzinfo=zone).timestamp())
    events = ev.recent_events([
        {"kind": "caffeine", "label": "Coffee", "occurred_start": start, "occurred_end": start + 60,
         "time_precision": "exact", "confirmation": "confirmed", "dose_amount": 95, "dose_unit": "mg"},
        {"kind": "alcohol", "label": "Wine", "occurred_start": start, "occurred_end": start + 60,
         "time_precision": "exact", "confirmation": "candidate"},
    ], {"exposures": {"category_status": [{"kind": "alcohol", "status": "unrecorded"}]}}, zone)
    assert events["events"] == [{"kind": "caffeine", "label": "Coffee", "local_day": "2026-10-05",
                                 "local_time": "08:00", "dose": 95, "dose_unit": "mg"}]
    assert events["unrecorded_categories"] == ["alcohol"]
    quality = ev.data_quality(rows, RHR, ANCHOR, 90, None, None)
    assert quality["measured_nights"] == 7 and quality["missing_nights"] == 83
    assert quality["first_measured"] == "2026-09-30" and quality["longest_gap_nights"] == 0
