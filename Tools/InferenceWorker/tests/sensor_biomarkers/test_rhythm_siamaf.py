"""SiamAF shadow adapter tests (real weights).

Covers spec 6.7 / section 10.4: strict checkpoint load with verified prefix
handling, the two-argument single-source wrapper, input shape, finite logits,
CPU reproducibility, and the source-verified preprocessing. No ``strict=False``
is ever used; the learned network is never modified to hide the forward/example
discrepancy. Flat/missing/short/mixed-channel/unverified-clock input can never
become a normal classification.
"""

from __future__ import annotations

pytest_plugins = ["rhythm_fixtures"]

import os

import numpy as np
import pytest

from frwhoop_inference.sensor_biomarkers.rhythm._common import parse_ppg_payload
from frwhoop_inference.sensor_biomarkers.rhythm.provider import (
    compute_rhythm_shadow_document,
)
from frwhoop_inference.sensor_biomarkers.rhythm.siamaf import (
    ARTIFACT_RELPATH,
    INPUT_SAMPLES,
    RHYTHM_CLASSES,
    SEGMENT_SECONDS,
    SiamAFAdapter,
)

from rhythm_helpers import family_request, ppg_payload


def _adapter(root: str) -> SiamAFAdapter:
    return SiamAFAdapter(os.path.join(root, ARTIFACT_RELPATH))


def test_strict_checkpoint_load_with_verified_prefix(rhythm_model_root):
    """The real checkpoint loads with weights_only=True, the verified leading
    module. prefix is stripped (all-or-nothing), and load_state_dict is strict:
    no missing and no unexpected keys."""
    import torch

    adapter = _adapter(rhythm_model_root)
    ok, why = adapter.readiness()
    assert ok, why
    model = adapter._load_model()
    assert adapter.loaded_sha256 is not None
    # the wrapped model is the vendored single-source Res34SimSiam
    assert model.single_source_mode is True
    assert model.classification_head.out_features == 2
    assert model.predictor[0].out_features == 128  # pred_dim=128
    # weights were loaded strictly: every one of the 186 checkpoint keys is
    # present in the wrapped model (no missing, no unexpected)
    sd = model.state_dict()
    assert len(sd) == 186
    # sanity: encoder conv0 has the learned 48x1x80 kernel
    assert tuple(sd["encoder.conv0.weight"].shape) == (48, 1, 80)
    # prefix handling: all-or-nothing. A mixed prefix is rejected (never
    # silently dropped); a bare (unprefixed) dict is accepted untouched.
    original = torch.load(os.path.join(rhythm_model_root, ARTIFACT_RELPATH),
                          map_location="cpu", weights_only=True)
    stripped = SiamAFAdapter._strip_prefix(dict(original))
    assert all(not k.startswith("module.") for k in stripped)
    mixed = dict(stripped)
    mixed["module.extra"] = torch.zeros(1)
    with pytest.raises(ValueError, match="mixed"):
        SiamAFAdapter._strip_prefix(mixed)
    assert SiamAFAdapter._strip_prefix(dict(stripped)) == stripped


def test_two_argument_wrapper_passes_unused_second_argument(rhythm_model_root):
    """The pinned forward takes TWO arguments even in single-source mode; the
    wrapper passes the unused second argument explicitly and never rewrites the
    learned network."""
    import torch

    adapter = _adapter(rhythm_model_root)
    model = adapter._load_model()
    assert model.forward.__code__.co_argcount == 3  # (self, ECG, PPG)
    x = torch.zeros(1, 1, INPUT_SAMPLES)
    with torch.inference_mode():
        out = model(x, x)  # explicit second argument
    assert len(out) == 3
    logits = out[2]
    assert tuple(logits.shape) == (1, 2)


def test_input_shape_and_finite_reproducible_logits(rhythm_model_root):
    """(batch, 1, 2400) in -> two logits out; finite and bit-reproducible on
    CPU."""
    adapter = _adapter(rhythm_model_root)
    ppg = parse_ppg_payload(ppg_payload(samples_per_segment=7200))  # 300 s -> 10 x 30 s
    result = adapter.infer(ppg)
    assert result["status"] == "ok"
    assert result["windows"] == 10
    logits = np.asarray(result["rhythm"]["scores"])
    assert logits.shape == (10, 2)
    assert np.isfinite(logits).all()
    assert result["rhythm"]["classes"] == RHYTHM_CLASSES
    assert result["rhythm"]["preprocessing_status"] == "verified_from_source"
    assert result["rhythm"]["domain_status"] == "native_rate_mismatch"
    assert result["rhythm"]["publishable"] is False
    again = adapter.infer(ppg)
    assert again["rhythm"]["scores"] == result["rhythm"]["scores"]


def test_real_sample_fixture_runs(rhythm_model_root):
    """The upstream sample_ppg.npy fixture (real, already min-max normalised)
    feeds the model through the exact source preparation path."""
    upstream_fixture = "/tmp/frwhoop-sensor-biomarkers/SiamAF/sample_ppg.npy"
    if not os.path.isfile(upstream_fixture):
        pytest.skip("upstream sample_ppg.npy not present")
    samples = np.load(upstream_fixture).astype(np.float32)
    assert samples.shape == (INPUT_SAMPLES,)
    assert samples.min() >= 0.0 and samples.max() <= 1.0
    adapter = _adapter(rhythm_model_root)
    logits = adapter._classify(samples)
    assert logits.shape == (2,)
    assert np.isfinite(logits).all()


def test_preprocessing_matches_source_pipeline(rhythm_model_root):
    """The adapter's PPG preparation is the source pipeline
    (make_whole_data.py: scipy.signal.resample to 2400 + per-segment min-max),
    checked against an independent re-implementation."""
    from scipy.signal import resample

    rng = np.random.default_rng(11)
    raw = 900.0 + 200.0 * np.sin(2 * np.pi * 1.0 * np.arange(720) / 24.0) + rng.normal(0, 3, 720)
    adapter = _adapter(rhythm_model_root)
    got = adapter.preprocess_window(raw.astype(np.float32), 24.0)
    expected = resample(raw, INPUT_SAMPLES)
    expected = (expected - expected.min()) / (expected.max() - expected.min())
    assert got.shape == (1, INPUT_SAMPLES)
    assert np.allclose(got[0], expected.astype(np.float32), atol=1e-6)


def test_flat_segment_withheld(rhythm_model_root):
    doc = compute_rhythm_shadow_document(
        family_request(ppg_payload(samples_per_segment=7200, waveform="flat")),
        model_root=rhythm_model_root, deepbeat_enabled=False, siamaf_enabled=True)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "not_enough_valid_data"
    assert doc["measurements"] == {}


def test_short_and_missing_input_withheld(rhythm_model_root):
    # 10 s at 24 Hz: no full 30 s window
    doc = compute_rhythm_shadow_document(
        family_request(ppg_payload(samples_per_segment=240)),
        model_root=rhythm_model_root, deepbeat_enabled=False, siamaf_enabled=True)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "not_enough_valid_data"
    # missing ppg entirely
    doc = compute_rhythm_shadow_document(
        {"families": ["rhythm_shadow"]},
        model_root=rhythm_model_root, deepbeat_enabled=False, siamaf_enabled=True)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "artifact_unavailable"


def test_unverified_clock_withheld(rhythm_model_root):
    doc = compute_rhythm_shadow_document(
        family_request(ppg_payload(samples_per_segment=7200, stable=False)),
        model_root=rhythm_model_root, deepbeat_enabled=False, siamaf_enabled=True)
    assert doc["status"] == "withheld"
    assert doc["reason"] == "unverified_sample_clock"


def test_siamaf_scores_are_shadow_measurements(rhythm_model_root):
    """SiamAF preprocessing is verified from source, so its scores appear as a
    family measurement (still nonpublishable shadow content)."""
    doc = compute_rhythm_shadow_document(
        family_request(ppg_payload(samples_per_segment=7200)),
        model_root=rhythm_model_root, deepbeat_enabled=False, siamaf_enabled=True)
    assert doc["status"] == "ok"
    assert doc["release_tier"] == "shadow"
    m = doc["measurements"]["siamaf_rhythm_scores"]
    assert m["publishable"] is False
    assert m["preprocessing_status"] == "verified_from_source"
    assert len(m["scores"]) == 10
