"""activity_context.recgym — RecGym gym-exercise recognition, SHADOW only (contract: Tools/ActivityContext/RECGYM.md).

A separate, optional expert beside HART, Inertia and ElderNet: the public pretrained CNN + Transformer of
``MKorp7/HAR_IMU_CNN-Transformer`` (MIT, "Copyright (c) 2025 MKorp7"), the wrist IMU-only checkpoint
``models.zip:models/wrist_-_imu_only_best.pt``, trained on RecGym (Bian, Rey, Yuan, Lukowicz; CC BY 4.0) wrist
windows of subjects 1-7. Twelve classes: eleven gym workouts plus ``Null`` (between exercises).

The architecture is vendored (``vendor/imu_transformer.py``, identical module and attribute names, so the upstream
state dict loads strictly). The checkpoint is never committed: the operator stages it by sha256 (the sidecar model
manifest, ``deploy/provision.sh``) or with ``python -m activity_context.recgym.weights fetch``. The StandardScaler
upstream fitted on the training windows was not shipped; ``recgym_wrist_imu_scaler.json`` is its exact
reproduction from the public dataset (``reproduce.py``; provenance inside the file).

The model was trained on a wrist. The owner wears the strap on the upper arm, so every output row records the
placement and whether it is one the model supports; nothing here shapes a canonical value.

Modules
-------
vendor/     : upstream IMUCNNTransformer (inference) and upstream RecGym windowing (reproduction only).
weights     : pinned checkpoint (models.zip at the pinned commit -> member), resolve / verify / fetch CLI.
scaler      : the reproduced per-(time step, channel) StandardScaler, loaded and verified.
preprocess  : ``recgym-prep-1`` (WHOOP NPB1 -> g, deg/s -> gravity-free m/s^2 -> 20 Hz -> RecGym units -> 4 s).
model       : the checkpoint loaded strictly (eval, inference_mode, CPU, fixed batch) -> logits.
runtime     : load once, turn requests into ``exercise-windows-1`` responses; serve: the stdin/stdout process.
reproduce   : offline: refit the scaler and recompute the upstream test accuracy from RecGym.csv.

Everything in this module is a plain constant; importing it is free (no numpy/torch).
"""

from __future__ import annotations

from typing import Tuple

WIRE_SCHEMA = "exercise-windows-1"
MODEL_ID = "recgym-cnn-transformer"
PREPROCESSING_VERSION = "recgym-prep-1"

UPSTREAM_REPO = "https://github.com/MKorp7/HAR_IMU_CNN-Transformer"
UPSTREAM_COMMIT = "e085ac0e116aa5997d5f593ac1d0dd0c801859b1"
UPSTREAM_LICENSE = "MIT"
UPSTREAM_COPYRIGHT = "Copyright (c) 2025 MKorp7"
MODEL_VERSION = "recgym-cnn-transformer-" + UPSTREAM_COMMIT[:7]

# Upstream label encoding: sorted(df["Workout"].unique()) on RecGym.csv (scripts/run_recgym.py step 3; the
# notebook's printed activity2id). The dataset spells the stair machine "StairClimber".
CLASSES: Tuple[str, ...] = ("Adductor", "ArmCurl", "BenchPress", "LegCurl", "LegPress", "Null", "Riding",
                            "RopeSkipping", "Running", "Squat", "StairClimber", "Walking")
NULL_CLASS = "Null"
NULL_INDEX = CLASSES.index(NULL_CLASS)
# Machine / free-weight strength classes (the rest are cardio: Riding, RopeSkipping, Running, StairClimber, Walking).
STRENGTH_CLASSES: Tuple[str, ...] = ("Adductor", "ArmCurl", "BenchPress", "LegCurl", "LegPress", "Squat")

# The model's training placement. Anything else is outside its distribution (`placement_supported` false).
TRAINED_PLACEMENT = "wrist"

# Architecture-fixed input (upstream create_windows: fs 20, window 4 s, step 2 s; IMU_IDX = A_x..G_z).
RATE_HZ = 20
WINDOW_S = 4
HOP_S = 2
WINDOW_SAMPLES = RATE_HZ * WINDOW_S            # 80
HOP_SAMPLES = RATE_HZ * HOP_S                  # 40
CHANNELS: Tuple[str, ...] = ("A_x", "A_y", "A_z", "G_x", "G_y", "G_z")
IN_CHANNELS = len(CHANNELS)

# RecGym's released units (measured from the data, RECGYM.md §2): accelerometer = gravity-free linear acceleration,
# clip(0.5 + a / 80, 0, 1) with a in m/s^2 (±40 m/s^2 full scale, 0.01 m/s^2 steps); gyroscope =
# clip(0.5 + w / 1600, 0, 1) with w in deg/s (±800 deg/s full scale, 1/16 deg/s steps rounded to 0.01).
ACCEL_FULL_SCALE_MS2 = 40.0
GYRO_FULL_SCALE_DPS = 800.0
STANDARD_GRAVITY = 9.80665

SCALER_FILE = "recgym_wrist_imu_scaler.json"
SCALER_VERSION = "recgym-wrist-imu-scaler-1"

ERROR_KINDS: Tuple[str, ...] = ("malformed", "model_missing", "weights_mismatch", "timeout", "internal",
                                "output_too_large")

__all__ = [
    "WIRE_SCHEMA", "MODEL_ID", "PREPROCESSING_VERSION", "UPSTREAM_REPO", "UPSTREAM_COMMIT", "UPSTREAM_LICENSE",
    "UPSTREAM_COPYRIGHT", "MODEL_VERSION", "CLASSES", "NULL_CLASS", "NULL_INDEX", "STRENGTH_CLASSES",
    "TRAINED_PLACEMENT", "RATE_HZ", "WINDOW_S", "HOP_S", "WINDOW_SAMPLES", "HOP_SAMPLES", "CHANNELS", "IN_CHANNELS",
    "ACCEL_FULL_SCALE_MS2", "GYRO_FULL_SCALE_DPS", "STANDARD_GRAVITY", "SCALER_FILE", "SCALER_VERSION",
    "ERROR_KINDS",
]
