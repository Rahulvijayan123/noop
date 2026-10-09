"""Shared deterministic builders for the RecGym tests (torch / weights imported lazily so skips stay clean)."""

import json
import os
import subprocess
import sys

import numpy as np
import pytest

PKG = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURES = os.path.join(PKG, "fixtures", "recgym")
T0 = 1758000000                     # even


def weights_path_or_skip():
    p = os.environ.get("RECGYM_WEIGHTS_PATH", "").strip()
    if not p or not os.path.exists(p):
        pytest.skip("RECGYM_WEIGHTS_PATH not set (the RecGym checkpoint is never committed)")
    return p


def golden():
    with open(os.path.join(FIXTURES, "golden_upstream.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def imu_to_columns(acc_g, gyro_dps=None):
    """[T*100, 3] g (+ optional [T*100, 3] deg/s) -> T int16 NPB1 columns (round(g * 4096), round(dps * 16.384))."""
    acc = np.asarray(acc_g, np.float64)
    T = acc.shape[0] // 100
    gyr = np.zeros_like(acc) if gyro_dps is None else np.asarray(gyro_dps, np.float64)
    qa = np.clip(np.rint(acc[:T * 100] * 4096.0), -32768, 32767).astype(np.int16)
    qg = np.clip(np.rint(gyr[:T * 100] * 32768.0 / 2000.0), -32768, 32767).astype(np.int16)
    out = []
    for s in range(T):
        c = np.zeros(600, dtype=np.int16)
        a, g = qa[s * 100:(s + 1) * 100], qg[s * 100:(s + 1) * 100]
        c[0:100], c[100:200], c[200:300] = a[:, 0], a[:, 1], a[:, 2]
        c[300:400], c[400:500], c[500:600] = g[:, 0], g[:, 1], g[:, 2]
        out.append(c)
    return out


def synth_imu(n_seconds, kind="curl", seed=0, fs=100):
    """([n*fs, 3] g, [n*fs, 3] deg/s). ``still``: gravity on z + noise; ``curl``: a 0.5 Hz rotation about x
    (+-60 deg) with gravity rotating consistently; ``walk``: arm swing + step impacts."""
    rng = np.random.default_rng(seed)
    t = np.arange(int(n_seconds * fs)) / fs
    if kind == "curl":
        ang = np.deg2rad(60.0) * np.sin(2 * np.pi * 0.5 * t)
        rate = np.rad2deg(np.deg2rad(60.0) * 2 * np.pi * 0.5 * np.cos(2 * np.pi * 0.5 * t))
        acc = np.stack([np.zeros_like(t), np.sin(ang), np.cos(ang)], axis=1)
        gyr = np.stack([rate, np.zeros_like(t), np.zeros_like(t)], axis=1)
    elif kind == "walk":
        acc = np.zeros((t.size, 3))
        acc[:, 2] = 1.0
        acc[:, 0] += 0.35 * np.sin(2 * np.pi * 0.9 * t)
        acc[:, 2] += 0.25 * np.sin(2 * np.pi * 1.8 * t) ** 3
        gyr = np.zeros((t.size, 3))
        gyr[:, 1] = 40.0 * np.sin(2 * np.pi * 0.9 * t)
    else:
        acc = np.zeros((t.size, 3))
        acc[:, 2] = 1.0
        gyr = np.zeros((t.size, 3))
    acc = acc + rng.normal(0, 0.003, acc.shape)
    gyr = gyr + rng.normal(0, 0.2, gyr.shape)
    return acc, gyr


def seconds_from_columns(cols, start_ts=T0):
    return [(start_ts + i, c) for i, c in enumerate(cols)]


def request_for(cols, start_ts=T0, head=0, tail=0, req_id="r1"):
    """``cols`` cover [start_ts, start_ts + len(cols)); the first ``head`` / last ``tail`` seconds become context."""
    from activity_context.preprocess import encode_columns_b64
    b64 = [encode_columns_b64(c) for c in cols]
    body = b64[head:len(b64) - tail]
    body_start = start_ts + head
    run = {"start_ts": body_start, "end_ts": body_start + len(body), "sample_rate_hz": 100,
           "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
           "columns_b64": body, "head_b64": b64[:head], "tail_b64": b64[len(b64) - tail:]}
    return {"id": req_id, "op": "infer", "run": run}


class FakeModel:
    """Deterministic, batch-independent stand-in for RecGymModel (NOT the RecGym model): logits from window means."""

    def __init__(self, nonfinite_first=False):
        self.nonfinite_first = nonfinite_first
        self.calls = []

    def logits(self, scaled):
        x = np.asarray(scaled, np.float64)
        self.calls.append(len(x))
        m = x.mean(axis=1)                                        # (N, 6)
        out = np.concatenate([m, -m], axis=1)                     # (N, 12)
        if self.nonfinite_first and len(out):
            out[0, 0] = np.nan
        return out


def env(extra=None):
    """Child environment for test subprocesses: an explicit allowlist, never the full os.environ."""
    from activity_context.inertia.subproc import PYTHON_ENV_ALLOWLIST, safe_env
    e = {"PYTHONPATH": PKG + os.pathsep + os.environ.get("PYTHONPATH", "")}
    e.update(extra or {})
    return safe_env(e, PYTHON_ENV_ALLOWLIST + ("RECGYM_WEIGHTS_PATH",))


class Serve:
    """A live ``python -m activity_context.recgym.serve`` subprocess."""

    def __init__(self, *args, extra_env=None):
        self.proc = subprocess.Popen([sys.executable, "-m", "activity_context.recgym.serve", *args],
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
