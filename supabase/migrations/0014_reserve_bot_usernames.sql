-- Every Hops install now ships with the assistant as a built-in contact
-- (see client/lib/services/hops_engine.dart's kHopsBotUsername). Its chat
-- history is stored in the local `messages` table keyed by peer username,
-- exactly like a real conversation — so a person who signed up as "Hops"
-- would land in the same thread as the bot on anyone who added them:
-- their messages interleaved with the assistant's, under the same name,
-- with no way for the reader to tell which was which.
--
-- That's an impersonation route into a safety app, so the name is reserved
-- server-side rather than only in the client. The client has its own copy
-- of this check for a fast, offline-friendly error message, but this is
-- the one that actually enforces it.

-- ---------------------------------------------------------------------------
-- 1. The reserved list.
--
-- IMMUTABLE because it's used in a CHECK constraint below, which Postgres
-- only allows for immutable expressions. Extending the list later is a
-- one-line edit here plus a re-run of this file — but note that adding a
-- name does NOT retroactively invalidate accounts that already hold it
-- (see the NOT VALID note in section 2).
--
-- Deliberately narrow: only the assistant's own identity. Names like
-- 'admin' or 'staff' are a separate impersonation question with real
-- existing accounts potentially behind them, so they're left alone rather
-- than swept in here as a side effect.
-- ---------------------------------------------------------------------------
create or replace function public.is_reserved_username(p_username text)
returns boolean
language sql
immutable
as $$
  select lower(btrim(coalesce(p_username, ''))) = any (
    array['hops', 'hopsbot', 'hops bot', 'hops_bot', 'hops-bot']
  );
$$;

revoke all on function public.is_reserved_username(text) from public;
grant execute on function public.is_reserved_username(text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Backstop constraint.
--
-- signup_hops_user (section 3) is the only path that creates a profile
-- today, but this catches anything that bypasses it — a future RPC, a
-- rename feature, or a hand-written insert from the SQL editor.
--
-- NOT VALID matters: if someone already registered as "Hops" before this
-- migration ran, a validating constraint would fail to apply and the whole
-- migration would abort. NOT VALID leaves existing rows alone and enforces
-- on every insert and update from here on. Check for a pre-existing holder
-- with:
--   select id, username, created_at from public.profiles
--     where public.is_reserved_username(username);
-- and rename or remove it by hand if there is one — this file deliberately
-- doesn't touch live accounts on its own.
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_username_not_reserved;
alter table public.profiles
  add constraint profiles_username_not_reserved
  check (not public.is_reserved_username(username))
  not valid;

-- ---------------------------------------------------------------------------
-- 3. signup_hops_user — as 0007, plus the reserved-name check.
--
-- Checked explicitly before the insert rather than left to the constraint
-- so the client gets a specific 'username_reserved' code to show a useful
-- message for, instead of a generic check_violation it would have to
-- render as "something went wrong".
--
-- CREATE OR REPLACE, not DROP + CREATE: the signature is unchanged from
-- 0007, so there's nothing to drop, and replacing in place keeps the
-- existing GRANT rather than silently dropping it (a DROP would take the
-- grant with it, and forgetting to re-issue it locks every new signup out
-- with a permissions error).
-- ---------------------------------------------------------------------------
create or replace function public.signup_hops_user(
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
  if public.is_reserved_username(p_username) then
    raise exception 'username_reserved' using errcode = '22023';
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

-- Re-issued defensively. Harmless if 0007's grant is still in place, and
-- the difference between "harmless" and "nobody can sign up" if it isn't.
revoke all on function public.signup_hops_user(text, text, text, text) from public;
grant execute on function public.signup_hops_user(text, text, text, text) to anon;
