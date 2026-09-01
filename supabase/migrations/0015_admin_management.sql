-- Admin tooling round two:
--   1. Suspension — a ban with an end date, so "cool off for a week" stops
--      being either nothing or permanent.
--   2. A full account view behind user search, so a moderation decision is
--      made with history in front of you rather than a username.
--   3. Wrongful-report escalation — reporting is currently free, which
--      makes it usable as a weapon. Dismissed reports now accumulate
--      against the reporter.
--
-- Thresholds live in resolve_report as named constants (4 and 7) rather
-- than a settings table: they're a policy decision that should be visible
-- in a diff when it changes.

-- ---------------------------------------------------------------------------
-- 1. Columns.
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists suspended_until timestamptz,
  add column if not exists suspension_reason text,
  -- Running count of this account's reports that admins threw out. Never
  -- auto-decays: forgiveness is admin_clear_reporter_flag, deliberately a
  -- decision someone makes rather than something time does quietly.
  add column if not exists dismissed_reports_count integer not null default 0,
  add column if not exists reporter_warned_at timestamptz,
  add column if not exists reporter_flagged_at timestamptz;

create index if not exists profiles_reporter_flagged_idx
  on public.profiles (reporter_flagged_at)
  where reporter_flagged_at is not null;

-- target_id alongside target_username. The username was the only link to
-- the subject of an action, which breaks the moment an account is deleted
-- or renamed — and "how many times has this person been banned" is exactly
-- the question that needs a stable answer.
alter table public.admin_actions_log
  add column if not exists target_id uuid;

alter table public.admin_actions_log drop constraint if exists admin_actions_log_action_check;
alter table public.admin_actions_log
  add constraint admin_actions_log_action_check check (action in
    ('ban', 'unban', 'delete_user', 'promote_admin', 'demote_admin',
     'resolve_report', 'official_alert', 'emergency_flare', 'warn_user',
     'suspend', 'unsuspend', 'clear_reporter_flag'));

-- ---------------------------------------------------------------------------
-- 2. Suspension.
--
-- Enforced in get_my_status (below) rather than by expiring the token the
-- way ban_user does: a suspension ends on its own, and force-expiring the
-- token would make the account look permanently signed out well after the
-- suspension lapsed.
-- ---------------------------------------------------------------------------
create or replace function public.suspend_user(
  p_hops_token text,
  p_target_id uuid,
  p_days integer,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_until timestamptz;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_days is null or p_days < 1 or p_days > 365 then
    raise exception 'invalid_duration' using errcode = '22023';
  end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if v_target.id = v_admin.id then
    raise exception 'cannot_suspend_self' using errcode = '22023';
  end if;

  v_until := (now() at time zone 'utc') + make_interval(days => p_days);

  update public.profiles
    set suspended_until = v_until, suspension_reason = p_reason
    where id = p_target_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_id, target_username, reason)
    values (v_admin.id, v_admin.username, 'suspend', v_target.id, v_target.username,
            coalesce(p_reason, '') || ' (' || p_days || ' days)');

  insert into public.user_notifications
    (recipient_id, type, title, occurred_at, note)
    values (v_target.id, 'warning', 'Your account has been suspended',
            (now() at time zone 'utc'),
            'Your Hops account is suspended until ' || to_char(v_until, 'YYYY-MM-DD') ||
            coalesce('. Reason: ' || p_reason, '.'));
end;
$$;

revoke all on function public.suspend_user(text, uuid, integer, text) from public;
grant execute on function public.suspend_user(text, uuid, integer, text) to anon;

create or replace function public.unsuspend_user(
  p_hops_token text,
  p_target_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  update public.profiles
    set suspended_until = null, suspension_reason = null
    where id = p_target_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_id, target_username)
    values (v_admin.id, v_admin.username, 'unsuspend', v_target.id, v_target.username);
end;
$$;

revoke all on function public.unsuspend_user(text, uuid) from public;
grant execute on function public.unsuspend_user(text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- 3. get_my_status — as 0010, plus the suspension check.
--
-- Same ordering lesson as 0010's ban fix: look the row up by token alone,
-- then decide. Filtering on expiry first hid exactly the rows the checks
-- below exist to catch.
-- ---------------------------------------------------------------------------
create or replace function public.get_my_status(
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
    raise exception 'account_banned' using errcode = '42501', detail = coalesce(v_row.ban_reason, '');
  end if;

  if v_row.suspended_until is not null and v_row.suspended_until > (now() at time zone 'utc') then
    raise exception 'account_suspended'
      using errcode = '42501',
            detail = to_char(v_row.suspended_until, 'YYYY-MM-DD') ||
                     coalesce(' — ' || v_row.suspension_reason, '');
  end if;

  if v_row.token_expires_at is null or v_row.token_expires_at <= (now() at time zone 'utc') then
    return;
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
-- 4. Full account view for the Users tab.
--
-- One round trip: identity, standing, and the counts a moderator needs
-- before deciding anything. Ban/suspend history is counted out of
-- admin_actions_log rather than kept as a column — the log is already the
-- record of truth, and a counter column would be a second one to drift.
-- ---------------------------------------------------------------------------
create or replace function public.admin_get_user_detail(
  p_hops_token text,
  p_target_id uuid
) returns table (
  id uuid,
  username text,
  email text,
  role text,
  admin_title text,
  created_at timestamptz,
  email_verified boolean,
  banned boolean,
  ban_reason text,
  banned_at timestamptz,
  suspended_until timestamptz,
  suspension_reason text,
  ban_count bigint,
  suspend_count bigint,
  warning_count bigint,
  reports_against bigint,
  reports_actioned_against bigint,
  reports_filed bigint,
  dismissed_reports_count integer,
  reporter_warned_at timestamptz,
  reporter_flagged_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_t public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_t from public.profiles where public.profiles.id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  return query select
    v_t.id, v_t.username, v_t.email, v_t.role, v_t.admin_title, v_t.created_at,
    coalesce(v_t.email_verified, false),
    v_t.banned, v_t.ban_reason, v_t.banned_at,
    v_t.suspended_until, v_t.suspension_reason,
    -- target_id is only populated from this migration onward, so older
    -- rows are matched on username too. Both sides are needed: username
    -- catches history, target_id survives a rename.
    (select count(*) from public.admin_actions_log l
      where l.action = 'ban' and (l.target_id = v_t.id or l.target_username = v_t.username)),
    (select count(*) from public.admin_actions_log l
      where l.action = 'suspend' and (l.target_id = v_t.id or l.target_username = v_t.username)),
    (select count(*) from public.user_notifications n
      where n.recipient_id = v_t.id and n.type = 'warning'),
    (select count(*) from public.content_reports r where r.target_username = v_t.username),
    (select count(*) from public.content_reports r
      where r.target_username = v_t.username and r.status = 'actioned'),
    (select count(*) from public.content_reports r where r.reporter_id = v_t.id),
    v_t.dismissed_reports_count, v_t.reporter_warned_at, v_t.reporter_flagged_at;
end;
$$;

revoke all on function public.admin_get_user_detail(text, uuid) from public;
grant execute on function public.admin_get_user_detail(text, uuid) to anon;

-- Recent moderation history for one account, for the detail screen's
-- timeline. Separate from the counts above so the screen can show them
-- immediately and fill the list in behind.
create or replace function public.admin_get_user_history(
  p_hops_token text,
  p_target_id uuid,
  p_limit integer default 25
) returns table (
  action text,
  actor_username text,
  reason text,
  content_snapshot text,
  content_place text,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_username text;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select p.username into v_username from public.profiles p where p.id = p_target_id;

  return query
    select l.action, l.actor_username, l.reason, l.content_snapshot, l.content_place, l.created_at
      from public.admin_actions_log l
      where l.target_id = p_target_id or l.target_username = v_username
      order by l.created_at desc
      limit least(coalesce(p_limit, 25), 100);
end;
$$;

revoke all on function public.admin_get_user_history(text, uuid, integer) from public;
grant execute on function public.admin_get_user_history(text, uuid, integer) to anon;

-- ---------------------------------------------------------------------------
-- 5. Wrongful-report escalation.
--
-- Filing a report is free and anonymous to the person being reported,
-- which makes it usable as a way to harass someone rather than to report
-- them. Dismissed reports now accumulate against the reporter:
--
--   4 dismissed  → automatic warning to the reporter, once.
--   7 dismissed  → account flagged for an admin to look at and decide
--                  (ban, suspend, or clear the flag). Deliberately not
--                  automatic — an automatic ban for reporting is its own
--                  way to silence someone with a genuine complaint.
--
-- A dismissed report is not proof of bad faith. That's exactly why the
-- second stage puts a human in front of it.
-- ---------------------------------------------------------------------------
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
  c_warn_threshold  constant integer := 4;
  c_flag_threshold  constant integer := 7;
  v_admin public.profiles%rowtype;
  v_report public.content_reports%rowtype;
  v_place text;
  v_count integer;
  v_reporter public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_status not in ('actioned', 'dismissed') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;

  select * into v_report from public.content_reports where id = p_report_id;
  if not found then
    raise exception 'report_not_found' using errcode = 'P0002';
  end if;
  if v_report.status <> 'open' then
    raise exception 'report_not_open' using errcode = 'P0002';
  end if;

  v_place := case v_report.content_type
    when 'chat_message' then 'Community Chat'
    when 'vibe_check' then 'Vibe Check'
    when 'contact_profile' then 'Profile'
    else v_report.content_type
  end;

  update public.content_reports
    set status = p_status, resolved_by = v_admin.id, resolved_at = (now() at time zone 'utc'),
        action_taken = p_action_taken
    where id = p_report_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_username, reason,
     content_snapshot, content_place, content_created_at, content_category)
    values
    (v_admin.id, v_admin.username, 'resolve_report', v_report.target_username, p_action_taken,
     v_report.snapshot_text, v_place,
     coalesce(v_report.content_created_at, v_report.created_at), v_report.category);

  -- Escalation, only on dismissal and only when we still know who filed it.
  if p_status = 'dismissed' and v_report.reporter_id is not null then
    update public.profiles
      set dismissed_reports_count = dismissed_reports_count + 1
      where id = v_report.reporter_id
      returning * into v_reporter;

    v_count := v_reporter.dismissed_reports_count;

    if v_count >= c_warn_threshold and v_reporter.reporter_warned_at is null then
      insert into public.user_notifications
        (recipient_id, type, title, occurred_at, note)
        values (v_reporter.id, 'warning',
                'Please only report genuine problems',
                (now() at time zone 'utc'),
                'Several reports you have sent were reviewed and found not to break any rule. '
                'Reporting is there to keep people safe — sending reports that do not need action '
                'makes it slower for admins to reach the ones that do. Continued reports of this '
                'kind may affect your account.');
      update public.profiles set reporter_warned_at = (now() at time zone 'utc')
        where id = v_reporter.id;
    end if;

    if v_count >= c_flag_threshold and v_reporter.reporter_flagged_at is null then
      update public.profiles set reporter_flagged_at = (now() at time zone 'utc')
        where id = v_reporter.id;
    end if;
  end if;

  perform public.notify_reporter_of_resolution(v_report, p_status = 'actioned');
end;
$$;

revoke all on function public.resolve_report(text, uuid, text, text) from public;
grant execute on function public.resolve_report(text, uuid, text, text) to anon;

-- Accounts sitting at the flag threshold, waiting on a decision.
create or replace function public.admin_list_flagged_reporters(
  p_hops_token text
) returns table (
  id uuid,
  username text,
  email text,
  dismissed_reports_count integer,
  reports_filed bigint,
  reporter_flagged_at timestamptz,
  banned boolean,
  suspended_until timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  return query
    select p.id, p.username, p.email, p.dismissed_reports_count,
           (select count(*) from public.content_reports r where r.reporter_id = p.id),
           p.reporter_flagged_at, p.banned, p.suspended_until
      from public.profiles p
      where p.reporter_flagged_at is not null
      order by p.reporter_flagged_at asc;
end;
$$;

revoke all on function public.admin_list_flagged_reporters(text) from public;
grant execute on function public.admin_list_flagged_reporters(text) to anon;

-- "Looked at it, no further action." Resets the counter as well as the
-- flags, so a cleared account starts over rather than re-flagging on its
-- very next dismissal.
create or replace function public.admin_clear_reporter_flag(
  p_hops_token text,
  p_target_id uuid,
  p_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  update public.profiles
    set reporter_flagged_at = null,
        reporter_warned_at = null,
        dismissed_reports_count = 0
    where id = p_target_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_id, target_username, reason)
    values (v_admin.id, v_admin.username, 'clear_reporter_flag', v_target.id, v_target.username, p_note);
end;
$$;

revoke all on function public.admin_clear_reporter_flag(text, uuid, text) from public;
grant execute on function public.admin_clear_reporter_flag(text, uuid, text) to anon;

-- ---------------------------------------------------------------------------
-- 6. Existing actions now record target_id as well, so the counts in
--    admin_get_user_detail keep working after a rename or delete.
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
  v_target public.profiles%rowtype;
begin
  select * into v_admin from public.profiles p
    where p.hops_token = p_hops_token and p.token_expires_at > (now() at time zone 'utc');
  if v_admin.role is distinct from 'admin' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select * into v_target from public.profiles where id = p_target_id;
  if not found then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;
  if v_target.id = v_admin.id then
    raise exception 'cannot_ban_self' using errcode = '22023';
  end if;

  update public.profiles
    set banned = true, ban_reason = p_reason, banned_at = (now() at time zone 'utc'),
        -- Force-expired so the ban takes effect on their next call rather
        -- than whenever the token would have lapsed on its own.
        token_expires_at = (now() at time zone 'utc') - interval '1 second'
    where id = p_target_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_id, target_username, reason)
    values (v_admin.id, v_admin.username, 'ban', v_target.id, v_target.username, p_reason);
end;
$$;

revoke all on function public.ban_user(text, uuid, text) from public;
grant execute on function public.ban_user(text, uuid, text) to anon;
