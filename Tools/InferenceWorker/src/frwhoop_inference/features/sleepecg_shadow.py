"""SleepECG shadow comparison (spec section 5 A8, contract \u00a73 sleepecg_shadow).

The SleepECG ``wrn-gru-mesa`` candidate lane runs through ``POST /v1/infer``
metric ``sleep_stage`` and its staged results are NOT delivered inside the
sleep-features request. In this first wave ``compute`` therefore:

* returns ``status: "not_run"`` with reason ``candidate_lane_result_not_provided``
  when the request's ``capabilities`` carry no SleepECG result block, and
* if ``capabilities.sleepecg_shadow.report`` (or the block itself) carries the
  two label series, runs the pure comparison and returns the full report.

The comparison lives in the pure ``compare`` function and is unit-tested
independently. It compares V2 vs SleepECG in their COMMON label space:
V2 light/deep -> NREM; WAKE and REM unchanged. Disagreement does not establish
which model is correct, and no Light/Deep claim is ever made for SleepECG
(SleepECG cannot provide an independent Light/Deep distinction).
"""

from __future__ import annotations

import math
from typing import Any, Mapping, Sequence

from .config import SleepFeaturesConfig
from .contract import SleepFeaturesRequest, json_finite

#: Common label space of the comparison.
COMMON_LABELS = ("wake", "nrem", "rem")

#: Disagreement within this many epochs of the compared span's first/last
#: compared epoch counts as "near onset/offset". Not a contract wire key; the
#: config object has no field for it, so a caller may supply one via
#: ``getattr(cfg, "sleepecg_near_boundary_epochs", 30)``.
DEFAULT_NEAR_BOUNDARY_EPOCHS = 30

_V2_MAP = {"wake": "wake", "light": "nrem", "deep": "nrem", "rem": "rem"}

#: Tolerant normalisation for the SleepECG lane's label spellings. The
#: wrn-gru-mesa provider emits per-epoch stages; both N1/N2/N3 and NREM/REM
#: spellings are accepted, plus the V2 vocab in case a caller passes it.
_SLEEPECG_MAP = {
    "wake": "wake", "w": "wake",
    "nrem": "nrem", "n1": "nrem", "n2": "nrem", "n3": "nrem",
    "light": "nrem", "deep": "nrem",
    "rem": "rem", "r": "rem",
}


def _normalise_v2(label: str) -> str | None:
    return _V2_MAP.get(label.lower())


def _normalise_sleepecg(label: str) -> str | None:
    return _SLEEPECG_MAP.get(label.lower())


def _distributions(compared: list[tuple[str, str]]) -> tuple[dict[str, float], dict[str, float]]:
    n = len(compared)
    v2_counts = {k: 0 for k in COMMON_LABELS}
    sc_counts = {k: 0 for k in COMMON_LABELS}
    for v2, sc in compared:
        v2_counts[v2] += 1
        sc_counts[sc] += 1
    v2_dist = {k: (v2_counts[k] / n if n else None) for k in COMMON_LABELS}
    sc_dist = {k: (sc_counts[k] / n if n else None) for k in COMMON_LABELS}
    return v2_dist, sc_dist


def compare(
    v2_labels: Sequence[str],
    sleepecg_labels: Sequence[str],
    *,
    near_boundary_epochs: int = DEFAULT_NEAR_BOUNDARY_EPOCHS,
) -> dict[str, Any]:
    """Compare two label series in the common label space (pure).

    Only epochs where BOTH series have a valid common-space label are compared;
    anything unmapped (e.g. V2 ``uns``) is excluded. Returns the contract
    ``sleepecg_shadow`` report minus ``weights_revision`` (supplied by the
    caller): ``epochs_compared``, ``agreement_pct``, ``agreement_by_label``
    {wake, nrem, rem}, ``v2_distribution``, ``sleepecg_distribution``,
    ``disagreement_near_onset_offset_pct`` and ``status``/``reasons``.
    """
    reasons: list[str] = []
    if len(v2_labels) != len(sleepecg_labels):
        reasons.append("length_mismatch")
    n = min(len(v2_labels), len(sleepecg_labels))

    compared: list[tuple[str, str]] = []
    agreements = 0
    for i in range(n):
        v2 = _normalise_v2(v2_labels[i])
        sc = _normalise_sleepecg(sleepecg_labels[i])
        if v2 is None or sc is None:
            continue
        compared.append((v2, sc))
        if v2 == sc:
            agreements += 1

    epochs_compared = len(compared)
    if epochs_compared == 0:
        reasons.append("no_common_valid_epochs")
        return {
            "epochs_compared": 0,
            "agreement_pct": None,
            "agreement_by_label": {k: None for k in COMMON_LABELS},
            "v2_distribution": {k: None for k in COMMON_LABELS},
            "sleepecg_distribution": {k: None for k in COMMON_LABELS},
            "disagreement_near_onset_offset_pct": None,
            "status": "partial",
            "reasons": sorted(set(reasons)),
        }

    agreement_pct = 100.0 * agreements / epochs_compared

    agreement_by_label: dict[str, float | None] = {}
    for label in COMMON_LABELS:
        total = sum(1 for v2, _sc in compared if v2 == label)
        if total == 0:
            agreement_by_label[label] = None
        else:
            agree = sum(1 for v2, sc in compared if v2 == label and v2 == sc)
            agreement_by_label[label] = 100.0 * agree / total

    v2_dist, sc_dist = _distributions(compared)

    # Disagreements within near_boundary_epochs of the FIRST or LAST compared
    # epoch count as near onset/offset. Index here is the position within the
    # compared sequence.
    disagreements = [i for i, (v2, sc) in enumerate(compared) if v2 != sc]
    k = max(0, int(near_boundary_epochs))
    near = [i for i in disagreements if i < k or i >= epochs_compared - k]
    disagreement_near_onset_offset_pct = (
        (100.0 * len(near) / len(disagreements)) if disagreements else 0.0
    )

    return {
        "epochs_compared": epochs_compared,
        "agreement_pct": json_finite(round(agreement_pct, 2)),
        "agreement_by_label": {
            k: json_finite(None if v is None else round(v, 2)) for k, v in agreement_by_label.items()
        },
        "v2_distribution": {k: json_finite(None if v is None else round(v, 4)) for k, v in v2_dist.items()},
        "sleepecg_distribution": {
            k: json_finite(None if v is None else round(v, 4)) for k, v in sc_dist.items()
        },
        "disagreement_near_onset_offset_pct": json_finite(
            round(disagreement_near_onset_offset_pct, 2)),
        "status": "available",
        "reasons": sorted(set(reasons)),
    }


def _block_labels(block: Mapping[str, Any]) -> tuple[list[str] | None, list[str] | None]:
    """Pull the two label series from a SleepECG capability block.

    Accepts either ``block.report.v2_labels/sleepecg_labels`` or the labels at
    the block's own top level.
    """
    report = block.get("report")
    if isinstance(report, Mapping):
        source = report
    else:
        source = block
    v2 = source.get("v2_labels")
    sc = source.get("sleepecg_labels")
    if isinstance(v2, (list, tuple)) and isinstance(sc, (list, tuple)):
        return [str(x) for x in v2], [str(x) for x in sc]
    return None, None


def compute(req: SleepFeaturesRequest, cfg: SleepFeaturesConfig) -> dict[str, Any]:
    """The ``capabilities.sleepecg_shadow`` report for this request.

    First wave: the candidate lane's staged result is not part of the
    sleep-features request, so unless ``capabilities`` carries a SleepECG
    result block with the two label series the report is ``not_run`` with
    reason ``candidate_lane_result_not_provided``.
    """
    capabilities = req.capabilities or {}
    block = capabilities.get("sleepecg_shadow")

    if isinstance(block, Mapping):
        v2, sc = _block_labels(block)
        if v2 is not None and sc is not None:
            report = compare(
                v2,
                sc,
                near_boundary_epochs=int(
                    getattr(cfg, "sleepecg_near_boundary_epochs", DEFAULT_NEAR_BOUNDARY_EPOCHS)
                ),
            )
            weights = block.get("weights_revision")
            report["weights_revision"] = weights if isinstance(weights, str) else None
            return report

    return {
        "epochs_compared": None,
        "agreement_pct": None,
        "agreement_by_label": {k: None for k in COMMON_LABELS},
        "v2_distribution": {k: None for k in COMMON_LABELS},
        "sleepecg_distribution": {k: None for k in COMMON_LABELS},
        "disagreement_near_onset_offset_pct": None,
        "weights_revision": None,
        "status": "not_run",
        "reason": "candidate_lane_result_not_provided",
        "reasons": ["candidate_lane_result_not_provided"],
    }
