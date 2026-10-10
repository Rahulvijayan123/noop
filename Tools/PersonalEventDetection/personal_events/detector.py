"""Scorers, detectability d, certified thresholds and episodes (docs/PHENOTYPE_SIGNATURES.md, section 6).

Every scorer reads causal trailing features only: the score at minute t uses minutes <= t. Scores are larger
when an event is more likely; they are not probabilities.
"""
from __future__ import annotations

import dataclasses
import math
import warnings

import numpy as np
from scipy import stats

from .baseline import CHANNELS, Deviation
from .context import GROUPS, CONTEXTS, Context
from .policy import EpisodeState, Policy

TRAILING = (1, 5, 15)
EVENT_WINDOW_MIN = 10
DECISIONS_PER_DAY = 100
BUDGETS = (0.5, 1.0, 2.0)
PRIMARY_BUDGET = 1.0
CERT_LEVEL = 0.80
PERSISTENCE = 2
COOLDOWN_S = 30 * 60
OVERDISPERSION = True
MAX_DISPERSION = 10.0
TEMPLATE_LAGS = (-20, 5)
LOGISTIC_C = (0.01, 0.1, 1.0)
MAX_NEGATIVE_SAMPLES = 3000
METHODS = ("logistic", "hr_rule_raw", "hr_rule_context", "template")


# --------------------------------------------------------------------------------------------- features

def trailing_mean(x, w):
  n = len(x)
  f = np.isfinite(x)
  cs = np.r_[0.0, np.cumsum(np.where(f, x, 0.0))]; cc = np.r_[0, np.cumsum(f)]
  hi = np.arange(1, n + 1); lo = np.maximum(0, hi - w)
  cnt = cc[hi] - cc[lo]
  need = max(1, (w + 1) // 2)
  with np.errstate(invalid="ignore", divide="ignore"):
    return np.where(cnt >= need, (cs[hi] - cs[lo]) / np.maximum(cnt, 1), np.nan)


def context_onehot(ctx: Context):
  names = list(GROUPS)
  out = np.zeros((len(ctx.code), len(names)))
  for gi, g in enumerate(names):
    codes = [CONTEXTS.index(c) for c in GROUPS[g]]
    out[:, gi] = np.isin(ctx.code, codes)
  return out, [f"ctx_{g}" for g in names]


N_Z_FEATURES = len(CHANNELS) * len(TRAILING)
HR_FEATURE = CHANNELS.index("hr") * len(TRAILING)        # hr_z_1
# A minute is scored by the logistic model only with HR present and at least this share of its z features
# observed (not imputed): otherwise the score is mostly imputation and fires where nothing was measured.
MIN_OBSERVED_SHARE = 0.4


MIN_CHANNEL_SHARE = 0.5
LOGISTIC_CONTEXT = True


def scorable(F, cols=None):
  cols = list(range(N_Z_FEATURES)) if cols is None else cols
  return np.isfinite(F[:, HR_FEATURE]) & (np.isfinite(F[:, cols]).mean(axis=1) >= MIN_OBSERVED_SHARE)


def design(F, cols=None):
  """Logistic design matrix: the used z features with NaN -> 0, one missingness indicator per used z feature,
  context one-hot."""
  cols = list(range(N_Z_FEATURES)) if cols is None else cols
  Z = F[:, cols]
  miss = ~np.isfinite(Z)
  parts = [np.where(miss, 0.0, Z), miss.astype(np.float64)]
  if LOGISTIC_CONTEXT:
    parts.append(F[:, N_Z_FEATURES:])
  return np.column_stack(parts)


def trailing_features(dev: Deviation, ctx: Context):
  cols, names = [], []
  for ch in CHANNELS:
    for w in TRAILING:
      cols.append(trailing_mean(dev.z[ch], w)); names.append(f"{ch}_z_{w}")
  oh, on = context_onehot(ctx)
  return np.column_stack(cols + [oh]), names + on


# --------------------------------------------------------------------------------------------- scorers

@dataclasses.dataclass
class TrainingSet:
  """Minute indices for positives (aligned onset .. +10 min of training events) and negatives (matched control
  windows, observation periods, reviewed negatives), plus the local day of each sample."""
  pos: np.ndarray
  neg: np.ndarray
  pos_group: np.ndarray     # event number of each positive minute
  day_pos: np.ndarray
  day_neg: np.ndarray


def training_set(tl, event_idxs, control_idxs, negative_minutes, rng):
  pos, grp = [], []
  for k, i in enumerate(event_idxs):
    pos.extend(range(i, i + EVENT_WINDOW_MIN)); grp.extend([k] * EVENT_WINDOW_MIN)
  neg = [j + d for cs in control_idxs for j in cs for d in range(EVENT_WINDOW_MIN)]
  extra = np.asarray(negative_minutes, dtype=np.int64)
  if len(extra) > MAX_NEGATIVE_SAMPLES:
    extra = np.sort(rng.choice(extra, MAX_NEGATIVE_SAMPLES, replace=False))
  neg = np.unique(np.r_[np.asarray(neg, dtype=np.int64), extra]).astype(np.int64)
  pos = np.asarray(pos, dtype=np.int64)
  day = tl.local_day
  n = len(tl)
  okp = (pos >= 0) & (pos < n); okn = (neg >= 0) & (neg < n)
  return TrainingSet(pos=pos[okp], neg=neg[okn], pos_group=np.asarray(grp, dtype=np.int64)[okp],
                     day_pos=day[pos[okp]], day_neg=day[neg[okn]])


class LogisticScorer:
  name = "logistic"

  def __init__(self, C=None):
    self.C = C; self.model = None; self.cols = None; self.info = {}

  def fit(self, F, ts: TrainingSet):
    """Missing channel z features are imputed with 0 (= the usual value) plus a missingness indicator per
    feature, so a channel that is often absent (HRV, breathing, motion) does not stop scoring. HR must be
    present: rows without HR are neither trained on nor scored."""
    from sklearn.linear_model import LogisticRegression
    if len(ts.pos) < 5 or len(ts.neg) < 20:
      self.info = {"reason": "too little data"}; return self
    idx = np.r_[ts.pos, ts.neg]; y = np.r_[np.ones(len(ts.pos)), np.zeros(len(ts.neg))]
    groups = np.r_[ts.day_pos, ts.day_neg]
    # A channel enters only if observed in >= half of the training negatives: a stream that is mostly absent
    # in training (e.g. an accelerometer that appears later) would otherwise shift scores on new days in a way
    # out-of-fold certification on the training days cannot see.
    obs = np.isfinite(F[ts.neg, :N_Z_FEATURES]).mean(axis=0) if len(ts.neg) else np.zeros(N_Z_FEATURES)
    per = len(TRAILING)
    self.cols = [c for ci in range(len(CHANNELS)) for c in range(ci * per, (ci + 1) * per)
                 if CHANNELS[ci] == "hr" or obs[ci * per:(ci + 1) * per].mean() >= MIN_CHANNEL_SHARE]
    rows = scorable(F[idx], self.cols)
    if len(np.unique(ts.day_pos[rows[:len(ts.pos)]])) < 2:
      self.info = {"reason": "too little data"}; return self
    X = design(F[idx[rows]], self.cols); y = y[rows]; groups = groups[rows]
    if y.sum() < 5 or (1 - y).sum() < 20:
      self.info = {"reason": "too little data"}; return self
    C = self.C if self.C is not None else self._choose_C(X, y, groups)
    with warnings.catch_warnings():
      warnings.simplefilter("ignore")
      self.model = LogisticRegression(C=C, class_weight="balanced", max_iter=500).fit(X, y)
    self.C = C; self.info = {"C": C, "features": int(X.shape[1]),
                             "channels": sorted({CHANNELS[c // len(TRAILING)] for c in self.cols})}
    return self

  @staticmethod
  def _choose_C(X, y, groups):
    from sklearn.linear_model import LogisticRegression
    pos_days = np.unique(groups[y == 1])
    if len(pos_days) < 3:
      return 0.1
    folds = np.array_split(pos_days, min(5, len(pos_days)))
    best, best_loss = 0.1, np.inf
    for C in LOGISTIC_C:
      loss = 0.0; count = 0
      for fd in folds:
        test = np.isin(groups, fd)
        if y[~test].sum() == 0 or (1 - y[~test]).sum() == 0 or not test.any():
          continue
        with warnings.catch_warnings():
          warnings.simplefilter("ignore")
          m = LogisticRegression(C=C, class_weight="balanced", max_iter=500).fit(X[~test], y[~test])
        p = np.clip(m.predict_proba(X[test])[:, 1], 1e-6, 1 - 1e-6)
        w = np.where(y[test] == 1, 0.5 / max(y[test].sum(), 1), 0.5 / max((1 - y[test]).sum(), 1))
        loss += float(-(w * (y[test] * np.log(p) + (1 - y[test]) * np.log(1 - p))).sum()); count += 1
      if count and loss / count < best_loss - 1e-12:
        best, best_loss = C, loss / count
    return best

  def score(self, F):
    out = np.full(len(F), np.nan)
    if self.model is None:
      return out
    ok = scorable(F, self.cols)
    if ok.any():
      out[ok] = self.model.decision_function(design(F[ok], self.cols))
    return out


class TemplateScorer:
  name = "template"

  def __init__(self):
    self.template = None; self.info = {}

  def fit(self, dev: Deviation, event_idxs, control_idxs):
    a, b = TEMPLATE_LAGS
    lags = np.arange(a, b + 1)
    temp = {}
    for ch in CHANNELS:
      z = dev.z[ch]
      rows = []
      for i, cs in zip(event_idxs, control_idxs):
        ev = _take(z, i + lags)
        if not cs:
          continue
        cp = np.array([_take(z, j + lags) for j in cs])
        cnt = np.isfinite(cp).sum(0)
        with np.errstate(invalid="ignore", divide="ignore"):
          rows.append(ev - np.where(cnt > 0, np.nansum(cp, 0) / np.maximum(cnt, 1), np.nan))
      if len(rows) < 3:
        continue
      R = np.array(rows); cnt = np.isfinite(R).sum(0)
      with np.errstate(invalid="ignore", divide="ignore"):
        m = np.where(cnt >= 2, np.nansum(R, 0) / np.maximum(cnt, 1), np.nan)
      if np.isfinite(m).mean() >= 0.8 and np.nanstd(m) > 1e-6:
        temp[ch] = m
    self.template = temp or None
    self.info = {"channels": sorted(temp)}
    return self

  def score(self, dev: Deviation):
    n = len(next(iter(dev.z.values())))
    if not self.template:
      return np.full(n, np.nan)
    a, b = TEMPLATE_LAGS
    L = b - a + 1
    Xs, Ts = [], []
    for ch, t in self.template.items():
      z = np.r_[np.full(L - 1, np.nan), dev.z[ch]]
      Xs.append(np.lib.stride_tricks.sliding_window_view(z, L)); Ts.append(t)
    X = np.concatenate(Xs, axis=1); T = np.concatenate(Ts)
    M = np.isfinite(X) & np.isfinite(T)[None, :]
    Xz = np.where(M, X, 0.0); Tz = np.where(M, T[None, :], 0.0)
    cnt = M.sum(1)
    with np.errstate(invalid="ignore", divide="ignore"):
      mx = Xz.sum(1) / cnt; mt = Tz.sum(1) / cnt
      cov = (Xz * Tz).sum(1) / cnt - mx * mt
      vx = (Xz * Xz).sum(1) / cnt - mx ** 2; vt = (Tz * Tz).sum(1) / cnt - mt ** 2
      r = cov / np.sqrt(vx * vt)
    return np.where((cnt >= 0.5 * X.shape[1]) & (vx > 1e-9) & (vt > 1e-9), r, np.nan)


def _take(x, pos):
  out = np.full(len(pos), np.nan)
  ok = (pos >= 0) & (pos < len(x))
  out[ok] = x[pos[ok]]
  return out


# --------------------------------------------------------------------------------------------- detectability

def window_scores(scores, idxs, width=EVENT_WINDOW_MIN):
  """Mean score over [i, i + width) per anchor; NaN with fewer than half the minutes finite."""
  out = np.full(len(idxs), np.nan)
  for k, i in enumerate(idxs):
    seg = scores[i:i + width]
    f = np.isfinite(seg)
    if f.sum() * 2 >= width:
      out[k] = seg[f].mean()
  return out


def separation(ev, ct):
  ev = ev[np.isfinite(ev)]; ct = ct[np.isfinite(ct)]
  if len(ev) < 2 or len(ct) < 2:
    return None
  pooled = math.sqrt(((len(ev) - 1) * ev.var(ddof=1) + (len(ct) - 1) * ct.var(ddof=1)) / (len(ev) + len(ct) - 2))
  if pooled <= 1e-12:
    return None
  return float((ev.mean() - ct.mean()) / pooled)


def expected_recall(d, budgets=BUDGETS, decisions=DECISIONS_PER_DAY):
  """Gaussian relation: about 100 near-independent decisions per waking day; at b false alerts/day each decision
  may fire with probability b / 100, so recall = 1 - Phi(z_(1 - b/100) - d)."""
  out = {}
  for b in budgets:
    key = f"{b:g}"
    out[key] = None if d is None else round(float(1 - stats.norm.cdf(stats.norm.ppf(1 - b / decisions) - d)), 3)
  return out


def detected_in_windows(scores, idxs, thr, width=EVENT_WINDOW_MIN, persistence=PERSISTENCE):
  """Per anchor: does the score stay >= thr for `persistence` consecutive minutes inside [i, i + width)?"""
  out = np.zeros(len(idxs), bool)
  for k, i in enumerate(idxs):
    run = 0
    for v in scores[i:i + width]:
      run = run + 1 if np.isfinite(v) and v >= thr else 0
      if run >= persistence:
        out[k] = True; break
  return out


def empirical_recall(times, scores, neg_mask, event_idxs, budgets=BUDGETS, min_days=1.0):
  """Expected recall measured on cross-validated scores instead of the Gaussian relation: for each budget, the
  lowest threshold whose false episodes per monitored day on CV negative time (episode counter) meet the budget;
  recall = share of CV event windows reaching it (Wilson 95 % CI). None where there is too little negative time."""
  s = np.asarray(scores, dtype=np.float64)
  neg_t = np.asarray(times, dtype=np.float64)[neg_mask]; neg_s = s[neg_mask]
  f = np.isfinite(neg_s)
  days = f.sum() / 1440.0
  recall = {f"{b:g}": None for b in budgets}; ci = {f"{b:g}": [None, None] for b in budgets}
  thresholds = {f"{b:g}": None for b in budgets}
  if days < min_days or not len(event_idxs):
    return recall, ci, thresholds, round(float(days), 3)
  v = neg_s[f]
  med = float(np.median(v)); sigma = max(float(np.median(np.abs(v - med))) * 1.4826, 1e-6)
  grid = np.unique(np.quantile(v, np.r_[np.linspace(0.5, 0.99, 50), 1 - np.logspace(-2, -5, 16)]))
  grid = np.r_[grid, v.max() + sigma][::-1]
  counts = []
  for thr in grid:
    counts.append(len(episodes(neg_t, neg_s, thr, thr - 0.5 * sigma)))
  for b in budgets:
    key = f"{b:g}"
    best = None
    for thr, k in zip(grid, counts):
      if k / days <= b:
        best = thr
      else:
        break
    if best is None:
      continue
    hit = detected_in_windows(s, event_idxs, best)
    recall[key] = round(float(hit.mean()), 3); ci[key] = wilson(int(hit.sum()), len(hit))
    thresholds[key] = float(best)
  return recall, ci, thresholds, round(float(days), 3)


def d_with_ci(ev_scores, ct_scores, ev_days, ct_days, rng, B=500):
  d = separation(ev_scores, ct_scores)
  if d is None:
    return None, [None, None]
  uniq = np.unique(ev_days)
  if len(uniq) < 3:
    return d, [None, None]
  boots = []
  for _ in range(B):
    pick = rng.choice(uniq, len(uniq), replace=True)
    e = np.concatenate([ev_scores[ev_days == u] for u in pick])
    c = np.concatenate([ct_scores[ct_days == u] for u in pick])
    v = separation(e, c)
    if v is not None:
      boots.append(v)
  if len(boots) < 50:
    return d, [None, None]
  lo, hi = np.percentile(boots, [2.5, 97.5])
  return d, [round(float(lo), 3), round(float(hi), 3)]


def assess(d, d_ci, n_events, n_days, recall=None, recall_ci=None):
  """promising only if the empirical expected recall at 1 false alert/day is >= 0.5 with a Wilson lower bound
  >= 0.3 and the lower end of d's CI is >= 2."""
  if n_events < 3 or n_days < 3:
    return "insufficient_data"
  r = (recall or {}).get("1"); lo = ((recall_ci or {}).get("1") or [None])[0]
  if r is not None and lo is not None and r >= 0.5 and lo >= 0.3 and d_ci and d_ci[0] is not None and d_ci[0] >= 2:
    return "promising"
  return "too_weak_for_alerts"


# --------------------------------------------------------------------------------------------- episodes

def poisson_upper(k, level=CERT_LEVEL):
  return float(stats.chi2.ppf(level, 2 * (k + 1)) / 2)


def poisson_ci(k, level=0.95):
  a = 1 - level
  lo = 0.0 if k == 0 else float(stats.chi2.ppf(a / 2, 2 * k) / 2)
  return lo, float(stats.chi2.ppf(1 - a / 2, 2 * (k + 1)) / 2)


def wilson(k, n, z=1.959964):
  if n == 0:
    return [None, None]
  p = k / n
  den = 1 + z * z / n
  c = (p + z * z / (2 * n)) / den
  h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
  return [round(max(0.0, c - h), 3), round(min(1.0, c + h), 3)]


def episodes(times, scores, enter, exit_, persistence=PERSISTENCE, cooldown=COOLDOWN_S):
  """Episodes exactly as EpisodeState (smoothing 1) produces them on a minute stream where a non-finite score or a
  missing minute resets the state. Vectorised over runs: cost scales with episodes, not minutes.
  Returns a list of (start, detected_at, end)."""
  t = np.asarray(times, dtype=np.float64); s = np.asarray(scores, dtype=np.float64)
  n = len(t)
  if not n:
    return []
  finite = np.isfinite(s)
  contiguous = np.r_[False, (np.diff(t) <= 90) & finite[1:] & finite[:-1]]
  seg_start = np.where(~contiguous)[0]
  seg_id = np.cumsum(~contiguous) - 1
  seg_end = np.r_[seg_start[1:] - 1, n - 1][seg_id]
  above = finite & (s >= enter)
  # run length of consecutive 'above' minutes ending at i, within a segment
  run = np.zeros(n, np.int64)
  idx = np.flatnonzero(above)
  if len(idx):
    brk = np.r_[True, (np.diff(idx) != 1) | (~contiguous[idx[1:]])]
    starts = np.maximum.accumulate(np.where(brk, idx, 0))
    run[idx] = idx - starts + 1
  cands = np.flatnonzero(run >= persistence)
  below = np.flatnonzero(finite & (s < exit_))
  out = []
  pos = 0; last_end = -np.inf
  while True:
    first_ok = max(pos, int(np.searchsorted(t, last_end + cooldown, side="left")))
    k = int(np.searchsorted(cands, first_ok + persistence - 1, side="left"))
    while k < len(cands) and cands[k] - persistence + 1 < first_ok:
      k += 1
    if k >= len(cands):
      break
    c = int(cands[k])
    # the p minutes ending at c must all be >= first_ok and in one above-run (run[c] >= p guarantees the run)
    start_i = c - persistence + 1
    m = int(np.searchsorted(below, c + 1, side="left"))
    end_i = int(seg_end[c])
    if m < len(below) and below[m] <= end_i:
      stop = int(below[m])
      out.append((t[start_i], t[c], t[stop - 1]))
      last_end = t[stop]; pos = stop + 1
    else:
      out.append((t[start_i], t[c], t[end_i]))
      last_end = t[end_i]; pos = end_i + 1
  return out


def episode_policy(enter_raw, exit_raw, sigma):
  """Map raw score thresholds to PR #5's Policy in [0, 1] via u = expit((s - enter) / sigma)."""
  exit_u = 1 / (1 + math.exp((enter_raw - exit_raw) / sigma))
  return Policy(enter=0.5, exit=exit_u, persistence=PERSISTENCE, smoothing=1, cadence=60, gap=90,
                cooldown=COOLDOWN_S)


def run_episode_state(times, scores, enter_raw, exit_raw, sigma, *, owner="eval", type_id="eval", device="eval"):
  """Alerts via PR #5's EpisodeState (the serving-time state machine)."""
  policy = episode_policy(enter_raw, exit_raw, sigma)
  state = EpisodeState(cursor=float(times[0]) - 60 if len(times) else 0)
  alerts = {}
  with np.errstate(over="ignore"):
    u = 1 / (1 + np.exp(-(np.asarray(scores, dtype=np.float64) - enter_raw) / sigma))
  for t, v in zip(times, u):
    a = state.step(float(t), float(v), owner=owner, type_id=type_id, device=device, model="sig-1", policy=policy)
    if a:
      alerts[a["id"]] = a
  return [(a["start"], a["detected_at"], a["end"]) for a in alerts.values()]


@dataclasses.dataclass
class Threshold:
  enter: float | None
  exit: float | None
  sigma: float | None
  false_alerts: int
  monitored_days: float
  bound_per_day: float | None
  reason: str = ""


def dispersion(det_times, times, finite, day_of):
  """Pearson overdispersion of per-day episode counts against a constant rate per monitored minute (>= 1)."""
  if day_of is None or not len(det_times):
    return 1.0
  days, inv = np.unique(day_of, return_inverse=True)
  monitored = np.bincount(inv, weights=finite.astype(np.float64), minlength=len(days))
  pos = np.clip(np.searchsorted(times, det_times), 0, len(times) - 1)
  counts = np.bincount(inv[pos], minlength=len(days)).astype(np.float64)
  use = monitored >= 60
  if use.sum() < 3:
    return 1.0
  rate = counts[use].sum() / monitored[use].sum()
  expected = rate * monitored[use]
  phi = float(np.sum((counts[use] - expected) ** 2 / np.maximum(expected, 1e-9)) / (use.sum() - 1))
  return float(np.clip(phi, 1.0, MAX_DISPERSION))


def certified_bound(k, days, phi=1.0, level=CERT_LEVEL):
  """80 % Poisson upper bound of the false-alert rate per day, quasi-Poisson for overdispersion phi: the count is
  treated as k / phi events over days / phi (false alerts cluster on some days, e.g. walking-heavy ones)."""
  return poisson_upper(k / phi, level) / (days / phi) if phi > 1 else poisson_upper(k, level) / days


def certify(times, scores, budget=PRIMARY_BUDGET, level=CERT_LEVEL, day_of=None):
  """Lowest threshold whose 80 % (quasi-)Poisson upper bound of false alerts per monitored day on negative time
  meets the budget. With `day_of` (local day of each minute) the bound is widened for day-level overdispersion of
  the episode counts. Abstains (enter None) when even zero alerts cannot be certified on the available time."""
  times = np.asarray(times, dtype=np.float64)
  s = np.asarray(scores, dtype=np.float64)
  f = np.isfinite(s)
  days = f.sum() / 1440.0
  if days <= 0:
    return Threshold(None, None, None, 0, 0.0, None, "no negative time with scores")
  if poisson_upper(0, level) / days > budget:
    return Threshold(None, None, None, 0, round(days, 3), None,
                     f"needs at least {poisson_upper(0, level) / budget:.1f} days of negative time; has {days:.1f}")
  v = s[f]
  med = float(np.median(v)); sigma = max(float(np.median(np.abs(v - med))) * 1.4826, 1e-6)
  grid = np.unique(np.quantile(v, np.r_[np.linspace(0.5, 0.99, 50), 1 - np.logspace(-2, -5, 16)]))
  grid = np.r_[grid, v.max() + sigma]
  best = None
  for thr in grid[::-1]:
    eps = episodes(times, s, thr, thr - 0.5 * sigma)
    phi = dispersion(np.array([d for _, d, _ in eps]), times, f, day_of) if OVERDISPERSION else 1.0
    bound = certified_bound(len(eps), days, phi, level)
    if bound <= budget:
      best = Threshold(float(thr), float(thr - 0.5 * sigma), sigma, len(eps), round(days, 3), round(bound, 3))
    else:
      break
  if best is None:
    return Threshold(None, None, None, 0, round(days, 3), None, "no threshold met the false-alert budget")
  return best
