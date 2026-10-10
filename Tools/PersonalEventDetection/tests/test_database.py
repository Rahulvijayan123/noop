"""Opt-in integration tests against the isolated local fixture, never a production DSN."""
import json
import os
import time
import unittest
import uuid

from personal_events.database import Database
from personal_events.report import validate
from personal_events.worker import signature_job

DSN = os.environ.get('NARA_EVENT_TEST_DSN')
DAY = 86400


def allow_observations(db):
  """Mirror of the pending app migration (20261009100000) for the kind CHECK, applied to the disposable test
  database only: observation entries are written directly, as the edge function will."""
  db.execute("""do $$ declare c record; begin
    for c in select con.conname from pg_constraint con where con.conrelid='public.manual_event_revisions'::regclass
      and con.contype='c' and pg_get_constraintdef(con.oid) like '%%preset%%'
      and pg_get_constraintdef(con.oid) not like '%%observation%%' loop
      execute format('alter table public.manual_event_revisions drop constraint %%I', c.conname);
    end loop; end $$""")
  db.execute("""do $$ begin if not exists(select 1 from pg_constraint where conname='manual_event_revisions_kind_test')
    then alter table public.manual_event_revisions add constraint manual_event_revisions_kind_test
      check (body->'entry'->>'kind' in ('event','event_type','preset','observation')); end if; end $$""")


@unittest.skipUnless(DSN and ('127.0.0.1' in DSN or 'localhost' in DSN or '/tmp' in DSN), 'local fixture DSN required')
class DatabaseTests(unittest.TestCase):
  def setUp(self):
    self.db = Database(DSN); self.owner = uuid.uuid4(); self.other = uuid.uuid4(); self.source = uuid.uuid4(); self.typ = uuid.uuid4(); self.device = uuid.uuid4()
    for owner in [self.owner, self.other]: self.db.execute('insert into auth.users(id) values(%s)', (owner,))
    self.db.execute('insert into noop_app_installations(user_id,source_id) values(%s,%s)', (self.owner, self.source))
    self.type_entry = dict(id=str(self.typ), kind='event_type', label='Walking', symbol='figure.walk', favorite=False, timeZoneIdentifier='UTC', archived=False)
    self.append(self.type_entry)

  def tearDown(self):
    for t in ('noop_rr_intervals', 'noop_gravity_samples', 'noop_step_samples', 'noop_sleep_state_samples', 'noop_events',
              'activity_context_runs', 'server_sleep_nights', 'noop_hr_samples', 'noop_skin_temp_samples', 'server_metric_series',
              'phone_context_intervals'):
      self.db.execute(f'delete from {t} where user_id in (%s,%s)', (self.owner, self.other))
    self.db.execute('delete from auth.users where id in (%s,%s)', (self.owner, self.other)); self.db.conn.close()

  def append(self, entry, stamp=1000):
    revision = dict(revision_id=str(uuid.uuid4()), updated_at_ms=stamp, entry=entry)
    return self.db.row('select append_manual_event_revisions(%s,%s,%s::jsonb) r', (self.owner, self.source, json.dumps([revision])))['r']

  def append_raw(self, entry, stamp=1000):
    rid = uuid.uuid4()
    body = dict(revision_id=str(rid), updated_at_ms=stamp, entry=entry)
    self.db.execute('insert into manual_event_revisions(user_id,source_id,revision_id,entity_id,updated_at_ms,body) values(%s,%s,%s,%s,%s,%s::jsonb)',
                    (self.owner, self.source, rid, entry['id'], stamp, json.dumps(body)))

  def command(self, **body):
    body = dict(requestId=str(uuid.uuid4()), typeId=str(self.typ), **body)
    return self.db.row('select event_detection_command(%s,%s,%s::jsonb) r', (self.owner, self.source, json.dumps(body)))['r']

  def event(self, start, end, typ=None, device=None, **extra):
    entry = dict(id=str(uuid.uuid4()), kind='event', label='Walking', symbol='figure.walk', typeId=str(typ or self.typ),
                 favorite=False, timeZoneIdentifier='UTC', archived=False, deviceId=str(device or self.device).upper(),
                 startUnixSeconds=start, endUnixSeconds=end, **extra)
    self.append(entry, int(time.time() * 1000))
    return entry

  # ------------------------------------------------------------------------------- PR #5 behaviour kept
  def test_off_and_archive_fence_claims_and_retains_data(self):
    self.command(action='setting', enabled=True); self.db.schedule(); job = self.db.claim('train')
    self.assertIsNotNone(job)
    self.command(action='setting', enabled=False)
    with self.assertRaises(InterruptedError):
      with self.db.fenced(job): self.fail('disabled job published')
    self.command(action='setting', enabled=True); job = self.db.claim('train')
    self.append(dict(self.type_entry, archived=True, archivedAt=2000), 2000)
    with self.assertRaises(InterruptedError):
      with self.db.fenced(job): self.fail('archived type published')
    self.assertEqual(self.db.row('select count(*) n from manual_event_revisions where user_id=%s', (self.owner,))['n'], 2)

  def test_retry_confirmation_rename_and_foreign_owner(self):
    self.command(action='setting', enabled=True)
    eid = uuid.uuid4()
    self.db.execute('insert into event_detections(user_id,id,type_id,device_id,start_at,end_at,model_id) values(%s,%s,%s,%s,100,200,%s)', (self.owner, eid, self.typ, self.device, uuid.uuid4()))
    self.command(action='review', detectionId=str(eid), outcome='confirmed', start=100, end=200)
    self.command(action='review', detectionId=str(eid), outcome='confirmed', start=100, end=200)
    self.assertEqual(self.db.row("select count(*) n from manual_events_current where user_id=%s and entry->>'kind'='event'", (self.owner,))['n'], 1)
    self.append(dict(self.type_entry, label='Walking outside'), 3000)
    self.assertEqual(self.db.row('select type_id from event_detector_settings where user_id=%s', (self.owner,))['type_id'], self.typ)
    with self.assertRaises(Exception):
      self.db.row('select event_detection_command(%s,%s,%s::jsonb)', (self.other, self.source, json.dumps(dict(action='setting', requestId=str(uuid.uuid4()), typeId=str(self.typ), enabled=True))))

  def test_sensor_invalidations_and_private_tables(self):
    self.command(action='setting', enabled=True)
    self.db.execute('insert into noop_hr_samples values(%s,%s,100,70),(%s,%s,101,71)', (self.owner, self.device, self.owner, self.device))
    self.assertEqual(self.db.row('select revision from event_detection_inputs where user_id=%s', (self.owner,))['revision'], 1)
    self.db.execute('set role authenticated')
    try:
      for table in ['event_detector_models', 'event_detector_jobs', 'event_detection_reviews', 'event_detector_runs']:
        with self.assertRaises(Exception): self.db.rows('select * from ' + table)
    finally: self.db.execute('reset role')

  def test_physiology_does_not_leak_foreign_device_or_bridge_missing_samples(self):
    self.db.execute('insert into noop_hr_samples values(%s,%s,100,70),(%s,%s,500,90)', (self.owner, self.device, self.owner, self.device))
    self.db.execute('insert into server_metric_series values(%s,%s,\'hrv_rmssd_ms\',to_timestamp(100),300,45)', (self.owner, self.device))
    r = self.db.row('select event_physiology(%s,%s,0,600) r', (self.owner, self.device))['r']
    self.assertEqual(len(r['heartRate']), 2); self.assertEqual(r['hrv'][0]['support'], 300)
    r = self.db.row('select event_physiology(%s,%s,0,600) r', (self.other, self.device))['r']
    self.assertEqual(r['heartRate'], []); self.assertEqual(r['hrv'], [])

  def test_layer1_reads_the_phones_uploaded_intervals_with_history(self):
    from personal_events import layer1_context as L
    from personal_events.timeline import load_postgres
    lo = 1_790_000_000 - 1_790_000_000 % DAY
    tl = load_postgres(self.db, self.owner, self.device, lo, lo + 3600)
    self.assertIsNone(tl.meta['context_intervals'])
    self.assertEqual(tl.meta['layer1_unavailable'], L.UNAVAILABLE_SERVER)
    other_device = uuid.uuid4()
    for dev, start in ((self.device, lo - 30 * DAY), (self.device, lo), (other_device, lo), (self.device, lo + 7200)):
      self.db.execute("""insert into phone_context_intervals(user_id,device_id,start_ts,end_ts,activity_class,confidence,
          evidence_quality,posture,locomotion,sleep_state,wear_state,intensity,hr_samples,hr_mean,rmssd,rr_beats,
          rr_diff_sq_sum_ms2,rr_diff_count,detail,arm_behavior) values(%s,%s,%s,%s,'sitting',0.9,0.8,'seated_likely',
          'stationary','awake','on_wrist',0.1,590,70.5,40,700,1120000,700,'in_vehicle','exercise_motion')""",
          (self.owner, dev, start, start + 600))
    tl = load_postgres(self.db, self.owner, self.device, lo, lo + 3600)
    rows = tl.meta['context_intervals']
    self.assertIsNone(tl.meta['layer1_unavailable'])
    self.assertEqual([r.start for r in rows], [lo - 30 * DAY, lo])   # history before the timeline, one strap only
    self.assertEqual((rows[1].posture, rows[1].hr_mean, rows[1].rr_diff_count, rows[1].detail, rows[1].arm_behavior),
                     ('seated_likely', 70.5, 700, 'in_vehicle', 'exercise_motion'))

  # ------------------------------------------------------------------------------- signature job
  def seed_sensors(self, lo, hi, events):
    """1 Hz HR (+20 bpm in event windows), RR, 1 Hz motion/steps, skin temperature, one activity run per hour."""
    windows = ' or '.join(f'(t between {int(s)} and {int(s) + 600})' for s in events) or 'false'
    args = (self.owner, self.device, lo, hi)
    self.db.execute(f"""insert into noop_hr_samples select %s,%s,t,
        (62 + 8*sin(t/5400.0) + (case when {windows} then 20 else 0 end) + 3*sin(t/97.0))::int
        from generate_series(%s::bigint,%s::bigint-1) t""", args)
    self.db.execute("""insert into noop_rr_intervals(user_id,device_id,ts,"rrMs",seq,"srcChannel")
        select %s,%s,t,900 + (t %% 3)*15,0,5 from generate_series(%s::bigint,%s::bigint-1) t""", args)
    self.db.execute("""insert into noop_gravity_samples(user_id,device_id,ts,"dynAccel")
        select %s,%s,t,0.01 + 0.005*sin(t/13.0) from generate_series(%s::bigint,%s::bigint-1,2) t""", args)
    self.db.execute("""insert into noop_step_samples(user_id,device_id,ts,counter)
        select %s,%s,t,((t/86400)*7) %% 65536 from generate_series(%s::bigint,%s::bigint-1,5) t""", args)
    self.db.execute("""insert into noop_skin_temp_samples select %s,%s,t,3400 + 20*sin(t/7200.0)
        from generate_series(%s::bigint,%s::bigint-1,30) t""", args)
    self.db.execute("""insert into noop_sleep_state_samples(user_id,device_id,ts,state)
        select %s,%s,t,case when (t %% 86400) < 6*3600 then 2 else 0 end from generate_series(%s::bigint,%s::bigint-1,30) t""", args)
    self.db.execute("""insert into noop_events(user_id,device_id,ts,kind) values (%s,%s,%s,'WRIST_ON(9)')""", (self.owner, self.device, lo + 1))
    self.db.execute("""insert into activity_context_runs select %s,%s,(to_timestamp(t) at time zone 'UTC')::date,t,t+3600,
        case when (t %% 86400) < 6*3600 then 'sleeping' else 'sitting' end,0.9,
        case when (t %% 86400) < 6*3600 then 'asleep' else 'awake' end,'on_wrist','{"seated_likely":0.9}'::jsonb,1
        from generate_series(%s::bigint,%s::bigint-1,3600) t""", args)

  def test_signature_job_assembles_evidence_and_persists_report(self):
    allow_observations(self.db)
    now = (int(time.time()) // DAY) * DAY
    lo = now - 10 * DAY
    starts = [lo + (k + 2) * DAY + 14 * 3600 for k in range(7)]
    other_typ = uuid.uuid4()
    self.append(dict(self.type_entry, id=str(other_typ), label='Other'))
    self.command(action='setting', enabled=True)
    for k, s in enumerate(starts):
      self.event(s, s + 600, **({'onsetUncertaintyMinutes': 15} if k == 0 else {}))
    self.event(starts[0] + 5 * 3600, starts[0] + 5 * 3600 + 300, typ=other_typ)
    archived = self.event(starts[1] + 3600, starts[1] + 4000)
    self.append(dict(archived, archived=True, archivedAt=1), int(time.time() * 1000) + 5)
    self.append_raw(dict(id=str(uuid.uuid4()), kind='observation', label='Watching', archived=False,
                         startUnixSeconds=starts[2] + 3 * 3600, endUnixSeconds=starts[2] + 6 * 3600))
    review = self.command(action='negative', deviceId=str(self.device), start=starts[3] + 4 * 3600, end=starts[3] + 5 * 3600)['saved']
    self.command(action='negative', deviceId=str(self.device), start=starts[4] + 4 * 3600, end=starts[4] + 5 * 3600)
    self.command(action='withdraw', reviewId=str(review).upper())
    self.seed_sensors(lo, now, starts)

    self.db.schedule(); job = self.db.claim('train')
    data = self.db.signature_dataset(job, now)
    ev = data['evidence']
    self.assertEqual(data['device'], str(self.device))
    self.assertEqual(len(ev.events), 7)                                      # archived event excluded
    self.assertEqual(ev.events[0].uncertainty_min, 15.0); self.assertEqual(ev.events[1].uncertainty_min, 5.0)
    self.assertEqual(len(ev.other_events), 1)
    self.assertEqual(len(ev.observations), 1)
    self.assertEqual([n[:2] for n in ev.negatives], [(starts[4] + 4 * 3600.0, starts[4] + 5 * 3600.0)])  # withdrawn dropped
    self.assertGreater(ev.negatives[0][2], starts[4])                         # available_at = review time
    self.assertEqual(len(ev.observations[0]), 3)
    tl = data['timeline']
    self.assertEqual(int(tl.minutes[0]), starts[0] - 30 * DAY)              # first label - 30 days
    seeded = tl.minutes >= lo
    self.assertGreater(float((tl['hr'][seeded] == tl['hr'][seeded]).mean()), 0.95)
    self.assertFalse((tl['hr'][~seeded] == tl['hr'][~seeded]).any())          # no data stays NaN
    self.assertTrue((tl['ln_rmssd'] == tl['ln_rmssd']).any())
    self.assertTrue((tl['activity'] >= 0).any())

    status = signature_job(self.db, job, now=now)
    run = self.db.row('select snapshot,report from event_detector_runs where user_id=%s and type_id=%s', (self.owner, self.typ))
    self.assertEqual(validate(run['report']), [])
    self.assertEqual(run['report']['version'], 'signature-report-1')
    self.assertEqual(run['report']['evidence']['events'], 7)
    self.assertEqual(run['report']['evidence']['negative_intervals'], 1)
    self.assertEqual(run['report']['evidence']['observation_hours'], 3.0)
    s = self.db.row('select state,detail from event_detector_settings where user_id=%s and type_id=%s', (self.owner, self.typ))
    self.assertEqual(s['state'], status)
    self.assertEqual(set(s['detail']), {'status', 'events', 'event_days', 'assessment'})
    self.assertEqual(self.db.row('select count(*) n from event_detections where user_id=%s', (self.owner,))['n'], 0)
    self.assertEqual(run['report']['engine']['version'], 'sig-4')
    self.assertEqual(run['report']['retrospective']['training_cutoff'], now)

  def test_unchanged_inputs_skip_recomputation(self):
    now = (int(time.time()) // DAY) * DAY
    lo = now - 6 * DAY
    starts = [lo + (k + 1) * DAY + 15 * 3600 for k in range(4)]
    self.command(action='setting', enabled=True)
    for s in starts:
      self.event(s, s + 600)
    self.seed_sensors(lo, now, starts)
    self.db.schedule(); job = self.db.claim('train')
    count = lambda: self.db.row('select count(*) n from event_detector_runs where user_id=%s', (self.owner,))['n']
    first = signature_job(self.db, job, now=now)
    self.assertEqual(count(), 1)
    self.assertEqual(signature_job(self.db, job, now=now + 600), first)       # same data, later clock: skipped
    self.assertEqual(count(), 1)
    self.db.execute('insert into noop_hr_samples values(%s,%s,%s,70)', (self.owner, self.device, now + 30))
    signature_job(self.db, job, now=now + 600)                                # new sample: recomputed
    self.assertEqual(count(), 2)

  def test_incumbent_cutoff_comes_from_the_promoted_report(self):
    from personal_events import engine
    now = (int(time.time()) // DAY) * DAY
    lo = now - 6 * DAY
    starts = [lo + (k + 1) * DAY + 15 * 3600 for k in range(4)]
    self.command(action='setting', enabled=True)
    for s in starts:
      self.event(s, s + 600)
    self.seed_sensors(lo, now, starts)
    self.db.execute("""insert into event_detector_runs(user_id,type_id,id,snapshot,report) values(%s,%s,%s,'old',%s::jsonb)""",
                    (self.owner, self.typ, uuid.uuid4(), json.dumps({'version': 'signature-report-1', 'status': 'emerging',
                     'retrospective': {'promoted': True, 'training_cutoff': lo + 3 * DAY}})))
    self.db.schedule(); job = self.db.claim('train')
    seen = {}
    real = engine.run
    def spy(*a, **kw):
      seen.update(kw); return real(*a, **kw)
    engine.run = spy
    try:
      signature_job(self.db, job, now=now)
    finally:
      engine.run = real
    self.assertEqual(seen['incumbent'], {'training_cutoff': float(lo + 3 * DAY)})

  def test_label_change_during_run_fences_the_report(self):
    now = (int(time.time()) // DAY) * DAY
    lo = now - 6 * DAY
    starts = [lo + (k + 1) * DAY + 15 * 3600 for k in range(4)]
    self.command(action='setting', enabled=True)
    for s in starts:
      self.event(s, s + 600)
    self.seed_sensors(lo, now, starts)
    self.db.schedule(); job = self.db.claim('train')
    test = self

    class EditingHeartbeat:
      calls = 0
      def check(inner):
        inner.calls += 1
        if inner.calls == 1:
          test.event(starts[0] + 7200, starts[0] + 7500)
    with self.assertRaises(InterruptedError):
      signature_job(self.db, job, EditingHeartbeat(), now=now)
    self.assertEqual(self.db.row('select count(*) n from event_detector_runs where user_id=%s', (self.owner,))['n'], 0)
    # A disabled setting also fences the publish.
    job = dict(job)
    self.command(action='setting', enabled=False)
    with self.assertRaises(InterruptedError):
      signature_job(self.db, job, now=now)
    self.assertEqual(self.db.row('select count(*) n from event_detector_runs where user_id=%s', (self.owner,))['n'], 0)

  def test_label_change_brings_training_forward(self):
    self.command(action='setting', enabled=True)
    self.db.schedule()
    self.db.execute("update event_detector_settings set last_training_at=now() where user_id=%s", (self.owner,))
    self.db.execute("update event_detector_jobs set due_at=now()+interval '1 day' where user_id=%s", (self.owner,))
    self.db.schedule()
    due = self.db.row("select due_at > now()+interval '12 hours' later from event_detector_jobs where user_id=%s and kind='train'", (self.owner,))
    self.assertTrue(due['later'])                                           # nothing changed since the last run
    time.sleep(0.05)
    self.event(1000, 1600)
    self.db.schedule()
    due = self.db.row("select due_at - now() d from event_detector_jobs where user_id=%s and kind='train'", (self.owner,))['d']
    self.assertLessEqual(due.total_seconds(), 601)
    infer = self.db.row("select due_at - now() d from event_detector_jobs where user_id=%s and kind='infer'", (self.owner,))['d']
    self.assertGreater(infer.total_seconds(), 12 * 3600)


if __name__ == '__main__': unittest.main()
