"""One-off normaliser: Agent C's audited crosswalk -> ``label_mappings.json`` (``nara.inertia.mappings/1``).

Run once (``python -m activity_context.inertia.mappings build --src <agentC>/label_mappings.json``); the
output is committed and is what every training run reads. Everything this adds is *explicit data* in the
output file (so it can be audited without reading code):

* ``dataset_roles``: licence/placement policy (INERTIA1.md §5 "Training data policy"). Only
  ``train_wrist`` datasets keep ``used_for_training``; every other row is forced to ``false`` with
  ``policy`` naming the reason and ``audit_used_for_training`` keeping Agent C's value.
* ``licence_decisions``: the owner's decision of 2026-10-06 — GOTOV and WEAR (CC BY-NC-SA 4.0) are
  ``train_wrist`` for non-commercial use. Their rows keep exactly Agent C's audited ``used_for_training`` (every
  such row is confidence high/medium; asserted) and say so in ``licence_decision``; their low-confidence /
  candidate rows stay unused with an explicit ``policy``. Sets with no stated (or a conflicting) licence stay
  ``excluded_licence``. GOTOV's measured-MET rows get the explicit per-window rule (loader ``gotov-met-1``).
* ``transition_states``: per (dataset, source label) the coarse state used to derive transition events
  from label changes (sit/stand/lie/walk/run/sleep/other, null = unlabelled), computed by the documented
  rule ``transition_states_rule`` from the audited posture/locomotion rows.
* ``event_pairs``: state change -> events (Agent C ``transition_derivation.event_semantics``).
* ``transition_rules``: per-dataset event-target policy (Agent C ``transition_derivation.by_dataset``).
* ``set_families``: a set target whose members lack direct evidence is credited to the family
  representative, which then ``covers`` the unsupported members (INERTIA1.md §5 ``covers``).
* ``ood_holdout``: activities withheld from the OOD-benchmark bundle (Agent C ``ood_candidates``).
* rationales: rows Agent C left blank get the explicit one-line reason from :mod:`.mappings_rationales`
  (never an invented "the label names the target"); a blank row without an entry is refused.
* portability: machine-specific absolute paths are rewritten to ``$INERTIA_DATA_ROOT/...`` / ``$WISDM_DIR``.
* window-assignment convention: states the rule ``windows.py`` implements (>= 90 % one non-null label); the
  audit's "100 % for transition-adjacent windows" was never implemented and is withdrawn.
"""

from __future__ import annotations

import copy
import hashlib
import json
import re
from typing import Any, Dict, List, Optional

from . import HEAD_CLASS_ORDERS, MAPPINGS_SCHEMA

ROLES = {
    "capture24": ("train_wrist", "CC BY 4.0", "wrist (dominant)"),
    "wisdm2019_watch": ("train_wrist", "CC BY 4.0", "wrist (dominant, watch)"),
    "hhar_watch": ("train_wrist", "CC BY 4.0", "wrist (side unknown, watch)"),
    "pamap2": ("train_wrist", "CC BY 4.0", "wrist (hand IMU, dominant)"),
    "mhealth": ("train_wrist", "CC BY 4.0", "right lower arm"),
    "opportunity": ("train_wrist", "CC BY 4.0", "wrist/forearm (one stream per subject-session)"),
    "uci_hapt_waist": ("pooled_ablation_non_wrist", "CC BY 4.0", "waist"),
    "harth": ("pooled_ablation_non_wrist", "CC BY 4.0", "back/thigh"),
    "har70plus": ("pooled_ablation_non_wrist", "CC BY 4.0", "back/thigh"),
    "daphnet_fog": ("ood_only", "CC BY 4.0", "ankle/thigh/trunk (non-wrist)"),
    "wear": ("train_wrist", "CC BY-NC-SA 4.0", "wrist (one per subject: left, else right; Bangle.js)"),
    "gotov": ("train_wrist", "CC BY-NC-SA 4.0", "wrist (right, GENEActiv)"),
    "extrasensory_watch": ("excluded_licence", "no licence stated", "wrist"),
    "realworld2016": ("excluded_licence", "no licence stated", "forearm"),
    "ut_complex_shoaib2016": ("excluded_licence", "no licence stated (and no subject ids)", "wrist"),
    "uci_hmp_wrist": ("excluded_licence", "UCI CC BY 4.0 vs README commercial restriction (conflict)", "wrist"),
    "dsads": ("excluded_other", "CC BY 4.0", "arm segment unverified"),
    "recofit": ("excluded_other", "unverified (not downloaded)", "forearm"),
    "nara_activity_stretch_feedback": ("future", "Nara user data", "WHOOP wrist"),
}
ROLE_NOTES = {
    "train_wrist": "v1 training set (CC BY 4.0, wrist/forearm)",
    "pooled_ablation_non_wrist": "non-wrist: pooled-placement ablation / transition-timing reference only",
    "ood_only": "OOD probe only (non-wrist; informative, not a Nara wrist result)",
    "excluded_licence": "excluded from training: no licence stated (or a conflicting one); not covered by the "
                        "2026-10-06 licence decision",
    "excluded_other": "excluded from v1 training (see note)",
    "future": "future personal supervision; not a v1 dependency",
}
NULL_LABELS = {"opportunity": ["loc:0"], "pamap2": ["0"], "hhar_watch": ["null"], "mhealth": ["0"],
               "capture24": ["<NA>"], "daphnet_fog": ["0"], "uci_hapt_waist": [], "harth": [], "har70plus": [],
               "gotov": ["NA"], "wear": ["null"]}
NC_SA = ("gotov", "wear")
NC_SA_NOTE = ("training set since 2026-10-06: CC BY-NC-SA 4.0, non-commercial use approved by the owner (Nara is "
              "non-commercial); attribution in Tools/ActivityContext/NOTICE.md; bundles record training_data_licences")
LICENCE_DECISIONS = [{
    "date": "2026-10-06",
    "decision": "GOTOV and WEAR (CC BY-NC-SA 4.0) may be used to train the Inertia motion heads (non-commercial use)",
    "datasets": list(NC_SA), "licence": "CC BY-NC-SA 4.0 (https://creativecommons.org/licenses/by-nc-sa/4.0/)",
    "basis": "approved by the owner on 2026-10-06; Nara is non-commercial (PolyForm Noncommercial 1.0.0)",
    "conditions": ["attribution and the changes made are listed in Tools/ActivityContext/NOTICE.md and ATTRIBUTION.md",
                   "no raw or windowed data is committed or redistributed (only aggregate metrics and label vocabularies)",
                   "every bundle trained on them records training_data_licences including 'CC BY-NC-SA 4.0' and stays "
                   "outside git; such bundles must not be used commercially or relicensed under terms that drop the "
                   "NC/SA conditions"],
    "rows": "Agent C's audited used_for_training is kept as is (every such row is confidence high/medium); its "
            "low-confidence / candidate rows stay unused",
    "still_excluded": {"extrasensory_watch": "no licence stated", "realworld2016": "no licence stated",
                       "ut_complex_shoaib2016": "no licence stated (and no subject ids)",
                       "uci_hmp_wrist": "UCI CC BY 4.0 vs README commercial restriction (conflict)"},
}]
GOTOV_MET_RULE = ("per window: clip(ln(mean measured METS) / ln 12, 0, 1); loader gotov-met-1: COSMED K4b2 "
                  "breath-by-breath METS (> 0), each held until the next breath when <= 15 s later, time-weighted over "
                  "the window's 20 Hz samples, >= 90 % of the window measured; the first 60 s of every activity "
                  "(VO2 on-kinetics) and participants without COSMED are MASK")
LOADER_VERIFICATION = {
    "gotov": ("loader gotov-loader-1 (2026-10-06): 35/35 right-wrist files; GENEActiv clock 600/7 = 85.714 Hz (CSV "
              "steps 4-15 ms, <= 15 ms from a uniform grid over every file; Agent C's '83 Hz' was nominal); no "
              "missing samples, no NaN; units g (median |a| over the rest labels 0.997-1.022 g per participant); "
              "31 COSMED files on the same unix-ms clock; labels protocol-imputed -> 10 s guard at every labelled "
              "segment edge (gotov-guard-10s); outdoor walking only in 22 participants"),
    "wear": ("loader wear-loader-1 (2026-10-06): 24 files sbj_0..23, uniform 50 Hz, units g (median |a| during "
             "stretching 0.997-1.023 g, both wrists); one wrist per subject (left unless < 95 % finite: sbj_10 left "
             "arm 25.8 % NaN -> right)"),
}
EVENT_PAIRS = [
    ("sit", "stand", ["sit_to_stand_like"]), ("stand", "sit", ["stand_to_sit_like"]),
    ("sit", "lie", ["lying_down_like"]), ("stand", "lie", ["lying_down_like"]),
    ("lie", "sit", ["getting_up_like"]), ("lie", "stand", ["getting_up_like"]),
    ("sit", "walk", ["sit_to_stand_like", "walk_start"]), ("walk", "sit", ["walk_stop", "stand_to_sit_like"]),
    ("stand", "walk", ["walk_start"]), ("walk", "stand", ["walk_stop"]),
    ("walk", "run", ["run_start"]), ("stand", "run", ["run_start"]),
    ("run", "walk", ["run_stop"]), ("run", "stand", ["run_stop"]),
    ("lie", "walk", ["getting_up_like", "walk_start"]), ("walk", "lie", ["walk_stop", "lying_down_like"]),
]
TRANSITION_RULES = {
    "opportunity": {"mode": "direct_switch", "max_null_s": 1.0, "timing_ground_truth": True,
                    "event_intervals_s": {"stand_to_sit_like": [-4.0, 1.0], "sit_to_stand_like": [-1.0, 5.0],
                                          "default": [-2.0, 2.0]},
                    "source": "Agent C: expert video annotation; BACK-IMU peak check (Stand->Sit -1.2 s, Sit->Stand +1.1 s)"},
    "pamap2": {"mode": "direct_switch", "max_null_s": 0.0, "timing_ground_truth": True,
               "allowed_pairs": [["sit", "stand"], ["lie", "sit"]],
               "event_intervals_s": {"default": [-8.0, 2.0]},
               "source": "Agent C: operator GUI switches; chest peak 3.7-5.8 s before the 2->3 switch; "
                         "all transitions through activityID 0 are MASK"},
    "hhar_watch": {"mode": "null_gap", "max_null_s": 10.0, "timing_ground_truth": True,
                   "allowed_pairs": [["stand", "sit"]],
                   "source": "Agent C: stand->null(5-10 s)->sit; the whole null gap must lie inside the window"},
    "capture24": {"mode": "null_gap", "max_null_s": 28.0, "timing_ground_truth": False, "window_s_only": [30],
                  "source": "Agent C: camera every 20-40 s; change lies inside the unannotated gap; event-presence "
                            "semantics only (30-s windows fully containing a <= 28-s gap); sleep onset/offset MASK"},
    "wisdm2019_watch": {"mode": "negatives_only",
                        "source": "separate recordings; timestamps jump at activity changes -> no positives"},
    "mhealth": {"mode": "negatives_only", "source": "all changes through 20-60 s nulls -> no positives"},
    "gotov": {"mode": "negatives_only",
              "source": "Agent C: labels imputed from the protocol (researcher-recorded start/end), NA gaps 15-80 s -> "
                        "no positives; interior windows of the audited 'none' rows are negatives (after the 10 s "
                        "label guard)"},
    "wear": {"mode": "mask", "source": "Agent C: run_start/run_stop candidates only (low); null content unknown -> "
                                       "no transition targets"},
}
COMMON_TRANSITION_POLICY = {
    "positive": "event interval [a, b] lies inside [w0 + 1 s, w1 - 1 s] (event-presence semantics)",
    "negative": "all 8 events 0 only for windows inside one labelled segment whose transition row is 'none', "
                ">= 5 s from every segment boundary, recording edge, gap or unlabelled interval",
    "guard_s": 3.0, "interior_margin_s": 5.0,
    "mask": "everything else: windows partially overlapping an event interval, any non-event label change "
            "within the window +- guard, unlabelled spans",
}
SET_FAMILIES = {"locomotion": {"walking": ["walking", "brisk_walking"]}}
OOD_HOLDOUT_FIXED = {"wisdm2019_watch": ["M", "O", "P"], "pamap2": ["20", "24"], "mhealth": ["8", "12"]}
C24_OOD_GROUPS = ("sports", "manual-work")


def ROLES_NOTE(dataset: str) -> str:
    return ROLE_NOTES[ROLES[dataset][0]]


def _nc_sa_row(r: Dict[str, Any]) -> None:
    """GOTOV / WEAR row under the 2026-10-06 licence decision (see ``licence_decisions``)."""
    from .mappings import MEASURED_MET, MappingError
    if r["used_for_training"]:
        if r["mapping_confidence"] not in ("high", "medium"):
            raise MappingError(f"{r['dataset']}/{r['source_label']}/{r['nara_head']}: a trained NC-SA row must be "
                               "confidence high/medium")
        r["licence_decision"] = ("2026-10-06: CC BY-NC-SA 4.0 approved for non-commercial training; row trained as "
                                 f"audited by Agent C (confidence {r['mapping_confidence']})")
    elif r["target_type"] != "mask":
        r["policy"] = (f"not trained: Agent C's audit left this row unused (confidence {r['mapping_confidence']}"
                       f"{'' if r['mapping_confidence'] == 'low' else ', candidate'}); unchanged by the 2026-10-06 "
                       "licence decision")
    t = r["nara_target"]
    if r["nara_head"] == "movement_intensity" and isinstance(t, dict) and t.get("met") == MEASURED_MET:
        r["nara_target"] = {"met": MEASURED_MET, "value": GOTOV_MET_RULE}


def _state(rows: Dict[str, Dict[str, Any]], dataset: str, label: str) -> Optional[str]:
    if label in NULL_LABELS.get(dataset, []):
        return None

    def target(head):
        r = rows.get(head)
        if r is None or not r.get("audit_used_for_training", r["used_for_training"]):
            return None
        return r["nara_target"] if r["target_type"] in ("class", "set") else None

    post, loco = target("posture"), target("locomotion")
    if post == "recumbent":
        return "sleep" if dataset == "capture24" and "sleeping" in label else "lie"
    if post == "seated_likely":
        return "sit"
    if post == "upright_stationary" and loco == "stationary":
        return "stand"
    if isinstance(loco, list) and "walking" in loco and "stationary" not in loco or loco in ("walking", "brisk_walking"):
        return "walk"
    if loco == "running":
        return "run"
    return "other"


WINDOW_RULE = ("assign a window the mapped target only if ONE non-null source label covers >= 90% of its samples "
               "(windows.py PURITY; the remaining <= 10% may be unlabelled or another label); otherwise MASK. Never "
               "majority-vote across labels with different targets. (The audit draft's extra '100% for "
               "transition-adjacent windows' rule was never implemented and is withdrawn.)")
# absolute local prefixes (any machine) -> environment-variable form
_PORTABLE = ((re.compile(r"(?<![\w$])/(?:[^/\"]+/)*?nara-activity-research/scratch/wisdm-data/unpacked/data/wisdm-dataset"),
              "$WISDM_DIR"),
             (re.compile(r"(?<![\w$])/(?:[^/\"]+/)*?research/(?=(?:har-datasets|inertia-[a-z0-9-]+)/)"), "$INERTIA_DATA_ROOT/"))
C24_ORA_NOTE = ("$INERTIA_DATA_ROOT/har-datasets/capture24/ora_stream: 48 complete participant files, every one verified "
                "identical to the HF mirror on 2026-10-05 (row counts, timestamps, x/y/z <= 1e-6, annotations; "
                "research/inertia-work/agentFP/c24_verify); the downloader stopped at P008 and is not running")


def portable(o: Any) -> Any:
    """Rewrite machine-specific absolute paths (recursively) to environment-variable form."""
    if isinstance(o, dict):
        return {k: portable(v) for k, v in o.items()}
    if isinstance(o, list):
        return [portable(v) for v in o]
    if isinstance(o, str):
        for pat, rep in _PORTABLE:
            o = pat.sub(rep, o)
    return o


def normalise(src: Dict[str, Any], src_sha256: str, src_path: str) -> Dict[str, Any]:
    from .mappings import MappingError
    from .mappings_rationales import RATIONALES
    rows = copy.deepcopy(src["mappings"])
    for r in rows:
        r["source_label"] = str(r["source_label"])
        if not str(r.get("rationale") or "").strip():
            key = (r["dataset"], r["source_label"], r["nara_head"])
            if key not in RATIONALES:
                raise MappingError(f"{key}: blank rationale and no explicit entry in mappings_rationales.RATIONALES")
            r["rationale"] = RATIONALES[key]
            r["rationale_source"] = "Nara normaliser: explicit rationale (mappings_rationales; Agent C left it blank)"
        role = ROLES[r["dataset"]][0]
        r["audit_used_for_training"] = bool(r["used_for_training"])
        if role != "train_wrist" and r["used_for_training"]:
            r["used_for_training"] = False
            r["policy"] = f"dataset role {role}: {ROLES_NOTE(r['dataset'])} ({ROLES[r['dataset']][1]})"
        if r["dataset"] in NC_SA:
            _nc_sa_row(r)
    by_label: Dict[tuple, Dict[str, Dict[str, Any]]] = {}
    for r in rows:
        by_label.setdefault((r["dataset"], r["source_label"]), {})[r["nara_head"]] = r
    states: Dict[str, Dict[str, Optional[str]]] = {}
    for (ds, lab), heads in sorted(by_label.items()):
        states.setdefault(ds, {})[lab] = _state(heads, ds, lab)
    c24_ood = sorted(lab for (ds, lab), heads in by_label.items() if ds == "capture24"
                     and heads["posture"].get("willetts_specific_2018") in C24_OOD_GROUPS
                     and _state(heads, ds, lab) not in ("walk", "run"))
    roles = {ds: {"role": r, "licence": lic, "placement": pl, "note": ROLE_NOTES[r]}
             for ds, (r, lic, pl) in ROLES.items()}
    roles["dsads"]["note"] = "CC BY 4.0 but the arm segment of the RA/LA units is not stated; not in the v1 list"
    for ds in NC_SA:
        roles[ds]["note"] = NC_SA_NOTE
    meta = portable(copy.deepcopy(src["datasets"]))
    for ds, note in LOADER_VERIFICATION.items():
        meta[ds]["loader_verification"] = note
    meta["capture24"]["mirror_verification"] = (
        "HF mirror nz00shuuuu verified identical to the ORA release for every complete ORA file (48 participants, "
        "449,565,923 rows; x/y/z within float32 rounding <= 4.8e-7; timestamps and annotations exactly equal; "
        "2026-10-05); Agent C had checked P011, P023, P053, P099, P135")
    meta["capture24"].setdefault("local_paths", {})["canonical_ora_stream"] = C24_ORA_NOTE
    conventions = copy.deepcopy(src["conventions"])
    conventions["window_assignment"]["classification_heads"] = WINDOW_RULE
    return {
        "schema": MAPPINGS_SCHEMA,
        "source": {"path": portable(src_path), "schema": src.get("schema"), "sha256": src_sha256,
                   "author": src.get("author"), "generated": src.get("generated")},
        "head_class_orders": {h: list(v) for h, v in HEAD_CLASS_ORDERS.items()},
        "ontology_source": src.get("ontology_source"),
        "conventions": conventions,
        "dataset_roles": roles,
        "licence_decisions": LICENCE_DECISIONS,
        "datasets": meta,
        "transition_states_rule": (
            "null label -> null; posture recumbent -> lie (Capture-24 '7030 sleeping' -> sleep: diary onset/offset "
            "is not an event); posture seated_likely -> sit; posture upright_stationary with locomotion stationary "
            "-> stand; locomotion containing walking (and not stationary) -> walk; running -> run; else other. "
            "Uses Agent C's audited rows (audit_used_for_training). A change between equal states is not a boundary. (brisk_walking counts as walk.)"),
        "transition_states": states,
        "event_pairs": [{"from": a, "to": b, "events": e} for a, b, e in EVENT_PAIRS],
        "transition_derivation": src["transition_derivation"],
        "transition_policy": COMMON_TRANSITION_POLICY,
        "transition_rules": TRANSITION_RULES,
        "set_families": SET_FAMILIES,
        "set_family_rule": ("support of a family representative counts windows whose target set equals the family; "
                            "an unsupported member is then covered by the representative (manifest 'covers'); a set "
                            "with a member that is neither supported nor covered is MASK"),
        "movement_intensity": src["movement_intensity"],
        "splits_policy": src["splits_policy"],
        "split_manifests": "Tools/ActivityContext/splits/<dataset>.json (nara-split-1, sha256 verified on load)",
        "ood_candidates": src["ood_candidates"],
        "ood_holdout": dict(OOD_HOLDOUT_FIXED, capture24=c24_ood),
        "ood_holdout_rule": ("withheld from every head of the OOD-benchmark bundle only: WISDM kicking/catch/dribbling, "
                             "PAMAP2 soccer/rope jumping, MHEALTH knee bends/jumps, Capture-24 labels whose "
                             f"WillettsSpecific2018 group is one of {list(C24_OOD_GROUPS)} except in-vocabulary gait "
                             "(walking/running labels)"),
        "nara_feedback": src["nara_feedback"],
        "mappings": rows,
    }


def build_file(src_path: str, out_path: str) -> str:
    with open(src_path, "rb") as f:
        data = f.read()
    doc = normalise(json.loads(data), hashlib.sha256(data).hexdigest(), src_path)
    out = (json.dumps(doc, indent=1, ensure_ascii=False, sort_keys=False) + "\n").encode("utf-8")
    with open(out_path, "wb") as f:
        f.write(out)
    return hashlib.sha256(out).hexdigest()


def summarize_states(doc: Dict[str, Any]) -> Dict[str, Dict[str, int]]:
    out: Dict[str, Dict[str, int]] = {}
    for ds, st in doc["transition_states"].items():
        c: Dict[str, int] = {}
        for v in st.values():
            c[str(v)] = c.get(str(v), 0) + 1
        out[ds] = c
    return out


__all__ = ["normalise", "build_file", "summarize_states", "portable", "ROLES", "EVENT_PAIRS", "TRANSITION_RULES",
           "WINDOW_RULE"]


def _labels(doc: Dict[str, Any], ds: str) -> List[str]:
    return sorted({r["source_label"] for r in doc["mappings"] if r["dataset"] == ds})
