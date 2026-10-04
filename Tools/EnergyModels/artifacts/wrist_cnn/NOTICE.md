# NOTICE: wrist CNN weights are fetched, not redistributed

This directory holds provenance only. `manifest.json` and this file are the only tracked
files here; `.gitignore` excludes everything else under `artifacts/`.

## What the model is

A pretrained 1-D CNN (two heads: energy-expenditure regression and three-class activity
intensity) for 60 s of raw wrist accelerometry, published by the authors of:

> Nawaratne R, Alahakoon D, De Silva D, O'Halloran PD, Montoye AHK, Staley K, Nicholson M,
> Kingsley MIC. Deep learning to predict energy expenditure and activity intensity in free
> living conditions using wrist-specific accelerometry. *Journal of Sports Sciences*
> 2021;39(6):683-690. doi:[10.1080/02640414.2020.1841394](https://doi.org/10.1080/02640414.2020.1841394)

Upstream code and weights: <https://github.com/razmik/cnn-wrist-model-freeliving>
(pinned commit `9ca77ea104074ad82c648ec75c3a48e2bd82deeb`, 2020-04-14).

## Licence status and what we do about it

The upstream repository ships **no licence**: the GitHub licence field is empty, there is no
`LICENSE`, `COPYING` or `NOTICE` file at the pinned commit, and the README states no terms of
reuse. Without a licence all rights stay with the authors. Therefore:

* the upstream weights (`*.h5`) and our float32 conversion of them (`*.npz`) are **never
  committed, copied into this repository, or redistributed**;
* `scripts/fetch_wrist_cnn.sh` downloads the two `.h5` files from the upstream repository at the
  pinned commit and accepts them only if their size and sha256 equal the values in
  `manifest.json` (a download that does not match is discarded and the run aborts with exit
  status 2, so nothing unverified is converted), converts them locally, and verifies the result
  against its own pinned sha256; the model loader re-verifies that digest on every load;
* the numpy forward pass in `energy_models/wrist_cnn/` is original code written against the
  published architecture; it contains no upstream source and no weights;
* `tests/fixtures/wrist_cnn_golden.npz` holds only synthetic input windows and twelve numbers
  (three MET values, nine class probabilities) produced by the reference network on them;
* the evaluation sample used for the reported numbers is also upstream data and is not copied
  here either: tests use synthetic signals, and the sample evaluation reads the user's own
  clone of the upstream repository.

Before shipping these weights inside any product, obtain written permission from the authors
(the repository owner, github.com/razmik, or the paper's corresponding author), or retrain the
model on data you are allowed to use.

## What the labels are

The training labels are **estimates computed from the activity counts of a waist-worn ActiGraph
accelerometer** (upstream's `ReferenceMethod.update_reference_ee` applies the Freedson VM3
Combination (11) equation, MET = 0.001092 x VA counts + 1.336129 below 2453 VM3 counts per
minute and 0.000863 x VM3 + 0.668876 above, and the data carry a matching intensity class). They
are **not indirect calorimetry**. The network therefore predicts what a waist accelerometer
algorithm would say, from the wrist signal. That is useful as **supporting evidence, not ground
truth**: do not present its output as measured energy cost, and expect its quiet-window floor
(about 1.40 on the MET-like scale, 1.336 in the labels) to differ from a calorimetric resting
value.

## Reproducing the artifacts

```
scripts/fetch_wrist_cnn.sh            # download, verify, convert, verify again (idempotent)
scripts/fetch_wrist_cnn.sh --check    # verify what is on disk; touches nothing
```

Conversion needs `h5py` (see `requirements-cnn-convert.txt`); inference needs only numpy.
