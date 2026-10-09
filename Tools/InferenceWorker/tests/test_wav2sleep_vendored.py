"""Vendored wav2sleep code: provenance, hashes, license and the absence of heavy dependencies.

The vendored files are generated from the pinned clone (278e3046). These tests fail when a
recorded hash, the verbatim body or the license stops matching the files on disk, so the code
the parity evidence was collected against cannot drift silently.
"""

import ast
import hashlib
import json
import os
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SLEEP = os.path.join(os.path.dirname(HERE), "src", "frwhoop_inference", "frwhoop_sleep")
VENDORED = os.path.join(SLEEP, "wav2sleep_vendored")
ADAPTER = os.path.join(SLEEP, "wav2sleep")
RECORD = json.load(open(os.path.join(VENDORED, "UPSTREAM_DIFF.json")))
PROVENANCE = open(os.path.join(VENDORED, "PROVENANCE.md")).read()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def test_pinned_commit_and_content_identity_are_recorded():
    assert RECORD["pinned_commit"] == "278e30463c8149c4e6899b8784da492fec695bd9"
    assert RECORD["upstream"] == "https://github.com/joncarter1/wav2sleep"
    assert RECORD["content_identical_since"]["commit"] == "8b2a7b1ca5caab4fe7efcf75faa0a125f5ea24c4"
    assert "278e3046" in PROVENANCE and "18fc32f0" in PROVENANCE


@pytest.mark.parametrize("rel", sorted(RECORD["files"]))
def test_recorded_vendored_hash_matches_the_file_on_disk(rel):
    with open(os.path.join(VENDORED, rel), "rb") as handle:
        assert _sha256(handle.read()) == RECORD["files"][rel]["vendored_sha256"], rel


@pytest.mark.parametrize("rel", sorted(r for r, e in RECORD["files"].items() if e["kind"] == "verbatim"))
def test_verbatim_files_are_the_upstream_bytes_plus_a_header(rel):
    entry = RECORD["files"][rel]
    with open(os.path.join(VENDORED, rel), "rb") as handle:
        lines = handle.read().split(b"\n")
    header, body = lines[:entry["header_lines"]], b"\n".join(lines[entry["header_lines"]:])
    assert all(line.startswith(b"#") for line in header[:-1])
    assert _sha256(body) == entry["upstream_sha256"], f"{rel} body differs from upstream"
    assert entry["unified_diff"] == ""


def test_extracts_record_what_was_removed_and_keep_function_bodies():
    utils = RECORD["files"]["data/utils.py"]
    assert {r.get("name") for r in utils["removed"] if r["kind"] == "function"} == \
        {"get_parquet_cols", "get_parquet_fps"}
    assert "import pyarrow.parquet as pq" in [r.get("line") for r in utils["removed"]]
    source = open(os.path.join(VENDORED, "data", "utils.py")).read()
    for name in utils["retained"]:
        assert f"def {name}(" in source
    assert "-import pyarrow.parquet as pq" in utils["unified_diff"]
    zscore = RECORD["files"]["data/zscore.py"]
    assert zscore["retained"] == ["ParquetDataset._zscore_normalize -> _zscore_normalize"]
    assert "staticmethod" in zscore["transform"]


def test_license_is_the_upstream_mit_file():
    raw = open(os.path.join(VENDORED, "LICENSE"), "rb").read()
    assert _sha256(raw) == RECORD["license"]["sha256"]
    assert raw.startswith(b"MIT License") and b"Jonathan Carter" in raw
    assert RECORD["license"]["spdx"] == "MIT"


def _imports(path):
    tree = ast.parse(open(path).read())
    names = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names.add(node.module.split(".")[0])
    return names


def test_no_dependency_outside_the_lock_is_imported():
    """hydra/omegaconf/lightning/einops/pyarrow/pyedflib/numba/huggingface_hub are not needed."""
    forbidden = {"hydra", "omegaconf", "lightning", "einops", "pyarrow", "pyedflib", "numba",
                 "huggingface_hub", "tqdm", "mlflow"}
    for base in (VENDORED, ADAPTER):
        for root, _, files in os.walk(base):
            for name in files:
                if name.endswith(".py"):
                    used = _imports(os.path.join(root, name))
                    assert not (used & forbidden), (name, used & forbidden)


def test_importing_the_adapter_package_does_not_import_torch():
    code = ("import sys; import frwhoop_inference.frwhoop_sleep.wav2sleep as w; "
            "import frwhoop_inference.frwhoop_sleep.wav2sleep.contract; "
            "print('torch' in sys.modules)")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert out.stdout.strip() == "False"


def test_provenance_records_every_deviation_and_the_parity_evidence():
    for token in ("D1", "D2", "D3", "D4", "D5", "D6", "max_length_hours", "safe_load",
                  "allowlist", "strict", "weights_only", "-inf", "bit-identical"):
        assert token in PROVENANCE, token
