"""ActiNet's temporal processing ``actinet-hmm-1``, re-implemented in numpy (ACTINET_CLASSIFIER.md §4).

Upstream path: actinet 0.7.2 ``ActivityClassifier.predict`` -> ``hmm.HMM.predict``. It is reproduced here from its
documented behaviour; no upstream code is copied.

1. **Observations.** One observation per VALID 30 s epoch: the network's argmax class index. Epochs with any
   missing sample never enter the sequence.
2. **Viterbi.** A single Viterbi pass runs over ALL valid epochs of the input in time order, as if they were
   consecutive.
   - Initial score: ``log(prior + 1e-16) + log(emission[:, y0] + 1e-16)``.
   - Recursion: ``v_j[i] = max_k (log(emission[i, y_j] + 1e-16) + log(transition[k, i] + 1e-16)) + v_{j-1}[k]``.
   - Backtrack: ``s_j = argmax_k log(transition[k, s_{j+1}] + 1e-16) + v_j[k]``; ties go to the first maximum.
   - ``prior`` is uniform because the released artifact has ``uniform_prior=True``. The fitted prior is carried
     in the artifact but not used.
3. **Gap restore.** Unless ``ignore_transition_gaps`` is set, an epoch whose start is not exactly one epoch (30 s)
   after the previous valid epoch's start gets its raw observation back. The first epoch never does. The Viterbi
   pass itself is not cut at gaps (step 2), so epochs before a gap are smoothed with evidence from after it. On
   duty-cycled input most epochs follow a gap, so the smoothed label is mostly the raw one; the response marks
   those epochs (``after_gap``).
4. **Sleep correction.** ``removeSpuriousSleep`` does nothing in upstream's default path: ``--require-sleep-above``
   is None and ``--single-sleep-block`` is off. It is not applied here.

**Dtypes.** These follow upstream under its pinned numpy 1.24 exactly, so tie-breaking matches bit for bit:

- ``emission`` is the artifact's float32 matrix.
- The initial step takes ``log`` of a float32 *column*. That is float32 arithmetic, as numpy does for an array plus
  a Python float.
- Each later step takes ``log`` of a float32 *scalar*. numpy 1.x promotes it to float64; NEP 50 would not, so the
  promotion is written out.
- ``prior`` and ``transition`` are float64.
- The arithmetic order is upstream's ``(emission + transition) + previous``.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Tuple

import numpy as np

_EPS = 1e-16


@dataclass(frozen=True)
class HMMParams:
    """Fitted upstream HMM. ``emission[i, c]``: mean probability of observing class ``c`` in true state ``i``;
    ``transition[k, i]``: probability of state ``k`` -> ``i`` between consecutive epochs. ``labels`` are the
    observation/state values (``0..K-1`` in the released artifact: indices into the class order)."""
    labels: np.ndarray
    prior: np.ndarray
    emission: np.ndarray
    transition: np.ndarray
    uniform_prior: bool = True
    ignore_transition_gaps: bool = False

    def __post_init__(self):
        k = int(np.asarray(self.labels).shape[0]) if np.asarray(self.labels).ndim == 1 else -1
        checks = (
            (k >= 2, "labels must be a 1-D array of >= 2 values"),
            (np.asarray(self.prior).shape == (k,), "prior must be [K]"),
            (np.asarray(self.emission).shape == (k, k), "emission must be [K, K]"),
            (np.asarray(self.transition).shape == (k, k), "transition must be [K, K]"),
        )
        for ok, msg in checks:
            if not ok:
                raise ValueError(msg)
        for name in ("prior", "emission", "transition"):
            a = np.asarray(getattr(self, name), dtype=np.float64)
            if not np.isfinite(a).all() or (a < 0).any():
                raise ValueError(f"{name} must be finite and non-negative")
        if len(set(np.asarray(self.labels).tolist())) != k:
            raise ValueError("labels must be unique")

    @property
    def n_states(self) -> int:
        return int(self.labels.shape[0])


def _positions(obs: np.ndarray, labels: np.ndarray) -> np.ndarray:
    """Observation values -> state positions (upstream maps through ``labels``); unknown values are refused."""
    lut = {int(v): i for i, v in enumerate(np.asarray(labels).tolist())}
    try:
        return np.fromiter((lut[int(v)] for v in obs), dtype=np.int64, count=obs.shape[0])
    except KeyError as exc:
        raise ValueError(f"observation {exc.args[0]!r} is not an HMM label") from None


def viterbi(obs: np.ndarray, p: HMMParams) -> np.ndarray:
    """Most likely state sequence for ``obs`` (label values), returned as label values. Empty in, empty out."""
    obs = np.asarray(obs)
    labels = np.asarray(p.labels)
    if obs.ndim != 1:
        raise ValueError("observations must be 1-D")
    n, k = obs.shape[0], p.n_states
    if n == 0:
        return labels[:0].copy()
    pos = _positions(obs, labels)
    e32 = np.asarray(p.emission, dtype=np.float32)
    prior = np.ones(k, dtype=np.float64) / k if p.uniform_prior else np.asarray(p.prior, dtype=np.float64)
    log_t = np.log(np.asarray(p.transition, dtype=np.float64) + _EPS)
    v = np.empty((n, k), dtype=np.float64)
    v[0] = np.log(prior + _EPS) + np.log(e32[:, pos[0]] + np.float32(_EPS))      # float32 column, as upstream
    for j in range(1, n):
        le = np.log(e32[:, pos[j]].astype(np.float64) + _EPS)                    # float32 scalars promoted
        v[j] = ((le[None, :] + log_t) + v[j - 1][:, None]).max(axis=0)
    path = np.empty(n, dtype=np.int64)
    path[-1] = int(np.argmax(v[-1]))
    for j in range(n - 2, -1, -1):
        path[j] = int(np.argmax(log_t[:, path[j + 1]] + v[j]))
    return labels[path]


def after_gap(t: np.ndarray, interval: int) -> np.ndarray:
    """bool [N]: epoch j > 0 whose start is not exactly ``interval`` after epoch j - 1's (integer time units)."""
    t = np.asarray(t, dtype=np.int64)
    out = np.zeros(t.shape[0], dtype=bool)
    if t.shape[0] > 1:
        out[1:] = np.diff(t) != int(interval)
    return out


def smooth(raw: np.ndarray, t: np.ndarray, p: HMMParams, interval: int) -> Tuple[np.ndarray, np.ndarray]:
    """Upstream ``HMM.predict``: (smoothed labels, after_gap mask). ``t`` and ``interval`` are integers in one
    unit (milliseconds here), so the gap test is exact like upstream's Timedelta comparison."""
    raw = np.asarray(raw)
    t = np.asarray(t)
    if raw.shape != t.shape or raw.ndim != 1:
        raise ValueError("labels and times must be 1-D and the same length")
    if raw.shape[0] and (np.diff(t.astype(np.int64)) <= 0).any():
        raise ValueError("epoch times must be strictly increasing")
    y = viterbi(raw, p)
    gaps = after_gap(t, interval) if not p.ignore_transition_gaps else np.zeros(raw.shape[0], dtype=bool)
    if gaps.any():
        y = y.copy()
        y[gaps] = raw[gaps]
    return y, gaps


def params_from_doc(doc: dict, classes: Optional[Tuple[str, ...]] = None) -> HMMParams:
    """The ``hmm`` block of a converted ``nara.actinet.hmm/1`` file -> :class:`HMMParams` (dtypes restored)."""
    p = HMMParams(labels=np.asarray(doc["labels"], dtype=np.int64),
                  prior=np.asarray(doc["prior"], dtype=np.float64),
                  emission=np.asarray(doc["emission"], dtype=np.float32),
                  transition=np.asarray(doc["transition"], dtype=np.float64),
                  uniform_prior=bool(doc["uniform_prior"]),
                  ignore_transition_gaps=bool(doc["ignore_transition_gaps"]))
    if classes is not None and (p.n_states != len(classes)
                                or np.asarray(p.labels).tolist() != list(range(len(classes)))):
        raise ValueError("HMM labels must be the class indices 0..K-1 of the class order")
    return p


__all__ = ["HMMParams", "viterbi", "after_gap", "smooth", "params_from_doc"]
