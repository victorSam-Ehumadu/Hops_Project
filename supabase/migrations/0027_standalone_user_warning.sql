-- ---------------------------------------------------------------------------
-- 0027 — warn a user directly, not only through a report.
--
-- WHY
--
-- Hops moderation is meant to warn three times before anything harsher, but
-- the only way to issue a warning was warn_user_for_report (0010, revised in
-- 0011): it takes a REPORT id, requires that report to be open, and closes it
-- as 'actioned' on the way out. That makes a warning something you can only
-- do *as the disposal of one report*.
--
-- Two consequences, both bad for a three-strike policy:
--
--   1. The Take Action sheet (admin_user_detail_screen) is where every other
--      moderation decision is made — ban, suspend, flag, delete — and it is
--      user-centric, not report-centric. It had no Warn at all, so the
--      escalation ladder was missing its first two rungs exactly where an
--      admin goes to climb it.
--   2. A warning that does not arise from a report — something an admin saw
--      themselves, or a pattern across several reports — could not be issued
--      at all.
--
-- WHAT THIS ADDS
--
-- warn_user(p_hops_token, p_target_id, p_note) — the same warning, addressed
-- to an account rather than to a report. It does NOT touch content_reports:
-- deciding a report's disposal is a separate judgement from warning someone,
-- and conflating them is what made the existing function unusable here.
--
-- warn_user_for_report is deliberately LEFT ALONE. The report card's own
-- "Send warning" button still uses it and still closes the report, which is
-- correct for that surface.
--
-- THE RETURN VALUE IS THE POINT
--
-- It returns the account's warning count *after* this one, so the admin app
-- can say "warning 2 of 3" at the moment of acting rather than making the
-- admin go and count. The count is deliberately derived the same way
-- admin_get_user_detail.warning_count is — user_notifications rows of type
-- 'warning' — so the number on the Record section and the number in the
-- confirmation can never disagree.
--
-- NOT ENFORCEMENT. Three warnings does not auto-ban anybody. The threshold is
-- a policy an admin applies, and automating it here would mean a ban nobody
-- decided to issue — see the standing rule in CLAUDE.md that moderation
-- outcomes are judgement calls. This only makes the count impossible to miss.
-- ---------------------------------------------------------------------------

begin;

create or replace function public.warn_user(
  p_hops_token text,
  p_target_id uuid,
  p_note text default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.profiles%rowtype;
  v_target public.profiles%rowtype;
  v_count bigint;
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

  -- An admin warning another admin is allowed (they are accountable too),
  -- but warning YOURSELF is always a mistake, and a self-warning would
  -- quietly inflate your own strike count.
  if v_target.id = v_admin.id then
    raise exception 'cannot_warn_self' using errcode = '22023';
  end if;

  -- message_snapshot/place/occurred_at/violation stay null: those four
  -- describe the reported content a warning came from, and this warning did
  -- not come from one. The student's notification screen already renders a
  -- warning with only a title and a note (they are nullable precisely so a
  -- plain notification can exist).
  insert into public.user_notifications (recipient_id, type, title, note)
    values (p_target_id, 'warning',
            'You received a warning from a Hops admin', p_note);

  insert into public.admin_actions_log
    (actor_id, actor_username, action, target_id, target_username, reason)
    values (v_admin.id, v_admin.username, 'warn_user',
            v_target.id, v_target.username, p_note);

  select count(*) into v_count
    from public.user_notifications n
    where n.recipient_id = p_target_id and n.type = 'warning';

  return v_count;
end;
$$;

revoke all on function public.warn_user(text, uuid, text) from public;
grant execute on function public.warn_user(text, uuid, text) to anon;

commit;
