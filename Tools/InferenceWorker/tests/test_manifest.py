"""Model manifest and startup artifact verification tests."""

from __future__ import annotations

import hashlib
import json

import pytest

from conftest import MANIFEST_PATH
from frwhoop_inference.artifacts import (
    CHECK_STATUSES,
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
    ids = [e["id"] for e in manifest_entries]
    assert ids == ["neurokit2", "hypnospy", "sleepecg_wrn_gru_mesa", "wav2sleep",
                   "no_eeg_sleep_staging", "rr_estimation", "stepcount",
                   "cnn_wrist_model_freeliving"]


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
    """Wired entries: the HRV dependency plus the two landed sleep candidates."""
    wired = {e["id"]: e["wired"] for e in manifest_entries}
    assert wired["neurokit2"] is True
    assert wired["hypnospy"] is True
    assert wired["sleepecg_wrn_gru_mesa"] is True
    assert all(value is False for key, value in wired.items()
               if key not in {"neurokit2", "hypnospy", "sleepecg_wrn_gru_mesa"})


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
    assert len(summary) == 8
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
