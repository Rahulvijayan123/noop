"""activity-personalize — SHADOW-ONLY personalization (spec 11, methodology 7).

Pure offline, numpy-only, deterministic, NO production wiring: this CLI
never touches serve.py, the Swift side, or the cloud. It answers one
research question per user: does a lightweight per-user head (temperature
calibration + linear probe on the frozen ``imu-feat-1`` features) beat the
generic HART/baseline head on SESSION-HELD-OUT data?

Method (spec 11.2 preference order, cheapest first):

  1. Temperature calibration of the generic head probabilities (one scalar
     T, fit on the train sessions by minimizing cross-entropy).
  2. A logistic-regression linear probe on the six ``imu-feat-2`` features
     (accel_rms_g, gyro_rms_dps, jerk_rms_gps, cadence_hz, cadence_strength,
     orientation_change_deg), one-vs-rest, fitted with CLOSED-FORM ridge
     (w = (X'X + lambda I)^-1 X'y) — deterministic, no iterative solver,
     no random init (the "closed-form ridge" option in the contracts).
  3. An abstention threshold on the probe's max probability, chosen on the
     train sessions (selective prediction, methodology 2.2 choice A).

Evidence gates (spec 11.3 / methodology 6.1, contract-tuned): before any
personalization is fitted for a user, EVERY locomotion class in their data
must have >= 30 windows AND >= 3 distinct sessions in the FIT split, and
there must be >= 2 sessions to hold out. Otherwise the user's report is
``insufficient_evidence`` listing the failed classes, and only the generic
baseline is reported.

Splits are SESSION-held-out (spec 10.4): windows of one session never land
on both sides. Per-user grouping uses the label ``user_id`` field when any
label carries it; otherwise all labels are treated as one subject.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .labels import (
    FEATURE_KEYS,
    EvalUnit,
    LabelRecord,
    WindowPrediction,
    assign_units,
    load_labels,
    parse_day_doc,
    split_by_session,
)

#: Fixed seed for anything that could be stochastic (all fits here are
#: closed-form, so this is belt-and-suspenders for tie-breaks / imputation).
SEED = 42
#: Ridge regularizer for the closed-form one-vs-rest logistic probe.
RIDGE_LAMBDA = 1.0
#: Minimum windows per class in the fit split (methodology 6.1 threshold gate).
MIN_WINDOWS_PER_CLASS = 30
#: Minimum distinct sessions per class in the fit split.
MIN_SESSIONS_PER_CLASS = 3
#: Minimum sessions overall to run a session-held-out split.
MIN_SESSIONS = 2
#: Abstention-threshold grid searched on the fit split.
ABSTAIN_GRID = (0.50, 0.60, 0.70, 0.80, 0.90, 0.95)


# ---------------------------------------------------------------------------
# Feature handling (imu-feat-1)
# ---------------------------------------------------------------------------

def feature_vector(window: WindowPrediction) -> Optional[np.ndarray]:
    """The six imu-feat-1 values in FEATURE_KEYS order, or None when the
    window carries no features. Missing cadence_hz inside a row is imputed
    with 0.0 (the scaler mean/std below are fit on real values only)."""
    f = window.features
    if not f:
        return None
    out = np.zeros(len(FEATURE_KEYS), dtype=np.float64)
    for i, key in enumerate(FEATURE_KEYS):
        v = f.get(key)
        out[i] = 0.0 if v is None else float(v)
    return out


def _fit_scaler(rows: Sequence[Optional[np.ndarray]]) -> Tuple[np.ndarray, np.ndarray]:
    """Per-feature mean/std over PRESENT rows; missing cadence_hz values are
    excluded from the stats (they were zero-imputed). Rows with any NaN are
    dropped; std floored at 1e-9."""
    present = [r for r in rows if r is not None and np.isfinite(r).all()]
    if not present:
        return np.zeros(len(FEATURE_KEYS)), np.ones(len(FEATURE_KEYS))
    X = np.stack(present)
    mean = X.mean(axis=0)
    std = X.std(axis=0)
    std = np.where(std < 1e-9, 1.0, std)
    return mean, std


# ---------------------------------------------------------------------------
# Generic head probabilities
# ---------------------------------------------------------------------------

def _generic_probs(window: WindowPrediction, classes: Sequence[str]) -> np.ndarray:
    """Head posterior over ``classes`` from the window's HART probabilities
    (renormalized over the head simplex; uniform when no usable probs)."""
    if not window.probs:
        return np.full(len(classes), 1.0 / len(classes))
    from .labels import HART_LABEL_TO_HEADS
    q = np.zeros(len(classes), dtype=np.float64)
    for src_label, p in window.probs:
        mapped = HART_LABEL_TO_HEADS.get(src_label)
        if mapped is None:
            continue
        hv = mapped.get("locomotion")
        if hv in classes:
            q[classes.index(hv)] += p
    z = q.sum()
    if z <= 0:
        return np.full(len(classes), 1.0 / len(classes))
    return q / z


def _softmax(z: np.ndarray, temperature: float) -> np.ndarray:
    z = np.asarray(z, dtype=np.float64) / max(temperature, 1e-9)
    z = z - z.max()
    e = np.exp(z)
    return e / e.sum()


def _nll(probs: np.ndarray, y_onehot: np.ndarray) -> float:
    p = np.clip(probs, 1e-12, 1.0)
    return float(-np.sum(y_onehot * np.log(p)))


# ---------------------------------------------------------------------------
# Personalizer (closed-form ridge one-vs-rest + temperature + abstention)
# ---------------------------------------------------------------------------

@dataclass
class Personalizer:
    """Fitted per-user head. All fit state is deterministic (closed-form)."""

    user: str
    classes: Tuple[str, ...]
    weights: np.ndarray                 # (K, d+1); last column = intercept
    temperature: float
    abstain_threshold: float
    feature_mean: np.ndarray
    feature_std: np.ndarray
    n_train_windows: int
    n_train_sessions: int

    def predict(self, window: WindowPrediction) -> Optional[str]:
        """Personalized prediction for one window (or an EvalUnit), or None
        (abstain).

        Preference order: the logistic probe on imu-feat-1 features when the
        window has them; else the temperature-calibrated generic head. The
        probe's max probability is gated by the abstention threshold."""
        from .labels import EvalUnit as _EvalUnit
        if isinstance(window, _EvalUnit):
            window = window.window
        classes = self.classes
        vec = feature_vector(window)
        if vec is not None:
            x = (vec - self.feature_mean) / self.feature_std
            x = np.append(x, 1.0)                      # intercept
            scores = self.weights @ x
            prob = _softmax(scores, self.temperature)
        else:
            prob = _generic_probs(window, classes)
            if self.temperature != 1.0:
                prob = _softmax(np.log(np.clip(prob, 1e-12, 1.0)),
                                self.temperature)
        if prob.max() < self.abstain_threshold:
            return None
        return classes[int(prob.argmax())]


def _fit_temperature(
    units: Sequence[EvalUnit], classes: Sequence[str]
) -> float:
    """One-scalar temperature minimizing cross-entropy of the GENERIC head
    probabilities on the fit split (golden-section search, deterministic)."""
    ys = np.zeros((len(units), len(classes)))
    logs = np.zeros((len(units), len(classes)))
    for i, u in enumerate(units):
        p = _generic_probs(u.window, classes)
        logs[i] = np.log(np.clip(p, 1e-12, 1.0))
        ys[i, classes.index(u.truth)] = 1.0
    if len(units) == 0:
        return 1.0

    def loss(t: float) -> float:
        z = logs / max(t, 1e-9)
        z = z - z.max(axis=1, keepdims=True)
        e = np.exp(z)
        p = e / e.sum(axis=1, keepdims=True)
        return float(-np.sum(ys * np.log(np.clip(p, 1e-12, 1.0))))

    lo, hi = 0.1, 5.0
    gr = (np.sqrt(5.0) - 1.0) / 2.0
    c = hi - gr * (hi - lo)
    d = lo + gr * (hi - lo)
    fc, fd = loss(c), loss(d)
    for _ in range(40):
        if fc < fd:
            hi, d, fd = d, c, fc
            c = hi - gr * (hi - lo)
            fc = loss(c)
        else:
            lo, c, fc = c, d, fd
            d = lo + gr * (hi - lo)
            fd = loss(d)
    return float((lo + hi) / 2.0)


def _fit_abstain_threshold(
    units: Sequence[EvalUnit], personalizer: "Personalizer"
) -> float:
    """Abstention threshold maximizing accepted macro-F1 on the fit split
    (deterministic grid over ABSTAIN_GRID; ties -> most permissive)."""
    best = 0.0
    best_score = -1.0
    for theta in ABSTAIN_GRID:
        preds = []
        for u in units:
            vec = feature_vector(u.window)
            if vec is None:
                preds.append(None)
                continue
            x = np.append((vec - personalizer.feature_mean) / personalizer.feature_std, 1.0)
            scores = personalizer.weights @ x
            prob = _softmax(scores, personalizer.temperature)
            preds.append(personalizer.classes[int(prob.argmax())] if prob.max() >= theta else None)
        from .labels import confusion_matrix, macro_f1, prf_per_class
        classes = list(personalizer.classes)
        conf, _ = confusion_matrix([u.truth for u in units], preds, classes)
        pc = prf_per_class(conf, classes)
        score = macro_f1(pc)
        if score > best_score:
            best_score = score
            best = theta
    return best


def fit_personalizer(
    user: str, units: Sequence[EvalUnit], seed: int = SEED
) -> Personalizer:
    """Fit the per-user head on ``units`` (the FIT split). Closed-form ridge
    one-vs-rest over imu-feat-1 features; temperature + abstention threshold
    calibrated on the same fit split. Deterministic (seed stored, used only
    for tie-breaks)."""
    rng = np.random.default_rng(seed)
    classes = tuple(sorted({u.truth for u in units}))
    rows = [feature_vector(u.window) for u in units]
    mean, std = _fit_scaler(rows)
    Xs: List[np.ndarray] = []
    ys: List[np.ndarray] = []
    for u, vec in zip(units, rows):
        if vec is None or not np.isfinite(vec).all():
            continue
        x = np.append((vec - mean) / std, 1.0)
        y = np.zeros(len(classes))
        y[classes.index(u.truth)] = 1.0
        Xs.append(x)
        ys.append(y)
    if not Xs:
        raise ValueError("no usable feature rows for personalization fit")
    X = np.stack(Xs)
    Y = np.stack(ys)
    XtX = X.T @ X + RIDGE_LAMBDA * np.eye(X.shape[1])
    weights = np.linalg.solve(XtX, X.T @ Y).T      # (K, d+1)

    temperature = _fit_temperature(units, classes)
    base = Personalizer(
        user=user, classes=classes, weights=weights, temperature=temperature,
        abstain_threshold=0.5, feature_mean=mean, feature_std=std,
        n_train_windows=len(units),
        n_train_sessions=len({u.session for u in units}),
    )
    abstain = _fit_abstain_threshold(units, base)
    return Personalizer(
        user=user, classes=classes, weights=weights, temperature=temperature,
        abstain_threshold=abstain, feature_mean=mean, feature_std=std,
        n_train_windows=len(units),
        n_train_sessions=len({u.session for u in units}),
    )


def _per_class_f1(units: Sequence[EvalUnit], predict_fn) -> Dict[str, Any]:
    """Per-class P/R/F1 + macro over ACCEPTED predictions (abstention is a
    decision, not a class — methodology 2.2 choice A)."""
    from .labels import confusion_matrix, macro_f1, prf_per_class
    classes = sorted({u.truth for u in units} |
                     {p for p in (predict_fn(u) for u in units) if p is not None})
    preds = [predict_fn(u) for u in units]
    conf, _ = confusion_matrix([u.truth for u in units], preds, classes)
    pc = prf_per_class(conf, classes)
    n = len(units)
    n_abstained = sum(1 for p in preds if p is None)
    return {
        "n_units": n,
        "n_accepted": n - n_abstained,
        "n_abstained": n_abstained,
        "abstention_rate": round(n_abstained / n, 6) if n else 0.0,
        "accepted_coverage": round((n - n_abstained) / n, 6) if n else 0.0,
        "per_class": pc,
        "macro_f1": round(macro_f1(pc), 6),
    }


def generic_predict(u: EvalUnit) -> Optional[str]:
    """The generic head: the window label projected onto locomotion (None =
    abstain)."""
    return u.window.head_value


def evaluate_user(
    user: str,
    train_units: Sequence[EvalUnit],
    test_units: Sequence[EvalUnit],
    seed: int = SEED,
) -> Dict[str, Any]:
    """Run one user's shadow evaluation: gates -> fit -> generic vs
    personalized on the held-out sessions."""
    classes = sorted({u.truth for u in train_units} | {u.truth for u in test_units})
    per_class_gate: Dict[str, Dict[str, Any]] = {}
    failed: List[str] = []
    for c in classes:
        c_units = [u for u in train_units if u.truth == c]
        n_windows = len(c_units)
        n_sessions = len({u.session for u in c_units})
        met = n_windows >= MIN_WINDOWS_PER_CLASS and n_sessions >= MIN_SESSIONS_PER_CLASS
        per_class_gate[c] = {
            "n_fit_windows": n_windows,
            "n_fit_sessions": n_sessions,
            "gate": f">= {MIN_WINDOWS_PER_CLASS} windows and >= {MIN_SESSIONS_PER_CLASS} sessions",
            "met": met,
        }
        if not met:
            failed.append(c)

    report: Dict[str, Any] = {
        "user": user,
        "classes": classes,
        "gates": per_class_gate,
        "n_fit_windows": len(train_units),
        "n_fit_sessions": len({u.session for u in train_units}),
        "n_heldout_windows": len(test_units),
        "n_heldout_sessions": len({u.session for u in test_units}),
        "generic": _per_class_f1(test_units, generic_predict),
    }
    if failed:
        report["status"] = "insufficient_evidence"
        report["failed_classes"] = failed
        report["personalized"] = None
        return report

    personalizer = fit_personalizer(user, train_units, seed=seed)
    personalized = _per_class_f1(test_units, personalizer.predict)
    delta: Dict[str, float] = {}
    for c in classes:
        g = report["generic"]["per_class"].get(c, {}).get("f1", 0.0)
        p = personalized["per_class"].get(c, {}).get("f1", 0.0)
        delta[c] = round(p - g, 6)
    report["status"] = "fit"
    report["personalized"] = personalized
    report["delta_f1"] = delta
    report["delta_macro_f1"] = round(
        personalized["macro_f1"] - report["generic"]["macro_f1"], 6)
    report["model"] = {
        "temperature": round(personalizer.temperature, 6),
        "abstain_threshold": round(personalizer.abstain_threshold, 6),
        "ridge_lambda": RIDGE_LAMBDA,
        "seed": seed,
        "features": list(FEATURE_KEYS),
    }
    return report


# ---------------------------------------------------------------------------
# Orchestration + CLI
# ---------------------------------------------------------------------------

def build_user_groups(labels: Sequence[LabelRecord]) -> Dict[str, List[LabelRecord]]:
    """Group labels per user. Owner is unknown at this layer: when ANY label
    carries a ``user_id``, group by it; otherwise everything is one subject
    ("all")."""
    has_user = any(l.user_id for l in labels)
    if not has_user:
        return {"all": list(labels)}
    groups: Dict[str, List[LabelRecord]] = {}
    for l in labels:
        groups.setdefault(l.user_id or "unknown", []).append(l)
    return groups


def run_personalization(
    labels: Sequence[LabelRecord],
    windows: Sequence[WindowPrediction],
    *,
    include_weak: bool = False,
    include_degraded: bool = False,
    holdout_sessions: int = 1,
    seed: int = SEED,
    model: str = "hart",
) -> Dict[str, Any]:
    """Shadow-only personalization over all users (spec 11).

    Returns per-user reports; a user whose evidence fails the gates is
    ``insufficient_evidence`` (with the failed classes listed) and gets NO
    personalized model. Deterministic.
    """
    results: Dict[str, Any] = {"seed": seed, "users": {}}
    groups = build_user_groups(labels)
    for user, user_labels in sorted(groups.items()):
        sel = user_labels if include_weak else [l for l in user_labels
                                                if l.is_strong]
        units, counts = assign_units(
            sel, windows,
            include_degraded=include_degraded,
            include_weak=include_weak,
            model=model,
        )
        # The locomotion head is the personalization target (spec 11.1).
        loc_units = [u for u in units if u.head == "locomotion"]
        sessions = {u.session for u in loc_units}
        if len(sessions) < MIN_SESSIONS:
            results["users"][user] = {
                "status": "insufficient_evidence",
                "reason": f"fewer than {MIN_SESSIONS} sessions "
                          f"({len(sessions)} found)",
                "n_fit_windows": len(loc_units),
                "n_heldout_windows": 0,
                "failed_classes": [],
                "classes": sorted({u.truth for u in loc_units}),
            }
            continue
        split = split_by_session(
            user_labels, loc_units,
            holdout_sessions=holdout_sessions,
            mode="holdout",
        )
        report = evaluate_user(
            user,
            split.train_units,
            split.test_units,
            seed=seed,
        )
        report["split"] = {
            "train_sessions": list(split.train_sessions),
            "test_sessions": list(split.test_sessions),
            "mode": "holdout",
            "holdout_sessions": holdout_sessions,
        }
        results["users"][user] = report
    return results


def render_personalize_markdown(report: Dict[str, Any]) -> str:
    lines: List[str] = ["# Shadow personalization (session-held-out)", ""]
    lines.append(f"seed: {report.get('seed')} — deterministic, closed-form "
                 "ridge probe, NO production wiring")
    lines.append("")
    for user in sorted(report.get("users", {})):
        u = report["users"][user]
        lines.append(f"## user: `{user}`")
        lines.append("")
        if u.get("status") == "insufficient_evidence":
            lines.append(f"- **status**: insufficient_evidence")
            lines.append(f"- reason: {u.get('reason') or 'evidence gates not met'}")
            failed = u.get("failed_classes") or []
            if failed:
                lines.append(f"- failed classes: {', '.join(failed)}")
            lines.append("- personalized model: NOT fitted (refused)")
            lines.append("")
            continue
        lines.append(f"- status: fit")
        lines.append(f"- fit windows: {u.get('n_fit_windows')} across "
                     f"{u.get('n_fit_sessions')} sessions | held-out windows: "
                     f"{u.get('n_heldout_windows')} across {u.get('n_heldout_sessions')} sessions")
        lines.append(f"- train sessions: {', '.join(u['split']['train_sessions'])}")
        lines.append(f"- test sessions: {', '.join(u['split']['test_sessions'])}")
        lines.append("")
        lines.append("### Gates (per class, fit split)")
        lines.append("")
        lines.append("| class | fit windows | fit sessions | met |")
        lines.append("|---|---|---|---|")
        for c in sorted(u.get("gates", {})):
            g = u["gates"][c]
            lines.append(f"| {c} | {g['n_fit_windows']} | {g['n_fit_sessions']} | "
                         f"{'yes' if g['met'] else 'NO'} |")
        lines.append("")
        lines.append("### Generic vs personalized (held-out sessions, accepted)")
        lines.append("")
        lines.append("| class | generic F1 | personalized F1 | delta |")
        lines.append("|---|---|---|---|")
        for c in sorted(u.get("classes", [])):
            g = u["generic"]["per_class"].get(c, {}).get("f1", 0.0)
            p = (u.get("personalized") or {}).get("per_class", {}).get(c, {}).get("f1", 0.0)
            d = u.get("delta_f1", {}).get(c, 0.0)
            lines.append(f"| {c} | {g:.4f} | {p:.4f} | {d:+.4f} |")
        lines.append(f"| **macro-F1** | {u['generic']['macro_f1']:.4f} | "
                     f"{(u.get('personalized') or {}).get('macro_f1', 0.0):.4f} | "
                     f"{u.get('delta_macro_f1', 0.0):+.4f} |")
        lines.append(f"| abstention rate | {u['generic']['abstention_rate']:.4f} | "
                     f"{(u.get('personalized') or {}).get('abstention_rate', 0.0):.4f} | — |")
        lines.append("")
        m = u.get("model") or {}
        lines.append(f"- temperature: {m.get('temperature')} | "
                     f"abstain threshold: {m.get('abstain_threshold')} | "
                     f"ridge lambda: {m.get('ridge_lambda')}")
        lines.append("")
    return "\n".join(lines)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="Shadow-only per-user personalization (spec 11)")
    ap.add_argument("--labels", required=True)
    ap.add_argument("--windows", action="append", required=True, metavar="PATH",
                    help="hart-windows-1 day document (repeatable)")
    ap.add_argument("--out", required=True, help="output dir for report.json "
                    "and report.md")
    ap.add_argument("--holdout-sessions", type=int, default=1)
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--include-weak", action="store_true")
    ap.add_argument("--include-degraded", action="store_true")
    args = ap.parse_args(argv)

    labels, label_report = load_labels(args.labels)
    windows: List[WindowPrediction] = []
    for p in args.windows:
        with open(p, "r", encoding="utf-8") as f:
            wins, _rep = parse_day_doc(json.load(f), p)
        windows.extend(wins)

    report = run_personalization(
        labels, windows,
        include_weak=args.include_weak,
        include_degraded=args.include_degraded,
        holdout_sessions=args.holdout_sessions,
        seed=args.seed,
    )
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, default=str)
    with open(os.path.join(args.out, "report.md"), "w", encoding="utf-8") as f:
        f.write(render_personalize_markdown(report) + "\n")
    for user, u in sorted(report["users"].items()):
        status = u.get("status")
        print(f"user {user}: {status}")
        if status == "fit":
            print(f"  macro-F1 delta: {u.get('delta_macro_f1'):+.4f} "
                  f"(generic {u['generic']['macro_f1']:.4f} -> "
                  f"{u['personalized']['macro_f1']:.4f})")
        elif u.get("failed_classes"):
            print(f"  failed classes: {', '.join(u['failed_classes'])}")
    print(f"report: {os.path.join(args.out, 'report.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
