"""Regression tests for train.py persisting REAL per-window timestamps.

Audit WS-07-F03: eval_data.npz had no time axis, so evaluate.py fabricated
i*HOP_SECONDS spacing and could not measure real latency or detect real gaps.
These tests pin the contract: every piece carries its real WISDM start
(``Block.t0_ns``), ``window_start_times`` emits per-window unix-second starts in
``windows_from_blocks`` order, and the smoke pipeline persists ``starts`` +
``sessions`` in every npz artifact.
"""

import os

import numpy as np
import pytest

from activity_context import train


@pytest.fixture(scope="module")
def blocks(tmp_path_factory):
    wisdm_dir = train.write_synthetic_wisdm(str(tmp_path_factory.mktemp("wisdm")))
    subjects = train.wisdm_loader.available_subjects(wisdm_dir, list(range(1600, 1651)))
    out, _ = train.load_all_blocks(wisdm_dir, subjects[:1])
    assert len(out) >= 2
    return out


def test_blocks_carry_real_start(blocks):
    for b in blocks:
        assert b.t0_ns > 0


def test_window_start_times_real_starts(blocks):
    x, _, _, sess = train.windows_from_blocks(blocks, 120, 60)
    starts = train.window_start_times(blocks, 120, 60)
    assert x.shape[0] == len(starts) == len(sess)
    assert np.isfinite(starts).all()
    # Within a piece, consecutive windows are exactly 2 s apart (60 samples at 30 Hz).
    for s_idx in np.unique(sess):
        m = sess == s_idx
        assert np.allclose(np.diff(starts[m]), 2.0, atol=1e-6)


def test_smoke_pipeline_persists_timestamps_and_sessions(tmp_path):
    out = str(tmp_path / "out")
    rc = train.main(["--smoke", "--out", out])
    assert rc == 0
    for name in ("train_data.npz", "val_data.npz", "eval_data.npz"):
        z = np.load(os.path.join(out, name), allow_pickle=True)
        assert "starts" in z and "sessions" in z and "subjects" in z
        assert z["starts"].shape == (z["X"].shape[0],)
        assert z["starts"].dtype == np.float64
        assert np.isfinite(z["starts"]).all()
        for s_idx in np.unique(z["sessions"]):
            assert np.all(np.diff(z["starts"][z["sessions"] == s_idx]) > 0)
    z = np.load(os.path.join(out, "eval_data.npz"), allow_pickle=True)
    for key in ("y_ontology", "y", "letters"):
        assert key in z


def test_manifest_deps_record_pinned_model_env(tmp_path):
    out = str(tmp_path / "out")
    train.main(["--smoke", "--out", out])
    import json
    with open(os.path.join(out, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    deps = manifest["deps"]
    assert deps["datasets"] == "2.14.4"
    assert deps["pyarrow"] == "14.0.1"
    assert deps["numpy"] == "1.26.4"
