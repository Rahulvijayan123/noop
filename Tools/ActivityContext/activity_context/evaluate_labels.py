"""activity-evaluate-labels — ground-truth label evaluation harness (spec 10/13).

Consumes ground-truth labels (guided strong + optional weak) and
``hart-windows-1`` day documents (HART and baseline rows), joins windows to
labels at the head level, splits sessions leakage-free, and reports the full
spec 10.3 metric block per (model, head, split), plus transitions, per-session
distribution, and an optional third model from ``activity_context_days``
documents.

Strong vs weak are counted separately and never mixed: the default evaluation
is guided-strong only; ``--include-weak`` adds a clearly-labelled combined
view. Labels with gaps / short sensor coverage are excluded unless
``--include-degraded`` (counted either way).

CLI mirrors ``activity_context.evaluate`` style (argparse, report to stdout
and file).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, List, Optional, Sequence, Tuple


from .labels import (
    DEFAULT_TAU_S,
    MIN_GT_EVENTS_FOR_REPORT,
    TAUS_S,
    EvalUnit,
    LabelRecord,
    WindowPrediction,
    assign_units,
    evaluate_head,
    load_labels,
    parse_day_doc,
    predicted_transitions,
    split_by_session,
    transition_matching,
)


def _fmt(value: Any, digits: int = 4) -> str:
    if value is None:
        return "—"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


# ---------------------------------------------------------------------------
# ActivityContext day documents -> per-window head values ("activity_context"
# model, spec 10.5 baseline 3)
# ---------------------------------------------------------------------------

def _head_top(probs: Any, head: str) -> Optional[str]:
    """Deterministic argmax over a run's head probability dict. Ties break on
    declaration order of the dict (kept as the document wrote them)."""
    if not isinstance(probs, dict) or not probs:
        return None
    best: Optional[str] = None
    best_p: float = 0.0
    for value, p in probs.items():
        try:
            p = float(p)
        except (TypeError, ValueError):
            continue
        if p > 0 and (best is None or p > best_p):
            best = value
            best_p = p
    if best is None or best == "unknown":
        return None
    return best


def decode_context_windows(docs: Sequence[Dict[str, Any]]) -> Dict[Tuple[int, int], Dict[str, str]]:
    """Decode per-window head values from ``activity_context_days`` documents.

    A day document stores coalesced ``runs`` (``{s, e, posture, locomotion,
    arm_behavior, ...}``); a run's head dict is the state belief over that
    stretch. The window's predicted head value is the head top of the run
    with the largest overlap over the window (mirrors the field names in
    ActivityContextDays.swift / ActivityContextTrack.swift). Returns a map
    (start_ts, end_ts) -> {head: value} over the union of the documents.
    """
    out: Dict[Tuple[int, int], Dict[str, str]] = {}
    for doc in docs:
        runs = doc.get("runs") if isinstance(doc, dict) else None
        if not isinstance(runs, list):
            continue
        for run in runs:
            if not isinstance(run, dict):
                continue
            start = run.get("s")
            end = run.get("e")
            if not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
                continue
            if end <= start or end - start > 86400:
                continue
            values: Dict[str, str] = {}
            for head in ("posture", "locomotion", "arm_behavior"):
                top = _head_top(run.get(head), head)
                if top is not None:
                    values[head] = top
            if values:
                out[(int(start), int(end))] = values
    return out


def context_head_value_for(
    context: Dict[Tuple[int, int], Dict[str, str]],
    window: WindowPrediction,
) -> Optional[str]:
    """Locomotion value the activity-context decoder holds over this window
    (run with the largest overlap; None when no run covers >= 50% of the
    window or the run abstains)."""
    best: Optional[Tuple[int, str]] = None
    for (rs, re), heads in context.items():
        if window.end_ts <= rs or window.start_ts >= re:
            continue
        overlap = min(window.end_ts, re) - max(window.start_ts, rs)
        key = (overlap, heads.get("locomotion", ""))
        if best is None or key[0] > best[0]:
            best = key
    if best is None or best[0] < 0.5 * (window.end_ts - window.start_ts):
        return None
    return best[1] or None


# ---------------------------------------------------------------------------
# Evaluation driver
# ---------------------------------------------------------------------------




def _monitored_seconds(units: Sequence[EvalUnit]) -> int:
    """Total monitored wall-clock time: the span from the first window start
    to the last window end across the units' windows (per session)."""
    by_session: Dict[str, List[EvalUnit]] = {}
    for u in units:
        by_session.setdefault(u.session, []).append(u)
    total = 0
    for sess, sess_units in by_session.items():
        starts = [u.window.start_ts for u in sess_units]
        ends = [u.window.end_ts for u in sess_units]
        if starts:
            total += max(ends) - min(starts)
    return total


def evaluate_models(
    labels: Sequence[LabelRecord],
    windows: Sequence[WindowPrediction],
    *,
    include_weak: bool = False,
    include_degraded: bool = False,
    holdout_sessions: int = 1,
    split_mode: str = "holdout",
    chronological_ts: Optional[int] = None,
    tau: int = DEFAULT_TAU_S,
    context_windows: Optional[Dict[Tuple[int, int], Dict[str, str]]] = None,
) -> Dict[str, Any]:
    """Run the whole evaluation: models = {"hart", "baseline"} from the
    window docs' baseline flags, plus "activity_context" when day documents
    are supplied. The SAME labeled windows feed every model, so comparisons
    are apples-to-apples (spec 10.5). Returns the full report dict.
    """
    # One join pass per model so each model only scores the windows its
    # encoder produced; labels are identical across passes.
    model_units: Dict[str, List[EvalUnit]] = {}
    all_hart = [w for w in windows if not w.baseline]
    all_baseline = [w for w in windows if w.baseline]
    for model, model_windows in (("hart", all_hart), ("baseline", all_baseline)):
        if not model_windows:
            model_units[model] = []
            continue
        units, counts = assign_units(
            labels, model_windows,
            include_degraded=include_degraded,
            include_weak=include_weak,
            model=model,
        )
        model_units[model] = units
    if context_windows:
        units, counts = assign_units(
            labels, all_hart if all_hart else windows,
            include_degraded=include_degraded,
            include_weak=include_weak,
            model="activity_context",
        )
        model_units["activity_context"] = [
            EvalUnit(
                window=u.window, head=u.head, truth=u.truth,
                predicted=context_head_value_for(context_windows, u.window),
                session=u.session, model="activity_context",
                label_duration_s=u.label_duration_s, label=u.label,
            )
            for u in units
        ]

    # The split is computed on the hart units and applied identically to
    # every model (same labeled windows on each side).
    base_units = model_units.get("hart") or model_units.get("baseline") or []
    if not base_units:
        return {"error": "no windows to evaluate", "models": {}}
    split = split_by_session(
        labels, base_units,
        holdout_sessions=holdout_sessions,
        mode=split_mode,
        chronological_ts=chronological_ts,
    )

    report: Dict[str, Any] = {
        "split": split.report,
        "models": {},
        "strong_weak": {
            "strong_labels": sum(1 for l in labels if l.is_strong),
            "weak_labels": sum(1 for l in labels if not l.is_strong),
            "evaluation": "strong_only" if not include_weak else "combined_strong_weak",
        },
    }
    for model, units in model_units.items():
        model_report: Dict[str, Any] = {}
        train_by_session = {u.session for u in split.train_units}
        test_by_session = {u.session for u in split.test_units}
        train_units = [u for u in units if u.session in train_by_session]
        test_units = [u for u in units if u.session in test_by_session]
        for split_name, split_units in (("train", train_units), ("test", test_units)):
            if not split_units:
                model_report[split_name] = {"n_units": 0}
                continue
            by_head: Dict[str, List[EvalUnit]] = {}
            for u in split_units:
                by_head.setdefault(u.head, []).append(u)
            heads_report: Dict[str, Dict[str, Any]] = {}
            for head in sorted(by_head):
                head_units = by_head[head]
                hr = evaluate_head(head_units)
                monitored = _monitored_seconds(head_units)
                gt_events = [
                    t for u in head_units if u.label.transition() is not None
                ]
                pred_events = predicted_transitions(head_units)
                transitions: Dict[str, Any] = {}
                for t in TAUS_S:
                    transitions[str(t)] = transition_matching(
                        gt_events, pred_events, tau=t, monitored_seconds=monitored)
                # Annotate insufficient event evidence (methodology 3.4).
                n_gt = len(gt_events)
                transitions["_n_gt_events"] = n_gt
                transitions["_insufficient_events"] = (
                    n_gt < MIN_GT_EVENTS_FOR_REPORT and n_gt > 0)
                hr["transitions"] = transitions
                hr["n_sessions"] = len({u.session for u in head_units})
                heads_report[head] = hr
            model_report[split_name] = {
                "n_units": len(split_units),
                "heads": heads_report,
            }
        model_report["n_windows_used"] = len({id(u.window) for u in units})
        report["models"][model] = model_report
    return report


def _load_windows(paths: Sequence[str]) -> Tuple[List[WindowPrediction], List[Dict[str, Any]]]:
    windows: List[WindowPrediction] = []
    day_reports: List[Dict[str, Any]] = []
    for p in paths:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        wins, rep = parse_day_doc(data, p)
        windows.extend(wins)
        day_reports.append(rep.as_dict())
    return windows, day_reports


def _load_context_days(path: Optional[str]) -> Optional[Dict[Tuple[int, int], Dict[str, str]]]:
    if not path:
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict) and isinstance(data.get("days"), list):
        docs = data["days"]
    elif isinstance(data, list):
        docs = data
    else:
        raise ValueError(f"{path}: expected a JSON array of activity_context_days documents")
    return decode_context_windows(docs)




def _head_metric_rows(hr: Dict[str, Any]) -> List[str]:
    rows = [
        ("n_units (labeled windows)", hr.get("n_units")),
        ("n_accepted", hr.get("n_accepted")),
        ("n_abstained", hr.get("n_abstained")),
        ("abstention rate", hr.get("abstention_rate")),
        ("accepted coverage", hr.get("accepted_coverage")),
        ("macro-F1 (accepted)", hr.get("macro_f1")),
        ("balanced accuracy", hr.get("balanced_accuracy")),
        ("duration-weighted accuracy", hr.get("duration_weighted_accuracy")),
        ("Brier (per head)", hr.get("brier")),
        ("ECE-15 (per head)", hr.get("ece_15")),
    ]
    return [f"| {k} | {_fmt(v)} |" for k, v in rows]


def _class_rows(hr: Dict[str, Any]) -> List[str]:
    pc = hr.get("per_class") or {}
    out = ["| class | tp | fp | fn | precision | recall | F1 | support |",
           "|---|---|---|---|---|---|---|---|"]
    for c in sorted(pc):
        d = pc[c]
        out.append(f"| {c} | {d['tp']} | {d['fp']} | {d['fn']} | "
                   f"{_fmt(d['precision'], 3)} | {_fmt(d['recall'], 3)} | "
                   f"{_fmt(d['f1'], 3)} | {d['support']} |")
    return out


def _segment_rows(hr: Dict[str, Any]) -> List[str]:
    seg = hr.get("segment") or {}
    return [
        "| metric | value |",
        "|---|---|",
        f"| segment-F1 | {_fmt(seg.get('segment_f1'), 4)} |",
        f"| mean matched IoU | {_fmt(seg.get('mean_matched_iou'), 4)} |",
        f"| predicted runs | {seg.get('n_pred_runs')} |",
        f"| truth runs | {seg.get('n_truth_runs')} |",
        f"| matched runs | {seg.get('n_matched_runs')} |",
    ]


def _transition_rows(hr: Dict[str, Any]) -> List[str]:
    tr = hr.get("transitions") or {}
    out = ["| tau (s) | matched | unmatched GT | unmatched pred | P | R | F1 | "
           "median abs err | p90 abs err | signed bias | FP/hour |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for tau in (str(t) for t in TAUS_S):
        d = tr.get(tau) or {}
        out.append(f"| {tau} | {d.get('matched', 0)} | {d.get('unmatched_gt', 0)} | "
                   f"{d.get('unmatched_pred', 0)} | {_fmt(d.get('precision'), 3)} | "
                   f"{_fmt(d.get('recall'), 3)} | {_fmt(d.get('f1'), 3)} | "
                   f"{_fmt(d.get('median_abs_err_s'), 1)} | {_fmt(d.get('p90_abs_err_s'), 1)} | "
                   f"{_fmt(d.get('signed_bias_s'), 1)} | {_fmt(d.get('fp_per_hour'), 2)} |")
    if tr.get("_insufficient_events"):
        out.append(f"_fewer than {MIN_GT_EVENTS_FOR_REPORT} GT events "
                   f"({tr.get('_n_gt_events')}); F1 is directional only_")
    return out


def _per_session_rows(hr: Dict[str, Any]) -> List[str]:
    ps = hr.get("per_session") or {}
    per = ps.get("per_session") or {}
    out = ["| session | units | accepted | macro-F1 |", "|---|---|---|---|"]
    for sess in sorted(per):
        d = per[sess]
        out.append(f"| {sess} | {d['n_units']} | {d['n_accepted']} | {_fmt(d['macro_f1'], 3)} |")
    out.append("")
    out.append("| aggregate | value |")
    out.append("|---|---|")
    out.append(f"| session-macro mean | {_fmt(ps.get('session_macro_f1_mean'), 4)} |")
    out.append(f"| session-macro median | {_fmt(ps.get('session_macro_f1_median'), 4)} |")
    out.append(f"| session-macro IQR | {_fmt(ps.get('session_macro_f1_iqr'), 4)} |")
    out.append(f"| session-macro min / max | {_fmt(ps.get('session_macro_f1_min'), 4)} / "
               f"{_fmt(ps.get('session_macro_f1_max'), 4)} |")
    out.append(f"| pooled macro-F1 | {_fmt(ps.get('pooled_macro_f1'), 4)} |")
    out.append(f"| pooled vs session-macro divergence | {_fmt(ps.get('divergence'), 4)} |")
    return out


def render_markdown(report: Dict[str, Any], inputs: Dict[str, Any]) -> str:
    if "error" in report:
        return f"# Ground-truth label evaluation\n\n{report['error']}\n"
    lines: List[str] = []
    lines.append("# Ground-truth label evaluation")
    lines.append("")
    lines.append(f"_generated {datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')} UTC_")
    lines.append("")
    lines.append("## Inputs")
    lines.append("")
    for k, v in inputs.items():
        lines.append(f"- **{k}**: {v}")
    lines.append("")
    split = report.get("split") or {}
    lines.append("## Split (leakage-free, session-held-out)")
    lines.append("")
    lines.append(f"- mode: `{split.get('mode')}` (sessions ordered by earliest label start_ts)")
    lines.append(f"- sessions total: {split.get('n_sessions_total')} | "
                 f"train: {split.get('n_train_sessions')} | test: {split.get('n_test_sessions')}")
    lines.append(f"- train sessions: `{', '.join(split.get('train_sessions') or [])}`")
    lines.append(f"- test sessions: `{', '.join(split.get('test_sessions') or [])}`")
    lines.append(f"- train units: {split.get('n_train_units')} | test units: {split.get('n_test_units')}")
    lines.append("")
    sw = report.get("strong_weak") or {}
    lines.append("## Strong vs weak")
    lines.append("")
    lines.append(f"- strong labels (guided, confident): {sw.get('strong_labels')}")
    lines.append(f"- weak labels (stretch feedback / imported / unsure): {sw.get('weak_labels')}")
    lines.append(f"- evaluation scope: `{sw.get('evaluation')}` "
                 "(strong and weak are never mixed; --include-weak adds a clearly-labelled combined view)")
    lines.append("")
    models = report.get("models") or {}
    for model in ("hart", "baseline", "activity_context"):
        if model not in models:
            continue
        mrep = models[model]
        if not mrep.get("heads") and not mrep.get("test", {}).get("n_units"):
            continue
        lines.append(f"## Model: `{model}`")
        lines.append("")
        if not mrep.get("test", {}).get("n_units"):
            lines.append("_no labeled windows for this model_")
            lines.append("")
            continue
        for split_name in ("test", "train"):
            srep = mrep.get(split_name) or {}
            heads = srep.get("heads") or {}
            if not heads:
                continue
            for head in sorted(heads):
                hr = heads[head]
                lines.append(f"### {model} · {head} · split={split_name}")
                lines.append("")
                lines.append("| metric | value |")
                lines.append("|---|---|")
                lines.extend(_head_metric_rows(hr))
                lines.append("")
                lines.append("#### Per-class P/R/F1 (accepted windows)")
                lines.append("")
                lines.extend(_class_rows(hr))
                lines.append("")
                lines.append("#### Segment level")
                lines.append("")
                lines.extend(_segment_rows(hr))
                lines.append("")
                lines.append("#### Transitions")
                lines.append("")
                lines.extend(_transition_rows(hr))
                lines.append("")
                lines.append("#### Per-session")
                lines.append("")
                lines.extend(_per_session_rows(hr))
                lines.append("")
        lines.append("")
    return "\n".join(lines)


def _compact_summary(report: Dict[str, Any]) -> str:
    if "error" in report:
        return report["error"]
    out: List[str] = []
    for model, mrep in report.get("models", {}).items():
        test = mrep.get("test") or {}
        heads = test.get("heads") or {}
        for head, hr in sorted(heads.items()):
            out.append(f"{model}/{head} test: n={hr.get('n_units')} "
                       f"macro-F1={_fmt(hr.get('macro_f1'), 3)} "
                       f"balacc={_fmt(hr.get('balanced_accuracy'), 3)} "
                       f"abstain={_fmt(hr.get('abstention_rate'), 3)} "
                       f"cov={_fmt(hr.get('accepted_coverage'), 3)}")
    return "\n".join(out) or "no evaluation units"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="Ground-truth label evaluation (spec 10/13)")
    ap.add_argument("--labels", required=True,
                    help="ground-truth labels: .jsonl (one wire object per "
                         "line) or .json (array)")
    ap.add_argument("--windows", action="append", required=True, metavar="PATH",
                    help="hart-windows-1 day document (repeatable)")
    ap.add_argument("--context-days", default=None, metavar="PATH",
                    help="JSON array of activity_context_days documents -> "
                         "third model 'activity_context'")
    ap.add_argument("--out-dir", default=".", help="output directory")
    ap.add_argument("--holdout-sessions", type=int, default=1,
                    help="session-held-out: last N sessions (by earliest "
                         "label start) are the test side (default 1)")
    ap.add_argument("--split", choices=("holdout", "alternate", "chronological"),
                    default="holdout")
    ap.add_argument("--chronological-ts", type=int, default=None,
                    help="chronological split: sessions starting at/after "
                         "this unix ts are test")
    ap.add_argument("--tau", type=int, default=DEFAULT_TAU_S,
                    help="transition tolerance in seconds (default 5); "
                         "F1@2/5/10 always reported")
    ap.add_argument("--report", default=None,
                    help="markdown report path (default <out-dir>/report.md)")
    ap.add_argument("--json", action="store_true",
                    help="also write machine-readable <out-dir>/report.json")
    ap.add_argument("--include-weak", action="store_true",
                    help="add weak labels (stretch/imported/unsure) to a "
                         "clearly-labelled combined view")
    ap.add_argument("--include-degraded", action="store_true",
                    help="include labels with gaps/short coverage (counted "
                         "as warnings)")
    args = ap.parse_args(argv)

    if args.split == "chronological" and args.chronological_ts is None:
        ap.error("--split chronological requires --chronological-ts")

    labels, label_report = load_labels(args.labels)
    windows, day_reports = _load_windows(args.windows)
    context = _load_context_days(args.context_days)

    report = evaluate_models(
        labels, windows,
        include_weak=args.include_weak,
        include_degraded=args.include_degraded,
        holdout_sessions=args.holdout_sessions,
        split_mode=args.split,
        chronological_ts=args.chronological_ts,
        tau=args.tau,
        context_windows=context,
    )
    report["tau"] = args.tau

    os.makedirs(args.out_dir, exist_ok=True)
    report_path = args.report or os.path.join(args.out_dir, "report.md")
    report_path = os.path.join(args.out_dir, os.path.basename(report_path))

    # Input summary for the markdown header.
    n_hart = sum(1 for w in windows if not w.baseline)
    n_baseline = sum(1 for w in windows if w.baseline)
    inputs = {
        "labels": f"{args.labels} — {label_report.parsed} parsed "
                  f"({label_report.skipped_malformed} malformed, "
                  f"{label_report.skipped_invalid_interval} invalid interval)",
        "windows": f"{len(args.windows)} day doc(s), "
                   f"{n_hart} HART + {n_baseline} baseline windows, "
                   f"{sum(d['dropped'] for d in day_reports)} dropped",
        "context days": args.context_days or "none",
        "tau": args.tau,
        "degraded labels": "included" if args.include_degraded else "excluded (default)",
        "weak labels": "included (combined view)" if args.include_weak else "excluded (default)",
    }
    md = render_markdown(report, inputs)
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(md + "\n")
    if args.json:
        json_path = os.path.join(args.out_dir, "report.json")
        with open(json_path, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2, default=str)
        print(f"wrote {json_path}")
    print(_compact_summary(report))
    print(f"report: {report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
