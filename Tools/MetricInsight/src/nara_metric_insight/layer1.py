"""Layer 1, the phone Baseline (LongitudinalBaseline, param set v1.review), ported for the night vitals and steps.

A line-by-line port of `LongitudinalBaseline.evaluate` with replay and `scoreOneDay`, for the five night vitals and
the daily steps series,
(Packages/StrandAnalytics/Sources/StrandAnalytics/LongitudinalBaseline.swift, LongitudinalBaselineReview.swift,
LongitudinalBaselineTrial.swift) and of the verdict the Home ring and the Monitor show
(`LongitudinalBaseline.vitalVerdict`), so an explanation calls a night "in range" or "off usual" exactly when the
app does for the same nightly values.

Phase A only. Treatment trials, day logs (felt ill, habits, confounders) and acute flags live on the phone, so they
are neutral here, as on a phone with none logged. Nights are keyed by the day they end, as everywhere else.
Pinned to the Swift: tests/data/layer1_expected.json holds what the app's own code returns for the tapes in
tests/data/layer1_cases.json (recorded by StrandAnalyticsTests/LayerOneServerMirrorTests, which also fails when
Layer 1 changes), and tests/test_layer1.py holds this port to it.
"""

from __future__ import annotations

import math
from bisect import bisect_right
from dataclasses import dataclass
from datetime import date
from typing import Any

PARAM_SET = "v1.review"
LOOKBACK_LONG, GAP_DAYS = 60, 7
LONG_SLOTS = LOOKBACK_LONG - GAP_DAYS        # 53: nights T-60 .. T-8
K_LEARN = 2.0
NU = 4.0
K_CUSUM, H_CUSUM, P_THR = 0.5, 20.0, 0.90
N7_SHOW = N_LONG_SHOW = 4
N_BORROW = 7.0
P_REGIME = 0.35
STALE_DAYS = 14
MAD_SCALE = 1.4826
SLOPE_FIT_NIGHTS = 28
SLOPE_HORIZON_DAYS = 30
TRUST_HIDE_THRESHOLD = 35                    # LongitudinalBaseline.trustHideThreshold

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
    k_band: float
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
class Carry:
    center7: float | None = None
    spread7: float | None = None
    center_long: float | None = None
    spread_long: float | None = None
    n_long: int = 0
    established_long: bool = False
    cusum_s: float = 0.0


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
    slope_usable: bool
    expected_long: float | None
    k_used: float
    p_change: float
    regime_shift: bool
    carry: Carry


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
    s = sorted(values)
    if not s:
        return None
    n = len(s)
    return s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def _robust_spread(values: list[float], center: float, floor: float) -> float:
    mad = _median([abs(v - center) for v in values])
    return max(MAD_SCALE * (0.0 if mad is None else mad), floor)


def _trim_long_list(values: list[float], floor: float) -> tuple[list[float], bool]:
    if not values:
        return [], False
    m0 = _median(values)
    s0 = _robust_spread(values, m0, floor)
    s1 = [v for v in values if abs(v - m0) / s0 < K_LEARN]
    absorbed = len(s1) / len(values) >= (1.0 - P_REGIME) and len(s1) >= N_LONG_SHOW
    return (s1 if absorbed else values), absorbed


def _theil_sen(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) != len(ys) or len(xs) < 2:
        return None
    slopes = []
    for i in range(len(xs)):
        for j in range(i + 1, len(xs)):
            dx = xs[j] - xs[i]
            if abs(dx) < 1e-12:
                continue
            slopes.append((ys[j] - ys[i]) / dx)
    return _median(slopes)


def _recent_block_is_level_step(pairs: list[tuple[int, float]], older_median: float, spread: float) -> bool:
    newest = pairs[-7:]
    if len(newest) < 7 or not spread > 0:
        return False
    ref = _median([v for _, v in pairs[:-7]])
    ref = older_median if ref is None else ref
    recent = _median([v for _, v in newest])
    if recent is None or not math.isfinite(ref):
        return False
    return abs(recent - ref) / spread >= K_LEARN * 0.75


def _slope_is_usable(slope: float, spread: float, n: int, residual_spread: float, established: bool) -> bool:
    if not (established and n >= 8 and spread > 0 and math.isfinite(slope)):
        return False
    if not abs(slope) * float(LOOKBACK_LONG) > 0.35 * spread:
        return False
    return residual_spread < 3.0 * spread


def _expected_on_path(center: float, slope: float, usable: bool, day: int, origin: int, last_night: int) -> float:
    if not usable:
        return center
    raw = day - origin
    capped_from_last = min(day, last_night + SLOPE_HORIZON_DAYS) - origin
    dt = float(min(max(raw, -SLOPE_HORIZON_DAYS), SLOPE_HORIZON_DAYS))
    cap_dt = float(min(max(capped_from_last, -SLOPE_HORIZON_DAYS), SLOPE_HORIZON_DAYS))
    if day - last_night > SLOPE_HORIZON_DAYS:
        return center + slope * cap_dt
    return center + slope * dt


def _k_band(table_k: float, abs_z: list[float], n_long: int) -> float:
    if n_long < 14 or len(abs_z) < 14:
        return table_k
    s = sorted(z for z in abs_z if math.isfinite(z))
    if len(s) < 14:
        return table_k
    empirical = s[min(len(s) - 1, max(0, int((float(len(s)) - 1) * 0.95)))]
    return min(max(empirical, table_k * 0.75), table_k * 1.40)


def _student_t_lambda(z_long: float) -> float:
    return min(1.0, (NU + 1.0) / (NU + z_long * z_long))


def _borrowed_spread(spread7_raw: float, spread_long: float | None, n_learn: float, established_long: bool,
                     floor: float) -> float:
    raw = max(spread7_raw, floor)
    lambda_s = min(1.0, n_learn / N_BORROW)
    if established_long and spread_long is not None:
        return max(lambda_s * raw + (1.0 - lambda_s) * spread_long, floor)
    return raw


def _cusum_step(previous: float, value: float, center: float, spread: float) -> float:
    if not spread > 0:
        return previous
    return max(0.0, previous + abs(value - center) / spread - K_CUSUM)


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
    floor = series.floor
    today_obs = by_day.get(t)
    today_native = _trainable_native(today_obs, series)
    today_math = None if today_native is None else _to_math(today_native, series)

    position = bisect_right(trainable, t)
    last_ok = trainable[position - 1] if position else None
    stale = True if last_ok is None else t - last_ok > STALE_DAYS

    long_epochs = range(t - LOOKBACK_LONG, t - GAP_DAYS)          # T-60 ... T-8
    long_pairs = [(e, x) for e in long_epochs if (x := _trainable_math(by_day.get(e), series)) is not None]
    long_train = [x for _, x in long_pairs]
    n_long_low = sum(1 for e in long_epochs if (o := by_day.get(e)) is not None and o.status == LOW_QUALITY)
    kept, absorbed = _trim_long_list(long_train, floor)
    last_long_update = long_pairs[-1][0] if long_pairs else None

    center_long: float | None = None
    spread_long: float | None = None
    n_long, long_held = 0, False
    if absorbed and (med := _median(kept)) is not None:
        center_long, spread_long, n_long = med, _robust_spread(kept, med, floor), len(kept)
    elif (med := _median(long_train)) is not None and len(long_train) >= N_LONG_SHOW:
        center_long, spread_long, n_long = med, _robust_spread(long_train, med, floor), len(long_train)
    elif carry.center_long is not None and carry.spread_long is not None:
        center_long, spread_long, n_long, long_held = carry.center_long, carry.spread_long, carry.n_long, True
    if long_held and last_long_update is not None:
        last_ok = last_long_update
        stale = t - last_long_update > STALE_DAYS
    established_long = n_long >= series.n_long_established
    show_long = n_long >= N_LONG_SHOW and center_long is not None

    slope_pairs = long_pairs[-SLOPE_FIT_NIGHTS:]
    slope = _theil_sen([float(e) for e, _ in slope_pairs], [v for _, v in slope_pairs])
    last_long_night = long_pairs[-1][0] if long_pairs else t - GAP_DAYS - 1
    origin = last_long_night if not slope_pairs else (slope_pairs[0][0] + slope_pairs[-1][0]) // 2
    recent_step = _recent_block_is_level_step(long_pairs, center_long if center_long is not None else 0.0,
                                              spread_long if spread_long is not None else floor)
    # Anchor the path so it passes through the last long night: the intercept stays the long median.
    if not recent_step and slope is not None and center_long is not None and slope_pairs and abs(slope) > 1e-9:
        last_e, last_v = slope_pairs[-1]
        dt = (last_v - center_long) / slope
        if math.isfinite(dt) and abs(dt) < float(LOOKBACK_LONG * 2):
            origin = last_e - int(round_half_away(dt))
    residual_spread = spread_long if spread_long is not None else floor
    if not recent_step and center_long is not None and slope is not None and slope_pairs:
        residual_spread = _robust_spread([v - (center_long + slope * float(e - origin)) for e, v in slope_pairs],
                                         0.0, floor)
    slope_usable = (not recent_step
                    and _slope_is_usable(slope if slope is not None else 0.0,
                                         spread_long if spread_long is not None else floor,
                                         len(slope_pairs), residual_spread, established_long)
                    and (t - last_long_night) <= SLOPE_HORIZON_DAYS)
    slope_value = slope if slope is not None else 0.0

    # CUSUM on the night that just aged into the long window; a usable slope is the drift and resets it.
    cusum = carry.cusum_s
    if slope_usable:
        cusum = 0.0
    elif (carry.center_long is not None and carry.spread_long is not None
          and (x := _trainable_math(by_day.get(t - (GAP_DAYS + 1)), series)) is not None):
        cusum = _cusum_step(cusum, x, carry.center_long, carry.spread_long)
    p_change = 1.0 - math.exp(-cusum / H_CUSUM)
    regime_shift = p_change >= P_THR and not slope_usable
    if (regime_shift and carry.center_long is not None and carry.spread_long is not None
            and carry.established_long):
        center_long, spread_long = carry.center_long, carry.spread_long
        n_long, long_held = max(n_long, carry.n_long), True
        if last_long_update is not None:
            last_ok = last_long_update
            stale = t - last_long_update > STALE_DAYS

    def on_path(day: int, center: float) -> float:
        return _expected_on_path(center, slope_value, slope_usable, day, origin, last_long_night)

    expected_today = None if center_long is None else on_path(t, center_long)
    abs_z = ([abs(v - on_path(e, center_long)) / spread_long for e, v in long_pairs]
             if center_long is not None and spread_long is not None and spread_long > 0 else [])
    k_used = _k_band(series.k_band, abs_z, n_long)

    # The 7-day copy (span7 nights; ten for HRV): Student-t learn weights against the long path.
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
            lam = _student_t_lambda((x - on_path(e, center_long)) / spread_long)
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
        spread7 = _borrowed_spread(_robust_spread(source, center7, floor), spread_long, n_learn, established_long,
                                   floor)
    show7 = n7 >= N7_SHOW and (center7 is not None or center7_raw is not None)
    if show7 and center7 is None and center7_raw is not None:
        center7 = center7_raw
        spread7 = _borrowed_spread(_robust_spread([x for x, _ in mad_pool], center7_raw, floor), spread_long,
                                   n_learn, established_long, floor)

    def z_score(center: float | None, spread: float | None) -> float | None:
        if today_math is None or center is None or spread is None or not spread > 0:
            return None
        return (today_math - center) / spread

    z7 = z_score(center7, spread7)
    z_long = z_score(expected_today if expected_today is not None else center_long, spread_long)

    week_values = [x for x in week_math if x is not None]
    r1_week = _lag1_r1([v - (center7 if center7 is not None else v) for v in week_values])
    r1_long = _lag1_r1([v - on_path(e, center_long if center_long is not None else v) for e, v in long_pairs])
    age_last = None if last_ok is None else t - last_ok
    tonight = today_obs.status if today_obs is not None else None
    trust7 = _trust_pct(n7, series.span7, n7_low, _n_eff(n7, r1_week or 0.0), series.span7, age_last, True, tonight)
    trust_long = _trust_pct(n_long, LONG_SLOTS, n_long_low, _n_eff(n_long, r1_long or 0.0),
                            series.n_long_established, age_last, slope_usable, tonight)

    def snapshot(center: float | None, spread: float | None, n: int, z: float | None, held: bool) -> Copy | None:
        if center is None or spread is None or n <= 0:
            return None
        return Copy(center, spread, _to_display(center, series), _to_display(center - k_used * spread, series),
                    _to_display(center + k_used * spread, series), n, z, held)

    copy7 = snapshot(center7, spread7, n7, z7, week_held) if show7 else None
    copy_long = (snapshot(expected_today if expected_today is not None else center_long, spread_long, n_long,
                          z_long, long_held) if show_long else None)
    new_carry = Carry(center7=center7 if center7 is not None else carry.center7,
                      spread7=spread7 if spread7 is not None else carry.spread7,
                      center_long=center_long if center_long is not None else carry.center_long,
                      spread_long=spread_long if spread_long is not None else carry.spread_long,
                      n_long=n_long, established_long=established_long, cusum_s=cusum)
    return Evaluation(as_of=date.fromordinal(t + _EPOCH), series=series.key, today=today_native,
                      tonight_status=tonight, copy7=copy7, copy_long=copy_long, n7=n7, n_learn=n_learn,
                      n_long=n_long, z7=z7, z_long=z_long, show7=show7, show_long=show_long,
                      established_long=established_long, stale=stale, trust7=trust7, trust_long=trust_long,
                      slope_usable=slope_usable, expected_long=expected_today, k_used=k_used, p_change=p_change,
                      regime_shift=regime_shift, carry=new_carry)


def _empty(as_of: date, series: Series) -> Evaluation:
    return Evaluation(as_of=as_of, series=series.key, today=None, tonight_status=None, copy7=None, copy_long=None,
                      n7=0, n_learn=0.0, n_long=0, z7=None, z_long=None, show7=False, show_long=False,
                      established_long=False, stale=True, trust7=0, trust_long=0, slope_usable=False,
                      expected_long=None, k_used=series.k_band, p_change=0.0, regime_shift=False, carry=Carry())


def evaluate(observations: dict[date, Observation], as_of: date, series: str) -> Evaluation:
    """`evaluate(asOf:series:observations:)` with replay: every night from the first observation through `as_of`
    is scored in turn, carrying the held copies and the CUSUM, exactly as the phone does."""
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
    copy's |z| reaches its k band; learning without a trusted copy; no reading without tonight's value."""
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
