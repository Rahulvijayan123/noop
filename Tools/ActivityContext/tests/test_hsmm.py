"""HSMM decoder port tests — golden-validated against the real Swift ActivityContext decoder.

The golden fixture (fixtures/hsmm_golden.json) was produced by the scratch Swift package
/tmp/hsmm-golden, which feeds deterministic synthetic IMU-only scenarios through the SAME types the
app uses (ActivityContextTrackInput + ActivityContextTrackBuilder.build, i.e.
ActivityContextTrackBuilder.observations(for:) then the hsmm-1.5 decoder). The Python port
(activity_context.hsmm) must reproduce every scenario's events exactly (kind, ts, and probability
within 1e-9) and the published heads at each checkpoint state (within 1e-9).

Also pinned here: run-to-run determinism (bit-identical), w_transition=0.0 with transition windows
supplied == no transition windows (bit-identical Model A), and fail-open parsing of malformed
transition windows (dropped, never fatal).
"""

import json
import os

import pytest

from activity_context.hsmm import HsmmDecoder

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures")
GOLDEN = os.path.join(FIXTURES, "hsmm_golden.json")

TOL = 1e-9
# The Swift constant wTransition is 0.6 (hsmm-1.5); the Python API defaults to 0.0 so a harness that
# does not opt in keeps Model A bit-identical. Golden parity for expert evidence needs the Swift value.
SWIFT_W_TRANSITION = 0.6

IMU_KEYS = ("accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz",
            "cadence_strength", "orientation_change_deg")


@pytest.fixture(scope="module")
def golden():
    with open(GOLDEN) as fh:
        return json.load(fh)


def _imu(win):
    return (win["s"], win["e"], {k: win[k] for k in IMU_KEYS})


def _encoder(win):
    return (win["s"], win["e"], {"probs": win["probs"],
                                 "calibrated": win.get("calibrated", not win["baseline"])})


def _transition(win):
    p = win["probabilities"]
    return (win["s"], win["e"], {
        "none": p[0], "sit_to_stand": p[1], "stand_to_sit": p[2],
        "lie_down": p[3], "get_up": p[4], "abstained": win["abstained"],
    })


def _run_scenario(sc):
    """Run the Python port on one fixture scenario (the exact inputs the Swift decoder saw)."""
    dec = HsmmDecoder()
    enc = [_encoder(e) for e in sc["encoder_windows"]] or None
    trans = [_transition(t) for t in sc["transition_windows"]] or None
    wtr = SWIFT_W_TRANSITION if trans else 0.0
    return dec.run([_imu(w) for w in sc["imu_windows"]], sc["start_ts"], sc["end_ts"],
                   encoder_windows=enc, transition_windows=trans, w_transition=wtr)


def _assert_events_close(got, want, scenario):
    assert len(got) == len(want), (
        f"{scenario}: event count {len(got)} != {len(want)}")
    for i, (g, w) in enumerate(zip(got, want)):
        assert g["kind"] == w["kind"], f"{scenario}: event {i} kind {g} != {w}"
        assert g["ts"] == w["ts"], f"{scenario}: event {i} ts {g} != {w}"
        assert abs(g["prob"] - w["prob"]) <= TOL, (
            f"{scenario}: event {i} prob {g['prob']} != {w['prob']} "
            f"(diff {abs(g['prob'] - w['prob']):.3e})")


def _assert_states_close(got, want, scenario):
    by_ts = {st["ts"]: st for st in got}
    assert set(w["ts"] for w in want) <= set(by_ts), (
        f"{scenario}: golden checkpoints not all published")
    for w in want:
        g = by_ts[w["ts"]]
        for head in ("posture", "locomotion", "arm_behavior"):
            assert set(g[head]) == set(w[head]), (
                f"{scenario}@{w['ts']} {head}: head keys differ "
                f"{set(g[head]) ^ set(w[head])}")
            for k, v in w[head].items():
                assert abs(g[head][k] - v) <= TOL, (
                    f"{scenario}@{w['ts']} {head}[{k}]: {g[head][k]} != {v}")
        for field in ("overall_confidence", "overall_uncertainty"):
            assert abs(g[field] - w[field]) <= TOL, (
                f"{scenario}@{w['ts']} {field}: {g[field]} != {w[field]}")
        assert (g["intensity"] is None) == (w["intensity"] is None), (
            f"{scenario}@{w['ts']} intensity None-ness differs")
        if g["intensity"] is not None:
            assert abs(g["intensity"] - w["intensity"]) <= TOL
        assert (g["transition"] is None) == (w["transition"] is None), (
            f"{scenario}@{w['ts']} transition presence differs")
        if g["transition"] is not None:
            assert g["transition"]["kind"] == w["transition"]["kind"]
            assert g["transition"]["ts"] == w["transition"]["ts"]
            assert abs(g["transition"]["prob"] - w["transition"]["prob"]) <= TOL


def test_golden_events_and_states(golden):
    """Every scenario reproduces the Swift decoder's events and checkpoint posteriors."""
    # Generated at hsmm-1.5. hsmm-1.6 only changes scoring for inputs these scenarios never carry, and
    # StrandAnalytics' ActivityHsmmGoldenParityTests replays this same file through the 1.6 Swift decoder.
    assert golden["decoder"] == "hsmm-1.5"
    assert len(golden["scenarios"]) <= 8
    for sc in golden["scenarios"]:
        res = _run_scenario(sc)
        got_events = [{"kind": e["kind"], "prob": e["prob"], "ts": e["ts"]}
                      for e in res.events]
        _assert_events_close(got_events, sc["events"], sc["name"])
        _assert_states_close(res.states, sc["states"], sc["name"])


def test_deterministic(golden):
    """Two runs over the same stream are bit-identical (no dict-order or RNG dependence)."""
    for sc in golden["scenarios"]:
        a = _run_scenario(sc)
        b = _run_scenario(sc)
        assert a.events == b.events
        assert a.states == b.states


def test_w_transition_zero_is_model_a(golden):
    """transition_windows with w_transition=0.0 == no transition windows, bit-identical."""
    sc = next(s for s in golden["scenarios"] if s["name"] == "transition_expert")
    dec = HsmmDecoder()
    imu = [_imu(w) for w in sc["imu_windows"]]
    trans = [_transition(t) for t in sc["transition_windows"]]
    with_trans = dec.run(imu, sc["start_ts"], sc["end_ts"],
                         transition_windows=trans, w_transition=0.0)
    without = dec.run(imu, sc["start_ts"], sc["end_ts"], transition_windows=None)
    assert with_trans.events == without.events
    assert with_trans.states == without.states


def test_malformed_transition_windows_dropped(golden):
    """Malformed transition windows are dropped, never fatal, and change nothing."""
    sc = next(s for s in golden["scenarios"] if s["name"] == "transition_expert")
    dec = HsmmDecoder()
    imu = [_imu(w) for w in sc["imu_windows"]]
    baseline = dec.run(imu, sc["start_ts"], sc["end_ts"], transition_windows=None)

    bad_windows = [
        (sc["start_ts"], sc["start_ts"] + 4, {"none": "not-a-number", "sit_to_stand": 0.1,
                                              "stand_to_sit": 0.1, "lie_down": 0.1, "get_up": 0.1}),
        (sc["start_ts"] + 6, sc["start_ts"] + 10, {"none": float("nan"), "sit_to_stand": 0.2,
                                                   "stand_to_sit": 0.2, "lie_down": 0.2, "get_up": 0.2}),
        (sc["start_ts"] + 12, sc["start_ts"] + 16, {"none": 0.5, "sit_to_stand": float("inf")}),
        (sc["start_ts"] + 18, sc["start_ts"] + 22, "garbage"),
        (sc["start_ts"] + 24, sc["start_ts"] + 28, None),
        None,
        (sc["start_ts"] + 30, sc["start_ts"] + 34, {"none": 0.5, "sit_to_stand": 0.1,
                                                    "stand_to_sit": 0.1, "lie_down": 0.1,
                                                    "get_up": 0.1, "abstained": True}),
    ]
    res = dec.run(imu, sc["start_ts"], sc["end_ts"], transition_windows=bad_windows)
    assert res.events == baseline.events
    assert res.states == baseline.states


def test_fixture_under_size_budget():
    size = os.path.getsize(GOLDEN)
    assert size < 200 * 1024, f"fixture too large: {size} bytes"
