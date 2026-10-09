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


def global_test(D, days, rng):
  """Max-|t| over valid (channel, window) cells with sign flips shared within a local day.
  D: (E, K). Returns dict(p, p_min_possible, t_max, cell, exact, cells_tested)."""
  S, N, Q, uniq = day_sums(D, days)
  n = N.sum(axis=0)
  valid = n >= min_cell_events(D.shape[0])
  nd = len(uniq)
  p_min = 2.0 / 2 ** nd if nd else 1.0
  if not valid.any() or nd < 1:
    return dict(p=None, p_min_possible=p_min, t_max=None, cell=None, exact=True, cells_tested=0,
                p_cells=np.full(D.shape[1], np.nan))
  t_obs = t_stats(S.sum(axis=0), n, Q)
  T_obs = np.nanmax(np.abs(t_obs[valid]))
  cell = int(np.flatnonzero(valid)[np.nanargmax(np.abs(t_obs[valid]))])
  F, exact = flip_matrix(nd, rng)
  T = np.nanmax(np.abs(t_stats(F @ S[:, valid], n[valid], Q[valid])), axis=1)
  hits = np.sum(T >= T_obs - 1e-9 * max(1.0, abs(T_obs)))
  p = hits / len(T)                                  # the identity flip is a row of F in both cases
  # Family-wise (max-t) adjusted p per cell: the share of flips whose max-|t| reaches the cell's |t|.
  p_cells = np.full(D.shape[1], np.nan)
  Ts = np.sort(T)
  absd = np.abs(t_obs[valid])
  p_cells[valid] = (len(Ts) - np.searchsorted(Ts, absd - 1e-9 * np.maximum(1.0, absd), side="left")) / len(Ts)
  return dict(p=float(max(p, p_min if exact else 1.0 / len(T))), p_min_possible=p_min, t_max=float(T_obs),
              cell=cell, exact=exact, cells_tested=int(valid.sum()), p_cells=p_cells)


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

def replication(X, days, rng):
  """X: (E, K) standardised cells of both families. Split events in time by day (first half of the event days vs
  the rest). The first part's top cell must hold its sign with a day-bootstrap CI excluding 0 on later events."""
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
  if not np.isfinite(t1).any():
    return "not_yet_testable", None
  cell = int(np.nanargmax(np.abs(t1)))
  X2 = X[later][:, cell:cell + 1]
  if np.isfinite(X2).sum() < 3:
    return "not_yet_testable", None
  W = bootstrap_weights(days[later], rng)
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
  test = global_test(X_test, days, rng)
  rep, _ = replication(X_test, days, rng)
  W = bootstrap_weights(days, rng)
  table = cell_table(X_test, X_phys, X_z, days, W)
  status = decide_status(E, nd, test["p"], rep)
  show = status in ("emerging", "established") and E >= MIN_CELL_EVENTS
  return dict(base, p_value=None if test["p"] is None else round(float(test["p"]), 5),
              p_min_possible=round(float(test["p_min_possible"]), 6), replicated=rep == "replicated",
              replication=rep, context_at_onset=context_share(onset_ctx),
              findings=findings(table, center, test["p_cells"], normalization) if show else [],
              profile=profile_block(paired.prof_res, days, W, center), status=status,
              cells_tested=int(test.get("cells_tested", 0)))


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
