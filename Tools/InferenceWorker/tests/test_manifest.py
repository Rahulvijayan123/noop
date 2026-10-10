"""Model manifest and startup artifact verification tests."""

from __future__ import annotations

import hashlib
import json
import os

import pytest

from conftest import MANIFEST_PATH, REPO_PACKAGE_ROOT
from frwhoop_inference.artifacts import (
    CHECK_STATUSES,
    SOURCE_KINDS,
    STAGED_ENTRY_STATUSES,
    artifact_source,
    default_manifest_path,
    load_manifest,
    manifest_summary,
    sha256_file,
    verify_manifest,
)

REQUIRED_ENTRY_FIELDS = ("id", "kind", "name", "revision", "license", "rights_verdict",
                         "status", "input_contract")


def test_default_manifest_path_points_at_the_package_manifest():
    assert default_manifest_path() == MANIFEST_PATH


def test_manifest_has_the_eight_planned_entries(manifest_entries):
    # The eight planned entries, plus the additive sensor-biomarker entries
    # (docs/sensor-biomarkers/CONTRACTS.md section 7): optional research/shadow
    # lanes, appended after the planned list, order unchanged.
    ids = [e["id"] for e in manifest_entries]
    assert ids == ["neurokit2", "hypnospy", "sleepecg_wrn_gru_mesa", "wav2sleep",
                   "no_eeg_sleep_staging", "rr_estimation", "stepcount",
                   "cnn_wrist_model_freeliving",
                   "paradigma", "deepbeat", "siamaf", "recgym_cnn_transformer"]


def test_every_entry_declares_revision_license_rights_status_and_input_contract(manifest_entries):
    for entry in manifest_entries:
        for field_name in REQUIRED_ENTRY_FIELDS:
            assert entry.get(field_name), f"{entry.get('id')} is missing {field_name}"
        assert entry["status"] in ("eligible", "unverified", "shadow_eligible",
                                   "blocked_input", "blocked_license")
        assert entry["rights_verdict"] in ("clear", "unverified_license_metadata", "blocked")
        assert isinstance(entry["artifacts"], list)
        assert isinstance(entry["required_for_readiness"], bool)
        assert isinstance(entry["wired"], bool)


def test_artifact_entries_publish_size_and_digest(manifest_entries):
    for entry in manifest_entries:
        for artifact in entry["artifacts"]:
            assert artifact.get("name")
            assert artifact.get("url")
            assert isinstance(artifact.get("size_bytes"), int)
            digest = artifact.get("sha256")
            if entry["rights_verdict"] == "blocked":
                assert digest is None, "unlicensed bytes were never staged, so no digest exists"
            else:
                assert isinstance(digest, str) and len(digest) == 64


def test_only_the_landed_providers_are_wired(manifest_entries):
    """Wired entries: the HRV dependency, the two landed sleep candidates and
    the additive sensor-biomarker lanes (paradigma research; deepbeat/siamaf
    rhythm shadow)."""
    wired = {e["id"]: e["wired"] for e in manifest_entries}
    assert wired["neurokit2"] is True
    assert wired["hypnospy"] is True
    assert wired["sleepecg_wrn_gru_mesa"] is True
    assert wired["paradigma"] is True
    assert wired["deepbeat"] is True
    assert wired["siamaf"] is True
    assert wired["recgym_cnn_transformer"] is True
    assert all(value is False for key, value in wired.items()
               if key not in {"neurokit2", "hypnospy", "sleepecg_wrn_gru_mesa",
                              "paradigma", "deepbeat", "siamaf", "recgym_cnn_transformer"})


def test_blocked_models_stay_blocked(manifest_entries):
    by_id = {e["id"]: e for e in manifest_entries}
    assert by_id["stepcount"]["status"] == "blocked_license"
    assert by_id["cnn_wrist_model_freeliving"]["status"] == "blocked_license"
    assert by_id["cnn_wrist_model_freeliving"]["license"] == "none"
    assert by_id["wav2sleep"]["status"] == "blocked_input"
    assert by_id["rr_estimation"]["status"] == "blocked_input"
    assert by_id["no_eeg_sleep_staging"]["status"] == "unverified"
    # the two landed sleep candidates are no longer "unverified": they are shadow-eligible
    # (executed, non-publishable, accuracy unverified). Blocked entries are unchanged.
    assert by_id["sleepecg_wrn_gru_mesa"]["status"] == "shadow_eligible"
    assert by_id["hypnospy"]["status"] == "shadow_eligible"
    assert by_id["hypnospy"]["rights_verdict"] == "unverified_license_metadata"


def test_pinned_digests_match_the_research_findings(manifest_entries):
    by_id = {e["id"]: e for e in manifest_entries}
    artifacts = {a["name"]: a for e in manifest_entries for a in e["artifacts"]}
    assert artifacts["neurokit2-0.2.13-py3-none-any.whl"]["sha256"] == (
        "25f1414214e832341312b8f0deeaeeefb6d01e9b14d8723b71c67e99e0430c4c")
    assert artifacts["state_dict.pth"]["sha256"] == (
        "ea6fb4410315cf6cce406fe1ffd44cba83e8dc69be6a69101aff62cc2cbee0bc")
    assert artifacts["lgbm_stage4.txt"]["sha256"] == (
        "fe2f8f4c68a28a0a0c75b4f32f2bf2027f21b6e4527d7a2e0108fe7d75767700")
    assert artifacts["RR_Estimation_Model.h5"]["sha256"] == (
        "78fbddd1dbe23a23909c438fe33efa0fb45e2fd4044715705ef912d64b95d2af")
    assert artifacts["wrn-gru-mesa.zip"]["sha256"] == (
        "5622a858c855b0090e1fbcbdc35334ea459707c830eae1a26a4375e33091e869")
    assert by_id["wav2sleep"]["revision"].startswith("278e3046")
    assert by_id["rr_estimation"]["revision"].startswith("e429f1cc")
    assert by_id["no_eeg_sleep_staging"]["revision"].startswith("97d4ef19")
    assert by_id["stepcount"]["revision"].startswith("d7bc0c6e")
    assert by_id["cnn_wrist_model_freeliving"]["revision"].startswith("9ca77ea1")
    assert by_id["hypnospy"]["revision"] == "3b6c825d1568158cbf0058de50495e5308117d17"


def test_manifest_summary_exposes_the_capability_fields(manifest_entries):
    state = verify_manifest(load_manifest(MANIFEST_PATH), "/nonexistent", manifest_path=MANIFEST_PATH)
    summary = manifest_summary(state)
    assert len(summary) == 12
    assert all("status" in row and "input_contract" in row for row in summary)


def test_only_the_sleepecg_checkpoint_gates_readiness():
    """A wired MODEL artifact gates readiness; nothing else does.

    The HRV providers need no model bytes (production is pure numpy, the shadow dependency is
    installed from uv.lock and checked by import), and the vendored HypnosPy source ships
    in-repo, so it has no artifact to stage. Only the SleepECG checkpoint is required, and with
    an empty root it blocks - which must not touch any other provider (see
    ``test_healthz_reports_readiness_per_provider``).
    """
    state = verify_manifest(load_manifest(MANIFEST_PATH), "/nonexistent", manifest_path=MANIFEST_PATH)
    required = [c for c in state.checks if c.required_for_readiness]
    assert required, "the wired SleepECG checkpoint must gate readiness"
    assert {c.entry_id for c in required} == {"sleepecg_wrn_gru_mesa"}
    assert all(c.status == "missing" for c in required)
    assert state.ok is False
    assert "sleepecg_wrn_gru_mesa" in state.reason
    assert {c.status for c in state.checks} <= set(CHECK_STATUSES)
    optional = [c for c in state.checks if not c.required_for_readiness]
    assert all(c.entry_id != "sleepecg_wrn_gru_mesa" for c in optional)
    assert all(c.status in ("not_verified", "missing") for c in optional)


def test_hypnospy_is_vendored_in_repo_with_no_artifact(manifest_entries):
    entry = {e["id"]: e for e in manifest_entries}["hypnospy"]
    assert entry["artifacts"] == []
    assert entry["required_for_readiness"] is False
    assert entry["wired"] is True
    assert entry["provider_id"] == "hypnospy.hr-boundary.v1"
    vendored = entry["vendored"]
    assert vendored["pinned_commit"] == "3b6c825d1568158cbf0058de50495e5308117d17"
    assert vendored["upstream_sleep_boundary_detector_sha256"].startswith("e89a22c4")
    assert vendored["vendored_sleep_boundary_detector_sha256"].startswith("228c2b8f")
    assert vendored["in_repo_path"].startswith("src/frwhoop_inference/")


def test_verified_artifact_passes(tmp_path):
    root = tmp_path / "models"
    (root / "a" / "r1").mkdir(parents=True)
    payload = b"weights-bytes"
    (root / "a" / "r1" / "w.bin").write_bytes(payload)
    manifest = {"manifest_version": "1", "entries": [{
        "id": "a", "kind": "model_checkpoint", "required_for_readiness": True,
        "artifacts": [{"name": "w.bin", "path": "a/r1/w.bin",
                       "size_bytes": len(payload),
                       "sha256": hashlib.sha256(payload).hexdigest(),
                       "verify_at_startup": True}]}]}
    state = verify_manifest(manifest, str(root))
    assert state.ok is True
    assert state.checks[0].status == "verified"
    assert state.checks[0].actual_size == len(payload)


def test_size_mismatch_is_reported(tmp_path):
    root = tmp_path / "models"
    (root / "a" / "r1").mkdir(parents=True)
    payload = b"weights-bytes"
    (root / "a" / "r1" / "w.bin").write_bytes(payload)
    manifest = {"manifest_version": "1", "entries": [{
        "id": "a", "required_for_readiness": True,
        "artifacts": [{"name": "w.bin", "path": "a/r1/w.bin", "size_bytes": 999,
                       "sha256": hashlib.sha256(payload).hexdigest(),
                       "verify_at_startup": True}]}]}
    state = verify_manifest(manifest, str(root))
    assert state.ok is False
    assert state.checks[0].status == "size_mismatch"
    assert "blocked_artifact" in state.reason


def test_optional_artifact_failure_does_not_block_readiness(tmp_path):
    manifest = {"manifest_version": "1", "entries": [{
        "id": "a", "required_for_readiness": False,
        "artifacts": [{"name": "w.bin", "path": "a/r1/w.bin", "size_bytes": 1,
                       "sha256": "0" * 64, "verify_at_startup": True}]}]}
    state = verify_manifest(manifest, str(tmp_path))
    assert state.ok is True
    assert state.checks[0].status == "missing"
    assert "optional artifacts failed verification" in state.reason


def test_required_artifact_without_a_digest_fails_readiness(tmp_path):
    """Audit DD-4: ``verify_at_startup`` with no ``sha256`` is a failure, not a skip.

    Before the repair the entry produced ``no_sha256``, ``failed`` was False, and the
    provider reported ready with bytes nothing had ever verified.
    """
    manifest = {"manifest_version": "1", "entries": [{
        "id": "a", "required_for_readiness": True,
        "artifacts": [{"name": "w.bin", "path": "a/r1/w.bin", "size_bytes": 1,
                       "verify_at_startup": True}]}]}
    state = verify_manifest(manifest, str(tmp_path))
    assert state.checks[0].status == "no_sha256"
    assert state.checks[0].failed is True
    assert state.ok is False
    assert "blocked_artifact" in state.reason
    assert "no_sha256" in state.reason


def test_optional_artifact_without_a_digest_is_reported_but_not_blocking(tmp_path):
    manifest = {"manifest_version": "1", "entries": [{
        "id": "a", "required_for_readiness": False,
        "artifacts": [{"name": "w.bin", "path": "a/r1/w.bin", "size_bytes": 1,
                       "verify_at_startup": True}]}]}
    state = verify_manifest(manifest, str(tmp_path))
    assert state.ok is True
    assert state.checks[0].failed is True
    assert "optional artifacts failed verification" in state.reason


def test_not_verified_entries_stay_non_blocking(tmp_path):
    """``verify_at_startup: false`` is a by-design skip and never a failure (DD-4)."""
    manifest = {"manifest_version": "1", "entries": [{
        "id": "a", "required_for_readiness": True,
        "artifacts": [{"name": "w.bin", "path": "a/r1/w.bin", "size_bytes": 1,
                       "verify_at_startup": False}]}]}
    state = verify_manifest(manifest, str(tmp_path))
    assert state.checks[0].status == "not_verified"
    assert state.checks[0].failed is False
    assert state.ok is True
    assert state.reason is None


def test_broken_manifest_shapes_are_rejected(tmp_path):
    for payload in ("[]", "{}", '{"entries": []}', '{"entries": [1]}', '{"entries": [{}]}'):
        path = tmp_path / "m.json"
        path.write_text(payload)
        with pytest.raises(ValueError):
            load_manifest(str(path))


def test_sha256_file_matches_hashlib(tmp_path):
    path = tmp_path / "x.bin"
    path.write_bytes(b"abc" * 1000)
    assert sha256_file(str(path)) == hashlib.sha256(b"abc" * 1000).hexdigest()


# --------------------------------------------------------------------------
# Machine-readable artifact sources (docs/model-integration/provisioning.md)
# --------------------------------------------------------------------------


def test_every_artifact_declares_a_machine_readable_source(manifest_entries):
    for entry in manifest_entries:
        for artifact in entry["artifacts"]:
            source = artifact.get("source")
            assert isinstance(source, dict), f"{entry['id']}/{artifact['name']} has no source"
            assert source["kind"] in SOURCE_KINDS
            if source["kind"] == "none":
                assert source.get("reason")


def test_every_staged_artifact_can_be_produced_and_verified(manifest_entries):
    """What deploy-prep stages has a real source and a pinned digest and size."""
    staged = 0
    for entry in manifest_entries:
        if entry["status"] not in STAGED_ENTRY_STATUSES or not entry["wired"]:
            continue
        names = {a["name"] for a in entry["artifacts"]}
        for artifact in entry["artifacts"]:
            source = artifact["source"]
            if source["kind"] == "installed_package":
                assert source["package"] and source["version"] == entry["revision"]
                assert artifact["verify_at_startup"] is False
                continue
            if not artifact["verify_at_startup"]:
                continue
            staged += 1
            assert len(artifact["sha256"]) == 64 and isinstance(artifact["size_bytes"], int)
            if source["kind"] == "url":
                assert artifact["url"].startswith("https://")
            elif source["kind"] == "wheel_resource":
                assert source["package"] and source["resource"]
                assert entry["revision"] == f"{source['package']}=={source['version']}"
            elif source["kind"] == "zip_member":
                assert source["artifact"] in names and source["member"]
            else:
                pytest.fail(f"{entry['id']}/{artifact['name']}: a staged artifact cannot be {source['kind']}")
    assert staged == 9


def test_the_recgym_checkpoint_is_a_pinned_member_of_the_pinned_upstream_archive(manifest_entries):
    """The exercise head's checkpoint (Tools/ActivityContext/activity_context/recgym/weights.py pins the same bytes)."""
    entry = {e["id"]: e for e in manifest_entries}["recgym_cnn_transformer"]
    assert entry["status"] == "shadow_eligible" and entry["required_for_readiness"] is False
    artifacts = {a["name"]: a for a in entry["artifacts"]}
    archive, member = artifacts["models.zip"], artifacts["wrist_-_imu_only_best.pt"]
    assert archive["url"] == ("https://raw.githubusercontent.com/MKorp7/HAR_IMU_CNN-Transformer/"
                              f"{entry['revision']}/models.zip")
    assert archive["sha256"] == "eb779a1fbf5af2db76c8babbfd3e4d8162d9e677738215db5c03f5c2fe4cdfe8"
    assert member["source"] == {"kind": "zip_member", "artifact": "models.zip",
                                "member": "models/wrist_-_imu_only_best.pt"}
    assert member["sha256"] == "7f0c4adf066bb842eeb0c114e765fd3cf1ca3a7ca6ef6cf5344f5f142651f5d9"
    assert member["path"] == "recgym/e085ac0e/wrist_-_imu_only_best.pt"
    assert not any(a["required_for_readiness"] for a in entry["artifacts"])


def test_the_sleepecg_artifacts_come_from_the_wheel_not_from_a_url(manifest_entries):
    entry = {e["id"]: e for e in manifest_entries}["sleepecg_wrn_gru_mesa"]
    sources = {a["name"]: a["source"] for a in entry["artifacts"]}
    assert sources["wrn-gru-mesa.zip"] == {"kind": "wheel_resource", "package": "sleepecg",
                                           "version": "0.5.9",
                                           "resource": "classifiers/wrn-gru-mesa.zip"}
    assert sources["classifier.keras"] == {"kind": "zip_member", "artifact": "wrn-gru-mesa.zip",
                                           "member": "classifier.keras"}


def test_a_manifest_without_sources_still_reads():
    assert artifact_source({"url": "https://example.invalid/w"}) == {"kind": "url"}
    assert artifact_source({"url": "bundled in a wheel"})["kind"] == "none"
    assert artifact_source({})["kind"] == "none"


def test_manifest_summary_exposes_the_source():
    state = verify_manifest(load_manifest(MANIFEST_PATH), "/nonexistent", manifest_path=MANIFEST_PATH)
    rows = {(row["id"], a["name"]): a for row in manifest_summary(state) for a in row["artifacts"]}
    assert rows[("sleepecg_wrn_gru_mesa", "classifier.keras")]["source"]["kind"] == "zip_member"
    assert rows[("deepbeat", "deepbeat.h5")]["source"] == {"kind": "url"}


def test_the_per_model_staging_scripts_write_the_manifest_paths(manifest_entries):
    """Their output directory can serve as a --mirror for the provisioner."""
    import importlib.util

    def load(name):
        spec = importlib.util.spec_from_file_location(
            name, os.path.join(REPO_PACKAGE_ROOT, "scripts", f"{name}.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    paths = {(e["id"], a["name"]): a["path"] for e in manifest_entries for a in e["artifacts"]}
    deepbeat, siamaf, paradigma = load("provision_deepbeat"), load("provision_siamaf"), load("provision_paradigma")
    assert paths[("deepbeat", deepbeat.FILENAME)] == deepbeat.RELPATH
    assert paths[("siamaf", siamaf.FILENAME)] == siamaf.RELPATH
    for name, pinned in paradigma.ASSETS.items():
        assert paths[("paradigma", name)] == f"paradigma/{paradigma.UPSTREAM_COMMIT}/{name}"
    digests = {(e["id"], a["name"]): a["sha256"] for e in manifest_entries for a in e["artifacts"]}
    assert digests[("deepbeat", deepbeat.FILENAME)] == deepbeat.EXPECTED_SHA256
    assert digests[("siamaf", siamaf.FILENAME)] == siamaf.EXPECTED_SHA256
    assert all(digests[("paradigma", n)] == p["sha256"] for n, p in paradigma.ASSETS.items())
