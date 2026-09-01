-- Adds email to the account (sign-in switches from username to email),
-- server-side username-length enforcement, and the OTP infrastructure
-- behind both "forgot password" and signup email verification.
--
-- Same hashing convention as the rest of this app: passwords are hashed
-- client-side (sha256) before ever reaching the server (see
-- root_gatekeeper.dart) and only the hash is compared/stored here. OTP
-- codes follow the identical pattern — a Supabase Edge Function generates
-- the plaintext code and emails it, but only ever stores/compares its
-- sha256 hash, computed the same way client-side once the user types the
-- code back in. Nothing in this file ever sees a plaintext password or
-- OTP.
--
-- What this file does NOT do: actually send email. That needs an outbound
-- HTTP call to an email provider, which Postgres can't do on its own —
-- see supabase/functions/send-password-reset-otp and
-- supabase/functions/send-verification-email for the sending side. This
-- migration only prepares the DB-only half (schema + the RPCs that verify
-- a code someone already received).

-- ---------------------------------------------------------------------------
-- 1. Email on the account. Nullable for now — existing accounts created
--    before this migration have no email on file and will need to set one
--    via Account Management > Change Email before they can use email
--    sign-in; new sign-ups always provide one. Unique on lower(email) so
--    "Person@X.com" and "person@x.com" can't both register.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists email text,
  add column if not exists email_verified boolean not null default false;

drop index if exists public.profiles_email_unique;
create unique index profiles_email_unique
  on public.profiles (lower(email))
  where email is not null;

-- ---------------------------------------------------------------------------
-- 2. Username length, enforced server-side too (the client already checks
--    this before submitting — see password_policy.dart — this is defense
--    in depth against a modified/older client).
--
--    NOT VALID: applies to every new INSERT/UPDATE from this point on
--    without Postgres retroactively checking every existing row first —
--    plain `ADD CONSTRAINT` fails outright (23514) the moment any account
--    already on file (test accounts made before this rule existed, an
--    early short admin username, etc.) doesn't fit, which blocks the
--    migration from ever completing. Left permanently NOT VALID rather
--    than following up with VALIDATE CONSTRAINT — validating would hit
--    the exact same pre-existing rows and fail the same way; there's
--    nothing wrong with those accounts that a grandfather clause doesn't
--    already solve.
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_username_length_check;
alter table public.profiles
  add constraint profiles_username_length_check
  check (char_length(username) >= 3 and char_length(username) <= 20)
  not valid;

-- ---------------------------------------------------------------------------
-- 3. signup_hops_user — now takes and stores p_email. Dropped first: adding
--    a required parameter changes the function's identity, and (like 0001)
--    this may re-run after a partial prior attempt.
--
--    unique_violation is now ambiguous (username OR email could collide) —
--    GET STACKED DIAGNOSTICS pulls back which constraint actually fired so
--    the client can tell the user which field to change, instead of one
--    generic "something's taken" for both.
-- ---------------------------------------------------------------------------
-- Both signatures: the pre-email 3-argument form this migration replaces,
-- and the 4-argument form it creates below. Dropping only the former means
-- re-running this file hits 42723 ("function already exists with same
-- argument types") on the CREATE, since the thing actually in the way is
-- the version this file made last time.
drop function if exists public.signup_hops_user(text, text, text);
drop function if exists public.signup_hops_user(text, text, text, text);

create function public.signup_hops_user(
  p_username text,
  p_email text,
  p_public_key text,
  p_password_hash text
) returns table (id uuid, hops_token text, token_expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := gen_random_uuid();
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz := (now() at time zone 'utc') + interval '24 hours';
  v_constraint text;
begin
  if char_length(p_username) < 3 or char_length(p_username) > 20 then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  if p_email is null or p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;

  insert into public.profiles (id, username, email, public_key, password_hash, hops_token, token_expires_at)
  values (v_id, p_username, lower(p_email), p_public_key, p_password_hash, v_token, v_expires);

  return query select v_id, v_token, v_expires;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'profiles_email_unique' then
      raise exception 'email_taken' using errcode = '23505';
    else
      raise exception 'username_taken' using errcode = '23505';
    end if;
end;
$$;

revoke all on function public.signup_hops_user(text, text, text, text) from public;
grant execute on function public.signup_hops_user(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. signin_hops_user_by_email — mirrors signin_hops_user's shape (same
--    "found but wrong password" vs. "not found" collapse, for the same
--    enumeration-resistance reason) but looks up by email instead of
--    username. The old username-based signin_hops_user is left in place
--    unchanged — nothing currently calls it after this, but nothing about
--    it is wrong, and removing it isn't necessary.
-- ---------------------------------------------------------------------------
create or replace function public.signin_hops_user_by_email(
  p_email text,
  p_password_hash text
) returns table (
  id uuid, username text, public_key text, hops_token text,
  token_expires_at timestamptz, role text, admin_title text, email_verified boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz := (now() at time zone 'utc') + interval '24 hours';
begin
  select * into v_row from public.profiles p where lower(p.email) = lower(p_email);

  if not found or v_row.password_hash is distinct from p_password_hash then
    return; -- empty result set — client treats as invalid credentials
  end if;

  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where id = v_row.id;

  return query select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
    v_row.role, v_row.admin_title, v_row.email_verified;
end;
$$;

revoke all on function public.signin_hops_user_by_email(text, text) from public;
grant execute on function public.signin_hops_user_by_email(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. change_hops_email — same verify-then-act shape as change_hops_password
--    (0006). Flips email_verified back to false on change, since whatever
--    verified the old address says nothing about ownership of the new one
--    — the caller is expected to immediately kick off the same
--    verification-email flow used at signup.
-- ---------------------------------------------------------------------------
create or replace function public.change_hops_email(
  p_hops_token text,
  p_password_hash text,
  p_new_email text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
begin
  if p_new_email is null or p_new_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;

  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_password_hash then
    return false;
  end if;

  begin
    update public.profiles
      set email = lower(p_new_email), email_verified = false
      where id = v_row.id;
  exception
    when unique_violation then
      raise exception 'email_taken' using errcode = '23505';
  end;

  return true;
end;
$$;

revoke all on function public.change_hops_email(text, text, text) from public;
grant execute on function public.change_hops_email(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 6. Password-reset OTPs. One row per request; old unused rows for the
--    same email are left alone (they'll simply lose the race — only the
--    newest matching, unused, unexpired row can ever succeed, and expiry
--    plus the attempts cap below bound how long a stale one stays live).
-- ---------------------------------------------------------------------------
create table if not exists public.password_reset_otps (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  otp_hash text not null,
  expires_at timestamptz not null,
  used boolean not null default false,
  attempts int not null default 0,
  created_at timestamptz not null default (now() at time zone 'utc')
);

create index if not exists password_reset_otps_email_idx on public.password_reset_otps (lower(email));

alter table public.password_reset_otps enable row level security;
revoke all on public.password_reset_otps from anon, authenticated;

-- Verification only — creating a row (with the plaintext code, before
-- hashing it for storage) is the Edge Function's job via its service-role
-- key, which bypasses these grants entirely. This RPC only ever sees a
-- hash, never the plaintext code.
create or replace function public.verify_password_reset_otp(
  p_email text,
  p_otp_hash text,
  p_new_password_hash text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_otp public.password_reset_otps%rowtype;
  v_profile_id uuid;
begin
  select * into v_otp
    from public.password_reset_otps
    where lower(email) = lower(p_email)
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.password_reset_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  select id into v_profile_id from public.profiles where lower(email) = lower(p_email);
  if v_profile_id is null then
    return false;
  end if;

  update public.password_reset_otps set used = true where id = v_otp.id;
  update public.profiles set password_hash = p_new_password_hash where id = v_profile_id;

  return true;
end;
$$;

revoke all on function public.verify_password_reset_otp(text, text, text) from public;
grant execute on function public.verify_password_reset_otp(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 7. Signup / change-email verification OTPs — same shape as password
--    reset, keyed to a profile via hops_token (the account already exists
--    and is signed in at this point) rather than a bare email.
-- ---------------------------------------------------------------------------
create table if not exists public.email_verification_otps (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  otp_hash text not null,
  expires_at timestamptz not null,
  used boolean not null default false,
  attempts int not null default 0,
  created_at timestamptz not null default (now() at time zone 'utc')
);

create index if not exists email_verification_otps_profile_idx on public.email_verification_otps (profile_id);

alter table public.email_verification_otps enable row level security;
revoke all on public.email_verification_otps from anon, authenticated;

create or replace function public.verify_signup_email_otp(
  p_hops_token text,
  p_otp_hash text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile_id uuid;
  v_otp public.email_verification_otps%rowtype;
begin
  select id into v_profile_id
    from public.profiles
    where hops_token = p_hops_token
      and token_expires_at > (now() at time zone 'utc');

  if v_profile_id is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  select * into v_otp
    from public.email_verification_otps
    where profile_id = v_profile_id
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.email_verification_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  update public.email_verification_otps set used = true where id = v_otp.id;
  update public.profiles set email_verified = true where id = v_profile_id;

  return true;
end;
$$;

revoke all on function public.verify_signup_email_otp(text, text) from public;
grant execute on function public.verify_signup_email_otp(text, text) to anon;
