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
PACKAGE = os.path.join(REPO, "Tools", "ActivityContext", "activity_context")
OWN = os.path.join(PACKAGE, "actinet_classifier")
TOKENS = ("actinet_classifier", WIRE_SCHEMA, CONSUMER, MODEL_ID)
PRODUCTION_ROOTS = ("Tools/CloudWorker/Sources", "Tools/InferenceWorker/src", "supabase", "Packages", "Strand",
                    "StrandiOS", "StrandiOSShared", "StrandiOSWidgets", "NOOPWatch", "android", "deploy",
                    "Tools/ActivityContext/activity_context")
SUFFIXES = (".py", ".swift", ".ts", ".sql", ".kt", ".json", ".sh", ".service", ".env", ".yml", ".yaml", ".toml")


def _offenders():
    hits = []
    for rel in PRODUCTION_ROOTS:
        root = os.path.join(REPO, rel)
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in ("__pycache__", "node_modules", ".build", ".venv")]
            if os.path.abspath(d).startswith(OWN):
                continue
            for name in files:
                if not name.endswith(SUFFIXES):
                    continue
                path = os.path.join(d, name)
                try:
                    text = open(path, encoding="utf-8", errors="ignore").read()
                except OSError:
                    continue
                hits += [f"{os.path.relpath(path, REPO)}: {t}" for t in TOKENS if t in text]
    return hits


def test_no_production_path_references_the_shadow_classifier():
    if not os.path.isdir(os.path.join(REPO, "Tools", "CloudWorker")):
        pytest.skip("not running from a full repository checkout")
    assert _offenders() == []


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
