"""Typed request/response contract for POST /v1/sleep-features.

Locked by docs/SLEEP_FEATURES_CONTRACT.md (commit b9667119). Module owners
compute against the parsed request types here; they must not rename wire keys.
Validation is deliberately strict: a violated bound is a client defect (HTTP
422 / 413), never a silently-truncated feature document.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Mapping, Sequence

from ..contract import ContractError, _parse_utc, _fmt_utc

from . import ALGORITHM_VERSION, CONFIG_VERSION, SCHEMA_VERSION

# ---------------------------------------------------------------------------
# Bounds (spec 7.4 "Bounded work")
# ---------------------------------------------------------------------------

MAX_NIGHTS = 8
MAX_NIGHT_SECONDS = 16 * 3600
MAX_HR_SAMPLES = 60_000
MAX_TEMP_SAMPLES = 60_000
MAX_RR_BEATS = 120_000
MAX_BREATH_INTERVALS = 20_000
MAX_HISTORY_DAYS = 31
#: A local day is 1440 minutes except on DST fall-back days (1500); the cap
#: admits both so an honest 25 h grid is not refused.
MAX_HISTORY_MINUTES_PER_DAY = 1500
#: A history day with fewer valid minutes than this is "missing" for SRI
#: pairing purposes (a whole night off the wrist cannot be treated as a
#: schedule observation). 12 h is the spec's "monitored valid day" floor.
MIN_VALID_DAY_MINUTES = 720

STAGE_LABELS = ("wake", "light", "deep", "rem", "uns")
KNOWN_STAGES = ("wake", "light", "deep", "rem")

HR_BPM_RANGE = (20.0, 250.0)
TEMP_C_RANGE = (-10.0, 60.0)
RR_MS_RANGE = (200.0, 3000.0)
BREATH_S_RANGE = (0.5, 60.0)

#: Metric statuses (spec 7.3): every metric can be available / partial /
#: withheld / not_applicable, with a machine-readable reason.
METRIC_STATUSES = ("available", "partial", "withheld", "not_applicable")


def _err(code: str, message: str, http_status: int = 422, field_name: str | None = None) -> ContractError:
    return ContractError(code, message, http_status=http_status, field=field_name)


def _require(cond: bool, code: str, message: str, field_name: str | None = None) -> None:
    if not cond:
        raise _err(code, message, field_name=field_name)


def _finite_number(value: Any, lo: float, hi: float, where: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise _err("invalid_number", f"{where} must be a number")
    v = float(value)
    if not math.isfinite(v):
        raise _err("invalid_number", f"{where} must be finite")
    if not (lo <= v <= hi):
        raise _err("out_of_range", f"{where} {v} outside [{lo}, {hi}]")
    return v


# ---------------------------------------------------------------------------
# Parsed request
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class StageSegmentIn:
    start: int
    end: int
    stage: str


@dataclass(frozen=True)
class NightIn:
    night_id: str
    start: int  # unix seconds, half-open [start, end)
    end: int
    is_nap: bool
    user_edited: bool
    stages: tuple[StageSegmentIn, ...]


@dataclass(frozen=True)
class HrSampleIn:
    ts: int
    bpm: float


@dataclass(frozen=True)
class TempSampleIn:
    ts: int
    celsius: float


@dataclass(frozen=True)
class BeatIn:
    ts: int
    rr_ms: float
    seq: int | None
    ordn: int | None
    src_channel: int | None


@dataclass(frozen=True)
class BreathIn:
    ts: int
    seconds: float


@dataclass(frozen=True)
class BreathRunIn:
    start: int
    end: int


@dataclass(frozen=True)
class HistoryMinuteIn:
    ts: int  # unix seconds of the minute's start (UTC)
    state: int  # 1 sleep, 0 wake
    valid: bool


@dataclass(frozen=True)
class HistoryDayIn:
    day: str  # YYYY-MM-DD (local day of the history's timezone)
    minutes: tuple[HistoryMinuteIn, ...]


@dataclass(frozen=True)
class SleepFeaturesContext:
    user_id: str
    device_id: str
    day: str
    iana_timezone: str
    input_revision: int
    interval_start: int
    interval_end: int
    history_revision_digest: str | None
    #: The canonical staging algorithm actually claimed for the day (the
    #: worker's ``v2AlgorithmVersion``). Echoed per night so stage-conditioned
    #: features can be compared like-for-like (spec 4.3). The wire parser
    #: REQUIRES the key (the worker always sends it); the dataclass default
    #: exists only for direct in-process construction (unit tests).
    stage_algorithm_version: str = "unknown"


@dataclass(frozen=True)
class SleepFeaturesRequest:
    context: SleepFeaturesContext
    nights: tuple[NightIn, ...]
    hr: tuple[HrSampleIn, ...]
    temp: tuple[TempSampleIn, ...]
    beats: tuple[BeatIn, ...]
    breaths: tuple[BreathIn, ...]
    breath_runs: tuple[BreathRunIn, ...]
    history_days: tuple[HistoryDayIn, ...]
    capabilities: Mapping[str, Any]

    def main_night(self) -> NightIn | None:
        for n in self.nights:
            if not n.is_nap:
                return n
        return None


# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------


def _parse_utc_ts(value: Any, where: str) -> int:
    if not isinstance(value, str):
        raise _err("invalid_timestamp", f"{where} must be an ISO-8601 UTC string")
    try:
        return _parse_utc(value)
    except ContractError as exc:
        raise _err("invalid_timestamp", f"{where}: {exc.message}") from exc


def parse_request(body: Any) -> SleepFeaturesRequest:
    """Validate a whole POST /v1/sleep-features body."""
    _require(isinstance(body, Mapping), "invalid_request", "request body must be a JSON object")
    _require(body.get("schema_version") == SCHEMA_VERSION, "invalid_schema_version",
             f"schema_version must be {SCHEMA_VERSION}")
    _require(body.get("algorithm_version") == ALGORITHM_VERSION, "invalid_algorithm_version",
             f"algorithm_version must be {ALGORITHM_VERSION}")

    raw_ctx = body.get("context")
    _require(isinstance(raw_ctx, Mapping), "invalid_context", "context must be an object")
    for key in ("user_id", "device_id", "day", "iana_timezone"):
        _require(isinstance(raw_ctx.get(key), str) and raw_ctx.get(key), "invalid_context",
                 f"context.{key} must be a non-empty string", field_name=f"context.{key}")
    _require(isinstance(raw_ctx.get("input_revision"), int) and not isinstance(raw_ctx.get("input_revision"), bool),
             "invalid_context", "context.input_revision must be an integer",
             field_name="context.input_revision")
    interval_start = _parse_utc_ts(raw_ctx.get("interval_start_utc"), "context.interval_start_utc")
    interval_end = _parse_utc_ts(raw_ctx.get("interval_end_utc"), "context.interval_end_utc")
    _require(interval_end > interval_start, "invalid_context", "context interval is empty")
    history_digest = raw_ctx.get("history_revision_digest")
    _require(history_digest is None or isinstance(history_digest, str),
             "invalid_context", "history_revision_digest must be a string or absent",
             field_name="context.history_revision_digest")
    stage_algorithm_version = raw_ctx.get("stage_algorithm_version")
    _require(isinstance(stage_algorithm_version, str) and stage_algorithm_version,
             "invalid_context", "context.stage_algorithm_version must be a non-empty string",
             field_name="context.stage_algorithm_version")
    context = SleepFeaturesContext(
        user_id=raw_ctx["user_id"], device_id=raw_ctx["device_id"], day=raw_ctx["day"],
        iana_timezone=raw_ctx["iana_timezone"], input_revision=int(raw_ctx["input_revision"]),
        interval_start=interval_start, interval_end=interval_end,
        history_revision_digest=history_digest,
        stage_algorithm_version=stage_algorithm_version,
    )

    nights = _parse_nights(body.get("nights"))
    hr = _parse_hr(body.get("hr_samples"))
    temp = _parse_temp(body.get("skin_temp_samples"))
    beats = _parse_beats(body.get("rr_beats"))
    breaths, breath_runs = _parse_breaths(body.get("resp_breaths"))
    history = _parse_history(body.get("history"))
    capabilities = body.get("capabilities") or {}
    _require(isinstance(capabilities, Mapping), "invalid_capabilities",
             "capabilities must be an object")
    return SleepFeaturesRequest(
        context=context, nights=nights, hr=hr, temp=temp, beats=beats,
        breaths=breaths, breath_runs=breath_runs, history_days=history,
        capabilities=dict(capabilities),
    )


def _parse_nights(raw: Any) -> tuple[NightIn, ...]:
    _require(isinstance(raw, list) and 1 <= len(raw) <= MAX_NIGHTS, "invalid_nights",
             f"nights must be a list of 1..{MAX_NIGHTS} entries")
    out: list[NightIn] = []
    seen_ids: set[str] = set()
    for i, n in enumerate(raw):
        where = f"nights[{i}]"
        _require(isinstance(n, Mapping), "invalid_nights", f"{where} must be an object")
        night_id = n.get("night_id")
        _require(isinstance(night_id, str) and night_id and night_id not in seen_ids,
                 "invalid_nights", f"{where}.night_id must be unique and non-empty")
        seen_ids.add(night_id)
        start = _parse_utc_ts(n.get("start_utc"), f"{where}.start_utc")
        end = _parse_utc_ts(n.get("end_utc"), f"{where}.end_utc")
        _require(end > start, "invalid_nights", f"{where} is empty")
        _require(end - start <= MAX_NIGHT_SECONDS, "invalid_nights",
                  f"{where} longer than {MAX_NIGHT_SECONDS}s")
        is_nap = bool(n.get("is_nap", False))
        user_edited = bool(n.get("user_edited", False))
        stages_raw = n.get("stages")
        _require(isinstance(stages_raw, list), "invalid_nights", f"{where}.stages must be a list")
        stages: list[StageSegmentIn] = []
        for j, s in enumerate(stages_raw):
            swhere = f"{where}.stages[{j}]"
            _require(isinstance(s, Mapping), "invalid_nights", f"{swhere} must be an object")
            _require(isinstance(s.get("start"), int) and isinstance(s.get("end"), int)
                     and not isinstance(s.get("start"), bool) and not isinstance(s.get("end"), bool),
                     "invalid_nights", f"{swhere}.start/.end must be unix seconds")
            _require(s["end"] > s["start"], "invalid_nights", f"{swhere} is empty")
            stage = s.get("stage")
            _require(isinstance(stage, str) and stage in STAGE_LABELS, "invalid_nights",
                     f"{swhere}.stage must be one of {STAGE_LABELS}")
            stages.append(StageSegmentIn(start=int(s["start"]), end=int(s["end"]), stage=stage))
        stages.sort(key=lambda s: (s.start, s.end))
        out.append(NightIn(night_id=night_id, start=start, end=end, is_nap=is_nap,
                           user_edited=user_edited, stages=tuple(stages)))
    return tuple(out)


def _parse_hr(raw: Any) -> tuple[HrSampleIn, ...]:
    if raw is None:
        return ()
    _require(isinstance(raw, list) and len(raw) <= MAX_HR_SAMPLES, "invalid_hr_samples",
             f"hr_samples must be a list of at most {MAX_HR_SAMPLES} entries")
    out: list[HrSampleIn] = []
    for i, s in enumerate(raw):
        where = f"hr_samples[{i}]"
        _require(isinstance(s, Mapping), "invalid_hr_samples", f"{where} must be an object")
        _require(isinstance(s.get("ts"), int) and not isinstance(s.get("ts"), bool),
                 "invalid_hr_samples", f"{where}.ts must be unix seconds")
        bpm = _finite_number(s.get("bpm"), *HR_BPM_RANGE, where=f"{where}.bpm")
        out.append(HrSampleIn(ts=int(s["ts"]), bpm=bpm))
    out.sort(key=lambda s: s.ts)
    return tuple(out)


def _parse_temp(raw: Any) -> tuple[TempSampleIn, ...]:
    if raw is None:
        return ()
    _require(isinstance(raw, list) and len(raw) <= MAX_TEMP_SAMPLES, "invalid_temp_samples",
             f"skin_temp_samples must be a list of at most {MAX_TEMP_SAMPLES} entries")
    out: list[TempSampleIn] = []
    for i, s in enumerate(raw):
        where = f"skin_temp_samples[{i}]"
        _require(isinstance(s, Mapping), "invalid_temp_samples", f"{where} must be an object")
        _require(isinstance(s.get("ts"), int) and not isinstance(s.get("ts"), bool),
                 "invalid_temp_samples", f"{where}.ts must be unix seconds")
        c = _finite_number(s.get("celsius"), *TEMP_C_RANGE, where=f"{where}.celsius")
        out.append(TempSampleIn(ts=int(s["ts"]), celsius=c))
    out.sort(key=lambda s: s.ts)
    return tuple(out)


def _parse_beats(raw: Any) -> tuple[BeatIn, ...]:
    if raw is None:
        return ()
    _require(isinstance(raw, list) and len(raw) <= MAX_RR_BEATS, "invalid_rr_beats",
             f"rr_beats must be a list of at most {MAX_RR_BEATS} entries")
    out: list[BeatIn] = []
    for i, b in enumerate(raw):
        where = f"rr_beats[{i}]"
        _require(isinstance(b, Mapping), "invalid_rr_beats", f"{where} must be an object")
        _require(isinstance(b.get("ts"), int) and not isinstance(b.get("ts"), bool),
                 "invalid_rr_beats", f"{where}.ts must be unix seconds")
        rr = _finite_number(b.get("rr_ms"), *RR_MS_RANGE, where=f"{where}.rr_ms")
        seq = b.get("seq")
        ordn = b.get("ord")
        src = b.get("src_channel")
        _require(seq is None or isinstance(seq, int), "invalid_rr_beats", f"{where}.seq must be int or null")
        _require(ordn is None or isinstance(ordn, int), "invalid_rr_beats", f"{where}.ord must be int or null")
        _require(src is None or isinstance(src, int), "invalid_rr_beats",
                 f"{where}.src_channel must be int or null")
        out.append(BeatIn(ts=int(b["ts"]), rr_ms=rr, seq=seq, ordn=ordn, src_channel=src))
    out.sort(key=lambda b: (b.ts, b.seq if b.seq is not None else 1 << 30,
                            b.ordn if b.ordn is not None else 1 << 30))
    return tuple(out)


def _parse_breaths(raw: Any) -> tuple[tuple[BreathIn, ...], tuple[BreathRunIn, ...]]:
    if raw is None:
        return (), ()
    _require(isinstance(raw, Mapping), "invalid_resp_breaths", "resp_breaths must be an object")
    intervals_raw = raw.get("intervals") or []
    runs_raw = raw.get("runs") or []
    _require(isinstance(intervals_raw, list) and len(intervals_raw) <= MAX_BREATH_INTERVALS,
             "invalid_resp_breaths",
             f"resp_breaths.intervals must be a list of at most {MAX_BREATH_INTERVALS} entries")
    _require(isinstance(runs_raw, list) and len(runs_raw) <= MAX_BREATH_INTERVALS,
             "invalid_resp_breaths", "resp_breaths.runs must be a bounded list")
    intervals: list[BreathIn] = []
    for i, s in enumerate(intervals_raw):
        where = f"resp_breaths.intervals[{i}]"
        _require(isinstance(s, Mapping), "invalid_resp_breaths", f"{where} must be an object")
        _require(isinstance(s.get("ts"), int) and not isinstance(s.get("ts"), bool),
                 "invalid_resp_breaths", f"{where}.ts must be unix seconds")
        seconds = _finite_number(s.get("seconds"), *BREATH_S_RANGE, where=f"{where}.seconds")
        intervals.append(BreathIn(ts=int(s["ts"]), seconds=seconds))
    intervals.sort(key=lambda s: s.ts)
    runs: list[BreathRunIn] = []
    for i, s in enumerate(runs_raw):
        where = f"resp_breaths.runs[{i}]"
        _require(isinstance(s, Mapping), "invalid_resp_breaths", f"{where} must be an object")
        _require(isinstance(s.get("start"), int) and isinstance(s.get("end"), int)
                 and not isinstance(s.get("start"), bool) and not isinstance(s.get("end"), bool)
                 and s["end"] >= s["start"], "invalid_resp_breaths",
                 f"{where} must be [start, end] unix seconds")
        runs.append(BreathRunIn(start=int(s["start"]), end=int(s["end"])))
    runs.sort(key=lambda r: r.start)
    return tuple(intervals), tuple(runs)


def _parse_history(raw: Any) -> tuple[HistoryDayIn, ...]:
    if raw is None:
        return ()
    _require(isinstance(raw, Mapping), "invalid_history", "history must be an object")
    _require(raw.get("pair_policy") == "elapsed_24h", "invalid_history",
             'history.pair_policy must be "elapsed_24h"')
    days_raw = raw.get("days") or []
    _require(isinstance(days_raw, list) and len(days_raw) <= MAX_HISTORY_DAYS, "invalid_history",
             f"history.days must be a list of at most {MAX_HISTORY_DAYS} entries")
    out: list[HistoryDayIn] = []
    for i, d in enumerate(days_raw):
        where = f"history.days[{i}]"
        _require(isinstance(d, Mapping), "invalid_history", f"{where} must be an object")
        day = d.get("day")
        import re as _re
        _require(isinstance(day, str) and _re.fullmatch(r"\d{4}-\d{2}-\d{2}", day or ""),
                 "invalid_history", f"{where}.day must be YYYY-MM-DD")
        minutes_raw = d.get("minutes") or []
        _require(isinstance(minutes_raw, list) and len(minutes_raw) <= MAX_HISTORY_MINUTES_PER_DAY,
                 "invalid_history", f"{where}.minutes must be a bounded list")
        minutes: list[HistoryMinuteIn] = []
        for j, m in enumerate(minutes_raw):
            mwhere = f"{where}.minutes[{j}]"
            _require(isinstance(m, Mapping), "invalid_history", f"{mwhere} must be an object")
            _require(isinstance(m.get("ts"), int) and not isinstance(m.get("ts"), bool),
                     "invalid_history", f"{mwhere}.ts must be unix seconds")
            _require(m.get("state") in (0, 1), "invalid_history", f"{mwhere}.state must be 0 or 1")
            _require(isinstance(m.get("valid"), bool), "invalid_history",
                     f"{mwhere}.valid must be a boolean")
            minutes.append(HistoryMinuteIn(ts=int(m["ts"]), state=int(m["state"]),
                                           valid=bool(m["valid"])))
        minutes.sort(key=lambda m: m.ts)
        out.append(HistoryDayIn(day=day, minutes=tuple(minutes)))
    return tuple(out)


# ---------------------------------------------------------------------------
# Response builders (shared helpers for module owners)
# ---------------------------------------------------------------------------


def json_finite(value: float | None) -> float | None:
    """Render a finite number, or None for NaN/inf/None (never invalid JSON)."""
    if value is None:
        return None
    v = float(value)
    return v if math.isfinite(v) else None


def metric_status(status: str, reasons: Sequence[str] = ()) -> dict[str, Any]:
    assert status in METRIC_STATUSES, status
    return {"status": status, "reasons": list(reasons)}


def versions_block(yasa_version: str, numpy_version: str, scipy_version: str,
                   neurokit2_version: str, sleepecg_version: str,
                   config: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "yasa": yasa_version,
        "numpy": numpy_version,
        "scipy": scipy_version,
        "neurokit2": neurokit2_version,
        "sleepecg": sleepecg_version,
        "config_version": CONFIG_VERSION,
        "config": dict(config),
    }


def fmt_utc(ts: int) -> str:
    return _fmt_utc(ts)
