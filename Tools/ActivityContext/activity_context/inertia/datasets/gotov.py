"""GOTOV (4TU.ResearchData, doi:10.4121/12716081.v2; CC BY-NC-SA 4.0): right-wrist GENEActiv, g, 600/7 Hz.

Trained on since the owner's licence decision of 2026-10-06 (non-commercial use; INERTIA1.md §5 "Training data
policy"). 35 older adults (59.5-81.3 y) performing a 16-activity protocol; a researcher asked for each activity
and recorded its start/end time, so labels are **protocol-imputed** (most durations are the nominal 60/180/300 s);
between activities the participant stood for > 1 min, unlabelled (``NA``).

Files (``$INERTIA_HAR_ROOT/gotov``): ``Activity_Measurements/<ID>/<ID>-GENEActiv-wrist.csv`` (columns ``"", time,
x, y, z, labels``; time = unix ms; x/y/z in g) and, for the 31 participants with COSMED,
``Energy_Expenditure_Measurements/<ID>.csv`` (COSMED K4b2 breath-by-breath ``METS`` merged onto the same unix-ms
clock). Read from the extracted folders, or straight from ``Activity_Measurements.zip`` /
``Energy_Expenditure_Measurements.zip`` when a file is not extracted. The ankle/chest GENEActiv, the Equivital and
every COSMED column except ``time`` and ``METS`` are never parsed; METS is a movement_intensity TARGET only, never
a head input (INERTIA1.md §9).

Clock: the CSV timestamps are page-interpolated (steps of 4/8/11/12/15 ms) but stay within 15 ms of a uniform
600/7 Hz (85.714 Hz) grid over every whole recording (measured on all 35 files), so samples are placed on that
grid (``uniform=True``; a file whose timestamps are not increasing or drift > 50 ms from it is refused). The
non-integer rate goes through ``preprocess.resample_to_20hz``'s ``np.interp`` path. The wrist files have no
missing samples; non-finite rows would be dropped (splitting the run), never interpolated.

Loader policy (versioned in ``LOADER_VERSION``; never applied to WHOOP data):

* ``gotov-guard-10s`` — label timing is protocol-imputed. Wrist activity onsets measured against the label onsets
  (walking/cycling/household tasks, all 35 files) put the median offset near 0 s but the 5-95 % range at about
  +-15 s, so the first and last ``GUARD_S`` = 10 s of every labelled segment are relabelled ``NA`` (MASK): class
  windows (>= 90 % one non-null label) then come from segment interiors only. ``syncJumping`` and the undocumented
  ``step`` stay labels of their own (MASK in the crosswalk).
* ``gotov-met-1`` — measured MET per sample for movement_intensity: each breath's METS (finite, > 0; others
  dropped and counted) holds until the next breath when that breath is <= ``MAX_BREATH_GAP_S`` = 15 s later, else
  there is no value. No value either for samples in the first ``MET_ONSET_S`` = 60 s of a labelled segment
  (VO2 on-kinetics: in these files walking/vacuuming reach their plateau about 60 s after the label onset and
  lying keeps the preceding activity's MET for ~60 s), for unlabelled (``NA``) samples and for participants without
  COSMED. ``windows.py`` averages it per window (>= 90 % of the window measured, else MASK).
"""

from __future__ import annotations

import io
import os
import zipfile
from typing import Iterator, List, Optional, Sequence, Tuple

import numpy as np

from ..paths import under
from . import HAR_ROOT, DatasetError, Recording, resolve_root

DATASET = "gotov"
LOADER_VERSION = "gotov-loader-1+gotov-guard-10s+gotov-met-1"
DEFAULT_ROOT = under(HAR_ROOT, "gotov")
FS = 600.0 / 7.0                      # GENEActiv 85.714 Hz
MAX_CLOCK_DRIFT_S = 0.05
GUARD_S = 10.0
MET_ONSET_S = 60.0
MAX_BREATH_GAP_S = 15.0
NULL_LABEL = "NA"
LABELS = ["NA", "cycling", "dishwashing", "lyingDownLeft", "lyingDownRight", "sittingChair", "sittingCouch",
          "sittingSofa", "stakingShelves", "standing", "step", "syncJumping", "vacuumCleaning", "walkingFast",
          "walkingNormal", "walkingSlow", "walkingStairsUp"]
REST_LABELS = ("standing", "sittingChair", "sittingSofa", "sittingCouch", "lyingDownLeft", "lyingDownRight")
ACT_ZIP, EE_ZIP = "Activity_Measurements.zip", "Energy_Expenditure_Measurements.zip"


def _wrist_member(subj: str) -> str:
    return f"Activity_Measurements/{subj}/{subj}-GENEActiv-wrist.csv"


def _ee_member(subj: str) -> str:
    return f"Energy_Expenditure_Measurements/{subj}.csv"


def _source(root: str, member: str, zip_name: str):
    """A path or file-like object for ``member``: the extracted file, else the member inside ``zip_name``; None
    if neither exists."""
    path = os.path.join(root, *member.split("/"))
    if os.path.isfile(path):
        return path
    zp = os.path.join(root, zip_name)
    if os.path.isfile(zp):
        with zipfile.ZipFile(zp) as z:
            if member in z.namelist():
                return io.BytesIO(z.read(member))
    return None


def list_units(root: Optional[str] = None) -> List[str]:
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    subs = set()
    act = os.path.join(root, "Activity_Measurements")
    if os.path.isdir(act):
        subs |= {s for s in os.listdir(act) if os.path.isfile(os.path.join(act, s, f"{s}-GENEActiv-wrist.csv"))}
    zp = os.path.join(root, ACT_ZIP)
    if os.path.isfile(zp):
        with zipfile.ZipFile(zp) as z:
            subs |= {n.split("/")[1] for n in z.namelist()
                     if n.startswith("Activity_Measurements/") and n.endswith("-GENEActiv-wrist.csv")}
    return sorted(subs)


def guard_labels(codes: np.ndarray, t: np.ndarray, null_code: int, guard_s: float = GUARD_S) -> Tuple[np.ndarray, int]:
    """Relabel the first/last ``guard_s`` of every non-null labelled segment as null; returns (codes, n relabelled)."""
    out = codes.copy()
    if not len(codes):
        return out, 0
    chg = np.flatnonzero(codes[1:] != codes[:-1]) + 1
    for a, b in zip(np.r_[0, chg], np.r_[chg, len(codes)]):
        if codes[a] == null_code:
            continue
        seg = slice(a, b)
        edge = (t[seg] < t[a] + guard_s) | (t[seg] > t[b - 1] - guard_s)
        out[seg][edge] = null_code
    return out, int((out != codes).sum())


def breath_series(ee) -> Tuple[np.ndarray, np.ndarray, int]:
    """(times s, METS, n dropped) from the merged COSMED file: rows with a finite, positive METS, time-sorted,
    duplicate times dropped (first kept)."""
    t = np.asarray(ee["time"], np.float64) / 1000.0
    v = np.asarray(ee["METS"], np.float64)
    has = np.isfinite(v) & np.isfinite(t)
    ok = has & (v > 0)
    t, v = t[ok], v[ok]
    o = np.argsort(t, kind="stable")
    t, v = t[o], v[o]
    keep = np.r_[True, np.diff(t) > 0] if len(t) else np.zeros(0, bool)
    return t[keep], v[keep], int((has & ~ok).sum())


def met_per_sample(t: np.ndarray, codes: np.ndarray, null_code: int, tb: np.ndarray, vb: np.ndarray,
                   max_gap_s: float = MAX_BREATH_GAP_S, onset_s: float = MET_ONSET_S) -> np.ndarray:
    """Step function of the breath values (each held until the next breath if <= max_gap_s later), NaN outside
    labelled segments and in the first ``onset_s`` of each (original, un-guarded) labelled segment."""
    met = np.full(len(t), np.nan)
    if len(tb) >= 2 and len(t):
        j = np.searchsorted(tb, t, side="right") - 1
        inside = (j >= 0) & (j < len(tb) - 1)
        jj = np.clip(j, 0, len(tb) - 2)
        ok = inside & ((tb[jj + 1] - tb[jj]) <= max_gap_s)
        met[ok] = vb[jj[ok]]
    met[codes == null_code] = np.nan
    if len(codes):
        chg = np.flatnonzero(codes[1:] != codes[:-1]) + 1
        for a, b in zip(np.r_[0, chg], np.r_[chg, len(codes)]):
            seg = slice(a, b)
            met[seg][t[seg] < t[a] + onset_s] = np.nan
    return met


def read_wrist(src):
    import pandas as pd
    df = pd.read_csv(src, usecols=["time", "x", "y", "z", "labels"], dtype={"labels": str})
    return (df["time"].to_numpy(np.int64), df[["x", "y", "z"]].to_numpy(np.float64),
            df["labels"].fillna(NULL_LABEL).to_numpy().astype(str))


def iter_recordings(root: Optional[str] = None, subjects: Optional[Sequence[str]] = None) -> Iterator[Recording]:
    import pandas as pd
    root = resolve_root(root, DEFAULT_ROOT, DATASET)
    lut = {n: i for i, n in enumerate(LABELS)}
    null = lut[NULL_LABEL]
    for subj in (subjects or list_units(root)):
        src = _source(root, _wrist_member(subj), ACT_ZIP)
        if src is None:
            raise DatasetError(f"gotov wrist file missing: {_wrist_member(subj)} under {root}")
        t_ms, xyz, lab = read_wrist(src)
        if len(t_ms) < 2 or (np.diff(t_ms) <= 0).any():
            raise DatasetError(f"gotov {subj}: timestamps are not strictly increasing")
        t = t_ms[0] / 1000.0 + np.arange(len(t_ms)) / FS               # uniform 600/7 Hz grid
        drift = float(np.abs(t_ms / 1000.0 - t).max())
        if drift > MAX_CLOCK_DRIFT_S:
            raise DatasetError(f"gotov {subj}: timestamps drift {drift:.3f} s from a uniform {FS:.3f} Hz clock")
        unknown = sorted(set(lab.tolist()) - set(lut))
        if unknown:
            raise DatasetError(f"gotov {subj}: unexpected labels {unknown}")
        raw = np.array([lut[x] for x in lab], np.int32)
        codes, n_guard = guard_labels(raw, t, null)
        ee_src = _source(root, _ee_member(subj), EE_ZIP)
        met_info = {"cosmed": ee_src is not None}
        if ee_src is not None:
            ee = pd.read_csv(ee_src, usecols=["time", "METS"])
            tb, vb, n_bad = breath_series(ee)
            if len(tb) and np.mean((tb >= t[0] - 1) & (tb <= t[-1] + 1)) < 0.9:
                raise DatasetError(f"gotov {subj}: COSMED times do not overlap the wrist clock")
            met = met_per_sample(t, raw, null, tb, vb)
            met_info.update(n_breaths=int(len(tb)), n_nonpositive_dropped=n_bad,
                            measured_fraction_of_labelled=float(np.isfinite(met).sum() / max(1, (raw != null).sum())))
        else:
            met = np.full(len(t), np.nan)
        ok = np.isfinite(xyz).all(axis=1)
        yield Recording(dataset=DATASET, subject=f"{DATASET}:{subj}", session=f"{DATASET}:{subj}",
                        placement="wrist_right", device="GENEActiv (right wrist, strap)", wrist_side="right",
                        axis_frame="GENEActiv native", source_hz=FS, t=t[ok], xyz_g=xyz[ok], labels=codes[ok],
                        label_names=list(LABELS), uniform=True, met=met[ok],
                        meta={"loader": LOADER_VERSION, "units_native": "g",
                              "measured_hz": round(float((len(t_ms) - 1) / ((t_ms[-1] - t_ms[0]) / 1000.0)), 4),
                              "max_clock_drift_s": round(drift, 4), "n_nonfinite_dropped": int((~ok).sum()),
                              "n_guard_relabelled_null": n_guard, "met": met_info})
