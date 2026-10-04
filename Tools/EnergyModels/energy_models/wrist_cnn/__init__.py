"""Numpy-only inference for the pretrained wrist-accelerometer CNN (Nawaratne et al. 2021).

Weights are not distributed with this repository: ``fetch.py`` (``scripts/fetch_wrist_cnn.sh``)
downloads them from the upstream repository at a pinned commit and verifies their sha256. See
``README.md`` for conventions, evidence and limits, and ``artifacts/wrist_cnn/NOTICE.md`` for
licence status. The network's labels are waist-ActiGraph estimates, not calorimetry: treat its
output as supporting evidence, not ground truth.

Importing this package pulls in numpy only. ``fetch`` (conversion, needs h5py), ``verify_keras``
(needs TensorFlow), ``evaluate``, ``ood_eval``, ``manifest`` and ``testing`` are build/verify-time
tools and are imported explicitly by whoever runs them.
"""

from .inputs import QUIET_MET_BASELINE, PreparedWindows, prepare_windows, quiet_mask
from .model import WristCNN, load_model, predict_met, predict_proba
from .ood import dominant_reason, ood_components, ood_signal
from .pins import PINNED_COMMIT, PINS

__all__ = [
    "PINNED_COMMIT",
    "PINS",
    "QUIET_MET_BASELINE",
    "PreparedWindows",
    "WristCNN",
    "dominant_reason",
    "load_model",
    "ood_components",
    "ood_signal",
    "predict_met",
    "predict_proba",
    "prepare_windows",
    "quiet_mask",
]
