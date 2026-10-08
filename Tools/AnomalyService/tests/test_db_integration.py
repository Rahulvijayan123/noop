"""Service ↔ Postgres round trip (enqueue with allowlist → claim → process → fenced publish → heartbeat).

Opt-in: ANOMALY_TEST_DB=postgresql://... pointing at a scratch database with tests/sql/prod_stubs.sql and the
migration applied (scoring_jobs_v2 row for user 1111…). Skipped otherwise. Model scoring is a stub; features.load is
replaced by a synthetic frame (the noop_* stubs carry no samples)."""
import os
import uuid

import numpy as np
import pytest

from frwhoop_anomaly import service as svcmod
from frwhoop_anomaly.config import Config
from frwhoop_anomaly.service import Service

from test_service import StubScorer, make_frame

DB = os.environ.get("ANOMALY_TEST_DB")
pytestmark = pytest.mark.skipif(not DB, reason="ANOMALY_TEST_DB not set")
OWNER = "11111111-1111-1111-1111-111111111111"


def test_round_trip(tmp_path, monkeypatch):
  cfg = Config(db_url=DB, db_sslrootcert=None, db_sslmode="disable", service_name="pytest-it", source_revision="it",
               state_dir=str(tmp_path), timesfm_src=None, timesfm_weights="", units_src="", units_ckpt="", threads=1,
               poll_seconds=60, enqueue_limit=10, min_interval_minutes=10, lease_seconds=600, context_minutes=60,
               horizon_minutes=30, score_lookback_hours=6, max_jobs_per_cycle=2, dry_run=False, users=(OWNER,))
  svc = Service(cfg, scorers=[StubScorer()])
  db = svc.db
  with db.conn().transaction():
    db.conn().execute("truncate public.anomaly_jobs, public.anomaly_candidates, public.anomaly_window_scores")
    db.conn().execute("update public.scoring_jobs_v2 set last_completed_at = now()")
  rs = np.random.default_rng(0)
  monkeypatch.setattr(svcmod.features, "load",
                      lambda db, u, d, lo, hi: make_frame(int((hi - lo) // 60), 60 + rs.normal(size=int((hi - lo) // 60))))
  other = db.rpc("enqueue_anomaly_jobs_v1", 10, "10 minutes", [uuid.UUID("22222222-2222-2222-2222-222222222222")])
  assert other[0]["enqueue_anomaly_jobs_v1"] == 0
  n = db.rpc("enqueue_anomaly_jobs_v1", 10, "10 minutes", [uuid.UUID(OWNER)])
  assert n[0]["enqueue_anomaly_jobs_v1"] == 1
  assert svc.run_one() is True
  assert svc.counters["published"] == 1 and svc.counters["failed"] == 0, svc.last_error
  job = db.rpc("claim_anomaly_job_v1", 60)
  assert not job or job[0].get("lease_token") is None          # completed: nothing due
  svc.hb_db.rpc("anomaly_service_heartbeat_v1", cfg.service_name, {"counters": svc.counters})
