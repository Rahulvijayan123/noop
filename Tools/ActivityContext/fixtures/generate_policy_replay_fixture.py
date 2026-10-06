#!/usr/bin/env python3
"""Deterministic generator for the Swift/Python policy replay fixture.

Synthetic only (artifact policy: no raw WISDM data in git). Produces a small
JSON of timestamped 4-s windows (2-s hop) across THREE sessions with TWO known
WITHIN-session transitions, plus the exact epochs/transitions the Swift
ActivityContextPolicy.buildEpochs must emit. Both runtimes replay the same
file: the Swift test (ActivityContextPolicyReplayTests.swift) decodes `windows`
and asserts `expect`; the Python test (test_evaluate.py) derives
truth/labels/sessions/starts from it and asserts the same transition offsets
through the session-aware transition evaluator.

Timeline (base = 1_758_000_000, an exact multiple of the 30-s epoch grid):

  session 0: walking       [base+0,   base+60)   — internally constant
  (gap > gapResetSeconds)
  session 1: stationary    [base+120, base+150)
             walking       [base+150, base+190)   — transition 1 @ base+150
             stationary    [base+190, base+240)   — transition 2 @ base+190
  (gap)
  session 2: running       [base+300, base+360)   — internally constant

Every window's model `label` equals its ground truth (`truth`), so the replay
exercises the policy's temporal behavior (epoch folding, gap reset, hysteresis
lag, transition offsets), not classifier accuracy.

Run:  python3 generate_policy_replay_fixture.py [out.json]
"""

import json
import os
import sys

BASE = 1_758_000_000          # multiple of 30 -> clean epoch grid
HOP = 2
WINDOW = 4
REQUIRED_VOTES = 2
GAP_RESET = 4

PROB = 0.95
SECOND = 0.05
ONTOLOGY = ["stationary", "walking", "running", "other_movement", "unknown"]


def windows_for(label: str, start: int, end: int):
    out = []
    t = start
    while t + WINDOW <= end:
        probs = {k: SECOND for k in ONTOLOGY}
        probs[label] = PROB
        out.append({"s": t, "e": t + WINDOW, "label": label, "truth": label,
                    "probs": probs, "baseline": False})
        t += HOP
    return out


def main() -> int:
    windows = []
    windows += windows_for("walking", BASE, BASE + 60)          # session 0
    windows += windows_for("stationary", BASE + 120, BASE + 150)  # session 1 (a)
    windows += windows_for("walking", BASE + 150, BASE + 190)     # session 1 (b)
    windows += windows_for("stationary", BASE + 190, BASE + 240)  # session 1 (c)
    windows += windows_for("running", BASE + 300, BASE + 360)     # session 2

    expect_epochs = [
        {"s": BASE, "e": BASE + 30, "motion": "walking", "observedS": 30, "validS": 30},
        {"s": BASE + 30, "e": BASE + 60, "motion": "walking", "observedS": 30, "validS": 30},
        {"s": BASE + 120, "e": BASE + 150, "motion": "stationary", "observedS": 30, "validS": 30},
        {"s": BASE + 150, "e": BASE + 180, "motion": "walking", "observedS": 30, "validS": 30},
        {"s": BASE + 180, "e": BASE + 210, "motion": "stationary", "observedS": 30, "validS": 30},
        {"s": BASE + 210, "e": BASE + 240, "motion": "stationary", "observedS": 30, "validS": 30},
        {"s": BASE + 300, "e": BASE + 330, "motion": "running", "observedS": 30, "validS": 30},
        {"s": BASE + 330, "e": BASE + 360, "motion": "running", "observedS": 30, "validS": 30},
    ]
    expect_transitions = [
        {"from": "stationary", "to": "walking", "offset": BASE + 150},
        {"from": "walking", "to": "stationary", "offset": BASE + 190},
    ]

    fixture = {
        "meta": {
            "name": "policy-replay-3-sessions",
            "description": (
                "Synthetic timestamped windows across 3 sessions with 2 known "
                "within-session transitions; expected ActivityContextPolicy "
                "epochs/transitions. See generate_policy_replay_fixture.py."),
            "generator": "Tools/ActivityContext/fixtures/generate_policy_replay_fixture.py",
            "base": BASE,
            "n_windows": len(windows),
        },
        "runStart": BASE - 60,
        "runEnd": BASE + 360,
        "config": {"requiredConsecutiveVotes": REQUIRED_VOTES,
                   "gapResetSeconds": GAP_RESET},
        "windows": windows,
        "expect": {"epochs": expect_epochs, "transitions": expect_transitions},
    }

    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "policy_replay_fixture.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(fixture, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {out}: {len(windows)} windows, {len(expect_epochs)} epochs, "
          f"{len(expect_transitions)} transitions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
