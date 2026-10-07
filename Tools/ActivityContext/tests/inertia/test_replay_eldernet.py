"""Unit tests for the ElderNet / HART-v1 replay extension (no data, no xctest)."""

import json
import math

import numpy as np

from activity_context.inertia import replay_eldernet as rg
from activity_context.inertia import replay_eval as ev
from activity_context.inertia import replay_export as rx


def _names():
    return [m[0] for m in ev.DECODER_MODES]


def test_gait_loglr_is_neutral_at_the_prior():
    assert np.allclose(rg.gait_loglr(rg.GAIT_PRIOR), 0.0)


def test_gait_loglr_matches_the_swift_formula():
    q, pi, eps = 0.9, 0.065, 0.02
    rg_, rn = q / pi, (1 - q) / (1 - pi)
    a = (1 + eps) / (1 + 2 * eps)
    lg = min(10, max(0.1, rn + a * (rg_ - rn)))
    ln = min(10, max(0.1, rg_ + a * (rn - rg_)))
    v = rg.gait_loglr(q, pi)
    names = _names()
    for m, n in enumerate(names):
        want = math.log(lg) if n in ("walk", "briskWalk", "stairs") else (
            math.log(ln) if n in ("bedRest", "seated", "upright", "vehicle", "cycling") else 0.0)
        assert abs(v[m] - want) < 1e-12, n
    # run, otherExercise and the transitions are neutral
    for n in ("run", "otherExercise", "sitToStand", "standToSit", "lyingDown", "gettingUp"):
        assert v[names.index(n)] == 0.0


def test_gait_loglr_is_clipped():
    v = rg.gait_loglr(1.0, 0.065)
    assert v.max() <= math.log(10) + 1e-12 and v.min() >= math.log(0.1) - 1e-12


def test_floor_never_below_rho_hat_or_default():
    assert rg.floor_for(0.41) == 0.65
    assert rg.floor_for(0.701) == 0.71
    assert rg.floor_for(None) == 0.65
    assert rg.rho_grid(0.65) == [0.65, 0.8, 0.95]
    assert rg.rho_grid(0.83) == [0.83, 0.95]


def test_fresh_window_lookup_respects_the_hold():
    ends = np.array([10, 15, 20])
    assert rg._fresh(ends, 14, 5) == 0
    assert rg._fresh(ends, 15, 5) == 1
    assert rg._fresh(ends, 26, 5) is None
    assert rg._fresh(ends, 9, 5) is None


def test_wire_row_keeps_only_wire_keys():
    row = {"s": 1.0, "e": 11.0, "gait_prob": 0.9, "is_gait": True, "speed_mps": 1.2, "subject": "x", "session": "y",
           "cadence_spm": None}
    d = rg._wire_row(row, 1700000005)
    assert d == {"s": 1700000005, "e": 1700000015, "gait_prob": 0.9, "is_gait": True, "speed_mps": 1.2}


def _rec(n=40):
    return rx.Recording(recording_id="r1", dataset="wisdm", subject="1", split="val", t0=1700000000,
                        sec=np.arange(n, dtype=np.int64), gravity=np.zeros((n, 3), np.float32),
                        dyn=np.zeros(n, np.float32))


def test_gait_windows_attach_like_motion_heads_and_header(tmp_path):
    rec = _rec()
    rows = [{"s": 1700000000 + 5 * k, "e": 1700000010 + 5 * k, "gait_prob": 0.8, "is_gait": True} for k in range(5)]
    gw = rx.GaitWindows(rows)
    header = {"model": {"model_id": "eldernet"}, "gait_prior": 0.065, "config": rg.gait_config(0.25, 0.65, 0.65)}
    p = tmp_path / "f.jsonl"
    m = rx.write_harness_file(str(p), [rec], ["eldernet"], gait={"r1": gw}, gait_quality=header, include_encoder=False)
    lines = [json.loads(x) for x in p.read_text().splitlines()]
    assert lines[0]["gait_quality"]["gait_prior"] == 0.065 and lines[0]["arms"] == ["eldernet"]
    at = {ln["obs"]["ts"]: ln["obs"]["gait_quality"]["s"] for ln in lines[1:] if "gait_quality" in ln["obs"]}
    # each window rides on the first observed second >= its end
    assert at == {1700000010 + 5 * k: 1700000000 + 5 * k for k in range(5)}
    assert m["gait_attach"]["attached"] == 5
    # without gait the file is exactly the old format
    p2 = tmp_path / "g.jsonl"
    rx.write_harness_file(str(p2), [rec], ["hart"], include_encoder=False)
    assert "gait_quality" not in p2.read_text()


def test_new_harness_arms_are_known():
    for a in ("eldernet", "hart+eldernet", "hart+eldernet+inertia"):
        assert a in rx.HARNESS_ARMS
        rx.harness_header([a])


def test_arm_map_is_complete():
    for ds, arms in rg.ARMS.items():
        for x, y in rg.PAIRS[ds]:
            assert x in arms and y in arms
        assert set(rg._variants(ds, "fixed")) | set(rg._variants(ds, "gait")) == {v for v, _ in arms.values()}
