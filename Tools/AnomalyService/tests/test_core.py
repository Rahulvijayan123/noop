"""Pure-logic tests (no database, no model weights)."""
import numpy as np

from frwhoop_anomaly import candidates as cand
from frwhoop_anomaly import rr
from frwhoop_anomaly.calibration import EmpiricalCalibrator, MultiChannel
from frwhoop_anomaly.features import MinuteFrame, TARGETS
from frwhoop_anomaly.state import UserState


def test_rr_pins_one_transport_and_drops_duplicates_fills_suspects():
  rows = [(100, 800, 0, 5, 0), (100, 800, 0, 5, 0), (101, 810, 0, 7, 0), (102, 500, 0, 5, 0),
          (103, 820, 0, 5, 1), (104, 790, 0, 5, 0), (105, 2500, 0, 5, 0)]
  ts, v, c = rr.clean_beats(rows, hr_at={60: 70.0})
  assert c["transport"] == 5 and c["duplicates"] == 1 and c["fill"] == 1 and c["suspect"] == 1 and c["range"] == 1
  assert list(v) == [800.0, 790.0]


def test_rmssd_matches_definition():
  rs = np.random.default_rng(1)
  rr_ms = 900 + rs.normal(0, 30, 600)
  ts = (np.cumsum(rr_ms) / 1000).astype(np.int64)
  minutes = np.arange(0, int(ts[-1]) - 60, 60)
  out, cov = rr.rmssd_per_minute(ts, rr_ms, minutes)
  i = len(minutes) - 1
  assert np.isfinite(out[i]) and 30 < out[i] < 55          # sd 30 → RMSSD ≈ 42
  assert 0.8 < np.nanmedian(cov) < 1.2


def test_calibrator_is_uniform_under_the_null():
  # Averaged over references: one 2 000-window reference has its own sampling error (single seeds range 3–7 %).
  rates = {0.05: [], 0.01: []}
  for seed in range(20):
    rs = np.random.default_rng(seed)
    ref = rs.normal(size=2000)
    p = EmpiricalCalibrator(ref).pvalue(rs.normal(size=10000))
    for a in rates:
      rates[a].append(np.mean(p < a))
  assert abs(np.mean(rates[0.05]) - 0.05) < 0.006             # body: exact
  assert 0.005 < np.mean(rates[0.01]) <= 0.0115               # tail: conservative (upper-bound scale), not liberal
  assert EmpiricalCalibrator(ref).pvalue(np.array([12.0]))[0] < 1e-5   # far tail still distinct


def test_multichannel_bonferroni_holds_alpha_with_thin_and_full_references():
  for n_ref in (96, 800):
    rates = []
    for seed in range(20):
      rs = np.random.default_rng(seed)
      mc = MultiChannel(rs.normal(size=(n_ref, 5)))
      combined, per = mc.pvalue(rs.normal(size=(20000, 5)))
      assert mc.ready
      rates.append([np.mean(combined < 0.05), np.mean(combined < 1e-3)])
    r = np.mean(rates, axis=0)
    assert 0.005 < r[0] <= 0.055                                 # valid (not 5 × 5 % = 23 %); conservative tail
    assert r[1] <= 1.5e-3                                        # the flag level the service uses


def test_multichannel_extreme_window_gets_an_extreme_p():
  rs = np.random.default_rng(4)
  mc = MultiChannel(rs.normal(size=(120, 5)))
  combined, _ = mc.pvalue(np.array([[8.0, 0.1, np.nan, -0.3, 0.2]]))
  assert combined[0] < 1e-4                                      # a bounded statistic could not go below 1/(n+1) ≈ 8e-3


def frame(minutes, hr=60.0, ctx="still"):
  n = len(minutes)
  data = {k: np.full(n, np.nan) for k in TARGETS}
  data["hr"][:] = hr
  data.update({"dyn": np.full(n, 0.01), "steps": np.zeros(n), "asleep": np.zeros(n), "hr_n": np.full(n, 60.0),
               "rr_cov": np.ones(n), "wrist_off": np.zeros(n)})
  return MinuteFrame(minutes=np.asarray(minutes, dtype=np.int64), data=data,
                     context=np.array([ctx] * n, dtype=object), family="whoop5", counters={})


def test_windows_gate_activity_and_quality():
  m = np.arange(0, 7200, 60)
  f = frame(m)
  f.context[30:60] = "active"
  f.data["hr_n"][60:90] = 0
  ws = cand.windows(f, 0, 7200)
  assert [w.usable for w in ws] == [True, False, False, True]
  assert ws[1].withheld == "activity" and ws[2].withheld == "low_hr_coverage"


def test_candidates_merge_consecutive_flagged_windows():
  m = np.arange(0, 3 * 1800, 60)
  f = frame(m)
  ws = cand.windows(f, 0, 3 * 1800)
  res = []
  for k, w in enumerate(ws):
    r = cand.ModelWindowResult(model="timesfm-3.0", window=w, channel_scores=np.array([4.0, 0, 0, 0, 0]),
                               signed_mean=np.array([4.0, 0, 0, 0, 0]), p=1e-5 if k < 2 else 0.4,
                               channel_p=np.array([1e-5, .5, .5, .5, .5]), flagged=k < 2)
    res.append(r)
  out = cand.form_candidates({"timesfm-3.0": res}, f, {"timesfm-3.0": "v"})
  assert len(out) == 1 and out[0]["candidate_key"] == "anomaly:0" and out[0]["channels"] == ["HR"]
  assert out[0]["direction"] == 1 and out[0]["flagged_by"] == ["timesfm-3.0"]
  assert out[0]["severity"] == "candidate"          # one model only


def test_state_merge_new_minutes_win(tmp_path):
  st = UserState(str(tmp_path), "11111111-1111-1111-1111-111111111111", "aaaaaaaa-0000-0000-0000-000000000001")
  a = frame(np.arange(0, 600, 60), hr=60)
  b = frame(np.arange(300, 900, 60), hr=70)
  merged = UserState.merge(a, b)
  assert list(merged.minutes) == list(range(0, 900, 60))
  assert merged.data["hr"][0] == 60 and merged.data["hr"][5] == 70
  st.save_frame(merged)
  back = st.load_frame()
  assert list(back.minutes) == list(merged.minutes) and back.context[0] == "still"
  ref = st.append_ref("timesfm-3.0", "rest", np.ones((3, 5)))
  assert ref.shape == (3, 5)
