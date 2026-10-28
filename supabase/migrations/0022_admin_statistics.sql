-- ---------------------------------------------------------------------------
-- 0022 — Admin statistics: arbitrary date ranges, time series for charts,
--        and a most-active-users ranking.
--
-- get_admin_dashboard_stats (0015) answers a fixed set of questions over
-- fixed windows (7d/30d) and returns single numbers. That is fine for the
-- dashboard's at-a-glance cards and is left exactly as it is. These three
-- functions are what a filterable, charted view needs instead:
--
--   get_admin_stats_range        totals over any [from, to)
--   get_admin_stats_timeseries   the same, bucketed, for plotting
--   get_admin_most_active_users  a ranking
--
-- WHAT "ACTIVITY" CAN MEAN HERE, AND WHAT IT CANNOT.
--
-- This is worth stating plainly because it is easy to promise more than
-- the architecture can deliver. Hops has no server-side data plane: chat
-- messages, vibe reports, tasks, study tags and games all live on the
-- device and never reach Postgres (see CLAUDE.md). So the server genuinely
-- cannot rank users by messages sent, and any statistic claiming to is
-- fabricated.
--
-- What the server does hold is identity and moderation. So "activity"
-- here means server-visible activity: reports filed, reports received,
-- warnings, moderation actions, official alerts, Emergency Flares raised
-- and account age. For a moderator that is arguably the more useful
-- ranking anyway — it surfaces who is generating moderation load — but it
-- should be labelled for what it is, which the UI does.
--
-- Emergency Flares are the exception worth knowing about: log_emergency_flare
-- writes to admin_actions_log with the RAISING STUDENT as actor_username,
-- so that table is not purely a record of admin activity. Anything
-- counting "admin actions" has to exclude action = 'emergency_flare' or it
-- double-counts student activity as moderation, which is why the queries
-- below do exactly that.
--
-- ALL RANGES ARE HALF-OPEN [from, to) IN UTC.
--
-- Deliberate: a closed range double-counts anything landing exactly on a
-- boundary when two adjacent periods are compared, and the client sends
-- UTC instants (see the Dart side's toUtc()). Every existing function in
-- this schema compares against `now() at time zone 'utc'`, so this stays
-- consistent with them.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. A shared admin check.
--
-- Every function below needs the identical six lines. Factored out so a
-- future statistic cannot be added with the check accidentally omitted —
-- these read moderation data, and an unauthorised one leaks the entire
-- report history.
-- ---------------------------------------------------------------------------
create or replace function public.assert_caller_is_admin(p_hops_token text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $fn$
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
end;
$fn$;

revoke all on function public.assert_caller_is_admin(text) from public;

-- ---------------------------------------------------------------------------
-- 2. Totals over an arbitrary range.
--
-- Two kinds of number here, and conflating them would mislead:
--
--   * PERIOD counts ("how many sign-ups between these dates") depend on
--     the range.
--   * STANDING totals ("how many accounts exist", "how many are banned
--     right now") are point-in-time and do NOT. They are returned with
--     the `current_` prefix so the UI can label them as "now" rather than
--     silently presenting them as if they belonged to the window.
-- ---------------------------------------------------------------------------
create or replace function public.get_admin_stats_range(
  p_hops_token text,
  p_from timestamptz,
  p_to timestamptz
) returns table (
  new_users bigint,
  reports_filed bigint,
  reports_resolved bigint,
  warnings_issued bigint,
  bans_issued bigint,
  suspensions_issued bigint,
  unbans_issued bigint,
  official_alerts bigint,
  emergency_flares bigint,
  admin_actions bigint,
  notifications_sent bigint,
  current_total_users bigint,
  current_banned bigint,
  current_suspended bigint,
  current_admins bigint,
  current_open_reports bigint,
  current_email_verified bigint
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.assert_caller_is_admin(p_hops_token);

  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range' using errcode = '22023';
  end if;

  return query
    select
      (select count(*) from public.profiles
        where created_at >= p_from and created_at < p_to),
      (select count(*) from public.content_reports
        where created_at >= p_from and created_at < p_to),
      -- Counted by when it was RESOLVED, not filed: this answers "how
      -- much did we get through in this period", which is a different
      -- question from how much arrived.
      (select count(*) from public.content_reports
        where status <> 'open'
          and resolved_at >= p_from and resolved_at < p_to),
      (select count(*) from public.admin_actions_log
        where action = 'warn_user'
          and created_at >= p_from and created_at < p_to),
      (select count(*) from public.admin_actions_log
        where action = 'ban'
          and created_at >= p_from and created_at < p_to),
      (select count(*) from public.admin_actions_log
        where action = 'suspend'
          and created_at >= p_from and created_at < p_to),
      (select count(*) from public.admin_actions_log
        where action = 'unban'
          and created_at >= p_from and created_at < p_to),
      (select count(*) from public.official_alerts_log
        where created_at >= p_from and created_at < p_to),
      -- Student-raised Emergency Flares. Logged to admin_actions_log by
      -- log_emergency_flare with the RAISER as actor, so unlike every
      -- other row in that table this one is not an admin action — which
      -- is also why admin_actions below would double-count it if read as
      -- "things admins did".
      (select count(*) from public.admin_actions_log
        where action = 'emergency_flare'
          and created_at >= p_from and created_at < p_to),
      (select count(*) from public.admin_actions_log
        where action <> 'emergency_flare'
          and created_at >= p_from and created_at < p_to),
      -- created_at, NOT occurred_at: the latter is when the reported
      -- content happened (nullable, and only set for warnings), so
      -- counting by it would both miss every plain 'info' notification
      -- and date the rest to the wrong period.
      (select count(*) from public.user_notifications
        where created_at >= p_from and created_at < p_to),
      -- Point-in-time from here down; range-independent by design.
      (select count(*) from public.profiles),
      (select count(*) from public.profiles where banned),
      (select count(*) from public.profiles
        where suspended_until is not null
          and suspended_until > (now() at time zone 'utc')),
      (select count(*) from public.profiles where role = 'admin'),
      (select count(*) from public.content_reports where status = 'open'),
      (select count(*) from public.profiles where email_verified);
end;
$fn$;

revoke all on function public.get_admin_stats_range(text, timestamptz, timestamptz) from public;
grant execute on function public.get_admin_stats_range(text, timestamptz, timestamptz) to anon;

-- ---------------------------------------------------------------------------
-- 3. The same counts, bucketed for a chart.
--
-- p_bucket is 'hour' or 'day'. Anything else is rejected rather than
-- defaulted: date_trunc takes the unit as text, so passing an unvalidated
-- value through would both allow surprising buckets and put caller-supplied
-- text into a function argument.
--
-- Buckets are generated with generate_series and LEFT JOINed, so periods
-- with no activity come back as zero rather than being absent. A chart
-- built from only non-empty buckets silently compresses quiet days and
-- misrepresents the shape of the data, which is the entire thing a chart
-- is for.
-- ---------------------------------------------------------------------------
create or replace function public.get_admin_stats_timeseries(
  p_hops_token text,
  p_from timestamptz,
  p_to timestamptz,
  p_bucket text default 'day'
) returns table (
  bucket timestamptz,
  new_users bigint,
  reports_filed bigint,
  moderation_actions bigint,
  official_alerts bigint,
  emergency_flares bigint
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_interval interval;
begin
  perform public.assert_caller_is_admin(p_hops_token);

  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range' using errcode = '22023';
  end if;

  if p_bucket = 'hour' then
    v_interval := interval '1 hour';
  elsif p_bucket = 'day' then
    v_interval := interval '1 day';
  else
    raise exception 'invalid_bucket' using errcode = '22023';
  end if;

  return query
    with buckets as (
      select generate_series(
               date_trunc(p_bucket, p_from),
               date_trunc(p_bucket, p_to - interval '1 microsecond'),
               v_interval) as b
    )
    select
      buckets.b,
      (select count(*) from public.profiles p
        where date_trunc(p_bucket, p.created_at) = buckets.b),
      (select count(*) from public.content_reports c
        where date_trunc(p_bucket, c.created_at) = buckets.b),
      (select count(*) from public.admin_actions_log a
        where a.action <> 'emergency_flare'
          and date_trunc(p_bucket, a.created_at) = buckets.b),
      (select count(*) from public.official_alerts_log o
        where date_trunc(p_bucket, o.created_at) = buckets.b),
      (select count(*) from public.admin_actions_log a
        where a.action = 'emergency_flare'
          and date_trunc(p_bucket, a.created_at) = buckets.b)
    from buckets
    order by buckets.b;
end;
$fn$;

revoke all on function public.get_admin_stats_timeseries(text, timestamptz, timestamptz, text) from public;
grant execute on function public.get_admin_stats_timeseries(text, timestamptz, timestamptz, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Most active users.
--
-- "Active" means server-visible activity only — see this file's header for
-- why that is a real limit and not an oversight. The score weights
-- moderation-relevant signals above neutral ones, because the use for this
-- ranking is deciding who needs attention:
--
--   reports received  x3   strongest signal that someone needs looking at
--   warnings received x5   already acted on once
--   reports filed     x1   engaged, and possibly over-reporting
--   alerts sent       x2   admins only
--   flares raised     x2   the one genuine student-activity signal here
--
-- Returned alongside the raw components, never as a bare score, so a
-- moderator can see WHY someone is ranked where they are. A single opaque
-- number would be acted on without that, which is the wrong way to use
-- this.
-- ---------------------------------------------------------------------------
create or replace function public.get_admin_most_active_users(
  p_hops_token text,
  p_from timestamptz,
  p_to timestamptz,
  p_limit int default 10
) returns table (
  user_id uuid,
  username text,
  role text,
  banned boolean,
  suspended boolean,
  reports_filed bigint,
  reports_received bigint,
  warnings_received bigint,
  alerts_sent bigint,
  flares_raised bigint,
  activity_score bigint,
  account_created timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $fn$
begin
  perform public.assert_caller_is_admin(p_hops_token);

  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_range' using errcode = '22023';
  end if;

  return query
    with filed as (
      select c.reporter_id as id, count(*) as n
        from public.content_reports c
       where c.created_at >= p_from and c.created_at < p_to
         and c.reporter_id is not null
       group by c.reporter_id
    ),
    -- Joined on username, not id: content_reports stores the target as a
    -- username (target_username) because a reported BLE payload carries a
    -- truncated sender tag and not an account id. Case-insensitive to
    -- match profiles_username_unique_ci from 0020.
    received as (
      select lower(c.target_username) as uname, count(*) as n
        from public.content_reports c
       where c.created_at >= p_from and c.created_at < p_to
         and c.target_username is not null
       group by lower(c.target_username)
    ),
    warned as (
      select lower(a.target_username) as uname, count(*) as n
        from public.admin_actions_log a
       where a.created_at >= p_from and a.created_at < p_to
         and a.action = 'warn_user'
         and a.target_username is not null
       group by lower(a.target_username)
    ),
    alerts as (
      select lower(o.admin_username) as uname, count(*) as n
        from public.official_alerts_log o
       where o.created_at >= p_from and o.created_at < p_to
         and o.admin_username is not null
       group by lower(o.admin_username)
    ),
    -- The one genuine student-activity signal the server holds: a flare
    -- is logged with the raiser as actor_username.
    flares as (
      select lower(a.actor_username) as uname, count(*) as n
        from public.admin_actions_log a
       where a.created_at >= p_from and a.created_at < p_to
         and a.action = 'emergency_flare'
       group by lower(a.actor_username)
    ),
    scored as (
      select
        p.id,
        p.username,
        p.role,
        p.banned,
        (p.suspended_until is not null
          and p.suspended_until > (now() at time zone 'utc')) as is_suspended,
        coalesce(f.n, 0) as n_filed,
        coalesce(r.n, 0) as n_received,
        coalesce(w.n, 0) as n_warned,
        coalesce(al.n, 0) as n_alerts,
        coalesce(fl.n, 0) as n_flares,
        p.created_at
      from public.profiles p
      left join filed f     on f.id = p.id
      left join received r  on r.uname = lower(p.username)
      left join warned w    on w.uname = lower(p.username)
      left join alerts al   on al.uname = lower(p.username)
      left join flares fl   on fl.uname = lower(p.username)
    )
    select
      s.id, s.username, s.role, s.banned, s.is_suspended,
      s.n_filed, s.n_received, s.n_warned, s.n_alerts, s.n_flares,
      (s.n_filed + s.n_received * 3 + s.n_warned * 5
        + s.n_alerts * 2 + s.n_flares * 2)::bigint,
      s.created_at
    from scored s
    -- Only users with something to show. Padding the list with inactive
    -- accounts would make an empty period look populated.
    where (s.n_filed + s.n_received + s.n_warned
            + s.n_alerts + s.n_flares) > 0
    order by
      (s.n_filed + s.n_received * 3 + s.n_warned * 5
        + s.n_alerts * 2 + s.n_flares * 2) desc,
      s.username asc
    limit greatest(1, least(coalesce(p_limit, 10), 100));
end;
$fn$;

revoke all on function public.get_admin_most_active_users(text, timestamptz, timestamptz, int) from public;
grant execute on function public.get_admin_most_active_users(text, timestamptz, timestamptz, int) to anon;

-- ---------------------------------------------------------------------------
-- 5. Indexes for the range scans above.
--
-- Every query here filters on a created_at range. Without these, each one
-- is a full scan of its table — fine at the current few-dozen rows,
-- noticeably not fine once the action log has been accumulating for a
-- term, and the custom-range picker makes it easy to ask for a wide one.
-- ---------------------------------------------------------------------------
create index if not exists profiles_created_at_idx
  on public.profiles (created_at);
create index if not exists content_reports_created_at_idx
  on public.content_reports (created_at);
create index if not exists content_reports_resolved_at_idx
  on public.content_reports (resolved_at);
create index if not exists admin_actions_log_action_created_idx
  on public.admin_actions_log (action, created_at);
create index if not exists official_alerts_log_created_at_idx
  on public.official_alerts_log (created_at);
-- user_notifications already has (recipient_id, created_at desc) from
-- 0010, which does not serve a bare created_at range scan.
create index if not exists user_notifications_created_at_idx
  on public.user_notifications (created_at);
