import assert from 'node:assert/strict';

/** Disposable, loopback-only SQL adapter. Production functions and transactions are
 * real; only the HTTP transport to PostgREST is replaced by a psql subprocess. */
export function recoverySqlFixture(database: string) {
  const url=new URL(database);
  assert.equal(url.hostname,'127.0.0.1');assert.equal(url.pathname,'/physiology_queue_test');assert.equal(url.username,'postgres');
  const literal=(v:unknown):string=>v===null||v===undefined?'null':typeof v==='object'?`'${JSON.stringify(v).replaceAll("'","''")}'::jsonb`:
    typeof v==='boolean'?String(v):typeof v==='number'?(assert(Number.isFinite(v)),String(v)):`'${String(v).replaceAll("'","''")}'`;
  async function sql(statement:string){
    const container=Deno.env.get('BOUNDED_RECOVERY_POSTGRES_CONTAINER');
    if(container)assert.match(container,/^[a-f0-9]{64}$/);
    const prefix=container?['--context','colima-frwhoop-integration','exec',container,'psql','-U','postgres','-d','postgres']:[database];
    const result=await new Deno.Command(container?'/opt/homebrew/bin/docker':'/opt/homebrew/bin/psql',{args:[...prefix,'-X','-qAt','-v','ON_ERROR_STOP=1','-c',
      `set request.jwt.claim.role='service_role';${statement}`],stdout:'piped',stderr:'piped'}).output();
    if(!result.success)throw new Error(new TextDecoder().decode(result.stderr));
    return new TextDecoder().decode(result.stdout).trim();
  }
  const rest:any={rpc:async(name:string,args:Record<string,unknown>)=>{
    assert.match(name,/^[a-z_]+$/);
    const named=Object.entries(args).map(([key,value])=>{assert.match(key,/^[a-z_][a-z0-9_]*$/);return `${key}=>${literal(value)}`;}).join(',');
    const result=await sql(`select coalesce(to_jsonb(public.${name}(${named}))::text,'null')`);return JSON.parse(result||'null');
  },select:async(table:string,query:string)=>{
    assert.equal(table,'devices');
    const filters=query.split('&').filter(x=>!x.startsWith('select=')).map(x=>{
      const [column,value]=x.split('=eq.');assert(['id','user_id'].includes(column));assert.match(value,/^[a-f0-9-]{36}$/);return `${column}=${literal(value)}`;});
    return JSON.parse(await sql(`select coalesce(jsonb_agg(to_jsonb(d)),'[]') from devices d where ${filters.join(' and ')}`));
  },request:async()=>{throw new Error('unexpected direct mutation');}};
  return {sql,rest,literal};
}
