"""WISDM-2019 smartwatch (UCI 507; CC BY 4.0): LG G Watch accelerometer, m/s^2, nominally 20 Hz.

``raw/watch/accel/data_<subject>_accel_watch.txt`` rows ``subject,activity,timestamp_ns,x,y,z;``.
Each contiguous same-activity block is its own recording (activities were recorded separately; the
clock jumps between them, so WISDM yields no transition positives). The sample rate is **detected per
block** from the timestamps: ~8% of blocks run at ~50 Hz; a block is assigned the nearest nominal rate
in {20, 50} Hz and dropped (counted) if its measured rate is > 5% off. Watch clocks jitter, so blocks are
``uniform=False`` and windows.py regrids each run onto the nominal grid (runs split at steps > 0.25 s).
Placement: dominant wrist (side not recorded). Gyroscope files are not read.
"""

from __future__ import annotations

import glob
import os
import re
from typing import Iterator, List, Optional, Sequence

import numpy as np

from . import DatasetError, Recording, encode_labels, ms2_to_g, resolve_root

DATASET = "wisdm2019_watch"
LOADER_VERSION = "wisdm-loader-1"
from ..paths import wisdm_dir

DEFAULT_ROOT = wisdm_dir()          # $WISDM_DIR (the unpacked ``wisdm-dataset`` directory); "" if unconfigured
NOMINAL_RATES = (20.0, 50.0)
RATE_TOL = 0.05
MIN_BLOCK_S = 12.0
MAX_STEP_S = 0.25
REST_LABELS = ("D", "E")
_ROW = re.compile(r"^\s*(\d+),([A-S]),(-?\d+),([^,]+),([^,]+),([^,;]+);?\s*$")


def _path(root: str, subject: str) -> str:
    return os.path.join(root, "raw", "watch", "accel", f"data_{subject}_accel_watch.txt")


def list_units(root: Optional[str] = None) -> List[str]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    return sorted(re.findall(r"data_(\d+)_accel_watch", os.path.basename(p))[0]
                  for p in glob.glob(_path(root, "*")))


def parse_file(path: str):
    acts, ts, xyz, bad = [], [], [], 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = _ROW.match(line)
            if not m:
                bad += 1 if line.strip() else 0
                continue
            try:
                v = (float(m.group(4)), float(m.group(5)), float(m.group(6)))
            except ValueError:
                bad += 1
                continue
            acts.append(m.group(2))
            ts.append(int(m.group(3)))
            xyz.append(v)
    return np.array(acts), np.array(ts, np.int64), np.array(xyz, np.float64).reshape(-1, 3), bad


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    for subj in (subjects or list_units(root)):
        path = _path(root, str(subj))
        if not os.path.isfile(path):
            raise DatasetError(f"wisdm file missing: {path}")
        acts, ts, xyz, n_bad = parse_file(path)
        if not len(ts):
            continue
        dt = np.diff(ts)
        cut = np.flatnonzero((acts[1:] != acts[:-1]) | (dt <= 0) | (dt > 1e9)) + 1
        starts, ends = np.r_[0, cut], np.r_[cut, len(ts)]
        for bi, (a, b) in enumerate(zip(starts, ends)):
            t = ts[a:b].astype(np.float64) / 1e9
            dur = t[-1] - t[0] if b - a > 1 else 0.0
            if dur < MIN_BLOCK_S:
                continue
            fs = (b - a - 1) / dur
            nominal = min(NOMINAL_RATES, key=lambda r: abs(r - fs))
            if abs(fs - nominal) / nominal > RATE_TOL:
                continue
            codes, names = encode_labels(acts[a:b])
            yield Recording(dataset=DATASET, subject=f"{DATASET}:{subj}", session=f"{DATASET}:{subj}:b{bi:03d}",
                            placement="wrist_dominant", device="LG G Watch", wrist_side="unknown",
                            axis_frame="Android watch sensor frame", source_hz=nominal, t=t,
                            xyz_g=ms2_to_g(xyz[a:b]), labels=codes, label_names=names, uniform=False,
                            max_step_s=MAX_STEP_S,
                            meta={"loader": LOADER_VERSION, "units_native": "m/s^2", "measured_hz": round(float(fs), 3),
                                  "n_unparsed_rows_in_file": n_bad})
