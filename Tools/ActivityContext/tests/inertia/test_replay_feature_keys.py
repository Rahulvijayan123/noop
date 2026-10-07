"""Replay IMU feature windows speak the Swift decoder's imu-feat-2 keys (audit D9-09).

The Swift ``ImuWindowFeatures`` decoder requires ``jerk_rms_gps`` (per-second jerk). The replay exporter wrote
the retired imu-feat-1 name ``jerk_rms``, so every exported replay failed to decode in the Swift harness with
``keyNotFound``. These tests pin the wire keys to the Swift CodingKeys and the legacy conversion (x30 Hz).
"""

import os
import re

import numpy as np

from activity_context.inertia import replay_data as rd
from activity_context.inertia import replay_export as rx

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
EVIDENCE = os.path.join(REPO, "Packages", "StrandAnalytics", "Sources", "StrandAnalytics",
                        "ActivityContextEvidence.swift")


def _swift_imu_keys():
    src = open(EVIDENCE, encoding="utf-8").read()
    block = src[src.index("enum CodingKeys"):]
    block = block[:block.index("}")]
    keys = set(re.findall(r'"([a-z_]+)"', block)) - {"s", "e"}
    return keys


def test_feature_keys_match_swift_codingkeys():
    assert set(rd.FEAT_KEYS) == _swift_imu_keys()


def test_imu_record_writes_swift_keys():
    feat = np.asarray([[0.01, 0.0, 0.42, np.nan, 0.1, np.nan]], np.float32)
    n = 8
    rec = rx.Recording(recording_id="k", dataset="wisdm", subject="1", split="test", t0=1_758_000_000,
                       sec=np.arange(n, dtype=np.int64),
                       gravity=np.tile(np.array([[0.0, 0.0, 1.0]], np.float32), (n, 1)),
                       dyn=np.zeros(n, np.float32), imu_s=np.asarray([0]), imu_e=np.asarray([4]), imu_feat=feat)
    d = rx.imu_record(rec, 0)
    assert set(d) - {"s", "e"} == _swift_imu_keys()
    assert d["jerk_rms_gps"] == 0.42
    assert d["cadence_hz"] is None and d["orientation_change_deg"] is None


def test_legacy_jerk_is_converted_per_second():
    legacy_keys = ("accel_rms_g", "gyro_rms_dps", "jerk_rms", "cadence_hz", "cadence_strength",
                   "orientation_change_deg")
    stored = np.asarray([[0.01, 0.0, 0.002, 1.8, 0.4, 3.0]], np.float32)
    cur = rd.current_feature_matrix(stored, legacy_keys)
    jerk = cur[0, rd.FEAT_KEYS.index("jerk_rms_gps")]
    assert abs(float(jerk) - 0.002 * 30.0) < 1e-6
    assert abs(float(cur[0, rd.FEAT_KEYS.index("cadence_hz")]) - 1.8) < 1e-6
    assert rd.feature_value({"jerk_rms": 0.002}, "jerk_rms_gps") == 0.002 * 30.0
    assert rd.feature_value({"jerk_rms_gps": 0.5, "jerk_rms": 0.002}, "jerk_rms_gps") == 0.5


def test_current_matrix_passes_current_keys_through():
    stored = np.asarray([[0.01, 0.2, 0.06, 1.8, 0.4, 3.0]], np.float32)
    cur = rd.current_feature_matrix(stored, rd.FEAT_KEYS)
    assert np.allclose(cur, stored)
