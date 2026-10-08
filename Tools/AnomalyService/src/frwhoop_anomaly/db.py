"""Postgres access. Reads run in short read-only transactions with their own statement/lock timeouts and only by
primary-key range (user_id, device_id, ts). The service never takes the scoring-inputs advisory lock, never writes
noop_* tables and never calls scoring enqueue functions (docs/BASELINE_WATCHDOG_V2.md §5 hazards)."""

from __future__ import annotations

import contextlib
from typing import Any, Iterator

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb


class Database:
  def __init__(self, url: str, sslmode: str = "verify-full", sslrootcert: str | None = None):
    kw: dict[str, Any] = {"autocommit": True, "row_factory": dict_row, "application_name": "frwhoop-anomaly"}
    if sslrootcert:
      kw["sslrootcert"] = sslrootcert
    if sslmode:
      kw["sslmode"] = sslmode
    self._url = url
    self._kw = kw
    self._conn: psycopg.Connection | None = None

  def conn(self) -> psycopg.Connection:
    if self._conn is None or self._conn.closed or self._conn.broken:
      self._conn = psycopg.connect(self._url, **self._kw)
    return self._conn

  def close(self) -> None:
    if self._conn is not None:
      self._conn.close()

  @contextlib.contextmanager
  def read(self, statement_timeout_ms: int = 20000) -> Iterator[psycopg.Cursor]:
    c = self.conn()
    with c.transaction():
      with c.cursor() as cur:
        cur.execute("set transaction read only")
        cur.execute(f"set local statement_timeout = {int(statement_timeout_ms)}")
        cur.execute("set local lock_timeout = 3000")
        cur.execute("set local idle_in_transaction_session_timeout = 60000")
        yield cur

  def rpc(self, fn: str, *args: Any, timeout_ms: int = 30000) -> list[dict]:
    c = self.conn()
    placeholders = ", ".join(["%s"] * len(args))
    adapted = [Jsonb(a) if isinstance(a, dict) else a for a in args]     # payloads are objects; lists are arrays
    with c.transaction():
      with c.cursor() as cur:
        cur.execute(f"set local statement_timeout = {int(timeout_ms)}")
        cur.execute("set local lock_timeout = 5000")
        cur.execute(f"select * from public.{fn}({placeholders})", adapted)
        try:
          return list(cur.fetchall())
        except psycopg.ProgrammingError:
          return []
