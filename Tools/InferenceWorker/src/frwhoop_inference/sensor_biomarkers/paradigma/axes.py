"""WHOOP -> ParaDigMa sensor-axis mapping (verified signed rotation).

ParaDigMa's classifiers were trained in ONE documented coordinate frame
(``docs/guides/coordinate_system.md`` at the pinned commit):

    x-axis  aligned with the arm, pointing toward the hand,
    y-axis  perpendicular to the arm, pointing upward from the top of the sensor,
    z-axis  pointing away from the arm and body,

with gyroscope signs following the right-hand grip rule about the
accelerometer axes. For the gait/arm-swing pipeline the raw device axes must
be mapped into that frame by a proper rotation before classification;
tremor is coordinate-invariant and is NOT gated on this mapping (upstream
docs, ``coordinate_system.md``).

Design rules (spec section 6.3, enforced by tests):

* the mapping is a SINGLE signed rotation matrix applied identically to the
  accelerometer and the gyroscope (the same physical rotation);
* the matrix must be orthonormal with determinant +1 (a proper rotation,
  never a reflection) - ``validate_rotation`` enforces this;
* ParaDigMa's own right-wrist handling (``util.invert_watch_side``) is
  applied by the library INSIDE ``run_paradigma`` from ``watch_side``; we
  never pre-invert for the right wrist ourselves, so the right-side
  transform is never applied twice;
* unknown wrist placement / device orientation withholds ARM SWING only;
  tremor keeps running.

WHOOP 5 / MG axis convention
----------------------------
The WHOOP 5/MG raw 6-axis buffer (``Whoop5RawImu.swift``) carries
``ax, ay, az`` and ``gx, gy, gz`` at 100 Hz, but WHOOP publishes NO
documentation of the physical meaning of these axes, and no community
reverse-engineering source records a verified axis convention either
(checked 2026-10-06: Asherlc/dofek whoop-ble-protocol.md, b-nnett/goose,
judes.club). Until a WHOOP axis convention is established from annotated
captures, ``WHOOP5_AXIS_CONVENTION_VERIFIED`` stays False and the arm-swing
family is withheld with ``unknown_orientation`` (fail-closed). The rotation
machinery below is complete, validated and testable so that when a mapping
is evidenced the constant can be updated in one place and the gate lifts.
"""

from __future__ import annotations

import numpy as np

#: ParaDigMa's documented training frame (upstream docs/guides/coordinate_system.md).
PARADIGMA_FRAME = {
    "x": "along arm toward hand",
    "y": "perpendicular to arm, upward from the top of the sensor",
    "z": "away from the arm and body",
}

#: Whether a WHOOP 5/MG axis convention has been established and the
#: WHOOP5_TO_PARADIGMA rotation below is a VERIFIED mapping. Currently False:
#: WHOOP publishes no axis documentation and no annotated WHOOP capture is
#: available to pin the mapping (remaining portability gate, spec section 2).
WHOOP5_AXIS_CONVENTION_VERIFIED = False

#: Evidence note attached to the arm-swing gate; surfaces in capability/readiness.
WHOOP5_AXIS_EVIDENCE = (
    "WHOOP publishes no raw-IMU axis convention; no community source records a "
    "verified WHOOP 5/MG axis mapping and no annotated WHOOP capture is available. "
    "arm_swing is withheld with unknown_orientation until the mapping is evidenced "
    "from real captures (spec section 2 portability gate)."
)

#: WHOOP 5/MG device axes, in the order the decoder emits them.
WHOOP5_DEVICE_AXES = ("x", "y", "z")

#: Candidate WHOOP 5 -> ParaDigMa mapping. The identity matrix is the
#: NULL hypothesis: it is orthonormal with determinant +1 but its physical
#: meaning is UNVERIFIED, so it must not be used to enable arm_swing until
#: WHOOP5_AXIS_CONVENTION_VERIFIED is True. Expressed as a row-per-target-axis
#: permutation+signed list so the intended physical mapping is readable:
#: ``["x", "y", "z"]`` means ParaDigMa x = WHOOP x, ParaDigMa y = WHOOP y,
#: ParaDigMa z = WHOOP z.
WHOOP5_TO_PARADIGMA_SPEC: list[str] = ["x", "y", "z"]

#: The same mapping as a 3x3 proper rotation (built and validated below).
WHOOP5_TO_PARADIGMA: np.ndarray = np.eye(3)


def build_rotation(spec: list[str]) -> np.ndarray:
    """Build the 3x3 rotation matrix from a ``["axis", "-axis", ...]`` spec.

    The spec lists, for each TARGET (ParaDigMa) axis in x/y/z order, the
    SOURCE (WHOOP) axis and an optional leading ``-`` sign. This is the same
    spelling the upstream ``device_orientation`` parameter uses, which keeps
    the mapping auditable against ``docs/guides/coordinate_system.md``.
    """
    valid = {"x": 0, "y": 1, "z": 2}
    if len(spec) != 3:
        raise ValueError("rotation spec must have exactly 3 entries (one per target axis)")
    rows: list[list[float]] = []
    for entry in spec:
        if not isinstance(entry, str) or not entry:
            raise ValueError(f"invalid rotation axis {entry!r}")
        sign = -1.0 if entry.startswith("-") else 1.0
        axis = entry[1:] if entry.startswith("-") else entry
        if axis not in valid:
            raise ValueError(f"invalid rotation axis {entry!r}: must be one of x/y/z")
        row = [0.0, 0.0, 0.0]
        row[valid[axis]] = sign
        rows.append(row)
    return np.asarray(rows, dtype=np.float64)


def validate_rotation(rotation: np.ndarray, *, atol: float = 1e-9) -> None:
    """Assert that ``rotation`` is a proper rotation.

    Checks shape, orthonormality (``R.T @ R == I``) and determinant +1.
    Raises ``ValueError`` on any violation; returns None on success. This is
    the "verified signed rotation" gate the adapter depends on.
    """
    rotation = np.asarray(rotation, dtype=np.float64)
    if rotation.shape != (3, 3):
        raise ValueError(f"rotation must be 3x3, got {rotation.shape}")
    if not np.all(np.isfinite(rotation)):
        raise ValueError("rotation contains non-finite values")
    product = rotation.T @ rotation
    if not np.allclose(product, np.eye(3), atol=atol, rtol=0):
        raise ValueError(
            "rotation is not orthonormal (R.T @ R differs from I by "
            f"max {np.max(np.abs(product - np.eye(3))):.3e})"
        )
    det = np.linalg.det(rotation)
    if not np.isclose(det, 1.0, atol=atol, rtol=0):
        raise ValueError(f"rotation has determinant {det:.6f}, expected +1 (proper rotation)")


#: Build the default mapping once at import time so every consumer sees a
#: validated matrix.
WHOOP5_TO_PARADIGMA = build_rotation(WHOOP5_TO_PARADIGMA_SPEC)
validate_rotation(WHOOP5_TO_PARADIGMA)


def apply_rotation(
    samples: np.ndarray, rotation: np.ndarray | None = None
) -> np.ndarray:
    """Apply one signed rotation to a (N, 3) sample array.

    ``rotation=None`` uses the (currently unverified) WHOOP5_TO_PARADIGMA
    mapping. The SAME matrix is meant for both accelerometer and gyroscope
    columns - callers pass the same ``rotation`` for both sensors.
    """
    rotation = WHOOP5_TO_PARADIGMA if rotation is None else np.asarray(rotation, dtype=np.float64)
    validate_rotation(rotation)
    samples = np.asarray(samples, dtype=np.float64)
    if samples.ndim != 2 or samples.shape[1] != 3:
        raise ValueError(f"samples must be (N, 3), got {samples.shape}")
    return samples @ rotation.T


def rotation_can_enable_arm_swing() -> bool:
    """True only when the WHOOP axis convention is verified.

    Fail-closed gate: the (orthonormal) identity null-hypothesis must not
    silently enable gait analysis on unverified axes.
    """
    return WHOOP5_AXIS_CONVENTION_VERIFIED
