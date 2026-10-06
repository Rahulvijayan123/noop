"""activity-train — WISDM-19 watch adaptation pipeline.

Builds the training/eval contract exactly as spec s7 requires:

  * WISDM-19 WATCH streams only (subjects 1600..1650), loaded by
    activity_context.wisdm (wisdm-watch-loader-2): per (subject, activity)
    stream sorted by timestamp, each sensor's own native rate detected per
    constant-rate segment and resampled from its MEASURED rate to 30 Hz with
    the repo polyphase design, accel/gyro aligned on one 30 Hz time base by
    timestamp, nothing zero-filled (windows lacking either stream are never
    built; recordings without gyro are excluded and reported). The v0 loader
    searchsorted-ed into the unsorted per-subject gyro array and zero-filled
    the misses (82 % of v0 train windows had all-zero gyro), and resampled
    every block 3/2 although subjects 1637-1640 are ~50 Hz accel / ~25 Hz gyro.
  * Subject/session split BEFORE windowing (test subjects held out; train
    subjects' sessions split train/val) — upstream's random_split-over-
    windows is explicitly NOT used (hart-repro s9.2).
  * Units converted to the canonical training contract: accel m/s^2 -> g
    (/9.80665), gyro rad/s -> deg/s (x180/pi) — recorded in the manifest so
    inference needs no unit conversion (C10).
  * Windows 120 @ 30 Hz, hop 60 (2 s), per aligned piece, exactly as serve.py
    windows a run (2 s grid anchored at the piece start, 1 s FIR-transient
    margin at both ends); label = the piece's WISDM letter; C10 label mapping
    letter -> ontology.
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
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .manifest import (SCHEMA_VERSION, WISDM_LABEL_MAPPING, Manifest,
                       ManifestError, scaler_sha256)
from .preprocess import (CHANNEL_ORDER, COLUMNS_PER_SECOND, HOP_SAMPLES,
                         N_CHANNELS, TARGET_HZ, WINDOW_SAMPLES)
from . import PREPROCESSING_VERSION
from . import wisdm as wisdm_loader
from .wisdm import M_S2_TO_G, RAD_S_TO_DEG_S, MARGIN_SAMPLES

SESSION_GAP_NS = 1_000_000_000     # >1 s gap splits a recording (wisdm.RECORDING_GAP_S)
SYNTH_HZ = 20                      # synthetic smoke data rate (the real loader detects rates)
PRETRAINED_SHA256 = "88b8d1790a43cb5c96c5bba5da60c81ae08657024f9747cbe52d45c2acfd2e6d"


@dataclass
class Block:
    """One aligned, contiguous 6-channel 30 Hz piece of a WISDM recording."""
    subject: int
    activity: str
    samples: np.ndarray            # (T, 6) float64, 30 Hz, canonical units (g, deg/s)
    duration_s: float
    session: str = ""              # recording key "subject-activity-recording" (pieces share it)
    t0_ns: int = 0
    meta: Dict[str, Any] = field(default_factory=dict)


def _piece_to_block(p: "wisdm_loader.Piece") -> Block:
    return Block(subject=p.subject, activity=p.activity, samples=p.samples,
                 duration_s=p.duration_s,
                 session=f"{p.subject}-{p.activity}-{p.recording}", t0_ns=p.t0_ns,
                 meta={"acc_rate_hz": round(p.acc_rate_hz, 4), "acc_nominal_hz": p.acc_nominal_hz,
                       "acc_ratio": list(p.acc_ratio), "gyr_nominal_hz": p.gyr_nominal_hz,
                       "gyr_ratio": list(p.gyr_ratio), "offset_ms": round(p.offset_s * 1e3, 3),
                       "time_error_ms": round(p.time_error_s * 1e3, 3),
                       "wander_ms": round(p.wander_s * 1e3, 3), "n_repaired": p.n_repaired})


def window_block(block: Block, window: int = WINDOW_SAMPLES, hop: int = HOP_SAMPLES,
                 margin: int = MARGIN_SAMPLES) -> List[Tuple[np.ndarray, str, int, int]]:
    """(data (window,6), activity letter, subject, start index) windows, serve.py semantics."""
    s = block.samples
    return [(np.ascontiguousarray(s[k:k + window]), block.activity, block.subject, k)
            for k in wisdm_loader.window_starts(len(s), window, hop, margin)]


def _load_subject(args: Tuple[str, int]) -> Tuple[List[Block], Dict[str, Any]]:
    wisdm_dir, subj = args
    sd = wisdm_loader.load_subject(wisdm_dir, subj)
    return [_piece_to_block(p) for p in sd.pieces], sd.report()


def load_all_blocks(wisdm_dir: str, subjects: Sequence[int], jobs: int = 1,
                    report: Optional[Dict[str, Any]] = None) -> List[Block]:
    """Aligned 30 Hz pieces of every subject with both watch files (wisdm-watch-loader-2).

    ``report`` (when given) receives the per-subject loader reports: duplicates, conflicting rows,
    repaired single dropouts, segment breaks, slips, and every recording excluded for lack of gyro.
    """
    subs = wisdm_loader.available_subjects(wisdm_dir, subjects)
    work = [(wisdm_dir, s) for s in subs]
    if jobs > 1 and len(work) > 1:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(_load_subject, work))
    else:
        results = [_load_subject(w) for w in work]
    blocks: List[Block] = []
    per_subject = []
    for bl, rep in results:
        blocks.extend(bl)
        per_subject.append(rep)
    if report is not None:
        report.update(summarize_loader_reports(per_subject))
        report["subjects"] = per_subject
    return blocks


def summarize_loader_reports(per_subject: Sequence[Dict[str, Any]]) -> Dict[str, Any]:
    """Totals over the per-subject loader reports (what was dropped, repaired, excluded)."""
    tot: Dict[str, Any] = {"loader": wisdm_loader.LOADER_VERSION, "n_subjects": len(per_subject)}
    for sensor in ("accel", "gyro", "alignment"):
        agg: Dict[str, int] = {}
        for r in per_subject:
            for k, v in r[sensor].items():
                agg[k] = agg.get(k, 0) + int(v)
        tot[sensor] = agg
    recs = [rec for r in per_subject for rec in r["recordings"]]
    tot["n_recordings"] = len(recs)
    tot["n_recordings_with_windows"] = sum(1 for rec in recs if rec["n_windows"] > 0)
    tot["excluded_no_gyro"] = [f"{rec['subject']}-{rec['activity']}-{rec['recording']}"
                               for rec in recs if rec["reason"] == "no_gyro"]
    tot["excluded_no_overlap"] = [f"{rec['subject']}-{rec['activity']}-{rec['recording']}"
                                  for rec in recs if rec["reason"] == "no_overlap"]
    tot["n_windows"] = int(sum(r["n_windows"] for r in per_subject))
    tot["n_unparsed_rows"] = int(sum(r["n_unparsed_rows"] for r in per_subject))
    tot["n_wrong_subject_rows"] = int(sum(r["n_wrong_subject_rows"] for r in per_subject))
    tot["max_abs_offset_ms"] = max([r["max_abs_offset_ms"] for r in per_subject], default=0.0)
    tot["max_time_error_ms"] = max([r["max_time_error_ms"] for r in per_subject], default=0.0)
    tot["max_wander_ms"] = max([r["max_wander_ms"] for r in per_subject], default=0.0)
    rates: Dict[str, int] = {}
    for rec in recs:
        key = f"acc{rec['acc_nominal_hz']}/gyr{rec['gyr_nominal_hz']}"
        rates[key] = rates.get(key, 0) + 1
    tot["recordings_by_nominal_rates"] = rates
    return tot


def split_blocks(blocks: List[Block], test_fraction: float, val_fraction: float,
                 seed: int, subjects: Optional[Sequence[int]] = None,
                 ) -> Tuple[List[Block], List[Block], List[Block], Dict[str, Any]]:
    """SUBJECT-HELD-OUT 3-way split BEFORE windowing (spec s7, C10).

    Subjects are shuffled with a fixed seed and partitioned into disjoint
    train (~70%) / val (~15%) / test (~15%) groups; every session (block) of a
    subject goes entirely to that subject's split, so sessions never straddle
    splits and the early-stop val set is subject-held-out (not a window-level
    random_split like upstream's validation). Returns the three block lists
    plus a split-manifest dict for the model manifest.

    ``subjects`` is the split universe (default: the subjects present in
    ``blocks``). main() passes every subject with both watch files, so the
    split does not depend on which recordings survive loading (v0's 51
    subjects -> train 35 / val 8 / test 8 at seed 42).
    """
    rng = np.random.default_rng(seed)
    subjects = sorted({int(s) for s in subjects} if subjects is not None
                      else {b.subject for b in blocks})
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
            "train": len({(b.subject, b.session) for b in train_blocks}),
            "val": len({(b.subject, b.session) for b in val_blocks}),
            "test": len({(b.subject, b.session) for b in test_blocks}),
        },
        "pieces": {
            "train": len(train_blocks),
            "val": len(val_blocks),
            "test": len(test_blocks),
        },
    }
    return train_blocks, val_blocks, test_blocks, split


SPLIT_KEYS = ("seed", "train_subjects", "val_subjects", "test_subjects")


def assert_same_split(split: Dict[str, Any], expected_path: str) -> None:
    """Refuse to continue unless the subject split equals a saved split_manifest.json."""
    with open(expected_path, "r", encoding="utf-8") as f:
        exp = json.load(f)
    for k in SPLIT_KEYS:
        if split.get(k) != exp.get(k):
            raise SystemExit(f"split mismatch on {k}: {split.get(k)} != {exp.get(k)} "
                             f"(expected {expected_path})")


def windows_from_blocks(blocks: Sequence[Block], window: int, hop: int,
                        ) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Stack windowed data; label = the piece's letter. ``sessions`` = piece index
    (each piece is one contiguous run; evaluate.py resets its policy on a change)."""
    xs: List[np.ndarray] = []
    ys: List[str] = []
    subs: List[int] = []
    sess: List[int] = []
    for s_idx, b in enumerate(blocks):
        for data, letter, subj, _ in window_block(b, window, hop):
            xs.append(data)
            ys.append(letter)
            subs.append(subj)
            sess.append(s_idx)
    if not xs:
        raise ValueError("no windows produced (check input data)")
    return (np.stack(xs).astype(np.float32),
            np.asarray(ys), np.asarray(subs, dtype=np.int64),
            np.asarray(sess, dtype=np.int64))


def fit_scaler(x_train: np.ndarray) -> Tuple[List[float], List[float]]:
    mean = x_train.reshape(-1, N_CHANNELS).mean(axis=0)
    scale = x_train.reshape(-1, N_CHANNELS).std(axis=0)
    scale = np.where(scale < 1e-12, 1.0, scale)
    return mean.tolist(), scale.tolist()


# ---------------------------------------------------------------------------
# Synthetic smoke dataset (tiny, deterministic, WISDM file format)
# ---------------------------------------------------------------------------

def _synth_seconds(activity: str, fs: int, seconds: float, seed: int) -> np.ndarray:
    """(N, 6) canonical-unit samples at ``fs`` Hz for one activity."""
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
            s = _synth_seconds(act, SYNTH_HZ, dur, seed * 1000 + subj)
            step_ns = 50_000_000
            for i in range(s.shape[0]):
                t = ts + i * step_ns
                a = s[i, 0:3] * M_S2_TO_G          # m/s^2
                g = s[i, 3:6] * RAD_S_TO_DEG_S     # rad/s
                acc_lines.append(f"{subj},{act},{t},{a[0]:.6f},{a[1]:.6f},{a[2]:.6f};")
                gyr_lines.append(f"{subj},{act},{t},{g[0]:.6f},{g[1]:.6f},{g[2]:.6f};")
            ts += int(dur * 1e9) + 2_000_000_000   # >1 s gap between blocks
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

    Deterministic on CPU: torch is seeded BEFORE the checkpoint load, so the
    newly initialized classification head is reproducible (v0 seeded only
    after from_pretrained had already drawn the head weights), and the batch
    order comes from numpy default_rng(seed).
    """
    import time

    from .model import _import_torch, apply_freeze_policy, _load_model_and_verify

    _torch = _import_torch()
    _torch.manual_seed(seed)
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

    history = {"train_loss": [], "val_loss": [], "val_macro_f1": [], "epoch_seconds": [],
               "best_epoch": None, "best_val_macro_f1": None,
               "stopped_epoch": None, "threads": int(torch.get_num_threads())}
    best_state = None
    best_f1 = -1.0
    best_ep = 0
    stall = 0
    for ep in range(epochs):
        t_ep = time.time()
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
        history["epoch_seconds"].append(round(time.time() - t_ep, 1))
        print(f"  epoch {ep + 1}/{epochs}: train_loss={tl:.4f} "
              f"val_loss={vl:.4f} val_macro_f1={f1:.4f} "
              f"({history['epoch_seconds'][-1]:.0f} s)", flush=True)
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
    m.deps = {"numpy": "2.2.6", "torch": "2.8.0", "transformers": "4.56.0",
              "granite-tsfm": "0.3.3"}
    if checkpoint_info:
        m.checkpoint = checkpoint_info
    if split is not None:
        m.split = split
    if data is not None:
        m.data = data
    return m


def zero_gyro_fraction(x: np.ndarray) -> float:
    """Fraction of windows whose gyro channels are all exactly zero (v0's zero-fill signature)."""
    if len(x) == 0:
        return 0.0
    return float(np.mean(np.all(x[:, :, 3:6] == 0.0, axis=(1, 2))))


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
    ap.add_argument("--patience", type=int, default=2,
                    help="early-stop patience on val macro-F1 (v0 used 2)")
    ap.add_argument("--model-version", default=None,
                    help="manifest model_version (default hart-wisdm-v1 / hart-wisdm-smoke-v1)")
    ap.add_argument("--expect-split", default=None,
                    help="split_manifest.json the subject split must equal (refuse otherwise)")
    ap.add_argument("--jobs", type=int, default=1, help="loader processes (subjects in parallel)")
    args = ap.parse_args(argv)

    os.makedirs(args.out, exist_ok=True)
    if args.smoke:
        wisdm_dir = write_synthetic_wisdm(args.out, args.seed)
    elif args.wisdm:
        wisdm_dir = args.wisdm
    else:
        ap.error("need --smoke or --wisdm <dir>")
    model_version = args.model_version or ("hart-wisdm-smoke-v1" if args.smoke else "hart-wisdm-v1")

    subjects = wisdm_loader.available_subjects(wisdm_dir, list(range(1600, 1651)))
    loader_report: Dict[str, Any] = {}
    blocks = load_all_blocks(wisdm_dir, subjects, jobs=args.jobs, report=loader_report)
    if not blocks:
        raise SystemExit("no WISDM watch blocks found (check --wisdm layout)")

    train_b, val_b, test_b, split = split_blocks(blocks, args.test_fraction,
                                                 args.val_fraction, args.seed,
                                                 subjects=subjects)
    if args.expect_split:
        assert_same_split(split, args.expect_split)
    x_train, y_train, _, _ = windows_from_blocks(train_b, WINDOW_SAMPLES, HOP_SAMPLES)
    x_val, y_val, subj_val, sess_val = windows_from_blocks(val_b, WINDOW_SAMPLES, HOP_SAMPLES)
    x_test, y_test, subj_test, sess_test = windows_from_blocks(
        test_b, WINDOW_SAMPLES, HOP_SAMPLES)
    zero_gyro = {"train": zero_gyro_fraction(x_train), "val": zero_gyro_fraction(x_val),
                 "test": zero_gyro_fraction(x_test)}
    if any(v > 0 for v in zero_gyro.values()):
        raise SystemExit(f"windows with all-zero gyro found {zero_gyro}: the loader must never fill")

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
                               "sha256": PRETRAINED_SHA256,
                               "size": 856744}}}
    trained = False
    train_history = None

    window_counts = {"train": int(len(x_train)), "val": int(len(x_val)), "test": int(len(x_test))}
    preprocessing = {
        "loader": wisdm_loader.LOADER_VERSION,
        "streams": "per (subject, activity) sensor stream sorted by timestamp; exact duplicate rows "
                   "collapsed, conflicting duplicates dropped; recordings split at gaps > 1 s",
        "rate": "constant-rate segments per stream (rolling-median nominal 20/25/50/100 Hz; breaks at "
                "rate changes and at intervals < 0.5 or > 2.5 periods; one missing sample repaired by "
                "linear interpolation of its neighbours); least-squares clock fit per segment",
        "resample": "repo polyphase design (Kaiser beta=5, 20*max(up,down)+1 taps) from the MEASURED "
                    "accel rate: up/down = simplest fraction of 30/rate with <= 2 ms accumulated "
                    "time error over the piece; gyro ratio = accel ratio * (accel/gyro nominal ratio) "
                    "on the shared clock",
        "align": "gyro located on the accel sample index via timestamps; pieces split at sustained "
                 "(>= 2 s) one-sample slips; common start within 10 ms; both streams on one 30 Hz "
                 "time base (output m of both at t0 + m/30 s)",
        "fill": "none: time covered by only one stream yields no samples; recordings without gyro "
                "are excluded (data_report.json)",
        "windows": "serve.py semantics: 120 @ 30 Hz, hop 60, grid anchored at the piece start, "
                   "1 s FIR-transient margin at both ends",
        "units": "accel m/s^2 -> g (/9.80665), gyro rad/s -> deg/s (x180/pi), before resampling",
        "scaler": "StandardScaler mean/std over every sample of the TRAIN-subject windows only",
        "windows_per_split": window_counts,
        "zero_gyro_window_fraction": zero_gyro,
        "excluded_recordings_no_gyro": loader_report.get("excluded_no_gyro", []),
    }

    # Training-data identifiers (spec s7 manifest; WISDM-19 = UCI 507, CC BY 4.0).
    if args.smoke:
        data_info = {"name": "synthetic WISDM-format CI smoke (deterministic)",
                     "license": "generated in-test", "source": "activity_context.train.write_synthetic_wisdm",
                     "subjects": len(split["train_subjects"]) + len(split["val_subjects"]) + len(split["test_subjects"]),
                     "archive_sha256": None, "preprocessing": preprocessing}
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
            "sample_rate": {"source_hz": "detected per segment (20/25/50/100 nominal; measured rate used)",
                            "target_hz": TARGET_HZ,
                            "resample": "anti-alias polyphase from the measured rate (rational up/down)"},
            "window": {"samples": WINDOW_SAMPLES, "hop": HOP_SAMPLES, "seconds": WINDOW_SAMPLES / TARGET_HZ},
            "label_mapping": WISDM_LABEL_MAPPING,
            "preprocessing": preprocessing,
        }

    if args.train and args.checkpoint and os.path.isdir(args.checkpoint):
        from .model import torch_available
        if not torch_available():
            raise SystemExit("--train requires torch; install the [model] extra")
        # Scaler/class-map manifest used only to drive the training loop.
        train_history = train_head(
            args.checkpoint, args.out,
            build_manifest(model_version, class_map, mean, scale, args.seed, True,
                           checkpoint_info, split=split, data=data_info),
            x_train, y_train_ids, x_val, y_val_ids,
            args.epochs, args.batch_size, args.lr, args.seed, patience=args.patience)
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
        checkpoint_info["finetuned_from_sha256"] = PRETRAINED_SHA256
        data_info["training"] = {k: train_history[k] for k in
                                 ("epochs", "batch_size", "lr", "patience", "param_counts")}
        data_info["training"]["history"] = train_history["history"]

    manifest = build_manifest(
        model_version, class_map, mean, scale, args.seed, trained, checkpoint_info,
        split=split, data=data_info)
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest.to_dict(), f, indent=2, sort_keys=True)
        f.write("\n")
    with open(os.path.join(args.out, "split_manifest.json"), "w",
              encoding="utf-8") as f:
        json.dump(split, f, indent=2, sort_keys=True)
        f.write("\n")
    with open(os.path.join(args.out, "data_report.json"), "w", encoding="utf-8") as f:
        json.dump(loader_report, f, indent=1, sort_keys=True)
        f.write("\n")

    np.savez_compressed(os.path.join(args.out, "train_data.npz"),
                        X=x_train, y=y_train_ids,
                        letters=np.asarray(letters))
    y_val_onto = np.asarray([WISDM_LABEL_MAPPING.get(c, "other_movement") for c in y_val])
    np.savez_compressed(os.path.join(args.out, "val_data.npz"),
                        X=x_val, y=y_val_ids, letters=np.asarray(letters),
                        y_ontology=y_val_onto, window_letters=y_val,
                        subjects=subj_val, sessions=sess_val)
    y_test_onto = np.asarray([WISDM_LABEL_MAPPING.get(c, "other_movement")
                              for c in y_test])
    y_test_ids = np.asarray([letter_to_id.get(c, -1) for c in y_test],
                            dtype=np.int64)
    np.savez_compressed(os.path.join(args.out, "eval_data.npz"),
                        X=x_test, y_ontology=y_test_onto, letters=y_test,
                        subjects=subj_test, sessions=sess_test, y=y_test_ids)

    print(json.dumps({
        "ok": True,
        "smoke": args.smoke,
        "trained": trained,
        "model_version": model_version,
        "train_history": train_history,
        "pieces": len(blocks),
        "windows": window_counts,
        "zero_gyro_window_fraction": zero_gyro,
        "excluded_recordings_no_gyro": loader_report.get("excluded_no_gyro", []),
        "class_map": class_map,
        "scaler_sha256": manifest.scaler.get("sha256"),
        "split": {k: split[k] for k in ("train_subjects", "val_subjects", "test_subjects")},
        "out": args.out,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
