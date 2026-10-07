"""Provisioning script: REAL asset hashes/sizes, corruption rejection, provenance."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess

import pytest

from pd_fixtures import ASSET_DIGESTS, FIXTURES_DIR, MANIFEST_ENTRY, REPO_PACKAGE_ROOT

from pd_fixtures import (manifest_with_paradigma, paradigma_env,
                          provisioned_root, real_asset_bytes,
                          venv_python_fixture)
PROVISION_SCRIPT = REPO_PACKAGE_ROOT / "scripts" / "provision_paradigma.py"


def _provision(dest, tree, env=None):
    return subprocess.run(
        [os.sys.executable, str(PROVISION_SCRIPT), "--dest", str(dest),
         "--from-tree", str(tree)],
        capture_output=True, text=True, env={**os.environ, **(env or {})})


def _fake_tree(tmp_path, bytes_by_name):
    tree = tmp_path / "tree" / "src" / "paradigma" / "assets"
    tree.mkdir(parents=True)
    for name, blob in bytes_by_name.items():
        (tree / name).write_bytes(blob)
    return tmp_path / "tree"


def test_provision_verifies_real_asset_hashes_and_sizes(
        tmp_path, real_asset_bytes, venv_python_fixture):
    """Provisioning the REAL bytes must produce the pinned sha256 + sizes."""
    if real_asset_bytes is None:
        pytest.skip("paradigma subprocess venv not available")
    tree = _fake_tree(tmp_path, real_asset_bytes)
    dest = tmp_path / "root"
    proc = _provision(dest, tree)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    for name, expected_sha in ASSET_DIGESTS.items():
        staged = dest / "paradigma" / MANIFEST_ENTRY["tag_commit"] / name
        assert staged.is_file(), staged
        assert staged.stat().st_size == len(real_asset_bytes[name])
        assert hashlib.sha256(staged.read_bytes()).hexdigest() == expected_sha
    # tremor pkl sha256 must match the value published in CONTRACTS.md
    assert ASSET_DIGESTS["tremor_detection_clf_package.pkl"] == \
        "4be2ac2b511c501257ea8186068f06a94d0084d653840e907be72cd103dc5b0e"


def test_provision_rejects_modified_asset(tmp_path, real_asset_bytes, venv_python_fixture):
    """A single flipped byte must fail the whole provision (never stage bad bytes)."""
    if real_asset_bytes is None:
        pytest.skip("paradigma subprocess venv not available")
    corrupted = dict(real_asset_bytes)
    blob = bytearray(corrupted["tremor_detection_clf_package.pkl"])
    blob[10] ^= 0xFF
    corrupted["tremor_detection_clf_package.pkl"] = bytes(blob)
    tree = _fake_tree(tmp_path, corrupted)
    dest = tmp_path / "root"
    proc = _provision(dest, tree)
    assert proc.returncode != 0
    # the gait asset may not be staged either (atomic-ish: verify all before success)
    assert not (dest / "paradigma").exists() or not list((dest / "paradigma").glob("**/*.pkl"))


def test_provision_rejects_truncated_asset(tmp_path, real_asset_bytes, venv_python_fixture):
    if real_asset_bytes is None:
        pytest.skip("paradigma subprocess venv not available")
    truncated = dict(real_asset_bytes)
    truncated["gait_filtering_clf_package.pkl"] = \
        truncated["gait_filtering_clf_package.pkl"][:-7]
    tree = _fake_tree(tmp_path, truncated)
    dest = tmp_path / "root"
    proc = _provision(dest, tree)
    assert proc.returncode != 0


def test_provision_records_provenance(tmp_path, real_asset_bytes, venv_python_fixture):
    """Provenance must record source URL, pinned commit, hashes, sizes, license."""
    if real_asset_bytes is None:
        pytest.skip("paradigma subprocess venv not available")
    tree = _fake_tree(tmp_path, real_asset_bytes)
    dest = tmp_path / "root"
    proc = _provision(dest, tree)
    assert proc.returncode == 0
    prov = json.loads((dest / "paradigma" / "provenance.json").read_text())
    assert prov["pinned_commit"] == MANIFEST_ENTRY["tag_commit"]
    assert prov["license"] == "Apache-2.0"
    assert prov["source"] == "real upstream pretrained classifier packages, not a reimplementation"
    by_name = {a["name"]: a for a in prov["artifacts"]}
    assert set(by_name) == set(ASSET_DIGESTS)
    for name, expected_sha in ASSET_DIGESTS.items():
        assert by_name[name]["sha256"] == expected_sha
        assert by_name[name]["size_bytes"] == len(real_asset_bytes[name])
        assert by_name[name]["path"].endswith(name)


def test_manifest_entry_shape_matches_contract():
    """The reported manifest entry is complete and contract-shaped."""
    artifacts = MANIFEST_ENTRY["artifacts"]
    assert len(artifacts) == 3
    for artifact in artifacts:
        assert artifact["verify_at_startup"] is True
        assert artifact["required_for_readiness"] is True
        assert len(artifact["sha256"]) == 64
        assert artifact["size_bytes"] > 0
    assert MANIFEST_ENTRY["provider_id"] == "sensor.biomarkers.paradigma.v1"
    assert MANIFEST_ENTRY["license"] == "Apache-2.0"
