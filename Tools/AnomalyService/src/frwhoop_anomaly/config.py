"""Environment configuration (names only in deploy/anomaly.env.example; values live in /etc/frwhoop/anomaly.env)."""

from __future__ import annotations

import dataclasses
import os


def _env(name: str, default: str | None = None) -> str | None:
  v = os.environ.get(name)
  return v if v not in (None, "") else default


@dataclasses.dataclass(frozen=True)
class Config:
  db_url: str
  db_sslrootcert: str | None
  db_sslmode: str
  service_name: str
  source_revision: str
  state_dir: str
  timesfm_src: str | None
  timesfm_weights: str
  units_src: str
  units_ckpt: str
  threads: int
  poll_seconds: int
  enqueue_limit: int
  min_interval_minutes: int
  lease_seconds: int
  context_minutes: int
  horizon_minutes: int
  score_lookback_hours: int
  max_jobs_per_cycle: int
  dry_run: bool
  users: tuple[str, ...] = ()            # staged rollout: only these owners (empty = every scored owner)

  @staticmethod
  def from_env() -> "Config":
    db_url = _env("FRWHOOP_ANOMALY_DB_URL") or _env("FRWHOOP_DB_URL")
    if not db_url:
      raise SystemExit("FRWHOOP_ANOMALY_DB_URL is required")
    return Config(
      db_url=db_url,
      db_sslrootcert=_env("FRWHOOP_DB_SSLROOTCERT"),
      db_sslmode=_env("FRWHOOP_DB_SSLMODE", "verify-full"),
      service_name=_env("FRWHOOP_ANOMALY_NAME", "frwhoop-anomaly"),
      source_revision=_env("FRWHOOP_ANOMALY_REVISION", "unknown"),
      state_dir=_env("FRWHOOP_ANOMALY_STATE", "/var/lib/frwhoop-anomaly"),
      timesfm_src=_env("TIMESFM_SRC"),
      timesfm_weights=_env("TIMESFM_WEIGHTS", "/opt/frwhoop-models/anomaly/timesfm-3.0-pytorch"),
      units_src=_env("UNITS_SRC", "/opt/frwhoop-models/anomaly/units-src"),
      units_ckpt=_env("UNITS_CKPT", "/opt/frwhoop-models/anomaly/units-ckpt/units_x128_pretrain_checkpoint.pth"),
      threads=int(_env("FRWHOOP_ANOMALY_THREADS", "2")),
      poll_seconds=int(_env("FRWHOOP_ANOMALY_POLL_SECONDS", "60")),
      enqueue_limit=int(_env("FRWHOOP_ANOMALY_ENQUEUE_LIMIT", "50")),
      min_interval_minutes=int(_env("FRWHOOP_ANOMALY_MIN_INTERVAL_MINUTES", "10")),
      lease_seconds=int(_env("FRWHOOP_ANOMALY_LEASE_SECONDS", "900")),
      context_minutes=int(_env("FRWHOOP_ANOMALY_CONTEXT_MINUTES", "1024")),
      horizon_minutes=int(_env("FRWHOOP_ANOMALY_HORIZON_MINUTES", "30")),
      score_lookback_hours=int(_env("FRWHOOP_ANOMALY_LOOKBACK_HOURS", "6")),
      max_jobs_per_cycle=int(_env("FRWHOOP_ANOMALY_MAX_JOBS_PER_CYCLE", "4")),
      dry_run=_env("FRWHOOP_ANOMALY_DRY_RUN", "0") == "1",
      users=tuple(u.strip() for u in (_env("FRWHOOP_ANOMALY_USERS", "") or "").split(",") if u.strip()),
    )
