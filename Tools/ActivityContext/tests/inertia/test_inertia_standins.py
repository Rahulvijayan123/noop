"""Stand-in encoders and the registry: deterministic, finite, honest about not being Inertia-1."""

import numpy as np
import pytest

pytest.importorskip("scipy")

from activity_context.inertia import registry  # noqa: E402
from activity_context.inertia.contract import InertiaUnavailable  # noqa: E402
from activity_context.inertia.standins import (HANDCRAFTED_ID, IMU_FEAT_ID, IMU_FEAT_NAMES,  # noqa: E402
                                               handcrafted_feature_names)


def _walk(window_s=30, f=1.8):
    t = np.arange(window_s * 20) / 20
    return np.stack([0.3 * np.sin(2 * np.pi * f / 2 * t), 0.1 * np.sin(2 * np.pi * f * t),
                     1 + 0.25 * np.sin(2 * np.pi * f * t)]).astype(np.float32)


def _still(window_s=30):
    x = np.zeros((3, window_s * 20), np.float32)
    x[2] = 1.0
    return x


def test_handcrafted_dims_names_determinism_and_finiteness():
    enc = registry.build_encoder(HANDCRAFTED_ID)
    names = handcrafted_feature_names()
    assert len(names) == len(set(names)) == enc.info.embedding_dim == 72
    batch = np.stack([_walk(), _still(), np.zeros((3, 600), np.float32)])
    a, b = enc.embed(batch), enc.embed(batch)
    assert a.shape == (3, 72) and a.dtype == np.float32 and np.isfinite(a).all() and np.array_equal(a, b)
    f = dict(zip(names, a[0]))
    assert abs(f["mag_dominant_hz"] - 1.8) < 0.05 and f["acf_peak"] > 0.9 and f["still_fraction"] == 0.0
    assert dict(zip(names, a[1]))["still_fraction"] == 1.0 and abs(dict(zip(names, a[1]))["g_norm"] - 1) < 1e-6
    assert enc.info.kind == "standin" and not enc.info.production_eligible


def test_handcrafted_window_length_follows_contract():
    enc = registry.build_encoder(HANDCRAFTED_ID, window_s=10)
    assert enc.embed(np.stack([_walk(10)])).shape == (1, 72)
    from activity_context.inertia.contract import EncoderInputError
    with pytest.raises(EncoderInputError):
        enc.embed(np.stack([_walk(30)]))


def test_imu_feat_accel():
    enc = registry.build_encoder(IMU_FEAT_ID)
    v = enc.embed(np.stack([_walk(), _still()]))
    names = list(IMU_FEAT_NAMES)
    walk, still = dict(zip(names, v[0])), dict(zip(names, v[1]))
    assert walk["cadence_present"] == 1.0 and abs(walk["cadence_hz"] - 1.8) < 0.1
    assert still["cadence_present"] == 0.0 and still["cadence_hz"] == 0.0 and still["accel_rms_g"] == 0.0
    assert still["orientation_present"] == 1.0 and still["orientation_change_deg"] == 0.0


def test_registry_specs_and_failures():
    with pytest.raises(InertiaUnavailable) as ei:
        registry.build_encoder("standin:does-not-exist")
    assert ei.value.kind == "config_mismatch"
    with pytest.raises(InertiaUnavailable) as ei:
        registry.build_encoder("inertia-1/ar_transformer-small/30s@20hz")
    assert ei.value.kind == "model_missing"
    assert not any(e["encoder_id"].startswith("inertia-1/") for e in registry.PINNED_CHECKPOINTS.values())


def test_random_init_standin_is_seeded():
    torch = pytest.importorskip("torch")
    spec = "standin:inertia-arch-random-init/ar_transformer-tiny/seed{}"
    x = np.stack([_walk(), _still()])
    a = registry.build_encoder(spec.format(1)).embed(x)
    b = registry.build_encoder(spec.format(1)).embed(x)
    c = registry.build_encoder(spec.format(2)).embed(x)
    assert np.array_equal(a, b) and not np.allclose(a, c)
    enc = registry.build_encoder(spec.format(1))
    assert enc.info.kind == "standin" and enc.info.checkpoint_sha256 is None and not enc.info.production_eligible
    state = torch.random.get_rng_state()
    registry.build_encoder(spec.format(3))
    assert torch.equal(state, torch.random.get_rng_state())             # global RNG untouched
    with pytest.raises(InertiaUnavailable):
        registry.build_encoder("standin:inertia-arch-random-init/ar_transformer-huge/seed0")
