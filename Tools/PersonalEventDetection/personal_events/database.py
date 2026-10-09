"""Private worker database adapter. Every data query includes the credential-derived owner."""
from contextlib import contextmanager
from datetime import datetime, timezone
import collections
import hashlib
import json
import time
import uuid

from .evidence import DEFAULT_UNCERTAINTY_MIN, Event, Evidence

LOOKBACK_S = 30 * 86400
MAX_SPAN_S = 120 * 86400
RETRAIN_DELAY = "10 minutes"
OPEN_EVENT_S = 3600


class Database:
  def __init__(self, dsn):
    import psycopg
    from psycopg.rows import dict_row
    self.conn = psycopg.connect(dsn, autocommit=True, row_factory=dict_row)
    self.conn.execute("set statement_timeout='30s'")
    self.conn.execute("set lock_timeout='3s'")

  def rows(self, sql, args=()): return self.conn.execute(sql, args).fetchall()
  def row(self, sql, args=()): return self.conn.execute(sql, args).fetchone()
  def execute(self, sql, args=()): return self.conn.execute(sql, args)

  def schedule(self):
    self.execute("""insert into event_detector_jobs(user_id,type_id,kind)
        select s.user_id,s.type_id,k from event_detector_settings s
        cross join (values ('train'),('infer')) v(k) where s.enabled
        on conflict(user_id,type_id,kind) do nothing""")
    # Event-driven retraining: a label change (manual log/observation revision or review) since the last run
    # brings the signature job forward to 10 minutes after the latest change (debounced), instead of weekly.
    self.execute(f"""with changed as (
        select s.user_id, s.type_id, greatest(
          (select max(r.received_at) from manual_event_revisions r where r.user_id = s.user_id),
          (select max(v.created_at) from event_detection_reviews v where v.user_id = s.user_id)) as at
        from event_detector_settings s where s.enabled)
      update event_detector_jobs j set due_at = c.at + interval '{RETRAIN_DELAY}'
        from changed c, event_detector_settings s
       where j.user_id = c.user_id and j.type_id = c.type_id and j.kind = 'train' and j.lease_token is null
         and s.user_id = c.user_id and s.type_id = c.type_id and c.at is not null
         and c.at > coalesce(s.last_training_at, '-infinity'::timestamptz)
         and j.due_at > c.at + interval '{RETRAIN_DELAY}'""")

  def claim(self, kind):
    with self.conn.transaction():
      job = self.row("""select j.* from event_detector_jobs j join event_detector_settings s using(user_id,type_id)
          where j.kind=%s and s.enabled and j.due_at<=now() and (j.lease_until is null or j.lease_until<now())
            and (j.kind='train' or s.active_model_id is not null)
          order by j.due_at,j.user_id,j.type_id for update of j skip locked limit 1""", (kind,))
      if not job: return None
      setting = self.row("select * from event_detector_settings where user_id=%s and type_id=%s", (job['user_id'], job['type_id']))
      token = uuid.uuid4()
      self.execute("""update event_detector_jobs set lease_token=%s,lease_until=now()+interval '5 minutes',
          settings_revision=%s,attempts=attempts+1 where user_id=%s and type_id=%s and kind=%s""",
                   (token, setting['revision'], job['user_id'], job['type_id'], kind))
      return dict(job, token=token, setting=setting)

  @contextmanager
  def fenced(self, job):
    with self.conn.transaction():
      self.execute("select pg_advisory_xact_lock(hashtextextended('event-detection:'||%s::text,0))", (job['user_id'],))
      self.execute("select pg_advisory_xact_lock(hashtextextended('manual-events:'||%s::text,0))", (job['user_id'],))
      setting = self.row("select * from event_detector_settings where user_id=%s and type_id=%s for update", (job['user_id'], job['type_id']))
      claim = self.row("select * from event_detector_jobs where user_id=%s and type_id=%s and kind=%s for update", (job['user_id'], job['type_id'], job['kind']))
      if (not setting or not setting['enabled'] or setting['revision'] != job['setting']['revision'] or not claim
          or claim['lease_token'] != job['token'] or claim['lease_until'] <= datetime.now(timezone.utc)):
        raise InterruptedError('Job fenced by account, setting or lease change')
      yield setting

  def heartbeat(self, job):
    with self.fenced(job):
      self.execute("update event_detector_jobs set lease_until=now()+interval '5 minutes' where lease_token=%s", (job['token'],))

  def finish(self, job, seconds):
    with self.fenced(job):
      self.execute("""update event_detector_jobs set lease_token=null,lease_until=null,
          due_at=now()+%s*interval '1 second',attempts=0 where lease_token=%s""", (seconds, job['token']))

  def retry(self, job):
    # A revoked/replaced claim cannot change the replacement job's due time.
    self.execute("""update event_detector_jobs set lease_token=null,lease_until=null,
        due_at=now()+%s*interval '1 second' where lease_token=%s""", (min(3600, 30 * 2 ** min(job['attempts'], 7)), job['token']))

  # ------------------------------------------------------------------------------------------- signature data

  def label_revisions(self, owner):
    """Every label input of a signature run: current manual event/observation revisions and all reviews."""
    manual = self.rows("""select revision_id from manual_events_current where user_id=%s
        and entry->>'kind' in ('event','observation')""", (owner,))
    reviews = self.rows('select id from event_detection_reviews where user_id=%s', (owner,))
    return sorted(str(r['revision_id']) for r in manual), sorted(str(r['id']) for r in reviews)

  def stream_fingerprint(self, owner, device, lo, hi):
    """Per input stream: row count and latest timestamp over [lo, hi). Unchanged inputs -> same fingerprint, so a
    run can be skipped before the timeline is loaded (the grid end moving with `now` does not count)."""
    out = {}
    for table in ('noop_hr_samples', 'noop_rr_intervals', 'noop_gravity_samples', 'noop_step_samples',
                  'noop_skin_temp_samples', 'noop_sleep_state_samples'):
      r = self.row(f'select count(*) n, max(ts) m from {table} where user_id=%s and device_id=%s and ts>=%s and ts<%s',
                   (owner, device, lo, hi))
      out[table] = [int(r['n']), None if r['m'] is None else int(r['m'])]
    r = self.row("""select count(*) n, max(ts) m from noop_events where user_id=%s and device_id=%s and ts>=%s and ts<%s
        and kind like 'WRIST_O%%'""", (owner, device, lo - 86400, hi))
    out['noop_events'] = [int(r['n']), None if r['m'] is None else int(r['m'])]
    r = self.row("""select count(*) n, max(end_ts) m from activity_context_runs where user_id=%s and device_id=%s
        and end_ts > %s and start_ts < %s""", (owner, device, lo, hi))
    out['activity_context_runs'] = [int(r['n']), None if r['m'] is None else int(r['m'])]
    r = self.row("""select count(*) n, extract(epoch from max(bucket_start))::bigint m from server_metric_series
        where user_id=%s and device_id=%s and metric='resp_rate_bpm' and bucket_start >= to_timestamp(%s)
        and bucket_start < to_timestamp(%s)""", (owner, device, lo, hi))
    out['server_metric_series'] = [int(r['n']), None if r['m'] is None else int(r['m'])]
    r = self.row("""select count(*) n, extract(epoch from max(end_at))::bigint m from server_sleep_nights
        where user_id=%s and (device_id=%s or device_id is null) and end_at > to_timestamp(%s)
        and start_at < to_timestamp(%s)""", (owner, device, lo, hi))
    out['server_sleep_nights'] = [int(r['n']), None if r['m'] is None else int(r['m'])]
    return out

  def signature_dataset(self, job, now=None, *, normalization='context', previous_snapshot=None):
    """Caregiver evidence and the device timeline for one (owner, type). Labels: this type's completed events
    (onsetUncertaintyMinutes, default 5), other types' events, observation periods, reviewed negative intervals
    (not withdrawn), rejected / confirmed detections, pending detections (excluded time). Unsure reviews and
    archived entries are not used. The timeline spans [first relevant label - 30 days, now], at most 120 days.
    Every caregiver span carries when it reached the server (start, end, available_at). The snapshot fingerprints
    labels + per-stream counts/latest timestamps + engine version; when it equals `previous_snapshot` the
    timeline is not loaded and `unchanged` is True."""
    from .timeline import load_postgres
    owner, typ = job['user_id'], str(job['type_id']).lower()
    now = time.time() if now is None else float(now)
    entries = self.rows("""select entity_id,entry,revision_id,received_at from manual_events_current where user_id=%s
        and entry->>'kind' in ('event','observation')""", (owner,))
    manual_revisions = sorted(str(e['revision_id']) for e in entries)
    entries = [e for e in entries if not _archived(e['entry'])]
    for e in entries:
      value = e['entry'].get('deviceId')
      e['entry']['deviceId'] = str(uuid.UUID(value)) if valid_uuid(value) else None
    events = [e for e in entries if e['entry'].get('kind') == 'event' and _num(e['entry'].get('startUnixSeconds')) is not None]
    mine = [e for e in events if str(e['entry'].get('typeId', '')).lower() == typ
            and _num(e['entry'].get('endUnixSeconds')) is not None]
    # A signature describes one wearable source; the canonical device is the one with the most events (PR #5).
    devices = sorted({e['entry']['deviceId'] for e in mine if e['entry']['deviceId']})
    device = max(devices, key=lambda d: sum(e['entry']['deviceId'] == d for e in mine)) if devices else None

    def as_event(e):
      x = e['entry']
      end = _num(x.get('endUnixSeconds'))
      unc = _num(x.get('onsetUncertaintyMinutes'))
      start = float(x['startUnixSeconds'])
      return Event(id=str(x['id']), start=start, end=float(end if end is not None else start + OPEN_EVENT_S),
                   uncertainty_min=DEFAULT_UNCERTAINTY_MIN if unc is None else float(unc),
                   available_at=e['received_at'].timestamp(), type_id=str(x.get('typeId', '')).lower())
    this_type = sorted((as_event(e) for e in mine if e['entry']['deviceId'] == device), key=lambda e: (e.start, e.id))
    mine_ids = {e['entry']['id'] for e in mine}
    # Other types' events (and this type's still-open or other-device events) are the same person's time:
    # they exclude baseline/control time and count as negatives for this type unless they overlap.
    other = sorted((as_event(e) for e in events if e['entry']['id'] not in mine_ids or e['entry']['deviceId'] != device),
                   key=lambda e: (e.start, e.id))
    observations = sorted((float(e['entry']['startUnixSeconds']), float(e['entry']['endUnixSeconds']),
                           e['received_at'].timestamp()) for e in entries if e['entry'].get('kind') == 'observation'
                    and _num(e['entry'].get('startUnixSeconds')) is not None
                          and _num(e['entry'].get('endUnixSeconds')) is not None)

    reviews = self.rows('select id,body,created_at from event_detection_reviews where user_id=%s order by created_at,id', (owner,))
    review_revisions = sorted(str(r['id']) for r in reviews)
    detections = self.rows('select * from event_detections where user_id=%s', (owner,))
    withdrawn = {str(r['body'].get('reviewId', '')).lower() for r in reviews if r['body'].get('action') == 'withdraw'}
    negatives = []
    for r in reviews:
      b = r['body']
      if str(r['id']).lower() in withdrawn or str(b.get('typeId', '')).lower() != typ:
        continue
      if b.get('action') == 'negative' and device and str(b.get('deviceId', '')).lower() == device:
        negatives.append((float(b['start']), float(b['end']), r['created_at'].timestamp()))
    on_device = lambda d: device is not None and str(d['device_id']) == device
    mine_det = [d for d in detections if str(d['type_id']).lower() == typ and on_device(d)]
    span = lambda d: (float(d['start_at']), float(d['end_at']), d['updated_at'].timestamp())
    rejected = sorted(span(d) for d in mine_det if d['status'] == 'rejected')
    confirmed = sorted(span(d) for d in mine_det if d['status'] == 'confirmed')
    unreviewed = sorted(span(d) for d in detections if d['status'] == 'pending' and on_device(d))
    negatives.sort()

    first = min([e.start for e in this_type] + [sp[0] for sp in observations] + [sp[0] for sp in negatives], default=None)
    lo = max((now if first is None else first) - LOOKBACK_S, now - MAX_SPAN_S)
    keep = lambda spans: [sp for sp in spans if sp[1] > lo]
    tz = _tz_offset([e['entry'].get('timeZoneIdentifier') for e in mine], now)
    from .report import ENGINE_VERSION
    fingerprint = self.stream_fingerprint(owner, device, int(lo), int(now)) if device else None
    snapshot = hashlib.sha256(json.dumps([str(owner), typ, device, tz, int(lo), fingerprint, manual_revisions,
                                          review_revisions, ENGINE_VERSION, normalization],
                                         sort_keys=True).encode()).hexdigest()
    base = dict(device=device, tz_offset_s=tz, span=(lo, now), snapshot=snapshot, fingerprint=fingerprint,
                manualRevisions=manual_revisions, reviewRevisions=review_revisions)
    if previous_snapshot is not None and previous_snapshot == snapshot:
      return dict(base, unchanged=True)
    timeline = load_postgres(self, owner, device, lo, now, tz) if device else None
    evidence = Evidence(type_id=typ, events=[e for e in this_type if e.start >= lo],
                        other_events=[e for e in other if e.end > lo], observations=keep(observations),
                        negatives=keep(negatives), rejected=keep(rejected), positive_reviews=keep(confirmed),
                        unreviewed=keep(unreviewed), confirmed_detections=len(confirmed),
                        rejected_detections=len(rejected), owner=str(owner))
    return dict(base, evidence=evidence, timeline=timeline, unchanged=False)


def _archived(entry):
  v = entry.get('archived')
  return v is True or str(v).lower() == 'true'


def _num(v):
  try:
    x = float(v)
  except (TypeError, ValueError):
    return None
  return x if x == x else None


def _tz_offset(names, at):
  """Fixed UTC offset (seconds) of the most common time zone of the type's logs at `at`. DST changes inside the
  analysed span are ignored (local days may shift by an hour across a change)."""
  names = [n for n in names if n]
  if not names:
    return 0
  name = collections.Counter(names).most_common(1)[0][0]
  try:
    from zoneinfo import ZoneInfo
    off = datetime.fromtimestamp(at, ZoneInfo(name)).utcoffset()
    return int(off.total_seconds()) if off is not None else 0
  except Exception:
    return 0


def valid_uuid(value):
  try: uuid.UUID(value); return True
  except (ValueError, TypeError, AttributeError): return False
