"""G-3 sealing: the one-shot test gate reaches the served artifact (test_gate.json listed in the manifest),
plus the evaluation report fields it is built from (per-dataset gates, single-label precision, union
macro-F1, awake lying). Synthetic smoke bundle; nothing here needs datasets."""

import json
import os
import shutil

import numpy as np
import pytest

pytest.importorskip("torch")
pytest.importorskip("scipy")

from activity_context.inertia import bundle as B  # noqa: E402
from activity_context.inertia.bundle_schema import BundleError, validate_manifest  # noqa: E402
from activity_context.inertia.evaluate_heads import apply_chunked, eval_class_head, rows_to_arrays  # noqa: E402
from activity_context.inertia.eval_parts import eval_transition  # noqa: E402
from activity_context.inertia.integrity import TestVault  # noqa: E402
from activity_context.inertia.mappings import load_mappings  # noqa: E402
from activity_context.inertia.report import _json_safe, render  # noqa: E402
from activity_context.inertia.smoke import run_smoke, synthetic_assembled  # noqa: E402
from activity_context.inertia.targets import CLASS_HEADS, class_targets  # noqa: E402


def _corrupted_test(cw):
    """Test split whose WISDM 'B' (jogging -> running) windows are relabelled 'D' (sitting -> stationary): the
    head still predicts running there, so running's test precision collapses (pooled and on wisdm)."""
    data = synthetic_assembled(0, cw=cw)
    test = data.split("test")
    meta = test.meta.copy()
    m = (meta["dataset"] == "wisdm2019_watch") & (meta["label"] == "B")
    meta.loc[m, "label"] = "D"
    test.meta = meta
    for h in CLASS_HEADS:
        test.targets[h] = class_targets(meta, cw, h)
    return test


def _evaluate(bundle, test, cw, ledger):
    def evaluator(payload):
        t = payload["test"]
        rows, arr = apply_chunked(bundle, t.emb)
        out = rows_to_arrays(bundle, rows, len(t.meta))
        rep = {"experiment": "smoke", "bundle_id": bundle.bundle_id, "bundle_sha256": bundle.bundle_sha256,
               "encoder": bundle.manifest["encoder"], "evidence_tier_max": bundle.evidence_tier_max, "role": "primary",
               "n_test_windows": len(t.meta), "n_nonfinite_dropped": 0, "heads": {},
               "test_windows": [{"dataset": "synthetic", "windows": len(t.meta), "subjects": 6}],
               "ood": {"bundle_method": "knn", "threshold": 0.5, "k": 3, "id_test_false_alarm_rate": 0.05, "n_id_test": 1}}
        for h in CLASS_HEADS:
            rep["heads"][h] = eval_class_head(h, bundle, out, t, arr.raw_logits, cw)
        rep["heads"]["transition"] = eval_transition(bundle, out, t, arr.raw_logits)
        return rep
    vault = TestVault(lambda: {"test": test}, lambda p: [p["test"].meta["uid"].to_numpy()], ledger)
    return vault.evaluate_once("smoke", bundle.bundle_sha256, evaluator, declared=["smoke"])


@pytest.fixture(scope="module")
def sealed(tmp_path_factory):
    d = tmp_path_factory.mktemp("seal")
    r = run_smoke(str(d / "b"), arch="linear")
    cw = load_mappings()
    pre = B.load_bundle(r["bundle_dir"])
    rep = _json_safe(_evaluate(pre, _corrupted_test(cw), cw, str(d / "ledger.jsonl")))
    post = B.seal_bundle(r["bundle_dir"], rep)
    return {"dir": r["bundle_dir"], "pre": pre, "post": post, "report": rep, "tmp": d}


def _copy(sealed, name):
    dst = os.path.join(str(sealed["tmp"]), name)
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(sealed["dir"], dst)
    return dst


def _rewrite_gate(bdir, mutate):
    """Edit test_gate.json AND re-hash it consistently (an attacker who also edits the manifest)."""
    with open(os.path.join(bdir, "test_gate.json")) as f:
        gate = json.load(f)
    mutate(gate)
    data = B.json_bytes(gate)
    with open(os.path.join(bdir, "test_gate.json"), "wb") as f:
        f.write(data)
    with open(os.path.join(bdir, "manifest.json")) as f:
        m = json.load(f)
    from activity_context.inertia.contract import sha256_bytes
    m["files"]["test_gate.json"] = sha256_bytes(data)
    m["seal"]["test_gate_sha256"] = sha256_bytes(data)
    with open(os.path.join(bdir, "manifest.json"), "wb") as f:
        f.write(B.json_bytes(m))


def test_class_failing_the_gate_is_served_demoted(sealed):
    pre, post, rep = sealed["pre"], sealed["post"], sealed["report"]
    assert pre.manifest["heads"]["locomotion"]["status"]["running"] in ("strong", "weak")
    g = rep["heads"]["locomotion"]["gate"]["running"]
    assert g["test"]["n_acc"] >= 30 and g["test"]["precision"] < 0.8 and g["final_status"] == "abstain"
    assert any(x.startswith("pooled") for x in g["reasons"])
    assert post.sealed and post.manifest["seal"]["evaluated_bundle_sha256"] == pre.bundle_sha256
    assert post.bundle_sha256 != pre.bundle_sha256 and "test_gate.json" in post.manifest["files"]
    assert B.presealed_sha256(post.manifest) == pre.bundle_sha256
    # the manifest keeps the VAL status; the served (wire) status is the gated one
    assert post.manifest["heads"]["locomotion"]["status"]["running"] == pre.manifest["heads"]["locomotion"]["status"]["running"]
    wire = post.wire_block()["heads"]["locomotion"]
    assert wire["status"]["running"] == "abstain" and "running" not in wire["merge_into"]   # no compatible partner
    gate = post.test_gate["heads"]["locomotion"]
    assert gate["classes"]["running"]["per_dataset"]["wisdm2019_watch"]["level"] == "abstain"
    assert post.test_gate["ledger_entry"]["bundle_sha256"] == pre.bundle_sha256


def test_served_runtime_carries_the_gate(sealed):
    from activity_context.inertia.runtime import build_runtime
    from activity_context.inertia.registry import build_encoder
    rt = build_runtime(sealed["dir"], allow_standin_shadow=True)            # stand-in built from its id
    assert rt.available, rt.error
    assert build_encoder("standin:handcrafted-stats-v1").info.config_sha256 == rt.info.config_sha256
    assert rt.bundle.wire_block()["heads"]["locomotion"]["status"]["running"] == "abstain"


def test_report_fields_behind_the_gate(sealed):
    rep = sealed["report"]
    loco, post = rep["heads"]["locomotion"], rep["heads"]["posture"]
    assert "macro_f1" in loco["pooled"] and "macro_f1_present_supported" in loco["pooled"]
    assert isinstance(loco["pooled"]["predicted_absent_classes"], list)
    assert post["single_label"]["n_single_label"] > 0 and "recumbent" in post["single_label"]["per_class"]
    aw = post["awake_lying"]
    assert aw["n_awake_lying_truth"] > 0 and aw["sleep_period_fraction_of_recumbent_truth"] == 0.0
    assert "gate" in aw and aw["gate"]["affects_served_status"] is False
    for d, v in loco["per_dataset"].items():
        assert v["n_test_subjects"] == 3 and v["descriptive_only"] is False
    md = render(dict(rep, integrity=rep["integrity"]))
    assert "recumbent (mostly sleep-period lying in training data)" in md and "Awake lying" in md


def test_tampered_gate_file_is_detected(sealed):
    bdir = _copy(sealed, "tamper-bytes")
    p = os.path.join(bdir, "test_gate.json")
    with open(p, "rb") as f:
        data = f.read()
    with open(p, "wb") as f:
        f.write(data.replace(b'"abstain"', b'"weak"', 1))
    with pytest.raises(BundleError) as e:
        B.load_bundle(bdir)
    assert e.value.kind == "checkpoint_mismatch"


def test_promotion_via_gate_file_is_refused(sealed):
    bdir = _copy(sealed, "tamper-promote")
    pre = sealed["pre"].manifest["heads"]["posture"]["status"]
    weak = next(c for c, s in pre.items() if s == "weak")

    def promote(g):
        g["heads"]["posture"]["classes"][weak]["final_status"] = "strong"
    _rewrite_gate(bdir, promote)
    with pytest.raises(BundleError) as e:
        B.load_bundle(bdir)
    assert e.value.kind == "config_mismatch" and "PROMOTE" in str(e.value)


def test_gate_that_drops_a_merge_check_is_refused(sealed):
    bdir = _copy(sealed, "tamper-merge")

    def bad_merge(g):
        g["heads"]["locomotion"]["merge_into"] = {"running": "stationary"}      # not semantically compatible
    _rewrite_gate(bdir, bad_merge)
    with pytest.raises(BundleError) as e:
        B.load_bundle(bdir)
    assert "compatibility" in str(e.value)


def test_gate_from_another_bundle_is_refused(sealed):
    bdir = _copy(sealed, "tamper-swap")
    with open(os.path.join(bdir, "manifest.json")) as f:
        m = json.load(f)
    m["training"]["description"] = "a different bundle"                     # changes the pre-seal hash
    with open(os.path.join(bdir, "manifest.json"), "wb") as f:
        f.write(B.json_bytes(m))
    with pytest.raises(BundleError) as e:
        B.load_bundle(bdir)
    assert e.value.kind == "checkpoint_mismatch" and "before sealing" in str(e.value)


def test_seal_refuses_double_seal_and_foreign_reports(sealed, tmp_path):
    with pytest.raises(BundleError):
        B.seal_bundle(sealed["dir"], sealed["report"])                      # already sealed
    r = run_smoke(str(tmp_path / "other"), arch="linear")
    with pytest.raises(BundleError):
        B.seal_bundle(r["bundle_dir"], sealed["report"])                    # report stamped for another bundle


def test_candidate_tier_requires_a_sealed_bundle(sealed):
    m = json.loads(json.dumps(sealed["pre"].manifest))
    m["evidence_tier_max"] = "candidate"
    m["encoder"] = dict(m["encoder"], encoder_id="inertia-1/ar_transformer-small/30s@20hz", checkpoint_sha256="a" * 64)
    with pytest.raises(BundleError) as e:
        validate_manifest(m)
    assert "sealed" in str(e.value)


def test_incompatible_merge_and_wrong_decoder_evidence_refused_on_write(sealed, tmp_path):
    from activity_context.inertia.registry import build_encoder
    from activity_context.inertia.synthetic import synthetic_bundle_parts
    from activity_context.inertia.bundle import encoder_block
    from ._helpers import reference_embeddings
    enc = build_encoder("standin:handcrafted-stats-v1")
    parts = synthetic_bundle_parts(encoder=encoder_block(enc.info), reference=reference_embeddings(enc))
    parts["manifest"]["heads"]["posture"]["merge_into"] = {"postural_transition": "recumbent"}
    with pytest.raises(BundleError):
        B.write_bundle(str(tmp_path / "a"), **parts)
    parts = synthetic_bundle_parts(encoder=encoder_block(enc.info), reference=reference_embeddings(enc))
    parts["manifest"]["heads"]["posture"]["decoder_evidence"] = False                  # 3 live classes
    with pytest.raises(BundleError):
        B.write_bundle(str(tmp_path / "b"), **parts)


def test_single_group_head_is_marked_without_decoder_evidence(tmp_path):
    from activity_context.inertia.registry import build_encoder
    from activity_context.inertia.synthetic import synthetic_bundle_parts
    from activity_context.inertia.bundle import encoder_block
    from ._helpers import reference_embeddings
    enc = build_encoder("standin:handcrafted-stats-v1")
    parts = synthetic_bundle_parts(encoder=encoder_block(enc.info), reference=reference_embeddings(enc))
    arm = parts["manifest"]["heads"]["arm_behavior"]
    live = [c for c, s in arm["status"].items() if s != "abstain"]
    for c in live[1:]:
        arm["status"][c] = "abstain"
    arm["merge_into"] = {}
    B.write_bundle(str(tmp_path / "one"), **parts)
    w = B.load_bundle(str(tmp_path / "one")).wire_block()["heads"]
    assert w["arm_behavior"]["decoder_evidence"] is False and w["posture"]["decoder_evidence"] is True
