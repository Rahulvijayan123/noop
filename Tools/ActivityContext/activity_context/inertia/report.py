"""Markdown/JSON report writers: per-bundle ``evaluation.{json,md}`` (render of the evaluate-once report)."""

from __future__ import annotations

import json
import math
import os
from typing import Any, Dict, List

from . import HEAD_CLASS_ORDERS

BANNER = ("> **STAND-IN ENCODERS — NOT INERTIA-1; real Inertia-1 evaluation blocked: no public checkpoint.** "
          "Every number below is a *measured* result for a stand-in encoder on public wrist data; nothing here is "
          "evidence about Inertia-1 itself.")


def f(x: Any, nd: int = 3) -> str:
    if x is None or (isinstance(x, float) and not math.isfinite(x)):
        return "–"
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, (int,)) and not isinstance(x, bool):
        return f"{x:,}"
    return f"{x:.{nd}f}"


FEW_SUBJECTS_MARK = "†"
FEW_SUBJECTS_NOTE = (f"{FEW_SUBJECTS_MARK} = subject-cluster bootstrap over fewer than 10 subjects: the percentile CI "
                     "under-covers (bootstrap.cluster_bootstrap warning); read it as descriptive.")
DESCRIPTIVE_NOTE = ("*descriptive* = a dataset with <= 2 test subjects: its per-dataset (and LODO) numbers describe "
                    "those subjects, not a population.")
LOSO_NOTE = ("Limitation: leave-one-subject-out folds are defined in the split manifests (`loso_folds`) for the small "
             "datasets but were NOT evaluated; every number here comes from the single frozen train/val/test split.")
RECUMBENT_LABEL = "recumbent (mostly sleep-period lying in training data)"
POSTURE_CAVEAT = ("Posture targets: `recumbent` is mostly Capture-24 sleep-diary lying in the training data (awake "
                  "lying is reported separately below); driving/passenger (vehicle) windows carry `seated_likely` "
                  "because posture is genuinely labelled there; posture is MASKED on gait/cycling/exercise windows.")


def ci(b: Dict[str, Any], nd: int = 3) -> str:
    if not b:
        return "–"
    mark = FEW_SUBJECTS_MARK if b.get("warning") else ""
    return f"{f(b.get('point'), nd)} [{f(b.get('ci_low'), nd)}, {f(b.get('ci_high'), nd)}]{mark}"


def class_label(h: str, c: str) -> str:
    return RECUMBENT_LABEL if (h, c) == ("posture", "recumbent") else c


def gate_cell(gt: Dict[str, Any]) -> str:
    if not gt:
        return "–"
    return f"P={f(gt.get('precision'))} n={f(gt.get('n_acc'))} → {gt.get('level', 'pass' if gt.get('pass') else 'fail')}"


def _json_safe(o):
    if isinstance(o, dict):
        return {str(k): _json_safe(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_json_safe(v) for v in o]
    if hasattr(o, "item") and not isinstance(o, (list, dict)):
        try:
            o = o.item()
        except (ValueError, AttributeError):
            pass
    if isinstance(o, float) and not math.isfinite(o):
        return None
    return o


def class_head_md(h: str, r: Dict[str, Any]) -> List[str]:
    p, u, b = r["pooled"], r.get("uncalibrated_softmax", {}), r.get("bootstrap_ci", {})
    L = [f"### {h}", ""]
    if h == "posture":
        L += [POSTURE_CAVEAT, ""]
    L += ["| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | macro-F1 present-only (legacy) | NLL raw→cal | "
          "Brier raw→cal | ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |", "|---|---|---|---|---|---|---|---|---|---|",
          f"| {f(p['n'])} | {f(p['accuracy'])} | {ci(b.get('balanced_accuracy'))} | {ci(b.get('macro_f1'))} | "
          f"{ci(b.get('macro_f1_present_supported')) if b.get('macro_f1_present_supported') else f(p.get('macro_f1_present_supported'))} | "
          f"{f(u.get('nll'))}→{f(p['nll'])} | {f(u.get('brier'))}→{f(p['brier'])} | {f(u.get('ece_top_equal_width_15'))}→"
          f"{f(p['ece_top_equal_width_15'])} ({f(p['ece_top_equal_width_15_null']['null_p95'])}) | "
          f"{f(u.get('classwise_ece_equal_width_15'))}→{f(p['classwise_ece_equal_width_15'])} | {f(r['aurc']['aurc'])} |", "",
          "macro-F1 = sklearn convention (mean F1 over the union of true and predicted classes; a class predicted while "
          f"absent scores 0). Predicted while absent from this test set: {', '.join(p.get('predicted_absent_classes') or []) or 'none'}. "
          "'present-only' = the earlier number over classes with test support only (kept for comparison).", ""]
    mb = r.get("majority_baseline", {})
    L += [f"Majority baseline (train-majority `{mb.get('class')}`): accuracy {f(mb.get('accuracy'))}, balanced acc "
          f"{f(mb.get('balanced_accuracy'))}, macro-F1 {f(mb.get('macro_f1'))}. Set-truth windows: {f(p.get('n_set_truth'))}; "
          f"windows whose truth is an unsupported class (not scored): "
          f"{f(sum(v['unsupported_truth_windows'] for v in p['per_class'].values()))}.", "",
          "| class | supported | test support | P | R | F1 | P single-label (n) | classwise ECE | val status | tau | "
          "pooled gate | dataset demotions | final status | unsupported-truth windows |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    sl = (r.get("single_label") or {}).get("per_class", {})
    for c in HEAD_CLASS_ORDERS[h]:
        pc = p["per_class"][c]
        g = r["gate"].get(c, {})
        prf = [pc["precision"], pc["recall"], pc["f1"]] if pc["supported_by_head"] else [None, None, None]
        s1 = sl.get(c)
        single = f"{f(s1['precision'])} ({f(s1['support'])})" if s1 else "–"
        dem = "; ".join(g.get("reasons", [])[1:] if g.get("reasons") and g["reasons"][0].startswith("pooled") else
                        g.get("reasons", [])) or "–"
        L.append(f"| {class_label(h, c)} | {f(pc['supported_by_head'])} | {f(pc['support'])} | {f(prf[0])} | {f(prf[1])} | "
                 f"{f(prf[2])} | {single} | {f(pc.get('classwise_ece'))} | {g.get('val_status', 'unsupported')} | "
                 f"{f(g.get('tau'))} | {gate_cell(g.get('test') or {})} | {dem} | {g.get('final_status', '–')} | "
                 f"{f(pc['unsupported_truth_windows'])} |")
    L += ["", "P single-label = precision (argmax) on windows whose truth is exactly one class, next to the set-target "
          "scoring (where a set-target window is correct for any member). Final status = min(val status, pooled gate, "
          "every wrist dataset with n_acc >= 30); the gate only demotes.", ""]
    L += per_dataset_md(h, r)
    aw = r.get("awake_lying")
    if aw:
        L += awake_lying_md(aw)
    L += ["", f"Wrist-only: n={f(r['wrist_only']['n'])}, macro-F1 {f(r['wrist_only']['macro_f1'])} ({r['wrist_only']['note']}).", "",
          "Coverage / precision at fixed confidence thresholds (top-label): " +
          "; ".join(f"≥{t['tau']}: cov {f(t['coverage'])}, P {f(t['precision'])}" for t in r["fixed_thresholds"]), "",
          "Confusion (rows truth, cols pred; " + ", ".join(p["confusion"]["rows_truth_cols_pred"]) + "):", "", "```"]
    L += [" ".join(f"{v:7d}" for v in row) for row in p["confusion"]["matrix"]] + ["```", ""]
    return L


def per_dataset_md(h: str, r: Dict[str, Any]) -> List[str]:
    """Per-dataset headline row + per-class P/R/F1 and per-dataset gate (G-5), descriptive flags (G-12)."""
    L = ["Per dataset (macro-F1 = union convention):", "",
         "| dataset | test subjects | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | note |", "|---|---|---|---|---|---|---|---|"]
    for d, dr in r["per_dataset"].items():
        if not dr.get("n"):
            continue
        note = "descriptive" if dr.get("descriptive_only") else ""
        L.append(f"| {d} | {f(dr.get('n_test_subjects'))} | {f(dr['n'])} | {f(dr['balanced_accuracy'])} | "
                 f"{ci(dr.get('bootstrap_macro_f1'))} | {f(dr['nll'])} | {f(dr['ece_top_equal_width_15'])} | {note} |")
    ds = [d for d, dr in r["per_dataset"].items() if dr.get("n")]
    L += ["", "Per dataset per class P/R/F1 (support) and the dataset gate at the frozen tau (P, n_acc → level; levels "
          "with n_acc < 30 do not demote):", "",
          "| class | " + " | ".join(ds) + " |", "|---|" + "---|" * len(ds)]
    for c in HEAD_CLASS_ORDERS[h]:
        cells, any_sup = [], False
        g = r["gate"].get(c, {})
        for d in ds:
            v = r["per_dataset"][d]["per_class"][c]
            if not v["supported_by_head"]:
                cells.append("unsupported")
                continue
            any_sup = True
            cell = f"{f(v['precision'], 2)}/{f(v['recall'], 2)}/{f(v['f1'], 2)} ({v['support']})"
            gd = (g.get("per_dataset") or {}).get(d)
            if gd and gd.get("n_acc"):
                cell += f"; gate P {f(gd.get('precision'), 2)} n {gd['n_acc']} → {gd['level']}"
            cells.append(cell)
        if any_sup:
            L.append(f"| {class_label(h, c)} | " + " | ".join(cells) + " |")
    return L + ["", DESCRIPTIVE_NOTE, FEW_SUBJECTS_NOTE, ""]


def awake_lying_md(aw: Dict[str, Any]) -> List[str]:
    pc = aw.get("per_class_recumbent") or {}
    g = aw.get("gate") or {}
    L = ["Awake lying (recumbent scored on NON-sleep windows only; G-2):", "",
         f"- recumbent truth windows: {f(aw.get('n_recumbent_truth_windows'))}, of which sleep-period "
         f"{f(aw.get('n_sleep_period_recumbent_truth'))} ({f(aw.get('sleep_period_fraction_of_recumbent_truth'))}) and awake "
         f"lying {f(aw.get('n_awake_lying_truth'))} (by dataset: "
         + ", ".join(f"{d} {n}" for d, n in (aw.get("by_dataset_awake_lying_truth") or {}).items()) + ")",
         f"- recumbent on non-sleep windows: P {f(pc.get('precision'))}, R {f(pc.get('recall'))}, F1 {f(pc.get('f1'))} "
         f"(support {f(pc.get('support'))}, predicted {f(pc.get('predicted'))})"]
    if g:
        L.append(f"- awake-lying gate at the frozen tau: pooled {gate_cell(g.get('test') or {})}; per dataset "
                 + ", ".join(f"{d} {gate_cell(v)}" for d, v in (g.get("per_dataset") or {}).items() if v.get("n_acc"))
                 + f"; awake-lying status {g.get('final_status')} (reported only; the served recumbent status is the pooled one)")
    return L + [""]
def transition_md(r: Dict[str, Any]) -> List[str]:
    L = ["### transition (multi-label events)", "", "| event | supported | n (pos) | AUROC | AP | Brier raw→cal | ECE raw→cal | val→final status |",
         "|---|---|---|---|---|---|---|---|"]
    for e, v in r["per_event"].items():
        if not v.get("supported"):
            L.append(f"| {e} | no | – ({f(v.get('n_pos'))}) | – | – | – | – | unsupported |")
            continue
        g = v.get("gate", {})
        L.append(f"| {e} | yes | {f(v['n'])} ({f(v['n_pos'])}) | {f(v['auroc'])} | {f(v['average_precision'])} | "
                 f"{f(v['uncalibrated']['brier'])}→{f(v['brier'])} | {f(v['uncalibrated']['ece_15'])}→{f(v['ece_15'])} | "
                 f"{g.get('val_status')}→{g.get('final_status')} |")
    ev = r.get("event_level", {})
    L += ["", "Event-level (Opportunity/PAMAP2/HHAR dense 2-s windows; theta chosen on val):", "",
          "| event | theta (val status) | true events | P/R/F1 ±5 s | P/R/F1 ±10 s | median / p90 abs error (s, ±10 s) |",
          "|---|---|---|---|---|---|"]
    for e, v in ev.items():
        if not isinstance(v, dict) or "tol_5s" not in v:
            continue
        a, b = v["tol_5s"], v["tol_10s"]
        L.append(f"| {e} | {f(v['theta_from_val'], 2)} ({v.get('theta_status')}) | {v['n_true_events']} | "
                 f"{f(a['precision'], 2)}/{f(a['recall'], 2)}/{f(a['f1'], 2)} | {f(b['precision'], 2)}/{f(b['recall'], 2)}/{f(b['f1'], 2)} | "
                 f"{f(b['abs_err_median_s'], 1)} / {f(b['abs_err_p90_s'], 1)} |")
    return L + ["", r.get("note", ""), ""]


def intensity_md(r: Dict[str, Any]) -> List[str]:
    L = ["### movement_intensity", "", f"Target {r['target']}; split-conformal 80% half-width {f(r['interval80'])}.", "",
         "| set | n | MAE | MAE const (test mean) | R² | Spearman | 80% interval coverage |", "|---|---|---|---|---|---|---|"]
    for name, v in [("pooled", r["pooled"])] + list(r["per_dataset"].items()):
        L.append(f"| {name} | {f(v.get('n'))} | {f(v.get('mae'))} | {f(v.get('mae_constant_test_mean'))} | {f(v.get('r2'))} | "
                 f"{f(v.get('spearman'))} | {f(v.get('interval80_coverage'))} |")
    return L + [""]


def ood_md(r: Dict[str, Any]) -> List[str]:
    L = ["## OOD", "", f"Bundle method `{r['bundle_method']}` (k={r.get('k')}), threshold {f(r['threshold'])} "
         f"(0.95 quantile of VAL ID scores); ID test false-alarm rate {f(r['id_test_false_alarm_rate'])} on {f(r['n_id_test'])} windows.", ""]
    for name, rows in r.get("benchmark", {}).items():
        L += [f"**{name}**", "", "| method | n_id | n_ood | AUROC | AUPRC (OOD+, prevalence) | FPR@95 (OOD+) | FPR@95 (ID+) | "
              "ID false alarm @op | OOD detect @op |", "|---|---|---|---|---|---|---|---|---|"]
        for m, v in rows.items():
            if m.startswith("combined"):
                continue
            L.append(f"| {m} | {f(v['n_id'])} | {f(v['n_ood'])} | {f(v['auroc'])} | {f(v['auprc_ood_positive'])} "
                     f"({f(v['ood_prevalence'])}) | {f(v['fpr95_ood_positive'])} | {f(v['fpr95_id_positive'])} | "
                     f"{f(v['id_false_alarm_at_op'])} | {f(v['ood_detect_rate_at_op'])} |")
        c = rows.get("combined_risk_coverage_locomotion")
        if c:
            a, b = c["confidence_only"], c["with_ood_rejection"]
            L += ["", f"Combined risk-coverage (locomotion; OOD windows count as errors): confidence-only max coverage "
                  f"{f(a['max_coverage'])}, risk {f(a['risk_at_max_coverage'])}, AURC {f(a['aurc_within_max_coverage'])}; "
                  f"with OOD rejection max coverage {f(b['max_coverage'])}, risk {f(b['risk_at_max_coverage'])}, "
                  f"AURC {f(b['aurc_within_max_coverage'])}."]
        L.append("")
    sel = r.get("selection_on_val")
    if sel:
        L += [f"OOD method selection (VAL only): chosen `{sel.get('chosen')}` from {sel.get('from')}; VAL AUROC "
              + ", ".join(f"{k} {f(v)}" for k, v in (sel.get("val_auroc") or {}).items()), ""]
    return L


def render(rep: Dict[str, Any]) -> str:
    st = rep.get("integrity", {})
    seal = rep.get("seal") or {}
    prov = rep.get("provenance") or {}
    rr = st.get("rerun_reason")
    L = [f"# Evaluation — `{rep['bundle_id']}` ({rep['role']})", "", BANNER, "",
         f"- evaluated bundle_sha256 `{rep['bundle_sha256']}`; sealed bundle_sha256 `{seal.get('sealed_bundle_sha256', '–')}` "
         f"(test_gate.json `{str(seal.get('test_gate_sha256', '–'))[:16]}`; the served artifact carries the gate); encoder "
         f"`{rep['encoder']['encoder_id']}` ({rep['encoder'].get('kind')}); evidence_tier_max `{rep['evidence_tier_max']}`",
         f"- provenance: git_commit `{prov.get('git_commit')}`, source_tree_sha256 `{str(prov.get('source_tree_sha256'))[:16]}`, "
         f"source dirty {prov.get('source_dirty')}, allow_dirty {prov.get('allow_dirty')}",
         f"- evaluated once on the frozen test subjects (assembled inside the TestVault) through `load_bundle(...).apply(...)`; "
         f"test_sha256 `{st.get('test_sha256')}`; evaluations of this experiment on this test split: {st.get('n_test_evaluations')} "
         f"(rerun reason: {rr or 'none'}{(' — ' + str(st.get('rerun_detail'))) if rr else ''}); bundle.apply vs training-side "
         f"numpy max |Δ| (first 2,000 windows) "
         f"{f(rep.get('apply_vs_training_side_max_abs', rep.get('apply_vs_apply_arrays_max_abs')), 12)}",
         f"- test windows: " + ", ".join(f"{d['dataset']} {d['windows']:,} ({d['subjects']} subj)" for d in rep["test_windows"]),
         f"- nonfinite windows dropped: {rep['n_nonfinite_dropped']}", "", FEW_SUBJECTS_NOTE, DESCRIPTIVE_NOTE, LOSO_NOTE, ""]
    for h in ("posture", "locomotion", "arm_behavior"):
        if h in rep["heads"]:
            L += class_head_md(h, rep["heads"][h])
    if "transition" in rep["heads"]:
        L += transition_md(rep["heads"]["transition"])
    if "movement_intensity" in rep["heads"]:
        L += intensity_md(rep["heads"]["movement_intensity"])
    L += ood_md(rep["ood"])
    tp = rep.get("test_predictions")
    if tp:
        L += ["## Per-window test predictions (outside git)", "", tp.get("format", ""), ""]
        L += [f"- {d}: `{v['path']}` ({v['n_windows']:,} windows)" for d, v in tp.items() if isinstance(v, dict)]
    L += ["", "Measured: every table above (test subjects, once). Inferred: nothing about Inertia-1 or WHOOP straps — "
          "the encoders are stand-ins and the data are public wrist datasets."]
    return "\n".join(L) + "\n"


def write_evaluation(rep: Dict[str, Any], out_dir: str) -> List[str]:
    os.makedirs(out_dir, exist_ok=True)
    jp, mp = os.path.join(out_dir, "evaluation.json"), os.path.join(out_dir, "evaluation.md")
    with open(jp, "w") as fh:
        json.dump(_json_safe(rep), fh, indent=1, sort_keys=True, allow_nan=False)
        fh.write("\n")
    with open(mp, "w") as fh:
        fh.write(render(rep))
    return [jp, mp]


def write_summary(eval_dir: str, bundles_root: str) -> str:
    from .summary import build_summary
    return build_summary(eval_dir, bundles_root)


__all__ = ["write_evaluation", "write_summary", "render", "BANNER", "f", "ci", "class_label", "gate_cell",
           "FEW_SUBJECTS_NOTE", "DESCRIPTIVE_NOTE", "LOSO_NOTE", "RECUMBENT_LABEL", "POSTURE_CAVEAT"]
