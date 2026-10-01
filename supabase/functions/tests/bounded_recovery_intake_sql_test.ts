import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { recoveryPoll } from '../_shared/boundedRecovery.ts';
import { sha256Hex } from '../_shared/s3.ts';
import { startObjectHttp } from './local_objects.ts';
import { recoverySqlFixture } from './recovery_sql_fixture.ts';

const database=Deno.env.get('BOUNDED_RECOVERY_TEST_DATABASE_URL');
async function withFixture(check:(fixture:any)=>Promise<void>) {
  const {sql,rest,literal}=recoverySqlFixture(database!);
  const owner=crypto.randomUUID(),device=crypto.randomUUID(),source=crypto.randomUUID(),run=crypto.randomUUID(),instance=crypto.randomUUID(),
    scoringInstance=crypto.randomUUID(),supervisor=crypto.randomUUID(),batch=crypto.randomUUID();
  const header={type:'batch',protocolVersion:'1.1',stream:'hrSample',deviceId:device,sourceId:source,batchId:batch,delivery:'append',recordCount:1,
    endCursor:{rowId:1,keySha256:'a'.repeat(64)}};
  const body=new TextEncoder().encode([header,{type:'record',key:{ts:1790000000},data:{bpm:74}}].map(x=>JSON.stringify(x)).join('\n')+'\n');
  const wire=new Uint8Array(gzipSync(body));
  const bucket=startObjectHttp({versioned:true,chunkBytes:17});
  const key=`synthetic-recovery/users/${owner}/devices/${device}/${batch}.ndjson.gz`;
  let runCreated=false;
  try {
    await sql(`insert into auth.users(id) values(${literal(owner)});insert into devices(id,user_id,source_kind) values(${literal(device)},${literal(owner)},'noop_push');
      update noop_recovery_database_identity set project_ref='abcdefghijklmnopqrst';
      insert into noop_recovery_runs(id,user_id,device_id,project_ref,source_revision,policy_hash,intake_image,scoring_image,intake_instance,scoring_instance,
        supervisor_token,expires_at,maximum_expires_at,intake_container,scoring_container)
      values(${literal(run)},${literal(owner)},${literal(device)},'abcdefghijklmnopqrst',repeat('a',40),repeat('b',64),'sha256:'||repeat('c',64),
        'sha256:'||repeat('d',64),${literal(instance)},${literal(scoringInstance)},${literal(supervisor)},clock_timestamp()+interval '10 minutes',
        clock_timestamp()+interval '1 hour',repeat('c',64),repeat('d',64));`);
    runCreated=true;
    await rest.rpc('noop_recovery_supervise',{p_run:run,p_supervisor:supervisor,p_policy_hash:'b'.repeat(64),p_observation:{
      intake_container:'c'.repeat(64),scoring_container:'d'.repeat(64),intake_image:'sha256:'+'c'.repeat(64),scoring_image:'sha256:'+'d'.repeat(64),
      source_revision:'a'.repeat(40),resources_healthy:true,captured_at:new Date().toISOString()}});
    const row={id:batch,user_id:owner,device_id:device,object_class:'raw',object_kind:'hrSample',provider:'b2',bucket:'fixture',object_key:key,
      start_at:new Date(1790000000*1000).toISOString(),end_at:new Date(1790000000*1000).toISOString(),period_day:'2026-09-21',
      sample_count:1,compressed_bytes:wire.length,uncompressed_bytes:body.length,content_type:'application/x-ndjson',format:'ndjson_gzip_noop_push_v1',
      compression:'gzip',schema_version:1,sha256:sha256Hex(wire),digest_scope:'wire',sha256_source:'server_verified',retention_class:'raw',
      source_id:source,batch_id:batch,auth_mode:'legacy_fleet',status:'pending',push_protocol_version:'1.1'};
    await rest.rpc('noop_reserve_push_batch',{p_user_id:owner,p_batch_id:batch,p_device_id:device,p_body_sha256:sha256Hex(body),
      p_entry:{...header,canonicalDeviceId:device,bodySha256:sha256Hex(body)}});
    await rest.rpc('noop_reserve_object_manifest',{p_manifest:row});
    await bucket.raw.putObject(key,wire);
    const databaseId=await sql('select database_id from noop_recovery_database_identity');
    const identity={processId:crypto.randomUUID(),instanceId:instance,sourceRevision:'a'.repeat(40),admission:{mode:'bounded-recovery' as const,
      ownerId:owner,deviceId:device,runId:run,imageDigest:'sha256:'+'c'.repeat(64),policyHash:'b'.repeat(64),projectRef:'abcdefghijklmnopqrst',databaseId}};
    await check({sql,rest,literal,owner,device,run,instance,supervisor,batch,body,wire,bucket,identity});
  } finally {
    await bucket.close();
    if(runCreated)await rest.rpc('noop_recovery_confirm_stopped',{p_run:run,p_supervisor:supervisor,p_instance:instance,p_container:'c'.repeat(64)});
  }
}

Deno.test({name:'recovery uses actual COPY/hash/receipt SQL then scoped scalar projection after lost receipt response',
  ignore:!database,fn:()=>withFixture(async({sql,rest,literal,owner,device,run,batch,body,wire,bucket,identity})=>{
    let dropped=false;
    const lostResponse={...rest,rpc:async(name:string,args:any)=>{
      const result=await rest.rpc(name,args);
      if(!dropped&&name==='noop_recovery_intake_call'&&args.p_operation==='noop_intake_canary_commit_receipt'){
        dropped=true;throw new Error('synthetic connection lost after committed receipt');
      }return result;
    }};
    await assert.rejects(()=>recoveryPoll(lostResponse,bucket.raw,identity,'legacy'),/recovery_lease_lost/);
    assert(dropped,'actual receipt boundary was not exercised');
    const receipt=JSON.parse(await sql(`select durability_receipt from object_manifests where id=${literal(batch)}`));
    assert.equal(receipt.state,'verified_indexed');assert.equal(receipt.contentSha256,sha256Hex(body));assert.equal(receipt.wireSha256,sha256Hex(wire));
    assert.equal(await sql(`select count(*) from noop_recovery_attempts where run_id=${literal(run)} and released_at is null`),'0');
    assert.equal(await sql(`select count(*) from noop_hr_samples where user_id=${literal(owner)}`),'0','receipt alone fabricated scalar projection');
    const projected=await recoveryPoll(rest,bucket.raw,{...identity,processId:crypto.randomUUID()},'projection');
    assert.equal(projected.completed,1);
    assert.equal(await sql(`select bpm from noop_hr_samples where user_id=${literal(owner)} and device_id=${literal(device)} and ts=1790000000`),'74');
    assert.equal(await sql(`select state from noop_projection_debt where object_id=${literal(batch)}`),'complete');
    assert.equal((await recoveryPoll(rest,bucket.raw,identity,'legacy')).claimed,0);
    assert.equal((await recoveryPoll(rest,bucket.raw,identity,'projection')).claimed,0);
    assert.deepEqual(JSON.parse(await sql(`select durability_receipt from object_manifests where id=${literal(batch)}`)),receipt,'receipt identity changed on replay');
    console.log('Synthetic local COPY/hash/immutable receipt → durable projection verified; no physiological result inserted.');
})});

for(const boundary of ['claim','verified','receipt','projection'])Deno.test({
  name:`actual SIGKILL at ${boundary} preserves debt and resumes through production intake SQL`,ignore:!database,
  fn:()=>withFixture(async({sql,rest,literal,owner,device,run,instance,supervisor,batch,bucket,identity})=>{
    if(boundary==='projection')assert.equal((await recoveryPoll(rest,bucket.raw,identity,'legacy')).completed,1);
    const child=new Deno.Command(Deno.execPath(),{args:['run','--cached-only','--allow-env','--allow-read',
      '--allow-run=/opt/homebrew/bin/docker,/opt/homebrew/bin/psql','--allow-net=127.0.0.1',
      '--lock=supabase/functions/deno.lock',new URL('./bounded_recovery_intake_child.ts',import.meta.url).href],
      env:{BOUNDED_RECOVERY_CHILD:JSON.stringify({boundary,identity,endpoint:bucket.raw.endpoint})},stdout:'piped',stderr:'piped'}).spawn();
    const reader=child.stdout.getReader();
    let timer:ReturnType<typeof setTimeout>|undefined;
    let killed=false;
    try {
      const reached=await Promise.race([reader.read(),new Promise<never>((_,reject)=>{timer=setTimeout(()=>reject(new Error('child boundary timeout')),15000);})]);
      assert(!reached.done,'child exited before durable boundary');
      assert.equal(new TextDecoder().decode(reached.value).trim(),`BOUNDARY:${boundary}`);
      child.kill('SIGKILL');killed=true;
      assert.equal((await child.status).signal,'SIGKILL');
    } finally {
      if(timer!==undefined)clearTimeout(timer);
      if(!killed){try{child.kill('SIGKILL');}catch{/* already stopped */}await child.status;}
      await reader.cancel();reader.releaseLock();
      const errors=await new Response(child.stderr).text();if(errors)console.log(errors);
    }
    const unresolved=boundary==='claim'||boundary==='verified';
    assert.equal(await sql(`select count(*) from noop_recovery_attempts where run_id=${literal(run)} and released_at is null`),unresolved?'1':'0');
    assert.equal(await sql(`select count(*) from object_manifests where id=${literal(batch)} and durability_receipt->>'state'='verified_indexed'`),unresolved?'0':'1');
    assert.equal(await sql(`select count(*) from noop_hr_samples where user_id=${literal(owner)}`),boundary==='projection'?'1':'0');
    // Database supervisor attestation is made only after the OS confirmed this
    // exact child died. Docker/cgroup attestation remains the guard's separate test.
    await rest.rpc('noop_recovery_confirm_stopped',{p_run:run,p_supervisor:supervisor,p_instance:instance,p_container:'c'.repeat(64)});
    assert.equal(await sql(`select count(*) from noop_recovery_attempts where run_id=${literal(run)} and released_at is null`),'0');
    await assert.rejects(()=>recoveryPoll(rest,bucket.raw,identity,'legacy'),/recovery_run_expired_or_target_mismatch/);
    const nextRun=crypto.randomUUID(),nextInstance=crypto.randomUUID(),nextSupervisor=crypto.randomUUID();
    await sql(`insert into noop_recovery_runs select (jsonb_populate_record(null::noop_recovery_runs,to_jsonb(r)||jsonb_build_object(
      'id',${literal(nextRun)},'intake_instance',${literal(nextInstance)},'supervisor_token',${literal(nextSupervisor)},
      'state','active','observed_at',null,'created_at',clock_timestamp(),'expires_at',clock_timestamp()+interval '10 minutes'))).* 
      from noop_recovery_runs r where id=${literal(run)}`);
    const resumed={...identity,processId:crypto.randomUUID(),instanceId:nextInstance,admission:{...identity.admission,runId:nextRun}};
    try {
      await rest.rpc('noop_recovery_supervise',{p_run:nextRun,p_supervisor:nextSupervisor,p_policy_hash:'b'.repeat(64),p_observation:{
        intake_container:'c'.repeat(64),scoring_container:'d'.repeat(64),intake_image:'sha256:'+'c'.repeat(64),scoring_image:'sha256:'+'d'.repeat(64),
        source_revision:'a'.repeat(40),resources_healthy:true,captured_at:new Date().toISOString()}});
      if(boundary==='verified') {
        assert.equal((await recoveryPoll(rest,bucket.raw,resumed,'legacy')).claimed,0,'unexpired old copy intent must remain fenced');
        // Explicit SQL clock injection: avoid a ten-minute wall-clock fixture.
        // Only the existing copy-intent timeout is advanced; raw bytes stay intact.
        await sql(`update noop_object_copy_intents set lease_until=clock_timestamp()-interval '1 second' where object_id=${literal(batch)}`);
      }
      if(unresolved)assert.equal((await recoveryPoll(rest,bucket.raw,resumed,'legacy')).completed,1);
      if(boundary!=='projection')assert.equal((await recoveryPoll(rest,bucket.raw,resumed,'projection')).completed,1);
      assert.equal((await recoveryPoll(rest,bucket.raw,resumed,'projection')).claimed,0);
      assert.equal(await sql(`select bpm from noop_hr_samples where user_id=${literal(owner)} and device_id=${literal(device)}`),'74');
      assert.equal(await sql(`select state from noop_projection_debt where object_id=${literal(batch)}`),'complete');
      assert.equal(await sql(`select count(*) from object_manifests where id=${literal(batch)}`),'1');
      console.log(JSON.stringify({boundary,actualProcessSignal:'SIGKILL',durableReservationRetainedUntilStop:unresolved,
        receiptBeforeRestart:!unresolved,projectionBeforeRestart:boundary==='projection',copyIntentClockInjected:boundary==='verified',recovery:'complete'}));
    } finally {
      await rest.rpc('noop_recovery_confirm_stopped',{p_run:nextRun,p_supervisor:nextSupervisor,p_instance:nextInstance,p_container:'c'.repeat(64)});
    }
  })
});
