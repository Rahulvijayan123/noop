"""Inertia1Encoder tests (spec §21.2) on seeded random-init test checkpoints (never real weights)."""

import json
import os

import numpy as np
import pytest

torch = pytest.importorskip("torch")
pytest.importorskip("scipy")

from activity_context.inertia.adapter import ENV_CKPT, Inertia1Encoder, make_test_checkpoint  # noqa: E402
from activity_context.inertia.contract import EncoderInputError, InertiaUnavailable, sha256_file  # noqa: E402
from activity_context.inertia.encoder_config import encoder_id_for, expected_arch  # noqa: E402

from ._helpers import tiny_art  # noqa: E402


def _x(b=4, window_s=30, seed=0):
    x = np.random.default_rng(seed).normal(0, 0.3, size=(b, 3, window_s * 20)).astype(np.float32)
    x[:, 2] += 1.0
    return x


def _refuses(kind, *args, **kw):
    with pytest.raises(InertiaUnavailable) as ei:
        Inertia1Encoder(*args, **kw)
    assert ei.value.kind == kind, str(ei.value)
    return ei.value


def _repin(cfg, path):
    cfg = json.loads(json.dumps(cfg))
    cfg["checkpoint"].update(sha256=sha256_file(path), size=os.path.getsize(path))
    return cfg


@pytest.mark.parametrize("method", ["ar_transformer", "patchtst"])
@pytest.mark.parametrize("window_s", [30, 10])
def test_valid_load_tiny(tmp_path, method, window_s):
    path, cfg = tiny_art(tmp_path, window_s=window_s, method=method)
    enc = Inertia1Encoder(path, cfg)
    assert enc.info.kind == "standin" and enc.info.wire_kind == "standin"
    assert enc.info.checkpoint_sha256 == cfg["checkpoint"]["sha256"]
    assert enc.embed(_x(3, window_s)).shape == (3, 16)


def test_valid_load_small_preset_with_real_style_id(tmp_path):
    path = os.path.join(tmp_path, "art_small.ckpt")
    cfg = make_test_checkpoint(path, "ar_transformer", "small", 30, 0,
                               encoder_id=encoder_id_for("ar_transformer", "small", 30))
    enc = Inertia1Encoder(path, cfg)
    assert enc.info.kind == "inertia1"                     # id family
    assert not enc.info.production_eligible and enc.info.wire_kind == "standin"   # not pinned
    assert enc.info.embedding_dim == 512 and enc.embed(_x(2)).shape == (2, 512)
    assert enc.info.upstream_commit == cfg["inertia_repo_commit"]


def test_env_fallback_and_missing_checkpoint(tmp_path, monkeypatch):
    path, cfg = tiny_art(tmp_path)
    monkeypatch.delenv(ENV_CKPT, raising=False)
    _refuses("model_missing", None, cfg)
    _refuses("model_missing", os.path.join(tmp_path, "nope.ckpt"), cfg)
    monkeypatch.setenv(ENV_CKPT, path)
    assert Inertia1Encoder(None, cfg).info.checkpoint_sha256 == cfg["checkpoint"]["sha256"]
    _refuses("model_missing", path, os.path.join(tmp_path, "missing-encoder.json"))


def test_wrong_hash_or_size_refuses(tmp_path):
    path, cfg = tiny_art(tmp_path)
    bad = json.loads(json.dumps(cfg))
    bad["checkpoint"]["sha256"] = "0" * 64
    _refuses("checkpoint_mismatch", path, bad)
    data = bytearray(open(path, "rb").read())
    data[len(data) // 2] ^= 0xFF
    open(path, "wb").write(bytes(data))                    # same size, different bytes
    _refuses("checkpoint_mismatch", path, cfg)
    open(path, "ab").write(b"x")
    _refuses("checkpoint_mismatch", path, cfg)


def test_unloadable_file_with_matching_hash_refuses(tmp_path):
    path, cfg = tiny_art(tmp_path)
    open(path, "wb").write(b"not a checkpoint" * 10)
    _refuses("checkpoint_mismatch", path, _repin(cfg, path))


def test_wrong_preset_refuses(tmp_path):
    path, cfg = tiny_art(tmp_path)
    small = make_test_checkpoint(os.path.join(tmp_path, "s.ckpt"), "ar_transformer", "small", 30, 0)
    claim_small = _repin(dict(small, checkpoint=dict(small["checkpoint"])), path)  # small config, tiny bytes
    _refuses("config_mismatch", path, claim_small)


def test_wrong_family_refuses(tmp_path):
    path, _ = tiny_art(tmp_path)
    ptst = make_test_checkpoint(os.path.join(tmp_path, "p.ckpt"), "patchtst", "tiny", 30, 0)
    _refuses("config_mismatch", path, _repin(ptst, path))


def test_patchtst_wrong_window_refuses(tmp_path):
    path, cfg = tiny_art(tmp_path, method="patchtst", window_s=30)
    cfg10 = make_test_checkpoint(os.path.join(tmp_path, "p10.ckpt"), "patchtst", "tiny", 10, 0)
    err = _refuses("config_mismatch", path, _repin(cfg10, path))
    assert "W_pos" in str(err)


def test_art_window_mismatch_caught_by_config_equality(tmp_path):
    path, cfg = tiny_art(tmp_path, window_s=30)
    pre10 = {"window_s": 10, "rate_hz": 20, "axes": ["ax", "ay", "az"]}
    _refuses("config_mismatch", path, cfg, expected_preprocessing=pre10)
    pre30 = dict(pre10, window_s=30)
    assert Inertia1Encoder(path, cfg, expected_preprocessing=pre30).info.input_contract.window_s == 30


def test_custom_arch_checkpoint_refuses_under_a_preset_config(tmp_path):
    path = os.path.join(tmp_path, "c.ckpt")
    custom = make_test_checkpoint(path, "ar_transformer", {"d_ff": 64}, 30, 0)
    _refuses("config_mismatch", path, custom)                          # preset "custom" never validates
    tiny = make_test_checkpoint(os.path.join(tmp_path, "t.ckpt"), "ar_transformer", "tiny", 30, 0)
    _refuses("config_mismatch", path, _repin(tiny, path))              # shapes differ from tiny


@pytest.mark.parametrize("mutate", [
    lambda c: c.update(unknown_key=1),
    lambda c: c["arch"].update(d_ff=33),
    lambda c: c.update(encoder_id="inertia-1/ar_transformer-tiny/30s@20hz"),
    lambda c: c.update(method="patchtst"),
    lambda c: c.update(inertia_repo_commit="0" * 40),
    lambda c: c.update(embedding_dim=17),
    lambda c: c["data"].update(hz=25),
    lambda c: c["data"].update(window_sec=20),
    lambda c: c["input_contract"].update(normalization="zscore"),
    lambda c: c.update(schema="nara.inertia.encoder/2"),
    lambda c: c["arch"].update(dropout=0.1),
])
def test_config_validation_refuses(tmp_path, mutate):
    path, cfg = tiny_art(tmp_path)
    bad = json.loads(json.dumps(cfg))
    mutate(bad)
    _refuses("config_mismatch", path, bad)


def test_weight_content_checks(tmp_path):
    path, cfg = tiny_art(tmp_path)
    blob = torch.load(path, weights_only=True)
    for name, fn in (("nan", lambda sd: sd["patch_proj.weight"].fill_(float("nan"))),
                     ("pe", lambda sd: sd["pos_encoder.pe"].add_(0.01)),
                     ("fp16", lambda sd: sd.__setitem__("head.bias", sd["head.bias"].half())),
                     ("extra", lambda sd: sd.__setitem__("channel_adapter.weight", torch.zeros(3))),
                     ("missing", lambda sd: sd.pop("head.weight"))):
        sd = {k: v.clone() for k, v in blob["state_dict"].items()}
        fn(sd)
        p = os.path.join(tmp_path, f"{name}.ckpt")
        torch.save({"state_dict": sd}, p)
        _refuses("config_mismatch", p, _repin(cfg, p))


def test_raw_state_dict_without_lightning_wrapper_loads(tmp_path):
    path, cfg = tiny_art(tmp_path)
    p = os.path.join(tmp_path, "raw.ckpt")
    torch.save(torch.load(path, weights_only=True)["state_dict"], p)
    a = Inertia1Encoder(p, _repin(cfg, p)).embed(_x())
    assert np.array_equal(a, Inertia1Encoder(path, cfg).embed(_x()))


def test_deterministic_batched_frozen(tmp_path):
    path, cfg = tiny_art(tmp_path, method="patchtst")
    enc = Inertia1Encoder(path, cfg, max_batch=3)
    x = _x(7)
    a, b = enc.embed(x), enc.embed(x)
    assert np.array_equal(a, b) and a.dtype == np.float32
    one = np.concatenate([enc.embed(x[i:i + 1]) for i in range(7)])
    assert np.abs(one - a).max() <= 1e-5
    assert a.shape[1] == enc.info.embedding_dim == expected_arch("patchtst", "tiny")["d_model"]
    assert not any(m.training for m in enc.module.modules())
    assert not any(p.requires_grad for p in enc.module.parameters())
    assert torch.get_num_threads() == 1 and enc.threads == 1
    with torch.inference_mode():
        out = enc.module.encode(torch.from_numpy(x))
    assert not out.requires_grad


def test_embed_input_contract(tmp_path):
    path, cfg = tiny_art(tmp_path)
    enc = Inertia1Encoder(path, cfg)
    for bad in (_x().astype(np.float64), _x(window_s=10), np.zeros((2, 3, 600)), "x"):
        with pytest.raises(EncoderInputError):
            enc.embed(bad)
    x = _x()
    x[0, 0, 0] = np.inf
    with pytest.raises(EncoderInputError):
        enc.embed(x)
    assert enc.embed(np.zeros((0, 3, 600), np.float32)).shape == (0, 16)


def test_cuda_device_refused(tmp_path):
    path, cfg = tiny_art(tmp_path)
    _refuses("config_mismatch", path, cfg, device="cuda")
