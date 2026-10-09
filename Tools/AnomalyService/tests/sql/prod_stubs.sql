-- Minimal stand-ins for the production objects the anomaly migration and service touch (tests only).
-- Column names/types mirror production (supabase/migrations/20260918010000_production_scoring_durability.sql etc.).
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create extension if not exists pgcrypto;
create schema if not exists auth;
create schema if not exists internal;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create table if not exists public.devices (id uuid primary key, user_id uuid not null references auth.users(id), kind text, unique (user_id, id));
create table if not exists public.noop_account_retirements (user_id uuid primary key);
create table if not exists public.scoring_algorithms_v2 (algorithm_version text primary key);
insert into public.scoring_algorithms_v2 values ('frwhoop-server-1') on conflict do nothing;
create table if not exists public.scoring_jobs_v2 (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null references public.devices(id) on delete cascade,
  day date not null,
  algorithm_version text not null references public.scoring_algorithms_v2,
  input_revision bigint not null default 1, completed_revision bigint not null default 0,
  last_completed_at timestamptz,
  primary key (user_id, device_id, day, algorithm_version));
create table if not exists public.noop_hr_samples (user_id uuid, device_id uuid, ts bigint, bpm integer, primary key (user_id, device_id, ts));
create table if not exists public.noop_rr_intervals (user_id uuid, device_id uuid, ts bigint, "rrMs" integer, seq integer default 0,
  ord integer, "srcChannel" integer, "tsSuspect" integer, primary key (user_id, device_id, ts, "rrMs", seq));
create table if not exists public.noop_skin_temp_samples (user_id uuid, device_id uuid, ts bigint, raw integer, "aux1Raw" integer, "aux2Raw" integer, primary key (user_id, device_id, ts));
create table if not exists public.noop_gravity_samples (user_id uuid, device_id uuid, ts bigint, x double precision, y double precision, z double precision, "dynAccel" double precision, primary key (user_id, device_id, ts));
create table if not exists public.noop_step_samples (user_id uuid, device_id uuid, ts bigint, counter integer, "activityClass" integer, primary key (user_id, device_id, ts));
create table if not exists public.noop_sleep_state_samples (user_id uuid, device_id uuid, ts bigint, state integer, primary key (user_id, device_id, ts));
create table if not exists public.noop_events (user_id uuid, device_id uuid, ts bigint, kind text, "payloadJSON" text, primary key (user_id, device_id, ts, kind));
-- Read by process() since the context-hygiene change (time zone history, nightly resting HR, current epoch lineage);
-- columns mirror 20260918010000_physiology_revisions.sql, 20260916160000_scoring_service_state.sql,
-- 20261003120000_activity_context.sql and 20261008100000_activity_context_current_lineage_and_versions.sql.
create table if not exists public.profiles (id uuid primary key references auth.users(id), timezone text not null default 'UTC');
create table if not exists public.scoring_timezone_history (user_id uuid not null references auth.users(id), effective_at timestamptz not null,
  timezone_id text not null, provenance text not null, primary key (user_id, effective_at));
create table if not exists public.server_daily_scores (user_id uuid not null references auth.users(id), day date not null,
  algorithm_version text not null, resting_hr_bpm numeric, primary key (user_id, day, algorithm_version));
alter table public.devices add column if not exists device_family text;
create table if not exists public.server_metric_series (user_id uuid not null, metric text not null, bucket_start timestamptz not null,
  bucket_seconds integer not null default 300, value double precision not null, primary key (user_id, metric, bucket_start));
create table if not exists public.activity_context_epochs (user_id uuid not null, device_id uuid not null, day date not null,
  start_ts bigint not null, end_ts bigint not null, motion_label text not null, posture text not null default 'unknown',
  exercise_session text not null default 'unknown', sleep_state text not null default 'unknown',
  exertion_context text not null default 'unknown', wear_state text not null default 'unknown', confidence real not null,
  fingerprint text not null, result_revision bigint not null, computed_at timestamptz not null,
  primary key (user_id, device_id, start_ts, fingerprint));
create or replace view public.activity_context_epochs_current with (security_invoker = true) as
select e.* from public.activity_context_epochs e
 where e.result_revision = (select max(x.result_revision) from public.activity_context_epochs x
                             where x.user_id = e.user_id and x.device_id = e.device_id and x.day = e.day);
