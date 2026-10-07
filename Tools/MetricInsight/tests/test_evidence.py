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
    # nights before the first measurement are before tracking began: not listed, not counted as missing
    assert [n["value"] for n in payload["nights"]] == [52]
    assert payload["measured_nights"] == 1 and payload["missing_nights"] == 0
    rows[date(2026, 9, 29)] = {"day": date(2026, 9, 29), "resting_hr_bpm": 50}
    payload = ev.metric_series(rows, RHR, date(2026, 10, 3), 7)
    assert [n["value"] for n in payload["nights"]] == [50, None, None, None, 52]
    assert payload["measured_nights"] == 2 and payload["missing_nights"] == 3


def test_summary_without_context_uses_the_labelled_fallback_and_says_history_is_short():
    summary = ev.metric_summary(week(), RHR, ANCHOR, 90, None)
    assert summary["latest"] == {"day": "2026-10-06", "value": 45}
    assert summary["previous"] == {"day": "2026-10-05", "value": 48, "change": -3}
    # Six earlier nights, all in the last week: Layer 1's 7-night usual (weighted, newest most) is the usual,
    # 50 bpm, so the shown change is 45 - 50; there is no 60-day band yet (it needs nights 8+ days old).
    baseline = summary["baseline"]
    assert baseline["usual"] == "week" and baseline["week"]["nights"] == 6 and baseline["usual_value"] == 50
    assert baseline["change_vs_usual"] == -5 and baseline["direction"] == "down"
    assert baseline["long"] is None and "usual_low" not in baseline
    assert summary["assessment"]["basis"] == "week_usual"
    assert summary["context_layer"] == {"available": False, "reason": "no_context_document"}
    assert summary["last_7_nights"] == {"measured": 7, "median": 50, "low": 45, "high": 53}
    assert ev.rounded(50.5, 0) == 51 and ev.rounded(-5.5, 0) == -6 and ev.rounded(0.05, 1) == 0.1


def test_personal_range_fallback_with_enough_nights():
    rows = {}
    for i in range(20):
        rows[ANCHOR - timedelta(days=20 - i)] = {"resting_hr_bpm": 50 + (i % 3)}
    rows[ANCHOR] = {"resting_hr_bpm": 60}
    summary = ev.metric_summary(scores(rows), RHR, ANCHOR, 90, None)
    # 13 nights 8-20 days old: the 60-day band is shown (not yet established); spread floored at 2 bpm, k = 2
    assert summary["baseline"]["usual"] == "long"
    assert (summary["baseline"]["usual_low"], summary["baseline"]["usual_high"]) == (47, 55)
    assert summary["assessment"] == {"basis": "usual_band", "state": "above_usual_band", "established": False,
                                     "note": summary["assessment"]["note"]}
    rows[ANCHOR] = {"resting_hr_bpm": 51}
    assert ev.metric_summary(scores(rows), RHR, ANCHOR, 90, None)["assessment"]["state"] == "within_usual_band"


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
    assert sleep["nights"][-1]["duration_h"] == 7.1  # 426 min
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
    assert quality["measured_nights"] == 7 and quality["tracked_nights"] == 7 and quality["missing_nights"] == 0
    assert quality["first_measured"] == "2026-09-30" and quality["longest_gap_nights"] == 0


def test_layer1_baseline_rules():
    anchor = date(2026, 10, 6)
    values = {anchor - timedelta(days=i): 60.0 + (i % 5) for i in range(1, 61)}  # 60 nights before the anchor
    base = ev.layer1_baseline(values, anchor, series='resting_hr', decimals=0)
    long = base["long"]
    assert long["from"] == "2026-08-07" and long["to"] == "2026-09-28" and long["nights"] == 53
    assert long["shown"] and not long["stale"]
    assert long["low"] < long["center"] < long["high"]
    assert base["week"]["nights"] == 7 and base["week"]["shown"]
    # the newest week never enters the long copy: a jump in it moves the week copy only
    jumped = dict(values)
    jumped.update({anchor - timedelta(days=i): 90.0 for i in range(1, 8)})
    assert ev.layer1_baseline(jumped, anchor, series='resting_hr', decimals=0)["long"] == long
    assert ev.layer1_baseline(jumped, anchor, series='resting_hr', decimals=0)["week"]["center"] == 90
    # HRV on ln(RMSSD): the band is multiplicative, wider above than below
    spread = {d: 60.0 * (1 + 0.04 * ((i * 7) % 11 - 5)) for i, d in enumerate(sorted(values))}
    hrv = ev.layer1_baseline(spread, anchor, series='hrv_rmssd', decimals=1)
    assert hrv["long"]["high"] - hrv["long"]["center"] > hrv["long"]["center"] - hrv["long"]["low"]
    assert hrv["long"]["spread_floored"] is False
    # whole-bpm nights that mostly repeat: the spread is floored at Layer 1's 2 bpm, so the band stays real
    flat = ev.layer1_baseline({d: 52.0 for d in values}, anchor, series='resting_hr', decimals=0)["long"]
    assert flat["spread_floored"] is True and flat["center"] == 52
    assert flat["low"] <= 49 and flat["high"] >= 55 and 1.5 <= flat["band_width_k"] <= 2.8
    # readiness and staleness
    few = {anchor - timedelta(days=i): 60.0 for i in (8, 9, 10)}
    few_long = ev.layer1_baseline(few, anchor, series='resting_hr', decimals=0)["long"]
    assert few_long["shown"] is False and few_long["established"] is False
    four = {anchor - timedelta(days=i): 60.0 for i in (8, 9, 10, 11)}
    assert ev.layer1_baseline(four, anchor, series='resting_hr', decimals=0)["long"]["shown"] is True
    # outside Layer 1's plausible range (resting HR 30-120) a night is not trained
    implausible = dict(values)
    implausible.update({anchor - timedelta(days=i): 200.0 for i in range(8, 30)})
    assert ev.layer1_baseline(implausible, anchor, series='resting_hr', decimals=0)["long"]["nights"] == 31
    old = {anchor - timedelta(days=i): 60.0 for i in range(20, 50)}
    assert ev.layer1_baseline(old, anchor, series='resting_hr', decimals=0)["long"]["stale"] is True
    assert ev.position(70, long) in ("above_usual_band", "within_usual_band")
    assert ev.position(None, long) == "not_measured" and ev.position(60, {"shown": False}) == "no_usual_yet"


def _snapshot_day(points, slots, sleep):
    return {"daily": {"hrv_series": {"slot_s": 900, "points": points},
                      "activity_context": {"contexts": {"hrv_slots": slots, "sleep_sessions": []}}},
            "sleep": sleep}


def test_hrv_through_the_day_is_grouped_by_what_the_person_was_doing():
    zone = ZoneInfo("America/Los_Angeles")
    night_start = int(datetime(2026, 10, 5, 23, 0, tzinfo=zone).timestamp())
    walk = int(datetime(2026, 10, 5, 18, 0, tzinfo=zone).timestamp())
    points = [[night_start + i * 900, 80.0 + i, 900] for i in range(4)]            # asleep
    points += [[walk, 30.0, 300], [walk + 900, 41.0, 400], [walk + 3600, 52.0, 600]]
    slots = [{"slot_s": walk, "shares": {"walking": 0.7, "stationary": 0.3}, "unknown_share": 0, "recent_activity_s": None,
              "post_activity": False},
             {"slot_s": walk + 900, "shares": {"stationary": 1.0}, "unknown_share": 0, "recent_activity_s": 300,
              "post_activity": True},
             {"slot_s": walk + 3600, "shares": {"stationary": 0.95}, "unknown_share": 0, "recent_activity_s": 3000,
              "post_activity": False}]
    sleep = [{"start_at": "2026-10-06T06:00:00Z", "end_at": "2026-10-06T13:00:00Z", "is_nap": False}]
    result = ev.hrv_slot_states({date(2026, 10, 5): _snapshot_day(points, slots, sleep)}, zone)
    states = {s["state"]: s for s in result["states"]}
    assert states["sleep"]["median_ms"] == 82 and states["sleep"]["readings"] == 4
    assert states["while_moving"]["median_ms"] == 30 and states["while_moving"]["from_local"] == "18:00"
    assert states["after_movement"]["median_ms"] == 41
    assert states["calm_awake"]["median_ms"] == 52
    assert list(states) == ["sleep", "calm_awake", "after_movement", "while_moving"]


def test_movement_patterns_from_activity_runs_and_the_gap_before_sleep():
    zone = ZoneInfo("America/Los_Angeles")
    t = lambda h, m=0: int(datetime(2026, 10, 5, h, m, tzinfo=zone).timestamp())  # noqa: E731
    runs = [{"start_ts": t(18), "end_ts": t(18, 20), "activity_class": "walking", "source_rank": 1},
            {"start_ts": t(18, 21), "end_ts": t(18, 40), "activity_class": "walking", "source_rank": 1},  # merged
            {"start_ts": t(19), "end_ts": t(19, 30), "activity_class": "sitting", "source_rank": 1},
            {"start_ts": t(21), "end_ts": t(21, 25), "activity_class": "cycling", "source_rank": 1}]
    scores = {date(2026, 10, 6): {"sleep_onset_at": datetime(2026, 10, 5, 23, 0, tzinfo=zone)}}
    out = ev.movement_patterns(None, None, scores, date(2026, 10, 6), zone, runs)
    assert out["before_the_night"] == [{"kind": "walking", "start_local": "18:00", "end_local": "18:40", "minutes": 40},
                                       {"kind": "cycling", "start_local": "21:00", "end_local": "21:25", "minutes": 25}]
    assert out["minutes_by_kind_before_the_night"] == {"walking": 40, "cycling": 25}
    assert out["last_movement_before_sleep_min"] == 95 and out["estimated"] is True


def test_logged_medications_are_never_named():
    zone = ZoneInfo("UTC")
    start = int(datetime(2026, 10, 5, 8, 0, tzinfo=zone).timestamp())
    events = ev.recent_events([{"kind": "medication", "label": "Brand-name pill", "occurred_start": start,
                                "occurred_end": start + 60, "time_precision": "exact", "confirmation": "confirmed",
                                "dose_amount": 20, "dose_unit": "mg"}], None, zone)
    assert events["events"][0]["label"] is None and "dose" not in events["events"][0]
    assert "never name it" in events["events"][0]["note"]
