"""Producer -> app fixture for the spec-02 sleep-features readback (docs/spec-02/CONTRACT.md §5).

The app's `StrandTests/Spec02SleepFeaturesProducerRoundTripTests` decodes a document this producer
actually computed (Python cannot run inside XCTest), through the app's real snapshot path, and checks
that the Sleep details model shows the persisted values. This test rebuilds that document and asserts
it equals the committed file (golden discipline). Regenerate with
``FRWHOOP_WRITE_APP_FIXTURE=1`` only after checking that a changed output is correct.

The request is the committed full-night wire fixture (the worker's real request shape) with three
additions so that every spec-02 block is AVAILABLE:

* ``rr_beats``: the same beat count and identity, but realistic beat-to-beat variation (a respiratory
  sinus component plus deterministic noise) with wall-clock times that follow the intervals. The
  committed fixture's beats are a constant 1000 ms, so sample entropy is undefined on every segment.
* ``resp_breaths``: varying breath intervals inside the committed runs (the committed ones are a
  constant 4 s, so every interval statistic would be 0).
* ``history.days[].nights``: the published main night of each history day, with short and fragmented
  nights and earlier days that carry nights only (for the next-night rebound observations).
* ``rhythm_history``: 30 days of hourly skin temperature, heart rate and movement (the rhythm test's
  realistic history builder).

``duration_ms`` is the route's wall clock and is not part of the document's content, so it is removed.
"""

from __future__ import annotations

import json
import math
import os
import random
import sys
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(__file__))

import test_features_rhythm as rhythm_fixtures  # noqa: E402

from frwhoop_inference.features.compute import compute  # noqa: E402
from frwhoop_inference.features.contract import parse_request  # noqa: E402

HERE = os.path.dirname(__file__)
REQUEST = os.path.join(HERE, "..", "..", "CloudWorker", "Tests", "frwhoop-workerTests",
                       "SleepFeatureWireFixtures", "sleep_features_request.json")
APP_FIXTURE = os.path.join(HERE, "..", "..", "..", "StrandTests", "Resources",
                           "spec02_sleep_features_producer.json")
LA = "America/Los_Angeles"


def _varied_beats(beats: list[dict]) -> list[dict]:
    """Same count, order, channel and sequence; realistic intervals, timestamps that follow them."""
    rng = random.Random(2026)
    t = float(beats[0]["ts"])
    out = []
    for k, b in enumerate(beats):
        rr = 1000.0 + 45.0 * math.sin(2 * math.pi * k / 4.3) + 25.0 * math.sin(2 * math.pi * k / 37.0) \
            + rng.gauss(0.0, 18.0)
        rr = round(rr, 1)
        out.append({"ord": b["ord"], "rr_ms": rr, "seq": b["seq"], "src_channel": b["src_channel"],
                    "ts": int(t)})
        t += rr / 1000.0
    return out


def _varied_breaths(breaths: dict) -> dict:
    """Breath intervals that vary like real RSA-derived breathing (about 12-18 br/min with a slow drift
    and breath-to-breath jitter) inside the committed runs; each interval ends at its timestamp."""
    rng = random.Random(4242)
    out = []
    for run in breaths["runs"]:
        t = float(run["start"])
        k = 0
        while True:
            sec = 4.0 + 0.45 * math.sin(2 * math.pi * k / 180.0) + rng.gauss(0.0, 0.3)
            sec = round(min(6.5, max(2.6, sec)), 2)
            if t + sec >= run["end"]:
                break
            t += sec
            out.append({"seconds": sec, "ts": int(t)})
            k += 1
    return {"intervals": out, "runs": breaths["runs"]}


def _night_for(day: date, asleep: float, awake: float) -> dict:
    end = int(datetime(day.year, day.month, day.day, 7, tzinfo=ZoneInfo(LA)).timestamp())
    start = end - int((asleep + awake) * 60)
    return {"start": start, "end": end, "is_nap": False, "asleep_min": asleep, "awake_min": awake,
            "efficiency": round(100.0 * asleep / (asleep + awake), 1)}


def _history_with_nights(history: dict, end_day: date) -> dict:
    """30 history days (the 9 committed ones keep their minutes) each with its main night."""
    rng = random.Random(77)
    by_day = {d["day"]: d for d in history["days"]}
    days = []
    for i in range(30, 0, -1):
        d = end_day - timedelta(days=i)
        idx = 30 - i
        asleep = 425.0 + rng.uniform(-15.0, 15.0)
        awake = 30.0 + rng.uniform(-6.0, 6.0)
        if idx in (3, 10, 17, 24):
            asleep -= 95.0  # short night
        if idx in (6, 13, 20, 27):
            awake += 45.0  # fragmented night
        if idx in (4, 11, 18, 25):
            asleep += 35.0  # the night after a short one runs longer here
        entry = dict(by_day.get(d.isoformat(), {"day": d.isoformat(), "minutes": []}))
        entry["nights"] = [_night_for(d, round(asleep, 1), round(awake, 1))]
        entry["timezone"] = LA
        days.append(entry)
    return {"pair_policy": history["pair_policy"], "days": days}


def build_document() -> dict:
    body = json.load(open(REQUEST))
    end_day = date.fromisoformat(body["context"]["day"])
    body["rr_beats"] = _varied_beats(body["rr_beats"])
    body["resp_breaths"] = _varied_breaths(body["resp_breaths"])
    body["history"] = _history_with_nights(body["history"], end_day)
    body["rhythm_history"] = rhythm_fixtures._realistic_history(end_day, n_days=30)
    doc = compute(parse_request(body), budget_ms=60000)
    doc.pop("duration_ms", None)
    return json.loads(json.dumps(doc, allow_nan=False))


def test_committed_app_fixture_matches_the_producer():
    doc = build_document()
    if os.environ.get("FRWHOOP_WRITE_APP_FIXTURE") == "1":
        with open(APP_FIXTURE, "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
            f.write("\n")
    committed = json.load(open(APP_FIXTURE))
    assert doc == committed

    main = next(n for n in doc["nights"] if not n["is_nap"])
    resp = main["respiratory_variability"]
    assert resp["status"] == "available"
    assert resp["interval_distribution"]["status"] == "available"
    assert resp["stable_modulation"]["status"] in ("available", "partial")
    assert resp["supported_range"]["detector_band_bpm"] == [6, 24]
    assert resp["sd_interval_s"] > 0 and resp["interval_distribution"]["iqr_s"] > 0
    assert main["prv_nonlinear"]["status"] == "available", main["prv_nonlinear"]["reasons"]
    assert main["prv_nonlinear"]["segments_used"] >= 3
    rhythm = main["thermal"]["observed_skin_temp_rhythm"]
    assert rhythm["status"] == "available", rhythm["reasons"]
    assert rhythm["phase_relations"]["hr_minus_temp"]["status"] == "available"
    assert doc["rest_activity_rhythm"]["status"] == "available"
    assert doc["rebound"]["status"] == "available", doc["rebound"]["reasons"]
    assert doc["rebound"]["after_short"]["pairs"] >= 3
    assert doc["rebound"]["after_fragmented"]["pairs"] >= 3
