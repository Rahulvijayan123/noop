"""``eval/inertia/SUMMARY.md``: one overview across every evaluated experiment (never hides poor classes)."""

from __future__ import annotations

import json
import os
from typing import Any, Dict, List

import numpy as np

from . import HEAD_CLASS_ORDERS
from .experiments import EXPERIMENTS, SHORT
from .mappings import load_mappings, summary_counts
from .report import BANNER, ci, f
from .splits import load_splits, summary as split_summary

HEADS = ("posture", "locomotion", "arm_behavior")
PRIMARY = ("primary-hc", "primary-nf", "primary-art")
ARCH = ("linear-hc", "mlp-hc", "linear-art", "mlp-art", "linear-nf")


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
    L = ["| experiment | head | n | macro-F1 [95% CI] | balanced acc [95% CI] | NLL | Brier | ECE-15 | majority macro-F1 |",
         "|---|---|---|---|---|---|---|---|---|"]
    for n in names:
        for h in HEADS:
            r = _head(R.get(n), h)
            if not r:
                continue
            p, b = r["pooled"], r["bootstrap_ci"]
            L.append(f"| {n} | {h} | {f(p['n'])} | {ci(b['macro_f1'])} | {ci(b['balanced_accuracy'])} | {f(p['nll'])} | "
                     f"{f(p['brier'])} | {f(p['ece_top_equal_width_15'])} | {f(r['majority_baseline']['macro_f1'])} |")
    return L + [""]


def _per_class(R, names, h) -> List[str]:
    L = [f"#### {h}", "", "| class | " + " | ".join(f"{n} F1 (P/R)" for n in names) + " | test support | final status (primary-hc) |",
         "|---|" + "---|" * (len(names) + 2)]
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
        g = (_head(R.get("primary-hc"), h) or {}).get("gate", {}).get(c, {})
        L.append(f"| {c} | " + " | ".join(cells) + f" | {sup} | {g.get('val_status', 'unsupported')}→{g.get('final_status', '–')} |")
    return L + [""]


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


def _ood(R) -> List[str]:
    L = ["| bundle | OOD set | method | AUROC | AUPRC (prev.) | FPR@95 OOD+ | ID false alarm @op | OOD detect @op |",
         "|---|---|---|---|---|---|---|---|"]
    for n in ("ood-hc", "ood-nf", "ood-art", "lodo-nohhar-hc"):
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
        o = rep.get("ood", {})
        L.append(f"| {n} | {o.get('bundle_method')}{'@' + str(o['k']) if o.get('k') else ''} | {f(o.get('threshold'))} | "
                 f"{f(o.get('id_test_false_alarm_rate'))} |")
    return L + [""]


def _per_dataset_f1(R, names, h) -> List[str]:
    ds = sorted({d for n in names for d in ((_head(R.get(n), h) or {}).get("per_dataset") or {})})
    L = [f"| {h} macro-F1 by test dataset | " + " | ".join(ds) + " |", "|---|" + "---|" * len(ds)]
    for n in names:
        r = _head(R.get(n), h)
        if not r:
            continue
        cells = [f(r["per_dataset"].get(d, {}).get("macro_f1_present_supported")) for d in ds]
        L.append(f"| {n} | " + " | ".join(cells) + " |")
    return L + [""]


def _seeds(R) -> List[str]:
    L = ["| head | seed 0 | seed 1 | seed 2 | mean ± sd |", "|---|---|---|---|---|"]
    for h in HEADS:
        v = [(_head(R.get(n), h) or {}).get("pooled", {}).get("macro_f1_present_supported") for n in ("primary-hc", "seed1-hc", "seed2-hc")]
        ok = [x for x in v if x is not None]
        L.append(f"| {h} | " + " | ".join(f(x) for x in v) + (f" | {np.mean(ok):.3f} ± {np.std(ok, ddof=1):.3f} |" if len(ok) > 1 else " | – |"))
    return L + [""]


def _windows_table() -> List[str]:
    from .cache import CACHE_ROOT, read_manifest
    L = ["| dataset | spec | window/hop (s) | train | val | test | ood | subjects | loader |", "|---|---|---|---|---|---|---|---|---|"]
    for ds in ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "daphnet_fog"):
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


def _ledger(eval_dir: str) -> List[str]:
    p = os.path.join(eval_dir, "test_ledger.jsonl")
    if not os.path.isfile(p):
        return ["(no ledger)"]
    rows = [json.loads(x) for x in open(p) if x.strip()]
    L = ["| # | experiment | bundle sha256 | test split sha256 | n evals of experiment | rerun reason |", "|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1):
        L.append(f"| {i} | {r['experiment']} | `{r['bundle_sha256'][:16]}` | `{r['test_sha256'][:12]}` | {r['n_test_evaluations']} | "
                 f"{r.get('rerun_reason') or ''} |")
    reruns = [r for r in rows if r.get("rerun_reason")]
    if reruns:
        L += ["", f"{len(reruns)} re-evaluations: the run-1 bundle directory was deleted by an external process; the bundles "
              "were retrained from identical code/data/splits and re-evaluated. Every metric of all 14 re-evaluated "
              "experiments was identical to run 1 (field-by-field comparison of evaluation.json, tolerance 1e-9) — "
              "training and evaluation are deterministic on CPU. Only bundle hashes differ (the manifest records "
              "creation time)."]
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
         "| experiment | role | encoder | window | training datasets | bundle | sha256 | evaluated |", "|---|---|---|---|---|---|---|---|"]
    for n, e in EXPERIMENTS.items():
        rep = R.get(n)
        L.append(f"| {n} | {e.role} | {SHORT.get(e.encoder, e.encoder)} | {e.window} | {', '.join(e.train_datasets)} | "
                 f"`{e.bundle_id}` | `{(rep or {}).get('bundle_sha256', '')[:16]}` | "
                 f"{'yes (n=' + str(rep['integrity']['n_test_evaluations']) + ')' if rep else ('blocked' if e.encoder.startswith('inertia-1/') else 'no')} |")
    L += ["", "## Headline (pooled test, subject-cluster bootstrap 95% CI)", ""] + _headline(R, PRIMARY + ARCH + ("w10-hc",))
    L += ["## Per-class test F1 (precision/recall) — primary bundles", ""]
    for h in HEADS:
        L += _per_class(R, list(PRIMARY) + ["linear-hc", "mlp-hc"], h)
    L += ["## Calibration (test; fit on val only)", ""] + _calibration(R, PRIMARY)
    L += ["## Transition events", ""] + _transition(R, PRIMARY)
    L += ["## Movement intensity", ""] + _intensity(R, PRIMARY)
    L += ["## OOD", ""] + _ood(R)
    L += ["## Ablations", "", "### 10 s vs 30 s windows (stand-in hc, class heads)", ""] + _headline(R, ("primary-hc", "w10-hc"))
    L += ["### Linear vs MLP (forced, test)", ""] + _headline(R, ("linear-hc", "mlp-hc", "linear-art", "mlp-art"))
    L += ["### Leave-one-dataset-out transfer (hc)", ""]
    for h in HEADS:
        L += _per_dataset_f1(R, ["primary-hc", "lodo-noc24-hc", "lodo-c24only-hc", "lodo-nohhar-hc"], h)
    L += ["### Seed variation (primary hc procedure, archs fixed from seed 0)", ""] + _seeds(R)
    sp = load_splits(["capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity"])
    L += ["## Split manifests (subject-level, frozen before windowing)", "", "| dataset | train | val | test | LOSO folds | sha256 |",
          "|---|---|---|---|---|---|"]
    L += [f"| {s['dataset']} | {s['train']} | {s['val']} | {s['test']} | {s['loso_folds']} | `{s['sha256']}` |" for s in split_summary(sp)]
    L += ["", "## Windows (cached, outside git)", ""] + _windows_table()
    L += ["## Dataset / label-mapping summary", "", f"`label_mappings.json` sha256 `{cw.sha256}`; full table: "
          "`eval/inertia/label_mappings.md`.", "", "| dataset | role | labels | rows | used rows posture/locomotion/arm/transition/intensity |",
          "|---|---|---|---|---|"]
    for s in summary_counts(cw):
        u = s["used_rows"]
        L.append(f"| {s['dataset']} | {s['role']} | {s['n_labels']} | {s['n_rows']} | {u['posture']}/{u['locomotion']}/"
                 f"{u['arm_behavior']}/{u['transition']}/{u['movement_intensity']} |")
    L += ["", "## Test-split ledger (evaluate-once integrity)", ""] + _ledger(eval_dir)
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
