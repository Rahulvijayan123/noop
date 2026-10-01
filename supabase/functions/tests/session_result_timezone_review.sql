-- Run after SessionInsightsConsentReviewIntegrationTest in its disposable fixture database.
-- No production approval, policy, candidate, source or request is changed by this regression.
begin;
set local request.jwt.claim.role='service_role';
do $$
declare r public.compute_session_requests; utc_result jsonb; tokyo_result jsonb;
 utc_fingerprint text; tokyo_fingerprint text; original_request jsonb; original_day date;
begin
 select q.* into r from public.compute_session_requests q
 join public.compute_session_numerical_candidates c on c.request_id=q.id
 where q.family='insights' and internal.compute_session_scope_active(q)
 order by c.revision desc limit 1;
 assert r.id is not null, 'actual insights producer fixture required; do not replace with an empty envelope';
 original_request:=r.request;
 original_day:=((r.event_end-interval '1 microsecond') at time zone r.timezone_id)::date;
 perform set_config('TimeZone','UTC',true);
 utc_fingerprint:=public.compute_session_source_fingerprint(r.id);
 utc_result:=public.read_compute_session_result(r.user_id,r.device_id,r.source_id,r.id);
 assert current_setting('TimeZone')='UTC', 'RPC must restore caller UTC setting';
 perform set_config('TimeZone','Asia/Tokyo',true);
 tokyo_fingerprint:=public.compute_session_source_fingerprint(r.id);
 assert current_setting('TimeZone')='Asia/Tokyo', 'fingerprint must restore caller timezone';
 tokyo_result:=public.read_compute_session_result(r.user_id,r.device_id,r.source_id,r.id);
 assert current_setting('TimeZone')='Asia/Tokyo', 'RPC must restore caller Tokyo setting';
 assert utc_result->'result'->>'result_revision' is not null, 'fixture must contain an immutable candidate';
 raise notice 'UTC fingerprint %, result %; Tokyo fingerprint %, result %',
   utc_fingerprint, utc_result->'result'->>'result_revision',
   tokyo_fingerprint, tokyo_result->'result'->>'result_revision';
 assert utc_fingerprint is not distinct from tokyo_fingerprint,
   'caller timezone must not change source fingerprint';
 assert utc_result->'result'->>'result_revision'=tokyo_result->'result'->>'result_revision',
   'caller timezone must not change immutable result revision';
 assert utc_result->'result'->>'computed_at'=tokyo_result->'result'->>'computed_at',
   'computed_at must use a stable canonical representation';
 assert utc_result->'result'->>'observed_through'=tokyo_result->'result'->>'observed_through',
   'observed_through must use a stable canonical representation';
 assert utc_result=tokyo_result, 'qualification, values and producer identity must also remain unchanged';
 assert (select request=original_request and timezone_id=r.timezone_id
   and ((event_end-interval '1 microsecond') at time zone timezone_id)::date=original_day
   from public.compute_session_requests where id=r.id), 'normalization must not relabel request civil day';
end $$;
rollback;
