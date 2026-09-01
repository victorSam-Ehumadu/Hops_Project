-- Reporting something was a one-way street: a student filed a report and
-- then never heard anything again, whether it was acted on, dismissed, or
-- silently ignored. That's a good way to train people out of reporting at
-- all. Every resolution path now sends the reporter a confirmation.
--
-- Deliberately vague about the outcome. The reporter is told their report
-- was reviewed and whether action was taken — never *what* action, and
-- never anything about the other account. Whether someone was warned,
-- banned or deleted is between the admin and that person; telling a
-- reporter "the user you reported has been banned" hands out moderation
-- outcomes about third parties to anyone willing to file a report.

-- ---------------------------------------------------------------------------
-- 1. 'info' notifications need to be listable the same way warnings are —
--    user_notifications already allows type='info' (0010) and
--    list_my_notifications returns every row for the caller, so nothing
--    schema-side changes here. This migration only rewires the two
--    resolution RPCs.
-- ---------------------------------------------------------------------------

-- Shared body for "tell the reporter we looked at it". Kept as its own
-- function so resolve_report and warn_user_for_report can't drift apart in
-- what they say. Not granted to anon — it's only ever called internally by
-- the SECURITY DEFINER functions below, which already gate on admin.
create or replace function public.notify_reporter_of_resolution(
  p_report public.content_reports,
  p_actioned boolean
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Reports from a since-deleted account have reporter_id set to null by
  -- the ON DELETE SET NULL on that column — nothing to notify.
  if p_report.reporter_id is null then
    return;
  end if;

  insert into public.user_notifications
    (recipient_id, type, title, message_snapshot, place, occurred_at, note)
  values (
    p_report.reporter_id,
    'info',
    case when p_actioned
      then 'Your report was reviewed — action was taken'
      else 'Your report was reviewed'
    end,
    p_report.snapshot_text,
    case p_report.content_type
      when 'chat_message' then 'Community Chat'
      when 'vibe_check' then 'Vibe Check'
      when 'contact_profile' then 'Profile'
      else p_report.content_type
    end,
    coalesce(p_report.content_created_at, p_report.created_at),
    case when p_actioned
      then 'Thanks for flagging this. An admin reviewed it and took the necessary action.'
      else 'Thanks for flagging this. An admin reviewed it and found no action was needed this time.'
    end
  );
end;
$$;

revoke all on function public.notify_reporter_of_resolution(public.content_reports, boolean) from public;

-- ---------------------------------------------------------------------------
-- 2. resolve_report — as 0012, plus the reporter confirmation.
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
  v_admin public.profiles%rowtype;
  v_report public.content_reports%rowtype;
  v_place text;
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

  perform public.notify_reporter_of_resolution(v_report, p_status = 'actioned');
end;
$$;

revoke all on function public.resolve_report(text, uuid, text, text) from public;
grant execute on function public.resolve_report(text, uuid, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. warn_user_for_report — as 0012, plus the reporter confirmation.
--    Always 'actioned' here by definition: a warning was sent.
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
    (actor_id, actor_username, action, target_username, reason,
     content_snapshot, content_place, content_created_at, content_category)
    values
    (v_admin.id, v_admin.username, 'warn_user', v_report.target_username, p_note,
     v_report.snapshot_text, v_place,
     coalesce(v_report.content_created_at, v_report.created_at), v_report.category);

  perform public.notify_reporter_of_resolution(v_report, true);
end;
$$;

revoke all on function public.warn_user_for_report(text, uuid, text) from public;
grant execute on function public.warn_user_for_report(text, uuid, text) to anon;
