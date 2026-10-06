# Tools/ActivityContext — third-party notices

HART (EdgeIntelligenceLab/HART)
  Pinned commit: 122b4a8b07758deedfcf3b1e87f03eed5ad55967
  License: MIT (upstream LICENSE in the HART repository).
  Used for: the pretrained TSPulse checkpoint and the classification-adapter
  contract (TSPulseForClassification.from_pretrained + finetune.py overrides).
  Artifact: finetuning_HART/pretrained_checkpoint/* (downloaded by
  fetch_artifacts.sh with pinned sha256 digests; never committed).

WISDM Smartphone and Smartwatch Activity and Biometrics Dataset
  Weiss, G. (2019). UCI Machine Learning Repository.
  https://doi.org/10.24432/C5HK59 — License: CC BY 4.0.
  Used for: watch-stream adaptation training (20 Hz accel m/s^2 + gyro rad/s).
  Raw archive is a download-time artifact (310 MB, sha256 pinned in
  fetch_artifacts.py); derived windows/metrics keep this attribution.

granite-tsfm / tsfm_public (the TSPulseForClassification implementation)
  Apache-2.0 (see the granite-tsfm package). Runtime dependency of the
  optional [model] extra only. torch / transformers keep their own licenses.

FORTH-TRACE (Karagiannaki, Panousopoulou, Tsakalides)
  Zenodo record 841301, https://doi.org/10.5281/zenodo.841301 — License: CC BY-SA 4.0.
  Used for: wrist postural-transition supervision (sit_to_stand / stand_to_sit)
  of the transition expert (51.2 Hz Shimmer wrist accel+gyro).
  Raw archive is a download-time artifact (110.6 MB); attribution + share-alike
  obligations apply to the dataset and derived data (the trained model is this
  project's own artifact; only aggregate held-out metrics are committed).

HAPT — Smartphone-Based Recognition of Human Activities and Postural Transitions
  (Reyes-Ortiz, Anguita, Ghio, Oneto, Parra). UCI dataset 341,
  https://doi.org/10.24432/C54G7M — License: CC BY 4.0.
  Used for: cross-placement (waist) transfer supervision of all four transition
  classes (50 Hz accel g + gyro). Download-time artifact; derived metrics keep
  this attribution.

PAMAP2 (Reiss & Stricker)
  UCI dataset 231, https://doi.org/10.24432/C5NW2H — License: CC BY 4.0.
  Used for: wrist (hand-IMU) transition supervision derived from protocol state
  boundaries (100 Hz accel m/s^2 + gyro rad/s). Download-time artifact.

xgboost / scikit-learn (transition-expert build-time training only)
  Apache-2.0 / BSD-3-Clause. Build-time dependencies of
  activity_context.train_transition (never a runtime dep: exported artifacts are
  evaluated by numpy alone; see transition_model.py).
