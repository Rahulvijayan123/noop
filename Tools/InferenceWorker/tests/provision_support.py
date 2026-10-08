"""Helpers for the provisioning and release tests (not a pytest plugin).

The optional sensor-biomarker artifacts (ParaDigMa, DeepBeat, SiamAF) are not on this machine
and the tests never touch the network, so those artifacts are served from deterministic local
fixture bytes through a stub fetcher, under a copy of the real manifest whose pins for exactly
those artifacts are rewritten to the fixture bytes. The SleepECG checkpoint is always the real
one, read from the installed ``sleepecg`` wheel.
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import sys
from pathlib import Path
from typing import Any, BinaryIO, Callable

REPO_PACKAGE_ROOT = Path(__file__).resolve().parent.parent
REPO_ROOT = REPO_PACKAGE_ROOT.parent.parent
DEPLOY_DIR = REPO_ROOT / "deploy"
MATERIALIZER = REPO_PACKAGE_ROOT / "scripts" / "materialize_model_root.py"
REAL_MANIFEST = REPO_PACKAGE_ROOT / "models" / "manifest.json"
SERVICE_UNIT = DEPLOY_DIR / "frwhoop-inference.service"

#: Optional url artifacts staged from fixture bytes in these tests.
OPTIONAL_ENTRIES = ("paradigma", "deepbeat", "siamaf")


def load_materializer():
    """``scripts/materialize_model_root.py`` as a module (scripts/ is not a package)."""
    name = "materialize_model_root_under_test"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, MATERIALIZER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def fixture_bytes(name: str) -> bytes:
    """Deterministic stand-in bytes for one optional artifact (never a real model)."""
    seed = hashlib.sha256(f"provisioning-fixture:{name}".encode()).digest()
    return seed * (64 + len(name))


def manifest_with_fixture_optionals(directory: Path) -> tuple[Path, dict[str, bytes]]:
    """A copy of the real manifest with the optional url artifacts pinned to fixture bytes.

    Returns the manifest path and ``{url: bytes}`` for the stub fetcher. Every other entry,
    including the SleepECG pins, is byte-for-byte the committed one.
    """
    manifest = json.loads(REAL_MANIFEST.read_text())
    served: dict[str, bytes] = {}
    for entry in manifest["entries"]:
        if entry["id"] not in OPTIONAL_ENTRIES:
            continue
        for artifact in entry["artifacts"]:
            blob = fixture_bytes(artifact["name"])
            artifact["sha256"] = hashlib.sha256(blob).hexdigest()
            artifact["size_bytes"] = len(blob)
            served[artifact["url"]] = blob
    path = directory / "manifest-with-fixture-optionals.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path, served


class StubFetcher:
    """Serves fixed bytes per url, records every call, and fails for anything else."""

    def __init__(self, served: dict[str, bytes], *, fail: tuple[str, ...] = ()):
        self.served = dict(served)
        self.fail = set(fail)
        self.calls: list[str] = []

    def __call__(self, url: str, out: BinaryIO, max_bytes: int) -> None:
        mm = load_materializer()
        self.calls.append(url)
        if url in self.fail or url not in self.served:
            raise mm.FetchError(f"stub: no bytes for {url}")
        out.write(self.served[url])


def ready_probe(*, not_ready: dict[str, str] | None = None, ok: bool = True,
                error: str = "probe failed") -> Callable[..., dict[str, Any]]:
    """A fast stand-in for the real readiness probe (the real one is exercised separately)."""
    calls: list[str] = []

    def probe(root: str, **_: Any) -> dict[str, Any]:
        calls.append(root)
        if not ok:
            return {"ok": False, "error": error}
        providers = {pid: {"ready": True, "reason": None, "version": "test"} for pid in (
            "production.runs.v1", "neurokit2.shadow.v1", "hypnospy.hr-boundary.v1",
            "sleepecg.wrn-gru-mesa.v1", "sensor.biomarkers.v1")}
        for pid, reason in (not_ready or {}).items():
            providers[pid] = {"ready": False, "reason": reason, "version": "test"}
        return {"ok": True, "process_ready": not not_ready, "providers": providers}

    probe.calls = calls  # type: ignore[attr-defined]
    return probe


def tree_snapshot(root: Path) -> dict[str, str]:
    """{relative path: sha256} for every file under ``root`` (to prove bytes did not change)."""
    out: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and not path.is_symlink():
            out[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return out


def subprocess_env(**overrides: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("FRWHOOP_")}
    env["FRWHOOP_PROVISION_OFFLINE"] = "1"
    env.update(overrides)
    return env


def read_json_stdout(text: str) -> dict[str, Any]:
    """The JSON report a CLI run printed on stdout."""
    return json.load(io.StringIO(text))
