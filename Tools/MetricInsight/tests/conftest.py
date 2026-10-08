"""Fixtures. The PostgreSQL fixture builds a throwaway cluster from the repository's full migration chain (the
same order and stubs as supabase/functions/tests/local_postgres.ts with fullChain), never a shared database."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
MIGRATIONS = REPO / "supabase" / "migrations"
PG_BIN = Path(os.environ.get("NARA_TEST_PG_BIN", "/opt/homebrew/bin"))
SKIPPED = {"20260911140000_scheduled_workers_pg_cron.sql", "20260930235500_expand_scoring_invalidations_cron.sql",
           "20260921060000_production_intake_durability.sql"}
USER_A = "11111111-1111-4111-8111-111111111111"
USER_B = "22222222-2222-4222-8222-222222222222"
DEVICE_A = "33333333-3333-4333-8333-333333333333"
DEVICE_B = "44444444-4444-4444-8444-444444444444"

BOOTSTRAP = """
create role postgres nologin; create role anon nologin; create role authenticated nologin;
create role service_role nologin bypassrls; create role authenticator login noinherit;
grant anon, authenticated, service_role to authenticator;
create schema auth; create schema extensions; create schema realtime;
create publication supabase_realtime;
create table auth.users (id uuid primary key, raw_user_meta_data jsonb default '{}'::jsonb, email text);
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid $$;
create function auth.role() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', current_user::text) $$;
grant usage on schema public, auth, extensions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
"""


def migration_order() -> list[Path]:
    out: list[Path] = []
    for path in sorted(MIGRATIONS.glob("*.sql")):
        if path.name in SKIPPED:
            continue
        out.append(path)
        if path.name == "20260918010000_production_scoring_durability.sql":
            out.append(MIGRATIONS / "20260921060000_production_intake_durability.sql")
    return out


class LocalPostgres:
    def __init__(self, base: Path) -> None:
        self.base = base
        self.data = base / "data"
        self.env = {"PATH": f"{PG_BIN}:/usr/bin:/bin", "LC_ALL": "C", "TMPDIR": str(base)}

    def run(self, *args: str, stdin: str | None = None) -> str:
        done = subprocess.run(list(args), input=stdin, capture_output=True, text=True, env=self.env)
        if done.returncode != 0:
            raise RuntimeError(f"{Path(args[0]).name} failed: {done.stderr[-2000:]}")
        return done.stdout

    def psql(self, sql: str | None = None, file: Path | None = None) -> str:
        args = [str(PG_BIN / "psql"), "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-h", str(self.base), "-U", "edge_test",
                "-d", "postgres"]
        args += ["-f", str(file)] if file else ["-c", sql or ""]
        return self.run(*args).strip()

    @property
    def url(self) -> str:
        return f"host={self.base} user=edge_test dbname=postgres"

    def start(self) -> "LocalPostgres":
        self.run(str(PG_BIN / "initdb"), "-D", str(self.data), "-U", "edge_test", "--auth-local=trust",
                 "--auth-host=reject", "--no-locale", "--encoding=UTF8")
        self.run(str(PG_BIN / "pg_ctl"), "-D", str(self.data), "-l", str(self.base / "postgres.log"), "-o",
                 f"-k '{self.base}' -c listen_addresses='' -c max_connections=40", "-w", "start")
        self.psql(BOOTSTRAP)
        for path in migration_order():
            self.psql(file=path)
        self.psql(f"insert into auth.users(id) values ('{USER_A}'), ('{USER_B}');")
        return self

    def stop(self) -> None:
        subprocess.run([str(PG_BIN / "pg_ctl"), "-D", str(self.data), "-m", "fast", "-w", "stop"],
                       capture_output=True, env=self.env)


@pytest.fixture(scope="session")
def pg():
    if not (PG_BIN / "initdb").exists():
        pytest.skip("initdb not available (set NARA_TEST_PG_BIN)")
    base = Path(tempfile.mkdtemp(prefix="mi-pg-", dir="/tmp"))
    server = LocalPostgres(base)
    try:
        server.start()
        yield server
    finally:
        server.stop()
        shutil.rmtree(base, ignore_errors=True)


@pytest.fixture()
def secret_file(tmp_path):
    def write(name: str, value: str) -> str:
        path = tmp_path / name
        path.write_text(value)
        path.chmod(0o600)
        return str(path)
    return write
