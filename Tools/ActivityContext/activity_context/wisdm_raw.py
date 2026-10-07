"""The simple WISDM v2 raw-file reader the transition expert (``transition_data``) is built on.

Rows are merged accel + gyro as-of (<= 100 ms), split into contiguous activity-letter blocks on > 1 s gaps, at
the nominal 20 Hz. The HART training pipeline (``train.py``) uses the measured-rate loader in ``wisdm.py``
instead; this module keeps the transition expert's inputs exactly as they were trained.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Tuple

import numpy as np

from .preprocess import TARGET_HZ, resample_poly_nd

M_S2_TO_G = 1.0 / 9.80665
RAD_S_TO_DEG_S = 180.0 / math.pi

ASOF_MAX_DT_NS = 100_000_000       # 100 ms merge tolerance (WHAR asof)
SESSION_GAP_NS = 1_000_000_000     # >1 s gap splits a session
WISDM_HZ = 20


@dataclass
class Block:
    """One contiguous same-activity WISDM session block."""
    subject: int
    activity: str
    samples: np.ndarray            # (T, 6) float64, 20 Hz, canonical units
    duration_s: float
    start_ts_s: float              # real block start (unix seconds, ts_ns/1e9)


def parse_raw_file(path: str) -> np.ndarray:
    """Parse a WISDM raw file (subject,activity,ts_ns,x,y,z;) -> structured."""
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip().rstrip(";").strip()
            if not line:
                continue
            parts = line.split(",")
            if len(parts) != 6:
                continue
            try:
                subj = int(parts[0])
                ts = int(parts[2])
                xyz = [float(p) for p in parts[3:6]]
            except ValueError:
                continue
            rows.append((subj, parts[1], ts, xyz[0], xyz[1], xyz[2]))
    if not rows:
        raise ValueError(f"no parseable rows in {path}")
    return np.array(rows, dtype=object)


def blocks_for_subject(accel_path: str, gyro_path: str) -> List[Block]:
    """Merge accel+gyro rows asof (<=100 ms) and split into activity blocks."""
    acc = parse_raw_file(accel_path)
    gyr = parse_raw_file(gyro_path)
    # Group rows by contiguous (subject, activity) with ts gaps <= 1 s.
    blocks: List[Block] = []
    cur_activity = None
    cur_ts: List[int] = []
    cur_xyz: List[Tuple[float, float, float]] = []
    for row in acc:
        subj, act, ts = int(row[0]), str(row[1]), int(row[2])
        xyz = (float(row[3]), float(row[4]), float(row[5]))
        if cur_activity is not None and act == cur_activity and cur_ts \
                and ts - cur_ts[-1] <= SESSION_GAP_NS:
            cur_ts.append(ts)
            cur_xyz.append(xyz)
            continue
        if cur_activity is not None and cur_ts:
            blocks.append(_finish_block(subj, cur_activity, cur_ts, cur_xyz, gyr))
        cur_activity, cur_ts, cur_xyz = act, [ts], [xyz]
    if cur_activity is not None and cur_ts:
        blocks.append(_finish_block(subj, cur_activity, cur_ts, cur_xyz, gyr))
    return blocks


def _finish_block(subject: int, activity: str, ts_list: List[int],
                  xyz_list: List[Tuple[float, float, float]],
                  gyr: np.ndarray) -> Block:
    ts_arr = np.asarray(ts_list, dtype=np.int64)
    xyz_arr = np.asarray(xyz_list, dtype=np.float64)
    # gyro ts/xyz columns: index 2 = ts, 3..5 = xyz
    g_ts = np.asarray([int(r[2]) for r in gyr], dtype=np.int64)
    g_xyz = np.asarray([[float(r[3]), float(r[4]), float(r[5])] for r in gyr],
                       dtype=np.float64)
    idx = np.searchsorted(g_ts, ts_arr)
    idx = np.clip(idx, 0, len(g_ts) - 1)
    near = np.abs(g_ts[idx] - ts_arr) <= ASOF_MAX_DT_NS
    g_aligned = g_xyz[idx]
    g_aligned[~near] = 0.0  # unmatched gyro -> zero rotation (documented)
    samples = np.concatenate([xyz_arr * M_S2_TO_G, g_aligned * RAD_S_TO_DEG_S], axis=1)
    return Block(subject=subject, activity=activity, samples=samples,
                 duration_s=len(ts_arr) / WISDM_HZ,
                 start_ts_s=float(ts_list[0]) / 1e9)


def resample_block(block: Block) -> Block:
    """20 -> 30 Hz per block (anti-alias polyphase 3/2), keeping metadata."""
    out = resample_poly_nd(block.samples, 3, 2, axis=0)
    return Block(subject=block.subject, activity=block.activity, samples=out,
                 duration_s=len(out) / TARGET_HZ,
                 start_ts_s=block.start_ts_s)
