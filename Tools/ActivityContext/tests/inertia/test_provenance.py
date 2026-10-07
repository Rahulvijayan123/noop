"""G-7 provenance: git HEAD (no environment override), source tree hash, dirty-tree refusal / offline cap."""

import os
import shutil
import subprocess

import pytest

from activity_context.inertia import provenance as P
from activity_context.inertia.subproc import safe_env


def _git_head():
    r = subprocess.run(["git", "rev-parse", "HEAD"], cwd=P.TOOLS_DIR, capture_output=True, text=True, env=safe_env())
    return r.stdout.strip() if r.returncode == 0 else None


def test_git_commit_cannot_be_overridden_by_the_environment(monkeypatch):
    monkeypatch.setenv("INERTIA_GIT_COMMIT", "deadbeef-from-env")
    monkeypatch.setenv("INERTIA_GIT_DIRTY", "0")
    info = P.provenance_info()
    assert info["git_commit"] == _git_head() and info["git_commit"] != "deadbeef-from-env"
    assert len(info["source_tree_sha256"]) == 64 and info["source_tree_files"] > 50
    from activity_context.inertia.build_bundle import git_info
    assert git_info()["git_commit"] == info["git_commit"]


def test_check_provenance_refuses_dirty_unless_allowed():
    clean = {"git_commit": "a" * 40, "source_dirty": False, "tools_activity_context_dirty": False}
    assert P.check_provenance(clean) == "shadow"
    for bad in ({"git_commit": "a" * 40, "source_dirty": True, "source_dirty_paths": ["activity_context/x.py"]},
                {"git_commit": "a" * 40, "source_dirty": False, "tools_activity_context_dirty": True,
                 "dirty_paths": ["Tools/ActivityContext/INERTIA1.md"]},       # any change under the tool dir
                {"git_commit": None, "source_dirty": None}, {"git_commit": "a" * 40, "source_dirty": None}):
        with pytest.raises(P.ProvenanceError):
            P.check_provenance(bad)
        assert P.check_provenance(bad, allow_dirty=True) == "offline"


def test_source_tree_hash_tracks_the_package_files(tmp_path):
    root = tmp_path / "tree"
    shutil.copytree(os.path.join(P.TOOLS_DIR, "activity_context"), root / "activity_context",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(os.path.join(P.TOOLS_DIR, "splits"), root / "splits")
    a, n = P.source_tree_sha256(str(root))
    assert (a, n) == P.source_tree_sha256(str(root))
    (root / "activity_context" / "inertia" / "abstention.py").write_text("# changed\n", encoding="utf-8")
    b, _ = P.source_tree_sha256(str(root))
    assert b != a
    (root / "activity_context" / "notes.txt").write_text("not source", encoding="utf-8")
    assert P.source_tree_sha256(str(root))[0] == b                     # only *.py / *.json / splits / pyproject


def test_run_experiment_refuses_a_dirty_tree_before_touching_data(monkeypatch, tmp_path):
    from activity_context.inertia import build_bundle as BB
    from activity_context.inertia.experiments import get_experiment
    monkeypatch.setattr(BB, "git_info", lambda: {"git_commit": "a" * 40, "source_dirty": True,
                                                  "source_dirty_paths": ["activity_context/inertia/x.py"]})
    with pytest.raises(P.ProvenanceError) as e:
        BB.run_experiment(get_experiment("primary-hc"), cache_root=str(tmp_path / "c"), bundles_root=str(tmp_path / "b"))
    assert "--allow-dirty" in str(e.value) and not (tmp_path / "b").exists()


def test_allow_dirty_caps_the_bundle_at_offline(tmp_path):
    pytest.importorskip("torch")
    from activity_context.inertia import bundle as B
    from activity_context.inertia.build_bundle import train_bundle
    from activity_context.inertia.mappings import load_mappings
    from activity_context.inertia.smoke import encoder_info, smoke_experiment, synthetic_assembled
    cw = load_mappings()
    data = synthetic_assembled(0, cw=cw)
    trval = data.select(data.meta["split"].isin(["train", "val"]).to_numpy())
    prov = {"git_commit": "a" * 40, "source_dirty": True, "source_dirty_paths": ["x.py"], "allow_dirty": True,
            "source_tree_sha256": "b" * 64}
    train_bundle(smoke_experiment("linear"), trval, str(tmp_path / "off"), cw, encoder_info(), str(tmp_path),
                 provenance=prov, tier=P.check_provenance(prov, allow_dirty=True))
    b = B.load_bundle(str(tmp_path / "off"))
    assert b.evidence_tier_max == "offline" and b.manifest["training"]["allow_dirty"] is True
    assert b.manifest["training"]["source_tree_sha256"] == "b" * 64
