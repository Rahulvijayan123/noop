"""activity_context.eldernet — ElderNet gait quality (contract: Tools/ActivityContext/ELDERNET.md).

A separate, optional expert beside HART and Inertia: real public fine-tuned weights from
``yonbrand/gait-quality`` (Brand et al., npj Digital Medicine 2026), University of Oxford Academic Use
Licence ("Copyright © 2022, University of Oxford"). Nothing here is imported by ``activity_context`` itself,
so the HART serve process never loads torch or this package.

Modules
-------
weights    : pinned weight manifest (name -> upstream path, sha256, size), resolve / verify / fetch CLI.
vendor/    : narrowly vendored ElderNet model definitions (Oxford licence header, upstream path + SHA).
model      : the six heads loaded strictly (eval, inference_mode, CPU, fixed threads, batched).
preprocess : ``eldernet-prep-1`` (WHOOP NPB1 -> g -> nearest-neighbour 30 Hz per run -> 10 s windows).
gait       : window-local static pre-filter + detector -> gait_prob / is_gait; quality heads on gait only.
runtime    : load once, turn requests into ``gait-quality-1`` responses; serve: the stdin/stdout process.
run        : offline CLI over an [N, 3] g array (upstream-style windows/bouts/summary CSVs; ``--upstream``).
validate   : frozen-split validation (VAL-only calibration, TEST once through a ledger).

Everything in this module is a plain constant; importing it is free (no numpy/torch).
"""

from __future__ import annotations

from typing import Dict, Tuple

PREPROCESSING_VERSION = "eldernet-prep-1"
WIRE_SCHEMA = "gait-quality-1"
MODEL_ID = "eldernet"

UPSTREAM_REPO = "https://github.com/yonbrand/gait-quality"
UPSTREAM_COMMIT = "437a38bcc69f42717fe73c1f7dbea7e1f7a50d23"
MODEL_VERSION = "eldernet-" + UPSTREAM_COMMIT[:7]
UPSTREAM_LICENSE = "University of Oxford SSL-wearables Academic Use Licence"
UPSTREAM_COPYRIGHT = "Copyright © 2022, University of Oxford"

# Architecture-fixed input (upstream pipelines/config.yaml: resampled_hz 30, window_sec 10).
RATE_HZ = 30
WINDOW_S = 10
WINDOW_SAMPLES = RATE_HZ * WINDOW_S            # 300
UPSTREAM_HOP_S = 1                             # window_sec 10 - window_overlap_sec 9
DEFAULT_HOP_S = 5                              # served default (ELDERNET.md §2.4); 1 = upstream stride
ALLOWED_HOP_S: Tuple[int, ...] = (1, 2, 5, 10)
AXES: Tuple[str, ...] = ("ax", "ay", "az")

# Upstream gait_quality/detection.py:46 STATIC_VARIANCE_CEILING (= actipy stationary std tolerance 0.013 g).
STATIC_VARIANCE_CEILING = 0.013 ** 2
DEFAULT_GAIT_THRESHOLD = 0.5                   # upstream argmax over the two logits

# Head name (upstream config key) -> (wire key, max_mu, num_layers_regressor, batch_norm). Detection first.
DETECTION_HEAD = "gait_detection"
QUALITY_HEADS: Dict[str, Tuple[str, float, int, bool]] = {
    "gait_speed": ("speed_mps", 2.0, 0, False),
    "cadence": ("cadence_spm", 150.0, 1, True),
    "gait_length": ("stride_m", 2.0, 1, True),
    "regularity": ("regularity", 1.0, 1, False),
    "step_count": ("steps", 25.0, 1, True),
}
HEAD_NAMES: Tuple[str, ...] = (DETECTION_HEAD,) + tuple(QUALITY_HEADS)
FEATURE_VECTOR_SIZE = 128

ERROR_KINDS: Tuple[str, ...] = ("malformed", "model_missing", "weights_mismatch", "timeout", "internal",
                                "output_too_large")

__all__ = [
    "PREPROCESSING_VERSION", "WIRE_SCHEMA", "MODEL_ID", "UPSTREAM_REPO", "UPSTREAM_COMMIT", "MODEL_VERSION",
    "UPSTREAM_LICENSE", "UPSTREAM_COPYRIGHT", "RATE_HZ", "WINDOW_S", "WINDOW_SAMPLES", "UPSTREAM_HOP_S",
    "DEFAULT_HOP_S", "ALLOWED_HOP_S", "AXES", "STATIC_VARIANCE_CEILING", "DEFAULT_GAIT_THRESHOLD",
    "DETECTION_HEAD", "QUALITY_HEADS", "HEAD_NAMES", "FEATURE_VECTOR_SIZE", "ERROR_KINDS",
]
