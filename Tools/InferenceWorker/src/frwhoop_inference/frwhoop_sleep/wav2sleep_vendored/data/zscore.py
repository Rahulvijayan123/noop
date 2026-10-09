# ---------------------------------------------------------------------------
# VENDORED FILE - do not edit by hand (regenerate with the vendoring script named in
# wav2sleep_vendored/PROVENANCE.md).
#
# Upstream        : https://github.com/joncarter1/wav2sleep
# Upstream path   : src/wav2sleep/data/dataset.py
# Pinned commit   : 278e30463c8149c4e6899b8784da492fec695bd9 (2026-07-16)
# Upstream sha256 : 026c6834a8ae80192a323e1caa85bbc354e16d96ee78ee836937f0c37d86f8ae
# License         : MIT, (c) 2026 Jonathan Carter - see wav2sleep_vendored/LICENSE
# Local edits     : EXTRACT - ParquetDataset._zscore_normalize (the non-causal normalization the
#                   public API uses: ParquetDataset(causal=False) is the default) as a module-level
#                   function. Body byte-identical after removing @staticmethod and one indent level.
#                   dataset.py itself is not vendored: it imports numba via data/normalization.py
#                   for the causal path, which the released non-causal checkpoint does not use.
#                   The exact unified diff is in wav2sleep_vendored/UPSTREAM_DIFF.json.
# ---------------------------------------------------------------------------
from typing import Dict

import torch
from torch import Tensor


def _zscore_normalize(signals: Dict[str, Tensor]) -> Dict[str, Tensor]:
    out: Dict[str, Tensor] = {}
    eps = 1e-6
    for k, x in signals.items():
        if x.numel() == 0 or not torch.isfinite(x).all():
            out[k] = x
            continue
        mu = torch.mean(x)
        std = torch.std(x)
        std = std if std > eps else torch.tensor(eps, dtype=x.dtype, device=x.device)
        out[k] = (x - mu) / std
    return out
