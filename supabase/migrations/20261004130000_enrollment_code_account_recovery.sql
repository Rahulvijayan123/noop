-- Recover a pre-Auth account with its enrollment code.
--
-- Before Supabase Auth, ops created each tester's account and handed out an enrollment code; the
-- tester never had a sign-in of their own. Everything that tester uploaded is owned by that account
-- (auth.users.id), across ~150 tables, and a source id can never change owner. So recovery does not
-- move data. It moves the sign-in: a tester signs up and verifies their address as a NEW, empty
-- account, then presents their enrollment code; this function transfers that verified email and
-- password onto the legacy account the code belongs to and deletes the empty new one. The tester
-- then signs in as the account that already owns their history, and the existing provisioning path
-- adopts the phone's legacy installation (`upgraded`).
--
-- Trust boundary: the Edge function validates the caller's Supabase JWT against Auth, requires a
-- confirmed address, and passes only the verified user id and the code's peppered HMAC. The
-- plaintext code never reaches Postgres. Holding the code is the proof of ownership — the same
-- proof legacy enrollment accepted — so a code is accepted after it expired or was redeemed, but
-- never after it was revoked, and each legacy account can be recovered exactly once.
begin;

create table public.noop_account_recoveries (
  id uuid primary key default gen_random_uuid(),
  legacy_user_id uuid not null unique references auth.users(id) on delete cascade,
  enrollment_code_id uuid not null references public.noop_enrollment_codes(id) on delete cascade,
  -- The verified sign-up that was folded into the legacy account. It no longer exists.
  replaced_user_id uuid not null,
  recovered_at timestamptz not null default clock_timestamp()
);

alter table public.noop_account_recoveries enable row level security;
revoke all on table public.noop_account_recoveries from public, anon, authenticated;
grant all on table public.noop_account_recoveries to service_role;

-- Every attempt, kept outside the outcome's transaction semantics (the RPC returns rather than
-- raises for expected failures, so a wrong code is still recorded). No foreign key: a successful
-- attempt's user is deleted by that same attempt.
create table public.noop_account_recovery_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  outcome text not null,
  attempted_at timestamptz not null default clock_timestamp()
);

create index noop_account_recovery_attempts_user_idx
  on public.noop_account_recovery_attempts (user_id, attempted_at desc);

alter table public.noop_account_recovery_attempts enable row level security;
revoke all on table public.noop_account_recovery_attempts from public, anon, authenticated;
grant all on table public.noop_account_recovery_attempts to service_role;

-- Outcomes (jsonb.status):
--   recovered          the caller's sign-in now belongs to the legacy account (jsonb.userId)
--   invalid_code       no live code has this hash
--   rate_limited       too many wrong codes from this account in the last hour
--   email_not_confirmed
--   same_account       the caller is already signed in as the code's account; nothing to do
--   already_recovered  the code's account was recovered before
--   account_active     the code's account already signs in through Supabase Auth
--   account_not_empty  the caller's account already has installations or devices of its own
create function public.recover_noop_account_from_enrollment(
  p_new_user uuid,
  p_code_hash text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_failures_per_hour constant integer := 10;
  v_now timestamptz := clock_timestamp();
  v_new auth.users%rowtype;
  v_code public.noop_enrollment_codes%rowtype;
  v_legacy uuid;
  v_status text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'recovery_service_role_required' using errcode = '42501';
  end if;
  if p_new_user is null or p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'recovery_request_invalid' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('account-recovery:' || p_new_user::text, 0));

  if (select count(*) from public.noop_account_recovery_attempts a
      where a.user_id = p_new_user and a.outcome = 'invalid_code'
        and a.attempted_at > v_now - interval '1 hour') >= c_max_failures_per_hour then
    v_status := 'rate_limited';
  end if;

  if v_status is null then
    select u.* into v_new from auth.users u where u.id = p_new_user for update;
    if not found or v_new.deleted_at is not null or coalesce(v_new.is_anonymous, false)
        or v_new.email is null or v_new.email_confirmed_at is null then
      v_status := 'email_not_confirmed';
    end if;
  end if;

  if v_status is null then
    select c.* into v_code from public.noop_enrollment_codes c
    where c.code_hash = p_code_hash and c.revoked_at is null
    order by c.created_at desc
    limit 1;
    if not found then
      v_status := 'invalid_code';
    else
      v_legacy := v_code.user_id;
      if v_legacy = p_new_user then
        v_status := 'same_account';
      end if;
    end if;
  end if;

  if v_status is null then
    -- Same admission lock provisioning takes, in a fixed order, so neither account can gain or lose
    -- an installation while its sign-in moves.
    perform pg_advisory_xact_lock(hashtextextended('account-admission:' || least(v_legacy, p_new_user)::text, 0));
    perform pg_advisory_xact_lock(hashtextextended('account-admission:' || greatest(v_legacy, p_new_user)::text, 0));

    perform 1 from auth.users u where u.id = v_legacy and u.deleted_at is null for update;
    if not found then
      v_status := 'invalid_code';
    elsif exists (select 1 from public.noop_account_recoveries r where r.legacy_user_id = v_legacy) then
      v_status := 'already_recovered';
    elsif exists (select 1 from public.noop_app_installations i
                  where i.user_id = v_legacy and i.provisioning_method = 'supabase_auth') then
      v_status := 'account_active';
    elsif exists (select 1 from public.noop_app_installations i where i.user_id = p_new_user)
        or exists (select 1 from public.devices d where d.user_id = p_new_user) then
      v_status := 'account_not_empty';
    end if;
  end if;

  if v_status is not null then
    insert into public.noop_account_recovery_attempts (user_id, outcome, attempted_at)
    values (p_new_user, v_status, v_now);
    return jsonb_build_object('status', v_status);
  end if;

  -- The new account is empty by the checks above; deleting it frees its address for the legacy one.
  delete from auth.refresh_tokens t where t.user_id = p_new_user::text;
  delete from auth.users u where u.id = p_new_user;

  update auth.users u
  set email = v_new.email,
      encrypted_password = v_new.encrypted_password,
      email_confirmed_at = v_new.email_confirmed_at,
      confirmation_token = '',
      confirmation_sent_at = null,
      recovery_token = '',
      recovery_sent_at = null,
      email_change = '',
      email_change_token_new = '',
      email_change_token_current = '',
      email_change_confirm_status = 0,
      reauthentication_token = '',
      is_anonymous = false,
      raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb)
        || jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      updated_at = v_now
  where u.id = v_legacy;

  update auth.identities i
  set identity_data = coalesce(i.identity_data, '{}'::jsonb) || jsonb_build_object(
        'sub', v_legacy::text, 'email', v_new.email, 'email_verified', true, 'phone_verified', false),
      updated_at = v_now
  where i.user_id = v_legacy and i.provider = 'email';
  if not found then
    insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
    values (v_legacy::text, v_legacy, jsonb_build_object(
        'sub', v_legacy::text, 'email', v_new.email, 'email_verified', true, 'phone_verified', false),
      'email', v_now, v_now);
  end if;

  -- Whatever could sign in as the legacy account before (an ops password, an old session) cannot now.
  delete from auth.refresh_tokens t where t.user_id = v_legacy::text;
  delete from auth.sessions s where s.user_id = v_legacy;
  delete from auth.one_time_tokens o where o.user_id = v_legacy;

  insert into public.noop_account_recoveries (legacy_user_id, enrollment_code_id, replaced_user_id, recovered_at)
  values (v_legacy, v_code.id, p_new_user, v_now);
  insert into public.noop_account_recovery_attempts (user_id, outcome, attempted_at)
  values (p_new_user, 'recovered', v_now);

  return jsonb_build_object('status', 'recovered', 'userId', v_legacy);
end;
$$;

revoke all on function public.recover_noop_account_from_enrollment(uuid, text)
  from public, anon, authenticated;
grant execute on function public.recover_noop_account_from_enrollment(uuid, text) to service_role;

comment on function public.recover_noop_account_from_enrollment(uuid, text) is
  'Moves a verified sign-up''s email and password onto the pre-Auth account its enrollment code belongs to, then deletes the empty sign-up. Service role only.';
comment on table public.noop_account_recoveries is
  'One row per pre-Auth account recovered with its enrollment code; enforces at most one recovery per account.';
comment on table public.noop_account_recovery_attempts is
  'Every enrollment-code recovery attempt, for the per-account hourly wrong-code limit.';

commit;
