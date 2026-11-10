    -- ---------------------------------------------------------------------------
    -- 0029 — keep admins out of "most active users".
    --
    -- WHY
    --
    -- The ranking scores five signals, and two of them are things only an
    -- admin can do: issuing a warning (weight 5) and broadcasting an Official
    -- Alert (weight 2). So an admin doing their job climbs a leaderboard whose
    -- stated purpose is showing which STUDENTS are using the app.
    --
    -- That is not merely untidy. The whole screen exists so a moderator can
    -- see activity at a glance, and an admin reading their own name at the top
    -- learns nothing about their campus. Worse, the per-column numbers make the
    -- list look like a student ranking with an anomaly in it, rather than two
    -- different populations mixed together.
    --
    -- Rather than reweight, this excludes role = 'admin' outright. Reweighting
    -- would still leave an admin on the list on the strength of reports filed
    -- against them, which is an even stranger thing for this screen to rank.
    --
    -- EVERYTHING ELSE IS UNCHANGED, deliberately: same five signals, same
    -- weights (filed 1, received 3, warned 5, alerts 2, flares 2), same
    -- half-open [from, to) range, same "only users with something to show"
    -- filter. The admin app now displays those weights in an info sheet, so a
    -- change here would make that sheet wrong — if the weights are ever
    -- revised, admin_statistics_screen.dart's _showScoringInfo must be revised
    -- in the same commit.
    --
    -- The warned/alerts columns stay in the signature even though they can now
    -- only ever be 0 for a listed user: dropping them would change the return
    -- shape and break the client, and a non-admin CAN be warned, so n_warned
    -- is still meaningful on its own.
    -- ---------------------------------------------------------------------------

    -- MATCH THE RETURN SHAPE EXACTLY. The first draft of this file renamed two
    -- output columns — `id` for `user_id` and `is_suspended` for `suspended` —
    -- transcribed from memory rather than read out of 0022. Postgres refused it
    -- outright:
    --
    --   42P13: cannot change return type of existing function
    --   DETAIL: Row type defined by OUT parameters is different.
    --
    -- That refusal was the safety net doing its job. The hint suggests DROP
    -- FUNCTION first, and following it would have "worked" — and then
    -- admin_stats_service.dart, which reads r['user_id'] and r['suspended'] by
    -- name, would have got null for both and the Most Active Users list would
    -- have gone quietly blank with no error anywhere.
    --
    -- So: never DROP to get past 42P13 on a function the app reads by column
    -- name. Read the live signature and match it.
    --
    begin;

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
      with
        filed as (
          select c.reporter_id as id, count(*) as n
            from public.content_reports c
           where c.created_at >= p_from and c.created_at < p_to
             and c.reporter_id is not null
           group by c.reporter_id
        ),
        -- Reports are stored against a username, not an id: the reporting
        -- device may only know a truncated sender tag. Case-insensitive to
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
              -- Named is_suspended, NOT suspended, matching 0022. The OUT
              -- parameter is called `suspended`, and in PL/pgSQL a column of
              -- the same name is ambiguous against it — which fails at call
              -- time, not at create time. 0022 sidestepped it this way and
              -- this must keep doing so.
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
          -- THE CHANGE. Filtered here rather than in the final WHERE so the
          -- aggregates above are never computed for accounts that cannot
          -- appear — and so a future reader sees the exclusion next to the
          -- table it applies to.
          --
          -- `is distinct from` rather than `<> 'admin'`: role is nullable in
          -- principle, and a null would make a plain inequality yield NULL
          -- and silently drop that account from the list entirely.
          where p.role is distinct from 'admin'
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

    commit;

    -- ===========================================================================
    -- AFTERWARDS
    -- ===========================================================================
    --
    --   No admin should appear:
    --     select username, role, activity_score
    --     from public.get_admin_most_active_users(
    --       '<an admin hops_token>',
    --       (now() at time zone 'utc') - interval '30 days',
    --       (now() at time zone 'utc'),
    --       20);
    --   Expect no row with role = 'admin'. If the list is now empty, that is
    --   a real finding rather than a fault: it means every scoring signal in
    --   the window belonged to admins.
    -- ===========================================================================
