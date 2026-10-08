"""ParaDigMa through ``sensor.biomarkers.v1``, the route the worker calls, on the REAL pipeline.

The worker's envelope (``worker_envelope``, a port of the Swift writer) is posted over HTTP to
``server.create_server`` with the default registry; tremor must come back computed by the pinned
ParaDigMa 1.1.2 subprocess with the manifest-verified classifier bytes, not by a separately
registered provider. SKIPS when the paradigma subprocess venv is not present.
"""

from __future__ import annotations

import json
import sys
import threading
import urllib.request
from pathlib import Path

import pytest

# worker_envelope lives one directory up (tests/sensor_biomarkers), beside the other helpers.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import worker_envelope as W  # noqa: E402
from pd_fixtures import (manifest_with_paradigma, paradigma_env,  # noqa: E402,F401
                         provisioned_root, real_asset_bytes)
from frwhoop_inference.sensor_biomarkers import paradigma  # noqa: E402
from frwhoop_inference.server import create_server  # noqa: E402

START = 1_780_010_000


def _serve(env):
    server = create_server("127.0.0.1", 0, manifest_path=str(env["manifest"]),
                           model_root=str(env["root"]))
    threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05},
                     daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


def test_aggregate_route_runs_the_real_paradigma_pipeline(paradigma_env):
    server, base = _serve(paradigma_env)
    try:
        families = ["arm_swing", "movement", "tremor"]
        raw = W.build_body(imu=W.imu_segments(W.synthetic_imu_records(START, 40)), ppg=[],
                           families=families, revision=W.input_revision(["ef" * 32]),
                           day=W.iso_utc(START)[:10])
        request = urllib.request.Request(base + "/v1/infer", data=raw, method="POST",
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=300) as response:
            envelope = json.loads(response.read())
        assert envelope["status"] == "ok"
        assert envelope["provider_id"] == "sensor.biomarkers.v1"
        stages = {s["family"]: s for s in envelope["result"]["stages"]}
        tremor = stages["tremor"]
        assert tremor["status"] == "ok" and tremor["release_tier"] == "research"
        # 40 s at 100 Hz -> nine 4 s windows classified by the real pipeline
        assert tremor["measurements"]["eligible_rest_seconds"]["count"] == 9
        assert tremor["quantification_parity_with_orchestrator"] is True
        assert tremor["input_provenance"] == {"imu_native_rate_hz": 100.0, "runs": 1,
                                              "observed_seconds": 40.0}
        # the worker does not know the placement, so it is never guessed
        assert tremor["placement"] == {"watch_side": "unknown", "device_orientation": "unknown",
                                       "source": "request"}
        assert stages["arm_swing"]["status"] == "withheld"
        assert stages["arm_swing"]["reason"] == "unknown_wrist_placement"
        assert stages["movement"]["status"] == "ok"

        with urllib.request.urlopen(base + "/v1/providers", timeout=30) as response:
            providers = {p["provider_id"]: p for p in json.loads(response.read())["providers"]}
        state = providers["sensor.biomarkers.v1"]["families"]["tremor"]
        assert state["ready"] is True and state["state"] == "ready"
        assert state["runtime"]["upstream_commit"] == paradigma.UPSTREAM_COMMIT
    finally:
        server.shutdown()
        server.server_close()


def test_subprocess_over_its_budget_is_withheld_timeout(paradigma_env):
    payload = json.loads(W.build_body(imu=W.imu_segments(W.synthetic_imu_records(START, 40)),
                                      ppg=[], families=["tremor"], revision="sha256:" + "0" * 64,
                                      day="2026-06-01"))["input"]
    docs = paradigma.compute_family_documents(payload, ["tremor"], deadline_s=0.05)
    assert [d["family"] for d in docs] == ["tremor"]
    assert docs[0]["status"] == "withheld" and docs[0]["reason"] == "timeout"
    assert docs[0]["reason_counts"] == {"paradigma_subprocess_timeout": 1}
