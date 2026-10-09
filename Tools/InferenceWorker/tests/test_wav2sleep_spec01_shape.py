"""The adapter reads exactly the PPG segment members Spec 01 pinned.

``wav2sleep_spec01_segment_shape.json`` copies the segment SHAPE from Spec 01's contract text
(docs/model-integration/README.md, "PPG segments sent to sensor.biomarkers.v1", branch
feat/spec01-model-integration-20261007 at 0fd8b94d3; members pinned in ff143411e). The golden
envelope that README names (Tools/CloudWorker/Tests/frwhoop-workerTests/Resources/sensor_biomarkers/
sensor_biomarkers_request_envelope.json) did not exist yet when this was written; set
``FRWHOOP_SPEC01_GOLDEN_ENVELOPE`` to it and ``test_the_spec01_golden_envelope_segments_parse``
checks the real file. Sample values are SYNTHETIC.
"""

import copy
import json
import os

import pytest

from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C
from frwhoop_inference.frwhoop_sleep.wav2sleep.contract import Withhold, parse_night

HERE = os.path.dirname(os.path.abspath(__file__))
SHAPE = json.load(open(os.path.join(HERE, "wav2sleep_spec01_segment_shape.json")))
GOLDEN_ENV = "FRWHOOP_SPEC01_GOLDEN_ENVELOPE"
CTX = {"user_id": "u", "device_id": "d", "iana_timezone": "UTC"}


def _input():
    return copy.deepcopy(SHAPE["input"])


def _refusal(payload):
    with pytest.raises(Withhold) as info:
        parse_night(payload, CTX)
    return info.value.detail


def test_the_fixture_records_where_its_shape_came_from():
    assert SHAPE["spec01_commits"] == ["ff143411e", "0fd8b94d3"]
    assert "docs/model-integration/README.md" in SHAPE["_source"]
    assert "did NOT exist yet" in SHAPE["_source"]
    assert SHAPE["golden_envelope_path"].endswith("sensor_biomarkers_request_envelope.json")
    assert "SYNTHETIC" in SHAPE["_values"]


def test_every_pinned_member_is_present_with_its_pinned_type():
    ppg = SHAPE["input"]["ppg"]
    assert ppg["native_rate_hz"] == C.ANCHORED_V26_NATIVE_RATE_HZ == 25
    for segment in ppg["segments"]:
        assert isinstance(segment["start_unix"], int) and isinstance(segment["duration_s"], int)
        assert len(segment["samples"]) == segment["duration_s"] * ppg["native_rate_hz"]
        assert segment["sample_count_per_second"] == ppg["native_rate_hz"]
        assert isinstance(segment["run_id"], str)
        assert segment["config"]["stable"] is True
        assert isinstance(segment["config"]["identity"], str)
        assert isinstance(segment["config"]["known"], bool)
        clock = segment["clock"]
        assert isinstance(clock["packet_timing_verified"], bool)
        assert clock["samples_per_second"] == ppg["native_rate_hz"]
        assert {"source", "grid", "endpoint"} <= set(clock)


def test_the_shape_parses_into_one_joined_run_at_the_declared_rate():
    night = parse_night(_input(), CTX)
    assert night.native_rate_hz == 25
    assert [(r.run_id, r.seconds, r.samples.size) for r in night.runs] == [("run-a", 4, 100)]
    assert night.run_id_discontinuities == 0
    assert set(night.runs[0].clock_provenance) == {"source", "grid", "endpoint"}


def test_each_interpreted_member_drives_its_documented_refusal():
    payload = _input()
    payload["ppg"]["segments"][1]["clock"]["packet_timing_verified"] = False
    assert _refusal(payload) == "unverified_sample_clock"

    payload = _input()
    payload["ppg"]["segments"][0]["clock"]["samples_per_second"] = 24
    assert _refusal(payload) == "clock_rate_mismatch"
    assert C.WIRE_REASON["clock_rate_mismatch"] == "blocked_input"

    payload = _input()
    del payload["ppg"]["segments"][0]["clock"]          # a segment without clock is legacy
    assert _refusal(payload) == "unverified_sample_clock"

    payload = _input()
    payload["ppg"]["segments"][0]["config"].update({"identity": "unknown", "known": False})
    assert _refusal(payload) == "optical_config_unidentified"


def test_provenance_only_clock_members_never_gate():
    payload = _input()
    for segment in payload["ppg"]["segments"]:
        for key in ("source", "grid", "endpoint"):
            segment["clock"].pop(key)
    assert len(parse_night(payload, CTX).runs) == 1


def test_a_run_id_violation_is_split_and_counted_with_the_spec01_name():
    payload = _input()
    payload["ppg"]["segments"][1]["config"]["identity"] = "srcA=9;drvA=40;rngA=3;offA=0;led=green"
    night = parse_night(payload, CTX)
    assert len(night.runs) == 2 and night.run_id_discontinuities == 1
    assert C.RUN_ID_DISCONTINUITY == "ppg_run_id_discontinuity"


REPO_GOLDEN = os.path.join(HERE, "..", "..", "CloudWorker", "Tests", "frwhoop-workerTests", "Resources",
                           "sensor_biomarkers", "sensor_biomarkers_request_envelope.json")


def test_the_spec01_golden_envelope_segments_parse():
    """Reads the worker's golden envelope: ``$FRWHOOP_SPEC01_GOLDEN_ENVELOPE``, else the repository copy (present once
    Spec 01 is merged; it arrived on Spec 01's branch in 574394cd0)."""
    path = os.environ.get(GOLDEN_ENV) or REPO_GOLDEN
    if not os.path.isfile(path):
        pytest.skip(f"no golden envelope: set {GOLDEN_ENV} or merge Spec 01")
    envelope = json.load(open(path))
    body = envelope.get("body", envelope)
    payload = dict(body["input"])
    context = dict(body.get("context") or {})
    ppg = payload["ppg"]
    for segment in ppg["segments"]:
        assert {"run_id", "config", "clock"} <= set(segment)
        assert segment["clock"]["samples_per_second"] == ppg["native_rate_hz"]
    # The refusal this envelope must get follows from its own values, in the contract's check order: today's worker
    # sends clock.packet_timing_verified false and config.known false (SensorBiomarkerLane.swift), so the night is
    # withheld at the clock gate. Only an envelope with both true may stage.
    first = ppg["segments"][0]
    expected = ("unverified_sample_clock" if first["clock"]["packet_timing_verified"] is not True else
                "optical_config_unidentified" if first["config"].get("known") is not True else None)
    try:
        night = parse_night(payload, {**CTX, **context})
    except Withhold as exc:
        assert exc.detail == expected, (exc.detail, exc.message)
        return
    assert expected is None, f"staged although the envelope should be withheld as {expected}"
    assert night.native_rate_hz in C.SUPPORTED_NATIVE_RATES_HZ
