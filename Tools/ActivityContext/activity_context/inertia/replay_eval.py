"""System-level comparison runner: export -> Swift replay -> score (agent R; spec §17 / §23 / §26).

Everything Inertia here is a STAND-IN, NOT INERTIA-1.

Decoding: one ``nara-activity-replay-1`` file per chunk of recordings and file variant (``full`` = with HART
encoder windows, ``noenc`` = without), decoded by the env-gated XCTest ``ActivityReplayTests/
testReplayFromEnvironment`` through ``xcrun xctest`` on a release build of the StrandAnalytics test bundle in
a private scratch path (so several chunks decode in parallel and every arm of a run uses the same build).

Scoring (published 5-s states vs per-second truth; MASK never scored), using P2's metric functions:
``abstention.select_operating_point`` (VAL) / ``check_gate`` (TEST at the frozen VAL tau) / ``class_curve`` /
``aurc``; ``metrics.nll`` / ``brier`` / ``ece_top``; ``events.event_metrics``; ``bootstrap.cluster_bootstrap``.
Locomotion is scored with ``brisk_walking`` folded into ``walking`` (no dataset here resolves pace: every
walking truth is the set {walking, brisk_walking}).
"""

from __future__ import annotations

import json
import math
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import replay_data as rd
from . import replay_export as rx
from . import replay_score as rs

XCTEST_BUNDLE = os.environ.get("NARA_REPLAY_XCTEST") or rd._paths.under(rd.REPLAY_DIR, "swiftbuild", "release",
                                                                        "StrandAnalyticsPackageTests.xctest")
XCTEST_FILTER = "ActivityReplayTests/testReplayFromEnvironment"
# Transient replay files (multi-GB for Capture-24) go to the internal disk: the external research volume
# dropped off the bus twice during this work, and every in-flight read/write died with it.
WORK_DIR = os.environ.get("NARA_REPLAY_WORK", os.path.expanduser("~/Library/Caches/nara-replay-R/work"))


def wait_for_volume(path: Optional[str] = None, timeout_s: int = 1800) -> None:
    path = path or rd.replay_root()
    t = time.time()
    while not os.path.isdir(path):
        if time.time() - t > timeout_s:
            raise RuntimeError(f"{path} did not come back within {timeout_s} s")
        time.sleep(15)


def retrying(fn, what: str, tries: int = 4):
    """Run fn(); on an I/O-ish failure wait for the research volume and retry (the volume is flaky)."""
    last = None
    for k in range(tries):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - logged and retried, re-raised after the last try
            last = exc
            print(json.dumps({"retry": what, "attempt": k + 1, "error": f"{type(exc).__name__}: {str(exc)[:300]}"}),
                  flush=True)
            wait_for_volume()
            time.sleep(10)
    raise last  # type: ignore[misc]

# Scoring vocabularies (decoder order, unknown last). Locomotion folds brisk_walking into walking.
SCORE_ORDERS: Dict[str, Tuple[str, ...]] = {
    "posture": ("recumbent", "seated_likely", "upright_stationary", "postural_transition", "unknown"),
    "locomotion": ("stationary", "walking", "running", "stairs", "cycling", "vehicle_motion", "other", "unknown"),
    "arm_behavior": ("quiet", "desk_like", "fidgeting", "repetitive_hand_motion", "active_gesturing",
                     "exercise_motion", "other", "unknown"),
}
SCORED_HEADS = ("posture", "locomotion", "arm_behavior")
EVENT_TOLS = (5.0, 10.0, 30.0)


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

def run_xctest(in_path: str, out_path: str, bundle: str = XCTEST_BUNDLE, timeout_s: int = 7200) -> float:
    from .subproc import safe_env
    env = safe_env({"ACTIVITY_REPLAY_IN": in_path, "ACTIVITY_REPLAY_OUT": out_path})   # never the full environ
    t = time.time()
    p = subprocess.run(["xcrun", "xctest", "-XCTest", XCTEST_FILTER, bundle], env=env, capture_output=True,
                       text=True, timeout=timeout_s)
    if p.returncode != 0 or not os.path.isfile(out_path):
        raise RuntimeError(f"xctest replay failed rc={p.returncode}: {_xctest_error_lines(p.stdout + p.stderr)}")
    return time.time() - t


def _xctest_error_lines(text: str, limit: int = 1500) -> str:
    """Only the failure lines of an xctest run, redacted. XCTest can dump the whole process environment on
    a crash, which may contain credentials: never log raw output."""
    from .subproc import failure_lines
    return failure_lines(text, limit)


@dataclass
class SeqStates:
    ts: np.ndarray
    heads: Dict[str, np.ndarray]          # head -> [m, len(rs.DECODER_ORDERS[head])]
    display: np.ndarray
    klass: np.ndarray
    events: List[Tuple[str, int, float]]
    refusal: Optional[str]
    motion_heads: Optional[Dict[str, Any]]


def parse_seq(entry: Mapping[str, Any]) -> SeqStates:
    st = entry.get("states") or []
    m = len(st)
    ts = np.fromiter((int(s["ts"]) for s in st), dtype=np.int64, count=m)
    heads = {}
    for h, order in rs.DECODER_ORDERS.items():
        a = np.zeros((m, len(order)))
        pos = {c: i for i, c in enumerate(order)}
        for i, s in enumerate(st):
            for c, v in (s.get(h) or {}).items():
                j = pos.get(c)
                if j is not None:
                    a[i, j] = float(v)
        heads[h] = a
    disp = np.asarray([s.get("display") or "" for s in st], dtype=object).astype(str)
    klass = np.asarray([s.get("class") or "" for s in st], dtype=object).astype(str)
    ev = [(str(e["kind"]), int(e["ts"]), float(e.get("probability", 1.0))) for e in (entry.get("events") or [])]
    return SeqStates(ts=ts, heads=heads, display=disp, klass=klass, events=ev,
                     refusal=entry.get("refusal"), motion_heads=entry.get("motion_heads"))


def _decode_task(args) -> Tuple[Dict[Tuple[str, str], Dict[str, SeqStates]], Dict[str, Any], float]:
    """Worker: write one replay file, decode it with xctest, parse, delete the files (process-pool safe)."""
    variant, arms, part, heads, bundle_info, weights, ip, keep_files = args
    op = ip[:-6] + ".out.json"
    m = rx.write_harness_file(ip, part, list(arms), heads=heads, bundle_info=bundle_info, weights=weights,
                              allow_standin=bundle_info is not None, include_encoder=(variant == "full"))
    m["variant"] = variant
    dt = retrying(lambda: run_xctest(ip, op), f"xctest {os.path.basename(ip)}")
    with open(op, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("format") != rx.HARNESS_OUT_FORMAT:
        raise RuntimeError(f"unexpected replay output format {doc.get('format')!r}")
    res = {(variant, arm): {seq: parse_seq(e) for seq, e in per.items()} for arm, per in doc["arms"].items()}
    if not keep_files:
        os.remove(ip)
        os.remove(op)
    return res, m, dt


def decode(recs: Sequence[rx.Recording], workdir: str, variants: Mapping[str, Sequence[str]],
           heads: Optional[Mapping[str, rx.HeadsWindows]] = None, bundle_info: Optional[Mapping[str, Any]] = None,
           weights: Optional[Mapping[str, float]] = None, chunk: int = 10, jobs: int = 4,
           keep_files: bool = False) -> Tuple[Dict[Tuple[str, str], Dict[str, SeqStates]], Dict[str, Any]]:
    """Decode every recording for each file variant -> {(variant, harness_arm): {seq: SeqStates}}.

    ``variants``: {"full": [harness arms], "noenc": [harness arms]}. Inertia arms need ``heads`` +
    ``bundle_info`` (the stand-in test override is set: STAND-IN, NOT INERTIA-1). Chunks are written, decoded
    and parsed in a process pool."""
    from concurrent.futures import ProcessPoolExecutor
    os.makedirs(workdir, exist_ok=True)
    tasks = []
    for variant, arms in variants.items():
        if not arms:
            continue
        for ci in range(0, len(recs), chunk):
            part = list(recs[ci:ci + chunk])
            ph = {r.recording_id: heads[r.recording_id] for r in part if heads and r.recording_id in heads}
            ip = os.path.join(workdir, f"{variant}_{ci // chunk:03d}.jsonl")
            tasks.append((variant, list(arms), part, ph or None, bundle_info, weights, ip, keep_files))
    out: Dict[Tuple[str, str], Dict[str, SeqStates]] = {}
    times, manifests = [], []
    with ProcessPoolExecutor(max_workers=max(1, min(jobs, len(tasks)))) as ex:
        for res, m, dt in ex.map(_decode_task, tasks):
            times.append(dt)
            manifests.append(m)
            for k, v in res.items():
                out.setdefault(k, {}).update(v)
    shared: Dict[str, set] = {}
    for m in manifests:
        for rid, d in m["shared_input_sha256"].items():
            shared.setdefault(rid, set()).add(d)
    identical = all(len(v) == 1 for v in shared.values())
    info = {"files": len(tasks), "decode_seconds": round(float(sum(times)), 1),
            "attach": [m["attach"] for m in manifests if m["variant"] == "full" or bundle_info is not None],
            "shared_inputs_identical_across_variants": identical}
    return out, info


def report_arms(decoded: Mapping[Tuple[str, str], Dict[str, SeqStates]]) -> Dict[str, Dict[str, SeqStates]]:
    """Map (variant, harness arm) results onto report arms (rx.ARM_SOURCES)."""
    out = {}
    for arm, src in rx.ARM_SOURCES.items():
        if src in decoded:
            out[arm] = decoded[src]
    return out


# ---------------------------------------------------------------------------
# Tables: published states aligned with per-second truth
# ---------------------------------------------------------------------------

def _fold(head: str, probs: np.ndarray) -> np.ndarray:
    """Decoder head probs (rs.DECODER_ORDERS) -> SCORE_ORDERS (locomotion: brisk_walking into walking)."""
    if head != "locomotion":
        return probs
    src = rs.DECODER_ORDERS["locomotion"]
    out = np.zeros((probs.shape[0], len(SCORE_ORDERS["locomotion"])))
    for j, c in enumerate(src):
        tgt = "walking" if c == "brisk_walking" else c
        out[:, SCORE_ORDERS["locomotion"].index(tgt)] += probs[:, j]
    return out


def _truth_bool(head: str, mask: np.ndarray) -> np.ndarray:
    """uint16 class-set mask over rd.HEAD_ORDERS[head] -> bool [N, len(SCORE_ORDERS[head])] (unknown False)."""
    order = rd.HEAD_ORDERS[head]
    out = np.zeros((len(mask), len(SCORE_ORDERS[head])), bool)
    for i, c in enumerate(order):
        tgt = "walking" if (head == "locomotion" and c == "brisk_walking") else c
        out[:, SCORE_ORDERS[head].index(tgt)] |= ((mask >> i) & 1).astype(bool)
    return out


@dataclass
class ArmTable:
    arm: str
    subject: np.ndarray
    seq: np.ndarray
    ts: np.ndarray
    probs: Dict[str, np.ndarray]       # head -> [N, len(SCORE_ORDERS[head])]
    truth: Dict[str, np.ndarray]       # head -> bool [N, len(SCORE_ORDERS[head])]
    display: np.ndarray
    klass: np.ndarray
    events: Dict[str, List[Tuple[str, int, float]]]
    refusals: Dict[str, Optional[str]]
    motion_heads: Dict[str, Any] = field(default_factory=dict)


def build_table(arm: str, recs: Sequence[rx.Recording], states: Mapping[str, SeqStates]) -> ArmTable:
    subj, seqs, tss, disp, kl = [], [], [], [], []
    probs = {h: [] for h in SCORED_HEADS}
    truth = {h: [] for h in SCORED_HEADS}
    events, refusals, mh = {}, {}, {}
    for r in recs:
        s = states.get(r.recording_id)
        if s is None:
            raise KeyError(f"{arm}: no decoded states for {r.recording_id}")
        refusals[r.recording_id] = s.refusal
        events[r.recording_id] = s.events
        if s.motion_heads:
            mh[r.recording_id] = s.motion_heads
        st = rs.ArmStates(record_id=r.recording_id, recording_id=r.recording_id, arm=arm, ts=s.ts, heads={},
                          display=s.display, overall_confidence=np.zeros(len(s.ts)))
        tr = rs.align_truth(st, r, "strict")
        m = len(s.ts)
        subj.append(np.full(m, r.subject, dtype=object))
        seqs.append(np.full(m, r.recording_id, dtype=object))
        tss.append(s.ts)
        disp.append(s.display)
        kl.append(s.klass)
        for h in SCORED_HEADS:
            probs[h].append(_fold(h, s.heads[h]))
            truth[h].append(_truth_bool(h, tr[h]))
    cat = lambda xs: np.concatenate(xs) if xs else np.zeros(0)  # noqa: E731
    return ArmTable(arm=arm, subject=cat(subj).astype(str), seq=cat(seqs).astype(str), ts=cat(tss).astype(np.int64),
                    probs={h: np.concatenate(v) for h, v in probs.items()},
                    truth={h: np.concatenate(v) for h, v in truth.items()},
                    display=cat(disp).astype(str), klass=cat(kl).astype(str), events=events, refusals=refusals,
                    motion_heads=mh)


def check_alignment(tables: Mapping[str, ArmTable]) -> None:
    ref = None
    for a, t in tables.items():
        key = (t.seq, t.ts)
        if ref is None:
            ref = (a, key)
            continue
        if not (np.array_equal(ref[1][0], key[0]) and np.array_equal(ref[1][1], key[1])):
            raise RuntimeError(f"published states of arms {ref[0]} and {a} are not aligned")


# ---------------------------------------------------------------------------
# Metrics (P2's functions)
# ---------------------------------------------------------------------------

def _known(head: str, probs: np.ndarray) -> np.ndarray:
    k = probs[:, :-1]
    s = k.sum(axis=1, keepdims=True)
    return np.divide(k, s, out=np.full_like(k, 1.0 / k.shape[1]), where=s > 0)


def scored_classes(table: ArmTable, head: str, min_pos: int = 1) -> List[int]:
    tr = table.truth[head]
    return [c for c in range(tr.shape[1] - 1) if int(tr[:, c].sum()) >= min_pos]


def descriptive_cov95(probs: np.ndarray, truth: np.ndarray, subjects: np.ndarray, c: int, n_min: int = 60) -> Dict[str, Any]:
    from .abstention import class_curve
    rows = class_curve(probs, truth, subjects, c)
    ok = [r for r in rows if r["n_acc"] >= n_min and r["cp_lower_95"] >= 0.95]
    if not ok:
        return {"coverage": 0.0, "tau": None}
    best = max(ok, key=lambda r: (r["recall"], r["tau"]))
    return {"coverage": float(best["recall"]), "tau": best["tau"], "precision": best["precision"],
            "cp_lower_95": best["cp_lower_95"], "n_acc": best["n_acc"]}


def head_metrics(table: ArmTable, head: str, val_ops: Optional[Dict[int, Dict[str, Any]]] = None) -> Dict[str, Any]:
    from .abstention import aurc, check_gate
    from .metrics import brier, ece_top, nll
    tr = table.truth[head]
    keep = tr.any(axis=1)
    if not keep.any():
        return {"n": 0}
    P = table.probs[head][keep]
    T = tr[keep]
    S = table.subject[keep]
    order = SCORE_ORDERS[head]
    out: Dict[str, Any] = {"n": int(keep.sum()), "n_subjects": int(len(np.unique(S))), "classes": {}}
    pk = _known(head, P)
    Tk = T[:, :-1]
    has_k = Tk.any(axis=1)
    out["nll_known"] = nll(pk[has_k], Tk[has_k])
    out["brier_known"] = brier(pk[has_k], Tk[has_k])
    out["ece_known_15"] = ece_top(pk[has_k], Tk[has_k], 15)
    out["unknown_mass_mean"] = float(P[:, -1].mean())
    out["unknown_mass_ge_0.5"] = float((P[:, -1] >= 0.5).mean())
    idx = P[:, :-1].argmax(axis=1)
    conf = P[np.arange(len(P)), idx]
    correct = T[np.arange(len(P)), idx]
    out["aurc"] = aurc(conf, correct)
    out["accuracy_top_known"] = float(correct.mean())
    for c in scored_classes(table, head):
        d: Dict[str, Any] = {"truth_states": int(T[:, c].sum()), "truth_subjects": int(len(np.unique(S[T[:, c]])))}
        d["descriptive_cov95"] = descriptive_cov95(P, T, S, c)
        if val_ops is not None and c in val_ops:
            op = val_ops[c]
            d["val_status"] = op["status"]
            d["val_tau"] = op["tau"]
            g = None
            if op["status"] in ("strong", "weak"):
                g = check_gate(P, T, c, op["tau"])
                d["test_at_val_tau"] = {k: g[k] for k in ("n_acc", "tp", "precision", "cp_lower_95", "recall", "pass")}
            # coverage at >= 95 % precision with NO test tuning: the VAL-strong tau, counted only when P2's one-shot
            # TEST gate passes (precision >= .95, CP95 lower >= .90, n_acc >= 30, recall >= .05); else 0
            d["coverage95_val_tau"] = (g["recall"] if (op["status"] == "strong" and g is not None and g["pass"]) else 0.0)
        out["classes"][order[c]] = d
    return out


def val_operating_points(table: ArmTable, head: str) -> Dict[int, Dict[str, Any]]:
    from .abstention import select_operating_point
    tr = table.truth[head]
    keep = tr.any(axis=1)
    P, T, S = table.probs[head][keep], tr[keep], table.subject[keep]
    return {c: select_operating_point(P, T, S, c, True) for c in range(T.shape[1] - 1) if T[:, c].sum() > 0}


def display_flips_per_hour(table: ArmTable, gap_reset_s: int = 120) -> Dict[str, Any]:
    flips, hours = 0, 0.0
    for sid in np.unique(table.seq):
        m = table.seq == sid
        st = rs.ArmStates(record_id=sid, recording_id=sid, arm=table.arm, ts=table.ts[m], heads={},
                          display=table.display[m], overall_confidence=np.zeros(int(m.sum())))
        f, h = rs.display_flips(st, gap_reset_s)
        flips += f
        hours += h
    return {"flips": flips, "hours": round(hours, 3), "flips_per_hour": flips / hours if hours else None}


def event_metrics_table(table: ArmTable, recs: Sequence[rx.Recording]) -> Dict[str, Any]:
    from .events import event_metrics
    per_kind_recs: Dict[str, List[Dict[str, Any]]] = {}
    interval_pred, interval_truth = [], []
    for r in recs:
        ev_true, masked = rs.truth_events_for_recording(r)
        pred = table.events.get(r.recording_id, [])
        kinds = sorted({e.kind for e in ev_true} | {p[0] for p in pred})
        for k in kinds:
            per_kind_recs.setdefault(k, []).append({
                "pred": [float(p[1]) for p in pred if p[0] == k],
                "true": [float(e.mid) for e in ev_true if e.kind == k],
                "masked": masked})
        interval_pred += rs.drop_masked_predictions(pred, masked, ev_true)
        interval_truth += ev_true
    out: Dict[str, Any] = {"n_truth_events": int(sum(len(v["true"]) for vs in per_kind_recs.values() for v in vs)),
                           "per_kind": {}, "pooled": {}}
    for tol in EVENT_TOLS:
        tp = fp = fn = 0
        for k, vs in per_kind_recs.items():
            m = event_metrics(vs, tol)
            out["per_kind"].setdefault(k, {})[f"tol{int(tol)}"] = m
            tp, fp, fn = tp + m["tp"], fp + m["fp"], fn + m["fn"]
        P = tp / (tp + fp) if tp + fp else float("nan")
        R = tp / (tp + fn) if tp + fn else float("nan")
        out["pooled"][f"tol{int(tol)}"] = {"tp": tp, "fp": fp, "fn": fn, "precision": P, "recall": R,
                                            "f1": 2 * P * R / (P + R) if tp and (P + R) > 0 else 0.0}
    out["interval_match_tol10"] = rs.match_events(interval_pred, interval_truth, 10.0)
    return out


def coarse_accuracy(table: ArmTable) -> Dict[str, Any]:
    """Locomotion collapsed to HART's 4 coarse classes, argmax over known classes."""
    order = SCORE_ORDERS["locomotion"]
    coarse = {"stationary": 0, "walking": 1, "running": 2}
    tr = table.truth["locomotion"]
    keep = tr[:, :-1].any(axis=1)
    if not keep.any():
        return {"n": 0}
    P = table.probs["locomotion"][keep][:, :-1]
    T = tr[keep][:, :-1]
    C = np.zeros((len(P), 4))
    TC = np.zeros((len(P), 4), bool)
    for j, c in enumerate(order[:-1]):
        k = coarse.get(c, 3)
        C[:, k] += P[:, j]
        TC[:, k] |= T[:, j]
    pred = C.argmax(axis=1)
    hit = TC[np.arange(len(C)), pred]
    return {"n": int(len(C)), "accuracy": float(hit.mean())}


def score_arm(table: ArmTable, recs: Sequence[rx.Recording], val_ops: Optional[Dict[str, Dict[int, Dict]]] = None,
              with_events: bool = False) -> Dict[str, Any]:
    out: Dict[str, Any] = {"n_states": int(len(table.ts)), "refusals": sorted({v for v in table.refusals.values() if v})}
    for h in SCORED_HEADS:
        out[h] = head_metrics(table, h, (val_ops or {}).get(h))
    out["display"] = display_flips_per_hour(table)
    out["coarse"] = coarse_accuracy(table)
    if with_events:
        out["events"] = event_metrics_table(table, recs)
    if table.motion_heads:
        agg: Dict[str, Any] = {}
        for v in table.motion_heads.values():
            for k, x in v.items():
                if isinstance(x, (int, float)) and not isinstance(x, bool):
                    agg[k] = agg.get(k, 0) + x
                elif k in ("stamp", "refusal"):
                    agg.setdefault(k, x)
        out["motion_heads_report"] = agg
    return out


# ---------------------------------------------------------------------------
# Objective (VALIDATION only) and paired bootstrap
# ---------------------------------------------------------------------------

def objective(scored: Mapping[str, Any], heads: Sequence[str] = ("posture", "locomotion")) -> Tuple[float, float]:
    """(mean descriptive coverage@95 over scored posture+locomotion classes, mean known-class NLL).
    Higher is better for the first, lower for the second (tie-break)."""
    covs, nlls = [], []
    for h in heads:
        hm = scored.get(h) or {}
        for c, d in (hm.get("classes") or {}).items():
            covs.append(d["descriptive_cov95"]["coverage"])
        if hm.get("nll_known") is not None:
            nlls.append(hm["nll_known"])
    return (float(np.mean(covs)) if covs else 0.0, float(np.mean(nlls)) if nlls else float("inf"))


def _subject_stats(t: ArmTable, head: str, classes: Sequence[int], taus: Mapping[int, Optional[float]]) -> Dict[str, Dict[str, Any]]:
    """Per-subject additive statistics of one arm/head (so a subject resample is a sum)."""
    tr = t.truth[head]
    keep = tr.any(axis=1)
    out: Dict[str, Dict[str, Any]] = {}
    for s in np.unique(t.subject):
        m = keep & (t.subject == s)
        P, T = t.probs[head][m], tr[m]
        d: Dict[str, Any] = {}
        if len(P):
            pk = _known(head, P)
            Tk = T[:, :-1]
            hk = Tk.any(axis=1)
            mass = (pk * Tk).sum(axis=1)
            d["nll_sum"] = float(-np.log(np.clip(mass[hk], 1e-12, 1.0)).sum())
            d["nll_n"] = int(hk.sum())
            j = P[:, :-1].argmax(axis=1)
            conf = P[np.arange(len(P)), j]
            corr = T[np.arange(len(P)), j]
            b = rs.score_bins(conf)
            d["rc_c"] = np.bincount(b[corr], minlength=rs.NBINS)
            d["rc_w"] = np.bincount(b[~corr], minlength=rs.NBINS)
            am = P.argmax(axis=1)
            for c in classes:
                pos = T[:, c]
                ph, nh = rs.class_histograms(np.where(am == c, P[:, c], 0.0), pos)
                d[f"cov_{c}"] = (ph, nh)
                tau = taus.get(c)
                acc = (am == c) & (P[:, c] >= tau) if tau is not None else np.zeros(len(P), bool)
                d[f"rec_{c}"] = (int((acc & pos).sum()), int(pos.sum()))
        out[str(s)] = d
    return out


def _combine(stats: Sequence[Dict[str, Any]], kind: str, c: Optional[int] = None) -> float:
    st = [s for s in stats if s]
    if not st:
        return float("nan")
    if kind == "nll":
        n = sum(s["nll_n"] for s in st)
        return sum(s["nll_sum"] for s in st) / n if n else float("nan")
    if kind == "aurc":
        r = rs.risk_coverage_hist(sum(s["rc_c"] for s in st), sum(s["rc_w"] for s in st))
        return r["aurc"] if r["aurc"] is not None else float("nan")
    if kind == "cov95_desc":
        ph = sum(s[f"cov_{c}"][0] for s in st)
        nh = sum(s[f"cov_{c}"][1] for s in st)
        if ph.sum() == 0:
            return float("nan")
        return rs.coverage_at_precision_hist(ph, nh, min_bin=300, n_min=60, grid_step=5)["coverage"]
    if kind == "recall_at_tau":
        tp = sum(s[f"rec_{c}"][0] for s in st)
        n = sum(s[f"rec_{c}"][1] for s in st)
        return tp / n if n else float("nan")
    raise ValueError(kind)


def _flip_stats(t: ArmTable) -> Dict[str, Tuple[int, float]]:
    out: Dict[str, List[float]] = {}
    for sid in np.unique(t.seq):
        m = t.seq == sid
        st = rs.ArmStates(record_id=sid, recording_id=sid, arm=t.arm, ts=t.ts[m], heads={}, display=t.display[m],
                          overall_confidence=np.zeros(int(m.sum())))
        f, h = rs.display_flips(st)
        s = str(t.subject[m][0])
        acc = out.setdefault(s, [0.0, 0.0])
        acc[0] += f
        acc[1] += h
    return {k: (int(v[0]), float(v[1])) for k, v in out.items()}


def paired_bootstrap(ta: ArmTable, tb: ArmTable, val_ops: Optional[Mapping[str, Mapping[str, Dict]]] = None,
                     n_boot: int = 1000, seed: int = 0, heads: Sequence[str] = ("posture", "locomotion")) -> Dict[str, Any]:
    """Paired subject-cluster bootstrap of B − A (P2's ``bootstrap.cluster_bootstrap``; one row per subject, the
    metric sums per-subject sufficient statistics of both arms over the SAME resampled subjects).

    AURC here is the 0.001-binned estimator (``replay_score.risk_coverage_hist``); its point value is reported
    next to the exact P2 ``aurc`` of ``score_arm``. ``coverage95_val_tau`` uses each arm's own frozen VAL tau
    (0 when the arm had no strong VAL operating point for the class)."""
    from .bootstrap import cluster_bootstrap
    subjects = sorted(set(ta.subject.tolist()))
    sub_arr = np.asarray(subjects)
    out: Dict[str, Any] = {"a": ta.arm, "b": tb.arm, "n_boot": n_boot, "n_subjects": len(subjects)}

    def boot(fn):
        return cluster_bootstrap(lambda idx: fn([subjects[i] for i in idx]), sub_arr, n_boot=n_boot, seed=seed)

    for h in heads:
        classes = scored_classes(ta, h, min_pos=60)
        taus = {}
        for arm_t in (ta, tb):
            ops = ((val_ops or {}).get(arm_t.arm) or {}).get(h) or {}
            taus[arm_t.arm] = {c: (ops[c]["tau"] if c in ops and ops[c]["status"] == "strong" else None) for c in classes}
        sa = _subject_stats(ta, h, classes, taus[ta.arm])
        sb = _subject_stats(tb, h, classes, taus[tb.arm])

        def diff(kind, c=None):
            return lambda subs: _combine([sb[s] for s in subs], kind, c) - _combine([sa[s] for s in subs], kind, c)
        hd: Dict[str, Any] = {"nll_known": boot(diff("nll")), "aurc_binned": boot(diff("aurc"))}
        for c in classes:
            cd = {"cov95_desc": boot(diff("cov95_desc", c))}
            if val_ops is not None:
                cd["coverage95_val_tau"] = boot(diff("recall_at_tau", c))
                cd["val_tau"] = {ta.arm: taus[ta.arm][c], tb.arm: taus[tb.arm][c]}
            hd[SCORE_ORDERS[h][c]] = cd
        out[h] = hd
    fa, fb = _flip_stats(ta), _flip_stats(tb)

    def flips(subs):
        va = [fa[s] for s in subs if s in fa]
        vb = [fb[s] for s in subs if s in fb]
        ha, hb = sum(v[1] for v in va), sum(v[1] for v in vb)
        if not ha or not hb:
            return float("nan")
        return sum(v[0] for v in vb) / hb - sum(v[0] for v in va) / ha
    out["display_flips_per_hour"] = boot(flips)
    return out


def _json_safe(o: Any) -> Any:
    if isinstance(o, dict):
        return {str(k): _json_safe(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [_json_safe(v) for v in o]
    if isinstance(o, (np.floating, float)):
        f = float(o)
        return f if math.isfinite(f) else None
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, np.bool_):
        return bool(o)
    if isinstance(o, np.ndarray):
        return _json_safe(o.tolist())
    return o


# ---------------------------------------------------------------------------
# Sweep (VALIDATION) and final (TEST) drivers
# ---------------------------------------------------------------------------

DEFAULT_WEIGHTS = {"locomotion": 0.25, "posture": 0.25, "arm": 0.25, "body_budget": 0.5, "arm_budget": 0.5,
                   "hart_redundancy": 0.5}
BODY_GRID = ((0.1, 0.1), (0.1, 0.25), (0.1, 0.4), (0.25, 0.1), (0.25, 0.25), (0.4, 0.1))
# The arm chain is fed by the body posterior, never the other way round, so the arm weight cannot move the
# posture / locomotion objective: it stays at the candidate default and is not swept.
ARM_GRID = (0.25,)
RHO_GRID = (0.25, 0.5, 0.75)


def sweep_configs(rho_extra: Sequence[float] = ()) -> List[Dict[str, float]]:
    out = []
    for l, p in BODY_GRID:
        for a in ARM_GRID:
            for rho in tuple(RHO_GRID) + tuple(rho_extra):
                out.append({"locomotion": l, "posture": p, "arm": a, "body_budget": 0.5, "arm_budget": 0.5,
                            "hart_redundancy": float(rho)})
    return out


def heads_cache_path(bundle_id: str, dataset: str, split: str, hop: int) -> str:
    return os.path.join(rd.replay_root(), "cache", "heads", bundle_id, f"{dataset}_{split}_hop{hop}.npz")


def get_heads(bundle_dir: str, dataset: str, split: str, recs: Sequence[rx.Recording], hop: Optional[int] = None,
              jobs: int = 6) -> Tuple[Dict[str, rx.HeadsWindows], Dict[str, Any]]:
    from . import replay_inertia as ri
    rt = ri.load_runtime(bundle_dir)
    hop = int(hop if hop is not None else rt.bundle.preprocessing["hop_s"])
    path = heads_cache_path(rt.bundle.bundle_id, dataset, split, hop)
    if os.path.isfile(path):
        heads, meta = ri.load_heads(path)
        if meta.get("bundle", {}).get("bundle_sha256") == rt.bundle.bundle_sha256:
            return heads, meta
    os.makedirs(os.path.dirname(path), exist_ok=True)
    retrying(lambda: ri.main(["--bundle", bundle_dir, "--dataset", dataset, "--split", split, "--hop", str(hop),
                              "--out", path, "--jobs", str(jobs)]), f"heads {dataset}/{split}")
    return ri.load_heads(path)


def _variants(dataset: str, kind) -> Dict[str, List[str]]:
    """kind: "baseline" (A0s / A0 / A1), "inertia" (A2 / A3), "nav" (naive average), or a bool for the old
    callers (True = "inertia", False = everything)."""
    if kind is True:
        kind = "inertia"
    if kind is False:
        kind = "all"
    if dataset == "capture24":                       # no gyro -> no HART
        return {"baseline": {"noenc": ["streams", "hart"]}, "inertia": {"noenc": ["inertia"]}, "nav": {},
                "all": {"noenc": ["streams", "hart", "inertia"]}}[kind]
    return {"baseline": {"full": ["streams", "hart"], "noenc": ["hart"]},
            "inertia": {"full": ["inertia", "hart+inertia"]},
            "nav": {"full": ["naive_average"]},
            "all": {"full": list(rx.HARNESS_ARMS), "noenc": ["hart"]}}[kind]


def _report_arms_c24(decoded):
    # Capture-24 files carry no encoder windows: harness `streams` = A0s, `hart` = A0, `inertia` = A2.
    m = {"A0s": ("noenc", "streams"), "A0": ("noenc", "hart"), "A2": ("noenc", "inertia")}
    return {a: decoded[k] for a, k in m.items() if k in decoded}


def decode_and_table(dataset: str, recs, heads, info, weights, workdir, kind, jobs, chunk):
    workdir = os.path.join(WORK_DIR, os.path.basename(os.path.dirname(workdir.rstrip("/"))) or "run",
                           f"{dataset}-{os.getpid()}")   # unique per process: concurrent runs never share files
    variants = _variants(dataset, kind)
    if not variants:
        return {}, {}
    dec, dinfo = decode(recs, workdir, variants, heads=heads, bundle_info=info, weights=weights, chunk=chunk, jobs=jobs)
    arms = _report_arms_c24(dec) if dataset == "capture24" else report_arms(dec)
    tables = {a: build_table(a, recs, s) for a, s in arms.items()}
    return tables, dinfo


def xctest_fingerprint(bundle: str = None) -> str:
    import hashlib
    bundle = bundle or XCTEST_BUNDLE
    exe = os.path.join(bundle, "Contents", "MacOS", "StrandAnalyticsPackageTests")
    h = hashlib.sha256()
    with open(exe, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def baseline_tables(dataset: str, split: str, recs, jobs: int = 4) -> Tuple[Dict[str, ArmTable], Dict[str, Any]]:
    """A0s / A0 / (WISDM) A1 tables — no Inertia involved — decoded once per (dataset, split, build) and cached
    (pickle) so the Inertia stages reuse exactly the same decode."""
    import pickle
    fp = xctest_fingerprint()
    path = os.path.join(rd.replay_root(), "runs", "baseline", f"{dataset}_{split}.pkl")
    if os.path.isfile(path):
        class _Unpickler(pickle.Unpickler):   # caches written by `python -m ...replay_eval` name this module __main__
            def find_class(self, module, name):
                if module == "__main__" and name in globals():
                    return globals()[name]
                return super().find_class(module, name)
        with open(path, "rb") as f:
            d = _Unpickler(f).load()
        if d.get("xctest_sha256") == fp and d.get("n_recs") == len(recs):
            return d["tables"], d["info"]
    chunk = 40 if dataset == "wisdm" else 4
    tables, dinfo = decode_and_table(dataset, recs, None, None, None, os.path.join(rd.replay_root(), "runs", "baseline", "work"),
                                     "baseline", jobs, chunk)
    check_alignment(tables)
    os.makedirs(os.path.dirname(path), exist_ok=True)

    def _save():
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            pickle.dump({"xctest_sha256": fp, "n_recs": len(recs), "tables": tables, "info": dinfo}, f)
        os.replace(tmp, path)
    retrying(_save, f"baseline cache {dataset}/{split}")
    return tables, dinfo


REPLAY_LEDGER = "replay_test_ledger.jsonl"


def replay_vault(load_test: Callable[[], Dict[str, Any]], ledger_dir: Optional[str] = None):
    """TestVault for a replay TEST decode: the test recordings (and Inertia windows) are loaded only inside
    ``evaluate_once``; identity = recording ids + subjects."""
    from .experiments import EVAL_ROOT
    from .integrity import TestVault
    return TestVault(load_test, lambda p: [np.asarray([r.recording_id for r in p["recs"]]),
                                           np.asarray([r.subject for r in p["recs"]])],
                     os.path.join(ledger_dir or EVAL_ROOT, REPLAY_LEDGER))


def run_baseline(dataset: str, out_dir: str, jobs: int = 4, n_boot: int = 1000, rerun_reason: Optional[str] = None,
                 rerun_detail: Optional[str] = None, ledger_dir: Optional[str] = None) -> Dict[str, Any]:
    """Bundle-independent arms on VAL (operating points) and TEST (scored once, through a ledgered vault):
    A0s, A0, (WISDM) A1."""
    from .experiments import REPLAY_DECLARED
    t = time.time()
    vrecs = rx.load_recordings(os.path.join(rd.replay_root(), f"recordings_{dataset}_val.npz"))
    vt, _ = baseline_tables(dataset, "val", vrecs, jobs)
    vops = {a: {h: val_operating_points(tb, h) for h in SCORED_HEADS} for a, tb in vt.items()}
    fp = xctest_fingerprint()

    def load_test():
        return {"recs": rx.load_recordings(os.path.join(rd.replay_root(), f"recordings_{dataset}_test.npz"))}

    def evaluator(payload):
        trecs = payload["recs"]
        tt, tinfo = baseline_tables(dataset, "test", trecs, jobs)
        res: Dict[str, Any] = {"split": "test", "dataset": dataset, "xctest_sha256": fp,
                               "decode": tinfo, "arms": {}, "val_operating_points":
                               _json_safe({a: {h: {SCORE_ORDERS[h][c]: v for c, v in d.items()} for h, d in ops.items()}
                                           for a, ops in vops.items()})}
        for a, tb in tt.items():
            res["arms"][a] = _json_safe(score_arm(tb, trecs, vops.get(a), with_events=(dataset == "capture24")))
        pairs = [("A0s", "A0")] + ([("A0", "A1"), ("A0s", "A1")] if dataset == "wisdm" else [])
        res["paired_bootstrap"] = {f"{b}-{a}": _json_safe(paired_bootstrap(tt[a], tt[b], vops, n_boot=n_boot))
                                   for a, b in pairs}
        return res

    res = replay_vault(load_test, ledger_dir).evaluate_once(f"replay-baseline/{dataset}", fp, evaluator, REPLAY_DECLARED,
                                                           rerun_reason, rerun_detail)
    res["seconds"] = round(time.time() - t, 1)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, f"baseline_{dataset}.json"), "w", encoding="utf-8") as f:
        json.dump(_json_safe(res), f, indent=1)
    return res


def run_sweep(bundle_dir: str, dataset: str, out_dir: str, jobs: int = 4, rho_extra: Sequence[float] = ()) -> Dict[str, Any]:
    """VALIDATION only: baseline arms once, then every config for the Inertia arms; pick by objective()."""
    from . import replay_inertia as ri
    t = time.time()
    os.makedirs(out_dir, exist_ok=True)
    recs = rx.load_recordings(os.path.join(rd.replay_root(), f"recordings_{dataset}_val.npz"))
    heads, hmeta = get_heads(bundle_dir, dataset, "val", recs)
    info = hmeta["bundle"]
    chunk = 40 if dataset == "wisdm" else 4
    base, _ = baseline_tables(dataset, "val", recs, jobs)
    if dataset == "wisdm":           # the naive average does not depend on the Inertia weights
        nav, _ = decode_and_table(dataset, recs, heads, info, DEFAULT_WEIGHTS, os.path.join(out_dir, "work"), "nav", jobs, chunk)
        base = {**base, **nav}
    check_alignment(base)
    result: Dict[str, Any] = {"banner": rd.STANDIN_BANNER, "split": "val", "dataset": dataset,
                              "bundle": {k: v for k, v in info.items() if k != "bundle"}, "objective":
                              "max mean descriptive coverage@95 (CP one-sided 95% >= .95, n_acc >= 60) over posture+"
                              "locomotion classes; tie-break min mean known-class NLL", "baseline": {}, "configs": []}
    val_ops: Dict[str, Dict[str, Dict[int, Dict]]] = {}
    for a, tb in base.items():
        result["baseline"][a] = _json_safe(score_arm(tb, recs))
        val_ops[a] = {h: val_operating_points(tb, h) for h in SCORED_HEADS}
    progress = os.path.join(out_dir, f"sweep_{dataset}.progress.jsonl")
    done: Dict[str, Any] = {}
    if os.path.isfile(progress):
        with open(progress, "r", encoding="utf-8") as f:
            for line in f:
                if line.strip():
                    r = json.loads(line)
                    if r.get("bundle_sha256") == info["bundle_sha256"]:
                        done[json.dumps(r["row"]["weights"], sort_keys=True)] = r["row"]

    def run_cfg(cfg: Dict[str, float]) -> Dict[str, Any]:
        key = json.dumps(cfg, sort_keys=True)
        if key in done:
            return done[key]
        tabs, _ = decode_and_table(dataset, recs, heads, info, cfg, os.path.join(out_dir, "work"), True, jobs, chunk)
        row: Dict[str, Any] = {"weights": cfg}
        for a, tb in tabs.items():
            sc = score_arm(tb, recs)
            ops = {h: val_operating_points(tb, h) for h in SCORED_HEADS}
            row[a] = {"objective": objective(sc), "summary": _json_safe(sc),
                      "val_ops": _json_safe({h: {SCORE_ORDERS[h][c]: v for c, v in d.items()} for h, d in ops.items()})}

        def _append(row=row):
            with open(progress, "a", encoding="utf-8") as f:
                f.write(json.dumps(_json_safe({"bundle_sha256": info["bundle_sha256"], "row": row})) + "\n")
        retrying(_append, "sweep progress")
        done[key] = row
        print(json.dumps({"cfg": cfg, **{a: row[a]["objective"] for a in tabs}}), flush=True)
        return row

    def cfg(l, p, rho=0.5):
        return {"locomotion": l, "posture": p, "arm": ARM_GRID[0], "body_budget": 0.5, "arm_budget": 0.5,
                "hart_redundancy": float(rho)}

    def pick(rows, a):
        return max(rows, key=lambda r: (r[a]["objective"][0], -r[a]["objective"][1]))

    # Stage 1: body weights at the default rho (C24: 3 points spanning posture-heavy .. locomotion-heavy).
    grid = BODY_GRID if dataset == "wisdm" else ((0.1, 0.4), (0.25, 0.25), (0.4, 0.1))
    stage1 = [run_cfg(cfg(l, p)) for l, p in grid]
    best: Dict[str, Any] = {}
    b2 = pick(stage1, "A2")
    best["A2"] = {"weights": b2["weights"], "objective": b2["A2"]["objective"]}
    rows_a3: List[Dict[str, Any]] = []
    if dataset == "wisdm":
        # Stage 2: rho for A3 at A3's best body weights (rho only acts while the HART channel speaks).
        b3 = pick(stage1, "A3")
        rows_a3 = list(stage1) + [run_cfg(cfg(b3["weights"]["locomotion"], b3["weights"]["posture"], r))
                                  for r in sorted(set(RHO_GRID) | {round(float(x), 2) for x in rho_extra}) if r != 0.5]
        b3 = pick(rows_a3, "A3")
        best["A3"] = {"weights": b3["weights"], "objective": b3["A3"]["objective"]}
    result["configs"] = list(done.values())
    result["selected"] = best
    # VAL operating points of the Inertia arms at the defaults and at the selected weights (frozen for TEST)
    for a in best:
        dflt = done[json.dumps(DEFAULT_WEIGHTS if a == "A2" else cfg(0.25, 0.25), sort_keys=True)]
        sel = done[json.dumps(best[a]["weights"], sort_keys=True)]
        val_ops[f"{a}@defaults"] = _ops_from_json(dflt[a]["val_ops"])
        val_ops[f"{a}@selected"] = _ops_from_json(sel[a]["val_ops"])
    result["val_operating_points"] = _json_safe({a: {h: {SCORE_ORDERS[h][c]: v for c, v in d.items()}
                                                     for h, d in ops.items()} for a, ops in val_ops.items()})
    result["seconds"] = round(time.time() - t, 1)
    with open(os.path.join(out_dir, f"sweep_{dataset}.json"), "w", encoding="utf-8") as f:
        json.dump(_json_safe(result), f, indent=1)
    return result


def _ops_from_json(d: Mapping[str, Any]) -> Dict[str, Dict[int, Dict]]:
    return {h: {SCORE_ORDERS[h].index(c): v for c, v in per.items()} for h, per in d.items()}


def run_final(bundle_dir: str, dataset: str, sweep_path: str, out_dir: str, jobs: int = 4, n_boot: int = 1000,
              rerun_reason: Optional[str] = None, rerun_detail: Optional[str] = None,
              ledger_dir: Optional[str] = None) -> Dict[str, Any]:
    """TEST, opened once per (dataset, bundle) through a ledgered TestVault: defaults (pre-specified) and the
    VAL-selected weights. A crash before the ledger stamp leaves resumable part files; a completed decode can
    only be repeated with an enumerated rerun reason."""
    from .bundle import load_bundle
    from .experiments import REPLAY_DECLARED
    t = time.time()
    os.makedirs(out_dir, exist_ok=True)
    with open(sweep_path, "r", encoding="utf-8") as f:
        sweep = json.load(f)
    b = load_bundle(bundle_dir)
    if b.bundle_sha256 != sweep["bundle"]["bundle_sha256"]:
        raise RuntimeError("sweep was run with a different bundle")

    def load_test():
        recs = rx.load_recordings(os.path.join(rd.replay_root(), f"recordings_{dataset}_test.npz"))
        heads, hmeta = get_heads(bundle_dir, dataset, "test", recs)
        return {"recs": recs, "heads": heads, "hmeta": hmeta}

    def evaluator(payload):
        return _final_body(payload, bundle_dir, dataset, sweep, out_dir, jobs, n_boot, t)

    res = replay_vault(load_test, ledger_dir).evaluate_once(f"replay-final/{dataset}/{b.bundle_id}", b.bundle_sha256,
                                                           evaluator, REPLAY_DECLARED, rerun_reason, rerun_detail)
    res["seconds"] = round(time.time() - t, 1)
    with open(os.path.join(out_dir, f"final_{dataset}.json"), "w", encoding="utf-8") as f:
        json.dump(_json_safe(res), f, indent=1)
    return res


def _final_body(payload, bundle_dir: str, dataset: str, sweep: Mapping[str, Any], out_dir: str, jobs: int, n_boot: int,
                t: float) -> Dict[str, Any]:
    recs, heads, hmeta = payload["recs"], payload["heads"], payload["hmeta"]
    info = hmeta["bundle"]
    if info["bundle_sha256"] != sweep["bundle"]["bundle_sha256"]:
        raise RuntimeError("sweep was run with a different bundle")
    chunk = 40 if dataset == "wisdm" else 4
    vops = {a: _ops_from_json(v) for a, v in sweep["val_operating_points"].items()}
    res: Dict[str, Any] = {"banner": rd.STANDIN_BANNER, "split": "test", "dataset": dataset,
                           "bundle": {k: v for k, v in info.items() if k != "bundle"},
                           "heads_windows": {k: v for k, v in hmeta.get("stats", {}).items()} if dataset == "wisdm" else None,
                           "configs": {}}
    base_tables: Optional[Dict[str, ArmTable]] = None
    for label in ("defaults", "selected"):
        part = os.path.join(out_dir, f"final_{dataset}.{label}.json")
        if os.path.isfile(part):
            with open(part, "r", encoding="utf-8") as f:
                prev = json.load(f)
            if prev.get("bundle_sha256") == info["bundle_sha256"]:
                res["configs"][label] = prev["config"]
                continue
        work = os.path.join(out_dir, "work")
        if base_tables is None:
            fixed, finfo = baseline_tables(dataset, "test", recs, jobs)         # A0s / A0 / A1, cached
            nav, _ = decode_and_table(dataset, recs, heads, info, DEFAULT_WEIGHTS, work, "nav", jobs, chunk)
            inert, iinfo = decode_and_table(dataset, recs, heads, info, DEFAULT_WEIGHTS, work, "inertia", jobs, chunk)
            base_tables = {**fixed, **nav, **inert}
        if label == "defaults":
            weights: Dict[str, Any] = {a: DEFAULT_WEIGHTS for a in sweep["selected"]}
            tables, dinfo = dict(base_tables), {"fixed_arms": "baseline cache (same build)", "inertia": iinfo}
        else:
            weights = {a: sweep["selected"][a]["weights"] for a in sweep["selected"]}
            tables, dinfo = dict(base_tables), {"reused_fixed_arms_from": "defaults"}
            for a, w in weights.items():  # each Inertia arm with its own VAL-selected weights
                if w == DEFAULT_WEIGHTS:
                    dinfo[f"{a}_decode"] = "VAL-selected weights equal the defaults: same decode reused"
                    continue
                t2, d2 = decode_and_table(dataset, recs, heads, info, w, work, "inertia", jobs, chunk)
                tables[a] = t2[a]
                dinfo[f"{a}_decode"] = d2
        check_alignment(tables)
        sc: Dict[str, Any] = {"weights": weights, "decode": dinfo, "arms": {}}
        for a, tb in tables.items():
            key = f"{a}@{label}" if a in ("A2", "A3") else a
            sc["arms"][a] = _json_safe(score_arm(tb, recs, vops.get(key), with_events=(dataset == "capture24")))
        ops_for = {a: vops.get(f"{a}@{label}" if a in ("A2", "A3") else a) for a in tables}
        pairs = [("A0", "A2")] + ([("A1", "A3"), ("A1", "NAV"), ("A0", "A1")] if dataset == "wisdm" else [])
        sc["paired_bootstrap"] = {}
        for a, b in pairs:
            sc["paired_bootstrap"][f"{b}-{a}"] = _json_safe(paired_bootstrap(tables[a], tables[b], ops_for, n_boot=n_boot))
        res["configs"][label] = sc

        def _save(sc=sc, part=part):
            with open(part, "w", encoding="utf-8") as f:
                json.dump(_json_safe({"bundle_sha256": info["bundle_sha256"], "config": sc}), f)
        retrying(_save, f"final {label}")
        print(json.dumps({"label": label, "seconds": round(time.time() - t, 1)}), flush=True)
    return res


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse
    import warnings
    warnings.filterwarnings("ignore", message=r".*encountered in matmul", category=RuntimeWarning)
    ap = argparse.ArgumentParser(prog="python -m activity_context.inertia.replay_eval")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sweep")
    s.add_argument("--bundle", required=True)
    s.add_argument("--dataset", choices=("wisdm", "capture24"), required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--jobs", type=int, default=4)
    s.add_argument("--rho-extra", type=float, nargs="*", default=())
    from .integrity import RERUN_REASONS
    bl = sub.add_parser("baseline")
    bl.add_argument("--dataset", choices=("wisdm", "capture24"), required=True)
    bl.add_argument("--out", required=True)
    bl.add_argument("--jobs", type=int, default=4)
    bl.add_argument("--n-boot", type=int, default=1000)
    f = sub.add_parser("final")
    f.add_argument("--bundle", required=True)
    f.add_argument("--dataset", choices=("wisdm", "capture24"), required=True)
    f.add_argument("--sweep", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--jobs", type=int, default=4)
    f.add_argument("--n-boot", type=int, default=1000)
    for p_ in (bl, f):
        p_.add_argument("--rerun-reason", choices=sorted(RERUN_REASONS))
        p_.add_argument("--rerun-detail")
    a = ap.parse_args(argv)
    if a.cmd == "baseline":
        r = run_baseline(a.dataset, a.out, a.jobs, a.n_boot, a.rerun_reason, a.rerun_detail)
        print(json.dumps({"seconds": r["seconds"]}))
        return 0
    if a.cmd == "sweep":
        r = run_sweep(a.bundle, a.dataset, a.out, a.jobs, a.rho_extra)
        print(json.dumps(_json_safe(r["selected"])))
    else:
        r = run_final(a.bundle, a.dataset, a.sweep, a.out, a.jobs, a.n_boot, a.rerun_reason, a.rerun_detail)
        print(json.dumps({"seconds": r["seconds"]}))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())


# ---------------------------------------------------------------------------
# rho-hat: residual log-LR correlation of the HART and Inertia-locomotion channels (INERTIA1.md §7)
# ---------------------------------------------------------------------------
# Mirrors of ActivityContextModel.profiles (decoder hsmm-1.3): per non-unknown body mode, the HART encoder
# compatibility (`encoder`) and the locomotion soft mapping (`locomotion`). Order = BodyMode raw values 1..14.
_STAT_ENC = {"stationary": 0.86, "other_movement": 0.10, "walking": 0.03, "running": 0.01}
_TRANS_ENC = {"other_movement": 0.45, "stationary": 0.35, "walking": 0.18, "running": 0.02}
_TRANS_LOCO = {"stationary": 0.85, "other": 0.10}
DECODER_MODES: Tuple[Tuple[str, Dict[str, float], Dict[str, float]], ...] = (
    ("bedRest", _STAT_ENC, {"stationary": 0.97}),
    ("seated", _STAT_ENC, {"stationary": 0.97}),
    ("upright", _STAT_ENC, {"stationary": 0.97}),
    ("walk", {"walking": 0.86, "other_movement": 0.07, "stationary": 0.05, "running": 0.02},
     {"walking": 0.93, "brisk_walking": 0.04}),
    ("briskWalk", {"walking": 0.72, "running": 0.12, "other_movement": 0.08, "brisk_walking": 0.06, "stationary": 0.02},
     {"brisk_walking": 0.88, "walking": 0.08, "running": 0.02}),
    ("run", {"running": 0.86, "walking": 0.10, "other_movement": 0.04}, {"running": 0.93, "brisk_walking": 0.04}),
    ("stairs", {"stairs": 0.90, "walking": 0.60, "other_movement": 0.20, "running": 0.05}, {"stairs": 0.70, "walking": 0.25}),
    ("cycling", {"cycling": 0.90, "other_movement": 0.55, "stationary": 0.15, "walking": 0.10, "running": 0.03},
     {"cycling": 0.80, "other": 0.10}),
    ("vehicle", {"vehicle_motion": 0.90, "stationary": 0.40, "other_movement": 0.35, "walking": 0.05},
     {"vehicle_motion": 0.80, "stationary": 0.10}),
    ("otherExercise", {"other_movement": 0.70, "running": 0.20, "walking": 0.10, "stationary": 0.05}, {"other": 0.80}),
    ("sitToStand", _TRANS_ENC, _TRANS_LOCO), ("standToSit", _TRANS_ENC, _TRANS_LOCO),
    ("lyingDown", _TRANS_ENC, _TRANS_LOCO), ("gettingUp", _TRANS_ENC, _TRANS_LOCO),
)


def hart_loglr(probs: Mapping[str, float]) -> np.ndarray:
    """log of the decoder's encoder-channel likelihood per mode (ActivityContextModel.score, channel 4)."""
    known = {k: v for k, v in probs.items() if k != "unknown" and v > 0}
    tot = sum(known.values())
    out = np.zeros(len(DECODER_MODES))
    for m, (_, enc, _) in enumerate(DECODER_MODES):
        s = sum((p / tot) * enc.get(k, 0.02) for k, p in sorted(known.items()))
        out[m] = math.log(max(0.01, s))
    return out


def prepare_inertia_locomotion(spec: Mapping[str, Any]):
    """Python mirror of PreparedMotionHead.prepare for the locomotion head (merge_into, covers, eps floor)."""
    order = list(spec["class_order"])
    prior = spec["prior"]
    status = spec.get("status", {})
    merge = spec.get("merge_into", {})
    covers = spec.get("covers", {})
    supported = [c for c in order if c in prior]
    kept = [c for c in supported if not (status.get(c) == "abstain" and c not in merge)]

    def root(c):
        hops = 0
        while c in merge and hops < 32:
            c = merge[c]
            hops += 1
        return c
    roots: List[str] = []
    group_of = []
    for c in kept:
        r = root(c)
        if r not in roots:
            roots.append(r)
        group_of.append(roots.index(r))
    kp = sum(prior[c] for c in kept)
    gprior = np.zeros(len(roots))
    for i, c in enumerate(kept):
        gprior[group_of[i]] += prior[c] / kp
    compat = []
    for _, _, loco in DECODER_MODES:
        raw = np.array([max([loco.get(c, 0.0)] + [loco.get(x, 0.0) for x in covers.get(c, [])]) for c in kept])
        if raw.sum() <= 0:
            compat.append(None)
            continue
        row = raw / raw.sum() + 0.02
        row = row / row.sum()
        g = np.zeros(len(roots))
        for i, v in enumerate(row):
            g[group_of[i]] += v
        compat.append(g)
    return kept, group_of, gprior, compat


def inertia_loglr(q: Mapping[str, float], prepared) -> Optional[np.ndarray]:
    kept, group_of, gprior, compat = prepared
    qg = np.zeros(len(gprior))
    for i, c in enumerate(kept):
        qg[group_of[i]] += q.get(c, 0.0)
    tot = qg.sum()
    if tot <= 0:
        return None
    r = np.maximum(qg / tot, 1e-9) / gprior
    out = np.zeros(len(DECODER_MODES))
    for m, row in enumerate(compat):
        out[m] = 0.0 if row is None else math.log(min(10.0, max(0.1, float(row @ r))))
    return out


def rho_hat(recs: Sequence[rx.Recording], heads: Mapping[str, rx.HeadsWindows], bundle_wire: Mapping[str, Any],
            hop_s: int) -> Dict[str, Any]:
    """Pooled Pearson correlation of per-window mode-centred log-LRs (HART vs Inertia locomotion) over HART
    windows that have a fresh, non-OOD Inertia window (age < hop). Computed on VALIDATION recordings."""
    prep = prepare_inertia_locomotion(bundle_wire["heads"]["locomotion"])
    xs, ys, subj = [], [], []
    for r in recs:
        h = heads.get(r.recording_id)
        if h is None or "locomotion" not in h.probs or not len(r.hart_e):
            continue
        order = h.class_order["locomotion"]
        he = h.e
        for i in range(len(r.hart_e)):
            e = r.hart_e[i]
            j = np.flatnonzero((he <= e) & (e - he < hop_s))
            if not len(j):
                continue
            k = int(j[np.argmax(he[j])])
            if h.is_ood is not None and bool(h.is_ood[k]):
                continue
            q = {c: float(v) for c, v in zip(order, h.probs["locomotion"][k]) if np.isfinite(v)}
            li = inertia_loglr(q, prep)
            if li is None:
                continue
            lh = hart_loglr({c: float(r.hart_probs[i, qq]) for qq, c in enumerate(rx.HART_ORDER)})
            xs.append(lh - lh.mean())
            ys.append(li - li.mean())
            subj.append(r.subject)
    if not xs:
        return {"n_windows": 0, "rho_hat": None}
    X, Y = np.concatenate(xs), np.concatenate(ys)
    rho = float(np.corrcoef(X, Y)[0, 1])
    per = {}
    S = np.repeat(np.asarray(subj), len(DECODER_MODES))
    for s in np.unique(S):
        m = S == s
        per[str(s)] = float(np.corrcoef(X[m], Y[m])[0, 1])
    return {"n_windows": len(xs), "rho_hat": rho, "per_subject": per,
            "definition": "Pearson r of mode-centred log-LR vectors (14 non-unknown body modes), pooled over HART windows "
                          "with a fresh non-OOD Inertia window; decoder compat tables mirrored from hsmm-1.3"}
