-- 0025_manual_reporter_flag.sql
--
-- Lets an admin flag an account for wrongful reporting by hand.
--
-- The flag itself is not new: 0015 added profiles.reporter_flagged_at, the
-- dismissed_reports_count that drives it, and admin_clear_reporter_flag to
-- lift it. What was missing is any way to SET it deliberately. Until now
-- the only route was automatic — the counter reaching c_flag_threshold
-- after enough dismissed reports — so an admin looking at one obviously
-- malicious report had nothing to do about the person who filed it except
-- wait for them to do it several more times.
--
-- That asymmetry is the bug: there was a "forgive" with no "act", and the
-- forgiving action already existed in the log's allowed-action list while
-- its counterpart did not.
--
-- Deliberately separate from warn_user: a warning is addressed to the
-- person and tells them something, while a flag is a note to other admins
-- about the weight their future reports should carry. Conflating them
-- would mean an admin could not do one without doing the other.

-- ---------------------------------------------------------------------------
-- 1. The log has to accept the new action, or the insert below fails the
--    CHECK and takes the whole flag with it.
-- ---------------------------------------------------------------------------
alter table public.admin_actions_log drop constraint if exists admin_actions_log_action_check;
alter table public.admin_actions_log
  add constraint admin_actions_log_action_check check (action in
    ('ban', 'unban', 'delete_user', 'promote_admin', 'demote_admin',
     'resolve_report', 'official_alert', 'emergency_flare', 'warn_user',
     'suspend', 'unsuspend', 'clear_reporter_flag', 'flag_reporter'));

-- ---------------------------------------------------------------------------
-- 2. Flag an account for wrongful reporting.
--
-- Idempotent on the timestamp: re-flagging an already-flagged account
-- keeps the ORIGINAL flag time rather than resetting it, because
-- "flagged since" is the useful fact and a second admin looking at the
-- same account should not quietly restart the clock. The action is still
-- logged every time, so the fact that two admins both thought so is not
-- lost.
-- ---------------------------------------------------------------------------
create or replace function public.admin_flag_reporter(
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

  -- An admin flagging themselves is always a mistake, and the account that
  -- can clear its own flag gains nothing from carrying one.
  if v_target.id = v_admin.id then
    raise exception 'cannot_flag_self' using errcode = '22023';
  end if;

  update public.profiles
    set reporter_flagged_at = coalesce(reporter_flagged_at, (now() at time zone 'utc'))
    where id = p_target_id;

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_id, target_username, reason)
    values (v_admin.id, v_admin.username, 'flag_reporter', v_target.id, v_target.username, p_note);
end;
$$;

revoke all on function public.admin_flag_reporter(text, uuid, text) from public;
grant execute on function public.admin_flag_reporter(text, uuid, text) to anon;
