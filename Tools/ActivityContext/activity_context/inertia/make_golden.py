"""Regenerate the Inertia golden fixtures (``Tools/ActivityContext/fixtures/inertia``).

    python -m activity_context.inertia.make_golden [--out DIR] [--check]

Everything is deterministic and synthetic — NOTHING here is Inertia-1 or trained:

* ``golden_motion_heads_request.json``  a WHOOP-format infer request: 1 s head + 100 s body + 1 s tail of
  synthetic NPB1 columns (still-flat, seated-ish tilt with sway, 1.8 Hz gait), i16 at 4096 LSB/g.
* ``encoder_tiny.ckpt``  seeded random-init vendored ART, preset ``tiny`` (d_model 16) — the stand-in
  ``standin:inertia-arch-random-init/ar_transformer-tiny/seed0`` (``make_test_checkpoint``; ~330 KB, the
  upstream-fixed [1, 5000, 16] PE table dominates).
* ``bundle_tiny/``  a shadow-tier head bundle with fixed seeded weights (``synthetic.py``); its standardiser
  and kNN OOD reference come from the tiny encoder's embeddings of a separate synthetic reference run,
  rounded to 5 decimals so the bundle bytes are stable under float noise. Includes ``encoder.json``.
* ``golden_motion_heads_response.json``  the exact serve response (``duration_ms`` pinned to 0), produced
  by the same runtime the serve process uses, run with ``--allow-standin-shadow``.
* ``golden_inertia_prep.json``  inertia-prep-1 applied to ``fixtures/golden_imu_frames.json`` (12 real-format
  WHOOP frames): the single 10 s window, rounded to 7 decimals.

``--check`` regenerates into a temporary directory and compares with the committed files (floats within
1e-6); exit status 1 on any mismatch. The Swift decoder test decodes golden_motion_heads_response.json.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import sys
import tempfile
from typing import Any, Dict, List, Tuple

import numpy as np

from ..preprocess import decode_frame_hex, encode_columns_b64
from .bundle import json_bytes, write_bundle
from .preprocess import windows_from_seconds

FIXTURE_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "fixtures", "inertia"))
GOLDEN_FRAMES = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "fixtures",
                                              "golden_imu_frames.json"))
T0 = 1758000000
BODY_S, HEAD_S, TAIL_S = 100, 1, 1
ENCODER_ID = "standin:inertia-arch-random-init/ar_transformer-tiny/seed0"
BUNDLE_ID = "fixture-heads-tiny-art-seed0"
REQUEST_ID = "golden-motion-heads-1"
_ACCEL_LSB, _GYRO_LSB = 4096.0, 32768.0 / 2000.0


def _unit(v: Tuple[float, float, float]) -> np.ndarray:
    a = np.asarray(v, dtype=np.float64)
    return a / np.linalg.norm(a)


def synth_columns(n_seconds: int, seed: int, segments: List[Tuple[str, int]]) -> List[np.ndarray]:
    """Per-second int16 NPB1 columns for consecutive (kind, seconds) segments at 100 Hz."""
    rng = np.random.default_rng(seed)
    t = np.arange(n_seconds * 100) / 100.0
    acc = np.zeros((t.size, 3))
    gyr = np.zeros((t.size, 3))
    edges = np.cumsum([0] + [s * 100 for _, s in segments])
    assert edges[-1] == t.size
    for (kind, _), a, b in zip(segments, edges[:-1], edges[1:]):
        tt = t[a:b]
        if kind == "still":
            acc[a:b] = _unit((0.0, 0.0, 1.0)) + rng.normal(0, 0.002, (b - a, 3))
            gyr[a:b] = rng.normal(0, 0.3, (b - a, 3))
        elif kind == "seated":
            acc[a:b] = _unit((0.45, 0.15, 0.88)) + rng.normal(0, 0.004, (b - a, 3))
            acc[a:b, 0] += 0.01 * np.sin(2 * np.pi * 0.25 * tt)
            gyr[a:b] = rng.normal(0, 1.5, (b - a, 3)) + 3.0 * np.sin(2 * np.pi * 0.25 * tt)[:, None]
        elif kind == "walk":
            acc[a:b] = _unit((0.2, -0.35, 0.91)) + rng.normal(0, 0.01, (b - a, 3))
            acc[a:b, 2] += 0.22 * np.sin(2 * np.pi * 1.8 * tt) + 0.07 * np.sin(2 * np.pi * 3.6 * tt + 0.3)
            acc[a:b, 0] += 0.35 * np.sin(2 * np.pi * 0.9 * tt)
            acc[a:b, 1] += 0.08 * np.sin(2 * np.pi * 1.8 * tt + 1.0)
            gyr[a:b, 1] = 40.0 * np.sin(2 * np.pi * 0.9 * tt) + rng.normal(0, 2.0, b - a)
            gyr[a:b, 0] = 15.0 * np.sin(2 * np.pi * 1.8 * tt) + rng.normal(0, 2.0, b - a)
        else:
            raise ValueError(kind)
    a16 = np.clip(np.round(acc * _ACCEL_LSB), -32768, 32767).astype(np.int16)
    g16 = np.clip(np.round(gyr * _GYRO_LSB), -32768, 32767).astype(np.int16)
    cols = []
    for s in range(n_seconds):
        sl = slice(s * 100, (s + 1) * 100)
        cols.append(np.concatenate([a16[sl, 0], a16[sl, 1], a16[sl, 2], g16[sl, 0], g16[sl, 1], g16[sl, 2]]))
    return cols


def golden_request() -> Dict[str, Any]:
    n = HEAD_S + BODY_S + TAIL_S
    cols = synth_columns(n, 20261005, [("still", 36), ("seated", 30), ("walk", 36)])
    b64 = [encode_columns_b64(c) for c in cols]
    return {"id": REQUEST_ID, "op": "infer", "run": {
        "start_ts": T0, "end_ts": T0 + BODY_S, "sample_rate_hz": 100,
        "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
        "columns_b64": b64[HEAD_S:HEAD_S + BODY_S], "head_b64": b64[:HEAD_S], "tail_b64": b64[HEAD_S + BODY_S:],
        "hop_s": 5}}


def _reference_embeddings(encoder) -> np.ndarray:
    n = 300
    cols = synth_columns(n, 7, [("walk", 60), ("still", 80), ("seated", 90), ("walk", 70)])
    seconds = [(T0 + 10_000 + i, c) for i, c in enumerate(cols)]
    windows = windows_from_seconds(seconds, T0 + 10_000, T0 + 10_000 + n, 30, 5)
    emb = encoder.embed(np.stack([w.data for w in windows]))
    return np.round(emb.astype(np.float64), 5)


def golden_prep() -> Dict[str, Any]:
    with open(GOLDEN_FRAMES) as f:
        frames = json.load(f)["frames"]
    seconds = [decode_frame_hex(hx) for hx in frames]
    start, end = seconds[0][0], seconds[-1][0] + 1
    windows = windows_from_seconds(seconds, start, end, 10, 1)
    return {"_note": "inertia-prep-1 of fixtures/golden_imu_frames.json (window 10 s, hop 1 s); data [3, 200] "
                     "float32 rounded to 7 decimals; regenerate with python -m activity_context.inertia.make_golden",
            "source": "golden_imu_frames.json", "start_ts": start, "end_ts": end, "window_s": 10, "hop_s": 1,
            "windows": [{"s": w.s, "e": w.e, "data": np.round(w.data.astype(np.float64), 7).tolist()}
                        for w in windows]}


def regenerate(out_dir: str) -> None:
    from .adapter import Inertia1Encoder, make_test_checkpoint
    from .bundle import encoder_block
    from .runtime import build_runtime, handle_request
    from .synthetic import synthetic_bundle_parts

    os.makedirs(out_dir, exist_ok=True)
    ckpt = os.path.join(out_dir, "encoder_tiny.ckpt")
    cfg = make_test_checkpoint(ckpt, "ar_transformer", "tiny", 30, 0, encoder_id=ENCODER_ID)
    cfg["notes"] = "GOLDEN FIXTURE ONLY: seeded random init of the vendored ART (tiny); NOT Inertia-1"
    enc = Inertia1Encoder(ckpt, cfg)
    parts = synthetic_bundle_parts(encoder=encoder_block(enc.info), reference=_reference_embeddings(enc),
                                   seed=0, window_s=30, hop_s=5, ood_method="knn", k=3, bundle_id=BUNDLE_ID)
    bdir = os.path.join(out_dir, "bundle_tiny")
    if os.path.isdir(bdir):
        shutil.rmtree(bdir)
    write_bundle(bdir, **parts, extra_files={"encoder.json": json_bytes(cfg)})
    req = golden_request()
    rt = build_runtime(bdir, checkpoint=ckpt, allow_standin_shadow=True)
    if rt.error is not None:
        raise RuntimeError(f"golden runtime failed to load: {rt.error}")
    resp = handle_request(rt, req)
    resp["duration_ms"] = 0
    for name, obj in (("golden_motion_heads_request.json", req), ("golden_motion_heads_response.json", resp),
                      ("golden_inertia_prep.json", golden_prep())):
        with open(os.path.join(out_dir, name), "wb") as f:
            f.write(json_bytes(obj))


def compare_json(a: Any, b: Any, path: str = "$", tol: float = 1e-6) -> List[str]:
    """Structural diff; floats compared within ``tol`` (+1e-9 for 6-decimal rounding flips)."""
    if isinstance(a, dict) and isinstance(b, dict):
        if sorted(a) != sorted(b):
            return [f"{path}: keys {sorted(set(a) ^ set(b))} differ"]
        return [d for k in a for d in compare_json(a[k], b[k], f"{path}.{k}", tol)]
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return [f"{path}: length {len(a)} != {len(b)}"]
        return [d for i, (x, y) in enumerate(zip(a, b)) for d in compare_json(x, y, f"{path}[{i}]", tol)]
    if isinstance(a, float) or isinstance(b, float):
        ok = (isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool)
              and not isinstance(b, bool) and math.isfinite(a) and abs(a - b) <= tol + 1e-9)
        return [] if ok else [f"{path}: {a!r} != {b!r}"]
    return [] if (type(a) is type(b) and a == b) else [f"{path}: {a!r} != {b!r}"]


def check(committed_dir: str = FIXTURE_DIR) -> List[str]:
    tmp = tempfile.mkdtemp(prefix="inertia-golden-")
    try:
        regenerate(tmp)
        diffs: List[str] = []
        for name in ("golden_motion_heads_request.json", "golden_motion_heads_response.json",
                     "golden_inertia_prep.json", os.path.join("bundle_tiny", "manifest.json"),
                     os.path.join("bundle_tiny", "encoder.json")):
            with open(os.path.join(committed_dir, name)) as f1, open(os.path.join(tmp, name)) as f2:
                diffs += [f"{name}: {d}" for d in compare_json(json.load(f1), json.load(f2))]
        return diffs
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Regenerate the Inertia golden fixtures (synthetic; not Inertia-1)")
    ap.add_argument("--out", default=FIXTURE_DIR)
    ap.add_argument("--check", action="store_true", help="compare a fresh regeneration with --out")
    args = ap.parse_args(argv)
    if args.check:
        diffs = check(args.out)
        print("\n".join(diffs) if diffs else "golden fixtures match")
        return 1 if diffs else 0
    regenerate(args.out)
    print(f"wrote golden fixtures to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
