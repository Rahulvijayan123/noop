"""Lane isolation: the HART serve never imports ElderNet; the ElderNet serve never imports HART's model stack,
the Inertia lane, scipy or pandas (its preprocessing is numpy-only)."""

import subprocess
import sys

from ._helpers import env

_HART = r"""
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
bad = sorted(m for m in sys.modules if m.startswith("activity_context.eldernet"))
assert not bad, bad
"""

_ELDERNET = r"""
import json, sys
import activity_context.eldernet.serve as serve
from activity_context.eldernet.runtime import build_runtime, handle_request
rt = build_runtime("/nonexistent")
assert handle_request(rt, {"id": "p", "op": "ping"})["model_available"] is False
bad = sorted(m for m in sys.modules if m in ("scipy", "pandas", "transformers", "tsfm_public", "sklearn")
             or m.startswith("activity_context.inertia") or m == "activity_context.model")
print(json.dumps(bad))
assert not bad, bad
"""


def test_hart_serve_does_not_import_eldernet():
    r = subprocess.run([sys.executable, "-c", _HART], env=env(), capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


def test_eldernet_serve_imports_nothing_from_the_other_lanes():
    r = subprocess.run([sys.executable, "-c", _ELDERNET], env=env(), capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


def test_eldernet_constants_are_free_to_import():
    code = ("import sys, activity_context.eldernet as e; assert e.WIRE_SCHEMA == 'gait-quality-1'; "
            "assert not [m for m in ('torch', 'numpy') if m in sys.modules]")
    r = subprocess.run([sys.executable, "-c", code], env=env(), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
