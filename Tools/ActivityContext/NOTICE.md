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

Inertia-1 (yang-ai-lab/Inertia-1)
  https://github.com/yang-ai-lab/Inertia-1
  Pinned commit: afcd725314c95f4afefce118821349df7d61e7e8
  License: MIT, "Copyright (c) 2026 The Inertia-1 Authors" (full text below).
  Used for: the ART and PatchTST encoder architectures. Only what encode() needs is vendored, with
  identical module/attribute names so upstream Lightning state_dicts load strictly; no
  pytorch-lightning, no training code. Each vendored file carries the upstream path, the SHA and this
  notice. Vendored files (activity_context/inertia/vendor/) and their upstream sources:
    vendor/ar_transformer.py  <- inertia1/methods/ar_transformer_module.py
    vendor/patchtst.py        <- inertia1/methods/patchtst_module.py,
                                 inertia1/augmentations/patchtst.py,
                                 inertia1/models/backbones/patchtst/patchTST_accel.py,
                                 inertia1/models/backbones/patchtst/layers/attention.py,
                                 inertia1/models/backbones/patchtst/layers/basics.py,
                                 inertia1/models/backbones/patchtst/layers/pos_encoding.py
    vendor/__init__.py        (notice + file map only)
  Weights: no official pretrained checkpoint is publicly available (audited 2026-10-05); none is
  committed. fixtures/inertia/encoder_tiny.ckpt is a seeded random initialisation of the vendored
  architecture made by Nara for tests — it is not Inertia-1 and carries no upstream weights.

  MIT License

  Copyright (c) 2026 The Inertia-1 Authors

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

scipy / torch (optional [inertia] extra) and scikit-learn / pandas / pyarrow ([inertia-train])
  BSD-3-Clause / BSD-style / Apache-2.0 respectively; runtime dependencies only, not vendored.
