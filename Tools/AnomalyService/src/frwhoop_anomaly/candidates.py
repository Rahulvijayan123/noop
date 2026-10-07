"""Windows → per-model calibrated p → candidates (docs/BASELINE_WATCHDOG_V2.md §5).

* Windows are 30-minute wall-clock blocks (:00 / :30), scored once complete (end ≤ newest data − 5 min).
* A window is USABLE when ≥ 70 % of its minutes have HR on ≥ 30 s AND ≥ 70 % are still or asleep (not "recovery":
  still minutes within 30 min of vigorous / 10 min of walking). Activity-dominated, recovering, off-wrist or poorly
  measured windows are withheld with a reason (the phone's activity and quality
  checks would fail them anyway; the models are not asked to explain exercise).
* Context bucket: "sleep" when ≥ 50 % of the minutes are asleep, else "rest". Calibration references are per bucket.
* Each model's window p = min-p over channels, re-calibrated on the user's own reference (calibration.MultiChannel).
  A model FLAGS a window at p < ALPHA (1e-3). Until a bucket has MIN_REFERENCE windows the model is "calibrating":
  scores are stored, nothing is flagged.
* A candidate = a run of consecutive flagged windows (either model). channels = channels with per-channel p < 0.01 in
  any flagging model; direction = sign of the strongest such channel's directional z. severity "strong" when both
  models flag and min p < 1e-4. candidate_key = "anomaly:<first window start>" (stable across re-scores).
"""

from __future__ import annotations

import dataclasses
import datetime as dt

import numpy as np

from .features import TARGETS

WINDOW_S = 1800
ALPHA = 1e-3
STRONG = 1e-4
CHANNEL_ALPHA = 0.01
MIN_QUALITY = 0.7
MIN_RESTFUL = 0.7
CHANNEL_NAMES = {"hr": "HR", "ln_rmssd": "HRV", "temp": "Temp", "resp": "Resp", "spo2": "SpO2"}
# Clinically relevant direction per target for the directional score (0 = two-sided).
DIRECTION = np.array([+1, -1, 0, +1, -1], dtype=np.float64)


@dataclasses.dataclass
class Window:
  start: int
  minute_idx: np.ndarray
  usable: bool
  withheld: str | None
  bucket: str
  context_mix: dict


def windows(frame, lo: int, hi: int) -> list[Window]:
  out = []
  first = lo - lo % WINDOW_S
  for s in range(first, hi - WINDOW_S + 1, WINDOW_S):
    idx = np.flatnonzero((frame.minutes >= s) & (frame.minutes < s + WINDOW_S))
    if len(idx) < 25:
      continue
    ctx = np.asarray(frame.context[idx]).astype(str)
    mix = {k: float(np.mean(ctx == k)) for k in ("still", "asleep", "recovery", "walking", "active", "off", "unknown")}
    quality = float(np.mean(frame.data["hr_n"][idx] >= 30))
    restful = mix["still"] + mix["asleep"]
    withheld = None
    if mix["off"] > 0.2:
      withheld = "off_wrist"
    elif quality < MIN_QUALITY:
      withheld = "low_hr_coverage"
    elif restful < MIN_RESTFUL:
      withheld = "activity" if (mix["walking"] + mix["active"] + mix["recovery"]) > 0.15 else "context_unknown"
    out.append(Window(start=s, minute_idx=idx, usable=withheld is None, withheld=withheld,
                      bucket="sleep" if mix["asleep"] >= 0.5 else "rest", context_mix=mix))
  return out


def directional(z: np.ndarray) -> np.ndarray:
  """z: (U, H) per-minute standardized residuals → (U,) mean directional z (NaN where a channel has no data)."""
  zz = np.where(DIRECTION[:, None] == 0, np.abs(z), z * DIRECTION[:, None])
  return nanmean_rows(zz)


def nanmean_rows(z: np.ndarray) -> np.ndarray:
  """Row means ignoring NaN; NaN (silently) for a channel with no data in the window."""
  n = np.isfinite(z).sum(axis=1)
  s = np.where(np.isfinite(z), z, 0.0).sum(axis=1)
  return np.where(n > 0, s / np.maximum(n, 1), np.nan)


@dataclasses.dataclass
class ModelWindowResult:
  model: str
  window: Window
  channel_scores: np.ndarray      # (U,) directional mean z
  signed_mean: np.ndarray         # (U,) signed mean z (for direction)
  p: float | None = None
  channel_p: np.ndarray | None = None
  flagged: bool = False
  calibrating: bool = False


def form_candidates(results: dict[str, list[ModelWindowResult]], frame, versions: dict[str, str],
                    tz_offset_s: int = 0) -> list[dict]:
  by_start: dict[int, list[ModelWindowResult]] = {}
  for model, rs in results.items():
    for r in rs:
      by_start.setdefault(r.window.start, []).append(r)
  flagged_starts = sorted(s for s, rs in by_start.items() if any(r.flagged for r in rs))
  runs: list[list[int]] = []
  for s in flagged_starts:
    if runs and s - runs[-1][-1] == WINDOW_S:
      runs[-1].append(s)
    else:
      runs.append([s])
  out = []
  for run in runs:
    rs = [r for s in run for r in by_start[s]]
    flagging = [r for r in rs if r.flagged]
    flagged_by = sorted({r.model for r in flagging})
    model_p = {m: float(min(r.p for r in rs if r.model == m and r.p is not None)) for m in {r.model for r in rs}
               if any(r.p is not None for r in rs if r.model == m)}
    chan_idx: set[int] = set()
    best = (0.0, 0, 0)  # (|z|, channel, sign)
    for r in flagging:
      if r.channel_p is None:
        continue
      for j in np.flatnonzero(r.channel_p < CHANNEL_ALPHA):
        chan_idx.add(int(j))
        sz = r.signed_mean[j]
        if np.isfinite(sz) and abs(sz) > best[0]:
          best = (abs(sz), int(j), 1 if sz > 0 else -1)
    if not chan_idx:   # combined min-p flagged but no single channel under 0.01: report the strongest channel
      for r in flagging:
        if r.channel_p is not None:
          j = int(np.nanargmin(r.channel_p))
          chan_idx.add(j)
          sz = r.signed_mean[j]
          if np.isfinite(sz) and abs(sz) > best[0]:
            best = (abs(sz), j, 1 if sz > 0 else -1)
    channels = [CHANNEL_NAMES[TARGETS[j]] for j in sorted(chan_idx)]
    minp = min(model_p.values()) if model_p else 1.0
    start, end = run[0], run[-1] + WINDOW_S
    local_day = dt.datetime.fromtimestamp(start + tz_offset_s, tz=dt.timezone.utc).date().isoformat()
    first = by_start[run[0]][0].window
    out.append({
      "candidate_key": f"anomaly:{start}",
      "start_ts": dt.datetime.fromtimestamp(start, tz=dt.timezone.utc).isoformat(),
      "end_ts": dt.datetime.fromtimestamp(end, tz=dt.timezone.utc).isoformat(),
      "local_day": local_day,
      "channels": channels or ["HR"],
      "flagged_by": flagged_by,
      "model_p": model_p,
      "score": float(-np.log10(max(minp, 1e-12))),
      "severity": "strong" if len(flagged_by) >= 2 and minp < STRONG else "candidate",
      "direction": best[2],
      "expected": {},
      "observed": {CHANNEL_NAMES[k]: (float(np.nanmedian(frame.data[k][first.minute_idx]))
                                      if np.isfinite(frame.data[k][first.minute_idx]).any() else None)
                   for k in TARGETS},
      "context": {"bucket": first.bucket, "mix": first.context_mix, "windows": len(run)},
      "quality": {"hr_coverage": float(np.mean(frame.data["hr_n"][first.minute_idx] >= 30))},
      "model_versions": versions,
      "status": "candidate",
    })
  return out


def window_score_rows(results: dict[str, list[ModelWindowResult]], withheld: list[Window]) -> list[dict]:
  rows = []
  iso = lambda t: dt.datetime.fromtimestamp(t, tz=dt.timezone.utc).isoformat()
  for model, rs in results.items():
    for r in rs:
      rows.append({"window_start": iso(r.window.start), "window_end": iso(r.window.start + WINDOW_S),
                   "channel_group": "all", "model": model,
                   "score": float(np.nanmax(r.channel_scores)) if np.isfinite(r.channel_scores).any() else None,
                   "p": r.p, "context_kind": r.window.bucket, "usable": True,
                   "withheld_reason": "calibrating" if r.calibrating else None})
  for w in withheld:
    rows.append({"window_start": iso(w.start), "window_end": iso(w.start + WINDOW_S), "channel_group": "all",
                 "model": "none", "score": None, "p": None, "context_kind": w.bucket, "usable": False,
                 "withheld_reason": w.withheld})
  return rows
