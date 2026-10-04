# NOTICE - wristmet-v1

`wristmet-v1.json.gz` is a **model retrained by this project** from the public code and public data of the
WristMET study. It is **not** the authors' pretrained model, it does not reproduce the accuracy reported in the
paper (see `manifest.json`, `loso`), and it is not endorsed by the authors or by the HABits Lab.

## Sources

1. Paper: Wei B, Romano C, Pedram M, Nolan B, Morelli WA, Alshurafa N. *Developing and comparing a new BMI
   inclusive energy expenditure algorithm on wrist-worn wearables.* Scientific Reports 15 (2025).
   https://doi.org/10.1038/s41598-025-99963-0 (please cite it when using this model).
2. Code: https://github.com/HAbitsLab/WristBased-EE-Estimation, commit
   `3d3517cb95ef490d5e867ebf6a7207b8f7278788`, MIT licence. The feature definitions, window rules and
   hyper-parameters were re-implemented from it (`energy_models/wristmet/features.py`), and short literal
   excerpts are kept for verification in `energy_models/wristmet/pipeline/upstream_reference.py`.
3. Data: Wei B, Romano C, Pedram M, Nolan B, Morelli W, Alshurafa N. *Wrist-Based Energy Expenditure Estimation
   In-lab Dataset*, Zenodo, record 14858226, https://doi.org/10.5281/zenodo.14858226, licensed
   **CC BY 4.0** (https://creativecommons.org/licenses/by/4.0/). File `Phase 2 - Data.zip`, md5
   `1840803700111c0a1871e9af3eacc9be`.
   Changes made: the recordings were re-windowed (60 s), summarised into statistical features, and used to fit
   the model parameters in the artifact. The artifact contains no raw recordings; it stores tree parameters and
   summary statistics (feature ranges, gravity-direction unit vectors of the training windows, age/BMI ranges of
   the 26 participants). `tests/fixtures/wristmet_golden.json` contains six 60 s windows from that dataset
   (rounded to 3 decimals) as a numerical regression fixture.
4. Left-handed mirroring follows Kyritsis et al., arXiv:2010.07051, Eq. 1.

## MIT licence of the upstream code

MIT License

Copyright (c) 2025 The HABits Lab

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

## Build-time libraries (not redistributed)

numpy (BSD-3-Clause), pandas (BSD-3-Clause), scikit-learn (BSD-3-Clause), xgboost (Apache-2.0), scipy
(BSD-3-Clause), openpyxl (MIT). Exact versions: `requirements-wristmet-build.txt` and `manifest.json`.
Inference needs numpy only.

## Intended use and warnings

Research / experimentation. Not a medical device; the estimate is coarse (see `manifest.json`, `limitations`).
