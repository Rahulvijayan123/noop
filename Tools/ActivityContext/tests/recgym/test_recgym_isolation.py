"""Lane isolation: the HART serve never imports RecGym; the RecGym serve never imports HART's model stack, Inertia,
ElderNet, scipy, pandas or scikit-learn; the constants import without numpy or torch."""

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
bad = sorted(m for m in sys.modules if m.startswith("activity_context.recgym"))
assert not bad, bad
"""

_RECGYM = r"""
import json, sys
import activity_context.recgym.serve as serve
from activity_context.recgym.runtime import build_runtime, handle_request
rt = build_runtime("/nonexistent")
assert handle_request(rt, {"id": "p", "op": "ping"})["model_available"] is False
import numpy as np
from activity_context.recgym.preprocess import windows_from_seconds
cols = np.zeros(600, np.int16); cols[200:300] = 4096
windows_from_seconds([(1758000000 + i, cols) for i in range(12)], 1758000000, 1758000012)
bad = sorted(m for m in sys.modules if m in ("scipy", "pandas", "transformers", "tsfm_public", "sklearn")
             or m.startswith("activity_context.inertia.") and m != "activity_context.inertia.subproc"
             or m.startswith("activity_context.eldernet") or m == "activity_context.model"
             or m == "activity_context.recgym.vendor.recgym_data")
print(json.dumps(bad))
assert not bad, bad
"""


def test_hart_serve_does_not_import_recgym():
    r = subprocess.run([sys.executable, "-c", _HART], env=env(), capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


def test_recgym_serve_imports_nothing_from_the_other_lanes():
    r = subprocess.run([sys.executable, "-c", _RECGYM], env=env(), capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


def test_recgym_constants_are_free_to_import():
    code = ("import sys, activity_context.recgym as e; assert e.WIRE_SCHEMA == 'exercise-windows-1'; "
            "assert not [m for m in ('torch', 'numpy') if m in sys.modules]")
    r = subprocess.run([sys.executable, "-c", code], env=env(), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stdout + r.stderr
