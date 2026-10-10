-- Local PostgreSQL fixture only. Never apply this file to a hosted project.
-- Minimal stand-ins for existing interfaces the worker reads; the real definitions live in supabase/migrations.
create role anon;
create role authenticated;
create role service_role bypassrls;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth to authenticated;
grant execute on function auth.uid() to authenticated;
create table noop_app_installations(user_id uuid, source_id uuid, revoked_at timestamptz);
create table compute_account_sources(user_id uuid, source_id uuid, revoked_at timestamptz);
grant select on noop_app_installations,compute_account_sources to service_role;
create table noop_hr_samples(user_id uuid,device_id uuid,ts bigint,bpm integer,primary key(user_id,device_id,ts));
create table noop_skin_temp_samples(user_id uuid,device_id uuid,ts bigint,raw double precision,primary key(user_id,device_id,ts));
create table server_metric_series(user_id uuid,device_id uuid,metric text,bucket_start timestamptz,bucket_seconds integer,value double precision);
create table activity_encoder_windows(user_id uuid,device_id uuid,day date,computed_at timestamptz,windows jsonb);
-- Signature engine timeline sources (column names as in the production stream tables).
create table noop_rr_intervals(user_id uuid,device_id uuid,ts bigint,"rrMs" integer,seq integer not null default 0,
  ord integer,"srcChannel" integer,"tsSuspect" integer,primary key(user_id,device_id,ts,"rrMs",seq));
create table noop_gravity_samples(user_id uuid,device_id uuid,ts bigint,x double precision default 0,
  y double precision default 0,z double precision default 1,"dynAccel" double precision,primary key(user_id,device_id,ts));
create table noop_step_samples(user_id uuid,device_id uuid,ts bigint,counter integer,"activityClass" integer,
  primary key(user_id,device_id,ts));
create table noop_sleep_state_samples(user_id uuid,device_id uuid,ts bigint,state integer,raw_byte integer,
  primary key(user_id,device_id,ts));
create table noop_events(user_id uuid,device_id uuid,ts bigint,kind text,"payloadJSON" text default '{}',
  primary key(user_id,device_id,ts,kind));
-- In production activity_context_runs is a view over activity_context_days documents; a table stands in here.
create table activity_context_runs(user_id uuid,device_id uuid,day date,start_ts bigint,end_ts bigint,
  activity_class text,class_confidence real,sleep_state text,wear_state text,posture jsonb,source_rank integer);
create table server_sleep_nights(user_id uuid,device_id uuid,start_at timestamptz,end_at timestamptz);
-- The phone's activity-context intervals (20261009190000), the columns the Layer 1 loader reads.
create table phone_context_intervals(user_id uuid,device_id uuid,start_ts bigint,end_ts bigint,activity_class text,
  confidence float8 default 0,evidence_quality float8 default 0,posture text,locomotion text,sleep_state text,
  wear_state text,intensity float8,hr_samples integer default 0,hr_mean float8,rmssd float8,rr_beats integer default 0,
  rr_diff_sq_sum_ms2 float8 default 0,rr_diff_count integer default 0,detail text,arm_behavior text,
  primary key(user_id,device_id,start_ts));
