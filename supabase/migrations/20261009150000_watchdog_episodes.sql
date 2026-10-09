-- Watchdog episodes and their annotations, synced from the phone (docs/context-watchdog/WATCHDOG_EPISODES.md).
--
-- WHY
-- The phone's Watchdog keeps a journal of every episode it opened (WatchdogEpisodeLedgerRow: severity, whether a
-- verified safety alert happened, whether and how the page was delivered, the evidence at the strongest tick, the
-- exercise context of rule exercise-session-1) and the wearer's optional note after a page
-- (WatchdogEpisodeAnnotation). Both lived only in UserDefaults on one phone, for 21 days: a reinstall lost them,
-- the server could not check an alarm against its own context, and the owner's gym-evening annotations
-- ("exertion: hard", "sensor: just_on") were never seen by anything that learns (audit A-watchdog D10, F-deploy).
-- This table is the account copy: one row per (owner, strap device, episode), last writer wins on the phone's own
-- client_updated_at, so a replayed or reordered upload never rolls a row back.
--
-- WHAT CHANGES
--   public.watchdog_episodes            one row per (user_id, device_id, episode_id). device_id is the canonical strap
--                                       device the scores route resolves (findNoopDevice, alias-aware), exactly as
--                                       every other device-scoped route. Scalars are columns; the evidence at the
--                                       peak (verdict), the context (exercise snapshot, activity label, canonical
--                                       quality reasons), the annotation and the versions are jsonb as the phone
--                                       sent them. Each episode is at most 16 KiB.
--   public.watchdog_episodes_upsert_v1  service only (POST scores/watchdog-episodes): at most 50 episodes per call,
--                                       validated again here, last-writer-wins, idempotent. Returns
--                                       {accepted, skipped_stale}.
--   public.watchdog_episodes_read_v1    service only (GET scores/watchdog-episodes): the episodes overlapping a
--                                       range in the wire shape, at most 500, oldest first.
-- RLS: the owner may select their own rows (authenticated); nobody but service_role writes. No trigger, no lock on
-- any other table.
--
-- Safe to re-run. Rollback: drop function public.watchdog_episodes_read_v1(uuid, uuid, timestamptz, timestamptz,
-- integer); drop function public.watchdog_episodes_upsert_v1(uuid, uuid, uuid, text, jsonb); drop table
-- public.watchdog_episodes.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table if not exists public.watchdog_episodes (
  user_id             uuid not null references auth.users(id) on delete cascade,
  device_id           uuid not null,
  episode_id          text not null check (episode_id ~ '^[A-Za-z0-9._:-]{1,128}$'),
  -- The id the phone knows the strap by locally ("my-whoop"), and the installation that sent this version.
  local_device_id     text check (local_device_id ~ '^[\x20-\x7e]{1,255}$'),
  source_id           uuid,
  opened_at           timestamptz not null,
  last_at             timestamptz not null,
  closed_at           timestamptz,
  max_severity        text not null check (max_severity in ('candidate', 'active', 'severe')),
  peak_severity       text check (peak_severity in ('withinLimits', 'note', 'candidate', 'active', 'severe',
                                                    'dataUnavailable')),
  -- A VERIFIED safety-extreme alert happened in this episode (not merely "reached severe").
  safety              boolean not null default false,
  personal_off        boolean not null default false,
  live_alerts         boolean not null default true,
  -- This episode's own page: '' never notified, else the notifier's outcome.
  notify_delivery     text not null default '' check (notify_delivery in ('', 'queued', 'sent', 'denied', 'failed',
                                                                         'skipped')),
  off_minute_count    integer not null default 0 check (off_minute_count between 0 and 1000000),
  unavailable_minutes integer not null default 0 check (unavailable_minutes between 0 and 1000000),
  -- What evaluate saw at the strongest tick: headline, event_label, contributing, signals.
  verdict             jsonb not null default '{}' check (jsonb_typeof(verdict) = 'object'),
  -- activity_label, exercise (WatchdogExerciseSnapshot), quality_reasons ([{code, certainty[, subcode]}]).
  context             jsonb not null default '{}' check (jsonb_typeof(context) = 'object'),
  -- WatchdogEpisodeAnnotation as the phone holds it, or NULL when there is none.
  annotation          jsonb check (annotation is null or jsonb_typeof(annotation) = 'object'),
  -- {watchdog, baseline, exercise_rule, reason_codes, ...}: what produced the row.
  versions            jsonb not null default '{}' check (jsonb_typeof(versions) = 'object'),
  client_updated_at   timestamptz not null,
  created_at          timestamptz not null default clock_timestamp(),
  updated_at          timestamptz not null default clock_timestamp(),
  primary key (user_id, device_id, episode_id),
  foreign key (user_id, device_id) references public.devices(user_id, id) on delete cascade,
  check (last_at >= opened_at),
  check (closed_at is null or closed_at >= opened_at),
  check (octet_length(verdict::text) + octet_length(context::text) + octet_length(coalesce(annotation, 'null')::text)
         + octet_length(versions::text) <= 16384)
);
comment on table public.watchdog_episodes is
  'Phone Watchdog episodes and annotations (20261009150000; docs/context-watchdog/WATCHDOG_EPISODES.md). One row per '
  '(owner, canonical strap device, episode). Written only through POST scores/watchdog-episodes '
  '(watchdog_episodes_upsert_v1, last writer wins on client_updated_at); the owner may read their own rows.';
comment on column public.watchdog_episodes.safety is 'A verified safety-extreme alert happened in this episode.';
comment on column public.watchdog_episodes.client_updated_at is
  'When the phone last changed this episode (its clock). The upsert keeps the newest; an older copy is skipped.';

create index if not exists watchdog_episodes_user_opened on public.watchdog_episodes (user_id, opened_at desc);

alter table public.watchdog_episodes enable row level security;
revoke all on public.watchdog_episodes from public, anon, authenticated;
grant select on public.watchdog_episodes to authenticated;
grant all on public.watchdog_episodes to service_role;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'watchdog_episodes'
                    and policyname = 'watchdog_episodes_select_own') then
    create policy watchdog_episodes_select_own on public.watchdog_episodes for select to authenticated
      using ((select auth.uid()) = user_id);
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'watchdog_episodes'
                    and policyname = 'watchdog_episodes_service') then
    create policy watchdog_episodes_service on public.watchdog_episodes for all to service_role
      using (true) with check (true);
  end if;
end $$;

-- The phone's episodes for one owner's device. The scores route validates first (_shared/watchdogEpisodes.ts); this
-- is the backstop: shape, sizes and enums are checked again (the table's CHECKs hold the enums), a batch with a
-- problem is refused whole. Last writer wins per episode on client_updated_at; an equal timestamp with different
-- content is the later arrival and wins; the same content again writes nothing. accepted = episodes the server
-- now holds as sent (written or already identical); skipped_stale = episodes the server holds a newer copy of.
create or replace function public.watchdog_episodes_upsert_v1(p_user uuid, p_device uuid, p_source uuid,
                                                              p_local_device text, p_episodes jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e jsonb;
  v_accepted integer := 0;
  v_stale integer := 0;
  v_written integer;
  v_client timestamptz;
  v_held timestamptz;
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
  if jsonb_typeof(p_episodes) is distinct from 'array' or jsonb_array_length(p_episodes) not between 1 and 50 then
    raise exception 'invalid_episodes' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_episodes) x
              where jsonb_typeof(x) is distinct from 'object' or octet_length(x::text) > 16384
                 or jsonb_typeof(x -> 'episode_id') is distinct from 'string'
                 or jsonb_typeof(x -> 'opened_at') is distinct from 'number'
                 or jsonb_typeof(x -> 'last_at') is distinct from 'number'
                 or jsonb_typeof(x -> 'client_updated_at') is distinct from 'number'
                 or coalesce(jsonb_typeof(x -> 'closed_at'), 'null') not in ('null', 'number')
                 or jsonb_typeof(x -> 'max_severity') is distinct from 'string'
                 or coalesce(jsonb_typeof(x -> 'safety'), 'boolean') <> 'boolean'
                 or coalesce(jsonb_typeof(x -> 'personal_off'), 'boolean') <> 'boolean'
                 or coalesce(jsonb_typeof(x -> 'live_alerts'), 'boolean') <> 'boolean'
                 or coalesce(jsonb_typeof(x -> 'versions'), 'null') not in ('null', 'object')
                 or coalesce(jsonb_typeof(x -> 'exercise'), 'null') not in ('null', 'object')
                 or coalesce(jsonb_typeof(x -> 'annotation'), 'null') not in ('null', 'object')
                 or coalesce(jsonb_typeof(x -> 'signals'), 'null') not in ('null', 'array')
                 or coalesce(jsonb_typeof(x -> 'contributing'), 'null') not in ('null', 'array')
                 or coalesce(jsonb_typeof(x -> 'quality_reasons'), 'null') not in ('null', 'array')) then
    raise exception 'invalid_episode' using errcode = '22023';
  end if;
  if (select count(*) <> count(distinct x ->> 'episode_id') from jsonb_array_elements(p_episodes) x) then
    raise exception 'duplicate_episode_id' using errcode = '22023';
  end if;
  -- Every canonical quality reason must name a registered code.
  if exists (select 1 from jsonb_array_elements(p_episodes) x
              cross join lateral jsonb_array_elements(case when jsonb_typeof(x -> 'quality_reasons') = 'array'
                                                          then x -> 'quality_reasons' else '[]' end) r
              where jsonb_typeof(r) is distinct from 'object'
                 or not exists (select 1 from public.reason_codes c where c.code = r ->> 'code')
                 or coalesce(r ->> 'certainty', '') not in ('confirmed', 'inferred', 'unknown', 'measured')) then
    raise exception 'invalid_quality_reasons' using errcode = '22023';
  end if;

  for e in select x from jsonb_array_elements(p_episodes) x loop
    v_client := to_timestamp((e ->> 'client_updated_at')::double precision);
    insert into public.watchdog_episodes as t (user_id, device_id, episode_id, local_device_id, source_id, opened_at,
        last_at, closed_at, max_severity, peak_severity, safety, personal_off, live_alerts, notify_delivery,
        off_minute_count, unavailable_minutes, verdict, context, annotation, versions, client_updated_at)
    values (p_user, p_device, e ->> 'episode_id', p_local_device, p_source,
        to_timestamp((e ->> 'opened_at')::double precision), to_timestamp((e ->> 'last_at')::double precision),
        to_timestamp((e ->> 'closed_at')::double precision), e ->> 'max_severity', e ->> 'peak_severity',
        coalesce((e ->> 'safety')::boolean, false), coalesce((e ->> 'personal_off')::boolean, false),
        coalesce((e ->> 'live_alerts')::boolean, true), coalesce(e ->> 'notify_delivery', ''),
        coalesce((e ->> 'off_minute_count')::integer, 0), coalesce((e ->> 'unavailable_minutes')::integer, 0),
        -- Absent and null members are left out at the top level only; nested objects are kept exactly as sent.
        (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(jsonb_build_object(
            'headline', e -> 'headline', 'event_label', e -> 'event_label', 'contributing', e -> 'contributing',
            'signals', e -> 'signals')) m(k, v) where jsonb_typeof(v) <> 'null'),
        (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(jsonb_build_object(
            'activity_label', e -> 'activity_label', 'exercise', e -> 'exercise',
            'quality_reasons', e -> 'quality_reasons')) m(k, v) where jsonb_typeof(v) <> 'null'),
        case when jsonb_typeof(e -> 'annotation') = 'object' then e -> 'annotation' end,
        coalesce(e -> 'versions', '{}'), v_client)
    on conflict (user_id, device_id, episode_id) do update set
        local_device_id = excluded.local_device_id, source_id = excluded.source_id, opened_at = excluded.opened_at,
        last_at = excluded.last_at, closed_at = excluded.closed_at, max_severity = excluded.max_severity,
        peak_severity = excluded.peak_severity, safety = excluded.safety, personal_off = excluded.personal_off,
        live_alerts = excluded.live_alerts, notify_delivery = excluded.notify_delivery,
        off_minute_count = excluded.off_minute_count, unavailable_minutes = excluded.unavailable_minutes,
        verdict = excluded.verdict, context = excluded.context, annotation = excluded.annotation,
        versions = excluded.versions, client_updated_at = excluded.client_updated_at,
        updated_at = clock_timestamp()
      where excluded.client_updated_at > t.client_updated_at
         or (excluded.client_updated_at = t.client_updated_at
             and (t.local_device_id, t.opened_at, t.last_at, t.closed_at, t.max_severity, t.peak_severity, t.safety,
                  t.personal_off, t.live_alerts, t.notify_delivery, t.off_minute_count, t.unavailable_minutes,
                  t.verdict, t.context, t.annotation, t.versions)
                 is distinct from
                 (excluded.local_device_id, excluded.opened_at, excluded.last_at, excluded.closed_at,
                  excluded.max_severity, excluded.peak_severity, excluded.safety, excluded.personal_off,
                  excluded.live_alerts, excluded.notify_delivery, excluded.off_minute_count,
                  excluded.unavailable_minutes, excluded.verdict, excluded.context, excluded.annotation,
                  excluded.versions));
    get diagnostics v_written = row_count;
    if v_written = 0 then
      select t.client_updated_at into v_held from public.watchdog_episodes t
       where t.user_id = p_user and t.device_id = p_device and t.episode_id = e ->> 'episode_id';
      if v_held > v_client then
        v_stale := v_stale + 1;
        continue;
      end if;
    end if;
    v_accepted := v_accepted + 1;
  end loop;
  return jsonb_build_object('accepted', v_accepted, 'skipped_stale', v_stale);
end $$;
revoke all on function public.watchdog_episodes_upsert_v1(uuid, uuid, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.watchdog_episodes_upsert_v1(uuid, uuid, uuid, text, jsonb) to service_role;

-- The owner's episodes overlapping [p_from, p_to) (opened before p_to, last seen at or after p_from), one device or
-- every device of the owner when p_device is NULL, oldest first, at most p_limit (<= 500). Times are unix seconds,
-- keys as the phone sends them, device_id the device's external id (the strap's whoop-<serial>).
create or replace function public.watchdog_episodes_read_v1(p_user uuid, p_device uuid, p_from timestamptz,
                                                            p_to timestamptz, p_limit integer default 500)
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
  select coalesce(jsonb_agg(x.doc order by x.opened_at, x.episode_id), '[]'), count(*)
    into v_rows, v_count
    from (select w.opened_at, w.episode_id,
                 jsonb_build_object(
                   'episode_id', w.episode_id, 'device_id', d.external_device_id,
                   'local_device_id', w.local_device_id,
                   'opened_at', extract(epoch from w.opened_at)::bigint,
                   'last_at', extract(epoch from w.last_at)::bigint,
                   'closed_at', extract(epoch from w.closed_at)::bigint,
                   'max_severity', w.max_severity, 'peak_severity', w.peak_severity, 'safety', w.safety,
                   'personal_off', w.personal_off, 'notify_delivery', w.notify_delivery,
                   'live_alerts', w.live_alerts, 'off_minute_count', w.off_minute_count,
                   'unavailable_minutes', w.unavailable_minutes,
                   'headline', w.verdict -> 'headline', 'event_label', w.verdict -> 'event_label',
                   'activity_label', w.context -> 'activity_label', 'contributing', w.verdict -> 'contributing',
                   'signals', w.verdict -> 'signals', 'exercise', w.context -> 'exercise',
                   'quality_reasons', w.context -> 'quality_reasons', 'annotation', w.annotation,
                   'versions', w.versions,
                   'client_updated_at', extract(epoch from w.client_updated_at)::bigint,
                   'updated_at', extract(epoch from w.updated_at)::bigint) as doc
            from public.watchdog_episodes w
            join public.devices d on d.id = w.device_id and d.user_id = w.user_id
           where w.user_id = p_user and (p_device is null or w.device_id = p_device)
             and w.opened_at < p_to and greatest(w.last_at, coalesce(w.closed_at, w.last_at)) >= p_from
           order by w.opened_at, w.episode_id
           limit p_limit + 1) x;
  return jsonb_build_object(
    'episodes', case when v_count > p_limit then v_rows - p_limit else v_rows end,
    'truncated', v_count > p_limit);
end $$;
revoke all on function public.watchdog_episodes_read_v1(uuid, uuid, timestamptz, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.watchdog_episodes_read_v1(uuid, uuid, timestamptz, timestamptz, integer)
  to service_role;

commit;
