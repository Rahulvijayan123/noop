"""Evaluate an external (never-fitted) validation set exactly once through the ElderNet test ledger; the
reviewed list of spent experiments that keeps a lost evaluation binding.

Same rules as the frozen-split TEST (``inertia.integrity.TestVault``, ledger ``eval/eldernet/test_ledger.jsonl``):
the payload is materialised only inside the vault, an experiment is evaluated once (a rerun needs an
enumerated reason), and the VAL-fitted calibration it applies is checked for provenance first.

:data:`SPENT_EXPERIMENTS` is a forward guard on top of the ledger (audit G2-3): the frozen-split TEST
(``eldernet_frozen_detection_v1``) was opened once, but its report and its ledger line were lost in an SSD
disconnect, so the ledger alone would let it run again as a "first" evaluation. Every experiment listed here
needs an enumerated ``rerun_reason`` (``inertia.integrity.RERUN_REASONS``) and a ``rerun_detail`` before any
payload is loaded, and the ledger line it writes records it as a rerun of the listed opening. The ledger itself
is never edited. Adding or removing an entry is a reviewed code change.
"""

from __future__ import annotations

import hashlib
import json
import os
from typing import Any, Callable, Dict, Optional

import numpy as np

from . import MODEL_VERSION, PREPROCESSING_VERSION, UPSTREAM_COMMIT

EXTERNAL_EXPERIMENTS = ("eldernet_gotov_external_v1", "eldernet_oxwalk_external_v1")

# experiment -> its (first) opening. ``ledger``: whether that opening's ledger line exists in test_ledger.jsonl.
SPENT_EXPERIMENTS: Dict[str, Dict[str, Any]] = {
    "eldernet_frozen_detection_v1": {
        "opened_unix": 1791310368, "opened_utc": "2026-10-06T18:12:48Z",
        "bundle_sha256": "eldernet-437a38b+cal:16191350862fb8de", "test_sha256_prefix": "677165e7",
        "ledger": "lost",
        "note": "TEST opened once; its report (VALIDATION_TEST.json) and ledger line were lost in an SSD "
                "disconnect; VALIDATION.md §2 numbers are transcribed from the run's console output",
    },
    "eldernet_gotov_external_v1": {
        "opened_unix": 1791310774, "opened_utc": "2026-10-06T18:19:34Z",
        "bundle_sha256": "eldernet-437a38b+cal:16191350862fb8de", "test_sha256_prefix": "465a59a9",
        "ledger": "present", "note": "external set evaluated once (VALIDATION_GOTOV.json)",
    },
    "eldernet_oxwalk_external_v1": {
        "opened_unix": 1791313350, "opened_utc": "2026-10-06T19:02:30Z",
        "bundle_sha256": "eldernet-437a38b+cal:16191350862fb8de", "test_sha256_prefix": "812c86d3",
        "ledger": "present", "note": "external set evaluated once (VALIDATION_OXWALK.json)",
    },
}


def spent_rerun_detail(experiment: str, rerun_reason: Optional[str], rerun_detail: Optional[str]) -> Optional[str]:
    """``rerun_detail`` to pass to ``TestVault.evaluate_once``. Raises SplitLeakError — before any payload is
    loaded — when ``experiment`` is spent and the call is not an enumerated, explained rerun; for a spent
    experiment the returned detail names the opening it reruns (so the new ledger line records it)."""
    from ..inertia.integrity import RERUN_REASONS, SplitLeakError, check_rerun_reason
    spent = SPENT_EXPERIMENTS.get(experiment)
    if spent is None:
        return rerun_detail
    if rerun_reason is None:
        raise SplitLeakError(
            f"{experiment} is spent (opened {spent['opened_utc']}, bundle {spent['bundle_sha256']}, ledger line "
            f"{spent['ledger']}: {spent['note']}); evaluating it again needs an enumerated rerun_reason "
            f"({sorted(RERUN_REASONS)}) and a rerun_detail, and is recorded as a rerun")
    check_rerun_reason(rerun_reason, rerun_detail)
    return (f"{rerun_detail.strip()} [rerun of spent {experiment}: opened {spent['opened_utc']} "
            f"(t={spent['opened_unix']}), bundle {spent['bundle_sha256']}, test_sha256 "
            f"{spent['test_sha256_prefix']}..., original ledger line {spent['ledger']}]")


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
    rerun_detail = spent_rerun_detail(experiment, rerun_reason, rerun_detail)     # before anything is loaded
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
                "upstream_commit": UPSTREAM_COMMIT, "spent_before": SPENT_EXPERIMENTS.get(experiment)})
    with open(os.path.join(out_dir, report_name), "w") as f:
        json.dump(rep, f, indent=1, sort_keys=True, default=float)
        f.write("\n")
    return rep


__all__ = ["EXTERNAL_EXPERIMENTS", "SPENT_EXPERIMENTS", "spent_rerun_detail", "load_calibration_doc",
           "evaluate_external_once"]
