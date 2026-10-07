"""activity-train-transition — train the learned transition expert (Model B / Model C head).

Participant-held-out by construction (spec s12): the split happens over SESSIONS grouped by
SUBJECT BEFORE any windowing, so no subject's windows ever straddle train/val/test — the same
discipline activity_context.train applies to WISDM. Datasets are mixed with placement recorded
(wrist-first: PAMAP2 hand + WISDM watch are wrist; HAPT is waist transfer data), and every
artifact records which dataset/placement contributed what, so the evaluation can report
performance per placement and the production decision can be made on wrist-tested numbers.

Model B (this CLI, --kind xgb|logistic): engineered transition-feat-1 features -> XGBoost
multi:softprob or multinomial logistic regression -> portable JSON artifact evaluated by
numpy alone at inference (the WristMET precedent; xgboost/sklearn are build-time only).

Model C (--kind hart): frozen HART backbone + a new 5-class transition head, reusing the
existing activity_context.model machinery (TSPulseForClassification, verify-on-load, freeze
policy, StandardScaler on train only) on the SAME canonical 30 Hz windows the general head
uses. The general 18-class head artifact is never touched; the transition head is a separate
artifact directory with its own manifest.

FORTH-TRACE is citation-licensed (no formal grant): it is NEVER loaded unless --forth is passed
explicitly, and its contribution is always recorded as research-only in the artifact provenance.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from typing import Dict, List, Optional, Tuple

import numpy as np

from .manifest import Manifest, ManifestError
from .preprocess import TARGET_HZ, WINDOW_SAMPLES, HOP_SAMPLES
from .transition_features import FEATURE_NAMES, window_transition_features
from .transition_model import (CLASSES, DEFAULT_THRESHOLDS, TransitionModel,
                               export_logistic, train_logistic, train_xgboost,
                               write_artifact, _xgb_trees_to_artifact)

DATA_ENV = "NARA_TRANSITION_DATA"


def _dataset_roots(args) -> List[Tuple[str, str]]:
    """(dataset, root) pairs from CLI paths or the NARA_TRANSITION_DATA env map."""
    pairs: List[Tuple[str, str]] = []
    if args.hapt:
        pairs.append(("hapt", args.hapt))
    if args.pamap2:
        pairs.append(("pamap2", args.pamap2))
    if args.wisdm:
        pairs.append(("wisdm", args.wisdm))
    if args.forth:
        pairs.append(("forth", args.forth))
    env = os.environ.get(DATA_ENV)
    if not any(pairs) and env:
        mapping = json.loads(env)
        for k in ("hapt", "pamap2", "wisdm", "forth"):
            if mapping.get(k):
                pairs.append((k, mapping[k]))
    return pairs


def load_sessions(pairs: List[Tuple[str, str]]):
    from .transition_data import TransitionSession
    sessions: List[TransitionSession] = []
    for dataset, root in pairs:
        from . import transition_data as td
        loader = {"hapt": td.load_hapt, "pamap2": td.load_pamap2,
                  "wisdm": td.load_wisdm, "forth": td.load_forth_trace}[dataset]
        sessions.extend(loader(root))
    return sessions


def split_subjects(sessions, test_fraction=0.2, val_fraction=0.15, seed=0):
    """Subject-held-out 3-way split BEFORE windowing (same discipline as train.split_blocks)."""
    rng = np.random.default_rng(seed)
    subjects = sorted({s.subject for s in sessions})
    rng.shuffle(subjects)
    n_test = max(1, int(round(len(subjects) * test_fraction)))
    n_val = max(1, int(round(len(subjects) * val_fraction)))
    n_test = min(n_test, max(1, len(subjects) - 2))
    n_val = min(n_val, max(1, len(subjects) - n_test - 1))
    test_subjects = set(sorted(subjects[:n_test]))
    val_subjects = set(sorted(subjects[n_test:n_test + n_val]))
    train_subjects = set(subjects[n_test + n_val:])
    split = {
        "seed": seed, "n_subjects": len(subjects),
        "train_subjects": sorted(train_subjects), "val_subjects": sorted(val_subjects),
        "test_subjects": sorted(test_subjects),
    }
    return train_subjects, val_subjects, test_subjects, split


def build_windows(sessions, subjects, model_kind: str, hop_s: float = 2.0):
    """Windows for one subject group; x = features (Model B) or 30 Hz tensors (Model C).

    Returns (x_list, y, meta) with one row per UNAMBIGUOUS window (positives + negatives;
    ambiguous windows are skipped, spec: never force a mixed window into a class).
    """
    from .transition_data import iter_windows
    xs: List[np.ndarray] = []
    ys: List[str] = []
    meta: List[Dict] = []
    for s in sessions:
        if s.subject not in subjects:
            continue
        for (start_ts, end_ts, data, label) in iter_windows(s, hop_s=hop_s):
            if label is None:
                continue
            if model_kind == "hart":
                from .transition_data import resample_window_to_30hz
                xs.append(resample_window_to_30hz(data, s.hz))
            else:
                xs.append(window_transition_features(data, s.hz))
            ys.append(label)
            meta.append({"dataset": s.dataset, "placement": s.placement,
                         "subject": s.subject, "session": s.session_id,
                         "start_ts": start_ts, "end_ts": end_ts})
    return xs, ys, meta


def _write_smoke_datasets(root: Optional[str] = None) -> str:
    """Tiny synthetic HAPT/PAMAP2/WISDM trees (CI smoke; no download, no real data).

    Two participants per dataset with one planted transition each — enough for the train CLI
    to exercise every loader, the split, and the artifact round trip end to end. The
    transition_data tests cover the exact label maps; this only needs to be loadable.
    """
    import tempfile
    root = root or tempfile.mkdtemp(prefix="nara-transition-smoke-")

    def _rng_wave(n, hz, seed, bursts=()):
        """Quiet wrist stream with rotation bursts: gravity steps 90 deg at each burst time
        (seconds). A burst is the physical content a transition label region marks."""
        rng = np.random.default_rng(seed)
        d = np.zeros((n, 6))
        d[:, 2] = 1.0
        axes = [(0, 2), (1, 0), (2, 1)]
        state = 0
        for t_burst in bursts:
            i0 = int(round(t_burst * hz))
            dur = max(4, int(round(0.8 * hz)))
            i1 = min(i0 + dur, n)
            if i1 - i0 < 4:
                break
            a_from, a_to = axes[state % 3]
            state += 1
            ang = np.linspace(0, np.pi / 2, i1 - i0)
            for k, a in enumerate(ang):
                d[i0 + k, 0:3] = 0.0
                d[i0 + k, a_from] = np.cos(a)
                d[i0 + k, a_to] = np.sin(a)
            d[i0:i1, 3:6] = rng.normal(0, 60, (i1 - i0, 3))
            if i1 < n:
                d[i1:, 0:3] = 0.0
                d[i1:, a_to] = 1.0
        d[:, 0:3] += rng.normal(0, 0.002, (n, 3))
        return d

    # HAPT: 50 Hz, 2 users; each user's session carries all four canonical classes
    # (7 stand_to_sit, 8 sit_to_stand, 9+11 lie_down, 10+12 get_up) so ANY subject
    # split still covers every class (the smoke must exercise the full 5-class head).
    hapt = os.path.join(root, "hapt", "RawData")
    os.makedirs(hapt, exist_ok=True)
    # 60 s sessions with six 0.8 s transitions spaced 8 s apart: every canonical class
    # appears, and the gaps leave real negative (none) windows (no event within +-3 s).
    n_hapt = 3000
    label_spans = [(1, 0, 380), (7, 400, 440), (8, 800, 840), (9, 1200, 1240),
                   (10, 1600, 1640), (11, 2000, 2040), (12, 2400, 2440), (5, 2600, 3000)]
    burst_times = tuple((a + b) / 2.0 / 50.0 for (_, a, b) in label_spans[1:-1])
    for user in (1, 2):
        d = _rng_wave(n_hapt, 50, user, bursts=burst_times)
        np.savetxt(os.path.join(hapt, f"acc_exp{user:02d}_user{user:02d}.txt"),
                   d[:, 0:3], fmt="%.6f")
        np.savetxt(os.path.join(hapt, f"gyro_exp{user:02d}_user{user:02d}.txt"),
                   d[:, 3:6], fmt="%.6f")
        with open(os.path.join(hapt, "labels.txt"), "a") as f:
            for label, a, b in label_spans:
                f.write(f"{user:02d} {user:02d} {label} {a} {b}\n")

    # PAMAP2: 100 Hz hand IMU, 2 subjects, lying -> sitting -> standing states.
    pamap = os.path.join(root, "pamap2", "Protocol")
    os.makedirs(pamap, exist_ok=True)
    for subj in (101, 102):
        d = _rng_wave(900, 100, subj, bursts=(3.0, 6.0))
        # col 4-6 hand accel m/s^2, 10-12 hand gyro rad/s; lying(1) then sitting(2) then standing(3)
        rows = []
        for i in range(d.shape[0]):
            t = i / 100.0
            act = 1 if t < 300 else (2 if t < 600 else 3)
            hand = np.concatenate([d[i, 0:3] * 9.80665, d[i, 3:6] / 57.29577951308232])
            rows.append([t, act, 100.0] + [0.0] * 3 + list(hand) + [0.0] * 35)
        with open(os.path.join(pamap, f"subject{subj}.dat"), "w") as f:
            for r in rows:
                f.write(" ".join(str(v) for v in r) + "\n")

    # WISDM: 20 Hz watch accel+gyro, 2 subjects, sitting (D) -> standing (E).
    wisdm_acc = os.path.join(root, "wisdm", "raw", "watch", "accel")
    wisdm_gyr = os.path.join(root, "wisdm", "raw", "watch", "gyro")
    os.makedirs(wisdm_acc, exist_ok=True)
    os.makedirs(wisdm_gyr, exist_ok=True)
    for subj in (1600, 1601):
        d = _rng_wave(600, 20, subj, bursts=(15.0,))
        # wisdm_raw.parse_raw_file expects: subject,activity,ts_ns,x,y,z; (trailing semicolon)
        with open(os.path.join(wisdm_acc, f"data_{subj}_accel_watch.txt"), "w") as f:
            for i in range(d.shape[0]):
                ts_ns = int(i * 1e9 / 20)  # 20 Hz
                act = "D" if i < 300 else "E"
                f.write(f"{subj},{act},{ts_ns},{d[i,0]},{d[i,1]},{d[i,2]};\n")
        with open(os.path.join(wisdm_gyr, f"data_{subj}_gyro_watch.txt"), "w") as f:
            for i in range(d.shape[0]):
                ts_ns = int(i * 1e9 / 20)
                act = "D" if i < 300 else "E"
                f.write(f"{subj},{act},{ts_ns},{d[i,3]},{d[i,4]},{d[i,5]};\n")
    return root


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="activity-train-transition",
                                 description=__doc__.splitlines()[0])
    p.add_argument("--hapt", help="HAPT dataset root (RawData/)")
    p.add_argument("--pamap2", help="PAMAP2 dataset root (Protocol/)")
    p.add_argument("--wisdm", help="WISDM raw/watch root")
    p.add_argument("--forth", help="FORTH-TRACE root (citation license: research only)")
    p.add_argument("--kind", choices=("xgb", "logistic", "hart"), default="xgb")
    p.add_argument("--out", required=True, help="output artifact directory")
    p.add_argument("--checkpoint", help="HART pretrained checkpoint dir (kind=hart)")
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch-size", type=int, default=64)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--hop-s", type=float, default=2.0, choices=(1.0, 2.0))
    p.add_argument("--smoke", action="store_true",
                   help="tiny synthetic datasets in a temp dir (CI smoke; no download)")
    args = p.parse_args(argv)

    if args.smoke:
        root = _write_smoke_datasets()
        args.hapt, args.pamap2, args.wisdm, args.forth = (
            os.path.join(root, "hapt"), os.path.join(root, "pamap2"),
            os.path.join(root, "wisdm"), None)

    pairs = _dataset_roots(args)
    if not pairs:
        p.error("no datasets given (use --hapt/--pamap2/--wisdm/--forth or set " + DATA_ENV)

    sessions = load_sessions(pairs)
    counts = Counter((s.dataset, s.placement) for s in sessions)
    events = Counter(e.kind for s in sessions for e in s.events)
    print("sessions:", dict(counts), "events:", dict(events), file=sys.stderr)

    train_sub, val_sub, test_sub, split = split_subjects(sessions, seed=args.seed)
    x_tr, y_tr, meta_tr = build_windows(sessions, train_sub, args.kind, args.hop_s)
    x_va, y_va, meta_va = build_windows(sessions, val_sub, args.kind, args.hop_s)
    x_te, y_te, meta_te = build_windows(sessions, test_sub, args.kind, args.hop_s)
    print("windows train/val/test:", len(x_tr), len(x_va), len(x_te), file=sys.stderr)
    print("train labels:", dict(Counter(y_tr)), file=sys.stderr)
    if not x_tr or set(y_tr) < set(CLASSES):
        print("ERROR: training set must cover all 5 classes", file=sys.stderr)
        return 2

    os.makedirs(args.out, exist_ok=True)
    provenance = {
        "datasets": {d: {"root": r, "license": lic} for d, r in pairs
                     for lic in [LICENSES.get(d, "unknown")]},
        "split": split,
        "window_counts": {"train": len(x_tr), "val": len(x_va), "test": len(x_te)},
        "label_counts_train": dict(Counter(y_tr)),
        "hop_s": args.hop_s,
    }

    if args.kind in ("xgb", "logistic"):
        from .transition_features import feature_matrix
        mat_tr, _ = feature_matrix(x_tr)
        keep = ~np.isnan(mat_tr).any(axis=1)
        mat_tr, y_tr2 = mat_tr[keep], [y for y, k in zip(y_tr, keep) if k]
        mean, scale = mat_tr.mean(axis=0), mat_tr.std(axis=0) + 1e-9
        xs_tr = (mat_tr - mean) / scale
        y_ids = np.array([CLASSES.index(c) for c in y_tr2], dtype=np.int64)
        if args.kind == "xgb":
            model = train_xgboost(xs_tr, y_ids, seed=args.seed)
            artifact = _xgb_trees_to_artifact(
                model, list(FEATURE_NAMES), mean, scale, DEFAULT_THRESHOLDS,
                provenance, "transition-b-xgb-v0")
        else:
            model = train_logistic(xs_tr, y_ids, seed=args.seed)
            artifact = export_logistic(
                model, list(FEATURE_NAMES), mean, scale, DEFAULT_THRESHOLDS,
                provenance, "transition-b-logistic-v0")
        sha = write_artifact(artifact, os.path.join(args.out, "transition.json.gz"))
        print("artifact sha256:", sha, file=sys.stderr)
        # smoke-check the artifact loads and is deterministic
        m = TransitionModel.load(os.path.join(args.out, "transition.json.gz"))
        pred = m.predict_window(np.zeros((int(4 * 100), 6)) + [0, 0, 1, 0, 0, 0], 100.0)
        print("loaded artifact smoke label:", pred.label, "abstained:", pred.abstained,
              file=sys.stderr)
    else:
        # Model C: frozen HART backbone + 5-class transition head on 30 Hz windows
        from .model import HARTModel, ModelError
        from .train import train_head
        mat_tr = np.stack([np.asarray(w, dtype=np.float64) for w in x_tr])
        mat_va = np.stack([np.asarray(w, dtype=np.float64) for w in x_va])
        mean, scale = mat_tr.reshape(-1, 6).mean(axis=0), mat_tr.reshape(-1, 6).std(axis=0) + 1e-9
        xs_tr = (mat_tr - mean) / scale
        xs_va = (mat_va - mean) / scale
        y_ids = np.array([CLASSES.index(c) for c in y_tr], dtype=np.int64)
        y_va_ids = np.array([CLASSES.index(c) for c in y_va], dtype=np.int64)
        manifest = Manifest(
            model_version="hart-transition-v0", model_kind="hart",
            class_map=list(CLASSES), seed=args.seed,
            scaler={"mean": mean.tolist(), "scale": scale.tolist(), "fit": "train"},
            thresholds={"max_prob": 0.60, "margin": 0.10})
        history = train_head(args.checkpoint, args.out, manifest, xs_tr, y_ids,
                             xs_va, y_va_ids, epochs=args.epochs,
                             batch_size=args.batch_size, lr=args.lr, seed=args.seed)
        print("history:", json.dumps(history), file=sys.stderr)
    return 0


LICENSES = {
    "hapt": "CC BY 4.0 (UCI id 341, DOI 10.24432/C54G7M)",
    "pamap2": "CC BY 4.0 (UCI id 231, DOI 10.24432/C5NW2H)",
    "wisdm": "CC BY 4.0 (UCI id 507, DOI 10.24432/C5HK59)",
    "forth": "citation-only (Karagiannaki et al., UbiComp 2016, DOI 10.1145/2968219.2971421); "
             "no formal license grant: RESEARCH BENCHMARKING ONLY",
}


if __name__ == "__main__":
    raise SystemExit(main())
