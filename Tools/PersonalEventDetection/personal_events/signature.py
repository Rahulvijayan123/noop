"""Signature statistics, day-clustered test, replication, status and plain-language findings
(docs/PHENOTYPE_SIGNATURES.md, section 5)."""
from __future__ import annotations

import itertools

import numpy as np

from .baseline import CHANNELS, UNITS, physical_change
from .context import C, GROUPS, CONTEXTS, group_of
from .profiles import CHANGE_CHANNELS, CHANGE_UNITS, CHANGE_WINDOWS, LAGS, WINDOWS

STATUSES = ("insufficient_events", "individual_context", "no_reliable_signature", "emerging", "established")
STATUS_RANK = {"insufficient_events": 0, "individual_context": 1, "no_reliable_signature": 2, "emerging": 3,
               "established": 4}
EXACT_MAX_DAYS = 12
MC_FLIPS = 4095
BOOTSTRAP = 1000
MIN_CELL_EVENTS = 3
T_SD_FLOOR = 0.5
MAX_FINDINGS = 5
# Joint family (sig-4): per post-onset window and family, a shrinkage-LDA combination of all channels.
JOINT_FAMILY = True
JOINT_SHRINK = 0.2
# Change-family joint vectors: "std" = change difference / robust SD of control changes (chosen: calibrated on the
# real-data nulls, and its combined score is in the same SD units as the per-channel values shown); "rank" =
# centred ranks (exactly symmetric per channel, but bounded, so the combined "SD" is not comparable).
JOINT_CHANGE_SCALE = "std"
MAX_JOINT_FINDINGS = 2
# Replication passes if the first half's top single cell or its top joint cell (first-half weights) holds on the
# later events. Without it, the joint family cost replications it would otherwise pass (real-data plants).
REPLICATE_EITHER = True
# A heart-rate / HRV finding is marked movement_accompanied when steps or motion changed (change family, day-
# bootstrap CI excluding 0) in an overlapping window in the direction that would explain it: the change may come
# from moving, not from the event itself.
MOVEMENT_CHANNELS = ("steps", "motion")
MOVEMENT_ACCOMPANIED = {"hr": 1, "hrv": -1}   # movement's usual effect: HR up, HRV down
FINDING_ALPHA = 0.10
SPLIT_MIN_EVENTS = 10
SPLIT_GROUP_EVENTS = 5
SPLIT_GROUP_DAYS = 3
SPLIT_FLIPS = 199  # label-swap draws for the 2-means split test
NAMES = {"hr": "Heart rate", "hrv": "Heart rate variability", "temp": "Skin temperature", "resp": "Breathing rate",
         "motion": "Movement", "steps": "Step rate"}
DECIMALS = {"hr": 1, "hrv": 1, "temp": 2, "resp": 1, "motion": 3, "steps": 0}
TEXT_DECIMALS = {"hr": 0, "hrv": 0, "temp": 2, "resp": 1, "motion": 3, "steps": 0}
TEXT_UNITS = {"hr": " bpm", "hrv": " ms", "temp": " °C", "resp": " breaths/min", "motion": " g", "steps": " steps/min"}


# --------------------------------------------------------------------------------------------- day clusters

def day_sums(X, days):
  """X: (E, K) with NaN -> per-day sums S (D, K), counts N (D, K), sums of squares Q (K,), unique days."""
  uniq, inv = np.unique(days, return_inverse=True)
  finite = np.isfinite(X)
  Xz = np.where(finite, X, 0.0)
  S = np.zeros((len(uniq), X.shape[1])); N = np.zeros_like(S)
  np.add.at(S, inv, Xz); np.add.at(N, inv, finite.astype(np.float64))
  return S, N, (Xz ** 2).sum(axis=0), uniq


def t_stats(sums, n, q):
  """Moderated t of the event-level mean for each cell; sums may be (P, K) under sign flips (q, n unchanged).
  The SD is floored at T_SD_FLOOR z-units so a cell with a few near-identical values cannot dominate max-|t|
  (the floor is part of the statistic, so the sign-flip null stays exact)."""
  with np.errstate(invalid="ignore", divide="ignore"):
    mean = sums / n
    var = (q - n * mean ** 2) / (n - 1)
    var = np.maximum(var, T_SD_FLOOR ** 2)
    return mean / np.sqrt(var / n)


def min_cell_events(n_events):
  """A cell enters the global test with data from at least 3 events and at least half of the events."""
  return max(MIN_CELL_EVENTS, int(np.ceil(0.5 * n_events)))


def flip_matrix(n_days, rng):
  if n_days <= EXACT_MAX_DAYS:
    return np.array(list(itertools.product((1.0, -1.0), repeat=n_days))), True
  F = rng.choice((1.0, -1.0), size=(MC_FLIPS, n_days))
  return np.vstack([np.ones(n_days), F]), False


def global_test(D, days, rng, joint=()):
  """Max-|t| over valid (channel, window) cells, plus the joint cells, with sign flips shared within a local day.
  D: (E, K). Joint cells re-estimate their channel weights inside every flip (see joint_t), so the family-wise
  null covers the weight fitting. Returns dict(p, p_min_possible, t_max, cell, exact, cells_tested, p_cells,
  joint: [(t, adjusted p) per joint cell])."""
  S, N, Q, uniq = day_sums(D, days)
  n = N.sum(axis=0)
  valid = n >= min_cell_events(D.shape[0])
  nd = len(uniq)
  p_min = 2.0 / 2 ** nd if nd else 1.0
  prepared = [joint_prepare(jc, days, D.shape[0]) for jc in joint]
  joint_ok = [pj is not None for pj in prepared]
  if (not valid.any() and not any(joint_ok)) or nd < 1:
    return dict(p=None, p_min_possible=p_min, t_max=None, cell=None, exact=True, cells_tested=0,
                p_cells=np.full(D.shape[1], np.nan), joint=[(None, None)] * len(prepared))
  t_obs = t_stats(S.sum(axis=0), n, Q)
  F, exact = flip_matrix(nd, rng)
  ident = np.ones((1, nd))
  jt_obs = [float(joint_t(pj, ident)[0]) if pj is not None else np.nan for pj in prepared]
  parts_obs = [np.abs(t_obs[valid])] + [np.array([t]) for t, ok in zip(jt_obs, joint_ok) if ok]
  T_obs = float(np.nanmax(np.concatenate(parts_obs)))
  cell = int(np.flatnonzero(valid)[np.nanargmax(np.abs(t_obs[valid]))]) if valid.any() else None
  cols = [np.abs(t_stats(F @ S[:, valid], n[valid], Q[valid]))] if valid.any() else []
  cols += [joint_t(pj, F)[:, None] for pj in prepared if pj is not None]
  T = np.nanmax(np.nan_to_num(np.concatenate(cols, axis=1), nan=0.0), axis=1)
  hits = np.sum(T >= T_obs - 1e-9 * max(1.0, abs(T_obs)))
  p = hits / len(T)                                  # the identity flip is a row of F in both cases
  # Family-wise (max-t) adjusted p per cell: the share of flips whose max-|t| reaches the cell's |t|.
  Ts = np.sort(T)
  adj = lambda x: (len(Ts) - np.searchsorted(Ts, x - 1e-9 * np.maximum(1.0, x), side="left")) / len(Ts)
  p_cells = np.full(D.shape[1], np.nan)
  if valid.any():
    p_cells[valid] = adj(np.abs(t_obs[valid]))
  jres = [(t, float(adj(np.array([t]))[0])) if ok and np.isfinite(t) else (None, None)
          for t, ok in zip(jt_obs, joint_ok)]
  return dict(p=float(max(p, p_min if exact else 1.0 / len(T))), p_min_possible=p_min, t_max=T_obs,
              cell=cell, exact=exact, cells_tested=int(valid.sum()) + int(sum(joint_ok)), p_cells=p_cells,
              joint=jres)


# --------------------------------------------------------------------------------------------- joint family

def _loo_pseudo_level(M):
  """Control-minus-other-controls differences (k, p) from control window means M (k, p)."""
  k = len(M)
  if k < 2:
    return np.empty((0, M.shape[1]))
  fin = np.isfinite(M)
  tot = np.where(fin, M, 0.0).sum(0); cnt = fin.sum(0)
  with np.errstate(invalid="ignore", divide="ignore"):
    others = (tot[None, :] - np.where(fin, M, 0.0)) / (cnt[None, :] - fin)
  return np.where(fin & ((cnt[None, :] - fin) > 0), M - others, np.nan)


def _loo_pseudo_rank(M):
  """Centred rank of each control's change among the other controls (k, p), in [-1, 1]."""
  k = len(M)
  out = np.full(M.shape, np.nan)
  for j in range(k):
    others = np.delete(M, j, axis=0)
    fin = np.isfinite(others)
    cnt = fin.sum(0)
    below = np.where(fin, others < M[j][None, :], False).sum(0) + 0.5 * np.where(fin, others == M[j][None, :], False).sum(0)
    half = cnt / 2.0
    with np.errstate(invalid="ignore", divide="ignore"):
      out[j] = np.where(np.isfinite(M[j]) & (cnt >= 2), (below - half) / half, np.nan)
  return out


def joint_cells(paired):
  """One joint cell per (family, post-onset window). Each holds per-event channel vectors d (E, p; NaN = missing),
  display z / physical means, and the null covariance Sigma of d estimated from control-minus-control variation
  of the same quantity (so correlated channels, e.g. HR and motion, are not double-counted)."""
  cells = []
  E = paired.D_z.shape[0]
  if not E:
    return cells
  post = [WINDOWS.index(w) for w in CHANGE_WINDOWS]
  for wi_level, w in zip(post, CHANGE_WINDOWS):
    pseudo = [_loo_pseudo_level(M[1:, :, wi_level]) for M in (paired.win_z or []) if len(M) > 2]
    cells.append(dict(family="level", window=w, channels=list(CHANNELS), units=[UNITS[c] for c in CHANNELS],
                      d=paired.D_z[:, :, wi_level], zdisp=paired.D_z[:, :, wi_level],
                      phys=paired.D_res[:, :, wi_level], center=paired.center,
                      pseudo=np.concatenate(pseudo) if pseudo else np.empty((0, len(CHANNELS)))))
  if paired.D_change is not None and paired.change_win is not None:
    scale = paired.change_scale if paired.change_scale is not None else np.ones((len(CHANGE_CHANNELS), len(CHANGE_WINDOWS)))
    for wi, w in enumerate(CHANGE_WINDOWS):
      ctrl = [M[1:, :, wi] for M in paired.change_win if len(M) > 2]
      if JOINT_CHANGE_SCALE == "rank":
        d = paired.D_change_rank[:, :, wi]
        pseudo = [_loo_pseudo_rank(M) for M in ctrl]
      else:
        d = paired.D_change[:, :, wi] / scale[None, :, wi]
        pseudo = [_loo_pseudo_level(M) / scale[None, :, wi] for M in ctrl]
      cells.append(dict(family="change", window=w, channels=list(CHANGE_CHANNELS),
                        units=[CHANGE_UNITS[c] for c in CHANGE_CHANNELS], d=d,
                        zdisp=paired.D_change[:, :, wi] / scale[None, :, wi], phys=paired.D_change[:, :, wi],
                        center=None,
                        pseudo=np.concatenate(pseudo) if pseudo else np.empty((0, len(CHANGE_CHANNELS)))))
  return cells


def joint_prepare(cell, days, n_events):
  """Channels with data in >= min_cell_events events enter; missing entries are 0 (= no deviation, which is
  invariant under sign flips). Sigma = second moment of the 0-imputed control pseudo-differences, shrunk by
  lambda = JOINT_SHRINK * mean diagonal. Returns None when the cell cannot be formed."""
  d = np.asarray(cell["d"], dtype=np.float64)
  have = np.isfinite(d)
  keep = np.flatnonzero(have.sum(0) >= min_cell_events(n_events))
  P = cell["pseudo"]
  if len(keep) < 2 or len(P) < 10:
    return None
  d = d[:, keep]; have = have[:, keep]; P = P[:, keep]
  valid = have.any(1)
  if valid.sum() < min_cell_events(n_events):
    return None
  d0 = np.where(have, d, 0.0); d0[~valid] = 0.0
  P0 = np.where(np.isfinite(P), P, 0.0)
  sig = P0.T @ P0 / len(P0)
  lam = JOINT_SHRINK * max(float(np.trace(sig)) / len(keep), 1e-6)
  sig = sig + lam * np.eye(len(keep))
  uniq, inv = np.unique(days, return_inverse=True)
  S = np.zeros((len(uniq), len(keep))); np.add.at(S, inv, d0)
  return dict(keep=keep, d0=d0, valid=valid, n=float(valid.sum()), S=S, M2=d0.T @ d0, sig=sig,
              A=np.linalg.inv(sig), inv=inv, cell=cell)


def joint_weights(pj, mu):
  """Shrinkage-LDA direction (Sigma + lambda I)^-1 mu, scaled to unit Sigma-norm (scores in null-SD units)."""
  w = mu @ pj["A"]
  norm2 = np.einsum("...i,ij,...j->...", w, pj["sig"], w)
  with np.errstate(invalid="ignore", divide="ignore"):
    return w / np.sqrt(norm2)[..., None]


def joint_t(pj, F):
  """Moderated t of the joint score s_i = w . d_i for every sign-flip row of F (P, days). The weights are
  re-estimated from the flipped event mean in every row, so the max-t null includes the weight fitting.
  Flipping all signs flips w as well, so s - and t - are unchanged (smallest p stays 2 / 2^days)."""
  mu = (F @ pj["S"]) / pj["n"]
  w = joint_weights(pj, mu)
  mean = np.einsum("pi,pi->p", w, mu)
  q = np.einsum("pi,ij,pj->p", w, pj["M2"], w)
  t = t_stats(mean * pj["n"], pj["n"], q)
  return np.where(np.isfinite(t), t, 0.0)


def bootstrap_weights(days, rng, B=BOOTSTRAP):
  uniq = np.unique(days)
  return rng.multinomial(len(uniq), np.full(len(uniq), 1.0 / len(uniq)), size=B).astype(np.float64)


def cluster_ci(X, days, W):
  """Day-clustered bootstrap 95 % CI of the event-level mean for each column of X (E, K)."""
  S, N, _, _ = day_sums(X, days)
  with np.errstate(invalid="ignore", divide="ignore"):
    boot = (W @ S) / (W @ N)
  lo = np.full(X.shape[1], np.nan); hi = np.full(X.shape[1], np.nan)
  for k in range(X.shape[1]):
    b = boot[:, k]; b = b[np.isfinite(b)]
    if len(b) >= 20:
      lo[k], hi[k] = np.percentile(b, [2.5, 97.5])
  return lo, hi


def cell_layout():
  """(family, channel, window) of every cell of the union: level family (5 channels x 6 windows), then change
  family (6 channels x 3 windows)."""
  out = [("level", ch, w) for ch in CHANNELS for w in WINDOWS]
  out += [("change", ch, w) for ch in CHANGE_CHANNELS for w in CHANGE_WINDOWS]
  return out


def union_matrices(paired):
  """(X_test, X_phys, X_z) over both families. X_test drives the max-t test and replication: level-family z
  differences, and change-family centred ranks (symmetric under the null). X_phys gives magnitudes and CIs in
  physical units; X_z gives change_z (change family: physical difference / robust SD of control changes)."""
  E = paired.D_z.shape[0]
  shape = (E, len(CHANGE_CHANNELS), len(CHANGE_WINDOWS))
  Dc = paired.D_change if paired.D_change is not None else np.full(shape, np.nan)
  Dr = paired.D_change_rank if paired.D_change_rank is not None else np.full(shape, np.nan)
  scale = paired.change_scale if paired.change_scale is not None else np.ones(shape[1:])
  X_test = np.concatenate([paired.D_z.reshape(E, -1), Dr.reshape(E, -1)], axis=1)
  X_phys = np.concatenate([paired.D_res.reshape(E, -1), Dc.reshape(E, -1)], axis=1)
  X_z = np.concatenate([paired.D_z.reshape(E, -1), (Dc / scale[None]).reshape(E, -1)], axis=1)
  return X_test, X_phys, X_z


def cell_table(X_test, X_phys, X_z, days, W):
  n = np.isfinite(X_test).sum(axis=0)
  have = np.isfinite(X_test)
  with np.errstate(invalid="ignore", divide="ignore"):
    mt = np.where(n > 0, np.nansum(X_test, axis=0) / np.maximum(n, 1), np.nan)
    mz = np.where(n > 0, np.nansum(np.where(have, X_z, np.nan), axis=0) / np.maximum(n, 1), np.nan)
    mr = np.where(n > 0, np.nansum(np.where(have, X_phys, np.nan), axis=0) / np.maximum(n, 1), np.nan)
  S, N, Q, _ = day_sums(X_test, days)
  t = t_stats(S.sum(axis=0), N.sum(axis=0), Q)
  same = np.where(have, np.sign(X_test) == np.sign(mt)[None, :], False).sum(axis=0)
  lo, hi = cluster_ci(np.where(have, X_phys, np.nan), days, W)
  return dict(mean_z=mz, mean_res=mr, t=t, n=n, same=same, ci_lo=lo, ci_hi=hi)


# --------------------------------------------------------------------------------------------- replication

def replication(X, days, rng, joint=()):
  """X: (E, K) test cells; joint: joint cells. Split events in time by day (first half of the event days vs the
  rest). The first part's top cell - a single cell, or a joint cell with weights fitted on the first part only -
  must hold its sign with a day-bootstrap CI excluding 0 on the later events (joint: the later events' scores
  under the first part's weights)."""
  uniq = np.unique(days)
  if len(uniq) < 4:
    return "not_yet_testable", None
  first_days = uniq[: (len(uniq) + 1) // 2]
  first = np.isin(days, first_days); later = ~first
  if later.sum() < 3 or len(np.unique(days[later])) < 2 or first.sum() < 3:
    return "not_yet_testable", None
  S, N, Q, _ = day_sums(X[first], days[first])
  n1 = N.sum(axis=0)
  t1 = t_stats(S.sum(axis=0), n1, Q)
  t1 = np.where(n1 >= min_cell_events(int(first.sum())), t1, np.nan)
  best_t = float(np.nanmax(np.abs(t1))) if np.isfinite(t1).any() else -np.inf
  best_joint = None
  for q, jc in enumerate(joint):
    sub = dict(jc, d=np.asarray(jc["d"])[first])
    pj = joint_prepare(sub, days[first], int(first.sum()))
    if pj is None:
      continue
    t = float(joint_t(pj, np.ones((1, len(np.unique(days[first])))))[0])
    if t > best_t:
      best_t, best_joint = t, (q, pj)
  if not np.isfinite(best_t):
    return "not_yet_testable", None
  W = bootstrap_weights(days[later], rng)
  single_best = float(np.nanmax(np.abs(t1))) if np.isfinite(t1).any() else -np.inf
  if REPLICATE_EITHER and best_joint is not None and np.isfinite(single_best):
    # Either the first part's top single cell or its top joint cell may replicate.
    j_res = _replicate_joint(joint, best_joint, days, later, W)
    s_res = _replicate_single(X, t1, days, later, W)
    if "replicated" in (j_res[0], s_res[0]):
      return "replicated", (j_res[1] if j_res[0] == "replicated" else s_res[1])
    if "failed" in (j_res[0], s_res[0]):
      return "failed", None
    return "not_yet_testable", None
  if best_joint is not None:
    return _replicate_joint(joint, best_joint, days, later, W)
  return _replicate_single(X, t1, days, later, W)


def _replicate_joint(joint, best_joint, days, later, W):
  if True:
    q, pj = best_joint
    mu = pj["d0"][pj["valid"]].mean(axis=0)
    w = joint_weights(pj, mu[None, :])[0]
    d2 = np.asarray(joint[q]["d"])[later][:, pj["keep"]]
    have = np.isfinite(d2).any(1)
    if have.sum() < 3:
      return "not_yet_testable", None
    s2 = np.where(have, np.where(np.isfinite(d2), d2, 0.0) @ w, np.nan)
    lo, hi = cluster_ci(s2[:, None], days[later], W)
    ok = np.isfinite(lo[0]) and lo[0] > 0
    return ("replicated" if ok else "failed"), ("joint", q)


def _replicate_single(X, t1, days, later, W):
  cell = int(np.nanargmax(np.abs(t1)))
  X2 = X[later][:, cell:cell + 1]
  if np.isfinite(X2).sum() < 3:
    return "not_yet_testable", None
  lo, hi = cluster_ci(X2, days[later], W)
  m2 = float(np.nanmean(X2))
  sign = np.sign(t1[cell])
  ok = np.isfinite(lo[0]) and np.sign(m2) == sign and ((lo[0] > 0) if sign > 0 else (hi[0] < 0))
  return ("replicated" if ok else "failed"), cell


def decide_status(n_events, n_days, p, rep):
  if n_events < 3:
    return "insufficient_events"
  if n_days < 3:
    return "individual_context"
  if p is not None and p < 0.05 and rep == "replicated":
    return "established"
  # Emerging needs p < 0.05 too: on null data p < 0.10 showed a signature for up to 17 % of event types.
  # With 3-5 event days p < 0.05 is unattainable (smallest p = 2 / 2^days), so nothing is shown before 6 days.
  if p is not None and p < 0.05:
    return "no_reliable_signature" if rep == "failed" else "emerging"
  if n_days >= 6:
    return "no_reliable_signature"
  # 3-5 event days and not significant: significance is not attainable yet (smallest p = 2 / 2^days).
  return "individual_context"


# --------------------------------------------------------------------------------------------- findings

def _window_text(a, b):
  if a >= 0:
    return f"within {b} min after onset" if a == 0 else f"{a}–{b} min after onset"
  if b == 0:
    return f"in the {-a} min before onset"
  return f"{-b}–{-a} min before onset"


def _fmt(x, d):
  v = round(float(x), d)
  return f"{v:.{d}f}" if d else f"{int(round(v))}"


def _range_text(ch, lo, hi):
  d = TEXT_DECIMALS[ch]
  lo_, hi_ = sorted((abs(lo), abs(hi))) if np.sign(lo) == np.sign(hi) else (lo, hi)
  return f"{_fmt(lo_, d)}–{_fmt(hi_, d)}"


def finding_text(ch, change, lo, hi, a, b, k, n, basis="change_from_before", usual="what is usual for the "
                 "activity and time of day"):
  """change_from_before: what physically changed; vs_usual_for_context: the deviation from the expected level."""
  d = TEXT_DECIMALS[ch]
  amount = f"{_fmt(abs(change), d)}{TEXT_UNITS[ch]} ({_range_text(ch, lo, hi)})"
  if basis == "change_from_before":
    return (f"{NAMES[ch]} {'rose' if change > 0 else 'fell'} {amount} from before onset, {_window_text(a, b)}, "
            f"in {k} of {n} events.")
  return (f"{NAMES[ch]} was {amount} {'above' if change > 0 else 'below'} {usual} {_window_text(a, b)} "
          f"in {k} of {n} events.")


def _overlap(w1, w2):
  return min(w1[1], w2[1]) > max(w1[0], w2[0])


def findings(table, center, p_cells, normalization="context", alpha=FINDING_ALPHA):
  """Top cells (max 5) of either family whose family-wise adjusted p < alpha and whose day-bootstrap CI excludes 0.
  A finding seen in both families (same channel and direction, overlapping windows) says so."""
  layout = cell_layout()
  usual = "this person's usual level" if normalization == "raw" else "what is usual for the activity and time of day"
  qualified = []
  for k in np.argsort(-np.nan_to_num(np.abs(table["t"]), nan=-1)):
    if table["n"][k] < MIN_CELL_EVENTS or not np.isfinite(table["ci_lo"][k]):
      continue
    if not (np.isfinite(p_cells[k]) and p_cells[k] < alpha):
      continue
    lo, hi = table["ci_lo"][k], table["ci_hi"][k]
    if lo <= 0 <= hi:
      continue
    family, ch, (a, b) = layout[k]
    if family == "level":
      c = center[CHANNELS.index(ch)]
      change = float(physical_change(ch, table["mean_res"][k], c))
      plo, phi = float(physical_change(ch, lo, c)), float(physical_change(ch, hi, c))
      unit = UNITS[ch]
    else:
      change, plo, phi, unit = float(table["mean_res"][k]), float(lo), float(hi), CHANGE_UNITS[ch]
    qualified.append((k, family, ch, (a, b), change, plo, phi, unit))
  # Movement around the same time: change-family steps/motion cells whose day-bootstrap CI excludes 0.
  movement = []
  for k, (family, ch, w) in enumerate(layout):
    if family == "change" and ch in MOVEMENT_CHANNELS and table["n"][k] >= MIN_CELL_EVENTS \
       and np.isfinite(table["ci_lo"][k]) and not (table["ci_lo"][k] <= 0 <= table["ci_hi"][k]):
      movement.append((w, np.sign(table["mean_res"][k])))
  out = []
  for k, family, ch, (a, b), change, plo, phi, unit in qualified[:MAX_FINDINGS]:
    basis = "change_from_before" if family == "change" else "vs_usual_for_context"
    dec = DECIMALS[ch]
    n_k = int(table["n"][k]); same = int(table["same"][k])
    text = finding_text(ch, change, plo, phi, a, b, same, n_k, basis, usual)
    # Only movement that would explain the finding counts: more movement with HR up / HRV down, less with
    # HR down / HRV up.
    explains = np.sign(change) * MOVEMENT_ACCOMPANIED.get(ch, 0)
    moved = [sgn for w, sgn in movement if _overlap(w, (a, b)) and sgn == explains] if ch in MOVEMENT_ACCOMPANIED else []
    if moved:
      text = text[:-1] + f", together with {'more' if moved[0] > 0 else 'less'} movement."
    other = [q for q in qualified if q[1] != family and q[2] == ch and np.sign(q[4]) == np.sign(change)
             and _overlap(q[3], (a, b))]
    if other:
      text += (f" It was also {'above' if change > 0 else 'below'} {usual}." if family == "change"
               else f" It also {'rose' if change > 0 else 'fell'} from before onset.")
    finding = dict(channel=ch, unit=unit, window=[a, b], direction="up" if change > 0 else "down",
                   change=round(change, dec), change_ci=[round(plo, dec), round(phi, dec)],
                   change_z=round(float(table["mean_z"][k]), 2), consistency=round(same / n_k, 3),
                   events_with_data=n_k, text=text, basis=basis)
    if ch in MOVEMENT_ACCOMPANIED:
      finding["movement_accompanied"] = bool(moved)
    out.append(finding)
  return out


def joint_findings(jcells, results, days, W, n_events, normalization="context", alpha=FINDING_ALPHA):
  """At most one joint finding per family (its best window): family-wise adjusted p < alpha and a day-bootstrap
  CI of the combined score above 0. Channels are listed by their contribution w_c * mean d_c."""
  usual = "against this person's usual level" if normalization == "raw" else \
    "against what is usual for the activity and time of day"
  best = {}
  for jc, (t, p_) in zip(jcells, results):
    if t is None or p_ is None or p_ >= alpha:
      continue
    if jc["family"] not in best or t > best[jc["family"]][1]:
      best[jc["family"]] = (jc, t, p_)
  out = []
  for family in ("change", "level"):
    if family not in best or len(out) >= MAX_JOINT_FINDINGS:
      continue
    jc, t, p_ = best[family]
    pj = joint_prepare(jc, days, n_events)
    if pj is None:
      continue
    mu = pj["d0"][pj["valid"]].mean(axis=0)
    w = joint_weights(pj, mu[None, :])[0]
    score = pj["d0"] @ w
    sv = np.where(pj["valid"], score, np.nan)
    lo, hi = cluster_ci(sv[:, None], days, W)
    combined = float(np.nanmean(sv))
    if not (np.isfinite(lo[0]) and lo[0] > 0):
      continue
    contrib = w * mu
    total = float(np.abs(contrib).sum()) or 1.0
    order = np.argsort(-np.abs(contrib))
    chans = []
    for q in order:
      if abs(contrib[q]) / total < 0.1:
        continue
      c = pj["keep"][q]; ch = jc["channels"][c]
      zc = jc["zdisp"][:, c]; zc = float(np.nanmean(zc)) if np.isfinite(zc).any() else None
      ph = jc["phys"][:, c]; ph = float(np.nanmean(ph)) if np.isfinite(ph).any() else None
      if family == "level" and ph is not None:
        cen = jc["center"][:, c] if jc["center"] is not None else np.array([np.nan])
        cen = float(np.nanmedian(cen)) if np.isfinite(cen).any() else None
        ph = float(physical_change(ch, ph, cen))
      chans.append(dict(channel=ch, weight=round(float(w[q]), 3),
                        change_z=None if zc is None else round(zc, 2),
                        change=None if ph is None else round(ph, DECIMALS[ch]), unit=jc["units"][c]))
    if not chans:
      continue
    n_valid = int(pj["valid"].sum())
    k_pos = int(np.sum(sv[pj["valid"]] > 0))
    a, b = jc["window"]
    named = [f"{NAMES[c['channel']] if q == 0 else NAMES[c['channel']].lower()} "
             f"{'rose' if (c['change_z'] or 0) > 0 else 'fell'}"
             + (f" ({c['change_z']:+.1f} SD)" if c["change_z"] is not None else "") for q, c in enumerate(chans[:3])]
    joined = named[0] if len(named) == 1 else ", ".join(named[:-1]) + " and " + named[-1]
    where = "from before onset" if family == "change" else usual
    together = " together" if len(named) > 1 else ""
    text = (f"{joined}{together} {where}, {_window_text(a, b)}, in {k_pos} of {n_valid} events "
            f"(combined {combined:+.1f} SD).")
    top = chans[0]
    out.append(dict(channel=top["channel"], unit="SD", window=[a, b],
                    direction="up" if (top["change_z"] or 0) >= 0 else "down",
                    change=round(combined, 2), change_ci=[round(float(lo[0]), 2), round(float(hi[0]), 2)],
                    change_z=round(combined, 2), consistency=round(k_pos / n_valid, 3), events_with_data=n_valid,
                    text=text, basis="joint", channels=chans, combined_z=round(combined, 2),
                    combined_z_ci=[round(float(lo[0]), 2), round(float(hi[0]), 2)]))
  return out


def profile_block(prof_res, days, W, center):
  chans = {}
  for ci, ch in enumerate(CHANNELS):
    P = prof_res[:, ci, :]
    if not np.isfinite(P).any():
      continue
    cnt = np.isfinite(P).sum(axis=0)
    with np.errstate(invalid="ignore", divide="ignore"):
      mean = np.where(cnt > 0, np.nansum(P, axis=0) / np.maximum(cnt, 1), np.nan)
    lo, hi = cluster_ci(P, days, W)
    conv = lambda x: [None if not np.isfinite(v) else round(float(v), DECIMALS[ch] + 1)
                      for v in physical_change(ch, x, center[ci])]
    chans[ch] = {"unit": UNITS[ch], "mean": conv(mean), "ci_lo": conv(lo), "ci_hi": conv(hi)}
  return {"lags": [int(LAGS[0]), int(LAGS[-1])], "channels": chans}


def context_share(onset_ctx):
  n = len(onset_ctx)
  out = {g: 0.0 for g in GROUPS}
  for c in onset_ctx:
    out[group_of(c)] += 1.0 / n if n else 0
  return {g: round(v, 3) for g, v in out.items()}


# --------------------------------------------------------------------------------------------- one signature

def analyse_group(paired, events, days, onset_ctx, rng, label, sid, normalization="context"):
  E = len(events)
  nd = len(np.unique(days)) if E else 0
  base = dict(id=sid, label=label, events=E, event_days=int(nd), event_ids=[e.id for e in events])
  if E == 0:
    return dict(base, p_value=None, p_min_possible=None, replicated=False, replication="not_yet_testable",
                context_at_onset=context_share([]), findings=[], profile={"lags": [-30, 30], "channels": {}},
                status="insufficient_events", cells_tested=0)
  center = np.array([np.nanmedian(paired.center[:, ci]) if np.isfinite(paired.center[:, ci]).any() else np.nan
                     for ci in range(len(CHANNELS))])
  X_test, X_phys, X_z = union_matrices(paired)
  jcells = joint_cells(paired) if JOINT_FAMILY else []
  test = global_test(X_test, days, rng, joint=jcells)
  rep, _ = replication(X_test, days, rng, joint=jcells)
  W = bootstrap_weights(days, rng)
  table = cell_table(X_test, X_phys, X_z, days, W)
  status = decide_status(E, nd, test["p"], rep)
  show = status in ("emerging", "established") and E >= MIN_CELL_EVENTS
  return dict(base, p_value=None if test["p"] is None else round(float(test["p"]), 5),
              p_min_possible=round(float(test["p_min_possible"]), 6), replicated=rep == "replicated",
              replication=rep, context_at_onset=context_share(onset_ctx),
              findings=(joint_findings(jcells, test["joint"], days, W, E, normalization) +
                        findings(table, center, test["p_cells"], normalization)) if show else [],
              profile=profile_block(paired.prof_res, days, W, center), status=status,
              cells_tested=int(test.get("cells_tested", 0)),
              joint=[{"family": jc["family"], "window": list(jc["window"]),
                      "t": None if t is None else round(float(t), 3), "p_adjusted": p_}
                     for jc, (t, p_) in zip(jcells, test["joint"])])


def _two_means(X, iters=25):
  """Deterministic 2-means (farthest-point init) on rows of X; returns boolean assignment to cluster 1."""
  if len(X) < 2:
    return np.zeros(len(X), bool)
  c0 = X[int(np.argmax(((X - X.mean(0)) ** 2).sum(1)))]
  c1 = X[int(np.argmax(((X - c0) ** 2).sum(1)))]
  lab = np.zeros(len(X), bool)
  for _ in range(iters):
    new = ((X - c1) ** 2).sum(1) < ((X - c0) ** 2).sum(1)
    if new.all() or (~new).all():
      return new
    c0, c1 = X[~new].mean(0), X[new].mean(0)
    if (new == lab).all():
      break
    lab = new
  return lab


def _between_stat(X, days):
  """2-means on the event difference vectors, then the largest between-group Welch t over cells (SD floored as in
  t_stats). 0 when either group is too small."""
  lab = _two_means(np.where(np.isfinite(X), X, 0.0))
  if not (_ok_group(lab, days) and _ok_group(~lab, days)):
    return 0.0, lab
  best = 0.0
  for g in (lab, ~lab):
    pass
  A, B = X[lab], X[~lab]
  na, nb = np.isfinite(A).sum(0), np.isfinite(B).sum(0)
  ok = (na >= MIN_CELL_EVENTS) & (nb >= MIN_CELL_EVENTS)
  if not ok.any():
    return 0.0, lab
  with np.errstate(invalid="ignore", divide="ignore"):
    ma, mb = np.nansum(A, 0) / na, np.nansum(B, 0) / nb
    va = np.maximum(np.nansum((A - ma) ** 2, 0) / np.maximum(na - 1, 1), T_SD_FLOOR ** 2)
    vb = np.maximum(np.nansum((B - mb) ** 2, 0) / np.maximum(nb - 1, 1), T_SD_FLOOR ** 2)
    t = np.abs(ma - mb) / np.sqrt(va / na + vb / nb)
  best = float(np.nanmax(t[ok]))
  return best, lab


def _swap_D(win_z, pick):
  """Difference vectors when window `pick[e]` of each event's (event + controls) set plays the event."""
  out = []
  for M, k in zip(win_z, pick):
    rest = np.delete(M, k, axis=0)
    cnt = np.isfinite(rest).sum(0)
    with np.errstate(invalid="ignore", divide="ignore"):
      out.append(M[k] - np.where(cnt > 0, np.nansum(rest, 0) / np.maximum(cnt, 1), np.nan))
  return np.array(out).reshape(len(win_z), -1)


def _cluster_split_p(paired, days, rng):
  """Randomisation p for 'two distinct signatures' found by 2-means. Under the null the logged window is
  exchangeable with its matched-control windows, so the null swaps which window plays the event (one draw per
  local day, shared by that day's events) and re-runs the whole procedure (clustering + between-group t). A
  sign-flip null cannot be used here: a mixture of opposite signatures is itself sign-symmetric."""
  X = paired.D_z.reshape(len(paired.D_z), -1)
  obs, lab = _between_stat(X, days)
  if obs <= 0 or paired.win_z is None:
    return None, lab
  uniq, inv = np.unique(days, return_inverse=True)
  sizes = np.array([len(M) for M in paired.win_z])
  hits = 1
  for _ in range(SPLIT_FLIPS):
    u = rng.random(len(uniq))[inv]
    pick = np.minimum((u * sizes).astype(np.int64), sizes - 1)
    stat, _ = _between_stat(_swap_D(paired.win_z, pick), days)
    if stat >= obs - 1e-12:
      hits += 1
  return hits / (SPLIT_FLIPS + 1), lab


def analyse(paired, events, days, onset_ctx, rng, normalization="context"):
  """All signatures for one type. Returns (signatures, status, split_info)."""
  days = np.asarray(days)
  onset_ctx = np.asarray(onset_ctx, dtype=np.int64)
  whole = analyse_group(paired, events, days, onset_ctx, rng, "all events", "s1", normalization)
  split = {"tried": False}
  if len(events) >= SPLIT_MIN_EVENTS:
    split["tried"] = True
    asleep = onset_ctx == C["asleep"]
    candidates = []
    if _ok_group(asleep, days) and _ok_group(~asleep, days):
      candidates.append(("context", asleep, ("asleep at onset", "awake at onset")))
    p_split, lab = _cluster_split_p(paired, days, rng)
    split["cluster_p"] = p_split
    if p_split is not None and p_split < 0.05:
      candidates.append(("pattern", lab, ("pattern A", "pattern B")))
    for kind, mask, labels in candidates:
      if not (_ok_group(mask, days) and _ok_group(~mask, days)):
        continue
      parts = [analyse_group(paired.subset(m), [e for e, k in zip(events, m) if k], days[m], onset_ctx[m], rng,
                             lbl, sid, normalization) for sid, m, lbl in (("s1", mask, labels[0]), ("s2", ~mask, labels[1]))]
      if all(p["p_value"] is not None and p["p_value"] < 0.05 for p in parts):
        split.update(kind=kind, kept=True)
        status = max((p["status"] for p in parts), key=STATUS_RANK.__getitem__)
        return parts, status, split
    split["kept"] = False
  return [whole], whole["status"], split


def _ok_group(mask, days):
  return mask.sum() >= SPLIT_GROUP_EVENTS and len(np.unique(days[mask])) >= SPLIT_GROUP_DAYS
