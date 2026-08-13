-- Admin roles: adds a role column to profiles and a request/approval queue
-- for granting it. Part of the two-tier Emergency Flare design (student SOS
-- vs. admin-only Official Alert) — see 0001_lockdown_profiles.sql for why
-- every RPC here takes hops_token explicitly rather than using auth.uid():
-- this app never uses Supabase Auth, so there is no such thing to call.
--
-- Bootstrap note: the very first admin has no inviter. After running this,
-- pick one account and run:
--   update public.profiles set role = 'admin' where username = '<you>';
-- Every admin after that goes through request_admin_access /
-- review_admin_request from within the app.

-- ---------------------------------------------------------------------------
-- 1. Role column. 'admin_title' is purely cosmetic — shown on Official
--    Alerts (e.g. "OFFICIAL ALERT — Campus Security") — never used for
--    authorization, only role is.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists role text not null default 'student',
  add column if not exists admin_title text;

-- Postgres has no "ADD CONSTRAINT IF NOT EXISTS" — drop-then-add is the
-- standard idempotent pattern, needed here for the same reason as the
-- DROP VIEW/DROP FUNCTION in 0001: this file may be re-run after a partial
-- or out-of-order prior attempt.
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check check (role in ('student', 'admin'));

-- ---------------------------------------------------------------------------
-- 2. Request queue. One pending request per user at a time — the partial
--    unique index below enforces that so someone can't spam the queue.
-- ---------------------------------------------------------------------------
create table if not exists public.admin_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles(id) on delete cascade,
  note text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  created_at timestamptz not null default (now() at time zone 'utc'),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz
);

create unique index if not exists admin_requests_one_pending_per_user
  on public.admin_requests (requester_id)
  where status = 'pending';

-- Lock the table down the same way profiles was locked down — nothing here
-- is meant to be read/written directly by the client, only through the
-- RPCs below.
alter table public.admin_requests enable row level security;
revoke all on public.admin_requests from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. request_admin_access — any signed-in user files a request.
-- ---------------------------------------------------------------------------
create or replace function public.request_admin_access(
  p_hops_token text,
  p_note text default null
) returns table (id uuid, status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid;
begin
  select p.id into v_caller_id
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_caller_id is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  begin
    return query
      insert into public.admin_requests (requester_id, note)
      values (v_caller_id, p_note)
      returning admin_requests.id, admin_requests.status;
  exception
    when unique_violation then
      raise exception 'request_already_pending' using errcode = '23505';
  end;
end;
$$;

revoke all on function public.request_admin_access(text, text) from public;
grant execute on function public.request_admin_access(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. list_pending_admin_requests — admin-only, returns the queue.
-- ---------------------------------------------------------------------------
create or replace function public.list_pending_admin_requests(
  p_hops_token text
) returns table (
  id uuid,
  requester_id uuid,
  requester_username text,
  note text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_role text;
begin
  select p.role into v_caller_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_caller_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select ar.id, ar.requester_id, req.username, ar.note, ar.created_at
      from public.admin_requests ar
      join public.profiles req on req.id = ar.requester_id
      where ar.status = 'pending'
      order by ar.created_at asc;
end;
$$;

revoke all on function public.list_pending_admin_requests(text) from public;
grant execute on function public.list_pending_admin_requests(text) to anon;

-- ---------------------------------------------------------------------------
-- 5. review_admin_request — admin-only, approve/deny. Approval flips the
--    requester's role; denial just closes the request out.
-- ---------------------------------------------------------------------------
create or replace function public.review_admin_request(
  p_hops_token text,
  p_request_id uuid,
  p_approve boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_id uuid;
  v_caller_role text;
  v_requester_id uuid;
begin
  select p.id, p.role into v_caller_id, v_caller_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_caller_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.admin_requests
    set status = case when p_approve then 'approved' else 'denied' end,
        reviewed_by = v_caller_id,
        reviewed_at = (now() at time zone 'utc')
    where id = p_request_id and status = 'pending'
    returning requester_id into v_requester_id;

  if v_requester_id is null then
    raise exception 'request_not_pending' using errcode = 'P0002';
  end if;

  if p_approve then
    update public.profiles set role = 'admin' where id = v_requester_id;
  end if;
end;
$$;

revoke all on function public.review_admin_request(text, uuid, boolean) from public;
grant execute on function public.review_admin_request(text, uuid, boolean) to anon;
