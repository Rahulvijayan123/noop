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
