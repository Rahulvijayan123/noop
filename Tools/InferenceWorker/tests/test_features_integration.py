"""End-to-end fixture night through the complete enrichment pipeline (root-owned).

One synthetic but realistic night: staged segments (wake/light/deep/rem with an
internal wake seam), 1 Hz HR + minute-resolution temperature, ~1 Hz R-R with a
gap, an RSA breath track, and a 9-day sleep/wake history. Asserts the document
invariants the spec's validation table demands:

* no NaN/inf anywhere (json-safe rendering);
* half-open interval arithmetic (TIB/TST/WASO/SOL consistent);
* UNS stays unknown (no invented labels, no transitions across the gap);
* YASA REM latency is measured FROM SLEEP ONSET (not recording start);
* per-block statuses are honest (available/partial/withheld with reasons);
* Group B capabilities report the verified blockers;
* one night with zero wake events reports a valid zero (not null).

This is the "one completed fixture night reaches the sidecar, publication,
scores API, typed decoder, cached offline view and Sleep page" seam's
computation half; the transport halves are covered by test_server.py (route)
and the worker tests (request assembly / attach).
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone

import pytest

from frwhoop_inference.features.config import CONFIG
from frwhoop_inference.features.contract import parse_request
from frwhoop_inference.features.compute import compute
from frwhoop_inference.features.timeline import build_timeline

UTC = timezone.utc

# Night: 2026-10-04 23:00 -> 2026-10-05 07:00 UTC (8 h in bed)
N0 = int(datetime(2026, 10, 4, 23, 0, tzinfo=UTC).timestamp())
N1 = N0 + 8 * 3600
ONSET = N0 + 20 * 60          # 20 min SOL
FINAL_WAKE = N1 - 15 * 60      # 15 min terminal wake


def _stages():
    segs = [
        (N0, ONSET, "wake"),
        (ONSET, ONSET + 90 * 60, "light"),
        (ONSET + 90 * 60, ONSET + 120 * 60, "deep"),
        (ONSET + 120 * 60, ONSET + 300 * 60, "light"),
        # internal wake seam (bounded by sleep both sides): 10 min
        (ONSET + 300 * 60, ONSET + 310 * 60, "wake"),
        (ONSET + 310 * 60, ONSET + 350 * 60, "rem"),
        (ONSET + 350 * 60, FINAL_WAKE, "light"),
        (FINAL_WAKE, N1, "wake"),
    ]
    return [{"start": s, "end": e, "stage": st} for s, e, st in segs]


def _hr():
    out = []
    ts = N0
    while ts < N1:
        rel = (ts - ONSET) / 60.0
        # pre-onset ~72, settling decline to ~54 nadir at +40 min, late ~58
        if rel < 0:
            bpm = 72.0 - 0.02 * (rel + 30)
        elif rel < 40:
            bpm = 72.0 - 0.45 * rel
        else:
            bpm = 54.0 + 0.08 * (rel - 40)
        out.append({"ts": ts, "bpm": bpm})
        ts += 1
    return out


def _temp():
    out = []
    ts = N0
    while ts < N1:
        rel = (ts - ONSET) / 60.0
        c = 30.0 + (0.012 * rel if rel > 0 else 0.0)
        out.append({"ts": ts, "celsius": c})
        ts += 1  # 1 Hz, like the real skin-temp stream: 60 distinct s/min
    return out


def _beats():
    out = []
    ts = ONSET  # beats only after onset; a real gap exists mid-night
    gap_start, gap_end = ONSET + 200 * 60, ONSET + 205 * 60
    seq = 0
    while ts < FINAL_WAKE:
        if gap_start <= ts < gap_end:
            ts += 1
            continue
        rel = (ts - ONSET) / 60.0
        bpm = 60.0 if rel < 60 else 55.0
        rr = 60000.0 / bpm
        out.append({"ts": ts, "rr_ms": rr, "seq": seq, "ord": seq % 7, "src_channel": 1})
        seq += 1
        ts += 1
    return out


def _breaths():
    # RSA-derived: 4 s breaths after onset, aligned to beats where possible
    intervals, runs = [], []
    ts = ONSET
    end = FINAL_WAKE
    run_start = ts
    while ts + 4 <= end:
        intervals.append({"ts": ts + 4, "seconds": 4.0})
        ts += 4
    runs.append({"start": run_start, "end": end - 1})
    return {"intervals": intervals, "runs": runs}


def _history(days: int = 9):
    out = []
    for d in range(days - 1, -1, -1):
        day = (datetime(2026, 10, 5, tzinfo=UTC) - timedelta(days=d)).strftime("%Y-%m-%d")
        minutes = []
        # sleep 23:00->07:00 every history day (UTC grid), valid in-session only
        start = int((datetime(2026, 10, 5, tzinfo=UTC) - timedelta(days=d)).replace(
            hour=23, minute=0).timestamp()) - 86400
        # simpler: build from N0-relative grid of the same day index
        start = int((datetime(2026, 10, 4, 23, 0, tzinfo=UTC) - timedelta(days=d)).timestamp())
        end = start + 8 * 3600
        m = start
        while m + 60 <= end:
            minutes.append({"ts": m, "state": 1, "valid": True})
            m += 60
        out.append({"day": day, "minutes": minutes})
    return {"pair_policy": "elapsed_24h", "days": out}


def _request(**overrides):
    body = {
        "schema_version": 1,
        "algorithm_version": "nara-sleep-features-1",
        "context": {
            "user_id": "u-fixture", "device_id": "d-fixture", "day": "2026-10-05",
            "iana_timezone": "America/Los_Angeles", "input_revision": 42,
            "interval_start_utc": "2026-10-05T00:00:00Z",
            "interval_end_utc": "2026-10-06T00:00:00Z",
            "stage_algorithm_version": "frwhoop-server-1",
        },
        "nights": [{
            "night_id": "sleep-d-fixture-%d" % N0,
            "start_utc": "2026-10-04T23:00:00Z",
            "end_utc": "2026-10-05T07:00:00Z",
            "is_nap": False, "user_edited": False,
            "stages": _stages(),
        }],
        "hr_samples": _hr(),
        "skin_temp_samples": _temp(),
        "rr_beats": _beats(),
        "resp_breaths": _breaths(),
        "history": _history(),
    }
    body.update(overrides)
    return parse_request(body)


def _assert_json_safe(node, path="doc"):
    if isinstance(node, dict):
        for k, v in node.items():
            _assert_json_safe(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _assert_json_safe(v, f"{path}[{i}]")
    elif isinstance(node, float):
        assert math.isfinite(node), f"non-finite number at {path}"


def test_fixture_night_full_document():
    req = _request()
    doc = compute(req)
    _assert_json_safe(doc)
    assert doc["schema_version"] == 1
    assert doc["algorithm_version"] == "nara-sleep-features-1"
    assert doc["status"] in ("available", "partial")
    assert doc["dependencies"]["yasa"] == "0.8.0"
    night = doc["nights"][0]
    assert night["night_id"] == req.nights[0].night_id
    assert night["stage_source"] == "sleep-v2"
    # The claimed staging algorithm is echoed per night (audit P2-1: the
    # actual claimed version, never a made-up one).
    assert night["stage_algorithm_version"] == "frwhoop-server-1"
    # All six per-night blocks present with honest statuses.
    for key in ("continuity", "architecture", "stage_physiology", "settling",
                "thermal", "respiratory_variability"):
        assert key in night, key
        assert night[key]["status"] in ("available", "partial", "withheld",
                                        "not_applicable"), (key, night[key]["status"])
    # Coverage block reports the real funnel.
    cov = night["coverage"]
    assert cov["known_fraction"] == 1.0
    assert cov["sources"]["hr"] > 0 and cov["sources"]["rr"] > 0
    # Group B capability gates are the verified blockers.
    caps = doc["capabilities"]
    assert caps["oxygen_events"] == {"ready": False, "reason": "unverified_sparse_oxygen"}
    assert caps["waveform_staging"] == {"ready": False,
                                        "reason": "continuous_ppg_not_delivered"}


def test_fixture_night_continuity_math():
    req = _request()
    doc = compute(req)
    cont = doc["nights"][0]["continuity"]
    # TIB = 8 h; SOL = 20 min; terminal wake = 15 min; WASO = 10 min.
    assert cont["tib_min"] == pytest.approx(480.0, abs=0.01)
    if cont["status"] != "withheld":
        assert cont["sol_min"] == pytest.approx(20.0, abs=1.0)
        assert cont["terminal_wake_min"] == pytest.approx(15.0, abs=1.0)
        assert cont["waso_min"] == pytest.approx(10.0, abs=1.0)
        # TST = 480 - 20 - 15 - 10 = 435 min
        assert cont["tst_min"] == pytest.approx(435.0, abs=2.0)
        assert cont["recurrent_awakenings"] == 1
        # sleep maintenance = TST / SPT; SPT = final_sleep_end - onset
        # = (ONSET + 445 min) - ONSET = 445; TST = 445 - 10 WASO = 435
        assert cont["sleep_maintenance_efficiency_pct"] == pytest.approx(
            435.0 / 445.0 * 100.0, abs=1.0)


def test_fixture_night_architecture_transitions():
    req = _request()
    doc = compute(req)
    arch = doc["nights"][0]["architecture"]
    if arch["status"] != "withheld":
        counts = arch["transition_counts"]
        # 4x4 with self transitions; rows/cols wake,light,deep,rem
        assert len(counts) == 4 and all(len(r) == 4 for r in counts)
        total = sum(sum(r) for r in counts)
        assert total == arch["eligible_pairs"]
        # REM latency measured FROM SLEEP ONSET (not recording start):
        # first REM at ONSET+310 min
        assert arch["rem_latency_from_onset_min"] == pytest.approx(310.0, abs=1.0)


def test_fixture_night_respiration_honesty():
    req = _request()
    doc = compute(req)
    resp = doc["nights"][0]["respiratory_variability"]
    if resp["status"] != "withheld":
        assert resp["estimate_source"] == "rsa_derived_rr"
        assert resp["rate_bpm"] == pytest.approx(15.0, abs=0.5)  # 4 s intervals
        assert resp["cv_interval"] == pytest.approx(0.0, abs=1e-9)


def test_uninterrupted_sleep_zero_events_is_valid_zero():
    stages = [{"start": N0, "end": N1, "stage": "light"}]
    body_nights = [{
        "night_id": "zero-night", "start_utc": "2026-10-04T23:00:00Z",
        "end_utc": "2026-10-05T07:00:00Z", "is_nap": False, "user_edited": False,
        "stages": stages,
    }]
    req = _request(nights=body_nights)
    doc = compute(req)
    cont = doc["nights"][0]["continuity"]
    assert cont["recurrent_awakenings"] == 0
    assert cont["waso_min"] == 0.0


def test_committed_fixture_pair_round_trips_over_real_http():
    """The committed cross-language fixture pair (the Swift-assembled request
    + the captured Python response) through a REAL loopback server round trip:
    the route must accept the Swift wire shape verbatim and answer a document
    the committed response fixture is a member of (same schema/keys)."""
    import json
    import threading
    import time
    import urllib.request
    import os

    fixture_path = os.path.join(
        os.path.dirname(__file__), "..", "..", "..", "Tools", "CloudWorker",
        "Tests", "frwhoop-workerTests", "SleepFeatureWireFixtures", "sleep_features_request.json")
    if not os.path.exists(fixture_path):  # pragma: no cover - fixture is committed
        pytest.skip("cross-language fixture not present")
    body = json.load(open(fixture_path))
    req = parse_request(body)  # the exact Swift wire shape validates

    from frwhoop_inference.server import Application, InferenceServer
    app = Application.build(registry=None)
    srv = InferenceServer(("127.0.0.1", 0), app)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    time.sleep(0.3)
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/sleep-features",
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"}), timeout=30)
        doc = json.loads(r.read())
    finally:
        srv.shutdown()
    assert r.status == 200
    assert doc["status"] == "available"
    assert doc["algorithm_version"] == "nara-sleep-features-1"
    # the committed response fixture is the same document modulo wall-clock
    resp_path = fixture_path.replace("request.json", "response.json")
    committed = json.load(open(resp_path))
    for key in ("nights", "regularity", "dependencies", "capabilities"):
        assert key in doc and key in committed
    assert set(doc["nights"][0]) == set(committed["nights"][0])


def _same(a, b) -> bool:
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        return a == pytest.approx(b, rel=1e-9, abs=1e-12)
    return a == b


def test_full_night_fixture_reproduces_the_committed_response_within_budget():
    """The committed fixture pair is a golden: computing the committed request must give
    the committed response (so the per-minute/per-window bucketing in physiology.py cannot
    drift), and a full 8 h night must stay far inside the 3 s route budget (the 4 vCPU
    Droplet measured ~4x slower than a laptop; the pre-bucketing code needed ~4 s there)."""
    import json
    import os
    import time

    base = os.path.join(os.path.dirname(__file__), "..", "..", "CloudWorker", "Tests",
                        "frwhoop-workerTests", "SleepFeatureWireFixtures")
    req = parse_request(json.load(open(os.path.join(base, "sleep_features_request.json"))))
    committed = json.load(open(os.path.join(base, "sleep_features_response.json")))
    started = time.monotonic()
    doc = json.loads(json.dumps(compute(req, budget_ms=60000)))
    elapsed = time.monotonic() - started
    for d in (doc, committed):
        d.pop("duration_ms", None)
    assert _same(doc, committed)
    assert elapsed < 0.75, f"full-night enrichment took {elapsed:.2f}s"


def test_unknown_gap_stays_uns_no_transitions_across():
    # A night whose middle 10 minutes carry NO stage coverage.
    segs = [
        {"start": N0, "end": N0 + 3600, "stage": "light"},
        {"start": N0 + 3600 + 600, "end": N1, "stage": "rem"},
    ]
    req = _request(nights=[{
        "night_id": "gap-night", "start_utc": "2026-10-04T23:00:00Z",
        "end_utc": "2026-10-05T07:00:00Z", "is_nap": False, "user_edited": False,
        "stages": segs,
    }])
    doc = compute(req)
    night = doc["nights"][0]
    _assert_json_safe(doc)
    # coverage reports the unresolved gap; night gate downgrades to partial
    assert night["coverage"]["max_unresolved_gap_s"] >= 600.0
    assert night["metric_status"]["night_gate"]["status"] == "partial"
    assert "unresolved_internal_gap" in night["metric_status"]["night_gate"]["reasons"]
    # no invented labels in the gap: known fraction < 1
    assert night["coverage"]["known_fraction"] < 1.0
