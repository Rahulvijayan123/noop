import assert from 'node:assert/strict';
import { recoveryPoll, recoveryPreflight } from '../_shared/boundedRecovery.ts';
import { intakeAdmissionFromEnv } from '../_shared/intakeAdmission.ts';
import { verifyStoredObject } from '../_shared/durability.ts';
import { createS3, S3OperationError, sha256Hex } from '../_shared/s3.ts';
import { readVerifiedArchive } from '../_shared/projections.ts';
import { createSupabaseRest, RestAuthorityError } from '../_shared/rest.ts';
import { runIntakeConsumer } from '../_shared/intakeConsumer.ts';
import { gzipSync } from 'node:zlib';

const admission={mode:'bounded-recovery' as const,ownerId:'11111111-1111-4111-8111-111111111111',
  deviceId:'22222222-2222-4222-8222-222222222222',runId:'33333333-3333-4333-8333-333333333333',
  imageDigest:'sha256:'+'a'.repeat(64),policyHash:'b'.repeat(64),projectRef:'abcdefghijklmnopqrst',
  databaseId:'44444444-4444-4444-8444-444444444444'};
const identity={admission,processId:crypto.randomUUID(),instanceId:crypto.randomUUID(),sourceRevision:'c'.repeat(40)};
const manifest={id:crypto.randomUUID(),user_id:admission.ownerId,device_id:admission.deviceId,
  status:'pending',object_key:'fixture/upload',compressed_bytes:100,uncompressed_bytes:200};
const job={manifest,token:crypto.randomUUID(),leaseToken:crypto.randomUUID(),recoveryToken:crypto.randomUUID(),reservedWireBytes:100,reservedDecodedBytes:200};

async function projectionResponseFixture(status: number, errorBody: unknown) {
  const batch=manifest.id, source=crypto.randomUUID();
  const header={type:'batch',protocolVersion:'1.1',stream:'hrSample',deviceId:admission.deviceId,sourceId:source,
    batchId:batch,delivery:'append',recordCount:1,endCursor:{rowId:1,keySha256:'a'.repeat(64)}};
  const body=new TextEncoder().encode([header,{type:'record',key:{ts:1790000000},data:{bpm:74}}].map(x=>JSON.stringify(x)).join('\n')+'\n');
  const wire=new Uint8Array(gzipSync(body));
  const receipt={version:1,state:'verified_indexed',objectKey:'fixture/verified',objectId:batch,batchId:batch,sourceId:source,
    ownerUserId:admission.ownerId,deviceId:admission.deviceId,stream:'hrSample',schemaVersion:1,
    compressedBytes:wire.length,uncompressedBytes:body.length,wireSha256:sha256Hex(wire),contentSha256:sha256Hex(body)};
  const projectionJob={...job,reservedWireBytes:wire.length,reservedDecodedBytes:body.length,
    manifest:{...manifest,object_key:receipt.objectKey,format:'ndjson',compression:'gzip',durability_receipt:receipt}};
  const calls:{name:string;args:any}[]=[];
  const rest=createSupabaseRest({cfg:{supabaseUrl:'https://fixture.invalid',supabaseServiceRoleKey:'synthetic-only'},
    fetchImpl:async(input,options)=>{
      const name=new URL(String(input)).pathname.split('/').at(-1)!;
      const args=JSON.parse(String(options?.body));calls.push({name,args});
      if(name==='noop_recovery_claim')return Response.json(projectionJob);
      if(name==='noop_recovery_intake_call'&&args.p_operation==='noop_intake_canary_commit_projection') {
        return Response.json(errorBody,{status});
      }
      return Response.json(true);
    }});
  return {calls,rest,raw:{getObjectStream:async()=>new Response(wire)} as any};
}

Deno.test('REST recovery RPC path does not turn an ordinary projection 400 into an authority stop',async()=>{
  const fixture=await projectionResponseFixture(400,{code:'P0001',message:'projection_archive_mismatch'});
  const result=await recoveryPoll(fixture.rest,fixture.raw,identity,'projection');
  assert.equal(result.completed,0);assert.equal(result.failures,1);
  assert.deepEqual(fixture.calls.map(x=>x.args.p_operation??x.name),[
    'noop_recovery_claim','noop_intake_canary_commit_projection','noop_fail_projection_debt','noop_recovery_poll']);
  const settlement=fixture.calls[2].args;
  assert.equal(settlement.p_token,job.recoveryToken);
  assert.equal(settlement.p_args.p_object_id,manifest.id);
  assert.equal(fixture.calls[3].args.p_failures,1);
});

Deno.test('structured REST authorization and recovery fences stop without settlement or heartbeat',async()=>{
  for(const [status,errorBody] of [
    [401,{message:'PRIVATE_PROVIDER_RESPONSE'}], [403,{message:'PRIVATE_PROVIDER_RESPONSE'}],
    [403,{code:'42501',message:'intake_admission_scope_mismatch'}],
    [400,{code:'42501',message:'PRIVATE_SQL_RESPONSE'}],
    [400,{code:'P0001',message:'recovery_lease_lost'}],
    [400,{code:'P0001',message:'recovery_supervision_unavailable'}],
    [400,{code:'P0001',message:'recovery_size_limit'}],
  ] as const) {
    const fixture=await projectionResponseFixture(status,errorBody);
    await assert.rejects(()=>recoveryPoll(fixture.rest,fixture.raw,identity,'projection'),
      error=>error instanceof RestAuthorityError&&!String(error).includes('PRIVATE'));
    assert.equal(fixture.calls.length,2,'authority failure settled debt or released reservation');
  }
});

Deno.test('outer lane loop uses typed authority and never classifies endpoint or message substrings',async()=>{
  for(const message of ['projection_archive_mismatch','object 42501 is missing','embedded recovery_lease_lost text']) {
    const rest=createSupabaseRest({cfg:{supabaseUrl:'https://fixture.invalid',supabaseServiceRoleKey:'synthetic-only'},
      fetchImpl:async()=>Response.json({code:'P0001',message},{status:400})});
    let failure:unknown;try{await rest.rpc('noop_recovery_intake_call',{});}catch(error){failure=error;}
    const controller=new AbortController(),events:any[]=[];
    await runIntakeConsumer({preflight:async()=>{},poll:async()=>{throw failure;}},
      {signal:controller.signal,sleep:async()=>{controller.abort();},report:event=>events.push(event)});
    assert(events.length>0);assert(events.every(x=>x.error==='intake_lane_failed'));
    assert(!JSON.stringify(events).includes(message));
  }
  const events:any[]=[];
  await assert.rejects(()=>runIntakeConsumer({preflight:async()=>{},poll:async()=>{throw new RestAuthorityError(403);}},
    {report:event=>events.push(event)}),RestAuthorityError);
  assert(events.every(x=>x.error==='intake_admission_scope_mismatch'));
});

Deno.test('recovery environment requires exact independent database and policy binding',()=>{
  const env={INTAKE_ADMISSION_MODE:'bounded-recovery',INTAKE_CANARY_OWNER_ID:admission.ownerId,
    INTAKE_CANARY_DEVICE_ID:admission.deviceId,INTAKE_RECOVERY_RUN_ID:admission.runId,
    INTAKE_WORKER_IMAGE_DIGEST:admission.imageDigest,INTAKE_RECOVERY_POLICY_HASH:admission.policyHash,
    INTAKE_EXPECTED_SUPABASE_PROJECT:admission.projectRef,INTAKE_EXPECTED_DATABASE_ID:admission.databaseId};
  assert.deepEqual(intakeAdmissionFromEnv(env),admission);
  for(const key of Object.keys(env)) assert.throws(()=>intakeAdmissionFromEnv({...env,[key]:undefined}));
});

Deno.test('recovery preflight rejects another database behind the matching project ref',async()=>{
  const base={owner_id:admission.ownerId,device_id:admission.deviceId,policy_hash:admission.policyHash,
    project_ref:admission.projectRef,database_id:admission.databaseId,algorithm_version:'frwhoop-server-1',
    expires_at:new Date(Date.now()+60000).toISOString()};
  await recoveryPreflight({rpc:async()=>base} as any,identity);
  for(const field of ['owner_id','device_id','policy_hash','project_ref','database_id','algorithm_version','expires_at']) {
    await assert.rejects(()=>recoveryPreflight({rpc:async()=>({...base,[field]:'wrong'})} as any,identity));
  }
});

Deno.test('capacity refusal polls health without reading raw or narrowing debt',async()=>{
  const calls:string[]=[];
  const result=await recoveryPoll({rpc:async(name:string)=>{calls.push(name);return null;}} as any,
    {head:()=>{throw new Error('raw touched');}} as any,identity,'legacy');
  assert.equal(result.claimed,0);assert.equal(result.failures,0);
  assert.deepEqual(calls,['noop_recovery_claim','noop_recovery_poll']);
});

Deno.test('legacy B2 failure retains a per-object retry while successful polling remains healthy',async()=>{
  const calls:any[]=[];
  const rest={select:async()=>[{id:admission.deviceId}],request:async()=>{throw new Error('unexpected direct mutation');},
    rpc:async(name:string,args:any)=>{
      calls.push({name,args});
      if(name==='noop_recovery_claim')return job;
      if(name==='noop_recovery_intake_call'&&args.p_operation==='noop_reserve_copy_intent')return {
        id:crypto.randomUUID(),lease_token:crypto.randomUUID(),verified_key:'fixture/verified',upload_key:manifest.object_key};
      return true;
    }};
  const result=await recoveryPoll(rest as any,{head:async()=>{throw new Error('b2 timeout');}} as any,identity,'legacy');
  assert.equal(result.claimed,1);assert.equal(result.completed,0);assert.equal(result.failures,1);
  const failure=calls.find(x=>x.args.p_operation==='legacy_failure');
  assert.equal(failure.args.p_token,job.recoveryToken);assert.equal(failure.args.p_args.retryable,true);
  assert.deepEqual(calls.at(-1),{name:'noop_recovery_poll',args:{p_run:admission.runId,p_lane:'legacy',p_completed:0,p_failures:1}});
});

Deno.test('lost reservation authority stops before retry settlement or poll',async()=>{
  const calls:string[]=[];
  await assert.rejects(()=>recoveryPoll({rpc:async(name:string)=>{
    calls.push(name);throw new Error('recovery_supervision_unavailable');}} as any,{} as any,identity,'legacy'),/recovery_supervision/);
  assert.deepEqual(calls,['noop_recovery_claim']);
});

Deno.test('actual signed S3 adapter preserves sanitized credential rejection and recovery stops without releasing capacity',async()=>{
  for(const status of [401,403]) {
    const raw=createS3({endpoint:'https://storage.invalid',bucket:'fixture',region:'test',accessKeyId:'fixture',secretAccessKey:'fixture',
      fetchImpl:async()=>new Response('PRIVATE_PROVIDER_RESPONSE',{status})});
    for(const operation of [()=>raw.head('fixture'),()=>raw.getObjectStream('fixture'),()=>raw.copyObject('a','b')]) {
      await assert.rejects(operation,error=>error instanceof S3OperationError && error.status===status && !String(error).includes('PRIVATE'));
    }
    const calls:any[]=[];
    const rest={select:async()=>[{id:admission.deviceId}],request:async()=>null,rpc:async(name:string,args:any)=>{
      calls.push({name,args});if(name==='noop_recovery_claim')return job;
      if(args?.p_operation==='noop_reserve_copy_intent')return {id:crypto.randomUUID(),lease_token:crypto.randomUUID(),
        verified_key:'fixture/verified',upload_key:manifest.object_key};return true;}};
    await assert.rejects(()=>recoveryPoll(rest as any,raw,identity,'legacy'),/intake_admission_scope_mismatch/);
    assert(!calls.some(x=>x.args?.p_operation==='legacy_failure'||x.name==='noop_recovery_poll'));
  }
});

Deno.test('streaming decoded enforcement uses reservation even when ordinary object hard limit is larger',async()=>{
  const plain=new TextEncoder().encode('x'.repeat(2048));
  const zipped=new Uint8Array(await new Response(new Blob([plain]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
  await assert.rejects(()=>verifyStoredObject({getObjectStream:async()=>new Response(zipped)} as any,
    {compression:'gzip',format:'ndjson',compressed_bytes:zipped.length,uncompressed_bytes:null,
      sha256:sha256Hex(zipped),digest_scope:'wire',recovery_max_decoded_bytes:1024},'fixture'),/decoded_size_mismatch/);
  await assert.rejects(()=>verifyStoredObject({getObjectStream:async()=>new Response(zipped)} as any,
    {compression:'gzip',format:'ndjson',compressed_bytes:zipped.length,uncompressed_bytes:plain.length,
      sha256:sha256Hex(zipped),digest_scope:'wire',recovery_max_wire_bytes:zipped.length-1},'fixture'),/size_mismatch/);
});

Deno.test('projection stops streamed decode at reserved bytes before buffering a larger valid receipt',async()=>{
  const plain=new TextEncoder().encode('x'.repeat(2048));
  const zipped=new Uint8Array(await new Response(new Blob([plain]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
  const receipt={state:'verified_indexed',objectKey:'fixture',objectId:manifest.id,ownerUserId:admission.ownerId,
    deviceId:admission.deviceId,compressedBytes:zipped.length,uncompressedBytes:plain.length,
    wireSha256:sha256Hex(zipped),contentSha256:sha256Hex(plain)};
  await assert.rejects(()=>readVerifiedArchive({getObjectStream:async()=>new Response(zipped)} as any,
    {...manifest,object_key:'fixture',format:'ndjson',compression:'gzip',durability_receipt:receipt,
      recovery_max_decoded_bytes:1024,recovery_max_wire_bytes:zipped.length}),/projection_decoded_size_mismatch/);
  await assert.rejects(()=>readVerifiedArchive({getObjectStream:async()=>new Response(zipped)} as any,
    {...manifest,object_key:'fixture',format:'ndjson',compression:'gzip',durability_receipt:receipt,
      recovery_max_decoded_bytes:plain.length,recovery_max_wire_bytes:zipped.length-1}),/projection_wire_size_mismatch/);
});
