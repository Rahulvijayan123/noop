"""The tool layer: small, generic, owner-scoped. One registry serves the model (through the broker and the MCP
shim) and the validator (which calls the same handlers to know what the model could have seen).

No tool takes a user, a device or a date range beyond its window: the job fixes the owner, the metric and the
anchor day. Adding a data source (labs, medications, EHR, genomics, conversation memory) is one more entry
here plus its loader in sources.py — the agent, the prompt contract and the validator do not change.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from typing import Any, Callable
from zoneinfo import ZoneInfo

from . import evidence as ev
from .literature import Literature
from .metrics import INSIGHT_METRICS, SIGNALS, WINDOW_DAYS
from .sources import Sources


MAX_SEARCHES = 3


class ToolError(ValueError):
    """A bad call (unknown tool, bad arguments). The message goes back to the model; never contains data."""


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    schema: dict[str, Any]
    handler: Callable[["JobTools", dict[str, Any]], dict[str, Any]]
    data: bool = True  # part of the evidence the validator grounds numbers in


def _object(properties: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"type": "object", "properties": properties or {}, "additionalProperties": False}


class JobTools:
    """The tools of one job: bound to one owner, one metric, one anchor day."""

    def __init__(self, *, user_id: str, metric: str, anchor: date | None, timezone_id: str, sources: Sources,
                 literature: Literature) -> None:
        self.user_id = user_id
        self.metric = INSIGHT_METRICS[metric]
        self.anchor = anchor
        self.zone = ZoneInfo(timezone_id)
        self.sources = sources
        self.literature = literature
        self.calls: list[str] = []
        self.received: list[tuple[str, dict[str, Any]]] = []  # every result the model got, as it got it
        self.retrieved: dict[str, dict[str, Any]] = {}
        self.searches = 0

    def call(self, name: str, args: dict[str, Any] | None) -> dict[str, Any]:
        tool = TOOLS.get(name)
        if tool is None:
            raise ToolError(f"unknown tool {name!r}; available: {', '.join(TOOLS)}")
        args = dict(args or {})
        _check_args(tool.schema, args)
        if self.anchor is None and tool.data:
            return {"available": False, "reason": "no_measured_data"}
        result = tool.handler(self, args)
        self.calls.append(name)
        self.received.append((name, result))
        return result

    def evidence(self) -> dict[str, Any]:
        """Every data tool with its default arguments (the payload's related signals and basis). Not logged."""
        if self.anchor is None:
            return {}
        return {name: tool.handler(self, {}) for name, tool in TOOLS.items() if tool.data}

    def validation_evidence(self) -> dict[str, list[dict[str, Any]]]:
        """What the answer may draw on: the default results plus every result the model actually received (it may
        have asked for other windows or signals)."""
        out: dict[str, list[dict[str, Any]]] = {name: [result] for name, result in self.evidence().items()}
        for name, result in self.received:
            if TOOLS[name].data:
                out.setdefault(name, []).append(result)
        return out

    # handlers --------------------------------------------------------------------------------------------

    def _context(self) -> dict[str, Any] | None:
        return self.sources.context()[0]

    def metric_series(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.metric_series(self.sources.scores(), self.metric, self.anchor, int(args.get("days", WINDOW_DAYS)))

    def metric_summary(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.metric_summary(self.sources.scores(), self.metric, self.anchor, WINDOW_DAYS, self._context())

    def related_metrics(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.related_metrics(self.sources.scores(), self.metric, self.anchor, WINDOW_DAYS, self._context(),
                                  args.get("metrics"))

    def sleep_context(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.sleep_context(self.sources.scores(), self.anchor, self.zone, int(args.get("nights", 7)),
                                self._context())

    def state_breakdown(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.state_breakdown(self.sources.scores(), self.metric, self.anchor, self._context(),
                                  self.sources.snapshots(), self.zone)

    def movement_patterns(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.movement_patterns(self.sources.previous_context()[0], self._context(), self.sources.scores(),
                                    self.anchor, self.zone, self.sources.activity_runs())

    def workout_context(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.workout_context(self._context())

    def activity_context(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.activity_context(self._context())

    def recent_events(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.recent_events(self.sources.exposures(), self._context(), self.zone)

    def data_quality(self, args: dict[str, Any]) -> dict[str, Any]:
        document, mode = self.sources.context()
        return ev.data_quality(self.sources.scores(), self.metric, self.anchor, WINDOW_DAYS, document, mode)

    def user_context(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.user_context(self.sources.memory())

    def previous_insight(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.previous_insight(self.sources.previous_insight())

    def chat_history(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.chat_history(self.sources.chat_history())

    def health_records(self, args: dict[str, Any]) -> dict[str, Any]:
        return ev.health_records(self.sources.health_records())

    def context_manifest(self, args: dict[str, Any]) -> dict[str, Any]:
        """Every source this analysis can use, whether it is connected, and the variable it loads into."""
        connected = {"get_chat_history": self.sources.chat_history() is not None,
                     "get_health_records": self.sources.health_records() is not None}
        return {"metric": self.metric.key, "analysis_night": self.anchor.isoformat() if self.anchor else None,
                "sources": [{"variable": v.name, "tool": v.tool, "kind": v.kind, "about": TOOLS[v.tool].description,
                             "connected": connected.get(v.tool, True)} for v in VARIABLES],
                "note": "load every variable before answering; a source that is not connected stays empty"}

    def missing_required(self) -> list[str]:
        """Variables the root agent has not loaded yet (the answer is refused until it has)."""
        return sorted(REQUIRED - set(self.calls))

    def search_literature(self, args: dict[str, Any]) -> dict[str, Any]:
        self.searches += 1
        if self.searches > MAX_SEARCHES:
            raise ToolError(f"at most {MAX_SEARCHES} literature searches per analysis; use the results you have")
        try:
            records = self.literature.search(str(args["query"]), self.metric.key, int(args.get("limit", 3)))
        except ValueError as exc:  # a query that looks personal is refused, never sent anywhere
            raise ToolError(str(exc)) from None
        for record in records:
            self.retrieved[record["id"]] = record
        return {"results": records, "note": "general findings, not about this person; cite by id"}


TOOLS: dict[str, Tool] = {tool.name: tool for tool in (
    Tool("get_metric_series", "This metric's nightly values (oldest first), null where a night was not measured.",
         _object({"days": {"type": "integer", "minimum": 7, "maximum": WINDOW_DAYS}}), JobTools.metric_series),
    Tool("get_metric_summary", "Latest value, previous night, personal baseline and usual range, last 7 nights, "
         "the context layer's comparison and change episode, and whether the latest night is unusual for this person.",
         _object(), JobTools.metric_summary),
    Tool("get_state_breakdown", "This metric in each measured state (during sleep, at calm awake rest, around "
         "movement) and by time of day, each against its own usual value and usual band (the threshold).",
         _object(), JobTools.state_breakdown),
    Tool("get_movement_patterns", "Movement bouts the evening before the night and on the day (local times, "
         "minutes), recent training load, and how long before sleep the last movement ended (estimated).",
         _object(), JobTools.movement_patterns),
    Tool("get_related_metrics", "Other nightly signals vs their own medians (HRV, resting HR, respiratory rate, "
         "skin temperature, sleep), each marked measured or estimated.",
         _object({"metrics": {"type": "array", "maxItems": 8, "items": {"type": "string", "enum": sorted(SIGNALS)}}}),
         JobTools.related_metrics),
    Tool("get_sleep_context", "Recent nights' estimated sleep duration, efficiency and local sleep/wake times, and "
         "the shift in sleep timing vs earlier nights.",
         _object({"nights": {"type": "integer", "minimum": 1, "maximum": 14}}), JobTools.sleep_context),
    Tool("get_workout_context", "Exertion over the 24/48/72 h before the analysis day and that day's movement bouts.",
         _object(), JobTools.workout_context),
    Tool("get_activity_context", "The analysis day's wear time and general activity level from wrist motion.",
         _object(), JobTools.activity_context),
    Tool("get_recent_events", "Exposures the person recorded in the 14 days up to the analysis day (caffeine, "
         "alcohol, ...) and the categories they did not record.", _object(), JobTools.recent_events),
    Tool("get_data_quality", "Measured and missing nights, gaps, and the context layer's status for this metric.",
         _object(), JobTools.data_quality),
    Tool("get_user_context", "Notes this person gave the coach (their own words, this person only).",
         _object(), JobTools.user_context),
    Tool("get_previous_insight", "The headline of the previous explanation of this metric, if any.",
         _object(), JobTools.previous_insight),
    Tool("get_chat_history", "This person's recent coach conversations (placeholder: not connected yet).",
         _object(), JobTools.chat_history),
    Tool("get_health_records", "This person's linked health records: conditions, medications, labs (placeholder: "
         "not connected yet).", _object(), JobTools.health_records),
    Tool("get_context_manifest", "Every source this analysis can use and whether it is connected.",
         _object(), JobTools.context_manifest, data=False),
    Tool("search_literature", "Peer-reviewed findings: a curated, verified corpus first, then PubMed / Europe PMC "
         "journal articles. Query with generic scientific keywords only (e.g. 'heart rate variability sleep "
         "evening exercise'); never personal details.",
         {**_object({"query": {"type": "string", "minLength": 3, "maxLength": 200},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 5}}), "required": ["query"]},
         JobTools.search_literature, data=False),
)}


@dataclass(frozen=True)
class Variable:
    name: str   # the Python variable the root agent loads it into
    tool: str
    kind: str   # physiological | movement | events | personal | conversation | health_records | history | quality


# The root agent's data, in the order its first cell loads it (prompts.bootstrap). Every one is loaded for every
# analysis, connected or not, so nothing is skipped silently; REQUIRED is what the validator insists on.
VARIABLES: tuple[Variable, ...] = (
    Variable("manifest", "get_context_manifest", "meta"),
    Variable("metric_summary", "get_metric_summary", "physiological"),
    Variable("metric_series", "get_metric_series", "physiological"),
    Variable("state_breakdown", "get_state_breakdown", "physiological"),
    Variable("movement_patterns", "get_movement_patterns", "movement"),
    Variable("related_metrics", "get_related_metrics", "physiological"),
    Variable("sleep_context", "get_sleep_context", "physiological"),
    Variable("workout_context", "get_workout_context", "movement"),
    Variable("activity_context", "get_activity_context", "movement"),
    Variable("recent_events", "get_recent_events", "events"),
    Variable("data_quality", "get_data_quality", "quality"),
    Variable("user_context", "get_user_context", "personal"),
    Variable("chat_history", "get_chat_history", "conversation"),
    Variable("health_records", "get_health_records", "health_records"),
    Variable("previous_insight", "get_previous_insight", "history"),
)
REQUIRED = frozenset({v.tool for v in VARIABLES} | {"search_literature"})


def _check_args(schema: dict[str, Any], args: dict[str, Any]) -> None:
    properties = schema.get("properties", {})
    for key in args:
        if key not in properties:
            raise ToolError(f"unexpected argument {key!r} (the user, device and dates are fixed by the host)")
    for key in schema.get("required", []):
        if key not in args:
            raise ToolError(f"missing argument {key!r}")
    for key, value in args.items():
        spec = properties[key]
        kind = spec.get("type")
        if kind == "integer":
            if isinstance(value, bool) or not isinstance(value, int):
                raise ToolError(f"{key} must be an integer")
            if not spec.get("minimum", value) <= value <= spec.get("maximum", value):
                raise ToolError(f"{key} must be between {spec.get('minimum')} and {spec.get('maximum')}")
        elif kind == "string":
            if not isinstance(value, str) or not spec.get("minLength", 0) <= len(value) <= spec.get("maxLength", 10**6):
                raise ToolError(f"{key} must be a string of {spec.get('minLength', 0)}-{spec.get('maxLength')} characters")
        elif kind == "array":
            if not isinstance(value, list) or len(value) > spec.get("maxItems", 10**6):
                raise ToolError(f"{key} must be a list of at most {spec.get('maxItems')} items")
            allowed = spec.get("items", {}).get("enum")
            if allowed and any(item not in allowed for item in value):
                raise ToolError(f"{key} items must be among: {', '.join(allowed)}")


def tool_list() -> list[dict[str, Any]]:
    return [{"name": t.name, "description": t.description, "inputSchema": t.schema} for t in TOOLS.values()]
