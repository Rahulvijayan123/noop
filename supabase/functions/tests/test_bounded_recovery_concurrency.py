#!/usr/bin/env python3
"""Actual concurrent PostgreSQL claims. Only an explicit loopback disposable DB.

Uses synthetic raw identities; creates no physiological result rows. Fixture data
is retained on failure, and deleted by its exact test owners after success.
"""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlparse
import uuid

URL=sys.argv[1]
parsed=urlparse(URL)
assert parsed.hostname=='127.0.0.1' and parsed.path=='/physiology_queue_test' and parsed.username=='postgres'
PSQL='/opt/homebrew/bin/psql'
def sql(text):
    result=subprocess.run([PSQL,URL,'-X','-qAt','-v','ON_ERROR_STOP=1','-c',text],capture_output=True,text=True)
    if result.returncode:raise RuntimeError(result.stderr)
    return result.stdout.strip()

fixture=Path(__file__).with_name('bounded_recovery.sql').read_text().split('do $$')[0]
# Different owners avoid interference with the rollback-only admission fixture.
fixture=fixture.replace('a24','c24').replace('b24','d24').replace("array['a','b']","array['c','d']")
sql(fixture+'commit;')
RUN='c2433333-3333-4333-8333-333333333333'
INSTANCE='c2444444-4444-4444-8444-444444444444'
SUPERVISOR='c2466666-6666-4666-8666-666666666666'
def observe(run,supervisor,container):
    return sql(f"select noop_recovery_supervise('{run}','{supervisor}',repeat('b',64),jsonb_build_object('intake_container',repeat('{container}',64),"
        "'scoring_container',repeat('e',64),'intake_image','sha256:'||repeat('c',64),'scoring_image','sha256:'||repeat('d',64),"
        "'source_revision',repeat('a',40),'resources_healthy',true,'captured_at',clock_timestamp()));")
observe(RUN,SUPERVISOR,'c')
def claim(process,run=RUN,instance=INSTANCE,lane='legacy'):
    text=sql(f"select noop_recovery_claim('{run}','{process}','{instance}',repeat('a',40),'sha256:'||repeat('c',64),'{lane}');")
    return json.loads(text) if text else None
processes=[str(uuid.uuid4()) for _ in range(16)]
with ThreadPoolExecutor(max_workers=16) as pool:responses=list(pool.map(claim,processes))
assert sum(x is not None for x in responses)==1,'duplicate processes exceeded single global lane slot'
winner=next((p,r) for p,r in zip(processes,responses) if r)
assert json.loads(sql("select jsonb_build_object('slots',count(*),'wire',sum(wire_bytes),'decoded',sum(decoded_bytes)) from noop_recovery_attempts where released_at is null"))=={'slots':1,'wire':1024,'decoded':2048}
sql(f"select noop_recovery_intake_call('{RUN}','{winner[0]}','{winner[1]['recoveryToken']}','legacy_failure','{{\"reason\":\"b2_transient\",\"retryable\":true}}');")
# A second owner with old debt wins the next turn, even if owner one polls first.
sql("insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,status,sha256_source,sha256,compressed_bytes,uncompressed_bytes) "
    "values('d2477777-7777-4777-8777-000000000001','d2411111-1111-4111-8111-111111111111','d2422222-2222-4222-8222-222222222222',"
    "'ppgWaveformSample','fairness-second-owner','binary',now()-interval '2 days',now()-interval '1 day','pending','client_claimed',repeat('a',64),1024,2048);")
SECOND='d2433333-3333-4333-8333-333333333333';SECOND_INSTANCE='d2444444-4444-4444-8444-444444444444'
observe(SECOND,'d2466666-6666-4666-8666-666666666666','d')
assert claim(str(uuid.uuid4())) is None,'owner one stole the next owner turn'
second_process=str(uuid.uuid4()); second=claim(second_process,SECOND,SECOND_INSTANCE)
assert second and second['manifest']['user_id']=='d2411111-1111-4111-8111-111111111111'
assert claim(str(uuid.uuid4())) is None,'two scope runs doubled the global lane'
sql(f"select noop_recovery_intake_call('{SECOND}','{second_process}','{second['recoveryToken']}','legacy_failure','{{\"reason\":\"corrupt\",\"retryable\":false}}');")
# Poison state is keyed to the object, so a replacement run cannot reset it.
sql(f"select noop_recovery_confirm_stopped('{SECOND}','d2466666-6666-4666-8666-666666666666','{SECOND_INSTANCE}',repeat('d',64));")
replacement=str(uuid.uuid4())
sql(f"insert into noop_recovery_runs select '{replacement}'::uuid,user_id,device_id,project_ref,source_revision,policy_hash,intake_image,scoring_image,"
    "intake_instance,scoring_instance,supervisor_token,clock_timestamp(),clock_timestamp()+interval '8 minutes',clock_timestamp()+interval '1 hour',"
    "null,'active',wire_limit,decoded_limit,intake_container,scoring_container,null,false from noop_recovery_runs where id='"+SECOND+"';")
observe(replacement,'d2466666-6666-4666-8666-666666666666','d')
assert claim(str(uuid.uuid4()),replacement,SECOND_INSTANCE) is None,'new run reset poison quarantine'
assert json.loads(sql(f"select noop_recovery_status('{replacement}')"))['blocked'].get('corrupt')==1,'new run hid retained quarantine debt'
assert sql("select count(*) from object_manifests where user_id='c2411111-1111-4111-8111-111111111111'")=='10000'
# Real parallel scoring/intake transactions contend for the unchanged128MiB
# global budget. Every score reserves112MiB; every retained raw object32MiB.
# Continuous new live objects must not starve history or selected-v1 work.
OWNER='c2411111-1111-4111-8111-111111111111';DEVICE='c2422222-2222-4222-8222-222222222222'
SCORING_INSTANCE='c2455555-5555-4555-8555-555555555555'
sql(f"update object_manifests set uncompressed_bytes=33554432 where user_id='{OWNER}'; "
    f"select scoring_canary_enqueue_legacy('{OWNER}','{DEVICE}',current_date-i,'UTC',0) from generate_series(1,8)i;")
def score(process):
    result=sql(f"begin isolation level repeatable read; create temp table claimed on commit drop as select * from scoring_recovery_claim_one("
        f"'{RUN}','{process}','{SCORING_INSTANCE}',repeat('a',40),'sha256:'||repeat('d',64),40,8,'{OWNER}','{DEVICE}',null); "
        "select scoring_legacy_seal_snapshot(user_id,device_id,day,input_revision,lease_token,run_id) from claimed; "
        "select to_jsonb(c) from claimed c;commit;")
    return json.loads(result) if result else None
def settle_score(process,row):
    assert sql(f"select scoring_recovery_finish_work('{OWNER}','{DEVICE}','{row['day']}',{row['input_revision']},"
        f"'{row['lease_token']}','{row['run_id']}','waiting',1,'synthetic_missing_inputs','{RUN}','{process}')")=='t'
counts={'scoring':0,'intake':0,'history':0,'live':0}
for cycle in range(16):
    observe(RUN,SUPERVISOR,'c')
    oid=str(uuid.uuid4())
    sql(f"insert into object_manifests(id,user_id,device_id,object_kind,object_key,format,start_at,end_at,status,sha256_source,sha256,compressed_bytes,uncompressed_bytes) "
        f"values('{oid}','{OWNER}','{DEVICE}','ppgWaveformSample','continuous-arrival/{oid}','binary',clock_timestamp(),clock_timestamp(),"
        "'pending','client_claimed',repeat('a',64),1024,33554432)")
    intake_process=str(uuid.uuid4());score_process=str(uuid.uuid4())
    with ThreadPoolExecutor(max_workers=2) as pool:
        intake_future=pool.submit(claim,intake_process)
        score_future=pool.submit(score,score_process)
        intake_row=intake_future.result();score_row=score_future.result()
    assert bool(intake_row)!=bool(score_row),'both classes stalled or exceeded shared decoded budget'
    active=json.loads(sql("select jsonb_build_object('slots',count(*),'decoded',sum(decoded_bytes)) from noop_recovery_attempts where released_at is null"))
    assert active=={'slots':1,'decoded':33554432 if intake_row else 117440512},active
    if intake_row:
        counts['intake']+=1
        historical=sql(f"select historical from noop_recovery_attempts where token='{intake_row['recoveryToken']}'")=='t'
        counts['history' if historical else 'live']+=1
        sql(f"select noop_recovery_intake_call('{RUN}','{intake_process}','{intake_row['recoveryToken']}','legacy_failure',"
            "'{\"reason\":\"synthetic_transient\",\"retryable\":true}')")
    else:
        counts['scoring']+=1;settle_score(score_process,score_row)
assert counts['scoring']==8 and counts['intake']==8 and counts['history']>=3 and counts['live']>=3,counts
# Exhausted/poison/oversized intake cannot retain a class turn and deadlock a
# healthy score. All identities remain present; only synthetic retry state changes.
sql(f"insert into noop_recovery_object_state(object_id,lane,run_id,quarantined,reason) select id,'legacy','{RUN}',true,'synthetic_poison' "
    f"from object_manifests where user_id='{OWNER}' on conflict(object_id,lane) do update set quarantined=true; "
    f"select scoring_canary_enqueue_legacy('{OWNER}','{DEVICE}',current_date-9,'UTC',0)")
sql("update object_manifests set compressed_bytes=33554433 where id='c2477777-7777-4777-8777-000000000001'; "
    "update noop_recovery_object_state set quarantined=false,next_attempt_at=clock_timestamp() where object_id='c2477777-7777-4777-8777-000000000001'")
poison_process=str(uuid.uuid4());poison_score=score(poison_process)
assert poison_score,'poison intake blocked eligible score';settle_score(poison_process,poison_score)
# Conversely, no eligible scores means good raw input proceeds immediately.
sql(f"update noop_recovery_object_state set quarantined=false,next_attempt_at=clock_timestamp() where object_id='{oid}'")
last_process=str(uuid.uuid4());last_raw=claim(last_process)
assert last_raw,'waiting scoring work blocked eligible raw input'
sql(f"select noop_recovery_intake_call('{RUN}','{last_process}','{last_raw['recoveryToken']}','legacy_failure',"
    "'{\"reason\":\"synthetic_done\",\"retryable\":false}')")
# A stricter64MiB run cannot ever fit the measured112MiB scoring input. Its
# unclaimable score must therefore not take the class turn away from good raw.
sql(f"update noop_recovery_runs set decoded_limit=67108864 where id='{RUN}'; "
    f"select scoring_canary_enqueue_legacy('{OWNER}','{DEVICE}',current_date-10,'UTC',0); "
    f"update noop_recovery_object_state set quarantined=false,next_attempt_at=clock_timestamp() where object_id='{oid}'")
assert score(str(uuid.uuid4())) is None,'score exceeded stricter run limit'
small_process=str(uuid.uuid4());small_raw=claim(small_process)
assert small_raw,'unclaimable scoring reservation deadlocked stricter run intake'
sql(f"select noop_recovery_intake_call('{RUN}','{small_process}','{small_raw['recoveryToken']}','legacy_failure',"
    "'{\"reason\":\"synthetic_done\",\"retryable\":false}')")
assert sql(f"select count(*) from object_manifests where user_id='{OWNER}'")=='10016'
test_owners="('c2411111-1111-4111-8111-111111111111','d2411111-1111-4111-8111-111111111111')"
sql(f"delete from noop_recovery_runs where user_id in {test_owners}; delete from object_manifests where user_id in {test_owners}; "
    f"delete from devices where user_id in {test_owners}; delete from auth.users where id in {test_owners}")
print('PASS: 16 real concurrent clients, global slot/bytes, cross-owner turn, quarantine survives new run,10000 retained identities')
print('PASS: 16 parallel112MiB score /32MiB raw cycles under128MiB global cap, continuous arrivals, both classes + live/history progress:',counts)
