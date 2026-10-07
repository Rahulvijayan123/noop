"""activity-evaluate — held-out evaluation with abstention (spec s12).

Consumes the eval_data.npz produced by activity-train (held-out TEST SUBJECTS,
windowed only after the subject/session split), runs the baseline or HART
model, applies the manifest abstention thresholds (max_prob 0.80 / margin
0.15 by default), and reports:

  * per-class precision / recall / F1 over ACCEPTED predictions
  * confusion matrix (ontology labels incl. unknown)
  * acceptance coverage and per-class counts by subject/session
  * session-aware transition metrics (spec s12 / audit A03): only genuine
    WITHIN-session ground-truth changes count as transitions; concatenated
    constant blocks never create one. Undetected transitions are counted as
    misses and CENSORED at the session end (never scanned into a later
    session, never silently omitted); detected ones report latency
    (mean/median/p50/p90/p95) plus a signed onset error. Real per-window
    timestamps persisted by activity-train (eval_data.npz "starts") are used
    when present; legacy artifacts without them fall back to fabricated
    i*HOP_SECONDS spacing and the report flags timestamps=fabricated.
  * the temporal policy lives on the Swift side (ActivityContextPolicy); this
    reports the per-window classifier's raw delay AND the Python vote mirror
    (smooth_predictions) delay for comparison. smooth_predictions is an
    APPROXIMATION of the Swift policy, never a certificate (spec A04).
  * ``transition_delay_censored_s`` stops the recovery search at the next truth
    change and counts those transitions as missed.
  * calibration of the window probabilities over the four supported classes
    (NLL, Brier, top-label ECE) — HART's raw softmax is consumed as if it were
    calibrated; these numbers say whether it is. ``fit_temperature`` fits a
    temperature on held-out logits for reporting (nothing in serve changes).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from collections import Counter
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .baseline import MOTION_LABELS, classify_window
from .manifest import Manifest, load_manifest
from .preprocess import HOP_SECONDS, WINDOW_SECONDS


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


SUPPORTED = ("stationary", "walking", "running", "other_movement")


def supported_probs(probs: Dict[str, float]) -> np.ndarray:
    """(4,) probabilities over SUPPORTED, renormalized (mass on 'unknown' is dropped).

    HART's ontology probs already sum to 1 over the four classes. The baseline's
    heuristic one-hot may put its mass on 'unknown'; that row becomes uniform."""
    v = np.asarray([float(probs.get(c, 0.0)) for c in SUPPORTED], dtype=np.float64)
    tot = v.sum()
    return v / tot if tot > 0 else np.full(len(SUPPORTED), 1.0 / len(SUPPORTED))


def calibration_metrics(p: np.ndarray, y: np.ndarray, n_bins: int = 15) -> Dict[str, float]:
    """NLL, Brier and top-label ECE of probability rows ``p`` (N, C) against labels ``y`` (N,).

    NLL = mean -log p[y] (p clipped at 1e-12); Brier = mean sum_c (p_c - 1[y=c])^2; ECE =
    sum over ``n_bins`` equal-width confidence bins of (bin share) * |accuracy - mean confidence|
    of the top label. Rows whose label is outside 0..C-1 are ignored."""
    p = np.asarray(p, dtype=np.float64)
    y = np.asarray(y, dtype=np.int64)
    ok = (y >= 0) & (y < p.shape[1])
    p, y = p[ok], y[ok]
    n = len(y)
    if n == 0:
        return {"n": 0}
    pt = np.clip(p[np.arange(n), y], 1e-12, 1.0)
    onehot = np.zeros_like(p)
    onehot[np.arange(n), y] = 1.0
    conf = p.max(axis=1)
    pred = p.argmax(axis=1)
    correct = (pred == y).astype(np.float64)
    edges = np.linspace(0.0, 1.0, n_bins + 1)
    idx = np.clip(np.digitize(conf, edges[1:-1], right=True), 0, n_bins - 1)
    ece = 0.0
    bins = []
    for b in range(n_bins):
        m = idx == b
        if not m.any():
            continue
        gap = abs(correct[m].mean() - conf[m].mean())
        ece += m.mean() * gap
        bins.append({"lo": round(float(edges[b]), 4), "hi": round(float(edges[b + 1]), 4),
                     "n": int(m.sum()), "accuracy": round(float(correct[m].mean()), 4),
                     "confidence": round(float(conf[m].mean()), 4)})
    return {"n": int(n), "nll": round(float(-np.log(pt).mean()), 4),
            "brier": round(float(((p - onehot) ** 2).sum(axis=1).mean()), 4),
            "ece": round(float(ece), 4), "accuracy_top1": round(float(correct.mean()), 4),
            "mean_confidence": round(float(conf.mean()), 4), "n_bins": n_bins,
            "reliability": bins}


def aggregate_softmax(logits: np.ndarray, groups: np.ndarray, n_groups: int,
                      temperature: float = 1.0) -> np.ndarray:
    """softmax(logits / T) summed into ``n_groups`` classes: column k of logits -> groups[k]."""
    z = np.asarray(logits, dtype=np.float64) / float(temperature)
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    sm = e / e.sum(axis=1, keepdims=True)
    out = np.zeros((sm.shape[0], n_groups), dtype=np.float64)
    for k, g in enumerate(groups):
        out[:, int(g)] += sm[:, k]
    return out


def fit_temperature(logits: np.ndarray, y: np.ndarray, groups: np.ndarray, n_groups: int,
                    lo: float = 0.05, hi: float = 20.0, iters: int = 100) -> float:
    """Temperature minimizing the NLL of the aggregated (grouped) softmax, by golden-section
    search on log T (the NLL of a temperature-scaled softmax is unimodal in practice)."""
    y = np.asarray(y, dtype=np.int64)
    rows = np.arange(len(y))

    def nll(log_t: float) -> float:
        q = aggregate_softmax(logits, groups, n_groups, math.exp(log_t))
        return float(-np.log(np.clip(q[rows, y], 1e-12, 1.0)).mean())

    a, b = math.log(lo), math.log(hi)
    g = (math.sqrt(5.0) - 1.0) / 2.0
    c, d = b - g * (b - a), a + g * (b - a)
    fc, fd = nll(c), nll(d)
    for _ in range(iters):
        if fc < fd:
            b, d, fd = d, c, fc
            c = b - g * (b - a)
            fc = nll(c)
        else:
            a, c, fc = c, d, fd
            d = a + g * (b - a)
            fd = nll(d)
        if b - a < 1e-6:
            break
    return float(math.exp((a + b) / 2.0))


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
             sessions: Optional[np.ndarray] = None,
             starts: Optional[np.ndarray] = None) -> Dict:
    """Run per-window evaluation + session-aware transition metrics.

    `starts` carries the real per-window start times (seconds) persisted by
    activity-train; when None the transition report uses fabricated i*HOP_SECONDS
    spacing and flags timestamps=fabricated (legacy artifact, audit WS-07-F03).
    """
    labels = list(MOTION_LABELS)
    conf = {t: {u: 0 for u in labels} for t in labels}
    preds: List[str] = []
    prob_rows: List[np.ndarray] = []
    accepted = 0
    for i in range(len(x)):
        label, probs = predictor(x[i])
        preds.append(label)
        prob_rows.append(supported_probs(probs))
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
    smoothed = smooth_predictions(preds, sessions=sessions, starts=starts)
    transition_delay = _transition_delay(y_ontology, preds,
                                         sessions=sessions, starts=starts)
    transition_delay_policy = _transition_delay(y_ontology, preds, smoothed,
                                                sessions=sessions, starts=starts)
    y_idx = np.asarray([SUPPORTED.index(str(t)) if str(t) in SUPPORTED else -1
                        for t in y_ontology], dtype=np.int64)
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
        "transition_delay_censored_s": transition_delay_censored(y_ontology, preds),
        "transition_delay_censored_policy_s": transition_delay_censored(y_ontology, smoothed),
        "accepted_precision": accepted_precision(conf),
        "calibration": calibration_metrics(np.stack(prob_rows) if prob_rows
                                           else np.zeros((0, len(SUPPORTED))), y_idx),
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
                       starts: Optional[np.ndarray] = None,
                       ) -> List[str]:
    """Causal vote/hysteresis mirror of the Swift ActivityContextPolicy.

    APPROXIMATION ONLY — never a certificate (spec A04, audit WS-07-F04): the
    deployed Swift path (ActivityContextPolicy.buildEpochs) additionally folds
    per-window votes into 30-s UTC epochs with per-second accounting, and its
    gap reset compares a window's start against the PREVIOUS WINDOW'S END
    (start > prev_end + gapResetSeconds) while this mirror compares window
    starts (start - prev_start > gapResetSeconds). Do not use these numbers to
    certify Swift temporal behavior.

    A label flip needs `required_votes` consecutive disagreeing accepted
    windows; an abstaining (unknown) window does not vote and never invents
    coverage (audit WS-07-F11); history resets when a window starts more than
    `gap_reset_seconds` after the previous one, and when a `sessions` (block
    index) change occurs. `starts` (real per-window start times, seconds) is
    used for the gap test when present; otherwise fabricated i*HOP_SECONDS
    spacing is assumed (legacy eval_data.npz, audit WS-07-F03)."""
    smoothed: List[str] = []
    cur: Optional[str] = None
    pending: Optional[Tuple[str, int]] = None
    prev_start: Optional[float] = None
    prev_sess: Optional[int] = None
    for i, p in enumerate(preds):
        start = float(starts[i]) if starts is not None else i * HOP_SECONDS
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
                      smoothed: Optional[List[str]] = None,
                      sessions: Optional[np.ndarray] = None,
                      starts: Optional[np.ndarray] = None) -> Dict:
    """Session-aware transition latency with censoring (spec s12 / audit A03).

    Evaluates ONLY ground-truth label changes that occur INSIDE one contiguous
    session (`sessions` = per-window block index). A session boundary is never
    a transition: concatenating unrelated constant blocks must not invent one
    (spec s12 "Do not create transitions by concatenating unrelated blocks").

    For each genuine within-session transition at window i (truth A->B):
      * the search for the first accepted correct prediction runs ONLY within
        the same session (windows [i, session_end)) — never into a later
        session, never silently omitted (audit WS-07-F01/F02);
      * a match before the session ends is DETECTED: delay = (prediction start
        - truth-change start), and a signed onset error = (start of the
        contiguous B-run containing the match - truth-change start), which is
        negative when the policy/classifier flipped BEFORE the truth change;
      * no match by the end of the session's last window is a MISS, CENSORED
        at the session end (right-censored: only the horizon is known, the
        detection time is not); it counts toward both n_misses and n_censored.

    `preds` is the raw per-window classifier; `smoothed` (when given) is the
    causal vote/hysteresis output (the Python policy mirror). `starts` carries
    real per-window start times (seconds) when present; otherwise fabricated
    i*HOP_SECONDS spacing is used and the report flags timestamps=fabricated.
    Windows are 4 s on a 2 s hop, so the minimum observable delay is 2 s.
    """
    series = smoothed if smoothed is not None else preds
    n = len(y)
    if sessions is None:
        sess_arr = np.zeros(n, dtype=np.int64)          # whole series = one session
    else:
        sess_arr = np.asarray(sessions, dtype=np.int64)
    if starts is None:
        starts_arr = np.arange(n, dtype=np.float64) * HOP_SECONDS
        timestamps = "fabricated"
    else:
        starts_arr = np.asarray(starts, dtype=np.float64)
        timestamps = "real"

    delays: List[float] = []
    onset_errors: List[float] = []
    horizons: List[float] = []
    n_transitions = n_detected = n_misses = n_censored = 0
    prev = None
    prev_sess = None
    for i in range(n):
        sess = int(sess_arr[i])
        if prev_sess is not None and sess != prev_sess:
            prev = None            # session boundary: previous label is meaningless
        if prev is not None and y[i] != prev:
            # Genuine within-session ground-truth transition at window i.
            n_transitions += 1
            target = y[i]
            # Search bound = first window of a LATER session (session end).
            j_end = n
            for j in range(i + 1, n):
                if int(sess_arr[j]) != sess:
                    j_end = j
                    break
            found = None
            for j in range(i, j_end):
                if series[j] == target:
                    found = j
                    break
            if found is not None:
                n_detected += 1
                delays.append(float(starts_arr[found] - starts_arr[i]))
                # Signed onset error: start of the contiguous target-run that
                # contains the match (may begin BEFORE the truth change).
                k = found
                while k > 0 and int(sess_arr[k - 1]) == sess and series[k - 1] == target:
                    k -= 1
                onset_errors.append(float(starts_arr[k] - starts_arr[i]))
            else:
                # Undetected: right-censored at the end of the session's last
                # window (the last instant a correct prediction was possible).
                n_misses += 1
                n_censored += 1
                last_idx = j_end - 1 if j_end > i else i
                horizons.append(float(starts_arr[last_idx] + WINDOW_SECONDS
                                      - starts_arr[i]))
        prev = y[i]
        prev_sess = sess

    def _stats(vals: List[float]) -> Optional[Dict]:
        if not vals:
            return None
        v = np.asarray(vals, dtype=np.float64)
        return {"n": int(len(v)),
                "mean_s": round(float(v.mean()), 3),
                "median_s": round(float(np.median(v)), 3),
                "p50_s": round(float(np.percentile(v, 50)), 3),
                "p90_s": round(float(np.percentile(v, 90)), 3),
                "p95_s": round(float(np.percentile(v, 95)), 3),
                "max_s": round(float(v.max()), 3)}

    d = _stats(delays)
    report: Dict = {
        "n_transitions": n_transitions,
        "n_detected": n_detected,
        "n_misses": n_misses,
        "n_censored": n_censored,
        "delay_s": d,
        "onset_error_s": _stats(onset_errors),
        "censoring_horizon_s": _stats(horizons),
        "timestamps": timestamps,
        # Legacy flat keys kept for backward-compatible consumers (detected-only).
        "mean_s": d["mean_s"] if d else None,
        "median_s": d["median_s"] if d else None,
        "p90_s": d["p90_s"] if d else None,
        "p95_s": d["p95_s"] if d else None,
    }
    return report


def transition_delay_censored(y: Sequence, preds: Sequence[str]) -> Dict:
    """Delay (s) to the first window predicting the new truth after each truth change, searched
    only until the next truth change; transitions never recovered in that span count as missed."""
    y = [str(v) for v in y]
    delays: List[float] = []
    missed = 0
    change = [i for i in range(1, len(y)) if y[i] != y[i - 1]]
    for n, i in enumerate(change):
        end = change[n + 1] if n + 1 < len(change) else len(y)
        hit = next((j for j in range(i, end) if preds[j] == y[i]), None)
        if hit is None:
            missed += 1
        else:
            delays.append((hit - i) * HOP_SECONDS)
    out: Dict[str, Any] = {"n_transitions": len(change), "n_missed": missed}
    if delays:
        out.update({"mean_s": round(float(np.mean(delays)), 3),
                    "median_s": round(float(np.median(delays)), 3),
                    "p90_s": round(float(np.percentile(delays, 90)), 3)})
    return out


def accepted_precision(conf: Dict[str, Dict[str, int]]) -> Optional[float]:
    """Share of accepted (non-unknown) predictions that are correct (all classes pooled)."""
    acc = sum(conf[t][p] for t in conf for p in conf[t] if p != "unknown")
    ok = sum(conf[t][t] for t in conf if t != "unknown")
    return round(ok / acc, 4) if acc else None


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara held-out activity evaluation")
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--data", required=True, help="eval_data.npz from activity-train")
    ap.add_argument("--checkpoint", default=None)
    ap.add_argument("--out", default=None, help="write JSON report to file")
    ap.add_argument("--ledger", default=None,
                    help="test ledger: evaluate through inertia.integrity.TestVault (use eval/hart/test_ledger.jsonl "
                         "whenever --data holds the HART TEST subjects; audit G2 E-2)")
    ap.add_argument("--rerun-reason", default=None)
    ap.add_argument("--rerun-detail", default=None)
    args = ap.parse_args(argv)

    manifest = load_manifest(args.manifest)
    if not os.path.isfile(args.data):
        raise SystemExit(f"eval data not found: {args.data}")
    def run(_payload=None) -> Dict:
        z = np.load(args.data, allow_pickle=True)
        x = z["X"]
        y = z["y_ontology"]
        letters = z["letters"] if "letters" in z else None
        subjects = z["subjects"] if "subjects" in z else None
        sessions = z["sessions"] if "sessions" in z else None
        starts = z["starts"] if "starts" in z else None
        if starts is None:
            # Legacy artifact produced before activity-train persisted timestamps
            # (audit WS-07-F03): keep old behavior but say so explicitly — the
            # transition report uses fabricated i*HOP_SECONDS spacing.
            print("warning: eval_data.npz has no per-window timestamps ('starts' "
                  "key missing — pre-fix artifact); transition metrics use "
                  "fabricated i*HOP_SECONDS spacing and flag timestamps="
                  "fabricated. Regenerate with activity-train to measure real "
                  "latency/gaps.", file=sys.stderr)
        predictor = build_predictor(manifest, args.checkpoint)
        rep = evaluate(x, y, predictor, manifest.thresholds,
                       letters=letters, subjects=subjects, sessions=sessions,
                       starts=starts)
        rep["model_version"] = manifest.model_version
        rep["model_kind"] = manifest.model_kind
        return rep

    if args.ledger:
        from .hart_wisdm_eval import (HART_DECLARED, HART_EXPERIMENT, _ledger_history, _vault, dataset_splits)
        sha = manifest.checkpoint["files"]["model.safetensors"]["sha256"] if manifest.checkpoint else "none"
        report = _vault(args.data, args.ledger).evaluate_once(
            HART_EXPERIMENT, f"{manifest.model_version}:{sha}", run, HART_DECLARED, args.rerun_reason,
            args.rerun_detail, dataset_splits=dataset_splits(), history=_ledger_history)
    else:
        report = run()

    text = json.dumps(report, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
