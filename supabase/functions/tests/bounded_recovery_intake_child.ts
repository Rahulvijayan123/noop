import assert from 'node:assert/strict';
import { recoveryPoll } from '../_shared/boundedRecovery.ts';
import { createS3 } from '../_shared/s3.ts';
import { recoverySqlFixture } from './recovery_sql_fixture.ts';

const input=JSON.parse(Deno.env.get('BOUNDED_RECOVERY_CHILD')!);
assert.equal(new URL(input.endpoint).hostname,'127.0.0.1');
assert(['claim','verified','receipt','projection'].includes(input.boundary));
const {rest}=recoverySqlFixture(Deno.env.get('BOUNDED_RECOVERY_TEST_DATABASE_URL')!);
let reached=false;
async function pauseAtBoundary() {
  reached=true;
  console.log(`BOUNDARY:${input.boundary}`);
  // Parent observes this marker then sends SIGKILL. No exception/finally handler
  // or worker compensation can run between this point and process death.
  await new Promise(()=>{});
}
const wrapped={...rest,rpc:async(name:string,args:any)=>{
  if(input.boundary==='verified'&&name==='noop_recovery_intake_call'&&args.p_operation==='noop_intake_canary_commit_receipt')
    await pauseAtBoundary();
  const value=await rest.rpc(name,args);
  if((input.boundary==='claim'&&name==='noop_recovery_claim')||
    (name==='noop_recovery_intake_call'&&((input.boundary==='receipt'&&args.p_operation==='noop_intake_canary_commit_receipt')||
      (input.boundary==='projection'&&args.p_operation==='noop_intake_canary_commit_projection'))))await pauseAtBoundary();
  return value;
}};
await recoveryPoll(wrapped,createS3({endpoint:input.endpoint,bucket:'fixture',region:'local',accessKeyId:'fixture',secretAccessKey:'fixture'}),
  input.identity,input.boundary==='projection'?'projection':'legacy');
assert(reached,'requested durable boundary was never reached');
