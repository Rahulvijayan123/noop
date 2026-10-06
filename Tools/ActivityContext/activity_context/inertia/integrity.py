"""Statistical-integrity guards (ported from Agent E; INERTIA1.md §9, spec §26).

* :class:`SplitView` is how fitting code receives train/val data (name + content hash); it cannot wrap test.
* :class:`TestVault` owns the test split: it is constructed with a LOADER, not with arrays, and its only
  operation :meth:`TestVault.evaluate_once` checks the ledger first, then materialises the test split
  (inside the vault), hashes it, runs the caller's pre-checks (e.g. calibration provenance) and the
  evaluator, stamps the report with ``(bundle_sha256, test_sha256)`` and appends to an append-only ledger.
  Evaluating an undeclared experiment refuses; evaluating a declared experiment again (any bundle, any test
  split) refuses unless ``rerun_reason`` is one of :data:`RERUN_REASONS` and ``rerun_detail`` explains it;
  both are recorded in the ledger and surfaced in every report (``n_test_evaluations``).
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


# Enumerated rerun reasons (G-16). Free text goes into ``rerun_detail``; the code is what reports group on.
RERUN_REASONS: Dict[str, str] = {
    "artifact_lost_identical_rebuild": "the evaluated bundle was lost and rebuilt deterministically from identical "
                                       "code, data and splits; no model, rule or threshold changed",
    "post_audit_rule_change": "a training/selection/gate/metric rule changed after an audit that had seen test "
                              "results; the new test numbers are NOT pristine",
    "evaluator_bug_fix": "the evaluation code was wrong; the bundle is unchanged",
    "provenance_rebuild": "rebuilt from a clean commit only to fix provenance; model-affecting code unchanged",
}


def check_rerun_reason(reason: Optional[str], detail: Optional[str]) -> None:
    if reason is None:
        if detail:
            raise SplitLeakError("rerun_detail given without rerun_reason")
        return
    if reason not in RERUN_REASONS:
        raise SplitLeakError(f"rerun_reason must be one of {sorted(RERUN_REASONS)}, got {reason!r}")
    if not (detail or "").strip():
        raise SplitLeakError("a rerun needs rerun_detail (free text: what happened and why)")


class TestVault:
    __test__ = False      # not a pytest test class

    def __init__(self, loader: Callable[[], Mapping[str, Any]],
                 identity: Callable[[Mapping[str, Any]], Sequence[np.ndarray]], ledger_path: str):
        """``loader()`` materialises the test payload (only ever called inside :meth:`evaluate_once`);
        ``identity(payload)`` returns the arrays whose hash is the test split identity (uids, subjects)."""
        if not callable(loader) or not callable(identity):
            raise SplitLeakError("TestVault takes a loader and an identity function, never test arrays")
        self.__loader = loader
        self.__identity = identity
        self._ledger = ledger_path
        self.test_sha256: Optional[str] = None

    def entries(self):
        if not os.path.exists(self._ledger):
            return []
        with open(self._ledger) as f:
            return [json.loads(line) for line in f if line.strip()]

    def evaluate_once(self, experiment: str, bundle_sha256: str, evaluator: Callable[[Mapping[str, Any]], Dict],
                      declared: Sequence[str], rerun_reason: Optional[str] = None, rerun_detail: Optional[str] = None,
                      before: Optional[Callable[[str], None]] = None,
                      dataset_splits: Optional[Mapping[str, str]] = None,
                      history: Optional[Callable[[Mapping[str, Any]], Mapping[str, str]]] = None) -> Dict:
        """``dataset_splits`` {dataset: frozen test-split identity} (e.g. the split manifest sha256) makes the
        stamp count test reuse PER DATASET test split as well (audit G2 D-2): a combined test split that adds
        datasets to an earlier one gets a new ``test_sha256`` although it re-opens the earlier datasets' test
        subjects. ``history(entry)`` derives the per-dataset identities of ledger entries written before
        ``per_dataset_split_sha256`` was recorded."""
        check_rerun_reason(rerun_reason, rerun_detail)
        if experiment not in declared:
            raise SplitLeakError(f"{experiment} is not a pre-registered experiment; refusing to open the test split")
        same_exp = [e for e in self.entries() if e["experiment"] == experiment]
        if any(e["bundle_sha256"] == bundle_sha256 for e in same_exp) and not rerun_reason:
            raise SplitLeakError(f"{experiment}: this bundle was already evaluated on the test split; reuse the report")
        if same_exp and not rerun_reason:
            raise SplitLeakError(f"{experiment}: test split already evaluated with another bundle; changing a model "
                                 "after seeing test requires an enumerated rerun_reason (recorded in the report)")
        payload = self.__loader()                       # the test split is materialised only here
        self.test_sha256 = array_sha256(*self.__identity(payload))
        if before is not None:
            before(self.test_sha256)
        report = evaluator(payload)
        prior = [e for e in self.entries() if e["test_sha256"] == self.test_sha256]
        same = [e for e in prior if e["experiment"] == experiment]
        stamp = {"experiment": experiment, "bundle_sha256": bundle_sha256, "test_sha256": self.test_sha256,
                 "time": int(time.time()), "rerun_reason": rerun_reason, "rerun_detail": rerun_detail,
                 "rerun_reason_text": RERUN_REASONS.get(rerun_reason) if rerun_reason else None,
                 "n_test_evaluations": len(same) + 1, "n_evaluations_of_experiment_any_split": len(same_exp) + 1,
                 "n_evaluations_on_this_test_split": len(prior) + 1}
        if dataset_splits:
            counts = per_dataset_reuse(self.entries(), history)
            stamp["per_dataset_split_sha256"] = dict(sorted(dataset_splits.items()))
            stamp["n_evaluations_per_dataset_split"] = {
                d: counts.get((d, sha), 0) + 1 for d, sha in sorted(dataset_splits.items())}
        report = dict(report, integrity=stamp)
        os.makedirs(os.path.dirname(self._ledger) or ".", exist_ok=True)
        with open(self._ledger, "a") as f:
            f.write(json.dumps(stamp, sort_keys=True) + "\n")
        return report


def entry_dataset_splits(entry: Mapping[str, Any],
                         history: Optional[Callable[[Mapping[str, Any]], Mapping[str, str]]] = None) -> Dict[str, str]:
    """{dataset: test-split identity} of one ledger entry: recorded, else derived by ``history`` (else {})."""
    rec = entry.get("per_dataset_split_sha256")
    if rec:
        return dict(rec)
    if history is not None:
        try:
            return dict(history(entry) or {})
        except Exception:  # noqa: BLE001 - an undeclared historical entry simply has no derivable identity
            return {}
    return {}


def per_dataset_reuse(entries: Sequence[Mapping[str, Any]],
                      history: Optional[Callable[[Mapping[str, Any]], Mapping[str, str]]] = None) -> Dict[tuple, int]:
    """{(dataset, split identity): number of ledger entries that opened that dataset's test split}."""
    out: Dict[tuple, int] = {}
    for e in entries:
        for d, sha in entry_dataset_splits(e, history).items():
            out[(d, sha)] = out.get((d, sha), 0) + 1
    return out


__all__ = ["SplitView", "TestVault", "entry_dataset_splits", "per_dataset_reuse", "SplitLeakError", "require_split", "assert_disjoint_subjects",
           "assert_calibration_provenance", "assert_head_inputs", "array_sha256", "FORBIDDEN_INPUTS", "RERUN_REASONS",
           "check_rerun_reason"]
