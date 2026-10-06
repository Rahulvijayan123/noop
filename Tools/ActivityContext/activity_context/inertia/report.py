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


def ci(b: Dict[str, Any], nd: int = 3) -> str:
    if not b:
        return "–"
    return f"{f(b.get('point'), nd)} [{f(b.get('ci_low'), nd)}, {f(b.get('ci_high'), nd)}]"


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
    L = [f"### {h}", "", "| n | accuracy | balanced acc [95% CI] | macro-F1 [95% CI] | NLL raw→cal | Brier raw→cal | "
         "ECE-15 raw→cal (null p95) | classwise ECE raw→cal | AURC |", "|---|---|---|---|---|---|---|---|---|",
         f"| {f(p['n'])} | {f(p['accuracy'])} | {ci(b.get('balanced_accuracy'))} | {ci(b.get('macro_f1'))} | "
         f"{f(u.get('nll'))}→{f(p['nll'])} | {f(u.get('brier'))}→{f(p['brier'])} | {f(u.get('ece_top_equal_width_15'))}→"
         f"{f(p['ece_top_equal_width_15'])} ({f(p['ece_top_equal_width_15_null']['null_p95'])}) | "
         f"{f(u.get('classwise_ece_equal_width_15'))}→{f(p['classwise_ece_equal_width_15'])} | {f(r['aurc']['aurc'])} |", ""]
    mb = r.get("majority_baseline", {})
    L += [f"Majority baseline (train-majority `{mb.get('class')}`): accuracy {f(mb.get('accuracy'))}, balanced acc "
          f"{f(mb.get('balanced_accuracy'))}, macro-F1 {f(mb.get('macro_f1'))}. Set-truth windows: {f(p.get('n_set_truth'))}; "
          f"windows whose truth is an unsupported class (not scored): "
          f"{f(sum(v['unsupported_truth_windows'] for v in p['per_class'].values()))}.", "",
          "| class | supported | test support | P | R | F1 | classwise ECE | val status | tau | test gate | final status | unsupported-truth windows |",
          "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for c in HEAD_CLASS_ORDERS[h]:
        pc = p["per_class"][c]
        g = r["gate"].get(c, {})
        gt = g.get("test") or {}
        gate = (f"P={f(gt.get('precision'))} n={f(gt.get('n_acc'))} {'pass' if gt.get('pass') else 'fail'}" if gt else "–")
        prf = [pc["precision"], pc["recall"], pc["f1"]] if pc["supported_by_head"] else [None, None, None]
        L.append(f"| {c} | {f(pc['supported_by_head'])} | {f(pc['support'])} | {f(prf[0])} | {f(prf[1])} | "
                 f"{f(prf[2])} | {f(pc.get('classwise_ece'))} | {g.get('val_status', 'unsupported')} | {f(g.get('tau'))} | "
                 f"{gate} | {g.get('final_status', '–')} | {f(pc['unsupported_truth_windows'])} |")
    L += ["", "Per dataset:", "", "| dataset | n | balanced acc | macro-F1 [95% CI] | NLL | ECE-15 | per-class F1 |",
          "|---|---|---|---|---|---|---|"]
    for d, dr in r["per_dataset"].items():
        if not dr.get("n"):
            continue
        pcs = ", ".join(f"{c} {f(v['f1'], 2)} (n={v['support']})" for c, v in dr["per_class"].items() if v["support"])
        L.append(f"| {d} | {f(dr['n'])} | {f(dr['balanced_accuracy'])} | {ci(dr.get('bootstrap_macro_f1'))} | "
                 f"{f(dr['nll'])} | {f(dr['ece_top_equal_width_15'])} | {pcs} |")
    L += ["", f"Wrist-only: n={f(r['wrist_only']['n'])}, macro-F1 {f(r['wrist_only']['macro_f1'])} ({r['wrist_only']['note']}).", "",
          "Coverage / precision at fixed confidence thresholds (top-label): " +
          "; ".join(f"≥{t['tau']}: cov {f(t['coverage'])}, P {f(t['precision'])}" for t in r["fixed_thresholds"]), "",
          "Confusion (rows truth, cols pred; " + ", ".join(p["confusion"]["rows_truth_cols_pred"]) + "):", "", "```"]
    L += [" ".join(f"{v:7d}" for v in row) for row in p["confusion"]["matrix"]] + ["```", ""]
    return L


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
    L = [f"# Evaluation — `{rep['bundle_id']}` ({rep['role']})", "", BANNER, "",
         f"- bundle_sha256 `{rep['bundle_sha256']}`; encoder `{rep['encoder']['encoder_id']}` ({rep['encoder'].get('kind')}); "
         f"evidence_tier_max `{rep['evidence_tier_max']}`",
         f"- evaluated once on the frozen test subjects through `load_bundle(...).apply(...)`; test_sha256 "
         f"`{st.get('test_sha256')}`; evaluations of this experiment: {st.get('n_test_evaluations')} "
         f"(rerun reason: {st.get('rerun_reason')}); bundle.apply vs training-side numpy max |Δ| (first 2,000 windows) "
         f"{f(rep.get('apply_vs_training_side_max_abs', rep.get('apply_vs_apply_arrays_max_abs')), 12)}",
         f"- test windows: " + ", ".join(f"{d['dataset']} {d['windows']:,} ({d['subjects']} subj)" for d in rep["test_windows"]),
         f"- nonfinite windows dropped: {rep['n_nonfinite_dropped']}", ""]
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


__all__ = ["write_evaluation", "write_summary", "render", "BANNER", "f", "ci"]
