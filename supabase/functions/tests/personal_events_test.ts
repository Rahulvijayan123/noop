import { assert, assertEquals, assertFalse } from 'jsr:@std/assert';
import { handleScoresRequest } from '../_shared/serverScores.ts';
import { validateDetectionCommand } from '../_shared/personalEvents.ts';
import { hashIngestToken } from '../_shared/tokens.ts';
import { makeMemRest } from './helpers.ts';
const A='11111111-1111-4111-8111-111111111111', B='22222222-2222-4222-8222-222222222222';
const S='33333333-3333-4333-8333-333333333333', T='44444444-4444-4444-8444-444444444444';
const cfg={supabaseUrl:'https://test.invalid',supabaseAnonKey:'fixture'};
const command={action:'setting',requestId:A,typeId:T,enabled:true};
async function fixture() {
  const rest=makeMemRest() as any;
  await rest.upsert('noop_ingest_tokens',[{id:'a',token_hash:hashIngestToken('noop_a'),token_kind:'installation',provisioning_method:'supabase_auth',user_id:A,source_id:S}]);
  await rest.upsert('noop_app_installations',[{user_id:A,source_id:S}]);
  const calls:any[]=[]; const reads:any[]=[]; const select=rest.select;
  rest.rpc=(name:string,args:any)=>{calls.push({name,args});return {saved:args.p_body?.requestId};};
  rest.select=(table:string,query:string)=> {
    if (!table.startsWith('event_')) return select(table,query);
    reads.push({table,query});return [];
  };
  return {rest,calls,reads};
}
function request(method:string,body?:unknown,suffix='',token='noop_a') {
  return new Request('https://test.invalid/functions/v1/scores/event-detection'+suffix,{method,
    headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},
    body:method==='POST'?JSON.stringify(body):undefined});
}
Deno.test('personal events: bounded commands reject injected ownership and invalid reviews',()=>{
  assert(validateDetectionCommand(command));
  assert(validateDetectionCommand({action:'negative',requestId:A,typeId:T,deviceId:S,start:100,end:400}));
  for(const body of [{...command,user_id:B},{...command,enabled:'true'},
    {action:'review',requestId:A,typeId:T,detectionId:S,outcome:'delete',start:1,end:2},
    {action:'negative',requestId:A,typeId:T,deviceId:S,start:1,end:90000},
    {action:'review',requestId:A,typeId:T,detectionId:S,outcome:'confirmed',start:4,end:2}]) assertFalse(validateDetectionCommand(body));
});
Deno.test('personal events: every write derives owner from installation and cannot delete',async()=>{
  const {rest,calls}=await fixture();
  const response=await handleScoresRequest(request('POST',command),{rest,cfg});
  assertEquals(response.status,200);assertEquals(calls[0].args.p_user,A);assertEquals(calls[0].args.p_source,S);
  assertEquals((await response.json()).identity.userId,A);
  assertEquals((await handleScoresRequest(request('DELETE'),{rest,cfg})).status,405);
  assertEquals((await handleScoresRequest(request('POST',{...command,user_id:B}),{rest,cfg})).status,400);
  assertEquals((await handleScoresRequest(request('GET',undefined,'',''),{rest,cfg})).status,401);
});
Deno.test('personal events: reads and physiology stay owner scoped, with bounded windows',async()=>{
  const {rest,reads,calls}=await fixture();
  assertEquals((await handleScoresRequest(request('GET'),{rest,cfg})).status,200);
  assert(reads.every(r=>r.query.startsWith(`user_id=eq.${A}&`)));
  assertEquals((await handleScoresRequest(request('GET',undefined,`/physiology?deviceId=${B}&from=100&to=500`),{rest,cfg})).status,200);
  assertEquals(calls[0].args.p_user,A);assertEquals(calls[0].args.p_device,B);
  for(const suffix of [`?user_id=${B}`,'?before=bad',`/physiology?deviceId=${B}&from=0&to=999999`])
    assertEquals((await handleScoresRequest(request('GET',undefined,suffix),{rest,cfg})).status,400);
});
