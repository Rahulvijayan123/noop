"""Opt-in integration tests against the isolated local fixture, never a production DSN."""
import json
import os
import unittest
import uuid
import numpy as np
from personal_events.models import Detector
from personal_events.policy import Policy
from personal_events.training import pack
from personal_events.worker import inference_job
from personal_events.database import Database

DSN=os.environ.get('NARA_EVENT_TEST_DSN')


@unittest.skipUnless(DSN and ('127.0.0.1' in DSN or 'localhost' in DSN),'local fixture DSN required')
class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.db=Database(DSN); self.owner=uuid.uuid4(); self.other=uuid.uuid4(); self.source=uuid.uuid4(); self.typ=uuid.uuid4(); self.device=uuid.uuid4()
        for owner in [self.owner,self.other]: self.db.execute('insert into auth.users(id) values(%s)',(owner,))
        self.db.execute('insert into noop_app_installations(user_id,source_id) values(%s,%s)',(self.owner,self.source))
        self.type_entry=dict(id=str(self.typ),kind='event_type',label='Walking',symbol='figure.walk',favorite=False,timeZoneIdentifier='UTC',archived=False)
        self.append(self.type_entry)
    def tearDown(self):
        self.db.execute('delete from auth.users where id in (%s,%s)',(self.owner,self.other));self.db.conn.close()
    def append(self,entry,stamp=1000):
        revision=dict(revision_id=str(uuid.uuid4()),updated_at_ms=stamp,entry=entry)
        return self.db.row('select append_manual_event_revisions(%s,%s,%s::jsonb) r',(self.owner,self.source,json.dumps([revision])))['r']
    def command(self,**body):
        body=dict(requestId=str(uuid.uuid4()),typeId=str(self.typ),**body)
        return self.db.row('select event_detection_command(%s,%s,%s::jsonb) r',(self.owner,self.source,json.dumps(body)))['r']
    def test_off_and_archive_fence_claims_and_retains_data(self):
        self.command(action='setting',enabled=True);self.db.schedule();job=self.db.claim('train')
        self.assertIsNotNone(job)
        self.command(action='setting',enabled=False)
        with self.assertRaises(InterruptedError):
            with self.db.fenced(job): self.fail('disabled job published')
        self.command(action='setting',enabled=True);job=self.db.claim('train')
        self.append(dict(self.type_entry,archived=True,archivedAt=2000),2000)
        with self.assertRaises(InterruptedError):
            with self.db.fenced(job): self.fail('archived type published')
        self.assertEqual(self.db.row('select count(*) n from manual_event_revisions where user_id=%s',(self.owner,))['n'],2)
    def test_retry_confirmation_rename_and_foreign_owner(self):
        self.command(action='setting',enabled=True)
        eid=uuid.uuid4()
        self.db.execute('insert into event_detections(user_id,id,type_id,device_id,start_at,end_at,model_id) values(%s,%s,%s,%s,100,200,%s)',(self.owner,eid,self.typ,self.device,uuid.uuid4()))
        self.command(action='review',detectionId=str(eid),outcome='confirmed',start=100,end=200)
        self.command(action='review',detectionId=str(eid),outcome='confirmed',start=100,end=200)
        self.assertEqual(self.db.row("select count(*) n from manual_events_current where user_id=%s and entry->>'kind'='event'",(self.owner,))['n'],1)
        self.append(dict(self.type_entry,label='Walking outside'),3000)
        self.assertEqual(self.db.row('select type_id from event_detector_settings where user_id=%s',(self.owner,))['type_id'],self.typ)
        with self.assertRaises(Exception):
            self.db.row('select event_detection_command(%s,%s,%s::jsonb)',(self.other,self.source,json.dumps(dict(action='setting',requestId=str(uuid.uuid4()),typeId=str(self.typ),enabled=True))))
    def test_sensor_invalidations_and_private_artifacts(self):
        self.command(action='setting',enabled=True)
        self.db.execute('insert into noop_hr_samples values(%s,%s,100,70),(%s,%s,101,71)',(self.owner,self.device,self.owner,self.device))
        row=self.db.row('select * from event_detection_inputs where user_id=%s',(self.owner,));self.assertEqual(row['revision'],1)
        self.db.execute('insert into noop_hr_samples values(%s,%s,102,72)',(self.owner,self.device))
        self.assertEqual(self.db.row('select revision from event_detection_inputs where user_id=%s',(self.owner,))['revision'],2)
        self.db.execute('set role authenticated')
        try:
            for table in ['event_detector_models','event_detector_jobs','event_detection_reviews']:
                with self.assertRaises(Exception): self.db.rows('select * from '+table)
        finally: self.db.execute('reset role')
    def test_physiology_does_not_leak_foreign_device_or_bridge_missing_samples(self):
        self.db.execute('insert into noop_hr_samples values(%s,%s,100,70),(%s,%s,500,90)',(self.owner,self.device,self.owner,self.device))
        self.db.execute('insert into server_metric_series values(%s,%s,\'hrv_rmssd_ms\',to_timestamp(100),300,45)',(self.owner,self.device))
        r=self.db.row('select event_physiology(%s,%s,0,600) r',(self.owner,self.device))['r']
        self.assertEqual(len(r['heartRate']),2);self.assertEqual(r['hrv'][0]['support'],300)
        r=self.db.row('select event_physiology(%s,%s,0,600) r',(self.other,self.device))['r']
        self.assertEqual(r['heartRate'],[]);self.assertEqual(r['hrv'],[])
    def test_upload_to_detection_replay_disable_and_model_swap(self):
        self.command(action='setting',enabled=True)
        raw=np.zeros((20,2,2,16),dtype='float32');raw[:10,:,1,:]=60;raw[10:,:,1,:]=140
        model=Detector(dict(groups=['cardiac'],head='ridge')).fit(raw,np.r_[np.zeros(10),np.ones(10)])
        model.policy=Policy(); mid=uuid.uuid4()
        manifest=json.dumps(dict(device=str(self.device)))
        self.db.execute('insert into event_detector_models(user_id,type_id,id,manifest,artifact) values(%s,%s,%s,%s::jsonb,%s)',(self.owner,self.typ,mid,manifest,pack(model)))
        self.db.execute("update event_detector_settings set active_model_id=%s where user_id=%s and type_id=%s",(mid,self.owner,self.typ))
        import time
        lo=int(time.time())//86400*86400
        self.db.execute('insert into noop_hr_samples select %s,%s,t,case when t between %s and %s then 140 else 60 end from generate_series(%s::bigint,%s::bigint) t',
            (self.owner,self.device,lo+400,lo+800,lo,lo+1200))
        self.db.schedule(); job=self.db.claim('infer')
        class Heartbeat:
            def check(self): pass
        inference_job(self.db,job,Heartbeat())
        before=self.db.rows('select * from event_detections where user_id=%s',(self.owner,))
        self.assertEqual(len(before),1)
        inference_job(self.db,job,Heartbeat())
        self.assertEqual(self.db.row('select count(*) n from event_detections where user_id=%s',(self.owner,))['n'],1)
        # Late upload dirties the same day; replay still updates the same episode.
        self.db.execute('insert into noop_hr_samples values(%s,%s,%s,60)',(self.owner,self.device,lo+1300))
        inference_job(self.db,job,Heartbeat())
        self.assertEqual(self.db.row('select id from event_detections where user_id=%s',(self.owner,))['id'],before[0]['id'])
        self.command(action='setting',enabled=False)
        with self.assertRaises(InterruptedError): inference_job(self.db,job,Heartbeat())
        self.assertEqual(self.db.row('select count(*) n from event_detections where user_id=%s',(self.owner,))['n'],1)


if __name__=='__main__': unittest.main()
