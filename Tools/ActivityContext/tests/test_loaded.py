"""The measured ``loaded`` identity every serve process reports (loaded.py, docs/model-integration/activity-authority.md):
only what was actually loaded, each digest read from the bytes, a digest over the map the worker can recompute, and
the same digest on every HART answer."""

import hashlib
import json
import os
import shutil

import pytest

from activity_context import loaded as L
from activity_context.preprocess import encode_columns_b64
from activity_context.serve import build_context, handle_request

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")
BASELINE = os.path.join(FIXTURES, "manifest.baseline.json")


def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def test_loaded_digest_is_the_documented_canonical_text():
    m = {"b": "2", "a": "1", "schema": L.LOADED_SCHEMA}
    text = "activity-loaded-1\na=1\nb=2\nschema=activity-loaded-1\n"
    assert L.loaded_digest(m) == hashlib.sha256(text.encode()).hexdigest()
    assert L.loaded_digest(dict(reversed(list(m.items())))) == L.loaded_digest(m)


def test_code_digest_follows_the_bytes_not_a_version(tmp_path):
    pkg = tmp_path / "pkg"
    shutil.copytree(L.PACKAGE_DIR, pkg, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    before = L.code_sha256(str(pkg))
    assert before == L.code_sha256(str(pkg)) and len(before) == 64
    (pkg / "__pycache__").mkdir(exist_ok=True)
    (pkg / "__pycache__" / "x.cpython-310.pyc").write_bytes(b"ignored")
    assert L.code_sha256(str(pkg)) == before, "byte-code caches are not code"
    target = pkg / "features.py"
    target.write_text(target.read_text() + "\n# one changed byte\n")
    assert L.code_sha256(str(pkg)) != before, "a code change under the same package version is a new identity"


def _request(seconds=8):
    import numpy as np
    cols = [np.zeros(600, dtype="<i2") for _ in range(seconds)]
    for c in cols:
        c[200:300] = 4096  # az = 1 g
    return {"id": "r1", "op": "infer",
            "run": {"start_ts": 1_760_000_000, "end_ts": 1_760_000_000 + seconds, "sample_rate_hz": 100,
                    "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"],
                    "units": {"accel": "g", "gyro": "deg/s"},
                    "columns_b64": [encode_columns_b64(c) for c in cols]}}


def test_baseline_reports_what_it_loaded_and_nothing_else():
    ctx = build_context(BASELINE, None)
    ping = handle_request(ctx, {"id": "p", "op": "ping"})
    loaded = ping["loaded"]
    assert loaded["schema"] == "activity-loaded-1" and loaded["model_kind"] == "baseline"
    assert loaded["manifest_sha256"] == _sha(BASELINE)
    assert loaded["code_sha256"] == L.code_sha256()
    for absent in ("checkpoint_sha256", "config_sha256", "transition_sha256", "gait_weights_digest", "threads"):
        assert absent not in loaded, absent
    assert ping["loaded_digest"] == L.loaded_digest(loaded)
    infer = handle_request(ctx, _request())
    assert infer["ok"] and infer["loaded_digest"] == ping["loaded_digest"]
    # A default (no-manifest) process says so instead of naming a file.
    assert build_context(None, None).loaded["manifest_sha256"] == "default"


def test_another_manifest_is_another_identity(tmp_path):
    other = tmp_path / "manifest.json"
    doc = json.loads(open(BASELINE).read())
    other.write_text(json.dumps(doc, indent=1))  # same content, other bytes
    a, b = build_context(BASELINE, None), build_context(str(other), None)
    assert a.loaded["manifest_sha256"] != b.loaded["manifest_sha256"]
    assert a.loaded_digest != b.loaded_digest


def test_hart_checkpoint_digest_is_measured():
    ckpt = os.environ.get("ACTIVITY_HART_CHECKPOINT")
    if not ckpt or not os.path.isdir(ckpt):
        pytest.skip("set ACTIVITY_HART_CHECKPOINT to a HART model dir (manifest.json, config.json, model.safetensors)")
    pytest.importorskip("torch")
    manifest = os.path.join(ckpt, "manifest.json")
    if not os.path.isfile(manifest):
        manifest = os.path.join(FIXTURES, "manifest.hart.example.json")
    ctx = build_context(manifest, ckpt, threads=1)
    assert ctx.model_status == "hart_loaded", ctx.model_error
    assert ctx.loaded["checkpoint_sha256"] == _sha(os.path.join(ckpt, "model.safetensors"))
    assert ctx.loaded["config_sha256"] == _sha(os.path.join(ckpt, "config.json"))
    assert ctx.loaded["model_kind"] == "hart" and ctx.loaded["threads"] == "1"
    import torch
    assert torch.get_num_threads() == 1 and torch.get_num_interop_threads() == 1


def test_probe_child_env_is_allowlisted_and_capped(monkeypatch):
    from activity_context.resources import child_env
    monkeypatch.setenv("FRWHOOP_DB_URL", "postgres://u:p@h/db")
    monkeypatch.setenv("OMP_NUM_THREADS", "8")
    env = child_env(1)
    assert "FRWHOOP_DB_URL" not in env
    assert env["OMP_NUM_THREADS"] == "1" and env["OPENBLAS_NUM_THREADS"] == "1" and env["MKL_NUM_THREADS"] == "1"
    assert child_env(None)["OMP_NUM_THREADS"] == "8", "uncapped passes the parent's own setting through"
