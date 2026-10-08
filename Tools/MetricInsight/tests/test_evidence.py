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


def test_summary_gives_the_apps_usual_and_its_call_for_the_night():
    summary = ev.metric_summary(week(), RHR, ANCHOR, 90, None)
    assert summary["latest"] == {"day": "2026-10-06", "value": 45}
    assert summary["previous"] == {"day": "2026-10-05", "value": 48, "change": -3}
    # Six earlier nights, all in the last week: the app trusts its week usual (weighted, newest most) and shows its
    # band, 46-54 bpm; 45 bpm is outside it, below ("Off usual"). There is no 60-day usual yet (nights 8+ days old).
    baseline = summary["baseline"]
    assert baseline["usual"] == "week" and baseline["week"]["nights"] == 6 and baseline["usual_value"] == 50
    assert (baseline["usual_low"], baseline["usual_high"]) == (46, 54) and baseline["long"] is None
    assert baseline["change_vs_usual"] == -5 and baseline["direction"] == "down"
    assert baseline["call"] == {"state": "off", "app_label": "Off usual", "shown_usual": "this_week", "low": 46,
                                "high": 54, "outside": ["this_week"], "side": "below"}
    assessment = summary["assessment"]
    assert (assessment["basis"], assessment["state"], assessment["side"]) == ("app_baseline", "off", "below")
    assert "change_detection" not in assessment
    assert summary["context_layer"] == {"available": False, "reason": "no_context_document"}
    assert summary["last_7_nights"] == {"measured": 7, "median": 50, "low": 45, "high": 53}
    assert ev.rounded(50.5, 0) == 51 and ev.rounded(-5.5, 0) == -6 and ev.rounded(0.05, 1) == 0.1


def test_the_60_day_usual_counts_once_the_app_trusts_it():
    rows = {}
    for i in range(20):
        rows[ANCHOR - timedelta(days=20 - i)] = {"resting_hr_bpm": 50 + (i % 3)}
    rows[ANCHOR] = {"resting_hr_bpm": 60}
    summary = ev.metric_summary(scores(rows), RHR, ANCHOR, 90, None)
    # 13 nights 8-20 days old: the 60-day usual is computed, but the app does not trust it yet (13 of its 53
    # nights); the week usual it trusts is the one shown, 47-55 bpm, and 60 bpm is above it.
    base = summary["baseline"]
    assert base["long"]["nights"] == 13 and not base["long"]["shown_by_the_app"] and not base["long"]["established"]
    assert base["usual"] == "week" and (base["usual_low"], base["usual_high"]) == (47, 55)
    assert (summary["assessment"]["state"], summary["assessment"]["side"]) == ("off", "above")
    rows[ANCHOR] = {"resting_hr_bpm": 51}
    assert ev.metric_summary(scores(rows), RHR, ANCHOR, 90, None)["assessment"]["state"] == "in_range"
    # A thin last week (two nights): the 60-day usual is the one the app shows.
    thin = {ANCHOR - timedelta(days=i): {"resting_hr_bpm": 55 + (i % 3)} for i in range(8, 61)}
    thin.update({ANCHOR - timedelta(days=2): {"resting_hr_bpm": 56}, ANCHOR - timedelta(days=5): {"resting_hr_bpm": 55},
                 ANCHOR: {"resting_hr_bpm": 63}})
    summary = ev.metric_summary(scores(thin), RHR, ANCHOR, 90, None)
    assert summary["baseline"]["week"] is None and summary["baseline"]["usual"] == "long"
    assert summary["baseline"]["call"] == {"state": "off", "app_label": "Off usual", "shown_usual": "60_days",
                                           "low": 53, "high": 59, "outside": ["60_days"], "side": "above"}


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
    # The app's own call for the night leads; the context layer's change detection sits next to it.
    assert summary["assessment"]["state"] == "off"
    assert summary["assessment"]["change_detection"] == {
        "state": "persistent_shift", "robust_distance": -2.3,
        "note": "the context layer's change detection against its personal reference"}


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


def test_the_apps_baseline_on_nightly_rows():
    anchor = date(2026, 10, 6)
    rows = {anchor - timedelta(days=i): {"resting_hr_bpm": 60.0 + (i % 5)} for i in range(1, 61)}
    rows[anchor] = {"resting_hr_bpm": 62}
    base = ev.app_baseline(rows, "sleep_rhr", anchor, 0)
    long, week_usual = base["long"], base["week"]
    assert (long["nights"], long["shown_by_the_app"], long["established"]) == (53, True, True)
    assert long["low"] < long["center"] < long["high"]
    assert week_usual["nights"] == 7 and week_usual["shown_by_the_app"]
    assert base["call"]["state"] == "in_range" and base["call"]["shown_usual"] == "this_week" and base["value"] == 62
    # The newest week never enters the 60-day usual, and nights far from an established usual barely train the
    # week usual: it holds near the old level, so tonight's 62 bpm is still in range.
    jumped = dict(rows)
    jumped.update({anchor - timedelta(days=i): {"resting_hr_bpm": 88 + (i * 2) % 5} for i in range(1, 8)})
    moved = ev.app_baseline(jumped, "sleep_rhr", anchor, 0)
    assert moved["long"] == long and moved["week"]["center"] < 70 and moved["call"]["state"] == "in_range"
    # HRV on ln(RMSSD): the band is multiplicative, wider above than below; the week usual is 10 nights.
    hrv = {anchor - timedelta(days=i): {"hrv_rmssd_ms": 60.0 * (1 + 0.04 * ((i * 7) % 11 - 5))} for i in range(1, 61)}
    hrv[anchor] = {"hrv_rmssd_ms": 58.0}
    band = ev.app_baseline(hrv, "sleep_hrv_ln", anchor, 0)
    assert band["long"]["high"] - band["long"]["center"] > band["long"]["center"] - band["long"]["low"]
    assert band["week"]["nights"] == 10
    # Not measured tonight, with a usual the app trusts: "No reading", the band still shown. Too few nights:
    # "Learning", no band. A night outside Layer 1's plausible range (resting HR 30-120) is not a reading.
    missing = dict(rows)
    missing[anchor] = {"resting_hr_bpm": None}
    assert ev.app_baseline(missing, "sleep_rhr", anchor, 0)["call"]["state"] == "no_reading"
    few = {anchor - timedelta(days=i): {"resting_hr_bpm": 60} for i in range(4)}
    assert ev.app_baseline(few, "sleep_rhr", anchor, 0)["call"] == {
        "state": "learning", "app_label": "Learning", "shown_usual": None, "low": None, "high": None, "outside": [],
        "side": None}
    implausible = dict(rows)
    implausible[anchor] = {"resting_hr_bpm": 25}
    assert ev.app_baseline(implausible, "sleep_rhr", anchor, 0)["call"]["state"] == "no_reading"
    # Numbers as the Monitor prints them (ties to even), unlike the half-up rounding of the other figures.
    assert [ev.app_rounded(v, 0) for v in (48.5, 56.5, 49.5, 52.4)] == [48, 56, 50, 52] and ev.rounded(48.5, 0) == 49
    assert ev.app_rounded(33.95, 1) == 34.0 and ev.app_rounded(-0.4, 0) == 0


def test_night_vitals_are_the_home_ring():
    anchor = date(2026, 10, 6)
    rows = {anchor - timedelta(days=i): {"resting_hr_bpm": 52 + (i % 3), "hrv_rmssd_ms": 70.0 + (i % 4),
                                         "skin_temp_c": 33.8 + 0.1 * (i % 3), "resp_rate_bpm": 14.2 + 0.1 * (i % 2),
                                         "spo2_pct": None} for i in range(0, 40)}
    rows[anchor]["resp_rate_bpm"] = 16.5
    document = {"availability": [{"metric": "respiratory_rate", "state": "supported", "reasons": ["rsa_only_estimate"]}]}
    ring = ev.night_vitals(rows, anchor, document)
    by = {v["vital"]: v for v in ring["vitals"]}
    assert [v["app_name"] for v in ring["vitals"]] == ["Resting HR", "HRV", "Wrist temp", "Resp", "SpO₂"]
    assert by["sleep_resp"]["state"] == "off" and by["sleep_resp"]["side"] == "above" and by["sleep_resp"]["estimated"]
    assert by["sleep_rhr"]["state"] == "in_range" and not by["sleep_rhr"]["estimated"]
    assert by["sleep_temp"]["units"] == "°C" and by["sleep_temp"]["value"] == 33.8
    assert by["sleep_spo2_mean"]["state"] == "learning" and by["sleep_spo2_mean"]["value"] is None  # never measured
    counted = [v for v in ring["vitals"] if v["state"] in ("in_range", "off")]
    assert ring["status_line"] == f"{len(counted) - 1} of {len(counted)} in range"
    # The related signals use the same usual and call as the ring.
    hrv = INSIGHT_METRICS["hrv_rmssd"]
    related = ev.related_metrics(scores(rows), hrv, anchor, 90, document)
    rhr = next(s for s in related["signals"] if s["metric"] == "resting_hr")
    assert rhr["app_call"] == "in_range" and (rhr["usual_low"], rhr["usual_high"]) == (by["sleep_rhr"]["usual_low"],
                                                                                     by["sleep_rhr"]["usual_high"])
    assert related["night_vitals"]["status_line"] == ring["status_line"]
    # The night's state in the breakdown carries the same call, in the words the other states use.
    states = ev.state_breakdown(scores(rows), RHR, anchor, None)["states"]
    sleep = next(s for s in states if s["state"] == "sleep")
    assert sleep["app_call"] == "in_range" and sleep["position"] == "within_usual_band" and sleep["usual"]["low"] < 54


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
    assert states["still_awake"]["median_ms"] == 52
    assert list(states) == ["sleep", "still_awake", "after_movement", "while_moving"]


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


def _days(n: int, make) -> dict[date, dict]:
    return {ANCHOR - timedelta(days=n - 1 - i): {"day": ANCHOR - timedelta(days=n - 1 - i), **make(i)} for i in range(n)}


def test_sdnn_spo2_and_calories_compare_with_recent_periods_only():
    rows = _days(31, lambda i: {"hrv_sdnn_ms": 60.0 + (i % 7), "hrv_rmssd_ms": 50.0 + (i % 5),
                                "spo2_candidate_pct": 95.0 + (i % 3), "total_kcal": 2200.0 + 10 * (i % 9)})
    rows[ANCHOR].update(hrv_sdnn_ms=48.0, spo2_candidate_pct=94.0, total_kcal=2600.0)
    for key, value, position in (("hrv_sdnn", 48, "lowest"), ("spo2", 94, "lowest"), ("calories", 2600, "highest")):
        summary = ev.metric_summary(rows, INSIGHT_METRICS[key], ANCHOR, 90, None)
        base = summary["baseline"]
        assert summary["latest"]["value"] == value and summary["assessment"]["basis"] == "recent_periods"
        assert base["call"]["state"] == "no_usual" and base["recent"]["position"] == position, key
        assert base["recent"]["periods"] == 30 and "usual_low" not in base
    assert ev.metric_summary(rows, INSIGHT_METRICS["calories"], ANCHOR, 90, None)["period"] == "day"
    # A 0 kcal day is no value (missing, never zero); a worn day's 0 steps is a real 0.
    rows[ANCHOR].update(total_kcal=0, steps=0)
    assert ev.metric_summary(rows, INSIGHT_METRICS["calories"], ANCHOR, 90, None)["latest"]["day"] != ANCHOR.isoformat()
    assert ev.nights(rows, SIGNALS["steps"], ANCHOR, ANCHOR) == [(ANCHOR, 0.0)]


def test_steps_use_the_apps_steps_usual_and_the_days_gait():
    rows = _days(60, lambda i: {"steps": 8000 + 300 * (i % 7)})
    rows[ANCHOR]["steps"] = 2100
    summary = ev.metric_summary(rows, INSIGHT_METRICS["steps"], ANCHOR, 90, None, rows)
    assert summary["assessment"]["basis"] == "app_baseline" and summary["assessment"]["state"] == "off"
    assert summary["assessment"]["side"] == "below" and summary["baseline"]["usual_low"] > 2100
    zone = ZoneInfo("America/Los_Angeles")
    start = int(datetime(2026, 10, 6, 8, 0, tzinfo=zone).timestamp())
    n = 180  # 15 minutes of 5-second hops
    windows = {"format": "gait-windows-1", "n": n, "w": 10, "h": 5, "s0": start - 5, "ds": [5] * n,
               "gp": [950] * n, "g": [1] * n, "pf": [0] * n, "sp": [140] * n, "cad": [112] * n, "st": [150] * n,
               "rg": [85] * n, "stp": [187] * n}
    utc_day = datetime.fromtimestamp(start, timezone.utc).date()
    days = [{"day": utc_day, "model_version": "eldernet-437a38b", "windows": windows, "n_gait": n, "hop_s": 5,
             "gait": {"cadence_spm": 112}},
            *({"day": ANCHOR - timedelta(days=k), "n_gait": 240, "hop_s": 5, "gait": {"cadence_spm": 100},
               "windows": None} for k in range(2, 6))]
    walking = ev.gait_context(days, ANCHOR, zone)
    assert walking["available"] and walking["walking_min"] == 15 and walking["brisk_min"] == 15
    assert walking["walks"] == 1 and walking["cadence_spm"] == 112 and walking["typical_speed_mps"] == 1.4
    assert walking["longest_walks"][0]["start_local"] == "08:00" and walking["estimated"] is True
    assert walking["previous_days"] == {"days": 4, "walking_min_median": 20, "cadence_spm_median": 100,
                                        "note": walking["previous_days"]["note"]}
    assert ev.gait_context([], ANCHOR, zone)["available"] is False


def test_calorie_split_and_stable_awake_heart_rate_against_the_context_layer():
    rows = _days(20, lambda i: {"total_kcal": 2300.0})
    rows[ANCHOR]["energy"] = {"total_kcal": 2650.4, "resting_kcal": 1610, "active_kcal": 1040.4, "workout_kcal": 380,
                              "light_min": 180, "moderate_min": 55, "high_min": 12, "workouts": 1, "gap_min": 30,
                              "confidence": 0.71}
    activity = ev.activity_context(None, rows, ANCHOR)
    energy = activity["energy"]
    assert (energy["total_kcal"], energy["active_kcal"], energy["workouts"]) == (2650, 1040, 1)
    assert energy["minutes_by_intensity"] == {"light": 180, "moderate": 55, "high": 12}
    assert energy["usual_total_kcal"] == {"median": 2300, "days": 19}
    hr = INSIGHT_METRICS["heart_rate"]
    rows = _days(20, lambda i: {"stable_awake_hr_bpm": 64.0 + (i % 3)})
    rows[ANCHOR]["stable_awake_hr_bpm"] = 71.0
    reference = {"series_key": "heart_rate.stable_awake_5min", "view": "rolling", "status": "ready",
                 "center": 65.0, "signed_difference": 6.0, "robust_z": 2.9, "support_days": 19}
    context = {"comparisons": [reference], "episodes": []}
    summary = ev.metric_summary(rows, hr, ANCHOR, 90, context)
    assert summary["assessment"]["basis"] == "context_layer" and summary["assessment"]["state"] == "in_range"
    assert summary["baseline"]["usual_value"] == 65 and summary["baseline"]["change_vs_usual"] == 6
    shifted = dict(context, episodes=[{"series_key": "heart_rate.stable_awake_5min", "state": "transient_deviation",
                                    "direction": 1, "last_day": ANCHOR.isoformat(), "ongoing": True}])
    call = ev.metric_summary(rows, hr, ANCHOR, 90, shifted)["baseline"]["call"]
    assert (call["state"], call["side"], call["app_label"]) == ("off", "above", "Transient deviation from reference")
    learning = ev.metric_summary(rows, hr, ANCHOR, 90, None)["assessment"]
    assert learning["state"] == "learning" and learning["basis"] == "context_layer"


def test_wrist_temperature_is_the_apps_absolute_usual():
    rows = _days(70, lambda i: {"skin_temp_c": 33.8 + 0.1 * (i % 3), "skin_temp_dev_c": 0.0})
    rows[ANCHOR]["skin_temp_c"] = 35.4
    summary = ev.metric_summary(rows, INSIGHT_METRICS["skin_temp"], ANCHOR, 90, None, rows)
    assert summary["units"] == "°C" and summary["latest"]["value"] == 35.4
    assert summary["assessment"]["basis"] == "app_baseline" and summary["assessment"]["state"] == "off"
    assert summary["assessment"]["side"] == "above"
