-- Two things:
--
--   1. admin_actions_log gains reporter_username, so a report-driven log
--      entry (resolve_report/warn_user_for_report) can show BOTH who was
--      reported and who reported them — previously only the target
--      survived onto the log row, so "who filed this?" meant going back to
--      the (possibly already-closed) report itself.
--
--   2. Ban/suspend/reinstatement emails: handled entirely client-side after
--      the RPC succeeds (see admin_user_detail_screen.dart calling the new
--      supabase/functions/send-moderation-email/), so nothing in THIS file
--      changes for it — the edge function takes just a target_id and looks
--      the email up itself with a service-role client. ban_user/
--      suspend_user's signatures are untouched: changing a function's
--      return type forces a DROP first (CREATE OR REPLACE can't do it),
--      and there was nothing to gain from carrying an email address through
--      the RPC's return value when the edge function was going to look it
--      up again anyway, more trustworthily, on its own.

-- unban_user already existed (0008) and unsuspend_user already existed
-- (0015) — nothing new needed there. This migration was almost titled
-- "add unsuspend", until re-checking the client (admin_user_detail_screen's
-- Take Action sheet) confirmed the "End suspension" action already calls
-- unsuspend_user. It works today; if it doesn't for you, the fault is a
-- skipped migration, not a missing feature.

-- ---------------------------------------------------------------------------
-- 1. Column.
-- ---------------------------------------------------------------------------
alter table public.admin_actions_log
  add column if not exists reporter_username text;

-- ---------------------------------------------------------------------------
-- 2. resolve_report — as 0015, plus reporter_username on the log row.
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
    (actor_id, actor_username, action, target_username, reporter_username, reason,
     content_snapshot, content_place, content_created_at, content_category)
    values
    (v_admin.id, v_admin.username, 'resolve_report', v_report.target_username,
     v_report.reporter_username, p_action_taken,
     v_report.snapshot_text, v_place,
     coalesce(v_report.content_created_at, v_report.created_at), v_report.category);

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

-- ---------------------------------------------------------------------------
-- 3. warn_user_for_report — as 0013, plus reporter_username on the log row.
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
     v_report.snapshot_text, v_place,
     coalesce(v_report.content_created_at, v_report.created_at),
     v_report.category, p_note);

  update public.content_reports
    set status = 'actioned', resolved_by = v_admin.id, resolved_at = (now() at time zone 'utc'),
        action_taken = 'Sender warned'
    where id = p_report_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_username, reporter_username, reason,
     content_snapshot, content_place, content_created_at, content_category)
    values
    (v_admin.id, v_admin.username, 'warn_user', v_report.target_username,
     v_report.reporter_username, p_note,
     v_report.snapshot_text, v_place,
     coalesce(v_report.content_created_at, v_report.created_at), v_report.category);

  perform public.notify_reporter_of_resolution(v_report, true);
end;
$$;

revoke all on function public.warn_user_for_report(text, uuid, text) from public;
grant execute on function public.warn_user_for_report(text, uuid, text) to anon;

-- No changes to ban_user, suspend_user, unban_user or unsuspend_user in
-- this migration — see the header comment above. They stay exactly as
-- 0008/0015 left them: unban_user(text, uuid), unsuspend_user(text, uuid),
-- ban_user(text, uuid, text), suspend_user(text, uuid, integer, text).
