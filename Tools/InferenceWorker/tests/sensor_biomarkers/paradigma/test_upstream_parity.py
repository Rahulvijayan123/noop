"""Wrapper vs pinned upstream pipeline parity on the REAL reference fixture.

Runs the venv-side ``upstream_parity.py`` (real classifiers + vendored
upstream reference predictions at the pinned commit) and asserts the
published parity numbers.
"""

from __future__ import annotations

import json
import os
import subprocess

import pytest

from pd_fixtures import FIXTURES_DIR, TESTS_DIR, venv_python

PARITY_SCRIPT = TESTS_DIR / "upstream_parity.py"


@pytest.mark.skipif(venv_python() is None, reason="paradigma subprocess venv not available")
def test_upstream_classifier_parity():
    proc = subprocess.run(
        [venv_python(), str(PARITY_SCRIPT), str(FIXTURES_DIR)],
        capture_output=True, text=True, timeout=300)
    assert proc.returncode == 0, proc.stdout + proc.stderr[-2000:]
    result = json.loads(proc.stdout)
    assert result["ok"] is True
    assert result["errors"] == []
    tremor = result["tremor"]
    # the reference probabilities are reproduced to machine precision
    assert tremor["pred_tremor_proba"] <= 1e-6
    assert tremor["pred_tremor_logreg"] == 0.0
    assert tremor["pred_tremor_checked"] == 0.0
    assert tremor["pred_arm_at_rest"] == 0.0
    assert tremor["n"] == 182
    assert result["gait"]["max_diff"] <= 1e-6
    assert result["gait"]["n"] == 725
    assert result["arm_activity"]["max_diff"] <= 1e-6
    assert result["arm_activity"]["n"] == 50


@pytest.mark.skipif(venv_python() is None, reason="paradigma subprocess venv not available")
def test_upstream_classifier_parity_rejects_corrupt_assets(tmp_path):
    """The parity script must refuse to unpickle a tampered wheel asset."""
    from pd_fixtures import wheel_asset_bytes
    blob = bytearray(wheel_asset_bytes("tremor_detection_clf_package.pkl", venv_python()))
    blob[7] ^= 0xFF
    # corrupt a COPY of the wheel asset in a scratch asset root and point the
    # parity script's asset gate at it (PARADIGMA_ASSET_ROOT): the real venv's
    # assets are never touched, and the sha256 gate must refuse the tampered
    # bytes before anything is unpickled.
    scratch = tmp_path / "assets"
    scratch.mkdir()
    for name in ("tremor_detection_clf_package.pkl", "gait_detection_clf_package.pkl",
                 "gait_filtering_clf_package.pkl"):
        (scratch / name).write_bytes(wheel_asset_bytes(name, venv_python()))
    (scratch / "tremor_detection_clf_package.pkl").write_bytes(bytes(blob))
    env = {**os.environ, "PARADIGMA_ASSET_ROOT": str(scratch)}
    proc = subprocess.run(
        [venv_python(), str(PARITY_SCRIPT), str(FIXTURES_DIR)],
        capture_output=True, text=True, timeout=300, env=env)
    assert proc.returncode != 0
    assert "sha256" in (proc.stdout + proc.stderr)
