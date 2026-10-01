-- In-app coach harness persistence. Additive only: two new columns on coach_messages, two new
-- tables, one function. The `coach` edge function reaches these with the service role after
-- resolving the installation identity, so RLS is enabled with no client policies (deny by default).

alter table public.coach_messages
  add column if not exists client_id uuid,
  add column if not exists meta jsonb not null default '{}'::jsonb;

-- Not partial: PostgREST `on_conflict=user_id,client_id` must match a plain unique index.
-- NULL client_id rows (legacy) never collide because NULLs are distinct.
create unique index if not exists coach_messages_user_client_uidx
  on public.coach_messages (user_id, client_id);

create table if not exists public.coach_memory_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (char_length(content) between 1 and 500),
  topic text not null default 'general',
  importance smallint not null default 3 check (importance between 1 and 5),
  created_at timestamptz not null default now()
);

create index if not exists coach_memory_items_user_rank_idx
  on public.coach_memory_items (user_id, importance desc, created_at desc);

create table if not exists public.coach_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  day date not null,
  calls integer not null default 0,
  primary key (user_id, day)
);

alter table public.coach_memory_items enable row level security;
alter table public.coach_usage enable row level security;

grant all on table public.coach_memory_items, public.coach_usage to service_role;

-- One model call against the owner's UTC-day budget. The conditional DO UPDATE makes the check and the
-- increment a single atomic statement: at the limit no row is returned, so parallel calls cannot overshoot.
create or replace function public.coach_take_quota(p_user_id uuid, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  used integer;
begin
  insert into public.coach_usage (user_id, day, calls)
  values (p_user_id, (now() at time zone 'utc')::date, 1)
  on conflict (user_id, day) do update
    set calls = public.coach_usage.calls + 1
    where public.coach_usage.calls < p_limit
  returning calls into used;
  return used is not null;
end;
$$;

revoke all on function public.coach_take_quota(uuid, integer) from public, anon, authenticated;
grant execute on function public.coach_take_quota(uuid, integer) to service_role;

comment on table public.coach_memory_items is 'Durable facts the in-app coach remembers about its owner. One row per fact; written only through the coach edge function.';
comment on table public.coach_usage is 'Per-owner per-UTC-day count of coach model calls (cost guard). Service role only.';
