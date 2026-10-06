"""Frozen subject splits: sha256 verified on load, disjoint, WISDM == HART split, Capture-24 official test."""

import json

import numpy as np
import pytest

from activity_context.inertia import splits as S

USED = ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity")


def test_manifests_load_and_verify():
    sp = S.load_splits(USED)
    for d, doc in sp.items():
        assert doc["schema"] == "nara-split-1" and doc["sha256"] == S.manifest_sha256(doc)
        s = [set(doc[f"{n}_subjects"]) for n in ("train", "val", "test")]
        assert not (s[0] & s[1] or s[0] & s[2] or s[1] & s[2])
    assert len(S.combined_sha256(sp)) == 64


def test_wisdm_is_the_hart_split():
    doc = S.load_split("wisdm2019_watch")
    assert doc["test_subjects"] == ["1605", "1607", "1617", "1627", "1638", "1646", "1648", "1650"]
    assert doc["val_subjects"] == ["1618", "1620", "1623", "1624", "1629", "1634", "1637", "1639"]
    subs = list(range(1600, 1651))
    rng = np.random.default_rng(42)
    rng.shuffle(subs)                       # activity_context.train.split_blocks (seed 42, 15%/15%)
    assert sorted(str(s) for s in subs[:8]) == doc["test_subjects"]


def test_capture24_official_test():
    doc = S.load_split("capture24")
    assert doc["test_subjects"] == [f"P{i:03d}" for i in range(102, 152)]
    assert len(doc["train_subjects"]) == 81 and len(doc["val_subjects"]) == 20


def test_tampered_manifest_refused(tmp_path):
    doc = S.load_split("pamap2")
    doc["test_subjects"] = doc["test_subjects"] + ["subject102"]
    p = tmp_path / "pamap2.json"
    p.write_text(json.dumps(doc))
    with pytest.raises(S.SplitError):
        S.load_split("pamap2", str(tmp_path))


def test_leak_on_windowed_arrays_detected():
    subj = np.array(["a:1", "a:1", "a:2", "a:3"])
    S.assert_disjoint_windows(subj, np.array(["train", "train", "val", "test"]))
    with pytest.raises(S.SplitError):
        S.assert_disjoint_windows(subj, np.array(["train", "val", "val", "test"]))


def test_unknown_subject_refused():
    sp = S.load_splits(["mhealth"])
    with pytest.raises(S.SplitError):
        S.assign_splits(np.array(["mhealth:subject99"]), sp)
    assert list(S.assign_splits(np.array(["mhealth:subject6"]), sp)) == ["test"]
