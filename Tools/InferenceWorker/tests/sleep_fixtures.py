"""Deterministic synthetic fixtures for the sleep-boundary and sleep-stage providers.

No private capture is used and no label is regenerated from the algorithm under test:
every expected boundary here is a *declared* property of the generator (see
``ground_truth`` in each fixture), so a test that compares the algorithm output with
``ground_truth`` compares it with the fixture definition, not with the algorithm.

Design rules
------------
* All fixtures are pure functions of a fixed seed and fixed local calendar dates, so the
  same numbers appear on every run and on every machine.
* Time is generated as *absolute* UTC seconds and rendered to local wall clock through the
  fixture's IANA zone. A DST transition day therefore really has 23/25 local hours, which
  is what the adapter's wake-date and analysis-block arithmetic must survive.
* A wear gap is a *removed* sample run (``None`` heart rate), not an interpolation, so the
  gap is visible to any coverage/gap logic.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Callable, Optional, Sequence
from zoneinfo import ZoneInfo

import numpy as np

DEFAULT_TZ = "America/New_York"
# 2026-10-19 is a Monday with no DST transition in America/New_York.
DEFAULT_WAKE_DAY = date(2026, 10, 19)
# US DST fall-back in 2026 is 2026-11-01 (local day is 25 hours long).
DST_WAKE_DAY = date(2026, 11, 1)
SEED = 20261001


def _local(day: date, hour: float, tz: str) -> datetime:
    """Local wall-clock datetime for ``day`` at ``hour`` (fractional hours)."""
    whole = int(math.floor(hour))
    minutes = int(round((hour - whole) * 60))
    return datetime(day.year, day.month, day.day, whole, 0, tzinfo=ZoneInfo(tz)) + timedelta(
        minutes=minutes
    )


@dataclass
class Fixture:
    name: str
    tz: str
    wake_day: date
    #: local spans the generator treats as *expected asleep*
    sleep_spans: list[tuple[datetime, datetime]]
    #: local spans of expected wakefulness *inside* the in-bed window
    awake_spans: list[tuple[datetime, datetime]] = field(default_factory=list)
    #: local spans of expected daytime sleep (naps)
    nap_spans: list[tuple[datetime, datetime]] = field(default_factory=list)
    #: removed-sample runs (wear gaps / off-wrist)
    gaps: list[tuple[datetime, datetime]] = field(default_factory=list)
    hr_sleep: float = 66.0
    sleep_dip_bpm: float = 14.0
    hr_awake_in_bed: float = 74.0
    hr_day: float = 82.0
    step_s: int = 60
    span_hours: int = 48
    span_start_local_hour: float = 12.0
    in_bed: Optional[tuple[datetime, datetime]] = None
    params: dict = field(default_factory=dict)
    user_edit: Optional[dict] = None
    age: Optional[int] = 42
    gender: Optional[int] = 1
    seed: int = SEED

    # -- derived ---------------------------------------------------------------
    def _in_bed(self) -> tuple[datetime, datetime]:
        if self.in_bed is not None:
            return self.in_bed
        first = self.sleep_spans[0][0]
        last = self.sleep_spans[-1][1]
        return (first, last)

    def _level(self, local_dt: datetime) -> float:
        for start, end in self.awake_spans:
            if start <= local_dt < end:
                return self.hr_awake_in_bed
        for start, end in self.nap_spans:
            if start <= local_dt < end:
                # A nap is generated as a flat deep level: its whole span must sit below the
                # analysis-day threshold so the upstream 40-minute minimum-candidate gate can
                # pass on a nap that is not hours long.
                return self.hr_sleep - self.sleep_dip_bpm
        for start, end in self.sleep_spans:
            if start <= local_dt < end:
                # A sharp shoulder at both edges (so the boundary is a real volatility
                # transition, which is what the algorithm's refinement step keys on) and a
                # slow, deep dip through the middle of the span (so a long stretch sits well
                # below the analysis-day HR threshold, which is what its quantile gate needs).
                span = (end - start).total_seconds()
                u = (local_dt - start).total_seconds() / span if span else 0.5
                dip = self.sleep_dip_bpm * math.exp(-(((u - 0.5) / 0.30) ** 2))
                return self.hr_sleep - dip
        hour = local_dt.hour + local_dt.minute / 60.0
        # mild deterministic circadian rhythm, peak ~16:00, trough ~04:00
        return self.hr_day + 6.0 * math.sin(2.0 * math.pi * (hour - 10.0) / 24.0)

    def hr_at(self, local_dt: datetime, rng: np.random.Generator) -> float:
        base = self._level(local_dt)
        minutes = local_dt.hour * 60 + local_dt.minute
        wobble = 1.4 * math.sin(2.0 * math.pi * minutes / 47.0) + 0.7 * math.sin(
            2.0 * math.pi * minutes / 13.0
        )
        return round(float(base + wobble + rng.normal(0.0, 0.7)), 3)

    def _gapped(self, local_dt: datetime) -> bool:
        return any(start <= local_dt < end for start, end in self.gaps)

    # -- build -----------------------------------------------------------------
    def build(self) -> dict:
        tz = ZoneInfo(self.tz)
        rng = np.random.default_rng(self.seed)
        span_start_local = _local(self.wake_day, self.span_start_local_hour, self.tz) - timedelta(
            days=1
        )
        span_start_utc = span_start_local.astimezone(timezone.utc)
        n = int(self.span_hours * 3600 / self.step_s)
        samples: list[tuple[int, Optional[float]]] = []
        for i in range(n):
            ts_utc = span_start_utc + timedelta(seconds=i * self.step_s)
            local_dt = ts_utc.astimezone(tz)
            if self._gapped(local_dt):
                # A wear gap is an ABSENT sample run (no rows), not a row with a null value.
                continue
            samples.append((int(ts_utc.timestamp()), self.hr_at(local_dt, rng)))

        in_bed_start, in_bed_end = self._in_bed()
        declared = self.sleep_spans if self.sleep_spans else self.awake_spans
        onset = min(s for s, _ in declared)
        wake = max(e for _, e in declared)
        gt = {
            "onset_local": onset.isoformat(),
            "wake_local": wake.isoformat(),
            "onset_utc": int(onset.astimezone(timezone.utc).timestamp()),
            "wake_utc": int(wake.astimezone(timezone.utc).timestamp()),
            "in_bed_utc": [
                int(in_bed_start.astimezone(timezone.utc).timestamp()),
                int(in_bed_end.astimezone(timezone.utc).timestamp()),
            ],
            "expected_asleep_utc": [
                [
                    int(s.astimezone(timezone.utc).timestamp()),
                    int(e.astimezone(timezone.utc).timestamp()),
                ]
                for s, e in self.sleep_spans
            ],
            "expected_awake_in_bed_utc": [
                [
                    int(s.astimezone(timezone.utc).timestamp()),
                    int(e.astimezone(timezone.utc).timestamp()),
                ]
                for s, e in self.awake_spans
            ],
            "expected_nap_utc": [
                [
                    int(s.astimezone(timezone.utc).timestamp()),
                    int(e.astimezone(timezone.utc).timestamp()),
                ]
                for s, e in self.nap_spans
            ],
            "gap_utc": [
                [
                    int(s.astimezone(timezone.utc).timestamp()),
                    int(e.astimezone(timezone.utc).timestamp()),
                ]
                for s, e in self.gaps
            ],
        }
        return {
            "name": self.name,
            "tz": self.tz,
            "wake_day": self.wake_day.isoformat(),
            "step_s": self.step_s,
            "hr": samples,
            "ground_truth": gt,
            "params": dict(self.params),
            "user_edit": self.user_edit,
            "age": self.age,
            "gender": self.gender,
        }


def _night(day: date, onset_hour: float, wake_hour: float, tz: str) -> tuple[datetime, datetime]:
    """In-bed span whose WAKE happens on ``day`` (the FRWHOOP analysis day).

    An evening onset (``onset_hour >= 12``) therefore starts on the previous calendar day.
    """
    if onset_hour >= 12:
        start = _local(day - timedelta(days=1), onset_hour, tz)
        end = _local(day, wake_hour, tz)
    else:
        start = _local(day, onset_hour, tz)
        end = _local(day, wake_hour, tz)
    return start, end


# --------------------------------------------------------------------------- fixtures
def normal_night() -> Fixture:
    """Clean reference night: in bed 22:45 -> 07:05 with a clear HR dip."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    return Fixture(
        name="normal_night",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def normal_night_with_gaps() -> Fixture:
    """Reference night plus a 3 h daytime wear gap and a 3 h wear gap inside the sleep window."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    day_before = DEFAULT_WAKE_DAY - timedelta(days=1)
    return Fixture(
        name="normal_night_with_gaps",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
        gaps=[
            (_local(day_before, 14.0, tz), _local(day_before, 17.0, tz)),
            (_local(DEFAULT_WAKE_DAY, 2.0, tz), _local(DEFAULT_WAKE_DAY, 5.0, tz)),
        ],
    )


def quiet_awake_in_bed() -> Fixture:
    """Lying quietly awake all night: HR stays at the awake-in-bed level, no dip."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    return Fixture(
        name="quiet_awake_in_bed",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[],
        awake_spans=[(start, end)],
        hr_awake_in_bed=70.0,
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def elevated_nighttime_hr() -> Fixture:
    """Elevated HR all night (illness / alcohol): a flat night inside the search window."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    return Fixture(
        name="elevated_nighttime_hr",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        hr_sleep=85.0,
        sleep_dip_bpm=0.0,
        hr_day=78.0,
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def fragmented_sleep() -> Fixture:
    """Four sleep blocks separated by 45-minute awake-in-bed bands."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    awake = [
        (_local(DEFAULT_WAKE_DAY, 1.5, tz), _local(DEFAULT_WAKE_DAY, 2.25, tz)),
        (_local(DEFAULT_WAKE_DAY, 3.5, tz), _local(DEFAULT_WAKE_DAY, 4.25, tz)),
        (_local(DEFAULT_WAKE_DAY, 5.0, tz), _local(DEFAULT_WAKE_DAY, 5.75, tz)),
    ]
    spans = []
    cursor = start
    for a_start, a_end in awake:
        spans.append((cursor, a_start))
        cursor = a_end
    spans.append((cursor, end))
    return Fixture(
        name="fragmented_sleep",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=spans,
        awake_spans=awake,
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def nap_day() -> Fixture:
    """Normal night plus a 14:00-15:10 local nap (outside the default 20:00-12:00 window)."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    nap = (_local(DEFAULT_WAKE_DAY, 14.0, tz), _local(DEFAULT_WAKE_DAY, 15.17, tz))
    return Fixture(
        name="nap_day",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        nap_spans=[nap],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def double_nap_day() -> Fixture:
    """Normal night plus TWO daytime sleeps: the longer becomes the main period, the other a nap."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    # 45 minutes each: above the upstream 40-minute minimum-candidate gate, and together
    # under 40% of the 4-hour window so the day's 0.4 HR quantile stays in the awake band.
    long_nap = (_local(DEFAULT_WAKE_DAY, 13.5, tz), _local(DEFAULT_WAKE_DAY, 14.25, tz))
    short_nap = (_local(DEFAULT_WAKE_DAY, 16.0, tz), _local(DEFAULT_WAKE_DAY, 16.75, tz))
    return Fixture(
        name="double_nap_day",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        nap_spans=[long_nap, short_nap],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
        # merge_gap_minutes below the 60-minute gap between the two naps, so they stay
        # separate periods (the upstream merge marks everything between two candidates as a
        # candidate when the gap is under the tolerance).
        params={"search_window_local_hours": [13, 17], "merge_gap_minutes": 30},
    )


def shift_schedule() -> Fixture:
    """Night-shift sleeper: sleep 08:00-15:00 local on the wake day."""
    tz = DEFAULT_TZ
    start = _local(DEFAULT_WAKE_DAY, 8.0, tz)
    end = _local(DEFAULT_WAKE_DAY, 15.0, tz)
    return Fixture(
        name="shift_schedule",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
        params={"search_window_local_hours": [5, 16]},
    )


def late_sleeper() -> Fixture:
    """Onset after local midnight (01:30 -> 09:00): still the wake day's session."""
    tz = DEFAULT_TZ
    start = _local(DEFAULT_WAKE_DAY, 1.5, tz)
    end = _local(DEFAULT_WAKE_DAY, 9.0, tz)
    return Fixture(
        name="late_sleeper",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def dst_fallback_night() -> Fixture:
    """Night across the US DST fall-back (2026-11-01): the local day is 25 hours long."""
    tz = DEFAULT_TZ
    start = _local(DST_WAKE_DAY - timedelta(days=1), 23.0, tz)
    end = _local(DST_WAKE_DAY, 8.0, tz)
    return Fixture(
        name="dst_fallback_night",
        tz=tz,
        wake_day=DST_WAKE_DAY,
        sleep_spans=[(start, end)],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
    )


def user_edited_bounds() -> Fixture:
    """Clean night plus a user-corrected in-bed window (corrections must outrank candidates)."""
    fx = normal_night()
    start, end = fx._in_bed()
    fx.name = "user_edited_bounds"
    fx.user_edit = {
        "onset_utc": int(start.astimezone(timezone.utc).timestamp()),
        "wake_utc": int(end.astimezone(timezone.utc).timestamp()),
        "source": "user_correction",
    }
    return fx


def sparse_wear() -> Fixture:
    """Off-wrist heavy night: two 2 h gaps inside the sleep window."""
    tz = DEFAULT_TZ
    start, end = _night(DEFAULT_WAKE_DAY, 22.75, 7.08, tz)
    return Fixture(
        name="sparse_wear",
        tz=tz,
        wake_day=DEFAULT_WAKE_DAY,
        sleep_spans=[(start, end)],
        in_bed=(start - timedelta(minutes=20), end + timedelta(minutes=15)),
        gaps=[
            (_local(DEFAULT_WAKE_DAY, 1.0, tz), _local(DEFAULT_WAKE_DAY, 3.0, tz)),
            (_local(DEFAULT_WAKE_DAY, 4.5, tz), _local(DEFAULT_WAKE_DAY, 6.5, tz)),
        ],
    )


ALL_FIXTURES: dict[str, Callable[[], Fixture]] = {
    "normal_night": normal_night,
    "normal_night_with_gaps": normal_night_with_gaps,
    "quiet_awake_in_bed": quiet_awake_in_bed,
    "elevated_nighttime_hr": elevated_nighttime_hr,
    "fragmented_sleep": fragmented_sleep,
    "nap_day": nap_day,
    "double_nap_day": double_nap_day,
    "shift_schedule": shift_schedule,
    "late_sleeper": late_sleeper,
    "dst_fallback_night": dst_fallback_night,
    "user_edited_bounds": user_edited_bounds,
    "sparse_wear": sparse_wear,
}


# --------------------------------------------------------------------------- rr series
def rr_series_from_fixture(
    fx: Fixture,
    *,
    start_utc: Optional[int] = None,
    end_utc: Optional[int] = None,
    gap_seconds: int = 120,
    seed: int = SEED,
    ectopic_fraction: float = 0.004,
    drop_runs: Sequence[tuple[int, int]] = (),
) -> dict:
    """Build a synthetic RR-interval series shaped like ``public.noop_rr_intervals``.

    The series is derived from the same HR profile as the boundary fixtures: RR samples are
    emitted at the instantaneous heart rate, with whole-second timestamps, a ``seq`` /
    ``ord`` ordering inside each second, and the fixture's wear gaps removed so that the
    stager sees the same dropouts as the boundary provider.
    """
    tz = ZoneInfo(fx.tz)
    rng = np.random.default_rng(seed)
    if start_utc is None or end_utc is None:
        in_bed_start, in_bed_end = fx._in_bed()
        start_utc = int(in_bed_start.astimezone(timezone.utc).timestamp())
        end_utc = int(in_bed_end.astimezone(timezone.utc).timestamp())

    t = float(start_utc)
    rows: list[tuple[int, int, int, int, int]] = []
    seq = 0
    last_second = -1
    order = 0
    while t < end_utc:
        local_dt = datetime.fromtimestamp(t, tz=timezone.utc).astimezone(tz)
        if any(s <= local_dt < e for s, e in fx.gaps):
            t += fx.step_s
            continue
        if any(lo <= t < hi for lo, hi in drop_runs):
            t += fx.step_s
            continue
        hr = fx.hr_at(local_dt, rng)
        rr_ms = 60000.0 / hr
        if rng.random() < ectopic_fraction:
            rr_ms *= float(rng.choice([0.55, 1.7]))
        ts = int(t)
        if ts != last_second:
            seq = 0
            last_second = ts
        else:
            seq += 1
        order += 1
        suspect = 1 if (rng.random() < 0.002) else 0
        rows.append((ts, int(round(rr_ms)), seq, order, suspect))
        t += rr_ms / 1000.0
    return {
        "rr": rows,
        "window": {"start_utc": start_utc, "end_utc": end_utc},
        "tz": fx.tz,
        "fixture": fx.name,
        "gap_seconds": gap_seconds,
        "age": fx.age,
        "gender": fx.gender,
    }
