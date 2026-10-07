"""Deterministic synthetic head-bundle parts — FIXTURES, TESTS AND BENCHMARKS ONLY.

Nothing built here is trained: head weights are fixed seeded random numbers, priors are flat, the OOD
reference is whatever embeddings the caller passes. Bundles built from these parts are always
``evidence_tier_max = "shadow"`` and say so in ``manifest.training``. They exist so the serve path, the
golden fixture and the Swift decoder can be exercised end-to-end without any real model or data.
"""

from __future__ import annotations

from typing import Any, Dict, Mapping, Optional

import numpy as np

from . import HEAD_CLASS_ORDERS, INERTIA_AXES, INERTIA_RATE_HZ, PREPROCESSING_VERSION
from . import bundle_math as bm

FIXTURE_NOTE = "FIXTURE: fixed seeded random head weights; NOT trained; NOT Inertia-1; shadow only"

# (supported mask by class, arch, calibration) per head — chosen to exercise every code path:
# unsupported classes, covers, merge_into, MLP heads, each calibration method, the multi-label head.
_LAYOUT = {
    "posture": ({"recumbent": 1, "seated_likely": 1, "upright_stationary": 1, "postural_transition": 1},
                "linear", "temperature"),
    "locomotion": ({"stationary": 1, "walking": 1, "brisk_walking": 0, "running": 1, "stairs": 0, "cycling": 1,
                    "vehicle_motion": 0, "other": 1}, "mlp", "temp_bias"),
    "arm_behavior": ({"quiet": 1, "desk_like": 1, "fidgeting": 1, "repetitive_hand_motion": 0,
                      "active_gesturing": 1, "exercise_motion": 1, "other": 0}, "linear", "vector"),
    "transition": ({"sit_to_stand_like": 1, "stand_to_sit_like": 1, "lying_down_like": 0, "getting_up_like": 0,
                    "walk_start": 1, "walk_stop": 1, "run_start": 0, "run_stop": 0}, "linear",
                   "temperature_per_event"),
}


def _head_meta(name: str, supported: Mapping[str, int], arch: str) -> Dict[str, Any]:
    order = list(HEAD_CLASS_ORDERS[name])
    sup = [bool(supported[c]) for c in order]
    sup_c = [c for c, s in zip(order, sup) if s]
    multilabel = name == "transition"
    prior = {c: (0.05 if multilabel else round(1.0 / len(sup_c), 6)) for c in sup_c}
    status = {c: ("strong" if i % 3 == 0 else "weak") for i, c in enumerate(sup_c)}
    merge: Dict[str, str] = {}
    covers: Dict[str, list] = {}
    if name == "posture":
        status["postural_transition"] = "abstain"
        merge["postural_transition"] = "upright_stationary"
    if name == "locomotion":
        covers["walking"] = ["walking", "brisk_walking"]
    tau = {c: (0.85 if status[c] == "strong" else 0.7) for c in sup_c}
    return {"arch": arch, "class_order": order, "supported": sup, "prior": prior, "status": status,
            "tau": tau, "merge_into": merge, "covers": covers,
            "support_counts": {c: 0 for c in sup_c}, "selection": {"note": FIXTURE_NOTE}}


def _calibration(name: str, meta: Mapping[str, Any], method: str, rng: np.random.Generator) -> Dict[str, Any]:
    K, sup = len(meta["class_order"]), meta["supported"]
    c: Dict[str, Any] = {"method": method, "class_order": list(meta["class_order"]), "support_mask": list(sup),
                         "class_prior": dict(meta["prior"]),
                         "fit": {"split": "val", "val_split_sha256": "0" * 64, "note": FIXTURE_NOTE}}
    vec = lambda lo, hi: [round(float(rng.uniform(lo, hi)), 6) if s else None for s in sup]  # noqa: E731
    if method in ("temperature", "temp_bias"):
        c["T"] = 1.5
    if method == "temperature_per_event":
        c["T"] = vec(0.8, 2.0)
    if method in ("temp_bias", "vector"):
        c["bias"] = vec(-0.3, 0.3)
    if method == "vector":
        c["weight"] = vec(0.5, 1.5)
    assert len(c["class_order"]) == K
    return c


def _ood(method: str, ref: np.ndarray, rng: np.random.Generator, k: int) -> tuple:
    mu = ref.mean(axis=0)
    sigma = np.maximum(ref.std(axis=0), 1e-3)
    z = (ref - mu) / sigma
    meta: Dict[str, Any] = {"method": method, "fit": {"split": "val", "note": FIXTURE_NOTE}}
    if method == "energy":
        meta.update(head="locomotion", threshold=0.0)
        return meta, {}
    arrays: Dict[str, np.ndarray] = {"mu": mu.astype(np.float32), "sigma": sigma.astype(np.float32)}
    if method == "knn":
        u = z / np.maximum(np.linalg.norm(z, axis=1, keepdims=True), 1e-12)
        arrays["reference"] = u.astype(np.float16)
        loo = bm.ood_knn(z, arrays["reference"], k + 1)       # +1: each point is its own nearest
        meta.update(k=k, threshold=round(float(np.quantile(loo, 0.95)), 6))
        return meta, arrays
    prec = np.linalg.inv(np.cov(z, rowvar=False) + 0.1 * np.eye(z.shape[1]))
    arrays["precision"] = prec.astype(np.float32)
    if method == "maha_min":
        groups = np.array_split(z[rng.permutation(len(z))], 3)
        arrays["class_means"] = np.stack([g.mean(axis=0) for g in groups]).astype(np.float32)
        score = bm.ood_maha_min(z, arrays["class_means"], arrays["precision"])
    else:
        arrays["mean"] = z.mean(axis=0).astype(np.float32)
        score = bm.ood_maha_global(z, arrays["mean"], arrays["precision"])
    meta["threshold"] = round(float(np.quantile(score, 0.95)), 6)
    return meta, arrays


def synthetic_bundle_parts(*, encoder: Mapping[str, Any], reference: np.ndarray, seed: int = 0,
                           window_s: int = 30, hop_s: int = 5, ood_method: str = "knn", k: int = 3,
                           hidden: int = 8, bundle_id: Optional[str] = None) -> Dict[str, Any]:
    """Keyword arguments for ``bundle.write_bundle`` (fixture-only; see module docstring).

    ``encoder`` is the manifest encoder block (encoder_id, embedding_dim, checkpoint_sha256, config_sha256);
    ``reference`` [N, D] embeddings give the standardisation and OOD reference."""
    D = int(encoder["embedding_dim"])
    ref = np.asarray(reference, dtype=np.float64)
    assert ref.ndim == 2 and ref.shape[1] == D and ref.shape[0] > k + 1
    rng = np.random.default_rng(seed)
    mu = ref.mean(axis=0)
    sigma = np.maximum(ref.std(axis=0), 1e-3)
    arrays: Dict[str, np.ndarray] = {"std.mu": mu.astype(np.float32), "std.sigma": sigma.astype(np.float32)}
    heads: Dict[str, Any] = {}
    calibration: Dict[str, Any] = {"heads": {}}
    scale = 1.0 / np.sqrt(D)
    for name, (supported, arch, method) in _LAYOUT.items():
        meta = _head_meta(name, supported, arch)
        K = len(meta["class_order"])
        if arch == "linear":
            arrays[f"{name}.W"] = (rng.normal(size=(K, D)) * 2 * scale).astype(np.float32)
            arrays[f"{name}.b"] = (rng.normal(size=K) * 0.1).astype(np.float32)
        else:
            arrays[f"{name}.ln_g"] = (1.0 + 0.1 * rng.normal(size=D)).astype(np.float32)
            arrays[f"{name}.ln_b"] = (0.1 * rng.normal(size=D)).astype(np.float32)
            arrays[f"{name}.W1"] = (rng.normal(size=(hidden, D)) * scale).astype(np.float32)
            arrays[f"{name}.b1"] = (0.1 * rng.normal(size=hidden)).astype(np.float32)
            arrays[f"{name}.W2"] = (rng.normal(size=(K, hidden)) / np.sqrt(hidden)).astype(np.float32)
            arrays[f"{name}.b2"] = (0.1 * rng.normal(size=K)).astype(np.float32)
        heads[name] = meta
        calibration["heads"][name] = _calibration(name, meta, method, rng)
    arrays["movement_intensity.W"] = (rng.normal(size=(1, D)) * scale).astype(np.float32)
    arrays["movement_intensity.b"] = np.array([-1.0], dtype=np.float32)
    heads["movement_intensity"] = {"arch": "linear", "output": "sigmoid", "interval80": 0.1,
                                   "target": "clip(ln(MET)/ln(12), 0, 1)"}
    ood_meta, ood_arrays = _ood(ood_method, ref, rng, k)
    manifest = {
        "bundle_id": bundle_id or f"fixture-heads-seed{seed}",
        "evidence_tier_max": "shadow",
        "encoder": dict(encoder),
        "preprocessing": {"version": PREPROCESSING_VERSION, "window_s": window_s, "hop_s": hop_s,
                          "rate_hz": INERTIA_RATE_HZ, "axes": list(INERTIA_AXES), "units": "g",
                          "gravity": "kept", "normalization": "none", "source_rate_hz": 100},
        "heads": heads,
        "training": {"kind": "fixture", "note": FIXTURE_NOTE, "seed": seed},
    }
    return {"manifest": manifest, "heads_arrays": arrays, "calibration": calibration,
            "ood_arrays": ood_arrays, "ood_meta": ood_meta}
