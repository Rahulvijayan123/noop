"""Offline replay of the anomaly service: the REAL scorers (TimesFM 3.0, UniTS x128) and the service's own
score_frame / calibration / candidate logic, driven tick by tick over a minute frame, without a database.

  python -I tools/replay.py --synth synth.npz --user 0 --out out_u0.json      # synthetic (labels → detection metrics)
  python -I tools/replay.py --frame owner.npz --out out_owner.json            # real minutes (no labels → rates only)

Each tick (every --step minutes) the frame is truncated to "now", the previous tick's scored_to is the watermark, and
every candidate the service would publish is recorded with the tick it first appeared at (detection delay). The
per-user state directory starts empty, so calibration warm-up and UniTS prompt-tuning happen exactly as on the VPS.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import shutil
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from frwhoop_anomaly import candidates as cand  # noqa: E402
from frwhoop_anomaly.config import Config  # noqa: E402
from frwhoop_anomaly.features import MinuteFrame, steady_state  # noqa: E402
from frwhoop_anomaly.service import Service  # noqa: E402
from frwhoop_anomaly.state import UserState  # noqa: E402

T0 = 1_788_220_800          # 2026-09-01T00:00Z, an aligned origin for synthetic minutes
SYNTH_STATE = {0: "asleep", 1: "still", 2: "walking", 3: "active", 4: "still", 5: "off"}
EVENT_NAMES = {1: "rest_tachy", 2: "fever", 3: "spo2_dips", 4: "hrv_collapse"}
USER_ID = "00000000-0000-4000-8000-00000000000{}"
DEVICE_ID = "00000000-0000-4000-8000-0000000000d{}"


def synth_frame(path: str, user: int) -> tuple[MinuteFrame, dict]:
  d = np.load(path, allow_pickle=False)
  tg = d[f"u{user}_targets"].astype(np.float64)      # hr, rmssd, temp, resp, spo2
  cv = d[f"u{user}_covs"].astype(np.float64)         # motion, sleep, posture, wear
  state = d[f"u{user}_state"].astype(int)
  n = tg.shape[1]
  minutes = T0 + 60 * np.arange(n, dtype=np.int64)
  ctx = np.array([SYNTH_STATE[s] for s in state], dtype=object)
  ctx = steady_state(ctx)
  hr_ok = np.isfinite(tg[0]) & (state != 5)
  data = {
    "hr": np.where(hr_ok, tg[0], np.nan),
    "ln_rmssd": np.where(np.isfinite(tg[1]) & (tg[1] > 0), np.log(np.maximum(tg[1], 1e-3)), np.nan),
    "temp": tg[2], "resp": tg[3], "spo2": tg[4],
    "dyn": np.where(state == 5, np.nan, cv[0] * 0.3),
    "steps": np.select([state == 2, state == 3], [100.0, 150.0], 0.0),
    "asleep": cv[1],
    "hr_n": np.where(hr_ok, 60.0, 0.0),
    "rr_cov": np.where(hr_ok, 1.0, 0.0),
    "wrist_off": (state == 5).astype(float),
  }
  labels = {"anomaly": d[f"u{user}_anomaly"].astype(int), "artifact": d[f"u{user}_artifact"].astype(int),
            "history_days": int(d["history_days"]), "minutes": minutes}
  return MinuteFrame(minutes=minutes, data=data, context=ctx, family="synthetic", counters={}), labels


def npz_frame(path: str) -> MinuteFrame:
  z = np.load(path, allow_pickle=False)
  data = {k[2:]: z[k] for k in z.files if k.startswith("d_")}
  ctx = z["context"].astype(str).astype(object)
  ctx = steady_state(np.where(ctx == "recovery", "still", ctx).astype(object))   # current steady-state rule
  return MinuteFrame(minutes=z["minutes"], data=data, context=ctx,
                     family=str(z["family"]) if "family" in z.files else None, counters={})


def truncate(f: MinuteFrame, lo: int, hi: int) -> MinuteFrame:
  m = (f.minutes >= lo) & (f.minutes < hi)
  return MinuteFrame(minutes=f.minutes[m], data={k: v[m] for k, v in f.data.items()}, context=f.context[m],
                     family=f.family, counters={})


def make_scorers(names: list[str], cfg: Config) -> list:
  out = []
  for n in names:
    if n == "timesfm":
      from frwhoop_anomaly.models.timesfm_scorer import TimesFMScorer
      out.append(TimesFMScorer(cfg))
    elif n == "units":
      from frwhoop_anomaly.models.units_scorer import UniTSScorer
      out.append(UniTSScorer(cfg, train_windows=cfg.units_train_windows, epochs=cfg.units_epochs))
    else:
      raise SystemExit(f"unknown model {n}")
  return out


def main() -> None:
  ap = argparse.ArgumentParser()
  src = ap.add_mutually_exclusive_group(required=True)
  src.add_argument("--synth")
  src.add_argument("--frame")
  ap.add_argument("--user", type=int, default=0)
  ap.add_argument("--out", required=True)
  ap.add_argument("--state", default=None, help="state dir (default: next to --out, wiped first)")
  ap.add_argument("--models", default="timesfm,units")
  ap.add_argument("--step", type=int, default=30, help="minutes between ticks")
  ap.add_argument("--threads", type=int, default=4)
  ap.add_argument("--start_hours", type=float, default=24.0, help="first tick this many hours after the frame start")
  ap.add_argument("--units_windows", type=int, default=400, help="UniTS prompt-tuning budget (VPS: 400 × 2)")
  ap.add_argument("--units_epochs", type=int, default=2)
  a = ap.parse_args()

  state_dir = a.state or str(Path(a.out).with_suffix("")) + "_state"
  shutil.rmtree(state_dir, ignore_errors=True)
  os.makedirs(state_dir)
  env = os.environ
  cfg = Config(db_url="postgresql://unused", db_sslrootcert=None, db_sslmode="disable", service_name="replay",
               source_revision="replay", state_dir=state_dir, timesfm_src=env.get("TIMESFM_SRC"),
               timesfm_weights=env["TIMESFM_WEIGHTS"], units_src=env["UNITS_SRC"], units_ckpt=env["UNITS_CKPT"],
               threads=a.threads, poll_seconds=60, enqueue_limit=1, min_interval_minutes=10, lease_seconds=900,
               context_minutes=1024, horizon_minutes=30, score_lookback_hours=6, max_jobs_per_cycle=1, dry_run=True,
               units_train_windows=a.units_windows, units_epochs=a.units_epochs)
  t_load = time.time()
  scorers = make_scorers(a.models.split(","), cfg)
  load_s = time.time() - t_load
  svc = Service(cfg, scorers=scorers)

  if a.synth:
    frame, labels = synth_frame(a.synth, a.user)
    uid, did = USER_ID.format(a.user), DEVICE_ID.format(a.user)
  else:
    frame, labels = npz_frame(a.frame), None
    uid, did = USER_ID.format(9), DEVICE_ID.format(9)
  st = UserState(state_dir, uid, did)

  first = int(frame.minutes[0])
  end = int(frame.minutes[-1]) + 60
  tick = first + int(a.start_hours * 3600)
  tick -= tick % (a.step * 60)
  wm = None
  seen: dict[str, dict] = {}          # candidate_key → latest candidate + first_seen tick
  windows: dict[tuple, dict] = {}     # (model, start) → latest window row
  ticks, tick_ms = 0, []
  t_all = time.time()
  while tick <= end:
    view = truncate(frame, max(first, tick - 7 * 86400), tick)
    if len(view.minutes) == 0:
      tick += a.step * 60
      continue
    t1 = time.time()
    out = svc.score_frame(view, st, wm, tick)
    tick_ms.append((time.time() - t1) * 1000)
    ticks += 1
    scored_to = int(np.datetime64(out["scored_to"].rstrip("Z")).astype("datetime64[s]").astype(np.int64))
    wm = max(wm or 0, scored_to)
    for c in out["candidates"]:
      prev = seen.get(c["candidate_key"])
      c["first_seen"] = prev["first_seen"] if prev else tick
      seen[c["candidate_key"]] = c
    for w in out["window_scores"]:
      ws = int(np.datetime64(w["window_start"][:19]).astype("datetime64[s]").astype(np.int64))
      windows[(w["model"], ws)] = w
    if ticks % 48 == 0:
      print(f"tick {ticks} day {(tick - first) / 86400:.1f}: {len(seen)} candidates, "
            f"{np.mean(tick_ms[-48:]):.0f} ms/tick", flush=True)
    tick += a.step * 60

  rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024)
  ts = lambda s: int(np.datetime64(s[:19]).astype("datetime64[s]").astype(np.int64))
  cands = sorted(seen.values(), key=lambda c: c["start_ts"])
  res = {
    "source": a.synth or a.frame, "user": a.user, "models": {s.name: s.version for s in scorers},
    "days": round((end - first) / 86400, 2), "ticks": ticks, "step_min": a.step,
    "load_s": round(load_s, 1), "replay_s": round(time.time() - t_all, 1),
    "tick_ms_median": round(float(np.median(tick_ms)), 1) if tick_ms else None,
    "tick_ms_p95": round(float(np.percentile(tick_ms, 95)), 1) if tick_ms else None,
    "peak_rss_mb": round(rss_mb), "counters": svc.counters,
    "units_last_train": getattr(next((s for s in scorers if s.name == "units-x128"), None), "last_train", None),
    "window_counts": {}, "candidates": [],
  }
  by_model: dict[str, dict] = {}
  for (m, s), w in windows.items():
    b = by_model.setdefault(m, {"scored": 0, "calibrating": 0, "withheld": {}, "p_lt_1e-3": 0})
    if m == "none":
      b["withheld"][w["withheld_reason"]] = b["withheld"].get(w["withheld_reason"], 0) + 1
    elif w["withheld_reason"] == "calibrating":
      b["calibrating"] += 1
    else:
      b["scored"] += 1
      b["p_lt_1e-3"] += int(w["p"] is not None and w["p"] < 1e-3)
  res["window_counts"] = by_model
  for c in cands:
    res["candidates"].append({k: c[k] for k in ("candidate_key", "start_ts", "end_ts", "channels", "flagged_by",
                                                 "model_p", "severity", "direction", "context")}
                             | {"first_seen": c["first_seen"], "delay_min": round((c["first_seen"] - ts(c["start_ts"])) / 60)})

  res["windows"] = [{"model": m, "start": st_, "p": w["p"], "withheld": w["withheld_reason"], "bucket": w["context_kind"],
                     "score": w["score"]} for (m, st_), w in sorted(windows.items(), key=lambda kv: kv[0][1])]
  if labels is not None:
    res["eval"] = evaluate(labels, cands, windows, ts, first)
  Path(a.out).write_text(json.dumps(res, indent=1, default=float))
  print(json.dumps({k: v for k, v in res.items() if k not in ("candidates", "windows")}, indent=1, default=float))


def evaluate(labels: dict, cands: list[dict], windows: dict, ts, first: int) -> dict:
  """Event-level detection, delay and false candidates on synthetic labels (test period only)."""
  an, minutes = labels["anomaly"], labels["minutes"]
  test_from = first + labels["history_days"] * 86400
  events = []
  i = 0
  while i < len(an):
    if an[i]:
      j = i
      while j < len(an) and an[j] == an[i]:
        j += 1
      events.append({"kind": EVENT_NAMES[an[i]], "start": int(minutes[i]), "end": int(minutes[j - 1]) + 60})
      i = j
    else:
      i += 1
  events = [e for e in events if e["start"] >= test_from]
  slack = 3600  # a candidate up to 1 h after the event's end still belongs to it (lagged models)
  hit_any = lambda c, e: ts(c["start_ts"]) < e["end"] + slack and ts(c["end_ts"]) > e["start"]
  per_kind: dict[str, dict] = {}
  for e in events:
    k = per_kind.setdefault(e["kind"], {"n": 0, "detected": 0, "timesfm": 0, "units": 0, "both": 0, "delays": []})
    k["n"] += 1
    hits = [c for c in cands if hit_any(c, e)]
    if hits:
      k["detected"] += 1
      models = set(m for c in hits for m in c["flagged_by"])
      k["timesfm"] += int("timesfm-3.0" in models)
      k["units"] += int("units-x128" in models)
      k["both"] += int({"timesfm-3.0", "units-x128"} <= models)
      k["delays"].append(round((min(c["first_seen"] for c in hits) - e["start"]) / 60))
    # Usable windows inside the event (an event the window gate withholds cannot be detected by design).
    k.setdefault("usable_windows_in_events", 0)
    k["usable_windows_in_events"] += sum(1 for (m, s), w in windows.items()
                                         if m != "none" and s < e["end"] and s + cand.WINDOW_S > e["start"])
  test_cands = [c for c in cands if ts(c["start_ts"]) >= test_from]
  false = [c for c in test_cands if not any(hit_any(c, e) for e in events)]
  hist_cands = [c for c in cands if ts(c["start_ts"]) < test_from]
  test_days = (int(minutes[-1]) + 60 - test_from) / 86400
  hist_days = (test_from - first) / 86400 - 1.0      # minus the first day (no model history yet)
  per_model_false = {m: sum(1 for c in false if m in c["flagged_by"]) for m in ("timesfm-3.0", "units-x128")}
  scored_test = {m: sum(1 for (mm, s), w in windows.items() if mm == m and s >= test_from
                        and w["withheld_reason"] is None) for m in ("timesfm-3.0", "units-x128")}
  return {
    "events": per_kind,
    "false_candidates_test": len(false), "false_per_day_test": round(len(false) / test_days, 3),
    "false_by_model_test": per_model_false,
    "false_strong_test": sum(1 for c in false if c["severity"] == "strong"),
    "candidates_history_period": len(hist_cands),
    "false_per_day_history": round(len(hist_cands) / max(hist_days, 1e-9), 3),
    "scored_windows_test": scored_test,
    "false_contexts": [c["context"]["bucket"] for c in false],
  }


if __name__ == "__main__":
  main()
