-- Reports record when they were *filed*, but not when the reported thing
-- was actually sent — and those can be far apart (someone scrolls back
-- and reports a message from an hour ago). An admin deciding whether to
-- warn or ban needs both, and the warning the student receives should
-- name the time they actually sent the thing, not the time somebody got
-- around to reporting it.

-- ---------------------------------------------------------------------------
-- 1. The column. Nullable on purpose: reports filed before this migration
--    genuinely don't have this information and there's nothing sensible to
--    backfill it with — the admin UI shows "unknown" for those rather than
--    inventing a timestamp. Vibe Check reports also legitimately leave it
--    null when the tag's own timestamp isn't known to the reporting device.
-- ---------------------------------------------------------------------------
alter table public.content_reports
  add column if not exists content_created_at timestamptz;

-- ---------------------------------------------------------------------------
-- 2. submit_report — takes the new timestamp. Dropped and recreated rather
--    than CREATE OR REPLACE: adding a parameter changes the function's
--    identity, and Postgres won't replace across that.
--
--    p_content_created_at is last and defaulted so the existing call sites
--    that don't pass it keep working unchanged.
--
--    BOTH signatures are dropped, which is what makes this file safe to
--    re-run. A DROP names an exact argument list: dropping only the old
--    6-argument form leaves the 7-argument form this file itself created
--    on a previous run still in place, so the CREATE below then fails with
--    42723 ("function already exists with same argument types"). Dropping
--    both also rules out a window where both versions coexist — with every
--    trailing parameter defaulted, a 6-argument call would be ambiguous
--    between them and fail at the API layer.
-- ---------------------------------------------------------------------------
drop function if exists public.submit_report(text, text, text, text, text, text);
drop function if exists public.submit_report(text, text, text, text, text, text, timestamptz);

create function public.submit_report(
  p_hops_token text,
  p_content_type text,
  p_snapshot_text text,
  p_category text,
  p_target_username text default null,
  p_note text default null,
  p_content_created_at timestamptz default null
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
    (reporter_id, reporter_username, content_type, target_username,
     snapshot_text, category, note, content_created_at)
  values
    (v_reporter.id, v_reporter.username, p_content_type, p_target_username,
     p_snapshot_text, p_category, p_note, p_content_created_at)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.submit_report(text, text, text, text, text, text, timestamptz) from public;
grant execute on function public.submit_report(text, text, text, text, text, text, timestamptz) to anon;

-- ---------------------------------------------------------------------------
-- 3. warn_user_for_report — the warning's "when" should be when the content
--    was sent, falling back to the report's own timestamp only when that
--    isn't known (pre-migration reports, or a content type that can't
--    supply one). Otherwise identical to 0010's version.
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

  insert into public.admin_actions_log (actor_id, actor_username, action, target_username, reason)
    values (v_admin.id, v_admin.username, 'warn_user', v_report.target_username, p_note);
end;
$$;

revoke all on function public.warn_user_for_report(text, uuid, text) from public;
grant execute on function public.warn_user_for_report(text, uuid, text) to anon;
