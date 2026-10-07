"""End-to-end on a synthetic on-disk cache: run_experiment (provenance) -> evaluate_experiment (test split
assembled inside the vault, ledger, report) -> seal -> serve the sealed bundle; then the SUMMARY generator.

The cache mimics ``cache.build_windows`` / ``embed_dataset`` output for WISDM (real frozen split subject
ids, synthetic windows and hand-crafted-encoder-sized embeddings). Nothing here reads real data."""

import json
import os

import numpy as np
import pytest

pytest.importorskip("torch")
pytest.importorskip("scipy")
pd = pytest.importorskip("pandas")
pytest.importorskip("pyarrow")

from activity_context.inertia import cache as C  # noqa: E402
from activity_context.inertia.registry import build_encoder  # noqa: E402
from activity_context.inertia.splits import load_splits  # noqa: E402

LABELS = ("A", "B", "D", "E", "F")          # walk, jog, sit, stand, type


def _write_cache(root):
    sp = load_splits(["wisdm2019_watch"])["wisdm2019_watch"]
    rng = np.random.default_rng(0)
    centers = np.random.default_rng(7).standard_normal((len(LABELS), 72)) * 2.0
    rows, embs = [], []
    for split in ("train", "val", "test"):
        for subj in sp[f"{split}_subjects"]:
            for li, lab in enumerate(LABELS):
                for w in range(7):
                    t0 = 1000.0 * li + 30.0 * w
                    s = f"wisdm2019_watch:{subj}"
                    rows.append({"uid": f"{s}|{lab}|{w}", "dataset": "wisdm2019_watch", "subject": s,
                                 "session": f"{s}:b{li}", "split": split, "t0": t0, "t1": t0 + 30.0, "label": lab,
                                 "purity": 1.0, "pure": True, "filled_fraction": 0.0, "placement": "wrist_dominant",
                                 "device": "synthetic", "wrist_side": "unknown", "source_hz": 20.0, "kind": "cls"})
                    embs.append(centers[li] + rng.standard_normal(72))
    meta = pd.DataFrame(rows)
    d = C.windows_dir(root, "w30", "wisdm2019_watch")
    os.makedirs(d)
    meta.to_parquet(os.path.join(d, "meta.parquet"), index=False)
    np.save(os.path.join(d, "trans.npy"), np.full((len(meta), 8), -1, np.int8))
    with open(os.path.join(d, "events.json"), "w") as f:
        json.dump({"events": [], "masked": []}, f)
    man = {"dataset": "wisdm2019_watch", "spec": "w30", "window_s": 30, "hop_s": 15, "n_windows": len(meta),
           "window_index_sha256": C.window_index_sha256(meta["uid"].tolist(), "w30"),
           "n_by_split": meta["split"].value_counts().to_dict(), "n_subjects": int(meta["subject"].nunique()),
           "loader_version": "synthetic", "windows_version": "synthetic"}
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(man, f)
    enc = build_encoder("standin:handcrafted-stats-v1", window_s=30)
    ed = os.path.join(root, "emb", C.encoder_slug(enc.info.encoder_id), "w30")
    os.makedirs(ed)
    np.save(os.path.join(ed, "wisdm2019_watch.npy"), np.asarray(embs, np.float32))
    info = enc.info
    with open(os.path.join(ed, "wisdm2019_watch.json"), "w") as f:
        json.dump({"encoder_id": info.encoder_id, "encoder_version": info.encoder_version, "kind": info.kind,
                   "config_sha256": info.config_sha256, "checkpoint_sha256": None, "embedding_dim": 72,
                   "dataset": "wisdm2019_watch", "spec": "w30", "window_index_sha256": man["window_index_sha256"],
                   "n_windows": len(meta), "emb_sha256": "0" * 64, "info": info.to_dict()}, f)


@pytest.fixture(scope="module")
def pipeline(tmp_path_factory):
    from activity_context.inertia import build_bundle as BB
    from activity_context.inertia.evaluate_heads import evaluate_experiment
    from activity_context.inertia.experiments import get_experiment
    tmp = tmp_path_factory.mktemp("e2e")
    cache, bundles, ev = str(tmp / "cache"), str(tmp / "bundles"), str(tmp / "eval")
    _write_cache(cache)
    clean = {"git_commit": "c" * 40, "source_tree_sha256": "d" * 64, "source_tree_files": 1, "source_dirty": False, "dirty_paths": [],
             "source_dirty_paths": [], "tools_activity_context_dirty": False, "git_dirty": False}
    mp = pytest.MonkeyPatch()
    mp.setattr(BB, "git_info", lambda: dict(clean))
    exp = get_experiment("primary-hc")
    r = BB.run_experiment(exp, cache_root=cache, bundles_root=bundles)
    rep = evaluate_experiment(exp, cache_root=cache, bundles_root=bundles, eval_root=ev)
    mp.undo()
    return {"train": r, "report": rep, "cache": cache, "bundles": bundles, "eval": ev, "exp": exp}


def test_trained_bundle_records_provenance(pipeline):
    from activity_context.inertia.bundle import load_bundle
    assert pipeline["train"]["evidence_tier_max"] == "shadow"
    t = load_bundle(pipeline["train"]["bundle_dir"]).manifest["training"]
    assert t["git_commit"] == "c" * 40 and t["source_tree_sha256"] == "d" * 64 and t["allow_dirty"] is False


def test_evaluation_is_ledgered_sealed_and_reported(pipeline):
    rep, ev = pipeline["report"], pipeline["eval"]
    assert rep["integrity"]["n_test_evaluations"] == 1 and rep["integrity"]["rerun_reason"] is None
    assert rep["seal"]["evaluated_bundle_sha256"] == rep["bundle_sha256"] != rep["seal"]["sealed_bundle_sha256"]
    assert rep["provenance"]["git_commit"] == "c" * 40
    with open(os.path.join(ev, "test_ledger.jsonl")) as f:
        assert len(f.read().strip().splitlines()) == 1
    with open(os.path.join(ev, "shadow-primary-hc", "evaluation.json")) as f:
        on_disk = json.load(f)
    assert on_disk["seal"]["sealed_bundle_sha256"] == rep["seal"]["sealed_bundle_sha256"]
    loco = rep["heads"]["locomotion"]
    assert set(loco["per_dataset"]) == {"wisdm2019_watch"} and loco["per_dataset"]["wisdm2019_watch"]["n_test_subjects"] == 8
    for c, g in loco["gate"].items():
        if g["val_status"] != "abstain":
            assert "wisdm2019_watch" in g["per_dataset"]


def test_sealed_bundle_cannot_be_evaluated_again_and_reruns_need_a_reason(pipeline):
    from activity_context.inertia.bundle_schema import BundleError
    from activity_context.inertia.evaluate_heads import evaluate_experiment
    with pytest.raises(BundleError):
        evaluate_experiment(pipeline["exp"], cache_root=pipeline["cache"], bundles_root=pipeline["bundles"],
                            eval_root=pipeline["eval"])


def test_sealed_bundle_serves_the_final_statuses(pipeline):
    from activity_context.inertia.runtime import build_runtime
    rt = build_runtime(pipeline["train"]["bundle_dir"], allow_standin_shadow=True,
                       expect_bundle_sha256=pipeline["report"]["seal"]["sealed_bundle_sha256"])
    assert rt.available, rt.error
    final = pipeline["report"]["seal"]["final_status"]
    for h, blk in rt.bundle.wire_block()["heads"].items():
        assert blk["status"] == final[h]


def test_summary_builds_from_the_sealed_report(pipeline):
    from activity_context.inertia.summary import build_summary
    path = build_summary(pipeline["eval"], pipeline["bundles"])
    text = open(path).read()
    for section in ("## Per-dataset per-class test P/R/F1", "## Awake lying", "## Disclosures",
                    "## Nara/WHOOP fixture behaviour", "## Capture-24 source verification", "sealed sha256"):
        assert section in text, section
