"""frwhoop-anomaly main loop.

Every `poll_seconds`: enqueue owners whose server scoring completed (throttled per owner in SQL), then claim and run
up to `max_jobs_per_cycle` jobs. A job: refresh the minute cache (re-read only the last 3 h), mark exercise sessions
and their recovery over the cached minutes (rule exercise-session-1), score complete 30-minute windows since the
watermark with every loaded model, calibrate each model's window scores on the user's own history, form candidates
(local day in the person's own time zone) and publish them (fenced). A heartbeat thread writes
`anomaly_service_heartbeats` every 30 s; systemd gets READY=1 and WATCHDOG=1 (Type=notify, WatchdogSec) so a hung
loop is restarted.
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
from .calibration import MIN_REFERENCE, MultiChannel, SustainedCalibrator
from .config import Config
from .db import Database
from .state import UserState

log = logging.getLogger("frwhoop_anomaly")

REREAD_SECONDS = 3 * 3600
DATA_SETTLE_SECONDS = 5 * 60
JOB_DEADLINE_SECONDS = 25 * 60
BACKFILL_SECONDS = 30 * 3600
RECENT_SECONDS = 18 * 3600          # ≥ 2 × quarantine + a window: flags on both sides of a candidate window
REF_QUARANTINE_SECONDS = 6 * 3600
BUCKETS = ("rest", "sleep")
SUSTAINED_K = 4                      # 2 h of 30-minute windows


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
    self.current_job: tuple[str, int] | None = None   # (lease token, revision) while a job runs

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
    self.current_job = (token, revision)
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
      self.current_job = None
      done.set()

  def release_current_job(self, reason: str) -> None:
    """On shutdown: hand the running job back now instead of leaving it leased for up to lease_seconds."""
    job = self.current_job
    if job is None:
      return
    db = Database(self.cfg.db_url, self.cfg.db_sslmode, self.cfg.db_sslrootcert)
    try:
      db.rpc("fail_anomaly_job_v1", job[0], job[1], reason, timeout_ms=5000)
    except Exception as e:
      log.warning("could not release job on shutdown: %s", e)
    finally:
      db.close()

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
    # recontext: minutes cached before the context-hygiene fix get the current rule (idempotent for fresh ones).
    frame = features.recontext(UserState.merge(cached, fresh))
    st.save_frame(frame)
    tz = features.timezone_history(self.db, user)
    resting = features.resting_nights(self.db, user, features.local_day(now, tz))
    wm = job.get("watermark_ts")
    return self.score_frame(frame, st, int(wm.timestamp()) if wm is not None else None, now,
                            tz_history=tz, resting=resting)

  def score_frame(self, frame, st: UserState, wm: int | None, now: int,
                  tz_history: list[tuple[float, str]] | None = None,
                  resting: list[tuple[str, float]] | None = None) -> dict:
    """Score one user's minute frame (also used by the offline replay harness, which has no database).

    First, rule exercise-session-1 over the whole cached frame (features.with_sessions): session and recovery
    minutes are never rest or sleep, for the window gate, UniTS' training windows and the calibration references.
    Per scorer, windows from its own start: normally the watermark's last window onward (bounded by the lookback);
    while that scorer's calibration reference is thin, back to the first window it has not yet considered (≤ 30 h).
    Window results of the last RECENT_SECONDS persist, so a sustained run keeps one candidate_key across jobs.
    tz_history / resting: the person's time zones (local_day) and nightly resting HR (the session rest reference);
    None = UTC and no nightly reference.
    """
    sleep_rest = (lambda t: features.sleep_rest_reference(resting, features.local_day(t, tz_history))) \
      if resting else None
    frame, sessions = features.with_sessions(frame, sleep_rest)
    self.counters["sessions"] = len(sessions)
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
      W = cand.WINDOW_S
      floor = int(frame.minutes[0]) + getattr(scorer, "history_minutes", self.cfg.context_minutes) * 60
      floor += (-floor) % W                # first window start with a full model history
      lookback = score_to - self.cfg.score_lookback_hours * 3600
      f = max(lookback - lookback % W, floor)
      if wm is not None:
        # A window [s, s+W) was scored by the previous job iff s + W ≤ wm: the first one not yet scored starts at wm
        # aligned DOWN (the window that was still incomplete at wm). Each window is scored once.
        f = max(f, wm - wm % W)
      gen = str(getattr(scorer, "generation", lambda _st: "0")(st))
      mine = seen.get(scorer.name) if isinstance(seen.get(scorer.name), dict) else {}
      if mine.get("gen") != gen:                                   # new scorer or re-trained prompt
        mine = {"gen": gen, "last": 0}
      seen[scorer.name] = mine
      if any(st.load_ref(scorer.name, b).shape[0] < MIN_REFERENCE for b in BUCKETS):
        f = min(f, max(floor, score_to - BACKFILL_SECONDS, int(mine["last"]) + cand.WINDOW_S))
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
      out = [cand.ModelWindowResult(model=scorer.name, window=w, channel_scores=cand.directional(z),
                                    signed_mean=cand.nanmean_rows(z)) for w, z in raw]
      for bucket in BUCKETS:
        mine = [r for r in out if r.window.bucket == bucket]
        if not mine:
          continue
        mc = MultiChannel(st.load_ref(scorer.name, bucket))
        if mc.ready:
          p, per = mc.pvalue(np.stack([r.channel_scores for r in mine]))
          for r, pi, cp in zip(mine, p, per):
            r.p, r.channel_p, r.flagged = float(pi), cp, bool(pi < cand.ALPHA)
            r.rule = "window" if r.flagged else None
        else:
          for r in mine:
            r.calibrating = True
      if out:
        seen[scorer.name]["last"] = max(int(seen[scorer.name]["last"]), max(r.window.start for r in out))
      results[scorer.name] = out
    self._save_json(st, "seen.json", seen)
    self.counters["windows"] += len(ws)
    combined, kept = self._load_recent(st, frame, results, score_to)
    self._sustained(st, combined, results)
    self._grow_references(st, combined, score_to)
    candidates = cand.form_candidates(combined, frame, versions, tz_history)
    self._carry_run_keys(candidates, kept)
    self._save_recent(st, results, kept, candidates, score_to)
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    return {"scored_from": iso(score_from), "scored_to": iso(score_to), "candidates": candidates,
            "window_scores": cand.window_score_rows(results, withheld)}

  @staticmethod
  def _sustained(st: UserState, combined: dict, results: dict) -> None:
    """The k-window rule for the windows scored now: mean channel score over this window and the k−1 before it
    (same model and bucket, current + persisted results, spanning ≤ k+1 windows) against SustainedCalibrator."""
    K, W = SUSTAINED_K, cand.WINDOW_S
    for model, rs in results.items():
      seq_all = sorted(combined.get(model, []), key=lambda r: r.window.start)
      for bucket in BUCKETS:
        mine = [r for r in rs if r.window.bucket == bucket and not r.calibrating]
        if not mine:
          continue
        sc = SustainedCalibrator(st.load_ref(model, bucket), st.load_ref_starts(model, bucket), K, W)
        if not sc.ready:
          continue
        seq = [r for r in seq_all if r.window.bucket == bucket]
        pos = {r.window.start: i for i, r in enumerate(seq)}
        for r in mine:
          i = pos.get(r.window.start)
          if i is None or i + 1 < K:
            continue
          span = seq[i + 1 - K:i + 1]
          if span[-1].window.start - span[0].window.start > K * W:
            continue
          T = cand.nanmean_rows(np.stack([x.channel_scores for x in span]).T)
          p, per = sc.pvalue(T[None, :])
          r.p_sustained = float(p[0])
          if p[0] < cand.ALPHA and not r.flagged:
            r.flagged, r.rule, r.evidence_from = True, "sustained", int(span[0].window.start)
            r.channel_p = per[0] if r.channel_p is None else np.minimum(r.channel_p, per[0])

  def _grow_references(self, st: UserState, combined: dict, score_to: int) -> None:
    """Quarantined reference growth (no silent drift into "normal"). A scored window joins its model's calibration
    reference only when (a) it is ≥ REF_QUARANTINE_SECONDS old, (b) it was not flagged, (c) no window of ANY
    model was flagged within REF_QUARANTINE_SECONDS of it, and (d) it is still usable under the context known now.
    By (c) the slowly-building onset of an event that is flagged later (a fever ramp) never becomes "normal"; under
    the null flags are ~1e-3 per window, so (c) removes almost nothing. By (d) a window scored while an exercise
    session was not yet recognisable (its first minutes, before the period met the rule) is re-gated against the
    session and recovery marks known 6 h later, so gym minutes never become "rest". Each window is considered once
    (refmeta "last")."""
    Q = REF_QUARANTINE_SECONDS
    flagged = np.array(sorted({r.window.start for rs in combined.values() for r in rs if r.flagged}), dtype=np.int64)
    for model, rs in combined.items():
      for bucket in BUCKETS:
        name = f"refmeta_{model}_{bucket}.json"
        last = self._load_json(st, name).get("last", 0)
        old = [r for r in rs if r.window.bucket == bucket and r.window.start > last
               and r.window.start + cand.WINDOW_S <= score_to - Q]
        def near_flag(s0: int) -> bool:
          return bool(len(flagged)) and bool(np.any(np.abs(flagged - s0) <= Q))
        new_rows = [r for r in old if not r.flagged and not near_flag(r.window.start) and r.window.usable
                    and np.isfinite(r.channel_scores).any()]
        if new_rows:
          new_rows.sort(key=lambda r: r.window.start)
          st.append_ref(model, bucket, np.stack([r.channel_scores for r in new_rows]),
                        starts=[r.window.start for r in new_rows])
        if old:
          self._save_json(st, name, {"last": max(r.window.start for r in old)})

  @staticmethod
  def _empty(now: int, lo: int | None = None, hi: int | None = None) -> dict:
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    lo = lo if lo is not None else now - 60
    hi = hi if hi is not None and hi > lo else lo + 60
    return {"scored_from": iso(lo), "scored_to": iso(hi), "candidates": [], "window_scores": []}

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
        calibrating=x["calibrating"], p_sustained=x.get("p_sus"), rule=x.get("rule"), evidence_from=x.get("ev")))
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
              "channel_p": fin(r.channel_p), "run": run_of.get(int(r.window.start)) if r.flagged else None,
              "p_sus": r.p_sustained, "rule": r.rule, "ev": r.evidence_from}
             for m, rs in results.items() for r in rs if r.window.start >= keep_from]
    self._save_json(st, "recent.json", {"rows": rows})


def load_scorers(cfg: Config) -> list:
  from .models.timesfm_scorer import TimesFMScorer
  from .models.units_scorer import UniTSScorer
  return [TimesFMScorer(cfg), UniTSScorer(cfg, train_windows=cfg.units_train_windows, epochs=cfg.units_epochs)]


def main() -> None:
  logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
  cfg = Config.from_env()
  svc = Service(cfg)

  def _stop(*_):
    svc.stop.set()
    sd_notify("STOPPING=1")
    if svc.current_job is not None:     # mid-job (e.g. UniTS prompt-tuning): release the lease and exit now
      svc.release_current_job("shutdown")
      raise SystemExit(0)
  signal.signal(signal.SIGTERM, _stop)
  signal.signal(signal.SIGINT, _stop)
  svc.run()


if __name__ == "__main__":
  main()
