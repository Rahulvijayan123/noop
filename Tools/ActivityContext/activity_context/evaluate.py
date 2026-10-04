"""activity-evaluate — held-out evaluation with abstention (spec s12).

Consumes the eval_data.npz produced by activity-train (held-out TEST SUBJECTS,
windowed only after the subject/session split), runs the baseline or HART
model, applies the manifest abstention thresholds (max_prob 0.80 / margin
0.15 by default), and reports:

  * per-class precision / recall / F1 over ACCEPTED predictions
  * confusion matrix (ontology labels incl. unknown)
  * acceptance coverage and per-class counts by subject/session
  * transition delay (seconds to correct the prediction after a ground-truth
    label change) — the temporal policy lives on the Swift side; this reports
    the per-window classifier's raw delay for comparison.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from typing import Dict, List, Optional, Tuple

import numpy as np

from .baseline import MOTION_LABELS, classify_window
from .manifest import Manifest, load_manifest
from .preprocess import HOP_SECONDS


def build_predictor(manifest: Manifest, checkpoint_dir: Optional[str]):
    """Return callable(window_data (120,6)) -> (label, probs).

    Exactly ONE model forward per window (the previous double call made the
    HART path do two inferences per window).
    """
    from .preprocess import Window

    def _data(x):
        return x.data if isinstance(x, Window) else x

    if manifest.model_kind == "hart":
        from .model import HARTModel
        if not checkpoint_dir or not os.path.isdir(checkpoint_dir):
            raise SystemExit("model_kind=hart requires --checkpoint <dir>")
        model = HARTModel(manifest, checkpoint_dir)

        def _pred(w):
            p = model.predict_window(_data(w))
            return p.label, p.probs
        return _pred

    def _pred(w):
        res = classify_window(_as_window(_data(w)))
        return res.label, res.probs
    return _pred


def _as_window(x):
    from .preprocess import Window
    if isinstance(x, Window):
        return x
    return Window(s=0.0, e=4.0, data=np.asarray(x, dtype=np.float64))


def _f1(p: float, r: float) -> float:
    return 0.0 if (p + r) == 0 else 2 * p * r / (p + r)


def _macro_f1(per_class: Dict) -> float:
    """Macro-F1 over the four SUPPORTED coarse classes (spec s12 target)."""
    f1s = [per_class[c]["f1"] for c in ("stationary", "walking", "running",
                                        "other_movement")]
    return round(float(np.mean(f1s)), 4)


def evaluate(x: np.ndarray, y_ontology: np.ndarray, predictor,
             thresholds: Dict[str, float],
             letters: Optional[np.ndarray] = None,
             subjects: Optional[np.ndarray] = None,
             sessions: Optional[np.ndarray] = None) -> Dict:
    labels = list(MOTION_LABELS)
    conf = {t: {u: 0 for u in labels} for t in labels}
    preds: List[str] = []
    accepted = 0
    for i in range(len(x)):
        label, _probs = predictor(x[i])
        preds.append(label)
        conf[y_ontology[i]][label] += 1
        if label != "unknown":
            accepted += 1

    results = {}
    for t in labels:
        tp = conf[t][t]
        fp = sum(conf[g][t] for g in labels if g != t)
        fn = sum(conf[t][u] for u in labels if u != t)
        p = tp / (tp + fp) if (tp + fp) else 0.0
        r = tp / (tp + fn) if (tp + fn) else 0.0
        results[t] = {"tp": tp, "fp": fp, "fn": fn,
                      "precision": round(p, 4), "recall": round(r, 4),
                      "f1": round(_f1(p, r), 4),
                      "count": int(np.sum(y_ontology == t))}

    coverage = accepted / len(x) if len(x) else 0.0
    smoothed = smooth_predictions(preds, sessions=sessions)
    transition_delay = _transition_delay(y_ontology, preds)
    transition_delay_policy = _transition_delay(y_ontology, preds, smoothed)
    report = {
        "n_windows": int(len(x)),
        "n_accepted": accepted,
        "coverage": round(coverage, 4),
        "macro_f1_supported": _macro_f1(results),
        "thresholds": thresholds,
        "per_class": results,
        "confusion": conf,
        "transition_delay_s": transition_delay,
        "transition_delay_policy_s": transition_delay_policy,
        "prediction_counts": dict(Counter(preds)),
    }

    # Per-subject breakdown (held-out TEST subjects) + session counts.
    if subjects is not None and len(subjects) == len(x):
        per_subject: Dict[str, Dict] = {}
        for s in sorted(set(int(v) for v in subjects)):
            m = subjects == s
            n = int(m.sum())
            n_acc = int(np.sum([m[i] and preds[i] != "unknown"
                                for i in range(len(x))]))
            per_subject[str(s)] = {
                "windows": n,
                "accepted": n_acc,
                "coverage": round(n_acc / n, 4) if n else 0.0,
                "sessions": int(len(set(int(v) for v in sessions[m])))
                if sessions is not None else None,
                "prediction_counts": dict(Counter(
                    preds[i] for i in range(len(x)) if m[i])),
            }
        report["per_subject"] = per_subject
        report["n_test_subjects"] = len(per_subject)

    # Per WISDM-letter breakdown (incl. the C10 disagreement cases F/Q/R/S and
    # the spec s12 negative-control inspection on typing/writing).
    if letters is not None and len(letters) == len(x):
        per_letter: Dict[str, Dict] = {}
        for letter in sorted({str(v) for v in letters}):
            m = letters == letter
            n = int(m.sum())
            n_acc = int(np.sum([m[i] and preds[i] != "unknown"
                                for i in range(len(x))]))
            per_letter[letter] = {
                "windows": n,
                "accepted": n_acc,
                "coverage": round(n_acc / n, 4) if n else 0.0,
                "ontology": str(np.unique(y_ontology[m])[0]),
                "prediction_counts": dict(Counter(
                    preds[i] for i in range(len(x)) if m[i])),
            }
        report["per_letter"] = per_letter
    return report


# Swift ActivityPolicyConfig constants (ActivityContextPolicy.swift) that the
# Python per-window classifier cannot import — mirrored for the delay report.
POLICY_REQUIRED_CONSECUTIVE_VOTES = 2
POLICY_GAP_RESET_SECONDS = 4


def smooth_predictions(preds: List[str],
                       required_votes: int = POLICY_REQUIRED_CONSECUTIVE_VOTES,
                       gap_reset_seconds: int = POLICY_GAP_RESET_SECONDS,
                       sessions: Optional[np.ndarray] = None,
                       ) -> List[str]:
    """Causal vote/hysteresis mirroring the Swift policy (spec s8): a label
    flip needs `required_votes` consecutive disagreeing accepted windows; an
    abstaining (unknown) window does not vote; history resets when a window
    starts more than `gap_reset_seconds` after the previous one. When `sessions`
    (block indices) is given, a session change is treated as a gap reset too —
    the eval windows carry no timestamps, and WISDM blocks are separated by
    >1 s recording pauses (train.py splits sessions at >1 s gaps)."""
    smoothed: List[str] = []
    cur: Optional[str] = None
    pending: Optional[Tuple[str, int]] = None
    prev_start: Optional[float] = None
    prev_sess: Optional[int] = None
    for i, p in enumerate(preds):
        start = i * HOP_SECONDS
        sess = int(sessions[i]) if sessions is not None else None
        if (prev_start is not None and start - prev_start > gap_reset_seconds) or                 (sessions is not None and prev_sess is not None and sess != prev_sess):
            cur, pending = None, None
        if p == "unknown":
            smoothed.append(cur if cur is not None else "unknown")
        else:
            if cur is None:
                cur, pending = p, None
            elif p == cur:
                pending = None
            else:
                if pending is None or pending[0] != p:
                    pending = (p, 1)
                else:
                    pending = (p, pending[1] + 1)
                if pending[1] >= required_votes:
                    cur, pending = p, None
            smoothed.append(cur)
        prev_start = start
        prev_sess = sess
    return smoothed


def _transition_delay(y: np.ndarray, preds: List[str],
                      smoothed: Optional[List[str]] = None) -> Dict:
    """Mean/median/p90 delay (seconds) to first accepted correct prediction
    after each ground-truth transition.

    `preds` is the raw per-window classifier; `smoothed` (when given) is the
    causal vote/hysteresis output (the temporal policy that actually ships on
    the Swift side, spec s8 / ActivityPolicyConfig). Windows are 4 s on a 2 s
    hop, so the minimum observable delay is 2 s.
    """
    delays = []
    prev = None
    for i in range(len(y)):
        if y[i] != prev and prev is not None:
            target = y[i]
            for j in range(i, len(y)):
                if (smoothed if smoothed is not None else preds)[j] == target:
                    delays.append((j - i) * HOP_SECONDS)
                    break
        prev = y[i]
    if not delays:
        return {"n_transitions": 0}
    return {"n_transitions": len(delays),
            "mean_s": round(float(np.mean(delays)), 3),
            "median_s": round(float(np.median(delays)), 3),
            "p90_s": round(float(np.percentile(delays, 90)), 3)}


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara held-out activity evaluation")
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--data", required=True, help="eval_data.npz from activity-train")
    ap.add_argument("--checkpoint", default=None)
    ap.add_argument("--out", default=None, help="write JSON report to file")
    args = ap.parse_args(argv)

    manifest = load_manifest(args.manifest)
    if not os.path.isfile(args.data):
        raise SystemExit(f"eval data not found: {args.data}")
    z = np.load(args.data, allow_pickle=True)
    x = z["X"]
    y = z["y_ontology"]
    letters = z["letters"] if "letters" in z else None
    subjects = z["subjects"] if "subjects" in z else None
    sessions = z["sessions"] if "sessions" in z else None
    predictor = build_predictor(manifest, args.checkpoint)
    report = evaluate(x, y, predictor, manifest.thresholds,
                      letters=letters, subjects=subjects, sessions=sessions)
    report["model_version"] = manifest.model_version
    report["model_kind"] = manifest.model_kind

    text = json.dumps(report, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
