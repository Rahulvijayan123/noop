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


def make_frame(n_minutes, hr, nights=False):
  m = np.arange(n_minutes, dtype=np.int64) * 60
  data = {k: np.full(n_minutes, np.nan) for k in TARGETS}
  data["hr"] = np.asarray(hr, dtype=float)
  asleep = (((m // 60) % 1440) < 8 * 60).astype(float) if nights else np.zeros(n_minutes)
  data.update({"dyn": np.full(n_minutes, 0.01), "steps": np.zeros(n_minutes), "asleep": asleep,
               "hr_n": np.full(n_minutes, 60.0), "rr_cov": np.ones(n_minutes), "wrist_off": np.zeros(n_minutes)})
  ctx = np.where(asleep == 1, "asleep", "still").astype(object)
  return MinuteFrame(minutes=m, data=data, context=ctx, family="t", counters={})


def view(f, hi):
  k = f.minutes < hi
  return MinuteFrame(minutes=f.minutes[k], data={a: b[k] for a, b in f.data.items()}, context=f.context[k],
                     family=f.family, counters={})


def run(tmp, hr, ticks_every=1800, nights=False):
  f = make_frame(len(hr), hr, nights)
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


def test_every_window_is_scored_exactly_once(tmp_path):
  # Both buckets fill (8 h nights), so after warm-up the thin-reference backfill path is off and only the
  # watermark path schedules windows — the case where an unaligned watermark used to drop windows.
  rs = np.random.default_rng(2)
  n = 12 * 1440
  hr = 60 + rs.normal(size=n)
  for ticks_every in (1800, 600):
    stub, _, st = run(tmp_path / str(ticks_every), hr, ticks_every=ticks_every, nights=True)
    assert all(st.load_ref("stub", b).shape[0] >= 96 for b in ("rest", "sleep"))
    starts, counts = np.unique(stub.asked, return_counts=True)
    assert counts.max() == 1, counts.max()
    expected = np.arange(3600 + 1800 * 0, n * 60 - 1800 - 300 + 1, 1800)      # history 60 min, settle 5 min
    expected = expected[expected >= 3600]
    assert len(starts) >= len(expected) - 2, (len(starts), len(expected))


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


def test_steady_state_marks_recovery_after_exertion_bouts():
  ctx = np.array(["active"] * 5 + ["still"] * 40 + ["walking"] * 3 + ["still"] * 20 + ["active"] + ["still"] * 10,
                 dtype=object)
  out = steady_state(ctx)
  assert list(out[5:35]) == ["recovery"] * 30 and out[35] == "still"
  assert list(out[48:58]) == ["recovery"] * 10 and out[58] == "still"
  assert list(out[69:71]) == ["recovery"] * 2 and out[71] == "still"      # isolated gesture: 2-min settle only


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


def test_no_measured_minutes_and_too_short_spans_return_an_empty_publishable_result(tmp_path):
  svc = Service(cfg(tmp_path), scorers=[StubScorer()])
  st = UserState(str(tmp_path), UID, DID)
  f = make_frame(600, np.full(600, 60.0))
  f.data["hr_n"][:] = 0
  out = svc.score_frame(f, st, None, 600 * 60)
  assert out["candidates"] == [] and out["window_scores"] == [] and out["scored_to"] > out["scored_from"]
  g = make_frame(600, np.full(600, 60.0))
  out = svc.score_frame(g, st, 600 * 60 - 600, 600 * 60)          # watermark 10 min ago: nothing complete
  assert out["candidates"] == [] and out["scored_to"] > out["scored_from"]


def test_onset_of_a_flagged_event_never_joins_the_reference(tmp_path):
  # Slow 8 h ramp to +15 bpm on day 6: early ramp windows are unflagged but within 6 h of flagged ones.
  rs = np.random.default_rng(7)
  n = 7 * 1440
  hr = 60 + rs.normal(size=n)
  a = 5 * 1440 + 360
  hr[a:a + 480] += np.linspace(0, 15, 480)
  stub, seen, st = run(tmp_path, hr)
  assert any(a * 60 - 1800 <= int(k.split(":")[1]) <= (a + 480) * 60 for k in seen)
  ref = st.load_ref("stub", "rest")
  hr_scores = ref[:, 0]
  # No reference window carries the ramp (stub HR score ≈ (hr − 60) / 2 → ramp windows ≥ ~1.5).
  assert np.max(hr_scores) < 1.5, np.sort(hr_scores)[-5:]


def test_a_moderate_sustained_shift_is_caught_by_the_sustained_rule(tmp_path):
  # +3 bpm for 4 h: each window's HR score ≈ 1.5 (window rule needs far more), the 2 h mean is extreme.
  rs = np.random.default_rng(11)
  n = 9 * 1440
  hr = 60 + rs.normal(size=n)
  a = 8 * 1440 + 600
  hr[a:a + 240] += 3
  _, seen, _ = run(tmp_path, hr)
  hits = [v[-1][1] for k, v in seen.items() if a * 60 - 3 * 3600 <= int(k.split(":")[1]) <= (a + 240) * 60]
  assert hits and "sustained" in hits[0]["context"]["rules"], seen.keys()
