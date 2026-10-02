"""Shared time, coverage and provenance helpers for the FRWHOOP sleep providers.

These helpers are deliberately outside the vendored HypnosPy code: the FRWHOOP wake-date and
IANA-timezone semantics (spec section 5, "explicitly adapt analysis-day bounds to FRWHOOP's
IANA timezone and wake-date semantics") are computed here and handed to the vendored
algorithm as one already-resolved analysis-day block.
"""

from __future__ import annotations

import hashlib
import json
import math
from datetime import date, datetime, timedelta, timezone
from typing import Iterable, Optional, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import numpy as np

UTC = timezone.utc

#: A wear gap / dropout is at least this long (2 minutes), per the migration plan.
GAP_MIN_SECONDS_DEFAULT = 120


class InputError(ValueError):
    """Malformed or out-of-bounds caller input (HTTP 400 / status "error")."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def parse_ts(value, field: str = "timestamp") -> int:
    """Accept an int/float epoch second or an ISO-8601 string; return whole epoch seconds."""
    if isinstance(value, bool) or value is None:
        raise InputError("invalid_timestamp", "%s is not a timestamp: %r" % (field, value))
    if isinstance(value, (int, np.integer)):
        return int(value)
    if isinstance(value, (float, np.floating)):
        if not math.isfinite(float(value)):
            raise InputError("invalid_timestamp", "%s is not finite: %r" % (field, value))
        return int(round(float(value)))
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as exc:
            raise InputError("invalid_timestamp", "%s is not ISO-8601: %r (%s)" % (field, value, exc))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=UTC)
        return int(parsed.timestamp())
    raise InputError("invalid_timestamp", "%s has unsupported type %s" % (field, type(value).__name__))


def parse_zone(name: str) -> ZoneInfo:
    if not name or not isinstance(name, str):
        raise InputError("invalid_timezone", "iana_timezone is required (got %r)" % (name,))
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise InputError("invalid_timezone", "unknown IANA timezone %r (%s)" % (name, exc))


def local_datetime(ts_utc: int, zone: ZoneInfo) -> datetime:
    return datetime.fromtimestamp(int(ts_utc), tz=UTC).astimezone(zone)


def local_day(ts_utc: int, zone: ZoneInfo) -> date:
    """The FRWHOOP analysis day for a session is the local date of its WAKE timestamp."""
    return local_datetime(ts_utc, zone).date()


def analysis_block(
    wake_day: date,
    zone: ZoneInfo,
    search_start_hour: int,
    search_end_hour: int,
) -> tuple[int, int]:
    """Local analysis block that contains the wake moment, as UTC epoch seconds.

    The block starts on the day before ``wake_day`` when ``search_start_hour >=
    search_end_hour`` (an overnight window such as 20:00 -> 12:00) and on ``wake_day``
    itself otherwise (a daytime window such as a night-shift 05:00 -> 16:00).

    Local calendar arithmetic is done through the zone, so a DST transition day yields a
    16 h or 18 h block rather than a fixed 16 h block.
    """
    if not (0 <= search_start_hour <= 23) or not (0 <= search_end_hour <= 23):
        raise InputError(
            "invalid_search_window",
            "search_window_local_hours must be integer local hours in 0..23 (got %r)"
            % ([search_start_hour, search_end_hour],),
        )
    if search_start_hour == search_end_hour:
        raise InputError("invalid_search_window", "search window start and end hour must differ")
    start_date = wake_day - timedelta(days=1) if search_start_hour >= search_end_hour else wake_day
    start_local = datetime(
        start_date.year, start_date.month, start_date.day, search_start_hour, tzinfo=zone
    )
    end_local = datetime(
        wake_day.year, wake_day.month, wake_day.day, search_end_hour, tzinfo=zone
    )
    if search_start_hour < search_end_hour:
        end_local = end_local + timedelta(days=0)
    else:
        end_local = datetime(
            wake_day.year, wake_day.month, wake_day.day, search_end_hour, tzinfo=zone
        )
    return int(start_local.timestamp()), int(end_local.timestamp())


def block_hours(start_utc: int, end_utc: int) -> float:
    return round((end_utc - start_utc) / 3600.0, 3)


def detect_gaps(times: Sequence[int], threshold_s: int = GAP_MIN_SECONDS_DEFAULT) -> list[tuple[int, int]]:
    """Contiguous sample runs whose *absence* is at least ``threshold_s`` long."""
    gaps: list[tuple[int, int]] = []
    ordered = sorted(int(t) for t in times)
    for prev, nxt in zip(ordered, ordered[1:]):
        if nxt - prev >= threshold_s:
            gaps.append((prev, nxt))
    return gaps


def epoch_gap_mask(epoch_times: np.ndarray, gaps: Sequence[tuple[int, int]]) -> np.ndarray:
    """True where an epoch falls strictly inside a gap interval."""
    mask = np.zeros(len(epoch_times), dtype=bool)
    for lo, hi in gaps:
        mask |= (epoch_times > lo) & (epoch_times < hi)
    return mask


def resample_to_grid(
    samples: Sequence[tuple[int, Optional[float]]],
    start_utc: int,
    end_utc: int,
    grid_seconds: int,
) -> tuple[np.ndarray, np.ndarray, dict]:
    """Resample irregular samples onto a fixed epoch grid.

    Returns ``(epoch_times, values, diagnostics)``. Values are the mean of the samples that
    land in an epoch; epochs with no sample are ``NaN``.
    """
    if grid_seconds <= 0:
        raise InputError("invalid_grid", "hr_grid_seconds must be positive")
    n = int((end_utc - start_utc) // grid_seconds)
    if n <= 0:
        raise InputError("empty_interval", "the analysis block is shorter than one epoch")
    epoch_times = start_utc + np.arange(n, dtype=np.int64) * grid_seconds
    sums = np.zeros(n, dtype=float)
    counts = np.zeros(n, dtype=np.int64)
    out_of_block = 0
    for ts, value in samples:
        idx = int((ts - start_utc) // grid_seconds)
        if idx < 0 or idx >= n:
            out_of_block += 1
            continue
        if value is None:
            continue
        if not math.isfinite(float(value)):
            continue
        sums[idx] += float(value)
        counts[idx] += 1
    values = np.full(n, np.nan)
    hit = counts > 0
    values[hit] = sums[hit] / counts[hit]
    diagnostics = {
        "grid_seconds": int(grid_seconds),
        "epochs": int(n),
        "samples_in_block": int(sum(1 for ts, _ in samples if start_utc <= ts < end_utc)),
        "samples_outside_block": int(out_of_block),
        "occupied_epochs": int(hit.sum()),
        "collisions": int((counts > 1).sum()),
        "occupancy_fraction": round(float(hit.mean()), 5),
    }
    return epoch_times, values, diagnostics


def sha256_payload(payload) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def json_safe(value):
    """Recursively convert numpy scalars/arrays to plain JSON types."""
    if isinstance(value, dict):
        return {str(k): json_safe(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(v) for v in value]
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating,)):
        return None if not math.isfinite(float(value)) else float(value)
    if isinstance(value, (np.bool_,)):
        return bool(value)
    if isinstance(value, np.ndarray):
        return json_safe(value.tolist())
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def finite_or_none(value) -> Optional[float]:
    if value is None:
        return None
    try:
        as_float = float(value)
    except (TypeError, ValueError):
        return None
    return as_float if math.isfinite(as_float) else None


def merge_intervals(intervals: Iterable[tuple[int, int]], tolerance_s: int = 0) -> list[tuple[int, int]]:
    ordered = sorted((int(a), int(b)) for a, b in intervals if b > a)
    merged: list[tuple[int, int]] = []
    for start, end in ordered:
        if merged and start - merged[-1][1] <= tolerance_s:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def complement_intervals(covered, lo: int, hi: int, min_piece_s: int = 30) -> list[tuple[int, int]]:
    """Parts of ``[lo, hi)`` that no covered interval reaches."""
    merged = merge_intervals(covered)
    out: list[tuple[int, int]] = []
    cursor = int(lo)
    for start, end in merged:
        if end <= lo or start >= hi:
            continue
        start = max(int(start), int(lo))
        end = min(int(end), int(hi))
        if start > cursor:
            out.append((cursor, start))
        cursor = max(cursor, end)
    if cursor < hi:
        out.append((cursor, int(hi)))
    return [(a, b) for a, b in out if (b - a) >= min_piece_s]


def mask_to_intervals(times: np.ndarray, mask: np.ndarray, epoch_seconds: int) -> list[tuple[int, int]]:
    """Contiguous True runs -> [start, end) epoch-second intervals."""
    intervals: list[tuple[int, int]] = []
    start_idx: Optional[int] = None
    for i, flag in enumerate(mask):
        if flag and start_idx is None:
            start_idx = i
        elif not flag and start_idx is not None:
            intervals.append((int(times[start_idx]), int(times[i])))
            start_idx = None
    if start_idx is not None:
        intervals.append((int(times[start_idx]), int(times[-1]) + epoch_seconds))
    return intervals


def split_interval_at_gaps(
    start: int, end: int, gaps: Sequence[tuple[int, int]], min_piece_s: int
) -> tuple[list[tuple[int, int]], float]:
    """Cut an interval at every gap that overlaps it; return the pieces and the gap fraction."""
    pieces: list[tuple[int, int]] = []
    cursor = start
    gap_seconds = 0
    for lo, hi in sorted(gaps):
        if hi <= start or lo >= end:
            continue
        overlap_start = max(lo, start)
        overlap_end = min(hi, end)
        gap_seconds += max(0, overlap_end - overlap_start)
        if overlap_start > cursor:
            pieces.append((cursor, overlap_start))
        cursor = max(cursor, overlap_end)
    if cursor < end:
        pieces.append((cursor, end))
    kept = [(a, b) for a, b in pieces if (b - a) >= min_piece_s]
    fraction = gap_seconds / float(end - start) if end > start else 0.0
    return kept, round(fraction, 5)
