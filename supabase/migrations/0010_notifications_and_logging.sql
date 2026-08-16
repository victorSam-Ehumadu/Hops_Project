-- Three things bundled together because they were all found/requested in
-- the same pass: a real ban-enforcement bug, unified alert logging
-- (personal Emergency Flares as well as admin Official Alerts), and a
-- notifications inbox so a warned student actually has somewhere to see it.

-- ---------------------------------------------------------------------------
-- 1. Fix get_my_status silently failing to report a ban.
--
--    ban_user (0008) force-expires the target's token in the same statement
--    that bans them: `token_expires_at = now()`. get_my_status's lookup was
--    `where hops_token = ... and token_expires_at > now()` — which now
--    excludes the very row it needs to find, since that row's token just
--    became expired *by the ban itself*. The query returns "not found," the
--    banned-check further down never runs, and the client (hops_app.dart's
--    _syncIdentityStatus) sees an empty response and does nothing. A banned
--    student's session was therefore never actually being caught by this
--    poll — it only ever worked by coincidence, at their *next natural
--    sign-in*, when signin_hops_user[_by_email]'s own separate banned check
--    (which doesn't filter by token_expires_at at all) would catch it.
--
--    Fix: look the row up by hops_token alone, check banned FIRST (a ban
--    must be reported regardless of what it did to token_expires_at), and
--    only apply the expiry check afterward for the ordinary "session
--    naturally expired" case — which still correctly reports nothing, same
--    as before.
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_status(text);

create function public.get_my_status(
  p_hops_token text
) returns table (role text, admin_title text, unread_notifications bigint)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.profiles%rowtype;
begin
  select * into v_row from public.profiles p where p.hops_token = p_hops_token;

  if not found then
    return;
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  if v_row.token_expires_at <= (now() at time zone 'utc') then
    return; -- naturally expired, not banned — same "nothing to report" as before
  end if;

  return query
    select v_row.role, v_row.admin_title,
      (select count(*) from public.user_notifications n
         where n.recipient_id = v_row.id and n.read = false);
end;
$$;

revoke all on function public.get_my_status(text) from public;
grant execute on function public.get_my_status(text) to anon;

-- ---------------------------------------------------------------------------
-- 2. Unified alert logging. official_alerts_log (0008) only ever recorded
--    admin-issued Official Alerts — a personal Emergency Flare never wrote
--    anything server-side at all, so the admin app's Action Log had no way
--    to show it. Rather than a second parallel table, both kinds now log
--    into admin_actions_log itself (renaming nothing — the table already
--    doubled as a generic "notable thing an account did" log, e.g.
--    resolve_report isn't really an admin-*moderating-someone-else* action
--    either) under two new action kinds. admin_actions_log.actor_id is not
--    admin-only by definition — 'emergency_flare' is the first action kind
--    logged by an ordinary student, and log_emergency_flare below is
--    intentionally open to any signed-in user, not admin-gated.
-- ---------------------------------------------------------------------------
alter table public.admin_actions_log drop constraint if exists admin_actions_log_action_check;
alter table public.admin_actions_log
  add constraint admin_actions_log_action_check check (action in
    ('ban', 'unban', 'delete_user', 'promote_admin', 'demote_admin',
     'resolve_report', 'official_alert', 'emergency_flare', 'warn_user'));

create or replace function public.log_emergency_flare(
  p_hops_token text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller public.profiles%rowtype;
begin
  select * into v_caller
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  insert into public.admin_actions_log (actor_id, actor_username, action, reason)
    values (v_caller.id, v_caller.username, 'emergency_flare', p_reason);
end;
$$;

revoke all on function public.log_emergency_flare(text, text) from public;
grant execute on function public.log_emergency_flare(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Notifications inbox. The only way a student learns something happened
--    to their account (banned, promoted) used to be the same identity-sync
--    poll as everything else, which only ever supported two hardcoded
--    outcomes. A warning is a third kind of thing an admin needs to hand
--    back to a *specific* student with real content attached (what they
--    sent, where, when, what it violated) — this is that inbox. Deliberately
--    generic (type text, not a hardcoded enum of one) so a future kind of
--    notification doesn't need its own parallel table.
-- ---------------------------------------------------------------------------
create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  type text not null default 'warning' check (type in ('warning', 'info')),
  title text not null,
  -- The following four are specific to a 'warning' born from a content
  -- report (see warn_user_for_report below) — null for a plain 'info'
  -- notification, which has nothing to attach beyond title/note.
  message_snapshot text,
  place text,
  occurred_at timestamptz,
  violation text,
  note text,
  read boolean not null default false,
  created_at timestamptz not null default (now() at time zone 'utc')
);

create index if not exists user_notifications_recipient_idx
  on public.user_notifications (recipient_id, created_at desc);

alter table public.user_notifications enable row level security;
revoke all on public.user_notifications from anon, authenticated;

create or replace function public.list_my_notifications(
  p_hops_token text
) returns setof public.user_notifications
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

  return query
    select * from public.user_notifications
    where recipient_id = v_caller_id
    order by created_at desc
    limit 200;
end;
$$;

revoke all on function public.list_my_notifications(text) from public;
grant execute on function public.list_my_notifications(text) to anon;

create or replace function public.mark_all_notifications_read(
  p_hops_token text
) returns void
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

  update public.user_notifications
    set read = true
    where recipient_id = v_caller_id and read = false;
end;
$$;

revoke all on function public.mark_all_notifications_read(text) from public;
grant execute on function public.mark_all_notifications_read(text) to anon;

-- ---------------------------------------------------------------------------
-- 4. warn_user_for_report — the admin app's "Send warning" action on an
--    open report. Pulls the warning's content straight from the report
--    itself (snapshot_text/content_type/created_at/category) rather than
--    asking the admin to retype what's already on screen, and resolves the
--    report as 'actioned' in the same call so there's no separate "now
--    also go resolve it" step. Requires target_username (same restriction
--    admin_moderation_tab.dart's "Ban sender" button already has) — a
--    Vibe Check report has no attributable sender to warn.
-- ---------------------------------------------------------------------------
create or replace function public.warn_user_for_report(
  p_hops_token text,
  p_report_id uuid,
  p_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_report public.content_reports%rowtype;
  v_target_id uuid;
  v_place text;
begin
  select * into v_admin
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_report from public.content_reports where id = p_report_id;
  if not found then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  if v_report.status <> 'open' then
    raise exception 'report_not_open' using errcode = 'P0002';
  end if;
  if v_report.target_username is null then
    raise exception 'no_attributable_sender' using errcode = '22023';
  end if;

  select id into v_target_id from public.profiles where username = v_report.target_username;
  if v_target_id is null then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  v_place := case v_report.content_type
    when 'chat_message' then 'Community Chat'
    when 'vibe_check' then 'Vibe Check'
    when 'contact_profile' then 'Profile'
    else v_report.content_type
  end;

  insert into public.user_notifications
    (recipient_id, type, title, message_snapshot, place, occurred_at, violation, note)
    values
    (v_target_id, 'warning', 'You received a warning from a Hops admin',
     v_report.snapshot_text, v_place, v_report.created_at, v_report.category, p_note);

  update public.content_reports
    set status = 'actioned', resolved_by = v_admin.id, resolved_at = (now() at time zone 'utc'),
        action_taken = 'Sender warned'
    where id = p_report_id;

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username, reason)
    values (v_admin.id, v_admin.username, 'warn_user', v_report.target_username, p_note);
end;
$$;

revoke all on function public.warn_user_for_report(text, uuid, text) from public;
grant execute on function public.warn_user_for_report(text, uuid, text) to anon;
