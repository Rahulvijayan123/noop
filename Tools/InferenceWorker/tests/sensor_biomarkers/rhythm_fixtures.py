"""Real-weight artifact fixtures for the W4 rhythm tests (pytest plugin).

This module is loaded as a pytest plugin by the rhythm test modules
(``pytest_plugins = ["rhythm_fixtures"]``) so its fixtures register without a
``conftest.py`` in this directory (a subdir ``conftest.py`` would shadow the
repository-level ``tests/conftest.py`` that the pre-existing test modules
import by name).

The fixtures locate the PROVISIONED real weights (from ``FRWHOOP_MODEL_ROOT``
or the provisioning default ``/tmp/frwhoop-sensor-biomarkers/models``), copy
them into a temporary root, and verify each sha256 against the pinned digest
before any test runs. When the artifacts are not staged, the real-weight tests
skip with a clear reason; the fail-closed wiring tests never need them.
Synthetic payload helpers live in ``rhythm_helpers`` (not a plugin).
"""

from __future__ import annotations

import hashlib
import os
import shutil

import pytest

from frwhoop_inference.sensor_biomarkers.rhythm._common import LOCAL_STAGING_ROOT

#: Pinned digests recorded from the actual cloned/downloaded bytes (W4 report).
DEEPBEAT_SHA256 = "6df126f88855388f8706ea6e158b80902752a019b1f3c26d3ceab22991e4eee3"
DEEPBEAT_SIZE = 1_502_052
DEEPBEAT_RELPATH = "deepbeat/f54004a80e/deepbeat.h5"
SIAMAF_SHA256 = "a141b91cf5a5ef8eb4a2a6142273852ee2810a36e6fba1642a4836b3402176be"
SIAMAF_SIZE = 10_915_597
SIAMAF_RELPATH = "siamaf/c05be9e37d/final_model.pt"


def _locate(source_root: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for name, rel in (("deepbeat", DEEPBEAT_RELPATH), ("siamaf", SIAMAF_RELPATH)):
        path = os.path.join(source_root, rel)
        if os.path.isfile(path):
            found[name] = path
    return found


@pytest.fixture(scope="session")
def rhythm_artifacts() -> dict[str, str]:
    """Paths to the REAL staged artifacts, or a skip when not provisioned."""
    candidates = [os.environ.get("FRWHOOP_MODEL_ROOT"), LOCAL_STAGING_ROOT]
    for root in candidates:
        if not root:
            continue
        found = _locate(root)
        if "deepbeat" in found and "siamaf" in found:
            return found
    pytest.skip(
        "real rhythm artifacts not staged; run "
        "Tools/InferenceWorker: uv run python scripts/provision_deepbeat.py and "
        "uv run python scripts/provision_siamaf.py")


@pytest.fixture(scope="session")
def rhythm_model_root(rhythm_artifacts, tmp_path_factory) -> str:
    """A hermetic artifact root with the verified real bytes."""
    root = tmp_path_factory.mktemp("frwhoop-rhythm-models")
    checks = {
        "deepbeat": (DEEPBEAT_RELPATH, DEEPBEAT_SHA256, DEEPBEAT_SIZE),
        "siamaf": (SIAMAF_RELPATH, SIAMAF_SHA256, SIAMAF_SIZE),
    }
    for name, (rel, expected_sha, expected_size) in checks.items():
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(rhythm_artifacts[name], target)
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        assert digest == expected_sha, f"{name} sha256 mismatch in staged root"
        assert target.stat().st_size == expected_size, f"{name} size mismatch"
    return str(root)
