"""Detectability and forward (future-held-out) evaluation (docs/PHENOTYPE_SIGNATURES.md, section 6).

`fit_models(..., cutoff)` fits everything - baseline, profiles, scorers, certified thresholds - on data and labels
available before the cutoff only (labels and caregiver spans by their available_at). `forward` re-fits at each
event day after the 3rd event and tests on the days that follow, so no test minute or test label reaches a fit.
With an incumbent (the last promoted run's training cutoff) it also freezes the model fitted at that cutoff and
scores it on every later test period: champion vs. challenger on the same later events.
"""
from __future__ import annotations

import dataclasses
import hashlib

import numpy as np

from . import profiles as prof
from .baseline import Normalizer, fit_mask, near_intervals
from .context import Context
from .detector import (BUDGETS, EVENT_WINDOW_MIN, METHODS, PRIMARY_BUDGET, LogisticScorer, TemplateScorer,
                       certify, d_with_ci, empirical_recall, expected_recall, assess, poisson_ci, run_episode_state,
                       separation, trailing_features, training_set, window_scores, wilson)
from .evidence import Evidence, known_before
from .timeline import Timeline

MATCH_BEFORE_S = 5 * 60
MATCH_AFTER_S = 10 * 60
MIN_TRAIN_EVENTS = 3
MIN_PROMOTION_DETECTIONS = 3
CV_FOLDS = 5
CERTIFY_OOF = True
CERT_EVENT_MARGIN_S = 0             # 0 = match windows (sig-3); sig-2 used +/- 2 h around events
MIN_DETECT_SUPPORT = 3              # local days (>= 30 min each) of the minute's own context behind its baseline


def seed_for(owner, type_id, cutoff) -> int:
  key = f"{owner}|{type_id}|{'none' if cutoff is None else int(cutoff)}".encode()
  return int.from_bytes(hashlib.sha256(key).digest()[:8], "little")


def rng_for(owner, type_id, cutoff, salt=""):
  return np.random.default_rng([seed_for(owner, type_id, cutoff), int.from_bytes(hashlib.sha256(salt.encode()).digest()[:4], "little")])


def preferred_spans(ev: Evidence, cutoff=None):
  return ev.negative_spans(cutoff)


@dataclasses.dataclass
class Model:
  cutoff: float | None
  normalizer: Normalizer
  dev: object
  built: dict
  features: np.ndarray
  scores: dict
  thresholds: dict
  scorers: dict
  cert_mask: np.ndarray
  hr_template: np.ndarray | None
  info: dict


def _negative_minutes(tl, spans, exclusions, hi_index):
  """Minutes of observation periods / reviewed negatives, worn, away (>= 30 min) from logged events."""
  if not spans:
    return np.zeros(0, np.int64)
  inside = near_intervals(tl, spans, 0) & tl["wear"] & ~near_intervals(tl, exclusions, 30 * 60)
  inside[hi_index:] = False
  return np.flatnonzero(inside)


def fit_models(tl: Timeline, ctx: Context, ev: Evidence, normalization: str, cutoff, rng, *, events=None) -> Model:
  n = len(tl)
  hi = n if cutoff is None else int(np.clip(tl.index(cutoff), 0, n))
  excl = ev.exclusions(before=cutoff)
  mask = fit_mask(tl, ctx, excl, cutoff)
  norm = Normalizer(normalization).fit(tl, ctx, mask)
  dev = norm.transform(tl, ctx)
  dev_raw = dev if normalization == "raw" else Normalizer("raw").fit(tl, ctx, mask).transform(tl, ctx)
  dev_ctx = dev if normalization == "context" else Normalizer("context").fit(tl, ctx, mask).transform(tl, ctx)
  if events is None:
    events = [e for e in ev.events if cutoff is None or (e.available <= cutoff and e.end <= cutoff)]
  spans = preferred_spans(ev, cutoff)
  built = prof.build(tl, ctx, dev, events, exclusions=excl, preferred_spans=spans, rng=rng, hi_index=hi)
  F, _ = trailing_features(dev, ctx)
  neg_min = _negative_minutes(tl, spans, excl, hi)
  ts = training_set(tl, built["idx"], built["controls"], neg_min, rng)
  logistic = LogisticScorer().fit(F, ts)
  template = TemplateScorer().fit(dev, built["idx"], built["controls"])
  scores = supported({"logistic": logistic.score(F), "hr_rule_raw": dev_raw.z["hr"],
                      "hr_rule_context": dev_ctx.z["hr"], "template": template.score(dev)}, dev, dev_raw, dev_ctx)
  # Negative time for certification: worn minutes before the cutoff outside the match windows of every known
  # event (the same windows that decide whether a held-out alert is false) and outside positive reviews / pending
  # detections (+/- 2 h). Observation periods and reviewed negatives are part of it.
  cert = tl["wear"] & ~near_intervals(tl, certification_exclusions(ev, cutoff), 0)
  cert[hi:] = False
  # Thresholds are certified on out-of-fold scores (every scorer, its baseline included, refitted without the
  # held-out days): in-sample scores understate how often a fitted scorer fires on new days.
  cert_scores = (oof_scores(tl, ctx, ev, normalization, cutoff, hi, built, neg_min, logistic.C, rng)
                 if CERTIFY_OOF else scores)
  thresholds = {m: certify(tl.minutes[cert], cert_scores[m][cert], PRIMARY_BUDGET, day_of=tl.local_day[cert])
                for m in METHODS}
  hr_template = None
  if len(built["idx"]) >= 2:
    P = prof.profiles(dev.z["hr"], built["idx"])
    cnt = np.isfinite(P).sum(0)
    with np.errstate(invalid="ignore", divide="ignore"):
      hr_template = np.where(cnt > 0, np.nansum(P, 0) / np.maximum(cnt, 1), np.nan)
  spans_obs = sum(max(0.0, sp[1] - sp[0]) for sp in known_before(ev.observations, cutoff))
  info = {"normalizer": norm.describe(), "train_events": len(built["idx"]), "logistic": logistic.info,
          "template": template.info, "negative_days": round(float(cert.sum()) / 1440, 3),
          "observation_hours": round(spans_obs / 3600, 2), "labelled_negative_minutes": int(len(neg_min))}
  return Model(cutoff=cutoff, normalizer=norm, dev=dev, built=built, features=F, scores=scores,
               thresholds=thresholds, scorers={"logistic": logistic, "template": template}, cert_mask=cert,
               hr_template=hr_template, info=info)


def certification_exclusions(ev: Evidence, cutoff=None):
  """Spans excluded from certification negative time: each known event's match window [onset - u - 5 min,
  end + 10 min] (an alert later in a walk that continues after an event is a false alert at test time, so it must
  count in certification too), and positive reviews / pending detections with a 2 h margin."""
  spans = [(e.start - e.uncertainty_min * 60 - MATCH_BEFORE_S, e.end + MATCH_AFTER_S)
           for e in ev.events + ev.other_events if cutoff is None or e.available <= cutoff]
  if CERT_EVENT_MARGIN_S:
    spans = [(e.start - CERT_EVENT_MARGIN_S, e.end + CERT_EVENT_MARGIN_S)
             for e in ev.events + ev.other_events if cutoff is None or e.available <= cutoff]
  spans += [(a - 2 * 3600, b + 2 * 3600) for a, b in
            [(sp[0], sp[1]) for sp in known_before(list(ev.positive_reviews) + list(ev.unreviewed), cutoff)]]
  return spans


def supported(scores, dev, dev_raw, dev_ctx):
  """Detectors abstain on minutes whose heart-rate baseline has seen fewer than MIN_DETECT_SUPPORT local days of the
  minute's own context (a borrowed or one-or-two-day baseline): a context that is new or rare in the fitting data
  (e.g. after a classifier update) has no day-to-day variation in its scale, so its z values on new days are not
  covered by the certification on earlier days."""
  out = dict(scores)
  for m in ("logistic", "template"):
    out[m] = np.where(dev.support["hr"] >= MIN_DETECT_SUPPORT, scores[m], np.nan)
  out["hr_rule_context"] = np.where(dev_ctx.support["hr"] >= MIN_DETECT_SUPPORT, scores["hr_rule_context"], np.nan)
  out["hr_rule_raw"] = np.where(dev_raw.support["hr"] >= MIN_DETECT_SUPPORT, scores["hr_rule_raw"], np.nan)
  return out


def oof_scores(tl, ctx, ev, normalization, cutoff, hi, built, neg_min, C, rng, k=CV_FOLDS):
  """Out-of-fold scores of every method on the minutes before `hi`. Days before the cutoff are dealt into folds
  (event days first, round-robin in time); for each fold the baselines, the logistic model (C fixed to the full
  fit's) and the template are refitted without that fold's days - its events, controls, negative minutes and
  baseline minutes - and score only that fold's minutes."""
  n = len(tl)
  out = {m: np.full(n, np.nan) for m in METHODS}
  day = tl.local_day
  days = [int(d) for d in np.unique(day[:hi])]
  if len(days) < 2:
    return out
  idx, controls = built["idx"], built["controls"]
  ev_days = sorted({int(day[i]) for i in idx})
  order = ev_days + [d for d in days if d not in set(ev_days)]
  k = max(2, min(k, len(days)))
  fold = {d: q % k for q, d in enumerate(order)}
  fold_of = np.array([fold.get(int(d), -1) for d in day])
  before = np.arange(n) < hi
  excl = ev.exclusions(before=cutoff)
  base_mask = fit_mask(tl, ctx, excl, cutoff)
  for f in range(k):
    held = (fold_of == f) & before
    if not held.any():
      continue
    mask = base_mask & ~held
    norm = Normalizer(normalization).fit(tl, ctx, mask)
    dev = norm.transform(tl, ctx)
    dev_raw = dev if normalization == "raw" else Normalizer("raw").fit(tl, ctx, mask).transform(tl, ctx)
    dev_ctx = dev if normalization == "context" else Normalizer("context").fit(tl, ctx, mask).transform(tl, ctx)
    F, _ = trailing_features(dev, ctx)
    keep = [q for q, i in enumerate(idx) if not held[i]]
    tr_idx = [idx[q] for q in keep]
    tr_ctrl = [[j for j in controls[q] if not held[j]] for q in keep]
    tr_neg = neg_min[~held[neg_min]] if len(neg_min) else neg_min
    ts = training_set(tl, tr_idx, tr_ctrl, tr_neg, rng)
    lg = LogisticScorer(C=C if C is not None else 0.1).fit(F, ts)
    tp = TemplateScorer().fit(dev, tr_idx, tr_ctrl)
    fold = supported({"logistic": lg.score(F), "template": tp.score(dev), "hr_rule_raw": dev_raw.z["hr"],
                      "hr_rule_context": dev_ctx.z["hr"]}, dev, dev_raw, dev_ctx)
    for m in METHODS:
      out[m][held] = fold[m][held]
  return out


# --------------------------------------------------------------------------------------------- detectability

def day_folds(tl: Timeline, event_days, k=CV_FOLDS):
  """Every local day -> fold. Event days are dealt round-robin in time order (so every fold holds events), then
  the remaining days likewise."""
  ev_days = sorted(set(int(d) for d in event_days))
  k = max(1, min(k, len(ev_days)))
  fold = {d: n % k for n, d in enumerate(ev_days)}
  others = [int(d) for d in np.unique(tl.local_day) if int(d) not in fold]
  fold.update({d: n % k for n, d in enumerate(others)})
  return fold, k


def cv_scores(tl: Timeline, ev: Evidence, model, k=CV_FOLDS):
  """Out-of-fold logistic and template scores for every minute: each fold's scorers are fitted (logistic C chosen
  inside the fold) without that fold's days - no held-out event, control window or negative minute is trained on."""
  built = model.built
  idx, controls = built["idx"], built["controls"]
  day = tl.local_day
  fold, k = day_folds(tl, [day[i] for i in idx], k)
  fold_of = np.array([fold[int(d)] for d in day])
  neg_min = _negative_minutes(tl, preferred_spans(ev, model.cutoff), ev.exclusions(model.cutoff), len(tl))
  out = {"logistic": np.full(len(tl), np.nan), "template": np.full(len(tl), np.nan)}
  for f in range(k):
    held = fold_of == f
    keep = [q for q, i in enumerate(idx) if not held[i]]
    tr_idx = [idx[q] for q in keep]
    tr_ctrl = [[j for j in controls[q] if not held[j]] for q in keep]
    tr_neg = neg_min[~held[neg_min]] if len(neg_min) else neg_min
    ts = training_set(tl, tr_idx, tr_ctrl, tr_neg, np.random.default_rng(f))
    lg = LogisticScorer().fit(model.features, ts)
    tp = TemplateScorer().fit(model.dev, tr_idx, tr_ctrl)
    out["logistic"][held] = lg.score(model.features)[held]
    out["template"][held] = tp.score(model.dev)[held]
  return out


def detectability(tl: Timeline, ctx: Context, ev: Evidence, model: Model, rng):
  """d per scorer (event windows vs matched-control windows) and an empirical expected recall at 0.5 / 1 / 2 false
  alerts per day, both from day-fold cross-validated scores. The Gaussian relation is kept for reference only."""
  built = model.built
  idx, controls = built["idx"], built["controls"]
  E = len(idx)
  day = tl.local_day
  ev_days = np.array([day[i] for i in idx]) if E else np.zeros(0, np.int64)
  n_days = len(np.unique(ev_days))
  empty = {"0.5": None, "1": None, "2": None}
  if E < 3 or n_days < 3:
    return {"method": None, "d": None, "d_ci": [None, None], "expected_recall": dict(empty),
            "expected_recall_ci": {k: [None, None] for k in empty}, "expected_recall_gaussian": dict(empty),
            "assessment": "insufficient_data", "per_method": {}}
  cv = cv_scores(tl, ev, model)
  scores = dict(model.scores, **cv)
  out = {}
  for m in METHODS:
    s = scores[m]
    evs = window_scores(s, idx); cts = [window_scores(s, c) for c in controls]
    ct_all = np.concatenate(cts) if cts else np.zeros(0)
    ct_days = np.concatenate([np.full(len(c), ev_days[q]) for q, c in enumerate(cts)]) if cts else np.zeros(0)
    d, ci = d_with_ci(evs, ct_all, ev_days, ct_days, rng)
    out[m] = {"d": None if d is None else round(d, 3), "d_ci": ci}
  method = "logistic" if out["logistic"]["d"] is not None else "hr_rule_context"
  d = out[method]["d"]; ci = out[method]["d_ci"]
  recall, recall_ci, thresholds, neg_days = empirical_recall(tl.minutes, scores[method], model.cert_mask, idx)
  return {"method": method, "d": d, "d_ci": ci, "expected_recall": recall, "expected_recall_ci": recall_ci,
          "expected_recall_gaussian": expected_recall(d), "cv_negative_days": neg_days,
          "assessment": assess(d, ci, E, n_days, recall, recall_ci), "per_method": out}


# --------------------------------------------------------------------------------------------- forward

def _cutoffs(tl: Timeline, events):
  """Local midnights of each event day after the 3rd event's day."""
  if len(events) < MIN_TRAIN_EVENTS + 1:
    return []
  tz = tl.tz_offset_s
  days = sorted({int((e.start + tz) // 86400) for e in events})
  third = int((events[MIN_TRAIN_EVENTS - 1].start + tz) // 86400)
  return [d * 86400 - tz for d in days if d > third]


def _align(dev, i, template, u, n):
  u = int(round(min(max(u, 0), 60)))
  u = min(u, i - prof.LAG, n - 1 - prof.LAG - i)
  return i + prof.best_shift(dev.z["hr"], i, template, max(u, 0))


def _match_windows(test_events):
  return [(e.start - e.uncertainty_min * 60 - MATCH_BEFORE_S, e.end + MATCH_AFTER_S) for e in test_events]


def _test_period(tl, model, method, ci, ni, test_events):
  """Alerts of one fitted model on minutes [ci, ni) and their matching to the test events."""
  n = len(tl)
  thr = model.thresholds[method]
  times = tl.minutes[ci:ni].astype(np.float64)
  s = model.scores[method][ci:ni]
  windows = _match_windows(test_events)
  in_window = near_intervals(tl, windows, 0)[ci:ni] if windows else np.zeros(ni - ci, bool)
  alerts = [] if thr.enter is None or not len(times) else run_episode_state(times, s, thr.enter, thr.exit, thr.sigma)
  monitored = np.isfinite(s) & ~in_window if thr.enter is not None else np.zeros(ni - ci, bool)
  hit = [False] * len(test_events); latencies = []; matched = []
  for (_, det, _) in alerts:
    k = next((k for k, (lo, hi) in enumerate(windows) if lo <= det <= hi), None)
    matched.append((float(det), k))
    if k is not None and not hit[k]:
      hit[k] = True
      i = int(tl.index(test_events[k].start))
      a = _align(model.dev, i, model.hr_template, test_events[k].uncertainty_min, n) if 0 <= i < n else i
      onset = tl.minutes[a] if 0 <= a < n else test_events[k].start
      latencies.append(max(0.0, (det - onset) / 60.0))
  return dict(alerts=matched, hit=hit, latencies=latencies, monitored=monitored, in_window=in_window,
              times=times, threshold=thr)


def forward(tl: Timeline, ctx: Context, ev: Evidence, normalization: str, owner: str, *, incumbent=None):
  events = sorted(ev.events, key=lambda e: e.start)
  cuts = _cutoffs(tl, events)
  n = len(tl)
  end_ts = float(tl.minutes[-1] + 60) if n else 0.0
  if not cuts:
    return {"evaluated": False, "reason": "Forward evaluation needs events on at least one day after the 3rd event.",
            "segments": [], "methods": {}, "training_cutoff": int(end_ts), "champion": None}
  bounds = list(zip(cuts, cuts[1:] + [end_ts]))
  acc = {m: dict(events=0, detected=0, alerts=0, matched_alerts=0, false=0, monitored_min=0, test_min=0,
                 latencies=[], ev_scores=[], neg_scores=[], per_event=[]) for m in METHODS}
  segments = []
  challenger_log = []        # (method logistic) per segment: alerts, hits, monitored minute times
  for c, nxt in bounds:
    rng = rng_for(owner, ev.type_id, c, "forward")
    model = fit_models(tl, ctx, ev, normalization, c, rng)
    test_events = [e for e in events if c <= e.start < nxt]
    used = model.built["events"]
    last_minute = max([i + prof.LAG for i in model.built["idx"]] +
                      [j + prof.LAG for cs in model.built["controls"] for j in cs], default=-1)
    seg = {"cutoff": int(c), "test_end": int(nxt), "train_events": model.info["train_events"],
           "test_events": len(test_events),
           "train_last_label_available": max((e.available for e in used), default=None),
           "train_last_minute": None if last_minute < 0 else int(tl.minutes[last_minute]),
           "methods": {}}
    if model.info["train_events"] < MIN_TRAIN_EVENTS:
      seg["skipped"] = "fewer than 3 usable training events before the cutoff"
      segments.append(seg); continue
    ci, ni = int(np.clip(tl.index(c), 0, n)), int(np.clip(tl.index(nxt), 0, n))
    for m in METHODS:
      r = _test_period(tl, model, m, ci, ni, test_events)
      thr = r["threshold"]
      a = acc[m]
      a["events"] += len(test_events); a["test_min"] += ni - ci
      a["monitored_min"] += int(r["monitored"].sum())
      false = sum(1 for _, k in r["alerts"] if k is None)
      a["alerts"] += len(r["alerts"]); a["matched_alerts"] += len(r["alerts"]) - false; a["false"] += false
      a["detected"] += sum(r["hit"]); a["latencies"].extend(r["latencies"])
      a["per_event"].extend([{"id": e.id, "detected": h} for e, h in zip(test_events, r["hit"])])
      full = model.scores[m]
      for e in test_events:
        i = int(tl.index(e.start))
        if 0 <= i < n:
          a["ev_scores"].append(window_scores(full, [_align(model.dev, i, model.hr_template, e.uncertainty_min, n)])[0])
      blocks = np.arange(ci, ni - EVENT_WINDOW_MIN, EVENT_WINDOW_MIN)
      blocks = blocks[~r["in_window"][blocks - ci]] if len(blocks) else blocks
      if len(blocks):
        a["neg_scores"].extend(window_scores(full, blocks).tolist())
      seg["methods"][m] = {"certified": thr.enter is not None, "threshold_reason": thr.reason,
                           "negative_days": thr.monitored_days, "train_false_alerts": thr.false_alerts,
                           "alerts": len(r["alerts"]), "false_alerts": false, "detected": int(sum(r["hit"]))}
      if m == "logistic":
        challenger_log.append(dict(events=test_events, hit=r["hit"], alerts=r["alerts"],
                                   monitored_times=r["times"][r["monitored"]]))
    seg["labels_used"] = sorted(e.id for e in ev.events if e.available <= c and e.end <= c)
    segments.append(seg)
  methods = {m: _summarise(acc[m]) for m in METHODS}
  champion = None
  if incumbent and incumbent.get("training_cutoff") is not None:
    champion = champion_vs_challenger(tl, ctx, ev, normalization, owner, float(incumbent["training_cutoff"]),
                                      events, challenger_log)
  promoted, reason = promotion(methods, champion)
  return {"evaluated": any("skipped" not in s for s in segments), "segments": segments, "methods": methods,
          "promoted": promoted, "reason": reason, "budget_per_day": PRIMARY_BUDGET,
          "training_cutoff": int(end_ts), "champion": champion}


def champion_vs_challenger(tl, ctx, ev, normalization, owner, cutoff, events, challenger_log):
  """Freeze the model fitted at the incumbent's training cutoff, score it on everything after that cutoff, and
  compare with the refit-at-each-cutoff procedure (the challenger) on the same later events and time."""
  n = len(tl)
  later = [e for e in events if e.start >= cutoff]
  out = {"training_cutoff": int(cutoff), "events": len(later), "comparable": False}
  if not later or cutoff >= float(tl.minutes[-1] + 60) or cutoff <= float(tl.minutes[0]):
    out["reason"] = "No events after the current detector's training cutoff yet."
    return out
  frozen = fit_models(tl, ctx, ev, normalization, cutoff, rng_for(owner, ev.type_id, cutoff, "forward"))
  if frozen.info["train_events"] < MIN_TRAIN_EVENTS:
    out["reason"] = "The current detector's training data is no longer in the analysed period."
    return out
  ci = int(np.clip(tl.index(cutoff), 0, n))
  r = _test_period(tl, frozen, "logistic", ci, n, later)
  champ_false = sum(1 for _, k in r["alerts"] if k is None)
  champ_days = r["monitored"].sum() / 1440.0
  later_ids = {e.id for e in later}
  ch_det = sum(h for log in challenger_log for e, h in zip(log["events"], log["hit"]) if e.id in later_ids)
  ch_false = sum(1 for log in challenger_log for det, k in log["alerts"] if k is None and det >= cutoff)
  ch_days = sum(int((log["monitored_times"] >= cutoff).sum()) for log in challenger_log) / 1440.0
  out.update(comparable=True, champion_detected=int(sum(r["hit"])), champion_false_alerts=int(champ_false),
             champion_monitored_days=round(float(champ_days), 3), challenger_detected=int(ch_det),
             challenger_false_alerts=int(ch_false), challenger_monitored_days=round(float(ch_days), 3))
  return out


def _summarise(a):
  k, n = a["detected"], a["events"]
  days = a["monitored_min"] / 1440.0
  lo, hi = poisson_ci(a["false"])
  lat = np.array(a["latencies"])
  d = separation(np.array(a["ev_scores"], dtype=float), np.array(a["neg_scores"], dtype=float))
  return {"events": n, "detected": k, "recall": round(k / n, 3) if n else None, "recall_ci": wilson(k, n),
          "false_alerts": a["false"],
          "false_alerts_per_day": round(a["false"] / days, 3) if days > 0 else None,
          "false_alerts_ci": [round(lo / days, 3), round(hi / days, 3)] if days > 0 else [None, None],
          "alert_precision": round(a["matched_alerts"] / a["alerts"], 3) if a["alerts"] else None,
          "latency_median_min": round(float(np.median(lat)), 1) if len(lat) else None,
          "latency_p90_min": round(float(np.percentile(lat, 90)), 1) if len(lat) else None,
          "monitored_days": round(days, 3),
          "monitored_fraction": round(a["monitored_min"] / a["test_min"], 3) if a["test_min"] else 0.0,
          "d": None if d is None else round(d, 3), "per_event": a["per_event"]}


def promotion(methods, champion=None, budget=PRIMARY_BUDGET):
  """The candidate procedure (logistic, refit at each cutoff) is promoted only if it is useful on future-held-out
  events and, when a detector is already promoted, better than that frozen detector on the events after its
  training cutoff (more detections at <= budget false alerts per day, or as many with fewer false alerts). With
  alerts disabled this governs the retrospective model only."""
  cand = methods.get("logistic") or {}
  if not cand.get("events") or cand["events"] < 3:
    return False, "Fewer than 3 events were held out after a training cutoff."
  if cand.get("false_alerts_per_day") is None:
    return False, "The detector abstained: there was not enough negative time to certify its false-alert rate."
  if cand["false_alerts_per_day"] > budget:
    return False, f"More than {budget:g} false alert per monitored day on held-out days."
  for name in METHODS[1:]:
    b = methods.get(name) or {}
    if b.get("recall") is not None and b.get("false_alerts_per_day") is not None and \
       b["false_alerts_per_day"] <= budget and b["recall"] >= cand["recall"]:
      return False, f"The simpler {name} baseline found as many held-out events."
  if cand.get("detected", 0) < MIN_PROMOTION_DETECTIONS:
    return False, f"Fewer than {MIN_PROMOTION_DETECTIONS} held-out events were found."
  if champion and champion.get("comparable"):
    cd, cf = champion["challenger_detected"], champion["challenger_false_alerts"]
    id_, if_ = champion["champion_detected"], champion["champion_false_alerts"]
    days = champion["challenger_monitored_days"]
    within = days > 0 and cf / days <= budget
    if not within or not (cd > id_ or (cd == id_ and cf < if_)):
      return False, "Not better than the current detector on the events after its training cutoff."
    return True, "Better than the current detector on the events after its training cutoff."
  if champion and not champion.get("comparable") and champion.get("events", 0) == 0:
    return False, champion.get("reason", "No events after the current detector's training cutoff yet.")
  return True, "Better than every baseline on future-held-out events."
