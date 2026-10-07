"""The job loop: claim -> analyse (deterministic gate, then Prime Agent) -> validate -> publish, or fail.

Logs carry no health data and no user text: a short hash of the owner, the metric, outcome codes, counts and
durations only.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import os
import signal
import threading
import time
from datetime import date
from typing import Any
from zoneinfo import ZoneInfo

import psycopg

from . import prompts, sandbox, validate
from .config import Config
from .db import Database, connect
from .literature import Literature
from .metrics import INSIGHT_METRICS, MIN_MEASURED_NIGHTS, SIGNALS
from .prime import AgentFailed, PrimeSession, check_work_root
from .sources import Sources
from .tools import JobTools

log = logging.getLogger("nara_metric_insight")
MAX_RELATED = 4


class AnalysisRejected(RuntimeError):
    def __init__(self, codes: list[str]) -> None:
        super().__init__(",".join(codes))
        self.codes = codes


def owner_ref(user_id: str) -> str:
    return hashlib.sha256(user_id.encode()).hexdigest()[:10]


def short_day(value: str | None) -> str:
    if not value:
        return ""
    day = date.fromisoformat(value)
    return f"{day:%b} {day.day}"


def _with_units(value: Any, units: str) -> str:
    return f"{value}{units}" if units == "%" else f"{value} {units}"


def _signed(value: Any, units: str) -> str:
    return f"{'+' if value > 0 else ''}{_with_units(value, units)}"


def related_items(evidence: dict[str, Any]) -> list[dict[str, Any]]:
    """The related-signals row, built deterministically (never by the model)."""
    items = []
    for signal in (evidence.get("get_related_metrics") or {}).get("signals") or []:
        latest = signal.get("latest")
        if not latest or not signal.get("same_night_as_metric"):
            continue
        units = signal.get("units", "")
        summary = f"{_with_units(latest['value'], units)} on {short_day(latest['day'])}"
        if signal.get("change_vs_median") is not None and signal.get("baseline_nights", 0) >= 3:
            if signal.get("direction") == "flat":
                summary += ", about your median"
            else:
                summary += f", {_signed(signal['change_vs_median'], units)} vs your median"
        items.append({"metric": signal["metric"], "label": signal["label"], "summary": summary,
                      "direction": signal.get("direction", "unknown"), "estimated": bool(signal.get("estimated"))})
        if len(items) >= MAX_RELATED:
            break
    return items


def basis(evidence: dict[str, Any], anchor: date) -> dict[str, Any]:
    quality = evidence.get("get_data_quality") or {}
    summary = evidence.get("get_metric_summary") or {}
    return {"nights": quality.get("measured_nights", 0), "from": quality.get("first_measured"),
            "to": anchor.isoformat(), "missing_nights": quality.get("missing_nights", 0),
            "comparison_status": (summary.get("assessment") or {}).get("basis")}


def insufficient_payload(job: dict[str, Any], tools: JobTools, started: float) -> dict[str, Any]:
    """Too little data for an explanation: a fixed, factual message and no model call."""
    metric = INSIGHT_METRICS[job["metric"]]
    evidence = tools.evidence()
    quality = evidence.get("get_data_quality") or {}
    summary = evidence.get("get_metric_summary") or {}
    nights = int(quality.get("measured_nights") or 0)
    label = metric.signal.label
    observed = []
    latest = summary.get("latest")
    if nights and latest:
        observed.append(f"{nights} night{'s' if nights != 1 else ''} of {label[0].lower() + label[1:]} measured so far, "
                        f"most recently {latest['value']} {metric.signal.units} on {short_day(latest['day'])}.")
    insight = {
        "headline": "Not enough measured nights yet",
        "observed": observed, "interpretation": [],
        "uncertainty": [f"An explanation needs at least {MIN_MEASURED_NIGHTS} measured nights, and what is usual "
                        "for you takes more nights to establish."],
        "related": [],
        "basis": basis(evidence, tools.anchor) if tools.anchor else {"nights": 0},
    }
    return {"kind": "insufficient_data", "analysis_version": job["analysis_version"], "model": None,
            "duration_ms": int((time.monotonic() - started) * 1000), "insight": insight,
            "evidence": {"quality": quality}, "citations": []}


async def analyse(cfg: Config, db: Database, job: dict[str, Any], literature: Literature, *, mode: str,
                  readable: tuple[str, ...]) -> dict[str, Any]:
    started = time.monotonic()
    anchor: date | None = job.get("anchor_day")
    zone = ZoneInfo(job["timezone_id"])
    sources = Sources(db, str(job["user_id"]), job["metric"], anchor, zone)
    tools = JobTools(user_id=str(job["user_id"]), metric=job["metric"], anchor=anchor,
                     timezone_id=job["timezone_id"], sources=sources, literature=literature)
    if anchor is None:
        return insufficient_payload(job, tools, started)
    quality = tools.evidence().get("get_data_quality") or {}
    if int(quality.get("measured_nights") or 0) < MIN_MEASURED_NIGHTS:
        return insufficient_payload(job, tools, started)

    metric = INSIGHT_METRICS[job["metric"]]
    summary = tools.evidence()["get_metric_summary"]
    attempts, rejected = 0, []
    async with PrimeSession(cfg, tools, mode=mode, readable=readable) as session:
        text = await session.ask(prompts.task(metric.signal.label, metric.signal.units,
                                              summary["latest"]["day"], summary["latest"]["value"]))
        attempts = 1
        result = validate.check(text, tools.validation_evidence(), tools.retrieved)
        if not result.ok:
            rejected = result.codes
            text = await session.ask(prompts.retry(result.errors))
            attempts = 2
            result = validate.check(text, tools.validation_evidence(), tools.retrieved)
        stats = session.stats()
    if not result.ok or result.answer is None:
        raise AnalysisRejected(result.codes)
    evidence = tools.evidence()
    answer = result.answer
    citations, papers = [], set()
    for cited in answer["citations"]:  # one entry per paper, even when two of its claims were cited
        record = tools.retrieved[cited]
        # The app hides an explanation with a forbidden word anywhere on the card, titles included: a paper
        # titled with one (possible from the remote fallback) is dropped rather than costing the explanation.
        if record.get("url") in papers or validate.forbidden_term(str(record.get("title") or "")):
            continue
        papers.add(record.get("url"))
        citations.append({k: record.get(k) for k in ("id", "title", "year", "url")})
    insight = {"headline": answer["headline"], "observed": answer["observed"],
               "interpretation": answer["interpretation"], "uncertainty": answer["uncertainty"],
               "related": related_items(evidence), "basis": basis(evidence, anchor)}
    record = {"summary": evidence.get("get_metric_summary"), "quality": evidence.get("get_data_quality"),
              "tool_calls": tools.calls, "sources_loaded": sources.loaded,
              "validator": {"attempts": attempts, "rejected": rejected}, "run": stats}
    return {"kind": "explained", "analysis_version": job["analysis_version"], "model": cfg.llm_model,
            "duration_ms": int((time.monotonic() - started) * 1000), "insight": insight,
            "evidence": record, "citations": citations}


class LeaseKeeper:
    def __init__(self, db: Database, token: str, lease_seconds: int) -> None:
        self.db, self.token, self.lease_seconds = db, token, lease_seconds
        self.lost = False
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="lease-keeper", daemon=True)

    def _run(self) -> None:
        while not self._stop.wait(max(10.0, self.lease_seconds / 3)):
            try:
                if not self.db.renew(self.token, self.lease_seconds):
                    self.lost = True
                    return
            except psycopg.Error:
                log.warning("lease renew failed; retrying")

    def __enter__(self) -> "LeaseKeeper":
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        self._stop.set()
        self._thread.join(timeout=30)


class Worker:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.mode = sandbox.resolve_mode(cfg.sandbox)
        if self.mode == "none" and os.environ.get("NARA_SANDBOX") != "none":
            raise sandbox.SandboxUnavailable("refusing to run unconfined")
        check_work_root(cfg.work_root)
        for path, what in ((cfg.prime_bin, "NARA_PRIME_BIN"), (cfg.kernel_python, "NARA_KERNEL_PYTHON")):
            if not os.access(path, os.X_OK):
                raise RuntimeError(f"{what} is not executable")
        self.readable: tuple[str, ...] = ()
        if self.mode == "linux":
            self.readable = (os.path.dirname(os.path.realpath(cfg.prime_bin)),
                             *sandbox.python_prefixes(cfg.kernel_python))
        self.literature = Literature(cfg.literature_remote, cfg.literature_cache)
        self.db: Database | None = None
        self.stopping = threading.Event()

    def _database(self) -> Database:
        if self.db is None or self.db.conn.closed:
            self.db = Database(connect(self.cfg.db_url))
        return self.db

    def process(self, job: dict[str, Any]) -> str:
        db = self._database()
        token, revision = str(job["lease_token"]), int(job["input_revision"])
        ref = f"{owner_ref(str(job['user_id']))}/{job['metric']}#{revision}"
        started = time.monotonic()
        outcome = "unknown"
        with LeaseKeeper(db, token, self.cfg.lease_seconds) as keeper:
            try:
                payload = asyncio.run(analyse(self.cfg, db, job, self.literature, mode=self.mode,
                                              readable=self.readable))
                if keeper.lost:
                    outcome = "lease_lost"
                else:
                    outcome = str(db.publish(token, revision, payload).get("reason"))
            except AnalysisRejected as exc:
                outcome = "rejected:" + ",".join(exc.codes)
                db.fail(token, revision, "validation:" + ",".join(exc.codes))
            except (asyncio.TimeoutError, TimeoutError):
                outcome = "timeout"
                db.fail(token, revision, "timeout")
            except AgentFailed as exc:
                outcome = "agent_failed"
                db.fail(token, revision, f"agent_failed:{exc}"[:200])
            except psycopg.Error as exc:
                outcome = f"database:{type(exc).__name__}"
                try:
                    db.fail(token, revision, outcome)
                except psycopg.Error:
                    self.db = None
            except Exception as exc:  # noqa: BLE001
                outcome = f"error:{type(exc).__name__}"
                db.fail(token, revision, outcome)
        log.info("job %s outcome=%s ms=%d", ref, outcome, int((time.monotonic() - started) * 1000))
        return outcome

    def once(self) -> str | None:
        job = self._database().claim(self.cfg.worker_id, self.cfg.lease_seconds)
        return self.process(job) if job else None

    def run_forever(self) -> None:
        signal.signal(signal.SIGTERM, lambda *_: self.stopping.set())
        backoff = 1.0
        while not self.stopping.is_set():
            try:
                outcome = self.once()
                backoff = 1.0
            except psycopg.OperationalError:
                log.warning("database unavailable; retrying in %.0fs", backoff)
                self.db = None
                self.stopping.wait(backoff)
                backoff = min(backoff * 2, 60.0)
                continue
            if outcome is None:
                self.stopping.wait(self.cfg.poll_seconds)


__all__ = ["Worker", "analyse", "related_items", "insufficient_payload", "SIGNALS"]
