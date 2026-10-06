"""activity-train — WISDM-19 watch adaptation pipeline.

Builds the training/eval contract exactly as spec s7 requires:

  * WISDM-19 WATCH streams only (subjects 1600..1650; accel+gyro merged by
    timestamp within 100 ms; 20 Hz -> 30 Hz via anti-alias polyphase 3/2).
  * Subject/session split BEFORE windowing (test subjects held out; train
    subjects' sessions split train/val) — upstream's random_split-over-
    windows is explicitly NOT used (hart-repro s9.2).
  * Units converted to the canonical training contract: accel m/s^2 -> g
    (/9.80665), gyro rad/s -> deg/s (x180/pi) — recorded in the manifest so
    inference needs no unit conversion (C10).
  * Windows 120 @ 30 Hz, hop 60 (2 s), per session; label = majority WISDM
    letter; C10 label mapping letter -> ontology.
  * StandardScaler fit on train windows ONLY; saved (mean/scale + sha256) in
    the manifest.
  * Optional --train finetunes the HART classification head with the frozen
    backbone + unfrozen time/fft encodings (upstream finetune.py:121-130)
    and saves model.safetensors + config.json to --out.

--smoke runs the whole pipeline on tiny synthetic WISDM-format data
(deterministic, seconds not minutes), so CI can exercise every stage without
the 310 MB archive. Real training (full archive) runs later in a separate
agent using this same entry point.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from .manifest import (SCHEMA_VERSION, WISDM_LABEL_MAPPING, Manifest,
                       ManifestError, scaler_sha256)
from .preprocess import (CHANNEL_ORDER, COLUMNS_PER_SECOND, HOP_SAMPLES,
                         N_CHANNELS, TARGET_HZ, WINDOW_SAMPLES,
                         resample_poly_nd)
from . import PREPROCESSING_VERSION

# Unit conversions (C10).
M_S2_TO_G = 1.0 / 9.80665
RAD_S_TO_DEG_S = 180.0 / math.pi

ASOF_MAX_DT_NS = 100_000_000       # 100 ms merge tolerance (WHAR asof)
SESSION_GAP_NS = 1_000_000_000     # >1 s gap splits a session
WISDM_HZ = 20


@dataclass
class Block:
    """One contiguous same-activity WISDM session block."""
    subject: int
    activity: str
    samples: np.ndarray            # (T, 6) float64, 20 Hz, canonical units
    duration_s: float
    start_ts_s: float              # real block start (unix seconds, ts_ns/1e9)


def parse_raw_file(path: str) -> np.ndarray:
    """Parse a WISDM raw file (subject,activity,ts_ns,x,y,z;) -> structured."""
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip().rstrip(";").strip()
            if not line:
                continue
            parts = line.split(",")
            if len(parts) != 6:
                continue
            try:
                subj = int(parts[0])
                ts = int(parts[2])
                xyz = [float(p) for p in parts[3:6]]
            except ValueError:
                continue
            rows.append((subj, parts[1], ts, xyz[0], xyz[1], xyz[2]))
    if not rows:
        raise ValueError(f"no parseable rows in {path}")
    return np.array(rows, dtype=object)


def blocks_for_subject(accel_path: str, gyro_path: str) -> List[Block]:
    """Merge accel+gyro rows asof (<=100 ms) and split into activity blocks."""
    acc = parse_raw_file(accel_path)
    gyr = parse_raw_file(gyro_path)
    # Group rows by contiguous (subject, activity) with ts gaps <= 1 s.
    blocks: List[Block] = []
    cur_activity = None
    cur_ts: List[int] = []
    cur_xyz: List[Tuple[float, float, float]] = []
    for row in acc:
        subj, act, ts = int(row[0]), str(row[1]), int(row[2])
        xyz = (float(row[3]), float(row[4]), float(row[5]))
        if cur_activity is not None and act == cur_activity and cur_ts \
                and ts - cur_ts[-1] <= SESSION_GAP_NS:
            cur_ts.append(ts)
            cur_xyz.append(xyz)
            continue
        if cur_activity is not None and cur_ts:
            blocks.append(_finish_block(subj, cur_activity, cur_ts, cur_xyz, gyr))
        cur_activity, cur_ts, cur_xyz = act, [ts], [xyz]
    if cur_activity is not None and cur_ts:
        blocks.append(_finish_block(subj, cur_activity, cur_ts, cur_xyz, gyr))
    return blocks


def _finish_block(subject: int, activity: str, ts_list: List[int],
                  xyz_list: List[Tuple[float, float, float]],
                  gyr: np.ndarray) -> Block:
    ts_arr = np.asarray(ts_list, dtype=np.int64)
    xyz_arr = np.asarray(xyz_list, dtype=np.float64)
    # gyro ts/xyz columns: index 2 = ts, 3..5 = xyz
    g_ts = np.asarray([int(r[2]) for r in gyr], dtype=np.int64)
    g_xyz = np.asarray([[float(r[3]), float(r[4]), float(r[5])] for r in gyr],
                       dtype=np.float64)
    idx = np.searchsorted(g_ts, ts_arr)
    idx = np.clip(idx, 0, len(g_ts) - 1)
    near = np.abs(g_ts[idx] - ts_arr) <= ASOF_MAX_DT_NS
    g_aligned = g_xyz[idx]
    g_aligned[~near] = 0.0  # unmatched gyro -> zero rotation (documented)
    samples = np.concatenate([xyz_arr * M_S2_TO_G, g_aligned * RAD_S_TO_DEG_S], axis=1)
    return Block(subject=subject, activity=activity, samples=samples,
                 duration_s=len(ts_arr) / WISDM_HZ,
                 start_ts_s=float(ts_list[0]) / 1e9)


def resample_block(block: Block) -> Block:
    """20 -> 30 Hz per block (anti-alias polyphase 3/2), keeping metadata."""
    out = resample_poly_nd(block.samples, 3, 2, axis=0)
    return Block(subject=block.subject, activity=block.activity, samples=out,
                 duration_s=len(out) / TARGET_HZ,
                 start_ts_s=block.start_ts_s)


def window_block(block: Block, window: int = WINDOW_SAMPLES,
                 hop: int = HOP_SAMPLES) -> List[Tuple[np.ndarray, str, int, int]]:
    """(data (window,6), activity letter, subject, session_idx) windows."""
    s = block.samples
    out = []
    k = 0
    while k + window <= len(s):
        out.append((np.ascontiguousarray(s[k:k + window]), block.activity,
                    block.subject, k))
        k += hop
    return out


def load_all_blocks(wisdm_dir: str, subjects: Sequence[int]) -> List[Block]:
    blocks: List[Block] = []
    for subj in subjects:
        ap = os.path.join(wisdm_dir, "raw", "watch", "accel",
                          f"data_{subj}_accel_watch.txt")
        gp = os.path.join(wisdm_dir, "raw", "watch", "gyro",
                          f"data_{subj}_gyro_watch.txt")
        if not (os.path.isfile(ap) and os.path.isfile(gp)):
            continue
        blocks.extend(blocks_for_subject(ap, gp))
    return blocks


def split_blocks(blocks: List[Block], test_fraction: float, val_fraction: float,
                 seed: int) -> Tuple[List[Block], List[Block], List[Block],
                                     Dict[str, Any]]:
    """SUBJECT-HELD-OUT 3-way split BEFORE windowing (spec s7, C10).

    Subjects are shuffled with a fixed seed and partitioned into disjoint
    train (~70%) / val (~15%) / test (~15%) groups; every session (block) of a
    subject goes entirely to that subject's split, so sessions never straddle
    splits and the early-stop val set is subject-held-out (not a window-level
    random_split like upstream's validation). Returns the three block lists
    plus a split-manifest dict for the model manifest.
    """
    rng = np.random.default_rng(seed)
    subjects = sorted({b.subject for b in blocks})
    rng.shuffle(subjects)
    n_test = max(1, int(round(len(subjects) * test_fraction)))
    n_val = max(1, int(round(len(subjects) * val_fraction)))
    # Keep at least one train subject when possible (tiny datasets).
    n_test = min(n_test, max(1, len(subjects) - 2))
    n_val = min(n_val, max(1, len(subjects) - n_test - 1))
    test_subjects = sorted(subjects[:n_test])
    val_subjects = sorted(subjects[n_test:n_test + n_val])
    train_subjects = sorted(subjects[n_test + n_val:])
    train_blocks = [b for b in blocks if b.subject in train_subjects]
    val_blocks = [b for b in blocks if b.subject in val_subjects]
    test_blocks = [b for b in blocks if b.subject in test_subjects]
    # Tiny-dataset fallbacks: never return an empty split when data exists.
    if not train_blocks and val_blocks:
        train_blocks.append(val_blocks.pop())
    if not train_blocks and test_blocks:
        train_blocks.append(test_blocks.pop())
    if not test_blocks and train_blocks:
        test_blocks.append(train_blocks.pop())
    if not val_blocks and train_blocks:
        val_blocks.append(train_blocks.pop())
    split = {
        "seed": seed,
        "test_fraction": test_fraction,
        "val_fraction": val_fraction,
        "n_subjects": len(subjects),
        "n_train_subjects": len(train_subjects),
        "n_val_subjects": len(val_subjects),
        "n_test_subjects": len(test_subjects),
        "train_subjects": train_subjects,
        "val_subjects": val_subjects,
        "test_subjects": test_subjects,
        "sessions": {
            "train": len(train_blocks),
            "val": len(val_blocks),
            "test": len(test_blocks),
        },
    }
    return train_blocks, val_blocks, test_blocks, split


def windows_from_blocks(blocks: Sequence[Block], window: int, hop: int,
                        ) -> Tuple[np.ndarray, np.ndarray, np.ndarray,
                                   np.ndarray, np.ndarray]:
    """Stack windowed data; label = majority letter per window.

    Returns (X, letters, subjects, session_ids, starts) where `starts` is the
    real per-window start time in unix seconds (block.start_ts_s + sample
    offset / sample rate) — persisted in the npz artifacts so the evaluator's
    session-aware transition metrics measure real latency, never fabricated
    i*HOP_SECONDS spacing (audit WS-07-F03)."""
    xs: List[np.ndarray] = []
    ys: List[str] = []
    subs: List[int] = []
    sess: List[int] = []
    starts: List[float] = []
    for s_idx, b in enumerate(blocks):
        # Sample rate of this block (30 Hz after resample, 20 Hz raw).
        rate = (len(b.samples) / b.duration_s) if b.duration_s > 0 else TARGET_HZ
        for data, letter, subj, k in window_block(b, window, hop):
            xs.append(data)
            ys.append(letter)
            subs.append(subj)
            sess.append(s_idx)
            starts.append(b.start_ts_s + k / rate)
    if not xs:
        raise ValueError("no windows produced (check input data)")
    return (np.stack(xs).astype(np.float32),
            np.asarray(ys), np.asarray(subs, dtype=np.int64),
            np.asarray(sess, dtype=np.int64),
            np.asarray(starts, dtype=np.float64))


def fit_scaler(x_train: np.ndarray) -> Tuple[List[float], List[float]]:
    mean = x_train.reshape(-1, N_CHANNELS).mean(axis=0)
    scale = x_train.reshape(-1, N_CHANNELS).std(axis=0)
    scale = np.where(scale < 1e-12, 1.0, scale)
    return mean.tolist(), scale.tolist()


# ---------------------------------------------------------------------------
# Synthetic smoke dataset (tiny, deterministic, WISDM file format)
# ---------------------------------------------------------------------------

def _synth_seconds(activity: str, fs: int, seconds: float, seed: int) -> np.ndarray:
    """(N, 6) 20 Hz canonical-unit samples for one activity."""
    rng = np.random.default_rng(seed)
    n = int(fs * seconds)
    t = np.arange(n) / fs
    if activity == "A":                       # walking: 1.8 Hz gait (impact at step rate)
        cad = 1.8
        ax = 0.10 * np.sin(2 * np.pi * cad * t) + 0.02 * rng.standard_normal(n)
        ay = 0.08 * np.sin(2 * np.pi * cad * t + 0.7) + 0.02 * rng.standard_normal(n)
        az = 1.0 + 0.10 * np.sin(2 * np.pi * cad * t) + 0.03 * np.sin(2 * np.pi * 2 * cad * t) \
             + 0.01 * rng.standard_normal(n)
        gx = 10.0 * np.sin(2 * np.pi * cad * t) + 0.5 * rng.standard_normal(n)
        gy = 8.0 * np.sin(2 * np.pi * cad * t + 0.5) + 0.5 * rng.standard_normal(n)
        gz = 2.0 * np.sin(2 * np.pi * cad * t) + 0.3 * rng.standard_normal(n)
    elif activity == "B":                     # jogging: 2.8 Hz
        cad = 2.8
        ax = 0.30 * np.sin(2 * np.pi * cad * t) + 0.05 * rng.standard_normal(n)
        ay = 0.25 * np.sin(2 * np.pi * cad * t + 0.7) + 0.05 * rng.standard_normal(n)
        az = 1.0 + 0.25 * np.sin(2 * np.pi * cad * t) + 0.05 * np.sin(2 * np.pi * 2 * cad * t) \
             + 0.03 * rng.standard_normal(n)
        gx = 30.0 * np.sin(2 * np.pi * cad * t) + 1.5 * rng.standard_normal(n)
        gy = 24.0 * np.sin(2 * np.pi * cad * t + 0.3) + 1.5 * rng.standard_normal(n)
        gz = 10.0 * np.sin(2 * np.pi * cad * t) + 1.0 * rng.standard_normal(n)
    else:                                     # D: sitting (near-zero motion)
        ax = 0.002 * rng.standard_normal(n)
        ay = 0.002 * rng.standard_normal(n)
        az = 1.0 + 0.002 * rng.standard_normal(n)
        gx = 0.05 * rng.standard_normal(n)
        gy = 0.05 * rng.standard_normal(n)
        gz = 0.05 * rng.standard_normal(n)
    xyz = np.stack([ax, ay, az], axis=1) * (1.0 / M_S2_TO_G)   # back to m/s^2
    gyro = np.stack([gx, gy, gz], axis=1) * (1.0 / RAD_S_TO_DEG_S)  # back to rad/s
    return np.concatenate([xyz, gyro], axis=1)


def write_synthetic_wisdm(out_dir: str, seed: int = 0) -> str:
    """Write a tiny WISDM-layout archive; returns the wisdm_dir path."""
    wisdm = os.path.join(out_dir, "wisdm_synthetic")
    acc_dir = os.path.join(wisdm, "raw", "watch", "accel")
    gyr_dir = os.path.join(wisdm, "raw", "watch", "gyro")
    os.makedirs(acc_dir, exist_ok=True)
    os.makedirs(gyr_dir, exist_ok=True)
    plan = {1600: [("A", 12.0), ("D", 10.0), ("B", 12.0)],
            1601: [("A", 10.0), ("D", 10.0), ("B", 10.0)],
            1602: [("A", 10.0), ("B", 10.0)]}
    ts_base = 1_000_000_000_000_000
    for subj, acts in plan.items():
        acc_lines, gyr_lines = [], []
        ts = ts_base + subj * 10**12
        for act, dur in acts:
            s = _synth_seconds(act, WISDM_HZ, dur, seed * 1000 + subj)
            step_ns = 50_000_000
            for i in range(s.shape[0]):
                t = ts + i * step_ns
                a = s[i, 0:3] * M_S2_TO_G          # m/s^2
                g = s[i, 3:6] * RAD_S_TO_DEG_S     # rad/s
                acc_lines.append(f"{subj},{act},{t},{a[0]:.6f},{a[1]:.6f},{a[2]:.6f};")
                gyr_lines.append(f"{subj},{act},{t},{g[0]:.6f},{g[1]:.6f},{g[2]:.6f};")
            # Advance the clock by the FULL block duration (n samples * 50 ms)
            # plus a >1 s pause, so successive blocks never overlap in real
            # time (the previous code advanced by only 5% of the duration,
            # making later blocks' first windows start BEFORE the earlier
            # block's last window — impossible timestamps that broke the
            # real-timestamps contract this pipeline now persists).
            ts += int(s.shape[0] * step_ns) + 2_000_000_000
        with open(os.path.join(acc_dir, f"data_{subj}_accel_watch.txt"), "w") as f:
            f.write("\n".join(acc_lines) + "\n")
        with open(os.path.join(gyr_dir, f"data_{subj}_gyro_watch.txt"), "w") as f:
            f.write("\n".join(gyr_lines) + "\n")
    return wisdm


# ---------------------------------------------------------------------------
# Training (optional, torch)
# ---------------------------------------------------------------------------

def _val_macro_f1(model, torch, x_val: np.ndarray, y_val_ids: np.ndarray,
                  manifest: Manifest, batch_size: int) -> float:
    """Ontology-space macro-F1 on the subject-held-out val set.

    Runs the model in eval mode (no masking) on the STANDARDIZED val windows
    (the scaler is applied once by train_head, so eval sees the same inputs as
    the deploy path), aggregates the WISDM-letter softmax into ontology
    probabilities via the manifest label_mapping, applies the manifest
    abstention thresholds, and returns macro-F1 over the four supported coarse
    classes (stationary/walking/running/other_movement). Abstained (unknown)
    windows count as errors, so the signal rewards both accuracy and coverage
    (spec s8: rejection of nearly all windows cannot satisfy a useful
    classifier).
    """
    from .model import abstain
    letters = list(manifest.class_map)
    mapping = manifest.label_mapping
    th = manifest.thresholds
    model.eval()
    preds: List[str] = []
    with torch.no_grad():
        for i in range(0, len(x_val), batch_size):
            xb = torch.from_numpy(np.ascontiguousarray(
                x_val[i:i + batch_size], dtype=np.float32))
            out = model(past_values=xb, return_loss=False)
            logits = getattr(out, "prediction_outputs", None)
            if logits is None:
                logits = getattr(out, "logits", None)
            probs = torch.softmax(torch.as_tensor(logits), dim=1).numpy()
            for row in probs:
                onto: Dict[str, float] = {}
                for cid, letter in enumerate(letters):
                    lab = mapping.get(letter, "other_movement")
                    onto[lab] = onto.get(lab, 0.0) + float(row[cid])
                preds.append(abstain(onto, float(th["max_prob"]),
                                     float(th["margin"])))
    y_onto = [mapping.get(letters[int(i)], "other_movement") for i in y_val_ids]
    classes = ("stationary", "walking", "running", "other_movement")
    f1s = []
    for c in classes:
        tp = sum(1 for t, p in zip(y_onto, preds) if t == c and p == c)
        fp = sum(1 for t, p in zip(y_onto, preds) if t != c and p == c)
        fn = sum(1 for t, p in zip(y_onto, preds) if t == c and p != c)
        p = tp / (tp + fp) if (tp + fp) else 0.0
        r = tp / (tp + fn) if (tp + fn) else 0.0
        f1s.append(2 * p * r / (p + r) if (p + r) else 0.0)
    return float(np.mean(f1s))


def train_head(checkpoint_dir: str, out_dir: str, manifest: Manifest,
               x_train: np.ndarray, y_ids: np.ndarray,
               x_val: np.ndarray, y_val_ids: np.ndarray,
               epochs: int, batch_size: int, lr: float, seed: int,
               patience: int = 2) -> Dict:
    """Finetune the classification head on windows (frozen backbone +
    trainable time/fft encodings; upstream finetune.py:121-130).

    Early-stops on the subject-held-out val macro-F1 (spec s7) and restores
    the best checkpoint before saving.
    """
    from .model import apply_freeze_policy, _load_model_and_verify

    model, torch = _load_model_and_verify(checkpoint_dir, len(manifest.class_map),
                                          manifest.seed, manifest=manifest)
    counts = apply_freeze_policy(model, torch)
    # Deploy parity: HARTModel.predict_window applies the manifest scaler
    # before the model, so training must see the SAME standardized inputs
    # (upstream finetune.py fits the scaler on train and applies it to both
    # train and test). Scaling here matches the inference path exactly.
    _mean = np.asarray(manifest.scaler["mean"], dtype=np.float64)
    _scale = np.asarray(manifest.scaler["scale"], dtype=np.float64)
    x_train = (x_train - _mean) / _scale
    x_val = (x_val - _mean) / _scale
    # Training is offline: use more than the single inference thread so the
    # bounded budget completes in reasonable wall time. Inference paths
    # (serve/infer) keep torch.set_num_threads(1) for determinism; this only
    # affects the offline training process.
    _train_threads = int(os.environ.get("ACTIVITY_TRAIN_THREADS", "4"))
    torch.set_num_threads(max(1, _train_threads))
    criterion = torch.nn.CrossEntropyLoss()
    trainable = [p for p in model.parameters() if p.requires_grad]
    optimizer = torch.optim.AdamW(trainable, lr=lr)
    rng = np.random.default_rng(seed)

    def _batches(x, y):
        idx = rng.permutation(len(x))
        for i in range(0, len(idx), batch_size):
            sel = idx[i:i + batch_size]
            yield torch.from_numpy(np.ascontiguousarray(
                x[sel], dtype=np.float32)), torch.from_numpy(
                np.asarray(y[sel], dtype=np.int64))

    def _logits(out):
        for attr in ("prediction_outputs", "logits"):
            if hasattr(out, attr) and getattr(out, attr) is not None:
                return getattr(out, attr)
        raise RuntimeError("model returned no logits")

    history = {"train_loss": [], "val_loss": [], "val_macro_f1": [],
               "best_epoch": None, "best_val_macro_f1": None,
               "stopped_epoch": None}
    best_state = None
    best_f1 = -1.0
    best_ep = 0
    stall = 0
    for ep in range(epochs):
        model.train()
        total, n = 0.0, 0
        for xb, yb in _batches(x_train, y_ids):
            optimizer.zero_grad()
            out = model(past_values=xb, target_values=yb)
            if getattr(out, "loss", None) is not None:
                loss = out.loss.mean()          # granite-tsfm returns (B,) loss
            else:
                loss = criterion(_logits(out), yb)
            loss.backward()
            optimizer.step()
            total += float(loss.detach())
            n += 1
        tl = total / max(1, n)
        nv = 0
        vl = 0.0
        model.eval()
        with torch.no_grad():
            for xb, yb in _batches(x_val, y_val_ids):
                out = model(past_values=xb, target_values=yb)
                vl += float(out.loss.mean())
                nv += 1
        vl /= max(1, nv)                        # val batch count (was train's)
        f1 = _val_macro_f1(model, torch, x_val, y_val_ids, manifest, batch_size)
        history["train_loss"].append(round(tl, 6))
        history["val_loss"].append(round(vl, 6))
        history["val_macro_f1"].append(round(f1, 4))
        print(f"  epoch {ep + 1}/{epochs}: train_loss={tl:.4f} "
              f"val_loss={vl:.4f} val_macro_f1={f1:.4f}", flush=True)
        if f1 > best_f1:
            best_f1 = f1
            best_ep = ep
            best_state = {k: v.detach().clone()
                          for k, v in model.state_dict().items()}
            stall = 0
        else:
            stall += 1
            if stall >= patience:
                history["stopped_epoch"] = ep + 1
                print(f"  early stop at epoch {ep + 1} "
                      f"(val macro-F1 stalled {patience} epochs)", flush=True)
                break

    if best_state is not None:
        model.load_state_dict(best_state)
    history["best_epoch"] = best_ep + 1
    history["best_val_macro_f1"] = round(best_f1, 4)
    model.eval()
    model.save_pretrained(out_dir)
    return {"history": history, "param_counts": counts,
            "epochs": best_ep + 1, "batch_size": batch_size, "lr": lr,
            "patience": patience}


def build_manifest(model_version: str, class_map: List[str], mean: List[float],
                   scale: List[float], seed: int, trained: bool,
                   checkpoint_info: Optional[Dict],
                   split: Optional[Dict] = None,
                   data: Optional[Dict] = None) -> Manifest:
    from .manifest import ONTOLOGY_MOTION_LABELS
    m = Manifest(model_version=model_version, model_kind="hart" if trained else "baseline")
    # Baseline manifests carry the ontology directly; HART manifests carry the
    # trained WISDM-letter head outputs (mapped via label_mapping).
    m.class_map = list(ONTOLOGY_MOTION_LABELS) if not trained else class_map
    m.scaler = {"mean": [float(v) for v in mean], "scale": [float(v) for v in scale],
                "sha256": scaler_sha256(mean, scale),
                "fit": "train-subjects-sessions-only"}
    m.units = {"input_accel": "g", "input_gyro": "deg/s",
               "train_accel": "g", "train_gyro": "deg/s"}
    m.seed = seed
    # Pinned resolved environment of the [model] extra (pyproject.toml): the
    # datasets 2.14.x / pyarrow 14 combo requires numpy<2 (audit WS-07-F09 /
    # WS-03-F02); granite-tsfm 0.3.3 ships the tsfm_public import path.
    m.deps = {"numpy": "1.26.4", "torch": "2.8.0", "transformers": "4.56.0",
              "granite-tsfm": "0.3.3", "datasets": "2.14.4",
              "pyarrow": "14.0.1"}
    if checkpoint_info:
        m.checkpoint = checkpoint_info
    if split is not None:
        m.split = split
    if data is not None:
        m.data = data
    return m


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Nara WISDM-19 watch adaptation pipeline")
    ap.add_argument("--wisdm", default=None, help="unpacked WISDM dir (raw/watch/...)")
    ap.add_argument("--out", required=True, help="output dir for manifest + data")
    ap.add_argument("--smoke", action="store_true", help="tiny synthetic dataset")
    ap.add_argument("--train", action="store_true", help="finetune the HART head")
    ap.add_argument("--checkpoint", default=None, help="HART checkpoint dir")
    ap.add_argument("--test-fraction", type=float, default=0.2)
    ap.add_argument("--val-fraction", type=float, default=0.1)
    ap.add_argument("--epochs", type=int, default=5)
    ap.add_argument("--batch-size", type=int, default=64)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args(argv)

    if args.smoke:
        wisdm_dir = write_synthetic_wisdm(args.out, args.seed)
    elif args.wisdm:
        wisdm_dir = args.wisdm
    else:
        ap.error("need --smoke or --wisdm <dir>")

    subjects = list(range(1600, 1651))
    blocks = load_all_blocks(wisdm_dir, subjects)
    if not blocks:
        raise SystemExit("no WISDM watch blocks found (check --wisdm layout)")

    blocks = [resample_block(b) for b in blocks]
    train_b, val_b, test_b, split = split_blocks(blocks, args.test_fraction,
                                                 args.val_fraction, args.seed)
    x_train, y_train, subj_train, sess_train, starts_train = windows_from_blocks(
        train_b, WINDOW_SAMPLES, HOP_SAMPLES)
    x_val, y_val, subj_val, sess_val, starts_val = windows_from_blocks(
        val_b, WINDOW_SAMPLES, HOP_SAMPLES)
    x_test, y_test, subj_test, sess_test, starts_test = windows_from_blocks(
        test_b, WINDOW_SAMPLES, HOP_SAMPLES)

    # Head classes = WISDM letters present in TRAIN+VAL only (a class the
    # model never sees must not be a trainable head output). Test-only letters
    # still contribute ground truth via the C10 label_mapping (rare; all 18
    # letters are almost always present across 43 train subjects).
    letters = sorted({str(c) for c in np.concatenate([y_train, y_val])})
    class_map = letters
    letter_to_id = {c: i for i, c in enumerate(letters)}
    test_only = sorted({str(c) for c in y_test} - set(letters))
    if test_only:
        print(f"  note: test-only WISDM letters (not trainable): {test_only}",
              file=sys.stderr)

    mean, scale = fit_scaler(x_train)
    y_train_ids = np.asarray([letter_to_id[c] for c in y_train], dtype=np.int64)
    y_val_ids = np.asarray([letter_to_id[c] for c in y_val], dtype=np.int64)

    checkpoint_info = None
    if args.checkpoint and os.path.isdir(args.checkpoint):
        checkpoint_info = {"commit": "122b4a8b07758deedfcf3b1e87f03eed5ad55967",
                           "license": "MIT",
                           "files": {"model.safetensors": {
                               "url": ("https://github.com/EdgeIntelligenceLab/HART/raw/"
                                       "122b4a8b07758deedfcf3b1e87f03eed5ad55967/"
                                       "finetuning_HART/pretrained_checkpoint/model.safetensors"),
                               "sha256": ("88b8d1790a43cb5c96c5bba5da60c81ae08657024f9747"
                                          "cbe52d45c2acfd2e6d"),
                               "size": 856744}}}

        os.makedirs(args.out, exist_ok=True)
    trained = False
    train_history = None

    # Training-data identifiers (spec s7 manifest; WISDM-19 = UCI 507, CC BY 4.0).
    if args.smoke:
        data_info = {"name": "synthetic WISDM-format CI smoke (deterministic)",
                     "license": "generated in-test", "source": "activity_context.train.write_synthetic_wisdm",
                     "subjects": len(split["train_subjects"]) + len(split["val_subjects"]) + len(split["test_subjects"]),
                     "archive_sha256": None}
    else:
        data_info = {
            "name": "WISDM Smartphone and Smartwatch Activity and Biometrics Dataset (UCI 507, DOI 10.24432/C5HK59)",
            "license": "CC BY 4.0",
            "source": "https://archive.ics.uci.edu/static/public/507/wisdm+smartphone+and+smartwatch+activity+and+biometrics+dataset.zip",
            "archive_sha256": "6e0147f181d8f5275918db65eeb9dc842a0185d37cb6b2f30cbf74ee6e205469",
            "inner_zip_sha256": "1cf32e8d3a0ecc101bd299fba22545273dcb7de1c9565e0b7844abdfbc6b1695",
            "subjects": len(split["train_subjects"]) + len(split["val_subjects"]) + len(split["test_subjects"]),
            "watch_only": True,
            "sensors": ["accel m/s^2 -> g (/9.80665)", "gyro rad/s -> deg/s (x180/pi)"],
            "sample_rate": {"source_hz": 20, "target_hz": TARGET_HZ,
                            "resample": "anti-alias polyphase 3/2 (upsampling; bandwidth preserved)"},
            "window": {"samples": WINDOW_SAMPLES, "hop": HOP_SAMPLES, "seconds": WINDOW_SAMPLES / TARGET_HZ},
            "label_mapping": WISDM_LABEL_MAPPING,
        }

    if args.train and args.checkpoint and os.path.isdir(args.checkpoint):
        from .model import torch_available
        if not torch_available():
            raise SystemExit("--train requires torch; install the [model] extra")
        # Scaler/class-map manifest used only to drive the training loop.
        train_history = train_head(
            args.checkpoint, args.out,
            build_manifest("hart-wisdm-smoke-v0" if args.smoke else "hart-wisdm-v0",
                           class_map, mean, scale, args.seed, True, checkpoint_info,
                           split=split, data=data_info),
            x_train, y_train_ids, x_val, y_val_ids,
            args.epochs, args.batch_size, args.lr, args.seed)
        trained = True
        # The deployed artifact is the FINE-TUNED model: record its digest in
        # the manifest so serve's verify-on-load matches what it actually loads.
        from .manifest import file_sha256
        fine_path = os.path.join(args.out, "model.safetensors")
        fine_sha = file_sha256(fine_path)
        checkpoint_info["files"]["model.safetensors"]["sha256"] = fine_sha
        checkpoint_info["files"]["model.safetensors"]["size"] = os.path.getsize(fine_path)
        checkpoint_info["files"]["model.safetensors"]["url"] = (
            f"local:{fine_path} "
            f"(fine-tuned from {checkpoint_info['commit'][:12]})")

    manifest = build_manifest(
        "hart-wisdm-smoke-v0" if args.smoke else "hart-wisdm-v0",
        class_map, mean, scale, args.seed, trained, checkpoint_info,
        split=split, data=data_info)
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest.to_dict(), f, indent=2, sort_keys=True)
        f.write("\n")
    with open(os.path.join(args.out, "split_manifest.json"), "w",
              encoding="utf-8") as f:
        json.dump(split, f, indent=2, sort_keys=True)
        f.write("\n")

    # Real per-window timestamps (unix seconds) + session/block ids persisted so
    # evaluate.py can measure actual within-session transition latency and
    # honor session boundaries (audit WS-07-F01/F03, spec s12).
    np.savez_compressed(os.path.join(args.out, "train_data.npz"),
                        X=x_train, y=y_train_ids,
                        letters=np.asarray(letters),
                        subjects=subj_train, sessions=sess_train,
                        starts=starts_train)
    np.savez_compressed(os.path.join(args.out, "val_data.npz"),
                        X=x_val, y=y_val_ids,
                        letters=np.asarray(letters),
                        subjects=subj_val, sessions=sess_val,
                        starts=starts_val)
    y_test_onto = np.asarray([WISDM_LABEL_MAPPING.get(c, "other_movement")
                              for c in y_test])
    y_test_ids = np.asarray([letter_to_id.get(c, -1) for c in y_test],
                            dtype=np.int64)
    np.savez_compressed(os.path.join(args.out, "eval_data.npz"),
                        X=x_test, y_ontology=y_test_onto, letters=y_test,
                        subjects=subj_test, sessions=sess_test, y=y_test_ids,
                        starts=starts_test)

    print(json.dumps({
        "ok": True,
        "smoke": args.smoke,
        "trained": trained,
        "train_history": train_history,
        "blocks": len(blocks),
        "windows": {"train": len(x_train), "val": len(x_val), "test": len(x_test)},
        "class_map": class_map,
        "scaler_sha256": manifest.scaler.get("sha256"),
        "out": args.out,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
