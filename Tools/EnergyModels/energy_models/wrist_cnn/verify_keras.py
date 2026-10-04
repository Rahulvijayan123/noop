"""Numerical parity of the numpy forward pass against the original Keras models.

Build/verify-time only: needs ``tensorflow`` and ``tf_keras`` (``requirements-cnn-convert.txt``,
section "optional: reference check"); the numpy inference path never imports them. The upstream
``.h5`` files were written by Keras 2.2.4, so the reference is *legacy Keras 2* (``tf_keras``);
Keras 3 mis-parses the input shape of those files and is not used.

    python -m energy_models.wrist_cnn.verify_keras \\
        --sample-dir <upstream>/data/train_ready/window-6000-overlap-3000 \\
        --report parity.json [--write-golden tests/fixtures/wrist_cnn_golden.npz]

What is compared (float32 numpy vs. float32 Keras on CPU, identical weights, digest-verified):
  * real upstream sample windows (stratified by MET band), if ``--sample-dir`` is given;
  * random Gaussian windows (gravity + noise of 3 mg .. 1.6 g), synthetic activity windows;
  * stress inputs (uniform +-8 g noise, constants, Nyquist square waves);
  * every layer's activations on three windows; and a float64 numpy run as a rounding reference.
Exit status 0 = all realistic inputs within ``--tolerance`` (default 1e-4, absolute) for both heads.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
from pathlib import Path

import numpy as np

from . import synthetic
from .fetch import default_artifacts_dir, ensure_upstream, verify_file
from .inputs import to_upstream_layout
from .model import WristCNN
from .pins import PINNED_COMMIT, PINS
from .spec import HEADS, REAL_ARCH, SAMPLE_RATE_HZ, WINDOW_SAMPLES

REALISTIC_SETS = ("real", "gaussian", "synthetic")
STRESS_SETS = ("uniform_noise", "edge")
GOLDEN_SEEDS = {"still": 101, "walking_like": 102, "running_like": 103}


# --------------------------------------------------------------------------- reference model


def _import_keras():
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import tensorflow as tf  # noqa: PLC0415 - heavy, verify-time only
    import tf_keras  # noqa: PLC0415

    return tf, tf_keras


def load_reference(h5_path: Path, tf_keras):
    """The original network, inference mode, exactly as saved upstream (input = flat 18000 samples)."""
    model = tf_keras.models.load_model(str(h5_path), compile=False)
    if tuple(model.input_shape) != (None, WINDOW_SAMPLES * REAL_ARCH.n_axes):
        raise RuntimeError(f"unexpected Keras input shape {model.input_shape}")
    return model


def keras_predict(model, windows: np.ndarray, batch_size: int = 8) -> np.ndarray:
    flat = np.ascontiguousarray(windows, dtype=np.float32).reshape(len(windows), -1)
    return np.asarray(model.predict(flat, batch_size=batch_size, verbose=0), dtype=np.float32)


def layer_probe(model, tf_keras) -> tuple[object, list[str | None]]:
    """A model returning every layer's output, plus the numpy stage name of each (None = not compared)."""
    names: list[str | None] = []
    n_conv = 0
    for layer in model.layers:
        kind = type(layer).__name__
        if kind == "Reshape":
            names.append(None)
        elif kind == "Conv1D":
            n_conv += 1
            names.append(f"conv{n_conv}")
        elif kind == "MaxPooling1D":
            names.append(f"pool_after_conv{n_conv}")
        elif kind in ("GlobalMaxPooling1D", "Dropout"):
            names.append("global_max")                   # Dropout is the identity at inference
        elif kind == "Dense":
            names.append("output")                       # post-activation: linear (MET) / softmax (probs)
        else:
            raise RuntimeError(f"unexpected Keras layer {kind}")
    return tf_keras.Model(model.inputs, [layer.output for layer in model.layers]), names


def keras_layer_outputs(probe, names: list[str | None], window: np.ndarray) -> list[tuple[str, np.ndarray]]:
    outs = probe.predict(np.asarray(window, dtype=np.float32).reshape(1, -1), verbose=0)
    return [(name, np.asarray(out)[0]) for name, out in zip(names, outs) if name is not None]


# --------------------------------------------------------------------------- inputs


def gaussian_windows(rng: np.random.Generator, n: int = 12) -> np.ndarray:
    """Gravity vector + white noise with sigma from 3 mg to 1.6 g, upstream layout."""
    sigmas = np.logspace(-2.5, 0.2, n)
    wins = []
    for s in sigmas:
        g = rng.normal(size=3)
        g /= np.linalg.norm(g)
        wins.append(np.clip(g + rng.normal(0.0, s, size=(WINDOW_SAMPLES, 3)), -8, 8))
    return to_upstream_layout(np.stack(wins).astype(np.float32))


def synthetic_windows(per_kind: int = 3) -> np.ndarray:
    makers = (synthetic.still_window, synthetic.oscillating_window, synthetic.running_window, synthetic.saturated_window, synthetic.flat_window)
    wins = [mk(1000 + s) for mk in makers for s in range(per_kind)]
    return to_upstream_layout(np.stack(wins))


def stress_uniform_windows(rng: np.random.Generator, n: int = 4) -> np.ndarray:
    return rng.uniform(-8.0, 8.0, size=(n, WINDOW_SAMPLES, 3)).astype(np.float32)


def edge_windows() -> np.ndarray:
    z = np.zeros((WINDOW_SAMPLES, 3), np.float32)
    nyq = np.where(np.arange(WINDOW_SAMPLES)[:, None] % 2 == 0, 8.0, -8.0).astype(np.float32) * np.ones((1, 3), np.float32)
    return np.stack([z, z + 1.0, z + 8.0, z - 8.0, nyq])


def real_windows(sample: dict, n_real: int, rng: np.random.Generator) -> np.ndarray:
    """Windows from the upstream sample, drawn evenly from the three MET bands (<1.5, 1.5..3, >=3)."""
    met = sample["met"]
    band = np.digitize(met, (1.5, 3.0))
    picks = []
    for b in range(3):
        pool = np.flatnonzero(band == b)
        if len(pool):
            picks.append(rng.choice(pool, size=min(len(pool), n_real // 3), replace=False))
    idx = np.sort(np.concatenate(picks))
    return np.asarray(sample["windows"][idx], dtype=np.float32)


# --------------------------------------------------------------------------- comparison


def compare(ref: np.ndarray, got: np.ndarray) -> dict[str, float]:
    ref = np.asarray(ref, dtype=np.float64)
    got = np.asarray(got, dtype=np.float64)
    d = np.abs(ref - got)
    return {
        "n": int(ref.shape[0]),
        "max_abs_diff": float(d.max()),
        "mean_abs_diff": float(d.mean()),
        "max_rel_diff": float((d / np.maximum(np.abs(ref), 1e-3)).max()),
        "max_abs_reference": float(np.abs(ref).max()),
    }


def layerwise(model, tf_keras, net: WristCNN, windows: np.ndarray) -> list[dict]:
    probe, names = layer_probe(model, tf_keras)
    rows: dict[str, dict[str, float]] = {}
    for w in windows:
        k_stages = keras_layer_outputs(probe, names, w)
        n_stages = dict(net.forward_stages(w))
        for name, k_out in k_stages:
            n_out = n_stages[name]
            if k_out.shape != n_out.shape:
                raise RuntimeError(f"{name}: shape {k_out.shape} (keras) vs {n_out.shape} (numpy)")
            c = compare(k_out, n_out)
            cur = rows.setdefault(name, {"shape": list(k_out.shape), "max_abs_diff": 0.0, "max_rel_diff": 0.0, "max_abs_reference": 0.0})
            cur["max_abs_diff"] = max(cur["max_abs_diff"], c["max_abs_diff"])
            cur["max_rel_diff"] = max(cur["max_rel_diff"], c["max_rel_diff"])
            cur["max_abs_reference"] = max(cur["max_abs_reference"], c["max_abs_reference"])
    return [{"stage": k, **v} for k, v in rows.items()]


def time_predict(fn, windows: np.ndarray, repeats: int = 3) -> float:
    fn(windows[:4])
    best = float("inf")
    for _ in range(repeats):
        t0 = time.perf_counter()
        fn(windows)
        best = min(best, time.perf_counter() - t0)
    return 1000.0 * best / len(windows)


# --------------------------------------------------------------------------- golden fixture


def golden_inputs() -> tuple[np.ndarray, list[str]]:
    """Three deterministic synthetic windows as int16 counts of the 3 mg quantum (reconstructible exactly)."""
    wins = [synthetic.still_window(GOLDEN_SEEDS["still"]), synthetic.oscillating_window(GOLDEN_SEEDS["walking_like"]), synthetic.running_window(GOLDEN_SEEDS["running_like"])]
    counts = np.stack([np.round(w / synthetic.QUANTUM_G) for w in wins]).astype(np.int16)
    return counts, list(GOLDEN_SEEDS)


def counts_to_windows(counts: np.ndarray, quantum_g: float = synthetic.QUANTUM_G) -> np.ndarray:
    """Natural-layout counts [n, 6000, 3] -> upstream-layout float32 windows (the model input)."""
    return to_upstream_layout(counts.astype(np.float32) * np.float32(quantum_g))


def write_golden(path: Path, refs: dict[str, object], versions: dict[str, str]) -> dict[str, object]:
    counts, names = golden_inputs()
    windows = counts_to_windows(counts)
    met = keras_predict(refs["regression"], windows)[:, 0]
    proba = keras_predict(refs["classification"], windows)
    meta = {
        "purpose": "Reference outputs of the original Keras models on synthetic windows (no upstream data redistributed).",
        "input_layout": "natural [n,6000,3] int16 counts of quantum_g; model input = to_upstream_layout(counts*quantum_g)",
        "pinned_commit": PINNED_COMMIT,
        "upstream_sha256": {h: PINS.upstream[h].sha256 for h in HEADS},
        "reference": versions,
        "names": names,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(
        path,
        counts=counts,
        quantum_g=np.float32(synthetic.QUANTUM_G),
        names=np.array(names),
        met_expected=met.astype(np.float32),
        proba_expected=proba.astype(np.float32),
        meta_json=np.frombuffer(json.dumps(meta, sort_keys=True).encode(), dtype=np.uint8),
    )
    return {"path": str(path), "bytes": path.stat().st_size, "met_expected": met.tolist(), "proba_expected": proba.tolist()}


# --------------------------------------------------------------------------- main


def environment(tf, tf_keras) -> dict[str, str]:
    import numpy  # noqa: PLC0415

    return {
        "python": platform.python_version(),
        "platform": f"{platform.system()} {platform.machine()}",
        "numpy": numpy.__version__,
        "tensorflow": tf.__version__,
        "tf_keras": tf_keras.__version__,
    }


def run(args: argparse.Namespace) -> tuple[dict, bool]:
    tf, tf_keras = _import_keras()
    art = Path(args.artifacts_dir) if args.artifacts_dir else default_artifacts_dir()
    rng = np.random.default_rng(args.seed)

    sample = None
    if args.sample_dir:
        from .evaluate import load_sample_dir  # noqa: PLC0415

        sample = load_sample_dir(args.sample_dir)

    sets: dict[str, np.ndarray] = {}
    if sample is not None:
        sets["real"] = real_windows(sample, args.n_real, rng)
    sets["gaussian"] = gaussian_windows(rng)
    sets["synthetic"] = synthetic_windows()
    sets["uniform_noise"] = stress_uniform_windows(rng)
    sets["edge"] = edge_windows()

    report: dict[str, object] = {
        "environment": environment(tf, tf_keras),
        "tolerance_abs": args.tolerance,
        "pinned_commit": PINNED_COMMIT,
        "set_sizes": {k: int(len(v)) for k, v in sets.items()},
        "heads": {},
    }
    refs: dict[str, object] = {}
    all_ok = True
    for head in HEADS:
        h5 = ensure_upstream(head, art / "upstream", PINS)           # digest-verified
        verify_file(art / PINS.npz[head].filename, PINS.npz[head].sha256, PINS.npz[head].size)
        ref = refs[head] = load_reference(h5, tf_keras)
        net = WristCNN.load(head, art)
        net64 = WristCNN.load(head, art, dtype=np.float64)

        per_set: dict[str, dict] = {}
        for name, x in sets.items():
            k_out = keras_predict(ref, x)
            n_out = net.predict_raw(x)
            per_set[name] = compare(k_out, n_out)
        realistic = max(per_set[s]["max_abs_diff"] for s in REALISTIC_SETS if s in per_set)
        stress = max(per_set[s]["max_abs_diff"] for s in STRESS_SETS)
        stress_rel = max(per_set[s]["max_rel_diff"] for s in STRESS_SETS)

        probe = sets.get("real", sets["synthetic"])[:3]
        stage_rows = layerwise(ref, tf_keras, net, probe)

        x64 = np.concatenate([sets.get("real", sets["synthetic"])[:6], sets["gaussian"][:2]])
        k64 = keras_predict(ref, x64)
        n32 = net.predict_raw(x64)
        n64 = net64.predict_raw(x64)
        float64 = {
            "n": int(len(x64)),
            "numpy32_vs_numpy64_max_abs": float(np.abs(n32.astype(np.float64) - n64).max()),
            "keras32_vs_numpy64_max_abs": float(np.abs(k64.astype(np.float64) - n64).max()),
            "keras32_vs_numpy32_max_abs": float(np.abs(k64.astype(np.float64) - n32.astype(np.float64)).max()),
        }

        timing = None
        if not args.skip_timing:
            tw = sets["synthetic"][:12]
            timing = {
                "n_windows": int(len(tw)),
                "keras_cpu_ms_per_window": time_predict(lambda a, m=ref: keras_predict(m, a, 12), tw, 2),
                "numpy_ms_per_window": time_predict(lambda a, m=net: m.predict_raw(a, batch_size=12), tw, 3),
            }

        ok = realistic <= args.tolerance
        all_ok &= ok
        report["heads"][head] = {
            "output": "MET" if head == "regression" else "class probabilities",
            "per_set": per_set,
            "max_abs_diff_realistic": realistic,
            "max_abs_diff_stress": stress,
            "max_rel_diff_stress": stress_rel,
            "within_tolerance_realistic": bool(ok),
            "layerwise": stage_rows,
            "float64_reference": float64,
            "timing": timing,
        }
    report["all_within_tolerance"] = bool(all_ok)

    if args.write_golden:
        report["golden"] = write_golden(args.write_golden, refs, report["environment"])
    return report, all_ok


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Numpy vs. Keras parity check for the wrist CNN (verify-time only).")
    ap.add_argument("--artifacts-dir", type=Path, default=None)
    ap.add_argument("--sample-dir", type=Path, default=None, help="upstream data/train_ready/window-6000-overlap-3000 (real windows)")
    ap.add_argument("--n-real", type=int, default=96)
    ap.add_argument("--seed", type=int, default=20261003)
    ap.add_argument("--tolerance", type=float, default=1e-4)
    ap.add_argument("--report", type=Path, default=None)
    ap.add_argument("--write-golden", type=Path, default=None)
    ap.add_argument("--skip-timing", action="store_true")
    args = ap.parse_args(argv)
    try:
        report, ok = run(args)
    except ImportError as exc:
        print(f"cannot run the Keras reference check: {exc}", file=sys.stderr)
        return 2
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.report:
        args.report.write_text(text + "\n")
    print(text)
    print(f"sample rate {SAMPLE_RATE_HZ} Hz, window {WINDOW_SAMPLES} samples; PASS" if ok else "PARITY FAILED", file=sys.stderr)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
