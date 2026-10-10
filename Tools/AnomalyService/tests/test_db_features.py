"""features.load and the per-user readers against the REAL schema (every migration applied, e.g. the database of
supabase/tests/e2e/pipeline_db.sh): the current epoch lineage, step classes, link / contact events, the time-zone
history and nightly resting heart rate.

Opt-in: ANOMALY_TEST_PIPELINE_DB=postgresql://... (skipped otherwise). The test writes its own random user, device
and rows and deletes them afterwards.
"""
import json
import os
import uuid

import numpy as np
import pytest

from frwhoop_anomaly import features as F
from frwhoop_anomaly.db import Database

DB = os.environ.get("ANOMALY_TEST_PIPELINE_DB")
pytestmark = pytest.mark.skipif(not DB, reason="ANOMALY_TEST_PIPELINE_DB not set")

T0 = 1791441000          # 2026-10-08T06:30:00Z = 2026-10-07 23:30 PDT
DAY = "2026-10-08"       # its UTC day (epoch rows are keyed by UTC day)
TABLES = ("noop_hr_samples", "noop_gravity_samples", "noop_step_samples", "noop_events", "activity_context_epochs",
          "server_daily_scores", "scoring_timezone_history", "user_workouts")


@pytest.fixture()
def seeded():
  db = Database(DB, sslmode="disable")
  user, device, src = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
  c = db.conn()
  try:
    with c.transaction():
      c.execute("insert into auth.users(id) values (%s)", (user,))
      c.execute("""insert into public.profiles(id, timezone) values (%s, 'America/Los_Angeles')
                   on conflict (id) do update set timezone = excluded.timezone""", (user,))
      c.execute("""insert into public.devices(id, user_id, source_kind, device_family)
                   values (%s, %s, 'whoop', 'whoop5')""", (device, user))
      # One statement per table (the stream tables carry statement-level scoring triggers). 20 minutes, 60 HR
      # samples each; still for the first 10, dynAccel 0.08 g (moving, no steps) after.
      ids = (uuid.UUID(user), uuid.UUID(device), uuid.UUID(src), uuid.UUID(src))
      c.execute("""insert into public.noop_hr_samples(user_id, device_id, source_id, batch_id, ts, bpm)
                   select %s, %s, %s, %s, %s + s, 72 from generate_series(0, 1199) s""", ids + (T0,))
      c.execute("""insert into public.noop_gravity_samples(user_id, device_id, source_id, batch_id, ts, x, y, z,
                     "dynAccel")
                   select %s, %s, %s, %s, %s + s, 0, 0, 1, case when s < 600 then 0.01 else 0.08 end
                     from generate_series(0, 1199, 5) s""", ids + (T0,))
      # Steps: minute 12 is all walk/run ticks (class 1/2), minute 13 a third of them; counter flat otherwise.
      c.execute("""insert into public.noop_step_samples(user_id, device_id, source_id, batch_id, ts, counter,
                     "activityClass")
                   select %s, %s, %s, %s, %s + 720 + s, 100 + s / 5, case when s %% 10 = 0 then 2 else 1 end
                     from generate_series(0, 55, 5) s
                   union all
                   select %s, %s, %s, %s, %s + 780 + s, 200, case when s < 20 then 1 else 0 end
                     from generate_series(0, 55, 5) s""", ids + (T0,) + ids + (T0,))
      c.execute("""insert into public.noop_events(user_id, device_id, source_id, batch_id, ts, kind, "payloadJSON")
                   select %s, %s, %s, %s, %s + e.dt, e.kind, e.p
                     from (values (90, 'BLE_CONNECTION_DOWN(12)', '{}'), (150, 'BLE_CONNECTION_UP(11)', '{}'),
                                  (240, 'STANDARD_HR_CONTACT', '{"contact":"supported_not_detected"}'),
                                  (400, 'STANDARD_HR_CONTACT', '{"contact":"supported_detected"}')) e(dt, kind, p)""",
                ids + (T0,))
      # Two lineages of the same UTC day. The superseded one (revision 1) was computed LATER and says walking for
      # all 20 minutes; the current one (revision 2) says stationary for the first 10 only.
      rows = []
      for fp, rev, motion, n, computed in (("a" * 64, 1, "walking", 40, "2026-10-08T12:00:00Z"),
                                           ("b" * 64, 2, "stationary", 20, "2026-10-08T09:00:00Z")):
        for k in range(n):
          rows.append((user, device, DAY, T0 + 30 * k, T0 + 30 * k + 30, motion, "awake",
                       "resting_candidate" if motion == "stationary" else "unknown", "on_wrist", 0.9, 30, 30,
                       "m", "p", "v1", fp, rev, computed))
      c.execute("""insert into public.activity_context_epochs(user_id, device_id, day, start_ts, end_ts,
                     motion_label, sleep_state, exertion_context, wear_state, confidence, observed_s, valid_s,
                     model_version, preprocessing_version, ontology_version, fingerprint, result_revision, computed_at)
                   select (r->>0)::uuid, (r->>1)::uuid, (r->>2)::date, (r->>3)::bigint, (r->>4)::bigint, r->>5, r->>6,
                          r->>7, r->>8, (r->>9)::real, (r->>10)::int, (r->>11)::int, r->>12, r->>13, r->>14, r->>15,
                          (r->>16)::bigint, (r->>17)::timestamptz
                     from jsonb_array_elements(%s::jsonb) r""", (json.dumps(rows),))
      c.execute("delete from public.scoring_timezone_history where user_id = %s", (user,))
      c.execute("""insert into public.scoring_timezone_history(user_id, effective_at, timezone_id, provenance)
                   values (%s, '-infinity', 'America/Los_Angeles', 'test'),
                          (%s, '2026-10-09T12:00:00Z', 'America/New_York', 'test')""", (user, user))
      c.execute("""insert into public.server_daily_scores(user_id, day, algorithm_version, resting_hr_bpm)
                   select %s, ('2026-10-0' || d)::date, 'frwhoop-server-1', 58 + d from generate_series(1, 7) d
                   union all select %s, '2026-10-07', 'other-algo', 99""", (uuid.UUID(user), uuid.UUID(user)))
    yield db, user, device
  finally:
    with c.transaction():
      for t in TABLES:
        c.execute(f"delete from public.{t} where user_id = %s", (user,))
      c.execute("delete from public.devices where id = %s", (device,))
      c.execute("delete from auth.users where id = %s", (user,))
    db.close()


def test_load_reads_only_the_current_epoch_lineage_and_refines_toward_caution(seeded):
  db, user, device = seeded
  f = F.load(db, user, device, T0, T0 + 20 * 60)
  assert len(f.minutes) == 20 and (f.data["hr_n"] == 60).all()
  # Current lineage only: stationary for minutes 0-9 (still: they did not move), nothing from the stale lineage
  # after. Minutes 10-19 moved (0.08 g): the strap's own reading stays "unknown", never still.
  assert list(f.context[:10]) == ["still"] * 10
  assert all(c in ("unknown", "walking", "active", "recovery") for c in f.context[10:]), list(f.context[10:])
  assert (f.data["ep_strong"][:10] == 0).all() and np.isnan(f.data["ep_strong"][10:]).all()
  assert f.counters["context_from_epochs"] == 10
  # Pre-fix query (distinct on start_ts, newest computed_at, across every lineage): the stale lineage won.
  with db.read() as cur:
    cur.execute("""select distinct on (start_ts) start_ts, motion_label, sleep_state, exertion_context, wear_state,
                          confidence::float8 as conf
                     from public.activity_context_epochs
                    where user_id = %s and device_id = %s and start_ts >= %s and start_ts < %s
                    order by start_ts, computed_at desc""", (user, device, T0, T0 + 1200))
    old = F.epoch_context(f.minutes, cur.fetchall())
  assert old == ["walking"] * 20


def test_load_reads_step_classes_link_and_contact(seeded):
  db, user, device = seeded
  f = F.load(db, user, device, T0, T0 + 20 * 60)
  assert f.data["walk_frac"][12] == 1.0 and f.data["walk_frac"][13] == pytest.approx(4 / 12)
  assert np.isnan(f.data["walk_frac"][0])
  assert list(f.data["link_down"][:4]) == [0.0, 0.5, 0.5, 0.0]           # down 90 s .. 150 s
  assert np.isnan(f.data["contact_lost"][2]) and f.data["contact_lost"][3] == 1 and f.data["contact_lost"][6] == 0
  strong, weak = F.exertion_evidence(f)
  assert strong[12] and not strong[13] and weak[11] and not weak[5]


def test_timezone_history_and_resting_nights(seeded):
  db, user, _ = seeded
  tz = F.timezone_history(db, user)
  assert tz[0] == (float("-inf"), "America/Los_Angeles") and tz[1][1] == "America/New_York"
  assert F.local_day(T0, tz) == "2026-10-07"                               # 23:30 PDT
  nights = F.resting_nights(db, user, "2026-10-08")
  assert [d for d, _ in nights] == [f"2026-10-0{d}" for d in range(1, 8)]  # only frwhoop-server-1
  assert F.sleep_rest_reference(nights, "2026-10-07") == 61.5              # nights before the 7th: 59..64
  with db.conn().transaction():
    db.conn().execute("delete from public.scoring_timezone_history where user_id = %s", (user,))
  assert F.timezone_history(db, user) == [(float("-inf"), "America/Los_Angeles")]   # profiles.timezone


def test_load_reads_logged_workouts(seeded):
  # A workout logged in workout mode (20261009170000) over minutes 5..14 of the fixture: the `logged` channel is 1 there
  # and NaN elsewhere, and refresh_logged re-reads it after the log changes (deleted: NaN everywhere).
  db, user, device = seeded
  c = db.conn()
  with c.transaction():
    c.execute("""insert into public.user_workouts(user_id, client_id, device_id, workout_type, started_at, ended_at,
                   client_updated_at)
                 values (%s, %s, %s, 'strength', to_timestamp(%s), to_timestamp(%s), now())""",
              (user, str(uuid.uuid4()), device, T0 + 300, T0 + 900))
  f = F.load(db, user, device, T0, T0 + 1200)
  logged = f.data["logged"]
  assert (logged[5:15] == 1).all() and np.isnan(logged[:5]).all() and np.isnan(logged[15:]).all()
  assert f.counters["logged_workouts"] == 1
  with c.transaction():
    c.execute("update public.user_workouts set deleted_at = now() where user_id = %s", (user,))
  g = F.refresh_logged(db, f, user, device)
  assert np.isnan(g.data["logged"]).all()
