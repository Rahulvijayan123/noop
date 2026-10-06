"""Score decoder replay outputs (published 5-s states) against per-second truth (agent R).

Inputs: per arm, per record, the published states the Swift replay harness wrote (``ACTIVITY_REPLAY_OUT``),
reduced to :class:`ArmStates` (head probabilities over the decoder's own vocabularies, display label,
overall confidence, flagged events), plus the :class:`replay_export.Recording` truth.

Metrics (all on published states whose second has known truth for the head; MASK never counts):

* ``coverage@95``   per posture / locomotion class: the largest share of truth-positive states claimed
                    (``q_c >= tau``) while the one-sided 95 % Clopper-Pearson lower bound of precision stays
                    >= 0.95. Reported (a) descriptively on the split itself and (b) at the threshold chosen on
                    VALIDATION and applied once to test (no test-set threshold tuning).
* risk-coverage / AURC on head confidence (top non-unknown class, as ``headConfidence`` publishes it).
* fused calibration over known classes (unknown mass removed and renormalised): NLL with set truth
  (−log Σ_{c∈T} p_c), Brier / ECE on single-class truth; unknown mass reported separately.
* transition events: P / R / F1 at ±5 / ±10 / ±30 s, median / p90 timing error (interval truth).
* display-label flips per hour.
* paired subject-cluster bootstrap CIs for arm differences (A3−A1, A2−A0).

Probabilities in the published JSON are rounded to 0.001, so histogram statistics on a 1001-bin grid are
exact; every resampling statistic is computed from per-subject histograms.

If P2's metric modules (``activity_context.inertia.metrics`` / ``abstention`` / ``events`` / ``bootstrap``)
are importable they are used for the point estimates they cover and recorded in ``implementation``;
the local reference implementations below are the fallback and are unit-tested against brute force.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import replay_data as rd

# Decoder vocabularies (ActivityContextOntology.swift), unknown last.
DECODER_ORDERS: Dict[str, Tuple[str, ...]] = {
    "posture": rd.HEAD_ORDERS["posture"] + ("unknown",),
    "locomotion": rd.HEAD_ORDERS["locomotion"] + ("unknown",),
    "arm_behavior": rd.HEAD_ORDERS["arm_behavior"] + ("unknown",),
}
NBINS = 1001          # probabilities published at 0.001 resolution
TARGET_PRECISION = 0.95
CP_ALPHA = 0.05       # one-sided


# ---------------------------------------------------------------------------
# States
# ---------------------------------------------------------------------------

@dataclass
class ArmStates:
    """Published states of one record (one arm)."""
    record_id: str
    recording_id: str
    arm: str
    ts: np.ndarray                                    # int64 [m]
    heads: Dict[str, np.ndarray]                      # head -> float [m, K+1] over DECODER_ORDERS[head]
    display: np.ndarray                               # str [m] ('' = None)
    overall_confidence: np.ndarray                    # float [m]
    events: List[Tuple[str, int, float]] = field(default_factory=list)   # (kind, ts first flagged, prob)
    ood_ignored: int = 0
    meta: Dict[str, Any] = field(default_factory=dict)


def states_from_json(record_id: str, recording_id: str, arm: str, states: Sequence[Mapping[str, Any]],
                     events: Optional[Sequence[Mapping[str, Any]]] = None) -> ArmStates:
    """Build ArmStates from canonical ``ActivityContextState`` JSON objects (``ts``, ``posture`` …)."""
    m = len(states)
    ts = np.zeros(m, np.int64)
    heads = {h: np.zeros((m, len(o))) for h, o in DECODER_ORDERS.items()}
    disp = np.empty(m, dtype=object)
    conf = np.zeros(m)
    for i, s in enumerate(states):
        ts[i] = int(s["ts"])
        for h, order in DECODER_ORDERS.items():
            d = s.get(h) or {}
            for k, v in d.items():
                if k in order:
                    heads[h][i, order.index(k)] = float(v)
        disp[i] = s.get("display_context") or ""
        conf[i] = float(s.get("overall_confidence", 0.0))
    ev = [(str(e["kind"]), int(e["ts"]), float(e.get("probability", 1.0))) for e in (events or [])]
    return ArmStates(record_id=record_id, recording_id=recording_id, arm=arm, ts=ts, heads=heads,
                     display=disp.astype(str), overall_confidence=conf, events=ev)


def align_truth(states: ArmStates, rec, which: str = "strict") -> Dict[str, np.ndarray]:
    """Truth mask per head for each published state (state at ts scores second ts − t0 − 1)."""
    off = states.ts - rec.t0 - 1
    pos = np.searchsorted(rec.sec, off)
    ok = (pos < rec.n) & (rec.sec[np.minimum(pos, rec.n - 1)] == off)
    src = rec.truth_strict if which == "strict" else rec.truth_lenient
    out = {}
    for h in rd.TRUTH_HEADS:
        m = np.zeros(len(off), np.uint16)
        if h in src:
            m[ok] = src[h][pos[ok]]
        out[h] = m
    return out


# ---------------------------------------------------------------------------
# Clopper-Pearson and coverage at precision
# ---------------------------------------------------------------------------

def cp_lower(k: np.ndarray, n: np.ndarray, alpha: float = CP_ALPHA) -> np.ndarray:
    """One-sided (1 − alpha) Clopper-Pearson lower bound of a binomial proportion k/n (0 when n == 0)."""
    from scipy.stats import beta
    k = np.asarray(k, dtype=np.float64)
    n = np.asarray(n, dtype=np.float64)
    out = np.zeros(np.broadcast(k, n).shape)
    ok = (n > 0) & (k > 0)
    out[ok] = beta.ppf(alpha, k[ok], n[ok] - k[ok] + 1)
    return out


def cp_interval(k: int, n: int, alpha: float = 0.05) -> Tuple[float, float]:
    """Two-sided (1 − alpha) Clopper-Pearson interval."""
    from scipy.stats import beta
    if n == 0:
        return (0.0, 1.0)
    lo = 0.0 if k == 0 else float(beta.ppf(alpha / 2, k, n - k + 1))
    hi = 1.0 if k == n else float(beta.ppf(1 - alpha / 2, k + 1, n - k))
    return lo, hi


def score_bins(p: np.ndarray) -> np.ndarray:
    """Bin b holds scores in [b/1000, (b+1)/1000): ``score >= tau`` <=> ``bin >= 1000·tau`` for tau on the
    0.001 grid (so cumulative counts at grid bins equal P2's ``class_curve`` counts exactly)."""
    return np.clip(np.floor(np.asarray(p, dtype=np.float64) * (NBINS - 1) + 1e-9), 0, NBINS - 1).astype(np.int64)


def class_histograms(score: np.ndarray, positive: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """(pos[NBINS], neg[NBINS]) counts by score bin."""
    b = score_bins(score)
    pos = np.bincount(b[positive], minlength=NBINS)
    neg = np.bincount(b[~positive], minlength=NBINS)
    return pos, neg


def coverage_at_precision_hist(pos: np.ndarray, neg: np.ndarray, target: float = TARGET_PRECISION,
                               alpha: float = CP_ALPHA, min_bin: int = 1, n_min: int = 0,
                               grid_step: int = 1) -> Dict[str, Any]:
    """Max recall over thresholds tau (claim when score >= tau; tau = b/1000 for bins b >= min_bin that are
    multiples of grid_step) with CP-lower >= target and >= n_min claimed.

    ``min_bin=300, grid_step=5, n_min=60`` reproduces P2's ``abstention.class_curve`` grid (0.300 … 0.995).
    Returns {coverage, tau, precision, cp_lower, claimed, positives}. coverage 0 / tau None when infeasible.
    """
    P = int(pos.sum())
    tp = np.cumsum(pos[::-1])[::-1]          # tp[b] = positives with bin >= b
    fp = np.cumsum(neg[::-1])[::-1]
    n = tp + fp
    lb = cp_lower(tp, n, alpha)
    bins = np.arange(NBINS)
    on_grid = (bins >= min_bin) & (bins % max(1, grid_step) == 0) & (bins <= NBINS - 1 - (0 if grid_step == 1 else 5))
    feasible = (lb >= target) & on_grid & (n > 0) & (n >= n_min)
    if P == 0 or not feasible.any():
        return {"coverage": 0.0, "tau": None, "precision": None, "cp_lower": None, "claimed": 0, "positives": P}
    rec = np.where(feasible, tp / max(P, 1), -1.0)
    b = int(np.argmax(rec))                  # lowest bin with the max recall among feasible bins
    best = rec[b]
    cands = np.where(feasible & (rec == best))[0]
    b = int(cands.max())                     # among ties, the most conservative threshold
    return {"coverage": float(tp[b] / P), "tau": b / (NBINS - 1), "precision": float(tp[b] / n[b]),
            "cp_lower": float(lb[b]), "claimed": int(n[b]), "positives": P}


def operating_point_hist(pos: np.ndarray, neg: np.ndarray, tau: Optional[float]) -> Dict[str, Any]:
    """Precision (two-sided CP CI) and coverage at a fixed threshold (chosen elsewhere, e.g. on val)."""
    P = int(pos.sum())
    if tau is None:
        return {"tau": None, "coverage": 0.0, "precision": None, "precision_ci": None, "claimed": 0, "positives": P}
    b = int(round(tau * (NBINS - 1)))
    tp = int(pos[b:].sum())
    fp = int(neg[b:].sum())
    n = tp + fp
    return {"tau": tau, "coverage": tp / P if P else 0.0, "precision": tp / n if n else None,
            "precision_ci": cp_interval(tp, n) if n else None, "claimed": n, "positives": P}


# ---------------------------------------------------------------------------
# Risk-coverage / AURC on head confidence
# ---------------------------------------------------------------------------

def top_known(probs: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """(argmax over known classes, its probability) — ties to the lower index like HeadProbabilities.top."""
    known = probs[:, :-1]
    idx = np.argmax(known, axis=1)
    return idx, known[np.arange(len(known)), idx]


def correct_top(probs: np.ndarray, truth: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    idx, conf = top_known(probs)
    return ((truth >> idx.astype(np.uint16)) & 1).astype(bool), conf


def risk_coverage_hist(correct_hist: np.ndarray, wrong_hist: np.ndarray) -> Dict[str, Any]:
    """AURC from confidence histograms (descending confidence; ties within a bin share the bin's risk).

    AURC = mean over accepted items, in order, of the running error rate. Within a bin, items are
    exchangeable, so the running risk is linearly interpolated (exact expectation over tie orders is
    approximated by the bin's average risk — documented; bins are the published 0.001 grid).
    """
    c = correct_hist[::-1].astype(np.float64)
    w = wrong_hist[::-1].astype(np.float64)
    n = c + w
    N = n.sum()
    if N == 0:
        return {"aurc": None, "n": 0, "risk_at": {}}
    cum_n = np.cumsum(n)
    cum_w = np.cumsum(w)
    # sum over items of running risk, approximated per bin by risk at the bin's end times its count
    risk_end = np.divide(cum_w, cum_n, out=np.zeros_like(cum_w), where=cum_n > 0)
    aurc = float((risk_end * n).sum() / N)
    risk_at = {}
    for cov in (0.25, 0.5, 0.8, 1.0):
        k = int(np.searchsorted(cum_n, cov * N - 1e-9))
        k = min(k, len(cum_n) - 1)
        risk_at[f"{cov:.2f}"] = float(risk_end[k])
    return {"aurc": aurc, "n": int(N), "risk_at": risk_at, "error_rate": float(cum_w[-1] / N)}


# ---------------------------------------------------------------------------
# Fused calibration over known classes
# ---------------------------------------------------------------------------

def calibration_terms(probs: np.ndarray, truth: np.ndarray, n_ece_bins: int = 15) -> Dict[str, np.ndarray]:
    """Per-state additive terms (so subjects can be resampled by summing)."""
    known = probs[:, :-1]
    s = known.sum(axis=1)
    has = (truth > 0) & (s > 0)
    p = np.divide(known, s[:, None], out=np.zeros_like(known), where=s[:, None] > 0)
    K = known.shape[1]
    bits = ((truth[:, None] >> np.arange(K, dtype=np.uint16)[None, :]) & 1).astype(bool)
    mass = (p * bits).sum(axis=1)
    nll = -np.log(np.maximum(mass, 1e-12))
    single = has & (bits.sum(axis=1) == 1)
    brier = ((p - bits) ** 2).sum(axis=1)
    idx = np.argmax(p, axis=1)
    conf = p[np.arange(len(p)), idx]
    corr = bits[np.arange(len(p)), idx]
    eb = np.minimum((conf * n_ece_bins).astype(np.int64), n_ece_bins - 1)
    return {"has": has, "nll": np.where(has, nll, 0.0), "single": single, "brier": np.where(single, brier, 0.0),
            "conf": conf, "corr": corr, "ece_bin": eb, "unknown": probs[:, -1]}


def calibration_summary(terms: Dict[str, np.ndarray], n_ece_bins: int = 15) -> Dict[str, Any]:
    has = terms["has"]
    n = int(has.sum())
    ns = int(terms["single"].sum())
    out: Dict[str, Any] = {"n": n, "n_single": ns,
                           "nll": float(terms["nll"][has].mean()) if n else None,
                           "brier": float(terms["brier"][terms["single"]].mean()) if ns else None}
    if n:
        eb = terms["ece_bin"][has]
        conf = terms["conf"][has]
        corr = terms["corr"][has].astype(np.float64)
        cnt = np.bincount(eb, minlength=n_ece_bins)
        sc = np.bincount(eb, weights=conf, minlength=n_ece_bins)
        sa = np.bincount(eb, weights=corr, minlength=n_ece_bins)
        out["ece"] = float(np.abs(sa - sc).sum() / n)
        out["unknown_mass_mean"] = float(terms["unknown"][has].mean())
        out["unknown_mass_ge_0.5"] = float((terms["unknown"][has] >= 0.5).mean())
    return out


# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

@dataclass
class TruthEvent:
    kind: str
    lo: int          # earliest plausible time (unix s): end of the previous labelled segment
    hi: int          # latest plausible time: start of the next labelled segment
    recording_id: str = ""

    @property
    def mid(self) -> float:
        return 0.5 * (self.lo + self.hi)


def interval_distance(t: float, lo: float, hi: float) -> float:
    return 0.0 if lo <= t <= hi else (lo - t if t < lo else t - hi)


def match_events(pred: Sequence[Tuple[str, int, float]], truth: Sequence[TruthEvent], tol_s: float,
                 min_prob: float = 0.0) -> Dict[str, Any]:
    """Greedy one-to-one matching per kind by interval distance <= tol. Returns tp/fp/fn and errors (s,
    predicted ts minus truth interval midpoint, for matched pairs)."""
    tp = 0
    errs: List[float] = []
    used = set()
    preds = [p for p in pred if p[2] >= min_prob]
    kinds = sorted({p[0] for p in preds} | {t.kind for t in truth})
    for k in kinds:
        tk = [i for i, t in enumerate(truth) if t.kind == k]
        pk = sorted([p for p in preds if p[0] == k], key=lambda p: p[1])
        pairs = []
        for pi, p in enumerate(pk):
            for ti in tk:
                d = interval_distance(p[1], truth[ti].lo, truth[ti].hi)
                if d <= tol_s:
                    pairs.append((d, abs(p[1] - truth[ti].mid), pi, ti))
        pairs.sort()
        up, ut = set(), set()
        for d, dm, pi, ti in pairs:
            if pi in up or ti in ut:
                continue
            up.add(pi)
            ut.add(ti)
            tp += 1
            errs.append(pk[pi][1] - truth[ti].mid)
            used.add(ti)
    n_pred = len(preds)
    n_truth = len(truth)
    fp = n_pred - tp
    fn = n_truth - tp
    p = tp / n_pred if n_pred else None
    r = tp / n_truth if n_truth else None
    f1 = (2 * p * r / (p + r)) if (p and r) else (0.0 if (p is not None and r is not None) else None)
    ae = np.abs(np.asarray(errs)) if errs else np.zeros(0)
    return {"tol_s": tol_s, "tp": tp, "fp": fp, "fn": fn, "precision": p, "recall": r, "f1": f1,
            "median_abs_err_s": float(np.median(ae)) if len(ae) else None,
            "p90_abs_err_s": float(np.percentile(ae, 90)) if len(ae) else None}


# ---------------------------------------------------------------------------
# Display flips
# ---------------------------------------------------------------------------

def display_flips(states: ArmStates, gap_reset_s: int = 120) -> Tuple[int, float]:
    """(flips, observed hours): label changes between consecutive states ≤ gap_reset_s apart."""
    if len(states.ts) < 2:
        return 0, len(states.ts) * 5 / 3600.0
    d = states.display
    contiguous = np.diff(states.ts) <= gap_reset_s
    flips = int(np.sum((d[1:] != d[:-1]) & contiguous))
    hours = float(np.sum(np.minimum(np.diff(states.ts), gap_reset_s)[contiguous]) / 3600.0)
    return flips, hours


# ---------------------------------------------------------------------------
# Subject-cluster bootstrap
# ---------------------------------------------------------------------------

def cluster_bootstrap(per_subject: Mapping[str, Any], stat: Callable[[Sequence[Any]], float],
                      n_boot: int = 2000, seed: int = 20261005) -> Dict[str, Any]:
    """Percentile CI of ``stat(list of per-subject items)`` resampling subjects with replacement.

    ``per_subject[s]`` is anything ``stat`` can combine (e.g. a tuple of per-arm histograms), so a paired
    difference is just a stat that returns arm_b − arm_a on the same resampled subjects.
    """
    keys = sorted(per_subject)
    items = [per_subject[k] for k in keys]
    point = stat(items)
    rng = np.random.default_rng(seed)
    vals = []
    for _ in range(n_boot):
        idx = rng.integers(0, len(items), len(items))
        v = stat([items[i] for i in idx])
        if v is not None and math.isfinite(v):
            vals.append(v)
    vals_a = np.asarray(vals)
    if len(vals_a) == 0:
        return {"point": point, "ci95": None, "n_boot": 0, "n_clusters": len(items)}
    return {"point": point, "ci95": [float(np.percentile(vals_a, 2.5)), float(np.percentile(vals_a, 97.5))],
            "n_boot": int(len(vals_a)), "n_clusters": len(items),
            "p_le_0": float(np.mean(vals_a <= 0)), "p_ge_0": float(np.mean(vals_a >= 0))}


# ---------------------------------------------------------------------------
# Event truth from per-second labels (reuses P2's transition_targets boundary rules)
# ---------------------------------------------------------------------------

def truth_events_for_recording(rec, mappings_path: Optional[str] = None,
                               dataset_key: str = "capture24") -> Tuple[List[TruthEvent], List[Tuple[float, float]]]:
    """(event truth, masked spans) in unix seconds for one recording, from its per-second labels.

    Uses the repo crosswalk's ``transition_states`` / ``event_pairs`` / ``transition_rules`` and P2's
    ``derive_boundaries`` (Capture-24: ``null_gap`` mode, the change lies somewhere inside an unannotated
    gap of <= 28 s; timing is NOT ground truth there). Runs split at missing seconds.
    """
    import json as _json
    import os as _os
    from . import transition_targets as tt

    path = mappings_path or _os.path.join(_os.path.dirname(__file__), "label_mappings.json")
    with open(path, "r", encoding="utf-8") as f:
        doc = _json.load(f)
    states_map = doc["transition_states"].get(dataset_key, {})
    rule = doc["transition_rules"].get(dataset_key, {"mode": "mask"})
    pairs = {(p["from"], p["to"]): list(p["events"]) for p in doc["event_pairs"]}
    states = [states_map.get(l) for l in rec.labels] + [None]
    codes_all = np.where(rec.truth_label >= 0, rec.truth_label, len(rec.labels)).astype(np.int64)
    events: List[TruthEvent] = []
    masked: List[Tuple[float, float]] = []
    brk = np.flatnonzero(np.diff(rec.sec) != 1) + 1
    for idx in np.split(np.arange(rec.n), brk):
        if len(idx) == 0:
            continue
        t = (rec.t0 + rec.sec[idx]).astype(np.float64)
        segs = tt.label_segments(t, codes_all[idx], 1.0, states)
        bounds = tt.derive_boundaries(segs, rule, pairs, window_s=30)
        for e in tt.timing_events(bounds):
            events.append(TruthEvent(kind=e["type"], lo=int(math.floor(e["lo"])), hi=int(math.ceil(e["hi"])),
                                     recording_id=rec.recording_id))
        masked.extend(tt.masked_intervals(bounds))
    return events, masked


def drop_masked_predictions(pred: Sequence[Tuple[str, int, float]], masked: Sequence[Tuple[float, float]],
                            truth: Sequence[TruthEvent]) -> List[Tuple[str, int, float]]:
    """Predicted events inside an unknown-boundary span (and not near a truth event) count neither way."""
    if not masked:
        return list(pred)
    lo = np.array([m[0] for m in masked])
    hi = np.array([m[1] for m in masked])
    out = []
    for p in pred:
        inside = bool(np.any((lo <= p[1]) & (p[1] <= hi)))
        if inside and not any(interval_distance(p[1], t.lo, t.hi) <= 30 for t in truth if t.kind == p[0]):
            continue
        out.append(p)
    return out
