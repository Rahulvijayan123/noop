"""transition-events — event-level matching and metrics for the transition expert.

Ground truth and predicted transition events are (ts, kind) pairs against the canonical
4-kind ontology (sit_to_stand, stand_to_sit, lie_down, get_up). Matching is greedy,
one-to-one, same-kind, with an absolute tolerance tau:

* For every GT event (in time order) the earliest unmatched prediction of the SAME kind
  within +-tau is consumed as a true positive. This is the standard event-detection contract
  and is deterministic (preds are sorted by (ts, kind)).
* Extra same-kind predictions within tau of an already-matched GT are DUPLICATES: counted
  separately and counted as false positives too (a detector firing twice for one true event is
  not a second correct detection).
* A prediction of a DIFFERENT kind within tau of a GT is a DIRECTION CONFUSION: recorded as
  (gt_kind, pred_kind), it counts as a false positive and the GT stays unmatched (false
  negative) — a wrong-direction event did not detect the true event.

Metrics are reported per tau over the same one-to-one matching, with per-class P/R/F1 derived
from the global match (so per-class counts sum exactly to the global counts), macro F1 over the
four kinds, timestamp-error statistics over matched pairs, and per-hour rates when the
recording length (hours) is provided. The permutation test for paired per-participant F1
differences is a sign-flip test with a fixed seed, so it is bit-reproducible.

All functions are pure numpy/math, deterministic, and free of RNG except paired_participant_diffs
(which uses an explicit fixed seed).
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np

from .transition_data import EVENT_KINDS

__all__ = ["MatchResult", "match_events", "metrics", "paired_participant_diffs"]


@dataclass
class MatchResult:
    """Outcome of one one-to-one same-kind event match."""
    tp: int
    fn: int
    fp: int                                  # includes duplicates and direction confusions
    duplicates: int                          # extra same-kind preds near already-matched GTs (subset of fp)
    direction_confusions: List[Tuple[str, str]]   # (gt_kind, pred_kind); one entry per confusion (subset of fp)
    matched: List[Tuple[float, float, str]]  # (gt_ts, pred_ts, kind)


def _pairs(items: Iterable, kinds: Sequence[str]) -> List[Tuple[float, str]]:
    """Normalize inputs to (ts, kind) tuples; accepts (ts, kind) pairs, {"ts", "kind"} dicts or
    objects with .ts/.kind."""
    out: List[Tuple[float, str]] = []
    for it in items:
        if isinstance(it, dict):
            ts, kind = float(it["ts"]), str(it["kind"])
        elif hasattr(it, "ts"):
            ts, kind = float(it.ts), str(it.kind)
        else:
            ts, kind = float(it[0]), str(it[1])
        if kind not in kinds:
            raise ValueError(f"unknown kind {kind!r}; expected one of {tuple(kinds)}")
        out.append((ts, kind))
    return out


def match_events(gt: Iterable, pred: Iterable, tau: float,
                 kinds: Sequence[str] = EVENT_KINDS) -> MatchResult:
    """Greedy one-to-one same-kind matching within +-tau.

    ``gt``/``pred`` are iterables of (ts, kind) pairs or objects exposing .ts/.kind. GT is
    iterated in time order; each GT consumes the earliest unmatched same-kind prediction within
    tau. Returns a MatchResult with tp/fn/fp/duplicates/direction_confusions/matched pairs.
    """
    if tau < 0:
        raise ValueError(f"tau must be >= 0, got {tau!r}")
    gt = sorted(_pairs(gt, kinds), key=lambda e: (e[0], e[1]))
    pred = sorted(_pairs(pred, kinds), key=lambda e: (e[0], e[1]))
    used = [False] * len(pred)
    matched: List[Tuple[float, float, str]] = []
    for gts, gk in gt:
        chosen: Optional[int] = None
        for j, (pts, pk) in enumerate(pred):
            if used[j] or pk != gk:
                continue
            if abs(pts - gts) <= tau:
                chosen = j                    # preds sorted by ts: earliest same-kind within tau
                break
        if chosen is not None:
            used[chosen] = True
            matched.append((gts, pred[chosen][0], gk))
    matched_gt_by_kind: Dict[str, List[float]] = {}
    for gts, _pts, gk in matched:
        matched_gt_by_kind.setdefault(gk, []).append(gts)

    tp = len(matched)
    fn = len(gt) - tp
    duplicates = 0
    confusions: List[Tuple[str, str]] = []
    fp = 0
    for j, (pts, pk) in enumerate(pred):
        if used[j]:
            continue
        fp += 1
        # Duplicate: an extra same-kind pred within tau of an already-matched GT.
        if pk in matched_gt_by_kind and any(abs(pts - g) <= tau for g in matched_gt_by_kind[pk]):
            duplicates += 1
            continue
        # Direction confusion: nearest GT within tau (any kind). Same-kind GTs within tau are
        # always matched, so a remaining GT within tau is a different kind.
        best_kind: Optional[str] = None
        best_key: Optional[Tuple[float, float]] = None
        for gts, gk in gt:
            d = abs(pts - gts)
            if d <= tau:
                key = (d, gts)               # nearest, tie -> earliest GT
                if best_key is None or key < best_key:
                    best_key, best_kind = key, gk
        if best_kind is not None:
            confusions.append((best_kind, pk))
    return MatchResult(tp=tp, fn=fn, fp=fp, duplicates=duplicates,
                       direction_confusions=confusions, matched=matched)


def metrics(gt: Iterable, pred: Iterable, taus: Sequence[float] = (0.5, 1.0, 2.0, 5.0),
            hours: Optional[float] = None, abstain_counts: Optional[Dict] = None,
            kinds: Sequence[str] = EVENT_KINDS) -> Dict[float, Dict]:
    """Per-tau event metrics over the one-to-one same-kind match.

    Returns a dict keyed by tau with: tp/fn/fp/duplicates, precision/recall/F1, fp_per_hour,
    missed_per_hour, duplicate_rate (duplicates / tp, 0 when tp == 0), direction_confusions and
    its matrix, abs_err_median / abs_err_p90 / signed_err_median over matched pairs, per_class
    {kind: {tp, fp, fn, precision, recall, f1}}, macro_f1 (mean of per-class F1; 0 for a kind
    with no support), and abstention_rate.

    ``hours`` (recording hours) normalizes fp/missed rates; when None it is estimated from the
    union event time span. ``abstain_counts`` is an optional dict with keys ``n_windows`` (total
    windows the model scored) and ``n_abstained`` (windows the model declined to label); the
    synonym ``n_none_label`` is accepted for ``n_abstained``. abstention_rate = n_abstained /
    n_windows (None when n_windows is 0).
    """
    gt_list = _pairs(gt, kinds)
    pred_list = _pairs(pred, kinds)
    if hours is None:
        all_ts = [e[0] for e in gt_list] + [e[0] for e in pred_list]
        span = (max(all_ts) - min(all_ts)) if all_ts else 0.0
        hours = max(span, 1e-9) / 3600.0
    if hours <= 0:
        raise ValueError(f"hours must be positive, got {hours!r}")

    abstention_rate: Optional[float] = None
    if abstain_counts:
        n_windows = int(abstain_counts.get("n_windows", 0))
        n_abstained = int(abstain_counts.get("n_abstained",
                                             abstain_counts.get("n_none_label", 0)))
        abstention_rate = (n_abstained / n_windows) if n_windows > 0 else None

    gt_counter = Counter(gt_list)
    pred_counter = Counter(pred_list)
    out: Dict[float, Dict] = {}
    for tau in taus:
        m = match_events(gt_list, pred_list, tau, kinds=kinds)
        matched_gt = Counter((gts, k) for gts, _pts, k in m.matched)
        matched_pred = Counter((pts, k) for _gts, pts, k in m.matched)
        gt_unmatched = gt_counter - matched_gt
        pred_unmatched = pred_counter - matched_pred

        per_class: Dict[str, Dict] = {}
        for kk in kinds:
            tp_k = sum(cnt for (ts, k), cnt in matched_gt.items() if k == kk)
            fn_k = sum(cnt for (ts, k), cnt in gt_unmatched.items() if k == kk)
            fp_k = sum(cnt for (ts, k), cnt in pred_unmatched.items() if k == kk)
            prec = tp_k / (tp_k + fp_k) if (tp_k + fp_k) > 0 else 0.0
            rec = tp_k / (tp_k + fn_k) if (tp_k + fn_k) > 0 else 0.0
            f1 = 2 * prec * rec / (prec + rec) if (prec + rec) > 0 else 0.0
            per_class[kk] = {"tp": tp_k, "fp": fp_k, "fn": fn_k,
                             "precision": prec, "recall": rec, "f1": f1}

        abs_err = [abs(pts - gts) for gts, pts, _k in m.matched]
        signed_err = [pts - gts for gts, pts, _k in m.matched]
        conf_matrix = dict(sorted(Counter(m.direction_confusions).items()))
        out[float(tau)] = {
            "tp": m.tp, "fn": m.fn, "fp": m.fp, "duplicates": m.duplicates,
            "precision": m.tp / (m.tp + m.fp) if (m.tp + m.fp) > 0 else 0.0,
            "recall": m.tp / (m.tp + m.fn) if (m.tp + m.fn) > 0 else 0.0,
            "f1": (2 * m.tp / (2 * m.tp + m.fp + m.fn)) if (m.tp + m.fp + m.fn) > 0 else 0.0,
            "fp_per_hour": m.fp / hours,
            "missed_per_hour": m.fn / hours,
            "duplicate_rate": (m.duplicates / m.tp) if m.tp > 0 else 0.0,
            "direction_confusions": list(m.direction_confusions),
            "direction_confusion_matrix": conf_matrix,
            "abs_err_median": float(np.median(abs_err)) if abs_err else None,
            "abs_err_p90": float(np.percentile(abs_err, 90)) if abs_err else None,
            "signed_err_median": float(np.median(signed_err)) if signed_err else None,
            "per_class": per_class,
            "macro_f1": float(np.mean([per_class[k]["f1"] for k in kinds])),
            "abstention_rate": abstention_rate,
        }
    return out


def paired_participant_diffs(a: Sequence[float], b: Sequence[float], seed: int = 0,
                             n_perm: int = 10000) -> Tuple[float, float]:
    """Sign-flip permutation test for paired per-participant differences (fixed rng).

    Returns (mean(a) - mean(b), p-value). Under H0 the pairwise differences d_i = a_i - b_i
    have zero mean, so n_perm random sign flips of d generate the null distribution; the
    observed statistic (all +1 flips) is included in the null with the +1 correction, and the
    two-sided p-value is the fraction of null |mean| >= observed |mean|. ``np.random.default_rng
    (seed)`` makes the result bit-reproducible for a given seed.
    """
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    if a.shape != b.shape or a.ndim != 1 or a.shape[0] == 0:
        raise ValueError(f"a and b must be non-empty 1-D arrays of equal length, got {a.shape}, {b.shape}")
    d = a - b
    obs = float(d.mean())
    rng = np.random.default_rng(seed)
    flips = rng.choice(np.array([-1.0, 1.0]), size=(n_perm, d.shape[0]))
    perm_means = (flips * d[None, :]).sum(axis=1) / d.shape[0]
    n_more = int((np.abs(perm_means) >= abs(obs)).sum()) + 1
    p = n_more / (n_perm + 1)
    return obs, p
