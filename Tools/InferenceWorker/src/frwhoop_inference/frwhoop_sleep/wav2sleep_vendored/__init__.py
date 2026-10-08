"""Vendored minimal wav2sleep (MIT, (c) 2026 Jonathan Carter) - model code + reference preprocessing.

Pinned commit ``278e30463c8149c4e6899b8784da492fec695bd9`` of
https://github.com/joncarter1/wav2sleep. Every file except this one is generated from the pinned
clone by the vendoring script named in ``PROVENANCE.md``; ``UPSTREAM_DIFF.json`` records the
upstream and vendored sha256 and the exact diff of each file.

* ``settings.py``, ``models/{wav2sleep,blocks,utils}.py`` - verbatim (header added): the model.
* ``data/preprocessing.py`` - verbatim: the pinned resampling (reference oracle for tests).
* ``data/utils.py``         - extract: ``interpolate_index`` + the stage converters (no pyarrow).
* ``data/zscore.py``        - extract: ``ParquetDataset._zscore_normalize`` (the production
  normalization).

Not vendored: the hydra/omegaconf loader (``api.py``), the Hugging Face downloader, the causal
numba normalization, the EDF reader and all training code. Importing this package imports
nothing heavy; the model modules import torch, ``data/*`` import pandas.
"""
