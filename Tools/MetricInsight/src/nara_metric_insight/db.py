"""Database access. Two shapes only:

* queue calls (claim/renew/fail/publish) run as `service_role`, like the scores edge function's PostgREST calls;
* owner reads run in a READ ONLY transaction as `authenticated` with the owner's JWT claims, so row-level security
  — not this code — decides which rows exist. Every read asserts `auth.uid()` is the job's owner first.

The one service-only table an owner read needs (coach_memory_items, RLS with no client policy) is read as
`service_role` with an explicit owner filter, in its own read-only transaction.
"""

from __future__ import annotations

import json
import threading
from collections.abc import Callable
from contextlib import contextmanager
from typing import Any, TypeVar

import psycopg
from psycopg.rows import dict_row

T = TypeVar("T")


class IsolationError(RuntimeError):
    """The database did not confirm the owner a read is scoped to."""


def connect(db_url: str) -> psycopg.Connection:
    # prepare_threshold=None: the Supabase pooler (and PgBouncer generally) cannot keep server-side statements.
    return psycopg.connect(db_url, autocommit=False, row_factory=dict_row, prepare_threshold=None,
                           application_name="nara-metric-insight")


class Database:
    """One connection, serialized: the worker thread and the tool broker's threads share it."""

    def __init__(self, conn: psycopg.Connection) -> None:
        self.conn = conn
        self.lock = threading.Lock()

    @contextmanager
    def _transaction(self, *, read_only: bool, role: str, timeout_ms: int):
        with self.lock:
            try:
                with self.conn.transaction():
                    with self.conn.cursor() as cur:
                        if read_only:
                            cur.execute("set transaction read only")
                        cur.execute(f"set local statement_timeout = {int(timeout_ms)}")
                        cur.execute("set local role " + {"service_role": "service_role",
                                                          "authenticated": "authenticated"}[role])
                        yield cur
            except psycopg.OperationalError:
                # A broken connection is not reusable; the caller's job fails and the next one reconnects.
                raise

    def service(self, fn: Callable[[psycopg.Cursor], T], *, read_only: bool = False, timeout_ms: int = 15000) -> T:
        with self._transaction(read_only=read_only, role="service_role", timeout_ms=timeout_ms) as cur:
            return fn(cur)

    def as_owner(self, user_id: str, fn: Callable[[psycopg.Cursor], T], *, timeout_ms: int = 5000) -> T:
        with self._transaction(read_only=True, role="authenticated", timeout_ms=timeout_ms) as cur:
            claims = json.dumps({"sub": user_id, "role": "authenticated"})
            cur.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
            cur.execute("select auth.uid()::text as uid")
            row = cur.fetchone()
            if not row or row["uid"] != user_id:
                raise IsolationError("owner scope not confirmed by the database")
            return fn(cur)

    # ------------------------------------------------------------------ queue (20261008000000_metric_insights.sql)

    def claim(self, worker: str, lease_seconds: int) -> dict[str, Any] | None:
        def go(cur: psycopg.Cursor) -> dict[str, Any] | None:
            cur.execute("select * from public.metric_insight_claim_v1(%s, %s)", (worker, lease_seconds))
            return cur.fetchone()
        return self.service(go)

    def sweep(self, limit: int) -> int:
        """Queue the background explanations that are missing (20261008010000_metric_insight_background_sweep.sql)."""
        def go(cur: psycopg.Cursor) -> int:
            cur.execute("select public.metric_insight_sweep_v1(%s) as n", (limit,))
            return int(cur.fetchone()["n"])
        return self.service(go, timeout_ms=60000)

    def renew(self, token: str, lease_seconds: int) -> bool:
        def go(cur: psycopg.Cursor) -> bool:
            cur.execute("select public.metric_insight_renew_v1(%s, %s) as ok", (token, lease_seconds))
            return bool(cur.fetchone()["ok"])
        return self.service(go)

    def fail(self, token: str, revision: int, error: str) -> dict[str, Any]:
        def go(cur: psycopg.Cursor) -> dict[str, Any]:
            cur.execute("select public.metric_insight_fail_v1(%s, %s, %s) as r", (token, revision, error[:500]))
            return cur.fetchone()["r"]
        return self.service(go)

    def publish(self, token: str, revision: int, payload: dict[str, Any]) -> dict[str, Any]:
        def go(cur: psycopg.Cursor) -> dict[str, Any]:
            cur.execute("select public.metric_insight_publish_v1(%s, %s, %s::jsonb) as r",
                        (token, revision, json.dumps(payload)))
            return cur.fetchone()["r"]
        return self.service(go)
