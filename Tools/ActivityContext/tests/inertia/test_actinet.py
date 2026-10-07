"""ActiNet encoder: identity, pinning, verify-on-load failures, seal promotion (real weights optional)."""

import os

import numpy as np
import pytest

from activity_context.inertia import actinet, registry
from activity_context.inertia.bundle import promotable
from activity_context.inertia.contract import InertiaUnavailable, make_info

torch = pytest.importorskip("torch")


def _info(eid=actinet.C24_ID, kind="actinet", sha=None):
    return make_info(encoder_id=eid, kind=kind, config={"x": 1}, embedding_dim=1024, window_s=30,
                     extraction_point="t", checkpoint_sha256=sha or actinet.WEIGHTS[actinet.C24_ID]["sha256"])


def test_ids_kinds_and_wire_kind():
    assert _info().production_eligible and _info().wire_kind == "actinet"
    assert not _info(sha="ab" * 32).production_eligible and _info(sha="ab" * 32).wire_kind == "standin"
    # pinned for the other ActiNet id: not eligible under this one
    assert not _info(eid=actinet.UKB_ID).production_eligible
    with pytest.raises(ValueError):
        _info(kind="inertia1")
    with pytest.raises(ValueError):
        make_info(encoder_id="standin:x", kind="actinet", config={}, embedding_dim=1, window_s=30, extraction_point="t")


def test_pins_match_weights_table():
    for eid, w in actinet.WEIGHTS.items():
        assert registry.is_pinned(w["sha256"], eid)


def test_missing_and_mismatched_weights(tmp_path, monkeypatch):
    monkeypatch.delenv(actinet.ENV_CKPT, raising=False)
    with pytest.raises(InertiaUnavailable) as ei:
        registry.build_encoder(actinet.C24_ID)
    assert ei.value.kind == "model_missing"
    with pytest.raises(InertiaUnavailable) as ei:
        registry.build_encoder(actinet.C24_ID, ckpt_path=str(tmp_path))
    assert ei.value.kind == "model_missing"
    from activity_context.inertia.vendor.ssl_wearables_resnet import harnet30_feature_extractor
    p = tmp_path / actinet.WEIGHTS[actinet.C24_ID]["file"]
    torch.save(harnet30_feature_extractor().state_dict(), p)
    with pytest.raises(InertiaUnavailable) as ei:
        registry.build_encoder(actinet.C24_ID, ckpt_path=str(tmp_path))
    assert ei.value.kind == "checkpoint_mismatch"
    with pytest.raises(InertiaUnavailable) as ei:
        registry.build_encoder(actinet.C24_ID, ckpt_path=str(tmp_path), window_s=10)
    assert ei.value.kind == "config_mismatch"


def _manifest(**kw):
    w = actinet.WEIGHTS[actinet.C24_ID]
    m = {"evidence_tier_max": "shadow",
         "encoder": {"encoder_id": actinet.C24_ID, "checkpoint_sha256": w["sha256"]},
         "files": {"label_mappings.json": "0" * 64, "split_manifest.json": "0" * 64},
         "training": {"git_commit": "abc", "tools_activity_context_dirty": False, "source_dirty": False,
                      "allow_dirty": False}}
    for k, v in kw.items():
        m[k] = v
    return m


def test_promotion_rule():
    assert promotable(_manifest())
    assert not promotable(_manifest(evidence_tier_max="offline"))
    assert not promotable(_manifest(training={"git_commit": "abc", "tools_activity_context_dirty": True}))
    assert not promotable(_manifest(files={}))
    assert not promotable(_manifest(encoder={"encoder_id": "standin:handcrafted-stats-v1", "checkpoint_sha256": None}))
    assert not promotable(_manifest(encoder={"encoder_id": actinet.UKB_ID,
                                             "checkpoint_sha256": actinet.WEIGHTS[actinet.C24_ID]["sha256"]}))


@pytest.mark.skipif(not os.environ.get(actinet.ENV_CKPT), reason="set ACTINET_CKPT_PATH to the pinned weights dir")
def test_real_weights_embed():
    for eid in actinet.WEIGHTS:
        enc = registry.build_encoder(eid)
        assert enc.info.wire_kind == "actinet" and enc.info.embedding_dim == 1024
        x = np.zeros((5, 3, 600), np.float32)
        x[:, 2] = 1.0
        e = enc.embed(x)
        assert e.shape == (5, 1024) and np.isfinite(e).all()
        np.testing.assert_allclose(enc.embed(x[:2]), e[:2], atol=1e-4)
