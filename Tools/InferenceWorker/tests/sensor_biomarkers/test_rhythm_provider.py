"""Rhythm provider wiring and fail-closed gates.

These tests do NOT require real weights: they verify that the rhythm shadow
lane is disabled by default, answers ``not_ready``/``artifact_unavailable``
without touching anything else, imports lazily (no keras/torch at import
time), and never breaks the other providers' readiness. Real-weight behaviour
is covered in test_rhythm_deepbeat.py / test_rhythm_siamaf.py.
"""

from __future__ import annotations

pytest_plugins = ["rhythm_fixtures"]

import os

import pytest

from frwhoop_inference.providers import ProviderRegistry, default_providers
from frwhoop_inference.sensor_biomarkers.rhythm import make_providers
from frwhoop_inference.sensor_biomarkers.rhythm.provider import (
    ENABLE_DEEPBEAT,
    ENABLE_SIAMAF,
    PROVIDER_ID,
    RhythmProvider,
    compute_rhythm_shadow_document,
)

from rhythm_helpers import family_request, ppg_payload


@pytest.fixture
def clear_flags(monkeypatch):
    monkeypatch.delenv(ENABLE_DEEPBEAT, raising=False)
    monkeypatch.delenv(ENABLE_SIAMAF, raising=False)
    return None


def test_flags_off_by_default(clear_flags):
    doc = compute_rhythm_shadow_document(family_request(ppg_payload(samples_per_segment=7200)))
    assert doc is not None
    assert doc["status"] == "withheld"
    assert doc["reason"] == "not_ready"


def test_not_requested_returns_none(clear_flags):
    request = family_request(ppg_payload(samples_per_segment=7200), families=["movement"])
    assert compute_rhythm_shadow_document(request) is None


def test_flag_must_be_exactly_one(monkeypatch):
    request = family_request(ppg_payload(samples_per_segment=7200))
    for value in ("1 ", "true", "True", "yes", "01"):
        monkeypatch.setenv(ENABLE_DEEPBEAT, str(value))
        doc = compute_rhythm_shadow_document(request, model_root="/nonexistent")
        assert doc["status"] == "withheld" and doc["reason"] == "not_ready"
    monkeypatch.setenv(ENABLE_DEEPBEAT, "1")
    # env flag on but no artifact under the root -> artifact_unavailable
    doc = compute_rhythm_shadow_document(request, model_root="/nonexistent")
    assert doc["status"] == "withheld"
    assert doc["reason"] == "artifact_unavailable"


def test_missing_optional_artifacts_do_not_break_other_providers(clear_flags, tmp_path,
                                                                  monkeypatch):
    """The full registry still wires when the rhythm artifacts are absent and
    the rhythm provider reports not_ready without raising."""
    empty_root = tmp_path / "root"
    empty_root.mkdir()
    monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(empty_root))
    monkeypatch.setenv(ENABLE_DEEPBEAT, "1")
    monkeypatch.setenv(ENABLE_SIAMAF, "1")
    registry = ProviderRegistry(default_providers())
    ids = [p.provider_id for p in registry.all()]
    assert PROVIDER_ID in ids
    rhythm = registry.get(PROVIDER_ID)
    assert rhythm is not None
    # An enabled-but-unprovisioned optional lane is a health signal: not ready
    # with artifact_unavailable, while every other provider stays ready.
    ready, reason = rhythm.readiness()
    assert ready is False
    assert "artifact_unavailable" in reason
    # HRV production readiness is untouched by the missing optional artifacts
    hrv = registry.get("production.runs.v1")
    assert hrv.readiness() == (True, None)


def test_disabled_lane_is_ready_by_default(clear_flags):
    """A disabled-by-default optional lane must NOT flip the process flag: the
    default deployment (no flags) has every provider ready."""
    provider = RhythmProvider()
    ready, reason = provider.readiness()
    assert ready is True and reason is None


def test_make_providers_fail_closed_without_heavy_runtimes():
    """make_providers() must not import keras or torch (lazy runtime).

    Runs in a fresh subprocess so popping/observing sys.modules cannot poison
    the shared pytest process (re-importing torch after a pop crashes it).
    """
    import subprocess
    import sys

    code = (
        "import sys\n"
        "from frwhoop_inference.sensor_biomarkers.rhythm import make_providers\n"
        "providers = make_providers()\n"
        "assert len(providers) == 1\n"
        "assert providers[0].provider_id == %r\n"
        "assert 'keras' not in sys.modules\n"
        "assert 'torch' not in sys.modules\n"
        "print('OK')\n" % PROVIDER_ID
    )
    result = subprocess.run([sys.executable, "-c", code], capture_output=True,
                            text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "OK"


def test_provider_standalone_infer_not_requested(clear_flags):
    request = type("Req", (), {
        "input": {"families": ["movement"]},
        "provider_id": PROVIDER_ID})()
    result = RhythmProvider().infer(request)
    assert result.status == "withheld"
    assert result.withheld_reason == "not_ready"
    assert result.stages is None


def test_provider_standalone_infer_withheld_shadow(clear_flags, rhythm_model_root):
    request = type("Req", (), {
        "input": family_request(ppg_payload(samples_per_segment=7200)), "provider_id": PROVIDER_ID})()
    result = RhythmProvider(model_root=rhythm_model_root,
                            deepbeat_enabled=True, siamaf_enabled=False).infer(request)
    assert result.status == "withheld"
    # wire envelope uses the closest enum value; the family detail reason is
    # preserved in diagnostics
    assert result.withheld_reason == "unverified"
    assert result.diagnostics["reason_detail"] == "preprocessing_unverified"
    assert result.stages is None
    assert result.raw_scores is not None
    assert "deepbeat_rhythm_scores" in result.raw_scores
    assert result.publishable is False


def test_provider_standalone_infer_ok_shadow_stage(clear_flags, rhythm_model_root):
    request = type("Req", (), {
        "input": family_request(ppg_payload(samples_per_segment=7200)), "provider_id": PROVIDER_ID})()
    result = RhythmProvider(model_root=rhythm_model_root,
                            deepbeat_enabled=False, siamaf_enabled=True).infer(request)
    assert result.status == "ok"
    assert result.label_space == "sensor_biomarkers.families/1"
    assert result.stages and len(result.stages) == 1
    stage = result.stages[0]
    assert stage["family"] == "rhythm_shadow"
    assert stage["status"] == "ok"
    assert "siamaf_rhythm_scores" in stage["measurements"]
    assert result.raw_scores is not None
    assert result.publishable is False


def test_capability_declares_shadow_eligibility(clear_flags):
    cap = RhythmProvider().capability()
    assert cap["publishable"] is False
    assert cap["mode"] == "shadow"
    assert cap["eligibility_state"] == "shadow_eligible"
    assert cap["accuracy_label"] == "unverified_accuracy"
    assert cap["release_tier"] == "shadow"
    assert "rhythm_shadow" in cap["families"]
