"""Rotation machinery for the WHOOP -> ParaDigMa axis mapping (W3)."""

from __future__ import annotations

import numpy as np
import pytest

from frwhoop_inference.sensor_biomarkers.paradigma.axes import (
    PARADIGMA_FRAME,
    WHOOP5_AXIS_CONVENTION_VERIFIED,
    WHOOP5_AXIS_EVIDENCE,
    WHOOP5_TO_PARADIGMA,
    WHOOP5_TO_PARADIGMA_SPEC,
    apply_rotation,
    build_rotation,
    rotation_can_enable_arm_swing,
    validate_rotation,
)


def test_builtin_rotation_is_a_proper_rotation():
    """The shipped WHOOP->ParaDigMa mapping must be orthonormal, det +1."""
    validate_rotation(WHOOP5_TO_PARADIGMA)
    product = WHOOP5_TO_PARADIGMA.T @ WHOOP5_TO_PARADIGMA
    assert np.allclose(product, np.eye(3), atol=1e-12)
    assert np.isclose(np.linalg.det(WHOOP5_TO_PARADIGMA), 1.0)


def test_rotation_validation_rejects_reflection():
    """A mirror (det -1) is NOT a signed rotation; it must be refused."""
    reflection = np.array([[1.0, 0, 0], [0, -1.0, 0], [0, 0, 1.0]])
    with pytest.raises(ValueError, match="determinant"):
        validate_rotation(reflection)


def test_rotation_validation_rejects_non_orthonormal():
    with pytest.raises(ValueError, match="orthonormal"):
        validate_rotation(np.array([[1.0, 0.1, 0], [0, 1, 0], [0, 0, 1]]))


def test_build_rotation_spec_roundtrip():
    """A signed permutation spec round-trips to the expected matrix."""
    spec = ["y", "-x", "z"]
    rot = build_rotation(spec)
    validate_rotation(rot)
    # target x = source y, target y = -source x, target z = source z
    x = np.array([0.0, 1.0, 0.0])
    y = np.array([-1.0, 0.0, 0.0])
    z = np.array([0.0, 0.0, 1.0])
    assert np.allclose(rot @ np.eye(3), np.stack([x, y, z]))


def test_build_rotation_rejects_bad_specs():
    with pytest.raises(ValueError):
        build_rotation(["x", "y"])
    with pytest.raises(ValueError):
        build_rotation(["x", "q", "z"])
    with pytest.raises(ValueError):
        build_rotation(["x", "y", "z", "x"])


def test_apply_rotation_same_matrix_for_accel_and_gyro():
    """The SAME rotation must be applied to accelerometer and gyroscope."""
    rng = np.random.default_rng(11)
    accel = rng.normal(0, 1, (50, 3))
    gyro = rng.normal(0, 1, (50, 3))
    spec = ["y", "-x", "z"]
    rot = build_rotation(spec)
    accel_rot = apply_rotation(accel, rot)
    gyro_rot = apply_rotation(gyro, rot)
    # Same transformation: rotation of a linear operator is exact.
    assert np.allclose(accel_rot, accel @ rot.T)
    assert np.allclose(gyro_rot, gyro @ rot.T)


def test_apply_rotation_preserves_norm():
    rng = np.random.default_rng(12)
    samples = rng.normal(0, 1, (20, 3))
    rot = build_rotation(["z", "-y", "x"])
    out = apply_rotation(samples, rot)
    assert np.allclose(np.linalg.norm(out, axis=1), np.linalg.norm(samples, axis=1))


def test_axis_convention_fail_closed_gate():
    """arm_swing must not enable until the WHOOP axis convention is verified."""
    assert rotation_can_enable_arm_swing() is False
    assert WHOOP5_AXIS_CONVENTION_VERIFIED is False
    assert "unknown_orientation" in WHOOP5_AXIS_EVIDENCE
    # The frame is the documented ParaDigMa training frame.
    assert set(PARADIGMA_FRAME) == {"x", "y", "z"}
    assert "hand" in PARADIGMA_FRAME["x"] and "arm" in PARADIGMA_FRAME["x"]
