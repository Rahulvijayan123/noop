"""Offline replay inputs for the system-level decoder comparison (agent R; INERTIA1.md §7, spec §17/§23).

Everything here is OFFLINE research plumbing: it turns public wrist datasets into the per-second streams and
per-window encoder outputs that the Swift ActivityContext decoder replay consumes, plus per-second ground
truth to score the decoder's published states against. Nothing here is imported by a serve path.

What it produces, per recording (a WISDM (subject, activity block) or a Capture-24 contiguous run):

* **30 Hz HART-path stream** — WISDM: each sensor resampled from its *own detected native rate*
  (20 / 25 / 50 Hz; ~8 % of WISDM watch blocks are ~50 Hz, not the documented 20 Hz) to 30 Hz with the
  repo's polyphase resampler (``preprocess.resample_poly_nd``); samples are taken as uniform at the detected
  nominal rate (see REGRID_TIMESTAMPS). Gyro (its own rate, e.g. 25 Hz beside 50 Hz accel) is resampled on
  its own and linearly aligned onto the accel's 30 Hz grid via the two streams' first timestamps.
  Known limitation (found by agent HF): a block's rate is ONE nominal rate from its median interval, but
  ~20 WISDM blocks switch between 20 Hz and ~100 Hz mid-block (test: 1605-I, 1607-L, 1617-P, 371 of
  12,493 windows; val: 1620-Q, 1624-Q, 182 windows); their off-rate stretches are time-scaled by 5x.
  Kept as is so existing replay outputs stay comparable; ``activity_context.wisdm`` segments per rate.
  Capture-24: 100 Hz accel through the exact production resampler (``resample_3_10``); gyro absent.
* **HART windows** exactly as ``serve.classify_windows`` would emit them (4 s / 2 s grid anchored at the
  recording start, 1 s FIR-transient margin at both edges, ``HARTModel.predict_window``, probabilities
  rounded to 6 dp, label after the manifest abstention, ``feat`` = imu-feat-1).
* **1 Hz strap-stream proxies** derived from wrist accel only: gravity (mean accel over the second, g) and a
  ``dynAccel`` proxy (see :data:`DYN_PROXY_DEFAULT`). The strap's own ``dynamic_acceleration@41`` is an
  on-device gravity-removed magnitude whose filter is not documented; these are proxies and are labelled so.
* **Per-second truth** per head (posture / locomotion / arm_behavior) as class-set bitmasks over the fixed
  INERTIA1.md §5 class orders (0 = MASK, never ``unknown``), from the audited crosswalk.

Pure numpy at import; scipy / torch / pandas are imported lazily inside the functions that need them.
"""

from __future__ import annotations

import json
import math
import os
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np

from ..preprocess import Run, Window, resample_poly_nd, windows_from_run, HOP_SAMPLES, TARGET_HZ

# ---------------------------------------------------------------------------
# Paths: environment only (activity_context/inertia/paths.py); "" = not configured. Nothing here is required
# at import time. Ground truth always comes from the repo's audited crosswalk (label_mappings.json next to
# mappings.py) — never from an untracked copy.
# ---------------------------------------------------------------------------

from . import paths as _paths
from .mappings import MAPPINGS_PATH

WISDM_DIR = _paths.wisdm_dir()
HART_OUT_DIR = os.environ.get("HART_OUT_DIR", "")
CAPTURE24_DIR = _paths.capture24_dir()
CROSSWALK_PATH = MAPPINGS_PATH
REPLAY_DIR = _paths.replay_dir()


def replay_root() -> str:
    """The configured replay work tree (refuses when NARA_REPLAY_DIR / INERTIA_DATA_ROOT is unset)."""
    return _paths.require_dir(REPLAY_DIR, "NARA_REPLAY_DIR / INERTIA_DATA_ROOT (replay work tree)")


# The StrandAnalytics package of THIS checkout (Tools/ActivityContext/../../Packages/StrandAnalytics).
STRAND_PACKAGE_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..",
                                                   "Packages", "StrandAnalytics"))

STANDIN_BANNER = "STAND-IN, NOT INERTIA-1"

# HART's seed-42 WISDM split (activity-train/out/split_manifest.json; eval/RESULTS.md).
WISDM_TEST_SUBJECTS = (1605, 1607, 1617, 1627, 1638, 1646, 1648, 1650)
WISDM_VAL_SUBJECTS = (1618, 1620, 1623, 1624, 1629, 1634, 1637, 1639)

M_S2_TO_G = 1.0 / 9.80665
RAD_S_TO_DEG_S = 180.0 / math.pi
SESSION_GAP_NS = 1_000_000_000     # > 1 s gap ends a recording (train.py convention)
GYRO_MATCH_SLACK_NS = 100_000_000  # gyro rows may start/end up to 100 ms outside the accel block
NOMINAL_RATES_HZ = (20, 25, 50, 100)
RATE_TOLERANCE = 0.03              # measured median rate must be within 3 % of a nominal rate

# Fixed class orders (INERTIA1.md §5). Bit i of a truth mask = class_order[i].
HEAD_ORDERS: Dict[str, Tuple[str, ...]] = {
    "posture": ("recumbent", "seated_likely", "upright_stationary", "postural_transition"),
    "locomotion": ("stationary", "walking", "brisk_walking", "running", "stairs", "cycling",
                   "vehicle_motion", "other"),
    "arm_behavior": ("quiet", "desk_like", "fidgeting", "repetitive_hand_motion", "active_gesturing",
                     "exercise_motion", "other"),
}
TRUTH_HEADS: Tuple[str, ...] = tuple(HEAD_ORDERS)
COARSE_ORDER: Tuple[str, ...] = ("stationary", "walking", "running", "other_movement")
# locomotion class -> HART coarse ontology (the decoder's locomotion head is collapsed the same way)
LOCOMOTION_TO_COARSE = {"stationary": "stationary", "walking": "walking", "brisk_walking": "walking",
                        "running": "running", "stairs": "other_movement", "cycling": "other_movement",
                        "vehicle_motion": "other_movement", "other": "other_movement"}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def nominal_rate(ts_ns: np.ndarray) -> Tuple[float, int]:
    """(measured median rate Hz, nominal rate) of a timestamp series; raises when no nominal rate fits."""
    if ts_ns.size < 3:
        raise ValueError("too few samples to detect a rate")
    dt = np.diff(ts_ns.astype(np.int64)) / 1e9
    med = float(np.median(dt))
    if not med > 0:
        raise ValueError("non-increasing timestamps")
    measured = 1.0 / med
    best = min(NOMINAL_RATES_HZ, key=lambda r: abs(measured - r))
    if abs(measured - best) / best > RATE_TOLERANCE:
        raise ValueError(f"measured rate {measured:.2f} Hz is not within {RATE_TOLERANCE:.0%} of {NOMINAL_RATES_HZ}")
    return measured, int(best)


def regrid_uniform(ts_ns: np.ndarray, x: np.ndarray, rate_hz: int) -> Tuple[np.ndarray, float]:
    """Linear re-grid of (ts, x) onto an exact uniform grid at ``rate_hz`` starting at ts[0].

    Returns (x_uniform (n, C), duration_s). Corrects the small rate error / jitter between the device's
    actual timestamps and its nominal rate (e.g. 49.8 Hz recorded as '50 Hz') before polyphase resampling.
    """
    t = (ts_ns.astype(np.int64) - int(ts_ns[0])) / 1e9
    dur = float(t[-1])
    n = int(math.floor(dur * rate_hz + 1e-9)) + 1
    grid = np.arange(n, dtype=np.float64) / rate_hz
    out = np.empty((n, x.shape[1]), dtype=np.float64)
    for c in range(x.shape[1]):
        out[:, c] = np.interp(grid, t, x[:, c])
    return out, dur


# Linear re-gridding at drifting fractional offsets is a low-pass (a half-sample linear interpolation has
# gain cos(pi f / fs): 0.71 at 5 Hz for a 20 Hz stream). A first run with it lowered HART's accepted
# coverage on the WISDM test subjects (0.547 -> 0.522) and moved its inputs away from what HART was trained
# on (raw sample index at 20 Hz), so the default is to take the samples as uniform at the detected nominal
# rate (measured rates are within 0.5 % of nominal: 20.01 Hz / 24.8 Hz / 49.8 Hz).
REGRID_TIMESTAMPS = False


def as_uniform(ts_ns: np.ndarray, x: np.ndarray, rate_hz: int) -> Tuple[np.ndarray, float]:
    """Samples of one recording as a uniform series at the nominal rate (or re-gridded when enabled)."""
    if REGRID_TIMESTAMPS:
        return regrid_uniform(ts_ns, x, rate_hz)
    x = np.asarray(x, dtype=np.float64)
    return x, (x.shape[0] - 1) / float(rate_hz)


def resample_to_30hz(x: np.ndarray, rate_hz: int) -> np.ndarray:
    """Repo polyphase resampler from an integer nominal rate to 30 Hz (20->3/2, 25->6/5, 50->3/5, 100->3/10)."""
    frac = Fraction(TARGET_HZ, int(rate_hz))
    return resample_poly_nd(np.asarray(x, dtype=np.float64), frac.numerator, frac.denominator, axis=0)


class Resampled30Run(Run):
    """A Run whose 30 Hz stream is already computed (public data arrives at its own rate, not 100 Hz).

    ``preprocess.windows_from_run`` only calls ``resampled()`` and reads ``start_ts`` / ``end_ts``, so the
    serve windowing semantics (request-anchored 2 s grid, 1 s transient margin, fully-inside rule) apply
    unchanged.
    """

    def __init__(self, start_ts: int, data30: np.ndarray):
        n_seconds = int(data30.shape[0] // TARGET_HZ)
        super().__init__(start_ts=int(start_ts), samples=np.zeros((0, 6)), end_ts=int(start_ts) + n_seconds)
        self._data30 = np.ascontiguousarray(data30, dtype=np.float64)

    def resampled(self) -> np.ndarray:  # noqa: D401 - Run API
        return self._data30


def serve_windows(data30: np.ndarray, start_ts: int = 0, hop_samples: int = HOP_SAMPLES) -> List[Window]:
    """4 s windows exactly as serve.classify_windows builds them for a request covering the whole run."""
    run = Resampled30Run(start_ts, data30)
    return windows_from_run(run, run.start_ts, run.end_ts, hop_samples=hop_samples)


# ---------------------------------------------------------------------------
# 1 Hz strap-stream proxies
# ---------------------------------------------------------------------------

# Gravity-removal low-pass for the dynAccel proxy: 2nd-order Butterworth at 0.5 Hz, zero-phase (filtfilt).
GRAVITY_LP_HZ = 0.5
GRAVITY_LP_ORDER = 2
DYN_PROXY_NAMES = ("dyn_vec_mean", "dyn_vec_rms", "dyn_vec_inst", "dyn_mag_rms", "enmo_mean")
# Chosen on TRAIN subjects only (WISDM 12 train subjects D/A/B + 10 Capture-24 train participants; log10-RMS
# distance of the per-class medians to the strap anchors below; research/inertia-replay/proxy_choice.json):
# dyn_mag_rms 0.18 (rest 9 mg / walk 166 mg / run 741 mg) beat enmo_mean 0.21 and every vector-removal
# variant (0.37-0.49: a rotating wrist leaks gravity into |a - LP(a)|). Fixed before any test scoring.
DYN_PROXY_DEFAULT = "dyn_mag_rms"
# Strap anchors from ActivityContextEvidence.swift (ActivityIntensity): resting ~7 mg, walking median ~135
# mg, running median ~400 mg.
STRAP_ANCHORS_G = {"rest": 0.007, "walking": 0.135, "running": 0.400}


def per_second_proxies(acc30: np.ndarray, fs: int = TARGET_HZ) -> Dict[str, np.ndarray]:
    """Per-second gravity (mean accel, g) and dynAccel proxy candidates from a contiguous 30 Hz accel run.

    Second i covers samples [fs*i, fs*(i+1)). Only complete seconds are returned.
    Candidates (all g):
      dyn_vec_mean  mean over the second of |a - LP(a)|        (expected value of an instantaneous sample)
      dyn_vec_rms   RMS  over the second of |a - LP(a)|
      dyn_vec_inst  |a - LP(a)| at the last sample of the second (one instant per second, like the strap)
      dyn_mag_rms   RMS of |a| - LP(|a|)                       (magnitude AC, like imu-feat-1 accel_rms_g)
      enmo_mean     mean of max(|a| - 1, 0)                    (ENMO)
    """
    from scipy.signal import butter, filtfilt

    acc30 = np.asarray(acc30, dtype=np.float64)
    n_sec = acc30.shape[0] // fs
    out: Dict[str, np.ndarray] = {"gravity": np.zeros((n_sec, 3), dtype=np.float32)}
    for k in DYN_PROXY_NAMES:
        out[k] = np.zeros(n_sec, dtype=np.float32)
    if n_sec == 0:
        return out
    a = acc30[: n_sec * fs]
    b, aa = butter(GRAVITY_LP_ORDER, GRAVITY_LP_HZ, fs=fs)
    padlen = 3 * max(len(aa), len(b))
    if a.shape[0] > padlen:
        g_lp = filtfilt(b, aa, a, axis=0)
        mag = np.linalg.norm(a, axis=1)
        mag_lp = filtfilt(b, aa, mag)
    else:  # too short to filter: per-recording mean as the gravity estimate
        g_lp = np.broadcast_to(a.mean(axis=0), a.shape)
        mag = np.linalg.norm(a, axis=1)
        mag_lp = np.full_like(mag, mag.mean())
    lin = np.linalg.norm(a - g_lp, axis=1).reshape(n_sec, fs)
    out["gravity"] = a.reshape(n_sec, fs, 3).mean(axis=1).astype(np.float32)
    out["dyn_vec_mean"] = lin.mean(axis=1).astype(np.float32)
    out["dyn_vec_rms"] = np.sqrt((lin ** 2).mean(axis=1)).astype(np.float32)
    out["dyn_vec_inst"] = lin[:, -1].astype(np.float32)
    mac = (mag - mag_lp).reshape(n_sec, fs)
    out["dyn_mag_rms"] = np.sqrt((mac ** 2).mean(axis=1)).astype(np.float32)
    out["enmo_mean"] = np.maximum(mag - 1.0, 0.0).reshape(n_sec, fs).mean(axis=1).astype(np.float32)
    return out


def choose_dyn_proxy(medians: Dict[str, Dict[str, float]]) -> Tuple[str, Dict[str, float]]:
    """Pick the proxy whose per-class medians best match the strap anchors in log space.

    ``medians[proxy][cls]`` for cls in STRAP_ANCHORS_G (computed on TRAIN subjects only). Returns
    (name, {proxy: rms log10 error}).
    """
    errs: Dict[str, float] = {}
    for name, med in medians.items():
        d = [math.log10(max(med[c], 1e-6) / STRAP_ANCHORS_G[c]) for c in STRAP_ANCHORS_G if c in med]
        if d:
            errs[name] = float(np.sqrt(np.mean(np.square(d))))
    best = min(errs, key=errs.get)
    return best, errs


# ---------------------------------------------------------------------------
# Truth: audited crosswalk -> per-head class-set bitmasks
# ---------------------------------------------------------------------------

@dataclass
class HeadTruth:
    strict: int = 0     # mask from rows with used_for_training == True
    lenient: int = 0    # mask from any non-MASK row (incl. documented low-confidence candidates)


def _mask_for(head: str, target: Any) -> int:
    order = HEAD_ORDERS[head]
    if target is None or target == "MASK":
        return 0
    targets = target if isinstance(target, list) else [target]
    m = 0
    for t in targets:
        if t in order:
            m |= 1 << order.index(t)
        else:
            return 0  # 'unknown' / 'none' / anything off-vocabulary is never a positive truth
    return m


def load_crosswalk(dataset: str, path: str = CROSSWALK_PATH) -> Dict[str, Dict[str, HeadTruth]]:
    """{source_label: {head: HeadTruth}} for one dataset of the audited crosswalk."""
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    rows = doc["mappings"] if isinstance(doc, dict) else doc
    out: Dict[str, Dict[str, HeadTruth]] = {}
    for r in rows:
        if r.get("dataset") != dataset or r.get("nara_head") not in HEAD_ORDERS:
            continue
        head = r["nara_head"]
        m = _mask_for(head, r.get("nara_target"))
        ht = out.setdefault(str(r["source_label"]), {}).setdefault(head, HeadTruth())
        ht.lenient |= m
        if r.get("used_for_training"):
            ht.strict |= m
    return out


def coarse_mask_from_locomotion(loco_mask: int) -> int:
    """HART coarse ontology mask implied by a locomotion truth mask (0 = MASK)."""
    m = 0
    for i, c in enumerate(HEAD_ORDERS["locomotion"]):
        if loco_mask & (1 << i):
            m |= 1 << COARSE_ORDER.index(LOCOMOTION_TO_COARSE[c])
    return m


def crosswalk_sha256(path: str = CROSSWALK_PATH) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


# ---------------------------------------------------------------------------
# WISDM-2019 watch: blocks = (subject, activity) recordings, each sensor at its own rate
# ---------------------------------------------------------------------------

def parse_wisdm_raw(path: str) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(activity letters [N], timestamps ns int64 [N], xyz float64 [N,3]) of one WISDM raw file."""
    acts: List[str] = []
    ts: List[int] = []
    xyz: List[Tuple[float, float, float]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip().rstrip(";").strip()
            if not line:
                continue
            p = line.split(",")
            if len(p) != 6:
                continue
            try:
                t = int(p[2])
                v = (float(p[3]), float(p[4]), float(p[5]))
            except ValueError:
                continue
            acts.append(p[1])
            ts.append(t)
            xyz.append(v)
    return np.asarray(acts), np.asarray(ts, dtype=np.int64), np.asarray(xyz, dtype=np.float64)


def split_recordings(acts: np.ndarray, ts: np.ndarray) -> List[Tuple[int, int]]:
    """[start, end) index ranges: a new recording at every activity change, gap > 1 s or non-increasing ts."""
    out: List[Tuple[int, int]] = []
    if len(ts) == 0:
        return out
    s = 0
    for i in range(1, len(ts) + 1):
        if i == len(ts) or acts[i] != acts[i - 1] or ts[i] - ts[i - 1] > SESSION_GAP_NS or ts[i] <= ts[i - 1]:
            out.append((s, i))
            s = i
    return out


@dataclass
class WisdmBlock:
    subject: int
    activity: str
    index: int                     # order of the block in the subject's accel file
    t0_ns: int                     # first accel timestamp of the block (the block's own time base)
    acc_measured_hz: float
    acc_nominal_hz: int
    n_acc: int
    gyr_measured_hz: Optional[float]
    gyr_nominal_hz: Optional[int]
    n_gyr: int
    data30: np.ndarray             # (N, 6) g / deg/s at 30 Hz on the accel grid; gyro NaN where uncovered
    duration_s: float

    @property
    def block_id(self) -> str:
        return f"wisdm-{self.subject}-{self.index:02d}-{self.activity}"

    @property
    def gyro_coverage(self) -> float:
        if self.data30.shape[0] == 0:
            return 0.0
        return float(np.isfinite(self.data30[:, 3]).mean())


def wisdm_blocks_for_subject(subject: int, wisdm_dir: str = WISDM_DIR) -> List[WisdmBlock]:
    ap = os.path.join(wisdm_dir, "raw", "watch", "accel", f"data_{subject}_accel_watch.txt")
    gp = os.path.join(wisdm_dir, "raw", "watch", "gyro", f"data_{subject}_gyro_watch.txt")
    a_act, a_ts, a_xyz = parse_wisdm_raw(ap)
    g_act, g_ts, g_xyz = parse_wisdm_raw(gp)
    g_recs = split_recordings(g_act, g_ts)
    blocks: List[WisdmBlock] = []
    for bi, (s, e) in enumerate(split_recordings(a_act, a_ts)):
        act = str(a_act[s])
        ts = a_ts[s:e]
        if e - s < 3 * 20:
            continue
        acc_meas, acc_nom = nominal_rate(ts)
        acc_u, dur = as_uniform(ts, a_xyz[s:e] * M_S2_TO_G, acc_nom)
        acc30 = resample_to_30hz(acc_u, acc_nom)
        n30 = acc30.shape[0]
        t30 = np.arange(n30) / TARGET_HZ                       # seconds from t0 (accel grid)
        gyr30 = np.full((n30, 3), np.nan)
        g_meas: Optional[float] = None
        g_nom: Optional[int] = None
        n_g = 0
        # gyro recording(s) of the same activity overlapping this accel block
        for gs, ge in g_recs:
            if str(g_act[gs]) != act:
                continue
            if g_ts[ge - 1] < ts[0] - GYRO_MATCH_SLACK_NS or g_ts[gs] > ts[-1] + GYRO_MATCH_SLACK_NS:
                continue
            if ge - gs < 3 * 20:
                continue
            gm, gn = nominal_rate(g_ts[gs:ge])
            g_u, _ = as_uniform(g_ts[gs:ge], g_xyz[gs:ge] * RAD_S_TO_DEG_S, gn)
            g30 = resample_to_30hz(g_u, gn)
            tg = (int(g_ts[gs]) - int(ts[0])) / 1e9 + np.arange(g30.shape[0]) / TARGET_HZ
            inside = (t30 >= tg[0]) & (t30 <= tg[-1])
            for c in range(3):
                gyr30[inside, c] = np.interp(t30[inside], tg, g30[:, c])
            g_meas, g_nom = gm, gn
            n_g += ge - gs
        data30 = np.concatenate([acc30, gyr30], axis=1)
        blocks.append(WisdmBlock(subject=subject, activity=act, index=bi, t0_ns=int(ts[0]),
                                 acc_measured_hz=acc_meas, acc_nominal_hz=acc_nom, n_acc=e - s,
                                 gyr_measured_hz=g_meas, gyr_nominal_hz=g_nom, n_gyr=n_g,
                                 data30=data30, duration_s=dur))
    return blocks


def hart_window_record(w: Window, pred, feat: Dict[str, Optional[float]]) -> Dict[str, Any]:
    """The window dict exactly as serve.classify_windows emits it (HART path)."""
    return {
        "s": round(w.s, 6),
        "e": round(w.e, 6),
        "label": pred.label,
        "probs": {k: round(float(v), 6) for k, v in pred.probs.items()},
        "baseline": bool(pred.baseline),
        "feat": feat,
    }


def run_wisdm_subject(subject: int, manifest_path: str, checkpoint_dir: str,
                      wisdm_dir: str = WISDM_DIR, gyro_mode: str = "real") -> Dict[str, Any]:
    """HART windows + 1 Hz proxies + per-block metadata for one WISDM subject (needs the [model] extra).

    ``gyro_mode="real"`` (default, production-faithful: WHOOP always streams gyro) feeds the aligned gyro.
    ``gyro_mode="zero"`` is a DIAGNOSTIC that reproduces what ``activity_context.train`` trained and evaluated
    hart-wisdm-v0 on: its old accel/gyro merge ``np.searchsorted``-ed an unsorted gyro timestamp array (WISDM
    timestamps jump at activity changes), so ~82 % of v0's train windows and ~83 % of its eval windows
    carry all-zero gyro. train.py now loads through ``activity_context.wisdm`` (no fill; hart-wisdm-v1).
    """
    if gyro_mode not in ("real", "zero"):
        raise ValueError("gyro_mode must be 'real' or 'zero'")
    from ..features import window_features
    from ..manifest import load_manifest
    from ..model import HARTModel

    man = load_manifest(manifest_path)
    model = HARTModel(man, checkpoint_dir)
    blocks_out: List[Dict[str, Any]] = []
    for b in wisdm_blocks_for_subject(subject, wisdm_dir):
        if gyro_mode == "zero":
            b.data30[:, 3:6] = 0.0
        wins = serve_windows(b.data30, start_ts=0)
        recs: List[Dict[str, Any]] = []
        feats_acc: List[Dict[str, Any]] = []
        n_gyro_missing = 0
        for w in wins:
            if not np.isfinite(w.data).all():
                n_gyro_missing += 1
                # accel-only imu-feat-1 is still computable (gyro zeros), like the Capture-24 path
                wz = Window(s=w.s, e=w.e, data=np.nan_to_num(w.data, nan=0.0))
                feats_acc.append({"s": round(w.s, 6), "e": round(w.e, 6), "feat": window_features(wz)})
                continue
            pred = model.predict_window(w.data)
            feat = window_features(w)
            recs.append(hart_window_record(w, pred, feat))
            feats_acc.append({"s": round(w.s, 6), "e": round(w.e, 6), "feat": feat})
        prox = per_second_proxies(b.data30[:, 0:3])
        blocks_out.append({
            "block_id": b.block_id, "subject": b.subject, "activity": b.activity, "index": b.index,
            "t0_ns": b.t0_ns, "duration_s": round(b.duration_s, 3),
            "acc_measured_hz": round(b.acc_measured_hz, 3), "acc_nominal_hz": b.acc_nominal_hz, "n_acc": b.n_acc,
            "gyr_measured_hz": None if b.gyr_measured_hz is None else round(b.gyr_measured_hz, 3),
            "gyr_nominal_hz": b.gyr_nominal_hz, "n_gyr": b.n_gyr, "gyro_coverage": round(b.gyro_coverage, 4),
            "n_seconds": int(prox["gravity"].shape[0]), "n_windows_grid": len(wins),
            "n_windows_gyro_missing": n_gyro_missing,
            "hart_windows": recs, "imu_windows": feats_acc,
            "proxies": {k: v.tolist() for k, v in prox.items()},
        })
    model.close()
    return {"subject": subject, "gyro_mode": gyro_mode, "model_version": man.model_version,
            "checkpoint_sha256": man.checkpoint["files"]["model.safetensors"]["sha256"],
            "thresholds": man.thresholds, "label_mapping": man.label_mapping, "blocks": blocks_out}


# ---------------------------------------------------------------------------
# Capture-24 (100 Hz wrist accel, g, ~24 h per participant)
# ---------------------------------------------------------------------------

def capture24_participant(pid: str, c24_dir: str = CAPTURE24_DIR) -> Dict[str, Any]:
    """Per-second proxies, per-second annotation, accel-only imu-feat-1 windows for one participant.

    Runs: contiguous integer seconds with exactly 100 finite samples each (gaps split runs; never
    interpolated across). Per-second annotation: the annotation shared by all 100 samples of the second,
    else none (MASK).
    """
    import pyarrow.parquet as pq
    from ..features import window_features
    from ..preprocess import resample_3_10

    path = os.path.join(c24_dir, f"pid={pid}", "data.parquet")
    tbl = pq.read_table(path, columns=["timestamp_ms", "x", "y", "z", "annotation"])
    ts = tbl.column("timestamp_ms").to_numpy().astype(np.int64)
    xyz = np.stack([tbl.column(c).to_numpy().astype(np.float64) for c in ("x", "y", "z")], axis=1)
    ann_col = tbl.column("annotation").combine_chunks()
    ann_dict = ann_col.dictionary_encode()
    ann_idx = ann_dict.indices.to_numpy(zero_copy_only=False)
    ann_idx = np.where(ann_dict.indices.is_null().to_numpy(zero_copy_only=False), -1, ann_idx).astype(np.int32)
    labels = [str(v) for v in ann_dict.dictionary.to_pylist()]
    del tbl

    sec = ts // 1000
    sub = ts % 1000
    if not np.all(sub % 10 == 0):
        raise ValueError(f"{pid}: timestamps are not on a 10 ms grid")
    # second -> samples; require exactly 100 samples, slots 0..99 once each, all finite
    uniq, first, counts = np.unique(sec, return_index=True, return_counts=True)
    order_ok = np.all(np.diff(ts) > 0)
    if not order_ok:
        raise ValueError(f"{pid}: timestamps not strictly increasing")
    full = counts == 100
    finite = np.isfinite(xyz).all(axis=1)
    # per-second finite check
    fin_sec = np.add.reduceat(finite.astype(np.int64), first) == counts
    keep = full & fin_sec
    secs = uniq[keep]
    starts = first[keep]
    # annotation per kept second: same index on all 100 samples
    a2 = ann_idx[starts[:, None] + np.arange(100)[None, :]]
    same = (a2 == a2[:, :1]).all(axis=1)
    sec_ann = np.where(same, a2[:, 0], -1).astype(np.int32)
    # runs of consecutive kept seconds
    brk = np.where(np.diff(secs) != 1)[0] + 1
    run_bounds = np.split(np.arange(len(secs)), brk)
    grav = np.zeros((len(secs), 3), dtype=np.float32)
    dyn = {k: np.zeros(len(secs), dtype=np.float32) for k in DYN_PROXY_NAMES}
    imu_s: List[int] = []
    imu_e: List[int] = []
    imu_f: List[List[float]] = []
    FEAT_KEYS = ("accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz", "cadence_strength",
                 "orientation_change_deg")
    runs_meta = []
    for idx in run_bounds:
        if len(idx) == 0:
            continue
        s0 = int(secs[idx[0]])
        rows = (starts[idx][:, None] + np.arange(100)[None, :]).reshape(-1)
        acc100 = xyz[rows]
        acc30 = resample_3_10(acc100, axis=0)
        prox = per_second_proxies(acc30)
        grav[idx] = prox["gravity"]
        for k in DYN_PROXY_NAMES:
            dyn[k][idx] = prox[k]
        data30 = np.concatenate([acc30, np.zeros_like(acc30)], axis=1)   # no gyro on Capture-24
        for w in serve_windows(data30, start_ts=s0):
            f = window_features(w)
            imu_s.append(int(round(w.s)))
            imu_e.append(int(round(w.e)))
            imu_f.append([np.nan if f[k] is None else float(f[k]) for k in FEAT_KEYS])
        runs_meta.append((s0, int(secs[idx[-1]]) + 1))
    return {
        "pid": pid, "labels": labels, "ts": secs.astype(np.int64), "ann": sec_ann, "gravity": grav,
        **{k: v for k, v in dyn.items()},
        "imu_s": np.asarray(imu_s, dtype=np.int64), "imu_e": np.asarray(imu_e, dtype=np.int64),
        "imu_feat": np.asarray(imu_f, dtype=np.float32).reshape(-1, len(FEAT_KEYS)),
        "imu_feat_keys": np.asarray(FEAT_KEYS), "runs": np.asarray(runs_meta, dtype=np.int64).reshape(-1, 2),
        "n_samples": int(len(ts)), "n_seconds_raw": int(len(uniq)),
    }


def load_splits(datasets: Sequence[str] = ("capture24", "wisdm2019_watch")) -> Dict[str, Dict[str, Any]]:
    """The repo's frozen subject splits (Tools/ActivityContext/splits/<dataset>.json, sha256-verified)."""
    from .splits import load_splits as _load
    return _load(list(datasets))


# ---------------------------------------------------------------------------
# HART reproduction summary (per-window accuracy vs the manifest's coarse mapping)
# ---------------------------------------------------------------------------

FEAT_KEYS: Tuple[str, ...] = ("accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz", "cadence_strength",
                              "orientation_change_deg")


def flatten_hart(subject_docs: Sequence[Dict[str, Any]]) -> Dict[str, np.ndarray]:
    """Per-window arrays over many subject documents from :func:`run_wisdm_subject`."""
    cols: Dict[str, List[Any]] = {k: [] for k in ("subject", "block_id", "activity", "acc_nominal_hz", "s", "e",
                                                    "label", "probs", "feat")}
    for doc in subject_docs:
        for b in doc["blocks"]:
            for w in b["hart_windows"]:
                cols["subject"].append(b["subject"])
                cols["block_id"].append(b["block_id"])
                cols["activity"].append(b["activity"])
                cols["acc_nominal_hz"].append(b["acc_nominal_hz"])
                cols["s"].append(w["s"])
                cols["e"].append(w["e"])
                cols["label"].append(w["label"])
                cols["probs"].append([w["probs"].get(c, 0.0) for c in COARSE_ORDER])
                cols["feat"].append([np.nan if w["feat"].get(k) is None else float(w["feat"][k]) for k in FEAT_KEYS])
    out = {
        "subject": np.asarray(cols["subject"], dtype=np.int64),
        "block_id": np.asarray(cols["block_id"]),
        "activity": np.asarray(cols["activity"]),
        "acc_nominal_hz": np.asarray(cols["acc_nominal_hz"], dtype=np.int64),
        "s": np.asarray(cols["s"], dtype=np.float64),
        "e": np.asarray(cols["e"], dtype=np.float64),
        "label": np.asarray(cols["label"]),
        "probs": np.asarray(cols["probs"], dtype=np.float64).reshape(-1, len(COARSE_ORDER)),
        "probs_order": np.asarray(COARSE_ORDER),
        "feat": np.asarray(cols["feat"], dtype=np.float64).reshape(-1, len(FEAT_KEYS)),
        "feat_keys": np.asarray(FEAT_KEYS),
    }
    return out


def hart_accuracy(flat: Dict[str, np.ndarray], label_mapping: Dict[str, str]) -> Dict[str, Any]:
    """eval/RESULTS.md-style metrics: coverage, per-class P/R/F1 over accepted, macro-F1, confusion."""
    truth = np.asarray([label_mapping.get(a, "other_movement") for a in flat["activity"]])
    pred = flat["label"]
    labels = list(COARSE_ORDER) + ["unknown"]
    conf = {t: {p: int(np.sum((truth == t) & (pred == p))) for p in labels} for t in COARSE_ORDER}
    per = {}
    f1s = []
    for c in COARSE_ORDER:
        tp = int(np.sum((truth == c) & (pred == c)))
        fp = int(np.sum((truth != c) & (pred == c)))
        fn = int(np.sum((truth == c) & (pred != c)))
        p = tp / (tp + fp) if tp + fp else 0.0
        r = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * p * r / (p + r) if p + r else 0.0
        f1s.append(f1)
        per[c] = {"count": int(np.sum(truth == c)), "precision": round(p, 4), "recall": round(r, 4),
                  "f1": round(f1, 4)}
    acc = pred != "unknown"
    per_subject = {}
    for s in sorted(set(flat["subject"].tolist())):
        m = flat["subject"] == s
        per_subject[str(s)] = {"windows": int(m.sum()), "accepted": int((m & acc).sum()),
                               "coverage": round(float((m & acc).sum() / max(1, m.sum())), 4),
                               "accepted_accuracy": round(float(((pred == truth) & m & acc).sum()
                                                                / max(1, (m & acc).sum())), 4)}
    return {
        "n_windows": int(len(pred)), "n_accepted": int(acc.sum()), "coverage": round(float(acc.mean()), 4)
        if len(pred) else 0.0,
        "macro_f1_supported": round(float(np.mean(f1s)), 4),
        "accepted_accuracy": round(float(((pred == truth) & acc).sum() / max(1, acc.sum())), 4),
        "per_class": per, "confusion": conf, "per_subject": per_subject,
        "prediction_counts": {l: int(np.sum(pred == l)) for l in labels},
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _wisdm_worker(args: Tuple[int, str, str, str, str, str]) -> str:
    subject, manifest_path, checkpoint_dir, wisdm_dir, out_dir, gyro_mode = args
    doc = run_wisdm_subject(subject, manifest_path, checkpoint_dir, wisdm_dir, gyro_mode=gyro_mode)
    path = os.path.join(out_dir, f"wisdm_{subject}.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
    os.replace(tmp, path)
    return path


def _c24_worker(args: Tuple[str, str, str]) -> str:
    pid, c24_dir, out_dir = args
    d = capture24_participant(pid, c24_dir)
    path = os.path.join(out_dir, f"c24_{pid}.npz")
    labels = d.pop("labels")
    tmp = path + ".tmp.npz"
    np.savez_compressed(tmp, labels=np.asarray(labels), **{k: v for k, v in d.items()})
    os.replace(tmp, path)
    return path


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse
    from concurrent.futures import ProcessPoolExecutor

    ap = argparse.ArgumentParser(description="offline replay inputs (agent R)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("wisdm-hart", help="HART windows + 1 Hz proxies per WISDM subject")
    w.add_argument("--subjects", type=int, nargs="+", default=list(WISDM_TEST_SUBJECTS + WISDM_VAL_SUBJECTS))
    def opt(default):            # configured env path -> default; otherwise the flag is required
        return {"default": default} if default else {"required": True}
    w.add_argument("--manifest", **opt(os.path.join(HART_OUT_DIR, "manifest.json") if HART_OUT_DIR else ""))
    w.add_argument("--checkpoint", **opt(HART_OUT_DIR))
    w.add_argument("--wisdm", **opt(WISDM_DIR))
    w.add_argument("--out", **opt(os.path.join(REPLAY_DIR, "cache", "wisdm") if REPLAY_DIR else ""))
    w.add_argument("--jobs", type=int, default=8)
    w.add_argument("--gyro-mode", choices=("real", "zero"), default="real")
    c = sub.add_parser("capture24", help="1 Hz proxies + accel-only imu-feat-1 per Capture-24 participant")
    c.add_argument("--pids", nargs="+", required=True)
    c.add_argument("--c24", **opt(CAPTURE24_DIR))
    c.add_argument("--out", **opt(os.path.join(REPLAY_DIR, "cache", "capture24") if REPLAY_DIR else ""))
    c.add_argument("--jobs", type=int, default=8)
    args = ap.parse_args(argv)

    if args.cmd == "wisdm-hart":
        os.makedirs(args.out, exist_ok=True)
        jobs = [(s, args.manifest, args.checkpoint, args.wisdm, args.out, args.gyro_mode) for s in args.subjects]
        with ProcessPoolExecutor(max_workers=args.jobs) as ex:
            for p in ex.map(_wisdm_worker, jobs):
                print(p, flush=True)
        return 0
    if args.cmd == "capture24":
        os.makedirs(args.out, exist_ok=True)
        todo = [p for p in args.pids if not os.path.isfile(os.path.join(args.out, f"c24_{p}.npz"))]
        with ProcessPoolExecutor(max_workers=args.jobs) as ex:
            for p in ex.map(_c24_worker, [(p, args.c24, args.out) for p in todo]):
                print(p, flush=True)
        return 0
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(main())
