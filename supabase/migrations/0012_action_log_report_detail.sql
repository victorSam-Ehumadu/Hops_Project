-- The Action Log could say "admin X warned student Y" but nothing about
-- *what for* — an admin reviewing the log had to go find the report
-- separately, and once a report is resolved it drops out of the Reports
-- queue entirely, so there was often nowhere left to look. This carries
-- the same detail the Reports tab shows onto the log entry itself.
--
-- Denormalized (copied at write time) rather than a foreign key to
-- content_reports, for exactly the reason admin_actions_log.target_username
-- is already denormalized: the log is an audit trail and has to stay
-- readable after the thing it describes is gone — including after
-- admin_delete_user removes the account and cascades away their reports.

alter table public.admin_actions_log
  add column if not exists content_snapshot text,
  add column if not exists content_place text,
  add column if not exists content_created_at timestamptz,
  add column if not exists content_category text;

-- ---------------------------------------------------------------------------
-- warn_user_for_report — same as 0011's version plus the snapshot copy.
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
end;
$$;

revoke all on function public.warn_user_for_report(text, uuid, text) from public;
grant execute on function public.warn_user_for_report(text, uuid, text) to anon;

-- ---------------------------------------------------------------------------
-- resolve_report — also carries the detail now, so a dismissed or
-- manually-actioned report leaves a log entry that still says what it was
-- about. Takes p_report_id (it always did) so the snapshot is a lookup
-- rather than another parameter for the client to pass and get wrong.
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
end;
$$;

revoke all on function public.resolve_report(text, uuid, text, text) from public;
grant execute on function public.resolve_report(text, uuid, text, text) to anon;
