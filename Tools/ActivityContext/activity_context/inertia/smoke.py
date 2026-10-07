"""Synthetic end-to-end smoke path (no datasets needed): fake embeddings for REAL crosswalk labels ->
train_bundle (support, weights, arch rule, calibration, operating points, OOD) -> write_bundle ->
load_bundle().apply() parity with the training-side numpy predictions. Used by tests and
``pipeline_cli smoke``. Every bundle produced here is a shadow stand-in fixture.
"""

from __future__ import annotations

import os
from typing import Any, Dict, Optional, Sequence, Tuple

import numpy as np

from . import HEAD_CLASS_ORDERS
from .assemble import Assembled
from .experiments import HC, Experiment
from .mappings import Crosswalk, load_mappings
from .targets import CLASS_HEADS, class_targets, intensity_targets, transition_targets

# (dataset, source label) pairs whose audited targets cover posture/locomotion/arm/intensity
SMOKE_LABELS: Tuple[Tuple[str, str], ...] = (
    ("wisdm2019_watch", "A"), ("wisdm2019_watch", "B"), ("wisdm2019_watch", "D"), ("wisdm2019_watch", "E"),
    ("wisdm2019_watch", "F"), ("wisdm2019_watch", "G"), ("pamap2", "1"), ("pamap2", "4"), ("pamap2", "17"),
)
D_SMOKE = 72


def synthetic_assembled(seed: int = 0, n_per: int = 40, n_train: int = 8, n_val: int = 3, n_test: int = 3,
                        dim: int = D_SMOKE, cw: Optional[Crosswalk] = None, labels: Sequence = SMOKE_LABELS,
                        shift: float = 0.0) -> Assembled:
    import pandas as pd
    cw = cw or load_mappings()
    rng = np.random.default_rng(seed)
    centers = np.random.default_rng(12345).standard_normal((len(labels), dim)) * 2.0
    rows, embs, trans = [], [], []
    for split, n_s in (("train", n_train), ("val", n_val), ("test", n_test)):
        for s in range(n_s):
            for li, (ds, lab) in enumerate(labels):
                subj = f"{ds}:{split}{s}"
                for w in range(n_per):
                    t0 = 1000.0 * li + 30.0 * w
                    rows.append({"uid": f"{ds}|{subj}|{li}|{w}", "dataset": ds, "subject": subj, "session": f"{subj}:s",
                                 "split": split, "t0": t0, "t1": t0 + 30.0, "label": lab, "purity": 1.0, "pure": True,
                                 "filled_fraction": 0.0, "placement": "wrist_dominant", "device": "synthetic",
                                 "wrist_side": "unknown", "source_hz": 20.0, "kind": "cls", "spec": "w30"})
                    embs.append(centers[li] + rng.standard_normal(dim) + shift)
                    tr = np.full(8, -1, np.int8)
                    if cw.transition_none_ok(ds, lab):
                        tr[:] = 0
                        if lab == "A" and w % 4 != 0:            # synthetic walk_start positives
                            tr[4] = 1
                    trans.append(tr)
    meta = pd.DataFrame(rows)
    emb = np.asarray(embs, np.float32)
    trn = np.stack(trans)
    pos = trn[:, 4] == 1
    emb[pos, :4] += 3.0                                           # make the synthetic event learnable
    tg: Dict[str, np.ndarray] = {h: class_targets(meta, cw, h) for h in CLASS_HEADS}
    tg["movement_intensity"] = intensity_targets(meta, cw)
    tg["transition"] = transition_targets(meta, trn, cw)
    return Assembled(emb, meta, tg, {}, {})


def smoke_experiment(arch: str = "select") -> Experiment:
    return Experiment(name="smoke", encoder=HC, role="primary", arch=arch, transition=True,
                      description="synthetic smoke bundle (fixture; not trained on data)")


def encoder_info() -> Dict[str, Any]:
    from .registry import build_encoder
    enc = build_encoder(HC, window_s=30)
    d = enc.info.to_dict()
    d["config"] = dict(enc.info.config)
    return d


def training_side_probs(bundle_dir: str, emb: np.ndarray) -> Dict[str, np.ndarray]:
    """Recompute supported-class probabilities from the bundle arrays with the TRAINING code path."""
    from . import bundle as B
    from .calibrate import apply_supported
    from .heads import numpy_logits
    b = B.load_bundle(bundle_dir)
    z = (np.asarray(emb, np.float64) - b.heads_arrays["std.mu"]) / b.heads_arrays["std.sigma"]
    out = {}
    for h in b.heads_present():
        meta, cal = b.manifest["heads"][h], b.calibration["heads"][h]
        idx = np.flatnonzero(meta["supported"])
        lg = numpy_logits(b.heads_arrays, h, meta["arch"], z)[:, idx]
        if h == "transition":
            out[h] = 1.0 / (1.0 + np.exp(-lg / np.array([cal["T"][k] for k in idx])))
            continue
        c = dict(cal)
        for key in ("bias", "weight"):
            if c.get(key) is not None:
                c[key] = np.array([c[key][k] for k in idx], np.float64)
        out[h] = apply_supported(lg, c)
    return out


def run_smoke(out_dir: str, seed: int = 0, arch: str = "select") -> Dict[str, Any]:
    from . import bundle as B
    from .build_bundle import train_bundle
    cw = load_mappings()
    data = synthetic_assembled(seed, cw=cw)
    trval = data.select(data.meta["split"].isin(["train", "val"]).to_numpy())
    test = data.split("test")
    bdir = os.path.join(out_dir, f"smoke-{arch}-seed{seed}")
    sha = train_bundle(smoke_experiment(arch), trval, bdir, cw, encoder_info(), out_dir)
    b = B.load_bundle(bdir)
    rows = b.apply(test.emb)
    side = training_side_probs(bdir, test.emb)
    diff = 0.0
    for h, P in side.items():
        sup = [c for c, s in zip(HEAD_CLASS_ORDERS[h], b.manifest["heads"][h]["supported"]) if s]
        A = np.array([[r[h][c] for c in sup] for r in rows])
        diff = max(diff, float(np.abs(A - P).max()))
    return {"bundle_dir": bdir, "bundle_sha256": sha, "parity_max_abs": diff, "heads": b.heads_present(),
            "n_test": int(len(test.meta))}


__all__ = ["synthetic_assembled", "run_smoke", "smoke_experiment", "encoder_info", "training_side_probs", "SMOKE_LABELS"]
