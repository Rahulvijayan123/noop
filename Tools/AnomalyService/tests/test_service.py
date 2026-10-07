"""score_frame with a stub scorer (no database, no model weights): warm-up, flagging, run continuity, backfill."""
import numpy as np

from frwhoop_anomaly import candidates as cand
from frwhoop_anomaly.config import Config
from frwhoop_anomaly.features import MinuteFrame, TARGETS, epoch_context, steady_state
from frwhoop_anomaly.service import Service
from frwhoop_anomaly.state import UserState

UID = "11111111-1111-1111-1111-111111111111"
DID = "aaaaaaaa-0000-0000-0000-000000000001"


class StubScorer:
  """z = (hr − 60) / 2 on the HR channel, standard-normal noise elsewhere; counts the windows it was asked for."""
  name = "stub"
  version = "stub-1"
  history_minutes = 60

  def __init__(self):
    self.asked = []
    self.rs = np.random.default_rng(0)

  def prepare(self, frame, state):
    pass

  def score(self, frame, windows, state=None):
    out = []
    for w in windows:
      self.asked.append(w.start)
      z = self.rs.normal(size=(len(TARGETS), 30))
      z[0] = (frame.data["hr"][w.minute_idx][:30] - 60.0) / 2.0 + self.rs.normal(size=30) * 0.5
      out.append((w, z))
    return out


def cfg(tmp):
  return Config(db_url="postgresql://unused", db_sslrootcert=None, db_sslmode="disable", service_name="t",
                source_revision="t", state_dir=str(tmp), timesfm_src=None, timesfm_weights="", units_src="",
                units_ckpt="", threads=1, poll_seconds=60, enqueue_limit=1, min_interval_minutes=10,
                lease_seconds=900, context_minutes=60, horizon_minutes=30, score_lookback_hours=6,
                max_jobs_per_cycle=1, dry_run=True)


def make_frame(n_minutes, hr):
  m = np.arange(n_minutes, dtype=np.int64) * 60
  data = {k: np.full(n_minutes, np.nan) for k in TARGETS}
  data["hr"] = np.asarray(hr, dtype=float)
  data.update({"dyn": np.full(n_minutes, 0.01), "steps": np.zeros(n_minutes), "asleep": np.zeros(n_minutes),
               "hr_n": np.full(n_minutes, 60.0), "rr_cov": np.ones(n_minutes), "wrist_off": np.zeros(n_minutes)})
  return MinuteFrame(minutes=m, data=data, context=np.array(["still"] * n_minutes, dtype=object), family="t",
                     counters={})


def view(f, hi):
  k = f.minutes < hi
  return MinuteFrame(minutes=f.minutes[k], data={a: b[k] for a, b in f.data.items()}, context=f.context[k],
                     family=f.family, counters={})


def run(tmp, hr, ticks_every=1800):
  f = make_frame(len(hr), hr)
  stub = StubScorer()
  svc = Service(cfg(tmp), scorers=[stub])
  st = UserState(str(tmp), UID, DID)
  wm, seen = None, {}
  for now in range(4 * 3600, len(hr) * 60 + 1, ticks_every):
    out = svc.score_frame(view(f, now), st, wm, now)
    to = int(np.datetime64(out["scored_to"].rstrip("Z")).astype("datetime64[s]").astype(np.int64))
    wm = max(wm or 0, to)
    for c in out["candidates"]:
      seen.setdefault(c["candidate_key"], []).append((now, c))
  return stub, seen, st


def test_no_candidates_while_calibrating_and_none_under_the_null(tmp_path):
  rs = np.random.default_rng(1)
  hr = 60 + rs.normal(size=6 * 1440) * 1.0
  stub, seen, st = run(tmp_path, hr)
  assert st.load_ref("stub", "rest").shape[0] >= 96
  assert len(seen) <= 1                      # α = 1e-3 per window over ~200 calibrated windows


def test_backfill_does_not_rescore_windows_already_considered(tmp_path):
  rs = np.random.default_rng(2)
  hr = 60 + rs.normal(size=4 * 1440)
  stub, _, _ = run(tmp_path, hr)
  starts, counts = np.unique(stub.asked, return_counts=True)
  # Each window is scored when it completes, and at most once more at the watermark edge (or once more as late
  # data settles); a thin reference must not make every job re-score 30 h.
  assert counts.max() <= 3, counts.max()


def test_sustained_shift_is_one_candidate_with_a_stable_key(tmp_path):
  rs = np.random.default_rng(3)
  n = 6 * 1440
  hr = 60 + rs.normal(size=n)
  hr[5 * 1440:5 * 1440 + 240] += 12          # 4 h shift on day 6
  _, seen, _ = run(tmp_path, hr)
  shift_keys = [k for k, v in seen.items() if 5 * 86400 - 1800 <= int(k.split(":")[1]) < 5 * 86400 + 4 * 3600]
  assert len(shift_keys) == 1, seen.keys()
  last = seen[shift_keys[0]][-1][1]
  assert last["context"]["windows"] >= 6     # the run grew across jobs under one key


def test_steady_state_marks_recovery_after_exertion():
  ctx = np.array(["active"] * 5 + ["still"] * 40 + ["walking"] * 3 + ["still"] * 20, dtype=object)
  out = steady_state(ctx)
  assert list(out[5:35]) == ["recovery"] * 30 and out[35] == "still"
  assert list(out[48:58]) == ["recovery"] * 10 and out[58] == "still"


def test_epoch_context_uses_confident_epochs_and_cautious_merge():
  rows = [
    {"start_ts": 0, "motion_label": "stationary", "sleep_state": "awake", "exertion_context": "resting_candidate",
     "wear_state": "on_wrist", "conf": 0.9},
    {"start_ts": 30, "motion_label": "walking", "sleep_state": "awake", "exertion_context": "unknown",
     "wear_state": "on_wrist", "conf": 0.8},
    {"start_ts": 60, "motion_label": "stationary", "sleep_state": "asleep", "exertion_context": "unknown",
     "wear_state": "on_wrist", "conf": 0.9},
    {"start_ts": 120, "motion_label": "stationary", "sleep_state": "awake", "exertion_context": "resting_candidate",
     "wear_state": "on_wrist", "conf": 0.3},
  ]
  assert epoch_context(np.array([0, 60, 120, 180]), rows) == ["walking", "asleep", None, None]


def test_merge_fills_gaps_with_unmeasured_minutes():
  a = make_frame(10, np.full(10, 60.0))
  b = make_frame(5, np.full(5, 70.0))
  b.minutes = b.minutes + 20 * 60
  m = UserState.merge(a, b)
  assert list(m.minutes) == list(range(0, 25 * 60, 60))
  assert np.isnan(m.data["hr"][10:20]).all() and (m.context[10:20] == "unknown").all()


def test_run_longer_than_the_recent_memory_keeps_its_key(tmp_path):
  rs = np.random.default_rng(5)
  n = 7 * 1440
  hr = 60 + rs.normal(size=n)
  hr[5 * 1440:5 * 1440 + 16 * 60] += 12      # 16 h shift (> RECENT_SECONDS = 12 h)
  _, seen, _ = run(tmp_path, hr)
  keys = [k for k in seen if int(k.split(":")[1]) >= 5 * 86400 - 1800]
  assert keys == ["anomaly:432000"], keys
  assert seen[keys[0]][-1][1]["context"]["windows"] >= 30
