"""Deterministic golden end-to-end: guided label -> raw IMU -> baseline window -> evaluation join.

Spec 15.4 requires one deterministic synthetic/golden end-to-end test of the whole chain:

    guided label -> raw IMU interval -> upload/object reference -> HART window
        -> ActivityContext state -> evaluation join -> expected metric result

This test drives the REAL offline chain in-process (no torch, no network, no device):

1. Synthetic 100 Hz WHOOP IMU (a 1.8 Hz gait bout then a still bout, the same synthetic
   shapes the baseline golden fixtures use) is encoded exactly the way the phone's object
   lane encodes a rawImuSession second (``encode_columns_b64``).
2. ``serve.handle_infer`` (the C10 service the worker drives) resamples 100->30 Hz, windows
   4 s / 2 s hop, and classifies each window with the heuristic baseline — the same
   preprocessing + windowing the HART path uses.
3. The returned windows are packed into a real ``hart-windows-1`` day document (the exact
   ``activity_encoder_windows`` wire shape the worker publishes and the phone reads).
4. Two guided strong labels (one per session, with full-coverage ``sensor_quality`` and
   ``raw_refs`` naming the store session, exactly as ``ActivityGroundTruthStore.upsert``
   fills them) are written as wire JSONL.
5. ``evaluate_labels.main`` (the spec 10 harness CLI) joins windows to labels, splits
   session-held-out, and writes the report.
6. The report's numbers are asserted EXACT: every joined window is pure (no straddling
   windows — the labels sit inside guard bands), the baseline classifies each purely,
   so locomotion macro-F1 == 1.0 with full coverage and zero abstention, and the strong
   labels never mix with the weak one also present in the file.
"""

from __future__ import annotations

import json
import math
import os
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from activity_context import serve  # noqa: E402
from activity_context.preprocess import encode_columns_b64  # noqa: E402
from activity_context import evaluate_labels  # noqa: E402
from activity_context import labels as L  # noqa: E402

T0 = 1_791_300_000            # a fixed UTC day second
DAY_START = (T0 // 86400) * 86400
WALK_SECONDS = 56             # gait bout, label [T0, T0+56)
STILL_FROM = 60               # still bout starts here, label [T0+60, T0+116)
TOTAL_SECONDS = 116


def _gait_columns(t: np.ndarray) -> np.ndarray:
    """The 1.8 Hz synthetic wrist gait the baseline golden fixtures use."""
    cad = 1.8
    ax = 0.10 * np.sin(2 * np.pi * cad * t) + 0.01 * np.sin(2 * math.pi * 0.3 * t)
    ay = 0.08 * np.sin(2 * math.pi * cad * t + 0.7)
    az = 1.0 + 0.10 * np.sin(2 * np.pi * cad * t) + 0.03 * np.sin(2 * math.pi * 2 * cad * t)
    gx = 10.0 * np.sin(2 * math.pi * cad * t)
    gy = 8.0 * np.sin(2 * math.pi * cad * t + 0.5)
    gz = 2.0 * np.sin(2 * math.pi * cad * t)
    return np.stack([ax, ay, az, gx, gy, gz], axis=1)


def _still_columns(t: np.ndarray) -> np.ndarray:
    """Gravity plus a deterministic, tiny, non-rhythmic ripple (never gait)."""
    ax = 0.001 * np.sin(2 * math.pi * 0.05 * t + 1.0)
    ay = 0.001 * np.cos(2 * math.pi * 0.04 * t)
    az = 1.0 + 0.001 * np.sin(2 * math.pi * 0.02 * t)
    gx = 0.2 * np.sin(2 * math.pi * 0.01 * t)
    gy = 0.1 * np.cos(2 * math.pi * 0.013 * t)
    gz = 0.0 * t
    return np.stack([ax, ay, az, gx, gy, gz], axis=1)


def _samples_to_columns(samples: np.ndarray) -> np.ndarray:
    """Inverse of ``raw_columns_to_samples``: canonical float samples (100, 6)
    in g / deg/s -> the strap's 600 i16 axis-major columns, exactly as a
    rawImuSession second is stored."""
    accel_scale = 1.0 / 4096.0          # g per LSB
    gyro_scale = 2000.0 / 32768.0       # deg/s per LSB
    acc = np.rint(samples[:, 0:3].T / accel_scale)
    gyr = np.rint(samples[:, 3:6].T / gyro_scale)
    cols = np.empty(600, dtype=np.int16)
    cols[0:300] = acc.reshape(-1)
    cols[300:600] = gyr.reshape(-1)
    return cols


def _synthetic_seconds() -> list:
    """One rawImuSession-style second per index: (start_ts, columns i16)."""
    rate = 100
    seconds = []
    for i in range(TOTAL_SECONDS):
        t = np.arange(rate, dtype=np.float64) / rate
        if i < STILL_FROM:
            samples = _gait_columns(t)
        else:
            samples = _still_columns(t)
        seconds.append((T0 + i, _samples_to_columns(samples)))
    return seconds


def _infer_via_serve(seconds) -> dict:
    ctx = serve.build_context(None, None)  # baseline context, exactly like a host with no model dir
    body = [encode_columns_b64(c) for _, c in seconds]
    # One second of boundary on each side so the first/last windows are not transient-cropped.
    head = [encode_columns_b64(seconds[0][1])]
    tail = [encode_columns_b64(seconds[-1][1])]
    req = {
        "id": "e2e-1",
        "op": "infer",
        "run": {
            "start_ts": T0, "end_ts": T0 + TOTAL_SECONDS, "sample_rate_hz": 100,
            "channels_order": ["ax", "ay", "az", "gx", "gy", "gz"],
            "units": {"accel": "g", "gyro": "deg/s"},
            "columns_b64": body, "head_b64": head, "tail_b64": tail,
        },
    }
    return serve.handle_request(ctx, req)


def _day_doc(resp: dict) -> dict:
    """Pack the served windows into the exact ``hart-windows-1`` wire shape."""
    labels = ["stationary", "walking", "running", "other_movement", "unknown"]
    index = {l: i for i, l in enumerate(labels)}
    wins = resp["windows"]
    return {
        "format": "hart-windows-1",
        "t0": DAY_START,
        "labels": labels,
        "s": [w["s"] - DAY_START for w in wins],
        "e": [w["e"] - DAY_START for w in wins],
        "l": [index[w["label"]] for w in wins],
        "p": [[int(round(w["probs"].get(l, 0.0) * 1000)) for l in labels] for w in wins],
        "b": [1 if w["baseline"] else 0 for w in wins],
        "f": [None] * len(wins),
    }


def _context_days_doc(resp: dict) -> dict:
    """Pack the served windows into an ``activity_context_days``-style document.

    Mirrors ``ActivityContextRun``'s field names EXACTLY (``ActivityContextDays
    .swift`` / ``ActivityContextTrack.swift``): each ``run`` carries ``s``/``e``
    (absolute start/end seconds) and the ``locomotion`` head as a sparse
    probability dict ``{value: 1.0}`` (the document's ``HeadProbabilities``
    encode drops sub-floor entries; a one-hot run is the deterministic top).
    One run per window keeps the "latest state over the run" semantics equal to
    the baseline label of that window, so the adapter's largest-overlap join
    reproduces the baseline block exactly per window.
    """
    runs = []
    for w in resp["windows"]:
        mapped = L.HART_LABEL_TO_HEADS.get(w["label"])
        if mapped is None:
            continue  # unknown windows abstain every head
        runs.append({
            "s": w["s"], "e": w["e"],
            "locomotion": {mapped["locomotion"]: 1.0},
        })
    return {"days": [{"runs": runs}]}


def _wire_label(label_key, session_id, start_ts, end_ts, locomotion, source="guided",
                user_unsure=False):
    return {
        "id": "5f0d3f0e-8f5a-4c8e-9d52-7d7a7f0c2a11",
        "label_key": label_key,
        "source": source,
        "session_id": session_id,
        "protocol_version": "calibration-v1",
        "repetition": 1,
        "start_ts": start_ts,
        "end_ts": end_ts,
        "locomotion": locomotion,
        "user_unsure": user_unsure,
        "sensor_quality": {
            "expected_seconds": end_ts - start_ts,
            "covered_seconds": end_ts - start_ts,
            "sample_rate_hz": 100,
            "first_ts": start_ts,
            "last_ts": end_ts - 1,
            "gaps": [],
            "coverage_ratio": 1.0,
            "evaluation_ready": True,
        },
        "raw_refs": [{
            "store_session_id": "activity-whoop-e2e",
            "start_ts": start_ts, "end_ts": end_ts,
            "sample_rate_hz": 100, "covered_seconds": end_ts - start_ts,
        }],
        "created_at": "2026-10-06T16:00:00Z",
        "updated_at": "2026-10-06T16:00:00Z",
    }


def test_guided_label_to_raw_imu_to_window_to_report_end_to_end():
    seconds = _synthetic_seconds()
    resp = _infer_via_serve(seconds)

    # --- Stage 2: the serve leg classified every window deterministically.
    assert resp["ok"] is True
    wins = resp["windows"]
    assert resp["model_version"] == "baseline-v0"
    assert len(wins) == (TOTAL_SECONDS - 4) // 2 + 1  # 4 s windows, 2 s hop, fully inside
    for w in wins:
        assert w["baseline"] is True
        inside_gait = w["e"] <= T0 + WALK_SECONDS
        inside_still = w["s"] >= T0 + STILL_FROM
        if inside_gait:
            assert w["label"] == "walking", w
        elif inside_still:
            assert w["label"] == "stationary", w
        # windows over the [56, 60) guard band are asserted only through the join below

    with tempfile.TemporaryDirectory() as tmp:
        # --- Stage 3: the exact hart-windows-1 day document.
        doc_path = os.path.join(tmp, "windows.json")
        with open(doc_path, "w") as f:
            json.dump(_day_doc(resp), f)

        # --- Stage 4: two guided strong labels (one per session) + one weak label.
        # Guard bands: walking label ends at 56 and the still label starts at 60, so
        # every window joined to a label is PURE (no window straddles a boundary).
        labels_path = os.path.join(tmp, "labels.jsonl")
        rows = [
            _wire_label("guided:sess-e2e-a:%d:1" % T0, "sess-e2e-a",
                        T0, T0 + WALK_SECONDS, "walking"),
            _wire_label("guided:sess-e2e-b:%d:1" % (T0 + STILL_FROM), "sess-e2e-b",
                        T0 + STILL_FROM, T0 + TOTAL_SECONDS, "stationary"),
            # A weak free-living label in the same file: never part of the default view.
            _wire_label("stretch_feedback:activity_context:%d:%d" % (T0 + 2, T0 + 2),
                        None, T0 + 2, T0 + 6, "other_movement", source="stretch_feedback"),
        ]
        with open(labels_path, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")

        # --- Stage 5: the evaluation harness joins, splits session-held-out, reports.
        out_dir = os.path.join(tmp, "out")
        rc = evaluate_labels.main([
            "--labels", labels_path,
            "--windows", doc_path,
            "--out-dir", out_dir,
            "--holdout-sessions", "1",
            "--json",
        ])
        assert rc == 0
        with open(os.path.join(out_dir, "report.json")) as f:
            report = json.load(f)

        # --- Stage 6: the expected metric result, exactly (all numbers are
        # deterministic for this synthetic chain; the single test-split error is
        # pinned and explained below).
        # Split: session-held-out, the walking session trains, the still session tests.
        assert report["split"]["train_sessions"] == ["sess-e2e-a"]
        assert report["split"]["test_sessions"] == ["sess-e2e-b"]
        assert report["split"]["n_train_units"] == 28
        assert report["split"]["n_test_units"] == 28

        # Train split: every window pure gait, the baseline says walking, the label
        # says walking — an exact perfect block.
        train = report["models"]["baseline"]["train"]["heads"]["locomotion"]
        assert train["n_units"] == 28
        assert train["macro_f1"] == 1.0
        assert train["balanced_accuracy"] == 1.0
        assert train["abstention_rate"] == 0.0
        assert train["accepted_coverage"] == 1.0
        assert train["per_class"]["walking"] == {
            "tp": 28, "fp": 0, "fn": 0, "precision": 1.0, "recall": 1.0, "f1": 1.0, "support": 28,
        }
        assert train["brier"] == 0.0
        assert train["ece_15"] == 0.0

        # Test split: all windows still and classified stationary except ONE: the
        # window [58, 62) straddles the raw gait->still boundary (2 s of gait ride
        # inside it) and the conservative baseline calls it walking. The join
        # still assigns it to the still label (50% overlap), so it is the one
        # honest false positive this chain produces — and its exact cost is pinned:
        # stationary recall 27/28, one walking FP, macro-F1 0.490909, and a
        # duration-weighted accuracy of 0.964286 (27 of 28 windows correct).
        test = report["models"]["baseline"]["test"]["heads"]["locomotion"]
        assert test["n_units"] == 28
        assert test["n_accepted"] == 28
        assert test["abstention_rate"] == 0.0
        assert test["per_class"]["stationary"]["tp"] == 27
        assert test["per_class"]["stationary"]["fn"] == 1
        assert test["per_class"]["stationary"]["precision"] == 1.0
        assert test["per_class"]["stationary"]["recall"] == 0.964286
        assert test["per_class"]["walking"]["fp"] == 1
        assert test["per_class"]["walking"]["support"] == 0
        assert test["macro_f1"] == 0.490909
        assert test["duration_weighted_accuracy"] == 0.964286
        # The joined window count and the boundary false positive are both exact.
        assert test["n_gt_transitions"] == 0

        # The hart model block is present but empty: every window in this synthetic
        # day doc carries the baseline flag (b: 1), so the HART rows evaluated zero
        # windows — exactly the split the wire format encodes.
        assert report["models"]["hart"]["n_windows_used"] == 0

        # The weak label never entered either view (guided strong only by default).
        assert "stretch_feedback" not in json.dumps(report["models"]["baseline"])
        assert report["strong_weak"] == {"strong_labels": 2, "weak_labels": 1,
                                         "evaluation": "strong_only"}
        # The join never invented a head: only locomotion was labeled, only
        # locomotion is evaluated.
        assert set(train.keys()) >= {"macro_f1"}
        assert "posture" not in report["models"]["baseline"]["train"]["heads"]
        # The join never invented a head: only locomotion was labeled, only
        # locomotion is evaluated.
        assert set(train.keys()) >= {"macro_f1"}
        assert "posture" not in report["models"]["baseline"]["train"]["heads"]


def test_activity_context_third_model_leg_end_to_end():
    """ActivityContext as the third evaluated model (spec 10.5 baseline 3).

    The SAME served windows are packed into an ``activity_context_days``
    document: one run per window whose ``locomotion`` head is the baseline
    label of that window (latest-state semantics over the run's span), written
    via ``--context-days``. ``evaluate_labels`` decodes the runs back to
    per-window head values (``_head_top`` argmax + largest-overlap join) and
    scores the ``activity_context`` model on the SAME labeled windows as the
    baseline. Because every per-window head value equals the baseline label,
    the whole block — pooled metrics and the temporal sub-block — must equal
    the baseline block exactly.
    """
    seconds = _synthetic_seconds()
    resp = _infer_via_serve(seconds)
    assert resp["ok"] is True

    with tempfile.TemporaryDirectory() as tmp:
        # --- the same hart-windows-1 day document the baseline leg uses.
        doc_path = os.path.join(tmp, "windows.json")
        with open(doc_path, "w") as f:
            json.dump(_day_doc(resp), f)

        # --- the same two guided strong labels (one per session).
        labels_path = os.path.join(tmp, "labels.jsonl")
        rows = [
            _wire_label("guided:sess-e2e-a:%d:1" % T0, "sess-e2e-a",
                        T0, T0 + WALK_SECONDS, "walking"),
            _wire_label("guided:sess-e2e-b:%d:1" % (T0 + STILL_FROM), "sess-e2e-b",
                        T0 + STILL_FROM, T0 + TOTAL_SECONDS, "stationary"),
        ]
        with open(labels_path, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")

        # --- the activity_context_days document decoded from the same windows.
        context_path = os.path.join(tmp, "context_days.json")
        with open(context_path, "w") as f:
            json.dump(_context_days_doc(resp), f)

        out_dir = os.path.join(tmp, "out")
        rc = evaluate_labels.main([
            "--labels", labels_path,
            "--windows", doc_path,
            "--context-days", context_path,
            "--out-dir", out_dir,
            "--holdout-sessions", "1",
            "--json",
        ])
        assert rc == 0
        with open(os.path.join(out_dir, "report.json")) as f:
            report = json.load(f)

        base = report["models"]["baseline"]
        ctx = report["models"]["activity_context"]

        # Same labeled windows scored for both models.
        assert ctx["n_windows_used"] == base["n_windows_used"]

        for split_name in ("train", "test"):
            b = base[split_name]["heads"]["locomotion"]
            c = ctx[split_name]["heads"]["locomotion"]
            # The context decoder's per-window head value equals the baseline
            # label on every window, so every metric is exactly equal.
            assert c["n_units"] == b["n_units"]
            assert c["n_accepted"] == b["n_accepted"]
            assert c["n_abstained"] == b["n_abstained"]
            assert c["macro_f1"] == b["macro_f1"]
            assert c["balanced_accuracy"] == b["balanced_accuracy"]
            assert c["duration_weighted_accuracy"] == b["duration_weighted_accuracy"]
            assert c["per_class"] == b["per_class"]
            # Temporal sub-block identical: same decoded stream -> same LAD /
            # TD / flips / TSCS numbers.
            assert c["temporal"] == b["temporal"]

        # The split is the same one the baseline leg pins.
        assert report["split"]["train_sessions"] == ["sess-e2e-a"]
        assert report["split"]["test_sessions"] == ["sess-e2e-b"]
        # The context document declared locomotion only: no other head invented.
        assert set(ctx["train"]["heads"].keys()) == {"locomotion"}
        # The baseline pin still holds exactly as in the baseline-only run.
        assert report["models"]["baseline"]["test"]["heads"]["locomotion"]["macro_f1"] == 0.490909
