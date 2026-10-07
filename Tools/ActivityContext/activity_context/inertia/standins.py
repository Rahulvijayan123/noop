"""Stand-in encoders — offline / shadow only, never Inertia-1 (INERTIA1.md §4).

``standin:handcrafted-stats-v1``  a strong engineered baseline: 72 deterministic statistical/spectral
    features per 3-axis 20 Hz window (numpy only). The bar a frozen foundation embedding must clear.
``standin:nara-imu-feat-1-accel`` what the decoder already sees: imu-feat-1's accel features on the window.
``standin:inertia-arch-random-init/<method>-<preset>/seed<k>`` (adapter.RandomInitArchEncoder) — the
    upstream architecture with seeded random weights: a negative control.

Feature encoders accept any window length allowed by the contract (``window_s`` pins the input shape).
All values are finite for finite input (degenerate statistics fall back to 0).
"""

from __future__ import annotations

from typing import List, Tuple

import numpy as np

from .. import __version__
from ..baseline import CADENCE_BAND_HZ, MIN_CADENCE_STRENGTH
from ..features import orientation_change_deg
from . import INERTIA_RATE_HZ
from .contract import EncoderInfo, make_info, validate_batch

HANDCRAFTED_ID = "standin:handcrafted-stats-v1"
IMU_FEAT_ID = "standin:nara-imu-feat-1-accel"
_FS = float(INERTIA_RATE_HZ)
_AXES = ("x", "y", "z", "mag")
_STATS = ("mean", "std", "min", "max", "p10", "p25", "p50", "p75", "p90")
_BANDS: Tuple[Tuple[float, float], ...] = ((0.3, 1.0), (1.0, 2.0), (2.0, 3.0), (3.0, 5.0), (5.0, 8.0))
_SPEC_LO, _SPEC_HI = 0.3, 8.0
_CADENCE_LAG_HZ = (0.5, 3.5)


def handcrafted_feature_names() -> List[str]:
    names = [f"{a}_{s}" for a in _AXES for s in _STATS]
    names += ["g_dir_x", "g_dir_y", "g_dir_z", "g_norm"]
    names += [f"jerk_rms_{a}" for a in _AXES] + ["jerk3d_mean", "jerk3d_std", "jerk3d_p90"]
    names += [f"band_frac_{lo:g}_{hi:g}hz" for lo, hi in _BANDS]
    names += ["mag_log_power_0.3_8hz", "mag_dominant_hz", "mag_dominant_frac", "mag_spectral_entropy"]
    names += [f"{a}_log_power_0.3_8hz" for a in _AXES[:3]]
    names += ["acf_peak", "acf_peak_hz", "acf_regularity"]
    names += ["corr_xy", "corr_xz", "corr_yz", "orientation_change_deg", "tilt_std_deg"]
    names += ["mag_skew", "mag_kurtosis", "mag_zero_cross_per_s", "still_fraction", "mag_mad"]
    return names


def _safe_div(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return np.divide(a, b, out=np.zeros(np.broadcast(a, b).shape), where=np.abs(b) > 1e-12)


def _handcrafted(batch: np.ndarray) -> np.ndarray:
    x = batch.astype(np.float64)                                   # [B, 3, T]
    B, _, T = x.shape
    mag = np.linalg.norm(x, axis=1)                                # [B, T]
    sig = np.concatenate([x, mag[:, None, :]], axis=1)             # [B, 4, T]
    pct = np.percentile(sig, [10, 25, 50, 75, 90], axis=2)         # [5, B, 4]
    stats = np.stack([sig.mean(2), sig.std(2), sig.min(2), sig.max(2), *pct], axis=2)   # [B, 4, 9]
    feats = [stats.reshape(B, -1)]

    gvec = x.mean(axis=2)                                          # [B, 3]
    gnorm = np.linalg.norm(gvec, axis=1)
    gdir = _safe_div(gvec, gnorm[:, None])
    feats += [gdir, gnorm[:, None]]

    d = np.diff(sig, axis=2) * _FS                                 # g/s
    j3 = np.linalg.norm(np.diff(x, axis=2) * _FS, axis=1)
    feats += [np.sqrt((d ** 2).mean(2)), j3.mean(1)[:, None], j3.std(1)[:, None],
              np.percentile(j3, 90, axis=1)[:, None]]

    ac = sig - sig.mean(axis=2, keepdims=True)
    power = np.abs(np.fft.rfft(ac * np.hanning(T), axis=2)) ** 2   # [B, 4, F]
    f = np.fft.rfftfreq(T, d=1.0 / _FS)
    band = (f >= _SPEC_LO) & (f <= _SPEC_HI)
    pm = power[:, 3, :]
    total = pm[:, band].sum(1)
    feats.append(np.stack([_safe_div(pm[:, (f >= lo) & (f < hi if hi < _SPEC_HI else f <= hi)].sum(1), total)
                           for lo, hi in _BANDS], axis=1))
    pb = pm[:, band]
    dom = pb.argmax(1)
    p = _safe_div(pb, total[:, None])
    ent = -(p * np.log(np.where(p > 0, p, 1.0))).sum(1) / np.log(max(int(band.sum()), 2))
    feats.append(np.stack([np.log10(total + 1e-12), f[band][dom], _safe_div(pb.max(1), total), ent], axis=1))
    feats.append(np.log10(power[:, :3, band].sum(2) + 1e-12))

    m = ac[:, 3, :]
    r = np.fft.irfft(np.abs(np.fft.rfft(m, n=2 * T, axis=1)) ** 2, n=2 * T, axis=1)[:, :T]
    r = _safe_div(r, r[:, :1])
    lo, hi = int(np.ceil(_FS / _CADENCE_LAG_HZ[1])), min(int(np.floor(_FS / _CADENCE_LAG_HZ[0])), T - 1)
    lag = lo + r[:, lo:hi + 1].argmax(1)
    peak = r[np.arange(B), lag]
    reg = np.where(2 * lag < T, r[np.arange(B), np.minimum(2 * lag, T - 1)], 0.0)
    feats.append(np.stack([peak, _FS / lag, reg], axis=1))

    sd = x.std(axis=2)
    xc = x - x.mean(axis=2, keepdims=True)
    cov = lambda i, j: (xc[:, i] * xc[:, j]).mean(1)  # noqa: E731
    feats.append(np.stack([_safe_div(cov(i, j), sd[:, i] * sd[:, j]) for i, j in ((0, 1), (0, 2), (1, 2))], axis=1))
    orient = [orientation_change_deg(w.T) for w in x]
    unit = _safe_div(x, mag[:, None, :])
    tilt = np.degrees(np.arccos(np.clip(np.einsum("bct,bc->bt", unit, gdir), -1.0, 1.0)))
    feats.append(np.stack([np.array([o or 0.0 for o in orient]), tilt.std(1)], axis=1))

    msd = mag.std(1)
    z = _safe_div(mag - mag.mean(1, keepdims=True), msd[:, None])
    zc = (np.diff(np.signbit(m).astype(np.int8), axis=1) != 0).sum(1) / (T / _FS)
    blocks = mag[:, : (T // INERTIA_RATE_HZ) * INERTIA_RATE_HZ].reshape(B, -1, INERTIA_RATE_HZ)
    still = (blocks.std(2) < 0.01).mean(1)
    feats.append(np.stack([(z ** 3).mean(1), (z ** 4).mean(1) - 3.0 * (msd > 1e-12), zc, still,
                           np.abs(mag - mag.mean(1, keepdims=True)).mean(1)], axis=1))
    out = np.concatenate(feats, axis=1)
    return np.where(np.isfinite(out), out, 0.0).astype(np.float32)


def _imu_feat_accel(batch: np.ndarray) -> np.ndarray:
    """imu-feat-1 accel features (features.py / baseline.extract_features formulas) at 20 Hz."""
    out = np.zeros((batch.shape[0], 7), dtype=np.float64)
    lo = max(1, int(round(_FS / CADENCE_BAND_HZ[1])))
    for b, w in enumerate(batch.astype(np.float64)):
        amag = np.linalg.norm(w, axis=0)
        n = amag.size
        ac = amag - amag.mean()
        ac0 = float(np.dot(ac, ac))
        best_f, best_s = None, 0.0
        if ac0 > 0:
            for lag in range(lo, min(n - 1, int(round(_FS / CADENCE_BAND_HZ[0]))) + 1):
                s = float(np.dot(ac[:-lag], ac[lag:])) / ac0
                if s > best_s:
                    best_s, best_f = s, _FS / lag
        cad = best_f if best_s >= MIN_CADENCE_STRENGTH else None
        orient = orientation_change_deg(w.T)
        out[b] = [np.sqrt(np.mean(ac * ac)), np.sqrt(np.mean(np.diff(amag) ** 2)), cad or 0.0,
                  float(cad is not None), max(0.0, best_s), orient or 0.0, float(orient is not None)]
    return out.astype(np.float32)


IMU_FEAT_NAMES = ["accel_rms_g", "jerk_rms_per_20hz_sample", "cadence_hz", "cadence_present", "cadence_strength",
                  "orientation_change_deg", "orientation_present"]


class _FeatureEncoder:
    _fn = staticmethod(_handcrafted)

    def __init__(self, encoder_id: str, names: List[str], window_s: int, description: str):
        cfg = {"encoder_id": encoder_id, "feature_names": names, "window_s": int(window_s),
               "rate_hz": INERTIA_RATE_HZ, "description": description, "package_version": __version__}
        self._info = make_info(encoder_id=encoder_id, kind="standin", config=cfg, embedding_dim=len(names),
                               window_s=window_s, extraction_point=f"activity_context.inertia.standins:{encoder_id}",
                               version_tag=encoder_id)

    @property
    def info(self) -> EncoderInfo:
        return self._info

    def embed(self, batch: np.ndarray) -> np.ndarray:
        batch = validate_batch(batch, self._info.input_contract)
        if batch.shape[0] == 0:
            return np.zeros((0, self._info.embedding_dim), dtype=np.float32)
        return type(self)._fn(batch)


class HandcraftedStatsEncoder(_FeatureEncoder):
    _fn = staticmethod(_handcrafted)

    def __init__(self, window_s: int = 30):
        super().__init__(HANDCRAFTED_ID, handcrafted_feature_names(), window_s,
                         "72 statistical/spectral/cadence/orientation features of the 20 Hz accel window")


class ImuFeatAccelEncoder(_FeatureEncoder):
    """imu-feat-1, adapted: whole 10/30 s window at 20 Hz (not 4 s at 30 Hz); jerk per 20 Hz sample (not
    comparable numerically to the HART-path value); gyro_rms dropped (accel-only input); None -> 0 plus a
    presence flag, so the vector is always finite."""
    _fn = staticmethod(_imu_feat_accel)

    def __init__(self, window_s: int = 30):
        super().__init__(IMU_FEAT_ID, list(IMU_FEAT_NAMES), window_s,
                         "imu-feat-1 accel features on the Inertia window (20 Hz adaptation)")
