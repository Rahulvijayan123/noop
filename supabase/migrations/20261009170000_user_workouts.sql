-- Workout mode: the workouts a wearer logs from the strap screen, saved by type, and the catalogue of those types
-- (docs/context-watchdog/WORKOUTS.md).
--
-- WHY
-- A logged workout was only ever a finished `public.sessions` row (kind manual_workout, a free-text sport in
-- summary->>'sport'), written by the structured push after the live session ended. Nothing on the server knew a
-- workout was running, nothing said what kind it was beyond that text, and the wearer could not say "I am on a
-- treadmill" versus "I am walking outside". Workout mode lets the wearer start, change, stop (or log afterwards) a
-- workout of a catalogue type; the phone uploads every edit, and every pipeline reads the same typed intervals: the
-- measurement-context builder (session phase `logged`, the type per minute), the activity worker (epochs'
-- exercise_session and the decoder's workout kind, ElderNet gait days), and the anomaly service.
--
-- WHAT CHANGES
--   public.workout_types                one row per catalogue type (contracts/workout-types-1.json, seeded here and
--                                       pinned by tests/workout_types_parity_test.ts): its attributes (environment,
--                                       locomotion, effort, gait_expected, arm_motion, steps_expected), the stored
--                                       sport name and the decoder kind. Readable by everyone signed in; ids are never
--                                       removed (a change is a new catalogue version).
--   public.user_workouts                one row per (owner, client_id): the canonical strap device (the scores route
--                                       resolves it, findNoopDevice), the type (FK to the catalogue), started_at,
--                                       ended_at (NULL while running), source manual | auto_ended, optional notes, the
--                                       phone's clock for last-writer-wins, soft delete. RLS: the owner selects their
--                                       own rows; only service_role writes.
--   internal.workout_type_for_sport     the catalogue type a stored sport label stands for (name or alias), or NULL.
--   internal.logged_workouts_v1         every pipeline's one read of logged workouts for a strap: user_workouts (a
--                                       running one up to now, never past 4 h) plus the manual workout sessions it
--                                       does not already hold (same start within 2 minutes), typed through the
--                                       catalogue.
--   internal.measurement_context_logged_workouts_v1  (from 20261009130100) now reads internal.logged_workouts_v1.
--   public.user_workouts_upsert_v1      service only (POST scores/workouts): at most 50 workouts, validated again,
--                                       last writer wins per client_id on client_updated_at, idempotent. One workout
--                                       runs at a time: an open workout followed by a later-starting open one is
--                                       closed at that start (source auto_ended). Every change re-queues the local
--                                       days it touches for the measurement-context builder. Returns
--                                       {accepted, skipped_stale, closed}.
--   public.user_workouts_read_v1        service only (GET scores/workouts): the owner's workouts overlapping a range,
--                                       each with its type's attributes, at most 500, oldest first.
-- No trigger, no lock on any other table; the activity job queue is not touched (a workout logged for a past day
-- reaches that day's epochs at its next activity job; the builder and the anomaly service read this table directly).
--
-- Safe to re-run. Rollback: re-create internal.measurement_context_logged_workouts_v1 from 20261009130100; drop
-- function public.user_workouts_read_v1(uuid, uuid, timestamptz, timestamptz, integer, boolean),
-- public.user_workouts_upsert_v1(uuid, uuid, uuid, text, jsonb), internal.logged_workouts_v1(uuid, uuid, timestamptz,
-- timestamptz), internal.workout_type_for_sport(text); drop table public.user_workouts, public.workout_types.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- 1. Catalogue ---------------------------------------------------------------------------------------------------
create table if not exists public.workout_types (
  id             text primary key check (id ~ '^[a-z][a-z0-9_]{0,31}$'),
  version        text not null check (version ~ '^workout-types-[0-9]+$'),
  sort_order     smallint not null,
  name           text not null,
  sport_name     text not null unique,
  decoder_kind   text not null check (decoder_kind in ('running', 'walking', 'cycling', 'other')),
  environment    text not null check (environment in ('indoor', 'outdoor', 'either')),
  locomotion     text not null check (locomotion in ('walking', 'running', 'cycling', 'none', 'mixed')),
  effort         text not null check (effort in ('light', 'moderate', 'vigorous', 'resistance')),
  gait_expected  boolean not null,
  arm_motion     text not null check (arm_motion in ('swing', 'fixed', 'varied')),
  steps_expected boolean not null,
  sport_aliases  text[] not null default '{}'
);
comment on table public.workout_types is
  'Workout-mode catalogue (contracts/workout-types-1.json; docs/context-watchdog/WORKOUTS.md): the attributes each '
  'pipeline reads for a logged workout of the type. Seeded by 20261009170000; ids are never removed.';
alter table public.workout_types enable row level security;
revoke all on public.workout_types from public, anon, authenticated;
grant select on public.workout_types to authenticated;
grant all on public.workout_types to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'workout_types'
                    and policyname = 'workout_types_read') then
    create policy workout_types_read on public.workout_types for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'workout_types'
                    and policyname = 'workout_types_service') then
    create policy workout_types_service on public.workout_types for all to service_role using (true) with check (true);
  end if;
end $$;

insert into public.workout_types as t (id, version, sort_order, name, sport_name, decoder_kind, environment, locomotion,
                                       effort, gait_expected, arm_motion, steps_expected, sport_aliases)
values
  ('strength', 'workout-types-1', 1, 'Strength training', 'Strength', 'other', 'either',
   'none', 'resistance', false, 'varied', false,
   array['Weightlifting', 'Bodybuilding', 'Powerlifting', 'Calisthenics']::text[]),
  ('hiit', 'workout-types-1', 2, 'HIIT / circuit', 'HIIT', 'other', 'either',
   'mixed', 'vigorous', false, 'varied', true,
   array['CrossFit', 'Boot camp', 'Jump rope']::text[]),
  ('indoor_walk', 'workout-types-1', 3, 'Indoor walk (treadmill)', 'Treadmill walk', 'walking', 'indoor',
   'walking', 'moderate', true, 'varied', true,
   '{}'::text[]),
  ('outdoor_walk', 'workout-types-1', 4, 'Outdoor walk', 'Walking', 'walking', 'outdoor',
   'walking', 'moderate', true, 'swing', true,
   array['Nordic walking', 'Rucking']::text[]),
  ('indoor_run', 'workout-types-1', 5, 'Indoor run (treadmill)', 'Treadmill run', 'running', 'indoor',
   'running', 'vigorous', true, 'varied', true,
   '{}'::text[]),
  ('outdoor_run', 'workout-types-1', 6, 'Outdoor run', 'Running', 'running', 'outdoor',
   'running', 'vigorous', true, 'swing', true,
   '{}'::text[]),
  ('indoor_cycling', 'workout-types-1', 7, 'Indoor cycling', 'Indoor cycle', 'cycling', 'indoor',
   'cycling', 'moderate', false, 'fixed', false,
   array['Spinning']::text[]),
  ('outdoor_cycling', 'workout-types-1', 8, 'Outdoor cycling', 'Cycling', 'cycling', 'outdoor',
   'cycling', 'moderate', false, 'fixed', false,
   array['Mountain biking']::text[]),
  ('rowing', 'workout-types-1', 9, 'Rowing / erg', 'Row machine', 'other', 'either',
   'none', 'vigorous', false, 'varied', false,
   array['Rowing', 'Kayaking']::text[]),
  ('elliptical', 'workout-types-1', 10, 'Elliptical', 'Elliptical', 'other', 'indoor',
   'none', 'moderate', false, 'varied', false,
   '{}'::text[]),
  ('stair_climber', 'workout-types-1', 11, 'Stair climber', 'Stair climber', 'other', 'indoor',
   'walking', 'vigorous', true, 'varied', true,
   '{}'::text[]),
  ('swimming', 'workout-types-1', 12, 'Swimming', 'Pool swim', 'other', 'either',
   'none', 'vigorous', false, 'varied', false,
   array['Open-water swim']::text[]),
  ('yoga', 'workout-types-1', 13, 'Yoga', 'Yoga', 'other', 'either',
   'none', 'light', false, 'varied', false,
   '{}'::text[]),
  ('pilates', 'workout-types-1', 14, 'Pilates', 'Pilates', 'other', 'either',
   'none', 'moderate', false, 'varied', false,
   '{}'::text[]),
  ('stretching', 'workout-types-1', 15, 'Stretching / mobility', 'Stretching', 'other', 'either',
   'none', 'light', false, 'varied', false,
   '{}'::text[]),
  ('sports', 'workout-types-1', 16, 'Sports (team / racket)', 'Sports', 'other', 'either',
   'mixed', 'vigorous', true, 'varied', true,
   array['Tennis', 'Padel', 'Pickleball', 'Squash', 'Badminton', 'Racquetball', 'Table tennis', 'Basketball', 'Soccer', 'Volleyball', 'Baseball', 'Softball', 'Ice Hockey', 'Rugby', 'Cricket', 'Handball', 'Netball', 'Lacrosse', 'Field hockey', 'American football', 'Australian football', 'Gaelic football']::text[]),
  ('hiking', 'workout-types-1', 17, 'Hiking', 'Hiking', 'walking', 'outdoor',
   'walking', 'moderate', true, 'swing', true,
   '{}'::text[]),
  ('dance', 'workout-types-1', 18, 'Dance', 'Dancing', 'other', 'either',
   'mixed', 'moderate', false, 'varied', true,
   array['Ballet', 'Breakdancing']::text[]),
  ('martial_arts', 'workout-types-1', 19, 'Martial arts / boxing', 'Martial arts', 'other', 'either',
   'mixed', 'vigorous', false, 'varied', false,
   array['Boxing', 'Kickboxing', 'Jiu jitsu', 'Judo', 'Muay Thai', 'Fencing']::text[]),
  ('other', 'workout-types-1', 20, 'Other', 'Other', 'other', 'either',
   'mixed', 'moderate', false, 'varied', false,
   '{}'::text[])
on conflict (id) do update set
  version = excluded.version, sort_order = excluded.sort_order, name = excluded.name, sport_name = excluded.sport_name,
  decoder_kind = excluded.decoder_kind, environment = excluded.environment, locomotion = excluded.locomotion,
  effort = excluded.effort, gait_expected = excluded.gait_expected, arm_motion = excluded.arm_motion,
  steps_expected = excluded.steps_expected, sport_aliases = excluded.sport_aliases
where (t.version, t.sort_order, t.name, t.sport_name, t.decoder_kind, t.environment, t.locomotion, t.effort,
       t.gait_expected, t.arm_motion, t.steps_expected, t.sport_aliases)
      is distinct from
      (excluded.version, excluded.sort_order, excluded.name, excluded.sport_name, excluded.decoder_kind,
       excluded.environment, excluded.locomotion, excluded.effort, excluded.gait_expected, excluded.arm_motion,
       excluded.steps_expected, excluded.sport_aliases);

-- The catalogue type a stored sport label stands for: its sport name or one of its aliases, case-insensitive and
-- trimmed (WorkoutTypeCatalog.resolve on the phone). Free text that names no type stays NULL; it is never guessed.
create or replace function internal.workout_type_for_sport(p_sport text)
returns text language sql stable security definer set search_path = '' as $$
  select t.id from public.workout_types t
   where lower(btrim(p_sport)) = lower(t.sport_name)
      or lower(btrim(p_sport)) = any (select lower(a) from unnest(t.sport_aliases) a)
   order by t.sort_order limit 1
$$;
revoke all on function internal.workout_type_for_sport(text) from public, anon, authenticated, service_role;

-- 2. The log ------------------------------------------------------------------------------------------------------
create table if not exists public.user_workouts (
  user_id           uuid not null references auth.users(id) on delete cascade,
  -- The phone's id for the workout (its idempotency key).
  client_id         uuid not null,
  -- The canonical strap device the scores route resolves (findNoopDevice, alias-aware), like every device-scoped row.
  device_id         uuid not null,
  -- The id the phone knows the strap by locally, and the installation that sent this version.
  local_device_id   text check (local_device_id ~ '^[\x20-\x7e]{1,255}$'),
  source_id         uuid,
  workout_type      text not null references public.workout_types(id),
  catalogue_version text not null default 'workout-types-1' check (catalogue_version ~ '^workout-types-[0-9]+$'),
  started_at        timestamptz not null,
  -- NULL while it runs. A running workout counts up to now and never past 4 hours (internal.logged_workouts_v1).
  ended_at          timestamptz,
  source            text not null default 'manual' check (source in ('manual', 'auto_ended')),
  notes             text check (notes is null or length(notes) <= 500),
  deleted_at        timestamptz,
  client_updated_at timestamptz not null,
  created_at        timestamptz not null default clock_timestamp(),
  updated_at        timestamptz not null default clock_timestamp(),
  primary key (user_id, client_id),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (ended_at is null or ended_at > started_at),
  check (ended_at is null or ended_at - started_at <= interval '24 hours')
);
comment on table public.user_workouts is
  'Workout mode (20261009170000; docs/context-watchdog/WORKOUTS.md): workouts the wearer logged, by catalogue type. '
  'One row per (owner, client_id). Written only through POST scores/workouts (user_workouts_upsert_v1, last writer '
  'wins on client_updated_at); the owner may read their own rows.';
comment on column public.user_workouts.source is
  'manual: stopped (or logged afterwards) by the wearer; auto_ended: closed at the 4-hour cap, or by a later workout.';

create index if not exists user_workouts_device_started on public.user_workouts (user_id, device_id, started_at desc);
create index if not exists user_workouts_open on public.user_workouts (user_id)
  where ended_at is null and deleted_at is null;

alter table public.user_workouts enable row level security;
revoke all on public.user_workouts from public, anon, authenticated;
grant select on public.user_workouts to authenticated;
grant all on public.user_workouts to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_workouts'
                    and policyname = 'user_workouts_select_own') then
    create policy user_workouts_select_own on public.user_workouts for select to authenticated
      using ((select auth.uid()) = user_id);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'user_workouts'
                    and policyname = 'user_workouts_service') then
    create policy user_workouts_service on public.user_workouts for all to service_role using (true) with check (true);
  end if;
end $$;

-- 3. Every pipeline's read ----------------------------------------------------------------------------------------
-- The workouts the wearer logged for strap p_device overlapping [p_from, p_to): workout mode's rows (a running one up
-- to now, never past 4 h; deleted ones never), then the manual workout sessions (the live tracker and the manual
-- sheet, written by the structured push) that no workout-mode row already holds (same start within 2 minutes), typed
-- through the catalogue from their sport label. Oldest first.
create or replace function internal.logged_workouts_v1(p_user uuid, p_device uuid, p_from timestamptz,
                                                       p_to timestamptz)
returns table (start_at timestamptz, end_at timestamptz, workout_type text, basis text, ref text, source text)
language sql stable security definer set search_path = '' as $$
  select x.s, x.e, x.workout_type, x.basis, x.ref, x.source
    from (select w.started_at as s,
                 least(coalesce(w.ended_at, clock_timestamp()), w.started_at + interval '4 hours') as e,
                 w.workout_type, 'user_workout'::text as basis, w.client_id::text as ref, w.source
            from public.user_workouts w
           where w.user_id = p_user and w.device_id = p_device and w.deleted_at is null
             and w.started_at < p_to and coalesce(w.ended_at, w.started_at + interval '4 hours') > p_from
          union all
          select s.start_at, s.end_at, internal.workout_type_for_sport(s.summary ->> 'sport'), 'manual_session',
                 s.id::text, 'manual'
            from public.sessions s
           where s.user_id = p_user and s.device_id = p_device and s.kind = 'manual_workout'
             and s.start_at < p_to and s.end_at > p_from
             and not exists (select 1 from public.user_workouts w
                              where w.user_id = p_user and w.deleted_at is null
                                and w.started_at between s.start_at - interval '2 minutes'
                                                     and s.start_at + interval '2 minutes')) x
   where x.e > x.s
   order by x.s, x.basis desc
$$;
revoke all on function internal.logged_workouts_v1(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated, service_role;

-- The measurement-context builder's seam (20261009130100) reads the same list.
create or replace function internal.measurement_context_logged_workouts_v1(p_user uuid, p_device uuid, p_from bigint,
                                                                          p_to bigint)
returns table (start_ts bigint, end_ts bigint, workout_type text, basis text)
language sql stable security definer set search_path = '' as $$
  select extract(epoch from l.start_at)::bigint, extract(epoch from l.end_at)::bigint, l.workout_type, l.basis
    from internal.logged_workouts_v1(p_user, p_device, to_timestamp(p_from), to_timestamp(p_to)) l
$$;
revoke all on function internal.measurement_context_logged_workouts_v1(uuid, uuid, bigint, bigint)
  from public, anon, authenticated, service_role;

-- 4. Write (POST scores/workouts) ---------------------------------------------------------------------------------
-- The phone's workouts for one owner's strap. The scores route validates first (_shared/userWorkouts.ts); this is the
-- backstop: shape, times, types and sizes are checked again and a batch with a problem is refused whole. Last writer
-- wins per client_id on client_updated_at (an equal timestamp with different content is the later arrival and wins;
-- the same content again writes nothing). accepted = workouts the server now holds as sent; skipped_stale = ones it
-- holds a newer copy of; closed = open workouts closed because a later one started.
create or replace function public.user_workouts_upsert_v1(p_user uuid, p_device uuid, p_source uuid,
                                                          p_local_device text, p_workouts jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  w jsonb;
  v_accepted integer := 0;
  v_stale integer := 0;
  v_closed integer := 0;
  v_written integer;
  v_client timestamptz;
  v_held timestamptz;
  v_start timestamptz;
  v_end timestamptz;
  v_old record;
  v_ranges tstzrange[] := '{}';
  v_devices uuid[] := '{}';
  v_now timestamptz := clock_timestamp();
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_user is null or p_device is null
     or not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;
  if p_local_device is not null and p_local_device !~ '^[\x20-\x7e]{1,255}$' then
    raise exception 'invalid_local_device_id' using errcode = '22023';
  end if;
  if jsonb_typeof(p_workouts) is distinct from 'array' or jsonb_array_length(p_workouts) not between 1 and 50 then
    raise exception 'invalid_workouts' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_workouts) x
              where jsonb_typeof(x) is distinct from 'object' or octet_length(x::text) > 4096
                 or jsonb_typeof(x -> 'client_id') is distinct from 'string'
                 or (x ->> 'client_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                 or jsonb_typeof(x -> 'type') is distinct from 'string'
                 or jsonb_typeof(x -> 'started_at') is distinct from 'number'
                 or coalesce(jsonb_typeof(x -> 'ended_at'), 'null') not in ('null', 'number')
                 or jsonb_typeof(x -> 'client_updated_at') is distinct from 'number'
                 or coalesce(x ->> 'source', 'manual') not in ('manual', 'auto_ended')
                 or coalesce(jsonb_typeof(x -> 'deleted'), 'boolean') <> 'boolean'
                 or coalesce(jsonb_typeof(x -> 'notes'), 'null') not in ('null', 'string')
                 or length(coalesce(x ->> 'notes', '')) > 500
                 or (x ->> 'started_at')::double precision < 1577836800
                 or (x ->> 'started_at')::double precision > extract(epoch from v_now) + 120
                 or (x ->> 'client_updated_at')::double precision < 1577836800
                 or (jsonb_typeof(x -> 'ended_at') = 'number'
                     and ((x ->> 'ended_at')::double precision <= (x ->> 'started_at')::double precision
                          or (x ->> 'ended_at')::double precision - (x ->> 'started_at')::double precision > 86400
                          or (x ->> 'ended_at')::double precision > extract(epoch from v_now) + 120))) then
    raise exception 'invalid_workout' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_workouts) x
              where not exists (select 1 from public.workout_types t where t.id = x ->> 'type')) then
    raise exception 'invalid_workout_type' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct lower(x ->> 'client_id')) from jsonb_array_elements(p_workouts) x) then
    raise exception 'duplicate_client_id' using errcode = '22023';
  end if;

  -- Closed (and deleted) workouts first, then by start, so a stop and the next start in one batch never leave two
  -- open workouts.
  for w in select x from jsonb_array_elements(p_workouts) x
            order by (jsonb_typeof(x -> 'ended_at') = 'number' or coalesce((x ->> 'deleted')::boolean, false)) desc,
                     (x ->> 'started_at')::double precision loop
    v_client := to_timestamp((w ->> 'client_updated_at')::double precision);
    v_start := to_timestamp((w ->> 'started_at')::double precision);
    v_end := to_timestamp((w ->> 'ended_at')::double precision);
    select t.device_id, t.started_at, t.ended_at into v_old from public.user_workouts t
     where t.user_id = p_user and t.client_id = (w ->> 'client_id')::uuid;
    insert into public.user_workouts as t (user_id, client_id, device_id, local_device_id, source_id, workout_type,
        started_at, ended_at, source, notes, deleted_at, client_updated_at)
    values (p_user, (w ->> 'client_id')::uuid, p_device, p_local_device, p_source, w ->> 'type', v_start, v_end,
        coalesce(w ->> 'source', 'manual'), nullif(w ->> 'notes', ''),
        case when coalesce((w ->> 'deleted')::boolean, false) then v_client end, v_client)
    on conflict (user_id, client_id) do update set
        device_id = excluded.device_id, local_device_id = excluded.local_device_id, source_id = excluded.source_id,
        workout_type = excluded.workout_type, started_at = excluded.started_at, ended_at = excluded.ended_at,
        source = excluded.source, notes = excluded.notes,
        deleted_at = case when excluded.deleted_at is null then null else coalesce(t.deleted_at, excluded.deleted_at) end,
        client_updated_at = excluded.client_updated_at, updated_at = clock_timestamp()
      where excluded.client_updated_at > t.client_updated_at
         or (excluded.client_updated_at = t.client_updated_at
             and (t.device_id, t.local_device_id, t.workout_type, t.started_at, t.ended_at, t.source, t.notes,
                  t.deleted_at is null)
                 is distinct from
                 (excluded.device_id, excluded.local_device_id, excluded.workout_type, excluded.started_at,
                  excluded.ended_at, excluded.source, excluded.notes, excluded.deleted_at is null));
    get diagnostics v_written = row_count;
    if v_written = 0 then
      select t.client_updated_at into v_held from public.user_workouts t
       where t.user_id = p_user and t.client_id = (w ->> 'client_id')::uuid;
      if v_held > v_client then
        v_stale := v_stale + 1;
        continue;
      end if;
    else
      -- What changed: the new interval, and the old one when it moved.
      v_ranges := v_ranges || tstzrange(v_start, coalesce(v_end, v_start + interval '4 hours'), '[]');
      v_devices := v_devices || p_device;
      if v_old.started_at is not null then
        v_ranges := v_ranges
          || tstzrange(v_old.started_at, coalesce(v_old.ended_at, v_old.started_at + interval '4 hours'), '[]');
        v_devices := v_devices || v_old.device_id;
      end if;
    end if;
    v_accepted := v_accepted + 1;
  end loop;

  -- One workout runs at a time: an open workout followed by a later-starting open one ends at that start (never past
  -- its own 4-hour cap), flagged auto_ended. Its client_updated_at is left alone, so the phone's own later stop wins.
  with open as (
    select t.client_id, t.started_at, t.device_id,
           lead(t.started_at) over (order by t.started_at, t.client_id) as next_start
      from public.user_workouts t
     where t.user_id = p_user and t.ended_at is null and t.deleted_at is null)
  update public.user_workouts t
     set ended_at = greatest(least(o.next_start, t.started_at + interval '4 hours'), t.started_at + interval '1 second'),
         source = 'auto_ended', updated_at = clock_timestamp()
    from open o
   where t.user_id = p_user and t.client_id = o.client_id and o.next_start is not null;
  get diagnostics v_closed = row_count;

  -- Re-queue the local days the changes touch for the measurement-context builder (rebuilt by its pg_cron tick).
  if cardinality(v_ranges) > 0 and to_regclass('internal.measurement_context_work') is not null then
    insert into internal.measurement_context_work as q (user_id, device_id, day, queued_at)
    select p_user, x.device, x.day, v_now
      from (select distinct r.device, d::date as day
              from unnest(v_ranges, v_devices) r(span, device)
             cross join lateral generate_series(
                   (lower(r.span) at time zone internal.measurement_context_zone_at(p_user, lower(r.span)))::date,
                   (upper(r.span) at time zone internal.measurement_context_zone_at(p_user, upper(r.span)))::date,
                   interval '1 day') d
             where exists (select 1 from public.devices dv where dv.id = r.device and dv.user_id = p_user)) x
    on conflict (user_id, device_id, day) do update set queued_at = coalesce(q.queued_at, excluded.queued_at);
  end if;
  return jsonb_build_object('accepted', v_accepted, 'skipped_stale', v_stale, 'closed', v_closed);
end $$;
revoke all on function public.user_workouts_upsert_v1(uuid, uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.user_workouts_upsert_v1(uuid, uuid, uuid, text, jsonb) to service_role;

-- 5. Read (GET scores/workouts) -----------------------------------------------------------------------------------
-- The owner's workouts overlapping [p_from, p_to), one strap or every device of the owner (p_device NULL), oldest
-- first, at most p_limit (<= 500); deleted ones only when asked. Times are unix seconds; device_id is the strap's
-- external id; every workout carries its type's attributes from the catalogue ("saved by the type it is").
create or replace function public.user_workouts_read_v1(p_user uuid, p_device uuid, p_from timestamptz,
                                                        p_to timestamptz, p_limit integer default 500,
                                                        p_include_deleted boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_rows jsonb;
  v_count integer;
begin
  if auth.uid() is not null and auth.uid() is distinct from p_user then
    raise exception 'cross_user_caller' using errcode = '42501';
  end if;
  if p_user is null or p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range' using errcode = '22023';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then raise exception 'invalid_limit' using errcode = '22023'; end if;
  if p_device is not null
     and not exists (select 1 from public.devices d where d.id = p_device and d.user_id = p_user) then
    raise exception 'device_owner_mismatch' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(x.doc order by x.started_at, x.client_id), '[]'), count(*)
    into v_rows, v_count
    from (select w.started_at, w.client_id,
                 jsonb_build_object(
                   'client_id', w.client_id, 'device_id', d.external_device_id, 'local_device_id', w.local_device_id,
                   'type', w.workout_type, 'catalogue_version', w.catalogue_version,
                   'started_at', extract(epoch from w.started_at)::bigint,
                   'ended_at', extract(epoch from w.ended_at)::bigint,
                   'source', w.source, 'notes', w.notes, 'deleted', w.deleted_at is not null,
                   'attributes', jsonb_build_object(
                     'name', t.name, 'sport_name', t.sport_name, 'decoder_kind', t.decoder_kind,
                     'environment', t.environment, 'locomotion', t.locomotion, 'effort', t.effort,
                     'gait_expected', t.gait_expected, 'arm_motion', t.arm_motion,
                     'steps_expected', t.steps_expected),
                   'client_updated_at', extract(epoch from w.client_updated_at)::bigint,
                   'updated_at', extract(epoch from w.updated_at)::bigint) as doc
            from public.user_workouts w
            join public.devices d on d.id = w.device_id and d.user_id = w.user_id
            join public.workout_types t on t.id = w.workout_type
           where w.user_id = p_user and (p_device is null or w.device_id = p_device)
             and (p_include_deleted or w.deleted_at is null)
             and w.started_at < p_to and coalesce(w.ended_at, w.started_at + interval '4 hours') > p_from
           order by w.started_at, w.client_id
           limit p_limit + 1) x;
  return jsonb_build_object(
    'workouts', case when v_count > p_limit then v_rows - p_limit else v_rows end,
    'truncated', v_count > p_limit,
    'catalogue_version', (select max(t.version) from public.workout_types t));
end $$;
revoke all on function public.user_workouts_read_v1(uuid, uuid, timestamptz, timestamptz, integer, boolean)
  from public, anon, authenticated;
grant execute on function public.user_workouts_read_v1(uuid, uuid, timestamptz, timestamptz, integer, boolean)
  to service_role;

commit;
