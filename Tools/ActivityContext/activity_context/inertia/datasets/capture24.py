"""Capture-24 (Oxford; CC BY 4.0): dominant-wrist Axivity AX3, 100 Hz, already in g, ~24 h per participant.

Source: the HF mirror ``nz00shuuuu/capture24-raw`` (``pid=P###/data.parquet``: ``timestamp_ms, x, y, z,
annotation``), verified identical to the ORA release for P011, P023, P053, P099, P135 by Agent C (x/y/z
within float32 rounding, timestamps and annotations exactly equal). The ORA stream download in
``capture24/ora_stream`` is never touched. Unannotated samples get the explicit label ``"<NA>"``.
Placement: dominant wrist (side not recorded) -> ``wrist_dominant`` / ``unknown``.
"""

from __future__ import annotations

import glob
import os
from typing import Iterator, List, Optional, Sequence

import numpy as np

from ..paths import under
from . import HAR_ROOT, DatasetError, Recording, resolve_root

DATASET = "capture24"
LOADER_VERSION = "capture24-loader-1"
DEFAULT_ROOT = under(HAR_ROOT, "capture24", "hf_mirror_nz00shuuuu")
NULL_LABEL = "<NA>"
REST_LABELS = ("7030 sleeping;MET 0.95",)


def list_units(root: Optional[str] = None) -> List[str]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    return sorted(os.path.basename(os.path.dirname(p)).split("=", 1)[1]
                  for p in glob.glob(os.path.join(root, "pid=P*", "data.parquet")))


def read_participant(path: str):
    import pyarrow.compute as pc
    import pyarrow.parquet as pq
    tb = pq.read_table(path, columns=["timestamp_ms", "x", "y", "z", "annotation"], read_dictionary=["annotation"])
    ann = tb.column("annotation").combine_chunks()
    if hasattr(ann, "dictionary"):
        names = [str(v) for v in ann.dictionary.to_pylist()]
        idx = pc.fill_null(ann.indices, -1).to_numpy(zero_copy_only=False).astype(np.int64)
    else:  # plain strings (synthetic fixtures)
        vals = ann.to_pylist()
        names = sorted({v for v in vals if v is not None})
        lut = {n: i for i, n in enumerate(names)}
        idx = np.array([lut[v] if v is not None else -1 for v in vals], np.int64)
    ts = tb.column("timestamp_ms").to_numpy().astype(np.int64)
    xyz = np.stack([tb.column(c).to_numpy().astype(np.float64) for c in "xyz"], axis=1)
    return ts, xyz, idx, names


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    for pid in (subjects or list_units(root)):
        path = os.path.join(root, f"pid={pid}", "data.parquet")
        if not os.path.isfile(path):
            raise DatasetError(f"capture24 participant file missing: {path}")
        ts, xyz, idx, names = read_participant(path)
        # names sorted with the null label appended -> deterministic codes independent of parquet order
        order = sorted(set(names))
        remap = np.array([order.index(n) for n in names] + [len(order)], np.int32)
        codes = remap[np.where(idx >= 0, idx, len(names))]
        label_names = order + [NULL_LABEL]
        ok = np.isfinite(xyz).all(axis=1)
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{pid}", session=f"{DATASET}:{pid}",
                        placement="wrist_dominant", device="Axivity AX3", wrist_side="unknown",
                        axis_frame="AX3 native (x along strap)", source_hz=100.0,
                        t=ts[ok].astype(np.float64) / 1000.0, xyz_g=xyz[ok], labels=codes[ok],
                        label_names=label_names, uniform=True,
                        meta={"loader": LOADER_VERSION, "units_native": "g", "n_nonfinite_dropped": int((~ok).sum()),
                              "source": "hf_mirror_nz00shuuuu (verified vs ORA for 5 participants)"})
