"""Build/verify-time tooling: sample-data evaluation, orientation sensitivity, speed.

The upstream repository ships a few thousand pickled windows from ONE participant
("LSM146 Wrist (2016-10-19)"); they are not redistributed here. This module reads a local
clone with a restricted unpickler (the files are pickles; arbitrary pickles are never loaded)
and reports how the numpy port behaves on them.

    python -m energy_models.wrist_cnn.evaluate --sample-dir <clone>/data/train_ready/window-6000-overlap-3000

These numbers are NOT a held-out evaluation: the upstream scripts train and "test" on the very same
folder, and the participant may well have been in the training set of the released weights.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import pickle
import sys
import time
from pathlib import Path

import numpy as np

from .inputs import apply_axis_transform, from_upstream_layout, to_upstream_layout
from .model import WristCNN
from .spec import WINDOW_SAMPLES

# upstream modeling/statistical_extensions.py: EnergyTransform.met_to_intensity
UPSTREAM_MET_CUTS = (1.5, 3.0)
# upstream modeling/model_train_class.py: Y 1->0, 2->1, 3->2, 4->2
UPSTREAM_CLASS_REMAP = {1: 0, 2: 1, 3: 2, 4: 2}


class _SafeUnpickler(pickle.Unpickler):
    """Allows only what numpy needs to rebuild plain ndarrays; anything else is refused."""

    def find_class(self, module: str, name: str):
        core = getattr(np, "_core", None) or np.core  # numpy 2.x renamed numpy.core -> numpy._core
        if module in ("numpy.core.multiarray", "numpy._core.multiarray") and name == "_reconstruct":
            return core.multiarray._reconstruct
        if module == "numpy" and name in ("ndarray", "dtype"):
            return getattr(np, name)
        if module == "_codecs" and name == "encode":
            import _codecs

            return _codecs.encode
        raise pickle.UnpicklingError(f"refusing to unpickle {module}.{name}")


def load_upstream_sample(path: Path | str) -> dict[str, np.ndarray]:
    """Read one upstream ``*_train_ready.npy`` (a pickled dict of arrays) without trusting the pickle."""
    with open(path, "rb") as fh:
        version = np.lib.format.read_magic(fh)
        shape, _fortran, dtype = np.lib.format._read_array_header(fh, version)
        if dtype != np.dtype(object) or shape != ():
            raise ValueError(f"{path}: not a pickled-object .npy")
        obj = _SafeUnpickler(io.BytesIO(fh.read()), encoding="latin1").load()
    data = obj.item() if isinstance(obj, np.ndarray) else obj
    if not isinstance(data, dict) or not {"segments", "activity_classes", "energy_e"} <= set(data):
        raise ValueError(f"{path}: unexpected sample structure")
    return data


def load_sample_dir(sample_dir: Path | str) -> dict[str, object]:
    files = sorted(Path(sample_dir).glob("*.npy"))
    if not files:
        raise FileNotFoundError(f"no .npy files under {sample_dir}")
    segs, cls, met, fidx, digests = [], [], [], [], {}
    for i, f in enumerate(files):
        d = load_upstream_sample(f)
        segs.append(np.asarray(d["segments"], dtype=np.float32))
        cls.append(np.asarray(d["activity_classes"]))
        met.append(np.asarray(d["energy_e"], dtype=np.float64))
        fidx.append(np.full(len(met[-1]), i))
        digests[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
    return {
        "windows": np.concatenate(segs),
        "classes": np.concatenate(cls),
        "met": np.concatenate(met),
        "file_index": np.concatenate(fidx),
        "file_names": [f.name for f in files],
        "file_sha256": digests,
    }


def met_to_intensity_index(met: np.ndarray) -> np.ndarray:
    """0/1/2 from upstream's cut points (<1.5, 1.5..<3, >=3 MET)."""
    met = np.asarray(met)
    return np.digitize(met, UPSTREAM_MET_CUTS).astype(np.int64)


def regression_metrics(pred: np.ndarray, ref: np.ndarray) -> dict[str, float]:
    pred = np.asarray(pred, dtype=np.float64)
    ref = np.asarray(ref, dtype=np.float64)
    err = pred - ref
    ss_res = float((err**2).sum())
    ss_tot = float(((ref - ref.mean()) ** 2).sum())
    floored = np.maximum(pred, 1.0) - ref
    return {
        "n": int(len(ref)),
        "rmse": float(np.sqrt((err**2).mean())),
        "rmse_pred_floored_at_1": float(np.sqrt((floored**2).mean())),
        "mae": float(np.abs(err).mean()),
        "bias": float(err.mean()),
        "pearson_r": float(np.corrcoef(pred, ref)[0, 1]),
        "r2": float(1.0 - ss_res / ss_tot),
        "pred_mean": float(pred.mean()),
        "ref_mean": float(ref.mean()),
    }


def class_metrics(pred_idx: np.ndarray, ref_idx: np.ndarray, n_classes: int = 3) -> dict[str, object]:
    pred_idx = np.asarray(pred_idx, dtype=np.int64)
    ref_idx = np.asarray(ref_idx, dtype=np.int64)
    cm = np.zeros((n_classes, n_classes), dtype=np.int64)
    np.add.at(cm, (ref_idx, pred_idx), 1)
    support = cm.sum(axis=1)
    recall = np.divide(np.diag(cm), support, out=np.full(n_classes, np.nan), where=support > 0)
    return {
        "n": int(len(ref_idx)),
        "accuracy": float(np.trace(cm) / cm.sum()),
        "balanced_accuracy": float(np.nanmean(recall)),
        "majority_baseline": float(support.max() / cm.sum()),
        "confusion_ref_rows_pred_cols": cm.tolist(),
        "recall": [None if np.isnan(r) else float(r) for r in recall],
    }


def evaluate_sample(sample: dict[str, object], reg: WristCNN, cls: WristCNN, *, batch_size: int = 16) -> dict[str, object]:
    windows = sample["windows"]
    met_ref = sample["met"]
    cls_ref = np.vectorize(UPSTREAM_CLASS_REMAP.get)(sample["classes"])
    out: dict[str, object] = {"n_windows": int(len(met_ref)), "class_counts_remapped": np.bincount(cls_ref, minlength=3).tolist()}

    def one_layout(w: np.ndarray) -> tuple[dict[str, object], np.ndarray, np.ndarray]:
        met = reg.predict(w, batch_size=batch_size)
        proba = cls.predict(w, batch_size=batch_size)
        pred_cls = proba.argmax(axis=1)
        res = {
            "regression_vs_energy_e": regression_metrics(met, met_ref),
            "regression_implied_3class_vs_energy_e_bands": class_metrics(met_to_intensity_index(met), met_to_intensity_index(met_ref)),
            "regression_implied_3class_vs_activity_classes": class_metrics(met_to_intensity_index(met), cls_ref),
            "classification_vs_activity_classes": class_metrics(pred_cls, cls_ref),
            "classification_vs_energy_e_bands": class_metrics(pred_cls, met_to_intensity_index(met_ref)),
        }
        return res, met, proba

    as_given, met_g, proba_g = one_layout(windows)
    out["upstream_layout_as_given"] = as_given
    # Contrast: a naive [time, axis] reading of the same data, fed to the same weights (wrong layout for them).
    wrong, _, _ = one_layout(from_upstream_layout(windows))
    out["natural_layout_fed_to_model_for_contrast"] = wrong

    per_file = []
    for i, name in enumerate(sample["file_names"]):
        m = sample["file_index"] == i
        per_file.append({
            "file": name,
            "n": int(m.sum()),
            "rmse": float(np.sqrt(((met_g[m] - met_ref[m]) ** 2).mean())),
            "pearson_r": float(np.corrcoef(met_g[m], met_ref[m])[0, 1]),
            "class_accuracy": float((proba_g[m].argmax(1) == cls_ref[m]).mean()),
        })
    out["per_file"] = per_file
    out["_predictions"] = {"met": met_g, "proba": proba_g}
    return out


AXIS_VARIANTS = {
    "identity": np.eye(3),
    "swap_xy": np.array([[0, 1, 0], [1, 0, 0], [0, 0, 1]], float),
    "swap_xz": np.array([[0, 0, 1], [0, 1, 0], [1, 0, 0]], float),
    "swap_yz": np.array([[1, 0, 0], [0, 0, 1], [0, 1, 0]], float),
    "cycle_xyz": np.array([[0, 1, 0], [0, 0, 1], [1, 0, 0]], float),
    "cycle_zyx": np.array([[0, 0, 1], [1, 0, 0], [0, 1, 0]], float),
    "negate_all": -np.eye(3),
    "flip_x": np.diag([-1.0, 1, 1]),
    "flip_y": np.diag([1.0, -1, 1]),
    "flip_z": np.diag([1.0, 1, -1]),
    "rot90_about_z": np.array([[0, 1, 0], [-1, 0, 0], [0, 0, 1]], float),
    "rot90_about_x": np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], float),
}


def orientation_sensitivity(windows: np.ndarray, reg: WristCNN, met_ref: np.ndarray, *, batch_size: int = 16) -> dict[str, dict[str, float]]:
    """How the MET output moves when the device axes are permuted / flipped (sample windows)."""
    natural = from_upstream_layout(windows).astype(np.float32)           # [n, T, 3]
    base = reg.predict(windows, batch_size=batch_size)
    res: dict[str, dict[str, float]] = {}
    for name, r in AXIS_VARIANTS.items():
        w = to_upstream_layout(apply_axis_transform(natural, r))
        pred = reg.predict(w, batch_size=batch_size)
        res[name] = {
            "rmse_vs_energy_e": float(np.sqrt(((pred - met_ref) ** 2).mean())),
            "pearson_r_vs_energy_e": float(np.corrcoef(pred, met_ref)[0, 1]),
            "mean_abs_change_vs_identity": float(np.abs(pred - base).mean()),
            "max_abs_change_vs_identity": float(np.abs(pred - base).max()),
            "bias_vs_identity": float((pred - base).mean()),
        }
    return res


def benchmark(model: WristCNN, *, n_windows: int = 96, batch_size: int = 16, repeats: int = 3, seed: int = 0) -> dict[str, float]:
    rng = np.random.default_rng(seed)
    x = rng.normal(0.0, 0.5, size=(n_windows, WINDOW_SAMPLES, 3)).astype(np.float32)
    model.predict_raw(x[:4], batch_size=batch_size)            # warm-up (page-faults the scratch buffers)
    times, cpu = [], []
    for _ in range(repeats):
        t0, c0 = time.perf_counter(), time.process_time()
        model.predict_raw(x, batch_size=batch_size)
        times.append(time.perf_counter() - t0)
        cpu.append(time.process_time() - c0)
    ms = min(times) / n_windows * 1e3
    return {
        "batch_size": batch_size,
        "ms_per_window_best": ms,
        "ms_per_window_median": float(np.median(times)) / n_windows * 1e3,
        "cpu_ms_per_window_median": float(np.median(cpu)) / n_windows * 1e3,
        "seconds_per_1440_windows": ms * 1440 / 1e3,
    }


def _jsonable(obj):
    if isinstance(obj, dict):
        return {k: _jsonable(v) for k, v in obj.items() if not str(k).startswith("_")}
    if isinstance(obj, (list, tuple)):
        return [_jsonable(v) for v in obj]
    if isinstance(obj, np.generic):
        return obj.item()
    return obj


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--sample-dir", type=Path, required=True)
    ap.add_argument("--artifacts-dir", type=Path, default=None)
    ap.add_argument("--json", type=Path, default=None, help="write the full result here")
    ap.add_argument("--skip-orientation", action="store_true")
    args = ap.parse_args(argv)

    reg = WristCNN.load("regression", args.artifacts_dir)
    cls = WristCNN.load("classification", args.artifacts_dir)
    sample = load_sample_dir(args.sample_dir)
    print(f"{len(sample['met'])} windows from {len(sample['file_names'])} files", file=sys.stderr)
    res = evaluate_sample(sample, reg, cls)
    res["source_file_sha256"] = sample["file_sha256"]
    if not args.skip_orientation:
        res["orientation_sensitivity"] = orientation_sensitivity(sample["windows"], reg, sample["met"])
    res["benchmark"] = {"regression": benchmark(reg), "classification": benchmark(cls)}
    text = json.dumps(_jsonable(res), indent=2)
    if args.json:
        args.json.write_text(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
