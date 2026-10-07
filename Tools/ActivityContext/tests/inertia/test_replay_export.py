"""Replay exporter (agent R): per-arm records from a synthetic recording; identical non-encoder inputs.

Everything here is synthetic and offline: no dataset, no HART checkpoint, no Swift.
"""

import json
import math

import numpy as np
import pytest

from activity_context.inertia import replay_data as rd
from activity_context.inertia import replay_export as rx

T0 = 1_758_000_000


def _recording(n=40, with_hart=True):
    sec = np.arange(n, dtype=np.int64)
    grav = np.tile(np.array([[0.0, 0.0, 1.0]], np.float32), (n, 1))
    dyn = np.linspace(0.005, 0.2, n).astype(np.float32)
    imu_s = np.arange(2, n - 5, 2, dtype=np.int64)
    imu_e = imu_s + 4
    feat = np.zeros((len(imu_s), len(rx.FEAT_KEYS)), np.float32)
    feat[:, rx.FEAT_KEYS.index("cadence_hz")] = np.nan          # None on the wire
    feat[:, rx.FEAT_KEYS.index("cadence_strength")] = 0.1
    if with_hart:
        hp = np.tile(np.array([[0.7, 0.2, 0.0, 0.1]]), (len(imu_s), 1))
        hl = np.asarray(["unknown"] * len(imu_s), dtype="<U16")
    else:
        hp = np.zeros((0, 4))
        hl = np.zeros(0, dtype="<U16")
    lab = np.zeros(n, np.int32)
    loco = np.full(n, 1 << rd.HEAD_ORDERS["locomotion"].index("stationary"), np.uint16)
    rec = rx.Recording(recording_id="syn-1", dataset="wisdm", subject="9999", split="test", t0=T0, sec=sec,
                       gravity=grav, dyn=dyn, truth_strict={"locomotion": loco}, truth_lenient={"locomotion": loco},
                       truth_label=lab, labels=("D",), imu_s=imu_s, imu_e=imu_e, imu_feat=feat,
                       hart_s=imu_s.copy() if with_hart else np.zeros(0, np.int64),
                       hart_e=imu_e.copy() if with_hart else np.zeros(0, np.int64),
                       hart_probs=hp, hart_label=hl)
    rec.validate()
    return rec


def _heads(rec, hop=5, stale=False, ood_first=False):
    e = np.arange(30, rec.n + 1, hop, dtype=np.int64)
    s = e - 30
    loco_order = rd.HEAD_ORDERS["locomotion"]
    p = np.full((len(e), len(loco_order)), np.nan)
    p[:, loco_order.index("stationary")] = 0.2
    p[:, loco_order.index("walking")] = 0.6
    p[:, loco_order.index("running")] = 0.2
    post_order = rd.HEAD_ORDERS["posture"]
    q = np.full((len(e), len(post_order)), np.nan)
    q[:, post_order.index("seated_likely")] = 0.9
    q[:, post_order.index("upright_stationary")] = 0.1
    is_ood = np.zeros(len(e), bool)
    if ood_first:
        is_ood[0] = True
    if stale:
        e = e - 100      # every window far older than the hop
        s = s - 100
    return rx.HeadsWindows(s=s, e=e, probs={"locomotion": p, "posture": q},
                           class_order={"locomotion": loco_order, "posture": post_order},
                           ood_score=np.zeros(len(e)), is_ood=is_ood)


def _lines(rec, heads=None, include_encoder=True):
    lines, rep = rx.observation_lines(rec, heads, include_encoder)
    return lines, rep


def test_observation_time_convention():
    rec = _recording()
    lines, _ = _lines(rec)
    assert lines[0]["obs"]["ts"] == T0 + 1                # second 0 closes at t0 + 1
    assert lines[-1]["obs"]["ts"] == T0 + rec.n
    assert all(ln["seq"] == "syn-1" for ln in lines)
    by_ts = {ln["obs"]["ts"]: ln["obs"] for ln in lines}
    e0 = T0 + int(rec.imu_e[0])
    assert by_ts[e0]["imu"]["e"] == e0 and by_ts[e0]["imu"]["s"] == T0 + int(rec.imu_s[0])
    assert by_ts[e0]["encoder"]["e"] == e0                # HART window rides on the second it ends
    assert by_ts[e0]["wear"] == "onWrist" and by_ts[e0]["sleep"] == "unknown"


def test_non_encoder_inputs_identical_across_variants():
    rec = _recording()
    heads = _heads(rec)
    full, _ = _lines(rec, heads, include_encoder=True)
    noenc, _ = _lines(rec, heads, include_encoder=False)
    bare, _ = _lines(rec, None, include_encoder=False)
    d = {rx.shared_inputs_digest(x) for x in (full, noenc, bare)}
    assert len(d) == 1
    assert any("encoder" in ln["obs"] for ln in full)
    assert not any("encoder" in ln["obs"] for ln in noenc)
    assert any("motion_heads" in ln["obs"] for ln in noenc)
    assert not any("motion_heads" in ln["obs"] for ln in bare)


def test_encoder_record_shape():
    rec = _recording()
    e = rx.encoder_record(rec, 0)
    assert e["id"] == "hart" and e["calibrated"] is True and e["abstained"] is True   # label 'unknown'
    assert set(e["probs"]) == {"stationary", "walking", "running", "other_movement"}
    assert e["probs"]["stationary"] == pytest.approx(0.7)


def test_heads_attach_rules():
    rec = _recording(n=60)
    heads = _heads(rec)
    lines, rep = _lines(rec, heads)
    assert rep.windows_in == len(heads) and rep.attached == len(heads) and rep.dropped_no_observation == 0
    by_ts = {ln["obs"]["ts"]: ln["obs"] for ln in lines}
    for i in range(len(heads)):
        w = by_ts[T0 + int(heads.e[i])]["motion_heads"]
        assert w["e"] == T0 + int(heads.e[i]) and w["is_ood"] in (True, False)
        assert set(w["locomotion"]) == {"stationary", "walking", "running"}   # supported classes only
    # a window whose [e, e+2] has no observed second is dropped and counted
    rec2 = _recording(n=60)
    keep = (rec2.sec < 29) | (rec2.sec > 33)
    for k in ("sec", "gravity", "dyn"):
        setattr(rec2, k, getattr(rec2, k)[keep])
    rec2.truth_strict = {h: m[keep] for h, m in rec2.truth_strict.items()}
    rec2.truth_lenient = {h: m[keep] for h, m in rec2.truth_lenient.items()}
    _, rep2 = rx.observation_lines(rec2, heads)
    assert rep2.dropped_no_observation == 1                 # window e = 30: seconds 30..32 are missing


def test_heads_superseded_on_same_second():
    rec = _recording(n=60)
    h = _heads(rec)
    h.e = np.array([30, 30], np.int64)
    h.s = np.array([0, 1], np.int64)
    h.probs = {k: v[:2] for k, v in h.probs.items()}
    h.is_ood = h.is_ood[:2]
    h.ood_score = h.ood_score[:2]
    at, rep = rx.attach_heads(rec.obs_ts(), h, rec.t0)
    assert rep.attached == 1 and rep.dropped_superseded == 1
    assert at[T0 + 30] == 1                                 # the later window (by (e, s)) wins


def test_harness_file(tmp_path):
    rec = _recording()
    heads = _heads(rec)
    bundle = {"encoder_id": "standin:handcrafted-stats-v1", "encoder_kind": "standin", "hop_s": 5}
    path = str(tmp_path / "in.jsonl")
    man = rx.write_harness_file(path, [rec], list(rx.HARNESS_ARMS), heads={rec.recording_id: heads},
                                bundle_info=bundle, weights={"locomotion": 0.25}, allow_standin=True)
    raw = open(path).read().splitlines()
    head = json.loads(raw[0])
    assert head["format"] == "nara-activity-replay-1" and head["arms"] == list(rx.HARNESS_ARMS)
    assert head["motion_heads"]["allow_standin_evidence_for_testing"] is True
    assert head["motion_heads"]["config"] == {"locomotion": 0.25}
    assert len(raw) == 1 + rec.n == 1 + man["lines"]
    for line in raw[1:]:
        r = json.loads(line)                                # strict JSON: no NaN / Infinity tokens
        imu = r["obs"].get("imu")
        if imu:
            assert imu["cadence_hz"] is None
            assert all(v is None or math.isfinite(v) for k, v in imu.items() if k not in ("s", "e"))
    with pytest.raises(ValueError):
        rx.harness_header(["A0"])


def test_arm_sources_cover_every_report_arm():
    assert set(rx.ARM_SOURCES) == set(rx.ARMS)
    for variant, arm in rx.ARM_SOURCES.values():
        assert variant in ("full", "noenc") and arm in rx.HARNESS_ARMS
    # A0 must keep the imu-feat-1 windows that A2 also sees (the harness `streams` arm drops them)
    assert rx.ARM_SOURCES["A0"] == ("noenc", "hart")


def test_recordings_roundtrip(tmp_path):
    rec = _recording()
    path = str(tmp_path / "recs.npz")
    rx.save_recordings([rec, _recording(n=20, with_hart=False)], path)
    back = rx.load_recordings(path)
    assert len(back) == 2
    a, b = rec, back[0]
    assert a.recording_id == b.recording_id and a.t0 == b.t0
    for k in ("sec", "gravity", "dyn", "imu_s", "imu_e", "hart_s", "hart_e", "hart_probs"):
        np.testing.assert_array_equal(getattr(a, k), getattr(b, k))
    np.testing.assert_array_equal(a.imu_feat, b.imu_feat)
    np.testing.assert_array_equal(a.truth_strict["locomotion"], b.truth_strict["locomotion"])
    assert len(back[1].hart_s) == 0


def test_validate_rejects_bad_shapes():
    rec = _recording()
    rec.dyn = rec.dyn[:-1]
    with pytest.raises(ValueError):
        rec.validate()


# ---------------------------------------------------------------------------
# replay_data helpers
# ---------------------------------------------------------------------------

def test_truth_masks_sets_mask_and_unknown():
    assert rd._mask_for("locomotion", "MASK") == 0
    assert rd._mask_for("locomotion", None) == 0
    assert rd._mask_for("locomotion", "unknown") == 0        # missing target != unknown
    order = rd.HEAD_ORDERS["locomotion"]
    m = rd._mask_for("locomotion", ["walking", "brisk_walking"])
    assert m == (1 << order.index("walking")) | (1 << order.index("brisk_walking"))
    assert rd.coarse_mask_from_locomotion(m) == 1 << rd.COARSE_ORDER.index("walking")
    assert rd._mask_for("posture", ["seated_likely", "nonsense"]) == 0


def test_nominal_rate_detection():
    def ts(rate, n=200):
        return (np.arange(n) * (1e9 / rate)).astype(np.int64)
    assert rd.nominal_rate(ts(20.01))[1] == 20
    assert rd.nominal_rate(ts(49.76))[1] == 50
    assert rd.nominal_rate(ts(24.8))[1] == 25
    with pytest.raises(ValueError):
        rd.nominal_rate(ts(33.0))


def test_split_recordings():
    acts = np.asarray(list("AAAABBBB"))
    ts = np.asarray([0, 1, 2, 3, 10, 11, 5_000_000_000, 5_000_000_001], dtype=np.int64)
    assert rd.split_recordings(acts, ts) == [(0, 4), (4, 6), (6, 8)]
    ts2 = np.asarray([0, 1, 2, 1, 2, 3, 4, 5], dtype=np.int64)    # clock goes backwards -> new recording
    acts2 = np.asarray(list("AAAAAAAA"))
    assert rd.split_recordings(acts2, ts2) == [(0, 3), (3, 8)]


def test_serve_windows_semantics():
    data30 = np.zeros((180 * 30, 6))
    data30[:, 2] = 1.0
    wins = rd.serve_windows(data30)
    assert wins[0].s == 2.0 and wins[0].e == 6.0            # k=0 is inside the 1 s FIR margin
    assert all(w.e - w.s == 4.0 for w in wins)
    assert all(b.s - a.s == 2.0 for a, b in zip(wins, wins[1:]))
    assert wins[-1].e <= 179.0                              # >= 1 s before the run end
    assert len(wins) == 87


def test_resample_to_30hz_rates():
    for rate in (20, 25, 50, 100):
        x = np.ones((rate * 10, 3))
        y = rd.resample_to_30hz(x, rate)
        assert y.shape[0] == 300
        # unit DC gain away from the edges (polyphase ripple of the Kaiser design is < 1e-3)
        np.testing.assert_allclose(y[30:-30], 1.0, atol=2e-3)


def test_per_second_proxies():
    pytest.importorskip("scipy")
    fs = 30
    t = np.arange(60 * fs) / fs
    still = np.zeros((len(t), 3))
    still[:, 2] = 1.0
    p = rd.per_second_proxies(still)
    assert p["gravity"].shape == (60, 3)
    np.testing.assert_allclose(p["gravity"][:, 2], 1.0, atol=1e-6)
    for k in rd.DYN_PROXY_NAMES:
        assert float(np.max(p[k])) < 1e-6, k
    moving = still.copy()
    moving[:, 2] += 0.2 * np.sin(2 * np.pi * 2.0 * t)       # 2 Hz bounce along gravity, 0.2 g amplitude
    q = rd.per_second_proxies(moving)
    mid = slice(5, 55)
    np.testing.assert_allclose(np.median(q["dyn_mag_rms"][mid]), 0.2 / np.sqrt(2), rtol=0.05)
    np.testing.assert_allclose(np.median(q["dyn_vec_rms"][mid]), 0.2 / np.sqrt(2), rtol=0.05)


def test_choose_dyn_proxy():
    med = {"a": {"rest": 0.007, "walking": 0.135, "running": 0.4},
           "b": {"rest": 0.07, "walking": 1.35, "running": 4.0}}
    best, errs = rd.choose_dyn_proxy(med)
    assert best == "a" and errs["a"] == pytest.approx(0.0) and errs["b"] == pytest.approx(1.0)
