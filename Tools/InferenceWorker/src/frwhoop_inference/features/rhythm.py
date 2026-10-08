"""Observed multi-day skin-temperature rhythm, its phase relations and drift, and the
document-level rest-activity rhythm (spec-02 sections 3 and 4; docs/spec-02/CONTRACT.md
5.1 and 5.4).

Owner: temperature rhythm. Pure functions over the request's bounded ``rhythm_history``
(hourly UTC bins aggregated near the source by the worker). Every return is a JSON wire
block; missing data is ``None`` with a machine-readable reason, never 0.

Definitions (``skin-temp-rhythm-1``)
------------------------------------
* A bin is SUPPORTED for a signal when its value is present and it carries at least
  ``RhythmConfig.hour_min_valid_minutes`` valid minutes (the worker's minute rules travel in
  ``rhythm_history.rules``).
* A QUALIFYING day has supported bins for at least ``CONFIG.rhythm_day_coverage`` (80 %) of
  its true local-day length (23 / 24 / 25 h on DST days). The gate is the thermal module's
  existing one: >= ``CONFIG.rhythm_min_days`` (5) qualifying days and every 6-hour local
  quadrant observed. A night-only trace leaves the 06-12 / 12-18 quadrants unobserved and is
  withheld ``insufficient_daytime_temperature`` (never extrapolated into a full-day rhythm).
* Cosinor: single-component 24 h least-squares fit
  ``y = M + a cos(w t) + b sin(w t)``, ``w = 2 pi / 24 h``, on the supported bins of the
  qualifying days. ``t`` is the bin's midpoint in ACTUAL elapsed UTC time (unix time has no
  DST, so the fit survives midnight and DST by construction). Bins are weighted by their
  support (valid minutes / 60, normalised to mean 1). Amplitude ``sqrt(a^2 + b^2)``, acrophase
  ``atan2(b, a) / w`` (UTC hours), reported also in local clock hours of the claim's zone.
* Uncertainty: the ordinary weighted-least-squares covariance ``s^2 (X'WX)^-1`` with
  ``s^2 = sum(w r^2) / (n - 3)`` propagated with the delta method (Bingham et al. 1982; the
  same first-order propagation CosinorPy uses), AND a delete-one-day jackknife (hourly
  residuals are autocorrelated within a day, so the OLS SE alone is optimistic). The
  reported ``acrophase_se_h`` / ``amplitude_se_c`` are the LARGER of the two.
* Phase availability: ``zero_amplitude`` when the amplitude is below
  ``amplitude_floor_c`` or below ``amplitude_min_se_ratio`` x its SE (indistinguishable from
  zero); ``unstable_phase`` when the acrophase SE exceeds ``max_acrophase_se_h`` or the
  circular SD of the qualifying days' own acrophases exceeds
  ``max_daily_phase_circular_sd_h``; ``mixed_devices`` when the history mixes conversion
  identities / device families (scales are incompatible, so nothing is fitted).
* Temperature regularity (``is`` / ``iv``; named temperature regularity, not rest-activity):
  IS = n * sum_h (xbar_h - xbar)^2 / (p * sum_i (x_i - xbar)^2) over the supported bins of
  the qualifying days, grouped by LOCAL clock hour (p = observed hour-of-day groups);
  IV = [sum over valid pairs (x_i - x_{i-1})^2 / P] / [sum_i (x_i - xbar)^2 / N], where a
  valid pair is two supported bins exactly 3600 s apart in UTC (``iv_definition =
  consecutive_valid_hour_pairs_across_midnight``: pairs cross midnight; a real gap breaks
  the pair; DST never joins non-adjacent hours). With no gap P = N - 1 and this is exactly
  the pyActigraphy / Witting formula n sum(dx^2) / ((n - 1) sum (x - xbar)^2); with gaps it is
  pyActigraphy's own pandas behaviour (``diff().pow(2).mean() / var(ddof=0)`` over a NaN-gapped
  regular grid), i.e. the valid-pair normalisation.
* Phase relations: circular differences HR acrophase - temperature acrophase and sleep
  midpoint - temperature acrophase, in [-12, 12) h, only when both phases are independently
  supported (the HR rhythm is fitted from the same history's HR bins with the same gate; the
  sleep midpoint is the circular mean of >= ``sleep_midpoint_min_nights`` sleep-period
  midpoints). Descriptive timing differences only; no causal or clinical meaning.
* Phase drift: the slope of the qualifying days' own UTC acrophases (unwrapped) against
  elapsed UTC days. Time-zone changes and DST transitions inside the history are listed as
  ``clock_changes`` (relabelings of the clock, never physiological drift: drift is computed in
  UTC, so a relabeling alone yields zero drift). ``observed_realignment`` describes, after the
  latest clock change, how far the UTC phase has moved relative to the shift needed to keep
  the same local phase. It is retrospective and descriptive; no forecast.

Rest-activity rhythm (``rest-activity-1``)
------------------------------------------
IS / IV / L5 / M10 / RA on ONE declared signal, ``gravity_movement_seconds_per_minute``
(seconds per minute whose 1 Hz gravity vector changed by >= the rules' threshold from the
previous second, among true one-second adjacencies of worn minutes), at hourly epochs.
pyActigraphy-compatible formulas, NOT binarised, no count threshold (the signal is not an
activity count), gaps stay gaps (never filled with activity-decoder labels). L5 / M10 are the
least / most active 5 / 10 consecutive hours of the cyclic average 24 h local-clock profile;
RA = (M10 - L5) / (M10 + L5). Requires the same >= 5 qualifying days (movement supported in
>= 80 % of local hours) and every quadrant; otherwise withheld with the precise reason.
LIDS, kRA / kAR and 24hAlign are deferred.
"""

from __future__ import annotations

import math
import statistics
from dataclasses import asdict, dataclass
from datetime import datetime, timezone as _tz
from typing import Any, Callable, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import numpy as np

from .config import CONFIG, SleepFeaturesConfig
from .contract import NightIn, RhythmHistoryIn, SleepFeaturesRequest, json_finite

METHOD_VERSION = "skin-temp-rhythm-1"
REST_ACTIVITY_METHOD_VERSION = "rest-activity-1"
IV_DEFINITION = "consecutive_valid_hour_pairs_across_midnight"
REST_ACTIVITY_SIGNAL = "gravity_movement_seconds_per_minute"
EPOCH_SECONDS = 3600
PERIOD_H = 24.0
OMEGA = 2.0 * math.pi / PERIOD_H
_EPS = 1e-12


@dataclass(frozen=True)
class RhythmConfig:
    """Versioned project defaults for the rhythm blocks (reported inside each block)."""

    #: a bin supports a signal when it carries >= this many valid minutes
    hour_min_valid_minutes: int = 30
    #: amplitude below this is treated as zero (temperature, degC)
    amplitude_floor_c: float = 0.05
    #: HR rhythm amplitude floor (bpm)
    hr_amplitude_floor_bpm: float = 1.0
    #: amplitude must be at least this many SEs above zero for a defined phase
    amplitude_min_se_ratio: float = 2.0
    #: acrophase SE (max of delta-method and day-jackknife) above which the phase is unstable
    max_acrophase_se_h: float = 1.5
    #: circular SD of the qualifying days' own acrophases above which the phase is unstable
    max_daily_phase_circular_sd_h: float = 3.0
    #: phase drift needs this many daily phases
    drift_min_days: int = 5
    #: sleep-midpoint phase needs this many non-nap sleep periods inside the history span
    sleep_midpoint_min_nights: int = 5
    #: observed re-alignment needs daily phases on both sides of the clock change
    realignment_min_days_before: int = 2
    realignment_min_days_after: int = 1
    #: a clock change smaller than this is listed but not used for re-alignment
    min_clock_shift_h: float = 0.5
    #: local clock hours counted as daytime coverage ([start, end)); = quadrants 2 and 3
    daytime_local_hours: tuple[int, int] = (6, 18)
    #: rest-activity gate (same structure as the temperature gate)
    rest_activity_min_days: int = 5
    rest_activity_day_coverage: float = 0.80
    l5_hours: int = 5
    m10_hours: int = 10

    def to_wire(self) -> dict[str, Any]:
        out = asdict(self)
        out["daytime_local_hours"] = list(self.daytime_local_hours)
        return out


RHYTHM_CONFIG = RhythmConfig()

RHYTHM_NOTES = [
    "acrophase is skin-temperature acrophase, not DLMO or core-temperature minimum",
    ("Wrist skin temperature also follows room temperature, bedding, clothing and activity; "
     "the observed rhythm describes the wrist channel only and implies no endogenous clock "
     "phase, melatonin timing or cause."),
    ("is / iv here are TEMPERATURE regularity on hourly skin-temperature bins (local clock "
     "hours for IS; consecutive valid UTC hours across midnight for IV), not rest-activity "
     "regularity."),
    ("Uncertainty is the larger of the OLS delta-method SE and a delete-one-day jackknife; "
     "hourly residuals are autocorrelated, so the OLS SE alone would be optimistic."),
]

REST_ACTIVITY_NOTES = [
    ("Signal: seconds per minute whose 1 Hz gravity vector changed by at least the threshold "
     "from the previous second (an orientation-change proxy that only sees motion surviving "
     "the strap's 1 Hz downsample). It is not an activity count: no count threshold and no "
     "binarisation are applied."),
    ("Hours without worn movement evidence stay missing; activity-decoder labels never fill "
     "observation gaps."),
    "LIDS, kRA/kAR and 24hAlign are deferred.",
]


# ---------------------------------------------------------------------------
# Circular helpers (hours on a 24 h circle)
# ---------------------------------------------------------------------------


def circ_diff_h(a: float, b: float) -> float:
    """Circular difference ``a - b`` in [-12, 12) hours."""
    return ((a - b + 12.0) % PERIOD_H) - 12.0


def circ_mean_h(hours: Sequence[float], weights: Sequence[float] | None = None
                ) -> tuple[float | None, float]:
    """Circular mean (hours in [0, 24)) and mean resultant length R."""
    if not hours:
        return None, 0.0
    w = [1.0] * len(hours) if weights is None else [float(x) for x in weights]
    sw = sum(w)
    if sw <= 0:
        return None, 0.0
    c = sum(wi * math.cos(OMEGA * h) for wi, h in zip(w, hours)) / sw
    s = sum(wi * math.sin(OMEGA * h) for wi, h in zip(w, hours)) / sw
    r = math.hypot(c, s)
    if r <= _EPS:
        return None, 0.0
    return (math.atan2(s, c) / OMEGA) % PERIOD_H, r


def circ_sd_h(hours: Sequence[float]) -> float | None:
    """Circular standard deviation sqrt(-2 ln R), in hours."""
    if len(hours) < 2:
        return None
    _, r = circ_mean_h(hours)
    if r <= _EPS:
        return None
    return math.sqrt(max(0.0, -2.0 * math.log(min(1.0, r)))) / OMEGA


# ---------------------------------------------------------------------------
# Weighted single-component cosinor with delta-method uncertainty
# ---------------------------------------------------------------------------


def _utc_hour_of_day(ts: float) -> float:
    """Elapsed-UTC time of day in hours (unix time is DST-free; 86400 s per day)."""
    return (float(ts) % 86400.0) / 3600.0


@dataclass(frozen=True)
class CosinorSuff:
    """Additive weighted-least-squares sufficient statistics of one group of points.

    Sums over groups give the pooled fit; ``total - group`` gives a delete-one-group fit
    without touching the points again (the jackknife costs 3x3 solves only). The covariance
    ``s^2 (X'WX)^-1`` is invariant to a common rescaling of the weights, so raw support
    weights are used directly.
    """

    xtwx: np.ndarray  # (3, 3)
    xtwy: np.ndarray  # (3,)
    swyy: float
    n: int

    def __add__(self, other: "CosinorSuff") -> "CosinorSuff":
        return CosinorSuff(self.xtwx + other.xtwx, self.xtwy + other.xtwy,
                           self.swyy + other.swyy, self.n + other.n)

    def __sub__(self, other: "CosinorSuff") -> "CosinorSuff":
        return CosinorSuff(self.xtwx - other.xtwx, self.xtwy - other.xtwy,
                           self.swyy - other.swyy, self.n - other.n)


def cosinor_suff(ts: Sequence[float], ys: Sequence[float],
                 ws: Sequence[float] | None = None) -> CosinorSuff | None:
    n = len(ys)
    if len(ts) != n:
        return None
    t = (np.asarray(ts, dtype=float) % 86400.0) / 3600.0
    y = np.asarray(ys, dtype=float)
    w = np.ones(n) if ws is None else np.asarray(ws, dtype=float)
    if n and (np.any(w <= 0) or not np.all(np.isfinite(y))):
        return None
    x = np.column_stack([np.ones(n), np.cos(OMEGA * t), np.sin(OMEGA * t)])
    xw = x * w[:, None]
    return CosinorSuff(xw.T @ x, xw.T @ y, float(np.sum(w * y * y)), n)


def cosinor_from_suff(st: CosinorSuff) -> dict[str, Any] | None:
    """The fit, weighted R2 and delta-method SEs from sufficient statistics."""
    n = st.n
    if n < 4:
        return None
    xtwx = st.xtwx
    eig = np.linalg.eigvalsh(xtwx)
    if eig[0] <= 1e-10 * max(eig[-1], _EPS):
        return None  # all points at (nearly) one clock phase: no cosine is identifiable
    inv = np.linalg.inv(xtwx)
    beta = inv @ st.xtwy
    rss = max(0.0, float(st.swyy - 2.0 * beta @ st.xtwy + beta @ xtwx @ beta))
    s2 = rss / (n - 3)
    cov = s2 * inv
    mesor, a, b = (float(v) for v in beta)
    amp = math.hypot(a, b)
    sw, swy = float(xtwx[0, 0]), float(st.xtwy[0])
    tss = max(0.0, st.swyy - swy * swy / sw)
    out: dict[str, Any] = {
        "n": n, "mesor": mesor, "amplitude": amp, "acrophase_utc_h": None,
        "r2": (1.0 - rss / tss) if tss > _EPS * max(1.0, st.swyy) else None,
        "se_amplitude": None, "se_acrophase_h": None,
        "residual_sd": math.sqrt(s2 * n / sw), "a": a, "b": b,
    }
    vaa, vbb, vab = float(cov[1, 1]), float(cov[2, 2]), float(cov[1, 2])
    if amp > _EPS:
        out["acrophase_utc_h"] = (math.atan2(b, a) / OMEGA) % PERIOD_H
        var_amp = (a * a * vaa + b * b * vbb + 2.0 * a * b * vab) / (amp * amp)
        var_phi = (b * b * vaa + a * a * vbb - 2.0 * a * b * vab) / amp ** 4
        out["se_amplitude"] = math.sqrt(max(0.0, var_amp))
        out["se_acrophase_h"] = math.sqrt(max(0.0, var_phi)) / OMEGA
    return out


def cosinor_weighted(ts: Sequence[float], ys: Sequence[float],
                     ws: Sequence[float] | None = None) -> dict[str, Any] | None:
    """Fit ``y = M + a cos(w t) + b sin(w t)`` at actual UTC times ``ts`` (unix seconds).

    Returns mesor, amplitude, acrophase_utc_h (None when the amplitude is ~0), weighted R2
    and delta-method SEs of amplitude and acrophase. ``None`` when fewer than 4 points (no
    residual degree of freedom) or the design is singular (all points at one clock phase).
    """
    st = cosinor_suff(ts, ys, ws)
    return None if st is None else cosinor_from_suff(st)


def jackknife_by_group(groups: Sequence[CosinorSuff],
                       full: dict[str, Any]) -> tuple[float | None, float | None]:
    """Delete-one-group (day) jackknife SEs of amplitude and acrophase (hours).

    The acrophase deviations are circular differences from the full-data acrophase.
    """
    g = len(groups)
    if g < 3 or full.get("acrophase_utc_h") is None:
        return None, None
    total = groups[0]
    for grp in groups[1:]:
        total = total + grp
    amps: list[float] = []
    phis: list[float] = []
    for grp in groups:
        fit = cosinor_from_suff(total - grp)
        if fit is None or fit["acrophase_utc_h"] is None:
            return None, None
        amps.append(fit["amplitude"])
        phis.append(circ_diff_h(fit["acrophase_utc_h"], full["acrophase_utc_h"]))
    k = (g - 1.0) / g
    ma, mp = statistics.fmean(amps), statistics.fmean(phis)
    se_a = math.sqrt(k * sum((v - ma) ** 2 for v in amps))
    se_p = math.sqrt(k * sum((v - mp) ** 2 for v in phis))
    return se_a, se_p


# ---------------------------------------------------------------------------
# IS / IV (shared by temperature regularity and the rest-activity rhythm)
# ---------------------------------------------------------------------------


def interdaily_stability(points: Sequence[tuple[int, float]]) -> float | None:
    """IS = n * sum_h (xbar_h - xbar)^2 / (p * sum_i (x_i - xbar)^2).

    ``points``: (local hour-of-day key, value) for VALID epochs only; p = number of observed
    hour-of-day groups (24 on complete data). Zero variance -> None.
    """
    if len(points) < 2:
        return None
    vals = [v for _, v in points]
    n = len(vals)
    xbar = statistics.fmean(vals)
    denom = sum((v - xbar) ** 2 for v in vals)
    if denom <= _EPS * max(1.0, abs(xbar)):
        return None
    groups: dict[int, list[float]] = {}
    for h, v in points:
        groups.setdefault(int(h), []).append(v)
    p = len(groups)
    num = sum((statistics.fmean(g) - xbar) ** 2 for g in groups.values())
    return n * num / (p * denom)


def intradaily_variability(points: Sequence[tuple[int, float]],
                           epoch_seconds: int = EPOCH_SECONDS) -> tuple[float | None, int, int]:
    """Valid-pair IV over a UTC epoch series; returns (iv, valid_pairs, n).

    ``points``: (epoch start, unix seconds, value) for VALID epochs only. A pair counts only
    when both epochs are valid and exactly ``epoch_seconds`` apart (consecutive across
    midnight; a gap breaks it). IV = [sum_pairs dx^2 / P] / [sum (x - xbar)^2 / N].
    """
    by_start: dict[int, float] = {}
    for s, v in points:
        by_start.setdefault(int(s), float(v))
    n = len(by_start)
    if n < 2:
        return None, 0, n
    vals = list(by_start.values())
    xbar = statistics.fmean(vals)
    denom = sum((v - xbar) ** 2 for v in vals) / n
    pairs = 0
    num = 0.0
    for s, v in by_start.items():
        prev = by_start.get(s - epoch_seconds)
        if prev is not None:
            pairs += 1
            num += (v - prev) ** 2
    if pairs == 0 or denom <= _EPS * max(1.0, abs(xbar)):
        return None, pairs, n
    return (num / pairs) / denom, pairs, n


def l5_m10(profile: Sequence[float], l_hours: int = 5, m_hours: int = 10
           ) -> tuple[float, int, float, int]:
    """Cyclic L5 / M10 over a complete 24-value local-hour profile.

    Returns (l5, l5_start_hour, m10, m10_start_hour); windows wrap around midnight
    (pyActigraphy ``cyclic=True``). Ties keep the earliest start hour.
    """
    assert len(profile) == 24
    def window_means(k: int) -> list[float]:
        return [statistics.fmean(profile[(s + j) % 24] for j in range(k)) for s in range(24)]
    lw, mw = window_means(l_hours), window_means(m_hours)
    l_start = min(range(24), key=lambda s: (lw[s], s))
    m_start = max(range(24), key=lambda s: (mw[s], -s))
    return lw[l_start], l_start, mw[m_start], m_start


# ---------------------------------------------------------------------------
# History preparation
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class _Bin:
    start: int
    day: str
    local_hour: int
    offset_h: float
    temp: float | None
    temp_minutes: int
    hr: float | None
    hr_minutes: int
    mov: float | None
    mov_minutes: int


@dataclass(frozen=True)
class _Day:
    day: str
    timezone: str
    revision: int | None
    start: int
    end: int
    identity: str
    family: str
    bins: tuple[_Bin, ...]
    offset_start_h: float
    offset_end_h: float
    offset_mid_h: float

    @property
    def hours(self) -> float:
        return (self.end - self.start) / 3600.0


@dataclass(frozen=True)
class _Prepared:
    days: tuple[_Day, ...]
    duplicate_days: int
    duplicate_bins: int
    invalid_timezone_days: tuple[str, ...]
    identities: tuple[str, ...]
    families: tuple[str, ...]
    mixed: bool


def _zone(name: str) -> ZoneInfo | None:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return None


def _local(ts: float, zone: ZoneInfo) -> datetime:
    return datetime.fromtimestamp(ts, tz=_tz.utc).astimezone(zone)


def _offset_h(ts: float, zone: ZoneInfo) -> float:
    off = _local(ts, zone).utcoffset()
    return off.total_seconds() / 3600.0 if off is not None else 0.0


def prepare_history(hist: RhythmHistoryIn) -> _Prepared:
    """Dedupe days (newest revision wins) and bins (first day wins), resolve local clock."""
    by_day: dict[str, Any] = {}
    duplicate_days = 0
    for d in hist.days:
        prev = by_day.get(d.day)
        if prev is None:
            by_day[d.day] = d
            continue
        duplicate_days += 1
        if (d.revision if d.revision is not None else -1) > (
                prev.revision if prev.revision is not None else -1):
            by_day[d.day] = d
    seen: set[int] = set()
    duplicate_bins = 0
    invalid_tz: list[str] = []
    days: list[_Day] = []
    for d in sorted(by_day.values(), key=lambda x: x.day_start):
        zone = _zone(d.timezone)
        if zone is None:
            invalid_tz.append(d.day)
            continue
        bins: list[_Bin] = []
        for b in d.bins:
            if b.start in seen:
                duplicate_bins += 1
                continue
            seen.add(b.start)
            mid = b.start + EPOCH_SECONDS / 2
            loc = _local(mid, zone)
            bins.append(_Bin(
                start=b.start, day=d.day, local_hour=loc.hour, offset_h=_offset_h(mid, zone),
                temp=b.skin_temp_c, temp_minutes=b.skin_temp_valid_minutes,
                hr=b.hr_mean_bpm, hr_minutes=b.hr_valid_minutes,
                mov=b.movement_s_per_min, mov_minutes=b.movement_valid_minutes))
        days.append(_Day(
            day=d.day, timezone=d.timezone, revision=d.revision, start=d.day_start,
            end=d.day_end, identity=d.conversion_identity or hist.conversion_identity,
            family=d.device_family or hist.device_family, bins=tuple(bins),
            offset_start_h=_offset_h(d.day_start, zone),
            offset_end_h=_offset_h(d.day_end - 1, zone),
            offset_mid_h=_offset_h((d.day_start + d.day_end) / 2, zone)))
    with_data = [d for d in days if d.bins]
    identities = tuple(sorted({d.identity for d in with_data}))
    families = tuple(sorted({d.family for d in with_data}))
    mixed = ("mixed" in (hist.device_family, hist.conversion_identity)
             or len(identities) > 1 or len(families) > 1)
    return _Prepared(days=tuple(days), duplicate_days=duplicate_days,
                     duplicate_bins=duplicate_bins, invalid_timezone_days=tuple(invalid_tz),
                     identities=identities, families=families, mixed=mixed)


# Signal accessors: (value, valid minutes) of a bin.
_Signal = Callable[[_Bin], tuple[float | None, int]]


def _temp(b: _Bin) -> tuple[float | None, int]:
    return b.temp, b.temp_minutes


def _hr(b: _Bin) -> tuple[float | None, int]:
    return b.hr, b.hr_minutes


def _mov(b: _Bin) -> tuple[float | None, int]:
    return b.mov, b.mov_minutes


def _supported(b: _Bin, signal: _Signal, rc: RhythmConfig) -> bool:
    value, minutes = signal(b)
    return value is not None and minutes >= rc.hour_min_valid_minutes


@dataclass(frozen=True)
class _Gate:
    qualifying: tuple[_Day, ...]
    days_with_data: int
    quadrants: tuple[bool, bool, bool, bool]
    day_hours: int
    night_hours: int
    reasons: tuple[str, ...]


def _gate(prep: _Prepared, signal: _Signal, rc: RhythmConfig, min_days: int,
          coverage: float, daytime_reason: str) -> _Gate:
    quadrants = [False, False, False, False]
    qualifying: list[_Day] = []
    day_hours = night_hours = days_with_data = 0
    lo, hi = rc.daytime_local_hours
    for d in prep.days:
        sup = [b for b in d.bins if _supported(b, signal, rc)]
        if sup:
            days_with_data += 1
        for b in sup:
            quadrants[b.local_hour // 6] = True
            if lo <= b.local_hour < hi:
                day_hours += 1
            else:
                night_hours += 1
        if d.hours > 0 and len(sup) / d.hours >= coverage - 1e-9:
            qualifying.append(d)
    reasons: list[str] = []
    if len(qualifying) < min_days:
        reasons.append("insufficient_days")
    if not (quadrants[1] and quadrants[2]):
        reasons.append(daytime_reason)
    if not (quadrants[0] and quadrants[3]):
        reasons.append("quadrant_unobserved")
    return _Gate(qualifying=tuple(qualifying), days_with_data=days_with_data,
                 quadrants=tuple(quadrants), day_hours=day_hours, night_hours=night_hours,
                 reasons=tuple(reasons))


def _day_points(day: _Day, signal: _Signal, rc: RhythmConfig) -> list[tuple[float, float, float]]:
    """(bin midpoint unix seconds, value, weight) of a day's supported bins."""
    out = []
    for b in day.bins:
        if _supported(b, signal, rc):
            value, minutes = signal(b)
            out.append((b.start + EPOCH_SECONDS / 2, float(value), minutes / 60.0))
    return out


@dataclass(frozen=True)
class _PhaseFit:
    fit: dict[str, Any] | None
    se_amp: float | None
    se_phase_h: float | None
    jk_amp: float | None
    jk_phase_h: float | None
    daily: tuple[tuple[_Day, dict[str, Any] | None], ...]
    daily_sd_h: float | None
    reasons: tuple[str, ...]  # phase-availability reasons (empty = phase available)


def _fit_phase(gate: _Gate, signal: _Signal, rc: RhythmConfig, amp_floor: float) -> _PhaseFit:
    pairs: list[tuple[_Day, CosinorSuff]] = []
    for d in gate.qualifying:
        pts = _day_points(d, signal, rc)
        st = cosinor_suff([p[0] for p in pts], [p[1] for p in pts], [p[2] for p in pts])
        if st is not None:
            pairs.append((d, st))
    groups = [st for _, st in pairs]
    total = groups[0] if groups else None
    for grp in groups[1:]:
        total = total + grp
    fit = cosinor_from_suff(total) if total is not None else None
    daily: list[tuple[_Day, dict[str, Any] | None]] = []
    for d, g in pairs:
        df = cosinor_from_suff(g)
        if df is not None and (df["acrophase_utc_h"] is None or df["amplitude"] < amp_floor):
            df = {**df, "acrophase_utc_h": None}
        daily.append((d, df))
    daily_phases = [df["acrophase_utc_h"] for _, df in daily
                    if df is not None and df["acrophase_utc_h"] is not None]
    daily_sd = circ_sd_h(daily_phases)
    if fit is None:
        return _PhaseFit(None, None, None, None, None, tuple(daily), daily_sd, ("fit_failed",))
    jk_amp, jk_phase = jackknife_by_group(groups, fit)
    se_amp = max(v for v in (fit["se_amplitude"], jk_amp) if v is not None) if (
        fit["se_amplitude"] is not None or jk_amp is not None) else None
    se_phase = max(v for v in (fit["se_acrophase_h"], jk_phase) if v is not None) if (
        fit["se_acrophase_h"] is not None or jk_phase is not None) else None
    reasons: list[str] = []
    amp = fit["amplitude"]
    if (fit["acrophase_utc_h"] is None or amp < amp_floor
            or (se_amp is not None and amp < rc.amplitude_min_se_ratio * se_amp)):
        reasons.append("zero_amplitude")
    elif ((se_phase is not None and se_phase > rc.max_acrophase_se_h)
          or (daily_sd is not None and daily_sd > rc.max_daily_phase_circular_sd_h)):
        reasons.append("unstable_phase")
    return _PhaseFit(fit, se_amp, se_phase, jk_amp, jk_phase, tuple(daily), daily_sd,
                     tuple(reasons))


def _local_h(utc_h: float | None, offset_h: float) -> float | None:
    return None if utc_h is None else (utc_h + offset_h) % PERIOD_H


def _r(x: float | None, nd: int = 4) -> float | None:
    v = json_finite(x)
    return None if v is None else round(v, nd)


def _context_offset_h(req: SleepFeaturesRequest, night: NightIn | None,
                      prep: _Prepared | None) -> tuple[float, str]:
    """UTC offset (h) of the claim's zone at the main night's end (local-clock reporting)."""
    zone = _zone(req.context.iana_timezone)
    at = night.end if night is not None else (prep.days[-1].end - 1 if prep and prep.days else 0)
    if zone is None:
        if prep and prep.days:
            return prep.days[-1].offset_end_h, prep.days[-1].timezone
        return 0.0, "UTC"
    return _offset_h(at, zone), req.context.iana_timezone


# ---------------------------------------------------------------------------
# Clock changes, drift and realignment
# ---------------------------------------------------------------------------


def clock_changes(days: Sequence[_Day]) -> list[dict[str, Any]]:
    """Timezone changes between days and DST transitions within a day (relabelings only)."""
    out: list[dict[str, Any]] = []
    prev: _Day | None = None
    for d in days:
        if prev is not None and (prev.timezone != d.timezone
                                 or abs(prev.offset_end_h - d.offset_start_h) > 1e-9):
            out.append({"day": d.day, "kind": "timezone" if prev.timezone != d.timezone else "dst",
                        "from_timezone": prev.timezone, "to_timezone": d.timezone,
                        "from_offset_h": prev.offset_end_h, "to_offset_h": d.offset_start_h})
        if abs(d.offset_start_h - d.offset_end_h) > 1e-9:
            out.append({"day": d.day, "kind": "dst", "from_timezone": d.timezone,
                        "to_timezone": d.timezone, "from_offset_h": d.offset_start_h,
                        "to_offset_h": d.offset_end_h})
        prev = d
    return out


def _unwrap(phases: Sequence[float]) -> list[float]:
    out: list[float] = []
    for p in phases:
        if not out:
            out.append(p)
        else:
            out.append(out[-1] + circ_diff_h(p, out[-1]))
    return out


def _phase_drift(pf: _PhaseFit, all_days: Sequence[_Day], rc: RhythmConfig) -> dict[str, Any]:
    """Daily phases come from the qualifying days; clock changes from the WHOLE history."""
    changes = clock_changes(all_days)
    daily_rows = []
    usable: list[tuple[_Day, float]] = []
    for d, df in pf.daily:
        phase = df["acrophase_utc_h"] if df is not None else None
        daily_rows.append({
            "day": d.day, "timezone": d.timezone, "utc_offset_h": d.offset_mid_h,
            "acrophase_utc_h": _r(phase), "acrophase_local_h": _r(_local_h(phase, d.offset_mid_h)),
            "amplitude_c": _r(df["amplitude"]) if df is not None else None,
            "hours": df["n"] if df is not None else 0,
        })
        if phase is not None:
            usable.append((d, phase))
    block: dict[str, Any] = {
        "status": "withheld", "reasons": [],
        "method": "ols_slope_of_unwrapped_daily_utc_acrophase_on_elapsed_utc_days",
        "utc_drift_h_per_day": None, "days_used": len(usable), "span_days": None,
        "daily_phases": daily_rows, "clock_changes": changes,
        "observed_realignment": _realignment(usable, changes, rc),
        "notes": ["Drift is measured on elapsed UTC time; clock changes are relabelings and "
                  "never count as physiological drift. Retrospective description only."],
    }
    if len(usable) < rc.drift_min_days:
        block["reasons"] = ["insufficient_days"]
        return block
    xs = [((d.start + d.end) / 2.0) / 86400.0 for d, _ in usable]
    ys = _unwrap([p for _, p in usable])
    x0 = xs[0]
    xs = [x - x0 for x in xs]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx <= _EPS:
        block["reasons"] = ["insufficient_days"]
        return block
    slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    block.update(status="available", utc_drift_h_per_day=_r(slope), span_days=_r(xs[-1], 3))
    return block


def _realignment(usable: Sequence[tuple[_Day, float]], changes: Sequence[dict[str, Any]],
                 rc: RhythmConfig) -> dict[str, Any]:
    base = {"status": "not_applicable", "reasons": ["no_clock_change"], "clock_change_day": None,
            "clock_shift_h": None, "required_utc_shift_h": None, "utc_phase_change_h": None,
            "days_since_change": None, "fraction_realigned": None,
            "definition": ("fraction = observed UTC acrophase change / UTC change needed to keep "
                           "the pre-change local acrophase; descriptive, no forecast")}
    shifts = [c for c in changes
              if abs(c["to_offset_h"] - c["from_offset_h"]) >= rc.min_clock_shift_h]
    if not shifts:
        return base
    ch = shifts[-1]
    shift = ch["to_offset_h"] - ch["from_offset_h"]
    before = [p for d, p in usable if d.day < ch["day"]]
    after = [(d, p) for d, p in usable if d.day > ch["day"]]
    base.update(clock_change_day=ch["day"], clock_shift_h=_r(shift),
                required_utc_shift_h=_r(-shift))
    if len(before) < rc.realignment_min_days_before or len(after) < rc.realignment_min_days_after:
        base.update(status="withheld", reasons=["insufficient_days_around_clock_change"])
        return base
    pre, _ = circ_mean_h(before)
    if pre is None:
        base.update(status="withheld", reasons=["unstable_phase"])
        return base
    last_day, last_phase = after[-1]
    change = circ_diff_h(last_phase, pre)
    days_since = (datetime.fromisoformat(last_day.day) - datetime.fromisoformat(ch["day"])).days
    base.update(status="available", reasons=[], utc_phase_change_h=_r(change),
                days_since_change=days_since,
                fraction_realigned=_r(change / -shift))
    return base


# ---------------------------------------------------------------------------
# Phase relations
# ---------------------------------------------------------------------------


def _relation(a_label: str, a_utc: float | None, b_label: str, b_utc: float | None,
              offset_h: float, support: int | None, reasons: list[str]) -> dict[str, Any]:
    available = not reasons and a_utc is not None and b_utc is not None
    return {
        "status": "available" if available else "withheld",
        "reasons": [] if available else (reasons or ["phase_unavailable"]),
        "a_label": a_label, "a_h": _r(_local_h(a_utc, offset_h)), "a_utc_h": _r(a_utc),
        "b_label": b_label, "b_h": _r(_local_h(b_utc, offset_h)), "b_utc_h": _r(b_utc),
        "difference_h": _r(circ_diff_h(a_utc, b_utc)) if available else None,
        "support_days": support,
        "method": "circular_difference_of_independent_utc_phases",
    }


def _sleep_midpoints(req: SleepFeaturesRequest, span: tuple[int, int]) -> list[float]:
    """UTC clock hours of non-nap sleep-period midpoints inside the history span (deduped)."""
    periods: set[tuple[int, int]] = set()
    for hd in req.history_days:
        for n in hd.nights:
            if not n.is_nap:
                periods.add((n.start, n.end))
    for n in req.nights:
        if not n.is_nap:
            periods.add((n.start, n.end))
    lo, hi = span
    mids = []
    for s, e in sorted(periods):
        m = (s + e) / 2.0
        if lo <= m < hi:
            mids.append(_utc_hour_of_day(m))
    return mids


# ---------------------------------------------------------------------------
# Blocks
# ---------------------------------------------------------------------------


def _empty_rhythm_block(status: str, reasons: Sequence[str], rc: RhythmConfig,
                        digest: str | None = None) -> dict[str, Any]:
    phase_reason = [r for r in reasons if r in ("insufficient_days",
                                                "insufficient_daytime_temperature",
                                                "mixed_devices")] or list(reasons)
    return {
        "status": status,
        "reasons": list(reasons),
        "mesor_c": None,
        "amplitude_c": None,
        "acrophase_h": None,
        "fit_quality": None,
        "is": None,
        "iv": None,
        "daily_amplitude_c": None,
        "phase_stability_h": None,
        "notes": list(RHYTHM_NOTES),
        "method_version": METHOD_VERSION,
        "history_revision_digest": digest,
        "qualifying_days": None,
        "days_evaluated": None,
        "coverage": None,
        "uncertainty": None,
        "phase_status": {"status": "not_applicable" if status == "not_applicable" else "unavailable",
                         "reasons": phase_reason},
        "iv_definition": IV_DEFINITION,
        "regularity_name": "temperature_regularity",
        "phase_relations": None,
        "phase_drift": None,
        "config": rc.to_wire(),
    }


def not_requested_block(rc: RhythmConfig = RHYTHM_CONFIG) -> dict[str, Any]:
    """The rhythm sub-block when the request carries no ``rhythm_history``."""
    return _empty_rhythm_block("withheld", ["multi_day_history_not_requested"], rc)


def observed_skin_temp_rhythm(req: SleepFeaturesRequest, night: NightIn | None,
                              cfg: SleepFeaturesConfig = CONFIG,
                              rc: RhythmConfig = RHYTHM_CONFIG) -> dict[str, Any]:
    """``nights[main].thermal.observed_skin_temp_rhythm`` (CONTRACT 5.4)."""
    if night is not None:
        main = req.main_night()
        if night.is_nap:
            return _empty_rhythm_block("not_applicable", ["nap"], rc)
        if main is None or main.night_id != night.night_id:
            return _empty_rhythm_block("not_applicable", ["not_main_night"], rc)
    hist = req.rhythm_history
    if hist is None:
        return not_requested_block(rc)
    digest = hist.revision_digest
    prep = prepare_history(hist)
    if prep.mixed:
        block = _empty_rhythm_block("withheld", ["mixed_devices"], rc, digest)
        block["days_evaluated"] = len(prep.days)
        block["conversion_identities"] = list(prep.identities)
        return block

    gate = _gate(prep, _temp, rc, cfg.rhythm_min_days, cfg.rhythm_day_coverage,
                 "insufficient_daytime_temperature")
    offset_h, local_zone = _context_offset_h(req, night, prep)
    coverage = {
        "day_hours_supported": gate.day_hours,
        "night_hours_supported": gate.night_hours,
        "quadrants_observed": list(gate.quadrants),
        "daytime_local_hours": list(rc.daytime_local_hours),
        "days_with_data": gate.days_with_data,
        "duplicate_days_dropped": prep.duplicate_days,
        "duplicate_bins_dropped": prep.duplicate_bins,
        "invalid_timezone_days": list(prep.invalid_timezone_days),
    }
    if gate.reasons:
        block = _empty_rhythm_block("withheld", list(gate.reasons), rc, digest)
        block.update(qualifying_days=len(gate.qualifying), days_evaluated=len(prep.days),
                     coverage=coverage, conversion_identity=hist.conversion_identity)
        return block

    pf = _fit_phase(gate, _temp, rc, rc.amplitude_floor_c)
    fit = pf.fit
    phase_ok = not pf.reasons
    acro_utc = fit["acrophase_utc_h"] if (fit is not None and phase_ok) else None

    points = [b for d in gate.qualifying for b in d.bins if _supported(b, _temp, rc)]
    is_value = interdaily_stability([(b.local_hour, float(b.temp)) for b in points])
    iv_value, iv_pairs, iv_n = intradaily_variability([(b.start, float(b.temp)) for b in points])

    daily_amps = [df["amplitude"] for _, df in pf.daily if df is not None]

    # Phase relations: HR rhythm from the same history, gated identically.
    hr_gate = _gate(prep, _hr, rc, cfg.rhythm_min_days, cfg.rhythm_day_coverage,
                    "insufficient_daytime_heart_rate")
    hr_reasons: list[str] = []
    hr_phase: float | None = None
    hr_days = len(hr_gate.qualifying)
    if hr_gate.reasons:
        hr_reasons = [f"hr_{r}" if not r.startswith("insufficient_daytime") else r
                      for r in hr_gate.reasons]
    else:
        hpf = _fit_phase(hr_gate, _hr, rc, rc.hr_amplitude_floor_bpm)
        if hpf.reasons:
            hr_reasons = [f"hr_{r}" for r in hpf.reasons]
        elif hpf.fit is not None:
            hr_phase = hpf.fit["acrophase_utc_h"]
    temp_reasons = [] if phase_ok else ["temperature_phase_unavailable"]
    span = (prep.days[0].start, prep.days[-1].end)
    mids = _sleep_midpoints(req, span)
    mid_phase, _ = circ_mean_h(mids) if len(mids) >= rc.sleep_midpoint_min_nights else (None, 0.0)
    mid_reasons = [] if mid_phase is not None else (
        ["insufficient_sleep_periods"] if len(mids) < rc.sleep_midpoint_min_nights
        else ["unstable_sleep_midpoint"])
    relations = {
        "hr_minus_temp": _relation("heart_rate_acrophase", hr_phase, "skin_temp_acrophase",
                                   acro_utc, offset_h, hr_days, temp_reasons + hr_reasons),
        "sleep_midpoint_minus_temp": _relation("sleep_period_midpoint", mid_phase,
                                               "skin_temp_acrophase", acro_utc, offset_h,
                                               len(mids), temp_reasons + mid_reasons),
    }

    status = "available" if phase_ok else "partial"
    block = _empty_rhythm_block(status, list(pf.reasons), rc, digest)
    block.update({
        "mesor_c": _r(fit["mesor"]) if fit else None,
        "amplitude_c": _r(fit["amplitude"]) if fit else None,
        "acrophase_h": _r(_local_h(acro_utc, offset_h)),
        "acrophase_utc_h": _r(acro_utc),
        "acrophase_local_timezone": local_zone,
        "acrophase_local_utc_offset_h": offset_h,
        "fit_quality": _r(fit["r2"]) if fit else None,
        "fit_hours": fit["n"] if fit else 0,
        "residual_sd_c": _r(fit["residual_sd"]) if fit else None,
        "is": _r(is_value),
        "iv": _r(iv_value),
        "iv_valid_pairs": iv_pairs,
        "regularity_hours": iv_n,
        "daily_amplitude_c": _r(statistics.median(daily_amps)) if daily_amps else None,
        "phase_stability_h": _r(pf.daily_sd_h),
        "qualifying_days": len(gate.qualifying),
        "days_evaluated": len(prep.days),
        "coverage": coverage,
        "uncertainty": {
            "acrophase_se_h": _r(pf.se_phase_h),
            "amplitude_se_c": _r(pf.se_amp),
            "method": "max(ols_delta_method, delete_one_day_jackknife)",
            "acrophase_delta_se_h": _r(fit["se_acrophase_h"]) if fit else None,
            "amplitude_delta_se_c": _r(fit["se_amplitude"]) if fit else None,
            "acrophase_jackknife_se_h": _r(pf.jk_phase_h),
            "amplitude_jackknife_se_c": _r(pf.jk_amp),
        },
        "phase_status": {"status": "available" if phase_ok else "unavailable",
                         "reasons": list(pf.reasons)},
        "phase_relations": relations,
        "phase_drift": _phase_drift(pf, prep.days, rc),
        "conversion_identity": hist.conversion_identity,
        "weighting": "valid_minutes_per_hour",
    })
    return block


def rest_activity_rhythm(req: SleepFeaturesRequest, cfg: SleepFeaturesConfig = CONFIG,
                         rc: RhythmConfig = RHYTHM_CONFIG) -> dict[str, Any]:
    """Document-level ``rest_activity_rhythm`` (CONTRACT 5.4)."""
    hist = req.rhythm_history
    rules = dict(hist.rules) if hist is not None else {}
    gate_text = (f">= {rc.rest_activity_min_days} days with movement supported in >= "
                 f"{int(rc.rest_activity_day_coverage * 100)}% of local hours (an hour needs >= "
                 f"{rc.hour_min_valid_minutes} worn minutes with >= 30 one-second gravity "
                 f"adjacencies) and every 6-hour local quadrant observed")
    block: dict[str, Any] = {
        "status": "withheld", "reasons": [], "method_version": REST_ACTIVITY_METHOD_VERSION,
        "signal": REST_ACTIVITY_SIGNAL, "unit": "s/min", "epoch_seconds": EPOCH_SECONDS,
        "binarized": False, "count_threshold": None,
        "movement_threshold_g": rules.get("movement_threshold_g"),
        "is": None, "iv": None, "iv_definition": IV_DEFINITION, "iv_valid_pairs": 0,
        "l5": None, "m10": None, "l5_start_h": None, "m10_start_h": None, "ra": None,
        "days_used": 0, "hours_used": 0, "gate": gate_text,
        "history_revision_digest": hist.revision_digest if hist is not None else None,
        "deferred": ["lids", "kra_kar", "24h_align"],
        "config": rc.to_wire(), "notes": list(REST_ACTIVITY_NOTES),
    }
    if hist is None:
        block["reasons"] = ["multi_day_history_not_requested"]
        return block
    prep = prepare_history(hist)
    if not any(_supported(b, _mov, rc) for d in prep.days for b in d.bins):
        block["reasons"] = ["movement_history_absent"]
        return block
    gate = _gate(prep, _mov, rc, rc.rest_activity_min_days, rc.rest_activity_day_coverage,
                 "insufficient_daytime_movement")
    block["days_used"] = len(gate.qualifying)
    if gate.reasons:
        block["reasons"] = list(gate.reasons)
        return block
    points = [b for d in gate.qualifying for b in d.bins if _supported(b, _mov, rc)]
    block["hours_used"] = len(points)
    is_value = interdaily_stability([(b.local_hour, float(b.mov)) for b in points])
    iv_value, pairs, _ = intradaily_variability([(b.start, float(b.mov)) for b in points])
    profile_groups: dict[int, list[float]] = {}
    for b in points:
        profile_groups.setdefault(b.local_hour, []).append(float(b.mov))
    reasons: list[str] = []
    if is_value is None or iv_value is None:
        reasons.append("zero_variance" if is_value is None else "no_consecutive_hour_pairs")
    if len(profile_groups) < 24:
        reasons.append("incomplete_daily_profile")
    else:
        profile = [statistics.fmean(profile_groups[h]) for h in range(24)]
        l5, l5s, m10, m10s = l5_m10(profile, rc.l5_hours, rc.m10_hours)
        block.update(l5=_r(l5), m10=_r(m10), l5_start_h=float(l5s), m10_start_h=float(m10s))
        if m10 + l5 > _EPS:
            block["ra"] = _r((m10 - l5) / (m10 + l5))
        else:
            reasons.append("zero_activity")
    block.update({"is": _r(is_value), "iv": _r(iv_value), "iv_valid_pairs": pairs,
                  "status": "partial" if reasons else "available", "reasons": reasons})
    return block
