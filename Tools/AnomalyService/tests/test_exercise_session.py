"""Rule exercise-session-1 (docs/context-watchdog/EXERCISE_SESSION.md): the service's port must reproduce the shared
parity fixture contracts/reference/exercise-session-1.json exactly (the phone and the SQL builder are pinned to the
same file)."""
import json
import os

import pytest

from frwhoop_anomaly import exercise_session as es

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FIXTURE = os.path.join(REPO, "contracts", "reference", "exercise-session-1.json")


@pytest.mark.skipif(not os.path.exists(FIXTURE), reason="contracts/ not in this checkout")
def test_rule_matches_the_shared_fixture_exactly():
  d = json.load(open(FIXTURE))
  assert d["rule"] == es.RULE
  assert len(d["cases"]) >= 7
  for c in d["cases"]:
    got = es.sessions(c["t0"], c["hr"], c["strong"], c["weak"], c["rest_reference"])
    assert got == c["sessions"], c["name"]
    # A per-period rest reference that is constant gives the same answer.
    assert es.sessions(c["t0"], c["hr"], c["strong"], c["weak"], lambda a, r=c["rest_reference"]: r) == got


def test_rest_reference_is_resolved_per_period():
  # Two identical bouts at HR 100: only the one whose period's rest reference is low enough carries load.
  n = 200
  hr = [70.0] * n
  strong = [0] * n
  for i in list(range(20, 40)) + list(range(120, 140)):
    strong[i], hr[i] = 1, 100.0
  out = es.session_spans(hr, strong, [0] * n, lambda a: 70.0 if a < 100 else 80.0)
  assert [(s["a"], s["b"]) for s in out] == [(20, 39)]
