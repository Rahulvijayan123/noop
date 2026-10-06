"""Frozen request/response contract for the FRWHOOP inference sidecar.

This module owns everything that is shared between the HTTP server and the
metric providers:

* version constants and the metric domain,
* the machine-readable withheld-reason enum (the wire contract),
* request/response dataclasses,
* validation of shape, bounds, label space, finiteness, timestamps and identity,
* an independent valid-pair RMSSD reference implementation.

Design rules
------------
* Standard library only (no pydantic, no aiohttp). Numeric work uses numpy.
* Every validation failure raises :class:`ContractError` with a stable ``code``
  so the server can map it to an HTTP status without guessing.
* The reference RMSSD in this module is deliberately written from first
  principles (sum of squared differences over an explicit adjacency mask). It is
  the oracle the provider tests check the production port against, so it must not
  share code with the provider.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Iterable, Mapping, Sequence
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# --------------------------------------------------------------------------
# Version constants
# --------------------------------------------------------------------------

CONTRACT_VERSION = "1.0.0"
PACKAGE_VERSION = "0.1.0"
SERVER_NAME = "frwhoop-inference"

#: Provider-independent adapter revision. Bumped whenever the validation or
#: serialisation behaviour of this package changes.
ADAPTER_VERSION = "frwhoop-inference.adapter/1.0.0"

#: ``sensor_biomarkers`` (additive sensor-biomarker families; docs/sensor-biomarkers/CONTRACTS.md)
#: owns its payload validation inside the provider package, exactly like the sleep
#: candidates: the provider checks shapes, bounds, finiteness and timestamps and
#: answers with status="error" plus a machine-readable diagnostics.reason_detail.
METRICS: tuple[str, ...] = ("hrv", "sleep_boundary", "sleep_stage", "respiration",
                            "sensor_biomarkers")

#: Status values permitted in a response.
STATUSES: tuple[str, ...] = ("ok", "withheld", "error")

#: final_or_provisional values.
FINALITY_VALUES: tuple[str, ...] = ("final", "provisional")

#: Timestamp convention for HRV interval evidence (spec section 5: verify the
#: meaning of the packet timestamp before reconstructing beat end times).
TIMESTAMP_CONVENTION = "interval_end_seconds"
TIMESTAMP_RESOLUTION = "whole_seconds"


# --------------------------------------------------------------------------
# Withheld reasons (wire contract)
# --------------------------------------------------------------------------


class WithheldReason(str, Enum):
    """Machine-readable withheld reasons.

    The first nine members are exactly the enum fixed by the shared plan
    (``Sidecar HTTP contract``). ``UNRESOLVED_ADJACENCY`` is an HRV-specific
    extension required by the HRV adapter contract: when a burst boundary cannot
    be resolved from observation identity, the interval series must be withheld
    rather than silently spliced (spec section 5).
    """

    BLOCKED_INPUT = "blocked_input"
    BLOCKED_ARTIFACT = "blocked_artifact"
    BLOCKED_LICENSE = "blocked_license"
    UNVERIFIED = "unverified"
    INSUFFICIENT_COVERAGE = "insufficient_coverage"
    ARTIFACT_FRACTION = "artifact_fraction"
    PROVIDER_ERROR = "provider_error"
    TIMEOUT = "timeout"
    NOT_READY = "not_ready"
    UNRESOLVED_ADJACENCY = "unresolved_adjacency"


# --------------------------------------------------------------------------
# Errors
# --------------------------------------------------------------------------


class ContractError(Exception):
    """A request violated the contract.

    ``http_status`` is the status the server must return; ``code`` is a stable
    machine-readable identifier that never changes meaning.
    """

    def __init__(self, code: str, message: str, http_status: int = 400, field: str | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.http_status = http_status
        self.field = field

    def to_wire(self) -> dict[str, Any]:
        err: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.field is not None:
            err["field"] = self.field
        return {"status": "error", "error": err}


# --------------------------------------------------------------------------
# Bounds
# --------------------------------------------------------------------------

#: Absolute input sanity bounds for an RR interval, in milliseconds. Values
#: outside these bounds are not "out of range beats" to be filtered later, they
#: are a malformed payload. The production range filter (300-2000 ms) is applied
#: by the provider, so physiologically implausible but well-formed values (for
#: example 250 ms or 2500 ms) must pass validation and be rejected by the
#: filter, with counts reported.
RR_INPUT_MIN_MS = 50.0
RR_INPUT_MAX_MS = 30000.0

MAX_BEATS = 300_000
MAX_WINDOWS = 4096
MAX_ID_LEN = 128
MAX_BODY_BYTES = 8 * 1024 * 1024

#: Slack, in seconds, allowed on either side of the context interval when checking
#: that ``input.beats`` describes the SAME interval. A client that sends the
#: enclosing analysis window - the shipped worker sends a 30 h-before / 54 h-after
#: read window - or that rounds an edge is still describing one night, while the
#: smallest realistic mismatch (a timezone or DST slip) is 3600 s, an order of
#: magnitude larger. Beats for the wrong interval are therefore refused instead of
#: being silently reported as an empty night.
BEAT_INTERVAL_SLACK_S = 300

_ID_RE = re.compile(r"^[A-Za-z0-9._:\-]+$")


# --------------------------------------------------------------------------
# Result payload rules
# --------------------------------------------------------------------------

#: Hard bound on a scalar result value, in the metric's own unit. Finiteness is
#: checked separately; this catches a unit mistake (seconds instead of
#: milliseconds, a raw sample count, an unnormalised score) that would otherwise
#: be persisted as a plausible-looking number.
RESULT_VALUE_ABS_MAX = 1e9

#: Keys the response envelope owns inside ``result``. A structured payload may
#: not set them, so a provider cannot clobber the scalar envelope.
RESULT_RESERVED_KEYS = ("value", "unit")

#: Shape limits for a structured result payload.
STRUCTURED_RESULT_MAX_DEPTH = 6
STRUCTURED_RESULT_MAX_LEAVES = 100_000
STRUCTURED_RESULT_MAX_STRING = 4096
STRUCTURED_RESULT_MAX_KEYS = 256


def validate_structured_result(payload: Any) -> dict[str, Any]:
    """Validate a structured result payload and return a normalised plain dict.

    The wire envelope renders ``result`` as an object, so a structured payload
    must be a mapping. Every leaf must be JSON-safe: strings, booleans, finite
    numbers or null. Two metric-level conventions are enforced because the
    consumer depends on them:

    * ``stages`` (the slot the Swift client and the candidate RPC read) must be a
      non-empty list or mapping, and must be accompanied by a non-empty
      ``label_space`` - a stage payload without its label space is rejected by the
      candidate RPC and demoted by the worker, so it is refused here instead;
    * the envelope keys ``value`` and ``unit`` are reserved.

    Raises ``ValueError`` on any violation. Callers treat that as a provider
    defect, not bad client input.
    """
    if not isinstance(payload, Mapping):
        raise ValueError("structured result must be an object")
    if not payload:
        raise ValueError("structured result must not be empty")

    leaves = 0

    def walk(node: Any, depth: int, where: str) -> Any:
        nonlocal leaves
        if depth > STRUCTURED_RESULT_MAX_DEPTH:
            raise ValueError(f"{where}: nesting deeper than {STRUCTURED_RESULT_MAX_DEPTH}")
        if node is None or isinstance(node, bool):
            leaves += 1
            return node
        if isinstance(node, str):
            if len(node) > STRUCTURED_RESULT_MAX_STRING:
                raise ValueError(f"{where}: string longer than {STRUCTURED_RESULT_MAX_STRING}")
            leaves += 1
            return node
        if isinstance(node, (int, float)):
            number = float(node)
            if not math.isfinite(number):
                raise ValueError(f"{where}: non-finite number")
            if abs(number) > RESULT_VALUE_ABS_MAX:
                raise ValueError(f"{where}: magnitude exceeds {RESULT_VALUE_ABS_MAX:g}")
            leaves += 1
            return node
        if isinstance(node, Mapping):
            if len(node) > STRUCTURED_RESULT_MAX_KEYS:
                raise ValueError(f"{where}: more than {STRUCTURED_RESULT_MAX_KEYS} keys")
            out: dict[str, Any] = {}
            for key, value in node.items():
                if not isinstance(key, str) or not key:
                    raise ValueError(f"{where}: keys must be non-empty strings")
                out[key] = walk(value, depth + 1, f"{where}.{key}")
            leaves += 1
            return out
        if isinstance(node, (list, tuple)):
            out_list = [walk(item, depth + 1, f"{where}[{index}]")
                        for index, item in enumerate(node)]
            leaves += 1
            return out_list
        raise ValueError(f"{where}: unsupported type {type(node).__name__}")

    normalised = walk(dict(payload), 1, "result")
    if leaves > STRUCTURED_RESULT_MAX_LEAVES:
        raise ValueError(f"structured result has more than {STRUCTURED_RESULT_MAX_LEAVES} leaves")
    for reserved in RESULT_RESERVED_KEYS:
        if reserved in normalised:
            raise ValueError(f"structured result must not set the envelope key {reserved!r}")

    if "label_space" in normalised:
        label_space = normalised["label_space"]
        if not isinstance(label_space, str) or not label_space:
            raise ValueError("result.label_space must be a non-empty string")
    if "stages" in normalised:
        stages = normalised["stages"]
        if isinstance(stages, (str, bytes)) or not isinstance(stages, (list, tuple, Mapping)):
            raise ValueError("result.stages must be a list or an object")
        if not stages:
            raise ValueError("result.stages must not be empty")
        if not normalised.get("label_space"):
            raise ValueError("result.stages requires result.label_space")
    return normalised


# --------------------------------------------------------------------------
# Request models
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class Beat:
    """One stored RR observation.

    ``ts`` is the whole-second unix timestamp of the packet that carried the
    interval (``Streams.swift:89``). ``seq``/``ord`` are the in-packet delivery
    counters. ``observation_id`` is an optional server-side identity.
    """

    ts: int
    rr_ms: float
    seq: int | None = None
    ord: int | None = None
    src_channel: int | None = None
    observation_id: str | None = None

    @property
    def identity(self) -> tuple[Any, ...]:
        """Physical observation identity.

        Retransmission duplicates share an identity; two genuine beats in the
        same second with the same value do not, because their ``seq``/``ord``
        (or explicit ``observation_id``) differ. Dedup uses this, never the RR
        value alone (spec section 5).
        """
        if self.observation_id is not None:
            return (self.observation_id,)
        return (self.ts, self.rr_ms, self.src_channel, self.seq, self.ord)


@dataclass(frozen=True)
class Window:
    """An analysis window.

    ``half_open=False`` (the default) matches ``HRVAnalyzer.analyze``, whose
    filter is inclusive on both ends. ``half_open=True`` makes the upper bound
    exclusive, which is the rule the shipped tumbling window generator uses
    (``SleepStager.sessionHrvWindows``: ``[t, t + windowS)`` for every window
    except the final one, which is ``[t, end]``). Without it, back-to-back
    tumbling windows would score a boundary beat twice.
    """

    start: int
    end: int
    session_id: str | None = None
    stage: str | None = None
    half_open: bool = False

    def contains(self, ts: int) -> bool:
        if ts < self.start:
            return False
        return ts < self.end if self.half_open else ts <= self.end


@dataclass(frozen=True)
class Context:
    """Immutable input identity for one inference request."""

    user_id: str
    device_id: str
    interval_start_utc: str
    interval_end_utc: str
    iana_timezone: str
    profile_version: str
    config_version: str
    corrections_version: str
    live: bool = False

    @property
    def start_ts(self) -> int:
        return _parse_utc(self.interval_start_utc)

    @property
    def end_ts(self) -> int:
        return _parse_utc(self.interval_end_utc)

    def to_wire(self) -> dict[str, Any]:
        return {
            "user_id": self.user_id,
            "device_id": self.device_id,
            "interval_start_utc": self.interval_start_utc,
            "interval_end_utc": self.interval_end_utc,
            "iana_timezone": self.iana_timezone,
            "profile_version": self.profile_version,
            "config_version": self.config_version,
            "corrections_version": self.corrections_version,
        }


@dataclass(frozen=True)
class HrvInput:
    """Validated HRV payload.

    ``aggregation`` keeps the caller's spelling (see ``HRV_AGGREGATIONS``);
    ``is_session_aggregation`` is the predicate that decides whether it selects
    the session mean over usable windows.
    """

    beats: tuple[Beat, ...]
    windows: tuple[Window, ...]
    aggregation: str = "window"

    def to_wire(self) -> dict[str, Any]:
        return {
            "beats": [
                {
                    "ts": b.ts,
                    "rr_ms": b.rr_ms,
                    "seq": b.seq,
                    "ord": b.ord,
                    "src_channel": b.src_channel,
                    "observation_id": b.observation_id,
                }
                for b in self.beats
            ],
            "windows": [
                {"start_utc": _fmt_utc(w.start), "end_utc": _fmt_utc(w.end),
                 "session_id": w.session_id, "stage": w.stage,
                 "half_open": w.half_open}
                for w in self.windows
            ],
            "aggregation": self.aggregation,
        }


@dataclass(frozen=True)
class InferRequest:
    """A fully validated inference request."""

    metric: str
    context: Context
    input: Any  # HrvInput today; other metrics add their own validated payload.
    provider_id: str | None
    expected_versions: Mapping[str, str] | None
    raw_input: Mapping[str, Any]
    input_sha256: str
    input_refs: tuple[dict[str, Any], ...]

    def to_wire(self) -> dict[str, Any]:
        return {
            "metric": self.metric,
            "context": self.context.to_wire(),
            "input": self.input.to_wire(),
            "provider": {"provider_id": self.provider_id,
                         "expected_versions": dict(self.expected_versions or {})},
        }


@dataclass
class ProviderResult:
    """What a provider returns; the server renders the wire shape."""

    status: str
    value: float | None = None
    unit: str | None = None
    withheld_reason: str | None = None
    label_space: str | None = None
    stages: Any = None
    final_or_provisional: str = "final"
    coverage: dict[str, Any] = field(default_factory=dict)
    diagnostics: dict[str, Any] = field(default_factory=dict)
    versions: dict[str, Any] = field(default_factory=dict)
    raw_scores: dict[str, Any] | None = None
    publishable: bool = True

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            raise ValueError(f"bad status {self.status!r}")
        if self.status == "ok":
            if self.value is None and self.stages is None:
                raise ValueError("status ok requires a value or stages")
            if self.value is not None and not math.isfinite(float(self.value)):
                raise ValueError("status ok requires a finite value")
            if self.stages is not None:
                if self.label_space is None:
                    raise ValueError("structured ok results require a label_space")
                if not isinstance(self.stages, (list, tuple)):
                    raise ValueError("stages must be a list of stage segments")
        if self.status == "withheld":
            if self.value is not None:
                raise ValueError("status withheld must not carry a value")
            if self.stages is not None:
                raise ValueError("status withheld must not carry stages")
            if self.withheld_reason is None:
                raise ValueError("status withheld requires a withheld_reason")
            valid = {r.value for r in WithheldReason}
            if self.withheld_reason not in valid:
                raise ValueError(f"unknown withheld_reason {self.withheld_reason!r}")
        if self.final_or_provisional not in FINALITY_VALUES:
            raise ValueError(f"bad final_or_provisional {self.final_or_provisional!r}")


# --------------------------------------------------------------------------
# Timestamp helpers
# --------------------------------------------------------------------------


def _parse_utc(value: Any) -> int:
    """Parse an ISO-8601 UTC timestamp to whole unix seconds."""
    if not isinstance(value, str) or not value:
        raise ContractError("invalid_timestamp", "timestamp must be a non-empty ISO-8601 string")
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError as exc:
        raise ContractError("invalid_timestamp", f"unparseable timestamp {value!r}: {exc}") from exc
    if dt.tzinfo is None:
        raise ContractError("invalid_timestamp", f"timestamp {value!r} has no timezone offset")
    return int(dt.timestamp())


def _fmt_utc(ts: int) -> str:
    return datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_day(ts: int, tz_name: str) -> str:
    """Local calendar day (YYYY-MM-DD) of a unix timestamp in an IANA zone."""
    return datetime.fromtimestamp(int(ts), tz=ZoneInfo(tz_name)).strftime("%Y-%m-%d")


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------


def _require_str(obj: Mapping[str, Any], key: str, where: str) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ContractError("invalid_context", f"{where}.{key} must be a non-empty string",
                            field=f"{where}.{key}")
    if len(value) > MAX_ID_LEN:
        raise ContractError("invalid_context", f"{where}.{key} is longer than {MAX_ID_LEN}",
                            field=f"{where}.{key}")
    return value.strip()


def _require_identity(obj: Mapping[str, Any], key: str, where: str) -> str:
    value = _require_str(obj, key, where)
    if not _ID_RE.match(value):
        raise ContractError("invalid_identity", f"{where}.{key} has unsupported characters",
                            field=f"{where}.{key}")
    return value


def parse_context(raw: Any) -> Context:
    if not isinstance(raw, Mapping):
        raise ContractError("invalid_context", "context must be an object", field="context")
    user_id = _require_identity(raw, "user_id", "context")
    device_id = _require_identity(raw, "device_id", "context")
    start_raw = _require_str(raw, "interval_start_utc", "context")
    end_raw = _require_str(raw, "interval_end_utc", "context")
    start_ts = _parse_utc(start_raw)
    end_ts = _parse_utc(end_raw)
    if end_ts <= start_ts:
        raise ContractError("invalid_timestamp", "interval_end_utc must be after interval_start_utc",
                            field="context.interval_end_utc")
    tz_name = _require_str(raw, "iana_timezone", "context")
    try:
        ZoneInfo(tz_name)
    except (ZoneInfoNotFoundError, ValueError) as exc:
        raise ContractError("invalid_timezone", f"unknown IANA timezone {tz_name!r}",
                            field="context.iana_timezone") from exc
    live = raw.get("live", False)
    if not isinstance(live, bool):
        raise ContractError("invalid_context", "context.live must be a boolean", field="context.live")
    return Context(
        user_id=user_id,
        device_id=device_id,
        interval_start_utc=_fmt_utc(start_ts),
        interval_end_utc=_fmt_utc(end_ts),
        iana_timezone=tz_name,
        profile_version=_require_str(raw, "profile_version", "context"),
        config_version=_require_str(raw, "config_version", "context"),
        corrections_version=_require_str(raw, "corrections_version", "context"),
        live=live,
    )


def _opt_int(value: Any, field_name: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise ContractError("invalid_input", f"{field_name} must be an integer or null", field=field_name)
    return value


def _finite_number(value: Any, field_name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ContractError("invalid_input", f"{field_name} must be a number", field=field_name)
    out = float(value)
    if not math.isfinite(out):
        raise ContractError("non_finite_input", f"{field_name} must be finite", field=field_name)
    return out


#: Aggregation spellings accepted on the wire.
#:
#: ``mean_over_windows`` is the Swift worker's spelling of the nightly session
#: value (``DayScoring.hrvConfig()["aggregation"]``, and, after the S-1 repair,
#: also top-level ``input.aggregation``): the plain mean over the session's
#: USABLE windows. ``session`` is the legacy alias for exactly the same
#: arithmetic and is still accepted, so no earlier caller breaks. ``day`` is the
#: duration-weighted mean across sessions.
HRV_AGGREGATIONS = ("window", "mean_over_windows", "session", "day")

#: The spellings that select "plain mean over the session's usable windows".
SESSION_HRV_AGGREGATIONS = ("mean_over_windows", "session")


def is_session_aggregation(aggregation: str) -> bool:
    """True when ``aggregation`` selects the session mean over usable windows.

    ``mean_over_windows`` (the worker's spelling) and ``session`` (the legacy
    alias) are the same arithmetic. Both providers ask this one predicate, so
    they can never disagree about which spellings select the session path.
    """
    return aggregation in SESSION_HRV_AGGREGATIONS


def _resolve_hrv_aggregation(raw: Mapping[str, Any], *, has_windows: bool) -> str:
    """Resolve ``input.aggregation``, mirroring ``input.config.aggregation``.

    The Swift worker states its intent inside ``input.config``
    (``"aggregation": "mean_over_windows"``, ``DayScoring.hrvConfig()``) and used
    to send no top-level ``aggregation`` at all. The parser ignored the config
    copy and defaulted to ``"window"``, so the candidate value was the FIRST
    5-minute window's RMSSD instead of the whole-night session mean (audit S-1).

    A top-level ``aggregation`` wins. The config copy is read as a back-compat
    mirror so a payload from an un-rebuilt worker still aggregates the night. An
    unknown spelling is refused rather than silently downgraded to ``"window"``,
    because a payload/parser mismatch of this class must not pass unnoticed.
    """
    config = raw.get("config")
    mirrored = config.get("aggregation") if isinstance(config, Mapping) else None
    if raw.get("aggregation") is not None:
        chosen: Any = raw.get("aggregation")
        field = "input.aggregation"
    elif mirrored is not None:
        chosen = mirrored
        field = "input.config.aggregation"
    else:
        # Back-compat default: a caller that supplied windows wanted them
        # aggregated; a caller that supplied none gets the single window the
        # provider derives from the context interval.
        return "session" if has_windows else "window"
    if not isinstance(chosen, str):
        raise ContractError("invalid_input", f"{field} must be a string", field=field)
    if chosen not in HRV_AGGREGATIONS:
        raise ContractError(
            "invalid_input",
            f"{field} must be one of {'|'.join(HRV_AGGREGATIONS)} "
            "('mean_over_windows' is the session mean over usable windows)",
            field=field,
        )
    return chosen


def parse_hrv_input(raw: Any, context: Context) -> HrvInput:
    """Validate an HRV payload.

    ``input.beats`` is required. ``input.windows`` is optional; when absent the
    single window is the context interval.

    ``input.aggregation`` selects the result: ``window`` scores the first (and,
    with supplied windows, only) window, ``mean_over_windows`` scores the plain
    mean over the session's usable windows, ``session`` is the legacy alias for
    it, and ``day`` is the duration-weighted mean across sessions. When the key
    is absent the value is mirrored from ``input.config.aggregation`` and, failing
    that, defaults to ``session`` with supplied windows and ``window`` without.
    """
    if not isinstance(raw, Mapping):
        raise ContractError("invalid_input", "input must be an object", field="input")
    beats_raw = raw.get("beats")
    if not isinstance(beats_raw, Sequence) or isinstance(beats_raw, (str, bytes)):
        raise ContractError("invalid_input", "input.beats must be an array", field="input.beats")
    if not beats_raw:
        raise ContractError("blocked_input", "input.beats is empty", field="input.beats")
    if len(beats_raw) > MAX_BEATS:
        raise ContractError("invalid_input", f"input.beats exceeds {MAX_BEATS} rows",
                            field="input.beats")

    beats: list[Beat] = []
    previous_ts: int | None = None
    for index, row in enumerate(beats_raw):
        where = f"input.beats[{index}]"
        if not isinstance(row, Mapping):
            raise ContractError("invalid_input", f"{where} must be an object", field=where)
        ts = row.get("ts")
        if isinstance(ts, bool) or not isinstance(ts, int):
            raise ContractError("invalid_timestamp", f"{where}.ts must be whole unix seconds",
                                field=f"{where}.ts")
        if ts <= 0 or ts > 4_102_444_800:
            raise ContractError("invalid_timestamp", f"{where}.ts is outside the supported range",
                                field=f"{where}.ts")
        if previous_ts is not None and ts < previous_ts:
            raise ContractError("unsorted_input",
                                f"{where}.ts is earlier than the previous row; beats must be "
                                "non-decreasing by ts (within-packet order is preserved by seq/ord)",
                                field=f"{where}.ts")
        previous_ts = ts
        rr_ms = _finite_number(row.get("rr_ms"), f"{where}.rr_ms")
        if rr_ms < RR_INPUT_MIN_MS or rr_ms > RR_INPUT_MAX_MS:
            raise ContractError(
                "out_of_bounds_input",
                f"{where}.rr_ms={rr_ms} is outside the absolute input bounds "
                f"[{RR_INPUT_MIN_MS}, {RR_INPUT_MAX_MS}] ms",
                field=f"{where}.rr_ms",
            )
        observation_id = row.get("observation_id")
        if observation_id is not None and (not isinstance(observation_id, str) or not observation_id):
            raise ContractError("invalid_input", f"{where}.observation_id must be a non-empty string",
                                field=f"{where}.observation_id")
        beats.append(
            Beat(
                ts=ts,
                rr_ms=rr_ms,
                seq=_opt_int(row.get("seq"), f"{where}.seq"),
                ord=_opt_int(row.get("ord"), f"{where}.ord"),
                src_channel=_opt_int(row.get("src_channel"), f"{where}.src_channel"),
                observation_id=observation_id,
            )
        )

    # The beats must describe the SAME interval as the context. A payload whose
    # beats all lie outside the interval is a client/interval mismatch (the wrong
    # night, a timezone slip), and it used to surface as a normal 200 ``withheld``
    # with ``no_beats_in_window`` - indistinguishable from an interval that simply
    # has no beats (review F6). The band allows ``BEAT_INTERVAL_SLACK_S`` on each
    # side, so a client that sends the enclosing read window is unaffected, and an
    # in-band but empty WINDOW still withholds with ``no_beats_in_window``.
    #
    # This is a set-level rule on purpose: the shipped worker sends a SUPERSET of
    # beats (``DayScoring.swift`` loads RR over a 30 h-before / 54 h-after night
    # window and sends the main sleep session as the interval), so rejecting an
    # individual beat that falls outside the interval would refuse normal traffic.
    low_ts = context.start_ts - BEAT_INTERVAL_SLACK_S
    high_ts = context.end_ts + BEAT_INTERVAL_SLACK_S
    if not any(low_ts <= beat.ts <= high_ts for beat in beats):
        raise ContractError(
            "out_of_bounds_input",
            f"no input.beats[].ts lies inside the context interval "
            f"[{context.interval_start_utc}, {context.interval_end_utc}] "
            f"(+/-{BEAT_INTERVAL_SLACK_S}s slack); the beats span "
            f"{beats[0].ts}..{beats[-1].ts}, so the payload and the interval "
            "describe different spans",
            field="input.beats",
        )

    windows_raw = raw.get("windows")
    windows: list[Window] = []
    if windows_raw is not None:
        if not isinstance(windows_raw, Sequence) or isinstance(windows_raw, (str, bytes)):
            raise ContractError("invalid_input", "input.windows must be an array", field="input.windows")
        if len(windows_raw) > MAX_WINDOWS:
            raise ContractError("invalid_input", f"input.windows exceeds {MAX_WINDOWS} rows",
                                field="input.windows")
        for index, row in enumerate(windows_raw):
            where = f"input.windows[{index}]"
            if not isinstance(row, Mapping):
                raise ContractError("invalid_input", f"{where} must be an object", field=where)
            start = _parse_utc(row.get("start_utc"))
            end = _parse_utc(row.get("end_utc"))
            if end < start:
                raise ContractError("invalid_timestamp", f"{where}.end_utc precedes start_utc",
                                    field=f"{where}.end_utc")
            if start < context.start_ts or end > context.end_ts:
                raise ContractError(
                    "out_of_bounds_input",
                    f"{where} lies outside the context interval "
                    f"[{context.interval_start_utc}, {context.interval_end_utc}]",
                    field=where,
                )
            session_id = row.get("session_id")
            if session_id is not None and not isinstance(session_id, str):
                raise ContractError("invalid_input", f"{where}.session_id must be a string",
                                    field=f"{where}.session_id")
            stage = row.get("stage")
            if stage is not None and not isinstance(stage, str):
                raise ContractError("invalid_input", f"{where}.stage must be a string",
                                    field=f"{where}.stage")
            half_open = row.get("half_open", False)
            if not isinstance(half_open, bool):
                raise ContractError("invalid_input", f"{where}.half_open must be a boolean",
                                    field=f"{where}.half_open")
            windows.append(Window(start=start, end=end, session_id=session_id, stage=stage,
                                  half_open=half_open))
        if not windows:
            raise ContractError("blocked_input", "input.windows is empty", field="input.windows")

    aggregation = _resolve_hrv_aggregation(raw, has_windows=bool(windows))
    # The single-window rule applies only when the caller SUPPLIED windows: with
    # no windows the provider derives them from the context interval, and the
    # "window" aggregation then means "the one window that covers the interval".
    if aggregation == "window" and windows and len(windows) != 1:
        raise ContractError("invalid_input",
                            "input.aggregation=window requires exactly one window",
                            field="input.windows")
    if aggregation == "day" and not windows:
        raise ContractError("invalid_input", "input.aggregation=day requires windows",
                            field="input.windows")

    return HrvInput(beats=tuple(beats), windows=tuple(windows), aggregation=aggregation)


def canonical_sha256(payload: Any) -> str:
    """sha256 over canonical JSON, so dict ordering cannot change the digest."""
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def build_input_refs(metric: str, validated: Any, raw: Mapping[str, Any]) -> tuple[dict[str, Any], ...]:
    """Input references (identifiers and counts, not values)."""
    refs: list[dict[str, Any]] = [{"kind": "input", "metric": metric, "sha256": canonical_sha256(raw)}]
    if metric == "sleep_boundary" and isinstance(validated, Mapping):
        hr = validated.get("hr")
        refs.append({"kind": "hr_samples", "count": len(hr) if isinstance(hr, (list, tuple)) else 0})
    elif metric == "sleep_stage" and isinstance(validated, Mapping):
        rr = validated.get("rr", validated.get("rr_intervals"))
        refs.append({"kind": "rr_intervals", "count": len(rr) if isinstance(rr, (list, tuple)) else 0})
        window = validated.get("window")
        if isinstance(window, Mapping):
            refs.append({"kind": "window", "start_utc": window.get("start_utc"),
                         "end_utc": window.get("end_utc")})
    if isinstance(validated, HrvInput):
        refs.append({"kind": "rr_intervals", "count": len(validated.beats),
                     "sha256": canonical_sha256([{"ts": b.ts, "rr_ms": b.rr_ms,
                                                  "seq": b.seq, "ord": b.ord,
                                                  "src_channel": b.src_channel}
                                                 for b in validated.beats])})
        refs.append({"kind": "windows", "count": len(validated.windows)})
    return tuple(refs)


def parse_request(body: Any) -> InferRequest:
    """Validate a whole ``POST /v1/infer`` body."""
    if not isinstance(body, Mapping):
        raise ContractError("invalid_request", "request body must be a JSON object")
    metric = body.get("metric")
    if not isinstance(metric, str) or not metric:
        raise ContractError("invalid_metric", "metric must be a non-empty string", http_status=404,
                            field="metric")
    if metric not in METRICS:
        raise ContractError("unknown_metric", f"unknown metric {metric!r}", http_status=404,
                            field="metric")
    context = parse_context(body.get("context"))
    raw_input = body.get("input")
    if not isinstance(raw_input, Mapping):
        raise ContractError("invalid_input", "input must be an object", field="input")

    if metric == "hrv":
        validated: Any = parse_hrv_input(raw_input, context)
    elif metric in ("sleep_boundary", "sleep_stage", "sensor_biomarkers"):
        # The sleep candidates and the sensor-biomarkers provider own their payload
        # validation: they check shapes, bounds, finiteness, timestamps and label space
        # inside the provider and answer with status="error" plus a machine-readable
        # diagnostics.reason_detail instead of raising here. Passing the raw mapping
        # through keeps that single source of truth.
        validated = dict(raw_input)
    else:
        raise ContractError("provider_unavailable",
                            f"metric {metric!r} has no wired provider in this build",
                            http_status=503, field="metric")

    provider_block = body.get("provider") or {}
    if not isinstance(provider_block, Mapping):
        raise ContractError("invalid_provider", "provider must be an object", field="provider")
    provider_id = provider_block.get("provider_id")
    if provider_id is not None and (not isinstance(provider_id, str) or not provider_id):
        raise ContractError("invalid_provider", "provider.provider_id must be a non-empty string",
                            field="provider.provider_id")
    expected = provider_block.get("expected_versions")
    if expected is not None:
        if not isinstance(expected, Mapping):
            raise ContractError("invalid_provider", "provider.expected_versions must be an object",
                                field="provider.expected_versions")
        expected = {str(k): str(v) for k, v in expected.items()}

    return InferRequest(
        metric=metric,
        context=context,
        input=validated,
        provider_id=provider_id,
        expected_versions=expected,
        raw_input=dict(raw_input),
        input_sha256=canonical_sha256(raw_input),
        input_refs=build_input_refs(metric, validated, raw_input),
    )


# --------------------------------------------------------------------------
# Independent reference RMSSD (test oracle; no provider code is reused)
# --------------------------------------------------------------------------


def reference_valid_pair_rmssd(
    rr_ms: Sequence[float], adjacency: Sequence[bool]
) -> tuple[float | None, int, int]:
    """Valid-pair RMSSD from first principles.

    ``adjacency[i]`` states that interval ``i`` is genuinely adjacent to
    interval ``i-1`` (so ``adjacency[0]`` is always ignored). Returns
    ``(rmssd, valid_pairs, excluded_pairs)``; ``rmssd`` is ``None`` when no pair
    is adjacent, which is the withholding condition.

    This is the independent check required by spec section 8 ("independent
    reference proves valid-pair RMSSD and withholding"). It is intentionally
    written without numpy and without any provider helper.
    """
    values = [float(v) for v in rr_ms]
    mask = [bool(v) for v in adjacency]
    if len(values) != len(mask):
        raise ValueError("adjacency must have the same length as rr_ms")
    if len(values) < 2:
        return None, 0, 0
    total = 0.0
    pairs = 0
    excluded = 0
    for i in range(1, len(values)):
        if not mask[i]:
            excluded += 1
            continue
        delta = values[i] - values[i - 1]
        total += delta * delta
        pairs += 1
    if pairs < 1:
        return None, 0, excluded
    return math.sqrt(total / pairs), pairs, excluded


def pooled_rmssd(sum_sq: float, pairs: int) -> float | None:
    """RMSSD from pooled squared differences and pair counts.

    Combining runs must pool these two numbers, never average segment RMSSDs
    (spec section 5).
    """
    if pairs < 1:
        return None
    value = math.sqrt(float(sum_sq) / float(pairs))
    return value if math.isfinite(value) else None
