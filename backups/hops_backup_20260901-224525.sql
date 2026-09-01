--
-- PostgreSQL database dump
--

\restrict Df01knzDlfw4Tph30W7OWFmj8oDBiIUW5rZzOElWc8c7wqoNvevpXxRpND9XzA2

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: admin_clear_reporter_flag(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_clear_reporter_flag(p_hops_token text, p_target_id uuid, p_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: admin_delete_user(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_delete_user(p_hops_token text, p_target_id uuid, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: admin_get_user_detail(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_user_detail(p_hops_token text, p_target_id uuid) RETURNS TABLE(id uuid, username text, email text, role text, admin_title text, created_at timestamp with time zone, email_verified boolean, banned boolean, ban_reason text, banned_at timestamp with time zone, suspended_until timestamp with time zone, suspension_reason text, ban_count bigint, suspend_count bigint, warning_count bigint, reports_against bigint, reports_actioned_against bigint, reports_filed bigint, dismissed_reports_count integer, reporter_warned_at timestamp with time zone, reporter_flagged_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: admin_get_user_history(text, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_user_history(p_hops_token text, p_target_id uuid, p_limit integer DEFAULT 25) RETURNS TABLE(action text, actor_username text, reason text, content_snapshot text, content_place text, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: admin_list_flagged_reporters(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_list_flagged_reporters(p_hops_token text) RETURNS TABLE(id uuid, username text, email text, dismissed_reports_count integer, reports_filed bigint, reporter_flagged_at timestamp with time zone, banned boolean, suspended_until timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: admin_search_users(text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_search_users(p_hops_token text, p_query text DEFAULT NULL::text, p_limit integer DEFAULT 50) RETURNS TABLE(id uuid, username text, email text, role text, admin_title text, banned boolean, ban_reason text, email_verified boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: ban_user(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ban_user(p_hops_token text, p_target_id uuid, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: change_hops_email(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.change_hops_email(p_hops_token text, p_password_hash text, p_new_email text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_row public.profiles%rowtype;
begin
  if p_new_email is null or p_new_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;

  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_password_hash then
    return false;
  end if;

  begin
    update public.profiles
      set email = lower(p_new_email), email_verified = false
      where id = v_row.id;
  exception
    when unique_violation then
      raise exception 'email_taken' using errcode = '23505';
  end;

  return true;
end;
$_$;


--
-- Name: change_hops_password(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.change_hops_password(p_hops_token text, p_old_password_hash text, p_new_password_hash text, p_new_password_salt text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_row public.profiles%rowtype;
begin
  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_old_password_hash then
    return false;
  end if;

  update public.profiles
    set password_hash = p_new_password_hash,
        password_salt = coalesce(p_new_password_salt, '')
    where id = v_row.id;

  return true;
end;
$$;


--
-- Name: delete_hops_user(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_hops_user(p_hops_token text, p_password_hash text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_row public.profiles%rowtype;
begin
  select * into v_row
    from public.profiles p
    where p.hops_token = p_hops_token
      and p.token_expires_at > (now() at time zone 'utc');

  if not found or v_row.password_hash is distinct from p_password_hash then
    return false;
  end if;

  delete from public.profiles where id = v_row.id;

  return true;
end;
$$;


--
-- Name: demote_admin(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.demote_admin(p_hops_token text, p_target_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: get_admin_dashboard_stats(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_admin_dashboard_stats(p_hops_token text) RETURNS TABLE(total_users bigint, new_users_7d bigint, new_users_30d bigint, email_verified_count bigint, banned_count bigint, admin_count bigint, open_reports bigint, resolved_reports_30d bigint, bans_30d bigint, alerts_30d bigint, actions_30d bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: get_my_password_salt(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_password_salt(p_hops_token text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_salt text;
begin
  select password_salt into v_salt
    from public.profiles
    where hops_token = p_hops_token
      and token_expires_at > (now() at time zone 'utc');

  if v_salt is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  return v_salt;
end;
$$;


--
-- Name: get_my_status(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_my_status(p_hops_token text) RETURNS TABLE(role text, admin_title text, unread_notifications bigint)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: get_password_salt_by_email(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_password_salt_by_email(p_email text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_salt text;
begin
  select password_salt into v_salt
    from public.profiles
    where lower(email) = lower(p_email);

  if v_salt is not null then
    return v_salt;
  end if;

  return encode(digest('hops-no-such-account:' || lower(p_email), 'sha256'), 'hex');
end;
$$;


--
-- Name: is_reserved_username(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_reserved_username(p_username text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  select lower(btrim(coalesce(p_username, ''))) = any (
    array['hops', 'hopsbot', 'hops bot', 'hops_bot', 'hops-bot']
  );
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: admin_actions_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_actions_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    actor_id uuid,
    actor_username text NOT NULL,
    action text NOT NULL,
    target_username text,
    reason text,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    content_snapshot text,
    content_place text,
    content_created_at timestamp with time zone,
    content_category text,
    target_id uuid,
    reporter_username text,
    CONSTRAINT admin_actions_log_action_check CHECK ((action = ANY (ARRAY['ban'::text, 'unban'::text, 'delete_user'::text, 'promote_admin'::text, 'demote_admin'::text, 'resolve_report'::text, 'official_alert'::text, 'emergency_flare'::text, 'warn_user'::text, 'suspend'::text, 'unsuspend'::text, 'clear_reporter_flag'::text])))
);


--
-- Name: list_admin_actions_log(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_admin_actions_log(p_hops_token text, p_limit integer DEFAULT 100) RETURNS SETOF public.admin_actions_log
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: user_notifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recipient_id uuid NOT NULL,
    type text DEFAULT 'warning'::text NOT NULL,
    title text NOT NULL,
    message_snapshot text,
    place text,
    occurred_at timestamp with time zone,
    violation text,
    note text,
    read boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    CONSTRAINT user_notifications_type_check CHECK ((type = ANY (ARRAY['warning'::text, 'info'::text])))
);


--
-- Name: list_my_notifications(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_my_notifications(p_hops_token text) RETURNS SETOF public.user_notifications
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: content_reports; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.content_reports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reporter_id uuid,
    reporter_username text NOT NULL,
    content_type text NOT NULL,
    target_username text,
    snapshot_text text NOT NULL,
    category text NOT NULL,
    note text,
    status text DEFAULT 'open'::text NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    action_taken text,
    content_created_at timestamp with time zone,
    CONSTRAINT content_reports_category_check CHECK ((category = ANY (ARRAY['spam'::text, 'harassment'::text, 'inappropriate'::text, 'other'::text]))),
    CONSTRAINT content_reports_content_type_check CHECK ((content_type = ANY (ARRAY['chat_message'::text, 'vibe_check'::text, 'contact_profile'::text, 'study_bunny'::text, 'lost_found'::text]))),
    CONSTRAINT content_reports_status_check CHECK ((status = ANY (ARRAY['open'::text, 'actioned'::text, 'dismissed'::text])))
);


--
-- Name: list_open_reports(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_open_reports(p_hops_token text) RETURNS SETOF public.content_reports
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: list_pending_admin_requests(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_pending_admin_requests(p_hops_token text) RETURNS TABLE(id uuid, requester_id uuid, requester_username text, note text, created_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: log_emergency_flare(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_emergency_flare(p_hops_token text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: log_official_alert(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_official_alert(p_hops_token text, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: mark_all_notifications_read(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mark_all_notifications_read(p_hops_token text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: notify_reporter_of_resolution(public.content_reports, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notify_reporter_of_resolution(p_report public.content_reports, p_actioned boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: promote_admin(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.promote_admin(p_hops_token text, p_target_id uuid, p_admin_title text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: refresh_public_key(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.refresh_public_key(p_hops_token text, p_public_key text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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

  update public.profiles set public_key = p_public_key where id = v_caller_id;
end;
$$;


--
-- Name: request_admin_access(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.request_admin_access(p_hops_token text, p_note text DEFAULT NULL::text) RETURNS TABLE(id uuid, status text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: resolve_report(text, uuid, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.resolve_report(p_hops_token text, p_report_id uuid, p_status text, p_action_taken text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: review_admin_request(text, uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.review_admin_request(p_hops_token text, p_request_id uuid, p_approve boolean) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: signin_hops_user(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.signin_hops_user(p_username text, p_password_hash text) RETURNS TABLE(id uuid, username text, public_key text, hops_token text, token_expires_at timestamp with time zone, role text, admin_title text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: signin_hops_user_by_email(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.signin_hops_user_by_email(p_email text, p_password_hash text) RETURNS TABLE(id uuid, username text, public_key text, hops_token text, token_expires_at timestamp with time zone, role text, admin_title text, email_verified boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_row public.profiles%rowtype;
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz;
begin
  -- Matches email AND password together (see comment above) — with
  -- duplicate emails now allowed, this is what picks the right account
  -- instead of an arbitrary one sharing the same address.
  select * into v_row
    from public.profiles p
    where lower(p.email) = lower(p_email)
      and p.password_hash = p_password_hash;

  if not found then
    return; -- empty result set — client treats as invalid credentials
  end if;

  if v_row.banned then
    raise exception 'account_banned' using errcode = '28000', detail = coalesce(v_row.ban_reason, '');
  end if;

  v_expires := (now() at time zone 'utc')
    + case when v_row.role = 'admin' then interval '90 days' else interval '24 hours' end;

  update public.profiles
    set hops_token = v_token, token_expires_at = v_expires
    where public.profiles.id = v_row.id;

  return query select v_row.id, v_row.username, v_row.public_key, v_token, v_expires,
    v_row.role, v_row.admin_title, v_row.email_verified;
end;
$$;


--
-- Name: signup_hops_user(text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.signup_hops_user(p_username text, p_email text, p_public_key text, p_password_hash text, p_password_salt text) RETURNS TABLE(id uuid, hops_token text, token_expires_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $_$
declare
  v_id uuid := gen_random_uuid();
  v_token text := gen_random_uuid()::text;
  v_expires timestamptz := (now() at time zone 'utc') + interval '24 hours';
  v_constraint text;
begin
  if char_length(p_username) < 3 or char_length(p_username) > 20 then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  if p_email is null or p_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;

  insert into public.profiles (id, username, email, public_key, password_hash, password_salt, hops_token, token_expires_at)
  values (v_id, p_username, lower(p_email), p_public_key, p_password_hash, coalesce(p_password_salt, ''), v_token, v_expires);

  return query select v_id, v_token, v_expires;
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'profiles_email_unique' then
      raise exception 'email_taken' using errcode = '23505';
    else
      raise exception 'username_taken' using errcode = '23505';
    end if;
end;
$_$;


--
-- Name: submit_report(text, text, text, text, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.submit_report(p_hops_token text, p_content_type text, p_snapshot_text text, p_category text, p_target_username text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_content_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: suspend_user(text, uuid, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.suspend_user(p_hops_token text, p_target_id uuid, p_days integer, p_reason text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: unban_user(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.unban_user(p_hops_token text, p_target_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: unsuspend_user(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.unsuspend_user(p_hops_token text, p_target_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: verify_account_otp(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_account_otp(p_hops_token text, p_otp_hash text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_profile_id uuid;
  v_otp public.email_verification_otps%rowtype;
begin
  select id into v_profile_id
    from public.profiles
    where hops_token = p_hops_token
      and token_expires_at > (now() at time zone 'utc');

  if v_profile_id is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  select * into v_otp
    from public.email_verification_otps
    where profile_id = v_profile_id
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.email_verification_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  update public.email_verification_otps set used = true where id = v_otp.id;
  return true;
end;
$$;


--
-- Name: verify_password_reset_otp(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_password_reset_otp(p_email text, p_otp_hash text, p_new_password_hash text, p_new_password_salt text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_otp public.password_reset_otps%rowtype;
  v_profile_id uuid;
begin
  select * into v_otp
    from public.password_reset_otps
    where lower(email) = lower(p_email)
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.password_reset_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  select id into v_profile_id from public.profiles where lower(email) = lower(p_email);
  if v_profile_id is null then
    return false;
  end if;

  update public.password_reset_otps set used = true where id = v_otp.id;
  update public.profiles
    set password_hash = p_new_password_hash,
        password_salt = coalesce(p_new_password_salt, '')
    where id = v_profile_id;

  return true;
end;
$$;


--
-- Name: verify_signup_email_otp(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_signup_email_otp(p_hops_token text, p_otp_hash text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_profile_id uuid;
  v_otp public.email_verification_otps%rowtype;
begin
  select id into v_profile_id
    from public.profiles
    where hops_token = p_hops_token
      and token_expires_at > (now() at time zone 'utc');

  if v_profile_id is null then
    raise exception 'invalid_session' using errcode = '28000';
  end if;

  select * into v_otp
    from public.email_verification_otps
    where profile_id = v_profile_id
      and used = false
      and expires_at > (now() at time zone 'utc')
    order by created_at desc
    limit 1;

  if not found or v_otp.attempts >= 5 then
    return false;
  end if;

  if v_otp.otp_hash is distinct from p_otp_hash then
    update public.email_verification_otps set attempts = attempts + 1 where id = v_otp.id;
    return false;
  end if;

  update public.email_verification_otps set used = true where id = v_otp.id;
  update public.profiles set email_verified = true where id = v_profile_id;

  return true;
end;
$$;


--
-- Name: warn_user_for_report(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.warn_user_for_report(p_hops_token text, p_report_id uuid, p_note text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: admin_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_requests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    requester_id uuid NOT NULL,
    note text,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    reviewed_by uuid,
    reviewed_at timestamp with time zone,
    CONSTRAINT admin_requests_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text])))
);


--
-- Name: email_verification_otps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_verification_otps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    otp_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used boolean DEFAULT false NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL
);


--
-- Name: official_alerts_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.official_alerts_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    admin_id uuid,
    admin_username text NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL
);


--
-- Name: password_reset_otps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.password_reset_otps (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email text NOT NULL,
    otp_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used boolean DEFAULT false NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username text NOT NULL,
    public_key text NOT NULL,
    hops_token text NOT NULL,
    created_at timestamp with time zone DEFAULT (now() AT TIME ZONE 'utc'::text) NOT NULL,
    token_expires_at timestamp with time zone NOT NULL,
    password_hash text,
    role text DEFAULT 'student'::text NOT NULL,
    admin_title text,
    email text,
    email_verified boolean DEFAULT false NOT NULL,
    banned boolean DEFAULT false NOT NULL,
    ban_reason text,
    banned_at timestamp with time zone,
    banned_by uuid,
    suspended_until timestamp with time zone,
    suspension_reason text,
    dismissed_reports_count integer DEFAULT 0 NOT NULL,
    reporter_warned_at timestamp with time zone,
    reporter_flagged_at timestamp with time zone,
    password_salt text DEFAULT ''::text NOT NULL,
    CONSTRAINT profiles_role_check CHECK ((role = ANY (ARRAY['student'::text, 'admin'::text])))
);


--
-- Name: COLUMN profiles.public_key; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.public_key IS 'The RSA/ED25519 public key distributed across the mesh to verify sender signatures.';


--
-- Name: profiles_public; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.profiles_public AS
 SELECT id,
    username,
    public_key,
    role,
    admin_title
   FROM public.profiles;


--
-- Data for Name: admin_actions_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.admin_actions_log (id, actor_id, actor_username, action, target_username, reason, created_at, content_snapshot, content_place, content_created_at, content_category, target_id, reporter_username) FROM stdin;
07c36f89-a2c6-4057-84a8-f935ccbf5066	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Content actioned	2026-08-15 13:30:05.617475+00	\N	\N	\N	\N	\N	\N
3cca1433-79b1-4d00-abf5-f9ad5dcd5ae0	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Content actioned	2026-08-15 13:31:51.510523+00	\N	\N	\N	\N	\N	\N
d517f4ae-3cde-4f8b-9a74-82a0b6cb3e83	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	ban	test1	Inappropriate behavior	2026-08-15 13:33:10.38581+00	\N	\N	\N	\N	\N	\N
ce7c1032-1be2-48c6-b82d-741478cc47a3	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	unban	test1	\N	2026-08-15 13:54:59.885152+00	\N	\N	\N	\N	\N	\N
776ed8ec-b85c-406f-9ba5-04ca344dc8ca	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Content actioned	2026-08-15 14:46:58.660379+00	\N	\N	\N	\N	\N	\N
08fd974f-ab65-4a39-a3b0-0a27001bcb8f	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Dismissed	2026-08-15 16:27:37.692148+00	\N	\N	\N	\N	\N	\N
bcd2d536-4104-4a10-8506-a1cf40a55c3d	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Dismissed	2026-08-15 16:38:38.281757+00	\N	\N	\N	\N	\N	\N
2b449829-1321-4c25-88b3-0859b9d33e34	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Content actioned	2026-08-15 18:16:40.360563+00	\N	\N	\N	\N	\N	\N
82608ab7-d70a-40e7-a9a8-fc83c9ccb449	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Dismissed	2026-08-15 18:19:35.222168+00	\N	\N	\N	\N	\N	\N
4eb118c4-b2dd-44ac-94f2-8081a8c8ee1c	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	official_alert	\N	fire	2026-08-15 18:20:02.374766+00	\N	\N	\N	\N	\N	\N
ad7c4779-9be1-4ab6-b8d4-0ae9f3a1b63b	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Dismissed	2026-08-15 18:31:36.035883+00	\N	\N	\N	\N	\N	\N
ab498b46-85a4-4c65-bad8-1bcbecc86cc0	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	warn_user	test2	bad	2026-08-15 20:36:15.163737+00	you good?	Community Chat	2026-08-15 19:31:02.633913+00	harassment	\N	\N
a853e3f7-26ca-4a92-bad8-ed4bf91b602a	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	ban	test2	misconduct	2026-08-16 09:06:52.953775+00	\N	\N	\N	\N	\N	\N
8f1b4ef6-58f7-4142-87d3-26928463f96f	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	unban	test2	\N	2026-08-16 09:43:31.063032+00	\N	\N	\N	\N	\N	\N
985f0467-7321-4202-9545-e5730736c88e	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Content actioned	2026-08-16 20:14:38.704784+00	love in the air: Quiet	Vibe Check	2026-08-16 20:04:47.235008+00	spam	\N	\N
5c1f78ff-4eab-4743-a765-9339e2e52115	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Dismissed	2026-08-16 20:19:25.619047+00	gc njbc: Quiet	Vibe Check	2026-08-16 20:05:56.144+00	spam	\N	\N
db9d006f-29b4-4daf-a9c6-9f9603f367bd	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	official_alert	\N	Fire	2026-08-16 20:34:14.783434+00	\N	\N	\N	\N	\N	\N
67d61e6a-1691-4c53-b2ee-e7c20e5c0387	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	suspend	test1	Misconduct (1 days)	2026-08-16 21:56:50.025564+00	\N	\N	\N	\N	202c1a17-9605-47ed-b4ea-51f48057eb6c	\N
b418a5bb-90d2-49ba-82bc-1aff1874f007	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	unsuspend	test1	\N	2026-08-16 21:57:10.265176+00	\N	\N	\N	\N	202c1a17-9605-47ed-b4ea-51f48057eb6c	\N
e20fb24e-770d-4cfe-8275-751fca14f6bd	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	ban	test1	Misconduct	2026-08-16 21:57:26.82994+00	\N	\N	\N	\N	202c1a17-9605-47ed-b4ea-51f48057eb6c	\N
453aaf6b-5563-4afa-8c8c-9fa3a73c99f3	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	unban	test1	\N	2026-08-17 05:07:26.149927+00	\N	\N	\N	\N	\N	\N
6c8764e8-a17b-4edb-bf0d-f2604eba8afe	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	suspend	test1	 (1 days)	2026-08-17 05:12:12.894036+00	\N	\N	\N	\N	202c1a17-9605-47ed-b4ea-51f48057eb6c	\N
c17d8046-c4f4-4910-8140-c548269ef305	\N	test1	emergency_flare	\N	fire	2026-08-15 18:20:51.266251+00	\N	\N	\N	\N	\N	\N
96dabce2-27ba-41a4-8c62-5730d3068e85	\N	test1	emergency_flare	\N	vvdd	2026-08-15 18:30:56.775154+00	\N	\N	\N	\N	\N	\N
9f5942a8-f116-4d49-995f-1fd2e4923785	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	resolve_report	\N	Content actioned	2026-08-17 12:42:20.953201+00	venue 1: Moderate	Vibe Check	2026-08-17 12:37:21.082053+00	harassment	\N	Test2
9638cf2c-376b-4417-92ce-126df0046893	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	ban	Thrishen	Misconduct	2026-08-17 12:42:55.938881+00	\N	\N	\N	\N	d205b7b1-174e-4464-965f-af863768badd	\N
15af1eb7-3164-4f7b-8cb5-bee530a3abb0	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	unban	Thrishen	\N	2026-08-17 12:43:57.557012+00	\N	\N	\N	\N	\N	\N
a0dc0016-9d9e-486f-8077-30cadfd58d2d	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	official_alert	\N	Fire	2026-08-17 12:45:26.386848+00	\N	\N	\N	\N	\N	\N
00f2af13-6e1d-4622-820c-0975551e6311	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	official_alert	\N	Bye	2026-08-17 12:45:54.62152+00	\N	\N	\N	\N	\N	\N
30f261a2-e485-462b-b9e7-aca2bb9ff8d7	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	delete_user	hopsdiagtest1	\N	2026-08-18 14:17:44.130711+00	\N	\N	\N	\N	\N	\N
\.


--
-- Data for Name: admin_requests; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.admin_requests (id, requester_id, note, status, created_at, reviewed_by, reviewed_at) FROM stdin;
\.


--
-- Data for Name: content_reports; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.content_reports (id, reporter_id, reporter_username, content_type, target_username, snapshot_text, category, note, status, created_at, resolved_by, resolved_at, action_taken, content_created_at) FROM stdin;
fdb9dd4b-c831-497b-a935-efbd07a931e5	\N	test2	vibe_check	\N	lib: Busy	spam	\N	actioned	2026-08-15 13:29:32.921226+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 13:30:05.617475+00	Content actioned	\N
5f29551b-d491-47c8-8255-107954c0c477	\N	test2	vibe_check	\N	love in the air: Packed	harassment	\N	actioned	2026-08-15 13:31:25.140687+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 13:31:51.510523+00	Content actioned	\N
ec6cc9ee-6f2a-4ef6-acc2-cda0508ef545	\N	test2	vibe_check	\N	love in the air: Quiet	spam	\N	actioned	2026-08-16 20:05:31.730929+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-16 20:14:38.704784+00	Content actioned	2026-08-16 20:04:47.235008+00
79737edd-f0bd-4ad8-8113-b1925bd8d33c	\N	test2	vibe_check	\N	gc njbc: Quiet	spam	\N	dismissed	2026-08-16 20:17:05.186086+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-16 20:19:25.619047+00	Dismissed	2026-08-16 20:05:56.144+00
a7c0d55d-e8b6-46ee-8c7c-f9adfee45b22	\N	test1	vibe_check	\N	love me: Busy	inappropriate	\N	actioned	2026-08-15 14:46:12.697591+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 14:46:58.660379+00	Content actioned	\N
fced739c-7efd-41de-b6d6-218a72d7aa8d	\N	test1	vibe_check	\N	my ffjhfdf: Busy	spam	\N	dismissed	2026-08-15 14:52:44.708771+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 16:27:37.692148+00	Dismissed	\N
cbde26e9-2acc-40c8-9352-083776b7ded3	\N	test1	chat_message	Anonymous #Kh53	test	spam	\N	dismissed	2026-08-15 16:29:22.14445+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 16:38:38.281757+00	Dismissed	\N
601de430-408c-4760-9f0b-f2485e62523a	\N	test1	vibe_check	\N	tvvg: Moderate	spam	\N	actioned	2026-08-15 18:16:00.514133+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 18:16:40.360563+00	Content actioned	2026-08-15 18:15:35.177461+00
99849b72-c0c5-4ae1-a524-489473168140	\N	test1	vibe_check	\N	tvvg: Moderate	harassment	\N	dismissed	2026-08-15 18:16:53.542521+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 18:19:35.222168+00	Dismissed	2026-08-15 18:15:35.177461+00
340b83d7-3476-4f71-82e4-0c64d93fda06	\N	test1	chat_message	Anonymous #Kh53	test	harassment	\N	dismissed	2026-08-15 18:27:14.195959+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 18:31:36.035883+00	Dismissed	2026-08-15 16:24:12.976+00
78a7cb53-5ef0-454e-bd16-9277830aef09	\N	test1	chat_message	test2	you good?	harassment	\N	actioned	2026-08-15 20:35:53.516323+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-15 20:36:15.163737+00	Sender warned	2026-08-15 19:31:02.633913+00
d574495b-6937-4c20-9867-9b4da98e1630	7fff40bc-6371-48e2-841c-7f202fc13753	Test2	vibe_check	\N	venue 1: Moderate	harassment	\N	actioned	2026-08-17 12:38:34.930246+00	7e1e5223-71cc-4837-9169-7148d1fdb1af	2026-08-17 12:42:20.953201+00	Content actioned	2026-08-17 12:37:21.082053+00
\.


--
-- Data for Name: email_verification_otps; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.email_verification_otps (id, profile_id, otp_hash, expires_at, used, attempts, created_at) FROM stdin;
d7dbfb10-2d0d-4d4d-b595-b6aa87bdee01	7e1e5223-71cc-4837-9169-7148d1fdb1af	719294639d25bcf223ba94d8a1c46f7e5a8003751ba246fec32c34f26b51112a	2026-08-14 10:55:13.83+00	t	0	2026-08-14 10:45:13.883307+00
69679c79-cb66-4ed1-b964-6dd63a9b53af	7fff40bc-6371-48e2-841c-7f202fc13753	b48696037ec1ff5453367be660f9ac1ae622b457f00359e4625651ab9bb39489	2026-08-17 10:15:58.609+00	f	0	2026-08-17 10:05:58.665838+00
07377998-0576-46e4-907b-d55711886d86	d205b7b1-174e-4464-965f-af863768badd	e60c8313e439ec3a16c33396f8e78730715a2f1c7330b3ab719d01020dc53ed8	2026-08-17 12:47:20.538+00	t	0	2026-08-17 12:37:20.633991+00
5b4b3bf2-9ed9-41f5-90e8-436681997993	c77d87f8-3113-4ad0-83c1-608343d50500	76723aa7fb864cac764c11fa941f781ced1fd73bf0cdef5f7b5a2aef416d5db1	2026-08-17 13:03:51.017+00	t	0	2026-08-17 12:53:51.069383+00
9d08b56e-9ea8-4223-9678-efb07be93e84	674b8419-8600-4777-a079-415ce7d75f49	21855e9c45052aae14a4083b6116ce13c41fcb28600aa416e8455260c9bc2f09	2026-08-17 13:19:30.632+00	t	0	2026-08-17 13:09:30.716339+00
3f9a493a-4e42-4375-96e3-0148cfb063f8	7dda75b3-9381-4234-b47e-3abc4e9060ec	a12847f624c7961f2d0aa65e733c15b7608527e7748f9c4731f178583f0b5c8f	2026-08-17 21:23:33.57+00	t	0	2026-08-17 21:13:33.622925+00
0c0e99a1-6411-4698-b71f-b132a7247c32	535d9a04-1965-4a7d-afaa-18afba54705a	75911b43e6505412402db5409acdb4ad0d9a6984e2d2be4457a1c172bdfd53ad	2026-08-24 11:10:51.977+00	t	0	2026-08-24 11:00:52.033767+00
c54b80dd-ddde-477b-9744-a92132c33295	a4bec4d7-5c9c-4f53-a519-01d08c8179db	7a490a3f198aef72936b8f5bdd3ef39d898876d9cc616c9a9d6f76b428e4ea03	2026-08-24 11:18:00.983+00	t	0	2026-08-24 11:08:01.075268+00
623dbfe3-6867-44d8-80e1-89866c6b40de	153c4dd4-cffa-4c87-97ce-39aa1de3d278	0ccbb09bcfd77ff82740a703ddd1a5bfbfcb85be1fdfe3fe365d3219ac7d8078	2026-08-27 07:17:45.437+00	f	0	2026-08-27 07:07:45.542854+00
b72e5eed-8f55-450f-adc2-c09dff2f5d48	153c4dd4-cffa-4c87-97ce-39aa1de3d278	b67f98875b8ab42dd5f87f7080bd3e380e5931fced62d83cf7863f2c7ba323c3	2026-08-27 07:18:57.509+00	t	0	2026-08-27 07:08:57.612684+00
\.


--
-- Data for Name: official_alerts_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.official_alerts_log (id, admin_id, admin_username, reason, created_at) FROM stdin;
fe86a14b-baa1-46e9-85f3-4d8c29034960	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	fire	2026-08-15 18:20:02.374766+00
5809e484-f330-43e1-915b-f026b84d5c67	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	Fire	2026-08-16 20:34:14.783434+00
e1800bda-7773-4faa-9e37-0d5da44ff25f	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	Fire	2026-08-17 12:45:26.386848+00
36945f09-7a42-4bd6-bd71-6b1084b67202	7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	Bye	2026-08-17 12:45:54.62152+00
\.


--
-- Data for Name: password_reset_otps; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.password_reset_otps (id, email, otp_hash, expires_at, used, attempts, created_at) FROM stdin;
462119c0-3071-4a63-b0c8-6f070351171e	victorsamehumadu@gmail.com	30394745aec700dea379c4eb85bab7269df851e97bcf6258d39f74a6ba64aeb0	2026-08-17 08:40:36.919+00	f	0	2026-08-17 08:30:37.030136+00
\.


--
-- Data for Name: profiles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.profiles (id, username, public_key, hops_token, created_at, token_expires_at, password_hash, role, admin_title, email, email_verified, banned, ban_reason, banned_at, banned_by, suspended_until, suspension_reason, dismissed_reports_count, reporter_warned_at, reporter_flagged_at, password_salt) FROM stdin;
674b8419-8600-4777-a079-415ce7d75f49	sadieee	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuHF60bEvSQc1JPr2y3FFMM9MmIS7+PP4VgjQKsyiyxkLG5/N8qiUwY8B3VSoZZSZrZXt3+8VeERmXIe1cQgj7x0mLszRiiNTx3NH7bJTEG72kYGrmiQ0c+mm9erL55oHw5TdjVdTp01DMiNJp+/RHGxpt9Ip96qy95cPKrNyZXDK7h1jA/4kSHj4yVxPoLztMq+x+92lc7SI5LES+SpbC48zFVNta0eYNx7VkVsujwl0OyF7hH2Y/9P/ivvELxDxdt1Wy8g7iOhDIUMcD3nwR9w7yIqt15tq9V23AVud4EhcyYmj5XJSxrUNDvUiBCy3YqAhW/XH7TMgpNIgC1K8XwIDAQAB	c95bcbf0-df17-4945-bd71-4697f6866ab0	2026-08-17 13:09:29.622058+00	2026-08-18 13:09:29.622058+00	b9317e72d71aa40bb153457f08263b0573a7e9e4e847a4e3127a1dc7f13cb474	student	\N	sadereddy7@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	
7fff40bc-6371-48e2-841c-7f202fc13753	Test2	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAreY5lR8SJ/+uwsU50H7Nm09r2bWEwal3MqE7new5wwWjf54QYxnVm4g171bZW8UbMe7qpgC3gGrw0y7Ay1ji45Ghj3U1HM2I06uo0L+YaOgLC1rNL8Yg/+0k5MqUEz6Wh7Dyaa6N6SrGI6hsdWLNREDrEgPHWenUdXCKQu4fXfgNgUI1dpfpcwXdDhpjEll51sYTPcTylczEhx3MUGq2o4H/Agce8QhfrHr990RBNFaAeQhd/W1lc3tuzzJFEhz4Wmf/RjjXVeULikSbd8m3eR3MGUBiN6RBOb6IhCMepNevSnQli5A3/r0nlEg0bgkcAdAHXKO9uwTwgfZ/Q1sdqwIDAQAB	fb4756f5-6fc1-4261-9639-1f84fe5fd3dc	2026-08-17 10:05:57.0613+00	2026-08-18 21:16:06.094796+00	d714c5fce369cde88db5e85f99e15dd5cbbd9d6822c8aaa63766b38f257feb6a	student	\N	victorsamehumadu@gmail.com	f	f	\N	\N	\N	\N	\N	0	\N	\N	
7dda75b3-9381-4234-b47e-3abc4e9060ec	Vik	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAm3ctvumYtqcfmSXcCdKNtHnZHmc2E5Bhbm/830+5RxCsuhkKmxlIvDu0DO0RtyyM78QnAD98L6cWOmh8ceMB8lCUVT8d4kYR3OoUn4YYe6BQL/+DeTgLtWaCT6EVbiVR/8eiqN4/tHWMSgPwVMq5/PcFsSpcBGEQK79PbBuC0sshY4zkhb4JIasemLyGwy5FO9YDmx6rafJtdVDL7HR+fJ48LFy2SkBy2oYRDHoYAtHUXLMbIePUzgZ2CETpKFGAFtzFWHgKucYYgnGG6Plw6T3dIkpcjuTKuIxFNCNg1hgXHUHvvph9OsDBhtlVLzXjfYyrRYpWp90hFVhwi0AxxwIDAQAB	78f40a1a-e70d-4bbc-9dc2-6938a135e48c	2026-08-17 21:13:31.778669+00	2026-08-18 21:13:31.778669+00	3b4f09c3ba84ffea25c6fcda3d3bd51d6bebf0b9359159289fdc00591336cdea	student	\N	vikkysamehumadu@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	
d205b7b1-174e-4464-965f-af863768badd	Thrishen	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAmHVrj4NCRORpXLXbIcafXfBCEoYkHv11cVyyu8WbeJL2D4l/NPvM8rlLDVdxswGenC/5YY/DhGvJEYOvHJdA3Y1OZn2JVYIdePEoxYDxz7auNT3/fI/GgDxwh0n3GK+T/G82WuRURjxX24WY+xWqbY8c6QgpUmQv76/VwIbYBbMoTZoV6yAPy8bLfn+V/K8qMNXFoyzUThpKAQlefejrsoGMvyqIzbNPigkBKhU+mNJ/+TstTYBkhU+zA5+WwYmOYHgAnEJfYs3pPLOo8hYxn8N0UShu7MaA0ETKWihQiX0o7wpknRcQ/wved+xbZi2XI6CmMq1N3buhs4w+rYWnZwIDAQAB	31edbb53-b8e6-42f3-9bea-0b5618dcd8cb	2026-08-17 12:37:19.601982+00	2026-08-18 12:44:00.909025+00	2af16060578ebda72082a06913dfb045682d73e3cc27757eee31c8fe1cfcf914	student	\N	thrishen02@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	
535d9a04-1965-4a7d-afaa-18afba54705a	noellblanc	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAr01plYze/6wTOVXcsOfB96Yt5bCka1v/14jwwov0XwqVKowT3ter4U05HqFInC71p8OTAmSLELD9Ez3fRZK7dItxYeqnepG+zJw4Z1B/i51BSGwktxGJgQ+Mb2UCFsdUzAIZW0U0reqdUNBYHROQklW3MSRYMu2Y52C0nogR3HkitIpngrnKdhvDBj3sULrCoCvHGQ85vKY0ZKjHric18ItytQzQocfJ+WtiH8lK/P0CjO60dXIWm90pwmDlzcUtcSCiXAc492Sq+Y9ypk96yMnNMgFfUc5fedDQ6KmxBMxrdSri+3WiTCGOZ070N7sdH/65R9H0KRc89zcU5mcUHQIDAQAB	bf12023b-fb7b-481a-916b-d04c892ac995	2026-08-24 11:00:50.528756+00	2026-08-25 11:00:50.528756+00	e10d85f1e042895fa2b9a211d1ab15d5b3e60e8e5aa0e1f5006a4a324c9880cf	student	\N	hlonipha19n@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	4251edc616c330f5576a1fbc8b66ad7f
a4bec4d7-5c9c-4f53-a519-01d08c8179db	jkay1501	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuwpfiE1p3Qi17kfZ6B/PqCU0VgzNmJeprsjyN3exQRY2brp09aRBymQx2S/OhkbTRUZw6QokSDyvKlpg+eo1/T78zqJzMLZJd09Z+WURgsx6qh/7SLm5n6NdhjHuHPuIYHjNdzL0Qvik8eZYy2k4fMdIBSCl8kRf7tNvvvsvG11/KraovKZD569TCJ9WwMkRwIUj56IKZ7fqsj0gFsEO4FQ75wyRbDwVru73WpA2qEWd17v+0IAECuGzYEByULWjWy3fn1vwuiE88UZhq87DuAGriJs2zUfDtWjBe2ETUPQG+7Np7MW246eymZIKOQ7ltKdnnPP7saNdiHUBU8WriQIDAQAB	987fcf0a-84ea-4ec1-80f0-94781a224304	2026-08-24 11:08:00.090468+00	2026-08-25 11:08:00.090468+00	f0388e5baa6877d8c22392b7a5072c1e40b0901cd1c07e4f4ec49dae3c360cc4	student	\N	kayliepillay38@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	7c4c2ebcb7bfe3c7f839872f6965c5b4
7e1e5223-71cc-4837-9169-7148d1fdb1af	HopsDev	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiawnEOqIc4tuvIPNrztdI1rZvHr6WVCF35iKW4CpxFE80qHkLnExDAJT0KlO6R7VXYDzPVqJxpLqeB9TQ+KDOG966cYNmIQmhVKVDuBaPKmZ/hzrakPESzjYAHxyTIDWC3LrUtApkiI80U2wu21P+ZkQYJy3kvDILkwovg3Yanrlo0vMc/vfxNAr/VjrgJLAUXX6pICHWPOMJosp1uz+L8giIiajOzb7BaY/et6st/XCIX5V++oaTATkCVDDTrQtnXk6J7NVERm0FleQMI49EqUKdGtGAqK/PCpBbqQSF7dVNmQvPbsZ/vJfsw995DRFht8pSf+MaZB0Ii/vucTblwIDAQAB	ab240b3f-1266-4408-a41d-cf3e12760c90	2026-08-14 10:45:11.127244+00	2026-11-13 14:40:38.826875+00	2ad8ef90fc3b773d60816464b48fef0e4a365c7ee47ca7cccc86f5981501450c	admin	\N	victorsamehumadu@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	
c77d87f8-3113-4ad0-83c1-608343d50500	elijah01	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3M5iCqYNX7j5NsqDh8/+W2aBmJZ8oeu41qSzQ3Kgq4F3tdGcH4x98/0arAUtvghXl1wkUvs/MrdiOyqFdC9E8TSTTR1xvF0Kkp8x87nNzc2HOhhLgD7rTnDe0jrolk55nzRY3iNgWYTqr+2LEDmqxdAU4nNySOFmo9e16jsh4ZW8VXSwJcvvJ4Yv43o7jP00gJcPE/L/M+x2GCoHxxGvnSNnruS6DwEQpCUtBlJ4xtyRFTGZNajENU+LUOp6ozJGyhJPhIwGwvqJo/vFtK6N/Hd8PF03loo4aAtu3ZonVhHSF5zA9Jo95Hm9iin+NpPkDZlVP0KOfoavcGQYV8vlCwIDAQAB	0d2a8ebf-7461-4949-9d1c-bd943d01aaee	2026-08-17 12:53:49.787514+00	2026-08-18 12:53:49.787514+00	e2e4a71d380a3648d6c9d2f0c4069623c43fab68af6748fadd08e2023abf75f4	student	\N	elijahjadenpillay@outlook.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	
153c4dd4-cffa-4c87-97ce-39aa1de3d278	diya	MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjrF1XppRJpYOvn+RyBmAnfeuX/+3HaiLnw4xliyHBlSf5CiXIyDeEbmd/DFQAG00oF1Myw21myPTx6fEn0XCu6R1QGM5uiv4Kc7B8l8KJJo2m6xTV1fvbEtDSKM6iZeD+Xru2q3MRXKGf0wFF2l1OVHE7D4V9u397bKZTw1Xc1zTs61iwcGWOcnPhvHvCBgySILzwhLqUa29tAvQa6fIje6zmaAcWB/ZeSLwrSneo+J9Kt9l7dQ7ItkGueT/gdzj+FYmO2fP1IM1lppIafW4OC+h7wpea4JCKDK17rGK18Iq03hiQtdAslAS798s1o4KXD/PblEUnL9eFZtltsD+RQIDAQAB	9a5a9254-3552-4640-ba42-9651053b4600	2026-08-27 07:07:44.085934+00	2026-08-28 07:07:44.085934+00	60fa426ec6ba8e9651013bfea9ed8daead08687e8b5a666561ee19e7973c1049	student	\N	dasingh5002@gmail.com	t	f	\N	\N	\N	\N	\N	0	\N	\N	8499c34be9445145ca9a474735b38d3a
\.


--
-- Data for Name: user_notifications; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.user_notifications (id, recipient_id, type, title, message_snapshot, place, occurred_at, violation, note, read, created_at) FROM stdin;
923fac28-0f13-4c21-897b-b6323dfb8939	7fff40bc-6371-48e2-841c-7f202fc13753	info	Your report was reviewed — action was taken	venue 1: Moderate	Vibe Check	2026-08-17 12:37:21.082053+00	\N	Thanks for flagging this. An admin reviewed it and took the necessary action.	t	2026-08-17 12:42:20.953201+00
\.


--
-- Name: admin_actions_log admin_actions_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_actions_log
    ADD CONSTRAINT admin_actions_log_pkey PRIMARY KEY (id);


--
-- Name: admin_requests admin_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_requests
    ADD CONSTRAINT admin_requests_pkey PRIMARY KEY (id);


--
-- Name: content_reports content_reports_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_pkey PRIMARY KEY (id);


--
-- Name: email_verification_otps email_verification_otps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verification_otps
    ADD CONSTRAINT email_verification_otps_pkey PRIMARY KEY (id);


--
-- Name: official_alerts_log official_alerts_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.official_alerts_log
    ADD CONSTRAINT official_alerts_log_pkey PRIMARY KEY (id);


--
-- Name: password_reset_otps password_reset_otps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.password_reset_otps
    ADD CONSTRAINT password_reset_otps_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_hops_token_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_hops_token_key UNIQUE (hops_token);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_username_key UNIQUE (username);


--
-- Name: profiles profiles_username_length_check; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_username_length_check CHECK (((char_length(username) >= 3) AND (char_length(username) <= 20))) NOT VALID;


--
-- Name: profiles profiles_username_not_reserved; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.profiles
    ADD CONSTRAINT profiles_username_not_reserved CHECK ((NOT public.is_reserved_username(username))) NOT VALID;


--
-- Name: user_notifications user_notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_notifications
    ADD CONSTRAINT user_notifications_pkey PRIMARY KEY (id);


--
-- Name: admin_actions_log_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX admin_actions_log_created_idx ON public.admin_actions_log USING btree (created_at DESC);


--
-- Name: admin_requests_one_pending_per_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX admin_requests_one_pending_per_user ON public.admin_requests USING btree (requester_id) WHERE (status = 'pending'::text);


--
-- Name: content_reports_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX content_reports_status_idx ON public.content_reports USING btree (status, created_at);


--
-- Name: email_verification_otps_profile_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX email_verification_otps_profile_idx ON public.email_verification_otps USING btree (profile_id);


--
-- Name: idx_profiles_hops_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_profiles_hops_token ON public.profiles USING btree (hops_token);


--
-- Name: password_reset_otps_email_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX password_reset_otps_email_idx ON public.password_reset_otps USING btree (lower(email));


--
-- Name: profiles_reporter_flagged_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX profiles_reporter_flagged_idx ON public.profiles USING btree (reporter_flagged_at) WHERE (reporter_flagged_at IS NOT NULL);


--
-- Name: user_notifications_recipient_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_notifications_recipient_idx ON public.user_notifications USING btree (recipient_id, created_at DESC);


--
-- Name: admin_actions_log admin_actions_log_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_actions_log
    ADD CONSTRAINT admin_actions_log_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: admin_requests admin_requests_requester_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_requests
    ADD CONSTRAINT admin_requests_requester_id_fkey FOREIGN KEY (requester_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: admin_requests admin_requests_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_requests
    ADD CONSTRAINT admin_requests_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES public.profiles(id);


--
-- Name: content_reports content_reports_reporter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_reporter_id_fkey FOREIGN KEY (reporter_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: content_reports content_reports_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.content_reports
    ADD CONSTRAINT content_reports_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES public.profiles(id);


--
-- Name: email_verification_otps email_verification_otps_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verification_otps
    ADD CONSTRAINT email_verification_otps_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: official_alerts_log official_alerts_log_admin_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.official_alerts_log
    ADD CONSTRAINT official_alerts_log_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES public.profiles(id) ON DELETE SET NULL;


--
-- Name: profiles profiles_banned_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_banned_by_fkey FOREIGN KEY (banned_by) REFERENCES public.profiles(id);


--
-- Name: user_notifications user_notifications_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_notifications
    ADD CONSTRAINT user_notifications_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: admin_actions_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_actions_log ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_requests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: content_reports; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.content_reports ENABLE ROW LEVEL SECURITY;

--
-- Name: email_verification_otps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.email_verification_otps ENABLE ROW LEVEL SECURITY;

--
-- Name: official_alerts_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.official_alerts_log ENABLE ROW LEVEL SECURITY;

--
-- Name: password_reset_otps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.password_reset_otps ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: user_notifications; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_notifications ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict Df01knzDlfw4Tph30W7OWFmj8oDBiIUW5rZzOElWc8c7wqoNvevpXxRpND9XzA2

