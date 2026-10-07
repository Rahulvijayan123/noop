"""Shared fixtures for the W3 ParaDigMa tests.

REAL assets only: the classifier pickles are read from the paradigma wheel
installed in the narrow subprocess venv (the exact bytes the pipeline will
unpickle) and provisioned into a per-test artifact root with the real
provision script. The upstream reference predictions live in
``fixtures/`` (vendored from the pinned upstream tree with attribution in
``fixtures/PROVENANCE.md``).

Tests that need the venv or the real assets SKIP with a clear reason when
they are absent; in a fully provisioned environment they run for real.

Env-var hygiene: env vars are applied per-test through the standard
``monkeypatch`` fixture so the W3 settings never leak into other test
modules.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

TESTS_DIR = Path(__file__).resolve().parent
FIXTURES_DIR = TESTS_DIR / "fixtures"
REPO_PACKAGE_ROOT = TESTS_DIR.parent.parent.parent  # Tools/InferenceWorker
REAL_MANIFEST = REPO_PACKAGE_ROOT / "models" / "manifest.json"
PARADIGMA_PKG = (REPO_PACKAGE_ROOT / "src" / "frwhoop_inference" /
                 "sensor_biomarkers" / "paradigma")

#: Asset digests measured from the pinned upstream bytes.
ASSET_DIGESTS = {
    "tremor_detection_clf_package.pkl": "4be2ac2b511c501257ea8186068f06a94d0084d653840e907be72cd103dc5b0e",
    "gait_detection_clf_package.pkl": "f2309bb8cff87648a54a338493db2cedb25b4a9a60cd77bbdb2d17e010a7cc25",
    "gait_filtering_clf_package.pkl": "94068bca1997755e17fddae662dd0433ac06c12a3cd32869c6d9dc586ab845f4",
}

#: The upstream manifest entry W3 reports for the parent to merge.
MANIFEST_ENTRY = {
    "id": "paradigma",
    "kind": "model_checkpoint",
    "name": "ParaDigMa 1.1.2 tremor/gait/gait-filtering classifiers",
    "revision": "1.1.2",
    "source_url": "https://github.com/biomarkersParkinson/paradigma",
    "tag_commit": "4735d6d21b2a62b764a0bc7e0f677577e6ce1668",
    "license": "Apache-2.0",
    "license_evidence": "repo LICENSE is Apache License 2.0",
    "rights_verdict": "clear",
    "status": "eligible",
    "status_reason": "real pinned inference executed 2026-10-06; classifier assets "
                     "verified by sha256; portability to WHOOP unverified (research tier)",
    "provider_id": "sensor.biomarkers.paradigma.v1",
    "wired": True,
    "input_contract": "prepared IMU DataFrame with time (relative s), "
                      "accelerometer_x/y/z (g), gyroscope_x/y/z (deg/s); "
                      "run_paradigma via the narrow subprocess env; gait requires "
                      "verified watch_side + device_orientation + verified WHOOP axis convention",
    "artifacts": [
        {"name": "tremor_detection_clf_package.pkl",
         "path": "paradigma/4735d6d21b2a62b764a0bc7e0f677577e6ce1668/tremor_detection_clf_package.pkl",
         "url": ("https://raw.githubusercontent.com/biomarkersParkinson/paradigma/"
                 "4735d6d21b2a62b764a0bc7e0f677577e6ce1668/src/paradigma/assets/"
                 "tremor_detection_clf_package.pkl"),
         "size_bytes": 1475, "sha256": ASSET_DIGESTS["tremor_detection_clf_package.pkl"],
         "verify_at_startup": True, "required_for_readiness": True},
        {"name": "gait_detection_clf_package.pkl",
         "path": "paradigma/4735d6d21b2a62b764a0bc7e0f677577e6ce1668/gait_detection_clf_package.pkl",
         "url": ("https://raw.githubusercontent.com/biomarkersParkinson/paradigma/"
                 "4735d6d21b2a62b764a0bc7e0f677577e6ce1668/src/paradigma/assets/"
                 "gait_detection_clf_package.pkl"),
         "size_bytes": 11497247, "sha256": ASSET_DIGESTS["gait_detection_clf_package.pkl"],
         "verify_at_startup": True, "required_for_readiness": True},
        {"name": "gait_filtering_clf_package.pkl",
         "path": "paradigma/4735d6d21b2a62b764a0bc7e0f677577e6ce1668/gait_filtering_clf_package.pkl",
         "url": ("https://raw.githubusercontent.com/biomarkersParkinson/paradigma/"
                 "4735d6d21b2a62b764a0bc7e0f677577e6ce1668/src/paradigma/assets/"
                 "gait_filtering_clf_package.pkl"),
         "size_bytes": 3915, "sha256": ASSET_DIGESTS["gait_filtering_clf_package.pkl"],
         "verify_at_startup": True, "required_for_readiness": True},
    ],
    "required_for_readiness": True,
    "accuracy_label": "unverified_accuracy",
    "runtime_note": "executed in the narrow optional subprocess venv (python 3.12, "
                    "numpy 2.5.3, scipy 1.18.1, pandas 2.3.3, scikit-learn 1.6.0) "
                    "because the main env pins scikit-learn 1.9.1, outside "
                    "paradigma's <1.6.1 range",
}


def venv_python() -> str | None:
    configured = os.environ.get("FRWHOOP_PARADIGMA_PYTHON")
    if configured and os.path.isfile(configured):
        return configured
    known = "/tmp/frwhoop-sensor-biomarkers/paradigma-venv/bin/python"
    return known if os.path.isfile(known) else None


def wheel_asset_bytes(name: str, python: str) -> bytes:
    """Read the exact bytes the venv's paradigma wheel would unpickle."""
    probe = (
        "import sys; from importlib.resources import files; import paradigma.assets; "
        f"sys.stdout.buffer.write((files('paradigma.assets') / {name!r}).read_bytes())"
    )
    proc = subprocess.run([python, "-c", probe], capture_output=True, check=True)
    return proc.stdout


@pytest.fixture(scope="session")
def venv_python_fixture():
    return venv_python()


@pytest.fixture(scope="session")
def real_asset_bytes():
    """The real pinned asset bytes from the installed wheel, keyed by name."""
    python = venv_python()
    if python is None:
        return None
    return {name: wheel_asset_bytes(name, python) for name in ASSET_DIGESTS}


@pytest.fixture(scope="session")
def provisioned_root(tmp_path_factory, real_asset_bytes):
    """A temp artifact root provisioned with the REAL bytes via the real script."""
    root = tmp_path_factory.mktemp("model-root")
    if real_asset_bytes is None:
        return root  # empty; provider gate tests rely on the empty root
    real = real_asset_bytes
    tree = tmp_path_factory.mktemp("paradigma-tree")
    asset_src = tree / "src" / "paradigma" / "assets"
    asset_src.mkdir(parents=True, exist_ok=True)
    for name, blob in real.items():
        (asset_src / name).write_bytes(blob)
    script = REPO_PACKAGE_ROOT / "scripts" / "provision_paradigma.py"
    proc = subprocess.run(
        [os.sys.executable, str(script), "--dest", str(root), "--from-tree", str(tree)],
        capture_output=True, text=True)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return root


@pytest.fixture(scope="session")
def manifest_with_paradigma(tmp_path_factory):
    """A copy of the real manifest plus the W3 paradigma entry."""
    manifest = json.loads(REAL_MANIFEST.read_text())
    entries = [e for e in manifest["entries"] if e.get("id") != "paradigma"]
    entries.append(MANIFEST_ENTRY)
    manifest["entries"] = entries
    path = tmp_path_factory.mktemp("manifest") / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2))
    return path


@pytest.fixture
def paradigma_env(monkeypatch, manifest_with_paradigma, provisioned_root):
    """Per-test env vars pointing the provider at the test manifest + real root.

    Standard ``monkeypatch`` undo guarantees the W3 env never leaks into
    other tests.
    """
    python = venv_python()
    if python is None:
        pytest.skip("paradigma subprocess venv not available")
    monkeypatch.setenv("FRWHOOP_MANIFEST", str(manifest_with_paradigma))
    monkeypatch.setenv("FRWHOOP_MODEL_ROOT", str(provisioned_root))
    monkeypatch.setenv("FRWHOOP_PARADIGMA_PYTHON", python)
    monkeypatch.setenv("FRWHOOP_PARADIGMA_ENABLED", "1")
    return {"manifest": manifest_with_paradigma, "root": provisioned_root,
            "python": python}
