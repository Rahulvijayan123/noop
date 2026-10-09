"""Which stored calibration-reference windows the CURRENT context rules would exclude (read-only by default).

Before the context-hygiene fix, a window could join a model's rest/sleep reference although its minutes were an
exercise session or its recovery (resistance training reads as "stationary" to the wrist classifier, and the
classifier's label used to override the strap's own movement). The service no longer adds such windows, but rows
already in the reference ring stay until a human removes them. This tool re-gates every stored reference row whose
window start is known against the minute frame:

  python -I tools/reference_audit.py --state /var/lib/frwhoop-anomaly                     # every user/device
  python -I tools/reference_audit.py --state DIR --user U --device D --frame owner.npz    # an exported frame
  python -I tools/reference_audit.py --state DIR --user U --device D --apply             # purge (service stopped)

The frame is the state's own minute cache (frame.npz, 7 days) unless --frame gives one exported with
tools/export_frame.py (read-only). Context is re-derived with features.recontext (the stored label may only move
toward caution) and rule exercise-session-1 (features.with_sessions; --sleep-rest gives the nightly resting HR the
service would read, else the 2 h-before median / 70 bpm fallback). A row is EXCLUDED when its window is not usable
now; rows whose start is unknown or outside the frame are listed as "not_checked" and never removed.

--apply copies each changed ref_<model>_<bucket>.npy / _t.npy pair to ref-backup-<UTC time>/ in the same directory,
then rewrites both without the excluded rows (atomic replace). refmeta_* is left alone, so a removed window is never
re-added. Stop frwhoop-anomaly first; the service writes these files.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import shutil
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from frwhoop_anomaly import candidates as cand  # noqa: E402
from frwhoop_anomaly import features  # noqa: E402
from frwhoop_anomaly.state import UserState  # noqa: E402

REF = re.compile(r"^ref_(?P<model>.+)_(?P<bucket>rest|sleep)\.npy$")


def load_npz_frame(path: str) -> features.MinuteFrame:
  z = np.load(path, allow_pickle=False)
  return features.MinuteFrame(minutes=z["minutes"], data={k[2:]: z[k] for k in z.files if k.startswith("d_")},
                              context=z["context"].astype(str).astype(object),
                              family=str(z["family"]) if "family" in z.files else None, counters={})


def audit_dir(st: UserState, frame: features.MinuteFrame | None, sleep_rest: float | None = None) -> dict:
  """Per reference file: rows, excluded [{start, iso, reason}], not_checked count. Pure read."""
  out: dict = {"dir": st.dir, "files": {}, "sessions": []}
  if frame is None or not len(frame.minutes):
    out["error"] = "no minute frame"
  else:
    frame, sessions = features.with_sessions(features.recontext(frame),
                                             (lambda t: sleep_rest) if sleep_rest else None)
    out["sessions"] = [dict(s, start_iso=_iso(s["start"]), end_iso=_iso(s["end"])) for s in sessions]
  for path in sorted(glob.glob(os.path.join(st.dir, "ref_*.npy"))):
    m = REF.match(os.path.basename(path))
    if not m:
      continue
    model, bucket = m["model"], m["bucket"]
    ref = st.load_ref(model, bucket)
    starts = st.load_ref_starts(model, bucket)
    excluded, unchecked = [], 0
    for k, s0 in enumerate(starts):
      if frame is None or not np.isfinite(s0):
        unchecked += 1
        continue
      w = cand.windows(frame, int(s0), int(s0) + cand.WINDOW_S)
      if not w or w[0].start != int(s0):
        unchecked += 1
        continue
      if not w[0].usable:
        excluded.append({"row": k, "start": int(s0), "iso": _iso(int(s0)), "reason": w[0].withheld,
                         "mix": {a: round(b, 2) for a, b in w[0].context_mix.items() if b}})
    out["files"][f"{model}/{bucket}"] = {"rows": int(ref.shape[0]), "excluded": excluded, "not_checked": unchecked}
  return out


def apply(st: UserState, report: dict) -> list[str]:
  """Remove the excluded rows (backup first). Returns the files rewritten."""
  changed = []
  backup = os.path.join(st.dir, "ref-backup-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
  for key, r in report["files"].items():
    if not r["excluded"]:
      continue
    model, bucket = key.rsplit("/", 1)
    drop = {e["row"] for e in r["excluded"]}
    ref, t = st.load_ref(model, bucket), st.load_ref_starts(model, bucket)
    keep = np.array([k not in drop for k in range(len(ref))], dtype=bool)
    os.makedirs(backup, exist_ok=True)
    for name in (f"ref_{model}_{bucket}.npy", f"ref_{model}_{bucket}_t.npy"):
      if os.path.exists(os.path.join(st.dir, name)):
        shutil.copy2(os.path.join(st.dir, name), os.path.join(backup, name))
    st._atomic_npy(f"ref_{model}_{bucket}.npy", ref[keep])
    st._atomic_npy(f"ref_{model}_{bucket}_t.npy", t[keep])
    changed.append(key)
  return changed


def _iso(t: int) -> str:
  return dt.datetime.fromtimestamp(t, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main(argv: list[str] | None = None) -> dict:
  ap = argparse.ArgumentParser()
  ap.add_argument("--state", required=True, help="FRWHOOP_ANOMALY_STATE (e.g. /var/lib/frwhoop-anomaly)")
  ap.add_argument("--user")
  ap.add_argument("--device")
  ap.add_argument("--frame", help="minute frame .npz (tools/export_frame.py); default: the state's frame.npz")
  ap.add_argument("--sleep-rest", type=float, default=None, help="nightly resting HR (bpm) for the session rule")
  ap.add_argument("--apply", action="store_true", help="remove the excluded rows (backup first; service stopped)")
  a = ap.parse_args(argv)
  if a.frame and not (a.user and a.device):
    ap.error("--frame needs --user and --device")
  pairs = [(a.user, a.device)] if a.user and a.device else [
    tuple(p.split(os.sep)[-2:]) for p in sorted(glob.glob(os.path.join(a.state, "users", "*", "*"))) if os.path.isdir(p)]
  result = {"generated_at": _iso(int(time.time())), "applied": a.apply, "users": []}
  for user, device in pairs:
    if not os.path.isdir(os.path.join(a.state, "users", user, device)):
      ap.error(f"no state for {user}/{device} under {a.state}")
    st = UserState(a.state, user, device)
    frame = load_npz_frame(a.frame) if a.frame else st.load_frame()
    rep = audit_dir(st, frame, a.sleep_rest)
    rep.update({"user": user, "device": device})
    if a.apply:
      rep["rewritten"] = apply(st, rep)
    result["users"].append(rep)
  print(json.dumps(result, indent=1))
  return result


if __name__ == "__main__":
  main()
