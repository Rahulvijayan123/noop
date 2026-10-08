"""Release packaging (deploy/package_release.py) and the host-side release script.

A small synthetic repository exercises the closure derivation, the dirty-tree rule, the stamp and
verification; one dry run against this repository pins the real closure. ``release-host.sh``
install/switch/rollback/status are exercised here with a stand-in build record; its ``build``
step (swift build + swift test + the binary's own identity check) runs for real in the Linux
build recorded in docs/model-integration/provisioning.md.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

from provision_support import DEPLOY_DIR, REPO_ROOT

pytestmark = pytest.mark.skipif(shutil.which("git") is None or not (DEPLOY_DIR / "package_release.py").is_file(),
                                reason="needs git and the repository's deploy/ directory")

PACKAGER = DEPLOY_DIR / "package_release.py"
HOST = DEPLOY_DIR / "release-host.sh"


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t",
                           "-c", "commit.gpgsign=false", *args],
                          capture_output=True, text=True, check=True).stdout


def _write(root: Path, relative: str, text: str) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


@pytest.fixture
def repo(tmp_path) -> Path:
    """A repository shaped like this one: worker -> A -> B, fixtures read by B's tests."""
    root = tmp_path / "repo"
    files = {
        "Tools/CloudWorker/Package.swift":
            '// swift-tools-version:5.9\nlet package = Package(name: "w", dependencies: [\n'
            '    .package(path: "../../Packages/A"),\n'
            '    // .package(path: "../../Packages/Ghost"),\n'
            '    .package(url: "https://github.com/example/remote.git", exact: "1.0.0"),\n])\n',
        "Tools/CloudWorker/Package.resolved": '{"pins": [], "version": 2}\n',
        "Tools/CloudWorker/Sources/w/main.swift": "print(1)\n",
        "Tools/CloudWorker/Tests/wTests/T.swift": 'let x = "fixtures/data.json"\n',
        "Packages/A/Package.swift": 'let package = Package(dependencies: [.package(path: "../B")])\n',
        "Packages/A/Sources/A/a.swift": "let a = 1\n",
        "Packages/B/Package.swift": "let package = Package(name: \"B\")\n",
        "Packages/B/Tests/BTests/B.swift":
            'let o = "android/app/oracle.json"; let m = "Tools/Missing/y.json"\n'
            'let j = "application/json"; let r = "Resources/local.json"\n',
        "Packages/Unused/Package.swift": "let package = Package(name: \"Unused\")\n",
        "contracts/README.md": "contracts\n",
        "Tools/ActivityContext/activity_context/__init__.py": "\n",
        "Tools/InferenceWorker/uv.lock": "lock\n",
        "Tools/InferenceWorker/models/manifest.json": '{"entries": []}\n',
        "Tools/InferenceWorker/src/frwhoop_inference/__init__.py": "\n",
        "LICENSE": "PolyForm Noncommercial 1.0.0\n",
        "NOTICE": "notice\n",
        "ATTRIBUTION.md": "attribution\n",
        "android/app/oracle.json": "{}\n",
        "fixtures/data.json": "{}\n",
        "Strand/App.swift": "app code that is not part of the worker release\n",
    }
    for relative, text in files.items():
        _write(root, relative, text)
    (root / "deploy").mkdir()
    for name in ("package_release.py", "package-release.sh", "release-host.sh"):
        shutil.copy2(DEPLOY_DIR / name, root / "deploy" / name)
    _git(root, "init", "-q", "-b", "main")
    _git(root, "add", "-A")
    _git(root, "commit", "-q", "-m", "first")
    return root


def _package(repo: Path, out: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(repo / "deploy" / "package_release.py"), "--out",
                           str(out), *extra], capture_output=True, text=True)


def _extract(tarball: Path, dest: Path) -> Path:
    with tarfile.open(tarball) as archive:
        archive.extractall(dest, filter="data")
    (only,) = list(dest.iterdir())
    return only


def test_the_release_holds_the_derived_closure_and_a_stamp(repo, tmp_path):
    out = tmp_path / "out"
    proc = _package(repo, out)
    assert proc.returncode == 0, proc.stderr
    commit = _git(repo, "rev-parse", "HEAD").strip()
    tarball = out / f"nara-release-{commit}.tar.gz"
    assert tarball.is_file()
    assert (out / f"{tarball.name}.sha256").read_text().split()[0] == hashlib.sha256(
        tarball.read_bytes()).hexdigest()
    assert (out / "release-host.sh").read_bytes() == (repo / "deploy" / "release-host.sh").read_bytes()
    assert os.access(out / "release-host.sh", os.X_OK)

    release = _extract(tarball, tmp_path / "x")
    assert release.name == f"nara-release-{commit}"
    stamp = json.loads((release / "RELEASE.json").read_text())
    assert stamp == json.loads((out / f"nara-release-{commit}.release.json").read_text())
    assert stamp["schema"] == "nara-release-stamp/1"
    assert stamp["release_id"] == stamp["git_commit"] == commit
    assert stamp["git_tree"] == _git(repo, "rev-parse", "HEAD^{tree}").strip()
    assert stamp["dirty"] is False
    assert stamp["local_packages"] == [
        {"path": "Packages/A", "declared_by": "Tools/CloudWorker"},
        {"path": "Packages/B", "declared_by": "Packages/A"},
    ], "derived from Package.swift; the commented-out Ghost and the remote package are not local"
    assert stamp["test_fixture_paths"] == ["android/app/oracle.json", "fixtures/data.json"]
    assert stamp["unresolved_test_paths"] == ["Tools/Missing/y.json"]
    assert "Packages/Unused" not in stamp["included_paths"]
    assert not (release / "Strand").exists() and not (release / "Packages" / "Unused").exists()
    for path in ("Tools/CloudWorker", "Packages/A", "Packages/B", "contracts", "deploy",
                 "Tools/ActivityContext", "Tools/InferenceWorker", "LICENSE", "NOTICE"):
        assert path in stamp["included_paths"]
        assert (release / path).exists()
    for key, path in (("package_resolved_sha256", "Tools/CloudWorker/Package.resolved"),
                      ("uv_lock_sha256", "Tools/InferenceWorker/uv.lock"),
                      ("manifest_sha256", "Tools/InferenceWorker/models/manifest.json")):
        assert stamp[key] == hashlib.sha256((release / path).read_bytes()).hexdigest()

    files_text = (release / "RELEASE.files").read_bytes()
    assert stamp["files"]["sha256"] == hashlib.sha256(files_text).hexdigest()
    listed = [line.split("  ", 1)[1] for line in files_text.decode().splitlines()]
    assert listed == sorted(listed) and len(listed) == stamp["files"]["count"]
    for line in files_text.decode().splitlines():
        digest, path = line.split("  ", 1)
        assert hashlib.sha256((release / path).read_bytes()).hexdigest() == digest

    from frwhoop_inference.identity import SOURCE_TREE_KEY, tree_sha256
    assert stamp["trees"][SOURCE_TREE_KEY] == tree_sha256(str(release / SOURCE_TREE_KEY))[0]

    verify = subprocess.run([sys.executable, str(PACKAGER), "verify", str(release)],
                            capture_output=True, text=True)
    assert verify.returncode == 0, verify.stdout
    (release / "Packages" / "A" / "Sources" / "A" / "a.swift").write_text("let a = 2\n")
    (release / "Tools" / "CloudWorker" / ".build").mkdir()
    (release / "Tools" / "CloudWorker" / ".build" / "product").write_text("built on the host\n")
    tampered = subprocess.run([sys.executable, str(PACKAGER), "verify", str(release)],
                              capture_output=True, text=True)
    assert tampered.returncode == 1
    assert "changed: Packages/A/Sources/A/a.swift" in tampered.stdout
    assert ".build/product" not in tampered.stdout, "build output is not a stamp violation"


def test_a_dirty_tree_is_refused_unless_explicitly_stamped_dirty(repo, tmp_path):
    (repo / "Packages" / "B" / "Package.swift").write_text('let package = Package(name: "B2")\n')
    (repo / "Strand" / "App.swift").write_text("unrelated edit\n")
    refused = _package(repo, tmp_path / "out")
    assert refused.returncode == 1
    assert "uncommitted changes" in refused.stderr and "Packages/B/Package.swift" in refused.stderr
    assert not (tmp_path / "out").exists() or not list((tmp_path / "out").glob("*.tar.gz"))

    head_tree = _git(repo, "rev-parse", "HEAD^{tree}").strip()
    stash_before = _git(repo, "stash", "list")
    allowed = _package(repo, tmp_path / "out", "--allow-dirty")
    assert allowed.returncode == 0, allowed.stderr
    (tarball,) = list((tmp_path / "out").glob("*.tar.gz"))
    release = _extract(tarball, tmp_path / "x")
    stamp = json.loads((release / "RELEASE.json").read_text())
    assert stamp["dirty"] is True
    assert stamp["release_id"].startswith(stamp["git_commit"] + "-dirty-")
    assert stamp["git_tree"] != head_tree
    assert (release / "Packages" / "B" / "Package.swift").read_text() == 'let package = Package(name: "B2")\n'
    # The repository itself is untouched: same HEAD, nothing staged, no stash entry.
    assert _git(repo, "rev-parse", "HEAD^{tree}").strip() == head_tree
    assert _git(repo, "diff", "--cached", "--name-only") == ""
    assert _git(repo, "stash", "list") == stash_before


def test_a_declared_local_dependency_that_is_missing_fails_the_package(repo, tmp_path):
    (repo / "Packages" / "A" / "Package.swift").write_text(
        'let package = Package(dependencies: [.package(path: "../B"), .package(path: "../Nope")])\n')
    _git(repo, "commit", "-qam", "depend on a package that is not there")
    proc = _package(repo, tmp_path / "out")
    assert proc.returncode == 1
    assert "Packages/Nope (declared by Packages/A/Package.swift) has no Package.swift" in proc.stderr


def test_an_older_commit_can_be_packaged_while_the_tree_is_dirty(repo, tmp_path):
    first = _git(repo, "rev-parse", "HEAD").strip()
    (repo / "contracts" / "README.md").write_text("second\n")
    _git(repo, "commit", "-qam", "second")
    (repo / "contracts" / "README.md").write_text("uncommitted\n")
    proc = _package(repo, tmp_path / "out", "--rev", first)
    assert proc.returncode == 0, proc.stderr
    release = _extract(tmp_path / "out" / f"nara-release-{first}.tar.gz", tmp_path / "x")
    assert (release / "contracts" / "README.md").read_text() == "contracts\n"
    assert json.loads((release / "RELEASE.json").read_text())["dirty"] is False


def test_this_repository_packages_the_worker_with_all_four_local_packages():
    proc = subprocess.run([sys.executable, str(PACKAGER), "--out", os.devnull, "--rev", "HEAD",
                           "--dry-run"], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    plan = json.loads(proc.stdout)
    assert [p["path"] for p in plan["closure"]] == [
        "Packages/StrandAnalytics", "Packages/WhoopProtocol", "Packages/WhoopStore",
        "Packages/OuraProtocol"]
    assert {"declared_by": "Packages/WhoopStore", "path": "Packages/OuraProtocol"} in plan["closure"]
    for path in ("Tools/CloudWorker", "contracts", "deploy", "Tools/ActivityContext",
                 "Tools/InferenceWorker", "LICENSE", "Tools/MetricInsight/tests/data",
                 "android/app/src/test/resources/schema_oracle.json",
                 "android/app/src/test/resources/local_day_windows_oracle.json"):
        assert path in plan["paths"], path
    assert plan["unresolved"] == []


# --------------------------------------------------------------------------
# release-host.sh: install, switch, rollback, status (no toolchain needed)
# --------------------------------------------------------------------------


def _host(root: Path, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "FRWHOOP_SYSTEMD_DIR": str(root / "no-systemd")}
    return subprocess.run(["bash", str(HOST), "--root", str(root), *args], capture_output=True,
                          text=True, env=env)


def _fake_build(release: Path) -> None:
    """What `build` leaves behind, without a Swift toolchain: a binary and its build record."""
    binary = release / "Tools" / "CloudWorker" / ".build" / "release" / "frwhoop-worker"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\necho '{\"schema\": \"worker-identity/1\", \"matches_release\": true}'\n")
    binary.chmod(0o755)
    record = {"schema": "nara-release-build/1", "executables": {"frwhoop-worker": {
        "path": "Tools/CloudWorker/.build/release/frwhoop-worker",
        "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}}, "built_at_utc": "now"}
    (release / "BUILD.json").write_text(json.dumps(record))


def test_releases_install_fresh_switch_atomically_and_roll_back(repo, tmp_path):
    out = tmp_path / "out"
    assert _package(repo, out).returncode == 0
    first = _git(repo, "rev-parse", "HEAD").strip()
    (repo / "contracts" / "README.md").write_text("second\n")
    _git(repo, "commit", "-qam", "second")
    second = _git(repo, "rev-parse", "HEAD").strip()
    assert _package(repo, out).returncode == 0
    root = tmp_path / "noop"

    installed = _host(root, "install", str(out / f"nara-release-{first}.tar.gz"))
    assert installed.returncode == 0, installed.stderr
    assert "tarball sha256 verified" in installed.stdout
    release = root / "releases" / first
    assert (release / "RELEASE.json").is_file()
    again = _host(root, "install", str(out / f"nara-release-{first}.tar.gz"))
    assert again.returncode == 1 and "never extracted over an existing tree" in again.stderr
    assert not [p for p in (root / "releases").iterdir() if p.name.startswith(".incoming")]

    unbuilt = _host(root, "switch", first)
    assert unbuilt.returncode == 1 and "not built" in unbuilt.stderr
    assert not (root / "current").exists()

    _fake_build(release)
    switched = _host(root, "switch", first)
    assert switched.returncode == 0, switched.stderr
    assert os.readlink(root / "current") == f"releases/{first}"
    assert not (root / "previous").exists()

    assert _host(root, "install", str(out / f"nara-release-{second}.tar.gz")).returncode == 0
    _fake_build(root / "releases" / second)
    assert _host(root, "switch", second).returncode == 0
    assert os.readlink(root / "current") == f"releases/{second}"
    assert os.readlink(root / "previous") == f"releases/{first}"

    rolled = _host(root, "rollback")
    assert rolled.returncode == 0, rolled.stderr
    assert os.readlink(root / "current") == f"releases/{first}"
    assert os.readlink(root / "previous") == f"releases/{second}"
    status = _host(root, "status")
    assert status.returncode == 0
    assert f"current:  {first}" in status.stdout and f"previous: {second}" in status.stdout
    assert '"matches_release": true' in status.stdout

    # A binary changed after its build record was written is never selected.
    binary = root / "releases" / second / "Tools" / "CloudWorker" / ".build" / "release" / "frwhoop-worker"
    binary.write_text("#!/bin/sh\necho swapped\n")
    refused = _host(root, "switch", second)
    assert refused.returncode == 1 and "changed since it was built" in refused.stderr
    assert os.readlink(root / "current") == f"releases/{first}"


def test_a_tarball_that_does_not_match_its_checksum_is_refused(repo, tmp_path):
    out = tmp_path / "out"
    assert _package(repo, out).returncode == 0
    (tarball,) = list(out.glob("*.tar.gz"))
    (out / f"{tarball.name}.sha256").write_text(f"{'0' * 64}  {tarball.name}\n")
    proc = _host(tmp_path / "noop", "install", str(tarball))
    assert proc.returncode == 1 and "tarball sha256" in proc.stderr
    assert not list((tmp_path / "noop" / "releases").glob("[0-9a-f]*"))
