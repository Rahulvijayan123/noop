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
        return result

    def evidence(self) -> dict[str, Any]:
        """Every data tool with its default arguments: what the explanation may draw on. Not logged as calls."""
        if self.anchor is None:
            return {}
        return {name: tool.handler(self, {}) for name, tool in TOOLS.items() if tool.data}

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
    Tool("search_literature", "General scientific findings from a curated, verified corpus. Query with generic "
         "scientific keywords only (e.g. 'resting heart rate training load'); never personal details.",
         {**_object({"query": {"type": "string", "minLength": 3, "maxLength": 200},
                     "limit": {"type": "integer", "minimum": 1, "maximum": 5}}), "required": ["query"]},
         JobTools.search_literature, data=False),
)}


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
