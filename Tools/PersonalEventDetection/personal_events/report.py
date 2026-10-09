"""signature-report-1 assembly and validation (docs/PHENOTYPE_SIGNATURES.md, "Report")."""
from __future__ import annotations

import math

import numpy as np

from .baseline import CHANNELS, MODES, SOURCE, SOURCES
from .detector import METHODS
from .evidence import Evidence, known_before
from .signature import STATUSES
from .timeline import Timeline

VERSION = "signature-report-1"
ENGINE_VERSION = "sig-4"
ASSESSMENTS = ("insufficient_data", "too_weak_for_alerts", "promising")
SIGNATURE_KEYS = ("id", "label", "events", "event_days", "event_ids", "p_value", "p_min_possible", "replicated",
                  "context_at_onset", "findings", "profile")
# Optional keys added in sig-2 (signature-report-1 stays compatible: nothing renamed or removed).
OPTIONAL_SIGNATURE_KEYS = ("control_time_window_min",)
OPTIONAL_FINDING_KEYS = ("basis", "movement_accompanied", "channels", "combined_z", "combined_z_ci")
OPTIONAL_EVIDENCE_KEYS = ("events_used", "events_dropped")
OPTIONAL_DETECTABILITY_KEYS = ("expected_recall_ci",)
OPTIONAL_RETRO_KEYS = ("training_cutoff", "champion")
FINDING_CHANNELS = ("hr", "hrv", "temp", "resp", "motion", "steps")
RETRO_KEYS = ("events", "recall", "recall_ci", "false_alerts_per_day", "false_alerts_ci", "latency_median_min",
              "monitored_days")


def clean(x):
  """JSON-safe: numpy scalars -> Python, NaN/inf -> None."""
  if isinstance(x, dict):
    return {str(k): clean(v) for k, v in x.items()}
  if isinstance(x, (list, tuple)):
    return [clean(v) for v in x]
  if isinstance(x, (np.bool_,)):
    return bool(x)
  if isinstance(x, (np.integer,)):
    return int(x)
  if isinstance(x, (float, np.floating)):
    v = float(x)
    return v if math.isfinite(v) else None
  return x


def data_quality(tl: Timeline, extra_notes=()):
  n = len(tl)
  worn = tl["wear"]
  nw = int(worn.sum())
  cov = {}
  for name, col in (("hr", "hr"), ("hrv", "ln_rmssd"), ("resp", "resp"), ("temp", "temp"), ("motion", "motion")):
    cov[name] = round(float(np.isfinite(tl[col][worn]).mean()), 3) if nw else 0.0
  notes = []
  if cov["resp"] < 0.05:
    notes.append("Breathing rate is not available for this strap yet.")
  if nw and cov["hrv"] < 0.5:
    notes.append("Heart rate variability is only measured while the wrist is still, so it covers part of the time.")
  if nw and cov["motion"] < 0.5:
    notes.append("Movement (accelerometer) data covers only part of the worn time; context then relies on steps "
                 "and the activity classifier.")
  if nw and cov["temp"] < 0.5:
    notes.append("Skin temperature covers only part of the worn time.")
  return {"monitored_fraction": round(nw / n, 3) if n else 0.0, "channels": cov, "notes": notes + list(extra_notes)}


MOVEMENT_NOTE = ("Some heart-rate findings happened together with a change in movement (steps or wrist motion) that "
                 "could explain them. The change may come from moving rather than from the event itself.")

LIMITATIONS = [
  "Alerts are not enabled. This report describes past events; it does not predict or detect new ones in real time.",
  "Findings are associations between logged events and this person's own sensor data, not a diagnosis.",
  "Significance is tested with events grouped by day, because events on the same day share that day's state.",
  "Onset times are as logged; each onset may be re-aligned only within the stated onset uncertainty.",
]


def build(*, ev: Evidence, tl: Timeline | None, sigs, status, detect, retro, normalization, generated_at,
          dropped=(), extra_notes=(), baselines=None):
  tz = tl.tz_offset_s if tl is not None else 0
  event_days = len({int((e.start + tz) // 86400) for e in ev.events})
  obs_h = sum(max(0.0, sp[1] - sp[0]) for sp in ev.observations) / 3600.0
  monitored = float(tl["wear"].sum()) / 1440.0 if tl is not None else 0.0
  limitations = list(LIMITATIONS)
  if event_days < 6:
    limitations.append("Fewer than 6 days with events: day-level significance is limited "
                       "(the smallest possible p-value is 2 / 2^days).")
  if not ev.observations and not ev.negatives:
    limitations.append("No observation periods or reviewed negative time yet: comparison time is unlabelled "
                       "time that may contain unlogged events.")
  signatures = [{k: s[k] for k in SIGNATURE_KEYS + OPTIONAL_SIGNATURE_KEYS if k in s} for s in sigs]
  dropped_counts = {}
  for _, reason in dropped:
    dropped_counts[reason] = dropped_counts.get(reason, 0) + 1
  report = {
    "version": VERSION, "type_id": str(ev.type_id), "generated_at": int(generated_at),
    "engine": {"version": ENGINE_VERSION, "normalization": normalization},
    "status": status,
    "evidence": {"events": len(ev.events), "event_days": event_days, "observation_hours": round(obs_h, 2),
                 "confirmed_detections": int(ev.confirmed_detections),
                 "rejected_detections": int(ev.rejected_detections), "negative_intervals": len(ev.negatives),
                 "monitored_days": round(monitored, 2),
                 "events_used": int(sum(s["events"] for s in sigs)),
                 "events_dropped": dropped_counts},
    "signatures": signatures,
    "detectability": {"d": detect["d"], "d_ci": list(detect["d_ci"]), "expected_recall": detect["expected_recall"],
                      "assessment": detect["assessment"],
                      "expected_recall_ci": detect.get("expected_recall_ci",
                                                       {"0.5": [None, None], "1": [None, None], "2": [None, None]})},
    "retrospective": retro,
    "data_quality": data_quality(tl, extra_notes) if tl is not None else
      {"monitored_fraction": 0.0, "channels": {c: 0.0 for c in ("hr", "hrv", "resp", "temp", "motion")},
       "notes": ["No sensor data for this wearable in the analysed period."]},
    "limitations": limitations,
    "alerts_enabled": False,
  }
  if baselines is not None and tl is not None:
    report["data_quality"]["baselines"] = baselines   # optional (layer1 normalisations)
  return clean(report)


def retrospective(fwd, training_cutoff=None):
  """training_cutoff: end of the data the run's own model was fitted on (read back as the incumbent's cutoff once
  this run is promoted). champion: the frozen-incumbent vs refit comparison, when there is an incumbent."""
  extra = {"training_cutoff": None if training_cutoff is None else int(training_cutoff),
           "champion": (fwd or {}).get("champion")}
  if not fwd or not fwd.get("evaluated"):
    return dict({"evaluated": False, "method": "logistic", "events": 0, "recall": None, "recall_ci": [None, None],
                 "false_alerts_per_day": None, "false_alerts_ci": [None, None], "latency_median_min": None,
                 "monitored_days": 0.0, "baselines": {m: {} for m in METHODS[1:]}, "promoted": False,
                 "reason": (fwd or {}).get("reason", "Not evaluated.")}, **extra)
  m = fwd["methods"]
  pick = lambda s: {k: s.get(k) for k in RETRO_KEYS}
  return dict({"evaluated": True, "method": "logistic"}, **pick(m["logistic"]),
              baselines={b: pick(m[b]) for b in METHODS[1:]}, promoted=bool(fwd["promoted"]), reason=fwd["reason"],
              **extra)


# --------------------------------------------------------------------------------------------- validation

NUM = (int, float)
OPT_NUM = (int, float, type(None))


def _check(cond, problems, msg):
  if not cond:
    problems.append(msg)


def _ci(x):
  return isinstance(x, list) and len(x) == 2 and all(isinstance(v, OPT_NUM) and not isinstance(v, bool) for v in x)


BASELINE_STATUSES = ("established", "provisional", "learning", "none")
BASELINE_CONTEXT_KEYS = {"context", "source", "status", "days", "center", "scale", "unit"}


def validate_baselines(b) -> list:
  """data_quality.baselines (optional): which baseline each channel's minutes were compared with."""
  p = []
  if not isinstance(b, dict) or not isinstance(b.get("channels"), dict) or b.get("mode") not in MODES:
    return ["baselines"]
  if "layer1" in b:
    l1 = b["layer1"]
    _check(isinstance(l1, dict) and isinstance(l1.get("available"), bool)
           and isinstance(l1.get("reason"), (str, type(None))), p, "baselines.layer1")
  for ch, c in b["channels"].items():
    _check(ch in CHANNELS and isinstance(c, dict) and set(c) == {"sources", "contexts"}, p, f"baselines.{ch}")
    if not isinstance(c, dict):
      continue
    shares = c.get("sources", {})
    _check(isinstance(shares, dict) and set(shares) <= set(SOURCES)
           and all(isinstance(v, NUM) and 0 <= v <= 1 for v in shares.values()), p, f"baselines.{ch}.sources")
    for item in c.get("contexts", []):
      ok = isinstance(item, dict) and BASELINE_CONTEXT_KEYS <= set(item) <= BASELINE_CONTEXT_KEYS | {"series", "borrowed_from"}
      _check(ok, p, f"baselines.{ch}.context keys")
      if not ok:
        continue
      _check(item["source"] in ("layer1", "engine_context") and item["status"] in BASELINE_STATUSES
             and isinstance(item["days"], int) and isinstance(item["center"], OPT_NUM)
             and isinstance(item["scale"], OPT_NUM) and isinstance(item["unit"], str), p, f"baselines.{ch}.context")
  return p


def validate(r) -> list:
  """Problems with a report against signature-report-1 (empty list = valid)."""
  p = []
  if not isinstance(r, dict):
    return ["report is not an object"]
  required = {"version", "type_id", "generated_at", "engine", "status", "evidence", "signatures", "detectability",
              "retrospective", "data_quality", "limitations", "alerts_enabled"}
  _check(required <= set(r), p, f"missing keys {sorted(required - set(r))}")
  if p:
    return p
  _check(r["version"] == VERSION, p, "version")
  _check(isinstance(r["type_id"], str), p, "type_id")
  _check(isinstance(r["generated_at"], int), p, "generated_at")
  _check(r["engine"] == {"version": ENGINE_VERSION, "normalization": r["engine"].get("normalization")} and
         r["engine"].get("normalization") in MODES, p, "engine")
  _check(r["status"] in STATUSES, p, "status")
  ev = r["evidence"]
  for k in ("events", "event_days", "confirmed_detections", "rejected_detections", "negative_intervals"):
    _check(isinstance(ev.get(k), int), p, f"evidence.{k}")
  for k in ("observation_hours", "monitored_days"):
    _check(isinstance(ev.get(k), NUM), p, f"evidence.{k}")
  _check(set(ev) <= {"events", "event_days", "observation_hours", "confirmed_detections", "rejected_detections",
                     "negative_intervals", "monitored_days"} | set(OPTIONAL_EVIDENCE_KEYS), p, "evidence keys")
  _check(isinstance(ev.get("events_used", 0), int) and isinstance(ev.get("events_dropped", {}), dict), p,
         "evidence optional keys")
  _check(isinstance(r["signatures"], list), p, "signatures")
  for s in r["signatures"]:
    ok_keys = set(SIGNATURE_KEYS) <= set(s) <= set(SIGNATURE_KEYS) | set(OPTIONAL_SIGNATURE_KEYS)
    _check(ok_keys, p, f"signature keys {sorted(set(s) ^ set(SIGNATURE_KEYS))}")
    if not ok_keys:
      continue
    if "control_time_window_min" in s:
      _check(isinstance(s["control_time_window_min"], list) and len(s["control_time_window_min"]) == len(s["event_ids"])
             and all(isinstance(w, int) for w in s["control_time_window_min"]), p, "control_time_window_min")
    _check(isinstance(s["id"], str) and isinstance(s["label"], str), p, "signature id/label")
    _check(isinstance(s["events"], int) and isinstance(s["event_days"], int), p, "signature counts")
    _check(all(isinstance(i, str) for i in s["event_ids"]), p, "event_ids")
    _check(isinstance(s["p_value"], OPT_NUM) and isinstance(s["p_min_possible"], OPT_NUM), p, "p values")
    _check(isinstance(s["replicated"], bool), p, "replicated")
    _check(set(s["context_at_onset"]) == {"asleep", "still", "walking", "active", "unknown"}, p, "context_at_onset")
    for f in s["findings"]:
      req = {"channel", "unit", "window", "direction", "change", "change_ci", "change_z", "consistency",
             "events_with_data", "text"}
      _check(req <= set(f) <= req | set(OPTIONAL_FINDING_KEYS), p, "finding keys")
      _check(f.get("basis", "vs_usual_for_context") in ("change_from_before", "vs_usual_for_context", "joint"), p, "basis")
      if f.get("basis") == "joint" or "channels" in f:
        chans = f.get("channels")
        _check(isinstance(chans, list) and len(chans) >= 1 and all(
          isinstance(c, dict) and set(c) == {"channel", "weight", "change_z", "change", "unit"}
          and c["channel"] in FINDING_CHANNELS and isinstance(c["weight"], NUM) for c in chans), p, "joint channels")
        _check(isinstance(f.get("combined_z"), NUM) and _ci(f.get("combined_z_ci")), p, "combined_z")
      _check(isinstance(f.get("movement_accompanied", False), bool), p, "movement_accompanied")
      _check(f.get("channel") in FINDING_CHANNELS and f.get("direction") in ("up", "down"), p, "finding channel/direction")
      _check(isinstance(f.get("window"), list) and len(f["window"]) == 2, p, "finding window")
      _check(_ci(f.get("change_ci")) and isinstance(f.get("text"), str), p, "finding ci/text")
    pr = s["profile"]
    _check(pr.get("lags") == [-30, 30] and isinstance(pr.get("channels"), dict), p, "profile")
    for ch, c in pr.get("channels", {}).items():
      _check(ch in CHANNELS and set(c) == {"unit", "mean", "ci_lo", "ci_hi"}, p, f"profile.{ch}")
      _check(all(len(c[k]) == 61 for k in ("mean", "ci_lo", "ci_hi")), p, f"profile.{ch} length")
  d = r["detectability"]
  _check({"d", "d_ci", "expected_recall", "assessment"} <= set(d) <=
         {"d", "d_ci", "expected_recall", "assessment"} | set(OPTIONAL_DETECTABILITY_KEYS), p, "detectability keys")
  if "expected_recall_ci" in d:
    _check(set(d["expected_recall_ci"]) == {"0.5", "1", "2"} and all(_ci(v) for v in d["expected_recall_ci"].values()),
           p, "expected_recall_ci")
  _check(isinstance(d.get("d"), OPT_NUM) and _ci(d.get("d_ci")), p, "detectability d")
  _check(set(d.get("expected_recall", {})) == {"0.5", "1", "2"}, p, "expected_recall keys")
  _check(d.get("assessment") in ASSESSMENTS, p, "assessment")
  rt = r["retrospective"]
  need = {"evaluated", "method", "events", "recall", "recall_ci", "false_alerts_per_day", "false_alerts_ci",
          "latency_median_min", "monitored_days", "baselines", "promoted", "reason"}
  _check(need <= set(rt) <= need | set(OPTIONAL_RETRO_KEYS), p, f"retrospective keys {sorted(set(rt) ^ need)}")
  _check(isinstance(rt.get("training_cutoff"), (int, type(None))), p, "training_cutoff")
  _check(isinstance(rt.get("champion"), (dict, type(None))), p, "champion")
  _check(isinstance(rt.get("evaluated"), bool) and isinstance(rt.get("promoted"), bool), p, "retrospective flags")
  _check(_ci(rt.get("recall_ci")) and _ci(rt.get("false_alerts_ci")), p, "retrospective cis")
  _check(set(rt.get("baselines", {})) == {"hr_rule_raw", "hr_rule_context", "template"}, p, "baselines")
  dq = r["data_quality"]
  _check(isinstance(dq.get("monitored_fraction"), NUM), p, "monitored_fraction")
  _check(set(dq.get("channels", {})) == {"hr", "hrv", "resp", "temp", "motion"}, p, "data_quality channels")
  _check(all(isinstance(n, str) for n in dq.get("notes", [None])), p, "notes")
  if "baselines" in dq:
    p.extend(validate_baselines(dq["baselines"]))
  _check(isinstance(r["limitations"], list) and all(isinstance(x, str) for x in r["limitations"]), p, "limitations")
  _check(r["alerts_enabled"] is False, p, "alerts_enabled")
  return p
