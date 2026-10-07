"""The HART serve never imports torch, scipy or the Inertia package: an Inertia failure cannot reach it.

(``activity_context.serve.handle_ping`` *does* try ``import torch`` to report its version — pre-existing
behaviour of the pinned HART module — so the check covers import + infer, the data path.)
"""

import subprocess
import sys

from ._helpers import env

_CODE = r"""
import json, os, sys
import activity_context.serve as serve
from activity_context.preprocess import decode_frame_hex, encode_columns_b64
fx = os.path.join(os.path.dirname(serve.__file__), "..", "fixtures")
frames = json.load(open(os.path.join(fx, "golden_imu_frames.json")))["frames"]
cols = [encode_columns_b64(decode_frame_hex(h)[1]) for h in frames]
ctx = serve.build_context(os.path.join(fx, "manifest.baseline.json"), None)
resp = serve.handle_infer(ctx, {"run": {"start_ts": 1758000000, "end_ts": 1758000000 + len(cols),
                                       "columns_b64": cols}})
assert resp["ok"] and resp["windows"], resp
bad = sorted(m for m in sys.modules if m in ("torch", "scipy") or m.startswith("activity_context.inertia"))
print(json.dumps(bad))
assert not bad, bad
"""


def test_hart_serve_does_not_import_torch_scipy_or_inertia():
    r = subprocess.run([sys.executable, "-c", _CODE], env=env(), capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


def test_activity_context_package_does_not_pull_inertia():
    code = ("import sys, activity_context, activity_context.preprocess, activity_context.features; "
            "assert not [m for m in sys.modules if m.startswith('activity_context.inertia')]")
    r = subprocess.run([sys.executable, "-c", code], env=env(), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
