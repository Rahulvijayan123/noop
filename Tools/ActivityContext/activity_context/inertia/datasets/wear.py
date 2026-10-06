"""WEAR (Bock, Kuehne, Van Laerhoven & Moeller 2024, IMWUT 8(4) 175, doi:10.1145/3699776; CC BY-NC-SA 4.0):
outdoor workouts, Bangle.js smartwatches on both wrists (and both ankles) in a fixed orientation.

Trained on since the owner's licence decision of 2026-10-06 (non-commercial use; INERTIA1.md §5 "Training data
policy"). ``$INERTIA_HAR_ROOT/wear/raw_inertial_50hz/sbj_<k>.csv`` (the release's ``raw/inertial/50hz``): columns
``sbj_id``, ``{right_arm, right_leg, left_leg, left_arm}_acc_{x,y,z}`` in g, ``label`` (18 workouts, video-annotated
segment boundaries, ``null`` in between). No timestamps: the release is on a uniform 50 Hz grid, sample k at
k / 50 s. The leg streams are never parsed.

**One wrist per subject** (no duplicated windows — the same rule as HHAR / Opportunity): both wrists record the
same movement at the same time, so using both would count every exercise bout twice, inflating window counts,
``n_acc`` and the CP95 bounds of the abstention / test gates (which assume independent windows) without adding a
subject. The LEFT wrist is used when >= 95 % of its samples are finite, else the right wrist (if >= 95 %), else the
more complete one; the choice is in ``meta['stream']``. Left first because the rest of the training pool is almost
entirely dominant / right wrist (Capture-24, WISDM, PAMAP2 dominant; MHEALTH, GOTOV right) while a WHOOP is often
worn on the non-dominant (mostly left) wrist. Non-finite rows of the chosen stream are dropped, which splits the
run (never interpolated).
"""

from __future__ import annotations

import os
import re
from typing import Iterator, List, Optional, Sequence

import numpy as np

from ..paths import under
from . import HAR_ROOT, DatasetError, Recording, resolve_root

DATASET = "wear"
LOADER_VERSION = "wear-loader-1"
DEFAULT_ROOT = under(HAR_ROOT, "wear", "raw_inertial_50hz")
FS = 50.0
MIN_FINITE = 0.95
NULL_LABEL = "null"
STREAMS = (("left_arm", "wrist_left", "left"), ("right_arm", "wrist_right", "right"))
WORKOUTS = ["jogging", "jogging (rotating arms)", "jogging (skipping)", "jogging (sidesteps)", "jogging (butt-kicks)",
            "stretching (triceps)", "stretching (lunging)", "stretching (shoulders)", "stretching (hamstrings)",
            "stretching (lumbar rotation)", "push-ups", "push-ups (complex)", "sit-ups", "sit-ups (complex)",
            "burpees", "lunges", "lunges (complex)", "bench-dips"]
LABELS = sorted(WORKOUTS + [NULL_LABEL])
# static holds: the per-dataset unit check (median |a| ~ 1 g); WEAR has no rest label
REST_LABELS = tuple(w for w in WORKOUTS if w.startswith("stretching"))


def list_units(root: Optional[str] = None) -> List[str]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    return sorted((f[:-4] for f in os.listdir(root) if re.fullmatch(r"sbj_\d+\.csv", f)), key=lambda s: int(s[4:]))


def choose_stream(finite_fractions: Sequence[float]) -> int:
    """Index into STREAMS: the first stream (left, then right) with >= MIN_FINITE finite samples, else the most
    complete one."""
    for i, f in enumerate(finite_fractions):
        if f >= MIN_FINITE:
            return i
    return int(np.argmax(finite_fractions))


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    import pandas as pd
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    lut = {n: i for i, n in enumerate(LABELS)}
    for subj in (subjects or list_units(root)):
        path = os.path.join(root, f"{subj}.csv")
        if not os.path.isfile(path):
            raise DatasetError(f"wear file missing: {path}")
        cols = [f"{s}_acc_{a}" for s, *_ in STREAMS for a in "xyz"]
        df = pd.read_csv(path, usecols=["sbj_id", "label", *cols], dtype={"label": str})
        ids = df["sbj_id"].dropna().unique()
        if len(ids) != 1 or f"sbj_{int(ids[0])}" != subj:
            raise DatasetError(f"wear {path}: sbj_id {ids.tolist()} does not match the file name")
        lab = df["label"].fillna(NULL_LABEL).to_numpy().astype(str)
        unknown = sorted(set(lab.tolist()) - set(lut))
        if unknown:
            raise DatasetError(f"wear {subj}: unexpected labels {unknown}")
        xyzs = [df[[f"{s}_acc_{a}" for a in "xyz"]].to_numpy(np.float64) for s, *_ in STREAMS]
        fr = [float(np.isfinite(x).all(axis=1).mean()) if len(x) else 0.0 for x in xyzs]
        k = choose_stream(fr)
        name, placement, side = STREAMS[k]
        xyz = xyzs[k]
        ok = np.isfinite(xyz).all(axis=1)
        codes = np.array([lut[x] for x in lab[ok]], np.int32)
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{subj}", session=f"{DATASET}:{subj}:{name}",
                        placement=placement, device=f"Bangle.js smartwatch ({name.replace('_', ' ')})", wrist_side=side,
                        axis_frame="Bangle.js native (fixed orientation, WEAR protocol)", source_hz=FS,
                        t=np.flatnonzero(ok).astype(np.float64) / FS, xyz_g=xyz[ok], labels=codes,
                        label_names=list(LABELS), uniform=True,
                        meta={"loader": LOADER_VERSION, "units_native": "g", "stream": name,
                              "finite_fraction": {s[0]: round(f, 4) for s, f in zip(STREAMS, fr)},
                              "n_nonfinite_dropped": int((~ok).sum()),
                              "stream_rule": "one wrist per subject: left if >= 95% finite, else right, else most complete"})
