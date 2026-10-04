"""Empirical checks of the OOD score on the public sample windows (build/verify-time tool).

    python -m energy_models.wrist_cnn.ood_eval --sample-dir <upstream>/data/train_ready/window-6000-overlap-3000 \\
        [--json ood_report.json]

Measures (1) the in-sample score distribution, (2) leave-one-segment-out false alarms (the envelope
is rebuilt without a segment and that segment is scored), (3) the response to unit / gravity /
scale / noise / frozen-data perturbations together with the resulting change in the MET estimate,
and (4) the score of the synthetic still / walking / running / railed / flat / NaN windows.

Caveat that applies to all of it: the public windows are ONE participant on ONE day, so
leave-one-segment-out is an optimistic stand-in for "unseen participant".
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Callable
from pathlib import Path

import numpy as np

from . import synthetic
from .evaluate import _jsonable, load_sample_dir
from .inputs import from_upstream_layout, to_upstream_layout
from .model import WristCNN
from .ood import COMPONENTS, compute_envelope, dominant_reason, ood_components, ood_signal

FALSE_ALARM_LEVEL = 0.5


def _frac(x: np.ndarray, level: float = FALSE_ALARM_LEVEL) -> float:
    return float((x > level).mean())


def _clip8(a: np.ndarray) -> np.ndarray:
    return np.clip(a, -8.0, 8.0)


def perturbations(seed: int = 0) -> dict[str, Callable[[np.ndarray], np.ndarray]]:
    """Natural-layout [n, T, 3] g -> perturbed natural-layout windows (clipped at the +-8 g rail like ``prepare_windows``)."""
    rng = np.random.default_rng(seed)

    def noise(sigma: float):
        return lambda w: _clip8(w + rng.normal(0.0, sigma, size=w.shape).astype(np.float32))

    def freeze_tail(frac: float):
        def f(w: np.ndarray) -> np.ndarray:
            out = w.copy()
            k = int(round(w.shape[1] * (1.0 - frac)))
            out[:, k:, :] = out[:, k - 1 : k, :]
            return out

        return f

    return {
        "identity": lambda w: w,
        "m/s^2 (x9.80665)": lambda w: _clip8(w * 9.80665),
        "milli-g (x1000)": lambda w: _clip8(w * 1000.0),
        "raw LSB (x4096)": lambda w: _clip8(w * 4096.0),
        "gravity removed (window mean)": lambda w: w - w.mean(axis=1, keepdims=True),
        "scale x0.5": lambda w: w * 0.5,
        "scale x1.5": lambda w: w * 1.5,
        "scale x2": lambda w: _clip8(w * 2.0),
        "white noise 0.05 g": noise(0.05),
        "white noise 0.3 g": noise(0.3),
        "white noise 1.0 g": noise(1.0),
        "40% frozen tail": freeze_tail(0.4),
        "95% frozen tail": freeze_tail(0.95),
        "axes cycled (x,y,z)->(y,z,x)": lambda w: w[:, :, [1, 2, 0]],
        "all axes negated": lambda w: -w,
    }


def leave_one_segment_out(sample: dict) -> dict:
    wins, files = sample["windows"], sample["file_index"]
    rows = []
    for k, name in enumerate(sample["file_names"]):
        held = files == k
        env = compute_envelope(wins[~held])
        c = ood_components(wins[held], envelope=env)
        score = np.max(np.stack([c[n] for n in COMPONENTS]), axis=0)
        env_only = np.maximum.reduce([c["envelope"], c["gravity"], c["saturation"]])
        rows.append({
            "segment": k,
            "file": name,
            "n": int(held.sum()),
            "frac_gt_0.5_all": _frac(score),
            "frac_gt_0.5_without_flat": _frac(env_only),
            "frac_gt_0.2_without_flat": _frac(env_only, 0.2),
            "mean_without_flat": float(env_only.mean()),
            "max_without_flat": float(env_only.max()),
        })
    n = np.array([r["n"] for r in rows])
    w = lambda key: float(np.average([r[key] for r in rows], weights=n))  # noqa: E731
    return {
        "per_segment": rows,
        "pooled_frac_gt_0.5_all": w("frac_gt_0.5_all"),
        "pooled_frac_gt_0.5_without_flat": w("frac_gt_0.5_without_flat"),
        "pooled_frac_gt_0.2_without_flat": w("frac_gt_0.2_without_flat"),
    }


def in_sample(sample: dict, met_pred: np.ndarray) -> dict:
    wins = sample["windows"]
    c = ood_components(wins)
    score = np.max(np.stack([c[n] for n in COMPONENTS]), axis=0)
    err = np.abs(met_pred - sample["met"])
    low, high = score < 0.2, score >= 0.5
    reasons = dominant_reason(c)
    counts: dict[str, int] = {}
    for r in reasons:
        counts[r] = counts.get(r, 0) + 1
    return {
        "n": int(len(score)),
        "quantiles_0_50_90_95_99_100": np.percentile(score, [0, 50, 90, 95, 99, 100]).tolist(),
        "frac_gt_0.2": _frac(score, 0.2),
        "frac_gt_0.5": _frac(score),
        "frac_gt_0.8": _frac(score, 0.8),
        "component_frac_gt_0.5": {n: _frac(c[n]) for n in COMPONENTS},
        "dominant_reason_counts": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        "mean_abs_met_error_score_lt_0.2": float(err[low].mean()) if low.any() else None,
        "mean_abs_met_error_score_ge_0.5": float(err[high].mean()) if high.any() else None,
        "n_score_lt_0.2": int(low.sum()),
        "n_score_ge_0.5": int(high.sum()),
        "spearman_score_vs_abs_error": _spearman(score, err),
    }


def _spearman(a: np.ndarray, b: np.ndarray) -> float:
    ra = np.argsort(np.argsort(a, kind="stable"), kind="stable").astype(np.float64)
    rb = np.argsort(np.argsort(b, kind="stable"), kind="stable").astype(np.float64)
    return float(np.corrcoef(ra, rb)[0, 1])


def perturbation_response(sample: dict, reg: WristCNN, n: int = 192, seed: int = 0) -> list[dict]:
    rng = np.random.default_rng(seed)
    idx = np.sort(rng.choice(len(sample["met"]), size=min(n, len(sample["met"])), replace=False))
    natural = from_upstream_layout(sample["windows"][idx]).astype(np.float32)
    base = reg.predict(to_upstream_layout(natural))
    rows = []
    for name, fn in perturbations(seed).items():
        pert = fn(natural.copy()).astype(np.float32)
        up = to_upstream_layout(pert)
        s = ood_signal(up)
        finite = np.isfinite(up).all(axis=(1, 2))
        met = np.full(len(up), np.nan)
        try:
            met[finite] = reg.predict(up[finite], on_invalid="nan")
        except FloatingPointError:
            pass
        rows.append({
            "perturbation": name,
            "mean_score": float(s.mean()),
            "frac_gt_0.5": _frac(s),
            "frac_gt_0.8": _frac(s, 0.8),
            "mean_abs_met_change": float(np.nanmean(np.abs(met - base))) if np.isfinite(met).any() else None,
        })
    return rows


def synthetic_scores() -> dict[str, dict]:
    makers = {
        "still": synthetic.still_window,
        "walking-like 1.8 Hz": synthetic.oscillating_window,
        "running-like 2.8 Hz": synthetic.running_window,
        "saturated +-8 g": synthetic.saturated_window,
        "flat (constant)": synthetic.flat_window,
        "NaN block": synthetic.nan_window,
    }
    out = {}
    for name, mk in makers.items():
        w = to_upstream_layout(np.stack([mk(500 + s) for s in range(8)]))
        c = ood_components(w)
        s = np.max(np.stack([c[n] for n in COMPONENTS]), axis=0)
        out[name] = {"mean": float(s.mean()), "min": float(s.min()), "max": float(s.max()), "reasons": sorted(set(dominant_reason(c)))}
    return out


def run(sample_dir: Path, artifacts_dir: Path | None = None) -> dict:
    sample = load_sample_dir(sample_dir)
    reg = WristCNN.load("regression", artifacts_dir)
    met = reg.predict(sample["windows"])
    return {
        "in_sample": in_sample(sample, met),
        "leave_one_segment_out": leave_one_segment_out(sample),
        "perturbations": perturbation_response(sample, reg),
        "synthetic": synthetic_scores(),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sample-dir", type=Path, required=True)
    ap.add_argument("--artifacts-dir", type=Path, default=None)
    ap.add_argument("--json", type=Path, default=None)
    args = ap.parse_args(argv)
    rep = run(args.sample_dir, args.artifacts_dir)
    text = json.dumps(_jsonable(rep), indent=2)
    if args.json:
        args.json.write_text(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
