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
