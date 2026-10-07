"""frwhoop-anomaly main loop.

Every `poll_seconds`: enqueue owners whose server scoring completed (throttled per owner in SQL), then claim and run
up to `max_jobs_per_cycle` jobs. A job: refresh the minute cache (re-read only the last 3 h), score complete 30-minute
windows since the watermark with every loaded model, calibrate each model's window scores on the user's own history,
form candidates and publish them (fenced). A heartbeat thread writes `anomaly_service_heartbeats` every 30 s;
systemd gets READY=1 and WATCHDOG=1 (Type=notify, WatchdogSec) so a hung loop is restarted.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import signal
import socket
import threading
import time
import traceback
import uuid

import numpy as np

from . import __version__, candidates as cand, features
from .calibration import MIN_REFERENCE, MultiChannel
from .config import Config
from .db import Database
from .state import UserState

log = logging.getLogger("frwhoop_anomaly")

REREAD_SECONDS = 3 * 3600
DATA_SETTLE_SECONDS = 5 * 60
JOB_DEADLINE_SECONDS = 25 * 60
BACKFILL_SECONDS = 30 * 3600
RECENT_SECONDS = 12 * 3600


def sd_notify(msg: str) -> None:
  addr = os.environ.get("NOTIFY_SOCKET")
  if not addr:
    return
  if addr.startswith("@"):
    addr = "\0" + addr[1:]
  try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
      s.connect(addr)
      s.sendall(msg.encode())
  except OSError:
    pass


class Service:
  def __init__(self, cfg: Config, scorers: list | None = None):
    self.cfg = cfg
    self.db = Database(cfg.db_url, cfg.db_sslmode, cfg.db_sslrootcert)
    self.hb_db = Database(cfg.db_url, cfg.db_sslmode, cfg.db_sslrootcert)
    self.scorers = scorers if scorers is not None else load_scorers(cfg)
    self.stop = threading.Event()
    self.started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    self.counters = {"claimed": 0, "published": 0, "failed": 0, "candidates": 0, "windows": 0,
                     "read_ms": 0, "infer_ms": 0, "stale_publish": 0}
    self.last_error: str | None = None

  # ---- heartbeat ---------------------------------------------------------------------------------------------
  def heartbeat_loop(self) -> None:
    while not self.stop.is_set():
      try:
        self.hb_db.rpc("anomaly_service_heartbeat_v1", self.cfg.service_name, {
          "started_at": self.started_at,
          "source_revision": f"{__version__}+{self.cfg.source_revision}",
          "models": {s.name: s.version for s in self.scorers},
          "counters": self.counters,
          "last_error": self.last_error,
        })
      except Exception as e:  # never let the heartbeat kill the service
        log.warning("heartbeat failed: %s", e)
      self.stop.wait(30)

  # ---- main loop ---------------------------------------------------------------------------------------------
  def run(self) -> None:
    threading.Thread(target=self.heartbeat_loop, name="heartbeat", daemon=True).start()
    sd_notify("READY=1")
    last_prune = 0.0
    while not self.stop.is_set():
      cycle_start = time.time()
      sd_notify("WATCHDOG=1")
      try:
        n = self.db.rpc("enqueue_anomaly_jobs_v1", self.cfg.enqueue_limit,
                        f"{self.cfg.min_interval_minutes} minutes",
                        [uuid.UUID(u) for u in self.cfg.users] if self.cfg.users else None)
        log.info("enqueue: %s", n[0] if n else n)
        for _ in range(self.cfg.max_jobs_per_cycle):
          if self.stop.is_set() or not self.run_one():
            break
          sd_notify("WATCHDOG=1")
        if time.time() - last_prune > 6 * 3600:
          self.db.rpc("prune_anomaly_window_scores_v1", "30 days")
          last_prune = time.time()
      except Exception as e:
        self.last_error = f"{type(e).__name__}: {e}"[:500]
        log.error("cycle failed: %s\n%s", e, traceback.format_exc())
        self.db.close()
      self.stop.wait(max(1.0, self.cfg.poll_seconds - (time.time() - cycle_start)))

  def run_one(self) -> bool:
    rows = self.db.rpc("claim_anomaly_job_v1", self.cfg.lease_seconds)
    if not rows or not rows[0].get("lease_token"):
      return False
    job = rows[0]
    self.counters["claimed"] += 1
    token, revision = str(job["lease_token"]), int(job["input_revision"])
    t0 = time.time()
    done = threading.Event()
    threading.Thread(target=self._keepalive, args=(token, t0, done), name="lease", daemon=True).start()
    try:
      payload = self.process(job)
      payload["run_ms"] = int((time.time() - t0) * 1000)
      payload["worker"] = f"{socket.gethostname()}/{os.getpid()}"
      if self.cfg.dry_run:
        log.info("dry-run job %s: %d candidates, %d windows", job["user_id"], len(payload["candidates"]),
                 len(payload["window_scores"]))
        self.db.rpc("fail_anomaly_job_v1", token, revision, "dry_run")
        return True
      res = self.db.rpc("publish_anomaly_result_v1", token, revision, payload)
      published = res[0]["publish_anomaly_result_v1"] if res else None
      if published is None:
        self.counters["stale_publish"] += 1
      else:
        self.counters["published"] += 1
        self.counters["candidates"] += len(payload["candidates"])
      return True
    except Exception as e:
      self.counters["failed"] += 1
      self.last_error = f"{type(e).__name__}: {e}"[:500]
      log.error("job failed: %s\n%s", e, traceback.format_exc())
      try:
        self.db.rpc("fail_anomaly_job_v1", token, revision, self.last_error)
      except Exception:
        self.db.close()
      return True
    finally:
      done.set()

  def _keepalive(self, token: str, t0: float, done: threading.Event) -> None:
    """While a job runs (UniTS prompt-tuning can take minutes): renew its lease and feed the systemd watchdog, but
    only up to JOB_DEADLINE_SECONDS — a job stuck past that stops being fed and systemd restarts the service."""
    db = Database(self.cfg.db_url, self.cfg.db_sslmode, self.cfg.db_sslrootcert)
    try:
      while not done.wait(min(60, self.cfg.lease_seconds / 3)):
        if time.time() - t0 > JOB_DEADLINE_SECONDS:
          log.error("job exceeded %d s; no longer feeding the watchdog", JOB_DEADLINE_SECONDS)
          return
        sd_notify("WATCHDOG=1")
        try:
          db.rpc("renew_anomaly_job_v1", token, self.cfg.lease_seconds)
        except Exception as e:
          log.warning("lease renew failed: %s", e)
          db.close()
    finally:
      db.close()

  def process(self, job: dict) -> dict:
    user, device = str(job["user_id"]), str(job["device_id"])
    now = int(time.time())
    st = UserState(self.cfg.state_dir, user, device)
    cached = st.load_frame()
    history = max([getattr(s, "history_minutes", self.cfg.context_minutes) for s in self.scorers] or [self.cfg.context_minutes])
    need_back = history * 60 + self.cfg.score_lookback_hours * 3600
    if cached is not None and len(cached.minutes) and cached.minutes[-1] > now - need_back:
      read_from = max(int(cached.minutes[-1]) - REREAD_SECONDS, now - need_back)
    else:
      read_from = now - need_back
    t0 = time.time()
    fresh = features.load(self.db, user, device, read_from, now)
    self.counters["read_ms"] += int((time.time() - t0) * 1000)
    frame = UserState.merge(cached, fresh)
    st.save_frame(frame)
    wm = job.get("watermark_ts")
    return self.score_frame(frame, st, int(wm.timestamp()) if wm is not None else None, now)

  def score_frame(self, frame, st: UserState, wm: int | None, now: int) -> dict:
    """Score one user's minute frame (also used by the offline replay harness, which has no database).

    Per scorer, windows from its own start: normally the watermark's last window onward (bounded by the lookback);
    while that scorer's calibration reference is thin, back to the first window it has not yet considered (≤ 30 h).
    Window results of the last RECENT_SECONDS persist, so a sustained run keeps one candidate_key across jobs.
    """
    for scorer in self.scorers:            # per-user model state (UniTS prompt) before the backfill decision
      t1 = time.time()
      scorer.prepare(frame, st)
      self.counters["infer_ms"] += int((time.time() - t1) * 1000)

    measured = frame.minutes[frame.data["hr_n"] >= 30]
    if not len(measured):
      return self._empty(now)
    score_to = int(measured[-1]) + 60 - DATA_SETTLE_SECONDS
    seen = self._load_json(st, "seen.json")
    froms = {}
    for scorer in self.scorers:
      floor = int(frame.minutes[0]) + getattr(scorer, "history_minutes", self.cfg.context_minutes) * 60
      f = max(score_to - self.cfg.score_lookback_hours * 3600, floor)
      if wm is not None:
        f = max(f, wm - cand.WINDOW_S)     # re-score the last window at the watermark edge
      if any(st.load_ref(scorer.name, b).shape[0] < MIN_REFERENCE for b in ("rest", "sleep")):
        f = min(f, max(floor, score_to - BACKFILL_SECONDS, int(seen.get(scorer.name, 0)) + cand.WINDOW_S))
      froms[scorer.name] = f
    score_from = min(froms.values()) if froms else score_to
    if score_to - score_from < cand.WINDOW_S:
      return self._empty(now, score_from, score_to)
    ws = cand.windows(frame, score_from, score_to)
    withheld = [w for w in ws if not w.usable]
    results: dict[str, list[cand.ModelWindowResult]] = {}
    versions = {}
    for scorer in self.scorers:
      usable = [w for w in ws if w.usable and w.start >= froms[scorer.name]]
      t1 = time.time()
      raw = scorer.score(frame, usable, state=st)   # list of (window, z (U, 30))
      self.counters["infer_ms"] += int((time.time() - t1) * 1000)
      versions[scorer.name] = scorer.version
      out = []
      for w, z in raw:
        out.append(cand.ModelWindowResult(model=scorer.name, window=w, channel_scores=cand.directional(z),
                                          signed_mean=cand.nanmean_rows(z)))
      for bucket in ("rest", "sleep"):
        mine = [r for r in out if r.window.bucket == bucket]
        if not mine:
          continue
        ref = st.load_ref(scorer.name, bucket)
        mc = MultiChannel(ref) if ref.size else None
        if mc is not None and mc.ready:
          p, per = mc.pvalue(np.stack([r.channel_scores for r in mine]))
          for r, pi, cp in zip(mine, p, per):
            r.p, r.channel_p, r.flagged = float(pi), cp, bool(pi < cand.ALPHA)
        else:
          for r in mine:
            r.calibrating = True
        # Windows ≥ 1 h old are considered once: unflagged ones join the reference (a run still building up is not
        # absorbed into "normal"; flagged ones never are).
        meta_path = os.path.join(st.dir, f"refmeta_{scorer.name}_{bucket}.json")
        last = self._load_json(st, os.path.basename(meta_path)).get("last", 0)
        old = [r for r in mine if r.window.start > last and r.window.start + cand.WINDOW_S <= score_to - 3600]
        new_rows = [r for r in old if not r.flagged]
        if new_rows:
          st.append_ref(scorer.name, bucket, np.stack([r.channel_scores for r in new_rows]))
        if old:
          self._save_json(st, os.path.basename(meta_path), {"last": max(r.window.start for r in old)})
      considered = [w.start for w in ws if w.start >= froms[scorer.name] and w.start + cand.WINDOW_S <= score_to - 3600]
      if considered:
        seen[scorer.name] = max(int(seen.get(scorer.name, 0)), max(considered))
      results[scorer.name] = out
    self._save_json(st, "seen.json", seen)
    self.counters["windows"] += len(ws)
    combined, kept = self._load_recent(st, frame, results, score_to)
    candidates = cand.form_candidates(combined, frame, versions)
    self._carry_run_keys(candidates, kept)
    self._save_recent(st, results, kept, candidates, score_to)
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    return {"scored_from": iso(score_from), "scored_to": iso(score_to), "candidates": candidates,
            "window_scores": cand.window_score_rows(results, withheld)}

  # ---- small per-user state helpers ----------------------------------------------------------------------------
  @staticmethod
  def _load_json(st: UserState, name: str) -> dict:
    path = os.path.join(st.dir, name)
    try:
      with open(path) as fh:
        return json.load(fh)
    except (OSError, ValueError):
      return {}

  @staticmethod
  def _save_json(st: UserState, name: str, obj) -> None:
    tmp = os.path.join(st.dir, name + ".tmp")
    with open(tmp, "w") as fh:
      json.dump(obj, fh)
    os.replace(tmp, os.path.join(st.dir, name))

  def _load_recent(self, st: UserState, frame, results: dict, score_to: int) -> tuple[dict, list]:
    """Current results plus the persisted window results of the last RECENT_SECONDS that were not re-scored now, so
    a run of flagged windows that spans jobs is formed as one candidate."""
    current = {(m, r.window.start) for m, rs in results.items() for r in rs}
    keep_from = score_to - RECENT_SECONDS
    kept = [x for x in self._load_json(st, "recent.json").get("rows", [])
            if x["start"] >= keep_from and (x["model"], x["start"]) not in current]
    combined = {m: list(rs) for m, rs in results.items()}
    nan = lambda v: np.array([np.nan if e is None else e for e in v], dtype=np.float64)
    for x in kept:
      w = cand.windows(frame, x["start"], x["start"] + cand.WINDOW_S)
      if not w:
        continue
      combined.setdefault(x["model"], []).append(cand.ModelWindowResult(
        model=x["model"], window=w[0], channel_scores=nan(x["scores"]), signed_mean=nan(x["signed"]),
        p=x["p"], channel_p=None if x["channel_p"] is None else nan(x["channel_p"]), flagged=x["flagged"],
        calibrating=x["calibrating"]))
    return combined, kept

  @staticmethod
  def _carry_run_keys(candidates: list[dict], kept: list[dict]) -> None:
    """A run longer than the recent memory keeps the key (and start) it was first published with."""
    run_of = {x["start"]: x["run"] for x in kept if x.get("run") is not None}
    for c in candidates:
      first = int(c["candidate_key"].split(":")[1])
      r = run_of.get(first)
      if r is not None and r < first:
        c["candidate_key"] = f"anomaly:{r}"
        c["start_ts"] = dt.datetime.fromtimestamp(r, tz=dt.timezone.utc).isoformat()
        c["context"]["windows"] = int((dt.datetime.fromisoformat(c["end_ts"]).timestamp() - r) // cand.WINDOW_S)

  def _save_recent(self, st: UserState, results: dict, kept: list[dict], candidates: list[dict],
                   score_to: int) -> None:
    run_of: dict[int, int] = {}
    for c in candidates:
      r = int(c["candidate_key"].split(":")[1])
      end = int(dt.datetime.fromisoformat(c["end_ts"]).timestamp())
      for s0 in range(r, end, cand.WINDOW_S):
        run_of[s0] = r
    fin = lambda a: None if a is None else [None if not np.isfinite(e) else float(e) for e in a]
    keep_from = score_to - RECENT_SECONDS
    rows = [dict(x, run=run_of.get(x["start"]) if x["flagged"] else None) for x in kept]
    rows += [{"model": m, "start": int(r.window.start), "p": r.p, "flagged": r.flagged,
              "calibrating": r.calibrating, "scores": fin(r.channel_scores), "signed": fin(r.signed_mean),
              "channel_p": fin(r.channel_p), "run": run_of.get(int(r.window.start)) if r.flagged else None}
             for m, rs in results.items() for r in rs if r.window.start >= keep_from]
    self._save_json(st, "recent.json", {"rows": rows})


def load_scorers(cfg: Config) -> list:
  from .models.timesfm_scorer import TimesFMScorer
  from .models.units_scorer import UniTSScorer
  return [TimesFMScorer(cfg), UniTSScorer(cfg)]


def main() -> None:
  logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
  cfg = Config.from_env()
  svc = Service(cfg)

  def _stop(*_):
    svc.stop.set()
    sd_notify("STOPPING=1")
  signal.signal(signal.SIGTERM, _stop)
  signal.signal(signal.SIGINT, _stop)
  svc.run()


if __name__ == "__main__":
  main()
