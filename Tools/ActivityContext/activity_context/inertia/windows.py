"""Recordings -> 20 Hz g runs -> labelled windows (INERTIA1.md §3 applied to public datasets).

Per recording: runs are split at any step > ``Recording.split_step_s`` (uniform-rate sources: any missing
sample; irregular watches: > 0.25 s; never bridged), irregular runs are regridded onto the nominal rate,
every run goes through ``preprocess.resample_to_20hz`` (Butterworth 10 Hz filtfilt + resample_poly), and
windows are cut on a per-run grid starting 1 s after the run start, ending >= 1 s before the run end.

Window sets (one pass per recording, see :data:`SPECS`):

``w30``  30 s windows, hop 15 s (Capture-24: hop 30 s = window); class-head windows; kept iff one
         non-null source label covers >= 90% of the window.
``w30t`` 30 s windows, hop 2 s, transition-only: every window of Opportunity / PAMAP2 / HHAR (dense series
         for event timing), and Capture-24 windows that contain an eligible <= 28-s gap event. Class
         targets are MASK for these (they duplicate ``w30`` content).
``w10``  10 s windows, hop 5 s (Capture-24: 10 s): the window-length benchmark (class heads only).

Capture-24 TRAIN ``w30``/``w10`` windows are capped at 1000 per (subject, fine label), keeping the windows
with the smallest sha256(uid) (deterministic); val/test are uncapped. Eval hop = train hop (documented).
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence

import numpy as np

from . import preprocess as ipre
from .datasets import Recording
from .mappings import Crosswalk
from .transition_targets import (N_EVENTS, derive_boundaries, label_segments, masked_intervals,
                                 timing_events, window_targets)

RATE = ipre.TARGET_HZ
EDGE_S = float(ipre.EDGE_MARGIN_S)
PURITY = 0.9
C24_TRAIN_CAP = 1000
WINDOWS_VERSION = "inertia-windows-1"


@dataclass(frozen=True)
class Spec:
    name: str
    window_s: int
    kind: str          # "cls" | "trn"

    def hop_s(self, dataset: str) -> float:
        if self.kind == "trn":
            return 2.0
        if dataset == "capture24":
            return float(self.window_s)
        return self.window_s / 2.0


SPECS = {"w30": Spec("w30", 30, "cls"), "w30t": Spec("w30t", 30, "trn"), "w10": Spec("w10", 10, "cls")}
DENSE_TRN = ("opportunity", "pamap2", "hhar_watch")


def window_uid(dataset: str, session: str, t0: float, window_s: int) -> str:
    return f"{dataset}|{session}|{int(round(t0 * 1000))}|w{window_s}"


def uid_rank(uid: str) -> int:
    return int(hashlib.sha256(uid.encode("utf-8")).hexdigest()[:16], 16)


def _regrid(t: np.ndarray, x: np.ndarray, fs: float):
    n = int(np.floor((t[-1] - t[0]) * fs + 1e-9)) + 1
    tg = t[0] + np.arange(n) / fs
    xg = np.stack([np.interp(tg, t, x[:, k]) for k in range(3)], axis=1)
    return tg, xg


def _nearest(t_src: np.ndarray, t_query: np.ndarray) -> np.ndarray:
    i = np.clip(np.searchsorted(t_src, t_query), 1, len(t_src) - 1)
    return np.where(np.abs(t_src[i - 1] - t_query) <= np.abs(t_src[i] - t_query), i - 1, i)


def window_recording(rec: Recording, cw: Crosswalk, specs: Sequence[Spec], split: str) -> Dict[str, Dict]:
    """All windows of one recording for each spec: ``{spec.name: {"X", "meta", "trans", "events"}}``."""
    states = [cw.transition_state(rec.dataset, n) for n in rec.label_names]
    none_ok = np.array([cw.has_label(rec.dataset, n) and cw.transition_none_ok(rec.dataset, n)
                        for n in rec.label_names], bool)
    null_codes = {i for i, s in enumerate(states) if s is None}
    rule = cw.transition_rule(rec.dataset)
    pairs = cw.event_pairs()
    pol = cw.doc["transition_policy"]
    acc = {s.name: {"X": [], "meta": [], "trans": []} for s in specs}
    events: List[Dict] = []
    masked: List = []
    for sl in ipre.segment_on_gaps(rec.t, max_gap_s=rec.split_step_s):
        t, x, codes = rec.t[sl], rec.xyz_g[sl], rec.labels[sl]
        filled = rec.filled[sl] if rec.filled is not None else np.zeros(len(t), bool)
        if len(t) < 2 or (t[-1] - t[0]) < min(s.window_s for s in specs) + 2 * EDGE_S:
            continue
        if not rec.uniform:                       # irregular watch clock: linear regrid onto the nominal rate
            tg, x = _regrid(t, x, rec.source_hz)
            near = _nearest(t, tg)
            codes, filled, t = codes[near], filled[near], tg
        try:
            x20 = ipre.resample_to_20hz(x, rec.source_hz)
        except ipre.PreprocessError:
            continue
        t20 = t[0] + np.arange(len(x20)) / RATE
        src_idx = np.clip(np.round(np.arange(len(x20)) * rec.source_hz / RATE).astype(np.int64), 0, len(t) - 1)
        lab20, fill20 = codes[src_idx], filled[src_idx]
        segs = label_segments(t, codes, rec.source_hz, states)
        run_end = t[-1] + 1.0 / rec.source_hz
        for spec in specs:
            hop = spec.hop_s(rec.dataset)
            if spec.kind == "trn" and rec.dataset not in DENSE_TRN and rec.dataset != "capture24":
                continue
            starts = np.arange(t[0] + EDGE_S, run_end - EDGE_S - spec.window_s + 1e-9, hop)
            if not len(starts):
                continue
            T = spec.window_s * RATE
            i0 = np.round((starts - t[0]) * RATE).astype(np.int64)
            ok = i0 + T <= len(x20)
            starts, i0 = starts[ok], i0[ok]
            w1 = starts + spec.window_s
            bnds = derive_boundaries(segs, rule, pairs, spec.window_s)
            trans = window_targets(starts, w1, bnds, segs, none_ok, pol["guard_s"], pol["interior_margin_s"])
            if spec.kind == "trn" and spec.name == "w30t":
                events += [dict(e, session=rec.session) for e in timing_events(bnds)]
                masked += [(rec.session, a, b) for a, b in masked_intervals(bnds, pol["guard_s"])]
            for k, (s, i) in enumerate(zip(starts, i0)):
                lw = lab20[i:i + T]
                cnt = np.bincount(lw, minlength=len(rec.label_names))
                mode = int(np.argmax(cnt))
                purity = float(cnt[mode]) / T
                pure = purity >= PURITY and mode not in null_codes
                if spec.kind == "cls" and not pure:
                    continue
                if spec.kind == "trn" and rec.dataset == "capture24" and not (trans[k] == 1).any():
                    continue
                acc[spec.name]["X"].append(np.ascontiguousarray(x20[i:i + T].T))
                acc[spec.name]["trans"].append(trans[k])
                acc[spec.name]["meta"].append({
                    "uid": window_uid(rec.dataset, rec.session, s, spec.window_s), "dataset": rec.dataset,
                    "subject": rec.subject, "session": rec.session, "split": split, "t0": float(s),
                    "t1": float(s + spec.window_s), "label": rec.label_names[mode], "purity": purity,
                    "pure": bool(pure), "filled_fraction": float(fill20[i:i + T].mean()),
                    "placement": rec.placement, "device": rec.device, "wrist_side": rec.wrist_side,
                    "source_hz": float(rec.source_hz), "kind": spec.kind})
    out = {}
    for spec in specs:
        a = acc[spec.name]
        meta = a["meta"]
        X = np.stack(a["X"]).astype(np.float32) if a["X"] else np.zeros((0, 3, spec.window_s * RATE), np.float32)
        tr = np.stack(a["trans"]).astype(np.int8) if a["trans"] else np.zeros((0, N_EVENTS), np.int8)
        if spec.kind == "cls" and rec.dataset == "capture24" and split == "train" and meta:
            keep = _cap(meta, C24_TRAIN_CAP)
            X, tr, meta = X[keep], tr[keep], [meta[i] for i in keep]
        out[spec.name] = {"X": X, "meta": meta, "trans": tr,
                          "events": events if spec.name == "w30t" else [],
                          "masked": masked if spec.name == "w30t" else []}
    return out


def _cap(meta: List[Dict], cap: int) -> np.ndarray:
    """Indices kept after capping windows per fine label (smallest sha256(uid) first), in time order."""
    by: Dict[str, List[int]] = {}
    for i, m in enumerate(meta):
        by.setdefault(m["label"], []).append(i)
    keep: List[int] = []
    for lab, idx in by.items():
        if len(idx) > cap:
            idx = sorted(idx, key=lambda i: uid_rank(meta[i]["uid"]))[:cap]
        keep += idx
    return np.array(sorted(keep), np.int64)


__all__ = ["Spec", "SPECS", "window_recording", "window_uid", "uid_rank", "PURITY", "C24_TRAIN_CAP",
           "WINDOWS_VERSION", "DENSE_TRN"]
