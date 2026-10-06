"""Regression tests for train.py persisting REAL per-window timestamps.

Audit WS-07-F03: eval_data.npz had no time axis, so evaluate.py fabricated
i*HOP_SECONDS spacing and could not measure real latency or detect real gaps.
These tests pin the new contract: Block carries the real WISDM block start,
windows_from_blocks emits per-window unix-second starts, and the smoke pipeline
persists `starts` + `sessions` in every npz artifact.
"""

import os

import numpy as np
import pytest

from activity_context import train
from activity_context.preprocess import TARGET_HZ
from activity_context.train import (Block, blocks_for_subject,
                                    resample_block, windows_from_blocks)


@pytest.fixture(scope="module")
def wisdm_dir(tmp_path_factory):
    return train.write_synthetic_wisdm(str(tmp_path_factory.mktemp("wisdm")))


def test_block_carries_real_start_ts(wisdm_dir):
    blocks = blocks_for_subject(
        os.path.join(wisdm_dir, "raw", "watch", "accel", "data_1600_accel_watch.txt"),
        os.path.join(wisdm_dir, "raw", "watch", "gyro", "data_1600_gyro_watch.txt"))
    assert len(blocks) >= 2
    for b in blocks:
        # start_ts_s == first raw WISDM ts_ns converted to seconds.
        raw = train.parse_raw_file(
            os.path.join(wisdm_dir, "raw", "watch", "accel", "data_1600_accel_watch.txt"))
        expected = float(int(raw[0][2])) / 1e9
        # Blocks are emitted in row order; the first block starts at the file's
        # first row, later blocks later.
        assert b.start_ts_s >= expected
        assert np.isfinite(b.start_ts_s)
    # Resampling preserves the real start time.
    assert resample_block(blocks[0]).start_ts_s == pytest.approx(blocks[0].start_ts_s)


def test_windows_from_blocks_real_starts(wisdm_dir):
    blocks = blocks_for_subject(
        os.path.join(wisdm_dir, "raw", "watch", "accel", "data_1600_accel_watch.txt"),
        os.path.join(wisdm_dir, "raw", "watch", "gyro", "data_1600_gyro_watch.txt"))
    blocks = [resample_block(b) for b in blocks]
    x, y, subs, sess, starts = windows_from_blocks(blocks, 120, 60)
    assert x.shape[0] == len(starts) == len(sess)
    # Within a session, consecutive windows are exactly 2 s apart (30 Hz hop).
    for s_idx in np.unique(sess):
        m = sess == s_idx
        assert np.allclose(np.diff(starts[m]), 2.0, atol=1e-9)
    # Session boundaries carry real (>=1 s) gaps; sessions are ordered.
    boundaries = np.flatnonzero(np.diff(sess) != 0)
    for bi in boundaries:
        assert starts[bi + 1] - starts[bi] > 1.0
    assert np.all(np.diff(starts) > 0)  # globally increasing, real timeline


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
        assert np.all(np.diff(z["starts"]) > 0)
    # eval_data.npz keeps y_ontology/y/letters for the evaluator.
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
