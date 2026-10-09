"""Offline: write ``fixtures/recgym/golden_upstream.json`` from UPSTREAM's own files (RECGYM.md §5).

The goldens are produced by upstream code, not by this package: ``--upstream-dir`` is a directory holding copies of
upstream ``src/models/imu_transformer.py`` and ``src/data/recgym.py`` at the pinned commit (their sha256 is checked
first; run with ``python -I`` and never from inside an upstream checkout). Upstream's own pipeline then

1. refits the StandardScaler on RecGym.csv exactly as ``make_loaders_for_channels`` does,
2. picks one test-subject (9-10) window per class (the first in upstream's window order) and records its raw values,
   the scaler's ``transform`` of four of them, and the upstream model's logits for all twelve (one batch of upstream's
   evaluation batch size, 64, the shape the port also runs),
3. records the upstream model's logits on two seeded standard-normal inputs (model-only parity).

The tests compare the port with these numbers: scaler to 1e-12, logits to 1e-5.

    python -I -m activity_context.recgym.make_golden --upstream-dir DIR --csv RecGym.csv \\
        --checkpoint wrist_-_imu_only_best.pt --out fixtures/recgym/golden_upstream.json
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from typing import Optional, Sequence

UPSTREAM_FILES = {
    "imu_transformer.py": "edd1801e5b7ace210859e75e039d1b106ff59f7bbe5740205f7024829e00278c",
    "recgym.py": "a8c47737994f6bda6437376c93e8cf4f4743525f1a4acf34a567d8fe76f52ed7",
}
ROUNDTRIP_WINDOWS = 4
SYNTHETIC_SEEDS = (20261009, 7)
EVAL_BATCH = 64                    # upstream make_loaders_for_channels(batch_size=64)


def _load(path: str, name: str):
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    base = path.rsplit("/", 1)[-1].replace("upstream_", "")
    if UPSTREAM_FILES.get(base) != digest:
        raise SystemExit(f"{path}: sha256 {digest} is not upstream's {base}")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Write the RecGym goldens from upstream's own code")
    ap.add_argument("--upstream-dir", required=True,
                    help="holds upstream imu_transformer.py and recgym.py (optionally prefixed upstream_)")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)

    import os

    import numpy as np
    import pandas as pd
    import torch

    def find(name):
        for cand in (name, "upstream_" + name):
            p = os.path.join(args.upstream_dir, cand)
            if os.path.isfile(p):
                return p
        raise SystemExit(f"{name} not found in {args.upstream_dir}")

    mdl = _load(find("imu_transformer.py"), "golden_upstream_imu_transformer")
    rec = _load(find("recgym.py"), "golden_upstream_recgym")

    df = pd.read_csv(args.csv)
    activities = sorted(df["Workout"].unique())
    df["label"] = df["Workout"].map({a: i for i, a in enumerate(activities)})
    X, y, meta = rec.get_windows_for_position(df, "wrist")
    _, _, _, scaler = rec.make_loaders_for_channels(X, y, meta, ch_idx=rec.IMU_IDX, augment=False)
    Xi = X[:, :, rec.IMU_IDX]

    test = np.isin(meta["Subject"], (9, 10))
    picks = [int(np.flatnonzero(test & (y == c))[0]) for c in range(len(activities))]
    raw = Xi[picks]                                                   # (12, 80, 6) float64, RecGym units
    scaled = scaler.transform(raw.reshape(len(raw), -1)).reshape(raw.shape)

    model = mdl.IMUCNNTransformer(in_channels=6, num_classes=len(activities), d_model=64, n_heads=4, num_layers=2,
                                  dropout=0.2)
    model.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True), strict=True)
    model.eval()

    def logits_of(x):
        # upstream IMUWindowDataset (.float(), (T, C) -> (C, T)) and evaluate() under torch.no_grad, in one batch of
        # upstream's evaluation batch size (DataLoader batch_size=64), zero rows filling it: logits reach ~60, where
        # one float32 ulp is 3.8e-6, and BLAS blocking follows the batch shape.
        t = torch.from_numpy(np.asarray(x)).float().permute(0, 2, 1)
        n = t.shape[0]
        t = torch.cat([t, torch.zeros((EVAL_BATCH - n,) + tuple(t.shape[1:]))]) if n < EVAL_BATCH else t
        with torch.no_grad():
            return model(t).double().numpy()[:n]

    synth = [np.random.default_rng(seed).standard_normal((80, 6)).astype(np.float32) for seed in SYNTHETIC_SEEDS]
    doc = {
        "schema": "recgym-golden/1",
        "generated_by": "activity_context.recgym.make_golden (upstream files, isolated venv)",
        "upstream_files_sha256": UPSTREAM_FILES,
        "libraries": {"numpy": np.__version__, "pandas": pd.__version__, "torch": torch.__version__,
                      "scikit-learn": __import__("sklearn").__version__},
        "classes": activities,
        "dataset_note": ("raw windows are RecGym (Bian, Rey, Yuan, Lukowicz), CC BY 4.0, UCI dataset 1128 "
                         "doi:10.24432/C5PW4K; test subjects 9-10, wrist, upstream window order"),
        "real": [{"label": activities[int(y[i])], "subject": int(meta["Subject"][i]), "session": int(meta["Session"][i]),
                  "raw": Xi[i].tolist(), "upstream_logits": lg.tolist()}
                 for i, lg in zip(picks, logits_of(scaled))],
        "scaler_roundtrip": [{"index": k, "scaled": scaled[k].tolist()} for k in range(ROUNDTRIP_WINDOWS)],
        "synthetic": [{"seed": seed, "scaled_float32": s.tolist(), "upstream_logits": lg.tolist()}
                      for seed, s, lg in zip(SYNTHETIC_SEEDS, synth, logits_of(np.stack(synth)))],
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
        f.write("\n")
    print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
