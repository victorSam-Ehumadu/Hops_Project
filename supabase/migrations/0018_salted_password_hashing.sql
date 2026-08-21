-- Salts password_hash. Until now every password was plain
-- sha256(password), client-side, with nothing else mixed in — vulnerable
-- to a precomputed rainbow-table lookup, and worse, means any two accounts
-- that happen to share a password are instantly recognizable as sharing it
-- (identical hash) from the hash column alone. Real risk today is low —
-- the table is fully RLS-locked and only reachable through these
-- SECURITY DEFINER RPCs (see 0001_lockdown_profiles.sql) — but it's the
-- one piece of the auth design that hadn't kept pace with how careful
-- everything around it already is.
--
-- See client/lib/utils/mesh_crypto.dart's header comment for the full
-- client-side half of this (that file's the one place hashSaltedPassword/
-- generatePasswordSalt/fetchPasswordSaltForEmail/fetchMyPasswordSalt live)
-- — short version: the client still always hashes before anything ever
-- reaches the server (an existing, deliberate rule — see 0001's comment),
-- which means the server can't salt on the client's behalf the way a
-- typical server-side bcrypt call would. Instead the client asks the
-- server for the (non-secret) salt first when it doesn't already know it.
--
-- Existing accounts get password_salt = '' below — hashSaltedPassword
-- treats an empty salt as a no-op prefix, so their existing sha256(password)
-- hash keeps matching with no migration of the hash itself needed. They
-- pick up a real salt automatically the next time that password changes
-- (change-password, or a forgot-password reset).

alter table public.profiles
  add column if not exists password_salt text not null default '';

-- ---------------------------------------------------------------------------
-- 1. Pre-authentication salt lookup, for sign-in. Enumeration-resistant the
--    same way signin_hops_user_by_email's collapsed error already is: an
--    email with no account gets a deterministic, salt-shaped value derived
--    from the email itself rather than an error or an empty string, so
--    this step alone can't be used to tell which emails are registered.
--    Deterministic (not random) so repeated lookups for the same
--    nonexistent email don't visibly change on each call either.
-- ---------------------------------------------------------------------------
create or replace function public.get_password_salt_by_email(
  p_email text
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_salt text;
begin
  select password_salt into v_salt
    from public.profiles
    where lower(email) = lower(p_email);

  if v_salt is not null then
    return v_salt;
  end if;

  return encode(digest('hops-no-such-account:' || lower(p_email), 'sha256'), 'hex');
end;
$$;

revoke all on function public.get_password_salt_by_email(text) from public;
grant execute on function public.get_password_salt_by_email(text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Post-authentication salt lookup — change-password/change-email/
--    delete-account all re-confirm the CURRENT password, and need this
--    account's own salt to reproduce a comparable hash. A live hops_token
--    is already proof of who's asking, so no enumeration-safe fallback is
--    needed here the way there is above.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_password_salt(
  p_hops_token text
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_salt text;
begin
  select password_salt into v_salt
    from public.profiles
    where hops_token = p_hops_token
      and token_expires_at > (now() at time zone 'utc');

  if v_salt is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  return v_salt;
end;
$$;

revoke all on function public.get_my_password_salt(text) from public;
grant execute on function public.get_my_password_salt(text) to anon;

-- ---------------------------------------------------------------------------
-- 3. signup_hops_user now takes and stores the salt the client generated
--    for this brand-new password. Dropped first — adding a parameter
--    changes the function's identity, same reasoning as every prior
--    migration that's touched this function's signature.
-- ---------------------------------------------------------------------------
drop function if exists public.signup_hops_user(text, text, text, text);

create function public.signup_hops_user(
  p_username text,
  p_email text,
  p_public_key text,
  p_password_hash text,
  p_password_salt text
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

  insert into public.profiles (id, username, email, public_key, password_hash, password_salt, hops_token, token_expires_at)
  values (v_id, p_username, lower(p_email), p_public_key, p_password_hash, coalesce(p_password_salt, ''), v_token, v_expires);

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

revoke all on function public.signup_hops_user(text, text, text, text, text) from public;
grant execute on function public.signup_hops_user(text, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. change_hops_password now also takes the fresh salt generated for the
--    NEW password. The old-password check is unchanged — the client
--    already fetched its own current salt via get_my_password_salt before
--    calling this, same as it always fetched the old hash to compare.
-- ---------------------------------------------------------------------------
drop function if exists public.change_hops_password(text, text, text);

create function public.change_hops_password(
  p_hops_token text,
  p_old_password_hash text,
  p_new_password_hash text,
  p_new_password_salt text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
begin
  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_old_password_hash then
    return false;
  end if;

  update public.profiles
    set password_hash = p_new_password_hash,
        password_salt = coalesce(p_new_password_salt, '')
    where id = v_row.id;

  return true;
end;
$$;

revoke all on function public.change_hops_password(text, text, text, text) from public;
grant execute on function public.change_hops_password(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. verify_password_reset_otp — the "forgot password" flow also sets a
--    brand-new password with no prior session to fetch a salt from, so it
--    needs the same new-salt parameter change_hops_password just got.
-- ---------------------------------------------------------------------------
drop function if exists public.verify_password_reset_otp(text, text, text);

create function public.verify_password_reset_otp(
  p_email text,
  p_otp_hash text,
  p_new_password_hash text,
  p_new_password_salt text
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
  update public.profiles
    set password_hash = p_new_password_hash,
        password_salt = coalesce(p_new_password_salt, '')
    where id = v_profile_id;

  return true;
end;
$$;

revoke all on function public.verify_password_reset_otp(text, text, text, text) from public;
grant execute on function public.verify_password_reset_otp(text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Standing note: delete_hops_user and change_hops_email both re-confirm the
-- CURRENT password only (no new password involved), so neither needs a new
-- parameter here — the client fetches the existing salt via
-- get_my_password_salt the same way change_hops_password's old-password
-- check does, and both functions are left exactly as 0006/0007 defined them.
-- ---------------------------------------------------------------------------
