-- Uploads stop waiting for scoring passes.
--
-- WHY
-- Every push POST took the owner gate pg_advisory_xact_lock('scoring-inputs-v2:<owner>') EXCLUSIVE
-- twice: in the receipt commit (the noop_signal_windows insert fires invalidate_scoring_stream_v2)
-- and in noop_commit_push_projection (an explicit lock, then the noop_* inserts fire the same
-- triggers). The scoring worker (ScoringLane.runV2Once) holds the SHARED side of that gate for its
-- whole 8-16 s pass, so uploads queued behind it and died on the authenticator role's 8 s
-- lock_timeout as HTTP 500s. Parallel uploads and bigger batches made it worse.
--
-- WHAT THE GATE PROTECTED, AND WHAT PROTECTS IT NOW
-- Scoring is fenced per job row, not by the gate:
--   * claim_scoring_v2 locks the job row (FOR UPDATE ... SKIP LOCKED, then UPDATE lease) as the first
--     statement of the worker's REPEATABLE READ transaction, and the row stays locked until that
--     transaction commits at publication. The pass reads inputs from that same snapshot.
--   * publish_scoring_snapshot_v2 re-reads the row FOR UPDATE and publishes only when
--     input_revision = the claimed revision; it sets completed_revision = that revision.
--   * Every input change bumps input_revision of each affected day (enqueue_scoring_v2) in the SAME
--     transaction as the rows themselves.
-- So a bump either commits before the claim (the pass sees the rows and the new revision), or it
-- cannot reach the claimed row until the pass has committed, and then it lands as
-- input_revision > completed_revision: the day is dirty and is scored again. The gate added two
-- things on top: (1) range invalidations (scoring_invalidations_v2) could not commit during a pass,
-- so publish's "no invalidation covers this day" check could not be overtaken; (2) a lock order
-- (gate before job row) so an upload waiting on the claimed row and a pass waiting on the gate
-- could not deadlock. The cost was that the upload WAITED on the claimed row anyway.
--
-- This migration:
--   1. scoring triggers never wait on a job row. internal.scoring_try_enqueue_v2 bumps a row only if
--      it can lock it without waiting (SKIP LOCKED); when a pass (or another writer) holds it, the
--      trigger appends a row to public.scoring_dirty_marks_v2 instead - a plain insert that nothing
--      else locks - in the same transaction as the samples.
--   2. public.fold_scoring_dirty_marks_v2 turns marks into ordinary revision bumps, again without
--      waiting: a mark whose row is still held stays for the next fold. It runs from every upload
--      (for that owner) and from pg_cron every minute. A fold reads a mark only after the upload
--      that wrote it committed, and it can lock the row only after the racing pass committed, so
--      its bump always lands after that pass's completed_revision: the day ends dirty and is
--      re-scored with the new rows. Nothing is lost; a racing upload's day is re-dirtied within one
--      fold (seconds while the phone is uploading, at most a minute otherwise).
--   3. invalidate_scoring_stream_v2 no longer takes the owner gate. Range invalidations (>7 days)
--      are still inserted unconditionally; one that commits mid-pass is not seen by that pass's
--      snapshot, so the pass may publish once more, but the range stays, readers already report
--      pending=true for covered days, claims skip covered days, and expand_scoring_invalidations_v2
--      (cron) re-dirties every covered day afterwards.
--   4. invalidate_scoring_history_stream_v3 returns at once when no history (v3) algorithm is
--      enabled - production has none - instead of taking the gate for an empty loop. With a v3
--      algorithm enabled it behaves exactly as before (gate included).
--   5. noop_commit_push_projection_intake_core serializes settlement on its own owner key
--      ('noop-projection-settlement-v1:<owner>') instead of the scoring gate.
--   6. Timezone resolution no longer scans pg_timezone_names (it enumerates the tz database on every
--      call, ~0.1-0.5 s): internal.scoring_timezone_names caches the catalog's names, a miss still
--      falls back to the catalog, and results are identical (a name the catalog does not list maps
--      to UTC exactly as before). The cache is re-synced daily and can be re-synced by hand with
--      select internal.refresh_scoring_timezone_names();
--
-- Unchanged: publish/claim/fail/renew, enqueue_scoring_v2, the worker's own gate (it now always gets
-- it at once), and the other exclusive gate takers (profile/device/source/history invalidation RPCs,
-- legacy engine_ingest_scored), which are rare and not on the upload path. No table or data is
-- dropped. Idempotent: create-if-not-exists / create or replace / guarded cron re-schedule.
begin;

-- 6. Timezone name cache -------------------------------------------------------------------------
create table if not exists internal.scoring_timezone_names (name text primary key);
revoke all on internal.scoring_timezone_names from public, anon, authenticated, service_role;

create or replace function internal.refresh_scoring_timezone_names() returns integer
language plpgsql security definer set search_path=pg_catalog as $$
declare added integer;
begin
  delete from internal.scoring_timezone_names c
    where not exists(select 1 from pg_catalog.pg_timezone_names t where t.name=c.name);
  insert into internal.scoring_timezone_names(name)
    select distinct t.name from pg_catalog.pg_timezone_names t on conflict do nothing;
  get diagnostics added=row_count;
  return added;
end $$;
revoke all on function internal.refresh_scoring_timezone_names() from public, anon, authenticated, service_role;
select internal.refresh_scoring_timezone_names();

-- The zone a scoring calendar uses for a profile timezone: the name itself when the catalog lists
-- it, otherwise UTC. Same answer as coalesce((select name from pg_timezone_names where name=z),'UTC');
-- the catalog is consulted only for a name the cache does not hold.
create or replace function internal.scoring_zone_v2(p_zone text) returns text
language plpgsql stable security definer set search_path=pg_catalog as $$
declare z text;
begin
  if p_zone is null then return 'UTC'; end if;
  select c.name into z from internal.scoring_timezone_names c where c.name=p_zone;
  if found then return z; end if;
  select t.name into z from pg_catalog.pg_timezone_names t where t.name=p_zone;
  return coalesce(z,'UTC');
end $$;
revoke all on function internal.scoring_zone_v2(text) from public, anon, authenticated, service_role;

-- Once-per-owner variant for statement triggers: also proves the zone converts, so a cached name a
-- newer tz database dropped (before the daily re-sync) degrades to UTC, as the catalog would say,
-- instead of aborting the upload.
create or replace function internal.scoring_zone_checked_v2(p_zone text) returns text
language plpgsql stable security definer set search_path=pg_catalog as $$
declare z text:=internal.scoring_zone_v2(p_zone);
begin
  perform pg_catalog.timezone(z, timestamptz '2000-01-01 00:00:00+00');
  return z;
exception when invalid_parameter_value then
  return 'UTC';
end $$;
revoke all on function internal.scoring_zone_checked_v2(text) from public, anon, authenticated, service_role;

-- Latest prior definition: 20260921104000_server_unrepresentable_clock.sql. Same results; the
-- pg_timezone_names scan per call is replaced by the cache. Security definer so a direct caller
-- does not need the internal schema.
create or replace function public.scoring_local_day_v2(p_time text,p_zone text) returns date
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare observed timestamptz;
begin
  observed:=case when p_time ~ '^-?[0-9]+(\.[0-9]+)?$' then to_timestamp(p_time::double precision)
    else p_time::timestamptz end;
  if observed is null or not isfinite(observed) then return null; end if;
  return (observed at time zone internal.scoring_zone_v2(p_zone))::date;
exception when datetime_field_overflow or numeric_value_out_of_range or invalid_datetime_format
  or invalid_text_representation then
  return null;
when invalid_parameter_value then
  -- Only a cached zone the running tz database no longer knows: the catalog would have said UTC.
  if observed is null then return null; end if;
  return (observed at time zone 'UTC')::date;
end $$;

-- 1. Lock-free dirty marks -----------------------------------------------------------------------
create table if not exists public.scoring_dirty_marks_v2 (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null references public.scoring_algorithms_v2,
  reason text not null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists scoring_dirty_marks_owner_v2 on public.scoring_dirty_marks_v2(user_id, id);
alter table public.scoring_dirty_marks_v2 enable row level security;
revoke all on public.scoring_dirty_marks_v2 from public, anon, authenticated;
grant all on public.scoring_dirty_marks_v2 to service_role;
grant usage, select on sequence public.scoring_dirty_marks_v2_id_seq to service_role;
do $$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='scoring_dirty_marks_v2'
      and policyname='scoring_service_v2') then
    create policy scoring_service_v2 on public.scoring_dirty_marks_v2 for all to service_role using (true) with check (true);
  end if;
end $$;
comment on table public.scoring_dirty_marks_v2 is
  'Day re-score requests an upload could not apply because the job row was held (a running scoring pass). '
  'Folded into scoring_jobs_v2.input_revision by fold_scoring_dirty_marks_v2 (uploads + pg_cron). '
  'A non-empty, old backlog here means the fold is not running.';

-- enqueue_scoring_v2 without ever waiting on an existing job row. TRUE: the day's input_revision was
-- bumped (or its job created) in this transaction. FALSE: someone else holds the row; the caller
-- must leave a mark. A row this transaction already locked is not "held" (own locks never skip).
create or replace function internal.scoring_try_enqueue_v2(p_user uuid,p_device uuid,p_day date,
  p_version text,p_reason text) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  perform 1 from scoring_jobs_v2 where user_id=p_user and device_id=p_device and day=p_day
    and algorithm_version=p_version for update skip locked;
  if found then
    perform enqueue_scoring_v2(p_user,p_device,p_day,p_version,p_reason);
    return true;
  end if;
  if exists(select 1 from scoring_jobs_v2 where user_id=p_user and device_id=p_device and day=p_day
      and algorithm_version=p_version) then
    return false;
  end if;
  -- No job yet: create it the way enqueue_scoring_v2 does. DO NOTHING never waits on a committed
  -- row (only on another transaction inserting this very key, which is brief).
  if not exists(select 1 from devices where id=p_device and user_id=p_user) then
    raise exception 'device_owner_mismatch';
  end if;
  insert into scoring_jobs_v2(user_id,device_id,day,algorithm_version,reason)
    values(p_user,p_device,p_day,p_version,p_reason) on conflict do nothing;
  if found then
    -- enqueue_scoring_v2's rev=1 branch: new source discovery must not leave the legacy projection
    -- on the previous source.
    if exists(select 1 from server_daily_scores where user_id=p_user and day=p_day
      and algorithm_version=p_version and source_device_id is distinct from
        selected_scoring_device_v2(p_user,p_day,p_version)) then
      perform refresh_scoring_legacy_v2(p_user,p_day,p_version);
    end if;
    return true;
  end if;
  -- Created concurrently: one more attempt that cannot wait.
  perform 1 from scoring_jobs_v2 where user_id=p_user and device_id=p_device and day=p_day
    and algorithm_version=p_version for update skip locked;
  if found then
    perform enqueue_scoring_v2(p_user,p_device,p_day,p_version,p_reason);
    return true;
  end if;
  return false;
end $$;
revoke all on function internal.scoring_try_enqueue_v2(uuid,uuid,date,text,text)
  from public, anon, authenticated, service_role;

-- 2. Fold marks into revisions, never waiting. Returns marks applied. Bounded per call; p_user
-- restricts the fold to one owner (what an upload does for its own owner).
create or replace function public.fold_scoring_dirty_marks_v2(p_limit integer default 500, p_user uuid default null)
returns integer language plpgsql security definer set search_path=public as $$
declare m record; n integer:=0;
begin
  for m in select * from scoring_dirty_marks_v2 k where (p_user is null or k.user_id=p_user)
    order by k.id for update skip locked limit least(greatest(coalesce(p_limit,0),0),5000)
  loop
    if not exists(select 1 from devices where id=m.device_id and user_id=m.user_id)
        or not exists(select 1 from scoring_algorithms_v2 where algorithm_version=m.algorithm_version) then
      delete from scoring_dirty_marks_v2 where id=m.id;
      continue;
    end if;
    if internal.scoring_try_enqueue_v2(m.user_id,m.device_id,m.day,m.algorithm_version,m.reason) then
      delete from scoring_dirty_marks_v2 where id=m.id;
      n:=n+1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.fold_scoring_dirty_marks_v2(integer,uuid) from public, anon, authenticated;
grant execute on function public.fold_scoring_dirty_marks_v2(integer,uuid) to service_role;

-- 3. Stream invalidation without the owner gate. Base: 20260918050000_production_scoring_history.sql
-- (the latest definition). Same changed-row detection, same day span (day .. through_day+2), same
-- >7-day range path; only the lock, the zone lookup and the blocking enqueue changed.
create or replace function public.invalidate_scoring_stream_v2() returns trigger
language plpgsql security definer set search_path=public as $$
declare r record; v record; d date; query text; source_sql text; ts_field text:=TG_ARGV[0];
  owners uuid[]:='{}'; o uuid;
begin
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] as b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) as b from new_rows n';
  else source_sql:='select to_jsonb(o) as b from old_rows o'; end if;
  query:='with changed as materialized ('||source_sql||'), zones as materialized (
    select p.id,internal.scoring_zone_checked_v2(p.timezone) as zone from profiles p
    join (select distinct (b->>''user_id'')::uuid id from changed) owners using(id))
    select distinct (b->>''user_id'')::uuid as u,(b->>''device_id'')::uuid as dev,
    (scoring_timestamp_v3(b->>'||quote_literal(ts_field)||') at time zone p.zone)::date as day,
    (scoring_timestamp_v3(coalesce(b->>'||quote_literal(coalesce(TG_ARGV[1],ts_field))||',b->>'||quote_literal(ts_field)||')) at time zone p.zone)::date as through_day
    from changed join zones p on p.id=(b->>''user_id'')::uuid order by u,dev,day';
  for r in execute query loop
    if not exists(select 1 from devices where id=r.dev and user_id=r.u) then continue; end if;
    if not (r.u = any(owners)) then owners:=owners||r.u; end if;
    for v in select algorithm_version from scoring_algorithms_v2 where enabled loop
      -- The current reader spans [wake day -30h, wake day end]. Includes the next two wake days.
      if r.through_day-r.day>7 then
        insert into scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
          values(r.u,r.dev,v.algorithm_version,r.day,r.through_day+2,TG_TABLE_NAME);
      else
        for d in select generate_series(r.day,r.through_day+2,interval '1 day')::date loop
          if not internal.scoring_try_enqueue_v2(r.u,r.dev,d,v.algorithm_version,TG_TABLE_NAME) then
            -- Held by a running pass: re-dirty it once that pass has committed.
            insert into scoring_dirty_marks_v2(user_id,device_id,day,algorithm_version,reason)
              values(r.u,r.dev,d,v.algorithm_version,TG_TABLE_NAME);
          end if;
        end loop;
      end if;
    end loop;
  end loop;
  -- Apply this owner's earlier marks whose pass has finished since (non-blocking, bounded).
  foreach o in array owners loop
    perform fold_scoring_dirty_marks_v2(64,o);
  end loop;
  return null;
end $$;

-- 4. History (v3) stream trigger. Base: 20260923190000_history_clock_durability.sql. Identical
-- except the early return when there is no enabled history algorithm, which is the production
-- state; then the old body only took the owner gate and looped over nothing.
create or replace function public.invalidate_scoring_history_stream_v3() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare source_sql text; query text; r record; v record;
begin
  if not exists(select 1 from public.scoring_history_algorithms_v3 a
      join public.scoring_algorithms_v2 b using(algorithm_version) where b.enabled) then
    return null;
  end if;
  if TG_OP='UPDATE' then
    source_sql:='(select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] b from new_rows n EXCEPT select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o) union (select to_jsonb(o)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from old_rows o EXCEPT select to_jsonb(n)-array[''ingested_at'',''updated_at'',''batch_id'',''source_id''] from new_rows n)';
  elsif TG_OP='INSERT' then source_sql:='select to_jsonb(n) b from new_rows n';
  else source_sql:='select to_jsonb(o) b from old_rows o'; end if;
  query:='with observed as materialized (
    select (b->>''user_id'')::uuid u,(b->>''device_id'')::uuid dev,
      (public.scoring_timestamp_v3(b->>'||quote_literal(TG_ARGV[0])||') at time zone ''UTC'')::date first_day,
      (public.scoring_timestamp_v3(coalesce(b->>'||quote_literal(TG_ARGV[1])||',b->>'||quote_literal(TG_ARGV[0])||')) at time zone ''UTC'')::date last_day
    from ('||source_sql||') changed
  ), spans as (
    select u,dev,first_day,last_day from observed
      where first_day is not null and last_day is not null and first_day<=last_day
    union all select u,dev,first_day,first_day from observed
      where first_day is not null and (last_day is null or first_day>last_day)
    union all select u,dev,last_day,last_day from observed
      where last_day is not null and (first_day is null or first_day>last_day)
  ) select u,dev,first_day-1 lo,max(last_day)+3 hi
    from spans group by u,dev,first_day order by u,dev,first_day';
  for r in execute query loop
    if r.lo is null or r.hi is null or r.lo>r.hi then continue; end if;
    if not exists(select 1 from public.devices where id=r.dev and user_id=r.u) then continue; end if;
    perform pg_advisory_xact_lock(hashtextextended('scoring-inputs-v2:'||r.u,0));
    for v in select a.algorithm_version from public.scoring_history_algorithms_v3 a
      join public.scoring_algorithms_v2 b using(algorithm_version) where b.enabled loop
      -- One initial day fences publication immediately. A true long interval
      -- remains complete durable debt for the existing bounded expander; distinct
      -- scalar days never become one continuous interval across their gaps.
      perform public.enqueue_scoring_v2(r.u,r.dev,r.lo,v.algorithm_version,'historical_timezone_raw_correction');
      insert into public.scoring_invalidations_v2(user_id,device_id,algorithm_version,next_day,through_day,reason)
        values(r.u,r.dev,v.algorithm_version,r.lo,r.hi,'historical_timezone_raw_correction');
    end loop;
  end loop;
  return null;
end $$;

-- 5. Projection settlement on its own owner key. Base: 20260918040000_production_projection_debt.sql
-- (renamed to *_intake_core by 20260922120000; contracts/deployed confirms the body). One line
-- changed: the advisory key. ACL is kept by create or replace.
create or replace function public.noop_commit_push_projection_intake_core(p_object_id uuid,p_body_sha256 text,p_header jsonb,
  p_rows jsonb,p_keep_keys jsonb,p_token uuid default null) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
<<settlement>>
declare m public.object_manifests; d public.noop_projection_debt; r public.noop_push_reservations;
  ack jsonb; rows_to_apply jsonb:=p_rows; keys_to_keep jsonb:=p_keep_keys; w jsonb; part_count integer;
  stream text:=p_header->>'stream'; generation text; source text; window_identity jsonb; g record;
  generation_at timestamptz; window_start numeric; window_end numeric; later_windows nummultirange;
begin
  select * into m from public.object_manifests where id=p_object_id;
  if not found or m.status not in ('ready','verified') or m.format not like 'ndjson%'
    or m.durability_receipt->>'state' is distinct from 'verified_indexed'
    or m.durability_receipt->>'contentSha256' is distinct from p_body_sha256
    or m.batch_id::text is distinct from p_header->>'batchId' or m.source_id::text is distinct from p_header->>'sourceId'
    or m.object_kind is distinct from stream or m.sample_count is distinct from (p_header->>'recordCount')::bigint
    or not exists(select 1 from public.devices where id=m.device_id and user_id=m.user_id)
    or not exists(select 1 from public.noop_signal_windows where object_id=m.id and object_key=m.object_key) then
    raise exception 'projection_archive_mismatch';
  end if;
  -- Serializes one owner's source-window settlement (replace_window part counting, later-window
  -- masking) and append settlement, as before, but on a key of its own: the scoring worker holds
  -- 'scoring-inputs-v2:<owner>' shared for a whole scoring pass, and waiting for that here is what
  -- turned uploads into 8 s lock timeouts. The scoring triggers no longer take any owner lock, so
  -- there is no lock order left to keep with them (20261008020000_ingest_no_scoring_wait.sql).
  perform pg_advisory_xact_lock(hashtextextended('noop-projection-settlement-v1:'||m.user_id,0));
  select * into r from public.noop_push_reservations where user_id=m.user_id and batch_id=m.batch_id for update;
  if not found or r.body_sha256<>p_body_sha256 or r.device_id<>m.device_id then raise exception 'batch_id_conflict'; end if;
  insert into public.noop_projection_debt(object_id,user_id,device_id,created_at)
    values(m.id,m.user_id,m.device_id,m.created_at) on conflict do nothing;
  select * into d from public.noop_projection_debt where object_id=m.id for update;
  if d.state in ('complete','staged') then
    select a.ack into ack from public.noop_push_acks a where a.user_id=m.user_id and a.batch_id=m.batch_id;
    if ack is not null then
      delete from public.noop_push_wal where user_id=m.user_id and batch_id=m.batch_id;
      return ack;
    end if;
  end if;
  if p_token is not null and (d.lease_token is distinct from p_token or d.lease_until<=clock_timestamp()) then
    raise exception 'projection_lease_lost';
  end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_typeof(p_keep_keys) is distinct from 'array'
    or exists(select 1 from jsonb_array_elements(p_rows) x where x->>'user_id' is distinct from m.user_id::text
      or coalesce(x->>'device_id',x->>'source_device_id') is distinct from m.device_id::text) then raise exception 'projection_owner_mismatch'; end if;
  if p_header->>'delivery'='replace_window' then
    w:=p_header->'window'; generation:=w->>'replacementId'; source:=p_header->>'sourceId';
    window_identity:=w-'part';
    if generation is null or coalesce((w->>'part')::integer,0)<1 or coalesce((w->>'parts')::integer,0)<1
      or (w->>'part')::integer>(w->>'parts')::integer or (w->>'parts')::integer>128
      or coalesce(w->>'selector','') not in ('day','startTs') or w->>'startInclusive' is null
      or w->>'endExclusive' is null then raise exception 'invalid_window'; end if;
    if (stream in ('dailyMetric','journal') and w->>'selector'<>'day')
      or (stream in ('sleepSession','workout') and w->>'selector'<>'startTs')
      or stream not in ('dailyMetric','journal','sleepSession','workout') then raise exception 'invalid_window'; end if;
    window_start:=case when w->>'selector'='day' then ((w->>'startInclusive')::date-date '1970-01-01')::numeric*86400
      else (w->>'startInclusive')::numeric end;
    window_end:=case when w->>'selector'='day' then ((w->>'endExclusive')::date-date '1970-01-01')::numeric*86400
      else (w->>'endExclusive')::numeric end;
    if window_end<=window_start or exists(select 1 from jsonb_array_elements(p_rows) x
      where public.noop_projection_coordinate(stream,x) is null
        or not(public.noop_projection_coordinate(stream,x)<@numrange(window_start,window_end,'[)'))) then
      raise exception 'projection_outside_window';
    end if;
    for g in select object_id,header from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
      and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation loop
      if ((g.header->'window')-'part') is distinct from window_identity then raise exception 'replacement_window_conflict'; end if;
      if g.object_id<>m.id and g.header->'window'->>'part'=w->>'part' then raise exception 'replacement_part_conflict'; end if;
    end loop;
    update public.noop_projection_debt set header=p_header,mapped_rows=p_rows,keep_keys=p_keep_keys where object_id=m.id;
    select count(*) into part_count from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
      and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation;
    if part_count=(w->>'parts')::integer then
      if (select sum(pg_column_size(mapped_rows)) from public.noop_projection_debt where user_id=m.user_id and device_id=m.device_id
          and header->>'stream'=stream and header->>'sourceId'=source and header->'window'->>'replacementId'=generation)>33554432 then
        raise exception 'replacement_projection_too_large';
      end if;
      select coalesce(jsonb_agg(x.row order by (q.header->'window'->>'part')::integer,x.ord),'[]') into rows_to_apply
        from public.noop_projection_debt q cross join lateral jsonb_array_elements(q.mapped_rows) with ordinality x(row,ord)
        where q.user_id=m.user_id and q.device_id=m.device_id and q.header->>'stream'=stream
          and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select coalesce(jsonb_agg(x.key),'[]') into keys_to_keep from public.noop_projection_debt q,
        lateral jsonb_array_elements(q.keep_keys) x(key) where q.user_id=m.user_id and q.device_id=m.device_id
          and q.header->>'stream'=stream and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select min(b.created_at) into generation_at from public.noop_projection_debt q
        join public.noop_push_reservations b on b.user_id=q.user_id and b.batch_id=q.object_id
        where q.user_id=m.user_id and q.device_id=m.device_id and q.header->>'stream'=settlement.stream
          and q.header->>'sourceId'=source and q.header->'window'->>'replacementId'=generation;
      select coalesce(range_agg(numrange(c.window_start,c.window_end,'[)')),'{}'::nummultirange) into later_windows
        from public.noop_projection_replacements c where c.user_id=m.user_id and c.device_id=m.device_id and c.stream=settlement.stream
          and (c.accepted_at,c.replacement_id)>(generation_at,generation)
          and c.window_start<settlement.window_end and c.window_end>settlement.window_start;
      select coalesce(jsonb_agg(x),'[]') into rows_to_apply from jsonb_array_elements(rows_to_apply) x
        where not(public.noop_projection_coordinate(stream,x)<@later_windows);
      perform public.noop_apply_projection_rows(stream,rows_to_apply);
      if stream='dailyMetric' then
        delete from public.daily_metrics where user_id=m.user_id and source_device_id=m.device_id
          and day>=(w->>'startInclusive')::date and day<(w->>'endExclusive')::date and not (keys_to_keep ? day::text)
          and not((day-date '1970-01-01')::numeric*86400<@later_windows);
      elsif stream='journal' then
        delete from public.noop_journal_entries where user_id=m.user_id and device_id=m.device_id
          and day>=(w->>'startInclusive')::date and day<(w->>'endExclusive')::date and not (keys_to_keep ? (day::text||'|'||question))
          and not((day-date '1970-01-01')::numeric*86400<@later_windows);
      elsif stream in ('sleepSession','workout') then
        delete from public.sessions where user_id=m.user_id and device_id=m.device_id
          and kind=any(case when stream='sleepSession' then array['sleep'] else array['workout','manual_workout'] end)
          and start_at>=to_timestamp((w->>'startInclusive')::double precision)
          and start_at<to_timestamp((w->>'endExclusive')::double precision) and not(keys_to_keep ? external_id)
          and not(extract(epoch from start_at)<@later_windows);
      else raise exception 'unsupported_projection'; end if;
      insert into public.noop_projection_replacements(user_id,device_id,source_id,stream,replacement_id,accepted_at,window_start,window_end)
        values(m.user_id,m.device_id,source::uuid,stream,generation,generation_at,window_start,window_end) on conflict do nothing;
      update public.noop_projection_debt set state='complete',completed_at=clock_timestamp(),mapped_rows=null,keep_keys=null,
        lease_token=null,lease_until=null where user_id=m.user_id and device_id=m.device_id and header->>'stream'=stream
          and header->>'sourceId'=source and header->'window'->>'replacementId'=generation;
      delete from public.noop_push_staging_parts where user_id=m.user_id and replacement_id=generation
        and scope=m.user_id::text||'|'||source||'|'||(p_header->>'deviceId')||'|'||stream;
    else
      update public.noop_projection_debt set state='staged',lease_token=null,lease_until=null where object_id=m.id;
    end if;
  elsif p_header->>'delivery'='append' then
    perform public.noop_apply_projection_rows(stream,p_rows);
    update public.noop_projection_debt set state='complete',completed_at=clock_timestamp(),lease_token=null,lease_until=null,
      failures=0,last_error=null where object_id=m.id;
  else raise exception 'unsupported_delivery'; end if;
  ack:=jsonb_build_object('protocolVersion',p_header->>'protocolVersion','batchId',p_header->>'batchId',
    'stream',stream,'deviceId',p_header->>'deviceId','endCursor',p_header->'endCursor',
    'acceptedRows',(p_header->>'recordCount')::integer,'status','accepted','durabilityReceipt',m.durability_receipt);
  perform public.noop_push_save_ack(m.user_id,m.batch_id,p_body_sha256,ack);
  delete from public.noop_push_wal where user_id=m.user_id and batch_id=m.batch_id;
  return ack;
end $$;

-- Schedules: fold marks every minute (uploads also fold their own owner's marks), re-sync the
-- timezone cache daily (a Postgres minor upgrade can ship new tz names; a miss is already correct,
-- just slower). Guarded so a database without pg_cron still applies the migration.
do $$
begin
  if to_regclass('cron.job') is null then
    raise warning 'ingest_no_scoring_wait: pg_cron absent; schedule fold_scoring_dirty_marks_v2 externally';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'frwhoop-fold-scoring-dirty-marks') then
    perform cron.unschedule('frwhoop-fold-scoring-dirty-marks');
  end if;
  perform cron.schedule('frwhoop-fold-scoring-dirty-marks', '* * * * *',
    'select public.fold_scoring_dirty_marks_v2(2000)');
  if exists (select 1 from cron.job where jobname = 'frwhoop-refresh-scoring-timezones') then
    perform cron.unschedule('frwhoop-refresh-scoring-timezones');
  end if;
  perform cron.schedule('frwhoop-refresh-scoring-timezones', '17 3 * * *',
    'select internal.refresh_scoring_timezone_names()');
end $$;

commit;
