"""Measured loaded identity of the checkpoint-loading providers (docs/model-integration/provisioning.md).

Each report must come from bytes the process verified, never from a pin, and must be empty when
the provider cannot load (so nothing claims weights it would not use)."""

from __future__ import annotations

import hashlib
import types

from frwhoop_inference.frwhoop_sleep.registry_adapter import RegistryShim
from frwhoop_inference.sensor_biomarkers import optional
from frwhoop_inference.sensor_biomarkers.paradigma import provider as paradigma
from frwhoop_inference.sensor_biomarkers.rhythm import provider as rhythm


class _SleepProvider:
    provider_id = "sleep.fake.v1"
    metric = "sleep_stage"
    mode = "retrospective"
    label_space = "x"
    required_signals = ()

    def __init__(self, report):
        self.report = report

    def readiness(self):
        return self.report


def test_sleep_shim_reports_the_provenance_its_readiness_measured():
    shim = RegistryShim(_SleepProvider({"ready": True, "reason": None,
                                        "provenance": {"zip_sha256": "aa", "model_sha256": "bb"}}))
    assert shim.loaded_identity() == {}  # nothing measured before the first check
    assert shim.readiness() == (True, None)
    assert shim.loaded_identity() == {"zip_sha256": "aa", "model_sha256": "bb"}


def test_sleep_shim_reports_nothing_when_the_check_failed():
    shim = RegistryShim(_SleepProvider({"ready": False, "reason": "artifact_mismatch: x",
                                        "provenance": {"zip_sha256": "aa"}}))
    shim.readiness()
    assert shim.loaded_identity() == {}


def test_paradigma_reports_nothing_while_disabled(monkeypatch):
    monkeypatch.delenv(paradigma.ENABLE_FLAG, raising=False)
    assert paradigma.loaded_identity() == {}


def test_paradigma_reports_the_verified_asset_digests(monkeypatch):
    monkeypatch.setenv(paradigma.ENABLE_FLAG, "1")
    monkeypatch.setattr(paradigma, "artifact_state", lambda: (True, None, {"tremor.pkl": "cc"}))
    assert paradigma.loaded_identity() == {"tremor.pkl.sha256": "cc"}
    monkeypatch.setattr(paradigma, "artifact_state", lambda: (False, "artifact_mismatch", {}))
    assert paradigma.loaded_identity() == {}


class _Checkpoint:
    def __init__(self, path, ready=True):
        self.checkpoint_path = path
        self._ready = ready

    def readiness(self):
        return (True, None) if self._ready else (False, "artifact_mismatch")


def test_rhythm_digest_is_measured_from_the_bytes(tmp_path):
    weights = tmp_path / "deepbeat.h5"
    weights.write_bytes(b"real weight bytes")
    adapters = {"deepbeat": lambda _path: _Checkpoint(str(weights)),
                "siamaf": lambda _path: _Checkpoint(str(weights), ready=False)}
    got = rhythm.loaded_identity(model_root=str(tmp_path), deepbeat_enabled=True,
                                 siamaf_enabled=True, model_adapters=adapters)
    assert got == {"deepbeat.sha256": hashlib.sha256(b"real weight bytes").hexdigest()}
    assert rhythm.loaded_identity(model_root=str(tmp_path), deepbeat_enabled=False,
                                  siamaf_enabled=False, model_adapters=adapters) == {}


def test_the_optional_seam_prefixes_reports_and_survives_a_broken_one():
    good = types.SimpleNamespace(FAMILIES=paradigma.FAMILIES,
                                 adapter_state=lambda: optional.make_state("paradigma", "ready"),
                                 compute_family_documents=lambda *a, **k: {},
                                 loaded_identity=lambda: {"tremor.pkl.sha256": "dd"})

    def explode():
        raise RuntimeError("boom")

    bad = types.SimpleNamespace(FAMILIES=rhythm.FAMILIES,
                                adapter_state=lambda: optional.make_state("rhythm", "ready"),
                                compute_family_documents=lambda *a, **k: {},
                                loaded_identity=explode)
    got = optional.optional_loaded_identity({"paradigma": good, "rhythm": bad})
    assert got["paradigma.tremor.pkl.sha256"] == "dd"
    assert "boom" in got["rhythm.error"]
    silent = types.SimpleNamespace(FAMILIES=rhythm.FAMILIES,
                                   adapter_state=lambda: optional.make_state("rhythm", "ready"),
                                   compute_family_documents=lambda *a, **k: {})
    assert optional.optional_loaded_identity({"paradigma": good, "rhythm": silent}) == {
        "paradigma.tremor.pkl.sha256": "dd"}
