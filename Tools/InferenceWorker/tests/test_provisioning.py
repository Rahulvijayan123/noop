"""Model provisioning: plan, stage, verify, probe, select (Spec 01 section 1).

Acceptance fixture: the real committed manifest is enumerated; a revision is staged with the
real SleepECG artifacts from the installed wheel and the optional artifacts from local fixture
bytes; a bad required artifact rejects the new revision and leaves the previous one selected
with its bytes intact; a missing optional artifact withholds only its own provider; and the
provisioner's model section runs from another directory, unprivileged, through the same code.
Nothing here touches the network.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import urllib.error

import pytest

from frwhoop_inference.artifacts import (load_manifest, plan_manifest, required_providers,
                                         verify_manifest)
from provision_support import (DEPLOY_DIR, MATERIALIZER, OPTIONAL_ENTRIES, REAL_MANIFEST,
                               REPO_PACKAGE_ROOT, SERVICE_UNIT, StubFetcher, load_materializer,
                               manifest_with_fixture_optionals, ready_probe, read_json_stdout,
                               subprocess_env, tree_snapshot)

mm = load_materializer()

SLEEPECG = "sleepecg.wrn-gru-mesa.v1"


def _real_counts() -> tuple[int, int]:
    document = json.loads(REAL_MANIFEST.read_text())
    return len(document["entries"]), sum(len(e["artifacts"]) for e in document["entries"])


def _service_env(**flags: str) -> dict[str, str]:
    env = mm.service_environment(unit_path=str(SERVICE_UNIT), env_file=None)
    env.update(flags)
    return env


def _stage(models_root, manifest, **kwargs):
    kwargs.setdefault("fetcher", None)
    kwargs.setdefault("probe", ready_probe())
    kwargs.setdefault("service_env", _service_env())
    kwargs.setdefault("log", lambda message: None)
    return mm.stage_revision(str(models_root), str(manifest), **kwargs)


def _current(models_root) -> str:
    return os.readlink(os.path.join(models_root, "current"))


def _staging_dirs(models_root) -> list[str]:
    return [n for n in os.listdir(os.path.join(models_root, "revisions")) if n.startswith(".")]


# --------------------------------------------------------------------------
# (a) the real schema, enumerated
# --------------------------------------------------------------------------


def test_the_plan_enumerates_every_entry_and_nested_artifact_of_the_real_manifest():
    entries, artifacts = _real_counts()
    assert (entries, artifacts) == (11, 18), "the committed manifest at this branch"
    plan = plan_manifest(load_manifest(str(REAL_MANIFEST)))
    assert len(plan) == artifacts
    assert len({p.entry_id for p in plan}) == entries - 2, "hypnospy and stepcount have no artifacts"

    by_action: dict[str, set[str]] = {}
    for p in plan:
        by_action.setdefault(p.action, set()).add(f"{p.entry_id}/{p.name}")
    assert by_action["stage"] == {
        "sleepecg_wrn_gru_mesa/wrn-gru-mesa.zip",
        "sleepecg_wrn_gru_mesa/classifier.keras",
        "paradigma/tremor_detection_clf_package.pkl",
        "paradigma/gait_detection_clf_package.pkl",
        "paradigma/gait_filtering_clf_package.pkl",
        "deepbeat/deepbeat.h5",
        "siamaf/final_model.pt",
    }
    assert by_action["check_installed"] == {"neurokit2/neurokit2-0.2.13-py3-none-any.whl"}
    assert by_action["record"] == {"neurokit2/neurokit2-0.2.13.tar.gz"}
    assert by_action["skip"] == {
        "wav2sleep/state_dict.pth", "wav2sleep/config.yaml",
        "no_eeg_sleep_staging/lgbm_stage4.txt", "no_eeg_sleep_staging/lgbm_stage2.txt",
        "no_eeg_sleep_staging/meta.json", "no_eeg_sleep_staging/sample_night.csv",
        "rr_estimation/RR_Estimation_Model.h5",
        "cnn_wrist_model_freeliving/best_model.013-0.28.h5",
        "cnn_wrist_model_freeliving/best_model.007-0.36.h5",
    }
    reasons = {p.entry_id: p.reason for p in plan if p.action == "skip"}
    assert "blocked_input" in reasons["wav2sleep"] and "blocked_input" in reasons["rr_estimation"]
    assert "blocked_license" in reasons["cnn_wrist_model_freeliving"]
    assert "unverified" in reasons["no_eeg_sleep_staging"]
    assert {p.source_kind for p in plan if p.entry_id == "sleepecg_wrn_gru_mesa"} == {
        "wheel_resource", "zip_member"}
    assert all(p.required_for_readiness for p in plan if p.entry_id == "sleepecg_wrn_gru_mesa")
    assert not any(p.required_for_readiness for p in plan if p.entry_id in OPTIONAL_ENTRIES)
    assert required_providers(load_manifest(str(REAL_MANIFEST))) == [SLEEPECG]


def test_blocked_and_unwired_entries_are_never_fetched(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    fetcher = StubFetcher(served)
    plan = plan_manifest(load_manifest(str(manifest)))
    results = mm.materialize(plan, mm.MaterializeContext(root=str(tmp_path / "root"), fetcher=fetcher))
    assert sorted(fetcher.calls) == sorted(served), "only the five optional url artifacts"
    blocked_urls = {p.url for p in plan if p.action in ("skip", "record")}
    assert not blocked_urls & set(fetcher.calls)
    statuses = {f"{r.planned.entry_id}/{r.planned.name}": r.status for r in results}
    assert statuses["wav2sleep/state_dict.pth"] == "skipped"
    assert statuses["neurokit2/neurokit2-0.2.13.tar.gz"] == "recorded"
    assert statuses["neurokit2/neurokit2-0.2.13-py3-none-any.whl"] == "installed"
    assert all(r.status == "verified" for r in results if r.planned.action == "stage")


def test_the_cli_plan_prints_the_same_enumeration():
    proc = subprocess.run([sys.executable, str(MATERIALIZER), "plan"], capture_output=True,
                          text=True, env=subprocess_env())
    assert proc.returncode == 0, proc.stderr
    document = read_json_stdout(proc.stdout)
    assert (document["entries"], document["artifacts"]) == _real_counts()
    assert len(document["plan"]) == document["artifacts"]


# --------------------------------------------------------------------------
# (b) a complete revision: real SleepECG bytes, fixture optional bytes, real probe
# --------------------------------------------------------------------------


def test_a_complete_revision_is_staged_verified_probed_and_selected(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    models = tmp_path / "models"
    fetcher = StubFetcher(served)
    report = _stage(models, manifest, fetcher=fetcher, probe=mm.probe_readiness,
                    probe_python=sys.executable)
    assert report.outcome == "selected", report.reason
    assert _current(models) == f"revisions/{report.revision_id}"
    assert report.revision_id.startswith("rev-")
    assert sorted(fetcher.calls) == sorted(served)

    revision = models / "revisions" / report.revision_id
    assert (revision / "manifest.json").read_bytes() == manifest.read_bytes()
    document = json.loads((revision / "revision.json").read_text())
    assert document["schema"] == "frwhoop-model-revision/1"
    assert document["revision_id"] == report.revision_id
    assert document["manifest"]["sha256"] == hashlib.sha256(manifest.read_bytes()).hexdigest()
    assert (document["manifest"]["entries"], document["manifest"]["artifacts"]) == _real_counts()
    assert document["staged_by"]["source"] in ("git", "release_stamp", "unknown")
    assert len(document["staged_by"]["materializer_sha256"]) == 64
    assert document["created_at_utc"].endswith("Z")
    staged = {f"{a['entry_id']}/{a['name']}": a for a in document["artifacts"]}
    assert len(staged) == _real_counts()[1]
    zip_record = staged["sleepecg_wrn_gru_mesa/wrn-gru-mesa.zip"]
    assert zip_record["status"] == "verified" and zip_record["origin"].startswith("wheel:sleepecg")
    assert staged["sleepecg_wrn_gru_mesa/classifier.keras"]["origin"].startswith("zip:wrn-gru-mesa.zip")
    assert all(staged[f"{e}/{a}"]["status"] == "verified" for e, a in (
        ("deepbeat", "deepbeat.h5"), ("siamaf", "final_model.pt"),
        ("paradigma", "tremor_detection_clf_package.pkl")))
    assert document["withheld"] == []
    assert document["required_providers"] == [SLEEPECG]

    # The real probe built the sidecar's own Application against the staged root.
    probe = document["probe"]
    assert probe["ok"] is True
    assert probe["providers"][SLEEPECG]["ready"] is True, probe["providers"][SLEEPECG]
    assert probe["providers"]["production.runs.v1"]["ready"] is True

    # Read-only, and the sidecar's verifier accepts the selected root as it stands.
    for path in revision.rglob("*"):
        mode = stat.S_IMODE(path.lstat().st_mode)
        assert mode & 0o222 == 0, f"{path} is writable ({oct(mode)})"
    state = verify_manifest(load_manifest(str(revision / "manifest.json")),
                            str(models / "current"), manifest_path=str(revision / "manifest.json"))
    assert state.ok is True
    assert {c.entry_id for c in state.checks if c.status == "verified"} == {
        "sleepecg_wrn_gru_mesa", *OPTIONAL_ENTRIES}
    assert _staging_dirs(models) == []


def test_restaging_the_same_manifest_and_bytes_is_idempotent(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    models = tmp_path / "models"
    first = _stage(models, manifest, fetcher=StubFetcher(served))
    assert first.outcome == "selected"
    before = tree_snapshot(models / "revisions")
    offline = _stage(models, manifest, fetcher=None)  # bytes come from the existing revision
    assert offline.outcome == "unchanged"
    assert offline.revision_id == first.revision_id
    assert sorted(os.listdir(models / "revisions")) == [first.revision_id]
    assert tree_snapshot(models / "revisions") == before


# --------------------------------------------------------------------------
# (c) a bad required artifact rejects the revision and keeps the previous one
# --------------------------------------------------------------------------


@pytest.fixture
def selected_previous(tmp_path):
    """A models root whose current revision is a verified, complete one."""
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    models = tmp_path / "models"
    report = _stage(models, manifest, fetcher=StubFetcher(served))
    assert report.outcome == "selected"
    return models, manifest, served, report.revision_id


def _assert_previous_kept(models, previous_id, snapshot):
    assert _current(models) == f"revisions/{previous_id}"
    assert sorted(os.listdir(models / "revisions")) == [previous_id]
    assert tree_snapshot(models / "revisions") == snapshot, "the previous revision's bytes changed"
    revision = models / "revisions" / previous_id
    state = verify_manifest(load_manifest(str(revision / "manifest.json")), str(revision))
    assert state.ok is True


def test_a_corrupted_required_artifact_rejects_and_keeps_the_previous_revision(
        tmp_path, selected_previous):
    models, _, served, previous_id = selected_previous
    snapshot = tree_snapshot(models / "revisions")
    import sleepecg

    real = os.path.join(os.path.dirname(sleepecg.__file__), "classifiers", "wrn-gru-mesa.zip")
    corrupted = tmp_path / "corrupted-wrn-gru-mesa.zip"
    blob = bytearray(open(real, "rb").read())
    blob[100] ^= 0xFF
    corrupted.write_bytes(bytes(blob))
    # A different manifest digest, so this is a new revision attempt, not a reuse.
    bumped = json.loads(REAL_MANIFEST.read_text())
    bumped["notes"].append("rejection test")
    manifest = tmp_path / "bumped.json"
    manifest.write_text(json.dumps(bumped))
    probe = ready_probe()
    report = _stage(models, manifest, fetcher=StubFetcher(served), probe=probe,
                    locate_resource=lambda package, resource: str(corrupted))
    assert report.outcome == "rejected"
    assert report.exit_code == 1
    assert "sleepecg_wrn_gru_mesa/wrn-gru-mesa.zip (missing)" in report.reason
    assert "sleepecg_wrn_gru_mesa/classifier.keras (missing)" in report.reason
    statuses = {a["name"]: a["status"] for a in report.revision["artifacts"]}
    assert statuses["wrn-gru-mesa.zip"] == "sha256_mismatch"
    assert probe.calls == [], "a revision missing a required artifact is never probed"
    _assert_previous_kept(models, previous_id, snapshot)
    assert _staging_dirs(models) == []


def test_a_missing_required_artifact_rejects_and_keeps_the_previous_revision(selected_previous, tmp_path):
    models, _, served, previous_id = selected_previous
    snapshot = tree_snapshot(models / "revisions")
    bumped = json.loads(REAL_MANIFEST.read_text())
    bumped["notes"].append("missing wheel test")
    manifest = tmp_path / "bumped.json"
    manifest.write_text(json.dumps(bumped))

    def unavailable(package, resource):
        raise ModuleNotFoundError(package)

    report = _stage(models, manifest, fetcher=StubFetcher(served), locate_resource=unavailable)
    assert report.outcome == "rejected"
    assert "required artifact failed verification" in report.reason
    _assert_previous_kept(models, previous_id, snapshot)


def test_a_required_provider_that_is_not_ready_rejects(selected_previous, tmp_path):
    models, manifest, served, previous_id = selected_previous
    snapshot = tree_snapshot(models / "revisions")
    bumped = json.loads(manifest.read_text())
    bumped["notes"].append("probe test")
    other = tmp_path / "other.json"
    other.write_text(json.dumps(bumped))
    report = _stage(models, other, fetcher=StubFetcher(served),
                    probe=ready_probe(not_ready={SLEEPECG: "dependency_missing: keras"}))
    assert report.outcome == "rejected"
    assert report.reason.startswith("required provider not ready: sleepecg.wrn-gru-mesa.v1")
    _assert_previous_kept(models, previous_id, snapshot)

    failed = _stage(models, other, fetcher=StubFetcher(served), probe=ready_probe(ok=False))
    assert failed.outcome == "rejected" and "readiness probe failed" in failed.reason
    _assert_previous_kept(models, previous_id, snapshot)


def test_an_existing_revision_with_other_bytes_is_never_reused(selected_previous):
    models, manifest, served, previous_id = selected_previous
    revision = models / "revisions" / previous_id
    target = revision / "deepbeat" / "f54004a80e" / "deepbeat.h5"
    os.chmod(target.parent, 0o755)
    os.chmod(target, 0o644)
    target.write_bytes(b"tampered")
    report = _stage(models, manifest, fetcher=StubFetcher(served))
    assert report.outcome == "rejected"
    assert f"revisions/{previous_id} already exists" in report.reason
    assert _current(models) == f"revisions/{previous_id}"


# --------------------------------------------------------------------------
# (d) a missing optional artifact withholds only its own provider
# --------------------------------------------------------------------------


def test_a_missing_optional_artifact_withholds_only_its_provider(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    deepbeat_url = next(url for url in served if url.endswith("deepbeat.h5"))
    models = tmp_path / "models"
    report = _stage(models, manifest, fetcher=StubFetcher(served, fail=(deepbeat_url,)),
                    probe=mm.probe_readiness, probe_python=sys.executable,
                    service_env=_service_env(FRWHOOP_DEEPBEAT_SHADOW_ENABLED="1"))
    assert report.outcome == "selected", report.reason
    assert report.revision["withheld"] == [{
        "provider_id": "sensor.biomarkers.rhythm.v1", "entry_id": "deepbeat",
        "artifacts": ["deepbeat.h5 (missing)"], "required": False,
        "reason": "optional artifact unavailable: deepbeat.h5 (missing)"}]
    statuses = {f"{a['entry_id']}/{a['name']}": a["status"] for a in report.revision["artifacts"]}
    assert statuses["deepbeat/deepbeat.h5"] == "missing"
    assert statuses["siamaf/final_model.pt"] == "verified"
    assert statuses["sleepecg_wrn_gru_mesa/classifier.keras"] == "verified"

    providers = report.revision["probe"]["providers"]
    rhythm = providers["sensor.biomarkers.rhythm.v1"]
    assert rhythm["ready"] is False and "deepbeat" in rhythm["reason"]
    others = {pid: s["ready"] for pid, s in providers.items() if pid != "sensor.biomarkers.rhythm.v1"}
    assert others and all(others.values()), others
    assert report.revision["probe"]["flags"] == {"FRWHOOP_DEEPBEAT_SHADOW_ENABLED": "1"}

    revision = models / "revisions" / report.revision_id
    state = verify_manifest(load_manifest(str(revision / "manifest.json")), str(revision))
    assert state.ok is True, "an optional artifact never gates the verifier"
    assert [c.status for c in state.checks if c.entry_id == "deepbeat"] == ["missing"]


def test_a_partial_revision_and_the_complete_one_have_different_ids(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    siamaf_url = next(url for url in served if url.endswith("final_model.pt"))
    models = tmp_path / "models"
    partial = _stage(models, manifest, fetcher=StubFetcher(served, fail=(siamaf_url,)))
    complete = _stage(models, manifest, fetcher=StubFetcher(served))
    assert partial.outcome == complete.outcome == "selected"
    assert partial.revision_id != complete.revision_id
    assert complete.previous == partial.revision_id
    assert _current(models) == f"revisions/{complete.revision_id}"


# --------------------------------------------------------------------------
# (e) the provisioner's model section, relative, unprivileged, from another cwd
# --------------------------------------------------------------------------


def _shims(tmp_path):
    """apt-get/systemctl/useradd/curl that leave a marker: the model section must use none."""
    bin_dir = tmp_path / "shims"
    bin_dir.mkdir()
    marker = tmp_path / "privileged-tool-called"
    for tool in ("apt-get", "systemctl", "useradd", "curl", "systemd-analyze"):
        script = bin_dir / tool
        script.write_text(f"#!/bin/sh\necho {tool} >> '{marker}'\nexit 99\n")
        script.chmod(0o755)
    return bin_dir, marker


def _provision(args, *, cwd, tmp_path, **env):
    bin_dir, marker = _shims(tmp_path) if not (tmp_path / "shims").exists() else (
        tmp_path / "shims", tmp_path / "privileged-tool-called")
    environment = subprocess_env(PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", **env)
    proc = subprocess.run(["bash", *args], cwd=cwd, capture_output=True, text=True,
                          env=environment, timeout=900)
    return proc, marker


def _common(models):
    return ["--models-only", "--models-root", str(models), "--python", sys.executable, "--offline"]


def test_the_provisioner_model_section_runs_relative_and_unprivileged(tmp_path):
    """The documented relative form, from the sidecar package directory, with the real probe."""
    models = tmp_path / "models"
    proc, marker = _provision(["../../deploy/provision.sh", *_common(models)], cwd=REPO_PACKAGE_ROOT,
                              tmp_path=tmp_path)
    assert proc.returncode == 0, proc.stderr[-3000:]
    report = read_json_stdout(proc.stdout)
    assert report["outcome"] == "selected"
    assert _current(models) == f"revisions/{report['revision_id']}"
    statuses = {f"{a['entry_id']}/{a['name']}": a["status"] for a in report["revision"]["artifacts"]}
    assert statuses["sleepecg_wrn_gru_mesa/wrn-gru-mesa.zip"] == "verified"
    assert statuses["sleepecg_wrn_gru_mesa/classifier.keras"] == "verified"
    assert statuses["deepbeat/deepbeat.h5"] == "missing", "offline: never fetched"
    assert report["probe"]["providers"][SLEEPECG]["ready"] is True
    assert not marker.exists(), marker.read_text() if marker.exists() else ""


def test_the_provisioner_model_section_is_idempotent_from_another_cwd(tmp_path):
    """Same manifest and bytes, run through a relative path from an unrelated directory."""
    models = tmp_path / "models"
    existing = _stage(models, REAL_MANIFEST)  # the same code path, with a fast probe
    snapshot = tree_snapshot(models / "revisions")
    elsewhere = tmp_path / "some" / "other" / "cwd"
    elsewhere.mkdir(parents=True)
    relative = os.path.relpath(DEPLOY_DIR / "provision.sh", elsewhere)
    assert not os.path.isabs(relative) and relative.startswith("..")
    proc, marker = _provision([relative, *_common(models)], cwd=elsewhere, tmp_path=tmp_path)
    assert proc.returncode == 0, proc.stderr[-3000:]
    report = read_json_stdout(proc.stdout)
    assert report["outcome"] == "unchanged"
    assert report["revision_id"] == existing.revision_id
    assert report["probe"]["providers"][SLEEPECG]["ready"] is True
    assert sorted(os.listdir(models / "revisions")) == [existing.revision_id]
    assert tree_snapshot(models / "revisions") == snapshot
    assert not marker.exists()


def test_the_provisioner_model_section_exits_nonzero_on_rejection(tmp_path):
    models = tmp_path / "models"
    previous = _stage(models, REAL_MANIFEST).revision_id
    snapshot = tree_snapshot(models / "revisions")

    bad = json.loads(REAL_MANIFEST.read_text())
    for entry in bad["entries"]:
        if entry["id"] == "sleepecg_wrn_gru_mesa":
            entry["artifacts"][0]["sha256"] = "0" * 64  # pins bytes the wheel does not have
    bad_manifest = tmp_path / "bad-manifest.json"
    bad_manifest.write_text(json.dumps(bad))
    proc, marker = _provision(["deploy/provision.sh", *_common(models)], cwd=DEPLOY_DIR.parent,
                              tmp_path=tmp_path, FRWHOOP_MODEL_MANIFEST=str(bad_manifest))
    assert proc.returncode == 1, proc.stderr[-3000:]
    report = read_json_stdout(proc.stdout)
    assert report["outcome"] == "rejected"
    assert "REJECTED" in proc.stderr
    _assert_previous_kept(models, previous, snapshot)
    assert not marker.exists()


def test_provision_sh_resolves_its_paths_before_any_cd():
    lines = (DEPLOY_DIR / "provision.sh").read_text().splitlines()
    code = [(i, line.strip()) for i, line in enumerate(lines) if line.strip()
            and not line.strip().startswith("#")]
    resolved_at = next(i for i, line in code if line.startswith("REPO_ROOT="))
    script_at = next(i for i, line in code if line.startswith("SCRIPT_DIR="))
    assert script_at < resolved_at
    for i, line in code:
        if i in (script_at, resolved_at):
            continue
        assert not (line.startswith("cd ") and i < resolved_at), line
    text = "\n".join(line for _, line in code)
    assert '$(dirname "$0")' not in text, "every path is derived from SCRIPT_DIR/REPO_ROOT"
    assert "ln -sfn" not in text, "symlinks are switched atomically"
    # Every remaining `cd` is inside a ( ... ) subshell, so the script's own cwd never moves.
    for i, line in code:
        if line.startswith("cd ") and i > resolved_at:
            opened = max(j for j, prior in code if j < i and prior == "(")
            closed = [j for j, later in code if opened < j < i and later.startswith(")")]
            assert not closed, f"line {i + 1}: cd outside a subshell"


# --------------------------------------------------------------------------
# Select (rollback), list, lock, legacy flat mode, unsafe paths, fetch bounds
# --------------------------------------------------------------------------


def test_select_rolls_back_to_an_older_revision_and_refuses_unknown_ones(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    models = tmp_path / "models"
    old = _stage(models, REAL_MANIFEST)  # offline: optional artifacts withheld
    new = _stage(models, manifest, fetcher=StubFetcher(served))
    assert _current(models) == f"revisions/{new.revision_id}"
    back = mm.select_revision(str(models), old.revision_id, log=lambda m: None)
    assert back.outcome == "selected" and _current(models) == f"revisions/{old.revision_id}"
    assert mm.select_revision(str(models), "rev-does-not-exist").outcome == "rejected"
    assert mm.select_revision(str(models), "../x").outcome == "rejected"
    listing = {row["revision_id"]: row for row in mm.list_revisions(str(models))}
    assert set(listing) == {old.revision_id, new.revision_id}
    assert listing[old.revision_id]["current"] is True
    assert "sensor.biomarkers.rhythm.v1" in listing[old.revision_id]["withheld"]


def test_a_second_provisioner_is_refused_while_one_holds_the_lock(tmp_path):
    models = tmp_path / "models"
    models.mkdir()
    fd = os.open(models / ".provision.lock", os.O_RDWR | os.O_CREAT)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with pytest.raises(mm.ProvisionBusy):
            _stage(models, REAL_MANIFEST)
        proc = subprocess.run([sys.executable, str(MATERIALIZER), "stage", "--models-root",
                               str(models), "--offline"], capture_output=True, text=True,
                              env=subprocess_env())
        assert proc.returncode == 3
    finally:
        os.close(fd)


def test_an_interrupted_staging_directory_is_cleaned_up(tmp_path):
    models = tmp_path / "models"
    stale = models / "revisions" / ".staging-interrupted"
    (stale / "sub").mkdir(parents=True)
    (stale / "sub" / "x").write_bytes(b"x")
    os.chmod(stale / "sub", 0o555)
    report = _stage(models, REAL_MANIFEST)
    assert report.outcome == "selected"
    assert _staging_dirs(models) == []


def test_a_current_that_is_a_real_directory_is_never_replaced(tmp_path):
    models = tmp_path / "models"
    (models / "current").mkdir(parents=True)
    report = _stage(models, REAL_MANIFEST)
    assert report.outcome == "rejected" and "not a symlink" in report.reason
    assert (models / "current").is_dir() and not (models / "current").is_symlink()


def test_the_original_flat_usage_still_materializes_the_sleepecg_root(tmp_path):
    dest = tmp_path / "flat"
    proc = subprocess.run([sys.executable, str(MATERIALIZER), str(dest)], capture_output=True,
                          text=True, env=subprocess_env())
    assert proc.returncode == 0, proc.stderr
    assert f"MODEL_ROOT {dest}" in proc.stdout
    state = verify_manifest(load_manifest(str(REAL_MANIFEST)), str(dest))
    assert state.ok is True
    assert all(c.status == "verified" for c in state.checks if c.required_for_readiness)
    assert not (dest / "revisions").exists()


def test_unsafe_artifact_paths_are_refused_by_the_plan_and_the_verifier(tmp_path):
    manifest = {"manifest_version": "t", "entries": [{
        "id": "evil", "status": "eligible", "wired": True, "provider_id": "p",
        "required_for_readiness": True,
        "artifacts": [{"name": "w", "path": "../outside.bin", "url": "https://example.invalid/w",
                       "source": {"kind": "url"}, "size_bytes": 1, "sha256": "0" * 64,
                       "verify_at_startup": True}]}]}
    with pytest.raises(ValueError, match="unsafe artifact path"):
        plan_manifest(manifest)
    state = verify_manifest(manifest, str(tmp_path))
    assert state.checks[0].status == "invalid_path" and state.ok is False
    path = tmp_path / "evil.json"
    path.write_text(json.dumps(manifest))
    report = _stage(tmp_path / "models", path)
    assert report.outcome == "rejected" and "manifest unusable" in report.reason


def test_network_fetch_refuses_plain_http_and_oversized_bodies(monkeypatch, tmp_path):
    with pytest.raises(mm.FetchError, match="non-https"):
        with open(tmp_path / "x", "wb") as out:
            mm.network_fetch("http://example.invalid/x", out, 10)

    class Body:
        def __init__(self, data):
            self.data = data

        def read(self, n):
            chunk, self.data = self.data[:n], self.data[n:]
            return chunk

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    opened: list[str] = []

    def oversized(request, timeout):
        opened.append(request.full_url)
        return Body(b"x" * 100)

    monkeypatch.setattr(mm.urllib.request, "urlopen", oversized)
    with open(tmp_path / "y", "wb") as out, pytest.raises(mm.FetchError, match="more than"):
        mm.network_fetch("https://example.invalid/y", out, 10)
    assert len(opened) == 1, "a body larger than the pin is not retried"

    attempts: list[int] = []

    def flaky(request, timeout):
        attempts.append(1)
        if len(attempts) == 1:
            raise urllib.error.URLError("reset")
        return Body(b"abc")

    monkeypatch.setattr(mm.urllib.request, "urlopen", flaky)
    with open(tmp_path / "z", "wb") as out:
        mm.network_fetch("https://example.invalid/z", out, 10)
    assert (tmp_path / "z").read_bytes() == b"abc" and len(attempts) == 2

    def down(request, timeout):
        attempts.append(1)
        raise urllib.error.URLError("down")

    attempts.clear()
    monkeypatch.setattr(mm.urllib.request, "urlopen", down)
    with open(tmp_path / "w", "wb") as out, pytest.raises(mm.FetchError):
        mm.network_fetch("https://example.invalid/w", out, 10)
    assert len(attempts) == 2, "bounded: two attempts"


def test_fetched_bytes_are_verified_before_they_are_installed(tmp_path):
    manifest, served = manifest_with_fixture_optionals(tmp_path)
    wrong = {url: b"not the pinned bytes" for url in served}
    plan = [p for p in plan_manifest(load_manifest(str(manifest))) if p.entry_id == "deepbeat"]
    root = tmp_path / "root"
    results = mm.materialize(plan, mm.MaterializeContext(root=str(root), fetcher=StubFetcher(wrong)))
    assert [r.status for r in results] == ["size_mismatch"]
    assert not [p for p in root.rglob("*") if p.is_file()], "nothing unverified is left behind"


def test_the_service_environment_comes_from_the_unit_and_its_environment_file(tmp_path):
    env_file = tmp_path / "inference.env"
    env_file.write_text("# comment\nFRWHOOP_MODEL_ROOT=/opt/frwhoop-models/current\n"
                        "FRWHOOP_DEEPBEAT_SHADOW_ENABLED=\"1\"\n\n")
    env = mm.service_environment(unit_path=str(SERVICE_UNIT), env_file=str(env_file))
    assert env["OMP_NUM_THREADS"] == "1" and env["UV_PYTHON_DOWNLOADS"] == "never"
    assert env["HOME"] == "/var/lib/frwhoop-inf"
    assert env["FRWHOOP_DEEPBEAT_SHADOW_ENABLED"] == "1"
    assert env["PATH"]


def test_the_service_user_can_enter_and_read_the_revision_it_probes(tmp_path):
    """The probe runs as the service user (``--probe-user frwhoop-inf``), not the owner. Every
    directory of the staged revision, its root included, must be traversable and every file
    readable by others when the probe starts, or a fresh host never gets a ``current``."""
    models = tmp_path / "models"
    seen: dict[str, object] = {}
    inner = ready_probe()

    def probe(root: str, **kwargs):
        seen["root"] = root
        modes = {}
        for dirpath, dirnames, filenames in os.walk(root):
            modes[dirpath] = os.stat(dirpath).st_mode
            for name in filenames:
                modes[os.path.join(dirpath, name)] = os.stat(os.path.join(dirpath, name)).st_mode
        seen["modes"] = modes
        return inner(root, **kwargs)

    report = _stage(models, REAL_MANIFEST, probe=probe)
    assert report.outcome == "selected", report.reason
    modes = seen["modes"]
    assert os.path.basename(seen["root"]).startswith(".staging"), "the probe saw the staged tree"
    assert stat.S_IMODE(modes[seen["root"]]) & 0o055 == 0o055, oct(modes[seen["root"]])
    for path, mode in modes.items():
        need = 0o005 if stat.S_ISDIR(mode) else 0o004
        assert mode & need == need, f"{path}: {oct(mode)} is not open to the service user"
    assert stat.S_IMODE(os.stat(models / "revisions").st_mode) & 0o005 == 0o005
    sealed = models / "revisions" / report.revision_id
    assert stat.S_IMODE(os.stat(sealed).st_mode) == 0o555


def test_the_probe_runs_with_the_service_users_groups_not_the_callers(monkeypatch):
    """``subprocess.run(user=)`` alone keeps root's groups; the probe gets the service user's."""
    import pwd

    class Entry:
        pw_name, pw_uid, pw_gid = "frwhoop-inf", 991, 991

    monkeypatch.setattr(pwd, "getpwnam", lambda name: Entry)
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setattr(os, "getgrouplist", lambda name, gid: [gid, 44, gid])
    assert mm.probe_identity("frwhoop-inf") == {"user": 991, "group": 991, "extra_groups": [44, 991]}
    assert mm.probe_identity(None) == {}

    calls = {}

    def fake_run(command, **kwargs):
        calls.update(kwargs)
        raise subprocess.TimeoutExpired(command, 0)

    monkeypatch.setattr(mm.shutil, "chown", lambda *a, **k: None)
    monkeypatch.setattr(mm.subprocess, "run", fake_run)
    result = mm.probe_readiness("/nonexistent", service_env={}, user="frwhoop-inf", timeout_s=1)
    assert result["ok"] is False
    assert (calls["user"], calls["group"], calls["extra_groups"]) == (991, 991, [44, 991])


def test_provision_sh_switches_the_sidecar_venv_only_after_the_revision_is_selected():
    """A rejected revision stops provision.sh (set -e) before the new release's venv is linked,
    so the running sidecar never pairs new code with a revision that code never probed."""
    text = (DEPLOY_DIR / "provision.sh").read_text()
    sidecar = text[text.index("== sidecar: pinned venv"):]
    probe_at = sidecar.index('provision_models "$VENV_DIR/bin/python"')
    switch_at = sidecar.index('switch_link "$VENV_DIR" "$SIDECAR_ROOT/venv"')
    assert probe_at < switch_at, "the venv link moved before the model revision was proven"
    assert sidecar.count('switch_link "$VENV_DIR"') == 1
    assert "set -euo pipefail" in text
