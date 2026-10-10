"""Caregiver evidence for one (owner, event type): the engine's only label input."""
from __future__ import annotations

import dataclasses

DEFAULT_UNCERTAINTY_MIN = 5.0
UNCERTAINTY_CHOICES = (0.0, 5.0, 15.0, 60.0)


@dataclasses.dataclass
class Event:
  id: str
  start: float
  end: float
  uncertainty_min: float = DEFAULT_UNCERTAINTY_MIN
  available_at: float | None = None      # when the label reached the server (None = at its end)
  type_id: str = ""

  @property
  def available(self) -> float:
    return float(self.end if self.available_at is None else self.available_at)


def available(span) -> float:
  """When a (start, end[, available_at]) span reached the server; spans without it count from their end."""
  return float(span[2]) if len(span) > 2 and span[2] is not None else float(span[1])


def known_before(spans, before):
  return list(spans) if before is None else [s for s in spans if available(s) <= before]


@dataclasses.dataclass
class Evidence:
  """Spans are (start, end, available_at) tuples (a 2-tuple counts as available at its end). Anything used for a
  cutoff is filtered by available_at <= cutoff, so a forward evaluation never sees a label recorded later."""
  type_id: str
  events: list                                   # Event of this type, completed (have an end)
  other_events: list = dataclasses.field(default_factory=list)          # Event of other types
  observations: list = dataclasses.field(default_factory=list)          # everything was logged in these
  negatives: list = dataclasses.field(default_factory=list)             # reviewed negative intervals
  rejected: list = dataclasses.field(default_factory=list)              # rejected detections
  positive_reviews: list = dataclasses.field(default_factory=list)      # confirmed detections
  unreviewed: list = dataclasses.field(default_factory=list)            # pending detections
  confirmed_detections: int = 0
  rejected_detections: int = 0
  owner: str = "local"

  def exclusions(self, before=None):
    """Intervals that must stay >= 2 h away from baselines and matched controls (only what was known before
    the cutoff)."""
    spans = [(e.start, e.end) for e in self.events + self.other_events if before is None or e.available <= before]
    spans += [(s[0], s[1]) for s in known_before(list(self.positive_reviews) + list(self.unreviewed), before)]
    return spans

  def negative_spans(self, before=None):
    """Preferred negative time: observation periods, reviewed negative intervals, rejected detections."""
    return [(s[0], s[1]) for s in known_before(list(self.observations) + list(self.negatives) + list(self.rejected),
                                               before)]


def parse_events(items, default_type=""):
  out = []
  for it in items:
    unc = it.get("onset_uncertainty_min", it.get("onsetUncertaintyMinutes", DEFAULT_UNCERTAINTY_MIN))
    out.append(Event(id=str(it["id"]), start=float(it["start"]), end=float(it["end"]),
                     uncertainty_min=float(DEFAULT_UNCERTAINTY_MIN if unc is None else unc),
                     available_at=None if it.get("available_at") is None else float(it["available_at"]),
                     type_id=str(it.get("type_id", default_type))))
  return out
