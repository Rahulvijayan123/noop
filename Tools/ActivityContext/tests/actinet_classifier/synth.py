"""Bit-stable synthetic inputs for the ActiNet classifier tests and their upstream goldens.

Everything is made with integer arithmetic (a splitmix64 counter hash and integer waves), so the int16 accelerometer
counts are identical under any numpy version, platform or SIMD path. The goldens are made in an offline environment
with numpy 1.24 and upstream actinet 0.7.2 (``fixtures/actinet_classifier/README.md``); the tests rebuild exactly
the same input. No pytest or torch import here: the golden generator imports this module too.
"""

from __future__ import annotations

import base64
from typing import Dict, List, Sequence, Tuple

import numpy as np

T0 = 1_760_000_040                 # a multiple of 30 s
FS = 100
G = 4096                           # counts per g (WHOOP i16 at 1/4096 g)

_M = np.uint64(0xFFFFFFFFFFFFFFFF)


def splitmix(n: int, seed: int) -> np.ndarray:
    """uint64 [n] splitmix64 of the counters ``seed * 2**32 + 0..n-1``."""
    with np.errstate(over="ignore"):
        x = (np.uint64(seed) << np.uint64(32)) + np.arange(n, dtype=np.uint64)
        z = x + np.uint64(0x9E3779B97F4A7C15)
        z = (z ^ (z >> np.uint64(30))) * np.uint64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> np.uint64(27))) * np.uint64(0x94D049BB133111EB)
        return z ^ (z >> np.uint64(31))


def int_noise(n: int, amp: int, seed: int) -> np.ndarray:
    """int64 [n] uniform integers in [-amp, amp]."""
    if amp <= 0:
        return np.zeros(n, np.int64)
    return (splitmix(n, seed) % np.uint64(2 * amp + 1)).astype(np.int64) - amp


def triangle(n: int, period: int, amp: int, phase: int = 0) -> np.ndarray:
    """int64 [n] integer triangle wave in [-amp, amp] with an integer period (samples)."""
    k = (np.arange(n, dtype=np.int64) + phase) % period
    half = period // 2
    up = np.where(k < half, k, period - k)                       # 0..half..0
    return (up * 2 * amp) // max(1, half) - amp


KINDS = ("still", "sleep", "desk", "walk", "run", "cycle")


def counts(n_seconds: int, kind: str, seed: int) -> np.ndarray:
    """int16 [n_seconds * 100, 3] accelerometer counts (x, y, z) of one synthetic activity."""
    n = int(n_seconds) * FS
    g = np.zeros((n, 3), np.int64)
    if kind in ("still", "sleep"):
        g[:, 0], g[:, 1], g[:, 2] = 300, -2600, 3150               # a resting wrist orientation (~1 g)
        amp = 6 if kind == "sleep" else 20
        for a in range(3):
            g[:, a] += int_noise(n, amp, seed * 3 + a)
    elif kind == "desk":
        g[:, 0], g[:, 1], g[:, 2] = -800, 1200, 3800
        for a in range(3):
            g[:, a] += triangle(n, 230 + 40 * a, 120, phase=17 * a) + int_noise(n, 60, seed * 3 + a)
    elif kind == "walk":
        g[:, 0], g[:, 1], g[:, 2] = 200, -3900, 900
        g[:, 0] += triangle(n, 111, 1400)                          # 0.9 Hz arm swing
        g[:, 1] += triangle(n, 56, 900, phase=11)                  # 1.8 Hz steps
        g[:, 2] += triangle(n, 56, 600, phase=29)
        for a in range(3):
            g[:, a] += int_noise(n, 150, seed * 3 + a)
    elif kind == "run":
        g[:, 0], g[:, 1], g[:, 2] = 600, -3500, 1500
        g[:, 0] += triangle(n, 74, 3500)                           # 1.35 Hz arm swing
        g[:, 1] += triangle(n, 37, 2800, phase=5)                  # 2.7 Hz impacts
        g[:, 2] += triangle(n, 37, 1900, phase=13)
        for a in range(3):
            g[:, a] += int_noise(n, 500, seed * 3 + a)
    elif kind == "cycle":
        g[:, 0], g[:, 1], g[:, 2] = 2500, -1500, 2800
        g[:, 0] += triangle(n, 125, 300)
        g[:, 2] += triangle(n, 125, 250, phase=31)
        for a in range(3):
            g[:, a] += int_noise(n, 200, seed * 3 + a)
    else:
        raise ValueError(f"unknown kind {kind!r}")
    return np.clip(g, -32768, 32767).astype(np.int16)


def columns(acc: np.ndarray) -> List[np.ndarray]:
    """int16 [T * 100, 3] counts -> T NPB1 seconds (int16[600]: ax, ay, az x 100, gyro zero)."""
    t = acc.shape[0] // FS
    out = []
    for s in range(t):
        blk = acc[s * FS:(s + 1) * FS]
        out.append(np.concatenate([blk.T.reshape(-1), np.zeros(3 * FS, np.int16)]).astype(np.int16))
    return out


def b64(cols: np.ndarray) -> str:
    return base64.b64encode(np.asarray(cols, dtype="<i2").tobytes()).decode("ascii")


# A request of six runs (start offset s from T0, duration s, activity, seed). Runs 0-4 start on the 30 s grid of
# T0, so upstream (one grid from the first sample) and the served per-run grid give the same epochs there. Run 5
# starts 15 s off the grid (the two grids differ) and ends 20 s into a bin (upstream wrap-pads that last bin). Gaps of 2-5 min mimic the WHOOP 60 s / 180 s duty cycle; run 2
# is long and continuous.
E2E_SPEC: Tuple[Tuple[int, int, str, int], ...] = (
    (0, 75, "sleep", 1),
    (180, 60, "sleep", 2),
    (360, 330, "walk", 3),
    (900, 90, "desk", 4),
    (1080, 120, "run", 5),
    (1335, 95, "cycle", 6),
)


def spec_runs(spec: Sequence[Tuple[int, int, str, int]] = E2E_SPEC, t0: int = T0) -> List[Dict]:
    """[{start_ts, end_ts, counts}] for each run of ``spec``."""
    return [{"start_ts": t0 + off, "end_ts": t0 + off + dur, "counts": counts(dur, kind, seed)}
            for off, dur, kind, seed in spec]


def wire_runs(spec: Sequence[Tuple[int, int, str, int]] = E2E_SPEC, t0: int = T0) -> List[Dict]:
    """The ``runs`` list of an infer request for ``spec``."""
    out = []
    for r in spec_runs(spec, t0):
        out.append({"start_ts": r["start_ts"], "end_ts": r["end_ts"], "sample_rate_hz": FS,
                    "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"], "units": {"accel": "g", "gyro": "deg/s"},
                    "columns_b64": [b64(c) for c in columns(r["counts"])]})
    return out


def contiguous_float32(n_seconds: int, seed: int) -> np.ndarray:
    """float32 [n * 100, 3] g of one contiguous mixed segment (walk, desk, run, still in turn), exact in float32."""
    kinds = ("walk", "desk", "run", "still")
    parts = [counts(10, kinds[i % 4], seed + i) for i in range((n_seconds + 9) // 10)]
    acc = np.concatenate(parts, axis=0)[: n_seconds * FS]
    return (acc.astype(np.float64) / G).astype(np.float32)


def hmm_cases(k: int, seed: int) -> Dict:
    """Synthetic HMM parameters (float32 emission, float64 transition with structural zeros, float64 prior)."""
    u = (splitmix(3 * k * k + k, seed) >> np.uint64(11)).astype(np.float64) * (2.0 ** -53)
    em = u[:k * k].reshape(k, k) + np.eye(k) * 2.0
    em = (em / em.sum(axis=1, keepdims=True)).astype(np.float32)
    tr = u[k * k:2 * k * k].reshape(k, k) * 0.05 + np.eye(k) * 0.9
    tr[0, k - 1] = 0.0                                          # forbidden transitions, as in the real artifact
    tr[k - 1, 1] = 0.0
    tr = tr / tr.sum(axis=1, keepdims=True)
    pr = u[2 * k * k:2 * k * k + k] + 0.1
    pr = pr / pr.sum()
    return {"emission": em, "transition": tr, "prior": pr}


__all__ = ["T0", "FS", "G", "splitmix", "int_noise", "triangle", "KINDS", "counts", "columns", "b64", "E2E_SPEC",
           "spec_runs", "wire_runs", "contiguous_float32", "hmm_cases"]
