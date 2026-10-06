"""Inertia heads pipeline CLI: windows -> embed -> train -> evaluate (offline; CPU; deterministic).

    python -m activity_context.inertia.pipeline_cli windows  --datasets capture24,wisdm2019_watch --specs w30,w30t,w10
    python -m activity_context.inertia.pipeline_cli embed    --encoder standin:handcrafted-stats-v1 --specs w30,w30t
    python -m activity_context.inertia.pipeline_cli train    --experiment primary-hc
    python -m activity_context.inertia.pipeline_cli evaluate --experiment primary-hc
    python -m activity_context.inertia.pipeline_cli summary
    python -m activity_context.inertia.pipeline_cli smoke    --out /tmp/inertia-smoke     # synthetic end-to-end

The real encoder runs through the same ``embed`` command::

    ... embed --encoder inertia-1/ar_transformer-small/30s@20hz --checkpoint $INERTIA1_CKPT_PATH \
              --encoder-config encoder.json

and fails with a typed ``blocked: no checkpoint`` (InertiaUnavailable kind ``model_missing``) until an official
checkpoint exists. Experiments are declared in :mod:`.experiments` (pre-registered before any test split is
opened); ``evaluate`` refuses an undeclared bundle and any silent re-evaluation.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional, Sequence

from .cache import CACHE_ROOT

ALL_DATASETS = ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "daphnet_fog")


def _csv(s: Optional[str], default: Sequence[str]) -> List[str]:
    return [x for x in (s.split(",") if s else default) if x]


def cmd_windows(a) -> int:
    from .cache import build_windows
    for ds in _csv(a.datasets, ALL_DATASETS):
        t = time.time()
        specs = _csv(a.specs, ("w30", "w30t", "w10")) if ds != "daphnet_fog" else ["w30"]
        out = build_windows(ds, specs, root=a.cache, workers=a.workers, force=a.force)
        print(json.dumps({"dataset": ds, "seconds": round(time.time() - t, 1),
                          "windows": {k: {"n": v["n_windows"], "by_split": v["n_by_split"]} for k, v in out.items()}}),
              flush=True)
    return 0


def cmd_embed(a) -> int:
    from .cache import embed_dataset, read_manifest
    from .contract import InertiaUnavailable
    kw: Dict[str, Any] = {}
    if a.checkpoint:
        kw["ckpt_path"] = a.checkpoint
    if a.encoder_config:
        kw["encoder_config"] = a.encoder_config
    if a.encoder.startswith("inertia-1/") and not (a.checkpoint or os.environ.get("INERTIA1_CKPT_PATH")):
        print(json.dumps({"ok": False, "kind": "model_missing", "error": "blocked: no checkpoint — no official "
                          "Inertia-1 checkpoint is publicly available; pass --checkpoint/$INERTIA1_CKPT_PATH and "
                          "--encoder-config once one exists"}), flush=True)
        return 3
    for ds in _csv(a.datasets, ALL_DATASETS):
        for spec in _csv(a.specs, ("w30", "w30t", "w10")):
            try:
                read_manifest(a.cache, spec, ds)
            except Exception:
                continue
            try:
                rec = embed_dataset(a.encoder, spec, ds, root=a.cache, workers=a.workers, encoder_kw=kw, force=a.force)
            except InertiaUnavailable as exc:
                print(json.dumps({"ok": False, "kind": exc.kind, "error": f"blocked: {exc.message}"}), flush=True)
                return 3
            print(json.dumps({"dataset": ds, "spec": spec, "n": rec["n_windows"], "dim": rec["embedding_dim"],
                              "seconds": rec.get("seconds")}), flush=True)
    return 0


def cmd_train(a) -> int:
    from .experiments import get_experiment
    from .build_bundle import run_experiment
    for name in _csv(a.experiment, ()):
        exp = get_experiment(name)
        out = run_experiment(exp, cache_root=a.cache, bundles_root=a.bundles, force=a.force)
        print(json.dumps({"experiment": name, "bundle_dir": out["bundle_dir"], "bundle_sha256": out["bundle_sha256"]}),
              flush=True)
    return 0


def cmd_evaluate(a) -> int:
    from .evaluate_heads import evaluate_experiment
    from .experiments import get_experiment
    for name in _csv(a.experiment, ()):
        rep = evaluate_experiment(get_experiment(name), cache_root=a.cache, bundles_root=a.bundles,
                                  eval_root=a.eval_dir, rerun_reason=a.rerun_reason)
        print(json.dumps({"experiment": name, "report": rep.get("report_path")}), flush=True)
    return 0


def cmd_summary(a) -> int:
    from .report import write_summary
    print(json.dumps({"summary": write_summary(a.eval_dir, a.bundles)}))
    return 0


def cmd_smoke(a) -> int:
    from .smoke import run_smoke
    print(json.dumps(run_smoke(a.out), default=str))
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    import warnings
    # numpy 2.x + macOS Accelerate emits spurious FP warnings from matmul on finite inputs/outputs
    warnings.filterwarnings("ignore", message=r".*encountered in matmul", category=RuntimeWarning)
    from .experiments import BUNDLES_ROOT, EVAL_ROOT
    ap = argparse.ArgumentParser(prog="python -m activity_context.inertia.pipeline_cli")
    ap.add_argument("--cache", default=CACHE_ROOT)
    ap.add_argument("--bundles", default=BUNDLES_ROOT)
    ap.add_argument("--eval-dir", default=EVAL_ROOT)
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("windows")
    w.add_argument("--datasets")
    w.add_argument("--specs")
    w.add_argument("--workers", type=int, default=8)
    w.add_argument("--force", action="store_true")
    e = sub.add_parser("embed")
    e.add_argument("--encoder", required=True)
    e.add_argument("--checkpoint")
    e.add_argument("--encoder-config")
    e.add_argument("--datasets")
    e.add_argument("--specs")
    e.add_argument("--workers", type=int, default=8)
    e.add_argument("--force", action="store_true")
    t = sub.add_parser("train")
    t.add_argument("--experiment", required=True)
    t.add_argument("--force", action="store_true")
    v = sub.add_parser("evaluate")
    v.add_argument("--experiment", required=True)
    v.add_argument("--rerun-reason")
    sub.add_parser("summary")
    s = sub.add_parser("smoke")
    s.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    return {"windows": cmd_windows, "embed": cmd_embed, "train": cmd_train, "evaluate": cmd_evaluate,
            "summary": cmd_summary, "smoke": cmd_smoke}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
