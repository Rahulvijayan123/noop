-- Local PostgreSQL fixture only. Never apply this file to a hosted project.
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
