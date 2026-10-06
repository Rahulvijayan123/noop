"""Evaluate an external (never-fitted) validation set exactly once through the ElderNet test ledger.

Same rules as the frozen-split TEST (``inertia.integrity.TestVault``, ledger ``eval/eldernet/test_ledger.jsonl``):
the payload is materialised only inside the vault, an experiment is evaluated once (a rerun needs an
enumerated reason), and the VAL-fitted calibration it applies is checked for provenance first.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Callable, Dict, Optional

import numpy as np

from . import MODEL_VERSION, PREPROCESSING_VERSION, UPSTREAM_COMMIT

EXTERNAL_EXPERIMENTS = ("eldernet_gotov_external_v1", "eldernet_oxwalk_external_v1")


def load_calibration_doc(out_dir: str) -> Dict:
    from ..inertia.integrity import SplitLeakError
    with open(os.path.join(out_dir, "calibration.json")) as f:
        cal = json.load(f)
    if cal["gait_prob"].get("fit") != "val" or cal["fit"].get("split") != "val":
        raise SplitLeakError("calibration must be fitted on VAL")
    return cal


def evaluate_external_once(experiment: str, loader: Callable[[], Dict[str, np.ndarray]],
                           evaluator: Callable[[Dict[str, np.ndarray], Dict], Dict], out_dir: str, report_name: str,
                           rerun_reason: Optional[str] = None, rerun_detail: Optional[str] = None) -> Dict:
    from ..inertia.integrity import TestVault
    cal = load_calibration_doc(out_dir)

    def identity(payload):
        h = hashlib.sha256()
        for k in ("subject", "session"):
            h.update("\n".join(np.asarray(payload[k]).astype(str).tolist()).encode())
        h.update(np.ascontiguousarray(payload["s"], np.float64).tobytes())
        return (np.array([h.hexdigest()]),)

    vault = TestVault(loader, identity, os.path.join(out_dir, "test_ledger.jsonl"))
    cal_sha = hashlib.sha256(json.dumps(cal, sort_keys=True).encode()).hexdigest()
    rep = vault.evaluate_once(experiment, f"{MODEL_VERSION}+cal:{cal_sha[:16]}", lambda p: evaluator(p, cal),
                              EXTERNAL_EXPERIMENTS, rerun_reason=rerun_reason, rerun_detail=rerun_detail)
    rep.update({"calibration": {k: cal[k] for k in ("calibration_id", "gait_prob", "gait_threshold")},
                "model_version": MODEL_VERSION, "preprocessing_version": PREPROCESSING_VERSION,
                "upstream_commit": UPSTREAM_COMMIT})
    with open(os.path.join(out_dir, report_name), "w") as f:
        json.dump(rep, f, indent=1, sort_keys=True, default=float)
        f.write("\n")
    return rep


__all__ = ["EXTERNAL_EXPERIMENTS", "load_calibration_doc", "evaluate_external_once"]
