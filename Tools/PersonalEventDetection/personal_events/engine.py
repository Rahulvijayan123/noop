"""The signature engine end to end: timeline -> context -> baseline -> profiles -> signature -> detectability ->
forward evaluation -> signature-report-1. Shared by the worker and the offline CLI."""
from __future__ import annotations

import time

import numpy as np

from . import report as rep
from . import signature as sig
from .context import classify
from .evaluation import detectability, fit_models, forward, rng_for
from .evidence import Evidence
from .timeline import Timeline


def run(tl: Timeline | None, ev: Evidence, *, normalization="context", generated_at=None, forward_eval=True,
        incumbent=None):
  """Returns (report, diagnostics, forward). The report is exactly signature-report-1; diagnostics carry the forward
  evaluation detail, dropped events and timings."""
  started = time.perf_counter()
  generated_at = int(time.time() if generated_at is None else generated_at)
  timings = {}
  if tl is None or not len(tl):
    detect = {"d": None, "d_ci": [None, None], "expected_recall": {"0.5": None, "1": None, "2": None},
              "assessment": "insufficient_data"}
    report = rep.build(ev=ev, tl=None, sigs=[], status="insufficient_events", detect=detect,
                       retro=rep.retrospective(None), normalization=normalization, generated_at=generated_at)
    return report, {"reason": "no timeline"}, None
  ctx = classify(tl)
  end = float(tl.minutes[-1] + 60)
  rng = rng_for(ev.owner, ev.type_id, end, "signature")
  t0 = time.perf_counter()
  model = fit_models(tl, ctx, ev, normalization, None, rng)
  timings["fit_s"] = round(time.perf_counter() - t0, 3)
  built = model.built
  days = tl.local_day[np.asarray(built["idx"], dtype=np.int64)] if built["idx"] else np.zeros(0, np.int64)
  t0 = time.perf_counter()
  sigs, status, split = sig.analyse(built["paired"], built["events"], days, built["onset_context"],
                                    rng_for(ev.owner, ev.type_id, end, "analyse"), normalization)
  width = {e.id: int(w) for e, w in zip(built["events"], built["control_window_min"])}
  for s_ in sigs:
    s_["control_time_window_min"] = [width[i] for i in s_["event_ids"]]
  timings["signature_s"] = round(time.perf_counter() - t0, 3)
  t0 = time.perf_counter()
  detect = detectability(tl, ctx, ev, model, rng_for(ev.owner, ev.type_id, end, "detectability"))
  timings["detectability_s"] = round(time.perf_counter() - t0, 3)
  fwd = None
  if forward_eval:
    t0 = time.perf_counter()
    fwd = forward(tl, ctx, ev, normalization, ev.owner, incumbent=incumbent)
    timings["forward_s"] = round(time.perf_counter() - t0, 3)
  fallback = model.normalizer.describe().get("fallback", {})
  notes = []
  if fallback.get("hr"):
    borrowed = ", ".join(f"{c} from {p}" for c, p in sorted(fallback["hr"].items()))
    notes.append(f"Some activities had too little data for their own heart-rate baseline and borrow a broader one "
                 f"({borrowed}).")
  if any(f.get("movement_accompanied") for s_ in sigs for f in s_["findings"]):
    notes.append(rep.MOVEMENT_NOTE)
  report = rep.build(ev=ev, tl=tl, sigs=sigs, status=status, detect=detect,
                     retro=rep.retrospective(fwd, training_cutoff=end), normalization=normalization,
                     generated_at=generated_at, dropped=built["dropped"], extra_notes=notes)
  timings["total_s"] = round(time.perf_counter() - started, 3)
  diagnostics = rep.clean({
    "dropped_events": [{"id": i, "reason": r} for i, r in built["dropped"]],
    "alignment_shift_min": {e.id: int(s) for e, s in zip(built["events"], built["shift"])},
    "controls_per_event": {e.id: len(c) for e, c in zip(built["events"], built["controls"])},
    "control_time_window_min": width,
    "onset_context_share": {e.id: round(float(x), 3) for e, x in zip(built["events"], built["pre_share"])},
    "baseline_fallback": fallback,
    "controls_from_labelled_negative_time": {e.id: int(p) for e, p in zip(built["events"], built["preferred"])},
    "signature_detail": [{k: s.get(k) for k in ("id", "status", "replication", "cells_tested")} for s in sigs],
    "split": split, "detectability": detect, "model": model.info,
    "thresholds": {m: vars(t) for m, t in model.thresholds.items()},
    "timings": timings, "minutes": len(tl),
  })
  return report, diagnostics, fwd


def run_report(tl, ev, **kw):
  out = run(tl, ev, **kw)
  return out[0]
