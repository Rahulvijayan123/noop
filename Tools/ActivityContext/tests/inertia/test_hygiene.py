"""G-12 / G-13 / G-14 reporting conventions and G-20 hygiene (subprocess environment, paths, crosswalk)."""

import glob
import json
import os
import re

import numpy as np
import pytest

from activity_context.inertia import metrics as M
from activity_context.inertia.subproc import failure_lines, redact, safe_env

PKG = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))


# --- G-13 macro-F1 convention, G-14 single-label precision ---------------------------------------------------

def test_macro_f1_is_over_true_and_predicted_classes():
    from sklearn.metrics import f1_score
    y = np.array([0, 0, 1, 1, 1])
    yhat = np.array([0, 2, 1, 1, 0])                      # class 2 is predicted but absent
    cm = M.confusion(y, yhat, 3)
    assert M.macro_f1(cm) == pytest.approx(f1_score(y, yhat, average="macro"))
    assert M.macro_f1(cm, [0, 1]) > M.macro_f1(cm)       # the legacy present-only number hides the false alarm
    probs = np.eye(3)[yhat] * 0.9 + 0.05
    truth = np.eye(3, dtype=bool)[y]
    r = M.head_report(probs, truth, ["a", "b", "c"], np.array([True, True, True]), null_reps=5)
    assert r["predicted_absent_classes"] == ["c"] and r["macro_f1"] < r["macro_f1_present_supported"]


def test_single_label_precision_excludes_set_targets():
    probs = np.array([[0.9, 0.1], [0.9, 0.1], [0.9, 0.1]])
    truth = np.array([[True, False], [False, True], [True, True]])         # last row is a set target
    r = M.single_label_prf(probs, truth, ["a", "b"], np.array([True, True]))
    assert r["n_single_label"] == 2 and r["n_set_target"] == 1
    assert r["per_class"]["a"]["precision"] == pytest.approx(0.5)          # set-aware scoring would say 2/3


# --- G-12 bootstrap warning rendered with every CI -----------------------------------------------------------

def test_few_subject_ci_is_marked():
    from activity_context.inertia.bootstrap import cluster_bootstrap
    from activity_context.inertia.report import FEW_SUBJECTS_MARK, ci
    s = np.repeat(["a", "b", "c"], 10)
    b = cluster_bootstrap(lambda i: float(len(i)), s, n_boot=20)
    assert b["warning"] and ci(b).endswith(FEW_SUBJECTS_MARK)
    b2 = cluster_bootstrap(lambda i: float(len(i)), np.repeat([f"s{k}" for k in range(12)], 3), n_boot=20)
    assert b2["warning"] is None and not ci(b2).endswith(FEW_SUBJECTS_MARK)


# --- G-20a subprocess environment -------------------------------------------------------------------------------

def test_safe_env_is_an_allowlist(monkeypatch):
    monkeypatch.setenv("NARA_DB_URL", "postgres://user:hunter2@db/x")
    monkeypatch.setenv("SOME_API_TOKEN", "tok123")
    env = safe_env({"ACTIVITY_REPLAY_IN": "/tmp/in.jsonl"})
    assert "NARA_DB_URL" not in env and "SOME_API_TOKEN" not in env
    assert env["ACTIVITY_REPLAY_IN"] == "/tmp/in.jsonl" and env.get("PATH") == os.environ.get("PATH")


def test_child_output_is_filtered_before_logging():
    dump = "NARA_DB_URL=postgres://u:p@h/db\nerror: test failed token=abc123\nconnecting postgres://bob:secret@host/x\nok"
    r = redact(dump)
    assert "NARA_DB_URL" not in r and "abc123" not in r and "secret" not in r and "ok" in r
    f = failure_lines(dump)
    assert "failed" in f and "abc123" not in f and "p@h" not in f


def _sources():
    files = glob.glob(os.path.join(PKG, "activity_context", "**", "*.py"), recursive=True)
    files += glob.glob(os.path.join(PKG, "tests", "**", "*.py"), recursive=True)
    return [f for f in files if "__pycache__" not in f and not f.endswith("test_hygiene.py")]


def test_no_subprocess_gets_the_full_environment():
    pat = re.compile(r"dict\(os\.environ\)|os\.environ\.copy\(\)|env=os\.environ\b")
    bad = [os.path.relpath(f, PKG) for f in _sources() if pat.search(open(f, encoding="utf-8").read())]
    assert bad == []


# --- G-20c no machine-specific paths -----------------------------------------------------------------------------

def test_no_machine_specific_paths_in_code_or_crosswalk():
    files = _sources() + [os.path.join(PKG, "activity_context", "inertia", "label_mappings.json")]
    bad = [os.path.relpath(f, PKG) for f in files if "/Volumes/" in open(f, encoding="utf-8").read()]
    assert bad == []


def test_unconfigured_data_paths_refuse(monkeypatch):
    from activity_context.inertia import paths
    for v in ("INERTIA_DATA_ROOT", "INERTIA_CACHE_DIR", "INERTIA_BUNDLES_DIR", "INERTIA_HAR_ROOT", "WISDM_DIR"):
        monkeypatch.delenv(v, raising=False)
    assert paths.cache_root() == "" and paths.bundles_root() == "" and paths.wisdm_dir() == ""
    with pytest.raises(paths.PathNotConfigured):
        paths.require_dir(paths.cache_root(), "cache")
    monkeypatch.setenv("INERTIA_DATA_ROOT", "/data/research")
    assert paths.cache_root() == "/data/research/inertia-cache"
    assert paths.capture24_dir() == "/data/research/har-datasets/capture24/hf_mirror_nz00shuuuu"


# --- G-20d crosswalk rationales / claims, G-20e replay truth source ---------------------------------------------

def test_crosswalk_rationales_are_real_and_direct_only_when_literal():
    from activity_context.inertia.mappings import load_mappings
    cw = load_mappings()
    for r in cw.doc["mappings"]:
        assert not r["rationale"].startswith("direct: the source label names the target"), r
        if r["rationale"].startswith("direct (source label equals Nara class)"):
            t = r["nara_target"]
            assert str(r["source_label"]).lower() == t or str(r.get("source_label_name", "")).lower() == t, r
    rule = cw.doc["conventions"]["window_assignment"]["classification_heads"]
    assert "never implemented and is withdrawn" in rule and ">= 90%" in rule


def test_rebuild_refuses_a_blank_rationale_without_an_explicit_entry():
    from activity_context.inertia.mappings import MappingError, load_mappings
    from activity_context.inertia.mappings_build import normalise
    doc = json.loads(json.dumps(load_mappings().doc))
    src = {k: doc[k] for k in ("conventions", "datasets", "transition_derivation", "movement_intensity",
                               "splits_policy", "ood_candidates", "nara_feedback")}
    src["mappings"] = [dict(doc["mappings"][0], rationale="", dataset="pamap2", source_label="no-such-label")]
    with pytest.raises(MappingError):
        normalise(src, "0" * 64, "/x/research/inertia-work/agentC/label_mappings.json")


def test_replay_truth_reads_the_repo_crosswalk():
    from activity_context.inertia import replay_data as rd
    from activity_context.inertia.mappings import MAPPINGS_PATH
    assert rd.CROSSWALK_PATH == MAPPINGS_PATH
    truth = rd.load_crosswalk("wisdm2019_watch")
    assert truth["A"]["locomotion"].strict != 0
