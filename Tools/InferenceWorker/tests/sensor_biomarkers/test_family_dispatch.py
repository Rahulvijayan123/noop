"""Optional families through ``sensor.biomarkers.v1``, the route the worker calls (Spec 01 §4).

The aggregate route must reach the ParaDigMa and rhythm implementations, keep every family's
failure to itself, and tell a disabled flag, missing weights or runtime, and a broken adapter
apart. Doubles are injected at the seam (``SensorBiomarkersProvider(optional_adapters=...)``),
never by patching an import away; where a double wraps the real family code it only replaces
the network, so windowing, gating and document assembly are the real ones.
"""

from __future__ import annotations

import hashlib
import json

import numpy as np
import pytest

from frwhoop_inference.contract import parse_request
from frwhoop_inference.sensor_biomarkers import FAMILY_TIERS
from frwhoop_inference.sensor_biomarkers import rhythm as real_rhythm
from frwhoop_inference.sensor_biomarkers.optional import PROVIDER_REVISION_RE
from frwhoop_inference.sensor_biomarkers.provider import SensorBiomarkersProvider
from frwhoop_inference.sensor_biomarkers.rhythm.deepbeat import DeepBeatAdapter
from frwhoop_inference.sensor_biomarkers.rhythm.siamaf import SiamAFAdapter

from ppg_run_helpers import VERIFIED_CLOCK, body, pulse_wave, unknown_segment

T0 = 1_780_000_000
RATE = 25.0
ALL_OPTIONAL = ["tremor", "arm_swing", "rhythm_shadow"]
FLAGS = ("FRWHOOP_PARADIGMA_ENABLED", "FRWHOOP_DEEPBEAT_SHADOW_ENABLED",
         "FRWHOOP_SIAMAF_SHADOW_ENABLED")


@pytest.fixture(autouse=True)
def _flags_off(monkeypatch):
    for flag in FLAGS:
        monkeypatch.delenv(flag, raising=False)


def _imu(seconds=60):
    n = seconds * 100
    rng = np.random.default_rng(3)
    accel = np.tile([0.0, 0.0, 1.0], (n, 1)) + rng.normal(0, 0.01, (n, 3))
    return {"sampling_rate_hz": 100, "units": {"accel": "g", "gyro": "deg/s"},
            "segments": [{"start_unix": T0, "duration_s": seconds,
                          "accel_g": np.round(accel, 6).tolist(),
                          "gyro_dps": np.round(rng.normal(0, 0.5, (n, 3)), 6).tolist()}]}


def _request(families, ppg=None, **overrides):
    segments = ppg if ppg is not None else [unknown_segment(T0, pulse_wave(120, RATE))]
    return parse_request(body(segments, families=families, imu=_imu(), **overrides))


def _by_family(result):
    assert result.status == "ok"
    return {s["family"]: s for s in result.stages}


class _Ready:
    """A recording double with the optional-family interface."""

    FAMILIES = ("tremor", "arm_swing")

    def __init__(self, docs=None, raises=None):
        self.calls = []
        self._docs = docs
        self._raises = raises

    def adapter_state(self):
        return {"adapter": "paradigma", "state": "ready", "reason": None, "detail": None}

    def compute_family_documents(self, input_payload, families, *, deadline_s=None):
        self.calls.append({"payload": input_payload, "families": list(families),
                           "deadline_s": deadline_s})
        if self._raises is not None:
            raise self._raises
        if self._docs is not None:
            return self._docs
        return [{"family": f, "status": "ok", "release_tier": "descriptive",
                 "provider_revision": "paradigma/1.0.0",
                 "measurements": {"eligible_rest_seconds": {"value": 8.0, "unit": "s"}},
                 "reason_counts": {}} for f in families]


# ---------------------------------------------------------------------------
# The aggregate route reaches the implementations
# ---------------------------------------------------------------------------

class TestReachesImplementations:
    def test_paradigma_double_receives_the_request_with_placement_and_inputs(self):
        double = _Ready()
        provider = SensorBiomarkersProvider(optional_adapters={"paradigma": double})
        request = _request(["movement", "tremor", "arm_swing"], watch_side="left",
                           device_orientation="screen_up")
        fam = _by_family(provider.infer(request))
        (call,) = double.calls
        assert call["families"] == ["tremor", "arm_swing"]
        # the adapter gets the request exactly as sent: placement is never filled in
        assert call["payload"]["watch_side"] == "left"
        assert call["payload"]["device_orientation"] == "screen_up"
        assert call["payload"]["imu"]["sampling_rate_hz"] == 100
        assert 0 < call["deadline_s"] <= 0.6 * 20.0
        assert fam["tremor"]["measurements"]["eligible_rest_seconds"]["value"] == 8.0
        # an adapter can never raise its own tier
        assert fam["tremor"]["release_tier"] == "research"
        assert fam["movement"]["status"] == "ok"

    def test_rhythm_real_family_code_runs_behind_the_seam(self, monkeypatch):
        # Only the networks are stand-ins: the real rhythm family code parses the
        # PPG, gates the clock, windows run by run and assembles the shadow stage.
        monkeypatch.setenv("FRWHOOP_DEEPBEAT_SHADOW_ENABLED", "1")
        monkeypatch.setenv("FRWHOOP_SIAMAF_SHADOW_ENABLED", "1")
        seen = []

        class Network:
            def predict(self, batch, verbose=0):
                seen.append(batch.shape)
                return np.array([[0.2, 0.3, 0.5]]), np.array([[0.9, 0.1]])

        class StandInDeepBeat(DeepBeatAdapter):
            def readiness(self):
                return True, None

            def _load_model(self):
                return Network()

        class StandInSiamAF(SiamAFAdapter):
            def readiness(self):
                return True, None

            def _classify(self, window):
                seen.append(window.shape)
                return np.array([1.5, -1.5])

        stand_ins = {"deepbeat": StandInDeepBeat, "siamaf": StandInSiamAF}

        class RhythmWithStandInNetworks:
            FAMILIES = real_rhythm.FAMILIES

            @staticmethod
            def adapter_state():
                return real_rhythm.adapter_state(model_adapters=stand_ins)

            @staticmethod
            def compute_family_documents(input_payload, families, *, deadline_s=None):
                return real_rhythm.compute_family_documents(
                    input_payload, families, deadline_s=deadline_s, model_adapters=stand_ins)

        ppg = [unknown_segment(T0, pulse_wave(60, RATE), run_id="ppg-a", clock=VERIFIED_CLOCK),
               unknown_segment(T0 + 100, pulse_wave(50, RATE, t0=100.0), run_id="ppg-b",
                               clock=VERIFIED_CLOCK),
               # a run whose clock was not verified against packet timing
               unknown_segment(T0 + 200, pulse_wave(40, RATE, t0=200.0), run_id="ppg-c")]
        provider = SensorBiomarkersProvider(optional_adapters={"rhythm": RhythmWithStandInNetworks})
        stage = _by_family(provider.infer(_request(["movement", "rhythm_shadow"], ppg=ppg)))[
            "rhythm_shadow"]
        assert stage["status"] == "ok" and stage["release_tier"] == "shadow"
        siamaf = stage["measurements"]["siamaf_rhythm_scores"]
        # 30 s SiamAF windows inside runs only: 60 s -> 2, 50 s -> 1, unverified run -> 0
        assert siamaf["count"] == 3
        assert siamaf["window_runs"] == ["ppg-a", "ppg-a", "ppg-b"]
        assert siamaf["window_starts_unix"] == [T0, T0 + 30, T0 + 100]
        assert siamaf["native_rate_hz"] == 25.0 and siamaf["model_input_rate_hz"] == 80.0
        deepbeat = stage["raw_scores"]["deepbeat_rhythm_scores"]
        assert deepbeat["count"] == 4 and deepbeat["model_input_rate_hz"] == 32.0
        assert deepbeat["preprocessing_status"] == "preprocessing_unverified"
        assert (1, 800, 1) in seen and (1, 2400) in seen
        assert stage["reason_counts"]["unverified_sample_clock_runs"] == 1
        prov = stage["input_provenance"]
        assert prov["native_rate_hz"] == 25.0 and prov["clock_gate"] == "packet_timing_verified"
        assert prov["runs"] == 3 and prov["runs_clock_verified"] == 2
        assert stage["provider_revision"] == "deepbeat/1.0.0_siamaf/1.0.0"
        assert PROVIDER_REVISION_RE.match(stage["provider_revision"])
        text = json.dumps(stage).lower()
        assert "burden" not in text and '"publishable": true' not in text

    def test_rhythm_withholds_when_no_run_clock_is_verified(self, monkeypatch):
        # The real v26 path today: packet_timing_verified is false on every run.
        monkeypatch.setenv("FRWHOOP_SIAMAF_SHADOW_ENABLED", "1")

        class AlwaysReady(SiamAFAdapter):
            def readiness(self):
                return True, None

        class Rhythm:
            FAMILIES = real_rhythm.FAMILIES
            adapter_state = staticmethod(lambda: real_rhythm.adapter_state(
                model_adapters={"siamaf": AlwaysReady}))

            @staticmethod
            def compute_family_documents(input_payload, families, *, deadline_s=None):
                return real_rhythm.compute_family_documents(
                    input_payload, families, model_adapters={"siamaf": AlwaysReady})

        provider = SensorBiomarkersProvider(optional_adapters={"rhythm": Rhythm})
        stage = _by_family(provider.infer(_request(["rhythm_shadow"])))["rhythm_shadow"]
        assert stage["status"] == "withheld"
        assert stage["reason"] == "unverified_sample_clock"
        assert stage["measurements"] == {} and "raw_scores" not in stage


# ---------------------------------------------------------------------------
# Distinct failure surfaces
# ---------------------------------------------------------------------------

def _fake_paradigma_root(tmp_path):
    """A manifest + root whose paradigma artifacts verify (dummy bytes, real hashing)."""
    from frwhoop_inference.sensor_biomarkers.paradigma.provider import REQUIRED_ARTIFACTS

    root = tmp_path / "root"
    artifacts = []
    for name in REQUIRED_ARTIFACTS:
        data = f"stand-in bytes for {name}".encode()
        path = root / "paradigma" / "pinned" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        artifacts.append({"name": name, "path": f"paradigma/pinned/{name}",
                          "sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data),
                          "verify_at_startup": True})
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"manifest_version": "test", "entries": [
        {"id": "paradigma", "provider_id": "sensor.biomarkers.paradigma.v1",
         "required_for_readiness": False, "artifacts": artifacts}]}))
    return root, manifest


class TestDistinctFailureSurfaces:
    def test_disabled_missing_weights_missing_runtime_and_broken_are_distinct(
            self, monkeypatch, tmp_path):
        reasons = {}

        # 1. flag off
        fam = _by_family(SensorBiomarkersProvider().infer(_request(ALL_OPTIONAL)))
        assert fam["tremor"]["status"] == "withheld"
        reasons["disabled"] = (fam["tremor"]["reason"], fam["rhythm_shadow"]["reason"])

        # 2. flag on, weights missing
        monkeypatch.setenv("FRWHOOP_PARADIGMA_ENABLED", "1")
        monkeypatch.setenv("FRWHOOP_DEEPBEAT_SHADOW_ENABLED", "1")
        monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(tmp_path / "empty"))
        fam = _by_family(SensorBiomarkersProvider().infer(_request(ALL_OPTIONAL)))
        assert fam["tremor"]["reason_counts"] == {"artifact_missing": 1}
        assert fam["rhythm_shadow"]["adapters"]["deepbeat"]["reason"] == "artifact_unavailable"
        reasons["weights"] = (fam["tremor"]["reason"], fam["rhythm_shadow"]["reason"])

        # 3. weights verified, isolated runtime missing
        root, manifest = _fake_paradigma_root(tmp_path)
        monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(root))
        monkeypatch.setenv("FRWHOOP_MANIFEST", str(manifest))
        monkeypatch.setenv("FRWHOOP_PARADIGMA_PYTHON", str(tmp_path / "no-venv" / "python"))
        fam = _by_family(SensorBiomarkersProvider().infer(_request(["tremor"])))
        assert fam["tremor"]["reason_counts"] == {"paradigma_runtime_missing": 1}
        reasons["runtime"] = (fam["tremor"]["reason"],)

        # 4. the adapter itself cannot be imported
        provider = SensorBiomarkersProvider(optional_adapters={
            "paradigma": "family_adapter_broken_import",
            "rhythm": "frwhoop_inference.sensor_biomarkers.no_such_adapter"})
        fam = _by_family(provider.infer(_request(ALL_OPTIONAL)))
        for family in ALL_OPTIONAL:
            assert fam[family]["status"] == "error"
            assert fam[family]["reason_counts"] == {"adapter_import_error": 1}
        assert "frwhoop_missing_optional_dependency" in fam["tremor"]["adapter"]["detail"]
        reasons["broken"] = (fam["tremor"]["reason"], fam["rhythm_shadow"]["reason"])

        assert reasons == {
            "disabled": ("family_disabled", "family_disabled"),
            "weights": ("model_unavailable", "model_unavailable"),
            "runtime": ("runtime_unavailable",),
            "broken": ("adapter_broken", "adapter_broken"),
        }

    @pytest.mark.parametrize("double, code", [
        (type("NoCompute", (), {"FAMILIES": ("tremor", "arm_swing"),
                                "adapter_state": staticmethod(lambda: {})}),
         "adapter_interface_mismatch"),
        (type("OldSignature", (), {
            "FAMILIES": ("tremor", "arm_swing"),
            "adapter_state": staticmethod(lambda: {}),
            "compute_family_documents": staticmethod(lambda payload: [])}),
         "adapter_interface_mismatch"),
        (type("WrongFamilies", (), {
            "FAMILIES": ("tremor",),
            "adapter_state": staticmethod(lambda: {}),
            "compute_family_documents": staticmethod(
                lambda payload, families, *, deadline_s=None: [])}),
         "adapter_interface_mismatch"),
        (_Ready(raises=AttributeError("'NoneType' object has no attribute 'run'")),
         "adapter_exception"),
        (_Ready(docs=[{"family": "tremor", "status": "maybe", "measurements": {},
                       "provider_revision": "paradigma/1.0.0"}]),
         "adapter_interface_mismatch"),
        (_Ready(docs=[{"family": "tremor", "status": "ok", "measurements": {},
                       "provider_revision": "paradigma/1.0.0",
                       "reason_counts": {"filtered_seconds": 12.5}}]),
         "adapter_interface_mismatch"),
    ])
    def test_interface_mismatch_and_exceptions_are_adapter_broken(self, double, code):
        provider = SensorBiomarkersProvider(optional_adapters={"paradigma": double})
        fam = _by_family(provider.infer(_request(["movement", "tremor", "arm_swing"])))
        assert fam["movement"]["status"] == "ok"
        for family in ("tremor", "arm_swing"):
            assert fam[family]["status"] == "error"
            assert fam[family]["reason"] == "adapter_broken"
            assert fam[family]["reason_counts"] == {code: 1}
            assert fam[family]["measurements"] == {}

    def test_one_broken_family_never_discards_the_others(self):
        provider = SensorBiomarkersProvider(optional_adapters={
            "paradigma": _Ready(raises=RuntimeError("boom")),
            "rhythm": "family_adapter_broken_import"})
        families = ["movement", "oscillation", "ppg_quality", "pulse_shape", *ALL_OPTIONAL]
        fam = _by_family(provider.infer(_request(families)))
        assert [f for f in families if fam[f]["status"] == "ok"] == [
            "movement", "oscillation", "ppg_quality", "pulse_shape"]
        assert {fam[f]["reason"] for f in ALL_OPTIONAL} == {"adapter_broken"}

    def test_exhausted_optional_budget_is_a_timeout_not_a_drop(self):
        double = _Ready()
        provider = SensorBiomarkersProvider(optional_adapters={"paradigma": double},
                                            optional_budget_s=0.0)
        fam = _by_family(provider.infer(_request(["movement", *ALL_OPTIONAL])))
        assert double.calls == []
        for family in ALL_OPTIONAL:
            assert fam[family]["status"] == "withheld" and fam[family]["reason"] == "timeout"
            assert fam[family]["reason_counts"] == {"optional_family_budget_exhausted": 1}
        assert fam["movement"]["status"] == "ok"

    def test_capability_reports_each_family_state(self, monkeypatch):
        families = SensorBiomarkersProvider().capability()["families"]
        assert list(families) == ["movement", "oscillation", "ppg_quality", "pulse_shape",
                                  "perfusion_research", "tremor", "arm_swing", "rhythm_shadow"]
        assert families["movement"]["ready"] is True and families["movement"]["publishable"]
        for family in ALL_OPTIONAL:
            assert families[family]["state"] == "disabled"
            assert families[family]["reason"] == "family_disabled"
            assert families[family]["publishable"] is False
            assert families[family]["tier"] == FAMILY_TIERS[family]
        assert families["arm_swing"]["axis_convention_verified"] is False
        broken = SensorBiomarkersProvider(optional_adapters={
            "paradigma": "family_adapter_broken_import"}).capability()["families"]
        assert broken["tremor"]["state"] == "adapter_broken"
        assert broken["tremor"]["detail_code"] == "adapter_import_error"
        assert broken["tremor"]["ready"] is False
        assert broken["rhythm_shadow"]["state"] == "disabled"


# ---------------------------------------------------------------------------
# Shadow isolation
# ---------------------------------------------------------------------------

class TestShadowOnly:
    @pytest.mark.parametrize("doc, detail", [
        ({"measurements": {"af_burden_percent": {"value": 3.0}}}, "measurements outside"),
        ({"measurements": {"siamaf_rhythm_scores": {"publishable": True, "scores": []}}},
         "publishable"),
        ({"raw_scores": {"af_episode_count": 2}}, "raw_scores outside"),
        ({"adapters": {"siamaf": {"af_alert": True}}}, "clinical key"),
        ({"provider_revision": "deepbeat/1.0.0+siamaf/1.0.0"}, "not publishable"),
    ])
    def test_rhythm_stage_that_breaks_the_shadow_contract_is_never_published(self, doc, detail):
        stage = {"family": "rhythm_shadow", "status": "ok", "release_tier": "shadow",
                 "provider_revision": "siamaf/1.0.0", "measurements": {}, "reason_counts": {}}
        stage.update(doc)

        class Rhythm:
            FAMILIES = ("rhythm_shadow",)
            adapter_state = staticmethod(lambda: {"adapter": "rhythm", "state": "ready",
                                                  "reason": None, "detail": None})
            compute_family_documents = staticmethod(
                lambda payload, families, *, deadline_s=None: [dict(stage)])

        provider = SensorBiomarkersProvider(optional_adapters={"rhythm": Rhythm})
        out = _by_family(provider.infer(_request(["rhythm_shadow"])))["rhythm_shadow"]
        assert out["status"] == "error" and out["reason"] == "adapter_broken"
        assert out["reason_counts"] == {"adapter_interface_mismatch": 1}
        assert detail in out["adapter"]["detail"]
        assert out["measurements"] == {} and "raw_scores" not in out

    def test_rhythm_tier_is_always_shadow(self):
        class Rhythm:
            FAMILIES = ("rhythm_shadow",)
            adapter_state = staticmethod(lambda: {"adapter": "rhythm", "state": "ready",
                                                  "reason": None, "detail": None})
            compute_family_documents = staticmethod(
                lambda payload, families, *, deadline_s=None: [{
                    "family": "rhythm_shadow", "status": "ok", "release_tier": "descriptive",
                    "provider_revision": "siamaf/1.0.0", "measurements": {},
                    "reason_counts": {}}])

        provider = SensorBiomarkersProvider(optional_adapters={"rhythm": Rhythm})
        out = _by_family(provider.infer(_request(["rhythm_shadow"])))["rhythm_shadow"]
        assert out["release_tier"] == "shadow"


def test_every_stage_revision_is_one_the_day_table_accepts(monkeypatch, tmp_path):
    monkeypatch.setenv("FRWHOOP_DEEPBEAT_SHADOW_ENABLED", "1")
    monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(tmp_path))
    families = ["movement", "oscillation", "ppg_quality", "pulse_shape", "perfusion_research",
                *ALL_OPTIONAL]
    for provider in (SensorBiomarkersProvider(),
                     SensorBiomarkersProvider(optional_adapters={
                         "paradigma": "family_adapter_broken_import"})):
        for stage in provider.infer(_request(families)).stages:
            assert PROVIDER_REVISION_RE.match(stage["provider_revision"]), stage
            assert all(isinstance(v, int) for v in stage["reason_counts"].values()), stage
