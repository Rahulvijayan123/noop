"""Context hygiene (audit 2026-10-09, A-watchdog R6 / F-deploy 2-3): epochs only toward caution, exercise session /
recovery / unconfirmed active-period windows withheld (rule exercise-session-2; its fixture parity is
tests/test_exercise_session.py), other_movement epochs are no evidence, references re-gated, local day in the
person's own zone, canonical reason codes. No database, no model weights."""
import datetime as dt
import json
import os

import numpy as np
import pytest

from frwhoop_anomaly import candidates as cand
from frwhoop_anomaly import features as F
from frwhoop_anomaly import reasons
from frwhoop_anomaly.service import Service
from frwhoop_anomaly.state import UserState

from test_service import DID, UID, StubScorer, cfg, make_frame, view

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
REASON_CODES = os.path.join(REPO, "contracts", "reason-codes.json")
LA = "America/Los_Angeles"


def utc(s: str) -> int:
  return int(dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc).timestamp())


# ---- epochs only toward caution --------------------------------------------------------------------------------

def test_an_epoch_never_turns_a_minute_that_moved_into_still():
  dyn = np.array([0.08, 0.02, 0.02, np.nan, 0.02, 0.02, 0.02, 0.06])
  steps = np.array([0, 0, 5, np.nan, 0, 0, 0, 0], dtype=float)
  asleep = np.array([0, 0, 0, 0, 0, 1, 0, 1], dtype=float)
  hr_n = np.full(8, 60.0)
  hr_n[6] = 0
  base = F.base_context(dyn, steps, asleep, np.zeros(8), hr_n)
  assert list(base) == ["unknown", "still", "unknown", "unknown", "still", "asleep", "unknown", "asleep"]
  epoch = ["still", "walking", "still", "still", "asleep", "still", "still", "still"]
  out = F.merge_epoch_context(base, epoch, dyn, steps, hr_n)
  assert list(out) == [
    "unknown",      # dynAccel 0.08 g: the wrist classifier's "stationary" is refused
    "walking",      # toward caution: accepted
    "unknown",      # step-counter increments: refused
    "still",        # no motion data at all: the epoch is the only motion evidence
    "asleep",       # between the restful labels the epoch chooses
    "still",
    "unknown",      # no heart rate: the label stays
    "asleep",       # moved while the strap says asleep: not turned still
  ]
  assert list(F.merge_epoch_context(base, ["off"] * 8, dyn, steps, hr_n)) == ["off"] * 8


# ---- the owner's 10-07 shape (PDT = UTC-7) ---------------------------------------------------------------------

def owner_1007_frame():
  """Minute frame shaped like the owner's 2026-10-07 evening: stepping bouts 21:21 and 21:30, weights 21:38-21:44,
  brisk walking 21:45-22:51, a short bout 23:00-23:04, then a slow return toward rest. Context as the pre-fix
  service built it: the server classifier read every non-walking gym minute "stationary", which overrode the
  strap's own reading, and the 30-minute steady-state hold ended at 23:21."""
  t0 = utc("2026-10-07T19:00:00")                # 12:00 PDT
  t1 = utc("2026-10-08T10:00:00")                # 03:00 PDT
  m = np.arange(t0, t1, 60, dtype=np.int64)
  n = len(m)
  pdt = lambda hhmm, day=7: utc(f"2026-10-{day:02d}T00:00:00") + 7 * 3600 + \
    (int(hhmm[:2]) * 60 + int(hhmm[3:])) * 60
  i = lambda hhmm, day=7: int((pdt(hhmm, day) - t0) // 60)
  rs = np.random.default_rng(7)
  hr = 70 + rs.normal(size=n)
  dyn = np.full(n, 0.02)
  steps = np.zeros(n)
  walk = np.zeros(n)
  for a, b in (("21:21", "21:24"), ("21:30", "21:33")):
    dyn[i(a):i(b) + 1], walk[i(a):i(b) + 1], steps[i(a):i(b) + 1], hr[i(a):i(b) + 1] = 0.12, 1, 60, 96
  for k in range(i("21:38"), i("21:44") + 1):
    dyn[k], hr[k] = (0.12 if k % 2 else 0.03), 115
  dyn[i("21:45"):i("22:51") + 1], walk[i("21:45"):i("22:51") + 1] = 0.16, 1
  steps[i("21:45"):i("22:51") + 1], hr[i("21:45"):i("22:51") + 1] = 112, 130
  hr[i("22:52"):i("23:00")] = np.linspace(110, 100, i("23:00") - i("22:52"))
  dyn[i("23:00"):i("23:04") + 1], hr[i("23:00"):i("23:04") + 1] = 0.06, 100
  dyn[i("23:02")] = 0.12
  for j, k in enumerate(range(i("23:05"), n)):
    hr[k] = 74 + 30 * 0.96 ** j
  data = {k: np.full(n, np.nan) for k in F.TARGETS}
  data["hr"] = hr
  data.update({"dyn": dyn, "steps": steps, "asleep": np.zeros(n), "hr_n": np.full(n, 60.0), "rr_cov": np.ones(n),
               "wrist_off": np.zeros(n), "walk_frac": walk, "ep_strong": np.full(n, np.nan)})
  base = F.base_context(dyn, steps, data["asleep"], data["wrist_off"], data["hr_n"])
  stationary = ["still" if b in ("still", "unknown") else None for b in base]
  old = base.copy()                                   # the pre-fix merge: any confident epoch label won
  for k, c in enumerate(stationary):
    if c is not None:
      old[k] = c
  old = F.steady_state(old)
  new = F.steady_state(F.merge_epoch_context(base, stationary, dyn, steps, data["hr_n"]))
  mk = lambda ctx: F.MinuteFrame(minutes=m, data=data, context=ctx, family="whoop5", counters={})
  return mk(old), mk(new), pdt


def test_owner_1007_late_window_is_no_longer_a_rest_window():
  old, new, pdt = owner_1007_frame()
  w2330 = pdt("23:30")
  assert w2330 == utc("2026-10-08T06:30:00")
  before = {w.start: w for w in cand.windows(old, int(old.minutes[0]), int(old.minutes[-1]))}
  assert before[w2330].usable and before[w2330].bucket == "rest"          # what production scored as rest

  frame, sessions = F.with_sessions(new, sleep_rest=None)
  assert len(sessions) == 1
  s = sessions[0]
  assert (s["start"], s["end"]) == (pdt("21:21"), pdt("23:04"))         # one session: bouts ≤ 10 min apart merge
  assert s["confirmed"] and pdt("21:45") < s["confirmed_at"] < pdt("21:55")   # the 15th strong minute
  assert pdt("23:30") < s["recovery_end"] <= pdt("23:50")         # HR back within pre-session + 10 bpm
  assert s["rest_reference"] == pytest.approx(70, abs=1.5)              # still minutes of the 2 h before
  after = {w.start: w for w in cand.windows(frame, int(frame.minutes[0]), int(frame.minutes[-1]))}
  assert after[w2330].withheld == "recovery"
  assert after[pdt("23:00")].withheld == "activity"
  assert after[pdt("21:00")].withheld == "activity"                     # the bout at 21:21 opens the session
  assert after[pdt("20:30")].usable
  assert after[pdt("00:30", 8)].usable and after[pdt("01:00", 8)].usable
  for w in after.values():                                              # no session minute is ever rest
    if w.usable:
      assert w.context_mix[F.EXERCISE] == 0 and w.context_mix[F.EXERCISE_RECOVERY] == 0


def test_resting_tachycardia_without_movement_is_still_judged_as_rest():
  # A still, high heart rate never opens a session: those windows stay usable rest windows (never muted).
  n = 8 * 60
  hr = np.full(n, 64.0)
  hr[240:] = 118.0
  f = make_frame(n, hr)
  f.data["dyn"][300::7] = 0.07            # fidgets: weak evidence only
  f2, sessions = F.with_sessions(f)
  assert sessions == []
  ws = cand.windows(f2, 0, n * 60)
  assert all(w.usable and w.bucket == "rest" for w in ws if w.start >= 240 * 60)


def test_a_session_still_in_progress_counts_once_it_has_load():
  n = 6 * 60
  hr = np.full(n, 62.0)
  hr[n - 10:] = 120.0
  f = make_frame(n, hr)
  f.data["dyn"][n - 10:] = 0.12            # 10 minutes in: shorter than 12, conditions 1-3 hold
  f.data["walk_frac"] = np.zeros(n)
  f2, sessions = F.with_sessions(f)
  assert len(sessions) == 1 and sessions[0]["open"]
  # Opened live (never back to a rest comparison), but 10 strong minutes do not confirm it yet: active.
  assert not sessions[0]["confirmed"] and sessions[0]["confirmed_at"] is None
  assert (f2.context[n - 10:] == F.EXERCISE_ACTIVE).all()
  _, closed = F.with_sessions(f, live=False)
  assert closed == []
  # 16 strong minutes so far: confirmed at the 15th, an exercise session while it is still open.
  hr[n - 16:] = 120.0
  f = make_frame(n, hr)
  f.data["dyn"][n - 16:] = 0.12
  f2, sessions = F.with_sessions(f)
  assert len(sessions) == 1 and sessions[0]["open"] and sessions[0]["confirmed"]
  assert sessions[0]["confirmed_at"] == int(f.minutes[n - 2])
  assert (f2.context[n - 16:] == F.EXERCISE).all()


def test_sessions_work_on_a_frame_cached_before_the_evidence_channels():
  n = 5 * 60
  hr = np.full(n, 60.0)
  hr[120:180] = 125.0
  hr[180:240] = np.linspace(110, 61, 60)
  f = make_frame(n, hr)
  f.data["dyn"][120:180] = 0.2
  assert "walk_frac" not in f.data
  f2, sessions = F.with_sessions(f, sleep_rest=lambda t: 55.0)
  assert len(sessions) == 1 and sessions[0]["rest_reference"] == 65.0   # nightly resting HR + 10
  assert (f2.context[120:180] == F.EXERCISE).all() and f2.context[185] == F.EXERCISE_RECOVERY
  assert f2.context[260] == "still"


def unconfirmed_period_frame():
  """Two days at 70 bpm, still. Day 2, minutes P..P+24 (P = 02:00): 100 bpm with weak movement every other minute and
  4 strong minutes, so the session conditions hold but the period is not confirmed (the fixture's late-night case);
  then 15 still minutes at 98 bpm, which rule -1 called recovery."""
  n = 2 * 1440
  P = 1440 + 120
  hr = np.full(n, 70.0)
  hr[P:P + 25] = 100.0
  hr[P + 25:P + 40] = 98.0
  f = make_frame(n, hr)
  f.data["dyn"][P:P + 25:2] = 0.06
  for k in (2, 10, 16, 24):
    f.data["dyn"][P + k] = 0.12
  return f, P


def test_an_unconfirmed_period_is_withheld_as_activity_with_no_recovery(tmp_path):
  f, P = unconfirmed_period_frame()
  f2, sessions = F.with_sessions(f)
  assert len(sessions) == 1
  s = sessions[0]
  assert (s["start"], s["end"]) == (P * 60, (P + 24) * 60) and not s["open"]
  assert not s["confirmed"] and s["confirmed_at"] is None
  assert s["recovery_end"] == s["end"] + 60                                 # no recovery after it
  assert (f2.context[P:P + 25] == F.EXERCISE_ACTIVE).all()
  assert not np.isin(f2.context, (F.EXERCISE, F.EXERCISE_RECOVERY)).any()   # neither exercise nor its recovery
  assert (f2.context[P + 25:P + 40] == "still").all()                        # judged as rest again right away
  assert not np.isin(f2.context[P:P + 25], ("still", "asleep")).any()        # never rest (UniTS training, gate)

  ws = {w.start: w for w in cand.windows(f2, 0, len(f.minutes) * 60)}
  assert ws[P * 60].withheld == "activity" and ws[P * 60].context_mix[F.EXERCISE_ACTIVE] == pytest.approx(25 / 30)
  assert reasons.canonical("activity") == ("context_not_comparable/movement", "inferred")
  assert ws[(P + 30) * 60].usable and ws[(P + 30) * 60].bucket == "rest"   # rule -1: withheld as recovery

  # Through the service: the window is never scored, never joins a reference, and is published withheld with
  # the canonical movement reason; the still window after it is scored and later joins the rest reference.
  stub = StubScorer()
  svc = Service(cfg(tmp_path), scorers=[stub])
  st = UserState(str(tmp_path), UID, DID)
  out = svc.score_frame(f, st, None, len(f.minutes) * 60)
  assert P * 60 not in stub.asked and (P + 30) * 60 in stub.asked
  row = next(r for r in out["window_scores"]
             if r["window_start"] == dt.datetime.fromtimestamp(P * 60, tz=dt.timezone.utc).isoformat())
  assert (row["usable"], row["withheld_reason"], row["reason_code"]) == (False, "activity",
                                                                         "context_not_comparable/movement")
  starts = set(st.load_ref_starts("stub", "rest").astype(np.int64).tolist())
  assert P * 60 not in starts and (P + 30) * 60 in starts


def test_an_unconfirmed_period_still_open_covers_up_to_now_and_ends_the_recovery_before_it():
  # A confirmed hour-long session, then a short block (6 strong minutes) 20 minutes later: it inherits confirmation
  # (rule -2 carry-over). 40 minutes later instead, it stays unconfirmed; either way the earlier session's recovery
  # (HR never back within pre-session + 10, cap 60 min) stops where the block starts.
  rest = lambda t: 60.0                                  # nightly resting HR: rest reference 70 for every period
  for gap, confirmed in ((20, True), (40, False)):
    n = 400
    hr = np.full(n, 70.0)
    hr[60:120] = 130.0
    hr[120:120 + gap] = 105.0
    b0 = 120 + gap
    hr[b0:b0 + 16] = 120.0
    f = make_frame(n, hr)
    f.data["dyn"][60:120] = 0.12                         # 60 strong minutes: confirmed
    f.data["dyn"][b0:b0 + 16] = 0.06
    f.data["dyn"][b0:b0 + 16:3] = 0.12                   # 6 strong minutes
    f2, sessions = F.with_sessions(f, sleep_rest=rest)
    assert [x["confirmed"] for x in sessions] == [True, confirmed], gap
    assert sessions[0]["recovery_end"] == b0 * 60, gap   # clamped by the next period, confirmed or not
    assert sessions[1]["confirmed_at"] == (b0 * 60 if confirmed else None)
    assert (f2.context[b0:b0 + 16] == (F.EXERCISE if confirmed else F.EXERCISE_ACTIVE)).all()
    assert (f2.context[120:b0] == F.EXERCISE_RECOVERY).all()
  # Still open at the frame's end (newest evidence 4 minutes old): the unconfirmed block covers the minutes up to
  # now and stays active.
  k = b0 + 20
  view_ = F.MinuteFrame(minutes=f.minutes[:k], data={a: v[:k] for a, v in f.data.items()}, context=f.context[:k],
                        family=f.family, counters={})
  f3, live = F.with_sessions(view_, sleep_rest=rest)
  assert live[-1]["open"] and not live[-1]["confirmed"] and live[-1]["end"] == int(view_.minutes[-1])
  assert (f3.context[b0:] == F.EXERCISE_ACTIVE).all()


def test_other_movement_epochs_are_no_longer_movement_evidence():
  # Confident awake on-wrist epochs: other_movement is copied as context (toward caution) but is not evidence.
  m = np.arange(4, dtype=np.int64) * 60
  row = lambda t, label, ex="unknown": {"start_ts": t, "motion_label": label, "sleep_state": "awake",
                                        "exertion_context": ex, "wear_state": "on_wrist", "exercise_session": "false",
                                        "conf": 0.9}
  rows = [row(0, "other_movement"), row(30, "other_movement"), row(60, "walking"), row(120, "stationary", "active")]
  strong = F.epoch_evidence(m, rows)
  assert list(strong[:3]) == [0.0, 1.0, 1.0] and np.isnan(strong[3])
  assert F.epoch_context(m, rows)[0] == "walking"                         # still kept out of rest

  # Two strong minutes 21 minutes apart, the minutes between at 110 bpm with an other_movement epoch each (as a
  # frame cached under rule -1 carries them: ep_weak = 1). Rule -1 read that as one period; now there is none.
  n = 300
  hr = np.full(n, 70.0)
  hr[120:142] = 110.0
  f = make_frame(n, hr)
  f.data["dyn"][[120, 141]] = 0.12
  f.data["ep_strong"] = np.where(np.isin(np.arange(n), [120, 141]), np.nan, 0.0)
  f.data["ep_weak"] = np.where((np.arange(n) > 120) & (np.arange(n) < 141), 1.0, 0.0)
  strong, weak = F.exertion_evidence(f)
  assert not weak[121:141].any() and strong[[120, 141]].all()
  f2, sessions = F.with_sessions(f)
  assert sessions == [] and (f2.context == "still").all()
  # The same minutes with real weak movement (dynAccel ≥ 0.05 g) do form a period: the test is not vacuous.
  f.data["dyn"][121:141] = 0.06
  _, sessions = F.with_sessions(f)
  assert len(sessions) == 1 and not sessions[0]["confirmed"]


def test_a_window_scored_before_its_session_was_recognisable_never_joins_the_reference(tmp_path):
  # Evidence starts at S with HR at its usual level; the session only qualifies once HR rises 12 minutes in. The
  # window [S − 25 min, S + 5 min) is scored (usable, unflagged) before that, and must still stay out of the
  # reference once the session is known.
  rs = np.random.default_rng(3)
  n = 3 * 1440
  hr = 60 + rs.normal(size=n)
  S = 2 * 1440 + 600 + 25                   # 10:25 on day 3
  hr[S + 12:S + 45] = 115.0
  hr[S + 45:S + 60] = np.linspace(100, 61, 15)
  f = make_frame(n, hr)
  f.data["dyn"][S:S + 45] = 0.12
  f.context[S:S + 45] = "unknown"
  stub = StubScorer()
  svc = Service(cfg(tmp_path), scorers=[stub])
  st = UserState(str(tmp_path), UID, DID)
  wm = None
  for now in range(4 * 3600, n * 60 + 1, 600):
    out = svc.score_frame(view(f, now), st, wm, now)
    to = int(np.datetime64(out["scored_to"].rstrip("Z")).astype("datetime64[s]").astype(np.int64))
    wm = max(wm or 0, to)
  W = (S - 25) * 60
  assert W in stub.asked                                       # it WAS scored as a usable rest window
  starts = set(st.load_ref_starts("stub", "rest").astype(np.int64).tolist())
  assert W not in starts
  assert (W - 4 * 1800) in starts and (W + 10 * 1800) in starts


# ---- local day in the person's own zone ------------------------------------------------------------------------

def test_local_day_uses_the_zone_effective_at_each_instant():
  la = [(float("-inf"), LA)]
  assert F.local_day(utc("2026-10-08T06:30:00"), la) == "2026-10-07"     # 23:30 PDT, not the UTC day
  assert F.local_day(utc("2026-10-08T06:30:00"), None) == "2026-10-08"
  # DST ends 2026-11-01 02:00 PDT: 23:30 the next evening is PST (UTC-8); a fixed −7 h offset says Nov 2.
  assert F.local_day(utc("2026-11-02T07:30:00"), la) == "2026-11-01"
  assert F.local_day(utc("2026-11-01T06:30:00"), la) == "2026-10-31"
  moved = la + [(float(utc("2026-10-08T12:00:00")), "America/New_York")]
  assert F.local_day(utc("2026-10-09T04:30:00"), moved) == "2026-10-09"   # 00:30 EDT after the move
  assert F.local_day(utc("2026-10-08T04:30:00"), moved) == "2026-10-07"   # 21:30 PDT before it
  assert F.local_day(utc("2026-10-08T06:30:00"), [(float("-inf"), "Not/AZone")]) == "2026-10-08"


def test_candidate_local_day_at_2330_pdt():
  start = utc("2026-10-08T06:30:00")
  m = np.arange(start - 3600, start + 3600, 60, dtype=np.int64)
  f = make_frame(len(m), np.full(len(m), 60.0))
  f.minutes = m
  w = cand.windows(f, start, start + cand.WINDOW_S)[0]
  r = cand.ModelWindowResult(model="stub", window=w, channel_scores=np.array([6.0, 0, 0, 0, 0]),
                             signed_mean=np.array([6.0, 0, 0, 0, 0]), p=1e-6,
                             channel_p=np.array([1e-6, .5, .5, .5, .5]), flagged=True, rule="window")
  out = cand.form_candidates({"stub": [r]}, f, {"stub": "v"}, [(float("-inf"), LA)])
  assert out[0]["local_day"] == "2026-10-07" and out[0]["start_ts"].startswith("2026-10-08T06:30")
  assert cand.form_candidates({"stub": [r]}, f, {"stub": "v"})[0]["local_day"] == "2026-10-08"


# ---- canonical reason codes and quality inputs -----------------------------------------------------------------

@pytest.mark.skipif(not os.path.exists(REASON_CODES), reason="contracts/ not in this checkout")
def test_withheld_reasons_mirror_the_contract():
  c = json.load(open(REASON_CODES))
  assert c["version"] == reasons.CONTRACT_VERSION
  legacy = c["legacy"]["anomaly_withheld"]
  assert set(legacy) == set(reasons.ANOMALY_WITHHELD)
  codes = {x["code"]: x for x in c["codes"]}
  for k, v in legacy.items():
    code, sub, certainty = reasons.ANOMALY_WITHHELD[k]
    assert (code, sub, certainty) == (v["code"], v.get("subcode"), v["certainty"]), k
    assert code in codes and (sub is None or sub in codes[code].get("subcodes", []))
    assert certainty in c["certainties"]


def test_every_published_window_row_carries_its_canonical_code(tmp_path):
  _, new, pdt = owner_1007_frame()
  svc = Service(cfg(tmp_path), scorers=[StubScorer()])
  st = UserState(str(tmp_path), UID, DID)
  out = svc.score_frame(new, st, pdt("21:00"), pdt("02:00", 8), tz_history=[(float("-inf"), LA)])
  rows = out["window_scores"]
  assert {r["withheld_reason"] for r in rows} >= {"activity", "recovery", "calibrating"}
  for r in rows:
    assert (r["reason_code"], r["reason_certainty"]) == reasons.canonical(r["withheld_reason"])
  rec = next(r for r in rows if r["withheld_reason"] == "recovery")
  assert rec["reason_code"] == "context_not_comparable/recovery" and rec["reason_certainty"] == "inferred"
  assert rec["window_start"].startswith("2026-10-08T06:30")
  assert reasons.canonical("calibrating") == ("learning", "measured")
  assert reasons.canonical(None) == (None, None)


def test_link_down_and_contact_state_per_minute():
  m = np.arange(0, 600, 60, dtype=np.int64)
  down = F.link_down_share(m, [(30, False), (90, True), (300, False)])
  assert list(down[:6]) == [0.5, 0.5, 0.0, 0.0, 0.0, 1.0] and down[-1] == 1.0     # still down at the end
  c = F.contact_state(m, [(100, "unsupported"), (200, "supported_not_detected"), (400, "supported_detected")])
  # The state at or before each minute's END counts (WatchdogVerifier's contact rule).
  assert np.isnan(c[0]) and np.isnan(c[2]) and c[3] == 1 and c[5] == 1 and c[6] == 0
  assert np.isnan(F.contact_state(m, [])).all()


# ---- workout mode: logged workouts (docs/context-watchdog/WORKOUTS.md) ----------------------------------------------

def test_a_logged_still_workout_is_withheld_as_exercise_never_scored_as_rest():
  # An hour of lifting with the arm still at 92 bpm: no movement evidence and too little load for the rule, so
  # unlogged it is a rest window. Logged, every minute is exercise from the first, and its windows are withheld.
  n = 6 * 60
  hr = np.full(n, 64.0)
  hr[180:240] = 92.0
  f = make_frame(n, hr)
  f2, sessions = F.with_sessions(f)
  assert sessions == [] and (f2.context[180:240] == "still").all()
  ws = {w.start: w for w in cand.windows(f2, 0, n * 60)}
  assert ws[180 * 60].usable and ws[180 * 60].bucket == "rest"

  f.data["logged"] = F.logged_minutes(f.minutes, [{"s": 180 * 60, "e": 240 * 60}])
  assert np.isnan(f.data["logged"][179]) and f.data["logged"][180] == 1 and np.isnan(f.data["logged"][240])
  f3, _ = F.with_sessions(f)
  assert (f3.context[180:240] == F.EXERCISE).all()
  assert f3.context[245] == "still", "after the logged workout the minutes are judged as they are"
  strong, _ = F.exertion_evidence(f)
  assert strong[180:240].all() and not strong[:180].any()
  ws = {w.start: w for w in cand.windows(f3, 0, n * 60)}
  assert ws[180 * 60].withheld == "activity" and ws[210 * 60].withheld == "activity"
  assert ws[300 * 60].usable and ws[300 * 60].bucket == "rest"


def test_a_logged_workout_off_the_wrist_stays_off():
  n = 3 * 60
  f = make_frame(n, np.full(n, 70.0))
  f.data["wrist_off"][60:90] = 1
  f.context[60:90] = "off"
  f.data["logged"] = F.logged_minutes(f.minutes, [{"s": 50 * 60, "e": 100 * 60}])
  f2, _ = F.with_sessions(f)
  assert (f2.context[60:90] == "off").all() and (f2.context[50:60] == F.EXERCISE).all()
