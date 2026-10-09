"""Private worker database adapter. Every data query includes the credential-derived owner."""
from contextlib import contextmanager
from datetime import datetime,timezone
import hashlib
import json
import uuid
import numpy as np
from .data import windows,label_windows,snapshot_id


class Database:
    def __init__(self,dsn):
        import psycopg
        from psycopg.rows import dict_row
        self.conn=psycopg.connect(dsn,autocommit=True,row_factory=dict_row)
        self.conn.execute("set statement_timeout='30s'")
        self.conn.execute("set lock_timeout='3s'")
    def rows(self,sql,args=()): return self.conn.execute(sql,args).fetchall()
    def row(self,sql,args=()): return self.conn.execute(sql,args).fetchone()
    def execute(self,sql,args=()): return self.conn.execute(sql,args)
    def schedule(self):
        self.execute("""insert into event_detector_jobs(user_id,type_id,kind)
            select s.user_id,s.type_id,k from event_detector_settings s
            cross join (values ('train'),('infer')) v(k) where s.enabled
            on conflict(user_id,type_id,kind) do nothing""")
    def claim(self,kind):
        with self.conn.transaction():
            job=self.row("""select j.* from event_detector_jobs j join event_detector_settings s using(user_id,type_id)
                where j.kind=%s and s.enabled and j.due_at<=now() and (j.lease_until is null or j.lease_until<now())
                  and (j.kind='train' or s.active_model_id is not null)
                order by j.due_at,j.user_id,j.type_id for update of j skip locked limit 1""",(kind,))
            if not job: return None
            setting=self.row("select * from event_detector_settings where user_id=%s and type_id=%s",(job['user_id'],job['type_id']))
            token=uuid.uuid4()
            self.execute("""update event_detector_jobs set lease_token=%s,lease_until=now()+interval '5 minutes',
                settings_revision=%s,attempts=attempts+1 where user_id=%s and type_id=%s and kind=%s""",
                (token,setting['revision'],job['user_id'],job['type_id'],kind))
            return dict(job,token=token,setting=setting)
    @contextmanager
    def fenced(self,job):
        with self.conn.transaction():
            setting=self.row("select * from event_detector_settings where user_id=%s and type_id=%s for update",(job['user_id'],job['type_id']))
            claim=self.row("select * from event_detector_jobs where user_id=%s and type_id=%s and kind=%s for update",(job['user_id'],job['type_id'],job['kind']))
            if (not setting or not setting['enabled'] or setting['revision']!=job['setting']['revision'] or not claim
                or claim['lease_token']!=job['token'] or claim['lease_until']<=datetime.now(timezone.utc)):
                raise InterruptedError('Job fenced by account, setting or lease change')
            yield setting
    def heartbeat(self,job):
        with self.fenced(job):
            self.execute("update event_detector_jobs set lease_until=now()+interval '5 minutes' where lease_token=%s",(job['token'],))
    def finish(self,job,seconds):
        with self.fenced(job):
            self.execute("""update event_detector_jobs set lease_token=null,lease_until=null,
                due_at=now()+%s*interval '1 second',attempts=0 where lease_token=%s""",(seconds,job['token']))
    def retry(self,job):
        # A revoked/replaced claim cannot change the replacement job's due time.
        self.execute("""update event_detector_jobs set lease_token=null,lease_until=null,
            due_at=now()+%s*interval '1 second' where lease_token=%s""",(min(3600,30*2**min(job['attempts'],7)),job['token']))
    def sensor_windows(self,owner,device,start,end):
        if end-start>86400*91: raise ValueError('Window exceeds dataset budget')
        limit=1_000_000
        heart=self.rows("select ts,bpm from noop_hr_samples where user_id=%s and device_id=%s and ts>=%s and ts<%s order by ts limit %s",(owner,device,start-32,end,limit+1))
        temperature=self.rows("select ts,raw from noop_skin_temp_samples where user_id=%s and device_id=%s and ts>=%s and ts<%s order by ts limit %s",(owner,device,start-32,end,limit+1))
        if max(len(heart),len(temperature))>limit: raise ValueError('Dataset sensor budget exceeded; use a shorter reviewed range')
        return windows([(r['ts'],r['bpm']) for r in heart],[(r['ts'],r['raw']) for r in temperature],start=start,end=end)
    def dataset(self,job):
        owner,typ=job['user_id'],job['type_id']
        entries=self.rows("""select entry,revision_id,received_at from manual_events_current where user_id=%s
            and entry->>'kind'='event' and (entry->>'typeId')::uuid=%s and not (entry->>'archived')::boolean
            and entry->>'endUnixSeconds' is not null""",(owner,typ))
        reviews=self.rows("select id,body,created_at from event_detection_reviews where user_id=%s order by created_at,id",(owner,))
        devices={e['entry'].get('deviceId') for e in entries if e['entry'].get('deviceId')}
        # A model trains and serves on a specified sensor source; never silently mix straps.
        devices={d for d in devices if valid_uuid(d)}
        if not devices: raise ValueError('Log completed events with a cloud-linked wearable first.')
        device=max(sorted(devices),key=lambda d:sum(e['entry'].get('deviceId')==d for e in entries))
        positive=[dict(id=e['entry']['id'],start=e['entry']['startUnixSeconds'],end=e['entry']['endUnixSeconds'])
                  for e in entries if e['entry'].get('deviceId')==device]
        detections={str(r['id']):r for r in self.rows('select * from event_detections where user_id=%s',(owner,))}
        latest={}
        for r in reviews:
            b=r['body']; latest[b.get('detectionId',str(r['id']))]=b
        negative=[]
        for b in latest.values():
            if b.get('typeId','').lower()!=str(typ): continue
            if b.get('action')=='negative' and b.get('deviceId','').lower()==device.lower(): negative.append((b['start'],b['end']))
            if b.get('outcome')=='rejected':
                d=detections.get(b.get('detectionId'))
                if d and str(d['device_id'])==device.lower() and d['status']=='rejected': negative.append((b['start'],b['end']))
        if not positive or not negative: raise ValueError('Add confirmed events and reviewed negative time for this wearable.')
        lo=min([e['start'] for e in positive]+[a for a,b in negative]); hi=max([e['end'] for e in positive]+[b for a,b in negative])
        cutoff=max(lo,hi-90*86400)
        positive=[e for e in positive if e['start']>=cutoff]; negative=[(max(a,cutoff),b) for a,b in negative if b>cutoff]
        times,raw=self.sensor_windows(owner,device,cutoff,hi)
        labels=label_windows(times,positive,negative)
        revisions=[(str(e['revision_id']),str(e['received_at'])) for e in entries]+[(str(r['id']),str(r['created_at'])) for r in reviews]
        snapshot=snapshot_id(owner,typ,device,times,raw,labels,revisions)
        return dict(times=times,raw=raw,labels=labels,positives=positive,negatives=negative,
                    snapshot=snapshot,device=device,labelRevisions=revisions,
                    manualRevisions=sorted(str(e['revision_id']) for e in entries),
                    reviewRevisions=sorted(str(r['id']) for r in reviews))


def valid_uuid(value):
    try: uuid.UUID(value); return True
    except (ValueError,TypeError,AttributeError): return False
