"""Out-of-distribution signal for 60 s windows fed to the wrist CNN.

``ood_signal(windows) -> [n]`` in [0, 1]: ~0 = looks like the public training windows, ~1 = clearly
outside what the network can be trusted on (unit/gravity mismatch, railed or frozen sensor, NaNs).
It is a *heuristic distance on simple statistics*, not a calibrated probability: it can flag
windows that are obviously unlike the training data, never certify that a window is fine.

Per-window statistics (3-axis acceleration in g, gravity included, 60 s at 100 Hz)::

    VM(t)          = sqrt(x^2 + y^2 + z^2)
    vm_p05/50/95   5th / 50th / 95th percentile of VM
    mean_norm      || (mean x, mean y, mean z) ||        static component, orientation-free
    std_*, range_* per-axis std and (max - min), sorted across axes (max >= mid >= min)
    diff_rms       sqrt(mean_t || a(t) - a(t-1) ||^2)    high-frequency / noise level
    sat_frac       fraction of samples with any |axis| >= 7.9 g
    flat_cov       fraction of samples lying in runs of >= 1 s of bit-identical 3-axis values

Every statistic is invariant to axis permutation and sign. That is deliberate: the network is
nearly insensitive to axis order (the five non-identity permutations of the sample's axes move
the output by 0.10-0.14 MET on average and leave the RMSE vs label at 0.72-0.75 MET against 0.741
unpermuted), the WHOOP-to-ActiGraph axis mapping is not established, and the public sample covers
one participant's wrist orientations. (Sign flips DO change the output: mean absolute change
0.14-0.33 MET, up to 2.9 MET on a single window; no statistic here can detect that.)

Components (each in [0, 1]); the score is their maximum::

    nonfinite   1 if any sample is NaN/inf
    saturation  s / (s + 0.005), s = sat_frac                     (0.5% railed samples -> 0.5)
    flat        clip((flat_cov - 0.5) / 0.4, 0, 1)                (>= 90% of the minute frozen -> 1)
    gravity     e / (e + 1), e = max(|vm_p50 - 1| - 0.06, 0) / 0.05, only for quiet windows
                (std_max < 0.15 g): a rigid sensor at rest reads 1 g. In the public windows
                |vm_p50 - 1| <= 0.043 for all 266 quiet windows. Catches units (m/s^2, mg, LSB),
                removed gravity and gain errors without relying on the sample envelope.
    envelope    max over features of e_f / (e_f + 1), where e_f is how far the feature lies
                outside its training envelope in units of the envelope half-width on that side:
                  lo_f, med_f, hi_f = p0.5, p50, p99.5 of the public windows
                  half-width above  = max(hi_f - med_f, floor_f),  below = max(med_f - lo_f, floor_f)
                  allowed range     = [lo_f - 0.25 below, hi_f + 0.25 above]
                vm_p05, vm_p50, mean_norm are two-sided, the rest upper-sided only (a calmer or
                cleaner signal than any training window is not suspicious).
                One half-width beyond the allowed range -> 0.5, three -> 0.75.

Reading it: < ~0.2 unremarkable; > 0.5 treat the CNN output as unsupported; ~1 unit mismatch or
dead/railed/missing data. ``ood_eval.py`` measures false alarms (leave-one-segment-out) and the
response to unit/gravity/scale/noise perturbations on the public windows.

Known weaknesses
----------------
* The envelope comes from the only training windows that are public: ONE participant, one day,
  7 segments, 1 292 windows (the real training set had 60 people). Movement stronger than that
  participant's is scored as unusual although the weights saw it in training; and stats that are
  all in-envelope say nothing about placement, orientation sign or sensor-noise differences.
* Univariate envelopes miss joint inconsistencies (e.g. white noise whose std looks like walking);
  only the explicit gravity-at-rest rule is joint.
* 24% of the public windows contain >= 1 s of exactly repeated samples (consistent with ActiGraph
  idle-sleep mode; the 58 fully frozen ones all carry the label floor of 1.336 MET). The network
  saw such inputs, yet a frozen minute from a WHOOP strap is a data fault, so ``flat`` flags it.
* The score has not been calibrated against prediction error.
"""

from __future__ import annotations

from collections.abc import Mapping

import numpy as np

from .inputs import axes_major

SATURATION_G = 7.9
FLAT_MIN_RUN_SAMPLES = 100
SAT_HALF_FRAC = 0.005
FLAT_ZERO_COV, FLAT_FULL_COV = 0.5, 0.9
GRAVITY_GATE_STD_G = 0.15
GRAVITY_TOL_G, GRAVITY_SCALE_G = 0.06, 0.05
ENVELOPE_MARGIN = 0.25

FEATURES: tuple[str, ...] = (
    "vm_p05", "vm_p50", "vm_p95", "mean_norm",
    "std_max", "std_mid", "std_min",
    "range_max", "range_mid", "range_min",
    "diff_rms",
)
TWO_SIDED = frozenset({"vm_p05", "vm_p50", "mean_norm"})
HALF_WIDTH_FLOOR: Mapping[str, float] = {
    "vm_p05": 0.02, "vm_p50": 0.02, "vm_p95": 0.02, "mean_norm": 0.02,
    "std_max": 0.01, "std_mid": 0.01, "std_min": 0.01,
    "range_max": 0.05, "range_mid": 0.05, "range_min": 0.05,
    "diff_rms": 0.005,
}
COMPONENTS = ("nonfinite", "saturation", "flat", "gravity", "envelope")

# (p0.5, p50, p99.5) of the 1 292 public windows, upstream layout; regenerate with
# ``python -m energy_models.wrist_cnn.ood --sample-dir <upstream>/data/train_ready/window-6000-overlap-3000``.
ENVELOPE: Mapping[str, tuple[float, float, float]] = {
    "vm_p05": (0.4176, 0.9262, 1.3023),
    "vm_p50": (0.9707, 1.0331, 1.8059),
    "vm_p95": (0.9824, 1.4150, 4.7958),
    "mean_norm": (0.4458, 1.0051, 1.6881),
    "std_max": (0.0, 0.3839, 1.6585),
    "std_mid": (0.0, 0.2933, 1.1589),
    "std_min": (0.0, 0.2010, 0.6634),
    "range_max": (0.0, 2.6820, 9.5049),
    "range_mid": (0.0, 2.1390, 8.3405),
    "range_min": (0.0, 1.6135, 5.9873),
    "diff_rms": (0.0, 0.0752, 0.5247),
}

_CHUNK = 64


def _frozen_coverage(same: np.ndarray, min_run: int) -> np.ndarray:
    """Fraction of samples inside runs of >= ``min_run`` identical consecutive samples.

    ``same`` [m, T-1] is True where sample t equals sample t-1 on all axes.
    """
    m, k = same.shape
    csum = np.cumsum(same, axis=1, dtype=np.int32)
    last_false = np.maximum.accumulate(np.where(same, 0, csum), axis=1)
    run = csum - last_false                                          # length of the True-run ending at t
    is_end = same & ~np.concatenate([same[:, 1:], np.zeros((m, 1), dtype=bool)], axis=1)
    long_run = is_end & (run >= min_run - 1)
    return ((run + 1) * long_run).sum(axis=1) / float(k + 1)


def window_features(windows: np.ndarray, layout: str = "upstream") -> dict[str, np.ndarray]:
    """Per-window statistics behind the OOD score (all-NaN rows for windows with a non-finite sample)."""
    a = np.asarray(windows)
    if a.ndim != 3 or a.shape[2] != 3:
        raise ValueError(f"windows must have shape [n, T, 3]; got {a.shape}")
    n = a.shape[0]
    feats = {k: np.full(n, np.nan, dtype=np.float64) for k in (*FEATURES, "sat_frac", "flat_cov")}
    finite = np.isfinite(a).all(axis=(1, 2)) if n else np.zeros(0, dtype=bool)
    for s in range(0, n, _CHUNK):
        sel = np.flatnonzero(finite[s : s + _CHUNK]) + s
        if not len(sel):
            continue
        x = axes_major(np.asarray(a[sel], dtype=np.float32), layout)       # [m, 3, T]
        vm = np.sqrt((x * x).sum(axis=1, dtype=np.float32))
        p05, p50, p95 = np.percentile(vm, [5, 50, 95], axis=1)
        mean_vec = x.mean(axis=2, dtype=np.float64)
        std = np.sort(x.std(axis=2, dtype=np.float64), axis=1)[:, ::-1]
        rng = np.sort((x.max(axis=2) - x.min(axis=2)).astype(np.float64), axis=1)[:, ::-1]
        d = np.diff(x, axis=2)
        out = {
            "vm_p05": p05, "vm_p50": p50, "vm_p95": p95,
            "mean_norm": np.linalg.norm(mean_vec, axis=1),
            "std_max": std[:, 0], "std_mid": std[:, 1], "std_min": std[:, 2],
            "range_max": rng[:, 0], "range_mid": rng[:, 1], "range_min": rng[:, 2],
            "diff_rms": np.sqrt((d.astype(np.float64) ** 2).sum(axis=1).mean(axis=1)),
            "sat_frac": (np.abs(x) >= SATURATION_G).any(axis=1).mean(axis=1),
            "flat_cov": _frozen_coverage((d == 0).all(axis=1), FLAT_MIN_RUN_SAMPLES),
        }
        for k, v in out.items():
            feats[k][sel] = v
    return feats


def compute_envelope(
    windows: np.ndarray, layout: str = "upstream", quantiles: tuple[float, float] = (0.5, 99.5)
) -> dict[str, tuple[float, float, float]]:
    """(low quantile, median, high quantile) of each feature over ``windows`` (maintainer tool)."""
    f = window_features(windows, layout)
    return {
        k: (float(np.percentile(f[k], quantiles[0])), float(np.percentile(f[k], 50)), float(np.percentile(f[k], quantiles[1])))
        for k in FEATURES
    }


def _envelope_scores(feats: Mapping[str, np.ndarray], envelope: Mapping[str, tuple[float, float, float]]) -> tuple[np.ndarray, np.ndarray]:
    n = len(feats["vm_p50"])
    worst = np.zeros(n)
    which = np.full(n, -1, dtype=np.int64)
    for j, name in enumerate(FEATURES):
        lo, med, hi = envelope[name]
        floor = HALF_WIDTH_FLOOR[name]
        w_up, w_dn = max(hi - med, floor), max(med - lo, floor)
        x = feats[name]
        with np.errstate(invalid="ignore"):
            e = np.maximum(x - (hi + ENVELOPE_MARGIN * w_up), 0.0) / w_up
            if name in TWO_SIDED:
                e = np.maximum(e, np.maximum((lo - ENVELOPE_MARGIN * w_dn) - x, 0.0) / w_dn)
        e = np.nan_to_num(e, nan=0.0)
        s = e / (e + 1.0)
        better = s > worst
        worst = np.where(better, s, worst)
        which = np.where(better, j, which)
    return worst, which


def ood_components(
    windows: np.ndarray,
    layout: str = "upstream",
    envelope: Mapping[str, tuple[float, float, float]] | None = None,
) -> dict[str, np.ndarray]:
    """Component scores (float32 [n]) plus ``worst_feature`` (index into ``FEATURES``, -1 if none)."""
    feats = window_features(windows, layout)
    bad = ~np.isfinite(feats["vm_p50"])
    sat = np.nan_to_num(feats["sat_frac"], nan=0.0)
    flat = np.nan_to_num(feats["flat_cov"], nan=0.0)
    quiet = np.nan_to_num(feats["std_max"], nan=np.inf) < GRAVITY_GATE_STD_G
    with np.errstate(invalid="ignore"):
        g_err = np.nan_to_num(np.maximum(np.abs(feats["vm_p50"] - 1.0) - GRAVITY_TOL_G, 0.0) / GRAVITY_SCALE_G, nan=0.0)
    env_score, which = _envelope_scores(feats, ENVELOPE if envelope is None else envelope)
    return {
        "nonfinite": bad.astype(np.float32),
        "saturation": (sat / (sat + SAT_HALF_FRAC)).astype(np.float32),
        "flat": np.clip((flat - FLAT_ZERO_COV) / (FLAT_FULL_COV - FLAT_ZERO_COV), 0.0, 1.0).astype(np.float32),
        "gravity": np.where(quiet, g_err / (g_err + 1.0), 0.0).astype(np.float32),
        "envelope": env_score.astype(np.float32),
        "worst_feature": which,
    }


def ood_signal(
    windows: np.ndarray,
    layout: str = "upstream",
    envelope: Mapping[str, tuple[float, float, float]] | None = None,
) -> np.ndarray:
    """OOD score in [0, 1] for each window ``[n, 6000, 3]`` (see the module docstring for the formula)."""
    comps = ood_components(windows, layout, envelope)
    return np.stack([comps[c] for c in COMPONENTS]).max(axis=0).astype(np.float32)


def dominant_reason(components: Mapping[str, np.ndarray], threshold: float = 0.05) -> list[str]:
    """Which component drives each window's score ("ok" when all components are below ``threshold``)."""
    stacked = np.stack([components[c] for c in COMPONENTS])
    top = stacked.argmax(axis=0)
    reasons: list[str] = []
    for i, t in enumerate(top):
        if stacked[t, i] < threshold:
            reasons.append("ok")
        elif COMPONENTS[t] == "envelope":
            reasons.append(f"envelope:{FEATURES[int(components['worst_feature'][i])]}")
        else:
            reasons.append(COMPONENTS[t])
    return reasons


def _main() -> int:
    import argparse  # noqa: PLC0415
    import pprint  # noqa: PLC0415

    from .evaluate import load_sample_dir  # noqa: PLC0415

    ap = argparse.ArgumentParser(description="Print feature quantiles and the envelope literal for the public windows.")
    ap.add_argument("--sample-dir", required=True)
    args = ap.parse_args()
    sample = load_sample_dir(args.sample_dir)
    feats = window_features(sample["windows"])
    print("feature     min     p0.5       p5      p50      p95    p99.5      max")
    for k, v in feats.items():
        print(f"{k:10s} " + " ".join(f"{x:8.4f}" for x in np.percentile(v, [0, 0.5, 5, 50, 95, 99.5, 100])))
    print("ENVELOPE =", end=" ")
    pprint.pprint({k: tuple(round(x, 4) for x in v) for k, v in compute_envelope(sample["windows"]).items()}, sort_dicts=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
