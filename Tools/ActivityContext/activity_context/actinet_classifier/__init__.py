"""activity_context.actinet_classifier — the full native ActiNet classifier, SHADOW ONLY (contract:
docs/pretrained-models/ACTINET_CLASSIFIER.md).

The complete upstream trained classifier, run without any training, fine-tuning or calibration. That is ActiNet's
``walmsley`` model ``ssl-ukb-c24-rw-30s-20260128``: the harnet30 ResNet and its 1024-512-K head, both fine-tuned
on Capture-24. Its documented temporal processing runs after it: the fitted HMM, uniform-prior Viterbi, and the
label after each time gap restored. The adapter gives sleep / sedentary / light / moderate-vigorous context for
non-overlapping 30 s epochs of WHOOP raw accelerometer. That context is HR-independent and is never canonical
sleep staging.

Upstream is University of Oxford software under its Academic Use Licence (actinet ``LICENSE.md``; "Copyright ©
2022, University of Oxford"). Nara's repository adds no Oxford code. The network reuses the harnet30 feature
extractor that the ActiNet encoder lane already vendors (``inertia/vendor/``); the head, preprocessing and HMM are
Nara's own code. The repository holds no weights and no HMM parameters: the operator fetches the upstream joblib by
sha256 and converts it offline (:mod:`.weights`). Licence scope (a service on other people's data) is an owner
decision (ACTINET_CLASSIFIER.md "Licence").

Modules
-------
weights    : pinned upstream source + converted-artifact manifest; fetch / convert (offline, needs ``actinet``) /
             verify CLI; size + sha256 verified before any byte is parsed; no unpickling at runtime.
preprocess : ``actinet-prep-1`` (WHOOP NPB1 -> g -> contiguous runs -> 30 s epochs -> 3000 samples -> linear
             resize to 900, upstream ``resize`` semantics; no filter, no calibration, no non-wear step).
model      : the frozen network (harnet30 feature extractor + the 1024-512-K head), strict load, fixed padded
             batches, CPU fp32, capped threads -> logits and softmax probabilities.
hmm        : upstream's temporal processing re-implemented in numpy (dtype-exact Viterbi, gap restore).
runtime    : load once; requests -> ``actinet-classifier-1`` responses; cache identity; resource bounds.
serve      : the stdin/stdout JSON-lines process (``python -m activity_context.actinet_classifier.serve``).

Everything in this module is a plain constant; importing it is free (no numpy/torch).
"""

from __future__ import annotations

from typing import Tuple

PREPROCESSING_VERSION = "actinet-prep-1"
TEMPORAL_VERSION = "actinet-hmm-1"            # upstream HMM.predict semantics (hmm.py)
WIRE_SCHEMA = "actinet-classifier-1"
HMM_SCHEMA = "nara.actinet.hmm/1"             # the converted HMM/labels file (weights.py)

# The one admitted identity (Spec 03; lead decision 2026-10-07): the Walmsley2020 intensity classifier. The
# Willetts2018 6-class model (``ssl-ukb-c24-mw-30s-20260128``, the backbone of the ActiNet encoder lane) is not
# wired here.
MODEL_ID = "actinet-walmsley"
MODEL_VERSION = "ssl-ukb-c24-rw-30s-20260128"
UPSTREAM_CLASSIFIER_KEY = "walmsley"          # actinet.__classifiers__ key (upstream's default --classifier)

UPSTREAM_REPO = "https://github.com/OxWearables/actinet"
UPSTREAM_VERSION = "0.7.2"
UPSTREAM_COMMIT = "58d134b8be0965b5611aa589bc07a926de68f575"   # tag v0.7.2 (= sdist _version.py full-revisionid)
UPSTREAM_NETWORK = "https://github.com/OxWearables/ssl-wearables@v1.0.0 hubconf.harnet30 (is_eva=True)"
UPSTREAM_LICENSE = "University of Oxford Academic Use Licence (actinet LICENSE.md)"
UPSTREAM_COPYRIGHT = "Copyright © 2022, University of Oxford"

# Release mode is fixed: nothing in this package can emit a stronger tier (Spec 01 "Release modes").
RELEASE_MODE = "shadow"
# The named downstream consumer (ACTINET_CLASSIFIER.md §7; wired after Spec 01 lands).
CONSUMER = "activity_intensity_shadow"

# Sampling contracts. Native: WHOOP NPB1 100 Hz accelerometer (i16, 1/4096 g, gravity kept). Model: 30 s epochs of
# 900 samples at 30 Hz, [B, 3, 900] float32, x/y/z in g, gravity kept, no normalisation.
SOURCE_HZ = 100
EPOCH_S = 30
EPOCH_SOURCE_SAMPLES = SOURCE_HZ * EPOCH_S    # 3000
MODEL_HZ = 30
MODEL_SAMPLES = MODEL_HZ * EPOCH_S            # 900
AXES: Tuple[str, ...] = ("ax", "ay", "az")
REQUIRED_CHANNELS: Tuple[str, ...] = AXES     # gyro is decoded (validated) by the shared decoder, then ignored

# Window grids (preprocess.py). ``run``: each contiguous run is cut from its own first sample, as upstream cuts a
# recording from its first sample (the served default). ``request``: one grid from the request start, as upstream
# cuts one file that starts at the request start (offline parity tool).
GRIDS: Tuple[str, ...] = ("run", "request")
DEFAULT_GRID = "run"

# Epoch validity reasons (an invalid epoch carries no probabilities and no label).
REASON_PARTIAL = "partial_window"             # the 30 s span is not fully covered by one contiguous run
REASON_NO_DATA = "no_data"                    # ``request`` grid: no sample at all in the span
REASONS: Tuple[str, ...] = (REASON_PARTIAL, REASON_NO_DATA)

ERROR_KINDS: Tuple[str, ...] = ("malformed", "model_missing", "weights_mismatch", "timeout", "internal",
                                "output_too_large", "too_many_epochs")

__all__ = [
    "PREPROCESSING_VERSION", "TEMPORAL_VERSION", "WIRE_SCHEMA", "HMM_SCHEMA", "MODEL_ID", "MODEL_VERSION",
    "UPSTREAM_CLASSIFIER_KEY", "UPSTREAM_REPO", "UPSTREAM_VERSION", "UPSTREAM_COMMIT", "UPSTREAM_NETWORK",
    "UPSTREAM_LICENSE", "UPSTREAM_COPYRIGHT", "RELEASE_MODE", "CONSUMER", "SOURCE_HZ", "EPOCH_S",
    "EPOCH_SOURCE_SAMPLES", "MODEL_HZ", "MODEL_SAMPLES", "AXES", "REQUIRED_CHANNELS", "GRIDS", "DEFAULT_GRID",
    "REASON_PARTIAL", "REASON_NO_DATA", "REASONS", "ERROR_KINDS",
]
