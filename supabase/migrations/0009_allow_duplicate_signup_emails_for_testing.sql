-- TESTING ONLY: temporarily allows multiple Hops accounts to share one
-- email address, so a handful of test emails can be spread across more
-- devices/accounts than there are emails to go around (e.g. 2 emails across
-- 3 phones). This is a deliberate, scoped relaxation of the uniqueness
-- 0007 added — revert before this app is used by real users again (see
-- "TO REVERT" at the bottom).
--
-- What changes:
--   1. profiles_email_unique is dropped, so signup_hops_user's INSERT no
--      longer raises unique_violation on a repeated email. (Its exception
--      handler still checks for that constraint name — harmless, it just
--      never matches anymore, so every unique_violation from here on is a
--      username collision.)
--   2. signin_hops_user_by_email now matches on (email, password_hash)
--      together instead of looking up by email alone and checking the
--      password after. With duplicate emails possible, an email-only
--      lookup would grab whichever matching row Postgres happened to scan
--      first, and the password check that ran *after* that lookup would
--      then reject a correct password that actually belonged to a
--      *different* account sharing the same email. Folding the password
--      into the WHERE clause picks the right row outright — and still
--      collapses "no such email" and "wrong password" into the same empty
--      result, preserving the enumeration-resistance the function already
--      had. Otherwise identical to 0008's version (banned check, role-based
--      token expiry, the qualified `public.profiles.id` fix).
--
-- What's NOT handled (out of scope for a testing-only change — flag if it
-- becomes a real problem): verify_password_reset_otp and
-- verify_signup_email_otp both still do a plain `where lower(email) = ...`
-- lookup with nothing to disambiguate multiple accounts on the same email,
-- so "forgot password" against a duplicated email will nondeterministically
-- target one of the accounts sharing it. Don't rely on those flows while
-- testing with shared emails — sign in directly with username/password-tied
-- credentials instead.
--
-- TO REVERT (once every account has its own real email again):
--   1. Make sure no two profiles share an email (delete/consolidate test
--      accounts as needed).
--   2. Re-run:
--        create unique index profiles_email_unique
--          on public.profiles (lower(email)) where email is not null;
--   3. signin_hops_user_by_email is safe to leave exactly as this migration
--      leaves it — matching on (email, password_hash) is still correct once
--      emails are unique again, it's just no longer load-bearing.
-- ---------------------------------------------------------------------------

drop index if exists public.profiles_email_unique;

drop function if exists public.signin_hops_user_by_email(text, text);

create function public.signin_hops_user_by_email(
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
  v_expires timestamptz;
begin
  -- Matches email AND password together (see comment above) — with
  -- duplicate emails now allowed, this is what picks the right account
  -- instead of an arbitrary one sharing the same address.
  select * into v_row
    from public.profiles p
    where lower(p.email) = lower(p_email)
      and p.password_hash = p_password_hash;

  if not found then
    return; -- empty result set — client treats as invalid credentials
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  v_expires := (now() at time zone 'utc')
    + case when v_row.role = 'admin' then interval '90 days' else interval '24 hours' end;

  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where public.profiles.id = v_row.id;

  return query select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
    v_row.role, v_row.admin_title, v_row.email_verified;
end;
$$;

revoke all on function public.signin_hops_user_by_email(text, text) from public;
grant execute on function public.signin_hops_user_by_email(text, text) to anon;
