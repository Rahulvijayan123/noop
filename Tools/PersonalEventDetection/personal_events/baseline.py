"""Expected value and deviation (docs/PHENOTYPE_SIGNATURES.md, section 3).

`Normalizer(mode).fit(timeline, context, mask)` learns the patient's normal; `transform` returns z per channel
plus the expected value in physical units. A channel or context without enough fitting data has no baseline and
its z is NaN (abstain; no stand-in).

`layer1` / `layer1+tod`: heart rate and HRV are compared with the phone's Layer 1 v2 context-strata reference for
the minute's context (layer1_context.py: sleep HR, awake lying / seated / standing / pooled rest, steady walking;
each day from the days before it). Minutes and channels without a Layer 1 reference use the `context` baseline,
and `Deviation.source` says per minute which one was used.
"""
from __future__ import annotations

import dataclasses

import numpy as np

from . import layer1_context as l1ctx
from .context import BANDS, C, CONTEXTS, Context
from .timeline import Timeline

CHANNELS = ("hr", "hrv", "temp", "resp", "motion")
SOURCE = {"hr": "hr", "hrv": "ln_rmssd", "temp": "temp_detr", "resp": "resp", "motion": "motion"}
UNITS = {"hr": "bpm", "hrv": "ms", "temp": "°C", "resp": "breaths/min", "motion": "g"}
FLOORS = {"hr": 1.0, "hrv": 0.05, "temp": 0.05, "resp": 0.3, "motion": 0.005}
MODES = ("raw", "context", "context+response", "layer1", "layer1+tod")
LAYER1_MODES = ("layer1", "layer1+tod")
LAYER1_CHANNELS = ("hr", "hrv")
# Deviation.source values, per minute and channel.
SOURCES = ("layer1_established", "layer1_provisional", "engine_context", "none")
SHRINK_K = 60.0
MIN_GLOBAL = 30
MIN_CONTEXT = 20
SUPPORT_DAY_MINUTES = 30
# Preferring a parent seen on >= N local days over a thin own baseline was evaluated (N = 3) and rejected: it
# changed the signature baselines and let new contexts borrow broad pools that misfit them. 0 = off; detectors
# instead abstain on minutes whose used baseline has < 3 days (evaluation.MIN_DETECT_SUPPORT).
MIN_CONTEXT_DAYS = 0
# A context with too few fitting minutes borrows its parent's baseline (flagged as a fallback) instead of NaN, so
# movement minutes stay visible: active -> walking -> awake pooled; still contexts -> still pooled -> awake.
STILL_POOL = ("still_supine", "still_seated", "still_upright", "still_unknown", "recovery")
PARENTS = {"active": ("walking", "awake"), "walking": ("awake",), "recovery": ("still", "awake"),
           "still_supine": ("still", "awake"), "still_seated": ("still", "awake"),
           "still_upright": ("still", "awake"), "still_unknown": ("still", "awake"), "unknown": ("awake",)}
EVENT_MARGIN_S = 2 * 3600
MAD_TO_SD = 1.4826
RESPONSE_LAGS = 10
RESPONSE_TAUS = (3.0, 10.0)
RESPONSE_MIN_ROWS = 500
RESPONSE_MIN_GAIN = 0.02


def fit_mask(tl: Timeline, ctx: Context, exclusions=(), cutoff=None, margin_s=EVENT_MARGIN_S) -> np.ndarray:
  """Minutes usable for fitting: worn, not off-wrist, before the cutoff, and not within +/- 2 h of any logged
  event / positive review / unreviewed detection (`exclusions` = [(start, end)])."""
  mask = tl["wear"] & (ctx.code != C["off"])
  if cutoff is not None:
    mask &= tl.minutes + 60 <= cutoff
  return mask & ~near_intervals(tl, exclusions, margin_s)


def near_intervals(tl: Timeline, intervals, margin_s) -> np.ndarray:
  n = len(tl)
  delta = np.zeros(n + 1, np.int64)
  for span in intervals:
    a, b = span[0], span[1]
    lo = int(np.clip(np.floor((a - margin_s - tl.minutes[0]) / 60), 0, n))
    hi = int(np.clip(np.ceil((b + margin_s - tl.minutes[0]) / 60), 0, n))
    if hi > lo:
      delta[lo] += 1; delta[hi] -= 1
  return np.cumsum(delta[:n]) > 0


def _robust(x):
  med = float(np.median(x))
  return med, float(np.median(np.abs(x - med))) * MAD_TO_SD


@dataclasses.dataclass
class Deviation:
  z: dict          # channel -> (N,) z (NaN = no baseline / no data)
  expected: dict   # channel -> (N,) expected value in analysis units (ln ms for hrv)
  scale: dict      # channel -> (N,) robust SD in analysis units
  residual: dict   # channel -> (N,) observed - expected in analysis units
  support: dict = None  # channel -> (N,) days behind the minute's baseline (0 = none)
  source: dict = None   # channel -> (N,) str in SOURCES: which baseline the minute was compared with


def physical_change(channel, delta, center=None):
  """Analysis-unit difference -> physical units. HRV is analysed as ln(RMSSD): a difference d around an expected
  ln value c is exp(c + d) - exp(c) ms."""
  delta = np.asarray(delta, dtype=np.float64)
  if channel == "hrv":
    c = np.log(40.0) if center is None or not np.isfinite(center) else center
    return np.exp(c + delta) - np.exp(c)
  return delta


class Normalizer:
  def __init__(self, mode: str = "context", k: float = SHRINK_K):
    if mode not in MODES:
      raise ValueError(f"unknown normalization {mode!r}")
    self.mode = mode; self.k = float(k)
    self.params: dict = {}
    self.response: dict | None = None
    self.info: dict = {}
    self.tod: dict | None = None       # layer1+tod: shrunk time-of-day offsets on the Layer 1 residuals

  # ------------------------------------------------------------------------------------------- fitting
  def fit(self, tl: Timeline, ctx: Context, mask: np.ndarray) -> "Normalizer":
    self.params = {}
    cells = ctx.code * len(BANDS) + ctx.band
    for ch in CHANNELS:
      x = tl[SOURCE[ch]]
      ok = mask & np.isfinite(x)
      self.params[ch] = self._fit_channel(ch, x[ok], ctx.code[ok], cells[ok], tl.local_day[ok])
    self.response = None
    self.tod = None
    self.info = {"mode": self.mode, "response_used": False}
    if self.mode == "context+response":
      self._fit_response(tl, ctx, mask)
    if self.mode in LAYER1_MODES:
      layer = l1ctx.cached(tl, ctx)
      self.info["layer1"] = {"available": layer.available, "reason": layer.reason}
      if self.mode == "layer1+tod" and layer.available:
        self._fit_tod(tl, ctx, mask, layer)
    return self

  # ------------------------------------------------------------------------------------------- Layer 1
  def _fit_tod(self, tl, ctx, mask, layer):
    """Shrunk time-of-day offsets of HR / HRV around the Layer 1 reference (Layer 1 has no time of day): per stratum
    the median residual shrunk toward 0, per (stratum, band) shrunk toward the stratum's offset, weight n/(n+k).
    Fitted only on `mask` minutes (worn, before the cutoff, outside event exclusion windows)."""
    self.tod = {}
    nb = len(BANDS)
    for ch in LAYER1_CHANNELS:
      t = layer.tracks[ch]
      r = tl[SOURCE[ch]] - t.expected
      ok = mask & np.isfinite(r)
      table = {}
      for key in sorted({k for k in t.series[ok] if k is not None}):
        sel = ok & (t.series == key)
        n_s = int(sel.sum())
        if n_s < MIN_CONTEXT:
          continue
        w = n_s / (n_s + self.k)
        base = w * float(np.median(r[sel]))
        offs = np.full(nb, base)
        for b in range(nb):
          sb = sel & (ctx.band == b)
          n_b = int(sb.sum())
          if n_b:
            wb = n_b / (n_b + self.k)
            offs[b] = wb * float(np.median(r[sb])) + (1 - wb) * base
        table[key] = offs
      self.tod[ch] = table
    self.info["tod_offsets"] = {ch: {k: [round(float(v), 4) for v in o] for k, o in tab.items()}
                                for ch, tab in self.tod.items()}

  def _layer1_lookup(self, ch, tl, ctx):
    """(expected, scale, source, days) from Layer 1 for one channel; NaN / "none" where it has no reference."""
    layer = l1ctx.cached(tl, ctx)
    t = layer.tracks[ch]
    e = t.expected.copy()
    if self.tod and self.tod.get(ch):
      for key, offs in self.tod[ch].items():
        sel = t.series == key
        e[sel] += offs[ctx.band[sel]]
    source = np.where(t.status == "established", "layer1_established",
                      np.where(t.status == "provisional", "layer1_provisional", "none"))
    return e, t.scale_floored, source, t.days

  def _fit_channel(self, ch, x, codes, cells, days=None):
    floor = FLOORS[ch]
    if len(x) < MIN_GLOBAL:
      return None
    days = np.zeros(len(x), np.int64) if days is None else np.asarray(days)

    def n_days(sel):
      _, cnt = np.unique(days[sel], return_counts=True)
      return int((cnt >= SUPPORT_DAY_MINUTES).sum())

    g_med, g_sd = _robust(x)
    g_sd = max(g_sd, floor)
    all_days = n_days(np.ones(len(x), bool))
    if self.mode == "raw":
      return {"global": (g_med, g_sd), "n": int(len(x)), "global_days": all_days}
    nc, nb = len(CONTEXTS), len(BANDS)
    center = np.full((nc, nb), np.nan); scale = np.full((nc, nb), np.nan); counts = np.zeros((nc, nb), np.int64)
    used_days = np.zeros(nc, np.int64)
    bands = cells % nb

    def shrunk(sel):
      """(center[nb], scale[nb], days) for a selection: its pooled value shrunk to global, bands shrunk to pooled."""
      n_c = int(sel.sum())
      if n_c < MIN_CONTEXT:
        return None
      c_med, c_sd = _robust(x[sel])
      w = n_c / (n_c + self.k)
      ctx_center = w * c_med + (1 - w) * g_med
      ctx_scale = w * c_sd + (1 - w) * g_sd
      ce = np.empty(nb); sc = np.empty(nb)
      for b in range(nb):
        sb = sel & (bands == b)
        n_cb = int(sb.sum())
        if n_cb:
          med, sd = _robust(x[sb]); wb = n_cb / (n_cb + self.k)
          ce[b] = wb * med + (1 - wb) * ctx_center; sc[b] = max(wb * sd + (1 - wb) * ctx_scale, floor)
        else:
          ce[b] = ctx_center; sc[b] = max(ctx_scale, floor)
      return ce, sc, n_days(sel)

    stats = {}
    for c in range(nc):
      if c == C["off"]:
        continue
      sel = codes == c
      counts[c] = np.bincount(bands[sel], minlength=nb)
      stats[CONTEXTS[c]] = shrunk(sel)
    stats["still"] = shrunk(np.isin(codes, [C[k] for k in STILL_POOL]))
    stats["awake"] = shrunk(~np.isin(codes, [C["asleep"], C["off"]]))
    fallback = {}
    for c in range(nc):
      if c == C["off"]:
        continue
      chain = [CONTEXTS[c]] + list(PARENTS.get(CONTEXTS[c], ()))
      # First baseline in the chain that has seen >= MIN_CONTEXT_DAYS days; else the first with enough minutes.
      pick = next((name for name in chain if stats.get(name) and stats[name][2] >= MIN_CONTEXT_DAYS), None)
      if pick is None:
        pick = next((name for name in chain if stats.get(name)), None)
      if pick is None:
        continue
      center[c], scale[c], used_days[c] = stats[pick]
      if pick != CONTEXTS[c]:
        fallback[CONTEXTS[c]] = pick
    return {"global": (g_med, g_sd), "center": center, "scale": scale, "counts": counts, "n": int(len(x)),
            "fallback": fallback, "days": used_days, "global_days": all_days}
  # ------------------------------------------------------------------------------------------- HR response
  @staticmethod
  def response_features(tl: Timeline, ctx: Context) -> np.ndarray:
    motion = tl["motion"]; steps = tl["steps"]
    n = len(tl)
    feats = []
    for series in (motion, steps):
      for lag in range(RESPONSE_LAGS + 1):
        feats.append(np.r_[np.full(lag, np.nan), series[:n - lag]] if lag else series)
    finite = np.isfinite(motion)
    x0 = np.where(finite, motion, 0.0)
    from scipy.signal import lfilter
    for tau in RESPONSE_TAUS:
      a = np.exp(-1.0 / tau)
      num = lfilter([1 - a], [1, -a], x0); den = lfilter([1 - a], [1, -a], finite.astype(np.float64))
      with np.errstate(invalid="ignore", divide="ignore"):
        feats.append(np.where(finite & (den > 1e-6), num / den, np.nan))
    since = ctx.minutes_since_exertion
    feats.append(np.minimum(np.where(np.isfinite(since), since, 120.0), 120.0))
    return np.column_stack(feats)

  def _fit_response(self, tl, ctx, mask):
    p = self.params.get("hr")
    if p is None:
      self.info["response_reason"] = "no heart-rate baseline"
      return
    base_expected, _ = self._lookup("hr", ctx)
    y = tl["hr"] - base_expected
    X = self.response_features(tl, ctx)
    rows = mask & np.isfinite(y) & np.all(np.isfinite(X), axis=1)
    if rows.sum() < RESPONSE_MIN_ROWS:
      self.info["response_reason"] = "too few minutes with movement data"
      return
    idx = np.flatnonzero(rows)
    fold = (tl.local_day[idx] % 2).astype(bool)
    if fold.all() or (~fold).all():
      self.info["response_reason"] = "movement data on one day only"
      return
    sse_model = sse_zero = 0.0
    for test in (fold, ~fold):
      model = _ridge_fit(X[idx[~test]], y[idx[~test]])
      pred = _ridge_predict(model, X[idx[test]])
      sse_model += float(np.sum((y[idx[test]] - pred) ** 2)); sse_zero += float(np.sum(y[idx[test]] ** 2))
    gain = 1 - sse_model / sse_zero if sse_zero > 0 else 0.0
    self.info["response_gain"] = round(gain, 4)
    if gain < RESPONSE_MIN_GAIN:
      self.info["response_reason"] = "movement model did not improve out-of-sample heart-rate fit"
      return
    model = _ridge_fit(X[idx], y[idx])
    resid = y[idx] - _ridge_predict(model, X[idx])
    cells = ctx.code[idx] * len(BANDS) + ctx.band[idx]
    saved_mode = self.mode
    self.mode = "context"
    scale_fit = self._fit_channel("hr", resid + p["global"][0], ctx.code[idx], cells, tl.local_day[idx])
    self.mode = saved_mode
    self.response = {"model": model, "scale": scale_fit["scale"] if scale_fit else None}
    self.info["response_used"] = True

  # ------------------------------------------------------------------------------------------- transform
  def _lookup(self, ch, ctx):
    p = self.params.get(ch)
    n = len(ctx.code)
    if p is None:
      return np.full(n, np.nan), np.full(n, np.nan)
    if self.mode == "raw":
      med, sd = p["global"]
      expected = np.full(n, med); scale = np.full(n, sd)
      off = ctx.code == C["off"]
      expected[off] = np.nan; scale[off] = np.nan
      return expected, scale
    return p["center"][ctx.code, ctx.band], p["scale"][ctx.code, ctx.band]

  def transform(self, tl: Timeline, ctx: Context) -> Deviation:
    z, expected, scale, resid, source, support = {}, {}, {}, {}, {}, {}
    for ch in CHANNELS:
      e, s = self._lookup(ch, ctx)
      src = np.where(np.isfinite(e) & np.isfinite(s), "engine_context", "none").astype(object)
      sup = self.support(ch, ctx)
      if self.mode in LAYER1_MODES and ch in LAYER1_CHANNELS:
        le, ls, lsrc, ldays = self._layer1_lookup(ch, tl, ctx)
        use = np.isfinite(le) & np.isfinite(ls)
        e = np.where(use, le, e); s = np.where(use, ls, s)
        src = np.where(use, lsrc, src).astype(object); sup = np.where(use, ldays, sup)
      x = tl[SOURCE[ch]]
      if ch == "hr" and self.response is not None and self.response["scale"] is not None:
        X = self.response_features(tl, ctx)
        ok = np.all(np.isfinite(X), axis=1) & np.isfinite(e)
        pred = np.full(len(tl), np.nan)
        if ok.any():
          pred[ok] = _ridge_predict(self.response["model"], X[ok])
        rs = self.response["scale"][ctx.code, ctx.band]
        # Minutes without movement inputs keep the context-only expectation and scale.
        e = np.where(ok, e + pred, e); s = np.where(ok & np.isfinite(rs), rs, s)
      with np.errstate(invalid="ignore"):
        r = x - e
        z[ch] = r / s
      expected[ch], scale[ch], resid[ch] = e, s, r
      source[ch], support[ch] = src, sup
    return Deviation(z=z, expected=expected, scale=scale, residual=resid, support=support, source=source)

  def support(self, ch, ctx) -> np.ndarray:
    """Distinct local days (>= 30 fitting minutes each) behind the baseline the minute uses (its own context's, or
    the parent's it borrows). Raw mode: days of the global baseline."""
    p = self.params.get(ch)
    n = len(ctx.code)
    if p is None:
      return np.zeros(n)
    if self.mode == "raw":
      return np.where(ctx.code == C["off"], 0.0, float(p.get("global_days", 0)))
    return p["days"].astype(np.float64)[ctx.code]

  def baselines(self, tl: Timeline, ctx: Context, dev: Deviation | None = None) -> dict:
    """Report summary (data_quality.baselines): per channel the share of worn minutes compared with each baseline
    source, and per context which baseline it uses, its status, days and centre / scale in physical units - so the
    app can say "compared with your seated heart-rate baseline (provisional, 9 days)"."""
    dev = dev if dev is not None else self.transform(tl, ctx)
    worn = tl["wear"]
    out = {"mode": self.mode, "channels": {}}
    layer = l1ctx.cached(tl, ctx) if self.mode in LAYER1_MODES else None
    if layer is not None:
      out["layer1"] = {"available": bool(layer.available), "reason": layer.reason}
    strata = layer.summary() if layer is not None and layer.available else {}
    for ch in LAYER1_CHANNELS:
      have = worn & np.isfinite(tl[SOURCE[ch]])
      n = int(have.sum())
      shares = {s: (round(float(np.mean(dev.source[ch][have] == s)), 3) if n else 0.0) for s in SOURCES}
      contexts = []
      for key, item in strata.items():
        if item["channel"] != ch:
          continue
        contexts.append({"context": item["stratum"], "source": "layer1", "series": key, "status": item["status"],
                         "days": item["days"], "center": item["center"], "scale": item["scale"],
                         "unit": item["unit"]})
      p = self.params.get(ch)
      if p is not None and self.mode != "raw":
        for c in range(len(CONTEXTS)):
          if c == C["off"] or not np.isfinite(p["center"][c]).any():
            continue
          w = p["counts"][c].astype(np.float64)
          w = w if w.sum() > 0 else np.ones(len(BANDS))
          center = float(np.average(p["center"][c], weights=w)); sc = float(np.average(p["scale"][c], weights=w))
          if ch == "hrv":
            mid = float(np.exp(center)); center, sc = mid, mid * float(np.sinh(sc))
          days = int(p["days"][c])
          contexts.append({"context": CONTEXTS[c], "source": "engine_context",
                           # Day thresholds of Layer 1 (shown from 4, established at 14); "learning" below 4.
                           "status": ("established" if days >= 14 else "provisional" if days >= 4
                                      else "learning"),
                           "days": days, "center": center, "scale": sc, "unit": UNITS[ch],
                           "borrowed_from": p.get("fallback", {}).get(CONTEXTS[c])})
      out["channels"][ch] = {"sources": shares, "contexts": contexts}
    return out

  def describe(self) -> dict:
    out = dict(self.info)
    out["channels"] = {ch: (None if p is None else int(p["n"])) for ch, p in self.params.items()}
    out["fallback"] = {ch: p["fallback"] for ch, p in self.params.items() if p is not None and p.get("fallback")}
    return out


def _ridge_fit(X, y, alpha=10.0):
  mu = X.mean(axis=0); sd = X.std(axis=0); sd[sd < 1e-9] = 1.0
  Z = (X - mu) / sd
  ym = float(y.mean())
  A = Z.T @ Z + alpha * np.eye(Z.shape[1])
  w = np.linalg.solve(A, Z.T @ (y - ym))
  return {"mu": mu, "sd": sd, "w": w, "b": ym}


def _ridge_predict(m, X):
  return ((X - m["mu"]) / m["sd"]) @ m["w"] + m["b"]
