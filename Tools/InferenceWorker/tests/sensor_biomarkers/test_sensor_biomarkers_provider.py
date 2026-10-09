"""Provider-level tests: request validation, dispatch, family independence,
server-path integration (spec 10.2/10.3)."""

from __future__ import annotations

import numpy as np
import pytest

from frwhoop_inference.contract import InferRequest, parse_request
from frwhoop_inference.sensor_biomarkers import imu as sbimu
from frwhoop_inference.sensor_biomarkers import ppg as sbppg
from frwhoop_inference.sensor_biomarkers.provider import (
    SensorBiomarkersProvider,
    parse_sensor_input,
)

RATE = 100.0


def _imu_segment(start=0.0, seconds=120.0, magnitude=1.0, rate=RATE):
    n = int(seconds * rate)
    accel = np.zeros((n, 3))
    accel[:, 2] = magnitude
    gyro = np.zeros((n, 3))
    return {"start_unix": start, "duration_s": seconds,
            "accel_g": np.round(accel, 6).tolist(),
            "gyro_dps": np.round(gyro, 6).tolist()}


def _ppg_segment(start=0.0, seconds=120.0, rate=24.0):
    n = int(seconds * rate)
    t = np.arange(n) / rate
    phase = (t * 1.2) % 1.0
    samples = 200000 + 30000 * np.exp(-((phase - 0.15) / 0.08) ** 2)
    return {"start_unix": start, "duration_s": seconds,
            "samples": np.round(samples, 3).tolist(),
            "config": {"source": 1, "drive": 1150}}


def _body(families=None, imu=True, ppg=True, **input_overrides):
    inp = {
        "schema_version": 1,
        "device": {"id": "dev-1", "family": "whoop5"},
        "input_revision": "sha256:" + "ab" * 32,
        "imu": {"sampling_rate_hz": RATE, "units": {"accel": "g", "gyro": "deg/s"},
                "segments": [_imu_segment()]},
        "ppg": {"native_rate_hz": 24.0, "units": "adc_counts",
                "segments": [_ppg_segment()], "expected_duration_s": 120.0},
        "watch_side": "left",
        "device_orientation": "screen_up",
        "families": families or ["movement", "oscillation", "ppg_quality",
                                 "pulse_shape", "perfusion_research"],
    }
    if not imu:
        inp.pop("imu")
    if not ppg:
        inp.pop("ppg")
    inp.update(input_overrides)
    return {
        "metric": "sensor_biomarkers",
        "context": {
            "user_id": "user-1", "device_id": "dev-1",
            "interval_start_utc": "2026-06-05T12:00:00Z",
            "interval_end_utc": "2026-06-05T12:02:00Z",
            "iana_timezone": "UTC",
            "profile_version": "p1", "config_version": "c1",
            "corrections_version": "k1", "live": False,
        },
        "input": inp,
    }


def _request(body):
    return parse_request(body)


class TestValidation:
    def test_valid_request_parses(self):
        parsed = parse_sensor_input(_body()["input"])
        assert parsed["families"] == ["movement", "oscillation", "ppg_quality",
                                      "pulse_shape", "perfusion_research"]
        assert parsed["imu"]["sampling_rate_hz"] == RATE
        assert parsed["ppg"]["native_rate_hz"] == 24.0

    @pytest.mark.parametrize("mutate,code", [
        (lambda i: i.update({"schema_version": 2}), "invalid_schema_version"),
        (lambda i: i.update({"families": ["movement", "not_a_family"]}), "invalid_families"),
        (lambda i: i.update({"families": []}), "invalid_families"),
        (lambda i: i.update({"input_revision": ""}), "invalid_input_revision"),
        (lambda i: i.pop("device"), "invalid_device"),
        (lambda i: i["imu"].update({"units": {"accel": "mg", "gyro": "deg/s"}}), "invalid_imu"),
        (lambda i: i["imu"].update({"sampling_rate_hz": 5}), "invalid_imu"),
        (lambda i: i["ppg"].update({"units": "volts"}), "invalid_ppg"),
        (lambda i: i["ppg"].update({"native_rate_hz": 400}), "invalid_ppg"),
        (lambda i: i["ppg"].pop("segments"), "invalid_ppg"),
    ])
    def test_invalid_input_maps_to_error_result(self, mutate, code):
        body = _body()
        mutate(body["input"])
        provider = SensorBiomarkersProvider()
        result = provider.infer(_request(body))
        assert result.status == "error"
        assert result.diagnostics["reason_detail"] == code

    def test_unknown_metric_rejected_by_contract(self):
        body = _body()
        body["metric"] = "not_a_metric"
        from frwhoop_inference.contract import ContractError
        with pytest.raises(ContractError):
            _request(body)


class TestDispatch:
    def test_full_request_returns_all_requested_families(self):
        provider = SensorBiomarkersProvider()
        result = provider.infer(_request(_body()))
        assert result.status == "ok"
        families = [s["family"] for s in result.stages]
        assert families == ["movement", "oscillation", "ppg_quality",
                            "pulse_shape", "perfusion_research"]
        # every measurement entry carries value/unit and count/method
        for stage in result.stages:
            for key, entry in stage.get("measurements", {}).items():
                assert "value" in entry and "unit" in entry, key
                if entry["value"] is not None:
                    assert np.isfinite(entry["value"]), key
        assert result.coverage["movement"]["observed_seconds"] == 120.0
        assert "neurokit2" in result.versions

    def test_missing_imu_withholds_imu_families_not_others(self):
        # No verified IMU objects: movement/oscillation withheld with a precise
        # reason; PPG families still publish (family independence).
        provider = SensorBiomarkersProvider()
        result = provider.infer(_request(_body(imu=False)))
        assert result.status == "ok"
        by_family = {s["family"]: s for s in result.stages}
        assert by_family["movement"]["status"] == "withheld"
        assert by_family["movement"]["reason"] == "no_verified_input"
        assert by_family["ppg_quality"]["status"] == "ok"
        assert by_family["pulse_shape"]["status"] == "ok"

    def test_corrupt_ppg_does_not_discard_valid_imu_families(self):
        # A failing optional family never discards already valid families.
        body = _body()
        # saturate the PPG segment so quality withholds
        seg = body["input"]["ppg"]["segments"][0]
        seg["samples"][10] = 524287
        seg["samples"][11] = 524287
        provider = SensorBiomarkersProvider()
        result = provider.infer(_request(body))
        by_family = {s["family"]: s for s in result.stages}
        assert by_family["movement"]["status"] == "ok"
        assert by_family["oscillation"]["status"] == "ok"
        assert "template_similarity_median" not in by_family["ppg_quality"]["measurements"]

    def test_optional_adapter_failure_yields_error_stage(self, monkeypatch):
        # A raising optional adapter yields adapter_broken for its own families,
        # never an error for the whole request or the descriptive families.
        monkeypatch.delenv("FRWHOOP_DEEPBEAT_SHADOW_ENABLED", raising=False)
        monkeypatch.delenv("FRWHOOP_SIAMAF_SHADOW_ENABLED", raising=False)

        class Exploding:
            FAMILIES = ("tremor", "arm_swing")

            @staticmethod
            def adapter_state():
                return {"adapter": "paradigma", "state": "ready", "reason": None, "detail": None}

            @staticmethod
            def compute_family_documents(input_payload, families, *, deadline_s=None):
                raise RuntimeError("paradigma exploded")

        body = _body(families=["movement", "tremor", "rhythm_shadow"])
        provider = SensorBiomarkersProvider(optional_adapters={"paradigma": Exploding})
        result = provider.infer(_request(body))
        assert result.status == "ok"
        by_family = {s["family"]: s for s in result.stages}
        assert by_family["movement"]["status"] == "ok"
        assert by_family["tremor"]["status"] == "error"
        assert by_family["tremor"]["reason"] == "adapter_broken"
        assert by_family["tremor"]["reason_counts"] == {"adapter_exception": 1}
        assert "paradigma exploded" in by_family["tremor"]["adapter"]["detail"]
        # rhythm_shadow still reaches its real implementation: disabled by flag.
        assert by_family["rhythm_shadow"]["status"] == "withheld"
        assert by_family["rhythm_shadow"]["reason"] == "family_disabled"

    def test_unrequested_families_absent(self):
        provider = SensorBiomarkersProvider()
        result = provider.infer(_request(_body(families=["movement"])))
        assert [s["family"] for s in result.stages] == ["movement"]

    def test_reason_counts_and_coverage_accumulate(self):
        body = _body(imu=False, families=["movement", "oscillation"])
        provider = SensorBiomarkersProvider()
        result = provider.infer(_request(body))
        assert result.diagnostics["reason_counts"]["no_verified_imu_objects"] == 2


class TestServerPath:
    def test_end_to_end_through_the_real_server(self):
        # The full POST /v1/infer path: route, provider selection, render.
        from frwhoop_inference.server import Application, run_inference

        app = Application.build(manifest_path=_manifest_path())
        body = _body()
        payload = run_inference(app, _request(body))
        assert payload["status"] == "ok"
        assert payload["metric"] == "sensor_biomarkers"
        assert payload["provider_id"] == "sensor.biomarkers.v1"
        stages = payload["result"]["stages"]
        assert {s["family"] for s in stages} >= {"movement", "ppg_quality"}
        assert payload["result"]["label_space"] == "sensor_biomarkers.families/1"
        assert payload["publishable"] is True

    def test_provider_listed_in_default_registry(self):
        from frwhoop_inference.providers import default_providers

        ids = [p.provider_id for p in default_providers()]
        assert "sensor.biomarkers.v1" in ids

    def test_readiness_gates_neurokit_version(self):
        provider = SensorBiomarkersProvider()
        ready, reason = provider.readiness()
        assert ready, reason


def _manifest_path():
    import os
    root = os.environ.get("FRWHOOP_MODEL_ROOT", "/tmp/frwhoop-sensor-biomarkers/models")
    return os.path.join(os.path.dirname(__file__), "..", "..", "models", "manifest.json")
