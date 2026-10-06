"""Shared deterministic builders for the Inertia tests (imports are lazy so skips stay clean)."""

import json
import os
import subprocess
import sys

import numpy as np

PKG = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES = os.path.join(PKG, "fixtures")
INERTIA_FIXTURES = os.path.join(FIXTURES, "inertia")
T0 = 1758000000


def seconds_from_columns(cols, start_ts):
    return [(start_ts + i, c) for i, c in enumerate(cols)]


def constant_columns(n, ax=0.0, ay=0.0, az=1.0, gyro=0.0):
    out = []
    for _ in range(n):
        c = np.zeros(600, dtype=np.int16)
        c[0:100], c[100:200], c[200:300] = int(round(ax * 4096)), int(round(ay * 4096)), int(round(az * 4096))
        c[300:600] = int(round(gyro * 32768 / 2000))
        out.append(c)
    return out


def synth(n, seed=0, segments=None):
    from activity_context.inertia.make_golden import synth_columns
    segments = segments or [("still", n // 3), ("seated", n // 3), ("walk", n - 2 * (n // 3))]
    return synth_columns(n, seed, segments)


def request_for(cols, start_ts=T0, head=1, tail=1, hop_s=None, req_id="r1"):
    """Infer request: the first ``head`` and last ``tail`` columns become head_b64/tail_b64."""
    from activity_context.preprocess import encode_columns_b64
    b64 = [encode_columns_b64(c) for c in cols]
    body = b64[head:len(b64) - tail]
    run = {"start_ts": start_ts, "end_ts": start_ts + len(body), "sample_rate_hz": 100,
           "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
           "columns_b64": body, "head_b64": b64[:head], "tail_b64": b64[len(b64) - tail:]}
    if hop_s is not None:
        run["hop_s"] = hop_s
    return {"id": req_id, "op": "infer", "run": run}


def reference_embeddings(encoder, n_seconds=200, seed=3, window_s=30):
    from activity_context.inertia.preprocess import stack_windows, windows_from_seconds
    cols = synth(n_seconds, seed)
    w = windows_from_seconds(seconds_from_columns(cols, T0), T0, T0 + n_seconds, window_s, 5)
    return encoder.embed(stack_windows(w)).astype(np.float64)


def write_standin_bundle(out_dir, encoder, window_s=30, hop_s=5, ood_method="knn", **kw):
    from activity_context.inertia.bundle import encoder_block, write_bundle
    from activity_context.inertia.synthetic import synthetic_bundle_parts
    parts = synthetic_bundle_parts(encoder=encoder_block(encoder.info),
                                   reference=reference_embeddings(encoder, window_s=window_s),
                                   window_s=window_s, hop_s=hop_s, ood_method=ood_method)
    return write_bundle(out_dir, **parts, **kw)


def tiny_art(tmp_path, window_s=30, seed=0, name="tiny.ckpt", **kw):
    """(checkpoint path, encoder config dict) for a seeded random-init tiny ART (NOT Inertia-1)."""
    from activity_context.inertia.adapter import make_test_checkpoint
    path = os.path.join(str(tmp_path), name)
    return path, make_test_checkpoint(path, kw.pop("method", "ar_transformer"), kw.pop("preset", "tiny"),
                                      window_s, seed, **kw)


def env():
    e = dict(os.environ)
    e["PYTHONPATH"] = PKG + os.pathsep + e.get("PYTHONPATH", "")
    return e


class Serve:
    """A live ``python -m activity_context.inertia.serve`` subprocess."""

    def __init__(self, *args):
        self.proc = subprocess.Popen([sys.executable, "-m", "activity_context.inertia.serve", *args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env(), text=True, bufsize=1)

    def send_line(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        out = self.proc.stdout.readline()
        assert out, "serve process closed stdout: " + self.proc.stderr.read()
        return json.loads(out)

    def send(self, req):
        return self.send_line(json.dumps(req))

    def close(self):
        if self.proc.poll() is None:
            try:
                self.send({"id": "bye", "op": "shutdown"})
                self.proc.wait(timeout=20)
            except Exception:
                self.proc.kill()
        for s in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            s.close()
