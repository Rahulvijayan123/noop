"""Shadow isolation and Spec 01 loaded identity for the ActiNet classifier (ACTINET_CLASSIFIER.md §7, §10).

Isolation: the classifier is a separate serve process whose outputs are ``release_mode: shadow``. Until Spec 01's
activity-intensity shadow store and worker wiring exist, nothing in production may read it. These tests fail if any
production path (the worker, the backend, the app packages and targets, the sidecar, or another ActivityContext
lane) starts naming it, so wiring it becomes a deliberate change that has to update this file and the contract.
"""

import importlib.util
import json
import os

import pytest

from activity_context.actinet_classifier import CONSUMER, MODEL_ID, RELEASE_MODE, WIRE_SCHEMA, serve

from ._helpers import fake_runtime, request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
AC = os.path.join(REPO, "Tools", "ActivityContext")
# Paths that may name the classifier: its own package, its tests and fixtures, and documentation.
OWN = tuple(os.path.join(AC, *p) for p in (("activity_context", "actinet_classifier"), ("tests", "actinet_classifier"),
                                           ("fixtures", "actinet_classifier")))
TOKENS = tuple(t.lower() for t in ("actinet_classifier", WIRE_SCHEMA, CONSUMER, MODEL_ID, "ACTINET_CLASSIFIER_DIR",
                                   "FRWHOOP_ACTINET_CLASSIFIER"))
# Everything production builds, deploys or configures from. Files are scanned whatever their extension (Dockerfile,
# unit files); documentation (*.md) and binaries are not.
PRODUCTION_ROOTS = ("Tools/CloudWorker", "Tools/InferenceWorker", "Tools/ActivityContext", "supabase", "Packages",
                    "Strand", "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch", "NOOPWatchComplications",
                    "android", "deploy", "Config", "contracts", "project.yml")
SKIP_SUFFIXES = (".md", ".png", ".jpg", ".pdf", ".npz", ".pt", ".pth", ".bin", ".zip", ".gz", ".lzma", ".joblib",
                 ".parquet", ".mlmodel", ".safetensors", ".lock")
MAX_SCAN_BYTES = 4 * 1024 * 1024


def _tracked(repo, roots):
    """Git-tracked files under ``roots`` (what production builds from; local build output and venvs excluded)."""
    import subprocess
    out = subprocess.run(["git", "-C", repo, "ls-files", "-z", "--", *roots], capture_output=True, check=True)
    return [os.path.join(repo, p) for p in out.stdout.decode("utf-8").split("\0") if p]


def _offenders(repo, files, tokens, own):
    hits = []
    for path in files:
        if os.path.abspath(path).startswith(own) or path.endswith(SKIP_SUFFIXES):
            continue
        try:
            if os.path.getsize(path) > MAX_SCAN_BYTES:
                continue
            text = open(path, encoding="utf-8", errors="ignore").read().lower()
        except OSError:
            continue
        hits += [f"{os.path.relpath(path, repo)}: {t}" for t in tokens if t in text]
    return hits


def _full_checkout_or_skip():
    has_git = os.path.exists(os.path.join(REPO, ".git"))          # a directory, or a file in a worktree
    if not (os.path.isdir(os.path.join(REPO, "Tools", "CloudWorker")) and has_git):
        if os.environ.get("CI"):
            pytest.fail("isolation guard needs the full repository checkout in CI")
        pytest.skip("not running from a full repository checkout")


def test_no_production_path_references_the_shadow_classifier():
    _full_checkout_or_skip()
    files = _tracked(REPO, PRODUCTION_ROOTS)
    assert len(files) > 1000                   # the scan really covers the tree
    assert _offenders(REPO, files, TOKENS, OWN) == []


def test_the_guard_would_catch_wiring(tmp_path):
    """An extensionless file naming the env var in upper case is caught; this package's own files are not."""
    unit = tmp_path / "Dockerfile"
    unit.write_text("ENV ACTINET_CLASSIFIER_DIR=/var/lib/frwhoop/actinet\n")
    assert _offenders(str(tmp_path), [str(unit)], TOKENS, OWN) == ["Dockerfile: actinet_classifier",
                                                                     "Dockerfile: actinet_classifier_dir"]
    assert _offenders(REPO, [os.path.join(OWN[0], "serve.py")], TOKENS, OWN) == []


def test_every_output_is_shadow_and_names_its_consumer():
    rt = fake_runtime()
    for op in ({"id": "p", "op": "ping"}, request()):
        r = json.loads(serve.handle_line(rt, json.dumps(op), timeout=0)[0])
        assert r["ok"] and r["release_mode"] == RELEASE_MODE == "shadow" and r["consumer"] == CONSUMER


def test_loaded_identity_follows_spec01_when_present():
    rt = fake_runtime()
    ping = json.loads(serve.handle_line(rt, json.dumps({"id": "p", "op": "ping"}), timeout=0)[0])
    infer = json.loads(serve.handle_line(rt, json.dumps(request()), timeout=0)[0])
    if importlib.util.find_spec("activity_context.loaded") is None:
        # Spec 01 not merged: no identity is claimed, so the worker would give this child no cache key.
        assert "loaded" not in ping and "loaded_digest" not in ping and "loaded_digest" not in infer
        return
    from activity_context.loaded import LOADED_SCHEMA, loaded_digest
    loaded = ping["loaded"]
    assert all(isinstance(k, str) and isinstance(v, str) for k, v in loaded.items())   # parsePing's rule
    assert loaded["schema"] == LOADED_SCHEMA and len(loaded["code_sha256"]) == 64
    assert ping["loaded_digest"] == loaded_digest(loaded) == infer["loaded_digest"]
    assert loaded["release_mode"] == "shadow" and loaded["artifact_digest"] == rt.artifact_digest
    assert loaded["preprocessing_digest"] == rt.preprocessing_digest


def test_unavailable_runtime_reports_no_artifact_identity():
    from activity_context.actinet_classifier.runtime import build_runtime
    rt = build_runtime("/nonexistent/actinet-classifier-dir")
    assert not rt.available
    loaded = rt.loaded()
    if loaded is not None:
        assert not any(k.endswith("_sha256") and k != "code_sha256" for k in loaded)
        assert "artifact_digest" not in loaded
