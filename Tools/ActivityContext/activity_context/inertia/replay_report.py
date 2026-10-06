"""Render the system-comparison tables (agent R) from the replay result JSONs.

``python -m activity_context.inertia.replay_report --out eval/inertia/SYSTEM_COMPARISON`` reads
``research/inertia-replay/{hart_wisdm_summary.json, proxy_choice.json, runs/<bundle>/{sweep,final}_*.json}``
and writes ``<out>.tables.md`` (tables only; the narrative lives in ``<out>.md``) and ``<out>.json``.
Everything Inertia is a STAND-IN, NOT INERTIA-1.
"""

from __future__ import annotations

import json
import os
from typing import Any, Dict, List, Mapping, Optional, Sequence

from . import replay_data as rd

ARM_LABEL = {"A0s": "A0s streams only", "A0": "A0 streams+imu-feat-1", "A1": "A1 +HART", "A2": "A2 +Inertia*",
             "A3": "A3 +HART+Inertia*", "NAV": "NAV naive avg*"}


def _f(x: Any, nd: int = 3) -> str:
    if x is None:
        return "—"
    if isinstance(x, bool):
        return "yes" if x else "no"
    if isinstance(x, (int,)) and not isinstance(x, bool):
        return f"{x:,}"
    try:
        return f"{float(x):.{nd}f}"
    except (TypeError, ValueError):
        return str(x)


def _ci(d: Optional[Mapping[str, Any]], nd: int = 3) -> str:
    if not d or d.get("point") is None:
        return "—"
    lo, hi = d.get("ci_low"), d.get("ci_high")
    star = ""
    if lo is not None and hi is not None and (lo > 0 or hi < 0):
        star = " **"
    few = "†" if d.get("warning") else ""          # < 10 subjects: the percentile CI under-covers (G-12)
    return f"{_f(d['point'], nd)} [{_f(lo, nd)}, {_f(hi, nd)}]{few}{star}"


def table(header: Sequence[str], rows: Sequence[Sequence[Any]]) -> str:
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(out)


def head_table(cfg: Mapping[str, Any], head: str, arms: Sequence[str]) -> str:
    rows = []
    for a in arms:
        hm = cfg["arms"].get(a, {}).get(head) or {}
        if not hm.get("n"):
            continue
        rows.append([ARM_LABEL[a], _f(hm.get("n")), _f(hm.get("accuracy_top_known")), _f((hm.get("aurc") or {}).get("aurc")),
                     _f(hm.get("nll_known")), _f(hm.get("brier_known")), _f(hm.get("ece_known_15")),
                     _f(hm.get("unknown_mass_mean")), _f(hm.get("unknown_mass_ge_0.5"))])
    return table(["arm", "states", "top-known acc", "AURC", "NLL (known)", "Brier", "ECE-15", "unknown mass",
                  "share unknown>=.5"], rows)


def class_table(cfg: Mapping[str, Any], head: str, arms: Sequence[str]) -> str:
    classes: List[str] = []
    for a in arms:
        for c in ((cfg["arms"].get(a, {}).get(head) or {}).get("classes") or {}):
            if c not in classes:
                classes.append(c)
    rows = []
    for c in classes:
        for a in arms:
            d = ((cfg["arms"].get(a, {}).get(head) or {}).get("classes") or {}).get(c)
            if d is None:
                continue
            ta = d.get("test_at_val_tau") or {}
            desc = d.get("descriptive_cov95") or {}
            rows.append([c, ARM_LABEL[a], _f(d.get("truth_states")), d.get("val_status", "—"), _f(d.get("val_tau"), 3),
                         _f(ta.get("precision")), _f(ta.get("cp_lower_95")), _f(ta.get("recall")),
                         _f(d.get("coverage95_val_tau")), _f(desc.get("coverage")), _f(desc.get("tau"), 3)])
    return table(["class", "arm", "truth states", "VAL status", "VAL tau", "TEST precision @VAL tau", "CP95 lower",
                  "TEST recall @VAL tau", "coverage@95 (VAL-strong tau, TEST gate passed)", "descriptive coverage@95 (TEST curve)",
                  "tau"], rows)


def boot_table(cfg: Mapping[str, Any], pair: str) -> str:
    b = (cfg.get("paired_bootstrap") or {}).get(pair)
    if not b:
        return "_not run_"
    rows = []
    for h in ("posture", "locomotion"):
        hd = b.get(h) or {}
        rows.append([h, "NLL (known) Δ", _ci(hd.get("nll_known"))])
        rows.append([h, "AURC (binned) Δ", _ci(hd.get("aurc_binned"))])
        for c, cd in hd.items():
            if not isinstance(cd, dict) or "cov95_desc" not in cd:
                continue
            rows.append([h, f"{c}: descriptive coverage@95 Δ", _ci(cd.get("cov95_desc"))])
            if "coverage95_val_tau" in cd:
                rows.append([h, f"{c}: recall at VAL-strong tau Δ (precision not gated)", _ci(cd.get("coverage95_val_tau"))])
    rows.append(["display", "label flips per hour Δ", _ci(b.get("display_flips_per_hour"), 2)])
    return (f"{b['b']} − {b['a']} (paired subject-cluster bootstrap, {b['n_boot']} resamples, {b['n_subjects']} subjects; "
            "point [95% CI]; ** = CI excludes 0)\n\n" + table(["head", "metric", "B − A"], rows))


def misc_table(cfg: Mapping[str, Any], arms: Sequence[str]) -> str:
    rows = []
    for a in arms:
        s = cfg["arms"].get(a) or {}
        d = s.get("display") or {}
        rows.append([ARM_LABEL[a], _f(s.get("n_states")), _f((s.get("coarse") or {}).get("accuracy")),
                     _f(d.get("flips_per_hour"), 1), _f(d.get("hours"), 1),
                     ", ".join(s.get("refusals") or []) or "—",
                     _f(((s.get("motion_heads_report") or {}).get("windows_ingested"))),
                     _f(((s.get("motion_heads_report") or {}).get("ood_windows")))])
    return table(["arm", "published states", "coarse 4-class acc", "display flips/h", "hours", "refusals",
                  "Inertia windows ingested", "of which OOD"], rows)


def event_table(cfg: Mapping[str, Any], arms: Sequence[str]) -> str:
    rows = []
    for a in arms:
        e = (cfg["arms"].get(a) or {}).get("events")
        if not e:
            continue
        for tol in ("tol5", "tol10", "tol30"):
            p = e["pooled"][tol]
            rows.append([ARM_LABEL[a], tol.replace("tol", "±") + " s", _f(p["tp"]), _f(p["fp"]), _f(p["fn"]),
                         _f(p["precision"]), _f(p["recall"]), _f(p["f1"])])
        kinds = e.get("per_kind") or {}
        for k, v in sorted(kinds.items()):
            m = v.get("tol10") or {}
            rows.append([ARM_LABEL[a], f"{k} ±10 s", _f(m.get("tp")), _f(m.get("fp")), _f(m.get("fn")),
                         _f(m.get("precision")), _f(m.get("recall")),
                         f"{_f(m.get('f1'))} (med {_f(m.get('abs_err_median_s'), 1)} s, p90 {_f(m.get('abs_err_p90_s'), 1)} s)"])
    return table(["arm", "tolerance / kind", "TP", "FP", "FN", "precision", "recall", "F1"], rows)


def sweep_table(sweep: Mapping[str, Any]) -> str:
    rows = []
    for r in sweep.get("configs", []):
        w = r["weights"]
        for a in ("A2", "A3"):
            if a in r:
                o = r[a]["objective"]
                rows.append([a, w["locomotion"], w["posture"], w["arm"], w["hart_redundancy"], _f(o[0]), _f(o[1])])
    return table(["arm", "w_loc", "w_post", "w_arm", "rho", "VAL objective (mean cov@95)", "VAL NLL (tie-break)"], rows)


def ledger_line(doc: Mapping[str, Any]) -> str:
    """The TestVault stamp of a replay TEST decode (G-16), or a note that the decode predates the ledger."""
    st = doc.get("integrity")
    if not st:
        return "_Ledger: none (this TEST decode predates the replay ledger)._"
    rr = st.get("rerun_reason")
    return (f"_Ledger: `{st.get('experiment')}`, evaluation {st.get('n_test_evaluations')} on test split "
            f"`{str(st.get('test_sha256'))[:12]}`; rerun reason: {rr or 'none'}"
            f"{(' — ' + str(st.get('rerun_detail'))) if rr else ''}._")


def render_baseline(path: str, ds: str) -> str:
    with open(path) as f:
        bl = json.load(f)
    arms = [a for a in ("A0s", "A0", "A1") if a in bl["arms"]]
    parts = [f"### {ds} TEST — bundle-independent arms ({', '.join(arms)}); xctest build {bl['xctest_sha256'][:12]}",
             ledger_line(bl)]
    parts.append(misc_table(bl, arms))
    for h in ("locomotion", "posture", "arm_behavior"):
        parts.append(f"#### {h}\n\n" + head_table(bl, h, arms) + "\n\n" + class_table(bl, h, arms))
    if ds == "capture24":
        parts.append("#### transition events (Capture-24 truth = unannotated gaps <= 28 s; NOT timing ground truth)\n\n"
                     + event_table(bl, arms))
    for pair in (bl.get("paired_bootstrap") or {}):
        parts.append(f"#### paired bootstrap {pair}\n\n" + boot_table(bl, pair))
    return "\n\n".join(parts)


def render(base: str, out: str, baseline_dir: Optional[str] = None) -> Dict[str, Any]:
    doc: Dict[str, Any] = {"banner": rd.STANDIN_BANNER}
    parts: List[str] = []
    for ds in ("wisdm", "capture24"):
        bp = os.path.join(baseline_dir or os.path.join(base, "baseline"), f"baseline_{ds}.json")
        if os.path.isfile(bp):
            parts.append(render_baseline(bp, ds))
            with open(bp) as f:
                doc[f"baseline_{ds}"] = json.load(f)
    for ds, arms in (("wisdm", ["A0s", "A0", "A1", "A2", "A3", "NAV"]), ("capture24", ["A0s", "A0", "A2"])):
        fp = os.path.join(base, f"final_{ds}.json")
        sp = os.path.join(base, f"sweep_{ds}.json")
        if os.path.isfile(sp):
            with open(sp) as f:
                sw = json.load(f)
            doc[f"sweep_{ds}"] = {"selected": sw.get("selected"), "objective": sw.get("objective"),
                                  "rho_hat": sw.get("rho_hat")}
            parts.append(f"### {ds}: VALIDATION sweep\n\n" + sweep_table(sw))
        if not os.path.isfile(fp):
            parts.append(f"### {ds}: TEST — not run\n")
            continue
        with open(fp) as f:
            fin = json.load(f)
        doc[f"final_{ds}"] = fin
        parts.append(f"### {ds} TEST ledger\n\n" + ledger_line(fin))
        for label, cfg in fin["configs"].items():
            ws = cfg["weights"]
            desc = "; ".join(f"{a}: loc {w['locomotion']}, post {w['posture']}, arm {w['arm']}, rho {w['hart_redundancy']}"
                             for a, w in sorted(ws.items()))
            parts.append(f"### {ds} TEST — Inertia weights: {label} ({desc})")
            parts.append(misc_table(cfg, arms))
            for h in ("locomotion", "posture", "arm_behavior"):
                parts.append(f"#### {h}\n\n" + head_table(cfg, h, arms) + "\n\n" + class_table(cfg, h, arms))
            if ds == "capture24":
                parts.append("#### transition events (Capture-24 truth = unannotated gaps <= 28 s; NOT timing ground truth)\n\n"
                             + event_table(cfg, arms))
            for pair in (cfg.get("paired_bootstrap") or {}):
                parts.append(f"#### paired bootstrap {pair}\n\n" + boot_table(cfg, pair))
    with open(out + ".tables.md", "w", encoding="utf-8") as f:
        f.write(f"<!-- generated by activity_context.inertia.replay_report; {rd.STANDIN_BANNER} -->\n\n")
        f.write("† = subject-cluster bootstrap over fewer than 10 subjects (WISDM test has 8): the percentile CI "
                "under-covers; read it as descriptive. ** = the 95 % CI excludes 0.\n\n")
        f.write("\n\n".join(parts) + "\n")
    return doc


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", required=True, help="directory holding sweep_*.json / final_*.json")
    ap.add_argument("--out", required=True, help="output path prefix (writes <out>.tables.md)")
    ap.add_argument("--baseline", default=None, help="directory holding baseline_*.json (default <runs>/baseline)")
    a = ap.parse_args(argv)
    render(a.runs, a.out, a.baseline)
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
