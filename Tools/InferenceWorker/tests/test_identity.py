"""The sidecar's runtime identity: measured code, lock, manifest, revision and artifacts."""

from __future__ import annotations

import hashlib
import json
import os

import pytest

from frwhoop_inference import identity
from frwhoop_inference.providers import HrvProductionProvider, ProviderRegistry
from frwhoop_inference.server import Application
from provision_support import REAL_MANIFEST, REPO_PACKAGE_ROOT, load_materializer, ready_probe

mm = load_materializer()


def _app(manifest: str, root: str, registry: ProviderRegistry | None = None) -> Application:
    return Application.build(registry=registry or ProviderRegistry([HrvProductionProvider()]),
                             manifest_path=manifest, model_root=root)


@pytest.fixture
def staged_revision(tmp_path):
    """A revision staged by the real materializer (offline, fast probe)."""
    models = tmp_path / "models"
    report = mm.stage_revision(str(models), str(REAL_MANIFEST), fetcher=None, probe=ready_probe(),
                               service_env={}, log=lambda m: None)
    assert report.outcome == "selected"
    return models / "current", report.revision_id


def test_the_tree_digest_covers_regular_files_and_ignores_bytecode(tmp_path):
    root = tmp_path / "pkg"
    (root / "sub" / "__pycache__").mkdir(parents=True)
    (root / "a.py").write_bytes(b"a")
    (root / "sub" / "b.json").write_bytes(b"b")
    (root / "sub" / "__pycache__" / "a.cpython-312.pyc").write_bytes(b"junk")
    (root / "c.pyc").write_bytes(b"junk")
    os.symlink("a.py", root / "link.py")
    expected = "".join(f"{hashlib.sha256(data).hexdigest()}  {path}\n"
                       for path, data in (("a.py", b"a"), ("sub/b.json", b"b")))
    assert identity.tree_lines(str(root)) == expected.splitlines(keepends=True)
    digest, count = identity.tree_sha256(str(root))
    assert count == 2 and digest == hashlib.sha256(expected.encode()).hexdigest()
    (root / "sub" / "__pycache__" / "other.pyc").write_bytes(b"more junk")
    assert identity.tree_sha256(str(root))[0] == digest, "bytecode never changes the digest"
    (root / "a.py").write_bytes(b"changed")
    assert identity.tree_sha256(str(root))[0] != digest


def test_the_source_digest_is_measured_once_at_import(monkeypatch):
    source = identity.source_identity()
    package_dir = os.path.dirname(identity.__file__)
    assert source["path"] == package_dir
    assert source["sha256"] == identity.tree_sha256(package_dir)[0]
    assert source["files"] > 10

    def fail(_):
        raise AssertionError("re-hashed the package on a request")

    monkeypatch.setattr(identity, "tree_sha256", fail)
    assert identity.source_identity() == source


def test_the_identity_block_reports_measured_digests_and_the_selected_revision(staged_revision,
                                                                               monkeypatch):
    root, revision_id = staged_revision
    monkeypatch.setenv("FRWHOOP_SOURCE_REVISION", "0" * 40)
    monkeypatch.delenv("FRWHOOP_RELEASE_STAMP", raising=False)
    app = _app(str(root / "manifest.json"), str(root))
    block = identity.runtime_identity(app)

    assert block["schema"] == identity.IDENTITY_SCHEMA
    assert block["claimed_source_revision"] == "0" * 40
    assert block["code_revision"]["commit"] is None, "a claim is never promoted to the revision"
    assert block["uv_lock_sha256"] == hashlib.sha256(
        (REPO_PACKAGE_ROOT / "uv.lock").read_bytes()).hexdigest()
    assert block["source"]["sha256"] == identity.source_identity()["sha256"]
    assert block["manifest"]["sha256"] == hashlib.sha256(REAL_MANIFEST.read_bytes()).hexdigest()
    assert block["manifest"]["matches_revision"] is True

    revision = block["model_revision"]
    assert revision["revision_id"] == revision_id
    assert revision["manifest_sha256"] == block["manifest"]["sha256"]
    assert revision["sha256"] == hashlib.sha256((root / "revision.json").read_bytes()).hexdigest()
    assert "sensor.biomarkers.rhythm.v1" in revision["withheld"]

    artifacts = {(a["entry_id"], a["name"]): a for a in block["artifacts"]}
    zipped = artifacts[("sleepecg_wrn_gru_mesa", "wrn-gru-mesa.zip")]
    assert zipped["status"] == "verified"
    assert zipped["sha256"] == "5622a858c855b0090e1fbcbdc35334ea459707c830eae1a26a4375e33091e869"
    assert artifacts[("deepbeat", "deepbeat.h5")] == {
        "entry_id": "deepbeat", "name": "deepbeat.h5", "status": "missing", "sha256": None}
    assert block["providers"]["production.runs.v1"] == {"ready": True, "reason": None}
    json.dumps(block)  # the block is plain JSON


def test_the_release_stamp_is_compared_with_what_was_measured(staged_revision, tmp_path,
                                                              monkeypatch):
    root, _ = staged_revision
    app = _app(str(root / "manifest.json"), str(root))
    measured = identity.runtime_identity(app)
    stamp = {
        "schema": "nara-release-stamp/1", "release_id": "a" * 40, "git_commit": "a" * 40,
        "git_tree": "b" * 40, "dirty": False,
        "uv_lock_sha256": measured["uv_lock_sha256"],
        "manifest_sha256": "f" * 64,
        "files": {"sha256": "c" * 64},
        "trees": {identity.SOURCE_TREE_KEY: measured["source"]["sha256"]},
    }
    path = tmp_path / "RELEASE.json"
    path.write_text(json.dumps(stamp))
    monkeypatch.setenv("FRWHOOP_RELEASE_STAMP", str(path))
    block = identity.runtime_identity(app)
    assert block["release"]["git_commit"] == "a" * 40
    assert block["release"]["stamp_sha256"] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert block["code_revision"] == {"commit": "a" * 40, "dirty": False,
                                      "source_matches_release": True,
                                      "uv_lock_matches_release": True}
    assert block["manifest"]["matches_release"] is False, "the revision came from another manifest"

    stamp["trees"][identity.SOURCE_TREE_KEY] = "0" * 64
    path.write_text(json.dumps(stamp))
    assert identity.runtime_identity(app)["code_revision"]["source_matches_release"] is False

    monkeypatch.setenv("FRWHOOP_RELEASE_STAMP", str(tmp_path / "missing.json"))
    missing = identity.runtime_identity(app)
    assert missing["release"]["error"].startswith("missing")
    assert missing["code_revision"]["commit"] is None


def test_a_release_stamp_beside_the_code_is_found_without_configuration(tmp_path):
    release = tmp_path / "releases" / ("a" * 40)
    package = release / "Tools" / "InferenceWorker"
    package.mkdir(parents=True)
    (release / "RELEASE.json").write_text("{}")
    assert identity.find_release_stamp(str(package), {}) == str(release / "RELEASE.json")
    assert identity.find_release_stamp(str(package), {"FRWHOOP_RELEASE_STAMP": "/x"}) == "/x"


def test_the_identity_block_is_cheap_per_request(staged_revision, monkeypatch):
    root, _ = staged_revision
    app = _app(str(root / "manifest.json"), str(root))
    identity.runtime_identity(app)
    before = identity._sha256_cached.cache_info()
    monkeypatch.setattr(identity, "tree_sha256", lambda _: (_ for _ in ()).throw(AssertionError()))
    for _ in range(20):
        identity.runtime_identity(app)
    after = identity._sha256_cached.cache_info()
    assert after.misses == before.misses, "no file was hashed again"


def test_a_provider_may_report_what_it_loaded(staged_revision):
    root, _ = staged_revision

    class Loaded(HrvProductionProvider):
        provider_id = "test.loaded.v1"

        def loaded_identity(self):
            return {"checkpoint_sha256": "ab" * 32}

    class Broken(HrvProductionProvider):
        provider_id = "test.broken.v1"

        def loaded_identity(self):
            raise RuntimeError("no model")

    app = _app(str(root / "manifest.json"), str(root),
               ProviderRegistry([HrvProductionProvider(), Loaded(), Broken()]))
    providers = identity.runtime_identity(app)["providers"]
    assert providers["test.loaded.v1"]["loaded"] == {"checkpoint_sha256": "ab" * 32}
    assert providers["test.broken.v1"]["loaded"]["error"].startswith("RuntimeError")
    assert "loaded" not in providers["production.runs.v1"]

    # What the warm worker reported it loaded wins over this process's copy.
    app.worker_loaded_identity = {"test.loaded.v1": {"checkpoint_sha256": "cd" * 32}}
    providers = identity.runtime_identity(app)["providers"]
    assert providers["test.loaded.v1"]["loaded"] == {"checkpoint_sha256": "cd" * 32}
    assert providers["test.loaded.v1"]["loaded_source"] == "worker"


def test_healthz_and_providers_carry_the_identity(staged_revision, live_server):
    root, revision_id = staged_revision
    server = live_server(registry=ProviderRegistry([HrvProductionProvider()]),
                         manifest_path=str(root / "manifest.json"), model_root=str(root))
    for route in ("/healthz", "/v1/providers"):
        status, body = server.get(route)
        assert status == 200
        block = body["identity"]
        assert block["model_revision"]["revision_id"] == revision_id
        assert block["source"]["sha256"] and block["manifest"]["sha256"]
        assert {"code_revision", "release", "artifacts", "providers"} <= set(block)


class _SleepStub(HrvProductionProvider):
    """Gated by the real manifest's sleepecg entry, as the real sleep provider is. Module-level
    so the registry pickles into the infer worker."""

    provider_id = "sleepecg.wrn-gru-mesa.v1"

    def __init__(self, checkpoint: str):
        super().__init__()
        self.checkpoint = checkpoint

    def loaded_identity(self):
        with open(self.checkpoint, "rb") as handle:
            return {"checkpoint_sha256": hashlib.sha256(handle.read()).hexdigest()}


def test_healthz_reports_code_lock_manifest_loaded_digests_and_readiness_together(
        staged_revision, live_server, tmp_path, monkeypatch):
    """Spec 01 §1: one ``/healthz`` answer, through the real HTTP server, ties together the code
    revision, the lock digest, the manifest digest, the digests of the checkpoints in use and
    provider readiness, each measured by the process rather than taken from a claim."""
    root, revision_id = staged_revision
    entry = next(e for e in json.loads(REAL_MANIFEST.read_text())["entries"]
                 if e["id"] == "sleepecg_wrn_gru_mesa")
    checkpoint = root / next(a["path"] for a in entry["artifacts"]
                             if a["name"] == "wrn-gru-mesa.zip")
    assert checkpoint.is_file()

    probe_app = _app(str(root / "manifest.json"), str(root))
    measured = identity.runtime_identity(probe_app)
    stamp_path = tmp_path / "RELEASE.json"
    stamp_path.write_text(json.dumps({
        "schema": "nara-release-stamp/1", "release_id": "d" * 40, "git_commit": "d" * 40,
        "git_tree": "e" * 40, "dirty": False,
        "uv_lock_sha256": measured["uv_lock_sha256"],
        "manifest_sha256": measured["manifest"]["sha256"],
        "files": {"sha256": "c" * 64},
        "trees": {identity.SOURCE_TREE_KEY: measured["source"]["sha256"]},
    }))
    monkeypatch.setenv("FRWHOOP_RELEASE_STAMP", str(stamp_path))
    monkeypatch.setenv("FRWHOOP_SOURCE_REVISION", "0" * 40)

    server = live_server(registry=ProviderRegistry([HrvProductionProvider(),
                                                    _SleepStub(str(checkpoint))]),
                         manifest_path=str(root / "manifest.json"), model_root=str(root))
    status, body = server.get("/healthz")
    assert status == 200
    block = body["identity"]

    # Code revision: from the stamp, confirmed by the measured source and lock, not the claim.
    assert block["claimed_source_revision"] == "0" * 40
    assert block["code_revision"] == {"commit": "d" * 40, "dirty": False,
                                      "source_matches_release": True,
                                      "uv_lock_matches_release": True}
    assert block["uv_lock_sha256"] == hashlib.sha256(
        (REPO_PACKAGE_ROOT / "uv.lock").read_bytes()).hexdigest()
    # Manifest: the bytes this process verified against, matching the release and the revision.
    assert block["manifest"]["sha256"] == hashlib.sha256(
        (root / "manifest.json").read_bytes()).hexdigest()
    assert block["manifest"]["matches_release"] is True
    assert block["manifest"]["matches_revision"] is True
    assert block["model_revision"]["revision_id"] == revision_id
    # Checkpoints: verified at startup and reported by the provider that loaded them.
    sleep_artifacts = {a["name"]: a for a in block["artifacts"]
                       if a["entry_id"] == "sleepecg_wrn_gru_mesa"}
    assert sleep_artifacts and all(a["status"] == "verified" and len(a["sha256"]) == 64
                                   for a in sleep_artifacts.values())
    loaded = block["providers"]["sleepecg.wrn-gru-mesa.v1"]
    assert loaded["ready"] is True and loaded["reason"] is None
    assert loaded["loaded"]["checkpoint_sha256"] == sleep_artifacts["wrn-gru-mesa.zip"]["sha256"]
    # Readiness: the same answer as the route's own provider map.
    assert {pid: p["ready"] for pid, p in block["providers"].items()} == {
        pid: p["ready"] for pid, p in body["providers"].items()}
