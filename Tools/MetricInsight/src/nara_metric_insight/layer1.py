"""Layer 1, the phone Baseline (LongitudinalBaseline, param set v2.clinical), ported for the night vitals and steps.

A line-by-line port of `LongitudinalBaseline.evaluate` with replay and `scoreOneDay`, for the five night vitals and
the daily steps series
(Packages/StrandAnalytics/Sources/StrandAnalytics/LongitudinalBaseline.swift, LongitudinalBaselineStatistics.swift,
LongitudinalBaselineV2.swift, LongitudinalBaselineReview.swift, LongitudinalBaselineTrial.swift and
PhysiologyContext/PCRobustStats.swift) and of the verdict the Home ring and the Monitor show
(`LongitudinalBaseline.vitalVerdict`), so an explanation calls a night "in range" or "off usual" exactly when the
app does for the same nightly values.

v2.clinical, in short: the 60-day usual is the median of the clean nights T-60 .. T-8 with a small-sample,
trim-consistent MAD scale and an AR(1) effective n; its band is a 95 % predictive Student-t interval widened by an
out-of-sample tail factor; the centre is never moved along a slope; a two-sided CUSUM on each night's predictive z
opens a change episode and holds the pre-change usual for 28 days; the week usual is the Student-t-weighted EWMA as
before, with a small-sample MAD and its own predictive band.

Phase A only. Treatment trials, day logs (felt ill, habits, confounders) and acute flags live on the phone, so they
are neutral here, as on a phone with none logged. The final-day v2 extras (`enrichV2`: the 90- and 365-day copies,
the frozen anchor, trends, drift, maturity) feed nothing the verdict or the two copies use and are not ported.
Nights are keyed by the day they end, as everywhere else.
Pinned to the Swift: tests/data/layer1_expected.json holds what the app's own code returns for the tapes in
tests/data/layer1_cases.json (recorded by StrandAnalyticsTests/LayerOneServerMirrorTests, which also fails when
Layer 1 changes), and tests/test_layer1.py holds this port to it.
"""

from __future__ import annotations

import math
from bisect import bisect_right
from dataclasses import dataclass
from datetime import date
from functools import lru_cache
from typing import Any

# LongitudinalBaseline.V2.paramSet: the param set every evaluation carries, and the one LayerOneServerMirrorTests
# records in layer1_expected.json.
PARAM_SET = "v2.clinical"

LOOKBACK_LONG, GAP_DAYS = 60, 7
LONG_SLOTS = LOOKBACK_LONG - GAP_DAYS        # 53: nights T-60 .. T-8
K_LEARN = 2.0                                # the fever-night trim of the 60-day copy, in robust SDs
NU = 4.0
N7_SHOW = N_LONG_SHOW = 4
N_BORROW = 7.0
P_REGIME = 0.35
STALE_DAYS = 14
MAD_SCALE = 1.4826                           # RobustStats.madNormalConsistency
MEDIAN_SE_FACTOR = 1.2533                    # RobustStats.medianStandardErrorFactor: SE of a median ≈ 1.2533·σ/√n
SLOPE_FIT_NIGHTS = 28
TRUST_HIDE_THRESHOLD = 35                    # LongitudinalBaseline.trustHideThreshold

# LongitudinalBaseline.V2 and Stats.
PHI_FALLBACK = 0.3                           # lag-1 autocorrelation assumed when too few consecutive pairs
BAND_ALPHA = 0.05                            # the usual band is a 95 % predictive interval
TREND_ALPHA = 0.01
CHANGE_HOLD_DAYS = 28
OOS_RING, OOS_DELAY_DAYS, OOS_FULL_WEIGHT_N, OOS_MAX_FACTOR = 120, 14, 60, 1.6
# Stats.CusumConfig (V2.cusum).
CUSUM_K, CUSUM_H, CUSUM_CLAMP_Z, CUSUM_CAP_FACTOR, CUSUM_MAX_GAP_DAYS = 0.25, 10.0, 2.0, 1.25, 7

OK, LOW_QUALITY, MISSING = "ok", "low_quality", "missing"
IN_RANGE, OFF, LEARNING, NO_READING = "in_range", "off", "learning", "no_reading"
_EPOCH = date(1970, 1, 1).toordinal()


@dataclass(frozen=True)
class Series:
    """seriesSpec + params(for:) of one night vital."""
    key: str                # LBSeries raw value
    min_val: float
    max_val: float
    floor: float            # spread floor, on the math scale (ln for HRV)
    k_band: float           # the table k: the band multiplier only when a copy has no spread to build one from
    span7: int
    n_long_established: int
    uses_log: bool = False

    @property
    def alpha(self) -> float:
        return 2.0 / (float(self.span7) + 1.0)


SERIES: dict[str, Series] = {s.key: s for s in (
    Series("sleep_rhr", 30, 120, 2, 2.0, 7, 14),
    Series("sleep_hrv_ln", 5, 250, 0.08, 2.6, 10, 14, uses_log=True),
    Series("sleep_temp", 20, 42, 0.3, 2.0, 7, 14),
    Series("sleep_resp", 4, 40, 0.5, 1.6, 7, 14),
    Series("sleep_spo2_mean", 70, 100, 0.5, 1.5, 7, 14),
    Series("waking_steps", 0, 200_000, 500, 2.4, 7, 21),
)}
# The server_daily_scores column each series reads (ServerScoreRepository → DailyMetric → nativeValue).
COLUMNS = {"sleep_rhr": "resting_hr_bpm", "sleep_hrv_ln": "hrv_rmssd_ms", "sleep_temp": "skin_temp_c",
           "sleep_resp": "resp_rate_bpm", "sleep_spo2_mean": "spo2_pct", "waking_steps": "steps"}
# Read as integers on the phone (ServerScoreRepository: Int(value.rounded())).
INTEGER_SERIES = frozenset({"sleep_rhr", "waking_steps"})
# BaselineStore.vitalsCheckSeries: the Home ring and Monitor list, in their order.
VITALS = ("sleep_rhr", "sleep_hrv_ln", "sleep_temp", "sleep_resp", "sleep_spo2_mean")


@dataclass(frozen=True)
class Observation:
    value: float | None
    status: str


@dataclass(frozen=True)
class WindowCopy:
    """Stats.WindowCopy: one robust reference copy on the math scale."""
    center: float
    scale: float             # 1.4826·MAD × small-sample factor (× trim consistency when trimmed), floored
    n: int
    phi: float
    n_eff: float
    center_se: float
    predictive_scale: float  # √(scale² + center_se²): the scale of a new night around this centre
    df: float
    from_epoch: int
    to_epoch: int
    trimmed: bool


@dataclass(frozen=True)
class Carry:
    """LBCarry: what one scored day hands to the next (the fields Phase A reads)."""
    center7: float | None = None
    spread7: float | None = None
    center_long: float | None = None
    spread_long: float | None = None
    n_long: int = 0
    established_long: bool = False
    cusum_s: float = 0.0
    # The two-sided CUSUM and its change episode.
    cusum_pos: float = 0.0
    cusum_neg: float = 0.0
    cusum_last_epoch: int | None = None
    cusum_run_start_pos: int | None = None
    cusum_run_start_neg: int | None = None
    change_direction: int = 0
    change_onset_epoch: int | None = None
    change_alarm_epoch: int | None = None
    held_copy_long: WindowCopy | None = None
    hold_until_epoch: int | None = None
    # Out-of-sample |predictive z| ring (newest last) and the nights still waiting to enter it, as (epoch, |z|).
    oos_abs_z: tuple[float, ...] = ()
    oos_pending: tuple[tuple[int, float], ...] = ()
    last_episode_direction: int = 0
    last_episode_alarm_epoch: int | None = None


@dataclass(frozen=True)
class Copy:
    """LBCopySnapshot: center and spread on the math scale, the band in display units."""
    center: float
    spread: float
    center_display: float
    band_lo_display: float
    band_hi_display: float
    n: int
    z: float | None
    held: bool


@dataclass(frozen=True)
class Evaluation:
    as_of: date
    series: str
    today: float | None             # todayNative: tonight's value when it may be scored, else None
    tonight_status: str | None
    copy7: Copy | None
    copy_long: Copy | None
    n7: int
    n_learn: float
    n_long: int
    z7: float | None
    z_long: float | None
    show7: bool
    show_long: bool
    established_long: bool
    stale: bool
    trust7: int
    trust_long: int
    slope_usable: bool              # a significant 28-night trend (reported only: v2 never moves the centre on it)
    expected_long: float | None     # the 60-day centre (v2: never a point on a slope path)
    k_used: float                   # the 60-day band multiplier (predictive t quantile × tail factor)
    p_change: float
    regime_shift: bool              # a change episode is open
    carry: Carry
    k7: float = 2.0                 # the week band multiplier (predictive t quantile)
    z_pred_long: float | None = None
    calibration_factor: float = 1.0
    holding_copy: bool = False      # the 60-day copy is the held pre-change copy
    # The reference copy behind copy_long (the held pre-change copy, the live window copy, or None while only the
    # carried centre and spread are held): its predictive scale is the Swift copyLong.predictiveSpread and its n_eff
    # copyLong.nEff. Read by Tools/PersonalEventDetection (layer1_context.py) for the context strata.
    ref_copy: WindowCopy | None = None


@dataclass(frozen=True)
class Verdict:
    """LBVitalVerdict: the state the app shows and the band it shows with it."""
    series: str
    state: str
    value: float | None
    band_lo: float | None
    band_hi: float | None
    center: float | None
    from_week: bool
    off_week: bool = False
    off_long: bool = False


# --------------------------------------------------------------------------- the helpers, as in Swift


def round_half_away(x: float) -> float:
    """Swift's `rounded()` (to nearest, ties away from zero)."""
    whole = math.floor(abs(x))
    if abs(x) - whole >= 0.5:
        whole += 1
    return math.copysign(whole, x)


def epoch_day(day: date) -> int:
    return day.toordinal() - _EPOCH


def _total(values) -> float:
    """Left-to-right sum, as Swift's `reduce(0, +)` (Python 3.12's `sum()` of floats compensates, which can differ
    in the last bits)."""
    total = 0.0
    for value in values:
        total += value
    return total


def _median(values: list[float]) -> float | None:
    s = sorted(v for v in values if math.isfinite(v))
    if not s:
        return None
    n = len(s)
    return s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2.0


_MAD_SMALL_SAMPLE = {2: 1.196, 3: 1.486, 4: 1.361, 5: 1.217, 6: 1.187, 7: 1.139, 8: 1.126, 9: 1.100}


def _mad_small_sample_factor(n: int) -> float:
    """RobustStats.madSmallSampleFactor: makes 1.4826·MAD unbiased for n Gaussian values."""
    if n < 2:
        return 1.0
    return _MAD_SMALL_SAMPLE[n] if n in _MAD_SMALL_SAMPLE else float(n) / (float(n) - 0.8)


def _mad_scale(values: list[float], center: float) -> float | None:
    """RobustStats.madScale with the small-sample correction; None when empty."""
    v = [x for x in values if math.isfinite(x)]
    mad = _median([abs(x - center) for x in v])
    if mad is None:
        return None
    return MAD_SCALE * mad * _mad_small_sample_factor(len(v))


def _small_sample_spread(values: list[float], center: float, floor: float) -> float:
    scale = _mad_scale(values, center)
    return max(0.0 if scale is None else scale, floor)


def _normal_cdf(z: float) -> float:
    return 0.5 * math.erfc(-z / math.sqrt(2.0))


_ACKLAM_A = (-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02,
             -3.066479806614716e+01, 2.506628277459239e+00)
_ACKLAM_B = (-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01,
             -1.328068155288572e+01)
_ACKLAM_C = (-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549732539343734e+00,
             4.374664141464968e+00, 2.938163982698783e+00)
_ACKLAM_D = (7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00)


def _normal_quantile(p: float) -> float:
    """Stats.normalQuantile (Acklam's rational approximation)."""
    a, b, c, d = _ACKLAM_A, _ACKLAM_B, _ACKLAM_C, _ACKLAM_D
    p = min(max(p, 1e-15), 1 - 1e-15)
    p_low = 0.02425
    if p < p_low:
        q = math.sqrt(-2 * math.log(p))
        return ((((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1))
    if p > 1 - p_low:
        q = math.sqrt(-2 * math.log(1 - p))
        return -((((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                 / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1))
    q = p - 0.5
    r = q * q
    return ((((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1))


def _beta_continued_fraction(x: float, a: float, b: float) -> float:
    """betaContinuedFraction (Lentz), as in LongitudinalBaselineReview.swift."""
    qab, qap, qam = a + b, a + 1, a - 1
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < 1e-30:
        d = 1e-30
    d = 1 / d
    h = d
    for m in range(1, 201):
        m2 = 2 * m
        aa = float(m) * (b - float(m)) * x / ((qam + float(m2)) * (a + float(m2)))
        d = 1 + aa * d
        if abs(d) < 1e-30:
            d = 1e-30
        c = 1 + aa / c
        if abs(c) < 1e-30:
            c = 1e-30
        d = 1 / d
        h *= d * c
        aa = -(a + float(m)) * (qab + float(m)) * x / ((a + float(m2)) * (qap + float(m2)))
        d = 1 + aa * d
        if abs(d) < 1e-30:
            d = 1e-30
        c = 1 + aa / c
        if abs(c) < 1e-30:
            c = 1e-30
        d = 1 / d
        delta = d * c
        h *= delta
        if abs(delta - 1) < 1e-12:
            break
    return h


def _regularized_incomplete_beta(x: float, a: float, b: float) -> float:
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    ln_beta = math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)
    if x < (a + 1) / (a + b + 2):
        front = math.exp(a * math.log(x) + b * math.log(1 - x) - ln_beta) / a
        return min(1.0, max(0.0, front * _beta_continued_fraction(x, a, b)))
    front2 = math.exp(b * math.log(1 - x) + a * math.log(x) - ln_beta) / b
    return min(1.0, max(0.0, 1 - front2 * _beta_continued_fraction(1 - x, b, a)))


def _student_t_two_sided_p(t: float, df: float) -> float:
    """Stats.studentTTwoSidedP (studentTTwoTailP): P(|T_df| ≥ |t|)."""
    if not math.isfinite(t):
        return 0.0
    t_abs = abs(t)
    nu = max(df, 1.0)
    return min(1.0, max(0.0, _regularized_incomplete_beta(nu / (nu + t_abs * t_abs), nu / 2.0, 0.5)))


@lru_cache(maxsize=4096)
def _student_t_critical(alpha: float, df: float) -> float:
    """Stats.studentTCritical: the t with P(|T_df| ≥ t) = alpha, by the same bisection (so the same bits)."""
    a = min(max(alpha, 1e-12), 0.999)
    nu = max(df, 1.0)
    lo, hi = 0.0, 1.0
    while _student_t_two_sided_p(hi, nu) > a and hi < 1e6:
        hi *= 2
    for _ in range(80):
        mid = (lo + hi) / 2
        if _student_t_two_sided_p(mid, nu) > a:
            lo = mid
        else:
            hi = mid
        if hi - lo < 1e-7:
            break
    return (lo + hi) / 2


@lru_cache(maxsize=8)
def _trimmed_mad_consistency(k: float) -> float:
    """Stats.trimmedMadConsistency: the MAD of the values kept within ±k robust SD is biased low; this undoes it."""
    if not math.isfinite(k) or not k > 0:
        return 1.0
    kept = 2 * _normal_cdf(k) - 1
    m = _normal_quantile(0.5 + kept / 4)
    return 0.674_489_75 / m if m > 0 else 1.0


def _lag_one_phi(pairs: list[tuple[int, float]], center: float, min_pairs: int = 10,
                 max_phi: float = 0.8) -> float | None:
    """Stats.lagOnePhi: lag-1 autocorrelation over calendar-consecutive pairs only, Kendall bias-corrected, clamped
    to [0, max_phi]; None below `min_pairs` pairs."""
    s = sorted(pairs, key=lambda p: p[0])
    x: list[float] = []
    y: list[float] = []
    for i in range(1, len(s)):
        if s[i][0] == s[i - 1][0] + 1:
            x.append(s[i - 1][1] - center)
            y.append(s[i][1] - center)
    if len(x) < min_pairs:
        return None
    mx, my = _total(x) / float(len(x)), _total(y) / float(len(y))
    num = dx = dy = 0.0
    for a, b in zip(x, y):
        num += (a - mx) * (b - my)
        dx += (a - mx) * (a - mx)
        dy += (b - my) * (b - my)
    if not (dx > 0 and dy > 0):
        return 0.0
    raw = num / math.sqrt(dx * dy)
    corrected = raw + (1 + 3 * max(0.0, raw)) / float(len(x))
    return min(max_phi, max(0.0, corrected))


def _effective_n(n: int, phi: float) -> float:
    """Stats.effectiveN: n(1-φ)/(1+φ), at least 1."""
    if n <= 0:
        return 0.0
    p = min(0.95, max(0.0, phi))
    return max(1.0, float(n) * (1 - p) / (1 + p))


def _window_copy(pairs: list[tuple[int, float]], floor: float, min_n: int, from_epoch: int, to_epoch: int,
                 trim_k: float = K_LEARN) -> WindowCopy | None:
    """Stats.windowCopy: median centre, small-sample MAD scale (fever nights trimmed when at least 1 − p_regime of
    the nights survive the trim, then corrected for the trim), AR(1) effective n and the predictive scale."""
    vals = [v for _, v in pairs if math.isfinite(v)]
    if len(vals) < max(1, min_n):
        return None
    m0 = _median(vals)
    if m0 is None:
        return None
    kept = [(e, v) for e, v in pairs if math.isfinite(v)]
    trimmed = False
    if trim_k > 0 and len(vals) >= 4 and (s0_raw := _mad_scale(vals, m0)) is not None:
        s0 = max(s0_raw, floor)
        inside = [(e, v) for e, v in kept if abs(v - m0) / s0 < trim_k]
        if float(len(inside)) / float(len(vals)) >= 1 - P_REGIME and len(inside) >= min_n:
            trimmed = len(inside) < len(kept)
            kept = inside
    kept_vals = [v for _, v in kept]
    c = _median(kept_vals)
    s = None if c is None else _mad_scale(kept_vals, c)
    if c is None or s is None:
        return None
    if trimmed:
        s *= _trimmed_mad_consistency(trim_k)
    s = max(s, floor)
    phi_hat = _lag_one_phi(kept, c)
    phi = PHI_FALLBACK if phi_hat is None else phi_hat
    n_eff = _effective_n(len(kept_vals), phi)
    se = MEDIAN_SE_FACTOR * s / math.sqrt(n_eff)
    return WindowCopy(center=c, scale=s, n=len(kept_vals), phi=phi, n_eff=n_eff, center_se=se,
                      predictive_scale=math.sqrt(s * s + se * se), df=max(n_eff - 1, 2.0),
                      from_epoch=from_epoch, to_epoch=to_epoch, trimmed=trimmed)


@dataclass(frozen=True)
class _Trend:
    slope: float
    lower: float
    upper: float
    p: float


def _trend(pairs: list[tuple[int, float]], ci_alpha: float = 0.05) -> _Trend | None:
    """Stats.trend: Theil–Sen slope with an autocorrelation-corrected Mann–Kendall p and the Sen CI; None below 8
    points or 7 days of span."""
    pts = sorted(((e, v) for e, v in pairs if math.isfinite(v)), key=lambda p: p[0])
    n = len(pts)
    if n < 8 or pts[-1][0] - pts[0][0] < 7:
        return None
    slopes: list[float] = []
    s = 0.0
    for i in range(n - 1):
        ei, vi = pts[i]
        for j in range(i + 1, n):
            dy = pts[j][1] - vi
            dx = float(pts[j][0] - ei)
            if dx > 0:
                slopes.append(dy / dx)
            s += 1 if dy > 0 else (-1 if dy < 0 else 0)
    slopes.sort()
    sen = _median(slopes)
    if sen is None:
        return None
    intercept = _median([v - sen * float(e) for e, v in pts])
    intercept = 0.0 if intercept is None else intercept
    resid = [(e, v - (intercept + sen * float(e))) for e, v in pts]
    phi_hat = _lag_one_phi(resid, 0.0, min_pairs=6)
    phi = PHI_FALLBACK if phi_hat is None else phi_hat
    nn = float(n)
    var_s = nn * (nn - 1) * (2 * nn + 5) / 18
    var_s *= (1 + phi) / (1 - phi)
    if s > 0:
        z = (s - 1) / math.sqrt(var_s)
    elif s < 0:
        z = (s + 1) / math.sqrt(var_s)
    else:
        z = 0.0
    p = 2 * (1 - _normal_cdf(abs(z)))
    c_alpha = _normal_quantile(1 - ci_alpha / 2) * math.sqrt(var_s)
    n_pairs = float(len(slopes))
    m1 = int(math.floor((n_pairs - c_alpha) / 2))
    m2 = int(math.ceil((n_pairs + c_alpha) / 2))
    last = len(slopes) - 1
    return _Trend(slope=sen, lower=slopes[min(max(m1, 0), last)], upper=slopes[min(max(m2, 0), last)], p=p)


def _slope_is_usable(slope: float, spread: float, n: int, residual_spread: float, established: bool) -> bool:
    if not (established and n >= 8 and spread > 0 and math.isfinite(slope)):
        return False
    if not abs(slope) * float(LOOKBACK_LONG) > 0.35 * spread:
        return False
    return residual_spread < 3.0 * spread


def _quantile(values: list[float], q: float) -> float | None:
    """RobustStats.quantile: linear interpolation (type 7)."""
    v = sorted(x for x in values if math.isfinite(x))
    if not v:
        return None
    if len(v) == 1:
        return v[0]
    pos = min(1.0, max(0.0, q)) * float(len(v) - 1)
    lo = int(math.floor(pos))
    hi = min(len(v) - 1, lo + 1)
    return v[lo] + (v[hi] - v[lo]) * (pos - float(lo))


def _oos_calibration_factor(ring: tuple[float, ...]) -> float:
    """oosCalibrationFactor: how much wider the realised out-of-sample |z| tail is than the model's 97.5 % point,
    shrunk toward 1 while the ring is short. Never below 1."""
    xs = [x for x in ring if math.isfinite(x)]
    q = _quantile(xs, 1 - BAND_ALPHA) if len(xs) >= 20 else None
    if q is None:
        return 1.0
    nominal = _normal_quantile(1 - BAND_ALPHA / 2)
    r = min(OOS_MAX_FACTOR, max(1.0, q / nominal))
    w = min(1.0, float(len(xs)) / float(OOS_FULL_WEIGHT_N))
    return 1 + w * (r - 1)


def _cusum_step(pos: float, neg: float, z: float, phi: float) -> tuple[float, float, int]:
    """Stats.cusumStep: two-sided CUSUM on a daily z (clamped to ±2, divided by the AR(1) long-run factor), each arm
    capped at 1.25·h; the alarm is +1 / −1 when an arm crosses h on this step."""
    p = min(0.95, max(0.0, phi))
    adj = math.sqrt((1 + p) / (1 - p))
    zz = min(CUSUM_CLAMP_Z, max(-CUSUM_CLAMP_Z, z)) / adj
    cap = CUSUM_CAP_FACTOR * CUSUM_H
    new_pos = min(cap, max(0.0, pos + zz - CUSUM_K))
    new_neg = min(cap, max(0.0, neg - zz - CUSUM_K))
    alarm = 0
    if new_pos > CUSUM_H and pos <= CUSUM_H:
        alarm = 1
    if new_neg > CUSUM_H and neg <= CUSUM_H:
        alarm = -1
    return new_pos, new_neg, alarm


def _student_t_lambda(z_long: float) -> float:
    return min(1.0, (NU + 1.0) / (NU + z_long * z_long))


def _borrowed_spread(spread7_raw: float, spread_long: float | None, n_learn: float, established_long: bool,
                     floor: float) -> float:
    raw = max(spread7_raw, floor)
    lambda_s = min(1.0, n_learn / N_BORROW)
    if established_long and spread_long is not None:
        return max(lambda_s * raw + (1.0 - lambda_s) * spread_long, floor)
    return raw


def _lag1_r1(residuals: list[float]) -> float | None:
    if len(residuals) < 3:
        return None
    x, y = residuals[:-1], residuals[1:]
    mx, my = _total(x) / float(len(x)), _total(y) / float(len(y))
    num = dx = dy = 0.0
    for a0, b0 in zip(x, y):
        a, b = a0 - mx, b0 - my
        num += a * b
        dx += a * a
        dy += b * b
    den = math.sqrt(dx * dy)
    return num / den if den > 0 else 0.0


def _n_eff(n: int, r1: float) -> float:
    r = min(0.99, max(-0.99, r1))
    return float(n) * (1.0 - r) / (1.0 + r)


def _clip_pct(x: float) -> int:
    return int(round_half_away(min(100.0, max(0.0, x))))


def _trust_pct(n_ok: int, n_window: int, n_low: int, n_eff: float, n_establish: int, age_last_ok: int | None,
               slope_usable: bool, tonight: str | None) -> int:
    """usualTrustPct with freezeOk 1 and no confounder today (Phase A)."""
    coverage = float(n_ok) / float(max(n_window, 1))
    freshness = max(0.0, 1 - float(age_last_ok) / float(max(STALE_DAYS, 1))) if age_last_ok is not None else 0.0
    quality = float(n_ok) / float(max(n_ok + n_low, 1))
    n_eff_frac = min(n_eff / float(max(n_establish, 1)), 1)
    slope_ok = 1.0 if slope_usable else 0.75
    tonight_factor = 1.0 if tonight == OK else 0.25 if tonight == LOW_QUALITY else 0.0
    data_q = coverage * freshness * quality * n_eff_frac * slope_ok * 1.0 * 1.0
    return _clip_pct(100.0 * data_q * (0.5 + 0.5 * tonight_factor))


def _to_math(native: float, series: Series) -> float | None:
    if not math.isfinite(native):
        return None
    if series.uses_log:
        return math.log(native) if native > 0 else None
    return native


def _to_display(value: float, series: Series) -> float:
    return math.exp(value) if series.uses_log else value


def observation(native: float | None, series: Series, *, sleep_hr_only: bool = False) -> Observation:
    """LongitudinalBaseline.observation: out of range or HR-only sleep is low quality (kept, never trained); no
    value is missing (never zero)."""
    if native is None:
        return Observation(None, MISSING)
    if series.key == "waking_steps":  # a present 0 is a real 0; only an impossible count is low quality
        return Observation(native, LOW_QUALITY if native > series.max_val else OK)
    if native < series.min_val or native > series.max_val or sleep_hr_only:
        return Observation(native, LOW_QUALITY)
    return Observation(native, OK)


def _trainable_native(obs: Observation | None, series: Series) -> float | None:
    if obs is None or obs.status != OK or obs.value is None or not math.isfinite(obs.value):
        return None
    if obs.value < series.min_val or obs.value > series.max_val or (series.uses_log and obs.value <= 0):
        return None
    return obs.value


def _trainable_math(obs: Observation | None, series: Series) -> float | None:
    native = _trainable_native(obs, series)
    return None if native is None else _to_math(native, series)


# --------------------------------------------------------------------------- one day, then the replay


def _score_one_day(t: int, series: Series, by_day: dict[int, Observation], trainable: list[int],
                   carry: Carry) -> Evaluation:
    """scoreOneDay (v2.clinical) with no day logs, habits or trial epoch: every night is clean."""
    floor = series.floor
    today_obs = by_day.get(t)
    today_native = _trainable_native(today_obs, series)
    today_math = None if today_native is None else _to_math(today_native, series)

    position = bisect_right(trainable, t)
    last_ok = trainable[position - 1] if position else None
    stale = True if last_ok is None else t - last_ok > STALE_DAYS

    # The 60-day robust copy from the nights T-60 ... T-8.
    last_long_night = t - GAP_DAYS - 1
    long_epochs = range(t - LOOKBACK_LONG, last_long_night + 1)
    long_pairs = [(e, x) for e in long_epochs if (x := _trainable_math(by_day.get(e), series)) is not None]
    n_long_low = sum(1 for e in long_epochs if (o := by_day.get(e)) is not None and o.status == LOW_QUALITY)
    live_copy = _window_copy(long_pairs, floor, N_LONG_SHOW, t - LOOKBACK_LONG, last_long_night)

    # The copy used today: the pre-change copy while a change episode is young, else the live copy, else (fewer
    # than four nights in the window) the last published centre and spread, held.
    ref_copy = live_copy
    long_held = holding_for_change = False
    if carry.held_copy_long is not None and carry.hold_until_epoch is not None and t <= carry.hold_until_epoch:
        ref_copy, long_held, holding_for_change = carry.held_copy_long, True, True
    center_long = None if ref_copy is None else ref_copy.center
    spread_long = None if ref_copy is None else ref_copy.scale
    n_long = 0 if ref_copy is None else ref_copy.n
    if ref_copy is None and carry.center_long is not None and carry.spread_long is not None:
        center_long, spread_long, n_long, long_held = carry.center_long, carry.spread_long, carry.n_long, True
        if long_pairs:  # the held copy is as fresh as the window's last trainable night
            last_ok = long_pairs[-1][0]
            stale = t - last_ok > STALE_DAYS
    established_long = n_long >= series.n_long_established
    show_long = n_long >= N_LONG_SHOW and center_long is not None

    # Slope: a significance-tested trend of the newest 28 long nights. Reported only; never moves the centre.
    slope_pairs = long_pairs[-SLOPE_FIT_NIGHTS:]
    trend = _trend(slope_pairs)
    spread_or_floor = floor if spread_long is None else spread_long
    slope_usable = (trend is not None and trend.p < TREND_ALPHA and (trend.lower > 0 or trend.upper < 0)
                    and _slope_is_usable(trend.slope, spread_or_floor, len(slope_pairs), spread_or_floor,
                                         established_long))

    # The predictive scale of the reference copy and its band multiplier.
    cal_factor = _oos_calibration_factor(carry.oos_abs_z)
    pred_scale = spread_long if ref_copy is None else ref_copy.predictive_scale
    df_long = max(float(n_long) - 1, 2.0) if ref_copy is None else ref_copy.df
    if spread_long is not None and spread_long > 0 and pred_scale is not None:
        k_used = _student_t_critical(BAND_ALPHA, df_long) * (pred_scale / spread_long) * cal_factor
    else:
        k_used = series.k_band
    z_pred_long = None
    if today_math is not None and center_long is not None and pred_scale is not None and pred_scale > 0:
        z_pred_long = (today_math - center_long) / pred_scale

    # Two-sided CUSUM on tonight's predictive z (established reference, trainable night only).
    pos, neg = carry.cusum_pos, carry.cusum_neg
    cusum_last = carry.cusum_last_epoch
    run_pos, run_neg = carry.cusum_run_start_pos, carry.cusum_run_start_neg
    direction, onset, alarm_epoch = carry.change_direction, carry.change_onset_epoch, carry.change_alarm_epoch
    held_copy, hold_until = carry.held_copy_long, carry.hold_until_epoch
    oos_abs_z = list(carry.oos_abs_z)
    oos_pending = dict(carry.oos_pending)
    last_episode_direction, last_episode_alarm = carry.last_episode_direction, carry.last_episode_alarm_epoch
    if hold_until is not None and t > hold_until:
        held_copy = hold_until = None
    if established_long and z_pred_long is not None:
        if cusum_last is not None and t - cusum_last > CUSUM_MAX_GAP_DAYS:   # a long gap resets both arms
            pos = neg = 0.0
            run_pos = run_neg = None
            direction, onset, alarm_epoch, held_copy, hold_until = 0, None, None, None, None
        phi = PHI_FALLBACK if ref_copy is None else ref_copy.phi
        was_pos, was_neg = pos, neg
        pos, neg, alarm = _cusum_step(was_pos, was_neg, z_pred_long / cal_factor, phi)
        if was_pos == 0 and pos > 0:
            run_pos = t
        if pos == 0:
            run_pos = None
        if was_neg == 0 and neg > 0:
            run_neg = t
        if neg == 0:
            run_neg = None
        if alarm != 0 and direction != alarm:
            direction = alarm
            run_start = run_pos if alarm > 0 else run_neg
            onset = t if run_start is None else run_start
            alarm_epoch = t
            if held_copy is None and ref_copy is not None:   # hold the pre-change copy for 28 days
                held_copy, hold_until = ref_copy, t + CHANGE_HOLD_DAYS
        # The episode stays open while its arm is above h.
        if direction > 0 and pos <= CUSUM_H:
            direction = 0
        elif direction < 0 and neg <= CUSUM_H:
            direction = 0
        if direction == 0:
            onset = alarm_epoch = held_copy = hold_until = None
        cusum_last = t
        # Out-of-sample tail ring: tonight's |z| waits 14 days; an alarm drops every waiting night from its onset,
        # so the nights of a real change never widen the band that must detect it.
        if alarm_epoch == t and onset is not None:
            oos_pending = {e: v for e, v in oos_pending.items() if e < onset}
            last_episode_direction, last_episode_alarm = direction, t
        if direction == 0:
            oos_pending[t] = abs(z_pred_long)
        for e in sorted(oos_pending):
            if t - e >= OOS_DELAY_DAYS:
                oos_abs_z.append(oos_pending.pop(e))
        if len(oos_abs_z) > OOS_RING:
            oos_abs_z = oos_abs_z[len(oos_abs_z) - OOS_RING:]
    cusum_s = max(pos, neg)
    p_change = min(1.0, cusum_s / CUSUM_H)
    regime_shift = direction != 0

    # The week copy (span7 nights; ten for HRV): Student-t learn weights against the 60-day centre.
    week_epochs = range(t - series.span7, t)
    week_math: list[float | None] = []
    lambdas: list[float] = []
    n7 = 0
    for e in week_epochs:
        x = _trainable_math(by_day.get(e), series)
        if x is None:
            week_math.append(None)
            lambdas.append(0.0)
            continue
        n7 += 1
        lam = 1.0
        if established_long and center_long is not None and spread_long is not None and spread_long > 0:
            lam = _student_t_lambda((x - center_long) / spread_long)
        week_math.append(x)
        lambdas.append(lam)
    n_learn = _total(lambdas)
    n7_low = sum(1 for e in week_epochs if (o := by_day.get(e)) is not None and o.status == LOW_QUALITY)

    raw_num = raw_den = learn_num = learn_den = 0.0
    mad_pool: list[tuple[float, float]] = []
    for i, x in enumerate(week_math):
        if x is None:
            continue
        w_raw = series.alpha * math.pow(1.0 - series.alpha, float(series.span7 - 1 - i))
        raw_num += w_raw * x
        raw_den += w_raw
        w_learn = w_raw * lambdas[i]
        learn_num += w_learn * x
        learn_den += w_learn
        mad_pool.append((x, lambdas[i]))
    center7_raw = raw_num / raw_den if raw_den > 0 else None

    center7: float | None = None
    spread7: float | None = None
    week_held = False
    if n_learn >= float(N7_SHOW) and learn_den > 0:
        center7 = learn_num / learn_den
    elif carry.center7 is not None and n7 >= N7_SHOW:
        center7, spread7, week_held = carry.center7, carry.spread7, True
    if center7 is not None and not week_held:
        strong = [x for x, lam in mad_pool if lam >= 0.5]
        source = strong if len(strong) >= 3 else [x for x, _ in mad_pool]
        spread7 = _borrowed_spread(_small_sample_spread(source, center7, floor), spread_long, n_learn,
                                   established_long, floor)
    show7 = n7 >= N7_SHOW and (center7 is not None or center7_raw is not None)
    if show7 and center7 is None and center7_raw is not None:
        center7 = center7_raw
        spread7 = _borrowed_spread(_small_sample_spread([x for x, _ in mad_pool], center7_raw, floor), spread_long,
                                   n_learn, established_long, floor)

    def z_score(center: float | None, spread: float | None) -> float | None:
        if today_math is None or center is None or spread is None or not spread > 0:
            return None
        return (today_math - center) / spread

    z7 = z_score(center7, spread7)
    z_long = z_score(center_long, spread_long)
    # The week band: a predictive t interval with the learn mass as its n.
    k7 = series.k_band
    if spread7 is not None and spread7 > 0:
        nn = max(n_learn, 1.0)
        se = MEDIAN_SE_FACTOR * spread7 / math.sqrt(nn)
        k7 = _student_t_critical(BAND_ALPHA, max(nn - 1, 2.0)) * (math.sqrt(spread7 * spread7 + se * se) / spread7)

    week_values = [x for x in week_math if x is not None]
    r1_week = _lag1_r1([v - (center7 if center7 is not None else v) for v in week_values])
    n_eff7 = _n_eff(n7, r1_week or 0.0)
    n_eff_long = _n_eff(n_long, PHI_FALLBACK) if ref_copy is None else ref_copy.n_eff
    age_last = None if last_ok is None else t - last_ok
    tonight = today_obs.status if today_obs is not None else None
    trust7 = _trust_pct(n7, series.span7, n7_low, n_eff7, series.span7, age_last, True, tonight)
    # v2: the slope never moves the centre, so an unusable slope no longer discounts trust.
    trust_long = _trust_pct(n_long, LONG_SLOTS, n_long_low, n_eff_long, series.n_long_established, age_last, True,
                            tonight)

    def snapshot(center: float | None, spread: float | None, n: int, z: float | None, held: bool,
                 k: float) -> Copy | None:
        if center is None or spread is None or n <= 0:
            return None
        return Copy(center, spread, _to_display(center, series), _to_display(center - k * spread, series),
                    _to_display(center + k * spread, series), n, z, held)

    copy7 = snapshot(center7, spread7, n7, z7, week_held, k7) if show7 else None
    copy_long = snapshot(center_long, spread_long, n_long, z_long, long_held, k_used) if show_long else None
    new_carry = Carry(center7=center7 if center7 is not None else carry.center7,
                      spread7=spread7 if spread7 is not None else carry.spread7,
                      center_long=center_long if center_long is not None else carry.center_long,
                      spread_long=spread_long if spread_long is not None else carry.spread_long,
                      n_long=n_long, established_long=established_long, cusum_s=cusum_s,
                      cusum_pos=pos, cusum_neg=neg, cusum_last_epoch=cusum_last,
                      cusum_run_start_pos=run_pos, cusum_run_start_neg=run_neg,
                      change_direction=direction, change_onset_epoch=onset, change_alarm_epoch=alarm_epoch,
                      held_copy_long=held_copy, hold_until_epoch=hold_until,
                      oos_abs_z=tuple(oos_abs_z), oos_pending=tuple(sorted(oos_pending.items())),
                      last_episode_direction=last_episode_direction, last_episode_alarm_epoch=last_episode_alarm)
    return Evaluation(as_of=date.fromordinal(t + _EPOCH), series=series.key, today=today_native,
                      tonight_status=tonight, copy7=copy7, copy_long=copy_long, n7=n7, n_learn=n_learn,
                      n_long=n_long, z7=z7, z_long=z_long, show7=show7, show_long=show_long,
                      established_long=established_long, stale=stale, trust7=trust7, trust_long=trust_long,
                      slope_usable=slope_usable, expected_long=center_long, k_used=k_used, p_change=p_change,
                      regime_shift=regime_shift, carry=new_carry, k7=k7, z_pred_long=z_pred_long,
                      calibration_factor=cal_factor, holding_copy=holding_for_change, ref_copy=ref_copy)


def _empty(as_of: date, series: Series) -> Evaluation:
    """emptyEvaluation (k_used keeps LBEvaluation's default 2, as in Swift)."""
    return Evaluation(as_of=as_of, series=series.key, today=None, tonight_status=None, copy7=None, copy_long=None,
                      n7=0, n_learn=0.0, n_long=0, z7=None, z_long=None, show7=False, show_long=False,
                      established_long=False, stale=True, trust7=0, trust_long=0, slope_usable=False,
                      expected_long=None, k_used=2.0, p_change=0.0, regime_shift=False, carry=Carry())


def evaluate(observations: dict[date, Observation], as_of: date, series: str) -> Evaluation:
    """`evaluate(asOf:series:observations:)` with replay: every night from the first observation through `as_of`
    is scored in turn, carrying the held copies, the CUSUM and the tail ring, exactly as the phone does."""
    spec = SERIES[series]
    by_day = {epoch_day(d): o for d, o in observations.items()}
    trainable = sorted(e for e, o in by_day.items() if _trainable_math(o, spec) is not None)
    t = epoch_day(as_of)
    carry, last = Carry(), None
    for day in range(min(by_day) if by_day else t, t + 1):
        last = _score_one_day(day, spec, by_day, trainable, carry)
        carry = last.carry
    return last if last is not None else _empty(as_of, spec)


class History(dict):
    """One job's nightly rows by day. Each series' evaluation at a night is computed once and kept here, so it lives
    and dies with the job's data (never across jobs or users)."""

    def __init__(self, rows: dict[date, dict[str, Any]] | None = None) -> None:
        super().__init__(rows or {})
        self.evaluations: dict[tuple[str, date], Evaluation] = {}


def evaluate_rows(rows: dict[date, dict[str, Any]], night: date, series: str) -> Evaluation:
    """`evaluate` over nightly rows (read as the phone reads hosted nights), once per job for a History."""
    memo = getattr(rows, "evaluations", None)
    if memo is not None and (series, night) in memo:
        return memo[(series, night)]
    ev = evaluate(native_values(rows, series), night, series)
    if memo is not None:
        memo[(series, night)] = ev
    return ev


def native_values(rows: dict[date, dict[str, Any]], series: str) -> dict[date, Observation]:
    """One series out of the nightly rows, as the phone reads hosted nights (ServerScoreRepository: a value that is
    not a finite number is no value; resting HR is an integer there, rounded half away from zero; a row without the
    value is a missing night, never zero)."""
    spec, column = SERIES[series], COLUMNS[series]
    out: dict[date, Observation] = {}
    for day, row in rows.items():
        raw = row.get(column)
        number = None if raw is None or isinstance(raw, bool) else float(raw)
        if number is not None and not math.isfinite(number):
            number = None
        if number is not None and series in INTEGER_SERIES:
            number = round_half_away(number)
        out[day] = observation(number, spec)
    return out


def _is_off(z: float | None, k: float) -> bool:
    return z is not None and abs(z) >= k


def verdict(ev: Evaluation) -> Verdict:
    """LongitudinalBaseline.vitalVerdict: the week copy when it is trusted, else the 60-day one; off when a trusted
    copy's |z| reaches the 60-day band multiplier (k_used, for either copy, as in Swift); learning without a trusted
    copy; no reading without tonight's value."""
    week = ev.copy7 if ev.show7 and ev.trust7 >= TRUST_HIDE_THRESHOLD else None
    long = ev.copy_long if ev.show_long and ev.trust_long >= TRUST_HIDE_THRESHOLD else None
    copy = week if week is not None else long
    band = (copy.band_lo_display, copy.band_hi_display, copy.center_display) if copy else (None, None, None)
    if ev.today is None:
        return Verdict(ev.series, LEARNING if copy is None else NO_READING, None, *band, from_week=week is not None)
    if copy is None:
        return Verdict(ev.series, LEARNING, ev.today, None, None, None, from_week=False)
    off_week = week is not None and _is_off(ev.z7, ev.k_used)
    off_long = long is not None and _is_off(ev.z_long, ev.k_used)
    return Verdict(ev.series, OFF if off_week or off_long else IN_RANGE, ev.today, *band, from_week=week is not None,
                   off_week=off_week, off_long=off_long)
