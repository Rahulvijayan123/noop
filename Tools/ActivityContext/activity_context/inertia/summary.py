"""``eval/inertia/SUMMARY.md``: one overview across every evaluated experiment (never hides poor classes)."""

from __future__ import annotations

import json
import os
from typing import Any, Dict, List

import numpy as np

from . import HEAD_CLASS_ORDERS
from .experiments import EXPERIMENTS, SHORT
from .integrity import RERUN_REASONS
from .mappings import load_mappings, summary_counts
from .report import (BANNER, DESCRIPTIVE_NOTE, FEW_SUBJECTS_NOTE, LOSO_NOTE, POSTURE_CAVEAT, ci, class_label, f,
                     gate_cell)
from .splits import load_splits, summary as split_summary

# Capture-24 ORA <-> HF mirror verification (G-20f): research/inertia-work/agentFP/c24_verify (verify.py,
# results.json), 2026-10-05. Recorded here because the ORA stream is outside git.
C24_ORA_VERIFICATION = {
    "n_complete_ora_files": 48, "n_verified_identical": 48, "n_failed": 0, "n_rows": 449_565_923,
    "incomplete": ["P008.csv.gz.tmp (0 bytes; the downloader stopped at 17:04 and is not running)"],
    "rule": "row counts equal; ORA time (no zone, read as UTC) == timestamp_ms exactly; x/y/z max |diff| <= 1e-6 "
            "(max observed 4.77e-7: HF stores the float32 of the ORA value); annotations exactly equal, missing "
            "aligned",
    "pids": "P002 P006 P011 P016 P019 P022 P023 P024 P026 P028 P029 P030 P031 P034 P035 P037 P043 P046 P049 P051 "
            "P053 P058 P066 P070 P072 P077 P078 P079 P083 P087 P089 P093 P095 P097 P099 P102 P103 P113 P116 P117 "
            "P118 P123 P127 P129 P130 P134 P135 P150",
}
FIXTURE_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "fixtures", "inertia"))

HEADS = ("posture", "locomotion", "arm_behavior")
PRIMARY = ("primary-hc", "primary-nf", "primary-art")
ARCH = ("linear-hc", "mlp-hc", "linear-art", "mlp-art", "linear-nf")
NCSA_PRIMARY = ("ncsa-primary-hc", "ncsa-primary-nf", "ncsa-primary-art")
NCSA_COMPARE = ("ncsa-lodo-nonc-hc", "ncsa-primary-hc", "ncsa-lodo-nogotov-hc", "ncsa-lodo-nowear-hc")
NCSA_ALL = NCSA_COMPARE + ("ncsa-primary-nf", "ncsa-primary-art")
SPLIT_DATASETS = ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "gotov", "wear")


def _load(eval_dir: str) -> Dict[str, Dict[str, Any]]:
    out = {}
    for name, e in EXPERIMENTS.items():
        p = os.path.join(eval_dir, e.bundle_id, "evaluation.json")
        if os.path.isfile(p):
            with open(p) as fh:
                out[name] = json.load(fh)
    return out


def _head(rep, h):
    return (rep or {}).get("heads", {}).get(h)


def _headline(R, names) -> List[str]:
    L = ["| experiment | head | n | macro-F1 [95% CI] | macro-F1 present-only (legacy) | balanced acc [95% CI] | NLL | "
         "Brier | ECE-15 | majority macro-F1 | predicted while absent |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for n in names:
        for h in HEADS:
            r = _head(R.get(n), h)
            if not r:
                continue
            p, b = r["pooled"], r["bootstrap_ci"]
            legacy = ci(b["macro_f1_present_supported"]) if "macro_f1_present_supported" in b else f(p.get("macro_f1_present_supported"))
            L.append(f"| {n} | {h} | {f(p['n'])} | {ci(b['macro_f1'])} | {legacy} | {ci(b['balanced_accuracy'])} | "
                     f"{f(p['nll'])} | {f(p['brier'])} | {f(p['ece_top_equal_width_15'])} | "
                     f"{f(r['majority_baseline']['macro_f1'])} | {', '.join(p.get('predicted_absent_classes') or []) or '–'} |")
    return L + ["", "macro-F1 = sklearn convention (union of true and predicted classes); 'present-only' = the earlier "
                "number over classes with test support only. " + FEW_SUBJECTS_NOTE, ""]


def _per_class(R, names, h) -> List[str]:
    L = [f"#### {h}", ""] + ([POSTURE_CAVEAT, ""] if h == "posture" else [])
    L += ["| class | " + " | ".join(f"{n} F1 (P/R)" for n in names) + " | primary-hc P single-label (n) | test support | "
          "status val→final (primary-hc) | demotion reasons |", "|---|" + "---|" * (len(names) + 4)]
    for c in HEAD_CLASS_ORDERS[h]:
        cells, sup = [], "–"
        for n in names:
            r = _head(R.get(n), h)
            if not r:
                cells.append("–")
                continue
            pc = r["pooled"]["per_class"][c]
            sup = f(pc["support"])
            cells.append(f"{f(pc['f1'], 2)} ({f(pc['precision'], 2)}/{f(pc['recall'], 2)})" if pc["supported_by_head"]
                         else "unsupported")
        ph = _head(R.get("primary-hc"), h) or {}
        g = ph.get("gate", {}).get(c, {})
        sl = (ph.get("single_label") or {}).get("per_class", {}).get(c)
        single = f"{f(sl['precision'], 2)} ({f(sl['support'])})" if sl else "–"
        L.append(f"| {class_label(h, c)} | " + " | ".join(cells) + f" | {single} | {sup} | "
                 f"{g.get('val_status', 'unsupported')}→{g.get('final_status', '–')} | {'; '.join(g.get('reasons', [])) or '–'} |")
    return L + [""]


def _per_dataset_classes(R, n, h) -> List[str]:
    """G-5: per-dataset per-class P/R/F1 (support) and the dataset gate at the frozen tau, for one bundle."""
    r = _head(R.get(n), h)
    if not r:
        return []
    ds = [d for d, v in r["per_dataset"].items() if v.get("n")]
    L = [f"#### {n} — {h}", "", "| class | " + " | ".join(
        f"{d} ({r['per_dataset'][d].get('n_test_subjects', '?')} subj{', descriptive' if r['per_dataset'][d].get('descriptive_only') else ''})"
        for d in ds) + " | final |", "|---|" + "---|" * (len(ds) + 1)]
    for c in HEAD_CLASS_ORDERS[h]:
        g = r["gate"].get(c, {})
        cells, any_sup = [], False
        for d in ds:
            v = r["per_dataset"][d]["per_class"][c]
            if not v["supported_by_head"]:
                cells.append("unsupported")
                continue
            any_sup = True
            cell = f"{f(v['precision'], 2)}/{f(v['recall'], 2)}/{f(v['f1'], 2)} ({v['support']})"
            gd = (g.get("per_dataset") or {}).get(d)
            if gd and gd.get("n_acc"):
                cell += f" · gate {f(gd.get('precision'), 2)}@{gd['n_acc']}→{gd['level']}"
            cells.append(cell)
        if any_sup:
            L.append(f"| {class_label(h, c)} | " + " | ".join(cells) + f" | {g.get('val_status', '–')}→{g.get('final_status', '–')} |")
    L += ["", "| dataset | " + " | ".join(ds) + " |", "|---|" + "---|" * len(ds),
          "| macro-F1 [95% CI] | " + " | ".join(ci(r["per_dataset"][d].get("bootstrap_macro_f1")) for d in ds) + " |"]
    return L + [""]


def _awake_lying(R, names) -> List[str]:
    L = ["| experiment | recumbent truth | sleep-period share | awake-lying truth (by dataset) | recumbent P/R/F1 on non-sleep "
         "windows | awake-lying gate (pooled) | awake-lying status |", "|---|---|---|---|---|---|---|"]
    for n in names:
        aw = (_head(R.get(n), "posture") or {}).get("awake_lying")
        if not aw:
            continue
        pc, g = aw.get("per_class_recumbent") or {}, aw.get("gate") or {}
        by = ", ".join(f"{d} {k}" for d, k in (aw.get("by_dataset_awake_lying_truth") or {}).items() if k)
        L.append(f"| {n} | {f(aw.get('n_recumbent_truth_windows'))} | {f(aw.get('sleep_period_fraction_of_recumbent_truth'))} | "
                 f"{f(aw.get('n_awake_lying_truth'))} ({by or '–'}) | {f(pc.get('precision'), 2)}/{f(pc.get('recall'), 2)}/"
                 f"{f(pc.get('f1'), 2)} | {gate_cell(g.get('test') or {})} | {g.get('final_status', '–')} |")
    return L + ["", "The awake-lying gate is reported only: the served `recumbent` status is the pooled gate's, and the "
                "class must be read as 'recumbent (mostly sleep-period lying in training data)'.", ""]


def _calibration(R, names) -> List[str]:
    L = ["| experiment | head | method | NLL raw→cal | Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal |",
         "|---|---|---|---|---|---|---|"]
    for n in names:
        rep = R.get(n)
        for h in HEADS:
            r = _head(rep, h)
            if not r:
                continue
            u, p = r["uncalibrated_softmax"], r["pooled"]
            L.append(f"| {n} | {h} | {rep.get('calibration_methods', {}).get(h, '')} | {f(u['nll'])}→{f(p['nll'])} | "
                     f"{f(u['brier'])}→{f(p['brier'])} | {f(u['ece_top_equal_width_15'])}→{f(p['ece_top_equal_width_15'])} "
                     f"({f(p['ece_top_equal_width_15_null']['null_p95'])}) | {f(u['classwise_ece_equal_width_15'])}→"
                     f"{f(p['classwise_ece_equal_width_15'])} |")
    return L + [""]


def _transition(R, names) -> List[str]:
    L = ["| experiment | event | supported | AUROC | AP | Brier | ECE | F1 ±5 s | F1 ±10 s | median/p90 abs err (s) | status val→final |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for n in names:
        r = _head(R.get(n), "transition")
        if not r:
            continue
        for e, v in r["per_event"].items():
            if not v.get("supported"):
                continue
            ev = r["event_level"].get(e, {}) if isinstance(r["event_level"], dict) else {}
            a, b = ev.get("tol_5s", {}), ev.get("tol_10s", {})
            L.append(f"| {n} | {e} | yes | {f(v['auroc'])} | {f(v['average_precision'])} | {f(v['brier'])} | {f(v['ece_15'])} | "
                     f"{f(a.get('f1'), 2)} | {f(b.get('f1'), 2)} | {f(b.get('abs_err_median_s'), 1)}/{f(b.get('abs_err_p90_s'), 1)} | "
                     f"{v['gate']['val_status']}→{v['gate']['final_status']} |")
    return L + [""]


def _intensity(R, names) -> List[str]:
    L = ["| experiment | set | n | MAE | MAE const | R² | Spearman | 80% coverage |", "|---|---|---|---|---|---|---|---|"]
    for n in names:
        r = _head(R.get(n), "movement_intensity")
        if not r:
            continue
        for s, v in [("pooled", r["pooled"])] + list(r["per_dataset"].items()):
            L.append(f"| {n} | {s} | {f(v.get('n'))} | {f(v.get('mae'))} | {f(v.get('mae_constant_test_mean'))} | {f(v.get('r2'))} | "
                     f"{f(v.get('spearman'))} | {f(v.get('interval80_coverage'))} |")
    return L + [""]


def _ood(R, names=("ood-hc", "ood-nf", "ood-art", "lodo-nohhar-hc"), selected=None) -> List[str]:
    L = ["| bundle | OOD set | method | AUROC | AUPRC (prev.) | FPR@95 OOD+ | ID false alarm @op | OOD detect @op |",
         "|---|---|---|---|---|---|---|---|"]
    for n in names:
        o = (R.get(n) or {}).get("ood", {})
        for s, rows in o.get("benchmark", {}).items():
            for m, v in rows.items():
                if m.startswith("combined"):
                    continue
                L.append(f"| {n} | {s} | {m}{' (bundle)' if m.split('@')[0] == o['bundle_method'] and (o.get('k') is None or m.endswith(str(o.get('k')))) else ''} | "
                         f"{f(v['auroc'])} | {f(v['auprc_ood_positive'])} ({f(v['ood_prevalence'], 2)}) | {f(v['fpr95_ood_positive'])} | "
                         f"{f(v['id_false_alarm_at_op'])} | {f(v['ood_detect_rate_at_op'])} |")
    L += ["", "| bundle | method (VAL-selected) | threshold | ID test false-alarm rate |", "|---|---|---|---|"]
    for n, rep in R.items():
        if selected is not None and n not in selected:
            continue
        o = rep.get("ood", {})
        L.append(f"| {n} | {o.get('bundle_method')}{'@' + str(o['k']) if o.get('k') else ''} | {f(o.get('threshold'))} | "
                 f"{f(o.get('id_test_false_alarm_rate'))} |")
    return L + [""]


def _per_dataset_f1(R, names, h) -> List[str]:
    ds = sorted({d for n in names for d in ((_head(R.get(n), h) or {}).get("per_dataset") or {})})
    desc = {d for n in names for d, v in ((_head(R.get(n), h) or {}).get("per_dataset") or {}).items()
            if v.get("descriptive_only")}
    L = [f"| {h} macro-F1 by test dataset | " + " | ".join(d + (" (descriptive)" if d in desc else "") for d in ds) + " |",
         "|---|" + "---|" * len(ds)]
    for n in names:
        r = _head(R.get(n), h)
        if not r:
            continue
        cells = [f(r["per_dataset"].get(d, {}).get("macro_f1", r["per_dataset"].get(d, {}).get("macro_f1_present_supported")))
                 for d in ds]
        L.append(f"| {n} | " + " | ".join(cells) + " |")
    return L + [""]


def _seeds(R) -> List[str]:
    L = ["| head | seed 0 | seed 1 | seed 2 | mean ± sd |", "|---|---|---|---|---|"]
    for h in HEADS:
        v = [(_head(R.get(n), h) or {}).get("pooled", {}).get("macro_f1") for n in ("primary-hc", "seed1-hc", "seed2-hc")]
        ok = [x for x in v if x is not None]
        L.append(f"| {h} | " + " | ".join(f(x) for x in v) + (f" | {np.mean(ok):.3f} ± {np.std(ok, ddof=1):.3f} |" if len(ok) > 1 else " | – |"))
    return L + [""]


def _windows_table() -> List[str]:
    from .cache import CACHE_ROOT, read_manifest
    L = ["| dataset | spec | window/hop (s) | train | val | test | ood | subjects | loader |", "|---|---|---|---|---|---|---|---|---|"]
    for ds in ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "daphnet_fog", "gotov",
               "wear"):
        for spec in ("w30", "w30t", "w10"):
            try:
                m = read_manifest(CACHE_ROOT, spec, ds)
            except Exception:  # noqa: BLE001
                continue
            if not m["n_windows"]:
                continue
            b = m["n_by_split"]
            L.append(f"| {ds} | {spec} | {m['window_s']}/{m['hop_s']:g} | {f(b.get('train'))} | {f(b.get('val'))} | "
                     f"{f(b.get('test'))} | {f(b.get('ood'))} | {m['n_subjects']} | {m['loader_version']} |")
    return L + ["", "`w30t` = dense 2-s-hop transition windows (Opportunity/PAMAP2/HHAR whole recordings; Capture-24 only "
                "windows containing an eligible <= 28-s gap event); class heads never train on them.", ""]


def _ledger(eval_dir: str, name: str = "test_ledger.jsonl") -> List[str]:
    p = os.path.join(eval_dir, name)
    if not os.path.isfile(p):
        return ["(no ledger)"]
    rows = [json.loads(x) for x in open(p) if x.strip()]
    L = ["| # | experiment | bundle sha256 | test split sha256 | n evals (this split) | rerun reason | detail |",
         "|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1):
        code = r.get("rerun_reason")
        if code and code not in RERUN_REASONS:
            code, detail = "legacy free text (pre-enumeration)", code
        else:
            detail = r.get("rerun_detail") or ""
        L.append(f"| {i} | {r['experiment']} | `{r['bundle_sha256'][:16]}` | `{r['test_sha256'][:12]}` | "
                 f"{r['n_test_evaluations']} | {code or ''} | {str(detail).replace('|', '/')} |")
    legacy = "legacy free text (pre-enumeration)"
    legacy_text = ("the run-1 bundle directory was deleted by an external process; the bundles were retrained "
                   "deterministically and re-evaluated: every metric identical to run 1 at tolerance 1e-9; only bundle "
                   "hashes differ (the manifest records creation time)")
    groups: Dict[str, int] = {}
    for r in rows:
        code = r.get("rerun_reason")
        if code:
            key = code if code in RERUN_REASONS else legacy
            groups[key] = groups.get(key, 0) + 1
    if groups:
        parts = [f"{k}: {v} ({RERUN_REASONS.get(k, legacy_text)})" for k, v in sorted(groups.items())]
        L += ["", "Re-evaluations by reason: " + "; ".join(parts) + "."]
    return L


def _disclosures() -> List[str]:
    return ["## Disclosures (test-set exposure and evaluator changes)", "",
            "- **WISDM / PAMAP2 test numbers are not fully pristine (G-8).** Prototyping in `research/inertia-work/agentD` "
            "loaded WISDM-2019 and PAMAP2 subjects that are in the frozen TEST split and printed test-subject deltas next "
            "to the validation numbers while the head grid and the arch-selection rule were being chosen; the final "
            "`train_heads` GRID and RULE equal the prototype's. No threshold, calibration or status was fit on test, "
            "but the procedure was designed with test feedback visible, so read WISDM and PAMAP2 test results as "
            "optimistic. The prototype scripts (`proto_*.py`, `run_proto.py`, `run_lodo.py`, `select_rule.py`) load only "
            "WISDM and PAMAP2; they contain no Capture-24, HHAR, MHEALTH or Opportunity code path.",
            "- **Evaluator diagnostic changed between runs (G-17).** Run 1 recorded `apply_vs_apply_arrays_max_abs` "
            "(bundle.apply vs bundle.apply_arrays); run 2 records `apply_vs_training_side_max_abs` (bundle.apply vs "
            "the training-side numpy path). Every metric of the 14 re-evaluated experiments was identical between "
            "the runs; only that diagnostic field changed.",
            "- **Rule changes after the audit.** The strong/weak VAL rule (subject-cluster bootstrap, >= 5 subjects), "
            "the test gate (weak -> abstain, per-dataset demotion), the merge table and the macro-F1 convention were "
            "changed after a red-team audit that had seen these test results; evaluations made with the new rules "
            "are recorded as `post_audit_rule_change` re-evaluations and are not pristine either.", ""]


def _c24_verification() -> List[str]:
    v = C24_ORA_VERIFICATION
    return ["## Capture-24 source verification", "",
            f"Training uses the HuggingFace parquet mirror (`hf_mirror_nz00shuuuu`, 151 participants). Every participant "
            f"downloaded from the Oxford ORA release so far was compared with it: **{v['n_verified_identical']} of "
            f"{v['n_complete_ora_files']} complete ORA files identical** ({v['n_rows']:,} rows; {v['n_failed']} failures; "
            f"rule: {v['rule']}). Incomplete: {', '.join(v['incomplete'])}. The remaining {151 - v['n_complete_ora_files']} "
            "participants are verified only through the mirror's own SHA256SUMS. Verified: " + v["pids"] + ".", ""]


def _fixture_section() -> List[str]:
    """Spec §13.3 #6: Nara/WHOOP fixture behaviour (what the golden fixture exercises; no labelled WHOOP data)."""
    L = ["## Nara/WHOOP fixture behaviour", ""]
    try:
        with open(os.path.join(FIXTURE_DIR, "golden_motion_heads_request.json")) as fh:
            req = json.load(fh)
        with open(os.path.join(FIXTURE_DIR, "golden_motion_heads_response.json")) as fh:
            resp = json.load(fh)
    except (OSError, ValueError):
        return L + ["(golden fixture not found)", ""]
    run = req["run"]
    heads = sorted(resp["bundle"]["heads"])
    L += [f"There is **no labelled WHOOP data**: nothing above is a WHOOP accuracy result. What the WHOOP path is "
          f"tested with is a synthetic, deterministic golden fixture (`fixtures/inertia/`, regenerated by "
          f"`python -m activity_context.inertia.make_golden`, checked by `make_golden --check` and "
          f"`tests/inertia/test_inertia_golden.py`):", "",
          f"- input: one WHOOP-format infer request — {len(run.get('head_b64') or [])} s head + {run['end_ts'] - run['start_ts']} s body + "
          f"{len(run.get('tail_b64') or [])} s tail of NPB1 int16 columns at 100 Hz, 4096 LSB/g (still, seated-like tilt "
          f"with sway, 1.8 Hz gait), hop {run.get('hop_s')} s;",
          "- path: `inertia-prep-1` (accel only, g, 10 Hz Butterworth filtfilt, resample_poly 1/5 -> 20 Hz, 30 s windows) "
          f"-> the stand-in encoder `{resp['encoder_id']}` (seeded random init, NOT Inertia-1) -> a fixed-weight shadow "
          f"bundle (`bundle_tiny`, every calibration method, covers, merge_into, MLP + linear heads, kNN OOD) -> the "
          f"`motion-heads-1` response: {len(resp['windows'])} windows, heads {', '.join(heads)}, tier "
          f"`{resp['evidence_tier_max']}`, encoder_kind `{resp['encoder_kind']}`;",
          "- serve: the same response is reproduced in-process and through the `python -m activity_context.inertia.serve "
          "--allow-standin-shadow` subprocess (byte-for-byte on every field but duration_ms); without the flag it is refused;",
          "- Swift: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/MotionHeadsContractTests.swift` decodes the same "
          "golden response (`MotionHeadsResponse.decode`), checks the class orders / wire keys, and pushes it through "
          "the track builder (every window attaches to an observed second in [e, e+2]).",
          "", "What it does NOT exercise: real Inertia-1 weights (none are public), WHOOP-specific signal statistics, any "
          "accuracy on WHOOP data, or candidate-mode evidence on a real night (stand-ins are refused as evidence).", ""]
    return L


NCSA_CAVEATS = [
    "**GOTOV is older adults** (35 participants, 59.5-81.3 y, BMI 23-35, recruited > 60 y) in a scripted protocol: its "
    "walking speeds are **instructed** ('slow / medium / fast pace'), never measured, so `brisk_walking` here means "
    "'an older adult asked to walk fast' — not a cadence or speed threshold, and not validated on younger or free-living "
    "walkers. Outdoor walking exists for 22 participants only; the frozen split leaves **one** GOTOV test participant "
    "with walking (GOTOV07: 19 `brisk_walking` and 33 `walking` test windows), so every GOTOV walking / brisk_walking / "
    "cycling test number is a one-subject, descriptive result and the test gate cannot demote with < 30 accepted windows.",
    "GOTOV labels are protocol-imputed (researcher-recorded start/end): the first/last 10 s of every activity are MASK "
    "(`gotov-guard-10s`), and transitions give interior negatives only. Its movement_intensity target is the **measured** "
    "COSMED K4b2 METS (time-weighted per window; the first 60 s of each activity MASK for VO2 on-kinetics; 4 of 35 "
    "participants have no COSMED) — whole-body energy expenditure of older adults, not wrist motion.",
    "WEAR is 24 (mostly young) adults doing 18 outdoor workouts on a Bangle.js; **one wrist per subject** (left unless "
    "< 95 % finite) so no movement is counted twice. `exercise_motion` is supervised only by WEAR push-ups (+complex), "
    "burpees, bench-dips and jogging with arm circles (sit-ups / lunges stay MASK: 'arms may be static').",
    "Both sets are **CC BY-NC-SA 4.0**: every `ncsa-*` bundle except `ncsa-lodo-nonc-hc` records "
    "`training_data_licences` = [CC BY 4.0, CC BY-NC-SA 4.0] and may only be used non-commercially (Nara is "
    "non-commercial; owner decision 2026-10-06). Bundles stay outside git.",
    "The `ncsa-*` test split = the six CC BY test splits + the GOTOV (7) and WEAR (5) test subjects, so its pooled numbers "
    "are not comparable with the sealed `primary-*` bundles above; compare `ncsa-primary-hc` with `ncsa-lodo-nonc-hc` "
    "(same test windows, same archs and OOD method, CC BY data only). WISDM / PAMAP2 test caveats (G-8) apply unchanged.",
]


def _ncsa_mapping_table(cw) -> List[str]:
    L = ["| dataset | head | trained rows (source label → target, confidence) |", "|---|---|---|"]
    for ds in ("gotov", "wear"):
        for h in ("posture", "locomotion", "arm_behavior", "transition", "movement_intensity"):
            rows = [r for r in cw.doc["mappings"] if r["dataset"] == ds and r["nara_head"] == h and r["used_for_training"]]
            if not rows:
                continue

            def tgt(r):
                t = r["nara_target"]
                return ("measured MET" if isinstance(t, dict) else "{" + ", ".join(t) + "}" if isinstance(t, list) else str(t))
            cells = "; ".join(f"{r['source_label']} → {tgt(r)} ({r['mapping_confidence'][0].upper()})" for r in rows)
            L.append(f"| {ds} | {h} | {cells} |")
    left = [f"{r['dataset']}/{r['source_label']}/{r['nara_head']} ({r['mapping_confidence']})" for r in cw.doc["mappings"]
            if r["dataset"] in ("gotov", "wear") and not r["used_for_training"] and r["target_type"] != "mask"]
    return L + ["", "Not trained (Agent C left them unused: low confidence or candidate): " + "; ".join(left) + ".", ""]


def _compare_classes(R, names, h) -> List[str]:
    L = [f"#### {h}", "", "| class | test support | " + " | ".join(f"{n} F1 (P/R) · val→final" for n in names) +
         " | ncsa-primary-hc P single-label (n) | ncsa-primary-hc demotion reasons |", "|---|---|" + "---|" * (len(names) + 2)]
    for c in HEAD_CLASS_ORDERS[h]:
        cells, sup = [], "–"
        for n in names:
            r = _head(R.get(n), h)
            if not r:
                cells.append("–")
                continue
            pc = r["pooled"]["per_class"][c]
            sup = f(pc["support"])
            if not pc["supported_by_head"]:
                cells.append("unsupported")
                continue
            g = r.get("gate", {}).get(c, {})
            cells.append(f"{f(pc['f1'], 2)} ({f(pc['precision'], 2)}/{f(pc['recall'], 2)}) · "
                         f"{g.get('val_status', '–')}→{g.get('final_status', '–')}")
        ph = _head(R.get("ncsa-primary-hc"), h) or {}
        sl = (ph.get("single_label") or {}).get("per_class", {}).get(c)
        single = f"{f(sl['precision'], 2)} ({f(sl['support'])})" if sl else "–"
        reasons = "; ".join(ph.get("gate", {}).get(c, {}).get("reasons", [])) or "–"
        L.append(f"| {class_label(h, c)} | {sup} | " + " | ".join(cells) + f" | {single} | {reasons} |")
    return L + [""]


FOCUS = (("gotov", "locomotion", ("stationary", "walking", "brisk_walking", "cycling", "other")),
         ("gotov", "posture", ("recumbent", "seated_likely", "upright_stationary")),
         ("gotov", "arm_behavior", ("desk_like",)),
         ("wear", "locomotion", ("stationary", "running", "other")),
         ("wear", "arm_behavior", ("exercise_motion",)))


def _focus(R, names) -> List[str]:
    L = ["| test dataset | head | class | " + " | ".join(f"{n} P/R/F1 (n)" for n in names) + " |",
         "|---|---|---|" + "---|" * len(names)]
    for ds, h, classes in FOCUS:
        for c in classes:
            cells = []
            for n in names:
                v = ((_head(R.get(n), h) or {}).get("per_dataset", {}).get(ds) or {}).get("per_class", {}).get(c)
                if not v:
                    cells.append("–")
                elif not v["supported_by_head"]:
                    cells.append(f"unsupported ({v.get('support', 0)})")
                else:
                    cells.append(f"{f(v['precision'], 2)}/{f(v['recall'], 2)}/{f(v['f1'], 2)} ({v['support']})")
            L.append(f"| {ds} | {h} | {class_label(h, c)} | " + " | ".join(cells) + " |")
    return L + [""]


def _intensity_dataset(R, names, ds) -> List[str]:
    L = ["| experiment | trained on GOTOV | n | MAE | MAE const (test mean) | R² | Spearman | 80% coverage |",
         "|---|---|---|---|---|---|---|---|"]
    for n in names:
        r = _head(R.get(n), "movement_intensity")
        if not r:
            continue
        v = r["per_dataset"].get(ds, {})
        tr = ds in EXPERIMENTS[n].train_datasets
        L.append(f"| {n} | {'yes' if tr else 'no'} | {f(v.get('n'))} | {f(v.get('mae'))} | {f(v.get('mae_constant_test_mean'))} | "
                 f"{f(v.get('r2'))} | {f(v.get('spearman'))} | {f(v.get('interval80_coverage'))} |")
    return L + [""]


def _ncsa_section(R, cw) -> List[str]:
    L = ["## With vs without NC-SA data (GOTOV + WEAR, CC BY-NC-SA 4.0; licence decision 2026-10-06)", "",
         "The owner approved non-commercial use of GOTOV and WEAR on 2026-10-06; sets with no stated licence "
         "(ExtraSensory, RealWorld 2016, UT complex, UCI HMP) stay excluded. The `ncsa-*` experiments were declared in "
         "`experiments.py` before any of their test splits was opened, trained from a clean commit and evaluated once "
         "(sealed) like every other bundle. `ncsa-lodo-nonc-hc` = **without** NC-SA data (six CC BY sets; archs and OOD "
         "method fixed from `ncsa-primary-hc` / `ncsa-ood-hc`); `ncsa-primary-hc` = **with**; `ncsa-lodo-nogotov-hc` / "
         "`ncsa-lodo-nowear-hc` leave one NC-SA set out.", "", "### Caveats", ""]
    L += [f"- {c}" for c in NCSA_CAVEATS] + ["", "### Crosswalk rows trained since 2026-10-06", ""] + _ncsa_mapping_table(cw)
    L += ["### Headline (pooled ncsa test split)", ""] + _headline(R, NCSA_ALL)
    L += ["### Per-class test P/R/F1 and final status — without vs with", "",
          "Pooled over the eight-set test split. `unsupported` = the class failed the train-support rule in that bundle "
          "(< 200 train windows / 5 train subjects / 2 val subjects); a set target {walking, brisk_walking} counts as "
          "correct for either member.", ""]
    for h in HEADS:
        L += _compare_classes(R, NCSA_COMPARE, h)
    L += ["### GOTOV / WEAR test subjects (key classes)", "", DESCRIPTIVE_NOTE + " GOTOV walking / brisk_walking / cycling "
          "test windows all come from ONE participant (GOTOV07).", ""] + _focus(R, NCSA_COMPARE + ("ncsa-primary-nf",))
    L += ["### Per-dataset macro-F1 (ncsa test split)", "", DESCRIPTIVE_NOTE, ""]
    for h in HEADS:
        L += _per_dataset_f1(R, list(NCSA_ALL), h)
    L += ["### Per-dataset per-class test P/R/F1 — ncsa-primary-hc and ncsa-lodo-nonc-hc", "", DESCRIPTIVE_NOTE,
          FEW_SUBJECTS_NOTE, ""]
    for n in ("ncsa-primary-hc", "ncsa-lodo-nonc-hc"):
        for h in HEADS:
            L += _per_dataset_classes(R, n, h)
    L += ["### Movement intensity on GOTOV (measured COSMED MET)", "",
          "Target `clip(ln MET / ln 12, 0, 1)` of the window's measured METS (7 GOTOV test participants, those with "
          "COSMED); `MAE const` = predicting the GOTOV test mean (an oracle constant; R² is relative to it).", ""]
    L += _intensity_dataset(R, NCSA_ALL, "gotov")
    L += ["All movement-intensity sets:", ""] + _intensity(R, NCSA_ALL)
    L += ["### Awake lying (GOTOV lying is awake by protocol)", ""] + _awake_lying(R, NCSA_ALL)
    L += ["### Transition events (ncsa)", ""] + _transition(R, NCSA_COMPARE)
    L += ["### Calibration (ncsa primaries)", ""] + _calibration(R, NCSA_PRIMARY + ("ncsa-lodo-nonc-hc",))
    L += ["### OOD (ncsa)", "", "`heldout_dataset_<set>_test` = the left-out NC-SA set's test windows scored as "
          "out-of-distribution by the LODO bundle that never saw it.", ""]
    L += _ood(R, ("ncsa-ood-hc", "ncsa-ood-nf", "ncsa-ood-art", "ncsa-lodo-nogotov-hc", "ncsa-lodo-nowear-hc"),
              selected=set(n for n in R if n.startswith("ncsa-")))
    return L


def build_summary(eval_dir: str, bundles_root: str) -> str:
    R = _load(eval_dir)
    for n, rep in R.items():
        cal = os.path.join(bundles_root, EXPERIMENTS[n].bundle_id, "calibration.json")
        if os.path.isfile(cal):
            with open(cal) as fh:
                rep["calibration_methods"] = {h: c["method"] for h, c in json.load(fh)["heads"].items()}
    cw = load_mappings()
    L = ["# Inertia-1 heads — evaluation summary", "", BANNER, "",
         "Status: real Inertia-1 evaluation **BLOCKED** (no public checkpoint; `pipeline_cli embed --encoder "
         "inertia-1/ar_transformer-small/30s@20hz` fails with `model_missing: blocked: no checkpoint`). The bundles below "
         "use stand-in encoders (`standin:handcrafted-stats-v1` = engineered baseline, `standin:nara-imu-feat-1-accel` = what "
         "the decoder already sees, `standin:inertia-arch-random-init/ar_transformer-small/seed0` = negative control). "
         "All are `evidence_tier_max = shadow`.", "", "## Experiments", "",
         "| experiment | role | encoder | window | training datasets | training data licences | bundle | evaluated sha256 | "
         "sealed sha256 | git commit | evaluated |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for n, e in EXPERIMENTS.items():
        rep = R.get(n)
        seal = (rep or {}).get("seal") or {}
        prov = (rep or {}).get("provenance") or {}
        lic = ", ".join(sorted({cw.doc["dataset_roles"][d]["licence"] for d in e.train_datasets}))
        L.append(f"| {n} | {e.role} | {SHORT.get(e.encoder, e.encoder)} | {e.window} | {', '.join(e.train_datasets)} | {lic} | "
                 f"`{e.bundle_id}` | `{(rep or {}).get('bundle_sha256', '')[:16]}` | `{str(seal.get('sealed_bundle_sha256', '–'))[:16]}` | "
                 f"`{str(prov.get('git_commit') or '–')[:12]}`{' (dirty)' if prov.get('source_dirty') else ''} | "
                 f"{'yes (n=' + str(rep['integrity']['n_test_evaluations']) + ')' if rep else ('blocked' if e.encoder.startswith('inertia-1/') else 'no')} |")
    L += ["", "Every evaluated bundle is SEALED: `test_gate.json` (per class val status, pooled + per-dataset test gates, "
          "final status, recomputed merges) is listed in the bundle's manifest, so the served artifact carries the "
          "one-shot gate; `load_bundle` refuses a gate that promotes or was made for another bundle.", "",
          "## Headline (pooled test, subject-cluster bootstrap 95% CI)", ""] + _headline(R, PRIMARY + ARCH + ("w10-hc",))
    L += ["## Per-class test F1 (precision/recall) — primary bundles", "",
          "Final status = min(VAL status, pooled test gate, every wrist dataset with >= 30 accepted windows): strong needs "
          "precision >= .95 (pooled also CP95 >= .90, recall >= .05), weak needs precision >= .80; demotions only. "
          "P single-label = precision on windows whose truth is exactly one class.", ""]
    for h in HEADS:
        L += _per_class(R, list(PRIMARY) + ["linear-hc", "mlp-hc"], h)
    L += ["## Per-dataset per-class test P/R/F1 — primary bundles", "", DESCRIPTIVE_NOTE, FEW_SUBJECTS_NOTE, ""]
    for n in PRIMARY:
        for h in HEADS:
            L += _per_dataset_classes(R, n, h)
    L += ["## Awake lying (recumbent outside sleep periods)", ""] + _awake_lying(R, PRIMARY)
    L += ["## Calibration (test; fit on val only)", ""] + _calibration(R, PRIMARY)
    L += ["## Transition events", ""] + _transition(R, PRIMARY)
    L += ["## Movement intensity", ""] + _intensity(R, PRIMARY)
    L += ["## OOD", ""] + _ood(R, selected=set(n for n in R if not n.startswith("ncsa-")))
    L += ["## Ablations", "", "### 10 s vs 30 s windows (stand-in hc, class heads)", ""] + _headline(R, ("primary-hc", "w10-hc"))
    L += ["### Linear vs MLP (forced, test)", ""] + _headline(R, ("linear-hc", "mlp-hc", "linear-art", "mlp-art"))
    L += ["### Leave-one-dataset-out transfer (hc)", "", DESCRIPTIVE_NOTE, ""]
    for h in HEADS:
        L += _per_dataset_f1(R, ["primary-hc", "lodo-noc24-hc", "lodo-c24only-hc", "lodo-nohhar-hc"], h)
    L += ["### Seed variation (primary hc procedure, archs fixed from seed 0)", ""] + _seeds(R)
    if any(n.startswith("ncsa-") for n in R):
        L += _ncsa_section(R, cw)
    sp = load_splits(list(SPLIT_DATASETS))
    L += ["## Split manifests (subject-level, frozen before windowing)", "", "| dataset | train | val | test | LOSO folds | sha256 |",
          "|---|---|---|---|---|---|"]
    L += [f"| {s['dataset']} | {s['train']} | {s['val']} | {s['test']} | {s['loso_folds']} | `{s['sha256']}` |" for s in split_summary(sp)]
    L += ["", LOSO_NOTE]
    L += ["", "## Windows (cached, outside git)", ""] + _windows_table()
    L += ["## Dataset / label-mapping summary", "", f"`label_mappings.json` sha256 `{cw.sha256}`; full table: "
          "`eval/inertia/label_mappings.md`.", "", "| dataset | role | labels | rows | used rows posture/locomotion/arm/transition/intensity |",
          "|---|---|---|---|---|"]
    for s in summary_counts(cw):
        u = s["used_rows"]
        L.append(f"| {s['dataset']} | {s['role']} | {s['n_labels']} | {s['n_rows']} | {u['posture']}/{u['locomotion']}/"
                 f"{u['arm_behavior']}/{u['transition']}/{u['movement_intensity']} |")
    L += [""] + _c24_verification()
    L += ["## Test-split ledger (evaluate-once integrity)", "",
          "The test split is assembled only inside the TestVault; a re-evaluation needs an enumerated reason ("
          + ", ".join(f"`{k}`" for k in sorted(RERUN_REASONS)) + ") plus free-text detail.", ""] + _ledger(eval_dir)
    if os.path.isfile(os.path.join(eval_dir, "replay_test_ledger.jsonl")):
        L += ["", "### Decoder-replay TEST ledger (replay_eval final/baseline)", ""] + _ledger(eval_dir, "replay_test_ledger.jsonl")
    L += [""] + _disclosures() + _fixture_section()
    L += ["", "## Measured vs inferred vs blocked", "",
          "- **Measured**: every test number above (stand-in encoders, public wrist datasets, frozen subject splits, "
          "evaluated once through `load_bundle().apply()`).",
          "- **Inferred**: how a real Inertia-1 embedding would compare — nothing here measures it. Relative ordering of "
          "stand-ins indicates what the heads/calibration/OOD machinery does with informative vs uninformative embeddings.",
          "- **Hypothesis**: posture (seated vs standing) from a wrist is inferred probabilistically from behaviour, not observed.",
          "- **Blocked**: real Inertia-1 (`primary-inertia1`), its system-level decoder comparison and any production promotion.", ""]
    path = os.path.join(eval_dir, "SUMMARY.md")
    with open(path, "w") as fh:
        fh.write("\n".join(L) + "\n")
    return path


__all__ = ["build_summary"]
