-- Foundation for the standalone Admin app. Three things bundled into one
-- migration because they're all part of the same shift in how admin
-- privilege works:
--
--   1. Retires the self-serve admin_requests flow from 0002. Admin
--      privilege is now provisioned out-of-band (whoever holds Supabase
--      access runs the same manual `update profiles set role = 'admin'`
--      bootstrap 0002 always documented for the *first* admin — that's now
--      the only path, not just the bootstrap special case) onto a device
--      that's handed to the person physically, not requested from inside
--      the app. request_admin_access/list_pending_admin_requests/
--      review_admin_request are left in place (dropping deployed functions
--      is a bigger, harder-to-reverse step than revoking anon's ability to
--      call them) but revoked from anon, so nothing can reach them anymore.
--      admin_requests_screen.dart and its entry point in profile_screen.dart
--      are removed in the same client change as this migration.
--
--   2. Moderation primitives: ban/unban, admin-initiated delete (no target
--      password needed, unlike the existing self-service delete_hops_user),
--      a content-report queue students file into and admins resolve, and an
--      admin_actions_log every one of those writes to — the moment admins
--      can ban/delete, admin behavior needs its own audit trail too, not
--      just student behavior.
--
--   3. Long-lived tokens for admin accounts. A provisioned device (a
--      security guard's phone) has nobody around to retype a password when
--      the token expires — see signin changes below.
--
-- What this deliberately does NOT add: any server-side log of Community
-- Chat or Vibe Check content that hasn't been reported. Both are still
-- transient/local-only (see hops_app.dart, community_chat.dart,
-- database_helper.dart) — content only reaches this database when a
-- student explicitly reports it, snapshotted at that moment. "Delete" from
-- the admin app therefore means resolving the report + acting on the
-- sender, not reaching into other people's phones to erase something
-- already delivered.

-- ---------------------------------------------------------------------------
-- 1. Retire the request/approval flow.
-- ---------------------------------------------------------------------------
revoke execute on function public.request_admin_access(text, text) from anon;
revoke execute on function public.list_pending_admin_requests(text) from anon;
revoke execute on function public.review_admin_request(text, uuid, boolean) from anon;

-- ---------------------------------------------------------------------------
-- 2. Ban state on profiles. Separate from role — a banned account keeps
--    whatever role it had (mostly relevant if an admin account is ever
--    banned instead of just demoted), it just can't sign in or act while
--    banned = true.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists banned boolean not null default false,
  add column if not exists ban_reason text,
  add column if not exists banned_at timestamptz,
  add column if not exists banned_by uuid references public.profiles(id);

-- Earlier migrations never added a creation timestamp (accounts were only
-- ever ordered implicitly via Postgres's own row insert order) — needed now
-- for the Dashboard's new_users_7d/30d stats below. Deliberately NOT
-- `add column ... default (now())` in one step — Postgres evaluates a
-- non-null default once and stamps it onto every *existing* row too, which
-- would make every pre-existing account falsely count as "created in the
-- last 7/30 days" the moment this migration runs. Backfill old rows to
-- epoch instead (their real creation time isn't recoverable, and epoch
-- correctly never counts as recent); only rows inserted from here on get
-- `now()`.
alter table public.profiles add column if not exists created_at timestamptz;
update public.profiles set created_at = timestamp with time zone 'epoch' where created_at is null;
alter table public.profiles alter column created_at set not null;
alter table public.profiles alter column created_at set default (now() at time zone 'utc');

-- ---------------------------------------------------------------------------
-- 3. Sign-in changes: reject banned accounts with a distinct error (safe to
--    be specific here — unlike the "invalid username or password" collapse
--    elsewhere, which protects against enumerating *other* people's
--    accounts, this is the account owner authenticating with their own
--    correct credentials, so telling them why they're locked out leaks
--    nothing to a third party). Also: admin accounts get a 90-day token
--    instead of 24h, since a provisioned device has no one to re-enter a
--    password when it expires.
-- ---------------------------------------------------------------------------
drop function if exists public.signin_hops_user(text, text);

create function public.signin_hops_user(
  p_username text,
  p_password_hash text
) returns table (
  id uuid, username text, public_key text, hops_token text,
  token_expires_at timestamptz, role text, admin_title text
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
  select * into v_row from public.profiles p where p.username = p_username;

  if not found or v_row.password_hash is distinct from p_password_hash then
    return; -- empty result set — client treats as invalid credentials
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  v_expires := (now() at time zone 'utc')
    + case when v_row.role = 'admin' then interval '90 days' else interval '24 hours' end;

  -- profiles.id, qualified — both of these functions RETURNS TABLE an
  -- output column literally named "id", which PL/pgSQL auto-declares as a
  -- variable in scope for the whole function body. An unqualified `where
  -- id = v_row.id` is genuinely ambiguous between that variable and the
  -- profiles.id column (Postgres error 42702, not a warning — it refuses
  -- to guess), so this can't be left bare the way an UPDATE's WHERE clause
  -- normally could.
  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where public.profiles.id = v_row.id;

  return query
    select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
           v_row.role, v_row.admin_title;
end;
$$;

revoke all on function public.signin_hops_user(text, text) from public;
grant execute on function public.signin_hops_user(text, text) to anon;

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
  select * into v_row from public.profiles p where lower(p.email) = lower(p_email);

  if not found or v_row.password_hash is distinct from p_password_hash then
    return; -- empty result set — client treats as invalid credentials
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  v_expires := (now() at time zone 'utc')
    + case when v_row.role = 'admin' then interval '90 days' else interval '24 hours' end;

  -- profiles.id, qualified — both of these functions RETURNS TABLE an
  -- output column literally named "id", which PL/pgSQL auto-declares as a
  -- variable in scope for the whole function body. An unqualified `where
  -- id = v_row.id` is genuinely ambiguous between that variable and the
  -- profiles.id column (Postgres error 42702, not a warning — it refuses
  -- to guess), so this can't be left bare the way an UPDATE's WHERE clause
  -- normally could.
  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where public.profiles.id = v_row.id;

  return query select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
    v_row.role, v_row.admin_title, v_row.email_verified;
end;
$$;

revoke all on function public.signin_hops_user_by_email(text, text) from public;
grant execute on function public.signin_hops_user_by_email(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. get_my_status — was purely for "did my admin request get approved?"
--    polling (0005); that reason is gone, but the shape (any signed-in
--    device periodically asking about its own live status) is exactly the
--    mechanism needed to catch an already-signed-in student getting banned
--    mid-session, so it's extended rather than replaced. raises the same
--    account_banned exception signin does, so the client can reuse one
--    handler for "you got banned" whether it happens at sign-in or later.
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_status(text);

create function public.get_my_status(
  p_hops_token text
) returns table (role text, admin_title text)
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

  if not found then
    return;
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  return query select v_row.role, v_row.admin_title;
end;
$$;

revoke all on function public.get_my_status(text) from public;
grant execute on function public.get_my_status(text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Admin action audit log. Every moderation action below writes one row
--    here. target_username is denormalized (kept even if the target row is
--    later deleted) since "who did what to whom" needs to survive an
--    admin_delete_user call on the very account being logged about.
-- ---------------------------------------------------------------------------
create table if not exists public.admin_actions_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.profiles(id) on delete set null,
  actor_username text not null,
  action text not null check (action in
    ('ban', 'unban', 'delete_user', 'promote_admin', 'demote_admin',
     'resolve_report', 'official_alert')),
  target_username text,
  reason text,
  created_at timestamptz not null default (now() at time zone 'utc')
);

alter table public.admin_actions_log enable row level security;
revoke all on public.admin_actions_log from anon, authenticated;

create index if not exists admin_actions_log_created_idx
  on public.admin_actions_log (created_at desc);

-- ---------------------------------------------------------------------------
-- 6. Content reports. Any signed-in user can file one; only admins can list
--    or resolve. snapshot_text is a copy taken at report time — this table
--    is the *only* place chat/vibe-check content ever exists server-side,
--    and only for what was actually reported.
-- ---------------------------------------------------------------------------
create table if not exists public.content_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  reporter_username text not null,
  content_type text not null check (content_type in ('chat_message', 'vibe_check', 'contact_profile')),
  -- Nullable: Vibe Check's crowd-density tags (VBT: in hops_app.dart) carry
  -- no sender at all by design — just a location + level — so a reported
  -- vibe_check row genuinely has no one to name. chat_message/
  -- contact_profile reports always populate this; the admin app's
  -- Moderation Queue just won't offer a "ban/delete sender" action on a
  -- report where it's null.
  target_username text,
  snapshot_text text not null,
  category text not null check (category in ('spam', 'harassment', 'inappropriate', 'other')),
  note text,
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default (now() at time zone 'utc'),
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  action_taken text
);

alter table public.content_reports enable row level security;
revoke all on public.content_reports from anon, authenticated;

create index if not exists content_reports_status_idx
  on public.content_reports (status, created_at);

create or replace function public.submit_report(
  p_hops_token text,
  p_content_type text,
  p_snapshot_text text,
  p_category text,
  -- Nullable — Vibe Check reports have no attributable sender at all (see
  -- content_reports.target_username above), so this is the last positional
  -- param with a default rather than required, letting Vibe Check's report
  -- call site simply omit it.
  p_target_username text default null,
  p_note text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reporter public.profiles%rowtype;
  v_id uuid;
begin
  select * into v_reporter
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  insert into public.content_reports
    (reporter_id, reporter_username, content_type, target_username, snapshot_text, category, note)
  values
    (v_reporter.id, v_reporter.username, p_content_type, p_target_username, p_snapshot_text, p_category, p_note)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_report(text, text, text, text, text, text) from public;
grant execute on function public.submit_report(text, text, text, text, text, text) to anon;

create or replace function public.list_open_reports(
  p_hops_token text
) returns setof public.content_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select p.role into v_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select * from public.content_reports
    where status = 'open'
    order by created_at asc;
end;
$$;

revoke all on function public.list_open_reports(text) from public;
grant execute on function public.list_open_reports(text) to anon;

-- p_action: what the admin decided ('dismissed', 'warned', 'banned_sender',
-- 'deleted_sender') — free text rather than a checked enum since it's a
-- human-readable label for the log/report row, not something anything
-- branches on programmatically. Actually banning/deleting the sender is a
-- separate explicit RPC call (ban_user/admin_delete_user) from the admin
-- app — this just records what happened and closes the report out.
create or replace function public.resolve_report(
  p_hops_token text,
  p_report_id uuid,
  p_status text,
  p_action_taken text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if p_status not in ('actioned', 'dismissed') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  update public.content_reports
    set status = p_status, resolved_by = v_admin.id, resolved_at = (now() at time zone 'utc'),
        action_taken = p_action_taken
    where id = p_report_id and status = 'open';

  if not found then
    raise exception 'report_not_open' using errcode = 'P0002';
  end if;

  insert into public.admin_actions_log (actor_id, actor_username, action, reason)
    values (v_admin.id, v_admin.username, 'resolve_report', p_action_taken);
end;
$$;

revoke all on function public.resolve_report(text, uuid, text, text) from public;
grant execute on function public.resolve_report(text, uuid, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 7. Ban / unban / admin-delete / promote / demote. All admin-only, all
--    take the caller's hops_token (never auth.uid() — see 0001/0002, this
--    app never uses Supabase Auth), all log to admin_actions_log.
-- ---------------------------------------------------------------------------
create or replace function public.ban_user(
  p_hops_token text,
  p_target_id uuid,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target_username text;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Force-expire the target's current session in the same statement — a
  -- banned account shouldn't get to keep using an already-issued token
  -- until it happens to naturally expire.
  update public.profiles
    set banned = true, ban_reason = p_reason, banned_at = (now() at time zone 'utc'),
        banned_by = v_admin.id, token_expires_at = (now() at time zone 'utc')
    where id = p_target_id
    returning username into v_target_username;

  if v_target_username is null then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username, reason)
    values (v_admin.id, v_admin.username, 'ban', v_target_username, p_reason);
end;
$$;

revoke all on function public.ban_user(text, uuid, text) from public;
grant execute on function public.ban_user(text, uuid, text) to anon;

create or replace function public.unban_user(
  p_hops_token text,
  p_target_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target_username text;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.profiles
    set banned = false, ban_reason = null, banned_at = null, banned_by = null
    where id = p_target_id
    returning username into v_target_username;

  if v_target_username is null then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username)
    values (v_admin.id, v_admin.username, 'unban', v_target_username);
end;
$$;

revoke all on function public.unban_user(text, uuid) from public;
grant execute on function public.unban_user(text, uuid) to anon;

-- Admin-initiated delete — unlike delete_hops_user (0006), this needs no
-- password from the target, only the caller being an admin. Deliberately
-- can't target another admin (must demote first) so one admin can't casually
-- nuke another's account in a single call.
create or replace function public.admin_delete_user(
  p_hops_token text,
  p_target_id uuid,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target public.profiles%rowtype;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if v_target.role = 'admin' then
    raise exception 'cannot_delete_admin' using errcode = '42501';
  end if;

  delete from public.profiles where id = p_target_id;

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username, reason)
    values (v_admin.id, v_admin.username, 'delete_user', v_target.username, p_reason);
end;
$$;

revoke all on function public.admin_delete_user(text, uuid, text) from public;
grant execute on function public.admin_delete_user(text, uuid, text) to anon;

create or replace function public.promote_admin(
  p_hops_token text,
  p_target_id uuid,
  p_admin_title text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target_username text;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.profiles
    set role = 'admin', admin_title = coalesce(p_admin_title, admin_title)
    where id = p_target_id
    returning username into v_target_username;

  if v_target_username is null then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username)
    values (v_admin.id, v_admin.username, 'promote_admin', v_target_username);
end;
$$;

revoke all on function public.promote_admin(text, uuid, text) from public;
grant execute on function public.promote_admin(text, uuid, text) to anon;

create or replace function public.demote_admin(
  p_hops_token text,
  p_target_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target_username text;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if v_admin.id = p_target_id then
    raise exception 'cannot_demote_self' using errcode = '42501';
  end if;

  update public.profiles
    set role = 'student'
    -- Demoting drops the 90-day admin token lifetime — force a re-sign-in
    -- on their next session rather than leaving a long-lived token on an
    -- account that's no longer supposed to have one.
    , token_expires_at = (now() at time zone 'utc')
    where id = p_target_id
    returning username into v_target_username;

  if v_target_username is null then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username)
    values (v_admin.id, v_admin.username, 'demote_admin', v_target_username);
end;
$$;

revoke all on function public.demote_admin(text, uuid) from public;
grant execute on function public.demote_admin(text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 8. User directory search — admin-only, backs the admin app's Users
--    screen. p_query matches username or email (case-insensitive substring);
--    empty/null query returns the most recently created accounts first.
-- ---------------------------------------------------------------------------
create or replace function public.admin_search_users(
  p_hops_token text,
  p_query text default null,
  p_limit int default 50
) returns table (
  id uuid, username text, email text, role text, admin_title text,
  banned boolean, ban_reason text, email_verified boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select p.role into v_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select p.id, p.username, p.email, p.role, p.admin_title, p.banned, p.ban_reason, p.email_verified
    from public.profiles p
    where p_query is null or p_query = ''
      or p.username ilike '%' || p_query || '%'
      or p.email ilike '%' || p_query || '%'
    order by p.username asc
    limit least(coalesce(p_limit, 50), 200);
end;
$$;

revoke all on function public.admin_search_users(text, text, int) from public;
grant execute on function public.admin_search_users(text, text, int) to anon;

-- ---------------------------------------------------------------------------
-- 9. Official Alert log — alerts are BLE broadcasts (ADM:/ADM_OFF: in
--    hops_app.dart), nothing about the broadcast itself touches the
--    server. This is a fire-and-forget record the admin app writes
--    alongside composing one, purely for the Dashboard's alert-frequency
--    stat and the Action Log — never read by anything mesh-side.
-- ---------------------------------------------------------------------------
create table if not exists public.official_alerts_log (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid references public.profiles(id) on delete set null,
  admin_username text not null,
  reason text,
  created_at timestamptz not null default (now() at time zone 'utc')
);

alter table public.official_alerts_log enable row level security;
revoke all on public.official_alerts_log from anon, authenticated;

create or replace function public.log_official_alert(
  p_hops_token text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  insert into public.official_alerts_log (admin_id, admin_username, reason)
    values (v_admin.id, v_admin.username, p_reason);
  insert into public.admin_actions_log (actor_id, actor_username, action, reason)
    values (v_admin.id, v_admin.username, 'official_alert', p_reason);
end;
$$;

revoke all on function public.log_official_alert(text, text) from public;
grant execute on function public.log_official_alert(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 10. Dashboard stats — one round trip for everything the admin app's
--     Dashboard screen shows. Admin-only. Returns a single row; counts
--     rather than raw rows throughout, consistent with the "no individual
--     movement/location tracking" line the mesh's design otherwise holds —
--     this is aggregate-only, nothing here identifies who did what.
-- ---------------------------------------------------------------------------
create or replace function public.get_admin_dashboard_stats(
  p_hops_token text
) returns table (
  total_users bigint,
  new_users_7d bigint,
  new_users_30d bigint,
  email_verified_count bigint,
  banned_count bigint,
  admin_count bigint,
  open_reports bigint,
  resolved_reports_30d bigint,
  bans_30d bigint,
  alerts_30d bigint,
  actions_30d bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select p.role into v_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select
      (select count(*) from public.profiles),
      (select count(*) from public.profiles where created_at > (now() at time zone 'utc') - interval '7 days'),
      (select count(*) from public.profiles where created_at > (now() at time zone 'utc') - interval '30 days'),
      (select count(*) from public.profiles where email_verified),
      (select count(*) from public.profiles where banned),
      (select count(*) from public.profiles where role = 'admin'),
      (select count(*) from public.content_reports where status = 'open'),
      (select count(*) from public.content_reports where status <> 'open' and resolved_at > (now() at time zone 'utc') - interval '30 days'),
      (select count(*) from public.admin_actions_log where action = 'ban' and created_at > (now() at time zone 'utc') - interval '30 days'),
      (select count(*) from public.official_alerts_log where created_at > (now() at time zone 'utc') - interval '30 days'),
      (select count(*) from public.admin_actions_log where created_at > (now() at time zone 'utc') - interval '30 days');
end;
$$;

revoke all on function public.get_admin_dashboard_stats(text) from public;
grant execute on function public.get_admin_dashboard_stats(text) to anon;

-- ---------------------------------------------------------------------------
-- 11. Action Log — admin_actions_log has RLS enabled and everything
--     revoked from anon/authenticated (section 5 above), same as every
--     other new table in this file, so without this the admin app's
--     Action Log screen would have no way to read it at all. Admin-only,
--     most-recent-first, capped the same way admin_search_users is.
-- ---------------------------------------------------------------------------
create or replace function public.list_admin_actions_log(
  p_hops_token text,
  p_limit int default 100
) returns setof public.admin_actions_log
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
begin
  select p.role into v_role
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select * from public.admin_actions_log
    order by created_at desc
    limit least(coalesce(p_limit, 100), 300);
end;
$$;

revoke all on function public.list_admin_actions_log(text, int) from public;
grant execute on function public.list_admin_actions_log(text, int) to anon;

-- ---------------------------------------------------------------------------
-- Note: new_users_7d/30d above assume profiles has a created_at column.
-- Earlier migrations never added one (accounts were only ever timestamped
-- implicitly via Postgres's own row insert order). Add it now, backfilled
-- to epoch for pre-existing rows since their real creation time isn't
-- recoverable — they'll simply not count toward the 7d/30d windows, which
-- is correct (they weren't created in the last 7/30 days).
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists created_at timestamptz not null default (now() at time zone 'utc');
