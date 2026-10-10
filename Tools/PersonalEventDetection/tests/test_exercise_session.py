"""Rule exercise-session-2 (personal_events/exercise_session.py) against the shared contract cases
(contracts/reference/exercise-session-2.json), the same cases the phone's ExerciseSessionRule is checked with."""
import dataclasses
import json
import math
import pathlib
import unittest

import numpy as np

from personal_events import exercise_session as X

CONTRACT = pathlib.Path(__file__).resolve().parents[3] / "contracts" / "reference" / "exercise-session-2.json"


class ContractCases(unittest.TestCase):
  def test_sessions_match_the_contract(self):
    doc = json.loads(CONTRACT.read_text())
    self.assertEqual(doc["rule"], "exercise-session-2")
    self.assertTrue(doc["cases"])
    for case in doc["cases"]:
      hr = np.array([math.nan if v is None else float(v) for v in case["hr"]])
      got = X.sessions(case["t0"], hr, [bool(v) for v in case["strong"]], [bool(v) for v in case["weak"]],
                       case["rest_reference"])
      want = case["sessions"]
      self.assertEqual(len(got), len(want), case["name"])
      for g, w in zip(got, want):
        g = dataclasses.asdict(g)
        for key in ("start", "end", "recovery_end", "confirmed", "confirmed_at"):
          self.assertEqual(g[key], w[key], f"{case['name']} {key}")
        self.assertAlmostEqual(g["pre_reference"], w["pre_reference"], places=9, msg=case["name"])


if __name__ == "__main__":
  unittest.main()
