# Provenance

The signature engine (sig-1) is new code written for this repository against
[docs/PHENOTYPE_SIGNATURES.md](../../docs/PHENOTYPE_SIGNATURES.md). It contains no vendored third-party source.

Reused from this repository:

- `policy.py` (`EpisodeState`, `Policy`), the job claim/lease/fence/heartbeat/retry adapter in `database.py`, and
  the lane, lease-heartbeat and account-cache cleanup structure of `worker.py` come from PR #5 (Hanson Wen).
- The minute timeline follows the anomaly service (`Tools/AnomalyService/src/frwhoop_anomaly/features.py`):
  strap sleep state 2 = asleep, the skin-temperature mapping (centidegrees, WHOOP 4.0 anchor rule), wrist
  ON/OFF events, the exertion/recovery bout rule, and the R-R cleaning rules of `rr.py` (transport pinning,
  suspect/duplicate/range/fill-value drops, Malik 20 % successive-difference rejection), re-implemented with
  numpy. That module is not imported.

PR #5's modelling core (window features, the 25 x 18 model registry, neural heads, frozen encoders, the
sparse-group estimator, MiniRocket and its GPL-3 licence file, argmax selection and gates) was removed, together
with the `matrix` extra (torch, xgboost, catboost, xlstm, numba, pycatch22). The remaining dependencies (numpy,
scipy, scikit-learn, psycopg) keep their upstream licences.
