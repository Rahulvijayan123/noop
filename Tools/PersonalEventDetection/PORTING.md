# Research code provenance

The candidate identities, input shortlist, small temporal architectures, sparse-group estimator and frozen encoder adapters were ported and adapted from the user's existing `forecasting-lab` research checkout: `event-matrix/benchmark.py`, `event-matrix/expand_benchmark.py`, `forecasting/models.py`, and `forecasting/encoders.py`. Production code has no dependency on that sibling directory, recordings, benchmark outputs, personal file paths or its dashboard server.

The MiniRocket multivariate implementation is vendored from the same benchmark's pinned `angus924/minirocket` source (commit `0b1c245d9c9dbc50886f28bc7b32d5d45b5663d6`). Its MIT licence is preserved in `personal_events/vendor/MINIROCKET_LICENSE`. Only the implementation module is included; benchmark data, weights and result files are excluded.

The other third-party model packages remain dependencies and retain their upstream licences. Pretrained source code and weights are not included. Maintainers must review their licensing and pin the exact files before enabling those candidates.

This implementation reproduces the candidate families, not the old benchmark's performance claims. In particular, the `stacking` candidate is the benchmark's fixed equal-weight ridge-branch score fusion, not a fitted meta-learner. The multiscale CNN is the small custom encoder, not the published InceptionTime ensemble. MiniRocket uses 504 features and training-only PCA. SVM output is a sigmoid-transformed margin, not a calibrated probability.
