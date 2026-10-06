"""Statistical-integrity guards (ported from Agent E; INERTIA1.md §9, spec §26).

* :class:`SplitView` is how fitting code receives train/val data (name + content hash); it cannot wrap test.
* :class:`TestVault` holds the test split and exposes no arrays. Its only operation is
  :meth:`TestVault.evaluate_once` which hashes the frozen bundle, runs the evaluator, stamps the report with
  ``(bundle_sha256, test_sha256)`` and appends to an append-only ledger. Evaluating the same experiment
  again (any bundle) or an undeclared experiment refuses unless ``rerun_reason`` is given; every rerun is
  recorded and surfaced (``n_test_evaluations``).
* :func:`assert_disjoint_subjects`, :func:`assert_calibration_provenance`, :func:`assert_head_inputs`.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass
from typing import Any, Callable, Dict, Mapping, Optional, Sequence

import numpy as np

from .heads import HEAD_INPUTS

FORBIDDEN_INPUTS = ("hr", "heart_rate", "hrv", "rr", "respiration", "temperature", "skin_temp", "spo2", "sleep",
                    "steps", "workout", "hart", "hart_probs", "imu_feat", "engineered")


class SplitLeakError(RuntimeError):
    pass


def array_sha256(*arrays: np.ndarray) -> str:
    h = hashlib.sha256()
    for a in arrays:
        a = np.ascontiguousarray(a)
        if a.dtype == object:
            a = np.asarray([str(v) for v in a.ravel()]).astype("U")
        h.update(str(a.dtype).encode())
        h.update(str(a.shape).encode())
        h.update(a.tobytes())
    return h.hexdigest()


@dataclass(frozen=True)
class SplitView:
    name: str
    emb: np.ndarray
    subjects: np.ndarray
    uids: np.ndarray

    def __post_init__(self):
        if self.name not in ("train", "val"):
            raise SplitLeakError("SplitView may only wrap train/val; the test split lives in TestVault")

    @property
    def sha256(self) -> str:
        return array_sha256(self.uids, self.subjects)


def require_split(view: SplitView, expected: str) -> None:
    if not isinstance(view, SplitView):
        raise SplitLeakError("fitting code must receive a SplitView, not raw arrays")
    if view.name != expected:
        raise SplitLeakError(f"expected the {expected!r} split, got {view.name!r}")


def assert_disjoint_subjects(train: Sequence, val: Sequence, test: Sequence) -> None:
    a, b, c = set(map(str, train)), set(map(str, val)), set(map(str, test))
    if a & b or a & c or b & c:
        raise SplitLeakError(f"subject overlap: tr&va={sorted(a & b)[:3]} tr&te={sorted(a & c)[:3]} va&te={sorted(b & c)[:3]}")


def assert_calibration_provenance(calibration: Mapping[str, Any], test_sha256: str) -> None:
    """Every head's calibration was fit on val, and the val split hash differs from the test hash."""
    for head, c in calibration.get("heads", {}).items():
        fit = c.get("fit", {})
        if c.get("method") == "none":
            continue
        if fit.get("split") != "val":
            raise SplitLeakError(f"{head}: calibration fit.split must be 'val', got {fit.get('split')!r}")
        if fit.get("val_split_sha256") == test_sha256:
            raise SplitLeakError(f"{head}: calibration val split hash equals the test split hash")


def assert_head_inputs(inputs: Sequence[str]) -> None:
    """The heads consume the encoder embedding and nothing else (no physiology, HART or engineered features)."""
    if list(inputs) != list(HEAD_INPUTS):
        bad = [i for i in inputs if i not in HEAD_INPUTS]
        raise SplitLeakError(f"head inputs must be exactly {list(HEAD_INPUTS)}, got {list(inputs)} (forbidden: {bad})")


class TestVault:
    __test__ = False      # not a pytest test class

    def __init__(self, payload: Mapping[str, Any], identity: Sequence[np.ndarray], ledger_path: str):
        self.__payload = dict(payload)
        self.test_sha256 = array_sha256(*identity)
        self._ledger = ledger_path

    def entries(self):
        if not os.path.exists(self._ledger):
            return []
        with open(self._ledger) as f:
            return [json.loads(line) for line in f if line.strip()]

    def evaluate_once(self, experiment: str, bundle_sha256: str, evaluator: Callable[[Mapping[str, Any]], Dict],
                      declared: Sequence[str], rerun_reason: Optional[str] = None) -> Dict:
        prior = [e for e in self.entries() if e["test_sha256"] == self.test_sha256]
        same_exp = [e for e in prior if e["experiment"] == experiment]
        if any(e["bundle_sha256"] == bundle_sha256 for e in same_exp) and not rerun_reason:
            raise SplitLeakError(f"{experiment}: this bundle was already evaluated on this test split; reuse the report")
        if experiment not in declared and not rerun_reason:
            raise SplitLeakError(f"{experiment} is not a pre-registered experiment; refusing to open the test split")
        if same_exp and not rerun_reason:
            raise SplitLeakError(f"{experiment}: test split already evaluated with another bundle; changing a model "
                                 "after seeing test requires rerun_reason (recorded in the report)")
        report = evaluator(self.__payload)
        stamp = {"experiment": experiment, "bundle_sha256": bundle_sha256, "test_sha256": self.test_sha256,
                 "time": int(time.time()), "rerun_reason": rerun_reason, "n_test_evaluations": len(same_exp) + 1,
                 "n_evaluations_on_this_test_split": len(prior) + 1}
        report = dict(report, integrity=stamp)
        os.makedirs(os.path.dirname(self._ledger) or ".", exist_ok=True)
        with open(self._ledger, "a") as f:
            f.write(json.dumps(stamp, sort_keys=True) + "\n")
        return report


__all__ = ["SplitView", "TestVault", "SplitLeakError", "require_split", "assert_disjoint_subjects",
           "assert_calibration_provenance", "assert_head_inputs", "array_sha256", "FORBIDDEN_INPUTS"]
