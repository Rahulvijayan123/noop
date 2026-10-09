-- The v2 scoring pass can publish while its owner uploads.
--
-- WHY
-- 20261008020000_ingest_no_scoring_wait let uploads stop waiting for the scoring pass. Every upload
-- still dirties the day's scoring_work_items row, whose result_day_changed trigger bumps that day's
-- server_result_days row. The v2 pass (ScoringLane.runV2Once) runs claim, scoring and
-- publish_scoring_snapshot_v2 in ONE REPEATABLE READ transaction, and the scoring_snapshots_v2 insert
-- fires the same touch on the same row. A REPEATABLE READ transaction cannot update a row another
-- transaction changed after its snapshot (40001), so while the phone uploads more often than a pass
-- takes, the owner's current day never publishes. The failed claim rolls back with the pass, so the
-- owner stays "least recently served" and claim_scoring_v2 hands the same day out again: every other
-- user's v2 days wait behind it.
--
-- WHAT CHANGES
--   1. touch_server_result_day keeps its READ COMMITTED behaviour exactly. In a snapshot transaction
--      (REPEATABLE READ or SERIALIZABLE) a serialization failure on the server_result_days upsert is
--      caught and the touch is appended to internal.server_result_day_touches (a plain insert that
--      nothing else updates), so the publication commits.
--   2. internal.fold_server_result_day_touches applies those touches as ordinary bumps, under the
--      same per-device advisory lock, from pg_cron every minute. A touch is visible to the fold only
--      after the transaction that left it committed, so the bump always allocates a cursor after
--      that publication: a paginated reader sees the day change again, at most a minute later.
--
-- Unchanged: the trigger set, the cursor, READ COMMITTED writers (uploads, workers' own commits).
-- No table or data is dropped. Idempotent: create-if-not-exists / create or replace / guarded cron.
begin;

create table if not exists internal.server_result_day_touches (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  device_id uuid not null,
  day date not null,
  created_at timestamptz not null default clock_timestamp()
);
revoke all on internal.server_result_day_touches from public, anon, authenticated;
comment on table internal.server_result_day_touches is
  'server_result_days bumps a REPEATABLE READ writer (the v2 scoring pass) could not apply because an '
  'upload changed the row after its snapshot. Folded by internal.fold_server_result_day_touches '
  '(pg_cron, every minute). A non-empty, old backlog here means the fold is not running.';

create or replace function public.touch_server_result_day() returns trigger
language plpgsql security definer set search_path=pg_catalog,public as $$
declare row_data jsonb:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  u uuid:=(row_data->>'user_id')::uuid; d uuid:=(row_data->>'device_id')::uuid;
  period date:=coalesce(row_data->>'period_day',row_data->>'day')::date;
begin
  if tg_op='DELETE' and not exists(select 1 from devices where id=d and user_id=u) then return null; end if;
  -- Serialize sequence allocation through commit per device, so a delayed transaction
  -- cannot commit an older cursor after the reader has already advanced past it.
  perform pg_advisory_xact_lock(hashtextextended('result-days:'||u::text||':'||d::text,0));
  if current_setting('transaction_isolation')='read committed' then
    insert into server_result_days(user_id,device_id,day) values(u,d,period)
    on conflict(user_id,device_id,day) do update set change_revision=nextval('public.server_result_day_change_seq');
    return null;
  end if;
  -- A snapshot transaction cannot update a row bumped after its snapshot; leave the bump for the fold.
  begin
    insert into server_result_days(user_id,device_id,day) values(u,d,period)
    on conflict(user_id,device_id,day) do update set change_revision=nextval('public.server_result_day_change_seq');
  exception when serialization_failure then
    insert into internal.server_result_day_touches(user_id,device_id,day) values(u,d,period);
  end;
  return null;
end $$;
revoke all on function public.touch_server_result_day() from public, anon, authenticated;

-- Call from a READ COMMITTED transaction (pg_cron's default). Returns the number of days bumped.
create or replace function internal.fold_server_result_day_touches(p_limit integer default 5000)
returns integer language plpgsql security definer set search_path=pg_catalog,public as $$
declare r record; n integer:=0;
begin
  for r in
    with taken as (
      delete from internal.server_result_day_touches t
       where t.id in (select k.id from internal.server_result_day_touches k order by k.id
                      for update skip locked limit least(greatest(coalesce(p_limit,0),0),20000))
      returning t.user_id, t.device_id, t.day)
    select distinct user_id, device_id, day from taken order by user_id, device_id, day
  loop
    if not exists(select 1 from devices where id=r.device_id and user_id=r.user_id) then continue; end if;
    perform pg_advisory_xact_lock(hashtextextended('result-days:'||r.user_id::text||':'||r.device_id::text,0));
    insert into server_result_days(user_id,device_id,day) values(r.user_id,r.device_id,r.day)
    on conflict(user_id,device_id,day) do update set change_revision=nextval('public.server_result_day_change_seq');
    n:=n+1;
  end loop;
  return n;
end $$;
revoke all on function internal.fold_server_result_day_touches(integer) from public, anon, authenticated;

-- Guarded so a database without pg_cron still applies the migration.
do $$
begin
  if to_regclass('cron.job') is null then
    raise warning 'result_day_touch_snapshot_writers: pg_cron absent; schedule internal.fold_server_result_day_touches externally';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'frwhoop-fold-result-day-touches') then
    perform cron.unschedule('frwhoop-fold-result-day-touches');
  end if;
  perform cron.schedule('frwhoop-fold-result-day-touches', '* * * * *',
    'select internal.fold_server_result_day_touches()');
end $$;

commit;
