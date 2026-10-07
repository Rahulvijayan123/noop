"""Replay inputs for the system-level decoder comparison (agent R; INERTIA1.md §7, spec §17 / §23).

Arms (identical non-encoder inputs in every arm; only the encoder / motion-head channels differ):

  A0   1 Hz gravity + dynAccel proxy + imu-feat-1 windows (streams + engineered). No encoder, no heads.
  A0s  1 Hz streams only (the harness `streams` arm also drops imu-feat-1).
  A1   A0 + the existing HART encoder windows (``ActivityObservation.encoder``), today's production channel.
  A2   A0 + Inertia motion-head windows (``motionHeads``, candidate mode)          — STAND-IN, NOT INERTIA-1.
  A3   A0 + HART + Inertia motion heads                                          — STAND-IN, NOT INERTIA-1.
  NAV  forbidden naive-average ablation (spec §17 "do not average"): one encoder channel carrying
       0.5·HART + 0.5·Inertia locomotion (folded onto the v1 labels by the harness), no motion-head channel.

The neutral in-memory form is :class:`Recording` (one decoder sequence: a WISDM (subject, activity block) or
a Capture-24 participant). :func:`write_harness_file` writes the ``nara-activity-replay-1`` JSON Lines file the
Swift replay harness reads (``ACTIVITY_REPLAY_IN``; format authority:
``Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ActivityReplayHarness.swift``). The harness derives every
arm from ONE observation stream, so the non-encoder inputs are identical across arms by construction;
:data:`ARM_SOURCES` maps report arms to (file variant, harness arm).

Time convention: second ``i`` of a recording covers ``[t0 + i, t0 + i + 1)`` and its observation is stamped
``t0 + i + 1`` (the second it closes, ``ActivityObservation.ts``); a HART / imu window ``[s, e)`` rides on the
observation stamped ``e``; an Inertia window on the first observed second in ``[e, e + 2]``. Truth for second
``i`` is scored against the published state stamped ``t0 + i + 1``.

Pure numpy; no torch / scipy at import.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Tuple

import numpy as np

from . import replay_data as rd

STANDIN_BANNER = rd.STANDIN_BANNER
ARMS: Tuple[str, ...] = ("A0", "A0s", "A1", "A2", "A3", "NAV")

# WISDM recordings get a synthetic, non-overlapping unix time base (the decoder is reset per record anyway).
WISDM_TIME_BASE = 1_700_000_000
WISDM_TIME_STRIDE = 100_000

FEAT_KEYS = rd.FEAT_KEYS
HART_ORDER = rd.COARSE_ORDER


# ---------------------------------------------------------------------------
# Neutral recording
# ---------------------------------------------------------------------------

@dataclass
class Recording:
    """One decoder session with everything every arm shares, plus the optional encoder channels."""
    recording_id: str
    dataset: str                       # "wisdm" | "capture24"
    subject: str                       # cluster id for the subject bootstrap
    split: str                         # "test" | "val" | ...
    t0: int                            # unix second at which second 0 starts
    sec: np.ndarray                    # int64 [n] second offsets from t0 (sorted; gaps allowed)
    gravity: np.ndarray                # float32 [n, 3] g
    dyn: np.ndarray                    # float32 [n] dynAccel proxy, g
    # truth masks per head over replay_data.HEAD_ORDERS (bit i = class i); 0 = MASK
    truth_strict: Dict[str, np.ndarray] = field(default_factory=dict)   # head -> uint16 [n]
    truth_lenient: Dict[str, np.ndarray] = field(default_factory=dict)
    truth_label: Optional[np.ndarray] = None        # int32 [n] index into labels (-1 = unlabeled)
    labels: Tuple[str, ...] = ()
    # imu-feat-1 windows (shared by all arms)
    imu_s: np.ndarray = field(default_factory=lambda: np.zeros(0, np.int64))   # offsets from t0
    imu_e: np.ndarray = field(default_factory=lambda: np.zeros(0, np.int64))
    imu_feat: np.ndarray = field(default_factory=lambda: np.zeros((0, len(FEAT_KEYS)), np.float32))
    # HART encoder windows (A1/A3/NAV)
    hart_s: np.ndarray = field(default_factory=lambda: np.zeros(0, np.int64))
    hart_e: np.ndarray = field(default_factory=lambda: np.zeros(0, np.int64))
    hart_probs: np.ndarray = field(default_factory=lambda: np.zeros((0, len(HART_ORDER)), np.float64))
    hart_label: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype="<U16"))
    meta: Dict[str, Any] = field(default_factory=dict)

    @property
    def n(self) -> int:
        return int(self.sec.shape[0])

    def obs_ts(self) -> np.ndarray:
        return self.t0 + self.sec.astype(np.int64) + 1

    def validate(self) -> None:
        n = self.n
        if self.gravity.shape != (n, 3) or self.dyn.shape != (n,):
            raise ValueError(f"{self.recording_id}: stream shapes do not match n={n}")
        if n and np.any(np.diff(self.sec) <= 0):
            raise ValueError(f"{self.recording_id}: seconds must be strictly increasing")
        for d in (self.truth_strict, self.truth_lenient):
            for h, m in d.items():
                if m.shape != (n,):
                    raise ValueError(f"{self.recording_id}: truth[{h}] shape {m.shape} != ({n},)")
        if not (len(self.hart_s) == len(self.hart_e) == len(self.hart_probs) == len(self.hart_label)):
            raise ValueError(f"{self.recording_id}: HART window arrays disagree in length")
        if not (len(self.imu_s) == len(self.imu_e) == len(self.imu_feat)):
            raise ValueError(f"{self.recording_id}: imu window arrays disagree in length")


# ---------------------------------------------------------------------------
# Builders from the Phase-1 caches (replay_data)
# ---------------------------------------------------------------------------

def _truth_arrays(label_idx: np.ndarray, labels: Sequence[str],
                  crosswalk: Mapping[str, Mapping[str, rd.HeadTruth]]) -> Tuple[Dict[str, np.ndarray], Dict[str, np.ndarray]]:
    strict: Dict[str, np.ndarray] = {}
    lenient: Dict[str, np.ndarray] = {}
    for h in rd.TRUTH_HEADS:
        s_tab = np.array([crosswalk.get(l, {}).get(h, rd.HeadTruth()).strict for l in labels] + [0], dtype=np.uint16)
        l_tab = np.array([crosswalk.get(l, {}).get(h, rd.HeadTruth()).lenient for l in labels] + [0], dtype=np.uint16)
        idx = np.where(label_idx >= 0, label_idx, len(labels))
        strict[h] = s_tab[idx]
        lenient[h] = l_tab[idx]
    return strict, lenient


def wisdm_recordings(split: str, cache_dir: Optional[str] = None, subjects: Optional[Sequence[int]] = None,
                     dyn_proxy: str = rd.DYN_PROXY_DEFAULT, require_hart: bool = True,
                     crosswalk_path: str = rd.CROSSWALK_PATH) -> List[Recording]:
    """WISDM recordings (one per (subject, activity block)) from ``replay_data wisdm-hart`` caches.

    ``require_hart``: drop blocks with no HART window (e.g. 1638's H/O blocks have no gyro at all) so every
    arm is scored on the same seconds.
    """
    cache_dir = cache_dir or os.path.join(rd.replay_root(), "cache", "wisdm")
    if subjects is None:
        subjects = rd.WISDM_TEST_SUBJECTS if split == "test" else rd.WISDM_VAL_SUBJECTS
    cw = rd.load_crosswalk("wisdm2019_watch", crosswalk_path)
    labels = tuple(sorted(cw))
    out: List[Recording] = []
    k = 0
    for s in subjects:
        with open(os.path.join(cache_dir, f"wisdm_{s}.json"), "r", encoding="utf-8") as f:
            doc = json.load(f)
        for b in doc["blocks"]:
            if require_hart and not b["hart_windows"]:
                continue
            n = int(b["n_seconds"])
            lab = np.full(n, labels.index(b["activity"]) if b["activity"] in labels else -1, dtype=np.int32)
            strict, lenient = _truth_arrays(lab, labels, cw)
            hw = b["hart_windows"]
            iw = b["imu_windows"]
            rec = Recording(
                recording_id=b["block_id"], dataset="wisdm", subject=str(b["subject"]), split=split,
                t0=WISDM_TIME_BASE + WISDM_TIME_STRIDE * k, sec=np.arange(n, dtype=np.int64),
                gravity=np.asarray(b["proxies"]["gravity"], dtype=np.float32).reshape(n, 3),
                dyn=np.asarray(b["proxies"][dyn_proxy], dtype=np.float32),
                truth_strict=strict, truth_lenient=lenient, truth_label=lab, labels=labels,
                imu_s=np.asarray([int(round(w["s"])) for w in iw], dtype=np.int64),
                imu_e=np.asarray([int(round(w["e"])) for w in iw], dtype=np.int64),
                imu_feat=np.asarray([[np.nan if w["feat"].get(q) is None else float(w["feat"][q]) for q in FEAT_KEYS]
                                     for w in iw], dtype=np.float32).reshape(-1, len(FEAT_KEYS)),
                hart_s=np.asarray([int(round(w["s"])) for w in hw], dtype=np.int64),
                hart_e=np.asarray([int(round(w["e"])) for w in hw], dtype=np.int64),
                hart_probs=np.asarray([[w["probs"].get(c, 0.0) for c in HART_ORDER] for w in hw],
                                      dtype=np.float64).reshape(-1, len(HART_ORDER)),
                hart_label=np.asarray([w["label"] for w in hw], dtype="<U16"),
                meta={"activity": b["activity"], "acc_nominal_hz": b["acc_nominal_hz"],
                      "gyr_nominal_hz": b["gyr_nominal_hz"], "block_index": b["index"],
                      "dyn_proxy": dyn_proxy, "hart_checkpoint_sha256": doc.get("checkpoint_sha256")},
            )
            rec.validate()
            out.append(rec)
            k += 1
    return out


def capture24_recordings(pids: Sequence[str], split: str, cache_dir: Optional[str] = None,
                         dyn_proxy: str = rd.DYN_PROXY_DEFAULT,
                         crosswalk_path: str = rd.CROSSWALK_PATH) -> List[Recording]:
    """One recording per Capture-24 participant (gaps stay gaps; the decoder's gapResetS handles them)."""
    cache_dir = cache_dir or os.path.join(rd.replay_root(), "cache", "capture24")
    cw = rd.load_crosswalk("capture24", crosswalk_path)
    out: List[Recording] = []
    for pid in pids:
        z = np.load(os.path.join(cache_dir, f"c24_{pid}.npz"), allow_pickle=False)
        labels = tuple(str(x) for x in z["labels"])
        ts = z["ts"].astype(np.int64)
        t0 = int(ts[0])
        lab = z["ann"].astype(np.int32)
        strict, lenient = _truth_arrays(lab, labels, cw)
        rec = Recording(
            recording_id=f"c24-{pid}", dataset="capture24", subject=pid, split=split, t0=t0,
            sec=ts - t0, gravity=z["gravity"].astype(np.float32), dyn=z[dyn_proxy].astype(np.float32),
            truth_strict=strict, truth_lenient=lenient, truth_label=lab, labels=labels,
            imu_s=z["imu_s"].astype(np.int64) - t0, imu_e=z["imu_e"].astype(np.int64) - t0,
            imu_feat=z["imu_feat"].astype(np.float32),
            meta={"dyn_proxy": dyn_proxy, "runs": z["runs"].tolist(), "gyro": "absent (zeros in imu-feat-1)"},
        )
        rec.validate()
        out.append(rec)
    return out


# ---------------------------------------------------------------------------
# Inertia windows (stand-in bundle predictions)
# ---------------------------------------------------------------------------

@dataclass
class HeadsWindows:
    """motion-heads-1 windows for one recording (offsets from the recording's t0)."""
    s: np.ndarray                      # int64 [k]
    e: np.ndarray                      # int64 [k]
    probs: Dict[str, np.ndarray]       # head -> float [k, K_head] over the bundle's class_order (NaN = unsupported)
    class_order: Dict[str, Tuple[str, ...]]
    movement_intensity: Optional[np.ndarray] = None
    ood_score: Optional[np.ndarray] = None
    is_ood: Optional[np.ndarray] = None

    def __len__(self) -> int:
        return int(self.s.shape[0])

    def window_dict(self, i: int, t0: int) -> Dict[str, Any]:
        """One wire-shaped window (absolute unix seconds; supported classes only)."""
        w: Dict[str, Any] = {"s": int(t0 + self.s[i]), "e": int(t0 + self.e[i])}
        for h, p in self.probs.items():
            row = p[i]
            d = {c: float(row[j]) for j, c in enumerate(self.class_order[h]) if np.isfinite(row[j])}
            if d:
                w[h] = d
        if self.movement_intensity is not None and np.isfinite(self.movement_intensity[i]):
            w["movement_intensity"] = float(self.movement_intensity[i])
        if self.ood_score is not None and np.isfinite(self.ood_score[i]):
            w["ood_score"] = float(self.ood_score[i])
        w["is_ood"] = bool(self.is_ood[i]) if self.is_ood is not None else False
        return w


# ---------------------------------------------------------------------------
# Swift replay harness input (`nara-activity-replay-1`; the authority for the format is
# Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ActivityReplayHarness.swift)
# ---------------------------------------------------------------------------

HARNESS_FORMAT = "nara-activity-replay-1"
HARNESS_OUT_FORMAT = "nara-activity-replay-out-1"
HARNESS_ARMS: Tuple[str, ...] = ("streams", "hart", "inertia", "hart+inertia", "naive_average",
                                 "eldernet", "hart+eldernet", "hart+eldernet+inertia")
# Report arm -> (input-file variant, harness arm). The harness's `streams` arm drops the imu-feat-1 windows as
# well as the encoder, while its `inertia` arm keeps them; so the engineered baseline that A2 must be compared
# with (same non-encoder inputs) is the harness `hart` arm on a file WITHOUT encoder windows ("noenc").
ARM_SOURCES: Dict[str, Tuple[str, str]] = {
    "A0": ("noenc", "hart"),           # 1 Hz streams + imu-feat-1 (engineered); no encoder, no heads
    "A0s": ("full", "streams"),        # 1 Hz streams only (harness `streams`; imu windows dropped too)
    "A1": ("full", "hart"),            # + HART encoder windows
    "A2": ("full", "inertia"),         # + Inertia heads, no HART              STAND-IN, NOT INERTIA-1
    "A3": ("full", "hart+inertia"),    # + HART + Inertia heads                STAND-IN, NOT INERTIA-1
    "NAV": ("full", "naive_average"),  # forbidden 0.5·HART + 0.5·Inertia ablation (harness implementation)
}
STANDIN_ARMS = ("A2", "A3", "NAV")


def _r(x: float, nd: int = 6) -> float:
    return float(round(float(x), nd))


def imu_record(rec: Recording, i: int) -> Dict[str, Any]:
    """`ImuWindowFeatures` JSON (absolute unix seconds; cadence / orientation null when absent)."""
    f = rec.imu_feat[i]
    d: Dict[str, Any] = {"s": int(rec.t0 + rec.imu_s[i]), "e": int(rec.t0 + rec.imu_e[i])}
    for q, k in enumerate(FEAT_KEYS):
        v = float(f[q])
        if k in ("cadence_hz", "orientation_change_deg"):
            d[k] = None if not math.isfinite(v) else _r(v, 5)
        else:
            d[k] = 0.0 if not math.isfinite(v) else _r(v, 5)
    return d


def encoder_record(rec: Recording, i: int, encoder_id: str = "hart",
                   encoder_version: str = "hart-wisdm-v0") -> Dict[str, Any]:
    """The HART window as `MotionEncoderOutput(prediction:)` wraps it (calibrated = !baseline, abstained =
    label == unknown); probabilities as serve emitted them (6 dp)."""
    return {"id": encoder_id, "version": encoder_version, "s": int(rec.t0 + rec.hart_s[i]),
            "e": int(rec.t0 + rec.hart_e[i]),
            "probs": {c: _r(rec.hart_probs[i, q]) for q, c in enumerate(HART_ORDER)},
            "calibrated": True, "abstained": str(rec.hart_label[i]) == "unknown"}


@dataclass
class AttachReport:
    windows_in: int = 0
    attached: int = 0
    dropped_no_observation: int = 0
    dropped_superseded: int = 0

    def add(self, o: "AttachReport") -> None:
        self.windows_in += o.windows_in
        self.attached += o.attached
        self.dropped_no_observation += o.dropped_no_observation
        self.dropped_superseded += o.dropped_superseded


def attach_heads(obs_ts: np.ndarray, heads: HeadsWindows, t0: int) -> Tuple[Dict[int, int], AttachReport]:
    """INERTIA1.md §7 / ActivityContextTrackBuilder.attachMotionHeads: each window rides on the first observed
    second in [e, e + 2]; a later window on the same second supersedes the earlier one.
    Returns {observation ts: window index}."""
    rep = AttachReport(windows_in=len(heads))
    observed = set(int(t) for t in obs_ts)
    at: Dict[int, int] = {}
    order = sorted(range(len(heads)), key=lambda i: (int(heads.e[i]), int(heads.s[i])))
    for i in order:
        e = int(t0 + heads.e[i])
        target = next((t for t in range(e, e + 3) if t in observed), None)
        if target is None:
            rep.dropped_no_observation += 1
            continue
        if target in at:
            rep.dropped_superseded += 1
            rep.attached -= 1
        at[target] = i
        rep.attached += 1
    return at, rep


@dataclass
class GaitWindows:
    """ElderNet gait-quality-1 windows for one recording, already on the recording's absolute clock (ELDERNET.md
    §4 wire objects: s, e, gait_prob, is_gait[, prefiltered][, speed_mps, cadence_spm, stride_m, regularity, steps])."""
    rows: List[Dict[str, Any]]

    def __post_init__(self) -> None:
        self.s = np.asarray([int(r["s"]) for r in self.rows], dtype=np.int64)
        self.e = np.asarray([int(r["e"]) for r in self.rows], dtype=np.int64)

    def __len__(self) -> int:
        return len(self.rows)


SHARED_OBS_KEYS = ("ts", "dyn", "grav", "wear", "sleep", "imu")


def observation_lines(rec: Recording, heads: Optional[HeadsWindows] = None, include_encoder: bool = True,
                      encoder_id: str = "hart", encoder_version: str = "hart-wisdm-v0",
                      gait: Optional[GaitWindows] = None) -> Tuple[List[Dict[str, Any]], AttachReport]:
    """`{"seq", "obs"}` lines of one recording. Non-encoder fields are identical whatever is included.
    ``gait`` (ElderNet windows, absolute clock) attaches like the motion heads: first observed second in
    [e, e + 2], a later window on the same second supersedes (ELDERNET.md §5)."""
    ts = rec.obs_ts()
    imu_at = {int(rec.t0 + rec.imu_e[i]): i for i in range(len(rec.imu_e))}
    enc_at = {int(rec.t0 + rec.hart_e[i]): i for i in range(len(rec.hart_e))} if include_encoder else {}
    head_at, rep = attach_heads(ts, heads, rec.t0) if heads is not None else ({}, AttachReport())
    gait_at, gait_rep = attach_heads(ts, gait, 0) if gait is not None else ({}, AttachReport())  # type: ignore[arg-type]
    rep.gait = gait_rep  # type: ignore[attr-defined]
    out: List[Dict[str, Any]] = []
    for j, t in enumerate(ts.tolist()):
        g = rec.gravity[j]
        o: Dict[str, Any] = {"ts": int(t), "dyn": _r(rec.dyn[j]), "grav": [_r(g[0]), _r(g[1]), _r(g[2])],
                             "wear": "onWrist", "sleep": "unknown"}
        if t in imu_at:
            o["imu"] = imu_record(rec, imu_at[t])
        if t in enc_at:
            o["encoder"] = encoder_record(rec, enc_at[t], encoder_id, encoder_version)
        if t in head_at:
            o["motion_heads"] = heads.window_dict(head_at[t], rec.t0)  # type: ignore[union-attr]
        if t in gait_at:
            o["gait_quality"] = dict(gait.rows[gait_at[t]])  # type: ignore[union-attr]
        out.append({"seq": rec.recording_id, "obs": o})
    return out, rep


def shared_inputs_digest(lines: Sequence[Mapping[str, Any]]) -> str:
    """sha256 over the non-encoder fields of observation lines (equal across file variants and arms)."""
    h = hashlib.sha256()
    for ln in lines:
        o = ln["obs"]
        h.update(json.dumps({k: o[k] for k in SHARED_OBS_KEYS if k in o}, sort_keys=True,
                            separators=(",", ":")).encode())
    return h.hexdigest()


def harness_header(arms: Sequence[str], bundle_info: Optional[Mapping[str, Any]] = None,
                   weights: Optional[Mapping[str, float]] = None, allow_standin: bool = False,
                   gait_quality: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """``gait_quality``: {"model": <gait-quality-1 response without windows>, "gait_prior": π, "config": {...}}
    (ELDERNET.md "Replay record format")."""
    for a in arms:
        if a not in HARNESS_ARMS:
            raise ValueError(f"unknown harness arm {a!r}")
    h: Dict[str, Any] = {"format": HARNESS_FORMAT, "arms": list(arms)}
    if bundle_info is not None:
        h["motion_heads"] = {"bundle": dict(bundle_info), "config": dict(weights or {}),
                             "allow_standin_evidence_for_testing": bool(allow_standin)}
    if gait_quality is not None:
        h["gait_quality"] = {k: (dict(v) if isinstance(v, Mapping) else v) for k, v in gait_quality.items()}
    return h


def write_harness_file(path: str, recs: Sequence[Recording], arms: Sequence[str],
                       heads: Optional[Mapping[str, HeadsWindows]] = None,
                       bundle_info: Optional[Mapping[str, Any]] = None,
                       weights: Optional[Mapping[str, float]] = None, allow_standin: bool = False,
                       include_encoder: bool = True, encoder_version: str = "hart-wisdm-v0",
                       gait: Optional[Mapping[str, GaitWindows]] = None,
                       gait_quality: Optional[Mapping[str, Any]] = None) -> Dict[str, Any]:
    """Write one `nara-activity-replay-1` file (header + per-second lines, atomic rename). ``gait`` /
    ``gait_quality``: ElderNet windows per recording and the header block (both optional)."""
    header = harness_header(arms, bundle_info, weights, allow_standin, gait_quality)
    tmp = path + ".tmp"
    total = AttachReport()
    gait_total = AttachReport()
    n_lines = 0
    digests: Dict[str, str] = {}
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(header, separators=(",", ":"), allow_nan=False) + "\n")
        for r in recs:
            lines, rep = observation_lines(r, (heads or {}).get(r.recording_id), include_encoder,
                                           encoder_version=encoder_version, gait=(gait or {}).get(r.recording_id))
            total.add(rep)
            gait_total.add(rep.gait)  # type: ignore[attr-defined]
            for ln in lines:
                f.write(json.dumps(ln, separators=(",", ":"), allow_nan=False) + "\n")
            n_lines += len(lines)
            digests[r.recording_id] = shared_inputs_digest(lines)
    os.replace(tmp, path)
    return {"path": path, "lines": n_lines, "sequences": len(recs), "arms": list(arms),
            "include_encoder": include_encoder, "attach": dict(total.__dict__), "shared_input_sha256": digests,
            **({"gait_attach": dict(gait_total.__dict__)} if gait is not None else {})}


def run_harness(in_path: str, out_path: str, package_dir: Optional[str] = None,
                test_filter: str = "ActivityReplayTests/testReplayFromEnvironment",
                timeout_s: int = 7200) -> Dict[str, Any]:
    """`swift test --filter ...` with ACTIVITY_REPLAY_IN / ACTIVITY_REPLAY_OUT; returns timing + log tail."""
    import subprocess
    import time
    from .subproc import failure_lines, safe_env
    package_dir = package_dir or rd.STRAND_PACKAGE_DIR
    env = safe_env({"ACTIVITY_REPLAY_IN": in_path, "ACTIVITY_REPLAY_OUT": out_path})
    t = time.time()
    p = subprocess.run(["swift", "test", "--filter", test_filter], cwd=package_dir, env=env,
                       capture_output=True, text=True, timeout=timeout_s)
    tail = failure_lines(p.stdout + p.stderr)       # never log raw output (it may echo the environment)
    if p.returncode != 0 or not os.path.isfile(out_path):
        raise RuntimeError(f"swift replay failed (rc={p.returncode}): {tail}")
    return {"returncode": p.returncode, "seconds": round(time.time() - t, 1), "tail": tail[-800:]}



# ---------------------------------------------------------------------------
# Neutral cache I/O (npz, one file per dataset/split)
# ---------------------------------------------------------------------------

def save_recordings(recs: Sequence[Recording], path: str) -> None:
    arrays: Dict[str, Any] = {}
    index = []
    for i, r in enumerate(recs):
        p = f"r{i}_"
        arrays[p + "sec"] = r.sec
        arrays[p + "gravity"] = r.gravity
        arrays[p + "dyn"] = r.dyn
        arrays[p + "imu_s"] = r.imu_s
        arrays[p + "imu_e"] = r.imu_e
        arrays[p + "imu_feat"] = r.imu_feat
        arrays[p + "hart_s"] = r.hart_s
        arrays[p + "hart_e"] = r.hart_e
        arrays[p + "hart_probs"] = r.hart_probs
        arrays[p + "hart_label"] = r.hart_label
        if r.truth_label is not None:
            arrays[p + "truth_label"] = r.truth_label
        for h in rd.TRUTH_HEADS:
            if h in r.truth_strict:
                arrays[p + "ts_" + h] = r.truth_strict[h]
            if h in r.truth_lenient:
                arrays[p + "tl_" + h] = r.truth_lenient[h]
        index.append({"recording_id": r.recording_id, "dataset": r.dataset, "subject": r.subject,
                      "split": r.split, "t0": r.t0, "labels": list(r.labels), "meta": r.meta})
    arrays["index_json"] = np.asarray(json.dumps(index))
    tmp = path + ".tmp.npz"
    np.savez_compressed(tmp, **arrays)
    os.replace(tmp, path)


def load_recordings(path: str) -> List[Recording]:
    z = np.load(path, allow_pickle=False)
    index = json.loads(str(z["index_json"]))
    out: List[Recording] = []
    for i, m in enumerate(index):
        p = f"r{i}_"
        out.append(Recording(
            recording_id=m["recording_id"], dataset=m["dataset"], subject=m["subject"], split=m["split"],
            t0=int(m["t0"]), sec=z[p + "sec"], gravity=z[p + "gravity"], dyn=z[p + "dyn"],
            truth_strict={h: z[p + "ts_" + h] for h in rd.TRUTH_HEADS if p + "ts_" + h in z},
            truth_lenient={h: z[p + "tl_" + h] for h in rd.TRUTH_HEADS if p + "tl_" + h in z},
            truth_label=z[p + "truth_label"] if p + "truth_label" in z else None, labels=tuple(m["labels"]),
            imu_s=z[p + "imu_s"], imu_e=z[p + "imu_e"], imu_feat=z[p + "imu_feat"],
            hart_s=z[p + "hart_s"], hart_e=z[p + "hart_e"], hart_probs=z[p + "hart_probs"],
            hart_label=z[p + "hart_label"], meta=m["meta"]))
    return out
