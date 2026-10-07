"""activity_context.inertia — Inertia-1 motion heads (contract: Tools/ActivityContext/INERTIA1.md).

A separate, optional lane beside the HART path. Nothing here is imported by ``activity_context`` itself,
so the HART serve process never loads torch, scipy or this package.

Modules
-------
contract      : EncoderInfo / InputContract / Encoder protocol, typed errors (InertiaUnavailable).
preprocess    : ``inertia-prep-1`` (WHOOP NPB1 -> g -> 10 Hz Butterworth filtfilt -> 20 Hz -> windows),
                plus the public ``resample_to_20hz`` / ``segment_on_gaps`` helpers for dataset loaders.
vendor/       : narrowly vendored upstream Inertia-1 encoder code (ART, PatchTST; MIT, pinned SHA).
encoder_config: ``encoder.json`` (nara.inertia.encoder/1) presets, validation, module builder.
adapter       : Inertia1Encoder (verify-on-load, strict, frozen, CPU fp32) + test-checkpoint helper.
standins      : offline/shadow stand-in encoders (never Inertia-1).
registry      : build_encoder(spec) and PINNED_CHECKPOINTS (empty: no official checkpoint exists).
bundle        : the single serialization authority for head bundles (nara.inertia.heads/1).
bundle_math   : numpy-only head / calibration / OOD math used by HeadBundle.apply.
runtime/serve : the persistent ``motion-heads-1`` process (python -m activity_context.inertia.serve).
make_golden   : regenerates fixtures/inertia (end-to-end golden).
bench         : performance measurement CLI.

Everything in this module is a plain constant; importing it is free (no numpy/torch/scipy).
"""

from __future__ import annotations

from typing import Dict, Tuple

# ---------------------------------------------------------------------------
# Pinned identifiers (INERTIA1.md §2). Changing any of these is a contract change.
# ---------------------------------------------------------------------------

PREPROCESSING_VERSION = "inertia-prep-1"
WIRE_SCHEMA = "motion-heads-1"
ENCODER_CONFIG_SCHEMA = "nara.inertia.encoder/1"
HEADS_SCHEMA = "nara.inertia.heads/1"
CALIBRATION_SCHEMA = "nara.inertia.calibration/1"
OOD_SCHEMA = "nara.inertia.ood/1"
SPLIT_SCHEMA = "nara-split-1"
MAPPINGS_SCHEMA = "nara.inertia.mappings/1"

UPSTREAM_REPO = "https://github.com/yang-ai-lab/Inertia-1"
UPSTREAM_COMMIT = "afcd725314c95f4afefce118821349df7d61e7e8"
UPSTREAM_LICENSE = "MIT"
UPSTREAM_COPYRIGHT = "Copyright (c) 2026 The Inertia-1 Authors"

# Encoder id prefixes: real ids are ``inertia-1/<method>-<preset>/<window>s@20hz``; anything else must be a
# stand-in whose id starts with ``standin:``.
REAL_ENCODER_PREFIX = "inertia-1/"
STANDIN_PREFIX = "standin:"
# ActiNet / ssl-wearables harnet30 encoders (``actinet/<weights>/30s@20hz``, INERTIA1.md §4b): pinned weights,
# eligible for evidence like a pinned Inertia-1 checkpoint.
ACTINET_ENCODER_PREFIX = "actinet/"
PINNED_ENCODER_PREFIXES: Tuple[str, ...] = (REAL_ENCODER_PREFIX, ACTINET_ENCODER_PREFIX)

# Encoder input contract (INERTIA1.md §3/§4).
INERTIA_RATE_HZ = 20
INERTIA_AXES: Tuple[str, ...] = ("ax", "ay", "az")
ALLOWED_WINDOW_S: Tuple[int, ...] = (10, 30)
ALLOWED_HOP_S: Tuple[int, ...] = (1, 2, 5, 10, 15, 30)

# Evidence tiers, weakest first (INERTIA1.md §6/§8) — the wire vocabulary.
EVIDENCE_TIERS: Tuple[str, ...] = ("shadow", "candidate", "production")
# Bundle tiers: the wire tiers plus ``offline`` (a bundle built from a dirty source tree with --allow-dirty;
# offline research only — the serve process refuses it, it never reaches the wire).
BUNDLE_TIERS: Tuple[str, ...] = ("offline",) + EVIDENCE_TIERS
TEST_GATE_SCHEMA = "nara.inertia.test_gate/1"

# ---------------------------------------------------------------------------
# Head class orders (INERTIA1.md §5). Fixed; ``unknown`` is never a trained class — it is the
# abstention/OOD outcome. A bundle whose class order differs from this table is refused on load.
# ---------------------------------------------------------------------------

HEAD_CLASS_ORDERS: Dict[str, Tuple[str, ...]] = {
    "posture": ("recumbent", "seated_likely", "upright_stationary", "postural_transition"),
    "locomotion": ("stationary", "walking", "brisk_walking", "running", "stairs", "cycling",
                   "vehicle_motion", "other"),
    "arm_behavior": ("quiet", "desk_like", "fidgeting", "repetitive_hand_motion", "active_gesturing",
                     "exercise_motion", "other"),
    # Multi-label event head: one sigmoid per event, no trained ``none`` output.
    "transition": ("sit_to_stand_like", "stand_to_sit_like", "lying_down_like", "getting_up_like",
                   "walk_start", "walk_stop", "run_start", "run_stop"),
}
CLASSIFIER_HEADS: Tuple[str, ...] = tuple(HEAD_CLASS_ORDERS)
# Softmax heads sum to 1 over their supported classes; multi-label heads carry independent per-event
# probabilities (sigmoid(z_e / T_e)).
SOFTMAX_HEADS: Tuple[str, ...] = ("posture", "locomotion", "arm_behavior")
MULTILABEL_HEADS: Tuple[str, ...] = ("transition",)
REGRESSION_HEADS: Tuple[str, ...] = ("movement_intensity",)
ALL_HEADS: Tuple[str, ...] = CLASSIFIER_HEADS + REGRESSION_HEADS

__all__ = [
    "PREPROCESSING_VERSION", "WIRE_SCHEMA", "ENCODER_CONFIG_SCHEMA", "HEADS_SCHEMA", "CALIBRATION_SCHEMA",
    "OOD_SCHEMA", "SPLIT_SCHEMA", "MAPPINGS_SCHEMA", "UPSTREAM_REPO", "UPSTREAM_COMMIT", "UPSTREAM_LICENSE",
    "UPSTREAM_COPYRIGHT", "REAL_ENCODER_PREFIX", "STANDIN_PREFIX", "INERTIA_RATE_HZ", "INERTIA_AXES",
    "ALLOWED_WINDOW_S", "ALLOWED_HOP_S", "EVIDENCE_TIERS", "BUNDLE_TIERS", "TEST_GATE_SCHEMA", "HEAD_CLASS_ORDERS",
    "CLASSIFIER_HEADS",
    "SOFTMAX_HEADS", "MULTILABEL_HEADS", "REGRESSION_HEADS", "ALL_HEADS",
]
