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
