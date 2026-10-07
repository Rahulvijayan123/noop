"""Shared deterministic builders for the ElderNet tests (torch / weights imported lazily so skips stay clean)."""

import json
import os
import subprocess
import sys

import numpy as np
import pytest

PKG = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES = os.path.join(PKG, "fixtures", "eldernet")
T0 = 1758000000


def weights_dir_or_skip():
    d = os.environ.get("ELDERNET_WEIGHTS_DIR", "").strip()
    if not d or not os.path.isdir(d):
        pytest.skip("ELDERNET_WEIGHTS_DIR not set (real ElderNet weights are never committed)")
    return d


def upstream_dir_or_skip():
    """An upstream checkout with the toy example (``upstream fetch --with-examples`` or a full clone)."""
    d = os.environ.get("ELDERNET_UPSTREAM_DIR", "").strip()
    if not d or not os.path.isdir(os.path.join(d, "examples")):
        pytest.skip("ELDERNET_UPSTREAM_DIR (upstream gait-quality checkout) not set")
    return d


def upstream_source_or_skip():
    """The pinned upstream source (the model architecture is never in Nara's repository; ELDERNET.md §1)."""
    d = os.environ.get("ELDERNET_UPSTREAM_DIR", "").strip()
    if not d or not os.path.isfile(os.path.join(d, "models.py")):
        pytest.skip("ELDERNET_UPSTREAM_DIR not set (the upstream ElderNet source is fetched, never committed)")
    return d


def synth_g(n_seconds, kind="walk", seed=0, fs=100):
    """[n * fs, 3] float64 g. ``walk``: gravity + 0.9 Hz arm swing + 1.8 Hz step impacts; ``still``: gravity +
    0.002 g noise; ``fidget``: gravity + slow 0.2 Hz 0.02 g drift + noise (below the static ceiling)."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(n_seconds * fs)) / fs
    x = np.zeros((t.size, 3))
    x[:, 2] = 1.0
    if kind == "walk":
        x[:, 0] += 0.35 * np.sin(2 * np.pi * 0.9 * t)
        x[:, 1] += 0.15 * np.sin(2 * np.pi * 1.8 * t + 0.4)
        x[:, 2] += 0.25 * np.sin(2 * np.pi * 1.8 * t) ** 3
        x += rng.normal(0, 0.02, x.shape)
    elif kind == "fidget":
        x[:, 0] += 0.02 * np.sin(2 * np.pi * 0.2 * t)
        x += rng.normal(0, 0.005, x.shape)
    else:
        x += rng.normal(0, 0.002, x.shape)
    return x


def g_to_columns(acc_g):
    """[T*100, 3] g -> T int16 NPB1 columns (accel round(g * 4096), gyro zero)."""
    acc = np.asarray(acc_g, np.float64)
    T = acc.shape[0] // 100
    q = np.clip(np.rint(acc[:T * 100] * 4096.0), -32768, 32767).astype(np.int16)
    out = []
    for s in range(T):
        c = np.zeros(600, dtype=np.int16)
        blk = q[s * 100:(s + 1) * 100]
        c[0:100], c[100:200], c[200:300] = blk[:, 0], blk[:, 1], blk[:, 2]
        out.append(c)
    return out


def seconds_from_columns(cols, start_ts):
    return [(start_ts + i, c) for i, c in enumerate(cols)]


def request_for(cols, start_ts=T0, head=0, tail=0, hop_s=None, req_id="r1"):
    from activity_context.preprocess import encode_columns_b64
    b64 = [encode_columns_b64(c) for c in cols]
    body = b64[head:len(b64) - tail]
    run = {"start_ts": start_ts, "end_ts": start_ts + len(body), "sample_rate_hz": 100,
           "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
           "columns_b64": body, "head_b64": b64[:head], "tail_b64": b64[len(b64) - tail:]}
    if hop_s is not None:
        run["hop_s"] = hop_s
    return {"id": req_id, "op": "infer", "run": run}


class FakeHeads:
    """Deterministic, batch-independent stand-in for ElderNetHeads (NOT ElderNet): logits from window std."""

    def __init__(self, nonfinite_quality=False, nonfinite_detect=False, delay_s=0.0):
        self.nonfinite_quality = nonfinite_quality
        self.nonfinite_detect = nonfinite_detect
        self.delay_s = delay_s
        self.calls = []

    def detect(self, batch):
        import time
        if self.delay_s:
            time.sleep(self.delay_s)
        self.calls.append(("detect", len(batch)))
        sd = np.asarray(batch, np.float64).std(axis=1).mean(axis=1)
        z = 60.0 * (sd - 0.05)
        out = np.stack([np.zeros_like(z), z], axis=1)
        if self.nonfinite_detect:
            out[0, 1] = np.nan
        return out

    def quality(self, batch):
        self.calls.append(("quality", len(batch)))
        sd = np.asarray(batch, np.float64).std(axis=1).mean(axis=1)
        q = {"gait_speed": 4.0 * sd, "cadence": 100.0 + 10 * sd, "gait_length": 1.0 + sd,
             "regularity": 0.5 + sd, "step_count": 15.0 + sd}
        if self.nonfinite_quality:
            q["cadence"] = q["cadence"].copy()
            q["cadence"][0] = np.inf
        return q


_ENV_ALLOWLIST = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "SYSTEMROOT", "VIRTUAL_ENV")


def env(extra=None):
    """Child environment for test subprocesses: an explicit allowlist, never the full os.environ
    (so a developer's ELDERNET_* / ACTIVITY_* variables cannot leak into a test)."""
    e = {k: os.environ[k] for k in _ENV_ALLOWLIST if k in os.environ}
    e["PYTHONPATH"] = PKG + os.pathsep + os.environ.get("PYTHONPATH", "")
    e.update(extra or {})
    return e


class Serve:
    """A live ``python -m activity_context.eldernet.serve`` subprocess."""

    def __init__(self, *args, extra_env=None):
        self.proc = subprocess.Popen([sys.executable, "-m", "activity_context.eldernet.serve", *args],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env(extra_env), text=True, bufsize=1)

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
                self.proc.wait(timeout=30)
            except Exception:
                self.proc.kill()
        for s in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            s.close()
