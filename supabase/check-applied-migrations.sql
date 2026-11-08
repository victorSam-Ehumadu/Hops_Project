-- Which migrations in supabase/migrations/ are actually applied?
--
-- WHERE TO RUN THIS
--
--   Supabase dashboard -> your project -> SQL Editor -> New query.
--   Paste, then run. Read-only: nothing here writes, locks or drops
--   anything, so it is safe against the live project at any time.
--
-- HOW TO RUN IT — THIS FILE HOLDS TWO QUERIES
--
--   The Supabase SQL Editor displays only the LAST result set when you run
--   several statements at once. Run the whole file and you will see only
--   QUERY 2 (usually empty) and conclude nothing happened.
--
--   So run them one at a time: SELECT the lines of one query with the
--   mouse and press Run / Ctrl+Enter. The editor runs just the selection.
--
--     QUERY 1  the migration report      -- start at "with probe(...)"
--     QUERY 2  duplicate usernames       -- start at the banner near the end
--
--   Query 1 is the one you want. Query 2 only matters if Query 1 reports
--   "0020 (a) unique username index" as not applied.
--
--   psql works too, and shows both:
--     psql "<session-pooler-URI>" -f supabase/check-applied-migrations.sql
--
-- WHY THIS EXISTS
--
-- These migrations are applied by hand in the SQL editor, so there is no
-- schema_migrations table recording what went in. That has already cost
-- real debugging time: admin_user_detail_screen.dart carries a hard-coded
-- "Server missing this action — run migration 0015" error string, and the
-- duplicate-username bug came down to public.profiles having been created
-- in the dashboard rather than by a migration, so nobody could say which
-- constraints it carried.
--
-- Each row probes for an artifact that only exists once that migration has
-- run. Where a migration only REPLACES an existing function, the probe
-- looks inside the function body (pg_proc.prosrc) for text unique to the
-- new version — that is the only way to tell a replaced function's
-- version apart, since the name and signature are unchanged.
--
-- READING THE RESULT
--
-- Rows needing action sort to the top and are marked '>> TODO'. If the
-- first row says 'ok', nothing is missing. Everything below the TODO block
-- is already in place.
--
-- The `applied` column means "the database is in the state this repository
-- expects", which is not always "this migration ran": 0026 is written but
-- DELIBERATELY unapplied (it drops profiles.email irreversibly and is gated
-- on both Vault keys living off the database — see its header), so its
-- healthy state is the column still being there. Keeping the column's
-- meaning uniform is what makes the TODO sort trustworthy.
--
-- COVERAGE
--
-- 0001-0027. Three throwaway scripts used to cover the tail of this range
-- (check-0023-0024-0025.sql, check-migrations-quick.sql) and were deleted
-- once this file caught up — two probes that can disagree about the same
-- database is worse than one that is occasionally behind.
--
-- WHEN YOU ADD A MIGRATION, ADD A PROBE HERE. A migration with no row in
-- this file is invisible to the only tool that can tell you it is missing,
-- and "a missing migration mistaken for an app bug" has already cost real
-- time more than once.

-- ===========================================================================
-- QUERY 1 OF 2 — THE MIGRATION REPORT.  Select from here to the first
-- semicolon (the "order by seq;" line) and Run.
-- ===========================================================================
with probe(seq, migration, applied, evidence) as (
  select 1, '0001_lockdown_profiles',
    to_regclass('public.profiles_public') is not null,
    'view profiles_public'
  union all select 2, '0002_admin_roles',
    to_regclass('public.admin_requests') is not null,
    'table admin_requests'
  union all select 3, '0003_refresh_public_key',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'refresh_public_key'),
    'function refresh_public_key'
  union all select 4, '0004_admin_flare_support',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'admin_title'),
    'profiles.admin_title'
  union all select 5, '0005_get_my_status',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'get_my_status'),
    'function get_my_status'
  union all select 6, '0006_account_management',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'delete_hops_user'),
    'function delete_hops_user'
  union all select 7, '0007_email_auth_and_otp',
    to_regclass('public.password_reset_otps') is not null
      and to_regclass('public.email_verification_otps') is not null,
    'OTP tables'
  union all select 8, '0008_admin_moderation',
    to_regclass('public.admin_actions_log') is not null
      and exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'profiles'
                     and column_name = 'banned'),
    'admin_actions_log + profiles.banned'
  union all select 9, '0009_allow_duplicate_signup_emails_for_testing',
    not exists (select 1 from pg_indexes
                 where schemaname = 'public' and indexname = 'profiles_email_unique'),
    'profiles_email_unique DROPPED (testing relaxation — see 0009 header)'
  union all select 10, '0010_notifications_and_logging',
    to_regclass('public.user_notifications') is not null,
    'table user_notifications'
  union all select 11, '0011_report_content_timestamp',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'content_reports'
               and column_name = 'content_created_at'),
    'content_reports.content_created_at'
  union all select 12, '0012_action_log_report_detail',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'resolve_report'),
    'function resolve_report'
  union all select 13, '0013_notify_reporter_on_resolution',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'notify_reporter_of_resolution'),
    'function notify_reporter_of_resolution'
  union all select 14, '0014_reserve_bot_usernames',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'is_reserved_username'),
    'function is_reserved_username'
  union all select 15, '0015_admin_management',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'suspended_until')
      and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'suspend_user'),
    'profiles.suspended_until + function suspend_user'
  -- Was probing resolve_report for '%target_email%', which NEVER appears
  -- in 0016 — that file's own header says the moderation email is handled
  -- client-side and "nothing in THIS file changes for it". So the probe
  -- reported 0016 as missing on a database where it was applied. What 0016
  -- actually adds is admin_actions_log.reporter_username, so a
  -- report-driven log row can show who reported as well as who was
  -- reported.
  union all select 16, '0016_moderation_email_and_log_detail',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'admin_actions_log'
               and column_name = 'reporter_username')
      and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'resolve_report'
                     and p.prosrc like '%reporter_username%'),
    'admin_actions_log.reporter_username + resolve_report writes it'
  union all select 17, '0017_report_content_types_study_lost_found',
    exists (select 1 from pg_constraint c
             join pg_class t on t.oid = c.conrelid
             where t.relname = 'content_reports'
               and pg_get_constraintdef(c.oid) like '%study%'),
    'content_reports content_type allows study/lost-found'
  union all select 18, '0018_salted_password_hashing',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'password_salt')
      and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'signup_hops_user'
                     and p.pronargs = 5),
    'profiles.password_salt + signup_hops_user/5'
  union all select 19, '0019_account_change_otp',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'verify_account_otp'),
    'function verify_account_otp'

  -- 0020 gets three separate probes: the index is what stops duplicate
  -- usernames, and the two sign-in functions are what stop a suspended
  -- user signing back in. All three must be present — the index alone
  -- would leave suspension unenforced at sign-in, and vice versa.
  union all select 20, '0020 (a) unique username index',
    exists (select 1 from pg_indexes
             where schemaname = 'public' and indexname = 'profiles_username_unique_ci'),
    'unique index profiles_username_unique_ci on lower(username)'
  union all select 21, '0020 (b) sign-in blocks suspension',
    (select bool_and(p.prosrc like '%account_suspended%')
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('signin_hops_user', 'signin_hops_user_by_email')),
    'both signin functions raise account_suspended'
  union all select 22, '0020 (c) reserved-name check restored',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'signup_hops_user'
               and p.pronargs = 5
               and p.prosrc like '%is_reserved_username%'),
    'signup_hops_user/5 checks is_reserved_username'

  -- 0021 and 0022, same per-half treatment as 0020: each probe covers one
  -- thing that can be missing on its own.
  union all select 23, '0021 (a) institutional domain rule',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'is_allowed_account_email'),
    'function is_allowed_account_email'
  union all select 24, '0021 (b) signup enforces the domain',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'signup_hops_user'
               and p.pronargs = 5
               and p.prosrc like '%is_allowed_account_email%'),
    'signup_hops_user/5 calls is_allowed_account_email'
  union all select 25, '0021 (c) email encryption columns',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'email_encrypted')
      and exists (select 1 from information_schema.columns
                   where table_schema = 'public' and table_name = 'profiles'
                     and column_name = 'email_lookup'),
    'profiles.email_encrypted + email_lookup'
  -- Separate from (c) because 0021 adds the columns but SKIPS the backfill
  -- when the keys are unavailable, leaving them all null. Columns present
  -- with no keys is a half-done state, not a done one.
  --
  -- Reads VAULT, not a database parameter. The first version of 0021 kept
  -- the keys in `app.email_encryption_key` via `alter database ... set`,
  -- which cannot work on Supabase (that needs superuser; the postgres role
  -- is not one). 0021 was rewritten to use Vault and this probe was left
  -- checking the parameter, so it reported "not applied" for keys that
  -- were present and working.
  union all select 26, '0021 (d) Vault keys present',
    coalesce((select count(*) >= 2 from vault.decrypted_secrets
               where name in ('hops_email_encryption_key',
                              'hops_email_blind_index_key')), false),
    'two Vault secrets named hops_email_*'
  union all select 27, '0021 (e) email actually encrypted',
    not exists (select 1 from public.profiles
                 where email is not null and email_encrypted is null),
    'every row with an email has ciphertext (null = backfill never ran)'
  union all select 28, '0022 statistics functions',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('get_admin_stats_range',
                          'get_admin_stats_timeseries',
                          'get_admin_most_active_users',
                          'assert_caller_is_admin')) = 4,
    'all four statistics functions present'
  union all select 29, '0023 salt lookup search_path',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public'
               and p.proname = 'get_password_salt_by_email'
               and array_to_string(p.proconfig, ',') like '%extensions%'),
    'get_password_salt_by_email has extensions on its search_path'
  union all select 30, '0024 (a) community_alerts table',
    to_regclass('public.community_alerts') is not null,
    'table community_alerts — the 9th table; a backup reporting 8 means this never ran'
  union all select 31, '0024 (b) community alert functions',
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('post_community_alert',
                          'list_community_alerts',
                          'delete_community_alert')) = 3,
    -- list_, NOT fetch_. This probe shipped with the wrong name and
    -- reported a false NO against a database where 0024 was applied
    -- perfectly well. Names here are now cross-checked against
    -- supabase/migrations/ rather than recalled.
    'all three community alert functions present'
  union all select 32, '0025 manual reporter flag',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'admin_flag_reporter'),
    'function admin_flag_reporter'
  union all select 33, '0027 standalone user warning',
    exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'warn_user'),
    'function warn_user — the Take Action sheet''s Send warning needs this'
  -- 0026 is INVERTED on purpose. It is written but deliberately unapplied
  -- (it drops profiles.email irreversibly and is gated on both Vault keys
  -- being stored off the database — see its header). So the healthy state
  -- is NOT applied, and this row says so rather than reporting a scary
  -- 'NO' on the one migration you are not supposed to have run.
  union all select 34, '0026 retire plaintext email (must NOT be applied)',
    exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'profiles'
               and column_name = 'email'),
    'profiles.email still present — correct, 0026 is deliberately unapplied'
)
-- Rows that need action sort to the TOP, so the answer to "what am I
-- missing" is simply the first block of the result rather than something
-- you scan 30 rows for.
--
-- `applied` means "the database is in the state this repository expects",
-- not literally "this migration ran" — the two differ for 0026, which is
-- written but deliberately unapplied, so its healthy state is the column
-- still being there. Keeping the column's meaning uniform is what lets
-- this sort be trusted.
select
  case when applied is not true then '>> TODO' else 'ok' end as action,
  migration,
  case
    when applied is null then 'UNKNOWN (object missing entirely)'
    when applied then 'yes'
    else 'NO  <-- not applied'
  end as applied,
  evidence
from probe
order by (applied is not true) desc, seq;

-- ===========================================================================
-- QUERY 2 OF 2 — DUPLICATE USERNAMES.  Select from here down and Run.
-- ===========================================================================
--
-- Only needed if Query 1 reported "0020 (a) unique username index" as not
-- applied. 0020 refuses to proceed while duplicates exist, and this is the
-- list it will complain about. No rows returned = nothing to fix.
-- ---------------------------------------------------------------------------
select lower(username) as duplicated_username,
       count(*) as accounts,
       string_agg(id::text, ', ') as profile_ids
  from public.profiles
 where username is not null
 group by lower(username)
having count(*) > 1
 order by lower(username);
