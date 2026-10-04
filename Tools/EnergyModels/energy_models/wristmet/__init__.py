"""WristMET: wrist-IMU MET estimator retrained from public code and data (numpy-only inference).

Quick start::

    from energy_models.wristmet import WristMetModel
    model = WristMetModel.load("artifacts/wristmet/wristmet-v1.json.gz")
    result = model.predict_windows(windows, age=35, sex="female", weight_kg=70, height_cm=165)

``windows`` is ``[n, 1200, 6]`` (60 s at 20 Hz; gyr_xyz then acc_xyz; acc in m/s^2 with gravity, gyr in
rad/s). Read ``model.py`` and ``preprocess.py`` for the limitations before using the output.
The ``pipeline`` subpackage (training, evaluation, export) needs pandas / scikit-learn / xgboost and is
not imported here.
"""

from .features import (
    CHANNELS,
    CLASSIFIER_FEATURE_NAMES,
    REGRESSOR_FEATURE_NAMES,
    classifier_features,
    regression_intensity_features,
    regressor_features,
)
from .model import WristMetModel, WristMetResult
from .preprocess import (
    AxisMap,
    RawWindows,
    mirror_to_right_wrist,
    resample_linear,
    to_dataset_units,
    windows_from_raw,
)

__all__ = [
    "AxisMap",
    "CHANNELS",
    "CLASSIFIER_FEATURE_NAMES",
    "REGRESSOR_FEATURE_NAMES",
    "RawWindows",
    "WristMetModel",
    "WristMetResult",
    "classifier_features",
    "mirror_to_right_wrist",
    "regression_intensity_features",
    "regressor_features",
    "resample_linear",
    "to_dataset_units",
    "windows_from_raw",
]
