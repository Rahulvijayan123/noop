"""Two independently supervised lanes: weekly training and incremental upload-driven detection."""
import argparse
from dataclasses import asdict
from datetime import datetime,timezone
import json
import logging
import os
from pathlib import Path
import threading
import time
import uuid
import hashlib
import shutil
from importlib.metadata import version as package_version,PackageNotFoundError
import numpy as np
from .database import Database
from .policy import EpisodeState,Policy
from .training import pack,unpack,train
from .models import REGISTRY_VERSION

LOG=logging.getLogger('nara.events')


def clean_deleted_accounts(db,cache):
    """Private caches share the database's whole-account deletion lifecycle."""
    if not cache.exists(): return
    owners={str(row['user_id']) for row in db.rows('select distinct user_id from event_detector_settings')}
    for child in cache.iterdir():
        try: owner=str(uuid.UUID(child.name))
        except ValueError: continue
        if owner not in owners and child.is_dir() and not child.is_symlink(): shutil.rmtree(child)


class LeaseHeartbeat:
    def __init__(self,dsn,job): self.dsn=dsn; self.job=job; self.stop=threading.Event(); self.error=None
    def __enter__(self):
        def run():
            db=Database(self.dsn)
            try:
                while not self.stop.wait(30): db.heartbeat(self.job)
            except Exception as error: self.error=error
            finally: db.conn.close()
        self.thread=threading.Thread(target=run,daemon=True); self.thread.start(); return self
    def check(self):
        if self.error: raise InterruptedError('Lease renewal failed') from self.error
    def __exit__(self,*_): self.stop.set(); self.thread.join(timeout=5)


def training_job(db,job,cache,config,heartbeat):
    owner,typ=job['user_id'],job['type_id']
    with db.fenced(job):
        db.execute("update event_detector_settings set state='training' where user_id=%s and type_id=%s",(owner,typ))
    try: data=db.dataset(job)
    except ValueError as error:
        with db.fenced(job) as setting:
            db.execute("""update event_detector_settings set state=%s,detail=%s::jsonb,last_training_at=now()
                where user_id=%s and type_id=%s""",('active' if setting['active_model_id'] else 'needs_examples',json.dumps(dict(reason=str(error))),owner,typ))
        return
    versions={}
    for package in ('numpy','scipy','scikit-learn','torch','pycatch22','numba','xlstm','xgboost','catboost'):
        try: versions[package]=package_version(package)
        except PackageNotFoundError: versions[package]='not installed'
    data['snapshot']=hashlib.sha256(json.dumps([data['snapshot'],REGISTRY_VERSION,config,asdict(Policy()),versions],sort_keys=True).encode()).hexdigest()
    previous=db.row("select snapshot,report from event_detector_runs where user_id=%s and type_id=%s order by created_at desc limit 1",(owner,typ))
    if previous and previous['snapshot']==data['snapshot']:
        with db.fenced(job) as setting:
            db.execute("update event_detector_settings set state=%s where user_id=%s and type_id=%s",('active' if setting['active_model_id'] else 'needs_examples',owner,typ))
        return
    current=db.row("select artifact,manifest from event_detector_models where user_id=%s and id=%s",(owner,job['setting']['active_model_id']))
    incumbent=unpack(current['artifact']) if current and current['manifest']['device']==data['device'] else None
    history=db.row("select max((report->>'testEnd')::double precision) t from event_detector_runs where user_id=%s and type_id=%s",(owner,typ))
    run_root=cache/str(owner)/str(typ)
    try:
        model,report=train(**{k:data[k] for k in ('times','raw','labels','positives','negatives','snapshot')},
            cache=run_root,config=config,current=incumbent,previous_test_end=(history or {}).get('t') or 0,
            progress=lambda _:heartbeat.check())
    except ValueError as error:
        with db.fenced(job) as setting:
            db.execute("update event_detector_settings set state=%s,detail=%s::jsonb,last_training_at=now() where user_id=%s and type_id=%s",
                ('active' if setting['active_model_id'] else 'needs_examples',json.dumps(dict(reason=str(error))),owner,typ))
        return
    report.update(device=data['device'],labelRevisions=data['labelRevisions'])
    report['dependencies']=versions
    with db.fenced(job) as setting:
        # Label edits during training must not publish a now-invalid training snapshot.
        revisions=db.rows('select revision_id from manual_events_current where user_id=%s and entry->>\'kind\'=\'event\' and (entry->>\'typeId\')::uuid=%s and not (entry->>\'archived\')::boolean and entry->>\'endUnixSeconds\' is not null',(owner,typ))
        reviews=db.rows('select id from event_detection_reviews where user_id=%s',(owner,))
        if (sorted(str(r['revision_id']) for r in revisions) != data['manualRevisions']
            or sorted(str(r['id']) for r in reviews) != data['reviewRevisions']):
            raise InterruptedError('Labels changed during training; retry the snapshot')
        db.execute('insert into event_detector_runs(user_id,type_id,id,snapshot,report) values(%s,%s,%s,%s,%s::jsonb)',
            (owner,typ,uuid.uuid4(),data['snapshot'],json.dumps(report,allow_nan=False)))
        detail=dict(reason=report['reason'])
        if model:
            version=uuid.uuid4(); manifest=dict(report,modelVersion=str(version))
            db.execute('insert into event_detector_models(user_id,type_id,id,manifest,artifact) values(%s,%s,%s,%s::jsonb,%s)',(owner,typ,version,json.dumps(manifest,allow_nan=False),pack(model)))
            detail.update(report['evaluation']); detail['candidate']=report['candidate']
            db.execute('update event_detector_settings set active_model_id=%s where user_id=%s and type_id=%s',(version,owner,typ))
            # Existing uploads also need a first pass when the initial model becomes available.
            db.execute("""insert into event_detection_inputs(user_id,device_id,day)
                select distinct user_id,device_id,(to_timestamp(ts) at time zone 'UTC')::date from noop_hr_samples
                where user_id=%s and device_id=%s and ts>=%s
                on conflict(user_id,device_id,day) do update set revision=event_detection_inputs.revision+1,updated_at=now()""",
                (owner,data['device'],float(data['times'].min())))
        db.execute("""update event_detector_settings set state=case when active_model_id is null then 'needs_examples' else 'active' end,
            last_training_at=now(),detail=%s::jsonb where user_id=%s and type_id=%s""",(json.dumps(detail),owner,typ))


def inference_job(db,job,heartbeat):
    owner,typ=job['user_id'],job['type_id']; version=job['setting']['active_model_id']
    stored=db.row('select artifact,manifest from event_detector_models where user_id=%s and id=%s',(owner,version))
    if not stored: return
    model=unpack(stored['artifact']); device=stored['manifest']['device']; policy=model.policy
    dirty=db.row("""select i.* from event_detection_inputs i left join event_detection_state s
        on s.user_id=i.user_id and s.type_id=%s and s.device_id=i.device_id and s.day=i.day
        where i.user_id=%s and i.device_id=%s and (s.input_revision is null or s.input_revision<i.revision)
        order by i.updated_at desc limit 1""",(typ,owner,device))
    if not dirty:
        with db.fenced(job):
            db.execute("""update event_detector_settings set state=case when last_input_at>now()-interval '10 minutes' then 'active' else 'waiting' end
                where user_id=%s and type_id=%s""",(owner,typ))
        return
    day=dirty['day']; lo=datetime.combine(day,datetime.min.time(),tzinfo=timezone.utc).timestamp()
    hi=min(lo+86400,time.time())
    # Replay a dirty day causally. Stable episode IDs plus overlap matching also handle late backfills.
    times,raw=db.sensor_windows(owner,device,lo,hi)
    scores=model.predict(raw); heartbeat.check(); state=EpisodeState(); episodes={}
    for t,score in zip(times,scores):
        episode=state.step(float(t),float(score),owner=str(owner),type_id=str(typ),device=device,model=str(version),policy=policy)
        if episode: episodes[episode['id']]=episode
    with db.fenced(job) as setting:
        if setting['active_model_id']!=version: raise InterruptedError('Selected model changed')
        for episode in episodes.values():
            existing=db.row("""select id,status,start_at,end_at from event_detections where user_id=%s and type_id=%s and device_id=%s
                and start_at<=%s and end_at>=%s order by start_at limit 1 for update""",
                (owner,typ,device,episode['end']+policy.cooldown,episode['start']-policy.cooldown))
            eid=existing['id'] if existing else uuid.UUID(episode['id'])
            db.execute("""insert into event_detections(user_id,id,type_id,device_id,start_at,end_at,model_id,historical)
                values(%s,%s,%s,%s,%s,%s,%s,%s) on conflict(user_id,id) do update
                set end_at=greatest(event_detections.end_at,excluded.end_at),updated_at=now()
                where event_detections.status='pending'""",
                (owner,eid,typ,device,episode['start'],episode['end'],version,episode['detected_at']<time.time()-900))
        db.execute("""insert into event_detection_state(user_id,type_id,device_id,day,input_revision,state)
            values(%s,%s,%s,%s,%s,%s::jsonb) on conflict(user_id,type_id,device_id,day) do update
            set input_revision=excluded.input_revision,state=excluded.state""",(owner,typ,device,day,dirty['revision'],json.dumps(asdict(state))))
        good=times[np.isfinite(scores)]
        last=float(good[-1]) if len(good) else None
        db.execute("""update event_detector_settings set last_input_at=greatest(last_input_at,to_timestamp(%s)),
            state=case when greatest(last_input_at,to_timestamp(%s))>now()-interval '10 minutes' then 'active' else 'waiting' end
            where user_id=%s and type_id=%s""",(last,last,owner,typ))


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--lane',choices=['train','infer'],required=True)
    parser.add_argument('--once',action='store_true'); args=parser.parse_args()
    if os.environ.get('NARA_EVENT_DETECTION_ENABLED')!='1':
        parser.error('Disabled. A maintainer must explicitly enable this service after deployment checks.')
    dsn=os.environ['NARA_EVENT_DATABASE_URL']; cache=Path(os.environ.get('NARA_EVENT_CACHE','/var/lib/nara-events'))
    config=json.loads(Path(os.environ['NARA_EVENT_ENCODERS']).read_text()) if os.environ.get('NARA_EVENT_ENCODERS') else {}
    db=Database(dsn); logging.basicConfig(level=logging.INFO); cleanup_at=0
    while True:
        if time.time()>cleanup_at:
            clean_deleted_accounts(db,cache); cleanup_at=time.time()+3600
        db.schedule(); job=db.claim(args.lane)
        if job:
            try:
                with LeaseHeartbeat(dsn,job) as heartbeat:
                    if args.lane=='train': training_job(db,job,cache,config,heartbeat)
                    else: inference_job(db,job,heartbeat)
                db.finish(job,7*86400 if args.lane=='train' else 15)
            except InterruptedError:
                db.retry(job); LOG.info('Job was fenced; retry scheduled')
            except Exception as error:
                # No credentials, SQL parameters or physiological data in logs.
                try:
                    with db.fenced(job):
                        db.execute("update event_detector_settings set state='paused',detail=%s::jsonb where user_id=%s and type_id=%s",
                            (json.dumps(dict(reason='Worker could not complete this run. It will retry.')),job['user_id'],job['type_id']))
                except Exception: pass
                db.retry(job); LOG.error('Job failed: %s',type(error).__name__)
        if args.once: break
        time.sleep(1 if job else 15)


if __name__=='__main__': main()
