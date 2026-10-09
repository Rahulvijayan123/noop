"""One causal alert policy used unchanged in evaluation and serving."""
from dataclasses import asdict, dataclass, field
import math
import uuid


@dataclass(frozen=True)
class Policy:
    enter: float = .7
    exit: float = .4
    persistence: int = 3
    smoothing: int = 3
    cadence: int = 8
    gap: int = 16
    cooldown: int = 120
    manual_seconds: float = 20
    confirm_seconds: float = 2
    dismiss_seconds: float = 10
    min_recall: float = .7
    max_false_per_day: float = 5
    max_delay: float = 120
    min_events: int = 3
    min_negative_hours: float = 1

    def __post_init__(self):
        if not 0 <= self.exit < self.enter <= 1 or min(self.persistence, self.smoothing, self.cadence) < 1:
            raise ValueError("invalid alert policy")


@dataclass
class EpisodeState:
    cursor: float = 0
    scores: list = field(default_factory=list)
    above: int = 0
    first: float | None = None
    active: dict | None = None
    last_end: float = 0

    def step(self, t, score, *, owner, type_id, device, model, policy):
        if t <= self.cursor:
            return None
        if t - self.cursor > policy.gap or not math.isfinite(score):
            self.scores = []; self.above = 0; self.first = None
            if self.active:
                self.last_end = self.active["end"]
            self.active = None
        self.cursor = t
        if not math.isfinite(score):
            return None
        self.scores = (self.scores + [float(score)])[-policy.smoothing:]
        value = sum(self.scores) / len(self.scores)
        if self.active:
            if value < policy.exit:
                self.last_end = t; self.active = None; self.above = 0; self.first = None
                return None
            self.active["end"] = t
            return dict(self.active)
        if value >= policy.enter and t - self.last_end >= policy.cooldown:
            self.above += 1
            if self.first is None: self.first = t
        else:
            self.above = 0; self.first = None
        if self.above >= policy.persistence:
            # Model is deliberately excluded: a swap cannot duplicate an in-flight episode.
            key = f"{owner}:{type_id}:{device}:{self.first:.3f}"
            self.active = dict(id=str(uuid.uuid5(uuid.NAMESPACE_URL, key)), start=self.first,
                               end=t, detected_at=t, model=str(model))
            return dict(self.active)
        return None


def evaluate(times, scores, positives, negatives, policy, *, owner="eval", type_id="eval", device="eval"):
    """Only reviewed exposure counts. Unknown intervals never supply false-negative evidence."""
    state = EpisodeState(); alerts = {}
    for t, score in zip(times, scores):
        alert = state.step(float(t), float(score), owner=owner, type_id=type_id, device=device, model="eval", policy=policy)
        if alert: alerts[alert["id"]] = alert
    covered = set(); false = 0; delays = []
    for alert in alerts.values():
        matches = [e for e in positives if e["start"] <= alert["detected_at"] <= e["end"]]
        fresh = next((e for e in matches if e["id"] not in covered), None)
        if fresh:
            covered.add(fresh["id"]); delays.append(max(0, alert["detected_at"] - fresh["start"]))
        elif matches or any(a <= alert["detected_at"] <= b for a, b in negatives):
            false += 1
    # Union of covered support; overlapping anchors do not inflate observed hours.
    supports = []
    for t, score in zip(times, scores):
        if math.isfinite(float(score)):
            supports.append((float(t)-policy.cadence, float(t)))
    def exposure(intervals):
        parts = sorted((max(a,c), min(b,d)) for a,b in supports for c,d in intervals if min(b,d)>max(a,c))
        total = 0; end = -math.inf
        for a,b in parts: total += max(0,b-max(a,end)); end = max(end,b)
        return total
    negative_seconds = exposure(negatives)
    seconds = exposure(negatives + [(e["start"],e["end"]) for e in positives])
    days = seconds/86400
    recall = len(covered)/len(positives) if positives else 0
    false_day = false/days if days else 0
    saved = ((policy.manual_seconds-policy.confirm_seconds)*len(covered)-policy.dismiss_seconds*false)/days if days else 0
    delay = sum(delays)/len(delays) if delays else None
    eligible = (len(positives)>=policy.min_events and negative_seconds>=policy.min_negative_hours*3600
                and recall>=policy.min_recall and false_day<=policy.max_false_per_day
                and delay is not None and max(delays)<=policy.max_delay and saved>0)
    return dict(eligible=eligible, timeSavedSecondsPerDay=saved, falseAlertsPerDay=false_day,
                recall=recall, delaySeconds=delay, events=len(positives), coveredEvents=len(covered),
                reviewedHours=seconds/3600, negativeHours=negative_seconds/3600, policy=asdict(policy))
