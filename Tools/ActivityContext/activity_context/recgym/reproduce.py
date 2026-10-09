"""Offline: reproduce the RecGym wrist IMU-only StandardScaler and the upstream test accuracy (RECGYM.md §1.2).

Upstream trained ``models/wrist_-_imu_only_best.pt`` with a StandardScaler fitted on the training windows but did not
ship the scaler. This refits it exactly the way upstream did, from the public dataset upstream used, with upstream's
own windowing code (``vendor/recgym_data.py``, byte for byte):

1. ``RecGym.csv`` from the Kaggle mirror upstream's notebook downloads (``zhaxidelebsz/10-gym-exercises-with-615-
   abstracted-features``, version 6; public, no credentials: the API answers a signed storage redirect). The UCI copy
   (dataset 1128) was not usable: its archive's first ~60 MB are zero bytes (checked 2026-10-09, sha256 9713a9ca…).
2. Labels ``sorted(df["Workout"].unique())``; ``get_windows_for_position(df, "wrist")`` (per Subject/Session group,
   80 samples, step 40, majority label >= 0.6 else dropped).
3. ``make_loaders_for_channels(..., ch_idx=IMU_IDX)``: subjects 1-7 train, 8 val, 9-10 test; StandardScaler fitted on
   the flattened training windows.
4. The shipped checkpoint, loaded strictly into the vendored architecture, is evaluated on the val and test loaders.
   Upstream reported test accuracy 0.963 and test loss 0.1516 (notebook cell 21; README 96.3 %). A scaler that does not
   reproduce them is refused (exit 1, nothing written).

Needs pandas, scikit-learn and torch (never imported by the serve process)::

    python -m activity_context.recgym.reproduce --csv RecGym.csv --checkpoint wrist_-_imu_only_best.pt \\
        --archive-sha256 <sha256 of the downloaded Kaggle zip> --out recgym_wrist_imu_scaler.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from typing import Any, Dict, Optional, Sequence

from . import CHANNELS, CLASSES, HOP_SAMPLES, RATE_HZ, SCALER_VERSION, UPSTREAM_COMMIT, WINDOW_SAMPLES

KAGGLE_URL = ("https://www.kaggle.com/api/v1/datasets/download/zhaxidelebsz/"
              "10-gym-exercises-with-615-abstracted-features?dataset_version_number=6")
UPSTREAM_REPORTED = {"test_accuracy": 0.963, "test_loss": 0.1516}
TOLERANCE = {"test_accuracy": 0.0015, "test_loss": 0.0015}


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def evaluate(model, loader, classes) -> Dict[str, Any]:
    import numpy as np
    import torch
    crit = torch.nn.CrossEntropyLoss()
    tot, correct, loss = 0, 0, 0.0
    preds, labels = [], []
    with torch.no_grad():
        for xb, yb in loader:
            logits = model(xb)
            loss += crit(logits, yb).item() * xb.size(0)
            p = logits.argmax(1)
            correct += int((p == yb).sum())
            tot += xb.size(0)
            preds.append(p.numpy())
            labels.append(yb.numpy())
    preds, labels = np.concatenate(preds), np.concatenate(labels)
    per_class = {c: {"n": int((labels == i).sum()),
                     "recall": float((preds[labels == i] == i).mean()) if (labels == i).any() else None}
                 for i, c in enumerate(classes)}
    return {"n": tot, "accuracy": correct / tot, "loss": loss / tot, "per_class": per_class}


def reproduce(csv_path: str, checkpoint: str, archive_sha256: Optional[str] = None) -> Dict[str, Any]:
    import numpy as np
    import pandas as pd
    import sklearn
    import torch

    from .vendor import recgym_data as rec
    from .vendor.imu_transformer import IMUCNNTransformer
    from .weights import CHECKPOINT, verify_file

    verify_file(checkpoint, CHECKPOINT)
    df = pd.read_csv(csv_path)
    activities = sorted(df["Workout"].unique())
    if tuple(activities) != CLASSES:
        raise SystemExit(f"label encoding {activities} differs from the pinned class order {list(CLASSES)}")
    df["label"] = df["Workout"].map({a: i for i, a in enumerate(activities)})
    X, y, meta = rec.get_windows_for_position(df, "wrist")
    _, val_loader, test_loader, scaler = rec.make_loaders_for_channels(X, y, meta, ch_idx=rec.IMU_IDX, augment=False)
    subjects = meta["Subject"]
    counts = {"total": int(X.shape[0]), "train": int(np.isin(subjects, (1, 2, 3, 4, 5, 6, 7)).sum()),
              "val": int(np.isin(subjects, (8,)).sum()), "test": int(np.isin(subjects, (9, 10)).sum())}

    model = IMUCNNTransformer(in_channels=len(CHANNELS), num_classes=len(CLASSES), d_model=64, n_heads=4,
                              num_layers=2, dropout=0.2)
    model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True), strict=True)
    model.eval()
    reproduced = {"val": evaluate(model, val_loader, CLASSES), "test": evaluate(model, test_loader, CLASSES)}

    T, C = WINDOW_SAMPLES, len(CHANNELS)
    mean, scale = scaler.mean_.reshape(T, C), scaler.scale_.reshape(T, C)
    return {
        "schema": "recgym-scaler/1",
        "scaler_version": SCALER_VERSION,
        "description": ("sklearn StandardScaler fitted exactly as upstream make_loaders_for_channels does: on the "
                        "flattened (N, 80*6) training windows (subjects 1-7) of the wrist IMU-only configuration. "
                        "Per (time step, channel) feature: 480 means and 480 scales laid out [t][c] in channel order. "
                        "Values are in RecGym's released normalised units."),
        "channels": list(CHANNELS), "window_samples": T, "step_samples": HOP_SAMPLES, "sample_rate_hz": RATE_HZ,
        "classes": list(CLASSES),
        "mean": mean.tolist(), "scale": scale.tolist(),
        "n_samples_seen": int(scaler.n_samples_seen_),
        "per_channel_summary": {
            "mean_of_means": mean.mean(axis=0).tolist(),
            "mean_of_scales": scale.mean(axis=0).tolist(),
            "max_abs_mean_deviation_over_t": np.abs(mean - mean.mean(axis=0)).max(axis=0).tolist(),
            "max_rel_scale_deviation_over_t":
                (np.abs(scale - scale.mean(axis=0)) / scale.mean(axis=0)).max(axis=0).tolist(),
        },
        "provenance": {
            "dataset": {
                "name": ("RecGym (Bian, Rey, Yuan, Lukowicz); Kaggle mirror zhaxidelebsz/10-gym-exercises-with-615-"
                         "abstracted-features version 6, the version upstream's notebook downloaded"),
                "url": KAGGLE_URL, "archive_sha256": archive_sha256, "csv_sha256": _sha256(csv_path),
                "licence": "CC BY 4.0 (UCI dataset 1128, doi:10.24432/C5PW4K)",
                "uci_note": "UCI archive 1128 (sha256 9713a9cac8c4…) is corrupt: its first ~60 MB are zero bytes",
            },
            "upstream": {
                "repo": "https://github.com/MKorp7/HAR_IMU_CNN-Transformer", "commit": UPSTREAM_COMMIT,
                "code": "src/data/recgym.py (vendor/recgym_data.py), src/models/imu_transformer.py",
                "checkpoint": "models.zip:models/wrist_-_imu_only_best.pt", "checkpoint_sha256": CHECKPOINT.sha256,
            },
            "procedure": {
                "script": "Tools/ActivityContext/activity_context/recgym/reproduce.py",
                "label_encoding": "sorted(df['Workout'].unique())", "position": "wrist",
                "windowing": "per (Subject, Session); 80 samples, step 40, majority label >= 0.6 else dropped",
                "split": {"train": [1, 2, 3, 4, 5, 6, 7], "val": [8], "test": [9, 10]},
                "windows": counts,
                "libraries": {"numpy": np.__version__, "pandas": pd.__version__,
                              "scikit-learn": sklearn.__version__, "torch": torch.__version__},
            },
            "verification": {
                "upstream_reported": dict(UPSTREAM_REPORTED,
                                          source="notebooks/ready_to_use_in_colab_recgym.ipynb cell 21; README 96.3%"),
                "tolerance": TOLERANCE,
                "reproduced": reproduced,
            },
        },
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Refit the RecGym wrist IMU scaler and check the upstream accuracy")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--archive-sha256", default=None)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    doc = reproduce(args.csv, args.checkpoint, args.archive_sha256)
    test = doc["provenance"]["verification"]["reproduced"]["test"]
    print(f"test accuracy {test['accuracy']:.4f} loss {test['loss']:.4f} (upstream {UPSTREAM_REPORTED})",
          file=sys.stderr)
    if (abs(test["accuracy"] - UPSTREAM_REPORTED["test_accuracy"]) > TOLERANCE["test_accuracy"]
            or abs(test["loss"] - UPSTREAM_REPORTED["test_loss"]) > TOLERANCE["test_loss"]):
        print("the refit scaler does not reproduce upstream's reported test result: nothing written", file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
