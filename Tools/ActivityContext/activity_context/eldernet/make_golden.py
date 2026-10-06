"""Regenerate the ElderNet golden fixtures (``Tools/ActivityContext/fixtures/eldernet``).

    python -m activity_context.eldernet.make_golden [--out DIR] [--check]
        (needs $ELDERNET_UPSTREAM_DIR for the toy recording and $ELDERNET_WEIGHTS_DIR for the response)

* ``golden_gait_quality_request.json`` — a WHOOP-format infer request (1 s head + 90 s body + 1 s tail of NPB1
  columns, i16 at 4096 LSB/g, gyro zero, ``hop_s`` 5). Body = 20 s of a synthetic device at rest (seeded:
  slight tilt + 2 mg noise; it exercises the static pre-filter) followed by 70 s of REAL public wrist data:
  seconds [12, 82) of upstream's committed toy recording ``examples/toy_wrist.csv.gz`` (Mobilise-D TVS v1.0.2,
  participant PD4010, INDIP left wrist, 100 Hz, in g; CC BY 4.0 — Del Din et al. 2025,
  doi:10.5281/zenodo.15861907), which contains upstream's detected bout 1 (toy 20-39 s) and the start of
  bout 2 (toy 50 s). The head second is synthetic rest, the tail second is toy second 82. Axes: toy x, y, z ->
  WHOOP ax, ay, az unchanged. No personal or WHOOP-user data.
* ``golden_gait_quality_response.json`` — the exact ``gait-quality-1`` response of the serve runtime (real
  pinned weights, no calibration, threshold 0.5) with ``duration_ms`` pinned to 0.

``--check`` regenerates into a temporary directory and compares with the committed files (request exactly,
response floats within 1e-6); exit status 1 on any mismatch. EN-S's Swift decoder test decodes the response.
"""

from __future__ import annotations

import argparse
import csv
import gzip
import hashlib
import json
import os
import sys
import tempfile
from typing import Any, Dict, Optional

import numpy as np

from ..preprocess import encode_columns_b64

T0 = 1758000000
TOY_MD5 = "cc1e841348a5b060af2da9d81c486248"
TOY_SECONDS = (12, 83)            # 70 s body + 1 s tail
STILL_SECONDS = 21                # 1 s head + 20 s body
HOP_S = 5
FIXTURE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fixtures", "eldernet")
REQUEST_NAME = "golden_gait_quality_request.json"
RESPONSE_NAME = "golden_gait_quality_response.json"


def read_toy(upstream_dir: str) -> np.ndarray:
    path = os.path.join(upstream_dir, "examples", "toy_wrist.csv.gz")
    with open(path, "rb") as f:
        raw = f.read()
    if hashlib.md5(raw).hexdigest() != TOY_MD5:
        raise SystemExit(f"{path}: md5 differs from upstream examples/README.md ({TOY_MD5})")
    rows = list(csv.reader(gzip.decompress(raw).decode("utf-8").splitlines()))
    head = rows[0]
    cols = [head.index(c) for c in ("x", "y", "z")]
    return np.array([[float(r[c]) for c in cols] for r in rows[1:]], dtype=np.float64)


def still_g(n_seconds: int, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    base = np.array([0.06, -0.12, 0.99])
    return base + rng.normal(0.0, 0.002, (n_seconds * 100, 3))


def g_to_columns(acc: np.ndarray) -> list:
    q = np.clip(np.rint(np.asarray(acc) * 4096.0), -32768, 32767).astype(np.int16)
    out = []
    for s in range(q.shape[0] // 100):
        c = np.zeros(600, dtype=np.int16)
        blk = q[s * 100:(s + 1) * 100]
        c[0:100], c[100:200], c[200:300] = blk[:, 0], blk[:, 1], blk[:, 2]
        out.append(c)
    return out


def build_request(upstream_dir: str) -> Dict[str, Any]:
    toy = read_toy(upstream_dir)
    a, b = TOY_SECONDS
    acc = np.concatenate([still_g(STILL_SECONDS), toy[a * 100:b * 100]])
    b64 = [encode_columns_b64(c) for c in g_to_columns(acc)]
    body = b64[1:-1]
    return {"id": "golden-gait-quality-1", "op": "infer",
            "run": {"start_ts": T0, "end_ts": T0 + len(body), "sample_rate_hz": 100,
                    "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
                    "columns_b64": body, "head_b64": b64[:1], "tail_b64": b64[-1:], "hop_s": HOP_S}}


def build_response(request: Dict[str, Any], weights_dir: Optional[str]) -> Dict[str, Any]:
    from .runtime import build_runtime, handle_request
    rt = build_runtime(weights_dir)
    if not rt.available:
        raise SystemExit(f"weights unavailable: {rt.error.kind}: {rt.error.message}")
    resp = handle_request(rt, request)
    resp["duration_ms"] = 0
    return resp


def write_json(path: str, doc: Dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2, sort_keys=True, allow_nan=False)
        f.write("\n")


def generate(out_dir: str, upstream_dir: str, weights_dir: Optional[str]) -> None:
    os.makedirs(out_dir, exist_ok=True)
    req = build_request(upstream_dir)
    write_json(os.path.join(out_dir, REQUEST_NAME), req)
    write_json(os.path.join(out_dir, RESPONSE_NAME), build_response(req, weights_dir))


def _close(a: Any, b: Any, tol: float = 1e-6) -> bool:
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_close(a[k], b[k], tol) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_close(x, y, tol) for x, y in zip(a, b))
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) <= tol
    return a == b


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Regenerate / check the ElderNet golden fixtures")
    ap.add_argument("--out", default=FIXTURE_DIR)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--upstream-dir", default=os.environ.get("ELDERNET_UPSTREAM_DIR", ""))
    ap.add_argument("--weights-dir", default=None)
    args = ap.parse_args(argv)
    if not args.upstream_dir:
        ap.error("--upstream-dir or $ELDERNET_UPSTREAM_DIR is required (the toy recording)")
    if not args.check:
        generate(args.out, args.upstream_dir, args.weights_dir)
        print(f"wrote {REQUEST_NAME}, {RESPONSE_NAME} -> {args.out}", file=sys.stderr)
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        generate(tmp, args.upstream_dir, args.weights_dir)
        bad = []
        for name in (REQUEST_NAME, RESPONSE_NAME):
            with open(os.path.join(tmp, name)) as f1, open(os.path.join(args.out, name)) as f2:
                new, old = json.load(f1), json.load(f2)
            if not (new == old if name == REQUEST_NAME else _close(new, old)):
                bad.append(name)
    print("golden check: " + ("OK" if not bad else f"MISMATCH {bad}"), file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
