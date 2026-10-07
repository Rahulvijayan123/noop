"""DeepBeat shadow adapter tests (real weights).

Covers the spec 6.6 / section 10.3 requirements: real HDF5 load on the
current stack, input/output shapes, deterministic inference-only behaviour,
label mapping verified against the pinned model + original evaluation code,
and fail-closed behaviour for flat/missing/short/mixed-channel/unverified-clock
input (which can never become a normal classification). Preprocessing is
unresolved upstream, so named publishable rhythm results must be withheld with
``preprocessing_unverified``.
"""

from __future__ import annotations

pytest_plugins = ["rhythm_fixtures"]

import os

import numpy as np
import pytest

from frwhoop_inference.sensor_biomarkers.rhythm._common import parse_ppg_payload
from frwhoop_inference.sensor_biomarkers.rhythm.deepbeat import (
    ARTIFACT_RELPATH,
    INPUT_SAMPLES,
    INPUT_RATE_HZ,
    QUALITY_CLASSES,
    RHYTHM_CLASSES,
    SEGMENT_SECONDS,
    DeepBeatAdapter,
)
from frwhoop_inference.sensor_biomarkers.rhythm.provider import (
    compute_rhythm_shadow_document,
)

from rhythm_helpers import family_request, ppg_payload


def _adapter(root: str) -> DeepBeatAdapter:
    return DeepBeatAdapter(os.path.join(root, ARTIFACT_RELPATH))


def test_real_h5_loads_with_keras3_torch_and_shapes_match_contract(rhythm_model_root):
    """The real deepbeat.h5 loads in the current env (keras 3 + torch backend)
    and its heads match the documented (batch,800,1) -> (3 quality, 2 rhythm)
    contract."""
    adapter = _adapter(rhythm_model_root)
    ok, why = adapter.readiness()
    assert ok, why
    # 300 s at 24 Hz = 7200 samples -> 12 full 25 s windows of 600 samples
    result = adapter.infer(parse_ppg_payload(ppg_payload(samples_per_segment=7200)))
    assert result["status"] == "preprocessing_unverified"
    assert result["windows"] == 12
    qa = np.asarray(result["quality"]["scores"])
    rhythm = np.asarray(result["rhythm"]["scores"])
    assert qa.shape == (12, 3)
    assert rhythm.shape == (12, 2)
    assert np.isfinite(qa).all() and np.isfinite(rhythm).all()
    # quality head is softmax: rows sum to 1 within float32 tolerance
    assert np.allclose(qa.sum(axis=1), 1.0, atol=1e-6)
    # rhythm head is sigmoid: rows in [0, 1]
    assert rhythm.min() >= 0.0 and rhythm.max() <= 1.0 + 1e-6


def test_deterministic_inference_only(rhythm_model_root):
    """Repeated CPU inference on the same bytes is bit-identical, and the model
    is loaded with training disabled (compile=False, trainable=False)."""
    adapter = _adapter(rhythm_model_root)
    ppg = parse_ppg_payload(ppg_payload(samples_per_segment=7200))
    first = adapter.infer(ppg)
    second = adapter.infer(ppg)
    assert first["quality"]["scores"] == second["quality"]["scores"]
    assert first["rhythm"]["scores"] == second["rhythm"]["scores"]
    model = adapter._load_model()
    assert all(not layer.trainable for layer in model.layers)
    assert model.compiled is False or model.optimizer is None


def test_label_mapping_matches_pinned_model_and_eval_code(rhythm_model_root):
    """Quality classes poor=0/acceptable=1/excellent=2 and rhythm classes
    non-AF=0/AF=1, matching utils.py (labels [0,1]) and table_2.ipynb
    (excellent == argmax 2)."""
    assert QUALITY_CLASSES == ["poor", "acceptable", "excellent"]
    assert RHYTHM_CLASSES == ["non_af", "af"]
    adapter = _adapter(rhythm_model_root)
    ppg = parse_ppg_payload(ppg_payload(samples_per_segment=7200, seed=3))
    result = adapter.infer(ppg)
    assert result["quality"]["classes"] == QUALITY_CLASSES
    assert result["rhythm"]["classes"] == RHYTHM_CLASSES
    # The quality vector has exactly three ordered scores (softmax over the 3
    # classes); the rhythm vector exactly two ordered sigmoid scores.
    for row in result["quality"]["scores"]:
        assert len(row) == 3
    for row in result["rhythm"]["scores"]:
        assert len(row) == 2
    assert result["quality"]["samples_per_segment"] == INPUT_SAMPLES
    assert result["rhythm"]["samples_per_segment"] == INPUT_SAMPLES
    assert result["quality"]["segment_seconds"] == SEGMENT_SECONDS
    assert result["rhythm"]["native_rate_hz"] == 24.0


def test_named_publishable_rhythm_results_are_withheld_preprocessing_unverified(
        rhythm_model_root):
    """Preprocessing is unresolved upstream, so the family must be withheld
    with preprocessing_unverified and the scores only preserved as
    nonpublishable research raw_scores (never a measurement, never a normal
    result)."""
    request = family_request(ppg_payload(samples_per_segment=7200))
    doc = compute_rhythm_shadow_document(request, model_root=rhythm_model_root,
                                         deepbeat_enabled=True, siamaf_enabled=False)
    assert doc is not None
    assert doc["family"] == "rhythm_shadow"
    assert doc["status"] == "withheld"
    assert doc["reason"] == "preprocessing_unverified"
    assert doc["measurements"] == {}
    raw = doc["raw_scores"]
    assert set(raw) == {"deepbeat_quality_scores", "deepbeat_rhythm_scores"}
    for key, entry in raw.items():
        assert entry["publishable"] is False
        assert entry["preprocessing_status"] == "preprocessing_unverified"
        assert entry["domain_status"] == "tensor_compatibility_resample"
        assert entry["classes"]
        assert len(entry["scores"]) == 12


def test_flat_segment_never_becomes_a_normal_classification(rhythm_model_root):
    request = family_request(ppg_payload(samples_per_segment=7200, waveform="flat"))
    doc = compute_rhythm_shadow_document(request, model_root=rhythm_model_root,
                                         deepbeat_enabled=True, siamaf_enabled=False)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "not_enough_valid_data"
    assert doc["measurements"] == {}
    assert "raw_scores" not in doc


def test_short_segment_withheld(rhythm_model_root):
    # 12 s at 24 Hz = 288 samples: not one full 25 s window
    request = family_request(ppg_payload(samples_per_segment=288))
    doc = compute_rhythm_shadow_document(request, model_root=rhythm_model_root,
                                         deepbeat_enabled=True, siamaf_enabled=False)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "not_enough_valid_data"


def test_mixed_channel_input_rejected(rhythm_model_root):
    payload = ppg_payload(samples_per_segment=7200)
    payload["segments"][0]["samples"] = [
        [float(v), float(v)] for v in payload["segments"][0]["samples"][:1000]]
    request = family_request(payload)
    doc = compute_rhythm_shadow_document(request, model_root=rhythm_model_root,
                                         deepbeat_enabled=True, siamaf_enabled=False)
    assert doc["status"] == "error"
    assert doc["reason"] == "blocked_input"


def test_unverified_clock_withheld(rhythm_model_root):
    request = family_request(ppg_payload(samples_per_segment=7200, stable=False))
    doc = compute_rhythm_shadow_document(request, model_root=rhythm_model_root,
                                         deepbeat_enabled=True, siamaf_enabled=False)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "unverified_sample_clock"
    assert doc["measurements"] == {}


def test_sha256_rejects_modified_bytes(rhythm_model_root, tmp_path):
    """Tampering with the staged bytes must fail the readiness gate and the
    provider must never load them."""
    import shutil
    bad_root = tmp_path / "bad"
    target = bad_root / ARTIFACT_RELPATH
    target.parent.mkdir(parents=True)
    shutil.copyfile(os.path.join(rhythm_model_root, ARTIFACT_RELPATH), target)
    data = bytearray(target.read_bytes())
    data[1000] ^= 0xFF
    target.write_bytes(bytes(data))
    adapter = _adapter(str(bad_root))
    ok, why = adapter.readiness()
    assert ok is False
    assert why == "artifact_mismatch"
    doc = compute_rhythm_shadow_document(
        family_request(ppg_payload(samples_per_segment=7200)),
        model_root=str(bad_root), deepbeat_enabled=True, siamaf_enabled=False)
    assert doc["status"] == "withheld"
    # family-level reason uses the CONTRACTS vocabulary; the precise
    # adapter detail stays in the adapters summary
    assert doc["reason"] == "artifact_unavailable"
    assert doc["adapters"]["deepbeat"]["reason"] == "artifact_mismatch"
    assert doc["measurements"] == {}
    assert "raw_scores" not in doc


def test_missing_artifact_reports_artifact_unavailable(rhythm_model_root, tmp_path):
    empty_root = tmp_path / "empty"
    empty_root.mkdir()
    doc = compute_rhythm_shadow_document(
        family_request(ppg_payload(samples_per_segment=7200)),
        model_root=str(empty_root), deepbeat_enabled=True, siamaf_enabled=False)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "artifact_unavailable"
