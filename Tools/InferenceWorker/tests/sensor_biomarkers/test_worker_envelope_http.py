"""The worker's exact request envelope through the sidecar's real HTTP route (Spec 01 §3/§4).

``worker_envelope`` writes the body the Swift worker writes (SensorBiomarkerInputs +
SensorBiomarkerLane.inferenceBody) from the committed worker fixtures; it is posted as raw bytes
to ``POST /v1/infer`` on ``server.create_server`` bound to a free loopback port, and the response
is read the way the lane parses it. The default registry is used, so the route reaches the real
family implementations. No DeepBeat/SiamAF weights exist on this machine, so the rhythm family is
asserted on its distinct ``artifact_unavailable`` path here (its real code with stand-in networks
is covered in test_family_dispatch.py); ParaDigMa on its real pinned pipeline is covered in
paradigma/test_paradigma_aggregate_route.py when its venv is present.
"""

from __future__ import annotations

import json
import os
import threading
import urllib.error
import urllib.request

import numpy as np
import pytest

from frwhoop_inference.contract import MAX_BODY_BYTES
from frwhoop_inference.server import create_server

import worker_envelope as W
from ppg_run_helpers import pulse_wave

MANIFEST = os.path.join(os.path.dirname(__file__), "..", "..", "models", "manifest.json")
FLAGS = ("FRWHOOP_PARADIGMA_ENABLED", "FRWHOOP_DEEPBEAT_SHADOW_ENABLED",
         "FRWHOOP_SIAMAF_SHADOW_ENABLED")
FAMILY_STATUSES = ("ok", "withheld", "error")


@pytest.fixture
def sidecar(tmp_path, monkeypatch):
    for flag in FLAGS:
        monkeypatch.delenv(flag, raising=False)
    root = tmp_path / "models"
    root.mkdir()
    monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(root))
    monkeypatch.setenv("FRWHOOP_MANIFEST", os.path.abspath(MANIFEST))
    servers = []

    def start():
        server = create_server("127.0.0.1", 0, manifest_path=os.path.abspath(MANIFEST),
                               model_root=str(root))
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                                  daemon=True)
        thread.start()
        servers.append(server)
        return f"http://127.0.0.1:{server.server_address[1]}"

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()


def _post(base: str, raw: bytes) -> tuple[int, dict]:
    request = urllib.request.Request(base + "/v1/infer", data=raw, method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read())


def _get(base: str, path: str) -> dict:
    with urllib.request.urlopen(base + path, timeout=30) as response:
        return json.loads(response.read())


def _lane_stages(envelope: dict, families: list[str]) -> dict[str, dict]:
    """What SensorBiomarkerLane.parseEnvelope accepts, asserted, keyed by family."""
    assert envelope["status"] == "ok", envelope
    assert envelope["provider_id"] == "sensor.biomarkers.v1"
    assert envelope["result"]["label_space"] == "sensor_biomarkers.families/1"
    out = {}
    for stage in envelope["result"]["stages"]:
        assert stage["family"] in families
        assert stage["status"] in FAMILY_STATUSES
        assert isinstance(stage["measurements"], dict)
        assert all(isinstance(v, int) for v in stage.get("reason_counts", {}).values())
        assert stage["release_tier"] in ("descriptive", "research", "shadow")
        out[stage["family"]] = stage
    assert sorted(out) == sorted(families)
    return out


def test_legacy_worker_envelope_from_the_committed_fixtures(sidecar):
    raw = W.legacy_fixture_body()
    request = json.loads(raw)
    assert request["input"]["ppg"]["native_rate_hz"] == 24
    assert all(set(s["config"]) == {"stable"} for s in request["input"]["ppg"]["segments"])
    status, envelope = _post(sidecar(), raw)
    assert status == 200
    stages = _lane_stages(envelope, W.ALL_FAMILIES)
    # 3 s + 1 s of IMU around a gap: no complete 5 s epoch or 4 s window
    assert stages["movement"]["reason"] == "insufficient_eligible_time"
    assert stages["oscillation"]["reason"] == "insufficient_eligible_time"
    # Old worker, old rules: the flat anchored second withholds similarity
    # request-wide, exactly as before this change.
    assert stages["ppg_quality"]["template_similarity_withheld"] is True
    assert stages["pulse_shape"]["status"] == "withheld"
    assert stages["perfusion_research"]["reason"] == "unverified_optical_dc"
    # Every optional family reaches its adapter and says why it did not run.
    for family in ("tremor", "arm_swing", "rhythm_shadow"):
        assert stages[family]["status"] == "withheld"
        assert stages[family]["reason"] == "family_disabled"


def _run_aware_body(families: list[str]) -> bytes:
    """Eight minutes of IMU and three anchored PPG bursts, written as the run-aware worker would
    (one request: the worker packs a longer hour into several under its 7.5 MB budget)."""
    start = 1_780_003_600
    imu = W.imu_segments(W.synthetic_imu_records(start, 480))
    records = []
    for i, (offset, seconds, amp) in enumerate(((0, 120, 30000.0), (300, 90, 45000.0),
                                                (600, 60, 20000.0))):
        wave = pulse_wave(seconds, 25.0, amp=amp, t0=float(offset))
        records += W.records_from_wave(wave, start + offset, burst_index=i + 1)
    ppg = W.ppg_segments(records, encoding="run_aware")
    return W.build_body(imu=imu, ppg=ppg, families=families,
                        revision=W.input_revision(["ab" * 32, "cd" * 32]),
                        day=W.iso_utc(start)[:10], ppg_rate=25)


def test_run_aware_envelope_reaches_every_family(sidecar, monkeypatch):
    monkeypatch.setenv("FRWHOOP_PARADIGMA_ENABLED", "1")
    monkeypatch.setenv("FRWHOOP_DEEPBEAT_SHADOW_ENABLED", "1")
    monkeypatch.setenv("FRWHOOP_SIAMAF_SHADOW_ENABLED", "1")
    raw = _run_aware_body(W.ALL_FAMILIES)
    assert len(raw) < MAX_BODY_BYTES
    segments = json.loads(raw)["input"]["ppg"]["segments"]
    assert {s["run_id"] for s in segments} == {"ppg-1780003600", "ppg-1780003900",
                                               "ppg-1780004200"}
    base = sidecar()
    status, envelope = _post(base, raw)
    assert status == 200
    stages = _lane_stages(envelope, W.ALL_FAMILIES)

    assert stages["movement"]["status"] == "ok"
    assert stages["ppg_quality"]["status"] == "ok"
    assert stages["ppg_quality"]["native_rate_hz"] == 25.0
    assert stages["ppg_quality"]["runs"]["count"] == 3
    pulse = stages["pulse_shape"]
    assert pulse["status"] == "ok"
    assert pulse["amplitude_scope"] == "per_run"
    assert pulse["amplitude_scope_reason"] == "configuration_unidentified"
    assert "pulse_amplitude_median_au" not in pulse["measurements"]
    levels = [row["pulse_amplitude_median_au"] for row in pulse["run_amplitudes"]["listed"]]
    assert levels[1] / levels[0] == pytest.approx(1.5, rel=0.05)
    assert pulse["measurements"]["pulse_width50_median_ms"]["value"] > 0
    # No weights on this machine: the model is unavailable, never a silent drop (and never
    # confused with missing input, which reads no_verified_input).
    assert stages["tremor"]["reason"] == "model_unavailable"
    assert stages["arm_swing"]["reason"] == "model_unavailable"
    rhythm = stages["rhythm_shadow"]
    assert rhythm["status"] == "withheld" and rhythm["reason"] == "model_unavailable"
    assert rhythm["release_tier"] == "shadow"
    assert envelope["raw_scores"] is None

    # /v1/providers names the adapter state per family (what is missing: the artifact).
    providers = {p["provider_id"]: p for p in _get(base, "/v1/providers")["providers"]}
    aggregate = providers["sensor.biomarkers.v1"]
    assert aggregate["readiness"]["ready"] is True
    families = aggregate["families"]
    assert families["pulse_shape"]["ready"] is True
    for family in ("tremor", "arm_swing", "rhythm_shadow"):
        assert families[family]["state"] == "artifact_unavailable"
        assert families[family]["ready"] is False
    # The standalone rhythm provider reports the enabled-but-unprovisioned lane.
    assert providers["sensor.biomarkers.rhythm.v1"]["readiness"]["ready"] is False


def test_optional_families_disabled_are_reported_by_the_route(sidecar):
    base = sidecar()
    families = _get(base, "/v1/providers")
    aggregate = next(p for p in families["providers"] if p["provider_id"] == "sensor.biomarkers.v1")
    for family in ("tremor", "arm_swing", "rhythm_shadow"):
        assert aggregate["families"][family]["state"] == "disabled"
        assert aggregate["families"][family]["reason"] == "family_disabled"
    assert aggregate["canonical_route"] == "sensor.biomarkers.v1"


@pytest.mark.skipif(W.golden_envelope() is None,
                    reason="the worker's golden request envelope "
                           "(Resources/sensor_biomarkers/sensor_biomarkers_request_envelope.json) "
                           "is committed on the PPG transport branch, not on this base")
def test_golden_worker_envelope(sidecar):
    raw = W.golden_envelope()
    status, envelope = _post(sidecar(), raw)
    assert status == 200
    families = json.loads(raw)["input"]["families"]
    stages = _lane_stages(envelope, families)
    for family, stage in stages.items():
        if family in ("ppg_quality", "pulse_shape") and stage["status"] == "ok":
            assert stage["computation"] == "per_run"
