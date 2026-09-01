-- Lock down public.profiles.
--
-- Why: the table was created without ever enabling Row Level Security, and
-- Supabase's default project setup grants ALL privileges on new public-schema
-- tables to `anon`/`authenticated` unless revoked. The result: anyone holding
-- the anon key (shipped inside every install of the app, in client/.env) had
-- direct SELECT/INSERT/UPDATE/DELETE/TRUNCATE on this table — including the
-- password_hash and hops_token (session credential) columns.
--
-- The client's sign-in flow does `select().eq('username', x)` then compares
-- password_hash locally, so no RLS policy shape can fix this on its own — a
-- policy permissive enough to let that query return a row is exactly as
-- permissive when queried with no filter at all. The real fix is: the client
-- never touches the table directly again. Two SECURITY DEFINER functions do
-- sign-up/sign-in server-side and hand back only the safe subset of columns;
-- a separate view exposes just {id, username, public_key} for the mesh's
-- future signature-verification key directory. Run this file in the Supabase
-- SQL editor, then ship the matching root_gatekeeper.dart change together —
-- see the note on anon/authenticated grants at the bottom before you do.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Safe public directory: only non-sensitive columns. This is what the
--    Emergency Flare signature-verification work will sync from while
--    online — nothing here is sensitive, so plain client-side SELECT is fine.
--
--    Dropped first rather than relying on CREATE OR REPLACE VIEW — Postgres
--    refuses to REPLACE a view in a way that removes columns, and if a
--    later migration's wider version of this view (0004 adds role,
--    admin_title) ever got applied before this one, replacing it with this
--    narrower 3-column version would fail with "cannot drop columns from
--    view". Explicit DROP sidesteps that regardless of what ran when.
-- ---------------------------------------------------------------------------
drop view if exists public.profiles_public;

create view public.profiles_public as
  select id, username, public_key
  from public.profiles;

revoke all on public.profiles_public from public;
grant select on public.profiles_public to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Sign-up RPC. Inserts the row server-side; returns only what the client
--    needs to persist locally. password_hash goes in, never comes back out.
-- ---------------------------------------------------------------------------
create or replace function public.signup_hops_user(
  p_username text,
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
begin
  insert into public.profiles (id, username, public_key, password_hash, hops_token, token_expires_at)
  values (v_id, p_username, p_public_key, p_password_hash, v_token, v_expires);

  return query select v_id, v_token, v_expires;
exception
  when unique_violation then
    raise exception 'username_taken' using errcode = '23505';
end;
$$;

revoke all on function public.signup_hops_user(text, text, text) from public;
grant execute on function public.signup_hops_user(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Sign-in RPC. Compares the hash *inside* the function; issues a fresh
--    token. Returns an empty result set for both "no such user" and "wrong
--    password" — collapsing those two cases (the old client code told them
--    apart) is deliberate: it stops this endpoint being used to enumerate
--    which usernames exist. root_gatekeeper.dart's error message needs to
--    become one generic "invalid username or password" string to match.
--
--    Dropped first for the same reason as profiles_public above — Postgres
--    won't CREATE OR REPLACE a function into a different return shape, and
--    0004's version of this function returns two more columns (role,
--    admin_title) than this one does.
-- ---------------------------------------------------------------------------
drop function if exists public.signin_hops_user(text, text);

create function public.signin_hops_user(
  p_username text,
  p_password_hash text
) returns table (id uuid, username text, public_key text, hops_token text, token_expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz := (now() at time zone 'utc') + interval '24 hours';
begin
  select * into v_row from public.profiles p where p.username = p_username;

  if not found or v_row.password_hash is distinct from p_password_hash then
    return; -- empty result set — client treats as invalid credentials
  end if;

  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where id = v_row.id;

  return query select v_row.id, v_row.username, v_row.public_key, v_token, v_expires;
end;
$$;

revoke all on function public.signin_hops_user(text, text) from public;
grant execute on function public.signin_hops_user(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. The actual lockdown. RLS on as defense-in-depth (if a future default
--    privilege change ever re-grants access, RLS with zero policies still
--    denies anon/authenticated by default), plus the direct REVOKE that
--    does the real work today. service_role/postgres are untouched —
--    dashboard/admin access still works exactly as before.
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

revoke select, insert, update, delete, truncate, references, trigger
  on public.profiles from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Standing gotcha, not just this table: Supabase's default project setup
-- auto-grants ALL privileges on every NEW public-schema table (and function,
-- and sequence) to anon/authenticated unless you revoke them — that's how
-- profiles ended up wide open despite no explicit GRANT ever being run. Any
-- table created from here on needs the same treatment (enable RLS + write
-- policies, or revoke + front it with RPCs) or it starts world-writable.
-- ---------------------------------------------------------------------------
