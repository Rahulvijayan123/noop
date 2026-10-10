"""Rule exercise-session-2 (docs/context-watchdog/EXERCISE_SESSION.md): the service's port must reproduce the shared
parity fixture contracts/reference/exercise-session-2.json exactly, confirmed / confirmed_at included (the phone and
the SQL builder are pinned to the same file)."""
import json
import os

import pytest

from frwhoop_anomaly import exercise_session as es

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FIXTURE = os.path.join(REPO, "contracts", "reference", "exercise-session-2.json")


@pytest.mark.skipif(not os.path.exists(FIXTURE), reason="contracts/ not in this checkout")
def test_rule_matches_the_shared_fixture_exactly():
  d = json.load(open(FIXTURE))
  assert d["rule"] == es.RULE == "exercise-session-2"
  assert len(d["cases"]) == 13
  for c in d["cases"]:
    got = es.sessions(c["t0"], c["hr"], c["strong"], c["weak"], c["rest_reference"])
    assert got == c["sessions"], c["name"]
    # A per-period rest reference that is constant gives the same answer.
    assert es.sessions(c["t0"], c["hr"], c["strong"], c["weak"], lambda a, r=c["rest_reference"]: r) == got
  # The fixture exercises every new path: unconfirmed periods (no recovery), confirmation at the 15th strong minute,
  # inherited confirmation, and a carry-over that expired.
  by_name = {c["name"]: c for c in d["cases"]}
  s = [x for c in d["cases"] for x in c["sessions"]]
  assert sum(not x["confirmed"] for x in s) >= 4
  assert all(x["recovery_end"] == x["end"] + 60 and x["confirmed_at"] is None for x in s if not x["confirmed"])
  split = by_name["split_workout_carry_over"]["sessions"]
  assert [x["confirmed"] for x in split] == [True, True, True]
  assert [x["confirmed_at"] == x["start"] for x in split] == [False, True, True]
  assert [x["confirmed"] for x in by_name["carry_over_expires_after_30_min"]["sessions"]] == [True, False]
  assert [x["confirmed"] for x in by_name["confirm_threshold_14_then_15"]["sessions"]] == [False, True]


def test_confirmation_counts_strong_minutes_and_inherits_forward_only():
  strong = [0] * 100
  for i in range(10, 40, 2):                   # 15 strong minutes, the 15th at index 38
    strong[i] = 1
  assert es.confirmation(10, 40, strong, None) == 38
  assert es.confirmation(10, 37, strong, None) is None          # 14 so far: not yet
  assert es.confirmation(60, 70, strong, 30) == 60              # starts 30 min after a confirmed end: inherited
  assert es.confirmation(61, 70, strong, 30) is None            # 31 min: too late


def test_an_unconfirmed_period_has_no_recovery_and_is_skipped_by_the_next_pre_reference():
  # 6 strong minutes over 20 at 110 bpm (unconfirmed), HR 105 after it: rule -1 would call that recovery.
  n = 200
  hr = [70.0] * n
  strong, weak = [0] * n, [0] * n
  for i in range(40, 60):
    hr[i] = 110.0
    weak[i] = 1
  for i in (40, 44, 48, 52, 56, 59):
    strong[i], weak[i] = 1, 0
  for i in range(60, 75):
    hr[i] = 105.0
  out = es.session_spans(hr, strong, weak, 70.0)
  assert [(s["a"], s["b"], s["end"], s["confirmed"], s["confirmed_at"]) for s in out] == [(40, 59, 60, False, None)]


def test_rest_reference_is_resolved_per_period():
  # Two identical bouts at HR 100: only the one whose period's rest reference is low enough carries load.
  n = 200
  hr = [70.0] * n
  strong = [0] * n
  for i in list(range(20, 40)) + list(range(120, 140)):
    strong[i], hr[i] = 1, 100.0
  out = es.session_spans(hr, strong, [0] * n, lambda a: 70.0 if a < 100 else 80.0)
  assert [(s["a"], s["b"]) for s in out] == [(20, 39)]
  assert out[0]["confirmed"] and out[0]["confirmed_at"] == 34   # the 15th strong minute
