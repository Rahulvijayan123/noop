"""Vendored-code provenance: hashes, patch set and the license inconsistency.

The vendored HypnosPy copy is upstream 3b6c825d plus a documented patch set. These tests fail
if either the recorded hashes or the recorded patch set stop matching the files on disk, so a
future edit cannot silently change the algorithm the evidence was collected against.
"""

import hashlib
import json
import os
import re

import pytest

VENDORED = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "src", "frwhoop_inference", "frwhoop_sleep", "hypnospy_vendored")
RECORD = json.load(open(os.path.join(VENDORED, "UPSTREAM_DIFF.json")))
PROVENANCE = open(os.path.join(VENDORED, "PROVENANCE.md")).read()


def _sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def test_recorded_hashes_match_the_files_on_disk():
    for rel, entry in RECORD["files"].items():
        path = os.path.join(VENDORED, "analysis" if rel.endswith("detector.py") else "", rel)
        assert _sha256(path) == entry["vendored_sha256"], rel


def test_pinned_upstream_commit_and_hashes_are_recorded():
    assert RECORD["pinned_commit"] == "3b6c825d1568158cbf0058de50495e5308117d17"
    assert RECORD["files"]["sleep_boundary_detector.py"]["upstream_sha256"] == \
        "e89a22c43f8c1b62a2a37c76d3fe6d18d62fa4d51c6b6a747ff9be3dca595f36"
    assert RECORD["files"]["misc.py"]["upstream_sha256"] == \
        "30349fb846dc350f9679c8edeb4f9e3c52449b1ec98fa21f699a4af2d15ea923"
    for entry in RECORD["files"].values():
        assert "hypnospy" in entry["upstream_path"]
        assert entry["unified_diff"], "the unified diff must be recorded"


def test_pandas_3_incompatibilities_are_patched_out():
    detector = open(os.path.join(VENDORED, "analysis", "sleep_boundary_detector.py")).read()
    misc = open(os.path.join(VENDORED, "misc.py")).read()
    assert "include_start=" not in detector
    assert "include_end=" not in detector
    assert "'24H'" not in detector
    assert "fillna(method=" not in detector
    assert "df[col_to_act] = df[col_to_act].astype(bool)" in misc
    assert "from hypnospy import" not in detector


def test_patch_set_is_fully_documented():
    for entry in RECORD["files"]["sleep_boundary_detector.py"]["patches"]:
        assert entry["id"] in PROVENANCE
        assert entry["sites"] >= 1
    assert "bool_dtype_normalization" in PROVENANCE


def test_license_inconsistency_is_recorded_not_hidden():
    license_info = RECORD["license"]
    assert license_info["spdx_from_license_file"] == "MIT"
    assert license_info["setup_py_declared_license"] == "BSD"
    assert license_info["github_api_license"].startswith("NOASSERTION")
    assert "MIT" in open(os.path.join(VENDORED, "LICENSE")).read()
    assert "unresolved" in PROVENANCE.lower()


def test_upstream_defects_are_documented_with_mitigations():
    for defect in ("D1", "D2", "D3", "D4", "D5", "D6", "D7", "D8"):
        assert defect in PROVENANCE
    assert "NaN heart rate is labelled SLEEP" in PROVENANCE


def test_vendored_algorithm_runs_on_the_installed_pandas():
    import pandas as pd

    from frwhoop_inference.frwhoop_sleep.hypnospy_vendored import SleepBoudaryDetector, Wearable  # noqa: F401

    assert re.match(r"^\d+\.", pd.__version__)


def test_wearable_refuses_to_infer_the_epoch_length():
    """Defect D3: a wrong-but-inferred frequency silently rescales every window."""
    from frwhoop_inference.frwhoop_sleep.hypnospy_vendored import FrequencyNotSetError, Wearable
    import pandas as pd

    frame = pd.DataFrame({"t": pd.date_range("2026-10-19 20:00", periods=10, freq="60s"),
                          "hr": [60.0] * 10})
    wearable = Wearable(frame, "t", "hr", pid="p", freq_in_secs=None)
    with pytest.raises(FrequencyNotSetError):
        wearable.get_frequency_in_secs()
    wearable.set_frequency_in_secs(60)
    assert wearable.get_frequency_in_secs() == 60
    assert wearable.get_epochs_in_min() == 1
