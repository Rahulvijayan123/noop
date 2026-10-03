"""activity_context — offline Nara activity-context pipeline.

Modules
-------
preprocess   : WHOOP/NPB1 raw-IMU decode -> float tensor, 100->30 Hz numpy
               polyphase anti-alias resample, windowing, rejection.
baseline     : conservative heuristic classifier (operational baseline, spec 7).
model        : optional HART (TSPulseForClassification) adapter, lazy import.
manifest     : model manifest load/validate (checkpoint digest, scaler, class
               map, thresholds, units, window/hop, label mapping).
serve        : persistent process, line-delimited JSON stdin/stdout (C10).
infer/train/evaluate : CLI entry points.
"""

__version__ = "0.1.0"

# Canonical preprocessing identity reported in every response/manifest.
PREPROCESSING_VERSION = "1.0.0"
