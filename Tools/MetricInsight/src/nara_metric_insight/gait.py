"""ElderNet gait for a day, read the way the phone's "How you walked" card reads it.

A line-by-line port of `GaitWindowColumns` (the `gait-windows-1` columns the server stores in
`activity_gait_windows_days.windows`) and `WalkingDayReading` (Packages/StrandAnalytics/Sources/StrandAnalytics/
GaitWindows.swift): the windows that START inside the local day, each owning `hop` seconds and `hop / window` of its
steps; walks of at least 60 s, with pauses of up to 15 s inside one; brisk at 100 steps/min or more; cadence bands
from 0, 80, 100 and 120 steps/min; the typical speed is the median of the walks' own speeds. Pinned to the Swift by
tests/data/gait_cases.json + gait_expected.json (StrandAnalyticsTests/GaitServerMirrorTests records them).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

CADENCE_BANDS = (0.0, 80.0, 100.0, 120.0)   # strolling, steady, brisk, fast
BRISK_CADENCE_SPM = 100.0
MIN_BOUT_SECONDS = 60
BOUT_MERGE_GAP_SECONDS = 15


@dataclass(frozen=True)
class Window:
    start: int
    gait_probability: float
    is_gait: bool
    speed_mps: float | None
    cadence_spm: float | None
    stride_m: float | None
    regularity: float | None
    steps: float | None
    prefiltered: bool = False


@dataclass(frozen=True)
class Columns:
    window_seconds: int
    hop_seconds: int
    windows: tuple[Window, ...]


def _int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return int(value)


def columns(obj: Any) -> Columns | None:
    """GaitWindowColumns.init?(_:): None for anything that is not a well-formed `gait-windows-1` object."""
    if not isinstance(obj, dict) or obj.get("format") != "gait-windows-1":
        return None
    n, w, h = _int(obj.get("n")), _int(obj.get("w")), _int(obj.get("h"))
    if n is None or w is None or h is None or w <= 0 or h <= 0:
        return None

    def column(key: str) -> list[int] | None:
        a = obj.get(key)
        if not isinstance(a, list) or len(a) != n:
            return None
        ints = [_int(x) for x in a]
        return None if any(x is None for x in ints) else ints  # type: ignore[return-value]

    cols = {key: column(key) for key in ("ds", "gp", "g", "sp", "cad", "st", "rg", "stp")}
    if any(v is None for v in cols.values()):
        return None
    pf = column("pf")

    def value(x: int, scale: float) -> float | None:
        return None if x < 0 else float(x) / scale

    out: list[Window] = []
    if n > 0:
        t = _int(obj.get("s0"))
        if t is None:
            return None
        for k in range(n):
            t += cols["ds"][k]
            out.append(Window(start=t, gait_probability=float(cols["gp"][k]) / 1000, is_gait=cols["g"][k] == 1,
                              speed_mps=value(cols["sp"][k], 100), cadence_spm=value(cols["cad"][k], 1),
                              stride_m=value(cols["st"][k], 100), regularity=value(cols["rg"][k], 100),
                              steps=value(cols["stp"][k], 10), prefiltered=pf is not None and pf[k] == 1))
    return Columns(w, h, tuple(out))


@dataclass
class Bout:
    start: int
    end: int
    cadence_spm: float | None
    speed_mps: float | None
    steps: float

    @property
    def seconds(self) -> int:
        return self.end - self.start


@dataclass
class Reading:
    walking_seconds: int = 0
    brisk_seconds: int = 0
    steps: float | None = None
    cadence_spm: float | None = None
    speed_mps: float | None = None
    stride_m: float | None = None
    regularity: float | None = None
    bouts: list[Bout] = field(default_factory=list)
    assessed_windows: int = 0
    cadence_band_seconds: list[int] = field(default_factory=list)
    hourly_seconds: list[int] = field(default_factory=list)
    typical_speed_mps: float | None = None


def reading(days: list[Columns], start: int, end: int) -> Reading:
    """WalkingDayReading.init(days:from:to:): the windows that start inside [start, end) across `days`, as one
    stretch."""
    walking = brisk = assessed = 0
    bands = [0] * len(CADENCE_BANDS)
    hourly = [0] * max(1, (end - start + 3_599) // 3_600)
    steps, step_windows = 0.0, 0
    sums, counts = [0.0, 0.0, 0.0, 0.0], [0, 0, 0, 0]
    bouts: list[Bout] = []
    open_: list[Any] | None = None   # [start, end, cad, cad_n, sp, sp_n, steps]

    def close() -> None:
        nonlocal open_
        b = open_
        if b is None:
            return
        open_ = None
        if b[1] - b[0] < MIN_BOUT_SECONDS:
            return
        bouts.append(Bout(b[0], b[1], b[2] / float(b[3]) if b[3] > 0 else None,
                          b[4] / float(b[5]) if b[5] > 0 else None, b[6]))

    every = sorted(((d.hop_seconds, d.window_seconds, w) for d in days for w in d.windows
                    if start <= w.start < end), key=lambda item: item[2].start)
    last_start: int | None = None
    for hop, width, w in every:
        if w.start == last_start:
            continue
        last_start = w.start
        assessed += 1
        if not w.is_gait:
            continue
        walking += hop
        if w.cadence_spm is not None and w.cadence_spm >= BRISK_CADENCE_SPM:
            brisk += hop
        if w.cadence_spm is not None:
            band = max((i for i, low in enumerate(CADENCE_BANDS) if w.cadence_spm >= low), default=None)
            if band is not None:
                bands[band] += hop
        hourly[min(len(hourly) - 1, max(0, (w.start - start) // 3_600))] += hop
        share = float(hop) / float(width)
        step_share = (w.steps if w.steps is not None else 0.0) * share
        if w.steps is not None:
            steps += step_share
            step_windows += 1
        for i, v in enumerate((w.cadence_spm, w.speed_mps, w.stride_m, w.regularity)):
            if v is not None:
                sums[i] += v
                counts[i] += 1
        window_end = w.start + hop
        if open_ is not None and w.start - open_[1] <= BOUT_MERGE_GAP_SECONDS:
            open_[1] = window_end
            open_[6] += step_share
            if w.cadence_spm is not None:
                open_[2] += w.cadence_spm
                open_[3] += 1
            if w.speed_mps is not None:
                open_[4] += w.speed_mps
                open_[5] += 1
        else:
            close()
            open_ = [w.start, window_end, w.cadence_spm if w.cadence_spm is not None else 0.0,
                     0 if w.cadence_spm is None else 1, w.speed_mps if w.speed_mps is not None else 0.0,
                     0 if w.speed_mps is None else 1, step_share]
    close()

    def mean(i: int) -> float | None:
        return sums[i] / float(counts[i]) if counts[i] > 0 else None

    speeds = sorted(b.speed_mps for b in bouts if b.speed_mps is not None)
    typical = (None if not speeds else speeds[len(speeds) // 2] if len(speeds) % 2 == 1
               else (speeds[len(speeds) // 2 - 1] + speeds[len(speeds) // 2]) / 2)
    return Reading(walking_seconds=walking, brisk_seconds=brisk, steps=steps if step_windows > 0 else None,
                   cadence_spm=mean(0), speed_mps=mean(1), stride_m=mean(2), regularity=mean(3), bouts=bouts,
                   assessed_windows=assessed, cadence_band_seconds=bands, hourly_seconds=hourly,
                   typical_speed_mps=typical)
