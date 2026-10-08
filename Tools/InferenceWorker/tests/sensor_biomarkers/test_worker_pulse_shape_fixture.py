"""The pulse_shape stages the worker's day merge is tested against are this sidecar's real output.

Two hourly requests of real-shaped v26 segments (the golden request envelope's ``config`` and
``clock`` members: identity ``unknown``, clock unverified, 25 Hz) go through the real provider; the
``pulse_shape`` stage of each is what the worker receives. The committed copy
(``sidecar_pulse_shape_unknown_stages.json`` beside the request envelope) is read by the worker's
``SensorBiomarkerLaneTests``; set ``FRWHOOP_PULSE_SHAPE_FIXTURE_OUTPUT=<path>`` to rewrite it.
"""

from __future__ import annotations

import json
import os

import pytest

from frwhoop_inference.contract import parse_request
from frwhoop_inference.sensor_biomarkers.provider import SensorBiomarkersProvider

from ppg_run_helpers import body, pulse_wave
from worker_envelope import FIXTURE_DIR, golden_envelope

FIXTURE = FIXTURE_DIR / "sidecar_pulse_shape_unknown_stages.json"
#: Two hours, two 120 s runs each; the second hour's pulses are faster with a slower upstroke, so
#: the two requests' medians differ and a day value must come from the pooled bins.
HOURS = ((1_780_916_400, 60.0, 0.12), (1_780_920_000, 80.0, 0.20))


def _segments(start: int, bpm: float, upstroke: float, template: dict) -> list[dict]:
    out = []
    for burst, run_start in enumerate((start, start + 400), start=1):
        wave = pulse_wave(120, 25.0, bpm=bpm, upstroke_frac=upstroke)
        out.append({"start_unix": run_start, "duration_s": 120, "sample_count_per_second": 25,
                    "samples": wave.tolist(), "run_id": f"ppg-{run_start}",
                    "config": {**template["config"], "burst_index": burst},
                    "clock": dict(template["clock"])})
    return out


def _stages() -> list[dict]:
    envelope = golden_envelope()
    if envelope is None:
        pytest.fail("the worker's golden request envelope is missing")
    template = json.loads(envelope)["input"]["ppg"]["segments"][0]
    assert template["config"]["identity"] == "unknown" and template["clock"]["samples_per_second"] == 25
    provider = SensorBiomarkersProvider()
    stages = []
    for start, bpm, upstroke in HOURS:
        result = provider.infer(parse_request(body(_segments(start, bpm, upstroke, template),
                                                   families=["pulse_shape"])))
        stages.extend(s for s in result.stages if s["family"] == "pulse_shape")
    # Through JSON exactly as the worker reads the HTTP body.
    return json.loads(json.dumps(stages, sort_keys=True))


def test_worker_pulse_shape_fixture_is_the_real_sidecar_output():
    stages = _stages()
    assert [s["status"] for s in stages] == ["ok", "ok"]
    for stage in stages:
        assert [c["configuration"] for c in stage["configurations"]] == ["unknown"]
        assert not any(key.startswith("pulse_amplitude") for key in stage["measurements"])
        assert "pulse_upstroke_median_ms" in stage["measurements"]
    out = os.environ.get("FRWHOOP_PULSE_SHAPE_FIXTURE_OUTPUT")
    if out:
        with open(out, "w") as handle:
            json.dump(stages, handle, sort_keys=True, indent=1)
            handle.write("\n")
        return
    assert FIXTURE.is_file(), f"{FIXTURE} missing; regenerate with FRWHOOP_PULSE_SHAPE_FIXTURE_OUTPUT"
    assert json.loads(FIXTURE.read_text()) == stages, "the committed fixture is not what the sidecar returns"
