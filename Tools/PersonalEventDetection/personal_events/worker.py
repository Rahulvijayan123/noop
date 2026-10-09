"""Supervised worker lanes. The training lane runs the signature engine (sig-1) and stores signature-report-1 in
event_detector_runs. The inference lane does not publish detections in this phase: alerts are not enabled."""
import argparse
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import shutil
import sys
import threading
import time
import uuid

from .database import Database

LOG = logging.getLogger('nara.events')
DAILY_REFRESH_S = 86400
PUBLISH_FLAG = 'NARA_EVENT_DETECTION_PUBLISH'
INFER_DISABLED = ('The inference lane is disabled: this phase has no real-time alerts (docs/PHENOTYPE_SIGNATURES.md). '
                  'Signature reports are produced by --lane train. Keep NARA_EVENT_DETECTION_PUBLISH unset.')
INFER_NOTHING = ('NARA_EVENT_DETECTION_PUBLISH=1 is set, but signature engine sig-1 has no publishing detector; '
                 'nothing to run. Unset it.')


def clean_deleted_accounts(db, cache):
  """Private caches share the database's whole-account deletion lifecycle."""
  if not cache.exists(): return
  owners = {str(row['user_id']) for row in db.rows('select distinct user_id from event_detector_settings')}
  for child in cache.iterdir():
    try: owner = str(uuid.UUID(child.name))
    except ValueError: continue
    if owner not in owners and child.is_dir() and not child.is_symlink(): shutil.rmtree(child)


class LeaseHeartbeat:
  def __init__(self, dsn, job): self.dsn = dsn; self.job = job; self.stop = threading.Event(); self.error = None
  def __enter__(self):
    def run():
      db = Database(self.dsn)
      try:
        while not self.stop.wait(30): db.heartbeat(self.job)
      except Exception as error: self.error = error
      finally: db.conn.close()
    self.thread = threading.Thread(target=run, daemon=True); self.thread.start(); return self
  def check(self):
    if self.error: raise InterruptedError('Lease renewal failed') from self.error
  def __exit__(self, *_): self.stop.set(); self.thread.join(timeout=5)


class NoHeartbeat:
  def check(self): pass


def signature_job(db, job, heartbeat=None, *, normalization='context', now=None):
  """Assemble evidence + timeline, run the engine, and publish the report under the job's fence. Labels edited
  while the engine ran fence the result (the job is retried with the new labels). Returns the report status."""
  from . import engine
  from .report import validate
  heartbeat = heartbeat or NoHeartbeat()
  owner, typ = job['user_id'], job['type_id']
  previous = db.row("""select snapshot,report,created_at from event_detector_runs where user_id=%s and type_id=%s
      and report->>'version'='signature-report-1' order by created_at desc,id desc limit 1""", (owner, typ))
  with db.conn.transaction():
    db.execute('set transaction isolation level repeatable read')
    db.execute("set local statement_timeout='120s'")
    data = db.signature_dataset(job, now, normalization=normalization,
                                previous_snapshot=previous['snapshot'] if previous else None)
  heartbeat.check()
  if data['unchanged']:
    # Same labels, same sensor inputs, same engine: keep the stored report.
    with db.fenced(job):
      db.execute("update event_detector_settings set state=%s,last_training_at=now() where user_id=%s and type_id=%s",
                 (previous['report']['status'], owner, typ))
    return previous['report']['status']
  promoted = db.row("""select report->'retrospective'->>'training_cutoff' as cutoff, created_at from event_detector_runs
      where user_id=%s and type_id=%s and report->>'version'='signature-report-1'
      and (report->'retrospective'->>'promoted')::boolean order by created_at desc, id desc limit 1""", (owner, typ))
  incumbent = None
  if promoted:
    # The incumbent's training cutoff is stored in its report; legacy reports fall back to the run time.
    cutoff = float(promoted['cutoff']) if promoted['cutoff'] is not None else promoted['created_at'].timestamp()
    incumbent = {'training_cutoff': cutoff}
  report, _, _ = engine.run(data['timeline'], data['evidence'], normalization=normalization, generated_at=now,
                            incumbent=incumbent)
  heartbeat.check()
  problems = validate(report)
  if problems:
    raise ValueError('Signature report failed validation')
  with db.fenced(job):
    # Label edits during the run must not publish a report computed from stale labels.
    if db.label_revisions(owner) != (data['manualRevisions'], data['reviewRevisions']):
      raise InterruptedError('Labels changed during the signature run; retry with the new labels')
    db.execute('insert into event_detector_runs(user_id,type_id,id,snapshot,report) values(%s,%s,%s,%s,%s::jsonb)',
               (owner, typ, uuid.uuid4(), data['snapshot'], json.dumps(report, allow_nan=False)))
    detail = {'status': report['status'], 'events': report['evidence']['events'],
              'event_days': report['evidence']['event_days'], 'assessment': report['detectability']['assessment']}
    db.execute("""update event_detector_settings set state=%s,detail=%s::jsonb,last_training_at=now()
        where user_id=%s and type_id=%s""", (report['status'], json.dumps(detail), owner, typ))
  return report['status']


def main():
  parser = argparse.ArgumentParser(); parser.add_argument('--lane', choices=['train', 'infer'], required=True)
  parser.add_argument('--once', action='store_true'); args = parser.parse_args()
  if os.environ.get('NARA_EVENT_DETECTION_ENABLED') != '1':
    parser.error('Disabled. A maintainer must explicitly enable this service after deployment checks.')
  if args.lane == 'infer':
    # No alerts in this phase: the lane never claims a job or writes a detection.
    print(INFER_NOTHING if os.environ.get(PUBLISH_FLAG) == '1' else INFER_DISABLED, file=sys.stderr)
    sys.exit(0)
  dsn = os.environ['NARA_EVENT_DATABASE_URL']; cache = Path(os.environ.get('NARA_EVENT_CACHE', '/var/lib/nara-events'))
  normalization = os.environ.get('NARA_EVENT_NORMALIZATION', 'context')
  db = Database(dsn); logging.basicConfig(level=logging.INFO); cleanup_at = 0
  while True:
    if time.time() > cleanup_at:
      clean_deleted_accounts(db, cache); cleanup_at = time.time() + 3600
    db.schedule(); job = db.claim('train')
    if job:
      try:
        with LeaseHeartbeat(dsn, job) as heartbeat:
          signature_job(db, job, heartbeat, normalization=normalization)
        # New sensor data arrives continuously: refresh daily; label changes bring the job forward (schedule()).
        db.finish(job, DAILY_REFRESH_S)
      except InterruptedError:
        db.retry(job); LOG.info('Job was fenced; retry scheduled')
      except Exception as error:
        # No credentials, SQL parameters or physiological data in logs.
        try:
          with db.fenced(job):
            db.execute("update event_detector_settings set state='paused',detail=%s::jsonb where user_id=%s and type_id=%s",
                       (json.dumps(dict(reason='Worker could not complete this run. It will retry.')), job['user_id'], job['type_id']))
        except Exception: pass
        db.retry(job); LOG.error('Job failed: %s', type(error).__name__)
    if args.once: break
    time.sleep(1 if job else 15)


if __name__ == '__main__': main()
