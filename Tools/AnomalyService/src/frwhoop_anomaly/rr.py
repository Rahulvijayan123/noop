"""R-R beats → de-duplicated series → windowed RMSSD. Mirrors the phone's WatchdogRRMerge rules:
one transport per window (the lowest of {5, 7} present: v18 history before 2A37 live), identity (ts, rrMs, seq)
never `ord`, tsSuspect dropped, transport fill values 500 / 333 ms dropped when the concurrent HR is < 100 bpm,
physiological range 300–2000 ms, and Malik 20 % successive-difference rejection before RMSSD."""

from __future__ import annotations

import numpy as np

FILL_VALUES = (500, 333)


def clean_beats(rows: list[tuple[int, int, int, int | None, int | None]],
                hr_at: dict[int, float] | None = None) -> tuple[np.ndarray, np.ndarray, dict]:
  """rows: (ts, rr_ms, seq, src_channel, ts_suspect). Returns (ts[int], rr[float]) sorted, plus counters."""
  counters = {"input": len(rows), "suspect": 0, "fill": 0, "range": 0, "duplicates": 0, "transport": None}
  chans = {r[3] for r in rows if r[3] is not None}
  pinned = min([c for c in chans if c in (5, 7)], default=None)
  counters["transport"] = pinned
  seen: set[tuple[int, int, int]] = set()
  ts_out: list[int] = []
  rr_out: list[float] = []
  for ts, rr, seq, ch, sus in sorted(rows, key=lambda r: (r[0], r[2] or 0)):
    if pinned is not None and ch is not None and ch != pinned:
      continue
    if sus:
      counters["suspect"] += 1
      continue
    key = (ts, rr, seq or 0)
    if key in seen:
      counters["duplicates"] += 1
      continue
    seen.add(key)
    if rr < 300 or rr > 2000:
      counters["range"] += 1
      continue
    if rr in FILL_VALUES:
      h = hr_at.get(ts - ts % 60) if hr_at else None
      if h is None or h < 100:
        counters["fill"] += 1
        continue
    ts_out.append(ts)
    rr_out.append(float(rr))
  return np.asarray(ts_out, dtype=np.int64), np.asarray(rr_out, dtype=np.float64), counters


def rmssd_per_minute(ts: np.ndarray, rr: np.ndarray, minute_starts: np.ndarray, window_s: int = 300,
                     min_pairs: int = 20) -> tuple[np.ndarray, np.ndarray]:
  """Rolling RMSSD over the `window_s` seconds ending at each minute's end, and beat coverage of each minute
  (Σ rr / 60 000). Successive differences are taken only between beats ≤ 3 s apart in wall time and rejected
  when |Δ| > 20 % of the previous interval (Malik)."""
  n = len(minute_starts)
  out = np.full(n, np.nan)
  cov = np.full(n, np.nan)
  if len(ts) < 2:
    return out, cov
  d = np.diff(rr)
  ok = (np.diff(ts) <= 3) & (np.abs(d) <= 0.2 * rr[:-1])
  pair_ts = ts[1:][ok]
  pair_sq = (d[ok]) ** 2
  csum = np.concatenate([[0.0], np.cumsum(pair_sq)])
  for i, m in enumerate(minute_starts):
    end = m + 60
    lo = np.searchsorted(pair_ts, end - window_s, side="left")
    hi = np.searchsorted(pair_ts, end, side="left")
    if hi - lo >= min_pairs:
      out[i] = np.sqrt((csum[hi] - csum[lo]) / (hi - lo))
    blo = np.searchsorted(ts, m, side="left")
    bhi = np.searchsorted(ts, end, side="left")
    if bhi > blo:
      cov[i] = rr[blo:bhi].sum() / 60000.0
  return out, cov
