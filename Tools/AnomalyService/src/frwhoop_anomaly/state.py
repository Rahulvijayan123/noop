"""Per-(user, device) local state under FRWHOOP_ANOMALY_STATE (regenerable; deleting it only costs a re-read):

* minute cache: the last `keep_minutes` (7 days) of the MinuteFrame, so a job re-reads only the newest few hours from
  Postgres (each 1 Hz table costs ~5–8 s per 20 h on the production database) and UniTS can prompt-tune on days of
  the user's own minutes that were never re-read;
* calibration references: per model × context bucket, the per-channel window scores of past usable, unflagged
  windows (a ring of at most `ref_cap` rows). A window's p-value is computed against its own user's history only.
"""

from __future__ import annotations

import os
import re
import tempfile

import numpy as np

from .features import MinuteFrame

_SAFE = re.compile(r"^[0-9a-f-]{36}$")


class UserState:
  def __init__(self, root: str, user_id: str, device_id: str, keep_minutes: int = 7 * 24 * 60, ref_cap: int = 1400):
    if not (_SAFE.match(user_id) and _SAFE.match(device_id)):
      raise ValueError("unexpected id format")
    self.dir = os.path.join(root, "users", user_id, device_id)
    os.makedirs(self.dir, exist_ok=True)
    self.keep_minutes = keep_minutes
    self.ref_cap = ref_cap

  # ---- minute cache ------------------------------------------------------------------------------------------
  def load_frame(self) -> MinuteFrame | None:
    path = os.path.join(self.dir, "frame.npz")
    if not os.path.exists(path):
      return None
    try:
      z = np.load(path, allow_pickle=False)
      data = {k[2:]: z[k] for k in z.files if k.startswith("d_")}
      ctx = z["context"].astype(str).astype(object)
      fam = str(z["family"]) if "family" in z.files and str(z["family"]) else None
      return MinuteFrame(minutes=z["minutes"], data=data, context=ctx, family=fam, counters={})
    except (OSError, ValueError, KeyError):
      return None

  def save_frame(self, f: MinuteFrame) -> None:
    keep = f.minutes >= (f.minutes[-1] - self.keep_minutes * 60) if len(f.minutes) else slice(None)
    arrays = {"minutes": f.minutes[keep], "context": np.asarray(f.context[keep]).astype(str),
              "family": np.asarray(f.family or "")}
    for k, v in f.data.items():
      arrays["d_" + k] = np.asarray(v)[keep]
    self._atomic_npz("frame.npz", arrays)

  @staticmethod
  def merge(old: MinuteFrame | None, new: MinuteFrame) -> MinuteFrame:
    """New minutes win over cached ones (late data re-read); older cached minutes are kept."""
    if old is None or not len(old.minutes):
      return new
    if not len(new.minutes):
      return old
    first_new = int(new.minutes[0])
    keep = old.minutes < first_new
    # The scorers index minutes by position: a gap between the cache and the fresh read is filled with unmeasured
    # minutes (NaN, context "unknown") so the grid stays dense.
    last_old = int(old.minutes[keep][-1]) if keep.any() else first_new - 60
    gap = np.arange(last_old + 60, first_new, 60, dtype=np.int64)
    minutes = np.concatenate([old.minutes[keep], gap, new.minutes])
    data = {}
    for k in new.data:
      ov = old.data.get(k)
      ov = ov[keep] if ov is not None and len(ov) == len(old.minutes) else np.full(int(keep.sum()), np.nan)
      data[k] = np.concatenate([ov, np.full(len(gap), np.nan), new.data[k]])
    ctx = np.concatenate([np.asarray(old.context, dtype=object)[keep], np.full(len(gap), "unknown", dtype=object),
                          np.asarray(new.context, dtype=object)])
    return MinuteFrame(minutes=minutes, data=data, context=ctx, family=new.family or old.family,
                       counters=new.counters)

  # ---- calibration references ------------------------------------------------------------------------------
  def load_ref(self, model: str, bucket: str) -> np.ndarray:
    path = os.path.join(self.dir, f"ref_{model}_{bucket}.npy")
    if not os.path.exists(path):
      return np.zeros((0, 0))
    try:
      return np.load(path, allow_pickle=False)
    except (OSError, ValueError):
      return np.zeros((0, 0))

  def load_ref_starts(self, model: str, bucket: str) -> np.ndarray:
    """Window start of each reference row (NaN where unknown); aligned with load_ref."""
    ref = self.load_ref(model, bucket)
    path = os.path.join(self.dir, f"ref_{model}_{bucket}_t.npy")
    try:
      t = np.load(path, allow_pickle=False) if os.path.exists(path) else None
    except (OSError, ValueError):
      t = None
    if t is None or len(t) != len(ref):
      return np.full(len(ref), np.nan)
    return t.astype(np.float64)

  def append_ref(self, model: str, bucket: str, rows: np.ndarray, starts=None) -> np.ndarray:
    ref = self.load_ref(model, bucket)
    old_t = self.load_ref_starts(model, bucket)
    rows = np.atleast_2d(rows)
    new_t = np.full(len(rows), np.nan) if starts is None else np.asarray(starts, dtype=np.float64)
    if ref.size and ref.shape[1] == rows.shape[1]:
      ref = np.concatenate([ref, rows])
      t = np.concatenate([old_t, new_t])
    else:
      ref, t = rows, new_t
    ref, t = ref[-self.ref_cap:], t[-self.ref_cap:]
    self._atomic_npy(f"ref_{model}_{bucket}.npy", ref)
    self._atomic_npy(f"ref_{model}_{bucket}_t.npy", t)
    return ref

  def _atomic_npz(self, name: str, arrays: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=self.dir, suffix=".npz")
    os.close(fd)
    np.savez(tmp, **arrays)
    os.replace(tmp, os.path.join(self.dir, name))

  def _atomic_npy(self, name: str, arr: np.ndarray) -> None:
    fd, tmp = tempfile.mkstemp(dir=self.dir, suffix=".npy")
    os.close(fd)
    np.save(tmp, arr)
    os.replace(tmp, os.path.join(self.dir, name))
