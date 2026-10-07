"""Decoder replay with HART v1 and the ElderNet gait-quality channel (agent R).

Extends the system comparison (``replay_eval``) with:

* **HART v1** (``hart-wisdm-v1``): per-window outputs produced by agent HF with the same stream / window code as
  R's v0 files (``hart_v1_wisdm_{split}.npz``: identical windows, new probabilities and labels).
* **ElderNet** (``gait-quality-1``): the served per-window outputs saved under ``$ELDERNET_REPLAY_DIR`` (default
  ``$INERTIA_DATA_ROOT/eldernet-replay``; MANIFEST.json) — served defaults: uncalibrated, threshold 0.5, hop 5.
  They enter the decoder through the harness's ElderNet arms (ELDERNET.md "Replay record format").
* Inertia: the sealed stand-in bundle ``shadow-primary-hc`` at the INERTIA1 §7 candidate defaults.
  STAND-IN, NOT INERTIA-1.

Report arms (harness arm on a file variant; ``noenc`` = no encoder windows, ``v0`` / ``v1`` = HART windows):

WISDM: A0 = noenc/hart, E = noenc/eldernet, A1v0 = v0/hart, A1v1 = v1/hart, A1v1+I = v1/hart+inertia,
A1v1+E = v1/hart+eldernet, A1v1+E+I = v1/hart+eldernet+inertia.
Capture-24: A0 = noenc/hart, E = noenc/eldernet, I = noenc/hart+inertia, E+I = noenc/hart+eldernet+inertia.

WISDM blocks whose sampling rate switches between 20 and ~100 Hz are time-scaled in R's recordings (one nominal
rate per block, replay_data); they are detected from the raw clock and excluded from EVERY arm here (ElderNet's
windows are on the true clock and cannot be aligned with them).

Weights: ElderNet weight and its redundancy floors chosen on VALIDATION only with the pre-registered objective
(``replay_eval.objective``); floors are never below the measured ρ̂. TEST is opened once per dataset through a
ledgered ``TestVault`` (declared experiments ``replay-gait/wisdm`` and ``replay-gait/capture24``).
"""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import json
import math
import os
import time
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import replay_data as rd
from . import replay_eval as ev
from . import replay_export as rx

# ---------------------------------------------------------------------------
# Constants (pre-registered before any VAL / TEST decode of these arms)
# ---------------------------------------------------------------------------

GAIT_PRIOR = 0.065                  # ELDERNET.md §8: Capture-24 VAL gait share of labelled windows (hop 5)
GAIT_DEFAULT_WEIGHT = 0.25          # GaitQualityEvidenceConfig candidate default
GAIT_DEFAULT_RHO = 0.65             # hartRedundancy / inertiaRedundancy candidate defaults
GAIT_BUDGET = 0.5                   # accelerometerBudget (Inertia's body budget)
GAIT_W_GRID = (0.10, 0.25, 0.40)
RHO_STEPS = (0.80, 0.95)            # redundancy floors tried above the default floor
INERTIA_WEIGHTS = dict(ev.DEFAULT_WEIGHTS)   # Inertia at the INERTIA1 §7 candidate defaults in every arm
INERTIA_BUNDLE = "shadow-primary-hc"
DECLARED = ("replay-gait/capture24", "replay-gait/wisdm")
MIXED_RATE_TOL_S = 3.0

ARMS: Dict[str, Dict[str, Tuple[str, str]]] = {
    "wisdm": {"A0": ("noenc", "hart"), "E": ("noenc", "eldernet"), "A1v0": ("v0", "hart"), "A1v1": ("v1", "hart"),
              "A1v1+I": ("v1", "hart+inertia"), "A1v1+E": ("v1", "hart+eldernet"),
              "A1v1+E+I": ("v1", "hart+eldernet+inertia")},
    "capture24": {"A0": ("noenc", "hart"), "E": ("noenc", "eldernet"), "I": ("noenc", "hart+inertia"),
                  "E+I": ("noenc", "hart+eldernet+inertia")},
}
GAIT_ARMS = {"E", "A1v1+E", "A1v1+E+I", "E+I"}
PAIRS: Dict[str, List[Tuple[str, str]]] = {
    "wisdm": [("A1v0", "A1v1"), ("A0", "A1v1"), ("A0", "E"), ("A1v1", "A1v1+E"), ("A1v1", "A1v1+I"),
              ("A1v1+E", "A1v1+E+I"), ("A1v1+I", "A1v1+E+I")],
    "capture24": [("A0", "E"), ("A0", "I"), ("E", "E+I"), ("I", "E+I")],
}
WISDM_GAIT_ACTIVITIES = {"A": "walking", "B": "jogging", "C": "stairs"}


def eldernet_dir() -> str:
    d = os.environ.get("ELDERNET_REPLAY_DIR") or rd._paths.under(rd._paths.data_root(), "eldernet-replay")
    return rd._paths.require_dir(d, "ELDERNET_REPLAY_DIR / INERTIA_DATA_ROOT (saved ElderNet replay outputs)")


def out_root() -> str:
    return os.path.join(rd.replay_root(), "runs", "gait")


def gait_config(w: float, rho_h: float, rho_i: float) -> Dict[str, Any]:
    return {"gait": float(w), "brisk": 0.0, "brisk_rule": "cadence", "hart_redundancy": float(rho_h),
            "inertia_redundancy": float(rho_i), "accelerometer_budget": GAIT_BUDGET}


def floor_for(rho_hat: Optional[float]) -> float:
    """Redundancy floor: the candidate default, raised to ρ̂ (rounded up to 0.01) when ρ̂ is higher."""
    if rho_hat is None or not math.isfinite(rho_hat):
        return GAIT_DEFAULT_RHO
    return round(max(GAIT_DEFAULT_RHO, math.ceil(rho_hat * 100 - 1e-9) / 100), 2)


def rho_grid(floor: float) -> List[float]:
    return sorted({round(floor, 2)} | {x for x in RHO_STEPS if x > floor + 1e-9})


def _key(cfg: Mapping[str, Any]) -> str:
    return json.dumps(cfg, sort_keys=True)


# ---------------------------------------------------------------------------
# Inputs: recordings (mixed-rate blocks excluded), HART v1 windows, ElderNet windows, Inertia windows
# ---------------------------------------------------------------------------

def mixed_rate_blocks(recs: Sequence[rx.Recording]) -> Dict[str, Dict[str, float]]:
    """WISDM recordings whose length in R's replay (one nominal rate per block) differs from the true span of
    their raw timestamps by more than MIXED_RATE_TOL_S: blocks that switch between 20 and ~100 Hz mid-block."""
    wisdm_dir = rd._paths.require_dir(rd.WISDM_DIR, "WISDM_DIR (the unpacked wisdm-dataset directory)")
    out: Dict[str, Dict[str, float]] = {}
    by_sub: Dict[str, List[rx.Recording]] = {}
    for r in recs:
        by_sub.setdefault(str(r.subject), []).append(r)
    for sub, rr in by_sub.items():
        acts, ts_ns, _ = rd.parse_wisdm_raw(os.path.join(wisdm_dir, "raw", "watch", "accel", f"data_{sub}_accel_watch.txt"))
        spans = {bi: float(ts_ns[b - 1] - ts_ns[a]) / 1e9 for bi, (a, b) in enumerate(rd.split_recordings(acts, ts_ns))}
        for r in rr:
            span = spans.get(int(r.meta["block_index"]))
            if span is not None and abs(r.n - span) > MIXED_RATE_TOL_S:
                out[r.recording_id] = {"replay_seconds": float(r.n), "raw_span_s": round(span, 2)}
    return out


def load_recs(dataset: str, split: str) -> Tuple[List[rx.Recording], Dict[str, Any]]:
    recs = rx.load_recordings(os.path.join(rd.replay_root(), f"recordings_{dataset}_{split}.npz"))
    info: Dict[str, Any] = {"recordings_in": len(recs)}
    if dataset == "wisdm":
        bad = mixed_rate_blocks(recs)
        info["excluded_mixed_rate"] = bad
        info["excluded_hart_windows"] = int(sum(len(r.hart_s) for r in recs if r.recording_id in bad))
        recs = [r for r in recs if r.recording_id not in bad]
    info["recordings"] = len(recs)
    info["subjects"] = len({r.subject for r in recs})
    return recs, info


def hart_v1_recordings(recs: Sequence[rx.Recording], split: str) -> Tuple[List[rx.Recording], Dict[str, Any]]:
    """Copies of the WISDM recordings with HART v1's probabilities / labels in the SAME windows."""
    path = os.path.join(rd.replay_root(), f"hart_v1_wisdm_{split}.npz")
    z = np.load(path, allow_pickle=False)
    with open(path[:-4] + ".json", "r", encoding="utf-8") as f:
        meta = json.load(f)
    bid, s, e = z["block_id"].astype(str), z["s"], z["e"]
    order = list(z["probs_order"].astype(str))
    if order != list(rx.HART_ORDER):
        raise RuntimeError(f"HART v1 probs order {order} != {rx.HART_ORDER}")
    out = []
    for r in recs:
        m = np.flatnonzero(bid == r.recording_id)
        if len(m) != len(r.hart_s) or not (np.allclose(s[m], r.hart_s) and np.allclose(e[m], r.hart_e)):
            raise RuntimeError(f"{r.recording_id}: HART v1 windows differ from v0's ({len(m)} vs {len(r.hart_s)})")
        out.append(dataclasses.replace(r, hart_probs=z["probs"][m].astype(np.float64), hart_label=z["label"][m].astype(str),
                                       meta={**r.meta, "hart_model_version": meta.get("model_version"),
                                             "hart_checkpoint_sha256": meta.get("checkpoint_sha256")}))
    return out, {"model_version": meta.get("model_version"), "checkpoint_sha256": meta.get("checkpoint_sha256"),
                 "file_sha256": _sha256_file(path)}


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def manifest() -> Dict[str, Any]:
    with open(os.path.join(eldernet_dir(), "MANIFEST.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def gait_model_block(m: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """The header model (a gait-quality-1 infer response without windows) for the saved served outputs."""
    m = m or manifest()
    return {"model_id": "eldernet", "model_version": m["model_version"], "weights": dict(m["weights"]),
            "upstream_commit": m["upstream_commit"], "preprocessing_version": m["preprocessing_version"],
            "window_s": 10, "hop_s": int(m["hop_s"]), "calibration": m.get("calibration"),
            "gait_threshold": float(m["gait_threshold"])}


WIRE_KEYS = ("gait_prob", "is_gait", "prefiltered", "speed_mps", "cadence_spm", "stride_m", "regularity", "steps")


def _wire_row(r: Mapping[str, Any], s_abs: int) -> Dict[str, Any]:
    d: Dict[str, Any] = {"s": int(s_abs), "e": int(s_abs) + 10}
    for k in WIRE_KEYS:
        if k in r and r[k] is not None:
            d[k] = r[k]
    return d


def _rows(path: str) -> List[Dict[str, Any]]:
    with gzip.open(path, "rt", encoding="utf-8") as f:
        return [json.loads(ln) for ln in f if ln.strip()]


def eldernet_windows(dataset: str, split: str, recs: Sequence[rx.Recording]
                     ) -> Tuple[Dict[str, rx.GaitWindows], Dict[str, Any]]:
    """ElderNet windows per recording on the recording's absolute clock (= what serve would have attached)."""
    base = os.path.join(eldernet_dir(), "wisdm2019_watch" if dataset == "wisdm" else "capture24", split)
    stats = {"rows": 0, "mapped": 0, "rounded_offset": 0, "max_round_shift_s": 0.0, "dropped_outside_recording": 0,
             "dropped_duplicate_s": 0, "rows_of_excluded_or_absent_recordings": 0}

    def to_int(x: float) -> int:
        # The wire carries integral seconds and the decoder attaches on 1-s bins: a window whose start is off the
        # integer clock (a run that began at a fractional second, e.g. Capture-24 P140 at +0.46 s; windowing that
        # restarted after a gap) is placed on the nearest second (shift <= 0.5 s), never dropped.
        k = math.floor(x + 0.5)
        d = abs(x - k)
        if d > 1e-3:
            stats["rounded_offset"] += 1
            stats["max_round_shift_s"] = max(stats["max_round_shift_s"], round(d, 3))
        return int(k)
    per: Dict[str, List[Dict[str, Any]]] = {}
    if dataset == "wisdm":
        with open(os.path.join(rd.replay_root(), f"hart_wisdm_{split}.json"), "r", encoding="utf-8") as f:
            blocks = json.load(f)["blocks"]
        t0_of = {b["block_id"]: b["t0_ns"] / 1e9 for b in blocks}
        by_start: Dict[Tuple[str, float], List[rx.Recording]] = {}
        for r in recs:
            by_start.setdefault((str(r.subject), round(t0_of[r.recording_id], 3)), []).append(r)
        for sub in sorted({str(r.subject) for r in recs}):
            sess: Dict[str, List[Dict[str, Any]]] = {}
            for row in _rows(os.path.join(base, f"{sub}.jsonl.gz")):
                sess.setdefault(row["session"], []).append(row)
            for rows in sess.values():
                stats["rows"] += len(rows)
                targets = by_start.get((sub, round(rows[0]["s"], 3)), [])
                if not targets:
                    stats["rows_of_excluded_or_absent_recordings"] += len(rows)
                for r in targets:                      # duplicated blocks (same t0) get the same windows
                    t0 = t0_of[r.recording_id]
                    for row in rows:
                        k = to_int(row["s"] - t0)
                        if k < 0 or k + 10 > r.n:
                            stats["dropped_outside_recording"] += 1
                            continue
                        per.setdefault(r.recording_id, []).append(_wire_row(row, r.t0 + k))
    else:
        for r in recs:
            pid = r.recording_id.split("-", 1)[1] if "-" in r.recording_id else r.recording_id
            rows = _rows(os.path.join(base, f"{pid}.jsonl.gz"))
            stats["rows"] += len(rows)
            last = int(r.t0 + r.sec[-1] + 1) if r.n else r.t0
            for row in rows:
                s = r.t0 + to_int(row["s"] - r.t0)
                if s < r.t0 or s + 10 > last:
                    stats["dropped_outside_recording"] += 1
                    continue
                per.setdefault(r.recording_id, []).append(_wire_row(row, s))
    out: Dict[str, rx.GaitWindows] = {}
    for rid, rows in per.items():
        rows.sort(key=lambda d: d["s"])
        keep, last_s = [], None
        for d in rows:
            if d["s"] == last_s:
                stats["dropped_duplicate_s"] += 1
                continue
            keep.append(d)
            last_s = d["s"]
        stats["mapped"] += len(keep)
        out[rid] = rx.GaitWindows(keep)
    stats["recordings_with_windows"] = len(out)
    return out, stats


def inertia_heads(dataset: str, split: str, recs: Sequence[rx.Recording]):
    bundle = os.path.join(rd._paths.bundles_root(), INERTIA_BUNDLE)
    heads, hmeta = ev.get_heads(bundle, dataset, split, recs)
    return heads, hmeta


# ---------------------------------------------------------------------------
# ρ̂: residual log-LR correlation (mode-centred, pooled), as replay_eval.rho_hat
# ---------------------------------------------------------------------------

_GAIT_MODES = {"walk", "briskWalk", "stairs"}
_NONGAIT_MODES = {"bedRest", "seated", "upright", "vehicle", "cycling"}
_EPS = 0.02


def gait_loglr(q: float, prior: float = GAIT_PRIOR) -> np.ndarray:
    """log L per body mode of the ElderNet gait term (mirror of PreparedGaitQuality.likelihood)."""
    rg = max(q, 1e-9) / prior
    rn = max(1 - q, 1e-9) / (1 - prior)
    a = (1 + _EPS) / (1 + 2 * _EPS)
    lg = min(10.0, max(0.1, rn + a * (rg - rn)))
    ln = min(10.0, max(0.1, rg + a * (rn - rg)))
    out = np.zeros(len(ev.DECODER_MODES))
    for m, (name, _, _) in enumerate(ev.DECODER_MODES):
        out[m] = math.log(lg) if name in _GAIT_MODES else (math.log(ln) if name in _NONGAIT_MODES else 0.0)
    return out


def _fresh(ends: np.ndarray, t: int, hold: int) -> Optional[int]:
    """Index of the latest window with end <= t and t - end < hold (the window the decoder holds at t)."""
    j = int(np.searchsorted(ends, t, side="right")) - 1
    if j >= 0 and t - ends[j] < hold:
        return j
    return None


def _pooled(xs: List[np.ndarray], ys: List[np.ndarray], subj: List[str], definition: str) -> Dict[str, Any]:
    if not xs:
        return {"n_windows": 0, "rho_hat": None, "definition": definition}
    X, Y = np.concatenate(xs), np.concatenate(ys)
    rho = float(np.corrcoef(X, Y)[0, 1])
    S = np.repeat(np.asarray(subj), len(ev.DECODER_MODES))
    per = {}
    for s in np.unique(S):
        m = S == s
        if np.std(X[m]) > 0 and np.std(Y[m]) > 0:
            per[str(s)] = float(np.corrcoef(X[m], Y[m])[0, 1])
    return {"n_windows": len(xs), "rho_hat": rho, "per_subject": per, "definition": definition}


def rho_gait_vs_hart(recs_v1: Sequence[rx.Recording], gait: Mapping[str, rx.GaitWindows], hop_gait: int = 5) -> Dict[str, Any]:
    xs, ys, subj = [], [], []
    for r in recs_v1:
        g = gait.get(r.recording_id)
        if g is None or not len(g) or not len(r.hart_e):
            continue
        ends = g.e
        for i in range(len(r.hart_e)):
            j = _fresh(ends, int(r.t0 + r.hart_e[i]), hop_gait)
            if j is None:
                continue
            lh = ev.hart_loglr({c: float(r.hart_probs[i, q]) for q, c in enumerate(rx.HART_ORDER)})
            lg = gait_loglr(float(g.rows[j]["gait_prob"]))
            xs.append(lh - lh.mean())
            ys.append(lg - lg.mean())
            subj.append(r.subject)
    return _pooled(xs, ys, subj, "Pearson r of mode-centred log-LR vectors (14 non-unknown body modes), HART v1 encoder "
                                 "channel vs ElderNet gait term (q = gait_prob, π = 0.065), pooled over HART windows with "
                                 "a fresh ElderNet window (age < 5 s); decoder tables mirrored")


def rho_gait_vs_inertia(recs: Sequence[rx.Recording], heads: Mapping[str, rx.HeadsWindows], bundle_wire: Mapping[str, Any],
                        gait: Mapping[str, rx.GaitWindows], hop_gait: int = 5) -> Dict[str, Any]:
    prep = ev.prepare_inertia_locomotion(bundle_wire["heads"]["locomotion"])
    xs, ys, subj = [], [], []
    for r in recs:
        h, g = heads.get(r.recording_id), gait.get(r.recording_id)
        if h is None or g is None or "locomotion" not in h.probs or not len(g):
            continue
        order = h.class_order["locomotion"]
        for k in range(len(h)):
            if h.is_ood is not None and bool(h.is_ood[k]):
                continue
            j = _fresh(g.e, int(r.t0 + h.e[k]), hop_gait)
            if j is None:
                continue
            q = {c: float(v) for c, v in zip(order, h.probs["locomotion"][k]) if np.isfinite(v)}
            li = ev.inertia_loglr(q, prep)
            if li is None:
                continue
            lg = gait_loglr(float(g.rows[j]["gait_prob"]))
            xs.append(li - li.mean())
            ys.append(lg - lg.mean())
            subj.append(r.subject)
    return _pooled(xs, ys, subj, "Pearson r of mode-centred log-LR vectors (14 non-unknown body modes), Inertia locomotion "
                                 "channel (shadow-primary-hc, non-OOD) vs ElderNet gait term, pooled over Inertia windows "
                                 "with a fresh ElderNet window (age < 5 s); decoder tables mirrored")


def run_rho(jobs: int = 4) -> Dict[str, Any]:
    t = time.time()
    res: Dict[str, Any] = {"banner": rd.STANDIN_BANNER, "split": "val", "gait_prior": GAIT_PRIOR}
    wv, winfo = load_recs("wisdm", "val")
    wv1, v1info = hart_v1_recordings(wv, "val")
    wg, wgs = eldernet_windows("wisdm", "val", wv)
    res["wisdm_val_inputs"] = {**winfo, "eldernet": wgs, "hart_v1": v1info}
    res["eldernet_vs_hart_v1_wisdm_val"] = rho_gait_vs_hart(wv1, wg)
    wh, whm = inertia_heads("wisdm", "val", wv)
    res["inertia_vs_hart_v1_wisdm_val"] = {**ev.rho_hat(wv1, wh, whm["bundle"]["bundle"], 5),
                                           "note": "side value: Inertia's own hart_redundancy stays at its default"}
    res["eldernet_vs_inertia_wisdm_val"] = rho_gait_vs_inertia(wv, wh, whm["bundle"]["bundle"], wg)
    cv, cinfo = load_recs("capture24", "val")
    cg, cgs = eldernet_windows("capture24", "val", cv)
    ch, chm = inertia_heads("capture24", "val", cv)
    res["capture24_val_inputs"] = {**cinfo, "eldernet": cgs}
    res["eldernet_vs_inertia_capture24_val"] = rho_gait_vs_inertia(cv, ch, chm["bundle"]["bundle"], cg)
    res["floors"] = {"hart_redundancy": floor_for(res["eldernet_vs_hart_v1_wisdm_val"]["rho_hat"]),
                     "inertia_redundancy": floor_for(res["eldernet_vs_inertia_capture24_val"]["rho_hat"])}
    res["seconds"] = round(time.time() - t, 1)
    os.makedirs(out_root(), exist_ok=True)
    with open(os.path.join(out_root(), "rho_hat.json"), "w", encoding="utf-8") as f:
        json.dump(ev._json_safe(res), f, indent=1)
    return res


# ---------------------------------------------------------------------------
# Decode
# ---------------------------------------------------------------------------

def _gait_arrays(states: Sequence[Mapping[str, Any]]) -> Dict[str, np.ndarray]:
    n = len(states)
    out = {k: np.full(n, np.nan) for k in ("speed_mps", "cadence_spm", "stride_m", "steps", "gait_probability", "windows")}
    has = np.zeros(n, bool)
    for i, s in enumerate(states):
        g = s.get("gait")
        if not g:
            continue
        has[i] = True
        for k in out:
            v = g.get(k)
            if v is not None:
                out[k][i] = float(v)
    out["has"] = has
    return out


def _task(args):
    variant, arms, part, enc, heads, bundle_info, gait, gait_header, ip, keep = args
    op = ip[:-6] + ".out.json"
    m = rx.write_harness_file(ip, part, list(arms), heads=heads, bundle_info=bundle_info,
                              weights=INERTIA_WEIGHTS if bundle_info is not None else None,
                              allow_standin=bundle_info is not None, include_encoder=(enc != "none"),
                              encoder_version="hart-wisdm-v1" if enc == "v1" else "hart-wisdm-v0",
                              gait=gait, gait_quality=gait_header)
    m["variant"] = variant
    dt = ev.retrying(lambda: ev.run_xctest(ip, op), f"xctest {os.path.basename(ip)}")
    with open(op, "r", encoding="utf-8") as f:
        doc = json.load(f)
    if doc.get("format") != rx.HARNESS_OUT_FORMAT:
        raise RuntimeError(f"unexpected replay output format {doc.get('format')!r}")
    states, garr, reports = {}, {}, {}
    for arm, per in doc["arms"].items():
        states[(variant, arm)] = {seq: ev.parse_seq(e) for seq, e in per.items()}
        garr[(variant, arm)] = {seq: _gait_arrays(e.get("states") or []) for seq, e in per.items()}
        reports[(variant, arm)] = {seq: e.get("gait_quality") for seq, e in per.items() if e.get("gait_quality")}
    if not keep:
        os.remove(ip)
        os.remove(op)
    return states, garr, reports, m, dt


@dataclasses.dataclass
class Inputs:
    dataset: str
    split: str
    recs: List[rx.Recording]
    recs_v1: Optional[List[rx.Recording]]
    heads: Dict[str, rx.HeadsWindows]
    bundle_info: Dict[str, Any]
    gait: Dict[str, rx.GaitWindows]
    info: Dict[str, Any]


def load_inputs(dataset: str, split: str) -> Inputs:
    recs, info = load_recs(dataset, split)
    v1, v1info = (hart_v1_recordings(recs, split) if dataset == "wisdm" else (None, None))
    heads, hmeta = inertia_heads(dataset, split, recs)
    gait, gstats = eldernet_windows(dataset, split, recs)
    info = {**info, "eldernet": gstats, "hart_v1": v1info, "inertia_bundle_sha256": hmeta["bundle"]["bundle_sha256"],
            "inertia_windows": int(sum(len(h) for h in heads.values()))}
    return Inputs(dataset, split, recs, v1, heads, hmeta["bundle"], gait, info)


def _variants(dataset: str, kind: str) -> Dict[str, List[str]]:
    want = [a for a in ARMS[dataset] if (a in GAIT_ARMS) == (kind == "gait")]
    v: Dict[str, List[str]] = {}
    for a in want:
        var, harm = ARMS[dataset][a]
        v.setdefault(var, []).append(harm)
    return v


def decode(inp: Inputs, kind: str, gait_cfg: Mapping[str, Any], jobs: int, workdir: str
           ) -> Tuple[Dict[str, ev.ArmTable], Dict[str, Dict[str, np.ndarray]], Dict[str, Dict[str, Any]], Dict[str, Any]]:
    """Decode the fixed arms (kind="fixed") or the ElderNet arms at ``gait_cfg`` (kind="gait")."""
    from concurrent.futures import ProcessPoolExecutor
    workdir = os.path.join(ev.WORK_DIR, "gait", f"{inp.dataset}-{inp.split}-{os.getpid()}")
    os.makedirs(workdir, exist_ok=True)
    chunk = 40 if inp.dataset == "wisdm" else 4
    header = {"model": gait_model_block(), "gait_prior": GAIT_PRIOR, "config": dict(gait_cfg)}
    tasks = []
    for variant, arms in _variants(inp.dataset, kind).items():
        enc = {"noenc": "none", "v0": "v0", "v1": "v1"}[variant]
        recs = inp.recs_v1 if variant == "v1" else inp.recs
        with_heads = any(a.endswith("inertia") for a in arms)
        for ci in range(0, len(recs), chunk):
            part = list(recs[ci:ci + chunk])
            ph = {r.recording_id: inp.heads[r.recording_id] for r in part if r.recording_id in inp.heads} if with_heads else None
            pg = {r.recording_id: inp.gait[r.recording_id] for r in part if r.recording_id in inp.gait}
            ip = os.path.join(workdir, f"{kind}_{variant}_{ci // chunk:03d}.jsonl")
            tasks.append((variant, arms, part, enc, ph or None, inp.bundle_info if with_heads else None, pg, header, ip, False))
    states: Dict[Tuple[str, str], Dict[str, ev.SeqStates]] = {}
    garr: Dict[Tuple[str, str], Dict[str, Dict[str, np.ndarray]]] = {}
    reps: Dict[Tuple[str, str], Dict[str, Any]] = {}
    manifests, times = [], []
    with ProcessPoolExecutor(max_workers=max(1, min(jobs, len(tasks)))) as ex:
        for s_, g_, r_, m, dt in ex.map(_task, tasks):
            manifests.append(m)
            times.append(dt)
            for k, v in s_.items():
                states.setdefault(k, {}).update(v)
            for k, v in g_.items():
                garr.setdefault(k, {}).update(v)
            for k, v in r_.items():
                reps.setdefault(k, {}).update(v)
    tables, gaits, reports = {}, {}, {}
    for a, src in ARMS[inp.dataset].items():
        if src not in states:
            continue
        recs = inp.recs_v1 if src[0] == "v1" else inp.recs
        tables[a] = ev.build_table(a, recs, states[src])
        if a in GAIT_ARMS:
            gaits[a] = {k: np.concatenate([garr[src][r.recording_id][k] for r in recs]) for k in
                        ("has", "speed_mps", "cadence_spm", "stride_m", "steps", "gait_probability", "windows")}
            tot: Dict[str, float] = {}
            for rep in reps.get(src, {}).values():
                for k, v in rep.items():
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        tot[k] = tot.get(k, 0) + v
            reports[a] = tot
    shared: Dict[str, set] = {}
    for m in manifests:
        for rid, d in m["shared_input_sha256"].items():
            shared.setdefault(rid, set()).add(d)
    info = {"files": len(tasks), "decode_seconds": round(float(sum(times)), 1),
            "gait_attach": _sum_attach([m.get("gait_attach") for m in manifests]),
            "shared_inputs_identical_across_variants": all(len(v) == 1 for v in shared.values())}
    return tables, gaits, reports, info


def _sum_attach(xs) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for x in xs:
        for k, v in (x or {}).items():
            out[k] = out.get(k, 0) + int(v)
    return out


# ---------------------------------------------------------------------------
# Scoring extras: the reported gait block, ElderNet windows by label
# ---------------------------------------------------------------------------

def _label_groups(tb: ev.ArmTable, recs: Sequence[rx.Recording], dataset: str) -> Dict[str, np.ndarray]:
    if dataset == "wisdm":
        act = {r.recording_id: str(r.meta.get("activity")) for r in recs}
        a = np.asarray([act[s] for s in tb.seq])
        groups = {f"{k} {v}": a == k for k, v in WISDM_GAIT_ACTIVITIES.items()}
        groups["other activities (D-S)"] = ~np.isin(a, list(WISDM_GAIT_ACTIVITIES))
        return groups
    T = tb.truth["locomotion"]
    order = ev.SCORE_ORDERS["locomotion"]
    has = T.any(1)
    groups = {f"truth {c}": has & T[:, i] & (T.sum(1) == 1) for i, c in enumerate(order) if c != "unknown"}
    groups["no locomotion truth"] = ~has
    return {k: v for k, v in groups.items() if v.any()}


def _med(x: np.ndarray) -> Dict[str, Optional[float]]:
    x = x[np.isfinite(x)]
    if not len(x):
        return {"n": 0, "median": None, "p25": None, "p75": None}
    return {"n": int(len(x)), "median": float(np.median(x)), "p25": float(np.percentile(x, 25)),
            "p75": float(np.percentile(x, 75))}


def gait_block_summary(tb: ev.ArmTable, g: Mapping[str, np.ndarray], recs: Sequence[rx.Recording], dataset: str) -> Dict[str, Any]:
    out = {}
    for name, m in _label_groups(tb, recs, dataset).items():
        n = int(m.sum())
        hb = g["has"] & m
        out[name] = {"states": n, "share_with_gait_block": float(hb.sum() / n) if n else None,
                     "share_with_speed": float((hb & np.isfinite(g["speed_mps"])).sum() / n) if n else None,
                     "share_with_cadence": float((hb & np.isfinite(g["cadence_spm"])).sum() / n) if n else None,
                     "speed_mps": _med(g["speed_mps"][hb]), "cadence_spm": _med(g["cadence_spm"][hb]),
                     "gait_probability": _med(g["gait_probability"][hb])}
    return out


def eldernet_window_summary(recs: Sequence[rx.Recording], gait: Mapping[str, rx.GaitWindows], dataset: str) -> Dict[str, Any]:
    """The served windows themselves (decoder-independent), by the truth of their centre second."""
    acc: Dict[str, Dict[str, list]] = {}
    for r in recs:
        g = gait.get(r.recording_id)
        if g is None:
            continue
        if dataset == "wisdm":
            a = str(r.meta.get("activity"))
            lab = f"{a} {WISDM_GAIT_ACTIVITIES[a]}" if a in WISDM_GAIT_ACTIVITIES else "other activities (D-S)"
            labs = [lab] * len(g)
        else:
            sec_index = {int(s): i for i, s in enumerate(r.sec)}
            m = r.truth_strict.get("locomotion")
            order = rd.HEAD_ORDERS["locomotion"]
            labs = []
            for row in g.rows:
                i = sec_index.get(int(row["s"] + 5 - r.t0))
                mask = int(m[i]) if (m is not None and i is not None) else 0
                bits = [order[b] for b in range(len(order)) if (mask >> b) & 1]
                lab = "walking" if bits in (["walking"], ["brisk_walking"], ["walking", "brisk_walking"]) else (
                    bits[0] if len(bits) == 1 else ("no locomotion truth" if not bits else "multi"))
                labs.append("truth " + lab if lab not in ("no locomotion truth", "multi") else lab)
        for lab, row in zip(labs, g.rows):
            d = acc.setdefault(lab, {"is_gait": [], "speed": [], "cadence": [], "prefiltered": []})
            d["is_gait"].append(bool(row.get("is_gait")))
            d["prefiltered"].append(bool(row.get("prefiltered", False)))
            if row.get("is_gait"):
                d["speed"].append(row.get("speed_mps", np.nan) if row.get("speed_mps") is not None else np.nan)
                d["cadence"].append(row.get("cadence_spm", np.nan) if row.get("cadence_spm") is not None else np.nan)
    return {lab: {"windows": len(d["is_gait"]), "share_is_gait": float(np.mean(d["is_gait"])),
                  "share_prefiltered": float(np.mean(d["prefiltered"])),
                  "speed_mps_on_gait": _med(np.asarray(d["speed"], float)),
                  "cadence_spm_on_gait": _med(np.asarray(d["cadence"], float))} for lab, d in sorted(acc.items())}


# ---------------------------------------------------------------------------
# VALIDATION sweep (selection only)
# ---------------------------------------------------------------------------

def _select(rows: Sequence[Mapping[str, Any]], arm: str) -> Mapping[str, Any]:
    return max(rows, key=lambda r: (r["objective"][arm][0], -r["objective"][arm][1]))


def run_sweep(dataset: str, jobs: int = 4) -> Dict[str, Any]:
    t = time.time()
    with open(os.path.join(out_root(), "rho_hat.json"), "r", encoding="utf-8") as f:
        rho = json.load(f)
    fh, fi = rho["floors"]["hart_redundancy"], rho["floors"]["inertia_redundancy"]
    inp = load_inputs(dataset, "val")
    work = os.path.join(out_root(), "work")
    fixed, _, _, finfo = decode(inp, "fixed", gait_config(GAIT_DEFAULT_WEIGHT, fh, fi), jobs, work)
    ev.check_alignment(fixed)
    res: Dict[str, Any] = {"banner": rd.STANDIN_BANNER, "split": "val", "dataset": dataset, "inputs": inp.info,
                           "floors": {"hart_redundancy": fh, "inertia_redundancy": fi}, "gait_prior": GAIT_PRIOR,
                           "objective": "max mean descriptive coverage@95 (CP one-sided 95% >= .95, n_acc >= 60) over "
                                        "posture+locomotion classes; tie-break min mean known-class NLL",
                           "baseline": {}, "configs": [], "val_operating_points": {}}
    vops: Dict[str, Any] = {}
    for a, tb in fixed.items():
        sc = ev.score_arm(tb, inp.recs)
        res["baseline"][a] = {"objective": ev.objective(sc), "summary": ev._json_safe(sc)}
        vops[a] = {h: ev.val_operating_points(tb, h) for h in ev.SCORED_HEADS}
    done: Dict[str, Dict[str, Any]] = {}

    def run(cfg):
        k = _key(cfg)
        if k in done:
            return done[k]
        tabs, gaits, reps, dinfo = decode(inp, "gait", cfg, jobs, work)
        ev.check_alignment({**fixed, **tabs})
        row = {"config": cfg, "objective": {}, "val_ops": {}, "gait_quality_report": reps, "decode": dinfo}
        for a, tb in tabs.items():
            row["objective"][a] = ev.objective(ev.score_arm(tb, inp.recs))
            row["val_ops"][a] = {h: ev.val_operating_points(tb, h) for h in ev.SCORED_HEADS}
        done[k] = row
        print(json.dumps({"cfg": cfg, **{a: [round(x, 4) for x in v] for a, v in row["objective"].items()}}), flush=True)
        return row

    stage1 = [run(gait_config(w, fh, fi)) for w in GAIT_W_GRID]
    sel: Dict[str, Mapping[str, Any]] = {}
    for a in ARMS[dataset]:
        if a not in GAIT_ARMS:
            continue
        best = _select(stage1, a)
        w = best["config"]["gait"]
        if a in ("A1v1+E", "A1v1+E+I"):            # stage 2: the HART discount floor
            best = _select([best] + [run(gait_config(w, r, fi)) for r in rho_grid(fh) if r != fh], a)
        if a in ("A1v1+E+I", "E+I"):               # stage 3: the Inertia discount floor
            rh = best["config"]["hart_redundancy"]
            best = _select([best] + [run(gait_config(w, rh, r)) for r in rho_grid(fi) if r != fi], a)
        sel[a] = best
    dflt = done[_key(gait_config(GAIT_DEFAULT_WEIGHT, fh, fi))]
    res["selected"] = {a: {"config": r["config"], "objective": r["objective"][a]} for a, r in sel.items()}
    res["defaults"] = {"config": dflt["config"], "objective": {a: dflt["objective"][a] for a in sel}}
    res["configs"] = [{"config": r["config"], "objective": r["objective"], "gait_quality_report": r["gait_quality_report"],
                       "decode": r["decode"]} for r in done.values()]
    for a in sel:
        vops[f"{a}@defaults"] = dflt["val_ops"][a]
        vops[f"{a}@selected"] = sel[a]["val_ops"][a]
    res["val_operating_points"] = ev._json_safe({a: {h: {ev.SCORE_ORDERS[h][c]: v for c, v in d.items()} for h, d in ops.items()}
                                                 for a, ops in vops.items()})
    res["seconds"] = round(time.time() - t, 1)
    with open(os.path.join(out_root(), f"sweep_{dataset}.json"), "w", encoding="utf-8") as f:
        json.dump(ev._json_safe(res), f, indent=1)
    return res


# ---------------------------------------------------------------------------
# TEST (one ledgered opening per dataset)
# ---------------------------------------------------------------------------

def _fingerprint(dataset: str, sweep: Mapping[str, Any], inp_info: Mapping[str, Any]) -> str:
    doc = {"xctest_sha256": ev.xctest_fingerprint(), "eldernet_manifest_sha256": _sha256_file(os.path.join(eldernet_dir(), "MANIFEST.json")),
           "inertia_bundle_sha256": inp_info.get("inertia_bundle_sha256"), "hart_v1": inp_info.get("hart_v1"),
           "selected": sweep["selected"], "defaults": sweep["defaults"]["config"], "gait_prior": GAIT_PRIOR,
           "excluded": (sorted(inp_info["excluded_mixed_rate"]) if isinstance(inp_info.get("excluded_mixed_rate"), dict)
                        else inp_info.get("excluded_mixed_rate")), "dataset": dataset}
    return hashlib.sha256(json.dumps(doc, sort_keys=True, default=str).encode()).hexdigest()


def _evaluate(inp: Inputs, sweep: Mapping[str, Any], jobs: int, n_boot: int) -> Dict[str, Any]:
    ds = inp.dataset
    vops = {a: ev._ops_from_json(v) for a, v in sweep["val_operating_points"].items()}
    work = os.path.join(out_root(), "work")
    dcfg = sweep["defaults"]["config"]
    fixed, _, _, finfo = decode(inp, "fixed", dcfg, jobs, work)
    by_cfg: Dict[str, Tuple] = {}

    def get(cfg):
        k = _key(cfg)
        if k not in by_cfg:
            by_cfg[k] = decode(inp, "gait", cfg, jobs, work)
        return by_cfg[k]

    res: Dict[str, Any] = {"banner": rd.STANDIN_BANNER, "split": "test", "dataset": ds, "inputs": inp.info,
                           "gait_prior": GAIT_PRIOR, "inertia_weights": INERTIA_WEIGHTS, "configs": {},
                           "eldernet_windows_by_label": eldernet_window_summary(inp.recs, inp.gait, ds)}
    for label in ("defaults", "selected"):
        tables = dict(fixed)
        gaits, reps, cfgs = {}, {}, {}
        for a in [x for x in ARMS[ds] if x in GAIT_ARMS]:
            cfg = dcfg if label == "defaults" else sweep["selected"][a]["config"]
            tabs, gs, rp, _ = get(cfg)
            tables[a], gaits[a], reps[a], cfgs[a] = tabs[a], gs[a], rp.get(a, {}), cfg
        ev.check_alignment(tables)
        ops_for = {a: (vops.get(f"{a}@{label}") if a in GAIT_ARMS else vops.get(a)) for a in tables}
        sc: Dict[str, Any] = {"gait_configs": cfgs, "arms": {}, "gait_quality_report": reps, "gait_block": {},
                              "paired_bootstrap": {}}
        for a, tb in tables.items():
            sc["arms"][a] = ev._json_safe(ev.score_arm(tb, inp.recs, ops_for.get(a), with_events=(ds == "capture24")))
            if a in GAIT_ARMS:
                sc["gait_block"][a] = gait_block_summary(tb, gaits[a], inp.recs, ds)
        for x, y in PAIRS[ds]:
            sc["paired_bootstrap"][f"{y}-{x}"] = ev._json_safe(ev.paired_bootstrap(tables[x], tables[y], ops_for, n_boot=n_boot))
        if ds == "capture24":
            for a in ("E", "E+I", "I"):
                sc.setdefault("posture_decomposition", {})[f"{a}-A0"] = ev._json_safe(
                    ev.posture_decomposition(tables["A0"], tables[a], inp.recs, n_boot))
        res["configs"][label] = sc
        print(json.dumps({"label": label}), flush=True)
    res["decoded_gait_configs"] = [json.loads(k) for k in by_cfg]
    return res


def run_final(dataset: str, jobs: int = 4, n_boot: int = 1000, rerun_reason: Optional[str] = None,
              rerun_detail: Optional[str] = None, ledger_dir: Optional[str] = None) -> Dict[str, Any]:
    from .experiments import REPLAY_DECLARED
    t = time.time()
    with open(os.path.join(out_root(), f"sweep_{dataset}.json"), "r", encoding="utf-8") as f:
        sweep = json.load(f)
    holder: Dict[str, Any] = {}

    def load_test():
        inp = load_inputs(dataset, "test")
        holder["inp"] = inp
        return {"recs": inp.recs, "inp": inp}

    def evaluator(payload):
        return _evaluate(payload["inp"], sweep, jobs, n_boot)

    # the fingerprint needs the TEST input provenance (bundle / HART v1 / exclusions), not TEST data
    fp_info = {"inertia_bundle_sha256": sweep["inputs"].get("inertia_bundle_sha256"), "hart_v1": sweep["inputs"].get("hart_v1"),
               "excluded_mixed_rate": "test split (detected from the raw clock inside the vault)"}
    fp = _fingerprint(dataset, sweep, fp_info)
    res = ev.replay_vault(load_test, ledger_dir).evaluate_once(f"replay-gait/{dataset}", fp, evaluator,
                                                               tuple(REPLAY_DECLARED) + DECLARED, rerun_reason, rerun_detail)
    res["fingerprint"] = fp
    res["seconds"] = round(time.time() - t, 1)
    with open(os.path.join(out_root(), f"final_{dataset}.json"), "w", encoding="utf-8") as f:
        json.dump(ev._json_safe(res), f, indent=1)
    return res


def main(argv: Optional[Sequence[str]] = None) -> int:
    from .integrity import RERUN_REASONS
    ap = argparse.ArgumentParser(prog="python -m activity_context.inertia.replay_eldernet", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("rho")
    r.add_argument("--jobs", type=int, default=4)
    s = sub.add_parser("sweep")
    s.add_argument("--dataset", choices=("wisdm", "capture24"), required=True)
    s.add_argument("--jobs", type=int, default=4)
    f = sub.add_parser("final")
    f.add_argument("--dataset", choices=("wisdm", "capture24"), required=True)
    f.add_argument("--jobs", type=int, default=4)
    f.add_argument("--n-boot", type=int, default=1000)
    f.add_argument("--rerun-reason", choices=sorted(RERUN_REASONS))
    f.add_argument("--rerun-detail")
    a = ap.parse_args(argv)
    if a.cmd == "rho":
        out = run_rho(a.jobs)
        print(json.dumps({k: (v.get("rho_hat") if isinstance(v, dict) and "rho_hat" in v else None)
                          for k, v in out.items() if isinstance(v, dict) and "rho_hat" in v} | {"floors": out["floors"]}))
    elif a.cmd == "sweep":
        out = run_sweep(a.dataset, a.jobs)
        print(json.dumps(ev._json_safe(out["selected"])))
    else:
        out = run_final(a.dataset, a.jobs, a.n_boot, a.rerun_reason, a.rerun_detail)
        print(json.dumps({"seconds": out["seconds"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
