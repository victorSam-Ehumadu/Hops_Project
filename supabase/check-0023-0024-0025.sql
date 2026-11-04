-- check-0023-0024-0025.sql
--
-- Did the three outstanding migrations actually take?
--
-- Read-only and safe to run any time. Paste the whole thing into the
-- Supabase SQL editor and press Run — unlike check-applied-migrations.sql
-- this is a SINGLE query, so the editor's "only the last result set is
-- shown" behaviour cannot hide half the answer.
--
-- Every row should read PASS. A FAIL means that migration did not apply,
-- and the feature it backs will fail at runtime rather than at deploy —
-- which is exactly how a missing migration has been mistaken for an app
-- bug on this project before.

select *
from (
  -- ── 0023: the salt lookup can reach pgcrypto ────────────────────────
  --
  -- pgcrypto lives in the `extensions` schema on Supabase, not `public`.
  -- Without it on the search_path the function cannot run its
  -- no-such-account branch, and a mistyped email surfaced to the user as
  -- "something went wrong on our end" instead of a wrong-password message.
  select
    1 as seq,
    '0023  get_password_salt_by_email search_path' as check,
    case
      when exists (
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = 'get_password_salt_by_email'
          and array_to_string(p.proconfig, ',') like '%extensions%'
      ) then 'PASS'
      else 'FAIL - reapply 0023'
    end as result

  union all

  -- ── 0024: the Community Alerts catch-up path ────────────────────────
  --
  -- Without this, an alert only ever arrives over Bluetooth. A student
  -- whose Bluetooth was off — or who has never been online, and so has an
  -- empty key directory — silently receives nothing at all.
  select 2,
    '0024  community_alerts table',
    case when to_regclass('public.community_alerts') is not null
         then 'PASS' else 'FAIL - reapply 0024' end

  union all

  select 3,
    '0024  post / list / delete RPCs',
    case when (
      select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('post_community_alert',
                          'list_community_alerts',
                          'delete_community_alert')
    ) = 3 then 'PASS' else 'FAIL - reapply 0024' end

  union all

  -- ── 0025: manual reporter flagging ──────────────────────────────────
  --
  -- Two halves, and BOTH are needed. The function does the work; the log's
  -- CHECK constraint has to accept the new action or the insert at the end
  -- of it fails and takes the whole flag down with it.
  select 4,
    '0025  admin_flag_reporter exists',
    case when exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_flag_reporter'
    ) then 'PASS' else 'FAIL - reapply 0025' end

  union all

  select 5,
    '0025  action log accepts flag_reporter',
    case when exists (
      select 1 from pg_constraint
      where conname = 'admin_actions_log_action_check'
        and pg_get_constraintdef(oid) like '%flag_reporter%'
    ) then 'PASS' else 'FAIL - reapply 0025' end

  union all

  -- ── Shape check, not a migration ────────────────────────────────────
  --
  -- RLS on with zero policies is the design: everything goes through
  -- SECURITY DEFINER functions. A policy appearing here means something
  -- changed and the deny-all posture no longer holds.
  select 6,
    'posture  RLS policies (expect 0)',
    case when (select count(*) from pg_policies
               where schemaname = 'public') = 0
         then 'PASS' else 'FAIL - a policy was added' end
) checks
order by seq;
