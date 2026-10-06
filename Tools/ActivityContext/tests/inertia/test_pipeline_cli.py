"""Pipeline CLI wiring: the real Inertia-1 path fails with a typed 'blocked: no checkpoint'; experiments are
pre-registered; stand-in bundles are shadow-only."""

import json
import os

import pytest

from activity_context.inertia.contract import InertiaUnavailable
from activity_context.inertia.experiments import DECLARED, EXPERIMENTS, REAL, get_experiment


def test_real_inertia1_embed_is_blocked(capsys, monkeypatch):
    from activity_context.inertia import pipeline_cli
    monkeypatch.delenv("INERTIA1_CKPT_PATH", raising=False)
    rc = pipeline_cli.main(["embed", "--encoder", REAL, "--datasets", "mhealth", "--specs", "w30"])
    out = json.loads(capsys.readouterr().out.strip().splitlines()[-1])
    assert rc == 3 and out["kind"] == "model_missing" and "blocked: no checkpoint" in out["error"]


def test_real_inertia1_with_bad_checkpoint_is_typed(tmp_path):
    from activity_context.inertia.registry import build_encoder
    with pytest.raises(InertiaUnavailable) as e:
        build_encoder(REAL, ckpt_path=str(tmp_path / "missing.ckpt"))
    assert e.value.kind in ("model_missing", "config_mismatch")


def test_real_training_and_evaluation_blocked(tmp_path):
    from activity_context.inertia.build_bundle import run_experiment
    from activity_context.inertia.evaluate_heads import evaluate_experiment
    exp = get_experiment("primary-inertia1")
    with pytest.raises(InertiaUnavailable) as e:
        run_experiment(exp, bundles_root=str(tmp_path))
    assert e.value.kind == "model_missing" and "blocked" in str(e.value)
    with pytest.raises(InertiaUnavailable):
        evaluate_experiment(exp, bundles_root=str(tmp_path), eval_root=str(tmp_path))


def test_experiments_preregistered_and_standin():
    assert set(DECLARED) == set(EXPERIMENTS)
    for e in EXPERIMENTS.values():
        assert e.encoder.startswith("standin:") or e.encoder.startswith("inertia-1/")
        assert e.bundle_id.startswith("shadow-")
        if e.arch.startswith("from:"):
            assert e.arch[5:] in EXPERIMENTS
        if e.ood_from:
            assert EXPERIMENTS[e.ood_from].role == "ood_bench" and EXPERIMENTS[e.ood_from].encoder == e.encoder


def test_ncsa_experiments_declared_with_licences():
    """GOTOV/WEAR (CC BY-NC-SA 4.0) experiments are pre-registered; their bundles record the licences."""
    from activity_context.inertia.build_bundle import training_data_licences
    from activity_context.inertia.experiments import NC_SA, WRIST, WRIST_NC
    from activity_context.inertia.mappings import load_mappings
    cw = load_mappings()
    names = {f"ncsa-{r}-{e}" for r in ("ood", "primary") for e in ("hc", "nf", "art")} | {
        "ncsa-lodo-nonc-hc", "ncsa-lodo-nogotov-hc", "ncsa-lodo-nowear-hc"}
    assert names <= set(DECLARED)
    for n in names:
        e = get_experiment(n)
        assert e.eval_datasets == WRIST_NC and e.datasets[:len(e.train_datasets)] == e.train_datasets
        lic = training_data_licences(cw, e.train_datasets)
        assert lic["licences"] == (["CC BY 4.0", "CC BY-NC-SA 4.0"] if set(NC_SA) & set(e.train_datasets) else ["CC BY 4.0"])
        assert (lic["note"] is not None) == bool(set(NC_SA) & set(e.train_datasets))
    assert get_experiment("ncsa-lodo-nonc-hc").train_datasets == WRIST
    assert "gotov" not in get_experiment("ncsa-lodo-nogotov-hc").train_datasets
    assert get_experiment("primary-hc").datasets == WRIST                  # sealed experiments unchanged
    assert training_data_licences(cw, WRIST)["licences"] == ["CC BY 4.0"]
