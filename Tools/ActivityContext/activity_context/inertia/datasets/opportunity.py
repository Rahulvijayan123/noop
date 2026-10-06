"""OPPORTUNITY (UCI 226; CC BY 4.0): one wrist/forearm accelerometer per subject-session, milli-g, 30 Hz.

Several arm sensors record the same movement simultaneously, so exactly **one stream per session** is
used (no duplicated windows): the first of RWR (right wrist), LWR (left wrist), RLA (right forearm, Xsens),
LLA (left forearm) whose finite-sample fraction is >= 0.95, else the most complete one. The choice is
recorded in ``meta['stream']``. Clock: column 1 MILLISEC (33/34 ms steps = 30 Hz). NaN dropouts are
removed, which splits the run (never interpolated). Labels: the Locomotion track only (column 244;
``loc:0`` null, ``loc:1`` Stand, ``loc:2`` Walk, ``loc:4`` Sit, ``loc:5`` Lie). Xsens values were stored
as round(m/s^2 / 9.8 * 1000) by the dataset authors, i.e. already milli-g.
"""

from __future__ import annotations

import glob
import os
import re
from typing import Iterator, List, Optional, Sequence

import numpy as np

from . import HAR_ROOT, DatasetError, Recording, mg_to_g

DATASET = "opportunity"
LOADER_VERSION = "opportunity-loader-1"
DEFAULT_ROOT = os.path.join(HAR_ROOT, "opportunity", "OpportunityUCIDataset", "dataset")
FS = 30.0
MIN_FINITE = 0.95
# 0-based column indices (column_names.txt is 1-based)
STREAMS = (("RWR", (22, 23, 24), "wrist_right", "right", "Bluetooth accelerometer"),
           ("LWR", (31, 32, 33), "wrist_left", "left", "Bluetooth accelerometer"),
           ("RLA", (63, 64, 65), "forearm_right", "right", "Xsens IMU"),
           ("LLA", (89, 90, 91), "forearm_left", "left", "Xsens IMU"))
LOCO_COL = 243
LOCO_CODES = {0: "loc:0", 1: "loc:1", 2: "loc:2", 4: "loc:4", 5: "loc:5"}
REST_LABELS = ("loc:4", "loc:5")


def list_units(root: Optional[str] = None) -> List[str]:
    root = root or DEFAULT_ROOT
    return sorted(os.path.basename(p)[:-4] for p in glob.glob(os.path.join(root, "S*-*.dat")))


def choose_stream(stream_xyz):
    """Index into STREAMS of the session's stream, plus every stream's finite fraction."""
    fr = [float(np.isfinite(x).all(axis=1).mean()) for x in stream_xyz]
    for i, f in enumerate(fr):
        if f >= MIN_FINITE:
            return i, fr
    return int(np.argmax(fr)), fr


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    """``subjects`` here are session units like ``S1-ADL1`` (or subject ids ``S1`` = all its sessions)."""
    root = root or DEFAULT_ROOT
    units = list_units(root)
    if subjects:
        want = set(subjects)
        units = [u for u in units if u in want or u.split("-")[0] in want]
    names = [LOCO_CODES[k] for k in sorted(LOCO_CODES)]
    for unit in units:
        m = re.match(r"^(S\d+)-(.+)$", unit)
        if not m:
            raise DatasetError(f"unexpected opportunity file name {unit}")
        cols = sorted({0, LOCO_COL} | {c for _, cs, *_ in STREAMS for c in cs})
        a = np.genfromtxt(os.path.join(root, f"{unit}.dat"), usecols=cols)
        pos = {c: i for i, c in enumerate(cols)}
        idx, fr = choose_stream([a[:, [pos[c] for c in cs]] for _, cs, *_ in STREAMS])
        name, scols, placement, side, device = STREAMS[idx]
        xyz = a[:, [pos[c] for c in scols]]
        loco = a[:, pos[LOCO_COL]]
        ok = np.isfinite(xyz).all(axis=1) & np.isfinite(loco) & np.isfinite(a[:, pos[0]])
        lab = loco[ok].astype(int)
        bad = sorted(set(lab.tolist()) - set(LOCO_CODES))
        if bad:
            raise DatasetError(f"opportunity {unit}: unexpected locomotion codes {bad}")
        code_of = {k: i for i, k in enumerate(sorted(LOCO_CODES))}
        codes = np.array([code_of[v] for v in lab], np.int32)
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{m.group(1)}", session=f"{DATASET}:{unit}:{name}",
                        placement=placement, device=f"{device} ({name})", wrist_side=side,
                        axis_frame=f"{name} sensor native", source_hz=FS, t=a[ok, pos[0]] / 1000.0,
                        xyz_g=mg_to_g(xyz[ok]), labels=codes, label_names=names, uniform=True,
                        meta={"loader": LOADER_VERSION, "units_native": "milli-g", "stream": name,
                              "finite_fraction": {s[0]: round(f, 4) for s, f in zip(STREAMS, fr)}})
