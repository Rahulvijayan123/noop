-- Disposable migrated database only; every fixture rolls back.
begin;
insert into auth.users(id) values('a1511111-1111-4111-8111-111111111111'),('b1511111-1111-4111-8111-111111111111');
insert into devices(id,user_id,source_kind) values
 ('a1522222-2222-4222-8222-222222222222','a1511111-1111-4111-8111-111111111111','noop_push'),
 ('b1522222-2222-4222-8222-222222222222','b1511111-1111-4111-8111-111111111111','noop_push');
insert into compute_account_sources(source_id,user_id) values
 ('a1533333-3333-4333-8333-333333333333','a1511111-1111-4111-8111-111111111111'),
 ('b1533333-3333-4333-8333-333333333333','b1511111-1111-4111-8111-111111111111');
select scoring_enqueue_legacy_fenced('a1511111-1111-4111-8111-111111111111',
 'a1522222-2222-4222-8222-222222222222','2026-01-01'::date+i,'America/Los_Angeles',0) from generate_series(0,39) i;
select set_config('request.jwt.claim.role','service_role',true);
do $$ declare page jsonb; cursor bigint:=0; scope text; count_days integer:=0; old_cursor bigint; begin
 loop
   page:=server_result_days_page('a1511111-1111-4111-8111-111111111111','a1522222-2222-4222-8222-222222222222',
     'a1533333-3333-4333-8333-333333333333',cursor,7,scope);
   assert jsonb_array_length(page->'days')<=7,'page exceeds budget';
   count_days:=count_days+jsonb_array_length(page->'days');
   scope:=page->>'scope_revision'; cursor:=(page->>'next_cursor')::bigint;
   exit when not (page->>'has_more')::boolean;
 end loop;
 assert count_days=40,'empty cache cannot discover all old days';
 assert page->>'timezone_id'='UTC','profile calendar fallback must agree with scoring_timezone_at';
 old_cursor:=cursor;
 perform scoring_enqueue_legacy_fenced('a1511111-1111-4111-8111-111111111111',
   'a1522222-2222-4222-8222-222222222222','2026-01-01','America/Los_Angeles',0);
 page:=server_result_days_page('a1511111-1111-4111-8111-111111111111','a1522222-2222-4222-8222-222222222222',
   'a1533333-3333-4333-8333-333333333333',cursor,7,scope);
 assert jsonb_array_length(page->'days')=1 and page#>>'{days,0,day}'='2026-01-01','changed old day missed';
 assert (page->>'next_cursor')::bigint>old_cursor,'change did not advance cursor';
 page:=server_result_days_page('a1511111-1111-4111-8111-111111111111','a1522222-2222-4222-8222-222222222222',
   'a1533333-3333-4333-8333-333333333333',cursor,7,repeat('0',32));
 assert jsonb_array_length(page->'days')=7,'scope change did not restart enumeration';
 insert into scoring_timezone_history(user_id,effective_at,timezone_id,provenance)
   values('a1511111-1111-4111-8111-111111111111',now()-interval '1 second','Pacific/Kiritimati','profile_change');
 page:=server_result_days_page('a1511111-1111-4111-8111-111111111111','a1522222-2222-4222-8222-222222222222',
   'a1533333-3333-4333-8333-333333333333',cursor,7,scope);
 assert page->>'timezone_id'='Pacific/Kiritimati','hosted profile calendar not returned';
 assert page->>'scope_revision'<>scope and jsonb_array_length(page->'days')=7,'calendar change did not invalidate discovery';
 begin
   perform server_result_days_page('a1511111-1111-4111-8111-111111111111','b1522222-2222-4222-8222-222222222222',
    'a1533333-3333-4333-8333-333333333333',0,7,null);
   raise exception 'other owner device admitted';
 exception when insufficient_privilege then null; end;
 begin
   perform server_result_days_page('a1511111-1111-4111-8111-111111111111','a1522222-2222-4222-8222-222222222222',
    'b1533333-3333-4333-8333-333333333333',0,7,null);
   raise exception 'other owner source admitted';
 exception when insufficient_privilege then null; end;
end $$;
rollback;
