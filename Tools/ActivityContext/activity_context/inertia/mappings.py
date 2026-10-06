"""The audited label crosswalk (``nara.inertia.mappings/1``): load, validate, look up, tabulate.

``label_mappings.json`` (next to this file) is the only place a source label becomes a Nara head target.
Every (dataset, source label, head) has an explicit row with ``nara_target``, ``target_type``
(mask | class | set | regression), ``mapping_confidence``, ``rationale`` and ``used_for_training``; code
never invents a mapping. It was normalised from Agent C's audited crosswalk by
``python -m activity_context.inertia.mappings build`` (see :mod:`.mappings_build`), which only *adds*
explicit blocks (dataset roles/licence policy, transition states, event pairs, set families, OOD hold-out)
and turns ``used_for_training`` off for every dataset whose role is not ``train_wrist`` (the original value
is kept as ``audit_used_for_training``).

Target encodings used downstream
--------------------------------
* class heads: ``uint16`` bitmask over the head's class order (bit k = class k), **0 = MASK**. A
  ``class`` row sets one bit, a ``set`` row several (truth is one of them). There is no ``unknown``.
* ``movement_intensity``: float in [0, 1] (``clip(ln MET / ln 12, 0, 1)``), NaN = MASK.
* ``transition``: a row's target is ``none`` (interior windows may be all-events-0 negatives) or MASK;
  positives come only from label changes (``transition_rules``) — never from a per-label row.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from dataclasses import dataclass
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import HEAD_CLASS_ORDERS, MAPPINGS_SCHEMA

MAPPINGS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "label_mappings.json")
CLASS_HEADS = ("posture", "locomotion", "arm_behavior")
ALL_ROW_HEADS = CLASS_HEADS + ("transition", "movement_intensity")
TARGET_TYPES = ("mask", "class", "set", "regression")
CONFIDENCES = ("n/a", "low", "medium", "high")
ROLES = ("train_wrist", "pooled_ablation_non_wrist", "ood_only", "excluded_licence", "excluded_other",
         "future")
TRANSITION_STATES = ("sit", "stand", "lie", "walk", "run", "sleep", "other")
MET_LOG_BASE = 12.0


class MappingError(ValueError):
    """The crosswalk file is malformed or violates the mapping policy."""


def met_to_intensity(met: float) -> float:
    """``clip(ln(MET) / ln(12), 0, 1)`` (INERTIA1.md §5)."""
    if not (isinstance(met, (int, float)) and math.isfinite(met) and met > 0):
        raise MappingError(f"MET must be a positive finite number, got {met!r}")
    return float(min(1.0, max(0.0, math.log(met) / math.log(MET_LOG_BASE))))


def bitmask(classes: Iterable[str], head: str) -> int:
    order = HEAD_CLASS_ORDERS[head]
    m = 0
    for c in classes:
        if c not in order:
            raise MappingError(f"{c!r} is not a class of head {head!r}")
        m |= 1 << order.index(c)
    return m


def mask_classes(mask: int, head: str) -> List[str]:
    return [c for k, c in enumerate(HEAD_CLASS_ORDERS[head]) if mask >> k & 1]


@dataclass(frozen=True)
class LabelTargets:
    """Training targets of one source label (only rows with used_for_training=True count)."""
    posture: int
    locomotion: int
    arm_behavior: int
    transition_none_ok: bool        # interior windows of this label may be all-events-0 negatives
    movement_intensity: float       # NaN = MASK
    transition_state: Optional[str]  # None = unlabelled/null


class Crosswalk:
    """Read-only view over ``label_mappings.json``."""

    def __init__(self, doc: Mapping[str, Any], sha256: str, path: str = ""):
        self.doc = doc
        self.sha256 = sha256
        self.path = path
        self._rows: Dict[Tuple[str, str, str], Mapping[str, Any]] = {}
        for r in doc["mappings"]:
            key = (r["dataset"], str(r["source_label"]), r["nara_head"])
            if key in self._rows:
                raise MappingError(f"duplicate mapping row {key}")
            self._rows[key] = r

    # -- dataset level -----------------------------------------------------
    def role(self, dataset: str) -> str:
        return self.doc["dataset_roles"][dataset]["role"]

    def datasets(self, role: Optional[str] = None) -> List[str]:
        return sorted(d for d, v in self.doc["dataset_roles"].items() if role is None or v["role"] == role)

    def source_labels(self, dataset: str) -> List[str]:
        return sorted({k[1] for k in self._rows if k[0] == dataset})

    def row(self, dataset: str, source_label: str, head: str) -> Mapping[str, Any]:
        try:
            return self._rows[(dataset, str(source_label), head)]
        except KeyError:
            raise MappingError(f"no mapping row for {dataset}/{source_label!r}/{head}") from None

    def has_label(self, dataset: str, source_label: str) -> bool:
        return (dataset, str(source_label), "posture") in self._rows

    # -- targets -----------------------------------------------------------
    def class_target(self, dataset: str, source_label: str, head: str) -> int:
        r = self.row(dataset, source_label, head)
        if not r["used_for_training"]:
            return 0
        t = r["nara_target"]
        return bitmask([t] if r["target_type"] == "class" else t, head)

    def intensity_target(self, dataset: str, source_label: str) -> float:
        r = self.row(dataset, source_label, "movement_intensity")
        if not r["used_for_training"] or r["target_type"] != "regression":
            return float("nan")
        return met_to_intensity(float(r["nara_target"]["met"]))

    def transition_none_ok(self, dataset: str, source_label: str) -> bool:
        r = self.row(dataset, source_label, "transition")
        return bool(r["used_for_training"] and r["nara_target"] == "none")

    def transition_state(self, dataset: str, source_label: str) -> Optional[str]:
        return self.doc["transition_states"].get(dataset, {}).get(str(source_label))

    def label_targets(self, dataset: str, source_label: str) -> LabelTargets:
        return LabelTargets(
            posture=self.class_target(dataset, source_label, "posture"),
            locomotion=self.class_target(dataset, source_label, "locomotion"),
            arm_behavior=self.class_target(dataset, source_label, "arm_behavior"),
            transition_none_ok=self.transition_none_ok(dataset, source_label),
            movement_intensity=self.intensity_target(dataset, source_label),
            transition_state=self.transition_state(dataset, source_label))

    def target_table(self, dataset: str, labels: Sequence[str]) -> Dict[str, np.ndarray]:
        """Vectorised per-label-code targets: arrays indexed by the position in ``labels``."""
        lt = [self.label_targets(dataset, lab) for lab in labels]
        return {"posture": np.array([t.posture for t in lt], np.uint16),
                "locomotion": np.array([t.locomotion for t in lt], np.uint16),
                "arm_behavior": np.array([t.arm_behavior for t in lt], np.uint16),
                "transition_none_ok": np.array([t.transition_none_ok for t in lt], bool),
                "movement_intensity": np.array([t.movement_intensity for t in lt], np.float32)}

    def event_pairs(self) -> Dict[Tuple[str, str], List[str]]:
        return {(p["from"], p["to"]): list(p["events"]) for p in self.doc["event_pairs"]}

    def transition_rule(self, dataset: str) -> Mapping[str, Any]:
        return self.doc["transition_rules"].get(dataset, {"mode": "mask"})

    def set_families(self, head: str) -> Dict[str, List[str]]:
        return {k: list(v) for k, v in self.doc["set_families"].get(head, {}).items()}

    def ood_holdout(self, dataset: str) -> List[str]:
        return [str(x) for x in self.doc["ood_holdout"].get(dataset, [])]


def load_mappings(path: Optional[str] = None) -> Crosswalk:
    path = path or MAPPINGS_PATH
    with open(path, "rb") as f:
        data = f.read()
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MappingError(f"{path} is not valid JSON: {exc}") from exc
    if doc.get("schema") != MAPPINGS_SCHEMA:
        raise MappingError(f"label mapping schema must be {MAPPINGS_SCHEMA!r}, got {doc.get('schema')!r}")
    cw = Crosswalk(doc, hashlib.sha256(data).hexdigest(), path)
    problems = validate(cw)
    if problems:
        raise MappingError("label_mappings.json failed validation:\n  " + "\n  ".join(problems[:20]))
    return cw


def validate(cw: Crosswalk) -> List[str]:
    """Policy checks; returns a list of problems (empty = valid)."""
    out: List[str] = []
    doc = cw.doc
    if doc.get("head_class_orders") != {h: list(v) for h, v in HEAD_CLASS_ORDERS.items()}:
        out.append("head_class_orders differ from INERTIA1.md / activity_context.inertia")
    for ds, v in doc["dataset_roles"].items():
        if v.get("role") not in ROLES:
            out.append(f"{ds}: unknown role {v.get('role')!r}")
    for r in doc["mappings"]:
        key = f"{r['dataset']}/{r['source_label']}/{r['nara_head']}"
        tt, tgt, head = r["target_type"], r["nara_target"], r["nara_head"]
        if head not in ALL_ROW_HEADS:
            out.append(f"{key}: unknown head")
            continue
        if tt not in TARGET_TYPES or r["mapping_confidence"] not in CONFIDENCES:
            out.append(f"{key}: bad target_type/confidence")
        if not isinstance(r.get("rationale"), str) or not r["rationale"].strip():
            out.append(f"{key}: missing rationale")
        if tt == "mask":
            if tgt != "MASK" or r["used_for_training"]:
                out.append(f"{key}: a MASK row must have nara_target 'MASK' and used_for_training false")
        elif tgt == "unknown" or (isinstance(tgt, list) and "unknown" in tgt):
            out.append(f"{key}: 'unknown' is never a training target")
        if r["used_for_training"] and doc["dataset_roles"][r["dataset"]]["role"] != "train_wrist":
            out.append(f"{key}: used_for_training on a dataset whose role is not train_wrist")
        if tt in ("class", "set") and head in CLASS_HEADS:
            classes = [tgt] if tt == "class" else tgt
            if not isinstance(classes, list) or not classes or any(c not in HEAD_CLASS_ORDERS[head] for c in classes):
                out.append(f"{key}: target {tgt!r} not in the {head} class order")
            if tt == "set" and len(set(classes)) < 2:
                out.append(f"{key}: a set target needs >= 2 distinct classes")
        if head == "transition" and tt == "class" and tgt != "none" and tgt not in HEAD_CLASS_ORDERS["transition"]:
            out.append(f"{key}: transition target {tgt!r} is neither 'none' nor an event")
        if head == "movement_intensity" and tt == "regression":
            if isinstance(tgt, dict) and isinstance(tgt.get("met"), str) and not r["used_for_training"]:
                continue        # per-minute measured METs (GOTOV, excluded): not a fixed label value
            try:
                v = met_to_intensity(float(tgt["met"]))
                if abs(v - float(tgt["value"])) > 1e-3:
                    out.append(f"{key}: value {tgt['value']} != clip(ln MET/ln 12) = {v:.4f}")
            except (MappingError, KeyError, TypeError, ValueError):
                out.append(f"{key}: regression target needs a positive 'met'")
    # completeness: every source label of a used dataset has a row for every head
    for ds in doc["dataset_roles"]:
        labels = cw.source_labels(ds)
        for lab in labels:
            for head in ALL_ROW_HEADS:
                if (ds, lab, head) not in cw._rows:
                    out.append(f"{ds}/{lab}: no row for head {head}")
        states = doc["transition_states"].get(ds, {})
        for lab, st in states.items():
            if st is not None and st not in TRANSITION_STATES:
                out.append(f"{ds}/{lab}: unknown transition state {st!r}")
    for p in doc["event_pairs"]:
        if any(e not in HEAD_CLASS_ORDERS["transition"] for e in p["events"]):
            out.append(f"event pair {p['from']}->{p['to']} names a non-event")
    for head, fams in doc["set_families"].items():
        for rep, members in fams.items():
            if rep not in members or any(m not in HEAD_CLASS_ORDERS[head] for m in members):
                out.append(f"set family {head}/{rep} malformed")
    return out


def markdown_table(cw: Crosswalk, datasets: Optional[Sequence[str]] = None) -> str:
    """Human-readable audit table (spec §10): one line per (dataset, source label, head)."""
    lines = [f"# Inertia head label mappings (`{MAPPINGS_SCHEMA}`)", "",
             f"Source: `activity_context/inertia/label_mappings.json` (sha256 `{cw.sha256}`), normalised from "
             f"Agent C's audited crosswalk (`{cw.doc['source']['path']}`, sha256 `{cw.doc['source']['sha256']}`).",
             "Generated by `python -m activity_context.inertia.mappings table`. `MASK` = the head is not "
             "supervised by the label (zero loss) — never `unknown`. Sets `{a, b}` = the truth is one of them.", "",
             "## Dataset roles", "", "| dataset | role | licence | placement | note |", "|---|---|---|---|---|"]
    for ds in sorted(cw.doc["dataset_roles"]):
        v = cw.doc["dataset_roles"][ds]
        lines.append(f"| {ds} | {v['role']} | {v.get('licence', '')} | {v.get('placement', '')} | {v.get('note', '')} |")
    lines += ["", "## Rows", "", "| dataset | source label | name | head | target | type | confidence | "
              "used_for_training | rationale |", "|---|---|---|---|---|---|---|---|---|"]
    for r in cw.doc["mappings"]:
        if datasets and r["dataset"] not in datasets:
            continue
        tgt = r["nara_target"]
        if isinstance(tgt, list):
            tgt = "{" + ", ".join(tgt) + "}"
        elif isinstance(tgt, dict):
            tgt = f"MET {tgt.get('met')} → {tgt.get('value')}"
        used = "yes" if r["used_for_training"] else ("no (policy)" if r.get("audit_used_for_training") else "no")
        rat = str(r["rationale"]).replace("|", "/").replace("\n", " ")
        name = str(r.get("source_label_name", "")).replace("|", "/")
        lab = str(r["source_label"]).replace("|", "/")
        lines.append(f"| {r['dataset']} | {lab} | {name} | {r['nara_head']} | {tgt} | {r['target_type']} | "
                     f"{r['mapping_confidence']} | {used} | {rat} |")
    return "\n".join(lines) + "\n"


def summary_counts(cw: Crosswalk) -> List[Dict[str, Any]]:
    """Per dataset: role, #labels, #rows used for training per head."""
    out = []
    for ds in sorted(cw.doc["dataset_roles"]):
        rows = [r for r in cw.doc["mappings"] if r["dataset"] == ds]
        used = {h: sum(1 for r in rows if r["nara_head"] == h and r["used_for_training"]) for h in ALL_ROW_HEADS}
        out.append({"dataset": ds, "role": cw.role(ds), "n_labels": len({r["source_label"] for r in rows}),
                    "n_rows": len(rows), "used_rows": used})
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(prog="python -m activity_context.inertia.mappings")
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build", help="normalise Agent C's crosswalk into label_mappings.json")
    b.add_argument("--src", required=True)
    b.add_argument("--out", default=MAPPINGS_PATH)
    t = sub.add_parser("table", help="write the human-readable mapping table")
    t.add_argument("--out", required=True)
    sub.add_parser("validate")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        from .mappings_build import build_file
        sha = build_file(a.src, a.out)
        print(json.dumps({"out": a.out, "sha256": sha}))
        return 0
    cw = load_mappings()
    if a.cmd == "table":
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(markdown_table(cw))
        print(json.dumps({"out": a.out, "rows": len(cw.doc["mappings"]), "sha256": cw.sha256}))
    else:
        print(json.dumps({"valid": True, "sha256": cw.sha256, "rows": len(cw.doc["mappings"])}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
